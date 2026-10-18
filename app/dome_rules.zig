//! The rules of a transport's dome (`dome.zig`): a small glass on the bottom edge of what it
//! drives, holding a liquid, that grows into the transport's bar when the pointer is held on it
//! and takes the bar back in. A document's history transport (`HistoryTransport`) and the demo's
//! tape player (`automation/overlay.zig`) both hide into one.
//!
//! How long the pointer is held before it grows (`Dwell`), how much of it shows (`Presence`), how
//! full it is (`stepsFill`, `progressFill`), its liquid's swing (`Slosh`, a damped spring), and the
//! liquid's shapes (`roundedOutline`, `cut`). Pure decisions over times and sizes, std-only, so they test without a window
//! (`fizzy-dome-tests`).
const std = @import("std");

/// How long the pointer stays on a dome before its bar grows out of it: passing over it on the
/// way somewhere never does.
pub const dwell_ns: i128 = 900 * std.time.ns_per_ms;
/// How long a bar grown from its dome stays once the pointer has left the bar.
pub const leave_ns: i128 = 700 * std.time.ns_per_ms;
/// How high the liquid reaches at its fullest: three quarters, room left to slosh.
pub const fill_top: f32 = 0.75;
/// How a dome fills with steps: `1 - e^(-steps / fill_steps)`, so some 1200 steps (an hour or so
/// of editing) fill it most of the way, and the first few show as a sliver (`min_fill`).
pub const fill_steps: f32 = 600;
pub const min_fill: f32 = 0.08;
/// How much of a dome shows at rest; in use (the pointer on it, a step, a slosh) all of it.
pub const rest_presence: f32 = 0.4;
/// How long a dome takes to come up to use and to settle back.
pub const presence_ns: i128 = 220 * std.time.ns_per_ms;

/// The pointer held on a dome: since when, while it stays there.
pub const Dwell = struct {
    since: ?i128 = null,
    /// It fired, and the pointer has not left since: a pointer left resting on the dome grows the
    /// bar once, not again each time the bar goes back in.
    spent: bool = false,

    /// The pointer is on the dome (`on`) or not at `now_ns`, and the bar is in it to grow out
    /// (`ready`). True once it has stayed `dwell_ns`: the bar grows. It fires again only after the
    /// pointer has left the dome; the bar showing and going under a resting pointer is not leaving.
    pub fn hold(self: *Dwell, on: bool, ready: bool, now_ns: i128) bool {
        if (!on) {
            self.since = null;
            self.spent = false;
            return false;
        }
        if (self.spent or !ready) {
            self.since = null;
            return false;
        }
        const since = self.since orelse now_ns;
        self.since = since;
        if (now_ns - since < dwell_ns) return false;
        self.since = null;
        self.spent = true;
        return true;
    }

    /// How far through its dwell the pointer is, 0 to 1: the dome lightens as it runs.
    pub fn held(self: Dwell, now_ns: i128) f32 {
        const since = self.since orelse return 0;
        return @floatCast(std.math.clamp(@as(f64, @floatFromInt(now_ns - since)) / @as(f64, @floatFromInt(dwell_ns)), 0, 1));
    }
};

/// How full a dome is of a history of `steps`, 0 to 1 (its liquid at `fill_top` of that).
pub fn stepsFill(steps: usize) f32 {
    if (steps == 0) return 0;
    return @max(min_fill, 1 - @exp(-@as(f32, @floatFromInt(steps)) / fill_steps));
}

/// How much of a dome shows: quiet at rest, mostly see-through (`rest_presence`), and all of it
/// while in use, easing between the two over `presence_ns`.
pub const Presence = struct {
    value: f32 = rest_presence,
    at_ns: ?i128 = null,

    /// Moved toward all of it (`in_use`) or rest by `now_ns`; returns how much shows.
    pub fn ease(self: *Presence, in_use: bool, now_ns: i128) f32 {
        const want = target(in_use);
        const since = now_ns - (self.at_ns orelse now_ns);
        const by: f32 = @floatCast(@as(f64, @floatFromInt(since)) / @as(f64, @floatFromInt(presence_ns)) * (1 - rest_presence));
        self.value = if (self.value < want) @min(want, self.value + by) else @max(want, self.value - by);
        self.at_ns = now_ns;
        return self.value;
    }

    /// Still on its way to what `in_use` wants: a frame each until it is there.
    pub fn moving(self: Presence, in_use: bool) bool {
        return self.value != target(in_use);
    }

    fn target(in_use: bool) f32 {
        return if (in_use) 1 else rest_presence;
    }
};

