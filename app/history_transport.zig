//! The rules of a document's transport (`HistoryTransport`): when its bar shows and for how long,
//! how far a held undo or redo goes each press, and which step a point on its line is.
//!
//! Pure decisions over times and sizes, std-only, so they test without a window
//! (`fizzy-history-transport-tests`).
const std = @import("std");

/// How long the bar stays once nothing touches it (`plans/RECORDING_PLAN.md`, "Undo is a seek").
pub const linger_ns: i128 = 3 * std.time.ns_per_s;
/// How long it takes to come in, and to go.
pub const fade_ns: i128 = 160 * std.time.ns_per_ms;

/// When the bar was last asked for: an undo, a redo, the pointer on it.
pub const Shown = struct {
    at_ns: ?i128 = null,
    /// How long it takes to come in and to go: `fade_ns`, or longer for a bar that grows.
    fade: i128 = fade_ns,

    /// Asked for at `now_ns`. Still coming in, it carries on; showing, it stays in and its linger
    /// starts over; gone, it comes in from nothing.
    pub fn stir(self: *Shown, now_ns: i128) void {
        if (self.at_ns) |at| if (now_ns - at < self.fade) return;
        self.at_ns = if (self.openness(now_ns) > 0) now_ns - self.fade else now_ns;
    }

    /// How much of the bar shows at `now_ns`, 0 gone to 1 in: in over `fade`, held, and out over
    /// `fade` once it has lingered.
    pub fn openness(self: Shown, now_ns: i128) f32 {
        const at = self.at_ns orelse return 0;
        const since = now_ns - at;
        if (since < 0) return 1;
        if (since < self.fade) return frac(since, self.fade);
        const left = linger_ns + self.fade - since;
        if (left <= 0) return 0;
        return if (left < self.fade) frac(left, self.fade) else 1;
    }

    /// Going at `now_ns`: from as much of it as shows, out over `fade`, as if it had lingered.
    pub fn hide(self: *Shown, now_ns: i128) void {
        const o = self.openness(now_ns);
        if (o <= 0) return;
        // Where its linger would have put it: `left` of its fade still to go.
        const left: i128 = @intFromFloat(@as(f64, o) * @as(f64, @floatFromInt(self.fade)));
        self.at_ns = now_ns - (linger_ns + self.fade - left);
    }

    /// Going by `ns` from `now_ns` at the latest: the pointer left it, and it need not linger its
    /// full time. Sooner already, it keeps its time.
    pub fn soon(self: *Shown, now_ns: i128, ns: i128) void {
        const at = self.at_ns orelse return;
        // Still coming in: it finishes coming in and keeps its linger. Moved earlier now, it would
        // jump to fully in, its growing cut short.
        if (now_ns - at < self.fade) return;
        if (at + linger_ns > now_ns + ns) self.at_ns = now_ns + ns - linger_ns;
    }

    /// When the bar next changes on its own (comes fully in, starts to go, is gone): what its timer
    /// waits for. Null when it is gone, so a bar not showing wakes nothing.
    pub fn nextChange(self: Shown, now_ns: i128) ?i128 {
        const at = self.at_ns orelse return null;
        for ([_]i128{ at + self.fade, at + linger_ns, at + linger_ns + self.fade }) |t| if (t > now_ns) return t;
        return null;
    }

    fn frac(n: i128, d: i128) f32 {
        return @floatCast(@as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(d)));
    }
};

/// Presses closer together than this are a key held down, its repeats.
pub const repeat_gap_ns: i128 = 150 * std.time.ns_per_ms;

