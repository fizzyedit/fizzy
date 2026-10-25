//! A tooltip: fizzy's copy of dvui's `FloatingTooltipWidget`, line for line but for the screen it
//! is placed on and clipped to. dvui's places a tooltip on the main window and clips it to the
//! main window's pixels; this one takes the screen its anchor is on (`core.screens`), so a
//! tooltip in a float popped out into an OS window of its own shows there, rather than being
//! pulled back onto the main window or clipped away. Same API.
const std = @import("std");
const dvui = @import("dvui");
const screens = @import("../screens.zig");

const Event = dvui.Event;
const Options = dvui.Options;
const Rect = dvui.Rect;
const RectScale = dvui.RectScale;
const Size = dvui.Size;
const Widget = dvui.Widget;
const WidgetData = dvui.WidgetData;

const FloatingTooltipWidget = @This();

/// The least a tooltip keeps between itself and its screen's edge, natural units.
pub const margin: f32 = 8;

/// How far a sticky tooltip sits from the pointer, natural units.
const sticky_gap: f32 = 10;

/// Which side of its anchor a tooltip prefers; it takes another when that one has no room.
pub const Side = enum { right, below };

/// `screen` less `margin` all round; never negative in size, so a screen smaller than twice the
/// margin (a minimized or zero-size window) leaves an empty rect rather than an inverted one.
pub fn innerOf(screen: Rect.Natural) Rect.Natural {
    var inner = screen.insetAll(margin);
    inner.w = @max(inner.w, 0);
    inner.h = @max(inner.h, 0);
    return inner;
}

/// Where a `w` by `h` tooltip goes, `Side` of `anchor`, kept `margin` inside `screen`: it tries
/// the preferred side, then the opposite, then the other axis' two sides (`.right` tries right,
/// left, below, above; `.below` tries below, above, right, left), and takes the first where it
/// fits whole. Where none does, it takes whichever side has the most room, overlapping the
/// anchor. Across the anchor it lines up with the anchor's start and slides back in. A size
/// larger than the screen less its margins is shrunk to it. The result is always inside
/// `screen` inset by `margin`, wherever `anchor` is.
pub fn place(screen: Rect.Natural, anchor: Rect.Natural, side: Side, w_in: f32, h_in: f32) Rect.Natural {
    const inner = innerOf(screen);
    const w = @min(w_in, inner.w);
    const h = @min(h_in, inner.h);
    const room_right = inner.x + inner.w - (anchor.x + anchor.w);
    const room_left = anchor.x - inner.x;
    const room_below = inner.y + inner.h - (anchor.y + anchor.h);
    const room_above = anchor.y - inner.y;

    const Dir = enum { right, left, below, above };
    const order: [4]Dir = if (side == .right) .{ .right, .left, .below, .above } else .{ .below, .above, .right, .left };
    var pick: ?Dir = null;
    for (order) |d| {
        const fits = switch (d) {
            .right => room_right >= w,
            .left => room_left >= w,
            .below => room_below >= h,
            .above => room_above >= h,
        };
        if (fits) {
            pick = d;
            break;
        }
    }
    // nowhere fits whole (a tall anchor and a wide tooltip): the roomiest side, overlapping some
    const dir = pick orelse blk: {
        var best = order[0];
        var best_room: f32 = -std.math.inf(f32);
        for (order) |d| {
            const room = switch (d) {
                .right => room_right,
                .left => room_left,
                .below => room_below,
                .above => room_above,
            };
            if (room > best_room) {
                best = d;
                best_room = room;
            }
        }
        break :blk best;
    };

    var r: Rect.Natural = .{ .x = anchor.x, .y = anchor.y, .w = w, .h = h };
    switch (dir) {
        .right => r.x = anchor.x + anchor.w,
        .left => r.x = anchor.x - w,
        .below => r.y = anchor.y + anchor.h,
        .above => r.y = anchor.y - h,
    }
    return keepInside(inner, r);
}

