//! A top sheet shares a finger's vertical travel with the visible page.
const std = @import("std");
const dvui = @import("dvui");
const ScrollArea = @import("ScrollArea.zig");
const TopSheet = @import("TopSheet.zig");

// The tests and their frame callback write this state on the test thread only.
var sheet: TopSheet.State = .{};
var pages: [2]dvui.ScrollInfo = .{ .{}, .{} };
var page: usize = 0;
var drawn_top: f32 = 0;
var drawn_bottom: f32 = 0;
var viewport_bottom: f32 = 0;
var offset: f32 = 0;
var over: f32 = 0;
var max_y: f32 = 0;
var finger_y: f32 = 0;
var draw_scale: f32 = 1;

fn testFrame() !dvui.App.Result {
    var area = ScrollArea.initWith(@src(), .{ .scroll_info = &pages[page], .horizontal = .none, .vertical_bar = .hide }, .{ .expand = .both }, .{ .lead = TopSheet.lead(&sheet) });
    const child = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 100, .h = 20000 } });
    const rs = child.rectScale();
    draw_scale = rs.s;
    drawn_top = rs.r.y / rs.s;
    drawn_bottom = (rs.r.y + rs.r.h) / rs.s;
    const area_rs = area.data().contentRectScale();
    viewport_bottom = (area_rs.r.y + area_rs.r.h) / area_rs.s;
    over = area.overscroll().y;
    area.deinit();
    offset = pages[page].viewport.y;
    max_y = pages[page].scrollMax(.vertical);
    return .ok;
}

fn reset(extent: f32) void {
    sheet = .{ .extent = extent, .range = 180, .seen_range = 180 };
    pages = .{ .{}, .{} };
    page = 0;
}

fn frameAfter(ms: u64) !void {
    const cw = dvui.currentWindow();
    _ = try testFrame();
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

test "take shuts and opens within the range and returns the length" {
    var state: TopSheet.State = .{ .extent = 30, .range = 180 };
    const lead = TopSheet.lead(&state);
    try std.testing.expectEqual(@as(f32, 30), lead.take(lead.ctx, 50));
    try std.testing.expectEqual(@as(f32, 0), state.extent);
    try std.testing.expectEqual(@as(f32, 180), lead.take(lead.ctx, -500));
    try std.testing.expectEqual(@as(f32, 180), state.extent);
}

test "a range change keeps an open sheet open" {
    var state: TopSheet.State = .{ .extent = 180, .range = 180, .seen_range = 180 };
    const lead = TopSheet.lead(&state);
    state.range = 120;
    try std.testing.expectEqual(@as(f32, 120), lead.extent(lead.ctx));
    state.range = 200;
    try std.testing.expectEqual(@as(f32, 200), lead.extent(lead.ctx));
    state.extent = 50;
    state.range = 40;
    try std.testing.expectEqual(@as(f32, 40), lead.extent(lead.ctx));
    state.range = 0;
    try std.testing.expectEqual(@as(f32, 0), TopSheet.openness(&state));
}

test "a pull at the page top opens the sheet with the finger" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    reset(0);
    try dvui.testing.settle(testFrame);
    try touchDown();
    for (1..7) |i| {
        const before = drawn_top;
        try touchMove(15);
        try std.testing.expectEqual(@as(f32, @floatFromInt(i * 15)), sheet.extent);
        try std.testing.expectEqual(@as(f32, 0), offset);
        try std.testing.expectEqual(@as(f32, 15), drawn_top - before);
    }
    try lift();
}

test "the first move at the top opens the sheet" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    reset(0);
    try dvui.testing.settle(testFrame);
    try touchDown();
    try touchMove(4);
    try std.testing.expectEqual(@as(f32, 4), sheet.extent);
    try touchMove(1);
    try std.testing.expectEqual(@as(f32, 5), sheet.extent);
    var travel: f32 = 5;
    while (travel < 240) {
        const d = @min(@as(f32, 15), 240 - travel);
        const before = drawn_top;
        try touchMove(d);
        travel += d;
        try std.testing.expectEqual(@min(travel, 180), sheet.extent);
        try std.testing.expectEqual(@as(f32, 0), offset);
        if (travel <= 180) try std.testing.expectEqual(d, drawn_top - before);
        if (sheet.extent < 180) try std.testing.expectEqual(@as(f32, 0), over);
    }
}

test "a pull past fully open is the band" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    reset(0);
    try dvui.testing.settle(testFrame);
    try touchDown();
    var prior_over: f32 = 0;
    for (1..17) |i| {
        const before = drawn_top;
        try touchMove(15);
        try std.testing.expectEqual(@min(@as(f32, @floatFromInt(i * 15)), 180), sheet.extent);
        try std.testing.expectEqual(@as(f32, 0), offset);
        try std.testing.expect(drawn_top - before <= 15);
        if (i <= 12) try std.testing.expectEqual(@as(f32, 0), over) else try std.testing.expect(over < prior_over);
        prior_over = over;
    }
}

