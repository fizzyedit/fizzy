//! Pure scalar easing helpers.
//!
//! Kept in its own file (free of dvui / fizzy imports) so that
//! `zig build test` can exercise it without pulling in the GUI stack.
//! `src/math/math.zig` re-exports these so existing call sites stay
//! unchanged.

const std = @import("std");

pub const EaseType = enum {
    linear,
    ease_in,
    ease_out,
    ease_in_out,
};

pub fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

pub fn square(t: f32) f32 {
    return t * t;
}

pub fn flip(t: f32) f32 {
    return 1.0 - t;
}

pub fn ease(a: f32, b: f32, t: f32, ease_type: EaseType) f32 {
    return switch (ease_type) {
        .linear => lerp(a, b, t),
        .ease_in => lerp(a, b, square(t)),
        .ease_out => lerp(a, b, flip(square(flip(t)))),
        .ease_in_out => lerp(a, b, -(std.math.cos(std.math.pi * t) - 1.0) / 2.0),
    };
}

const expectApproxEqAbs = std.testing.expectApproxEqAbs;
const tolerance: f32 = 1e-5;

test "lerp endpoints and midpoint" {
    try expectApproxEqAbs(@as(f32, 0.0), lerp(0.0, 10.0, 0.0), tolerance);
    try expectApproxEqAbs(@as(f32, 10.0), lerp(0.0, 10.0, 1.0), tolerance);
    try expectApproxEqAbs(@as(f32, 5.0), lerp(0.0, 10.0, 0.5), tolerance);
}

test "lerp is symmetric in a and b" {
    try expectApproxEqAbs(lerp(2.0, 8.0, 0.25), lerp(8.0, 2.0, 0.75), tolerance);
}

test "square and flip are inverses through identity" {
    try expectApproxEqAbs(@as(f32, 0.0), square(0.0), tolerance);
    try expectApproxEqAbs(@as(f32, 1.0), square(1.0), tolerance);
    try expectApproxEqAbs(@as(f32, 0.25), square(0.5), tolerance);

    try expectApproxEqAbs(@as(f32, 1.0), flip(0.0), tolerance);
    try expectApproxEqAbs(@as(f32, 0.0), flip(1.0), tolerance);
    try expectApproxEqAbs(@as(f32, 0.7), flip(0.3), tolerance);
}

test "ease pins endpoints regardless of curve" {
    inline for (@typeInfo(EaseType).@"enum".fields) |f| {
        const kind: EaseType = @enumFromInt(f.value);
        try expectApproxEqAbs(@as(f32, 0.0), ease(0.0, 1.0, 0.0, kind), tolerance);
        try expectApproxEqAbs(@as(f32, 1.0), ease(0.0, 1.0, 1.0, kind), tolerance);
    }
}

test "ease curves bias the midpoint correctly" {
    // ease_in starts slow, so at t=0.5 we should be below linear (0.5).
    // ease_out starts fast, so at t=0.5 we should be above linear.
    const linear_mid = ease(0.0, 1.0, 0.5, .linear);
    const in_mid = ease(0.0, 1.0, 0.5, .ease_in);
    const out_mid = ease(0.0, 1.0, 0.5, .ease_out);
    try expectApproxEqAbs(@as(f32, 0.5), linear_mid, tolerance);
    try std.testing.expect(in_mid < linear_mid);
    try std.testing.expect(out_mid > linear_mid);
    // ease_in_out is symmetric and should hit exactly 0.5 at the midpoint.
    try expectApproxEqAbs(@as(f32, 0.5), ease(0.0, 1.0, 0.5, .ease_in_out), tolerance);
}