/// Where a sticky tooltip goes: up and to the right of the pointer, `sticky_gap` away, flipping
/// below it and to its left where there is no room, then kept `margin` inside `screen`.
pub fn placeAtPoint(screen: Rect.Natural, p: dvui.Point.Natural, w_in: f32, h_in: f32) Rect.Natural {
    const inner = innerOf(screen);
    const w = @min(w_in, inner.w);
    const h = @min(h_in, inner.h);
    var r: Rect.Natural = .{ .x = p.x + sticky_gap, .y = p.y - h - sticky_gap, .w = w, .h = h };
    if (r.x + w > inner.x + inner.w) r.x = p.x - sticky_gap - w;
    if (r.y < inner.y) r.y = p.y + sticky_gap * 2;
    return keepInside(inner, r);
}

/// `r` slid so it is inside `inner`; `r` is no larger than it. The upper bounds are raised to the
/// lower ones: when `r` fills `inner` the f32 difference can round below them.
fn keepInside(inner: Rect.Natural, r_in: Rect.Natural) Rect.Natural {
    var r = r_in;
    r.x = std.math.clamp(r.x, inner.x, @max(inner.x, inner.x + inner.w - r.w));
    r.y = std.math.clamp(r.y, inner.y, @max(inner.y, inner.y + inner.h - r.h));
    return r;
}

test "a tooltip stays inside the screen less its margin, wherever its anchor and size" {
    const screen: Rect.Natural = .{ .x = 100, .y = 50, .w = 800, .h = 600 };
    const inner = screen.insetAll(margin);
    var prng = std.Random.DefaultPrng.init(66);
    const rand = prng.random();
    for (0..5000) |_| {
        // anchors anywhere, including partly or wholly off the screen
        const a: Rect.Natural = .{
            .x = rand.float(f32) * 1200 - 100,
            .y = rand.float(f32) * 900 - 100,
            .w = rand.float(f32) * 300,
            .h = rand.float(f32) * 100,
        };
        const w = rand.float(f32) * 1200;
        const h = rand.float(f32) * 900;
        for ([_]Side{ .right, .below }) |side| {
            const r = place(screen, a, side, w, h);
            try expectInside(inner, r);
            try std.testing.expect(r.w <= w and r.h <= h);
        }
        const p: dvui.Point.Natural = .{ .x = a.x, .y = a.y };
        try expectInside(inner, placeAtPoint(screen, p, w, h));
    }
}

test "a screen smaller than its margins gives an empty rect, not a crash" {
    const anchor: Rect.Natural = .{ .x = 10, .y = 10, .w = 20, .h = 20 };
    for ([_]Rect.Natural{
        .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .{ .x = 5, .y = 5, .w = margin, .h = 2 * margin + 50 },
        .{ .x = 5, .y = 5, .w = 300, .h = 1 },
    }) |screen| {
        const inner = innerOf(screen);
        for ([_]Side{ .right, .below }) |side| {
            const r = place(screen, anchor, side, 120, 40);
            try std.testing.expect(r.w <= inner.w and r.h <= inner.h);
            try std.testing.expect(r.w >= 0 and r.h >= 0);
        }
        const r = placeAtPoint(screen, .{ .x = 10, .y = 10 }, 120, 40);
        try std.testing.expect(r.w <= inner.w and r.h <= inner.h);
    }
}

test "fitWidth keeps the caller's narrower cap and height, and wraps at the screen otherwise" {
    var tt: FloatingTooltipWidget = undefined;
    tt.scale_val = 2;
    tt.options = .{};
    tt.own_max = .{ .w = dvui.max_float_safe, .h = dvui.max_float_safe };
    const screen: Rect.Natural = .{ .x = 0, .y = 0, .w = 416, .h = 300 };
    // container units: 416 - 2 * margin, the scaler scales its children itself
    tt.fitWidth(screen);
    try std.testing.expectEqual(screen.w - 2 * margin, tt.options.max_size_content.?.w);
    tt.own_max = .{ .w = 120, .h = 80 };
    tt.fitWidth(screen);
    try std.testing.expectEqual(@as(f32, 120), tt.options.max_size_content.?.w);
    try std.testing.expectEqual(@as(f32, 80), tt.options.max_size_content.?.h);
    tt.own_max = .{ .w = 900, .h = 80 };
    tt.fitWidth(screen);
    try std.testing.expectEqual(screen.w - 2 * margin, tt.options.max_size_content.?.w);
    try std.testing.expectEqual(@as(f32, 80), tt.options.max_size_content.?.h);
    // a screen narrower than its margins still leaves a positive width
    tt.fitWidth(.{ .x = 0, .y = 0, .w = 4, .h = 4 });
    try std.testing.expectEqual(@as(f32, 1), tt.options.max_size_content.?.w);
}

