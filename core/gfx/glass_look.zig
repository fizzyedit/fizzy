//! One material on one value, the window's opacity (`plans/WINDOW_GLASS_PLAN.md`): what every glass
//! surface is at it.
//!
//! - **0 is a clear window**: no material, no colour — an overlay, the drag's glass layer, a window
//!   the app draws every pixel of. Not the end of the ramp but a mode of its own; an app's own
//!   slider stops at `min_opacity`.
//! - **Above 0 the glass is always frosted**, at one frost (`frost_level`), the same at every
//!   opacity: transparent always comes with blur. Over it the window's colour ramps from a little
//!   (still reading as glass) to the window's fill at 1. From `shine_start` the colour covers the
//!   edge too and the glass's shine goes, so at 1 the glass is opaque all over with a little of its
//!   shine left at the edge.
//! - **Where nothing can blur** (`base`, no material), above 0 is opaque.
//!
//! Two forms read it on macOS: the OS's glass (`native`, `window`; Liquid Glass on macOS 26) and
//! the app's own beside it (`inApp`, the glass program of `LiquidField`), on the same curves, so a
//! surface looks alike in either. Where there is no OS glass to match — the web, Linux, Windows —
//! the app's glass is its own frosted pane (`frosted`), on the same value.
//!
//! Every glass is frosted glass with a clearing bevel: its middle takes the frost and the window's
//! colour, which fade out across a band along its edge (`band`) so the edge stays clear glass,
//! bending the surface behind it — the band a share of the shape's size, so it hugs the rim of
//! small glass.
//!
//! std-only: the mapping is pure, and tested here. The app publishes the in-app look each frame
//! (`LiquidField.publishLook`, macOS); fizzy's pop-out overlay reads the native one.
const std = @import("std");

/// The one frost every glass has above 0, as a share of the way from a clear lens (0) to wholly
/// blurred (1), in the glass's body; its edge stays the clear lens, as Liquid Glass's does. Tuned
/// once, here, rather than set by each person (it was a second slider, roughness).
pub const frost_level: f32 = 0.82;

/// The least opacity an app's own slider offers: 0 is a clear window, not glass (fizzy's settings).
pub const min_opacity: f32 = 0.05;

/// Where the colour starts covering the edge too, and the glass's shine starts going…
pub const shine_start: f32 = 0.8;
/// …to this much at 1.
pub const shine_min: f32 = 0.25;

/// What the opacity makes of the glass.
pub const Way = struct {
    /// Frost over the lens, 0…1: `frost_level`'s above 0, none at it.
    frost: f32,
    /// The window's colour over the frost, 0…1.
    tint: f32,
    /// The glass's shine, 1 until `shine_start`, `shine_min` at 1; none at 0, where there is no glass.
    shine: f32,
    /// The colour over everything, the edge too: 0 until `shine_start`, 1 at 1.
    top: f32,
};

/// Whether `opacity` is a clear window, no glass at all.
pub fn clear(opacity: f32) bool {
    return !(opacity > 0);
}

/// How rough the glass is at `opacity`: `frost_level` above 0, none at it.
fn roughness(opacity: f32) f32 {
    return if (clear(opacity)) 0 else frost_level;
}

