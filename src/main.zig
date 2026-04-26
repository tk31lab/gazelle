const std = @import("std");
const builtin = @import("builtin");
const gazelle = @import("gazelle");

// シグナルセーフなアトミックフラグ（Watcherからも参照できるようにグローバルに保持）
var should_exit = std.atomic.Value(bool).init(false);

fn handleSigInt(sig: @TypeOf(std.posix.SIG.INT)) callconv(.c) void {
    _ = sig;
    should_exit.store(true, .monotonic);
}

/// Watcher の設定を保持する構造体
pub const Config = struct {
    conninfo: [:0]const u8,
    slot_name: [:0]const u8,
    pub_name: [:0]const u8,
    output_format: OutputFormat = .text,
    include_tables: ?[]const []const u8 = null,
    exclude_tables: ?[]const []const u8 = null,
    pos_file: ?[]const u8 = null,

    pub const OutputFormat = enum {
        text,
        json,
    };
};

/// 監視の主力ロジックを担当する構造体
pub const Watcher = struct {
    allocator: std.mem.Allocator,
    config: Config,
    relations: std.AutoHashMap(u32, gazelle.protocol.Relation),
    formatter: gazelle.formatter.Formatter,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Config) Watcher {
        const fmt_type: gazelle.formatter.Formatter.Format = switch (config.output_format) {
            .text => .text,
            .json => .json,
        };
        return .{
            .allocator = allocator,
            .config = config,
            .relations = std.AutoHashMap(u32, gazelle.protocol.Relation).init(allocator),
            .formatter = gazelle.formatter.Formatter.init(io, fmt_type),
            .io = io,
        };
    }

    pub fn deinit(self: *Watcher) void {
        var it = self.relations.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.relations.deinit();
    }

    pub fn loadPosition(self: *Watcher) u64 {
        const path = self.config.pos_file orelse return 0;
        const is_absolute = std.Io.Dir.path.isAbsolute(path);
        const file = if (is_absolute)
            std.Io.Dir.openFileAbsolute(self.io, path, .{}) catch return 0
        else
            std.Io.Dir.cwd().openFile(self.io, path, .{}) catch return 0;
        defer file.close(self.io);

        var buf: [64]u8 = undefined;
        var file_reader = file.reader(self.io, &buf);
        const r = &file_reader.interface;
        const bytes_read = r.readSliceShort(&buf) catch return 0;
        const content = std.mem.trim(u8, buf[0..bytes_read], " \n\r\t");

        // X/Y 形式のパース
        var it = std.mem.splitScalar(u8, content, '/');
        const high_str = it.next() orelse return 0;
        const low_str = it.next() orelse return 0;

        const high = std.fmt.parseInt(u32, high_str, 16) catch return 0;
        const low = std.fmt.parseInt(u32, low_str, 16) catch return 0;

        return (@as(u64, high) << 32) | low;
    }

    pub fn savePosition(self: *Watcher, lsn: u64) !void {
        const path = self.config.pos_file orelse return;
        if (lsn == 0) return;

        // アトミックな書き込みのために一時ファイルを作成
        var tmp_path_buf: [256]u8 = undefined;
        const tmp_path = try std.fmt.bufPrint(&tmp_path_buf, "{s}.tmp", .{path});
        const is_absolute = std.Io.Dir.path.isAbsolute(path);
        {
            const file = if (is_absolute)
                try std.Io.Dir.createFileAbsolute(self.io, tmp_path, .{})
            else
                try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{});
            defer file.close(self.io);

            var buf: [1024]u8 = undefined;
            var file_writer = file.writer(self.io, &buf);
            const writer = &file_writer.interface;
            try writer.print("{X}/{X}\n", .{ @as(u32, @intCast(lsn >> 32)), @as(u32, @intCast(lsn & 0xFFFFFFFF)) });
            try writer.flush();
            try file.sync(self.io);
        }
        if (is_absolute) {
            try std.Io.Dir.renameAbsolute(tmp_path, path, self.io);
        } else {
            try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, self.io);
        }
    }

    fn shouldWatch(self: *Watcher, table_name: []const u8) bool {
        // ブラックリスト形式のチェック
        if (self.config.exclude_tables) |excludes| {
            for (excludes) |exclude| {
                if (std.mem.eql(u8, table_name, exclude)) return false;
            }
        }

        // ホワイトリスト形式のチェック
        if (self.config.include_tables) |includes| {
            for (includes) |include| {
                if (std.mem.eql(u8, table_name, include)) return true;
            }
            return false;
        }

        return true;
    }

    /// 指定されたミリ秒待機するが、シグナル（Ctrl+C）を受け取ったら即座に中断して true を返す
    fn waitInterruptible(io: std.Io, ms: u32) bool {
        const step_ms: u32 = 100;
        var remaining = ms;
        while (remaining > 0) {
            if (should_exit.load(.monotonic)) return true;
            const sleep_ms = @min(remaining, step_ms);
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(sleep_ms), .awake) catch |err| {
                std.debug.print("{}\n", .{err});
            };
            remaining -= sleep_ms;
        }
        return should_exit.load(.monotonic);
    }

    pub fn run(self: *Watcher) !void {
        var retry_delay_ms: u32 = 1000;
        const max_retry_delay_ms: u32 = 30000;

        const is_debug = builtin.mode == .Debug;
        var gpa = if (is_debug) std.heap.DebugAllocator(.{}).init else undefined;
        defer if (is_debug) {
            _ = gpa.deinit();
        };
        const loop_allocator = if (is_debug) gpa.allocator() else std.heap.c_allocator;
        var arena = std.heap.ArenaAllocator.init(loop_allocator);
        defer arena.deinit();

        outer: while (!should_exit.load(.monotonic)) {
            var conn = gazelle.connection.Connection.connect(self.io, self.config.conninfo) catch |err| {
                std.debug.print("Database connection failed: {}. Retrying in {d}ms...\n", .{ err, retry_delay_ms });
                if (waitInterruptible(self.io, retry_delay_ms)) break :outer;
                retry_delay_ms = @min(retry_delay_ms * 2, max_retry_delay_ms);
                continue :outer;
            };
            defer conn.deinit();

            // 起動時の自動設定
            conn.createPublicationIfNotExists(self.config.pub_name) catch |err| {
                std.debug.print("Setup failed (Publication): {}. Reconnecting...\n", .{err});
                if (waitInterruptible(self.io, retry_delay_ms)) break :outer;
                continue :outer;
            };
            conn.setReplicaIdentityFullForAllTables() catch |err| {
                std.debug.print("Setup failed (Replica Identity): {}. Reconnecting...\n", .{err});
                if (waitInterruptible(self.io, retry_delay_ms)) break :outer;
                continue :outer;
            };

            // レプリケーションスロットの作成（既にある場合はエラーになるが無視）
            _ = conn.createReplicationSlot(self.config.slot_name) catch {};

            const start_lsn = self.loadPosition();
            if (start_lsn != 0) {
                std.debug.print("Resuming replication from LSN: {X}/{X}\n", .{ @as(u32, @intCast(start_lsn >> 32)), @as(u32, @intCast(start_lsn & 0xFFFFFFFF)) });
            }

            conn.startReplication(self.config.slot_name, self.config.pub_name, start_lsn) catch |err| {
                std.debug.print("Start replication failed: {s}. Reconnecting...\n", .{@errorName(err)});
                if (waitInterruptible(self.io, retry_delay_ms)) break :outer;
                continue :outer;
            };

            std.debug.print("Connection established. Monitoring logical replication...\n", .{});
            retry_delay_ms = 1000; // 成功したのでリセット

            var last_wal_end: u64 = start_lsn;

            while (!should_exit.load(.monotonic)) {
                _ = arena.reset(.retain_capacity);
                const aa = arena.allocator();

                const raw_data = conn.pollAndReceive(100) catch |err| {
                    if (err == error.SignalInterrupt) break :outer;
                    std.debug.print("\nConnection lost: {}. Reconnecting in {d}ms...\n", .{ err, retry_delay_ms });
                    break; // 内側ループを抜けて再接続へ
                } orelse continue;
                defer conn.free(raw_data.ptr);

                if (raw_data.len == 0) continue;

                const msg_type = raw_data[0];
                switch (msg_type) {
                    'w' => {
                        const xlog = try gazelle.protocol.XLogData.parse(raw_data);
                        last_wal_end = xlog.wal_end;
                        // 進行状況を保存
                        self.savePosition(last_wal_end) catch {};

                        if (xlog.data.len > 0) {
                            const logical_msg_type = xlog.data[0];
                            switch (logical_msg_type) {
                                'R' => {
                                    var rel = try gazelle.protocol.Relation.parse(self.allocator, xlog.data);
                                    if (self.shouldWatch(rel.name)) {
                                        if (self.relations.getPtr(rel.id)) |old_rel| {
                                            old_rel.deinit(self.allocator);
                                        }
                                        try self.relations.put(rel.id, rel);
                                    } else {
                                        // 監視対象外の場合はマップから削除し、メモリを解放する
                                        if (self.relations.fetchRemove(rel.id)) |entry| {
                                            var v = entry.value;
                                            v.deinit(self.allocator);
                                        }
                                        rel.deinit(self.allocator);
                                    }
                                },
                                'I' => {
                                    const insert = try gazelle.protocol.Insert.parse(aa, xlog.data);
                                    if (self.relations.get(insert.relation_id)) |rel| {
                                        try self.formatter.printInsert(rel, insert);
                                    }
                                },
                                'U' => {
                                    const update = try gazelle.protocol.Update.parse(aa, xlog.data);
                                    if (self.relations.get(update.relation_id)) |rel| {
                                        try self.formatter.printUpdate(rel, update);
                                    }
                                },
                                'D' => {
                                    const delete = try gazelle.protocol.Delete.parse(aa, xlog.data);
                                    if (self.relations.get(delete.relation_id)) |rel| {
                                        try self.formatter.printDelete(rel, delete);
                                    }
                                },
                                'B' => try self.formatter.printBegin(),
                                'C' => try self.formatter.printCommit(),
                                else => {},
                            }
                        }
                    },
                    'k' => {
                        const keepalive = try gazelle.protocol.Keepalive.parse(raw_data);
                        last_wal_end = keepalive.wal_end;
                        // 進行状況を保存
                        self.savePosition(last_wal_end) catch {};

                        if (keepalive.reply_requested) {
                            conn.sendStatusUpdate(last_wal_end) catch |err| {
                                std.debug.print("Failed to send status update: {}. Reconnecting...\n", .{err});
                                break;
                            };
                        }
                    },
                    else => {},
                }
            }

            // ループを抜けた（エラーまたは終了）
            std.debug.print("Stopping replication...\n", .{});
            conn.stopReplication() catch {};
        }

        // プログラム終了時の最終クリーンアップ
        std.debug.print("Gazelle shutting down. Cleaning up resource...\n", .{});
        // 最終的なスロット削除などは必要に応じてここで行う
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // シグナルハンドリング設定
    var act = std.posix.Sigaction{
        .handler = .{ .handler = handleSigInt },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);

    // デフォルト値
    var config = Config{
        .conninfo = "host=localhost port=5432 user=postgres password=password dbname=gazelle_db replication=database",
        .slot_name = "gazelle_slot",
        .pub_name = "gazelle_pub",
    };

    const arena_allocator = init.arena.allocator();
    var include_tables: std.ArrayList([]const u8) = .empty;
    var exclude_tables: std.ArrayList([]const u8) = .empty;

    // 1次パース: --config を探す
    const args = try init.minimal.args.toSlice(arena_allocator);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--config")) {
            i += 1;
            if (i < args.len) {
                const config_path = args[i];
                const file = try std.Io.Dir.cwd().openFile(init.io, config_path, .{});
                defer file.close(init.io);

                var buf: [1024 * 16]u8 = undefined; // 16KB max config
                var file_reader = file.reader(init.io, &buf);
                const r = &file_reader.interface;
                const bytes_read = try r.readSliceShort(&buf);
                
                const parsed = try std.json.parseFromSlice(Config, arena_allocator, buf[0..bytes_read], .{
                    .ignore_unknown_fields = true,
                    .allocate = .alloc_always,
                });
                // 設定ファイルの内容を反映（後続の引数で上書きされる）
                config = parsed.value;
            }
        }
    }

    // 2次パース: その他の引数で上書き
    i = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--config")) {
            i += 1; // 既に対処済み
        } else if (std.mem.eql(u8, arg, "--dsn")) {
            i += 1;
            if (i < args.len) config.conninfo = args[i];
        } else if (std.mem.eql(u8, arg, "--slot")) {
            i += 1;
            if (i < args.len) config.slot_name = args[i];
        } else if (std.mem.eql(u8, arg, "--pub")) {
            i += 1;
            if (i < args.len) config.pub_name = args[i];
        } else if (std.mem.eql(u8, arg, "--table")) {
            i += 1;
            if (i < args.len) try include_tables.append(arena_allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "--exclude")) {
            i += 1;
            if (i < args.len) try exclude_tables.append(arena_allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "--pos")) {
            i += 1;
            if (i < args.len) config.pos_file = args[i];
        } else if (std.mem.eql(u8, arg, "--json")) {
            config.output_format = .json;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print(
                \\Usage: gazelle [options]
                \\
                \\Options:
                \\  --config <file>   Load configuration from a JSON file
                \\  --dsn <dsn>      PostgreSQL connection string (default: host=localhost ...)
                \\  --slot <name>     Replication slot name (default: gazelle_slot)
                \\  --pub <name>      Publication name (default: gazelle_pub)
                \\  --table <name>    Include table in monitoring (can be specified multiple times)
                \\  --exclude <name>  Exclude table from monitoring (can be specified multiple times)
                \\  --pos <file>      File to persist the last WAL position (LSN)
                \\  --json            Output in JSON Lines format
                \\  -h, --help        Show this help
                \\
            , .{});
            return;
        }
    }

    if (include_tables.items.len > 0) config.include_tables = include_tables.items;
    if (exclude_tables.items.len > 0) config.exclude_tables = exclude_tables.items;

    var watcher = Watcher.init(allocator, init.io, config);
    defer watcher.deinit();

    try watcher.run();
}
