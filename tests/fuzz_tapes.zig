//! Seeded interruptions of the real headless demo player. Findings are observations, not gates.
const std = @import("std");
const dvui = @import("dvui");
const fizzy = @import("fizzy");
const automation = @import("app").automation;
const workbench = @import("workbench");

/// The observation a frame feeds while `Observation.frame` steps. The player runs the app's frame
/// several times inside one step while it seeks, so a press is checked after the run it landed in
/// (`headlessFrame`), not after the step.
var watching: ?struct { obs: *Observation, player: *automation.Player } = null;

fn headlessFrame() !dvui.App.Result {
    const w = watching orelse return fizzy.Entry.AppFrame();
    const before = w.player.seq.cursor;
    const res = try fizzy.Entry.AppFrame();
    if (!w.obs.corrupted and pointerNotAtTargetOnPress(w.player, before)) w.obs.verdict.insert(.pointer_target);
    return res;
}

const BundledApp = struct {
    t: dvui.testing,
    tmp: std.testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8,
    entry: *fizzy.Entry,
    editor: *fizzy.Editor,
    /// What `up` opened the window at; `reset` puts it back.
    size: dvui.Size.Natural,
    size_pixels: dvui.Size.Physical,
    /// A button the `real_press` action holds on the window, outside the player's own input.
    real_held: bool = false,

    // The app's own lifetime, whose exit leaks by design (`Editor.unloadPluginLibs`).
    const gpa = std.heap.smp_allocator;

    fn up(self: *BundledApp) !void {
        self.t = try dvui.testing.init(.{ .allocator = gpa, .window_size = .{ .w = 1280, .h = 800 } });
        self.size = self.t.backend.size;
        self.size_pixels = self.t.backend.size_pixels;
        self.real_held = false;
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

    /// A run starts from the window `up` left: its size, no button held, the pointer off any widget
    /// and nothing focused. Without it one run's `resize` or `real_press` shows up as a hole in the next.
    fn reset(self: *BundledApp) !void {
        const cw = dvui.currentWindow();
        if (self.real_held) _ = try cw.addEventMouseButton(.left, .release);
        self.real_held = false;
        self.t.backend.size = self.size;
        self.t.backend.size_pixels = self.size_pixels;
        _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = 0, .y = 0 } });
        dvui.focusWidget(null, null, null);
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

const Action = enum { frames, pause, play, seek, mid_drag, speed, real_motion, real_press, real_release, real_key, scripted_key, blur, resize, edit, close_target, missing_anchor };
const Step = struct { action: Action, value: u32 };
const Category = enum { held_button, final_state, caption_layer, pointer_target, seek_budget, timeout_then_ops, frame_limit };
const Verdict = std.EnumSet(Category);
const frame_limit = 2400;
const seek_limit = 400;
const action_count = 24;
const seeds = 4;
const shrink_probes = 60;

fn heldButton(p: *const automation.Player) bool {
    return (p.state == .paused or p.state == .ended or p.state == .idle) and p.input.held.count() > 0;
}

fn finalState(p: *const automation.Player, clean: u64) bool {
    return p.state == .ended and p.stage.fingerprint() != clean;
}

fn captionNotTopLayer() bool {
    const td = dvui.tagGet(automation.overlay.callout_anchor) orelse return false;
    var found = false;
    for (dvui.currentWindow().subwindows.stack.items) |sw| {
        if (sw.id == td.id) {
            found = true;
            continue;
        }
        // Transport and pointer layers may be above a caption; interactive app windows may not.
        if (found and sw.used and sw.mouse_events) return true;
    }
    return false;
}

fn pointerNotAtTargetOnPress(p: *const automation.Player, before: usize) bool {
    const tape = p.tape() orelse return false;
    if (p.seq.cursor <= before) return false;
    var target: ?automation.Tape.Target = null;
    for (tape.ops[0..@min(p.seq.cursor, tape.ops.len)], 0..) |op, i| {
        if (op.do.target()) |t| target = t;
        if (i < before or op.do != .press) continue;
        const t = target orelse return true;
        const point = automation.Input.targetPoint(p.stage, t) orelse return true;
        const press = p.last_press orelse return true;
        // A pixel tolerates rounding between natural and physical coordinates.
        if (@abs(point.x - press.pt.x) > 1 or @abs(point.y - press.pt.y) > 1) return true;
    }
    return false;
}

