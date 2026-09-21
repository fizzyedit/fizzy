//! `core.draw` — drawing with no widget of its own.
//!
//! Highlighted labels for filter results, the fixed icon slot a menu row reserves, keybind
//! labels, edge shadows for scrolled content, the active-tab indicator. Each is a few `pathFill`
//! calls a caller makes *inside* someone else's widget, which is why none of them is a type.
//!
//! `core` and not the app, because a plugin's list should shade its edges the same way fizzy's
//! does — see `core.widgets` for the divide.
const std = @import("std");
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
/// Shared by fizzy's own menu rows (`Menu.menuItemWithHotkey`, from `menu_model.CommandItem`)
/// and plugin-contributed ones (`Editor.fizzyDrawMenuItem`, from `sdk.Command`) so both draw the
/// same slot the same way.
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

pub fn labelWithKeybind(label_str: []const u8, hotkey: dvui.enums.Keybind, enabled: bool, label_opts: dvui.Options, opts: dvui.Options) void {
    const box = dvui.box(@src(), .{ .dir = .horizontal }, opts);
    defer box.deinit();

    var new_opts = label_opts.strip();
    new_opts.gravity_y = 0.5;
    if (!enabled) {
        if (new_opts.color_text) |c| {
            new_opts.color_text = c.opacity(0.5);
        } else {
            new_opts.color_text = .{ .color = dvui.themeGet().color(.window, .text).opacity(0.5) };
        }
    }

    dvui.labelNoFmt(@src(), label_str, .{}, new_opts);
    _ = dvui.spacer(@src(), .{ .min_size_content = .width(12) });

    var second_opts = opts.strip();
    second_opts.color_text = .{ .color = dvui.themeGet().color(.control, .text) };
    second_opts.gravity_y = 0.5;
    second_opts.gravity_x = 1.0;
    second_opts.font = dvui.Font.theme(.heading);

    keybindLabels(&hotkey, enabled, second_opts);
}

pub fn keybindLabels(self: *const dvui.enums.Keybind, enabled: bool, opts: dvui.Options) void {
    var box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = opts.expand, .gravity_x = 1.0 });
    defer box.deinit();

    var color = if (opts.color_text) |c| c.toColor() else dvui.themeGet().color(.control, .text);
    if (true or enabled) {
        color = color.opacity(0.5);
    }

    var second_opts = opts.strip();
    second_opts.color_text = .{ .color = color };
    second_opts.font = dvui.Font.theme(.mono);
    second_opts.gravity_y = 0.5;

    var needs_space = false;
    if (self.control) |ctrl| {
        if (ctrl) {
            needs_space = true;
            if (needs_space) dvui.labelNoFmt(@src(), " ", .{}, opts.strip());
            //if (needs_plus) dvui.labelNoFmt(@src(), "+", .{}, opts.strip()) else needs_plus = true;
            //if (needs_space) dvui.labelNoFmt(@src(), " ", .{}, opts.strip()) else needs_space = true;

            dvui.labelNoFmt(@src(), "ctrl", .{}, second_opts);
        }
    }

    if (self.command) |cmd| {
        if (cmd) {
            needs_space = true;
            if (needs_space) dvui.labelNoFmt(@src(), " ", .{}, opts.strip());
            //if (needs_plus) dvui.labelNoFmt(@src(), "+", .{}, opts.strip()) else needs_plus = true;
            //if (needs_space) dvui.labelNoFmt(@src(), " ", .{}, opts.strip()) else needs_space = true;
            if (platform.isMacOS()) {
                icon_tex.icon(@src(), "cmd", icons.tvg.lucide.command, .{ .stroke_color = .{ .color = color } }, .{ .gravity_y = 0.5 });
            } else {
                dvui.labelNoFmt(@src(), "cmd", .{}, second_opts);
            }
        }
    }

    if (self.alt) |alt| {
        if (alt) {
            needs_space = true;
            if (needs_space) dvui.labelNoFmt(@src(), " ", .{}, opts.strip());
            //if (needs_plus) dvui.labelNoFmt(@src(), "+", .{}, opts.strip()) else needs_plus = true;
            //if (needs_space) dvui.labelNoFmt(@src(), " ", .{}, opts.strip()) else needs_space = true;
            if (platform.isMacOS()) {
                icon_tex.icon(@src(), "option", icons.tvg.lucide.option, .{ .stroke_color = .{ .color = color } }, .{ .gravity_y = 0.5 });
            } else {
                dvui.labelNoFmt(@src(), "alt", .{}, second_opts);
            }
        }
    }

    if (self.shift) |shift| {
        if (shift) {
            needs_space = true;
            if (needs_space) dvui.labelNoFmt(@src(), " ", .{}, opts.strip());
            //if (needs_plus) dvui.labelNoFmt(@src(), "+", .{}, opts.strip()) else needs_plus = true;
            //if (needs_space) dvui.labelNoFmt(@src(), " ", .{}, opts.strip()) else needs_space = true;
            dvui.labelNoFmt(@src(), "shift", .{}, second_opts);
        }
    }

    if (self.key) |key| {
        needs_space = true;
        if (needs_space) dvui.labelNoFmt(@src(), " ", .{}, opts.strip());
        //if (needs_plus) dvui.labelNoFmt(@src(), "+", .{}, opts.strip()) else needs_plus = true;
        //if (needs_space) dvui.labelNoFmt(@src(), " ", .{}, opts.strip()) else needs_space = true;
        dvui.labelNoFmt(@src(), @tagName(key), .{}, second_opts);
    }
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
