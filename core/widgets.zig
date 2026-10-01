//! `core.widgets` — the widgets an app and a plugin both draw with.
//!
//! This is the shared floor of the UI. A `Split` is here rather than beside the layout because
//! the workbench draws document splits from inside a **dylib**, and the bottom panel draws the
//! same one from inside the app: a split implemented twice is a split that behaves two ways.
//! `Tabs` is here for the same reason.
//!
//! The divide this file sits on:
//!
//!   `editor/layout/`  the app's own shape — `Layout`, `Region`, the shipped presets. App
//!                     only: a plugin never declares a region, it fills one.
//!   `core.widgets`    what both sides draw with. No layout vocabulary, no plugin vocabulary.
//!   `fizzy.sdk`       the plugin contract — `Host`, `Surface`, `Plugin`. Draws nothing itself.
//!
//! Widgets are `init` + `deinit`, like dvui's own; the verb form (`split`, `reorder`,
//! `floatingWindow`) sits here in the namespace, the way `dvui.box` sits over `BoxWidget.init`.
const std = @import("std");
const dvui = @import("dvui");
const builtin = @import("builtin");
const icons = @import("icons");
const platform = @import("platform.zig");
const dialogs = @import("dialogs.zig");
const draw = @import("draw.zig");
const icon_tex = @import("gfx/icon.zig");

pub const CanvasWidget = @import("widgets/CanvasWidget.zig");
pub const ReorderWidget = @import("widgets/ReorderWidget.zig");
pub const FloatingWindowWidget = @import("widgets/FloatingWindowWidget.zig");
pub const TreeWidget = @import("widgets/TreeWidget.zig");
pub const TreeSelection = @import("widgets/TreeSelection.zig");
/// Local copies of upstream dvui's `DockingWidget` (+ its `DockLayout` tree) and `BlurBackdrop`,
/// taken at the current pin so the split-tree/blur work can be iterated here before anything is
/// proposed upstream. Keep the diff against `dvui-dev/src/{widgets/DockingWidget.zig,
/// widgets/DockingWidget/Layout.zig,BlurBackdrop.zig}` readable.
pub const DockingWidget = @import("widgets/DockingWidget.zig");
pub const DockLayout = DockingWidget.Layout;
pub const BlurBackdrop = @import("widgets/BlurBackdrop.zig");
pub const Popover = @import("widgets/Popover.zig");
pub const ContextWidget = @import("widgets/ContextWidget.zig");

/// The menu chain, copied from dvui so a menu can be frosted and so its rows are the same rows
/// the command palette and the flyouts draw — see `widgets/menu/FloatingMenu.zig`'s header for
/// what differs and why all three had to come together.
pub const MenuWidget = @import("widgets/menu/Menu.zig");
pub const MenuItemWidget = @import("widgets/menu/MenuItem.zig");
pub const FloatingMenuWidget = @import("widgets/menu/FloatingMenu.zig");
pub const PopupWidget = @import("widgets/menu/Popup.zig");

/// Points: the one size of a round button — a floating toggle, a place's corner grid, anything
/// round that is tapped or clicked. Big enough to hit with a finger, small enough not to crowd
/// what it sits over, so one size serves touch and mouse alike.
pub const round_button_size: f32 = 32;
/// A dropdown whose list is the menus' frosted surface — use this, not `dvui.DropdownWidget`.
pub const DropdownWidget = @import("widgets/Dropdown.zig");

/// `dvui.menu` / `dvui.menuItem` / `dvui.floatingMenu`, over the copies above.
pub fn menu(src: std.builtin.SourceLocation, dir: dvui.enums.Direction, opts: dvui.Options) *MenuWidget {
    var ret = dvui.widgetAlloc(MenuWidget);
    ret.init(src, .{ .dir = dir }, opts);
    return ret;
}

pub fn menuItem(src: std.builtin.SourceLocation, init_opts: MenuItemWidget.InitOptions, opts: dvui.Options) *MenuItemWidget {
    var ret = dvui.widgetAlloc(MenuItemWidget);
    ret.init(src, init_opts, opts);
    ret.processEvents();
    ret.drawBackground();
    return ret;
}

/// A right-click / touch-hold area over `init_opts.rect` — use this, not `dvui.context`: see
/// `ContextWidget`'s header for why a touch hold needs the copy.
pub fn context(src: std.builtin.SourceLocation, init_opts: ContextWidget.InitOptions, opts: dvui.Options) *ContextWidget {
    var ret = dvui.widgetAlloc(ContextWidget);
    ret.init(src, init_opts, opts);
    ret.processEvents();
    return ret;
}

