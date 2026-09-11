//! Fizzy's bottom panel: pane map maintenance, and drawing the panes side by side with the
//! same `core.widgets.Split` the app's regions and the workbench's documents use.
const std = @import("std");
const dvui = @import("dvui");
const fizzy = @import("../../fizzy.zig");

const Panel = @import("Panel.zig");
const Split = @import("core").widgets.Split;
const Layout = @import("app").layout.Layout;
const Pane = @import("Pane.zig");

const handle_size = 10;
const handle_dist = 60;

pub fn rebuildWorkspaces(panel: *Panel, f: *Layout, keywords: []const []const u8) !void {
    panel.ensurePanes(f, keywords);

    for (f.matching(keywords)) |view| {
        const grouping = panel.paneOf(view.id);
        if (!panel.workspaces.contains(grouping)) {
            var workspace = Pane.init(grouping);
            workspace.active_view_id = view.id;
            try panel.workspaces.put(fizzy.entry().allocator, grouping, workspace);
        }
    }

    for (panel.workspaces.values()) |*workspace| {
        if (panel.workspaces.count() == 1) break;

        var contains = false;
        for (f.matching(keywords)) |v| {
            if (panel.paneOf(v.id) == workspace.grouping) {
                contains = true;
                break;
            }
        }

        if (!contains) {
            if (panel.open_pane == workspace.grouping) {
                for (panel.workspaces.values()) |*w| {
                    if (w.grouping != workspace.grouping) {
                        panel.open_pane = w.grouping;
                        break;
                    }
                }
            }
            _ = panel.workspaces.orderedRemove(workspace.grouping);
            break;
        }
    }

    for (panel.workspaces.values()) |*workspace| {
        if (panel.activeSurfaceIn(f, keywords, workspace.grouping)) |active| {
            if (panel.paneOf(active.id) == workspace.grouping) continue;
        }
        for (f.matching(keywords)) |v| {
            if (panel.paneOf(v.id) == workspace.grouping) {
                workspace.active_view_id = v.id;
                break;
            }
        }
    }
}

/// Draw the pane group's panes side by side, separated by the same split the app's regions and
/// the workbench's document panes use.
///
/// This recursed the same way `workbench_layout` did — a two-child paned per level with the rest
/// nested in the second half — which made it the third implementation of splitting in the tree.
/// It is now a flat loop over `core.widgets.Split`, so a divider here drags, looks and feels exactly
/// like a divider anywhere else.
pub fn drawWorkspaces(
    panel: *Panel,
    host: *fizzy.Editor.Host,
    f: *Layout,
    keywords: []const []const u8,
    index: usize,
) !dvui.App.Result {
    const count = panel.workspaces.count();
    if (index >= count) return .ok;

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both, .background = false });
    defer row.deinit();

    var i: usize = index;
    while (i < count) : (i += 1) {
        if (i > index) {
            var divider = Split.init(@src(), .horizontal, i, null);
            defer divider.deinit();
            divider.drag(row, paneId(row, i - 1), 1, .{}, .{
                .extent = row.data().contentRect().w,
                .handles = Split.handle_size * @as(f32, @floatFromInt(count - 1)),
            });
        }

        const last = i == count - 1;
        const id = paneId(row, i);

        // Absence means never sized; zero means the user dragged it shut. Reading zero as
        // "needs a starting size" springs a closed pane back open on the next frame.
        const stored = dvui.dataGet(null, id, "_size", f32);
        const width = stored orelse blk: {
            const even = @max(80, row.data().contentRect().w / @as(f32, @floatFromInt(count)));
            dvui.dataSet(null, id, "_size", even);
            dvui.refresh(null, @src(), id);
            break :blk even;
        };

        var pane = dvui.box(@src(), .{ .dir = .vertical }, if (last) .{
            .id_extra = i,
            .expand = .both,
            .background = false,
        } else .{
            .id_extra = i,
            .expand = .vertical,
            .background = false,
            .min_size_content = .{ .w = width },
            .max_size_content = .width(width),
        });
        if (!last) Split.recordEdges(id, pane.data(), .horizontal);

        const result = try panel.workspaces.values()[i].draw(panel, host, f, keywords);
        pane.deinit();
        if (result != .ok) return result;
    }

    return .ok;
}

/// A stable id per pane, derived from the row so it survives its neighbours coming and going.
fn paneId(row: *dvui.BoxWidget, i: usize) dvui.Id {
    return row.data().id.extendId(@src(), i);
}
