//! Which of the ten touch slots each finger on the screen holds.
//!
//! A consumer that reads touch as buttons (dvui's `touch0` to `touch9`) needs a finger to keep one
//! number from down to up, so two fingers are two buttons (a pinch) and one lifting releases its
//! own, not another finger's. Only a finger on the screen gets a slot: a platform reports a
//! trackpad's or a pen's as `Event.Payload.pointer`, never as a touch (`Event.Touch`), so it never
//! reaches here. An eleventh finger gets none and is not seen.
//!
//! A lift the window never hears of (it lost focus, went to the background or closed mid-touch)
//! would hold its slot for good, so `EventQueue` cancels every held finger then (`releaseAll`).
//!
//! `backend/src/touch_slots.zig` is the same table for the SDL backend, which cannot import
//! across its module root; step 7 of the windowing plan retires it when the SDL adapter reads
//! `EventQueue`.
const std = @import("std");

const TouchSlots = @This();

pub const count = 10;

const Finger = struct { device: u64, finger: u64 };

fingers: [count]?Finger = @splat(null),

/// A finger landed: its slot, or null for an eleventh. A finger that is already down keeps its
/// slot.
pub fn down(self: *TouchSlots, device: u64, finger: u64) ?u4 {
    if (self.find(device, finger)) |i| return i;
    for (&self.fingers, 0..) |*slot, i| if (slot.* == null) {
        slot.* = .{ .device = device, .finger = finger };
        return @intCast(i);
    };
    return null;
}

/// A finger moved: the slot it landed in, if it was given one.
pub fn find(self: *const TouchSlots, device: u64, finger: u64) ?u4 {
    for (self.fingers, 0..) |slot, i| if (slot) |f| {
        if (f.device == device and f.finger == finger) return @intCast(i);
    };
    return null;
}

/// A finger lifted (or was cancelled): the slot it frees, if it had one.
pub fn up(self: *TouchSlots, device: u64, finger: u64) ?u4 {
    const i = self.find(device, finger) orelse return null;
    self.fingers[i] = null;
    return i;
}

/// Free every held slot: a bit per slot freed, from slot 0.
pub fn releaseAll(self: *TouchSlots) u10 {
    var freed: u10 = 0;
    for (&self.fingers, 0..) |*slot, i| if (slot.* != null) {
        slot.* = null;
        freed |= @as(u10, 1) << @intCast(i);
    };
    return freed;
}

test "each finger on the screen keeps its own slot until it lifts" {
    var slots: TouchSlots = .{};
    try std.testing.expectEqual(0, slots.down(1, 100));
    try std.testing.expectEqual(1, slots.down(1, 200));
    try std.testing.expectEqual(1, slots.find(1, 200));
    // The first lifts: its own slot is freed, the second keeps its.
    try std.testing.expectEqual(0, slots.up(1, 100));
    try std.testing.expectEqual(1, slots.find(1, 200));
    // A new finger takes the free slot.
    try std.testing.expectEqual(0, slots.down(1, 300));
    // The same finger id on another device is another finger.
    try std.testing.expectEqual(2, slots.down(2, 100));
}

test "a finger that is already down keeps its slot" {
    var slots: TouchSlots = .{};
    try std.testing.expectEqual(0, slots.down(1, 5));
    try std.testing.expectEqual(0, slots.down(1, 5));
    try std.testing.expectEqual(1, slots.down(1, 6));
}

test "an eleventh finger is not seen" {
    var slots: TouchSlots = .{};
    for (0..count) |i| try std.testing.expect(slots.down(1, i) != null);
    try std.testing.expectEqual(null, slots.down(1, count));
    try std.testing.expectEqual(null, slots.find(1, count));
    try std.testing.expectEqual(null, slots.up(1, count));
}

test "lifts the window never hears of free every slot" {
    var slots: TouchSlots = .{};
    for (0..count) |i| _ = slots.down(1, i);
    _ = slots.up(1, 3);
    try std.testing.expectEqual(@as(u10, 0b11_1111_0111), slots.releaseAll());
    try std.testing.expectEqual(@as(u10, 0), slots.releaseAll());
    // Touch works again after.
    try std.testing.expectEqual(0, slots.down(1, 99));
}
