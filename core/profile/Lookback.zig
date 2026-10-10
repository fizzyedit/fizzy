//! What the frame profiler keeps past its half-second window (plans/DASHBOARD_PLAN.md, "Most
//! expensive" and "Hitches"): every scope's cost in each of the last `windows` half-second
//! windows, so a reader can ask what cost the most over the last 30 seconds rather than the last
//! half; and the frames whose work went over a budget, each with every scope's time in it, so a
//! spike is explained rather than averaged away.
//!
//! The profiler (`core.profile`) owns one, made the first time it records and published beside
//! it, so nothing is spent on it while nobody profiles. std-only, and fed plain numbers, so it
//! tests on its own (`fizzy-profile-lookback-tests`).
const Lookback = @This();

const std = @import("std");

/// Bumped whenever the layout changes: part of the key the profiler publishes it under, so a
/// plugin built against another layout finds none.
pub const abi: u32 = 1;
/// Half-second windows kept: 30 seconds.
pub const windows = 60;
/// Frames over budget kept, the newest replacing the oldest.
pub const hitches_kept = 16;

gpa: std.mem.Allocator,
/// How many entries each window and hitch has room for (the profiler's `max_entries`).
entries: usize,

/// Per window (`windows` of them), per entry: its time, its time less its children's, its calls,
/// and its slowest frame, in the window. Index `window * entries + entry`.
win_ns: []u32,
win_self_ns: []u32,
win_calls: []u32,
win_max_ns: []u32,
win: [windows]Window = @splat(.{}),
win_head: usize = 0,
win_filled: usize = 0,

/// Per hitch (`hitches_kept` of them), per entry: its time and calls in that frame. Index
/// `hitch * entries + entry`.
hitch_ns: []u32,
hitch_calls: []u16,
hitch: [hitches_kept]Hitch = @splat(.{}),
hitch_head: usize = 0,
hitch_filled: usize = 0,
/// A frame whose work takes longer than this is kept as a hitch: one 60 Hz frame by default.
budget_ns: u64 = std.time.ns_per_s / 60,

pub const Window = struct {
    /// When the window ended, on the profiler's clock.
    end_ns: i128 = 0,
    frames: u32 = 0,
    work_ns: u64 = 0,
    worst_work_ns: u64 = 0,
};

pub const Hitch = struct {
    /// When the frame ended, on the profiler's clock.
    at_ns: i128 = 0,
    work_ns: u64 = 0,
    /// How many entries it recorded (the profiler's count then).
    count: u16 = 0,
};

pub fn create(gpa: std.mem.Allocator, entries: usize) error{OutOfMemory}!*Lookback {
    const self = try gpa.create(Lookback);
    errdefer gpa.destroy(self);
    const win_n = windows * entries;
    const hitch_n = hitches_kept * entries;
    const win_ns = try gpa.alloc(u32, win_n);
    errdefer gpa.free(win_ns);
    const win_self_ns = try gpa.alloc(u32, win_n);
    errdefer gpa.free(win_self_ns);
    const win_calls = try gpa.alloc(u32, win_n);
    errdefer gpa.free(win_calls);
    const win_max_ns = try gpa.alloc(u32, win_n);
    errdefer gpa.free(win_max_ns);
    const hitch_ns = try gpa.alloc(u32, hitch_n);
    errdefer gpa.free(hitch_ns);
    const hitch_calls = try gpa.alloc(u16, hitch_n);
    self.* = .{
        .gpa = gpa,
        .entries = entries,
        .win_ns = win_ns,
        .win_self_ns = win_self_ns,
        .win_calls = win_calls,
        .win_max_ns = win_max_ns,
        .hitch_ns = hitch_ns,
        .hitch_calls = hitch_calls,
    };
    self.reset();
    return self;
}

pub fn destroy(self: *Lookback) void {
    const gpa = self.gpa;
    gpa.free(self.win_ns);
    gpa.free(self.win_self_ns);
    gpa.free(self.win_calls);
    gpa.free(self.win_max_ns);
    gpa.free(self.hitch_ns);
    gpa.free(self.hitch_calls);
    gpa.destroy(self);
}

/// Forget everything: the profiler's entries were forgotten too, and their indices mean
/// something else from now on.
pub fn reset(self: *Lookback) void {
    @memset(self.win_ns, 0);
    @memset(self.win_self_ns, 0);
    @memset(self.win_calls, 0);
    @memset(self.win_max_ns, 0);
    @memset(self.hitch_ns, 0);
    @memset(self.hitch_calls, 0);
    self.win = @splat(.{});
    self.win_head = 0;
    self.win_filled = 0;
    self.hitch = @splat(.{});
    self.hitch_head = 0;
    self.hitch_filled = 0;
}