test "a tooltip wider than the small window it is raised in wraps and stays inside it" {
    // A picker's window: 364 by 512 at the display's right edge, its anchor near the window's.
    const window: Rect.Natural = .{ .x = 1260, .y = 40, .w = 364, .h = 512 };
    const anchor: Rect.Natural = .{ .x = 1566, .y = 49, .w = 24, .h = 24 };
    const inner = window.insetAll(margin);
    // 200 wide would run past the window's edge; 600 is wider than the window itself
    for ([_]f32{ 200, 600 }) |w| {
        for ([_]Side{ .right, .below }) |side| {
            const r = place(window, anchor, side, w, 40);
            try expectInside(inner, r);
            try std.testing.expect(r.w <= inner.w);
        }
    }
    const r = place(window, anchor, .below, 200, 40);
    try std.testing.expectEqual(@as(f32, 200), r.w);
    try std.testing.expectEqual(@as(f32, window.x + window.w - margin - 200), r.x);
}

test "a tooltip flips to the side of its anchor that has room" {
    const screen: Rect.Natural = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    // right of an anchor at the right edge: no room, so left of it
    var r = place(screen, .{ .x = 700, .y = 100, .w = 90, .h = 20 }, .right, 120, 30);
    try std.testing.expectEqual(@as(f32, 580), r.x);
    // right of an anchor with room: right of it, lined up with its top
    r = place(screen, .{ .x = 100, .y = 100, .w = 90, .h = 20 }, .right, 120, 30);
    try std.testing.expectEqual(@as(f32, 190), r.x);
    try std.testing.expectEqual(@as(f32, 100), r.y);
    // below an anchor on the bottom edge: above it
    r = place(screen, .{ .x = 100, .y = 570, .w = 90, .h = 20 }, .below, 120, 30);
    try std.testing.expectEqual(@as(f32, 540), r.y);
    // below an anchor with room: directly below it
    r = place(screen, .{ .x = 100, .y = 100, .w = 90, .h = 20 }, .below, 120, 30);
    try std.testing.expectEqual(@as(f32, 120), r.y);
    // sticky: above-right of the pointer, below it at the top edge, left of it at the right edge
    r = placeAtPoint(screen, .{ .x = 300, .y = 300 }, 100, 30);
    try std.testing.expectEqual(@as(f32, 310), r.x);
    try std.testing.expectEqual(@as(f32, 260), r.y);
    r = placeAtPoint(screen, .{ .x = 790, .y = 5 }, 100, 30);
    try std.testing.expectEqual(@as(f32, 680), r.x);
    try std.testing.expect(r.y > 5);
}

fn expectInside(inner: Rect.Natural, r: Rect.Natural) !void {
    const eps = 0.001;
    try std.testing.expect(r.x >= inner.x - eps);
    try std.testing.expect(r.y >= inner.y - eps);
    try std.testing.expect(r.x + r.w <= inner.x + inner.w + eps);
    try std.testing.expect(r.y + r.h <= inner.y + inner.h + eps);
}

// maintain a chain of all the nested FloatingTooltipWidgets
var tooltip_current: ?*FloatingTooltipWidget = null;

fn tooltipSet(tt: ?*FloatingTooltipWidget) ?*FloatingTooltipWidget {
    const ret = tooltip_current;
    tooltip_current = tt;
    return ret;
}

pub var defaults: Options = .{
    .name = "Tooltip",
    .style = .content,
    .corners = .default,
    .border = Rect.all(1),
    .background = true,
};

