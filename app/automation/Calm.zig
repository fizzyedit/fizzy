//! Where a callout is, frame to frame: a guide's calm rather than a label stuck to the pointer.
//!
//! A callout keeps its spot while the spot is still good - on the window, clear of everything the
//! viewer is watching, near enough to what it is about - and moves only on the tape's beats: when
//! what it is about changes (a new subject), or when its spot stops being good (a bar grew over it,
//! the subject moved away). A pointer's wiggle is neither, so it stays put through one. When it
//! moves, it goes once to the best spot by the new subject (`choose`), along a gentle curve eased in
//! and out, over 300-600 ms by how far it goes; with motion off it jumps there instead, with the same
//! calm about when.
//!
//! Pure: the overlay hands it what it measured (`In`), in natural units and demo time, and draws
//! where it says. Kept in dvui's data between frames, one per caption showing.
const Calm = @This();

const std = @import("std");
const dvui = @import("dvui");
const Side = @import("tape").Tape.Caption.Side;

/// The caption this is the state of (`Caption.at`); another one starts afresh.
caption: ?u32 = null,
/// What it is about, as `In.subject` keys it.
subject: u64 = 0,
/// Where it belongs (top-left, natural), and the point in it (fractions) it opens from.
spot: dvui.Point = .{},
origin: dvui.Point = .{ .x = 0.5, .y = 0.5 },
/// The travel to `spot` underway, if any: from where, bowed through `ctrl`, starting at `start`
/// (demo ms) and taking `ms`.
from: dvui.Point = .{},
ctrl: dvui.Point = .{},
start: f64 = 0,
ms: f64 = 0,
/// The demo time last seen: going back is a seek, after which it is placed afresh.
seen: f64 = 0,

/// The space between a callout and what it is beside.
pub const gap: f32 = 14;
/// How far a callout may be from what it is about and still be beside it.
pub const reach: f32 = 120;
/// How long it rests after arriving (`start` + `ms`) before anything short of an overlap moves it
/// again.
pub const dwell_ms: f64 = 450;
/// A step of demo time longer than this between frames is a seek, after which it is placed afresh
/// rather than flown across from where it was.
pub const seek_ms: f64 = 400;
/// Its spot moving by less than this while it travels changes where the travel ends rather than
/// starting it over: a bar growing over it pushes it along, not back to the start of its ease.
pub const retarget: f32 = 32;
/// Its travel's shortest and longest, as written: a short hop at the one, across the window at the
/// other.
pub const travel_min_ms: f32 = 300;
pub const travel_max_ms: f32 = 600;

/// What the overlay measured this frame.
pub const In = struct {
    /// The caption showing (`Caption.at`).
    caption: u32,
    /// What it is about, as a key: changes when the tape's focus goes to something else.
    subject: u64,
    /// That subject's rect, and everything it must stay clear of (natural). The subject's own rect
    /// is kept clear of too. No subject: it waits at `home` (its top-left) until there is one.
    near: ?dvui.Rect,
    home: dvui.Point = .{},
    keep: []const dvui.Rect,
    /// Where its top-left may be: the window less its margins, above the bar.
    bounds: dvui.Rect,
    size: dvui.Size,
    /// Demo time, ms.
    now: f64,
    /// `ms` at the user's motion speed (`motion.durationMs(1)`): 0 jumps.
    rate: f32,
    side: Side = .any,
    /// Where it belongs, now, with no history: it is opening, and is placed by its size, which it
    /// only has once drawn.
    fresh: bool = false,
    /// Where it is, and no further: it is closing.
    hold: bool = false,
};

pub const Out = struct {
    at: dvui.Point,
    origin: dvui.Point,
    /// Still on its way: the caller asks for another frame.
    moving: bool,
};

