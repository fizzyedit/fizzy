//! A point that follows a moving target on a damped spring: for motion driven by the pointer,
//! where the target changes every frame and an animation curve keyed to a start time would have
//! to restart — kinking the motion — each time it did.
//!
//! Stepped by hand each frame (`step`), with the frame's time: a spring keeps its velocity when
//! its target moves, so a drop dragged fast stretches out behind the pointer and, let go of, swings
//! past where it was going and settles. How springy is the app's motion level (`core.motion`):
//! playful overshoots, minimal arrives without overshoot, off goes straight to the target.
const std = @import("std");
const dvui = @import("dvui");
const motion = @import("motion.zig");

const Spring = @This();

pos: dvui.Point.Physical = .{},
vel: dvui.Point.Physical = .{},
/// False until the first `step` puts it on its target.
placed: bool = false,

/// How a spring moves: how quickly it closes on its target, and how much it swings past.
pub const Tune = struct {
    /// Hertz: its natural frequency — how quick it is, before damping.
    hz: f32 = 6,
    /// Damping at playful: under 1 swings past the target and back. Minimal and below are
    /// critically damped (1): no overshoot.
    playful_damping: f32 = 0.5,
};

/// The damping ratio at the app's motion level: `playful_damping` at playful, 1 at minimal.
pub fn damping(t: Tune) f32 {
    const play = std.math.clamp((motion.level() - 0.5) * 2, 0, 1);
    return 1 + (t.playful_damping - 1) * play;
}

/// Move toward `target` over `dt_s` seconds. Returns whether it is still moving — keep frames
/// coming while it is.
pub fn step(self: *Spring, target: dvui.Point.Physical, dt_s: f32, t: Tune) bool {
    if (!self.placed or motion.off()) {
        self.* = .{ .pos = target, .placed = true };
        return false;
    }
    const w = 2 * std.math.pi * t.hz * motion.rate();
    const z = damping(t);
    // A frame's step in small pieces: semi-implicit Euler is stable well under w·h ≈ 1, and a
    // dropped frame's long step would otherwise throw the spring.
    var left = std.math.clamp(dt_s, 0, 0.1);
    const h_max: f32 = 0.004;
    while (left > 0) {
        const h = @min(left, h_max);
        left -= h;
        const ax = -w * w * (self.pos.x - target.x) - 2 * z * w * self.vel.x;
        const ay = -w * w * (self.pos.y - target.y) - 2 * z * w * self.vel.y;
        self.vel.x += ax * h;
        self.vel.y += ay * h;
        self.pos.x += self.vel.x * h;
        self.pos.y += self.vel.y * h;
    }
    const dx = self.pos.x - target.x;
    const dy = self.pos.y - target.y;
    const resting = dx * dx + dy * dy < 0.04 and self.vel.x * self.vel.x + self.vel.y * self.vel.y < 1;
    if (resting) {
        self.pos = target;
        self.vel = .{};
    }
    return !resting;
}
