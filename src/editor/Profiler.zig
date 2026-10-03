//! The profiler window: where each frame's time goes (`core.profile`). Opened from the palette
//! ("Toggle Profiler"); the profiler records only while it is open.
//!
//! Two views of the same timings, averaged per frame over the last half second:
//! - **By plugin** — each owner (fizzy, or a plugin's id) with the time spent in its own code
//!   (self time: its scopes less the scopes inside them), then its hooks, surfaces and sections
//!   costliest first. Where to look for the slow plugin, and its slow part.
//! - **Call tree** — the scopes as they nest: a fizzy phase, the surfaces drawn in it, the hooks
//!   they call, the sections a plugin marks inside a hook.
//!
//! Above them, the frame: its interval, fizzy's work in it, the backend's submit after it (the
//! frame handed to the GPU, where the backend measures it — the web's does), and the pointer
//! moves that came in. The app draws a frame only when something asks for one, so while a
//! pointer drives it the frame rate follows the input; "Continuous" asks for every frame, so the
//! rate shows what drawing can do with the input taken out of it.
const std = @import("std");
const dvui = @import("dvui");
const fizzy = @import("../fizzy.zig");
const core = fizzy.core;
const profile = core.profile;

pub var open: bool = false;
var rect: dvui.Rect = .{ .x = 80, .y = 80, .w = 720, .h = 560 };
var view: enum { by_plugin, tree } = .by_plugin;
/// The window is too narrow for the table's full share bars (a phone).
var narrow = false;
/// Touch: a finger on the graph holds the frame under it only while it is down. The pointer
/// stays where the finger lifted, and read as a hover it froze the profiler for good.
var touch_pointer = false;
var touch_down = false;
/// Ask for every frame while the window is open, instead of only the ones something wants.
var continuous = false;

/// The palette's "Toggle Profiler".
pub fn toggle() void {
    open = !open;
    const p = profile.host();
    p.enabled = open;
    if (open) p.reset();
}

