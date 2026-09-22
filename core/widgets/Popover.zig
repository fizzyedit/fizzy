//! A popover: one level of a flyout, drawn like a dialog. A frosted, rounded, shadowed
//! floating window that grows from its anchor to fit its rows with the same overshoot the
//! store's cards and the palette use, holding rows styled like the command palette's — no
//! border, nothing at rest, a wash of `control.fill_hover` when hovered, generous padding.
//!
//! Not a dvui menu: `dvui.floatingMenu` styles its rows as menubar rows and paints its own
//! opaque chrome around them, and a submenu opened from it closes the chain on the press that
//! should have chosen a row. A flyout with more than one level draws one `Popover` per level
//! (the second anchored at the row that opened it) and closes on a press outside all of them —
//! see `outside`.
//!
//! Rows are the caller's: `row` lays out the hover/press shell and returns whether it was
//! clicked; the caller draws the label, picture or chevron inside it before `rowEnd`.
const std = @import("std");
const dvui = @import("dvui");
const dialogs = @import("../dialogs.zig");
const widgets = @import("../widgets.zig");
const FloatingWindowWidget = @import("FloatingWindowWidget.zig");

const Popover = @This();

win: *FloatingWindowWidget,
/// The window's rect this frame, physical. Where a press counts as inside.
rect: dvui.Rect.Physical,

/// The shared surface radius (`core.dialogs`), re-exported because callers anchor submenus
/// against it.
pub const corners: dvui.CornerRect = dialogs.surface_corners;

pub const InitOptions = struct {
    /// Persistent, caller-owned: the window animates its size through it across frames. Zero
    /// it to open fresh (the grow-from-nothing is the open animation).
    rect: *dvui.Rect,
    /// Where the window's top-left sits, natural coordinates.
    anchor: dvui.Point.Natural,
    id_extra: usize = 0,
};

/// Open (or continue) the popover. Rows go between this and `deinit`.
pub fn init(src: std.builtin.SourceLocation, init_opts: InitOptions) Popover {
    // Only the position is ours each frame; the size is auto-size's, animated from whatever it
    // was — a fresh rect grows from the anchor with the overshoot.
    init_opts.rect.x = init_opts.anchor.x;
    init_opts.rect.y = init_opts.anchor.y;
    const theme = dvui.themeGet();
    const win = widgets.floatingWindow(src, .{
        .rect = init_opts.rect,
        .resize = .none,
        .size_anchor = .top_left,
        .auto_size_axes = .both,
        .window_avoid = .nudge,
        .process_events_in_deinit = true,
        .frost = dialogs.dialogFrost(),
    }, .{
        .id_extra = init_opts.id_extra,
        .color_text = .{ .color = theme.color(.control, .text) },
        .color_fill = .{ .color = dialogs.dialogFill() },
        .corners = corners,
        .padding = dialogs.surface_padding,
        .border = .all(0),
        .box_shadow = dialogs.surfaceShadow(),
    });
    // Not a window anyone drags: no drag area, so the pointer over it is not the move cursor.
    win.dragAreaSet(.{});
    return .{ .win = win, .rect = win.data().borderRectScale().r };
}

pub fn deinit(self: *Popover) void {
    self.win.deinit();
}

pub const RowOptions = struct {
    enabled: bool = true,
    /// Held highlighted regardless of the mouse — the row whose submenu is open.
    active: bool = false,
    id_extra: usize = 0,
};

pub const Row = struct {
    box: *dvui.BoxWidget,
    hovered: bool,
    clicked: bool,

    /// Physical rect of the row, for anchoring a submenu at its right edge.
    pub fn rect(self: Row) dvui.Rect.Physical {
        return self.box.data().borderRectScale().r;
    }
    pub fn deinit(self: *Row) void {
        self.box.deinit();
    }
};

/// One row: the palette's shell, inside the open popover. The caller draws the row's
/// content (horizontal box) after, then `deinit`s it. Text inside inherits the popover's text colour; nothing changes on hover
/// but the fill.
pub fn row(src: std.builtin.SourceLocation, opts: RowOptions) Row {
    const theme = dvui.themeGet();
    const box = dvui.box(src, .{ .dir = .horizontal }, .{
        .id_extra = opts.id_extra,
        .expand = .horizontal,
        .background = false,
        .corners = .all(4),
        .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
        .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
    });
    const r = box.data().borderRectScale().r;
    const mouse = dvui.currentWindow().mouse_pt;
    const hovered = opts.enabled and r.contains(mouse) and dvui.clipGet().contains(mouse);
    var clicked = false;
    if (opts.enabled) {
        for (dvui.events()) |*e| {
            if (!dvui.eventMatchSimple(e, box.data())) continue;
            if (e.evt != .mouse) continue;
            const me = e.evt.mouse;
            if (me.action == .press and me.button.pointer()) {
                e.handle(@src(), box.data());
                clicked = true;
            } else if (me.action == .release and me.button.pointer()) {
                e.handle(@src(), box.data());
            }
        }
    }
    if (hovered) dvui.cursorSet(.hand);
    if (hovered or opts.active) {
        r.fill(.all(4 * box.data().rectScale().s), .{ .color = .{ .color = theme.color(.control, .fill_hover) }, .fade = 1.0 });
    }
    return .{ .box = box, .hovered = hovered, .clicked = clicked };
}

/// Whether a pointer press landed this frame outside every rect given (the popovers of a
/// flyout and the control that opened it): the flyout's cue to close.
pub fn outside(rects: []const dvui.Rect.Physical) bool {
    for (dvui.events()) |*e| {
        if (e.evt != .mouse or e.evt.mouse.action != .press or !e.evt.mouse.button.pointer()) continue;
        const p = e.evt.mouse.p;
        var inside = false;
        for (rects) |r| {
            if (r.contains(p)) inside = true;
        }
        if (!inside) return true;
    }
    return false;
}
