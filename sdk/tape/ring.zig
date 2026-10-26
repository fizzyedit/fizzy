//! A recorder's rings: the last stretch of a run, frame by frame, for almost nothing, written out
//! as a file that reads back in place (plans/RECORDER_PLAN.md). Any stream of fixed records stamped
//! to frames: a dvui app's events (`events`), a game's inputs at its own tick, a plugin's own.
//!
//! `Ring(Frame, Record, caps)` holds three fixed rings: the last `caps.frames` frames, the last
//! `caps.records` records, the last `caps.bytes` bytes of the records' payloads (typed text, a
//! selection's offsets, whatever a record carries that does not fit it). Every frame, record and
//! byte is numbered by its sequence from the recorder's start, so a stretch of the run is a range
//! of numbers and a frame names its records by theirs. Appending is a copy into the next slot, no
//! allocation; a reader asks for a range and is told when the rings have already moved past it.
//!
//! What the two types must have, as `extern` structs:
//!
//! - `Frame`: `t_ns: i64` (the frame's time on the run's clock, so a replay's clock can say it),
//!   `first: u64` and `count: u32` (its records). Anything else is the stream's: a dvui window's
//!   size, a game's tick length.
//! - `Record`: `bytes_at: u64` and `bytes_len: u32` (its payload, set by the ring). Optionally
//!   `pub fn valid(self) bool`, which `read` asks of every record a file holds.
//!
//! A stretch written out (`write`) is a header and the three arrays as they are in memory,
//! little-endian: reading one back is a bounds check and a cast (`read`). The header names the
//! stream and its record sizes, so captures holding several streams (fizzy's input beside a
//! game's) never mistake one for another.
//!
//! Going back in a run, a game's rewind or a capture's replay, is this plus the state it starts
//! from: put back the nearest state kept (`replay.Stage.restore`), then feed each frame's records
//! from there. The ring keeps the input; what the state is stays the app's.
const std = @import("std");
const builtin = @import("builtin");

pub const Caps = struct {
    frames: u32,
    records: u32,
    bytes: u32,
};

pub const magic = "FZRG";
pub const version: u32 = 1;

pub const Header = extern struct {
    magic: [4]u8 = magic.*,
    version: u32 = version,
    /// Which stream: `events.stream` for a dvui app's input, a game's own name for its.
    stream: [8]u8,
    frame_size: u16,
    record_size: u16,
    /// The frames written, the records they name, the payload bytes those name.
    frames: u32,
    records: u32,
    bytes: u32,
    /// The first frame's sequence in the run, so a capture's frames keep their numbers.
    first_frame: u64,
};

comptime {
    std.debug.assert(@sizeOf(Header) == 40);
}

pub const ReadError = error{ NotARecording, UnknownVersion, OtherStream, Truncated, BadIndex };

/// The stream name as the header holds it: up to eight bytes, zero-padded.
pub fn streamName(comptime name: []const u8) [8]u8 {
    if (name.len > 8) @compileError("a stream's name is at most 8 bytes: " ++ name);
    var out: [8]u8 = @splat(0);
    @memcpy(out[0..name.len], name);
    return out;
}

/// What a file holds, read without knowing its stream (to list a capture's streams).
pub fn header(bytes: []const u8) ReadError!Header {
    if (bytes.len < @sizeOf(Header)) return error.Truncated;
    const h = std.mem.bytesToValue(Header, bytes[0..@sizeOf(Header)]);
    if (!std.mem.eql(u8, &h.magic, magic)) return error.NotARecording;
    if (h.version != version) return error.UnknownVersion;
    return h;
}

