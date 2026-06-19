const std = @import("std");
const builtin = @import("builtin");

const wb = @import("../workbench.zig");
const dvui = wb.dvui;
const wdvui = wb.wdvui;
const sdk = wb.sdk;
const Globals = @import("Globals.zig");
const icons = @import("icons");

/// Workspaces are drawn recursively inside of the explorer paned widget
/// second pane, and contains drag/drop enabled tabs. Tabs can freely be dragged to
/// panes or other tab bars.
/// Workspaces can potentially draw open files, the project logo, or the project pane
/// containing the packed atlas.
pub const Workspace = @This();

open_file_index: usize = 0,
grouping: u64 = 0,
center: bool = false,

tabs_drag_index: ?usize = null,
tabs_removed_index: ?usize = null,
tabs_insert_before_index: ?usize = null,

/// Physical-pixel content rect of this workspace's canvas vbox, captured each frame during
/// `drawCanvas` (or a sidebar view's `draw_workspace` takeover, e.g. pixel art's Project view).
/// `null` until the workspace has rendered at least once. Used
/// by the editor-level load/save toast overlays to center cards over the area the user is
/// actually looking at (rather than the OS window rect).
canvas_rect_physical: ?dvui.Rect.Physical = null,

pub fn init(grouping: u64) Workspace {
    return .{ .grouping = grouping };
}

/// Release any plugin-owned per-pane canvas chrome. Called when a pane is removed
/// (`Editor.rebuildWorkspaces`) and for each pane at editor shutdown.
pub fn deinit(self: *Workspace) void {
    for (Globals.host.plugins.items) |plugin| {
        plugin.removeCanvasPane(self.grouping, Globals.allocator());
    }
}

const handle_size = 10;
const handle_dist = 60;

const opacity = 60;

const color_0 = wb.math.Color.initBytes(0, 0, 0, 0);
const color_1 = wb.math.Color.initBytes(230, 175, 137, opacity);
const color_2 = wb.math.Color.initBytes(216, 145, 115, opacity);
const color_3 = wb.math.Color.initBytes(41, 23, 41, opacity);
const color_4 = wb.math.Color.initBytes(194, 109, 92, opacity);
const color_5 = wb.math.Color.initBytes(180, 89, 76, opacity);

const logo_colors: [12]wb.math.Color = [_]wb.math.Color{
    color_1, color_1, color_1,
    color_2, color_2, color_3,
    color_4, color_3, color_0,
    color_3, color_0, color_0,
};

var dragging: bool = false;

pub fn draw(self: *Workspace) !dvui.App.Result {
    // Canvas Area
    var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .gravity_y = 0.0,
        .id_extra = @intCast(self.grouping),
    });
    defer vbox.deinit();

    // Set the active workspace grouping when the user clicks on the workspace rect
    for (dvui.events()) |*e| {
        if (!vbox.matchEvent(e)) {
            continue;
        }

        if (e.evt == .mouse) {
            if (e.evt.mouse.action == .press or (e.evt.mouse.action == .position and e.evt.mouse.mod.matchBind("ctrl/cmd"))) {
                Globals.workbench.open_workspace_grouping = self.grouping;
            }
        }
    }

    // A sidebar view may optionally take over this workspace pane's content region (e.g. pixel
    // art's "Project" view renders the packed atlas here instead of document tabs+canvas). The
    // workbench owns only the pane frame; it hands the active view the opaque workspace handle.
    const active = Globals.host.activeSidebarView();
    if (active != null and active.?.draw_workspace != null) {
        var pane_view: sdk.WorkbenchPaneView = .{
            .grouping = self.grouping,
            .canvas_rect_physical = &self.canvas_rect_physical,
        };
        try active.?.draw_workspace.?(active.?.ctx, &pane_view);
    } else {
        self.drawTabs();
        try self.drawCanvas();
    }

    return .ok;
}

/// Same `@src()` for every call so DVUI sees one stable id when switching between `drawCanvas` and
/// a plugin's `draw_workspace` takeover (avoids first-frame min-size / layout flash). Use `grouping`
/// so multi-workspace panes stay distinct. Delegates to `sdk.pane_layout` for a single definition.
pub fn workspaceMainCanvasVbox(content_color: dvui.Color, background: bool, grouping: u64) *dvui.BoxWidget {
    return sdk.pane_layout.mainCanvasVbox(content_color, background, grouping);
}

/// Rounded “card” behind the project empty state and the homepage. Delegates to `sdk.pane_layout`.
pub fn workspaceEmptyStateCard(content_color: dvui.Color, grouping: u64) *dvui.BoxWidget {
    return sdk.pane_layout.emptyStateCard(content_color, grouping);
}

