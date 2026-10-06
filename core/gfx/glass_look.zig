//! One material on one slider (`docs/NATIVE_WINDOWS_PLAN.md`, "One material, one slider"): what
//! every glass surface is at the window opacity `t`, read as the glass's roughness. At 0 it is clear
//! glass, a lens bending what is behind it toward a bright rim; going up it grows rougher — a
//! smooth frost, whole by `rough_by`, so the middle of the way is frosted glass with its shine at
//! the edge — and the window's colour comes in over the frost after it, from `tint_start`; at 1 it
//! is the window's colour all over, no translucency, and only a little of the glass's shine left at
//! its edge. Colour coming in ahead of the frost read as a feathered fill fading in, not glass
//! growing rougher (the user). Two forms read it: the OS's glass where it has one (`native`,
//! `window`; Liquid Glass on macOS 26) and the app's own (`inApp`, the glass program of
//! `LiquidField`) — on the same breakpoints, so a surface looks alike in either.
//!
//! Every glass is frosted glass with a clearing bevel: its middle takes the frost and the window's
//! colour, which fade out across a band along its edge (`band`) so the edge stays clear glass,
//! bending the surface behind it — the band a share of the shape's size, so it hugs the rim of
//! small glass.
//!
//! std-only: the mapping is pure, and tested here. The app publishes the in-app look each frame
//! (`LiquidField.publishLook`); fizzy's pop-out overlay reads the native one.
const std = @import("std");

/// Where the frost is whole: the glass as rough as it gets.
pub const rough_by: f32 = 0.6;
/// Where the window's colour starts coming in over the frost, whole at 1.
pub const tint_start: f32 = 0.3;
/// Where the colour starts covering the edge too, and the glass's shine starts going…
pub const shine_start: f32 = 0.8;
/// …to this much at 1.
pub const shine_min: f32 = 0.25;

/// How far along each part of the way `t` is.
pub const Way = struct {
    /// How rough the glass is: frost over the lens, 0…1.
    frost: f32,
    /// The window's colour over the frost, 0…1.
    tint: f32,
    /// The glass's shine, 1 until `shine_start`, `shine_min` at 1.
    shine: f32,
    /// The colour over everything, the edge too: 0 until `shine_start`, 1 at 1.
    top: f32,
};

pub fn way(t: f32) Way {
    const o = std.math.clamp(t, 0, 1);
    const top = smoothstep(std.math.clamp((o - shine_start) / (1 - shine_start), 0, 1));
    return .{
        .frost = smoothstep(std.math.clamp(o / rough_by, 0, 1)),
        .tint = smoothstep(std.math.clamp((o - tint_start) / (1 - tint_start), 0, 1)),
        .shine = 1 - (1 - shine_min) * top,
        .top = top,
    };
}

// ── The clearing bevel ──────────────────────────────────────────────────────────────────────────

/// The bevel's width: a share of a shape's shorter half…
pub const bevel: f32 = 0.29;
/// …and at most this many points.
pub const bevel_cap: f32 = 20;
/// How much of the bevel, from the edge in, is clear before the middle's frost and colour start
/// coming in across the rest of it: none — the frost reaches the edge, thinning to nothing just
/// there, rather than stopping short of it at a clear band (the user).
pub const bevel_clear: f32 = 0;

/// The clearing bevel along the edge of a shape of `shorter_half` points, in points: clear for
/// `clear`, then the middle coming in over `feather`, quickly at first — strong most of the way to
/// the edge, gone at it.
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

/// The OS's glass at `t` — a drop, the carried view: the lens whole, bending the surface behind it;
/// over it frost at `over_share` and the window's colour `fill` opaque over that — both fading out
/// across each piece's clearing bevel (`band`), so the rim stays the lens; the glass `glass` there,
/// and the colour flat over everything `top_fill` opaque at the top. A drop takes the window's
/// colour only at the top, as the app's glass does (`InApp.mix`): coming in from `tint_start` it was
/// a disc of colour over the surface being dragged across, not rougher glass (the user).
pub const Native = struct {
    under: Material,
    over: Material,
    over_share: f32,
    fill: f32,
    glass: f32,
    top_fill: f32,
};

