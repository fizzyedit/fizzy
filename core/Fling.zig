//! Reusable flick / momentum helper.
//!
//! Tracks a smoothed drag velocity (sampled once per frame during a drag), then
//! coasts with exponential decay after release. It's one-dimensional: use a single
//! instance for a 1-D scrub (the sprite cover flow) or one per axis for a 2-D pan
//! (the canvas). All values are in the caller's own units — index units, viewport
//! pixels, whatever — so only the `Tuning` thresholds need to match those units.
//!
//! Typical wiring per frame:
//!   press:   fling.begin()
//!   drag:    accumulate this frame's movement, then fling.sample(delta) once
//!   release: if (!fling.release(tuning)) settleImmediately()
//!   draw:    while (fling.coasting) pos += fling.step(tuning).?  // then check coasting

const std = @import("std");
const dvui = @import("dvui");

const Fling = @This();

/// Per-call-site feel tuning. Units match whatever the caller flings.
pub const Tuning = struct {
    /// Velocity decay rate (1/s); higher stops the coast sooner.
    decay: f32 = 4.0,
    /// Minimum release speed needed to start coasting (units/s).
    min_start: f32 = 1.2,
    /// Speed at which the coast ends (units/s).
    stop: f32 = 0.6,
    /// Clamp on coast speed so a hard flick can't run away (units/s).
    max: f32 = 50.0,
    /// If the pointer was still longer than this before release (s), don't coast.
    idle_s: f32 = 0.08,
};

/// How far content follows a finger dragged past its end: the farther past, the less it moves.
pub const Rubber = struct {
    /// How much of the finger's travel shows at the edge itself.
    c: f32,
    /// The overscroll the drag approaches but never reaches (units).
    limit: f32,
};

/// iOS's rubber band in points: about a third of the finger's travel shows at 120 points past.
/// Android stretches or glows instead; when it is done, its value sits beside this one.
pub const rubber_band: Rubber = .{ .c = 0.55, .limit = 101.5 };

/// The overscroll shown for a finger `excess` past the end (either sign).
pub fn rubber(excess: f32, r: Rubber) f32 {
    const x = @abs(excess);
    return std.math.copysign(r.c * x * r.limit / (r.c * x + r.limit), excess);
}

/// The finger travel past the end that `rubber` shows as `overscroll`: where a drag that
/// catches a springing area takes over from.
pub fn unrubber(overscroll: f32, r: Rubber) f32 {
    const o = @min(@abs(overscroll), r.limit * 0.999);
    return std.math.copysign(o * r.limit / (r.c * (r.limit - o)), overscroll);
}

/// A place of interest in a scroll area, in the area's own units.
pub const Notch = struct {
    at: f32,
    /// How far from `at` a release may land, or a lift come to rest, and still be drawn in.
    capture: f32 = 64,
    /// Release speeds at or above this pass the notch (units/s).
    pass_speed: f32 = 1500,
};

/// The decay a coast needs to end on a notch.
pub const Aim = struct { at: f32, decay: f32 };

/// Where a coast released at `origin` with `v` ends: `origin` when it does not start.
pub fn landing(origin: f32, v: f32, t: Tuning) f32 {
    if (@abs(v) <= t.stop) return origin;
    return origin + (v - std.math.sign(v) * t.stop) / t.decay;
}

/// The notch a release at `origin` with `v` lands within reach of, and the decay that ends the
/// coast on it exactly, or null for a release that passes: too fast, or no notch ahead within
/// its capture of the landing. The nearest to the landing wins.
pub fn aim(origin: f32, v: f32, t: Tuning, notches: []const Notch) ?Aim {
    if (@abs(v) <= t.stop) return null;
    const end = landing(origin, v, t);
    var best: ?Notch = null;
    for (notches) |n| {
        if ((n.at - origin) * v <= 0 or @abs(end - n.at) > n.capture or @abs(v) >= n.pass_speed) continue;
        if (best == null or @abs(end - n.at) < @abs(end - best.?.at)) best = n;
    }
    const n = best orelse return null;
    return .{ .at = n.at, .decay = (@abs(v) - t.stop) / @abs(n.at - origin) };
}

/// The position of the notch within whose capture `pos` is, the nearest to it, or null.
pub fn nearest(pos: f32, notches: []const Notch) ?f32 {
    var best: ?f32 = null;
    for (notches) |n| {
        if (@abs(pos - n.at) > n.capture) continue;
        if (best == null or @abs(pos - n.at) < @abs(pos - best.?)) best = n.at;
    }
    return best;
}

/// True while a release coast is still running.
coasting: bool = false,
/// Current coast velocity (units/s).
vel: f32 = 0.0,
/// Smoothed velocity built up during the drag, sampled on release (units/s).
drag_vel: f32 = 0.0,
/// Frame timestamp (ns) of the last frame that had drag motion — used to detect a
/// pause before release, which should cancel the coast.
last_drag_ns: i128 = 0,

