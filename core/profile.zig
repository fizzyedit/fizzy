//! The frame profiler: how long every part of a frame takes — fizzy's own phases, each plugin's
//! hooks, the surfaces plugins draw, and whatever sections a plugin marks inside its own code —
//! averaged over the last half second and shown in the profiler window (`Profiler` in the app).
//!
//! Everything a plugin does is called from fizzy, so the host times it at the call
//! (`sdk.Plugin`'s hook methods, `Layout`'s surface draws, `Host`'s callbacks) with no help from
//! the plugin. Inside a hook, a plugin marks its own sections to see where the hook's time goes:
//!
//!     const s = core.profile.section("transform");
//!     defer s.end();
//!
//! A section is nested under whatever scope is open, and belongs to the same owner — so a
//! plugin's sections land under its own hook without it naming itself.
//!
//! Each image (the host, every plugin dylib) compiles its own copy of this file. There is one
//! profiler, the host's: it publishes a pointer to itself in the shared dvui window each frame
//! (`hostFrameBegin`), and a plugin's `section` records into that. `abi` guards the layout — a
//! plugin built against a different one records nothing rather than into the wrong fields.
//!
//! Costs nothing while nobody is looking: a scope is then one branch. Two things record — the
//! profiler window while it is open (`enabled`), and anyone who asks (`want`): a plugin's test
//! holding its own cost to a budget, an automation client measuring what a change costs, a
//! benchmark. `report` writes what was measured as ZON, the same numbers the window shows.
const std = @import("std");
const dvui = @import("dvui");
const perf = @import("gfx/perf.zig");
/// What the profiler keeps past its half-second window: 30 seconds of windows, and the frames
/// over budget (`lookback`).
pub const Lookback = @import("profile/Lookback.zig");

/// Bumped whenever `Profiler`'s layout changes. Part of the key the host publishes it under
/// (`publish_key`), so a plugin built against another layout finds none and records nothing: the
/// `abi` field it would check sits wherever its own layout put it, which a reordered struct moves.
pub const abi: u32 = 4;

pub const max_entries = 1024;
const max_depth = 48;
const names_capacity = 64 * 1024;
const map_capacity = 2048; // a power of two, over twice `max_entries`
const none: u16 = std.math.maxInt(u16);

/// How many frames the history keeps (`historyFrame`), for the profiler window's graph.
pub const history_len = 240;

/// How long the published averages cover.
pub const window_ns: i128 = 500 * std.time.ns_per_ms;

pub const Entry = struct {
    owner: []const u8,
    name: []const u8,
    parent: u16,
    depth: u8,
    key: u64,

    // This frame.
    frame_ns: u64 = 0,
    frame_child_ns: u64 = 0,
    frame_calls: u32 = 0,

    // This window.
    win_ns: u64 = 0,
    win_child_ns: u64 = 0,
    win_calls: u64 = 0,
    win_max_ns: u64 = 0,

    // Published: per frame, over the last window.
    avg_ns: f64 = 0,
    avg_self_ns: f64 = 0,
    avg_calls: f64 = 0,
    max_ns: u64 = 0,
};

pub const FrameStats = struct {
    /// Between the starts of consecutive frames — what the frame rate is.
    interval_ns: f64 = 0,
    /// Inside fizzy's frame (`hostFrameBegin` … `hostFrameEnd`): the work the profiler sees.
    work_ns: f64 = 0,
    /// After fizzy's frame, the backend's end of it (`hostFrameBegin`'s `prev_submit_ns`):
    /// dvui's deferred drawing, and the frame's draws handed to the GPU. Null where the backend
    /// does not measure it.
    submit_ns: ?f64 = null,
    /// The slowest frame's work in the window.
    worst_work_ns: u64 = 0,
    fps: f64 = 0,
    frames: u32 = 0,
    /// Pointer moves (mouse or touch) the app was given, per second (`countInput`). Where frames
    /// are drawn only when there is input, the frame rate can be no better than this.
    inputs_per_s: f64 = 0,
};

