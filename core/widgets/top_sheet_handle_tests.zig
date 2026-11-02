//! Touch pulls on a bar share the sheet with the page, without scrolling the page.
const std = @import("std");
const dvui = @import("dvui");
const glass = @import("glass");
const TopSheet = @import("TopSheet.zig");
const ScrollArea = @import("ScrollArea.zig");

// The test thread and its frame callback own all fixture state.
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
    scale = handle.box.data().borderRectScale().s;
    if (dvui.button(@src(), "Button", .{}, .{ .min_size_content = .{ .w = 80, .h = 40 } })) clicks += 1;
    handle.deinit();
    var area = ScrollArea.initWith(@src(), .{ .scroll_info = &page, .horizontal = .none, .vertical_bar = .hide }, .{ .expand = .both }, .{ .lead = TopSheet.lead(&sheet) });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 100, .h = 20000 } });
    area.deinit();
    offset = page.viewport.y;
    return .ok;
}

fn frame(ms: u64) !void {
    const cw = dvui.currentWindow();
    _ = try testFrame();
    _ = try cw.end(.{});
    try cw.begin(cw.frame_time_ns + @as(i128, ms) * std.time.ns_per_ms);
}

fn reset() !void {
    sheet = .{ .range = 180, .seen_range = 180 };
    page = .{};
    clicks = 0;
    try dvui.testing.settle(testFrame);
    page.viewport.y = 400;
    try dvui.testing.settle(testFrame);
}

fn pointer(action: dvui.Event.Mouse.Action, x: f32, y: f32) !void {
    finger = .{ .x = x, .y = y };
    const cw = dvui.currentWindow();
    _ = try cw.addEventPointer(.{ .button = .touch0, .action = action, .xynorm = .{ .x = x / 300, .y = y / 400 } });
    // A lift accompanies the last sampled position; no extra idle interval is injected.
    glass.input_time.set(cw, cw.event_num, cw.frame_time_ns -
        @as(i128, if (action == .release) 16 else 0) * std.time.ns_per_ms);
    try frame(16);
}

fn move(x: f32, y: f32) !void {
    finger.x += x;
    finger.y += y;
    const cw = dvui.currentWindow();
    _ = try cw.addEventTouchMotion(.touch0, finger.x / 300, finger.y / 400, x / 300, y / 400);
    glass.input_time.set(cw, cw.event_num, cw.frame_time_ns);
    for (dvui.events()) |*e| {
        if (e.evt == .mouse and e.evt.mouse.button == .touch0 and e.evt.mouse.action == .motion) {
            e.evt.mouse.p = .{ .x = finger.x * scale, .y = finger.y * scale };
            e.evt.mouse.action.motion = .{ .x = x * scale, .y = y * scale };
        }
    }
    try frame(16);
}

fn lift() !void {
    try pointer(.release, finger.x, finger.y);
}

fn finish(target: f32) !void {
    for (0..37) |_| try frame(16);
    try std.testing.expectEqual(target, sheet.extent);
    dvui.currentWindow().extra_frames_needed = 0;
    try frame(16);
    try std.testing.expectEqual(@as(u8, 0), dvui.currentWindow().extra_frames_needed);
}

test "a pull on the bar opens the sheet over a scrolled page" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    try reset();
    try pointer(.press, 200, 20);
    for (1..7) |i| {
        try move(0, 15);
        try std.testing.expectEqual(@as(f32, @floatFromInt(i * 15)), sheet.extent);
        try std.testing.expectEqual(@as(f32, 400), offset);
    }
    const l = TopSheet.lead(&sheet);
    try std.testing.expectEqual(@as(f32, 0), l.take(l.ctx, 20));
    try std.testing.expectEqual(@as(f32, 90), sheet.extent);
    try pointer(.press, 200, 20);
    try move(30, 5);
    try std.testing.expectEqual(@as(f32, 90), sheet.extent);
    try lift();
    try pointer(.press, 200, 20);
    try move(0, 15);
    try std.testing.expect(sheet.held);
    // Capture loss also clears ownership when a platform cancels the touch.
    dvui.captureMouse(null, dvui.currentWindow().event_num);
    const cancelled_at = sheet.extent;
    try std.testing.expectEqual(@as(f32, 20), l.take(l.ctx, 20));
    try std.testing.expectEqual(cancelled_at - 20, sheet.extent);
    try std.testing.expect(!sheet.pressed);
    try frame(16);
    try std.testing.expect(!sheet.held);
    try pointer(.press, 200, 20);
    try move(0, 15);
    try lift(); // Native focus loss is delivered as a synthetic touch release too.
    try std.testing.expect(!sheet.held);
    try std.testing.expect(!sheet.pressed);
}

test "a drag that starts on a bar button pulls, and the button does not click" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    try reset();
    try pointer(.press, 30, 20);
    for (0..6) |_| try move(0, 15);
    try std.testing.expectEqual(@as(f32, 90), sheet.extent);
    try std.testing.expectEqual(@as(f32, 400), offset);
    try lift();
    try std.testing.expectEqual(@as(usize, 0), clicks);
    try pointer(.press, 30, 20);
    try lift();
    try std.testing.expectEqual(@as(usize, 1), clicks);
}

test "a release rests by speed, then by place" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    const Case = struct { at: f32, speed: f32, target: f32 };
    for ([_]Case{
        .{ .at = 120, .speed = 0, .target = 180 },
        .{ .at = 50, .speed = 0, .target = 0 },
        .{ .at = 120, .speed = -600, .target = 0 },
        .{ .at = 50, .speed = 600, .target = 180 },
    }) |case| {
        try reset();
        try pointer(.press, 200, 20);
        const delta = case.speed * 0.016;
        try move(0, case.at - delta * 5);
        try frame(100);
        if (case.speed != 0) {
            for (0..5) |_| try move(0, delta);
        }
        try std.testing.expectApproxEqAbs(case.at, sheet.extent, 0.001);
        try lift();
        try std.testing.expectApproxEqAbs(case.speed, sheet.velocity.last_debug.vel, 0.01);
        try finish(case.target);
        try std.testing.expectEqual(@as(f32, 400), offset);
    }
}

test "a tap toggles in one glide" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    try reset();
    try pointer(.press, 200, 20);
    try lift();
    var before: f32 = 0;
    for (0..37) |_| {
        try frame(16);
        try std.testing.expect(sheet.extent >= before);
        try std.testing.expectEqual(@as(f32, 400), offset);
        before = sheet.extent;
    }
    try finish(180);
    try pointer(.press, 200, 20);
    try lift();
    try finish(0);
    glass.motion.publish(0, 0.5, false, false, 1);
    TopSheet.open(&sheet);
    try std.testing.expectEqual(@as(f32, 180), sheet.extent);
    TopSheet.shut(&sheet);
    try std.testing.expectEqual(@as(f32, 0), sheet.extent);
    glass.motion.publish(0.5, 0.5, false, false, 1);
}

test "a page drag stops a handle glide" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    try reset();
    TopSheet.open(&sheet);
    try frame(16);
    try frame(16);
    try pointer(.press, 150, 250);
    // A lead read steps the same frame the page's motion will take over.
    const l = TopSheet.lead(&sheet);
    const before = l.extent(l.ctx);
    try move(0, -30);
    try std.testing.expectEqual(@max(0, before - 30), sheet.extent);
    try std.testing.expectEqual(@as(?f32, null), sheet.target);
}
