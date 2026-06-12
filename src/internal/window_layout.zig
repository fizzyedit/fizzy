//! Pure window-layout decisions extracted from the macOS windowing code
//! (`backend_native.zig` + `objc/FizzyWindowMonitor.m`), so the "+/- titlebar
//! height" math is testable without a window. std-only — pulled in by
//! `tests/root.zig` and called from `backend_native.zig` (which keeps the
//! AppKit/SDL plumbing). See `src/internal/window_layout` notes in the plan.

const std = @import("std");

/// Inputs to the titlebar-strip height decision. All already resolved from
/// AppKit/SDL by the caller so this stays pure. Insets are in points; 0 means
/// "no usable value" (caller passes 0 when the source returned <= 0).
pub const StripInputs = struct {
    /// Chrome is hidden (fullscreen Space, entering, or pending) — strip is just the buffer.
    collapsed: bool,
    /// We are animating chrome back in (unzoom / Space exit) — prefer the saved
    /// inset over the live one, which still reads the fullscreen (0) value mid-morph.
    restoring_chrome: bool,
    /// Live AppKit titlebar inset for the current frame (0 if unavailable / fullscreen).
    live_inset: f32,
    /// Inset captured before the last enter, used while the live value is unreliable.
    saved_inset: f32,
    titlebar_height: f32,
    titlebar_top_buffer: f32,
};

/// Height of the top strip that keeps editor content clear of the traffic
/// lights. Port of the branching previously inlined in
/// `backend_native.titlebarStripHeight`.
pub fn chooseTitlebarStrip(in: StripInputs) f32 {
    if (in.collapsed) return in.titlebar_top_buffer;

    const min_strip = in.titlebar_top_buffer + in.titlebar_height;
    const appkit: f32 = if (in.restoring_chrome)
        (if (in.saved_inset > 0) in.saved_inset else if (in.live_inset > 0) in.live_inset else 0)
    else if (in.live_inset > 0)
        in.live_inset
    else if (in.saved_inset > 0)
        in.saved_inset
    else
        0;
    return @max(min_strip, appkit);
}

/// AppKit screen-coordinate rectangle (bottom-left origin). A frame's top edge
/// is `y + h`. Matches `NSRect` field order/semantics so the C-ABI wrapper in
/// `backend_native.zig` can forward `window.frame` straight through.
pub const Rect = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
};

pub fn pointInAnyRect(px: f64, py: f64, rects: []const Rect) bool {
    for (rects) |r| {
        if (px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h) return true;
    }
    return false;
}

/// Guards against restoring fizzy's saved window frame onto a display that is no
/// longer connected (e.g. an external monitor that was unplugged). True when the
/// centre of the frame's top strip — where the traffic lights / drag region live
/// — lands on one of the connected screens, so the window is reachable and
/// draggable. `screens` are NSScreen frames in AppKit bottom-left coords; the
/// top edge of a frame is `y + h`, so the strip sits just below it.
pub fn frameTitleReachable(frame: Rect, screens: []const Rect) bool {
    if (frame.w < 1 or frame.h < 1) return false;
    const cx = frame.x + frame.w / 2.0;
    const cy = frame.y + frame.h - 10.0;
    return pointInAnyRect(cx, cy, screens);
}

/// True when AppKit's `-constrainFrameRect:toScreen:` result is just the
/// "keep the titlebar below the menu bar" nudge applied to a top-anchored
/// full-size-content window — the case we want to undo so our frame can reach
/// the usable top. `requested` is the frame we asked for, `constrained` is what
/// AppKit returned, both in AppKit bottom-left coords (top edge = `y + h`).
/// `visible_top` is `NSMaxY(screen.visibleFrame)` — the highest a normal titlebar
/// may reach. `titlebar_max` bounds how far down counts as the nudge (a real
/// reposition is larger); `tol` is the float-compare slack.
///
/// Fires only when: AppKit lowered the top, the requested top was no higher than
/// the usable top (so we never push content under the menu bar), the drop is
/// within a titlebar, and x/width are unchanged (a real move/resize is left
/// alone). The caller then restores `requested`'s top edge.
pub fn constrainResultIsMenuBarNudge(
    requested: Rect,
    constrained: Rect,
    visible_top: f64,
    titlebar_max: f64,
    tol: f64,
) bool {
    const want_top = requested.y + requested.h;
    const got_top = constrained.y + constrained.h;
    const lowered = want_top > got_top + tol;
    const at_or_below_usable_top = want_top <= visible_top + tol;
    const within_titlebar = (want_top - got_top) <= titlebar_max;
    const same_x = @abs(requested.x - constrained.x) < tol;
    const same_w = @abs(requested.w - constrained.w) < tol;
    return lowered and at_or_below_usable_top and within_titlebar and same_x and same_w;
}

