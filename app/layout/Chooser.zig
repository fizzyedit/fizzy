//! A **chooser**: the views of one place, laid out as something to pick from.
//!
//! The tab strip above a Multiple place and the icon rail beside the sidebar are the same
//! control — a list of a place's views, where picking one selects it there — differing only in
//! which way they run, where they sit, and what an item looks like. This is that control. What it
//! does is the same everywhere; what it looks like is the caller's:
//!
//! ```zig
//! var rail = Chooser.init(@src(), f, .{ .keywords = sidebar }, .{ .dir = .vertical });
//! defer rail.deinit();
//! for (rail.views()) |view| {
//!     var item = rail.item(@src(), view, .{ .tooltip = true });
//!     defer item.deinit();
//!     drawAnything(view, item.selected, item.hovered());
//! }
//! if (rail.reselected()) |_| toggleThePlace();
//! ```
//!
//! **What every chooser does**, with nothing written for it:
//!
//!   * a click (a tap, for a finger) selects the view in its place;
//!   * dragging an item along the chooser reorders the place's views — kept as the place's
//!     order (`State.order`), or its assignment's order when it has one, never as a new
//!     assignment, which would freeze a keyword place against views installed later;
//!   * dragging an item off the chooser starts the ordinary view drag with that view, so it can
//!     land on another place or split one — the gesture the corner chooser starts;
//!   * a finger drag that moves on at once scrolls instead, and one held still first lifts
//!     (`core.widgets.Tabs`).
//!
//! **What the caller decides:** what an item looks like (`label` and `icon` are the two stock
//! looks), where the chooser sits — inside its place or beside it, before the place is even
//! declared this frame — which views it lists and in what groups (the rail keeps two, a scrolling
//! list and a pinned footer: two choosers over one place), anything drawn between items, and what
//! picking the already-selected item means (`reselected`).
//!
//! Nothing here reaches past the public `Layout` API: a shape that wants a chooser this file
//! cannot draw copies it, per the shipped-shapes methodology in CLAUDE.md.
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const sdk = @import("fizzy_sdk");
const Layout = @import("Layout.zig");
const Region = @import("Region.zig");
const ViewDrag = @import("ViewDrag.zig");

const Chooser = @This();

pub const Options = struct {
    /// Which way the items run: a strip above a place, or a rail beside one.
    dir: dvui.enums.Direction = .horizontal,
    /// Scroll along the chooser when the items overflow.
    scroll: bool = true,
    /// Two choosers over one place in one frame (the rail's list and its footer) differ by this.
    id_extra: usize = 0,
    /// Options for the chooser's outermost box (`expand`, `min_size_content`, …).
    outer: dvui.Options = .{},
    /// Shade the ends the items continue past when they scroll.
    scroll_shadows: bool = false,
};

pub const ItemOptions = struct {
    /// Show the view's title on hover — for a chooser whose items do not say it themselves.
    tooltip: bool = false,
    /// A further line under the title in that tooltip (what a badge means, say).
    tooltip_detail: ?[]const u8 = null,
};

layout: *Layout,
place: Region,
opts: Options,
info: *core.widgets.Tabs.TabInfo,
strip: core.widgets.Tabs,
/// The chooser's own rect, for telling a reorder from a drag off it.
bounds: dvui.Rect.Physical,
all: []const *Layout.Surface,
selected_id: ?[]const u8,
/// Views in the order their items were drawn — what the strip's indices mean — and where each
/// item was, for a drag that starts from one.
drawn: std.ArrayListUnmanaged([]const u8) = .empty,
drawn_rects: std.ArrayListUnmanaged(dvui.Rect.Physical) = .empty,
picked_id: ?[]const u8 = null,
picked_again_id: ?[]const u8 = null,