test "a swipe up shuts the sheet before the page moves" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    reset(180);
    try dvui.testing.settle(testFrame);
    try touchDown();
    for (0..8) |_| {
        const before = drawn_top;
        try touchMove(-15);
        try std.testing.expectEqual(@as(f32, 0), offset);
        try std.testing.expectEqual(@as(f32, -15), drawn_top - before);
    }
    try std.testing.expectEqual(@as(f32, 60), sheet.extent);
    const before = drawn_top;
    try touchMove(-100);
    try std.testing.expectEqual(@as(f32, 0), sheet.extent);
    try std.testing.expectEqual(@as(f32, 40), offset);
    try std.testing.expectEqual(@as(f32, -100), drawn_top - before);
}

test "an open sheet leaves the last row reachable" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    reset(180);
    try dvui.testing.settle(testFrame);
    // The page can also be moved by bars or the wheel while its sheet stays open.
    pages[0].viewport.y = max_y;
    try dvui.testing.settle(testFrame);
    try std.testing.expectEqual(@as(f32, 180), sheet.extent);
    try std.testing.expectEqual(viewport_bottom, drawn_bottom);
    try std.testing.expect(offset >= 0 and offset <= max_y);
    // A finger can reach the end too, shutting the sheet on the way.
    pages[0].viewport.y = 0;
    try dvui.testing.settle(testFrame);
    try touchDown();
    const travel = max_y;
    try touchMoves(-travel, 100);
    try std.testing.expectEqual(@as(f32, 0), sheet.extent);
    try std.testing.expectEqual(viewport_bottom, drawn_bottom);
    try std.testing.expect(offset >= 0 and offset <= max_y);
}

test "one sheet, two pages" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    reset(0);
    try dvui.testing.settle(testFrame);
    try touchDown();
    try touchMoves(180, 15);
    try std.testing.expectEqual(@as(f32, 180), sheet.extent);
    try std.testing.expectEqual(@as(f32, 0), pages[0].viewport.y);
    // Hold long enough that release does not start a coast before changing the visible page.
    for (0..10) |_| try frameAfter(16);
    try lift();
    pages[1] = pages[0];
    pages[1].viewport.y = 300;
    page = 1;
    try dvui.testing.settle(testFrame);
    try std.testing.expectEqual(@as(f32, 180), sheet.extent);
    try std.testing.expectEqual(@as(f32, 0), pages[0].viewport.y);
    try std.testing.expectEqual(@as(f32, 300), pages[1].viewport.y);
}

test "a fast flick shuts the sheet and carries on into the page" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    reset(180);
    try dvui.testing.settle(testFrame);
    try touchDown();
    for (0..3) |_| try touchMove(-20);
    try lift();
    var crossed = false;
    var prior_move: f32 = 20;
    for (0..300) |_| {
        const before = drawn_top;
        const e = sheet.extent;
        try frameAfter(16);
        const moved = @abs(drawn_top - before);
        if (e > 0 and sheet.extent == 0) {
            crossed = true;
            try std.testing.expect(@abs(moved - prior_move) < prior_move * 0.1);
        }
        prior_move = moved;
    }
    try std.testing.expect(crossed);
    try std.testing.expectEqual(@as(f32, 0), sheet.extent);
    try std.testing.expect(offset > 300);
}

test "a coast down from a part-open sheet opens it" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    reset(60);
    try dvui.testing.settle(testFrame);
    try touchDown();
    for (0..3) |_| try touchMove(20);
    try lift();
    for (0..300) |_| try frameAfter(16);
    try std.testing.expectEqual(@as(f32, 180), sheet.extent);
    try std.testing.expectEqual(@as(f32, 0), offset);
    try std.testing.expectEqual(@as(f32, 0), over);
}

test "a coast down a long page does not open the sheet" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    reset(0);
    try dvui.testing.settle(testFrame);
    pages[0].viewport.y = 600;
    try dvui.testing.settle(testFrame);
    try touchDown();
    for (0..3) |_| try touchMove(20);
    try lift();
    var bounced = false;
    for (0..300) |_| {
        try frameAfter(16);
        bounced = bounced or over < 0;
        try std.testing.expectEqual(@as(f32, 0), sheet.extent);
    }
    try std.testing.expect(bounced);
    try std.testing.expectEqual(@as(f32, 0), offset);
    try std.testing.expectEqual(@as(f32, 0), over);
}

test "a pull that catches a coast goes on into the sheet" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    for ([_]f32{ 24, 36 }) |speed| {
        reset(0);
        try dvui.testing.settle(testFrame);
        pages[0].viewport.y = 300;
        try dvui.testing.settle(testFrame);
        try touchDown();
        for (0..4) |_| try touchMove(speed);
        try lift();
        if (speed == 24) {
            try std.testing.expect(offset > 0);
            try touchDown();
            for (0..18) |_| {
                const before = drawn_top;
                try touchMove(20);
                try std.testing.expectEqual(@as(f32, 20), drawn_top - before);
            }
        } else {
            var frames: usize = 0;
            while (over > -20 and frames < 300) : (frames += 1) try frameAfter(16);
            try std.testing.expect(over <= -20);
            const caught = -over;
            const before = drawn_top;
            try touchDown();
            try std.testing.expectEqual(caught, sheet.extent);
            try std.testing.expectEqual(@as(f32, 0), over);
            try std.testing.expectEqual(before, drawn_top);
            try touchMoves(60, 20);
            try std.testing.expectEqual(caught + 60, sheet.extent);
            try std.testing.expectEqual(@as(f32, 0), over);
        }
        for (0..10) |_| try frameAfter(16);
        try lift();
        for (0..300) |_| try frameAfter(16);
    }
}
