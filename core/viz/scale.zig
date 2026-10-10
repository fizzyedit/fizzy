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
