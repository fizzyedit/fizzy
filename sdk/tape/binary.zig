//! The binary form of a tape: what a recording is saved as and a site serves when it is long.
//!
//! ZON (`Tape.parse`, `Tape.write`) is for people — a tape written by hand, a diff in review, a
//! look inside a recording. This is for machines: a load is a bounds check and a copy, not a
//! parse. Both are the same tape, losslessly, and convert either way.
//!
//! **Layout**, little-endian throughout, every section starting on four bytes:
//!
//!   * a header (`Header`): the magic `FZTP`, the version, the tape's name, title and home, and
//!     how many of everything follow;
//!   * the string table: each distinct string once — every anchor, every typed text, every file —
//!     as `count + 1` offsets into the bytes that follow them;
//!   * the blob table, the same shape: each step's effect and motion, in order and never interned
//!     (an effect almost never repeats, and hashing every byte of an hour of them to find out
//!     would cost more than it saves);
//!   * the ops, one fixed-size record each (`op_size` bytes): time, length, kind, and the kind's
//!     payload as string indices and numbers. Fixed size is what lets a reader index op `i`, or
//!     binary-search them by time, without decoding the ones before it;
//!   * the keyframes, their files, opened paths and settings; the captions and what each keeps
//!     clear of; the chapters — the same, in records of their own.
//!
//! **Reading** (`read`) copies the bytes once into the tape's arena, checks every count, offset
//! and index against what is there, and builds the ops over them: every string in the tape is a
//! slice of that one copy, so there is one allocation for the bytes and one per list, never one
//! per string. A truncated or tampered file is an error, never a crash or a read out of bounds.
//!
//! **Deflated** (`Options.deflate`, the header's flag `flag_deflated`): after the magic, version
//! and flags come the length of what would otherwise follow them, then one zlib stream of it. For
//! a recording that is shared — its effects are mostly runs of the same few bytes. Reading
//! inflates it into the one copy, exactly that long, then reads as ever.
//!
//! **Versions.** `version` is bumped for any change a reader of the old one would misread; a
//! reader refuses a version it does not know (`error.UnsupportedVersion`) rather than guess, and
//! reads every older one it does. 2 gave a `command` op its arguments, in the record's second
//! string; a version-1 command has none. 3 added steps, files' owner and format, the blob table
//! and the deflated form.
const std = @import("std");
const flate = std.compress.flate;
const Tape = @import("Tape.zig");

pub const magic = "FZTP".*;
pub const version: u16 = 3;
/// The oldest version `read` still reads.
pub const oldest_version: u16 = 1;

/// Whether `bytes` are a binary tape (rather than ZON, say).
pub fn sniff(bytes: []const u8) bool {
    return bytes.len >= magic.len and std.mem.eql(u8, bytes[0..magic.len], &magic);
}

pub const Header = struct {
    name: u32,
    title: u32,
    home: u32,
    strings: u32,
    string_bytes: u32,
    ops: u32,
    keyframes: u32,
    files: u32,
    open: u32,
    settings: u32,
    captions: u32,
    clear: u32,
    chapters: u32,
    // Version 3 on.
    blobs: u32 = 0,
    blob_bytes: u32 = 0,

    /// How many of its fields a tape of version `v` has on disk.
    fn fields(v: u16) usize {
        return if (v >= 3) std.meta.fields(Header).len else 13;
    }
};
/// What comes before the header: magic, version, flags.
const prefix_size = 4 + 2 + 2;

/// The header's flags.
pub const flag_deflated: u16 = 1 << 0;
const known_flags = flag_deflated;
/// The most a deflated tape inflates to: past it, the stream is taken for corrupt rather than
/// allocated (a few bytes of tampered stream can claim gigabytes).
pub const max_inflated = 256 << 20;

/// The size of each record on disk.
pub const op_size = 36;
const keyframe_size = 32;
/// A file's record: path and text, then from version 3 its owner and format.
fn fileSize(v: u16) usize {
    return if (v >= 3) 16 else 8;
}
const open_size = 4;
const setting_size = 12;
const caption_size = 32;
const clear_size = 4;
const chapter_size = 8;

/// An op's kind on disk. Appended to, never reordered.
const Kind = enum(u8) { keyframe, move, press, release, scroll, key, type, command, wait, trace, step };
/// A wait's condition on disk.
const UntilKind = enum(u8) { idle, shown, gone };

// ---- writing -------------------------------------------------------------------------------

pub const Options = struct {
    /// One zlib stream after the header's flags: smaller, for a tape that is sent somewhere, and
    /// slower to write and read (`zig build bench-tape`).
    deflate: bool = false,
};

