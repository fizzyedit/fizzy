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

fn pageFrame() !dvui.App.Result {
    var area = ScrollArea.init(@src(), .{ .scroll_info = &inner, .vertical_bar = .hide }, .{ .expand = .both });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 100, .h = 4000 } });
    area.deinit();
    return .ok;
}

fn pageAfter(ms: i128) !void {
    const win = dvui.currentWindow();
    _ = try pageFrame();
    _ = try win.end(.{});
    try win.begin(win.frame_time_ns + ms * std.time.ns_per_ms);
}

/// How far a finger flick up the screen and its coast carry the page, two seconds on.
fn flickTravel() !f32 {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    inner = .{};
    try dvui.testing.settle(pageFrame);
    const win = dvui.currentWindow();
    const h = win.data().rect.h;
    const x = 0.5;
    var y: f32 = 0.8;
    _ = try win.addEventPointer(.{ .button = .touch0, .action = .press, .xynorm = .{ .x = x, .y = y } });
    try pageAfter(16);
    for (0..10) |_| {
        _ = try win.addEventTouchMotion(.touch0, x, y - 10 / h, 0, -10 / h);
        y -= 10 / h;
        try pageAfter(16);
    }
    _ = try win.addEventPointer(.{ .button = .touch0, .action = .release, .xynorm = .{ .x = x, .y = y } });
    try pageAfter(16);
    const at_release = inner.viewport.y;
    for (0..120) |_| try pageAfter(16);
    return inner.viewport.y - at_release;
}

test "feel change reaches the next coast" {
    defer ScrollArea.feel = .default;
    ScrollArea.feel = .default;
    const default_travel = try flickTravel();
    ScrollArea.feel.coast.decay *= 2;
    const braked_travel = try flickTravel();
    try std.testing.expect(braked_travel > 0);
    try std.testing.expect(braked_travel < default_travel * 0.75);
}

test "default equals the old constants" {
    const d = ScrollArea.Feel.default;
    try std.testing.expectEqual(@as(f32, 2.0), d.coast.decay);
    try std.testing.expectEqual(@as(f32, 80.0), d.coast.min_start);
    try std.testing.expectEqual(@as(f32, 20.0), d.coast.stop);
    try std.testing.expectEqual(@as(f32, 8000.0), d.coast.max);
    try std.testing.expectEqual(@as(f32, 0.08), d.coast.idle_s);
    try std.testing.expectEqual(@TypeOf(d.coast.edge){}, d.coast.edge);
    try std.testing.expectEqual(@as(f32, 3), d.seat.hz);
    try std.testing.expectEqual(@as(f32, 1), d.seat.playful_damping);
    try std.testing.expectEqual(@as(f32, 0.1), d.window_s);
    try std.testing.expectEqual(@as(f32, 0.05), d.glide_tau_s);
}
