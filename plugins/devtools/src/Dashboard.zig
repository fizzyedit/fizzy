//! The dashboard: where each frame's time goes (`core.profile`), drawn wherever its surface is
//! placed (a bottom-panel tab by default). The profiler records while it is drawn.
//!
//! Three views of the same timings, averaged per frame over the last half second or 30 s:
//! - **By plugin** — each owner (fizzy, or a plugin's id) with the time spent in its own code
//!   (self time: its scopes less the scopes inside them), then its hooks, surfaces and sections
//!   costliest first. Where to look for the slow plugin, and its slow part.
//! - **Call tree** — the scopes as they nest: a fizzy phase, the surfaces drawn in it, the hooks
//!   they call, the sections a plugin marks inside a hook.
//! - **Plugins** — each plugin as the `plugins` service tells it: how it is in the app, its
//!   version, its loads and the last reload's cost, its own time per frame, what it registered.
//!
//! Above them, the frame: its interval, fizzy's work in it, the backend's submit after it (the
//! frame handed to the GPU, where the backend measures it — the web's does), and the pointer
//! moves that came in. The app draws a frame only when something asks for one, so while a
//! pointer drives it the frame rate follows the input; "Continuous" asks for every frame, so the
//! rate shows what drawing can do with the input taken out of it.
const std = @import("std");
const dvui = @import("dvui");
const sdk = @import("fizzy_sdk");
const core = @import("core");
const profile = core.profile;
const viz = core.viz;
const Plugins = sdk.services.plugins.Api;

var view: enum { by_plugin, tree, plugins } = .by_plugin;
/// What the table and the pie cover: the last half second, or the last 30 s (`profile.lookback`).
var span: enum { recent, long } = .recent;
/// The hitch the person clicked, held in the table and the pie until clicked again; by when it
/// happened, since newer hitches move it along the list.
var held_hitch: ?i128 = null;
/// The frame the person clicked in the graph, frames back from the newest: held in the table, the
/// pie and the numbers until clicked again. The profiler holds still while it is (`frozen`), so
/// "frames back" keeps naming the same frame.
var locked: ?usize = null;
/// The width the table's columns needed last frame (`Table.needed`): a strip gives it that and the
/// rest to the graph.
var table_needed: f32 = 0;
/// What the last frame's graph and chips picked, for the numbers above them (drawn first).
var picked_last: Picked = .{ .inspected = null, .held = null };
/// The place it is drawn in is too narrow for the table's full share bars (a phone).
var narrow = false;
/// How the place it is drawn in is shaped, which decides the arrangement (`draw`).
var shape: enum { strip, roomy, column } = .roomy;
/// Ask for every frame while it is drawn, instead of only the ones something wants.
var continuous = false;
/// Drawn since the last `frameBegin`; and whether the profiler is on for it.
var drawn = false;
var recording = false;

/// Once a frame, before anything draws: the profiler records while the dashboard was drawn last
/// frame, and stops the frame after it was not.
pub fn frameBegin() void {
    const p = profile.current() orelse return;
    if (!drawn and recording) {
        p.enabled = false;
        recording = false;
    }
    drawn = false;
}

