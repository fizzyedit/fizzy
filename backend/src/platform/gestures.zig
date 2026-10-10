//! Trackpad and touch gestures, gathered as SDL reports them and drained once a frame by whatever
//! zooms: the pinch (SDL's `SDL_EVENT_PINCH_*`, from a macOS trackpad, iOS, and Linux under
//! Wayland or X11; Windows reports a precision touchpad's pinch as ctrl+wheel instead).
//!
//! SDL hands these to the backend's event loop, which no backend does anything with yet — dvui's
//! gesture event is still to come (david-vanderson/dvui#1000) — so they are watched for here
//! (`SDL_AddEventWatch`), under whichever backend the app runs. When dvui routes gestures to the
//! widget under them, a widget can take them from there instead and this drain goes.
const std = @import("std");
const c = @import("backend").c;

// One multiplicative ratio — every pinch update's scale multiplied in — that the canvas drains
// and applies once a frame. Stored as an f64's bits in an atomic u64: the watch runs on the
// thread that pumps SDL's events (the main one) and the frame drains on the same thread, so the
// update is single-threaded in practice; the atomic guards against that ever changing.
var pending_pinch_ratio_bits: std.atomic.Value(u64) = .init(@bitCast(@as(f64, 1.0)));
var installed = false;

fn pinchWatch(_: ?*anyopaque, event: ?*c.SDL_Event) callconv(.c) bool {
    const e = event orelse return true;
    if (e.type != c.SDL_EVENT_PINCH_UPDATE) return true;
    const scale: f64 = e.pinch.scale;
    if (scale <= 0 or scale == 1) return true;
    const current: f64 = @bitCast(pending_pinch_ratio_bits.load(.acquire));
    pending_pinch_ratio_bits.store(@bitCast(current * scale), .release);
    // A watch's return is ignored; the event goes on to the backend either way.
    return true;
}

/// Start watching for pinches. Safe to call more than once.
pub fn installTrackpadGestureMonitor() void {
    if (installed) return;
    installed = true;
    _ = c.SDL_AddEventWatch(pinchWatch, null);
}

/// Drain the accumulated pinch zoom ratio (>1.0 = zoom in, <1.0 = zoom out). Multiply a canvas'
/// scale by this and adjust the focal point to match. 1.0 when no pinch has arrived since the
/// last call.
pub fn takeTrackpadPinchRatio() f32 {
    const one_bits: u64 = @bitCast(@as(f64, 1.0));
    const prev_bits = pending_pinch_ratio_bits.swap(one_bits, .acq_rel);
    return @floatCast(@as(f64, @bitCast(prev_bits)));
}
