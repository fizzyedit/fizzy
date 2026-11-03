//! Nested scroll areas receive only the axis chosen by a trackpad gesture.
const std = @import("std");
const dvui = @import("dvui");
const wheel_kind = @import("glass").wheel_kind;
const ScrollArea = @import("ScrollArea.zig");

// The test and frame callback write these on the testing window's thread.
var outer: dvui.ScrollInfo = .{};
var inner: dvui.ScrollInfo = .{};

fn frame() !dvui.App.Result {
    var horizontal = ScrollArea.init(@src(), .{ .scroll_info = &outer, .horizontal_bar = .hide }, .{ .expand = .both });
    var vertical = ScrollArea.init(@src(), .{ .scroll_info = &inner, .vertical_bar = .hide }, .{ .min_size_content = .{ .w = 900 }, .expand = .vertical });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 900, .h = 2000 } });
    vertical.deinit();
    horizontal.deinit();
    return .ok;
}

fn after(ms: i128) !void {
    const win = dvui.currentWindow();
    _ = try frame();
    _ = try win.end(.{});
    try win.begin(win.frame_time_ns + ms * std.time.ns_per_ms);
}

fn swipe(dx: f32, dy: f32) !void {
    const win = dvui.currentWindow();
    for (0..20) |_| {
        _ = try wheel_kind.add(win, dx, .horizontal, .trackpad);
        _ = try wheel_kind.add(win, dy, .vertical, .trackpad);
        try after(16);
    }
}

test "trackpad axis choice keeps nested perpendicular scroll areas still" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    outer = .{ .horizontal = .auto, .vertical = .none };
    inner = .{};
    try dvui.testing.settle(frame);
    _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = .{ .x = 150, .y = 200 } });
    try swipe(-12, -3);
    try std.testing.expectEqual(@as(f32, 0), inner.viewport.y);
    try std.testing.expect(outer.viewport.x > 0);
    const x = outer.viewport.x;
    try after(200);
    try swipe(-1, -12);
    try std.testing.expectEqual(x, outer.viewport.x);
    try std.testing.expect(inner.viewport.y > 0);
}