pub fn draw(host: *sdk.Host) void {
    const p = profile.current() orelse return;
    drawn = true;
    if (!recording) {
        // Fresh numbers each time it comes back on screen.
        p.reset();
        locked = null;
        recording = true;
    }
    p.enabled = true;
    // Its own drawing is not what anyone came to see.
    const self_prof = profile.begin("devtools", "dashboard");
    defer self_prof.end();

    // The place's shape decides the layout: a bottom panel is wide and short, a sidebar narrow,
    // a float or a tall panel roomy. Each shows everything; only the arrangement changes.
    const place = dvui.parentGet().data().contentRect();
    narrow = place.w < 600;
    shape = if (narrow) .column else if (place.h < 480 and place.w >= 900) .strip else .roomy;
    // A place shorter than the layout needs scrolls down rather than squeezing it. Never sideways:
    // everything is as wide as the place, and the table scrolls sideways itself when its columns
    // need more. One tall enough gives the body its whole height, so the table stays bounded and
    // draws only the rows in view.
    // Its bar over the content, not beside it: a bar that came and went with the content's height
    // changed everything's width, and hovering the graph's edge flickered between the two.
    var scroll = dvui.scrollArea(@src(), .{ .horizontal = .none, .vertical_bar = .auto_overlay }, .{ .expand = .both, .background = false });
    defer scroll.deinit();
    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .all(8),
        .min_size_content = .{ .h = switch (shape) {
            .strip => 220,
            .roomy => 560,
            .column => 640,
        } },
    });
    defer body.deinit();
    const width = body.data().contentRect().w;

    if (continuous) dvui.refresh(null, @src(), null);
    // Pointer moves this frame, mouse or touch: where the frame rate comes from while one
    // drives it. Not in a run nobody sees — a demo catching up replays its own moves there, run
    // after run, inside the one frame shown.
    if (!core.FrameTarget.unseen()) {
        var moves: u32 = 0;
        for (dvui.events()) |*e| {
            if (e.evt == .mouse and e.evt.mouse.action == .motion) moves += 1;
        }
        p.countInput(moves);
    }
    const arena = dvui.currentWindow().arena();

    switch (shape) {
        // Wide and short: the graph across the left part with the room to spread out, under it a
        // small pie (the table's bars are its legend) with the numbers and the controls beside it,
        // and the table down the right.
        .strip => {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both, .min_size_content = .{ .h = 220 } });
            defer row.deinit();
            // The plugins list has columns enough to want more of the width than the scopes do.
            // The table at least its share, more where its columns need it; the graph, the pie and
            // the controls the rest, wrapping to fit rather than squeezing the table.
            const share: f32 = if (view == .plugins) width * 0.58 else width * 0.4;
            const table_w = @min(width - 320, @max(share, table_needed + 4));
            var shown: Shown = undefined;
            var pie_colors: PieColors = .{};
            {
                var left = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .max_size_content = .{ .w = @max(300, width - table_w - 10), .h = dvui.max_float_safe }, .margin = .{ .w = 10 } });
                defer left.deinit();
                const picked = drawGraphPicked(p, true);
                shown = whatToShow(p, arena, picked);
                // A fixed height, whatever its stats and chips hold, so the graph above it keeps its
                // height as they change.
                var under = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .min_size_content = .{ .h = 136 }, .max_size_content = .{ .w = dvui.max_float_safe, .h = 136 } });
                defer under.deinit();
                pie_colors = drawPie(arena, shown, .{ .labels = .none, .size = .{ .w = 128, .h = 128 }, .centre = true });
                var controls = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .margin = .{ .x = 10 } });
                defer controls.deinit();
                drawStats(p);
                drawControls(p);
                drawHitchChips();
            }
            // At least its share; more where the table's columns need it (`claim_width`).
            var right = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .min_size_content = .{ .w = table_w } });
            defer right.deinit();
            if (view == .plugins) return drawPlugins(host, arena, shown.entries);
            drawTable(arena, shown, pie_colors);
        },
        // Roomy: the numbers, the controls and the graph across the top, the pie beside the table
        // under them.
        .roomy => {
            drawStats(p);
            drawControls(p);
            drawExplanation();
            const picked = drawGraphPicked(p, false);
            drawHitchChips();
            const shown = whatToShow(p, arena, picked);
            var lower = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both, .min_size_content = .{ .h = 280 } });
            defer lower.deinit();
            if (view == .plugins) return drawPlugins(host, arena, shown.entries);
            const colors = drawPie(arena, shown, .{ .labels = if (width < 1100) .legend else .leaders, .size = .{ .w = @min(420, width * 0.38), .h = 260 } });
            drawTable(arena, shown, colors);
        },
        // Narrow: one column, the pie above the table at the full width.
        .column => {
            drawStats(p);
            drawControls(p);
            const picked = drawGraphPicked(p, false);
            drawHitchChips();
            const shown = whatToShow(p, arena, picked);
            var lower = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .min_size_content = .{ .h = 280 } });
            defer lower.deinit();
            if (view == .plugins) return drawPlugins(host, arena, shown.entries);
            const colors = drawPie(arena, shown, .{ .labels = .legend, .size = .{ .w = width, .h = 200 } });
            drawTable(arena, shown, colors);
        },
    }
}

/// The frame's numbers, or a picked frame's own while one is (the averages say nothing about
/// it): one text layout of runs, the numbers padded to a steady width, where a widget each (a
/// box, a label for the name, the number and the unit) was some 35 widgets a frame for seven
/// numbers.
fn drawStats(p: *profile.Profiler) void {
    const s = p.stats;
    // Room for two lines held, so a frame's numbers wrapping differently from the averages do not
    // move what is below them.
    const line_h = dvui.Font.theme(.mono).textHeight();
    var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false, .padding = .{ .y = 2, .h = 2 }, .min_size_content = .{ .h = if (shape == .strip) 0 else 2 * line_h } });
    defer tl.deinit();
    const run: Runs = .{ .tl = tl };
    if (picked_last.inspected) |ago| if (p.historyFrame(ago)) |f| {
        run.stat("frame", "{d}", .{-@as(i64, @intCast(ago))}, "");
        run.stat("work", "{d:>6.2}", .{ms(@floatFromInt(f.work_ns))}, "ms");
        if (s.submit_ns != null) run.stat("submit", "{d:>6.2}", .{ms(@floatFromInt(f.submit_ns))}, "ms");
        run.note(if (locked != null) "locked" else "under the pointer");
        return;
    };
    if (picked_last.held) |h| {
        run.stat("hitch", "{d:.0}", .{secondsAgo(h.at_ns)}, "s ago");
        run.stat("work", "{d:>6.2}", .{ms(@floatFromInt(h.work_ns))}, "ms");
        return;
    }
    run.stat("", "{d:>3.0}", .{s.fps}, "fps");
    run.stat("frame", "{d:>6.2}", .{ms(s.interval_ns)}, "ms");
    run.stat("work", "{d:>6.2}", .{ms(s.work_ns)}, "ms");
    if (s.submit_ns) |ns| run.stat("submit", "{d:>6.2}", .{ms(ns)}, "ms");
    run.stat("worst", "{d:>6.2}", .{ms(@floatFromInt(s.worst_work_ns))}, "ms");
    run.stat("input", "{d:>3.0}", .{s.inputs_per_s}, "/s");
    run.stat("", "{d:>3}", .{s.frames}, "frames");
}