fn drawTabs(self: *Workspace) void {
    if (Globals.host.openDocCount() == 0) return;

    // Handle dragging of tabs between workspace reorderables (tab bars)
    defer self.processTabsDrag();

    {
        var tabs_anim = dvui.animate(@src(), .{ .duration = 500_000, .kind = .vertical, .easing = dvui.easing.outBack }, .{});
        defer tabs_anim.deinit();

        var tabs_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .none,
            .id_extra = @intCast(self.grouping),
        });
        defer tabs_box.deinit();

        var scroll_area = dvui.scrollArea(@src(), .{ .horizontal = .auto, .horizontal_bar = .hide, .vertical_bar = .hide }, .{
            .expand = .none,
            .background = false,
            .corner_radius = dvui.Rect.all(0),
            .id_extra = @intCast(self.grouping),
        });
        defer scroll_area.deinit();

        {
            var tabs = dvui.reorder(@src(), .{ .drag_name = "tab_drag" }, .{
                .expand = .none,
                .background = false,
            });
            defer tabs.deinit();

            var tabs_hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .none,
                .id_extra = @intCast(self.grouping),
            });
            defer tabs_hbox.deinit();

            const files_len = Globals.host.openDocCount();

            // Find the neighbouring tabs (within this workspace grouping) of the active tab.
            var prev_same_group_index: ?usize = null;
            var next_same_group_index: ?usize = null;

            const active_in_this_group = blk: {
                if (Globals.workbench.open_workspace_grouping != self.grouping) break :blk false;
                if (self.open_file_index >= files_len) break :blk false;
                const active_doc = Globals.host.docByIndex(self.open_file_index) orelse break :blk false;
                if (active_doc.owner.documentGrouping(active_doc) != self.grouping) break :blk false;
                break :blk true;
            };

            if (active_in_this_group) {
                const active_index = self.open_file_index;

                var j: usize = active_index;
                while (j > 0) {
                    j -= 1;
                    const tab_doc = Globals.host.docByIndex(j) orelse continue;
                    if (tab_doc.owner.documentGrouping(tab_doc) == self.grouping) {
                        prev_same_group_index = j;
                        break;
                    }
                }

                j = active_index + 1;
                while (j < files_len) : (j += 1) {
                    const tab_doc = Globals.host.docByIndex(j) orelse continue;
                    if (tab_doc.owner.documentGrouping(tab_doc) == self.grouping) {
                        next_same_group_index = j;
                        break;
                    }
                }
            }

            for (0..files_len) |i| {
                const doc = Globals.host.docByIndex(i) orelse continue;
                const is_fizzy_file = doc.owner.documentHasNativeExtension(doc);

                if (doc.owner.documentGrouping(doc) != self.grouping) continue;

                var reorderable = tabs.reorderable(@src(), .{}, .{
                    .expand = .vertical,
                    .id_extra = i,
                    .padding = dvui.Rect.all(0),
                    .margin = dvui.Rect.all(0),
                });
                defer reorderable.deinit();

                const selected = self.open_file_index == i and Globals.workbench.open_workspace_grouping == self.grouping;

                var anim = dvui.animate(@src(), .{ .duration = 400_000, .kind = .horizontal, .easing = dvui.easing.outBack }, .{});
                defer anim.deinit();

                var hbox: dvui.BoxWidget = undefined;
                hbox.init(@src(), .{ .dir = .horizontal }, .{
                    .expand = .none,
                    .border = .all(0),
                    .color_fill = if (selected) .transparent else dvui.themeGet().color(.window, .fill).opacity(Globals.host.contentOpacity()),
                    .background = true,
                    .id_extra = i,
                    .padding = dvui.Rect.all(2),
                    .margin = dvui.Rect.all(0),
                });

                defer hbox.deinit();

                const tab_hovered = wdvui.hovered(hbox.data());

                if (selected) {
                    if (!reorderable.floating()) {
                        dvui.Path.stroke(.{
                            .points = &.{
                                hbox.data().rectScale().r.bottomLeft(),
                                hbox.data().rectScale().r.bottomRight(),
                            },
                        }, .{
                            .color = dvui.themeGet().color(.window, .text),
                            .thickness = 1,
                        });
                    }
                }

                if (reorderable.floating()) {
                    self.tabs_drag_index = i;
                    hbox.data().options.color_fill = dvui.themeGet().color(.control, .fill);
                }
                hbox.drawBackground();

                if (!selected and active_in_this_group and tabs.drag_point == null) {
                    // Draw edge shadow between the active tab and its neighbours within this grouping.
                    if (prev_same_group_index) |prev_index| {
                        if (i == prev_index) {
                            // This tab is directly to the left of the active tab.
                            wdvui.drawEdgeShadow(hbox.data().rectScale(), .right, .{});
                        }
                    }

                    if (next_same_group_index) |next_index| {
                        if (i == next_index) {
                            // This tab is directly to the right of the active tab.
                            wdvui.drawEdgeShadow(hbox.data().rectScale(), .left, .{});
                        }
                    }
                }

                if (reorderable.removed()) {
                    self.tabs_removed_index = i;
                } else if (reorderable.insertBefore()) {
                    self.tabs_insert_before_index = i;
                }

                if (is_fizzy_file) {
                    const ui_atlas = Globals.host.uiAtlas();
                    const ui_sprite = ui_atlas.sprites[wb.atlas.sprites.logo_default];
                    const logo_sprite = wb.Sprite{ .origin = ui_sprite.origin, .source = ui_sprite.source };
                    _ = wb.Sprite.draw(logo_sprite, @src(), ui_atlas.source, 2.0, .{
                        .gravity_y = 0.5,
                        .padding = dvui.Rect.all(4),
                    });
                } else {
                    dvui.icon(@src(), "file_icon", icons.tvg.lucide.file, .{
                        .stroke_color = if (is_fizzy_file) .transparent else dvui.themeGet().color(.control, .text),
                    }, .{
                        .gravity_y = 0.5,
                        .padding = dvui.Rect.all(4),
                    });
                }

                dvui.label(@src(), "{s}", .{std.fs.path.basename(doc.owner.documentPath(doc))}, .{
                    .color_text = if (selected) dvui.themeGet().color(.window, .text) else dvui.themeGet().color(.control, .text),
                    .padding = dvui.Rect.all(4),
                    .gravity_y = 0.5,
                });

                const close_inner = wdvui.windowHeaderCloseInnerSide();
                const close_pad = wdvui.window_header_close_margin;
                const tab_status_slot = close_inner + close_pad.x + close_pad.w;

                const status_close_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .none,
                    .gravity_y = 0.5,
                    .min_size_content = .{ .w = tab_status_slot, .h = tab_status_slot },
                });
                defer status_close_box.deinit();

                // Saving has priority over hover/close/dirty indicators: the user wants visible
                // confirmation that the save is in flight, and the slot's size matches the close
                // button so the layout doesn't shift when saving starts/ends. `editor.saving`
                // can be written by a background save worker (`saveZip`), so we read it with an
                // atomic load — the write side uses an atomic store in matching `save*` paths.
                const save_flash_elapsed = doc.owner.timeSinceSaveCompleteNs(doc);
                const save_in_check_phase = if (save_flash_elapsed) |elapsed|
                    wdvui.bubbleSpinnerSaveInCheckPhase(elapsed)
                else
                    false;
                const save_blocks_tab_close = doc.owner.isDocumentSaving(doc) or
                    (doc.owner.showsSaveStatusIndicator(doc) and !save_in_check_phase);

                if (save_blocks_tab_close) {
                    wdvui.bubbleSpinner(@src(), .{
                        .id_extra = i *% 16 + 5,
                        .expand = .none,
                        .min_size_content = .{ .w = close_inner, .h = close_inner },
                        .gravity_x = 0.5,
                        .gravity_y = 0.5,
                        .color_text = dvui.themeGet().color(.window, .text),
                    }, .{
                        .complete_elapsed_ns = save_flash_elapsed,
                    });
                } else if (save_in_check_phase and !tab_hovered) {
                    wdvui.bubbleSpinner(@src(), .{
                        .id_extra = i *% 16 + 5,
                        .expand = .none,
                        .min_size_content = .{ .w = close_inner, .h = close_inner },
                        .gravity_x = 0.5,
                        .gravity_y = 0.5,
                        .color_text = dvui.themeGet().color(.window, .text),
                    }, .{
                        .complete_elapsed_ns = save_flash_elapsed,
                    });
                } else if (tab_hovered) {
                    var tab_close_button: dvui.ButtonWidget = undefined;
                    tab_close_button.init(@src(), .{ .draw_focus = false }, wdvui.windowHeaderCloseButtonOptions(.{
                        .expand = .none,
                        .min_size_content = .{ .w = close_inner, .h = close_inner },
                        .id_extra = i *% 16 + 1,
                    }));
                    defer tab_close_button.deinit();

                    tab_close_button.processEvents();
                    tab_close_button.drawBackground();
                    tab_close_button.drawFocus();

                    if (tab_close_button.hovered()) {
                        dvui.icon(@src(), "close", icons.tvg.lucide.x, .{
                            .stroke_color = dvui.themeGet().color(.err, .fill).lighten(if (dvui.themeGet().dark) -10 else 10),
                            .fill_color = dvui.themeGet().color(.err, .fill).lighten(if (dvui.themeGet().dark) -10 else 10),
                        }, .{
                            .expand = .ratio,
                            .gravity_x = 0.5,
                            .gravity_y = 0.5,
                            .id_extra = i *% 16 + 2,
                        });
                    }

                    if (tab_close_button.clicked()) {
                        Globals.host.closeDocById(doc.id) catch |err| {
                            dvui.log.err("closeFile: {d} failed: {s}", .{ i, @errorName(err) });
                        };
                        break;
                    }
                } else if (selected and !doc.owner.isDirty(doc)) {
                    const tab_text = dvui.themeGet().color(.window, .text);
                    var ghost_close: dvui.ButtonWidget = undefined;
                    ghost_close.init(@src(), .{ .draw_focus = false }, wdvui.windowHeaderCloseButtonOptions(.{
                        .expand = .none,
                        .min_size_content = .{ .w = close_inner, .h = close_inner },
                        .id_extra = i *% 16 + 3,
                        .style = .window,
                        .background = false,
                        .box_shadow = null,
                        .border = .all(0),
                        .color_fill = .transparent,
                        .color_fill_hover = .transparent,
                        .color_fill_press = .transparent,
                        .ninepatch_fill = &dvui.Ninepatch.none,
                        .ninepatch_hover = &dvui.Ninepatch.none,
                        .ninepatch_press = &dvui.Ninepatch.none,
                    }));
                    defer ghost_close.deinit();

                    ghost_close.processEvents();
                    // Invisible hit target only — `drawBackground` would run theme ninepatch.

                    dvui.icon(@src(), "close", icons.tvg.lucide.x, .{
                        .stroke_color = tab_text,
                        .fill_color = tab_text,
                    }, .{
                        .expand = .ratio,
                        .gravity_x = 0.5,
                        .gravity_y = 0.5,
                        .id_extra = i *% 16 + 4,
                        .background = false,
                        .border = .all(0),
                        .box_shadow = null,
                        .ninepatch_fill = &dvui.Ninepatch.none,
                        .ninepatch_hover = &dvui.Ninepatch.none,
                        .ninepatch_press = &dvui.Ninepatch.none,
                    });

                    if (ghost_close.clicked()) {
                        Globals.host.closeDocById(doc.id) catch |err| {
                            dvui.log.err("closeFile: {d} failed: {s}", .{ i, @errorName(err) });
                        };
                        break;
                    }
                } else if (doc.owner.isDirty(doc)) {
                    dvui.icon(@src(), "dirty_icon", icons.tvg.lucide.@"circle-small", .{
                        .stroke_color = dvui.themeGet().color(.window, .text),
                    }, .{
                        .gravity_x = 0.5,
                        .gravity_y = 0.5,
                        .padding = dvui.Rect.all(2),
                        .id_extra = i *% 16 + 0,
                    });
                }

                loop: for (dvui.events()) |*e| {
                    if (!hbox.matchEvent(e)) {
                        continue;
                    }

                    switch (e.evt) {
                        .mouse => |me| {
                            if (me.action == .press and me.button.pointer()) {
                                Globals.host.setActiveDocIndex(i);
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
                                        reorderable.reorder.dragStart(reorderable.data().id.asUsize(), me.p, 0); // reorder grabs capture
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
                self.tabs_insert_before_index = Globals.host.openDocCount();
            }
        }
    }
}

