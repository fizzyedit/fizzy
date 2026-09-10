//! Workspace map maintenance, and drawing the document panes side by side.
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const sdk = @import("fizzy_sdk");
const runtime = @import("runtime.zig");
const Workbench = @import("Workbench.zig");
const Workspace = @import("Workspace.zig");

const handle_size = 10;
const handle_dist = 60;

pub fn rebuildWorkspaces(wb: *Workbench) !void {
    const host = runtime.host();

    var i: usize = 0;
    while (i < host.openDocCount()) : (i += 1) {
        const doc = host.docByIndex(i) orelse continue;
        const grouping = doc.owner.documentGrouping(doc);
        if (!wb.workspaces.contains(grouping)) {
            var workspace: Workspace = .init(grouping);
            var j: usize = 0;
            while (j < host.openDocCount()) : (j += 1) {
                const d = host.docByIndex(j) orelse continue;
                if (d.owner.documentGrouping(d) == grouping) {
                    workspace.open_file_index = host.docIndex(d.id) orelse 0;
                }
            }
            try wb.workspaces.put(runtime.allocator(), grouping, workspace);
        }
    }

    for (wb.workspaces.values()) |*workspace| {
        if (wb.workspaces.count() == 1) break;

        var contains = false;
        var k: usize = 0;
        while (k < host.openDocCount()) : (k += 1) {
            const doc = host.docByIndex(k) orelse continue;
            if (doc.owner.documentGrouping(doc) == workspace.grouping) {
                contains = true;
                break;
            }
        }

        if (!contains) {
            if (wb.open_workspace_grouping == workspace.grouping) {
                for (wb.workspaces.values()) |*w| {
                    if (w.grouping != workspace.grouping) {
                        wb.open_workspace_grouping = w.grouping;
                        break;
                    }
                }
            }
            workspace.deinit();
            _ = wb.workspaces.orderedRemove(workspace.grouping);
            break;
        }
    }

    for (wb.workspaces.values()) |*workspace| {
        if (host.docByIndex(workspace.open_file_index)) |doc| {
            if (doc.owner.documentGrouping(doc) == workspace.grouping) continue;
        }
        var idx: usize = host.openDocCount();
        while (idx > 0) {
            idx -= 1;
            if (host.docByIndex(idx)) |d| {
                if (d.owner.documentGrouping(d) == workspace.grouping) {
                    workspace.open_file_index = idx;
                    break;
                }
            }
        }
    }
}

/// Draw every workspace side by side, separated by the same sash the app's own regions use.
///
/// This was a **recursion**: each level opened a two-child `PanedWidget` with workspace `index`
/// in the first half and all the remaining workspaces nested in the second. That is the tree
/// shape a two-child pane forces, and it is why splitting documents behaved differently from
/// splitting anything else in the app — it was a second implementation of the same idea, with
/// its own ratios, its own handle and its own feel.
///
/// Now it is a flat loop: N panes on an axis with `core.dvui.Sash` between them, sized in points
/// like every other region. The `index` parameter stays because it is on the host vtable, and is
/// the first pane to draw.
pub fn drawWorkspaces(wb: *Workbench, index: usize) !dvui.App.Result {
    const count = wb.workspaces.count();
    if (index >= count) return .ok;

    // The bottom split's state, asked for directly rather than handed in as three out-parameters
    // on the call. Those parameters only worked because fizzy's own shape has a panel; an app
    // whose bottom region is laid out differently — or absent — had no way to supply them.
    // Absent is a normal answer, and means "no bottom split to coordinate with".
    const panel = runtime.host().splitState(sdk.keywords.ide.panel);
    const panel_dragging = if (panel) |p| p.dragging else false;
    const panel_animating_open = if (panel) |p| (p.animating and p.ratio < 1.0) else false;

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both, .background = false });
    defer row.deinit();

    var dragging = panel_dragging;
    var i: usize = index;
    while (i < count) : (i += 1) {
        if (i > index) {
            // The divider between this pane and the one before it. Every pane but the last is
            // sized, so the sash drags the one on its left.
            var sep = core.dvui.Sash.begin(@src(), .horizontal, i);
            defer sep.end();
            sep.drag(row, paneId(row, i - 1), 1, .{}, .{
                .length = row.data().contentRect().w,
                .handles = handle_size * @as(f32, @floatFromInt(count - 1)),
            });
            if (dvui.captured(sep.box.data().id)) dragging = true;
        }

        // The last pane takes what is left; the others keep the width they were dragged to.
        const last = i == count - 1;
        const id = paneId(row, i);
        const width = core.dvui.Sash.sizeOf(id);
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
        if (!last) core.dvui.Sash.recordEdges(id, pane.data(), .horizontal);

        // A pane that has never been sized starts at an even share, which is what the old
        // first-frame `1.0 -> 0.5` animation was expressing.
        if (!last and width <= 0) {
            const even = row.data().contentRect().w / @as(f32, @floatFromInt(count));
            dvui.dataSet(null, id, "_size", @max(80, even));
            dvui.refresh(null, @src(), id);
        }

        const result = try wb.workspaces.values()[i].draw();
        pane.deinit();
        if (result != .ok) return result;
    }

    // Centring is coordinated with the panel exactly as before: while nothing is being dragged,
    // a workspace centres its content if the panel is animating open.
    if (!dragging and count > 0) {
        wb.workspaces.values()[count - 1].center = panel_animating_open;
    }

    return .ok;
}

/// A stable id per pane, derived from the row so it survives the panes around it coming and
/// going. Sizes hang off this.
fn paneId(row: *dvui.BoxWidget, i: usize) dvui.Id {
    return row.data().id.extendId(@src(), i);
}
