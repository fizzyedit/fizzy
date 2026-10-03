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
/// `rebuildWorkspaces` must not close it before the load lands. Cleared by `addTab`, and by
/// `rebuildWorkspaces` once the pane holds any tab.
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
/// The whole pane, tab strip included, as last drawn — what the host snapshots when this
/// pane's last document closes.
pane_rect_physical: ?dvui.Rect.Physical = null,
/// The window the pane is drawn in (`dvui.subwindowCurrentId`): the app's own, or the float the
/// documents were floated into. What the pane's own drags ask whether anything lies over it
/// (`uncoveredAt`).
subwindow_id: dvui.Id = .zero,
/// The tab strip as last laid out — where a lifted tab can still be put back in a strip, before
/// it becomes a view drag (`drawTabs`).
strip_rect_physical: ?dvui.Rect.Physical = null,
/// Where each tab was this frame, with its index in the pane's tab list: where a tab carried
/// back over the strip goes in (`insertIndexAt`).
tab_slots: [max_tab_slots]TabSlot = undefined,
tab_slot_count: usize = 0,
/// Where in this pane's assignment a tab carried in the app's view drag would go in, while it is
/// over the strip — last frame's reading, the gap this frame opens for it (`offerStrip`).
strip_insert: ?usize = null,
/// One of this pane's tabs was carried along the strips last frame, floating off its slot
/// (`drawTabs`): the drag is this strip's own.
lifting: bool = false,
/// The gap drawn this frame: where it starts along the strip and how wide it is, physical.
/// `insertIndexAt` reads the tabs as if it were not there, so the gap does not chase itself.
gap_x: f32 = 0,
gap_w: f32 = 0,
/// The pane as it looked just before its last document closed (the host's
/// `FrameTarget.snapshot`), drawn while the emptied pane slides shut so it reads as the file
/// closing rather than as a blank pane. Freed when the pane goes, or refills.
closing_snapshot: ?dvui.Texture = null,
/// Frames `closing_snapshot` has been held by a pane not (yet) sliding shut. The close that took
/// it reaches the tree on the next rebuild, so this is a frame or so at most; past that the pane
/// is staying, and a picture of a closed document must not stand in for it.
snapshot_idle_frames: u8 = 0,

const max_tab_slots = 64;
const TabSlot = struct { index: usize, rect: dvui.Rect.Physical };

pub fn init(grouping: u64) Workspace {
    return .{ .grouping = grouping };
}

/// Release any plugin-owned per-pane canvas chrome. Called when a pane is removed and for each
/// pane at shutdown.
pub fn deinit(self: *Workspace) void {
    self.dropSnapshot();
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
        // The app draws a dragged tab's drop zones and preview over this pane, as over any
        // place; the drop itself is ours, since only we make panes. The grouping, not a pointer
        // to this workspace: the map it lives in can grow between the draw and the drop.
        .on_drop = paneDrop,
        .drop_ctx = @ptrFromInt(@as(usize, @intCast(self.grouping + 1))),
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
    const pane_r = pane_box.rectScale().r;
    self.pane_rect_physical = pane_r;
    self.subwindow_id = dvui.subwindowCurrentId();

    if (tabs.len > 0) {
        self.dropSnapshot();
    } else if (self.closing_snapshot != null and !runtime.workbench().paneClosing(self.grouping)) {
        self.snapshot_idle_frames +|= 1;
        if (self.snapshot_idle_frames > 2) self.dropSnapshot();
    }
    if (tabs.len == 0) if (self.closing_snapshot) |snap| {
        // Sliding shut after its last document closed: the picture of it, from the pane's
        // top left, cut off by the pane as it narrows — the document leaving, not a blank.
        const prev_clip = dvui.clip(pane_r);
        defer dvui.clipSet(prev_clip);
        dvui.renderTexture(snap, .{ .r = .{ .x = pane_r.x, .y = pane_r.y, .w = @floatFromInt(snap.width), .h = @floatFromInt(snap.height) }, .s = 1 }, .{}) catch {};
        return .ok;
    };

    // Where this frame's tab strip is, for a file dropped on it; none when there are no tabs.
    self.strip_rect_physical = null;
    self.tab_slot_count = 0;
    if (tabs.len > 0) {
        self.drawTabs(region, tabs, selected);
        self.offerStrip(region, self.tabCount());
    } else if (!solePane()) {
        // An empty pane in a split looks like its neighbours with nothing open: the tab strip's
        // room, then the same card, empty — not a bare pane that starts higher than they do.
        const h = runtime.workbench().tab_strip_h;
        if (h > 0) _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = h }, .id_extra = @intCast(self.grouping) });
    }
    try self.drawCanvas(region, tabs.len > 0);
    return .ok;
}

