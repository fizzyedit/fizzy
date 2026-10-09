//! What the native backend has done since it started, kept current as it goes: frames, presents,
//! swapchain resizes, what SDL logged, how long frames took, and how much each frame asked of the
//! GPU. Anything can read it (`SDLBackend.health`, a `Snapshot`): a run that ends in a verdict, a
//! benchmark, the live-resize trace (`SDLBackend.live_resize_trace`).
//!
//! Nobody turns it on. What the frame pays is integer increments on memory the backend touches
//! anyway and one clock read at each end of the frame, with no allocation and no lock; the
//! counters SDL's log feeds are atomic, since SDL may log from any thread. Everything that costs
//! more — sorting frame times into percentiles, asking SDL and AppKit how many windows are alive —
//! happens when a snapshot is taken.
//!
//! std-only, so its arithmetic is tested without a window (`fizzy-backend-health-tests`).
const std = @import("std");

const Health = @This();

/// The one the backend keeps.
pub var current: Health = .{};

/// How many frame times the percentiles are taken over: the last this many frames.
pub const frame_window = 512;
/// How much of the first error SDL logged is kept.
pub const first_error_cap = 256;

/// Frames the backend ran (`frameBegin`): the number of the frame in flight, while one is.
frames: u64 = 0,
/// Frames whose picture reached the main window: a drawable was acquired and submitted.
presents: u64 = 0,
/// Frames that ended with no drawable for the main window — minimized, occluded, held, or the
/// acquire failed — so the window kept its last picture.
presents_skipped: u64 = 0,
/// Pictures handed to other OS windows (a float popped out, a menu, a dialog: `Viewport`).
viewport_presents: u64 = 0,
/// Times the main window's drawable came back a different size from the last one: the swapchain
/// was recreated for a resize, a scale change or full screen.
swapchain_resizes: u64 = 0,
/// Times the swapchain's parameters were set again (vsync on or off), which recreates it too.
swapchain_reconfigures: u64 = 0,

/// What the frame in flight has asked of the GPU so far; folded into `last`, `peak` and `total`
/// as it ends.
counts: Counts = .{},
last: Counts = .{},
peak: Counts = .{},
total: Counts = .{},

frame_start_ns: u64 = 0,
/// Frame times, ns, as a ring: `frame_ns_written` is how many were ever written.
frame_ns: [frame_window]u32 = @splat(0),
frame_ns_written: u64 = 0,

/// Messages SDL logged at error or critical priority, and at warning priority, through its log
/// output (`SDLBackend.enableSDLLogging`). Only what SDL's priorities let through is seen: errors
/// always, warnings where fizzy's log level shows them.
sdl_errors: std.atomic.Value(u32) = .init(0),
sdl_warnings: std.atomic.Value(u32) = .init(0),
/// The first error's text, set once: `first_error_len` is published after the bytes are written.
first_error: [first_error_cap]u8 = undefined,
first_error_len: std.atomic.Value(u32) = .init(0),
first_error_claimed: std.atomic.Value(bool) = .init(false),

/// What a frame asks of the GPU, counted as it is recorded (`GpuRenderer`). Deterministic for a
/// given scene, so a run can hold them to a budget where it cannot hold times.
pub const Counts = struct {
    /// Render passes encoded: one per destination change, plus the clears a target owes.
    passes: u32 = 0,
    /// Indexed draws issued, after consecutive draws that could merge did.
    draws: u32 = 0,
    /// Times the destination changed from one target (or the window) to another.
    target_switches: u32 = 0,
    /// Texture creations and updates uploaded.
    uploads: u32 = 0,

    fn add(a: *Counts, b: Counts) void {
        inline for (std.meta.fields(Counts)) |f| @field(a, f.name) +|= @field(b, f.name);
    }

    fn max(a: *Counts, b: Counts) void {
        inline for (std.meta.fields(Counts)) |f| @field(a, f.name) = @max(@field(a, f.name), @field(b, f.name));
    }
};

pub const Priority = enum { warning, @"error" };

/// Frame times over the last frames, in microseconds.
pub const FrameTimes = struct {
    samples: u32 = 0,
    p50_us: u32 = 0,
    p95_us: u32 = 0,
    p99_us: u32 = 0,
    max_us: u32 = 0,
};

