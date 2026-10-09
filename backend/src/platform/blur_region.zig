//! The blur behind a window as a desktop takes it: a region of whole rectangles (Wayland's
//! `wl_region`), here a window's frame with its corners rounded, stepped into rows along each
//! corner's arc. The protocols take no radius, so the rows are the corners; under a blur a step
//! of one surface unit does not show. std-only, so it is tested on any host
//! (`fizzy-blur-region-tests`); `wayland_blur` hands it to the compositor.
const std = @import("std");

/// Surface units (points), whole as the protocols take them.
pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
};

/// The roundest corner stepped: a row per unit of it.
pub const max_radius = 64;

/// The most rectangles `rounded` makes: a row per unit of the radius above the middle and below
/// it, and the middle.
pub const max_rects = 2 * max_radius + 1;

/// `frame` with its corners rounded by `radius` (surface units), as rectangles in `out`: the
/// middle whole, and above and below it a row per unit of the radius, each in from the frame's
/// sides by as far as the corner's arc is at the row's middle. Rows the arc leaves the same width
/// are one rectangle. Nothing for an empty frame.
pub fn rounded(frame: Rect, radius: f32, out: *[max_rects]Rect) []Rect {
    if (frame.w <= 0 or frame.h <= 0) return out[0..0];
    const half: f32 = @floatFromInt(@divTrunc(@min(frame.w, frame.h), 2));
    const r_units: i32 = @intFromFloat(@round(std.math.clamp(radius, 0, @min(half, @as(f32, max_radius)))));
    if (r_units <= 0) {
        out[0] = frame;
        return out[0..1];
    }
    const r: f32 = @floatFromInt(r_units);
    var n: usize = 0;
    // From the top: the top corners' rows, then the middle, then the bottom corners' rows. Row
    // `i` of a corner lies `i` units in from the frame's edge.
    var y = frame.y;
    var i: i32 = 0;
    while (i < r_units) : (i += 1) {
        n = addRow(out, n, frame, y, 1, inset(r, i));
        y += 1;
    }
    const middle_h = frame.h - 2 * r_units;
    if (middle_h > 0) {
        n = addRow(out, n, frame, y, middle_h, 0);
        y += middle_h;
    }
    i = r_units - 1;
    while (i >= 0) : (i -= 1) {
        n = addRow(out, n, frame, y, 1, inset(r, i));
        y += 1;
    }
    return out[0..n];
}

/// How far in from the frame's side row `i` of a corner of radius `r` starts: where the arc is
/// at the row's middle, to the nearest unit.
fn inset(r: f32, i: i32) i32 {
    const dy = r - (@as(f32, @floatFromInt(i)) + 0.5);
    const dx = @sqrt(@max(r * r - dy * dy, 0));
    return @intFromFloat(@round(r - dx));
}

/// A row of `h` units at `y`, `in` from each side, onto the last rectangle when it is the same
/// width and runs on from it.
fn addRow(out: *[max_rects]Rect, n: usize, frame: Rect, y: i32, h: i32, in: i32) usize {
    const row: Rect = .{ .x = frame.x + in, .y = y, .w = frame.w - 2 * in, .h = h };
    if (row.w <= 0) return n;
    if (n > 0) {
        const last = &out[n - 1];
        if (last.x == row.x and last.w == row.w and last.y + last.h == row.y) {
            last.h += row.h;
            return n;
        }
    }
    out[n] = row;
    return n + 1;
}

test "a square frame is itself" {
    var out: [max_rects]Rect = undefined;
    const rs = rounded(.{ .x = 3, .y = 4, .w = 100, .h = 80 }, 0, &out);
    try std.testing.expectEqual(@as(usize, 1), rs.len);
    try std.testing.expectEqual(Rect{ .x = 3, .y = 4, .w = 100, .h = 80 }, rs[0]);
}

test "an empty frame is nothing" {
    var out: [max_rects]Rect = undefined;
    try std.testing.expectEqual(@as(usize, 0), rounded(.{ .w = 0, .h = 10 }, 12, &out).len);
}

test "rounded rows cover the frame's height, in from its sides at the corners, symmetric" {
    var out: [max_rects]Rect = undefined;
    const frame: Rect = .{ .x = 10, .y = 20, .w = 300, .h = 200 };
    const rs = rounded(frame, 12, &out);
    try std.testing.expect(rs.len > 3);
    // Top to bottom without gaps or overlaps.
    var y = frame.y;
    for (rs) |r| {
        try std.testing.expectEqual(y, r.y);
        try std.testing.expect(r.x >= frame.x and r.x + r.w <= frame.x + frame.w);
        // Centred: in by as much on the right as on the left.
        try std.testing.expectEqual(frame.x + frame.w - (r.x + r.w), r.x - frame.x);
        y += r.h;
    }
    try std.testing.expectEqual(frame.y + frame.h, y);
    // The first row is well in at the corner; the middle is the whole width.
    try std.testing.expect(rs[0].x - frame.x >= 6);
    var widest: i32 = 0;
    for (rs) |r| widest = @max(widest, r.w);
    try std.testing.expectEqual(frame.w, widest);
    // Mirrored top and bottom.
    for (0..rs.len) |k| {
        const a = rs[k];
        const b = rs[rs.len - 1 - k];
        try std.testing.expectEqual(a.x, b.x);
        try std.testing.expectEqual(a.h, b.h);
    }
}

test "the area is the rounded rect's, near enough" {
    var out: [max_rects]Rect = undefined;
    const r: f32 = 12;
    const rs = rounded(.{ .w = 300, .h = 200 }, r, &out);
    var area: f32 = 0;
    for (rs) |x| area += @floatFromInt(x.w * x.h);
    const want = 300 * 200 - (4 - std.math.pi) * r * r;
    // Within a unit of each corner's arc.
    try std.testing.expect(@abs(area - want) <= 4 * r);
}

test "a radius past half the shorter side is clamped" {
    var out: [max_rects]Rect = undefined;
    const rs = rounded(.{ .w = 40, .h = 20 }, 500, &out);
    var y: i32 = 0;
    for (rs) |x| {
        try std.testing.expect(x.w > 0);
        y += x.h;
    }
    try std.testing.expectEqual(@as(i32, 20), y);
}
