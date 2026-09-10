//! Workspace map maintenance, and drawing the document panes side by side.
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const sdk = @import("fizzy_sdk");
const runtime = @import("runtime.zig");
const Sash = core.dvui.Sash;
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
    // The **first** pane absorbs the remainder; every pane after it carries a size.
    //
    // It used to be the last, which meant a pane opened to the side was the unsized one and
    // simply appeared at whatever was left — instantly, with nothing to animate. Sizing the new
    // pane instead lets it start at zero and slide in, which is what opening to the side looked
    // like when it was a paned animating its ratio.
    var i: usize = index;
    while (i < count) : (i += 1) {
        const first = i == index;
        const id = paneId(wb, i);

        if (!first) {
            // The divider before this pane drags *this* pane, anchored to its far edge.
            var sep = core.dvui.sash(@src(), .horizontal, i);
            defer sep.end();
            sep.drag(row, id, -1, .{}, .{
                .length = row.data().contentRect().w,
                .handles = Sash.handle_size * @as(f32, @floatFromInt(count - 1)),
            });
            if (dvui.captured(sep.box.data().id)) dragging = true;
        }

        // Absence means never sized; zero means the user dragged it shut. Reading zero as "needs
        // a starting size" springs a closed pane back open on the next frame.
        var width: f32 = 0;
        if (!first) {
            const stored = dvui.dataGet(null, id, "_size", f32);
            const target = stored orelse blk: {
                // A new pane halves what is left, which is what "open to the side" means: the
                // group being split gives up half of itself. Shown starts at zero so it slides in.
                var taken: f32 = 0;
                var k: usize = index + 1;
                while (k < i) : (k += 1) taken += dvui.dataGet(null, paneId(wb, k), "_size", f32) orelse 0;
                const handles = Sash.handle_size * @as(f32, @floatFromInt(count - 1));
                const half = @max(80, (row.data().contentRect().w - taken - handles) / 2);
                dvui.dataSet(null, id, "_size", half);
                dvui.dataSet(null, id, "_shown", @as(f32, 0));
                dvui.refresh(null, @src(), id);
                break :blk half;
            };
            width = Sash.eased(id, target, 220);
        }

        var pane = dvui.box(@src(), .{ .dir = .vertical }, if (first) .{
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
        if (!first) Sash.recordEdges(id, pane.data(), .horizontal);

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

/// A stable id per pane, keyed by the **workspace's grouping** rather than its position.
///
/// Keying by index attached a size to a *slot*: close a pane, open a document to the side, and
/// the new group inherited whatever the old occupant of that slot had been dragged to —
/// including zero, which opened it already shut.
fn paneId(wb: *Workbench, i: usize) dvui.Id {
    return dvui.Id.extendId(null, @src(), @truncate(wb.workspaces.keys()[i] +% 0x9E37));
}
