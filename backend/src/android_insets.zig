//! Android's on-screen keyboard inset: how far the keyboard covers the window's bottom, in
//! points. `FizzyActivity` reports the IME and navigation bar insets from the Java UI thread,
//! each step of the keyboard's animation; the frame reads the latest (`keyboardInset`). std-only.

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

fn nativeInsets(_: ?*anyopaque, _: ?*anyopaque, ime_px: f32, nav_px: f32, density: f32) callconv(.c) void {
    const bits: u32 = @bitCast(points(ime_px, nav_px, density));
    if (latest.swap(bits, .monotonic) == bits) return;
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