pub fn processTabsDrag(self: *Workspace) void {
    if (self.tabs_insert_before_index) |insert_before| {
        if (self.tabs_removed_index) |removed| { // Dragging from this workspace

            if (removed > Globals.host.openDocCount()) return;
            if (removed > insert_before) {
                Globals.host.swapDocs(removed, insert_before);
                Globals.host.setActiveDocIndex(insert_before);
            } else {
                if (insert_before > 0) {
                    Globals.host.swapDocs(removed, insert_before - 1);
                    Globals.host.setActiveDocIndex(insert_before - 1);
                } else {
                    Globals.host.swapDocs(removed, insert_before);
                    Globals.host.setActiveDocIndex(insert_before);
                }
            }

            self.tabs_removed_index = null;
            self.tabs_insert_before_index = null;
        } else { // Dragging from another workspace
            for (Globals.workbench.workspaces.values()) |*workspace| {
                if (workspace.tabs_removed_index) |removed| {
                    if (removed > insert_before) {
                        Globals.host.swapDocs(removed, insert_before);
                        if (Globals.host.docByIndex(insert_before)) |d| {
                            d.owner.setDocumentGrouping(d, self.grouping);
                        }
                        Globals.host.setActiveDocIndex(insert_before);
                    } else {
                        if (insert_before > 0) {
                            Globals.host.swapDocs(removed, insert_before - 1);
                            if (Globals.host.docByIndex(insert_before - 1)) |d| {
                                d.owner.setDocumentGrouping(d, self.grouping);
                            }
                            Globals.host.setActiveDocIndex(insert_before - 1);
                        } else {
                            Globals.host.swapDocs(removed, insert_before);
                            if (Globals.host.docByIndex(insert_before)) |d| {
                                d.owner.setDocumentGrouping(d, self.grouping);
                            }
                            Globals.host.setActiveDocIndex(insert_before);
                        }
                    }

                    self.tabs_removed_index = null;
                    self.tabs_insert_before_index = null;

                    workspace.tabs_removed_index = null;
                    workspace.tabs_insert_before_index = null;
                }
            }
        }
    }
}

