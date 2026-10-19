//! `core.draw` — drawing with no widget of its own.
//!
//! Highlighted labels for filter results, the fixed icon slot a menu row reserves, keybind
//! labels, edge shadows for scrolled content, the active-tab indicator, a control's raised or inset
//! edge. Each is a few `pathFill`
//! calls a caller makes *inside* someone else's widget, which is why none of them is a type.
//!
//! `core` and not the app, because a plugin's list should shade its edges the same way fizzy's
//! does — see `core.widgets` for the divide.
const std = @import("std");
const keycaps = @import("keycaps.zig");
const dvui = @import("dvui");
const icon_tex = @import("gfx/icon.zig");
const builtin = @import("builtin");
const icons = @import("icons");
const platform = @import("platform.zig");
const fuzzy = @import("fuzzy.zig");
const widgets = @import("widgets.zig");
const edge = @import("edge.zig");
const liquid_glass = @import("glass").liquid_glass;

/// Draw `text` as a single-line label, tinting the bytes `query` matched with the theme
/// highlight colour — same treatment as the file-tree filter, settings search, and plugin store.
///
/// Falls back to a plain `dvui.label` when the query is empty or nothing matched. `plain`
/// should match how the row was scored (`false` for paths, `true` for bare names/titles).
pub fn labelHighlighted(
    src: std.builtin.SourceLocation,
    text: []const u8,
    query: *const fuzzy.Query,
    plain: bool,
    opts: dvui.Options,
) void {
    const color = opts.color(.text).toColor();
    if (query.isEmpty()) {
        dvui.label(src, "{s}", .{text}, opts);
        return;
    }

    var buf: [fuzzy.highlight_buf_len]usize = undefined;
    const hits = fuzzy.highlight(text, query, &buf, .{ .plain = plain });
    if (hits.len == 0) {
        dvui.label(src, "{s}", .{text}, opts);
        return;
    }

    var tl = dvui.textLayout(src, .{ .break_lines = false }, opts.override(.{ .background = false }));
    defer tl.deinit();

    const matched = dvui.themeGet().color(.highlight, .fill);
    var i: usize = 0;
    var h: usize = 0;
    while (i < text.len) {
        if (h < hits.len and hits[h] == i) {
            const start = i;
            while (h < hits.len and hits[h] == i) : (h += 1) i += 1;
            tl.addText(text[start..i], .{ .color_text = .{ .color = matched } });
        } else {
            const start = i;
            i = if (h < hits.len) hits[h] else text.len;
            tl.addText(text[start..i], .{ .color_text = .{ .color = color } });
        }
    }
}

/// `labelHighlighted`'s body, for callers that already own a `TextLayoutWidget` — appends `text`
/// to `tl` with the bytes `query` matched tinted, everything else in `plain_color`. Used for the
/// settings tree's rows, where the caller controls wrapping and font.
pub fn addHighlightedText(
    tl: *dvui.TextLayoutWidget,
    text: []const u8,
    query: *const fuzzy.Query,
    plain: bool,
    plain_color: dvui.Color,
) void {
    if (query.isEmpty()) {
        tl.addText(text, .{ .color_text = .{ .color = plain_color } });
        return;
    }

    var buf: [fuzzy.highlight_buf_len]usize = undefined;
    const hits = fuzzy.highlight(text, query, &buf, .{ .plain = plain });
    if (hits.len == 0) {
        tl.addText(text, .{ .color_text = .{ .color = plain_color } });
        return;
    }

    const matched = dvui.themeGet().color(.highlight, .fill);
    var i: usize = 0;
    var h: usize = 0;
    while (i < text.len) {
        if (h < hits.len and hits[h] == i) {
            // Consume the whole contiguous run of matched bytes in one addText.
            const start = i;
            while (h < hits.len and hits[h] == i) : (h += 1) i += 1;
            tl.addText(text[start..i], .{ .color_text = .{ .color = matched } });
        } else {
            const start = i;
            i = if (h < hits.len) hits[h] else text.len;
            tl.addText(text[start..i], .{ .color_text = .{ .color = plain_color } });
        }
    }
}

