//! Which card of a list a carousel shows, and the slide between two: pure state with no drawing,
//! so what the buttons do is tested without a window.
//!
//! Cards are named by a hash of their id, never by position, so a card the provider drops (the
//! person answered it) is noticed by the carousel rather than shifting the one shown under the
//! person's eyes. Going past the last card wraps to the first and back, as a carousel does; a
//! lone card has nowhere to go and no slide.
const std = @import("std");
const FrameClock = @import("core").FrameClock;

const Carousel = @This();

pub const Dir = enum { next, prev };

/// The card shown, by position. `sync` keeps it in range.
index: usize = 0,
/// The card shown at the last `sync`: a different one under `index` (the one before it was
/// answered, or the list was reordered) slides the new one in.
shown: ?u64 = null,
slide: ?Slide = null,

/// A slide in progress: the card going out (when it still exists) and the one coming in, both
/// moving the way `dir` says.
pub const Slide = struct {
    dir: Dir,
    /// The card leaving: its place in the list, and its hash to know it is still there.
    from: ?struct { index: usize, hash: u64 } = null,
    clock: FrameClock = .{},
};

pub const Offsets = struct {
    /// Where the card coming in is, in `width`s from its place: 0 once it has arrived.
    entering: f32,
    /// Where the one going out is: 0 at the start, a whole width away at the end.
    leaving: f32,
};

/// The id of a card, as the carousel names it.
pub fn hashId(id: []const u8) u64 {
    return std.hash.Wyhash.hash(0, id);
}

/// Put `index` back in range and see whether the card under it changed. `ids` are the hashes of
/// the cards, in order. Call it once a frame before drawing.
pub fn sync(self: *Carousel, ids: []const u64) void {
    if (ids.len == 0) {
        self.* = .{};
        return;
    }
    self.index = @min(self.index, ids.len - 1);
    if (self.slide) |s| {
        // The card that was leaving is gone, or moved: it has nothing left to slide out.
        if (s.from) |f| if (f.index >= ids.len or ids[f.index] != f.hash) {
            self.slide.?.from = null;
        };
    }
    const now = ids[self.index];
    if (self.shown != null and self.shown.? != now and self.slide == null) {
        // Not by a button: the card shown was answered, and the next comes in from the right.
        self.slide = .{ .dir = .next };
    }
    self.shown = now;
}

/// Show the next or previous card, wrapping, and start the slide to it. Returns whether anything
/// changed: false with fewer than two cards.
pub fn go(self: *Carousel, ids: []const u64, dir: Dir) bool {
    if (ids.len < 2) return false;
    const from = @min(self.index, ids.len - 1);
    self.index = switch (dir) {
        .next => if (from + 1 == ids.len) 0 else from + 1,
        .prev => if (from == 0) ids.len - 1 else from - 1,
    };
    self.shown = ids[self.index];
    self.slide = .{ .dir = dir, .from = .{ .index = from, .hash = ids[from] } };
    return true;
}

/// Move a slide on to frame time `now_ns`; `duration_ms` is its length at the person's motion
/// level (0 with motion off, which ends it at once). Returns how far it is, 0 to 1, or null when
/// none runs, and drops a finished one.
pub fn progress(self: *Carousel, now_ns: i128, duration_ms: f32) ?f32 {
    const s = &(self.slide orelse return null);
    s.clock.step(now_ns);
    const t = s.clock.fraction(duration_ms);
    if (t >= 1) self.slide = null;
    return t;
}

/// Where the two cards are when a slide is `eased` of the way (the motion curve over `progress`,
/// which may pass 1 at playful). Entering from the side the direction came from.
pub fn offsets(dir: Dir, eased: f32) Offsets {
    const sign: f32 = if (dir == .next) 1 else -1;
    return .{ .entering = sign * (1 - eased), .leaving = -sign * eased };
}

const testing = std.testing;