pub const Position = enum {
    /// Beside active_rect: right of it, else left, else below or above it (`place`)
    horizontal,
    /// Above or below active_rect: below it, else above, else left or right of it (`place`)
    vertical,
    /// Starts where mouse is but stays there
    sticky,
    /// Use Options.rect as natural coords
    absolute,
};

pub const InitOptions = struct {
    /// Show when mouse enters this physical rect.
    active_rect: Rect.Physical,

    /// How to position tooltip from `active_rect` or mouse.
    position: Position = .horizontal,

    /// True if the user should be able to hover the tooltips content without it disappearing.
    interactive: bool = false,

    /// Delay showing the tooltip for `delay` microseconds. Tooltip will fade in after 80% of `delay`.
    delay: ?i32 = null,

    /// Scale applied on top of `windowNaturalScale` (so 1.0 means natural
    /// scale).  If null, match the scale of the current parent.
    scale: ?f32 = null,
};

parent_tooltip: ?*FloatingTooltipWidget = null,
/// The subwindow it was raised in.
home: dvui.Id = .zero,
/// SAFETY: Set by `install`
render_ftb: dvui.RenderFrontToBack = undefined,
wd: WidgetData,
/// SAFETY: Set by `install`
prev_windowInfo: dvui.subwindowCurrentSetReturn = undefined,
prev_scroll: ?*dvui.ScrollContainerWidget = undefined,
/// SAFETY: Set by `install`
prevClip: Rect.Physical = undefined,
scale_val: f32,
/// SAFETY: Set by `install`, so is only valid if `installed` is true
scaler: dvui.ScaleWidget = undefined,
animate: ?dvui.AnimateWidget = null,
options: Options,
/// The caller's `max_size_content` scaled to container units once, in `init`; `fitWidth` narrows
/// `options.max_size_content` from it each frame.
own_max: Options.MaxSize = .{ .w = dvui.max_float_safe, .h = dvui.max_float_safe },
init_options: InitOptions,
showing: bool = false,
mouse_good_this_frame: bool = false,
installed: bool = false,
tt_child_shown: bool = false,

/// FloatingTooltipWidget is a subwindow to show temporary floating tooltips,
/// possibly nested. It doesn't focus itself (as a subwindow).
///
/// Will show when the mouse is in the active rect.
///
/// Will stop if the mouse is outside the active rect AND outside
/// FloatingTooltipWidget's rect AND no nested FloatingTooltipWidget is still
/// showing.
///
/// Don't put menus or menuItems in this those depend on focus to work.
/// FloatingMenu is made for that.
///
/// Use FloatingWindowWidget for a floating window that the user can change
/// size, move around, and adjust stacking.
pub fn init(self: *FloatingTooltipWidget, src: std.lang.SourceLocation, init_opts: InitOptions, opts_in: Options) void {
    self.* = .{
        .wd = WidgetData.init(src, .{ .subwindow = true }, (Options{ .name = "FloatingTooltip" }).override(.{
            // passing options.rect will stop WidgetData.init from calling
            // rectFor/minSizeForChild which is important because we are outside
            // normal layout
            .rect = opts_in.rect orelse .{},
            // Identity only — the rest of `opts_in` styles the *content* (see
            // `self.options` below) and must not reach layout here. Without
            // these, every tooltip sharing a source location shares an id, so
            // one of them showing makes all of them show (`_showing` is keyed
            // by id) and they collide in `subwindowAdd`.
            .id_extra = opts_in.id_extra,
            .tag = opts_in.tag,
        })),
        // get scale from parent
        .scale_val = init_opts.scale orelse (dvui.parentGet().screenRectScale(Rect{}).s / dvui.windowNaturalScale()),
        .options = defaults.override(opts_in),
        .init_options = init_opts,
    };

    self.home = dvui.subwindowCurrentId();

    if (self.options.min_size_content) |msc| {
        self.options.min_size_content = msc.scale(self.scale_val, Size);
    }
    if (self.options.max_size_content) |mxc| {
        self.own_max = .{ .w = mxc.w * self.scale_val, .h = mxc.h * self.scale_val };
        self.options.max_size_content = self.own_max;
    }

    // if a rect got passed, we don't want to also pass it to scaler
    self.options.rect = null;

    if (dvui.dataGet(null, self.wd.id, "_showing", bool)) |showing| self.showing = showing;
}

