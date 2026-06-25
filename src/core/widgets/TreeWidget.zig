const std = @import("std");
const dvui = @import("dvui");

/// True when a primary-button release in `r` used shift/ctrl/cmd (selection modifiers).
fn pointerReleaseInRectHasSelectionModifier(r: dvui.Rect.Physical) bool {
    for (dvui.events()) |*e| {
        switch (e.evt) {
            .mouse => |me| {
                if (me.action == .release and me.button.pointer() and r.contains(me.p)) {
                    return me.mod.shift() or me.mod.control() or me.mod.command();
                }
            },
            else => {},
        }
    }
    return false;
}

const Options = dvui.Options;
const Rect = dvui.Rect;
const RectScale = dvui.RectScale;
const Size = dvui.Size;
const Widget = dvui.Widget;
const WidgetData = dvui.WidgetData;
const AccessKit = dvui.AccessKit;

const TreeWidget = @This();

wd: WidgetData = undefined,
layout: dvui.BasicLayout = .{},
/// Primary dragged row; matches `Branch.InitOptions.branch_id` (or branch widget id). For
/// multi-drag, row content is still drawn in a stacked floating preview; this id matches the row
/// that initiated the drag / receives drop-target semantics as before.
id_branch: ?usize = null,
/// When non-null, this is the full set of branch ids being dragged together (includes the primary).
/// Each id gets an in-tree placeholder slot and its row content is drawn in a stacked floating
/// preview. For a single-item drag this is null and only `id_branch` is used.
drag_branch_ids: ?[]usize = null,
drag_point: ?dvui.Point.Physical = null,
drag_ending: bool = false,
branch_size: Size = .{},
current_branch_focus_id: ?dvui.Id = null,
init_options: InitOptions = undefined,
group: dvui.FocusGroupWidget = undefined,
/// Drop indicator: last branch that contains the mouse wins
drop_target_branch_id: ?usize = null,
drop_target_rs: ?dvui.RectScale = null,
drop_target_drop_into: bool = false,
/// Row size (natural) captured at `dragStart`; used for placeholder + floating min size so the
/// drag source's button laid out in a floating subwindow cannot inflate `branch_size` unbounded.
drag_row_size: ?Size = null,
/// Optional consumer-provided selection: when a branch that is in this set starts a drag, the
/// tree upgrades to a multi-item drag with this exact set. Lifetime: must remain valid for the
/// duration of this frame (not stored across frames by the tree).
selected_branch_ids: ?[]const usize = null,

pub const InitOptions = struct {
    enable_reordering: bool = true,

    /// If not null, drags give up mouse capture and set this drag name
    drag_name: ?[]const u8 = null,
};

pub fn init(self: *TreeWidget, src: std.builtin.SourceLocation, init_opts: InitOptions, opts: Options) void {
    self.* = .{};
    const defaults = Options{ .name = "Tree", .role = .tree };
    self.init_options = init_opts;
    self.wd = WidgetData.init(src, .{}, defaults.override(opts));
    self.id_branch = dvui.dataGet(null, self.wd.id, "_id_branch", usize) orelse null;
    self.drag_point = dvui.dataGet(null, self.wd.id, "_drag_point", dvui.Point.Physical) orelse null;
    self.branch_size = dvui.dataGet(null, self.wd.id, "_branch_size", dvui.Size) orelse dvui.Size{};
    self.drag_row_size = dvui.dataGet(null, self.wd.id, "_drag_row_size", Size);
    self.drag_branch_ids = dvui.dataGetSlice(null, self.wd.id, "_drag_branch_ids", []usize);
    if (init_opts.drag_name) |dn| {
        if (self.drag_point != null and !dvui.dragName(dn)) {
            self.drag_ending = true;
        }
    }

    self.data().register();
    self.data().borderAndBackground(.{});

    dvui.parentSet(self.widget());

    self.group.init(@src(), .{ .nav_key_dir = .vertical }, .{});

    if (self.group.data().accesskit_node()) |ak_node| {
        AccessKit.nodeAddAction(ak_node, AccessKit.Action.focus);
        AccessKit.nodeAddAction(ak_node, AccessKit.Action.click);
    }
}

