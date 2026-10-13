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
    labels: Labels = .leaders,

    pub const Labels = enum {
        /// Out from each slice to its name and value, on its side: the pie in the middle of a
        /// place with room on both sides.
        leaders,
        /// A list beside the pie, a swatch, name and value a row: for a place short or narrow
        /// enough that leaders on both sides would leave the names no room. Hovering a row is
        /// hovering its slice.
        legend,
        /// None: the pie fills its box, and something beside it says which colour is what (a
        /// table whose bars are in the pie's colours, `colors`). The hole still names the slice
        /// under the pointer.
        none,
    };
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
    // Its labels and its pulled-out slice stay inside its box, however small the place makes it.
    const prev_clip = dvui.clip(r);
    defer dvui.clipSet(prev_clip);
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

    const legend = opts.labels == .legend;
    const bare = opts.labels == .none;
    const pop = 5 * s;
    // With leaders, room for their labels on both sides, and the pie takes the middle; with a
    // legend, the pie sits at the left and the list takes the rest.
    const radius = @max(8 * s, if (bare) @min(r.h, r.w) / 2 - pop else if (legend) @min(r.h * 0.42, r.w * 0.24) else @min(r.h * 0.4, r.w * 0.2));
    const inner = radius * opts.hole;
    const c: dvui.Point.Physical = if (legend)
        .{ .x = r.x + radius + pop, .y = r.y + r.h / 2 }
    else
        .{ .x = r.x + r.w / 2, .y = r.y + r.h / 2 };
    const font = dvui.Font.theme(.body).withSize(dvui.Font.theme(.body).size * 0.9);
    const mono = dvui.Font.theme(.mono);
    const line_h = font.textHeight() * s;

    // The legend's rows, the slices big enough to name, centred beside the pie.
    var rows: std.ArrayList(usize) = .empty;
    // Every slice: a list has the room leaders do not.
    if (legend and total > 0) for (slices, 0..) |sl, i| {
        if (sl.value > 0) rows.append(arena, i) catch {};
    };
    const row_h = line_h + 4 * s;
    const legend_x = c.x + radius + pop + 12 * s;
    const legend_y = std.math.clamp(c.y - @as(f32, @floatFromInt(rows.items.len)) * row_h / 2, r.y, @max(r.y, r.y + r.h - @as(f32, @floatFromInt(rows.items.len)) * row_h));

    // The slice under the pointer: inside the ring (and its pulled-out edge), at its angle.
    var hovered: ?usize = null;
    const mouse = dvui.currentWindow().mouse_pt;
    if (sum > 0 and r.contains(mouse) and dvui.clipGet().contains(mouse)) {
        const dx = mouse.x - c.x;
        const dy = mouse.y - c.y;
        const d = @sqrt(dx * dx + dy * dy);
        if (d >= inner and d <= radius + pop) hovered = scale.sliceAt(scale.angleFromTop(dx, dy), shares);
        if (legend and mouse.x >= legend_x - 4 * s) for (rows.items, 0..) |i, n| {
            const y = legend_y + @as(f32, @floatFromInt(n)) * row_h;
            if (mouse.y >= y and mouse.y < y + row_h) hovered = i;
        };
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
        if (opts.labels == .leaders and (shares[i] / sum >= opts.leader_min or hovered == i)) {
            const right = @sin(mid) >= 0;
            leaders.append(arena, .{ .i = i, .mid = mid, .y = c.y - @cos(mid) * (radius + 10 * s), .right = right }) catch {};
        }
    }

    // The legend: a swatch, the name cut to the room left, and the value at the right edge.
    for (rows.items, 0..) |i, n| {
        const y = legend_y + @as(f32, @floatFromInt(n)) * row_h + 2 * s;
        const faded = hovered != null and hovered != i;
        const sw = 8 * s;
        const swatch: dvui.Rect.Physical = .{ .x = legend_x, .y = y + (line_h - sw) / 2, .w = sw, .h = sw };
        swatch.fill(.all(2 * s), .{ .color = .{ .color = if (faded) colors[i].opacity(0.4) else colors[i] }, .fade = 1 });
        var buf: [32]u8 = undefined;
        const value = std.fmt.bufPrint(&buf, "{[v]d:.[p]} {[u]s}", .{ .v = slices[i].value, .p = opts.decimals, .u = opts.unit }) catch "";
        const value_w = mono.textSize(value).w * s;
        const name_x = legend_x + sw + 6 * s;
        const name = viz.fit(arena, font, slices[i].label, (r.x + r.w - value_w - 8 * s - name_x) / s);
        const name_w = font.textSize(name).w * s;
        dvui.renderText(.{ .font = font, .text = name, .rs = .{ .r = .{ .x = name_x, .y = y, .w = name_w, .h = line_h }, .s = s }, .color = if (faded) text_col.opacity(0.4) else text_col }) catch {};
        dvui.renderText(.{ .font = mono, .text = value, .rs = .{ .r = .{ .x = r.x + r.w - value_w, .y = y, .w = value_w, .h = line_h }, .s = s }, .color = text_col.opacity(if (faded) 0.3 else 0.75) }) catch {};
    }

    // Leaders: out from the rim, then level to a label on that side, the labels on each side
    // pushed apart so none overlap.
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
            const name = viz.fit(arena, font, sl.label, room / s);
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
        const cap = viz.fit(arena, font, caption, inner * 1.7 / s);
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

