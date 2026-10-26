//! A `dvui.scrollArea` whose finger-drag and fling feel like a phone's.
//!
//! dvui's scroll container turns a touch drag into scroll from the *last motion event alone*:
//! its release velocity is that one event's pixels (no time), the coast guesses 50 events a
//! second, and the braking is stronger the slower the flick. On a phone, where moves arrive in
//! bursts and the last one before `touchend` is often tiny, the momentum drops out. This keeps
//! dvui's area (its container, `ScrollInfo`, bars, `scrollTo`, `scrollDrag`, nesting) and takes
//! over only the touch drag: it samples (position, time), releases with the velocity of the
//! last `window_s` through `Fling.releaseWindowed`, and coasts on one decay per second.
//!
//! Local copy of upstream behaviour, kept so it can be deleted once dvui has it (plans#51):
//! `dvui-dev 3d90fdd src/widgets/ScrollContainerWidget.zig` — the touch branch of `processEvent`
//! (a press stops the coast), `processMotionScroll` (drag and propagation to the parent) and
//! `processVelocityAfter` (the coast). Names and order are kept so a diff reads cleanly.
//!
//! How it hooks in without touching dvui: `deinit` claims this area's touch motion events
//! (`handle`, as dvui does) *before* the area's own `deinit`, which skips handled events, so
//! `si.velocity` stays 0 and dvui's coast never runs. Wheel, trackpad, keys and the bars are
//! dvui's, unchanged. A motion the area cannot take is passed to the enclosing scroll
//! container's own `processMotionScroll`, so a dvui parent still scrolls (with dvui's coast).
const std = @import("std");
const dvui = @import("dvui");
const Fling = @import("../Fling.zig");

const ScrollArea = @This();

area: *dvui.ScrollAreaWidget,
si: *dvui.ScrollInfo,
touch: *Touch,

/// Per-area state that outlives a frame: a fling per axis and whether a finger is dragging.
const Touch = struct {
    x: Fling = .{},
    y: Fling = .{},
    dragging: bool = false,
    /// The finger that owns the drag; another finger's release or motion is not this area's.
    finger: dvui.enums.Button = .none,
};

/// Seconds of recent motion the release velocity averages over: native scrollers read the last
/// 50 to 100 ms.
pub const window_s: f32 = 0.1;

/// Viewport points per second. `decay` 2 leaves 13.5% of the speed after one second, iOS's
/// `UIScrollView.DecelerationRate.normal` (0.998 per ms), at every speed.
pub const tuning: Fling.Tuning = .{
    .decay = 2.0,
    .min_start = 80.0,
    .stop = 20.0,
    .max = 8000.0,
    .idle_s = 0.08,
};

pub fn init(src: std.builtin.SourceLocation, init_opts: dvui.ScrollAreaWidget.InitOpts, opts: dvui.Options) ScrollArea {
    const area = dvui.scrollArea(src, init_opts, opts);
    const c = &area.scroll.?;
    const self: ScrollArea = .{
        .area = area,
        .si = area.si,
        .touch = dvui.dataGetPtrDefault(null, c.data().id, "_touch", Touch, .{}),
    };

    // A press while coasting only stops the coast: eat it so it doesn't also tap what is under it.
    for (dvui.events()) |*e| {
        if (!dvui.eventMatch(e, .{ .id = c.data().id, .r = c.data().borderRectScale().r })) continue;
        if (e.evt != .mouse or e.evt.mouse.action != .press or !e.evt.mouse.button.touch()) continue;
        if (!self.touch.x.coasting and !self.touch.y.coasting) continue;
        e.handle(@src(), c.data());
        self.touch.x.cancel();
        self.touch.y.cancel();
    }
    return self;
}

pub fn data(self: *const ScrollArea) *dvui.WidgetData {
    return self.area.data();
}

