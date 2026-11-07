//! A top sheet shared by page scrolling and bar pulls. One State per app.
const std = @import("std");
const dvui = @import("dvui");
const glass = @import("glass");
const Fling = @import("../Fling.zig");
const ScrollArea = @import("ScrollArea.zig");

pub const State = struct {
    /// Points open, 0 (shut) .. range. The app keeps it once, not per page.
    extent: f32 = 0,
    /// The open height, measured by the caller each frame (the brief's height).
    range: f32 = 0,
    /// The range the extent was last checked against: a range change keeps an open sheet open.
    seen_range: f32 = 0,
    target: ?f32 = null,
    settle_ns: i128 = 0,
    settle_offset: f32 = 0,
    settle_speed: f32 = 0,
    stepped_ns: ?i128 = null,
    held: bool = false,
    pressed: bool = false,
    owns_capture: bool = false,
    finger: dvui.enums.Button = .none,
    handle_id: ?dvui.Id = null,
    press_point: dvui.Point.Physical = .{},
    last_point: dvui.Point.Physical = .{},
    velocity: Fling = .{},
};
/// Arrival speed (pt/s) above which a flick passes the shut stop into the page (T5b, T-snap's `detent`).
pub const pass_speed: f32 = 400;

/// The lead to give the visible page's ScrollArea: `.{ .lead = TopSheet.lead(&sheet) }`.
pub fn lead(state: *State) ScrollArea.Lead {
    return .{ .ctx = state, .extent = extent, .range = range, .take = take, .release = releaseRest };
}

/// The lead for a scroll area holding the sheet's own content.
pub fn inner(state: *State) ScrollArea.Lead {
    var piece = lead(state);
    piece.after = true;
    return piece;
}

/// Rest at the open or shut stop after a finger release.
fn releaseRest(ctx: *anyopaque, speed: f32) void {
    const state = sync(ctx);
    const target: f32 = if (@abs(speed) > pass_speed)
        (if (speed > 0) state.range else 0)
    else if (state.extent > state.range * @as(f32, if (speed > 0) 0.35 else 0.65)) state.range else 0;
    rest(state, target, speed);
}

/// 0 shut .. 1 open; the header draws from this alone.
pub fn openness(state: *const State) f32 {
    return if (state.range > 0) std.math.clamp(state.extent / state.range, 0, 1) else 0;
}

fn sync(ctx: *anyopaque) *State {
    const state: *State = @ptrCast(@alignCast(ctx));
    // Capture loss cancels ownership even when the page reads the lead before the handle draws.
    if (state.owns_capture and state.handle_id != null and dvui.currentWindow().captureId(state.finger) != state.handle_id) {
        state.held = false;
        state.pressed = false;
        state.owns_capture = false;
    }
    if (state.range != state.seen_range) {
        state.extent = if (state.seen_range > 0 and state.extent >= state.seen_range)
            state.range
        else
            std.math.clamp(state.extent, 0, state.range);
        state.seen_range = state.range;
    }
    step(state);
    return state;
}

fn extent(ctx: *anyopaque) f32 {
    return sync(ctx).extent;
}

fn range(ctx: *anyopaque) f32 {
    return sync(ctx).range;
}

fn take(ctx: *anyopaque, by: f32) f32 {
    const state = sync(ctx);
    if (state.held or by == 0) return 0;
    state.target = null;
    const before = state.extent;
    state.extent = std.math.clamp(before - by, 0, state.range);
    return @abs(state.extent - before);
}

/// Glide to the open rest without changing the page's scroll position.
pub fn open(state: *State) void {
    _ = sync(state);
    rest(state, state.range, 0);
}

/// Glide to the shut rest without changing the page's scroll position.
pub fn shut(state: *State) void {
    _ = sync(state);
    rest(state, 0, 0);
}

fn rest(state: *State, target: f32, speed: f32) void {
    state.target = target;
    state.settle_ns = dvui.frameTimeNS();
    state.settle_offset = state.extent - target;
    state.settle_speed = speed;
    if (glass.motion.off()) {
        state.extent = target;
        state.target = null;
    } else dvui.refresh(null, @src(), null);
}

fn step(state: *State) void {
    // Plain lead operations also work outside a window when no animation is running.
    if (state.target == null) return;
    const now = dvui.frameTimeNS();
    if (state.stepped_ns == now) return;
    state.stepped_ns = now;
    const target = state.target.?;
    const elapsed = @as(f64, @floatFromInt(now - state.settle_ns)) / std.time.ns_per_s;
    const at = Fling.settle(state.settle_offset, state.settle_speed, elapsed, 2 * std.math.pi * ScrollArea.feel.seat.hz * glass.motion.rate());
    state.extent = std.math.clamp(target + at.pos, 0, state.range);
    if (glass.motion.off() or (@abs(at.pos) < 0.1 and @abs(at.vel) < 2)) {
        state.extent = target;
        state.target = null;
    } else dvui.refresh(null, @src(), null);
}

