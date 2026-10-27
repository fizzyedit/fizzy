//! Golden streams: a scenario driven on a `Sim` through a `Recorder`, the bytes compared with the
//! stream checked in beside this file (`streams/*.hex`, the stream as hex), and the stream played
//! back into a fresh `Sim` with nothing different. The first fails when the format moves (bump
//! `stream.version` and regenerate: a failure prints the new hex); the second when `Sim` or the
//! replay stops being deterministic.
const std = @import("std");
const Sim = @import("../Sim.zig");
const Platform = @import("../Platform.zig");
const Recorder = @import("../Recorder.zig");
const Replayer = @import("../Replayer.zig");
const Window = @import("../Window.zig");
const stream = @import("../stream.zig");

const ms = std.time.ns_per_ms;

/// A scenario's wiring: the Sim, the recorder over it, and the platform an app would hold.
const Rig = struct {
    sim: Sim,
    rec: Recorder,

    fn init(options: Sim.Options) !Rig {
        // The goldens hold the text they record, so they record it plainly.
        return initWith(options, .{ .redact = false, .read_clipboard = true });
    }

    fn initWith(options: Sim.Options, recording: Recorder.Options) !Rig {
        var rig: Rig = undefined;
        rig.sim = .init(std.testing.allocator, options);
        rig.rec = try .init(std.testing.allocator, rig.sim.platform(), recording);
        return rig;
    }

    fn deinit(rig: *Rig) void {
        rig.rec.deinit();
        rig.sim.deinit();
    }

    /// The app's side. The recorder is moved with the rig, so its inner platform is re-pointed.
    fn app(rig: *Rig) Platform {
        rig.rec.inner = rig.sim.platform();
        return rig.rec.platform();
    }

    fn drain(rig: *Rig) void {
        const p = rig.app();
        while (p.poll() != null) {}
    }
};

fn expectGolden(name: []const u8, hex: []const u8, actual: []const u8) !void {
    var want: [4096]u8 = undefined;
    var clean: [8192]u8 = undefined;
    var n: usize = 0;
    for (hex) |c| if (!std.ascii.isWhitespace(c)) {
        clean[n] = c;
        n += 1;
    };
    const golden = try std.fmt.hexToBytes(&want, clean[0..n]);
    std.testing.expectEqualSlices(u8, golden, actual) catch |err| {
        std.debug.print("golden stream '{s}' differs; the stream now is:\n", .{name});
        for (actual, 0..) |b, i| std.debug.print("{x:0>2}{s}", .{ b, if (i % 32 == 31) "\n" else "" });
        std.debug.print("\n", .{});
        return err;
    };
}

fn expectReplaysClean(bytes: []const u8) !Replayer.Report {
    var replay = try Replayer.init(std.testing.allocator, bytes);
    defer replay.deinit();
    const report = try replay.run();
    if (report.mismatch) |m| std.debug.print("replay differs at event {d}:\n  stream: {?s}\n  sim:    {?s}\n", .{ m.index, m.expected, m.actual });
    try std.testing.expect(report.clean());
    return report;
}

fn typing(rig: *Rig) !void {
    const p = rig.app();
    const w = try p.openWindow(.{ .title = "editor", .position = .{ .x = 100, .y = 100 }, .size = .{ .w = 800, .h = 600 } });
    p.setTextInput(w, true);
    rig.drain();
    _ = p.now();

    rig.sim.movePointer(rig.sim.desktopPoint(w, .{ .x = 200, .y = 120 }));
    rig.sim.pressButton(.left);
    rig.sim.releaseButton(.left);
    rig.sim.wheel(0, -2, false);
    rig.sim.key(.left_shift, .down);
    rig.sim.tap(.h);
    rig.sim.key(.left_shift, .up);
    rig.sim.tap(.i);
    rig.sim.typeText("é");
    rig.sim.advance(3 * ms);
    rig.drain();

    p.setWindowState(w, .maximized);
    p.setTitle(w, "editor — saved");
    rig.sim.advance(10 * ms);
    rig.drain();
    _ = p.now();
    p.closeWindow(w);
}

test "golden: typing and pointing in one window" {
    var rig = try Rig.init(.{});
    defer rig.deinit();
    try typing(&rig);
    try expectGolden("typing", @embedFile("streams/typing.hex"), rig.rec.bytes());
    const report = try expectReplaysClean(rig.rec.bytes());
    try std.testing.expect(report.expected > 10);
}

fn displaysAndWindows(rig: *Rig) !void {
    const p = rig.app();
    const main = try p.openWindow(.{ .position = .{ .x = 50, .y = 50 }, .size = .{ .w = 400, .h = 300 } });
    const tip = try p.openWindow(.{ .kind = .overlay, .parent = main, .position = .{ .x = 60, .y = 60 }, .size = .{ .w = 100, .h = 40 } });
    rig.drain();

    const second = rig.sim.addDisplay(.{ .name = "Right", .bounds = .{ .x = 1920, .w = 1280, .h = 800 }, .scale = 2 });
    const list = try p.displays(std.testing.allocator);
    Platform.freeDisplays(std.testing.allocator, list);
    p.setWindowPosition(main, .{ .x = 2000, .y = 100 });
    rig.sim.advance(10 * ms);
    rig.drain();

    rig.sim.setDisplayScale(second, 3);
    rig.sim.advance(1 * ms);
    rig.drain();
    p.raiseWindow(tip);
    p.setCursor(main, .ibeam);
    rig.sim.copyFromOutside("copied elsewhere");
    rig.drain();
    try p.setClipboardText("copied here");
    rig.sim.removeDisplay(second);
    rig.sim.advance(1 * ms);
    rig.drain();
    const after = try p.displays(std.testing.allocator);
    Platform.freeDisplays(std.testing.allocator, after);
}

