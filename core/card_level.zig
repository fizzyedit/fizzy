//! Pure size-based card detail selection and visibility during a shell's size change.
const std = @import("std");
const placement = @import("placement.zig");

/// Points, as the container gives them.
pub const Size = placement.Size;

/// Extra room required to enter a level; leaving takes falling below its minimum size.
pub const band: f32 = 24;
/// A card has at most this many levels.
pub const max_levels = 4;
/// Below this shell-size change in points, `progress` returns its fallback.
pub const min_travel: f32 = 8;
/// Elements only in the destination level start appearing after this fraction of the change.
pub const enter_after: f32 = 0.6;
/// Elements only in the source level are gone by this fraction of the change.
pub const leave_by: f32 = 0.3;

/// The level for `avail`, with hysteresis when `prev` is given (clamped to the last level).
/// Asserts one to `max_levels` minima, starting at {0, 0}, ascending on both axes.
pub fn pick(levels: []const Size, avail: Size, prev: ?u8) u8 {
    std.debug.assert(levels.len >= 1 and levels.len <= max_levels);
    std.debug.assert(levels[0].w == 0 and levels[0].h == 0);
    for (levels[1..], levels[0 .. levels.len - 1]) |level, before| {
        std.debug.assert(level.w >= before.w and level.h >= before.h);
    }

    const p: usize = @min(prev orelse 0, levels.len - 1);
    const descending = avail.w < levels[p].w or avail.h < levels[p].h;
    var result: u8 = if (prev == null or descending) 0 else @intCast(p);
    for (levels, 0..) |level, i| {
        if (prev != null and !descending and i <= p) continue;
        if (descending and i >= p) break;
        const w_band: f32 = if (prev != null and !descending and level.w > 0) band else 0;
        const h_band: f32 = if (prev != null and !descending and level.h > 0) band else 0;
        if (avail.w >= level.w + w_band and avail.h >= level.h + h_band) result = @intCast(i);
    }
    return result;
}

/// Where an element is relative to a level change.
pub const Membership = enum { shared, entering, leaving };

/// Visibility from 0 to 1 at `t` of a level change. Clamps `t` to 0..1.
pub fn alpha(m: Membership, t: f32) f32 {
    const clamped = std.math.clamp(t, 0, 1);
    return switch (m) {
        .shared => 1,
        .entering => smooth01((clamped - enter_after) / (1 - enter_after)),
        .leaving => 1 - smooth01(clamped / leave_by),
    };
}

/// Weight of the destination text copy, fading over 0.3..0.7; the source weighs `1 - crossFade(t)`.
pub fn crossFade(t: f32) f32 {
    // Text sizes cross-fade over the middle 40% of the level change.
    return smooth01((t - 0.3) / 0.4);
}

/// Shell progress on the axis with the larger absolute change, clamped to 0..1.
/// Below `min_travel`, returns `fallback` clamped to 0..1.
pub fn progress(from: Size, to: Size, shown: Size, fallback: f32) f32 {
    const dw = to.w - from.w;
    const dh = to.h - from.h;
    if (@max(@abs(dw), @abs(dh)) < min_travel) return std.math.clamp(fallback, 0, 1);
    const fraction = if (@abs(dw) >= @abs(dh)) (shown.w - from.w) / dw else (shown.h - from.h) / dh;
    return std.math.clamp(fraction, 0, 1);
}

fn smooth01(x: f32) f32 {
    const clamped = std.math.clamp(x, 0, 1);
    return clamped * clamped * (3 - 2 * clamped);
}

const machine_levels = [_]Size{ .{ .w = 0, .h = 0 }, .{ .w = 200, .h = 150 }, .{ .w = 320, .h = 460 } };

test "card_level: the first pick is the largest level that fits, with no band" {
    try std.testing.expectEqual(@as(u8, 1), pick(&machine_levels, .{ .w = 210, .h = 160 }, null));
    try std.testing.expectEqual(@as(u8, 0), pick(&machine_levels, .{ .w = 100, .h = 100 }, null));
    try std.testing.expectEqual(@as(u8, 2), pick(&machine_levels, .{ .w = 358, .h = 800 }, null));
}

test "card_level: going up waits for the band" {
    try std.testing.expectEqual(@as(u8, 1), pick(&machine_levels, .{ .w = 320, .h = 460 }, 1));
    try std.testing.expectEqual(@as(u8, 1), pick(&machine_levels, .{ .w = 343, .h = 484 }, 1));
    try std.testing.expectEqual(@as(u8, 2), pick(&machine_levels, .{ .w = 344, .h = 484 }, 1));
    try std.testing.expectEqual(@as(u8, 2), pick(&machine_levels, .{ .w = 344, .h = 484 }, 0));
    try std.testing.expectEqual(@as(u8, 1), pick(&machine_levels, .{ .w = 344, .h = 483 }, 1));
}

test "card_level: going down happens below the min on either axis" {
    try std.testing.expectEqual(@as(u8, 2), pick(&machine_levels, .{ .w = 320, .h = 460 }, 2));
    try std.testing.expectEqual(@as(u8, 1), pick(&machine_levels, .{ .w = 319, .h = 800 }, 2));
    try std.testing.expectEqual(@as(u8, 1), pick(&machine_levels, .{ .w = 400, .h = 459 }, 2));
    try std.testing.expectEqual(@as(u8, 0), pick(&machine_levels, .{ .w = 150, .h = 100 }, 2));
}

