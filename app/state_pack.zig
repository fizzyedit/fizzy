//! A document state as it is stored in a track file (`track_file`): the bytes
//! `captureDocumentState` gave, packed without losing any. A canvas is mostly transparent, so the
//! raw state of a few layers of pixels is tens of megabytes of which almost every byte is zero.
//!
//! Two steps, each only kept when it is smaller, chosen by a mode byte that opens the packed form:
//!
//!   * **Zero runs** (`zero_runs`): a pass over the bytes, a word at a time, that stores each run
//!     of zeros as its length and everything between runs as it is. It costs one scan, so a
//!     frame can afford it; the deflate below runs on its far smaller output.
//!   * **Deflate** (`deflated`): the zero-run form through zlib, when it is still a few KiB or
//!     more. Not tried on a form over `deflate_limit` (an incompressible document would cost a
//!     frame's worth of time for nothing); that stays zero-run packed.
//!
//! Layout, every count LEB128: `raw`, the bytes; `zero_runs`, the length, then per run its zeros,
//! the literal length and the literal; `deflated`, the zero-run form's length, then its zlib
//! stream. `unpack` refuses (`error.BadPack`) anything cut short, longer than `max_len`, or not
//! adding up to its length.
//!
//! std-only, so it tests without a window (`fizzy-state-pack-tests`).
const std = @import("std");
const flate = std.compress.flate;

const Mode = enum(u8) { raw, zero_runs, deflated };

/// The most a packed state may unpack to: a corrupt file must not ask for the machine's memory.
pub const max_len = 4 << 30;
/// A zero-run form at least this long is tried through deflate.
const deflate_min = 4096;
/// And one longer than this is not.
pub const deflate_limit = 16 << 20;
/// What a deflated form's length takes before its stream, at most.
const length_room = 10;
/// Fewer zeros than this in a row are not worth a run of their own.
const min_run = 8;

pub const Error = error{BadPack} || std.mem.Allocator.Error;

/// `bytes` packed, allocated with `gpa`. Never longer than `bytes` and one byte.
pub fn pack(gpa: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error![]u8 {
    var runs: std.Io.Writer.Allocating = .init(gpa);
    defer runs.deinit();
    // An allocating writer fails only for want of memory.
    writeRuns(&runs.writer, bytes) catch return error.OutOfMemory;
    const form = runs.written();

    var best: Mode = .raw;
    var best_len = bytes.len;
    var zipped: ?[]u8 = null;
    defer if (zipped) |z| gpa.free(z);
    if (form.len < best_len) {
        best = .zero_runs;
        best_len = form.len;
    }
    if (form.len >= deflate_min and form.len <= deflate_limit) {
        if (try deflate(gpa, form)) |z| {
            if (z.len + length_room < best_len) {
                zipped = z;
                best = .deflated;
                best_len = z.len;
            } else gpa.free(z);
        }
    }

    const out = try gpa.alloc(u8, @as(usize, 1) + best_len + @as(usize, if (best == .deflated) length_room else 0));
    errdefer gpa.free(out);
    var w: std.Io.Writer = .fixed(out);
    w.writeByte(@backingInt(best)) catch unreachable;
    switch (best) {
        .raw => w.writeAll(bytes) catch unreachable,
        .zero_runs => w.writeAll(form) catch unreachable,
        .deflated => {
            w.writeUleb128(form.len) catch unreachable;
            w.writeAll(zipped.?) catch unreachable;
        },
    }
    return gpa.realloc(out, w.end);
}

/// The bytes `packed` was made from, allocated with `gpa`.
pub fn unpack(gpa: std.mem.Allocator, packed_bytes: []const u8) Error![]u8 {
    if (packed_bytes.len == 0) return error.BadPack;
    const mode = std.enums.fromInt(Mode, packed_bytes[0]) orelse return error.BadPack;
    const body = packed_bytes[1..];
    switch (mode) {
        .raw => return gpa.dupe(u8, body),
        .zero_runs => return readRuns(gpa, body),
        .deflated => {
            var r: std.Io.Reader = .fixed(body);
            const len = r.takeLeb128(usize) catch return error.BadPack;
            if (len > max_len) return error.BadPack;
            const window = try gpa.alloc(u8, flate.max_window_len);
            defer gpa.free(window);
            var d: flate.Decompress = .init(&r, .zlib, window);
            const form = d.reader.allocRemaining(gpa, .limited(len + 1)) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.ReadFailed, error.StreamTooLong => error.BadPack,
            };
            defer gpa.free(form);
            if (form.len != len or d.state != .end) return error.BadPack;
            if (std.hash.Adler32.hash(form) != d.container_metadata.zlib.adler) return error.BadPack;
            return readRuns(gpa, form);
        },
    }
}

