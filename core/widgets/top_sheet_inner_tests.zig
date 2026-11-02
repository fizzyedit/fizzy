//! Inner content crosses the sheet seam without moving the page.
const std = @import("std");
const dvui = @import("dvui");
const ScrollArea = @import("ScrollArea.zig");
const TopSheet = @import("TopSheet.zig");

var sheet: TopSheet.State = .{};
var content: dvui.ScrollInfo = .{};
var page: dvui.ScrollInfo = .{};
var finger_y: f32 = 0;
var draw_scale: f32 = 1;
var over: f32 = 0;

fn testFrame() !dvui.App.Result {
    var inner = ScrollArea.initWith(@src(), .{ .scroll_info = &content, .horizontal = .none, .vertical_bar = .hide }, .{ .min_size_content = .{ .h = 200 }, .max_size_content = .{ .w = dvui.max_float_safe, .h = 200 }, .expand = .horizontal }, .{ .lead = TopSheet.inner(&sheet) });
    const child = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 100, .h = 1000 } });
    draw_scale = child.rectScale().s;
    over = inner.overscroll().y;
    inner.deinit();
    var below = ScrollArea.initWith(@src(), .{ .scroll_info = &page, .horizontal = .none, .vertical_bar = .hide }, .{ .expand = .both }, .{ .lead = TopSheet.lead(&sheet) });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 100, .h = 2000 } });
    below.deinit();
    return .ok;
}

fn start(y: f32) !void {
    sheet = .{ .extent = 180, .range = 180, .seen_range = 180 };
    content = .{};
    page = .{};
    try dvui.testing.settle(testFrame);
    content.viewport.y = y;
    try dvui.testing.settle(testFrame);
    try std.testing.expectEqual(@as(f32, 800), content.scrollMax(.vertical));
    try touchDown();
}

fn frameAfter(ms: u64) !void {
    const cw = dvui.currentWindow();
    _ = try testFrame();
    try std.testing.expectEqual(@as(f32, 0), page.viewport.y);
    _ = try cw.end(.{});
    try cw.begin(cw.frame_time_ns + @as(i128, ms) * std.time.ns_per_ms);
}

fn touchDown() !void {
    finger_y = 80;
    _ = try dvui.currentWindow().addEventPointer(.{ .button = .touch0, .action = .press, .xynorm = .{ .x = 0.5, .y = finger_y / 400 } });
    try frameAfter(16);
}

fn touchMove(by: f32) !void {
    finger_y += by;
    _ = try dvui.currentWindow().addEventTouchMotion(.touch0, 0.5, finger_y / 400, 0, by / 400);
    // Supply exact physical points: normalization through 400 otherwise rounds a 15 pt delta.
    for (dvui.events()) |*e| {
        if (e.evt == .mouse and e.evt.mouse.button == .touch0 and e.evt.mouse.action == .motion) {
            e.evt.mouse.p.y = finger_y * draw_scale;
            e.evt.mouse.action.motion.y = by * draw_scale;
        }
    }
    try frameAfter(16);
}

fn touchMoves(by: f32, step: f32) !void {
    var left = @abs(by);
    while (left > 0) {
        const d = std.math.copysign(@min(left, step), by);
        try touchMove(d);
        left -= @abs(d);
    }
}

fn lift() !void {
    _ = try dvui.currentWindow().addEventPointer(.{ .button = .touch0, .action = .release, .xynorm = .{ .x = 0.5, .y = finger_y / 400 } });
    try frameAfter(16);
}

fn upTo130() !void {
    try start(750);
    for (0..5) |_| {
        try touchMove(-20);
        try std.testing.expectEqual(@as(f32, 0), page.viewport.y);
    }
    try std.testing.expectEqual(@as(f32, 800), content.viewport.y);
    try std.testing.expectEqual(@as(f32, 130), sheet.extent);
}

test "the inner content scrolls first, then shuts the sheet" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    try upTo130();
}

test "a drag back down reopens before the content scrolls back" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    try upTo130();
    try touchMoves(40, 20);
    try touchMove(10);
    try std.testing.expectEqual(@as(f32, 180), sheet.extent);
    try std.testing.expectEqual(@as(f32, 800), content.viewport.y);
    try touchMoves(30, 20);
    try std.testing.expectEqual(@as(f32, 770), content.viewport.y);
    try std.testing.expectEqual(@as(f32, 0), page.viewport.y);
}

test "a coast inside stops at the end and never shuts" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    try start(500);
    for (0..3) |_| try touchMove(-24);
    try lift();
    var banded = false;
    for (0..300) |_| {
        try frameAfter(16);
        banded = banded or over > 0;
        try std.testing.expectEqual(@as(f32, 180), sheet.extent);
        try std.testing.expectEqual(@as(f32, 0), page.viewport.y);
    }
    try std.testing.expect(banded);
    try std.testing.expectEqual(@as(f32, 800), content.viewport.y);
    try std.testing.expectEqual(@as(f32, 0), over);
}

test "let go half shut, it settles" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    for ([_][2]f32{ .{ 120, 180 }, .{ 50, 0 } }) |case| {
        try start(750);
        try touchMoves(-(50 + 180 - case[0]), 20);
        try std.testing.expectEqual(case[0], sheet.extent);
        try frameAfter(200);
        try lift();
        for (0..37) |_| try frameAfter(16);
        try std.testing.expectEqual(case[1], sheet.extent);
        try std.testing.expectEqual(@as(f32, 800), content.viewport.y);
        dvui.currentWindow().extra_frames_needed = 0;
        try frameAfter(0);
        try std.testing.expectEqual(@as(u8, 0), dvui.currentWindow().extra_frames_needed);
    }
}