pub fn draw() void {
    const p = profile.host();
    if (!open) {
        p.enabled = false;
        return;
    }
    p.enabled = true;
    // Its own drawing is not what anyone came to see.
    const self_prof = profile.begin("fizzy", "profiler window");
    defer self_prof.end();

    // On the screen whatever its size: a phone is narrower than the window's natural size,
    // and its left half was off the edge with nothing to drag it back by.
    const screen = dvui.windowRect();
    const margin: f32 = 8;
    const min_w = @min(520, @max(200, screen.w - 2 * margin));
    const min_h = @min(320, @max(160, screen.h - 2 * margin));
    rect.w = @min(rect.w, @max(min_w, screen.w - 2 * margin));
    rect.h = @min(rect.h, @max(min_h, screen.h - 2 * margin));
    rect.x = std.math.clamp(rect.x, margin, @max(margin, screen.w - rect.w - margin));
    rect.y = std.math.clamp(rect.y, margin, @max(margin, screen.h - rect.h - margin));
    narrow = rect.w < 600;

    // Frosted like every floating surface — and its blur shows up in its own numbers, under
    // "frost pane", with every other surface's.
    var win = core.widgets.floatingWindow(@src(), .{
        .open_flag = &open,
        .rect = &rect,
        .frost = core.dialogs.dialogFrost(),
    }, .{
        .min_size_content = .{ .w = min_w, .h = min_h },
        .color_fill = .{ .color = core.dialogs.dialogFill() },
        .corners = core.dialogs.surfaceCorners(),
        .box_shadow = core.dialogs.surfaceShadow(),
    });
    defer win.deinit();
    _ = core.dialogs.windowHeader("Profiler", "", &open, .none);

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .all(8) });
    defer body.deinit();

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

    const s = p.stats;
    const mono = dvui.Font.theme(.mono);
    const dim = dvui.themeGet().color(.control, .text).opacity(0.6);

    // The frame.
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        var submit_buf: [32]u8 = undefined;
        const submit = if (s.submit_ns) |ns| std.fmt.bufPrint(&submit_buf, "   submit {d:.2} ms", .{ms(ns)}) catch "" else "";
        dvui.label(@src(), "{d:.0} fps   frame {d:.2} ms   work {d:.2} ms{s}   worst {d:.2} ms   input {d:.0}/s   {d} frames", .{
            s.fps,
            ms(s.interval_ns),
            ms(s.work_ns),
            submit,
            ms(@floatFromInt(s.worst_work_ns)),
            s.inputs_per_s,
            s.frames,
        }, .{ .font = mono, .gravity_y = 0.5 });
    }
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 4, .h = 6 } });
        defer row.deinit();
        if (dvui.button(@src(), if (p.paused) "Resume" else "Pause", .{}, .{})) p.paused = !p.paused;
        if (dvui.button(@src(), if (continuous) "On input" else "Continuous", .{}, .{})) continuous = !continuous;
        if (dvui.button(@src(), "Reset", .{}, .{})) p.reset();
        if (dvui.button(@src(), if (view == .by_plugin) "Call tree" else "By plugin", .{}, .{})) {
            view = if (view == .by_plugin) .tree else .by_plugin;
        }
        // The explanation is the widest thing in the window; a phone has no room for it.
        if (!narrow) dvui.labelNoFmt(@src(), "per frame, over the last 0.5 s — self is a scope's time less the scopes inside it", .{}, .{
            .gravity_y = 0.5,
            .color_text = .{ .color = dim },
        });
    }
    const arena = dvui.currentWindow().arena();

    // The graph: the last frames' work. Under the pointer it holds the profiler still and the
    // table shows the frame under it, alone, instead of the averages.
    const inspected = drawGraph(p, mono, dim);
    p.frozen = inspected != null;

    var entries = p.slice();
    var work = @max(s.work_ns, 1);
    if (inspected) |ago| if (p.historyFrame(ago)) |f| {
        // That frame's numbers, in the shape the tables read: its time as the "average", its
        // self time from its children's, its calls.
        const copy = arena.dupe(profile.Entry, entries) catch entries;
        for (copy, 0..) |*e, i| {
            e.avg_ns = @floatFromInt(f.ns[i]);
            e.avg_calls = @floatFromInt(f.calls[i]);
            e.max_ns = f.ns[i];
            e.avg_self_ns = e.avg_ns;
        }
        for (copy) |e| if (e.parent != std.math.maxInt(u16)) {
            copy[e.parent].avg_self_ns = @max(0, copy[e.parent].avg_self_ns - e.avg_ns);
        };
        entries = copy;
        work = @max(@as(f64, @floatFromInt(f.work_ns)), 1);
    };
    var rows: std.ArrayList(Row) = .empty;
    switch (view) {
        .by_plugin => collectByPlugin(arena, entries, work, &rows),
        .tree => collectTree(arena, entries, &rows),
    }
    drawGrid(rows.items, work, mono, dim);
}

