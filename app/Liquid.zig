//! The liquid in a history vial (`dome.paintCorner`): a surface that sloshes as the vial moves and
//! splashes as steps come, as a liquid does.
//!
//! The surface is a row of columns tied to their neighbours by springs (the usual small model of
//! water waves): pulled toward their neighbours' heights, toward rest, and losing energy as they
//! go, with what the row holds kept the same, so a wave moves liquid about rather than making it.
//! The vial moving tips it: its acceleration across the screen, from where the caller says it is
//! each frame, pushes one side down and the other up, as a cup's liquid does when the cup is
//! moved. A new step splashes it (`splashIn`), an undo or redo knocks it (`knock`), and its level
//! eases to the history's fill (`setLevel`).
//!
//! **It lets the app sleep.** `settled` says when nothing moves - the surface flat and still, the
//! level where it is going - and the caller asks for frames only while it is not. A long gap
//! between frames (the app slept, or its frames come slower than the liquid can follow) starts it
//! afresh, still, at its level: frames that never come quickly enough never keep it moving.
//!
//! Units are physical pixels and seconds; std-only, so it tests without a window
//! (`build/app.zig`).
const std = @import("std");

const Liquid = @This();

pub const columns = 16;

/// Each column's height over the level, pixels (up positive), and its speed.
h: [columns]f32 = @splat(0),
v: [columns]f32 = @splat(0),
/// The level, 0 to 1, as it is and where it is going (`setLevel`).
level: f32 = 0,
target: f32 = 0,
last_ns: i128 = 0,
last_pos: [2]f32 = .{ 0, 0 },
last_vel: [2]f32 = .{ 0, 0 },
/// Which splash comes next, for where it lands.
count: u32 = 0,

/// How strongly a column is pulled toward its neighbours (wave speed), toward rest, and how fast
/// it loses energy, per second.
const tension: f32 = 900;
const stiffness: f32 = 30;
const damping: f32 = 2.6;
/// Pixels of tip per pixel-per-second^2 of acceleration across, at the vessel's edges.
const tip_gain: f32 = 0.00045;
/// How hard a splash pushes the column it lands on down, pixels per second.
const splash: f32 = 90;
/// How fast the level comes to where it is going, per second.
const level_rate: f32 = 6;
/// A frame gap past this is a new start, not motion to follow.
const max_gap_ns: i128 = 100 * std.time.ns_per_ms;
/// The longest step the simulation takes, seconds.
const step_s: f32 = 1.0 / 240.0;

/// Where the level is going, 0 to 1: the history's fill.
pub fn setLevel(self: *Liquid, fill: f32) void {
    self.target = std.math.clamp(fill, 0, 1);
    if (self.last_ns == 0) self.level = self.target;
}

/// A new step: the surface splashes where a drop would land, somewhere across the middle, a little
/// differently each time.
pub fn splashIn(self: *Liquid) void {
    const spread = [_]f32{ 0.5, 0.38, 0.62, 0.45, 0.55, 0.32 };
    const c: usize = @intFromFloat(@round(spread[self.count % spread.len] * (columns - 1)));
    self.count +%= 1;
    self.v[c] -= splash;
    if (c > 0) self.v[c - 1] -= splash * 0.4;
    if (c < columns - 1) self.v[c + 1] -= splash * 0.4;
}

/// A knock, -1 to 1: the surface tipped as by a sideways push (an undo, a redo).
pub fn knock(self: *Liquid, amount: f32) void {
    for (&self.v, 0..) |*v, i| v.* += amount * 60 * across(i);
}

/// Advance to `now_ns`, the vial at `pos` (pixels, any fixed point of it on screen): tip the surface
/// by how the vial accelerated, run the waves, and ease the level.
pub fn step(self: *Liquid, now_ns: i128, pos: [2]f32) void {
    defer {
        self.last_ns = now_ns;
        self.last_pos = pos;
    }
    if (self.last_ns == 0 or now_ns - self.last_ns > max_gap_ns or now_ns <= self.last_ns) {
        // A new start: still, at its level.
        self.h = @splat(0);
        self.v = @splat(0);
        self.level = self.target;
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
    }
    self.level += (self.target - self.level) * @min(1, level_rate * dt);
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

/// Nothing moves: the surface flat and still, the level where it is going. The caller asks for no
/// frames while this holds.
pub fn settled(self: *const Liquid) bool {
    if (@abs(self.level - self.target) > 0.002) return false;
    for (self.h, self.v) |h, v| if (@abs(h) > 0.05 or @abs(v) > 0.5) return false;
    return true;
}

test "a still vial settles and stays settled" {
    var l: Liquid = .{};
    l.setLevel(0.5);
    var t: i128 = 1;
    for (0..200) |_| {
        l.step(t, .{ 100, 100 });
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
        l.step(t, .{ x, 100 });
        t += 16 * std.time.ns_per_ms;
        x += 20;
    }
    try std.testing.expect(!l.settled());
    for (0..600) |_| {
        l.step(t, .{ x, 100 });
        t += 16 * std.time.ns_per_ms;
    }
    try std.testing.expect(l.settled());
}

test "a splash ripples the surface, keeps its volume, and settles" {
    var l: Liquid = .{};
    l.setLevel(0.4);
    var t: i128 = 1;
    l.step(t, .{ 0, 0 });
    l.splashIn();
    t += 16 * std.time.ns_per_ms;
    l.step(t, .{ 0, 0 });
    try std.testing.expect(!l.settled());
    for (0..600) |_| {
        t += 16 * std.time.ns_per_ms;
        l.step(t, .{ 0, 0 });
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
    l.step(t, .{ 0, 0 });
    t += 5 * std.time.ns_per_s;
    l.step(t, .{ 500, 0 });
    try std.testing.expect(l.settled());
}

test "frames always too slow to follow still settle, so the app can sleep" {
    var l: Liquid = .{};
    l.setLevel(0.2);
    var t: i128 = 1;
    l.step(t, .{ 0, 0 });
    l.splashIn();
    l.setLevel(0.6);
    t += 200 * std.time.ns_per_ms;
    l.step(t, .{ 0, 0 });
    try std.testing.expect(l.settled());
}
