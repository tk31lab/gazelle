const std = @import("std");
const gazelle = @import("gazelle");
const Watcher = @import("main.zig").Watcher;
const Config = @import("main.zig").Config;

test "Watcher.savePosition and loadPosition" {
    // Zig 0.16.0 の Io テストセットアップ (モック相当)
    // 実際のテストでは一時的なディレクトリやファイルを使用します。
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const pos_file = "test_gazelle.pos";
    defer std.Io.Dir.cwd().deleteFile(io, pos_file) catch {};

    const config = Config{
        .conninfo = "",
        .slot_name = "test_slot",
        .pub_name = "test_pub",
        .pos_file = pos_file,
    };

    var watcher = Watcher.init(allocator, io, config);
    defer watcher.deinit();

    // 1. 初期状態 (ファイルなし) は 0 を返すはず
    try std.testing.expectEqual(@as(u64, 0), watcher.loadPosition());

    // 2. 位置を保存 (1/2A3B4C5D)
    const test_lsn: u64 = (1 << 32) | 0x2A3B4C5D;
    try watcher.savePosition(test_lsn);

    // 3. ロードして一致するか確認
    const loaded_lsn = watcher.loadPosition();
    try std.testing.expectEqual(test_lsn, loaded_lsn);

    // 4. 文字列として正しく書き込まれているか直接確認
    const file = try std.Io.Dir.cwd().openFile(io, pos_file, .{});
    defer file.close(io);
    var buf: [64]u8 = undefined;
    var file_reader = file.reader(io, &buf);
    const r = &file_reader.interface;
    const len = try r.readSliceShort(&buf);
    try std.testing.expectEqualStrings("1/2A3B4C5D\n", buf[0..len]);
}