fn seekOverBudget(p: *const automation.Player, elapsed: i128) bool {
    // A frame also draws, and this is a debug build: allow a few budgets before calling a seek slow.
    return elapsed > p.budget_ns * 4;
}

fn timedOutWaitThenOpsRan(p: *const automation.Player, timed_out_cursor: ?usize) bool {
    return if (timed_out_cursor) |cursor| p.seq.cursor > cursor else false;
}

const Observation = struct {
    verdict: Verdict = .empty,
    timeout_cursor: ?usize = null,
    seek_frames: usize = 0,
    over_budget: usize = 0,
    worst_ns: i128 = 0,
    /// A missing anchor makes the tape diverge on purpose; the end-state and pointer checks
    /// say nothing about a tape that was told to point at nothing.
    corrupted: bool = false,

    fn frame(self: *Observation, p: *automation.Player) !void {
        const timeouts = p.timeouts;
        const seeking = p.state == .seeking;
        const start = std.Io.Clock.awake.now(dvui.io).nanoseconds;
        watching = .{ .obs = self, .player = p };
        defer watching = null;
        _ = try dvui.testing.step(headlessFrame);
        const elapsed = std.Io.Clock.awake.now(dvui.io).nanoseconds - start;
        if (heldButton(p)) self.verdict.insert(.held_button);
        if (captionNotTopLayer()) self.verdict.insert(.caption_layer);
        if (p.timeouts > timeouts) self.timeout_cursor = p.seq.cursor;
        if (timedOutWaitThenOpsRan(p, self.timeout_cursor)) self.verdict.insert(.timeout_then_ops);
        if (seeking) {
            self.seek_frames += 1;
            self.worst_ns = @max(self.worst_ns, elapsed);
            if (seekOverBudget(p, elapsed)) {
                self.over_budget += 1;
                self.verdict.insert(.seek_budget);
            }
        }
    }
};

fn load(app: *BundledApp, name: []const u8) !void {
    app.editor.demo.player.unload();
    try dvui.testing.settle(headlessFrame);
    try app.reset();
    if (std.mem.eql(u8, name, "hello")) {
        try app.editor.demo.playTape(@embedFile("hello"));
    } else try app.editor.demo.play(name);
}

fn seekTo(p: *automation.Player, at: f64, obs: *Observation) !void {
    p.seek(at);
    for (0..seek_limit) |_| {
        if (p.state != .seeking) return;
        try obs.frame(p);
    }
    obs.verdict.insert(.frame_limit);
}