/// Draw a menu row's optional leading icon in a fixed `treeRowGlyph` slot. The slot is reserved
/// even when `bytes` is null, so a row with an icon and a row without one in the same menu still
/// line up in the same column instead of the label shifting left to fill the gap. Dimmed to half
/// opacity when `enabled` is false, matching `labelWithKeybind`'s greying of the label beside it.
///
/// Shared by `core.widgets.menuRow` (every menu's rows) and the command palette, so both draw
/// the same slot the same way.
pub fn menuRowIcon(bytes: ?[]const u8, base_color: dvui.Color, enabled: bool, id_extra: usize) void {
    var glyph = widgets.treeRowGlyph(@src(), .{ .id_extra = id_extra, .margin = .{ .w = 6 } });
    defer glyph.deinit();
    if (bytes) |b| {
        // Disabled is the colour half-way to the menu's fill, opaque: a translucent icon is a
        // mesh whose overlapping triangles double-blend (the web build draws them as a mesh).
        const color = if (enabled) base_color else base_color.lerp(dvui.themeGet().color(.control, .fill), 0.5);
        icon_tex.icon(@src(), "menu_icon", b, .{ .stroke_color = .{ .color = color }, .fill_color = .{ .color = color } }, widgets.treeRowIconOptions(.{ .id_extra = id_extra }));
    }
}

/// A menu row's label and its shortcut, laid out the way macOS lays out a menu: the label starts
/// right after the icon column, and the shortcut sits against the right edge — so down a whole
/// menu the shortcuts line up in their own column instead of trailing each label at a different x.
///
/// The row always fills the width it is given and the label takes the slack, whatever `opts`
/// says: a row that shrink-wraps puts every shortcut right after its label.
pub fn labelWithKeybind(label_str: []const u8, hotkey: dvui.enums.Keybind, enabled: bool, label_opts: dvui.Options, opts: dvui.Options) void {
    const box = dvui.box(@src(), .{ .dir = .horizontal }, opts.override(.{ .expand = .horizontal }));
    defer box.deinit();

    var label = label_opts.strip();
    label.gravity_y = 0.5;
    // Takes whatever the shortcut does not, which is what pushes the shortcut to the edge.
    label.expand = .horizontal;
    if (!enabled) {
        if (label.color_text) |c| {
            label.color_text = c.opacity(0.5);
        } else {
            label.color_text = .{ .color = dvui.themeGet().color(.window, .text).opacity(0.5) };
        }
    }
    dvui.labelNoFmt(@src(), label_str, .{}, label);

    // No shortcut, no gap: a row without one should not be widened by space for it.
    if (hotkey.key == null) return;
    // The minimum distance between a label and its shortcut. macOS keeps a wide one, so the
    // shortcut column reads as a column even in the widest row of the menu.
    _ = dvui.spacer(@src(), .{ .min_size_content = .width(28) });
    keybindLabels(&hotkey, enabled, .{ .id_extra = opts.id_extra });
}

/// A menu row's shortcut, drawn the way the OS's own menus draw one — `keycaps.draw` in `.plain`
/// style.
pub fn keybindLabels(self: *const dvui.enums.Keybind, enabled: bool, opts: dvui.Options) void {
    const stroke = keycaps.Stroke.fromKeybind(self.*) orelse return;
    keycaps.draw(@src(), stroke, .{
        .style = .plain,
        .enabled = enabled,
        .color = if (opts.color_text) |c| c.toColor().opacity(0.55) else null,
        .id_extra = opts.id_extra orelse 0,
    });
}

const Shadow = enum {
    top,
    bottom,
    right,
    left,
};

