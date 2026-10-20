//! `core.draw` — drawing with no widget of its own.
//!
//! Highlighted labels for filter results, the fixed icon slot a menu row reserves, keybind
//! labels, edge shadows for scrolled content, the active-tab indicator. Each is a few `pathFill`
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

/// Draw `text` as a single-line label, tinting the bytes `query` matched with the theme
/// highlight colour — same treatment as the file-tree filter, settings search, and plugin store.
///
/// Falls back to a plain `dvui.label` when the query is empty or nothing matched. `plain`
/// should match how the row was scored (`false` for paths, `true` for bare names/titles).
pub fn labelHighlighted(
    src: std.lang.SourceLocation,
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
