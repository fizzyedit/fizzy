const std = @import("std");
const fizzy = @import("../fizzy.zig");
const dvui = @import("dvui");
const Constants = @import("Constants.zig");
const Editor = fizzy.Editor;
const settings = fizzy.settings;
const builtin = @import("builtin");
const model = @import("menu_model.zig");
const widgets = fizzy.core.widgets;

pub var mouse_distance: f32 = std.math.floatMax(f32);

/// TEMPORARY debug knob: draw the in-app dvui menu bar on macOS too, alongside the native
/// `NSMenu`, so the two can be compared side by side (e.g. Edit menu contents). Not persisted —
/// resets to off every launch. Toggled from View > "Show DVUI Menu (macOS)"; remove once the
/// native/dvui menu comparison this exists for is done.
pub var debug_force_on_macos: bool = false;

pub fn draw(editor: *Editor) !dvui.App.Result {
    const bg_box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false, .color_fill = .{ .color = dvui.themeGet().color(.control, .fill) } });
    defer bg_box.deinit();

    var m = widgets.menu(@src(), .horizontal, .{});
    defer m.deinit();

    // The menu's own palette, for as long as it draws. Two overrides, both about the same thing:
    // a menu row should read as "the pointer is here", not as "this is selected".
    //
    //   * `highlight.fill` is the accent green, which dvui paints under an open submenu's title.
    //   * `focus` is that same green, stroked 2px around whichever row has keyboard focus — and a
    //     menu leaves focus on the row the pointer last crossed, so with a mouse it was a green
    //     ring hopping down the menu ahead of the hover wash.
    //
    // The wash they both become is the one the flyout rows and the command palette use.
    const prev_highlight = dvui.themeGet().highlight;
    const prev_focus = dvui.themeGet().focus;
    var theme = dvui.themeGet();
    const wash = chrome.rowHover();
    theme.highlight.fill = wash;
    theme.focus = wash;
    dvui.themeSet(theme);
    defer {
        theme.highlight = prev_highlight;
        theme.focus = prev_focus;
        dvui.themeSet(theme);
    }

    // Fizzy owns only the menu bar container + theme; the top-level menus are
    // plugin (and fizzy built-in) contributions, drawn in registration order.
    for (editor.app.host.menus.items) |*menu| {
        if (menu.hidden) continue;
        menu.draw(menu.ctx) catch |err| {
            dvui.log.err("Menu contribution failed: {any}", .{err});
        };
    }

    return .ok;
}

// ---- chrome: a menu popup is the same surface as a flyout or a dialog ------------------------

/// The one description of a floating surface and its rows (`core.dialogs`): the same fill,
/// corners, padding, shadow and hover the command palette, the dialogs and the flyouts use.
const chrome = fizzy.core.dialogs;

/// One menu dropdown, drawn like every other floating surface in fizzy: frosted, rounded,
/// shadowed, no border — `core.dialogs`' description of a surface, the same one the command
/// palette, the dialogs and the flyouts are built from.
///
/// Through `core.widgets`' menu chain rather than dvui's: a frosted surface has to paint shadow,
/// then blur, then its own translucent fill, and dvui's floating menu paints its background
/// inside `init` where nothing outside can get in front of it. See
/// `core/widgets/menu/FloatingMenu.zig`.
fn menuPopup(src: std.builtin.SourceLocation, from: dvui.Rect.Natural, id_extra: usize) *widgets.FloatingMenuWidget {
    return widgets.floatingMenu(src, .{ .from = from, .frost = frostPane() }, .{
        .id_extra = id_extra,
        .background = true,
        .color_fill = .{ .color = chrome.dialogFill() },
        .border = .all(0),
        .corners = chrome.surface_corners,
        .padding = chrome.surface_padding,
        .box_shadow = chrome.surfaceShadow(),
    });
}

/// The blur behind a menu, as `core.dialogs` describes it for every floating surface. Null when
/// the style has the blur off, which the panel then simply draws without.
fn frostPane() ?fizzy.core.widgets.BlurBackdrop.Pane {
    const f = chrome.dialogFrost() orelse return null;
    return .{ .radius = f.radius, .refresh_ms = f.refresh_ms, .tint = f.tint, .mix = f.mix, .lift = f.lift };
}

