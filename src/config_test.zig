const std = @import("std");
const gazelle = @import("gazelle");
const Watcher = @import("main.zig").Watcher;
const Config = @import("main.zig").Config;

test "Load configuration from JSON" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const config_path = "test_config.json";

    // 1. テスト用JSONの作成
    const json_content =
        \\{
        \\  "conninfo": "localhost",
        \\  "slot_name": "json_slot",
        \\  "pub_name": "json_pub",
        \\  "output_format": "json",
        \\  "include_tables": ["table1", "table2"]
        \\}
    ;
    {
        const file = try std.Io.Dir.cwd().createFile(io, config_path, .{});
        defer file.close(io);
        var buf: [1024]u8 = undefined;
        var file_writer = file.writer(io, &buf);
        try file_writer.interface.writeAll(json_content);
        try file_writer.flush();
    }
    defer std.Io.Dir.cwd().deleteFile(io, config_path) catch {};

    // 2. パース処理 (main.zig からロジックを抜粋・テスト用に構成)
    var config = Config{
        .conninfo = "default",
        .slot_name = "default",
        .pub_name = "default",
    };

    const file = try std.Io.Dir.cwd().openFile(io, config_path, .{});
    defer file.close(io);

    var buf: [1024]u8 = undefined;
    var file_reader = file.reader(io, &buf);
    const reader = &file_reader.interface;
    const bytes_read = try reader.readSliceShort(&buf);

    const parsed = try std.json.parseFromSlice(Config, allocator, buf[0..bytes_read], .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    config = parsed.value;

    // 3. 検証
    try std.testing.expectEqualStrings("json_slot", config.slot_name);
    try std.testing.expectEqualStrings("json_pub", config.pub_name);
    try std.testing.expectEqual(Config.OutputFormat.json, config.output_format);
    try std.testing.expectEqual(@as(usize, 2), config.include_tables.?.len);
    try std.testing.expectEqualStrings("table1", config.include_tables.?[0]);
}
