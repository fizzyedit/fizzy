//! One bottom-panel split: workspace-style tab strip + active registered view.
const std = @import("std");
const builtin = @import("builtin");

const dvui = @import("dvui");
const fizzy = @import("../../fizzy.zig");

const Panel = @import("Panel.zig");

const panel_corner_radius: f32 = 12;

pub const drag_name = "panel_tab_drag";

pub const PanelWorkspace = @This();

grouping: u64,
active_view_id: ?[]const u8 = null,

tabs_drag_index: ?usize = null,
tabs_removed_index: ?usize = null,
tabs_insert_before_index: ?usize = null,

pub fn init(grouping: u64) PanelWorkspace {
    return .{ .grouping = grouping };
}

pub fn draw(self: *PanelWorkspace, panel: *Panel, host: *fizzy.Editor.Host) !dvui.App.Result {
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .color_fill = panelContentColor(),
        .corner_radius = dvui.Rect.all(panel_corner_radius),
        .padding = .{ .x = 6, .y = 6, .w = 6, .h = 6 },
        .gravity_y = 0.0,
        .id_extra = @intCast(self.grouping),
    });
    defer card.deinit();

    for (dvui.events()) |*e| {
        if (!card.matchEvent(e)) continue;
        if (e.evt == .mouse) {
            if (e.evt.mouse.action == .press or (e.evt.mouse.action == .position and e.evt.mouse.mod.matchBind("ctrl/cmd"))) {
                panel.open_workspace_grouping = self.grouping;
            }
        }
    }

    if (host.bottom_views.items.len >= 1) self.drawTabs(panel, host);
    try self.drawContent(panel, host);

    return .ok;
}

fn panelContentColor() dvui.Color {
    var content_color = dvui.themeGet().color(.window, .fill);
    switch (builtin.os.tag) {
        .macos, .windows => {
            content_color = if (!fizzy.backend.isMaximized(dvui.currentWindow()))
                content_color.opacity(fizzy.editor.settings.content_opacity)
            else
                content_color;
        },
        else => {},
    }
    return content_color;
}

