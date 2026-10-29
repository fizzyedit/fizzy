//! Press-and-hold selection for touch, without a window: a finger held still for `delay_ns`
//! selects; a tap clears; a finger that moves more than `slop` is a scroll and selects nothing.
//!
//! std-only so the rules are tested by feeding it times and points. `widgets/SelectableText.zig`
//! is the dvui half: it feeds this the frame's touch events and applies what it answers.

const std = @import("std");

const TouchHold = @This();

/// How long a finger holds still before it selects (the platforms' long-press, about half a second).
pub const delay_ns: i128 = 450 * std.time.ns_per_ms;

/// The one touch slop, in points: read by SelectableText holds, dvui drag thresholds
/// (sdk.dvui_context), and ViewDrag ghost rests.
pub const slop_pt: f32 = 14;

/// A finger is down on the text, still holding or finished with this press.
armed: bool = false,
/// The hold has selected; the release is then not a tap.
fired: bool = false,
/// Where the finger went down, in physical pixels.
x: f32 = 0,
y: f32 = 0,
/// Frame time of the press.
start_ns: i128 = 0,

/// A finger went down on the text at (`x`, `y`) in physical pixels.
pub fn press(self: *TouchHold, x: f32, y: f32, now_ns: i128) void {
    self.* = .{ .armed = true, .x = x, .y = y, .start_ns = now_ns };
}

/// The finger moved to (`x`, `y`). Past `slop` physical pixels it is a scroll: the hold ends.
pub fn move(self: *TouchHold, x: f32, y: f32, slop: f32) void {
    if (!self.armed or self.fired) return;
    if (std.math.hypot(x - self.x, y - self.y) > slop) self.armed = false;
}

/// True once, on the first call at or after `delay_ns` of holding still.
pub fn due(self: *TouchHold, now_ns: i128) bool {
    if (!self.armed or self.fired or now_ns - self.start_ns < delay_ns) return false;
    self.fired = true;
    return true;
}

/// Nanoseconds until the hold is due, for a timer; null when nothing is waiting.
pub fn remaining(self: TouchHold, now_ns: i128) ?i128 {
    if (!self.armed or self.fired) return null;
    return @max(0, delay_ns - (now_ns - self.start_ns));
}

/// The finger lifted. True when it was a tap: lifted before the hold, without moving away.
/// A finger that selected, or scrolled, is not.
pub fn release(self: *TouchHold) bool {
    const tap = self.armed and !self.fired;
    self.* = .{};
    return tap;
}

/// The press was claimed by something else (another widget took the touch).
pub fn cancel(self: *TouchHold) void {
    self.* = .{};
}

const t0: i128 = 1_000_000_000;

test "a tap is reported on release and does not select" {
    var h: TouchHold = .{};
    h.press(10, 10, t0);
    try std.testing.expect(!h.due(t0 + 100 * std.time.ns_per_ms));
    try std.testing.expect(h.release());
}

test "a finger held still selects once after the delay" {
    var h: TouchHold = .{};
    h.press(10, 10, t0);
    try std.testing.expect(!h.due(t0 + delay_ns - 1));
    h.move(12, 11, slop_pt);
    try std.testing.expect(h.due(t0 + delay_ns));
    try std.testing.expect(!h.due(t0 + delay_ns + 1));
    try std.testing.expect(!h.release());
}

test "a drag past the slop cancels the hold and is not a tap" {
    var h: TouchHold = .{};
    h.press(10, 10, t0);
    h.move(10 + slop_pt + 1, 10, slop_pt);
    try std.testing.expect(!h.due(t0 + 10 * delay_ns));
    try std.testing.expect(!h.release());
}

test "a drift inside the slop keeps the hold" {
    var h: TouchHold = .{};
    h.press(10, 10, t0);
    h.move(10 + slop_pt, 10, slop_pt);
    try std.testing.expect(h.due(t0 + delay_ns));
}

test "the slop is measured from the press, not from the last move" {
    var h: TouchHold = .{};
    h.press(0, 0, t0);
    h.move(10, 0, slop_pt);
    h.move(20, 0, slop_pt);
    try std.testing.expect(!h.due(t0 + delay_ns));
}

test "remaining counts down to the hold and stops once it fired or ended" {
    var h: TouchHold = .{};
    try std.testing.expectEqual(@as(?i128, null), h.remaining(t0));
    h.press(0, 0, t0);
    try std.testing.expectEqual(@as(?i128, delay_ns - 100), h.remaining(t0 + 100));
    try std.testing.expectEqual(@as(?i128, 0), h.remaining(t0 + 2 * delay_ns));
    _ = h.due(t0 + delay_ns);
    try std.testing.expectEqual(@as(?i128, null), h.remaining(t0 + delay_ns));
}
