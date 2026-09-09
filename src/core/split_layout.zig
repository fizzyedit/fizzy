//! Pure layout math for a **linear splitter**: a box whose children are separated by draggable
//! handles, written as
//!
//! ```zig
//! var box = SplitBox.begin(@src(), .{ .dir = .horizontal });
//! defer box.end();
//!     ...child 0...
//! box.split();          // a draggable handle here
//!     ...child 1...
//! box.split();
//!     ...child 2...
//! ```
//!
//! rather than as a tree of two-child panes. The linear form reads top to bottom, needs no
//! `showFirst` / `showSecond` / `rest()` branching in the caller, and generalises to N children
//! — which is what fizzy's multi-pane bottom panel actually wants, and what nesting
//! `PanedWidget` was standing in for.
//!
//! No dvui here on purpose. Boundary maths is where the fiddly off-by-ones live (handles eat
//! space; a drag must not push a neighbour below its minimum; children can appear and disappear
//! between frames), and it is all testable directly. `SplitBox` is the thin dvui shell over it.
const std = @import("std");

/// Boundaries between children, as fractions of the box's length along the split axis.
/// `count` children means `count - 1` boundaries, ascending, each in (0, 1).
pub const Boundaries = struct {
    values: []f32,

    pub fn count(self: Boundaries) usize {
        return self.values.len + 1;
    }

    /// Reset to equal shares. Used when the child count changes, since old boundaries no longer
    /// describe the same layout.
    pub fn distributeEvenly(self: Boundaries) void {
        const n: f32 = @floatFromInt(self.values.len + 1);
        for (self.values, 0..) |*v, i| {
            v.* = @as(f32, @floatFromInt(i + 1)) / n;
        }
    }

    /// The span of child `index` as (start, end) fractions.
    pub fn span(self: Boundaries, index: usize) struct { start: f32, end: f32 } {
        const start: f32 = if (index == 0) 0.0 else self.values[index - 1];
        const end: f32 = if (index >= self.values.len) 1.0 else self.values[index];
        return .{ .start = start, .end = end };
    }

    /// Move boundary `index` to `to`, clamped so neither neighbouring child goes below
    /// `min_fraction`. Returns the value actually applied.
    pub fn moveBoundary(self: Boundaries, index: usize, to: f32, min_fraction: f32) f32 {
        if (index >= self.values.len) return 0;
        const lower = if (index == 0) 0.0 else self.values[index - 1];
        const upper = if (index + 1 >= self.values.len) 1.0 else self.values[index + 1];
        // Check before clamping, not after: `std.math.clamp` itself asserts `lower <= upper`,
        // so an inverted range panics inside the clamp rather than reaching a guard below it.
        // A box too small to honour both minimums leaves the boundary where it is.
        if (lower + min_fraction > upper - min_fraction) return self.values[index];
        const clamped = std.math.clamp(to, lower + min_fraction, upper - min_fraction);
        self.values[index] = clamped;
        return clamped;
    }
};

/// Split child `index` in two, giving the new child the second half of that child's span.
///
/// This is what dragging a tab into a pane does — and why boundaries are stored rather than
/// recomputed: redistributing evenly on every count change would silently reset every size the
/// user had dragged, everywhere else in the layout, each time a split appeared. `values` must
/// have room for one more (the caller grows it and passes the larger slice).
pub fn insertSplit(values: []f32, count_before: usize, index: usize, at: f32) void {
    std.debug.assert(values.len >= count_before);
    const old: Boundaries = .{ .values = values[0 .. count_before - 1] };
    const s = old.span(index);
    const new_boundary = s.start + (s.end - s.start) * at;

    // Shift the tail up one and drop the new boundary in place, so every other child keeps the
    // span it had.
    var i: usize = count_before - 1;
    while (i > index) : (i -= 1) values[i] = values[i - 1];
    values[index] = new_boundary;
}

/// Remove child `index`, giving its space to the neighbour it was split from.
pub fn removeSplit(values: []f32, count_before: usize, index: usize) void {
    if (count_before <= 1) return;
    const boundary_to_drop = if (index == 0) 0 else index - 1;
    var i: usize = boundary_to_drop;
    while (i + 1 < count_before - 1) : (i += 1) values[i] = values[i + 1];
}

