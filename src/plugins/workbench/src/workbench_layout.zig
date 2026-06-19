//! Workspace map maintenance + recursive split drawing (Stage W2).
const std = @import("std");
const dvui = @import("dvui");
const wbench = @import("../workbench.zig");
const Globals = @import("Globals.zig");
const Workbench = @import("Workbench.zig");
const Workspace = @import("Workspace.zig");

const handle_size = 10;
const handle_dist = 60;

pub fn rebuildWorkspaces(wb: *Workbench) !void {
    const host = Globals.host;

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
            try wb.workspaces.put(Globals.allocator(), grouping, workspace);
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

pub const PanelPanedState = struct {
    dragging: bool,
    animating: bool,
    split_ratio: *f32,
};

pub fn drawWorkspaces(wb: *Workbench, panel: PanelPanedState, index: usize) !dvui.App.Result {
    if (index >= wb.workspaces.count()) return .ok;

    var s = wbench.wdvui.paned(@src(), .{
        .direction = .horizontal,
        .collapsed_size = if (index == wb.workspaces.count() - 1) std.math.floatMax(f32) else 0,
        .handle_size = handle_size,
        .handle_dynamic = .{ .handle_size_max = handle_size, .distance_max = handle_dist },
    }, .{
        .expand = .both,
        .background = false,
    });
    defer s.deinit();

    const dragging = panel.dragging or s.dragging;

    if (!dragging) {
        const should_center = (s.animating and s.split_ratio.* < 1.0) or
            (panel.animating and panel.split_ratio.* < 1.0);
        if (index + 1 < wb.workspaces.count()) {
            wb.workspaces.values()[index + 1].center = should_center;
        } else if (wb.workspaces.count() == 1) {
            wb.workspaces.values()[index].center = should_center;
        }
    }

    if (s.collapsing and s.split_ratio.* < 0.5) {
        s.animateSplit(1.0, dvui.easing.outBack);
    }

    if (!s.dragging and !s.animating and !s.collapsing and !s.collapsed_state) {
        if (index == wb.workspaces.count() - 1) {
            if (s.split_ratio.* != 1.0) {
                s.animateSplit(1.0, dvui.easing.outBack);
            }
        } else {
            if (dvui.firstFrame(s.wd.id)) {
                s.split_ratio.* = 1.0;
                s.animateSplit(0.5, dvui.easing.outBack);
            }
        }
    }

    if (s.showFirst()) {
        const result = try wb.workspaces.values()[index].draw();
        if (result != .ok) return result;
    }

    if (s.showSecond()) {
        const result = try drawWorkspaces(wb, panel, index + 1);
        if (result != .ok) return result;
    }

    return .ok;
}