/// How much of the OS's frost a drop takes over its lens, at most: a drop is water, its lens bending
/// what is under it, and a light frost only softens the dark band Apple's lens shades its edge with
/// over a flat background. Frosted whole, drops read flat — matte discs rather than water (the
/// user, against the web build's glass).
pub const drop_frost: f32 = 0.4;

pub fn native(t: f32) Native {
    const w = way(t);
    return .{ .under = lens_material, .over = frost_material, .over_share = w.frost * drop_frost, .fill = w.top, .glass = w.shine, .top_fill = w.top };
}

/// A window of the OS's glass at `t` — the main window, a float's own. A window is read through,
/// not looked at: at 0 it is clear glass with a slight frost (`window_frost`), and its roughness
/// goes on past the glass frost into the plain blur behind the window (the vibrancy fizzy's windows
/// wore before), smooth and heavy, whole a little after the frost is. Over the lens its body takes
/// the frost, the blur over that, and the window's colour over both — all fading out across its
/// clearing bevel (`band`), so its edge stays the clear lens bending the desktop. The frost is under
/// the blur and the colour: over them its light lifted the whole window. At the top the colour
/// comes in under the lens too (`top_fill`), all over — the bevel opaque, the lens's last shine over
/// it — while the blur and the frost go: the blur shows the desktop whatever is under it, and
/// faded across the bevel over an opaque colour it was a ring of desktop inside the edge.
pub const Window = struct {
    under: Material,
    over: Material,
    /// Glass frost over the lens, in the body.
    frost: f32,
    /// The plain blur over the frost, in the body.
    blur: f32,
    /// The window's colour over the blur, in the body.
    fill: f32,
    /// The lens, `shine_min` of it left at 1.
    glass: f32,
    /// The window's colour under the lens, all over, at the top.
    top_fill: f32,
};

/// How much frost a window has at the bottom of the slider: clear glass, a little frosted.
pub const window_frost: f32 = 0.35;