pub const Profiler = struct {
    abi: u32 = abi,
    enabled: bool = false,
    paused: bool = false,
    /// Held still for a moment (the window's graph under the pointer): like `paused`, but the
    /// window sets it each frame it wants it.
    frozen: bool = false,
    /// Recording asked for (`want`) until this time (`now`), window open or not.
    wanted_until_ns: i128 = 0,
    /// This frame records: the window is open or someone asked. Decided once, at the frame's
    /// start, so a scope costs one branch either way.
    active: bool = false,

    /// The last `history_len` frames: each one's work and submit, and each entry's time and
    /// calls in it.
    history_work: [history_len]u32 = @splat(0),
    history_submit: [history_len]u32 = @splat(0),
    history_ns: [history_len][max_entries]u32 = @splat(@splat(0)),
    history_calls: [history_len][max_entries]u16 = @splat(@splat(0)),
    history_head: usize = 0,
    history_filled: usize = 0,

    entries: [max_entries]Entry = undefined,
    count: u16 = 0,
    /// Open addressing over `key`; `none` is empty.
    map: [map_capacity]u16 = @splat(none),

    stack: [max_depth]u16 = undefined,
    stack_start: [max_depth]i128 = undefined,
    depth: u8 = 0,

    names: [names_capacity]u8 = undefined,
    names_len: usize = 0,

    frame_start: i128 = 0,
    prev_frame_start: i128 = 0,
    win_start: i128 = 0,
    win_frames: u32 = 0,
    win_interval_ns: u64 = 0,
    win_work_ns: u64 = 0,
    win_worst_work_ns: u64 = 0,
    win_submit_ns: u64 = 0,
    win_submit_frames: u32 = 0,
    win_inputs: u64 = 0,
    /// This frame's pointer moves (`countInput`).
    frame_inputs: u32 = 0,
    /// The history slot the last frame was recorded in, for its submit to land in when the
    /// next frame begins. Null when it was not recorded (paused, frozen).
    recorded_slot: ?usize = null,
    stats: FrameStats = .{},

    /// Forget every entry (the window's Reset).
    pub fn reset(self: *Profiler) void {
        self.count = 0;
        self.map = @splat(none);
        self.names_len = 0;
        self.depth = 0;
        self.win_frames = 0;
        self.win_interval_ns = 0;
        self.win_work_ns = 0;
        self.win_worst_work_ns = 0;
        self.win_submit_ns = 0;
        self.win_submit_frames = 0;
        self.win_inputs = 0;
        self.frame_inputs = 0;
        self.recorded_slot = null;
        self.stats = .{};
        self.history_head = 0;
        self.history_filled = 0;
        self.history_work = @splat(0);
        self.history_submit = @splat(0);
        for (&self.history_ns) |*h| h.* = @splat(0);
        for (&self.history_calls) |*h| h.* = @splat(0);
        if (host_lookback) |lb| lb.reset();
    }

    /// The frame `ago` frames back (0 the latest recorded): its work, its submit (0 until the
    /// next frame reports it), and entries' times and calls, indexed as `slice`. Null past what
    /// the history holds.
    pub fn historyFrame(self: *Profiler, ago: usize) ?struct { work_ns: u32, submit_ns: u32, ns: []const u32, calls: []const u16 } {
        if (ago >= self.history_filled) return null;
        const slot = (self.history_head + history_len - 1 - ago) % history_len;
        return .{ .work_ns = self.history_work[slot], .submit_ns = self.history_submit[slot], .ns = self.history_ns[slot][0..self.count], .calls = self.history_calls[slot][0..self.count] };
    }

    pub fn slice(self: *Profiler) []Entry {
        return self.entries[0..self.count];
    }

    fn keep(self: *Profiler, s: []const u8) []const u8 {
        if (self.names_len + s.len > names_capacity) return "…";
        const out = self.names[self.names_len..][0..s.len];
        @memcpy(out, s);
        self.names_len += s.len;
        return out;
    }

    fn entryFor(self: *Profiler, owner: []const u8, name: []const u8, parent: u16) ?u16 {
        var h = std.hash.Wyhash.init(parent);
        h.update(owner);
        h.update(&.{0});
        h.update(name);
        const key = h.final();
        var slot: usize = @intCast(key & (map_capacity - 1));
        while (true) : (slot = (slot + 1) & (map_capacity - 1)) {
            const idx = self.map[slot];
            if (idx == none) break;
            if (self.entries[idx].key == key) return idx;
        }
        if (self.count >= max_entries) return null;
        const idx = self.count;
        self.count += 1;
        self.entries[idx] = .{
            .owner = self.keep(owner),
            .name = self.keep(name),
            .parent = parent,
            .depth = if (parent == none) 0 else self.entries[parent].depth + 1,
            .key = key,
        };
        self.map[slot] = idx;
        return idx;
    }

    fn open(self: *Profiler, owner: []const u8, name: []const u8) ?u16 {
        if (self.depth >= max_depth) return null;
        const parent = if (self.depth == 0) none else self.stack[self.depth - 1];
        const idx = self.entryFor(owner, name, parent) orelse return null;
        self.stack[self.depth] = idx;
        self.stack_start[self.depth] = now();
        self.depth += 1;
        return idx;
    }

    fn close(self: *Profiler, idx: u16) void {
        // Unwind to it: a scope whose end was skipped (an early return past a `defer`-less end,
        // a hook that errored) must not strand everything after it under itself.
        var d = self.depth;
        while (d > 0) {
            d -= 1;
            if (self.stack[d] == idx) break;
        } else return;
        const elapsed: u64 = @intCast(@max(0, now() - self.stack_start[d]));
        self.depth = d;
        const e = &self.entries[idx];
        e.frame_ns += elapsed;
        e.frame_calls += 1;
        if (e.parent != none) self.entries[e.parent].frame_child_ns += elapsed;
    }

    /// Pointer moves this frame, for `FrameStats.inputs_per_s`.
    pub fn countInput(self: *Profiler, n: u32) void {
        self.frame_inputs +|= n;
    }

    fn frameBegin(self: *Profiler, prev_submit_ns: ?u64) void {
        const t = now();
        self.active = self.enabled or t < self.wanted_until_ns;
        if (self.prev_frame_start != 0 and self.active and !self.paused) {
            self.win_interval_ns += @intCast(@max(0, t - self.prev_frame_start));
        }
        // The last frame's submit only exists now that the backend has finished it.
        if (self.recorded_slot) |slot| if (prev_submit_ns) |ns| {
            self.history_submit[slot] = @intCast(@min(ns, std.math.maxInt(u32)));
            self.win_submit_ns += ns;
            self.win_submit_frames += 1;
        };
        self.recorded_slot = null;
        self.prev_frame_start = t;
        self.frame_start = t;
        self.frame_inputs = 0;
        self.depth = 0;
    }

    fn frameEnd(self: *Profiler) void {
        if (!self.active or self.paused or self.frozen) {
            // Still clear the frame's times, or a held frame's add to the next one recorded.
            for (self.slice()) |*e| {
                e.frame_ns = 0;
                e.frame_child_ns = 0;
                e.frame_calls = 0;
            }
            return;
        }
        const t = now();
        const work: u64 = @intCast(@max(0, t - self.frame_start));
        {
            const slot = self.history_head;
            self.history_work[slot] = @intCast(@min(work, std.math.maxInt(u32)));
            self.history_submit[slot] = 0;
            self.recorded_slot = slot;
            for (self.slice(), 0..) |e, i| {
                self.history_ns[slot][i] = @intCast(@min(e.frame_ns, std.math.maxInt(u32)));
                self.history_calls[slot][i] = @intCast(@min(e.frame_calls, std.math.maxInt(u16)));
            }
            self.history_head = (slot + 1) % history_len;
            self.history_filled = @min(self.history_filled + 1, history_len);
            if (host_lookback) |lb| lb.noteFrame(t, work, self.history_ns[slot][0..self.count], self.history_calls[slot][0..self.count]);
        }
        self.win_work_ns += work;
        self.win_worst_work_ns = @max(self.win_worst_work_ns, work);
        self.win_inputs += self.frame_inputs;
        self.win_frames += 1;
        for (self.slice()) |*e| {
            e.win_ns += e.frame_ns;
            e.win_child_ns += e.frame_child_ns;
            e.win_calls += e.frame_calls;
            e.win_max_ns = @max(e.win_max_ns, e.frame_ns);
            e.frame_ns = 0;
            e.frame_child_ns = 0;
            e.frame_calls = 0;
        }
        if (self.win_start == 0) self.win_start = t;
        if (t - self.win_start < window_ns) return;

        const frames: f64 = @floatFromInt(@max(self.win_frames, 1));
        const span: f64 = @floatFromInt(t - self.win_start);
        self.stats = .{
            .interval_ns = @as(f64, @floatFromInt(self.win_interval_ns)) / frames,
            .work_ns = @as(f64, @floatFromInt(self.win_work_ns)) / frames,
            .submit_ns = if (self.win_submit_frames == 0) null else @as(f64, @floatFromInt(self.win_submit_ns)) / @as(f64, @floatFromInt(self.win_submit_frames)),
            .worst_work_ns = self.win_worst_work_ns,
            .fps = @as(f64, @floatFromInt(self.win_frames)) / (span / std.time.ns_per_s),
            .frames = self.win_frames,
            .inputs_per_s = @as(f64, @floatFromInt(self.win_inputs)) / (span / std.time.ns_per_s),
        };
        if (host_lookback) |lb| lb.foldWindow(.{
            .end_ns = t,
            .frames = self.win_frames,
            .work_ns = self.win_work_ns,
            .worst_work_ns = self.win_worst_work_ns,
        }, self.slice());
        for (self.slice()) |*e| {
            e.avg_ns = @as(f64, @floatFromInt(e.win_ns)) / frames;
            e.avg_self_ns = @as(f64, @floatFromInt(e.win_ns -| e.win_child_ns)) / frames;
            e.avg_calls = @as(f64, @floatFromInt(e.win_calls)) / frames;
            e.max_ns = e.win_max_ns;
            e.win_ns = 0;
            e.win_child_ns = 0;
            e.win_calls = 0;
            e.win_max_ns = 0;
        }
        self.win_start = t;
        self.win_frames = 0;
        self.win_interval_ns = 0;
        self.win_work_ns = 0;
        self.win_worst_work_ns = 0;
        self.win_submit_ns = 0;
        self.win_submit_frames = 0;
        self.win_inputs = 0;
    }
};