fn drawTabs(self: *Workspace, region: sdk.Host.Region, tabs: []const *sdk.Surface, selected: ?*sdk.Surface) void {
    defer self.processTabsDrag(region, tabs);

    var tabs_anim = dvui.animate(@src(), .{ .duration = core.motion.duration(500_000), .kind = .vertical, .easing = core.motion.enter }, .{});
    defer tabs_anim.deinit();

    var tabs_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .none,
        .margin = dvui.Rect.all(0),
        .padding = dvui.Rect.all(0),
        .id_extra = @intCast(self.grouping),
        // Never shorter than a strip: with its only tab in the hand (`Host.viewDragSurface`) it
        // has nothing to draw, and the strip — somewhere to put it back — stays.
        .min_size_content = .{ .h = runtime.workbench().tab_strip_h },
    });
    // The strip's full width across the pane, not just its tabs: a tab put back anywhere along
    // it is still being reordered.
    if (self.pane_rect_physical) |pr| {
        const tr = tabs_box.data().borderRectScale().r;
        self.strip_rect_physical = .{ .x = pr.x, .y = tr.y, .w = pr.w, .h = tr.h };
    }
    defer {
        const id = tabs_box.data().id;
        tabs_box.deinit();
        // Read after `deinit`: a box totals its children only as it closes.
        if (dvui.minSizeGet(id)) |ms| if (ms.h > 0) {
            runtime.workbench().tab_strip_h = ms.h;
        };
    }

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

    // A strip a window lies over where the pointer is (`uncoveredAt`) — a float over the
    // documents — takes no part in a drag carried there: dvui's reorder opens its slot wherever
    // the pointer is, over a window or not, and parted the tabs under the float for a release
    // that is the float's. The strip a tab was lifted from keeps its part (`lifting`), for the
    // frame that hands the tab to the app's view drag (`overAnyStrip`): that drag grows out of
    // the tab where it floats, and only the reorder lays the tab out there. With no drag on, the
    // name stays: it is what a tab lifted here starts the drag under.
    const covered = dvui.dragName("tab_drag") and !self.uncoveredAt(dvui.currentWindow().mouse_pt) and !self.lifting;
    self.lifting = false;
    var reorder = dvui.reorder(@src(), .{ .drag_name = if (covered) null else "tab_drag" }, .{
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

    // A tab carried in the app's view drag is in the hand, not on any strip — as a tab being
    // reordered leaves its place — and over a strip, the strip opens a slot where it would go in.
    const carried = runtime.host().viewDragSurface();
    self.gap_w = 0;
    var gap_drawn = false;
    for (tabs, 0..) |surface, i| {
        // A tab has a document, or is the placeholder of one still loading (`Workbench.loading`),
        // which draws the same tab from what is known before the document exists: its path and
        // whether it is a preview.
        const doc_opt = documentOf(surface);
        const loading = if (doc_opt == null) runtime.workbench().loading.get(surface.id) else null;
        if (doc_opt == null and loading == null) continue;
        if (carried) |c| if (std.mem.eql(u8, c, surface.id)) continue;
        if (!gap_drawn) if (self.strip_insert) |at| if ((self.assignedIndexOf(surface.id) orelse i) >= at) {
            self.drawGap(i);
            gap_drawn = true;
        };

        // Keyed by the tab, not its index: dvui remembers each widget's size under its id, and
        // keyed by index, the frame after a reorder laid every tab out at the width of the one
        // that used to stand there — the tabs, and the active tab's line, snapped into place.
        const tab_key: usize = @truncate(std.hash.Wyhash.hash(0, surface.id));
        var reorderable = reorder.reorderable(@src(), .{ .draw_target = false }, .{
            .expand = .vertical,
            .id_extra = tab_key,
            .padding = dvui.Rect.all(0),
            .margin = dvui.Rect.all(0),
            .border = .all(0),
        });
        defer reorderable.deinit();
        // The slot a tab dragged along the strip would drop into: the carried look's drop slot,
        // seen blurred through the glass of the tab over it (`core.dialogs.dropSlot`).
        if (reorderable.targetRectScale()) |trs| core.dialogs.dropSlot(trs.r, trs.s);
        if (self.tab_slot_count < max_tab_slots) {
            // Its place in the assignment, which is what a drop rewrites — the list drawn here
            // leaves out entries that name nothing loadable, so its own index can be short.
            self.tab_slots[self.tab_slot_count] = .{ .index = self.assignedIndexOf(surface.id) orelse i, .rect = reorderable.data().borderRectScale().r };
            self.tab_slot_count += 1;
        }

        // Active-tab chrome belongs to the one pane that is active: four panes each dressing
        // their own tab as current is four claims to be where the next command lands.
        const is_selected = selected_index == i and pane_is_active;

        var hbox: dvui.BoxWidget = undefined;
        hbox.init(@src(), .{ .dir = .horizontal }, .{
            .expand = .none,
            .border = dvui.Rect.all(0),
            .color_fill = .{ .color = if (is_selected) .transparent else dvui.themeGet().color(.window, .fill).opacity(runtime.host().contentOpacity()) },
            .background = true,
            .id_extra = tab_key,
            .padding = .{ .x = 2, .y = 2, .w = 2, .h = 0 },
            .margin = dvui.Rect.all(0),
        });
        defer hbox.deinit();
        if (sdk.document.pathOfSurfaceId(surface.id)) |path| core.anchor.mark(hbox.data(), "workbench.tab:{s}", .{path});

        const tab_hovered = core.widgets.hovered(hbox.data());

        if (reorderable.floating()) {
            self.lifting = true;
            runtime.workbench().dragging_surface = surface.id;
            // Dragging a tab is arranging it, and a tab someone is placing is not on loan.
            if (doc_opt) |doc| runtime.host().setDocumentPreview(doc.id, false);
            // Carried, it is glass — the look it keeps if it leaves the strip for the places and
            // comes back (`core.dialogs.carriedGlass`) — with the slot it would drop into showing
            // through it.
            hbox.data().options.background = false;
            const frs = hbox.data().borderRectScale();
            core.dialogs.carriedGlass(hbox.data().id, frs.r, frs.s);
            // Off every strip: no longer a reorder, a document on its way somewhere. Hand it to
            // the app's view drag — the drop zones and live preview every place shows — and let
            // `paneDrop` land it. Only a document: a loading placeholder has nothing to carry.
            if (doc_opt != null and !overAnyStrip(dvui.currentWindow().mouse_pt)) {
                runtime.workbench().dragging_surface = null;
                dvui.dragEnd();
                runtime.workbench().carried_tab_w = frs.r.w;
                // From the tab as it is drawn — floating under the pointer, its glass just laid at
                // `frs` — not its slot: the view drag grows out of this rect, and from the slot
                // its glass jumped to the strip's corner before forming.
                runtime.host().beginViewDrag(surface.id, frs.r);
            }
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
        const tab_doc_path = if (doc_opt) |doc| doc.owner.documentPath(doc) else loading.?.path;
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

        // Italic says *preview*: this tab is on loan. The next single click replaces it, and
        // editing it — or double-clicking it, or Keep Open on its menu — makes it a tab like any
        // other. Borrowed from every editor that has the idea, because it is the one signal that
        // does not cost a control.
        var title_font = dvui.Font.theme(.body);
        const is_preview = if (doc_opt) |doc| runtime.host().documentIsPreview(doc.id) else loading.?.preview;
        if (is_preview) title_font.style = .italic;
        dvui.labelNoFmt(@src(), surface.title, .{}, .{
            .color_text = .{ .color = if (is_selected) dvui.themeGet().color(.window, .text) else dvui.themeGet().color(.control, .text) },
            .padding = dvui.Rect.all(4),
            .gravity_y = 0.5,
            .font = title_font,
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
        const save_flash_elapsed = if (doc_opt) |doc| doc.owner.timeSinceSaveCompleteNs(doc) else null;
        const save_in_check_phase = if (save_flash_elapsed) |elapsed|
            core.dialogs.bubbleSpinnerSaveInCheckPhase(elapsed)
        else
            false;
        const save_blocks_tab_close = if (doc_opt) |doc|
            doc.owner.isDocumentSaving(doc) or (doc.owner.showsSaveStatusIndicator(doc) and !save_in_check_phase)
        else
            false;

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

            const dirty = if (doc_opt) |doc| doc.owner.isDirty(doc) else false;
            const show_close_visible = tab_hovered or (is_selected and !dirty);
            const err_accent = dvui.themeGet().color(.err, .fill);
            const close_hovered = tab_close_button.hovered();

            // The dialog's close button (`core.dialogs.windowHeaderCloseButtonOptions`), but
            // only while the tab is hovered: a red circle on its drop shadow with the X in a
            // deeper red. At rest a tab shows just the X — a row of red circles along the strip
            // would shout over the titles.
            const lit = show_close_visible and (tab_hovered or close_hovered);
            if (lit) {
                const rs = tab_close_button.data().borderRectScale();
                const circle: dvui.CornerRect.Physical = .round(@min(rs.r.w, rs.r.h) / 2);
                if (core.dialogs.windowHeaderCloseButtonOptions(.{}).box_shadow) |bs| {
                    rs.r.insetAll(bs.shrink * rs.s).offsetPoint(bs.offset.scale(rs.s, dvui.Point.Physical))
                        .fill(circle, .{ .color = .{ .color = bs.color.opacity(bs.alpha) }, .fade = bs.fade * rs.s });
                }
                const fill = if (close_hovered) dvui.themeGet().color(.err, .fill_hover) else err_accent;
                rs.r.fill(circle, .{ .color = .{ .color = fill }, .fade = 1 });
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
                else if (lit)
                    err_accent.lighten(if (dvui.themeGet().dark) -10 else 10)
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
                if (doc_opt) |doc| {
                    runtime.host().closeDocById(doc.id) catch |err| {
                        dvui.log.err("closeFile: {d} failed: {s}", .{ i, @errorName(err) });
                    };
                } else {
                    // Closing a load: the app sees its placeholder gone and cancels it.
                    self.removeTab(surface.id);
                }
                break;
            }
        }

        if (is_selected and !reorderable.floating()) {
            core.draw.drawTabActiveIndicator(
                reorderable.data().borderRectScale(),
                dvui.themeGet().color(.window, .text),
            );
        }

        // The tab's own menu. Right-click only, so it never competes with the press above,
        // which is the left button's (select, then drag).
        if (doc_opt) |doc| {
            if (drawTabMenu(tabs, i, doc, self.grouping, hbox.data().borderRectScale().r)) break;
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
                        // The hand from the press on: the app's view drag, which this becomes off the
                        // strip, asks for the same (`ViewDrag.cursor`), so it does not change there.
                        dvui.dragPreStart(me.button, me.p, .{ .size = reorderable.data().rectScale().r.size(), .offset = reorderable.data().rectScale().r.topLeft().diff(me.p), .cursor = .hand });
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
    // Past the last tab.
    if (!gap_drawn and self.strip_insert != null) self.drawGap(tabs.len);
    // The slot past the last tab, drawn as every other slot is. Not `reorder.finalSlot()`: that
    // one paints dvui's own square target, a different slot at the end of the strip from the
    // rounded one between tabs.
    if (reorder.needFinalSlot()) {
        var last = reorder.reorderable(@src(), .{ .last_slot = true, .draw_target = false }, .{});
        defer last.deinit();
        if (last.targetRectScale()) |trs| core.dialogs.dropSlot(trs.r, trs.s);
        if (last.insertBefore()) self.tabs_insert_before_index = tabs.len;
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

/// Where `id` is in this pane's assignment.
fn assignedIndexOf(self: *const Workspace, id: []const u8) ?usize {
    var buf: [32]u8 = undefined;
    const existing = runtime.host().assignedSurfaces(name(&buf, self.grouping)) orelse return null;
    for (existing, 0..) |e, k| if (std.mem.eql(u8, e, id)) return k;
    return null;
}

/// How many tabs this pane has by assignment, open or not.
pub fn tabCount(self: *Workspace) usize {
    var buf: [32]u8 = undefined;
    const existing = runtime.host().assignedSurfaces(name(&buf, self.grouping)) orelse return 0;
    return existing.len;
}

/// How many of this pane's tabs can draw: a document that is open, or one loading behind its
/// placeholder. The rest name documents that never came back — a restore that ran before the
/// mount holding them was up — and a pane holding only those shows nothing at all.
pub fn liveTabCount(self: *Workspace) usize {
    var buf: [32]u8 = undefined;
    const host = runtime.host();
    const existing = host.assignedSurfaces(name(&buf, self.grouping)) orelse return 0;
    var n: usize = 0;
    for (existing) |id| {
        if (host.surfaceById(id) != null) n += 1;
    }
    return n;
}

/// The strip is this pane's chooser (`Host.Region.offerChooser`): a tab carried in the app's view
/// drag back over it goes into the tabs rather than onto a drop zone — the zones and the preview
/// are for the pane's inside — and while it is over, a bar shows where it would go in.
fn offerStrip(self: *Workspace, region: sdk.Host.Region, tab_count: usize) void {
    self.strip_insert = null;
    const strip = self.strip_rect_physical orelse return;
    if (!region.offerChooser(strip)) return;
    // Read next frame, where the strip opens its slot (`drawGap`).
    self.strip_insert = self.insertIndexAt(dvui.currentWindow().mouse_pt.x, tab_count);
}

/// The slot a tab carried back over the strip would go into, before tab `id_extra`'s place: as
/// wide as the tab was, a drop slot in it (`core.dialogs.dropSlot`).
fn drawGap(self: *Workspace, id_extra: usize) void {
    const s = dvui.currentWindow().natural_scale;
    const w = if (runtime.workbench().carried_tab_w > 0) runtime.workbench().carried_tab_w else 120 * s;
    var gap = dvui.box(@src(), .{}, .{
        .id_extra = id_extra,
        .expand = .vertical,
        .min_size_content = .{ .w = w / s, .h = 1 },
        .margin = .{},
        .padding = .{},
    });
    const rs = gap.data().borderRectScale();
    self.gap_x = rs.r.x;
    self.gap_w = rs.r.w;
    core.dialogs.dropSlot(rs.r, rs.s);
    gap.deinit();
}

/// The index in this pane's assignment a tab let go at `x` goes in before: the first tab whose
/// middle is past it, else the end.
pub fn insertIndexAt(self: *const Workspace, x: f32, tab_count: usize) usize {
    for (self.tab_slots[0..self.tab_slot_count]) |slot| {
        // Read as if the open slot were not there: tabs past it sit a gap further along.
        const x0 = if (self.gap_w > 0 and slot.rect.x >= self.gap_x) slot.rect.x - self.gap_w else slot.rect.x;
        if (x < x0 + slot.rect.w / 2) return slot.index;
    }
    return tab_count;
}

/// Put `id` in this pane's tabs before `index` — moved there if it is already one of them — and
/// show it.
pub fn insertTab(self: *Workspace, id: []const u8, index: usize) void {
    self.expecting = false;
    var buf: [32]u8 = undefined;
    const arena = runtime.host().arena();
    var ids: std.ArrayListUnmanaged([]const u8) = .empty;
    var at = index;
    if (runtime.host().assignedSurfaces(name(&buf, self.grouping))) |existing| {
        for (existing, 0..) |e, k| {
            if (std.mem.eql(u8, e, id)) {
                if (k < index) at -|= 1;
                continue;
            }
            ids.append(arena, e) catch return;
        }
    }
    ids.insert(arena, @min(at, ids.items.len), id) catch return;
    self.setTabs(ids.items, id);
}

/// Whether `p` is over some pane's tab strip, or near enough to it — within half a strip's
/// height — that a lifted tab there is still being put back in a strip. Not a strip a window
/// lies over there (`uncoveredAt`): over a float the tab is off every strip, and goes to the
/// app's view drag, which knows what each float covers.
fn overAnyStrip(p: dvui.Point.Physical) bool {
    for (runtime.workbench().workspaces.values()) |*ws| {
        const r = ws.strip_rect_physical orelse continue;
        const reach = r.h * 0.5;
        if (p.x < r.x or p.x > r.x + r.w or p.y < r.y - reach or p.y > r.y + r.h + reach) continue;
        if (ws.uncoveredAt(p)) return true;
    }
    return false;
}

/// Whether nothing lies over this pane at `p`: no window above the one it is drawn in — a float
/// over the documents, a dialog — takes the pointer there. It is the reading dvui tags a pointer
/// event with (`Subwindows.windowFor`), so what the pane shows for its own drag — a slot opening
/// in its strip for a tab carried along the strips — agrees with where a release goes, and under
/// a float it shows nothing: a release there is the float's.
///
/// A window that takes no pointer events covers nothing, here as for dvui: the app's drag
/// overlay, which draws the drops and the carried view over every window, and what a drag
/// carries — a tab floating off its strip. A float stepping aside for a view carried out of it is
/// still a window, and covers. It steps aside only for the app's view drag, which reads the floats
/// itself and sees past it (`Host.Region.offerChooser`, `RegionSpec.on_drop`), and a tab along
/// the strips meets one only in the moment it takes to come back or go, when dvui hands it the
/// release too.
pub fn uncoveredAt(self: *const Workspace, p: dvui.Point.Physical) bool {
    return dvui.currentWindow().subwindows.windowFor(p) == self.subwindow_id;
}

/// A document dropped on this pane through the app's view drag (`RegionSpec.on_drop`): the
/// middle takes it as a tab, an edge opens a pane on that side with it. Taking it here takes it
/// out of the pane it was in — an assignment lives in one place. A file carried out of the tree
/// that is not open yet comes by the id its document will have, with no surface behind it, and
/// opens here (`openHere`).
pub fn paneDrop(ctx: ?*anyopaque, drop: sdk.RegionSpec.Drop) bool {
    const grouping: u64 = @as(u64, @intFromPtr(ctx orelse return false)) - 1;
    const wb = runtime.workbench();
    const target = switch (drop.zone) {
        .center => grouping,
        .edge => |side| blk: {
            const g = wb.newGroupingID();
            wb.paneBeside(g, grouping, paneSide(side)) catch return false;
            break :blk g;
        },
    };
    if (runtime.host().surfaceById(drop.surface_id) == null) {
        const path = sdk.document.pathOfSurfaceId(drop.surface_id) orelse return false;
        const pane = wb.pane(target) catch return false;
        return pane.openHere(drop.surface_id, path, if (drop.on_chooser) pane.insertIndexAt(drop.point.x, pane.tabCount()) else null);
    }
    for (wb.workspaces.values()) |*other| {
        if (other.grouping != target) other.removeTab(drop.surface_id);
    }
    const pane = wb.pane(target) catch return false;
    // Over the strip: where along it — between the tabs it was let go between, and back on its
    // own strip that is a reorder.
    if (drop.on_chooser) {
        pane.insertTab(drop.surface_id, pane.insertIndexAt(drop.point.x, pane.tabCount()));
    } else {
        pane.addTab(drop.surface_id, true);
    }
    return true;
}

/// Open the file at `path`, which is not open yet, as a tab of this pane — before tab `at`, or at
/// the end as any open goes in — and show it. Between two tabs the slot is held by the id its
/// document will have (`id`): the load's placeholder takes that slot, and the document takes it
/// from the placeholder (`Openings.begin`, `land`), as with the slot a restored session kept for
/// a document. False when no load started — it is loading already, or nothing can open it — and
/// then the slot goes again, and a pane an edge opened for it has nothing to wait for.
fn openHere(self: *Workspace, id: []const u8, path: []const u8, at: ?usize) bool {
    if (at) |i| self.insertTab(id, i);
    const started = runtime.host().openFile(.{ .path = path, .grouping = self.grouping }) catch false;
    if (!started) {
        if (at != null) self.removeTab(id);
        self.expecting = false;
    }
    return started;
}

fn paneSide(side: sdk.RegionSpec.Drop.Side) core.widgets.DockLayout.Side {
    return switch (side) {
        .left => .left,
        .right => .right,
        .top => .top,
        .bottom => .bottom,
    };
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
    // frame around it.
    var frame = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .id_extra = @intCast(self.grouping),
    });
    defer {
        self.canvas_rect_physical = frame.data().contentRectScale().r;
        frame.deinit();
    }

    if (has_tabs) {
        _ = try region.drawContents();
    } else {
        var box = sdk.pane_layout.emptyStateCard(content_color, self.grouping);
        defer box.deinit();

        // The home page belongs to the editor as a whole, so only the one pane there is shows
        // it. An empty pane beside others — above all one sliding shut after its last tab
        // closed — is just an empty document pane: the logo and buttons flashing up in it as it
        // went read as a page opening, not a file closing.
        if (!solePane()) return;

        const alpha = dvui.alpha(1.0);
        dvui.alphaSet(1.0);
        defer dvui.alphaSet(alpha);

        try self.drawHomePage();
    }
}

fn dropSnapshot(self: *Workspace) void {
    if (self.closing_snapshot) |t| dvui.textureDestroyLater(t);
    self.closing_snapshot = null;
    self.snapshot_idle_frames = 0;
}

/// Whether this is the workbench's only pane — the one that shows the home page when empty.
fn solePane() bool {
    const wb = runtime.workbench();
    return wb.panes.nodes.items[wb.panes.root] == .leaf;
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
    defer core.widgets.scrollShadows(page_scroll);

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

            // Not on the web: a page cannot read a directory tree (see `Keybinds`).
            if (comptime builtin.target.cpu.arch != .wasm32) {
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

    const fill: dvui.Color = .{ .r = color[0], .g = color[1], .b = color[2], .a = color[3] };

    // The block, always square: the bubble pushes up out of its top rather than rounding it.
    {
        var path = dvui.Path.Builder.init(dvui.currentWindow().lifo());
        defer path.deinit();
        path.addRect(base_phys, dvui.CornerRect.Physical.square);
        path.build().fillConvex(.{ .color = .{ .color = fill }, .fade = 1.0 });
    }
    if (bubble_phys.h <= 0) return;

    // The bubble: the part of a pill (round top, radius half the width, rising `bubble_h`)
    // above the block's top — a low arc out of the middle of a flat top that widens into the
    // full round as it rises, the square pixel pushed up into a bubble. Its own convex shape,
    // one outline through the peak once (two quarter-arcs meeting there made a notch), its
    // flat foot a pixel inside the block so the two meet without a seam. The block and bubble
    // together are not convex, so they are two fills rather than one outline.
    const rad = bubble_phys.w / 2.0;
    const center = dvui.Point.Physical{ .x = bubble_phys.x + rad, .y = bubble_phys.y + rad };
    const foot = base_phys.y + 1;
    const dy = center.y - foot;
    if (dy >= rad) return;
    var path = dvui.Path.Builder.init(dvui.currentWindow().lifo());
    defer path.deinit();
    if (dy <= 0) {
        // Risen past its full round: the arc, then straight sides down to the foot.
        path.addArc(center, rad, dvui.math.pi * 1.5, dvui.math.pi, false);
        path.addPoint(.{ .x = bubble_phys.x, .y = foot });
        path.addPoint(.{ .x = bubble_phys.x + bubble_phys.w, .y = foot });
        path.addArc(center, rad, dvui.math.pi * 2.0, dvui.math.pi * 1.5, true);
    } else {
        // Still rising: only the arc above the foot, ending where the circle crosses it.
        const a = std.math.asin(dy / rad);
        path.addArc(center, rad, dvui.math.pi * 1.5, dvui.math.pi + a, false);
        path.addArc(center, rad, dvui.math.pi * 2.0 - a, dvui.math.pi * 1.5, true);
    }
    path.build().fillConvex(.{ .color = .{ .color = fill }, .fade = 1.0 });
}

// This should never be able to return more than one folder
/// `fizzy.menu.tab`: Keep Open for a preview, the close family, then whatever plugins add to
/// that menu. True when it closed something, so the caller stops walking a tab list that just
/// changed underneath it — the close button breaks out of the loop for the same reason.
fn drawTabMenu(tabs: []const *const sdk.Surface, index: usize, doc: sdk.DocHandle, grouping: u64, tab_rect: dvui.Rect.Physical) bool {
    var ctx = core.widgets.context(@src(), .{ .rect = tab_rect }, .{ .id_extra = index });
    defer ctx.deinit();
    const point = ctx.activePoint() orelse return false;

    const host = runtime.host();
    var menu = core.widgets.contextMenu(@src(), point, .{});
    defer menu.deinit();

    const Close = enum { none, this, others, right, left };
    var close: Close = .none;

    // Only while it is one: a kept tab has nothing to keep.
    if (host.documentIsPreview(doc.id)) {
        if (core.widgets.menuRow(@src(), "Keep Open", .{ .icon = icons.tvg.lucide.@"pin" }) != null) {
            host.setDocumentPreview(doc.id, false);
            menu.close();
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal });
    }
    if (core.widgets.menuRow(@src(), "Close", .{ .icon = icons.tvg.lucide.@"x" }) != null) close = .this;
    if (tabs.len > 1) {
        if (core.widgets.menuRow(@src(), "Close Others", .{ .icon = icons.tvg.lucide.@"copy-x" }) != null) close = .others;
    }
    if (index + 1 < tabs.len) {
        if (core.widgets.menuRow(@src(), "Close to the Right", .{ .icon = icons.tvg.lucide.@"arrow-right-to-line" }) != null) close = .right;
    }
    if (index > 0) {
        if (core.widgets.menuRow(@src(), "Close to the Left", .{ .icon = icons.tvg.lucide.@"arrow-left-to-line" }) != null) close = .left;
    }

    // What plugins add. The subject is the document, with its path and pane, so a row that works
    // on files ("Copy Path", "Reveal in Explorer") needs nothing else.
    host.drawMenuSections(.{
        .menu_id = "fizzy.menu.tab",
        .subject = .{ .document = .{ .id = doc.id, .path = doc.owner.documentPath(doc), .grouping = grouping } },
    }, true);

    if (close == .none) return false;
    menu.close();

    // Collected before any close runs: closing edits the list these indices point into.
    var ids: std.ArrayListUnmanaged(u64) = .empty;
    const arena = host.arena();
    for (tabs, 0..) |surface, i| {
        const other = documentOf(surface) orelse continue;
        const wanted = switch (close) {
            .none => false,
            .this => i == index,
            .others => i != index,
            .right => i > index,
            .left => i < index,
        };
        if (wanted) ids.append(arena, other.id) catch return false;
    }
    for (ids.items) |id| {
        // Each one goes through the ordinary close, so a dirty document still asks about saving
        // rather than being dropped because it happened to sit to the right.
        host.closeDocById(id) catch |err| dvui.log.err("close tab {d}: {t}", .{ id, err });
    }
    return true;
}

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
            _ = runtime.host().openFile(.{ .path = file, .grouping = runtime.workbench().open_workspace_grouping }) catch {
                dvui.log.err("Failed to open file: {s}", .{file});
            };
        }
    }
}