/// A chooser for `place`: a declared region, or `.{ .keywords = … }` for the place with those
/// keywords. Draw items with `item`, then `deinit`.
pub fn init(src: std.builtin.SourceLocation, f: *Layout, place: Region, opts: Options) Chooser {
    const key = place.selectionKey();
    // Per chooser, kept in dvui's store under wherever it is drawn, so it lives as long as the
    // chooser does and two never share a drag.
    const info = dvui.dataGetPtrDefault(null, dvui.parentGet().extendId(src, opts.id_extra ^ @as(usize, @truncate(key))), "_chooser_tabs", core.widgets.Tabs.TabInfo, .{});
    // Which item is floating is this frame's news; the strip only ever sets it.
    info.drag_index = null;

    // A drag name per chooser, so one chooser's items are not drop targets for another's —
    // moving a view between places is the view drag's job.
    var name_buf: [64]u8 = undefined;
    const drag_name = f.state.internName(f.gpa, std.fmt.bufPrint(&name_buf, "fizzy_chooser:{x}:{x}:{d}", .{
        key,
        opts.id_extra,
        src.line,
    }) catch "fizzy_chooser");

    const strip: core.widgets.Tabs = .init(src, info, .{
        .drag_name = drag_name,
        .id_extra = opts.id_extra ^ @as(usize, @truncate(key)),
        .scroll = opts.scroll,
        .dir = opts.dir,
        .outer = opts.outer,
        .scroll_shadows = opts.scroll_shadows,
    });
    const sel = f.selectedIn(&place);
    return .{
        .layout = f,
        .place = place,
        .opts = opts,
        .info = info,
        .strip = strip,
        .bounds = strip.outer.data().borderRectScale().r,
        .all = f.matchingIn(&place),
        .selected_id = if (sel) |s| s.id else null,
    };
}

/// The place's views, in its order. Draw an item for whichever of them this chooser lists.
pub fn views(self: *const Chooser) []const *Layout.Surface {
    return self.all;
}

/// One item. Draw what it looks like between this and `Item.deinit`.
pub fn item(self: *Chooser, src: std.builtin.SourceLocation, view: *const Layout.Surface, opts: ItemOptions) Item {
    const index = self.drawn.items.len;
    self.drawn.append(self.layout.arena, view.id) catch {};
    const selected = if (self.selected_id) |id| std.mem.eql(u8, id, view.id) else false;
    return .{
        .chooser = self,
        .view = view,
        .tab = self.strip.tab(src, index, selected),
        .selected = selected,
        .opts = opts,
        .index = index,
    };
}

pub const Item = struct {
    chooser: *Chooser,
    view: *const Layout.Surface,
    tab: core.widgets.Tabs.Tab,
    /// This view is the one its place shows.
    selected: bool,
    opts: ItemOptions,
    index: usize,

    /// Under the pointer (and not mid-drag): for a hover look.
    pub fn hovered(self: *Item) bool {
        return core.widgets.hovered(self.tab.box.data());
    }

    /// The item's box, for anything drawn relative to it (a badge on a corner).
    pub fn data(self: *Item) *dvui.WidgetData {
        return self.tab.box.data();
    }

    pub fn deinit(self: *Item) void {
        const c = self.chooser;
        c.drawn_rects.append(c.layout.arena, self.tab.box.data().borderRectScale().r) catch {};
        if (self.tab.clicked()) {
            if (self.selected) {
                c.picked_again_id = self.view.id;
            } else {
                c.picked_id = self.view.id;
                c.layout.selectIn(&c.place, self.view.id);
            }
            dvui.refresh(null, @src(), null);
        }
        if (self.opts.tooltip and !self.selected) self.drawTooltip();
        self.tab.deinit();
    }

    fn drawTooltip(self: *Item) void {
        var tip: dvui.FloatingTooltipWidget = undefined;
        tip.init(@src(), .{
            .active_rect = self.tab.box.data().rectScale().r,
            .delay = 350_000,
        }, core.dialogs.tooltipOptions(self.index));
        defer tip.deinit();
        if (!tip.shown()) return;
        const prev_alpha = core.dialogs.tooltipBeginFor(&tip, 350_000);
        defer dvui.alphaSet(prev_alpha);
        var tl = dvui.textLayout(@src(), .{}, .{ .background = false, .padding = dvui.Rect.all(4) });
        defer tl.deinit();
        const title = std.ascii.allocUpperString(dvui.currentWindow().arena(), self.view.title) catch self.view.title;
        tl.format("{s}", .{title}, .{ .font = dvui.Font.theme(.heading) });
        if (self.opts.tooltip_detail) |d| tl.format("\n{s}", .{d}, .{});
    }
};

/// The view picked this frame, if any — already selected in its place.
pub fn picked(self: *const Chooser) ?[]const u8 {
    return self.picked_id;
}

/// The view picked this frame that was *already* selected — a second click on the showing tab.
/// Nothing is done for it; the caller says what it means (the rail closes or opens its place).
pub fn reselected(self: *const Chooser) ?[]const u8 {
    return self.picked_again_id;
}