/// The last `profile.history_len` frames' work as bars, newest at the right, each with its
/// submit on top in a fainter colour, and the 120 and 60 fps lines. Returns how many frames back
/// the pointer is over (0 the newest), if it is.
fn drawGraph(p: *profile.Profiler, font: dvui.Font, dim: dvui.Color) ?usize {
    var box = dvui.box(@src(), .{}, .{ .expand = .horizontal, .min_size_content = .{ .w = 200, .h = 90 }, .margin = .{ .h = 6 } });
    defer box.deinit();
    const rs = box.data().contentRectScale();
    const r = rs.r;
    r.fill(.all(4 * rs.s), .{ .color = .{ .color = dvui.themeGet().color(.control, .fill).opacity(0.35) }, .fade = 0 });

    const n = p.history_filled;
    var top_ns: f64 = 1000.0 / 60.0 * std.time.ns_per_ms * 1.25;
    var ago: usize = 0;
    while (ago < n) : (ago += 1) {
        if (p.historyFrame(ago)) |f| top_ns = @max(top_ns, @as(f64, @floatFromInt(@as(u64, f.work_ns) + f.submit_ns)) * 1.1);
    }
    const bar_w = r.w / @as(f32, @floatFromInt(profile.history_len));
    const scale: f32 = @floatCast(r.h / top_ns);

    for (dvui.events()) |*e| {
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        switch (me.action) {
            .press => {
                touch_pointer = me.button.touch();
                if (touch_pointer) touch_down = true;
            },
            .release => if (me.button.touch()) {
                touch_down = false;
            },
            .motion => if (!me.button.touch() and !touch_down) {
                touch_pointer = false;
            },
            else => {},
        }
    }

    // Which frame the pointer is over.
    const mouse = dvui.currentWindow().mouse_pt;
    var hovered: ?usize = null;
    if ((!touch_pointer or touch_down) and r.contains(mouse) and dvui.clipGet().contains(mouse) and n > 0) {
        const from_right = (r.x + r.w - mouse.x) / bar_w;
        const h: usize = @intFromFloat(@max(0, @floor(from_right)));
        if (h < n) hovered = h;
    }

    // Every bar and both frame-rate lines as one batch of quads: one draw rather than 240 fills
    // (each its own path, triangulation and draw call), so the graph stays out of the numbers
    // it shows.
    const lifo = dvui.currentWindow().lifo();
    const quads = 2 * n + 2;
    if (dvui.Triangles.Builder.init(lifo, quads * 4, quads * 6)) |builder| {
        var b = builder;
        defer b.deinit(lifo);
        const bar_col = dvui.Color.PMA.fromColor(dvui.themeGet().color(.highlight, .fill).opacity(0.8));
        const submit_col = dvui.Color.PMA.fromColor(dvui.themeGet().color(.highlight, .fill).opacity(0.35));
        const hover_col = dvui.Color.PMA.fromColor(dvui.themeGet().color(.window, .text));
        const line_col = dvui.Color.PMA.fromColor(dim.opacity(0.5));
        ago = 0;
        while (ago < n) : (ago += 1) {
            const f = p.historyFrame(ago) orelse break;
            const hgt = @min(r.h, @as(f32, @floatFromInt(f.work_ns)) * scale);
            const submit_hgt = @min(r.h - hgt, @as(f32, @floatFromInt(f.submit_ns)) * scale);
            const x = r.x + r.w - @as(f32, @floatFromInt(ago + 1)) * bar_w;
            const w = @max(1, bar_w - rs.s);
            const is_hovered = hovered != null and hovered.? == ago;
            addQuad(&b, .{ .x = x, .y = r.y + r.h - hgt, .w = w, .h = hgt }, if (is_hovered) hover_col else bar_col);
            if (submit_hgt > 0) addQuad(&b, .{ .x = x, .y = r.y + r.h - hgt - submit_hgt, .w = w, .h = submit_hgt }, submit_col);
        }
        inline for (.{ 120.0, 60.0 }) |fps| {
            const y = r.y + r.h - @as(f32, @floatCast(1000.0 / fps * std.time.ns_per_ms)) * scale;
            if (y > r.y) addQuad(&b, .{ .x = r.x, .y = y, .w = r.w, .h = rs.s }, line_col);
        }
        if (b.indices.items.len > 0) dvui.renderTriangles(b.build_unowned(), null) catch {};
    } else |_| {}
    {
        var label_buf: [128]u8 = undefined;
        const text = if (hovered) |h| blk: {
            const f = p.historyFrame(h).?;
            // Submit only where the backend measures it (`FrameStats.submit_ns`).
            break :blk if (p.stats.submit_ns != null)
                std.fmt.bufPrint(&label_buf, "frame -{d}: {d:.2} ms + submit {d:.2} ms — the table shows this frame", .{ h, ms(@floatFromInt(f.work_ns)), ms(@floatFromInt(f.submit_ns)) }) catch ""
            else
                std.fmt.bufPrint(&label_buf, "frame -{d}: {d:.2} ms — the table shows this frame", .{ h, ms(@floatFromInt(f.work_ns)) }) catch "";
        } else std.fmt.bufPrint(&label_buf, "last {d} frames · hover one to hold it", .{n}) catch "";
        dvui.labelNoFmt(@src(), text, .{}, .{ .font = font, .color_text = .{ .color = dim }, .gravity_x = 0, .gravity_y = 0 });
    }
    return hovered;
}

fn addQuad(b: *dvui.Triangles.Builder, q: dvui.Rect.Physical, col: dvui.Color.PMA) void {
    const base: dvui.Vertex.Index = @intCast(b.vertexes.items.len);
    for ([4]dvui.Point.Physical{ q.topLeft(), q.topRight(), q.bottomRight(), q.bottomLeft() }) |pt| {
        b.appendVertex(.{ .pos = pt, .col = col, .uv = .{ 0, 0 } });
    }
    b.appendTriangles(&.{ base, base + 1, base + 2, base, base + 2, base + 3 });
}

fn ms(ns: f64) f64 {
    return ns / std.time.ns_per_ms;
}