/// How far each press of a held undo or redo goes: one step at a time for the first few, then
/// further, so holding the key scrubs a long history in a second or two.
pub const Repeat = struct {
    last_ns: ?i128 = null,
    /// Which way the run goes: a press the other way starts a new one.
    forward: bool = false,
    /// Presses in this run, the first one included.
    run: u32 = 0,

    /// A press at `now_ns`, of redo (`forward`) or undo: how many steps it moves.
    pub fn press(self: *Repeat, now_ns: i128, forward: bool) usize {
        const held = if (self.last_ns) |l| now_ns - l < repeat_gap_ns and forward == self.forward else false;
        self.run = if (held) self.run + 1 else 1;
        self.last_ns = now_ns;
        self.forward = forward;
        return stepsAt(self.run);
    }

    /// The step a run of `run` presses takes: 1 for the first six (a deliberate few undos stay one
    /// at a time), then doubling every four presses, up to 32.
    pub fn stepsAt(run: u32) usize {
        if (run <= 6) return 1;
        const doublings: u5 = @intCast(@min(5, (run - 7) / 4 + 1));
        return @as(usize, 1) << doublings;
    }
};

/// A window over a history of `n` steps (`HistoryTransport`'s export window): the steps from after
/// `from` through `to`, at least one, as macOS's trim keeps the part of a recording between its two
/// handles.
pub const Trim = struct {
    from: usize,
    to: usize,
    n: usize,

    pub fn all(n: usize) Trim {
        return .{ .from = 0, .to = n, .n = n };
    }

    /// What a press at `x` takes hold of on a line from `x0` to `x1`: a handle when the press is on
    /// it, up to `out` outside the window's side (where the bracket's handle is drawn) or `in`
    /// inside it, else the playhead. A handle stands on the outer edge of its stop's cell
    /// (`cellStart`, `cellEnd`); a press on a picture inside the window, however near its side, is
    /// a seek, as a recorder's trim takes a press on its strip.
    pub fn grab(self: Trim, x: f32, x0: f32, x1: f32, out: f32, in: f32) Grip {
        const xf = cellStart(self.from, x0, x1, self.n);
        const xt = cellEnd(self.to, x0, x1, self.n);
        const on_from = x >= xf - out and x <= xf + in;
        const on_to = x >= xt - in and x <= xt + out;
        if (on_from and on_to) {
            // Both (a range of one step on a long line): the side the press is on, else the nearer.
            if (x < xf) return .from;
            if (x > xt) return .to;
            return if (x - xf <= xt - x) .from else .to;
        }
        if (on_from) return .from;
        if (on_to) return .to;
        return .head;
    }

    /// Move what `grip` holds to `stop`, kept inside the history and at least one step apart.
    /// Returns the stop the document shows: the handle's, or the playhead's inside the range.
    pub fn drag(self: *Trim, grip: Grip, stop: usize) usize {
        switch (grip) {
            .from => {
                self.from = @min(stop, self.to - 1);
                return self.from;
            },
            .to => {
                self.to = @max(@min(stop, self.n), self.from + 1);
                return self.to;
            },
            .head => return std.math.clamp(stop, self.from, self.to),
        }
    }

    pub const Grip = enum { from, to, head };
};

test "a trim keeps one step at least, its handles inside the history" {
    var t: Trim = .all(10);
    try std.testing.expectEqual(@as(usize, 9), t.drag(.from, 12));
    try std.testing.expectEqual(@as(usize, 10), t.drag(.to, 3));
    t = .all(10);
    try std.testing.expectEqual(@as(usize, 4), t.drag(.to, 4));
    try std.testing.expectEqual(@as(usize, 3), t.drag(.from, 7));
    try std.testing.expectEqual(@as(usize, 4), t.drag(.head, 9));
    try std.testing.expectEqual(@as(usize, 3), t.drag(.head, 0));
}

