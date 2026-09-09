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
//! var strip: Tabs = .begin(@src(), &self.tab_state, .{ .drag_name = drag_name });
//! defer strip.end();
//! for (items, 0..) |item, i| {
//!     var t = strip.tab(@src(), i, i == active_index);
//!     defer t.end();
//!     // draw whatever a tab looks like here
//! }
//! ```
const std = @import("std");
const dvui = @import("dvui");

const Tabs = @This();

/// Per-strip drag state. The caller owns it so it survives across frames — this is the trio
/// that was duplicated verbatim on both sides.
pub const State = struct {
    drag_index: ?usize = null,
    removed_index: ?usize = null,
    insert_before_index: ?usize = null,

    /// True when a drag finished this frame and the caller should apply a move.
    pub fn pendingMove(self: State) ?struct { from: usize, to: usize } {
        const from = self.removed_index orelse return null;
        const to = self.insert_before_index orelse return null;
        return .{ .from = from, .to = if (to > from) to - 1 else to };
    }

    pub fn clearMove(self: *State) void {
        self.removed_index = null;
        self.insert_before_index = null;
    }
};

pub const Options = struct {
    /// dvui drag namespace. Two strips that should be able to exchange tabs share a name; two
    /// that must not, must not.
    drag_name: []const u8,
    /// Disambiguates strips built from the same source location (e.g. one per split).
    id_extra: usize = 0,
    /// Horizontal scroll when the tabs overflow.
    scroll: bool = true,
};

state: *State,
opts: Options,
outer: *dvui.BoxWidget,
scroll_area: ?*dvui.ScrollAreaWidget,
reorder: *dvui.ReorderWidget,
inner: *dvui.BoxWidget,

pub fn begin(src: std.builtin.SourceLocation, state: *State, opts: Options) Tabs {
    const outer = dvui.box(src, .{ .dir = .horizontal }, .{
        .expand = .none,
        .margin = dvui.Rect.all(0),
        .padding = dvui.Rect.all(0),
        .id_extra = opts.id_extra,
    });

    const scroll_area: ?*dvui.ScrollAreaWidget = if (opts.scroll) dvui.scrollArea(@src(), .{
        .horizontal = .auto,
        .horizontal_bar = .hide,
        .vertical_bar = .hide,
    }, .{
        .expand = .none,
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
        .expand = .none,
        .background = false,
    });

    const inner = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .none,
        .margin = dvui.Rect.all(0),
        .padding = dvui.Rect.all(0),
        .id_extra = opts.id_extra,
    });

    return .{
        .state = state,
        .opts = opts,
        .outer = outer,
        .scroll_area = scroll_area,
        .reorder = reorder,
        .inner = inner,
    };
}

/// One tab. Draw its contents between this and `Tab.end()`.
pub const Tab = struct {
    reorderable: *dvui.ReorderWidget.Reorderable,
    box: dvui.BoxWidget,
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
    pub fn clicked(self: *Tab) bool {
        if (self.processed) return self.was_clicked;
        self.processed = true;

        loop: for (dvui.events()) |*e| {
            if (!self.box.matchEvent(e)) continue;
            switch (e.evt) {
                .mouse => |me| {
                    if (me.action == .press and me.button.pointer()) {
                        self.was_clicked = true;
                        dvui.refresh(null, @src(), self.box.data().id);
                        e.handle(@src(), self.box.data());
                        dvui.captureMouse(self.box.data(), e.num);
                        dvui.dragPreStart(me.button, me.p, .{
                            .size = self.reorderable.data().rectScale().r.size(),
                            .offset = self.reorderable.data().rectScale().r.topLeft().diff(me.p),
                        });
                    } else if (me.action == .release and me.button.pointer()) {
                        dvui.captureMouse(null, e.num);
                        dvui.dragEnd();
                    } else if (me.action == .motion) {
                        if (dvui.captured(self.box.data().id)) {
                            e.handle(@src(), self.box.data());
                            if (dvui.dragging(me.p, null)) |_| {
                                self.reorderable.reorder.dragStart(self.reorderable.data().id.asUsize(), me.p, 0);
                                break :loop;
                            }
                        }
                    }
                },
                else => {},
            }
        }
        return self.was_clicked;
    }

    pub fn end(self: *Tab) void {
        _ = self.clicked();
        self.box.deinit();
        self.reorderable.deinit();
    }
};

pub fn tab(self: *Tabs, src: std.builtin.SourceLocation, index: usize, selected: bool) Tab {
    const reorderable = self.reorder.reorderable(src, .{}, .{
        .expand = .vertical,
        .id_extra = index,
        .padding = dvui.Rect.all(0),
        .margin = dvui.Rect.all(0),
        .border = .all(0),
    });

    const floating = reorderable.floating();
    if (floating) self.state.drag_index = index;
    if (reorderable.removed()) {
        self.state.removed_index = index;
    } else if (reorderable.insertBefore()) {
        self.state.insert_before_index = index;
    }

    var box: dvui.BoxWidget = undefined;
    box.init(@src(), .{ .dir = .horizontal }, .{
        .expand = .none,
        .border = dvui.Rect.all(0),
        .background = floating,
        .color_fill = if (floating) dvui.themeGet().color(.control, .fill) else .transparent,
        .id_extra = index,
        .padding = .{ .x = 2, .y = 2, .w = 2, .h = 2 },
        .margin = dvui.Rect.all(0),
        .ninepatch_fill = &dvui.Ninepatch.none,
        .ninepatch_hover = &dvui.Ninepatch.none,
        .ninepatch_press = &dvui.Ninepatch.none,
    });
    if (floating) box.drawBackground();

    return .{ .reorderable = reorderable, .box = box, .floating = floating, .selected = selected };
}

/// The trailing drop slot, so a tab can be dragged past the last one. `count` is the number of
/// tabs drawn, which is the index a drop past the end inserts at.
pub fn finalSlot(self: *Tabs, count: usize) void {
    if (self.reorder.finalSlot()) {
        self.state.insert_before_index = count;
    }
}

pub fn end(self: *Tabs) void {
    self.inner.deinit();
    self.reorder.deinit();
    if (self.scroll_area) |sa| sa.deinit();
    self.outer.deinit();
}
