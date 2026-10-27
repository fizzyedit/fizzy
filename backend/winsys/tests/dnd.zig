const std = @import("std");
const t = @import("root.zig");
const Sim = @import("../Sim.zig");

test "a drag from another program is a visit per window, and release is not acceptance" {
    var sim = Sim.init(std.testing.allocator, .{});
    defer sim.deinit();
    const p = sim.platform();
    const a = try p.openWindow(.{ .position = .{ .x = 0, .y = 0 }, .size = .{ .w = 300, .h = 300 } });
    const b = try p.openWindow(.{ .position = .{ .x = 400, .y = 0 }, .size = .{ .w = 300, .h = 300 } });
    t.drain(p);

    sim.movePointer(.{ .x = 10, .y = 10 });
    t.drain(p);
    sim.dragBegin(.{ .files = &.{ "/tmp/one.png", "/tmp/two.png" } });
    const enter = try t.expectNext(p, a, .drop);
    try std.testing.expectEqual(.enter, enter.phase);
    try std.testing.expectEqualStrings("/tmp/two.png", enter.data.files[1]);

    // Crossing into the other window ends one visit and starts another, and no pointer event.
    sim.movePointer(.{ .x = 410, .y = 10 });
    try std.testing.expectEqual(.leave, (try t.expectNext(p, a, .drop)).phase);
    try std.testing.expectEqual(.enter, (try t.expectNext(p, b, .drop)).phase);
    p.dropRespond(b, .copy);
    sim.movePointer(.{ .x = 420, .y = 10 });
    try std.testing.expectEqual(.move, (try t.expectNext(p, b, .drop)).phase);

    try std.testing.expectEqual(Sim.DropOutcome.accepted, sim.dragRelease());
    try std.testing.expectEqual(.drop, (try t.expectNext(p, b, .drop)).phase);

    // Never answered, the next drop is rejected.
    sim.dragBegin(.{ .text = "hello" });
    try std.testing.expectEqual(.enter, (try t.expectNext(p, b, .drop)).phase);
    try std.testing.expectEqual(Sim.DropOutcome.rejected, sim.dragRelease());
    t.drain(p);

    // Let go over no window.
    sim.dragBegin(.{ .text = "x" });
    t.drain(p);
    sim.movePointer(.{ .x = 900, .y = 900 });
    try std.testing.expectEqual(.leave, (try t.expectNext(p, b, .drop)).phase);
    try std.testing.expectEqual(Sim.DropOutcome.outside, sim.dragRelease());
    try t.expectIdle(p);
}