test "a press takes a handle it is on, else the playhead" {
    const t: Trim = .{ .from = 2, .to = 8, .n = 10 };
    // 11 cells over 0..110: the window from 20 to 90.
    try std.testing.expectEqual(Trim.Grip.from, t.grab(12, 0, 110, 10, 3));
    try std.testing.expectEqual(Trim.Grip.from, t.grab(22, 0, 110, 10, 3));
    try std.testing.expectEqual(Trim.Grip.to, t.grab(98, 0, 110, 10, 3));
    try std.testing.expectEqual(Trim.Grip.head, t.grab(50, 0, 110, 10, 3));
    // A picture just inside a side is a seek.
    try std.testing.expectEqual(Trim.Grip.head, t.grab(25, 0, 110, 10, 3));
    try std.testing.expectEqual(Trim.Grip.head, t.grab(85, 0, 110, 10, 3));
    const one: Trim = .{ .from = 5, .to = 6, .n = 1000 };
    try std.testing.expectEqual(Trim.Grip.from, one.grab(0.4, 0, 100, 5, 3));
}

/// The step a point `x` on a line from `x0` to `x1` means, in a history of `n` steps: how many
/// of them are applied, 0 (before the first) to `n`. The line is split into `n + 1` equal cells, one
/// a stop, the point taking the cell it is in.
pub fn stopAt(x: f32, x0: f32, x1: f32, n: usize) usize {
    if (n == 0 or x1 <= x0) return 0;
    const f = std.math.clamp((x - x0) / (x1 - x0), 0, 1);
    return @min(n, @as(usize, @intFromFloat(@floor(f * @as(f32, @floatFromInt(n + 1))))));
}

/// Where stop `i` of `n` sits on the line from `x0` to `x1`: the middle of its cell, every cell
/// as wide (a stop's slice of the strip is too: `stripColumns`).
pub fn stopX(i: usize, x0: f32, x1: f32, n: usize) f32 {
    return x0 + (x1 - x0) * (@as(f32, @floatFromInt(i)) + 0.5) / @as(f32, @floatFromInt(n + 1));
}

/// Where stop `i`'s cell begins and ends on the line from `x0` to `x1`.
pub fn cellStart(i: usize, x0: f32, x1: f32, n: usize) f32 {
    return x0 + (x1 - x0) * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n + 1));
}
pub fn cellEnd(i: usize, x0: f32, x1: f32, n: usize) f32 {
    return cellStart(i + 1, x0, x1, n);
}

/// One column of the strip (`stripColumns`): the stop it shows, and the stretch of the strip it
/// takes, from `x0` to `x1`.
pub const Column = struct { stop: usize, x0: f32, x1: f32 };

/// How the strip from `x0` to `x1` is shared among the line's `n + 1` stops, into `out`: each stop
/// its own cell, every one as wide, its knob in the middle (`stopX`), so the picture of the document
/// then stands under the knob that goes there. Too many stops for each to have `min_w`, the strip
/// is cut into columns of `min_w` instead, each showing the stop at its middle (`stopAt`).
/// Returns the columns, left to right, covering the strip.
pub fn stripColumns(n: usize, x0: f32, x1: f32, min_w: f32, out: []Column) []Column {
    const w = x1 - x0;
    if (w <= 0 or out.len == 0) return out[0..0];
    const stops = n + 1;
    if (w / @as(f32, @floatFromInt(stops)) >= min_w and stops <= out.len) {
        for (out[0..stops], 0..) |*c, i| c.* = .{ .stop = i, .x0 = cellStart(i, x0, x1, n), .x1 = cellEnd(i, x0, x1, n) };
        return out[0..stops];
    }
    const count = @min(out.len, @max(1, @as(usize, @intFromFloat(@floor(w / @max(min_w, 1e-3))))));
    const cw = w / @as(f32, @floatFromInt(count));
    for (out[0..count], 0..) |*c, i| {
        const lo = x0 + cw * @as(f32, @floatFromInt(i));
        c.* = .{ .stop = stopAt(lo + cw / 2, x0, x1, n), .x0 = lo, .x1 = lo + cw };
    }
    return out[0..count];
}

/// A part of a picture, as fractions of it: 0 to 1 across and down.
pub const Frac = struct { x: f32 = 0, y: f32 = 0, w: f32 = 1, h: f32 = 1 };