/// A menu row, drawn the way the command palette draws its rows: `row_corners`, and `rowHover`
/// under the pointer.
///
/// The rest fill is that same hover colour at zero alpha, not a transparent background colour.
/// dvui fades a row by lerping `color_fill` → `color_fill_hover` across all four channels, so
/// starting from a different hue made the fade travel through it — a row darkening on the way
/// in, and again on the way out after the pointer had left. From the hover colour itself, the
/// fade is alpha alone.
///
/// It also stops the row the pointer *last* crossed from sitting there filled: dvui paints a
/// menu row when it is hovered **or focused**, and a menu leaves focus behind it.
pub fn rowOptions(opts: dvui.Options) dvui.Options {
    const hover = chrome.rowHover();
    return opts.override(.{
        .corners = chrome.row_corners,
        .color_fill = .{ .color = hover.opacity(0) },
        .color_fill_hover = .{ .color = hover },
        // The label does not change colour under the pointer: a row that both lights up and
        // rewrites its text reads as two things happening.
        .color_text_hover = opts.color_text orelse .{ .color = dvui.themeGet().color(.window, .text) },
    });
}

/// File menu (workbench contribution).
/// Run the command a menu item stands for.
///
/// Every item in both menu bars names a command and does nothing else.
fn run(id: []const u8) void {
    fizzy.editor().app.host.runCommand(id) catch |err| {
        dvui.log.err("menu command '{s}' failed: {s}", .{ id, @errorName(err) });
    };
}

/// Draw one top-level menu from `menu_model`. Registered once per `menu_model.menu_bar` entry
/// with the `Submenu` itself as `ctx`, so there is no per-menu function here to fall out of step
/// with the macOS builder walking the same tree.
pub fn drawModelMenu(ctx: ?*anyopaque) anyerror!void {
    const sub: *const model.Submenu = @ptrCast(@alignCast(ctx orelse return));
    const editor = fizzy.editor();

    // Every top-level menu (File/Edit/View/Help) is drawn through this same function at this
    // same `@src()`s, so without a differentiator dvui sees sibling widgets — the button, the
    // open-animation, and the floating menu itself — all asking for the identical id (hit on
    // Windows, where this bar actually draws; macOS uses the native menu instead — see
    // `Editor.zig`'s "menu is handled natively" check). It surfaces specifically while the mouse
    // transitions from one open top-level menu to the next, because that's the one moment two of
    // these subtrees are both live in the same frame (the old menu closing/fading, the new one
    // opening). `sub`'s address is stable and distinct per entry in `menu_model.menu_bar`, so
    // it's a cheap unique id_extra for all three without threading an index through the fixed
    // `MenuContribution.draw` ABI.
    const extra = @intFromPtr(sub);
    if (menuItem(@src(), sub.title, .{ .submenu = true }, .{
        .expand = .horizontal,
        .id_extra = extra,
        .color_text = .{ .color = dvui.themeGet().color(.control, .text) },
    })) |r| {
        const fw = menuPopup(@src(), r, extra);
        defer fw.deinit();

        for (sub.items, 0..) |item, i| {
            try drawModelItem(editor, item, i, fw);
        }
    }
}

fn drawModelItem(
    editor: *Editor,
    item: model.Item,
    id_extra: usize,
    fw: *widgets.FloatingMenuWidget,
) !void {
    switch (item) {
        .separator => _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = id_extra }),

        .plugin_section => |parent| try drawMenuSections(parent),

        .recent_folders => try drawRecentFolders(editor, id_extra),

        .open_actions => {
            const host = &editor.app.host;
            for (host.open_actions.items) |a| {
                if (!host.openActionShown(a)) continue;
                if (host.drawMenuItem(a.title, a.command)) {
                    fw.close();
                    host.runCommand(a.command) catch |err| dvui.log.warn("open action {s}: {t}", .{ a.id, err });
                }
            }
        },

        .submenu => |nested| {
            // No nested submenus in the bar today; the model allows them, so handle rather
            // than silently drop.
            if (menuItemWithChevron(@src(), nested.title, .{ .submenu = true }, .{
                .expand = .horizontal,
                .id_extra = id_extra,
                .color_text = .{ .color = dvui.themeGet().color(.window, .text) },
            })) |r| {
                const nested_fw = menuPopup(@src(), r, id_extra);
                defer nested_fw.deinit();
                for (nested.items, 0..) |nested_item, j| {
                    try drawModelItem(editor, nested_item, j, nested_fw);
                }
            }
        },

        .command => |c| {
            if (c.visible) |f| {
                if (!f(editor)) return;
            }
            const enabled = if (c.enabled) |f| f(editor) else true;
            const hotkey = hotkeyFor(editor, c.id);
            // The icon lives once, on the registered `Command` (`sdk.Command.icon`) — every
            // fizzy command is registered there too (`Keybinds.registerCommands`), so this and
            // `Editor.fizzyDrawMenuItem` (the plugin-section row equivalent) resolve it the same
            // way instead of each menu item duplicating an icon assignment of its own.
            const icon: ?[]const u8 = if (editor.app.host.command(c.id)) |cmd| cmd.icon else null;

            if (menuItemWithHotkey(@src(), c.title.resolve(editor), icon, hotkey, enabled, .{}, .{
                .expand = .horizontal,
                .id_extra = id_extra,
                .color_text = .{ .color = dvui.themeGet().color(.window, .text) },
            }) != null) {
                run(c.id);
                fw.close();
            }
        },
    }
}

