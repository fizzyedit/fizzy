//! Visibility of glass ink in physical pixels, including its antialiasing fringe.
const std = @import("std");
const dvui = @import("dvui");

/// Physical antialiasing fringe included when testing glass ink against the clip.
pub const fringe_px: f32 = 1;

/// True when physical ink meets the clip grown by `margin_px` on both axes.
pub fn within(ink: dvui.Rect.Physical, clip: dvui.Rect.Physical, margin_px: f32) bool {
    return ink.x <= clip.x + clip.w + margin_px and ink.x + ink.w >= clip.x - margin_px and
        ink.y <= clip.y + clip.h + margin_px and ink.y + ink.h >= clip.y - margin_px;
}

/// True when ink reaches the current, non-empty clip, including the physical fringe.
pub fn reaches(ink: dvui.Rect.Physical) bool {
    const clip = dvui.clipGet();
    return !clip.empty() and within(ink, clip, fringe_px);
}

test "ink must reach both axes, with the same margins in core and the backend" {
    try std.testing.expectEqual(fringe_px, @import("glass").BlurBackdrop.fringe_px);
    const clip: dvui.Rect.Physical = .{ .x = 20, .y = 30, .w = 40, .h = 50 };
    for ([_]f32{ 1, 11 }) |margin| {
        for ([_]dvui.Rect.Physical{
            .{ .x = 20 - margin, .y = 40, .w = 0, .h = 1 },
            .{ .x = 60 + margin, .y = 40, .w = 0, .h = 1 },
            .{ .x = 40, .y = 30 - margin, .w = 1, .h = 0 },
            .{ .x = 40, .y = 80 + margin, .w = 1, .h = 0 },
        }) |edge| {
            for ([_]f32{ -0.25, 0, 0.25 }) |delta| {
                var ink = edge;
                if (ink.w == 0) ink.x += if (ink.x < clip.x) -delta else delta;
                if (ink.h == 0) ink.y += if (ink.y < clip.y) -delta else delta;
                try std.testing.expectEqual(delta <= 0, within(ink, clip, margin));
                try std.testing.expectEqual(within(ink, clip, margin), @import("glass").BlurBackdrop.inkWithin(ink, clip, margin));
            }
        }
        for ([_]dvui.Rect.Physical{
            .{ .x = 0, .y = 40, .w = 1, .h = 1 },
            .{ .x = 80, .y = 40, .w = 1, .h = 1 },
            .{ .x = 40, .y = 0, .w = 1, .h = 1 },
            .{ .x = 40, .y = 100, .w = 1, .h = 1 },
        }) |ink| {
            try std.testing.expect(!within(ink, clip, margin));
            try std.testing.expectEqual(within(ink, clip, margin), @import("glass").BlurBackdrop.inkWithin(ink, clip, margin));
        }
    }
}
