//! One material on one slider (`docs/NATIVE_WINDOWS_PLAN.md`, "One material, one slider"): what
//! every glass surface is at the window opacity `t`, from 0 — clear glass, a lens bending what is
//! behind it toward a bright rim — through the window's colour coming in with the blur, to 1,
//! opaque in the window's colour. Two forms read it: the OS's glass where it has one (`native`,
//! Liquid Glass on macOS 26) and the app's own (`inApp`, the glass program of `LiquidField`) —
//! on the same breakpoints, so a surface looks alike in either.
//!
//! std-only: the mapping is pure, and tested here. The app publishes the in-app look each frame
//! (`LiquidField.publishLook`); fizzy's pop-out overlay reads the native one.
const std = @import("std");

/// Where the window's colour starts coming in (under the glass, natively; as the tint, in the app).
pub const tint_start: f32 = 0.15;
/// Where frost starts coming in over the lens.
pub const frost_start: f32 = 0.6;
/// Where the glass's shine starts going, handing over to flat opaque colour by 1.
pub const shine_end: f32 = 0.92;

/// How far along each part of the way `t` is.
pub const Way = struct {
    /// The window's colour, 0…1 (opaque at `shine_end`).
    tint: f32,
    /// Frost over the lens, 0…1.
    frost: f32,
    /// The glass itself, 1 until `shine_end`, 0 at the top.
    shine: f32,
};

pub fn way(t: f32) Way {
    const o = std.math.clamp(t, 0, 1);
    return .{
        .tint = std.math.pow(f32, std.math.clamp((o - tint_start) / (shine_end - tint_start), 0, 1), 1.2),
        .frost = smoothstep(std.math.clamp((o - frost_start) / (shine_end - frost_start), 0, 1)),
        .shine = 1 - smoothstep(std.math.clamp((o - shine_end) / (1 - shine_end), 0, 1)),
    };
}

// ── The OS's glass ──────────────────────────────────────────────────────────────────────────────

/// Liquid Glass's variants and styles, as measured on macOS 26.5 (`visual_effect_view.m`).
pub const Material = struct {
    /// `_variant`: 11 the clear lens, 2 the glass's own frost.
    variant: i32,
    /// `NSGlassEffectViewStyle`: 1 Clear (light frost), 0 Regular (heavier).
    style: i32,
};
pub const lens_material: Material = .{ .variant = 11, .style = 1 };
pub const frost_material: Material = .{ .variant = 2, .style = 1 };

/// The OS's glass at `t`: two layers of the same pieces — the lens whole, frost over it at
/// `over_share` (faded out toward each piece's edge, so the rim stays the lens) — the window's
/// colour under the glass `under_fill` opaque, the glass `glass` there, and the colour flat over
/// everything `top_fill` opaque at the very top.
pub const Native = struct {
    under: Material,
    over: Material,
    over_share: f32,
    under_fill: f32,
    glass: f32,
    top_fill: f32,
};

pub fn native(t: f32) Native {
    const w = way(t);
    return .{ .under = lens_material, .over = frost_material, .over_share = w.frost, .under_fill = w.tint, .glass = w.shine, .top_fill = 1 - w.shine };
}

// ── The app's glass ─────────────────────────────────────────────────────────────────────────────

/// The app's glass at `t`, as the glass program (`shaders/liquid_glass.glsl`) reads it. Shaped
/// after Apple's lens, measured over a striped pattern: the backdrop pulled *inward* from a band
/// near the rim — `bevel` of the shape's shorter half, at most `bevel_cap` points — by up to `bend`
/// times that band, which magnifies it and, past 1, folds it into a mirrored, darker band just
/// inside the edge; the middle sharp and unblurred; a thin bright rim with a little colour fringe.
pub const InApp = struct {
    /// Frost over the sharp picture, 0…1: each shape's own blur is multiplied by it.
    frost: f32,
    /// The window's colour over it, 0…1 (the program's tint mix, whatever the blur).
    mix: f32,
    /// White over it, 0…1.
    lift: f32,
    /// The bending band's width: a share of the shape's shorter half…
    bevel: f32,
    /// …and at most this many points.
    bevel_cap: f32,
    /// How far the band pulls inward, in band widths at the rim; past 1 the picture folds there.
    bend: f32,
    /// How clear the band is: the sharp picture over the frost there, 0…1 — the rim stays clear
    /// glass while the middle frosts.
    clarity: f32,
    /// The rim's light, 0…1.
    rim: f32,
    /// How much darker the folded band is, 0…1.
    shade: f32,
    /// Light across the bending band, lighter facing the top left and darker away — the glass's
    /// bevel, which a full tint does not hide.
    bevel_light: f32,
    /// The colour fringe where the band bends hardest, 0…1.
    dispersion: f32,
};

