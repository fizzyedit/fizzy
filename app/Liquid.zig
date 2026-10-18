//! The liquid in a history vial (`dome.paintCorner`): a surface that sloshes as the vial moves and
//! takes in drops that fall into it, as a liquid does.
//!
//! The surface is a row of columns tied to their neighbours by springs (the usual small model of
//! water waves): pulled toward their neighbours' heights, toward rest, and losing energy as they
//! go, with what the row holds kept the same, so a wave moves liquid about rather than making it.
//! The vial moving tips it: its acceleration across the screen, from where the caller says it is
//! each frame, pushes one side down and the other up, as a cup's liquid does when the cup is
//! moved. A new step drops a drop in from the top (`drip`): it falls, lands with a splash at the
//! column it hits, and only then is the level up by it.
//!
//! **It lets the app sleep.** `settled` says when nothing moves — the surface flat, no drop in the
//! air, the level where it is going — and the caller asks for frames only while it is not. A long
//! gap between frames (the app slept, and the vial moved in the frame that woke it) is a new start,
//! not an acceleration.
//!
//! Units are physical pixels and seconds; std-only, so it tests without a window
//! (`build/app.zig`).
const std = @import("std");

const Liquid = @This();

pub const columns = 16;
/// The most drops in the air at once; more wait their turn.
pub const max_drops = 4;

pub const Drop = struct {
    /// Across the vessel, 0 its left to 1 its right.
    x: f32,
    /// Down from the vessel's top, pixels.
    y: f32,
    vy: f32,
};

/// Each column's height over the level, pixels (up positive), and its speed.
h: [columns]f32 = @splat(0),
v: [columns]f32 = @splat(0),
drops: [max_drops]Drop = undefined,
drop_n: usize = 0,
/// Drops asked for and not yet falling (`drip` with the air full).
waiting: usize = 0,
/// The level, 0 to 1, as it is and where it is going (`setLevel`); a drop in the air or waiting
/// holds back its share until it lands.
level: f32 = 0,
target: f32 = 0,
/// Each drop's share of the level, held back until it lands.
per_drop: f32 = 0,
last_ns: i128 = 0,
last_pos: [2]f32 = .{ 0, 0 },
last_vel: [2]f32 = .{ 0, 0 },
/// Which drop comes next, for where it falls.
count: u32 = 0,

/// How strongly a column is pulled toward its neighbours (wave speed), toward rest, and how fast
/// it loses energy, per second.
const tension: f32 = 900;
const stiffness: f32 = 30;
const damping: f32 = 2.6;
/// Pixels of tip per pixel-per-second² of acceleration across, at the vessel's edges.
const tip_gain: f32 = 0.00045;
/// Gravity on a drop, pixels per second².
const gravity: f32 = 2600;
/// How hard a landing drop pushes the column it hits down, pixels per second.
const splash: f32 = 90;
/// How fast the level comes to where it is going, per second.
const level_rate: f32 = 6;
/// A frame gap past this is the app waking, not the vial moving.
const max_gap_ns: i128 = 100 * std.time.ns_per_ms;
/// Steps the simulation takes per second at most.
const step_s: f32 = 1.0 / 240.0;

/// Where the level is going, 0 to 1: the history's fill. A rise asked for by `drip` waits for its
/// drop to land.
pub fn setLevel(self: *Liquid, fill: f32) void {
    self.target = std.math.clamp(fill, 0, 1);
    if (self.last_ns == 0) self.level = self.target;
}

/// A new step: a drop falls in from the top, and the level is up by `share` (0 to 1) once it lands.
pub fn drip(self: *Liquid, share: f32) void {
    self.per_drop = share;
    if (self.drop_n < max_drops) self.launch() else self.waiting += 1;
}

fn launch(self: *Liquid) void {
    // Somewhere across the middle of the vessel, a little differently each time.
    const spread = [_]f32{ 0.5, 0.38, 0.62, 0.45, 0.55, 0.32 };
    self.drops[self.drop_n] = .{ .x = spread[self.count % spread.len], .y = 0, .vy = 0 };
    self.drop_n += 1;
    self.count +%= 1;
}