const ShadowOptions = struct {
    color: dvui.Color = .black,
    opacity: f32 = 0.25,
    offset: dvui.Rect = .{},
    thickness: f32 = 20.0,
    radius: f32 = 0.0,
};

const EdgeGradient = struct {
    axis: enum { x, y },
    opaque_at_zero: bool,
};

fn drawGradientRect(r: dvui.Rect.Physical, corners: dvui.CornerRect.Physical, opts: ShadowOptions, gradient: EdgeGradient) void {
    var path: dvui.Path.Builder = .init(dvui.currentWindow().arena());
    path.addRect(r, corners);
    var triangles = path.build().fillConvexTriangles(dvui.currentWindow().arena(), .{ .center = r.center(), .color = .white }) catch {
        path.deinit();
        return;
    };
    defer {
        triangles.deinit(dvui.currentWindow().arena());
        path.deinit();
    }

    const total_opacity = if (dvui.themeGet().dark) opts.opacity else opts.opacity * 0.5;

    const ca0 = opts.color.opacity(if (gradient.opaque_at_zero) total_opacity else 0.0);
    const ca1 = opts.color.opacity(if (gradient.opaque_at_zero) 0.0 else total_opacity);

    const t_scale_x = if (r.w > 0) 1.0 / r.w else 0.0;
    const t_scale_y = if (r.h > 0) 1.0 / r.h else 0.0;

    for (triangles.vertexes) |*v| {
        const t = std.math.clamp(
            if (gradient.axis == .y)
                (v.pos.y - r.y) * t_scale_y
            else
                (v.pos.x - r.x) * t_scale_x,
            0.0,
            1.0,
        );
        v.col = v.col.multiply(.fromColor(dvui.Color.lerp(ca0, ca1, t)));
    }
    dvui.renderTriangles(triangles, null) catch {
        dvui.log.err("Failed to render triangles", .{});
    };
}

/// Active workspace tab indicator: one snapped physical pixel along the tab bottom edge.
pub fn drawTabActiveIndicator(tab: dvui.RectScale, color: dvui.Color) void {
    if (tab.r.empty()) return;
    const scale = tab.s;
    var line = tab.r;
    line.h = scale;
    line.y = @floor(tab.r.y + tab.r.h - scale);
    line.x = @floor(line.x);
    line.w = @ceil(line.w);
    if (line.w <= 0) return;
    line.fill(.{}, .{ .color = .{ .color = color } });
}

pub fn drawEdgeShadow(container: dvui.RectScale, shadow: Shadow, opts: ShadowOptions) void {
    var rs = container;
    // Out to whole pixels. The fill has a hard edge, so on a fractional rect (a viewport beside
    // a text-sized ruler) the pixel the content part-covers got no shadow — a 1px bright seam
    // between the shadow and the viewport's edge.
    const x = @floor(rs.r.x);
    const y = @floor(rs.r.y);
    rs.r = .{ .x = x, .y = y, .w = @ceil(rs.r.x + rs.r.w) - x, .h = @ceil(rs.r.y + rs.r.h) - y };
    // And the clip out to whole pixels with it. The SDL backend truncates a clip's origin and
    // size separately, so its right/bottom edge lands on `trunc(x) + trunc(w)` — short of the
    // part-covered last pixel — and the bottom shadow's darkest row, the one on that pixel,
    // was cut off: the seam, back on the bottom edge only.
    const prev_clip = dvui.clipGet();
    defer dvui.clipSet(prev_clip);
    const cx = @floor(prev_clip.x);
    const cy = @floor(prev_clip.y);
    dvui.clipSet(.{ .x = cx, .y = cy, .w = @ceil(prev_clip.x + prev_clip.w) - cx, .h = @ceil(prev_clip.y + prev_clip.h) - cy });
    switch (shadow) {
        .top => {
            rs.r.h = opts.thickness;
            rs.r = rs.r.plus(.cast(opts.offset));
            drawGradientRect(rs.r, dvui.CornerRect.Physical.round(opts.radius), opts, .{ .axis = .y, .opaque_at_zero = true });
        },
        .bottom => {
            rs.r.y += rs.r.h - opts.thickness;
            rs.r.h = opts.thickness;
            rs.r = rs.r.plus(.cast(opts.offset));
            drawGradientRect(rs.r, dvui.CornerRect.Physical.round(opts.radius), opts, .{ .axis = .y, .opaque_at_zero = false });
        },
        .right => {
            rs.r.x += rs.r.w - opts.thickness;
            rs.r.w = opts.thickness;
            rs.r = rs.r.plus(.cast(opts.offset));
            drawGradientRect(rs.r, dvui.CornerRect.Physical.round(opts.radius), opts, .{ .axis = .x, .opaque_at_zero = false });
        },
        .left => {
            rs.r.w = opts.thickness;
            rs.r = rs.r.plus(.cast(opts.offset));
            drawGradientRect(rs.r, dvui.CornerRect.Physical.round(opts.radius), opts, .{ .axis = .x, .opaque_at_zero = true });
        },
    }
}