/// Interpolate the start of the release window; stationary time before lift counts too.
pub fn releaseSpeed(fling: *const Fling, now: i128) f32 {
    if (fling.hist_len < 2) return 0;
    const start = (fling.hist_head + fling.hist.len - fling.hist_len) % fling.hist.len;
    const first = fling.hist[start];
    const cutoff = @max(first.t, now - 50 * std.time.ns_per_ms);
    var old = first;
    var at_cutoff = first.pos;
    for (0..fling.hist_len) |i| {
        const sample = fling.hist[(start + i) % fling.hist.len];
        if (sample.t > cutoff) {
            const fraction = @as(f32, @floatFromInt(cutoff - old.t)) /
                @as(f32, @floatFromInt(sample.t - old.t));
            at_cutoff = old.pos + (sample.pos - old.pos) * fraction;
            break;
        }
        old = sample;
        at_cutoff = sample.pos;
    }
    const elapsed = @as(f32, @floatFromInt(now - cutoff)) / std.time.ns_per_s;
    return if (elapsed > 0) (fling.hist_pos - at_cutoff) / elapsed else 0;
}

/// A box for a bar, edge band or sheet handle strip. A touch drag past dvui's threshold
/// mostly vertically (|dy| > 1.25 |dx|) moves extent 1:1, cancelling child presses.
/// Draw children between init and deinit; their unhandled events bubble here. An empty tap toggles.
pub const Handle = struct {
    box: *dvui.BoxWidget,
    state: *State,

    pub fn init(src: std.builtin.SourceLocation, state: *State, opts: dvui.Options) Handle {
        _ = sync(state);
        const box = dvui.box(src, .{}, opts);
        const wd = box.data();
        // Observe the press before children consume it, without taking their capture.
        for (dvui.events()) |*e| {
            if (e.evt != .mouse) continue;
            const me = e.evt.mouse;
            if (me.action == .motion and state.handle_id == wd.id and
                state.pressed and me.button == state.finger)
            {
                // Observe held travel even before a child gives up its touch capture.
                state.velocity.sampleTimed(me.action.motion.y / wd.borderRectScale().s, glass.input_time.get(e.num));
            }
            if (me.action != .press or !me.button.touch()) continue;
            if (!dvui.eventMatch(e, .{ .id = wd.id, .r = wd.borderRectScale().r })) continue;
            state.target = null;
            state.pressed = true;
            state.held = false;
            state.owns_capture = false;
            state.finger = me.button;
            state.handle_id = wd.id;
            state.press_point = me.p;
            state.last_point = me.p;
            state.velocity.begin();
            state.velocity.sampleTimed(0, glass.input_time.get(e.num));
        }
        return .{ .box = box, .state = state };
    }

    pub fn deinit(self: *Handle) void {
        const s = self.state;
        const wd = self.box.data();
        const rs = wd.borderRectScale();
        for (dvui.events()) |*e| {
            if (e.evt != .mouse) continue;
            const me = e.evt.mouse;
            if (s.handle_id != wd.id or !s.pressed or me.button != s.finger) continue;
            if (me.action == .press and !e.handled) {
                e.handle(@src(), wd);
                dvui.captureMouse(wd, e.num);
                s.owns_capture = true;
                dvui.dragPreStart(me.button, me.p, .{});
            } else if (me.action == .motion) {
                const travel = me.p.diff(s.press_point);
                const threshold = dvui.Dragging.threshold * dvui.currentWindow().natural_scale;
                const vertical = @abs(travel.y) > 1.25 * @abs(travel.x);
                if (!s.held and (!vertical or @abs(travel.y) <= threshold)) continue;
                // A child yielding capture retargets only later events. This unhandled motion
                // still names that child, but its press began here and its capture is gone.
                var bubbled = e.*;
                if (bubbled.target_widgetId) |id| {
                    if (!dvui.captured(id)) bubbled.target_widgetId = wd.id;
                }
                if (!dvui.eventMatch(&bubbled, .{ .id = wd.id, .r = rs.r })) continue;
                e.handle(@src(), wd);
                dvui.captureMouse(wd, e.num);
                s.owns_capture = true;
                const delta = if (s.held) me.p.diff(s.last_point).y else travel.y;
                s.held = true;
                s.extent = std.math.clamp(s.extent + delta / rs.s, 0, s.range);
                s.last_point = me.p;
            } else if (me.action == .release) {
                if (s.held) {
                    e.handle(@src(), wd);
                    const v = releaseSpeed(&s.velocity, glass.input_time.get(e.num));
                    s.velocity.last_debug.vel = v;
                    releaseRest(s, v);
                } else if (!e.handled and rs.r.contains(me.p) and
                    @abs(me.p.x - s.press_point.x) <= dvui.Dragging.threshold * dvui.currentWindow().natural_scale and
                    @abs(me.p.y - s.press_point.y) <= dvui.Dragging.threshold * dvui.currentWindow().natural_scale)
                {
                    e.handle(@src(), wd);
                    rest(s, if (s.extent > 0) 0 else s.range, 0);
                }
                if (dvui.captured(wd.id)) dvui.captureMouse(null, e.num);
                dvui.dragEnd();
                s.held = false;
                s.pressed = false;
                s.owns_capture = false;
            }
        }
        self.box.deinit();
    }
};
