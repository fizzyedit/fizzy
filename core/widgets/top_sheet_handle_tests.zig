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
var show_handle: bool = true;

fn testFrame() !dvui.App.Result {
    var column = dvui.box(@src(), .{}, .{ .expand = .both });
    defer column.deinit();
    if (show_handle) {
        var handle = TopSheet.Handle.init(@src(), &sheet, .{ .expand = .horizontal, .min_size_content = .{ .h = 60 } });
        scale = handle.box.data().borderRectScale().s;
        if (dvui.button(@src(), "Button", .{}, .{ .min_size_content = .{ .w = 80, .h = 40 } })) clicks += 1;
        handle.deinit();
    }
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
    show_handle = true;
    try dvui.testing.settle(testFrame);
    page.viewport.y = 400;
    try dvui.testing.settle(testFrame);
}

fn pointer(action: dvui.Event.Mouse.Action, x: f32, y: f32) !void {
    finger = .{ .x = x, .y = y };
    const cw = dvui.currentWindow();
    _ = try cw.addEventPointer(.{ .button = .touch0, .action = action, .xynorm = .{ .x = x / 300, .y = y / 400 } });
    glass.input_time.set(cw, cw.event_num, cw.frame_time_ns);
    try frame(16);
}

fn move(x: f32, y: f32, next_ms: u64) !void {
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
    try frame(next_ms);
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
        try move(0, 15, 16);
        try std.testing.expectEqual(@as(f32, @floatFromInt(i * 15)), sheet.extent);
        try std.testing.expectEqual(@as(f32, 400), offset);
    }
    const l = TopSheet.lead(&sheet);
    try std.testing.expectEqual(@as(f32, 0), l.take(l.ctx, 20));
    try std.testing.expectEqual(@as(f32, 90), sheet.extent);
    try pointer(.press, 200, 20);
    try move(30, 5, 16);
    try std.testing.expectEqual(@as(f32, 90), sheet.extent);
    try lift();
    try pointer(.press, 200, 20);
    try move(0, 15, 16);
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
    try move(0, 15, 16);
    try lift(); // Native focus loss is delivered as a synthetic touch release too.
    try std.testing.expect(!sheet.held);
    try std.testing.expect(!sheet.pressed);
    // A cancelled press below the threshold must not become a pull on later motion.
    try pointer(.press, 200, 20);
    try move(0, 1, 16);
    try std.testing.expect(sheet.pressed);
    try std.testing.expect(!sheet.held);
    dvui.captureMouse(null, dvui.currentWindow().event_num);
    const before_cancel = sheet.extent;
    _ = l.extent(l.ctx);
    try std.testing.expect(!sheet.pressed);
    try move(0, 15, 16);
    try std.testing.expectEqual(before_cancel, sheet.extent);
}

test "a cancelled bar drag lets the page move the sheet" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    for (0..4) |cancel| {
        try reset();
        try pointer(.press, 200, 20);
        try move(0, 60, 16);
        try std.testing.expect(sheet.held);
        const l = TopSheet.lead(&sheet);
        if (cancel == 0) {
            dvui.captureMouse(null, dvui.currentWindow().event_num);
        } else if (cancel == 1) {
            // Native focus loss delivers a synthetic release for each active touch.
            try lift();
        } else if (cancel == 2) {
            show_handle = false;
            // Capture expires at begin after a whole frame without its widget.
            try frame(16);
            try frame(16);
        } else {
            // Another finger retaining the same handle must not keep this drag alive.
            const cw = dvui.currentWindow();
            const capture = dvui.captureMouseGet();
            _ = try cw.addEventPointer(.{ .button = .touch1, .action = .press, .xynorm = .{ .x = 0.7, .y = 0.05 } });
            dvui.captureMouseCustom(capture, cw.event_num);
            _ = try cw.addEventPointer(.{ .button = .touch0, .action = .release });
            dvui.captureMouse(null, cw.event_num);
        }
        const before = l.extent(l.ctx);
        try std.testing.expect(!sheet.held);
        try std.testing.expect(!sheet.pressed);
        try std.testing.expectEqual(@as(f32, 20), l.take(l.ctx, 20));
        try std.testing.expectEqual(before - 20, sheet.extent);
        try pointer(.press, 150, 250);
        const before_page_pull = sheet.extent;
        try move(0, -15, 16);
        try std.testing.expectEqual(before_page_pull - 15, sheet.extent);
        try std.testing.expectEqual(@as(f32, 400), offset);
        try lift();
    }
}

test "a drag that starts on a bar button pulls, and the button does not click" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    for ([_]bool{ false, true }) |slow_start| {
        try reset();
        try pointer(.press, 30, 20);
        // Held travel includes motion below the threshold before the button yields capture.
        if (slow_start) {
            try move(0, 1, 16);
            try std.testing.expectEqual(@as(f32, 0), sheet.extent);
        }
        try move(0, if (slow_start) 14 else 15, 16);
        try std.testing.expectEqual(@as(f32, 15), sheet.extent);
        try std.testing.expectEqual(@as(f32, 400), offset);
        for (2..7) |i| {
            try move(0, 15, 16);
            try std.testing.expectEqual(@as(f32, @floatFromInt(i * 15)), sheet.extent);
            try std.testing.expectEqual(@as(f32, 400), offset);
        }
        try lift();
        try std.testing.expectEqual(@as(usize, 0), clicks);
        try pointer(.press, 30, 20);
        try lift();
        try std.testing.expectEqual(@as(usize, 1), clicks);
    }
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
        try move(0, case.at - delta * 5, 16);
        try frame(100);
        if (case.speed != 0) {
            // Five 16 ms moves, then 16 ms stationary before lift. The 50 ms
            // window contains 34 ms of motion, including an interpolated sample.
            for (0..5) |_| try move(0, delta, 16);
        }
        try std.testing.expectApproxEqAbs(case.at, sheet.extent, 0.001);
        try lift();
        try std.testing.expectApproxEqAbs(case.speed * 34 / 50, sheet.velocity.last_debug.vel, 0.01);
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
    TopSheet.open(&sheet);
    try frame(16);
    try frame(16);
    const before_reverse = sheet.extent;
    TopSheet.shut(&sheet);
    // Reversing before either widget draws must first advance to this frame.
    try std.testing.expect(sheet.extent > before_reverse);
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
    try move(0, -30, 16);
    try std.testing.expectEqual(@max(0, before - 30), sheet.extent);
    try std.testing.expectEqual(@as(?f32, null), sheet.target);
}
