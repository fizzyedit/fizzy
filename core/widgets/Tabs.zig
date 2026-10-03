//! A reorderable strip of tabs.
//!
//! Fizzy's bottom panel and the workbench's document tabs had **the same code twice** — not
//! similar code, the same: identical `tabs_drag_index` / `tabs_removed_index` /
//! `tabs_insert_before_index` state, the same `dvui.reorder` scaffolding, the same
//! floating/removed/insertBefore capture, the same drag handling. Only three things ever
//! differed:
//!
//!   1. what the tabs *represent* — open documents vs registered views,
//!   2. how each tab *looks* — an icon, a dirty dot and a close button vs an uppercase label,
//!   3. how selection is decided.
//!
//! So this owns the scaffolding and the caller owns all three. It lives in `core` because both
//! sides need it and they are on opposite sides of the plugin boundary: the panel is fizzy, the
//! workbench is a dylib.
//!
//! Usage:
//! ```zig
//! var strip: Tabs = .init(@src(), &self.tab_info, .{ .drag_name = drag_name });
//! defer strip.deinit();
//! for (items, 0..) |item, i| {
//!     var t = strip.tab(@src(), i, i == active_index);
//!     defer t.deinit();
//!     // draw whatever a tab looks like here
//! }
//! ```
const std = @import("std");
const dvui = @import("dvui");
const dialogs = @import("../dialogs.zig");
const corners = @import("../corners.zig");

const Tabs = @This();

/// A strip's live drag state, owned by the caller so it survives across frames — the same
/// arrangement as `dvui.ScrollInfo`, and named for it: you keep one and pass it in, and reading
/// it afterwards is how you learn a tab moved.
pub const TabInfo = struct {
    drag_index: ?usize = null,
    removed_index: ?usize = null,
    insert_before_index: ?usize = null,
};

pub const Options = struct {
    /// dvui drag namespace. Two strips that should be able to exchange tabs share a name; two
    /// that must not, must not.
    drag_name: []const u8,
    /// Disambiguates strips built from the same source location (e.g. one per split).
    id_extra: usize = 0,
    /// Scroll along the strip when the tabs overflow.
    scroll: bool = true,
    /// Which way the tabs run: a strip above a pane, or a rail beside one.
    dir: dvui.enums.Direction = .horizontal,
    /// Options for the outermost box, over the strip's own (`expand`, `min_size_content`, …).
    outer: dvui.Options = .{},
    /// Shade the ends the tabs continue past (`scrollShadows`), for a strip that does not say
    /// so some other way.
    scroll_shadows: bool = false,
};

/// How long a finger holds still on something draggable in a scrolling list before it lifts
/// rather than scrolls — a tab, a rail icon, a picker card. One number, so every such list
/// answers a finger the same way.
pub const touch_hold_ns: i128 = 400 * std.time.ns_per_ms;

info: *TabInfo,
opts: Options,
outer: *dvui.BoxWidget,
scroll_area: ?*dvui.ScrollAreaWidget,
reorder: *dvui.ReorderWidget,
inner: *dvui.BoxWidget,
/// Where a dragged item would land this frame, for its slot (`deinit`).
slot: ?dvui.RectScale = null,

pub fn init(src: std.builtin.SourceLocation, info: *TabInfo, opts: Options) Tabs {
    const vertical = opts.dir == .vertical;
    const outer = dvui.box(src, .{ .dir = opts.dir }, (dvui.Options{
        .expand = .none,
        .margin = dvui.Rect.all(0),
        .padding = dvui.Rect.all(0),
        .id_extra = opts.id_extra,
    }).override(opts.outer));

    const scroll_area: ?*dvui.ScrollAreaWidget = if (opts.scroll) dvui.scrollArea(@src(), .{
        .horizontal = if (vertical) .none else .auto,
        .vertical = if (vertical) .auto else .none,
        .horizontal_bar = .hide,
        .vertical_bar = .hide,
    }, .{
        .expand = if (vertical) .both else .none,
        .background = false,
        .style = .content,
        .margin = dvui.Rect.all(0),
        .padding = dvui.Rect.all(0),
        .border = dvui.Rect.all(0),
        .corners = dvui.CornerRect.all(0),
        .ninepatch_fill = &dvui.Ninepatch.none,
        .ninepatch_hover = &dvui.Ninepatch.none,
        .ninepatch_press = &dvui.Ninepatch.none,
        .id_extra = opts.id_extra,
    }) else null;

    const reorder = dvui.reorder(@src(), .{ .drag_name = opts.drag_name }, .{
        .expand = if (vertical) .horizontal else .none,
        .background = false,
    });

    const inner = dvui.box(@src(), .{ .dir = opts.dir }, .{
        .expand = if (vertical) .horizontal else .none,
        .margin = dvui.Rect.all(0),
        .padding = dvui.Rect.all(0),
        .id_extra = opts.id_extra,
    });

    return .{
        .info = info,
        .opts = opts,
        .outer = outer,
        .scroll_area = scroll_area,
        .reorder = reorder,
        .inner = inner,
    };
}

