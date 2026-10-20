const std = @import("std");
const t = @import("root.zig");
const Sim = @import("../Sim.zig");

test "a press lands where the pointer is and the release goes to the window it ends over" {
    var sim = Sim.init(std.testing.allocator, .{ .displays = &.{.{ .scale = 2 }} });
    defer sim.deinit();
    const p = sim.platform();
    const a = try p.openWindow(.{ .position = .{ .x = 0, .y = 0 }, .size = .{ .w = 300, .h = 300 } });
    const b = try p.openWindow(.{ .position = .{ .x = 400, .y = 0 }, .size = .{ .w = 300, .h = 300 } });
    t.drain(p);

    sim.movePointer(.{ .x = 10, .y = 20 });
    // Window pixels are physical: points times the scale.
    const moved = try t.expectNext(p, a, .pointer);
    try std.testing.expectEqual(@as(f32, 20), moved.at.x);
    try std.testing.expectEqual(@as(f32, 40), moved.at.y);

    sim.pressButton(.left);
    try std.testing.expectEqual(a.id, sim.focused().?.id);
    sim.movePointer(.{ .x = 410, .y = 20 });
    sim.releaseButton(.left);
    t.drain(p);
    sim.movePointer(.{ .x = 10, .y = 20 });
    // Leaving a window names the window it left, with the last place it was.
    const left = try t.expectNext(p, b, .pointer);
    try std.testing.expectEqual(.leave, left.kind);
    try std.testing.expectEqual(@as(f32, 20), left.at.x);
}

test "a key carries where it is and what it types, with the modifiers held" {
    var sim = Sim.init(std.testing.allocator, .{});
    defer sim.deinit();
    const p = sim.platform();
    const w = try p.openWindow(.{});
    p.setTextInput(w, true);
    t.drain(p);

    sim.key(.left_shift, .down);
    sim.tap(.k);
    sim.key(.left_shift, .up);
    try std.testing.expectEqual(.left_shift, (try t.expectNext(p, w, .key)).physical);
    const down = try t.expectNext(p, w, .key);
    try std.testing.expectEqual(@as(u21, 'k'), down.logical.char);
    try std.testing.expect(down.mods.shift);
    try std.testing.expectEqualStrings("K", try t.expectNext(p, w, .text));
    try std.testing.expectEqual(.up, (try t.expectNext(p, w, .key)).action);
    try std.testing.expect(!(try t.expectNext(p, w, .key)).mods.shift);

    // A window not taking text gets the keys and no characters.
    p.setTextInput(w, false);
    sim.tap(.a);
    _ = try t.expectNext(p, w, .key);
    _ = try t.expectNext(p, w, .key);
    try t.expectIdle(p);
}
