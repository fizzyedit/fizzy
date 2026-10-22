//! A record of the last frames, always kept: for each one when it began, how long its work took,
//! which input events it was drawn for, and the scopes that cost the most in it. Where `Lookback`
//! keeps the frames that went over budget and `FrameCauses` counts who asked for frames, this keeps
//! every frame in order, so a frame that is wanted by what caused it (the pen coming up, a key) can
//! be found and read after the fact, with no profiler window open and nobody having asked first.
//!
//! A fixed ring in the image's own data: nothing is allocated per frame and a frame costs a few
//! dozen bytes of writes. The profiler (`core.profile`) owns the host's and publishes it beside
//! itself, under its own key as `FrameCauses` is, so the profiler's layout is untouched. Scopes are
//! kept as entry indices into the profiler's entries, which stay put until the profiler is reset
//! (the record is then too). std-only, fed plain numbers, so it tests on its own.
const FrameRecord = @This();

const std = @import("std");

/// Bumped whenever the layout changes: part of the key the profiler publishes it under.
pub const abi: u32 = 1;
/// Frames kept: a few seconds at 60 Hz, the newest replacing the oldest.
pub const capacity = 256;
/// The costliest scopes kept per frame, by their own time.
pub const scopes_kept = 8;

/// The kinds of input event a frame can have been drawn for. A frame has the set of them it
/// handled, less the pointer's `position` event dvui adds to every frame (it causes nothing).
pub const Kinds = packed struct(u16) {
    press: bool = false,
    release: bool = false,
    motion: bool = false,
    wheel: bool = false,
    key_down: bool = false,
    key_up: bool = false,
    text: bool = false,
    focus: bool = false,
    window: bool = false,
    app: bool = false,
    _: u6 = 0,

    pub fn any(self: Kinds) bool {
        return @as(u16, @bitCast(self)) != 0;
    }

    /// Whether every kind in `want` is in this.
    pub fn has(self: Kinds, want: Kinds) bool {
        return @as(u16, @bitCast(self)) & @as(u16, @bitCast(want)) == @as(u16, @bitCast(want));
    }
};

pub const Scope = struct {
    /// An index into the profiler's entries.
    entry: u16,
    /// Its own time in the frame, less its children's.
    self_ns: u32,
};

pub const Frame = struct {
    /// Counted from 1 since the record was made or reset.
    number: u64 = 0,
    /// When the frame began, on the profiler's clock.
    began_ns: i128 = 0,
    /// Inside fizzy's frame (`core.profile.hostFrameBegin` … `hostFrameEnd`).
    work_ns: u32 = 0,
    /// The input events it handled, and of which kinds. No kinds: something asked for it, a
    /// `dvui.refresh` or a timer coming due (`FrameCauses` says which).
    events: u16 = 0,
    kinds: Kinds = .{},
    /// Whether the scopes below were timed: not in a frame the profiler was paused or frozen for.
    scoped: bool = false,
    scope_len: u8 = 0,
    /// The costliest first.
    scopes: [scopes_kept]Scope = undefined,

    pub fn costliest(self: *const Frame) []const Scope {
        return self.scopes[0..self.scope_len];
    }
};

frames: [capacity]Frame = @splat(.{}),
/// The next slot to write.
head: usize = 0,
filled: usize = 0,
/// Frames begun since the last reset.
count: u64 = 0,
open: Frame = .{},
is_open: bool = false,

pub fn reset(self: *FrameRecord) void {
    self.* = .{};
}

/// A frame begins, on the UI thread, with the input events it handles.
pub fn begin(self: *FrameRecord, at_ns: i128, events: u16, kinds: Kinds) void {
    self.count += 1;
    self.open = .{ .number = self.count, .began_ns = at_ns, .events = events, .kinds = kinds };
    self.is_open = true;
}

/// A scope's own time in the frame in progress, to be kept if it is among the costliest. Entries
/// are offered in any order; a scope that took no time is not kept.
pub fn noteScope(self: *FrameRecord, entry: u16, self_ns: u64) void {
    const f = &self.open;
    f.scoped = true;
    if (self_ns == 0) return;
    const ns: u32 = @intCast(@min(self_ns, std.math.maxInt(u32)));
    var at: usize = f.scope_len;
    while (at > 0 and f.scopes[at - 1].self_ns < ns) at -= 1;
    if (at >= scopes_kept) return;
    const last = @min(f.scope_len, scopes_kept - 1);
    var i: usize = last;
    while (i > at) : (i -= 1) f.scopes[i] = f.scopes[i - 1];
    f.scopes[at] = .{ .entry = entry, .self_ns = ns };
    f.scope_len = @intCast(@min(@as(usize, f.scope_len) + 1, scopes_kept));
}

/// The frame in progress ends, having taken `work_ns`: it joins the record.
pub fn end(self: *FrameRecord, work_ns: u64) void {
    if (!self.is_open) return;
    self.is_open = false;
    self.open.work_ns = @intCast(@min(work_ns, std.math.maxInt(u32)));
    self.frames[self.head] = self.open;
    self.head = (self.head + 1) % capacity;
    self.filled = @min(self.filled + 1, capacity);
}

/// The frame `ago` frames back (0 the latest finished). Null past what is kept.
pub fn get(self: *const FrameRecord, ago: usize) ?*const Frame {
    if (ago >= self.filled) return null;
    return &self.frames[(self.head + capacity - 1 - ago) % capacity];
}

