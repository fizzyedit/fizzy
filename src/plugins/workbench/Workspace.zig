const std = @import("std");
const builtin = @import("builtin");

const dvui = @import("dvui");
const fizzy = @import("../../fizzy.zig");
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

/// Opaque per-pane state owned by the plugin that renders documents into this pane (today
/// only pixel art, via `CanvasData`: rulers, edit pill, grid-reorder drag, etc.). The
/// workbench never dereferences it — it just frees it through `plugin_view_destroy` when the
/// pane is torn down (`deinit`). Lazily created by the owning plugin on first document draw.
plugin_view_state: ?*anyopaque = null,
/// Teardown for `plugin_view_state`, set by the owner alongside the state. Null when no
/// plugin view has been attached.
plugin_view_destroy: ?*const fn (state: *anyopaque) void = null,

/// Physical-pixel content rect of this workspace's canvas vbox, captured each frame during
/// `drawCanvas` (or a sidebar view's `draw_workspace` takeover, e.g. pixel art's Project view).
/// `null` until the workspace has rendered at least once. Used
/// by the editor-level load/save toast overlays to center cards over the area the user is
/// actually looking at (rather than the OS window rect).
canvas_rect_physical: ?dvui.Rect.Physical = null,

pub fn init(grouping: u64) Workspace {
    return .{ .grouping = grouping };
}

/// Release any plugin-owned per-pane view state. Called when a pane is removed
/// (`Editor.rebuildWorkspaces`) and for each pane at editor shutdown.
pub fn deinit(self: *Workspace) void {
    if (self.plugin_view_state) |state| {
        if (self.plugin_view_destroy) |destroy| destroy(state);
        self.plugin_view_state = null;
        self.plugin_view_destroy = null;
    }
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
                    _ = fizzy.sprite_render.sprite(@src(), .{
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