/// Scroll offsets are floats that rarely land exactly on their limit, so comparing them bare
/// makes an edge hint flicker on and off by a fraction of a pixel at the extremes.
const scroll_edge_epsilon: f32 = 0.5;

/// Draw "there is more content this way" hints on whichever edges of a scroll viewport actually
/// have content past them: `top` once scrolled away from the start, `bottom` while the end is
/// still below the viewport, and likewise `left`/`right`. An axis whose content already fits gets
/// nothing, and neither does an edge you have already scrolled to.
///
/// **This is the one definition of that behaviour.** Every viewport in the app routes through it
/// so they can't drift: explorer, sidebar, both store panes, the text editor, markdown previews,
/// and the workspace's recents list. (Testing only `virtual_size > viewport` for the
/// bottom/right edge leaves the hint showing when scrolled all the way to that end.)
/// Call this instead of `drawEdgeShadow` for anything that is a scroll viewport; reach
/// for `drawEdgeShadow` directly only for shadows that aren't about hidden scroll content (the
/// workspace draws one between the active tab and its neighbours, for instance).
///
/// Call it *after* the scroll area's content is drawn so the hints sit on top of it. Pass `null`
/// for an axis that doesn't scroll. The two rects are separate because some panes hint the two
/// axes over different areas — the explorer's horizontal hint spans a box its vertical one
/// doesn't, and the text editor's excludes the line-number gutter.
pub fn drawScrollEdgeShadows(
    vertical_rs: ?dvui.RectScale,
    horizontal_rs: ?dvui.RectScale,
    si: *const dvui.ScrollInfo,
    opts: ShadowOptions,
) void {
    if (vertical_rs) |rs| {
        if (!rs.r.empty() and si.virtual_size.h > si.viewport.h) {
            const off = si.offset(.vertical);
            if (off > scroll_edge_epsilon) drawEdgeShadow(rs, .top, opts);
            if (off + si.viewport.h < si.virtual_size.h - scroll_edge_epsilon) {
                drawEdgeShadow(rs, .bottom, opts);
            }
        }
    }
    if (horizontal_rs) |rs| {
        if (!rs.r.empty() and si.virtual_size.w > si.viewport.w) {
            const off = si.offset(.horizontal);
            if (off > scroll_edge_epsilon) drawEdgeShadow(rs, .left, opts);
            if (off + si.viewport.w < si.virtual_size.w - scroll_edge_epsilon) {
                drawEdgeShadow(rs, .right, opts);
            }
        }
    }
}

/// Which edge a control has: standing off its background, or sunk into it.
pub const EdgeKind = edge.Kind;

