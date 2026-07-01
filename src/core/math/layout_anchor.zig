//! Nine-way anchor placement for padded layout (paste smaller bitmap in larger rectangle)
//! and symmetrical cropping (viewport origin when cutting a smaller viewport from larger bitmap).
//!
//! Pure scalar logic, std-only — pulled in by `tests/root.zig`.

const std = @import("std");

pub const LayoutAnchor = enum(u8) {
    nw,
    n,
    ne,
    w,
    c,
    e,
    sw,
    s,
    se,
};

pub const UOffset = struct { dx: u32, dy: u32 };

/// Top-left coordinate for placing inner_w×inner_h content inside outer_w×outer_h (padding).
/// Requires inner_* <= outer_*.
pub fn padDestOrigin(inner_w: u32, inner_h: u32, outer_w: u32, outer_h: u32, anchor: LayoutAnchor) UOffset {
    std.debug.assert(inner_w <= outer_w and inner_h <= outer_h);

    const ix = outer_w - inner_w;
    const iy = outer_h - inner_h;

    return switch (anchor) {
        .nw => .{ .dx = 0, .dy = 0 },
        .n => .{ .dx = ix / 2, .dy = 0 },
        .ne => .{ .dx = ix, .dy = 0 },
        .w => .{ .dx = 0, .dy = iy / 2 },
        .c => .{ .dx = ix / 2, .dy = iy / 2 },
        .e => .{ .dx = ix, .dy = iy / 2 },
        .sw => .{ .dx = 0, .dy = iy },
        .s => .{ .dx = ix / 2, .dy = iy },
        .se => .{ .dx = ix, .dy = iy },
    };
}

/// Top-left `(sx,sy)` inside a larger `src_*` rectangle for taking a viewport of size `crop_*`.
/// Requires crop_* <= src_*.
pub fn cropSourceOrigin(src_w: u32, src_h: u32, crop_w: u32, crop_h: u32, anchor: LayoutAnchor) UOffset {
    std.debug.assert(crop_w <= src_w and crop_h <= src_h);

    const ix = src_w - crop_w;
    const iy = src_h - crop_h;

    return switch (anchor) {
        .nw => .{ .dx = 0, .dy = 0 },
        .n => .{ .dx = ix / 2, .dy = 0 },
        .ne => .{ .dx = ix, .dy = 0 },
        .w => .{ .dx = 0, .dy = iy / 2 },
        .c => .{ .dx = ix / 2, .dy = iy / 2 },
        .e => .{ .dx = ix, .dy = iy / 2 },
        .sw => .{ .dx = 0, .dy = iy },
        .s => .{ .dx = ix / 2, .dy = iy },
        .se => .{ .dx = ix, .dy = iy },
    };
}

/// Per-grid-cell paste of an old `ow×oh` tile into a new `nw×nh` cell with the same nine-way anchor
/// semantics as full-canvas growth (pad) or shrink (crop), including mixed axis (crop one, pad the other).
/// All coordinates are pixel offsets within the respective cell's top-left.
pub const CellAnchoredBlit = struct {
    /// Sample region origin and size inside the **old** cell `[0..ow)×[0..oh)`.
    sx: u32,
    sy: u32,
    sw: u32,
    sh: u32,
    /// Where those `sw×sh` pixels are written inside the **new** cell `[0..nw)×[0..nh)` (1:1, no scaling).
    dx: u32,
    dy: u32,
};