/// One line of the table.
const Row = struct {
    name: []const u8,
    indent: u8 = 0,
    strong: bool = false,
    self_ns: f64 = 0,
    total_ns: f64 = 0,
    calls: f64 = 0,
    max_ns: f64 = 0,
};

const columns = [_][]const u8{ "", "self ms", "total ms", "calls", "max ms", "share of work" };

fn drawGrid(rows: []const Row, work: f64, font: dvui.Font, dim: dvui.Color) void {
    var grid = dvui.grid(@src(), .{ .rows = rows.len }, .{ .expand = .both, .background = false });
    defer grid.deinit();
    // Columns fit to what they hold, every frame: the numbers keep a steady width (fixed
    // decimals, monospace), and names come and go as scopes do. The name column takes the rest.
    grid.autoSize(.both);
    const body = dvui.Font.theme(.body);
    for (columns, 0..) |title, col| {
        // At least as wide as its title: the grid fits columns to their body cells only.
        const title_w = body.textSize(title).w + 16;
        grid.cellMinSize(col, std.math.maxInt(usize), .{ .w = title_w, .h = 0 });
        const c = grid.colHeader(.{ .col = col }, .{ .expand = if (col == 0) .horizontal else .none, .padding = .{ .x = 8, .w = 8, .y = 2, .h = 2 } });
        defer c.deinit();
        dvui.labelNoFmt(@src(), title, .{}, .{ .font = body, .color_text = .{ .color = dim }, .gravity_x = if (col == 0 or col == 5) 0 else 1, .padding = .{} });
    }
    const text = dvui.themeGet().color(.control, .text);
    // Only the rows in view are built: a scrolled-away row is widgets, labels and number
    // formatting every frame for nothing.
    const first, const last = grid.rowsVisible();
    const lo = @min(first, rows.len);
    const hi = @min(last, rows.len); // `last` is exclusive
    for (rows[lo..hi], lo..) |r, ri| {
        {
            const c = grid.cell(.{ .col = 0, .row = ri }, .{ .expand = .horizontal, .padding = .{ .x = 8 + @as(f32, @floatFromInt(r.indent)) * 16, .w = 8 } });
            defer c.deinit();
            var f = body;
            if (r.strong) f.weight = .bold;
            dvui.labelNoFmt(@src(), r.name, .{}, .{ .font = f, .color_text = .{ .color = text }, .padding = .{} });
        }
        const nums = [_]f64{ ms(r.self_ns), ms(r.total_ns), r.calls, ms(r.max_ns) };
        for (nums, 1..) |v, col| {
            const c = grid.cell(.{ .col = col, .row = ri }, .{ .padding = .{ .x = 8, .w = 8 } });
            defer c.deinit();
            var buf: [32]u8 = undefined;
            const t = if (col == 3 and r.strong)
                ""
            else if (col == 3)
                std.fmt.bufPrint(&buf, "{d:.1}", .{v}) catch "?"
            else
                std.fmt.bufPrint(&buf, "{d:.3}", .{v}) catch "?";
            dvui.labelNoFmt(@src(), t, .{}, .{ .font = font, .color_text = .{ .color = text }, .gravity_x = 1, .padding = .{} });
        }
        {
            const c = grid.cell(.{ .col = 5, .row = ri }, .{ .padding = .{ .x = 8, .w = 8 } });
            defer c.deinit();
            // From the left edge of the column, so bars compare by their length.
            var bb = dvui.box(@src(), .{}, .{ .expand = .horizontal, .min_size_content = .{ .w = if (narrow) 48 else 140, .h = 10 }, .gravity_y = 0.5 });
            defer bb.deinit();
            const rs = bb.data().contentRectScale();
            var bar = rs.r;
            bar.w *= @floatCast(std.math.clamp(r.self_ns / work, 0, 1));
            if (bar.w >= 1) bar.fill(.all(2 * rs.s), .{ .color = .{ .color = dvui.themeGet().color(.highlight, .fill).opacity(if (r.strong) 1 else 0.75) }, .fade = 0 });
        }
    }
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
        rows.append(arena, .{ .name = o.name, .strong = true, .self_ns = o.self_ns, .total_ns = o.total_ns }) catch return;
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
                .name = pathName(arena, entries, i),
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
    if (ms(untimed) >= min_ms_shown) rows.append(arena, .{ .name = "untimed (outside every scope)", .strong = true, .self_ns = untimed, .total_ns = untimed }) catch {};
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