/// Where the callout is this frame.
pub fn update(self: *Calm, in: In) Out {
    const seek = in.now < self.seen or in.now - self.seen > seek_ms;
    self.seen = in.now;
    if (in.fresh or seek or self.caption == null or self.caption.? != in.caption) {
        self.caption = in.caption;
        self.subject = in.subject;
        self.place(choose(in, null), in.now);
        return self.out(in.now);
    }
    if (in.hold) return self.out(in.now);

    const here = self.position(in.now);
    const covered = overlap(card(self.spot, in.size), in.near, in.keep);
    const on_way = self.travelling(in.now);
    const settled = !on_way and in.now - (self.start + self.ms) >= dwell_ms;
    const good = self.fits(in);
    if (covered > 0 or (settled and (in.subject != self.subject or !good))) {
        self.subject = in.subject;
        const to = choose(in, here);
        // Where nothing is clear, only for a spot that covers much less, or when where it is is
        // no good at all: not round and round the least bad ones.
        const better = to.covered == 0 or to.covered < covered * 0.5 or (covered == 0 and !good);
        if (better and dist(to.at, self.spot) > 1) {
            if (on_way and dist(to.at, self.spot) < retarget) {
                self.spot = to.at;
                self.origin = to.origin;
            } else self.go(to, here, in);
        }
    }
    return self.out(in.now);
}

fn place(self: *Calm, to: Spot, now: f64) void {
    self.spot = to.at;
    self.origin = to.origin;
    self.from = to.at;
    self.ctrl = to.at;
    self.ms = 0;
    self.start = now;
}

/// Travel from `here` to `to`: a curve bowed a little to one side, longer the further it goes.
fn go(self: *Calm, to: Spot, here: dvui.Point, in: In) void {
    const d = dist(here, to.at);
    const ms = std.math.clamp(travel_min_ms + d * 0.45, travel_min_ms, travel_max_ms) * in.rate;
    if (ms <= 0) return self.place(to, in.now);
    const mid: dvui.Point = .{ .x = (here.x + to.at.x) / 2, .y = (here.y + to.at.y) / 2 };
    // A tenth of the way off the straight line, always to the same hand.
    const bow: f32 = 0.1;
    self.from = here;
    self.ctrl = .{ .x = mid.x - (to.at.y - here.y) * bow, .y = mid.y + (to.at.x - here.x) * bow };
    self.spot = to.at;
    self.origin = to.origin;
    self.start = in.now;
    self.ms = ms;
}

fn travelling(self: *const Calm, now: f64) bool {
    return self.ms > 0 and now < self.start + self.ms;
}

/// Where it is at `now`, along its travel.
fn position(self: *const Calm, now: f64) dvui.Point {
    if (!self.travelling(now) or now < self.start) return self.spot;
    const u: f32 = @floatCast((now - self.start) / self.ms);
    const e = easeInOut(u);
    const a = 1 - e;
    return .{
        .x = a * a * self.from.x + 2 * a * e * self.ctrl.x + e * e * self.spot.x,
        .y = a * a * self.from.y + 2 * a * e * self.ctrl.y + e * e * self.spot.y,
    };
}

fn out(self: *const Calm, now: f64) Out {
    return .{ .at = self.position(now), .origin = self.origin, .moving = self.travelling(now) };
}

/// Its spot is still a good one: on the window and near enough to what it is about.
fn fits(self: *const Calm, in: In) bool {
    const r = card(self.spot, in.size);
    const b = in.bounds;
    const on = r.x >= b.x - 0.5 and r.y >= b.y - 0.5 and r.x <= b.x + b.w + 0.5 and r.y <= b.y + b.h + 0.5;
    const near = in.near orelse return on and dist(self.spot, in.home) < 1;
    return on and apart(r, near) <= reach;
}

/// The ease of its travel: slow away, slow in, no overshoot - a guide does not swing.
fn easeInOut(t: f32) f32 {
    const u = std.math.clamp(t, 0, 1);
    return if (u < 0.5) 4 * u * u * u else 1 - std.math.pow(f32, -2 * u + 2, 3) / 2;
}

pub const Spot = struct {
    at: dvui.Point,
    origin: dvui.Point = .{ .x = 0.5, .y = 0.5 },
    /// How much of what it must keep clear it covers: 0 but where nothing is clear.
    covered: f32 = 0,
};