/// The newest finished frame that handled every kind in `kinds` and is newer than frame number
/// `after` (0 for any): how a test finds the frame the pen came up in.
pub fn latestWith(self: *const FrameRecord, kinds: Kinds, after: u64) ?*const Frame {
    var ago: usize = 0;
    while (self.get(ago)) |f| : (ago += 1) {
        if (f.number <= after) return null;
        if (f.kinds.has(kinds)) return f;
    }
    return null;
}

/// The number of the newest finished frame, 0 when none: take it before an action and ask
/// `latestWith` for what came after.
pub fn newest(self: *const FrameRecord) u64 {
    return if (self.get(0)) |f| f.number else 0;
}

fn writeKinds(k: Kinds, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(".{");
    var first = true;
    inline for (.{ "press", "release", "motion", "wheel", "key_down", "key_up", "text", "focus", "window", "app" }) |name| {
        if (@field(k, name)) {
            try w.print("{s} \"{s}\"", .{ if (first) "" else ",", name });
            first = false;
        }
    }
    try w.writeAll(" }");
}

/// As ZON, the newest `last` frames, newest first. `names` resolves a scope's entry index to its
/// owner and name (the profiler's entries), null for one since forgotten.
pub fn write(
    self: *const FrameRecord,
    w: *std.Io.Writer,
    last: usize,
    ctx: anytype,
    comptime names: fn (@TypeOf(ctx), u16) ?[2][]const u8,
) std.Io.Writer.Error!void {
    try w.print(".{{\n    .capacity = {d}, .frames_seen = {d},\n    .frames = .{{\n", .{ capacity, self.count });
    var ago: usize = 0;
    while (ago < last) : (ago += 1) {
        const f = self.get(ago) orelse break;
        try w.print("        .{{ .frame = {d}, .work_ms = {d:.3}, .events = {d}, .cause = \"{s}\", .kinds = ", .{
            f.number, @as(f64, @floatFromInt(f.work_ns)) / std.time.ns_per_ms, f.events, if (f.kinds.any()) "input" else "refresh_or_timer",
        });
        try writeKinds(f.kinds, w);
        try w.writeAll(", .scopes = .{");
        for (f.costliest(), 0..) |s, i| {
            const n = names(ctx, s.entry) orelse .{ "?", "?" };
            try w.print("{s} .{{ .scope = \"{f}.{f}\", .self_ms = {d:.3} }}", .{
                if (i == 0) "" else ",",                                 std.zig.fmtString(n[0]), std.zig.fmtString(n[1]),
                @as(f64, @floatFromInt(s.self_ns)) / std.time.ns_per_ms,
            });
        }
        try w.writeAll(" } },\n");
    }
    try w.writeAll("    },\n}\n");
}

fn testNames(_: void, entry: u16) ?[2][]const u8 {
    return if (entry == 3) .{ "fizzy", "draw" } else null;
}

test "frames are kept in order and the ring wraps, keeping the newest" {
    var r: FrameRecord = .{};
    for (0..capacity + 10) |i| {
        r.begin(@intCast(i), 0, .{});
        r.end(i);
    }
    try std.testing.expectEqual(@as(u64, capacity + 10), r.count);
    try std.testing.expectEqual(@as(usize, capacity), r.filled);
    try std.testing.expectEqual(@as(u64, capacity + 10), r.get(0).?.number);
    try std.testing.expectEqual(@as(u64, 11), r.get(capacity - 1).?.number);
    try std.testing.expectEqual(@as(?*const Frame, null), r.get(capacity));
    try std.testing.expectEqual(@as(u32, capacity + 9), r.get(0).?.work_ns);
    r.reset();
    try std.testing.expectEqual(@as(?*const Frame, null), r.get(0));
}

test "a frame keeps its costliest scopes, costliest first" {
    var r: FrameRecord = .{};
    r.begin(0, 1, .{ .release = true });
    for (0..20) |i| r.noteScope(@intCast(i), (i * 37) % 11 * 100 + 1);
    r.noteScope(99, 0);
    r.end(5);
    const f = r.get(0).?;
    try std.testing.expect(f.scoped);
    try std.testing.expectEqual(@as(usize, scopes_kept), f.costliest().len);
    var prev: u32 = std.math.maxInt(u32);
    for (f.costliest()) |s| {
        try std.testing.expect(s.self_ns <= prev);
        prev = s.self_ns;
    }
    try std.testing.expectEqual(@as(u32, 1001), f.costliest()[0].self_ns);
}

test "the frame a kind of event caused is found, and only frames after the one asked from" {
    var r: FrameRecord = .{};
    r.begin(0, 1, .{ .press = true });
    r.end(1);
    const before = r.newest();
    r.begin(1, 0, .{});
    r.end(1);
    r.begin(2, 2, .{ .release = true, .motion = true });
    r.noteScope(3, 2_500_000);
    r.end(4_000_000);
    r.begin(3, 0, .{});
    r.end(1);
    try std.testing.expect(r.latestWith(.{ .press = true }, before) == null);
    const f = r.latestWith(.{ .release = true }, before).?;
    try std.testing.expectEqual(@as(u64, 3), f.number);
    try std.testing.expectEqual(@as(u16, 2), f.events);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try r.write(&out.writer, 2, {}, testNames);
    try std.testing.expect(std.mem.find(u8, out.written(), ".cause = \"input\", .kinds = .{ \"release\", \"motion\" }, .scopes = .{ .{ .scope = \"fizzy.draw\", .self_ms = 2.500 } }") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), ".cause = \"refresh_or_timer\"") != null);
}