fn now() i128 {
    return perf.nanoTimestamp();
}

/// The host's profiler. Only the host image's copy is ever used as one (`hostFrameBegin`).
var host_profiler: Profiler = .{};
var is_host = false;
/// The host's lookback, made the first frame the profiler records: nothing is spent on it while
/// nobody profiles. Published beside the profiler under a key of its own, so the profiler's
/// layout, and the plugins built against it, are untouched.
var host_lookback: ?*Lookback = null;

const publish_id: dvui.Id = @enumFromInt(0x6669_7a7a_7970_7266); // "fizzyprf"
const publish_key = std.fmt.comptimePrint("_profiler{d}", .{abi});
const lookback_key = std.fmt.comptimePrint("_profiler_lookback{d}", .{Lookback.abi});

/// The profiler to record into: the host's own in the host, the one it published in a plugin.
/// Null when there is none, or it was built with another layout.
pub fn current() ?*Profiler {
    if (is_host) return &host_profiler;
    // A plugin's copy finds the host's through the window, so outside one — a hook called
    // between frames, or from a test with no window at all — there is nothing to record into.
    // Asking dvui's store then is a panic, not a miss.
    if (dvui.current_window == null) return null;
    const addr = dvui.dataGet(null, publish_id, publish_key, usize) orelse return null;
    const p: *Profiler = @ptrFromInt(addr);
    return if (p.abi == abi) p else null;
}

