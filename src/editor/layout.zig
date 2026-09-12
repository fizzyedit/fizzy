//! Fizzy's own shape: icon rail, left explorer, bottom panel, main area.
//!
//! Same role as `examples/*/src/layout.zig`: this file *is* the app's layout. A consumer that
//! wants a different shape writes its own and passes `-Dapp-layout=`.
const builtin = @import("builtin");
const dvui = @import("dvui");
const fizzy = @import("../fizzy.zig");
const sdk = fizzy.sdk;
const app = @import("app");

const Layout = app.layout.Layout;
const Menu = @import("Menu.zig");

pub const sidebar = sdk.keywords.ide.sidebar;
pub const bottom = sdk.keywords.ide.panel;
pub const main_area = sdk.keywords.ide.main;

pub fn layout(ctx: ?*anyopaque, f: *Layout) !dvui.App.Result {
    const editor: *fizzy.Editor = @ptrCast(@alignCast(ctx.?));
    var body = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer body.deinit();

    const rail_action = try editor.sidebar.draw(editor, f, sidebar);

    var stack = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = false,
    });
    defer stack.deinit();

    editor.infobar.draw(editor) catch dvui.log.err("Failed to draw infobar", .{});

    if (builtin.os.tag != .macos or Menu.debug_force_on_macos) {
        const r = try Menu.draw(editor);
        if (r != .ok) return r;
    }

    var work = try f.region(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer work.deinit();

    {
        var side = try f.region(@src(), .{
            .name = "Sidebar",
            .keywords = sidebar,
            .shows = .many,
            .content = .{ .ctx = editor, .draw = explorerPane },
            .resize = true,
            .collapsible = true,
        }, .{
            .min_size_content = .{ .w = 260 },
            .expand = .vertical,
            .background = false,
        });
        defer side.deinit();
    }

    switch (rail_action) {
        .open => editor.explorer.open(editor),
        .close => editor.explorer.peekClose(editor),
        .none => {},
    }

    f.split(@src(), .{});

    var content = try f.region(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer content.deinit();

    {
        var main = try f.region(@src(), .{ .name = "Main", .keywords = main_area }, placeCard(editor, .{ .expand = .both }));
        defer main.deinit();
    }

    f.split(@src(), .{});

    {
        var panel = try f.region(@src(), .{
            .name = "Panel",
            .keywords = bottom,
            .shows = .many,
            .content = .{ .ctx = editor, .draw = bottomPane },
            .resize = true,
            .collapsible = true,
            .hide_when_empty = true,
        }, placeCard(editor, .{
            .min_size_content = .{ .h = 220 },
            .expand = .horizontal,
        }));
        defer panel.deinit();
    }

    return .ok;
}

/// Window fill, translucent while the OS window is, rounded like the old
/// place card. Sidebar paints its own chrome; Main and Panel do not.
/// Padding and margin stay the region's `dvui.Options`. A sash gap is a
/// packed split, never a handle_size margin on the card.
const place_radius: f32 = 12;

fn placeCard(editor: *fizzy.Editor, extra: dvui.Options) dvui.Options {
    var fill = dvui.themeGet().color(.window, .fill);
    if (editor.host.appliesNativeWindowOpacity() and !editor.host.isMaximized()) {
        fill = fill.opacity(editor.host.contentOpacity());
    }
    var opts = extra;
    opts.background = true;
    opts.color_fill = fill;
    opts.corners = dvui.CornerRect.round(place_radius);
    // Inset the plugin surface inside the card. A sash is a packed split,
    // not this padding — this only shrinks the content rect.
    if (opts.padding == null) opts.padding = .all(8);
    if (opts.margin == null) opts.margin = .{};
    return opts;
}

fn explorerPane(ctx: ?*anyopaque, f: *Layout, keywords: []const []const u8) !dvui.App.Result {
    const editor: *fizzy.Editor = @ptrCast(@alignCast(ctx.?));
    return editor.explorer.draw(editor, f, keywords);
}

fn bottomPane(ctx: ?*anyopaque, f: *Layout, keywords: []const []const u8) !dvui.App.Result {
    const editor: *fizzy.Editor = @ptrCast(@alignCast(ctx.?));
    return editor.panel.draw(editor, f, keywords);
}