/// Repoint `open_file_index` on workspaces that were showing the dragged tab as active.
fn repointWorkspacesAfterTabDrag(tab_bar_workspace: ?*Workspace, drag_index: usize) void {
    const dragged_doc = Globals.host.docByIndex(drag_index) orelse return;
    if (tab_bar_workspace) |workspace| {
        if (workspace.open_file_index == Globals.host.docIndex(dragged_doc.id)) {
            var i: usize = 0;
            while (i < Globals.host.openDocCount()) : (i += 1) {
                const doc = Globals.host.docByIndex(i).?;
                if (doc.owner.documentGrouping(doc) == workspace.grouping and doc.id != dragged_doc.id) {
                    workspace.open_file_index = i;
                    break;
                }
            }
        }
    } else {
        for (Globals.workbench.workspaces.values()) |*w| {
            if (w.open_file_index == drag_index) {
                var i: usize = 0;
                while (i < Globals.host.openDocCount()) : (i += 1) {
                    const doc = Globals.host.docByIndex(i).?;
                    if (doc.owner.documentGrouping(doc) == w.grouping and doc.id != dragged_doc.id) {
                        w.open_file_index = i;
                        break;
                    }
                }
            }
        }
    }
}

const WorkspaceTabDragSrc = union(enum) {
    tab_bar: struct { ws: *Workspace, index: usize },
    tree_open: usize,
    tree_closed: []const u8,
    none,

    fn resolve() WorkspaceTabDragSrc {
        for (Globals.workbench.workspaces.values()) |*w| {
            if (w.tabs_drag_index) |i| return .{ .tab_bar = .{ .ws = w, .index = i } };
        }
        if (Globals.workbench.tab_drag_from_tree_path) |p| {
            var i: usize = 0;
            while (i < Globals.host.openDocCount()) : (i += 1) {
                const doc = Globals.host.docByIndex(i).?;
                if (doc.owner.documentByPath(p) != null) {
                    return .{ .tree_open = i };
                }
            }
            return .{ .tree_closed = p };
        }
        return .none;
    }
};