pub fn deinit(self: *ScrollArea) void {
    const c = &self.area.scroll.?;
    const t = self.touch;

    // Events match inside the clip, and the container's content clip is still set.
    dvui.clipSet(c.prevClip);

    const rs = c.data().borderRectScale();
    var delta: dvui.Point = .{};
    var released = false;
    for (dvui.events()) |*e| {
        if (e.evt != .mouse or !e.evt.mouse.button.touch()) continue;
        const finger = e.evt.mouse.button;
        switch (e.evt.mouse.action) {
            .release => released = released or (t.dragging and finger == t.finger),
            .motion => |motion| {
                if (t.dragging and finger != t.finger) continue;
                if (!dvui.eventMatch(e, .{ .id = c.data().id, .r = c.init_opts.event_rect orelse rs.r })) continue;
                e.handle(@src(), c.data());
                // The touch usually went down on a child that has since given up capture.
                if (!dvui.captured(c.data().id)) dvui.captureMouse(c.data(), e.num);
                if (!t.dragging) {
                    t.dragging = true;
                    t.finger = finger;
                    t.x.begin();
                    t.y.begin();
                }
                delta = delta.plus(self.processMotionScroll(motion, rs.s));
            },
            else => {},
        }
    }

    if (delta.nonZero() or released) {
        t.x.sampleTimed(delta.x);
        t.y.sampleTimed(delta.y);
    }
    if (released) {
        t.dragging = false;
        _ = t.x.releaseWindowed(tuning, window_s);
        _ = t.y.releaseWindowed(tuning, window_s);
    }

    if (!t.dragging) self.coast();

    // A nested child's propagated motion sets this (parent) area's velocity through dvui's
    // `processMotionScroll`; clear it so dvui's coast never runs beside ours.
    self.si.velocity = .{};
    self.area.deinit();
}

/// Scroll by one touch motion, as dvui's `processMotionScroll` does but without setting
/// `si.velocity`. Returns how far this area's viewport moved (in viewport points) for the fling.
fn processMotionScroll(self: *ScrollArea, motion: dvui.Point.Physical, scale: f32) dvui.Point {
    const c = &self.area.scroll.?;
    const si = self.si;
    var moved: dvui.Point = .{};

    var have_parent = false;
    if (c.parentScroll) |parent| have_parent = parent.subwindowId == c.subwindowId;

    // Propagate unless this area did the whole scroll in the main direction of movement.
    var propagate = false;

    if (si.vertical != .none) {
        if (!have_parent or
            (motion.y > 0 and si.viewport.y > 0) or
            (motion.y < 0 and si.viewport.y < si.scrollMax(.vertical)))
        {
            moved.y = -motion.y / scale;
        } else if (@abs(motion.y) > @abs(motion.x)) {
            propagate = true;
        }
    }

    if (si.horizontal != .none) {
        if (!have_parent or
            (motion.x > 0 and si.viewport.x > 0) or
            (motion.x < 0 and si.viewport.x < si.scrollMax(.horizontal)))
        {
            moved.x = -motion.x / scale;
        } else if (@abs(motion.x) > @abs(motion.y)) {
            propagate = true;
        }
    }

    self.scrollBy(moved);

    if (propagate) {
        if (c.parentScroll) |parent| {
            if (parent.subwindowId == c.subwindowId) parent.processMotionScroll(motion);
        }
    }
    return moved;
}

/// Advance the coast one frame (`processVelocityAfter`). Past an edge the coast ends and dvui's
/// bounce-back, which runs in the area's `deinit`, takes over.
fn coast(self: *ScrollArea) void {
    const t = self.touch;
    const si = self.si;
    var moved: dvui.Point = .{};
    if (t.x.step(tuning)) |d| moved.x = d;
    if (t.y.step(tuning)) |d| moved.y = d;
    if (!moved.nonZero()) return;

    self.scrollBy(moved);
    if (si.viewport.x < 0 or si.viewport.x > si.scrollMax(.horizontal)) t.x.cancel();
    if (si.viewport.y < 0 or si.viewport.y > si.scrollMax(.vertical)) t.y.cancel();
    if (t.x.coasting or t.y.coasting) dvui.refresh(null, @src(), self.data().id);
}