test "golden: displays come and go under windows, the clipboard changes hands" {
    var rig = try Rig.init(.{ .displays = &.{.{ .top_inset = 24 }} });
    defer rig.deinit();
    try displaysAndWindows(&rig);
    try expectGolden("displays", @embedFile("streams/displays.hex"), rig.rec.bytes());
    _ = try expectReplaysClean(rig.rec.bytes());
}

test "a stream names nothing the platform picked" {
    // The same session on a platform whose window and display numbers are all different.
    var a = try Rig.init(.{});
    defer a.deinit();
    try typing(&a);

    var b = try Rig.init(.{});
    defer b.deinit();
    b.sim.next_window_id = 0x7fff_0000_1234;
    b.sim.next_display_id = 900;
    try typing(&b);
    try std.testing.expectEqualSlices(u8, a.rec.bytes(), b.rec.bytes());

    var c = try Rig.init(.{ .displays = &.{.{ .top_inset = 24 }} });
    defer c.deinit();
    try displaysAndWindows(&c);
    var d = try Rig.init(.{ .displays = &.{.{ .top_inset = 24 }} });
    defer d.deinit();
    d.sim.next_window_id = 5000;
    d.sim.next_display_id = 77;
    try displaysAndWindows(&d);
    try std.testing.expectEqualSlices(u8, c.rec.bytes(), d.rec.bytes());
}

test "a replay says where the Sim and the stream part" {
    var rig = try Rig.init(.{});
    defer rig.deinit();
    try typing(&rig);

    // The same stream with the second key tap's down edge turned into a wheel turn is no
    // longer one a Sim would write: build it by rewriting the records.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var reader = try stream.Reader.init(rig.rec.bytes());
    var w = try stream.Writer.init(std.testing.allocator);
    defer w.deinit();
    var dropped = false;
    while (try reader.next(arena.allocator())) |record| {
        // Leave out the first focus event the stream saw, as if the platform had not sent it.
        if (!dropped and record.body == .event and record.body.event.payload == .focus) {
            dropped = true;
            continue;
        }
        try w.write(record);
    }
    try std.testing.expect(dropped);

    var replay = try Replayer.init(std.testing.allocator, w.bytes.items);
    defer replay.deinit();
    const report = try replay.run();
    try std.testing.expect(!report.clean());
    try std.testing.expectEqual(report.expected + 1, report.actual);
    try std.testing.expect(report.mismatch != null);
}

test "a stream of touches and drops is read and left alone" {
    var rig = try Rig.init(.{});
    defer rig.deinit();
    const p = rig.app();
    const w = try p.openWindow(.{});
    rig.drain();
    rig.sim.dragBegin(.{ .files = &.{"/tmp/a.png"} });
    rig.sim.movePointer(rig.sim.desktopPoint(w, .{ .x = 10, .y = 10 }));
    _ = rig.sim.dragRelease();
    rig.drain();
    const report = try expectReplaysClean(rig.rec.bytes());
    try std.testing.expect(report.skipped >= 2);
}

test "the default recording holds no text, keys' characters, titles or clipboard" {
    var rig = try Rig.initWith(.{ .displays = &.{.{ .top_inset = 24 }} }, .{});
    defer rig.deinit();
    try typing(&rig);
    rig.sim.copyFromOutside("hunter2-secret");
    rig.drain();
    try rig.app().setClipboardText("hunter2-secret");
    for ([_][]const u8{ "editor", "saved", "hunter2", "é" }) |plain| {
        try std.testing.expect(std.mem.indexOf(u8, rig.rec.bytes(), plain) == null);
    }
    _ = try expectReplaysClean(rig.rec.bytes());
}

test "the clipboard is read only when asked" {
    var rig = try Rig.initWith(.{}, .{ .redact = false });
    defer rig.deinit();
    const p = rig.app();
    _ = try p.openWindow(.{ .size = .{ .w = 200, .h = 100 } });
    rig.drain();
    rig.sim.copyFromOutside("seen");
    rig.drain();
    try std.testing.expect(std.mem.indexOf(u8, rig.rec.bytes(), "seen") == null);
    _ = try expectReplaysClean(rig.rec.bytes());
}

test "a recording stops at its cap, whole, and still replays" {
    var rig = try Rig.initWith(.{ .displays = &.{.{ .top_inset = 24 }} }, .{ .max_bytes = 200 });
    defer rig.deinit();
    try typing(&rig);
    try std.testing.expect(rig.rec.full);
    try std.testing.expect(rig.rec.bytes().len < 200 + 64);
    var replay = try Replayer.init(std.testing.allocator, rig.rec.bytes());
    defer replay.deinit();
    _ = try replay.run();
}

test "the default recording holds no dropped paths or text" {
    var rig = try Rig.initWith(.{}, .{});
    defer rig.deinit();
    const w = try rig.app().openWindow(.{});
    rig.drain();
    rig.sim.dragBegin(.{ .files = &.{ "/Users/someone/taxes.pdf", "/Users/someone/b.png" } });
    rig.sim.movePointer(rig.sim.desktopPoint(w, .{ .x = 10, .y = 10 }));
    _ = rig.sim.dragRelease();
    rig.sim.dragBegin(.{ .text = "dragged-secret" });
    rig.sim.movePointer(rig.sim.desktopPoint(w, .{ .x = 12, .y = 12 }));
    _ = rig.sim.dragRelease();
    rig.drain();
    for ([_][]const u8{ "someone", "taxes", "dragged" }) |plain| {
        try std.testing.expect(std.mem.indexOf(u8, rig.rec.bytes(), plain) == null);
    }
    const report = try expectReplaysClean(rig.rec.bytes());
    try std.testing.expect(report.skipped >= 2);
}