/// The screen the tooltip is kept on: the OS window of the menu or dialog it is raised in, which
/// cuts off what is drawn past its edge (`screens.nativeWindowOf`), else `r`'s screen.
fn screenFor(self: *const FloatingTooltipWidget, r: Rect.Natural) Rect.Natural {
    return screens.nativeWindowOf(self.home) orelse screens.screenFor(r);
}

/// Keep the tooltip from being wider than `screen` less its margins: its text wraps instead.
/// `max_size_content` is in container units, as the scaler it is handed to measures; the caller's
/// narrower width and its height cap are kept.
fn fitWidth(self: *FloatingTooltipWidget, screen: Rect.Natural) void {
    const border = self.options.borderGet();
    const pad = self.options.paddingGet();
    const room = screen.w - 2 * margin - border.x - border.w - pad.x - pad.w;
    self.options.max_size_content = .{ .w = @min(self.own_max.w, @max(room, 1)), .h = self.own_max.h };
}

pub fn shown(self: *FloatingTooltipWidget) bool {
    // protect against this being called multiple times
    if (self.installed) {
        return true;
    }

    // check for mouse position in active_rect
    const evts = dvui.events();
    for (evts) |*e| {
        if (!dvui.eventMatch(e, .{ .id = self.data().id, .r = self.init_options.active_rect })) {
            continue;
        }

        if (e.evt == .mouse and e.evt.mouse.action == .position) {
            self.mouse_good_this_frame = true;
            if (!self.showing) {
                self.showing = true;
            }
        }
    }

    if (self.showing) {
        const size = self.data().rect.size();
        switch (self.init_options.position) {
            .horizontal, .vertical => |o| {
                const ar = self.init_options.active_rect.toNatural();
                const screen = self.screenFor(ar);
                self.fitWidth(screen);
                self.data().rect = .cast(place(screen, ar, if (o == .horizontal) .right else .below, size.w, size.h));
            },
            .sticky => {
                // The first frame only records the pointer and sizes the width; the rect is placed from
                // the second, once the tooltip has a size to place.
                if (dvui.firstFrame(self.data().id)) {
                    const mp = dvui.currentWindow().mouse_pt.toNatural();
                    dvui.dataSet(null, self.data().id, "_sticky_pt", mp);
                    self.fitWidth(self.screenFor(.fromPoint(mp)));
                } else {
                    const mp = dvui.dataGet(null, self.data().id, "_sticky_pt", dvui.Point.Natural) orelse dvui.Point.Natural{};
                    const screen = self.screenFor(.fromPoint(mp));
                    self.fitWidth(screen);
                    self.data().rect = .cast(placeAtPoint(screen, mp, size.w, size.h));
                }
            },
            .absolute => {},
        }
        //std.debug.print("rect {}\n", .{self.data().rect});

        self.install();

        if (self.init_options.interactive) {
            // check for mouse position in tooltip window rect
            for (evts) |*e| {
                if (!dvui.eventMatch(e, .{ .id = self.data().id, .r = self.data().borderRectScale().r })) {
                    continue;
                }

                if (e.evt == .mouse and e.evt.mouse.action == .position) {
                    self.mouse_good_this_frame = true;
                }
            }
        }

        return true;
    }

    return false;
}