/// The best spot for it: beside what it is about - right, below, left or above it, then the
/// window's corners - taking only one that covers none of it and nothing it must keep clear, and
/// among those the nearest, the side the tape asks for (`In.side`) first, and `here` (where it is)
/// if it is one of them. Failing every one, the one that covers least.
///
/// What it is beside is the subject together with whatever it must keep clear that touches it: a
/// bar grown out of a grip, a menu opened from a button. It goes beside the whole of that, not
/// into it.
pub fn choose(in: In, here: ?dvui.Point) Spot {
    var near = in.near orelse return .{ .at = in.home, .origin = .{ .x = 0.5, .y = 1 } };
    // Till nothing more joins: a menu item touching only the menu that touches the button.
    var joined = std.StaticBitSet(64).empty;
    var more = true;
    while (more) {
        more = false;
        for (in.keep[0..@min(in.keep.len, 64)], 0..) |k, i| if (!joined.isSet(i) and apart(k, near) < gap) {
            near = near.unionWith(k);
            joined.set(i);
            more = true;
        };
    }
    const size = in.size;
    const cx = near.x + near.w / 2;
    const cy = near.y + near.h / 2;
    // Below or above, its words line up with what it is beside.
    const lined = near.x - 18;
    const b = in.bounds;
    const Try = struct { at: dvui.Point, side: Side };
    const tries = [_]Try{
        .{ .at = .{ .x = near.x + near.w + gap, .y = cy - size.h / 2 }, .side = .right },
        .{ .at = .{ .x = lined, .y = near.y + near.h + gap }, .side = .below },
        .{ .at = .{ .x = near.x - gap - size.w, .y = cy - size.h / 2 }, .side = .left },
        .{ .at = .{ .x = lined, .y = near.y - gap - size.h }, .side = .above },
        .{ .at = .{ .x = b.x, .y = b.y }, .side = .any },
        .{ .at = .{ .x = b.x + b.w, .y = b.y }, .side = .any },
        .{ .at = .{ .x = b.x, .y = b.y + b.h }, .side = .any },
        .{ .at = .{ .x = b.x + b.w, .y = b.y + b.h }, .side = .any },
    };
    var best: Spot = undefined;
    var best_score = std.math.inf(f32);
    var least: Spot = undefined;
    var least_covered = std.math.inf(f32);
    for (tries, 0..) |t, i| {
        const at: dvui.Point = .{
            .x = std.math.clamp(t.at.x, b.x, @max(b.x, b.x + b.w)),
            .y = std.math.clamp(t.at.y, b.y, @max(b.y, b.y + b.h)),
        };
        const r = card(at, size);
        // It opens out of the side facing what it is beside.
        const along_x = if (size.w > 0) std.math.clamp((cx - at.x) / size.w, 0, 1) else 0.5;
        const along_y = if (size.h > 0) std.math.clamp((cy - at.y) / size.h, 0, 1) else 0.5;
        const spot: Spot = .{ .at = at, .origin = switch (t.side) {
            .right => .{ .x = 0, .y = along_y },
            .below => .{ .x = along_x, .y = 0 },
            .left => .{ .x = 1, .y = along_y },
            .above => .{ .x = along_x, .y = 1 },
            .any => .{ .x = along_x, .y = along_y },
        }, .covered = 0 };
        const covered = overlap(r, in.near, in.keep);
        if (covered < least_covered) {
            least = spot;
            least.covered = covered;
            least_covered = covered;
        }
        if (covered > 0) continue;
        // Nearest first, the sides in order after; the side asked for, and staying, well ahead.
        var score = apart(r, near) + @as(f32, @floatFromInt(i)) * 6;
        if (i >= 4) score += 2 * reach;
        if (in.side != .any and t.side == in.side) score -= 4 * reach;
        if (here) |h| score += dist(h, at) * 0.25;
        if (score < best_score) {
            best = spot;
            best_score = score;
        }
    }
    return if (best_score < std.math.inf(f32)) best else least;
}

fn card(at: dvui.Point, size: dvui.Size) dvui.Rect {
    return .{ .x = at.x, .y = at.y, .w = size.w, .h = size.h };
}