test "card_level: a size that wobbles across a threshold changes the level once per real crossing" {
    var prev: u8 = 1;
    var changes: usize = 0;
    const widths = [_]f32{ 199, 201, 199, 224, 223, 225, 199, 201 };
    const expected = [_]u8{ 0, 0, 0, 1, 1, 1, 0, 0 };
    for (widths, expected) |w, want| {
        const next = pick(&machine_levels, .{ .w = w, .h = 200 }, prev);
        try std.testing.expectEqual(want, next);
        if (next != prev) changes += 1;
        prev = next;
    }
    try std.testing.expectEqual(@as(usize, 3), changes);
}

test "card_level: an axis with a zero min takes no band" {
    const levels = [_]Size{ .{ .w = 0, .h = 0 }, .{ .w = 200, .h = 0 } };
    try std.testing.expectEqual(@as(u8, 1), pick(&levels, .{ .w = 224, .h = 0 }, 0));
    try std.testing.expectEqual(@as(u8, 0), pick(&levels, .{ .w = 223, .h = 0 }, 0));
}

test "card_level: prev past the last level is clamped" {
    try std.testing.expectEqual(@as(u8, 1), pick(machine_levels[0..2], .{ .w = 500, .h = 500 }, 3));
}

test "card_level: an entering element waits for 0.6 and ends at 1" {
    try std.testing.expectEqual(@as(f32, 0), alpha(.entering, 0.6));
    try std.testing.expectEqual(@as(f32, 1), alpha(.entering, 1));
    var prev: f32 = 0;
    for (0..21) |i| {
        const value = alpha(.entering, @as(f32, @floatFromInt(i)) / 20);
        try std.testing.expect(value >= prev);
        prev = value;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), alpha(.entering, 0.8), 1e-6);
    try std.testing.expectEqual(@as(f32, 0), alpha(.entering, -1));
    try std.testing.expectEqual(@as(f32, 1), alpha(.entering, 2));
}

test "card_level: a leaving element is gone by 0.3" {
    try std.testing.expectEqual(@as(f32, 1), alpha(.leaving, 0));
    try std.testing.expectEqual(@as(f32, 0), alpha(.leaving, 0.3));
    try std.testing.expectEqual(@as(f32, 0), alpha(.leaving, 1));
    for (0..21) |i| {
        try std.testing.expectEqual(@as(f32, 1), alpha(.shared, @as(f32, @floatFromInt(i)) / 20));
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), alpha(.leaving, 0.15), 1e-6);
    try std.testing.expectEqual(@as(f32, 1), alpha(.leaving, -1));
    try std.testing.expectEqual(@as(f32, 0), alpha(.leaving, 2));
}

test "card_level: the cross-fade's two copies always sum to 1" {
    for (0..21) |i| {
        const t = @as(f32, @floatFromInt(i)) / 20;
        const weight = crossFade(t);
        try std.testing.expectApproxEqAbs(@as(f32, 1), weight + (1 - weight), 1e-6);
        if (t <= 0.3) try std.testing.expectEqual(@as(f32, 0), weight);
        if (t >= 0.7) try std.testing.expectApproxEqAbs(@as(f32, 1), weight, 1e-6);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), crossFade(0.5), 1e-6);
    try std.testing.expectEqual(@as(f32, 0), crossFade(-1));
    try std.testing.expectEqual(@as(f32, 1), crossFade(2));
}

test "card_level: progress, growing and shrinking" {
    const from: Size = .{ .w = 200, .h = 150 };
    const to: Size = .{ .w = 358, .h = 800 };
    const midpoint: Size = .{ .w = 279, .h = 475 };
    try std.testing.expectEqual(@as(f32, 0.5), progress(from, to, midpoint, 0));
    try std.testing.expectEqual(@as(f32, 0.5), progress(to, from, midpoint, 0));
    const past: Size = .{ .w = 400, .h = 900 };
    const before: Size = .{ .w = 100, .h = 100 };
    try std.testing.expectEqual(@as(f32, 1), progress(from, to, past, 0));
    try std.testing.expectEqual(@as(f32, 0), progress(from, to, before, 0));
    try std.testing.expectEqual(@as(f32, 0), progress(to, from, past, 0));
    try std.testing.expectEqual(@as(f32, 1), progress(to, from, before, 0));
    try std.testing.expectEqual(@as(f32, 0.5), progress(.{ .w = 0, .h = 0 }, .{ .w = 8, .h = 0 }, .{ .w = 4, .h = 0 }, 0));
}

test "card_level: progress falls back when the size barely changes" {
    const from: Size = .{ .w = 300, .h = 300 };
    const to: Size = .{ .w = 305, .h = 302 };
    try std.testing.expectEqual(@as(f32, 0.4), progress(from, to, .{ .w = 900, .h = 900 }, 0.4));
    try std.testing.expectEqual(@as(f32, 0), progress(from, to, from, -1));
    try std.testing.expectEqual(@as(f32, 1), progress(from, from, from, 2));
}