/// What the profiler kept past its half-second window, from any image: the costs of the last 30
/// seconds and the frames over budget. Null until the profiler has recorded a frame.
pub fn lookback() ?*Lookback {
    if (is_host) return host_lookback;
    if (dvui.current_window == null) return null;
    const addr = dvui.dataGet(null, publish_id, lookback_key, usize) orelse return null;
    return @ptrFromInt(addr);
}

/// Host only: the profiler the window shows and controls.
pub fn host() *Profiler {
    return &host_profiler;
}

/// Host only, at the start of every frame, before anything is timed: start the frame, and
/// publish the profiler to the plugins through the shared window. `prev_submit_ns` is how long
/// the backend took to end the last frame after fizzy's part of it (`FrameStats.submit_ns`),
/// where the backend measures that.
pub fn hostFrameBegin(prev_submit_ns: ?u64) void {
    is_host = true;
    host_profiler.frameBegin(prev_submit_ns);
    dvui.dataSet(null, publish_id, publish_key, @as(usize, @intFromPtr(&host_profiler)));
    if (host_lookback == null and host_profiler.active) host_lookback = Lookback.create(std.heap.page_allocator, max_entries) catch null;
    if (host_lookback) |lb| dvui.dataSet(null, publish_id, lookback_key, @as(usize, @intFromPtr(lb)));
}

