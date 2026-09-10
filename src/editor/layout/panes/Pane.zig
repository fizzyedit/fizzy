//! One bottom-panel split: workspace-style tab strip + active registered view.
const std = @import("std");
const builtin = @import("builtin");

const dvui = @import("dvui");
const fizzy = @import("../../../fizzy.zig");

const PaneGroup = @import("PaneGroup.zig");
const Frame = @import("../Frame.zig");

const panel_corner_radius: f32 = 12;

pub const drag_name = "panel_tab_drag";

pub const Pane = @This();

grouping: u64,
active_view_id: ?[]const u8 = null,

/// Shared with the workbench's document tabs — see `core.dvui.Tabs.State`. This trio used
/// to be declared identically in both places.
tab_state: fizzy.dvui.Tabs.State = .{},

pub fn init(grouping: u64) Pane {
    return .{ .grouping = grouping };
}

/// Rounded panel chrome (window fill + corner radius) used with and without plugin content.
pub fn drawBackground(grouping: u64) void {
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .color_fill = panelContentColor(),
        .corners = dvui.CornerRect.all(panel_corner_radius),
        .padding = .{ .x = 6, .y = 6, .w = 6, .h = 6 },
        .gravity_y = 0.0,
        .id_extra = @intCast(grouping),
    });
    defer card.deinit();
}

pub fn draw(self: *Pane, panel: *PaneGroup, host: *fizzy.Editor.Host, f: *Frame, keywords: []const []const u8) !dvui.App.Result {
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .color_fill = panelContentColor(),
        .corners = dvui.CornerRect.all(panel_corner_radius),
        .padding = .{ .x = 6, .y = 6, .w = 6, .h = 6 },
        .gravity_y = 0.0,
        .id_extra = @intCast(self.grouping),
    });
    defer card.deinit();

    for (dvui.events()) |*e| {
        if (!card.matchEvent(e)) continue;
        if (e.evt == .mouse) {
            if (e.evt.mouse.action == .press or (e.evt.mouse.action == .position and e.evt.mouse.mod.matchBind("ctrl/cmd"))) {
                panel.open_pane = self.grouping;
            }
        }
    }

    if (PaneGroup.surfaces(f, keywords).len >= 1) self.drawTabs(panel, host, f, keywords);
    try self.drawContent(panel, host, f, keywords);

    return .ok;
}

fn panelContentColor() dvui.Color {
    var content_color = dvui.themeGet().color(.window, .fill);
    switch (builtin.os.tag) {
        .macos, .windows => {
            content_color = if (!fizzy.backend.isMaximized(dvui.currentWindow()))
                content_color.opacity(fizzy.editor().settings.content_opacity)
            else
                content_color;
        },
        else => {},
    }
    return content_color;
}

fn drawTabs(self: *Pane, panel: *PaneGroup, host: *fizzy.Editor.Host, f: *Frame, keywords: []const []const u8) void {
    defer self.processTabsDrag(panel, host, f, keywords);

    // The strip scaffolding — reorder, scroll, per-tab boxes, press/drag handling — is shared
    // with the workbench's document tabs (`core.dvui.Tabs`). What stays here is the part
    // that is actually about *this* strip: which views belong to this grouping, what a tab
    // looks like, and what selecting one means.
    var strip: fizzy.dvui.Tabs = .begin(@src(), &self.tab_state, .{
        .drag_name = drag_name,
        .id_extra = @intCast(self.grouping),
    });
    defer strip.end();

    const active_in_this_group = blk: {
        if (panel.open_pane != self.grouping) break :blk false;
        const active_id = self.active_view_id orelse break :blk false;
        if (panel.paneOf(active_id) != self.grouping) break :blk false;
        break :blk true;
    };

    const active_index = if (active_in_this_group)
        panel.viewIndex(f, keywords, self.active_view_id.?) orelse null
    else
        null;

    for (PaneGroup.surfaces(f, keywords), 0..) |view, i| {
        if (panel.paneOf(view.id) != self.grouping) continue;

        const selected = active_in_this_group and active_index == i;
        var t = strip.tab(@src(), i, selected);
        defer t.end();

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

        if (t.clicked()) {
            self.active_view_id = view.id;
            panel.open_pane = self.grouping;
            host.setActiveBottomView(view.id);
        }
    }

    strip.finalSlot(PaneGroup.surfaces(f, keywords).len);
}

fn drawContent(self: *Pane, panel: *PaneGroup, host: *fizzy.Editor.Host, f: *Frame, keywords: []const []const u8) !void {
    var content_vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = false,
        .id_extra = @intCast(self.grouping),
    });
    defer {
        self.processTabDrag(content_vbox.data(), panel, host, f, keywords);
        content_vbox.deinit();
    }

    const view = panel.activeSurfaceIn(f, keywords, self.grouping) orelse return;
    // Through the frame, so the active surface gets the swap cross-fade every other region does.
    _ = try f.draw(view);
}

