//! A donut of shares of a whole, with leader lines out to each slice's name and value, the
//! slice under the pointer pulled out and the others faded, and the hole saying what the
//! slices add up to (or, while one is hovered, that slice's share).
//!
//!     var pie: viz.Pie = .init(@src(), slices, .{ .unit = "ms", .caption = "per frame" }, .{});
//!     defer pie.deinit();
//!     if (pie.hovered) |i| … // the slice under the pointer, to show elsewhere too
//!
//! The slices ease to new values rather than jump, each followed by its `key` (its name when it
//! has none), so a slice that changes place keeps its colour and moves instead of flickering.
//! A slice's colour comes from its key too: `viz.keyColor`, moved along the palette when another
//! slice in view already has it, so no two slices look alike. `colors` says what each got, for
//! a table beside the pie to draw the same thing in the same colour.
const Pie = @This();

const std = @import("std");
const dvui = @import("dvui");
const viz = @import("viz.zig");
const scale = @import("scale.zig");

box: *dvui.BoxWidget,
/// The slice under the pointer, while there is one.
hovered: ?usize,
/// Each slice's key and the colour it was drawn in, for this frame: a table beside the pie
/// colours the same things the same way.
keys: []const u64,
colors: []const dvui.Color,

pub const Slice = struct {
    label: []const u8,
    value: f32,
    /// What the slice is, across frames: its colour and its easing follow it. A hash of
    /// `label` when null.
    key: ?u64 = null,
    /// `viz.keyColor(key)` when null.
    color: ?dvui.Color = null,
};

pub const Options = struct {
    /// After each value: "ms".
    unit: []const u8 = "",
    decimals: u8 = 2,
    /// Under the total in the hole: what the whole is ("per frame", "frame -12").
    caption: []const u8 = "",
    /// The hole's radius, as a share of the pie's.
    hole: f32 = 0.62,
    /// Between slices, in natural pixels.
    gap: f32 = 2,
    /// Slices smaller than this share get no leader (the hole still names them on hover).
    leader_min: f32 = 0.025,
    /// Ease between values rather than jump.
    ease: bool = true,
};

/// What a slice was last drawn as, kept between frames for the easing.
const Shown = struct { key: u64, share: f32 };

