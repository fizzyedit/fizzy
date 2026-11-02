//! Widget motion on real 16 ms frames, observed at glass replay.
const std = @import("std");
const dvui = @import("dvui");
const glass = @import("../glass.zig");
const backend = @import("glass");
const widgets = @import("../widgets.zig");
const Glass = @import("Glass.zig");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const source: dvui.Rect.Physical = .{ .x = 20, .y = 20, .w = 40, .h = 40 };
var morph: ?Glass.MorphOptions = null;
var width: f32 = 200;
var laid_out: dvui.Rect.Physical = .{};
var moving = false;
var menu_rect: dvui.Rect.Natural = .{};
var placed: dvui.Rect.Natural = .{};
var radius: f32 = 0;
var alpha: f32 = 0;
var level: f32 = 1;

fn glassFrame() void {
    const scale = dvui.windowNaturalScale();
    var g = Glass.init(@src(), .{ .morph = morph }, .{
        .rect = (dvui.Rect.Physical{ .x = 100, .y = 80, .w = width, .h = 120 }).scale(1 / scale, dvui.Rect),
        .corners = .round(12 / scale),
    });
    g.install();
    laid_out = g.data().borderRectScale().r;
    if (dvui.dataGet(null, g.data().id, "_morph", glass.Morph)) |m| moving = m.center.moving or m.size.moving;
    g.deinit();
}

fn menuFrame() void {
    var menu = widgets.floatingMenu(@src(), .{
        .grow_from = .{ .x = 20, .y = 20, .w = 40, .h = 24 },
        .frost = .{},
    }, .{ .corners = .round(6) });
    menu_rect = .cast(menu.wd.rect);
    moving = menu.revealing;
    if (menu.grown) |g| {
        radius = g.radius;
        alpha = g.alpha;
    }
    if (dvui.dataGet(null, menu.wd.id, "_morph", glass.Morph)) |m| placed = m.to.rect.scale(1 / dvui.windowNaturalScale(), dvui.Rect.Natural);
    for (0..3) |i| {
        var row = widgets.menuItem(@src(), .{}, .{ .id_extra = i, .min_size_content = .{ .w = 140, .h = 24 } });
        row.deinit();
    }
    menu.deinit();
}

fn frame(comptime draw: fn () void) !void {
    backend.motion.publish(level, 0.5, false, false, 1);
    draw();
    const cw = dvui.currentWindow();
    _ = try cw.end(.{});
    try cw.begin(cw.frame_time_ns + 16 * std.time.ns_per_ms);
}

fn setup() void {
    backend.LiquidField.readyInTest(true);
    morph = null;
    width = 200;
    level = 1;
    moving = false;
    alpha = -1;
}

fn settle(comptime draw: fn () void) !void {
    for (0..300) |_| {
        try frame(draw);
        if (!moving) return;
    }
    return error.WidgetDidNotSettle;
}

test "a Glass without morph draws its laid-out box" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 300 } });
    defer t.deinit();
    setup();
    try frame(glassFrame);
    try equal(laid_out, glass.drawnRects()[0]);
}

test "a Glass grows out of its source and lands exactly" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 300 } });
    defer t.deinit();
    setup();
    morph = .{ .from = source };
    try frame(glassFrame);
    try equal(source, glass.drawnRects()[0]);
    try expect(moving);
    try settle(glassFrame);
    try equal(laid_out, glass.drawnRects()[0]);
    try equal(@as([4]f32, @splat(12)), glass.drawnDetails().radii[0]);
    dvui.currentWindow().extra_frames_needed = 0;
    try frame(glassFrame);
    try equal(@as(u8, 0), dvui.currentWindow().extra_frames_needed);
}

test "a Glass follows a layout change on the spring" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 300 } });
    defer t.deinit();
    setup();
    morph = .{};
    try settle(glassFrame);
    width = 300;
    try frame(glassFrame);
    try equal(@as(f32, 200), glass.drawnRects()[0].w);
    try frame(glassFrame);
    try expect(glass.drawnRects()[0].w > 200 and glass.drawnRects()[0].w < 300);
    try settle(glassFrame);
    try equal(@as(f32, 300), glass.drawnRects()[0].w);
}

test "a menu grows out of its button and lands" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 300 } });
    defer t.deinit();
    setup();
    try frame(menuFrame); // Measure the rows before starting the spring.
    try frame(menuFrame);
    try equal(dvui.Rect.Natural{ .x = 20, .y = 20, .w = 40, .h = 24 }, menu_rect);
    try equal(@as(f32, 12), radius);
    try expect(moving);
    try frame(menuFrame);
    try expect(radius < 12 and radius > 6);
    try settle(menuFrame);
    try equal(placed, menu_rect);
    try equal(@as(f32, 6), radius);
    try expect(!moving);
    try equal(@as(f32, 1), alpha);
}

test "motion off: the menu appears at once" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 300 } });
    defer t.deinit();
    setup();
    level = 0;
    try frame(menuFrame);
    try frame(menuFrame);
    try equal(placed, menu_rect);
    try expect(!moving);
    try equal(@as(f32, 1), alpha);
}
