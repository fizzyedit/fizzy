//! Fizzy's graphics for live numbers (plans/DASHBOARD_PLAN.md, "The graphics library"):
//! immediate-mode dvui functions over slices the caller owns, drawn in fizzy's theme, for the
//! profiler, a plugin showing what it costs, and an agent's charts alike.
//!
//! - `line`: series over time, as lines or columns (stacked or side by side), newest at the
//!   right, with reference marks and the slot under the pointer.
//! - `bar`: a share of a whole, as a bar from the left (a table's "share of work").
//! - `stat`: a number with its label and unit.
//! - `Table`: columns of names, fixed-decimal numbers and bars, only the rows in view built.
//! - `Pie`: shares of a whole as a donut, with leaders out to their labels, easing as they change.
//!
//! None allocates beyond the frame's arena, and none keeps state but what dvui keeps for its
//! widgets. The arithmetic is in `scale` (tested without a window).
const std = @import("std");
const dvui = @import("dvui");
pub const palette = @import("../palette.zig");

pub const scale = @import("scale.zig");
pub const Table = @import("Table.zig");
pub const Pie = @import("Pie.zig");

/// One series of a `line`.
pub const Series = struct {
    name: []const u8 = "",
    /// Oldest first; the last is drawn at the right edge.
    values: []const f32,
    /// The theme's highlight for the first series, fizzy's palette after it, when null.
    color: ?dvui.Color = null,
};

pub const LineOptions = struct {
    style: Style = .line,
    /// Columns only: each series sits on the one before it (a frame's work, its submit on
    /// top). Otherwise the series share each slot side by side.
    stacked: bool = false,
    /// How many slots the width holds. The longest series' length when null; a fixed count
    /// keeps the slots still while a history fills.
    slots: ?usize = null,
    /// The scale's top is never below this, so small values stay small (a frame graph's floor
    /// is a little over one 60 Hz frame).
    floor: f32 = 0,
    /// Room above the largest value, as a factor.
    headroom: f32 = 1.1,
    /// Horizontal reference lines at these values: a frame budget, a target.
    marks: []const f32 = &.{},
    /// Report the slot under the pointer, and show it. On touch, only while the finger is down:
    /// the pointer stays where a finger lifted.
    hover: bool = true,

    pub const Style = enum { line, columns };
};

/// A `line` in progress: draw a caption or anything else inside it, then `deinit`.
pub const Line = struct {
    box: *dvui.BoxWidget,
    /// Slots back from the newest that the pointer is over (0 the newest), while it is.
    hovered: ?usize,

    pub fn deinit(self: *Line) void {
        self.box.deinit();
    }
};

/// The colour a series is drawn in when it names none.
pub fn seriesColor(i: usize) dvui.Color {
    if (i == 0) return dvui.themeGet().color(.highlight, .fill);
    return palette.colors[(i - 1) % palette.colors.len];
}

/// The colour for a thing known by `key` (a hash of its name, a profiler scope's key): the same
/// thing is the same colour in every graphic that shows it, a pie's slice and a table's bar.
pub fn keyColor(key: u64) dvui.Color {
    return palette.colors[@intCast(key % palette.colors.len)];
}

