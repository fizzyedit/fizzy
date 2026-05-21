const std = @import("std");
const dvui = @import("dvui");
const fizzy = @import("../../fizzy.zig");

pub const CanvasWidget = @This();

/// Canvas reveal fade duration in microseconds. Tuned to overlap noticeably with pane open
/// animations so the canvas doesn't pop in after them. Adjust here, not at the call site.
const fade_duration_micros: i32 = 150_000;

id: dvui.Id = undefined,
installed: bool = false,
init_opts: InitOptions = undefined,
scroll: *dvui.ScrollAreaWidget = undefined,
scaler: *dvui.ScaleWidget = undefined,
rect: dvui.Rect.Physical = .{},
scroll_container: *dvui.ScrollContainerWidget = undefined,
scroll_rect_scale: dvui.RectScale = .{},
screen_rect_scale: dvui.RectScale = .{},
scroll_info: dvui.ScrollInfo = .{ .vertical = .given, .horizontal = .given },
origin: dvui.Point = .{},
scale: f32 = 1.0,
prev_size: dvui.Size = .{},
prev_scale: f32 = 0.0,

// Centering needs the scroll container's final laid-out rect to compute the correct origin,
// but `install()` runs before the new scroll area's layout has settled — so the first
// `recenter()` pass uses a stale/empty viewport and the canvas appears at the wrong position
// for one frame, then "snaps" to centered on the second frame. We absorb this by tracking
// settlement explicitly and fading the canvas contents in via `dvui.alpha` (the canvas is
// invisible until centering has settled, then fades up via a dvui `Animation` keyed off the
// canvas id).
//
// A fixed two-pass count isn't enough on app startup / first file open: the surrounding
// workspace layout (status bar, tab bar, side panes) can take more than two frames to
// reach its final size, so both recenter passes can fire against a still-changing parent
// rect and the canvas ends up biased (typically slightly low). To handle that, we only
// decrement the pass counters on frames where the parent rect matches the previous
// frame's — i.e. layout has actually stopped moving — and we force an extra recenter on
// any frame where the parent rect changed since last frame.
first_center: bool = true,
second_center: bool = true,
prev_parent_rect: dvui.Rect = .{},

// Set to false on a reset (new file / size change / explicit recenter) so `install` kicks off
// a fresh fade-in animation exactly once per reset. dvui's animation system drives the value
// and the per-frame refresh internally.
fade_started: bool = false,
// One-frame latch: on a reset we wait a single frame before registering the reveal
// animation, so the very first install (where parent rect is most likely stale) is hidden
// behind a fully-opaque cover, and the fade then begins on the next frame — overlapping
// with any remaining settle frames instead of waiting for full settlement.
fade_pending: bool = false,
// Saved between `install` and `deinit` so the parent alpha is restored exactly.
prev_alpha: f32 = 1.0,
hovered: bool = false,
// Previous frame's `hovered`. Lets the tool dispatch detect the cursor-leaving-canvas
// transition exactly once, so the temp brush/fill preview can be cleared on the way out
// without paying the per-frame clear cost while the cursor is outside the canvas.
prev_hovered: bool = false,
// Previous frame's `gesture_active`. Lets FileWidget detect the moment a 2-finger pan
// takes over so an in-progress stroke / drag can be finalized (history append) and torn
// down. Without this, mid-stroke gesture takeovers swallow the release event and the
// pixels already drawn never make it into the undo stack.
prev_gesture_active: bool = false,
// Sticky input-mode flag: true once a touch has pressed, cleared by any subsequent
// non-touch mouse motion / press. Used by tools to suppress *all* temp-layer preview
// drawing while the user is on touch — there's no visible cursor, the finger occludes
// whatever it's over, and hover==drag on a touchscreen, so the preview pixel is dead
// weight that only ever shows up as a phantom after the user lifts off.
last_input_was_touch: bool = false,
// Latched in `deinit` so FileWidget can clear the temp layer exactly once on the input-
// mode transition (a mouse hover preview drawn before the user reached for the screen
// shouldn't linger after the first touch lands, and vice versa).
prev_last_input_was_touch: bool = false,

