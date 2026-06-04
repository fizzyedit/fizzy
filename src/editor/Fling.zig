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

/// Begin a fresh drag: cancel any coast and clear the velocity estimate.
pub fn begin(self: *Fling) void {
    self.coasting = false;
    self.vel = 0.0;
    self.drag_vel = 0.0;
    self.last_drag_ns = dvui.frameTimeNS();
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
