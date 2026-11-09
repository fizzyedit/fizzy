//! Pictures grow from their thumbnails on real frames at each motion level.
const std = @import("std");
const dvui = @import("dvui");
const backend = @import("glass");
const ImageViewer = @import("ImageViewer.zig");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;

const content: dvui.Rect.Natural = .{ .x = 100, .y = 50, .w = 400, .h = 600 };
const thumb: dvui.Rect.Natural = .{ .x = 140, .y = 400, .w = 60, .h = 40 };
var viewer: ImageViewer = .{};
var level: f32 = 1;
var shown: dvui.Rect.Natural = .{};

fn frame(step_ms: i128) !void {
    backend.motion.publish(level, 0.5, false, false, 1);
    try viewer.draw(content, .{ .pan_zoom_scheme = .mouse });
    const cw = dvui.currentWindow();
    const stack = cw.subwindows.stack.items;
    if (viewer.isOpen()) shown = .cast(stack[1].rect);
    _ = try cw.end(.{});
    try cw.begin(cw.frame_time_ns + step_ms * std.time.ns_per_ms);
}

fn setup(pixels: []u8, motion_level: f32) !void {
    backend.LiquidField.readyInTest(true);
    level = motion_level;
    viewer = .{};
    @memset(pixels, 255);
    viewer.openFrom(.{ .source = .{ .pixels = .{ .rgba = pixels, .width = 300, .height = 200 } }, .width = 300, .height = 200 }, thumb);
    try frame(16);
}

fn untilRest() !dvui.Size {
    var largest: dvui.Size = .{ .w = shown.w, .h = shown.h };
    var frames: usize = 0;
    while (viewer.isOpen() and (viewer.morph.center.moving or viewer.morph.size.moving)) : (frames += 1) {
        try expect(frames < 300);
        try frame(16);
        largest = .{ .w = @max(largest.w, shown.w), .h = @max(largest.h, shown.h) };
    }
    return largest;
}

test "a picture opened from its thumbnail grows out of it, swings past and lands" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 700 } });
    defer t.deinit();
    const pixels = try std.testing.allocator.alloc(u8, 300 * 200 * 4);
    defer std.testing.allocator.free(pixels);
    defer viewer.deinit();
    try setup(pixels, 1);
    try equal(thumb, shown);
    const largest = try untilRest();
    try expect(largest.w > 1.02 * content.w);
    try expect(largest.h > 1.02 * content.h);
    try frame(16);
    try equal(content, shown);
}

test "closing shrinks the picture back into its thumbnail" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 700 } });
    defer t.deinit();
    const pixels = try std.testing.allocator.alloc(u8, 300 * 200 * 4);
    defer std.testing.allocator.free(pixels);
    defer viewer.deinit();
    try setup(pixels, 0.5);
    _ = try untilRest();
    viewer.close();
    try frame(16);
    try expect(viewer.isOpen());
    var smallest = shown.w;
    var frames: usize = 0;
    while (viewer.isOpen()) : (frames += 1) {
        try expect(frames < 300);
        try frame(16);
        smallest = @min(smallest, shown.w);
    }
    try expect(smallest < thumb.w + 1);
}

test "at minimal a picture never grows past its rect" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 700 } });
    defer t.deinit();
    const pixels = try std.testing.allocator.alloc(u8, 300 * 200 * 4);
    defer std.testing.allocator.free(pixels);
    defer viewer.deinit();
    try setup(pixels, 0.5);
    const largest = try untilRest();
    try expect(largest.w <= content.w + 0.01);
    try expect(largest.h <= content.h + 0.01);
    try frame(16);
    try equal(content, shown);
}

test "with motion off a picture opens and closes at once" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 700 } });
    defer t.deinit();
    const pixels = try std.testing.allocator.alloc(u8, 300 * 200 * 4);
    defer std.testing.allocator.free(pixels);
    defer viewer.deinit();
    try setup(pixels, 0);
    try equal(content, shown);
    viewer.close();
    try frame(16);
    try expect(!viewer.isOpen());
}
