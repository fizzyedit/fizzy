//! A raised or inset edge: the shade and light round a control's outline that make it stand off
//! its background or sink into it, lit from the top left. A raised control catches light on the
//! sides that face the light and casts shade off the sides that face away; an inset well is the
//! other way round, its near wall in shade and its far wall lit.
//!
//! The look is a ring of rings from the outline (outward for raised, inward for inset), each
//! vertex coloured by which way the outline faces there (`weights`) and fading across the ring
//! (`fall`). `core.draw.drawEdge` builds it; this file is the arithmetic, std-only, so it tests
//! without a window (`build/app.zig`, `fizzy-edge-tests`).
const std = @import("std");

pub const Kind = enum { raised, inset };

/// The unit direction the light comes from: the top left, y down.
pub const light_from: [2]f32 = .{ -std.math.sqrt1_2, -std.math.sqrt1_2 };

/// The rings across the edge, as fractions of its depth from the outline: closer together near
/// the outline, where the fade is steepest.
pub const ring_steps = [_]f32{ 0, 0.12, 0.28, 0.48, 0.72, 1.0 };

/// The edge's strength at ring fraction `x`: full at the outline, none at its far side, falling
/// fastest at first, as a soft shadow does.
pub fn fall(x: f32) f32 {
    const f = 1 - std.math.clamp(x, 0, 1);
    return f * f;
}

/// How much shade and light a point of the outline gets.
pub const Weights = struct { shade: f32, light: f32 };

/// The weights where the outline's outward unit normal is `normal`. A straight side facing the
/// light or away from it gets the whole of one; round a corner one hands to the other through
/// nothing at 45°, so a side never ends in a seam.
pub fn weights(kind: Kind, normal: [2]f32) Weights {
    const toward = normal[0] * light_from[0] + normal[1] * light_from[1];
    // A side's normal is 45° off the light, so its dot is √½: scaled to a whole weight.
    const w = std.math.clamp(toward * std.math.sqrt2, -1, 1);
    const lit = @max(0, w);
    const away = @max(0, -w);
    return switch (kind) {
        .raised => .{ .shade = away, .light = lit },
        .inset => .{ .shade = lit, .light = away },
    };
}

const top: [2]f32 = .{ 0, -1 };
const left: [2]f32 = .{ -1, 0 };
const bottom: [2]f32 = .{ 0, 1 };
const right: [2]f32 = .{ 1, 0 };

fn expectWeights(want: Weights, got: Weights) !void {
    try std.testing.expectApproxEqAbs(want.shade, got.shade, 1e-5);
    try std.testing.expectApproxEqAbs(want.light, got.light, 1e-5);
}

test "a raised control is lit on its top and left, shaded on its bottom and right" {
    try expectWeights(.{ .shade = 0, .light = 1 }, weights(.raised, top));
    try expectWeights(.{ .shade = 0, .light = 1 }, weights(.raised, left));
    try expectWeights(.{ .shade = 1, .light = 0 }, weights(.raised, bottom));
    try expectWeights(.{ .shade = 1, .light = 0 }, weights(.raised, right));
}

test "an inset well is the raised look turned round" {
    for ([_][2]f32{ top, left, bottom, right }) |n| {
        const r = weights(.raised, n);
        try expectWeights(.{ .shade = r.light, .light = r.shade }, weights(.inset, n));
    }
}

test "round a corner the weight passes through nothing at 45 degrees, never jumping" {
    // The top-right corner's normals, from straight up to straight right.
    var prev = weights(.raised, top);
    var i: usize = 1;
    while (i <= 90) : (i += 1) {
        const a = std.math.degreesToRadians(@as(f32, @floatFromInt(i)));
        const n: [2]f32 = .{ @sin(a), -@cos(a) };
        const w = weights(.raised, n);
        try std.testing.expect(w.shade == 0 or w.light == 0);
        try std.testing.expect(@abs((w.light - w.shade) - (prev.light - prev.shade)) < 0.05);
        if (i == 45) try expectWeights(.{ .shade = 0, .light = 0 }, w);
        prev = w;
    }
    try expectWeights(weights(.raised, right), prev);
}

test "the edge fades from full at the outline to nothing at its depth" {
    try std.testing.expectEqual(@as(f32, 1), fall(ring_steps[0]));
    try std.testing.expectEqual(@as(f32, 0), fall(ring_steps[ring_steps.len - 1]));
    for (ring_steps[1..], ring_steps[0 .. ring_steps.len - 1]) |x, before| {
        try std.testing.expect(x > before);
        try std.testing.expect(fall(x) < fall(before));
    }
}