pub fn tree(src: std.builtin.SourceLocation, init_opts: InitOptions, opts: Options) *TreeWidget {
    var ret = dvui.widgetAlloc(TreeWidget);
    ret.init(src, init_opts, opts);
    ret.processEvents();
    return ret;
}

pub fn widget(self: *TreeWidget) Widget {
    return Widget.init(self, data, rectFor, screenRectScale, minSizeForChild);
}

pub fn data(self: *TreeWidget) *WidgetData {
    return self.wd.validate();
}

pub fn rectFor(self: *TreeWidget, id: dvui.Id, min_size: Size, e: Options.Expand, g: Options.Gravity) Rect {
    return self.layout.rectFor(self.data().contentRect().justSize(), id, min_size, e, g);
}

pub fn screenRectScale(self: *TreeWidget, rect: Rect) RectScale {
    return self.data().contentRectScale().rectToRectScale(rect);
}

pub fn minSizeForChild(self: *TreeWidget, s: Size) void {
    const ms = self.layout.minSizeForChild(s);
    self.data().minSizeMax(self.data().options.padSize(ms));
}

pub fn matchEvent(self: *TreeWidget, event: *dvui.Event) bool {
    if (dvui.captured(self.wd.id) or (self.init_options.drag_name != null and dvui.dragName(self.init_options.drag_name.?))) {
        // passively listen to mouse motion
        for (dvui.events()) |*e| {
            if (e.evt == .mouse and e.evt.mouse.action == .motion) {
                self.drag_point = e.evt.mouse.p;

                dvui.scrollDrag(.{
                    .mouse_pt = e.evt.mouse.p,
                    .screen_rect = self.wd.rectScale().r,
                });
            }
        }
    }

    if (self.init_options.drag_name) |dn| {
        if (dvui.dragName(dn)) {
            return dvui.eventMatch(event, .{ .id = self.data().id, .r = self.data().borderRectScale().r, .drag_name = dn });
        }
    }

    return dvui.eventMatchSimple(event, self.data());
}

pub fn processEvents(self: *TreeWidget) void {
    const evts = dvui.events();
    for (evts) |*e| {
        if (!self.matchEvent(e))
            continue;

        self.processEvent(e);
    }
}

pub fn processEvent(self: *TreeWidget, e: *dvui.Event) void {
    if (dvui.captured(self.data().id) or (self.init_options.drag_name != null and dvui.dragName(self.init_options.drag_name.?))) {
        switch (e.evt) {
            .mouse => |me| {
                if ((me.action == .press or me.action == .release) and me.button.pointer()) {
                    e.handle(@src(), self.data());
                    self.drag_ending = true;
                    dvui.captureMouse(null, e.num);
                    dvui.dragEnd();
                }
            },
            else => {},
        }
    }
}