/// A ring's arc from `a0` to `a1` (clockwise from the top) between `inner` and `outer`, as a mesh
/// of its own: across the ring four rows of points, a pixel's fade outside each edge, and along it
/// the same fade past each end. Every edge is anti-aliased alike, the round ones and the cuts
/// between slices, where a stroke's ends were hard and showed jagged; and nothing overlaps, so a
/// faded slice is evenly faded.
fn ring(c: dvui.Point.Physical, outer: f32, inner: f32, a0: f32, a1: f32, col: dvui.Color, s: f32) void {
    if (a1 <= a0) return;
    const f = s; // the fade: a pixel
    const mid = (outer + inner) / 2;
    // Half the fade as an angle at the ring's middle: the solid part starts half a pixel inside
    // each end, the fade reaches half a pixel past it.
    const half = f / 2 / mid;
    const sweep = a1 - a0;
    // A sliver thinner than its fade is drawn at the alpha its width earns.
    const thin = @min(1, sweep / (2 * half));
    const steps: usize = @max(1, @as(usize, @intFromFloat(@ceil(sweep * outer / (2 * s)))));
    const cols = steps + 3;
    const radii = [4]f32{ inner - f / 2, inner + f / 2, outer - f / 2, outer + f / 2 };
    const row_alpha = [4]f32{ 0, 1, 1, 0 };
    const lifo = dvui.currentWindow().lifo();
    var b = dvui.Triangles.Builder.init(lifo, cols * 4, (cols - 1) * 3 * 6) catch return;
    defer b.deinit(lifo);
    for (0..cols) |k| {
        const angle, const col_alpha = if (k == 0)
            .{ a0 - half, 0 }
        else if (k == cols - 1)
            .{ a1 + half, 0 }
        else blk: {
            const t = @as(f32, @floatFromInt(k - 1)) / @as(f32, @floatFromInt(steps));
            const lo = a0 + @min(half, sweep / 2);
            const hi = a1 - @min(half, sweep / 2);
            break :blk .{ lo + (hi - lo) * t, thin };
        };
        const sin = @sin(angle);
        const cos = @cos(angle);
        for (radii, row_alpha) |radius, ra| {
            b.appendVertex(.{
                .pos = .{ .x = c.x + sin * radius, .y = c.y - cos * radius },
                .col = .fromColor(col.opacity(ra * col_alpha)),
                .uv = .{ 0, 0 },
            });
        }
    }
    for (0..cols - 1) |k| {
        const here: dvui.Vertex.Index = @intCast(k * 4);
        const next: dvui.Vertex.Index = @intCast((k + 1) * 4);
        for (0..3) |j| {
            const jj: dvui.Vertex.Index = @intCast(j);
            b.appendTriangles(&.{ here + jj, here + jj + 1, next + jj + 1, here + jj, next + jj + 1, next + jj });
        }
    }
    dvui.renderTriangles(b.build_unowned(), null) catch {};
}