/// True when the window's origin differs from the captured pre-fullscreen origin
/// by a small amount — AppKit's exit nudge — and so should be re-asserted. A zero
/// delta (already correct) returns false, as does a large delta (a real move we
/// must not fight). `max_delta` is the largest nudge we will undo.
pub fn originNudged(cap_x: f64, cap_y: f64, cur_x: f64, cur_y: f64, max_delta: f64) bool {
    const dx = @abs(cap_x - cur_x);
    const dy = @abs(cap_y - cur_y);
    if (dx == 0 and dy == 0) return false;
    return dx <= max_delta and dy <= max_delta;
}

test "chooseTitlebarStrip collapsed returns just the buffer" {
    const got = chooseTitlebarStrip(.{
        .collapsed = true,
        .restoring_chrome = false,
        .live_inset = 28,
        .saved_inset = 28,
        .titlebar_height = 24,
        .titlebar_top_buffer = 6,
    });
    try std.testing.expectEqual(@as(f32, 6), got);
}

test "chooseTitlebarStrip steady state floors at buffer+height" {
    // No usable inset -> min_strip wins.
    const got = chooseTitlebarStrip(.{
        .collapsed = false,
        .restoring_chrome = false,
        .live_inset = 0,
        .saved_inset = 0,
        .titlebar_height = 24,
        .titlebar_top_buffer = 6,
    });
    try std.testing.expectEqual(@as(f32, 30), got);
}

test "chooseTitlebarStrip prefers live inset when larger than min" {
    const got = chooseTitlebarStrip(.{
        .collapsed = false,
        .restoring_chrome = false,
        .live_inset = 40,
        .saved_inset = 28,
        .titlebar_height = 24,
        .titlebar_top_buffer = 6,
    });
    try std.testing.expectEqual(@as(f32, 40), got);
}

test "chooseTitlebarStrip restoring prefers saved over stale live" {
    // Mid Space-exit the live inset still reads fullscreen (0); saved carries the
    // real value and must win.
    const got = chooseTitlebarStrip(.{
        .collapsed = false,
        .restoring_chrome = true,
        .live_inset = 0,
        .saved_inset = 38,
        .titlebar_height = 24,
        .titlebar_top_buffer = 6,
    });
    try std.testing.expectEqual(@as(f32, 38), got);
}

test "chooseTitlebarStrip restoring falls back to live when no saved" {
    const got = chooseTitlebarStrip(.{
        .collapsed = false,
        .restoring_chrome = true,
        .live_inset = 33,
        .saved_inset = 0,
        .titlebar_height = 24,
        .titlebar_top_buffer = 6,
    });
    try std.testing.expectEqual(@as(f32, 33), got);
}

test "frameTitleReachable accepts a frame on the main screen" {
    const screens = [_]Rect{.{ .x = 0, .y = 0, .w = 1800, .h = 1169 }};
    // Maximized-ish window pinned to the bottom, top strip near 1130.
    const frame: Rect = .{ .x = 0, .y = 39, .w = 1800, .h = 1091 };
    try std.testing.expect(frameTitleReachable(frame, &screens));
}

