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

    /// Asked for at `now_ns`. Still coming in, it carries on; showing, it stays in and its linger
    /// starts over; gone, it comes in from nothing.
    pub fn stir(self: *Shown, now_ns: i128) void {
        if (self.at_ns) |at| if (now_ns - at < fade_ns) return;
        self.at_ns = if (self.openness(now_ns) > 0) now_ns - fade_ns else now_ns;
    }

    /// How much of the bar shows at `now_ns`, 0 gone to 1 in: in over `fade_ns`, held, and out over
    /// `fade_ns` once it has lingered.
    pub fn openness(self: Shown, now_ns: i128) f32 {
        const at = self.at_ns orelse return 0;
        const since = now_ns - at;
        if (since < 0) return 1;
        if (since < fade_ns) return frac(since, fade_ns);
        const left = linger_ns + fade_ns - since;
        if (left <= 0) return 0;
        return if (left < fade_ns) frac(left, fade_ns) else 1;
    }

    /// When the bar next changes on its own (comes fully in, starts to go, is gone): what its timer
    /// waits for. Null when it is gone, so a bar not showing wakes nothing.
    pub fn nextChange(self: Shown, now_ns: i128) ?i128 {
        const at = self.at_ns orelse return null;
        for ([_]i128{ at + fade_ns, at + linger_ns, at + linger_ns + fade_ns }) |t| if (t > now_ns) return t;
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

    /// What a press at `x` takes hold of on a line from `x0` to `x1`: the nearer handle within
    /// `slop` of the press, else the playhead.
    pub fn grab(self: Trim, x: f32, x0: f32, x1: f32, slop: f32) Grip {
        const xf = stopX(self.from, x0, x1, self.n);
        const xt = stopX(self.to, x0, x1, self.n);
        const df = @abs(x - xf);
        const dt = @abs(x - xt);
        if (@min(df, dt) > slop) return .head;
        // Both as close (a range of one step on a long line): the side the press is on.
        if (df == dt) return if (x < xf) .from else .to;
        return if (df < dt) .from else .to;
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

test "a press takes the nearer handle, else the playhead" {
    const t: Trim = .{ .from = 2, .to = 8, .n = 10 };
    // Stops 10 apart over 0..100.
    try std.testing.expectEqual(Trim.Grip.from, t.grab(22, 0, 100, 5));
    try std.testing.expectEqual(Trim.Grip.to, t.grab(79, 0, 100, 5));
    try std.testing.expectEqual(Trim.Grip.head, t.grab(50, 0, 100, 5));
    const one: Trim = .{ .from = 5, .to = 6, .n = 1000 };
    try std.testing.expectEqual(Trim.Grip.from, one.grab(0.4, 0, 100, 5));
}

/// The step a point `x` on a line from `x0` to `x1` means, in a history of `n` steps: how many
/// of them are applied, 0 (before the first) to `n`. The line is split into `n + 1` equal stops,
/// the point taking the nearest.
pub fn stopAt(x: f32, x0: f32, x1: f32, n: usize) usize {
    if (n == 0 or x1 <= x0) return 0;
    const f = std.math.clamp((x - x0) / (x1 - x0), 0, 1);
    return @intFromFloat(@round(f * @as(f32, @floatFromInt(n))));
}

/// Where stop `i` of `n` sits on the line from `x0` to `x1`.
pub fn stopX(i: usize, x0: f32, x1: f32, n: usize) f32 {
    if (n == 0) return x0;
    return x0 + (x1 - x0) * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
}

// ---- tests ---------------------------------------------------------------------------------

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
