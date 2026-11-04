//! The std-only rule behind a settings or store field row: narrow rows stack their control
//! below the label, while a dead band keeps resizing from flipping the layout on every pixel.
const std = @import("std");

pub const stack_below: f32 = 420;
pub const dead_band: f32 = 24;
pub const control_w: f32 = 200;
pub const control_share: f32 = 0.45;

/// Inside the dead band, keep the previous layout.
pub fn stacked(prev: bool, w: f32) bool {
    const half = dead_band / 2;
    if (w < stack_below - half) return true;
    if (w >= stack_below + half) return false;
    return prev;
}

/// Limit the control column to its share of the row or its preferred width.
pub fn controlWidth(w: f32) f32 {
    return @min(control_w, w * control_share);
}

test "stacked flips only outside the dead band" {
    try std.testing.expectEqual(true, stacked(false, 407));
    try std.testing.expectEqual(false, stacked(false, 408));
    try std.testing.expectEqual(true, stacked(true, 431));
    try std.testing.expectEqual(false, stacked(true, 432));
    try std.testing.expectEqual(true, stacked(true, 420));
    try std.testing.expectEqual(false, stacked(false, 420));
}

test "the control column is 200 or 45 percent of the row, whichever is less" {
    try std.testing.expectEqual(@as(f32, 200), controlWidth(600));
    try std.testing.expectEqual(@as(f32, 180), controlWidth(400));
}
