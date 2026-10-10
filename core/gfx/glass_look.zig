//! One material on two sliders, the window's (`plans/NATIVE_WINDOWS_PLAN.md`): what every glass
//! surface is at the window's opacity and roughness.
//!
//! - **Roughness** is the glass. At 0 it is clear, shiny glass, a lens bending what is behind it
//!   toward a bright rim; going up it frosts, and at 1 it is wholly blurred. The lens's bend and
//!   shine fade as it roughens, as frosted glass's do: the refraction once set on its own is here.
//! - **Opacity** is the window's colour over it: none at 0, the window's fill at 1. From
//!   `shine_start` the colour covers the edge too and the glass's shine goes, so at 1 the glass is
//!   opaque all over with a little of its shine left at the edge.
//!
//! Two forms read them on macOS: the OS's glass (`native`, `window`; Liquid Glass on macOS 26) and
//! the app's own beside it (`inApp`, the glass program of `LiquidField`), on the same curves, so a
//! surface looks alike in either. Where there is no OS glass to match — the web, Linux, Windows —
//! the app's glass is its own frosted pane (`frosted`), on the same two sliders.
//!
//! Every glass is frosted glass with a clearing bevel: its middle takes the frost and the window's
//! colour, which fade out across a band along its edge (`band`) so the edge stays clear glass,
//! bending the surface behind it — the band a share of the shape's size, so it hugs the rim of
//! small glass.
//!
//! std-only: the mapping is pure, and tested here. The app publishes the in-app look each frame
//! (`LiquidField.publishLook`, macOS); fizzy's pop-out overlay reads the native one.
const std = @import("std");

/// Where the colour starts covering the edge too, and the glass's shine starts going…
pub const shine_start: f32 = 0.8;
/// …to this much at 1.
pub const shine_min: f32 = 0.25;

/// What the two sliders make of the glass.
pub const Way = struct {
    /// How rough the glass is: frost over the lens, 0…1 (roughness).
    frost: f32,
    /// The window's colour over the frost, 0…1 (opacity).
    tint: f32,
    /// The glass's shine, 1 until `shine_start`, `shine_min` at 1.
    shine: f32,
    /// The colour over everything, the edge too: 0 until `shine_start`, 1 at 1.
    top: f32,
};