fn scrollBy(self: *ScrollArea, by: dvui.Point) void {
    const c = &self.area.scroll.?;
    self.si.viewport.x += by.x;
    self.si.viewport.y += by.y;
    if (c.init_opts.user_scroll) |us| us.* = us.plus(by);
    if (by.nonZero()) dvui.refresh(null, @src(), self.data().id);
}

// ---- tests ----

var t_viewport_y: f32 = 0;
var t_use_dvui: bool = false;

fn testFrame() !dvui.App.Result {
    var root = dvui.box(@src(), .{}, .{ .expand = .both });
    defer root.deinit();
    if (t_use_dvui) {
        var scroll = dvui.scrollArea(@src(), .{ .horizontal = .none, .vertical_bar = .hide }, .{ .expand = .both });
        defer scroll.deinit();
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 100, .h = 20000 } });
        t_viewport_y = scroll.si.viewport.y;
    } else {
        var scroll = ScrollArea.init(@src(), .{ .horizontal = .none, .vertical_bar = .hide }, .{ .expand = .both });
        // After the area's `deinit`, which is where the coast moves it: the frame's final place.
        const si = scroll.si;
        defer t_viewport_y = si.viewport.y;
        defer scroll.deinit();
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 100, .h = 20000 } });
    }
    return .ok;
}

/// One frame `ms` after the last, the way `dvui.testing.step` runs one but with the gap chosen.
fn frameAfter(ms: u64) !void {
    const cw = dvui.currentWindow();
    _ = try testFrame();
    _ = try cw.end(.{});
    try cw.begin(cw.frame_time_ns + @as(i128, ms) * std.time.ns_per_ms);
}

/// A flick up the screen at 10 points a frame (about 600 points/s), whose last move is one
/// point and whose release comes a frame later. Returns the viewport's position at the release.
fn swipe() !f32 {
    const cw = dvui.currentWindow();
    try dvui.testing.settle(testFrame);
    const x = 0.5;
    var y: f32 = 0.8;
    const h = cw.data().rect.h;
    _ = try cw.addEventPointer(.{ .button = .touch0, .action = .press, .xynorm = .{ .x = x, .y = y } });
    try frameAfter(16);
    for (0..10) |_| {
        _ = try cw.addEventTouchMotion(.touch0, x, y - 10 / h, 0, -10 / h);
        y -= 10 / h;
        try frameAfter(16);
    }
    _ = try cw.addEventTouchMotion(.touch0, x, y - 1 / h, 0, -1 / h);
    try frameAfter(16);
    _ = try cw.addEventPointer(.{ .button = .touch0, .action = .release, .xynorm = .{ .x = x, .y = y } });
    try frameAfter(16);
    return t_viewport_y;
}

/// How far the viewport coasts in the second after a `swipe`.
fn flick() !f32 {
    const at_release = try swipe();
    for (0..60) |_| try frameAfter(16);
    return t_viewport_y - at_release;
}

/// How far the viewport has coasted from the release at each of 15 steps of 33 ms, the clock
/// cut into frames by `gaps_ms` (summing to 33), so different cuts meet at equal timestamps.
fn coastTrace(gaps_ms: []const u64, out: *[15]f32) !void {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    t_use_dvui = false;
    const at_release = try swipe();
    // A frame's step spans the gap before it, so end on the last gap and the frames after
    // it span `gaps_ms` rotated, summing to 33 each step.
    try frameAfter(gaps_ms[gaps_ms.len - 1]);
    for (out) |*slot| {
        for (gaps_ms) |g| try frameAfter(g);
        slot.* = t_viewport_y - at_release;
    }
}