/// Keep a half-second window as it closes. `per_entry` is the profiler's entries, each with the
/// window's totals (`win_ns`, `win_child_ns`, `win_calls`, `win_max_ns`) not yet cleared.
pub fn foldWindow(self: *Lookback, w: Window, per_entry: anytype) void {
    const at = self.win_head * self.entries;
    const n = @min(per_entry.len, self.entries);
    for (per_entry[0..n], 0..) |e, i| {
        self.win_ns[at + i] = clamp32(e.win_ns);
        self.win_self_ns[at + i] = clamp32(e.win_ns -| e.win_child_ns);
        self.win_calls[at + i] = clamp32(e.win_calls);
        self.win_max_ns[at + i] = clamp32(e.win_max_ns);
    }
    self.win[self.win_head] = w;
    self.win_head = (self.win_head + 1) % windows;
    self.win_filled = @min(self.win_filled + 1, windows);
}

/// Keep a frame if its work went over `budget_ns`, with every entry's time and calls in it.
pub fn noteFrame(self: *Lookback, at_ns: i128, work_ns: u64, ns: []const u32, calls: []const u16) void {
    if (work_ns <= self.budget_ns) return;
    const at = self.hitch_head * self.entries;
    const n = @min(ns.len, self.entries);
    @memcpy(self.hitch_ns[at..][0..n], ns[0..n]);
    @memcpy(self.hitch_calls[at..][0..n], calls[0..n]);
    self.hitch[self.hitch_head] = .{ .at_ns = at_ns, .work_ns = work_ns, .count = @intCast(n) };
    self.hitch_head = (self.hitch_head + 1) % hitches_kept;
    self.hitch_filled = @min(self.hitch_filled + 1, hitches_kept);
}

/// An entry's cost per frame over a span of windows.
pub const Cost = struct {
    avg_ns: f64 = 0,
    self_ns: f64 = 0,
    calls: f64 = 0,
    /// Its slowest single frame in the span.
    max_ns: u32 = 0,
};

/// The span `costs` covered.
pub const Span = struct {
    /// From the start of its oldest window to the end of its newest; 0 when nothing is kept yet.
    ns: i128 = 0,
    frames: u64 = 0,
    work_ns: f64 = 0,
    worst_work_ns: u64 = 0,
};

/// Each of the first `out.len` entries' cost per frame over the windows that ended in the last
/// `ms` milliseconds before the newest one ended (at least the newest), into `out`.
pub fn costs(self: *const Lookback, ms: u32, out: []Cost) Span {
    @memset(out, .{});
    if (self.win_filled == 0) return .{};
    const n = @min(out.len, self.entries);
    const newest = (self.win_head + windows - 1) % windows;
    const from_ns = self.win[newest].end_ns - @as(i128, ms) * std.time.ns_per_ms;
    var span: Span = .{};
    var oldest_end: i128 = self.win[newest].end_ns;
    var ago: usize = 0;
    while (ago < self.win_filled) : (ago += 1) {
        const slot = (self.win_head + windows - 1 - ago) % windows;
        const w = self.win[slot];
        if (ago > 0 and w.end_ns <= from_ns) break;
        span.frames += w.frames;
        span.work_ns += @floatFromInt(w.work_ns);
        span.worst_work_ns = @max(span.worst_work_ns, w.worst_work_ns);
        oldest_end = w.end_ns;
        const at = slot * self.entries;
        for (out[0..n], 0..) |*c, i| {
            c.avg_ns += @floatFromInt(self.win_ns[at + i]);
            c.self_ns += @floatFromInt(self.win_self_ns[at + i]);
            c.calls += @floatFromInt(self.win_calls[at + i]);
            c.max_ns = @max(c.max_ns, self.win_max_ns[at + i]);
        }
    }
    const frames: f64 = @floatFromInt(@max(span.frames, 1));
    for (out[0..n]) |*c| {
        c.avg_ns /= frames;
        c.self_ns /= frames;
        c.calls /= frames;
    }
    span.work_ns /= frames;
    // From the oldest window's start: its end less one window.
    span.ns = self.win[newest].end_ns - oldest_end + @as(i128, std.time.ns_per_s / 2);
    return span;
}

