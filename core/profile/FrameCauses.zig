//! Why each frame happened, kept while the profiler records (`core.profile`): fizzy draws only
//! when something asks, so the two frame-loop bugs are a frame that never comes (work waiting for
//! the next unrelated event) and frames that never stop (something asking for another every frame).
//! A profile shows where a frame's time goes; this says who asked for it.
//!
//! A frame is put down to its events (input, a window event), else to the `dvui.refresh` calls
//! since the last one, by the file and line that asked (from dvui's own refresh records, which
//! the app's log function hands to `noteRefresh`), else to something else: a timer or an animation
//! coming due. Refreshes are counted by place; the places are kept, the frames as counts.
//!
//! Its own allocation, published beside the profiler under its own key (as `Lookback`), so the
//! profiler's layout, and its `abi`, are untouched. std-only. `noteRefresh` may be called from
//! any thread (a worker waking the app), under a spin lock held for a few instructions.
const FrameCauses = @This();

const std = @import("std");

pub const abi: u32 = 1;
/// The places that asked for frames, kept by count. One past it counts as `other_places`.
pub const places_kept = 32;
const file_len = 64;

lock: std.atomic.Value(bool) = .init(false),
/// Frames recorded, and what each was put down to.
frames: u32 = 0,
by_events: u32 = 0,
by_refresh: u32 = 0,
by_other: u32 = 0,
/// Refreshes since the last frame began: they caused the next one.
pending: u32 = 0,
places: [places_kept]Place = undefined,
places_len: usize = 0,
/// Refreshes from places past `places_kept`.
other_places: u32 = 0,

pub const Place = struct {
    /// The asking file's path, its tail when longer than `file_len`: a dylib's strings go with it
    /// when it unloads, so it is copied.
    file_buf: [file_len]u8,
    file_len: u8,
    line: u32,
    count: u32,
    /// Asked from a thread other than the UI's (`dvui.refresh` with a window, through the backend).
    from_thread: bool,

    pub fn file(self: *const Place) []const u8 {
        return self.file_buf[0..self.file_len];
    }
};

fn acquire(self: *FrameCauses) void {
    while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn release(self: *FrameCauses) void {
    self.lock.store(false, .release);
}

/// Start over: counts from now.
pub fn reset(self: *FrameCauses) void {
    self.acquire();
    defer self.release();
    self.frames = 0;
    self.by_events = 0;
    self.by_refresh = 0;
    self.by_other = 0;
    self.pending = 0;
    self.places_len = 0;
    self.other_places = 0;
}

/// A `dvui.refresh` from `file`:`line`. Any thread.
pub fn noteRefresh(self: *FrameCauses, file: []const u8, line: u32, from_thread: bool) void {
    self.acquire();
    defer self.release();
    self.pending +|= 1;
    const tail = file[file.len - @min(file.len, file_len) ..];
    for (self.places[0..self.places_len]) |*p| {
        if (p.line == line and p.from_thread == from_thread and std.mem.eql(u8, p.file(), tail)) {
            p.count +|= 1;
            return;
        }
    }
    if (self.places_len == places_kept) {
        self.other_places +|= 1;
        return;
    }
    var p: Place = .{ .file_buf = undefined, .file_len = @intCast(tail.len), .line = line, .count = 1, .from_thread = from_thread };
    @memcpy(p.file_buf[0..tail.len], tail);
    self.places[self.places_len] = p;
    self.places_len += 1;
}

/// A frame begins, with `events` events to handle. On the UI thread.
pub fn frameBegin(self: *FrameCauses, events: usize) void {
    self.acquire();
    defer self.release();
    self.frames +|= 1;
    if (events > 0) {
        self.by_events +|= 1;
    } else if (self.pending > 0) {
        self.by_refresh +|= 1;
    } else self.by_other +|= 1;
    self.pending = 0;
}

/// As ZON: what the frames since the last `reset` were put down to, and the places that asked
/// for frames, most first (at most `top`).
pub fn write(self: *FrameCauses, w: *std.Io.Writer, indent: []const u8, top: usize) std.Io.Writer.Error!void {
    self.acquire();
    defer self.release();
    try w.print(".{{\n{s}    .frames = {d}, .by_events = {d}, .by_refresh = {d}, .by_other = {d},\n", .{ indent, self.frames, self.by_events, self.by_refresh, self.by_other });
    var order: [places_kept]u8 = undefined;
    for (0..self.places_len) |i| order[i] = @intCast(i);
    const Ctx = struct {
        places: []const Place,
        fn more(ctx: @This(), a: u8, b: u8) bool {
            return ctx.places[a].count > ctx.places[b].count;
        }
    };
    std.mem.sort(u8, order[0..self.places_len], Ctx{ .places = self.places[0..self.places_len] }, Ctx.more);
    try w.print("{s}    .refreshed_from = .{{\n", .{indent});
    for (order[0..@min(top, self.places_len)]) |i| {
        const p = &self.places[i];
        try w.print("{s}        .{{ .place = \"{s}:{d}\", .count = {d}{s} }},\n", .{ indent, p.file(), p.line, p.count, if (p.from_thread) ", .from_thread = true" else "" });
    }
    try w.print("{s}    }},\n", .{indent});
    if (self.other_places > 0) try w.print("{s}    .from_other_places = {d},\n", .{ indent, self.other_places });
    try w.print("{s}}}", .{indent});
}

test "a frame is put down to its events, else the refreshes before it, else something else" {
    var c: FrameCauses = .{};
    c.frameBegin(2);
    c.noteRefresh("src/editor/Editor.zig", 120, false);
    c.noteRefresh("src/editor/Editor.zig", 120, false);
    c.noteRefresh("plugins/text/src/Doc.zig", 9, true);
    c.frameBegin(0);
    c.frameBegin(0);
    try std.testing.expectEqual(@as(u32, 3), c.frames);
    try std.testing.expectEqual(@as(u32, 1), c.by_events);
    try std.testing.expectEqual(@as(u32, 1), c.by_refresh);
    try std.testing.expectEqual(@as(u32, 1), c.by_other);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try c.write(&out.writer, "", 8);
    const text = out.written();
    // The busiest place first.
    const editor = std.mem.indexOf(u8, text, "src/editor/Editor.zig:120\", .count = 2").?;
    const doc = std.mem.indexOf(u8, text, "plugins/text/src/Doc.zig:9\", .count = 1, .from_thread = true").?;
    try std.testing.expect(editor < doc);

    c.reset();
    try std.testing.expectEqual(@as(u32, 0), c.frames);
    try std.testing.expectEqual(@as(usize, 0), c.places_len);
}

test "a long path keeps its tail, and places past the kept ones are counted together" {
    var c: FrameCauses = .{};
    const long = "/a/very/long/path/that/goes/on/and/on/and/on/past/sixty/four/bytes/src/Thing.zig";
    c.noteRefresh(long, 1, false);
    try std.testing.expect(std.mem.endsWith(u8, c.places[0].file(), "src/Thing.zig"));
    for (0..places_kept + 3) |i| c.noteRefresh("x.zig", @intCast(i + 2), false);
    try std.testing.expectEqual(@as(usize, places_kept), c.places_len);
    try std.testing.expectEqual(@as(u32, 4), c.other_places);
}
