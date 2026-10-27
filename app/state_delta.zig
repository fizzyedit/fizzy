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
    var enc: Encoder = .init(gpa, ref, new);
    defer enc.deinit();
    var budget: usize = std.math.maxInt(usize);
    _ = try enc.step(&budget);
    return enc.finish();
}

/// `encode` in slices: `step` compares and writes a bounded number of bytes and returns, so a
/// caller with a frame to keep spreads a big document over several. Run to completion it is
/// `encode`, byte for byte. `ref` and `new` are borrowed, and must not change until `finish` or
/// `deinit`.
pub const Encoder = struct {
    gpa: std.mem.Allocator,
    ref: []const u8,
    new: []const u8,
    phase: enum { prefix, suffix, runs, header, body, done } = .prefix,
    prefix: usize = 0,
    suffix: usize = 0,
    /// The middles of `ref` and `new` once the prefix and suffix are known.
    it: Runs = .{ .a = &.{}, .b = &.{} },
    runs: std.ArrayList(Run) = .empty,
    /// Where the last run in `runs` ends, and the encoded size of all of them, kept as they are
    /// found so the header knows the delta's exact length without another pass.
    runs_end: usize = 0,
    runs_len: usize = 0,
    /// The delta so far, allocated at its exact final length by the header.
    out: std.ArrayList(u8) = .empty,
    /// Where the body is up to: the run, and the byte of its bytes (of the middle, when raw).
    out_run: usize = 0,
    out_at: usize = 0,

    pub fn init(gpa: std.mem.Allocator, ref: []const u8, new: []const u8) Encoder {
        return .{ .gpa = gpa, .ref = ref, .new = new };
    }

    pub fn deinit(self: *Encoder) void {
        self.runs.deinit(self.gpa);
        self.out.deinit(self.gpa);
    }

    /// Compare and write on, spending `budget` bytes (comparing may overspend by up to a block).
    /// Returns whether the delta is complete and `finish` can be called.
    pub fn step(self: *Encoder, budget: *usize) std.mem.Allocator.Error!bool {
        const ref = self.ref;
        const new = self.new;
        const shortest = @min(ref.len, new.len);
        // A block at a time while they agree (a memcmp each), then a byte at a time.
        if (self.phase == .prefix) {
            while (self.prefix + block <= shortest) {
                if (budget.* == 0) return false;
                if (!std.mem.eql(u8, ref[self.prefix..][0..block], new[self.prefix..][0..block])) break;
                self.prefix += block;
                budget.* -|= block;
            }
            while (self.prefix < shortest and ref[self.prefix] == new[self.prefix]) self.prefix += 1;
            self.phase = .suffix;
        }
        if (self.phase == .suffix) {
            const room = shortest - self.prefix;
            while (self.suffix + block <= room) {
                if (budget.* == 0) return false;
                if (!std.mem.eql(u8, ref[ref.len - self.suffix - block ..][0..block], new[new.len - self.suffix - block ..][0..block])) break;
                self.suffix += block;
                budget.* -|= block;
            }
            while (self.suffix < room and ref[ref.len - 1 - self.suffix] == new[new.len - 1 - self.suffix]) self.suffix += 1;
            self.it = .{ .a = ref[self.prefix .. ref.len - self.suffix], .b = new[self.prefix .. new.len - self.suffix] };
            self.phase = if (self.it.a.len != self.it.b.len) .header else .runs;
        }
        if (self.phase == .runs) {
            // Runs of differing blocks, found in one pass and kept so their count can lead them.
            while (true) switch (self.it.next(budget)) {
                .run => |r| {
                    try self.runs.append(self.gpa, r);
                    self.runs_len += ulebLen(r.start - self.runs_end) + ulebLen(r.len) + r.len;
                    self.runs_end = r.start + r.len;
                },
                .paused => return false,
                .done => break,
            };
            self.phase = .header;
        }
        if (self.phase == .header) {
            try self.writeHeader();
            self.phase = .body;
        }
        if (self.phase == .body) {
            if (!self.writeBody(budget)) return false;
            self.phase = .done;
        }
        return true;
    }

    /// The delta, owned by `gpa`; `step` has returned true. Hands over the buffer the header sized,
    /// with no copy. The encoder stays valid for `deinit`.
    pub fn finish(self: *Encoder) []u8 {
        std.debug.assert(self.phase == .done);
        std.debug.assert(self.out.items.len == self.out.capacity);
        const delta = self.out.items;
        self.out = .empty;
        return delta;
    }

    fn put(self: *Encoder, n: usize) void {
        var buf: [10]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        w.writeUleb128(n) catch unreachable;
        self.out.appendSliceAssumeCapacity(w.buffered());
    }

    /// Allocate the delta at its exact length, then write the counts and the mode.
    fn writeHeader(self: *Encoder) std.mem.Allocator.Error!void {
        const raw = self.it.a.len != self.it.b.len;
        var len = ulebLen(self.new.len) + ulebLen(self.prefix) + ulebLen(self.suffix) + 1;
        len += if (raw) self.it.b.len else ulebLen(self.runs.items.len) + self.runs_len;
        try self.out.ensureTotalCapacityPrecise(self.gpa, len);
        self.put(self.new.len);
        self.put(self.prefix);
        self.put(self.suffix);
        self.out.appendAssumeCapacity(@backingInt(if (raw) Mode.raw else Mode.runs));
        if (!raw) self.put(self.runs.items.len);
    }

    /// Copy the middle's bytes on, at most `budget` of them; whether all are written.
    fn writeBody(self: *Encoder, budget: *usize) bool {
        const b = self.it.b;
        if (self.it.a.len != b.len) {
            const n = @min(budget.*, b.len - self.out_at);
            self.out.appendSliceAssumeCapacity(b[self.out_at..][0..n]);
            self.out_at += n;
            budget.* -= n;
            return self.out_at == b.len;
        }
        while (self.out_run < self.runs.items.len) {
            if (budget.* == 0) return false;
            const r = self.runs.items[self.out_run];
            if (self.out_at == 0) {
                var end: usize = 0;
                if (self.out_run > 0) {
                    const last = self.runs.items[self.out_run - 1];
                    end = last.start + last.len;
                }
                self.put(r.start - end);
                self.put(r.len);
            }
            const n = @min(budget.*, r.len - self.out_at);
            self.out.appendSliceAssumeCapacity(b[r.start + self.out_at ..][0..n]);
            self.out_at += n;
            budget.* -= n;
            if (self.out_at < r.len) return false;
            self.out_run += 1;
            self.out_at = 0;
        }
        return true;
    }
};

