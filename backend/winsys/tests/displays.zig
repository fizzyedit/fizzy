const std = @import("std");
const t = @import("root.zig");
const Sim = @import("../Sim.zig");
const Platform = @import("../Platform.zig");

const ms = std.time.ns_per_ms;

test "a window dragged to a display of another scale hears the new one, and a lost display sends it home" {
    var sim = Sim.init(std.testing.allocator, .{ .displays = &.{.{ .top_inset = 24 }} });
    defer sim.deinit();
    const p = sim.platform();
    // Left of the primary one, so its origin is negative.
    const hidpi = sim.addDisplay(.{ .bounds = .{ .x = -1440, .y = 0, .w = 1440, .h = 900 }, .scale = 2, .refresh_hz = 120 });
    const w = try p.openWindow(.{ .position = .{ .x = 100, .y = 100 }, .size = .{ .w = 400, .h = 300 } });
    t.drain(p);
    try std.testing.expectEqual(@as(f32, 1), p.windowScale(w));
    try std.testing.expectEqual(@as(u32, 400), p.windowSize(w).w);

    p.setWindowPosition(w, .{ .x = -1000, .y = 100 });
    sim.advance(10 * ms);
    try std.testing.expectEqual(hidpi, p.displayOf(w).?);
    try std.testing.expectEqual(@as(i32, -1000), (try t.expectNext(p, w, .moved)).x);
    const re = try t.expectNext(p, w, .resized);
    try std.testing.expectEqual(@as(f32, 2), re.scale);
    try std.testing.expectEqual(@as(u32, 800), re.size.w);

    const both = try p.displays(std.testing.allocator);
    defer Platform.freeDisplays(std.testing.allocator, both);
    try std.testing.expectEqual(@as(f32, 120), both[1].refresh_hz);
    try std.testing.expectEqual(@as(i32, -1440), both[1].bounds.x);

    sim.removeDisplay(hidpi);
    try std.testing.expect(p.displayOf(w) != null);
    try std.testing.expectEqual(@as(f32, 1), p.windowScale(w));
    try std.testing.expect(p.windowPosition(w).x >= 0);

    const list = try p.displays(std.testing.allocator);
    defer Platform.freeDisplays(std.testing.allocator, list);
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqual(@as(i32, 24), list[0].usable.y);
    try std.testing.expect(list[0].primary);
}
