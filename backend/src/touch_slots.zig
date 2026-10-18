//! Which of dvui's touch buttons (`touch0` to `touch9`) each finger on the screen presses.
//!
//! dvui reads a touch button as a finger on the screen at the event's point: it sets
//! `dvui.pointerKind()` to `.touch`, and a lifted finger hovers nothing. Only a direct touch is
//! that. SDL also reports a trackpad's fingers as touches (on macOS, with a device of type
//! `SDL_TOUCH_DEVICE_INDIRECT_*`), at a point on the pad rather than in the window; the trackpad
//! already moves the mouse and clicks, so those get no slot and reach dvui as nothing. Nothing in
//! fizzy or its plugins read them: they arrived as `touch0` presses at the pad's point, mapped
//! into the window.
//!
//! SDL also registers two touch devices of its own as direct: `SDL_MOUSE_TOUCHID`, for the touches
//! it synthesizes from a mouse, and `SDL_PEN_TOUCHID`, for a pen's (`SDL_HINT_PEN_TOUCH_EVENTS`,
//! on by default). A pen already reaches dvui as the mouse; read as a finger too, a tablet stroke
//! would flip `dvui.pointerKind()` with every press. Neither is a finger (`deviceOf`).
//!
//! Each finger keeps its slot from down to up, so two fingers are two buttons (a pinch), and one
//! lifting releases its own button, not another finger's. A lift the window never hears of (it
//! lost focus, went to the background or closed mid-touch) would hold its slot for good, and
//! dvui would think a finger is still down: the backend releases every held slot then
//! (`releaseAll`).
const std = @import("std");

pub const Device = enum { direct, indirect };

/// `SDL_MOUSE_TOUCHID` and `SDL_PEN_TOUCHID` (`(SDL_TouchID)-1` and `-2`).
pub const mouse_touch_id: u64 = std.math.maxInt(u64);
pub const pen_touch_id: u64 = std.math.maxInt(u64) - 1;

/// A touch device as dvui is to see it: a finger on the screen (`direct`, as SDL reports its type)
/// unless it is SDL's own mouse or pen device.
pub fn deviceOf(touch: u64, sdl_direct: bool) Device {
    if (touch == mouse_touch_id or touch == pen_touch_id) return .indirect;
    return if (sdl_direct) .direct else .indirect;
}

const Finger = struct { touch: u64, finger: u64 };

fingers: [10]?Finger = @splat(null),

const TouchSlots = @This();

/// A finger landed: its slot, or null for a finger dvui is not to see (not on the screen, or an
/// eleventh).
pub fn down(self: *TouchSlots, device: Device, touch: u64, finger: u64) ?u4 {
    if (device != .direct) return null;
    if (self.find(touch, finger)) |i| return i;
    for (&self.fingers, 0..) |*slot, i| if (slot.* == null) {
        slot.* = .{ .touch = touch, .finger = finger };
        return @intCast(i);
    };
    return null;
}

/// A finger moved: the slot it landed in, if it was given one.
pub fn find(self: *const TouchSlots, touch: u64, finger: u64) ?u4 {
    for (self.fingers, 0..) |slot, i| if (slot) |f| {
        if (f.touch == touch and f.finger == finger) return @intCast(i);
    };
    return null;
}

/// A finger lifted (or was cancelled): the slot it frees, if it had one.
pub fn up(self: *TouchSlots, touch: u64, finger: u64) ?u4 {
    const i = self.find(touch, finger) orelse return null;
    self.fingers[i] = null;
    return i;
}

/// Free every held slot, for a window that will not hear their lifts: a bit per slot freed, from
/// slot 0.
pub fn releaseAll(self: *TouchSlots) u10 {
    var freed: u10 = 0;
    for (&self.fingers, 0..) |*slot, i| if (slot.* != null) {
        slot.* = null;
        freed |= @as(u10, 1) << @intCast(i);
    };
    return freed;
}

test "SDL's mouse and pen touch devices are not fingers" {
    try std.testing.expectEqual(.indirect, deviceOf(mouse_touch_id, true));
    try std.testing.expectEqual(.indirect, deviceOf(pen_touch_id, true));
    try std.testing.expectEqual(.direct, deviceOf(42, true));
    try std.testing.expectEqual(.indirect, deviceOf(42, false));
}

test "lifts the window never hears of free every slot" {
    var slots: TouchSlots = .{};
    for (0..10) |i| _ = slots.down(.direct, 1, i);
    try std.testing.expectEqual(null, slots.down(.direct, 1, 10));
    _ = slots.up(1, 3);
    try std.testing.expectEqual(@as(u10, 0b11_1111_0111), slots.releaseAll());
    try std.testing.expectEqual(@as(u10, 0), slots.releaseAll());
    // Touch works again after.
    try std.testing.expectEqual(0, slots.down(.direct, 1, 99));
}

test "a trackpad's fingers get no slot" {
    var slots: TouchSlots = .{};
    try std.testing.expectEqual(null, slots.down(.indirect, 1, 7));
    try std.testing.expectEqual(null, slots.find(1, 7));
    try std.testing.expectEqual(null, slots.up(1, 7));
}

test "each finger on the screen keeps its own slot until it lifts" {
    var slots: TouchSlots = .{};
    try std.testing.expectEqual(0, slots.down(.direct, 1, 100));
    try std.testing.expectEqual(1, slots.down(.direct, 1, 200));
    try std.testing.expectEqual(1, slots.find(1, 200));
    // The first lifts: its own slot is freed, the second keeps its.
    try std.testing.expectEqual(0, slots.up(1, 100));
    try std.testing.expectEqual(1, slots.find(1, 200));
    // A new finger takes the free slot.
    try std.testing.expectEqual(0, slots.down(.direct, 1, 300));
    // The same finger id on another device is another finger.
    try std.testing.expectEqual(2, slots.down(.direct, 2, 100));
}

test "an eleventh finger is not seen" {
    var slots: TouchSlots = .{};
    for (0..10) |i| try std.testing.expect(slots.down(.direct, 1, i) != null);
    try std.testing.expectEqual(null, slots.down(.direct, 1, 10));
}