/// Responsible for handling the cross-widget drag of tabs between multiple workspaces or between tabs and workspaces.
/// Also handles the same `tab_drag` from the Files tree (see `files.zig` + DVUI reorder_tree cross-widget pattern).
pub fn processTabDrag(self: *Workspace, data: *dvui.WidgetData) void {
    if (!dvui.dragName("tab_drag")) {
        Globals.workbench.clearFileTreeTabDragDropState();
        return;
    }

    const drag_src = WorkspaceTabDragSrc.resolve();
    switch (drag_src) {
        .none => return,
        else => {},
    }

    events_loop: for (dvui.events()) |*e| {
        if (!dvui.eventMatch(e, .{ .id = data.id, .r = data.rectScale().r, .drag_name = "tab_drag" })) continue;

        switch (drag_src) {
            .none => unreachable,
            .tab_bar => |tb| {
                const workspace = tb.ws;
                const drag_index = tb.index;

                var right_side = data.rectScale().r;
                right_side.w /= 2;
                right_side.x += right_side.w;

                if (right_side.contains(e.evt.mouse.p) and Globals.workbench.workspaces.keys()[Globals.workbench.workspaces.keys().len - 1] == self.grouping) {
                    if (e.evt == .mouse and e.evt.mouse.action == .position) {
                        right_side.fill(dvui.Rect.Physical.all(right_side.w / 8), .{
                            .color = dvui.themeGet().color(.highlight, .fill).opacity(0.5),
                        });
                    }

                    if (e.evt == .mouse and e.evt.mouse.action == .release and e.evt.mouse.button.pointer()) {
                        defer workspace.tabs_drag_index = null;
                        e.handle(@src(), data);
                        dvui.dragEnd();
                        dvui.refresh(null, @src(), data.id);
                        Globals.workbench.clearFileTreeTabDragDropState();

                        repointWorkspacesAfterTabDrag(workspace, drag_index);
                        const dragged_doc = Globals.host.docByIndex(drag_index) orelse continue;
                        const new_g = Globals.workbench.newGroupingID();
                        dragged_doc.owner.setDocumentGrouping(dragged_doc, new_g);
                        Globals.workbench.open_workspace_grouping = new_g;
                    }
                } else if (data.rectScale().r.contains(e.evt.mouse.p)) {
                    if (e.evt == .mouse and e.evt.mouse.action == .position) {
                        data.rectScale().r.fill(dvui.Rect.Physical.all(data.rectScale().r.w / 8), .{
                            .color = dvui.themeGet().color(.highlight, .fill).opacity(0.5),
                        });
                    }

                    if (e.evt == .mouse and e.evt.mouse.action == .release and e.evt.mouse.button.pointer()) {
                        defer workspace.tabs_drag_index = null;
                        e.handle(@src(), data);
                        dvui.dragEnd();
                        dvui.refresh(null, @src(), data.id);
                        Globals.workbench.clearFileTreeTabDragDropState();

                        repointWorkspacesAfterTabDrag(workspace, drag_index);
                        const dragged_doc = Globals.host.docByIndex(drag_index) orelse continue;
                        dragged_doc.owner.setDocumentGrouping(dragged_doc, self.grouping);
                        Globals.workbench.open_workspace_grouping = self.grouping;
                        self.open_file_index = Globals.host.docIndex(dragged_doc.id) orelse 0;
                    }
                }
            },
            .tree_open => |drag_index| {
                var right_side = data.rectScale().r;
                right_side.w /= 2;
                right_side.x += right_side.w;

                if (right_side.contains(e.evt.mouse.p) and Globals.workbench.workspaces.keys()[Globals.workbench.workspaces.keys().len - 1] == self.grouping) {
                    if (e.evt == .mouse and e.evt.mouse.action == .position) {
                        right_side.fill(dvui.Rect.Physical.all(right_side.w / 8), .{
                            .color = dvui.themeGet().color(.highlight, .fill).opacity(0.5),
                        });
                    }

                    if (e.evt == .mouse and e.evt.mouse.action == .release and e.evt.mouse.button.pointer()) {
                        e.handle(@src(), data);
                        dvui.dragEnd();
                        dvui.refresh(null, @src(), data.id);
                        Globals.workbench.clearFileTreeTabDragDropState();

                        repointWorkspacesAfterTabDrag(null, drag_index);
                        const dragged_doc = Globals.host.docByIndex(drag_index) orelse continue;
                        const new_g = Globals.workbench.newGroupingID();
                        dragged_doc.owner.setDocumentGrouping(dragged_doc, new_g);
                        Globals.workbench.open_workspace_grouping = new_g;
                    }
                } else if (data.rectScale().r.contains(e.evt.mouse.p)) {
                    if (e.evt == .mouse and e.evt.mouse.action == .position) {
                        data.rectScale().r.fill(dvui.Rect.Physical.all(data.rectScale().r.w / 8), .{
                            .color = dvui.themeGet().color(.highlight, .fill).opacity(0.5),
                        });
                    }

                    if (e.evt == .mouse and e.evt.mouse.action == .release and e.evt.mouse.button.pointer()) {
                        e.handle(@src(), data);
                        dvui.dragEnd();
                        dvui.refresh(null, @src(), data.id);
                        Globals.workbench.clearFileTreeTabDragDropState();

                        repointWorkspacesAfterTabDrag(null, drag_index);
                        const dragged_doc = Globals.host.docByIndex(drag_index) orelse continue;
                        dragged_doc.owner.setDocumentGrouping(dragged_doc, self.grouping);
                        Globals.workbench.open_workspace_grouping = self.grouping;
                        self.open_file_index = Globals.host.docIndex(dragged_doc.id) orelse 0;
                    }
                }
            },
            .tree_closed => |path| {
                var right_side = data.rectScale().r;
                right_side.w /= 2;
                right_side.x += right_side.w;

                if (right_side.contains(e.evt.mouse.p) and Globals.workbench.workspaces.keys()[Globals.workbench.workspaces.keys().len - 1] == self.grouping) {
                    if (e.evt == .mouse and e.evt.mouse.action == .position) {
                        right_side.fill(dvui.Rect.Physical.all(right_side.w / 8), .{
                            .color = dvui.themeGet().color(.highlight, .fill).opacity(0.5),
                        });
                    }

                    if (e.evt == .mouse and e.evt.mouse.action == .release and e.evt.mouse.button.pointer()) {
                        e.handle(@src(), data);
                        dvui.dragEnd();
                        dvui.refresh(null, @src(), data.id);
                        const new_g = Globals.workbench.newGroupingID();
                        const maybe_idx = Globals.host.openOrFocusFileAtGrouping(path, new_g) catch {
                            Globals.workbench.clearFileTreeTabDragDropState();
                            continue :events_loop;
                        };
                        if (maybe_idx) |idx| {
                            // File was already open and moved between groupings — repoint the
                            // workspaces that were showing it, and focus the new pane now.
                            repointWorkspacesAfterTabDrag(null, idx);
                            Globals.workbench.open_workspace_grouping = new_g;
                        }
                        // Else: async load — leave `open_workspace_grouping` alone. Switching
                        // to the not-yet-extant workspace would make `activeFile()` null and
                        // collapse the bottom panel mid-load; `processLoadingJobs` will focus
                        // the new pane once the worker lands the file, matching the
                        // "Open to the side" menu action.
                        Globals.workbench.clearFileTreeTabDragDropState();
                    }
                } else if (data.rectScale().r.contains(e.evt.mouse.p)) {
                    if (e.evt == .mouse and e.evt.mouse.action == .position) {
                        data.rectScale().r.fill(dvui.Rect.Physical.all(data.rectScale().r.w / 8), .{
                            .color = dvui.themeGet().color(.highlight, .fill).opacity(0.5),
                        });
                    }

                    if (e.evt == .mouse and e.evt.mouse.action == .release and e.evt.mouse.button.pointer()) {
                        e.handle(@src(), data);
                        dvui.dragEnd();
                        dvui.refresh(null, @src(), data.id);
                        const maybe_idx = Globals.host.openOrFocusFileAtGrouping(path, self.grouping) catch {
                            Globals.workbench.clearFileTreeTabDragDropState();
                            continue :events_loop;
                        };
                        if (maybe_idx) |idx| {
                            repointWorkspacesAfterTabDrag(null, idx);
                            self.open_file_index = idx;
                        }
                        // Else: async load into this workspace's existing grouping. The
                        // worker's `processLoadingJobs` focus handler will set the active
                        // file once it lands.
                        Globals.workbench.clearFileTreeTabDragDropState();
                    }
                }
            },
        }
    }
}

