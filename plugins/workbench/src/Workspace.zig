//! One document pane: a region the workbench declares inside the main area, with the tab strip
//! it draws over that region's surfaces.
//!
//! A pane used to be a private subdivision — its own list of documents by grouping, its own
//! active index into the app's open-file array, its own drag/drop that rewrote both. Now the pane
//! is a region (`host.region`, keywords `{"document"}`, `shows = .many`) and each open document
//! is a surface the app registers; the tabs are `region.matching()`, the active tab is the
//! region's selection, and a tab moved to another pane is an assignment edit. Nothing here
//! remembers which documents it holds: the app does, by the pane's name, which is also what makes
//! last session's panes come back.
const std = @import("std");
const builtin = @import("builtin");

const core = @import("core");
const dvui = @import("dvui");
const sdk = @import("fizzy_sdk");
const runtime = @import("runtime.zig");
const icons = @import("icons");
const math = core.math;

pub const Workspace = @This();

/// The pane's key: half of its region id, and the number in its name. Minted by
/// `Workbench.newGroupingID`; the app still calls it a grouping because that is the word on the
/// document vtable.
grouping: u64 = 0,
/// A pane opened by a drop whose document is still loading. Empty for now, but not *emptied*:
/// `rebuildWorkspaces` must not close it before the load lands. Cleared by `addTab`.
expecting: bool = false,

/// What this pane showed last frame, for the commands that act on "the active document" between
/// frames. Read from the region during draw; never derived from the app's document array.
active: ?sdk.DocHandle = null,

/// Reorder bookkeeping for the frame: where a tab was lifted from and where it is about to land,
/// as indices into this pane's tab list.
tabs_removed_index: ?usize = null,
tabs_insert_before_index: ?usize = null,

/// Physical-pixel content rect of this pane's canvas, captured each frame. `null` until the pane
/// has rendered once. The editor-level load/save toasts centre over it.
canvas_rect_physical: ?dvui.Rect.Physical = null,

pub fn init(grouping: u64) Workspace {
    return .{ .grouping = grouping };
}

/// Release any plugin-owned per-pane canvas chrome. Called when a pane is removed and for each
/// pane at shutdown.
pub fn deinit(self: *Workspace) void {
    for (runtime.host().plugins.items) |plugin| {
        plugin.removeCanvasPane(self.grouping, runtime.allocator());
    }
}

/// The document a surface draws, if it is one. By the id's convention rather than a field on
/// `Surface`: a surface says what it is, and "is a document" is this plugin's question.
fn documentOf(s: *const sdk.Surface) ?sdk.DocHandle {
    const path = sdk.document.pathOfSurfaceId(s.id) orelse return null;
    return runtime.host().docFromPath(path);
}

/// The region name this pane persists under. One spelling, here, because the app's assignment
/// table is keyed by it and the workbench has to find last session's panes by it.
pub fn name(buf: []u8, grouping: u64) []const u8 {
    return std.fmt.bufPrint(buf, "Pane {d}", .{grouping}) catch "Pane";
}

/// The grouping a pane name encodes, or null if the name is not a pane's.
pub fn groupingOfName(region_name: []const u8) ?u64 {
    const prefix = "Pane ";
    if (!std.mem.startsWith(u8, region_name, prefix)) return null;
    return std.fmt.parseInt(u64, region_name[prefix.len..], 10) catch null;
}

const opacity = 60;

const color_0 = math.Color.initBytes(0, 0, 0, 0);
const color_1 = math.Color.initBytes(230, 175, 137, opacity);
const color_2 = math.Color.initBytes(216, 145, 115, opacity);
const color_3 = math.Color.initBytes(41, 23, 41, opacity);
const color_4 = math.Color.initBytes(194, 109, 92, opacity);
const color_5 = math.Color.initBytes(180, 89, 76, opacity);

const logo_colors: [12]math.Color = [_]math.Color{
    color_1, color_1, color_1,
    color_2, color_2, color_3,
    color_4, color_3, color_0,
    color_3, color_0, color_0,
};

