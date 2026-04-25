const std = @import("std");

/// PostgreSQL Logical Replication Message Types
pub const MessageType = enum(u8) {
    Begin = 'B',
    Commit = 'C',
    Origin = 'O',
    Relation = 'R',
    Type = 'Y',
    Insert = 'I',
    Update = 'U',
    Delete = 'D',
    Truncate = 'T',
    StreamStart = 'S',
    StreamStop = 'E',
    StreamCommit = 'c',
    StreamAbort = 'A',
};

/// データの値を保持する構造体
pub const TupleData = struct {
    values: [][]const u8,

    pub fn parse(allocator: std.mem.Allocator, reader: *std.Io.Reader) !TupleData {
        const num_cols = try reader.takeInt(u16, .big);
        var values = try allocator.alloc([]const u8, num_cols);

        for (0..num_cols) |i| {
            const col_type = try reader.takeByte();
            switch (col_type) {
                'n' => values[i] = try allocator.dupe(u8, "NULL"),
                'u' => values[i] = try allocator.dupe(u8, "[UNCHANGED]"),
                't' => {
                    const len = try reader.takeInt(u32, .big);
                    const val = try reader.take(len);
                    values[i] = try allocator.dupe(u8, val);
                },
                else => return error.UnknownColumnType,
            }
        }
        return TupleData{ .values = values };
    }

    pub fn deinit(self: *TupleData, allocator: std.mem.Allocator) void {
        for (self.values) |val| {
            allocator.free(val);
        }
        allocator.free(self.values);
    }
};

pub const Relation = struct {
    id: u32,
    namespace: []const u8,
    name: []const u8,
    column_names: [][]const u8,

    pub fn parse(allocator: std.mem.Allocator, buffer: []const u8) !Relation {
        var reader = std.Io.Reader.fixed(buffer);
        _ = try reader.takeByte(); // 'R'

        const id = try reader.takeInt(u32, .big);
        const namespace = try reader.takeSentinel(0);
        const name = try reader.takeSentinel(0);
        _ = try reader.takeByte(); // replica identity

        const num_cols = try reader.takeInt(u16, .big);
        var column_names = try allocator.alloc([]const u8, num_cols);

        for (0..num_cols) |i| {
            _ = try reader.takeByte(); // flags
            column_names[i] = try allocator.dupe(u8, try reader.takeSentinel(0));
            _ = try reader.takeInt(u32, .big); // type OID
            _ = try reader.takeInt(u32, .big); // type mod
        }

        return Relation{
            .id = id,
            .namespace = try allocator.dupe(u8, namespace),
            .name = try allocator.dupe(u8, name),
            .column_names = column_names,
        };
    }

    pub fn deinit(self: *Relation, allocator: std.mem.Allocator) void {
        allocator.free(self.namespace);
        allocator.free(self.name);
        for (self.column_names) |name| {
            allocator.free(name);
        }
        allocator.free(self.column_names);
    }
};

pub const Insert = struct {
    relation_id: u32,
    tuple: TupleData,

    pub fn parse(allocator: std.mem.Allocator, buffer: []const u8) !Insert {
        var reader = std.Io.Reader.fixed(buffer);
        _ = try reader.takeByte(); // 'I'

        const relation_id = try reader.takeInt(u32, .big);
        const tuple_type = try reader.takeByte(); // 'N' for New Tuple
        if (tuple_type != 'N') return error.UnsupportedTupleType;

        const tuple = try TupleData.parse(allocator, &reader);

        return Insert{
            .relation_id = relation_id,
            .tuple = tuple,
        };
    }

    pub fn deinit(self: *Insert, allocator: std.mem.Allocator) void {
        self.tuple.deinit(allocator);
    }
};

pub const Update = struct {
    relation_id: u32,
    old_tuple: ?TupleData,
    new_tuple: TupleData,

    pub fn parse(allocator: std.mem.Allocator, buffer: []const u8) !Update {
        var reader = std.Io.Reader.fixed(buffer);
        _ = try reader.takeByte(); // 'U'

        const relation_id = try reader.takeInt(u32, .big);
        var tuple_type = try reader.takeByte();

        var old_tuple: ?TupleData = null;
        if (tuple_type == 'K' or tuple_type == 'O') {
            old_tuple = try TupleData.parse(allocator, &reader);
            tuple_type = try reader.takeByte();
        }

        if (tuple_type != 'N') return error.ExpectedNewTuple;
        const new_tuple = try TupleData.parse(allocator, &reader);

        return Update{
            .relation_id = relation_id,
            .old_tuple = old_tuple,
            .new_tuple = new_tuple,
        };
    }

    pub fn deinit(self: *Update, allocator: std.mem.Allocator) void {
        if (self.old_tuple) |*t| t.deinit(allocator);
        self.new_tuple.deinit(allocator);
    }
};