pub fn drawCanvas(self: *Workspace) !void {
    var content_color = dvui.themeGet().color(.window, .fill);

    switch (builtin.os.tag) {
        .macos => {
            content_color = if (!Globals.host.isMaximized()) content_color.opacity(Globals.host.contentOpacity()) else content_color;
        },
        .windows => {
            content_color = if (!Globals.host.isMaximized()) content_color.opacity(Globals.host.contentOpacity()) else content_color;
        },
        else => {},
    }

    const has_files = Globals.host.openDocCount() > 0;

    var canvas_vbox = workspaceMainCanvasVbox(content_color, has_files, self.grouping);
    defer {
        self.canvas_rect_physical = canvas_vbox.data().contentRectScale().r;
        dvui.toastsShow(canvas_vbox.data().id, canvas_vbox.data().contentRectScale().r.toNatural());
        canvas_vbox.deinit();
    }
    defer self.processTabDrag(canvas_vbox.data());

    if (has_files) {
        if (self.open_file_index >= Globals.host.openDocCount()) {
            self.open_file_index = Globals.host.openDocCount() - 1;
        }

        if (Globals.host.docByIndex(self.open_file_index)) |doc| {
        doc.owner.bindDocumentToPane(doc, canvas_vbox.data().id, self, self.center);
        _ = try doc.owner.drawDocument(doc);
        }
    } else {
        var box = workspaceEmptyStateCard(content_color, self.grouping);
        defer box.deinit();

        // Make sure alpha is 1 before we draw the homepage, as the logo hover animation breaks if alpha is not 1
        const alpha = dvui.alpha(1.0);
        dvui.alphaSet(1.0);
        defer dvui.alphaSet(alpha);

        try self.drawHomePage(canvas_vbox);
    }
}