/// `series` over time in a box of their own. The caller `deinit`s what it returns.
pub fn line(src: std.builtin.SourceLocation, series: []const Series, opts: LineOptions, wopts: dvui.Options) Line {
    const defaults: dvui.Options = .{ .name = "viz.line", .expand = .horizontal, .min_size_content = .{ .w = 200, .h = 90 } };
    const box = dvui.box(src, .{}, defaults.override(wopts));
    const rs = box.data().contentRectScale();
    const r = rs.r;
    r.fill(.all(4 * rs.s), .{ .color = .{ .color = dvui.themeGet().color(.control, .fill).opacity(0.35) }, .fade = 0 });

    var filled: usize = 0;
    for (series) |s| filled = @max(filled, s.values.len);
    const slots = @max(opts.slots orelse filled, 1);
    filled = @min(filled, slots);

    // The scale: the tallest slot, stacked or not.
    var largest: f32 = 0;
    var ago: usize = 0;
    while (ago < filled) : (ago += 1) {
        var sum: f32 = 0;
        for (series) |s| {
            const v = valueAgo(s, ago);
            if (opts.stacked and opts.style == .columns) sum += v else largest = @max(largest, v);
        }
        largest = @max(largest, sum);
    }
    const top = scale.top(largest, opts.floor, opts.headroom);
    const per_value: f32 = r.h / top;
    const slot_w = r.w / @as(f32, @floatFromInt(slots));

    const hovered = if (opts.hover) hoveredSlot(box.data().id, r, slot_w, filled) else null;

    const text = dvui.themeGet().color(.window, .text);
    const lifo = dvui.currentWindow().lifo();
    const columns = opts.style == .columns;
    // Every column, mark and the hover marker as one batch of quads: one draw rather than one
    // fill (its own path, triangulation and draw call) each, so the chart stays out of the
    // numbers it shows.
    const quads = (if (columns) series.len * filled else 0) + opts.marks.len + 1;
    if (dvui.Triangles.Builder.init(lifo, quads * 4, quads * 6)) |builder| {
        var b = builder;
        defer b.deinit(lifo);
        if (columns) {
            const n_side: f32 = if (opts.stacked) 1 else @floatFromInt(@max(series.len, 1));
            ago = 0;
            while (ago < filled) : (ago += 1) {
                const x0 = r.x + r.w - @as(f32, @floatFromInt(ago + 1)) * slot_w;
                const w = @max(1, slot_w / n_side - rs.s);
                var base: f32 = 0;
                for (series, 0..) |s, i| {
                    const v = valueAgo(s, ago);
                    const h = @min(r.h - base, v * per_value);
                    if (h <= 0) continue;
                    const x = if (opts.stacked) x0 else x0 + @as(f32, @floatFromInt(i)) * slot_w / n_side;
                    var c = s.color orelse seriesColor(i).opacity(0.8);
                    // The slot under the pointer in the text colour: the bottom series solid, the
                    // ones on it as faint as they were, so a stack still reads as one.
                    if (hovered != null and hovered.? == ago) c = text.opacity(if (i == 0) 1 else @as(f32, @floatFromInt(c.a)) / 255);
                    addQuad(&b, .{ .x = x, .y = r.y + r.h - base - h, .w = w, .h = h }, .fromColor(c));
                    if (opts.stacked) base += h;
                }
            }
        } else if (hovered) |h| {
            const x = r.x + r.w - (@as(f32, @floatFromInt(h)) + 0.5) * slot_w;
            addQuad(&b, .{ .x = x - rs.s / 2, .y = r.y, .w = rs.s, .h = r.h }, .fromColor(text.opacity(0.4)));
        }
        const mark_col: dvui.Color.PMA = .fromColor(dvui.themeGet().color(.control, .text).opacity(0.3));
        for (opts.marks) |m| {
            const y = r.y + r.h - m * per_value;
            if (y > r.y) addQuad(&b, .{ .x = r.x, .y = y, .w = r.w, .h = rs.s }, mark_col);
        }
        if (b.indices.items.len > 0) dvui.renderTriangles(b.build_unowned(), null) catch {};
    } else |_| {}

    if (!columns) for (series, 0..) |s, i| {
        const n = @min(s.values.len, filled);
        if (n < 2) continue;
        var path: dvui.Path.Builder = .init(dvui.currentWindow().arena());
        defer path.deinit();
        var a = n;
        while (a > 0) {
            a -= 1;
            const x = r.x + r.w - (@as(f32, @floatFromInt(a)) + 0.5) * slot_w;
            const y = r.y + r.h - @min(r.h, valueAgo(s, a) * per_value);
            path.addPoint(.{ .x = x, .y = y });
        }
        path.build().stroke(.{ .thickness = 1.5 * rs.s, .color = .{ .color = s.color orelse seriesColor(i) }, .join = .strip });
    };

    return .{ .box = box, .hovered = hovered };
}

fn valueAgo(s: Series, ago: usize) f32 {
    if (ago >= s.values.len) return 0;
    return @max(0, s.values[s.values.len - 1 - ago]);
}

/// The slot under the pointer. A touch holds a slot only while the finger is down: the pointer
/// stays where it lifted, and read as a hover it would hold the chart for good.
fn hoveredSlot(id: dvui.Id, r: dvui.Rect.Physical, slot_w: f32, filled: usize) ?usize {
    var touch_pointer = dvui.dataGet(null, id, "touch_pointer", bool) orelse false;
    var touch_down = dvui.dataGet(null, id, "touch_down", bool) orelse false;
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
    dvui.dataSet(null, id, "touch_pointer", touch_pointer);
    dvui.dataSet(null, id, "touch_down", touch_down);

    const mouse = dvui.currentWindow().mouse_pt;
    if (touch_pointer and !touch_down) return null;
    if (!r.contains(mouse) or !dvui.clipGet().contains(mouse)) return null;
    return scale.slotFromRight(r.x + r.w - mouse.x, slot_w, filled);
}