pub fn way(opacity: f32) Way {
    if (clear(opacity)) return .{ .frost = 0, .tint = 0, .shine = 0, .top = 0 };
    const o = @min(opacity, 1);
    const top = smoothstep(std.math.clamp((o - shine_start) / (1 - shine_start), 0, 1));
    return .{
        .frost = smoothstep(frost_level),
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

/// The least frost a drop keeps, with no frost of the window's: every drop carries something to read
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

/// A drop is glass at any opacity, a clear window's drag included: it carries something to read
/// (`drop_frost_min`), so at 0 it is the lens at its least frost, not nothing.
pub fn native(opacity: f32) Native {
    const w = way(@max(opacity, min_opacity));
    return .{ .under = lens_material, .over = frost_material, .over_share = std.math.lerp(drop_frost_min, drop_frost, w.frost), .fill = w.top, .glass = w.shine, .top_fill = w.top, .blur = std.math.lerp(drop_blur_min, drop_blur, w.frost) };
}

/// A window of the OS's glass — the main window, a float's own. Nothing at 0, a clear window. Above
/// it the frost at `frost_level`: the glass frost first (whole by `window_frost_by`), then the plain
/// blur behind the window (the vibrancy fizzy's windows wore before) on past it, whole at 1. Over the lens its body takes the frost, the blur over that, and the window's colour over
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

/// The frost level by which a window's glass frost is whole; the plain blur over it is whole at 1.
pub const window_frost_by: f32 = 0.3;
/// The frost level the plain blur starts at.
pub const window_blur_from: f32 = 0.1;
/// The opacity a window's frost and blur start going at, gone at 1, under a colour that by then
/// all but covers them. Under them is the clear lens, showing the desktop sharp: going from
/// `shine_start` with the edge's colour, they were half gone at 0.9 while the colour covered only
/// 90%, and the window grew clearer just before it was opaque (the user).
pub const window_frost_out: f32 = 0.95;

pub fn window(opacity: f32) Window {
    const r = roughness(opacity);
    const w = way(opacity);
    const going = 1 - smoothstep(std.math.clamp((@min(opacity, 1) - window_frost_out) / (1 - window_frost_out), 0, 1));
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

/// The app's glass at the opacity, as the glass program (`shaders/liquid_glass.glsl`) reads it. Shaped
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
    /// A drop's edge, measured beside the OS's: lit along the diagonal the light runs (top left,
    /// bottom right), darkened across the other — this much at its brightest. 0 is a window's
    /// edge instead: an even hairline (`forText`).
    diagonal: f32,
    /// The colour fringe where the band bends hardest, 0…1.
    dispersion: f32,
};

pub fn inApp(opacity: f32) InApp {
    const w = way(opacity);
    return .{
        .frost = w.frost,
        .mix = w.top,
        .text_mix = w.tint,
        .lift = 0.03 * w.shine,
        .bevel = bevel,
        .bevel_cap = bevel_cap,
        // The lens whole at its edge whatever the frost, as Liquid Glass's is (and the OS's drops,
        // `native`): the frost is the body's. Softened with the frost, it went with the one frost
        // level (`frost_level`), and the edge stopped bending (the user).
        .bend = 1.1 * w.shine,
        .clarity = 0.9 * w.shine,
        .rim = w.shine,
        // No light or shade across the band, only at the edge (the glass program's): lit toward the
        // top left and darkened away, the band read as a bevel in shadow (the user). A drop's
        // edge: highlights 110 to 130 over its body along the light's diagonal and 20 under it across
        // the other, measured on the OS's drops (0–255).
        .shade = 0,
        .diagonal = 0.6 * w.shine,
        // A hint of colour fringe: whole, it was red and blue specks along the edge, which
        // Liquid Glass does not show.
        .dispersion = 0.25 * w.shine,
    };
}

/// `look` for a drop — a drop zone's bubble, the carried view: frosted at least as much as the OS's
/// glass keeps with no frost of the window's (`native`, `drop_frost_min`), on the same way up.
pub fn forDrops(look: InApp) InApp {
    var l = look;
    l.frost = std.math.lerp(drop_frost_min / drop_frost, 1, l.frost);
    return l;
}

/// `look` for a surface carrying text — a dialog, a menu: the window's colour as the opacity has it
/// (`text_mix`), over the whole frost, as a window of the OS's glass has (`window`: its glass frost
/// whole, its blur nearly so). At the frost level the sharp picture kept a tenth of the body, and
/// the code behind a dialog read through it, where the OS's window beside it showed none.
pub fn forText(look: InApp) InApp {
    var l = look;
    l.mix = l.text_mix;
    if (l.frost > 0) l.frost = 1;
    // A window's lens, not a drop's: shallower, in a narrower band. Beside an OS window of Liquid
    // Glass moving over the same code, the drop's deep lens across a 20-point band pulled text in
    // from far outside the edge, in streaks that drew the eye as it moved (the user).
    l.bend *= text_bend;
    l.bevel_cap = text_bevel_cap;
    // A window's edge: the even hairline an OS window of Liquid Glass has, not a drop's diagonal.
    l.diagonal = 0;
    return l;
}

/// How much of a drop's bend a surface carrying text keeps (`forText`)…
pub const text_bend: f32 = 0.5;
/// …and the most its bending band is, in points.
pub const text_bevel_cap: f32 = 12;
/// The blur under a surface carrying text, in points (`BlurBackdrop.Pane.radius`): less than
/// `max_blur`, as an OS window of Liquid Glass's body is less blurred than fizzy's was beside it.
pub const text_blur: f32 = 24;

/// `look` for a lens over a picture of the caller's own — a magnifier's zoom, a loupe — rather than
/// over what is behind it (`LiquidField.drawPicture`): the picture is what it shows, as it is, so
/// its middle takes no frost, none of the window's colour and no lift, at any opacity
/// — a colour picked through it is the colour under it. Only the band along its edge is glass,
/// bending the picture toward its rim and lit there, and that follows the opacity as every glass
/// does, its shine going at the top.
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
/// blurred, the window's colour mixed over it (`core.dialogs.Style`). The blur is the frost level's
/// share of `max_blur`, the edge refracting whole (the frost is the body's, as `inApp`'s), none of
/// either at 0; the opacity is the colour as it is.
pub const Frosted = struct {
    /// The window's colour over the frost, 0…1.
    mix: f32,
    /// The blur's radius (`BlurBackdrop.Pane.radius`).
    blur: f32,
    /// How far the edge refracts, as `core.dialogs.publishRefraction` takes it: 0…1, 0.5 as designed.
    refraction: f32,
};

/// The blur at full frost: a heavy frost, colour and shape gone (`BlurBackdrop.Pane.radius`).
pub const max_blur: f32 = 40;

pub fn frosted(opacity: f32) Frosted {
    const r = roughness(opacity);
    return .{ .mix = std.math.clamp(opacity, 0, 1), .blur = r * max_blur, .refraction = if (clear(opacity)) 0 else 1 };
}

// ── The window's own base ───────────────────────────────────────────────────────────────────────

/// What a window draws under everything where the OS's glass is not its base (`window` is, on
/// macOS 26): the window's colour at `alpha`, `lighten` lighter — so the material behind reads as
/// the same tone as it goes see-through — over the OS's material (vibrancy, Acrylic, the
/// compositor's blur) where it has one.
pub const Base = struct {
    /// Whether the OS's material is behind the window.
    material: bool,
    alpha: f32,
    /// Percent lighter (`dvui.Color.lighten`).
    lighten: f32,
};

/// The base at `opacity`, where the OS can put a material behind the window (`material`) or not:
/// clear at 0 either way; above it the colour's ramp over the material, or opaque with none to blur
/// what shows through.
pub fn base(opacity: f32, material: bool) Base {
    if (clear(opacity)) return .{ .material = false, .alpha = 0, .lighten = 0 };
    if (!material) return .{ .material = false, .alpha = 1, .lighten = 0 };
    const o = @min(opacity, 1);
    return .{ .material = true, .alpha = o, .lighten = (1 - o) * 4 };
}

fn smoothstep(x: f32) f32 {
    return x * x * (3 - 2 * x);
}

// ── Tests ───────────────────────────────────────────────────────────────────────────────────────

fn at(i: usize, n: usize) f32 {
    return @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
}

test "opacity 0 is a clear window: no material, no colour, no shine" {
    const win = window(0);
    try std.testing.expectEqual(@as(f32, 0), win.frost);
    try std.testing.expectEqual(@as(f32, 0), win.blur);
    try std.testing.expectEqual(@as(f32, 0), win.fill);
    try std.testing.expectEqual(@as(f32, 0), win.glass);
    try std.testing.expectEqual(@as(f32, 0), win.top_fill);
    const a = inApp(0);
    try std.testing.expectEqual(@as(f32, 0), a.frost);
    try std.testing.expectEqual(@as(f32, 0), a.mix);
    try std.testing.expectEqual(@as(f32, 0), a.rim);
    try std.testing.expectEqual(@as(f32, 0), frosted(0).blur);
    try std.testing.expectEqual(@as(f32, 0), frosted(0).mix);
    for ([_]bool{ false, true }) |material| {
        const b = base(0, material);
        try std.testing.expectEqual(@as(f32, 0), b.alpha);
        try std.testing.expect(!b.material);
    }
    try std.testing.expect(clear(0) and clear(-1) and !clear(min_opacity));
}

test "above 0 the frost is the same at every opacity; only the colour ramps" {
    var i: usize = 1;
    while (i <= 20) : (i += 1) {
        const o = at(i, 20);
        // The window's own frost and blur go under the colour only at the very top, once it covers them.
        if (o <= window_frost_out) try std.testing.expectEqual(window(min_opacity).frost, window(o).frost);
        try std.testing.expectEqual(smoothstep(frost_level), way(o).frost);
        try std.testing.expectEqual(frost_level * max_blur, frosted(o).blur);
        try std.testing.expectEqual(o, way(o).tint);
        try std.testing.expect(window(o).glass > 0);
    }
    // Some frost, some blur: transparent always comes with blur.
    try std.testing.expect(window(min_opacity).frost > 0 and window(min_opacity).blur > 0);
}

test "where nothing can blur, above 0 is opaque; over a material the colour ramps" {
    try std.testing.expectEqual(@as(f32, 1), base(min_opacity, false).alpha);
    try std.testing.expectEqual(@as(f32, 1), base(0.5, false).alpha);
    try std.testing.expectEqual(@as(f32, 0.5), base(0.5, true).alpha);
    try std.testing.expect(base(0.5, true).material);
    try std.testing.expectEqual(@as(f32, 1), base(1, true).alpha);
    try std.testing.expectEqual(@as(f32, 0), base(1, true).lighten);
}

test "full opacity is the window's colour all over, the frost gone under it" {
    const top = window(1);
    try std.testing.expectEqual(@as(f32, 1), top.fill);
    try std.testing.expectEqual(@as(f32, 1), top.top_fill);
    try std.testing.expectEqual(shine_min, top.glass);
    // The blur shows the desktop whatever is under it: gone at the top, so nothing does.
    try std.testing.expectEqual(@as(f32, 0), top.blur);
    try std.testing.expectEqual(@as(f32, 1), native(1).fill);
    try std.testing.expectEqual(@as(f32, 1), inApp(1).mix);
    try std.testing.expect(inApp(1).rim > 0 and inApp(1).rim < 0.3);
}

test "the window grows no clearer on its way to opaque: frost and blur go only once covered" {
    var i: usize = 1;
    while (i <= 100) : (i += 1) {
        const o = at(i, 100);
        const w = window(o);
        // What of the frost and blur shows through the colour over them never rises.
        const prev = window(at(i - 1, 100) + 1e-4);
        try std.testing.expect(w.blur * (1 - w.fill) <= prev.blur * (1 - prev.fill) + 1e-6);
        if (o <= window_frost_out) try std.testing.expectEqual(window(min_opacity).blur, w.blur);
    }
}

test "the opacity only goes one way: colour comes in, the shine only goes" {
    var i: usize = 2;
    while (i <= 100) : (i += 1) {
        const a = way(at(i - 1, 100));
        const b = way(at(i, 100));
        try std.testing.expect(b.tint >= a.tint and b.top >= a.top and b.shine <= a.shine);
        try std.testing.expect(base(at(i, 100), true).alpha >= base(at(i - 1, 100), true).alpha);
    }
}

test "a lens over a picture leaves its middle as it is, at every opacity" {
    var i: usize = 1;
    while (i <= 20) : (i += 1) {
        const t = at(i, 20);
        const l = forLens(inApp(t));
        try std.testing.expectEqual(@as(f32, 0), l.frost);
        try std.testing.expectEqual(@as(f32, 0), l.mix);
        try std.testing.expectEqual(@as(f32, 0), l.lift);
        // Its edge is the glass all the same.
        try std.testing.expectEqual(inApp(t).bend, l.bend);
        try std.testing.expectEqual(inApp(t).rim, l.rim);
    }
}

test "the lens's edge is whole whatever the frost: it bends and folds as the clear lens does" {
    var i: usize = 1;
    while (i <= 16) : (i += 1) {
        const l = inApp(at(i, 20)); // up to `shine_start`
        try std.testing.expectEqual(@as(f32, 1.1), l.bend);
        try std.testing.expectEqual(@as(f32, 0.9), l.clarity);
        try std.testing.expectEqual(@as(f32, 1), l.rim);
        try std.testing.expect(l.frost > 0.5);
        try std.testing.expectEqual(@as(f32, 1), frosted(at(i, 20)).refraction);
    }
}

test "a drop is glass until the top, not a disc of colour, and glass even in a clear window" {
    try std.testing.expectEqual(@as(f32, 0), native(0.7).fill);
    try std.testing.expectEqual(@as(f32, 0), inApp(0.7).mix);
    try std.testing.expectEqual(@as(f32, 0.7), forText(inApp(0.7)).mix);
    try std.testing.expectEqual(native(min_opacity), native(0));
    try std.testing.expect(native(0).glass > 0 and native(0).over_share >= drop_frost_min);
}

test "the clearing bevel hugs the rim of small glass and stops growing on large" {
    const small = band(20);
    try std.testing.expectApproxEqAbs(@as(f32, 0.29 * 20), small.clear + small.feather, 1e-4);
    const large = band(400);
    try std.testing.expectApproxEqAbs(bevel_cap, large.clear + large.feather, 1e-4);
    try std.testing.expect(large.clear <= large.feather);
    try std.testing.expectEqual(@as(f32, 0), band(0).feather);
}

test "glass carrying text is wholly frosted: nothing sharp shows through a dialog" {
    var i: usize = 1;
    while (i <= 20) : (i += 1) try std.testing.expectEqual(@as(f32, 1), forText(inApp(at(i, 20))).frost);
    try std.testing.expectEqual(@as(f32, 0), forText(inApp(0)).frost);
}

test "both forms share the way" {
    var i: usize = 1;
    while (i <= 20) : (i += 1) {
        const o = at(i, 20);
        try std.testing.expectApproxEqAbs(native(o).over_share, forDrops(inApp(o)).frost * drop_frost, 1e-6);
        try std.testing.expectEqual(native(o).fill, inApp(o).mix);
    }
}