/// Host only, at the end of every frame.
pub fn hostFrameEnd() void {
    host_profiler.frameEnd();
}

/// An open scope; `end` it (deferred) where the timed code ends.
pub const Scope = struct {
    p: ?*Profiler = null,
    idx: u16 = none,

    pub fn end(self: Scope) void {
        if (self.p) |p| p.close(self.idx);
    }
};

/// Time from here to `end` as `name` under `owner` (a plugin id, or "fizzy"), nested under the
/// scope already open. What the host wraps each call into a plugin with.
pub fn begin(owner: []const u8, name: []const u8) Scope {
    const p = current() orelse return .{};
    if (!p.active or p.paused) return .{};
    const idx = p.open(owner, name) orelse return .{};
    return .{ .p = p, .idx = idx };
}

/// Time from here to `end` as `name`, nested under the open scope and belonging to its owner:
/// how a plugin marks the parts of a hook.
pub fn section(name: []const u8) Scope {
    const p = current() orelse return .{};
    if (!p.active or p.paused) return .{};
    const owner = if (p.depth > 0) p.entries[p.stack[p.depth - 1]].owner else "?";
    const idx = p.open(owner, name) orelse return .{};
    return .{ .p = p, .idx = idx };
}

/// Record for the next `ms` milliseconds, whether or not the profiler window is open — or for
/// longer, if someone already asked for longer. From any image: it records into the host's
/// profiler. The next frame is the first recorded; `report` covers the half second
/// (`window_ns`) before it, so ask for at least a second to read a full window.
///
/// Consumers: a plugin's test holding its own cost to a budget, a benchmark, an automation
/// client measuring what a change costs — without the window open, or anyone reading a log.
pub fn want(ms: u32) void {
    const p = current() orelse return;
    p.wanted_until_ns = @max(p.wanted_until_ns, now() + @as(i128, ms) * std.time.ns_per_ms);
}

pub const ReportOptions = struct {
    /// Leave out scopes cheaper than this per frame, on average: most of a frame's scopes cost
    /// next to nothing, and a reader wants the ones that do not.
    min_ms: f64 = 0.01,
    /// Also the costliest scopes over this many milliseconds (`lookback`, at most 30 s), by
    /// their own time, when above zero: the averages a half second hides.
    over_ms: u32 = 0,
    /// How many scopes `over` lists, and each hitch.
    top: usize = 10,
    /// Also the newest this many frames that went over budget (`Lookback.budget_ns`), each with
    /// its costliest scopes.
    hitches: usize = 0,
};

/// Each entry's own time in a frame whose times (`ns`, indexed as `Profiler.slice`) are given:
/// its time less its children's.
pub fn selfTimes(p: *const Profiler, ns: []const u32, out: []u64) void {
    const n = @min(ns.len, out.len, p.count);
    for (out[0..n], ns[0..n]) |*o, v| o.* = v;
    for (p.entries[0..n], 0..) |e, i| if (e.parent != none and e.parent < n) {
        out[e.parent] -|= ns[i];
    };
}

