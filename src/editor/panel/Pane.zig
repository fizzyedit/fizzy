//! One pane of fizzy's bottom `Panel`: a workspace-style tab strip plus the surface its
//! active tab selects. Fizzy's own chrome — see `Panel.zig`. The translucent
//! card is the shape's `placeCard` on the Panel region, not a second fill here.
const std = @import("std");

const dvui = @import("dvui");
const fizzy = @import("../../fizzy.zig");

const Panel = @import("Panel.zig");
const Layout = @import("app").layout.Layout;

pub const drag_name = "panel_tab_drag";

pub const Pane = @This();

grouping: u64,
active_view_id: ?[]const u8 = null,

/// Shared with the workbench's document tabs — see `core.widgets.Tabs.TabInfo`. This trio used
/// to be declared identically in both places.
tab_info: fizzy.core.widgets.Tabs.TabInfo = .{},

pub fn init(grouping: u64) Pane {
    return .{ .grouping = grouping };
}

/// Kept for `Panel.draw`'s empty path. A fill belongs on the region's Options.
pub fn drawBackground(_: u64) void {}

pub fn draw(self: *Pane, panel: *Panel, host: *fizzy.Editor.Host, f: *Layout, keywords: []const []const u8) !dvui.App.Result {
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = false,
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

    if (showChooser(f, keywords, self.viewCount(panel, f, keywords))) self.drawTabs(panel, host, f, keywords);
    try self.drawContent(panel, host, f, keywords);

    return .ok;
}

fn viewCount(self: *Pane, panel: *Panel, f: *Layout, keywords: []const []const u8) usize {
    var n: usize = 0;
    for (f.matching(keywords)) |view| {
        if (panel.paneOf(view.id) == self.grouping) n += 1;
    }
    return n;
}

/// Same rule as a place with no custom chrome: a chooser exists only for
/// Multiple with more than one surface. A single Output is just Output.
fn showChooser(f: *Layout, keywords: []const []const u8, count: usize) bool {
    if (count <= 1) return false;
    const r = f.state.regionFor(keywords) orelse return true;
    return r.shows == .many;
}

fn drawTabs(self: *Pane, panel: *Panel, host: *fizzy.Editor.Host, f: *Layout, keywords: []const []const u8) void {
    defer self.processTabsDrag(panel, host, f, keywords);

    // The strip scaffolding — reorder, scroll, per-tab boxes, press/drag handling — is shared
    // with the workbench's document tabs (`core.widgets.Tabs`). What stays here is the part
    // that is actually about *this* strip: which views belong to this grouping, what a tab
    // looks like, and what selecting one means.
    var strip: fizzy.core.widgets.Tabs = .init(@src(), &self.tab_info, .{
        .drag_name = drag_name,
        .id_extra = @intCast(self.grouping),
    });
    defer strip.deinit();

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

    for (f.matching(keywords), 0..) |view, i| {
        if (panel.paneOf(view.id) != self.grouping) continue;

        const selected = active_in_this_group and active_index == i;
        var t = strip.tab(@src(), i, selected);
        defer t.deinit();

        var title_buf: [64]u8 = undefined;
        const title_upper = if (view.title.len <= title_buf.len)
            std.ascii.upperString(&title_buf, view.title)
        else
            view.title;

        dvui.label(@src(), "{s}", .{title_upper}, .{
            .color_text = .{ .color = if (selected) dvui.themeGet().color(.highlight, .fill) else dvui.themeGet().color(.control, .text) },
            .font = dvui.Font.theme(.heading),
            .padding = dvui.Rect.all(4),
            .gravity_y = 0.5,
        });

        if (t.clicked()) {
            self.active_view_id = view.id;
            panel.open_pane = self.grouping;
            host.setSelectionFor(keywords, view.id);
        }
    }

    strip.finalSlot(f.matching(keywords).len);
}