// Two-finger pan + pinch zoom (web/mobile touch). One finger continues to draw — the
// gesture only kicks in once a second finger touches. We mark the gesture sticky until
// every finger lifts so the remaining finger after a multi-touch doesn't suddenly start
// drawing mid-stroke. While the gesture is active we capture to the scaler so drawing
// tools' `scroll_container.matchEvent` returns false and they skip the touch.
touches: [10]TouchSlot = @splat(.{}),
gesture_active: bool = false,
last_centroid: dvui.Point.Physical = .{},
last_pinch: f32 = 0.0,

// Single-touch evaluation window. When the first finger lands we don't yet know whether
// the user is starting to draw or beginning a two-finger pan. Swallow the press (and any
// follow-up motion/release) for a short window; if a second finger doesn't arrive in
// time, replay the press into dvui's event queue so the active tool can react.
touch_eval_active: bool = false,
touch_eval_started_ns: i128 = 0,
touch_eval_slot: u8 = 0,
touch_eval_button: dvui.enums.Button = .touch0,
touch_eval_press_p: dvui.Point.Physical = .{},
touch_eval_released: bool = false,
touch_eval_release_p: dvui.Point.Physical = .{},


const TouchSlot = struct {
    active: bool = false,
    p: dvui.Point.Physical = .{},
};

const touch_eval_duration_ns: i128 = 80 * std.time.ns_per_ms;

/// True while a 2-finger pan/pinch is in progress, or while we're still deciding whether
/// a single touch will become one. Tools should skip their input processing whenever this
/// returns true so previews / strokes / fills aren't triggered by the touch that's about
/// to become a pan.
pub fn gestureActive(self: *const CanvasWidget) bool {
    return self.gesture_active or self.touch_eval_active;
}

pub const InitOptions = struct {
    id: dvui.Id,
    data_size: dvui.Size,
    center: bool = false,
};

pub fn recenter(self: *CanvasWidget) void {
    const parent = dvui.parentGet().data().rect;

    const file_width: f32 = self.init_opts.data_size.w;
    const file_height: f32 = self.init_opts.data_size.h;

    self.scroll_info.virtual_size.w = file_width * self.scale;
    self.scroll_info.virtual_size.h = file_height * self.scale;

    // Reset the scroll position alongside the origin. `deinit` adds pan slack each frame by
    // outsetting `virtual_size` and bumping `viewport.x/y` by the pad — so in steady state the
    // scroll position is non-zero. Recenter ignored that, leaving the scaler at `offset_y` in
    // virtual coords but rendered at `offset_y - viewport.y` on screen, shifting the content up
    // by exactly the pad. Zeroing the viewport here keeps `origin` and the scroll position in
    // sync; the next `deinit` re-establishes the pan slack symmetrically.
    self.scroll_info.viewport.x = 0;
    self.scroll_info.viewport.y = 0;

    const view_w = parent.w;
    const view_h = parent.h;

    const virt_w = self.scroll_info.virtual_size.w;
    const virt_h = self.scroll_info.virtual_size.h;

    const offset_x = (view_w - virt_w) * 0.5;
    const offset_y = (view_h - virt_h) * 0.5;

    self.origin.x = -offset_x;
    self.origin.y = -offset_y;

    // Only count this pass as making progress toward "settled" if the parent rect
    // actually matched last frame's — otherwise the layout is still moving under us and
    // this offset will be wrong by the next frame.
    const parent_stable = parent.w == self.prev_parent_rect.w and parent.h == self.prev_parent_rect.h;
    if (parent_stable) {
        if (self.first_center) {
            self.first_center = false;
        } else if (self.second_center) {
            self.second_center = false;
        }
    }
    self.prev_parent_rect = parent;
}

pub fn rescale(self: *CanvasWidget) void {
    const parent = dvui.parentGet().data().rect;

    const file_width: f32 = self.init_opts.data_size.w;
    const file_height: f32 = self.init_opts.data_size.h;
    const target_width = parent.w;
    const target_height = parent.h;
    const target_scale: f32 = @min(target_width / (file_width * 1.25), target_height / (file_height * 1.25));

    self.prev_scale = self.scale;
    self.scale = target_scale;
}

