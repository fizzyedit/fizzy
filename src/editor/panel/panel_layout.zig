//! Bottom-panel workspace map maintenance + recursive split drawing.
const std = @import("std");
const dvui = @import("dvui");
const fizzy = @import("../../fizzy.zig");

const Panel = @import("Panel.zig");
const PanelWorkspace = @import("PanelWorkspace.zig");

const handle_size = 10;
const handle_dist = 60;

pub fn rebuildWorkspaces(panel: *Panel, host: *fizzy.Editor.Host) !void {
    panel.ensureViewGroupings(host);

    var i: usize = 0;
    while (i < host.bottom_views.items.len) : (i += 1) {
        const view = host.bottom_views.items[i];
        const grouping = panel.viewGrouping(view.id);
        if (!panel.workspaces.contains(grouping)) {
            var workspace = PanelWorkspace.init(grouping);
            workspace.active_view_id = view.id;
            try panel.workspaces.put(fizzy.app.allocator, grouping, workspace);
        }
    }

    for (panel.workspaces.values()) |*workspace| {
        if (panel.workspaces.count() == 1) break;

        var contains = false;
        for (host.bottom_views.items) |v| {
            if (panel.viewGrouping(v.id) == workspace.grouping) {
                contains = true;
                break;
            }
        }

        if (!contains) {
            if (panel.open_workspace_grouping == workspace.grouping) {
                for (panel.workspaces.values()) |*w| {
                    if (w.grouping != workspace.grouping) {
                        panel.open_workspace_grouping = w.grouping;
                        break;
                    }
                }
            }
            _ = panel.workspaces.orderedRemove(workspace.grouping);
            break;
        }
    }

    for (panel.workspaces.values()) |*workspace| {
        if (panel.activeViewInGrouping(host, workspace.grouping)) |active| {
            if (panel.viewGrouping(active.id) == workspace.grouping) continue;
        }
        for (host.bottom_views.items) |v| {
            if (panel.viewGrouping(v.id) == workspace.grouping) {
                workspace.active_view_id = v.id;
                break;
            }
        }
    }
}

pub fn drawWorkspaces(
    panel: *Panel,
    host: *fizzy.Editor.Host,
    index: usize,
) !dvui.App.Result {
    if (index >= panel.workspaces.count()) return .ok;

    var s = fizzy.dvui.paned(@src(), .{
        .direction = .horizontal,
        .collapsed_size = if (index == panel.workspaces.count() - 1) std.math.floatMax(f32) else 0,
        .handle_size = handle_size,
        .handle_dynamic = .{ .handle_size_max = handle_size, .distance_max = handle_dist },
    }, .{
        .expand = .both,
        .background = false,
        .id_extra = @intCast(panel.workspaces.keys()[index]),
    });
    defer s.deinit();

    if (s.showFirst()) {
        const result = try panel.workspaces.values()[index].draw(panel, host);
        if (result != .ok) return result;
    }

    if (s.showSecond()) {
        const result = try drawWorkspaces(panel, host, index + 1);
        if (result != .ok) return result;
    }

    return .ok;
}
