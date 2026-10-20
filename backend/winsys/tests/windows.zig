const std = @import("std");
const t = @import("root.zig");
const Sim = @import("../Sim.zig");
const Window = @import("../Window.zig");

const ms = std.time.ns_per_ms;

test "full screen lands late and comes back to where the window was" {
    var sim = Sim.init(std.testing.allocator, .{});
    defer sim.deinit();
    const p = sim.platform();
    const w = try p.openWindow(.{ .size = .{ .w = 800, .h = 600 } });
    t.drain(p);

    p.setWindowState(w, .maximized);
    sim.advance(10 * ms);
    t.drain(p);
    p.setWindowState(w, .fullscreen);
    // The call returned; the OS has not done it.
    try std.testing.expectEqual(Window.State.maximized, p.windowState(w));
    try t.expectIdle(p);

    sim.advance(10 * ms);
    try std.testing.expectEqual(Window.State.fullscreen, p.windowState(w));
    t.drain(p);
    p.setWindowState(w, .normal);
    sim.advance(10 * ms);
    // Out of full screen goes back to maximized, not to normal.
    try std.testing.expectEqual(Window.State.maximized, p.windowState(w));
    try std.testing.expectEqual(.left_fullscreen, try t.expectNext(p, w, .state));
}

test "an overlay takes no focus and no input, and stays above ordinary windows" {
    var sim = Sim.init(std.testing.allocator, .{});
    defer sim.deinit();
    const p = sim.platform();
    const main = try p.openWindow(.{ .position = .{ .x = 100, .y = 100 }, .size = .{ .w = 400, .h = 300 } });
    const tip = try p.openWindow(.{ .kind = .overlay, .position = .{ .x = 100, .y = 100 }, .size = .{ .w = 400, .h = 300 } });
    try std.testing.expectEqual(main.id, sim.focused().?.id);

    p.raiseWindow(tip);
    try std.testing.expectEqual(main.id, sim.focused().?.id);
    p.raiseWindow(main);
    try std.testing.expect(sim.stackIndex(tip).? > sim.stackIndex(main).?);

    t.drain(p);
    sim.movePointer(.{ .x = 150, .y = 150 });
    sim.pressButton(.left);
    // The pointer is over both, and only the one beneath hears it.
    try std.testing.expectEqual(.move, (try t.expectNext(p, main, .pointer)).kind);
    try std.testing.expectEqual(.press, (try t.expectNext(p, main, .pointer)).kind);
    try t.expectIdle(p);

    var plain = Sim.init(std.testing.allocator, .{ .caps = .{} });
    defer plain.deinit();
    try std.testing.expectError(error.Unsupported, plain.platform().openWindow(.{ .kind = .overlay }));
}

test "closing the focused window hands focus on, and a parent takes its children with it" {
    var sim = Sim.init(std.testing.allocator, .{});
    defer sim.deinit();
    const p = sim.platform();
    const a = try p.openWindow(.{});
    const b = try p.openWindow(.{});
    const menu = try p.openWindow(.{ .kind = .menu, .parent = b });
    t.drain(p);

    p.raiseWindow(b);
    try std.testing.expect(sim.stackIndex(menu).? > sim.stackIndex(b).?);
    p.raiseWindow(a);
    p.raiseWindow(b);
    try std.testing.expect(sim.stackIndex(menu).? > sim.stackIndex(b).?);

    p.closeWindow(b);
    try std.testing.expectEqual(@as(usize, 1), sim.windowCount());
    try std.testing.expect(sim.stackIndex(menu) == null);
    try std.testing.expectEqual(a.id, sim.focused().?.id);
    // Ids are not reused.
    try std.testing.expect((try p.openWindow(.{})).id > menu.id);
}

test "minimising gives focus away and a minimised window draws nothing" {
    var sim = Sim.init(std.testing.allocator, .{});
    defer sim.deinit();
    const p = sim.platform();
    const a = try p.openWindow(.{});
    const b = try p.openWindow(.{});
    t.drain(p);

    p.setWindowState(b, .minimized);
    sim.advance(10 * ms);
    try std.testing.expectEqual(.minimized, try t.expectNext(p, b, .state));
    try std.testing.expect(try t.expectNext(p, b, .occluded));
    try std.testing.expect(!(try t.expectNext(p, b, .focus)));
    try std.testing.expect(try t.expectNext(p, a, .focus));
    try std.testing.expectEqual(@as(u32, 0), p.windowSize(b).w);
}
