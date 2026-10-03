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
//!   * dragging an item lifts it into the ordinary view drag, the one drag a view is ever carried
//!     in: along a chooser — this one, or another place's — it is carried as a tab in glass, and
//!     the chooser under it opens a slot where it would go in (`ViewDrag.offerChooser` with where
//!     along it); let go there it goes in (`ViewDrag.insertInto`), which back on its own chooser
//!     moves it along the place's list — kept as the place's order (`State.order`), or its
//!     assignment's order when it has one, never as a new assignment, which would freeze a keyword
//!     place against views installed later. Off the choosers it is the view drag over the places,
//!     to land on another place or split one — the gesture the corner chooser starts;
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
kept: *Kept,
strip: core.widgets.Tabs,
/// The chooser's own rect.
bounds: dvui.Rect.Physical,
/// The place's views, less the one the view drag is carrying (`carried`).
all: []const *Layout.Surface,
selected_id: ?[]const u8,
/// Views in the order their items were drawn, and where each item was: where along the chooser a
/// carried view goes in (`insertAt`), and what a lift carries.
drawn: std.ArrayListUnmanaged([]const u8) = .empty,
drawn_rects: std.ArrayListUnmanaged(dvui.Rect.Physical) = .empty,
picked_id: ?[]const u8 = null,
picked_again_id: ?[]const u8 = null,
/// One of the place's views is in the view drag's hand: not on the chooser while it is carried,
/// as a tab lifted off a strip leaves its place.
carried: ?[]const u8 = null,
/// The slot is open this frame (`openSlot`).
slot_drawn: bool = false,
/// An item lifted this frame, to carry once the chooser has drawn (`carryLifted`).
lifted: ?Lift = null,

const Lift = struct { id: []const u8, rect: dvui.Rect.Physical, event: u16 };

/// What a chooser keeps between frames, in dvui's store under wherever it is drawn, so it lives
/// as long as the chooser does and two never share one.
const Kept = struct {
    /// Where the slot opens: before the item drawn at this index, or past the last — read last
    /// frame from where the carried view was over the chooser. Null when nothing carried is.
    slot_at: ?usize = null,
    /// How long, along the chooser, the item last lifted off it was, and which it was (a hash of
    /// its view's id): the slot's length for it.
    lifted_len: f32 = 0,
    lifted_key: u64 = 0,
    /// How long an item was along the chooser, last frame: the slot's length for a view carried
    /// in from elsewhere.
    item_len: f32 = 0,
};

/// A chooser for `place`: a declared region, or `.{ .keywords = … }` for the place with those
/// keywords. Draw items with `item`, then `deinit`.
pub fn init(src: std.builtin.SourceLocation, f: *Layout, place: Region, opts: Options) Chooser {
    const key = place.selectionKey();
    const id_extra = opts.id_extra ^ @as(usize, @truncate(key));
    const kept = dvui.dataGetPtrDefault(null, dvui.parentGet().extendId(src, id_extra), "_chooser", Kept, .{});
    const d = &f.state.view_drag;
    if (!d.active()) kept.slot_at = null;

    var strip: core.widgets.Tabs = .init(src, .{
        .id_extra = id_extra,
        .scroll = opts.scroll,
        .dir = opts.dir,
        .outer = opts.outer,
        .scroll_shadows = opts.scroll_shadows,
    });
    // Carried along the chooser near an end of it, it scrolls that way.
    if (kept.slot_at != null) strip.scrollToward(dvui.currentWindow().mouse_pt);

    const sel = f.selectedIn(&place);
    var all = f.matchingIn(&place);
    var carried: ?[]const u8 = null;
    if (d.active() and d.moved_id.len > 0) {
        for (all) |s| if (std.mem.eql(u8, s.id, d.moved_id)) {
            carried = s.id;
        };
        if (carried) |c| {
            var rest: std.ArrayListUnmanaged(*Layout.Surface) = .empty;
            for (all) |s| if (!std.mem.eql(u8, s.id, c)) rest.append(f.arena, s) catch {};
            all = rest.items;
        }
    }
    return .{
        .layout = f,
        .place = place,
        .opts = opts,
        .kept = kept,
        .strip = strip,
        .bounds = strip.outer.data().borderRectScale().r,
        .all = all,
        .selected_id = if (sel) |s| s.id else null,
        .carried = carried,
    };
}