fn drawTabs(self: *PanelWorkspace, panel: *Panel, host: *fizzy.Editor.Host) void {
    defer self.processTabsDrag(panel, host);

    var tabs_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .none,
        .margin = dvui.Rect.all(0),
        .padding = dvui.Rect.all(0),
        .id_extra = @intCast(self.grouping),
    });
    defer tabs_box.deinit();

    var scroll_area = dvui.scrollArea(@src(), .{ .horizontal = .auto, .horizontal_bar = .hide, .vertical_bar = .hide }, .{
        .expand = .none,
        .background = false,
        .style = .content,
        .margin = dvui.Rect.all(0),
        .padding = dvui.Rect.all(0),
        .border = dvui.Rect.all(0),
        .corner_radius = dvui.Rect.all(0),
        .ninepatch_fill = &dvui.Ninepatch.none,
        .ninepatch_hover = &dvui.Ninepatch.none,
        .ninepatch_press = &dvui.Ninepatch.none,
        .id_extra = @intCast(self.grouping),
    });
    defer scroll_area.deinit();

    var tabs = dvui.reorder(@src(), .{ .drag_name = drag_name }, .{
        .expand = .none,
        .background = false,
    });
    defer tabs.deinit();

    var tabs_hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .none,
        .margin = dvui.Rect.all(0),
        .padding = dvui.Rect.all(0),
        .id_extra = @intCast(self.grouping),
    });
    defer tabs_hbox.deinit();

    const active_in_this_group = blk: {
        if (panel.open_workspace_grouping != self.grouping) break :blk false;
        const active_id = self.active_view_id orelse break :blk false;
        if (panel.viewGrouping(active_id) != self.grouping) break :blk false;
        break :blk true;
    };

    const active_index = if (active_in_this_group)
        panel.viewIndex(host, self.active_view_id.?) orelse null
    else
        null;

    for (host.bottom_views.items, 0..) |view, i| {
        if (panel.viewGrouping(view.id) != self.grouping) continue;

        var reorderable = tabs.reorderable(@src(), .{}, .{
            .expand = .vertical,
            .id_extra = i,
            .padding = dvui.Rect.all(0),
            .margin = dvui.Rect.all(0),
            .border = .all(0),
        });
        defer reorderable.deinit();

        const selected = active_in_this_group and active_index == i;

        // Tabs carry no background in their resting state — selection is shown purely via the
        // label color (see `color_text` below). A fill is drawn only while a tab is being
        // dragged, as reorder feedback.
        const show_tab_fill = reorderable.floating();

        var hbox: dvui.BoxWidget = undefined;
        hbox.init(@src(), .{ .dir = .horizontal }, .{
            .expand = .none,
            .border = dvui.Rect.all(0),
            .background = show_tab_fill,
            .color_fill = if (show_tab_fill) dvui.themeGet().color(.control, .fill) else .transparent,
            .id_extra = i,
            .padding = .{ .x = 2, .y = 2, .w = 2, .h = 2 },
            .margin = dvui.Rect.all(0),
            .ninepatch_fill = &dvui.Ninepatch.none,
            .ninepatch_hover = &dvui.Ninepatch.none,
            .ninepatch_press = &dvui.Ninepatch.none,
        });
        defer hbox.deinit();

        if (reorderable.floating()) {
            self.tabs_drag_index = i;
        }
        if (show_tab_fill) hbox.drawBackground();

        if (reorderable.removed()) {
            self.tabs_removed_index = i;
        } else if (reorderable.insertBefore()) {
            self.tabs_insert_before_index = i;
        }

        var title_buf: [64]u8 = undefined;
        const title_upper = if (view.title.len <= title_buf.len)
            std.ascii.upperString(&title_buf, view.title)
        else
            view.title;

        dvui.label(@src(), "{s}", .{title_upper}, .{
            .color_text = if (selected) dvui.themeGet().color(.highlight, .fill) else dvui.themeGet().color(.control, .text),
            .font = dvui.Font.theme(.heading),
            .padding = dvui.Rect.all(4),
            .gravity_y = 0.5,
        });

        loop: for (dvui.events()) |*e| {
            if (!hbox.matchEvent(e)) continue;

            switch (e.evt) {
                .mouse => |me| {
                    if (me.action == .press and me.button.pointer()) {
                        self.active_view_id = view.id;
                        panel.open_workspace_grouping = self.grouping;
                        host.setActiveBottomView(view.id);
                        dvui.refresh(null, @src(), hbox.data().id);

                        e.handle(@src(), hbox.data());
                        dvui.captureMouse(hbox.data(), e.num);
                        dvui.dragPreStart(me.p, .{ .size = reorderable.data().rectScale().r.size(), .offset = reorderable.data().rectScale().r.topLeft().diff(me.p) });
                    } else if (me.action == .release and me.button.pointer()) {
                        dvui.captureMouse(null, e.num);
                        dvui.dragEnd();
                    } else if (me.action == .motion) {
                        if (dvui.captured(hbox.data().id)) {
                            e.handle(@src(), hbox.data());
                            if (dvui.dragging(me.p, null)) |_| {
                                reorderable.reorder.dragStart(reorderable.data().id.asUsize(), me.p, 0);
                                break :loop;
                            }
                        }
                    }
                },
                else => {},
            }
        }
    }

    if (tabs.finalSlot()) {
        self.tabs_insert_before_index = host.bottom_views.items.len;
    }
}

fn drawContent(self: *PanelWorkspace, panel: *Panel, host: *fizzy.Editor.Host) !void {
    var content_vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = false,
        .id_extra = @intCast(self.grouping),
    });
    defer {
        self.processTabDrag(content_vbox.data(), panel, host);
        content_vbox.deinit();
    }

    const view = panel.activeViewInGrouping(host, self.grouping) orelse return;
    try view.draw(view.ctx);
}