/// One tab. Draw its contents between this and `Tab.deinit()`.
pub const Tab = struct {
    reorderable: *dvui.ReorderWidget.Reorderable,
    /// A **pointer**, not a value. A `BoxWidget` registers itself as dvui's current parent using
    /// its own address, so a box held by value inside a struct returned from `tab()` leaves dvui
    /// pointing at the dead stack temporary — every widget drawn inside the tab then crashes
    /// dereferencing its parent. dvui's own `dvui.box` uses `widgetAlloc` for this reason.
    box: *dvui.BoxWidget,
    /// True while this tab is the one being dragged — the only state at which a resting tab
    /// draws a fill, as reorder feedback.
    floating: bool,
    selected: bool,
    processed: bool = false,
    was_clicked: bool = false,

    /// Runs the strip's shared press/drag handling and reports whether this tab was clicked.
    ///
    /// Call it *after* drawing the tab body — the handling needs the body's laid-out rect, and
    /// that ordering is what the two hand-rolled copies did. Idempotent, so calling it twice is
    /// harmless.
    ///
    /// What it owns: press selects and arms a drag; motion while captured starts the reorder;
    /// release ends it. What it does *not* own is what "selected" means — the caller does that,
    /// because that is the only part that differed between documents and views.
    ///
    /// A finger is read differently, because touching a strip is also how it scrolls: a tab is
    /// clicked when the finger lifts, not when it lands; a finger that moves on straight away is
    /// scrolling, and the tab lets go of it; one held still for `touch_hold_ns` first lifts the
    /// tab to reorder it, as a mouse drag does.
    pub fn clicked(self: *Tab) bool {
        if (self.processed) return self.was_clicked;
        self.processed = true;
        const id = self.box.data().id;

        loop: for (dvui.events()) |*e| {
            if (!self.box.matchEvent(e)) continue;
            switch (e.evt) {
                .mouse => |me| {
                    if (me.action == .press and me.button.pointer()) {
                        if (me.button.touch()) {
                            dvui.dataSet(null, id, "_touch_down", dvui.frameTimeNS());
                        } else {
                            self.was_clicked = true;
                            dvui.dataRemove(null, id, "_touch_down");
                        }
                        dvui.refresh(null, @src(), id);
                        e.handle(@src(), self.box.data());
                        dvui.captureMouse(self.box.data(), e.num);
                        dvui.dragPreStart(me.button, me.p, .{
                            .size = self.reorderable.data().rectScale().r.size(),
                            .offset = self.reorderable.data().rectScale().r.topLeft().diff(me.p),
                        });
                    } else if (me.action == .release and me.button.pointer()) {
                        // A finger that lifts without having moved off is a tap.
                        if (me.button.touch() and dvui.captured(id)) self.was_clicked = true;
                        dvui.dataRemove(null, id, "_touch_down");
                        dvui.captureMouse(null, e.num);
                        dvui.dragEnd();
                    } else if (me.action == .motion) {
                        if (dvui.captured(id)) {
                            if (dvui.dragging(me.p, null)) |_| {
                                if (me.button.touch() and !heldLongEnough(id)) {
                                    // Moving on at once: a scroll. Let the list have it.
                                    dvui.dataRemove(null, id, "_touch_down");
                                    dvui.captureMouse(null, e.num);
                                    dvui.dragEnd();
                                    break :loop;
                                }
                                e.handle(@src(), self.box.data());
                                self.reorderable.reorder.dragStart(self.reorderable.data().id.asUsize(), me.p, 0);
                                break :loop;
                            }
                            e.handle(@src(), self.box.data());
                        }
                    }
                },
                else => {},
            }
        }
        return self.was_clicked;
    }

    fn heldLongEnough(id: dvui.Id) bool {
        const down = dvui.dataGet(null, id, "_touch_down", i128) orelse return false;
        return dvui.frameTimeNS() - down >= touch_hold_ns;
    }

    pub fn deinit(self: *Tab) void {
        _ = self.clicked();
        self.box.deinit();
        self.reorderable.deinit();
    }
};

