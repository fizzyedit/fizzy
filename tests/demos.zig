//! Every demo fizzy ships with (`Editor.Demo.catalog`), played through fizzy's own stage in the
//! whole editor, as `Entry` brings it up headless. A renamed anchor, a wait that never holds or a
//! document owner whose snapshot does not put it back fails here, before it fails on fizzyed.it.
//!
//! A binary of its own (`zig build test-integration`, "fizzy-demo-tests"): the whole editor
//! leaves module state behind in the plugins it links when it goes down, so a process brings it
//! up once — `tests/integration.zig` already does, for "headless: …".
const std = @import("std");
const dvui = @import("dvui");
const fizzy = @import("fizzy");
const automation = @import("app").automation;
const workbench = @import("workbench");

/// The app's frame as `Entry` runs it: the demo player, the frame target, the editor.
fn headlessFrame() !dvui.App.Result {
    return fizzy.Entry.AppFrame();
}

/// The whole editor over dvui's testing backend, in a profile of its own.
const BundledApp = struct {
    t: dvui.testing,
    tmp: std.testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8,
    entry: *fizzy.Entry,
    editor: *fizzy.Editor,

    // The app's own lifetime, whose exit leaks by design (`Editor.unloadPluginLibs`).
    const gpa = std.heap.smp_allocator;

    fn up(self: *BundledApp) !void {
        self.t = try dvui.testing.init(.{ .allocator = gpa, .window_size = .{ .w = 1280, .h = 800 } });
        self.tmp = std.testing.tmpDir(.{});
        const len = try self.tmp.dir.realPath(dvui.io, self.root_buf[0 .. self.root_buf.len - 1]);
        self.root_buf[len] = 0;
        const root = self.root_buf[0..len :0];
        @import("app").profile.root = root;
        self.entry = try gpa.create(fizzy.Entry);
        // The profile as the executable's folder too: no bundled plugin is built as a dylib there,
        // so each registers the copy linked in, whatever a build left beside the checkout.
        self.entry.* = .{ .allocator = gpa, .window = self.t.window, .root_path = root };
        self.editor = try gpa.create(fizzy.Editor);
        fizzy.setInstances(self.entry, self.editor);
        self.editor.* = try fizzy.Editor.init(self.entry);
        workbench.runtime.setWorkbench(&self.editor.workbench);
        try self.editor.postInit();
        try dvui.testing.settle(headlessFrame);
    }

    fn down(self: *BundledApp) void {
        self.editor.deinit() catch {};
        gpa.destroy(self.editor);
        gpa.destroy(self.entry);
        @import("app").profile.root = null;
        self.tmp.cleanup();
        self.t.deinit();
    }
};

/// A moment straight play reached with nothing left due at it, the app idle: what a seek to `now`
/// must land on.
const DemoMoment = struct { now: f64, cursor: usize, print: u64 };

/// The seed the seeks below are drawn with: fixed, so a failure names a moment that fails again.
const bundled_seek_seed: u64 = 0xf122_de40;
const bundled_random_seeks = 16;

test "demo: every bundled demo plays to the end through fizzy's stage, and a seek lands on what playing reached" {
    var app: BundledApp = undefined;
    try app.up();
    defer app.down();
    const p = &app.editor.demo.player;
    const gpa = std.testing.allocator;
    var moments: std.ArrayList(DemoMoment) = .empty;
    defer moments.deinit(gpa);
    var prng: std.Random.DefaultPrng = .init(bundled_seek_seed);
    const random = prng.random();

    for (fizzy.Editor.Demo.catalog.entries) |e| {
        try app.editor.demo.play(e.name);

        // Straight through, on the testing backend's clock (100 ms a step), keeping every moment
        // a seek could be asked to reproduce.
        moments.clearRetainingCapacity();
        var frames: usize = 0;
        while (p.state != .ended and frames < 20_000) : (frames += 1) {
            _ = try dvui.testing.step(headlessFrame);
            if (p.state != .playing or p.seq.cursor == 0) continue;
            if (p.seq.nextAt() <= p.seq.now or !p.stage.idle()) continue;
            try moments.append(gpa, .{ .now = p.seq.now, .cursor = p.seq.cursor, .print = p.stage.fingerprint().? });
        }
        errdefer std.debug.print("demo '{s}': {t} after {d} frames at {d:.0} of {d} ms\n", .{ e.name, p.state, frames, p.seq.now, p.duration() });
        try std.testing.expectEqual(automation.Player.State.ended, p.state);
        try std.testing.expect(p.seq.done());
        try std.testing.expectEqual(@as(u32, 0), p.timeouts);
        try std.testing.expectEqual(@as(u32, 0), p.mismatches);
        try std.testing.expect(moments.items.len > bundled_random_seeks);

        // Seeks to random moments, and the first of each chapter, in an order that goes back and
        // forth: from snapshots, from the keyframe, and forward on the tape's own state.
        const tape = p.tape().?;
        var picks: std.ArrayList(usize) = .empty;
        defer picks.deinit(gpa);
        for (0..bundled_random_seeks) |_| try picks.append(gpa, random.uintLessThan(usize, moments.items.len));
        for (tape.chapters) |c| {
            for (moments.items, 0..) |m, i| if (m.now >= @as(f64, @floatFromInt(c.at))) {
                try picks.insert(gpa, random.uintAtMost(usize, picks.items.len), i);
                break;
            };
        }
        var wrong: usize = 0;
        for (picks.items) |i| {
            const want = moments.items[i];
            p.seek(want.now);
            var steps: usize = 0;
            while ((p.state == .seeking or !p.stage.idle()) and steps < 400) : (steps += 1) {
                _ = try dvui.testing.step(headlessFrame);
            }
            const got = p.stage.fingerprint().?;
            if (p.state == .paused and p.seq.cursor == want.cursor and got == want.print) continue;
            wrong += 1;
            std.debug.print("demo '{s}': a seek to {d:.0} ms is {t} at op {d}, fingerprint {x}; playing reached op {d}, fingerprint {x}\n", .{ e.name, want.now, p.state, p.seq.cursor, got, want.cursor, want.print });
        }
        try std.testing.expectEqual(@as(usize, 0), wrong);
        // Every snapshot moment a seek replayed through was reached exactly, too.
        try std.testing.expectEqual(@as(u32, 0), p.mismatches);
        try std.testing.expectEqual(@as(u32, 0), p.timeouts);
    }
    p.unload();
    try dvui.testing.settle(headlessFrame);
}