/// A new step without a drop: the surface splashes where one would have landed, somewhere across
/// the middle, a little differently each time, and the level comes up by itself (`setLevel`).
pub fn splashIn(self: *Liquid) void {
    const spread = [_]f32{ 0.5, 0.38, 0.62, 0.45, 0.55, 0.32 };
    const c: usize = @intFromFloat(@round(spread[self.count % spread.len] * (columns - 1)));
    self.count +%= 1;
    self.v[c] -= splash;
    if (c > 0) self.v[c - 1] -= splash * 0.4;
    if (c < columns - 1) self.v[c + 1] -= splash * 0.4;
}

/// The level the surface is drawn at: where it is, short of what the drops still in the air (or
/// waiting) will add.
pub fn shownLevel(self: *const Liquid) f32 {
    const pending = @as(f32, @floatFromInt(self.drop_n + self.waiting)) * self.per_drop;
    return @max(0, @min(self.level, self.target - pending));
}

/// Advance to `now_ns`, the vial at `pos` (pixels, any fixed point of it on screen), its vessel
/// `width` across and `depth` from its top to the liquid's level: tip the surface by how the
/// vial accelerated, run the waves, and let the drops fall.
pub fn step(self: *Liquid, now_ns: i128, pos: [2]f32, width: f32, depth: f32) void {
    defer {
        self.last_ns = now_ns;
        self.last_pos = pos;
    }
    if (self.last_ns == 0 or now_ns - self.last_ns > max_gap_ns or now_ns <= self.last_ns) {
        self.last_vel = .{ 0, 0 };
        return;
    }
    const dt: f32 = @floatCast(@as(f64, @floatFromInt(now_ns - self.last_ns)) / std.time.ns_per_s);
    const vel: [2]f32 = .{ (pos[0] - self.last_pos[0]) / dt, (pos[1] - self.last_pos[1]) / dt };
    const acc_x = (vel[0] - self.last_vel[0]) / dt;
    self.last_vel = vel;
    // The vial pushed one way, the liquid lags: higher on the side it was pushed from.
    const tip = std.math.clamp(acc_x * tip_gain, -400, 400);
    for (&self.v, 0..) |*v, i| v.* += tip * across(i);

    var left = dt;
    while (left > 0) {
        const h = @min(left, step_s);
        left -= h;
        self.wave(h);
        self.fall(h, width, depth);
    }
    // The level eases to where it is going.
    self.level += (self.shownTarget() - self.level) * @min(1, level_rate * dt);
}

/// What the level eases to: the target, short of the drops still to land.
fn shownTarget(self: *const Liquid) f32 {
    const pending = @as(f32, @floatFromInt(self.drop_n + self.waiting)) * self.per_drop;
    return @max(0, self.target - pending);
}

/// Column `i` across the vessel, -1 at its left to 1 at its right.
fn across(i: usize) f32 {
    return @as(f32, @floatFromInt(i)) / @as(f32, columns - 1) * 2 - 1;
}

fn wave(self: *Liquid, dt: f32) void {
    var force: [columns]f32 = undefined;
    for (0..columns) |i| {
        const l = self.h[if (i == 0) 0 else i - 1];
        const r = self.h[if (i == columns - 1) columns - 1 else i + 1];
        force[i] = tension * (l + r - 2 * self.h[i]) - stiffness * self.h[i];
    }
    const keep = @exp(-damping * dt);
    var mean: f32 = 0;
    for (0..columns) |i| {
        self.v[i] = (self.v[i] + force[i] * dt) * keep;
        self.h[i] += self.v[i] * dt;
        mean += self.h[i];
    }
    // What the row holds stays the same: a wave moves liquid, it makes none.
    mean /= columns;
    for (&self.h) |*h| h.* -= mean;
}