test "the coast is a function of time, not of how the frames cut it" {
    var steady: [15]f32 = undefined;
    try coastTrace(&.{33}, &steady);
    var jittery: [15]f32 = undefined;
    try coastTrace(&.{ 25, 8 }, &jittery);
    for (steady, jittery) |a, b| try std.testing.expectApproxEqAbs(a, b, 0.01);
}

test "a fling coasts at the speed of the last 100 ms, not of the last move" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    t_use_dvui = false;
    const coasted = try flick();
    // 600 points/s with 13.5% left after a second travels about 600 / 2 * (1 - 0.135) points.
    try std.testing.expect(coasted > 150);
    try std.testing.expect(coasted < 400);
}

// The canary for dvui bumps: if this fails, upstream changed the touch path, so port the change
// or delete this wrapper (docs/DEPENDENCIES.md, "Local copies of dvui").
test "dvui's own area, given the same flick, stops almost at once" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    t_use_dvui = true;
    defer t_use_dvui = false;
    const coasted = try flick();
    try std.testing.expect(coasted < 30);
}

test "a press while coasting stops the coast without tapping" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    t_use_dvui = false;
    const at_release = try swipe();
    for (0..10) |_| try frameAfter(16);
    try std.testing.expect(t_viewport_y > at_release + 20);

    const cw = dvui.currentWindow();
    _ = try cw.addEventPointer(.{ .button = .touch0, .action = .press, .xynorm = .{ .x = 0.5, .y = 0.5 } });
    try frameAfter(16);
    const stopped = t_viewport_y;
    _ = try cw.addEventPointer(.{ .button = .touch0, .action = .release, .xynorm = .{ .x = 0.5, .y = 0.5 } });
    for (0..10) |_| try frameAfter(16);
    try std.testing.expectEqual(stopped, t_viewport_y);
}

test "another finger's release does not end the drag" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    t_use_dvui = false;
    const cw = dvui.currentWindow();
    try dvui.testing.settle(testFrame);
    const h = cw.data().rect.h;
    var y: f32 = 0.8;
    _ = try cw.addEventPointer(.{ .button = .touch0, .action = .press, .xynorm = .{ .x = 0.5, .y = y } });
    try frameAfter(16);
    for (0..10) |_| {
        _ = try cw.addEventTouchMotion(.touch0, 0.5, y - 10 / h, 0, -10 / h);
        y -= 10 / h;
        try frameAfter(16);
    }
    _ = try cw.addEventPointer(.{ .button = .touch1, .action = .press, .xynorm = .{ .x = 0.2, .y = 0.2 } });
    try frameAfter(16);
    _ = try cw.addEventPointer(.{ .button = .touch1, .action = .release, .xynorm = .{ .x = 0.2, .y = 0.2 } });
    try frameAfter(16);
    const held = t_viewport_y;
    // Finger 0 is still down and still: nothing may coast.
    for (0..30) |_| try frameAfter(16);
    try std.testing.expectEqual(held, t_viewport_y);
}

var t_scroll_to: bool = false;

fn scrollToFrame() !dvui.App.Result {
    var root = dvui.box(@src(), .{}, .{ .expand = .both });
    defer root.deinit();
    var scroll = ScrollArea.init(@src(), .{ .horizontal = .none, .vertical_bar = .hide }, .{ .expand = .both });
    defer scroll.deinit();
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 100, .h = 1000 } });
    var child = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = 100, .h = 50 } });
    defer child.deinit();
    if (t_scroll_to) {
        t_scroll_to = false;
        dvui.scrollTo(.{ .screen_rect = child.data().borderRectScale().r });
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 100, .h = 20000 } });
    t_viewport_y = scroll.si.viewport.y;
    return .ok;
}

test "dvui.scrollTo from a child moves a ScrollArea" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    try dvui.testing.settle(scrollToFrame);
    try std.testing.expectEqual(@as(f32, 0), t_viewport_y);
    t_scroll_to = true;
    try dvui.testing.settle(scrollToFrame);
    try std.testing.expect(t_viewport_y > 500);
}