/// `name number unit` runs in a text layout: the name and unit faint, all monospace.
const Runs = struct {
    tl: *dvui.TextLayoutWidget,

    fn stat(self: Runs, name: []const u8, comptime fmt: []const u8, args: anytype, unit: []const u8) void {
        const mono = dvui.Font.theme(.mono);
        const dim = dvui.themeGet().color(.control, .text).opacity(0.6);
        var buf: [32]u8 = undefined;
        if (name.len > 0) self.tl.addText(name, .{ .font = mono, .color_text = .{ .color = dim } });
        self.tl.addText(std.fmt.bufPrint(&buf, " " ++ fmt, args) catch "", .{ .font = mono });
        if (unit.len > 0) self.tl.addText(std.fmt.bufPrint(&buf, " {s}", .{unit}) catch "", .{ .font = mono, .color_text = .{ .color = dim } });
        self.tl.addText("   ", .{ .font = mono });
    }

    fn note(self: Runs, text: []const u8) void {
        self.tl.addText(text, .{ .font = dvui.Font.theme(.mono), .color_text = .{ .color = dvui.themeGet().color(.control, .text).opacity(0.6) } });
    }
};

/// The controls as three groups, each one segmented row: running (pause, every frame, reset),
/// the view, and the span.
fn drawControls(p: *profile.Profiler) void {
    var row = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .expand = .horizontal, .margin = .{ .y = 4, .h = 4 } });
    defer row.deinit();
    switch (segmented(@src(), &.{ if (p.paused) "Resume" else "Pause", "Every frame", "Reset" }, &.{ p.paused, continuous, false }) orelse 99) {
        0 => p.paused = !p.paused,
        1 => continuous = !continuous,
        2 => {
            p.reset();
            locked = null;
        },
        else => {},
    }
    const views = [_]@TypeOf(view){ .by_plugin, .tree, .plugins };
    if (segmented(@src(), &.{ "By plugin", "Call tree", "Plugins" }, &.{ view == .by_plugin, view == .tree, view == .plugins })) |i| view = views[i];
    if (segmented(@src(), &.{ "0.5 s", "30 s" }, &.{ span == .recent, span == .long })) |i| span = if (i == 0) .recent else .long;
}

/// Buttons joined into one rounded group, those `on` lit: a segmented control. The one clicked.
fn segmented(src: std.builtin.SourceLocation, labels: []const []const u8, on: []const bool) ?usize {
    var group = dvui.box(src, .{ .dir = .horizontal }, .{
        .background = true,
        .color_fill = .{ .color = dvui.themeGet().color(.control, .fill).opacity(0.5) },
        .corners = .all(7),
        .padding = .all(2),
        .margin = .{ .w = 6, .y = 2, .h = 2 },
        .gravity_y = 0.5,
    });
    defer group.deinit();
    var clicked: ?usize = null;
    for (labels, on, 0..) |label, lit, i| {
        if (dvui.button(@src(), label, .{}, .{
            .id_extra = i,
            .style = if (lit) .highlight else .control,
            .background = lit,
            .corners = .all(5),
            .margin = .{},
            .padding = .{ .x = 8, .w = 8, .y = 3, .h = 3 },
        })) clicked = i;
    }
    return clicked;
}

/// What the numbers are; the widest thing here, shown only where there is room for it.
fn drawExplanation() void {
    dvui.labelNoFmt(@src(), if (span == .recent)
        "per frame, over the last 0.5 s — self is a scope's time less the scopes inside it"
    else
        "per frame, over the last 30 s; max is the slowest frame in it", .{}, .{
        .color_text = .{ .color = dvui.themeGet().color(.control, .text).opacity(0.6) },
        .margin = .{ .h = 4 },
    });
}

/// The graph and what the person picked: a frame under the pointer, or a held hitch.
const Picked = struct { inspected: ?usize, held: ?Held };

fn drawGraphPicked(p: *profile.Profiler, fill: bool) Picked {
    // The graph: the last frames' work. Under the pointer it holds the profiler still and the
    // table shows the frame under it, alone, instead of the averages.
    const inspected = blk: {
        const timed = profile.section("graph");
        defer timed.end();
        break :blk drawGraph(p, dvui.Font.theme(.mono), dvui.themeGet().color(.control, .text).opacity(0.6), fill);
    };
    p.frozen = inspected != null;
    picked_last = .{ .inspected = inspected, .held = heldHitch() };
    return picked_last;
}

/// What the table and the pie show, in the shape they read (an entry's numbers as its
/// "average"): the frame under the pointer, a held hitch, the last 30 s, or the last half second.
const Shown = struct { entries: []profile.Entry, work: f64, caption: []const u8 };