/// What `snapshot` read: plain data, written as ZON as it is (`std.zon.stringify`).
pub const Snapshot = struct {
    frames: u64 = 0,
    presents: u64 = 0,
    presents_skipped: u64 = 0,
    viewport_presents: u64 = 0,
    swapchain_resizes: u64 = 0,
    swapchain_reconfigures: u64 = 0,
    /// OS windows SDL has alive: the main window and every viewport's.
    os_windows: u32 = 0,
    /// macOS: the windows AppKit holds (`NSApp.windows`), and how many of them are on screen. A
    /// window SDL let go of that something still holds shows here and not in `os_windows`.
    ns_windows: ?u32 = null,
    ns_windows_visible: ?u32 = null,
    sdl_errors: u32 = 0,
    sdl_warnings: u32 = 0,
    first_sdl_error: []const u8 = "",
    /// Each frame's time from its start to its present returning, which includes waiting for
    /// the drawable: under vsync, a frame that is quick to build still takes a display interval.
    frame_times: FrameTimes = .{},
    /// The last frame's GPU work, the most any frame asked, and all of it.
    last_frame: Counts = .{},
    peak_frame: Counts = .{},
    total: Counts = .{},
};

// ---------------------------------------------------------------------------------------------
// Kept by the backend, every frame

pub fn frameBegin(self: *Health, now_ns: u64) void {
    self.frames += 1;
    self.frame_start_ns = now_ns;
    self.counts = .{};
}

/// The frame presented (or had nothing to present into): its time goes into the ring and its
/// counts into `last`, `peak` and `total`.
pub fn frameEnd(self: *Health, now_ns: u64) void {
    const took = now_ns -| self.frame_start_ns;
    self.frame_ns[@intCast(self.frame_ns_written % frame_window)] = @intCast(@min(took, std.math.maxInt(u32)));
    self.frame_ns_written += 1;
    self.last = self.counts;
    self.peak.max(self.counts);
    self.total.add(self.counts);
}

/// How long the last frame took, ns (0 before the first has ended).
pub fn lastFrameNs(self: *const Health) u32 {
    if (self.frame_ns_written == 0) return 0;
    return self.frame_ns[@intCast((self.frame_ns_written - 1) % frame_window)];
}

/// A message SDL logged at `priority`. Any thread.
pub fn noteLog(self: *Health, priority: Priority, message: []const u8) void {
    switch (priority) {
        .warning => _ = self.sdl_warnings.fetchAdd(1, .monotonic),
        .@"error" => {
            _ = self.sdl_errors.fetchAdd(1, .monotonic);
            if (self.first_error_claimed.swap(true, .acquire)) return;
            const n = @min(message.len, first_error_cap);
            @memcpy(self.first_error[0..n], message[0..n]);
            self.first_error_len.store(@intCast(n), .release);
        },
    }
}

// ---------------------------------------------------------------------------------------------
// Read

/// What the counters hold now. The window counts are the caller's to fill in (the backend asks
/// SDL and AppKit); everything here is read without a lock, so a count SDL's log moves on another
/// thread meanwhile may be one behind.
pub fn snapshot(self: *const Health) Snapshot {
    const err_len = self.first_error_len.load(.acquire);
    return .{
        .frames = self.frames,
        .presents = self.presents,
        .presents_skipped = self.presents_skipped,
        .viewport_presents = self.viewport_presents,
        .swapchain_resizes = self.swapchain_resizes,
        .swapchain_reconfigures = self.swapchain_reconfigures,
        .sdl_errors = self.sdl_errors.load(.monotonic),
        .sdl_warnings = self.sdl_warnings.load(.monotonic),
        .first_sdl_error = self.first_error[0..err_len],
        .frame_times = self.frameTimes(),
        .last_frame = self.last,
        .peak_frame = self.peak,
        .total = self.total,
    };
}

pub fn frameTimes(self: *const Health) FrameTimes {
    const n: usize = @intCast(@min(self.frame_ns_written, frame_window));
    var sorted: [frame_window]u32 = undefined;
    @memcpy(sorted[0..n], self.frame_ns[0..n]);
    return percentiles(sorted[0..n]);
}

/// Nearest-rank percentiles of `ns` (sorted in place), in microseconds.
pub fn percentiles(ns: []u32) FrameTimes {
    if (ns.len == 0) return .{};
    std.mem.sort(u32, ns, {}, std.sort.asc(u32));
    return .{
        .samples = @intCast(ns.len),
        .p50_us = rank(ns, 50) / std.time.ns_per_us,
        .p95_us = rank(ns, 95) / std.time.ns_per_us,
        .p99_us = rank(ns, 99) / std.time.ns_per_us,
        .max_us = ns[ns.len - 1] / std.time.ns_per_us,
    };
}

/// The smallest value at least `p` percent of `sorted` is at or below.
fn rank(sorted: []const u32, comptime p: u32) u32 {
    const at = std.math.divCeil(usize, sorted.len * p, 100) catch unreachable;
    return sorted[@max(at, 1) - 1];
}

// ---------------------------------------------------------------------------------------------
// Tests

