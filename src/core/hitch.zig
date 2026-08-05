//! TEMPORARY frame-hitch profiler. Env-gated (`FIZZY_HITCH_MS=<threshold>`); zero cost when off.
//!
//! Records per-frame wall time plus a handful of named phase timers, and logs any frame that
//! exceeds the threshold with the phase breakdown. Used to attribute the "opening a large
//! markdown file stalls the UI" report to a specific phase rather than guessing.

const std = @import("std");
const perf = @import("gfx/perf.zig");

pub const Phase = enum {
    watchers,
    loading_jobs,
    rebuild_workspaces,
    plugin_hooks,
    draw,
};

const phase_count = @typeInfo(Phase).@"enum".fields.len;

pub var enabled: bool = false;
var threshold_ns: u64 = 16 * std.time.ns_per_ms;

var frame_start: i128 = 0;
var phase_ns: [phase_count]u64 = @splat(0);
var frame_index: u64 = 0;

pub fn initFromEnv() void {
    if (comptime @import("builtin").target.cpu.arch == .wasm32) return;
    const raw = std.c.getenv("FIZZY_HITCH_MS") orelse return;
    const thresh = std.fmt.parseInt(u64, std.mem.trim(u8, std.mem.span(raw), " \t"), 10) catch return;
    enabled = true;
    threshold_ns = thresh * std.time.ns_per_ms;
    std.log.info("hitch profiler on, threshold {d} ms", .{thresh});
}

fn now() i128 {
    return perf.nanoTimestamp();
}

pub const Timer = struct {
    phase: Phase,
    start: i128,

    pub fn end(self: Timer) void {
        if (!enabled) return;
        phase_ns[@intFromEnum(self.phase)] +%= @intCast(now() - self.start);
    }
};

pub fn begin(phase: Phase) Timer {
    return .{ .phase = phase, .start = if (enabled) now() else 0 };
}

pub fn frameBegin() void {
    if (!enabled) return;
    frame_index +%= 1;
    frame_start = now();
    phase_ns = @splat(0);
}

pub fn frameEnd() void {
    if (!enabled) return;
    const total: u64 = @intCast(now() - frame_start);
    if (total < threshold_ns) return;
    var accounted: u64 = 0;
    for (phase_ns[0 .. phase_count - 1]) |v| accounted +%= v;
    std.log.info(
        "hitch frame {d}: {d:.1} ms | watchers {d:.1} loading {d:.1} workspaces {d:.1} plugin_hooks {d:.1} draw {d:.1} other {d:.1}",
        .{
            frame_index,
            ms(total),
            ms(phase_ns[@intFromEnum(Phase.watchers)]),
            ms(phase_ns[@intFromEnum(Phase.loading_jobs)]),
            ms(phase_ns[@intFromEnum(Phase.rebuild_workspaces)]),
            ms(phase_ns[@intFromEnum(Phase.plugin_hooks)]),
            ms(phase_ns[@intFromEnum(Phase.draw)]),
            ms(total -| accounted -| phase_ns[@intFromEnum(Phase.draw)]),
        },
    );
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, std.time.ns_per_ms);
}
