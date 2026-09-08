//! Fizzy's own shell, written in the new layout primitives.
//!
//! This is simultaneously the default shell, the reference example every fizzy-based app
//! starts from, and the proof that the API is expressive enough — if fizzy's real layout
//! cannot be written here, the design is wrong (plan, Phase 1).
//!
//! Read it top to bottom: a fixed rail on the left, a resizable sidebar, the menu bar, a
//! resizable bottom panel, and everything left over is the main area.
//!
//! The main area goes through `f.region` — the real test of the generalized cross-fade. The
//! sidebar and bottom go through `widgets.*`, because fizzy wraps those regions in app chrome
//! that Phase 4 splits apart; see the finding recorded in `widgets.zig`.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const fizzy = @import("../../fizzy.zig");

const Frame = @import("Frame.zig");
const layout_split = @import("split.zig");
const widgets = @import("widgets.zig");
const Menu = @import("../Menu.zig");
const Constants = @import("../Constants.zig");

/// Keyword sets this shell's regions accept. An app declares what *kinds* of thing each
/// region takes; it never names a plugin's surfaces.
const sidebar = Frame.sidebar_keywords;
const bottom = Frame.bottom_keywords;
const main_area = Frame.center_keywords;

pub fn layout(editor: *fizzy.Editor, f: *Frame) !dvui.App.Result {
    var body = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer body.deinit();

    for (editor.host.plugins.items) |plugin| plugin.tickActiveDocument(body.data().id);
    defer for (editor.host.plugins.items) |plugin| plugin.endFrame();

    // The icon rail: the app's own loop over matching surfaces. Nothing here is a framework
    // "chooser" — swapping this for PNG icons or a radial menu is editing these six lines.
    const rail_action = try widgets.iconRail(f, sidebar);

    var explorer_col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = false });
    defer explorer_col.deinit();

    // Infobar is drawn early but gravity-anchored to the bottom of this column, so it spans
    // the sidebar+content width. Preserved from the legacy shell verbatim.
    editor.infobar.draw() catch dvui.log.err("Failed to draw infobar", .{});

    var side = layout_split.split(@src(), .{
        .side = .left,
        .size = editor.explorer_ratio,
        .resize = .drag,
        .collapse = .peek,
    });
    defer side.deinit();

    // SPIKE FINDING: a split's PanedWidget is NOT private layout state. `Explorer.open` /
    // `peekClose` / `collapsed`, `Editor.revealCenter` (:3237) and — critically —
    // `Editor.drawWorkspaces` (:4552, the host API the *workbench plugin* calls) all reach
    // into `editor.explorer.paned` / `editor.panel.paned` to coordinate their own animation
    // with the shell's. Publishing them here keeps behavior identical; see the write-up in
    // shell/FINDINGS.md for why Phase 4 should invert this instead.
    editor.explorer.paned = side.paned;

    editor.flushQueuedNativeMenuActions();
    editor.flushQueuedNativeMenuItems();
    editor.processPendingSaveAs();

    if (dvui.firstFrame(side.paned.wd.id)) {
        side.paned.split_ratio.* = 0.0;
        const avail_w = side.paned.wd.contentRect().w;
        const start_collapsed = avail_w < Constants.min_window_size[0];
        if (start_collapsed or editor.explorer_ratio < 0.01) {
            editor.explorer.closed = true;
        } else {
            side.paned.animateSplit(editor.explorer_ratio, dvui.easing.outBack);
        }
    } else if (side.paned.dragging) {
        editor.explorer_ratio = side.paned.split_ratio.*;
        editor.markWindowRatiosDirty();
    }

    if (!side.paned.collapsed()) editor.panel_hidden_for_center = false;

    switch (rail_action) {
        .open => editor.explorer.open(),
        .close => editor.explorer.peekClose(),
        .none => {},
    }

    if (side.showDock()) {
        // Explorer chrome (header + scroll) wrapping the sidebar region — see widgets.zig.
        const r = try widgets.explorerPane(f, sidebar);
        if (r != .ok) return r;
    }

    if (!side.showRest()) {
        // Explorer peek/collapse hides the workspace subtree, so `drawWorkspaces` does not run
        // and `workspace.center` would otherwise stay latched from a prior panel animation.
        editor.clearAllWorkspaceCenter();
        return .ok;
    }

    var content = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer content.deinit();

    // macOS draws the menu natively; the in-app bar is the fallback everywhere else.
    if (builtin.os.tag != .macos or Menu.debug_force_on_macos) {
        const r = try Menu.draw();
        if (r != .ok) return r;
    }

    if (f.matching(bottom).len > 0) {
        var dock = layout_split.split(@src(), .{
            .side = .bottom,
            .size = editor.panel_ratio,
            .resize = .drag,
            .collapse = .peek,
        });
        defer dock.deinit();
        editor.panel.paned = dock.paned;

        // Panel auto-show/hide, ported verbatim from the legacy shell: the panel collapses
        // when there is no document and no persistent view, and a user drag overrides it.
        if (!dock.paned.dragging) {
            const show_panel = (editor.activeDoc() != null or editor.host.hasPersistentBottomView()) and
                !editor.panel_hidden_for_center;
            if (show_panel) {
                if ((dock.paned.split_ratio.* == 1.0 and !dock.paned.collapsed()) and editor.panel_ratio > 0.0) {
                    dock.paned.animateSplit(1.0 - editor.panel_ratio, dvui.easing.outQuint);
                }
            } else if (!dock.paned.animating and dock.paned.split_ratio.* < 1.0) {
                dock.paned.animateSplit(1.0, dvui.easing.outQuint);
            }
        } else {
            editor.panel_hidden_for_center = false;
            editor.panel_ratio = 1.0 - dock.paned.split_ratio.*;
            editor.markWindowRatiosDirty();
        }

        if (dock.showDock()) {
            // Panel chrome (tab strip) wrapping the bottom region — see widgets.zig.
            const r = try widgets.bottomPane(f, bottom);
            if (r != .ok) return r;
        }
        if (dock.showRest()) {
            const r = try f.region(.{ .keywords = main_area });
            if (r != .ok) return r;
        }
        return .ok;
    }

    return try f.region(.{ .keywords = main_area });
}
