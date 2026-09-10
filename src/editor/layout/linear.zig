//! The linear form of fizzy's IDE shape: three regions on an axis, no nesting of two-child panes.
//!
//! **This is the trial shape for `core.dvui.SplitBox`.** `ide.zig` expresses the same layout as
//! a tree of edge-docked regions, each of which is a two-child `PanedWidget` — which is why it
//! needs `rest()` branching and early returns, and why its regions read as nested rather than as
//! a list. Here the sidebar, the content column and the panel are three `slot` calls, and the
//! boundaries between them are handles.
//!
//! It is written directly against the widget rather than through `Frame.region` on purpose. The
//! open question is how the drag *feels* — thickness, grow-on-approach, whether a boundary
//! drifts under the pointer, what happens at the minimums — and that has to be answered by
//! dragging it before the two-verb `region`/`split` API is committed to on top. Once the feel is
//! right, this becomes `f.region` / `f.split` and this file collapses to the shape in
//! `layout.zig`'s docs.
//!
//! Known gaps, deliberate for the trial: no collapse/peek (the sidebar does not fold away), no
//! fit-to-content regions, and the infobar and menu are drawn in the content column rather than
//! spanning. None of those are drag behaviour, which is what this is for.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const core = @import("core");
const fizzy = @import("../../fizzy.zig");
const sdk = fizzy.sdk;

const Frame = @import("Frame.zig");
const chrome = @import("chrome.zig");
const layout_split = @import("split.zig");
const Menu = @import("../Menu.zig");

pub const sidebar = sdk.keywords.ide.sidebar;
pub const bottom = sdk.keywords.ide.panel;
pub const main_area = sdk.keywords.ide.main;

pub fn layout(editor: *fizzy.Editor, f: *Frame) !dvui.App.Result {
    var body = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer body.deinit();

    // The rail sits outside the layout: it is a chooser drawn *beside* the region it chooses
    // for, with a fixed width, so it is not one of the split shares.
    _ = chrome.iconRail(f, sidebar) catch {};

    // Everything right of the rail, stacked: the regions, then the infobar under them. The
    // right padding is fizzy's own margin, matching `ide.zig`.
    var stack = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = false,
        .padding = .{ .w = layout_split.handle_size },
    });
    defer stack.deinit();

    // macOS draws the menu natively; the in-app bar is the fallback everywhere else.
    if (builtin.os.tag != .macos or Menu.debug_force_on_macos) {
        const r = try Menu.draw(editor);
        if (r != .ok) return r;
    }

    {
        // ── the shape, in two verbs ─────────────────────────────────────────────────────────
        //
        // No `dvui.box`, no widget handles, no `rest()` branching and no early returns: a
        // container subdivides, a leaf hosts surfaces, and `split` puts a draggable boundary
        // between the two either side of it. Read it as the picture it makes.
        var cols = try f.region(@src(), .{ .dir = .horizontal });
        defer cols.end();

        _ = try f.region(@src(), .{ .name = "Sidebar", .keywords = sidebar, .content = chrome.explorerPane });

        f.split(.{});

        var right = try f.region(@src(), .{ .dir = .vertical });
        defer right.end();

        _ = try f.region(@src(), .{ .name = "Main", .keywords = main_area });

        f.split(.{});

        _ = try f.region(@src(), .{ .name = "Panel", .keywords = bottom, .content = chrome.bottomPane });
    }

    editor.infobar.draw(editor) catch dvui.log.err("Failed to draw infobar", .{});
    return .ok;
}
