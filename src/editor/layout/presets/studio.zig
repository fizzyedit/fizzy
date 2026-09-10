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
//! over the public `Layout` API, which is exactly what makes copying it a reasonable thing to do
//! rather than a fork.
//!
//! The interesting part is the right-hand region: it accepts the *same* `sidebar`/`explorer`
//! keywords fizzy's left region does, so browser surfaces (the file tree, a plugin's list panes)
//! land on the right here with no plugin knowing the difference. That is keyword matching doing
//! the job place-names could not.
const std = @import("std");
const dvui = @import("dvui");
const fizzy = @import("../../../fizzy.zig");
const sdk = fizzy.sdk;

const Layout = @import("../Layout.zig");
const Sash = @import("core").dvui.Sash;
const chrome = @import("../chrome.zig");

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

pub fn layout(editor: *fizzy.Editor, f: *Layout) !dvui.App.Result {
    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = false,
        .padding = .{ .x = Sash.handle_size },
    });
    defer body.deinit();

    editor.infobar.draw(editor) catch dvui.log.err("Failed to draw infobar", .{});

    // The whole shape, as regions and splits. No paned, no ratios, no `rest()` branching, and
    // nothing about an edge: where a region sits is where it is declared, and which way a split
    // divides comes from the container it is in.
    var work = try f.region(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer work.deinit();

    {
        // Canvas over strip, on the left.
        var left = try f.region(@src(), .{ .dir = .vertical }, .{ .expand = .both });
        defer left.deinit();

        // The large canvas.
        _ = try f.region(@src(), .{ .name = "Canvas", .keywords = main_area }, .{ .expand = .both });

        f.split(@src(), .{});

        // A short strip along the bottom with no chrome of its own: "this region IS x". The
        // shape an app takes when it wants, say, just a terminal down there. Adding `.content =
        // chrome.tabbed` gets the tabbed form; `ide.zig` passes `chrome.bottomPane` for the
        // richer splittable one. The difference is one field.
        _ = try f.region(@src(), .{
            .name = "Strip",
            .keywords = bottom,
            .resize = true,
            .collapsible = true,
            .hide_when_empty = true,
        }, .{ .min_size_content = .{ .h = 150 }, .expand = .horizontal });
    }

    f.split(@src(), .{});

    // A stack on the right, not the left. Same keywords as the IDE's sidebar, so a surface that
    // belongs "somewhere like a sidebar" lands here without knowing it moved.
    _ = try f.region(@src(), .{
        .name = "Stack",
        .keywords = side,
        .resize = true,
        .collapsible = true,
    }, .{ .min_size_content = .{ .w = 300 }, .expand = .vertical });

    return .ok;
}
