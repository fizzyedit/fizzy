//! Pure transparency-aware bounding-rect tightening for sprite packing.
//!
//! The atlas packer (`tools/Packer.zig`) walks each grid cell of every visible layer and asks
//! "what is the smallest sub-rect of this cell that contains all opaque pixels?" before handing
//! the bitmap to the rect packer. That avoids reserving texture space for fully-transparent
//! borders. The same call also reports the offset by which the sprite *origin* must shift so
//! that the in-game anchor point (feet, hand, muzzle, …) still lines up after the bitmap is
//! tightened.
//!
//! This module is std-only: no dvui, no fizzy globals, no allocator. `Internal.Layer.reduce` is
//! a thin wrapper around `reduce` here, and `Packer.append` consumes both `reduce` and
//! `originAfterReduce`.
//!
//! Behavior pinned by tests in this file:
//!  * Empty input — fully transparent rect, zero-area rect, or rect outside the layer — returns
//!    `null` (caller should drop the sprite or substitute a placeholder).
//!  * Non-empty input returns a rect whose four edges each touch at least one opaque pixel.
//!  * Returned rect is contained inside the requested src rect (clamped to the layer).
//!  * `originAfterReduce` is exact: `origin' = origin - (reduced_xy - src_xy)` so the world-space
//!    anchor lands on the same pixel before/after the reduce.

const std = @import("std");
const builtin = @import("builtin");

/// Integer-pixel rect. Distinct from dvui.Rect (which is f32) so this module stays std-only.
pub const Rect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

/// Treat any pixel with `pixels[i][3] != 0` as opaque. Matches the production rule used
/// throughout the editor (drawing tools clear alpha-zero pixels rather than touching alpha).
inline fn isOpaque(p: [4]u8) bool {
    return p[3] != 0;
}

/// True if any pixel in the contiguous `pixels` is opaque (alpha byte != 0).
///
/// Vectorized: each RGBA pixel bitcasts to one `u32`, so it ORs the alpha bytes of
/// `vec_len` pixels per step and bails on the first opaque chunk
pub fn anyOpaque(pixels: []const [4]u8) bool {
    var i: usize = 0;
    if (std.simd.suggestVectorLength(u32)) |vec_len| {
        const V = @Vector(vec_len, u32);
        // Alpha is byte 3 of each pixel: the high byte of the u32 on little-endian
        // targets, the low byte on big-endian.
        const alpha_mask: V = @splat(switch (builtin.cpu.arch.endian()) {
            .little => 0xFF00_0000,
            .big => 0x0000_00FF,
        });
        while (i + vec_len <= pixels.len) : (i += vec_len) {
            const chunk: V = @bitCast(pixels[i..][0..vec_len].*);
            if (@reduce(.Or, chunk & alpha_mask) != 0) return true;
        }
    }
    while (i < pixels.len) : (i += 1) if (isOpaque(pixels[i])) return true;
    return false;
}

/// Tighten `src` to the smallest sub-rect of `pixels` (laid out row-major, `layer_width` wide and
/// `layer_height` tall) that still contains every opaque pixel inside `src`. Returns `null` when:
///
///  * `src` has zero area, or its origin is outside the layer (caller passed nonsense), or
///  * every pixel covered by the (clamped) src rect is fully transparent.
///
/// The returned rect is always non-empty (`w > 0 and h > 0`), fully contained within both
/// `src` (after clamp) and the layer extents, and has at least one opaque pixel touching each of
/// its four edges.
pub fn reduce(
    pixels: []const [4]u8,
    layer_width: u32,
    layer_height: u32,
    src: Rect,
) ?Rect {
    if (src.w == 0 or src.h == 0) return null;
    if (src.x >= layer_width or src.y >= layer_height) return null;
    if (@as(usize, layer_width) * @as(usize, layer_height) != pixels.len) return null;

    const x_end = @min(src.x + src.w, layer_width);
    const y_end = @min(src.y + src.h, layer_height);

    var top: u32 = src.y;
    var bottom: u32 = y_end - 1;
    var left: u32 = src.x;
    var right: u32 = x_end - 1;

    // Find the topmost row with any opaque pixel inside the src column range.
    top: while (top <= bottom) : (top += 1) {
        const row_start: usize = @as(usize, left) + @as(usize, top) * layer_width;
        const row = pixels[row_start .. row_start + (right - left + 1)];
        if (anyOpaque(row)) break :top;
    }
    if (top > bottom) return null;

    // Find the bottommost row with any opaque pixel.
    bottom: while (bottom >= top) : (bottom -= 1) {
        const row_start: usize = @as(usize, left) + @as(usize, bottom) * layer_width;
        const row = pixels[row_start .. row_start + (right - left + 1)];
        if (anyOpaque(row)) break :bottom;
        if (bottom == 0) break;
    }

    // Tighten left edge by scanning columns within the [top..bottom] band.
    left: while (left < right) : (left += 1) {
        var y = top;
        while (y <= bottom) : (y += 1) {
            const idx = @as(usize, left) + @as(usize, y) * layer_width;
            if (isOpaque(pixels[idx])) break :left;
        }
    }

    // Tighten right edge symmetrically.
    right: while (right > left) : (right -= 1) {
        var y = top;
        while (y <= bottom) : (y += 1) {
            const idx = @as(usize, right) + @as(usize, y) * layer_width;
            if (isOpaque(pixels[idx])) break :right;
        }
    }

    return .{
        .x = left,
        .y = top,
        .w = right - left + 1,
        .h = bottom - top + 1,
    };
}

