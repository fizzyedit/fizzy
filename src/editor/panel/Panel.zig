const std = @import("std");

const dvui = @import("dvui");
const fizzy = @import("../../fizzy.zig");

const panel_layout = @import("panel_layout.zig");
const PanelWorkspace = @import("PanelWorkspace.zig");

pub const Panel = @This();

paned: *fizzy.dvui.PanedWidget = undefined,
scroll_info: dvui.ScrollInfo = .{
    .horizontal = .auto,
},

/// Bottom-panel splits keyed by tab-grouping id (mirrors workbench workspaces).
workspaces: std.AutoArrayHashMapUnmanaged(u64, PanelWorkspace) = .empty,
open_workspace_grouping: u64 = 0,
grouping_id_counter: u64 = 0,
/// Which split each registered bottom view belongs to (`view.id` -> grouping).
view_groupings: std.StringArrayHashMapUnmanaged(u64) = .empty,

pub fn init() Panel {
    return .{};
}

pub fn deinit(self: *Panel, allocator: std.mem.Allocator) void {
    self.workspaces.deinit(allocator);
    self.view_groupings.deinit(allocator);
}

pub fn draw(panel: *Panel) !dvui.App.Result {
    var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = false,
    });
    defer vbox.deinit();

    const host = &fizzy.editor.host;
    if (host.bottom_views.items.len == 0) {
        PanelWorkspace.drawBackground(0);
        return .ok;
    }

    panel.ensureViewGroupings(host);
    try panel_layout.rebuildWorkspaces(panel, host);

    if (panel.workspaces.count() == 0) {
        try panel.workspaces.put(fizzy.app.allocator, 0, PanelWorkspace.init(0));
    }

    return try panel_layout.drawWorkspaces(panel, host, 0);
}

pub fn ensureViewGroupings(self: *Panel, host: *fizzy.Editor.Host) void {
    for (host.bottom_views.items) |view| {
        if (self.view_groupings.get(view.id) == null) {
            self.view_groupings.put(fizzy.app.allocator, view.id, 0) catch {};
        }
    }
}

pub fn viewGrouping(self: *Panel, view_id: []const u8) u64 {
    return self.view_groupings.get(view_id) orelse 0;
}

pub fn setViewGrouping(self: *Panel, view_id: []const u8, grouping: u64) void {
    if (self.view_groupings.getPtr(view_id)) |g| {
        g.* = grouping;
    } else {
        self.view_groupings.put(fizzy.app.allocator, view_id, grouping) catch {};
    }
}

pub fn newGroupingID(self: *Panel) u64 {
    self.grouping_id_counter += 1;
    return self.grouping_id_counter;
}

pub fn viewIndex(self: *Panel, host: *fizzy.Editor.Host, view_id: []const u8) ?usize {
    _ = self;
    for (host.bottom_views.items, 0..) |view, i| {
        if (std.mem.eql(u8, view.id, view_id)) return i;
    }
    return null;
}

pub fn activeViewInGrouping(self: *Panel, host: *fizzy.Editor.Host, grouping: u64) ?*fizzy.Editor.Host.BottomView {
    const workspace = self.workspaces.get(grouping) orelse return null;
    if (workspace.active_view_id) |active_id| {
        for (host.bottom_views.items) |*view| {
            if (std.mem.eql(u8, view.id, active_id) and self.viewGrouping(view.id) == grouping) {
                return view;
            }
        }
    }
    for (host.bottom_views.items) |*view| {
        if (self.viewGrouping(view.id) == grouping) return view;
    }
    return null;
}

pub fn swapBottomViews(_: *Panel, host: *fizzy.Editor.Host, a: usize, b: usize) void {
    if (a >= host.bottom_views.items.len or b >= host.bottom_views.items.len or a == b) return;
    const tmp = host.bottom_views.items[a];
    host.bottom_views.items[a] = host.bottom_views.items[b];
    host.bottom_views.items[b] = tmp;
}
