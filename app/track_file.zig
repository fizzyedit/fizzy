//! A track as a file: what a closed document's track is kept as in the profile
//! (`<config>/tracks/`, `Tracks.keep`), and read back from when the document opens again
//! (`Tracks.pickUp`). Everything a track holds but its document's handle: the owner and step
//! format it was recorded for, the document's path and where the track ended (`End`: what
//! reopening checks), the base, the steps with their effects and motion, and the
//! checkpoints as they were kept (whole, or as deltas).
//!
//! Std only, and its own: no other reader. Little-endian, lengths as LEB128, opening with
//! `magic` and `version`; a file of another version is not read (the document opens with a fresh
//! track, as one changed outside fizzy does).
const std = @import("std");
const Tracks = @import("Tracks.zig");
const Track = Tracks.Track;
const Kind = @import("fizzy_sdk").Step.Kind;

pub const magic = "fizzy-track\n";
pub const version: u32 = 1;

/// Where a track ended, as a document opening again is checked against: its fingerprint then
/// (an unsaved document a restart brings back stands exactly there, caret and all), and, when it
/// closed saved, a hash of its file (a saved document read back from disk is its file, wherever
/// its caret is). Either is enough.
pub const End = struct {
    fingerprint: u64,
    file_hash: ?u64 = null,
};

/// The hash a file's bytes are known by (`End.file_hash`).
pub fn fileHash(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0x7472_6163_6b, bytes);
}

/// A track read back from its file. `deinit` frees it, unless its parts were handed on
/// (`Tracks.pickUp` takes them into a track).
pub const Read = struct {
    owner: []u8,
    path: []u8,
    format: u32,
    base_top: u64,
    /// Where the track ended: a document that opens anywhere else is not where it left it.
    end: End,
    base: Track.State,
    steps: std.ArrayList(Track.Rec),
    bytes: std.ArrayList(u8),
    checkpoints: std.ArrayList(Track.State),

    pub fn deinit(self: *Read, gpa: std.mem.Allocator) void {
        gpa.free(self.owner);
        gpa.free(self.path);
        gpa.free(self.base.bytes);
        self.steps.deinit(gpa);
        self.bytes.deinit(gpa);
        for (self.checkpoints.items) |c| gpa.free(c.bytes);
        self.checkpoints.deinit(gpa);
    }
};

/// `t` as a file's bytes, for `path`'s document whose owner is `owner`, ending at `end`. `t` must
/// have its base.
pub fn write(gpa: std.mem.Allocator, t: *const Track, owner: []const u8, path: []const u8, end: End) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll(magic);
    try w.writeInt(u32, version, .little);
    try writeBytes(w, owner);
    try writeBytes(w, path);
    try w.writeInt(u32, t.format, .little);
    try w.writeInt(u64, t.base_top, .little);
    try w.writeInt(u64, end.fingerprint, .little);
    try w.writeByte(@intFromBool(end.file_hash != null));
    try w.writeInt(u64, end.file_hash orelse 0, .little);
    try writeState(w, t.base.?);
    try w.writeUleb128(t.steps.items.len);
    for (t.steps.items) |r| {
        try w.writeByte(@backingInt(r.kind));
        try w.writeInt(u64, r.id, .little);
        try w.writeInt(u32, r.at, .little);
        try w.writeInt(u32, r.ms, .little);
        try writeBytes(w, t.effect(r));
        try writeBytes(w, t.motion(r));
    }
    try w.writeUleb128(t.checkpoints.items.len);
    for (t.checkpoints.items) |c| try writeState(w, c);
    return out.toOwnedSlice();
}