pub fn deinit(self: *TreeWidget) void {
    defer if (dvui.widgetIsAllocated(self)) dvui.widgetFree(self);
    defer self.* = undefined;

    self.group.deinit();

    // Draw drop indicator once; last branch that contained the mouse set drop_target_rs
    if (self.drag_point != null) {
        if (self.drop_target_rs) |*rs| {
            if (self.drop_target_drop_into) {
                rs.r.stroke(.all(12), .{ .color = dvui.themeGet().focus, .thickness = 2.0 });
            } else {
                rs.r.h = 6.0;
                rs.r.fill(.all(3), .{ .color = dvui.themeGet().focus, .fade = 1.0 });
            }
        }
    }

    if (self.drag_ending) {
        self.id_branch = null;
        self.drag_point = null;
        self.drag_row_size = null;
        self.drag_branch_ids = null;
        dvui.refresh(null, @src(), self.data().id);
    }

    if (self.id_branch) |idr| {
        dvui.dataSet(null, self.data().id, "_id_branch", idr);
    } else {
        dvui.dataRemove(null, self.data().id, "_id_branch");
    }

    if (self.drag_point) |dp| {
        dvui.dataSet(null, self.data().id, "_drag_point", dp);
    } else {
        dvui.dataRemove(null, self.data().id, "_drag_point");
    }

    dvui.dataSet(null, self.data().id, "_branch_size", self.branch_size);

    if (self.drag_row_size) |drs| {
        dvui.dataSet(null, self.data().id, "_drag_row_size", drs);
    } else {
        dvui.dataRemove(null, self.data().id, "_drag_row_size");
    }

    // Do NOT re-`dataSetSlice` here: `init` populated `drag_branch_ids` from dvui's internal
    // storage, so re-writing the same slice would be an aliasing memcpy (@memcpy arguments alias).
    // `dragStart*` owns writes to this slot; here we only need to clear it when the drag ended.
    if (self.drag_branch_ids == null) {
        dvui.dataRemove(null, self.data().id, "_drag_branch_ids");
    }

    self.data().minSizeSetAndRefresh();
    self.data().minSizeReportToParent();
    dvui.parentReset(self.data().id, self.data().parent);
}

/// `row_size` is the dragged row's natural size (header). Pass `.{}` to use `branch_size` from layout.
pub fn dragStart(self: *TreeWidget, branch_id: usize, p: dvui.Point.Physical, row_size: Size) void {
    self.id_branch = branch_id;
    self.drag_point = p;
    self.drag_row_size = if (row_size.w > 0 and row_size.h > 0) row_size else self.branch_size;
    self.drag_branch_ids = null;
    dvui.dataRemove(null, self.wd.id, "_drag_branch_ids");
    dvui.captureMouse(self.data(), 0);
    if (self.init_options.drag_name) |dn| {
        // `dragStart` overwrites the whole `Dragging` options; keep `dragPreStart`'s offset so the
        // floating row stays anchored to the grab point (files tree uses a named "tab" drag here).
        dvui.dragStart(p, .{ .name = dn, .offset = dvui.dragOffset() });
        dvui.captureMouse(null, 0);
    }
}

/// Multi-row drag. `primary_branch_id` is the one rendered as the floating ghost; `branch_ids` is the
/// full set of rows being dragged together (must include `primary_branch_id`). Every row in the set
/// gets a reserved placeholder slot and its content is faded while the drag is active. The caller is
/// responsible for interpreting the drop target and moving all rows as a group.
pub fn dragStartMulti(
    self: *TreeWidget,
    primary_branch_id: usize,
    branch_ids: []const usize,
    p: dvui.Point.Physical,
    row_size: Size,
) void {
    self.id_branch = primary_branch_id;
    self.drag_point = p;
    self.drag_row_size = if (row_size.w > 0 and row_size.h > 0) row_size else self.branch_size;
    if (branch_ids.len > 1) {
        dvui.dataSetSlice(null, self.wd.id, "_drag_branch_ids", branch_ids);
        self.drag_branch_ids = dvui.dataGetSlice(null, self.wd.id, "_drag_branch_ids", []usize);
    } else {
        self.drag_branch_ids = null;
        dvui.dataRemove(null, self.wd.id, "_drag_branch_ids");
    }
    dvui.captureMouse(self.data(), 0);
    if (self.init_options.drag_name) |dn| {
        dvui.dragStart(p, .{ .name = dn, .offset = dvui.dragOffset() });
        dvui.captureMouse(null, 0);
    }
}

/// Returns true if `branch_id` is part of the active drag (either the primary, or a secondary row
/// in a multi-drag set).
pub fn isDragSource(self: *TreeWidget, branch_id: usize) bool {
    if (self.drag_branch_ids) |ids| {
        for (ids) |id| {
            if (id == branch_id) return true;
        }
        return false;
    }
    if (self.id_branch) |idb| return idb == branch_id;
    return false;
}