/// Write `tape` in the binary form. `gpa` is for the string table while it is built, and for the
/// uncompressed form while it is deflated.
pub fn write(gpa: std.mem.Allocator, tape: Tape, w: *std.Io.Writer, opts: Options) !void {
    try w.writeAll(&magic);
    try w.writeInt(u16, version, .little);
    try w.writeInt(u16, if (opts.deflate) flag_deflated else 0, .little);
    if (!opts.deflate) return writeBody(gpa, tape, w);

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    try writeBody(gpa, tape, &body.writer);
    // The compressor wants room to write into of its own, whatever `w` has.
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 64);
    defer out.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    const c = try gpa.create(flate.Compress);
    defer gpa.destroy(c);
    c.* = try .init(&out.writer, window, .zlib, .default);
    try c.writer.writeAll(body.written());
    try c.finish();
    try w.writeInt(u32, count(body.written().len), .little);
    try w.writeAll(out.written());
}

/// Everything after the flags.
fn writeBody(gpa: std.mem.Allocator, tape: Tape, w: *std.Io.Writer) !void {
    var table: Strings = .{};
    defer table.deinit(gpa);
    var blobs: std.ArrayList([]const u8) = .empty;
    defer blobs.deinit(gpa);
    var blob_bytes: usize = 0;

    // Every string, interned, in the order first met — so the table is deterministic.
    const name = try table.intern(gpa, tape.name);
    const title = try table.intern(gpa, tape.title);
    const home = try table.intern(gpa, tape.home);
    for (tape.ops) |op| switch (op.do) {
        .move, .trace => |m| _ = try table.intern(gpa, m.tag),
        .key, .type => |s| _ = try table.intern(gpa, s),
        .command => |c| {
            _ = try table.intern(gpa, c.id);
            _ = try table.intern(gpa, c.args);
        },
        .wait => |wt| switch (wt.until) {
            .shown, .gone => |s| _ = try table.intern(gpa, s),
            .idle => {},
        },
        .step => |st| {
            _ = try table.intern(gpa, st.file);
            try blobs.appendSlice(gpa, &.{ st.effect, st.motion });
            blob_bytes += st.effect.len + st.motion.len;
        },
        .keyframe, .press, .release, .scroll => {},
    };
    var n_files: u32 = 0;
    var n_open: u32 = 0;
    var n_settings: u32 = 0;
    for (tape.keyframes) |kf| {
        _ = try table.intern(gpa, kf.root);
        for (kf.files) |f| {
            _ = try table.intern(gpa, f.path);
            _ = try table.intern(gpa, f.text);
            _ = try table.intern(gpa, f.owner);
        }
        for (kf.open) |o| _ = try table.intern(gpa, o);
        for (kf.settings) |s| {
            _ = try table.intern(gpa, s.owner);
            _ = try table.intern(gpa, s.key);
            _ = try table.intern(gpa, s.value);
        }
        n_files += count(kf.files.len);
        n_open += count(kf.open.len);
        n_settings += count(kf.settings.len);
    }
    var n_clear: u32 = 0;
    for (tape.captions) |c| {
        _ = try table.intern(gpa, c.title);
        _ = try table.intern(gpa, c.text);
        _ = try table.intern(gpa, c.near);
        for (c.clear) |t| _ = try table.intern(gpa, t);
        n_clear += count(c.clear.len);
    }
    for (tape.chapters) |c| _ = try table.intern(gpa, c.title);

    const h: Header = .{
        .name = name,
        .title = title,
        .home = home,
        .strings = count(table.list.items.len),
        .string_bytes = count(table.bytes),
        .ops = count(tape.ops.len),
        .keyframes = count(tape.keyframes.len),
        .files = n_files,
        .open = n_open,
        .settings = n_settings,
        .captions = count(tape.captions.len),
        .clear = n_clear,
        .chapters = count(tape.chapters.len),
        .blobs = count(blobs.items.len),
        .blob_bytes = count(blob_bytes),
    };
    inline for (std.meta.fields(Header)) |f| try w.writeInt(u32, @field(h, f.name), .little);

    try writeTable(w, table.list.items, table.bytes);
    try writeTable(w, blobs.items, blob_bytes);
    // The next blob of each step's, in the order the steps were met above.
    var blob: u32 = 0;

    for (tape.ops) |op| {
        var kind: Kind = undefined;
        var small: u8 = 0;
        var a: u32 = 0;
        var b: u32 = 0;
        // The record's last four words: a pointer's floats, bit for bit, or a step's motion.
        var xy: [4]u32 = @splat(0);
        switch (op.do) {
            .keyframe => |i| {
                kind = .keyframe;
                a = i;
            },
            .move, .trace => |m| {
                kind = if (op.do == .move) .move else .trace;
                a = table.index(m.tag);
                xy = .{ @bitCast(m.x), @bitCast(m.y), @bitCast(m.dx), @bitCast(m.dy) };
            },
            .press, .release => |btn| {
                kind = if (op.do == .press) .press else .release;
                small = @intFromEnum(btn);
            },
            .scroll => |s| {
                kind = .scroll;
                xy = .{ @bitCast(s.x), @bitCast(s.y), 0, 0 };
            },
            .key => |s| {
                kind = .key;
                a = table.index(s);
            },
            .type => |s| {
                kind = .type;
                a = table.index(s);
            },
            .command => |c| {
                kind = .command;
                a = table.index(c.id);
                b = table.index(c.args);
            },
            .step => |st| {
                kind = .step;
                a = table.index(st.file);
                b = blob;
                xy[0] = blob + 1;
                blob += 2;
            },
            .wait => |wt| {
                kind = .wait;
                b = wt.timeout;
                switch (wt.until) {
                    .idle => small = @intFromEnum(UntilKind.idle),
                    .shown => |s| {
                        small = @intFromEnum(UntilKind.shown);
                        a = table.index(s);
                    },
                    .gone => |s| {
                        small = @intFromEnum(UntilKind.gone);
                        a = table.index(s);
                    },
                }
            },
        }
        try w.writeInt(u32, op.at, .little);
        try w.writeInt(u32, op.ms, .little);
        try w.writeByte(@intFromEnum(kind));
        try w.writeByte(small);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u32, a, .little);
        try w.writeInt(u32, b, .little);
        for (xy) |v| try w.writeInt(u32, v, .little);
    }

    var files_at: u32 = 0;
    var open_at: u32 = 0;
    var settings_at: u32 = 0;
    for (tape.keyframes) |kf| {
        try w.writeInt(u32, table.index(kf.root), .little);
        try w.writeByte(@intFromEnum(kf.layout));
        try w.splatByteAll(0, 3);
        for ([_]u32{ files_at, count(kf.files.len), open_at, count(kf.open.len), settings_at, count(kf.settings.len) }) |v|
            try w.writeInt(u32, v, .little);
        files_at += count(kf.files.len);
        open_at += count(kf.open.len);
        settings_at += count(kf.settings.len);
    }
    for (tape.keyframes) |kf| for (kf.files) |f| {
        for ([_]u32{ table.index(f.path), table.index(f.text), table.index(f.owner), f.format }) |v|
            try w.writeInt(u32, v, .little);
    };
    for (tape.keyframes) |kf| for (kf.open) |o| try w.writeInt(u32, table.index(o), .little);
    for (tape.keyframes) |kf| for (kf.settings) |s| {
        try w.writeInt(u32, table.index(s.owner), .little);
        try w.writeInt(u32, table.index(s.key), .little);
        try w.writeInt(u32, table.index(s.value), .little);
    };

    var clear_at: u32 = 0;
    for (tape.captions) |c| {
        for ([_]u32{ c.at, c.ms, table.index(c.title), table.index(c.text) }) |v| try w.writeInt(u32, v, .little);
        try w.writeByte(@intFromEnum(c.place));
        try w.splatByteAll(0, 3);
        for ([_]u32{ table.index(c.near), clear_at, count(c.clear.len) }) |v| try w.writeInt(u32, v, .little);
        clear_at += count(c.clear.len);
    }
    for (tape.captions) |c| for (c.clear) |t| try w.writeInt(u32, table.index(t), .little);

    for (tape.chapters) |c| {
        try w.writeInt(u32, c.at, .little);
        try w.writeInt(u32, table.index(c.title), .little);
    }
}

