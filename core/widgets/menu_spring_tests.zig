//! Every menu grows out of what opened it on the reference spring (`core.Spring.Tune.playful`),
//! on real frames, at each motion level.
const std = @import("std");
const dvui = @import("dvui");
const glass = @import("../glass.zig");
const backend = @import("glass");
const widgets = @import("../widgets.zig");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;

const button: dvui.Rect.Natural = .{ .x = 40, .y = 30, .w = 60, .h = 24 };
var from: dvui.Rect.Natural = button;
var level: f32 = 1;
var natural: dvui.Rect.Natural = .{};
var placed: dvui.Rect.Natural = .{};
var moving = false;

fn draw() void {
    var menu = widgets.floatingMenu(@src(), .{ .from = from, .frost = .{} }, .{ .corners = .round(6) });
    natural = .cast(menu.wd.rect);
    moving = menu.revealing;
    if (dvui.dataGet(null, menu.wd.id, "_morph", glass.Morph)) |m| placed = m.to.rect.scale(1 / dvui.windowNaturalScale(), dvui.Rect.Natural);
    for (0..3) |i| {
        var row = widgets.menuItem(@src(), .{}, .{ .id_extra = i, .min_size_content = .{ .w = 140, .h = 24 } });
        row.deinit();
    }
    menu.deinit();
}

fn frame(step_ms: i128) !void {
    backend.motion.publish(level, 0.5, false, false, 1);
    draw();
    const cw = dvui.currentWindow();
    _ = try cw.end(.{});
    try cw.begin(cw.frame_time_ns + step_ms * std.time.ns_per_ms);
}

fn setup(at: dvui.Rect.Natural, motion_level: f32) void {
    backend.LiquidField.readyInTest(true);
    from = at;
    level = motion_level;
    moving = false;
    placed = .{};
}

test "a menu opened from a button grows out of it, swings past and lands" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 300 } });
    defer t.deinit();
    setup(button, 1);
    try frame(16); // Measure the rows before starting the spring.
    try frame(16);
    try equal(button, natural);
    var max: dvui.Size = .{};
    var frames: usize = 0;
    while (moving) : (frames += 1) {
        try expect(frames < 300);
        try frame(16);
        max = .{ .w = @max(max.w, natural.w), .h = @max(max.h, natural.h) };
    }
    try expect(max.w > 1.05 * placed.w);
    try expect(max.h > 1.05 * placed.h);
    try equal(placed, natural);
}

test "a context menu grows out of the pointer" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 300 } });
    defer t.deinit();
    const pointer: dvui.Rect.Natural = .fromPoint(.{ .x = 120, .y = 90 });
    setup(pointer, 1);
    try frame(16);
    try frame(16);
    try equal(pointer, natural);
    try expect(moving);
}

test "at minimal a menu never grows past its size" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 300 } });
    defer t.deinit();
    setup(button, 0.5);
    try frame(16);
    try frame(16);
    try expect(moving);
    var frames: usize = 0;
    while (moving) : (frames += 1) {
        try expect(frames < 300);
        try frame(16);
        try expect(natural.w <= placed.w + 0.01);
        try expect(natural.h <= placed.h + 0.01);
    }
    try equal(placed, natural);
}

/// The menu's height on each of `heights.len` frames `step_ms` apart, from the one that starts it.
fn openHeights(step_ms: i128, heights: []f32) !void {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 300 } });
    defer t.deinit();
    setup(button, 1);
    try frame(step_ms); // Measure the rows before starting the spring.
    for (heights) |*h| {
        try frame(step_ms);
        h.* = natural.h;
    }
}

test "a menu opens the same at 60 and 120 frames a second" {
    var at60: [40]f32 = undefined;
    var at120: [80]f32 = undefined;
    try openHeights(16, &at60);
    try openHeights(8, &at120);
    for (at60, 0..) |h, i| try expect(@abs(h - at120[2 * i]) <= 0.5);
}
