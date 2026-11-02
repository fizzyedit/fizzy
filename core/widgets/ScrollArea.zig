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
//! `fizzyedit/dvui 3d90fdd src/widgets/ScrollContainerWidget.zig` — the touch branch of `processEvent`
//! (a press stops the coast), `processMotionScroll` (drag and propagation to the parent) and
//! `processVelocityAfter` (the coast). Names and order are kept so a diff reads cleanly.
//!
//! How it hooks in without touching dvui: this wrapper claims the area's touch motion events
//! (`handle`, as dvui does) *before* the area's own `deinit`, which skips handled events, so
//! `si.velocity` stays 0 and dvui's coast never runs. Wheel events retain their input kind: notches glide and trackpad deltas apply directly.
//! Keys and the bars are dvui's. A motion the area cannot take is passed to the enclosing scroll
//! container's own `processMotionScroll`, so a dvui parent still scrolls (with dvui's coast).
//!
//! Past either end a finger drags the content on a rubber band (`Fling.band`) and, let go, it
//! returns to the edge on a critically damped curve; a coast that reaches an end carries into the
//! band and returns once. The area keeps one position per axis that may leave its range, and
//! `si.viewport` is the part of it in range: the band is only where the content is *drawn*
//! (`frame_viewport`, which hit-testing uses too), so dvui's own bounce never runs, and the wheel,
//! keys, bars and `scrollTo`, which move `si.viewport`, cannot overscroll. A band is a closed
//! form of the time since its segment began, never a sum of frames. Only an outermost area bands,
//! and not one whose content something else places (`frame_viewport`, `lock_visible`).
const std = @import("std");
const dvui = @import("dvui");
const input_time = @import("glass").input_time;
const profile = @import("../profile.zig");
const Fling = @import("../Fling.zig");
const glass = @import("glass");
const FrameClock = glass.FrameClock;
const Spring = @import("../Spring.zig");

const ScrollArea = @This();

area: *dvui.ScrollAreaWidget,
si: *dvui.ScrollInfo,
touch: *Touch,
/// Whether this area may overscroll: not under a parent that takes what it cannot, and not when
/// something else places its content.
bands: bool,
/// Whether a scroll area of the same subwindow encloses this one and takes what it cannot scroll.
nested: bool,
/// The places of interest this frame (`notches`).
notch_list: []const Fling.Notch = &.{},
snap_with: ?Snap = null,
lead: ?Lead = null,
// Saved before children can advance or end dvui's drag on take-over.
press_point: ?dvui.Point.Physical = null,
finger_delta: dvui.Point = .{},

/// Per-area state that outlives a frame: a fling per axis and whether a finger is dragging.
const Touch = struct {
    pad: f32 = 0,
    x: Fling = .{},
    y: Fling = .{},
    dragging: bool = false,
    wheel_ns: i128 = 0,
    wheel_settle: bool = false,
    /// A wheel event or touch coast is waiting to settle at rest.
    rest_pending: bool = false,
    /// Direction of the last wheel event or touch coast.
    wheel_dir: f32 = 0,
    coast_aimed: bool = false,
    glide_x: ?f32 = null,
    glide_y: ?f32 = null,
    glide_at: dvui.Point = .{},
    /// Where the drawn position (`si.viewport` plus `over`) was at the last frame's end.
    last_viewport: dvui.Point = .{},
    last_coast: dvui.Point = .{},
    /// What each axis is doing on its own, apart from a finger.
    seg_x: Segment = .{},
    seg_y: Segment = .{},
    /// While seating, the notch the content is drawn onto, and the spring that draws it there
    /// (`pos.y` is how far the viewport is from `seat_at`).
    seat_at: f32 = 0,
    seating: bool = false,
    seat_spring: Spring = .{},
    /// The finger that owns the drag; another finger's release or motion is not this area's.
    finger: dvui.enums.Button = .none,
    /// How far the content is drawn past its ends this frame: negative past the start, positive
    /// past the end, zero along an axis that is in range.
    over: dvui.Point = .{},
    /// While dragging, how far the finger has gone past the ends (`over` is its `Fling.band`).
    pull: dvui.Point = .{},

    fn anyMoving(self: *const Touch) bool {
        return self.seg_x.kind != .none or self.seg_y.kind != .none or self.seating or self.glide_x != null or self.glide_y != null;
    }
};

/// One axis's motion since a finger last let go: the closed form of the time since `start_ns`.
const Segment = struct {
    kind: enum { none, coast, settle } = .none,
    start_ns: i128 = 0,
    /// A coast: the viewport at its start. A settle: how far past the edge it starts.
    origin: f32 = 0,
    low: f32 = 0,
    /// Points a second at the start.
    vel: f32 = 0,
    /// A coast's decay: `tuning.decay`, or the one that ends it on a notch.
    decay: f32 = tuning.decay,
    /// A settle: whether the edge it returns to is the end (`scrollMax`) and not the start.
    end: bool = false,
};

/// The seat: a lift near a notch that starts no coast comes to rest on it, critically damped at
/// every motion level, about 500 ms after a lift 30 points off.
pub const seat: Spring.Tune = .{ .hz = 3, .playful_damping = 1 };

/// Seconds of recent motion the release velocity averages over: native scrollers read the last
/// 50 to 100 ms.
pub const window_s: f32 = 0.1;

/// Milliseconds after the last wheel event before pixel settling and rest snapping.
pub const wheel_rest_ms = 120;

/// Viewport points per second. `decay` 2 leaves 13.5% of the speed after one second, iOS's
/// `UIScrollView.DecelerationRate.normal` (0.998 per ms), at every speed.
pub const tuning: Fling.Tuning = .{
    .decay = 2.0,
    .min_start = 80.0,
    .stop = 20.0,
    .max = 8000.0,
    .idle_s = 0.08,
};

/// A piece outside the area that takes part of its vertical scroll: a top sheet.
pub const Lead = struct {
    ctx: *anyopaque,
    /// How far the piece is open, 0 .. `range`, in points.
    extent: *const fn (ctx: *anyopaque) f32,
    range: *const fn (ctx: *anyopaque) f32,
    /// Open (`by` < 0) or shut (`by` > 0) by up to `|by|`; returns the length used, never negative.
    take: *const fn (ctx: *anyopaque, by: f32) f32,
};
pub const With = struct { lead: ?Lead = null };

pub fn init(src: std.builtin.SourceLocation, init_opts: dvui.ScrollAreaWidget.InitOpts, opts: dvui.Options) ScrollArea {
    return initWith(src, init_opts, opts, .{});
}

/// `init` with fizzy's own options; `init` is `initWith(.., .{})`.
pub fn initWith(src: std.builtin.SourceLocation, init_opts: dvui.ScrollAreaWidget.InitOpts, opts: dvui.Options, with: With) ScrollArea {
    // lint-allow(raw-scroll-area): Wrapper implementation delegates layout to dvui.
    const area = dvui.scrollArea(src, init_opts, opts);
    const c = &area.scroll.?;
    var have_parent = false;
    if (c.parentScroll) |parent| have_parent = parent.subwindowId == c.subwindowId;
    var self: ScrollArea = .{
        .nested = have_parent,
        .area = area,
        .si = area.si,
        .touch = dvui.dataGetPtrDefault(null, c.data().id, "_touch", Touch, .{}),
        .bands = !have_parent and c.init_opts.frame_viewport == null and !c.init_opts.lock_visible,
    };

    if (self.bands) self.lead = with.lead;
    if (self.lead) |lead_piece| _ = lead_piece.extent(lead_piece.ctx);

    const dragging = dvui.currentWindow().dragging;
    if (dragging.state == .prestart) self.press_point = dragging.pt;
    for (dvui.events()) |*e| {
        if (!dvui.eventMatch(e, .{ .id = c.data().id, .r = c.init_opts.event_rect orelse c.data().borderRectScale().r })) continue;
        if (e.evt == .mouse and e.evt.mouse.action == .press and e.evt.mouse.button.touch()) {
            self.press_point = e.evt.mouse.p;
            if (!self.touch.dragging) self.touch.finger = e.evt.mouse.button;
        }
    }

    // Preserve the caller's pixel snapping during motion: glyphs need whole device pixels
    // to keep their weight stable. The viewport itself keeps its fractional coast position.
    const was_coasting_x = self.touch.seg_x.kind == .coast;
    const was_coasting_y = self.touch.seg_y.kind == .coast;
    const was_seating = self.touch.seating;
    const was_moving_x = self.touch.seg_x.kind != .none;
    const was_moving_y = self.touch.seg_y.kind != .none or was_seating;

    // A press while coasting or settling only stops the motion: eat it so it doesn't also tap
    // what is under it.
    const t = self.touch;
    for (dvui.events()) |*e| {
        if (!dvui.eventMatch(e, .{ .id = c.data().id, .r = c.data().borderRectScale().r })) continue;
        if (e.evt != .mouse or e.evt.mouse.action != .press or !e.evt.mouse.button.touch()) continue;
        if (!t.anyMoving()) continue;
        t.glide_x = null;
        t.glide_y = null;
        e.handle(@src(), c.data());
        dvui.captureMouse(c.data(), e.num);
        t.x.cancel();
        t.y.cancel();
        t.seg_x = .{};
        t.seg_y = .{};
        t.seating = false;
        // The press begins the drag at the drawn position, including a caught rubber band.
        t.dragging = true;
        t.finger = e.evt.mouse.button;
        t.x.begin();
        t.y.begin();
        t.pull = .{
            .x = Fling.pullFor(t.over.x, self.si.viewport.w, tuning.edge),
            .y = Fling.pullFor(t.over.y, self.si.viewport.h, tuning.edge),
        };
        if (self.lead) |piece| {
            const k = @min(-@min(t.over.y, 0), piece.range(piece.ctx) - piece.extent(piece.ctx));
            _ = piece.take(piece.ctx, -k);
            t.over.y += k;
            t.pull.y = Fling.pullFor(t.over.y, self.si.viewport.h, tuning.edge);
        }
    }

    // Captured and unclaimed motion reaches layout here; event matching preserves child capture.
    for (dvui.events()) |*e| self.touchMotion(e);

    // The coast moves the content before it is laid out, so a frame draws where the clock is at
    // that frame. Moved after the children, it would draw where the clock was one gap ago, and
    // an uneven gap would show as an uneven step.
    const coast_velocity_y = t.seg_y.vel;
    if (!t.dragging) {
        self.glideStep();
        self.coast();
        self.seatStep();
    }
    if (was_coasting_y and t.seg_y.kind == .none and !t.dragging and !t.coast_aimed and
        t.over.y == 0 and self.si.viewport.y > 0 and self.si.viewport.y < self.si.scrollMax(.vertical))
    {
        t.rest_pending = true;
        t.wheel_dir = std.math.sign(coast_velocity_y);
    }
    if (t.wheel_settle and dvui.frameTimeNS() - t.wheel_ns >= wheel_rest_ms * std.time.ns_per_ms and
        !t.dragging and t.finger == .none and !t.anyMoving())
    {
        t.wheel_settle = false;
        self.settle(true, true);
    }
    // A bounce ends its coast past an edge; only in-range axes settle onto pixels.
    self.settle(was_coasting_x and t.seg_x.kind != .coast and t.over.x == 0, (was_coasting_y and t.seg_y.kind != .coast or was_seating and !t.seating) and t.over.y == 0);
    if (was_moving_x) t.glide_at.x = self.si.viewport.x;
    if (was_moving_y) t.glide_at.y = self.si.viewport.y;
    if (c.init_opts.frame_viewport == null) {
        c.frame_viewport = self.si.viewport.topLeft().plus(t.over);
        if (self.lead) |piece| c.frame_viewport.y -= piece.extent(piece.ctx);
    }
    return self;
}

/// How far the content is drawn past its ends this frame, as the area's content sees it: negative
/// past the start, positive past the end, zero along an axis in range. A header can stretch by it.
/// `si.viewport` stays within its range whatever this is.
pub fn overscroll(self: *const ScrollArea) dvui.Point {
    return self.touch.over;
}

/// Places a touch scroll comes to rest on, in content points down from the top, for this frame
/// (the slice must outlive `deinit`). A slow flick that would land near one is carried onto it;
/// a lift near one, with no flick, settles onto it; a fast flick passes. Decided at the release
/// alone, unless `on_rest` also enables wheel rests. None by default.
pub fn notches(self: *ScrollArea, n: []const Fling.Notch) void {
    self.notch_list = n;
}

/// Snap points made on demand (a list's row tops), used with `notches`.
pub const Snap = struct {
    ctx: *anyopaque,
    /// The snap point at or before `at` (`dir` < 0) or at or after it (`dir` > 0), or null.
    near: *const fn (ctx: *anyopaque, at: f32, dir: f32) ?Fling.Notch,
};