/// The place's views, in its order — less the one the view drag is carrying, which is in the
/// hand. Draw an item for whichever of them this chooser lists.
pub fn views(self: *const Chooser) []const *Layout.Surface {
    return self.all;
}

/// One item. Draw what it looks like between this and `Item.deinit`.
pub fn item(self: *Chooser, src: std.builtin.SourceLocation, view: *const Layout.Surface, opts: ItemOptions) Item {
    const index = self.drawn.items.len;
    if (self.kept.slot_at) |at| if (at == index) self.openSlot();
    self.drawn.append(self.layout.arena, view.id) catch {};
    const selected = if (self.selected_id) |id| std.mem.eql(u8, id, view.id) else false;
    return .{
        .chooser = self,
        .view = view,
        // Keyed by the view, not its place in the list: an item lifted out of it, or a slot
        // opening in it, moves the rest along, and keyed by index each would take on another's
        // size for a frame.
        .tab = self.strip.tab(src, @truncate(std.hash.Wyhash.hash(0, view.id)), selected),
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
        const rect = self.tab.box.data().borderRectScale().r;
        c.drawn_rects.append(c.layout.arena, rect) catch {};
        if (self.tab.clicked()) {
            if (self.selected) {
                c.picked_again_id = self.view.id;
            } else {
                c.picked_id = self.view.id;
                c.layout.selectIn(&c.place, self.view.id);
            }
            dvui.refresh(null, @src(), null);
        }
        if (self.tab.lifted()) |event| c.lifted = .{ .id = self.view.id, .rect = rect, .event = event };
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
    // Past the last item.
    if (!self.slot_drawn) if (self.kept.slot_at != null) self.openSlot();
    self.strip.deinit();
    self.measureItems();
    self.carryLifted();
    self.offerDrop();
}

/// The slot where a carried view would go in, before the next item drawn or past the last: as
/// long as the item was if it was lifted off this chooser, as long as an item is otherwise.
fn openSlot(self: *Chooser) void {
    self.slot_drawn = true;
    const k = self.kept;
    const d = &self.layout.state.view_drag;
    const lifted_here = d.moved_id.len > 0 and k.lifted_key == std.hash.Wyhash.hash(0, d.moved_id);
    const s = dvui.currentWindow().natural_scale;
    const len = if (lifted_here and k.lifted_len > 0) k.lifted_len else if (k.item_len > 0) k.item_len else default_slot * s;
    self.strip.gap(@src(), len, 0);
}

/// Points: the slot's length when there is nothing to measure it by.
const default_slot: f32 = 80;

/// Whether the chooser runs across (a strip) rather than down (a rail).
fn across(self: *const Chooser) bool {
    return self.opts.dir == .horizontal;
}

/// How long an item is along the chooser, for the slot a view from elsewhere opens.
fn measureItems(self: *Chooser) void {
    var total: f32 = 0;
    for (self.drawn_rects.items) |r| total += if (self.across()) r.w else r.h;
    if (self.drawn_rects.items.len > 0) self.kept.item_len = total / @as(f32, @floatFromInt(self.drawn_rects.items.len));
}

/// An item lifted this frame (`Tabs.Tab.lifted`): carry it in the view drag, from where it stood.
/// Out of an open place it is the place's own drag, which the place drives — it carries what the
/// place shows, so it is shown first — and out of a shut one (a rail beside a closed sidebar) a
/// view carried loose, as a card lifted out of the picker is: the place is not drawing to drive a
/// drag. Either way the slot it leaves, if it is carried back along here, is its own length.
fn carryLifted(self: *Chooser) void {
    const lift = self.lifted orelse return;
    const f = self.layout;
    if (f.state.view_drag.active()) return;
    const name = placeName(f, &self.place) orelse return;
    dvui.dragEnd();
    self.kept.lifted_len = if (self.across()) lift.rect.w else lift.rect.h;
    self.kept.lifted_key = std.hash.Wyhash.hash(0, lift.id);
    const region = regionOf(f, &self.place);
    const open = if (region) |r| r.bounds.w > 1 and r.bounds.h > 1 and !r.isClosed() else false;
    if (open) {
        dvui.captureMouse(null, lift.event);
        f.selectIn(&self.place, lift.id);
        ViewDrag.begin(f, name, region.?.bounds, lift.rect);
    } else {
        f.beginViewDrag(lift.id, lift.rect);
        // From the motion that lifted it on: a release in the same frame is the drag's too.
        if (dvui.currentWindow().capture) |cm| dvui.captureMouseCustom(cm, lift.event);
    }
    self.carried = lift.id;
    dvui.refresh(null, @src(), null);
}

/// While a view is carried, the chooser is somewhere it can go: into this chooser's place, as one
/// of its views, where along it the pointer is — a rail beside a sidebar as much as a strip inside
/// a panel, and the chooser it was lifted off as much as any other. It says so to the drag
/// (`ViewDrag.offerChooser`), which lands a release over it there (`ViewDrag.insertInto`); and
/// while it is the chooser the view is over, it opens a slot there next frame (`openSlot`). It
/// reaches half its thickness past itself toward its place's inside — below a strip, right of a
/// rail — so a hand drifting a little off it is still among its items.
fn offerDrop(self: *Chooser) void {
    const f = self.layout;
    self.kept.slot_at = null;
    if (!f.state.view_drag.active()) return;
    const name = placeName(f, &self.place) orelse return;
    var bounds = self.bounds;
    if (self.across()) bounds.h *= reach else bounds.w *= reach;
    const p = dvui.currentWindow().mouse_pt;
    const at = self.insertAt(p);
    ViewDrag.offerChooser(f, name, bounds, true, at.insert);
    // The chooser the view is over, and its place could take it — the drag's own reading, which
    // asks which window is on top there and what the place accepts. Of two choosers over one
    // place (the rail's list and footer), the one the view is over by its bounds.
    const o = ViewDrag.chooserAt(f.state, p) orelse return;
    if (!std.mem.eql(u8, o.name, name) or !std.meta.eql(o.bounds, bounds)) return;
    self.kept.slot_at = at.index;
}

/// How far a chooser reaches as somewhere to go in, in its own thickness (`offerDrop`).
const reach: f32 = 1.5;

/// Where a view let go at `p` goes in: before the first item (not the carried one) whose middle is
/// past it along the chooser — read as if the open slot were not there, so the slot does not chase
/// the pointer — else after this chooser's last item, which the place may follow with views this
/// chooser does not list. `index` counts the items drawn before it, the carried one left out.
fn insertAt(self: *const Chooser, p: dvui.Point.Physical) struct { index: usize, insert: ViewDrag.Insert } {
    const a = if (self.across()) p.x else p.y;
    var index: usize = 0;
    var last: ?[]const u8 = null;
    for (self.drawn.items, 0..) |id, i| {
        if (self.carried) |c| if (std.mem.eql(u8, c, id)) continue;
        if (i >= self.drawn_rects.items.len) break;
        const r = self.drawn_rects.items[i];
        var start = if (self.across()) r.x else r.y;
        const len = if (self.across()) r.w else r.h;
        if (self.slot_drawn and self.strip.gap_len > 0 and start >= self.strip.gap_at) start -= self.strip.gap_len;
        if (a < start + len / 2) return .{ .index = index, .insert = .{ .before = id } };
        index += 1;
        last = id;
    }
    return .{ .index = index, .insert = if (last) |id| .{ .after = id } else .end };
}

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