/// A table of `list` as `count + 1` offsets into their `bytes` bytes, then the bytes, padded.
fn writeTable(w: *std.Io.Writer, list: []const []const u8, bytes: usize) !void {
    var at: u32 = 0;
    for (list) |s| {
        try w.writeInt(u32, at, .little);
        at += count(s.len);
    }
    try w.writeInt(u32, at, .little);
    for (list) |s| try w.writeAll(s);
    try w.splatByteAll(0, pad4(bytes));
}

/// `write` into a new allocation.
pub fn encode(gpa: std.mem.Allocator, tape: Tape, opts: Options) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    write(gpa, tape, &out.writer, opts) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    return out.toOwnedSlice();
}

fn count(n: usize) u32 {
    return @intCast(n);
}

fn pad4(n: usize) usize {
    return std.mem.alignForward(usize, n, 4) - n;
}

/// Each distinct string once, by first appearance.
const Strings = struct {
    map: std.StringHashMapUnmanaged(u32) = .empty,
    list: std.ArrayList([]const u8) = .empty,
    bytes: usize = 0,

    fn deinit(self: *Strings, gpa: std.mem.Allocator) void {
        self.map.deinit(gpa);
        self.list.deinit(gpa);
    }

    fn intern(self: *Strings, gpa: std.mem.Allocator, s: []const u8) !u32 {
        const got = try self.map.getOrPut(gpa, s);
        if (!got.found_existing) {
            got.value_ptr.* = count(self.list.items.len);
            try self.list.append(gpa, s);
            self.bytes += s.len;
        }
        return got.value_ptr.*;
    }

    /// A string already interned.
    fn index(self: *const Strings, s: []const u8) u32 {
        return self.map.get(s).?;
    }
};

// ---- reading -------------------------------------------------------------------------------

pub const ReadError = error{
    /// Not a binary tape at all.
    NotATape,
    /// A binary tape of a version this reader does not know.
    UnsupportedVersion,
    /// It ends before what its header says is there.
    Truncated,
    /// What is there does not hold together: an index past its table, an unknown kind.
    Corrupt,
    OutOfMemory,
} || Tape.Error;