/// How much of `r` covers `near` and everything in `keep`.
fn overlap(r: dvui.Rect, near: ?dvui.Rect, keep: []const dvui.Rect) f32 {
    var covered = if (near) |n| area(r.intersect(n)) else 0;
    for (keep) |k| covered += area(r.intersect(k));
    return covered;
}

fn area(r: dvui.Rect) f32 {
    return @max(0, r.w) * @max(0, r.h);
}

/// The gap between two rects: 0 when they touch or overlap.
fn apart(a: dvui.Rect, b: dvui.Rect) f32 {
    const dx = @max(0, @max(b.x - (a.x + a.w), a.x - (b.x + b.w)));
    const dy = @max(0, @max(b.y - (a.y + a.h), a.y - (b.y + b.h)));
    return @sqrt(dx * dx + dy * dy);
}

fn dist(a: dvui.Point, b: dvui.Point) f32 {
    return @sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
}

// ---- tests ---------------------------------------------------------------------------------

const testing = std.testing;

const win: dvui.Rect = .{ .x = 16, .y = 16, .w = 1000, .h = 700 };
const test_size: dvui.Size = .{ .w = 240, .h = 60 };

fn input(subject: u64, near: dvui.Rect, keep: []const dvui.Rect, now: f64) In {
    return .{ .caption = 7, .subject = subject, .near = near, .keep = keep, .bounds = .{ .x = win.x, .y = win.y, .w = win.w - test_size.w, .h = win.h - test_size.h }, .size = test_size, .now = now, .rate = 1 };
}

/// Frames of 16 ms from `t0` to `t1`, `f` giving each frame's input; the spots it went to.
// anytype: Test scenarios provide distinct frame input generators through in(t).
fn run(c: *Calm, t0: f64, t1: f64, f: anytype) !struct { moves: usize, last: dvui.Point } {
    var moves: usize = 0;
    var spot = c.spot;
    var t = t0;
    var last: dvui.Point = undefined;
    while (t < t1) : (t += 16) {
        last = c.update(f.in(t)).at;
        if (dist(c.spot, spot) > 0.01) moves += 1;
        spot = c.spot;
    }
    return .{ .moves = moves, .last = last };
}

test "a pointer's jitter about the same subject does not move it" {
    var c: Calm = .{};
    const base: dvui.Rect = .{ .x = 400, .y = 300, .w = 24, .h = 24 };
    _ = c.update(input(1, base, &.{}, 0));
    const first = c.spot;
    const Jitter = struct {
        base: dvui.Rect,
        fn in(self: @This(), t: f64) In {
            const k: f32 = @floatCast(@sin(t / 37));
            return input(1, self.base.offsetPoint(.{ .x = k * 9, .y = -k * 7 }), &.{}, t);
        }
    };
    const r = try run(&c, 16, 3000, Jitter{ .base = base });
    try testing.expectEqual(@as(usize, 0), r.moves);
    try testing.expectEqual(first, c.spot);
}

test "a new subject far off moves it once, along an eased path, in the calm range" {
    var c: Calm = .{};
    const a: dvui.Rect = .{ .x = 100, .y = 100, .w = 30, .h = 30 };
    const b: dvui.Rect = .{ .x = 600, .y = 500, .w = 30, .h = 30 };
    // Rested where it came up.
    var t0: f64 = 0;
    while (t0 <= 600) : (t0 += 16) _ = c.update(input(1, a, &.{}, t0));
    const start = c.spot;
    const Jump = struct {
        b: dvui.Rect,
        fn in(self: @This(), t: f64) In {
            // A wiggle on the way, and once there.
            const k: f32 = @floatCast(@sin(t / 23) * 4);
            return input(2, self.b.offsetPoint(.{ .x = k, .y = k }), &.{}, t);
        }
    };
    var steps: [64]dvui.Point = undefined;
    var n: usize = 0;
    var t: f64 = t0;
    while (t < t0 + 1000) : (t += 16) {
        const o = c.update(Jump.in(.{ .b = b }, t));
        if (n < steps.len) steps[n] = o.at;
        n += 1;
    }
    try testing.expect(dist(start, c.spot) > 300);
    try testing.expect(c.ms >= travel_min_ms and c.ms <= travel_max_ms);
    // Eased: the first and last frames move less than the middle ones.
    const d0 = dist(steps[0], steps[1]);
    const mid: usize = @intFromFloat(c.ms / 16 / 2);
    const dm = dist(steps[mid], steps[mid + 1]);
    try testing.expect(d0 < dm / 3);
    try testing.expectEqual(c.spot, steps[n - 1]);
    // And it went once: nothing after moved it.
    const r = try run(&c, t, t + 2000, Jump{ .b = b });
    try testing.expectEqual(@as(usize, 0), r.moves);
}

