//! Owner-held glass motion: two springs carry the centre and size in physical coordinates.
//! Close by stepping toward the source box until `moving` is false; no window data is stored.
const std = @import("std");
const motion = @import("glass").motion;
const glass = @import("glass.zig");
const Spring = @import("Spring.zig");

const glass_morph = @This();

center: Spring = .{},
size: Spring = .{},
from: glass.Box = .{ .rect = .{} },
to: glass.Box = .{ .rect = .{} },
started: bool = false,

pub const Tune = struct {
    spring: Spring.Tune = .{ .hz = 4.5, .playful_damping = 0.72 },
    flex: f32 = 0.35,
    /// Points per second at which the lens reaches its full flex.
    flex_speed: f32 = 1800,
};

pub const Frame = struct {
    box: glass.Box,
    t: f32,
    lens: f32,
    blur: f32,
    content_alpha: f32,
    moving: bool,
};

/// Place both springs on the source, with no incoming velocity.
pub fn start(self: *glass_morph, from: glass.Box) void {
    self.* = .{
        .center = .{ .pos = .{ .x = from.rect.x + from.rect.w / 2, .y = from.rect.y + from.rect.h / 2 }, .placed = true },
        .size = .{ .pos = .{ .x = from.rect.w, .y = from.rect.h }, .placed = true },
        .from = from,
    };
}

/// Advance this frame. Assumes a positive physical-pixels-per-point `scale`.
pub fn step(self: *glass_morph, to: glass.Box, dt_s: f32, scale: f32, tune: Tune) Frame {
    if (self.started and !std.meta.eql(to, self.to)) {
        self.from = if (!self.center.moving and !self.size.moving) self.to else self.frameBox(self.progress());
    }
    self.to = to;
    self.started = true;
    const center_moving = self.center.step(.{ .x = to.rect.x + to.rect.w / 2, .y = to.rect.y + to.rect.h / 2 }, dt_s, tune.spring);
    const size_moving = self.size.step(.{ .x = to.rect.w, .y = to.rect.h }, dt_s, tune.spring);
    const moving = center_moving or size_moving;
    if (!moving) return .{ .box = to, .t = 1, .lens = 1, .blur = 1, .content_alpha = 1, .moving = false };
    const t = self.progress();
    const cv = self.center.vel;
    const sv = self.size.vel;
    const speed = @max(@sqrt(cv.x * cv.x + cv.y * cv.y), @sqrt(sv.x * sv.x + sv.y * sv.y)) / scale;
    const play = std.math.clamp((motion.level() - 0.5) * 2, 0, 1);
    return .{
        .box = self.frameBox(t),
        .t = t,
        .lens = 1 - tune.flex * play * smoothstep(0, tune.flex_speed, speed),
        .blur = std.math.clamp(0.15 + 0.85 * t / 0.6, 0, 1),
        .content_alpha = smoothstep(0.45, 0.8, t),
        .moving = moving,
    };
}

fn progress(self: *const glass_morph) f32 {
    const dx = self.to.rect.w - self.from.rect.w;
    const dy = self.to.rect.h - self.from.rect.h;
    const length_sq = dx * dx + dy * dy;
    return if (length_sq == 0) 1 else ((self.size.pos.x - self.from.rect.w) * dx + (self.size.pos.y - self.from.rect.h) * dy) / length_sq;
}

/// Radii follow size progress so corners open with the box, including after a retarget.
fn frameBox(self: *const glass_morph, t: f32) glass.Box {
    var box: glass.Box = .{
        .rect = .{ .x = self.center.pos.x - self.size.pos.x / 2, .y = self.center.pos.y - self.size.pos.y / 2, .w = self.size.pos.x, .h = self.size.pos.y },
        .round = self.to.round,
    };
    for (&box.radii, self.from.radii, self.to.radii) |*r, a, b| r.* = std.math.lerp(a, b, std.math.clamp(t, 0, 1));
    return box;
}

fn smoothstep(lo: f32, hi: f32, value: f32) f32 {
    const t = std.math.clamp((value - lo) / (hi - lo), 0, 1);
    return t * t * (3 - 2 * t);
}