/// What the last window (`window_ns`) measured, as ZON, a line per item so two reports diff:
/// the frame (rate, interval, fizzy's work, its worst, the backend's submit), each owner's own
/// time costliest first — where to look for the slow plugin — and the scopes as a tree, each
/// with its average, its self time, its worst and its calls per frame, `parent` an index into
/// the list. Milliseconds throughout.
pub fn report(p: *const Profiler, w: *std.Io.Writer, opts: ReportOptions) std.Io.Writer.Error!void {
    const st = p.stats;
    try w.print(".{{\n    .frame = .{{ .fps = {d:.1}, .interval_ms = {d:.3}, .work_ms = {d:.3}, .worst_work_ms = {d:.3}, ", .{
        st.fps, millis(st.interval_ns), millis(st.work_ns), millis(@floatFromInt(st.worst_work_ns)),
    });
    if (st.submit_ns) |sub| try w.print(".submit_ms = {d:.3}, ", .{millis(sub)});
    try w.print(".frames = {d}, .inputs_per_s = {d:.1} }},\n", .{ st.frames, st.inputs_per_s });

    // Each owner's own time: the self time of every scope it owns.
    var owners: [64]struct { name: []const u8, self_ns: f64 } = undefined;
    var n_owners: usize = 0;
    for (p.entries[0..p.count]) |e| {
        const i = for (owners[0..n_owners], 0..) |o, i| {
            if (std.mem.eql(u8, o.name, e.owner)) break i;
        } else blk: {
            if (n_owners == owners.len) continue;
            owners[n_owners] = .{ .name = e.owner, .self_ns = 0 };
            n_owners += 1;
            break :blk n_owners - 1;
        };
        owners[i].self_ns += e.avg_self_ns;
    }
    std.mem.sort(@TypeOf(owners[0]), owners[0..n_owners], {}, struct {
        fn lt(_: void, a: @TypeOf(owners[0]), b: @TypeOf(owners[0])) bool {
            return a.self_ns > b.self_ns;
        }
    }.lt);
    try w.writeAll("    .owners = .{\n");
    for (owners[0..n_owners]) |o| {
        if (millis(o.self_ns) < opts.min_ms) continue;
        try w.print("        .{{ .owner = \"{f}\", .self_ms = {d:.3} }},\n", .{ std.zig.fmtString(o.name), millis(o.self_ns) });
    }

    // The scopes, depth first: a scope, then the scopes inside it.
    try w.writeAll("    },\n    .scopes = .{\n");
    var out_index: [max_entries]u16 = @splat(none);
    var written: u16 = 0;
    for (p.entries[0..p.count], 0..) |e, i| {
        if (e.parent == none) try writeScope(p, w, @intCast(i), none, &out_index, &written, opts);
    }
    try w.writeAll("    },\n");
    if (lookback()) |lb| {
        if (opts.over_ms > 0) try writeOver(p, lb, w, opts);
        if (opts.hitches > 0) try writeHitches(p, lb, w, opts);
    }
    try w.writeAll("}\n");
}

/// The costliest scopes over `opts.over_ms`, by their own time per frame.
fn writeOver(p: *const Profiler, lb: *const Lookback, w: *std.Io.Writer, opts: ReportOptions) std.Io.Writer.Error!void {
    var costs: [max_entries]Lookback.Cost = undefined;
    const n = p.count;
    const span = lb.costs(opts.over_ms, costs[0..n]);
    var order: [max_entries]u16 = undefined;
    for (order[0..n], 0..) |*o, i| o.* = @intCast(i);
    std.mem.sort(u16, order[0..n], costs[0..n], struct {
        fn lt(cs: []const Lookback.Cost, a: u16, b: u16) bool {
            return cs[a].self_ns > cs[b].self_ns;
        }
    }.lt);
    try w.print("    .over = .{{ .seconds = {d:.1}, .frames = {d}, .work_ms = {d:.3}, .worst_work_ms = {d:.3}, .top = .{{\n", .{
        @as(f64, @floatFromInt(span.ns)) / std.time.ns_per_s, span.frames, millis(span.work_ns), millis(@floatFromInt(span.worst_work_ns)),
    });
    for (order[0..@min(n, opts.top)]) |i| {
        const c = costs[i];
        if (millis(c.self_ns) < opts.min_ms) break;
        const e = p.entries[i];
        try w.print("        .{{ .owner = \"{f}\", .name = \"{f}\", .self_ms = {d:.3}, .avg_ms = {d:.3}, .max_ms = {d:.3}, .calls = {d:.1} }},\n", .{
            std.zig.fmtString(e.owner), std.zig.fmtString(e.name), millis(c.self_ns), millis(c.avg_ns), millis(@floatFromInt(c.max_ns)), c.calls,
        });
    }
    try w.writeAll("    } },\n");
}

