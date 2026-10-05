//! One material on one slider (`docs/NATIVE_WINDOWS_PLAN.md`, "One material, one slider"): what
//! every glass surface is at the window opacity `t`, from 0 — clear glass, a lens bending what is
//! behind it toward a bright rim — through the window's colour coming in with the blur, to 1,
//! opaque in the window's colour. Two forms read it: the OS's glass where it has one (`native`,
//! Liquid Glass on macOS 26) and the app's own (`inApp`, the glass program of `LiquidField`) —
//! on the same breakpoints, so a surface looks alike in either.
//!
//! Every glass is frosted glass with a clearing bevel: its middle takes the frost and the window's
//! colour, which fade out across a band along its edge (`band`) so the edge stays clear glass,
//! bending the surface behind it — the band a share of the shape's size, so it hugs the rim of
//! small glass.
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

// ── The clearing bevel ──────────────────────────────────────────────────────────────────────────

/// The bevel's width: a share of a shape's shorter half…
pub const bevel: f32 = 0.29;
/// …and at most this many points.
pub const bevel_cap: f32 = 20;
/// How much of the bevel, from the edge in, is clear before the middle's frost and colour start
/// coming in across the rest of it.
pub const bevel_clear: f32 = 0.2;

/// The clearing bevel along the edge of a shape of `shorter_half` points, in points: clear for
/// `clear`, then the middle coming in over `feather` on a smoothstep.
pub const Band = struct {
    clear: f32,
    feather: f32,
};

pub fn band(shorter_half: f32) Band {
    const w = @min(bevel * @max(shorter_half, 0), bevel_cap);
    return .{ .clear = w * bevel_clear, .feather = w * (1 - bevel_clear) };
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

/// The OS's glass at `t`: the lens whole, bending the surface behind it; over it the window's
/// colour `fill` opaque, and frost at `over_share` over that — both fading out across each piece's
/// clearing bevel (`band`), so the rim stays the lens; the glass `glass` there, and the colour flat
/// over everything `top_fill` opaque at the very top. Colour under the lens was a disc the lens
/// bent, where the surface being dragged over should be.
pub const Native = struct {
    under: Material,
    over: Material,
    over_share: f32,
    fill: f32,
    glass: f32,
    top_fill: f32,
};

pub fn native(t: f32) Native {
    const w = way(t);
    return .{ .under = lens_material, .over = frost_material, .over_share = w.frost, .fill = w.tint, .glass = w.shine, .top_fill = 1 - w.shine };
}

/// A window of the OS's glass at `t` — the main window, a float's own. A window is read through,
/// not looked at, so its slider starts where a drop's is half way (`window_from`), frosted already:
/// below that a window was all but clear glass. Over the lens its body takes frost, the plain blur
/// behind the window (the vibrancy fizzy's windows wore before) over that, and the window's colour
/// over both — all fading out across its clearing bevel (`band`), so the layers in it stand apart
/// from what is behind while its edge stays the clear lens, bending the desktop. The frost is under
/// the blur and the colour: over them its light lifted the whole window. The colour covers the
/// bevel too only as the glass goes at the very top (`top_fill`), so at 1 nothing anywhere lets the
/// desktop through; colour under the lens all along read as a dark band round the edge.
pub const Window = struct {
    under: Material,
    over: Material,
    /// Glass frost over the lens, in the body.
    frost: f32,
    /// The plain blur over the frost, in the body.
    blur: f32,
    /// The window's colour over the blur, in the body.
    fill: f32,
    /// The glass itself, 1 until near the top, 0 there.
    glass: f32,
    /// The window's colour over all of it, the bevel too, as the glass goes.
    top_fill: f32,
};

/// Where on a drop's way a window's slider starts.
pub const window_from: f32 = 0.5;

pub fn window(t: f32) Window {
    const o = window_from + (1 - window_from) * std.math.clamp(t, 0, 1);
    const w = way(o);
    // Colour comes in later than on a drop's glass, on a curve.
    const tint = std.math.pow(f32, std.math.clamp((o - tint_start) / (shine_end - tint_start), 0, 1), 2);
    return .{
        .under = lens_material,
        .over = frost_material,
        .frost = smoothstep(std.math.clamp((o - 0.05) / 0.35, 0, 1)),
        .blur = smoothstep(std.math.clamp((o - 0.25) / 0.55, 0, 1)),
        .fill = tint,
        .glass = w.shine,
        .top_fill = 1 - w.shine,
    };
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
        .bevel = bevel,
        .bevel_cap = bevel_cap,
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
    try std.testing.expectEqual(@as(f32, 0), n.fill);
    try std.testing.expectEqual(@as(f32, 1), n.glass);
    const a = inApp(0);
    try std.testing.expectEqual(@as(f32, 0), a.frost);
    try std.testing.expectEqual(@as(f32, 0), a.mix);
    try std.testing.expect(a.bend > 1); // folds, as Apple's lens does
}

test "the top of the slider is opaque window colour, the glass gone" {
    const n = native(1);
    try std.testing.expectEqual(@as(f32, 1), n.fill);
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

test "a window starts frosted, and is opaque all over at the top" {
    const low = window(0);
    try std.testing.expectEqual(@as(f32, 1), low.frost);
    try std.testing.expect(low.blur > 0.3 and low.blur < 0.6);
    try std.testing.expect(low.fill > 0.1 and low.fill < 0.3);
    try std.testing.expectEqual(@as(f32, 1), low.glass);
    const top = window(1);
    try std.testing.expectEqual(@as(f32, 1), top.fill);
    try std.testing.expectEqual(@as(f32, 1), top.top_fill);
    try std.testing.expectEqual(@as(f32, 0), top.glass);
    // The bevel stays clear glass until the glass starts going.
    try std.testing.expectEqual(@as(f32, 0), window(0.8).top_fill);
}

test "a window only gains frost, blur and colour along the way" {
    var prev = window(0);
    var i: usize = 1;
    while (i <= 100) : (i += 1) {
        const w = window(@as(f32, @floatFromInt(i)) / 100);
        try std.testing.expect(w.frost >= prev.frost);
        try std.testing.expect(w.blur >= prev.blur);
        try std.testing.expect(w.fill >= prev.fill);
        try std.testing.expect(w.top_fill >= prev.top_fill);
        try std.testing.expect(w.glass <= prev.glass);
        prev = w;
    }
}

test "the clearing bevel hugs the rim of small glass and stops growing on large" {
    const small = band(20);
    try std.testing.expectApproxEqAbs(@as(f32, 0.29 * 20), small.clear + small.feather, 1e-4);
    const large = band(400);
    try std.testing.expectApproxEqAbs(bevel_cap, large.clear + large.feather, 1e-4);
    try std.testing.expect(large.clear < large.feather);
    try std.testing.expectEqual(@as(f32, 0), band(0).feather);
}

test "both forms share the way" {
    var i: usize = 0;
    while (i <= 20) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / 20;
        try std.testing.expectEqual(native(t).over_share, inApp(t).frost);
        try std.testing.expectEqual(native(t).fill, inApp(t).mix);
    }
}