pub fn Ring(comptime name: []const u8, comptime Frame: type, comptime Record: type, comptime caps: Caps) type {
    comptime {
        for (.{ "t_ns", "first", "count" }) |f|
            if (!@hasField(Frame, f)) @compileError(@typeName(Frame) ++ " has no `" ++ f ++ "`");
        for (.{ "bytes_at", "bytes_len" }) |f|
            if (!@hasField(Record, f)) @compileError(@typeName(Record) ++ " has no `" ++ f ++ "`");
    }
    return struct {
        const Self = @This();

        pub const stream = streamName(name);
        pub const frames_cap = caps.frames;
        pub const records_cap = caps.records;
        pub const bytes_cap = caps.bytes;

        frames: [caps.frames]Frame = undefined,
        records: [caps.records]Record = undefined,
        bytes: [caps.bytes]u8 = undefined,
        /// How many of each were ever appended: the next one's sequence number.
        frames_n: u64 = 0,
        records_n: u64 = 0,
        bytes_n: u64 = 0,

        /// Append this frame's records, then the frame naming them. `payloads[i]` is record `i`'s
        /// bytes (the caller's, copied here; empty for none, and missing past the slice's end);
        /// its `bytes_at` and `bytes_len` are set from where they land.
        pub fn appendFrame(self: *Self, fr: Frame, records: []const Record, payloads: []const []const u8) void {
            const first = self.records_n;
            for (records, 0..) |r, i| {
                var rec = r;
                rec.bytes_at = 0;
                rec.bytes_len = 0;
                if (i < payloads.len and payloads[i].len > 0) {
                    // A payload longer than the whole byte ring keeps its tail.
                    const p = payloads[i];
                    const keep = p[p.len - @min(p.len, caps.bytes) ..];
                    rec.bytes_at = self.bytes_n;
                    rec.bytes_len = @intCast(keep.len);
                    for (keep) |b| {
                        self.bytes[@intCast(self.bytes_n % caps.bytes)] = b;
                        self.bytes_n += 1;
                    }
                }
                self.records[@intCast(self.records_n % caps.records)] = rec;
                self.records_n += 1;
            }
            var f = fr;
            f.first = first;
            f.count = @intCast(records.len);
            self.frames[@intCast(self.frames_n % caps.frames)] = f;
            self.frames_n += 1;
        }

        pub fn frame(self: *const Self, seq: u64) Frame {
            return self.frames[@intCast(seq % caps.frames)];
        }

        /// The oldest frame from which every frame is whole: their records and payloads all still
        /// in the rings. (A frame with no payload can outlive a later one whose bytes are gone.)
        pub fn oldestWhole(self: *const Self) u64 {
            var oldest = self.frames_n -| caps.frames;
            var f = oldest;
            while (f < self.frames_n) : (f += 1) {
                const fr = self.frame(f);
                var whole = fr.first >= self.records_n -| caps.records;
                if (whole) for (0..fr.count) |k| {
                    const r = self.records[@intCast((fr.first + k) % caps.records)];
                    if (r.bytes_len > 0 and r.bytes_at < self.bytes_n -| caps.bytes) whole = false;
                };
                if (!whole) oldest = f + 1;
            }
            return oldest;
        }

        /// The first frame at or after `t_ns` that is still whole, or `frames_n` if none.
        pub fn frameAt(self: *const Self, t_ns: i64) u64 {
            var f = self.oldestWhole();
            while (f < self.frames_n) : (f += 1) {
                if (self.frame(f).t_ns >= t_ns) return f;
            }
            return self.frames_n;
        }

        /// Frames `from` up to (not including) `to`, their records and payloads, as one file: the
        /// header and the three arrays, the records' `first` and `bytes_at` rebased to the file's.
        pub fn write(self: *const Self, w: *std.Io.Writer, from: u64, to: u64) !void {
            std.debug.assert(builtin.target.cpu.arch.endian() == .little);
            const lo = @max(from, self.oldestWhole());
            const hi = @min(to, self.frames_n);
            var n_records: u64 = 0;
            var n_bytes: u64 = 0;
            var f = lo;
            while (f < hi) : (f += 1) {
                const fr = self.frame(f);
                n_records += fr.count;
                for (0..fr.count) |k| n_bytes += self.records[@intCast((fr.first + k) % caps.records)].bytes_len;
            }
            try w.writeStruct(Header{
                .stream = stream,
                .frame_size = @sizeOf(Frame),
                .record_size = @sizeOf(Record),
                .frames = @intCast(hi -| lo),
                .records = @intCast(n_records),
                .bytes = @intCast(n_bytes),
                .first_frame = lo,
            }, .little);
            // Frames, each naming its records from the file's first.
            var rc: u64 = 0;
            f = lo;
            while (f < hi) : (f += 1) {
                var fr = self.frame(f);
                fr.first = rc;
                rc += fr.count;
                try w.writeStruct(fr, .little);
            }
            // Records, each naming its payload from the file's first byte.
            var by: u64 = 0;
            f = lo;
            while (f < hi) : (f += 1) {
                const fr = self.frame(f);
                for (0..fr.count) |k| {
                    var r = self.records[@intCast((fr.first + k) % caps.records)];
                    if (r.bytes_len > 0) {
                        r.bytes_at = by;
                        by += r.bytes_len;
                    }
                    try w.writeStruct(r, .little);
                }
            }
            f = lo;
            while (f < hi) : (f += 1) {
                const fr = self.frame(f);
                for (0..fr.count) |k| {
                    const r = self.records[@intCast((fr.first + k) % caps.records)];
                    var b: u64 = 0;
                    while (b < r.bytes_len) : (b += 1)
                        try w.writeByte(self.bytes[@intCast((r.bytes_at + b) % caps.bytes)]);
                }
            }
        }

        /// The last `ns` of the run (all it kept, if less). How many frames went out.
        pub fn writeLast(self: *const Self, w: *std.Io.Writer, ns: i64) !u64 {
            if (self.frames_n == 0) {
                try writeEmpty(w);
                return 0;
            }
            const from = self.frameAt(self.frame(self.frames_n - 1).t_ns - ns);
            try self.write(w, from, self.frames_n);
            return self.frames_n - @max(from, self.oldestWhole());
        }

        /// A stretch of nothing: what a capture holds when nothing was recorded.
        pub fn writeEmpty(w: *std.Io.Writer) !void {
            try w.writeStruct(
                Header{
                    .stream = stream,
                    .frame_size = @sizeOf(Frame),
                    .record_size = @sizeOf(Record),
                    .frames = 0,
                    .records = 0,
                    .bytes = 0,
                    .first_frame = 0,
                },
                .little,
            );
        }

        /// A file `write` made, read in place: its arrays are views into the bytes, checked to fit.
        pub const Stretch = struct {
            header: Header,
            frames: []align(1) const Frame,
            records: []align(1) const Record,
            bytes: []const u8,

            /// Frame `i`'s records.
            pub fn recordsOf(self: Stretch, i: usize) []align(1) const Record {
                const f = self.frames[i];
                return self.records[@intCast(f.first)..][0..f.count];
            }

            /// A record's payload.
            pub fn payload(self: Stretch, r: Record) []const u8 {
                return self.bytes[@intCast(r.bytes_at)..][0..r.bytes_len];
            }
        };

        pub fn read(bytes: []const u8) ReadError!Stretch {
            const h = try header(bytes);
            if (!std.mem.eql(u8, &h.stream, &stream) or
                h.frame_size != @sizeOf(Frame) or h.record_size != @sizeOf(Record))
                return error.OtherStream;
            const frames_bytes = @as(usize, h.frames) * @sizeOf(Frame);
            const records_bytes = @as(usize, h.records) * @sizeOf(Record);
            if (bytes.len < @sizeOf(Header) + frames_bytes + records_bytes + h.bytes) return error.Truncated;
            var at: usize = @sizeOf(Header);
            const frames = std.mem.bytesAsSlice(Frame, bytes[at..][0..frames_bytes]);
            at += frames_bytes;
            const records = std.mem.bytesAsSlice(Record, bytes[at..][0..records_bytes]);
            at += records_bytes;
            const payloads = bytes[at..][0..h.bytes];
            // Every index in range, so a reader never checks again.
            for (frames) |fr| if (fr.first + fr.count > records.len) return error.BadIndex;
            for (records) |r| {
                if (r.bytes_at + r.bytes_len > payloads.len) return error.BadIndex;
                if (@hasDecl(Record, "valid") and !r.valid()) return error.BadIndex;
            }
            return .{ .header = h, .frames = frames, .records = records, .bytes = payloads };
        }
    };
}

