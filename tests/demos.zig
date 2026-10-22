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
const sdk = fizzy.sdk;

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

test "demo: the rail's Files anchor the scripts spell out is the one fizzy publishes" {
    try std.testing.expectEqualStrings("fizzy.rail:" ++ workbench.view_files, fizzy.Editor.Demo.catalog.files_icon);
}

test "demo: every bundled demo plays to the end through fizzy's stage, a seek lands on what playing reached, and the person's own folder is theirs again after" {
    var app: BundledApp = undefined;
    try app.up();
    defer app.down();
    const p = &app.editor.demo.player;
    const gpa = std.testing.allocator;

    // What the person had before the demos: a folder opened from a zip's bytes, as the web's
    // `?open=/site.zip` opens the site. There is no file to open it from again.
    const site = try openZipFromBytes(app.editor, "site.zip", &.{.{ "README.md", "# The site\n" }});
    defer gpa.free(site);
    const docs_before = app.editor.app.open_files.count();
    const active_before = try gpa.dupe(u8, activePath(app.editor));
    defer gpa.free(active_before);
    try std.testing.expectEqualStrings("site.zip", active_before);
    var moments: std.ArrayList(DemoMoment) = .empty;
    defer moments.deinit(gpa);
    var prng: std.Random.DefaultPrng = .init(bundled_seek_seed);
    const random = prng.random();

    for (fizzy.Editor.Demo.catalog.entries) |e| {
        try app.editor.demo.play(e.name);

        // Straight through, on the testing backend's clock (100 ms a step), keeping every moment
        // a seek could be asked to reproduce.
        moments.clearRetainingCapacity();
        var steady: Steady = .{};
        defer steady.deinit(gpa);
        var frames: usize = 0;
        while (p.state != .ended and frames < 20_000) : (frames += 1) {
            _ = try dvui.testing.step(headlessFrame);
            try steady.frame(gpa, app.editor, e.name);
            if (p.state != .playing or p.seq.cursor == 0) continue;
            if (p.seq.nextAt() <= p.seq.now or !p.stage.idle()) continue;
            // Not mid-drag: a seek there lands with the button held, and one on from it lets go
            // first and replays from the keyframe (`Player.letGo`), which replays a drag cut short
            // no better than it did — a moment the player takes no snapshot at either.
            if (p.input.held.count() > 0) continue;
            try moments.append(gpa, .{ .now = p.seq.now, .cursor = p.seq.cursor, .print = p.stage.fingerprint().? });
        }
        errdefer std.debug.print("demo '{s}': {t} after {d} frames at {d:.0} of {d} ms\n", .{ e.name, p.state, frames, p.seq.now, p.duration() });
        try std.testing.expectEqual(automation.Player.State.ended, p.state);
        try std.testing.expect(p.seq.done());
        try std.testing.expectEqual(@as(u32, 0), p.timeouts);
        try std.testing.expectEqual(@as(u32, 0), p.mismatches);
        try std.testing.expect(moments.items.len > bundled_random_seeks);
        try steady.landed(e.name);

        // Seeks to random moments, and the first of each chapter, in an order that goes back and
        // forth: from snapshots, from the keyframe, and forward on the tape's own state.
        const tape = p.tape().?;
        // A button aimed at an anchor, never a coordinate (docs/AUTOMATION.md).
        if (tape.firstButtonOffAnchor()) |i| {
            std.log.err("demo '{s}': op {d} presses or releases off an anchor; aim at one (docs/AUTOMATION.md)", .{ tape.name, i });
            return error.ButtonOffAnchor;
        }
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
            const from_now = p.seq.now;
            p.seek(want.now);
            var steps: usize = 0;
            while ((p.state == .seeking or !p.stage.idle()) and steps < 400) : (steps += 1) {
                _ = try dvui.testing.step(headlessFrame);
            }
            // A seek back lands from a snapshot whenever its scene has one before the moment,
            // whatever the window was arranged as since: a snapshot holds the layout too. (A
            // snapshot is still refused when a document it held has closed since; no bundled demo
            // closes one mid-scene, and one that does wants a keyframe after the close.)
            if (want.now < from_now and p.seek_stats.restored == null) {
                const kf = tape.keyframeBefore(want.now);
                for (p.snapshots.items) |snap| if (snap.scene == kf and snap.at <= want.now) {
                    std.debug.print("demo '{s}': a seek back from {d:.0} to {d:.0} ms replayed from the keyframe past a snapshot at {d:.0}\n", .{ e.name, from_now, want.now, snap.at });
                    return error.SeekPastSnapshot;
                };
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

    // The `demos` service lists them, fizzy's own in its order, with each one's length and chapters.
    const api = app.editor.demos.api;
    const catalog = fizzy.Editor.Demo.catalog;
    try std.testing.expectEqual(catalog.entries.len, api.list().len);
    for (catalog.entries, api.list()) |e, info| {
        try std.testing.expectEqualStrings(e.name, info.name);
        try std.testing.expectEqual(sdk.services.demos.Api.Origin.bundled, info.origin);
        try std.testing.expect(info.ms > 0);
    }

    // A plugin's demo is listed beside them; one reusing a name fizzy has, and a live tape, are not.
    const generation = api.generation();
    const guide = try encodedDemo("guide", true);
    defer gpa.free(guide);
    const live = try encodedDemo("live", false);
    defer gpa.free(live);
    const host = &app.editor.app.host;
    try host.registerDemo(.{ .name = "a-guide", .title = "A guide", .tape = guide });
    try host.registerDemo(.{ .name = "tour", .title = "Not the tour", .tape = guide });
    try host.registerDemo(.{ .name = "a-live-tape", .title = "Live", .tape = live });
    try std.testing.expect(api.generation() != generation);
    const listed = api.list();
    try std.testing.expectEqual(catalog.entries.len + 1, listed.len);
    const added = listed[listed.len - 1];
    try std.testing.expectEqualStrings("a-guide", added.name);
    try std.testing.expectEqualStrings("A guide", added.title);
    try std.testing.expectEqual(sdk.services.demos.Api.Origin.plugin, added.origin);
    try std.testing.expectEqual(@as(usize, 2), added.chapters.len);

    // It plays by name, to its end, named the one playing while it does.
    try std.testing.expectEqual(sdk.services.demos.Api.Play.unknown, api.play("no-such-demo", 0));
    try std.testing.expectEqual(sdk.services.demos.Api.Play.started, api.play("a-guide", 0));
    try std.testing.expectEqualStrings("a-guide", api.current().?);
    var frames: usize = 0;
    while (p.state != .ended and frames < 2_000) : (frames += 1) _ = try dvui.testing.step(headlessFrame);
    try std.testing.expectEqual(automation.Player.State.ended, p.state);
    try std.testing.expectEqual(@as(u32, 0), p.timeouts);

    // From a chapter, it starts there.
    const second = added.chapters[1].at;
    try std.testing.expectEqual(sdk.services.demos.Api.Play.started, api.play("a-guide", second));
    frames = 0;
    while (p.state == .seeking and frames < 400) : (frames += 1) _ = try dvui.testing.step(headlessFrame);
    try std.testing.expect(p.seq.now >= @as(f64, @floatFromInt(second)));

    // The window's material a tape sets is the demo's: a cut and the end give the person theirs.
    const settings = &app.editor.app.settings;
    p.unload();
    try dvui.testing.settle(headlessFrame);
    settings.window_material = .blur;
    const glassy = try materialDemo();
    defer gpa.free(glassy);
    try app.editor.demo.playTape(glassy);
    frames = 0;
    while (p.state != .ended and frames < 2_000) : (frames += 1) _ = try dvui.testing.step(headlessFrame);
    try std.testing.expectEqual(fizzy.core.material.Kind.frost, settings.window_material);
    // Written while the tape has it frosted, the file says what the person chose.
    app.editor.flushSettings();
    {
        const path = try std.fs.path.join(gpa, &.{ app.editor.app.config_folder, "settings.zon" });
        defer gpa.free(path);
        const written = try std.Io.Dir.cwd().readFileAlloc(dvui.io, path, gpa, .limited(1 << 20));
        defer gpa.free(written);
        try std.testing.expect(std.mem.find(u8, written, ".window_material = .blur") != null);
    }
    p.seek(0);
    frames = 0;
    while (p.state == .seeking and frames < 400) : (frames += 1) _ = try dvui.testing.step(headlessFrame);
    try std.testing.expectEqual(fizzy.core.material.Kind.blur, settings.window_material);
    p.seek(@floatFromInt(p.duration()));
    frames = 0;
    while (p.state == .seeking and frames < 400) : (frames += 1) _ = try dvui.testing.step(headlessFrame);
    try std.testing.expectEqual(fizzy.core.material.Kind.frost, settings.window_material);
    p.unload();
    try dvui.testing.settle(headlessFrame);
    try std.testing.expectEqual(fizzy.core.material.Kind.blur, settings.window_material);
    settings.window_material = .liquid;

    // A demo's panes are its own: a cut is one pane again, and the end gives back the person's.
    {
        const wb = &app.editor.workbench;
        p.unload();
        try dvui.testing.settle(headlessFrame);
        // The person's own split first: a file of theirs in a pane of its own beside the zip's.
        const readme = try gpa.print("{s}/notes.md", .{app.root_buf[0 .. std.mem.findScalar(u8, &app.root_buf, 0) orelse 0]});
        defer gpa.free(readme);
        try std.Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = readme, .data = "# Notes\n" });
        const beside = wb.newGroupingID();
        _ = try app.editor.openFilePath(readme, beside);
        // Loaded off the UI thread: it lands a frame or more on.
        frames = 0;
        while (app.editor.app.host.docFromPath(readme) == null and frames < 200) : (frames += 1) _ = try dvui.testing.step(headlessFrame);
        try dvui.testing.settle(headlessFrame);
        const zip_pane = (app.editor.app.host.docFromPath("site.zip") orelse return error.TestUnexpectedResult).owner.documentGrouping(app.editor.app.host.docFromPath("site.zip").?);
        try std.testing.expect(zip_pane != beside);
        const panes_before = wb.workspaces.count();
        try std.testing.expectEqual(@as(usize, 2), panes_before);
        const split = try splitDemo();
        defer gpa.free(split);
        try app.editor.demo.playTape(split);
        frames = 0;
        while (p.state != .ended and frames < 2_000) : (frames += 1) _ = try dvui.testing.step(headlessFrame);
        try std.testing.expectEqual(@as(u32, 0), p.timeouts);
        try std.testing.expectEqual(@as(usize, 2), wb.workspaces.count());
        p.seek(0);
        frames = 0;
        while ((p.state == .seeking or wb.workspaces.count() != 1) and frames < 400) : (frames += 1) _ = try dvui.testing.step(headlessFrame);
        try std.testing.expectEqual(@as(usize, 1), wb.workspaces.count());
        p.unload();
        try dvui.testing.settle(headlessFrame);
        frames = 0;
        while (app.editor.app.host.docFromPath(readme) == null and frames < 200) : (frames += 1) _ = try dvui.testing.step(headlessFrame);
        try dvui.testing.settle(headlessFrame);
        try std.testing.expectEqual(panes_before, wb.workspaces.count());
        try std.testing.expect(wb.held_panes == null and !wb.holding);
        // Each document back in its own pane, and both panes still there after a rebuild more.
        const back = app.editor.app.host.docFromPath(readme) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(beside, back.owner.documentGrouping(back));
        const zip_back = app.editor.app.host.docFromPath("site.zip") orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(zip_pane, zip_back.owner.documentGrouping(zip_back));
        try dvui.testing.settle(headlessFrame);
        try std.testing.expectEqual(panes_before, wb.workspaces.count());
        try app.editor.rawCloseFileID(back.id);
        try dvui.testing.settle(headlessFrame);
    }

    // A demo plays on a stage of its own: unsaved work of the person's never stops one, and is
    // there after it exactly as it was — still open, still unsaved, its history and its pane
    // theirs — through a play, a seek back and an end, with settings.zon never written.
    {
        const wb = &app.editor.workbench;
        const draft = try gpa.print("{s}/draft.md", .{app.root_buf[0 .. std.mem.findScalar(u8, &app.root_buf, 0) orelse 0]});
        defer gpa.free(draft);
        try std.Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = draft, .data = "# Draft\n" });
        _ = try app.editor.openFilePath(draft, wb.currentGroupingID());
        frames = 0;
        while (host.docFromPath(draft) == null and frames < 200) : (frames += 1) _ = try dvui.testing.step(headlessFrame);
        try dvui.testing.settle(headlessFrame);
        const doc = host.docFromPath(draft) orelse return error.TestUnexpectedResult;
        const write = try gpa.print(".{{ .path = \"{s}\", .text = \"# Draft, not saved\\n\" }}", .{draft});
        defer gpa.free(write);
        try std.testing.expect(host.callCommand("text.write", write, host.arena()) == .ok);
        try dvui.testing.settle(headlessFrame);
        try std.testing.expect(doc.owner.isDirty(doc));
        const line_before = doc.owner.historyLine(doc, host.arena()) orelse return error.TestUnexpectedResult;
        const steps_before = line_before.entries.len;
        const at_before = line_before.at;
        const grouping = doc.owner.documentGrouping(doc);
        const panes_before = wb.workspaces.count();
        const docs_open = app.editor.app.open_files.count();
        try std.testing.expectEqual(doc.id, app.editor.activeDoc().?.id);
        app.editor.flushSettings();
        const settings_path = try std.fs.path.join(gpa, &.{ app.editor.app.config_folder, "settings.zon" });
        defer gpa.free(settings_path);
        const settings_before = try std.Io.Dir.cwd().statFile(dvui.io, settings_path, .{});

        try app.editor.demo.playTape(glassy);
        try std.testing.expect(app.editor.demo.active());
        frames = 0;
        while (p.state != .ended and frames < 2_000) : (frames += 1) _ = try dvui.testing.step(headlessFrame);
        try std.testing.expectEqual(automation.Player.State.ended, p.state);
        // On the stage, only the demo's: its pane, its document in front, the draft nowhere.
        try std.testing.expectEqual(@as(usize, 1), wb.workspaces.count());
        try std.testing.expect(std.mem.startsWith(u8, activePath(app.editor), "demo://"));
        try std.testing.expect(!wb.workspaces.contains(grouping));
        p.seek(0);
        frames = 0;
        while (p.state == .seeking and frames < 400) : (frames += 1) _ = try dvui.testing.step(headlessFrame);
        p.seek(@floatFromInt(p.duration()));
        frames = 0;
        while (p.state == .seeking and frames < 400) : (frames += 1) _ = try dvui.testing.step(headlessFrame);
        p.unload();
        try dvui.testing.settle(headlessFrame);

        // The same document, never closed: unsaved, its text and history as they were, in its pane
        // and in front.
        const back = host.docFromPath(draft) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(doc.id, back.id);
        try std.testing.expect(back.owner.isDirty(back));
        const read_args = try gpa.print(".{{ .path = \"{s}\" }}", .{draft});
        defer gpa.free(read_args);
        const out = host.callCommand("text.read", read_args, host.arena()).ok orelse return error.TestUnexpectedResult;
        try std.testing.expect(std.mem.find(u8, out, "# Draft, not saved") != null);
        const line_after = back.owner.historyLine(back, host.arena()) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(steps_before, line_after.entries.len);
        try std.testing.expectEqual(at_before, line_after.at);
        try std.testing.expectEqual(grouping, back.owner.documentGrouping(back));
        try std.testing.expectEqual(panes_before, wb.workspaces.count());
        try std.testing.expectEqual(docs_open, app.editor.app.open_files.count());
        try std.testing.expectEqual(doc.id, app.editor.activeDoc().?.id);
        try std.testing.expect(wb.held_tabs.items.len == 0 and wb.held_workspaces.count() == 0);
        // Not written while the demo played, nor by its end.
        const settings_after = try std.Io.Dir.cwd().statFile(dvui.io, settings_path, .{});
        try std.testing.expectEqual(settings_before.mtime, settings_after.mtime);
        try std.testing.expectEqual(settings_before.size, settings_after.size);
        try app.editor.rawCloseFileID(back.id);
        try dvui.testing.settle(headlessFrame);
    }

    // A tape loaded some other way is not the one the service started.
    try app.editor.demo.play("markdown");
    try std.testing.expectEqual(@as(?[]const u8, null), api.current());

    p.unload();
    try dvui.testing.settle(headlessFrame);
    try std.testing.expectEqual(@as(?[]const u8, null), api.current());

    try std.testing.expectEqualStrings(site, app.editor.app.folder orelse "");
    try std.testing.expectEqual(docs_before, app.editor.app.open_files.count());
    try std.testing.expect(app.editor.app.host.files.?.isMounted(site));
    try std.testing.expectEqualStrings(active_before, activePath(app.editor));

    // Closing the player keeps the app as it is once the tape has ended or a person has stepped
    // in; only "Revert to before" gives the person's session back.
    {
        const wb = &app.editor.workbench;
        const draft = try gpa.print("{s}/keep.md", .{app.root_buf[0 .. std.mem.findScalar(u8, &app.root_buf, 0) orelse 0]});
        defer gpa.free(draft);
        try std.Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = draft, .data = "# Keep\n" });
        _ = try app.editor.openFilePath(draft, wb.currentGroupingID());
        frames = 0;
        while (host.docFromPath(draft) == null and frames < 200) : (frames += 1) _ = try dvui.testing.step(headlessFrame);
        try dvui.testing.settle(headlessFrame);
        const mine = host.docFromPath(draft) orelse return error.TestUnexpectedResult;

        // A tape that ended: stopping leaves its documents and its folder, and the person's own
        // document is back among the tabs of the pane it ended in.
        try app.editor.demo.playTape(glassy);
        frames = 0;
        while (p.state != .ended and frames < 2_000) : (frames += 1) _ = try dvui.testing.step(headlessFrame);
        const demo_active = activePath(app.editor);
        try std.testing.expect(std.mem.startsWith(u8, demo_active, "demo://"));
        const demo_folder = try gpa.dupe(u8, app.editor.app.folder orelse "");
        defer gpa.free(demo_folder);
        p.stop();
        try dvui.testing.settle(headlessFrame);
        try std.testing.expect(!app.editor.demo.active());
        try std.testing.expectEqualStrings(demo_active, activePath(app.editor));
        try std.testing.expectEqualStrings(demo_folder, app.editor.app.folder orelse "");
        try std.testing.expect(wb.held_tabs.items.len == 0 and wb.held_workspaces.count() == 0 and !wb.holding);
        const id = try sdk.document.surfaceId(host.arena(), mine.owner.id, mine.owner.documentPath(mine));
        var seated = false;
        for (wb.workspaces.values()) |*ws| seated = seated or ws.hasTab(id);
        try std.testing.expect(seated);

        // What the kept demo left in the layout is not written: no later launch could open it.
        app.editor.app.layout.dirty = true;
        app.editor.flushLayout();
        {
            const path = try std.fs.path.join(gpa, &.{ app.editor.app.config_folder, "layout.zon" });
            defer gpa.free(path);
            const written = try std.Io.Dir.cwd().readFileAlloc(dvui.io, path, gpa, .limited(1 << 20));
            defer gpa.free(written);
            try std.testing.expect(std.mem.find(u8, written, "demo://") == null);
        }

        // A person stepping in, then playing on: a new branch, not a replay over their work, and
        // the history before it still there to seek back into.
        try app.editor.demo.play(fizzy.Editor.Demo.catalog.entries[0].name);
        frames = 0;
        while ((p.state != .playing or p.seq.now < 3000) and frames < 2_000) : (frames += 1) _ = try dvui.testing.step(headlessFrame);
        try std.testing.expectEqual(automation.Player.State.playing, p.state);
        p.pause();
        p.diverged = true;
        const snaps = p.snapshots.items.len;
        p.play();
        try std.testing.expect(p.branched and !p.diverged);
        try std.testing.expectEqual(automation.Player.State.playing, p.state);
        frames = 0;
        while (p.state != .ended and frames < 2_000) : (frames += 1) _ = try dvui.testing.step(headlessFrame);
        try std.testing.expectEqual(snaps, p.snapshots.items.len);
        p.seek(0);
        frames = 0;
        while (p.state == .seeking and frames < 400) : (frames += 1) _ = try dvui.testing.step(headlessFrame);
        try std.testing.expect(!p.branched);

        // Reverting is the way back to the session set aside.
        p.revert();
        try dvui.testing.settle(headlessFrame);
        try std.testing.expect(!app.editor.demo.active());
        try std.testing.expect(host.docFromPath(draft) != null);
        try std.testing.expect(!std.mem.startsWith(u8, activePath(app.editor), "demo://"));
    }
}