pub fn inApp(t: f32) InApp {
    const w = way(t);
    return .{
        .frost = w.frost,
        .mix = w.tint,
        .lift = 0.03 * w.shine,
        .bevel = 0.29,
        .bevel_cap = 20,
        .bend = std.math.lerp(1.1, 0.55, w.frost) * w.shine,
        .clarity = std.math.lerp(0.9, 0.3, w.frost) * w.shine,
        .rim = std.math.lerp(1.0, 0.8, w.frost) * w.shine,
        .shade = std.math.lerp(0.15, 0.05, w.frost) * w.shine,
        .bevel_light = 0.08 * w.shine,
        .dispersion = std.math.lerp(1.0, 0.25, w.frost) * w.shine,
    };
}

/// The least frost a surface carrying text keeps — a dialog, a menu — so it still reads over a
/// clear lens; drops and the carried bubble follow the slider as it is.
pub const text_frost: f32 = 0.35;

/// `look` for a surface carrying text (`text_frost`).
pub fn forText(look: InApp) InApp {
    var l = look;
    l.frost = @max(l.frost, text_frost * (1 - std.math.clamp(l.mix, 0, 1)));
    return l;
}

fn smoothstep(x: f32) f32 {
    return x * x * (3 - 2 * x);
}

// ── Tests ───────────────────────────────────────────────────────────────────────────────────────

test "the bottom of the slider is clear glass: lens, no frost, no colour" {
    const n = native(0);
    try std.testing.expectEqual(lens_material, n.under);
    try std.testing.expectEqual(@as(f32, 0), n.over_share);
    try std.testing.expectEqual(@as(f32, 0), n.under_fill);
    try std.testing.expectEqual(@as(f32, 1), n.glass);
    const a = inApp(0);
    try std.testing.expectEqual(@as(f32, 0), a.frost);
    try std.testing.expectEqual(@as(f32, 0), a.mix);
    try std.testing.expect(a.bend > 1); // folds, as Apple's lens does
}

test "the top of the slider is opaque window colour, the glass gone" {
    const n = native(1);
    try std.testing.expectEqual(@as(f32, 1), n.under_fill);
    try std.testing.expectEqual(@as(f32, 0), n.glass);
    try std.testing.expectEqual(@as(f32, 1), n.top_fill);
    const a = inApp(1);
    try std.testing.expectEqual(@as(f32, 1), a.mix);
    try std.testing.expectEqual(@as(f32, 0), a.bend);
    try std.testing.expectEqual(@as(f32, 0), a.rim);
}

test "the way is monotonic: colour and frost only come in, the glass only goes" {
    var prev = way(0);
    var i: usize = 1;
    while (i <= 100) : (i += 1) {
        const w = way(@as(f32, @floatFromInt(i)) / 100);
        try std.testing.expect(w.tint >= prev.tint);
        try std.testing.expect(w.frost >= prev.frost);
        try std.testing.expect(w.shine <= prev.shine);
        prev = w;
    }
}

test "the glass keeps its shine until near the top" {
    try std.testing.expectEqual(@as(f32, 1), way(shine_end).shine);
    try std.testing.expect(way(0.85).tint > 0.8);
    try std.testing.expect(inApp(0.85).rim > 0.8);
}

test "a surface carrying text keeps some frost over a clear lens, none once it is opaque" {
    try std.testing.expectApproxEqAbs(text_frost, forText(inApp(0)).frost, 1e-6);
    try std.testing.expectEqual(inApp(1).frost, forText(inApp(1)).frost);
}

test "both forms share the way" {
    var i: usize = 0;
    while (i <= 20) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / 20;
        try std.testing.expectEqual(native(t).over_share, inApp(t).frost);
        try std.testing.expectEqual(native(t).under_fill, inApp(t).mix);
    }
}