/// Snap points for this frame, beside `notches`; they also count as `on_rest`. None by default.
pub fn snap(self: *ScrollArea, s: Snap) void {
    self.snap_with = s;
}

pub fn data(self: *const ScrollArea) *dvui.WidgetData {
    return self.area.data();
}

pub fn deinit(self: *ScrollArea) void {
    const c = &self.area.scroll.?;
    const t = self.touch;

    // Events match inside the clip, and the container's content clip is still set.
    dvui.clipSet(c.prevClip);

    const was_dragging = t.dragging;
    var released = false;
    var release_ns = glass.MotionClock.wallFrameNs();
    for (dvui.events()) |*e| {
        self.wheelEvent(e);
        if (e.evt != .mouse or !e.evt.mouse.button.touch()) continue;
        const finger = e.evt.mouse.button;
        switch (e.evt.mouse.action) {
            .release => if (t.dragging and finger == t.finger) {
                released = true;
                release_ns = input_time.get(e.num);
            },
            .motion => self.touchMotion(e),
            else => {},
        }
    }

    for (dvui.events()) |e| {
        if (e.evt == .mouse and e.evt.mouse.action == .release and e.evt.mouse.button == t.finger) t.finger = .none;
    }
    if (released) {
        t.dragging = false;
        _ = t.x.releaseWindowedAt(tuning, window_s, release_ns);
        _ = t.y.releaseWindowedAt(tuning, window_s, release_ns);
        t.pull = .{};
        const now = dvui.frameTimeNS();
        release(&t.x, &t.seg_x, self.si.viewport.x, &t.over.x, self.si.viewport.w, now);
        t.coast_aimed = false;
        release(&t.y, &t.seg_y, self.si.viewport.y, &t.over.y, self.si.viewport.h, now);
        if (self.lead) |piece| {
            if (t.seg_y.kind == .coast) {
                const e = piece.extent(piece.ctx);
                t.seg_y.origin = self.si.viewport.y - e;
                t.seg_y.low = if (e > 0) -piece.range(piece.ctx) else 0;
            }
        }
        if (t.over.y == 0) self.aimOrSeat();
        // The release may contain no motion, so it must schedule the first coast, settle or seat frame itself.
        if (t.anyMoving()) dvui.refresh(null, @src(), self.data().id);
    }

    self.wheelRest();

    // A nested child's propagated motion sets this (parent) area's velocity through dvui's
    // `processMotionScroll`; clear it so dvui's coast never runs beside ours.
    self.si.velocity = .{};
    var drawn = self.si.viewport.topLeft().plus(t.over);
    t.pad = if (self.lead) |piece| piece.extent(piece.ctx) else 0;
    drawn.y -= t.pad;
    if (was_dragging) {
        const moved = drawn.diff(t.last_viewport);
        profile.scrollJump(moved.x, @abs(self.finger_delta.x) + 2);
        profile.scrollJump(moved.y, @abs(self.finger_delta.y) + 2);
    }
    t.last_viewport = drawn;
    if (t.pad > 0) _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = t.pad } });
    self.area.deinit();
}

// The late pass sees motions children gave up; the early pass handles owned or unclaimed motion.
fn touchMotion(self: *ScrollArea, e: *dvui.Event) void {
    const c = &self.area.scroll.?;
    const t = self.touch;
    if (e.evt != .mouse or !e.evt.mouse.button.touch() or e.evt.mouse.action != .motion) return;
    const me = e.evt.mouse;
    if (t.dragging and me.button != t.finger) return;
    const rs = c.data().borderRectScale();
    if (!dvui.eventMatch(e, .{ .id = c.data().id, .r = c.init_opts.event_rect orelse rs.r })) return;
    e.handle(@src(), c.data());
    const taking_over = !dvui.captured(c.data().id);
    if (taking_over) dvui.captureMouse(c.data(), e.num);
    if (!t.dragging) {
        t.glide_x = null;
        t.glide_y = null;
        t.dragging = true;
        t.finger = me.button;
        t.last_coast = .{};
        t.x.begin();
        t.y.begin();
    }
    const motion = me.action.motion;
    const travel = if (taking_over and self.press_point != null) me.p.diff(self.press_point.?) else motion;
    _ = self.processMotionScroll(travel, rs.s);
    self.finger_delta = self.finger_delta.plus(travel.scale(1 / rs.s, dvui.Point));
    // Catch-up changes position only: velocity measures the actual event's finger motion.
    const delta = motion.scale(-1 / rs.s, dvui.Point);
    const time_ns = input_time.get(e.num);
    t.x.sampleTimed(delta.x, time_ns);
    t.y.sampleTimed(delta.y, time_ns);
}

/// Seconds for a glide to cover 63% of what is left; about 95% in 150 ms.
pub const glide_tau_s: f32 = 0.05;

/// Slide the viewport to `to` along `axis`, clamped to 0..scrollMax. Moves from the next frame's `init`.
pub fn glideTo(self: *ScrollArea, axis: dvui.enums.Direction, to: f32) void {
    const target = if (axis == .horizontal) &self.touch.glide_x else &self.touch.glide_y;
    target.* = std.math.clamp(to, 0, self.si.scrollMax(axis));
    if (axis == .horizontal) self.touch.glide_at.x = self.si.viewport.x else self.touch.glide_at.y = self.si.viewport.y;
    dvui.refresh(null, @src(), self.data().id);
}

/// Add `by` to the glide's target (the viewport when none runs), clamped. Notches accumulate on the target.
pub fn glideBy(self: *ScrollArea, axis: dvui.enums.Direction, by: f32) void {
    const target = if (axis == .horizontal) self.touch.glide_x else self.touch.glide_y;
    const pos = if (axis == .horizontal) self.si.viewport.x else self.si.viewport.y;
    self.glideTo(axis, (target orelse pos) + by);
}

/// Whether either axis is gliding.
pub fn gliding(self: *const ScrollArea) bool {
    return self.touch.glide_x != null or self.touch.glide_y != null;
}

fn glideStep(self: *ScrollArea) void {
    const t = self.touch;
    const max_step_s = @as(f32, @floatFromInt(FrameClock.max_step_ns)) / std.time.ns_per_s;
    const dt = @min(dvui.secondsSinceLastFrame(), max_step_s);
    var axis_index: usize = 0;
    while (axis_index < 2) : (axis_index += 1) {
        const axis: dvui.enums.Direction = if (axis_index == 0) .horizontal else .vertical;
        const horizontal = axis == .horizontal;
        const target = if (horizontal) &t.glide_x else &t.glide_y;
        const to = target.* orelse continue;
        const pos = if (horizontal) self.si.viewport.x else self.si.viewport.y;
        const at = if (horizontal) &t.glide_at.x else &t.glide_at.y;
        if (@abs(pos - at.*) > 0.01) {
            target.* = null;
            continue;
        }
        const seg = if (horizontal) t.seg_x else t.seg_y;
        if (seg.kind != .none or (!horizontal and t.seating)) continue;
        const clamped = std.math.clamp(to, 0, self.si.scrollMax(axis));
        var next = if (glass.motion.off()) clamped else pos + (clamped - pos) * (1 - @exp(-dt * glass.motion.rate() / glide_tau_s));
        const done = @abs(clamped - next) <= 0.5;
        if (done) next = clamped;
        self.scrollBy(if (horizontal) .{ .x = next - pos } else .{ .y = next - pos });
        if (done) {
            target.* = null;
            self.settle(horizontal, !horizontal);
        } else dvui.refresh(null, @src(), self.data().id);
        at.* = if (horizontal) self.si.viewport.x else self.si.viewport.y;
    }
}

fn wheelEvent(self: *ScrollArea, e: *dvui.Event) void {
    const c = &self.area.scroll.?;
    if (e.evt != .mouse) return;
    const dir: dvui.enums.Direction = switch (e.evt.mouse.action) {
        .wheel_x => .horizontal,
        .wheel_y => .vertical,
        else => return,
    };
    const kind = glass.wheel_kind.get(e.num) orelse return;
    const trackpad = kind != .mouse;
    if (!dvui.eventMatch(e, .{ .id = c.data().id, .r = c.init_opts.event_rect orelse c.data().borderRectScale().r })) return;
    const by = -switch (e.evt.mouse.action) {
        .wheel_x => |n| n,
        .wheel_y => |n| n,
        else => return,
    };
    if (trackpad) {
        if (dir == .horizontal) self.touch.glide_x = null else self.touch.glide_y = null;
    }
    const at = if (dir == .vertical) self.si.viewport.y else self.si.viewport.x;
    const max = self.si.scrollMax(dir);
    if (max <= 0 or (by < 0 and at <= 0) or (by > 0 and at >= max)) return;
    e.handle(@src(), c.data());
    self.touch.wheel_ns = dvui.frameTimeNS();
    self.touch.wheel_settle = true;
    self.touch.rest_pending = true;
    self.touch.wheel_dir = std.math.sign(by);
    dvui.timer(self.data().id, wheel_rest_ms * 1000);
    self.touch.x.cancel();
    self.touch.y.cancel();
    if (self.touch.seg_x.kind == .coast) self.touch.seg_x = .{};
    if (self.touch.seg_y.kind == .coast) self.touch.seg_y = .{};
    self.touch.seating = false;
    if (trackpad) {
        self.si.scrollByOffset(dir, by);
        if (c.init_opts.user_scroll) |us| {
            if (dir == .vertical) us.y += by else us.x += by;
        }
    } else {
        self.glideBy(dir, by);
    }
    dvui.refresh(null, @src(), self.data().id);
}

/// Scroll by one touch motion, as dvui's `processMotionScroll` does but without setting
/// `si.velocity`. Returns how far this area's content moved on screen (in viewport points,
/// the band included) for the fling.
fn processMotionScroll(self: *ScrollArea, motion: dvui.Point.Physical, scale: f32) dvui.Point {
    const c = &self.area.scroll.?;
    const si = self.si;
    const t = self.touch;
    const before = si.viewport.topLeft();
    var moved: dvui.Point = .{};

    const have_parent = self.nested;

    // Propagate unless this area did the whole scroll in the main direction of movement.
    var propagate = false;

    if (si.vertical != .none) {
        if (!have_parent or
            (motion.y > 0 and si.viewport.y > 0) or
            (motion.y < 0 and si.viewport.y < si.scrollMax(.vertical)))
        {
            moved.y = self.moveY(-motion.y / scale, true);
        } else if (@abs(motion.y) > @abs(motion.x)) {
            propagate = true;
        }
    }

    if (si.horizontal != .none) {
        if (!have_parent or
            (motion.x > 0 and si.viewport.x > 0) or
            (motion.x < 0 and si.viewport.x < si.scrollMax(.horizontal)))
        {
            moved.x = drag(&si.viewport.x, &t.pull.x, &t.over.x, si.scrollMax(.horizontal), si.viewport.w, -motion.x / scale, self.bands);
        } else if (@abs(motion.x) > @abs(motion.y)) {
            propagate = true;
        }
    }

    // What the user scrolled is the in-range part; the band is not scrolling.
    if (c.init_opts.user_scroll) |us| us.* = us.plus(si.viewport.topLeft().diff(before));
    if (moved.nonZero()) dvui.refresh(null, @src(), self.data().id);

    if (propagate) {
        if (c.parentScroll) |parent| {
            if (parent.subwindowId == c.subwindowId) parent.processMotionScroll(motion);
        }
    }
    return moved;
}

// Vertical travel crosses the page/sheet seam before reaching a band.
fn moveY(self: *ScrollArea, by: f32, band: bool) f32 {
    const si = self.si;
    const t = self.touch;
    const piece = self.lead orelse return drag(&si.viewport.y, &t.pull.y, &t.over.y, si.scrollMax(.vertical), si.viewport.h, by, self.bands);
    const before = si.viewport.y + t.over.y - piece.extent(piece.ctx);
    const page_max = @max(0, si.scrollMax(.vertical) - t.pad);
    var left = by;
    if (!band) {
        if (left > 0) {
            left -= piece.take(piece.ctx, left);
            si.viewport.y = std.math.clamp(si.viewport.y + left, 0, page_max);
        } else {
            const used = @min(-left, si.viewport.y);
            si.viewport.y -= used;
            _ = piece.take(piece.ctx, left + used);
        }
        return si.viewport.y + t.over.y - piece.extent(piece.ctx) - before;
    }
    if (left > 0) {
        if (t.pull.y < 0) {
            const used = @min(left, -t.pull.y);
            _ = drag(&si.viewport.y, &t.pull.y, &t.over.y, page_max + piece.extent(piece.ctx), si.viewport.h, used, true);
            left -= used;
        }
        left -= piece.take(piece.ctx, left);
    } else if (left < 0) {
        const used = @min(-left, si.viewport.y + @max(0, t.pull.y));
        _ = drag(&si.viewport.y, &t.pull.y, &t.over.y, page_max + piece.extent(piece.ctx), si.viewport.h, -used, true);
        left += used;
        left += piece.take(piece.ctx, left);
    }
    if (left != 0) _ = drag(&si.viewport.y, &t.pull.y, &t.over.y, page_max + piece.extent(piece.ctx), si.viewport.h, left, true);
    return si.viewport.y + t.over.y - piece.extent(piece.ctx) - before;
}