fn whatToShow(p: *profile.Profiler, arena: std.mem.Allocator, picked: Picked) Shown {
    var shown: Shown = .{ .entries = p.slice(), .work = @max(p.stats.work_ns, 1), .caption = "per frame" };
    if (picked.inspected) |ago| {
        if (p.historyFrame(ago)) |f| {
            shown.entries = withFrame(arena, shown.entries, f.ns, f.calls);
            shown.work = @max(@as(f64, @floatFromInt(f.work_ns)), 1);
            shown.caption = std.fmt.allocPrint(arena, "frame -{d}", .{ago}) catch "";
        }
    } else if (picked.held) |h| {
        shown.entries = withFrame(arena, shown.entries, h.ns, h.calls);
        shown.work = @max(@as(f64, @floatFromInt(h.work_ns)), 1);
        shown.caption = std.fmt.allocPrint(arena, "hitch {d:.1} s ago", .{secondsAgo(h.at_ns)}) catch "";
    } else if (span == .long) {
        if (profile.lookback()) |lb| {
            if (arena.alloc(profile.Lookback.Cost, shown.entries.len)) |costs| {
                const covered = lb.costs(30_000, costs);
                const copy = arena.dupe(profile.Entry, shown.entries) catch shown.entries;
                for (copy, costs) |*e, c| {
                    e.avg_ns = c.avg_ns;
                    e.avg_self_ns = c.self_ns;
                    e.avg_calls = c.calls;
                    e.max_ns = c.max_ns;
                }
                shown.entries = copy;
                shown.work = @max(covered.work_ns, 1);
                shown.caption = std.fmt.allocPrint(arena, "per frame · {d:.0} s", .{@as(f64, @floatFromInt(covered.ns)) / std.time.ns_per_s}) catch "";
            } else |_| {}
        }
    }
    return shown;
}

/// Where the frame went: its costliest scopes as a pie, the same frame the table shows (the
/// averages, or the one picked). Its colours, for the table's bars, and the slice hovered.
fn drawPie(arena: std.mem.Allocator, shown: Shown, how: struct { labels: viz.Pie.Options.Labels, size: dvui.Size, centre: bool = false }) PieColors {
    const timed = profile.section("pie");
    defer timed.end();
    var pie: viz.Pie = .init(@src(), collectSlices(arena, shown.entries, shown.work), .{
        .unit = "ms",
        .caption = if (how.labels == .none) "" else shown.caption,
        .labels = how.labels,
    }, .{
        .min_size_content = how.size,
        .max_size_content = .{ .w = how.size.w, .h = how.size.h },
        // Centred across a row only: in a column, dvui packs a centred child in the middle of
        // what is left, and what follows it would overlap.
        .gravity_y = if (how.centre) 0.5 else null,
        .margin = .{ .w = 10 },
    });
    pie.deinit();
    return .{ .keys = pie.keys, .colors = pie.colors, .hovered = if (pie.hovered) |h| pie.keys[h] else null };
}

/// Every scope, in the view chosen: the table's bars in the pie's colours, a hovered slice's row lit.
fn drawTable(arena: std.mem.Allocator, shown: Shown, colors: PieColors) void {
    const timed = profile.section("table");
    defer timed.end();
    var rows: std.ArrayList(Row) = .empty;
    switch (view) {
        .by_plugin => collectByPlugin(arena, shown.entries, shown.work, &rows),
        .tree => collectTree(arena, shown.entries, &rows),
        .plugins => unreachable,
    }
    drawGrid(rows.items, shown.work, colors);
}

/// `entries` as one frame saw them (`ns`, `calls`, indexed as `entries`): its time as each one's
/// "average", its self time from its children's, its calls.
fn withFrame(arena: std.mem.Allocator, entries: []profile.Entry, ns: []const u32, calls: []const u16) []profile.Entry {
    const copy = arena.dupe(profile.Entry, entries) catch return entries;
    for (copy, 0..) |*e, i| {
        const t: u32 = if (i < ns.len) ns[i] else 0;
        e.avg_ns = @floatFromInt(t);
        e.avg_calls = if (i < calls.len) @floatFromInt(calls[i]) else 0;
        e.max_ns = t;
        e.avg_self_ns = e.avg_ns;
    }
    for (copy) |e| if (e.parent != std.math.maxInt(u16)) {
        copy[e.parent].avg_self_ns = @max(0, copy[e.parent].avg_self_ns - e.avg_ns);
    };
    return copy;
}

fn secondsAgo(at_ns: i128) f64 {
    return @as(f64, @floatFromInt(core.perf.nanoTimestamp() - at_ns)) / std.time.ns_per_s;
}

const Held = struct { at_ns: i128, work_ns: u64, ns: []const u32, calls: []const u16 };

/// The kept hitches as a row of chips, newest first, each saying when and how long; a click holds
/// one (and another click lets it go). The held one, while it is still kept.
fn heldHitch() ?Held {
    const at = held_hitch orelse return null;
    const lb = profile.lookback() orelse return null;
    var ago: usize = 0;
    while (lb.hitchAt(ago)) |h| : (ago += 1) {
        if (h.at_ns == at) return .{ .at_ns = h.at_ns, .work_ns = h.work_ns, .ns = h.ns, .calls = h.calls };
    }
    // Fell out of the list: let it go.
    held_hitch = null;
    return null;
}