pub fn init(src: std.builtin.SourceLocation, slices: []const Slice, opts: Options, wopts: dvui.Options) Pie {
    const defaults: dvui.Options = .{ .name = "viz.Pie", .min_size_content = .{ .w = 300, .h = 200 } };
    const box = dvui.box(src, .{}, defaults.override(wopts));
    const id = box.data().id;
    const rs = box.data().contentRectScale();
    const r = rs.r;
    const s = rs.s;
    const arena = dvui.currentWindow().arena();
    const text_col = dvui.themeGet().color(.control, .text);
    const dim = text_col.opacity(0.6);

    var total: f32 = 0;
    for (slices) |sl| total += @max(0, sl.value);

    // The shares to draw: each slice eased from what it was last frame toward its share now.
    const none: Pie = .{ .box = box, .hovered = null, .keys = &.{}, .colors = &.{} };
    const keys = arena.alloc(u64, slices.len) catch return none;
    const shares = arena.alloc(f32, slices.len) catch return none;
    const colors = arena.alloc(dvui.Color, slices.len) catch return none;
    const prev = dvui.dataGetSlice(null, id, "shown", []Shown) orelse &.{};
    const k: f32 = if (opts.ease) 1 - @exp(-dvui.secondsSinceLastFrame() * 14) else 1;
    var moving = false;
    for (slices, 0..) |sl, i| {
        keys[i] = sl.key orelse std.hash.Wyhash.hash(0, sl.label);
        const want = if (total > 0) @max(0, sl.value) / total else 0;
        const was = for (prev) |p| {
            if (p.key == keys[i]) break p.share;
        } else 0;
        shares[i] = was + (want - was) * k;
        if (@abs(shares[i] - want) > 0.001) moving = true else shares[i] = want;
    }
    assignColors(arena, slices, keys, colors);
    if (arena.alloc(Shown, slices.len)) |keep| {
        for (keep, 0..) |*p, i| p.* = .{ .key = keys[i], .share = shares[i] };
        dvui.dataSetSlice(null, id, "shown", keep);
    } else |_| {}
    if (moving) dvui.refresh(null, @src(), id);
    var sum: f32 = 0;
    for (shares) |sh| sum += sh;

    // Room for leaders and their labels on both sides; the pie takes the middle.
    const radius = @max(8 * s, @min(r.h * 0.4, r.w * 0.2));
    const inner = radius * opts.hole;
    const c: dvui.Point.Physical = .{ .x = r.x + r.w / 2, .y = r.y + r.h / 2 };
    const pop = 5 * s;

    // The slice under the pointer: inside the ring (and its pulled-out edge), at its angle.
    var hovered: ?usize = null;
    const mouse = dvui.currentWindow().mouse_pt;
    if (sum > 0 and r.contains(mouse) and dvui.clipGet().contains(mouse)) {
        const dx = mouse.x - c.x;
        const dy = mouse.y - c.y;
        const d = @sqrt(dx * dx + dy * dy);
        if (d >= inner and d <= radius + pop) hovered = scale.sliceAt(scale.angleFromTop(dx, dy), shares);
    }

    if (sum <= 0) {
        // Nothing to share out: the empty ring, so the place keeps its shape.
        ring(c, radius, inner, 0, 2 * std.math.pi, dim.opacity(0.25), s);
    }

    const tau: f32 = 2 * std.math.pi;
    const Leader = struct { i: usize, mid: f32, y: f32, right: bool };
    var leaders: std.ArrayList(Leader) = .empty;
    var start: f32 = 0;
    for (slices, 0..) |sl, i| {
        if (sum <= 0) break;
        const sweep = shares[i] / sum * tau;
        defer start += sweep;
        if (sweep <= 0) continue;
        const mid = start + sweep / 2;
        const out: f32 = if (hovered == i) pop else 0;
        const at: dvui.Point.Physical = .{ .x = c.x + @sin(mid) * out, .y = c.y - @cos(mid) * out };
        // The gap is the same width at the rim whatever the slice's size; a sliver too thin for
        // it is drawn without.
        const half_gap = opts.gap * s / 2 / radius;
        const inset = if (sweep > 4 * half_gap) half_gap else 0;
        var col = colors[i];
        if (hovered != null and hovered != i) col = col.opacity(0.4);
        _ = sl;
        ring(at, radius, inner, start + inset, start + sweep - inset, col, s);
        if (shares[i] / sum >= opts.leader_min or hovered == i) {
            const right = @sin(mid) >= 0;
            leaders.append(arena, .{ .i = i, .mid = mid, .y = c.y - @cos(mid) * (radius + 10 * s), .right = right }) catch {};
        }
    }

    // Leaders: out from the rim, then level to a label on that side, the labels on each side
    // pushed apart so none overlap.
    const font = dvui.Font.theme(.body).withSize(dvui.Font.theme(.body).size * 0.9);
    const mono = dvui.Font.theme(.mono);
    const line_h = font.textHeight() * s;
    // A label is two lines: the name, and under it the value.
    const label_h = 2 * line_h;
    for ([_]bool{ false, true }) |side| {
        var idx: std.ArrayList(usize) = .empty;
        for (leaders.items, 0..) |l, li| if (l.right == side) idx.append(arena, li) catch {};
        std.mem.sort(usize, idx.items, leaders.items, struct {
            fn lt(ls: []Leader, a: usize, b: usize) bool {
                return ls[a].y < ls[b].y;
            }
        }.lt);
        const ys = arena.alloc(f32, idx.items.len) catch continue;
        for (ys, idx.items) |*y, li| y.* = leaders.items[li].y;
        scale.spread(ys, label_h + 2 * s, r.y + label_h / 2, r.y + r.h - label_h / 2);
        for (ys, idx.items) |y, li| {
            const l = leaders.items[li];
            const sl = slices[l.i];
            const out: f32 = if (hovered == l.i) pop else 0;
            const dir: f32 = if (side) 1 else -1;
            const rim: dvui.Point.Physical = .{ .x = c.x + @sin(l.mid) * (radius + out + 2 * s), .y = c.y - @cos(l.mid) * (radius + out + 2 * s) };
            const elbow: dvui.Point.Physical = .{ .x = c.x + @sin(l.mid) * (radius + 10 * s), .y = y };
            const end: dvui.Point.Physical = .{ .x = c.x + dir * (radius + 22 * s), .y = y };
            const faded = hovered != null and hovered != l.i;
            var col = colors[l.i];
            if (faded) col = col.opacity(0.4);
            var path: dvui.Path.Builder = .init(arena);
            path.addPoint(rim);
            path.addPoint(elbow);
            path.addPoint(end);
            path.build().stroke(.{ .thickness = 1 * s, .color = .{ .color = col } });

            // The name, cut to the room that side has, and its value under it: level with the
            // leader's end, outward from it.
            var buf: [32]u8 = undefined;
            const value = std.fmt.bufPrint(&buf, "{[v]d:.[p]} {[u]s}", .{ .v = sl.value, .p = opts.decimals, .u = opts.unit }) catch "";
            const room = (if (side) r.x + r.w - end.x else end.x - r.x) - 6 * s;
            const name = fit(arena, font, sl.label, room / s);
            const name_w = font.textSize(name).w * s;
            const value_w = mono.textSize(value).w * s;
            const ty = y - line_h;
            const name_x = if (side) end.x + 4 * s else end.x - 4 * s - name_w;
            const value_x = if (side) end.x + 4 * s else end.x - 4 * s - value_w;
            dvui.renderText(.{ .font = font, .text = name, .rs = .{ .r = .{ .x = name_x, .y = ty, .w = name_w, .h = line_h }, .s = s }, .color = if (faded) text_col.opacity(0.4) else text_col }) catch {};
            const value_col = text_col.opacity(if (faded) 0.3 else 0.75);
            dvui.renderText(.{ .font = mono, .text = value, .rs = .{ .r = .{ .x = value_x, .y = ty + line_h, .w = value_w, .h = line_h }, .s = s }, .color = value_col }) catch {};
        }
    }

    // The hole: the whole, or the hovered slice's value and share of it.
    {
        const big = dvui.Font.theme(.mono).withSize(dvui.Font.theme(.mono).size * 1.25);
        var vbuf: [48]u8 = undefined;
        var cbuf: [96]u8 = undefined;
        const value, const caption = if (hovered) |h| .{
            std.fmt.bufPrint(&vbuf, "{[v]d:.[p]} {[u]s}", .{ .v = slices[h].value, .p = opts.decimals, .u = opts.unit }) catch "",
            std.fmt.bufPrint(&cbuf, "{d:.0}% · {s}", .{ shares[h] / sum * 100, slices[h].label }) catch "",
        } else .{
            std.fmt.bufPrint(&vbuf, "{[v]d:.[p]} {[u]s}", .{ .v = total, .p = opts.decimals, .u = opts.unit }) catch "",
            opts.caption,
        };
        const vs = big.textSize(value).scale(s, dvui.Size.Physical);
        const cap = fit(arena, font, caption, inner * 1.7 / s);
        const cs = font.textSize(cap).scale(s, dvui.Size.Physical);
        const top = c.y - (vs.h + cs.h) / 2;
        dvui.renderText(.{ .font = big, .text = value, .rs = .{ .r = .{ .x = c.x - vs.w / 2, .y = top, .w = vs.w, .h = vs.h }, .s = s }, .color = text_col }) catch {};
        dvui.renderText(.{ .font = font, .text = cap, .rs = .{ .r = .{ .x = c.x - cs.w / 2, .y = top + vs.h, .w = cs.w, .h = cs.h }, .s = s }, .color = dim }) catch {};
    }

    return .{ .box = box, .hovered = hovered, .keys = keys, .colors = colors };
}

