//! Spans on any thread, each occurrence kept (plans/DASHBOARD_PLAN.md, "What performance work
//! lacked"): the profiler's scopes time the UI thread and average it per window, so work off it (a
//! checkpoint's write, a plugin reload's open, a download) showed only as a worst frame, if at
//! all. A span is one start and end, with its thread and its name, kept in a ring of the last
//! `capacity`: read back as a list, summed by name, drawn as a timeline, or written as a Chrome
//! trace that Perfetto (ui.perfetto.dev) and chrome://tracing open.
//!
//! Writers on any thread take a slot with one atomic add and stamp it with its sequence number
//! last; a reader skips a slot whose stamp changed while it read, so a write in progress is never
//! read half done. Nothing is written while `on` is false, which the profiler sets: a span costs
//! one atomic load when nobody is recording.
//!
//! std-only, clock included, so it tests on its own (`fizzy-profile-spans-tests`) and code with
//! no dvui (`core.transport`) can time itself. The profiler (`core.profile`) owns one, switches it
//! on and off, and hands it to every image (`image`); `span` is how anything records into it.
const Spans = @This();

const std = @import("std");
const builtin = @import("builtin");

/// Bumped whenever the layout changes: part of the key the profiler publishes it under.
pub const abi: u32 = 1;
/// Spans kept, the newest replacing the oldest.
pub const capacity = 16 * 1024;
/// Bytes of a span's name kept: a longer one is cut.
pub const name_cap = 47;

gpa: std.mem.Allocator,
records: []Record,
/// How many spans were ever written: the next one's sequence number. Word-sized, as every atomic
/// here is: the web's wasm32 has no 64-bit ones.
next: std.atomic.Value(usize) = .init(0),
/// Recording: the profiler sets it each frame (its window open, or someone asked).
on: std.atomic.Value(bool) = .init(false),
/// The UI thread's id, so a trace can name it.
ui_thread: std.atomic.Value(usize) = .init(0),

pub const Record = struct {
    /// 0 while empty or being written; else the span's sequence number plus one, stored last.
    stamp: std.atomic.Value(usize) = .init(0),
    start_ns: i64 = 0,
    end_ns: i64 = 0,
    thread: usize = 0,
    name_len: u8 = 0,
    name: [name_cap]u8 = undefined,
};

/// A span read back. `name` is the reader's copy.
pub const Span = struct {
    name: []const u8,
    start_ns: i64,
    end_ns: i64,
    thread: usize,
};

/// The spans this image records into, for any of its threads: an atomic, so a worker thread finds
/// it with no window to ask. Each image has its own copy of this file; the profiler sets the
/// host's, and a plugin's on the UI thread before the plugin draws (`core.profile.adopt`).
pub var image: std.atomic.Value(usize) = .init(0);

/// The spans this image records into, from any thread. Null until the profiler has recorded, or
/// in a plugin built before spans.
pub fn current() ?*Spans {
    const addr = image.load(.acquire);
    return if (addr == 0) null else @ptrFromInt(addr);
}

/// A span in progress; `end` it (deferred) where the timed work ends.
pub const Open = struct {
    spans: ?*Spans = null,
    name: []const u8 = "",
    start_ns: i64 = 0,

    pub fn end(self: Open) void {
        const sp = self.spans orelse return;
        sp.add(self.name, self.start_ns, now(), threadId());
    }
};

/// Time from here to `end` as `name`, on whatever thread this is, kept as one occurrence beside
/// every other: work off the UI thread, or anything whose each run matters rather than its
/// average. Nothing is kept unless the profiler is recording; then the first `name_cap` bytes of
/// `name` are copied at `end`, so it may be built in a buffer that lives until then.
///
///     const s = core.profile.span("checkpoint write");
///     defer s.end();
pub fn span(name: []const u8) Open {
    const sp = current() orelse return .{};
    if (!sp.on.load(.monotonic)) return .{};
    return .{ .spans = sp, .name = name, .start_ns = now() };
}

/// The boot clock, in nanoseconds: the same on every thread, with no `Io` to hand around. The web
/// reads the page's clock (`performance.now`), as `core` does elsewhere.
pub fn now() i64 {
    return if (comptime builtin.target.cpu.arch == .wasm32)
        @intFromFloat(wasm.wasm_now() * 1_000_000.0)
    else
        @intCast(std.Io.Clock.boot.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds);
}

const wasm = struct {
    extern "dvui" fn wasm_now() f64;
};

pub fn threadId() usize {
    return if (comptime builtin.single_threaded) 0 else @intCast(std.Thread.getCurrentId());
}

/// A store and a load another thread may race with: atomic, or plain where there is one thread
/// (the web, which has no 64-bit atomics).
fn put(comptime T: type, p: *T, v: T) void {
    if (comptime builtin.single_threaded) p.* = v else @atomicStore(T, p, v, .monotonic);
}
fn get(comptime T: type, p: *const T) T {
    return if (comptime builtin.single_threaded) p.* else @atomicLoad(T, p, .monotonic);
}

