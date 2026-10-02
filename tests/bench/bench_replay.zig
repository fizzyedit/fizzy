//! `zig build bench-replay` — what a seek costs, and what it used to.
//!
//! The demo player (`app.automation.Player`) against a realistic scene in dvui's headless
//! window: a row of tagged buttons and the text editor's widget over one of this repo's sources,
//! driven by a recording-shaped tape (glide, click, glide into the text, click, type a word) a
//! few minutes long. It plays a stretch live, then seeks from the end back to just before it —
//! a rewind to the start and a replay of everything — two ways:
//!
//!   * **silent**: `Player.frames` with no budget, every replay frame run unseen inside one
//!     displayed frame. Reports the frames it needed and their cost; at fizzy's budget
//!     (`Player.budget_ns`, 8 ms) the same work is spread over `total / budget` displayed frames.
//!   * **shown**: no budget, as the player did before — a displayed frame per replay frame.
//!
//! Prints rather than asserts, like `bench-text`; the testing backend does no GPU work, so this is
//! the CPU side of a frame. Compare runs at the same `-Doptimize`.
const std = @import("std");
const dvui = @import("dvui");
const automation = @import("app").automation;
const TextEntryWidget = @import("text").TextEntryWidget;

const sample = @embedFile("sample");

const buttons = 8;
const button_tags = blk: {
    var tags: [buttons][]const u8 = undefined;
    for (&tags, 0..) |*t, i| t.* = std.fmt.comptimePrint("bench.button.{d}", .{i});
    break :blk tags;
};

var text: std.ArrayListUnmanaged(u8) = .empty;
var player: automation.Player = undefined;
var clock: i128 = 0;
var presses: usize = 0;

const Stage = struct {
    fn stage() automation.Stage {
        return .{ .ctx = undefined, .vtable = &.{
            .begin = begin,
            .end = end,
            .keyframe = keyframe,
            .idle = idle,
            .command = command,
            .chordFor = chordFor,
            .commandTitle = commandTitle,
            .fastForward = fastForward,
        } };
    }
    fn begin(_: *anyopaque, _: *const automation.Tape) void {}
    fn end(_: *anyopaque) void {}
    fn keyframe(_: *anyopaque, kf: *const automation.Tape.Keyframe) void {
        text.clearRetainingCapacity();
        text.appendSlice(std.testing.allocator, kf.files[0].text) catch unreachable;
        presses = 0;
    }
    fn idle(_: *anyopaque) bool {
        return true;
    }
    fn command(_: *anyopaque, _: []const u8) void {}
    fn chordFor(_: *anyopaque, _: []const u8) ?@import("app").keymap.chord.Stroke {
        return null;
    }
    fn commandTitle(_: *anyopaque, _: []const u8) ?[]const u8 {
        return null;
    }
    fn fastForward(_: *anyopaque, _: bool) void {}
};

fn frame() !dvui.App.Result {
    return player.frames(dvui.currentWindow(), run, &clock);
}

fn run() !dvui.App.Result {
    player.frame();
    {
        var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
        defer col.deinit();
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer row.deinit();
            for (button_tags, 0..) |tag, i| {
                if (dvui.button(@src(), "Button", .{}, .{ .id_extra = i, .tag = tag })) presses += 1;
            }
        }
        var te: TextEntryWidget = undefined;
        te.init(@src(), .{
            .multiline = true,
            .text = .{ .array_list = .{ .backing = &text, .allocator = std.testing.allocator, .limit = 1 << 20 } },
        }, .{ .expand = .both, .tag = "bench.field" });
        te.processEvents();
        te.draw();
        te.deinit();
    }
    automation.overlay.draw(&player);
    return .ok;
}

/// `cycles` rounds of: click a button, click into the text, type a word.
fn recording(cycles: usize) !automation.Tape.Owned {
    var s: automation.Script = .init(std.testing.allocator, "bench", "Bench");
    errdefer s.deinit();
    try s.keyframe(.{ .root = "demo://bench", .files = &.{.{ .path = "doc", .text = sample }} });
    var word: [32]u8 = undefined;
    for (0..cycles) |i| {
        if (i % 10 == 0) try s.chapter("Ten more");
        try s.click(.{ .tag = button_tags[i % buttons] }, .{});
        const y: f32 = @as(f32, @floatFromInt(i % 17)) / 20 + 0.05;
        try s.click(.{ .tag = "bench.field", .x = 0.3, .y = y }, .{});
        try s.typeText(try std.fmt.bufPrint(&word, "word{d} ", .{i}), .{});
    }
    return s.finish();
}

fn nowNs() i96 {
    return std.Io.Clock.awake.now(std.testing.io).nanoseconds;
}

fn ms(ns: i96) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

test "bench replay: a seek, silent and shown" {
    var t = try dvui.testing.init(.{ .allocator = std.testing.allocator, .window_size = .{ .w = 1280, .h = 800 } });
    defer t.deinit();
    defer text.deinit(std.testing.allocator);
    player = .init(Stage.stage());
    defer player.deinit();
    try dvui.testing.settle(frame);

    std.debug.print("\n== a seek across a recording — {s} ==\n", .{@tagName(@import("builtin").mode)});
    std.debug.print("{s:>7} {s:>8} | {s:>13} | {s:>7} {s:>8} {s:>9} {s:>10} | {s:>11}\n", .{
        "cycles", "demo s", "live us/frame", "frames", "silent", "us/frame", "at 8 ms", "shown, was",
    });
    for ([_]usize{ 10, 40, 120 }) |cycles| {
        player.load(try recording(cycles), .{});
        player.budget_ns = std.math.maxInt(i64);
        const duration: f64 = @floatFromInt(player.duration());

        // Live: a stretch of ordinary play, a frame per 100 ms of demo.
        _ = try dvui.testing.step(frame);
        const live_frames = 40;
        const l0 = nowNs();
        for (0..live_frames) |_| _ = try dvui.testing.step(frame);
        const live_us = ms(nowNs() - l0) * 1000 / live_frames;

        // To the end, then back to just before it: the whole tape replayed, silently.
        player.seek(duration);
        while (player.state == .seeking) _ = try dvui.testing.step(frame);
        player.seek(duration - 50);
        const s0 = nowNs();
        while (player.state == .seeking) _ = try dvui.testing.step(frame);
        const silent_ms = ms(nowNs() - s0);
        const runs = player.seek_stats.silent + 1;

        // And as it was: a displayed frame per replay frame.
        player.budget_ns = 0;
        player.seek(duration);
        while (player.state == .seeking) _ = try dvui.testing.step(frame);
        player.seek(duration - 50);
        while (player.state == .seeking) _ = try dvui.testing.step(frame);
        const shown = player.seek_stats.shown;

        std.debug.print("{d:>7} {d:>8.0} | {d:>13.0} | {d:>7} {d:>8.1} {d:>9.0} {d:>10.0} | {d:>11}\n", .{
            cycles,
            duration / 1000,
            live_us,
            runs,
            silent_ms,
            silent_ms * 1000 / @as(f64, @floatFromInt(runs)),
            @ceil(silent_ms / 8),
            shown,
        });
        player.unload();
    }
    std.debug.print("  frames: replay frames the seek needed; silent: their cost, ms, in one displayed frame;\n", .{});
    std.debug.print("  at 8 ms: displayed frames at fizzy's budget; shown, was: displayed frames without one.\n", .{});
}
