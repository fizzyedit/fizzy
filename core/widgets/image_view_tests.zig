//! The image viewer fits what it shows and frees what it made.
const std = @import("std");
const dvui = @import("dvui");
const ImageView = @import("ImageView.zig");

// The tests and their frame callback write this state on the test thread only.
var view: ImageView = .{};
var image: ImageView.Image = undefined;
var viewport: dvui.Rect.Physical = .{};
var image_screen: dvui.Rect.Physical = .{};

fn testFrame() !dvui.App.Result {
    try view.draw(image, .{ .pan_zoom_scheme = .mouse });
    // The canvas has ended; its viewport is the one it kept on the way out.
    viewport = view.canvas.sample_viewport_physical.?;
    image_screen = view.canvas.screenFromDataRect(.{ .w = @floatFromInt(image.width), .h = @floatFromInt(image.height) });
    return .ok;
}

fn solidImage(gpa: std.mem.Allocator, width: u32, height: u32, rgba: [4]u8) ![]u8 {
    const pixels = try gpa.alloc(u8, @as(usize, width) * height * 4);
    for (0..pixels.len / 4) |i| @memcpy(pixels[i * 4 ..][0..4], &rgba);
    return pixels;
}

test "ImageView fits a wide image to its view" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 400 } });
    defer t.deinit();
    const gpa = std.testing.allocator;
    const pixels = try solidImage(gpa, 2000, 1000, .{ 200, 40, 40, 255 });
    defer gpa.free(pixels);
    view = .{};
    view.canvas.id = dvui.Id.extendId(null, @src(), 0);
    defer view.deinit();
    image = .{ .source = .{ .pixels = .{ .rgba = pixels, .width = 2000, .height = 1000 } }, .width = 2000, .height = 1000 };

    try dvui.testing.settle(testFrame);

    try std.testing.expect(viewport.w > 0);
    try std.testing.expect(image_screen.x >= viewport.x - 0.5);
    try std.testing.expect(image_screen.y >= viewport.y - 0.5);
    try std.testing.expect(image_screen.x + image_screen.w <= viewport.x + viewport.w + 0.5);
    try std.testing.expect(image_screen.y + image_screen.h <= viewport.y + viewport.h + 0.5);
    // `CanvasWidget` fits at view / (data × 1.25), so 80 % of the view's width.
    try std.testing.expect(image_screen.w >= 0.75 * viewport.w);
}

test "ImageView frees its checkerboard tile" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 400 } });
    defer t.deinit();
    const gpa = std.testing.allocator;
    const pixels = try solidImage(gpa, 64, 64, .{ 0, 0, 0, 0 });
    defer gpa.free(pixels);
    view = .{};
    view.canvas.id = dvui.Id.extendId(null, @src(), 0);
    image = .{ .source = .{ .pixels = .{ .rgba = pixels, .width = 64, .height = 64 } }, .width = 64, .height = 64 };

    try dvui.testing.settle(testFrame);
    try std.testing.expect(view.checkerboard_tile != null);
    view.deinit();
    try std.testing.expect(view.checkerboard_tile == null);
}