pub fn create(gpa: std.mem.Allocator) error{OutOfMemory}!*Spans {
    const self = try gpa.create(Spans);
    errdefer gpa.destroy(self);
    const records = try gpa.alloc(Record, capacity);
    @memset(records, .{});
    self.* = .{ .gpa = gpa, .records = records };
    return self;
}

pub fn destroy(self: *Spans) void {
    self.gpa.free(self.records);
    self.gpa.destroy(self);
}

/// Keep a span. From any thread; nothing while `on` is false.
pub fn add(self: *Spans, name: []const u8, start_ns: i64, end_ns: i64, thread: usize) void {
    if (!self.on.load(.monotonic)) return;
    const seq = self.next.fetchAdd(1, .monotonic);
    const r = &self.records[@intCast(seq % capacity)];
    // Mark it unreadable before changing it; a reader that saw the old stamp sees it change.
    r.stamp.store(0, .release);
    const n: u8 = @intCast(@min(name.len, name_cap));
    put(i64, &r.start_ns, start_ns);
    put(i64, &r.end_ns, end_ns);
    put(usize, &r.thread, thread);
    put(u8, &r.name_len, n);
    for (r.name[0..n], name[0..n]) |*d, c| put(u8, d, c);
    r.stamp.store(seq + 1, .release);
}

/// The kept spans that ended at or after `since_ns`, oldest start first, copied into `arena`.
pub fn collect(self: *const Spans, arena: std.mem.Allocator, since_ns: i64) error{OutOfMemory}![]Span {
    var out: std.ArrayList(Span) = .empty;
    const written = self.next.load(.acquire);
    const kept = @min(written, capacity);
    var k: usize = 0;
    while (k < kept) : (k += 1) {
        const seq = written - kept + k;
        const r = &self.records[@intCast(seq % capacity)];
        if (r.stamp.load(.acquire) != seq + 1) continue;
        var name_buf: [name_cap]u8 = undefined;
        const n = get(u8, &r.name_len);
        for (name_buf[0..n], r.name[0..n]) |*d, *c| d.* = get(u8, c);
        const read: Span = .{
            .name = name_buf[0..n],
            .start_ns = get(i64, &r.start_ns),
            .end_ns = get(i64, &r.end_ns),
            .thread = get(usize, &r.thread),
        };
        // Written again while it was read: skip it rather than return a mix of two spans.
        if (r.stamp.load(.acquire) != seq + 1) continue;
        if (read.end_ns < since_ns) continue;
        var kept_span = read;
        kept_span.name = try arena.dupe(u8, read.name);
        try out.append(arena, kept_span);
    }
    std.mem.sort(Span, out.items, {}, struct {
        fn lt(_: void, a: Span, b: Span) bool {
            return a.start_ns < b.start_ns;
        }
    }.lt);
    return out.items;
}

/// Spans of one name, summed.
pub const Sum = struct {
    name: []const u8,
    count: u32 = 0,
    total_ns: i64 = 0,
    max_ns: i64 = 0,
    /// How many threads ran it.
    threads: u32 = 0,
};

/// `spans` summed by name, the most total time first.
pub fn summarize(arena: std.mem.Allocator, spans: []const Span) error{OutOfMemory}![]Sum {
    var sums: std.ArrayList(Sum) = .empty;
    var seen: std.ArrayList(struct { sum: usize, thread: usize }) = .empty;
    for (spans) |s| {
        const i = for (sums.items, 0..) |x, i| {
            if (std.mem.eql(u8, x.name, s.name)) break i;
        } else blk: {
            try sums.append(arena, .{ .name = s.name });
            break :blk sums.items.len - 1;
        };
        const d = s.end_ns - s.start_ns;
        sums.items[i].count += 1;
        sums.items[i].total_ns += d;
        sums.items[i].max_ns = @max(sums.items[i].max_ns, d);
        const new_thread = for (seen.items) |x| {
            if (x.sum == i and x.thread == s.thread) break false;
        } else true;
        if (new_thread) {
            try seen.append(arena, .{ .sum = i, .thread = s.thread });
            sums.items[i].threads += 1;
        }
    }
    std.mem.sort(Sum, sums.items, {}, struct {
        fn lt(_: void, a: Sum, b: Sum) bool {
            return a.total_ns > b.total_ns;
        }
    }.lt);
    return sums.items;
}

