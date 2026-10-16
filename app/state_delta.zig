//! What one document state is, as the bytes that differ from another: how a track keeps its
//! checkpoints (`Tracks`) without a whole copy of the document each time.
//!
//! Generic over any owner's state bytes (`captureDocumentState`'s), so no owner writes anything for
//! it. Two steps, each a pass over the bytes:
//!
//!   * **The common prefix and suffix are trimmed.** Typing in one place, strokes in one area,
//!     leave a small middle between them that differs.
//!   * **The middle,** when it is as long in both (nothing shifted: a canvas's pixels, a fixed
//!     layout), is kept as the runs of `block`-byte blocks that differ, so strokes far apart are
//!     a few runs rather than one span from the first to the last. When the lengths differ (text
//!     inserted, which shifts what follows), it is kept as it is.
//!
//! Layout, every count LEB128: the new length, the prefix, the suffix, a mode byte, then the
//! mode's own: `raw`, the middle's bytes; `runs`, a count, then per run its gap from the last
//! run's end, its length, its bytes.
//!
//! std-only, so it tests without a window (`fizzy-state-delta-tests`).
const std = @import("std");

/// The unit runs are found in: smaller finds tighter runs over more of them.
pub const block = 64;

const Mode = enum(u8) { raw, runs };

pub const Error = error{BadDelta} || std.mem.Allocator.Error;

/// `new` as a delta against `ref`, allocated with `gpa`.
pub fn encode(gpa: std.mem.Allocator, ref: []const u8, new: []const u8) std.mem.Allocator.Error![]u8 {
    const shortest = @min(ref.len, new.len);
    // A block at a time while they agree (a memcmp each), then a byte at a time.
    var prefix: usize = 0;
    while (prefix + block <= shortest and std.mem.eql(u8, ref[prefix..][0..block], new[prefix..][0..block])) prefix += block;
    while (prefix < shortest and ref[prefix] == new[prefix]) prefix += 1;
    var suffix: usize = 0;
    while (suffix + block <= shortest - prefix and std.mem.eql(u8, ref[ref.len - suffix - block ..][0..block], new[new.len - suffix - block ..][0..block])) suffix += block;
    while (suffix < shortest - prefix and ref[ref.len - 1 - suffix] == new[new.len - 1 - suffix]) suffix += 1;
    const a = ref[prefix .. ref.len - suffix];
    const b = new[prefix .. new.len - suffix];

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    write(w, new.len, prefix, suffix) catch return error.OutOfMemory;
    if (a.len != b.len) {
        w.writeByte(@intFromEnum(Mode.raw)) catch return error.OutOfMemory;
        w.writeAll(b) catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }
    w.writeByte(@intFromEnum(Mode.runs)) catch return error.OutOfMemory;
    // Runs of differing blocks, found in one pass and kept so their count can lead them.
    var runs: std.ArrayList(Run) = .empty;
    defer runs.deinit(gpa);
    var it: Runs = .{ .a = a, .b = b };
    while (it.next()) |r| try runs.append(gpa, r);
    w.writeUleb128(runs.items.len) catch return error.OutOfMemory;
    var end: usize = 0;
    for (runs.items) |r| {
        w.writeUleb128(r.start - end) catch return error.OutOfMemory;
        w.writeUleb128(r.len) catch return error.OutOfMemory;
        w.writeAll(b[r.start..][0..r.len]) catch return error.OutOfMemory;
        end = r.start + r.len;
    }
    return out.toOwnedSlice();
}

fn write(w: *std.Io.Writer, len: usize, prefix: usize, suffix: usize) !void {
    try w.writeUleb128(len);
    try w.writeUleb128(prefix);
    try w.writeUleb128(suffix);
}

const Run = struct { start: usize, len: usize };

/// The runs of `block`-byte blocks where `a` and `b`, of one length, differ.
const Runs = struct {
    a: []const u8,
    b: []const u8,
    at: usize = 0,

    fn next(self: *Runs) ?Run {
        while (self.at < self.a.len and self.same(self.at)) self.at += block;
        if (self.at >= self.a.len) return null;
        const start = self.at;
        while (self.at < self.a.len and !self.same(self.at)) self.at += block;
        return .{ .start = start, .len = @min(self.at, self.a.len) - start };
    }

    fn same(self: *const Runs, at: usize) bool {
        const n = @min(block, self.a.len - at);
        return std.mem.eql(u8, self.a[at..][0..n], self.b[at..][0..n]);
    }
};

