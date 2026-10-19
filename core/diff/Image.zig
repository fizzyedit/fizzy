//! Image diff over RGBA8 pixels: which rectangles of one image differ from another's.
//!
//! The pass walks both images a row at a time. A row that is identical (one `std.mem.eql`, the
//! common case in sprite work) costs memory bandwidth and nothing more; a row that differs is
//! compared per tile segment, starting at its first differing byte. Each changed tile records the
//! exact bounding box of its changed pixels and how many there are (`Options.exact`), the changed
//! tiles are merged into rectangles (runs along a row, joined to an identical run above), and each
//! rectangle shrinks to the union of its tiles' exact boxes.
//!
//! `Image` is the reusable state (`Scratch` in the plan): after a first diff of a size, later ones
//! allocate nothing. Sizes that differ report `size_changed` and diff the overlap; there is no
//! alignment search. Not a perceptual or motion diff.
const std = @import("std");

const Image = @This();

/// Bytes per pixel: R, G, B, A.
pub const bpp = 4;

/// Pixels of `width` x `height`, rows `stride` bytes apart (`stride >= width * 4`).
pub const Source = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
    stride: u32,

    /// Rows packed with no padding.
    pub fn tight(pixels: []const u8, width: u32, height: u32) Source {
        return .{ .pixels = pixels, .width = width, .height = height, .stride = width * bpp };
    }

    pub fn row(self: Source, y: u32, x0: u32, x1: u32) []const u8 {
        const at = @as(usize, y) * self.stride + @as(usize, x0) * bpp;
        return self.pixels[at..][0 .. @as(usize, x1 - x0) * bpp];
    }

    /// Whether `pixels` really holds the rows it claims.
    pub fn valid(self: Source) bool {
        if (self.stride < self.width * bpp) return false;
        if (self.width == 0 or self.height == 0) return true;
        return self.pixels.len >= @as(usize, self.height - 1) * self.stride + @as(usize, self.width) * bpp;
    }
};

/// A tile is 2^shift pixels square. 32x32 is 4 KiB of RGBA; 16x16 suits a small canvas.
pub const TileSize = enum(u3) {
    @"16" = 4,
    @"32" = 5,
};

pub const Options = struct {
    tile: TileSize = .@"32",
    /// More rects than this coalesce the rest into one bounding box (`Result.coalesced`).
    max_rects: u32 = 64,
    /// Shrink each rect to its changed pixels and count them. Off, a rect is whole tiles and the
    /// first differing pixel in a tile is enough to stop looking at it.
    exact: bool = true,
    /// A pixel whose every channel is within this of the other's counts as unchanged, for lossy
    /// sources. Off by default.
    tolerance: u8 = 0,
};

pub const Rect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

pub const Result = struct {
    /// Pixel rects that cover every change, in the order their top-left tiles were met. Owned by
    /// the `Image` that produced them: valid until its next diff. Rects never overlap, except
    /// that a coalesced last one is a bounding box and may cover the others.
    rects: []const Rect,
    /// Changed pixels. Only counted when `Options.exact` (a `TileGrid` diff cannot see pixels).
    changed_px: u64 = 0,
    tiles_changed: u32 = 0,
    /// The two images' dimensions differ; only the overlap was compared.
    size_changed: bool = false,
    coalesced: bool = false,

    pub fn isEmpty(self: Result) bool {
        return self.rects.len == 0 and !self.size_changed;
    }
};

/// The index of the first byte where `a` and `b` (the same length) differ, 64 bytes at a time.
/// `std.mem.indexOfDiff` and `eql` are not vectorized well enough for a 4K image to meet the
/// budget; this is the loop the whole diff leans on.
pub fn firstDiff(a: []const u8, b: []const u8) ?usize {
    std.debug.assert(a.len == b.len);
    const V = @Vector(64, u8);
    var i: usize = 0;
    while (i + 64 <= a.len) : (i += 64) {
        const va: V = a[i..][0..64].*;
        const vb: V = b[i..][0..64].*;
        if (!@reduce(.And, va == vb)) return i + std.mem.indexOfDiff(u8, a[i..][0..64], b[i..][0..64]).?;
    }
    return if (i == a.len) null else if (std.mem.indexOfDiff(u8, a[i..], b[i..])) |d| i + d else null;
}

