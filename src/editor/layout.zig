//! Fizzy's own shape: icon rail, left explorer, bottom panel, main area.
//!
//! Same role as fizzyedit/example-app's `shapes/*.zig`: this file *is* the app's layout. A consumer that
//! wants a different shape writes its own and passes `-Dapp-layout=`.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const fizzy = @import("../fizzy.zig");
const sdk = fizzy.sdk;
const app = @import("app");

const Layout = app.layout.Layout;
const Menu = @import("Menu.zig");
const Rail = app.layout.Rail;
const Accounts = @import("Accounts.zig");
const Chrome = @import("Chrome.zig");

pub const sidebar = sdk.keywords.ide.sidebar;
pub const bottom = sdk.keywords.ide.panel;
pub const main_area = sdk.keywords.ide.main;

pub fn layout(ctx: ?*anyopaque, f: *Layout) !dvui.App.Result {
    const editor: *fizzy.Editor = @ptrCast(@alignCast(ctx.?));
    const chrome = editor.chrome;
    const rail_left = chrome.sidebar_edge == .left;
    // The card Main and Panel wear, and every float's places with them (`Layout.card`).
    f.card = placeCard(editor);
    // The blur harness: a frosted card above the shape, declared last so it floats over it.
    defer blurDemo(editor);
    var body = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer body.deinit();

    var rail_action: Rail.Action = .none;
    if (rail_left) rail_action = Rail.draw(railHost(editor), f, sidebar);

    {
        var stack = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
            .background = false,
        });
        defer stack.deinit();

        if (chrome.infobar) editor.infobar.draw(editor) catch dvui.log.err("Failed to draw infobar", .{});

        if (chrome.menu_bar and (builtin.target.os.tag != .macos or Menu.debug_force_on_macos)) {
            const r = try Menu.draw(editor);
            if (r != .ok) return r;
        }

        // The window fill shows as a frame around the cards: the rail on one side, so the work area
        // insets itself on the other.
        var work = try f.region(@src(), .{ .dir = .horizontal }, .{
            .expand = .both,
            .padding = if (rail_left) dvui.Rect{ .w = edge_gutter } else dvui.Rect{ .x = edge_gutter },
        });
        defer work.deinit();

        // The Sidebar's sash is the `split` after it on the left and the one before it on the
        // right, as the Panel's is before it: `Layout.drawPendingSplit` resizes the nearer
        // `resize` region.
        if (rail_left) {
            try sidebarRegion(editor, f);
            applyRailAction(editor, f, rail_action);
            f.split(@src(), .{});
        }
        try contentRegion(f, chrome);
        if (!rail_left) {
            f.split(@src(), .{});
            try sidebarRegion(editor, f);
        }
    }

    if (!rail_left) {
        rail_action = Rail.draw(railHost(editor), f, sidebar);
        applyRailAction(editor, f, rail_action);
    }

    return .ok;
}

