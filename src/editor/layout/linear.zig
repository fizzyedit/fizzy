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
const Menu = @import("../Menu.zig");

pub const sidebar = sdk.keywords.ide.sidebar;
pub const bottom = sdk.keywords.ide.panel;
pub const main_area = sdk.keywords.ide.main;

pub fn layout(editor: *fizzy.Editor, f: *Frame) !dvui.App.Result {
    var body = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer body.deinit();

    // The rail still sits outside the splitter: it is a chooser beside the region it chooses
    // for, and it has a fixed width, so it is not one of the split shares.
    _ = chrome.iconRail(f, sidebar) catch {};

    var cols = core.dvui.splitBox(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer cols.deinit();

    {   // ── the sidebar ─────────────────────────────────────────────────────────────────────
        var c = cols.slot(@src());
        defer c.deinit();
        _ = chrome.explorerPane(f, sidebar) catch {};
    }

    cols.handle();

    {   // ── the content column: main over panel, split the other way ────────────────────────
        var c = cols.slot(@src());
        defer c.deinit();

        if (builtin.os.tag != .macos or Menu.debug_force_on_macos) {
            const r = try Menu.draw(editor);
            if (r != .ok) return r;
        }

        var rows = core.dvui.splitBox(@src(), .{ .dir = .vertical }, .{ .expand = .both });
        defer rows.deinit();

        {
            var m = rows.slot(@src());
            defer m.deinit();
            _ = try f.drawSelected(main_area);
        }

        rows.handle();

        {
            var p = rows.slot(@src());
            defer p.deinit();
            _ = chrome.bottomPane(f, bottom) catch {};
        }
    }

    editor.infobar.draw(editor) catch dvui.log.err("Failed to draw infobar", .{});
    return .ok;
}
