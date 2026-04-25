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

            conn.startReplication(self.config.slot_name, self.config.pub_name) catch |err| {
                std.debug.print("Start replication failed: {s}. Reconnecting...\n", .{@errorName(err)});
                if (waitInterruptible(self.io, retry_delay_ms)) break :outer;
                continue :outer;
            };

            std.debug.print("Connection established. Monitoring logical replication...\n", .{});
            retry_delay_ms = 1000; // 成功したのでリセット

            var last_wal_end: u64 = 0;

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
    var exclude_tables: std.ArrayList([]const u8) = .empty; // std.ArrayList([]const u8).init(init.arena.allocator());

    // 引数のパース (Zig 0.16.0 Juicy Main)
    const args = try init.minimal.args.toSlice(arena_allocator);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--dsn")) {
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
        } else if (std.mem.eql(u8, arg, "--json")) {
            config.output_format = .json;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print(
                \\Usage: gazelle [options]
                \\
                \\Options:
                \\  --dsn <dsn>      PostgreSQL connection string (default: host=localhost ...)
                \\  --slot <name>     Replication slot name (default: gazelle_slot)
                \\  --pub <name>      Publication name (default: gazelle_pub)
                \\  --table <name>    Include table in monitoring (can be specified multiple times)
                \\  --exclude <name>  Exclude table from monitoring (can be specified multiple times)
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
