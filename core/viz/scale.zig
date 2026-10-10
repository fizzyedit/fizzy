//! The arithmetic behind `core.viz`'s graphics, with no dvui in it so it tests on its own
//! (`fizzy-viz-scale-tests`): how tall a chart's scale is, which slot the pointer is over, how
//! much of a bar a value fills.
const std = @import("std");

/// The value a chart's top edge stands for: the largest value with `headroom` above it (1.1 is a
/// tenth more), and never below `floor`, so a quiet chart does not blow small values up to full
/// height. At least a tiny positive number, so dividing by it is safe.
pub fn top(largest: f32, floor: f32, headroom: f32) f32 {
    return @max(@max(largest * headroom, floor), std.math.floatEps(f32));
}

/// Slots back from the newest (0 the newest, at the right edge) that a point `from_right`
/// pixels left of the chart's right edge is over, when each slot is `slot_w` wide and `filled`
/// slots hold values. Null past the oldest filled slot, or outside the chart.
pub fn slotFromRight(from_right: f32, slot_w: f32, filled: usize) ?usize {
    if (!(from_right >= 0) or !(slot_w > 0)) return null;
    const slot: usize = @intFromFloat(@floor(from_right / slot_w));
    return if (slot < filled) slot else null;
}

/// How much of a bar `value` fills out of `whole`, from 0 to 1. A bar of nothing for a whole of
/// nothing.
pub fn fraction(value: f64, whole: f64) f32 {
    if (!(whole > 0)) return 0;
    return @floatCast(std.math.clamp(value / whole, 0, 1));
}

/// The angle of a point `dx, dy` from a circle's centre, clockwise from straight up (screen y
/// grows down), in radians from 0 up to 2π: the direction a pie's slices are laid out in.
pub fn angleFromTop(dx: f32, dy: f32) f32 {
    const a = std.math.atan2(dx, -dy);
    return if (a < 0) a + 2 * std.math.pi else a;
}

/// The slice `angle` (as `angleFromTop` gives it) falls in, when slices of these `fractions` of
/// the whole run clockwise from the top. The fractions need not add up to one: they are taken
/// as shares of their sum. Null for no slices or nothing to share.
pub fn sliceAt(angle: f32, fractions: []const f32) ?usize {
    var sum: f32 = 0;
    for (fractions) |f| sum += @max(0, f);
    if (!(sum > 0)) return null;
    const at = angle / (2 * std.math.pi) * sum;
    var start: f32 = 0;
    for (fractions, 0..) |f, i| {
        start += @max(0, f);
        if (at < start) return i;
    }
    return fractions.len - 1;
}

/// Moves labels' `ys` (sorted top to bottom) apart until each is at least `gap` below the one
/// before, keeping them within `lo` and `hi` where there is room: down past any that crowd,
/// then back up from the bottom edge. A pie's leader labels on one side, so none overlap.
pub fn spread(ys: []f32, gap: f32, lo: f32, hi: f32) void {
    if (ys.len == 0) return;
    ys[0] = @max(ys[0], lo);
    for (ys[1..], 1..) |*y, i| y.* = @max(y.*, ys[i - 1] + gap);
    if (ys[ys.len - 1] > hi) {
        ys[ys.len - 1] = hi;
        var i = ys.len - 1;
        while (i > 0) : (i -= 1) ys[i - 1] = @min(ys[i - 1], ys[i] - gap);
    }
}

test top {
    try std.testing.expectEqual(@as(f32, 20), top(10, 20, 1.1));
    try std.testing.expectApproxEqAbs(@as(f32, 33), top(30, 20, 1.1), 1e-4);
    try std.testing.expect(top(0, 0, 1.1) > 0);
}

test slotFromRight {
    try std.testing.expectEqual(@as(?usize, 0), slotFromRight(0, 4, 10));
    try std.testing.expectEqual(@as(?usize, 0), slotFromRight(3.9, 4, 10));
    try std.testing.expectEqual(@as(?usize, 1), slotFromRight(4, 4, 10));
    try std.testing.expectEqual(@as(?usize, 9), slotFromRight(39, 4, 10));
    try std.testing.expectEqual(@as(?usize, null), slotFromRight(40, 4, 10));
    // Left of the oldest filled slot, but still inside the chart: nothing there yet.
    try std.testing.expectEqual(@as(?usize, null), slotFromRight(12, 4, 3));
    try std.testing.expectEqual(@as(?usize, null), slotFromRight(-1, 4, 10));
    try std.testing.expectEqual(@as(?usize, null), slotFromRight(1, 0, 10));
    try std.testing.expectEqual(@as(?usize, null), slotFromRight(std.math.nan(f32), 4, 10));
}

test fraction {
    try std.testing.expectEqual(@as(f32, 0.5), fraction(1, 2));
    try std.testing.expectEqual(@as(f32, 1), fraction(3, 2));
    try std.testing.expectEqual(@as(f32, 0), fraction(-1, 2));
    try std.testing.expectEqual(@as(f32, 0), fraction(1, 0));
}

test angleFromTop {
    try std.testing.expectApproxEqAbs(@as(f32, 0), angleFromTop(0, -1), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, std.math.pi / 2.0), angleFromTop(1, 0), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, std.math.pi), angleFromTop(0, 1), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 3 * std.math.pi / 2.0), angleFromTop(-1, 0), 1e-5);
}

test sliceAt {
    const fr = [_]f32{ 0.5, 0.25, 0.25 };
    try std.testing.expectEqual(@as(?usize, 0), sliceAt(0, &fr));
    try std.testing.expectEqual(@as(?usize, 1), sliceAt(std.math.pi + 0.1, &fr));
    try std.testing.expectEqual(@as(?usize, 2), sliceAt(2 * std.math.pi - 0.01, &fr));
    // Shares of their sum: the same slices given as milliseconds.
    try std.testing.expectEqual(@as(?usize, 1), sliceAt(std.math.pi + 0.1, &.{ 2, 1, 1 }));
    try std.testing.expectEqual(@as(?usize, null), sliceAt(1, &.{}));
    try std.testing.expectEqual(@as(?usize, null), sliceAt(1, &.{ 0, 0 }));
}

test spread {
    var ys = [_]f32{ 10, 11, 12, 50 };
    spread(&ys, 5, 0, 100);
    try std.testing.expectEqualSlices(f32, &.{ 10, 15, 20, 50 }, &ys);
    // Crowded at the bottom edge: pushed back up.
    var low = [_]f32{ 90, 95, 98 };
    spread(&low, 5, 0, 100);
    try std.testing.expectEqualSlices(f32, &.{ 90, 95, 100 }, &low);
    var lower = [_]f32{ 97, 98, 99 };
    spread(&lower, 5, 0, 100);
    try std.testing.expectEqualSlices(f32, &.{ 90, 95, 100 }, &lower);
}
