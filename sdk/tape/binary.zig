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
//! **Versions.** `version` is bumped for any change a reader of the old one would misread; a
//! reader refuses a version it does not know (`error.UnsupportedVersion`) rather than guess.
const std = @import("std");
const Tape = @import("Tape.zig");

pub const magic = "FZTP".*;
pub const version: u16 = 1;

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
};
/// The header's size on disk: magic, version, flags, then `Header`'s fields.
pub const header_size = 4 + 2 + 2 + 13 * 4;

/// The size of each record on disk.
pub const op_size = 36;
const keyframe_size = 32;
const file_size = 8;
const open_size = 4;
const setting_size = 12;
const caption_size = 32;
const clear_size = 4;
const chapter_size = 8;

/// An op's kind on disk. Appended to, never reordered.
const Kind = enum(u8) { keyframe, move, press, release, scroll, key, type, command, wait };
/// A wait's condition on disk.
const UntilKind = enum(u8) { idle, shown, gone };

// ---- writing -------------------------------------------------------------------------------

/// Write `tape` in the binary form. `gpa` is for the string table while it is built.
pub fn write(gpa: std.mem.Allocator, tape: Tape, w: *std.Io.Writer) !void {
    var table: Strings = .{};
    defer table.deinit(gpa);

    // Every string, interned, in the order first met — so the table is deterministic.
    const name = try table.intern(gpa, tape.name);
    const title = try table.intern(gpa, tape.title);
    const home = try table.intern(gpa, tape.home);
    for (tape.ops) |op| switch (op.do) {
        .move => |m| _ = try table.intern(gpa, m.tag),
        .key, .type, .command => |s| _ = try table.intern(gpa, s),
        .wait => |wt| switch (wt.until) {
            .shown, .gone => |s| _ = try table.intern(gpa, s),
            .idle => {},
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
    };
    try w.writeAll(&magic);
    try w.writeInt(u16, version, .little);
    try w.writeInt(u16, 0, .little);
    inline for (std.meta.fields(Header)) |f| try w.writeInt(u32, @field(h, f.name), .little);

    var at: u32 = 0;
    for (table.list.items) |s| {
        try w.writeInt(u32, at, .little);
        at += count(s.len);
    }
    try w.writeInt(u32, at, .little);
    for (table.list.items) |s| try w.writeAll(s);
    try w.splatByteAll(0, pad4(table.bytes));

    for (tape.ops) |op| {
        var kind: Kind = undefined;
        var small: u8 = 0;
        var a: u32 = 0;
        var b: u32 = 0;
        var xy: [4]f32 = @splat(0);
        switch (op.do) {
            .keyframe => |i| {
                kind = .keyframe;
                a = i;
            },
            .move => |m| {
                kind = .move;
                a = table.index(m.tag);
                xy = .{ m.x, m.y, m.dx, m.dy };
            },
            .press, .release => |btn| {
                kind = if (op.do == .press) .press else .release;
                small = @intFromEnum(btn);
            },
            .scroll => |s| {
                kind = .scroll;
                xy = .{ s.x, s.y, 0, 0 };
            },
            .key => |s| {
                kind = .key;
                a = table.index(s);
            },
            .type => |s| {
                kind = .type;
                a = table.index(s);
            },
            .command => |s| {
                kind = .command;
                a = table.index(s);
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
        for (xy) |v| try w.writeInt(u32, @bitCast(v), .little);
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
        try w.writeInt(u32, table.index(f.path), .little);
        try w.writeInt(u32, table.index(f.text), .little);
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

/// `write` into a new allocation.
pub fn encode(gpa: std.mem.Allocator, tape: Tape) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    write(gpa, tape, &out.writer) catch |err| switch (err) {
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
    const own = try a.dupe(u8, bytes);
    var r: Reader = .{ .bytes = own };

    _ = try r.take(magic.len);
    if (try r.int(u16) != version) return error.UnsupportedVersion;
    _ = try r.int(u16); // flags: none yet
    var h: Header = undefined;
    inline for (std.meta.fields(Header)) |f| @field(h, f.name) = try r.int(u32);

    // The string table: offsets, then the bytes they index.
    const offsets = try r.take(try sizeOf(@as(usize, h.strings) + 1, 4));
    const string_bytes = try r.take(h.string_bytes);
    try r.align4();
    const strings: Strings2 = .{ .offsets = offsets, .bytes = string_bytes, .count = h.strings };
    try strings.check();

    const op_bytes = try r.take(try sizeOf(h.ops, op_size));
    const kf_bytes = try r.take(try sizeOf(h.keyframes, keyframe_size));
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
        var xy: [4]f32 = undefined;
        for (&xy) |*v| v.* = @bitCast(try f.int(u32));
        op.* = .{ .at = at, .ms = ms, .do = switch (kind) {
            .keyframe => .{ .keyframe = std.math.cast(u16, ia) orelse return error.Corrupt },
            .move => .{ .move = .{ .tag = try strings.get(ia), .x = xy[0], .y = xy[1], .dx = xy[2], .dy = xy[3] } },
            .press => .{ .press = std.enums.fromInt(Tape.Button, small) orelse return error.Corrupt },
            .release => .{ .release = std.enums.fromInt(Tape.Button, small) orelse return error.Corrupt },
            .scroll => .{ .scroll = .{ .x = xy[0], .y = xy[1] } },
            .key => .{ .key = try strings.get(ia) },
            .type => .{ .type = try strings.get(ia) },
            .command => .{ .command = try strings.get(ia) },
            .wait => .{ .wait = .{ .timeout = ib, .until = switch (std.enums.fromInt(UntilKind, small) orelse return error.Corrupt) {
                .idle => .idle,
                .shown => .{ .shown = try strings.get(ia) },
                .gone => .{ .gone = try strings.get(ia) },
            } } },
        } };
    }

    const files = try a.alloc(Tape.File, h.files);
    for (files, 0..) |*file, i| {
        var f: Reader = .{ .bytes = file_bytes[i * file_size ..][0..file_size] };
        file.* = .{ .path = try strings.get(try f.int(u32)), .text = try strings.get(try f.int(u32)) };
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

/// The string table as read: offsets into `bytes`, checked once, then indexed.
const Strings2 = struct {
    offsets: []const u8,
    bytes: []const u8,
    count: u32,

    fn offset(self: Strings2, i: usize) u32 {
        return std.mem.readInt(u32, self.offsets[i * 4 ..][0..4], .little);
    }

    /// Offsets start at 0, never go backwards, and end at the end of the bytes.
    fn check(self: Strings2) ReadError!void {
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
    fn get(self: Strings2, i: u32) ReadError![]const u8 {
        if (i >= self.count) return error.Corrupt;
        const lo = self.offset(i);
        const hi = self.offset(@as(usize, i) + 1);
        if (lo == hi) return "";
        return self.bytes[lo..hi];
    }
};

// ---- tests ---------------------------------------------------------------------------------

const testing = std.testing;

/// A tape with something of everything in it.
fn everything() Tape {
    const S = struct {
        const files = [_]Tape.File{ .{ .path = "a.md", .text = "# A\n" }, .{ .path = "b.md", .text = "" } };
        const settings = [_]Tape.Setting{.{ .owner = "markdown", .key = "default_md_view", .value = ".split" }};
        const keyframes = [_]Tape.Keyframe{
            .{ .root = "demo://t", .files = &files, .open = &.{ "a.md", "b.md" }, .settings = &settings, .layout = .reset },
            .{ .root = "demo://t" },
        };
        const ops = [_]Tape.Op{
            .{ .at = 0, .do = .{ .keyframe = 0 } },
            .{ .at = 0, .do = .{ .wait = .{ .until = .idle } } },
            .{ .at = 0, .do = .{ .wait = .{ .until = .{ .shown = "text.end:demo://t/a.md" }, .timeout = 2500 } } },
            .{ .at = 100, .ms = 400, .do = .{ .move = .{ .tag = "text.end:demo://t/a.md", .x = 0.25, .y = 0.75, .dx = -3.5, .dy = 8 } } },
            .{ .at = 500, .do = .{ .press = .right } },
            .{ .at = 560, .do = .{ .release = .right } },
            .{ .at = 600, .do = .{ .scroll = .{ .x = 1, .y = -3 } } },
            .{ .at = 700, .ms = 300, .do = .{ .type = "héllo\n\tworld" } },
            .{ .at = 1100, .do = .{ .key = "mod+k mod+c" } },
            .{ .at = 1200, .do = .{ .command = "fizzy.toggleExplorer" } },
            .{ .at = 1300, .do = .{ .wait = .{ .until = .{ .gone = "fizzy.palette" } } } },
            .{ .at = 1400, .do = .{ .keyframe = 1 } },
            .{ .at = 1500, .ms = 200, .do = .{ .move = .{} } },
        };
        const captions = [_]Tape.Caption{
            .{ .at = 0, .ms = 900, .title = "Hi", .text = "Welcome.", .place = .middle },
            .{ .at = 900, .ms = 600, .text = "Beside it.", .near = "text.end:demo://t/a.md", .clear = &.{ "text.body:demo://t/a.md", "text.preview:demo://t/a.md" } },
        };
        const chapters = [_]Tape.Chapter{ .{ .at = 0, .title = "One" }, .{ .at = 1400, .title = "Two" } };
    };
    return .{
        .name = "t",
        .title = "Everything",
        .home = "region:Main",
        .ops = &S.ops,
        .keyframes = &S.keyframes,
        .captions = &S.captions,
        .chapters = &S.chapters,
    };
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

test "a tape round-trips through the binary form, field for field" {
    const tape = everything();
    try tape.validate(.{});
    const bytes = try encode(testing.allocator, tape);
    defer testing.allocator.free(bytes);
    try testing.expect(sniff(bytes));

    var owned = try read(testing.allocator, bytes, .{});
    defer owned.deinit();
    try expectSame(tape, owned.tape);
    // Floats exactly, not near enough.
    try testing.expectEqual(@as(f32, -3.5), owned.tape.ops[3].do.move.dx);
    try testing.expectEqualStrings("héllo\n\tworld", owned.tape.ops[7].do.type);
}

test "binary and ZON are the same tape, converted either way" {
    const tape = everything();
    var zon: std.Io.Writer.Allocating = .init(testing.allocator);
    defer zon.deinit();
    try tape.write(&zon.writer);
    const source = try testing.allocator.dupeZ(u8, zon.written());
    defer testing.allocator.free(source);
    var from_zon = try Tape.parse(testing.allocator, source, .{});
    defer from_zon.deinit();

    const bytes = try encode(testing.allocator, from_zon.tape);
    defer testing.allocator.free(bytes);
    var back = try read(testing.allocator, bytes, .{});
    defer back.deinit();
    try expectSame(tape, back.tape);
}

test "each string is stored once" {
    const tape = everything();
    const bytes = try encode(testing.allocator, tape);
    defer testing.allocator.free(bytes);
    // The anchor is named by two ops, a wait and a caption: once in the file.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "text.end:demo://t/a.md"));
}

test "a reader holds nothing of the bytes it read" {
    const bytes = try encode(testing.allocator, everything());
    var owned = try read(testing.allocator, bytes, .{});
    defer owned.deinit();
    @memset(bytes, 0xaa);
    testing.allocator.free(bytes);
    try testing.expectEqualStrings("region:Main", owned.tape.home);
}

test "what is not a binary tape, or not a whole one, is refused" {
    try testing.expectError(error.NotATape, read(testing.allocator, ".{ .name = \"zon\" }", .{}));

    const bytes = try encode(testing.allocator, everything());
    defer testing.allocator.free(bytes);
    // Cut short anywhere, it is truncated — or, cut inside the string table, corrupt — and never
    // read past its end.
    for (0..bytes.len) |n| {
        if (read(testing.allocator, bytes[0..n], .{})) |owned| {
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
    try testing.expectError(error.UnsupportedVersion, read(testing.allocator, newer, .{}));
}

test "flipped bytes are an error, never a crash" {
    const bytes = try encode(testing.allocator, everything());
    defer testing.allocator.free(bytes);
    const copy = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(copy);
    var prng: std.Random.DefaultPrng = .init(0x7a9e);
    const r = prng.random();
    for (0..4000) |_| {
        @memcpy(copy, bytes);
        for (0..1 + r.uintLessThan(usize, 4)) |_| copy[r.uintLessThan(usize, copy.len)] ^= @as(u8, 1) << r.int(u3);
        if (read(testing.allocator, copy, .{})) |owned| {
            var o = owned;
            o.deinit();
        } else |_| {}
    }
}

test "a recording's key chords are checked against the app's spelling, as in ZON" {
    const bytes = try encode(testing.allocator, everything());
    defer testing.allocator.free(bytes);
    try testing.expectError(error.BadChord, read(testing.allocator, bytes, .{ .key = struct {
        fn ok(c: []const u8) bool {
            return std.mem.indexOfScalar(u8, c, ' ') == null;
        }
    }.ok }));
}