/// One tile's changed pixels: an empty box (`x0 >= x1`) is unchanged.
const Box = struct {
    x0: u32 = std.math.maxInt(u32),
    y0: u32 = std.math.maxInt(u32),
    x1: u32 = 0,
    y1: u32 = 0,
    count: u32 = 0,

    fn changed(self: Box) bool {
        return self.x0 < self.x1;
    }

    fn add(self: *Box, other: Box) void {
        self.x0 = @min(self.x0, other.x0);
        self.y0 = @min(self.y0, other.y0);
        self.x1 = @max(self.x1, other.x1);
        self.y1 = @max(self.y1, other.y1);
        self.count += other.count;
    }
};

/// A rect being grown by the merge: tile extents to match the next row's runs, and the union
/// of its tiles' boxes.
const Acc = struct {
    tx0: u32,
    tx1: u32,
    ty_last: u32,
    box: Box,
};

boxes: std.ArrayList(Box) = .empty,
open_prev: std.ArrayList(u32) = .empty,
open_cur: std.ArrayList(u32) = .empty,
accs: std.ArrayList(Acc) = .empty,
out: std.ArrayList(Rect) = .empty,

pub fn deinit(self: *Image, gpa: std.mem.Allocator) void {
    self.boxes.deinit(gpa);
    self.open_prev.deinit(gpa);
    self.open_cur.deinit(gpa);
    self.accs.deinit(gpa);
    self.out.deinit(gpa);
    self.* = .{};
}

/// The pixels where `a` and `b` differ, as rects. `a` is the earlier image, `b` the later; the
/// result is symmetric.
pub fn diff(self: *Image, gpa: std.mem.Allocator, a: Source, b: Source, opts: Options) !Result {
    std.debug.assert(a.valid() and b.valid());
    const w = @min(a.width, b.width);
    const h = @min(a.height, b.height);
    var result: Result = .{ .rects = &.{}, .size_changed = a.width != b.width or a.height != b.height };
    if (w == 0 or h == 0) return result;

    // The same storage (a layer two steps share) is identical without a compare.
    if (!result.size_changed and a.stride == b.stride and a.pixels.ptr == b.pixels.ptr) return result;
    // Identical buffers return after one pass of memory compare.
    if (!result.size_changed and a.stride == w * bpp and b.stride == w * bpp) {
        const n = @as(usize, w) * h * bpp;
        if (firstDiff(a.pixels[0..n], b.pixels[0..n]) == null) return result;
    }

    const shift: u5 = @backingInt(opts.tile);
    const w_tiles = (w + (@as(u32, 1) << shift) - 1) >> shift;
    const h_tiles = (h + (@as(u32, 1) << shift) - 1) >> shift;
    try self.boxes.resize(gpa, @as(usize, w_tiles) * h_tiles);
    @memset(self.boxes.items, .{});

    const tile = @as(u32, 1) << shift;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const ra = a.row(y, 0, w);
        const rb = b.row(y, 0, w);
        // The first differing byte skips every tile before it; an identical row skips all.
        const first = firstDiff(ra, rb) orelse continue;
        const row_boxes = self.boxes.items[@as(usize, y >> shift) * w_tiles ..][0..w_tiles];
        var tx: u32 = @intCast((first / bpp) >> shift);
        while (tx < w_tiles) : (tx += 1) {
            const box = &row_boxes[tx];
            if (box.changed() and !opts.exact) continue;
            const x0 = tx << shift;
            const x1 = @min(x0 + tile, w);
            const ty0 = (y >> shift) << shift;
            const whole: Box = .{ .x0 = x0, .y0 = ty0, .x1 = x1, .y1 = @min(ty0 + tile, h) };
            scanSegment(box, ra[x0 * bpp .. x1 * bpp], rb[x0 * bpp .. x1 * bpp], x0, y, whole, opts);
        }
    }

    try self.merge(gpa, w_tiles, h_tiles, opts, &result);
    return result;
}