pub fn deinit(self: *Chooser) void {
    const f = self.layout;
    self.strip.finalSlot(self.drawn.items.len);
    const strip_id = self.strip.outer.data().id;
    self.strip.deinit();
    self.offerDrop(strip_id);

    // Reordered along the chooser.
    if (self.info.removed_index) |removed| if (self.info.insert_before_index) |before| {
        self.info.removed_index = null;
        self.info.insert_before_index = null;
        if (removed < self.drawn.items.len) {
            const moved = self.drawn.items[removed];
            // Before the item it was dropped in front of, or after this chooser's last item when
            // dropped past the end — the place may hold views this chooser does not list.
            const anchor: Anchor = if (before < self.drawn.items.len)
                .{ .before = self.drawn.items[before] }
            else
                .{ .after = self.drawn.items[self.drawn.items.len - 1] };
            reorder(f, &self.place, moved, anchor);
        }
    };

    // Dragged off the chooser: hand the view to the view drag. Past half the chooser's
    // thickness away, which a reorder along it never reaches.
    if (self.info.drag_index) |i| if (i < self.drawn.items.len and !f.state.view_drag.active()) {
        if (placeName(f, &self.place)) |name| {
            const p = dvui.currentWindow().mouse_pt;
            const b = self.bounds;
            const off = switch (self.opts.dir) {
                .horizontal => p.y < b.y - b.h * 0.5 or p.y > b.y + b.h * 1.5,
                .vertical => p.x < b.x - b.w * 0.5 or p.x > b.x + b.w * 1.5,
            };
            if (off) {
                self.info.* = .{};
                dvui.dragEnd();
                const id = self.drawn.items[i];
                const region = regionOf(f, &self.place);
                const open = if (region) |r| r.bounds.w > 1 and r.bounds.h > 1 and !r.isClosed() else false;
                if (open) {
                    // Out of an open place: the place's own drag, which it drives and which
                    // knows a drop back onto the place is no move at all. It carries what the
                    // place shows, so show this first.
                    dvui.captureMouse(null, 0);
                    f.selectIn(&self.place, id);
                    ViewDrag.begin(f, name, region.?.bounds, if (i < self.drawn_rects.items.len) self.drawn_rects.items[i] else b);
                } else {
                    // Out of a shut place (a rail beside a closed sidebar): the place is not
                    // drawing to drive a drag, and cannot be dropped on. Carry the view loose,
                    // as a card lifted out of the picker is.
                    f.beginViewDrag(id, if (i < self.drawn_rects.items.len) self.drawn_rects.items[i] else b);
                }
                dvui.refresh(null, @src(), null);
            }
        }
    };
}

/// While a view is carried, the chooser is somewhere it can go: into this chooser's place, as one
/// of its views — a rail beside a sidebar as much as a strip inside a panel. It says so to the drag
/// (`ViewDrag.offerChooser`), which lands a release over it there; and under the pointer it shows
/// as one pane of the drop zones' glass across it, where the places' own zones step back. For the
/// place the view came out of it is chrome only: dropping it back is no move.
fn offerDrop(self: *Chooser, key: dvui.Id) void {
    const f = self.layout;
    const d = f.state.view_drag;
    const name = placeName(f, &self.place);
    var lit: ?dvui.Rect.Physical = null;
    if (d.active()) if (name) |n| {
        // Offered for the place the view came out of as well, as chrome: its zones stay off the
        // strip and the card rides as a tab over it (`ViewDrag.interiorBounds`), but a release
        // there lands nowhere — dropping it back is no move — and it does not light.
        const into = !std.mem.eql(u8, n, d.name);
        ViewDrag.offerChooser(f, n, self.bounds, into);
        if (into and self.bounds.contains(dvui.currentWindow().mouse_pt)) lit = self.bounds;
    };
    const drop_key = key.update("_chooser_drop");
    // A release over the chooser lands the view in it, which then shows there: the pane goes with
    // the drag rather than fading round the view that just arrived. Off it, it fades as it leaves.
    if (!d.active()) core.widgets.DropZones.forgetSingle(drop_key);
    core.widgets.DropZones.drawSingle(drop_key, lit, dvui.currentWindow().natural_scale, .{
        .inset = 2,
        .icon = .add,
        .radius = core.corners.scaled(core.corners.small),
    });
}