/// The newest `opts.hitches` frames over budget, each with its costliest scopes by own time.
fn writeHitches(p: *const Profiler, lb: *const Lookback, w: *std.Io.Writer, opts: ReportOptions) std.Io.Writer.Error!void {
    try w.print("    .hitch_budget_ms = {d:.3},\n    .hitches = .{{\n", .{millis(@floatFromInt(lb.budget_ns))});
    const t = now();
    var ago: usize = 0;
    while (ago < opts.hitches) : (ago += 1) {
        const h = lb.hitchAt(ago) orelse break;
        var self_ns: [max_entries]u64 = undefined;
        const n = h.ns.len;
        selfTimes(p, h.ns, self_ns[0..n]);
        var order: [max_entries]u16 = undefined;
        for (order[0..n], 0..) |*o, i| o.* = @intCast(i);
        std.mem.sort(u16, order[0..n], self_ns[0..n], struct {
            fn lt(ss: []const u64, a: u16, b: u16) bool {
                return ss[a] > ss[b];
            }
        }.lt);
        try w.print("        .{{ .ago_s = {d:.1}, .work_ms = {d:.3}, .top = .{{\n", .{
            @as(f64, @floatFromInt(t - h.at_ns)) / std.time.ns_per_s, millis(@floatFromInt(h.work_ns)),
        });
        for (order[0..@min(n, opts.top)]) |i| {
            if (millis(@floatFromInt(self_ns[i])) < opts.min_ms) break;
            const e = p.entries[i];
            try w.print("            .{{ .owner = \"{f}\", .name = \"{f}\", .self_ms = {d:.3}, .ms = {d:.3}, .calls = {d} }},\n", .{
                std.zig.fmtString(e.owner), std.zig.fmtString(e.name), millis(@floatFromInt(self_ns[i])), millis(@floatFromInt(h.ns[i])), h.calls[i],
            });
        }
        try w.writeAll("        } },\n");
    }
    try w.writeAll("    },\n");
}

fn writeScope(p: *const Profiler, w: *std.Io.Writer, idx: u16, parent_out: u16, out_index: *[max_entries]u16, written: *u16, opts: ReportOptions) std.Io.Writer.Error!void {
    const e = p.entries[idx];
    // A scope below the line is left out, and what is inside it hangs from its nearest shown
    // ancestor.
    var mine = parent_out;
    if (millis(e.avg_ns) >= opts.min_ms) {
        try w.print("        .{{ .owner = \"{f}\", .name = \"{f}\", .avg_ms = {d:.3}, .self_ms = {d:.3}, .max_ms = {d:.3}, .calls = {d:.1}", .{
            std.zig.fmtString(e.owner), std.zig.fmtString(e.name), millis(e.avg_ns), millis(e.avg_self_ns), millis(@floatFromInt(e.max_ns)), e.avg_calls,
        });
        if (parent_out != none) try w.print(", .parent = {d}", .{parent_out});
        try w.writeAll(" },\n");
        mine = written.*;
        out_index[idx] = mine;
        written.* += 1;
    }
    for (p.entries[0..p.count], 0..) |c, i| {
        if (c.parent == idx) try writeScope(p, w, @intCast(i), mine, out_index, written, opts);
    }
}

fn millis(ns: f64) f64 {
    return ns / std.time.ns_per_ms;
}

