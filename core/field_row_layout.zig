//! The std-only rule behind a settings or store field row: narrow rows stack their control
//! below the label, and a dead band keeps small width changes from flipping the layout.
const std = @import("std");

/// The row width in points around which the layout changes.
pub const stack_below: f32 = 420;
/// Width in points over which the previous layout holds.
pub const dead_band: f32 = 24;
/// Maximum control column width in points.
pub const control_w: f32 = 200;
/// Maximum fraction of the row width given to the control column.
pub const control_share: f32 = 0.45;

/// Whether the control sits below the label, keeping `prev` inside the dead band.
pub fn stacked(prev: bool, w: f32) bool {
    const half = dead_band / 2;
    if (w < stack_below - half) return true;
    if (w >= stack_below + half) return false;
    return prev;
}

/// The control column's width in points, capped by its share of the row.
pub fn controlWidth(w: f32) f32 {
    return @min(control_w, w * control_share);
}

test "stacked flips only outside the dead band" {
    try std.testing.expect(stacked(false, 407));
    try std.testing.expect(!stacked(false, 408));
    try std.testing.expect(stacked(true, 431));
    try std.testing.expect(!stacked(true, 432));
    try std.testing.expect(stacked(true, 420));
    try std.testing.expect(!stacked(false, 420));
}

test "the control column is 200 or 45 percent of the row, whichever is less" {
    try std.testing.expectEqual(@as(f32, 200), controlWidth(600));
    try std.testing.expectEqual(@as(f32, 180), controlWidth(400));
}