test "it never covers a bar grown out of its subject, nor the subject" {
    var c: Calm = .{};
    // A grip at the foot of a page; then a history bar grows out of it along the foot.
    const grip: dvui.Rect = .{ .x = 480, .y = 640, .w = 40, .h = 10 };
    _ = c.update(input(1, grip, &.{}, 0));
    var t: f64 = 16;
    while (t < 2000) : (t += 16) {
        const grown: f32 = @floatCast(std.math.clamp((t - 500) / 400, 0, 1));
        const bar: dvui.Rect = .{ .x = 500 - 400 * grown, .y = 600 - 20 * grown, .w = 800 * grown, .h = 60 + 20 * grown };
        const keep: []const dvui.Rect = if (grown > 0) &.{bar} else &.{};
        const o = c.update(input(1, grip, keep, t));
        const r = card(c.spot, test_size);
        try testing.expectEqual(@as(f32, 0), area(r.intersect(grip)));
        if (grown > 0) try testing.expectEqual(@as(f32, 0), area(r.intersect(bar)));
        if (!o.moving) try testing.expectEqual(@as(f32, 0), overlap(card(o.at, test_size), grip, keep));
    }
}

test "a side the tape asks for is taken when it is clear" {
    const near: dvui.Rect = .{ .x = 400, .y = 300, .w = 40, .h = 20 };
    const plain = choose(input(1, near, &.{}, 0), null);
    try testing.expect(plain.at.x > near.x); // right, by default
    var in = input(1, near, &.{}, 0);
    in.side = .above;
    try testing.expect(choose(in, null).at.y + test_size.h <= near.y);
}

test "with motion off it jumps, with the same calm about when" {
    var c: Calm = .{};
    const a: dvui.Rect = .{ .x = 100, .y = 100, .w = 30, .h = 30 };
    const b: dvui.Rect = .{ .x = 600, .y = 500, .w = 30, .h = 30 };
    var in = input(1, a, &.{}, 0);
    in.rate = 0;
    var t: f64 = 0;
    while (t <= 600) : (t += 50) {
        in.now = t;
        _ = c.update(in);
    }
    const start = c.spot;
    in.near = b;
    in.subject = 2;
    in.now = 650;
    const o = c.update(in);
    try testing.expect(!o.moving);
    try testing.expect(dist(start, c.spot) > 300);
    try testing.expectEqual(c.spot, o.at);
    // A wiggle of the same subject, rested or not, still does not move it.
    const there = c.spot;
    t = 700;
    while (t <= 2000) : (t += 50) {
        in.now = t;
        const k: f32 = @floatCast(@sin(t / 23) * 8);
        in.near = b.offsetPoint(.{ .x = k, .y = k });
        _ = c.update(in);
        try testing.expectEqual(there, c.spot);
    }
}

test "a step forward in demo time is a seek: placed afresh, not flown across" {
    var c: Calm = .{};
    _ = c.update(input(1, .{ .x = 100, .y = 100, .w = 30, .h = 30 }, &.{}, 0));
    const o = c.update(input(2, .{ .x = 600, .y = 500, .w = 30, .h = 30 }, &.{}, 5000));
    try testing.expect(!o.moving);
    try testing.expectEqual(c.spot, o.at);
}