/// Move one axis for a finger that moved the content `by`, and return how far the content moved on
/// screen. The finger is at the viewport `pos` plus `pull`; what lies past an end is shown on the
/// band (`over`), or not at all where the area may not band. `extent` is the viewport's length.
fn drag(pos: *f32, pull: *f32, over: *f32, max: f32, extent: f32, by: f32, bands: bool) f32 {
    const finger = pos.* + pull.* + by;
    const in_range = std.math.clamp(finger, 0, max);
    const before = pos.* + over.*;
    pull.* = if (bands) finger - in_range else 0;
    over.* = Fling.band(pull.*, extent, tuning.edge);
    pos.* = in_range;
    return pos.* + over.* - before;
}

/// A finger let go of one axis at `viewport`: past an end it settles back from the speed it
/// had, and inside the range it coasts if it was fast enough.
fn release(fling: *Fling, seg: *Segment, viewport: f32, over: *f32, extent: f32, now: i128) void {
    const vel: f32 = if (fling.coasting) fling.vel else 0;
    if (over.* != 0) {
        fling.cancel();
        if (glass.motion.off()) {
            over.* = 0;
            seg.* = .{};
        } else {
            seg.* = .{ .kind = .settle, .start_ns = now, .origin = over.*, .vel = settleVelocity(over.*, vel, extent), .end = over.* > 0 };
        }
        return;
    }
    seg.* = if (fling.coasting) .{ .kind = .coast, .start_ns = now, .origin = viewport, .vel = vel } else .{};
}

/// The most notches within the content's range a release looks at.
const max_notches = 32;

/// At a release inside the range: end a coast on the notch it was headed for, or, when none
/// started, seat the content on the notch it was lifted near.
fn aimOrSeat(self: *ScrollArea) void {
    const t = self.touch;
    const y = self.si.viewport.y;
    const max = self.si.scrollMax(.vertical);
    var buf: [max_notches + 2]Fling.Notch = undefined;
    var n: usize = 0;
    for (self.notch_list) |notch| {
        if (notch.at < 0 or notch.at > max or n == max_notches) continue;
        buf[n] = notch;
        n += 1;
    }
    if (self.snap_with) |provider| {
        const at = if (t.y.coasting) Fling.landing(y, t.y.vel, tuning) else y;
        for ([_]f32{ -1, 1 }) |dir| {
            if (provider.near(provider.ctx, at, dir)) |notch| {
                if (notch.at < 0 or notch.at > max) continue;
                buf[n] = notch;
                n += 1;
            }
        }
    }
    if (t.y.coasting) {
        if (Fling.aim(y, t.y.vel, tuning, buf[0..n])) |a| {
            t.seg_y.decay = a.decay;
            t.coast_aimed = true;
        }
    } else if (Fling.nearest(y, buf[0..n])) |at| {
        // A lift with no coast is slow or paused: the seat starts from rest.
        t.seating = true;
        t.seat_at = at;
        t.seat_spring = .{ .pos = .{ .y = y - at }, .placed = true };
    }
}

fn wheelRest(self: *ScrollArea) void {
    const t = self.touch;
    if (!t.rest_pending or dvui.frameTimeNS() - t.wheel_ns < wheel_rest_ms * std.time.ns_per_ms or
        t.dragging or t.finger != .none or t.over.y != 0 or t.anyMoving()) return;
    t.rest_pending = false;
    const y = self.si.viewport.y;
    const max = self.si.scrollMax(.vertical);
    var a: ?Fling.Notch = null;
    var b: ?Fling.Notch = null;
    for (self.notch_list) |notch| {
        if (notch.on_rest) restCandidate(notch, y, max, &a, &b);
    }
    if (self.snap_with) |provider| {
        for ([_]f32{ -1, 1 }) |dir| {
            if (provider.near(provider.ctx, y, dir)) |notch| restCandidate(notch, y, max, &a, &b);
        }
    }
    if ((a != null and a.?.at == y) or (b != null and b.?.at == y)) return;
    const target = if (a) |lo| (if (b) |hi| blk: {
        const f = (y - lo.at) / (hi.at - lo.at);
        break :blk if ((t.wheel_dir > 0 and f > 0.35) or (t.wheel_dir < 0 and f > 0.65)) hi else lo;
    } else lo) else b orelse return;
    if (@abs(y - target.at) <= target.capture) self.glideTo(.vertical, target.at);
}

fn restCandidate(n: Fling.Notch, y: f32, max: f32, a: *?Fling.Notch, b: *?Fling.Notch) void {
    if (n.at < 0 or n.at > max) return;
    if (n.at <= y and (a.* == null or n.at > a.*.?.at)) a.* = n;
    if (n.at >= y and (b.* == null or n.at < b.*.?.at)) b.* = n;
}

/// Carry a seating viewport onto its notch, on the frame clock.
fn seatStep(self: *ScrollArea) void {
    const t = self.touch;
    if (!t.seating) return;
    const max_step_s = @as(f32, @floatFromInt(FrameClock.max_step_ns)) / std.time.ns_per_s;
    const moving = t.seat_spring.step(.{}, @min(dvui.secondsSinceLastFrame(), max_step_s), seat);
    const to = if (moving) t.seat_at + t.seat_spring.pos.y else t.seat_at;
    self.scrollBy(.{ .y = to - self.si.viewport.y });
    if (moving) {
        dvui.refresh(null, @src(), self.data().id);
    } else {
        t.seating = false;
    }
}

/// Advance each axis's coast or settle to the frame's time (`processVelocityAfter`).
fn coast(self: *ScrollArea) void {
    const t = self.touch;
    const si = self.si;
    const in_range = si.viewport.topLeft();
    var before = in_range.plus(t.over);
    if (self.lead) |piece| before.y -= piece.extent(piece.ctx);
    self.advance(&t.x, &t.seg_x, &si.viewport.x, &t.over.x, si.scrollMax(.horizontal), si.viewport.w);
    if (self.lead) |piece| {
        const origin = si.viewport.y - piece.extent(piece.ctx);
        var p = origin;
        self.advance(&t.y, &t.seg_y, &p, &t.over.y, @max(0, si.scrollMax(.vertical) - t.pad), si.viewport.h);
        _ = self.moveY(p - origin, false);
    } else {
        self.advance(&t.y, &t.seg_y, &si.viewport.y, &t.over.y, si.scrollMax(.vertical), si.viewport.h);
    }
    var after = si.viewport.topLeft().plus(t.over);
    if (self.lead) |piece| after.y -= piece.extent(piece.ctx);
    const moved = after.diff(before);

    if (t.last_coast.x != 0) profile.scrollJump(moved.x, @abs(t.last_coast.x) * 3);
    if (t.last_coast.y != 0) profile.scrollJump(moved.y, @abs(t.last_coast.y) * 3);
    t.last_coast = moved;
    if (self.area.scroll.?.init_opts.user_scroll) |us| us.* = us.plus(si.viewport.topLeft().diff(in_range));
    if (t.seg_x.kind != .none or t.seg_y.kind != .none) dvui.refresh(null, @src(), self.data().id);
}

/// Move one axis to where its segment puts it at the frame's time. A coast that reaches an end
/// hands over to a settle from the speed it had there, and a settle flicked back toward the
/// content hands over to a coast from the edge, so the content goes out and returns once,
/// whichever way it was moving. Each is a function of its start, never of the frames between.
fn advance(self: *ScrollArea, fling: *Fling, seg: *Segment, pos: *f32, over: *f32, max: f32, extent: f32) void {
    const now = dvui.frameTimeNS();
    // A return can cross into a coast, then reach the other edge and return from zero.
    // That final return cannot cross zero: at most two hand-offs, hence three evaluations.
    const max_segment_evaluations = 3;
    for (0..max_segment_evaluations) |_| switch (seg.kind) {
        .none => return,
        .coast => {
            const elapsed = @as(f64, @floatFromInt(now - seg.start_ns)) / std.time.ns_per_s;
            const edge: f32 = if (seg.vel > 0) max else seg.low;
            if (Fling.edgeTime(seg.origin, seg.vel, edge, seg.decay, tuning.stop)) |hit| {
                if (hit <= elapsed) {
                    pos.* = edge;
                    fling.cancel();
                    if (!self.bands or glass.motion.off()) {
                        seg.* = .{};
                        return;
                    }
                    seg.* = .{
                        .kind = .settle,
                        .low = seg.low,
                        .start_ns = seg.start_ns + @as(i128, @intFromFloat(hit * std.time.ns_per_s)),
                        .vel = settleVelocity(0, seg.vel * @as(f32, @floatCast(@exp(-@as(f64, seg.decay) * hit))), extent),
                        .end = seg.vel > 0,
                    };
                    continue;
                }
            }
            pos.* = coastPosition(fling, seg.origin, seg.vel, seg.decay, elapsed);
            // Content that shrank under a coast ends it at the new edge.
            if (pos.* < seg.low or pos.* > max) {
                pos.* = std.math.clamp(pos.*, seg.low, max);
                fling.cancel();
                seg.* = .{};
            }
            if (!fling.coasting) seg.* = .{};
            return;
        },
        .settle => {
            pos.* = if (seg.end) max else seg.low;
            const w = 2 * std.math.pi * @as(f64, tuning.edge.hz) * glass.motion.rate();
            if (w <= 0) {
                over.* = 0;
                seg.* = .{};
                return;
            }
            const elapsed = @as(f64, @floatFromInt(now - seg.start_ns)) / std.time.ns_per_s;
            if (seg.origin * seg.vel < 0 and @abs(seg.vel) > w * @abs(seg.origin)) {
                // Flicked back toward the content: it crosses the edge when x0 + (v0 + w·x0)·t = 0.
                const cross = -@as(f64, seg.origin) / (seg.vel + w * seg.origin);
                if (cross <= elapsed) {
                    const at = Fling.settle(seg.origin, seg.vel, cross, w);
                    over.* = 0;
                    if (@abs(at.vel) <= tuning.stop) {
                        seg.* = .{};
                        return;
                    }
                    seg.* = .{ .kind = .coast, .low = seg.low, .start_ns = seg.start_ns + @as(i128, @intFromFloat(cross * std.time.ns_per_s)), .origin = pos.*, .vel = at.vel };
                    if (seg == &self.touch.seg_y) self.touch.coast_aimed = false;
                    fling.coasting = true;
                    fling.vel = at.vel;
                    continue;
                }
            }
            const at = Fling.settle(seg.origin, seg.vel, elapsed, w);
            if (@abs(at.pos) < 0.5 and @abs(at.vel) < tuning.stop) {
                over.* = 0;
                seg.* = .{};
            } else {
                over.* = at.pos;
            }
            return;
        },
    };
}

/// Keep an outward return inside the inverse band's catchable range without moving its origin.
fn settleVelocity(offset: f32, vel: f32, extent: f32) f32 {
    if (offset * vel < 0) return vel;
    const w = 2 * std.math.pi * tuning.edge.hz * glass.motion.rate();
    // (1 + w·t)·exp(-w·t) <= 1, and t·exp(-w·t) peaks at 1/(w·e).
    const limit = @max(0, extent * 0.999 - @abs(offset)) * w * std.math.e;
    return std.math.clamp(vel, -limit, limit);
}

/// On the axes whose coast ended this frame (run out, or stopped by a press), move the content
/// onto whole physical pixels so the resting viewport agrees with the drawn content origin.
fn settle(self: *ScrollArea, x: bool, y: bool) void {
    if (!x and !y) return;
    const rs = self.area.scroll.?.data().contentRectScale();
    if (rs.s == 0) return;
    const si = self.si;
    self.scrollBy(.{
        .x = if (x) settleBy(rs.r.x, si.viewport.x, 0, si.scrollMax(.horizontal), rs.s) else 0,
        .y = if (y and self.lead == null) settleBy(rs.r.y, si.viewport.y, 0, si.scrollMax(.vertical), rs.s) else 0,
    });
    if (y) {
        if (self.lead) |piece| {
            const e = piece.extent(piece.ctx);
            const by = settleBy(rs.r.y, si.viewport.y - e, if (e > 0) -piece.range(piece.ctx) else 0, @max(0, si.scrollMax(.vertical) - self.touch.pad), rs.s);
            _ = self.moveY(by, false);
        }
    }
}

