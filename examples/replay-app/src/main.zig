//! A plain dvui app with tape playback, and nothing of fizzy's.
//!
//! At launch it plays a live tape into its own window: two clicks on Count, a click into the field
//! and some typing, a command that resets the count, and one more click — so it ends on 1. The tape aims at widgets by their tags, so it plays at any
//! window size; the tape's pointer and its clicks are drawn over the app (`replay.overlay`); a
//! click or key from a person stops it. When it ends, the app prints what is on screen, as text
//! (`replay.Snapshot`) — the names a test or an automation client reads instead of pixels.
//!
//! What an app gives `replay`: a `Stage` (`idle` and `command` are enough for a live tape),
//! `LiveDriver.frame` and `Snapshot.beginFrame` first thing in its frame, and the overlay and
//! `Snapshot.endFrame` last.
const std = @import("std");
const dvui = @import("dvui");
const replay = @import("replay");
const Script = @import("tape").Script;

pub const dvui_app: dvui.App = .{
    .config = .{ .options = .{
        .size = .{ .w = 520, .h = 360 },
        .title = "Replay example",
    } },
    .frameFn = frame,
    .initFn = init,
    .deinitFn = deinit,
};
pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{ .logFn = dvui.App.logFn };

var gpa: std.mem.Allocator = undefined;
var count: usize = 0;
var driver: replay.LiveDriver = undefined;
var snapshot: replay.Snapshot = undefined;
/// The snapshot asked for when the last tape ended, until it is printed.
var shot: ?u32 = null;
var played_once = false;
/// The last tape's end has been read back.
var reported = true;

// ---- the stage: what this app is to a tape -------------------------------------------------

const stage_vtable: replay.Stage.VTable = .{ .idle = idle, .command = command };

/// Nothing here loads in the background: always settled.
fn idle(_: *anyopaque) bool {
    return true;
}

/// The one command this app offers a tape.
fn command(_: *anyopaque, id: []const u8, _: []const u8) void {
    if (std.mem.eql(u8, id, "example.reset")) count = 0;
}

// ---- the app -------------------------------------------------------------------------------

fn init(win: *dvui.Window) !void {
    gpa = win.gpa;
    driver = .init(.{ .ctx = &count, .vtable = &stage_vtable });
    snapshot = .init(gpa);
}

fn deinit(_: *dvui.Window) void {
    driver.deinit();
    snapshot.deinit();
}

/// The tape: written with `tape.Script`, aimed at tags rather than positions.
fn demoTape() !@import("tape").Tape.Owned {
    var s: Script = .init(gpa, "example", "Count, type, reset");
    errdefer s.deinit();
    s.check = replay.Input.check;
    s.check.live = true;
    try s.click(.{ .tag = "example.count" }, .{});
    try s.click(.{ .tag = "example.count" }, .{});
    try s.click(.{ .tag = "example.field", .x = 0.5, .y = 0.5 }, .{});
    try s.typeText("typed by a tape", .{});
    s.pause(600);
    try s.command("example.reset");
    try s.click(.{ .tag = "example.count" }, .{});
    return s.finish();
}

fn play() void {
    driver.play(demoTape() catch return) catch |err| return std.log.err("tape refused: {t}", .{err});
    reported = false;
}

fn frame() !dvui.App.Result {
    // First, before anything reads the frame's events.
    snapshot.beginFrame();
    driver.frame();
    if (!played_once) {
        played_once = true;
        play();
    }

    {
        var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .all(16), .background = true, .style = .window });
        defer box.deinit();
        dvui.label(@src(), "Clicked {d} times", .{count}, .{});
        if (dvui.button(@src(), "Count", .{}, .{ .tag = "example.count" })) count += 1;
        var entry = dvui.textEntry(@src(), .{}, .{ .tag = "example.field", .expand = .horizontal });
        entry.deinit();
        if (dvui.button(@src(), "Play the tape again", .{}, .{}) and !driver.playing()) play();
        if (driver.outcome) |o| dvui.label(@src(), "Last tape: {t}", .{o}, .{});
    }

    // When a tape ends, read the screen back as text.
    if (!driver.playing() and !reported) {
        reported = true;
        std.debug.print("The tape ended ({any}); the count is {d}.\n", .{ driver.outcome, count });
        shot = snapshot.request();
    }
    if (shot) |n| if (snapshot.get(n)) |text| {
        std.debug.print("What is on screen:\n{s}", .{text});
        shot = null;
    };

    // Last, over everything: the tape's pointer, then the snapshot written out.
    replay.overlay.drawLive(&driver, .{});
    snapshot.endFrame();
    return .ok;
}
