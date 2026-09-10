//! Fizzy's own shell, written in the new layout primitives.
//!
//! This is simultaneously the default shell, the reference example every fizzy-based app
//! starts from, and the proof that the API is expressive enough — if fizzy's real layout
//! cannot be written here, the design is wrong (plan, Phase 1).
//!
//! **Use it, or copy it.** Following dvui's methodology for widgets: fizzy ships a handful of
//! shapes, and an app either uses one directly — `-Dlayout=ide` gives you the general IDE shape
//! with no layout code of your own — or copies this function into its own source and edits it to
//! add, remove or rearrange regions. There is nothing privileged in here: it is ordinary code
//! over the public `Layout` API, which is exactly what makes copying it a reasonable thing to do
//! rather than a fork.
//!
//! Read it top to bottom: a fixed rail on the left, a resizable sidebar, the menu bar, a
//! resizable bottom panel, and everything left over is the main area.
//!
//! The main area goes through `f.region` — the real test of the generalized cross-fade. The
//! sidebar and bottom go through `chrome.*`, because fizzy wraps those regions in app chrome
//! that Phase 4 splits apart; see the finding recorded in `chrome.zig`.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const fizzy = @import("../../../fizzy.zig");
const sdk = fizzy.sdk;

const Layout = @import("../Layout.zig");
const Sash = @import("core").dvui.Sash;
const chrome = @import("../chrome.zig");
const Menu = @import("../../Menu.zig");
const Constants = @import("../../Constants.zig");

// ── The IDE preset ──────────────────────────────────────────────────────────────────────────
//
// A preset is a **layout plus the keywords it accepts**, kept in one file: copying this shape
// gets you both, and a plugin can name this shape's vocabulary directly
// (`sdk.keywords.ide.sidebar`). The strings live in the SDK because plugins are dylibs and
// cannot import app code; these re-export them so the preset reads as one thing.

/// The left explorer: file trees, outlines, plugin browsers — things you pick *from*.
pub const sidebar = sdk.keywords.ide.sidebar;
/// The bottom panel: logs, diagnostics, terminals — things a task *produces*.
pub const bottom = sdk.keywords.ide.panel;
/// The main area: documents and canvases — the thing being worked on.
pub const main_area = sdk.keywords.ide.main;

pub fn layout(editor: *fizzy.Editor, f: *Layout) !dvui.App.Result {
    var body = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer body.deinit();

    // The icon rail: a chooser for the sidebar region, drawn in its own fixed strip because it
    // sits *beside* the region it chooses for rather than above it. That is why choosers are
    // widgets an app places, not a property of a region.
    const rail_action = try chrome.iconRail(f, sidebar);

    var stack = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = false,
        .padding = .{ .w = Sash.handle_size },
    });
    defer stack.deinit();

    // Drawn first so it reserves its height: a region that expands takes every remaining point.
    editor.infobar.draw(editor) catch dvui.log.err("Failed to draw infobar", .{});

    // macOS draws the menu natively; the in-app bar is the fallback everywhere else.
    if (builtin.os.tag != .macos or Menu.debug_force_on_macos) {
        const r = try Menu.draw(editor);
        if (r != .ok) return r;
    }

    // ── The shape ───────────────────────────────────────────────────────────────────────────
    //
    // Regions and splits, with no edges and no `rest()`. Where a region sits is where it is
    // declared; which way a split divides comes from the container it is in.
    var work = try f.region(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer work.deinit();

    _ = try f.region(@src(), .{
        .name = "Sidebar",
        .keywords = sidebar,
        .content = chrome.explorerPane,
        .resize = true,
        .collapsible = true,
    }, .{ .min_size_content = .{ .w = 260 }, .expand = .vertical });

    // The rail drives the sidebar by *size*, not by reaching for the widget behind it.
    switch (rail_action) {
        .open => editor.explorer.open(editor),
        .close => editor.explorer.peekClose(editor),
        .none => {},
    }

    f.split(@src(), .{});

    var content = try f.region(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer content.deinit();

    _ = try f.region(@src(), .{ .name = "Main", .keywords = main_area }, .{ .expand = .both });

    f.split(@src(), .{});

    _ = try f.region(@src(), .{
        .name = "Panel",
        .keywords = bottom,
        .content = chrome.bottomPane,
        .resize = true,
        .collapsible = true,
        .hide_when_empty = true,
    }, .{ .min_size_content = .{ .h = 220 }, .expand = .horizontal });

    return .ok;
}