/// How far to move a viewport at `viewport` (of `low..max`, in an area whose content starts at
/// physical `area_px` with `scale` pixels a point) so the content's origin lands on a pixel.
fn settleBy(area_px: f32, viewport: f32, low: f32, max: f32, scale: f32) f32 {
    // A child at content point p draws at `area_px + (p - viewport) * scale`. Round the
    // content's origin, not the viewport: the area itself may sit between pixels.
    const origin = area_px - viewport * scale;
    var by = (origin - @round(origin)) / scale;
    // Round the other way if snapping would put the viewport outside its scroll range.
    if (viewport + by < low) by += 1 / scale;
    if (viewport + by > max) by -= 1 / scale;
    return by;
}

// Evaluate from the release, rounding the position once rather than accumulating f32 deltas.
// Clamp time at the stop speed so the final position also agrees across frame schedules.
fn coastPosition(fling: *Fling, origin: f32, velocity: f32, coast_decay: f32, elapsed: f64) f32 {
    const decay: f64 = coast_decay;
    const duration = @log(@as(f64, @abs(velocity)) / tuning.stop) / decay;
    const time = std.math.clamp(elapsed, 0, duration);
    const keep = @exp(-decay * time);
    fling.vel = @floatCast(velocity * keep);
    fling.coasting = elapsed < duration;
    return @floatCast(origin + velocity / decay * (1 - keep));
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
var t_release_velocity: f32 = 0;
/// Written by testFrame on the test thread from the release decision, before edge settling.
var t_release_coasted: bool = false;
/// Written by swipe on the test thread before it draws the release frame.
var t_release_time: i128 = 0;
var t_use_dvui: bool = false;
/// Where a child of the area is drawn this frame (physical y, as the renderer would place it),
/// and whether the renderer snaps there.
var t_drawn_y: f32 = 0;
var t_raw_y: f32 = 0;
/// Written by testFrame on the test thread from the child's physical draw scale.
var t_draw_scale: f32 = 1;
var t_snapping: bool = false;
/// Written by testFrame on the test thread after motion advances.
var t_moving: bool = false;
/// The overscroll the area's content sees this frame, whether a finger is dragging it, and
/// whether the viewport ever left its range.
var t_over_y: f32 = 0;
var t_dragging: bool = false;
var t_range_broken: bool = false;
/// Set to place the viewport before the next frame's layout.
var t_jump_to: ?f32 = null;
var t_max_y: f32 = 0;
/// Written by glide tests and consumed by testFrame on the test thread.
var t_glide_to: ?f32 = null;
var t_glide_by: ?f32 = null;
var t_motion_off: bool = false;
/// Lay the area out as a column of `t_rows` rows, `t_top` points below the window's top, and
/// record where each row is drawn.
var t_column: bool = false;
/// Set by the drag regression tests on the test thread to let a text child take the press.
var t_touch_text: bool = false;
var t_top: f32 = 0;
var t_rows: [400]dvui.Point.Physical = undefined;
/// The notches the test area sets, and the highest viewport it reached while `restAfter` ran.
var t_notches: []const Fling.Notch = &.{};
var t_peak: f32 = 0;
/// Set by snap tests and read by testFrame on the test thread.
var t_snap: ?Snap = null;
/// Viewport before deinit handles wheel events, written by testFrame on the test thread.
var t_wheel_origin: f32 = 0;

fn testFrame() !dvui.App.Result {
    if (t_motion_off) glass.motion.publish(0, 0.5, false, false, 1);
    var root = dvui.box(@src(), .{}, .{ .expand = .both });
    defer root.deinit();
    if (t_use_dvui) {
        // lint-allow(raw-scroll-area): Raw dvui baseline for the touch-scroll comparison test.
        var scroll = dvui.scrollArea(@src(), .{ .horizontal = .none, .vertical_bar = .hide }, .{ .expand = .both });
        defer scroll.deinit();
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 100, .h = 20000 } });
        t_viewport_y = scroll.si.viewport.y;
    } else {
        var scroll = ScrollArea.init(@src(), .{ .horizontal = .none, .vertical_bar = .hide }, .{ .expand = .both, .margin = .{ .y = t_top } });
        scroll.notches(t_notches);
        if (t_snap) |provider| scroll.snap(provider);
        if (t_glide_to) |to| scroll.glideTo(.vertical, to);
        if (t_glide_by) |by| scroll.glideBy(.vertical, by);
        t_glide_to = null;
        t_glide_by = null;
        t_moving = scroll.touch.anyMoving();
        // Read the final viewport after the area's event handling and edge correction.
        const si = scroll.si;
        if (t_jump_to) |y| si.viewport.y = y;
        t_jump_to = null;
        defer {
            t_viewport_y = si.viewport.y;
            // dvui's bounce only runs for a viewport out of range: it must never be.
            if (si.viewport.y < 0 or si.viewport.y > si.scrollMax(.vertical)) t_range_broken = true;
        }
        defer {
            t_wheel_origin = si.viewport.y;
            scroll.deinit();
            t_release_velocity = scroll.touch.y.last_debug.vel;
            t_release_coasted = scroll.touch.y.last_debug.coasted;
        }
        if (t_column) {
            t_snapping = dvui.snapToPixels();
            for (&t_rows, 0..) |*drawn, i| {
                var label: dvui.LabelWidget = undefined;
                label.init(@src(), "Row {d}", .{i}, .{}, .{
                    .id_extra = i,
                    .min_size_content = .{ .w = 100, .h = 30 },
                    .padding = .{},
                });
                defer label.deinit();
                label.draw();
                const r = label.wd.rectScale().r;
                // Where the renderer puts a texture or a glyph run: rounded while snapping.
                drawn.* = if (t_snapping) .{ .x = @round(r.x), .y = @round(r.y) } else .{ .x = r.x, .y = r.y };
            }
            return .ok;
        }
        if (t_touch_text) {
            var text = dvui.textLayout(@src(), .{}, .{ .min_size_content = .{ .w = 300, .h = 20000 } });
            for (0..400) |_| text.addText("A text row to drag\n", .{});
            t_draw_scale = text.data().rectScale().s;
            t_raw_y = text.data().rectScale().r.y;
            text.deinit();
            return .ok;
        }
        const child = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 100, .h = 20000 } });
        t_snapping = dvui.snapToPixels();
        t_draw_scale = child.rectScale().s;
        const y = child.rectScale().r.y;
        t_raw_y = y;
        t_over_y = scroll.overscroll().y;
        t_dragging = scroll.touch.dragging;
        t_max_y = si.scrollMax(.vertical);
        t_drawn_y = if (t_snapping) @round(y) else y;
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
    return swipeAt(10, 10);
}

/// A flick of `frames` moves of `step` points a frame, then as `swipe` ends.
fn swipeAt(step: f32, frames: usize) !f32 {
    const cw = dvui.currentWindow();
    try dvui.testing.settle(testFrame);
    const x = 0.5;
    var y: f32 = 0.8;
    const h = cw.data().rect.h;
    _ = try cw.addEventPointer(.{ .button = .touch0, .action = .press, .xynorm = .{ .x = x, .y = y } });
    try frameAfter(16);
    for (0..frames) |_| {
        _ = try cw.addEventTouchMotion(.touch0, x, y - step / h, 0, -step / h);
        y -= step / h;
        try frameAfter(16);
    }
    _ = try cw.addEventTouchMotion(.touch0, x, y - 1 / h, 0, -1 / h);
    try frameAfter(16);
    _ = try cw.addEventPointer(.{ .button = .touch0, .action = .release, .xynorm = .{ .x = x, .y = y } });
    t_release_time = cw.frame_time_ns;
    try frameAfter(16);
    return t_viewport_y;
}

/// How far the viewport coasts in the second after a `swipe`.
fn flick() !f32 {
    const at_release = try swipe();
    for (0..60) |_| try frameAfter(16);
    return t_viewport_y - at_release;
}

/// How far the content has been drawn to move from the release at each of 150 steps of 33 ms, the clock
/// cut into frames by `gaps_ms` (summing to 33), so different cuts meet at equal timestamps.
fn coastTrace(gaps_ms: []const u64, out: *[150]f32) !void {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    t_use_dvui = false;
    _ = try swipe();
    const at_release = t_raw_y;
    // A frame draws where the clock is at its start, so end on the last gap and the frames
    // after it span `gaps_ms` rotated, summing to 33 each step.
    try frameAfter(gaps_ms[gaps_ms.len - 1]);
    for (out) |*slot| {
        for (gaps_ms) |g| try frameAfter(g);
        slot.* = at_release - t_raw_y;
    }
}

test "the coast is a function of time, not of how the frames cut it" {
    var steady: [150]f32 = undefined;
    try coastTrace(&.{ 16, 17 }, &steady);
    var jittery: [150]f32 = undefined;
    try coastTrace(&.{ 25, 8 }, &jittery);
    var max_error: f32 = 0;
    for (steady, jittery) |a, b| max_error = @max(max_error, @abs(a - b));
    std.debug.print("coast: steady final={d:.6}, jittery final={d:.6}, max difference={d:.6} points\n", .{ steady[149], jittery[149], max_error });
    try std.testing.expectApproxEqAbs(@as(f32, 0), max_error, 0.0001);
}

test "coast displacement follows each frame gap" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    t_use_dvui = false;
    _ = try swipe();
    const release_time = t_release_time;
    const release_speed: f64 = t_release_velocity * t_draw_scale;
    var previous_time = dvui.currentWindow().frame_time_ns;
    try frameAfter(25);
    var previous_y = t_raw_y;
    // frameAfter draws at the current timestamp, then begins the next frame with this gap.
    // Alternating long and short gaps exposes a displacement applied one frame late.
    var max_error: f32 = 0;
    for ([_]u64{ 8, 25, 8, 25, 8, 25, 8, 25 }) |next_gap| {
        const time = dvui.currentWindow().frame_time_ns;
        try frameAfter(next_gap);
        const displacement = previous_y - t_raw_y;
        const from_s = @as(f64, @floatFromInt(previous_time - release_time)) / std.time.ns_per_s;
        const to_s = @as(f64, @floatFromInt(time - release_time)) / std.time.ns_per_s;
        const expected: f32 = @floatCast(release_speed / tuning.decay *
            (@exp(-tuning.decay * from_s) - @exp(-tuning.decay * to_s)));
        std.debug.print("coast frame: gap={d} ms, float={d:.6} px, integral={d:.6} px, error={d:.6} px\n", .{
            @divTrunc(time - previous_time, std.time.ns_per_ms), displacement, expected, displacement - expected,
        });
        // The float trajectory follows the release integral before pixel quantization.
        max_error = @max(max_error, @abs(displacement - expected));
        previous_time = time;
        previous_y = t_raw_y;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0), max_error, 0.0001);
}

test "a coast requests another frame even when its timestamp has not advanced" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    t_use_dvui = false;
    _ = try swipe();
    const cw = dvui.currentWindow();
    _ = try testFrame();
    const position = t_viewport_y;
    _ = try cw.end(.{});
    try cw.begin(cw.frame_time_ns);
    // Isolate the coast's refresh from layout, input and displacement refreshes.
    cw.extra_frames_needed = 0;
    _ = try testFrame();
    try std.testing.expectEqual(position, t_viewport_y);
    try std.testing.expect(cw.extra_frames_needed > 0);
}

test "coast position matches the release integral through jitter and a long stall" {
    var fling: Fling = .{ .coasting = true };
    const origin: f32 = 137;
    const velocity: f32 = -625;
    var elapsed: f64 = 0;
    for ([_]f64{ 0.008, 0.025, 0.008, 0.025, 0.5, 0.008, 0.025 }) |gap| {
        elapsed += gap;
        const expected = origin + velocity / 2.0 * (1 - @exp(-2.0 * elapsed));
        try std.testing.expectApproxEqAbs(@as(f32, @floatCast(expected)), coastPosition(&fling, origin, velocity, tuning.decay, elapsed), 0.0001);
        try std.testing.expect(fling.coasting);
    }
    const stopped = coastPosition(&fling, origin, velocity, tuning.decay, 10);
    try std.testing.expectApproxEqAbs(origin + (velocity + tuning.stop) / tuning.decay, stopped, 0.0001);
    try std.testing.expect(!fling.coasting);
    try std.testing.expectEqual(stopped, coastPosition(&fling, origin, velocity, tuning.decay, 20));
}

