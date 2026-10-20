//! Round buttons in liquid glass: the controls that float over a document or a pane.
//!
//! Each is a glass bubble (`dialogs.glassBubbles`), the same glass as the demo player's transport
//! and pixi's canvas controls, refracting what is behind it along its own outline, with the
//! floating surfaces' shadow as a ring round it (never a box shadow, which the frost would read
//! back and blur). Hover and press light the glass; a toggled-on button stays glass, its icon in
//! the highlight. With the blur off the glass is the plain dialog fill.
const std = @import("std");
const dvui = @import("dvui");
const dialogs = @import("../dialogs.zig");
const screens = @import("../screens.zig");
const icon_draw = @import("../gfx/icon.zig");
const widgets = @import("../widgets.zig");

/// The size of a viewport bubble, in points: pixi's canvas controls are this size.
pub const size: f32 = 36;

/// How lit a button's glass is for its state (`dialogs.Bubble.light`).
pub fn light(btn: *dvui.ButtonWidget) f32 {
    return if (btn.pressed()) dialogs.bubble_press else if (btn.hovered()) dialogs.bubble_hover else 0;
}

/// The wash over a button inside a pane of glass (pixi's edit pill), as a menu's rows take: the
/// highlight when toggled on, else the menus' press and hover colours, else nothing.
pub fn wash(btn: *dvui.ButtonWidget, active: bool) void {
    const color: ?dvui.Color = if (active)
        highlight(btn)
    else if (btn.pressed())
        dialogs.rowPress()
    else if (btn.hovered())
        dialogs.rowHover()
    else
        null;
    if (color) |c| fillCircle(btn, c);
}

/// A toggled-on button's tint.
fn highlight(btn: *dvui.ButtonWidget) dvui.Color {
    return dvui.themeGet().color(.highlight, .fill).opacity(if (btn.hovered()) 1 else 0.85);
}

fn fillCircle(btn: *dvui.ButtonWidget, c: dvui.Color) void {
    const rs = btn.data().borderRectScale();
    rs.r.fill(.round(@min(rs.r.w, rs.r.h) / 2), .{ .color = .{ .color = c }, .fade = 1 });
}

/// A round button's whole background: its own disc of glass, lit under the pointer. Call after
/// `processEvents`, in place of `drawBackground`, with the button made by `options`. A toggled-on
/// button is still glass: its icon takes the highlight (`iconColor`).
///
/// `under_witness` is a signature of what lies under the glass (`witness`); the frost is read again only
/// when it changes. Null re-reads it every frame the app draws.
pub fn background(btn: *dvui.ButtonWidget, under_witness: ?u64) void {
    const rs = btn.data().borderRectScale();
    dialogs.glassBubbles(btn.data().id, &.{.{ .rect = rs.r, .light = light(btn) }}, rs.s, .{ .witness = under_witness });
}

/// The icon's colour on a glass button: the highlight when toggled on, the text colour otherwise;
/// disabled, most of the way to the content fill rather than see-through (at partial alpha a
/// stroked icon's overlapping caps and joins drew darker than its lines).
pub fn iconColor(active: bool, enabled: bool) dvui.Color {
    const theme = dvui.themeGet();
    const color = if (active) theme.color(.highlight, .fill) else theme.color(.content, .text);
    return if (enabled) color else color.lerp(theme.color(.content, .fill), 0.65);
}

/// A witness for glass at `r` (physical) over something whose look `under` signs (a canvas's art,
/// zoom and pan; a pane's scroll; 0 for a plain fill): what is under it, where the glass is, and
/// how glass is drawn.
pub fn witness(r: dvui.Rect.Physical, under: u64) u64 {
    var h = std.hash.Wyhash.init(under);
    h.update(std.mem.asBytes(&.{ r.x, r.y, r.w, r.h }));
    h.update(std.mem.asBytes(&.{ dialogs.style().blur, dvui.themeGet().color(.content, .fill) }));
    return h.final();
}

/// Button options for a round glass button of `diameter` points: no fill, border or shadow of its
/// own; `background` draws them.
pub fn options(diameter: f32, over: dvui.Options) dvui.Options {
    const base: dvui.Options = .{
        .min_size_content = .{ .w = diameter, .h = diameter },
        .expand = .none,
        .background = false,
        .border = .all(0),
        .corners = .round(diameter / 2),
        .color_border = .transparent,
        .box_shadow = null,
        .padding = .all(0),
        .margin = .{},
    };
    return base.override(over);
}

pub const BubbleOptions = struct {
    /// What it does, as its tooltip says and a screen reader reads it.
    label: []const u8,
    enabled: bool = true,
    active: bool = false,
    /// `witness` of what lies under it; null re-reads it every frame.
    witness_under: ?u64 = null,
    /// How much of the bubble the icon fills.
    icon_share: f32 = 0.34,
    id_extra: usize = 0,
};

/// A viewport bubble: a round glass button floating at `rect` (natural; `size` square, or smaller
/// while it grows in) with `icon` (tvg) in it and a tooltip. Floats over whatever is drawn there,
/// clipped to the screen it is on (the main window, or a float popped out of it). True on the
/// frame it is clicked.
pub fn bubble(src: std.lang.SourceLocation, rect: dvui.Rect, icon: []const u8, opts: BubbleOptions) bool {
    var fw: dvui.FloatingWidget = undefined;
    fw.init(src, .{}, .{
        .rect = rect,
        .expand = .none,
        .background = false,
        .id_extra = opts.id_extra,
    });
    defer fw.deinit();
    dvui.clipSet(screens.pixelsFor(.cast(fw.data().rect)));

    var btn: dvui.ButtonWidget = undefined;
    btn.init(@src(), .{}, options(@min(rect.w, rect.h), .{ .expand = .both, .label = .{ .text = opts.label } }));
    defer btn.deinit();
    if (opts.enabled) btn.processEvents();
    const r = btn.data().borderRectScale().r;
    background(&btn, if (opts.witness_under) |u| witness(r, u) else null);

    const color = iconColor(opts.active, opts.enabled);
    // White, tinted by the text colour: the icon cache tints a flat colour rather than baking it.
    icon_draw.icon(@src(), opts.label, icon, .{ .stroke_color = .white, .fill_color = .white }, .{
        .color_text = .{ .color = color },
        .expand = .ratio,
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 1, .h = 1 },
        .padding = .all(@min(rect.w, rect.h) * opts.icon_share),
    });

    widgets.tooltip(@src(), .{ .active_rect = btn.data().rectScale().r }, "{s}", .{opts.label}, .{});
    return opts.enabled and btn.clicked();
}