pub fn install(self: *CanvasWidget, src: std.builtin.SourceLocation, init_opts: InitOptions, opts: dvui.Options) void {
    self.id = init_opts.id;
    self.init_opts = init_opts;

    defer self.prev_size = self.init_opts.data_size;

    const size_changed = self.prev_size.h != self.init_opts.data_size.h or self.prev_size.w != self.init_opts.data_size.w;
    if (size_changed) {
        // Genuinely new content — restart the centering + fade. We deliberately do NOT key
        // off `init_opts.center` here: the workspace re-asserts `center=true` every frame
        // while the bottom-pane tray is animating open, and resetting `fade_started` each
        // frame would re-register the dvui animation at `start_time=0` forever, so the
        // fade would only "start" once the tray finishes. Centering itself is fine to run
        // multiple times — the two-frame `first/second_center` machinery handles that.
        self.first_center = true;
        self.second_center = true;
        self.fade_started = false;
        self.fade_pending = false;
    }
    // While still in the settle phase, force another recenter whenever the parent rect
    // changed since last frame: the workspace layout may still be moving (e.g. status bar
    // / tab bar laying out on first open) and a recenter against a stale parent rect
    // leaves the canvas visibly off-center. Once settled, parent-rect changes (e.g. user
    // resizing the window) must NOT re-center — the user's pan/zoom state is preserved.
    const parent_rect_now = dvui.parentGet().data().rect;
    const parent_changed_while_unsettled = !self.settled() and
        (parent_rect_now.w != self.prev_parent_rect.w or parent_rect_now.h != self.prev_parent_rect.h);
    if (size_changed or self.second_center or self.init_opts.center or parent_changed_while_unsettled) {
        self.rescale();
        self.recenter();
        dvui.refresh(null, @src(), self.id);
    }

    // Wait one frame before starting the fade so the most-stale (frame 1) recenter is
    // hidden (alpha == 0), then begin fading on the next install — overlapping with any
    // further settle frames rather than waiting for full settlement.
    if (!self.fade_started) {
        if (self.fade_pending) {
            dvui.animation(self.id, "canvas_reveal", .{
                .start_time = 0,
                .end_time = fade_duration_micros,
            });
            self.fade_started = true;
        } else {
            self.fade_pending = true;
            dvui.refresh(null, @src(), self.id);
        }
    }

    // Compute the current reveal value [0,1] and fade the canvas contents in by
    // multiplying the dvui alpha. Saved in `prev_alpha` so `deinit` can restore it.
    const reveal: f32 = if (!self.fade_started)
        0.0
    else if (dvui.animationGet(self.id, "canvas_reveal")) |a|
        std.math.clamp(a.value(), 0.0, 1.0)
    else
        1.0;
    self.prev_alpha = dvui.alpha(reveal);

    // Decide scrollbar visibility from last frame's viewport + this frame's scale. The bars are
    // misleading when virtual_size is artificially inflated by the pan-slack pad (deinit), so we
    // hide them outright when the content rect fits inside the viewport.
    const content_w_vp = self.init_opts.data_size.w * self.scale;
    const content_h_vp = self.init_opts.data_size.h * self.scale;
    const vp = self.scroll_info.viewport;
    const overflow_w = vp.w > 0 and content_w_vp > vp.w + 0.001;
    const overflow_h = vp.h > 0 and content_h_vp > vp.h + 0.001;

    self.scroll = dvui.scrollArea(src, .{
        .scroll_info = &self.scroll_info,
        .horizontal_bar = if (overflow_w) .auto else .hide,
        .vertical_bar = if (overflow_h) .auto else .hide,
    }, opts);

    self.scroll_container = &self.scroll.scroll.?;

    self.scaler = dvui.scale(src, .{ .scale = &self.scale }, .{ .rect = .{ .x = -self.origin.x, .y = -self.origin.y } });

    self.syncTransformCachesFromWidgets();

    // Eagerly update `hovered` against the current mouse position so the drawing tools (which
    // read it during the same frame) don't see stale state on the first touch frame. The
    // tail-end `processEvents()` pass also updates it, but by then the brush has already
    // skipped the press because `hovered` was still false from the previous frame.
    self.hovered = self.rect.contains(dvui.currentWindow().mouse_pt);

    // Process two-finger gesture BEFORE any drawing tool event loop so we can capture the
    // touches and prevent the brush from drawing during pan/pinch.
    self.updateTouchGesture();
}

