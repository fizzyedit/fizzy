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

    // Drawn early but gravity-anchored to the bottom, exactly as `ide.zig` does. A region that
    // expands takes every remaining point of the stack, so anything declared after it gets
    // nothing — which is why the infobar has to reserve its height first rather than trail the
    // layout.
    editor.infobar.draw(editor) catch dvui.log.err("Failed to draw infobar", .{});

    // macOS draws the menu natively; the in-app bar is the fallback everywhere else.
    if (builtin.os.tag != .macos or Menu.debug_force_on_macos) {
        const r = try Menu.draw(editor);
        if (r != .ok) return r;
    }

    {
        // ── the shape ───────────────────────────────────────────────────────────────────────
        //
        // Regions are boxes and splits are separators, so this is ordinary dvui: scope a region,
        // `deinit` it, put a split between two of them. Sizes are points that `dvui.box` lays out
        // — the sidebar keeps the width you dragged it to when the window resizes, rather than
        // rescaling with it.
        var work = try f.region(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
        defer work.deinit();

        {
            var side = try f.region(@src(), .{
                .keywords = sidebar,
                .name = "Sidebar",
                .content = chrome.explorerPane,
                .resize = true,
            }, .{ .min_size_content = .{ .w = 260 }, .expand = .vertical });
            defer side.deinit();
        }

        f.split(@src(), .{});

        {
            var content = try f.region(@src(), .{ .dir = .vertical }, .{ .expand = .both });
            defer content.deinit();

            {
                var main = try f.region(@src(), .{ .keywords = main_area, .name = "Main" }, .{ .expand = .both });
                defer main.deinit();
            }

            f.split(@src(), .{});

            {
                var panel = try f.region(@src(), .{
                    .keywords = bottom,
                    .name = "Panel",
                    .content = chrome.bottomPane,
                    .resize = true,
                    .hide_when_empty = true,
                }, .{ .min_size_content = .{ .h = 220 }, .expand = .horizontal });
                defer panel.deinit();
            }
        }
    }

    return .ok;
}