test "frameTitleReachable accepts a frame on a secondary screen" {
    const screens = [_]Rect{
        .{ .x = 0, .y = 0, .w = 1800, .h = 1169 },
        .{ .x = 1800, .y = 0, .w = 2560, .h = 1440 },
    };
    const frame: Rect = .{ .x = 2000, .y = 200, .w = 800, .h = 600 };
    try std.testing.expect(frameTitleReachable(frame, &screens));
}

test "frameTitleReachable rejects a frame whose top strip is off all screens" {
    // The secondary display was unplugged; only the main screen remains.
    const screens = [_]Rect{.{ .x = 0, .y = 0, .w = 1800, .h = 1169 }};
    const frame: Rect = .{ .x = 2400, .y = 300, .w = 800, .h = 600 };
    try std.testing.expect(!frameTitleReachable(frame, &screens));
}

test "frameTitleReachable rejects an empty frame" {
    const screens = [_]Rect{.{ .x = 0, .y = 0, .w = 1800, .h = 1169 }};
    try std.testing.expect(!frameTitleReachable(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, &screens));
}

test "frameTitleReachable rejects when no screens at all" {
    const screens = [_]Rect{};
    try std.testing.expect(!frameTitleReachable(.{ .x = 0, .y = 0, .w = 800, .h = 600 }, &screens));
}

test "constrainResultIsMenuBarNudge detects the titlebar nudge at the usable top" {
    // visibleFrame top = 1130. We asked for a frame topped at 1130; AppKit lowered
    // the top to 1098 (a 32px titlebar) keeping x/width.
    const requested: Rect = .{ .x = 0, .y = 0, .w = 1800, .h = 1130 }; // top = 1130
    const constrained: Rect = .{ .x = 0, .y = 0, .w = 1800, .h = 1098 }; // top = 1098
    try std.testing.expect(constrainResultIsMenuBarNudge(requested, constrained, 1130, 40, 0.5));
}

test "constrainResultIsMenuBarNudge ignores an unchanged result" {
    const r: Rect = .{ .x = 100, .y = 100, .w = 800, .h = 600 };
    try std.testing.expect(!constrainResultIsMenuBarNudge(r, r, 1130, 40, 0.5));
}

test "constrainResultIsMenuBarNudge ignores a drop larger than a titlebar" {
    // A 60px drop is not the menu-bar nudge (a real reposition); leave it alone.
    const requested: Rect = .{ .x = 0, .y = 0, .w = 1800, .h = 1130 }; // top = 1130
    const constrained: Rect = .{ .x = 0, .y = 0, .w = 1800, .h = 1070 }; // top = 1070
    try std.testing.expect(!constrainResultIsMenuBarNudge(requested, constrained, 1130, 40, 0.5));
}

test "constrainResultIsMenuBarNudge ignores a frame requested above the usable top" {
    // Requested top 1160 is above the usable top 1130 — we must not pull content
    // up under the menu bar, so AppKit's lowering stands.
    const requested: Rect = .{ .x = 0, .y = 30, .w = 1800, .h = 1130 }; // top = 1160
    const constrained: Rect = .{ .x = 0, .y = 0, .w = 1800, .h = 1130 }; // top = 1130
    try std.testing.expect(!constrainResultIsMenuBarNudge(requested, constrained, 1130, 40, 0.5));
}

test "constrainResultIsMenuBarNudge ignores a horizontal/width change" {
    // x changed -> a real move, not the nudge.
    const requested: Rect = .{ .x = 0, .y = 0, .w = 1800, .h = 1130 };
    const constrained: Rect = .{ .x = 40, .y = 0, .w = 1800, .h = 1098 };
    try std.testing.expect(!constrainResultIsMenuBarNudge(requested, constrained, 1130, 40, 0.5));
}

test "originNudged detects a small nudge" {
    // Down 32px (titlebar): re-assert.
    try std.testing.expect(originNudged(100, 200, 100, 168, 64));
}

test "originNudged ignores an exact match" {
    try std.testing.expect(!originNudged(100, 200, 100, 200, 64));
}

test "originNudged ignores a large move" {
    // 200px move is the user repositioning, not the nudge.
    try std.testing.expect(!originNudged(100, 200, 100, 0, 64));
}