/// The kept hitches as a row of chips, newest first, each saying when and how long; a click holds
/// one in the table and the pie (`heldHitch`), another click lets it go.
fn drawHitchChips() void {
    const timed = profile.section("hitches");
    defer timed.end();
    const lb = profile.lookback() orelse return;
    if (lb.hitch_filled == 0) return;
    // One row, as many as fit: a new hitch never wraps it onto a second and moves what is below.
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .h = 4 } });
    defer row.deinit();
    const prev_clip = dvui.clip(row.data().contentRectScale().r);
    defer dvui.clipSet(prev_clip);
    const dim = dvui.themeGet().color(.control, .text).opacity(0.6);
    var buf: [64]u8 = undefined;
    const title = std.fmt.bufPrint(&buf, "over {d:.1} ms:", .{@as(f64, @floatFromInt(lb.budget_ns)) / std.time.ns_per_ms}) catch "";
    dvui.labelNoFmt(@src(), title, .{}, .{ .color_text = .{ .color = dim }, .gravity_y = 0.5 });
    var ago: usize = 0;
    while (lb.hitchAt(ago)) |h| : (ago += 1) {
        const is_held = held_hitch != null and held_hitch.? == h.at_ns;
        const text = std.fmt.bufPrint(&buf, "{d:.0} s ago · {d:.1} ms", .{ secondsAgo(h.at_ns), @as(f64, @floatFromInt(h.work_ns)) / std.time.ns_per_ms }) catch "";
        if (dvui.button(@src(), text, .{}, .{ .id_extra = ago, .style = if (is_held) .highlight else .control, .margin = .all(2), .padding = .{ .x = 6, .w = 6, .y = 2, .h = 2 } })) {
            held_hitch = if (is_held) null else h.at_ns;
        }
    }
}

/// The last `profile.history_len` frames' work as columns, newest at the right, each with its
/// submit on top in a fainter colour, and the 120 and 60 fps lines. Returns how many frames back
/// the pointer is over (0 the newest), if it is.
fn drawGraph(p: *profile.Profiler, font: dvui.Font, dim: dvui.Color, fill: bool) ?usize {
    const arena = dvui.currentWindow().arena();
    const n = p.history_filled;
    const work = arena.alloc(f32, n) catch return null;
    const submit = arena.alloc(f32, n) catch return null;
    @memset(work, 0);
    @memset(submit, 0);
    for (0..n) |ago| {
        const f = p.historyFrame(ago) orelse break;
        work[n - 1 - ago] = @floatCast(ms(@floatFromInt(f.work_ns)));
        submit[n - 1 - ago] = @floatCast(ms(@floatFromInt(f.submit_ns)));
    }
    const highlight = dvui.themeGet().color(.highlight, .fill);
    var graph = viz.line(@src(), &.{
        .{ .name = "work", .values = work, .color = highlight.opacity(0.8) },
        .{ .name = "submit", .values = submit, .color = highlight.opacity(0.35) },
    }, .{
        .style = .columns,
        .stacked = true,
        .slots = profile.history_len,
        .floor = 1000.0 / 60.0 * 1.25,
        .marks = &.{ 1000.0 / 120.0, 1000.0 / 60.0 },
        .selected = locked,
    }, if (fill) .{ .expand = .both, .min_size_content = .{ .w = 200, .h = 70 }, .margin = .{ .h = 6 } } else .{ .margin = .{ .h = 6 } });
    defer graph.deinit();
    // A click locks the frame under it; clicking the locked one, or anywhere off the graph, lets
    // it go.
    if (graph.clicked) |c| {
        locked = if (locked != null and locked.? == c) null else c;
    } else if (locked != null) {
        const on_graph = graph.box.data().borderRectScale().r;
        for (dvui.events()) |*e| {
            if (e.evt != .mouse) continue;
            const me = e.evt.mouse;
            if (me.action == .press and me.button.pointer() and !on_graph.contains(me.p)) locked = null;
        }
    }
    const picked = locked orelse graph.hovered;
    var label_buf: [128]u8 = undefined;
    const text = if (picked) |h| blk: {
        const f = p.historyFrame(h).?;
        // Submit only where the backend measures it (`FrameStats.submit_ns`).
        break :blk if (p.stats.submit_ns != null)
            std.fmt.bufPrint(&label_buf, "frame -{d}: {d:.2} ms + submit {d:.2} ms · {s}", .{ h, ms(@floatFromInt(f.work_ns)), ms(@floatFromInt(f.submit_ns)), if (locked != null) "locked, click it to let go" else "click to lock it" }) catch ""
        else
            std.fmt.bufPrint(&label_buf, "frame -{d}: {d:.2} ms · {s}", .{ h, ms(@floatFromInt(f.work_ns)), if (locked != null) "locked, click it to let go" else "click to lock it" }) catch "";
    } else std.fmt.bufPrint(&label_buf, "last {d} frames · hover one to see it, click to lock it", .{n}) catch "";
    // Drawn over the graph, not laid out in it: a longer caption (a tall frame's numbers) must not
    // widen the graph and shift what is around it.
    {
        const rs = graph.box.data().contentRectScale();
        const prev_clip = dvui.clip(rs.r);
        defer dvui.clipSet(prev_clip);
        const size = font.textSize(text).scale(rs.s, dvui.Size.Physical);
        dvui.renderText(.{ .font = font, .text = text, .rs = .{ .r = .{ .x = rs.r.x + 6 * rs.s, .y = rs.r.y + 3 * rs.s, .w = size.w, .h = size.h }, .s = rs.s }, .color = dim }) catch {};
    }
    return picked;
}

