//! Handle touch routing and its finite rest, against a scrolled page.
const std = @import("std");
const dvui = @import("dvui");
const glass = @import("glass");
const TopSheet = @import("TopSheet.zig");
const ScrollArea = @import("ScrollArea.zig");

var sheet: TopSheet.State = .{};
var page: dvui.ScrollInfo = .{};
var offset: f32 = 0;
var clicks: usize = 0;
var finger: dvui.Point = .{};
var scale: f32 = 1;

fn testFrame() !dvui.App.Result {
    var column = dvui.box(@src(), .{}, .{ .expand = .both });
    defer column.deinit();
    var handle = TopSheet.Handle.init(@src(), &sheet, .{ .expand = .horizontal, .min_size_content = .{ .h = 60 } });
    scale = handle.box.data().rectScale().s;
    if (dvui.button(@src(), "Button", .{}, .{ .min_size_content = .{ .w = 80, .h = 30 } })) clicks += 1;
    handle.deinit();
    var area = ScrollArea.initWith(@src(), .{ .scroll_info = &page, .horizontal = .none, .vertical_bar = .hide }, .{ .expand = .both }, .{ .lead = TopSheet.lead(&sheet) });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 100, .h = 20000 } });
    area.deinit();
    offset = page.viewport.y;
    return .ok;
}

fn frameAfter(ms: u64) !void {
    const cw = dvui.currentWindow();
    _ = try testFrame();
    _ = try cw.end(.{});
    try cw.begin(cw.frame_time_ns + @as(i128, ms) * std.time.ns_per_ms);
}

fn reset(e: f32) !void {
    sheet = .{ .extent = e, .range = 180, .seen_range = 180 };
    page = .{};
    clicks = 0;
    try dvui.testing.settle(testFrame);
    page.viewport.y = 400;
    try dvui.testing.settle(testFrame);
}

fn press(x: f32, y: f32) !void {
    finger = .{ .x = x, .y = y };
    _ = try dvui.currentWindow().addEventPointer(.{ .button = .touch0, .action = .press, .xynorm = .{ .x = x / 300, .y = y / 400 } });
    try frameAfter(16);
}

fn move(x: f32, y: f32) !void {
    finger.x += x;
    finger.y += y;
    _ = try dvui.currentWindow().addEventTouchMotion(.touch0, finger.x / 300, finger.y / 400, x / 300, y / 400);
    for (dvui.events()) |*e| {
        if (e.evt == .mouse and e.evt.mouse.action == .motion and e.evt.mouse.button == .touch0) {
            e.evt.mouse.p = finger.scale(scale, dvui.Point.Physical);
            e.evt.mouse.action.motion = (dvui.Point{ .x = x, .y = y }).scale(scale, dvui.Point.Physical);
        }
    }
    try frameAfter(16);
}

fn lift() !void {
    _ = try dvui.currentWindow().addEventPointer(.{ .button = .touch0, .action = .release, .xynorm = .{ .x = finger.x / 300, .y = finger.y / 400 } });
    try frameAfter(16);
}

fn finish(target: f32) !void {
    for (0..36) |_| try frameAfter(16);
    try std.testing.expectEqual(target, sheet.extent);
    try dvui.testing.settle(testFrame);
    dvui.currentWindow().extra_frames_needed = 0;
    try frameAfter(16);
    try std.testing.expectEqual(@as(u8, 0), dvui.currentWindow().extra_frames_needed);
}

test "a pull on the bar opens the sheet over a scrolled page" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    try reset(0);
    try press(200, 20);
    for (1..7) |i| {
        try move(0, 15);
        try std.testing.expectEqual(@as(f32, @floatFromInt(i * 15)), sheet.extent);
        try std.testing.expectEqual(@as(f32, 400), offset);
    }
    const l = TopSheet.lead(&sheet);
    try std.testing.expectEqual(@as(f32, 0), l.take(l.ctx, 20));
    try std.testing.expectEqual(@as(f32, 90), sheet.extent);
    try press(200, 20);
    try move(30, 5);
    try std.testing.expectEqual(@as(f32, 90), sheet.extent);
}

test "a drag that starts on a bar button pulls, and the button does not click" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    try reset(0);
    try press(30, 15);
    for (0..6) |_| try move(0, 15);
    try std.testing.expectEqual(@as(f32, 90), sheet.extent);
    try lift();
    try std.testing.expectEqual(@as(usize, 0), clicks);
    try reset(0);
    try press(30, 15);
    try lift();
    try std.testing.expectEqual(@as(usize, 1), clicks);
    try std.testing.expectEqual(@as(f32, 0), sheet.extent);
    try std.testing.expect(sheet.target == null);
}

test "a release rests by speed, then by place" {
    const Case = struct { e: f32, speed: f32, target: f32 };
    for ([_]Case{
        .{ .e = 120, .speed = 0, .target = 180 },
        .{ .e = 50, .speed = 0, .target = 0 },
        .{ .e = 120, .speed = -600, .target = 0 },
        .{ .e = 50, .speed = 600, .target = 180 },
    }) |case| {
        var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
        defer t.deinit();
        try reset(case.e);
        try press(200, 40);
        if (case.speed == 0) {
            try move(0, 5);
            sheet.extent = case.e;
            for (0..6) |_| try frameAfter(16);
        } else {
            for (0..4) |_| try move(0, case.speed * 0.016);
            sheet.extent = case.e;
        }
        try lift();
        try finish(case.target);
    }
}

test "a tap toggles in one glide" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    try reset(0);
    try press(200, 20);
    try lift();
    var prior: f32 = 0;
    for (0..36) |_| {
        try frameAfter(16);
        try std.testing.expect(sheet.extent >= prior);
        try std.testing.expectEqual(@as(f32, 400), offset);
        prior = sheet.extent;
    }
    try std.testing.expectEqual(@as(f32, 180), sheet.extent);
    try press(200, 20);
    try lift();
    try finish(0);
    try std.testing.expectEqual(@as(f32, 400), offset);
    glass.motion.publish(0, 0.5, false, false, 1);
    TopSheet.open(&sheet);
    try std.testing.expectEqual(@as(f32, 180), sheet.extent);
    TopSheet.shut(&sheet);
    try std.testing.expectEqual(@as(f32, 0), sheet.extent);
    try std.testing.expect(sheet.target == null);
}

test "a page drag stops a handle glide" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    try reset(0);
    TopSheet.open(&sheet);
    try frameAfter(16);
    try frameAfter(16);
    try press(200, 250);
    // Account for this frame's step before measuring the page's take.
    const l = TopSheet.lead(&sheet);
    const before = l.extent(l.ctx);
    try move(0, -30);
    try std.testing.expectEqual(before - 30, sheet.extent);
    try std.testing.expect(sheet.target == null);
}