fn activeTouchCount(self: *CanvasWidget) usize {
    var n: usize = 0;
    for (self.touches) |t| {
        if (t.active) n += 1;
    }
    return n;
}

fn touchCentroid(self: *CanvasWidget) dvui.Point.Physical {
    var x: f32 = 0;
    var y: f32 = 0;
    var n: f32 = 0;
    for (self.touches) |t| {
        if (t.active) {
            x += t.p.x;
            y += t.p.y;
            n += 1;
        }
    }
    if (n == 0) return .{};
    return .{ .x = x / n, .y = y / n };
}

fn touchPinchDistance(self: *CanvasWidget) f32 {
    var a: ?dvui.Point.Physical = null;
    var b: ?dvui.Point.Physical = null;
    for (self.touches) |t| {
        if (!t.active) continue;
        if (a == null) {
            a = t.p;
        } else {
            b = t.p;
            break;
        }
    }
    if (a == null or b == null) return 0;
    const dx = a.?.x - b.?.x;
    const dy = a.?.y - b.?.y;
    return @sqrt(dx * dx + dy * dy);
}

/// Iterate touch events: track active fingers, drive pan + pinch zoom once ≥2 are down,
/// and stay in that mode until every finger lifts. While active, claim each touch event
/// against the scaler so the scroll container's built-in touch-to-scroll and the drawing
/// tools' event loops both see it as captured-by-another-widget and skip.
pub fn updateTouchGesture(self: *CanvasWidget) void {
    var zoom: f32 = 1.0;
    var zoomP: dvui.Point.Physical = self.last_centroid;

    // Sniff this frame's events for the input mode. A non-touch press / motion (real
    // mouse) drops us out of "touch mode"; a touch press puts us back in. The flag
    // sticks across frames so hover previews stay suppressed while the user's finger is
    // lifted but `mouse_pt` still points at the last touch.
    for (dvui.events()) |*e| {
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        switch (me.action) {
            .press => self.last_input_was_touch = me.button.touch(),
            .motion => {
                if (!me.button.touch()) self.last_input_was_touch = false;
            },
            else => {},
        }
    }

    for (dvui.events()) |*e| {
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        if (!me.button.touch()) continue;

        const slot_signed = @intFromEnum(me.button) - @intFromEnum(dvui.enums.Button.touch0);
        if (slot_signed < 0 or slot_signed >= self.touches.len) continue;
        const slot: usize = @intCast(slot_signed);

        // For a press to belong to this canvas the touch must land in our scroll
        // container's rect; afterwards matchEvent honors the capture and keeps returning true
        // for the captured target. While gesture_active we accept events unconditionally.
        const in_area = self.scroll_container.matchEvent(e);

        switch (me.action) {
            .press => {
                if (!in_area and !self.gesture_active and !self.touch_eval_active) continue;
                self.touches[slot] = .{ .active = true, .p = me.p };

                if (self.activeTouchCount() >= 2 and !self.gesture_active) {
                    // Second finger arrived — promote to a gesture. Any pending evaluation
                    // is discarded; we never replay the original press.
                    self.gesture_active = true;
                    self.touch_eval_active = false;
                    self.last_centroid = self.touchCentroid();
                    self.last_pinch = self.touchPinchDistance();
                    dvui.captureMouse(self.scaler.data(), e.num);
                } else if (!self.gesture_active and !self.touch_eval_active and self.activeTouchCount() == 1) {
                    // First (and so far only) finger — start the wait window.
                    self.touch_eval_active = true;
                    self.touch_eval_started_ns = dvui.currentWindow().frame_time_ns;
                    self.touch_eval_slot = @intCast(slot);
                    self.touch_eval_button = me.button;
                    self.touch_eval_press_p = me.p;
                    self.touch_eval_released = false;
                    dvui.captureMouse(self.scaler.data(), e.num);
                }
                if (self.gesture_active or self.touch_eval_active) {
                    e.handle(@src(), self.scaler.data());
                }
            },
            .release => {
                if (self.touches[slot].active) self.touches[slot].active = false;

                if (self.touch_eval_active and slot == @as(usize, self.touch_eval_slot)) {
                    // User lifted before the eval window elapsed. Record it so the replay
                    // can synthesize both a press and a release once the window times out.
                    self.touch_eval_released = true;
                    self.touch_eval_release_p = me.p;
                    e.handle(@src(), self.scaler.data());
                }

                if (self.gesture_active) {
                    e.handle(@src(), self.scaler.data());

                    if (self.activeTouchCount() == 0) {
                        self.gesture_active = false;
                        if (dvui.captured(self.scaler.data().id)) {
                            dvui.captureMouse(null, e.num);
                        }
                    } else {
                        // Re-baseline so the remaining fingers don't cause a jump.
                        self.last_centroid = self.touchCentroid();
                        self.last_pinch = self.touchPinchDistance();
                    }
                }
            },
            .motion => {
                if (self.touches[slot].active) {
                    self.touches[slot].p = me.p;
                }
                if (self.touch_eval_active and slot == @as(usize, self.touch_eval_slot)) {
                    // Swallow motion during eval so the scroll container's touch-pan and the
                    // drawing tools' previews don't run on a touch that might still become a
                    // gesture. The latest position is used as the release point if the user
                    // lifts mid-window.
                    self.touch_eval_release_p = me.p;
                    e.handle(@src(), self.scaler.data());
                }
                if (self.gesture_active) {
                    e.handle(@src(), self.scaler.data());

                    const new_c = self.touchCentroid();
                    const dx_centroid = new_c.x - self.last_centroid.x;
                    const dy_centroid = new_c.y - self.last_centroid.y;
                    const rs = self.scroll_rect_scale;
                    if (rs.s > 0) {
                        self.scroll_info.viewport.x -= dx_centroid / rs.s;
                        self.scroll_info.viewport.y -= dy_centroid / rs.s;
                    }

                    const new_d = self.touchPinchDistance();
                    if (self.last_pinch > 1.0 and new_d > 1.0) {
                        const ratio = new_d / self.last_pinch;
                        zoom *= ratio;
                        zoomP = new_c;
                    }

                    self.last_centroid = new_c;
                    self.last_pinch = new_d;
                    dvui.refresh(null, @src(), self.scroll_container.data().id);
                }
            },
            else => {},
        }
    }

    // Drive the wait window: if the timer expired without a 2nd touch, replay the
    // swallowed press/release into dvui's event queue. Later widgets this frame fetch a
    // fresh `dvui.events()` slice that includes the synthetic events and react normally.
    if (self.touch_eval_active and !self.gesture_active) {
        const now = dvui.currentWindow().frame_time_ns;
        const elapsed = now - self.touch_eval_started_ns;
        if (elapsed >= touch_eval_duration_ns) {
            const win = dvui.currentWindow();
            const press_p = self.touch_eval_press_p;
            const release_p = self.touch_eval_release_p;
            const button = self.touch_eval_button;
            const released = self.touch_eval_released;

            self.touch_eval_active = false;
            if (dvui.captured(self.scaler.data().id)) {
                dvui.captureMouse(null, 0);
            }

            // `addEventPointer` uses `win.mouse_pt` for the event position. Push the press
            // point first, fire the synthetic press, then do the same for the release.
            win.mouse_pt = press_p;
            _ = win.addEventPointer(.{ .button = button, .action = .press }) catch {};

            if (released) {
                win.mouse_pt = release_p;
                _ = win.addEventPointer(.{ .button = button, .action = .release }) catch {};
            }

            dvui.refresh(null, @src(), self.scroll_container.data().id);
        } else {
            // Keep frames coming so the timer ticks even on an idle press.
            dvui.refresh(null, @src(), self.scroll_container.data().id);
        }
    }

    if (zoom != 1.0) {
        // Same scale-around-point math as the wheel-zoom path in processEvents.
        const prevP = self.dataFromScreenPoint(zoomP);
        var pp = prevP.scale(1 / self.scale, dvui.Point);
        self.scale *= zoom;
        pp = pp.scale(self.scale, dvui.Point);
        const newP = self.screenFromDataPoint(pp);
        const diff = self.viewportFromScreenPoint(newP).diff(self.viewportFromScreenPoint(zoomP));
        self.scroll_info.viewport.x += diff.x;
        self.scroll_info.viewport.y += diff.y;
        dvui.refresh(null, @src(), self.scroll_container.data().id);
    }
}