fn ms(ns: f64) f64 {
    return ns / std.time.ns_per_ms;
}

/// One line of the table.
const Row = struct {
    name: []const u8,
    /// The scope's key, so its bar is the colour of its slice in the pie; none for an owner.
    key: ?u64 = null,
    indent: u8 = 0,
    strong: bool = false,
    self_ns: f64 = 0,
    total_ns: f64 = 0,
    calls: f64 = 0,
    max_ns: f64 = 0,
};

/// The pie's colours, for the table's bars to match, and the slice under the pointer, whose row
/// stays bright while the others fade.
const PieColors = struct {
    keys: []const u64 = &.{},
    colors: []const dvui.Color = &.{},
    hovered: ?u64 = null,

    fn of(self: PieColors, key: ?u64) ?dvui.Color {
        const k = key orelse return null;
        for (self.keys, self.colors) |pk, c| if (pk == k) return c;
        return null;
    }
};

fn drawGrid(rows: []const Row, work: f64, pie: PieColors) void {
    // In a strip the names need the width more than the calls do (a scope runs once a frame,
    // nearly always): the calls column goes.
    const with_calls = shape != .strip;
    const all = [_]viz.Table.Column{
        .{ .title = "", .kind = .text },
        .{ .title = "self ms" },
        .{ .title = "total ms" },
        .{ .title = "max ms" },
        .{ .title = "share of work", .kind = .bar, .bar_w = if (narrow or shape == .strip) 56 else 140 },
        .{ .title = "calls", .decimals = 1 },
    };
    const columns = if (with_calls) all[0..] else all[0..5];
    var table: viz.Table = .init(@src(), columns, .{ .rows = rows.len, .claim_width = shape != .column }, .{});
    defer table.deinit();
    table_needed = table.needed;
    for (rows[table.first..table.last], table.first..) |r, i| {
        table.text(i, 0, r.name, .{ .indent = r.indent, .strong = r.strong });
        table.number(i, 1, ms(r.self_ns));
        table.number(i, 2, ms(r.total_ns));
        table.number(i, 3, ms(r.max_ns));
        var bar_col = pie.of(r.key);
        if (pie.hovered) |h| if (r.key != h) {
            bar_col = (bar_col orelse dvui.themeGet().color(.highlight, .fill)).opacity(0.3);
        };
        table.bar(i, 4, viz.scale.fraction(r.self_ns, work), .{ .strong = r.strong, .color = bar_col });
        if (with_calls) table.number(i, 5, if (r.strong) null else r.calls);
    }
}

/// How many scopes the pie names; the rest of the frame's work is one slice, "the rest".
const pie_slices = 7;

/// The frame's costliest scopes by their own time, each named with its owner, and the rest of
/// the frame's work as one slice.
fn collectSlices(arena: std.mem.Allocator, entries: []profile.Entry, work: f64) []const viz.Pie.Slice {
    var slices: std.ArrayList(viz.Pie.Slice) = .empty;
    const faint = dvui.themeGet().color(.control, .text);
    // The frame's work no scope covers: fizzy's own code between its phases, and whatever is not
    // timed yet. Its own slice, so a big one says so instead of hiding in a catch-all.
    var roots: f64 = 0;
    for (entries) |e| if (e.parent == std.math.maxInt(u16)) {
        roots += e.avg_ns;
    };
    const untimed = work - roots;
    if (view == .by_plugin) {
        // Each owner's own time: every timed scope is in one slice, so the slices are the frame.
        var owners: std.ArrayList(viz.Pie.Slice) = .empty;
        for (entries) |e| {
            if (e.avg_self_ns <= 0) continue;
            const o = for (owners.items) |*o| {
                if (std.mem.eql(u8, o.label, e.owner)) break o;
            } else blk: {
                owners.append(arena, .{ .label = e.owner, .value = 0, .key = ownerKey(e.owner) }) catch break;
                break :blk &owners.items[owners.items.len - 1];
            };
            o.value += @floatCast(ms(e.avg_self_ns));
        }
        std.mem.sort(viz.Pie.Slice, owners.items, {}, struct {
            fn lt(_: void, a: viz.Pie.Slice, b: viz.Pie.Slice) bool {
                return a.value > b.value;
            }
        }.lt);
        slices.appendSlice(arena, owners.items) catch {};
    } else {
        // The costliest scopes by their own time, then the other scopes' together.
        var idx: std.ArrayList(usize) = .empty;
        for (entries, 0..) |e, i| if (e.avg_self_ns > 0) idx.append(arena, i) catch return &.{};
        std.mem.sort(usize, idx.items, entries, struct {
            fn lt(es: []profile.Entry, a: usize, b: usize) bool {
                return es[a].avg_self_ns > es[b].avg_self_ns;
            }
        }.lt);
        var named: f64 = 0;
        var all: f64 = 0;
        for (idx.items) |i| all += entries[i].avg_self_ns;
        for (idx.items[0..@min(idx.items.len, pie_slices)]) |i| {
            const e = entries[i];
            // Fizzy's own scopes by name; a plugin's with its id in front, unless the name says it.
            const short = shortName(e.name);
            const label = if (std.mem.eql(u8, e.owner, "fizzy") or std.mem.startsWith(u8, short, e.owner)) short else std.fmt.allocPrint(arena, "{s} · {s}", .{ e.owner, short }) catch short;
            slices.append(arena, .{ .label = label, .value = @floatCast(ms(e.avg_self_ns)), .key = e.key }) catch break;
            named += e.avg_self_ns;
        }
        if (ms(all - named) >= min_ms_shown) slices.append(arena, .{ .label = "other scopes", .value = @floatCast(ms(all - named)), .key = 1, .color = faint.opacity(0.45) }) catch {};
    }
    if (ms(untimed) >= min_ms_shown) slices.append(arena, .{ .label = "untimed", .value = @floatCast(ms(untimed)), .key = 0, .color = faint.opacity(0.25) }) catch {};
    return slices.items;
}

