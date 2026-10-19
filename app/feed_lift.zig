//! How high the activity feed stands over its pane's bottom (`ActivityFeed`), as what is under it
//! comes and goes. std-only, so it tests without a Window.
//!
//! The height follows its target exactly while the same thing stays under the feed: a history
//! strip growing, a card's corner panned, a window resized, all of which already move smoothly.
//! Only when what is under it changes (a bar comes, a pill goes) does the height jump, and that
//! jump is eased: the feed sets off from where it stood and closes the gap over the caller's
//! `Pace`, while still following the new target's own motion. A change at a crossing, where both
//! things stood at the same height, has no gap and costs nothing.
const std = @import("std");

const Lift = @This();

/// The most one frame moves an ease on, ns, as `core.FrameClock`: a long frame holds it a moment
/// rather than skipping it on.
const max_step_ns: i128 = 34 * std.time.ns_per_ms;

/// What is under the feed, as the caller names it; null until the first `at`.
under: ?u32 = null,
/// How far from its target the feed stood when what is under it last changed; 0 once eased.
gap: f32 = 0,
/// How far that ease has run.
elapsed_ns: i128 = 0,
/// The frame time of the last `at`.
last_ns: i128 = 0,
/// The height shown at the last `at`.
shown: f32 = 0,

/// How an ease runs: for how long (0 for at once, motion off) and on which curve.
pub const Pace = struct { ms: f32, curve: *const fn (f32) f32 };

/// The height to show at frame time `now`, `target` being where the feed belongs over what is
/// under it, `under`. `rising` paces an ease up (something came), `falling` one down.
pub fn at(self: *Lift, target: f32, under: u32, now: i128, rising: Pace, falling: Pace) f32 {
    const was = self.under orelse {
        self.* = .{ .under = under, .last_ns = now, .shown = target };
        return target;
    };
    const step = std.math.clamp(now - self.last_ns, 0, max_step_ns);
    self.last_ns = now;
    if (under != was) {
        self.under = under;
        self.gap = self.shown - target;
        self.elapsed_ns = 0;
    }
    if (self.gap != 0) {
        self.elapsed_ns += step;
        const p = if (self.gap < 0) rising else falling;
        const t: f32 = if (p.ms <= 0) 1 else @floatCast(std.math.clamp(@as(f64, @floatFromInt(self.elapsed_ns)) / (@as(f64, p.ms) * std.time.ns_per_ms), 0, 1));
        self.shown = target + self.gap * (1 - p.curve(t));
        if (t >= 1) self.gap = 0;
    } else self.shown = target;
    return self.shown;
}

const testing = std.testing;
const ms = std.time.ns_per_ms;

fn linear(t: f32) f32 {
    return t;
}

const pace: Pace = .{ .ms = 160, .curve = linear };

/// Frames 16 ms apart from `from` to `to` (inclusive), all at `target` over `under`; the last height.
fn frames(l: *Lift, target: f32, under: u32, from: i128, to: i128) f32 {
    var t = from;
    var h: f32 = undefined;
    while (t <= to) : (t += 16 * ms) h = l.at(target, under, t, pace, pace);
    return h;
}

test "the lift eases to a new height over frames when what is under it changes, and back" {
    var l: Lift = .{};
    try testing.expectEqual(@as(f32, 20), l.at(20, 0, 0, pace, pace));
    // A bar comes under it: from where it stood, a frame's way on already, then the rest.
    try testing.expectApproxEqAbs(@as(f32, 30), l.at(120, 1, 16 * ms, pace, pace), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 80), frames(&l, 120, 1, 32 * ms, 96 * ms), 1e-3);
    try testing.expectEqual(@as(f32, 120), frames(&l, 120, 1, 112 * ms, 160 * ms));
    try testing.expectEqual(@as(f32, 0), l.gap);
    // The bar goes: down over frames as well.
    try testing.expectApproxEqAbs(@as(f32, 110), l.at(20, 0, 176 * ms, pace, pace), 1e-3);
    try testing.expectEqual(@as(f32, 20), frames(&l, 20, 0, 192 * ms, 400 * ms));
}

test "with the same thing under it, the lift follows its target at once" {
    var l: Lift = .{};
    _ = l.at(100, 1, 0, pace, pace);
    // A strip growing under it, a corner panned: no lag.
    try testing.expectEqual(@as(f32, 104), l.at(104, 1, 16 * ms, pace, pace));
    try testing.expectEqual(@as(f32, 90), l.at(90, 1, 32 * ms, pace, pace));
}

test "mid-ease, the lift follows its moving target, and turned back sets off from where it is" {
    var l: Lift = .{};
    _ = l.at(0, 0, 0, pace, pace);
    try testing.expectApproxEqAbs(@as(f32, 10), l.at(100, 1, 16 * ms, pace, pace), 1e-3);
    // The bar's strip grows by 10 while it eases: the gap closes over the moving target.
    try testing.expectApproxEqAbs(@as(f32, 30), l.at(110, 1, 32 * ms, pace, pace), 1e-3);
    // The bar goes mid-way: on from 30, a frame's way down.
    const back = l.at(0, 0, 48 * ms, pace, pace);
    try testing.expectApproxEqAbs(@as(f32, 27), back, 1e-3);
}

test "motion off, or a long frame, never jumps past what it should" {
    var l: Lift = .{};
    _ = l.at(0, 0, 0, pace, pace);
    try testing.expectEqual(@as(f32, 100), l.at(100, 1, 16 * ms, .{ .ms = 0, .curve = linear }, pace));
    var m: Lift = .{};
    _ = m.at(0, 0, 0, pace, pace);
    // A 500 ms frame moves the ease on by one step's worth.
    try testing.expectApproxEqAbs(@as(f32, 100.0 * 34.0 / 160.0), m.at(100, 1, 500 * ms, pace, pace), 1e-3);
}