pub fn floatingMenu(src: std.builtin.SourceLocation, init_opts: FloatingMenuWidget.InitOptions, opts: dvui.Options) *FloatingMenuWidget {
    var ret = dvui.widgetAlloc(FloatingMenuWidget);
    ret.init(src, init_opts, opts);
    return ret;
}

/// `dvui.tooltip` drawn as fizzy's floating surface (`dialogs.tooltipSurface`): a line of text
/// in a frosted, rounded, shadowed card like the dialogs and menus, rather than dvui's opaque box.
/// Same arguments; `opts` styles the text.
pub fn tooltip(src: std.builtin.SourceLocation, init_opts: dvui.FloatingTooltipWidget.InitOptions, comptime fmt: []const u8, fmt_args: anytype, opts: dvui.Options) void {
    var tt: dvui.FloatingTooltipWidget = undefined;
    const defaults: dvui.Options = .{ .role = .tooltip, .padding = dvui.Rect.all(6) };
    tt.init(src, init_opts, defaults.override(dialogs.tooltipOptions(0)).override(opts));
    defer tt.deinit();
    if (!tt.shown()) return;
    const prev_alpha = dialogs.tooltipBeginFor(&tt, 250_000);
    defer dvui.alphaSet(prev_alpha);
    var tl = dvui.textLayout(@src(), .{}, defaults.override(opts).override(.{ .background = false }).strip());
    tl.format(fmt, fmt_args, .{});
    tl.deinit();
}

/// `dvui.popup` on this module's menu chain, so it can be frosted — see `PopupWidget`.
pub fn popup(src: std.builtin.SourceLocation, init_opts: PopupWidget.InitOptions, opts: dvui.Options) ?*PopupWidget {
    var ret = dvui.widgetAlloc(PopupWidget);
    return ret.active(src, init_opts, opts);
}

/// The fills a menu row wears: nothing at rest, `core.dialogs`' hover wash under the pointer, and
/// the same rounded corners every flyout row has. Resting at the hover colour with zero alpha
/// rather than at a different colour, because dvui lerps between the two and a rest fill of
/// another hue made every hover cross through a third one on its way.
pub fn menuRowOptions(opts: dvui.Options) dvui.Options {
    const hover = dialogs.rowHover();
    return opts.override(.{
        .corners = dialogs.rowCorners(),
        .color_fill = .{ .color = hover.opacity(0) },
        .color_fill_hover = .{ .color = hover },
        // The label does not change colour under the pointer: a row that both lights up and
        // rewrites its text reads as two things happening.
        .color_text_hover = opts.color_text orelse .{ .color = dvui.themeGet().color(.window, .text) },
    });
}

pub const MenuRowOptions = struct {
    /// TVG bytes for the icon column. The column is kept either way, so rows with and without an
    /// icon start their labels at the same x.
    icon: ?[]const u8 = null,
    /// The shortcut drawn against the right edge. Empty draws none.
    keybind: dvui.enums.Keybind = .{},
    /// False greys the row and swallows its click — dvui's menu item has no disabled state of its
    /// own, so a greyed row was otherwise still clickable.
    enabled: bool = true,
    submenu: bool = false,
    id_extra: usize = 0,
};

/// One menu row, the same everywhere: an icon column, the label straight after it, and the
/// shortcut against the right edge — how macOS lays out a menu. The menu bar, a plugin's row in
/// it, the file tree's and tab strip's context menus, and a text field's all draw this, so no
/// two menus in the app can disagree about what a row is.
///
/// Returns the rect a submenu would open from, or null when not activated.
pub fn menuRow(src: std.builtin.SourceLocation, label: []const u8, opts: MenuRowOptions) ?dvui.Rect.Natural {
    var mi = menuItem(src, .{ .submenu = opts.submenu }, menuRowOptions(.{ .expand = .horizontal, .id_extra = opts.id_extra }));
    const ret: ?dvui.Rect.Natural = if (opts.enabled) mi.activeRect() else null;

    // Closed before `mi`: it is `mi`'s child, and dvui's widget stack is strictly LIFO.
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = opts.id_extra });
    draw.menuRowIcon(opts.icon, dvui.themeGet().color(.window, .text), opts.enabled, opts.id_extra);
    draw.labelWithKeybind(label, opts.keybind, opts.enabled, .{}, .{ .id_extra = opts.id_extra });
    // A submenu's row ends in a chevron where a command's shortcut would be — the same right-hand
    // column, so it reads as "more this way" rather than as a row with a stray mark after it.
    if (opts.submenu) {
        const muted = dvui.themeGet().color(.control, .text).opacity(0.5);
        icon_tex.icon(@src(), "submenu_chevron", icons.tvg.lucide.@"chevron-right", .{
            .stroke_color = .{ .color = muted },
        }, .{ .gravity_y = 0.5, .id_extra = opts.id_extra, .min_size_content = .{ .w = 12, .h = 12 } });
    }
    row.deinit();

    mi.deinit();
    return ret;
}