/// How full a dome is of something played `f` (0 to 1) of the way: as far as it has played.
pub fn progressFill(f: f32) f32 {
    return std.math.clamp(f, 0, 1);
}

/// How hard a jump of `by` (a fraction of the whole, its sign the way it went) knocks the liquid.
pub fn knockFor(by: f32) f32 {
    return std.math.clamp(by * 4, -0.8, 0.8);
}

/// A liquid's surface, swinging: a damped spring, its tilt and its speed. A knock (a step made, a
/// scrub) adds to how fast it moves, on top of what it is doing, so knocks close together build on
/// each other or cancel as their timing falls, and no two are the same strength: rapid edits make a
/// living, uneven swing rather than one swing played again. Worked out from the last knock, so it
/// holds nothing but that and asks for frames only until it is still.
pub const Slosh = struct {
    at_ns: ?i128 = null,
    /// Its tilt and speed (tilts a second) at `at_ns`.
    x0: f32 = 0,
    v0: f32 = 0,
    /// Knocks so far: each one's strength varies by it.
    knocks: u32 = 0,

    const hz: f32 = 1.5;
    /// How quickly a swing dies: a share of critical damping.
    const damping: f32 = 0.28;
    /// Below this much swing it is still.
    const still: f32 = 0.01;
    const omega: f32 = 2 * std.math.pi * hz;
    const decay: f32 = damping * omega;
    const omega_d: f32 = omega * @sqrt(1 - damping * damping);

    /// Knocked at `now_ns` by `by` (its sign the way it goes; 1 swings it about all the way on
    /// its own), as strong as 70% to 130% of that.
    pub fn knock(self: *Slosh, now_ns: i128, by: f32) void {
        const st = self.state(now_ns);
        self.knocks +%= 1;
        const h: f32 = @as(f32, @floatFromInt((self.knocks *% 2654435761) >> 16 & 0xffff)) / 65536.0;
        self.x0 = st[0];
        self.v0 = st[1] + by * (0.7 + 0.6 * h) * omega_d;
        self.at_ns = now_ns;
    }

    /// How tipped it is at `now_ns`, -1 to 1.
    pub fn tilt(self: Slosh, now_ns: i128) f32 {
        if (self.settled(now_ns)) return 0;
        return std.math.clamp(self.state(now_ns)[0], -1, 1);
    }

    pub fn settled(self: Slosh, now_ns: i128) bool {
        const at = self.at_ns orelse return true;
        const t = seconds(now_ns - at);
        const b = (self.v0 + decay * self.x0) / omega_d;
        return @exp(-decay * @max(0, t)) * @sqrt(self.x0 * self.x0 + b * b) < still;
    }

    /// Tilt and speed at `now_ns`: the spring's free swing from its last knock.
    fn state(self: Slosh, now_ns: i128) [2]f32 {
        const at = self.at_ns orelse return .{ 0, 0 };
        const t = @max(0, seconds(now_ns - at));
        const b = (self.v0 + decay * self.x0) / omega_d;
        const e = @exp(-decay * t);
        const c = @cos(omega_d * t);
        const sn = @sin(omega_d * t);
        return .{ e * (self.x0 * c + b * sn), e * ((b * omega_d - decay * self.x0) * c - (decay * b + self.x0 * omega_d) * sn) };
    }

    fn seconds(ns: i128) f32 {
        return @floatCast(@as(f64, @floatFromInt(ns)) / std.time.ns_per_s);
    }
};

/// A point of an outline, for the liquid's shapes: x, y.
pub const Pt = [2]f32;