/// Read a binary tape. The bytes are copied once into the result's arena and every string in the
/// tape is a slice of that copy; `bytes` can be let go of at once. Checked with `check` as a ZON
/// tape is (`Tape.validate`).
pub fn read(gpa: std.mem.Allocator, bytes: []const u8, check: Tape.Check) ReadError!Tape.Owned {
    if (!sniff(bytes)) return error.NotATape;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var pre: Reader = .{ .bytes = bytes };
    _ = try pre.take(magic.len);
    const tape_version = try pre.int(u16);
    if (tape_version < oldest_version or tape_version > version) return error.UnsupportedVersion;
    const flags = try pre.int(u16);
    if (flags & ~known_flags != 0) return error.Corrupt;
    // The one copy every string and blob of the tape is a slice of.
    const own = if (flags & flag_deflated == 0) try a.dupe(u8, bytes[prefix_size..]) else blk: {
        if (tape_version < 3) return error.Corrupt;
        const len = try pre.int(u32);
        if (len > max_inflated) return error.Corrupt;
        var in_buffer: [4096]u8 = undefined;
        var in: Endless = .init(bytes[prefix_size + 4 ..], &in_buffer);
        const window = try gpa.alloc(u8, flate.max_window_len);
        defer gpa.free(window);
        var d: flate.Decompress = .init(&in.reader, .zlib, window);
        // One byte more than it should come to, so a stream that runs on is caught; a stream cut
        // short runs on into the zeros, or stops early, or fails its checksum.
        const inflated = d.reader.allocRemaining(a, .limited(@as(usize, len) + 1)) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.ReadFailed, error.StreamTooLong => error.Corrupt,
        };
        if (inflated.len != len or d.state != .end) return error.Corrupt;
        // std's inflate reads the stream's checksum and leaves it unchecked.
        if (std.hash.Adler32.hash(inflated) != d.container_metadata.zlib.adler) return error.Corrupt;
        break :blk inflated;
    };
    var r: Reader = .{ .bytes = own };

    var h: Header = std.mem.zeroes(Header);
    inline for (std.meta.fields(Header), 0..) |f, i| {
        if (i < Header.fields(tape_version)) @field(h, f.name) = try r.int(u32);
    }

    const strings = try Table.take(&r, h.strings, h.string_bytes);
    const blobs: Table = if (tape_version >= 3) try Table.take(&r, h.blobs, h.blob_bytes) else .empty;

    const op_bytes = try r.take(try sizeOf(h.ops, op_size));
    const kf_bytes = try r.take(try sizeOf(h.keyframes, keyframe_size));
    const file_size = fileSize(tape_version);
    const file_bytes = try r.take(try sizeOf(h.files, file_size));
    const open_bytes = try r.take(try sizeOf(h.open, open_size));
    const setting_bytes = try r.take(try sizeOf(h.settings, setting_size));
    const caption_bytes = try r.take(try sizeOf(h.captions, caption_size));
    const clear_bytes = try r.take(try sizeOf(h.clear, clear_size));
    const chapter_bytes = try r.take(try sizeOf(h.chapters, chapter_size));

    const ops = try a.alloc(Tape.Op, h.ops);
    for (ops, 0..) |*op, i| {
        var f: Reader = .{ .bytes = op_bytes[i * op_size ..][0..op_size] };
        const at = try f.int(u32);
        const ms = try f.int(u32);
        const kind = std.enums.fromInt(Kind, try f.int(u8)) orelse return error.Corrupt;
        const small = try f.int(u8);
        _ = try f.int(u16);
        const ia = try f.int(u32);
        const ib = try f.int(u32);
        var words: [4]u32 = undefined;
        for (&words) |*v| v.* = try f.int(u32);
        const xy: [4]f32 = @bitCast(words);
        op.* = .{ .at = at, .ms = ms, .do = switch (kind) {
            .keyframe => .{ .keyframe = std.math.cast(u16, ia) orelse return error.Corrupt },
            .move => .{ .move = .{ .tag = try strings.get(ia), .x = xy[0], .y = xy[1], .dx = xy[2], .dy = xy[3] } },
            .trace => .{ .trace = .{ .tag = try strings.get(ia), .x = xy[0], .y = xy[1], .dx = xy[2], .dy = xy[3] } },
            .press => .{ .press = std.enums.fromInt(Tape.Button, small) orelse return error.Corrupt },
            .release => .{ .release = std.enums.fromInt(Tape.Button, small) orelse return error.Corrupt },
            .scroll => .{ .scroll = .{ .x = xy[0], .y = xy[1] } },
            .key => .{ .key = try strings.get(ia) },
            .type => .{ .type = try strings.get(ia) },
            .command => .{ .command = .{
                .id = try strings.get(ia),
                .args = if (tape_version >= 2) try strings.get(ib) else "",
            } },
            .wait => .{ .wait = .{ .timeout = ib, .until = switch (std.enums.fromInt(UntilKind, small) orelse return error.Corrupt) {
                .idle => .idle,
                .shown => .{ .shown = try strings.get(ia) },
                .gone => .{ .gone = try strings.get(ia) },
            } } },
            .step => .{ .step = .{ .file = try strings.get(ia), .effect = try blobs.get(ib), .motion = try blobs.get(words[0]) } },
        } };
    }

    const files = try a.alloc(Tape.File, h.files);
    for (files, 0..) |*file, i| {
        var f: Reader = .{ .bytes = file_bytes[i * file_size ..][0..file_size] };
        file.* = .{ .path = try strings.get(try f.int(u32)), .text = try strings.get(try f.int(u32)) };
        if (tape_version >= 3) {
            file.owner = try strings.get(try f.int(u32));
            file.format = try f.int(u32);
        }
    }
    const open = try a.alloc([]const u8, h.open);
    for (open, 0..) |*o, i| {
        var f: Reader = .{ .bytes = open_bytes[i * open_size ..][0..open_size] };
        o.* = try strings.get(try f.int(u32));
    }
    const settings = try a.alloc(Tape.Setting, h.settings);
    for (settings, 0..) |*s, i| {
        var f: Reader = .{ .bytes = setting_bytes[i * setting_size ..][0..setting_size] };
        s.* = .{ .owner = try strings.get(try f.int(u32)), .key = try strings.get(try f.int(u32)), .value = try strings.get(try f.int(u32)) };
    }
    const keyframes = try a.alloc(Tape.Keyframe, h.keyframes);
    for (keyframes, 0..) |*kf, i| {
        var f: Reader = .{ .bytes = kf_bytes[i * keyframe_size ..][0..keyframe_size] };
        const root = try strings.get(try f.int(u32));
        const layout = std.enums.fromInt(Tape.Keyframe.Layout, try f.int(u8)) orelse return error.Corrupt;
        _ = try f.take(3);
        kf.* = .{
            .root = root,
            .layout = layout,
            .files = try slice(Tape.File, files, try f.int(u32), try f.int(u32)),
            .open = try slice([]const u8, open, try f.int(u32), try f.int(u32)),
            .settings = try slice(Tape.Setting, settings, try f.int(u32), try f.int(u32)),
        };
    }

    const clear = try a.alloc([]const u8, h.clear);
    for (clear, 0..) |*c, i| {
        var f: Reader = .{ .bytes = clear_bytes[i * clear_size ..][0..clear_size] };
        c.* = try strings.get(try f.int(u32));
    }
    const captions = try a.alloc(Tape.Caption, h.captions);
    for (captions, 0..) |*c, i| {
        var f: Reader = .{ .bytes = caption_bytes[i * caption_size ..][0..caption_size] };
        const at = try f.int(u32);
        const ms = try f.int(u32);
        const title = try strings.get(try f.int(u32));
        const text = try strings.get(try f.int(u32));
        const place = std.enums.fromInt(Tape.Caption.Place, try f.int(u8)) orelse return error.Corrupt;
        _ = try f.take(3);
        c.* = .{
            .at = at,
            .ms = ms,
            .title = title,
            .text = text,
            .place = place,
            .near = try strings.get(try f.int(u32)),
            .clear = try slice([]const u8, clear, try f.int(u32), try f.int(u32)),
        };
    }

    const chapters = try a.alloc(Tape.Chapter, h.chapters);
    for (chapters, 0..) |*c, i| {
        var f: Reader = .{ .bytes = chapter_bytes[i * chapter_size ..][0..chapter_size] };
        c.* = .{ .at = try f.int(u32), .title = try strings.get(try f.int(u32)) };
    }

    const tape: Tape = .{
        .name = try strings.get(h.name),
        .title = try strings.get(h.title),
        .home = try strings.get(h.home),
        .ops = ops,
        .keyframes = keyframes,
        .captions = captions,
        .chapters = chapters,
    };
    try tape.validate(check);
    return .{ .arena = arena, .tape = tape };
}

