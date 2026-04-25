const std = @import("std");
const protocol = @import("protocol.zig");

pub const Formatter = struct {
    const COLOR_RESET = "\x1b[0m";
    const COLOR_GREEN = "\x1b[32m";
    const COLOR_YELLOW = "\x1b[33m";
    const COLOR_RED = "\x1b[31m";
    const COLOR_CYAN = "\x1b[36m";
    const COLOR_BOLD = "\x1b[1m";

    pub const Format = enum {
        text,
        json,
    };

    io: std.Io,
    output_format: Format,

    pub fn init(io: std.Io, output_format: Format) Formatter {
        return .{
            .io = io,
            .output_format = output_format,
        };
    }

    fn print(self: Formatter, comptime fmt: []const u8, args: anytype) !void {
        // テキスト形式は stderr に、JSON形式は stdout に出力するのが一般的
        var file = if (self.output_format == .json) std.Io.File.stdout() else std.Io.File.stderr();
        var buf: [1024]u8 = undefined;
        var file_writer = file.writer(self.io, &buf);
        const writer = &file_writer.interface;
        try writer.print(fmt, args);
        try writer.flush();
    }

    fn printJson(self: Formatter, value: anytype) !void {
        var buf: [4096]u8 = undefined;
        var file_writer = std.Io.File.stdout().writer(self.io, &buf);
        const writer = &file_writer.interface;

        // Zig 0.16.0 では std.json.fmt を使用
        const d = std.json.fmt(value, .{});
        try writer.print("{f}\n", .{d});
        try writer.flush();
    }

    pub fn printBegin(self: Formatter) !void {
        if (self.output_format == .json) {
            try self.printJson(.{ .op = "BEGIN" });
        } else {
            try self.print("{s}[BEGIN]{s}\n", .{ COLOR_CYAN, COLOR_RESET });
        }
    }

    pub fn printCommit(self: Formatter) !void {
        if (self.output_format == .json) {
            try self.printJson(.{ .op = "COMMIT" });
        } else {
            try self.print("{s}[COMMIT]{s}\n", .{ COLOR_CYAN, COLOR_RESET });
        }
    }

    pub fn printInsert(self: Formatter, rel: protocol.Relation, insert: protocol.Insert) !void {
        if (self.output_format == .json) {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const aa = arena.allocator();

            var data: std.array_hash_map.String([]const u8) = .empty;
            for (rel.column_names, insert.tuple.values) |col_name, val| {
                try data.put(aa, col_name, val);
            }

            const json_data: std.json.ArrayHashMap([]const u8) = .{
                .map = data,
            };

            try self.printJson(.{
                .op = "INSERT",
                .table = rel.name,
                .schema = rel.namespace,
                .data = json_data,
            });
        } else {
            try self.print("{s}{s}[INSERT]{s} table={s}{s}{s}\n", .{ COLOR_BOLD, COLOR_GREEN, COLOR_RESET, COLOR_BOLD, rel.name, COLOR_RESET });
            for (rel.column_names, insert.tuple.values) |col_name, val| {
                try self.print("  {s}- {s}:{s} {s}\n", .{ COLOR_CYAN, col_name, COLOR_RESET, val });
            }
        }
    }

    pub fn printUpdate(self: Formatter, rel: protocol.Relation, update: protocol.Update) !void {
        if (self.output_format == .json) {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const aa = arena.allocator();

            var data: std.array_hash_map.String([]const u8) = .empty;
            var old_data: ?std.array_hash_map.String([]const u8) = null;

            for (rel.column_names, update.new_tuple.values) |col_name, val| {
                try data.put(aa, col_name, val);
            }

            if (update.old_tuple) |old| {
                // var map = std.StringArrayHashMap([]const u8).init(aa);
                var map: std.array_hash_map.String([]const u8) = .empty;
                for (rel.column_names, old.values) |col_name, val| {
                    try map.put(aa, col_name, val);
                }
                old_data = map;
            }

            const json_data: std.json.ArrayHashMap([]const u8) = .{
                .map = data,
            };

            var old_json_data: ?std.json.ArrayHashMap([]const u8) = .{};
            if (old_data) |d| {
                old_json_data = .{
                    .map = d,
                };
            }

            try self.printJson(.{
                .op = "UPDATE",
                .table = rel.name,
                .schema = rel.namespace,
                .data = json_data,
                .old_data = old_json_data,
            });
        } else {
            try self.print("{s}{s}[UPDATE]{s} table={s}{s}{s}\n", .{ COLOR_BOLD, COLOR_YELLOW, COLOR_RESET, COLOR_BOLD, rel.name, COLOR_RESET });
            for (rel.column_names, update.new_tuple.values, 0..) |col_name, new_val, i| {
                if (update.old_tuple) |old| {
                    const old_val = old.values[i];
                    if (!std.mem.eql(u8, old_val, new_val)) {
                        try self.print("  {s}- {s}:{s} {s} -> {s}{s}{s}\n", .{ COLOR_CYAN, col_name, COLOR_RESET, old_val, COLOR_YELLOW, new_val, COLOR_RESET });
                    } else {
                        try self.print("  {s}- {s}:{s} {s}\n", .{ COLOR_CYAN, col_name, COLOR_RESET, new_val });
                    }
                } else {
                    try self.print("  {s}- {s}:{s} {s}\n", .{ COLOR_CYAN, col_name, COLOR_RESET, new_val });
                }
            }
        }
    }

    pub fn printDelete(self: Formatter, rel: protocol.Relation, delete: protocol.Delete) !void {
        if (self.output_format == .json) {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const aa = arena.allocator();

            var old_data: std.array_hash_map.String([]const u8) = .empty;
            for (rel.column_names, delete.old_tuple.values) |col_name, val| {
                try old_data.put(aa, col_name, val);
            }

            const json_old_data: std.json.ArrayHashMap([]const u8) = .{
                .map = old_data,
            };

            try self.printJson(.{
                .op = "DELETE",
                .table = rel.name,
                .schema = rel.namespace,
                .old_data = json_old_data,
            });
        } else {
            try self.print("{s}{s}[DELETE]{s} table={s}{s}{s}\n", .{ COLOR_BOLD, COLOR_RED, COLOR_RESET, COLOR_BOLD, rel.name, COLOR_RESET });
            for (rel.column_names, delete.old_tuple.values) |col_name, val| {
                try self.print("  {s}- {s}:{s} {s}\n", .{ COLOR_CYAN, col_name, COLOR_RESET, val });
            }
        }
    }
};