/// The outline of a box at `x`, `y`, `w` by `h`, its corners rounded `r`, into `out` (at least
/// `4 * (corner_points + 1)` long), clockwise with y down. A circle is a square box rounded by half.
pub fn roundedOutline(x: f32, y: f32, w: f32, h: f32, r_in: f32, out: []Pt) []Pt {
    const r = @min(r_in, @min(w, h) / 2);
    const centres = [4]Pt{ .{ x + w - r, y + r }, .{ x + w - r, y + h - r }, .{ x + r, y + h - r }, .{ x + r, y + r } };
    var n: usize = 0;
    for (centres, 0..) |c, corner| {
        const from = (@as(f32, @floatFromInt(corner)) - 1) * std.math.pi / 2;
        for (0..corner_points + 1) |i| {
            const a = from + @as(f32, @floatFromInt(i)) / corner_points * std.math.pi / 2;
            out[n] = .{ c[0] + r * @cos(a), c[1] + r * @sin(a) };
            n += 1;
        }
    }
    return out[0..n];
}
pub const corner_points = 10;

/// The part of convex `poly` on the near side of the line through `at` whose far side `away` (a
/// unit vector) points to (`(p - at) · away <= 0` is kept), into `out` (at least `poly.len + 1`
/// long). Still convex: a liquid is its vessel cut by its surface.
///
/// A point within `on_line` of the line counts as kept. A line just touching the vessel (an
/// untipped surface at a capsule's very end) has its points there either side of it by rounding
/// alone, and each flip would add a point; past `out`'s room, points are dropped rather than
/// written.
pub fn cut(poly: []const Pt, at: Pt, away: Pt, out: []Pt) []Pt {
    var n: usize = 0;
    for (poly, 0..) |p, i| {
        const q = poly[(i + 1) % poly.len];
        const dp = (p[0] - at[0]) * away[0] + (p[1] - at[1]) * away[1];
        const dq = (q[0] - at[0]) * away[0] + (q[1] - at[1]) * away[1];
        const p_in = dp <= on_line;
        if (p_in and n < out.len) {
            out[n] = p;
            n += 1;
        }
        if (p_in != (dq <= on_line) and n < out.len) {
            const t = (dp - on_line) / (dp - dq);
            out[n] = .{ p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t };
            n += 1;
        }
    }
    return out[0..n];
}
/// How near the line a point is on it, in the outline's units (physical pixels): far under one.
const on_line: f32 = 1e-3;

const testing = std.testing;
const ms = std.time.ns_per_ms;

test "a dome grows only for a pointer held on it" {
    var d: Dwell = .{};
    try testing.expect(!d.hold(true, true, 0));
    try testing.expectApproxEqAbs(@as(f32, 0.5), d.held(dwell_ns / 2), 0.001);
    // Passing over: off it before the dwell, and it starts over.
    try testing.expect(!d.hold(false, true, dwell_ns / 2));
    try testing.expectEqual(@as(f32, 0), d.held(dwell_ns));
    try testing.expect(!d.hold(true, true, 1000 * ms));
    try testing.expect(!d.hold(true, true, 1000 * ms + dwell_ns - 1));
    try testing.expect(d.hold(true, true, 1000 * ms + dwell_ns));
    // Fired, a pointer resting there does not fire it again, however long it rests (the bar it
    // grew went back in under it), and asks for nothing meanwhile.
    // The bar out over it (not ready), then back in: still the same resting pointer.
    try testing.expect(!d.hold(true, false, 1000 * ms + dwell_ns + 16 * ms));
    try testing.expect(!d.hold(true, false, 4000 * ms));
    try testing.expect(!d.hold(true, true, 60_000 * ms));
    try testing.expect(d.since == null);
    // Left and come back, it can again.
    try testing.expect(!d.hold(false, true, 61_000 * ms));
    try testing.expect(!d.hold(true, true, 62_000 * ms));
    try testing.expect(d.hold(true, true, 62_000 * ms + dwell_ns));
}

test "a dome is quiet at rest and comes up in use" {
    var pr: Presence = .{};
    try testing.expectEqual(rest_presence, pr.ease(false, 0));
    try testing.expect(!pr.moving(false));
    _ = pr.ease(true, 0);
    try testing.expect(pr.moving(true));
    try testing.expectApproxEqAbs(@as(f32, 0.7), pr.ease(true, presence_ns / 2), 0.001);
    try testing.expectEqual(@as(f32, 1), pr.ease(true, presence_ns * 2));
    try testing.expect(!pr.moving(true));
    try testing.expectEqual(rest_presence, pr.ease(false, presence_ns * 4));
}