/// Compare one tile's slice of one row, widening `box` over the pixels that differ. Without
/// `exact`, the box becomes the whole tile at the first one.
fn scanSegment(box: *Box, sa: []const u8, sb: []const u8, x0: u32, y: u32, whole: Box, opts: Options) void {
    var x: usize = firstDiff(sa, sb) orelse return;
    x /= bpp;
    const px = sa.len / bpp;
    // Pixels before the first differing byte are identical; walk from there to the segment's end.
    while (x < px) : (x += 1) {
        const pa = sa[x * bpp ..][0..bpp];
        const pb = sb[x * bpp ..][0..bpp];
        if (!pixelsDiffer(pa, pb, opts.tolerance)) continue;
        if (!opts.exact) {
            box.* = whole;
            return;
        }
        const gx = x0 + @as(u32, @intCast(x));
        box.x0 = @min(box.x0, gx);
        box.x1 = @max(box.x1, gx + 1);
        box.y0 = @min(box.y0, y);
        box.y1 = @max(box.y1, y + 1);
        box.count += 1;
    }
}

fn pixelsDiffer(pa: *const [bpp]u8, pb: *const [bpp]u8, tolerance: u8) bool {
    if (tolerance == 0) return !std.mem.eql(u8, pa, pb);
    inline for (0..bpp) |i| {
        if (@abs(@as(i16, pa[i]) - @as(i16, pb[i])) > tolerance) return true;
    }
    return false;
}

/// Merge the changed tiles in `boxes` (`TileGrid.diff` fills them too) into `self.out`: runs along a row, each joined to the run
/// above it with the same tile extents.
pub fn merge(self: *Image, gpa: std.mem.Allocator, w_tiles: u32, h_tiles: u32, opts: Options, result: *Result) !void {
    try self.open_prev.resize(gpa, w_tiles);
    try self.open_cur.resize(gpa, w_tiles);
    @memset(self.open_prev.items, 0);
    self.accs.clearRetainingCapacity();
    self.out.clearRetainingCapacity();

    var ty: u32 = 0;
    while (ty < h_tiles) : (ty += 1) {
        @memset(self.open_cur.items, 0);
        const row = self.boxes.items[@as(usize, ty) * w_tiles ..][0..w_tiles];
        var tx: u32 = 0;
        while (tx < w_tiles) {
            if (!row[tx].changed()) {
                tx += 1;
                continue;
            }
            const start = tx;
            var run: Box = .{};
            while (tx < w_tiles and row[tx].changed()) : (tx += 1) {
                run.add(row[tx]);
                result.tiles_changed += 1;
            }
            const above = self.open_prev.items[start];
            if (above != 0 and self.accs.items[above - 1].tx1 == tx and self.accs.items[above - 1].ty_last + 1 == ty) {
                const acc = &self.accs.items[above - 1];
                acc.ty_last = ty;
                acc.box.add(run);
                self.open_cur.items[start] = above;
            } else {
                try self.accs.append(gpa, .{ .tx0 = start, .tx1 = tx, .ty_last = ty, .box = run });
                self.open_cur.items[start] = @intCast(self.accs.items.len);
            }
        }
        std.mem.swap(std.ArrayList(u32), &self.open_prev, &self.open_cur);
    }

    const keep = @max(opts.max_rects, 1);
    const coalesce = self.accs.items.len > keep;
    const direct = if (coalesce) keep - 1 else self.accs.items.len;
    var rest: Box = .{};
    for (self.accs.items, 0..) |acc, i| {
        result.changed_px += acc.box.count;
        if (i >= direct) {
            rest.add(acc.box);
            continue;
        }
        try self.out.append(gpa, boxRect(acc.box));
    }
    if (coalesce) try self.out.append(gpa, boxRect(rest));
    result.coalesced = coalesce;
    result.rects = self.out.items;
}

