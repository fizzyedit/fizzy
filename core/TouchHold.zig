//! Press-and-hold selection for touch, without a window: a finger held still for `delay_ns`
//! selects; a double tap selects; a tap clears; a finger that moves more than `slop` is a
//! scroll and selects nothing.
//!
//! std-only so the rules are tested by feeding it times and points. `widgets/SelectableText.zig`
//! is the dvui half: it feeds this the frame's touch events and applies what it answers.

const std = @import("std");

const TouchHold = @This();

/// How long a finger holds still before it selects (the platforms' long-press, about half a second).
pub const delay_ns: i128 = 450 * std.time.ns_per_ms;

/// The most time between a tap and the next press for the two to be a double tap.
pub const tap_ns: i128 = 300 * std.time.ns_per_ms;
/// What a lifted finger was.
pub const Release = enum { none, tap, double_tap };

/// Points a finger may drift and still be holding.
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
/// This press is within `tap_ns` and `slop` of the last tap; a short release is a double tap.
second: bool = false,
/// The only state retained across `press` and `release`: the last plain tap's position and time.
/// A plain tap replaces it; every other release and `cancel` clear it.
last_tap: ?struct { x: f32, y: f32, at_ns: i128 } = null,

/// `slop` in physical pixels: a press within `tap_ns` and `slop` of the last tap is a second press.
pub fn press(self: *TouchHold, x: f32, y: f32, now_ns: i128, slop: f32) void {
    const second = if (self.last_tap) |tap|
        now_ns - tap.at_ns <= tap_ns and std.math.hypot(x - tap.x, y - tap.y) <= slop
    else
        false;
    self.* = .{ .armed = true, .x = x, .y = y, .start_ns = now_ns, .second = second, .last_tap = self.last_tap };
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

/// A tap is lifted before the hold without moving away; the tap of a second press is a double tap.
pub fn release(self: *TouchHold, now_ns: i128) Release {
    const result: Release = if (self.armed and !self.fired and now_ns - self.start_ns < delay_ns)
        (if (self.second) .double_tap else .tap)
    else
        .none;
    self.* = .{ .last_tap = if (result == .tap) .{ .x = self.x, .y = self.y, .at_ns = now_ns } else null };
    return result;
}

/// The press was claimed by something else (another widget took the touch).
pub fn cancel(self: *TouchHold) void {
    self.* = .{};
}

const t0: i128 = 1_000_000_000;

test "a tap is reported on release and does not select" {
    var h: TouchHold = .{};
    h.press(10, 10, t0, slop_pt);
    try std.testing.expect(!h.due(t0 + 100 * std.time.ns_per_ms));
    try std.testing.expectEqual(Release.tap, h.release(t0 + 100 * std.time.ns_per_ms));
}

test "a finger held still selects once after the delay" {
    var h: TouchHold = .{};
    h.press(10, 10, t0, slop_pt);
    try std.testing.expect(!h.due(t0 + delay_ns - 1));
    h.move(12, 11, slop_pt);
    try std.testing.expect(h.due(t0 + delay_ns));
    try std.testing.expect(!h.due(t0 + delay_ns + 1));
    try std.testing.expectEqual(Release.none, h.release(t0 + delay_ns));
}

test "a drag past the slop cancels the hold and is not a tap" {
    var h: TouchHold = .{};
    h.press(10, 10, t0, slop_pt);
    h.move(10 + slop_pt + 1, 10, slop_pt);
    try std.testing.expect(!h.due(t0 + 10 * delay_ns));
    try std.testing.expectEqual(Release.none, h.release(t0 + delay_ns));
}

test "a drift inside the slop keeps the hold" {
    var h: TouchHold = .{};
    h.press(10, 10, t0, slop_pt);
    h.move(10 + slop_pt, 10, slop_pt);
    try std.testing.expect(h.due(t0 + delay_ns));
}

test "the slop is measured from the press, not from the last move" {
    var h: TouchHold = .{};
    h.press(0, 0, t0, slop_pt);
    h.move(10, 0, slop_pt);
    h.move(20, 0, slop_pt);
    try std.testing.expect(!h.due(t0 + delay_ns));
}

test "remaining counts down to the hold and stops once it fired or ended" {
    var h: TouchHold = .{};
    try std.testing.expectEqual(@as(?i128, null), h.remaining(t0));
    h.press(0, 0, t0, slop_pt);
    try std.testing.expectEqual(@as(?i128, delay_ns - 100), h.remaining(t0 + 100));
    try std.testing.expectEqual(@as(?i128, 0), h.remaining(t0 + 2 * delay_ns));
    _ = h.due(t0 + delay_ns);
    try std.testing.expectEqual(@as(?i128, null), h.remaining(t0 + delay_ns));
}

test "a tap that drifts 13 points is a tap and at 15 points is not" {
    for ([_]f32{ 13, 15 }) |drift| {
        var h: TouchHold = .{};
        h.press(0, 0, t0, slop_pt);
        h.move(drift, 0, slop_pt);
        try std.testing.expectEqual(if (drift == 13) Release.tap else Release.none, h.release(t0 + 30 * std.time.ns_per_ms));
    }
}

test "the hold is due at 450 ms with the finger still down" {
    var h: TouchHold = .{};
    h.press(0, 0, t0, slop_pt);
    try std.testing.expect(!h.due(t0 + 449 * std.time.ns_per_ms));
    try std.testing.expect(h.due(t0 + 450 * std.time.ns_per_ms));
    try std.testing.expectEqual(Release.none, h.release(t0 + 451 * std.time.ns_per_ms));
}

test "a second tap 299 ms after the first is a double tap and at 301 ms is not" {
    for ([_]i128{ 299, 301 }) |gap_ms| {
        var h: TouchHold = .{};
        h.press(0, 0, t0, slop_pt);
        const first_release = t0 + 30 * std.time.ns_per_ms;
        try std.testing.expectEqual(Release.tap, h.release(first_release));
        const second_press = first_release + gap_ms * std.time.ns_per_ms;
        h.press(0, 0, second_press, slop_pt);
        try std.testing.expectEqual(if (gap_ms == 299) Release.double_tap else Release.tap, h.release(second_press + 30 * std.time.ns_per_ms));
        h.press(0, 0, second_press + 60 * std.time.ns_per_ms, slop_pt);
        try std.testing.expectEqual(if (gap_ms == 299) Release.tap else Release.double_tap, h.release(second_press + 90 * std.time.ns_per_ms));
    }
}

test "a second tap outside the slop of the first, or after a hold, is a plain tap" {
    var h: TouchHold = .{};
    h.press(0, 0, t0, slop_pt);
    try std.testing.expectEqual(Release.tap, h.release(t0 + 30 * std.time.ns_per_ms));
    h.press(15, 0, t0 + 100 * std.time.ns_per_ms, slop_pt);
    try std.testing.expectEqual(Release.tap, h.release(t0 + 130 * std.time.ns_per_ms));
    h.press(15, 0, t0 + 200 * std.time.ns_per_ms, slop_pt);
    try std.testing.expect(h.due(t0 + 650 * std.time.ns_per_ms));
    try std.testing.expectEqual(Release.none, h.release(t0 + 660 * std.time.ns_per_ms));
    h.press(15, 0, t0 + 700 * std.time.ns_per_ms, slop_pt);
    try std.testing.expectEqual(Release.tap, h.release(t0 + 730 * std.time.ns_per_ms));
}
