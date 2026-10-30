//! One motion clock: a late frame holds motion instead of skipping it. A dvui animation, a
//! `Spring` and a `FrameClock` tween, run through a jittery wall clock with a long first frame and
//! an idle gap before they start, show what they show under a steady 8 ms clock, and no frame moves
//! motion by more than a step. Real time (`MotionClock.wallFrameNs`) still counts the stall.
const std = @import("std");
const dvui = @import("dvui");
const glass = @import("glass");
const FrameClock = @import("glass").FrameClock;
const Spring = @import("Spring.zig");
const tape = @import("tape");
const wall = @import("replay").wall;

const MotionClock = glass.MotionClock;
const ms = std.time.ns_per_ms;
const duration_ms: f32 = 200;
const tune: Spring.Tune = .{};

/// One window run on a fake wall: `frame` ends the frame and begins the next at the wall `gap_ms`
/// later, through the motion clock as the backends do or, with `held` false, straight off the wall.
const Rig = struct {
    t: dvui.testing,
    clock: MotionClock = .{},
    wall_ns: i128,
    held: bool,
    max_step_ns: i128 = 0,

    fn init(held: bool) !Rig {
        const t = try dvui.testing.init(.{});
        return .{ .t = t, .wall_ns = t.window.frame_time_ns, .held = held };
    }

    fn deinit(r: *Rig) void {
        r.t.deinit();
    }

    fn frame(r: *Rig, gap_ms: i128) !void {
        const win = r.t.window;
        _ = try win.end(.{});
        const before = win.frame_time_ns;
        r.wall_ns += gap_ms * ms;
        const reading = r.clock.now(r.wall_ns);
        try win.begin(if (r.held) r.clock.frameTime(before, reading) else reading);
        r.clock.publish();
        r.max_step_ns = @max(r.max_step_ns, win.frame_time_ns - before);
    }
};

const Sample = struct { t_ms: f64, anim: f32, spring: f32, tween: f32 };

const anim_id: dvui.Id = @fromBackingInt(@intCast(0x6d6f_7469));

/// `lead` frames at `lead_gaps_ms` (the first long), an idle gap of 3 s, then everything starts
/// at that frame and `gaps_ms` follow. One `Sample` per frame from the start, by motion time.
fn run(r: *Rig, lead_gaps_ms: []const i128, gaps_ms: []const i128, out: *std.ArrayList(Sample)) !void {
    var spring: Spring = .{};
    var tween: FrameClock = .{};
    for (lead_gaps_ms) |g| {
        try r.frame(g);
        _ = spring.step(.{ .x = 0, .y = 0 }, dvui.secondsSinceLastFrame(), tune);
    }
    try r.frame(3_000);
    const start_ns = dvui.frameTimeNS();
    dvui.animation(anim_id, "a", .{ .end_time = @intFromFloat(duration_ms * 1000) });
    tween.step(start_ns);
    for (gaps_ms, 0..) |g, i| {
        if (i != 0) try r.frame(g);
        if (i != 0) tween.step(dvui.frameTimeNS());
        const moving = spring.step(.{ .x = 100, .y = 0 }, dvui.secondsSinceLastFrame(), tune);
        // A second step in the frame changes nothing.
        try std.testing.expectEqual(moving, spring.step(.{ .x = 100, .y = 0 }, 0.1, tune));
        const a = dvui.animationGet(anim_id, "a");
        try out.append(std.testing.allocator, .{
            .t_ms = @as(f64, @floatFromInt(dvui.frameTimeNS() - start_ns)) / ms,
            .anim = if (a) |an| an.value() else 1,
            .spring = spring.pos.x,
            .tween = tween.fraction(duration_ms),
        });
    }
}

fn steadyGaps(n: usize) ![]i128 {
    const gaps = try std.testing.allocator.alloc(i128, n);
    @memset(gaps, 8);
    return gaps;
}

fn jitterGaps(n: usize) ![]i128 {
    const gaps = try std.testing.allocator.alloc(i128, n);
    for (gaps, 0..) |*g, i| g.* = if (i % 2 == 0) 8 else 25;
    return gaps;
}