/// The part of a picture `pic_aspect` wide for each high that a strip `want` wide for each high
/// shows (`paintStrip`): round `content` (the whole picture without one), padded by `pad` of its
/// size each side, grown to the strip's shape, and never closer in than `min` of the picture's
/// height. Kept inside the picture, its middle where the content's is as far as that allows. A
/// picture of another shape than the strip, its content all of it, is covered round its middle.
pub fn frameContent(content: ?Frac, pic_aspect: f32, want: f32, pad: f32, min: f32) Frac {
    const a = @max(pic_aspect, 1e-3);
    const c = content orelse Frac{};
    // In the picture's own units: `a` across, 1 down.
    const cw = c.w * a * (1 + 2 * pad);
    const ch = c.h * (1 + 2 * pad);
    var h = @max(@max(ch, cw / want), min);
    var w = h * want;
    if (w > a) {
        w = a;
        h = w / want;
    }
    if (h > 1) {
        h = 1;
        w = want;
    }
    const mx = (c.x + c.w / 2) * a;
    const my = c.y + c.h / 2;
    const x = std.math.clamp(mx - w / 2, 0, a - w);
    const y = std.math.clamp(my - h / 2, 0, 1 - h);
    return .{ .x = x / a, .y = y, .w = w / a, .h = h };
}

/// What the strip frames of `boxes`, each one picture's content: the box round them all, leaving
/// out any far bigger than most (four times the middle one's area), which is something passing
/// over the pane when that picture was taken (the activity feed, a menu), not the document. Null
/// for none.
pub fn contentUnion(boxes: []Frac) ?Frac {
    if (boxes.len == 0) return null;
    std.mem.sort(Frac, boxes, {}, struct {
        fn smaller(_: void, a: Frac, b: Frac) bool {
            return a.w * a.h < b.w * b.h;
        }
    }.smaller);
    const median = boxes[boxes.len / 2];
    const most = 4 * median.w * median.h;
    var u: ?Frac = null;
    for (boxes) |b| {
        if (b.w * b.h > most) break;
        u = if (u) |v| blk: {
            const x0 = @min(v.x, b.x);
            const y0 = @min(v.y, b.y);
            break :blk Frac{ .x = x0, .y = y0, .w = @max(v.x + v.w, b.x + b.w) - x0, .h = @max(v.y + v.h, b.y + b.h) - y0 };
        } else b;
    }
    return u;
}

const testing = std.testing;
const ms = std.time.ns_per_ms;

test "the bar comes in, lingers, goes, and wakes nothing once gone" {
    var s: Shown = .{};
    try testing.expectEqual(@as(f32, 0), s.openness(0));
    try testing.expect(s.nextChange(0) == null);
    s.stir(1000 * ms);
    try testing.expectEqual(@as(f32, 0.5), s.openness(1080 * ms));
    try testing.expectEqual(@as(f32, 1), s.openness(2000 * ms));
    try testing.expectEqual(@as(?i128, 1000 * ms + linger_ns), s.nextChange(2000 * ms));
    try testing.expect(s.openness(1000 * ms + linger_ns + fade_ns / 2) < 1);
    try testing.expectEqual(@as(f32, 0), s.openness(1000 * ms + linger_ns + fade_ns));
    try testing.expect(s.nextChange(1000 * ms + linger_ns + fade_ns) == null);
}

test "asked for again while it shows, it stays in rather than fading in again" {
    var s: Shown = .{};
    s.stir(0);
    try testing.expectEqual(@as(f32, 1), s.openness(1000 * ms));
    s.stir(2500 * ms);
    try testing.expectEqual(@as(f32, 1), s.openness(2500 * ms));
    // Its linger starts again from the stir.
    try testing.expectEqual(@as(f32, 1), s.openness(2500 * ms + linger_ns - fade_ns));
    try testing.expectEqual(@as(f32, 0), s.openness(2500 * ms + linger_ns + 2 * fade_ns));
    // Gone, a stir brings it in from nothing.
    s.stir(60_000 * ms);
    try testing.expect(s.openness(60_000 * ms) < 0.01);
}