pub fn drawHomePage(_: *Workspace, canvas_vbox: *dvui.BoxWidget) !void {
    const logo_pixel_size = 32;
    const logo_width = 3;
    const logo_height = 5;

    const logo_vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .none,
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .background = false,
        .padding = dvui.Rect.all(10),
    });
    defer logo_vbox.deinit();

    { // Logo

        const vbox2 = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .none,
            .gravity_x = 0.5,
            .min_size_content = .{ .w = logo_pixel_size * logo_width, .h = logo_pixel_size * logo_height },
            .padding = dvui.Rect.all(20),
        });
        defer vbox2.deinit();

        for (0..4) |i| {
            const hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .none,
                .min_size_content = .{ .w = logo_pixel_size * logo_width, .h = logo_pixel_size },
                .margin = dvui.Rect.all(0),
                .padding = dvui.Rect.all(0),
                .id_extra = i,
            });
            defer hbox.deinit();

            for (0..3) |j| {
                const index = i * logo_width + j;
                var fizzy_color = logo_colors[index];

                if (fizzy_color.value[3] < 1.0 and fizzy_color.value[3] > 0.0) {
                    const theme_bg = dvui.themeGet().color(.window, .fill);
                    fizzy_color = fizzy_color.lerp(wb.math.Color.initBytes(theme_bg.r, theme_bg.g, theme_bg.b, 255), fizzy_color.value[3]);
                    fizzy_color.value[3] = 1.0;
                }

                const color = fizzy_color.bytes();

                const pixel = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .none,
                    .min_size_content = .{ .w = logo_pixel_size, .h = logo_pixel_size },
                    .id_extra = index,
                    .background = false,
                    .color_fill = .{ .r = color[0], .g = color[1], .b = color[2], .a = color[3] },
                    .margin = dvui.Rect.all(0),
                    .padding = dvui.Rect.all(0),
                });

                const rect = pixel.data().rect.outset(.{ .x = 0, .y = 0 });
                const rs = pixel.data().rectScale();
                pixel.deinit();

                if (fizzy_color.value[3] <= 0.0) continue;

                try drawBubble(rect, rs, color, index);
            }
        }
    }

    var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .none,
        .gravity_x = 0.5,
    });

    {
        var button: dvui.ButtonWidget = undefined;
        button.init(@src(), .{ .draw_focus = true }, .{
            .gravity_x = 0.5,
            .expand = .horizontal,
            .padding = dvui.Rect.all(2),
            .color_fill = .transparent,
            .color_fill_hover = dvui.themeGet().color(.window, .fill_hover),
            .color_fill_press = dvui.themeGet().color(.window, .fill_press),
        });
        defer button.deinit();

        button.processEvents();
        button.drawBackground();

        wdvui.labelWithKeybind(
            "New File",
            dvui.currentWindow().keybinds.get("new_file") orelse .{},
            true,
            .{ .padding = dvui.Rect.all(4), .expand = .horizontal, .gravity_x = 1.0 },
            .{ .padding = dvui.Rect.all(4), .expand = .horizontal, .gravity_x = 1.0 },
        );

        if (button.clicked()) {
            Globals.host.requestNewDocument(null, 0);
        }
    }
    {
        var button: dvui.ButtonWidget = undefined;
        button.init(@src(), .{ .draw_focus = true }, .{
            .gravity_x = 0.5,
            .expand = .horizontal,
            .padding = dvui.Rect.all(2),
            .color_fill = .transparent,
            .color_fill_hover = dvui.themeGet().color(.window, .fill_hover),
            .color_fill_press = dvui.themeGet().color(.window, .fill_press),
        });
        defer button.deinit();

        button.processEvents();
        button.drawBackground();

        wdvui.labelWithKeybind(
            "Open Folder",
            dvui.currentWindow().keybinds.get("open_folder") orelse .{},
            true,
            .{ .padding = dvui.Rect.all(4), .expand = .horizontal, .gravity_x = 1.0 },
            .{ .padding = dvui.Rect.all(4), .expand = .horizontal, .gravity_x = 1.0 },
        );

        if (button.clicked()) {
            Globals.host.showOpenFolderDialog(setProjectFolderCallback, null);
        }
    }

    {
        var button: dvui.ButtonWidget = undefined;
        button.init(@src(), .{ .draw_focus = true }, .{
            .gravity_x = 0.5,
            .expand = .horizontal,
            .padding = dvui.Rect.all(2),
            .color_fill = .transparent,
            .color_fill_hover = dvui.themeGet().color(.window, .fill_hover),
            .color_fill_press = dvui.themeGet().color(.window, .fill_press),
        });
        defer button.deinit();

        button.processEvents();
        button.drawBackground();

        wdvui.labelWithKeybind(
            "Open Files",
            dvui.currentWindow().keybinds.get("open_files") orelse .{},
            true,
            .{ .padding = dvui.Rect.all(4), .expand = .horizontal, .gravity_x = 1.0 },
            .{ .padding = dvui.Rect.all(4), .expand = .horizontal, .gravity_x = 1.0, .font = dvui.Font.theme(.heading) },
        );

        if (button.clicked()) {
            // if (try dvui.dialogNativeFileOpenMultiple(dvui.currentWindow().arena(), .{
            //     .title = "Open Files...",
            //     .filter_description = ".pixi, .png",
            //     .filters = &.{ "*.pixi", "*.png" },
            // })) |files| {
            //     for (files) |file| {
            //         _ = fizzy.editor.openFilePath(file, Globals.workbench.open_workspace_grouping) catch {
            //             std.log.err("Failed to open file: {s}", .{file});
            //         };
            //     }
            // }

            Globals.host.showOpenFileDialog(openFilesCallback, &.{
                .{ .name = "Image Files", .pattern = "fizzy;png;jpg;jpeg" },
            }, "", null);
        }
    }
    vbox.deinit();

    const spacer = dvui.spacer(@src(), .{ .expand = .horizontal, .min_size_content = .{ .h = 30 } });

    {
        var recents_box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .none,
            .gravity_x = 0.5,
            .max_size_content = .{ .h = (canvas_vbox.data().rect.h - spacer.rect.y) / 3.0, .w = canvas_vbox.data().rect.w / 2.0 },
        });
        defer recents_box.deinit();

        var scroll_area = dvui.scrollArea(@src(), .{}, .{
            .expand = .both,
            .color_border = dvui.themeGet().color(.control, .fill),
            .corner_radius = dvui.Rect.all(8),
            .color_fill = .transparent,
        });
        defer scroll_area.deinit();

        var i: usize = Globals.host.recentFolderCount();
        while (i > 0) : (i -= 1) {
            var anim = dvui.animate(@src(), .{
                .kind = .horizontal,
                .duration = 150_000 + 150_000 * @as(i32, @intCast(i)),
                .easing = dvui.easing.outBack,
            }, .{
                .id_extra = i,
                .expand = .horizontal,
            });
            defer anim.deinit();

            const folder = Globals.host.recentFolderAt(i - 1) orelse continue;
            if (dvui.button(@src(), folder, .{
                .draw_focus = false,
            }, .{
                .expand = .horizontal,
                .font = dvui.Font.theme(.mono).larger(-2.0),
                .id_extra = i,
                .margin = dvui.Rect.all(1),
                .padding = dvui.Rect.all(2),
                .color_fill = .transparent,
                .color_fill_hover = dvui.themeGet().color(.window, .fill_hover),
                .color_fill_press = dvui.themeGet().color(.window, .fill_press),
                .color_text = dvui.themeGet().color(.control, .text).opacity(0.5),
            })) {
                try Globals.host.setProjectFolder(folder);
            }
        }
    }
}