/// New sprite origin after a reduce step. The packer ships sprites with their bitmap tightened
/// to the rect returned by `reduce`, so the sprite origin (used at runtime as the pivot when the
/// sprite is placed in the world) must shift by the same `(dx, dy)` to keep the anchor on the
/// same pixel. With `cell_x`, `cell_y` the top-left of the cell the sprite was sliced from, and
/// `reduced_x`, `reduced_y` the top-left of the reduced rect, the new origin is:
///
///     origin' = origin - (reduced - cell)
///
/// Origins are stored in *cell-local* pixel coordinates (e.g. `(8, 16)` means "pivot 8 px right
/// and 16 px down inside the cell"), so subtracting the reduce offset gives the pivot's location
/// inside the *reduced* bitmap.
///
/// Invariant: `reduced_x >= cell_x` and `reduced_y >= cell_y` (caller guaranteed by `reduce`).
pub fn originAfterReduce(
    origin: [2]f32,
    cell_x: u32,
    cell_y: u32,
    reduced_x: u32,
    reduced_y: u32,
) [2]f32 {
    std.debug.assert(reduced_x >= cell_x);
    std.debug.assert(reduced_y >= cell_y);
    const dx: f32 = @floatFromInt(reduced_x - cell_x);
    const dy: f32 = @floatFromInt(reduced_y - cell_y);
    return .{ origin[0] - dx, origin[1] - dy };
}

// ----------------------------------------------------------------
// Tests
// ----------------------------------------------------------------

const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

const transparent: [4]u8 = .{ 0, 0, 0, 0 };
const opaque_red: [4]u8 = .{ 255, 0, 0, 255 };

/// Build a `width × height` pixel buffer pre-filled with transparent pixels.
fn blankPixels(comptime width: u32, comptime height: u32) [width * height][4]u8 {
    var out: [width * height][4]u8 = undefined;
    @memset(&out, transparent);
    return out;
}

test "reduce returns null for fully transparent src" {
    var px = blankPixels(8, 8);
    try expectEqual(@as(?Rect, null), reduce(&px, 8, 8, .{ .x = 0, .y = 0, .w = 8, .h = 8 }));
}

test "reduce returns null for zero-area src" {
    var px = blankPixels(8, 8);
    px[0] = opaque_red;
    try expectEqual(@as(?Rect, null), reduce(&px, 8, 8, .{ .x = 0, .y = 0, .w = 0, .h = 4 }));
    try expectEqual(@as(?Rect, null), reduce(&px, 8, 8, .{ .x = 0, .y = 0, .w = 4, .h = 0 }));
}

test "reduce returns null for src origin outside the layer" {
    var px = blankPixels(4, 4);
    try expectEqual(@as(?Rect, null), reduce(&px, 4, 4, .{ .x = 4, .y = 0, .w = 1, .h = 1 }));
    try expectEqual(@as(?Rect, null), reduce(&px, 4, 4, .{ .x = 0, .y = 9, .w = 1, .h = 1 }));
}