fn addQuad(b: *dvui.Triangles.Builder, q: dvui.Rect.Physical, col: dvui.Color.PMA) void {
    const base: dvui.Vertex.Index = @intCast(b.vertexes.items.len);
    for ([4]dvui.Point.Physical{ q.topLeft(), q.topRight(), q.bottomRight(), q.bottomLeft() }) |pt| {
        b.appendVertex(.{ .pos = pt, .col = col, .uv = .{ 0, 0 } });
    }
    b.appendTriangles(&.{ base, base + 1, base + 2, base, base + 2, base + 3 });
}

pub const BarOptions = struct {
    /// The theme's highlight when null.
    color: ?dvui.Color = null,
    /// Full strength; otherwise a little fainter (a child row under its parent).
    strong: bool = true,
};

/// `fraction` (0 to 1) of the box's width filled from its left edge, so bars side by side
/// compare by their length. `scale.fraction` makes one from a value and its whole.
pub fn bar(src: std.builtin.SourceLocation, fraction: f32, opts: BarOptions, wopts: dvui.Options) void {
    const defaults: dvui.Options = .{ .name = "viz.bar", .expand = .horizontal, .min_size_content = .{ .w = 48, .h = 10 }, .gravity_y = 0.5 };
    var bb = dvui.box(src, .{}, defaults.override(wopts));
    defer bb.deinit();
    const rs = bb.data().contentRectScale();
    var r = rs.r;
    r.w *= std.math.clamp(fraction, 0, 1);
    if (r.w < 1) return;
    const c = opts.color orelse dvui.themeGet().color(.highlight, .fill);
    r.fill(.all(2 * rs.s), .{ .color = .{ .color = c.opacity(if (opts.strong) 1 else 0.75) }, .fade = 0 });
}

pub const StatOptions = struct {
    /// After the number, fainter: "ms", "fps", "MB".
    unit: []const u8 = "",
    /// Fixed, so a changing number keeps its width.
    decimals: u8 = 2,
};

/// `label value unit`, the label and unit faint and the number in the monospace font: one
/// reading of a dashboard's header, a status line's figure.
pub fn stat(src: std.builtin.SourceLocation, label: []const u8, value: f64, opts: StatOptions, wopts: dvui.Options) void {
    const defaults: dvui.Options = .{ .name = "viz.stat", .gravity_y = 0.5, .padding = .{ .w = 12 } };
    var row = dvui.box(src, .{ .dir = .horizontal }, defaults.override(wopts));
    defer row.deinit();
    const dim = dvui.themeGet().color(.control, .text).opacity(0.6);
    const mono = dvui.Font.theme(.mono);
    if (label.len > 0) dvui.labelNoFmt(@src(), label, .{}, .{ .font = mono, .color_text = .{ .color = dim }, .padding = .{ .w = 4 }, .gravity_y = 0.5 });
    var buf: [48]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{[v]d:.[p]}", .{ .v = value, .p = opts.decimals }) catch "?";
    // As wide as three digits and the decimals whatever the number, so a row of stats keeps
    // its layout while the numbers change: "79" and "120" take the same room.
    const digits = "000.000000000";
    const room = mono.textSize(digits[0 .. 3 + @as(usize, if (opts.decimals > 0) 1 + @min(opts.decimals, 9) else 0)]).w;
    {
        // Right-aligned in its own box: in the row itself, a child pulled right is packed at the
        // row's far end, after the unit.
        var cell = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = room, .h = 0 }, .gravity_y = 0.5 });
        defer cell.deinit();
        dvui.labelNoFmt(@src(), text, .{}, .{ .font = mono, .padding = .{}, .gravity_x = 1 });
    }
    if (opts.unit.len > 0) dvui.labelNoFmt(@src(), opts.unit, .{}, .{ .font = mono, .color_text = .{ .color = dim }, .padding = .{ .x = 3 }, .gravity_y = 0.5 });
}