/// A deflated stream's bytes, then zeros without end. std's inflate (0.16) misreads a stream that
/// ends inside its last four bytes (`tossBitsShort` adds the bits it has used where it should take
/// them away) and asserts past the end of its input — a crash on a tape cut short. Never letting
/// its input end keeps it off that path; the inflated length, known from the header, bounds what a
/// stream cut short can run on into. ZIG017: fixed in 0.17's inflate, so this goes with the move;
/// 0.17 still leaves the checksum unchecked, so `read`'s Adler-32 check stays.
const Endless = struct {
    rest: []const u8,
    reader: std.Io.Reader,

    fn init(bytes: []const u8, buffer: []u8) Endless {
        return .{ .rest = bytes, .reader = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 } };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Endless = @alignCast(@fieldParentPtr("reader", r));
        const dest = limit.slice(try w.writableSliceGreedy(1));
        const n = @min(dest.len, self.rest.len);
        @memcpy(dest[0..n], self.rest[0..n]);
        @memset(dest[n..], 0);
        self.rest = self.rest[n..];
        w.advance(dest.len);
        return dest.len;
    }
};

/// `n` records of `size` bytes, or `error.Corrupt` when that is more than a tape could hold.
fn sizeOf(n: usize, size: usize) ReadError!usize {
    return std.math.mul(usize, n, size) catch error.Corrupt;
}