fn sidebarRegion(editor: *fizzy.Editor, f: *Layout) !void {
    var side = try f.region(@src(), .{
        .name = "Sidebar",
        .keywords = sidebar,
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

/// What the Sidebar and the rail ask of the frame once the Sidebar is drawn.
fn applyRailAction(editor: *fizzy.Editor, f: *Layout, action: Rail.Action) void {
    // `?show=` asked for one file and the room for it (`Editor.show_only_document`).
    if (editor.show_only_document) {
        editor.show_only_document = false;
        editor.explorer.peekClose(editor);
        if (f.state.regionFor(bottom)) |panel| panel.close();
    }

    switch (action) {
        .open => {
            editor.explorer.open(editor);
            // One pane at a time while there is only room for one. On a mobile-width window the
            // explorer covers the width it opens into, so leaving the panel open below it would
            // split the little space left between two things and show neither.
            if (f.state.regionFor(bottom)) |panel| {
                if (panel.isPeeking() or !panel.isClosed()) {
                    if (dvui.windowRect().w < Layout.Region.InitOptions.collapse_below) panel.close();
                }
            }
        },
        .close => editor.explorer.peekClose(editor),
        .none => {},
    }
}

fn contentRegion(f: *Layout, chrome: Chrome) !void {
    var content = try f.region(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer content.deinit();

    {
        var main = try f.region(@src(), .{ .name = "Main", .keywords = main_area, .card = true, .pane_cards = true }, .{ .expand = .both });
        defer main.deinit();
    }

    if (!chrome.panel) return;
    f.split(@src(), .{});

    {
        var panel = try f.region(@src(), .{
            .name = "Panel",
            .keywords = bottom,
            // A place like any other: the generic strip while it holds more than one view, a tab
            // dragged along it or off it carried in the view drag, and splitting it is the region
            // Split every place has.
            .resize = true,
            .collapsible = true,
            .hide_when_empty = true,
            .card = true,
            .pane_cards = true,
        }, .{
            .min_size_content = .{ .h = 220 },
            .expand = .horizontal,
        });
        defer panel.deinit();
    }
}

/// Window fill, translucent while the OS window is, rounded like the old
/// place card. Sidebar paints its own chrome; Main and Panel do not.
/// Padding and margin stay the region's `dvui.Options`. A sash gap is a
/// packed split, never a handle_size margin on the card.
const place_radius: f32 = 12;
/// Between a place card's edge and the surface in it.
const place_padding: f32 = 8;

/// The window fill shows as a frame around the place cards — the icon rail on
/// one side, the infobar above, the status bar below. The other edge has no
/// chrome of its own, so the work area insets itself there and the frame
/// closes; without it Main and Panel run into the window border.
///
/// Padding on the work area rather than a margin on each card: a card's margin
/// would also open this gap either side of an inner sash every time a place is
/// split, and a sash gap is a packed split.
const edge_gutter: f32 = 10;

fn placeCard(editor: *fizzy.Editor) dvui.Options {
    var fill = dvui.themeGet().color(.window, .fill);
    // Opaque while the window covers the desktop: `contentOpacity` eases there with the window.
    if (editor.app.host.appliesNativeWindowOpacity()) {
        fill = fill.opacity(editor.app.host.contentOpacity());
    }
    return .{
        .background = true,
        .color_fill = .{ .color = fill },
        .corners = dvui.CornerRect.round(fizzy.core.corners.scaled(place_radius)),
        // Inset the plugin surface inside the card. A sash is a packed split,
        // not this padding — this only shrinks the content rect.
        .padding = .all(place_padding),
    };
}

fn explorerPane(ctx: ?*anyopaque, f: *Layout, keywords: []const []const u8) Layout.Region.Error!dvui.App.Result {
    const editor: *fizzy.Editor = @ptrCast(@alignCast(ctx.?));
    return editor.explorer.draw(editor, f, keywords);
}

pub fn railHost(editor: *fizzy.Editor) Rail.Host {
    return .{ .ctx = editor, .vtable = &.{
        .drawFooterItems = railFooterItems,
        .sidePaneShown = railSidePaneShown,
        .undecidedPluginCount = railUndecidedCount,
        .iconRect = railIconRect,
    } };
}

/// The account disc, when anything can be signed in to; then plugin-drawn items (a badge, a
/// status light); the rail then adds fizzy's own views.
fn railFooterItems(ctx: ?*anyopaque, size: f32) void {
    const editor: *fizzy.Editor = @ptrCast(@alignCast(ctx.?));
    if (editor.app.host.account_providers.items.len != 0) Accounts.drawRailDisc(editor, size) catch |err| dvui.log.err("account disc failed to draw: {s}", .{@errorName(err)});
    for (editor.app.host.rail_items.items, 0..) |item, i| {
        if (item.hidden) continue;
        var slot = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = i, .background = false, .min_size_content = .{ .h = size } });
        defer slot.deinit();
        item.draw(item.ctx, size) catch |err| dvui.log.err("rail item '{s}' failed to draw: {s}", .{ item.id, sdk.Plugin.errorNameOf(item.owner, err) });
    }
}

fn railSidePaneShown(ctx: ?*anyopaque) bool {
    const editor: *fizzy.Editor = @ptrCast(@alignCast(ctx.?));
    return if (editor.regionFor(sidebar)) |r| !r.isClosed() and !r.isFolded() else !editor.explorer.closed;
}

fn railUndecidedCount(ctx: ?*anyopaque, view_id: []const u8) usize {
    // The rail knows no view by name; only the store's view holds the card that offers a build.
    if (!std.mem.eql(u8, view_id, app.store.Store.view_id)) return 0;
    const editor: *fizzy.Editor = @ptrCast(@alignCast(ctx.?));
    return editor.app.undecidedPluginCount();
}

fn railIconRect(_: ?*anyopaque, r: dvui.Rect.Physical) void {
    if (fizzy.backend.custom_titlebar) fizzy.Editor.pushTitleStripRect(r);
}

// ── Blur harness ───────────────────────────────────────────────────────────────────────────────
//
// `FIZZY_BLUR_DEMO=1` draws a draggable frosted card over the window: a `core.widgets`
// floating window with the dialog frost (`core.dialogs.dialogFrost`), so it is drawn exactly
// the way a dialog or the palette is — the deferred capture, the tint, the settings — and can
// be dragged next to the explorer's empty space to compare, or over another dialog to check
// the frost sees it. Nothing else reads it.

var blur_demo_on: ?bool = null;
/// Where the card is; the user drags it around by its header.
var blur_demo_rect: ?dvui.Rect = null;

fn blurDemoWanted(editor: *fizzy.Editor) bool {
    if (blur_demo_on == null) {
        blur_demo_on = if (comptime builtin.target.cpu.arch == .wasm32) false else blk: {
            const v = std.process.Environ.getAlloc(fizzy.core.platform.processEnviron(), editor.app.gpa, "FIZZY_BLUR_DEMO") catch break :blk false;
            defer editor.app.gpa.free(v);
            dvui.log.info("blur harness on", .{});
            break :blk true;
        };
    }
    return blur_demo_on.?;
}

fn blurDemo(editor: *fizzy.Editor) void {
    if (!blurDemoWanted(editor)) return;
    if (blur_demo_rect == null) {
        const win = dvui.windowRect();
        const w = @min(480, win.w * 0.6);
        const h = @min(320, win.h * 0.5);
        blur_demo_rect = .{ .x = (win.w - w) / 2, .y = (win.h - h) / 2, .w = w, .h = h };
    }
    var fw = fizzy.core.widgets.floatingWindow(@src(), .{
        .rect = &blur_demo_rect.?,
        .open_flag = null,
        .frost = fizzy.core.dialogs.dialogFrost(),
    }, .{
        .color_fill = .{ .color = fizzy.core.dialogs.dialogFill() },
        .corners = dvui.CornerRect.all(12),
        .border = .{},
        .padding = .{},
        .margin = .{},
        .box_shadow = .{ .color = .black, .alpha = 0.35, .fade = 10, .corners = dvui.CornerRect.all(12) },
    });
    defer fw.deinit();
    fw.dragAreaSet(dvui.windowHeader("frosted glass", "", null));
}
