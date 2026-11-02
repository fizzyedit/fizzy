//! A sheet pulled from the top edge by a page's scroll: the header's brief. One State per app.
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
    /// The rest, and the closed-form segment that reaches it. Null needs no more frames.
    target: ?f32 = null,
    settle_ns: i128 = 0,
    settle_offset: f32 = 0,
    settle_speed: f32 = 0,
    stepped_frame: ?i128 = null,
    /// A Handle past its threshold owns the extent until its finger lifts.
    held: bool = false,
};
/// Arrival speed (pt/s) above which a flick passes the shut stop into the page (T5b, T-snap's `detent`).
pub const pass_speed: f32 = 400;

/// The lead to give the visible page's ScrollArea: `.{ .lead = TopSheet.lead(&sheet) }`.
pub fn lead(state: *State) ScrollArea.Lead {
    return .{ .ctx = state, .extent = extent, .range = range, .take = take };
}

/// 0 shut .. 1 open; the header draws from this alone.
pub fn openness(state: *const State) f32 {
    return if (state.range > 0) std.math.clamp(state.extent / state.range, 0, 1) else 0;
}

fn sync(ctx: *anyopaque) *State {
    const state: *State = @ptrCast(@alignCast(ctx));
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
    if (state.held) return 0;
    state.target = null;
    const before = state.extent;
    state.extent = std.math.clamp(before - by, 0, state.range);
    return @abs(state.extent - before);
}

/// Glide open without changing the page's scroll position.
pub fn open(state: *State) void {
    _ = sync(state);
    rest(state, state.range, 0);
}

/// Glide shut without changing the page's scroll position.
pub fn shut(state: *State) void {
    _ = sync(state);
    rest(state, 0, 0);
}

fn rest(state: *State, target: f32, speed: f32) void {
    state.target = null;
    if (glass.motion.off()) {
        state.extent = target;
        return;
    }
    state.target = target;
    state.settle_ns = dvui.frameTimeNS();
    state.settle_offset = state.extent - target;
    state.settle_speed = speed;
    dvui.refresh(null, @src(), null);
}

fn step(state: *State) void {
    const target = state.target orelse return;
    const now = dvui.frameTimeNS();
    if (state.stepped_frame == now) return;
    state.stepped_frame = now;
    const t = @as(f64, @floatFromInt(now - state.settle_ns)) / std.time.ns_per_s;
    const at = Fling.settle(state.settle_offset, state.settle_speed, t, 2 * std.math.pi * ScrollArea.seat.hz * glass.motion.rate());
    if (glass.motion.off() or (@abs(at.pos) < 0.1 and @abs(at.vel) < 2)) {
        state.extent = target;
        state.target = null;
    } else {
        state.extent = std.math.clamp(target + at.pos, 0, state.range);
        dvui.refresh(null, @src(), null);
    }
}

/// Draw bar children between init and deinit. Unhandled touch travel pulls the sheet;
/// a tap on empty space toggles it. A child button yields its press at the drag threshold.
pub const Handle = struct {
    box: *dvui.BoxWidget,
    state: *State,
    touch: *Touch,

    const Touch = struct {
        finger: dvui.enums.Button = .none,
        origin: dvui.Point.Physical = .{},
        dragging: bool = false,
        sideways: bool = false,
        probe: dvui.Dragging = .{},
        fling: Fling = .{},
    };

    pub fn init(src: std.builtin.SourceLocation, state: *State, opts: dvui.Options) Handle {
        _ = sync(state);
        const box = dvui.box(src, .{}, opts);
        var self: Handle = .{
            .box = box,
            .state = state,
            .touch = dvui.dataGetPtrDefault(null, box.data().id, "_sheet_touch", Touch, .{}),
        };
        for (dvui.events()) |*e| {
            if (!dvui.eventMatchSimple(e, box.data())) continue;
            if (e.evt == .mouse and e.evt.mouse.action == .press and e.evt.mouse.button.touch()) {
                state.target = null;
                state.held = false;
                self.touch.* = .{ .finger = e.evt.mouse.button, .origin = e.evt.mouse.p };
                self.touch.probe.preStart(e.evt.mouse.button, e.evt.mouse.p, .{});
                self.touch.fling.begin();
                self.touch.fling.sampleTimed(0, glass.input_time.get(e.num));
            }
        }
        if (self.touch.dragging) self.events();
        return self;
    }

    fn events(self: *Handle) void {
        const wd = self.box.data();
        const touch = self.touch;
        for (dvui.events()) |*e| {
            if (e.evt != .mouse or e.evt.mouse.button != touch.finger) continue;
            if (!dvui.eventMatchSimple(e, wd)) continue;
            const me = e.evt.mouse;
            switch (me.action) {
                .motion => {
                    const travel = me.p.diff(touch.origin);
                    // Velocity includes travel held before the drag threshold, just as extent does.
                    touch.fling.sampleTimed(me.action.motion.y / wd.rectScale().s, glass.input_time.get(e.num));
                    if (!touch.dragging) {
                        if (touch.probe.get(me.p, .{ .window_natural_scale = dvui.currentWindow().natural_scale }) == null) continue;
                        if (@abs(travel.y) <= 1.25 * @abs(travel.x)) touch.sideways = true;
                        if (touch.sideways) continue;
                    }
                    e.handle(@src(), wd);
                    dvui.captureMouse(wd, e.num);
                    const by = if (touch.dragging) me.action.motion.y else travel.y;
                    touch.dragging = true;
                    self.state.held = true;
                    self.state.target = null;
                    self.state.extent = std.math.clamp(self.state.extent + by / wd.rectScale().s, 0, self.state.range);
                },
                .press => {
                    e.handle(@src(), wd);
                    dvui.captureMouse(wd, e.num);
                },
                .release => {
                    e.handle(@src(), wd);
                    dvui.captureMouse(null, e.num);
                    dvui.dragEnd();
                    self.state.held = false;
                    if (touch.dragging) {
                        _ = touch.fling.releaseWindowedAt(.{ .min_start = 0, .max = std.math.inf(f32), .idle_s = 0.05 }, 0.05, glass.input_time.get(e.num));
                        const v = if (touch.fling.coasting) touch.fling.vel else 0;
                        const goes_open = if (@abs(v) > pass_speed) v > 0 else self.state.extent > self.state.range * @as(f32, if (v > 0) 0.35 else 0.65);
                        rest(self.state, if (goes_open) self.state.range else 0, v);
                    } else if (!touch.sideways and wd.borderRectScale().r.contains(me.p)) {
                        rest(self.state, if (self.state.extent > 0) 0 else self.state.range, 0);
                    }
                    touch.finger = .none;
                    touch.dragging = false;
                },
                else => {},
            }
        }
    }

    pub fn deinit(self: *Handle) void {
        self.events();
        // Children keep taps; their handled release still ends our observation of the finger.
        for (dvui.events()) |e| {
            if (e.evt == .mouse and e.evt.mouse.action == .release and e.evt.mouse.button == self.touch.finger) {
                self.touch.finger = .none;
            }
        }
        self.box.deinit();
    }
};
