const std = @import("std");
const builtin = @import("builtin");

const dvui = @import("dvui");
const fizzy = @import("../fizzy.zig");
const icons = @import("icons");

const App = fizzy.App;
const Editor = fizzy.Editor;

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

columns_drag_name: []const u8 = undefined,
columns_drag_index: ?usize = null,
columns_target_id: ?dvui.Id = null,
columns_target_index: ?usize = null,
columns_removed_index: ?usize = null,
columns_insert_before_index: ?usize = null,

rows_drag_name: []const u8 = undefined,
rows_drag_index: ?usize = null,
rows_target_id: ?dvui.Id = null,
rows_target_index: ?usize = null,
rows_removed_index: ?usize = null,
rows_insert_before_index: ?usize = null,

horizontal_scroll_info: dvui.ScrollInfo = .{ .vertical = .given, .horizontal = .given },
vertical_scroll_info: dvui.ScrollInfo = .{ .vertical = .given, .horizontal = .given },

horizontal_ruler_height: f32 = 0.0,
vertical_ruler_width: f32 = 0.0,

/// Floating Edit-pill quick-access bar collapse state. Starts collapsed (single
/// hamburger button); the user toggles to expand the full action row.
edit_pill_expanded: bool = false,

/// Physical-pixel content rect of this workspace's canvas vbox, captured each frame during
/// `drawCanvas` (or a sidebar view's `draw_workspace` takeover, e.g. pixel art's Project view).
/// `null` until the workspace has rendered at least once. Used
/// by the editor-level load/save toast overlays to center cards over the area the user is
/// actually looking at (rather than the OS window rect).
canvas_rect_physical: ?dvui.Rect.Physical = null,

pub fn init(grouping: u64) Workspace {
    return .{
        .grouping = grouping,
        .columns_drag_name = std.fmt.allocPrint(fizzy.app.allocator, "column_drag_{d}", .{grouping}) catch "column_drag",
        .rows_drag_name = std.fmt.allocPrint(fizzy.app.allocator, "row_drag_{d}", .{grouping}) catch "row_drag",
    };
}

/// Recover the typed workspace currently drawing `file` from its opaque slot
/// handle (`File.EditorData.workspace_handle`, set each frame in `drawCanvas`).
/// Returns null before the file has been laid out this session.
pub fn ofFile(file: *fizzy.Internal.File) ?*Workspace {
    const handle = file.editor.workspace_handle orelse return null;
    return @ptrCast(@alignCast(handle));
}

const handle_size = 10;
const handle_dist = 60;

const opacity = 60;

const color_0 = fizzy.math.Color.initBytes(0, 0, 0, 0);
const color_1 = fizzy.math.Color.initBytes(230, 175, 137, opacity);
const color_2 = fizzy.math.Color.initBytes(216, 145, 115, opacity);
const color_3 = fizzy.math.Color.initBytes(41, 23, 41, opacity);
const color_4 = fizzy.math.Color.initBytes(194, 109, 92, opacity);
const color_5 = fizzy.math.Color.initBytes(180, 89, 76, opacity);

const logo_colors: [12]fizzy.math.Color = [_]fizzy.math.Color{
    color_1, color_1, color_1,
    color_2, color_2, color_3,
    color_4, color_3, color_0,
    color_3, color_0, color_0,
};

var dragging: bool = false;

pub fn draw(self: *Workspace) !dvui.App.Result {
    defer self.columns_drag_index = null;
    defer self.rows_drag_index = null;

    // Process the column reorder, when both fields are set and we can take action
    defer self.processColumnReorder();
    defer self.processRowReorder();

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
                fizzy.editor.open_workspace_grouping = self.grouping;
            }
        }
    }

    // A sidebar view may optionally take over this workspace pane's content region (e.g. pixel
    // art's "Project" view renders the packed atlas here instead of document tabs+canvas). The
    // workbench owns only the pane frame; it hands the active view the opaque workspace handle.
    const active = fizzy.editor.host.activeSidebarView();
    if (active != null and active.?.draw_workspace != null) {
        try active.?.draw_workspace.?(active.?.ctx, self);
    } else {
        self.drawTabs();
        try self.drawCanvas();
    }

    return .ok;
}

/// Same `@src()` for every call so DVUI sees one stable id when switching between `drawCanvas` and
/// a plugin's `draw_workspace` takeover (avoids first-frame min-size / layout flash). Use `grouping`
/// so multi-workspace panes stay distinct.
/// `pub` so a plugin's `draw_workspace` takeover (pixel art's Project view) can reuse the exact same
/// vbox so switching project ↔ canvas does not churn the widget id.
pub fn workspaceMainCanvasVbox(content_color: dvui.Color, background: bool, grouping: u64) *dvui.BoxWidget {
    return dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = background,
        .color_fill = content_color,
        .id_extra = @intCast(grouping),
    });
}

/// Rounded “card” behind the project empty state and the homepage. Shared id base + `grouping` so
/// switching project tab ↔ file pane (no open files) does not create a new widget each time.
/// `pub` so pixel art's Project-view takeover (`draw_workspace`) reuses the identical empty-state card.
pub fn workspaceEmptyStateCard(content_color: dvui.Color, grouping: u64) *dvui.BoxWidget {
    return dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
        .background = true,
        .color_fill = content_color,
        .corner_radius = dvui.Rect.all(16),
        .margin = .{ .y = 10 },
        .id_extra = @intCast(grouping),
    });
}