/// The key an owner's slice and its row share, so the row's bar takes the slice's colour.
fn ownerKey(owner: []const u8) u64 {
    return std.hash.Wyhash.hash(0x6f776e6572, owner);
}

/// Rows below this much total time (ms per frame) are left out: they are noise, and a table of
/// thousands of rows would cost more than what it measures.
const min_ms_shown: f64 = 0.005;

/// A scope's name as shown: a surface named for a file path (`pixi.doc:/Users/…/sheet.fiz`)
/// by its file name, which is the part that tells one from another.
fn shortName(name: []const u8) []const u8 {
    if (std.mem.indexOf(u8, name, ":/")) |colon| {
        const tail = name[colon + 1 ..];
        return if (std.mem.lastIndexOfScalar(u8, tail, '/')) |slash| tail[slash + 1 ..] else tail;
    }
    return name;
}

fn outermostForOwner(entries: []profile.Entry, e: profile.Entry) bool {
    return e.parent == std.math.maxInt(u16) or !std.mem.eql(u8, entries[e.parent].owner, e.owner);
}

fn collectByPlugin(arena: std.mem.Allocator, entries: []profile.Entry, work: f64, rows: *std.ArrayList(Row)) void {
    // Owners, by the self time of everything they own.
    const Owner = struct { name: []const u8, self_ns: f64 = 0, total_ns: f64 = 0 };
    var owners: std.ArrayList(Owner) = .empty;
    var roots_ns: f64 = 0;
    for (entries) |e| {
        const found = for (owners.items) |*o| {
            if (std.mem.eql(u8, o.name, e.owner)) break o;
        } else blk: {
            owners.append(arena, .{ .name = e.owner }) catch return;
            break :blk &owners.items[owners.items.len - 1];
        };
        found.self_ns += e.avg_self_ns;
        // Total: only the owner's outermost scopes, so nested ones are not counted twice.
        if (outermostForOwner(entries, e)) found.total_ns += e.avg_ns;
        if (e.parent == std.math.maxInt(u16)) roots_ns += e.avg_ns;
    }
    std.mem.sort(Owner, owners.items, {}, struct {
        fn lt(_: void, a: Owner, b: Owner) bool {
            return a.self_ns > b.self_ns;
        }
    }.lt);

    var idx: std.ArrayList(usize) = .empty;
    for (owners.items) |o| {
        if (ms(o.total_ns) < min_ms_shown) continue;
        rows.append(arena, .{ .name = o.name, .key = ownerKey(o.name), .strong = true, .self_ns = o.self_ns, .total_ns = o.total_ns }) catch return;
        idx.clearRetainingCapacity();
        for (entries, 0..) |e, i| if (std.mem.eql(u8, e.owner, o.name) and ms(e.avg_ns) >= min_ms_shown) idx.append(arena, i) catch return;
        std.mem.sort(usize, idx.items, entries, struct {
            fn lt(es: []profile.Entry, a: usize, b: usize) bool {
                return es[a].avg_self_ns > es[b].avg_self_ns;
            }
        }.lt);
        for (idx.items) |i| {
            const e = entries[i];
            rows.append(arena, .{
                // Indented under its plugin, a scope's own name is enough where the width is
                // short; elsewhere its path says where it sits.
                .name = if (shape != .roomy) shortName(e.name) else pathName(arena, entries, i),
                .key = e.key,
                .indent = 1,
                .self_ns = e.avg_self_ns,
                .total_ns = e.avg_ns,
                .calls = e.avg_calls,
                .max_ns = @floatFromInt(e.max_ns),
            }) catch return;
        }
    }
    // The frame's work no scope covers: fizzy's own code between its phases, and whatever of the
    // frame is not yet timed. Large means something worth a scope.
    const untimed = work - roots_ns;
    if (ms(untimed) >= min_ms_shown) rows.append(arena, .{ .name = "untimed (outside every scope)", .key = 0, .strong = true, .self_ns = untimed, .total_ns = untimed }) catch {};
}

/// `entries[i]`'s name with its parents' up to its owner's outermost scope: "sheet.fiz ›
/// bubbles › frost".
fn pathName(arena: std.mem.Allocator, entries: []profile.Entry, i: usize) []const u8 {
    var parts: [16][]const u8 = undefined;
    var n: usize = 0;
    var cur: u16 = @intCast(i);
    while (cur != std.math.maxInt(u16) and n < parts.len) {
        const e = entries[cur];
        parts[n] = shortName(e.name);
        n += 1;
        if (outermostForOwner(entries, e)) break;
        cur = e.parent;
    }
    var out: std.ArrayList(u8) = .empty;
    var k = n;
    while (k > 0) {
        k -= 1;
        out.appendSlice(arena, parts[k]) catch return shortName(entries[i].name);
        if (k > 0) out.appendSlice(arena, " › ") catch {};
    }
    return out.items;
}