/// `s`'s field `f` at motion time `t_ms`, between the two samples around it.
fn at(s: []const Sample, t_ms: f64, comptime f: []const u8) f32 {
    var i: usize = 1;
    while (i + 1 < s.len and s[i].t_ms < t_ms) i += 1;
    const a = s[i - 1];
    const b = s[i];
    const k: f32 = @floatCast(std.math.clamp((t_ms - a.t_ms) / (b.t_ms - a.t_ms), 0, 1));
    return std.math.lerp(@field(a, f), @field(b, f), k);
}

test "the step a clock holds a frame to is the one a tween holds to" {
    try std.testing.expectEqual(FrameClock.max_step_ns, MotionClock.max_step_ns);
}

test "a jittery clock with a long first frame and an idle gap moves motion as a steady one does" {
    const lead_steady = [_]i128{ 8, 8, 8 };
    const lead_jitter = [_]i128{ 120, 8, 25 };
    const steady_gaps = try steadyGaps(60);
    defer std.testing.allocator.free(steady_gaps);
    const jitter_gaps = try jitterGaps(30);
    defer std.testing.allocator.free(jitter_gaps);

    var steady_rig = try Rig.init(true);
    defer steady_rig.deinit();
    var steady: std.ArrayList(Sample) = .empty;
    defer steady.deinit(std.testing.allocator);
    try run(&steady_rig, &lead_steady, steady_gaps, &steady);

    var jitter_rig = try Rig.init(true);
    defer jitter_rig.deinit();
    var jitter: std.ArrayList(Sample) = .empty;
    defer jitter.deinit(std.testing.allocator);
    try run(&jitter_rig, &lead_jitter, jitter_gaps, &jitter);

    // No frame moved motion by more than a step: not the 120 ms first frame, not the 3 s idle gap.
    try std.testing.expect(jitter_rig.max_step_ns <= MotionClock.max_step_ns);
    try std.testing.expect(steady_rig.max_step_ns <= MotionClock.max_step_ns);

    // The first frame of a motion shows its start.
    try std.testing.expectEqual(@as(f32, 0), jitter.items[0].anim);
    try std.testing.expectEqual(@as(f32, 0), jitter.items[0].spring);
    try std.testing.expectEqual(@as(f32, 0), jitter.items[0].tween);

    // Every frame after shows what the steady clock showed at that motion time.
    for (jitter.items) |s| {
        if (s.t_ms > steady.items[steady.items.len - 1].t_ms) break;
        try std.testing.expectApproxEqAbs(at(steady.items, s.t_ms, "anim"), s.anim, 2e-3);
        try std.testing.expectApproxEqAbs(at(steady.items, s.t_ms, "tween"), s.tween, 2e-3);
        try std.testing.expectApproxEqAbs(at(steady.items, s.t_ms, "spring"), s.spring, 1.0);
    }
    // And they went somewhere: the animation and tween finish, the spring has left 0.
    try std.testing.expectEqual(@as(f32, 1), jitter.items[jitter.items.len - 1].tween);
    try std.testing.expect(jitter.items[jitter.items.len - 1].spring > 50);
}

test "off the wall, the same frames skip the stall" {
    const lead = [_]i128{ 120, 8, 25 };
    const gaps = try jitterGaps(4);
    defer std.testing.allocator.free(gaps);
    var rig = try Rig.init(false);
    defer rig.deinit();
    var out: std.ArrayList(Sample) = .empty;
    defer out.deinit(std.testing.allocator);
    try run(&rig, &lead, gaps, &out);
    try std.testing.expect(rig.max_step_ns >= 3_000 * ms);
}

test "real time still counts a stall the motion clock held" {
    var rig = try Rig.init(true);
    defer rig.deinit();
    const wall_before = MotionClock.wallFrameNs();
    const frame_before = dvui.frameTimeNS();
    try rig.frame(8);
    try rig.frame(10_000);
    const wall_elapsed = MotionClock.wallFrameNs() - wall_before;
    try std.testing.expectEqual(@as(i128, 10_008 * ms), wall_elapsed);
    try std.testing.expect(dvui.frameTimeNS() - frame_before <= 8 * ms + MotionClock.max_step_ns);
    // A wall time on the frame clock's side of the line.
    try std.testing.expectEqual(dvui.frameTimeNS(), MotionClock.fromWall(MotionClock.wallFrameNs()));
}

