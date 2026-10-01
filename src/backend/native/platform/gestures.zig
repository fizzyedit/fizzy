//! Trackpad gestures SDL does not deliver — on macOS, the pinch (magnify) — gathered as they
//! arrive and drained once a frame by whatever zooms.
const std = @import("std");
const builtin = @import("builtin");

// AppKit's local monitor for magnify events (installed by `installTrackpadGestureMonitor`,
// `objc/FizzyTrackpadGesture.m`) calls back here for each magnification delta. We accumulate
// a single multiplicative ratio that the canvas widget drains and applies per frame.
//
// Storage is the bit pattern of an f64 (initial = 1.0) in an atomic u64. NSEvent local
// monitors run on the AppKit event-pump thread (main, for SDL), and we drain on the same
// main thread inside the frame, so the RMW below is single-threaded in practice — the
// atomic is a guardrail against a future change moving the producer side.
var pending_pinch_ratio_bits: std.atomic.Value(u64) = .init(@bitCast(@as(f64, 1.0)));

/// Called from `objc/FizzyTrackpadGesture.m` for every magnify event. `delta` is the relative
/// magnification reported by AppKit for that single event (small per-event values that
/// compound multiplicatively across the gesture).
export fn FizzyTrackpadMagnification(delta: f64) void {
    if (delta == 0.0) return;
    const current: f64 = @bitCast(pending_pinch_ratio_bits.load(.acquire));
    const next = current * (1.0 + delta);
    pending_pinch_ratio_bits.store(@bitCast(next), .release);
}

// Conditional declaration so non-macOS native targets (which don't compile the .m source) don't
// pull in an unresolved external symbol at link time.
const fizzy_install_trackpad_gesture_monitor = if (builtin.os.tag == .macos) struct {
    extern fn FizzyInstallTrackpadGestureMonitor() void;
    fn install() void {
        FizzyInstallTrackpadGestureMonitor();
    }
}.install else struct {
    fn install() void {}
}.install;

/// Install a process-wide AppKit local monitor for trackpad pinch events. Safe to call multiple
/// times — the monitor is one-shot. No-op on non-macOS targets.
pub fn installTrackpadGestureMonitor() void {
    fizzy_install_trackpad_gesture_monitor();
}

/// Drain the accumulated trackpad pinch zoom ratio (>1.0 = zoom in, <1.0 = zoom out). Multiply
/// canvas scale by this and adjust the focal point to match. Returns 1.0 if no pinch input has
/// arrived since the last call.
pub fn takeTrackpadPinchRatio() f32 {
    const one_bits: u64 = @bitCast(@as(f64, 1.0));
    const prev_bits = pending_pinch_ratio_bits.swap(one_bits, .acq_rel);
    return @floatCast(@as(f64, @bitCast(prev_bits)));
}