fn collectTree(arena: std.mem.Allocator, entries: []profile.Entry, rows: *std.ArrayList(Row)) void {
    // Children of each entry (and the roots), costliest first.
    var kids = arena.alloc(std.ArrayList(usize), entries.len + 1) catch return;
    for (kids) |*k| k.* = .empty;
    for (entries, 0..) |e, i| {
        const slot = if (e.parent == std.math.maxInt(u16)) entries.len else e.parent;
        kids[slot].append(arena, i) catch return;
    }
    for (kids) |*k| std.mem.sort(usize, k.items, entries, struct {
        fn lt(es: []profile.Entry, a: usize, b: usize) bool {
            return es[a].avg_ns > es[b].avg_ns;
        }
    }.lt);
    const Walk = struct {
        fn go(es: []profile.Entry, ks: []std.ArrayList(usize), a: std.mem.Allocator, list: []const usize, out: *std.ArrayList(Row)) void {
            for (list) |i| {
                const e = es[i];
                if (ms(e.avg_ns) < min_ms_shown) continue;
                const name = if (outermostForOwner(es, e)) std.fmt.allocPrint(a, "{s} · {s}", .{ e.owner, shortName(e.name) }) catch e.name else shortName(e.name);
                out.append(a, .{
                    .name = name,
                    .key = e.key,
                    .indent = e.depth,
                    .strong = e.depth == 0,
                    .self_ns = e.avg_self_ns,
                    .total_ns = e.avg_ns,
                    .calls = e.avg_calls,
                    .max_ns = @floatFromInt(e.max_ns),
                }) catch return;
                go(es, ks, a, ks[i].items, out);
            }
        }
    };
    Walk.go(entries, kids, arena, kids[entries.len].items, rows);
}

/// The plugins as the `plugins` service tells them, with each one's own time per frame from the
/// profiler (its scopes' self time, summed): which plugin costs what, and what it brought.
fn drawPlugins(host: *sdk.Host, arena: std.mem.Allocator, entries: []const profile.Entry) void {
    const plugins = host.getServiceTyped(Plugins) orelse {
        dvui.labelNoFmt(@src(), "This app offers no plugins service.", .{}, .{});
        return;
    };
    const list = plugins.list(arena) catch return;
    var work: f64 = 0;
    for (entries) |e| work += e.avg_self_ns;
    const columns = [_]viz.Table.Column{
        .{ .title = "plugin", .kind = .text },
        .{ .title = "how", .kind = .text, .w = 76 },
        .{ .title = "version", .kind = .text, .w = 72 },
        .{ .title = "loads", .decimals = 0 },
        .{ .title = "reload ms", .decimals = 1 },
        .{ .title = "self ms" },
        .{ .title = "share of work", .kind = .bar, .bar_w = if (narrow) 48 else 120 },
        .{ .title = "surfaces", .decimals = 0 },
        .{ .title = "commands", .decimals = 0 },
        .{ .title = "services", .decimals = 0 },
    };
    var table: viz.Table = .init(@src(), &columns, .{ .rows = list.len, .claim_width = shape != .column }, .{});
    defer table.deinit();
    table_needed = table.needed;
    for (list[table.first..table.last], table.first..) |info, i| {
        var self_ns: f64 = 0;
        for (entries) |e| if (std.mem.eql(u8, e.owner, info.id)) {
            self_ns += e.avg_self_ns;
        };
        var version_buf: [32]u8 = undefined;
        const version = if (info.link == .bundled) "" else std.fmt.bufPrint(&version_buf, "{f}", .{info.version}) catch "";
        const failed = info.status.state == .failed;
        table.text(i, 0, info.name, .{ .strong = true });
        table.text(i, 1, if (failed) "failed" else @tagName(info.link), .{});
        table.text(i, 2, version, .{});
        // A bundled plugin is part of the app, never loaded on its own: no count to give.
        table.number(i, 3, if (info.link == .bundled) null else @as(f64, @floatFromInt(info.status.generation)));
        table.number(i, 4, if (info.status.opened_ms > 0) info.status.opened_ms + info.status.swapped_ms else null);
        table.number(i, 5, ms(self_ns));
        table.bar(i, 6, viz.scale.fraction(self_ns, @max(work, 1)), .{});
        table.number(i, 7, @floatFromInt(info.registered.surfaces));
        table.number(i, 8, @floatFromInt(info.registered.commands));
        table.number(i, 9, @floatFromInt(info.registered.services));
    }
}

/// The `plugins` service's list as ZON, for `devtools.stats`: each plugin's identity, how it is
/// in the app, its loads and what it registered.
pub fn writePlugins(host: *sdk.Host, arena: std.mem.Allocator, w: *std.Io.Writer) !void {
    const plugins = host.getServiceTyped(Plugins) orelse return w.writeAll(".{}");
    const list = try plugins.list(arena);
    try std.zon.stringify.serialize(list, .{ .whitespace = false }, w);
}