const Run = struct { start: usize, len: usize };

/// The bytes LEB128 takes for `n`.
fn ulebLen(n: usize) usize {
    return @max(1, (@bitSizeOf(usize) - @clz(n) + 6) / 7);
}

/// The runs of `block`-byte blocks where `a` and `b`, of one length, differ.
const Runs = struct {
    a: []const u8,
    b: []const u8,
    at: usize = 0,
    /// Where the run being walked began.
    start: ?usize = null,

    const Next = union(enum) { run: Run, paused, done };

    /// The next run, comparing at most `budget` more bytes: `paused` when it ran out first.
    fn next(self: *Runs, budget: *usize) Next {
        while (self.at < self.a.len) {
            if (budget.* == 0) return .paused;
            budget.* -|= block;
            const equal = self.same(self.at);
            const at = self.at;
            self.at += block;
            if (self.start) |s| {
                if (equal) {
                    self.start = null;
                    return .{ .run = .{ .start = s, .len = at - s } };
                }
            } else if (!equal) self.start = at;
        }
        const s = self.start orelse return .done;
        self.start = null;
        return .{ .run = .{ .start = s, .len = self.a.len - s } };
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
    const line = "fn main() void {\n    std.debug.print(\"hello\", .{});\n}\n";
    const ref: *const [line.len * 100]u8 = comptime blk: {
        var buf: [line.len * 100]u8 = undefined;
        for (0..100) |i| buf[i * line.len ..][0..line.len].* = line.*;
        const out = buf;
        break :blk &out;
    };
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

test "an encoder given a few bytes at a time makes the delta encode does" {
    var prng: std.Random.DefaultPrng = .init(0x511ce);
    const r = prng.random();
    var ref: [8192]u8 = undefined;
    r.bytes(&ref);
    for (0..300) |_| {
        var new: std.ArrayList(u8) = .empty;
        defer new.deinit(testing.allocator);
        try new.appendSlice(testing.allocator, &ref);
        for (0..r.uintLessThan(usize, 5)) |_| {
            const at = r.uintLessThan(usize, new.items.len + 1);
            switch (r.uintLessThan(u8, 3)) {
                0 => try new.insertSlice(testing.allocator, at, "inserted"),
                1 => new.replaceRangeAssumeCapacity(at, @min(300, new.items.len - at), ""),
                else => if (at < new.items.len) @memset(new.items[at..@min(new.items.len, at + 200)], 7),
            }
        }
        const whole = try encode(testing.allocator, &ref, new.items);
        defer testing.allocator.free(whole);
        for ([_]usize{ 1, block, 100, 1000, 5000 }) |slice| {
            var enc: Encoder = .init(testing.allocator, &ref, new.items);
            defer enc.deinit();
            var steps: usize = 0;
            while (true) : (steps += 1) {
                var budget = slice;
                if (try enc.step(&budget)) break;
                // Never more than a block over what it was given.
                try testing.expect(budget <= slice);
            }
            const sliced = enc.finish();
            defer testing.allocator.free(sliced);
            try testing.expectEqualSlices(u8, whole, sliced);
            if (slice == 1 and new.items.len >= 4 * block) try testing.expect(steps > 1);
        }
    }
}

test "a step writes no more than its budget, however much differs" {
    const size = 1 << 20;
    const slice = 4096;
    const ref = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(ref);
    @memset(ref, 0);
    // Every other block changed (dense runs), and the same bytes with one inserted (a raw middle).
    const dense = try testing.allocator.dupe(u8, ref);
    defer testing.allocator.free(dense);
    var at: usize = 0;
    while (at < size) : (at += 2 * block) @memset(dense[at..][0..block], 1);
    const shifted = try testing.allocator.alloc(u8, size + 1);
    defer testing.allocator.free(shifted);
    @memset(shifted, 1);
    for ([_][]const u8{ dense, shifted }) |new| {
        var counting: std.testing.FailingAllocator = .init(testing.allocator, .{});
        var enc: Encoder = .init(counting.allocator(), ref, new);
        defer enc.deinit();
        var steps: usize = 0;
        while (true) : (steps += 1) {
            const before = enc.out.items.len;
            var budget: usize = slice;
            const done = try enc.step(&budget);
            // The bytes copied are the budget; the rest is a run's two counts.
            try testing.expect(enc.out.items.len - before <= slice + slice / block * 20 + 64);
            if (done) break;
        }
        try testing.expect(steps >= size / slice / 2);
        const whole = try encode(testing.allocator, ref, new);
        defer testing.allocator.free(whole);
        // The header sized the delta exactly, so handing it over allocates, copies and resizes nothing.
        const calls = .{ counting.alloc_index, counting.resize_index, counting.allocated_bytes, counting.freed_bytes };
        const sliced = enc.finish();
        defer testing.allocator.free(sliced);
        try testing.expectEqual(calls, .{ counting.alloc_index, counting.resize_index, counting.allocated_bytes, counting.freed_bytes });
        try testing.expectEqual(whole.len, sliced.len);
        try testing.expectEqualSlices(u8, whole, sliced);
    }
}

test "the length ulebLen counts is the length written" {
    var buf: [10]u8 = undefined;
    for ([_]usize{ 0, 1, 127, 128, 16383, 16384, 1 << 21, 1 << 28, 1 << 35, std.math.maxInt(usize) }) |n| {
        var w: std.Io.Writer = .fixed(&buf);
        try w.writeUleb128(n);
        try testing.expectEqual(w.buffered().len, ulebLen(n));
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
