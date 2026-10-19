//! A tile hash of an image: 8 bytes per tile (a 4K image at 32x32 is about 16 KB), cheap to keep
//! per history step. Diffing a past step is then a compare of two grids, not two images.
//! A grid sees tiles, not pixels: its rects are whole tiles and it counts no pixels.
const std = @import("std");
const Image = @import("Image.zig");

const TileGrid = @This();

pub const Error = error{TileSizeMismatch} || std.mem.Allocator.Error;

width: u32 = 0,
height: u32 = 0,
tile: Image.TileSize = .@"32",
w_tiles: u32 = 0,
h_tiles: u32 = 0,
hashes: std.ArrayList(u64) = .empty,

pub fn deinit(self: *TileGrid, gpa: std.mem.Allocator) void {
    self.hashes.deinit(gpa);
    self.* = .{};
}

/// Hash `src` into the grid, reusing its storage. Each tile is hashed row by row (Wyhash chained over its
/// row slices), never per pixel.
pub fn compute(self: *TileGrid, gpa: std.mem.Allocator, src: Image.Source, tile: Image.TileSize) std.mem.Allocator.Error!void {
    std.debug.assert(src.valid());
    const shift: u5 = @backingInt(tile);
    const size = @as(u32, 1) << shift;
    const w_tiles = (src.width + size - 1) >> shift;
    const h_tiles = (src.height + size - 1) >> shift;
    // Resize first: a failure leaves the grid as it was, still matching its hashes.
    try self.hashes.resize(gpa, @as(usize, w_tiles) * h_tiles);
    self.tile = tile;
    self.width = src.width;
    self.height = src.height;
    self.w_tiles = w_tiles;
    self.h_tiles = h_tiles;
    for (0..self.h_tiles) |ty| {
        const y0: u32 = @intCast(ty << shift);
        const y1 = @min(y0 + size, src.height);
        for (0..self.w_tiles) |tx| {
            const x0: u32 = @intCast(tx << shift);
            const x1 = @min(x0 + size, src.width);
            var h: u64 = 0;
            var y = y0;
            while (y < y1) : (y += 1) h = std.hash.Wyhash.hash(h, src.row(y, x0, x1));
            self.hashes.items[ty * self.w_tiles + tx] = h;
        }
    }
}

/// The tiles that differ between this grid (earlier) and `later`, as rects in `img`. Tiles are
/// compared where both images are whole there: with different sizes, a tile cut short in either
/// is not compared, and `size_changed` says the rest was not looked at.
/// (A dimension that matches keeps its edge tiles.)
pub fn diff(self: *const TileGrid, later: *const TileGrid, img: *Image, gpa: std.mem.Allocator, max_rects: u32) Error!Image.Result {
    if (self.tile != later.tile) return error.TileSizeMismatch;
    const shift: u5 = @backingInt(self.tile);
    const size = @as(u32, 1) << shift;
    const same_size = self.width == later.width and self.height == later.height;
    const w = @min(self.width, later.width);
    const h = @min(self.height, later.height);
    // An edge tile is cut the same in both only along a dimension that matches.
    const w_tiles = if (self.width == later.width) self.w_tiles else w >> shift;
    const h_tiles = if (self.height == later.height) self.h_tiles else h >> shift;

    var result: Image.Result = .{ .rects = &.{}, .size_changed = !same_size };
    try img.boxes.resize(gpa, @as(usize, w_tiles) * h_tiles);
    for (0..h_tiles) |ty| {
        for (0..w_tiles) |tx| {
            const box = &img.boxes.items[ty * w_tiles + tx];
            box.* = .{};
            if (self.hashes.items[ty * self.w_tiles + tx] == later.hashes.items[ty * later.w_tiles + tx]) continue;
            const x0: u32 = @intCast(tx << shift);
            const y0: u32 = @intCast(ty << shift);
            box.* = .{ .x0 = x0, .y0 = y0, .x1 = @min(x0 + size, w), .y1 = @min(y0 + size, h) };
        }
    }
    try img.merge(gpa, w_tiles, h_tiles, .{ .max_rects = max_rects }, &result);
    return result;
}

test "grids of equal images match; one pixel changes one tile" {
    const gpa = std.testing.allocator;
    const a = try gpa.alloc(u8, 70 * 70 * 4);
    defer gpa.free(a);
    @memset(a, 7);
    const b = try gpa.dupe(u8, a);
    defer gpa.free(b);
    var ga: TileGrid = .{};
    defer ga.deinit(gpa);
    var gb: TileGrid = .{};
    defer gb.deinit(gpa);
    var img: Image = .{};
    defer img.deinit(gpa);
    try ga.compute(gpa, .tight(a, 70, 70), .@"32");
    try gb.compute(gpa, .tight(b, 70, 70), .@"32");
    try std.testing.expect((try ga.diff(&gb, &img, gpa, 8)).isEmpty());
    b[(40 * 70 + 65) * 4] = 0;
    try gb.compute(gpa, .tight(b, 70, 70), .@"32");
    const r = try ga.diff(&gb, &img, gpa, 8);
    try std.testing.expectEqual(@as(usize, 1), r.rects.len);
    // The edge tile is clipped to the image.
    try std.testing.expectEqualDeep(Image.Rect{ .x = 64, .y = 32, .w = 6, .h = 32 }, r.rects[0]);
}