fn deflate(gpa: std.mem.Allocator, form: []const u8) std.mem.Allocator.Error!?[]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 64);
    defer out.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    const c = try gpa.create(flate.Compress);
    defer gpa.destroy(c);
    c.* = flate.Compress.init(&out.writer, window, .zlib, .default) catch return null;
    c.writer.writeAll(form) catch return null;
    c.finish() catch return null;
    return try out.toOwnedSlice();
}

fn isZeroWord(bytes: []const u8, i: usize) bool {
    return i + min_run <= bytes.len and std.mem.readInt(u64, bytes[i..][0..8], .little) == 0;
}

fn writeRuns(w: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    try w.writeUleb128(bytes.len);
    var i: usize = 0;
    while (i < bytes.len) {
        const zeros_at = i;
        while (isZeroWord(bytes, i)) i += 8;
        while (i < bytes.len and bytes[i] == 0) i += 1;
        const lit_at = i;
        // A literal runs to the next stretch of `min_run` zeros, or the end.
        while (i < bytes.len and !isZeroWord(bytes, i)) i += 1;
        try w.writeUleb128(lit_at - zeros_at);
        try w.writeUleb128(i - lit_at);
        try w.writeAll(bytes[lit_at..i]);
    }
}

fn readRuns(gpa: std.mem.Allocator, form: []const u8) Error![]u8 {
    var r: std.Io.Reader = .fixed(form);
    const len = r.takeLeb128(usize) catch return error.BadPack;
    if (len > max_len) return error.BadPack;
    const out = try gpa.alloc(u8, len);
    errdefer gpa.free(out);
    var at: usize = 0;
    while (at < len) {
        const zeros = r.takeLeb128(usize) catch return error.BadPack;
        const lit = r.takeLeb128(usize) catch return error.BadPack;
        if (zeros > len - at or lit > len - at - zeros) return error.BadPack;
        @memset(out[at..][0..zeros], 0);
        at += zeros;
        r.readSliceAll(out[at..][0..lit]) catch return error.BadPack;
        at += lit;
    }
    if (r.bufferedLen() != 0) return error.BadPack;
    return out;
}

const testing = std.testing;

fn expectRoundTrip(bytes: []const u8) !usize {
    const p = try pack(testing.allocator, bytes);
    defer testing.allocator.free(p);
    try testing.expect(p.len <= bytes.len + 1);
    const back = try unpack(testing.allocator, p);
    defer testing.allocator.free(back);
    try testing.expectEqualSlices(u8, bytes, back);
    return p.len;
}

test "a state packs and unpacks to the same bytes, whatever it holds" {
    _ = try expectRoundTrip("");
    _ = try expectRoundTrip("x");
    _ = try expectRoundTrip("plain text with no zeros at all");
    _ = try expectRoundTrip(&@as([7]u8, @splat(0)));
    _ = try expectRoundTrip(&@as([100]u8, @splat(0)));
    _ = try expectRoundTrip(&(@as([100]u8, @splat(0)) ++ [_]u8{ 1, 2, 3 } ++ @as([5]u8, @splat(0)) ++ [_]u8{9} ++ @as([16]u8, @splat(0))));
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    var buf: [20000]u8 = undefined;
    for (0..40) |_| {
        // Sparse, with runs of every length around the word size.
        @memset(&buf, 0);
        for (0..random.uintLessThan(usize, 60)) |_| {
            const at = random.uintLessThan(usize, buf.len);
            const n = @min(random.uintLessThan(usize, 40), buf.len - at);
            random.bytes(buf[at..][0..n]);
        }
        _ = try expectRoundTrip(buf[0..random.uintLessThan(usize, buf.len + 1)]);
    }
    random.bytes(&buf);
    _ = try expectRoundTrip(&buf);
}

test "a mostly transparent canvas packs to the size of what is drawn on it" {
    const gpa = testing.allocator;
    const canvas = try gpa.alloc(u8, 8 << 20);
    defer gpa.free(canvas);
    @memset(canvas, 0);
    var prng = std.Random.DefaultPrng.init(1);
    // A few strokes of noise: the pixels that are not transparent.
    for (0..20) |i| prng.random().bytes(canvas[i * 400_000 ..][0..3000]);
    const n = try expectRoundTrip(canvas);
    try testing.expect(n < 64 * 1024);
}

test "a packed state that is cut short or inconsistent is refused" {
    const gpa = testing.allocator;
    var canvas: [20000]u8 = @splat(0);
    canvas[5] = 1;
    canvas[15000] = 2;
    const p = try pack(gpa, &canvas);
    defer gpa.free(p);
    try testing.expectError(error.BadPack, unpack(gpa, ""));
    try testing.expectError(error.BadPack, unpack(gpa, &.{9}));
    for (0..p.len) |cut| if (unpack(gpa, p[0..cut])) |b| {
        gpa.free(b);
        return error.TestUnexpectedResult;
    } else |_| {};
}