fn drawContent(self: *Pane, panel: *Panel, host: *fizzy.Editor.Host, f: *Layout, keywords: []const []const u8) !void {
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

fn processTabsDrag(self: *Pane, panel: *Panel, host: *fizzy.Editor.Host, f: *Layout, keywords: []const []const u8) void {
    if (self.tab_info.insert_before_index) |insert_before| {
        if (self.tab_info.removed_index) |removed| {
            if (removed >= f.matching(keywords).len) return;
            // The dragged surface ends up under the cursor whichever way the swap goes, so
            // read it before reordering rather than re-indexing the match set afterwards.
            const view = f.matching(keywords)[removed];
            if (removed > insert_before) {
                panel.swapSurfaces(host, f, keywords, removed, insert_before);
            } else if (insert_before > 0) {
                panel.swapSurfaces(host, f, keywords, removed, insert_before - 1);
            } else {
                panel.swapSurfaces(host, f, keywords, removed, insert_before);
            }
            self.active_view_id = view.id;
            self.tab_info.removed_index = null;
            self.tab_info.insert_before_index = null;
        } else {
            for (panel.workspaces.values()) |*workspace| {
                if (workspace.tab_info.removed_index) |removed| {
                    if (removed >= f.matching(keywords).len) return;
                    const view = f.matching(keywords)[removed];
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

                    self.tab_info.removed_index = null;
                    self.tab_info.insert_before_index = null;
                    workspace.tab_info.removed_index = null;
                    workspace.tab_info.insert_before_index = null;
                    panel.open_pane = self.grouping;
                    host.setSelectionFor(keywords, view.id);
                    break;
                }
            }
        }
    }
}

fn processTabDrag(self: *Pane, data: *dvui.WidgetData, panel: *Panel, host: *fizzy.Editor.Host, f: *Layout, keywords: []const []const u8) void {
    if (!dvui.dragName(drag_name)) return;

    const drag_src = blk: {
        for (panel.workspaces.values()) |*w| {
            if (w.tab_info.drag_index) |i| break :blk .{ .ws = w, .index = i };
        }
        break :blk null;
    };
    if (drag_src == null) return;
    const workspace = drag_src.?.ws;
    const drag_index = drag_src.?.index;
    if (drag_index >= f.matching(keywords).len) return;
    const dragged_view = f.matching(keywords)[drag_index];

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
                    .color = .{ .color = dvui.themeGet().color(.highlight, .fill).opacity(0.5) },
                });
            }

            if (e.evt.mouse.action == .release and e.evt.mouse.button.pointer()) {
                defer workspace.tab_info.drag_index = null;
                e.handle(@src(), data);
                dvui.dragEnd();
                dvui.refresh(null, @src(), data.id);

                const new_g = panel.newPaneId();
                panel.setViewGrouping(dragged_view.id, new_g);
                var new_ws = Pane.init(new_g);
                new_ws.active_view_id = dragged_view.id;
                panel.workspaces.put(fizzy.entry().allocator, new_g, new_ws) catch {};
                panel.open_pane = new_g;
                host.setSelectionFor(keywords, dragged_view.id);
            }
        } else if (data.rectScale().r.contains(e.evt.mouse.p)) {
            if (e.evt.mouse.action == .position) {
                data.rectScale().r.fill(dvui.CornerRect.Physical.round(data.rectScale().r.w / 8), .{
                    .color = .{ .color = dvui.themeGet().color(.highlight, .fill).opacity(0.5) },
                });
            }

            if (e.evt.mouse.action == .release and e.evt.mouse.button.pointer()) {
                defer workspace.tab_info.drag_index = null;
                e.handle(@src(), data);
                dvui.dragEnd();
                dvui.refresh(null, @src(), data.id);

                panel.setViewGrouping(dragged_view.id, self.grouping);
                self.active_view_id = dragged_view.id;
                panel.open_pane = self.grouping;
                host.setSelectionFor(keywords, dragged_view.id);
            }
        }
    }
}