test "a slow coast preserves pixel snapping while its position stays fractional" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    // A phone with three physical pixels per point.
    t.backend.size_pixels = .{ .w = 900, .h = 1200 };
    t_use_dvui = false;
    _ = try swipe();
    var prev = t_drawn_y;
    var prev_raw = t_raw_y;
    var tail_frames: usize = 0;
    var tail_repeats: usize = 0;
    var tail_min: f32 = std.math.inf(f32);
    var tail_max: f32 = 0;
    var raw_min: f32 = std.math.inf(f32);
    var raw_max: f32 = 0;
    var last = t_viewport_y;
    var slow_frames: usize = 0;
    var repeated_pixels: usize = 0;
    // 8 ms frames approximate a 120 Hz display through the slow tail.
    for (0..600) |_| {
        try frameAfter(8);
        const speed = (t_viewport_y - last) / 0.008;
        last = t_viewport_y;
        if (speed < 60 and speed > 25) {
            slow_frames += 1;
            try std.testing.expect(t_snapping);
            try std.testing.expectEqual(@round(t_drawn_y), t_drawn_y);
            try std.testing.expect(@abs(t_drawn_y - t_raw_y) <= 0.5);
            if (t_drawn_y == prev) repeated_pixels += 1;
        }
        // At decay 2, the final 300 ms spans speeds 20..20*exp(2*0.3) points/s.
        if (speed > tuning.stop and speed < tuning.stop * @exp(tuning.decay * 0.3)) {
            tail_frames += 1;
            const drawn_delta = @abs(t_drawn_y - prev);
            const raw_delta = @abs(t_raw_y - prev_raw);
            tail_min = @min(tail_min, drawn_delta);
            tail_max = @max(tail_max, drawn_delta);
            raw_min = @min(raw_min, raw_delta);
            raw_max = @max(raw_max, raw_delta);
            if (drawn_delta == 0) tail_repeats += 1;
        }
        prev = t_drawn_y;
        prev_raw = t_raw_y;
    }
    std.debug.print("3x coast tail: gap=8 ms, frames={d}, float delta={d:.6}..{d:.6} px, snapped delta={d:.6}..{d:.6} px, repeated pixels={d}\n", .{
        tail_frames, raw_min, raw_max, tail_min, tail_max, tail_repeats,
    });
    try std.testing.expectApproxEqAbs(@as(f32, 3), t_draw_scale, 0.001);
    try std.testing.expect(tail_frames >= 36);
    try std.testing.expect(slow_frames > 20);
    try std.testing.expect(repeated_pixels > 0);
    try std.testing.expect(t_snapping);
}

test "a settled viewport puts the content's origin on a pixel, inside the range" {
    const cases = [_]struct { area_px: f32, viewport: f32, max: f32, scale: f32 }{
        .{ .area_px = 0, .viewport = 10.3, .max = 100, .scale = 1 },
        .{ .area_px = 0.5, .viewport = 10, .max = 100, .scale = 1 },
        .{ .area_px = 3.25, .viewport = 41.7, .max = 100, .scale = 2 },
        // The nearest pixel would put these past the top and the bottom.
        .{ .area_px = 0.9, .viewport = 0.2, .max = 100, .scale = 1 },
        .{ .area_px = 0, .viewport = 99.7, .max = 99.9, .scale = 1 },
    };
    for (cases) |c| {
        const settled = c.viewport + settleBy(c.area_px, c.viewport, 0, c.max, c.scale);
        const origin = c.area_px - settled * c.scale;
        try std.testing.expectApproxEqAbs(@round(origin), origin, 0.0001);
        try std.testing.expect(settled >= 0 and settled <= c.max);
        try std.testing.expect(@abs(settled - c.viewport) * c.scale < 1);
    }
}

/// Step frames until motion ends and return the largest row movement on the final frame.
fn restJump(gap_ms: u64) !f32 {
    var last_coast: [t_rows.len]dvui.Point.Physical = t_rows;
    for (0..600) |_| {
        try frameAfter(gap_ms);
        if (!t_moving) break;
        last_coast = t_rows;
    } else return error.NeverStopped;
    var jump: f32 = 0;
    for (last_coast, t_rows) |a, b| jump = @max(jump, @abs(a.x - b.x), @abs(a.y - b.y));
    return jump;
}

test "the end of a coast draws where the rest frames do" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    t_use_dvui = false;
    t_column = true;
    defer t_column = false;
    // The area sits between pixels, so rounding the viewport alone would not settle it.
    t_top = 0.5;
    defer t_top = 0;
    _ = try swipe();
    const jump = try restJump(8);
    try std.testing.expectApproxEqAbs(@as(f32, 0), jump, 0.001);
}

test "a press that stops a coast leaves text rows where they were drawn at 3x" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    t_use_dvui = false;
    // Phone density: one device pixel is a third of a point.
    t.backend.size_pixels = .{ .w = 900, .h = 1200 };
    t_column = true;
    defer t_column = false;
    t_top = 0.5;
    defer t_top = 0;
    _ = try swipe();
    for (0..7) |_| try frameAfter(16);
    try std.testing.expect(t_moving);
    try std.testing.expect(t_snapping);
    _ = try dvui.currentWindow().addEventPointer(.{ .button = .touch0, .action = .press, .xynorm = .{ .x = 0.5, .y = 0.5 } });
    const jump = try restJump(16);
    try std.testing.expectApproxEqAbs(@as(f32, 0), jump, 0.001);
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

/// Drag finger 0 by `points` (positive pulls the content down) in steps of `step` points a frame,
/// starting a press at the middle when `press`, and hold still after for `hold` frames.
fn dragBy(points: f32, step: f32, press: bool, hold: usize) !void {
    const cw = dvui.currentWindow();
    const h = cw.data().rect.h;
    const x = 0.5;
    var y: f32 = 0.5;
    if (press) {
        _ = try cw.addEventPointer(.{ .button = .touch0, .action = .press, .xynorm = .{ .x = x, .y = y } });
        try frameAfter(16);
    }
    var left = @abs(points);
    while (left > 0) {
        const d = std.math.copysign(@min(step, left), points);
        _ = try cw.addEventTouchMotion(.touch0, x, y + d / h, 0, d / h);
        y += d / h;
        left -= @abs(d);
        try frameAfter(16);
    }
    for (0..hold) |_| try frameAfter(16);
}

fn lift() !void {
    _ = try dvui.currentWindow().addEventPointer(.{ .button = .touch0, .action = .release, .xynorm = .{ .x = 0.5, .y = 0.5 } });
}

test "releasing a held overscroll without a coast requests a settle frame" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    t_use_dvui = false;
    try dvui.testing.settle(testFrame);
    try dragBy(300, 10, true, 10);
    try std.testing.expect(t_over_y < 0);

    const cw = dvui.currentWindow();
    try lift();
    // Discard input and layout requests so only the release can request the next frame.
    cw.extra_frames_needed = 0;
    _ = try testFrame();
    try std.testing.expect(cw.extra_frames_needed > 0);
    try std.testing.expect(!t_release_coasted);
}

test "a drag 300 points past the top shows the band, and the viewport stays in range" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    t_use_dvui = false;
    t_range_broken = false;
    try dvui.testing.settle(testFrame);
    const rest_y = t_raw_y;

    try dragBy(300, 10, true, 10);
    const shown = Fling.band(300, 400, tuning.edge);
    try std.testing.expectApproxEqAbs(@as(f32, 116.8), shown, 0.5);
    try std.testing.expectApproxEqAbs(-shown, t_over_y, 0.5);
    // The content is drawn that far down, and the area's own viewport is at the edge.
    try std.testing.expectApproxEqAbs(shown * dvui.currentWindow().natural_scale, t_raw_y - rest_y, 0.5);
    try std.testing.expectEqual(@as(f32, 0), t_viewport_y);
    try std.testing.expect(!t_range_broken);
}

test "a drag 300 points past the bottom is symmetric" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    t_use_dvui = false;
    t_range_broken = false;
    try dvui.testing.settle(testFrame);
    t_jump_to = t_max_y;
    try dvui.testing.settle(testFrame);
    const end = t_viewport_y;
    try std.testing.expectEqual(t_max_y, end);
    try std.testing.expect(end > 1000);

    try dragBy(-300, 10, true, 10);
    try std.testing.expectApproxEqAbs(Fling.band(300, 400, tuning.edge), t_over_y, 0.5);
    try std.testing.expectEqual(end, t_viewport_y);
    try std.testing.expect(!t_range_broken);
}

/// Hold a 300 point drag past the top for 100 ms, let go, and record how far past the top the
/// content is drawn every 33 ms, the clock cut into frames by `gaps_ms` (summing to 33).
fn settleTrace(gaps_ms: []const u64, out: *[13]f32) !void {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    t_use_dvui = false;
    t_range_broken = false;
    try dvui.testing.settle(testFrame);
    try dragBy(300, 10, true, 0);
    try frameAfter(100);
    try lift();
    // Same alignment as `coastTrace`: each step's last frame is drawn at a whole multiple of 33 ms.
    try frameAfter(gaps_ms[gaps_ms.len - 1]);
    for (out) |*slot| {
        for (gaps_ms) |g| try frameAfter(g);
        slot.* = t_over_y;
    }
    try std.testing.expect(!t_range_broken);
}

test "a release settles within 400 ms without reversing, however the frames cut the time" {
    var steady: [13]f32 = undefined;
    var uneven: [13]f32 = undefined;
    try settleTrace(&.{ 16, 17 }, &steady);
    try settleTrace(&.{ 25, 8 }, &uneven);
    var prev: f32 = -Fling.band(300, 400, tuning.edge);
    for (steady, uneven) |a, b| {
        try std.testing.expect(a >= prev and a <= 0);
        prev = a;
        try std.testing.expectApproxEqAbs(a, b, 0.01);
    }
    // 12 steps of 33 ms is 396 ms.
    try std.testing.expectEqual(@as(f32, 0), steady[11]);
}

test "a fling into the top bounces once and settles" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    t_use_dvui = false;
    t_range_broken = false;
    try dvui.testing.settle(testFrame);
    // Scroll 300 points in and stop there, then flick back toward the top at about 1900 points/s.
    try dragBy(-300, 10, true, 10);
    try lift();
    for (0..10) |_| try frameAfter(16);
    try std.testing.expectApproxEqAbs(@as(f32, 300), t_viewport_y, 0.01);
    try dragBy(150, 30, true, 0);
    try lift();

    var deepest: f32 = 0;
    var deepening_frames: usize = 0;
    var turns: usize = 0;
    var deepening = true;
    var prev: f32 = 0;
    var rest_ms: ?u64 = null;
    for (0..120) |i| {
        try frameAfter(16);
        try std.testing.expect(t_over_y <= 0);
        if (t_over_y < deepest) {
            deepest = t_over_y;
            deepening_frames += 1;
        }
        if (deepening and t_over_y > prev) {
            deepening = false;
            turns += 1;
        } else if (!deepening and t_over_y < prev) {
            turns += 1;
        }
        if (rest_ms == null and deepest < 0 and t_over_y == 0) rest_ms = i * 16;
        prev = t_over_y;
    }
    std.debug.print("bounce: {d:.1} points past the top, home after {?d} ms\n", .{ -deepest, rest_ms });
    // It carries on past the edge for a while, as the coast's speed would take it, and comes
    // back once.
    try std.testing.expect(deepest < -5);
    try std.testing.expect(deepening_frames >= 2);
    try std.testing.expectEqual(@as(usize, 1), turns);
    try std.testing.expectEqual(@as(f32, 0), t_over_y);
    try std.testing.expectEqual(@as(f32, 0), t_viewport_y);
    try std.testing.expect(!t_range_broken);
    // Sampled every 16 ms, the whole bounce fits in half a second.
    try std.testing.expect(rest_ms.? <= 500);
}

test "the wheel at the top does not overscroll" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    t_use_dvui = false;
    try dvui.testing.settle(testFrame);
    const cw = dvui.currentWindow();
    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = 150, .y = 200 } });
    for (0..10) |_| {
        _ = try cw.addEventMouseWheel(10, .vertical, null);
        try frameAfter(16);
        try std.testing.expectEqual(@as(f32, 0), t_over_y);
        try std.testing.expectEqual(@as(f32, 0), t_viewport_y);
    }
}