const Anchor = union(enum) { before: []const u8, after: []const u8 };

/// The declared region a chooser's place is — by its own name, or the one with its keywords.
fn regionOf(f: *Layout, place: *const Region) ?Region {
    if (place.name.len > 0) {
        for (f.state.regions.items) |r| if (std.mem.eql(u8, r.name, place.name)) return r;
        return null;
    }
    return f.state.regionFor(place.keywords);
}

fn placeName(f: *Layout, place: *const Region) ?[]const u8 {
    if (place.name.len > 0) return place.name;
    const r = regionOf(f, place) orelse return null;
    return if (r.name.len > 0) r.name else null;
}

/// Move `moved` next to `anchor` in `place`'s list and keep it. A place the user filled keeps
/// its assignment, reordered; a place its keywords fill keeps an order (`State.setOrder`) and
/// stays open to views that arrive later.
fn reorder(f: *Layout, place: *const Region, moved: []const u8, anchor: Anchor) void {
    const name = placeName(f, place) orelse return;
    const a = f.arena;
    // The whole list to reorder: the assignment when there is one — ids of plugins not loaded
    // now included, so they keep their slots — else what the place shows, then whatever an
    // earlier order named that is not showing now.
    var base: std.ArrayListUnmanaged([]const u8) = .empty;
    const assigned = f.state.assignment(name);
    if (assigned) |ids| {
        base.appendSlice(a, ids) catch return;
    } else {
        for (f.matchingIn(place)) |s| base.append(a, s.id) catch return;
        if (f.state.order(name)) |ids| for (ids) |id| {
            if (!contains(base.items, id)) base.append(a, id) catch return;
        };
    }
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    for (base.items) |id| if (!std.mem.eql(u8, id, moved)) list.append(a, id) catch return;
    const at = switch (anchor) {
        .before => |id| indexOf(list.items, id) orelse list.items.len,
        .after => |id| if (indexOf(list.items, id)) |i| i + 1 else list.items.len,
    };
    list.insert(a, at, moved) catch return;

    if (assigned != null) {
        f.state.assign(f.gpa, name, list.items) catch return;
    } else {
        f.state.setOrder(f.gpa, name, list.items) catch return;
    }
    f.selectIn(place, moved);
    f.state.markDirty();
    dvui.refresh(null, @src(), null);
}

fn indexOf(list: []const []const u8, id: []const u8) ?usize {
    for (list, 0..) |x, i| if (std.mem.eql(u8, x, id)) return i;
    return null;
}

fn contains(list: []const []const u8, id: []const u8) bool {
    return indexOf(list, id) != null;
}

// ── The two stock looks ────────────────────────────────────────────────────────────────────────

/// A tab's look: the view's title, uppercase, in the heading font, highlighted when selected.
pub fn label(view: *const Layout.Surface, selected: bool) void {
    var buf: [64]u8 = undefined;
    const title = if (view.title.len <= buf.len) std.ascii.upperString(&buf, view.title) else view.title;
    const theme = dvui.themeGet();
    dvui.labelNoFmt(@src(), title, .{}, .{
        .color_text = .{ .color = if (selected) theme.color(.highlight, .fill) else theme.color(.control, .text) },
        .font = dvui.Font.theme(.heading),
        .padding = dvui.Rect.all(4),
        .gravity_y = 0.5,
    });
}

/// A rail's look: the view's icon, `size` points tall and centred, highlighted when selected and
/// brightened under the pointer. A view with no tvg icon gets a dot rather than no item.
pub fn icon(view: *const Layout.Surface, selected: bool, hovered: bool, size: f32, id_extra: usize) void {
    const theme = dvui.themeGet();
    const color: dvui.Color = if (selected)
        theme.color(.highlight, .fill)
    else if (hovered)
        theme.color(.window, .text)
    else
        theme.color(.window, .fill);
    // Both fill and stroke: entypo glyphs fill, lucide (and most plugin icons) stroke.
    core.icon.icon(@src(), view.id, switch (view.icon orelse .none) {
        .tvg => |bytes| bytes,
        else => dvui.entypo.dot_single,
    }, .{ .fill_color = .{ .color = color }, .stroke_color = .{ .color = color } }, .{
        .id_extra = id_extra,
        .gravity_x = 0.5,
        .min_size_content = .{ .h = size },
        .padding = .{ .y = size / 2, .h = size / 2 },
    });
}
