//! A strip of tabs — or, run the other way, a rail of icons: items laid out in a row, each one
//! a press away from being picked and a drag away from being lifted.
//!
//! What an item *is*, what it looks like and what picking it means are the caller's. What this
//! owns is the part every strip did the same: the scrolling row, an item's press, click and lift
//! (a finger read as a finger — below), and the open slot a strip shows where something carried
//! along it would go in (`gap`).
//!
//! It does not carry anything itself. A lifted item is reported (`Tab.lifted`) and the caller
//! carries it — in fizzy, the app's view drag, the one drag a view is ever carried in, so an item
//! lifted off a strip is carried the same way wherever it goes, back along its own strip
//! included. The strip only opens where the caller says the carried thing would go in.
//!
//! Usage:
//! ```zig
//! var strip: Tabs = .init(@src(), .{});
//! defer strip.deinit();
//! for (items, 0..) |item, i| {
//!     if (i == slot_at) strip.gap(@src(), carried_len, i);
//!     var t = strip.tab(@src(), keyOf(item), i == active_index);
//!     defer t.deinit();
//!     // draw whatever a tab looks like here
//!     if (t.lifted()) carry(item);
//! }
//! ```
const std = @import("std");
const dvui = @import("dvui");
const corners = @import("../corners.zig");
const dialogs = @import("../dialogs.zig");

const Tabs = @This();

pub const Options = struct {
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

opts: Options,
outer: *dvui.BoxWidget,
scroll_area: ?*dvui.ScrollAreaWidget,
inner: *dvui.BoxWidget,
/// The open slot drawn this frame (`gap`), physical: where it starts along the strip and how long
/// it is. Zero length when none is open.
gap_at: f32 = 0,
gap_len: f32 = 0,

pub fn init(src: std.builtin.SourceLocation, opts: Options) Tabs {
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

    const inner = dvui.box(@src(), .{ .dir = opts.dir }, .{
        .expand = if (vertical) .horizontal else .none,
        .margin = dvui.Rect.all(0),
        .padding = dvui.Rect.all(0),
        .id_extra = opts.id_extra,
    });

    return .{
        .opts = opts,
        .outer = outer,
        .scroll_area = scroll_area,
        .inner = inner,
    };
}

/// Something carried along the strip at `p`, near either end of it, scrolls the strip as far as
/// there are tabs past that end. Call it between `init` and `deinit`, each frame something is
/// carried over the strip.
pub fn scrollToward(self: *Tabs, p: dvui.Point.Physical) void {
    const sa = self.scroll_area orelse return;
    dvui.scrollDrag(.{ .mouse_pt = p, .screen_rect = sa.data().borderRectScale().r });
}

/// One tab. Draw its contents between this and `Tab.deinit()`. `key` is the tab's own — its
/// item's, not its index: dvui keeps each widget's size under its id, and keyed by index, a tab
/// taken out of the strip or put back in it left the ones after it at each other's sizes for a
/// frame.
pub const Tab = struct {
    /// A **pointer**, not a value. A `BoxWidget` registers itself as dvui's current parent using
    /// its own address, so a box held by value inside a struct returned from `tab()` leaves dvui
    /// pointing at the dead stack temporary — every widget drawn inside the tab then crashes
    /// dereferencing its parent. dvui's own `dvui.box` uses `widgetAlloc` for this reason.
    box: *dvui.BoxWidget,
    selected: bool,
    processed: bool = false,
    was_clicked: bool = false,
    /// The motion that lifted it this frame, by event number (`lifted`).
    lift_event: ?u16 = null,

    /// Runs the strip's shared press/drag handling and reports whether this tab was clicked.
    ///
    /// Call it *after* drawing the tab body — the handling needs the body's laid-out rect.
    /// Idempotent, so calling it twice is harmless.
    ///
    /// What it owns: press selects and arms a drag; motion past dvui's drag threshold while
    /// captured lifts the tab (`lifted`); release ends it. What it does *not* own is what
    /// "selected" means, nor what carries a lifted tab — the caller does both.
    ///
    /// A finger is read differently, because touching a strip is also how it scrolls: a tab is
    /// clicked when the finger lifts, not when it lands; a finger that moves on straight away is
    /// scrolling, and the tab lets go of it; one held still for `touch_hold_ns` first lifts the
    /// tab, as a mouse drag does.
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
                        const r = self.box.data().borderRectScale().r;
                        dvui.dragPreStart(me.button, me.p, .{ .size = r.size(), .offset = r.topLeft().diff(me.p) });
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
                                dvui.dataRemove(null, id, "_touch_down");
                                self.lift_event = e.num;
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

    /// Whether the tab was lifted this frame — dragged far enough to be carried — and by which
    /// event: the caller carries it from there, from the motion that lifted it on.
    pub fn lifted(self: *Tab) ?u16 {
        _ = self.clicked();
        return self.lift_event;
    }

    fn heldLongEnough(id: dvui.Id) bool {
        const down = dvui.dataGet(null, id, "_touch_down", i128) orelse return false;
        return dvui.frameTimeNS() - down >= touch_hold_ns;
    }

    pub fn deinit(self: *Tab) void {
        _ = self.clicked();
        self.box.deinit();
    }
};

pub fn tab(self: *Tabs, src: std.builtin.SourceLocation, key: usize, selected: bool) Tab {
    const box = dvui.widgetAlloc(dvui.BoxWidget);
    box.init(src, .{ .dir = .horizontal }, .{
        // A rail's cell is its full width, so the whole row is the hit area.
        .expand = if (self.opts.dir == .vertical) .horizontal else .none,
        .border = dvui.Rect.all(0),
        .background = false,
        .corners = corners.all(corners.small),
        .id_extra = key,
        .padding = .{ .x = 2, .y = 2, .w = 2, .h = 2 },
        .margin = dvui.Rect.all(0),
        .ninepatch_fill = &dvui.Ninepatch.none,
        .ninepatch_hover = &dvui.Ninepatch.none,
        .ninepatch_press = &dvui.Ninepatch.none,
    });

    return .{ .box = box, .selected = selected };
}

/// The open slot where something carried along the strip would go in, `len` long along it
/// (physical) — before whichever tab is drawn next, or past the last. The carried look's drop
/// slot (`dialogs.dropSlot`), seen blurred through the glass of what is carried over it: the same
/// slot every strip opens. `id_extra` tells two apart in one frame.
pub fn gap(self: *Tabs, src: std.builtin.SourceLocation, len: f32, id_extra: usize) void {
    const s = dvui.currentWindow().natural_scale;
    const vertical = self.opts.dir == .vertical;
    var g = dvui.box(src, .{}, .{
        .id_extra = id_extra,
        .expand = if (vertical) .horizontal else .vertical,
        .min_size_content = if (vertical) .{ .w = 1, .h = len / s } else .{ .w = len / s, .h = 1 },
        .margin = .{},
        .padding = .{},
    });
    const rs = g.data().borderRectScale();
    self.gap_at = if (vertical) rs.r.y else rs.r.x;
    self.gap_len = if (vertical) rs.r.h else rs.r.w;
    dialogs.dropSlot(rs.r, rs.s);
    g.deinit();
}

pub fn deinit(self: *Tabs) void {
    self.inner.deinit();
    if (self.scroll_area) |sa| {
        if (self.opts.scroll_shadows) @import("../widgets.zig").scrollShadows(sa);
        sa.deinit();
    }
    self.outer.deinit();
}