// ---- Touch path: windowed velocity (see `sampleTimed` / `releaseWindowed`) ----
// The EMA above divides a single frame's movement by that frame's duration, which is
// fine for the steady event stream a mouse/trackpad produces but unreliable for touch
// on the web: the browser delivers moves in bursts and leaves an irregular gap before
// `touchend`, so the last-frame estimate reads a near-random speed. These fields track
// the recent (position, time) history so release velocity can be averaged over a fixed
// time window instead — immune to a dropped final move and to frame-timing jitter.
hist: [hist_cap]TimedSample = @splat(.{}),
hist_head: usize = 0,
hist_len: usize = 0,
hist_pos: f32 = 0,
/// Diagnostics from the last `releaseWindowed`, for an optional on-screen readout.
last_debug: Debug = .{},

const TimedSample = struct { pos: f32 = 0, t: i128 = 0 };
const hist_cap = 32;
pub const Debug = struct { vel: f32 = 0, idle_s: f32 = 0, dt: f32 = 0, samples: usize = 0, coasted: bool = false };

/// Begin a fresh drag: cancel any coast and clear both velocity estimates.
pub fn begin(self: *Fling) void {
    self.coasting = false;
    self.vel = 0.0;
    self.drag_vel = 0.0;
    self.last_drag_ns = dvui.frameTimeNS();
    self.hist_head = 0;
    self.hist_len = 0;
    self.hist_pos = 0;
}

/// Feed the total drag movement for this frame. Call once per frame that had drag
/// motion — `frameTimeNS` is constant within a frame, so per-event sampling is moot.
pub fn sample(self: *Fling, frame_delta: f32) void {
    const dt = dvui.secondsSinceLastFrame();
    if (dt > 0.0 and dt < 0.1) {
        const inst = frame_delta / dt;
        self.drag_vel = self.drag_vel * 0.6 + inst * 0.4;
    }
    self.last_drag_ns = dvui.frameTimeNS();
}

/// Decide what happens on release. Starts a coast (returns true) when the pointer
/// was still moving fast enough and wasn't paused; otherwise returns false so the
/// caller can settle immediately. Always clears the drag velocity estimate.
pub fn release(self: *Fling, t: Tuning) bool {
    const idle_s: f32 = @floatCast(@as(f64, @floatFromInt(dvui.frameTimeNS() - self.last_drag_ns)) / 1_000_000_000.0);
    const vel = @abs(self.drag_vel);
    // Touch browsers often drop the last motion event before release; still coast fast flicks.
    const fast_flick = vel > t.min_start * 3;
    self.coasting = vel > t.min_start and (idle_s <= t.idle_s or fast_flick);
    if (self.coasting) self.vel = std.math.clamp(self.drag_vel, -t.max, t.max);
    self.drag_vel = 0.0;
    return self.coasting;
}

/// Record one motion sample using its timestamp in the backend nanosecond clock. A sample
/// stamped before the one it follows is held at that one's time: the history only moves forward,
/// so a stray time can't make a speed of one sample's travel over an unrelated gap.
pub fn sampleTimed(self: *Fling, delta: f32, time_ns: i128) void {
    self.hist_pos += delta;
    const t = if (self.hist_len > 0) @max(time_ns, self.histAt(0).t) else time_ns;
    self.hist[self.hist_head] = .{ .pos = self.hist_pos, .t = t };
    self.hist_head = (self.hist_head + 1) % hist_cap;
    if (self.hist_len < hist_cap) self.hist_len += 1;
}

/// `i` counts back from newest: 0 = most recent recorded sample, 1 = the one before…
fn histAt(self: *const Fling, i: usize) TimedSample {
    return self.hist[(self.hist_head + hist_cap - 1 - i) % hist_cap];
}

/// Touch release: average velocity over the last `window_s` of recorded motion and
/// coast if that speed clears `min_start` and the last move wasn't older than
/// `idle_s`. Robust to a dropped final `touchmove` because the window still spans
/// real motion, and to frame jitter because displacement and time come from the same
/// pair of samples. Returns true if a coast started.
pub fn releaseWindowed(self: *Fling, t: Tuning, window_s: f32) bool {
    return self.releaseWindowedAt(t, window_s, dvui.frameTimeNS());
}

/// Release using the input event time in the backend nanosecond clock.
pub fn releaseWindowedAt(self: *Fling, t: Tuning, window_s: f32, time_ns: i128) bool {
    self.coasting = false;
    var dbg: Debug = .{ .samples = self.hist_len };
    if (self.hist_len >= 2) {
        const newest = self.histAt(0);
        const window_ns: i128 = @intFromFloat(@as(f64, window_s) * 1_000_000_000.0);

        // Reach back to the oldest sample still inside the window; fall back to the
        // immediately older one so there are always two points to divide across.
        var old = self.histAt(1);
        var i: usize = 1;
        while (i < self.hist_len) : (i += 1) {
            const s = self.histAt(i);
            if (newest.t - s.t > window_ns) break;
            old = s;
        }

        const dt: f32 = @floatCast(@as(f64, @floatFromInt(newest.t - old.t)) / 1_000_000_000.0);
        const idle_s: f32 = @floatCast(@as(f64, @floatFromInt(time_ns - newest.t)) / 1_000_000_000.0);
        dbg.dt = dt;
        dbg.idle_s = idle_s;
        if (dt > 0.0) {
            const vel = (newest.pos - old.pos) / dt;
            dbg.vel = vel;
            if (@abs(vel) > t.min_start and idle_s <= t.idle_s) {
                self.coasting = true;
                self.vel = std.math.clamp(vel, -t.max, t.max);
            }
        }
    }
    dbg.coasted = self.coasting;
    self.last_debug = dbg;
    self.hist_len = 0;
    return self.coasting;
}

