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

/// Parent rect captured during the previous `install` call (regardless of whether
/// `recenter` ran). Lets us detect "the workspace pane is mid-animation right now" so
/// we can skip the pan-slack viewport/origin mutation in `processEvents` — running it
/// while the parent is still resizing causes the canvas to drift downward a few pixels
/// each open/close cycle of the explorer in collapsed (mobile) mode.
prev_install_parent_rect: dvui.Rect = .{},
/// Number of consecutive frames the parent rect has been unchanged. Pan-slack only
/// runs after a few stable frames — otherwise easing animations (which can briefly
/// repeat a value between two different ones) sneak a pan-slack run mid-animation and
/// it leaks pixels of drift.
stable_parent_rect_frames: u32 = 0,
/// Snapshot of the scroll-info viewport / virtual_size / origin taken on the last
/// truly-stable frame. Restored every install while the parent rect is still moving,
/// so any mid-frame mutations to those fields (the scroll container's processVelocity
/// bounce-back, an aborted pan-slack adjustment, etc.) don't leak across frames.
stable_viewport: dvui.Rect = .{},
stable_virtual_size: dvui.Size = .{},
stable_origin: dvui.Point = .{},
has_stable_snapshot: bool = false,

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
// Last frame's scroll viewport in physical pixels (latched in `deinit`). Used when the
// scroll container is not installed yet this frame (e.g. UI chrome before `FileWidget`).
sample_viewport_physical: ?dvui.Rect.Physical = null,
// Previous frame's `hovered` (drawable artboard via `pointerOverDrawable`). Lets the tool dispatch
// detect the cursor-leaving-canvas transition exactly once, so the temp brush/fill preview can be
// cleared on the way out without paying the per-frame clear cost while the pointer is outside
// the artboard.
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

// Frame time (ns) of the most recently applied trackpad pinch event. `trackpadPinching()`
// reports true within a brief window after this so consumers (e.g. sprite bubble drawing)
// can suppress chrome that doesn't smoothly follow the per-frame scale change — same role
// `ctrl/cmd` plays for wheel-zoom. 0 means no pinch has ever happened this session.
trackpad_pinch_last_ns: i128 = 0,

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
touch_eval_last_p: dvui.Point.Physical = .{},
/// Off-artboard pan promoted from the touch-eval window (finger left the artboard while eval was active).
touch_eval_pan_active: bool = false,
/// Touch slot driving an empty-area scroll pan (for release / cancel when the browser drops events).
scroll_pan_touch_slot: ?u8 = null,
scroll_pan_end_pending: bool = false,

// Momentum for the drag-pan (middle button, or a left/touch drag starting off the
// artboard). One coast per axis so a flick keeps gliding after release; see Fling.
pan_fling_x: fizzy.Fling = .{},
pan_fling_y: fizzy.Fling = .{},

// Pinch / two-finger pan input accumulated during this frame's `updateTouchGesture`.
// Mutating `scale` / `scroll_info.viewport` mid-frame jitters the canvas because the
// scaler's own `data().rectScale()` is locked in at scaler creation (before the pinch
// runs) — scaler-child widgets would render at post-pinch scale relative to pre-pinch
// origin. Instead we collect the deltas here and apply them at end-of-frame from
// `processEvents`, so the next frame's install caches everything consistently (this
// is the same pattern wheel zoom uses, which is why it stays smooth).
pending_pinch_zoom: f32 = 1.0,
pending_pinch_zoom_p: dvui.Point.Physical = .{},
pending_touch_pan: dvui.Point.Physical = .{},
pending_trackpad_ratio: f32 = 1.0,
pending_trackpad_cursor: dvui.Point.Physical = .{},
pending_trackpad: bool = false,

// A left/touch press that begins on empty canvas (off the artboard) and hasn't resolved
// yet. It is one explicit state instead of the old tangle of tap_* booleans, and it is
// resolved in a single place each frame, keyed off whether the pointer is still down. For
// touch that "still down" signal is the slot's `active` flag (maintained in
// `updateTouchGesture`, which runs earlier this frame), so it no longer depends on the
// release event reaching a particular event loop — that dependency is what latched stale
// state and produced phantom / delayed radial menus. Middle-button pans never arm this.
empty: EmptyGesture = .idle,
/// Whether the pending gesture came from touch (resolve via slot) vs mouse (resolve via events).
empty_is_touch: bool = false,
empty_slot: u8 = 0,
/// Mouse-only "pointer still down" latch (set on press, cleared on release event).
empty_down: bool = false,
empty_press_p: dvui.Point.Physical = .{},
empty_press_ns: i128 = 0,