pub fn install(self: *FloatingTooltipWidget) void {
    self.installed = true;

    self.data().register();
    dvui.parentSet(self.widget());

    // standard subwindow stuff
    {
        const rs = self.data().rectScale();
        self.render_ftb.initReset();
        self.prev_windowInfo = dvui.subwindowCurrentSet(self.data().id, null);
        dvui.subwindowAdd(self.data().id, self.data().rect, rs.r, false, self.prev_windowInfo.id, true);
        dvui.captureMouseMaintain(.{ .id = self.data().id, .rect = rs.r, .subwindow_id = self.data().id });
        self.prevClip = dvui.clipGet();
        // break out of whatever clipping we were in, onto the screen it is placed on
        const screen = self.screenFor(.cast(self.data().rect));
        const m = dvui.windowNaturalScale();
        dvui.clipSet(.{ .x = screen.x * m, .y = screen.y * m, .w = screen.w * m, .h = screen.h * m });
        self.prev_scroll = dvui.ScrollContainerWidget.scrollSet(null);
    }

    self.parent_tooltip = tooltipSet(self);

    if (self.init_options.delay) |delay| {
        self.animate = @as(dvui.AnimateWidget, undefined);
        self.animate.?.init(@src(), .{ .duration = delay, .kind = .alpha, .easing = easing }, .{});
    }
    // scaler is what is drawing our background/border/box_shadow
    self.scaler.init(@src(), .{ .scale = &self.scale_val }, self.options.override(.{ .expand = .both }));
}

pub fn widget(self: *FloatingTooltipWidget) Widget {
    return Widget.init(self, data, rectFor, screenRectScale, minSizeForChild);
}

pub fn data(self: *FloatingTooltipWidget) *WidgetData {
    return self.wd.validate();
}

pub fn rectFor(self: *FloatingTooltipWidget, id: dvui.Id, min_size: Size, e: Options.Expand, g: Options.Gravity) Rect {
    _ = id;
    return dvui.placeIn(self.data().contentRect().justSize(), min_size, e, g);
}

pub fn screenRectScale(self: *FloatingTooltipWidget, rect: Rect) RectScale {
    return self.data().contentRectScale().rectToRectScale(rect);
}

pub fn minSizeForChild(self: *FloatingTooltipWidget, s: Size) void {
    self.data().minSizeMax(self.data().options.padSize(s));
}

pub fn deinit(self: *FloatingTooltipWidget) void {
    defer if (dvui.widgetIsAllocated(self)) dvui.widgetFree(self);
    defer self.* = undefined;
    if (!self.installed) {
        return;
    }

    // check if we should still be shown
    if (self.mouse_good_this_frame or (self.init_options.interactive and self.tt_child_shown)) {
        dvui.dataSet(null, self.data().id, "_showing", true);
        var parent: ?*FloatingTooltipWidget = self.parent_tooltip;
        while (parent) |p| {
            p.tt_child_shown = true;
            parent = p.parent_tooltip;
        }
    } else {
        // don't store showing if mouse is outside trigger and tooltip which will close it next frame
        dvui.dataRemove(null, self.data().id, "_showing");
        dvui.refresh(null, @src(), self.data().id); // refresh with new hidden state
    }

    self.scaler.deinit();
    if (self.animate) |*animate| {
        animate.deinit();
    }
    self.data().minSizeSetAndRefresh();

    // outside normal layout, don't call minSizeForChild or self.data().minSizeReportToParent();

    _ = tooltipSet(self.parent_tooltip);
    dvui.parentReset(self.data().id, self.data().parent);

    // standard subwindow stuff
    {
        _ = dvui.ScrollContainerWidget.scrollSet(self.prev_scroll);
        _ = dvui.subwindowCurrentSet(self.prev_windowInfo.id, self.prev_windowInfo.rect);
        dvui.clipSet(self.prevClip);
        self.render_ftb.deinit();
    }
}

// Return 0 until 80% of time then fade in remaining 20% linearly.
pub fn easing(t: f32) f32 {
    return @max(0, (t - 0.8) / 0.2);
}

test "a rect that fills the inner rect on an axis is kept, whatever the f32 rounding" {
    const inner: Rect.Natural = .{ .x = 0.1, .y = 1e7 + 0.5, .w = 0.7, .h = 3.3 };
    const r = keepInside(inner, .{ .x = -5, .y = 1e7, .w = inner.w, .h = inner.h });
    try std.testing.expect(r.x >= inner.x and r.y >= inner.y);
}
