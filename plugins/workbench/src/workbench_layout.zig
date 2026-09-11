//! Workspace map maintenance, and drawing the document panes side by side.
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const sdk = @import("fizzy_sdk");
const runtime = @import("runtime.zig");
const Split = core.widgets.Split;
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

/// Draw every workspace side by side, separated by a boundary the user can drag.
///
/// This was a **recursion**: each level opened a two-child `PanedWidget` with workspace `index`
/// in the first half and all the remaining workspaces nested in the second. That is the tree
/// shape a two-child pane forces, and it is why splitting documents behaved differently from
/// splitting anything else in the app — it was a second implementation of the same idea, with
/// its own ratios, its own handle and its own feel.
///
/// It then became a flat row sized in **points**, one number per pane with the first absorbing
/// the remainder — the model the app's own regions use. That was wrong for documents in a way
/// that took using it to see: with a single flexible pane, dragging the boundary between panes 2
/// and 3 grew pane 3 while pane 2 kept its width and slid sideways, so every divider left of the
/// pointer moved; and once the flexible pane reached the minimum its content wanted, every
/// boundary in the row locked at once.
///
/// Now it is `core.widgets.Panes`: every pane holds a *share* of the row, a boundary is a
/// position the rest of the row gives way to — the pane it touches first, then the one past that
/// — and a window resize is proportional because nothing is stored in points. `Panes` is the
/// general piece; the app's regions keep the points model, which is right for a sidebar and wrong
/// for a document.
///
/// The `index` parameter stays because it is on the host vtable, and is the first pane to draw.
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

    // One id per pane, keyed by the workspace's grouping rather than its position — see `paneId`.
    // Every group gets a pane: there is no cap, because a cap would mean "open to the side" quietly
    // doing nothing once the user has enough documents open. A row of twenty panes is unusable,
    // but unusable is the user's call to make and undo by dragging, and a share of a row stays
    // arithmetic however many there are.
    const shown = count - index;
    const ids = dvui.currentWindow().arena().alloc(dvui.Id, shown) catch |err| {
        dvui.logError(@src(), err, "{d} document panes", .{shown});
        return .ok;
    };
    for (ids, 0..) |*id, k| id.* = paneId(wb, index + k);

    var row = core.widgets.panes(@src(), .horizontal, ids);
    defer row.deinit();

    for (0..shown) |k| {
        row.divider(@src(), k);

        var pane = row.pane(@src(), k);
        const result = try wb.workspaces.values()[index + k].draw();
        pane.deinit();
        if (result != .ok) return result;
    }

    // Centring is coordinated with the panel exactly as before: while nothing is being dragged,
    // a workspace centres its content if the panel is animating open.
    if (!panel_dragging and !row.dragging and count > 0) {
        wb.workspaces.values()[count - 1].center = panel_animating_open;
    }

    return .ok;
}

/// A stable id per pane, keyed by the **workspace's grouping** rather than its position.
///
/// Keying by index attached a size to a *slot*: close a pane, open a document to the side, and
/// the new group inherited whatever the old occupant of that slot had been dragged to —
/// including zero, which opened it already shut.
fn paneId(wb: *Workbench, i: usize) dvui.Id {
    return dvui.Id.extendId(null, @src(), @truncate(wb.workspaces.keys()[i] +% 0x9E37));
}