pub fn way(opacity: f32, roughness: f32) Way {
    const o = std.math.clamp(opacity, 0, 1);
    const top = smoothstep(std.math.clamp((o - shine_start) / (1 - shine_start), 0, 1));
    return .{
        .frost = smoothstep(std.math.clamp(roughness, 0, 1)),
        .tint = o,
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

/// The OS's glass for a drop, the carried view: the lens whole, bending the surface behind it; over
/// it frost at `over_share` and the window's colour `fill` opaque over that — both fading out
/// across each piece's clearing bevel (`band`), so the rim stays the lens; the glass `glass` there,
/// and the colour flat over everything `top_fill` opaque at the top. A drop takes the window's
/// colour only at the top, as the app's glass does (`InApp.mix`): coming in sooner it was a disc of
/// colour over the surface being dragged across, not rougher glass (the user).
pub const Native = struct {
    under: Material,
    over: Material,
    over_share: f32,
    fill: f32,
    glass: f32,
    top_fill: f32,
    /// Points of plain blur over the lens in place of the frost, where the OS can draw one
    /// (`drop_blur`).
    blur: f32,
};

/// How much of the OS's frost a drop takes over its lens, at most. The frost is a blur, and the lens
/// under it the sharp picture: at half, the sharp picture showed through it only lightened — a bloom
/// with every line still in it, not frost (the user, against the app's own glass, which blurs);
/// whole, nothing behind it showed at all, a muddy disc rather than frosted glass — a canvas's
/// checkerboard gone from under it (the user). Mostly blur, a little of the picture through it.
pub const drop_frost: f32 = 0.75;

/// The least frost a drop keeps, at the bottom of the slider: every drop carries something to read
/// — a drop zone's icon — and over a busy background a clear lens left it hard to make out (the
/// user). Still water, the lens bending what is under it, softened.
pub const drop_frost_min: f32 = 0.45;

/// Points of plain blur over a drop's lens, at the top of its way and at the bottom, where the OS
/// can blur what is behind a window without a material's tint (macOS: Core Animation's backdrop
/// blur). The OS's frost is not a blur but a material: measured, it pulls whatever is under it some
/// 29% toward one mid grey — a dark window's colour lifted, a light one dulled — and blurs past any
/// detail, so a bubble over the window's colour read as a grey disc, and over a canvas as a flat
/// one, nothing under it showing (the user). A plain blur keeps the colour under it and a little of
/// its shape: clear glass, slightly frosted.
pub const drop_blur: f32 = 6;
pub const drop_blur_min: f32 = 2;

/// The carried view's picture in its drop, a touch out of focus, points: frosted with the glass it is
/// in rather than printed on it, and far less than the bubbles' backdrop (`drop_blur`), so what the
/// view shows still reads (the user: "a very slight frost").
pub const drop_photo_blur: f32 = 1.25;

/// The clearing bevel of a drop of the OS's glass, a share of its shorter half (`bevel_cap` still
/// the most): narrower than the app's own, its frost reaching nearer the rim (the user) — the OS's
/// lens has a bright rim of its own, which the app's glass draws across its whole band.
pub const drop_bevel: f32 = 0.22;

pub fn native(opacity: f32, roughness: f32) Native {
    const w = way(opacity, roughness);
    return .{ .under = lens_material, .over = frost_material, .over_share = std.math.lerp(drop_frost_min, drop_frost, w.frost), .fill = w.top, .glass = w.shine, .top_fill = w.top, .blur = std.math.lerp(drop_blur_min, drop_blur, w.frost) };
}

/// A window of the OS's glass — the main window, a float's own. Clear, shiny glass at no roughness;
/// roughening, the glass frost comes first (`window_frost_by`), then the plain blur behind the
/// window (the vibrancy fizzy's windows wore before) goes on past it, smooth and heavy, whole at the
/// top. Over the lens its body takes the frost, the blur over that, and the window's colour over
/// both — all fading out across its clearing bevel (`band`), so its edge stays the clear lens bending
/// the desktop. The frost is under the blur and the colour: over them its light lifted the whole
/// window. Near full opacity the colour comes in under the lens too (`top_fill`), all over — the
/// bevel opaque, the lens's last shine over it — while the blur and the frost go: the blur shows the
/// desktop whatever is under it, and faded across the bevel over an opaque colour it was a ring of
/// desktop inside the edge.
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

/// The roughness by which a window's glass frost is whole; the plain blur over it is whole at 1.
pub const window_frost_by: f32 = 0.3;
/// The roughness the plain blur starts at.
pub const window_blur_from: f32 = 0.1;

pub fn window(opacity: f32, roughness: f32) Window {
    const r = std.math.clamp(roughness, 0, 1);
    const w = way(opacity, r);
    const going = 1 - w.top;
    return .{
        .under = lens_material,
        .over = frost_material,
        .frost = smoothstep(std.math.clamp(r / window_frost_by, 0, 1)) * going,
        .blur = smoothstep(std.math.clamp((r - window_blur_from) / (1 - window_blur_from), 0, 1)) * going,
        .fill = w.tint,
        .glass = w.shine,
        .top_fill = w.top,
    };
}

// ── The app's glass ─────────────────────────────────────────────────────────────────────────────

/// The app's glass at the two sliders, as the glass program (`shaders/liquid_glass.glsl`) reads it. Shaped
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
    /// The colour a surface carrying text takes — a dialog, a menu: the window's opacity as it is.
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

pub fn inApp(opacity: f32, roughness: f32) InApp {
    const w = way(opacity, roughness);
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

/// `look` for a drop — a drop zone's bubble, the carried view: frosted at least as much as the OS's
/// glass keeps at the bottom of the slider (`native`, `drop_frost_min`), on the same way up.
pub fn forDrops(look: InApp) InApp {
    var l = look;
    l.frost = std.math.lerp(drop_frost_min / drop_frost, 1, l.frost);
    return l;
}

/// `look` for a surface carrying text — a dialog, a menu: the window's colour as the opacity has it
/// (`text_mix`), over glass as rough as the roughness — clear at 0, as the user asked of the bottom
/// of the slider.
pub fn forText(look: InApp) InApp {
    var l = look;
    l.mix = l.text_mix;
    return l;
}

/// `look` for a lens over a picture of the caller's own — a magnifier's zoom, a loupe — rather than
/// over what is behind it (`LiquidField.drawPicture`): the picture is what it shows, as it is, so
/// its middle takes no frost, none of the window's colour and no lift, at any point on the sliders
/// — a colour picked through it is the colour under it. Only the band along its edge is glass,
/// bending the picture toward its rim and lit there, and that follows the sliders as every glass
/// does: a clear lens at the bottom, its shine going at the top.
pub fn forLens(look: InApp) InApp {
    var l = look;
    l.frost = 0;
    l.mix = 0;
    l.text_mix = 0;
    l.lift = 0;
    return l;
}

// ── The app's frosted pane ──────────────────────────────────────────────────────────────────────

/// The app's own glass where there is no OS glass to match (the web, Linux, Windows): what is behind
/// blurred, the window's colour mixed over it (`core.dialogs.Style`). The roughness is the blur —
/// clear glass, unblurred, below the least blur a pane draws (`BlurBackdrop.min_blur`) — and the lens's bend fades as it grows,
/// half gone at the top; the opacity is the colour as it is.
pub const Frosted = struct {
    /// The window's colour over the frost, 0…1.
    mix: f32,
    /// The blur's radius (`BlurBackdrop.Pane.radius`).
    blur: f32,
    /// How far the edge refracts, as `core.dialogs.publishRefraction` takes it: 0…1, 0.5 as designed.
    refraction: f32,
};

/// The blur at full roughness: a heavy frost, colour and shape gone (`BlurBackdrop.Pane.radius`).
pub const max_blur: f32 = 40;

pub fn frosted(opacity: f32, roughness: f32) Frosted {
    const r = std.math.clamp(roughness, 0, 1);
    return .{ .mix = std.math.clamp(opacity, 0, 1), .blur = r * max_blur, .refraction = std.math.lerp(1, 0.5, r) };
}

// ── Settings from before the two sliders ────────────────────────────────────────────────────────

/// The roughness a window had at the one slider's `t`, for settings written before there were two
/// (`SettingsMigration.windowGlass`): its plain blur came in from 0.1 and was whole by 0.65, so the
/// window looks as it did. Its opacity stays the slider as it was.
pub fn roughnessFromOneSlider(t: f32) f32 {
    return std.math.clamp(window_blur_from + (1 - window_blur_from) * (t - 0.1) / 0.55, 0, 1);
}

/// The roughness the dialogs' blur radius was, for the same settings where the app's glass is its
/// frosted pane (`frosted`).
pub fn roughnessFromBlur(radius: f32) f32 {
    return std.math.clamp(radius / max_blur, 0, 1);
}

fn smoothstep(x: f32) f32 {
    return x * x * (3 - 2 * x);
}

// ── Tests ───────────────────────────────────────────────────────────────────────────────────────

fn at(i: usize, n: usize) f32 {
    return @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
}

test "the bottom of both sliders is clear, shiny glass: lens, no colour, a drop only softened" {
    const n = native(0, 0);
    try std.testing.expectEqual(lens_material, n.under);
    try std.testing.expectApproxEqAbs(drop_frost_min, n.over_share, 1e-6);
    try std.testing.expectApproxEqAbs(drop_frost_min, forDrops(inApp(0, 0)).frost * drop_frost, 1e-6);
    try std.testing.expectEqual(@as(f32, 0), n.fill);
    try std.testing.expectEqual(@as(f32, 1), n.glass);
    const a = inApp(0, 0);
    try std.testing.expectEqual(@as(f32, 0), a.frost);
    try std.testing.expectEqual(@as(f32, 0), a.mix);
    try std.testing.expect(a.bend > 1); // folds, as Apple's lens does
    const win = window(0, 0);
    try std.testing.expectEqual(@as(f32, 0), win.frost);
    try std.testing.expectEqual(@as(f32, 0), win.blur);
    try std.testing.expectEqual(@as(f32, 0), win.fill);
    try std.testing.expectEqual(@as(f32, 1), win.glass);
}

test "roughness is the frost alone, opacity the colour alone" {
    var i: usize = 0;
    while (i <= 20) : (i += 1) {
        try std.testing.expectEqual(@as(f32, 0), way(0, at(i, 20)).tint);
        try std.testing.expectEqual(@as(f32, 0), way(at(i, 20), 0).frost);
        try std.testing.expectEqual(at(i, 20), way(at(i, 20), 0.5).tint);
    }
}

test "full roughness is a wholly blurred window; full opacity the window's colour all over" {
    const rough = window(0, 1);
    try std.testing.expectEqual(@as(f32, 1), rough.frost);
    try std.testing.expectEqual(@as(f32, 1), rough.blur);
    try std.testing.expectEqual(@as(f32, 0), rough.fill);
    var i: usize = 0;
    while (i <= 10) : (i += 1) {
        const r = at(i, 10);
        const top = window(1, r);
        try std.testing.expectEqual(@as(f32, 1), top.fill);
        try std.testing.expectEqual(@as(f32, 1), top.top_fill);
        try std.testing.expectEqual(shine_min, top.glass);
        // The blur shows the desktop whatever is under it: gone at the top, so nothing does.
        try std.testing.expectEqual(@as(f32, 0), top.blur);
        try std.testing.expectEqual(@as(f32, 1), native(1, r).fill);
        try std.testing.expectEqual(@as(f32, 1), inApp(1, r).mix);
        try std.testing.expect(inApp(1, r).rim > 0 and inApp(1, r).rim < 0.3);
    }
}

test "each slider only goes one way: frost and colour come in, the shine only goes" {
    var i: usize = 1;
    while (i <= 100) : (i += 1) {
        const a = way(at(i - 1, 100), 0.5);
        const b = way(at(i, 100), 0.5);
        try std.testing.expect(b.tint >= a.tint and b.top >= a.top and b.shine <= a.shine);
        const c = way(0.5, at(i - 1, 100));
        const d = way(0.5, at(i, 100));
        try std.testing.expect(d.frost >= c.frost);
        const wa = window(0.3, at(i - 1, 100));
        const wb = window(0.3, at(i, 100));
        try std.testing.expect(wb.frost >= wa.frost and wb.blur >= wa.blur);
    }
}

test "a lens over a picture leaves its middle as it is, everywhere on the sliders" {
    var i: usize = 0;
    while (i <= 20) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / 20;
        const l = forLens(inApp(t, 0));
        try std.testing.expectEqual(@as(f32, 0), l.frost);
        try std.testing.expectEqual(@as(f32, 0), l.mix);
        try std.testing.expectEqual(@as(f32, 0), l.lift);
        // Its edge is the sliders' glass all the same.
        try std.testing.expectEqual(inApp(t, 0).bend, l.bend);
        try std.testing.expectEqual(inApp(t, 0).rim, l.rim);
    }
    // A clear lens at the bottom, folding at its rim as Apple's does.
    try std.testing.expect(forLens(inApp(0, 0)).bend > 1);
}

test "the lens bends less as the glass roughens: the refraction is the roughness's" {
    try std.testing.expect(inApp(0, 1).bend < inApp(0, 0).bend);
    try std.testing.expect(inApp(0, 1).clarity < inApp(0, 0).clarity);
    try std.testing.expect(inApp(0, 1).dispersion < inApp(0, 0).dispersion);
}

test "a surface carrying text is as rough as the roughness: clear at the bottom" {
    try std.testing.expectEqual(@as(f32, 0), forText(inApp(0, 0)).frost);
    try std.testing.expectEqual(inApp(1, 0.5).frost, forText(inApp(1, 0.5)).frost);
}

test "the frosted pane: the roughness its blur, the opacity its colour" {
    const clear = frosted(0, 0);
    try std.testing.expectEqual(@as(f32, 0), clear.blur);
    try std.testing.expectEqual(@as(f32, 0), clear.mix);
    try std.testing.expectEqual(@as(f32, 1), clear.refraction);
    const rough = frosted(1, 1);
    try std.testing.expectEqual(max_blur, rough.blur);
    try std.testing.expectEqual(@as(f32, 1), rough.mix);
    try std.testing.expectEqual(@as(f32, 0.5), rough.refraction);
    try std.testing.expectEqual(@as(f32, 0.3), frosted(0.3, 0.7).mix);
}

test "a drop's plain blur is light, growing with the roughness" {
    try std.testing.expectApproxEqAbs(drop_blur_min, native(0, 0).blur, 1e-6);
    try std.testing.expectApproxEqAbs(drop_blur, native(0, 1).blur, 1e-6);
    var prev = native(0, 0).blur;
    var i: usize = 1;
    while (i <= 20) : (i += 1) {
        const b = native(0, at(i, 20)).blur;
        try std.testing.expect(b >= prev);
        prev = b;
    }
}

test "a drop is glass until the top, not a disc of colour; text takes the opacity's colour" {
    try std.testing.expectEqual(@as(f32, 0), native(0.7, 0.5).fill);
    try std.testing.expectEqual(@as(f32, 0), inApp(0.7, 0.5).mix);
    try std.testing.expectApproxEqAbs(drop_frost, native(0.7, 1).over_share, 1e-6);
    try std.testing.expectEqual(@as(f32, 0.7), forText(inApp(0.7, 0.5)).mix);
}

test "settings from one slider keep their window's blur, and a dialog's blur its radius" {
    try std.testing.expectEqual(@as(f32, 1), roughnessFromOneSlider(0.7));
    try std.testing.expectApproxEqAbs(@as(f32, 0.427), roughnessFromOneSlider(0.3), 1e-3);
    try std.testing.expectEqual(window_blur_from, roughnessFromOneSlider(0.1));
    try std.testing.expectEqual(@as(f32, 0), roughnessFromOneSlider(0));
    try std.testing.expectEqual(@as(f32, 0.75), roughnessFromBlur(30));
    try std.testing.expectEqual(@as(f32, 1), roughnessFromBlur(48));
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
        const o = at(i, 20);
        const r = at(20 - i, 20);
        try std.testing.expectApproxEqAbs(native(o, r).over_share, forDrops(inApp(o, r)).frost * drop_frost, 1e-6);
        try std.testing.expectEqual(native(o, r).fill, inApp(o, r).mix);
    }
}