/// Frames of 16 ms until the slide is done (`FrameClock` holds a longer frame to 34 ms).
fn runOut(c: *Carousel, duration_ms: f32) void {
    var now: i128 = 5_000_000_000;
    for (0..100) |_| {
        now += 16 * std.time.ns_per_ms;
        _ = c.progress(now, duration_ms);
    }
}

fn ids3() [3]u64 {
    return .{ hashId("a"), hashId("b"), hashId("c") };
}

test "next and previous step one card and wrap at the ends" {
    const ids = ids3();
    var c: Carousel = .{};
    c.sync(&ids);
    try testing.expectEqual(@as(usize, 0), c.index);
    try testing.expect(c.go(&ids, .next));
    try testing.expectEqual(@as(usize, 1), c.index);
    try testing.expect(c.go(&ids, .next));
    try testing.expect(c.go(&ids, .next));
    try testing.expectEqual(@as(usize, 0), c.index);
    try testing.expect(c.go(&ids, .prev));
    try testing.expectEqual(@as(usize, 2), c.index);
}

test "a lone card has nowhere to go and no slide" {
    const ids = [_]u64{hashId("only")};
    var c: Carousel = .{};
    c.sync(&ids);
    try testing.expect(!c.go(&ids, .next));
    try testing.expect(!c.go(&ids, .prev));
    try testing.expectEqual(@as(usize, 0), c.index);
    try testing.expect(c.slide == null);
}

test "an answered card leaves the list: the next one slides in and the index stays in range" {
    const ids = ids3();
    var c: Carousel = .{};
    c.sync(&ids);
    _ = c.go(&ids, .next);
    runOut(&c, 100);
    try testing.expect(c.slide == null);
    // "b" is answered: "c" is under the index, and comes in.
    const rest = [_]u64{ ids[0], ids[2] };
    c.sync(&rest);
    try testing.expectEqual(@as(usize, 1), c.index);
    try testing.expect(c.slide != null and c.slide.?.from == null);
    // The last card answered while shown: the index falls back to the new last.
    runOut(&c, 100);
    c.sync(ids[0..1]);
    try testing.expectEqual(@as(usize, 0), c.index);
    c.sync(&.{});
    try testing.expectEqual(@as(usize, 0), c.index);
    try testing.expect(c.shown == null);
}

test "a leaving card that was answered mid-slide is dropped from the slide" {
    const ids = ids3();
    var c: Carousel = .{};
    c.sync(&ids);
    _ = c.go(&ids, .next);
    try testing.expect(c.slide.?.from != null);
    const rest = [_]u64{ ids[1], ids[2] };
    c.sync(&rest);
    try testing.expect(c.slide.?.from == null);
}

test "a slide runs its length and then ends; with motion off it ends at once" {
    const ids = ids3();
    var c: Carousel = .{};
    c.sync(&ids);
    _ = c.go(&ids, .next);
    const ms = std.time.ns_per_ms;
    try testing.expectEqual(@as(f32, 0), c.progress(1000 * ms, 200).?);
    // Frames of 30 ms: 100 ms in, a slide of 200 ms is half done; a few frames on, it is over
    // and gone.
    _ = c.progress(1030 * ms, 200);
    _ = c.progress(1060 * ms, 200);
    const half = c.progress(1090 * ms, 200).?;
    try testing.expect(half > 0.4 and half < 0.6);
    runOut(&c, 200);
    try testing.expect(c.slide == null);
    try testing.expect(c.progress(9000 * ms, 200) == null);

    _ = c.go(&ids, .prev);
    _ = c.progress(2000 * ms, 0);
    try testing.expect(c.slide == null);
}

test "cards enter from the side they are going toward" {
    const next = offsets(.next, 0);
    try testing.expectEqual(@as(f32, 1), next.entering);
    try testing.expectEqual(@as(f32, 0), next.leaving);
    const prev = offsets(.prev, 1);
    try testing.expectEqual(@as(f32, 0), prev.entering);
    try testing.expectEqual(@as(f32, 1), prev.leaving);
}