test "reduce returns null on layer/pixels length mismatch (defensive)" {
    var px = blankPixels(4, 4);
    px[0] = opaque_red;
    try expectEqual(@as(?Rect, null), reduce(&px, 5, 4, .{ .x = 0, .y = 0, .w = 1, .h = 1 }));
}

test "reduce: single opaque pixel collapses src to 1x1" {
    var px = blankPixels(8, 8);
    px[3 * 8 + 5] = opaque_red;
    const r = reduce(&px, 8, 8, .{ .x = 0, .y = 0, .w = 8, .h = 8 }) orelse return error.Unexpected;
    try expectEqual(@as(u32, 5), r.x);
    try expectEqual(@as(u32, 3), r.y);
    try expectEqual(@as(u32, 1), r.w);
    try expectEqual(@as(u32, 1), r.h);
}

test "reduce: opaque pixel at (0,0) — corners returned exactly" {
    var px = blankPixels(8, 8);
    px[0] = opaque_red;
    const r = reduce(&px, 8, 8, .{ .x = 0, .y = 0, .w = 8, .h = 8 }) orelse return error.Unexpected;
    try expectEqual(@as(u32, 0), r.x);
    try expectEqual(@as(u32, 0), r.y);
    try expectEqual(@as(u32, 1), r.w);
    try expectEqual(@as(u32, 1), r.h);
}

test "reduce: opaque pixel at bottom-right corner" {
    var px = blankPixels(8, 8);
    px[7 * 8 + 7] = opaque_red;
    const r = reduce(&px, 8, 8, .{ .x = 0, .y = 0, .w = 8, .h = 8 }) orelse return error.Unexpected;
    try expectEqual(@as(u32, 7), r.x);
    try expectEqual(@as(u32, 7), r.y);
    try expectEqual(@as(u32, 1), r.w);
    try expectEqual(@as(u32, 1), r.h);
}

test "reduce: tightens around an opaque rectangle inside the cell" {
    // Paint a 3x2 rectangle at (2,4) inside an 8x8 layer.
    var px = blankPixels(8, 8);
    var y: u32 = 4;
    while (y < 6) : (y += 1) {
        var x: u32 = 2;
        while (x < 5) : (x += 1) {
            px[y * 8 + x] = opaque_red;
        }
    }
    const r = reduce(&px, 8, 8, .{ .x = 0, .y = 0, .w = 8, .h = 8 }) orelse return error.Unexpected;
    try expectEqual(@as(u32, 2), r.x);
    try expectEqual(@as(u32, 4), r.y);
    try expectEqual(@as(u32, 3), r.w);
    try expectEqual(@as(u32, 2), r.h);
}

test "reduce: src rect smaller than layer is honoured (does not see pixels outside)" {
    var px = blankPixels(8, 8);
    // Opaque pixel outside the src rect — must not affect the reduce.
    px[7 * 8 + 7] = opaque_red;
    // Opaque pixel inside the src rect.
    px[1 * 8 + 1] = opaque_red;
    const r = reduce(&px, 8, 8, .{ .x = 0, .y = 0, .w = 4, .h = 4 }) orelse return error.Unexpected;
    try expectEqual(@as(u32, 1), r.x);
    try expectEqual(@as(u32, 1), r.y);
    try expectEqual(@as(u32, 1), r.w);
    try expectEqual(@as(u32, 1), r.h);
}

test "reduce: returned rect is fully contained in the (clamped) src rect" {
    var px = blankPixels(16, 16);
    // Stripe across the full layer.
    var x: u32 = 0;
    while (x < 16) : (x += 1) px[5 * 16 + x] = opaque_red;
    // Pick a src rect off-center; reduce should clamp to the stripe within it.
    const src = Rect{ .x = 4, .y = 3, .w = 6, .h = 5 };
    const r = reduce(&px, 16, 16, src) orelse return error.Unexpected;
    try expect(r.x >= src.x);
    try expect(r.y >= src.y);
    try expect(r.x + r.w <= src.x + src.w);
    try expect(r.y + r.h <= src.y + src.h);
    try expectEqual(@as(u32, 5), r.y);
    try expectEqual(@as(u32, 1), r.h);
    try expectEqual(@as(u32, src.x), r.x);
    try expectEqual(@as(u32, src.w), r.w);
}