/// Re-read scroll/scaler `RectScale` and `rect` from the widget tree. Call at end of `install`, or
/// after changing `scale` / `origin` / `virtual_size` while the scroll area still exists (e.g. fit pass).
pub fn syncTransformCachesFromWidgets(self: *CanvasWidget) void {
    self.scroll_rect_scale = self.scroll_container.screenRectScale(.{});
    self.screen_rect_scale = self.scaler.screenRectScale(.{});
    self.rect = self.screenFromDataRect(dvui.Rect.fromSize(.{ .w = self.init_opts.data_size.w, .h = self.init_opts.data_size.h }));
}

/// Contain `content` inside `host` (natural px) with margin; updates `scale`, `scroll_info.virtual_size`,
/// and `origin` for centered letterboxing. Prefer calling **before** `install` when the host size comes
/// from the previous frame’s viewport so the scaler is created with the right offset; if you must run
/// after `install`, follow with `syncTransformCachesFromWidgets` (scaler child offset may lag one frame).
pub fn fitContentContainInHost(self: *CanvasWidget, content: dvui.Size, host: dvui.Rect, margin: f32) void {
    const fw = content.w;
    const fh = content.h;
    if (fw <= 0 or fh <= 0 or host.w <= 1 or host.h <= 1) return;

    self.scale = @max(
        @min(host.w / (fw * margin), host.h / (fh * margin)),
        0.0001,
    );

    self.scroll_info.virtual_size.w = fw * self.scale;
    self.scroll_info.virtual_size.h = fh * self.scale;

    const virt_w = self.scroll_info.virtual_size.w;
    const virt_h = self.scroll_info.virtual_size.h;
    self.origin.x = -(host.w - virt_w) * 0.5;
    self.origin.y = -(host.h - virt_h) * 0.5;
}