pub fn tab(self: *Tabs, src: std.builtin.SourceLocation, index: usize, selected: bool) Tab {
    // dvui's own slot is a square of the focus colour; the strip draws its own (`deinit`).
    const reorderable = self.reorder.reorderable(src, .{ .draw_target = false }, .{
        .expand = if (self.opts.dir == .vertical) .horizontal else .vertical,
        .id_extra = index,
        .padding = dvui.Rect.all(0),
        .margin = dvui.Rect.all(0),
        .border = .all(0),
    });

    if (reorderable.targetRectScale()) |rs| self.slot = rs;
    const floating = reorderable.floating();
    if (floating) self.info.drag_index = index;
    if (reorderable.removed()) {
        self.info.removed_index = index;
    } else if (reorderable.insertBefore()) {
        self.info.insert_before_index = index;
    }

    const box = dvui.widgetAlloc(dvui.BoxWidget);
    box.init(@src(), .{ .dir = .horizontal }, .{
        // A rail's cell is its full width, so the whole row is the hit area.
        .expand = if (self.opts.dir == .vertical) .horizontal else .none,
        .border = dvui.Rect.all(0),
        .background = false,
        .color_fill = .{ .color = .transparent },
        .corners = corners.all(corners.small),
        .id_extra = index,
        .padding = .{ .x = 2, .y = 2, .w = 2, .h = 2 },
        .margin = dvui.Rect.all(0),
        .ninepatch_fill = &dvui.Ninepatch.none,
        .ninepatch_hover = &dvui.Ninepatch.none,
        .ninepatch_press = &dvui.Ninepatch.none,
    });
    // Carried along the strip, it is glass (`dialogs.carriedGlass`), the slot it would land in
    // showing through it — the look a tab carried along a document's strip has, and a view carried
    // over the places.
    if (floating) {
        const frs = box.data().borderRectScale();
        dialogs.carriedGlass(box.data().id, frs.r, frs.s);
    }

    return .{ .reorderable = reorderable, .box = box, .floating = floating, .selected = selected };
}

/// The trailing drop slot, so a tab can be dragged past the last one. `count` is the number of
/// tabs drawn, which is the index a drop past the end inserts at.
pub fn finalSlot(self: *Tabs, count: usize) void {
    // `ReorderWidget.finalSlot`, with its target drawn by the strip rather than as dvui's square.
    if (!self.reorder.needFinalSlot()) return;
    var r = self.reorder.reorderable(@src(), .{ .last_slot = true, .draw_target = false }, .{});
    defer r.deinit();
    if (r.targetRectScale()) |rs| self.slot = rs;
    if (r.insertBefore()) self.info.insert_before_index = count;
}

pub fn deinit(self: *Tabs) void {
    // The slot a dragged item will land in: the highlight a document's strip opens for a tab
    // (`dialogs.dropSlot`), seen through the glass of the item carried over it. It was a pane of
    // glass itself, under an item drawn solid — the glass on the wrong one of the two.
    if (self.slot) |rs| dialogs.dropSlot(rs.r, rs.s);
    self.inner.deinit();
    self.reorder.deinit();
    if (self.scroll_area) |sa| {
        if (self.opts.scroll_shadows) @import("../widgets.zig").scrollShadows(sa);
        sa.deinit();
    }
    self.outer.deinit();
}