/// A control's raised or inset edge (`edge.zig`): how far it reaches and what it is made of.
pub const Edge = struct {
    /// Points from the outline to where the edge has faded out.
    depth: f32 = 4,
    shade: dvui.Color = .black,
    shade_alpha: f32 = 0.2,
    light: dvui.Color = .white,
    light_alpha: f32 = 0.9,

    /// The edge for `theme`. Light only reads where there is room above the background, so a
    /// dark theme gets a faint one and more shade.
    pub fn forTheme(theme: *const dvui.Theme) Edge {
        return if (theme.dark) .{ .shade_alpha = 0.45, .light_alpha = 0.06 } else .{};
    }
};

/// Draw a raised or inset edge round the outline `rs` with `corners`, lit from the top left. A
/// raised edge lies outside the outline, so it may go before or after the control's fill, and
/// the control needs `depth` of room round it (a margin) or its parent's clip cuts the edge off;
/// an inset one lies inside, so it goes after the fill and before the contents. Nothing is drawn
/// where the control is, so it suits a translucent control too. One mesh, one draw.
pub fn drawEdge(rs: dvui.RectScale, corners: dvui.CornerRect, kind: EdgeKind, e: Edge) void {
    const theme = dvui.themeGet();
    const c = corners.finalize(&theme);
    const radii: liquid_glass.Radii = .{ c.tl.radius() * rs.s, c.bl.radius() * rs.s, c.br.radius() * rs.s, c.tr.radius() * rs.s };
    const arena = dvui.currentWindow().arena();
    var tris = edgeMesh(arena, rs.r, radii, e.depth * rs.s, kind, e) catch return orelse return;
    defer tris.deinit(arena);
    dvui.renderTriangles(tris, null) catch {};
}

/// `drawEdge`'s mesh, in physical pixels: `radii` in `liquid_glass.ringPoints`' order, `depth`
/// how far the edge reaches. Null when there is nothing to draw.
fn edgeMesh(gpa: std.mem.Allocator, r: dvui.Rect.Physical, radii: liquid_glass.Radii, depth_px: f32, kind: EdgeKind, e: Edge) !?dvui.Triangles {
    if (r.w < 1 or r.h < 1) return null;
    // An inset edge can reach no further than the middle of the well.
    const depth = if (kind == .inset) @min(depth_px, @min(r.w, r.h) / 2) else depth_px;
    if (depth < 0.5) return null;
    const sign: f32 = if (kind == .raised) 1 else -1;
    // The widest ring's corners, so no ring's arc is coarser than it should be.
    const grow = if (kind == .raised) depth else 0;
    const arc_steps = liquid_glass.arcSteps(.{ radii[0] + grow, radii[1] + grow, radii[2] + grow, radii[3] + grow });
    const per_ring = 4 * (arc_steps + 1);
    const steps = edge.ring_steps;
    var b = try dvui.Triangles.Builder.init(gpa, per_ring * steps.len, per_ring * 6 * (steps.len - 1));
    errdefer b.deinit(gpa);
    const pts = try gpa.alloc(dvui.Point.Physical, per_ring);
    defer gpa.free(pts);
    const normals = try gpa.alloc(dvui.Point.Physical, per_ring);
    defer gpa.free(normals);
    // The outline's normals, for every ring: a point keeps the weight of the outline it is off.
    liquid_glass.ringPoints(pts, normals, r, radii, 0, arc_steps, 1, 1);
    for (steps) |x| {
        const d = sign * x * depth;
        const ring_radii: liquid_glass.Radii = .{ radii[0] + d, radii[1] + d, radii[2] + d, radii[3] + d };
        liquid_glass.ringPoints(pts, null, r, ring_radii, -d, arc_steps, 1, 1);
        const f = edge.fall(x);
        for (pts, normals) |p, n| {
            const w = edge.weights(kind, .{ n.x, n.y });
            const col: dvui.Color.PMA = if (w.shade > 0)
                .fromColor(e.shade.opacity(e.shade_alpha * w.shade * f))
            else
                .fromColor(e.light.opacity(e.light_alpha * w.light * f));
            b.appendVertex(.{ .pos = p, .col = col });
        }
    }
    liquid_glass.appendRingStrips(&b, per_ring, steps.len);
    return b.build();
}