test "reduce: src that overshoots the layer is clamped, not rejected" {
    var px = blankPixels(8, 8);
    px[7 * 8 + 7] = opaque_red;
    const r = reduce(&px, 8, 8, .{ .x = 6, .y = 6, .w = 32, .h = 32 }) orelse return error.Unexpected;
    try expectEqual(@as(u32, 7), r.x);
    try expectEqual(@as(u32, 7), r.y);
    try expectEqual(@as(u32, 1), r.w);
    try expectEqual(@as(u32, 1), r.h);
}

test "reduce: separate opaque islands inside the src rect are spanned by one bbox" {
    var px = blankPixels(10, 10);
    px[2 * 10 + 1] = opaque_red;
    px[7 * 10 + 8] = opaque_red;
    const r = reduce(&px, 10, 10, .{ .x = 0, .y = 0, .w = 10, .h = 10 }) orelse return error.Unexpected;
    try expectEqual(@as(u32, 1), r.x);
    try expectEqual(@as(u32, 2), r.y);
    try expectEqual(@as(u32, 8), r.w);
    try expectEqual(@as(u32, 6), r.h);
}

test "reduce: alpha=0 with non-zero RGB is treated as transparent" {
    var px = blankPixels(4, 4);
    // Many pipelines write color into transparent slots. The reducer must look at alpha only.
    px[0] = .{ 255, 255, 255, 0 };
    px[5] = opaque_red;
    const r = reduce(&px, 4, 4, .{ .x = 0, .y = 0, .w = 4, .h = 4 }) orelse return error.Unexpected;
    try expectEqual(@as(u32, 1), r.x);
    try expectEqual(@as(u32, 1), r.y);
    try expectEqual(@as(u32, 1), r.w);
    try expectEqual(@as(u32, 1), r.h);
}

test "reduce: returned rect's edges each touch an opaque pixel" {
    var px = blankPixels(12, 12);
    // L-shape: column at x=2 from y=2..6, row at y=6 from x=2..8.
    var y: u32 = 2;
    while (y <= 6) : (y += 1) px[y * 12 + 2] = opaque_red;
    var x: u32 = 2;
    while (x <= 8) : (x += 1) px[6 * 12 + x] = opaque_red;
    const r = reduce(&px, 12, 12, .{ .x = 0, .y = 0, .w = 12, .h = 12 }) orelse return error.Unexpected;
    try expectEqual(@as(u32, 2), r.x);
    try expectEqual(@as(u32, 2), r.y);
    try expectEqual(@as(u32, 7), r.w);
    try expectEqual(@as(u32, 5), r.h);

    // Top edge: row r.y has at least one opaque pixel within [r.x, r.x+r.w).
    var has_top = false;
    var has_bot = false;
    var has_left = false;
    var has_right = false;
    {
        var i: u32 = 0;
        while (i < r.w) : (i += 1) {
            if (isOpaque(px[r.y * 12 + (r.x + i)])) has_top = true;
            if (isOpaque(px[(r.y + r.h - 1) * 12 + (r.x + i)])) has_bot = true;
        }
    }
    {
        var i: u32 = 0;
        while (i < r.h) : (i += 1) {
            if (isOpaque(px[(r.y + i) * 12 + r.x])) has_left = true;
            if (isOpaque(px[(r.y + i) * 12 + (r.x + r.w - 1)])) has_right = true;
        }
    }
    try expect(has_top);
    try expect(has_bot);
    try expect(has_left);
    try expect(has_right);
}

test "anyOpaque: empty slice is not opaque" {
    const px: []const [4]u8 = &.{};
    try expect(!anyOpaque(px));
}

test "anyOpaque: all transparent is false" {
    var px = blankPixels(16, 16);
    try expect(!anyOpaque(&px));
}

test "anyOpaque: alpha=0 with non-zero RGB still counts as transparent" {
    var px = blankPixels(8, 8);
    @memset(&px, .{ 255, 255, 255, 0 });
    try expect(!anyOpaque(&px));
}