/// The chord shown beside a row, straight from the keymap `Keybinds.tick` dispatches out of.
///
/// From the keymap, not the command's dvui *bind name*: a command with no dvui bind
/// (`fizzy.quickOpen`) or a plugin command the user gave a chord has an accelerator too.
fn hotkeyFor(editor: *Editor, command_id: []const u8) dvui.enums.Keybind {
    return fizzy.Editor.Keybinds.menuKeybindFor(editor, command_id);
}

fn drawRecentFolders(editor: *Editor, id_extra: usize) !void {
    if (editor.app.recents.folders.items.len == 0) return;

    if (menuItemWithChevron(@src(), "Recent Folders", .{ .submenu = true }, .{
        .expand = .horizontal,
        .id_extra = id_extra,
        .color_text = .{ .color = dvui.themeGet().color(.window, .text) },
    })) |recents_item| {
        var recents_anim = dvui.animate(@src(), .{
            .kind = .alpha,
            .duration = 250_000,
        }, .{ .expand = .both });
        defer recents_anim.deinit();

        const recents_fw = menuPopup(@src(), recents_item, id_extra);
        defer recents_fw.deinit();

        var vert_box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .none });
        defer vert_box.deinit();

        var i: usize = editor.app.recents.folders.items.len;
        while (i > 0) : (i -= 1) {
            const folder = editor.app.recents.folders.items[i - 1];
            if (menuItem(@src(), folder, .{}, .{
                .expand = .horizontal,
                .font = dvui.Font.theme(.mono),
                .id_extra = i,
                .margin = dvui.Rect.all(1),
                .padding = dvui.Rect.all(2),
            })) |_| {
                try editor.setProjectFolder(folder);
            }
        }
    }
}

/// A menu leaf with a trailing keybind hint. `enabled = false` both greys the label (see
/// `labelWithKeybind`) *and* swallows the click here — dvui's `MenuItemWidget` has no built-in
/// disabled state, so without this a "greyed out" item was still fully clickable and silently
/// ran its action.
///
/// `icon` is optional TVG bytes (`menu_model.CommandItem.icon`) drawn in a fixed
/// `treeRowGlyph`-sized slot ahead of the label — reserved even when a particular row has no
/// icon, so rows with and without one still line up in the same column rather than the label
/// shifting left to fill the gap.
pub fn menuItemWithHotkey(src: std.builtin.SourceLocation, label_str: []const u8, icon: ?[]const u8, hotkey: dvui.enums.Keybind, enabled: bool, init_opts: widgets.MenuItemWidget.InitOptions, opts: dvui.Options) ?dvui.Rect.Natural {
    var mi = widgets.menuItem(src, init_opts, rowOptions(opts));

    var ret: ?dvui.Rect.Natural = null;
    if (enabled) {
        if (mi.activeRect()) |r| {
            ret = r;
        }
    }

    // Deinit order matters to dvui's widget stack (strictly LIFO, parent last): `row` is a child
    // of `mi`, so it must close before `mi.deinit()` below, not after — a `defer row.deinit()`
    // here would fire at function exit, *after* the explicit `mi.deinit()` call, closing the
    // parent before its child and panicking ("widget is not closed within its parent").
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = opts.id_extra orelse 0 });
    fizzy.core.draw.menuRowIcon(icon, if (opts.color_text) |c| c.toColor() else dvui.themeGet().color(.window, .text), enabled, opts.id_extra orelse 0);
    fizzy.core.draw.labelWithKeybind(label_str, hotkey, enabled, opts, opts);
    row.deinit();

    mi.deinit();

    return ret;
}

