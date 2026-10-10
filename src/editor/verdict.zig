//! A run of the real app that plays a tape to its end and then says whether it went well: what
//! CI runs, and what anyone runs to check fizzy against the backend it is on (`docs/AUTOMATION.md`,
//! "A run that ends in a verdict").
//!
//! ```sh
//! FIZZY_VERDICT=out/verdict.zon FIZZY_DEMO=tests/tapes/soak.zon fizzy --profile out/profile
//! ```
//!
//! `FIZZY_DEMO` names the tape as it always does — a bundled demo, or a `.zon` or `.tape` file —
//! and `FIZZY_VERDICT` makes the run one with a verdict: it plays the tape (a demo through the
//! `Player`, a live tape through the `LiveDriver`), quits when it ends, and exits 1 when
//!
//! * the tape did not start, did not finish (a person's input, `deadline`), or lost its place (a
//!   wait gave up: `Player.timeouts`, or a live tape's `timed_out`);
//! * a replay did not reach what playing did (`Player.mismatches`);
//! * SDL logged an error, from launch to exit (the backend's `Health`);
//! * the debug allocator found memory still allocated at exit (Debug builds);
//! * the backend's counters break what the run expects (`Expect`): by default the OS windows
//!   alive at the end are as many as at the start, and the main window was presented to.
//!
//! The verdict and the counters it read go to the `FIZZY_VERDICT` path as ZON (`Verdict`).
//! `FIZZY_VERDICT_EXPECT` names a ZON file of `Expect` to hold the run to more than the defaults.
//!
//! It must run in a profile of its own (`--profile` or `FIZZY_PROFILE`): a run that quits by
//! itself must never touch a person's settings, plugins, lock or socket. Without one it refuses to
//! start (exit 2). Native only.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const Demo = @import("Demo.zig");

const log = std.log.scoped(.verdict);

/// The backend keeps health counters (fizzy's native backend does; dvui's `sdl3` and the web's
/// do not).
const has_health = builtin.target.cpu.arch != .wasm32 and @hasDecl(dvui.backend, "health");
pub const Health = if (has_health) dvui.backend.Health.Snapshot else struct {};

pub const env_out = "FIZZY_VERDICT";
pub const env_expect = "FIZZY_VERDICT_EXPECT";

/// What a run is held to, beyond the tape playing to its end with nothing lost or mismatched. A
/// `FIZZY_VERDICT_EXPECT` file holds one as ZON; every field it leaves out keeps its default.
pub const Expect = struct {
    /// Wall time the run may take, start to the tape's end, before it is given up.
    timeout_s: u32 = 600,
    /// Whether memory still allocated at exit (Debug builds) passes: recorded either way. Only
    /// for a run held to everything else while known leaks are fixed.
    allow_leaks: bool = false,
    /// Errors SDL may log, launch to exit.
    max_sdl_errors: u32 = 0,
    /// Warnings SDL may log; null: any number.
    max_sdl_warnings: ?u32 = null,
    /// OS windows alive when the tape ends; null: as many as when it began.
    os_windows: ?u32 = null,
    /// macOS: SDL's windows AppKit still holds when the tape ends (`Health.Snapshot.ns_windows`),
    /// visible or not; null: not checked. A window SDL destroyed that something keeps alive shows
    /// here and not in `os_windows`.
    ns_windows: ?u32 = null,
    /// Presents to the main window the run must reach: a run that drew nothing failed, whatever
    /// else it says.
    min_presents: u64 = 1,
    /// The most any one frame may ask of the GPU; null: no limit.
    max_peak_draws: ?u32 = null,
    max_peak_passes: ?u32 = null,
    max_peak_target_switches: ?u32 = null,
    /// The slowest frame time a run may have at the 99th percentile, µs; null: no limit. Times
    /// wobble with the machine: for a run on known hardware, never a hosted runner.
    max_frame_p99_us: ?u32 = null,
};

pub const Failure = enum {
    /// No tape began: a bundled name nothing has, a file that would not read.
    did_not_start,
    /// A person's input stopped or paused it, or something stopped it.
    interrupted,
    /// It had not ended when `Expect.timeout_s` ran out.
    deadline,
    /// A wait gave up: what the tape waited for never came.
    lost_place,
    /// A replay did not reach what playing did.
    mismatched,
    sdl_errors,
    sdl_warnings,
    /// Memory still allocated at exit (Debug builds).
    leaks,
    /// More (or fewer) OS windows alive at the end than expected.
    windows,
    /// Fewer presents than `Expect.min_presents`.
    presents,
    /// A frame asked more of the GPU than `Expect` allows, or took too long.
    budget,
};