/// A row with a label and nothing else — `menuRow` with no icon or shortcut. Kept for the callers
/// that only name a verb; it is the same row, so it sits in the same column as its neighbours.
pub fn menuItemLabel(
    src: std.builtin.SourceLocation,
    label_str: []const u8,
    init_opts: MenuItemWidget.InitOptions,
    opts: dvui.Options,
) ?dvui.Rect.Natural {
    return menuRow(src, label_str, .{ .submenu = init_opts.submenu, .id_extra = opts.id_extra orelse 0 });
}

/// The filter box every list in the app wears: a search glyph, then a borderless field with a
/// field's Copy/Paste menu. One control, so the file tree, the settings, the plugin store and the
/// region picker read as the same thing and cannot drift apart. Returns the text, which borrows
/// the field's buffer — read it this frame.
pub fn filterRow(src: std.builtin.SourceLocation, placeholder: []const u8, opts: dvui.Options) []const u8 {
    var row = dvui.box(src, .{ .dir = .horizontal }, (dvui.Options{ .expand = .horizontal }).override(opts));
    defer row.deinit();
    icon_tex.icon(
        @src(),
        "FilterIcon",
        icons.tvg.lucide.search,
        .{ .stroke_color = .{ .color = dvui.themeGet().color(.window, .text) } },
        .{ .gravity_y = 0.5, .padding = dvui.Rect.all(0) },
    );
    const entry = dvui.textEntry(@src(), .{ .placeholder = placeholder }, .{
        .expand = .horizontal,
        .background = false,
    });
    defer entry.deinit();
    _ = textEntryMenu(entry);
    return entry.getText();
}

/// A context menu's surface, opened at the point the pointer was pressed. Every right-click
/// menu in the app goes through here: the file tree's rows, the docking widget's tabs, and
/// whatever a plugin contributes into one — so "what a menu looks like" is answered once,
/// beside the menu bar's dropdown rather than near it.
/// Copy and Paste on a right-click in a text field. Call after drawing the entry, before its
/// `deinit` — the menu acts on this widget directly.
///
/// Directly, not through `fizzy.copy`/`fizzy.paste`: those pick their target by asking what has
/// focus, and opening a menu moves focus *to the menu*. A field's own menu already knows which
/// field it belongs to, and asking focus at the one moment focus is elsewhere is how a paste
/// meant for a search box lands in the document behind it. (The text editor's document menu is
/// the other case: there the active document is still the editor while its menu is open, so it
/// does run the commands, and they route to it.)
///
/// Returns true when it changed the text — a paste — because the caller may need to treat that as
/// an edit. A field that commits only while it has focus, or resyncs from its stored value when
/// it does not, would otherwise drop the paste: it happened while the *menu* had focus. Focus goes
/// back to the field afterwards, so the next keystroke lands where the paste did.
pub fn textEntryMenu(te: *dvui.TextEntryWidget) bool {
    var right_click = context(@src(), .{ .rect = te.data().borderRectScale().r }, .{ .id_extra = te.data().id.asUsize() });
    defer right_click.deinit();
    const point = right_click.activePoint() orelse return false;

    var menu_popup = contextMenu(@src(), point, .{});
    defer menu_popup.deinit();
    // With the chords the field itself answers to: ⌘C in a focused field does exactly what this
    // row does, so showing it is the truth, not decoration.
    const keybinds = &dvui.currentWindow().keybinds;
    if (menuRow(@src(), "Copy", .{ .icon = icons.tvg.lucide.copy, .keybind = keybinds.get("copy") orelse .{} }) != null) {
        te.copy();
        menu_popup.close();
    }
    if (menuRow(@src(), "Paste", .{ .icon = icons.tvg.lucide.@"clipboard-paste", .keybind = keybinds.get("paste") orelse .{} }) != null) {
        te.paste();
        menu_popup.close();
        dvui.focusWidget(te.data().id, null, null);
        return true;
    }
    return false;
}