/// True once both centering passes have completed. While unsettled, the canvas contents are
/// positioned with a stale viewport, so callers should treat coordinate transforms as
/// preliminary. The canvas alpha is held at 0 until settled so the misalignment is invisible.
pub fn settled(self: *const CanvasWidget) bool {
    return !self.first_center and !self.second_center;
}

pub fn deinit(self: *CanvasWidget) void {
    // Latch `hovered` / `gesture_active` / active touch count for the next frame's
    // transition checks. Done in deinit (rather than install) so FileWidget's hover-leave
    // / gesture-takeover / touch-lift handlers run against the values set during *this*
    // frame's processing.
    self.prev_hovered = self.hovered;
    self.prev_gesture_active = self.gesture_active;
    self.prev_last_input_was_touch = self.last_input_was_touch;
    self.scaler.deinit();
    self.scroll.deinit();
    // Restore the alpha multiplied in `install`. Done after the children deinit so any
    // sibling content drawn by the caller between `install` and `deinit` is also faded.
    dvui.alphaSet(self.prev_alpha);
}

pub fn dataFromScreenPoint(self: *CanvasWidget, screen: dvui.Point.Physical) dvui.Point {
    return self.screen_rect_scale.pointFromPhysical(screen);
}

pub fn screenFromDataPoint(self: *CanvasWidget, data: dvui.Point) dvui.Point.Physical {
    return self.screen_rect_scale.pointToPhysical(data);
}

pub fn viewportFromScreenPoint(self: *CanvasWidget, screen: dvui.Point.Physical) dvui.Point {
    return self.scroll_rect_scale.pointFromPhysical(screen);
}

pub fn screenFromViewportPoint(self: *CanvasWidget, viewport: dvui.Point) dvui.Point.Physical {
    return self.scroll_rect_scale.pointToPhysical(viewport);
}

pub fn dataFromScreenRect(self: *CanvasWidget, screen: dvui.Rect.Physical) dvui.Rect {
    return self.screen_rect_scale.rectFromPhysical(screen);
}

pub fn screenFromDataRect(self: *CanvasWidget, data: dvui.Rect) dvui.Rect.Physical {
    return self.screen_rect_scale.rectToPhysical(data);
}

