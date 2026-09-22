//! Fizzy's own shape: icon rail, left explorer, bottom panel, main area.
//!
//! Same role as `examples/*/src/layout.zig`: this file *is* the app's layout. A consumer that
//! wants a different shape writes its own and passes `-Dapp-layout=`.
const std = @import("std");
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
    // The blur harness: a frosted card above the shape, declared last so it floats over it.
    defer blurDemo(editor);
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

    var work = try f.region(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
        .padding = .{ .w = edge_gutter },
    });
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
        .open => {
            editor.explorer.open(editor);
            // One pane at a time while there is only room for one. On a phone-width window the
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

/// The window fill shows as a frame around the place cards — the icon rail on
/// the left, the infobar above, the status bar below. The right edge has no
/// chrome of its own, so the work area insets itself there and the frame
/// closes; without it Main and Panel run into the window border.
///
/// Padding on the work area rather than a margin on each card: a card's margin
/// would also open this gap either side of an inner sash every time a place is
/// split, and a sash gap is a packed split.
const edge_gutter: f32 = 10;

fn placeCard(editor: *fizzy.Editor, extra: dvui.Options) dvui.Options {
    var fill = dvui.themeGet().color(.window, .fill);
    if (editor.app.host.appliesNativeWindowOpacity() and !editor.app.host.isMaximized()) {
        fill = fill.opacity(editor.app.host.contentOpacity());
    }
    var opts = extra;
    opts.background = true;
    opts.color_fill = .{ .color = fill };
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