/// The vertex of `tris` nearest `p`.
fn nearestVertex(tris: dvui.Triangles, p: dvui.Point.Physical) dvui.Vertex {
    var best = tris.vertexes[0];
    var best_d: f32 = std.math.inf(f32);
    for (tris.vertexes) |v| {
        const d = (v.pos.x - p.x) * (v.pos.x - p.x) + (v.pos.y - p.y) * (v.pos.y - p.y);
        if (d < best_d) {
            best_d = d;
            best = v;
        }
    }
    return best;
}

test "an inset edge lies inside its outline, shaded on the top and lit on the bottom" {
    const gpa = std.testing.allocator;
    const r: dvui.Rect.Physical = .{ .x = 10, .y = 10, .w = 100, .h = 40 };
    const e: Edge = .{ .shade = .black, .light = .white };
    var tris = (try edgeMesh(gpa, r, @splat(8), 6, .inset, e)).?;
    defer tris.deinit(gpa);
    for (tris.vertexes) |v| {
        try std.testing.expect(v.pos.x >= r.x - 0.01 and v.pos.x <= r.x + r.w + 0.01);
        try std.testing.expect(v.pos.y >= r.y - 0.01 and v.pos.y <= r.y + r.h + 0.01);
    }
    const top = nearestVertex(tris, .{ .x = 60, .y = 10 });
    const bottom = nearestVertex(tris, .{ .x = 60, .y = 50 });
    try std.testing.expect(top.col.a > 0 and top.col.r == 0);
    try std.testing.expect(bottom.col.a > 0 and bottom.col.r == bottom.col.a);
}

test "a raised edge lies outside its outline, lit on the left and shaded on the right" {
    const gpa = std.testing.allocator;
    const r: dvui.Rect.Physical = .{ .x = 10, .y = 10, .w = 100, .h = 40 };
    const e: Edge = .{ .shade = .black, .light = .white };
    var tris = (try edgeMesh(gpa, r, @splat(8), 6, .raised, e)).?;
    defer tris.deinit(gpa);
    // Signed distance to the rounded outline (radius 8): no vertex inside it, corners included.
    for (tris.vertexes) |v| {
        const qx = @abs(v.pos.x - (r.x + r.w / 2)) - (r.w / 2 - 8);
        const qy = @abs(v.pos.y - (r.y + r.h / 2)) - (r.h / 2 - 8);
        const sdf = std.math.hypot(@max(qx, 0), @max(qy, 0)) + @min(@max(qx, qy), 0) - 8;
        try std.testing.expect(sdf >= -0.01);
    }
    const left = nearestVertex(tris, .{ .x = 10, .y = 30 });
    const right = nearestVertex(tris, .{ .x = 110, .y = 30 });
    try std.testing.expect(left.col.a > 0 and left.col.r == left.col.a);
    try std.testing.expect(right.col.a > 0 and right.col.r == 0);
}

test "a well too small for its edge, or no edge, draws nothing broken" {
    const gpa = std.testing.allocator;
    try std.testing.expect(try edgeMesh(gpa, .{ .w = 0.5, .h = 10 }, @splat(0), 4, .inset, .{}) == null);
    try std.testing.expect(try edgeMesh(gpa, .{ .w = 10, .h = 10 }, @splat(0), 0, .raised, .{}) == null);
    // An inset edge deeper than half the well stops at its middle.
    var tris = (try edgeMesh(gpa, .{ .w = 10, .h = 6 }, @splat(2), 20, .inset, .{})).?;
    defer tris.deinit(gpa);
    for (tris.vertexes) |v| try std.testing.expect(v.pos.y >= -0.01 and v.pos.y <= 6.01);
}

test {
    // Compiled even before a control draws one.
    _ = &drawEdge;
}