/// What straight play of a demo must keep steady, watched a frame at a time:
///
/// - **The layout carries over from chapter to chapter.** A chapter starts in the window the last
///   one left; no cut puts it back to a fresh arrangement (`Demo.layoutPrint`).
/// - **Carrying something, the pointer goes straight to where it is going.** Its distance to where
///   the glide lands never grows: chasing a target that moves for what it carries (a tab strip
///   making room) sent it back and forth every other frame (`Sequencer.Glide.carried`).
/// - **A drop's lit bubble does not flicker.** Over one drag, a bubble once left is not lit again.
const Steady = struct {
    chapter: ?usize = null,
    print: u64 = 0,
    /// The carried glide in flight, by op, and the pointer at each of its frames.
    glide: ?usize = null,
    path: std.ArrayList(dvui.Point.Physical) = .empty,
    /// The bubbles lit over the drag in flight, each once, and those lit the frame before.
    lit: std.ArrayList(u64) = .empty,
    was_lit: std.ArrayList(u64) = .empty,
    dragging: bool = false,

    fn deinit(self: *Steady, gpa: std.mem.Allocator) void {
        self.path.deinit(gpa);
        self.lit.deinit(gpa);
        self.was_lit.deinit(gpa);
    }

    fn frame(self: *Steady, gpa: std.mem.Allocator, editor: *fizzy.Editor, name: []const u8) !void {
        const p = &editor.demo.player;
        if (p.state != .playing) return;
        const tape = p.tape().?;

        const print = fizzy.Editor.Demo.layoutPrint(editor);
        const chapter = tape.chapterAt(p.seq.now);
        if (self.chapter != null and chapter != self.chapter and print != self.print) {
            std.debug.print("demo '{s}': chapter '{s}' opens on another layout than '{s}' left\n", .{ name, tape.chapters[chapter.?].title, tape.chapters[self.chapter.?].title });
            return error.LayoutCut;
        }
        self.chapter = chapter;
        self.print = print;

        const g: ?usize = if (p.seq.glide) |g| (if (g.carried) g.op else null) else null;
        if (g != self.glide) try self.landed(name);
        self.glide = g;
        if (g != null) try self.path.append(gpa, dvui.currentWindow().mouse_pt);

        const d = &editor.app.layout.view_drag;
        if (!d.active()) {
            self.dragging = false;
            return;
        }
        if (!self.dragging) {
            self.lit.clearRetainingCapacity();
            self.was_lit.clearRetainingCapacity();
        }
        self.dragging = true;
        var now_lit: std.ArrayList(u64) = .empty;
        defer now_lit.deinit(gpa);
        for (d.pending[0..d.pending_count]) |q| {
            if (!q.look.target) continue;
            const zone = q.look.hovered orelse continue;
            var h = std.hash.Wyhash.init(@backingInt(q.key));
            h.update(std.mem.asBytes(&zone));
            try now_lit.append(gpa, h.final());
        }
        // Lit now, not lit the frame before, and lit at some time before that: it went out and
        // came back.
        for (now_lit.items) |lit| {
            const before = std.mem.findScalar(u64, self.was_lit.items, lit) != null;
            const ever = std.mem.findScalar(u64, self.lit.items, lit) != null;
            if (ever and !before) {
                std.debug.print("demo '{s}': a drop's bubble lit again at {d:.0} ms after another was\n", .{ name, p.seq.now });
                return error.DropFlickers;
            }
            if (!ever) try self.lit.append(gpa, lit);
        }
        self.was_lit.clearRetainingCapacity();
        try self.was_lit.appendSlice(gpa, now_lit.items);
    }

    /// The carried glide in flight has ended: its pointer never got further from where it landed.
    fn landed(self: *Steady, name: []const u8) !void {
        defer self.path.clearRetainingCapacity();
        const pts = self.path.items;
        if (pts.len < 2) return;
        const end = pts[pts.len - 1];
        var was = std.math.floatMax(f32);
        for (pts) |pt| {
            const dist = @sqrt((pt.x - end.x) * (pt.x - end.x) + (pt.y - end.y) * (pt.y - end.y));
            if (dist > was + 2) {
                std.debug.print("demo '{s}': a carried pointer turned back, {d:.0} px from where it landed after {d:.0}\n", .{ name, dist, was });
                return error.PointerTurnedBack;
            }
            was = @min(was, dist);
        }
    }
};