fn processTabsDrag(self: *Pane, panel: *PaneGroup, host: *fizzy.Editor.Host, f: *Frame, keywords: []const []const u8) void {
    if (self.tab_state.insert_before_index) |insert_before| {
        if (self.tab_state.removed_index) |removed| {
            if (removed >= PaneGroup.surfaces(f, keywords).len) return;
            if (removed > insert_before) {
                panel.swapSurfaces(host, f, keywords, removed, insert_before);
                self.active_view_id = host.bottom_views.items[insert_before].id;
            } else if (insert_before > 0) {
                panel.swapSurfaces(host, f, keywords, removed, insert_before - 1);
                self.active_view_id = host.bottom_views.items[insert_before - 1].id;
            } else {
                panel.swapSurfaces(host, f, keywords, removed, insert_before);
                self.active_view_id = host.bottom_views.items[insert_before].id;
            }
            self.tab_state.removed_index = null;
            self.tab_state.insert_before_index = null;
        } else {
            for (panel.workspaces.values()) |*workspace| {
                if (workspace.tab_state.removed_index) |removed| {
                    if (removed >= PaneGroup.surfaces(f, keywords).len) return;
                    const view = host.bottom_views.items[removed];
                    if (removed > insert_before) {
                        panel.swapSurfaces(host, f, keywords, removed, insert_before);
                        panel.setViewGrouping(view.id, self.grouping);
                        self.active_view_id = view.id;
                    } else if (insert_before > 0) {
                        panel.swapSurfaces(host, f, keywords, removed, insert_before - 1);
                        panel.setViewGrouping(view.id, self.grouping);
                        self.active_view_id = view.id;
                    } else {
                        panel.swapSurfaces(host, f, keywords, removed, insert_before);
                        panel.setViewGrouping(view.id, self.grouping);
                        self.active_view_id = view.id;
                    }

                    self.tab_state.removed_index = null;
                    self.tab_state.insert_before_index = null;
                    workspace.tab_state.removed_index = null;
                    workspace.tab_state.insert_before_index = null;
                    panel.open_pane = self.grouping;
                    host.setActiveBottomView(view.id);
                    break;
                }
            }
        }
    }
}

fn processTabDrag(self: *Pane, data: *dvui.WidgetData, panel: *PaneGroup, host: *fizzy.Editor.Host, f: *Frame, keywords: []const []const u8) void {
    if (!dvui.dragName(drag_name)) return;

    const drag_src = blk: {
        for (panel.workspaces.values()) |*w| {
            if (w.tab_state.drag_index) |i| break :blk .{ .ws = w, .index = i };
        }
        break :blk null;
    };
    if (drag_src == null) return;
    const workspace = drag_src.?.ws;
    const drag_index = drag_src.?.index;
    if (drag_index >= PaneGroup.surfaces(f, keywords).len) return;
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
                right_side.fill(dvui.CornerRect.Physical.round(right_side.w / 8), .{
                    .color = dvui.themeGet().color(.highlight, .fill).opacity(0.5),
                });
            }

            if (e.evt.mouse.action == .release and e.evt.mouse.button.pointer()) {
                defer workspace.tab_state.drag_index = null;
                e.handle(@src(), data);
                dvui.dragEnd();
                dvui.refresh(null, @src(), data.id);

                const new_g = panel.newPaneId();
                panel.setViewGrouping(dragged_view.id, new_g);
                var new_ws = Pane.init(new_g);
                new_ws.active_view_id = dragged_view.id;
                panel.workspaces.put(fizzy.entry().allocator, new_g, new_ws) catch {};
                panel.open_pane = new_g;
                host.setActiveBottomView(dragged_view.id);
            }
        } else if (data.rectScale().r.contains(e.evt.mouse.p)) {
            if (e.evt.mouse.action == .position) {
                data.rectScale().r.fill(dvui.CornerRect.Physical.round(data.rectScale().r.w / 8), .{
                    .color = dvui.themeGet().color(.highlight, .fill).opacity(0.5),
                });
            }

            if (e.evt.mouse.action == .release and e.evt.mouse.button.pointer()) {
                defer workspace.tab_state.drag_index = null;
                e.handle(@src(), data);
                dvui.dragEnd();
                dvui.refresh(null, @src(), data.id);

                panel.setViewGrouping(dragged_view.id, self.grouping);
                self.active_view_id = dragged_view.id;
                panel.open_pane = self.grouping;
                host.setActiveBottomView(dragged_view.id);
            }
        }
    }
}
