const std = @import("std");
const fizzy = @import("../fizzy.zig");
const dvui = @import("dvui");
const Constants = @import("Constants.zig");
const Editor = fizzy.Editor;
const settings = fizzy.settings;
const builtin = @import("builtin");
const model = @import("menu_model.zig");

pub var mouse_distance: f32 = std.math.floatMax(f32);

pub fn draw() !dvui.App.Result {
    const bg_box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = false, .color_fill = dvui.themeGet().color(.control, .fill) });
    defer bg_box.deinit();

    var m = dvui.menu(@src(), .horizontal, .{});
    defer m.deinit();

    const current_highlight_style = dvui.themeGet().highlight;
    var theme = dvui.themeGet();
    theme.highlight.fill = theme.color(.control, .fill_hover);
    dvui.themeSet(theme);
    defer {
        theme.highlight = current_highlight_style;
        dvui.themeSet(theme);
    }

    // The shell owns only the menu bar container + theme; the top-level menus are
    // plugin (and shell built-in) contributions, drawn in registration order.
    for (fizzy.editor.host.menus.items) |*menu| {
        if (menu.hidden) continue;
        menu.draw(menu.ctx) catch |err| {
            dvui.log.err("Menu contribution failed: {any}", .{err});
        };
    }

    return .ok;
}

/// File menu (workbench contribution).
/// Run the command a menu item stands for.
///
/// Every item in both menu bars names a command and does nothing else. Before this, each item's
/// action was written out here *and* in the macOS menu path *and* as the command body in
/// `Keybinds` — three copies that had already drifted apart.
fn run(id: []const u8) void {
    fizzy.editor.host.runCommand(id) catch |err| {
        dvui.log.err("menu command '{s}' failed: {s}", .{ id, @errorName(err) });
    };
}

/// Draw one top-level menu from `menu_model`. Registered once per `menu_model.menu_bar` entry
/// with the `Submenu` itself as `ctx`, so there is no per-menu function here to fall out of step
/// with the macOS builder walking the same tree.
pub fn drawModelMenu(ctx: ?*anyopaque) anyerror!void {
    const sub: *const model.Submenu = @ptrCast(@alignCast(ctx orelse return));
    const editor = fizzy.editor;

    if (menuItem(@src(), sub.title, .{ .submenu = true }, .{
        .expand = .horizontal,
        .color_text = dvui.themeGet().color(.control, .text),
    })) |r| {
        var animator = dvui.animate(@src(), .{
            .kind = .alpha,
            .duration = 250_000,
        }, .{
            .expand = .both,
        });
        defer animator.deinit();

        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
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
    fw: *dvui.FloatingMenuWidget,
) !void {
    switch (item) {
        .separator => _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = id_extra }),

        .plugin_section => |parent| try drawMenuSections(parent),

        .recent_folders => try drawRecentFolders(editor, id_extra),

        .submenu => |nested| {
            // No nested submenus in the bar today; the model allows them, so handle rather
            // than silently drop.
            if (menuItemWithChevron(@src(), nested.title, .{ .submenu = true }, .{
                .expand = .horizontal,
                .id_extra = id_extra,
                .color_text = dvui.themeGet().color(.window, .text),
            })) |r| {
                var nested_fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
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

            if (menuItemWithHotkey(@src(), c.title.resolve(editor), hotkey, enabled, .{}, .{
                .expand = .horizontal,
                .id_extra = id_extra,
                .color_text = dvui.themeGet().color(.window, .text),
            }) != null) {
                run(c.id);
                fw.close();
            }
        },
    }
}

/// The chord shown beside a row, straight from the keymap `Keybinds.tick` dispatches out of.
///
/// This used to go via the command's dvui *bind name* (`dvui.Window.keybinds`), which only
/// worked for the subset of commands that have one. Anything bound purely through the keymap —
/// a command with no dvui bind (`fizzy.quickOpen`), or any plugin command the user gave a chord
/// in the Keyboard Shortcuts pane — resolved to nothing and drew a blank accelerator, even
/// though the chord worked. Asking the keymap directly is one lookup for every command.
fn hotkeyFor(editor: *Editor, command_id: []const u8) dvui.enums.Keybind {
    return fizzy.Editor.Keybinds.menuKeybindFor(editor, command_id);
}

