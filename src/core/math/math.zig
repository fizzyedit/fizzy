const zm = @import("zmath");
const std = @import("std");
const dvui = @import("dvui");

// Returns true if the pixel would be color 1 of a checkerboard pattern
// Returns false if the pixel would be color 2 of a checkerboard pattern
pub fn checker(size: dvui.Size, index: usize) bool {
    // Get the image width as usize
    const w = @as(usize, @intFromFloat(size.w));
    // Compute y (row) and x (column) from the index
    const y = index / w;
    const x = index % w;
    // Checkerboard: light if (x + y) is even, dark if odd
    return ((x + y) & 1) == 0;
}

pub fn rotate(point: dvui.Point, origin: dvui.Point, radians: f32) dvui.Point {
    if (radians == 0) return point;

    const cos = @cos(radians);
    const sin = @sin(radians);

    // get vector from origin to point
    const d = point.diff(origin);

    // rotate vector
    const rotated: dvui.Point = .{
        .x = d.x * cos - d.y * sin,
        .y = d.x * sin + d.y * cos,
    };

    return origin.plus(rotated);
}

pub const sqrt2: f32 = 1.414213562373095;

pub const Direction = @import("direction.zig").Direction;

const color = @import("color.zig");
pub const Color = color.Color;
pub const Colors = color.Colors;
pub const blendPmaSrcOver = color.blendPmaSrcOver;

pub const Point = struct { x: i32, y: i32 };

// Pure scalar easing/lerp helpers live in a sibling file so `zig build
// test` can exercise them without pulling in dvui. Re-exported here to
// keep existing call sites unchanged.
const easing = @import("easing.zig");
pub const EaseType = easing.EaseType;
pub const lerp = easing.lerp;
pub const ease = easing.ease;

pub const layout_anchor = @import("layout_anchor.zig");
