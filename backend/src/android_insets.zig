//! Android's on-screen keyboard inset: how far the keyboard covers the window's bottom, in
//! points. `FizzyActivity` reports the IME and navigation bar insets from the Java UI thread,
//! each step of the keyboard's animation; the frame reads the latest (`keyboardInset`). Full
//! screen, it reports the display cutout too (`safeInsets`). std-only.

const std = @import("std");
const builtin = @import("builtin");

/// Called on the Java UI thread when the inset changes, to wake the frame loop. Must be safe
/// from any thread; never touches dvui. Atomic because the backend stores it on SDL's thread
/// while the activity's listener may already be reporting.
pub var wake: std.atomic.Value(?*const fn () void) = .init(null);

/// The latest inset in points, as the bits of an f32: written on the Java UI thread, read on the
/// frame's.
var latest: std.atomic.Value(u32) = .init(@bitCast(@as(f32, 0)));

/// The keyboard's cover of the window in points: the IME's inset above the navigation bar's,
/// which the activity's bottom padding already lifts the surface above. Both insets are in pixels.
pub fn points(ime_px: f32, nav_px: f32, density: f32) f32 {
    return @max(0, ime_px - nav_px) / density;
}

/// How far the on-screen keyboard covers the window's bottom now, in points; 0 with none.
pub fn keyboardInset() f32 {
    return @bitCast(latest.load(.monotonic));
}

/// Where the display's cutout lies while the app is full screen, in points; zero when the bars
/// show, because the activity already pads the window clear of them.
pub const Safe = struct { top: f32 = 0, left: f32 = 0, right: f32 = 0, bottom: f32 = 0 };

/// The cutout's insets, in pixels, as points; never negative.
pub fn safePoints(left_px: f32, top_px: f32, right_px: f32, bottom_px: f32, density: f32) Safe {
    return .{
        .top = @max(0, top_px) / density,
        .left = @max(0, left_px) / density,
        .right = @max(0, right_px) / density,
        .bottom = @max(0, bottom_px) / density,
    };
}

/// The latest safe insets in points, each as the bits of an f32 (top, left, right, bottom):
/// written on the Java UI thread, read on the frame's. A frame may read a half-written set; the
/// write's wake brings the next frame, which reads it whole.
var latest_safe: [4]std.atomic.Value(u32) = @splat(.init(@bitCast(@as(f32, 0))));

/// The display cutout's insets now, in points; zero when the bars show or off full screen.
pub fn safeInsets() Safe {
    return .{
        .top = @bitCast(latest_safe[0].load(.monotonic)),
        .left = @bitCast(latest_safe[1].load(.monotonic)),
        .right = @bitCast(latest_safe[2].load(.monotonic)),
        .bottom = @bitCast(latest_safe[3].load(.monotonic)),
    };
}

fn nativeInsets(
    _: ?*anyopaque,
    _: ?*anyopaque,
    ime_px: f32,
    nav_px: f32,
    density: f32,
    safe_left_px: f32,
    safe_top_px: f32,
    safe_right_px: f32,
    safe_bottom_px: f32,
) callconv(.c) void {
    const bits: u32 = @bitCast(points(ime_px, nav_px, density));
    var changed = latest.swap(bits, .monotonic) != bits;
    const safe = safePoints(safe_left_px, safe_top_px, safe_right_px, safe_bottom_px, density);
    for (&latest_safe, [4]f32{ safe.top, safe.left, safe.right, safe.bottom }) |*slot, v| {
        const v_bits: u32 = @bitCast(v);
        if (slot.swap(v_bits, .monotonic) != v_bits) changed = true;
    }
    if (!changed) return;
    if (wake.load(.acquire)) |f| f();
}

comptime {
    // The activity's Java package stays `dev.fizzyedit.hello` (build/android.zig).
    if (builtin.target.abi.isAndroid()) @export(&nativeInsets, .{ .name = "Java_dev_fizzyedit_hello_FizzyActivity_nativeInsets" });
}

test "keyboard inset is the IME above the navigation bar, in points" {
    try std.testing.expectEqual(@as(f32, 0), points(0, 63, 2.625));
    try std.testing.expectEqual(@as(f32, 0), points(63, 63, 2.625));
    try std.testing.expectEqual(@as(f32, 320), points(903, 63, 2.625));
    try std.testing.expectEqual(@as(f32, 500), points(1000, 0, 2));
}

test "safe insets are the cutout in points" {
    try std.testing.expectEqual(Safe{ .top = 40 }, safePoints(0, 105, 0, 0, 2.625));
    try std.testing.expectEqual(Safe{ .top = 50, .left = 12, .right = 8, .bottom = 1 }, safePoints(24, 100, 16, 2, 2));
}

test "a negative safe inset clamps to 0" {
    try std.testing.expectEqual(Safe{ .left = 10 }, safePoints(20, -4, -1, -100, 2));
}