/// What the run wrote to `FIZZY_VERDICT`.
pub const Verdict = struct {
    pass: bool = false,
    failures: []const Failure = &.{},
    /// The tape's name, and how it was played.
    tape: []const u8 = "",
    driver: enum { none, demo, live } = .none,
    /// How the tape ended: `finished`, or what stopped it.
    ended: []const u8 = "",
    /// Waits that gave up, and replays that did not match (a demo's).
    timeouts: u32 = 0,
    mismatches: u32 = 0,
    /// Memory still allocated at exit; null where the allocator does not track it (release).
    leaks: ?bool = null,
    wall_ms: u64 = 0,
    /// The backend's counters as the tape began and as it ended (`SDLBackend.health`).
    at_start: ?Health = null,
    at_end: ?Health = null,
    /// SDL's errors and warnings from launch to exit, shutdown included.
    sdl_errors: u32 = 0,
    sdl_warnings: u32 = 0,
    expect: Expect = .{},
};

const State = enum { off, waiting, playing, ended };

var state: State = .off;
var io: std.Io = undefined;
/// Where the verdict goes, absolute; in `path_buf`.
var path_buf: [std.fs.max_path_bytes]u8 = undefined;
var path: []const u8 = "";
var expect: Expect = .{};
var start_ns: i128 = 0;
var waited_frames: u32 = 0;
var failures: [@typeInfo(Failure).@"enum".fields.len]Failure = undefined;
var failure_count: usize = 0;
var ended_buf: [64]u8 = undefined;
var tape_buf: [128]u8 = undefined;
var result: Verdict = .{};

/// Whether this run ends in a verdict.
pub fn on() bool {
    return state != .off;
}

/// First thing in the app's `main`, before it takes its single-instance lock: a verdict run with
/// no profile named stops here (exit 2), before anything of the person's is touched.
pub fn refuseWithoutProfile(gpa: std.mem.Allocator, args: std.process.Args) ?u8 {
    if (comptime !has_health) return null;
    if (std.c.getenv(env_out) == null) return null;
    const profile = @import("app").profile;
    if (std.c.getenv(profile.env_var) != null) return null;
    var it = std.process.Args.Iterator.initAllocator(args, gpa) catch return 2;
    defer it.deinit();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, profile.flag) or std.mem.startsWith(u8, arg, profile.flag ++ "=")) return null;
    }
    log.err(no_profile, .{env_out});
    return 2;
}

const no_profile = "{s} needs a profile of its own (--profile <dir> or FIZZY_PROFILE): a run that quits by itself must not touch your settings, plugins or lock";

/// Before the app starts, from its `main`, while the working directory is still the one it was
/// launched from: read `FIZZY_VERDICT` and `FIZZY_VERDICT_EXPECT`. Null: carry on (with or without a
/// verdict); an exit code: the run cannot be one, and stops here.
pub fn init(gpa: std.mem.Allocator, process_io: std.Io, profile: ?[]const u8) ?u8 {
    if (comptime !has_health) return null;
    const out = std.c.getenv(env_out) orelse return null;
    io = process_io;
    if (profile == null) {
        log.err(no_profile, .{env_out});
        return 2;
    }
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io, &cwd_buf) catch 0;
    const resolved = std.fs.path.resolve(gpa, &.{ cwd_buf[0..cwd_len], std.mem.span(out) }) catch return 2;
    defer gpa.free(resolved);
    if (resolved.len > path_buf.len) return 2;
    @memcpy(path_buf[0..resolved.len], resolved);
    path = path_buf[0..resolved.len];

    if (std.c.getenv(env_expect)) |expect_path| {
        expect = readExpect(gpa, std.mem.span(expect_path)) catch |err| {
            log.err("could not read {s} ({s}): {t}", .{ env_expect, expect_path, err });
            return 2;
        };
    }
    state = .waiting;
    log.info("this run ends in a verdict, written to {s}", .{path});
    return null;
}

fn readExpect(gpa: std.mem.Allocator, file: []const u8) !Expect {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, file, gpa, .limited(1 << 16));
    defer gpa.free(bytes);
    const source = try gpa.dupeZ(u8, bytes);
    defer gpa.free(source);
    return std.zon.parse.fromSlice(Expect, gpa, source, null, .{});
}

/// Once a displayed frame, after the app's: watch the tape start and end. True: the tape has
/// ended (or will not), and the app quits now.
pub fn frame(demo: *Demo) bool {
    if (state == .off or state == .ended) return false;
    const now = std.Io.Clock.awake.now(io).nanoseconds;
    if (start_ns == 0) {
        start_ns = now;
        result.at_start = health();
    }
    if (now - start_ns > @as(i128, expect.timeout_s) * std.time.ns_per_s) {
        fail(.deadline);
        return end("did not end in time");
    }
    switch (state) {
        .waiting => {
            if (demo.player.state != .idle) {
                started(.demo, if (demo.player.tape()) |t| t.name else "");
            } else if (demo.live.playing()) {
                started(.live, if (demo.live.owned) |o| o.tape.name else "");
            } else if (demo.pending == null) {
                // Asked for at launch and started on the first frame: a few frames on, nothing is
                // playing, so nothing will.
                waited_frames += 1;
                if (waited_frames > 30) {
                    fail(.did_not_start);
                    return end("did not start");
                }
            }
            return false;
        },
        .playing => switch (result.driver) {
            .demo => {
                const p = &demo.player;
                result.timeouts = p.timeouts;
                result.mismatches = p.mismatches;
                return switch (p.state) {
                    .ended => end("finished"),
                    .playing, .seeking => false,
                    .paused => blk: {
                        // A person's input pauses a demo; one that stays paused never ends.
                        fail(.interrupted);
                        break :blk end("paused");
                    },
                    .idle => blk: {
                        fail(.interrupted);
                        break :blk end("stopped");
                    },
                };
            },
            .live => {
                const outcome = demo.live.outcome orelse return false;
                switch (outcome) {
                    .finished => return end("finished"),
                    .timed_out => |op| {
                        result.timeouts += 1;
                        return endFmt("timed out at op {d}", .{op});
                    },
                    .interrupted => |op| {
                        fail(.interrupted);
                        return endFmt("interrupted at op {d}", .{op});
                    },
                    .stopped => |op| {
                        fail(.interrupted);
                        return endFmt("stopped at op {d}", .{op});
                    },
                }
            },
            .none => unreachable,
        },
        .off, .ended => unreachable,
    }
}