fn activePath(editor: *fizzy.Editor) []const u8 {
    const doc = editor.activeDoc() orelse return "";
    return doc.owner.documentPath(doc);
}

/// Open a zip of `files` from its bytes, as the web page opens one it fetched
/// (`FizzyWebOpenBytes`), and return the folder it mounted as, in `std.testing.allocator`.
fn openZipFromBytes(editor: *fizzy.Editor, name: []const u8, files: []const struct { []const u8, []const u8 }) ![]u8 {
    const gpa = std.testing.allocator;
    var mem = try fizzy.core.vfs.Mem.init(gpa);
    defer mem.deinit();
    for (files) |f| try mem.put(f[0], f[1]);
    const bytes = try fizzy.core.vfs.zip.pack(gpa, &mem);
    defer gpa.free(bytes);
    _ = try editor.openFileFromBytes(try editor.app.gpa.dupe(u8, name), bytes, 0);
    try dvui.testing.settle(headlessFrame);
    const folder = editor.app.folder orelse return error.NotMounted;
    try std.testing.expect(std.mem.startsWith(u8, folder, "zip://"));
    return gpa.dupe(u8, folder);
}

/// A demo that frosts the window a moment in (`fizzy.windowMaterial`), encoded.
fn materialDemo() ![]u8 {
    const gpa = std.testing.allocator;
    var s: automation.Script = .init(gpa, "glass", "Glass");
    errdefer s.deinit();
    try s.keyframe(.{ .root = "demo://glass", .files = &.{.{ .path = "notes.md", .text = "# Notes\n" }}, .open = &.{"notes.md"} });
    s.pause(400);
    try s.commandWith("fizzy.windowMaterial", .{ .kind = "frost" });
    s.pause(600);
    var owned = try s.finish();
    defer owned.deinit();
    return automation.binary.encode(gpa, owned.tape, .{});
}