test "a press during the return catches it where it is drawn" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    t_use_dvui = false;
    t_range_broken = false;
    try dvui.testing.settle(testFrame);
    try dragBy(300, 10, true, 10);
    const held = t_over_y;
    try lift();
    for (0..6) |_| try frameAfter(16);
    const caught = t_over_y;
    try std.testing.expect(caught < 0 and caught > held);

    const cw = dvui.currentWindow();
    _ = try cw.addEventPointer(.{ .button = .touch0, .action = .press, .xynorm = .{ .x = 0.5, .y = 0.5 } });
    try frameAfter(16);
    // The area took the press, and the content did not move.
    try std.testing.expect(t_dragging);
    try std.testing.expectApproxEqAbs(caught, t_over_y, 0.5);

    // Held by a finger that barely moves, it stays put until let go, and then returns.
    try dragBy(1, 1, false, 10);
    try std.testing.expectApproxEqAbs(caught, t_over_y, 1);
    try lift();
    for (0..30) |_| try frameAfter(16);
    try std.testing.expectEqual(@as(f32, 0), t_over_y);
    try std.testing.expect(!t_range_broken);
}

test "a finger catching the hardest bounce keeps it where it is" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 100 } });
    defer t.deinit();
    t_use_dvui = false;
    try dvui.testing.settle(testFrame);
    try dragBy(-300, 10, true, 10);
    try lift();
    for (0..10) |_| try frameAfter(16);
    // A flick back at the speed clamp (`tuning.max`), released near the top: the fastest bounce.
    try dragBy(260, 130, true, 0);
    try lift();
    var deepest: f32 = 0;
    for (0..30) |_| {
        try frameAfter(16);
        deepest = @min(deepest, t_over_y);
    }
    try std.testing.expect(deepest > -100 * 0.999);

    // Catch it while it is still going out.
    try dragBy(-260, 130, true, 0);
    try lift();
    try dragBy(260, 130, true, 0);
    try lift();
    var caught: f32 = 0;
    for (0..30) |_| {
        try frameAfter(16);
        if (t_over_y < -20) {
            caught = t_over_y;
            break;
        }
    }
    try std.testing.expect(caught < -20);
    try dragBy(1, 1, true, 0);
    try std.testing.expectApproxEqAbs(caught, t_over_y, 3);
}

test "steady event times release at steady speed across bursts of 3, 0, 1" {
    var test_window = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer test_window.deinit();
    t_use_dvui = false;
    const cw = dvui.currentWindow();
    try dvui.testing.settle(testFrame);
    const h = cw.data().rect.h;
    var y: f32 = 0.8;
    _ = try cw.addEventPointer(.{ .button = .touch0, .action = .press, .xynorm = .{ .x = 0.5, .y = y } });
    try frameAfter(16);
    const start = cw.frame_time_ns;
    var sample: i128 = 0;
    for ([_]usize{ 3, 0, 1 }) |count| {
        for (0..count) |_| {
            sample += 1;
            y -= 10 / h;
            _ = try cw.addEventTouchMotion(.touch0, 0.5, y, 0, -10 / h);
            input_time.set(cw, cw.event_num, start + sample * 10 * std.time.ns_per_ms);
        }
        try frameAfter(16);
    }
    _ = try cw.addEventPointer(.{ .button = .touch0, .action = .release, .xynorm = .{ .x = 0.5, .y = y } });
    try frameAfter(16);
    try std.testing.expectApproxEqAbs(@as(f32, 1000), t_release_velocity, 0.1);
}

test "a flick stamped as the backend stamps it coasts at its true speed across a late frame" {
    var test_window = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer test_window.deinit();
    t_use_dvui = false;
    const cw = dvui.currentWindow();
    try dvui.testing.settle(testFrame);
    const h = cw.data().rect.h;
    var y: f32 = 0.8;
    _ = try cw.addEventPointer(.{ .button = .touch0, .action = .press, .xynorm = .{ .x = 0.5, .y = y } });
    try frameAfter(16);
    const start = glass.MotionClock.wallFrameNs();
    // Twelve motions of 10 points every 8 ms: 1250 points/s. A frame of 120 ms falls between the
    // sixth and seventh, as a stalled phone's would.
    for (1..13) |k| {
        y -= 10 / h;
        const before = cw.event_num;
        _ = try cw.addEventTouchMotion(.touch0, 0.5, y, 0, -10 / h);
        input_time.stamp(cw, before, start + @as(i128, @intCast(k)) * 8 * std.time.ns_per_ms);
        if (k == 6) try frameAfter(120);
    }
    const before = cw.event_num;
    _ = try cw.addEventPointer(.{ .button = .touch0, .action = .release, .xynorm = .{ .x = 0.5, .y = y } });
    input_time.stamp(cw, before, start + 12 * 8 * std.time.ns_per_ms);
    try frameAfter(16);
    try std.testing.expectApproxEqRel(@as(f32, 1250), t_release_velocity, 0.1);
}

/// Where a flick of `frames` moves of `step` points a frame comes to rest with `n` set.
fn restAfter(n: []const Fling.Notch, step: f32, frames: usize) !f32 {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    t_use_dvui = false;
    t_notches = n;
    defer t_notches = &.{};
    t_peak = 0;
    _ = try swipeAt(step, frames);
    for (0..120) |_| {
        try frameAfter(16);
        t_peak = @max(t_peak, t_viewport_y);
    }
    return t_viewport_y;
}

test "a slow flick comes to rest on a notch" {
    const at = 400;
    try std.testing.expectApproxEqAbs(@as(f32, at), try restAfter(&.{.{ .at = at, .capture = 1000 }}, 10, 10), 0.5);
    try std.testing.expect(t_peak <= at + 0.01);
}

test "a fast flick passes a notch" {
    const free = try restAfter(&.{}, 48, 6);
    const passed = try restAfter(&.{.{ .at = free + 20 }}, 48, 6);
    try std.testing.expectApproxEqAbs(free, passed, 0.01);
}

test "an aimed coast ends where the landing says" {
    var fling: Fling = .{ .coasting = true };
    const a = Fling.aim(0, 600, tuning, &.{.{ .at = 300 }}).?;
    try std.testing.expectApproxEqAbs(@as(f32, 300), coastPosition(&fling, 0, 600, a.decay, 60), 1e-3);
    try std.testing.expectApproxEqAbs(Fling.landing(0, 600, tuning), coastPosition(&fling, 0, 600, tuning.decay, 60), 1e-3);
}

test "an aimed coast is a function of time" {
    t_notches = &.{.{ .at = 400, .capture = 1000 }};
    defer t_notches = &.{};
    var steady: [150]f32 = undefined;
    try coastTrace(&.{ 16, 17 }, &steady);
    var jittery: [150]f32 = undefined;
    try coastTrace(&.{ 25, 8 }, &jittery);
    for (steady, jittery) |a, b| try std.testing.expectApproxEqAbs(a, b, 0.01);
}

/// Press, drag the content `points` up in 10-point steps, and hold still `hold` frames.
fn dragIn(points: f32, hold: usize) !void {
    try dvui.testing.settle(testFrame);
    try dragBy(-points, 10, true, hold);
}

test "a finger on a notch is never moved" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    t_use_dvui = false;
    t_notches = &.{.{ .at = 100 }};
    defer t_notches = &.{};
    try dragIn(100, 0);
    const held = t_viewport_y;
    for (0..10) |_| try frameAfter(16);
    try std.testing.expectEqual(held, t_viewport_y);
}

test "a slow lift inside a window seats, and only ever moves toward the notch" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    t_use_dvui = false;
    t_notches = &.{.{ .at = 70 }};
    defer t_notches = &.{};
    try dragIn(100, 6);
    try lift();
    var prev = t_viewport_y;
    for (0..44) |_| {
        try frameAfter(16);
        try std.testing.expect(t_viewport_y <= prev);
        prev = t_viewport_y;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 70), t_viewport_y, 0.5);
}

test "a slow lift outside every window stays" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    t_use_dvui = false;
    t_notches = &.{.{ .at = 20 }};
    defer t_notches = &.{};
    try dragIn(100, 6);
    try lift();
    for (0..44) |_| try frameAfter(16);
    try std.testing.expectApproxEqAbs(@as(f32, 100), t_viewport_y, 0.01);
}

test "the wheel never notches" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    t_use_dvui = false;
    try dvui.testing.settle(testFrame);
    const cw = dvui.currentWindow();
    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = 150, .y = 200 } });
    for (0..3) |_| {
        _ = try cw.addEventMouseWheel(-10, .vertical, null);
        try frameAfter(16);
    }
    for (0..60) |_| try frameAfter(16);
    const at = t_viewport_y;
    try std.testing.expect(at > 0);
    t_notches = &.{.{ .at = at + 10 }};
    defer t_notches = &.{};
    for (0..30) |_| try frameAfter(16);
    try std.testing.expectEqual(at, t_viewport_y);
}

test "a press stops an aimed coast where it is drawn" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    t_use_dvui = false;
    // Phone density: one device pixel is a third of a point.
    t.backend.size_pixels = .{ .w = 900, .h = 1200 };
    t_column = true;
    defer t_column = false;
    t_top = 0.5;
    defer t_top = 0;
    t_notches = &.{.{ .at = 400, .capture = 1000 }};
    defer t_notches = &.{};
    _ = try swipe();
    for (0..7) |_| try frameAfter(16);
    try std.testing.expect(t_moving);
    _ = try dvui.currentWindow().addEventPointer(.{ .button = .touch0, .action = .press, .xynorm = .{ .x = 0.5, .y = 0.5 } });
    try std.testing.expectApproxEqAbs(@as(f32, 0), try restJump(16), 0.001);
}

test "a press stops a seat where it is drawn" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    t_use_dvui = false;
    // Phone density: one device pixel is a third of a point.
    t.backend.size_pixels = .{ .w = 900, .h = 1200 };
    t_column = true;
    defer t_column = false;
    t_top = 0.5;
    defer t_top = 0;
    t_notches = &.{.{ .at = 70 }};
    defer t_notches = &.{};
    try dragIn(100, 6);
    try lift();
    for (0..3) |_| try frameAfter(16);
    try std.testing.expect(t_moving);
    _ = try dvui.currentWindow().addEventPointer(.{ .button = .touch0, .action = .press, .xynorm = .{ .x = 0.5, .y = 0.5 } });
    try std.testing.expectApproxEqAbs(@as(f32, 0), try restJump(16), 0.001);
}

test "fast returns stay catchable in short panes at every motion rate" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    try dvui.testing.settle(testFrame);
    for ([_]f32{ 0, 0.5, 1 }) |speed| {
        glass.motion.publish(1, speed, false, false, 1);
        const w = 2 * std.math.pi * tuning.edge.hz * glass.motion.rate();
        for ([_]f32{ 50, 100, 150, 250 }) |extent| {
            for ([_]f32{ -1, 1 }) |sign| {
                for ([_]f32{ 0, 0.5, 0.99 }) |fraction| {
                    const origin = sign * extent * fraction;
                    const vel = settleVelocity(origin, sign * tuning.max, extent);
                    for (0..1000) |ms| {
                        const at = Fling.settle(origin, vel, @as(f64, @floatFromInt(ms)) / 1000, w);
                        try std.testing.expect(@abs(at.pos) <= extent * 0.999);
                        const caught = Fling.band(Fling.pullFor(at.pos, extent, tuning.edge), extent, tuning.edge);
                        try std.testing.expectApproxEqAbs(at.pos, caught, 0.001);
                    }
                }
            }
        }
    }
}

/// Script a wheel event with its per-event kind, as the backends do.
fn wheel(by: f32, kind: dvui.enums.MouseType) !void {
    const cw = dvui.currentWindow();
    _ = try cw.addEventMouseWheel(-by, .vertical, kind);
    glass.wheel_kind.set(cw, cw.event_num, kind);
}

test "web trackpad pixels and momentum apply once and stop with the events" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    t_use_dvui = false;
    try dvui.testing.settle(testFrame);
    _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = .{ .x = 150, .y = 200 } });
    for (0..10) |_| {
        try wheel(10, .trackpad);
        try frameAfter(16);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 100), t_viewport_y, 0.01);
    for ([_]f32{ 8, 4, 2, 1, 0.25 }) |by| {
        try wheel(by, .trackpad);
        try frameAfter(16);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 115.25), t_viewport_y, 0.01);
    for (0..30) |_| try frameAfter(16);
    try std.testing.expectApproxEqAbs(@as(f32, 115.25), t_viewport_y, 0.5);
}