fn drawTabs(self: *Workspace) void {
    if (fizzy.editor.open_files.values().len == 0) return;

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

            const files = fizzy.editor.open_files.values();
            const files_len = files.len;

            // Find the neighbouring tabs (within this workspace grouping) of the active tab.
            var prev_same_group_index: ?usize = null;
            var next_same_group_index: ?usize = null;

            const active_in_this_group = blk: {
                if (fizzy.editor.open_workspace_grouping != self.grouping) break :blk false;
                if (self.open_file_index >= files_len) break :blk false;
                if (files[self.open_file_index].editor.grouping != self.grouping) break :blk false;
                break :blk true;
            };

            if (active_in_this_group) {
                const active_index = self.open_file_index;

                // Scan left from the active tab to find the previous tab in this grouping.
                var j: usize = active_index;
                while (j > 0) {
                    j -= 1;
                    if (files[j].editor.grouping == self.grouping) {
                        prev_same_group_index = j;
                        break;
                    }
                }

                // Scan right from the active tab to find the next tab in this grouping.
                j = active_index + 1;
                while (j < files_len) : (j += 1) {
                    if (files[j].editor.grouping == self.grouping) {
                        next_same_group_index = j;
                        break;
                    }
                }
            }

            for (files, 0..) |file, i| {
                const is_fizzy_file = fizzy.Internal.File.isFizzyExtension(std.fs.path.extension(file.path));

                if (file.editor.grouping != self.grouping) continue;

                var reorderable = tabs.reorderable(@src(), .{}, .{
                    .expand = .vertical,
                    .id_extra = i,
                    .padding = dvui.Rect.all(0),
                    .margin = dvui.Rect.all(0),
                });
                defer reorderable.deinit();

                const selected = self.open_file_index == i and fizzy.editor.open_workspace_grouping == self.grouping;

                var anim = dvui.animate(@src(), .{ .duration = 400_000, .kind = .horizontal, .easing = dvui.easing.outBack }, .{});
                defer anim.deinit();

                var hbox: dvui.BoxWidget = undefined;
                hbox.init(@src(), .{ .dir = .horizontal }, .{
                    .expand = .none,
                    .border = .all(0),
                    .color_fill = if (selected) .transparent else dvui.themeGet().color(.window, .fill).opacity(fizzy.editor.settings.content_opacity),
                    .background = true,
                    .id_extra = i,
                    .padding = dvui.Rect.all(2),
                    .margin = dvui.Rect.all(0),
                });

                defer hbox.deinit();

                const tab_hovered = fizzy.dvui.hovered(hbox.data());

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
                            fizzy.dvui.drawEdgeShadow(hbox.data().rectScale(), .right, .{});
                        }
                    }

                    if (next_same_group_index) |next_index| {
                        if (i == next_index) {
                            // This tab is directly to the right of the active tab.
                            fizzy.dvui.drawEdgeShadow(hbox.data().rectScale(), .left, .{});
                        }
                    }
                }

                if (reorderable.removed()) {
                    self.tabs_removed_index = i;
                } else if (reorderable.insertBefore()) {
                    self.tabs_insert_before_index = i;
                }

                if (is_fizzy_file) {
                    _ = fizzy.dvui.sprite(@src(), .{
                        .source = fizzy.editor.atlas.source,
                        .sprite = fizzy.editor.atlas.data.sprites[fizzy.atlas.sprites.logo_default],
                        .scale = 2.0,
                    }, .{
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

                dvui.label(@src(), "{s}", .{std.fs.path.basename(file.path)}, .{
                    .color_text = if (selected) dvui.themeGet().color(.window, .text) else dvui.themeGet().color(.control, .text),
                    .padding = dvui.Rect.all(4),
                    .gravity_y = 0.5,
                });

                const close_inner = fizzy.dvui.windowHeaderCloseInnerSide();
                const close_pad = fizzy.dvui.window_header_close_margin;
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
                const save_flash_elapsed = file.timeSinceSaveComplete();
                const save_in_check_phase = if (save_flash_elapsed) |elapsed|
                    fizzy.dvui.bubbleSpinnerSaveInCheckPhase(elapsed)
                else
                    false;
                const save_blocks_tab_close = file.isSaving() or
                    (file.showsSaveStatusIndicator() and !save_in_check_phase);

                if (save_blocks_tab_close) {
                    fizzy.dvui.bubbleSpinner(@src(), .{
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
                    fizzy.dvui.bubbleSpinner(@src(), .{
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
                    tab_close_button.init(@src(), .{ .draw_focus = false }, fizzy.dvui.windowHeaderCloseButtonOptions(.{
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
                        fizzy.editor.closeFileID(file.id) catch |err| {
                            dvui.log.err("closeFile: {d} failed: {s}", .{ i, @errorName(err) });
                        };
                        break;
                    }
                } else if (selected and !file.dirty()) {
                    const tab_text = dvui.themeGet().color(.window, .text);
                    var ghost_close: dvui.ButtonWidget = undefined;
                    ghost_close.init(@src(), .{ .draw_focus = false }, fizzy.dvui.windowHeaderCloseButtonOptions(.{
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
                        fizzy.editor.closeFileID(file.id) catch |err| {
                            dvui.log.err("closeFile: {d} failed: {s}", .{ i, @errorName(err) });
                        };
                        break;
                    }
                } else if (file.dirty()) {
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
                                fizzy.editor.setActiveFile(i);
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
                self.tabs_insert_before_index = fizzy.editor.open_files.values().len;
            }
        }
    }
}

pub fn processTabsDrag(self: *Workspace) void {
    if (self.tabs_insert_before_index) |insert_before| {
        if (self.tabs_removed_index) |removed| { // Dragging from this workspace

            if (removed > fizzy.editor.open_files.count()) return;
            if (removed > insert_before) {
                std.mem.swap(fizzy.Internal.File, &fizzy.editor.open_files.values()[removed], &fizzy.editor.open_files.values()[insert_before]);
                std.mem.swap(u64, &fizzy.editor.open_files.keys()[removed], &fizzy.editor.open_files.keys()[insert_before]);
                fizzy.editor.setActiveFile(insert_before);
            } else {
                if (insert_before > 0) {
                    std.mem.swap(fizzy.Internal.File, &fizzy.editor.open_files.values()[removed], &fizzy.editor.open_files.values()[insert_before - 1]);
                    std.mem.swap(u64, &fizzy.editor.open_files.keys()[removed], &fizzy.editor.open_files.keys()[insert_before - 1]);
                    fizzy.editor.setActiveFile(insert_before - 1);
                } else {
                    std.mem.swap(fizzy.Internal.File, &fizzy.editor.open_files.values()[removed], &fizzy.editor.open_files.values()[insert_before]);
                    std.mem.swap(u64, &fizzy.editor.open_files.keys()[removed], &fizzy.editor.open_files.keys()[insert_before]);
                    fizzy.editor.setActiveFile(insert_before);
                }
            }

            self.tabs_removed_index = null;
            self.tabs_insert_before_index = null;
        } else { // Dragging from another workspace
            for (fizzy.editor.workspaces.values()) |*workspace| {
                if (workspace.tabs_removed_index) |removed| {
                    if (removed > insert_before) {
                        std.mem.swap(fizzy.Internal.File, &fizzy.editor.open_files.values()[removed], &fizzy.editor.open_files.values()[insert_before]);
                        std.mem.swap(u64, &fizzy.editor.open_files.keys()[removed], &fizzy.editor.open_files.keys()[insert_before]);

                        fizzy.editor.open_files.values()[insert_before].editor.grouping = self.grouping;
                        fizzy.editor.setActiveFile(insert_before);
                    } else {
                        if (insert_before > 0) {
                            std.mem.swap(fizzy.Internal.File, &fizzy.editor.open_files.values()[removed], &fizzy.editor.open_files.values()[insert_before - 1]);
                            std.mem.swap(u64, &fizzy.editor.open_files.keys()[removed], &fizzy.editor.open_files.keys()[insert_before - 1]);
                            fizzy.editor.open_files.values()[insert_before - 1].editor.grouping = self.grouping;
                            fizzy.editor.setActiveFile(insert_before - 1);
                        } else {
                            std.mem.swap(fizzy.Internal.File, &fizzy.editor.open_files.values()[removed], &fizzy.editor.open_files.values()[insert_before]);
                            std.mem.swap(u64, &fizzy.editor.open_files.keys()[removed], &fizzy.editor.open_files.keys()[insert_before]);
                            fizzy.editor.open_files.values()[insert_before].editor.grouping = self.grouping;
                            fizzy.editor.setActiveFile(insert_before);
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
fn repointWorkspacesAfterTabDrag(editor: *Editor, tab_bar_workspace: ?*Workspace, drag_index: usize) void {
    const dragged_file = &editor.open_files.values()[drag_index];
    if (tab_bar_workspace) |workspace| {
        if (workspace.open_file_index == editor.open_files.getIndex(dragged_file.id)) {
            for (editor.open_files.values()) |f| {
                if (f.editor.grouping == workspace.grouping and f.id != dragged_file.id) {
                    workspace.open_file_index = editor.open_files.getIndex(f.id) orelse 0;
                    break;
                }
            }
        }
    } else {
        for (editor.workspaces.values()) |*w| {
            if (w.open_file_index == drag_index) {
                for (editor.open_files.values()) |f| {
                    if (f.editor.grouping == w.grouping and f.id != dragged_file.id) {
                        w.open_file_index = editor.open_files.getIndex(f.id) orelse 0;
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

    fn resolve(editor: *Editor) WorkspaceTabDragSrc {
        for (editor.workspaces.values()) |*w| {
            if (w.tabs_drag_index) |i| return .{ .tab_bar = .{ .ws = w, .index = i } };
        }
        if (editor.tab_drag_from_tree_path) |p| {
            if (editor.getFileFromPath(p)) |f| {
                const idx = editor.open_files.getIndex(f.id) orelse return .none;
                return .{ .tree_open = idx };
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
        fizzy.editor.clearFileTreeTabDragDropState();
        return;
    }

    const drag_src = WorkspaceTabDragSrc.resolve(fizzy.editor);
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

                if (right_side.contains(e.evt.mouse.p) and fizzy.editor.workspaces.keys()[fizzy.editor.workspaces.keys().len - 1] == self.grouping) {
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
                        fizzy.editor.clearFileTreeTabDragDropState();

                        repointWorkspacesAfterTabDrag(fizzy.editor, workspace, drag_index);
                        var dragged_file = &fizzy.editor.open_files.values()[drag_index];
                        dragged_file.editor.grouping = fizzy.editor.newGroupingID();
                        fizzy.editor.open_workspace_grouping = dragged_file.editor.grouping;
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
                        fizzy.editor.clearFileTreeTabDragDropState();

                        repointWorkspacesAfterTabDrag(fizzy.editor, workspace, drag_index);
                        var dragged_file = &fizzy.editor.open_files.values()[drag_index];
                        dragged_file.editor.grouping = self.grouping;
                        fizzy.editor.open_workspace_grouping = dragged_file.editor.grouping;
                        self.open_file_index = fizzy.editor.open_files.getIndex(dragged_file.id) orelse 0;
                    }
                }
            },
            .tree_open => |drag_index| {
                var right_side = data.rectScale().r;
                right_side.w /= 2;
                right_side.x += right_side.w;

                if (right_side.contains(e.evt.mouse.p) and fizzy.editor.workspaces.keys()[fizzy.editor.workspaces.keys().len - 1] == self.grouping) {
                    if (e.evt == .mouse and e.evt.mouse.action == .position) {
                        right_side.fill(dvui.Rect.Physical.all(right_side.w / 8), .{
                            .color = dvui.themeGet().color(.highlight, .fill).opacity(0.5),
                        });
                    }

                    if (e.evt == .mouse and e.evt.mouse.action == .release and e.evt.mouse.button.pointer()) {
                        e.handle(@src(), data);
                        dvui.dragEnd();
                        dvui.refresh(null, @src(), data.id);
                        fizzy.editor.clearFileTreeTabDragDropState();

                        repointWorkspacesAfterTabDrag(fizzy.editor, null, drag_index);
                        var dragged_file = &fizzy.editor.open_files.values()[drag_index];
                        dragged_file.editor.grouping = fizzy.editor.newGroupingID();
                        fizzy.editor.open_workspace_grouping = dragged_file.editor.grouping;
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
                        fizzy.editor.clearFileTreeTabDragDropState();

                        repointWorkspacesAfterTabDrag(fizzy.editor, null, drag_index);
                        var dragged_file = &fizzy.editor.open_files.values()[drag_index];
                        dragged_file.editor.grouping = self.grouping;
                        fizzy.editor.open_workspace_grouping = dragged_file.editor.grouping;
                        self.open_file_index = fizzy.editor.open_files.getIndex(dragged_file.id) orelse 0;
                    }
                }
            },
            .tree_closed => |path| {
                var right_side = data.rectScale().r;
                right_side.w /= 2;
                right_side.x += right_side.w;

                if (right_side.contains(e.evt.mouse.p) and fizzy.editor.workspaces.keys()[fizzy.editor.workspaces.keys().len - 1] == self.grouping) {
                    if (e.evt == .mouse and e.evt.mouse.action == .position) {
                        right_side.fill(dvui.Rect.Physical.all(right_side.w / 8), .{
                            .color = dvui.themeGet().color(.highlight, .fill).opacity(0.5),
                        });
                    }

                    if (e.evt == .mouse and e.evt.mouse.action == .release and e.evt.mouse.button.pointer()) {
                        e.handle(@src(), data);
                        dvui.dragEnd();
                        dvui.refresh(null, @src(), data.id);
                        const new_g = fizzy.editor.newGroupingID();
                        const maybe_idx = fizzy.editor.openOrFocusFileAtGrouping(path, new_g) catch {
                            fizzy.editor.clearFileTreeTabDragDropState();
                            continue :events_loop;
                        };
                        if (maybe_idx) |idx| {
                            // File was already open and moved between groupings — repoint the
                            // workspaces that were showing it, and focus the new pane now.
                            repointWorkspacesAfterTabDrag(fizzy.editor, null, idx);
                            fizzy.editor.open_workspace_grouping = new_g;
                        }
                        // Else: async load — leave `open_workspace_grouping` alone. Switching
                        // to the not-yet-extant workspace would make `activeFile()` null and
                        // collapse the bottom panel mid-load; `processLoadingJobs` will focus
                        // the new pane once the worker lands the file, matching the
                        // "Open to the side" menu action.
                        fizzy.editor.clearFileTreeTabDragDropState();
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
                        const maybe_idx = fizzy.editor.openOrFocusFileAtGrouping(path, self.grouping) catch {
                            fizzy.editor.clearFileTreeTabDragDropState();
                            continue :events_loop;
                        };
                        if (maybe_idx) |idx| {
                            repointWorkspacesAfterTabDrag(fizzy.editor, null, idx);
                            self.open_file_index = idx;
                        }
                        // Else: async load into this workspace's existing grouping. The
                        // worker's `processLoadingJobs` focus handler will set the active
                        // file once it lands.
                        fizzy.editor.clearFileTreeTabDragDropState();
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
            content_color = if (!fizzy.backend.isMaximized(dvui.currentWindow())) content_color.opacity(fizzy.editor.settings.content_opacity) else content_color;
        },
        .windows => {
            content_color = if (!fizzy.backend.isMaximized(dvui.currentWindow())) content_color.opacity(fizzy.editor.settings.content_opacity) else content_color;
        },
        else => {},
    }

    const has_files = fizzy.editor.open_files.values().len > 0;

    var canvas_vbox = workspaceMainCanvasVbox(content_color, has_files, self.grouping);
    defer {
        self.canvas_rect_physical = canvas_vbox.data().contentRectScale().r;
        dvui.toastsShow(canvas_vbox.data().id, canvas_vbox.data().contentRectScale().r.toNatural());
        canvas_vbox.deinit();
    }
    defer self.processTabDrag(canvas_vbox.data());

    if (has_files) {
        if (self.open_file_index >= fizzy.editor.open_files.values().len) {
            self.open_file_index = fizzy.editor.open_files.values().len - 1;
        }

        const file = &fizzy.editor.open_files.values()[self.open_file_index];
        // The workbench owns only the content region (this container) + tab/split frame;
        // bind it to the document and route the entire in-region render to the owning
        // plugin (pixel art draws its rulers, overlays, and editing widget itself).
        file.editor.canvas.id = canvas_vbox.data().id;
        file.editor.workspace_handle = self;
        file.editor.center = self.center;

        if (fizzy.editor.host.pluginForExtension(std.fs.path.extension(file.path))) |plugin| {
            _ = try plugin.drawDocument(.{ .ptr = file, .owner = plugin, .id = file.id });
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

pub const RulerOrientation = enum {
    horizontal,
    vertical,
};

pub fn drawRuler(self: *Workspace, orientation: RulerOrientation) void {
    const file = &fizzy.editor.open_files.values()[self.open_file_index];
    const font = dvui.Font.theme(.body).larger(-1);

    const largest_label = std.fmt.allocPrint(dvui.currentWindow().arena(), "{d}", .{file.rows - 1}) catch {
        dvui.log.err("Failed to allocate largest label", .{});
        return;
    };
    const largest_label_size = font.textSize(largest_label);
    const natural_scale = dvui.currentWindow().natural_scale;
    const largest_label_phys = largest_label_size.scale(natural_scale, dvui.Size.Physical);
    const base_ruler_size = largest_label_size.w + fizzy.editor.settings.ruler_padding;

    const ruler_thickness: f32 = switch (orientation) {
        .horizontal => blk: {
            self.horizontal_ruler_height = font.textSize("M").h + fizzy.editor.settings.ruler_padding;
            break :blk self.horizontal_ruler_height;
        },
        .vertical => blk: {
            self.vertical_ruler_width = @max(base_ruler_size, font.textSize("M").h + fizzy.editor.settings.ruler_padding);
            break :blk self.vertical_ruler_width;
        },
    };

    switch (orientation) {
        .horizontal => {
            var canvas_hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
            });
            defer canvas_hbox.deinit();

            var corner_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .none,
                .min_size_content = .{ .h = self.vertical_ruler_width, .w = self.vertical_ruler_width },
                .background = true,
                .color_fill = dvui.themeGet().color(.window, .fill),
            });
            corner_box.deinit();

            var top_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .min_size_content = .{ .h = ruler_thickness, .w = ruler_thickness },
                .background = true,
                .color_fill = dvui.themeGet().color(.window, .fill),
            });
            defer top_box.deinit();

            self.drawRulerContent(file, font, orientation, ruler_thickness, largest_label, null);
        },
        .vertical => {
            var ruler_box = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .vertical,
                .min_size_content = .{ .w = ruler_thickness, .h = 1.0 },
                .background = true,
                .color_fill = dvui.themeGet().color(.window, .fill),
            });
            defer ruler_box.deinit();

            self.drawRulerContent(file, font, orientation, ruler_thickness, largest_label, largest_label_phys);
        },
    }
}

/// `largest_row_index_*` come from `drawRuler` (widest row index string and its measured size in physical pixels).
fn drawRulerContent(
    self: *Workspace,
    file: *fizzy.Internal.File,
    font: dvui.Font,
    orientation: RulerOrientation,
    ruler_size: f32,
    largest_row_index_label: []const u8,
    largest_row_index_size_phys: ?dvui.Size.Physical,
) void {
    const scale = file.editor.canvas.scale;
    const canvas = file.editor.canvas;

    switch (orientation) {
        .horizontal => {
            self.horizontal_scroll_info.virtual_size.w = canvas.scroll_info.virtual_size.w;
            self.horizontal_scroll_info.virtual_size.h = ruler_size;
            self.horizontal_scroll_info.viewport.w = canvas.scroll_info.viewport.w;
            self.horizontal_scroll_info.viewport.x = canvas.scroll_info.viewport.x;
        },
        .vertical => {
            self.vertical_scroll_info.virtual_size.h = canvas.scroll_info.virtual_size.h;
            self.vertical_scroll_info.virtual_size.w = ruler_size;
            self.vertical_scroll_info.viewport.h = canvas.scroll_info.viewport.h;
            self.vertical_scroll_info.viewport.y = canvas.scroll_info.viewport.y;
        },
    }

    const scroll_info = switch (orientation) {
        .horizontal => &self.horizontal_scroll_info,
        .vertical => &self.vertical_scroll_info,
    };

    var scroll_area = dvui.scrollArea(@src(), .{
        .scroll_info = scroll_info,
        .container = true,
        .process_events_after = true,
        .horizontal_bar = .hide,
        .vertical_bar = .hide,
    }, .{ .expand = .both });
    defer scroll_area.deinit();

    const scale_rect = switch (orientation) {
        .horizontal => dvui.Rect{ .x = -canvas.origin.x, .y = 0, .w = 0, .h = 0 },
        .vertical => dvui.Rect{ .x = 0, .y = -canvas.origin.y, .w = 0, .h = 0 },
    };
    var scaler = dvui.scale(@src(), .{ .scale = &file.editor.canvas.scale }, .{ .rect = scale_rect });
    defer scaler.deinit();

    const outer_rect: dvui.Rect = switch (orientation) {
        .horizontal => .{
            .x = 0,
            .y = 0,
            .w = @as(f32, @floatFromInt(file.width())),
            .h = ruler_size / scale,
        },
        .vertical => .{
            .x = 0,
            .y = 0,
            .w = ruler_size / scale,
            .h = @as(f32, @floatFromInt(file.height())),
        },
    };
    var outer_box = dvui.box(@src(), .{ .dir = switch (orientation) {
        .horizontal => .horizontal,
        .vertical => .horizontal,
    } }, .{
        .expand = .none,
        .rect = outer_rect,
    });
    defer outer_box.deinit();

    const drag_name = switch (orientation) {
        .horizontal => self.columns_drag_name,
        .vertical => self.rows_drag_name,
    };

    var reorder = fizzy.dvui.reorder(@src(), .{ .drag_name = drag_name }, .{
        .expand = .both,
        .margin = dvui.Rect.all(0),
        .padding = dvui.Rect.all(0),
        .background = false,
        .corner_radius = dvui.Rect.all(0),
    });
    defer reorder.deinit();

    const reorder_box_dir: dvui.enums.Direction = switch (orientation) {
        .horizontal => .horizontal,
        .vertical => .vertical,
    };
    var reorder_box = dvui.box(@src(), .{ .dir = reorder_box_dir }, .{
        .expand = .both,
        .background = false,
        .corner_radius = dvui.Rect.all(0),
        .margin = dvui.Rect.all(0),
        .padding = dvui.Rect.all(0),
    });
    defer reorder_box.deinit();

    const ruler_stroke_color = dvui.themeGet().color(.control, .fill_hover).lighten(switch (orientation) {
        .horizontal => 2.0,
        .vertical => 0.0,
    });

    const edge_stroke_points = switch (orientation) {
        .horizontal => .{
            reorder_box.data().rectScale().r.topRight(),
            reorder_box.data().rectScale().r.bottomRight(),
        },
        .vertical => .{
            reorder_box.data().rectScale().r.bottomRight(),
            reorder_box.data().rectScale().r.bottomLeft(),
        },
    };
    defer dvui.Path.stroke(.{ .points = &edge_stroke_points }, .{
        .color = ruler_stroke_color,
        .thickness = 1.0,
    });

    const count = switch (orientation) {
        .horizontal => file.columns,
        .vertical => file.rows,
    };
    const cell_min_size: dvui.Size = switch (orientation) {
        .horizontal => .{ .w = @as(f32, @floatFromInt(file.column_width)), .h = 1.0 },
        .vertical => .{ .w = 1.0, .h = @as(f32, @floatFromInt(file.row_height)) },
    };
    const reorder_mode: fizzy.dvui.ReorderWidget.Reorderable.Mode = switch (orientation) {
        .horizontal => .any_y,
        .vertical => .any_x,
    };
    const reorder_expand: dvui.Options.Expand = switch (orientation) {
        .horizontal => .vertical,
        .vertical => .horizontal,
    };

    // Shared layout width for every row tick (widest index string); actual glyph size may differ per cell.
    const vertical_row_layout_size_phys: ?dvui.Size.Physical = switch (orientation) {
        .vertical => largest_row_index_size_phys,
        .horizontal => null,
    };

    // Captured during iteration: the highlighted target slot (drop location) screen rect.
    var target_rs_screen: ?dvui.RectScale = null;

    var index: usize = 0;
    while (index < count) : (index += 1) {
        var reorderable = reorder.reorderable(@src(), .{
            .mode = reorder_mode,
            .clamp_to_edges = true,
        }, .{
            .expand = reorder_expand,
            .id_extra = index,
            .padding = dvui.Rect.all(0),
            .margin = dvui.Rect.all(0),
            .min_size_content = cell_min_size,
        });
        defer reorderable.deinit();

        if (reorderable.targetRectScale()) |trs| {
            target_rs_screen = trs;
        }

        var button_color = if (reorder.drag_point != null) dvui.themeGet().color(.control, .fill).opacity(0.85) else dvui.themeGet().color(.window, .fill);

        if (fizzy.dvui.hovered(reorderable.data())) {
            button_color = dvui.themeGet().color(.control, .fill_hover);
            dvui.cursorSet(.hand);
        }

        var cell_box: dvui.BoxWidget = undefined;
        cell_box.init(@src(), .{ .dir = .horizontal }, .{
            .expand = .both,
            .background = true,
            .color_fill = button_color,
            .id_extra = index,
        });

        switch (orientation) {
            .horizontal => {
                if (reorderable.floating()) {
                    self.columns_drag_index = index;
                    reorder.reorderable_size.h = 0.0;
                    dvui.cursorSet(.hand);
                }
                if (reorderable.removed()) self.columns_removed_index = index;
                if (reorderable.insertBefore()) self.columns_insert_before_index = index;
                if (reorderable.targetID()) |target_id| self.columns_target_id = target_id;
                if (self.columns_drag_index) |_| {
                    var mouse_pt = @constCast(&file.editor.canvas).dataFromScreenPoint(dvui.currentWindow().mouse_pt);
                    mouse_pt.y = 0.0;
                    mouse_pt.x = std.math.clamp(mouse_pt.x, 0.0, @as(f32, @floatFromInt(file.width() - 1)));
                    self.columns_target_index = file.columnIndex(mouse_pt);
                }
            },
            .vertical => {
                if (reorderable.floating()) {
                    self.rows_drag_index = index;
                    reorder.reorderable_size.w = 0.0;
                    dvui.cursorSet(.hand);
                }
                if (reorderable.removed()) self.rows_removed_index = index;
                if (reorderable.insertBefore()) self.rows_insert_before_index = index;
                if (reorderable.targetID()) |target_id| self.rows_target_id = target_id;
                if (self.rows_drag_index) |_| {
                    var mouse_pt = @constCast(&file.editor.canvas).dataFromScreenPoint(dvui.currentWindow().mouse_pt);
                    mouse_pt.x = 0.0;
                    mouse_pt.y = std.math.clamp(mouse_pt.y, 0.0, @as(f32, @floatFromInt(file.height() - 1)));
                    self.rows_target_index = file.rowIndex(mouse_pt);
                }
            },
        }

        {
            defer cell_box.deinit();

            // The dragged item's cell_box is parented to the reorderable's floating widget
            // (rendered at the mouse position). We collapse that floating widget to h/w = 0
            // above, but `dvui.renderText` is not clipped by that, so the label would still
            // appear at the cursor. Skip the visible cell rendering entirely while floating;
            // the dragged label is drawn over the highlighted target slot below instead.
            if (!reorderable.floating()) {
                cell_box.drawBackground();

                const label = switch (orientation) {
                    .horizontal => file.fmtColumn(dvui.currentWindow().arena(), @intCast(index)) catch {
                        dvui.log.err("Failed to allocate label", .{});
                        return;
                    },
                    .vertical => std.fmt.allocPrint(dvui.currentWindow().arena(), "{d}", .{index}) catch {
                        dvui.log.err("Failed to allocate label", .{});
                        return;
                    },
                };

                self.drawRulerLabel(.{
                    .font = font,
                    .label = label,
                    .rect = cell_box.data().rectScale().r,
                    .color = dvui.themeGet().color(.control, .text).opacity(0.5),
                    .mode = switch (orientation) {
                        .horizontal => .horizontal,
                        .vertical => .vertical,
                    },
                    .largest_label = if (orientation == .vertical) largest_row_index_label else null,
                    .ref_size_physical = vertical_row_layout_size_phys,
                });

                const cell_rect = cell_box.data().rectScale().r;
                const cell_stroke_points = switch (orientation) {
                    .horizontal => .{ cell_rect.topLeft(), cell_rect.bottomLeft() },
                    .vertical => .{ cell_rect.topLeft(), cell_rect.topRight() },
                };
                dvui.Path.stroke(.{ .points = &cell_stroke_points }, .{ .color = ruler_stroke_color, .thickness = 2.0 });
            }

            loop: for (dvui.events()) |*e| {
                if (!cell_box.matchEvent(e)) continue;

                switch (e.evt) {
                    .mouse => |me| {
                        if (me.action == .press and me.button.pointer()) {
                            e.handle(@src(), cell_box.data());
                            dvui.captureMouse(cell_box.data(), e.num);
                            dvui.dragPreStart(me.p, .{
                                .size = reorderable.data().rectScale().r.size(),
                                .offset = reorderable.data().rectScale().r.topLeft().diff(me.p),
                            });
                        } else if (me.action == .release and me.button.pointer()) {
                            dvui.captureMouse(null, e.num);
                            dvui.dragEnd();
                            switch (orientation) {
                                .horizontal => self.columns_drag_index = null,
                                .vertical => self.rows_drag_index = null,
                            }
                        } else if (me.action == .motion) {
                            if (dvui.captured(cell_box.data().id)) {
                                e.handle(@src(), cell_box.data());
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
    }

    const final_slot_id = switch (orientation) {
        .horizontal => file.columns,
        .vertical => file.rows,
    };
    if (reorder.needFinalSlot()) {
        var reorderable = reorder.reorderable(@src(), .{
            .mode = reorder_mode,
            .last_slot = true,
            .clamp_to_edges = true,
        }, .{
            .expand = reorder_expand,
            .id_extra = final_slot_id,
            .padding = dvui.Rect.all(0),
            .margin = dvui.Rect.all(0),
            .min_size_content = cell_min_size,
        });
        defer reorderable.deinit();

        if (reorderable.targetRectScale()) |trs| {
            target_rs_screen = trs;
        }

        if (reorderable.insertBefore()) {
            switch (orientation) {
                .horizontal => self.columns_insert_before_index = final_slot_id,
                .vertical => self.rows_insert_before_index = final_slot_id,
            }
        }
    }

    // Drag overlay: draw the dragged column/row label on the highlighted target slot in
    // highlight-text color (no extra fill, the reorderable's own focus fill is the
    // background) and a thick err-colored marker line at the dragged-from position in the
    // ruler that lines up with the equivalent indicator in the file canvas.
    const drag_idx_for_overlay = switch (orientation) {
        .horizontal => self.columns_drag_index,
        .vertical => self.rows_drag_index,
    };
    if (drag_idx_for_overlay) |di| {
        const target_idx_opt = switch (orientation) {
            .horizontal => self.columns_target_index,
            .vertical => self.rows_target_index,
        };
        const same_slot = target_idx_opt == di;

        if (target_rs_screen) |trs| {
            const drag_label_opt: ?[]const u8 = switch (orientation) {
                .horizontal => file.fmtColumn(dvui.currentWindow().arena(), @intCast(di)) catch null,
                .vertical => std.fmt.allocPrint(dvui.currentWindow().arena(), "{d}", .{di}) catch null,
            };
            if (drag_label_opt) |drag_label| {
                if (same_slot) {
                    // Reorderable still draws theme focus fill for the drop target; paint control
                    // hover on top so "no move" matches ruler button hover styling.
                    trs.r.fill(.all(0), .{ .color = dvui.themeGet().color(.control, .fill_hover), .fade = 1.0 });
                }
                self.drawRulerLabel(.{
                    .font = font,
                    .label = drag_label,
                    .rect = trs.r,
                    .color = if (same_slot)
                        dvui.themeGet().color(.control, .text).opacity(0.5)
                    else
                        dvui.themeGet().color(.highlight, .text),
                    .mode = switch (orientation) {
                        .horizontal => .horizontal,
                        .vertical => .vertical,
                    },
                    .largest_label = if (orientation == .vertical) largest_row_index_label else null,
                    .ref_size_physical = vertical_row_layout_size_phys,
                });
            }
        }

        // Use the canvas data->screen mapping for the cross-axis position so the marker
        // line aligns exactly with the err indicator drawn over the file canvas grid.
        // The other axis uses the ruler's own screen extents so the line fills the ruler.
        const target_idx_for_line = switch (orientation) {
            .horizontal => self.columns_target_index,
            .vertical => self.rows_target_index,
        };
        if (target_idx_for_line) |ti| {
            if (di != ti) {
                const removed_data_rect = switch (orientation) {
                    .horizontal => file.columnRect(di),
                    .vertical => file.rowRect(di),
                };
                const removed_canvas_screen = file.editor.canvas.screenFromDataRect(removed_data_rect);
                const ruler_screen = outer_box.data().contentRectScale().r;
                const err_color = dvui.themeGet().color(.err, .fill);
                const thickness = 3.0 * dvui.currentWindow().natural_scale;
                switch (orientation) {
                    .horizontal => {
                        const edge_x = if (di < ti)
                            removed_canvas_screen.x
                        else
                            removed_canvas_screen.x + removed_canvas_screen.w;
                        dvui.Path.stroke(.{ .points = &.{
                            .{ .x = edge_x, .y = ruler_screen.y },
                            .{ .x = edge_x, .y = ruler_screen.y + ruler_screen.h },
                        } }, .{ .thickness = thickness, .color = err_color });
                    },
                    .vertical => {
                        const edge_y = if (di < ti)
                            removed_canvas_screen.y
                        else
                            removed_canvas_screen.y + removed_canvas_screen.h;
                        dvui.Path.stroke(.{ .points = &.{
                            .{ .x = ruler_screen.x, .y = edge_y },
                            .{ .x = ruler_screen.x + ruler_screen.w, .y = edge_y },
                        } }, .{ .thickness = thickness, .color = err_color });
                    },
                }
            }
        }
    }
}

pub const TextLabelOptions = struct {
    pub const Mode = enum {
        horizontal,
        vertical,
    };

    font: dvui.Font,
    label: []const u8,
    rect: dvui.Rect.Physical,
    color: dvui.Color,
    mode: Mode = .horizontal,
    /// Widest row index string (e.g. `"99"`); layout cell size uses this, text may be a shorter index.
    largest_label: ?[]const u8 = null,
    /// When set, layout size for that widest string (already × `natural_scale`); skips `textSize(largest_label)` per cell.
    ref_size_physical: ?dvui.Size.Physical = null,
};

pub fn drawRulerLabel(_: *Workspace, options: TextLabelOptions) void {
    const font = options.font;
    const label = options.label;
    const rect = options.rect;
    const color = options.color;
    const natural = dvui.currentWindow().natural_scale;

    const ref_for_layout = options.largest_label orelse label;
    const label_size = options.ref_size_physical orelse font.textSize(ref_for_layout).scale(natural, dvui.Size.Physical);
    const actual_label_size = if (std.mem.eql(u8, ref_for_layout, label))
        label_size
    else
        font.textSize(label).scale(natural, dvui.Size.Physical);

    const padding = fizzy.editor.settings.ruler_padding * natural;

    var label_rect = rect;

    if (label_size.w + padding <= label_rect.w and options.mode == .horizontal) {
        label_rect.h = label_size.h + padding;
        label_rect.x += (label_rect.w - actual_label_size.w) / 2.0;
        label_rect.y += (label_rect.h - actual_label_size.h) / 2.0;

        dvui.renderText(.{
            .text = label,
            .font = font,
            .color = color,
            .rs = .{
                .r = label_rect,
                .s = natural,
            },
        }) catch {
            dvui.log.err("Failed to render text", .{});
        };
    } else if (label_size.h + padding <= label_rect.h and options.mode == .vertical) {
        label_rect.w = label_size.h + padding;
        label_rect.x += (label_rect.w - actual_label_size.w) / 2.0;
        label_rect.y += (label_rect.h - actual_label_size.h) / 2.0;

        dvui.renderText(.{
            .text = label,
            .font = font,
            .color = color,
            .rs = .{
                .r = label_rect,
                .s = natural,
            },
        }) catch {
            dvui.log.err("Failed to render text", .{});
        };
    }
}

pub fn processColumnReorder(self: *Workspace) void {
    if (self.columns_removed_index) |columns_removed_index| {
        if (self.columns_insert_before_index) |columns_insert_before_index| {
            defer self.columns_removed_index = null;
            defer self.columns_insert_before_index = null;

            if (columns_removed_index == columns_insert_before_index or columns_removed_index + 1 == columns_insert_before_index) return;

            const file = &fizzy.editor.open_files.values()[self.open_file_index];

            file.reorderColumns(columns_removed_index, columns_insert_before_index) catch {
                dvui.log.err("Failed to reorder columns", .{});
                return;
            };

            // We'll store the previous indices for clarity.
            const prev_removed_index = columns_removed_index;
            const prev_insert_before_index = columns_insert_before_index;

            if (prev_removed_index < prev_insert_before_index) {
                file.history.append(.{
                    .reorder_col_row = .{
                        .mode = .columns,
                        .removed_index = prev_insert_before_index - 1,
                        .insert_before_index = prev_removed_index,
                    },
                }) catch {
                    dvui.log.err("Failed to append history", .{});
                };
            } else {
                file.history.append(.{
                    .reorder_col_row = .{
                        .mode = .columns,
                        .removed_index = prev_insert_before_index,
                        .insert_before_index = prev_removed_index + 1,
                    },
                }) catch {
                    dvui.log.err("Failed to append history", .{});
                };
            }
        }
    }
}

pub fn processRowReorder(self: *Workspace) void {
    if (self.rows_removed_index) |rows_removed_index| {
        if (self.rows_insert_before_index) |rows_insert_before_index| {
            defer self.rows_removed_index = null;
            defer self.rows_insert_before_index = null;
            if (rows_removed_index == rows_insert_before_index or rows_removed_index + 1 == rows_insert_before_index) return;

            const file = &fizzy.editor.open_files.values()[self.open_file_index];

            file.reorderRows(rows_removed_index, rows_insert_before_index) catch {
                dvui.log.err("Failed to reorder rows", .{});
                return;
            };

            // We'll store the previous indices for clarity.
            const prev_removed_index = rows_removed_index;
            const prev_insert_before_index = rows_insert_before_index;

            if (prev_removed_index < prev_insert_before_index) {
                file.history.append(.{
                    .reorder_col_row = .{
                        .mode = .rows,
                        .removed_index = prev_insert_before_index - 1,
                        .insert_before_index = prev_removed_index,
                    },
                }) catch {
                    dvui.log.err("Failed to append history", .{});
                };
            } else {
                file.history.append(.{
                    .reorder_col_row = .{
                        .mode = .rows,
                        .removed_index = prev_insert_before_index,
                        .insert_before_index = prev_removed_index + 1,
                    },
                }) catch {
                    dvui.log.err("Failed to append history", .{});
                };
            }
        }
    }
}

pub fn drawTransformDialog(self: *Workspace, container: *dvui.WidgetData) void {
    const file = &fizzy.editor.open_files.values()[self.open_file_index];
    if (file.editor.transform) |*transform| {
        var rect = container.rect;
        rect.w = 0;
        rect.h = 0;

        var fw: dvui.FloatingWidget = undefined;
        fw.init(@src(), .{}, .{
            .rect = .{ .x = container.rectScale().r.toNatural().x + 10, .y = container.rectScale().r.toNatural().y + 10, .w = 0, .h = 0 },
            .expand = .none,
            .background = true,
            .color_fill = dvui.themeGet().color(.control, .fill),
            .corner_radius = dvui.Rect.all(8),
            .box_shadow = .{
                .color = .black,
                .alpha = 0.2,
                .fade = 8,
                .corner_radius = dvui.Rect.all(8),
            },
        });
        defer fw.deinit();

        var anim = dvui.animate(@src(), .{ .kind = .vertical, .duration = 450_000, .easing = dvui.easing.outBack }, .{});
        defer anim.deinit();

        var anim_box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
            .background = false,
        });
        defer anim_box.deinit();

        dvui.labelNoFmt(@src(), "TRANSFORM", .{ .align_x = 0.5 }, .{
            .padding = dvui.Rect.all(4),
            .expand = .horizontal,
            .font = dvui.Font.theme(.heading).withWeight(.bold),
        });
        _ = dvui.separator(@src(), .{ .expand = .horizontal });

        _ = dvui.spacer(@src(), .{ .expand = .horizontal });

        var degrees: f32 = std.math.radiansToDegrees(transform.rotation);

        var slider_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = false,
        });

        if (dvui.sliderEntry(@src(), "{d:0.0}°", .{
            .value = &degrees,
            .min = 0,
            .max = 360,
            .interval = 1,
        }, .{ .expand = .horizontal, .color_fill = dvui.themeGet().color(.window, .fill) })) {
            transform.rotation = std.math.degreesToRadians(degrees);
        }
        slider_box.deinit();

        if (transform.ortho) {
            var box = dvui.box(@src(), .{ .dir = .horizontal, .equal_space = true }, .{
                .expand = .horizontal,
                .background = false,
            });
            defer box.deinit();
            dvui.label(@src(), "Width: {d:0.0}", .{transform.point(.bottom_left).diff(transform.point(.bottom_right).*).length()}, .{ .expand = .horizontal, .font = dvui.Font.theme(.heading) });
            dvui.label(@src(), "Height: {d:0.0}", .{transform.point(.top_left).diff(transform.point(.bottom_left).*).length()}, .{ .expand = .horizontal, .font = dvui.Font.theme(.heading) });
        }

        {
            var box = dvui.box(@src(), .{ .dir = .horizontal, .equal_space = true }, .{
                .expand = .horizontal,
                .background = false,
            });
            defer box.deinit();
            if (dvui.buttonIcon(@src(), "transform_cancel", icons.tvg.lucide.@"trash-2", .{}, .{ .stroke_color = dvui.themeGet().color(.window, .fill) }, .{ .style = .err, .expand = .horizontal })) {
                fizzy.editor.cancel() catch {
                    dvui.log.err("Failed to cancel transform", .{});
                };
            }
            if (dvui.buttonIcon(@src(), "transform_accept", icons.tvg.lucide.check, .{}, .{ .stroke_color = dvui.themeGet().color(.window, .fill) }, .{ .style = .highlight, .expand = .horizontal })) {
                fizzy.editor.accept() catch {
                    dvui.log.err("Failed to accept transform", .{});
                };
            }
        }
    }
}

/// Floating rounded-pill quick-access bar anchored to the top-right of the workspace
/// canvas. Mirrors the Edit menu (Undo / Redo / Copy / Paste / Transform / Grid Layout)
/// with icon-only round buttons sized to match the toolbox buttons. Starts collapsed as a
/// single hamburger circle; tapping toggles the row of action buttons in/out with a
/// width animation.
pub fn drawEditPill(self: *Workspace, container: *dvui.WidgetData) void {
    const file = fizzy.editor.activeFile() orelse return;

    const button_size: f32 = 36;
    const button_gap: f32 = 6;
    const pill_padding: f32 = 6;
    const margin: f32 = 10;
    // Canvas scroll area uses a non-overlay vertical bar on the right edge; keep the
    // pill clear of it (see `CanvasWidget.install` + dvui `ScrollBarWidget` width).
    const right_margin: f32 = margin + dvui.ScrollBarWidget.defaults.min_sizeGet().w;
    // Icons render at ~60% of their previous size — previous padding was 0.22 (icon
    // ≈ 56% of button); new padding is 0.33 so the icon ends up ≈ 34% of the button,
    // which is roughly 60% of the prior icon footprint.
    const icon_padding: f32 = button_size * 0.33;

    const Action = enum { save, exportd, undo, redo, copy, paste, transform, grid_layout };
    const Entry = struct {
        action: Action,
        tvg: []const u8,
        tooltip: []const u8,
    };

    const entries = [_]Entry{
        .{ .action = .save, .tvg = icons.tvg.lucide.save, .tooltip = "Save" },
        .{ .action = .exportd, .tvg = icons.tvg.lucide.@"file-output", .tooltip = "Export" },
        .{ .action = .undo, .tvg = icons.tvg.lucide.undo, .tooltip = "Undo" },
        .{ .action = .redo, .tvg = icons.tvg.lucide.redo, .tooltip = "Redo" },
        .{ .action = .copy, .tvg = icons.tvg.lucide.copy, .tooltip = "Copy" },
        .{ .action = .paste, .tvg = icons.tvg.lucide.@"clipboard-paste", .tooltip = "Paste" },
        .{ .action = .transform, .tvg = icons.tvg.lucide.scaling, .tooltip = "Transform" },
        .{ .action = .grid_layout, .tvg = icons.tvg.lucide.@"layout-grid", .tooltip = "Grid Layout" },
    };

    // Vertical pill: width is fixed (one button + padding), height animates between a
    // single-button "collapsed" state and the full-stack "expanded" state. Most screens
    // have more vertical real estate than horizontal, so growing the pill downward keeps
    // it from eating into the canvas's working width.
    const pill_w: f32 = button_size + 2 * pill_padding;
    const collapsed_h: f32 = button_size + 2 * pill_padding;
    const expanded_h: f32 = @as(f32, @floatFromInt(entries.len + 1)) * button_size +
        @as(f32, @floatFromInt(entries.len)) * button_gap + 2 * pill_padding;
    const pill_radius: f32 = pill_w / 2;
    const btn_radius: f32 = button_size / 2;

    // Drive the expand/collapse with a dvui animation. Look up the current value, and on
    // a toggle click kick off a new animation between the current value and the target.
    const anim_id = dvui.Id.update(container.id, "edit_pill_expand");
    var anim_value: f32 = if (self.edit_pill_expanded) 1.0 else 0.0;
    if (dvui.animationGet(anim_id, "_t")) |a| anim_value = std.math.clamp(a.value(), 0.0, 1.0);

    const pill_h: f32 = collapsed_h + (expanded_h - collapsed_h) * anim_value;

    // Compute the scroll-area rect — the canvas region inside the rulers. We pull this
    // off the live `canvas_vbox` (so the values are this frame's, not a stale latch) and
    // subtract the ruler thickness from the top/left. Anchoring against this rect means
    // the pill follows the workspace exactly: as a split is dragged shut the canvas area
    // shrinks, and once it's narrower than the pill we bail and draw nothing this frame —
    // so closing splits cleanly hides the menu.
    const wb = container.rectScale().r.toNatural();
    const ruler_top: f32 = if (fizzy.editor.settings.show_rulers) self.horizontal_ruler_height else 0;
    const ruler_left: f32 = if (fizzy.editor.settings.show_rulers) self.vertical_ruler_width else 0;
    const canvas_nat = dvui.Rect{
        .x = wb.x + ruler_left,
        .y = wb.y + ruler_top,
        .w = wb.w - ruler_left,
        .h = wb.h - ruler_top,
    };

    if (canvas_nat.w < pill_w + margin + right_margin or canvas_nat.h < collapsed_h + 2 * margin) return;

    const pill_x: f32 = canvas_nat.x + canvas_nat.w - right_margin - pill_w;
    const pill_y: f32 = canvas_nat.y + margin;

    // Clamp the bottom edge so the expanded pill never spills past the canvas area —
    // FloatingWidget bypasses parent clipping, so we cap the height explicitly.
    const max_pill_h: f32 = canvas_nat.h - 2 * margin;
    const effective_pill_h: f32 = @min(pill_h, max_pill_h);

    var fw: dvui.FloatingWidget = undefined;
    fw.init(@src(), .{}, .{
        .rect = .{
            .x = pill_x,
            .y = pill_y,
            .w = pill_w,
            .h = effective_pill_h,
        },
        .expand = .none,
        .background = self.edit_pill_expanded,
        .color_fill = dvui.themeGet().color(.window, .fill),
        .corner_radius = dvui.Rect.all(pill_radius),
        .box_shadow = if (self.edit_pill_expanded) .{
            .color = .black,
            .alpha = 0.25,
            .fade = 10,
            .offset = .{ .x = 0, .y = 3 },
            .corner_radius = dvui.Rect.all(pill_radius),
        } else null,
    });
    defer fw.deinit();

    var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = false,
        .padding = dvui.Rect.all(pill_padding),
    });
    defer vbox.deinit();

    // Hamburger toggle is always present at the top of the pill; the stack of action
    // buttons grows downward beneath it as the pill expands.
    {
        var btn: dvui.ButtonWidget = undefined;
        btn.init(@src(), .{}, .{
            .id_extra = entries.len, // distinct from action button ids below
            .min_size_content = .{ .w = button_size, .h = button_size },
            .expand = .none,
            .gravity_x = 0.5,
            .gravity_y = 0.0,
            .background = true,
            .corner_radius = dvui.Rect.all(btn_radius),
            .color_fill = dvui.themeGet().color(.content, .fill),
            .color_fill_hover = dvui.themeGet().color(.content, .fill).lighten(if (dvui.themeGet().dark) 10.0 else -10.0),
            .color_border = .transparent,
            .padding = .all(0),
            .margin = .{},
            .box_shadow = .{
                .color = .black,
                .alpha = 0.2,
                .fade = 4,
                .offset = .{ .x = 0, .y = 2 },
                .corner_radius = dvui.Rect.all(btn_radius),
            },
        });
        defer btn.deinit();
        btn.processEvents();
        btn.drawBackground();

        const icon_color = dvui.themeGet().color(.content, .text);
        dvui.icon(
            @src(),
            "edit_pill_toggle",
            icons.tvg.lucide.menu,
            .{ .stroke_color = icon_color, .fill_color = icon_color },
            .{
                .expand = .ratio,
                .gravity_x = 0.5,
                .gravity_y = 0.5,
                .min_size_content = .{ .w = 1.0, .h = 1.0 },
                .padding = dvui.Rect.all(icon_padding),
            },
        );

        if (btn.clicked()) {
            self.edit_pill_expanded = !self.edit_pill_expanded;
            const target: f32 = if (self.edit_pill_expanded) 1.0 else 0.0;
            dvui.animation(anim_id, "_t", .{
                .start_val = anim_value,
                .end_val = target,
                .end_time = 250_000,
                .easing = dvui.easing.outBack,
            });
        }
    }

    // Action buttons live inside a scroll area so the pill stays the right width and
    // never visually "squishes" when there isn't enough vertical room — instead the
    // overflow buttons become reachable via vertical scroll inside the pill. Bars are
    // hidden to preserve the rounded-pill look; touch / wheel still drives the scroll.
    var actions_scroll = dvui.scrollArea(@src(), .{
        .vertical_bar = .hide,
        .horizontal_bar = .hide,
    }, .{
        .expand = .both,
        .background = false,
        .padding = .{},
        .margin = .{},
        .border = dvui.Rect.all(0),
        .color_fill = .transparent,
    });
    defer actions_scroll.deinit();

    // Action buttons stacked below the hamburger. We draw them all and let the
    // scrollArea handle any overflow when the pill is clamped to the canvas height.
    for (entries, 0..) |entry, i| {
        const enabled: bool = switch (entry.action) {
            .save => file.dirty(),
            .undo => file.history.undo_stack.items.len > 0,
            .redo => file.history.redo_stack.items.len > 0,
            else => true,
        };

        var btn: dvui.ButtonWidget = undefined;
        btn.init(@src(), .{}, .{
            .id_extra = i,
            .min_size_content = .{ .w = button_size, .h = button_size },
            .expand = .none,
            .gravity_x = 0.5,
            .background = true,
            .corner_radius = dvui.Rect.all(btn_radius),
            .color_fill = dvui.themeGet().color(.content, .fill),
            .color_fill_hover = dvui.themeGet().color(.content, .fill).lighten(if (dvui.themeGet().dark) 10.0 else -10.0),
            .color_border = .transparent,
            .padding = .all(0),
            .margin = .{ .y = button_gap },
            .box_shadow = .{
                .color = .black,
                .alpha = 0.2,
                .fade = 4,
                .offset = .{ .x = 0, .y = 2 },
                .corner_radius = dvui.Rect.all(btn_radius),
            },
        });
        defer btn.deinit();
        btn.processEvents();
        btn.drawBackground();

        const icon_color = if (enabled) dvui.themeGet().color(.content, .text) else dvui.themeGet().color(.content, .text).opacity(0.35);

        dvui.icon(
            @src(),
            entry.tooltip,
            entry.tvg,
            .{ .stroke_color = icon_color, .fill_color = icon_color },
            .{
                .expand = .ratio,
                .gravity_x = 0.5,
                .gravity_y = 0.5,
                .min_size_content = .{ .w = 1.0, .h = 1.0 },
                .padding = dvui.Rect.all(icon_padding),
            },
        );

        // Suppress activation while collapsed (or mid-animation) so a stray tap on a
        // partially-visible button doesn't fire an Edit action behind the hamburger.
        const fully_expanded = anim_value >= 0.999;
        if (btn.clicked() and enabled and fully_expanded) {
            switch (entry.action) {
                .save => fizzy.editor.save() catch {
                    dvui.log.err("Failed to save", .{});
                },
                .exportd => {
                    // Open the Export dialog (same configuration the `export` keybind uses).
                    var mutex = fizzy.dvui.dialog(@src(), .{
                        .displayFn = fizzy.Editor.Dialogs.Export.dialog,
                        .callafterFn = fizzy.Editor.Dialogs.Export.callAfter,
                        .title = "Export...",
                        .ok_label = "Export",
                        .cancel_label = "Cancel",
                        .resizeable = false,
                        .modal = false,
                        .header_kind = .info,
                        .default = .ok,
                    });
                    mutex.mutex.unlock(dvui.io);
                },
                .undo => file.history.undoRedo(file, .undo) catch {
                    dvui.log.err("Failed to undo", .{});
                },
                .redo => file.history.undoRedo(file, .redo) catch {
                    dvui.log.err("Failed to redo", .{});
                },
                .copy => fizzy.editor.copy() catch {
                    dvui.log.err("Failed to copy", .{});
                },
                .paste => fizzy.editor.paste() catch {
                    dvui.log.err("Failed to paste", .{});
                },
                .transform => fizzy.editor.transform() catch {
                    dvui.log.err("Failed to start transform", .{});
                },
                .grid_layout => fizzy.editor.requestGridLayoutDialog(),
            }
        }
    }
}

/// Floating round button anchored just to the left of the Edit pill at the top-right of
/// the canvas. Tapping it shows a tooltip explaining the gesture; the primary action is
/// to drag from the button toward whatever pixel you want to sample. The button itself
/// stays put — instead, while the drag is in progress, we route the touch position
/// through to `file.editor.canvas.sample_data_point` so `FileWidget.drawSample` renders
/// the existing color-dropper magnifier at the touch location. On release we read the
/// color underneath the sample point and apply it to the primary color slot.
pub fn drawSampleButton(self: *Workspace, container: *dvui.WidgetData) void {
    const file = fizzy.editor.activeFile() orelse return;

    const pill_button_size: f32 = 36;
    const pill_padding: f32 = 6;
    const pill_outer_w: f32 = pill_button_size + 2 * pill_padding;
    const button_size: f32 = 36;
    const btn_radius: f32 = button_size / 2;
    const icon_padding: f32 = button_size * 0.33;
    const margin: f32 = 10;
    const right_margin: f32 = margin + dvui.ScrollBarWidget.defaults.min_sizeGet().w;
    const gap: f32 = 6;

    // Anchor against the same canvas-scroll-area rect the pill uses.
    const wb = container.rectScale().r.toNatural();
    const ruler_top: f32 = if (fizzy.editor.settings.show_rulers) self.horizontal_ruler_height else 0;
    const ruler_left: f32 = if (fizzy.editor.settings.show_rulers) self.vertical_ruler_width else 0;
    const canvas_nat = dvui.Rect{
        .x = wb.x + ruler_left,
        .y = wb.y + ruler_top,
        .w = wb.w - ruler_left,
        .h = wb.h - ruler_top,
    };

    // Only draw when the canvas area can fit pill + gap + sample button + margins.
    if (canvas_nat.w < pill_outer_w + gap + button_size + margin + right_margin) return;
    if (canvas_nat.h < button_size + 2 * margin) return;

    const btn_x = canvas_nat.x + canvas_nat.w - right_margin - pill_outer_w - gap - button_size;
    // Match the hamburger row inside the pill (pill top + inner vbox padding).
    const btn_y = canvas_nat.y + margin + pill_padding;

    var fw: dvui.FloatingWidget = undefined;
    fw.init(@src(), .{}, .{
        .rect = .{ .x = btn_x, .y = btn_y, .w = button_size, .h = button_size },
        .expand = .none,
        .background = false,
    });
    defer fw.deinit();

    var btn: dvui.ButtonWidget = undefined;
    // `touch_drag = true` keeps `ButtonWidget`'s own capture alive while the touch is
    // dragging away from the button — without it, dvui's default `clickedEx` releases
    // capture as soon as the drag crosses the threshold (treating the gesture as a
    // canceled scroll), which would also cancel our custom drag-to-sample handler.
    btn.init(@src(), .{ .touch_drag = true }, .{
        .expand = .both,
        .background = true,
        .min_size_content = .{ .w = button_size, .h = button_size },
        .corner_radius = dvui.Rect.all(btn_radius),
        .color_fill = dvui.themeGet().color(.content, .fill),
        .color_fill_hover = dvui.themeGet().color(.content, .fill).lighten(if (dvui.themeGet().dark) 10.0 else -10.0),
        .color_border = .transparent,
        .padding = .all(0),
        .margin = .{},
        .box_shadow = .{
            .color = .black,
            .alpha = 0.2,
            .fade = 4,
            .offset = .{ .x = 0, .y = 2 },
            .corner_radius = dvui.Rect.all(btn_radius),
        },
    });
    defer btn.deinit();

    // Persistent drag state (a press is "drag-sampling" once motion clears the dvui drag
    // threshold). Stored via dataSet because the button widget is recreated each frame.
    const drag_state_id = dvui.Id.update(container.id, "sample_button_drag");
    var is_drag_sampling = dvui.dataGet(null, drag_state_id, "active", bool) orelse false;
    var did_sample = dvui.dataGet(null, drag_state_id, "did_sample", bool) orelse false;

    // The button's screen rect is the "press home base"; events that happen here belong
    // to us regardless of whether motion has carried the pointer away.
    const btn_rs = btn.data().rectScale();

    // Custom event handling runs *before* `btn.processEvents()` so we can claim the
    // press / motion / release events first. `ButtonWidget.clickedEx` ALWAYS releases
    // mouse capture and ends the drag on a release event (regardless of touch_drag) —
    // if we ran after it, our release branch would see `dvui.captured(...)` already
    // false and the magnifier would stay stuck on screen. Calling `e.handle(...)` here
    // makes `clickedEx`'s match-event check skip these events entirely, so the button
    // leaves our gesture alone.
    for (dvui.events()) |*e| {
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;

        switch (me.action) {
            .press => {
                if (!me.button.pointer()) continue;
                if (!btn_rs.r.contains(me.p)) continue;
                e.handle(@src(), btn.data());
                dvui.captureMouse(btn.data(), e.num);
                dvui.dragPreStart(me.p, .{ .name = "sample_button_drag" });
                is_drag_sampling = false;
                did_sample = false;
            },
            .motion => {
                if (!dvui.captured(btn.data().id)) continue;
                if (dvui.dragging(me.p, "sample_button_drag")) |_| {
                    is_drag_sampling = true;
                    if (file.editor.canvas.samplePointerInViewport(me.p)) {
                        const data_pt = file.editor.canvas.dataFromScreenPoint(me.p);
                        dvui.dataSet(null, file.editor.canvas.id, "sample_data_point", data_pt);
                        did_sample = true;
                    } else {
                        dvui.dataRemove(null, file.editor.canvas.id, "sample_data_point");
                    }
                    dvui.refresh(null, @src(), file.editor.canvas.id);
                    e.handle(@src(), btn.data());
                }
            },
            .release => {
                if (!me.button.pointer()) continue;
                if (!dvui.captured(btn.data().id)) continue;
                e.handle(@src(), btn.data());
                dvui.captureMouse(null, e.num);
                dvui.dragEnd();

                if (is_drag_sampling and did_sample and file.editor.canvas.samplePointerInViewport(me.p)) {
                    const data_pt = file.editor.canvas.dataFromScreenPoint(me.p);
                    fizzy.dvui.FileWidget.sampleColorAtPoint(file, data_pt, false, true, true);
                }

                // Clear sample state so the magnifier disappears on the next frame.
                dvui.dataRemove(null, file.editor.canvas.id, "sample_data_point");
                is_drag_sampling = false;
                did_sample = false;
                dvui.refresh(null, @src(), file.editor.canvas.id);
            },
            else => {},
        }
    }

    // Persist the drag state for the next frame's widget recreate.
    dvui.dataSet(null, drag_state_id, "active", is_drag_sampling);
    dvui.dataSet(null, drag_state_id, "did_sample", did_sample);

    // Now let the button run its own pass to handle hover styling against any remaining
    // (non-claimed) events — i.e. plain mouse hover when we're not in a drag.
    btn.processEvents();
    btn.drawBackground();

    const icon_color = dvui.themeGet().color(.content, .text);
    dvui.icon(
        @src(),
        "sample_dropper",
        icons.tvg.lucide.pipette,
        .{ .stroke_color = icon_color, .fill_color = icon_color },
        .{
            .expand = .ratio,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 1.0, .h = 1.0 },
            .padding = dvui.Rect.all(icon_padding),
        },
    );

    // While the drag is in progress, hide the OS cursor entirely so only the canvas
    // magnifier (drawn at the touch point via `FileWidget.drawSample`) communicates
    // where the sample is happening. Set after `btn.processEvents()` so it overrides
    // the `.hand` hover cursor `clickedEx` would otherwise leave in place.
    if (is_drag_sampling) {
        dvui.cursorSet(.hidden);
    }

    // Tooltip prompting the gesture. We hide it during an active sample drag so it
    // doesn't compete with the magnifier on screen.
    if (!is_drag_sampling) {
        var tooltip: dvui.FloatingTooltipWidget = undefined;
        tooltip.init(@src(), .{
            .active_rect = btn.data().rectScale().r,
            .delay = 350_000,
        }, .{
            .color_fill = dvui.themeGet().color(.window, .fill),
            .border = dvui.Rect.all(0),
            .box_shadow = .{
                .color = .black,
                .shrink = 0,
                .corner_radius = dvui.Rect.all(8),
                .offset = .{ .x = 0, .y = 2 },
                .fade = 4,
                .alpha = 0.2,
            },
        });
        defer tooltip.deinit();

        if (tooltip.shown()) {
            var anim = dvui.animate(@src(), .{ .kind = .alpha, .duration = 250_000 }, .{ .expand = .both });
            defer anim.deinit();

            var tl = dvui.textLayout(@src(), .{}, .{
                .background = false,
                .padding = dvui.Rect.all(6),
            });
            tl.format("Drag to sample color", .{}, .{ .font = dvui.Font.theme(.body) });
            tl.deinit();
        }
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
                    fizzy_color = fizzy_color.lerp(fizzy.math.Color.initBytes(theme_bg.r, theme_bg.g, theme_bg.b, 255), fizzy_color.value[3]);
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

        fizzy.dvui.labelWithKeybind(
            "New File",
            dvui.currentWindow().keybinds.get("new_file") orelse .{},
            true,
            .{ .padding = dvui.Rect.all(4), .expand = .horizontal, .gravity_x = 1.0 },
            .{ .padding = dvui.Rect.all(4), .expand = .horizontal, .gravity_x = 1.0 },
        );

        if (button.clicked()) {
            fizzy.editor.requestNewFileDialog();
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

        fizzy.dvui.labelWithKeybind(
            "Open Folder",
            dvui.currentWindow().keybinds.get("open_folder") orelse .{},
            true,
            .{ .padding = dvui.Rect.all(4), .expand = .horizontal, .gravity_x = 1.0 },
            .{ .padding = dvui.Rect.all(4), .expand = .horizontal, .gravity_x = 1.0 },
        );

        if (button.clicked()) {
            fizzy.backend.showOpenFolderDialog(setProjectFolderCallback, null);
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

        fizzy.dvui.labelWithKeybind(
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
            //         _ = fizzy.editor.openFilePath(file, fizzy.editor.open_workspace_grouping) catch {
            //             std.log.err("Failed to open file: {s}", .{file});
            //         };
            //     }
            // }

            fizzy.backend.showOpenFileDialog(openFilesCallback, &.{
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

        var i: usize = fizzy.editor.recents.folders.items.len;
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

            const folder = fizzy.editor.recents.folders.items[i - 1];
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
                try fizzy.editor.setProjectFolder(folder);
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
        fizzy.editor.setProjectFolder(f[0]) catch {
            dvui.log.err("Failed to set project folder: {s}", .{f[0]});
        };
    }
}

pub fn openFilesCallback(files: ?[][:0]const u8) void {
    if (files) |f| {
        for (f) |file| {
            _ = fizzy.editor.openFilePath(file, fizzy.editor.open_workspace_grouping) catch {
                dvui.log.err("Failed to open file: {s}", .{file});
            };
        }
    }
}