/// A track from a file's `bytes`, or `error.NotATrack` for anything else (another version, cut
/// short, a value out of range).
pub fn read(gpa: std.mem.Allocator, bytes: []const u8) !Read {
    var r: std.Io.Reader = .fixed(bytes);
    const head = r.take(magic.len) catch return error.NotATrack;
    if (!std.mem.eql(u8, head, magic)) return error.NotATrack;
    if ((r.takeInt(u32, .little) catch return error.NotATrack) != version) return error.NotATrack;
    const owner = try gpa.dupe(u8, try takeBytes(&r));
    errdefer gpa.free(owner);
    const path = try gpa.dupe(u8, try takeBytes(&r));
    errdefer gpa.free(path);
    const format = r.takeInt(u32, .little) catch return error.NotATrack;
    const base_top = r.takeInt(u64, .little) catch return error.NotATrack;
    const end_fingerprint = r.takeInt(u64, .little) catch return error.NotATrack;
    const has_file = (r.takeByte() catch return error.NotATrack) != 0;
    const file_hash = r.takeInt(u64, .little) catch return error.NotATrack;
    const base = try takeState(gpa, &r);
    errdefer gpa.free(base.bytes);
    var steps: std.ArrayList(Track.Rec) = .empty;
    errdefer steps.deinit(gpa);
    var held: std.ArrayList(u8) = .empty;
    errdefer held.deinit(gpa);
    const n = r.takeLeb128(usize) catch return error.NotATrack;
    for (0..n) |_| {
        const kind = std.enums.fromInt(Kind, r.takeByte() catch return error.NotATrack) orelse return error.NotATrack;
        const id = r.takeInt(u64, .little) catch return error.NotATrack;
        const at = r.takeInt(u32, .little) catch return error.NotATrack;
        const ms = r.takeInt(u32, .little) catch return error.NotATrack;
        const effect = try takeBytes(&r);
        const effect_at = held.items.len;
        try held.appendSlice(gpa, effect);
        const motion = try takeBytes(&r);
        const motion_at = held.items.len;
        try held.appendSlice(gpa, motion);
        try steps.append(gpa, .{
            .kind = kind,
            .id = id,
            .at = at,
            .ms = ms,
            .effect = .{ .start = effect_at, .len = effect.len },
            .motion = .{ .start = motion_at, .len = motion.len },
        });
    }
    var checkpoints: std.ArrayList(Track.State) = .empty;
    errdefer {
        for (checkpoints.items) |c| gpa.free(c.bytes);
        checkpoints.deinit(gpa);
    }
    const m = r.takeLeb128(usize) catch return error.NotATrack;
    for (0..m) |_| {
        const c = try takeState(gpa, &r);
        checkpoints.append(gpa, c) catch |err| {
            gpa.free(c.bytes);
            return err;
        };
    }
    return .{
        .owner = owner,
        .path = path,
        .format = format,
        .base_top = base_top,
        .end = .{ .fingerprint = end_fingerprint, .file_hash = if (has_file) file_hash else null },
        .base = base,
        .steps = steps,
        .bytes = held,
        .checkpoints = checkpoints,
    };
}

/// The path a track file is for, from its first bytes alone (`head_len` of them is enough for any
/// path), without reading the rest: what finding the files of documents gone from disk reads.
/// Null for anything that is not a track file.
pub fn headPath(head: []const u8) ?[]const u8 {
    var r: std.Io.Reader = .fixed(head);
    const m = r.take(magic.len) catch return null;
    if (!std.mem.eql(u8, m, magic)) return null;
    if ((r.takeInt(u32, .little) catch return null) != version) return null;
    _ = takeBytes(&r) catch return null;
    return takeBytes(&r) catch null;
}

/// How much of a track file `headPath` needs: its magic, version, owner id and a path.
pub const head_len = 8192;

fn writeBytes(w: *std.Io.Writer, bytes: []const u8) !void {
    try w.writeUleb128(bytes.len);
    try w.writeAll(bytes);
}

fn takeBytes(r: *std.Io.Reader) ![]const u8 {
    const len = r.takeLeb128(usize) catch return error.NotATrack;
    return r.take(len) catch error.NotATrack;
}

fn writeState(w: *std.Io.Writer, s: Track.State) !void {
    try w.writeInt(u32, s.at, .little);
    try w.writeUleb128(s.step);
    try w.writeByte(@intFromBool(s.whole));
    try w.writeByte(@intFromBool(s.fingerprint != null));
    try w.writeInt(u64, s.fingerprint orelse 0, .little);
    try writeBytes(w, s.bytes);
}