/// The state `delta` stands for against `ref`, allocated with `gpa`. A delta that does not fit
/// `ref` is `error.BadDelta`.
pub fn apply(gpa: std.mem.Allocator, ref: []const u8, delta: []const u8) Error![]u8 {
    var r: std.Io.Reader = .fixed(delta);
    const len = take(&r) catch return error.BadDelta;
    const prefix = take(&r) catch return error.BadDelta;
    const suffix = take(&r) catch return error.BadDelta;
    if (prefix > ref.len or suffix > ref.len - prefix or prefix > len or suffix > len - prefix) return error.BadDelta;
    const mode = std.enums.fromInt(Mode, r.takeByte() catch return error.BadDelta) orelse return error.BadDelta;
    const middle = len - prefix - suffix;
    const out = try gpa.alloc(u8, len);
    errdefer gpa.free(out);
    @memcpy(out[0..prefix], ref[0..prefix]);
    @memcpy(out[len - suffix ..], ref[ref.len - suffix ..]);
    switch (mode) {
        .raw => {
            const bytes = r.take(middle) catch return error.BadDelta;
            @memcpy(out[prefix..][0..middle], bytes);
        },
        .runs => {
            if (ref.len != len) return error.BadDelta;
            @memcpy(out[prefix..][0..middle], ref[prefix..][0..middle]);
            const n = take(&r) catch return error.BadDelta;
            var end: usize = 0;
            for (0..n) |_| {
                const gap = take(&r) catch return error.BadDelta;
                const run = take(&r) catch return error.BadDelta;
                if (gap > middle - end or run > middle - end - gap) return error.BadDelta;
                const bytes = r.take(run) catch return error.BadDelta;
                @memcpy(out[prefix + end + gap ..][0..run], bytes);
                end += gap + run;
            }
        },
    }
    if (r.seek != delta.len) return error.BadDelta;
    return out;
}

fn take(r: *std.Io.Reader) !usize {
    return r.takeLeb128(usize);
}

// ---- tests ---------------------------------------------------------------------------------

const testing = std.testing;

fn roundTrip(ref: []const u8, new: []const u8) !usize {
    const d = try encode(testing.allocator, ref, new);
    defer testing.allocator.free(d);
    const back = try apply(testing.allocator, ref, d);
    defer testing.allocator.free(back);
    try testing.expectEqualSlices(u8, new, back);
    return d.len;
}

test "an edit in one place is a delta of about its size" {
    var ref: [64 << 10]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(0xde17a);
    prng.random().bytes(&ref);
    var new = ref;
    @memcpy(new[30_000..][0..20], "twenty bytes changed");
    try testing.expect(try roundTrip(&ref, &new) < 64);
    // Nothing changed: next to nothing.
    try testing.expect(try roundTrip(&ref, &ref) < 16);
}

test "text inserted shifts what follows, and the delta is still the part between the edits" {
    const ref = "fn main() void {\n    std.debug.print(\"hello\", .{});\n}\n" ** 100;
    const new = ref[0..2000] ++ "// inserted\n" ++ ref[2000..];
    const size = try roundTrip(ref, new);
    try testing.expect(size < 32);
    // Two edits far apart, lengths differing: the middle between them, kept as it is.
    const two = ref[0..100] ++ "x" ++ ref[100..5000] ++ "y" ++ ref[5000..];
    try testing.expect(try roundTrip(ref, two) < 5000);
}

test "changes far apart on a canvas are a few runs, not the span between them" {
    var ref: [1 << 20]u8 = @splat(0);
    var new = ref;
    for ([_]usize{ 1000, 400_000, 900_000 }) |at| @memset(new[at..][0..30], 0xff);
    try testing.expect(try roundTrip(&ref, &new) < 4 * block * 2);
}

test "growing, shrinking, emptying and starting from nothing" {
    _ = try roundTrip("", "");
    _ = try roundTrip("", "abc");
    _ = try roundTrip("abc", "");
    _ = try roundTrip("abc", "abcdef");
    _ = try roundTrip("abcdef", "abc");
    _ = try roundTrip("aaaa", "aa");
    _ = try roundTrip("xabcx", "xx");
}

test "random edits round-trip" {
    var prng: std.Random.DefaultPrng = .init(0x5ea1);
    const r = prng.random();
    var ref: [4096]u8 = undefined;
    r.bytes(&ref);
    for (0..500) |_| {
        var new: std.ArrayList(u8) = .empty;
        defer new.deinit(testing.allocator);
        try new.appendSlice(testing.allocator, &ref);
        for (0..1 + r.uintLessThan(usize, 4)) |_| {
            const at = r.uintLessThan(usize, new.items.len + 1);
            switch (r.uintLessThan(u8, 3)) {
                0 => try new.insertSlice(testing.allocator, at, "inserted"),
                1 => new.replaceRangeAssumeCapacity(at, @min(16, new.items.len - at), ""),
                else => if (at < new.items.len) {
                    new.items[at] +%= 1;
                },
            }
        }
        _ = try roundTrip(&ref, new.items);
    }
}

test "a damaged delta is an error, never a crash" {
    var ref: [2048]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(0xbad);
    const r = prng.random();
    r.bytes(&ref);
    var new = ref;
    @memset(new[100..][0..40], 1);
    @memset(new[1500..][0..40], 2);
    const d = try encode(testing.allocator, &ref, &new);
    defer testing.allocator.free(d);
    for (0..d.len) |n| if (apply(testing.allocator, &ref, d[0..n])) |got| {
        testing.allocator.free(got);
        return error.TestUnexpectedResult;
    } else |err| try testing.expectEqual(error.BadDelta, err);
    const copy = try testing.allocator.dupe(u8, d);
    defer testing.allocator.free(copy);
    for (0..4000) |_| {
        @memcpy(copy, d);
        copy[r.uintLessThan(usize, copy.len)] ^= @as(u8, 1) << r.int(u3);
        if (apply(testing.allocator, &ref, copy)) |got| testing.allocator.free(got) else |_| {}
    }
    // Against the wrong reference: refused rather than misread where it can tell.
    try testing.expectError(error.BadDelta, apply(testing.allocator, ref[0..100], d));
}
