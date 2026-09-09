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
const sdk = fizzy.sdk;

const Frame = @import("Frame.zig");
const layout_split = @import("split.zig");
const widgets = @import("widgets.zig");

// ── The studio preset ───────────────────────────────────────────────────────────────────────
//
// Layout plus vocabulary, as with `ide.zig`. Note it reuses the IDE's keyword sets rather than
// inventing synonyms: that is the point of matching on *kind of place* rather than position. A
// surface saying "I belong somewhere like a sidebar" lands in this shape's right-hand stack
// without knowing it moved.

/// The right-hand stack — same kind of content as the IDE's left sidebar, opposite side.
pub const side = sdk.keywords.studio.stack;
/// The short bottom strip.
pub const bottom = sdk.keywords.studio.strip;
/// The large canvas.
pub const main_area = sdk.keywords.studio.canvas;

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
    var right = layout_split.dock(editor, @src(), .{
        .side = .right,
        .keywords = side,
        .size = 0.25,
        .resize = .drag,
    });
    defer right.deinit();

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
        var strip = layout_split.dock(editor, @src(), .{
            .side = .bottom,
            .keywords = bottom,
            .size = 0.18,
            .resize = .drag,
        });
        defer strip.deinit();

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