/// `list[first..][0..len]`, checked. Empty, it is the empty list a tape's defaults are — so the
/// tape writes back as the ZON it came from, defaults left out (`Tape.write` leaves out only
/// what is the default itself, not merely equal to it).
fn slice(comptime T: type, list: []const T, first: u32, len: u32) ReadError![]const T {
    const end = std.math.add(usize, first, len) catch return error.Corrupt;
    if (end > list.len) return error.Corrupt;
    if (len == 0) return &.{};
    return list[first..end];
}

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(self: *Reader, n: usize) ReadError![]const u8 {
        if (n > self.bytes.len - self.pos) return error.Truncated;
        defer self.pos += n;
        return self.bytes[self.pos..][0..n];
    }

    fn int(self: *Reader, comptime T: type) ReadError!T {
        const b = try self.take(@sizeOf(T));
        return std.mem.readInt(T, b[0..@sizeOf(T)], .little);
    }

    fn align4(self: *Reader) ReadError!void {
        _ = try self.take(pad4(self.pos));
    }
};

/// A table as read — the strings, or the blobs: offsets into `bytes`, checked once, then indexed.
const Table = struct {
    offsets: []const u8,
    bytes: []const u8,
    count: u32,

    /// No entries: what a tape from before version 3 has of blobs.
    const empty: Table = .{ .offsets = &.{ 0, 0, 0, 0 }, .bytes = "", .count = 0 };

    /// The table at `r`: `n + 1` offsets, then `len` bytes and their padding.
    fn take(r: *Reader, n: u32, len: u32) ReadError!Table {
        const offsets = try r.take(try sizeOf(@as(usize, n) + 1, 4));
        const bytes = try r.take(len);
        try r.align4();
        const t: Table = .{ .offsets = offsets, .bytes = bytes, .count = n };
        try t.check();
        return t;
    }

    fn offset(self: Table, i: usize) u32 {
        return std.mem.readInt(u32, self.offsets[i * 4 ..][0..4], .little);
    }

    /// Offsets start at 0, never go backwards, and end at the end of the bytes.
    fn check(self: Table) ReadError!void {
        var prev: u32 = 0;
        if (self.offset(0) != 0) return error.Corrupt;
        for (1..@as(usize, self.count) + 1) |i| {
            const o = self.offset(i);
            if (o < prev) return error.Corrupt;
            prev = o;
        }
        if (prev != self.bytes.len) return error.Corrupt;
    }

    /// String `i`. Empty, it is the empty string a tape's defaults are, as `slice`'s lists.
    fn get(self: Table, i: u32) ReadError![]const u8 {
        if (i >= self.count) return error.Corrupt;
        const lo = self.offset(i);
        const hi = self.offset(@as(usize, i) + 1);
        if (lo == hi) return "";
        return self.bytes[lo..hi];
    }
};

// ---- tests ---------------------------------------------------------------------------------

const testing = std.testing;

const Everything = struct {
    const files = [_]Tape.File{ .{ .path = "a.md", .text = "# A\n" }, .{ .path = "b.md", .text = "" } };
    const settings = [_]Tape.Setting{.{ .owner = "markdown", .key = "default_md_view", .value = ".split" }};
    const keyframe = Tape.Keyframe{ .root = "demo://t", .files = &files, .open = &.{ "a.md", "b.md" }, .settings = &settings, .layout = .reset };
    /// A binary document, by its owner, and its steps.
    const sprite = [_]Tape.File{.{ .path = "a.pixi", .text = &.{ 0x89, 'P', 0, 0xff, '\n', 0 }, .owner = "pixi", .format = 1 }};
    const ops_v2 = [_]Tape.Op{
        .{ .at = 0, .do = .{ .keyframe = 0 } },
        .{ .at = 0, .do = .{ .wait = .{ .until = .idle } } },
        .{ .at = 0, .do = .{ .wait = .{ .until = .{ .shown = "text.end:demo://t/a.md" }, .timeout = 2500 } } },
        .{ .at = 100, .ms = 400, .do = .{ .move = .{ .tag = "text.end:demo://t/a.md", .x = 0.25, .y = 0.75, .dx = -3.5, .dy = 8 } } },
        .{ .at = 500, .do = .{ .press = .right } },
        .{ .at = 560, .do = .{ .release = .right } },
        .{ .at = 600, .do = .{ .scroll = .{ .x = 1, .y = -3 } } },
        .{ .at = 700, .ms = 300, .do = .{ .type = "héllo\n\tworld" } },
        .{ .at = 1100, .do = .{ .key = "mod+k mod+c" } },
        .{ .at = 1200, .do = .{ .command = .{ .id = "fizzy.toggleExplorer" } } },
        .{ .at = 1250, .do = .{ .command = .{ .id = "text.goToLine", .args = ".{ .line = 12, .column = 3 }" } } },
        .{ .at = 1300, .do = .{ .wait = .{ .until = .{ .gone = "fizzy.palette" } } } },
        .{ .at = 1400, .do = .{ .keyframe = 1 } },
        .{ .at = 1500, .ms = 200, .do = .{ .move = .{} } },
        .{ .at = 1700, .ms = 80, .do = .{ .trace = .{ .tag = "pixi.canvas:demo://t/a.pixi", .x = 0.4, .y = 0.6 } } },
    };
    const ops = ops_v2 ++ [_]Tape.Op{
        .{ .at = 1800, .ms = 250, .do = .{ .step = .{ .file = "a.pixi", .effect = "\x00\x01\xff", .motion = "\x02\x00" } } },
        // The same effect again is stored again; one with no motion stores an empty one.
        .{ .at = 2100, .do = .{ .step = .{ .file = "a.pixi", .effect = "\x00\x01\xff" } } },
    };
    const captions = [_]Tape.Caption{
        .{ .at = 0, .ms = 900, .title = "Hi", .text = "Welcome.", .place = .middle },
        .{ .at = 900, .ms = 600, .text = "Beside it.", .near = "text.end:demo://t/a.md", .clear = &.{ "text.body:demo://t/a.md", "text.preview:demo://t/a.md" } },
    };
    const chapters = [_]Tape.Chapter{ .{ .at = 0, .title = "One" }, .{ .at = 1400, .title = "Two" } };

    fn tape(ops_: []const Tape.Op, keyframes: []const Tape.Keyframe) Tape {
        return .{ .name = "t", .title = "Everything", .home = "region:Main", .ops = ops_, .keyframes = keyframes, .captions = &captions, .chapters = &chapters };
    }
};