test "a replay wait's timeout counts the wall the motion clock held" {
    var rig = try Rig.init(true);
    defer rig.deinit();
    // Stalls from before the replay started are not its wait's time.
    try rig.frame(3000);
    try rig.frame(3000);
    var seen: ?i128 = null;
    try std.testing.expectEqual(dvui.secondsSinceLastFrame() * 1000, wall.gapMs(&seen));
    const ops = [_]tape.Tape.Op{
        .{ .at = 0, .do = .{ .wait = .{ .until = .idle, .timeout = 10_000 } } },
    };
    const demo: tape.Tape = .{ .name = "timeout", .ops = &ops };
    var seq: tape.Sequencer = .init(&demo);
    var sink_state: TimeoutSink = .{};
    const sink: tape.Sequencer.Sink = .{ .ctx = &sink_state, .vtable = &TimeoutSink.vtable };
    try std.testing.expectEqual(.holding, seq.advance(0, 0, sink));
    // At 10 fps, a ten-second timeout expires on frame 100, despite 34 ms motion steps.
    for (0..100) |i| {
        try rig.frame(100);
        const progress = seq.advance(0, wall.gapMs(&seen), sink);
        try std.testing.expectEqual(if (i == 99) tape.Sequencer.Progress.yielded else .holding, progress);
    }
    try std.testing.expectEqual(@as(usize, 1), sink_state.failures);
    try std.testing.expect(seq.done());
    try std.testing.expect(dvui.secondsSinceLastFrame() * 1000 <= 34 + 1e-6);
}

const TimeoutSink = struct {
    failures: usize = 0,
    const vtable: tape.Sequencer.Sink.VTable = .{
        .locate = locate,
        .moveTo = moveTo,
        .button = button,
        .scroll = scroll,
        .key = bytes,
        .text = bytes,
        .command = command,
        .keyframe = keyframe,
        .holds = holds,
        .failed = failed,
    };
    fn locate(_: *anyopaque, _: tape.Tape.Target) ?tape.Sequencer.Point {
        unreachable;
    }
    fn moveTo(_: *anyopaque, _: tape.Sequencer.Point) void {
        unreachable;
    }
    fn button(_: *anyopaque, _: tape.Tape.Button, _: bool) void {
        unreachable;
    }
    fn scroll(_: *anyopaque, _: tape.Tape.Scroll) void {
        unreachable;
    }
    fn bytes(_: *anyopaque, _: []const u8) void {
        unreachable;
    }
    fn command(_: *anyopaque, _: tape.Tape.Command) void {
        unreachable;
    }
    fn keyframe(_: *anyopaque, _: *const tape.Tape.Keyframe) void {
        unreachable;
    }
    fn holds(_: *anyopaque, _: tape.Tape.Until) bool {
        return false;
    }
    fn failed(ctx: *anyopaque, failure: tape.Sequencer.Failure) void {
        const self: *TimeoutSink = @ptrCast(@alignCast(ctx));
        std.debug.assert(failure.what == .wait);
        self.failures += 1;
    }
};

test "a flick keeps its true speed across a stalled frame the motion clock held" {
    const Fling = @import("Fling.zig");
    var rig = try Rig.init(true);
    defer rig.deinit();
    const cw = dvui.currentWindow();
    var fling: Fling = .{};
    fling.begin();
    const step_ns = 8 * ms;
    const per_motion: f32 = 0.04;
    for (0..12) |i| {
        // The frame between motions 6 and 7 stalls, so the motion clock falls behind the wall.
        if (i == 6) try rig.frame(120);
        const before = cw.event_num;
        _ = try cw.addEventTouchMotion(.touch0, 0.5, 0.5, 0, 0.01);
        const stamped: i128 = @as(i128, @intCast(i)) * step_ns;
        glass.input_time.stamp(cw, before, stamped);
        fling.sampleTimed(per_motion, glass.input_time.get(cw.event_num));
    }
    try std.testing.expect(MotionClock.wallFrameNs() - dvui.frameTimeNS() > 50 * ms);
    try std.testing.expect(fling.releaseWindowedAt(.{}, 0.1, 11 * step_ns + 4 * ms));
    const true_speed = per_motion / (@as(f32, step_ns) / std.time.ns_per_s);
    try std.testing.expectApproxEqRel(true_speed, fling.vel, 0.1);
}