const EmptyGesture = enum {
    idle,
    /// Pressed, undecided: may become a tap (clear selection), a hold (radial menu), or a pan.
    pending,
    /// A hold opened the radial menu; the finger may still be down.
    holding,
};

const TouchSlot = struct {
    active: bool = false,
    p: dvui.Point.Physical = .{},
};

const touch_eval_duration_ns: i128 = 80 * std.time.ns_per_ms;

/// Drag-pan momentum tuning. Units are viewport (data) pixels per second — the same
/// units `scroll_info.viewport.x/y` move in — so the feel scales naturally with zoom.
/// Release velocity is measured over a wall-clock position/time window
/// (`releaseWindowed`)
const pan_fling: fizzy.Fling.Tuning = .{
    .decay = 4.0,
    .min_start = 40.0,
    .stop = 10.0,
    .max = 8000.0,
    .idle_s = 0.18,
};
/// Window the pan release velocity is averaged over (s).
const pan_fling_window_s: f32 = 0.08;

/// True while a 2-finger pan/pinch is in progress, or while we're still deciding whether
/// a single touch will become one. Tools should skip their input processing whenever this
/// returns true so previews / strokes / fills aren't triggered by the touch that's about
/// to become a pan.
pub fn gestureActive(self: *const CanvasWidget) bool {
    return self.gesture_active or self.touch_eval_active;
}

fn emptyPanDragThreshold() f32 {
    return dvui.Dragging.threshold * dvui.currentWindow().natural_scale;
}

fn viewportPanDeltaFromPhysical(self: *const CanvasWidget, dp: dvui.Point.Physical) dvui.Point.Physical {
    const rs = self.scroll_rect_scale;
    if (rs.s <= 0) return .{};
    return .{ .x = -dp.x / rs.s, .y = -dp.y / rs.s };
}

fn promoteTouchEvalToEmptyPan(self: *CanvasWidget, slot: usize, p: dvui.Point.Physical) void {
    self.touch_eval_active = false;
    self.touch_eval_pan_active = true;
    self.scroll_pan_touch_slot = @intCast(slot);
    if (dvui.captured(self.scaler.data().id)) {
        dvui.captureMouse(null, 0);
    }
    const dp = p.diff(self.touch_eval_last_p);
    if (dp.x != 0 or dp.y != 0) {
        const vd = self.viewportPanDeltaFromPhysical(dp);
        self.pending_touch_pan.x += vd.x;
        self.pending_touch_pan.y += vd.y;
    }
    self.touch_eval_last_p = p;
    dvui.refresh(null, @src(), self.scroll_container.data().id);
}

fn noteScrollPanTouchEnd(self: *CanvasWidget, slot: usize) void {
    if (self.scroll_pan_touch_slot) |s| {
        if (s == slot) self.scroll_pan_end_pending = true;
    }
    if (self.touch_eval_pan_active and self.touch_eval_slot == slot) {
        self.scroll_pan_end_pending = true;
        self.touch_eval_pan_active = false;
    }
}

/// True for a brief window after the most recent macOS trackpad pinch event. The window
/// (~150ms) spans tiny pauses inside a continuous gesture and the trailing end-of-gesture
/// frame so toggling UI doesn't flicker. Callers should treat this as "user is actively
/// zooming" and suppress chrome that doesn't smoothly track the per-frame scale change.
pub fn trackpadPinching(self: *const CanvasWidget) bool {
    if (self.trackpad_pinch_last_ns == 0) return false;
    const window_ns: i128 = 150 * std.time.ns_per_ms;
    return (dvui.currentWindow().frame_time_ns - self.trackpad_pinch_last_ns) < window_ns;
}

/// How wheel/scroll input maps to pan vs. zoom. The owner resolves its own user
/// preference (mouse vs. trackpad) and passes the result; the canvas stays unaware of
/// any settings system.
pub const PanZoomScheme = enum { mouse, trackpad };