pub fn drawBubble(rect: dvui.Rect, rs: dvui.RectScale, color: [4]u8, _: usize) !void {
    var bubble_h: f32 = rect.h;
    for (dvui.events()) |evt| {
        switch (evt.evt) {
            .mouse => |me| {
                const dx = @abs(me.p.x - (rs.r.x + rs.r.w * 0.5)) / rs.s;
                const dy = @abs(me.p.y - (rs.r.y - rs.r.h * 0.5)) / rs.s;
                const distance = @sqrt(dx * dx + dy * dy);
                const max_distance: f32 = rect.h * 2.0;

                var t = distance / max_distance;
                if (t > 1.0) t = 1.0;
                if (t < 0.0) t = 0.0;
                bubble_h = @ceil(rect.h - rect.h * t);
            },
            else => {},
        }
    }

    // Derive the pill's physical rect directly from the base's physical rect
    // (no dvui.box layout round-trip). This guarantees identical left/right
    // edges between base and pill at any scale or splitter ratio.
    const base_phys = rs.r.outsetAll(1);
    const bubble_h_phys = @ceil(bubble_h * rs.s);
    const bubble_phys = dvui.Rect.Physical{
        .x = base_phys.x,
        .y = rs.r.y - bubble_h_phys,
        .w = base_phys.w,
        .h = bubble_h_phys,
    };

    var path = dvui.Path.Builder.init(dvui.currentWindow().lifo());
    defer path.deinit();

    path.addRect(base_phys, dvui.Rect.Physical.all(0));

    if (bubble_phys.h > 0) {
        const rad_x = rs.r.w / 2.0;
        const rad_y = rs.r.h / 2.0;
        const r = bubble_phys;
        const tl = dvui.Point.Physical{ .x = r.x + rad_x, .y = r.y + rad_x };
        const bl = dvui.Point.Physical{ .x = r.x, .y = r.y + r.h };
        const br = dvui.Point.Physical{ .x = r.x + r.w, .y = r.y + r.h };
        const tr = dvui.Point.Physical{ .x = r.x + r.w - rad_y, .y = r.y + rad_y };
        path.addArc(tl, rad_x, dvui.math.pi * 1.5, dvui.math.pi, true);
        path.addArc(bl, 0, dvui.math.pi, dvui.math.pi * 0.5, true);
        path.addArc(br, 0, dvui.math.pi * 0.5, 0, true);
        path.addArc(tr, rad_y, dvui.math.pi * 2.0, dvui.math.pi * 1.5, false);
    }

    path.build().fillConvex(.{ .color = .{ .r = color[0], .g = color[1], .b = color[2], .a = color[3] }, .fade = 1.0 });
}

// This should never be able to return more than one folder
pub fn setProjectFolderCallback(folder: ?[][:0]const u8) void {
    if (folder) |f| {
        Globals.host.setProjectFolder(f[0]) catch {
            dvui.log.err("Failed to set project folder: {s}", .{f[0]});
        };
    }
}

pub fn openFilesCallback(files: ?[][:0]const u8) void {
    if (files) |f| {
        for (f) |file| {
            _ = Globals.host.openFilePath(file, Globals.workbench.open_workspace_grouping) catch {
                dvui.log.err("Failed to open file: {s}", .{file});
            };
        }
    }
}