pub fn draw(self: *Workspace) !dvui.App.Result {
    var name_buf: [32]u8 = undefined;
    var region = runtime.host().region(.{
        .name = name(&name_buf, self.grouping),
        .keywords = sdk.document.keywords,
        .shows = .many,
        .key = self.grouping,
        .expand = .both,
    }) orelse return .ok;
    defer region.deinit();

    // Clicking anywhere in the pane makes it the one commands act on.
    const pane_box = dvui.parentGet().data();
    for (dvui.events()) |*e| {
        if (!dvui.eventMatch(e, .{ .id = pane_box.id, .r = pane_box.rectScale().r })) continue;
        if (e.evt == .mouse) {
            if (e.evt.mouse.action == .press or (e.evt.mouse.action == .position and e.evt.mouse.mod.matchBind("ctrl/cmd"))) {
                runtime.workbench().open_workspace_grouping = self.grouping;
            }
        }
    }

    const tabs = region.matching();
    const selected = region.selected();
    self.active = if (selected) |s| documentOf(s) else null;

    if (tabs.len > 0) self.drawTabs(region, tabs, selected);
    try self.drawCanvas(region, tabs.len > 0);
    return .ok;
}

fn drawTabs(self: *Workspace, region: sdk.Host.Region, tabs: []const *sdk.Surface, selected: ?*sdk.Surface) void {
    defer self.processTabsDrag(region, tabs);

    var tabs_anim = dvui.animate(@src(), .{ .duration = 500_000, .kind = .vertical, .easing = dvui.easing.outBack }, .{});
    defer tabs_anim.deinit();

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
        .margin = dvui.Rect.all(0),
        .padding = dvui.Rect.all(0),
        .border = dvui.Rect.all(0),
        .corners = dvui.CornerRect.all(0),
        .id_extra = @intCast(self.grouping),
    });
    defer scroll_area.deinit();

    var reorder = dvui.reorder(@src(), .{ .drag_name = "tab_drag" }, .{
        .expand = .none,
        .background = false,
    });
    defer reorder.deinit();

    var tabs_hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .none,
        .margin = dvui.Rect.all(0),
        .padding = dvui.Rect.all(0),
        .id_extra = @intCast(self.grouping),
    });
    defer tabs_hbox.deinit();

    const pane_is_active = runtime.workbench().open_workspace_grouping == self.grouping;
    const selected_index: ?usize = blk: {
        const sel = selected orelse break :blk null;
        for (tabs, 0..) |t, i| if (t == sel) break :blk i;
        break :blk null;
    };

    for (tabs, 0..) |surface, i| {
        const doc = documentOf(surface) orelse continue;

        var reorderable = reorder.reorderable(@src(), .{}, .{
            .expand = .vertical,
            .id_extra = i,
            .padding = dvui.Rect.all(0),
            .margin = dvui.Rect.all(0),
            .border = .all(0),
        });
        defer reorderable.deinit();

        // Active-tab chrome belongs to the one pane that is active: four panes each dressing
        // their own tab as current is four claims to be where the next command lands.
        const is_selected = selected_index == i and pane_is_active;

        var hbox: dvui.BoxWidget = undefined;
        hbox.init(@src(), .{ .dir = .horizontal }, .{
            .expand = .none,
            .border = dvui.Rect.all(0),
            .color_fill = .{ .color = if (is_selected) .transparent else dvui.themeGet().color(.window, .fill).opacity(runtime.host().contentOpacity()) },
            .background = true,
            .id_extra = i,
            .padding = .{ .x = 2, .y = 2, .w = 2, .h = 0 },
            .margin = dvui.Rect.all(0),
        });
        defer hbox.deinit();

        const tab_hovered = core.widgets.hovered(hbox.data());

        if (reorderable.floating()) {
            runtime.workbench().dragging_surface = surface.id;
            hbox.data().options.color_fill = .{ .color = dvui.themeGet().color(.control, .fill) };
        }
        hbox.drawBackground();

        if (!is_selected and pane_is_active and reorder.drag_point == null) {
            // Edge shadows between the active tab and its neighbours.
            if (selected_index) |si| {
                if (i + 1 == si) core.draw.drawEdgeShadow(hbox.data().rectScale(), .right, .{});
                if (i == si + 1) core.draw.drawEdgeShadow(hbox.data().rectScale(), .left, .{});
            }
        }

        if (reorderable.removed()) {
            self.tabs_removed_index = i;
        } else if (reorderable.insertBefore()) {
            self.tabs_insert_before_index = i;
        }

        // Same fixed glyph slot as the file tree.
        const tab_doc_path = doc.owner.documentPath(doc);
        const tab_icon_color = dvui.themeGet().color(.control, .text);
        {
            var icon_slot = core.widgets.treeRowGlyph(@src(), .{ .gravity_y = 0.5, .margin = .{ .x = 4, .w = 2 } });
            defer icon_slot.deinit();
            if (!runtime.host().drawFileIcon(std.fs.path.extension(tab_doc_path), tab_doc_path, tab_icon_color)) {
                core.icon.icon(@src(), "file_icon", icons.tvg.lucide.file, .{
                    .stroke_color = .{ .color = tab_icon_color },
                }, core.widgets.treeRowIconOptions(.{}));
            }
        }

        dvui.labelNoFmt(@src(), surface.title, .{}, .{
            .color_text = .{ .color = if (is_selected) dvui.themeGet().color(.window, .text) else dvui.themeGet().color(.control, .text) },
            .padding = dvui.Rect.all(4),
            .gravity_y = 0.5,
        });

        const close_inner = core.dialogs.windowHeaderCloseInnerSide();

        const status_close_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .none,
            .gravity_y = 0.5,
            .margin = dvui.Rect.all(0),
            .padding = core.widgets.tab_status_inset,
            .min_size_content = .{ .w = close_inner, .h = close_inner },
        });
        defer status_close_box.deinit();

        // Saving has priority over hover/close/dirty indicators: the user wants visible
        // confirmation that the save is in flight, and the slot's size matches the close button
        // so the layout doesn't shift when saving starts/ends.
        const save_flash_elapsed = doc.owner.timeSinceSaveCompleteNs(doc);
        const save_in_check_phase = if (save_flash_elapsed) |elapsed|
            core.dialogs.bubbleSpinnerSaveInCheckPhase(elapsed)
        else
            false;
        const save_blocks_tab_close = doc.owner.isDocumentSaving(doc) or
            (doc.owner.showsSaveStatusIndicator(doc) and !save_in_check_phase);

        if (save_blocks_tab_close or (save_in_check_phase and !tab_hovered)) {
            core.dialogs.bubbleSpinner(@src(), .{
                .id_extra = i *% 16 + 5,
                .expand = .none,
                .min_size_content = .{ .w = close_inner, .h = close_inner },
                .gravity_x = 0.5,
                .gravity_y = 0.5,
                .color_text = .{ .color = dvui.themeGet().color(.window, .text) },
            }, .{
                .complete_elapsed_ns = save_flash_elapsed,
            });
        } else {
            var tab_close_button: dvui.ButtonWidget = undefined;
            tab_close_button.init(@src(), .{ .draw_focus = false }, core.widgets.tabCloseButtonOptions(.{
                .expand = .none,
                .min_size_content = .{ .w = close_inner, .h = close_inner },
                .gravity_x = 0.5,
                .gravity_y = 0.5,
                .id_extra = i *% 16 + 1,
            }));
            defer tab_close_button.deinit();

            tab_close_button.processEvents();

            const dirty = doc.owner.isDirty(doc);
            const show_close_visible = tab_hovered or (is_selected and !dirty);
            const err_accent = dvui.themeGet().color(.err, .fill);
            const close_hovered = tab_close_button.hovered();

            if (show_close_visible and (tab_hovered or close_hovered)) {
                const rs = tab_close_button.data().borderRectScale();
                rs.r.fill(.round(8), .{ .color = .{ .color = err_accent } });
            }

            if (dirty and !show_close_visible) {
                core.icon.icon(@src(), "dirty_icon", icons.tvg.lucide.@"circle-small", .{
                    .stroke_color = .{ .color = dvui.themeGet().color(.window, .text) },
                }, .{
                    .expand = .none,
                    .min_size_content = .{ .w = close_inner, .h = close_inner },
                    .gravity_x = 0.5,
                    .gravity_y = 0.5,
                    .id_extra = i *% 16 + 0,
                });
            } else {
                const icon_color = if (!show_close_visible)
                    dvui.Color.transparent
                else if (tab_hovered or close_hovered)
                    dvui.Color.white
                else
                    dvui.themeGet().color(.window, .text);
                core.icon.icon(@src(), "close", icons.tvg.lucide.x, .{
                    .stroke_color = .{ .color = icon_color },
                    .fill_color = .{ .color = icon_color },
                }, .{
                    .expand = .none,
                    .min_size_content = .{ .w = close_inner, .h = close_inner },
                    .gravity_x = 0.5,
                    .gravity_y = 0.5,
                    .id_extra = i *% 16 + 2,
                    .background = false,
                    .border = dvui.Rect.all(0),
                    .box_shadow = null,
                    .ninepatch_fill = &dvui.Ninepatch.none,
                    .ninepatch_hover = &dvui.Ninepatch.none,
                    .ninepatch_press = &dvui.Ninepatch.none,
                });
            }

            if (tab_close_button.clicked()) {
                runtime.host().closeDocById(doc.id) catch |err| {
                    dvui.log.err("closeFile: {d} failed: {s}", .{ i, @errorName(err) });
                };
                break;
            }
        }

        if (is_selected and !reorderable.floating()) {
            core.draw.drawTabActiveIndicator(
                reorderable.data().borderRectScale(),
                dvui.themeGet().color(.window, .text),
            );
        }

        loop: for (dvui.events()) |*e| {
            if (!hbox.matchEvent(e)) continue;
            switch (e.evt) {
                .mouse => |me| {
                    if (me.action == .press and me.button.pointer()) {
                        region.select(surface.id);
                        runtime.workbench().open_workspace_grouping = self.grouping;
                        dvui.refresh(null, @src(), hbox.data().id);

                        e.handle(@src(), hbox.data());
                        dvui.captureMouse(hbox.data(), e.num);
                        dvui.dragPreStart(me.button, me.p, .{ .size = reorderable.data().rectScale().r.size(), .offset = reorderable.data().rectScale().r.topLeft().diff(me.p) });
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
    if (reorder.finalSlot()) {
        self.tabs_insert_before_index = tabs.len;
    }
}

/// A tab landed: within this pane (reorder) or from another (move). Either way the change is an
/// assignment edit, and both panes' lists are written whole — this frame's `tabs` is the order
/// the user saw when they let go.
fn processTabsDrag(self: *Workspace, region: sdk.Host.Region, tabs: []const *sdk.Surface) void {
    _ = region;
    const insert_before = self.tabs_insert_before_index orelse return;
    defer self.tabs_insert_before_index = null;
    defer self.tabs_removed_index = null;

    const arena = runtime.host().arena();
    var ids = std.ArrayListUnmanaged([]const u8).initCapacity(arena, tabs.len + 1) catch return;
    for (tabs) |t| ids.appendAssumeCapacity(t.id);

    if (self.tabs_removed_index) |removed| {
        if (removed >= ids.items.len) return;
        const id = ids.orderedRemove(removed);
        const at = if (removed < insert_before) insert_before - 1 else insert_before;
        ids.insert(arena, @min(at, ids.items.len), id) catch return;
        self.setTabs(ids.items, id);
        return;
    }

    // From another pane: whichever one lifted the surface this frame.
    const id = runtime.workbench().dragging_surface orelse return;
    runtime.workbench().dragging_surface = null;
    for (runtime.workbench().workspaces.values()) |*other| {
        if (other.grouping == self.grouping) continue;
        other.removeTab(id);
        other.tabs_removed_index = null;
    }
    ids.insert(arena, @min(insert_before, ids.items.len), id) catch return;
    self.setTabs(ids.items, id);
}

/// Write this pane's tab list and make `focus` its active tab.
pub fn setTabs(self: *Workspace, ids: []const []const u8, focus: ?[]const u8) void {
    var buf: [32]u8 = undefined;
    const region_name = name(&buf, self.grouping);
    runtime.host().assignSurfaces(region_name, ids) catch |err| {
        dvui.log.err("pane {d}: {s}", .{ self.grouping, @errorName(err) });
        return;
    };
    if (focus) |id| {
        runtime.host().selectInRegion(region_name, id);
        runtime.workbench().open_workspace_grouping = self.grouping;
    }
}

/// Append a surface to this pane's tabs (no-op if already there).
pub fn addTab(self: *Workspace, id: []const u8, focus: bool) void {
    self.expecting = false;
    var buf: [32]u8 = undefined;
    const arena = runtime.host().arena();
    var ids: std.ArrayListUnmanaged([]const u8) = .empty;
    if (runtime.host().assignedSurfaces(name(&buf, self.grouping))) |existing| {
        for (existing) |e| {
            if (std.mem.eql(u8, e, id)) {
                if (focus) self.setTabs(existing, id);
                return;
            }
            ids.append(arena, e) catch return;
        }
    }
    ids.append(arena, id) catch return;
    self.setTabs(ids.items, if (focus) id else null);
}

/// Drop a surface from this pane's tabs, if it is one of them.
pub fn removeTab(self: *Workspace, id: []const u8) void {
    var buf: [32]u8 = undefined;
    const existing = runtime.host().assignedSurfaces(name(&buf, self.grouping)) orelse return;
    const arena = runtime.host().arena();
    var ids: std.ArrayListUnmanaged([]const u8) = .empty;
    var found = false;
    for (existing) |e| {
        if (std.mem.eql(u8, e, id)) {
            found = true;
            continue;
        }
        ids.append(arena, e) catch return;
    }
    if (found) self.setTabs(ids.items, null);
}

/// Drop every tab whose surface id names `path`, whatever plugin's id it carries. True if any did.
pub fn removeTabsForPath(self: *Workspace, path: []const u8) bool {
    var buf: [32]u8 = undefined;
    const existing = runtime.host().assignedSurfaces(name(&buf, self.grouping)) orelse return false;
    const arena = runtime.host().arena();
    var ids: std.ArrayListUnmanaged([]const u8) = .empty;
    var found = false;
    for (existing) |e| {
        if (sdk.document.pathOfSurfaceId(e)) |p| if (std.mem.eql(u8, p, path)) {
            found = true;
            continue;
        };
        ids.append(arena, e) catch return false;
    }
    if (found) self.setTabs(ids.items, null);
    return found;
}

/// Whether `id` is one of this pane's tabs, by assignment.
pub fn hasTab(self: *Workspace, id: []const u8) bool {
    var buf: [32]u8 = undefined;
    const existing = runtime.host().assignedSurfaces(name(&buf, self.grouping)) orelse return false;
    for (existing) |e| if (std.mem.eql(u8, e, id)) return true;
    return false;
}

/// How many tabs this pane has by assignment, open or not.
pub fn tabCount(self: *Workspace) usize {
    var buf: [32]u8 = undefined;
    const existing = runtime.host().assignedSurfaces(name(&buf, self.grouping)) orelse return 0;
    return existing.len;
}

/// Where a lifted tab or a file-tree row can be dropped: the middle of this pane joins it; an
/// edge opens a new pane on that side of it — the same reading the app's places use for a
/// dragged view (`DockLayout.zoneAt`: edges split, the middle lands here).
pub fn processTabDrag(self: *Workspace, data: *dvui.WidgetData) void {
    if (!dvui.dragName("tab_drag")) {
        runtime.workbench().clearFileTreeTabDragDropState();
        return;
    }
    const wb = runtime.workbench();
    const from_tab: ?[]const u8 = wb.dragging_surface;
    const from_tree: ?[]const u8 = wb.tab_drag_from_tree_path;
    if (from_tab == null and from_tree == null) return;

    const Zones = core.widgets.DockLayout;
    const bounds = data.rectScale().r;
    const band = 36.0 * data.rectScale().s;

    for (dvui.events()) |*e| {
        if (!dvui.eventMatch(e, .{ .id = data.id, .r = bounds, .drag_name = "tab_drag" })) continue;
        if (e.evt != .mouse) continue;
        const hit = Zones.zoneAt(bounds, e.evt.mouse.p, band) orelse continue;

        if (e.evt.mouse.action == .position) {
            hit.rect.fill(dvui.CornerRect.Physical.round(@min(hit.rect.w, hit.rect.h) / 8), .{
                .color = .{ .color = dvui.themeGet().color(.highlight, .fill).opacity(0.5) },
            });
        }
        if (e.evt.mouse.action != .release or !e.evt.mouse.button.pointer()) continue;

        e.handle(@src(), data);
        dvui.dragEnd();
        dvui.refresh(null, @src(), data.id);
        wb.dragging_surface = null;
        defer wb.clearFileTreeTabDragDropState();

        const grouping = switch (hit.zone) {
            .tab => self.grouping,
            .split => |side| blk: {
                const g = wb.newGroupingID();
                wb.paneBeside(g, self.grouping, side) catch continue;
                break :blk g;
            },
        };
        if (from_tab) |id| {
            for (wb.workspaces.values()) |*other| other.removeTab(id);
            const pane = wb.pane(grouping) catch continue;
            pane.addTab(id, true);
        } else if (from_tree) |path| {
            // Already open: it moves. Not yet: it loads into that pane and `rebuildWorkspaces`
            // seats it when the load lands.
            if (runtime.host().docFromPath(path)) |doc| {
                const id = sdk.document.surfaceId(runtime.host().arena(), doc.owner.id, doc.owner.documentPath(doc)) catch continue;
                for (wb.workspaces.values()) |*other| other.removeTab(id);
                const pane = wb.pane(grouping) catch continue;
                pane.addTab(id, true);
            } else {
                _ = runtime.host().openFilePath(path, grouping) catch {};
            }
        }
    }
}

fn drawCanvas(self: *Workspace, region: sdk.Host.Region, has_tabs: bool) !void {
    var content_color = dvui.themeGet().color(.window, .fill);
    switch (builtin.os.tag) {
        .macos, .windows => {
            content_color = if (!runtime.host().isMaximized()) content_color.opacity(runtime.host().contentOpacity()) else content_color;
        },
        else => {},
    }

    // The document draws its own canvas box (the app's surface does); this one is the pane's
    // frame around it, and the drop target for tabs.
    var frame = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .id_extra = @intCast(self.grouping),
    });
    defer {
        self.canvas_rect_physical = frame.data().contentRectScale().r;
        frame.deinit();
    }
    defer self.processTabDrag(frame.data());

    if (has_tabs) {
        _ = try region.drawContents();
    } else {
        var box = sdk.pane_layout.emptyStateCard(content_color, self.grouping);
        defer box.deinit();

        const alpha = dvui.alpha(1.0);
        dvui.alphaSet(1.0);
        defer dvui.alphaSet(alpha);

        try self.drawHomePage();
    }
}

pub fn drawHomePage(_: *Workspace) !void {
    const logo_pixel_size = 32;
    const logo_width = 3;

    var page_scroll = dvui.scrollArea(@src(), .{ .vertical = .auto, .horizontal = .none }, .{
        .expand = .both,
        .background = false,
        .color_fill = .transparent,
    });
    defer page_scroll.deinit();

    var content_vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .none,
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .background = false,
    });
    defer content_vbox.deinit();

    { // Logo

        {
            const vbox2 = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .none,
                .gravity_x = 0.5,
                .margin = .{ .y = 20 },
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
                        fizzy_color = fizzy_color.lerp(math.Color.initBytes(theme_bg.r, theme_bg.g, theme_bg.b, 255), fizzy_color.value[3]);
                        fizzy_color.value[3] = 1.0;
                    }

                    const color = fizzy_color.bytes();

                    const pixel = dvui.box(@src(), .{ .dir = .horizontal }, .{
                        .expand = .none,
                        .min_size_content = .{ .w = logo_pixel_size, .h = logo_pixel_size },
                        .id_extra = index,
                        .background = false,
                        .color_fill = .{ .color = .{ .r = color[0], .g = color[1], .b = color[2], .a = color[3] } },
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

        {
            var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .none,
                .gravity_x = 0.5,
                .margin = .{ .y = 80 },
            });

            defer vbox.deinit();

            // Dispatches through the same generic `Host.requestNewDocument` the menu item and the
            // `new_file` hotkey use, so it stays plugin-neutral (single editor plugin: straight to its
            // dialog/direct-create; 2+: the chooser picker) — see `Host.requestNewDocument`.
            {
                var button: dvui.ButtonWidget = undefined;
                button.init(@src(), .{ .draw_focus = true }, .{
                    .gravity_x = 0.5,
                    .expand = .horizontal,
                    .padding = dvui.Rect.all(2),
                    .color_fill = .{ .color = core.widgets.hoverRestFill(dvui.themeGet().color(.window, .fill_hover)) },
                    .color_fill_hover = .{ .color = dvui.themeGet().color(.window, .fill_hover) },
                    .color_fill_press = .{ .color = dvui.themeGet().color(.window, .fill_press) },
                });
                defer button.deinit();

                button.processEvents();
                button.drawBackground();

                core.draw.labelWithKeybind(
                    "New File",
                    dvui.currentWindow().keybinds.get("new_file") orelse .{},
                    true,
                    .{ .padding = dvui.Rect.all(4) },
                    .{ .padding = dvui.Rect.all(4), .expand = .horizontal },
                );

                if (button.clicked()) {
                    runtime.host().requestNewDocument(null, 0);
                }
            }

            {
                var button: dvui.ButtonWidget = undefined;
                button.init(@src(), .{ .draw_focus = true }, .{
                    .gravity_x = 0.5,
                    .expand = .horizontal,
                    .padding = dvui.Rect.all(2),
                    .color_fill = .{ .color = core.widgets.hoverRestFill(dvui.themeGet().color(.window, .fill_hover)) },
                    .color_fill_hover = .{ .color = dvui.themeGet().color(.window, .fill_hover) },
                    .color_fill_press = .{ .color = dvui.themeGet().color(.window, .fill_press) },
                });
                defer button.deinit();

                button.processEvents();
                button.drawBackground();

                core.draw.labelWithKeybind(
                    "Open Folder",
                    dvui.currentWindow().keybinds.get("open_folder") orelse .{},
                    true,
                    .{ .padding = dvui.Rect.all(4) },
                    .{ .padding = dvui.Rect.all(4), .expand = .horizontal },
                );

                if (button.clicked()) {
                    runtime.host().showOpenFolderDialog(setProjectFolderCallback, null);
                }
            }

            // Plugins' own ways to open a folder — a cloud drive's picker — right after fizzy's,
            // the same slot the File menu gives them. Only those enabled now (signed in).
            for (runtime.host().open_actions.items, 0..) |action, ai| {
                if (!runtime.host().openActionShown(action)) continue;
                var button: dvui.ButtonWidget = undefined;
                button.init(@src(), .{ .draw_focus = true }, .{
                    .id_extra = ai,
                    .gravity_x = 0.5,
                    .expand = .horizontal,
                    .padding = dvui.Rect.all(2),
                    .color_fill = .{ .color = core.widgets.hoverRestFill(dvui.themeGet().color(.window, .fill_hover)) },
                    .color_fill_hover = .{ .color = dvui.themeGet().color(.window, .fill_hover) },
                    .color_fill_press = .{ .color = dvui.themeGet().color(.window, .fill_press) },
                });
                defer button.deinit();
                button.processEvents();
                button.drawBackground();
                core.draw.labelWithKeybind(
                    action.title,
                    .{},
                    true,
                    .{ .padding = dvui.Rect.all(4) },
                    .{ .padding = dvui.Rect.all(4), .expand = .horizontal },
                );
                if (button.clicked()) {
                    runtime.host().runCommand(action.command) catch |err| dvui.log.warn("workbench: {s}: {t}", .{ action.id, err });
                }
            }

            {
                var button: dvui.ButtonWidget = undefined;
                button.init(@src(), .{ .draw_focus = true }, .{
                    .gravity_x = 0.5,
                    .expand = .horizontal,
                    .padding = dvui.Rect.all(2),
                    .color_fill = .{ .color = core.widgets.hoverRestFill(dvui.themeGet().color(.window, .fill_hover)) },
                    .color_fill_hover = .{ .color = dvui.themeGet().color(.window, .fill_hover) },
                    .color_fill_press = .{ .color = dvui.themeGet().color(.window, .fill_press) },
                });
                defer button.deinit();

                button.processEvents();
                button.drawBackground();

                core.draw.labelWithKeybind(
                    "Open Files",
                    dvui.currentWindow().keybinds.get("open_files") orelse .{},
                    true,
                    .{ .padding = dvui.Rect.all(4) },
                    .{ .padding = dvui.Rect.all(4), .expand = .horizontal, .font = dvui.Font.theme(.heading) },
                );

                if (button.clicked()) {
                    runtime.host().showOpenFileDialog(openFilesCallback, &.{}, "", null);
                }
            }
        }

        // Recent folders are the File menu's (File › Open Recent): the home page keeps to the
        // three verbs, which stays true whatever the folder is backed by.
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

    path.addRect(base_phys, dvui.CornerRect.Physical.square);

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

    path.build().fillConvex(.{ .color = .{ .color = .{ .r = color[0], .g = color[1], .b = color[2], .a = color[3] } }, .fade = 1.0 });
}

// This should never be able to return more than one folder
pub fn setProjectFolderCallback(folder: ?[][:0]const u8) void {
    if (folder) |f| {
        runtime.host().setProjectFolder(f[0]) catch {
            dvui.log.err("Failed to set project folder: {s}", .{f[0]});
        };
    }
}

pub fn openFilesCallback(files: ?[][:0]const u8) void {
    if (files) |f| {
        for (f) |file| {
            _ = runtime.host().openFilePath(file, runtime.workbench().open_workspace_grouping) catch {
                dvui.log.err("Failed to open file: {s}", .{file});
            };
        }
    }
}