/// `spans` as a Chrome trace (JSON, the Trace Event Format), which Perfetto (ui.perfetto.dev) and
/// chrome://tracing open: one complete event a span, times in microseconds from the first span's
/// start, threads numbered in the order they appear, the UI thread named "ui".
pub fn writeTrace(w: *std.Io.Writer, spans: []const Span, ui_thread: usize) std.Io.Writer.Error!void {
    const base: i64 = if (spans.len > 0) spans[0].start_ns else 0;
    var threads: [64]usize = undefined;
    var n_threads: usize = 0;
    try w.writeAll("{\"traceEvents\":[\n");
    var first = true;
    for (spans) |s| {
        const tid = for (threads[0..n_threads], 0..) |t, i| {
            if (t == s.thread) break i;
        } else blk: {
            if (n_threads == threads.len) break :blk threads.len;
            threads[n_threads] = s.thread;
            n_threads += 1;
            if (!first) try w.writeAll(",\n");
            first = false;
            const label: []const u8 = if (s.thread == ui_thread) "ui" else "worker";
            try w.print("{{\"ph\":\"M\",\"name\":\"thread_name\",\"pid\":1,\"tid\":{d},\"args\":{{\"name\":\"{s} {d}\"}}}}", .{ n_threads - 1, label, s.thread });
            break :blk n_threads - 1;
        };
        if (!first) try w.writeAll(",\n");
        first = false;
        const ts = @as(f64, @floatFromInt(s.start_ns - base)) / 1000;
        const dur = @as(f64, @floatFromInt(s.end_ns - s.start_ns)) / 1000;
        try w.print("{{\"ph\":\"X\",\"name\":{f},\"cat\":\"fizzy\",\"pid\":1,\"tid\":{d},\"ts\":{d:.3},\"dur\":{d:.3}}}", .{ std.json.fmt(s.name, .{}), tid, ts, dur });
    }
    try w.writeAll("\n]}\n");
}

test "spans are kept with their names and threads, oldest first" {
    const spans = try create(std.testing.allocator);
    defer spans.destroy();
    spans.add("ignored while off", 0, 1, 1);
    spans.on.store(true, .monotonic);
    spans.add("write", 20, 30, 2);
    spans.add("open", 10, 40, 3);
    spans.add("a name longer than the forty-seven bytes a span keeps of it", 50, 60, 2);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const got = try spans.collect(arena.allocator(), 0);
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqualStrings("open", got[0].name);
    try std.testing.expectEqual(@as(usize, 3), got[0].thread);
    try std.testing.expectEqual(@as(usize, name_cap), got[2].name.len);
    // Only those that ended at or after the time asked.
    try std.testing.expectEqual(@as(usize, 2), (try spans.collect(arena.allocator(), 35)).len);
}

test "the ring keeps the newest" {
    const spans = try create(std.testing.allocator);
    defer spans.destroy();
    spans.on.store(true, .monotonic);
    for (0..capacity + 10) |i| spans.add("x", @intCast(i), @intCast(i + 1), 1);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const got = try spans.collect(arena.allocator(), 0);
    try std.testing.expectEqual(@as(usize, capacity), got.len);
    try std.testing.expectEqual(@as(i64, 10), got[0].start_ns);
}

test "threads write at once, and every span reads back whole" {
    const spans = try create(std.testing.allocator);
    defer spans.destroy();
    spans.on.store(true, .monotonic);
    const per = 2000;
    const Writer = struct {
        fn run(s: *Spans, id: usize) void {
            for (0..per) |i| s.add(if (id % 2 == 0) "even" else "odd", @intCast(i), @intCast(i + id), id);
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Writer.run, .{ spans, i + 1 });
    for (threads) |t| t.join();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const got = try spans.collect(arena.allocator(), 0);
    try std.testing.expectEqual(@as(usize, 4 * per), got.len);
    for (got) |s| {
        try std.testing.expectEqualStrings(if (s.thread % 2 == 0) "even" else "odd", s.name);
        try std.testing.expectEqual(@as(i64, @intCast(s.thread)), s.end_ns - s.start_ns);
    }
    const sums = try summarize(arena.allocator(), got);
    try std.testing.expectEqual(@as(usize, 2), sums.len);
    // "even" ran on threads 2 and 4, 2 + 4 ns each time; "odd" on 1 and 3.
    try std.testing.expectEqualStrings("even", sums[0].name);
    try std.testing.expectEqual(@as(u32, 2 * per), sums[0].count);
    try std.testing.expectEqual(@as(u32, 2), sums[0].threads);
    try std.testing.expectEqual(@as(i64, 4), sums[0].max_ns);
}

test "a trace is JSON Perfetto reads: complete events, named threads" {
    const spans = [_]Span{
        .{ .name = "frame", .start_ns = 1_000, .end_ns = 9_000, .thread = 7 },
        .{ .name = "checkpoint \"write\"", .start_ns = 2_000, .end_ns = 5_000, .thread = 9 },
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeTrace(&out.writer, &spans, 7);
    const Trace = struct { traceEvents: []const struct { ph: []const u8, name: []const u8, tid: u32, ts: ?f64 = null, dur: ?f64 = null, args: ?struct { name: []const u8 } = null } };
    const parsed = try std.json.parseFromSlice(Trace, std.testing.allocator, out.written(), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const ev = parsed.value.traceEvents;
    try std.testing.expectEqual(@as(usize, 4), ev.len);
    try std.testing.expectEqualStrings("ui 7", ev[0].args.?.name);
    try std.testing.expectEqualStrings("frame", ev[1].name);
    try std.testing.expectEqual(@as(f64, 8), ev[1].dur.?);
    try std.testing.expectEqualStrings("checkpoint \"write\"", ev[3].name);
    try std.testing.expectEqual(@as(f64, 1), ev[3].ts.?);
    try std.testing.expectEqual(@as(u32, 1), ev[3].tid);
}