test "percentiles are nearest-rank over what was recorded" {
    var ns: [100]u32 = undefined;
    // 1..100 µs, shuffled.
    for (&ns, 0..) |*v, i| v.* = @intCast(((i * 37) % 100 + 1) * std.time.ns_per_us);
    const t = percentiles(&ns);
    try std.testing.expectEqual(@as(u32, 100), t.samples);
    try std.testing.expectEqual(@as(u32, 50), t.p50_us);
    try std.testing.expectEqual(@as(u32, 95), t.p95_us);
    try std.testing.expectEqual(@as(u32, 99), t.p99_us);
    try std.testing.expectEqual(@as(u32, 100), t.max_us);

    var one = [_]u32{7 * std.time.ns_per_us};
    const o = percentiles(&one);
    try std.testing.expectEqual(@as(u32, 7), o.p50_us);
    try std.testing.expectEqual(@as(u32, 7), o.p99_us);
    try std.testing.expectEqual(FrameTimes{}, percentiles(&.{}));
}

test "frame times are the last frame_window frames" {
    var h: Health = .{};
    try std.testing.expectEqual(@as(u32, 0), h.lastFrameNs());
    // frame_window frames of 1 ms, then as many of 3 ms: only the 3 ms ones are left.
    var t: u64 = 0;
    for (0..2 * frame_window) |i| {
        h.frameBegin(t);
        t += if (i < frame_window) std.time.ns_per_ms else 3 * std.time.ns_per_ms;
        h.frameEnd(t);
    }
    try std.testing.expectEqual(@as(u64, 2 * frame_window), h.frames);
    const ft = h.snapshot().frame_times;
    try std.testing.expectEqual(@as(u32, frame_window), ft.samples);
    try std.testing.expectEqual(@as(u32, 3000), ft.p50_us);
    try std.testing.expectEqual(@as(u32, 3000), ft.max_us);
    try std.testing.expectEqual(@as(u32, 3 * std.time.ns_per_ms), h.lastFrameNs());
}

test "a frame's counts become last, peak and total as it ends" {
    var h: Health = .{};
    h.frameBegin(0);
    h.counts.draws += 10;
    h.counts.passes += 2;
    h.frameEnd(1);
    h.frameBegin(2);
    h.counts.draws += 4;
    h.counts.passes += 3;
    h.counts.target_switches += 1;
    h.frameEnd(3);
    const s = h.snapshot();
    try std.testing.expectEqual(Counts{ .draws = 4, .passes = 3, .target_switches = 1 }, s.last_frame);
    try std.testing.expectEqual(Counts{ .draws = 10, .passes = 3, .target_switches = 1 }, s.peak_frame);
    try std.testing.expectEqual(Counts{ .draws = 14, .passes = 5, .target_switches = 1 }, s.total);
    // A frame begun is counted from nothing.
    h.frameBegin(4);
    try std.testing.expectEqual(Counts{}, h.counts);
}

test "SDL's log is counted from any thread, and the first error kept" {
    var h: Health = .{};
    h.noteLog(.warning, "a warning");
    try std.testing.expectEqualStrings("", h.snapshot().first_sdl_error);

    const threads = 8;
    const each = 1000;
    var pool: [threads]std.Thread = undefined;
    for (&pool) |*th| th.* = try std.Thread.spawn(.{}, struct {
        fn run(hp: *Health) void {
            for (0..each) |_| {
                hp.noteLog(.@"error", "x" ** (first_error_cap + 10));
                hp.noteLog(.warning, "w");
            }
        }
    }.run, .{&h});
    for (pool) |th| th.join();

    const s = h.snapshot();
    try std.testing.expectEqual(@as(u32, threads * each), s.sdl_errors);
    try std.testing.expectEqual(@as(u32, threads * each + 1), s.sdl_warnings);
    // Cut to the cap, written once.
    try std.testing.expectEqualStrings("x" ** first_error_cap, s.first_sdl_error);
}

test "a snapshot round-trips through ZON" {
    var h: Health = .{};
    h.frameBegin(0);
    h.counts.draws = 3;
    h.frameEnd(2 * std.time.ns_per_ms);
    h.presents = 1;
    h.noteLog(.@"error", "Vulkan: device \"lost\"");
    var s = h.snapshot();
    s.os_windows = 2;
    s.ns_windows = 3;

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.zon.stringify.serialize(s, .{}, &out.writer);
    const text = try std.testing.allocator.dupeZ(u8, out.written());
    defer std.testing.allocator.free(text);
    const back = try std.zon.parse.fromSliceAlloc(Snapshot, std.testing.allocator, text, null, .{});
    defer std.zon.parse.free(std.testing.allocator, back);
    try std.testing.expectEqual(s.presents, back.presents);
    try std.testing.expectEqual(s.os_windows, back.os_windows);
    try std.testing.expectEqual(s.ns_windows, back.ns_windows);
    try std.testing.expectEqual(s.ns_windows_visible, back.ns_windows_visible);
    try std.testing.expectEqual(s.frame_times, back.frame_times);
    try std.testing.expectEqual(s.last_frame, back.last_frame);
    try std.testing.expectEqualStrings(s.first_sdl_error, back.first_sdl_error);
}