/// Advance the coast by the last frame's duration and return the position delta to apply, or null when
/// not coasting. On the frame the coast finishes it still returns the final delta
/// but leaves `coasting` false, so check `coasting` afterward to detect the stop.
pub fn step(self: *Fling, t: Tuning) ?f32 {
    if (!self.coasting) return null;
    const dt = dvui.secondsSinceLastFrame();
    // The integral of the decaying speed over this frame, not speed times the frame: the
    // position then depends on the elapsed time alone, however it was cut into frames.
    const keep = @exp(-t.decay * dt);
    const delta = self.vel * (1.0 - keep) / t.decay;
    self.vel *= keep;
    if (@abs(self.vel) < t.stop) self.coasting = false;
    return delta;
}

/// Immediately stop any coast (e.g. input got suppressed).
pub fn cancel(self: *Fling) void {
    self.coasting = false;
    self.vel = 0.0;
}

test "the rubber band shows a third of the travel at 120 points and never reaches its limit" {
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0), rubber(120, rubber_band) / 120, 0.01);
    try std.testing.expectEqual(@as(f32, -rubber(300, rubber_band)), rubber(-300, rubber_band));
    try std.testing.expect(rubber(1e6, rubber_band) < rubber_band.limit);
    for ([_]f32{ -250, -3, 0, 40, 300 }) |x| {
        try std.testing.expectApproxEqAbs(x, unrubber(rubber(x, rubber_band), rubber_band), 0.01);
    }
}

test "a sample stamped before the previous one is held at the previous time" {
    var f: Fling = .{};
    f.sampleTimed(10, 100 * std.time.ns_per_ms);
    f.sampleTimed(10, 40 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(i128, 100 * std.time.ns_per_ms), f.histAt(0).t);
    f.sampleTimed(10, 108 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(i128, 108 * std.time.ns_per_ms), f.histAt(0).t);
}

/// Where a coast released at `origin` with `v` stops, from its closed form.
fn coastEnd(origin: f32, v: f32, decay: f32, t: Tuning) f32 {
    return origin + v / decay * (1 - t.stop / @abs(v));
}

test "landing is where the coast ends" {
    const t: Tuning = .{ .decay = 2, .stop = 20 };
    try std.testing.expectEqual(@as(f32, 290), landing(0, 600, t));
    try std.testing.expectEqual(@as(f32, 7), landing(7, 15, t));
    for ([_]f32{ 600, -600, 3000, -3000 }) |v| {
        try std.testing.expectApproxEqAbs(landing(0, v, t), coastEnd(0, v, t.decay, t), 1e-3);
    }
}

test "aim lands the coast on the notch" {
    const t: Tuning = .{ .decay = 2, .stop = 20 };
    const a = aim(0, 600, t, &.{.{ .at = 300 }}).?;
    try std.testing.expectApproxEqAbs(@as(f32, 580.0 / 300.0), a.decay, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 300), coastEnd(0, 600, a.decay, t), 1e-3);
    const back = aim(0, -600, t, &.{.{ .at = -300 }}).?;
    try std.testing.expectApproxEqAbs(@as(f32, -300), coastEnd(0, -600, back.decay, t), 1e-3);
}

test "aim lets a fast, a far or a behind release go" {
    const t: Tuning = .{ .decay = 2, .stop = 20 };
    try std.testing.expectEqual(@as(?Aim, null), aim(0, 2000, t, &.{.{ .at = 1000 }}));
    try std.testing.expectEqual(@as(?Aim, null), aim(0, 600, t, &.{.{ .at = 400 }}));
    try std.testing.expectEqual(@as(?Aim, null), aim(0, 600, t, &.{.{ .at = -50 }}));
}

test "the nearest notch to the landing wins" {
    const t: Tuning = .{ .decay = 2, .stop = 20 };
    try std.testing.expectEqual(@as(f32, 280), aim(0, 600, t, &.{ .{ .at = 330 }, .{ .at = 280 } }).?.at);
    try std.testing.expectEqual(@as(?f32, 280), nearest(290, &.{ .{ .at = 330 }, .{ .at = 280 } }));
    try std.testing.expectEqual(@as(?f32, null), nearest(400, &.{.{ .at = 330 }}));
}
