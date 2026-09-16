//! A same-axis row of split cells, and the pure arithmetic over one: accordion sash drags,
//! `divide` / `ratioFor`, and the child rects of one split.
//!
//! No widget state, no allocator, no tree walk. `DockingWidget` gathers a `Row`
//! from the live tree and drawn ratios, calls here, then writes ratios back.
const std = @import("std");
const dvui = @import("dvui");

/// A side scaled to this keeps its proportions to open back out with; exactly
/// zero would forget them. Matches the feel settled in `DockingWidget`.
const squeezed_min: f32 = 0.01;

/// How `extent` divides at `ratio`: `first` is the first child's length; `usable`
/// the room the ratio is a share of (the extent less the sash and both floors).
pub const Division = struct { first: f32, usable: f32, floor_first: f32, floor_second: f32 };

/// A row of cells along one axis, with a sash of thickness `gap` between each
/// pair. `boundaries[k]` is the start of sash `k` (so there is one more floor
/// than there are boundaries).
const Row = @This();

boundaries: []f32,
floors: []f32,
gap: f32,
extent: f32,

/// Drag boundary `k` to `to`: each side accordions in proportion, never below
/// its floors; sashes keep `gap`.
pub fn dragBoundary(row: *Row, k: usize, to: f32) void {
    const n = row.floors.len;
    if (n == 0 or row.boundaries.len != n - 1 or k >= row.boundaries.len) return;

    var lo: f32 = 0;
    for (row.floors[0 .. k + 1], 0..) |f, i| {
        lo += f;
        if (i < k) lo += row.gap;
    }
    var hi: f32 = row.extent - row.gap;
    for (row.floors[k + 1 ..], 0..) |f, i| {
        hi -= f;
        if (i + 1 < n - (k + 1)) hi -= row.gap;
    }
    const want = std.math.clamp(to, lo, @max(lo, hi));

    var room_buf: [64]f32 = undefined;
    if (n > room_buf.len) return;
    const room = room_buf[0..n];
    for (row.floors, 0..) |f, i| {
        const start: f32 = if (i == 0) 0 else row.boundaries[i - 1] + row.gap;
        const end: f32 = if (i == n - 1) row.extent else row.boundaries[i];
        room[i] = @max(0, end - start - f);
    }

    scaleSide(room[0 .. k + 1], want - lo, true);
    scaleSide(room[k + 1 ..], hi - want, false);

    var at: f32 = 0;
    for (row.floors, 0..) |f, i| {
        at += f + room[i];
        if (i < row.boundaries.len) {
            row.boundaries[i] = at;
            at += row.gap;
        }
    }
}

/// Ratio of a split from its boundary position, given its cell and floors
/// (inverse of `divide`).
pub fn ratioFor(first_len: f32, extent: f32, gap: f32, floor_first: f32, floor_second: f32) f32 {
    const usable = @max(0, extent - gap - floor_first - floor_second);
    if (usable > 0) return std.math.clamp((first_len - floor_first) / usable, 0, 1);
    return 0;
}

/// How `extent` divides at `ratio`.
pub fn divide(extent: f32, ratio: f32, gap: f32, floor_first: f32, floor_second: f32) Division {
    const usable = @max(0, extent - gap - floor_first - floor_second);
    return .{
        .first = floor_first + usable * std.math.clamp(ratio, 0, 1),
        .usable = usable,
        .floor_first = floor_first,
        .floor_second = floor_second,
    };
}

/// The child rects and sash rect for a split of content size `cr` whose first
/// child is `first` long and whose sash is `gap` thick.
pub fn cellRects(cr: dvui.Rect, dir: dvui.enums.Direction, first: f32, gap: f32) struct { first: dvui.Rect, second: dvui.Rect, sash: dvui.Rect } {
    return switch (dir) {
        .horizontal => .{
            .first = .{ .x = cr.x, .y = cr.y, .w = first, .h = cr.h },
            .sash = .{ .x = cr.x + first, .y = cr.y, .w = gap, .h = cr.h },
            .second = .{ .x = cr.x + first + gap, .y = cr.y, .w = @max(0, cr.w - first - gap), .h = cr.h },
        },
        .vertical => .{
            .first = .{ .x = cr.x, .y = cr.y, .w = cr.w, .h = first },
            .sash = .{ .x = cr.x, .y = cr.y + first, .w = cr.w, .h = gap },
            .second = .{ .x = cr.x, .y = cr.y + first + gap, .w = cr.w, .h = @max(0, cr.h - first - gap) },
        },
    };
}

/// Fit `room` (each cell's stretch above its floor) into `total`, keeping
/// proportions. A side that has been squeezed to nothing has no proportions to
/// keep, so the room goes to the cell nearest the boundary (`nearest_last` says
/// which end that is).
fn scaleSide(room: []f32, total: f32, nearest_last: bool) void {
    if (room.len == 0) return;
    const fit = @max(squeezed_min, total);
    var sum: f32 = 0;
    for (room) |r| sum += r;
    if (sum > 0.0001) {
        const f = fit / sum;
        for (room) |*r| r.* *= f;
    } else {
        @memset(room, 0);
        room[if (nearest_last) room.len - 1 else 0] = fit;
    }
}