const TestFrame = extern struct { t_ns: i64, first: u64 = 0, count: u32 = 0, tick: u32 = 0 };
const TestRecord = extern struct {
    button: u32,
    _pad: u32 = 0,
    bytes_at: u64 = 0,
    bytes_len: u32 = 0,
    _pad1: u32 = 0,
    pub fn valid(self: TestRecord) bool {
        return self.button < 16;
    }
};
const TestRing = Ring("pad", TestFrame, TestRecord, .{ .frames = 64, .records = 128, .bytes = 256 });

test "a stream of its own: frames keep their records and payloads, and a stretch reads back" {
    const ring = try std.testing.allocator.create(TestRing);
    defer std.testing.allocator.destroy(ring);
    ring.* = .{};
    ring.appendFrame(.{ .t_ns = 10, .tick = 1 }, &.{}, &.{});
    ring.appendFrame(.{ .t_ns = 20, .tick = 2 }, &.{ .{ .button = 3 }, .{ .button = 4 } }, &.{ "", "axes" });
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try ring.write(&out.writer, 0, ring.frames_n);
    const s = try TestRing.read(out.written());
    try std.testing.expectEqual(@as(usize, 2), s.frames.len);
    try std.testing.expectEqual(@as(u32, 2), s.frames[1].tick);
    try std.testing.expectEqualStrings("axes", s.payload(s.recordsOf(1)[1]));
    try std.testing.expectEqual(@as(u32, 0), s.recordsOf(1)[0].bytes_len);
    // Another stream's file is refused, and a record the stream calls invalid is too.
    const Other = Ring("other", TestFrame, TestRecord, .{ .frames = 4, .records = 4, .bytes = 4 });
    try std.testing.expectError(error.OtherStream, Other.read(out.written()));
    const bad = try std.testing.allocator.dupe(u8, out.written());
    defer std.testing.allocator.free(bad);
    bad[@sizeOf(Header) + 2 * @sizeOf(TestFrame)] = 99;
    try std.testing.expectError(error.BadIndex, TestRing.read(bad));
}