test "anyOpaque: a single opaque pixel anywhere is detected" {
    // Cover positions inside the first vector chunk, on a likely chunk boundary,
    // and in the ragged tail past the last full vector.
    for ([_]usize{ 0, 1, 7, 8, 15, 16, 31, 63, 64, 100, 254, 255 }) |idx| {
        var px = blankPixels(16, 16); // 256 pixels
        px[idx] = opaque_red;
        try expect(anyOpaque(&px));
    }
}

test "anyOpaque: detects opaque pixel in a non-vector-multiple length (tail)" {
    // 13 is prime — guarantees a scalar-tail remainder for any vector width.
    var px = blankPixels(13, 1);
    try expect(!anyOpaque(&px));
    px[12] = opaque_red;
    try expect(anyOpaque(&px));
}

test "anyOpaque: only the alpha byte matters (RGB ignored)" {
    var px = blankPixels(8, 8);
    // Opaque red has alpha 255 -> opaque.
    px[5] = opaque_red;
    try expect(anyOpaque(&px));
    // Clearing alpha (but leaving RGB) makes the whole slice transparent again.
    px[5] = .{ 255, 0, 0, 0 };
    try expect(!anyOpaque(&px));
}

test "originAfterReduce: zero offset leaves the origin untouched" {
    const o = originAfterReduce(.{ 4.0, 7.5 }, 0, 0, 0, 0);
    try expectEqual(@as(f32, 4.0), o[0]);
    try expectEqual(@as(f32, 7.5), o[1]);
}

test "originAfterReduce: shifts by the reduce delta within the cell" {
    // Cell (32, 32) reduced rect at (35, 38) → offsets (3, 6). Origin (12, 24) becomes (9, 18).
    const o = originAfterReduce(.{ 12.0, 24.0 }, 32, 32, 35, 38);
    try expectEqual(@as(f32, 9.0), o[0]);
    try expectEqual(@as(f32, 18.0), o[1]);
}

test "originAfterReduce: anchor lands on the same world pixel after tighten" {
    // Sprite is sliced from cell (16,16); origin in cell-local space is (10, 12).
    const cell_x: u32 = 16;
    const cell_y: u32 = 16;
    const origin_local: [2]f32 = .{ 10.0, 12.0 };

    // Reducer tightens the bitmap to start at (19, 17) inside the layer.
    const reduced_x: u32 = 19;
    const reduced_y: u32 = 17;

    const new_origin = originAfterReduce(origin_local, cell_x, cell_y, reduced_x, reduced_y);

    // Convert both origins back to layer-space and check the world pixel is identical.
    const orig_world_x: f32 = origin_local[0] + @as(f32, @floatFromInt(cell_x));
    const orig_world_y: f32 = origin_local[1] + @as(f32, @floatFromInt(cell_y));
    const new_world_x: f32 = new_origin[0] + @as(f32, @floatFromInt(reduced_x));
    const new_world_y: f32 = new_origin[1] + @as(f32, @floatFromInt(reduced_y));
    try expectEqual(orig_world_x, new_world_x);
    try expectEqual(orig_world_y, new_world_y);
}

test "originAfterReduce + reduce: round-trip on a real bitmap" {
    // Paint a 2x2 opaque block at (5, 6) inside an 8x8 cell at (0, 0) within a 16x16 layer.
    // Cell origin (0, 0); sprite origin in cell-local space at (4, 5) (just below the block).
    var px = blankPixels(16, 16);
    var y: u32 = 6;
    while (y < 8) : (y += 1) {
        var x: u32 = 5;
        while (x < 7) : (x += 1) {
            px[y * 16 + x] = opaque_red;
        }
    }

    const cell = Rect{ .x = 0, .y = 0, .w = 8, .h = 8 };
    const r = reduce(&px, 16, 16, cell) orelse return error.Unexpected;
    try expectEqual(@as(u32, 5), r.x);
    try expectEqual(@as(u32, 6), r.y);

    const new_origin = originAfterReduce(.{ 4.0, 5.0 }, cell.x, cell.y, r.x, r.y);
    // Origin in reduced-bitmap-local space.
    try expectEqual(@as(f32, -1.0), new_origin[0]);
    try expectEqual(@as(f32, -1.0), new_origin[1]);
    // World pixel preserved.
    try expectEqual(
        @as(f32, 4.0) + @as(f32, @floatFromInt(cell.x)),
        new_origin[0] + @as(f32, @floatFromInt(r.x)),
    );
}