/// Pixel geometry for one child, given the box length and the space handles consume.
pub fn childExtent(
    boundaries: Boundaries,
    index: usize,
    length: f32,
    handle_size: f32,
) struct { offset: f32, size: f32 } {
    const n = boundaries.count();
    // Handles sit *between* children, so they take (n-1) * handle_size out of the length before
    // the fractions are applied. Forgetting this is what makes the last child overflow by
    // exactly the total handle width.
    const handles_total = handle_size * @as(f32, @floatFromInt(if (n > 0) n - 1 else 0));
    const usable = @max(0.0, length - handles_total);
    const s = boundaries.span(index);
    const offset = s.start * usable + handle_size * @as(f32, @floatFromInt(index));
    return .{ .offset = offset, .size = (s.end - s.start) * usable };
}

const testing = std.testing;

test "even distribution splits the box into equal shares" {
    var vals = [_]f32{ 0, 0, 0 };
    const b: Boundaries = .{ .values = &vals };
    b.distributeEvenly();
    try testing.expectEqual(@as(usize, 4), b.count());
    try testing.expectApproxEqAbs(@as(f32, 0.25), vals[0], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.50), vals[1], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.75), vals[2], 0.0001);
}

test "spans cover the whole box with no gaps or overlap" {
    var vals = [_]f32{ 0.2, 0.7 };
    const b: Boundaries = .{ .values = &vals };
    try testing.expectApproxEqAbs(@as(f32, 0.0), b.span(0).start, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.2), b.span(0).end, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.2), b.span(1).start, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.7), b.span(1).end, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.7), b.span(2).start, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), b.span(2).end, 0.0001);
}

test "a drag cannot push a neighbour below its minimum" {
    var vals = [_]f32{ 0.5 };
    const b: Boundaries = .{ .values = &vals };
    _ = b.moveBoundary(0, 0.99, 0.1);
    try testing.expectApproxEqAbs(@as(f32, 0.9), vals[0], 0.0001);
    _ = b.moveBoundary(0, 0.01, 0.1);
    try testing.expectApproxEqAbs(@as(f32, 0.1), vals[0], 0.0001);
}

test "a drag cannot cross its neighbouring boundaries" {
    var vals = [_]f32{ 0.3, 0.6 };
    const b: Boundaries = .{ .values = &vals };
    _ = b.moveBoundary(0, 0.95, 0.05); // would pass boundary 1 at 0.6
    try testing.expectApproxEqAbs(@as(f32, 0.55), vals[0], 0.0001);
}

test "handles are taken out of the length before fractions apply" {
    var vals = [_]f32{0.5};
    const b: Boundaries = .{ .values = &vals };
    // 100px, one 10px handle -> 90px usable, 45px each, second child starts at 45+10.
    const a = childExtent(b, 0, 100, 10);
    const c = childExtent(b, 1, 100, 10);
    try testing.expectApproxEqAbs(@as(f32, 0.0), a.offset, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 45.0), a.size, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 55.0), c.offset, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 45.0), c.size, 0.0001);
    // Children plus handles exactly fill the box — the overflow bug this guards against.
    try testing.expectApproxEqAbs(@as(f32, 100.0), c.offset + c.size, 0.0001);
}

test "inserting a split preserves every other child's span" {
    // Three children at 0.2 / 0.7, then child 1 is split in half.
    var vals = [_]f32{ 0.2, 0.7, 0 };
    insertSplit(&vals, 3, 1, 0.5);
    const b: Boundaries = .{ .values = &vals };
    try testing.expectEqual(@as(usize, 4), b.count());
    // child 0 untouched
    try testing.expectApproxEqAbs(@as(f32, 0.0), b.span(0).start, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.2), b.span(0).end, 0.0001);
    // child 1 halved, new child takes the other half
    try testing.expectApproxEqAbs(@as(f32, 0.2), b.span(1).start, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.45), b.span(1).end, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.45), b.span(2).start, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.7), b.span(2).end, 0.0001);
    // the last child, which the user may have sized, is untouched
    try testing.expectApproxEqAbs(@as(f32, 0.7), b.span(3).start, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), b.span(3).end, 0.0001);
}

test "removing a child gives its space to its neighbour" {
    var vals = [_]f32{ 0.2, 0.45, 0.7 };
    removeSplit(&vals, 4, 1);
    const b: Boundaries = .{ .values = vals[0..2] };
    try testing.expectEqual(@as(usize, 3), b.count());
    try testing.expectApproxEqAbs(@as(f32, 0.0), b.span(0).start, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.45), b.span(0).end, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.7), b.span(1).end, 0.0001);
}

test "a box too small for both minimums leaves the boundary alone" {
    var vals = [_]f32{0.5};
    const b: Boundaries = .{ .values = &vals };
    _ = b.moveBoundary(0, 0.2, 0.6); // 0.6 + 0.6 > 1.0
    try testing.expectApproxEqAbs(@as(f32, 0.5), vals[0], 0.0001);
}