test "the rings keep the newest, and a stretch starts at the oldest frame still whole" {
    const ring = try std.testing.allocator.create(TestRing);
    defer std.testing.allocator.destroy(ring);
    ring.* = .{};
    // More frames than the ring holds, each with one record.
    for (0..TestRing.frames_cap + 10) |i| ring.appendFrame(
        .{ .t_ns = @intCast(i) },
        &.{.{ .button = @intCast(i % 16) }},
        &.{},
    );
    try std.testing.expectEqual(@as(u64, 10), ring.oldestWhole());
    // Payloads outrunning their ring: a frame whose bytes were overwritten is not whole.
    for (0..8) |_| ring.appendFrame(.{ .t_ns = 100 }, &.{.{ .button = 1 }}, &.{&@as([64]u8, @splat('x'))});
    const oldest = ring.frame(ring.oldestWhole());
    const r = ring.records[@intCast(oldest.first % TestRing.records_cap)];
    try std.testing.expect(r.bytes_at >= ring.bytes_n - TestRing.bytes_cap);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectEqual(@as(u64, 4), try ring.writeLast(&out.writer, 0));
}

test "a file that lies about its sizes is refused" {
    try std.testing.expectError(error.Truncated, TestRing.read("FZR"));
    var bad: [@sizeOf(Header)]u8 = std.mem.toBytes(Header{
        .stream = TestRing.stream,
        .frame_size = @sizeOf(TestFrame),
        .record_size = @sizeOf(TestRecord),
        .frames = 5,
        .records = 0,
        .bytes = 0,
        .first_frame = 0,
    });
    try std.testing.expectError(error.Truncated, TestRing.read(&bad));
    bad[0] = 'X';
    try std.testing.expectError(error.NotARecording, TestRing.read(&bad));
}