pub fn contextMenu(src: std.builtin.SourceLocation, at: dvui.Point.Natural, opts: dvui.Options) *FloatingMenuWidget {
    // `.popup`, not the `.menu` default: a right-click menu is not part of a menubar chain, and
    // the difference that matters is that a popup closes when you click outside it. The default
    // left a context menu standing while the click that should have dismissed it went somewhere
    // else — which is not a decision any caller should be making separately.
    // Frosted like the menu bar's dropdowns and every other floating surface: without the frost
    // and the translucent fill a right-click menu drew as a bare opaque dvui panel.
    return floatingMenu(src, .{
        .from = dvui.Rect.Natural.fromPoint(at),
        .style = .popup,
        .frost = menuFrost(),
    }, menuSurfaceOptions().override(opts));
}

/// The blur behind a menu popup — `core.dialogs`' frost for every floating surface, as a
/// `BlurBackdrop.Pane`. Null when the style has the blur off; the panel's fill then stands alone.
pub fn menuFrost() ?BlurBackdrop.Pane {
    const f = dialogs.dialogFrost() orelse return null;
    return .{ .radius = f.radius, .refresh_ms = f.refresh_ms, .tint = f.tint, .mix = f.mix, .lift = f.lift, .detail = f.detail, .refraction = f.refraction };
}

/// A menu popup's surface: `core.dialogs`' fill, corners, padding and shadow, no border — the
/// menu bar's dropdowns, context menus and the rest wear the same one.
pub fn menuSurfaceOptions() dvui.Options {
    return .{
        .background = true,
        .color_fill = .{ .color = dialogs.dialogFill() },
        .border = .all(0),
        .corners = dialogs.surfaceCorners(),
        .padding = dialogs.surface_padding,
        .box_shadow = dialogs.surfaceShadow(),
    };
}
/// Verb form of `DockingWidget`, same shape as `dvui.dockspace`.
pub const dockspace = DockingWidget.dockspace;

/// Reorderable tab strip shared by fizzy's bottom panel and the workbench's document tabs.
/// The draggable split between two regions. Lives here rather than beside the layout because the
/// workbench draws document splits from inside a dylib and must reach the same one — the same
/// reason `Tabs` is here. A split implemented twice is a split that behaves two ways.
pub const Split = @import("widgets/Split.zig");
/// Open a split — the verb form of `Split.init`, so a caller that never names the type reads
/// the same as it does for `dvui.box`.
pub const split = Split.init;
pub const Tabs = @import("widgets/Tabs.zig");
/// The drop targets over a place while something is dragged onto it — see its file.
pub const DropZones = @import("widgets/DropZones.zig");

/// Side of the square every glyph in a tree row occupies — the expand/collapse caret, a folder
/// or file-type icon, a plugin's own icon, the app logo, or a letter standing in for a missing
/// icon.
///
/// Derived from the body font so it tracks the user's font-size setting instead of pinning rows
/// to a fixed pixel height, and a little *under* the text height so glyphs read as sitting beside
/// the label rather than looming over it.
pub fn treeRowGlyphSize() dvui.Size {
    const h = @round(dvui.Font.theme(.body).textHeight() * 0.9);
    return .{ .w = h, .h = h };
}

/// A tree row's expand caret, in its own glyph slot: down when `expanded`, right when not.
///
/// The two arrows are different shapes (the down one wide, the right one tall) and the icon fits
/// itself to the slot by the proportions dvui remembers for its id. Drawn under one id, a
/// just-collapsed caret was fitted by the down arrow's proportions and stayed stretched until
/// something redrew the row, so each direction has an id of its own.
pub fn treeCaret(src: std.builtin.SourceLocation, expanded: bool, color: dvui.Color) void {
    var slot = treeRowGlyph(src, .{});
    defer slot.deinit();
    _ = icon_tex.icon(
        @src(),
        "TreeCaret",
        if (expanded) icons.tvg.entypo.@"down-open" else icons.tvg.entypo.@"right-open",
        .{ .fill_color = .{ .color = color }, .stroke_color = .{ .color = color } },
        treeRowIconOptions(.{ .id_extra = @intFromBool(expanded) }),
    );
}

/// Options for fizzy's own icons/images drawn inside a `treeRowGlyph` slot — the same
/// `expand = .ratio` fit asked of plugin icons, centred in the slot.
pub fn treeRowIconOptions(over: dvui.Options) dvui.Options {
    const defaults: dvui.Options = .{
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .expand = .ratio,
        .padding = dvui.Rect.all(0),
        .margin = dvui.Rect.all(0),
        .background = false,
    };
    return defaults.override(over);
}