fn processTabsDrag(self: *PanelWorkspace, panel: *Panel, host: *fizzy.Editor.Host) void {
    if (self.tabs_insert_before_index) |insert_before| {
        if (self.tabs_removed_index) |removed| {
            if (removed >= host.bottom_views.items.len) return;
            if (removed > insert_before) {
                panel.swapBottomViews(host, removed, insert_before);
                self.active_view_id = host.bottom_views.items[insert_before].id;
            } else if (insert_before > 0) {
                panel.swapBottomViews(host, removed, insert_before - 1);
                self.active_view_id = host.bottom_views.items[insert_before - 1].id;
            } else {
                panel.swapBottomViews(host, removed, insert_before);
                self.active_view_id = host.bottom_views.items[insert_before].id;
            }
            self.tabs_removed_index = null;
            self.tabs_insert_before_index = null;
        } else {
            for (panel.workspaces.values()) |*workspace| {
                if (workspace.tabs_removed_index) |removed| {
                    if (removed >= host.bottom_views.items.len) return;
                    const view = host.bottom_views.items[removed];
                    if (removed > insert_before) {
                        panel.swapBottomViews(host, removed, insert_before);
                        panel.setViewGrouping(view.id, self.grouping);
                        self.active_view_id = view.id;
                    } else if (insert_before > 0) {
                        panel.swapBottomViews(host, removed, insert_before - 1);
                        panel.setViewGrouping(view.id, self.grouping);
                        self.active_view_id = view.id;
                    } else {
                        panel.swapBottomViews(host, removed, insert_before);
                        panel.setViewGrouping(view.id, self.grouping);
                        self.active_view_id = view.id;
                    }

                    self.tabs_removed_index = null;
                    self.tabs_insert_before_index = null;
                    workspace.tabs_removed_index = null;
                    workspace.tabs_insert_before_index = null;
                    panel.open_workspace_grouping = self.grouping;
                    host.setActiveBottomView(view.id);
                    break;
                }
            }
        }
    }
}

fn processTabDrag(self: *PanelWorkspace, data: *dvui.WidgetData, panel: *Panel, host: *fizzy.Editor.Host) void {
    if (!dvui.dragName(drag_name)) return;

    const drag_src = blk: {
        for (panel.workspaces.values()) |*w| {
            if (w.tabs_drag_index) |i| break :blk .{ .ws = w, .index = i };
        }
        break :blk null;
    };
    if (drag_src == null) return;
    const workspace = drag_src.?.ws;
    const drag_index = drag_src.?.index;
    if (drag_index >= host.bottom_views.items.len) return;
    const dragged_view = host.bottom_views.items[drag_index];

    for (dvui.events()) |*e| {
        if (!dvui.eventMatch(e, .{ .id = data.id, .r = data.rectScale().r, .drag_name = drag_name })) continue;
        if (e.evt != .mouse) continue;

        var right_side = data.rectScale().r;
        right_side.w /= 2;
        right_side.x += right_side.w;

        const last_grouping = panel.workspaces.keys()[panel.workspaces.keys().len - 1];
        if (right_side.contains(e.evt.mouse.p) and last_grouping == self.grouping) {
            if (e.evt.mouse.action == .position) {
                right_side.fill(dvui.Rect.Physical.all(right_side.w / 8), .{
                    .color = dvui.themeGet().color(.highlight, .fill).opacity(0.5),
                });
            }

            if (e.evt.mouse.action == .release and e.evt.mouse.button.pointer()) {
                defer workspace.tabs_drag_index = null;
                e.handle(@src(), data);
                dvui.dragEnd();
                dvui.refresh(null, @src(), data.id);

                const new_g = panel.newGroupingID();
                panel.setViewGrouping(dragged_view.id, new_g);
                var new_ws = PanelWorkspace.init(new_g);
                new_ws.active_view_id = dragged_view.id;
                panel.workspaces.put(fizzy.app.allocator, new_g, new_ws) catch {};
                panel.open_workspace_grouping = new_g;
                host.setActiveBottomView(dragged_view.id);
            }
        } else if (data.rectScale().r.contains(e.evt.mouse.p)) {
            if (e.evt.mouse.action == .position) {
                data.rectScale().r.fill(dvui.Rect.Physical.all(data.rectScale().r.w / 8), .{
                    .color = dvui.themeGet().color(.highlight, .fill).opacity(0.5),
                });
            }

            if (e.evt.mouse.action == .release and e.evt.mouse.button.pointer()) {
                defer workspace.tabs_drag_index = null;
                e.handle(@src(), data);
                dvui.dragEnd();
                dvui.refresh(null, @src(), data.id);

                panel.setViewGrouping(dragged_view.id, self.grouping);
                self.active_view_id = dragged_view.id;
                panel.open_workspace_grouping = self.grouping;
                host.setActiveBottomView(dragged_view.id);
            }
        }
    }
}
