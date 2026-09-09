//! Fizzy's own shell, written in the new layout primitives.
//!
//! This is simultaneously the default shell, the reference example every fizzy-based app
//! starts from, and the proof that the API is expressive enough — if fizzy's real layout
//! cannot be written here, the design is wrong (plan, Phase 1).
//!
//! **Use it, or copy it.** Following dvui's methodology for widgets: fizzy ships a handful of
//! shapes, and an app either uses one directly — `-Dshell=ide` gives you the general IDE shape
//! with no layout code of your own — or copies this function into its own source and edits it to
//! add, remove or rearrange regions. There is nothing privileged in here: it is ordinary code
//! over the public `Frame` API, which is exactly what makes copying it a reasonable thing to do
//! rather than a fork.
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
const sdk = fizzy.sdk;

const Frame = @import("Frame.zig");
const layout_split = @import("split.zig");
const widgets = @import("widgets.zig");
const Menu = @import("../Menu.zig");
const Constants = @import("../Constants.zig");

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
    editor.infobar.draw(editor) catch dvui.log.err("Failed to draw infobar", .{});

    // `dock`, not `split`: it registers the split under the keywords its docked half shows, so
    // anything outside the layout that needs to command or query this region — `Explorer.open`,
    // `revealCenter`, the workbench's `drawWorkspaces` — finds it by keyword. A shape used to
    // have to publish `editor.explorer.paned = …` by hand, which was mechanism leaking into app
    // code and only worked because fizzy's own shape happens to have an explorer.
    var side = layout_split.dock(editor, @src(), .{
        .side = .left,
        .keywords = sidebar,
        .size = editor.explorer_ratio,
        .resize = .drag,
        .collapse = .peek,
    });
    defer side.deinit();

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
        .open => editor.explorer.open(editor),
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

    // The legacy shell pads the workspace column by the sash width so content never sits flush
    // against the window edge; preserved here (`Editor.zig`'s workspace_vbox).
    var content = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = false,
        .padding = .{ .w = layout_split.handle_size },
    });
    defer content.deinit();

    // macOS draws the menu natively; the in-app bar is the fallback everywhere else.
    if (builtin.os.tag != .macos or Menu.debug_force_on_macos) {
        const r = try Menu.draw(editor);
        if (r != .ok) return r;
    }

    if (f.matching(bottom).len > 0) {
        var dock = layout_split.dock(editor, @src(), .{
            .side = .bottom,
            .keywords = bottom,
            .size = editor.panel_ratio,
            .resize = .drag,
            .collapse = .peek,
        });
        defer dock.deinit();

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
            // "This region is TABBED, and the tabs correspond to bottom surfaces."
            //
            // Fizzy uses the *rich* tabbed form: `Panel` draws its own strip and additionally
            // supports splitting the bottom into several panes with tabs moving between them.
            // The plain tabbed form is `widgets.tabs(f, bottom)` followed by
            // `f.region(.{ .keywords = bottom })` — same chooser, no splitting — and the single
            // form is that with the `tabs` line deleted (`studio.zig`). All three are the same
            // building blocks; none is a mode on the others.
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