fn apply(app: *BundledApp, step: Step, obs: *Observation) !void {
    const p = &app.editor.demo.player;
    const cw = dvui.currentWindow();
    switch (step.action) {
        .frames => for (0..1 + step.value % 32) |_| try obs.frame(p),
        .pause => p.pause(),
        .play => p.play(),
        .seek => try seekTo(p, @as(f64, @floatFromInt(p.duration())) *
            @as(f64, @floatFromInt(step.value % 1001)) / 1000, obs),
        .mid_drag => {
            var held = false;
            for (p.tape().?.ops) |op| {
                if (op.do == .press) held = true;
                if (op.do == .release) held = false;
                if (held and op.ms > 0 and op.do.target() != null) {
                    try seekTo(p, @as(f64, @floatFromInt(op.at)) + @as(f64, @floatFromInt(op.ms)) / 2, obs);
                    break;
                }
            }
        },
        .speed => p.seq.setSpeed(automation.Sequencer.speeds[step.value % automation.Sequencer.speeds.len]),
        .real_motion => {
            _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = @floatFromInt(step.value % 900), .y = 200 } });
        },
        .real_press => {
            app.real_held = true;
            _ = try cw.addEventMouseButton(.left, .press);
        },
        .real_release => {
            app.real_held = false;
            _ = try cw.addEventMouseButton(.left, .release);
        },
        .real_key => try dvui.testing.pressKey(.a, .none),
        .scripted_key => automation.Input.key("a"),
        // The headless backend has no OS focus callback; leave is its available blur event.
        .blur => try cw.addEventWindow(.{ .action = .leave }),
        .resize => {
            const w: f32 = @floatFromInt(640 + step.value % 640);
            app.t.backend.size = .{ .w = w, .h = 700 };
            app.t.backend.size_pixels = .{ .w = w * 2, .h = 1400 };
        },
        .edit => {
            p.pause();
            if (app.editor.activeDoc()) |doc| {
                const host = &app.editor.app.host;
                const path = doc.owner.documentPath(doc);
                const args = try std.fmt.allocPrint(std.testing.allocator, ".{{ .path = \"{s}\", .text = \"# Fuzzer edit\\n\" }}", .{path});
                defer std.testing.allocator.free(args);
                _ = host.callCommand("text.write", args, host.arena());
            }
        },
        .close_target => {
            if (app.editor.app.frame_layout) |layout| layout.closeFloat("Float 1");
        },
        .missing_anchor => {
            // Owned tape ops are mutable; corrupt future targets without changing production code.
            obs.corrupted = true;
            const owned = &p.owned.?;
            for (@constCast(owned.tape.ops)[@min(p.seq.cursor, owned.tape.ops.len)..]) |*op| {
                switch (op.do) {
                    .move => |*target| target.tag = "fuzz.missing",
                    .trace => |*target| target.tag = "fuzz.missing",
                    .wait => |*wait| {
                        wait.until = .{ .shown = "fuzz.missing" };
                        wait.timeout = 100;
                    },
                    else => {},
                }
            }
        },
    }
    try obs.frame(p);
}

fn run(app: *BundledApp, name: []const u8, steps: []const Step, clean: ?u64) !Observation {
    try load(app, name);
    const p = &app.editor.demo.player;
    var obs: Observation = .{};
    for (steps) |step| try apply(app, step, &obs);
    p.play();
    for (0..frame_limit) |_| {
        if (p.state == .ended) break;
        try obs.frame(p);
    }
    if (p.state != .ended) obs.verdict.insert(.frame_limit);
    if (clean) |fingerprint| if (!obs.corrupted and finalState(p, fingerprint)) {
        obs.verdict.insert(.final_state);
    };
    return obs;
}

/// Delete chunks of steps (halving the chunk) while the category still fails. Capped, because
/// each probe replays a whole tape.
fn shrink(app: *BundledApp, name: []const u8, steps: *std.ArrayList(Step), category: Category, clean: u64) !void {
    var budget: usize = shrink_probes;
    var chunk = (steps.items.len + 1) / 2;
    while (chunk >= 1) : (chunk /= 2) {
        var i: usize = 0;
        while (i + chunk <= steps.items.len) {
            if (budget == 0) return;
            budget -= 1;
            var trial: std.ArrayList(Step) = .empty;
            defer trial.deinit(std.testing.allocator);
            try trial.appendSlice(std.testing.allocator, steps.items[0..i]);
            try trial.appendSlice(std.testing.allocator, steps.items[i + chunk ..]);
            const obs = try run(app, name, trial.items, clean);
            if (obs.verdict.contains(category)) {
                steps.shrinkRetainingCapacity(0);
                try steps.appendSlice(std.testing.allocator, trial.items);
            } else i += chunk;
        }
    }
}