pub const Delete = struct {
    relation_id: u32,
    old_tuple: TupleData,

    pub fn parse(allocator: std.mem.Allocator, buffer: []const u8) !Delete {
        var reader = std.Io.Reader.fixed(buffer);
        _ = try reader.takeByte(); // 'D'

        const relation_id = try reader.takeInt(u32, .big);
        const tuple_type = try reader.takeByte();
        if (tuple_type != 'K' and tuple_type != 'O') return error.ExpectedOldTuple;

        const old_tuple = try TupleData.parse(allocator, &reader);

        return Delete{
            .relation_id = relation_id,
            .old_tuple = old_tuple,
        };
    }

    pub fn deinit(self: *Delete, allocator: std.mem.Allocator) void {
        self.old_tuple.deinit(allocator);
    }
};

pub const XLogData = struct {
    wal_start: u64,
    wal_end: u64,
    server_time: u64,
    data: []const u8,

    pub fn parse(buffer: []const u8) !XLogData {
        if (buffer.len < 25) return error.MalformedXLogData;
        if (buffer[0] != 'w') return error.InvalidMessageType;

        var reader = std.Io.Reader.fixed(buffer[1..]);

        const wal_start = try reader.takeInt(u64, .big);
        const wal_end = try reader.takeInt(u64, .big);
        const server_time = try reader.takeInt(u64, .big);

        return XLogData{
            .wal_start = wal_start,
            .wal_end = wal_end,
            .server_time = server_time,
            .data = buffer[25..],
        };
    }
};

pub const Keepalive = struct {
    wal_end: u64,
    server_time: u64,
    reply_requested: bool,

    pub fn parse(buffer: []const u8) !Keepalive {
        if (buffer.len < 18) return error.MalformedKeepalive;
        if (buffer[0] != 'k') return error.InvalidMessageType;

        var reader = std.Io.Reader.fixed(buffer[1..]);

        const wal_end = try reader.takeInt(u64, .big);
        const server_time = try reader.takeInt(u64, .big);
        const reply_requested = (try reader.takeByte()) != 0;

        return Keepalive{
            .wal_end = wal_end,
            .server_time = server_time,
            .reply_requested = reply_requested,
        };
    }
};

test "XLogData parse" {
    // 'w' (1), wal_start (8), wal_end (8), server_time (8), data...
    var buffer: [26]u8 = undefined;
    buffer[0] = 'w';
    std.mem.writeInt(u64, buffer[1..9], 0x1122334455667788, .big);
    std.mem.writeInt(u64, buffer[9..17], 0x99AABBCCDDEEFF00, .big);
    std.mem.writeInt(u64, buffer[17..25], 0xAAAABBBBCCCCDDDD, .big);
    buffer[25] = 'I'; // Logical Insert

    const xlog = try XLogData.parse(&buffer);
    try std.testing.expectEqual(@as(u64, 0x1122334455667788), xlog.wal_start);
    try std.testing.expectEqual(@as(u64, 0x99AABBCCDDEEFF00), xlog.wal_end);
    try std.testing.expectEqual(@as(u64, 0xAAAABBBBCCCCDDDD), xlog.server_time);
    try std.testing.expectEqual(@as(u8, 'I'), xlog.data[0]);
}

test "Keepalive parse" {
    // 'k' (1), wal_end (8), server_time (8), reply_requested (1)
    var buffer: [18]u8 = undefined;
    buffer[0] = 'k';
    std.mem.writeInt(u64, buffer[1..9], 0x1234567812345678, .big);
    std.mem.writeInt(u64, buffer[9..17], 0x8765432187654321, .big);
    buffer[17] = 1; // reply requested

    const k = try Keepalive.parse(&buffer);
    try std.testing.expectEqual(@as(u64, 0x1234567812345678), k.wal_end);
    try std.testing.expectEqual(@as(u64, 0x8765432187654321), k.server_time);
    try std.testing.expectEqual(true, k.reply_requested);
}
