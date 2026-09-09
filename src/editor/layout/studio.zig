//! A Blender-ish shell that deliberately **inverts** fizzy's shape: no file explorer on the
//! left, a large canvas, a right-hand stack, and a bottom strip.
//!
//! Second half of the Phase 5 acceptance test. Same plugins as `ide.zig` and `minimal.zig`,
//! loaded unchanged; only the layout function differs. If a plugin needed a source change to
//! work here, the design would have failed.
//!
//! **Use it, or copy it.** Following dvui's methodology for widgets: fizzy ships a handful of
//! shapes, and an app either uses one directly — `-Dlayout=ide` gives you the general IDE shape
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
const chrome = @import("chrome.zig");

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

    var col = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = false,
        .padding = .{ .x = layout_split.handle_size },
    });
    defer col.deinit();

    editor.infobar.draw(editor) catch dvui.log.err("Failed to draw infobar", .{});

    // The whole shape, as region declarations. No paned, no split ratios, no showFirst /
    // showSecond, no widget pointers published for other code to find — the framework owns all
    // of that. What is left is what this shape actually *is*.

    // A stack on the right, not the left. Same keywords as the IDE's sidebar, so a surface that
    // belongs "somewhere like a sidebar" lands here without knowing it moved.
    var stack = try f.region(@src(), .{
        .name = "Stack",
        .keywords = side,
        .edge = .right,
        .size = 0.25,
        .resize = true,
    });
    defer stack.end();
    if (!stack.rest()) return .ok;

    // A short strip along the bottom with no chrome of its own: "this region IS x". The shape
    // an app takes when it wants, say, just a terminal down there. Adding `.content =
    // chrome.tabbed` to the same declaration gets the tabbed form instead, and `ide.zig` passes
    // `chrome.bottomPane` for the richer splittable one; the difference is one field.
    var strip = try f.region(@src(), .{
        .name = "Strip",
        .keywords = bottom,
        .edge = .bottom,
        .size = 0.18,
        .resize = true,
        .hide_when_empty = true,
    });
    defer strip.end();
    if (!strip.rest()) return .ok;

    // The remainder: the large canvas.
    var canvas = try f.region(@src(), .{ .name = "Canvas", .keywords = main_area });
    defer canvas.end();

    return .ok;
}