test "a web mouse notch glides 100 points reaching 95 percent in 150 ms" {
    for ([_]u64{ 60, 120 }) |hz| {
        var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
        defer t.deinit();
        t_use_dvui = false;
        try dvui.testing.settle(testFrame);
        _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = .{ .x = 150, .y = 200 } });
        try wheel(100, .mouse);
        try frameAfter(0);
        try std.testing.expectApproxEqAbs(@as(f32, 0), t_viewport_y, 0.01);
        const cw = dvui.currentWindow();
        const start = cw.frame_time_ns;
        // Both rates have a frame at exactly 150 ms (9 frames or 18 frames).
        for (1..hz * 150 / 1000 + 1) |frame| {
            _ = try testFrame();
            _ = try cw.end(.{});
            try cw.begin(start + @divTrunc(@as(i128, @intCast(frame)) * std.time.ns_per_s, hz));
        }
        _ = try testFrame();
        try std.testing.expect(t_viewport_y >= 95 and t_viewport_y < 100);
        _ = try cw.end(.{});
        try cw.begin(cw.frame_time_ns + 8 * std.time.ns_per_ms);
        for (0..120) |_| try frameAfter(8);
        try std.testing.expectApproxEqAbs(@as(f32, 100), t_viewport_y, 0.01);
    }
}

test "mixed web wheel kinds keep each event's behavior in one frame" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    t_use_dvui = false;
    try dvui.testing.settle(testFrame);
    _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = .{ .x = 150, .y = 200 } });
    try wheel(10, .trackpad);
    try wheel(100, .mouse);
    try frameAfter(16);
    try std.testing.expectApproxEqAbs(@as(f32, 10), t_viewport_y, 0.01);
    for (0..60) |_| try frameAfter(16);
    try std.testing.expectApproxEqAbs(@as(f32, 110), t_viewport_y, 0.01);
}

test "content drawn equals the finger every frame after the take-over, at 2 pt and 15 pt steps" {
    for ([_]f32{ 2, 15 }) |step| {
        for ([_]enum { text, background, coast, settle }{ .text, .background, .coast, .settle }) |kind| {
            var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
            defer t.deinit();
            t_use_dvui = false;
            t_touch_text = kind == .text;
            defer t_touch_text = false;
            try dvui.testing.settle(testFrame);
            if (kind == .coast) {
                _ = try swipe();
                try frameAfter(16);
                try std.testing.expect(t_moving);
            } else if (kind == .settle) {
                // Settle toward an in-range notch so finger and content travel compare directly.
                t_notches = &.{.{ .at = 70 }};
                try dragIn(100, 6);
                try lift();
                try frameAfter(16);
                try frameAfter(16);
                try std.testing.expect(t_moving);
            }
            defer t_notches = &.{};
            const cw = dvui.currentWindow();
            const x: f32 = if (kind == .text) 0.1 else 0.5;
            var y: f32 = 0.5;
            _ = try cw.addEventPointer(.{ .button = .touch0, .action = .press, .xynorm = .{ .x = x, .y = y } });
            try frameAfter(16);
            const origin = t_raw_y / t_draw_scale;
            var exempt: usize = 0;
            for (1..9) |i| {
                y -= step / 400;
                _ = try cw.addEventTouchMotion(.touch0, x, y, 0, -step / 400);
                try frameAfter(16);
                const travel = step * @as(f32, @floatFromInt(i));
                if (kind == .text and travel <= dvui.Dragging.threshold) {
                    try std.testing.expectApproxEqAbs(origin, t_raw_y / t_draw_scale, 0.01);
                } else if (kind == .text and exempt == 0) {
                    try std.testing.expectApproxEqAbs(origin, t_raw_y / t_draw_scale, 0.01);
                    exempt += 1;
                } else {
                    try std.testing.expectApproxEqAbs(origin - travel, t_raw_y / t_draw_scale, 0.01);
                }
            }
            try std.testing.expectEqual(@as(usize, if (kind == .text) 1 else 0), exempt);
            _ = try cw.addEventPointer(.{ .button = .touch0, .action = .release, .xynorm = .{ .x = x, .y = y } });
            try frameAfter(16);
        }
    }
}

test "the take-over catch-up is not a velocity spike (a fling leaves at the finger's speed)" {
    for ([_]f32{ 2, 15 }) |step| {
        var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
        defer t.deinit();
        t_use_dvui = false;
        t_touch_text = true;
        defer t_touch_text = false;
        try dvui.testing.settle(testFrame);
        const cw = dvui.currentWindow();
        var y: f32 = 0.5;
        _ = try cw.addEventPointer(.{ .button = .touch0, .action = .press, .xynorm = .{ .x = 0.1, .y = y } });
        try frameAfter(16);
        // Release while the catch-up is still inside the velocity sampling window.
        for (0..4) |_| {
            y -= step / 400;
            _ = try cw.addEventTouchMotion(.touch0, 0.1, y, 0, -step / 400);
            input_time.set(cw, cw.event_num, cw.frame_time_ns);
            try frameAfter(16);
        }
        try std.testing.expectApproxEqAbs(step * 4, t_viewport_y, 0.01);
        _ = try cw.addEventPointer(.{ .button = .touch0, .action = .release, .xynorm = .{ .x = 0.1, .y = y } });
        input_time.set(cw, cw.event_num, cw.frame_time_ns);
        try frameAfter(16);
        try std.testing.expect(t_release_coasted);
        try std.testing.expectApproxEqAbs(step / 0.016, t_release_velocity, 0.01);
    }
}

test "a press elsewhere during take-over leaves the carried travel at 8 points" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    t_use_dvui = false;
    t_top = 100;
    defer t_top = 0;
    t_touch_text = true;
    defer t_touch_text = false;
    try dvui.testing.settle(testFrame);
    const cw = dvui.currentWindow();
    _ = try cw.addEventPointer(.{ .button = .touch0, .action = .press, .xynorm = .{ .x = 0.1, .y = 0.5 } });
    try frameAfter(16);
    _ = try cw.addEventTouchMotion(.touch0, 0.1, 0.48, 0, -0.02);
    // A second finger presses above this area, inside the same window in the take-over frame.
    _ = try cw.addEventPointer(.{ .button = .touch1, .action = .press, .xynorm = .{ .x = 0.5, .y = 0.1 } });
    try frameAfter(16);
    try std.testing.expectApproxEqAbs(@as(f32, 8), t_viewport_y, 0.01);
}

// Written and read only by the release-speed tests and their callback on the test thread.
var t_speed_case: enum { band, unscrollable, nested } = .band;
var t_speed: dvui.Point = .{};
var t_speed_position: dvui.Point = .{};
var t_speed_over: f32 = 0;
var t_parent_position: f32 = 0;

fn speedFrame() !dvui.App.Result {
    var parent = ScrollArea.init(@src(), .{ .horizontal = .none, .vertical_bar = .hide }, .{ .expand = .both });
    if (t_speed_case == .nested) {
        var child = ScrollArea.init(@src(), .{ .horizontal = .none, .vertical_bar = .hide }, .{ .min_size_content = .{ .w = 300, .h = 200 } });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 100, .h = 2000 } });
        child.deinit();
        t_speed.y = child.touch.y.last_debug.vel;
        t_speed_position = child.si.viewport.topLeft();
        t_speed_over = child.overscroll().y;
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 100, .h = 2000 } });
    } else {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 100, .h = 2000 } });
        // Release is handled in deinit, before the next frame advances the coast.
        parent.deinit();
        t_speed = .{ .x = parent.touch.x.last_debug.vel, .y = parent.touch.y.last_debug.vel };
        t_speed_position = parent.si.viewport.topLeft();
        t_speed_over = parent.overscroll().y;
        return .ok;
    }
    t_parent_position = parent.si.viewport.y;
    parent.deinit();
    return .ok;
}

fn releaseSpeedCase(kind: @TypeOf(t_speed_case)) !void {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    t_speed_case = kind;
    try dvui.testing.settle(speedFrame);
    const cw = dvui.currentWindow();
    var y: f32 = 0.2;
    var x: f32 = 0.5;
    _ = try cw.addEventPointer(.{ .button = .touch0, .action = .press, .xynorm = .{ .x = x, .y = y } });
    _ = try speedFrame();
    _ = try cw.end(.{});
    try cw.begin(cw.frame_time_ns + 16 * std.time.ns_per_ms);
    for (0..4) |_| {
        if (kind == .unscrollable) x += 10.0 / 300.0 else y += 10.0 / 400.0;
        _ = try cw.addEventTouchMotion(.touch0, x, y, if (kind == .unscrollable) 10.0 / 300.0 else 0, if (kind == .unscrollable) 0 else 10.0 / 400.0);
        input_time.set(cw, cw.event_num, cw.frame_time_ns);
        _ = try speedFrame();
        _ = try cw.end(.{});
        try cw.begin(cw.frame_time_ns + 16 * std.time.ns_per_ms);
    }
    _ = try cw.addEventPointer(.{ .button = .touch0, .action = .release, .xynorm = .{ .x = x, .y = y } });
    input_time.set(cw, cw.event_num, cw.frame_time_ns);
    _ = try speedFrame();
    try std.testing.expectApproxEqAbs(@as(f32, -625), if (kind == .unscrollable) t_speed.x else t_speed.y, 0.01);
    try std.testing.expectEqual(@as(f32, 0), if (kind == .unscrollable) t_speed_position.x else t_speed_position.y);
    if (kind == .band) {
        try std.testing.expect(t_speed_over < 0 and t_speed_over > -40);
    } else if (kind == .nested) {
        try std.testing.expectEqual(@as(f32, 0), t_speed_over);
        try std.testing.expectApproxEqAbs(@as(f32, -20), t_parent_position, 0.01);
    }
}

test "past an end the band releases at the finger speed of minus 625 points per second" {
    try releaseSpeedCase(.band);
}

test "an unscrollable axis releases at the finger speed of minus 625 points per second" {
    try releaseSpeedCase(.unscrollable);
}

test "a nested area at its start releases at the finger speed of minus 625 points per second" {
    try releaseSpeedCase(.nested);
}

test "a glide reaches 95 percent in 150 ms at 60 and 120 Hz and ends exactly" {
    for ([_]u64{ 60, 120 }) |hz| {
        var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
        defer t.deinit();
        t_use_dvui = false;
        try dvui.testing.settle(testFrame);
        t_glide_to = 400;
        try frameAfter(0);
        const cw = dvui.currentWindow();
        const start = cw.frame_time_ns;
        // Both rates include a frame at 150 ms.
        for (1..hz * 150 / 1000 + 1) |frame| {
            _ = try testFrame();
            try std.testing.expect(t_viewport_y <= 400);
            _ = try cw.end(.{});
            try cw.begin(start + @divTrunc(@as(i128, @intCast(frame)) * std.time.ns_per_s, hz));
        }
        _ = try testFrame();
        try std.testing.expect(t_viewport_y >= 380 and t_viewport_y < 400);
        _ = try cw.end(.{});
        try cw.begin(cw.frame_time_ns + 8 * std.time.ns_per_ms);
        for (0..120) |_| {
            try frameAfter(8);
            try std.testing.expect(t_viewport_y <= 400);
        }
        try std.testing.expectEqual(@as(f32, 400), t_viewport_y);
    }
}

test "a glide ends at the same place on an uneven frame schedule" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    try dvui.testing.settle(testFrame);
    t_glide_to = 400;
    var prev: f32 = 0;
    for (0..30) |_| for ([_]u64{ 8, 33, 16, 50, 8 }) |gap| {
        try frameAfter(gap);
        try std.testing.expect(t_viewport_y >= prev and t_viewport_y <= 400);
        prev = t_viewport_y;
    };
    try std.testing.expectEqual(@as(f32, 400), t_viewport_y);
}

test "glideBy accumulates on the target" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    try dvui.testing.settle(testFrame);
    for (0..3) |_| {
        t_glide_by = 100;
        try frameAfter(16);
    }
    for (0..60) |_| try frameAfter(16);
    try std.testing.expectEqual(@as(f32, 300), t_viewport_y);
}

test "a glide target is clamped to the content" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    t_range_broken = false;
    try dvui.testing.settle(testFrame);
    t_glide_to = 1e6;
    for (0..120) |_| try frameAfter(16);
    try std.testing.expectEqual(t_max_y, t_viewport_y);
    t_glide_to = -50;
    for (0..120) |_| try frameAfter(16);
    try std.testing.expectEqual(@as(f32, 0), t_viewport_y);
    try std.testing.expect(!t_range_broken);
}

test "a touch press stops a glide where it is drawn" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    t_column = true;
    defer t_column = false;
    try dvui.testing.settle(testFrame);
    t_glide_to = 400;
    for (0..4) |_| try frameAfter(16);
    const before = t_viewport_y;
    _ = try dvui.currentWindow().addEventPointer(.{ .button = .touch0, .action = .press, .xynorm = .{ .x = 0.5, .y = 0.5 } });
    try std.testing.expectApproxEqAbs(@as(f32, 0), try restJump(16), 0.001);
    for (0..10) |_| {
        try frameAfter(16);
        try std.testing.expectEqual(before, t_viewport_y);
    }
}

