//! The input kind of each wheel event, by dvui event number: dvui keeps only the window's last.
const std = @import("std");
const dvui = @import("dvui");

/// Record `kind` for wheel event `num` (the window's `event_num` right after addEventMouseWheel).
pub fn set(win: *dvui.Window, num: u16, kind: dvui.enums.MouseType) void {
    var buf: [32]u8 = undefined;
    dvui.dataSet(win, win.data().id, key(&buf, num), kind);
}

/// The kind recorded for event `num`, or null when no backend recorded one (synthetic events, remote view).
pub fn get(num: u16) ?dvui.enums.MouseType {
    var buf: [32]u8 = undefined;
    return dvui.dataGet(null, dvui.currentWindow().data().id, key(&buf, num), dvui.enums.MouseType);
}

fn key(buf: *[32]u8, num: u16) []const u8 {
    // The prefix and a u16 event number fit in 32 bytes.
    return std.mem.print(buf, "_wheel_kind_{d}", .{num}) catch unreachable;
}

test "set and get keep each event's kind in a mixed frame" {
    var test_window = try dvui.testing.init(.{});
    defer test_window.deinit();
    const win = dvui.currentWindow();

    _ = try win.addEventMouseWheel(1, .vertical, .mouse);
    const mouse_num = win.event_num;
    set(win, mouse_num, .mouse);
    _ = try win.addEventMouseWheel(1, .vertical, .trackpad);
    const trackpad_num = win.event_num;
    set(win, trackpad_num, .trackpad);

    try std.testing.expectEqual(@as(?dvui.enums.MouseType, .mouse), get(mouse_num));
    try std.testing.expectEqual(@as(?dvui.enums.MouseType, .trackpad), get(trackpad_num));
    try std.testing.expectEqual(@as(?dvui.enums.MouseType, null), get(trackpad_num + 1));
}