fn drawRecentFolders(editor: *Editor, id_extra: usize) !void {
    if (editor.recents.folders.items.len == 0) return;

    if (menuItemWithChevron(@src(), "Recent Folders", .{ .submenu = true }, .{
        .expand = .horizontal,
        .id_extra = id_extra,
        .color_text = dvui.themeGet().color(.window, .text),
    })) |recents_item| {
        var recents_anim = dvui.animate(@src(), .{
            .kind = .alpha,
            .duration = 250_000,
        }, .{ .expand = .both });
        defer recents_anim.deinit();

        var recents_fw = dvui.floatingMenu(@src(), .{ .from = recents_item }, .{});
        defer recents_fw.deinit();

        var vert_box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .none });
        defer vert_box.deinit();

        var i: usize = editor.recents.folders.items.len;
        while (i > 0) : (i -= 1) {
            const folder = editor.recents.folders.items[i - 1];
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
pub fn menuItemWithHotkey(src: std.builtin.SourceLocation, label_str: []const u8, hotkey: dvui.enums.Keybind, enabled: bool, init_opts: dvui.MenuItemWidget.InitOptions, opts: dvui.Options) ?dvui.Rect.Natural {
    var mi = dvui.menuItem(src, init_opts, opts);

    var ret: ?dvui.Rect.Natural = null;
    if (enabled) {
        if (mi.activeRect()) |r| {
            ret = r;
        }
    }

    fizzy.dvui.labelWithKeybind(label_str, hotkey, enabled, opts, opts);

    mi.deinit();

    return ret;
}

pub fn menuItem(src: std.builtin.SourceLocation, label_str: []const u8, init_opts: dvui.MenuItemWidget.InitOptions, opts: dvui.Options) ?dvui.Rect.Natural {
    var mi = dvui.menuItem(src, init_opts, opts);

    var ret: ?dvui.Rect.Natural = null;
    if (mi.activeRect()) |r| {
        ret = r;
    }

    var label_opts = opts;
    label_opts.margin = dvui.Rect.all(0);
    label_opts.padding = dvui.Rect.all(0);

    if (fizzy.dvui.hovered(mi.data())) {
        label_opts.color_text = dvui.themeGet().color(.window, .text);
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

pub fn menuItemWithChevron(src: std.builtin.SourceLocation, label_str: []const u8, init_opts: dvui.MenuItemWidget.InitOptions, opts: dvui.Options) ?dvui.Rect.Natural {
    var mi = dvui.menuItem(src, init_opts, opts);

    var ret: ?dvui.Rect.Natural = null;
    if (mi.activeRect()) |r| {
        ret = r;
    }

    var label_opts = opts;
    label_opts.margin = dvui.Rect.all(0);
    label_opts.padding = dvui.Rect.all(0);

    if (fizzy.dvui.hovered(mi.data())) {
        label_opts.color_text = dvui.themeGet().color(.window, .text);
    }

    dvui.labelNoFmt(@src(), label_str, .{}, label_opts);

    dvui.icon(@src(), "chevron_right", dvui.entypo.chevron_small_right, .{
        .stroke_color = dvui.themeGet().color(.control, .text).opacity(0.5),
        .fill_color = dvui.themeGet().color(.control, .text).opacity(0.5),
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
pub fn drawMenuSections(parent_menu_id: []const u8) !void {
    for (fizzy.editor.host.menu_sections.items) |*section| {
        if (section.hidden) continue;
        if (!std.mem.eql(u8, section.parent_menu_id, parent_menu_id)) continue;
        section.draw(section.ctx) catch |err| {
            dvui.log.err("Menu section '{s}' failed: {any}", .{ section.id, err });
        };
    }
}
