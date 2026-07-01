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
hist: [hist_cap]TimedSample = [_]TimedSample{.{}} ** hist_cap,
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

/// Touch sampling: record this frame's movement into the position/time history.
/// Call once per frame the drag moved, exactly like `sample`.
pub fn sampleTimed(self: *Fling, frame_delta: f32) void {
    self.hist_pos += frame_delta;
    self.hist[self.hist_head] = .{ .pos = self.hist_pos, .t = dvui.frameTimeNS() };
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
        const idle_s: f32 = @floatCast(@as(f64, @floatFromInt(dvui.frameTimeNS() - newest.t)) / 1_000_000_000.0);
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

/// Advance the coast one frame and return the position delta to apply, or null when
/// not coasting. On the frame the coast finishes it still returns the final delta
/// but leaves `coasting` false, so check `coasting` afterward to detect the stop.
pub fn step(self: *Fling, t: Tuning) ?f32 {
    if (!self.coasting) return null;
    const dt = dvui.secondsSinceLastFrame();
    const delta = self.vel * dt;
    self.vel *= @exp(-t.decay * dt);
    if (@abs(self.vel) < t.stop) self.coasting = false;
    return delta;
}

/// Immediately stop any coast (e.g. input got suppressed).
pub fn cancel(self: *Fling) void {
    self.coasting = false;
    self.vel = 0.0;
}