test "a scrollbar move drops a glide" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    try dvui.testing.settle(testFrame);
    t_glide_to = 400;
    for (0..4) |_| try frameAfter(16);
    t_jump_to = 125;
    for (0..10) |_| {
        try frameAfter(16);
        try std.testing.expectEqual(@as(f32, 125), t_viewport_y);
    }
}

test "motion off: a glide is one frame" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    t_motion_off = true;
    defer t_motion_off = false;
    try dvui.testing.settle(testFrame);
    t_glide_to = 400;
    try frameAfter(16);
    try frameAfter(16);
    try std.testing.expectEqual(@as(f32, 400), t_viewport_y);
    try std.testing.expect(!t_moving);
}

test "snapping inside the area is the same while gliding and at rest" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    try dvui.testing.settle(testFrame);
    const snapping = t_snapping;
    t_glide_to = 400;
    for (0..60) |_| {
        try frameAfter(16);
        try std.testing.expectEqual(snapping, t_snapping);
    }
    try std.testing.expectEqual(@as(f32, 400), t_viewport_y);
}

fn wheelStart() !void {
    t_use_dvui = false;
    try dvui.testing.settle(testFrame);
    _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = .{ .x = 150, .y = 200 } });
}

fn wheelFrames(count: usize) !void {
    for (0..count) |_| try frameAfter(16);
}

test "a desktop mouse notch glides and a trackpad delta does not" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    try wheelStart();
    try wheel(80, .mouse);
    try frameAfter(0);
    try std.testing.expectEqual(@as(f32, 0), t_viewport_y);
    for (0..10) |_| try frameAfter(15);
    try frameAfter(0);
    try std.testing.expect(t_viewport_y >= 76);
    try wheel(7, .trackpad);
    try frameAfter(0);
    try std.testing.expectApproxEqAbs(t_wheel_origin + 7, t_viewport_y, 0.001);
    const at = t_viewport_y;
    try wheelFrames(6);
    try std.testing.expectApproxEqAbs(at, t_viewport_y, 0.001);
}

test "three notches in 40 ms end at three steps" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    try wheelStart();
    for (0..3) |_| {
        try wheel(80, .mouse);
        try frameAfter(20);
    }
    for (0..60) |_| {
        try frameAfter(16);
        try std.testing.expect(t_viewport_y <= 240);
    }
    try std.testing.expectEqual(@as(f32, 240), t_viewport_y);
}

test "a notch at the end moves nothing and never bands" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    try wheelStart();
    t_jump_to = t_max_y;
    try frameAfter(16);
    try wheel(80, .mouse);
    for (0..60) |_| {
        try frameAfter(16);
        try std.testing.expectEqual(t_max_y, t_viewport_y);
        try std.testing.expectEqual(@as(f32, 0), t_over_y);
    }
}

test "slow trackpad motion keeps snapping and rests on a pixel" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    t.backend.size_pixels = .{ .w = 900, .h = 1200 };
    try wheelStart();
    for (1..21) |k| {
        try wheel(0.37, .trackpad);
        try frameAfter(16);
        try std.testing.expect(t_snapping);
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(k)) * 0.37, t_viewport_y, 0.001);
    }
    try frameAfter(130);
    try frameAfter(0);
    try std.testing.expectApproxEqAbs(@round(t_raw_y), t_raw_y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 7.4), t_viewport_y, 1.0 / 3.0);
}

test "a notch glide that ends between pixels rests on one" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    t.backend.size_pixels = .{ .w = 900, .h = 1200 };
    try wheelStart();
    try wheel(0.37, .trackpad);
    try frameAfter(16);
    try wheel(80, .mouse);
    try wheelFrames(26);
    try std.testing.expectApproxEqAbs(@round(t_raw_y), t_raw_y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 80.37), t_viewport_y, 1.0 / 3.0);
}

test "a wheel event without a kind is dvui's" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    try wheelStart();
    _ = try dvui.currentWindow().addEventMouseWheel(-10, .vertical, null);
    try frameAfter(16);
    try std.testing.expectEqual(@as(f32, 10), t_viewport_y);
}

fn wheelRestCase(start: f32, by: f32, kind: dvui.enums.MouseType, target: f32) !void {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    try wheelStart();
    t_jump_to = start;
    try frameAfter(16);
    try wheel(by, kind);
    // Rest selects its target in deinit; the glide starts one frame later in init.
    // Thirty-six frames spanning 600 ms at 60 Hz.
    for (0..12) |_| {
        try frameAfter(17);
        try frameAfter(17);
        try frameAfter(16);
    }
    try frameAfter(0);
    try std.testing.expectApproxEqAbs(target, t_viewport_y, 0.5);
}

const rest_notches: []const Fling.Notch = &.{
    .{ .at = 0, .capture = 200, .on_rest = true },
    .{ .at = 200, .capture = 200, .on_rest = true },
};

test "a wheel rest finishes what it started" {
    t_notches = rest_notches;
    defer t_notches = &.{};
    try wheelRestCase(0, 100, .mouse, 200);
    try wheelRestCase(0, 60, .mouse, 0);
}

test "a wheel rest going up keeps to the 65 percent line" {
    t_notches = rest_notches;
    defer t_notches = &.{};
    try wheelRestCase(200, -60, .mouse, 200);
    try wheelRestCase(200, -80, .mouse, 0);
}

test "a trackpad rest settles too" {
    t_notches = rest_notches;
    defer t_notches = &.{};
    try wheelRestCase(0, 100, .trackpad, 200);
}

test "a notch without on_rest never moves after the wheel" {
    t_notches = &.{ .{ .at = 0, .capture = 200 }, .{ .at = 200, .capture = 200 } };
    defer t_notches = &.{};
    try wheelRestCase(0, 100, .mouse, 100);
}

test "a press during the rest wait postpones it" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    t_notches = rest_notches;
    defer t_notches = &.{};
    try wheelStart();
    try wheel(100, .trackpad);
    try frameAfter(60);
    _ = try dvui.currentWindow().addEventPointer(.{ .button = .touch0, .action = .press, .xynorm = .{ .x = 0.5, .y = 0.5 } });
    try wheelFrames(20);
    try std.testing.expectEqual(@as(f32, 100), t_viewport_y);
}

test "a rest settles within 0.6 s of the last wheel event" {
    t_notches = rest_notches;
    defer t_notches = &.{};
    try wheelRestCase(0, 100, .mouse, 200);
}

fn rowSnap(_: *anyopaque, at: f32, dir: f32) ?Fling.Notch {
    const row = if (dir < 0) @floor(at / 100) else @ceil(at / 100);
    return .{ .at = row * 100, .capture = 100, .pass_speed = std.math.inf(f32) };
}

test "a flick lands on a snap point" {
    var ctx: u8 = 0;
    t_snap = .{ .ctx = &ctx, .near = rowSnap };
    defer t_snap = null;
    for ([_]f32{ 3, 30 }) |step| {
        var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
        defer t.deinit();
        t_use_dvui = false;
        _ = try swipeAt(step, 8);
        try wheelFrames(400);
        try std.testing.expect(t_viewport_y > 0);
        try std.testing.expectEqual(@round(t_viewport_y / 100) * 100, t_viewport_y);
    }
}

test "a wheel rest uses snap points" {
    var ctx: u8 = 0;
    t_snap = .{ .ctx = &ctx, .near = rowSnap };
    defer t_snap = null;
    try wheelRestCase(0, 130, .mouse, 100);
    try wheelRestCase(0, 140, .mouse, 200);
}

test "nothing outside capture moves" {
    t_notches = &.{ .{ .at = 0, .on_rest = true }, .{ .at = 1000, .on_rest = true } };
    defer t_notches = &.{};
    try wheelRestCase(0, 500, .mouse, 500);
}

test "a slow coast stops on a detent, a fast arrival passes" {
    const free = try restAfter(&.{}, 10, 10);
    const at = free - 40;
    try std.testing.expectApproxEqAbs(at, try restAfter(&.{.{ .at = at, .capture = 0, .detent = 200 }}, 10, 10), 0.5);
    try std.testing.expect(t_peak <= at + 0.01);
    try std.testing.expectApproxEqAbs(free, try restAfter(&.{.{ .at = at, .capture = 0, .detent = 50 }}, 10, 10), 0.01);
}

test "a touch coast that runs out between rest notches settles" {
    const free = try restAfter(&.{}, 10, 10);
    for ([_][2]f32{ .{ free - 100, free + 100 }, .{ free - 60, free + 140 } }, 0..) |pair, index| {
        var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
        defer t.deinit();
        t_use_dvui = false;
        const stops = [_]Fling.Notch{
            .{ .at = pair[0], .on_rest = true, .capture = 200, .pass_speed = 100 },
            .{ .at = pair[1], .on_rest = true, .capture = 200, .pass_speed = 100 },
        };
        t_notches = &stops;
        defer t_notches = &.{};
        const r = try swipeAt(10, 10);
        const coast_end_s = @log(@abs(t_release_velocity) / tuning.stop) / tuning.decay;
        const end_ns = t_release_time + @as(i128, @intFromFloat(coast_end_s * std.time.ns_per_s));
        const target = pair[if (index == 0) @as(usize, 1) else 0];
        while (dvui.currentWindow().frame_time_ns < end_ns + 300 * std.time.ns_per_ms) try frameAfter(16);
        try std.testing.expect(r < free);
        try std.testing.expectApproxEqAbs(target, t_viewport_y, 0.5);
        for (0..10) |_| try frameAfter(16);
        try std.testing.expect(!t_moving);
        dvui.currentWindow().extra_frames_needed = 0;
        _ = try testFrame();
        try std.testing.expectEqual(@as(u8, 0), dvui.currentWindow().extra_frames_needed);
    }
}

test "a release past an edge does not inherit an earlier aimed coast" {
    const aimed_at = try restAfter(&.{}, 10, 10) + 40;
    var free: f32 = 0;
    for (0..2) |run| {
        var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
        defer t.deinit();
        t_use_dvui = false;
        t_notches = &.{.{ .at = aimed_at, .capture = 1000 }};
        defer t_notches = &.{};
        _ = try swipeAt(10, 10);
        for (0..120) |_| try frameAfter(16);
        try std.testing.expectApproxEqAbs(aimed_at, t_viewport_y, 0.5);

        t_notches = &.{};
        t_jump_to = 0;
        try dvui.testing.settle(testFrame);
        try dragBy(150, 10, true, 10);
        try dragBy(-140, 20, false, 0);
        try std.testing.expect(t_over_y < 0);
        const stops = [_]Fling.Notch{
            .{ .at = free - 20, .on_rest = true, .capture = 200, .pass_speed = 100 },
            .{ .at = free + 40, .on_rest = true, .capture = 200, .pass_speed = 100 },
        };
        if (run == 1) t_notches = &stops;
        try lift();
        var coasted = false;
        for (0..180) |_| {
            try frameAfter(16);
            coasted = coasted or t_viewport_y > 0;
        }
        try std.testing.expect(coasted);
        if (run == 0) {
            free = t_viewport_y;
            try std.testing.expect(free > 20);
        } else {
            try std.testing.expectApproxEqAbs(stops[0].at, t_viewport_y, 0.5);
            try std.testing.expect(!t_moving);
        }
    }
}

test "a coast into the top bounces and does not settle" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    t_use_dvui = false;
    t_notches = &.{.{ .at = 60, .on_rest = true, .capture = 200 }};
    defer t_notches = &.{};
    try dvui.testing.settle(testFrame);
    try dragBy(-300, 10, true, 10);
    try lift();
    for (0..10) |_| try frameAfter(16);
    try dragBy(150, 30, true, 0);
    try lift();
    var bounced = false;
    for (0..120) |_| {
        try frameAfter(16);
        bounced = bounced or t_over_y < 0;
    }
    try std.testing.expect(bounced);
    for (0..63) |_| {
        try frameAfter(16);
        try std.testing.expectEqual(@as(f32, 0), t_viewport_y);
        try std.testing.expectEqual(@as(f32, 0), t_over_y);
        try std.testing.expect(!t_moving);
    }
}

test "the brief's closed detent: a slow flick stops, a fast one passes" {
    const stops = [_]Fling.Notch{
        .{ .at = 0, .on_rest = true, .capture = 180 },
        .{ .at = 180, .on_rest = true, .capture = 180, .detent = 400 },
    };
    try std.testing.expectEqual(@as(f32, 180), try restAfter(&stops, 10, 2));
    const free = try restAfter(&.{}, 40, 4);
    try std.testing.expect(free > 180);
    try std.testing.expectApproxEqAbs(free, try restAfter(&stops, 40, 4), 0.01);
}
