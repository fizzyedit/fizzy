//! When a pane swaps to different content — another store page, another document tab, another
//! center provider — dvui needs one frame to learn the new subtree's sizes. Widget rects come
//! from the *previous* frame's min-size cache, and a widget id that didn't exist last frame has
//! no entry, so it lays out at zero and snaps to the right size on the next frame. That is the
//! visible flash: a store detail page drawing once with no header, a document appearing at the
//! wrong offset before settling.
//!
//! `CanvasWidget` already solved this for one case (see its `canvas_reveal` animation): hide the
//! content while it settles, then fade it up fast enough to read as "it was always there". This
//! is that policy, extracted so every content swap can share it.
//!
//! The phase machine is the whole decision, and it is pure — dvui's data store and animation
//! system only supply the inputs (`core.anim.reveal` does that part).
const std = @import("std");

pub const Phase = enum {
    /// Content is laid out but not drawn. Exactly one frame, right after the key changes.
    hidden,
    /// Settling is done; alpha ramps 0 → 1.
    fading,
    /// Fully visible, nothing animating.
    shown,
};

/// The phase for this frame.
///
/// `prev_key` is null on the very first frame a given pane draws. A first appearance reveals the
/// same way a swap does: the subtree is equally new to dvui either way, so it flashes identically
/// without it.
pub fn next(prev_key: ?u64, key: u64, prev_phase: Phase, animation_running: bool) Phase {
    const key_changed = prev_key == null or prev_key.? != key;
    if (key_changed) return .hidden;
    return switch (prev_phase) {
        // One hidden frame is enough: the min-size cache is populated by the end of it.
        .hidden => .fading,
        .fading => if (animation_running) .fading else .shown,
        .shown => .shown,
    };
}

const testing = std.testing;

test "a first appearance hides for one frame, then fades" {
    try testing.expectEqual(Phase.hidden, next(null, 7, .shown, false));
    try testing.expectEqual(Phase.fading, next(7, 7, .hidden, true));
}

test "a key change restarts the reveal from any phase" {
    try testing.expectEqual(Phase.hidden, next(7, 8, .shown, false));
    try testing.expectEqual(Phase.hidden, next(7, 8, .fading, true));
    try testing.expectEqual(Phase.hidden, next(7, 8, .hidden, false));
}

test "fading ends only when the animation does" {
    try testing.expectEqual(Phase.fading, next(7, 7, .fading, true));
    try testing.expectEqual(Phase.shown, next(7, 7, .fading, false));
}

test "unchanged content stays shown and never re-reveals" {
    try testing.expectEqual(Phase.shown, next(7, 7, .shown, false));
    // An animation left over from elsewhere must not drag a settled pane back into fading.
    try testing.expectEqual(Phase.shown, next(7, 7, .shown, true));
}