pub fn window(t: f32) Window {
    const o = std.math.clamp(t, 0, 1);
    const w = way(o);
    const going = 1 - w.top;
    return .{
        .under = lens_material,
        .over = frost_material,
        .frost = std.math.lerp(window_frost, 1, smoothstep(std.math.clamp(o / (rough_by / 2), 0, 1))) * going,
        .blur = smoothstep(std.math.clamp((o - 0.1) / (rough_by - 0.05), 0, 1)) * going,
        .fill = w.tint,
        .glass = w.shine,
        .top_fill = w.top,
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
    /// The window's colour over it, 0…1 (the program's tint mix, whatever the blur): only at the
    /// top for glass that is a thing of its own — a drop, the carried view — which grows rough
    /// before it takes the window's colour; a surface carrying text takes `text_mix` (`forText`).
    mix: f32,
    /// The colour a surface carrying text takes — a dialog, a menu — from `tint_start`.
    text_mix: f32,
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
        .mix = w.top,
        .text_mix = w.tint,
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

/// `look` for a surface carrying text: its colour from `tint_start` (`text_mix`), and at least
/// `text_frost`.
pub fn forText(look: InApp) InApp {
    var l = look;
    l.mix = l.text_mix;
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

test "the middle of the slider is frosted glass with its shine, the colour only a hint" {
    const w = way(0.5);
    try std.testing.expect(w.frost > 0.9);
    try std.testing.expect(w.tint > 0 and w.tint < 0.3);
    try std.testing.expectEqual(@as(f32, 1), w.shine);
    try std.testing.expectEqual(@as(f32, 0), w.top);
}

test "the top of the slider is the window's colour all over, a little shine left at the edge" {
    const n = native(1);
    try std.testing.expectEqual(@as(f32, 1), n.fill);
    try std.testing.expectEqual(@as(f32, 1), n.top_fill);
    try std.testing.expectEqual(shine_min, n.glass);
    const a = inApp(1);
    try std.testing.expectEqual(@as(f32, 1), a.mix);
    try std.testing.expect(a.rim > 0 and a.rim < 0.3);
}

test "the way is monotonic: frost and colour only come in, the shine only goes" {
    var prev = way(0);
    var i: usize = 1;
    while (i <= 100) : (i += 1) {
        const w = way(@as(f32, @floatFromInt(i)) / 100);
        try std.testing.expect(w.frost >= prev.frost);
        try std.testing.expect(w.tint >= prev.tint);
        try std.testing.expect(w.top >= prev.top);
        try std.testing.expect(w.shine <= prev.shine);
        prev = w;
    }
}

test "the glass grows rough before the colour comes in" {
    // Colour ahead of the frost read as a feathered fill fading in, not glass growing rougher.
    var i: usize = 1;
    while (i < 100) : (i += 1) {
        const w = way(@as(f32, @floatFromInt(i)) / 100);
        try std.testing.expect(w.frost >= w.tint);
    }
}

test "a surface carrying text keeps some frost over a clear lens, none once it is opaque" {
    try std.testing.expectApproxEqAbs(text_frost, forText(inApp(0)).frost, 1e-6);
    try std.testing.expectEqual(inApp(1).frost, forText(inApp(1)).frost);
}

test "a drop is rough glass until the top, not a disc of colour; text takes its colour sooner" {
    try std.testing.expectEqual(@as(f32, 0), native(0.7).fill);
    try std.testing.expectEqual(@as(f32, 0), inApp(0.7).mix);
    // Water: a light frost over the lens at most.
    try std.testing.expectApproxEqAbs(drop_frost, native(0.7).over_share, 1e-6);
    try std.testing.expectEqual(way(0.7).tint, forText(inApp(0.7)).mix);
}

test "a window is clear glass a little frosted at the bottom, and opaque all over at the top" {
    const low = window(0);
    try std.testing.expectApproxEqAbs(window_frost, low.frost, 1e-6);
    try std.testing.expectEqual(@as(f32, 0), low.blur);
    try std.testing.expectEqual(@as(f32, 0), low.fill);
    try std.testing.expectEqual(@as(f32, 1), low.glass);
    const mid = window(0.5);
    try std.testing.expectEqual(@as(f32, 1), mid.frost);
    try std.testing.expect(mid.blur > 0.8);
    try std.testing.expectEqual(@as(f32, 0), mid.top_fill);
    const top = window(1);
    try std.testing.expectEqual(@as(f32, 1), top.fill);
    try std.testing.expectEqual(@as(f32, 1), top.top_fill);
    try std.testing.expectEqual(shine_min, top.glass);
    // The blur shows the desktop whatever is under it: gone by the top, so nothing does.
    try std.testing.expectEqual(@as(f32, 0), top.blur);
}

test "a window's colour only comes in, and its edge stays clear until the top" {
    var prev = window(0);
    var i: usize = 1;
    while (i <= 100) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / 100;
        const w = window(t);
        try std.testing.expect(w.fill >= prev.fill);
        try std.testing.expect(w.top_fill >= prev.top_fill);
        try std.testing.expect(w.glass <= prev.glass);
        if (t <= shine_start) try std.testing.expectEqual(@as(f32, 0), w.top_fill);
        prev = w;
    }
}

test "the clearing bevel hugs the rim of small glass and stops growing on large" {
    const small = band(20);
    try std.testing.expectApproxEqAbs(@as(f32, 0.29 * 20), small.clear + small.feather, 1e-4);
    const large = band(400);
    try std.testing.expectApproxEqAbs(bevel_cap, large.clear + large.feather, 1e-4);
    try std.testing.expect(large.clear <= large.feather);
    try std.testing.expectEqual(@as(f32, 0), band(0).feather);
}

test "both forms share the way" {
    var i: usize = 0;
    while (i <= 20) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / 20;
        try std.testing.expectApproxEqAbs(native(t).over_share, inApp(t).frost * drop_frost, 1e-6);
        try std.testing.expectEqual(native(t).fill, inApp(t).mix);
    }
}