fn boxRect(box: Box) Rect {
    return .{ .x = box.x0, .y = box.y0, .w = box.x1 - box.x0, .h = box.y1 - box.y0 };
}

// --- tests ---------------------------------------------------------------------------------

const testing = std.testing;

fn blank(gpa: std.mem.Allocator, w: u32, h: u32) ![]u8 {
    const px = try gpa.alloc(u8, @as(usize, w) * h * bpp);
    @memset(px, 0);
    return px;
}

fn setPx(px: []u8, w: u32, x: u32, y: u32, v: u8) void {
    px[(@as(usize, y) * w + x) * bpp] = v;
}

test "identical images have no changes" {
    const a = try blank(testing.allocator, 100, 70);
    defer testing.allocator.free(a);
    const b = try testing.allocator.dupe(u8, a);
    defer testing.allocator.free(b);
    var img: Image = .{};
    defer img.deinit(testing.allocator);
    const r = try img.diff(testing.allocator, .tight(a, 100, 70), .tight(b, 100, 70), .{});
    try testing.expect(r.isEmpty());
}

test "one pixel gives its exact rect" {
    const a = try blank(testing.allocator, 100, 70);
    defer testing.allocator.free(a);
    const b = try testing.allocator.dupe(u8, a);
    defer testing.allocator.free(b);
    setPx(b, 100, 37, 50, 9);
    var img: Image = .{};
    defer img.deinit(testing.allocator);
    const r = try img.diff(testing.allocator, .tight(a, 100, 70), .tight(b, 100, 70), .{});
    try testing.expectEqual(@as(usize, 1), r.rects.len);
    try testing.expectEqualDeep(Rect{ .x = 37, .y = 50, .w = 1, .h = 1 }, r.rects[0]);
    try testing.expectEqual(@as(u64, 1), r.changed_px);

    const whole = try img.diff(testing.allocator, .tight(a, 100, 70), .tight(b, 100, 70), .{ .exact = false });
    try testing.expectEqualDeep(Rect{ .x = 32, .y = 32, .w = 32, .h = 32 }, whole.rects[0]);
}

test "changed tiles merge into disjoint rects by run" {
    const a = try blank(testing.allocator, 128, 128);
    defer testing.allocator.free(a);
    const b = try testing.allocator.dupe(u8, a);
    defer testing.allocator.free(b);
    var y: u32 = 20;
    while (y < 90) : (y += 1) {
        var x: u32 = 10;
        while (x < 70) : (x += 1) setPx(b, 128, x, y, 1);
    }
    setPx(b, 128, 120, 5, 1);
    var img: Image = .{};
    defer img.deinit(testing.allocator);
    const r = try img.diff(testing.allocator, .tight(a, 128, 128), .tight(b, 128, 128), .{});
    try testing.expectEqual(@as(usize, 2), r.rects.len);
    // Greedy cover by tile runs: the top tile row's run (the block's tiles and the pixel's, one
    // run, its box the union of their changes) and the block's lower rows, which share only the
    // block's three tiles. Disjoint, and together exactly the changes.
    try testing.expectEqualDeep(Rect{ .x = 10, .y = 5, .w = 111, .h = 27 }, r.rects[0]);
    try testing.expectEqualDeep(Rect{ .x = 10, .y = 32, .w = 60, .h = 58 }, r.rects[1]);
    try testing.expectEqual(@as(u64, 60 * 70 + 1), r.changed_px);
}

