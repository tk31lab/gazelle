const std = @import("std");
const pg = @import("libpq");

pub const Connection = struct {
    handle: ?*pg.PGconn,
    io: std.Io,

    pub fn connect(io: std.Io, conninfo: [:0]const u8) !Connection {
        const handle = pg.PQconnectdb(conninfo);
        if (pg.PQstatus(handle) != pg.CONNECTION_OK) {
            std.debug.print("Connection to database failed: {s}\n", .{pg.PQerrorMessage(handle)});
            pg.PQfinish(handle);
            return error.ConnectionFailed;
        }
        return Connection{
            .handle = handle,
            .io = io,
        };
    }

    pub fn deinit(self: *Connection) void {
        if (self.handle) |h| {
            pg.PQfinish(h);
            self.handle = null;
        }
    }

    pub fn exec(self: *Connection, query: [:0]const u8) !void {
        const res = pg.PQexec(self.handle, query);
        defer pg.PQclear(res);
        const status = pg.PQresultStatus(res);
        if (status != pg.PGRES_COMMAND_OK and status != pg.PGRES_TUPLES_OK) {
            std.debug.print("Query failed: {s} (Query: {s})\n", .{ pg.PQerrorMessage(self.handle), query });
            return error.QueryFailed;
        }
    }

    /// Publication を作成する（既に存在する場合は無視）
    pub fn createPublicationIfNotExists(self: *Connection, pub_name: [:0]const u8) !void {
        var query_buf: [256]u8 = undefined;
        // DO ブロックを使って存在チェックを行い、なければ作成する
        const query = try std.fmt.bufPrintZ(&query_buf, "DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = '{s}') THEN CREATE PUBLICATION {s} FOR ALL TABLES; END IF; END $$;", .{ pub_name, pub_name });
        try self.exec(query);
        std.debug.print("Publication '{s}' ensured (created if missing).\n", .{pub_name});
    }

    /// 全てのユーザーテーブルを REPLICA IDENTITY FULL に設定する
    pub fn setReplicaIdentityFullForAllTables(self: *Connection) !void {
        const query =
            \\DO $$
            \\DECLARE
            \\    t text;
            \\BEGIN
            \\    FOR t IN (SELECT quote_ident(schemaname) || '.' || quote_ident(tablename) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog', 'information_schema')) LOOP
            \\        EXECUTE 'ALTER TABLE ' || t || ' REPLICA IDENTITY FULL';
            \\    END LOOP;
            \\END $$;
        ;
        try self.exec(query);
        std.debug.print("All user tables set to REPLICA IDENTITY FULL.\n", .{});
    }

    /// レプリケーションスロットを作成する
    pub fn createReplicationSlot(self: *Connection, slot_name: [:0]const u8) !void {
        var query_buf: [256]u8 = undefined;
        const query = try std.fmt.bufPrintZ(&query_buf, "CREATE_REPLICATION_SLOT {s} LOGICAL pgoutput", .{slot_name});
        try self.exec(query);
        std.debug.print("Replication slot '{s}' created.\n", .{slot_name});
    }

    /// レプリケーションスロットを削除する
    pub fn dropReplicationSlot(self: *Connection, slot_name: [:0]const u8) !void {
        var query_buf: [256]u8 = undefined;
        const query = try std.fmt.bufPrintZ(&query_buf, "DROP_REPLICATION_SLOT {s}", .{slot_name});
        try self.exec(query);
        std.debug.print("Replication slot '{s}' dropped.\n", .{slot_name});
    }

    /// レプリケーションを開始する
    pub fn startReplication(self: *Connection, slot_name: [:0]const u8, publication_name: [:0]const u8, lsn: u64) !void {
        var query_buf: [512]u8 = undefined;
        // proto_version '2' は PostgreSQL 14以降で推奨される論理複製のプロトコルバージョン
        // LSN が 0 の場合は 0/0 (最初から) を指定する。指定がある場合は X/Y 形式で指定する。
        const query = if (lsn == 0)
            try std.fmt.bufPrintZ(&query_buf, "START_REPLICATION SLOT {s} LOGICAL 0/0 (proto_version '2', publication_names '{s}')", .{ slot_name, publication_name })
        else
            try std.fmt.bufPrintZ(&query_buf, "START_REPLICATION SLOT {s} LOGICAL {X}/{X} (proto_version '2', publication_names '{s}')", .{ slot_name, @as(u32, @intCast(lsn >> 32)), @as(u32, @intCast(lsn & 0xFFFFFFFF)), publication_name });

        const res = pg.PQexec(self.handle, query);
        defer pg.PQclear(res);

        if (pg.PQresultStatus(res) != pg.PGRES_COPY_BOTH) {
            std.debug.print("Failed to start replication: {s}\n", .{pg.PQerrorMessage(self.handle)});
            return error.StartReplicationFailed;
        }
        std.debug.print("Replication started on slot '{s}' for publication '{s}'.\n", .{ slot_name, publication_name });
    }

    /// レプリケーション（COPY モード）を終了する
    pub fn stopReplication(self: *Connection) !void {
        // サーバーに CopyDone メッセージ ('X') を送る
        const res = pg.PQputCopyEnd(self.handle, null);
        if (res == -1) {
            std.debug.print("Failed to send CopyEnd: {s}\n", .{pg.PQerrorMessage(self.handle)});
            return error.StopReplicationFailed;
        }

        // START_REPLICATION コマンドの最終結果を読み取って COPY モードを完全に抜ける
        const result = pg.PQgetResult(self.handle);
        if (result) |r| {
            pg.PQclear(r);
        }
        // var result = pg.PQgetResult(self.handle);
        // while (result != null) {
        //     pg.PQclear(result);
        //     result = pg.PQgetResult(self.handle);
        // }
        std.debug.print("Replication mode ended.\n", .{});
    }

    /// ソケットを監視し、データが来るかタイムアウトするまで待機して受信する
    pub fn pollAndReceive(self: *Connection, timeout_ms: i32) !?[]u8 {
        // 1. すでにバッファにあるデータを確認 (asyncモード: 1)
        var buffer: [*c]u8 = undefined;
        var len = pg.PQgetCopyData(self.handle, &buffer, 1);
        if (len > 0) return buffer[0..@intCast(len)];
        if (len == -1) return null; // 終了

        // 2. ソケットが読み取り可能になるまで待機
        const fd = pg.PQsocket(self.handle);
        const pfd = std.posix.pollfd{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        };
        var fds = [1]std.posix.pollfd{pfd};

        // poll で待機。シグナルで中断された場合は SignalInterrupt エラーが出るのでキャッチ
        const ready_count = std.posix.poll(&fds, timeout_ms) catch |err| {
            if (err == error.SignalInterrupt) return null;
            return err;
        };

        if (ready_count == 0) return null; // タイムアウト

        // 3. データをサーバーから読み取ってバッファに補充
        if (pg.PQconsumeInput(self.handle) == 0) {
            std.debug.print("PQconsumeInput failed: {s}\n", .{pg.PQerrorMessage(self.handle)});
            return error.ConsumeInputFailed;
        }

        // 4. 再度バッファから取得を試みる
        len = pg.PQgetCopyData(self.handle, &buffer, 1);
        if (len > 0) {
            return buffer[0..@intCast(len)];
        }
        return null;
    }

    /// libpq が割り当てたメモリを解放する
    pub fn free(self: *Connection, ptr: anyptr) void {
        _ = self;
        pg.PQfreemem(ptr);
    }

    /// サーバーに現在の WAL 位置を報告する (Standby status update)
    /// メッセージタイプ 'r' (Standby status update) を送る
    pub fn sendStatusUpdate(self: *Connection, last_wal_end: u64) !void {
        var buffer: [34]u8 = undefined;
        buffer[0] = 'r';
        // write, flush, apply の各位置をセット（とりあえず全て同じ位置を報告）
        std.mem.writeInt(u64, buffer[1..9], last_wal_end, .big);
        std.mem.writeInt(u64, buffer[9..17], last_wal_end, .big);
        std.mem.writeInt(u64, buffer[17..25], last_wal_end, .big);

        // 時刻 (2000年1月1日午前0時からのマイクロ秒)
        // 2000-01-01 00:00:00 UTC の Unixタイムスタンプは 946684800 秒
        const postgres_epoch_us = 946684800 * 1000 * 1000;
        const t = std.Io.Timestamp.now(self.io, .real);
        const now_us = t.toMicroseconds();
        const pg_now_us: u64 = if (now_us > postgres_epoch_us)
            @intCast(now_us - postgres_epoch_us)
        else
            0;
        std.mem.writeInt(u64, buffer[25..33], pg_now_us, .big);

        // reply requested (0 = 不要)
        buffer[33] = 0;

        const res = pg.PQputCopyData(self.handle, @ptrCast(&buffer), @intCast(buffer.len));
        if (res == -1) {
            std.debug.print("Failed to send status update: {s}\n", .{pg.PQerrorMessage(self.handle)});
            return error.SendStatusUpdateFailed;
        }

        // 送信を確定させる
        if (pg.PQflush(self.handle) == -1) {
            std.debug.print("Failed to flush status update: {s}\n", .{pg.PQerrorMessage(self.handle)});
            return error.FlushFailed;
        }
    }
};

const anyptr = ?*anyopaque;