pub fn viewportFromScreenRect(self: *CanvasWidget, screen: dvui.Rect.Physical) dvui.Rect {
    return self.scroll_rect_scale.rectFromPhysical(screen);
}

pub fn screenFromViewportRect(self: *CanvasWidget, viewport: dvui.Rect) dvui.Rect.Physical {
    return self.scroll_rect_scale.rectToPhysical(viewport);
}

/// If the mouse position is currently contained within the canvas rect,
/// Returns the data/world point of the mouse, which corresponds to the pixel input of
/// Layer functions
// pub fn hovered(self: *CanvasWidget) ?dvui.Point {
//     for (dvui.events()) |*e| {
//         if (!self.scroll_container.matchEvent(e)) {
//             continue;
//         }

//         if (e.evt == .mouse and e.evt.mouse.action == .position) {
//             if (self.rect.contains(e.evt.mouse.p)) {
//                 return self.dataFromScreenPoint(e.evt.mouse.p);
//             }
//         }
//     }

//     return null;
// }

/// Returns the mouse event if one occured this frame
pub fn mouse(self: *CanvasWidget) ?dvui.Event.Mouse {
    for (dvui.events()) |*e| {
        if (!self.scroll_container.matchEvent(e))
            continue;

        switch (e.evt) {
            .mouse => |me| {
                return me;
            },
            else => {},
        }
    }

    return null;
}