/// A kept hitch, `ago` back (0 the newest): its frame's work, and each entry's time and calls.
pub fn hitchAt(self: *const Lookback, ago: usize) ?struct { at_ns: i128, work_ns: u64, ns: []const u32, calls: []const u16 } {
    if (ago >= self.hitch_filled) return null;
    const slot = (self.hitch_head + hitches_kept - 1 - ago) % hitches_kept;
    const h = self.hitch[slot];
    const at = slot * self.entries;
    return .{ .at_ns = h.at_ns, .work_ns = h.work_ns, .ns = self.hitch_ns[at..][0..h.count], .calls = self.hitch_calls[at..][0..h.count] };
}

fn clamp32(v: u64) u32 {
    return @intCast(@min(v, std.math.maxInt(u32)));
}

const TestEntry = struct { win_ns: u64, win_child_ns: u64 = 0, win_calls: u64 = 1, win_max_ns: u64 = 0 };

test "costs average the windows that ended within the asked span" {
    const lb = try create(std.testing.allocator, 4);
    defer lb.destroy();
    const half = std.time.ns_per_s / 2;
    // Three windows, ten frames each: entry 0 costs 10, 20, then 30 ms in total per window.
    for (0..3) |k| {
        const ms_total: u64 = 10 * (k + 1);
        lb.foldWindow(.{ .end_ns = @intCast(half * (k + 1)), .frames = 10, .work_ns = 50 * std.time.ns_per_ms, .worst_work_ns = 8 * std.time.ns_per_ms }, &[_]TestEntry{
            .{ .win_ns = ms_total * std.time.ns_per_ms, .win_child_ns = std.time.ns_per_ms, .win_calls = 10, .win_max_ns = (k + 2) * std.time.ns_per_ms },
        });
    }
    var out: [2]Cost = undefined;
    // The newest window only.
    var span = lb.costs(0, &out);
    try std.testing.expectEqual(@as(u64, 10), span.frames);
    try std.testing.expectApproxEqAbs(@as(f64, 3 * std.time.ns_per_ms), out[0].avg_ns, 1);
    try std.testing.expectApproxEqAbs(@as(f64, 2.9 * std.time.ns_per_ms), out[0].self_ns, 1);
    // All three: (10 + 20 + 30) ms over 30 frames, the worst of their slowest frames.
    span = lb.costs(1500, &out);
    try std.testing.expectEqual(@as(u64, 30), span.frames);
    try std.testing.expectApproxEqAbs(@as(f64, 2 * std.time.ns_per_ms), out[0].avg_ns, 1);
    try std.testing.expectEqual(@as(u32, 4 * std.time.ns_per_ms), out[0].max_ns);
    try std.testing.expectApproxEqAbs(@as(f64, 1), out[0].calls, 1e-9);
    try std.testing.expectEqual(@as(f64, 0), out[1].avg_ns);
    try std.testing.expectEqual(@as(i128, 3 * half), span.ns);
}

test "the ring keeps the newest windows" {
    const lb = try create(std.testing.allocator, 1);
    defer lb.destroy();
    for (0..windows + 5) |k| lb.foldWindow(.{ .end_ns = @intCast(k + 1), .frames = 1 }, &[_]TestEntry{.{ .win_ns = k }});
    try std.testing.expectEqual(@as(usize, windows), lb.win_filled);
    var out: [1]Cost = undefined;
    _ = lb.costs(0, &out);
    try std.testing.expectEqual(@as(f64, windows + 4), out[0].avg_ns);
}

test "only frames over budget are kept as hitches, newest first" {
    const lb = try create(std.testing.allocator, 3);
    defer lb.destroy();
    lb.budget_ns = 10;
    lb.noteFrame(1, 5, &.{ 1, 2, 3 }, &.{ 1, 1, 1 });
    try std.testing.expectEqual(@as(?@TypeOf(lb.hitchAt(0).?), null), lb.hitchAt(0));
    lb.noteFrame(2, 20, &.{ 4, 5 }, &.{ 1, 2 });
    lb.noteFrame(3, 30, &.{ 7, 8, 9 }, &.{ 3, 3, 3 });
    const h = lb.hitchAt(0).?;
    try std.testing.expectEqual(@as(u64, 30), h.work_ns);
    try std.testing.expectEqualSlices(u32, &.{ 7, 8, 9 }, h.ns);
    try std.testing.expectEqualSlices(u32, &.{ 4, 5 }, lb.hitchAt(1).?.ns);
    try std.testing.expectEqual(@as(?@TypeOf(h), null), lb.hitchAt(2));
    lb.reset();
    try std.testing.expectEqual(@as(?@TypeOf(h), null), lb.hitchAt(0));
}