/// A tape with something of everything in it.
fn everything() Tape {
    const keyframes = [_]Tape.Keyframe{ Everything.keyframe, .{ .root = "demo://t", .files = &Everything.sprite } };
    return Everything.tape(&Everything.ops, &keyframes);
}

/// `everything` as version 2 could hold it, before steps: what `testdata/everything-v2.tape` is,
/// written by the version-2 codec.
fn everythingV2() Tape {
    const keyframes = [_]Tape.Keyframe{ Everything.keyframe, .{ .root = "demo://t" } };
    return Everything.tape(&Everything.ops_v2, &keyframes);
}

/// The two tapes say exactly the same, field for field — and write the same ZON.
fn expectSame(want: Tape, got: Tape) !void {
    try testing.expectEqualDeep(want, got);
    var a: std.Io.Writer.Allocating = .init(testing.allocator);
    defer a.deinit();
    var b: std.Io.Writer.Allocating = .init(testing.allocator);
    defer b.deinit();
    try want.write(&a.writer);
    try got.write(&b.writer);
    try testing.expectEqualStrings(a.written(), b.written());
}

const steps_check = Tape.test_steps;

test "a tape round-trips through the binary form, field for field, deflated or not" {
    const tape = everything();
    try tape.validate(steps_check);
    for ([_]bool{ false, true }) |deflate| {
        const bytes = try encode(testing.allocator, tape, .{ .deflate = deflate });
        defer testing.allocator.free(bytes);
        try testing.expect(sniff(bytes));

        var owned = try read(testing.allocator, bytes, steps_check);
        defer owned.deinit();
        try expectSame(tape, owned.tape);
        // Floats exactly, not near enough; bytes as they were.
        try testing.expectEqual(@as(f32, -3.5), owned.tape.ops[3].do.move.dx);
        try testing.expectEqualStrings("héllo\n\tworld", owned.tape.ops[7].do.type);
        try testing.expectEqualSlices(u8, &.{ 0x89, 'P', 0, 0xff, '\n', 0 }, owned.tape.keyframes[1].files[0].text);
    }
}

test "binary and ZON are the same tape, converted either way" {
    const tape = everything();
    var zon: std.Io.Writer.Allocating = .init(testing.allocator);
    defer zon.deinit();
    try tape.write(&zon.writer);
    const source = try testing.allocator.dupeZ(u8, zon.written());
    defer testing.allocator.free(source);
    var from_zon = try Tape.parse(testing.allocator, source, steps_check);
    defer from_zon.deinit();

    const bytes = try encode(testing.allocator, from_zon.tape, .{});
    defer testing.allocator.free(bytes);
    var back = try read(testing.allocator, bytes, steps_check);
    defer back.deinit();
    try expectSame(tape, back.tape);
}

test "each string is stored once, each blob as often as it comes" {
    const tape = everything();
    const bytes = try encode(testing.allocator, tape, .{});
    defer testing.allocator.free(bytes);
    // The anchor is named by two ops, a wait and a caption: once in the file.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "text.end:demo://t/a.md"));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, bytes, "\x00\x01\xff"));
}