fn fall(self: *Liquid, dt: f32, width: f32, depth: f32) void {
    _ = width;
    var i: usize = 0;
    while (i < self.drop_n) {
        const d = &self.drops[i];
        d.vy += gravity * dt;
        d.y += d.vy * dt;
        const c: usize = @intFromFloat(std.math.clamp(@round(d.x * (columns - 1)), 0, columns - 1));
        // Near the surface, the surface reaches up for it: the two join, not a ball hitting a floor.
        const gap = depth - self.h[c] - d.y;
        if (gap < 6) self.v[c] += (6 - gap) * 40 * dt;
        if (gap <= 0) {
            // Landed: a splash where it hit, and its share in the level.
            self.v[c] -= splash;
            if (c > 0) self.v[c - 1] -= splash * 0.4;
            if (c < columns - 1) self.v[c + 1] -= splash * 0.4;
            self.drops[i] = self.drops[self.drop_n - 1];
            self.drop_n -= 1;
            if (self.waiting > 0) {
                self.waiting -= 1;
                self.launch();
            }
            continue;
        }
        i += 1;
    }
}

/// Nothing moves: the surface flat and still, no drop in the air or waiting, the level where it is
/// going. The caller asks for no frames while this holds.
pub fn settled(self: *const Liquid) bool {
    if (self.drop_n > 0 or self.waiting > 0) return false;
    if (@abs(self.level - self.target) > 0.002) return false;
    for (self.h, self.v) |h, v| if (@abs(h) > 0.05 or @abs(v) > 0.5) return false;
    return true;
}

/// A knock, -1 to 1: the surface tipped as by a sideways push (an undo, a redo).
pub fn knock(self: *Liquid, amount: f32) void {
    for (&self.v, 0..) |*v, i| v.* += amount * 60 * across(i);
}

test "a still vial settles and stays settled" {
    var l: Liquid = .{};
    l.setLevel(0.5);
    var t: i128 = 1;
    for (0..200) |_| {
        l.step(t, .{ 100, 100 }, 40, 30);
        t += 16 * std.time.ns_per_ms;
    }
    try std.testing.expect(l.settled());
}

test "moving the vial tips the surface, and it settles again" {
    var l: Liquid = .{};
    l.setLevel(0.5);
    var t: i128 = 1;
    var x: f32 = 100;
    for (0..10) |_| {
        l.step(t, .{ x, 100 }, 40, 30);
        t += 16 * std.time.ns_per_ms;
        x += 20;
    }
    try std.testing.expect(!l.settled());
    for (0..600) |_| {
        l.step(t, .{ x, 100 }, 40, 30);
        t += 16 * std.time.ns_per_ms;
    }
    try std.testing.expect(l.settled());
}

test "a drop holds back its share until it lands, and the volume stays the same" {
    var l: Liquid = .{};
    l.setLevel(0.2);
    var t: i128 = 1;
    l.step(t, .{ 0, 0 }, 40, 30);
    l.setLevel(0.3);
    l.drip(0.1);
    try std.testing.expect(l.shownLevel() <= 0.2 + 1e-4);
    var landed = false;
    for (0..400) |_| {
        t += 16 * std.time.ns_per_ms;
        l.step(t, .{ 0, 0 }, 40, 30);
        if (l.drop_n == 0) landed = true;
        var sum: f32 = 0;
        for (l.h) |h| sum += h;
        try std.testing.expectApproxEqAbs(@as(f32, 0), sum, 0.01);
    }
    try std.testing.expect(landed);
    try std.testing.expect(l.settled());
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), l.level, 0.01);
}

test "a splash ripples the surface, keeps its volume, and settles" {
    var l: Liquid = .{};
    l.setLevel(0.4);
    var t: i128 = 1;
    l.step(t, .{ 0, 0 }, 40, 30);
    l.splashIn();
    t += 16 * std.time.ns_per_ms;
    l.step(t, .{ 0, 0 }, 40, 30);
    try std.testing.expect(!l.settled());
    for (0..600) |_| {
        t += 16 * std.time.ns_per_ms;
        l.step(t, .{ 0, 0 }, 40, 30);
        var sum: f32 = 0;
        for (l.h) |h| sum += h;
        try std.testing.expectApproxEqAbs(@as(f32, 0), sum, 0.01);
    }
    try std.testing.expect(l.settled());
}

test "a gap between frames is a new start, not a jolt" {
    var l: Liquid = .{};
    l.setLevel(0.5);
    var t: i128 = 1;
    l.step(t, .{ 0, 0 }, 40, 30);
    t += 5 * std.time.ns_per_s;
    l.step(t, .{ 500, 0 }, 40, 30);
    try std.testing.expect(l.settled());
}
