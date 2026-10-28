//! The clock every motion in the app runs on: the wall, less a debt that grows whenever a frame
//! comes later than a motion should be moved by.
//!
//! A window's first frames make its glass's textures, a phone's GPU stalls, a loaded machine drops
//! frames, and a window that waited three seconds for an event wakes with a gap of three seconds
//! in front of it. Handed the wall, dvui steps an animation by all of it: a motion that starts in
//! such a frame is shown at its start for as long as the stall took and then far along. Handed a
//! `MotionClock`'s time, a frame is never more than `max_step_ns` after the one before, and the
//! rest is kept as `debt_ns` and taken off every reading the backend gives after: a late frame
//! holds motion for a moment and it goes on from where it was shown.
//!
//! The backend's `nanoTime` reports `now`, so dvui's own pacing (`waitTime`, a timer's due time)
//! stays in step with `frame_time_ns`. What means real elapsed time (a timeout, a save's age) reads
//! `wallFrameNs`. Event times are wall times: put one beside a frame time through `fromWall`.
//!
//! Pure but for `publish`: the wall is the caller's.
const std = @import("std");
const dvui = @import("dvui");

const MotionClock = @This();

/// The most one frame moves motion on, ns: a frame at 30 Hz, so a device drawing that often keeps
/// its motions' speed and only a frame longer than that holds them.
pub const max_step_ns: i128 = @import("FrameClock.zig").max_step_ns;

/// How far the motion clock is behind the wall. Only grows.
debt_ns: i128 = 0,

/// The motion clock's reading at wall time `wall_ns` (the wall with a demo's silent frames added):
/// what the backend's `nanoTime` returns.
pub fn now(self: MotionClock, wall_ns: i128) i128 {
    return wall_ns - self.debt_ns;
}

/// The time to begin the frame at, given the time of the frame before (`dvui.Window.frame_time_ns`)
/// and the clock's reading now (`now`, as `dvui.Window.beginWait` takes it). At most `max_step_ns`
/// after `prev_ns`; what is more becomes debt. A reading before `prev_ns` is left for dvui, which
/// holds its frame time.
pub fn frameTime(self: *MotionClock, prev_ns: i128, reading_ns: i128) i128 {
    if (reading_ns - prev_ns <= max_step_ns) return reading_ns;
    self.debt_ns += reading_ns - prev_ns - max_step_ns;
    return prev_ns + max_step_ns;
}

const publish_id: dvui.Id = @fromBackingInt(@intCast(0x6669_7a7a_636c_6f63)); // "fizzcloc"
const publish_key = "_motion_debt";

/// Backend only, once a frame after `dvui.Window.begin`: where every image's copy of this file
/// finds the debt, as `motion.publish` does the level.
pub fn publish(self: MotionClock) void {
    dvui.dataSet(null, publish_id, publish_key, self.debt_ns);
}

/// The wall time the frame began at, ns on the backend's clock: for a timeout, an age, anything that
/// means real time and not motion. Constant within a frame, like `dvui.frameTimeNS`.
pub fn wallFrameNs() i128 {
    return dvui.frameTimeNS() + (dvui.dataGet(null, publish_id, publish_key, i128) orelse 0);
}

/// A wall time (an event's, a deadline) on the frame time's clock, to compare with `dvui.frameTimeNS`.
pub fn fromWall(wall_ns: i128) i128 {
    return wall_ns - (wallFrameNs() - dvui.frameTimeNS());
}

const testing = std.testing;
const ms = std.time.ns_per_ms;

test "a frame within a step goes at the reading, and a long one is held with the rest as debt" {
    var c: MotionClock = .{};
    try testing.expectEqual(@as(i128, 1_008 * ms), c.frameTime(1_000 * ms, c.now(1_008 * ms)));
    try testing.expectEqual(@as(i128, 0), c.debt_ns);
    const held = c.frameTime(1_008 * ms, c.now(1_128 * ms));
    try testing.expectEqual(@as(i128, 1_008 * ms) + max_step_ns, held);
    try testing.expectEqual(120 * ms - max_step_ns, c.debt_ns);
    // The frame 8 ms of wall later is 8 ms on in motion time too.
    try testing.expectEqual(held + 8 * ms, c.frameTime(held, c.now(1_136 * ms)));
}