fn started(driver: @TypeOf(result.driver), name: []const u8) void {
    state = .playing;
    result.driver = driver;
    const n = @min(name.len, tape_buf.len);
    @memcpy(tape_buf[0..n], name[0..n]);
    result.tape = tape_buf[0..n];
    log.info("playing '{s}' ({t})", .{ result.tape, driver });
}

fn endFmt(comptime fmt: []const u8, args: anytype) bool {
    return end(std.fmt.bufPrint(&ended_buf, fmt, args) catch "ended");
}

fn end(how: []const u8) bool {
    // Static text, or already in `ended_buf` (`endFmt`).
    result.ended = how;
    result.wall_ms = @intCast(@divTrunc(std.Io.Clock.awake.now(io).nanoseconds - start_ns, std.time.ns_per_ms));
    result.at_end = health();
    state = .ended;
    log.info("'{s}' {s}; quitting for the verdict", .{ result.tape, result.ended });
    return true;
}

fn fail(f: Failure) void {
    for (failures[0..failure_count]) |have| if (have == f) return;
    failures[failure_count] = f;
    failure_count += 1;
}

fn health() ?Health {
    if (comptime !has_health) return null;
    return dvui.backend.health();
}

/// After the app has shut down, from its `main`: judge, write the verdict, and say what the
/// process exits with. `leaks`: what the debug allocator found at exit, or null where it does not
/// track allocations.
pub fn finish(leaks: ?bool) u8 {
    if (comptime !has_health) return 0;
    if (state == .waiting) {
        // The app quit before any tape ended: closed by hand, or it never drew a frame.
        fail(.interrupted);
        result.ended = "quit before the tape ended";
    }
    result.leaks = leaks;
    if (leaks == true and !expect.allow_leaks) fail(.leaks);
    if (result.timeouts > 0) fail(.lost_place);
    if (result.mismatches > 0) fail(.mismatched);

    // SDL's log from launch to exit: what shutdown logged counts too.
    const all = dvui.backend.Health.current.snapshot();
    result.sdl_errors = all.sdl_errors;
    result.sdl_warnings = all.sdl_warnings;
    if (all.sdl_errors > expect.max_sdl_errors) fail(.sdl_errors);
    if (expect.max_sdl_warnings) |max| if (all.sdl_warnings > max) fail(.sdl_warnings);

    if (result.at_end) |e| {
        const want_windows = expect.os_windows orelse if (result.at_start) |s| s.os_windows else e.os_windows;
        if (e.os_windows != want_windows) fail(.windows);
        if (expect.ns_windows) |want| if (e.ns_windows) |have| if (have != want) fail(.windows);
        if (e.presents < expect.min_presents) fail(.presents);
        if (over(expect.max_peak_draws, e.peak_frame.draws) or
            over(expect.max_peak_passes, e.peak_frame.passes) or
            over(expect.max_peak_target_switches, e.peak_frame.target_switches) or
            over(expect.max_frame_p99_us, e.frame_times.p99_us)) fail(.budget);
    }

    result.failures = failures[0..failure_count];
    result.pass = failure_count == 0;
    result.expect = expect;

    var buf: [16 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    std.zon.stringify.serialize(result, .{}, &w) catch {};
    w.writeByte('\n') catch {};
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = w.buffered() }) catch |err|
        log.err("could not write the verdict to {s}: {t}", .{ path, err });

    if (result.pass) {
        log.info("verdict: pass ('{s}' {s}, {d} ms) -> {s}", .{ result.tape, result.ended, result.wall_ms, path });
        return 0;
    }
    var names: [256]u8 = undefined;
    var nw: std.Io.Writer = .fixed(&names);
    for (result.failures, 0..) |f, i| nw.print("{s}{t}", .{ if (i > 0) ", " else "", f }) catch {};
    log.err("verdict: FAIL ({s}; '{s}' {s}) -> {s}", .{ nw.buffered(), result.tape, result.ended, path });
    if (all.first_sdl_error.len > 0) log.err("verdict: SDL's first error: {s}", .{all.first_sdl_error});
    return 1;
}

fn over(limit: ?u32, value: u32) bool {
    const max = limit orelse return false;
    return value > max;
}