test "a held key goes one step at a time, then further" {
    var r: Repeat = .{};
    var got: [16]usize = undefined;
    for (&got, 0..) |*g, i| g.* = r.press(@as(i128, @intCast(i)) * 50 * ms, false);
    try testing.expectEqualSlices(usize, &.{ 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 8, 8 }, &got);
    try testing.expectEqual(@as(usize, 32), Repeat.stepsAt(1000));
    // The other way, at once, is a first press: overshooting and coming back is one step.
    try testing.expectEqual(@as(usize, 1), r.press(16 * 50 * ms, true));
    // A pause, and the next press is a first one again.
    try testing.expectEqual(@as(usize, 1), r.press(10_000 * ms, true));
}

test "a point on the line is the nearest step" {
    try testing.expectEqual(@as(usize, 0), stopAt(0, 0, 100, 10));
    try testing.expectEqual(@as(usize, 10), stopAt(100, 0, 100, 10));
    try testing.expectEqual(@as(usize, 5), stopAt(52, 0, 100, 10));
    try testing.expectEqual(@as(usize, 0), stopAt(-40, 0, 100, 10));
    try testing.expectEqual(@as(usize, 10), stopAt(140, 0, 100, 10));
    try testing.expectEqual(@as(usize, 0), stopAt(50, 0, 100, 0));
    for (0..11) |i| try testing.expectEqual(i, stopAt(stopX(i, 20, 220, 10), 20, 220, 10));
}

test "a bar told to go goes from where it is, and one left goes soon" {
    var sh: Shown = .{};
    sh.stir(0);
    try testing.expectEqual(@as(f32, 1), sh.openness(fade_ns));
    sh.hide(500 * ms);
    try testing.expectApproxEqAbs(@as(f32, 1), sh.openness(500 * ms), 0.001);
    try testing.expect(sh.openness(500 * ms + fade_ns / 2) < 0.6);
    try testing.expectEqual(@as(f32, 0), sh.openness(500 * ms + fade_ns));
    // Half in, it goes from half.
    var half: Shown = .{};
    half.stir(0);
    half.hide(fade_ns / 2);
    try testing.expectApproxEqAbs(@as(f32, 0.5), half.openness(fade_ns / 2), 0.01);
    // Left: it goes after `ns`, not its whole linger.
    var left: Shown = .{};
    left.stir(0);
    left.soon(1000 * ms, 600 * ms);
    try testing.expectEqual(@as(f32, 1), left.openness(1500 * ms));
    try testing.expectEqual(@as(f32, 0), left.openness(1600 * ms + fade_ns));
    // Left while still coming in: it finishes coming in rather than jumping to fully in.
    var growing: Shown = .{};
    growing.stir(0);
    growing.soon(fade_ns / 4, 600 * ms);
    try testing.expectApproxEqAbs(@as(f32, 0.5), growing.openness(fade_ns / 2), 0.01);
    // Gone sooner anyway: unchanged.
    var near: Shown = .{};
    near.stir(0);
    near.soon(linger_ns - 100 * ms, 600 * ms);
    try testing.expectEqual(@as(f32, 0), near.openness(linger_ns + fade_ns));
}