pub fn cellAnchoredBlit(ow: u32, oh: u32, nw: u32, nh: u32, anchor: LayoutAnchor) CellAnchoredBlit {
    if (nw >= ow and nh >= oh) {
        const off = padDestOrigin(ow, oh, nw, nh, anchor);
        return .{
            .sx = 0,
            .sy = 0,
            .sw = ow,
            .sh = oh,
            .dx = off.dx,
            .dy = off.dy,
        };
    }
    if (nw <= ow and nh <= oh) {
        const cr = cropSourceOrigin(ow, oh, nw, nh, anchor);
        return .{
            .sx = cr.dx,
            .sy = cr.dy,
            .sw = nw,
            .sh = nh,
            .dx = 0,
            .dy = 0,
        };
    }
    if (nw >= ow and nh < oh) {
        const cr = cropSourceOrigin(ow, oh, ow, nh, anchor);
        const p = padDestOrigin(ow, nh, nw, nh, anchor);
        return .{
            .sx = 0,
            .sy = cr.dy,
            .sw = ow,
            .sh = nh,
            .dx = p.dx,
            .dy = 0,
        };
    }
    // nw < ow and nh >= oh
    std.debug.assert(nw < ow and nh >= oh);
    const cr = cropSourceOrigin(ow, oh, nw, oh, anchor);
    const p = padDestOrigin(nw, oh, nw, nh, anchor);
    return .{
        .sx = cr.dx,
        .sy = 0,
        .sw = nw,
        .sh = oh,
        .dx = 0,
        .dy = p.dy,
    };
}

test "pad centers for asymmetric slack" {
    try std.testing.expectEqual(@as(u32, 5), padDestOrigin(12, 10, 22, 10, .n).dx);
    try std.testing.expectEqual(@as(u32, 4), padDestOrigin(6, 6, 22, 14, .c).dy);
}

test "cropSourceOrigin viewport bottom-right anchor" {
    const o = cropSourceOrigin(16, 16, 8, 8, .se);
    try std.testing.expectEqual(@as(u32, 8), o.dx);
    try std.testing.expectEqual(@as(u32, 8), o.dy);
}

test "growth paste anchors se in larger canvas" {
    const p = padDestOrigin(8, 8, 32, 16, .se);
    try std.testing.expectEqual(@as(u32, 24), p.dx);
    try std.testing.expectEqual(@as(u32, 8), p.dy);
}

test "cellAnchoredBlit grow centered" {
    const b = cellAnchoredBlit(32, 32, 64, 64, .c);
    try std.testing.expectEqual(@as(u32, 0), b.sx);
    try std.testing.expectEqual(@as(u32, 0), b.sy);
    try std.testing.expectEqual(@as(u32, 32), b.sw);
    try std.testing.expectEqual(@as(u32, 32), b.sh);
    try std.testing.expectEqual(@as(u32, 16), b.dx);
    try std.testing.expectEqual(@as(u32, 16), b.dy);
}

test "cellAnchoredBlit grow w-anchor" {
    const b = cellAnchoredBlit(32, 32, 64, 64, .w);
    try std.testing.expectEqual(@as(u32, 0), b.dx);
    try std.testing.expectEqual(@as(u32, 16), b.dy);
}

test "cellAnchoredBlit shrink w-anchor crops left side" {
    const b = cellAnchoredBlit(64, 64, 32, 32, .w);
    try std.testing.expectEqual(@as(u32, 0), b.sx);
    try std.testing.expectEqual(@as(u32, 16), b.sy);
    try std.testing.expectEqual(@as(u32, 32), b.sw);
    try std.testing.expectEqual(@as(u32, 32), b.sh);
    try std.testing.expectEqual(@as(u32, 0), b.dx);
    try std.testing.expectEqual(@as(u32, 0), b.dy);
}

test "cellAnchoredBlit mixed grow-x shrink-y" {
    const b = cellAnchoredBlit(32, 64, 64, 32, .c);
    try std.testing.expectEqual(@as(u32, 0), b.sx);
    try std.testing.expectEqual(@as(u32, 16), b.sy);
    try std.testing.expectEqual(@as(u32, 32), b.sw);
    try std.testing.expectEqual(@as(u32, 32), b.sh);
    try std.testing.expectEqual(@as(u32, 16), b.dx);
    try std.testing.expectEqual(@as(u32, 0), b.dy);
}
