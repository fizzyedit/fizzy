//! The image viewer sits over the rect it is given, keeps taps from what is under it, and closes on
//! Esc and on its bubble.
const std = @import("std");
const dvui = @import("dvui");
const ImageView = @import("ImageView.zig");
const ImageViewer = @import("ImageViewer.zig");
const glass_button = @import("glass_button.zig");

// The tests and their frame callback write this state on the test thread only.
var viewer: ImageViewer = .{};
var content: dvui.Rect.Natural = .{ .x = 100, .y = 50, .w = 400, .h = 600 };
var floating_rect: ?dvui.Rect = null;
var under_clicks: u32 = 0;

fn testFrame() !dvui.App.Result {
    if (dvui.button(@src(), "Under", .{}, .{ .expand = .both })) under_clicks += 1;
    try viewer.draw(content, .{ .pan_zoom_scheme = .mouse });
    // The first subwindow above the base one is the viewer's: its bubbles come after it.
    const stack = dvui.currentWindow().subwindows.stack.items;
    floating_rect = if (viewer.isOpen() and stack.len > 1) stack[1].rect else null;
    return .ok;
}

fn solidImage(gpa: std.mem.Allocator, width: u32, height: u32, rgba: [4]u8) ![]u8 {
    const pixels = try gpa.alloc(u8, @as(usize, width) * height * 4);
    for (0..pixels.len / 4) |i| @memcpy(pixels[i * 4 ..][0..4], &rgba);
    return pixels;
}

/// A click at `pt` (natural), then frames until the fades are over.
fn clickAt(pt: dvui.Point.Natural) !void {
    const cw = dvui.currentWindow();
    _ = try cw.addEventMouseMotion(.{ .pt = dvui.windowRectScale().pointToPhysical(.cast(pt)) });
    try dvui.testing.click(.left);
    try dvui.testing.settle(testFrame);
}

fn openTestImage(pixels: []u8) !void {
    viewer = .{};
    under_clicks = 0;
    viewer.open(.{ .source = .{ .pixels = .{ .rgba = pixels, .width = 300, .height = 200 } }, .width = 300, .height = 200 });
    try dvui.testing.settle(testFrame);
}

test "ImageViewer opens over its rect and closes on Esc" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 700 } });
    defer t.deinit();
    const gpa = std.testing.allocator;
    const pixels = try solidImage(gpa, 300, 200, .{ 40, 120, 200, 255 });
    defer gpa.free(pixels);
    defer viewer.deinit();
    try openTestImage(pixels);

    try std.testing.expect(viewer.isOpen());
    try std.testing.expectEqual(@as(dvui.Rect, .cast(content)), floating_rect.?);

    try dvui.testing.pressKey(.escape, .none);
    // Each step is 100 ms: three are past the 180 ms fade.
    for (0..3) |_| _ = try dvui.testing.step(testFrame);
    try dvui.testing.settle(testFrame);
    try std.testing.expect(!viewer.isOpen());
}

test "ImageViewer keeps taps from the content under it" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 700 } });
    defer t.deinit();
    const gpa = std.testing.allocator;
    const pixels = try solidImage(gpa, 300, 200, .{ 40, 120, 200, 255 });
    defer gpa.free(pixels);
    defer viewer.deinit();

    // Closed, the click reaches the button: the click itself is sound.
    viewer = .{};
    try dvui.testing.settle(testFrame);
    try clickAt(content.center());
    try std.testing.expectEqual(@as(u32, 1), under_clicks);

    try openTestImage(pixels);
    try clickAt(content.center());
    try std.testing.expect(viewer.isOpen());
    try std.testing.expectEqual(@as(u32, 0), under_clicks);
}

test "ImageViewer close button closes it" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 700 } });
    defer t.deinit();
    const gpa = std.testing.allocator;
    const pixels = try solidImage(gpa, 300, 200, .{ 40, 120, 200, 255 });
    defer gpa.free(pixels);
    defer viewer.deinit();
    try openTestImage(pixels);

    const half = glass_button.size / 2;
    try clickAt(.{ .x = content.x + content.w - 10 - half, .y = content.y + 10 + half });
    for (0..3) |_| _ = try dvui.testing.step(testFrame);
    try dvui.testing.settle(testFrame);
    try std.testing.expect(!viewer.isOpen());
    try std.testing.expectEqual(@as(u32, 0), under_clicks);
}