test "a dome fills slowly with history, and with play as it plays" {
    try testing.expectEqual(@as(f32, 0), stepsFill(0));
    try testing.expectEqual(min_fill, stepsFill(1));
    try testing.expect(stepsFill(1200) > 0.85);
    try testing.expect(stepsFill(100_000) <= 1);
    try testing.expectEqual(@as(f32, 0.25), progressFill(0.25));
    try testing.expectEqual(@as(f32, 1), progressFill(1.5));
    try testing.expectEqual(@as(f32, 0.8), knockFor(1));
    try testing.expectEqual(@as(f32, -0.4), knockFor(-0.1));
}

test "a knocked liquid swings back level and settles" {
    var sl: Slosh = .{};
    try testing.expectEqual(@as(f32, 0), sl.tilt(0));
    try testing.expect(sl.settled(0));
    sl.knock(1000 * ms, 1);
    try testing.expectEqual(@as(f32, 0), sl.tilt(1000 * ms));
    try testing.expect(sl.tilt(1150 * ms) > 0.3);
    try testing.expect(sl.tilt(1450 * ms) < 0);
    try testing.expect(!sl.settled(1500 * ms));
    try testing.expect(sl.settled(4000 * ms));
    try testing.expectEqual(@as(f32, 0), sl.tilt(4000 * ms));
    for (0..300) |i| try testing.expect(@abs(sl.tilt(1000 * ms + @as(i128, @intCast(i)) * 10 * ms)) <= 1);
}

test "knocks build on the swing they land in" {
    // Knocked again as it swings the same way, it swings further than one knock does; knocked
    // against its swing, less.
    var one: Slosh = .{};
    one.knock(0, 0.4);
    var with: Slosh = .{};
    with.knock(0, 0.4);
    with.knock(20 * ms, 0.4);
    var against: Slosh = .{};
    against.knock(0, 0.4);
    against.knock(20 * ms, -0.4);
    const t = 170 * ms;
    try testing.expect(with.tilt(t) > one.tilt(t));
    try testing.expect(@abs(against.tilt(t)) < one.tilt(t));
    // No two knocks the same strength.
    var a: Slosh = .{};
    a.knock(0, 0.5);
    var b: Slosh = .{ .knocks = 1 };
    b.knock(0, 0.5);
    try testing.expect(a.tilt(t) != b.tilt(t));
}

test "a vessel cut by a surface keeps the part below it" {
    var buf: [4 * (corner_points + 1)]Pt = undefined;
    const square = [_]Pt{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    const below = cut(&square, .{ 0, 4 }, .{ 0, -1 }, &buf);
    try testing.expectEqual(@as(usize, 4), below.len);
    for (below) |p| try testing.expect(p[1] >= 4 - 0.01);
    // Wholly kept, wholly gone.
    try testing.expectEqual(@as(usize, 4), cut(&square, .{ 0, -5 }, .{ 0, -1 }, &buf).len);
    try testing.expectEqual(@as(usize, 0), cut(&square, .{ 0, 20 }, .{ 0, -1 }, &buf).len);
    // A circle's outline is round: every point on it is its radius from the centre.
    for (roundedOutline(0, 0, 20, 20, 10, &buf)) |p| try testing.expectApproxEqAbs(@as(f32, 10), @sqrt((p[0] - 10) * (p[0] - 10) + (p[1] - 10) * (p[1] - 10)), 0.001);
}

test "a capsule cut at its very end keeps all of it, in the room it was given" {
    var outline: [4 * (corner_points + 1)]Pt = undefined;
    // Room to spare, so a cut that needs more than it is promised shows.
    var kept: [outline.len + 8]Pt = undefined;
    // The tube's end point is on its outline twice (two corners' arcs meet there), and rounding put
    // the two either side of a surface through it: two crossings where there is none. Found by a
    // fuzz; it overran the buffer drawing a scrubber's liquid.
    const cases = [_][4]f32{ .{ 663.002, 505.9362, 230.10228, -0.13590178 }, .{ 598.6372, 1015.9274, 77.07582, 0.00040574002 } };
    for (cases) |c| {
        const vessel = roundedOutline(c[0], c[1], c[2], 12, 6, &outline);
        const got = cut(vessel, .{ c[0] + c[2], c[1] + 6 }, .{ @cos(c[3]), @sin(c[3]) }, &kept);
        try testing.expect(got.len <= vessel.len + 1);
        try testing.expect(got.len >= vessel.len / 2);
    }
}