test "exploratory tape interruptions report and shrink every failing seed" {
    var app: BundledApp = undefined;
    try app.up();
    defer app.down();
    var counts = std.mem.zeroes([std.enums.values(Category).len]usize);
    std.debug.print("\n# Tape fuzzer\n\nRobustness report for fizzyedit/work#72 (exploratory, not a CI gate).\n\n", .{});
    for ([_][]const u8{ "tour", "markdown", "hello" }) |name| {
        const baseline = try run(&app, name, &.{}, null);
        const clean = app.editor.demo.player.stage.fingerprint() orelse return error.NoFingerprint;
        std.debug.print("Baseline {s}: {t}, timeouts={d}, observations={any}\n\n", .{ name, app.editor.demo.player.state, app.editor.demo.player.timeouts, baseline.verdict });
        for (0..seeds) |seed| {
            var prng: std.Random.DefaultPrng = .init(seed);
            const random = prng.random();
            var steps: std.ArrayList(Step) = .empty;
            defer steps.deinit(std.testing.allocator);
            for (0..action_count) |_| try steps.append(std.testing.allocator, .{
                .action = random.enumValue(Action),
                .value = random.int(u32),
            });
            const result = try run(&app, name, steps.items, clean);
            std.debug.print("## {s}, seed {d}\n\nSeek frames {d}, over budget {d}, worst {d:.2} ms.\n\n", .{ name, seed, result.seek_frames, result.over_budget, @as(f64, @floatFromInt(result.worst_ns)) / std.time.ns_per_ms });
            var categories = result.verdict.iterator();
            while (categories.next()) |category| {
                counts[@backingInt(category)] += 1;
                var repro: std.ArrayList(Step) = .empty;
                defer repro.deinit(std.testing.allocator);
                try repro.appendSlice(std.testing.allocator, steps.items);
                try shrink(&app, name, &repro, category, clean);
                const verified = try run(&app, name, repro.items, clean);
                if (repro.items.len == 0) std.debug.print("Fails with no interruption at all: state leaking between runs, or the tape itself.\n\n", .{});
                std.debug.print("Invariant `{t}`; shrunk {d} -> {d}; replay {s}.\n\n```zon\n.{{\n", .{ category, steps.items.len, repro.items.len, if (verified.verdict.contains(category)) "reproduced" else "UNSTABLE" });
                for (repro.items) |s| std.debug.print("    .{{ .action = .{t}, .value = {d} }},\n", .{ s.action, s.value });
                std.debug.print("}}\n```\n\n", .{});
            }
        }
    }
    std.debug.print("## Counts (failing seeds per category)\n\n", .{});
    for (std.enums.values(Category)) |c| std.debug.print("- {t}: {d}\n", .{ c, counts[@backingInt(c)] });
    try checkFixtures(&app);
}

/// The worst shrunk sequences, kept as expected failures: each is a hole today. When a fix lands
/// the matching test stops reproducing, fails, and the fixture is deleted with the fix.
const Fixture = struct { tape: []const u8, category: Category, steps: []const Step };
const fixtures = [_]Fixture{
    .{ .tape = "tour", .category = .held_button, .steps = &.{
        .{ .action = .pause, .value = 3709114103 },
        .{ .action = .mid_drag, .value = 3417069504 },
    } },
    .{ .tape = "tour", .category = .pointer_target, .steps = &.{
        .{ .action = .edit, .value = 1179371865 },
        .{ .action = .mid_drag, .value = 3225570326 },
        .{ .action = .scripted_key, .value = 816815299 },
        .{ .action = .mid_drag, .value = 3417069504 },
    } },
    .{ .tape = "markdown", .category = .timeout_then_ops, .steps = &.{
        .{ .action = .missing_anchor, .value = 1044382321 },
    } },
};

/// Runs in the same test as the exploration: the app's globals do not survive a second `up`.
fn checkFixtures(app: *BundledApp) !void {
    std.debug.print("\n## Expected-fail fixtures\n\n", .{});
    for (fixtures) |f| {
        _ = try run(app, f.tape, &.{}, null);
        const clean = app.editor.demo.player.stage.fingerprint() orelse return error.NoFingerprint;
        const obs = try run(app, f.tape, f.steps, clean);
        const holds = obs.verdict.contains(f.category);
        std.debug.print("- {s}/{t}: {s}\n", .{ f.tape, f.category, if (holds) "still fails (expected)" else "FIXED, delete the fixture" });
        try std.testing.expect(holds);
    }
}
