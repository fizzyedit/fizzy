//! A Blender-ish shell that deliberately **inverts** fizzy's shape: no file explorer on the
//! left, a large canvas, a right-hand stack, and a bottom strip.
//!
//! Second half of the Phase 5 acceptance test. Same plugins as `ide.zig` and `minimal.zig`,
//! loaded unchanged; only the layout function differs. If a plugin needed a source change to
//! work here, the design would have failed.
//!
//! **Use it, or copy it.** Following dvui's methodology for widgets: fizzy ships a handful of
//! shapes, and an app either uses one directly — `-Dshell=ide` gives you the general IDE shape
//! with no layout code of your own — or copies this function into its own source and edits it to
//! add, remove or rearrange regions. There is nothing privileged in here: it is ordinary code
//! over the public `Frame` API, which is exactly what makes copying it a reasonable thing to do
//! rather than a fork.
//!
//! The interesting part is the right-hand region: it accepts the *same* `sidebar`/`explorer`
//! keywords fizzy's left region does, so browser surfaces (the file tree, a plugin's list panes)
//! land on the right here with no plugin knowing the difference. That is keyword matching doing
//! the job place-names could not.
const std = @import("std");
const dvui = @import("dvui");
const fizzy = @import("../../fizzy.zig");

const Frame = @import("Frame.zig");
const layout_split = @import("split.zig");
const widgets = @import("widgets.zig");

const side = Frame.sidebar_keywords;
const bottom = Frame.bottom_keywords;
const main_area = Frame.center_keywords;

pub fn layout(editor: *fizzy.Editor, f: *Frame) !dvui.App.Result {
    var body = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer body.deinit();

    for (editor.host.plugins.items) |plugin| plugin.tickActiveDocument(body.data().id);
    defer for (editor.host.plugins.items) |plugin| plugin.endFrame();

    editor.flushQueuedNativeMenuActions();
    editor.flushQueuedNativeMenuItems();
    editor.processPendingSaveAs();

    var col = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = false,
        .padding = .{ .x = layout_split.handle_size },
    });
    defer col.deinit();

    editor.infobar.draw(editor) catch dvui.log.err("Failed to draw infobar", .{});

    // Right-hand stack, not left. Same keywords as fizzy's sidebar.
    var right = layout_split.split(@src(), .{
        .side = .right,
        .size = 0.25,
        .resize = .drag,
    });
    defer right.deinit();
    editor.explorer.paned = right.paned;

    if (right.showDock()) {
        const r = try widgets.explorerPane(f, side);
        if (r != .ok) return r;
    }
    if (!right.showRest()) {
        editor.clearAllWorkspaceCenter();
        return .ok;
    }

    // Big canvas with a short strip underneath — the studio arrangement.
    if (f.matching(bottom).len > 0) {
        var strip = layout_split.split(@src(), .{
            .side = .bottom,
            .size = 0.18,
            .resize = .drag,
        });
        defer strip.deinit();
        editor.panel.paned = strip.paned;
        editor.shell_bottom_split = strip.paned;

        if (strip.showDock()) {
            // "This region IS x": a single bottom surface fills it, with no chooser at all —
            // the shape an app takes when it wants, say, just a terminal down here. Contrast
            // `ide.zig`, which draws a tab strip above the same call and so gets the tabbed
            // form. The difference is one line of app code, not a framework mode.
            const r = try f.region(.{ .keywords = bottom });
            if (r != .ok) return r;
        }
        if (strip.showRest()) {
            const r = try f.region(.{ .keywords = main_area });
            if (r != .ok) return r;
        }
        return .ok;
    }

    return try f.region(.{ .keywords = main_area });
}