pub fn processEvents(self: *CanvasWidget) void {
    //const file = self.file;

    var zoom: f32 = 1;
    var zoomP: dvui.Point.Physical = .{};

    // Suppress DVUI's built-in single-touch auto-pan inside the canvas. By this point in the
    // frame the drawing tools have already consumed any single-finger touches, and the scroll
    // container's processEvents runs at scroll.deinit (which comes after this) — so claiming
    // here makes its `me.button.touch()` branches see the event as handled and skip the pan.
    // Two-finger gestures are already captured to the scaler by `updateTouchGesture`, which
    // takes precedence here via matchEvent returning false for them.
    for (dvui.events()) |*e| {
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        if (!me.button.touch()) continue;
        if (self.scroll_container.matchEvent(e)) {
            e.handle(@src(), self.scroll_container.data());
        }
    }

    // process scroll area events after boxes so the boxes get first pick (so
    // the button works)
    for (dvui.events()) |*e| {
        if (!self.scroll_container.matchEvent(e)) {
            self.hovered = false;
            continue;
        }

        switch (e.evt) {
            .mouse => |me| {
                if (me.action == .position) {
                    if (self.rect.contains(me.p)) {
                        self.hovered = true;
                    } else {
                        self.hovered = false;
                    }
                }

                if (me.action == .press and me.button == .middle) {
                    e.handle(@src(), self.scroll_container.data());
                    dvui.captureMouse(self.scroll_container.data(), e.num);
                    dvui.dragPreStart(me.p, .{ .name = "scroll_drag" });
                } else if (me.action == .release and me.button == .middle) {
                    if (dvui.captured(self.scroll_container.data().id)) {
                        e.handle(@src(), self.scroll_container.data());
                        dvui.captureMouse(null, e.num);
                        dvui.dragEnd();
                    }
                } else if (me.action == .motion) {
                    if (dvui.captured(self.scroll_container.data().id)) {
                        if (dvui.dragging(me.p, "scroll_drag")) |dps| {
                            const rs = self.scroll_rect_scale;
                            self.scroll_info.viewport.x -= dps.x / rs.s;
                            self.scroll_info.viewport.y -= dps.y / rs.s;
                            dvui.refresh(null, @src(), self.scroll_container.data().id);
                        }
                    }
                } else if (me.action == .wheel_y or me.action == .wheel_x) {
                    switch (fizzy.Editor.Settings.resolvedPanZoomScheme(&fizzy.editor.settings)) {
                        .mouse => {
                            const base: f32 = if (me.mod.matchBind("shift")) 1.005 else 1.005;
                            if ((me.mod.matchBind("shift") and me.mod.matchBind("ctrl/cmd")) or !me.mod.matchBind("shift") and !me.mod.matchBind("ctrl/cmd")) {
                                e.handle(@src(), self.scroll_container.data());
                                if (me.action == .wheel_y) {
                                    const zs = @exp(@log(base) * me.action.wheel_y);
                                    if (zs != 1.0) {
                                        zoom *= zs;
                                        zoomP = me.p;
                                    }
                                }
                            }
                        },
                        .trackpad => {
                            if (me.mod.matchBind("zoom")) {
                                e.handle(@src(), self.scroll_container.data());
                                if (me.action == .wheel_y) {
                                    const base: f32 = if (me.mod.matchBind("shift")) 1.003 else 1.002;
                                    const zs = @exp(@log(base) * me.action.wheel_y);
                                    if (zs != 1.0) {
                                        zoom *= zs;
                                        zoomP = me.p;
                                    }
                                }
                            }
                        },
                    }
                }
            },
            else => {},
        }
    }

    // scale around mouse point
    // first get data point of mouse
    // data from screen
    const prevP = self.dataFromScreenPoint(zoomP);

    // scale
    var pp = prevP.scale(1 / self.scale, dvui.Point);
    self.scale *= zoom;
    pp = pp.scale(self.scale, dvui.Point);

    // get where the mouse would be now
    // data to screen
    const newP = self.screenFromDataPoint(pp);

    if (zoom != 1.0) {

        // convert both to viewport
        const diff = self.viewportFromScreenPoint(newP).diff(self.viewportFromScreenPoint(zoomP));
        self.scroll_info.viewport.x += diff.x;
        self.scroll_info.viewport.y += diff.y;

        dvui.refresh(null, @src(), self.scroll_container.data().id);
    }

    // // don't mess with scrolling if we aren't being shown (prevents weirdness
    // // when starting out)
    if (!self.scroll_info.viewport.empty()) {
        // Pad strategy depends on whether the content rect overflows the viewport:
        //   - Overflow (zoomed in): use a tiny pad so virtual_size tracks the content rect.
        //     Scrollbars stay anchored to the artwork bounds and don't dance around as the user
        //     pans into a viewport-relative bbox that keeps shifting.
        //   - Fit (zoomed out): use the hybrid pad for generous, smooth pan slack since
        //     scrollbars are hidden in this regime anyway (see `install`).
        const content_w_vp = self.init_opts.data_size.w * self.scale;
        const content_h_vp = self.init_opts.data_size.h * self.scale;
        const overflow_w = content_w_vp > self.scroll_info.viewport.w + 0.001;
        const overflow_h = content_h_vp > self.scroll_info.viewport.h + 0.001;
        const content_overflows = overflow_w or overflow_h;

        const pad: f32 = if (content_overflows) 6.0 else blk: {
            const viewport_min = @min(self.scroll_info.viewport.w, self.scroll_info.viewport.h);
            break :blk @max(
                @max(6.0, viewport_min * 0.5),
                6.0 / @max(self.scale, 0.0001),
            );
        };
        var bbox = self.scroll_info.viewport.outsetAll(pad);
        const scrollbbox = self.viewportFromScreenRect(self.rect);
        bbox = bbox.unionWith(scrollbbox);

        // adjust top if needed
        if (bbox.y != 0) {
            const adj = -bbox.y;
            self.scroll_info.virtual_size.h += adj;
            self.scroll_info.viewport.y += adj;
            self.origin.y -= adj;
            dvui.refresh(null, @src(), self.scroll.data().id);
        }

        // adjust left if needed
        if (bbox.x != 0) {
            const adj = -bbox.x;
            self.scroll_info.virtual_size.w += adj;
            self.scroll_info.viewport.x += adj;
            self.origin.x -= adj;
            dvui.refresh(null, @src(), self.scroll.data().id);
        }

        // adjust bottom if needed
        if (bbox.h != self.scroll_info.virtual_size.h) {
            self.scroll_info.virtual_size.h = bbox.h;
            dvui.refresh(null, @src(), self.scroll.data().id);
        }

        // adjust right if needed
        if (bbox.w != self.scroll_info.virtual_size.w) {
            self.scroll_info.virtual_size.w = bbox.w;
            dvui.refresh(null, @src(), self.scroll.data().id);
        }
    }
}