test "stride is honoured and padding ignored" {
    const w = 40;
    const h = 40;
    const stride = w * bpp + 16;
    const a = try testing.allocator.alloc(u8, stride * h);
    defer testing.allocator.free(a);
    @memset(a, 0);
    const b = try testing.allocator.dupe(u8, a);
    defer testing.allocator.free(b);
    b[10 * stride + w * bpp + 3] = 77; // padding
    var img: Image = .{};
    defer img.deinit(testing.allocator);
    const sa: Source = .{ .pixels = a, .width = w, .height = h, .stride = stride };
    var sb = sa;
    sb.pixels = b;
    try testing.expect((try img.diff(testing.allocator, sa, sb, .{})).isEmpty());
    b[39 * stride + 39 * bpp + 2] = 5;
    const r = try img.diff(testing.allocator, sa, sb, .{});
    try testing.expectEqualDeep(Rect{ .x = 39, .y = 39, .w = 1, .h = 1 }, r.rects[0]);
}

test "tolerance, sizes and coalescing" {
    const a = try blank(testing.allocator, 128, 64);
    defer testing.allocator.free(a);
    const b = try testing.allocator.dupe(u8, a);
    defer testing.allocator.free(b);
    setPx(b, 128, 3, 3, 4);
    var img: Image = .{};
    defer img.deinit(testing.allocator);
    try testing.expect((try img.diff(testing.allocator, .tight(a, 128, 64), .tight(b, 128, 64), .{ .tolerance = 4 })).isEmpty());
    try testing.expectEqual(@as(usize, 1), (try img.diff(testing.allocator, .tight(a, 128, 64), .tight(b, 128, 64), .{ .tolerance = 3 })).rects.len);

    const small = try blank(testing.allocator, 64, 64);
    defer testing.allocator.free(small);
    const r = try img.diff(testing.allocator, .tight(a, 128, 64), .tight(small, 64, 64), .{});
    try testing.expect(r.size_changed and r.rects.len == 0);

    // Three separated changes with room for two rects: the last two share a bounding box.
    setPx(b, 128, 100, 3, 1);
    setPx(b, 128, 40, 50, 1);
    const c = try img.diff(testing.allocator, .tight(a, 128, 64), .tight(b, 128, 64), .{ .max_rects = 2 });
    try testing.expect(c.coalesced);
    try testing.expectEqual(@as(usize, 2), c.rects.len);
    try testing.expectEqualDeep(Rect{ .x = 40, .y = 3, .w = 61, .h = 48 }, c.rects[1]);
}

test "property: rects cover every differing pixel and count them exactly" {
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();
    var img: Image = .{};
    defer img.deinit(testing.allocator);
    for (0..40) |_| {
        const w = rnd.intRangeAtMost(u32, 1, 150);
        const h = rnd.intRangeAtMost(u32, 1, 150);
        const a = try blank(testing.allocator, w, h);
        defer testing.allocator.free(a);
        rnd.bytes(a);
        const b = try testing.allocator.dupe(u8, a);
        defer testing.allocator.free(b);
        for (0..rnd.intRangeAtMost(usize, 0, 20)) |_| b[rnd.uintLessThan(usize, b.len)] +%= 1;
        const r = try img.diff(testing.allocator, .tight(a, w, h), .tight(b, w, h), .{ .max_rects = 1000 });
        var diff_px: u64 = 0;
        var y: u32 = 0;
        while (y < h) : (y += 1) {
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                const i = (@as(usize, y) * w + x) * bpp;
                if (std.mem.eql(u8, a[i..][0..bpp], b[i..][0..bpp])) continue;
                diff_px += 1;
                var covered = false;
                for (r.rects) |c| covered = covered or (x >= c.x and x < c.x + c.w and y >= c.y and y < c.y + c.h);
                try testing.expect(covered);
            }
        }
        try testing.expectEqual(diff_px, r.changed_px);
    }
}