fn takeState(gpa: std.mem.Allocator, r: *std.Io.Reader) !Track.State {
    const at = r.takeInt(u32, .little) catch return error.NotATrack;
    const step = r.takeLeb128(usize) catch return error.NotATrack;
    const whole = (r.takeByte() catch return error.NotATrack) != 0;
    const has_fingerprint = (r.takeByte() catch return error.NotATrack) != 0;
    const fingerprint = r.takeInt(u64, .little) catch return error.NotATrack;
    const bytes = try gpa.dupe(u8, try takeBytes(r));
    return .{ .at = at, .step = step, .bytes = bytes, .whole = whole, .fingerprint = if (has_fingerprint) fingerprint else null };
}

const testing = std.testing;

test "a track written to a file reads back as it was" {
    const gpa = testing.allocator;
    var t: Track = .{ .doc_id = 1, .doc = undefined, .owner = undefined, .format = 3, .base_top = 9 };
    t.base = .{ .at = 0, .step = 0, .bytes = try gpa.dupe(u8, "base"), .fingerprint = 11 };
    defer gpa.free(t.base.?.bytes);
    defer t.steps.deinit(gpa);
    defer t.bytes.deinit(gpa);
    defer {
        for (t.checkpoints.items) |c| gpa.free(c.bytes);
        t.checkpoints.deinit(gpa);
    }
    for ([_]struct { Kind, u64, []const u8, []const u8 }{
        .{ .added, 10, "ab", "" }, .{ .joined, 10, "c", "mm" }, .{ .undone, 10, "CBA", "" },
    }, 0..) |s, i| {
        const effect_at = t.bytes.items.len;
        try t.bytes.appendSlice(gpa, s[2]);
        const motion_at = t.bytes.items.len;
        try t.bytes.appendSlice(gpa, s[3]);
        try t.steps.append(gpa, .{ .kind = s[0], .id = s[1], .at = @intCast(i * 100), .ms = 40, .effect = .{ .start = effect_at, .len = s[2].len }, .motion = .{ .start = motion_at, .len = s[3].len } });
    }
    try t.checkpoints.append(gpa, .{ .at = 200, .step = 2, .bytes = try gpa.dupe(u8, "delta"), .whole = false, .fingerprint = null });

    const bytes = try write(gpa, &t, "text", "/a/b.txt", .{ .fingerprint = 77, .file_hash = 5 });
    defer gpa.free(bytes);
    var back = try read(gpa, bytes);
    defer back.deinit(gpa);
    try testing.expectEqualStrings("text", back.owner);
    try testing.expectEqualStrings("/a/b.txt", back.path);
    try testing.expectEqual(@as(u32, 3), back.format);
    try testing.expectEqual(@as(u64, 9), back.base_top);
    try testing.expectEqual(@as(u64, 77), back.end.fingerprint);
    try testing.expectEqual(@as(?u64, 5), back.end.file_hash);
    try testing.expectEqualStrings("base", back.base.bytes);
    try testing.expectEqual(@as(?u64, 11), back.base.fingerprint);
    try testing.expectEqual(@as(usize, 3), back.steps.items.len);
    for (t.steps.items, back.steps.items) |a, b| {
        try testing.expectEqual(a.kind, b.kind);
        try testing.expectEqual(a.id, b.id);
        try testing.expectEqual(a.at, b.at);
        try testing.expectEqualStrings(t.effect(a), back.bytes.items[b.effect.start..][0..b.effect.len]);
        try testing.expectEqualStrings(t.motion(a), back.bytes.items[b.motion.start..][0..b.motion.len]);
    }
    try testing.expectEqual(@as(usize, 1), back.checkpoints.items.len);
    try testing.expect(!back.checkpoints.items[0].whole);
    try testing.expectEqual(@as(?u64, null), back.checkpoints.items[0].fingerprint);
    try testing.expectEqualStrings("delta", back.checkpoints.items[0].bytes);

    // Its path, from its head alone.
    try testing.expectEqualStrings("/a/b.txt", headPath(bytes[0..@min(bytes.len, head_len)]).?);
    try testing.expectEqual(@as(?[]const u8, null), headPath("not a track"));

    // Anything else is not read: another version, or cut short anywhere.
    var other = try gpa.dupe(u8, bytes);
    defer gpa.free(other);
    other[magic.len] = 2;
    try testing.expectError(error.NotATrack, read(gpa, other));
    for (0..bytes.len) |cut| if (read(gpa, bytes[0..cut])) |r| {
        var rr = r;
        rr.deinit(gpa);
        return error.TestUnexpectedResult;
    } else |_| {};
}