/// Index of `branch_id` in the multi-drag set (stack order in the floating preview). Single-item
/// drags always use 0. When `drag_branch_ids` is null, returns 0.
pub fn multiDragStackIndex(self: *TreeWidget, branch_id: usize) usize {
    if (self.drag_branch_ids) |ids| {
        for (ids, 0..) |id, i| {
            if (id == branch_id) return i;
        }
    }
    return 0;
}

/// True while a row reorder interaction is active: `dragStart` ran and/or this tree holds capture.
/// Callers that bypass `TreeWidget.processEvents` (e.g. layer list in `tools.zig`) must still drive
/// `matchEvent` on motion while this is true so `drag_point` / `scrollDrag` stay updated.
pub fn reorderDragActive(self: *TreeWidget) bool {
    return self.drag_point != null or dvui.captured(self.data().id);
}

pub fn branch(self: *TreeWidget, src: std.builtin.SourceLocation, init_opts: Branch.InitOptions, opts: Options) *Branch {
    const ret = dvui.widgetAlloc(Branch);
    ret.init(src, self, init_opts, opts);
    ret.install();
    if (ret.data().accesskit_node()) |ak_node| {
        AccessKit.nodeAddAction(ak_node, AccessKit.Action.focus);
        AccessKit.nodeAddAction(ak_node, AccessKit.Action.click);
        // Accessibility TODO: Support expand / collapse when available.
    }
    return ret;
}