pub fn deinit(self: *Pie) void {
    self.box.deinit();
}

/// Each slice's colour: its own when it names one, else `viz.keyColor` of its key, moved along
/// the palette past colours another slice already took. Taken in key order, not slice order, so
/// slices trading places as their values change keep their colours.
fn assignColors(arena: std.mem.Allocator, slices: []const Slice, keys: []const u64, colors: []dvui.Color) void {
    const order = arena.alloc(usize, slices.len) catch {
        for (colors, keys) |*c, k| c.* = viz.keyColor(k);
        return;
    };
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, keys, struct {
        fn lt(ks: []const u64, a: usize, b: usize) bool {
            return ks[a] < ks[b];
        }
    }.lt);
    const n = viz.palette.colors.len;
    var taken: [64]bool = @splat(false);
    for (order) |i| {
        if (slices[i].color) |c| {
            colors[i] = c;
            continue;
        }
        var at: usize = @intCast(keys[i] % n);
        var tries: usize = 0;
        while (taken[at] and tries < n) : (tries += 1) at = (at + 1) % n;
        taken[at] = true;
        colors[i] = viz.palette.colors[at];
    }
}

/// A ring's arc from `a0` to `a1` (clockwise from the top) between `inner` and `outer`, filled
/// with its edge anti-aliased.
fn ring(c: dvui.Point.Physical, outer: f32, inner: f32, a0: f32, a1: f32, col: dvui.Color, s: f32) void {
    if (a1 <= a0) return;
    var path: dvui.Path.Builder = .init(dvui.currentWindow().arena());
    // Fine enough that the rim reads as a curve at any size: a step of about 3 pixels.
    const steps: usize = @max(2, @as(usize, @intFromFloat(@ceil((a1 - a0) * outer / (3 * s)))));
    for (0..steps + 1) |n| {
        const a = a0 + (a1 - a0) * @as(f32, @floatFromInt(n)) / @as(f32, @floatFromInt(steps));
        path.addPoint(.{ .x = c.x + @sin(a) * outer, .y = c.y - @cos(a) * outer });
    }
    for (0..steps + 1) |n| {
        const a = a1 - (a1 - a0) * @as(f32, @floatFromInt(n)) / @as(f32, @floatFromInt(steps));
        path.addPoint(.{ .x = c.x + @sin(a) * inner, .y = c.y - @cos(a) * inner });
    }
    dvui.Path.fill(&.{path.build()}, .{ .color = .{ .color = col }, .fade = 1 });
}

/// `text` cut to `max_w` (natural pixels) with an ellipsis, or whole if it fits.
fn fit(arena: std.mem.Allocator, font: dvui.Font, text: []const u8, max_w: f32) []const u8 {
    if (max_w <= 0) return "";
    if (font.textSize(text).w <= max_w) return text;
    const ellipsis = "…";
    var end: usize = 0;
    _ = font.textSizeEx(text, .{ .max_width = @max(0, max_w - font.textSize(ellipsis).w), .end_idx = &end });
    return std.fmt.allocPrint(arena, "{s}{s}", .{ text[0..end], ellipsis }) catch text[0..end];
}