test "a report says what each owner and scope cost, as ZON that reads back" {
    // The profiler's clock reads `dvui.io`, which no window has set up in a test of its own.
    dvui.io = std.testing.io;
    var p: Profiler = .{ .wanted_until_ns = std.math.maxInt(i96) };
    // Two frames a window apart, so the second publishes averages.
    for (0..2) |_| {
        p.frameBegin(null);
        const outer = p.open("fizzy", "draw").?;
        const inner = p.open("text", "surface").?;
        const until = now() + 2 * std.time.ns_per_ms;
        while (now() < until) {}
        p.close(inner);
        p.close(outer);
        p.win_start -= window_ns;
        p.frameEnd();
    }
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try report(&p, &w, .{});
    const text = w.buffered();

    const Report = struct {
        frame: struct { fps: f64, interval_ms: f64, work_ms: f64, worst_work_ms: f64, submit_ms: ?f64 = null, frames: u32, inputs_per_s: f64 },
        owners: []const struct { owner: []const u8, self_ms: f64 },
        scopes: []const struct { owner: []const u8, name: []const u8, avg_ms: f64, self_ms: f64, max_ms: f64, calls: f64, parent: ?u16 = null },
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try std.zon.parse.fromSliceAlloc(Report, arena.allocator(), try arena.allocator().dupeZ(u8, text), null, .{});
    // The plugin's own time is what it spent; fizzy's own is what was left once that is taken out.
    try std.testing.expectEqualStrings("text", r.owners[0].owner);
    try std.testing.expect(r.owners[0].self_ms >= 1.5);
    try std.testing.expectEqual(@as(usize, 2), r.scopes.len);
    try std.testing.expectEqualStrings("draw", r.scopes[0].name);
    try std.testing.expectEqual(@as(?u16, 0), r.scopes[1].parent);
}

test "nothing records unless the window is open or someone asked" {
    dvui.io = std.testing.io;
    var p: Profiler = .{};
    p.frameBegin(null);
    try std.testing.expect(!p.active);
    p.wanted_until_ns = now() + std.time.ns_per_s;
    p.frameBegin(null);
    try std.testing.expect(p.active);
}

test "scopes nest, and a frame's time folds into the window's averages" {
    var p: Profiler = .{ .enabled = true };
    p.frameBegin(null);
    const a = p.open("pixi", "draw").?;
    const b = p.open("pixi", "bubbles").?;
    p.close(b);
    p.close(a);
    try std.testing.expectEqual(@as(u16, 2), p.count);
    try std.testing.expectEqual(@as(u8, 1), p.entries[b].depth);
    try std.testing.expectEqual(a, p.entries[b].parent);
    try std.testing.expectEqual(@as(u32, 1), p.entries[a].frame_calls);
    try std.testing.expect(p.entries[a].frame_child_ns == p.entries[b].frame_ns);
    // The same path finds the same entry.
    const a2 = p.open("pixi", "draw").?;
    try std.testing.expectEqual(a, a2);
    p.close(a2);
}

test "a scope whose end was skipped does not strand the ones after it" {
    var p: Profiler = .{ .enabled = true };
    p.frameBegin(null);
    const a = p.open("fizzy", "frame").?;
    _ = p.open("x", "lost").?; // never closed
    p.close(a);
    try std.testing.expectEqual(@as(u8, 0), p.depth);
}

test "a frame's submit lands in its own slot when the next frame begins" {
    var p: Profiler = .{ .enabled = true };
    p.frameBegin(null);
    p.countInput(3);
    p.frameEnd();
    try std.testing.expectEqual(@as(u32, 0), p.historyFrame(0).?.submit_ns);
    p.frameBegin(5 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u32, 5 * std.time.ns_per_ms), p.historyFrame(0).?.submit_ns);
    try std.testing.expectEqual(@as(u64, 3), p.win_inputs);
    // Paused, a frame is not recorded and its submit goes nowhere.
    p.frameEnd();
    p.paused = true;
    p.frameBegin(null);
    p.frameEnd();
    p.frameBegin(7 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u32, 0), p.historyFrame(0).?.submit_ns);
}