test "each stop takes the stretch of the strip round its knob, or columns share them out" {
    var buf: [64]Column = undefined;
    // Five stops over 100: every cell as wide, its knob in the middle, the ends included.
    const few = stripColumns(4, 0, 100, 2, &buf);
    try testing.expectEqual(@as(usize, 5), few.len);
    for (few, 0..) |c, i| {
        try testing.expectEqual(i, c.stop);
        try testing.expectApproxEqAbs(@as(f32, 20), c.x1 - c.x0, 1e-4);
        try testing.expectApproxEqAbs(stopX(i, 0, 100, 4), (c.x0 + c.x1) / 2, 1e-4);
    }
    try testing.expectEqual(@as(f32, 0), few[0].x0);
    try testing.expectApproxEqAbs(@as(f32, 100), few[4].x1, 1e-4);
    // More stops than room: columns of the least width, each the stop at its middle, in order.
    const many = stripColumns(1000, 0, 100, 4, &buf);
    try testing.expectEqual(@as(usize, 25), many.len);
    try testing.expectEqual(@as(f32, 100), many[many.len - 1].x1);
    for (many[1..], many[0 .. many.len - 1]) |b, a| try testing.expect(b.stop > a.stop);
    // No history: the one stop takes it all.
    const none = stripColumns(0, 10, 50, 2, &buf);
    try testing.expectEqual(@as(usize, 1), none.len);
    try testing.expectEqual(@as(f32, 10), none[0].x0);
    try testing.expectEqual(@as(f32, 50), none[0].x1);
}

test "the strip frames the content, at the strip's shape, inside the picture" {
    const eq = struct {
        fn eq(want: Frac, got: Frac) !void {
            try testing.expectApproxEqAbs(want.x, got.x, 1e-4);
            try testing.expectApproxEqAbs(want.y, got.y, 1e-4);
            try testing.expectApproxEqAbs(want.w, got.w, 1e-4);
            try testing.expectApproxEqAbs(want.h, got.h, 1e-4);
        }
    }.eq;
    // No content known: the picture covers the strip round its middle.
    try eq(.{ .x = 0, .y = 0.25, .w = 1, .h = 0.5 }, frameContent(null, 2, 4, 0.1, 0.3));
    // A few words at the top left: framed close, as close as `min` allows, held to the corner.
    try eq(.{ .x = 0, .y = 0, .w = 0.6, .h = 0.3 }, frameContent(.{ .x = 0, .y = 0, .w = 0.2, .h = 0.1 }, 2, 4, 0.1, 0.3));
    // Content in the middle stays in the middle.
    const mid = frameContent(.{ .x = 0.4, .y = 0.4, .w = 0.2, .h = 0.2 }, 2, 4, 0, 0.1);
    try testing.expectApproxEqAbs(@as(f32, 0.5), mid.x + mid.w / 2, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.5), mid.y + mid.h / 2, 1e-4);
    // Always the strip's shape, in the picture's units.
    for ([_]?Frac{ null, .{ .x = 0.1, .y = 0.7, .w = 0.05, .h = 0.05 }, .{ .x = 0, .y = 0, .w = 1, .h = 1 } }) |c| {
        const f = frameContent(c, 2, 4, 0.1, 0.2);
        try testing.expectApproxEqAbs(@as(f32, 4), f.w * 2 / f.h, 1e-3);
        try testing.expect(f.x >= 0 and f.y >= 0 and f.x + f.w <= 1 + 1e-4 and f.y + f.h <= 1 + 1e-4);
    }
}

test "the strip's content leaves out a picture of something passing over the pane" {
    var boxes = [_]Frac{
        .{ .x = 0, .y = 0, .w = 0.1, .h = 0.03 }, .{ .x = 0, .y = 0, .w = 0.2, .h = 0.03 },
        .{ .x = 0, .y = 0, .w = 0.9, .h = 0.9 },  .{ .x = 0, .y = 0, .w = 0.25, .h = 0.03 },
    };
    const u = contentUnion(&boxes).?;
    try testing.expectApproxEqAbs(@as(f32, 0.25), u.w, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.03), u.h, 1e-5);
    // All of them big: the document fills the pane, and the strip frames it all.
    var big = [_]Frac{ .{ .w = 0.8, .h = 0.9 }, .{ .w = 0.9, .h = 0.9 } };
    try testing.expectApproxEqAbs(@as(f32, 0.9), contentUnion(&big).?.w, 1e-5);
    try testing.expectEqual(@as(?Frac, null), contentUnion(&.{}));
}