test "a deflated tape is smaller" {
    // Steps the shape of a recording's: runs of a few colours.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ops = try arena.allocator().alloc(Tape.Op, 201);
    ops[0] = .{ .at = 0, .do = .{ .keyframe = 1 } };
    for (ops[1..], 1..) |*op, i| {
        const effect = try arena.allocator().alloc(u8, 64);
        @memset(effect, @intCast(i % 4));
        op.* = .{ .at = @intCast(i * 100), .do = .{ .step = .{ .file = "a.pixi", .effect = effect } } };
    }
    const tape = Everything.tape(ops, &.{ Everything.keyframe, .{ .root = "demo://t", .files = &Everything.sprite } });
    const plain = try encode(testing.allocator, tape, .{});
    defer testing.allocator.free(plain);
    const deflated = try encode(testing.allocator, tape, .{ .deflate = true });
    defer testing.allocator.free(deflated);
    try testing.expect(deflated.len * 4 < plain.len);
}

test "a reader holds nothing of the bytes it read" {
    for ([_]bool{ false, true }) |deflate| {
        const bytes = try encode(testing.allocator, everything(), .{ .deflate = deflate });
        var owned = try read(testing.allocator, bytes, steps_check);
        defer owned.deinit();
        @memset(bytes, 0xaa);
        testing.allocator.free(bytes);
        try testing.expectEqualStrings("region:Main", owned.tape.home);
        try testing.expectEqualStrings("\x02\x00", owned.tape.ops[15].do.step.motion);
    }
}

test "what is not a binary tape, or not a whole one, is refused" {
    try testing.expectError(error.NotATape, read(testing.allocator, ".{ .name = \"zon\" }", steps_check));

    for ([_]bool{ false, true }) |deflate| {
        const bytes = try encode(testing.allocator, everything(), .{ .deflate = deflate });
        defer testing.allocator.free(bytes);
        // Cut short anywhere, it is truncated — or, cut inside a table or the stream, corrupt —
        // and never read past its end.
        for (0..bytes.len) |n| {
            if (read(testing.allocator, bytes[0..n], steps_check)) |owned| {
                var o = owned;
                o.deinit();
                return error.TestUnexpectedResult;
            } else |err| switch (err) {
                error.NotATape, error.Truncated, error.Corrupt => {},
                else => return err,
            }
        }

        var newer = try testing.allocator.dupe(u8, bytes);
        defer testing.allocator.free(newer);
        std.mem.writeInt(u16, newer[4..6], version + 1, .little);
        try testing.expectError(error.UnsupportedVersion, read(testing.allocator, newer, steps_check));
        // A flag no reader knows is not guessed at.
        std.mem.writeInt(u16, newer[4..6], version, .little);
        std.mem.writeInt(u16, newer[6..8], 1 << 7, .little);
        try testing.expectError(error.Corrupt, read(testing.allocator, newer, steps_check));
    }
}

test "flipped bytes are an error, never a crash" {
    var prng: std.Random.DefaultPrng = .init(0x7a9e);
    const r = prng.random();
    for ([_]bool{ false, true }) |deflate| {
        const bytes = try encode(testing.allocator, everything(), .{ .deflate = deflate });
        defer testing.allocator.free(bytes);
        const copy = try testing.allocator.dupe(u8, bytes);
        defer testing.allocator.free(copy);
        for (0..4000) |_| {
            @memcpy(copy, bytes);
            for (0..1 + r.uintLessThan(usize, 4)) |_| copy[r.uintLessThan(usize, copy.len)] ^= @as(u8, 1) << r.int(u3);
            if (read(testing.allocator, copy, steps_check)) |owned| {
                var o = owned;
                o.deinit();
            } else |_| {}
        }
    }
}

const v2_fixture = @embedFile("testdata/everything-v2.tape");

test "a version-2 tape still reads, field for field" {
    var owned = try read(testing.allocator, v2_fixture, .{});
    defer owned.deinit();
    try expectSame(everythingV2(), owned.tape);
}

test "a version-1 tape still reads, its commands without arguments" {
    const bytes = try testing.allocator.dupe(u8, v2_fixture);
    defer testing.allocator.free(bytes);
    std.mem.writeInt(u16, bytes[4..6], 1, .little);
    var owned = try read(testing.allocator, bytes, .{});
    defer owned.deinit();
    const go = owned.tape.ops[10].do.command;
    try testing.expectEqualStrings("text.goToLine", go.id);
    try testing.expectEqualStrings("", go.args);

    std.mem.writeInt(u16, bytes[4..6], 0, .little);
    try testing.expectError(error.UnsupportedVersion, read(testing.allocator, bytes, .{}));
    // Deflating came with version 3.
    std.mem.writeInt(u16, bytes[4..6], 2, .little);
    std.mem.writeInt(u16, bytes[6..8], flag_deflated, .little);
    try testing.expectError(error.Corrupt, read(testing.allocator, bytes, .{}));
}

test "a recording's key chords and steps are checked against the app, as in ZON" {
    const bytes = try encode(testing.allocator, everything(), .{});
    defer testing.allocator.free(bytes);
    try testing.expectError(error.BadChord, read(testing.allocator, bytes, .{ .steps = steps_check.steps, .key = struct {
        fn ok(c: []const u8) bool {
            return std.mem.indexOfScalar(u8, c, ' ') == null;
        }
    }.ok }));
    try testing.expectError(error.StepsUnsupported, read(testing.allocator, bytes, .{}));
}