/// Owner-supplied reactions to viewport gestures the canvas itself has no opinion about.
/// Every field is optional: a plain pan/zoom viewport (e.g. an image preview) supplies
/// none, while an editor supplies hooks that act on its own document/tool state. `ctx` is
/// passed back to each callback so a plugin can reach its state without globals.
pub const Hooks = struct {
    ctx: ?*anyopaque = null,
    /// An off-artboard press that released without moving or holding (a "tap" on empty
    /// space). Pixel art uses this to clear the current selection.
    onEmptyTap: ?*const fn (ctx: ?*anyopaque) void = null,
    /// An off-artboard press held in place past the hold-menu duration. Pixel art opens
    /// its radial tool menu at `press_p`.
    onEmptyHold: ?*const fn (ctx: ?*anyopaque, press_p: dvui.Point.Physical) void = null,
    /// Whether a modified (ctrl/cmd or shift) off-artboard press should be yielded to the
    /// owner instead of starting a viewport pan. Pixel art yields it to the selection
    /// marquee when the pointer tool is active.
    yieldModifiedEmptyPress: ?*const fn (ctx: ?*anyopaque) bool = null,
    /// Whether pointer input to this canvas is currently suppressed (e.g. a modal overlay
    /// owns input this frame). Replaces the old built-in main/dialog scope switch.
    pointerInputSuppressed: ?*const fn (ctx: ?*anyopaque) bool = null,
};