pub const Branch = struct {
    pub const InitOptions = struct {
        // if true, the branch is currently expanded
        expanded: bool = false,

        // if null, uses widget id
        // if non-null, must be unique among branches in one tree while dragging
        branch_id: ?usize = null,

        /// When true, dragging over this row can show "drop into" (as child) instead of only "insert before"
        can_accept_children: bool = false,

        // If animation duration is greater than 0, the expander will animate accordingly
        animation_duration: i32 = 100_000,

        animation_easing: *const dvui.easing.EasingFn = dvui.easing.outQuad,

        process_events: bool = true,
    };

    wd: WidgetData = undefined,
    layout: dvui.BasicLayout = .{},
    button: dvui.ButtonWidget = undefined,
    hbox: dvui.BoxWidget = undefined,
    expander_vbox: dvui.BoxWidget = undefined,
    tree: *TreeWidget = undefined,
    init_options: Branch.InitOptions = undefined,
    options: Options = undefined,
    installed: bool = false,
    floating_widget: ?dvui.FloatingWidget = null,
    drag_alpha_restore: ?f32 = null,
    expanded: bool = false,
    can_expand: bool = false,
    anim: ?*dvui.AnimateWidget = null,
    /// Populated while `expander_vbox` is active: clip children to `anim`'s content (animated height).
    expander_clip_prev: ?dvui.Rect.Physical = null,
    /// SAFETY: Set in `install`
    parent_focus_id: ?dvui.Id = undefined,

    pub fn wrapOuter(opts: Options) Options {
        var ret = opts;
        ret.tab_index = null;
        ret.border = Rect{};
        ret.padding = Rect{};
        ret.margin = .{};
        ret.background = false;
        return ret;
    }

    pub fn wrapInner(opts: Options) Options {
        var ret = opts;
        ret.name = null;
        ret.role = null;
        ret.label = null;
        return ret;
    }

    pub var defaults = Options{
        .name = "Branch",
        .role = .tree_item,
        .label = .{ .label_widget = .next },
        .margin = dvui.Rect.all(1),
        .padding = dvui.Rect.all(2),
    };

    pub fn init(self: *Branch, src: std.builtin.SourceLocation, tw: *TreeWidget, init_opts: Branch.InitOptions, opts: Options) void {
        self.* = .{};
        self.tree = tw;
        self.init_options = init_opts;
        self.options = defaults.override(opts);
        self.wd = WidgetData.init(src, .{}, wrapOuter(self.options).override(.{ .rect = .{} }));
        self.expanded = if (dvui.dataGet(null, self.wd.id, "_expanded", bool)) |e| e else init_opts.expanded;
    }

    // can call this after init before install
    pub fn floating(self: *Branch) bool {
        if (self.tree.drag_point == null or self.tree.drag_ending) return false;
        return self.floating_widget != null;
    }

    /// True while this branch is a secondary source of an active multi-drag (dragged but not the
    /// primary "floating ghost" row). Callers can use this to render the row as a placeholder slot.
    pub fn dragSourceSecondary(self: *Branch) bool {
        if (self.tree.drag_point == null or self.tree.drag_ending) return false;
        const bid = self.init_options.branch_id orelse self.data().id.asUsize();
        if (self.tree.id_branch) |idb| {
            if (idb == bid) return false;
        }
        if (self.tree.drag_branch_ids) |ids| {
            for (ids) |id| {
                if (id == bid) return true;
            }
        }
        return false;
    }

    pub fn install(self: *Branch) void {
        self.installed = true;
        var check_button_hovered: bool = false;
        const branch_id = self.init_options.branch_id orelse self.data().id.asUsize();
        if (self.tree.drag_point) |dp| {
            if (self.tree.isDragSource(branch_id)) {
                const drag_min = self.tree.drag_row_size orelse self.tree.branch_size;
                const stack_i = self.tree.multiDragStackIndex(branch_id);
                const row_gap: f32 = 2.0;

                // Reserve the original slot so tree shape does not collapse; row chrome is drawn only
                // in the floating subwindow below (same for primary and secondary multi-drag rows).
                self.wd = WidgetData.init(self.wd.src, .{}, wrapOuter(self.options).override(.{
                    .min_size_content = drag_min,
                }));
                self.wd.register();
                dvui.parentSet(self.widget());

                const slot_rs = self.wd.borderRectScale().r;
                const over_slot = slot_rs.contains(dvui.currentWindow().mouse_pt);
                if (over_slot) {
                    slot_rs.fill(.all(8), .{ .color = dvui.themeGet().color(.content, .fill), .fade = 1.0 });
                } else {
                    slot_rs.fill(.all(8), .{ .color = dvui.themeGet().color(.err, .fill), .fade = 0.25 });
                }

                var npt = dp.plus(dvui.dragOffset().plus(.{ .x = 5, .y = 5 })).toNatural();
                npt.y += @as(f32, @floatFromInt(stack_i)) * (drag_min.h + row_gap);

                self.floating_widget = @as(dvui.FloatingWidget, undefined);
                self.floating_widget.?.init(
                    @src(),
                    .{ .mouse_events = false },
                    .{
                        .rect = Rect.fromPoint(.cast(npt)),
                        .min_size_content = drag_min,
                        .background = true,
                        .corner_radius = dvui.Rect.all(8),
                        .color_fill = dvui.themeGet().color(.content, .fill).opacity(0.9),
                        .box_shadow = .{
                            .fade = 8,
                            .corner_radius = dvui.Rect.all(8),
                            .alpha = 0.25,
                            .color = .black,
                        },
                    },
                );
            } else {
                self.wd = WidgetData.init(self.wd.src, .{}, wrapOuter(self.options));
                self.wd.register();
                dvui.parentSet(self.widget());

                var rs = self.wd.rectScale();

                // Hit-test by mouse position; last branch that contains the cursor wins
                if (rs.r.contains(dp)) {
                    if (!self.expanded) {
                        // Auto-expand after timer so hover over closed folder opens it.
                        // Set only `init_options.expanded` so `self.expanded` stays false until
                        // `expander()` runs: that keeps `init_options.expanded != self.expanded` and
                        // replays the same open animation as a click.
                        if (dvui.timerDone(self.data().id)) {
                            self.init_options.expanded = true;
                        } else {
                            _ = dvui.timer(self.data().id, 500_000);
                        }
                        self.tree.drop_target_branch_id = branch_id;
                        // drop_target_rs set after button.init() so we use full row (incl. expander)
                        self.tree.drop_target_drop_into = self.init_options.can_accept_children;
                    } else {
                        check_button_hovered = true;
                    }
                }
            }
        } else {
            self.wd = WidgetData.init(self.wd.src, .{}, wrapOuter(self.options));

            self.wd.register();
            dvui.parentSet(self.widget());
        }

        // Branch.layout stacks the header row and the expander vertically. Only one child may use
        // vertical expand; the hbox row below uses `.both`, so the button must stay horizontal-only
        // even when the Branch outer widget uses `.expand = .both` (fills the tree from the parent).
        self.button.init(@src(), .{ .draw_focus = false }, wrapInner(self.options).override(.{ .expand = .horizontal }));
        if (self.init_options.process_events) {
            self.button.processEvents();
        }
        // `dvui.clicked` (ButtonWidget) uses `dragPreStart(., .{})` on press, then marks the event
        // handled — so the loop below never sees the press. Re-apply with a grab offset for this row.
        if (self.init_options.process_events and self.tree.init_options.enable_reordering) {
            for (dvui.events()) |*e| {
                if (e.evt != .mouse) continue;
                const me = e.evt.mouse;
                if (me.action != .press or !me.button.pointer()) continue;
                if (!dvui.captured(self.button.data().id)) continue;
                const cw = dvui.currentWindow();
                if (cw.dragging.state != .none) dvui.dragEnd();
                const tl = self.button.data().rectScale().r.topLeft();
                dvui.dragPreStart(me.p, .{ .offset = tl.diff(me.p) });
            }
        }
        self.button.drawBackground();
        self.button.drawFocus();

        // Full row rect: branch x/w; when expanded the expander/padding can extend above the button so use branch top -> button bottom
        const button_rs = self.button.data().borderRectScale();
        const branch_rs = self.data().rectScale();
        var row_rs = button_rs;
        row_rs.r.x = branch_rs.r.x;
        row_rs.r.w = branch_rs.r.w;
        if (self.expanded) {
            row_rs.r.y = branch_rs.r.y;
            row_rs.r.h = (button_rs.r.y + button_rs.r.h) - branch_rs.r.y;
        }

        if (self.tree.drop_target_branch_id == branch_id) {
            self.tree.drop_target_rs = row_rs;
        }

        // Hit-test: when over this branch's header row, claim the drop target.
        // Expanded + can_accept_children: draw indicator around the entire branch and always drop-into (no insert strip).
        // Otherwise: use row_rs and thin insert-before strip at top.
        if (check_button_hovered and self.tree.drag_point != null) {
            const dp = self.tree.drag_point.?;
            if (row_rs.r.contains(dp)) {
                self.tree.drop_target_branch_id = branch_id;
                if (self.expanded and self.init_options.can_accept_children) {
                    self.tree.drop_target_rs = branch_rs;
                    self.tree.drop_target_drop_into = true;
                } else {
                    self.tree.drop_target_rs = row_rs;
                    const insert_before_zone_h = @min(row_rs.r.h * 0.12, 5.0 * row_rs.s);
                    const in_insert_before_strip = dp.y < row_rs.r.y + insert_before_zone_h;
                    self.tree.drop_target_drop_into = self.init_options.can_accept_children and !in_insert_before_strip;
                }
            }
        }

        // Do not take size from the drag source row while it is laid out in the floating subwindow:
        // the floating parent can grow without bound and would feed back into min_size next frame.
        if (!self.floating()) {
            self.tree.branch_size = self.button.data().rect.size();
        }

        self.parent_focus_id = self.tree.current_branch_focus_id;
        self.tree.current_branch_focus_id = self.button.data().id;

        self.hbox.init(@src(), .{ .dir = .horizontal }, .{ .expand = .both });

        for (dvui.events()) |*e| {
            if (!self.button.matchEvent(e))
                continue;

            switch (e.evt) {
                .mouse => |me| {
                    if (!self.tree.init_options.enable_reordering) continue;
                    if (me.action == .press and me.button.pointer()) {
                        // `process_events == true`: offset is set above, after `button.processEvents` (the
                        // event is already handled, so this branch is not reached for press).
                        if (!self.init_options.process_events) {
                            const cw = dvui.currentWindow();
                            if (cw.dragging.state != .none) dvui.dragEnd();
                            const tl = self.button.data().rectScale().r.topLeft();
                            dvui.dragPreStart(me.p, .{ .offset = tl.diff(me.p) });
                        }
                        continue;
                    }
                    if (me.action == .motion) {
                        if (dvui.captured(self.button.data().id)) {
                            e.handle(@src(), self.button.data());
                            if (dvui.dragging(me.p, null)) |_| {
                                const bid = self.init_options.branch_id orelse self.data().id.asUsize();
                                const row_size = self.button.data().rect.size();
                                if (self.tree.selected_branch_ids) |ids| {
                                    var this_in = false;
                                    for (ids) |i| if (i == bid) {
                                        this_in = true;
                                        break;
                                    };
                                    if (this_in and ids.len > 1) {
                                        self.tree.dragStartMulti(bid, ids, me.p, row_size);
                                    } else {
                                        self.tree.dragStart(bid, me.p, row_size);
                                    }
                                } else {
                                    self.tree.dragStart(bid, me.p, row_size);
                                }
                            }
                        }
                    }
                },
                .key => |ke| {
                    if (ke.action != .down and ke.action != .repeat)
                        continue;

                    switch (ke.code) {
                        .right => {
                            e.handle(@src(), self.button.data());
                            if (self.expanded) {
                                dvui.tabIndexNextEx(e.num, self.tree.group.tab_index_prev, self.tree.data().id, false);
                            } else {
                                self.expanded = true;
                            }
                        },
                        .left => {
                            e.handle(@src(), self.button.data());
                            if (self.expanded) {
                                self.expanded = false;
                            } else if (self.parent_focus_id) |pid| {
                                dvui.focusWidget(pid, null, e.num);
                            } else {
                                // no parent, so focus the first branch of the tree
                                while (dvui.focusedWidgetId() != null) {
                                    dvui.tabIndexPrevEx(e.num, self.tree.group.tab_index_prev, self.tree.data().id, false);
                                }
                                dvui.tabIndexNextEx(e.num, self.tree.group.tab_index_prev, self.tree.data().id, false);
                            }
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }
    }

    pub const ExpanderOptions = struct {
        indent: f32 = 10.0,
    };

    pub fn expanding(self: *Branch) bool {
        if (self.anim) |a| {
            return a.val != null;
        }

        return false;
    }

    pub fn expander(self: *Branch, src: std.builtin.SourceLocation, init_opts: ExpanderOptions, opts: Options) bool {
        var clicked: bool = false;
        if (self.button.clicked()) {
            const r = self.button.data().borderRectScale().r;
            if (!pointerReleaseInRectHasSelectionModifier(r)) {
                clicked = true;
            }
        }

        self.hbox.deinit();
        self.button.deinit();

        const default_opts = Options{
            .name = "Expander",
            .margin = .{ .x = init_opts.indent },
        };

        self.anim = dvui.animate(
            @src(),
            .{
                .duration = self.init_options.animation_duration,
                .easing = self.init_options.animation_easing,
                .kind = if (self.init_options.animation_duration > 0) .vertical else .none,
            },
            default_opts.override(opts),
        );

        if (clicked or self.init_options.expanded != self.expanded) {
            if (self.expanded) {
                self.anim.?.init_opts.easing = dvui.easing.outQuad;
                self.anim.?.init_opts.duration = @divTrunc(self.init_options.animation_duration, 2);
                self.anim.?.startEnd();
            } else {
                self.anim.?.val = 0.0;
                self.anim.?.start();
                self.expanded = true;
            }
        }

        if (self.anim.?.end()) {
            self.expanded = false;
        }

        if (self.expanded) {
            // Always expand the inner box to fill the animation
            const expander_opts = dvui.Options{ .expand = .both };

            self.expander_vbox.init(src, .{ .dir = .vertical }, expander_opts.override(opts.strip()));
            self.expander_vbox.drawBackground();

            // AnimateWidget shrinks layout height but does not clip drawing; row content (icons,
            // sprites) can paint outside the collapsing region without this.
            self.expander_clip_prev = dvui.clip(self.anim.?.data().contentRectScale().r);
        }

        self.can_expand = true;

        return self.expanded;
    }

    pub fn targetRectScale(self: *Branch) ?dvui.RectScale {
        const bid = self.init_options.branch_id orelse self.data().id.asUsize();
        if (self.tree.drop_target_branch_id == bid) {
            return self.tree.drop_target_rs;
        }
        return null;
    }

    pub fn removed(self: *Branch) bool {
        if (!self.tree.drag_ending) return false;
        const bid = self.init_options.branch_id orelse self.data().id.asUsize();
        if (self.tree.drag_branch_ids) |ids| {
            for (ids) |id| {
                if (id == bid) return true;
            }
            return false;
        }
        if (self.tree.id_branch) |idb| {
            if (idb == bid) return true;
        }
        return false;
    }

    // must be called after install()
    pub fn insertBefore(self: *Branch) bool {
        if (!self.installed) {
            dvui.log.err("Branch.insertBefore() must be called after install()", .{});
            std.debug.assert(false);
        }

        const bid = self.init_options.branch_id orelse self.data().id.asUsize();
        if (self.tree.drag_ending and self.tree.drop_target_branch_id == bid and !self.tree.drop_target_drop_into) {
            return true;
        }

        return false;
    }

    /// True when drop would add as first child of this branch (only when can_accept_children and pointer in drop-into zone).
    pub fn dropInto(self: *Branch) bool {
        if (!self.installed) {
            dvui.log.err("Branch.dropInto() must be called after install()", .{});
            std.debug.assert(false);
        }

        const bid = self.init_options.branch_id orelse self.data().id.asUsize();
        if (self.tree.drag_ending and self.tree.drop_target_branch_id == bid and self.tree.drop_target_drop_into) {
            return true;
        }

        return false;
    }

    pub fn widget(self: *Branch) Widget {
        return Widget.init(self, Branch.data, Branch.rectFor, Branch.screenRectScale, Branch.minSizeForChild);
    }

    pub fn data(self: *Branch) *WidgetData {
        return self.wd.validate();
    }

    pub fn rectFor(self: *Branch, id: dvui.Id, min_size: Size, e: Options.Expand, g: Options.Gravity) Rect {
        return self.layout.rectFor(self.data().contentRect().justSize(), id, min_size, e, g);
    }

    pub fn screenRectScale(self: *Branch, rect: Rect) RectScale {
        return self.data().contentRectScale().rectToRectScale(rect);
    }

    pub fn minSizeForChild(self: *Branch, s: Size) void {
        const ms = self.layout.minSizeForChild(s);
        self.data().minSizeMax(self.data().options.padSize(ms));
    }

    pub fn deinit(self: *Branch) void {
        defer if (dvui.widgetIsAllocated(self)) dvui.widgetFree(self);
        defer self.* = undefined;

        if (self.drag_alpha_restore) |a| {
            dvui.alphaSet(a);
        }

        if (self.can_expand) {
            if (self.expanded) {
                if (self.expander_clip_prev) |p| {
                    dvui.clipSet(p);
                    self.expander_clip_prev = null;
                }
                self.expander_vbox.deinit();
            }
            if (self.anim) |a| {
                a.deinit();
            }

            dvui.dataSet(null, self.data().id, "_expanded", self.expanded);
        } else {
            self.hbox.deinit();
            self.button.deinit();
        }

        if (self.floating_widget) |*fw| {
            self.data().minSizeMax(fw.data().min_size);
            fw.deinit();
        }

        self.data().minSizeSetAndRefresh();
        self.data().minSizeReportToParent();

        self.tree.current_branch_focus_id = self.parent_focus_id;
        dvui.parentReset(self.data().id, self.data().parent);
    }
};

test {
    @import("std").testing.refAllDecls(@This());
}