/// Reserve one tree-row glyph slot: a box of exactly `treeRowGlyphSize()`, into which the caller
/// draws a caret, an icon, an image, or a letter.
///
/// **This is the contract for plugin-drawn icons** (`Host.registerFileIcon` /
/// `registerPluginIcon`). Fizzy reserves the rect; the plugin draws into it with
/// `expand = .ratio`, which fits its artwork to whatever the row can spare while preserving the
/// aspect ratio. Both halves are needed: a plugin that draws at a hard-coded size ignores the
/// slot and knocks the row out of line, and a slot with no fixed size lets each icon dictate its
/// own row height. `min` and `max` are both set so the slot is a genuinely fixed rect rather than
/// a floor that any large icon can push open.
///
/// Caller deinits, as with `dvui.box`.
pub fn treeRowGlyph(src: std.builtin.SourceLocation, opts: dvui.Options) *dvui.BoxWidget {
    const size = treeRowGlyphSize();
    const defaults: dvui.Options = .{
        .gravity_y = 0.5,
        .min_size_content = size,
        .max_size_content = .size(size),
        .expand = .none,
        .background = false,
        .padding = dvui.Rect.all(0),
        .margin = dvui.Rect.all(0),
    };
    return dvui.box(src, .{ .dir = .horizontal }, defaults.override(opts));
}

/// Shade `area`'s edges where its content continues past them (`draw.drawScrollEdgeShadows`),
/// over its viewport — the scroll container, bars excluded. Call after the content, just before
/// the area's `deinit`: `defer core.widgets.scrollShadows(scroll);` written after
/// `defer scroll.deinit();` runs first. Every scroll area that does not hint its edges some
/// other way takes this, so none of them shows content cut off at a bare edge.
pub fn scrollShadows(area: *dvui.ScrollAreaWidget) void {
    const rs = if (area.scroll) |*s| s.data().borderRectScale() else area.data().contentRectScale();
    draw.drawScrollEdgeShadows(rs, rs, area.si, .{});
}

pub fn floatingWindow(src: std.builtin.SourceLocation, floating_opts: FloatingWindowWidget.InitOptions, opts: dvui.Options) *FloatingWindowWidget {
    var ret = dvui.widgetAlloc(FloatingWindowWidget);
    ret.init(src, floating_opts, opts);
    ret.processEventsBefore();
    ret.drawBackground();
    return ret;
}

pub fn hovered(wd: *dvui.WidgetData) bool {
    for (dvui.events()) |*event| {
        if (!dvui.eventMatchSimple(event, wd)) {
            continue;
        }

        switch (event.evt) {
            .mouse => |mouse| {
                return wd.borderRectScale().r.contains(mouse.p);
            },
            else => {},
        }
    }

    return false;
}

/// Rest fill for a control that should be invisible until hovered.
///
/// `Color.transparent` is transparent *black*, and dvui's hover fade lerps straight (non
/// premultiplied) RGBA, so a `.transparent` -> `hover` fade dips through a dark wash before it
/// reaches the hover tint. That is invisible on near-black themes and jarring on saturated ones
/// (Strawberry). Reusing the hover colour's RGB at zero alpha makes the fade ramp alpha only.
pub fn hoverRestFill(hover: dvui.Color) dvui.Color {
    return hover.opacity(0);
}

pub fn reorder(src: std.builtin.SourceLocation, init_opts: ReorderWidget.InitOptions, opts: dvui.Options) *ReorderWidget {
    var ret = dvui.widgetAlloc(ReorderWidget);
    ret.init(src, init_opts, opts);
    ret.processEvents();
    return ret;
}

/// Padding around the close / dirty / save indicator in workspace tabs (fixed every frame).
pub const tab_status_inset = dvui.Rect{ .x = 4, .y = 2, .w = 4, .h = 2 };

/// Workspace tab close control: fixed size, no margin/shadow (unlike dialog header close).
pub fn tabCloseButtonOptions(over: dvui.Options) dvui.Options {
    return dialogs.windowHeaderCloseButtonOptions(over.override(.{
        .margin = dvui.Rect.all(0),
        .padding = dvui.Rect.all(0),
        .border = dvui.Rect.all(0),
        .corners = dvui.CornerRect.all(1000),
        .box_shadow = null,
        .background = false,
        .color_fill = .transparent,
        .color_fill_hover = .transparent,
        .color_fill_press = .transparent,
        .ninepatch_fill = &dvui.Ninepatch.none,
        .ninepatch_hover = &dvui.Ninepatch.none,
        .ninepatch_press = &dvui.Ninepatch.none,
    }));
}
