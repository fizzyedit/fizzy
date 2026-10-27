const std = @import("std");
const t = @import("root.zig");
const Sim = @import("../Sim.zig");

const ms = std.time.ns_per_ms;

test "waiting jumps the virtual clock to the transition and stamps the event with it" {
    var sim = Sim.init(std.testing.allocator, .{});
    defer sim.deinit();
    const p = sim.platform();
    const w = try p.openWindow(.{ .size = .{ .w = 800, .h = 600 } });
    t.drain(p);

    const asked = p.now();
    p.setWindowSize(w, .{ .w = 1000, .h = 500 });
    try std.testing.expectEqual(@as(u32, 800), p.windowSize(w).w);
    p.wait(null);
    try std.testing.expectEqual(asked + 10 * ms, p.now());

    const e = p.poll().?;
    try std.testing.expectEqual(asked + 10 * ms, e.time_ns);
    try std.testing.expectEqual(@as(u32, 1000), e.payload.resized.size.w);
    try std.testing.expect(!e.payload.resized.live);
    try t.expectIdle(p);

    // A woken wait returns at once and moves nothing.
    p.wake();
    p.wait(1000 * ms);
    try std.testing.expectEqual(asked + 10 * ms, p.now());
}
