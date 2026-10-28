//! A motion's clock, stepped by the frames that draw it rather than read off the wall: each frame
//! moves it on by the time since the frame before, but never by more than `max_step_ns`.
//!
//! Read off the wall, a motion whose first frames are long ones — a window's first frames make
//! its glass's textures, and on a phone's GPU those take tens of milliseconds — is shown at its
//! start for as long as they take and then far along: a jump where its start should be, and most
//! of a motion that arrives in a handful of frames (`core.motion.arrival`) gone in one. Stepped, a
//! long frame holds it for a moment instead, and it goes on from where it was shown.
//!
//! Pure: the frame time and the duration (`core.motion.durationMs`, the user's speed and level)
//! are the caller's.
const std = @import("std");

const FrameClock = @This();

/// The most one frame moves a clock on, ns: a frame at 30 Hz, so a device drawing that often keeps
/// its motions' speed, and only a frame longer than that holds one.
pub const max_step_ns: i128 = 34 * std.time.ns_per_ms;

/// How far it has run.
elapsed_ns: i128 = 0,
/// The frame time it was last stepped to; null before its first step.
last_ns: ?i128 = null,

/// Step it to frame time `now`. Its first step starts it, at 0; another in the same frame leaves it
/// where it is.
pub fn step(self: *FrameClock, now: i128) void {
    if (self.last_ns) |last| self.elapsed_ns += std.math.clamp(now - last, 0, max_step_ns);
    self.last_ns = now;
}

/// How far through a motion of `duration_ms` it is, 0…1 — 1 for a duration of 0, motion off.
pub fn fraction(self: FrameClock, duration_ms: f32) f32 {
    const dur: f64 = @as(f64, duration_ms) * std.time.ns_per_ms;
    if (dur <= 0) return 1;
    return @floatCast(std.math.clamp(@as(f64, @floatFromInt(self.elapsed_ns)) / dur, 0, 1));
}

const testing = std.testing;
const ms = std.time.ns_per_ms;

test "a clock starts at its first step, and a second step in the same frame leaves it" {
    var c: FrameClock = .{};
    c.step(5_000 * ms);
    try testing.expectEqual(@as(i128, 0), c.elapsed_ns);
    c.step(5_008 * ms);
    c.step(5_008 * ms);
    try testing.expectEqual(@as(i128, 8 * ms), c.elapsed_ns);
}

test "a long frame moves a clock on by one step's worth, not by how long it took" {
    var c: FrameClock = .{};
    c.step(0);
    c.step(120 * ms);
    try testing.expectEqual(max_step_ns, c.elapsed_ns);
    // At 30 Hz it keeps time.
    c.step(120 * ms + 33 * ms);
    try testing.expectEqual(max_step_ns + 33 * ms, c.elapsed_ns);
    // A clock that runs backwards (a seek) does not unwind it.
    c.step(10 * ms);
    try testing.expectEqual(max_step_ns + 33 * ms, c.elapsed_ns);
}

test "a fraction of a motion: clamped, and whole at once with motion off" {
    var c: FrameClock = .{};
    c.step(0);
    c.step(30 * ms);
    try testing.expectApproxEqAbs(@as(f32, 0.1), c.fraction(300), 1e-6);
    try testing.expectEqual(@as(f32, 1), c.fraction(10));
    try testing.expectEqual(@as(f32, 1), c.fraction(0));
    const unstarted: FrameClock = .{};
    try testing.expectEqual(@as(f32, 0), unstarted.fraction(300));
}