pub const InitOptions = struct {
    id: dvui.Id,
    data_size: dvui.Size,
    center: bool = false,
    pan_zoom_scheme: PanZoomScheme = .mouse,
    hooks: Hooks = .{},
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

    // Track parent-rect stability across consecutive installs. Pan-slack and any
    // discretionary mutation of scroll_info only runs when we've seen `stable_threshold`
    // identical-rect frames in a row — easing animations sometimes repeat a value
    // between two different ones, and a single pan-slack run mid-animation drifts
    // `viewport.y` / `origin.y` a couple of pixels that never get restored, which is
    // what was sliding the canvas off-screen over many open/close cycles in collapsed mode.
    const stable_threshold: u32 = 3;
    const rect_eq = std.math.approxEqAbs(f32, parent_rect_now.w, self.prev_install_parent_rect.w, 0.5) and
        std.math.approxEqAbs(f32, parent_rect_now.h, self.prev_install_parent_rect.h, 0.5);
    if (rect_eq) {
        self.stable_parent_rect_frames = @min(self.stable_parent_rect_frames + 1, stable_threshold);
    } else {
        self.stable_parent_rect_frames = 0;
    }
    self.prev_install_parent_rect = parent_rect_now;

    const parent_is_stable = self.stable_parent_rect_frames >= stable_threshold;

    // While the parent is moving, restore the scroll/origin snapshot from the last
    // confirmed stable frame. This freezes the canvas's pan/zoom state during animations
    // so mid-frame mutations (scroll container bounce-back, scrollbar visibility flips
    // shrinking the viewport, etc.) don't accumulate drift.
    if (self.settled() and !parent_is_stable and self.has_stable_snapshot) {
        self.scroll_info.viewport.x = self.stable_viewport.x;
        self.scroll_info.viewport.y = self.stable_viewport.y;
        self.scroll_info.virtual_size = self.stable_virtual_size;
        self.origin = self.stable_origin;
    }

    // Even on stable frames, eagerly grow `virtual_size` to cover `viewport.{x,y} +
    // parent_rect.{w,h}` so `ScrollContainerWidget.processVelocity`'s bounce-back never
    // fires. That bounce is the underlying dvui behavior responsible for the canvas
    // visibly scrolling downward whenever the workspace's parent rect grows (explorer
    // toggle, bottom-panel slider drag, window resize).
    {
        const needed_h = self.scroll_info.viewport.y + parent_rect_now.h;
        if (self.scroll_info.virtual_size.h < needed_h) self.scroll_info.virtual_size.h = needed_h;
        const needed_w = self.scroll_info.viewport.x + parent_rect_now.w;
        if (self.scroll_info.virtual_size.w < needed_w) self.scroll_info.virtual_size.w = needed_w;
    }
    // `init_opts.center` is driven by workspace split / bottom-panel tray animation. If the
    // workspace subtree was not drawn (explorer peek/collapse), `drawWorkspaces` may not run
    // for many frames and `center` can stay true — ignore it once the canvas has settled so
    // reopening the explorer does not recenter an already-panned file.
    const explicit_center = self.init_opts.center and !self.settled();
    if (size_changed or self.second_center or explicit_center or parent_changed_while_unsettled) {
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
    self.hovered = !self.pointerInputSuppressed() and
        self.pointerOverDrawable(dvui.currentWindow().mouse_pt);

    // Process two-finger gesture BEFORE any drawing tool event loop so we can capture the
    // touches and prevent the brush from drawing during pan/pinch.
    self.updateTouchGesture();

    self.installed = true;
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
                    self.touch_eval_pan_active = false;
                    self.empty = .idle;
                    if (dvui.captured(self.scroll_container.data().id)) {
                        dvui.captureMouse(null, e.num);
                        dvui.dragEnd();
                        self.pan_fling_x.cancel();
                        self.pan_fling_y.cancel();
                        self.scroll_pan_touch_slot = null;
                    }
                    self.last_centroid = self.touchCentroid();
                    self.last_pinch = self.touchPinchDistance();
                    dvui.captureMouse(self.scaler.data(), e.num);
                } else if (self.gesture_active) {
                    // Already in gesture mode and another finger touched down (typical case:
                    // user dropped to a single-finger pan after a 2-finger start and is now
                    // bringing a second finger back to resume pinch-zoom). Re-baseline so the
                    // centroid/pinch jump from the new finger doesn't translate into a pan/zoom
                    // delta on the next motion event.
                    self.last_centroid = self.touchCentroid();
                    self.last_pinch = self.touchPinchDistance();
                } else if (!self.touch_eval_active and !self.touch_eval_pan_active and self.activeTouchCount() == 1) {
                    // First finger on the artboard: short wait for a possible second finger.
                    // Off-artboard presses skip eval so empty-area pan + flick work immediately.
                    if (self.pointerOverDrawable(me.p)) {
                        self.touch_eval_active = true;
                        self.touch_eval_started_ns = dvui.currentWindow().frame_time_ns;
                        self.touch_eval_slot = @intCast(slot);
                        self.touch_eval_button = me.button;
                        self.touch_eval_press_p = me.p;
                        self.touch_eval_last_p = me.p;
                        self.touch_eval_released = false;
                        dvui.captureMouse(self.scaler.data(), e.num);
                    }
                }
                if (self.gesture_active or self.touch_eval_active) {
                    e.handle(@src(), self.scaler.data());
                }
            },
            .release => {
                if (self.touches[slot].active) self.touches[slot].active = false;
                self.noteScrollPanTouchEnd(slot);

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
                if (self.touch_eval_pan_active and self.scroll_pan_touch_slot == @as(u8, @intCast(slot))) {
                    const dp = me.p.diff(self.touch_eval_last_p);
                    if (dp.x != 0 or dp.y != 0) {
                        const vd = self.viewportPanDeltaFromPhysical(dp);
                        self.pending_touch_pan.x += vd.x;
                        self.pending_touch_pan.y += vd.y;
                        self.touch_eval_last_p = me.p;
                        dvui.refresh(null, @src(), self.scroll_container.data().id);
                    }
                    e.handle(@src(), self.scaler.data());
                } else if (self.touch_eval_active and slot == @as(usize, self.touch_eval_slot)) {
                    // Swallow motion during eval so the scroll container's touch-pan and the
                    // drawing tools' previews don't run on a touch that might still become a
                    // gesture. The latest position is used as the release point if the user
                    // lifts mid-window.
                    self.touch_eval_release_p = me.p;
                    const dist = me.p.diff(self.touch_eval_press_p);
                    const th = emptyPanDragThreshold();
                    if (!self.pointerOverDrawable(me.p) and
                        (@abs(dist.x) > th or @abs(dist.y) > th))
                    {
                        self.promoteTouchEvalToEmptyPan(slot, me.p);
                    } else {
                        self.touch_eval_last_p = me.p;
                    }
                    e.handle(@src(), self.scaler.data());
                }
                if (self.gesture_active) {
                    e.handle(@src(), self.scaler.data());

                    const new_c = self.touchCentroid();
                    const dx_centroid = new_c.x - self.last_centroid.x;
                    const dy_centroid = new_c.y - self.last_centroid.y;
                    const rs = self.scroll_rect_scale;
                    if (rs.s > 0) {
                        // Defer the pan to end-of-frame so the canvas widget tree this
                        // frame stays internally consistent (see field doc).
                        self.pending_touch_pan.x -= dx_centroid / rs.s;
                        self.pending_touch_pan.y -= dy_centroid / rs.s;
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

    if (self.scroll_pan_touch_slot) |slot| {
        if (!self.touches[slot].active) {
            self.noteScrollPanTouchEnd(slot);
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

            // Quick off-artboard tap: finger lifted during the eval window. Hand it to the
            // owner (pixel art clears selection) so we never arm hold state from the replayed press.
            if (released and !self.pointerOverDrawable(press_p)) {
                if (self.init_opts.hooks.onEmptyTap) |f| f(self.init_opts.hooks.ctx);
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
        // Defer the 2-finger pinch zoom to `processEvents` (end-of-frame) — see the
        // pending field docs for the jitter reason.
        self.pending_pinch_zoom *= zoom;
        self.pending_pinch_zoom_p = zoomP;
        dvui.refresh(null, @src(), self.scroll_container.data().id);
    }

    // macOS trackpad pinch-zoom. The native backend accumulates per-event magnification
    // deltas from an AppKit local monitor; we drain them once per frame and apply the same
    // scale-around-point math used by wheel/touch zoom. Focal point is the cursor position
    // (macOS does not move the cursor during a trackpad gesture, so it represents intent).
    // No-op on Windows/Linux/web (`takeTrackpadPinchRatio` returns 1.0 there).
    const trackpad_ratio = fizzy.backend.takeTrackpadPinchRatio();
    if (trackpad_ratio != 1.0) {
        const cursor_phys = dvui.currentWindow().mouse_pt;
        // Only honor the gesture when the cursor is over the canvas viewport — otherwise a
        // user pinching while their pointer sits on a side panel / toolbar would unexpectedly
        // zoom the canvas.
        if (self.scroll_container.data().contentRectScale().r.contains(cursor_phys)) {
            // Defer the trackpad pinch zoom to `processEvents` for the same reason.
            self.pending_trackpad_ratio *= trackpad_ratio;
            self.pending_trackpad_cursor = cursor_phys;
            self.pending_trackpad = true;
            self.trackpad_pinch_last_ns = dvui.currentWindow().frame_time_ns;
            dvui.refresh(null, @src(), self.scroll_container.data().id);
        }
    } else if (self.trackpadPinching()) {
        // No pinch event this frame but we're still inside the post-gesture window. Schedule
        // one more frame so `trackpadPinching()` transitions to false and dependent UI
        // (sprite bubbles, etc.) gets a chance to re-render in its non-pinching state.
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

    if (self.installed) {
        self.sample_viewport_physical = self.scroll_container.data().contentRectScale().r;
    }

    // Snapshot the (post-pan-slack) scroll state on confirmed-stable frames. The next
    // mid-animation install will restore from this snapshot so the canvas's pan/zoom
    // doesn't drift across explorer toggles.
    if (self.settled() and self.stable_parent_rect_frames >= 3) {
        self.stable_viewport = self.scroll_info.viewport;
        self.stable_virtual_size = self.scroll_info.virtual_size;
        self.stable_origin = self.origin;
        self.has_stable_snapshot = true;
    }

    self.installed = false;

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

/// True when `p` is inside the scroll area's visible viewport (not the panned image bounds).
pub fn samplePointerInViewport(self: *const CanvasWidget, p: dvui.Point.Physical) bool {
    if (self.installed) {
        return self.scroll_container.data().contentRectScale().r.contains(p);
    }
    if (self.sample_viewport_physical) |r| return r.contains(p);
    return false;
}

/// True when `p` is over the drawable artboard: inside the viewport and on the scaled image bounds.
pub fn pointerOverDrawable(self: *const CanvasWidget, p: dvui.Point.Physical) bool {
    return self.samplePointerInViewport(p) and self.rect.contains(p);
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

fn pointerInputSuppressed(self: *const CanvasWidget) bool {
    const hooks = self.init_opts.hooks;
    return if (hooks.pointerInputSuppressed) |f| f(hooks.ctx) else false;
}

pub fn processEvents(self: *CanvasWidget) void {

    // Apply pinch / two-finger pan deferred from this frame's `updateTouchGesture`.
    // We do it at end-of-frame so the body above rendered with stable widget state
    // (matching wheel zoom). The mutations land on `scale` / `scroll_info.viewport`,
    // and next frame's install picks them up consistently across the image, shadow,
    // and resize handle. The scale-around-point math here is identical to the wheel
    // and old inline pinch paths — only the timing changed.
    if (self.pending_pinch_zoom != 1.0) {
        const zoom = self.pending_pinch_zoom;
        const zoomP = self.pending_pinch_zoom_p;
        const prevP = self.dataFromScreenPoint(zoomP);
        var pp = prevP.scale(1 / self.scale, dvui.Point);
        self.scale *= zoom;
        pp = pp.scale(self.scale, dvui.Point);
        const newP = self.screenFromDataPoint(pp);
        const diff = self.viewportFromScreenPoint(newP).diff(self.viewportFromScreenPoint(zoomP));
        self.scroll_info.viewport.x += diff.x;
        self.scroll_info.viewport.y += diff.y;
        self.pending_pinch_zoom = 1.0;
    }
    if (self.pending_trackpad) {
        const ratio = self.pending_trackpad_ratio;
        const cursor_phys = self.pending_trackpad_cursor;
        const prevP = self.dataFromScreenPoint(cursor_phys);
        var pp = prevP.scale(1 / self.scale, dvui.Point);
        self.scale *= ratio;
        pp = pp.scale(self.scale, dvui.Point);
        const newP = self.screenFromDataPoint(pp);
        const diff = self.viewportFromScreenPoint(newP).diff(self.viewportFromScreenPoint(cursor_phys));
        self.scroll_info.viewport.x += diff.x;
        self.scroll_info.viewport.y += diff.y;
        self.pending_trackpad_ratio = 1.0;
        self.pending_trackpad = false;
    }
    if (self.pending_touch_pan.x != 0 or self.pending_touch_pan.y != 0) {
        const pdx = self.pending_touch_pan.x;
        const pdy = self.pending_touch_pan.y;
        self.scroll_info.viewport.x += pdx;
        self.scroll_info.viewport.y += pdy;
        if (self.touch_eval_pan_active or self.scroll_pan_touch_slot != null) {
            self.pan_fling_x.sampleTimed(pdx);
            self.pan_fling_y.sampleTimed(pdy);
        }
        self.pending_touch_pan = .{};
    }

    if (self.touch_eval_pan_active and !dvui.captured(self.scroll_container.data().id)) {
        dvui.captureMouse(self.scroll_container.data(), 0);
        dvui.dragPreStart(self.touch_eval_press_p, .{ .name = "scroll_drag", .cursor = .hand });
        self.pan_fling_x.begin();
        self.pan_fling_y.begin();
    }

    if (self.pointerInputSuppressed()) {
        self.hovered = false;
        self.pan_fling_x.cancel();
        self.pan_fling_y.cancel();
        // The radial menu (opened on hold below) suppresses canvas input while it's
        // up; its release/close is handled in Editor.drawRadialMenu, so just drop our
        // pending gesture state here.
        self.empty = .idle;
        return;
    }

    //const file = self.file;

    var zoom: f32 = 1;
    var zoomP: dvui.Point.Physical = .{};

    // Drag-pan movement accumulated across this frame's motion events, finalized
    // after the loop so the fling velocity is sampled once per frame.
    var pan_dx: f32 = 0;
    var pan_dy: f32 = 0;
    var pan_motion = false;
    var pan_released = false;

    if (self.scroll_pan_end_pending) {
        const scroll_id = self.scroll_container.data().id;
        if (dvui.captured(scroll_id) or dvui.dragging(dvui.currentWindow().mouse_pt, "scroll_drag") != null) {
            dvui.captureMouse(null, 0);
            dvui.dragEnd();
            pan_released = true;
        }
        self.scroll_pan_end_pending = false;
        self.scroll_pan_touch_slot = null;
        self.touch_eval_pan_active = false;
    }

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
        // Let single-finger touches that belong to an empty-area canvas pan fall
        // through to the pan handler below instead of being swallowed here: a press
        // starting off the artboard, or any touch while such a pan is captured.
        // The pan handler claims those itself, so the built-in scroll pan still
        // stays suppressed for touches over the drawable (where we want to draw).
        if (dvui.captured(self.scroll_container.data().id)) continue;
        if (me.action == .press and !self.pointerOverDrawable(me.p)) continue;
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
                    self.hovered = self.pointerOverDrawable(me.p);
                }

                // Pan the canvas on a middle-button drag, or on a left/touch drag
                // that starts in the empty scroll area (not over the artboard) —
                // same scrub-the-viewport feel as the middle-button pan.
                //
                // Exception: a left/touch off-artboard press holding ctrl/cmd (add)
                // or shift (subtract) that the owner wants to claim (pixel art: the
                // sprite-selection marquee, which already claimed the press earlier in
                // FileWidget.processSpriteSelection). Yielding it here keeps our
                // `dragPreStart("scroll_drag")` from clobbering the marquee's drag, so
                // the hotkey draws a selection box instead of panning. Middle-button
                // pans are never affected.
                const owner_yields = if (self.init_opts.hooks.yieldModifiedEmptyPress) |f|
                    f(self.init_opts.hooks.ctx)
                else
                    false;
                const sel_marquee_press = me.button.pointer() and me.button != .middle and
                    (me.mod.matchBind("ctrl/cmd") or me.mod.matchBind("shift")) and
                    owner_yields;
                if (me.action == .press and !sel_marquee_press and (me.button == .middle or (me.button.pointer() and !self.pointerOverDrawable(me.p)))) {
                    e.handle(@src(), self.scroll_container.data());
                    dvui.captureMouse(self.scroll_container.data(), e.num);
                    dvui.dragPreStart(me.p, .{ .name = "scroll_drag", .cursor = .hand });
                    self.pan_fling_x.begin();
                    self.pan_fling_y.begin();
                    if (me.button.touch()) {
                        const slot_signed = @intFromEnum(me.button) - @intFromEnum(dvui.enums.Button.touch0);
                        if (slot_signed >= 0 and slot_signed < self.touches.len) {
                            self.scroll_pan_touch_slot = @intCast(slot_signed);
                        }
                    }
                    // A non-middle (left/touch) off-artboard press may still become a tap
                    // (clear selection), a hold (radial menu), or a pan. Arm the empty
                    // gesture; it is resolved after the loop from whether the pointer is
                    // still down (for touch: the slot's `active` flag), so a swallowed
                    // release can't latch it. Skip while touch-eval owns the finger.
                    if (me.button != .middle and !self.touch_eval_active and !self.gesture_active and self.empty == .idle) {
                        self.empty = .pending;
                        self.empty_is_touch = me.button.touch();
                        self.empty_slot = if (me.button.touch()) slot: {
                            const s = @intFromEnum(me.button) - @intFromEnum(dvui.enums.Button.touch0);
                            break :slot if (s >= 0 and s < self.touches.len) @intCast(s) else 0;
                        } else 0;
                        self.empty_down = true;
                        self.empty_press_p = me.p;
                        self.empty_press_ns = dvui.frameTimeNS();
                    }
                } else if (me.action == .release and (me.button == .middle or me.button.pointer())) {
                    // Mouse releases reliably reach here, so latch the pointer up; touch
                    // instead resolves from its slot going inactive (see after the loop).
                    if (self.empty != .idle and !self.empty_is_touch) self.empty_down = false;
                    const scroll_captured = dvui.captured(self.scroll_container.data().id);
                    const scroll_dragging = dvui.dragging(me.p, "scroll_drag") != null;
                    if (scroll_captured or scroll_dragging) {
                        e.handle(@src(), self.scroll_container.data());
                        dvui.captureMouse(null, e.num);
                        dvui.dragEnd();
                        pan_released = true;
                        self.scroll_pan_touch_slot = null;
                        self.touch_eval_pan_active = false;
                    }
                } else if (me.action == .motion) {
                    if (dvui.captured(self.scroll_container.data().id)) {
                        // Claim the event so the scroll container's built-in
                        // touch-to-scroll doesn't also pan from the same finger.
                        e.handle(@src(), self.scroll_container.data());
                        if (dvui.dragging(me.p, "scroll_drag")) |dps| {
                            const rs = self.scroll_rect_scale;
                            const ddx = -dps.x / rs.s;
                            const ddy = -dps.y / rs.s;
                            self.scroll_info.viewport.x += ddx;
                            self.scroll_info.viewport.y += ddy;
                            pan_dx += ddx;
                            pan_dy += ddy;
                            pan_motion = true;
                            // Movement past the drag threshold means this is a pan, not a
                            // tap or a hold — drop the candidacy; the pan is already running.
                            if (self.empty == .pending) self.empty = .idle;
                            dvui.refresh(null, @src(), self.scroll_container.data().id);
                        }
                    }
                } else if (me.action == .wheel_y or me.action == .wheel_x) {
                    switch (self.init_opts.pan_zoom_scheme) {
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

    // ---- Drag-pan momentum. Record each moved frame into the per-axis position/time
    // history, decide on release whether to coast from a velocity averaged over a
    // wall-clock window, and advance an in-flight coast — each axis is independent so a
    // mostly-horizontal flick doesn't drift vertically. Sampling, release, and the step
    // happen in sequence here (not split across a draw pass), so a coincident
    // move+release frame samples the final move before the coast starts — no race. ----
    if (pan_motion) {
        self.pan_fling_x.sampleTimed(pan_dx);
        self.pan_fling_y.sampleTimed(pan_dy);
    }
    if (pan_released) {
        _ = self.pan_fling_x.releaseWindowed(pan_fling, pan_fling_window_s);
        _ = self.pan_fling_y.releaseWindowed(pan_fling, pan_fling_window_s);
    }
    if (self.pan_fling_x.coasting or self.pan_fling_y.coasting) {
        if (self.pan_fling_x.step(pan_fling)) |dx| self.scroll_info.viewport.x += dx;
        if (self.pan_fling_y.step(pan_fling)) |dy| self.scroll_info.viewport.y += dy;
        dvui.refresh(null, @src(), self.scroll_container.data().id);
    }

    // ---- Resolve the empty-canvas gesture: a still hold opens the radial tool menu,
    // a quick lift without moving clears the selection, and a moved press already
    // became a pan above. Resolution is keyed off whether the pointer is still down —
    // for touch that's the slot's `active` flag (set in `updateTouchGesture` earlier
    // this frame), so it never depends on a release event reaching this loop. ----
    if (self.empty != .idle) {
        const still_down = if (self.empty_is_touch)
            self.touches[self.empty_slot].active
        else
            self.empty_down;

        switch (self.empty) {
            .pending => {
                if (!still_down) {
                    // Lifted without moving or holding → a tap: hand to the owner (pixel
                    // art clears the selection).
                    if (self.init_opts.hooks.onEmptyTap) |f| f(self.init_opts.hooks.ctx);
                    self.empty = .idle;
                } else if (dvui.frameTimeNS() - self.empty_press_ns >= dvui.currentWindow().hold_menu_duration_ns) {
                    // Held in place past the hold duration → tell the owner (pixel art opens
                    // its radial tool menu at the press point) and release our capture so its
                    // buttons can be hovered.
                    if (self.init_opts.hooks.onEmptyHold) |f| f(self.init_opts.hooks.ctx, self.empty_press_p);
                    self.empty = .holding;
                    if (dvui.captured(self.scroll_container.data().id)) {
                        dvui.captureMouse(null, 0);
                        dvui.dragEnd();
                    }
                    self.pan_fling_x.cancel();
                    self.pan_fling_y.cancel();
                    self.scroll_pan_touch_slot = null;
                } else {
                    // Keep frames coming so the hold timer ticks on an otherwise idle press.
                    dvui.refresh(null, @src(), self.scroll_container.data().id);
                }
            },
            .holding => if (!still_down) {
                self.empty = .idle;
            },
            .idle => {},
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
    //
    // Also skip while the workspace pane is mid-animation. The pan-slack bbox math
    // adjusts `viewport.y` / `origin.y` to keep the canvas centered in its scroll area,
    // but the math assumes the parent rect is stable. When the explorer is peeking
    // open/closed in collapsed mode, the workspace's rect changes every frame for the
    // duration of the animation and any pan-slack run mid-animation leaks pixels of
    // drift that accumulate into the canvas sliding off-screen over many open/close
    // cycles. We require N stable frames before allowing pan-slack to run again.
    const parent_is_stable_now = self.stable_parent_rect_frames >= 3;
    if (!self.scroll_info.viewport.empty() and !(self.settled() and !parent_is_stable_now)) {
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