/// A demo that drags its second tab onto the editor's right edge, opening a pane beside, encoded.
fn splitDemo() ![]u8 {
    const gpa = std.testing.allocator;
    var s: automation.Script = .init(gpa, "split", "Split");
    errdefer s.deinit();
    try s.keyframe(.{
        .root = "demo://split",
        .files = &.{ .{ .path = "a.md", .text = "# A\n" }, .{ .path = "b.md", .text = "# B\n" } },
        .open = &.{ "a.md", "b.md" },
    });
    try s.drag(.{ .tag = "workbench.tab:demo://split/b.md" }, .{ .tag = "region:Main", .dx = 132 }, .{});
    s.pause(600);
    var owned = try s.finish();
    defer owned.deinit();
    return automation.binary.encode(gpa, owned.tape, .{});
}

/// A tape a plugin might register, encoded: a demo opening on a keyframe of one file, in two
/// chapters, or (`demo` false) a live tape of the same pauses, which a demo list leaves out.
fn encodedDemo(name: []const u8, demo: bool) ![]u8 {
    const gpa = std.testing.allocator;
    var s: automation.Script = .init(gpa, name, name);
    errdefer s.deinit();
    s.check.live = !demo;
    if (demo) try s.keyframe(.{ .root = "demo://guide", .files = &.{.{ .path = "notes.md", .text = "# Notes\n" }}, .open = &.{"notes.md"} });
    try s.chapter("One");
    s.pause(600);
    try s.chapter("Two");
    s.pause(600);
    var owned = try s.finish();
    defer owned.deinit();
    return automation.binary.encode(gpa, owned.tape, .{});
}
