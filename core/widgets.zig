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

/// The menu chain, copied from dvui so a menu can be frosted and so its rows are the same rows
/// the command palette and the flyouts draw — see `widgets/menu/FloatingMenu.zig`'s header for
/// what differs and why all three had to come together.
pub const MenuWidget = @import("widgets/menu/Menu.zig");
pub const MenuItemWidget = @import("widgets/menu/MenuItem.zig");
pub const FloatingMenuWidget = @import("widgets/menu/FloatingMenu.zig");

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

pub fn floatingMenu(src: std.builtin.SourceLocation, init_opts: FloatingMenuWidget.InitOptions, opts: dvui.Options) *FloatingMenuWidget {
    var ret = dvui.widgetAlloc(FloatingMenuWidget);
    ret.init(src, init_opts, opts);
    return ret;
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
