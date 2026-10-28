//! The wall time between frames, for what counts real time while the app's motion clock runs
//! behind it: a wait's timeout.
//!
//! The backend holds a late frame's motion step to a few dozen milliseconds and keeps the rest as
//! a debt it publishes each frame, so `dvui.secondsSinceLastFrame` is a motion step, not the wall.
//! A wait that gives up after ten seconds counts ten seconds of wall, however slowly the app draws.
const std = @import("std");
const dvui = @import("dvui");

// Where the backend publishes its debt (`glass.MotionClock.publish`): the same id and key.
const debt_id: dvui.Id = @fromBackingInt(@intCast(0x6669_7a7a_636c_6f63)); // "fizzcloc"
const debt_key = "_motion_debt";

/// Wall time since the last frame, ms: the frame's step and what the motion clock took off it.
/// `seen_ns` is the debt as of the caller's last call, which this moves up to now; null, before
/// the first call, takes the debt already owed as the baseline so earlier stalls are not charged.
pub fn gapMs(seen_ns: *?i128) f64 {
    const debt = dvui.dataGet(null, debt_id, debt_key, i128) orelse 0;
    const held = @max(0, debt - (seen_ns.* orelse debt));
    seen_ns.* = debt;
    return dvui.secondsSinceLastFrame() * 1000 + @as(f64, @floatFromInt(held)) / std.time.ns_per_ms;
}