pub fn menuItem(src: std.builtin.SourceLocation, label_str: []const u8, init_opts: widgets.MenuItemWidget.InitOptions, opts: dvui.Options) ?dvui.Rect.Natural {
    var mi = widgets.menuItem(src, init_opts, rowOptions(opts));

    var ret: ?dvui.Rect.Natural = null;
    if (mi.activeRect()) |r| {
        ret = r;
    }

    var label_opts = opts;
    label_opts.margin = dvui.Rect.all(0);
    label_opts.padding = dvui.Rect.all(0);

    if (fizzy.core.widgets.hovered(mi.data())) {
        label_opts.color_text = .{ .color = dvui.themeGet().color(.window, .text) };
    }

    dvui.labelNoFmt(@src(), label_str, .{}, label_opts);

    // Register top-level menu items as interactive rects on Windows so clicks land on the item
    // instead of dragging the window. We only push items that overlap the title bar strip — submenu
    // items rendered inside floatingMenu are below the strip and don't need registering.
    if (builtin.os.tag == .windows) {
        const r = mi.data().rectScale().r;
        const strip_h = (Constants.titlebar_top_buffer + Constants.titlebar_height) * dvui.windowNaturalScale();
        if (r.y < strip_h) fizzy.backend.pushTitleBarInteractiveRect(r);
    }

    mi.deinit();

    return ret;
}

pub fn menuItemWithChevron(src: std.builtin.SourceLocation, label_str: []const u8, init_opts: widgets.MenuItemWidget.InitOptions, opts: dvui.Options) ?dvui.Rect.Natural {
    var mi = widgets.menuItem(src, init_opts, rowOptions(opts));

    var ret: ?dvui.Rect.Natural = null;
    if (mi.activeRect()) |r| {
        ret = r;
    }

    var label_opts = opts;
    label_opts.margin = dvui.Rect.all(0);
    label_opts.padding = dvui.Rect.all(0);

    if (fizzy.core.widgets.hovered(mi.data())) {
        label_opts.color_text = .{ .color = dvui.themeGet().color(.window, .text) };
    }

    dvui.labelNoFmt(@src(), label_str, .{}, label_opts);

    fizzy.core.icon.icon(@src(), "chevron_right", dvui.entypo.chevron_small_right, .{
        .stroke_color = .{ .color = dvui.themeGet().color(.control, .text).opacity(0.5) },
        .fill_color = .{ .color = dvui.themeGet().color(.control, .text).opacity(0.5) },
    }, .{
        .expand = .none,
        .gravity_x = 1.0,
        .gravity_y = 0.5,
        .margin = dvui.Rect.all(0),
        .padding = dvui.Rect.all(0),
    });

    mi.deinit();

    return ret;
}

/// Draw registered menu sections for an open parent menu.
///
/// Matches through `menu_model.menuMatches` rather than a plain `eql`, so a plugin section
/// registered under one of a menu's legacy alias ids (e.g. `"workbench.menu.file"`, still a
/// published contract per `Submenu.aliases`'s doc comment) is found here too. The native macOS
/// builder (`backend_native.zig`'s `resolveBuiltinNativeMenu`) already resolved aliases for its
/// own leaf items.
///
/// Draws a single separator ahead of the whole group, not one per section (or per row within a
/// section — `Editor.fizzyDrawMenuItem`, the widget every section's `draw` goes through, no
/// longer draws its own): now that a section draws its row(s) unconditionally rather than
/// hiding them for the wrong document (see `Editor.fizzyDrawMenuItem`'s doc comment), the Edit
/// menu can carry three of these at once (pixi's Transform, pixi's Grid Layout, text's Format
/// Document), and a separator before each made every greyed-out row look like its own group.
pub fn drawMenuSections(parent_menu_id: []const u8) !void {
    const sub = model.submenuFor(parent_menu_id) orelse return;
    var drew_separator = false;
    for (fizzy.editor().app.host.menu_sections.items) |*section| {
        if (section.hidden) continue;
        if (!model.menuMatches(sub, section.parent_menu_id)) continue;
        if (!drew_separator) {
            _ = dvui.separator(@src(), .{ .expand = .horizontal });
            drew_separator = true;
        }
        section.draw(section.ctx) catch |err| {
            dvui.log.err("Menu section '{s}' failed: {any}", .{ section.id, err });
        };
    }
}
