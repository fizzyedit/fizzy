//! `core.dialogs` — the dialog framework, its window chrome, and the transient feedback that
//! shares it: toasts, spinners, the save bubble.
//!
//! Grouped by what they are for rather than by what they draw with. A dialog here is a `dvui`
//! subwindow plus fizzy's own header, close-rect handoff (so a dialog can shrink *into* the row
//! that caused it), and the modal bookkeeping the titlebar and the canvas both read.
//!
//! `core` and not the app, because plugins raise dialogs too, and a plugin's dialog must look
//! like the app's — see `core.widgets` for the divide.
const std = @import("std");
const dvui = @import("dvui");
const rounding = @import("corners.zig");
const liquid_glass = @import("gfx/liquid_glass.zig");
const motion = @import("motion.zig");
const icon_tex = @import("gfx/icon.zig");
const builtin = @import("builtin");
const icons = @import("icons");
const platform = @import("platform.zig");
const widgets = @import("widgets.zig");
const anchor = @import("replay").anchor;
const anim = @import("anim.zig");
const draw = @import("draw.zig");
const screens = @import("screens.zig");

/// Core-owned dialog chrome state, set by the dialog framework and read by
/// fizzy so core stays decoupled from the editor. When a modal is open fizzy
/// dims the titlebar.
pub var modal_dim_titlebar: bool = false;

/// The host's dialog chrome, handed to a plugin dylib at load (`sdk.runtime.installRuntime`,
/// from `EditorAPI`). A dylib has its own copy of this file; without these, `dialog` would
/// register *its* `dialogWindow` with dvui and draw the frame itself — with its own idea of
/// the style, its own backend hooks, its own build of the frost. With them the plugin
/// contributes a body (`displayFn`) and the host draws the window around it: one frame, one
/// frost, one set of settings, whatever SDK the plugin was built against. Null in the host.
pub const HostChrome = struct {
    dialog_window: dvui.Dialog.DisplayFn,
    frost_pane: *const fn (id: dvui.Id, rect: dvui.Rect.Physical, corners: dvui.CornerRect, scale: f32) bool,
};
pub var host_chrome: ?HostChrome = null;

/// How the app wants its dialogs to look: the palette's and every `core.dialogs` window's, in
/// the host and in every plugin dylib alike. Not globals — a dylib has its own copy of this
/// file, and a global set in the host is never seen there. It lives in the dvui data store on
/// the window's id instead: one `dvui.Window` is shared by everyone, so `style()` reads the
/// same bytes wherever it is called from. The host writes it every frame (`publishStyle`).
pub const Style = extern struct {
    /// How much a modal window dims what is behind it, 0 (none) to 1. 1 is a little past
    /// dvui's default scrim (60/255 dark, 80/255 light), which sits at about 0.8 here.
    modal_dim: f32 = 0.8,
    /// How much of a dialog is its own colour rather than the glass behind it, 0…1: the window's
    /// opacity (`glass_look`).
    opacity: f32 = 0.3,
    /// The frost's blur radius (`FloatingWindowWidget.Frost.radius`), the window's roughness
    /// (`glass_look.frosted`); under `BlurBackdrop.min_blur` the glass is clear.
    blur: f32 = 20,
    /// What a bare stretch of the app's chrome is on screen — the window base (the content
    /// fill at window opacity, over the OS material). A fully opaque dialog is drawn as
    /// exactly this, so it matches the explorer's empty space. Only meaningful once the host
    /// has published (`has_chrome`); until then `chromeColor` reads the theme's content fill,
    /// so nothing here names a colour of its own.
    chrome: [4]u8 = .{ 0, 0, 0, 0 },
    has_chrome: bool = false,
    /// A light lift over the whole pane, 0…1: white added on top of frost and tint. 1 adds ~15%
    /// white. The host writes 0 — the window's two sliders are the glass now — and keeps the field
    /// for the layout plugins were built against.
    lift: f32 = 0.3,
    /// Unused: once how much of what is behind the frost stayed readable. The host writes 0; the
    /// field stays for the layout plugins were built against.
    detail: f32 = 0.3,

    pub fn chromeColor(self: Style) dvui.Color {
        if (!self.has_chrome) return dvui.themeGet().color(.content, .fill);
        return .{ .r = self.chrome[0], .g = self.chrome[1], .b = self.chrome[2], .a = self.chrome[3] };
    }
};

const style_key = "fizzy_dialog_style";

/// The host's `Style` for this frame, or the defaults before the host has published one.
pub fn style() Style {
    const cw = dvui.currentWindow();
    return dvui.dataGet(null, cw.data().id, style_key, Style) orelse .{};
}

/// Host only: write this frame's `Style` where every dylib's `style()` finds it.
pub fn publishStyle(s: Style) void {
    const cw = dvui.currentWindow();
    dvui.dataSet(null, cw.data().id, style_key, s);
}

/// The frost a dialog asks its floating window for: the style's blur, tinted with the chrome
/// colour, mixed by its opacity. Under the least blur a pane draws, clear glass (`clearFrost`)
/// where the glass program is there to draw it; null where it is not — the caller then paints
/// `dialogFill()` as an ordinary background.
pub fn dialogFrost() ?widgets.FloatingWindowWidget.Frost {
    const s = style();
    if (s.blur < widgets.BlurBackdrop.min_blur) {
        if (!widgets.LiquidField.ready()) return null;
        const c = clearFrost();
        return .{ .radius = c.radius, .refresh_ms = c.refresh_ms, .tint = c.tint, .mix = c.mix, .lift = c.lift, .refraction = c.refraction, .clear = true };
    }
    return .{
        .radius = s.blur,
        // Every frame, so what moves behind the glass moves in it — the welcome logo following
        // the pointer under a dialog stepped at 10 Hz on a 100 ms re-read. A re-read is about a
        // quarter of a millisecond in Debug now (a half-size copy and the Gaussian's few passes),
        // and it is only paid on frames something asked for: an idle app draws none.
        .refresh_ms = 0,
        .tint = s.chromeColor(),
        .mix = std.math.clamp(s.opacity, 0, 1),
        .lift = std.math.clamp(s.lift, 0, 1) * lift_max,
        .refraction = refraction(),
    };
}

/// Where the host records the dialog refraction setting — its own key beside the style, so a
/// plugin built before it existed reads the style it knows and simply never asks for this.
const refraction_key = "fizzy_dialog_refraction";

/// Host only, each frame: how far the glass's edge refracts, 0 to 1 (0.5 as designed) — the
/// window's roughness (`glass_look.frosted`).
pub fn publishRefraction(setting: f32) void {
    const cw = dvui.currentWindow();
    dvui.dataSet(null, cw.data().id, refraction_key, std.math.clamp(setting, 0, 1));
}

/// How far frosted glass's bevelled edge refracts, 0 (none) to 2: twice the setting, so its
/// middle is the glass as designed.
pub fn refraction() f32 {
    if (dvui.current_window == null) return 1;
    const cw = dvui.currentWindow();
    return 2 * (dvui.dataGet(null, cw.data().id, refraction_key, f32) orelse 0.5);
}

/// How much white `Style.lift = 1` adds.
const lift_max: f32 = 0.15;

/// Frost any floating surface — a menu, a popover — the way dialogs are frosted, at the app's
/// dialog style. `rect` is physical, `corners` the surface's own. Draw the surface's shadow
/// before this and its contents after; paint no fill — the frost's tint is the fill. Returns
/// false when the style has the blur off: paint `dialogFill()` as a plain background instead.
pub fn frostPane(id: dvui.Id, rect: dvui.Rect.Physical, corners: dvui.CornerRect, scale: f32) bool {
    if (host_chrome) |h| return h.frost_pane(id, rect, corners, scale);
    const f = dialogFrost() orelse return false;
    widgets.BlurBackdrop.frostPane(id, rect, corners, scale, .{
        .radius = f.radius,
        .refresh_ms = f.refresh_ms,
        .tint = f.tint,
        .mix = f.mix,
        .lift = f.lift,
        .refraction = f.refraction,
        .clear = f.clear,
    });
    return true;
}

/// `frostPane` for chrome over something the caller can describe: `witness` is a signature of
/// what lies under `rect`, and the frost reads it again only when that changes (or the pane
/// moves or resizes), not every frame (`BlurBackdrop.Pane.witness`). Drawn here, in the caller's
/// own copy of the frost, since the host's route (`host_chrome`) predates the witness.
pub fn frostPaneKept(id: dvui.Id, rect: dvui.Rect.Physical, corners: dvui.CornerRect, scale: f32, witness: u64) bool {
    const f = dialogFrost() orelse return false;
    widgets.BlurBackdrop.frostPane(id, rect, corners, scale, .{
        .radius = f.radius,
        .tint = f.tint,
        .mix = f.mix,
        .lift = f.lift,
        .refraction = f.refraction,
        .clear = f.clear,
        .witness = witness,
    });
    return true;
}

/// Something carried under the pointer — a tab being dragged, a view's card — as glass: frosted
/// over whatever it passes (a slot it would drop into shows through, blurred), rounded like the
/// app's cards (a capsule on anything tab-tall), its shadow a ring round it. `r` physical at
/// `scale`; `id` keys the frost. One look for a carried thing wherever it is carried: along a
/// tab strip and over the places alike.
pub fn carriedGlass(id: dvui.Id, r: dvui.Rect.Physical, scale: f32) void {
    const corners = rounding.round(rounding.card);
    if (!frostPane(id, r, corners, scale)) {
        r.fill(corners.scale(scale, dvui.CornerRect.Physical), .{ .color = .{ .color = dialogFill() }, .fade = 1 });
    }
    glassShadow(r, corners, scale, surfaceShadow(), 1);
}

/// Whether carried things are shown in windows of their own this run (fizzy's float windows on
/// macOS): a carried view's photograph is taken without the place's background, its content over
/// the window's material — set by the app before anything draws.
pub var carry_windows: bool = false;

/// `carriedGlass` for glass whose shapes run together (`LiquidField`) — the dragged view as a
/// drop — frosted at the dialog style. False when the style has the blur off, or the glass program
/// is not there to draw it: carry a card instead.
pub fn carriedField(id: dvui.Id, field: widgets.LiquidField, scale: f32) bool {
    const pane = widgets.liquidFrost() orelse return false;
    widgets.BlurBackdrop.fieldPane(id, field, scale, pane);
    return true;
}

/// `carriedField`, whole from the first frame it is drawn. For glass that carries on a shape
/// already on screen — a carried view turning from the drop of glass it was (merged, until then,
/// into the drop zones' glass) into a tab — where forming in from nothing, as a pane that comes
/// back does, blinked it out for the frames that took.
pub fn carriedFieldWhole(id: dvui.Id, field: widgets.LiquidField, scale: f32) bool {
    var pane = widgets.liquidFrost() orelse return false;
    pane.form = 1;
    widgets.BlurBackdrop.fieldPane(id, field, scale, pane);
    return true;
}

/// Clear glass at the dialog style (`BlurBackdrop.Pane.clear`): its tint, lift and edge over what
/// is behind, unblurred — glass for the blur off.
pub fn clearFrost() widgets.BlurBackdrop.Pane {
    const s = style();
    return .{
        .radius = widgets.BlurBackdrop.min_blur,
        .refresh_ms = 0,
        .tint = s.chromeColor(),
        .mix = std.math.clamp(s.opacity, 0, 1),
        .lift = std.math.clamp(s.lift, 0, 1) * lift_max,
        .refraction = refraction(),
        .clear = true,
    };
}

/// Where a carried thing would go in among others — a tab strip's open slot: a rounded fill in
/// the highlight colour, a little inside `r` (physical, at `scale`).
pub fn dropSlot(r: dvui.Rect.Physical, scale: f32) void {
    const slot = r.insetAll(2 * scale);
    if (slot.w < 1 or slot.h < 1) return;
    const radius = @min(rounding.scaled(rounding.small) * scale, @min(slot.w, slot.h) / 2);
    slot.fill(.round(radius), .{ .color = .{ .color = dvui.themeGet().color(.highlight, .fill).opacity(drop_slot_alpha) }, .fade = 1 });
}
/// How much of the highlight a drop slot is: there without shouting over the tabs beside it.
const drop_slot_alpha: f32 = 0.55;

// ---- one floating surface, everywhere ---------------------------------------------------------
//
// A dialog, the command palette, the account flyout, a menu dropdown and a store card's hover
// panel are all the same object: something floating over the app, frosted, rounded, shadowed,
// holding rows that light up under the pointer. They looked like four different objects because
// each one wrote its own numbers. These are those numbers, in one place, taken from the command
// palette — the surface the rest are measured against.
//
// A surface: `surfaceCorners` + `surface_padding` + `surfaceShadow()` + `dialogFill()`, frosted
// with `dialogFrost()`. A row inside it: `rowCorners`, `rowHover()`, `rowPress()`.

/// The radius a floating surface is cut with, at the user's corner roundness (`core.corners`).
/// `all` rather than `round`: it carries the theme's corner *kind* at this size, so a
/// square-cornered theme gets square surfaces.
pub fn surfaceCorners() dvui.CornerRect {
    return rounding.all(rounding.surface);
}
/// A row inside one — tighter, so a hovered row reads as sitting *in* the surface.
pub const row_radius: f32 = rounding.row;
pub fn rowCorners() dvui.CornerRect {
    return rounding.all(row_radius);
}
/// The gap between a surface's edge and its rows.
pub const surface_padding: dvui.Rect = .all(6);

/// How far in from the edges of a surface with corners of `radius` its content has to start for
/// its own corner to clear the curve: where the arc crosses the corner's diagonal, `r(1 − 1/√2)`.
/// Content pads itself a little anyway; this is what the rounding adds on top, so a surface at
/// full corner roundness does not crowd a heading into its corner — nothing at square corners,
/// a couple of points at the default, nearly five at full. Give it as padding to anything whose
/// content runs to its edges (`tooltipOptions` does).
pub fn cornerInset(radius: f32) f32 {
    return @max(0, radius) * (1 - std.math.sqrt1_2);
}

/// The drop shadow under a floating surface. Its corners resolved against the theme: a box
/// shadow's corners are not finalized the way a widget's are, and an unresolved corner draws
/// square whatever radius it names — square shadow corners stood out past rounded glass.
pub fn surfaceShadow() dvui.Options.BoxShadow {
    const theme = dvui.themeGet();
    return .{ .color = .black, .fade = 8, .corners = surfaceCorners().finalize(&theme), .alpha = 0.25 };
}

/// A frosted surface's shadow: `bs` as a ring round `r` (physical) with the surface's `corners`,
/// drawn after the glass so the glass never blurs it in (`liquid_glass.drawShadow`). Call after
/// the frost; an opaque surface keeps the ordinary box shadow under its fill.
pub fn glassShadow(r: dvui.Rect.Physical, corners: dvui.CornerRect, scale: f32, bs: dvui.Options.BoxShadow, alpha_mult: f32) void {
    // The glass's own outline, always: the ring hugs the pane, whatever corners the shadow was
    // described with (resolved through the theme's corner kind, they could come out square
    // beside glass that is explicitly round).
    const theme = dvui.themeGet();
    const c = corners.finalize(&theme);
    const radii: liquid_glass.Radii = .{ c.tl.radius() * scale, c.bl.radius() * scale, c.br.radius() * scale, c.tr.radius() * scale };
    liquid_glass.drawShadow(r.insetAll(scale * bs.shrink), radii, bs.fade * scale, bs.offset.scale(scale, dvui.Point.Physical), bs.color, bs.alpha * alpha_mult);
}

// ---- tooltips: the same surface, small ------------------------------------------------------
//
// A tooltip is a floating surface like any other, so it wears the same frost, fill, corners and
// shadow. dvui's tooltip widgets paint their own background inside `init`/`install`, before
// anything can get beneath it, and the frost *replaces* what it covers — so a tooltip is told to
// paint nothing (`tooltipOptions`) and `tooltipSurface` lays the surface down under its contents.

/// A tooltip's own options: no background, border or shadow of its own — `tooltipSurface` draws
/// them. Corners explicitly round: `surfaceCorners` is `.all`, which leaves the corner *kind*
/// to the theme, and only a widget's options resolve that — handed straight to the frost it
/// drew square.
pub fn tooltipOptions(id_extra: usize) dvui.Options {
    return .{
        .id_extra = id_extra,
        .background = false,
        .border = .all(0),
        .corners = tooltipCorners(),
        // Whatever the tooltip holds keeps clear of its corners, however round they are.
        .padding = .all(cornerInset(tooltipCorners().tl.radius())),
    };
}

fn tooltipCorners() dvui.CornerRect {
    return rounding.round(rounding.surface);
}

/// The surface under a shown tooltip, from its widget data, at full strength — see
/// `tooltipSurfaceFaded`. Call once the tooltip is shown, before its contents.
pub fn tooltipSurface(wd: *dvui.WidgetData) void {
    tooltipSurfaceFaded(wd, 1);
}

/// The surface under a shown tooltip at `fade` (0…1): shadow, then the frost (its tint is the
/// fill) — the order a frosted surface needs, since the frost replaces what it covers and a
/// shadow drawn first survives only outside. With the blur off, the plain `dialogFill`.
///
/// Fading a frost is not fading its alpha: the frost *replaces* what it covers, so at partial
/// alpha it would punch a half-transparent hole. It forms instead — blur radius, tint and lift
/// all rise with `fade` — and at no radius a frost is an exact copy of what is behind it, so a
/// tooltip fading in goes from invisible to glass rather than appearing whole while its text
/// fades in over it.
pub fn tooltipSurfaceFaded(wd: *dvui.WidgetData, fade: f32) void {
    tooltipSurfaceWith(wd, fade, fade);
}

/// `tooltipSurfaceFaded` with the frost's fade and the plain paint's (shadow, blur-off fill)
/// apart: under a fade that already scales everything drawn (a tooltip's own alpha animation),
/// the plain paint takes 1 — it is faded once by that alpha — while the frost, drawn later and
/// outside it, still needs the fade to form by. It grows over the whole of the fade.
fn tooltipSurfaceWith(wd: *dvui.WidgetData, frost_fade: f32, paint_fade: f32) void {
    const t = std.math.clamp(frost_fade, 0, 1);
    tooltipSurfaceAt(wd, t, motion.enterFull(t), paint_fade);
}

/// The surface under a shown tooltip: formed `form` of the way (0…1), grown `grow` of the way
/// out of the point the pointer was at (past 1 while it overshoots), its plain paint at
/// `paint_fade`.
fn tooltipSurfaceAt(wd: *dvui.WidgetData, form: f32, grow: f32, paint_fade: f32) void {
    const t = std.math.clamp(form, 0, 1);
    const p = std.math.clamp(paint_fade, 0, 1);
    const brs = wd.borderRectScale();
    // It grows out of where the pointer was when it began to show, and what it holds is cut to
    // it as it grows — the tooltip opens from the thing it is about, as a menu slides open from
    // what opened it.
    const r = tooltipGrown(wd, brs.r, grow);
    tooltipGlass(wd, r, brs.s, t, p);
    // Only now: the shadow ring lies outside the glass, and cut to its rect it was nothing but
    // dark square wedges behind the round corners.
    dvui.clipSet(dvui.clipGet().intersect(r));
}

/// A tooltip's glass over `r` (physical, at `scale`), formed `t`, its plain paint at `p`: the
/// frost, or with the blur off the plain fill, and the shadow ring round either.
fn tooltipGlass(wd: *dvui.WidgetData, r: dvui.Rect.Physical, scale: f32, t: f32, p: f32) void {
    const phys_corners = tooltipCorners().scale(scale, dvui.CornerRect.Physical);
    const bs = surfaceShadow();
    const f = dialogFrost() orelse {
        const prect = r.insetAll(scale * bs.shrink).offsetPoint(bs.offset.scale(scale, dvui.Point.Physical));
        prect.fill(phys_corners, .{ .color = .{ .color = bs.color.opacity(bs.alpha * p) }, .fade = scale * bs.fade });
        r.fill(phys_corners, .{ .color = .{ .color = dialogFill().opacity(p) } });
        return;
    };
    // The shadow as a ring round the glass, after it (`glassShadow`), so the glass does not blur
    // it in; deferred behind the frost by drawing it once the frost is queued.
    defer glassShadow(r, tooltipCorners(), scale, bs, p);
    // Under a couple of pixels of blur there is nothing to see yet, and too little for the blur
    // to make a pass at all.
    if (f.radius * t < 2) return;
    widgets.BlurBackdrop.frostPane(wd.id, r, tooltipCorners(), scale, .{
        .radius = f.radius,
        .refresh_ms = f.refresh_ms,
        .tint = f.tint,
        .mix = f.mix,
        .lift = f.lift,
        .refraction = f.refraction,
        .clear = f.clear,
        .form = t,
    });
}

/// `full` — a shown tooltip's rect — `k` of the way grown out of the point the pointer was at
/// when this showing began (held inside the tooltip, so it grows from its nearest edge when the
/// pointer is beside it). A showing begins when the tooltip is drawn after a pause.
fn tooltipGrown(wd: *dvui.WidgetData, full: dvui.Rect.Physical, grow: f32) dvui.Rect.Physical {
    // Kept only while drawn every frame (`tooltipClock`): gone, this is a new showing.
    const at = dvui.dataGet(null, wd.id, "_tooltip_origin", dvui.Point.Physical) orelse blk: {
        const mouse = dvui.currentWindow().mouse_pt;
        dvui.dataSet(null, wd.id, "_tooltip_origin", mouse);
        break :blk mouse;
    };
    const o: dvui.Point.Physical = .{
        .x = std.math.clamp(at.x, full.x, full.x + full.w),
        .y = std.math.clamp(at.y, full.y, full.y + full.h),
    };
    const k = @max(0, grow);
    return .{
        .x = o.x + (full.x - o.x) * k,
        .y = o.y + (full.y - o.y) * k,
        .w = full.w * k,
        .h = full.h * k,
    };
}

/// How far into this showing a tooltip is, 0…1, linear over a floating surface's opening time
/// (`motion.open_us`) — the clock a menu slides open on, so the two open together. A showing
/// starts on the first frame it is drawn after a frame it was not, so a tooltip that hides and
/// comes back opens again — a tooltip widget exists every frame whether shown or not, so its
/// first frame will not do.
///
/// Told by frames, not time: dvui drops a data entry nobody touched in a frame, so the marker
/// here is present exactly when the tooltip was drawn in the last one — however long ago that
/// was. A gap in time said "hidden" whenever the app slept between mouse moves, and the tooltip
/// opened again on every move after a pause.
fn tooltipClock(wd: *dvui.WidgetData) f32 {
    const shown_before = dvui.dataGet(null, wd.id, "_tooltip_shown", bool) != null;
    dvui.dataSet(null, wd.id, "_tooltip_shown", true);
    if (!shown_before) {
        _ = dvui.currentWindow().animations.remove(wd.id.update("_tooltip_open"));
        dvui.animation(wd.id, "_tooltip_open", .{ .start_val = 0, .end_val = 1, .end_time = motion.duration(motion.open_us) });
    }
    return if (dvui.animationGet(wd.id, "_tooltip_open")) |a| std.math.clamp(a.value(), 0, 1) else 1;
}

/// How far a tooltip has faded in this showing, 0…1 (`motion.fade` on `tooltipClock`).
/// `duration_us` is kept for callers written against the older clock of their own; a tooltip
/// now opens on the menus' clock, whatever it asks for.
pub fn tooltipFade(wd: *dvui.WidgetData, duration_us: i32) f32 {
    _ = duration_us;
    return motion.fade(tooltipClock(wd));
}

/// A shown tooltip's surface and fade in one: the glass forming and growing out of the pointer as
/// a menu slides open (`tooltipClock`), and the same fade on everything drawn after — the
/// tooltip's contents — so glass and text arrive together. Returns the alpha to restore once the
/// contents are drawn:
///
///     if (tt.shown()) {
///         const prev = core.dialogs.tooltipBegin(tt.data(), 350_000);
///         defer dvui.alphaSet(prev);
///         // contents
///     }
///
/// `duration_us` as `tooltipFade`'s: kept, not used.
pub fn tooltipBegin(wd: *dvui.WidgetData, duration_us: i32) f32 {
    _ = duration_us;
    const u = tooltipClock(wd);
    const t = motion.fade(u);
    tooltipSurfaceAt(wd, t, motion.enter(u), t);
    return dvui.alpha(t);
}

/// `tooltipBegin` for a floating tooltip widget: `core.widgets.FloatingTooltipWidget` (the one that
/// opens on the screen of the window it is in: a popped-out float's) or dvui's own, which a plugin
/// built before core had one passes — the same `animate` and `data()`, so either compiles, and a
/// plugin repinned to a newer SDK keeps building unchanged. A tooltip with a `delay` is "shown" from
/// the moment the pointer arrives and hides its contents behind its own alpha animation (nothing
/// for 80% of the delay, then a quick fade): the glass waits for that to begin — so it does not
/// form, dark tint and all, while the text still waits out the delay — and then opens on the
/// menus' clock like any other tooltip, rather than riding the widget's fade, which runs over a
/// fifth of the delay and played the whole grow in a blink. Returns the alpha to restore after
/// the contents, as `tooltipBegin` does.
pub fn tooltipBeginFor(tt: anytype, duration_us: i32) f32 {
    if (tt.animate) |fade_in| {
        // Still waiting out the delay: nothing, and no showing begun yet.
        if ((fade_in.val orelse 1) <= 0.01) return dvui.alpha(1);
    }
    return tooltipBegin(tt.data(), duration_us);
}

/// The wash under the pointer, and under the palette's selected row — the same colour, so a
/// keyboard selection and a hover are one idea.
///
/// Asked of the theme rather than stated here: dvui derives `fill_hover` from a style's fill
/// (`Theme.adjustColorForState`, ±10% by `dark`) unless the theme names one, so a theme that
/// wants a stronger hover says so once and every surface follows — this, the palette, the
/// flyouts, and the rows a menu draws.
pub fn rowHover() dvui.Color {
    return dvui.themeGet().color(row_style, .fill_hover);
}

/// A row being activated.
pub fn rowPress() dvui.Color {
    return dvui.themeGet().color(row_style, .fill_press);
}

/// The style a row inside a floating surface takes its colours from.
pub const row_style: dvui.Theme.Style.Name = .control;

/// The fill a dialog paints when there is no frost to composite with: the chrome at the
/// dialog's opacity, lifted the same amount.
pub fn dialogFill() dvui.Color {
    const s = style();
    var c = s.chromeColor();
    c.a = @intFromFloat(@round(@as(f32, @floatFromInt(c.a)) * std.math.clamp(s.opacity, 0, 1)));
    return c.lerp(.white, std.math.clamp(s.lift, 0, 1) * lift_max);
}

/// The scrim alpha for `modal_dim`, scaled by `t` (a window's reveal, 0…1).
pub fn modalDimAlpha(t: f32) u8 {
    const base: f32 = if (dvui.themeGet().dark) 75 else 100;
    return @intFromFloat(@round(base * std.math.clamp(style().modal_dim, 0, 1) * std.math.clamp(t, 0, 1)));
}

/// Key/id for the dialog close-rect handoff below. A fixed string rather than `@src()`
/// because `Id.extendId` hashes the *module* pointer, which differs per copy.
const dialog_close_rect_key = "fizzy_dialog_close_rect_override";

fn dialogCloseRectId() dvui.Id {
    return dvui.Id.zero.update(dialog_close_rect_key);
}

/// Re-aim an open dialog's close animation at `rect`, so it shrinks *into* a specific place on
/// screen instead of collapsing to its own centre. The New File flow uses this to fly the dialog
/// into the row the file tree just grew for the new document.
///
/// Deliberately **not** a module-level `var`: `core` is linked into fizzy and into every plugin
/// dylib, so each has its own copy of any global. The module that knows the destination (the
/// workbench's file tree) is never the module drawing the dialog (the plugin that owns the New
/// Document dialog), and a global would leave each of them talking to itself. dvui's data store
/// hangs off the one `Window` every module is handed through `dvui_context.zig`, which makes it
/// the only state they all agree on.
///
/// Safe to call while the dialog is already shrinking: `FloatingWindowWidget` re-targets each
/// axis in flight, preserving progress, so a row that only appears part-way through the close
/// still gets flown into rather than snapped to.
pub fn setDialogCloseRectOverride(rect: dvui.Rect.Physical) void {
    dvui.dataSet(null, dialogCloseRectId(), dialog_close_rect_key, rect);
}

/// Consume a pending override, if any. One-shot, so the next dialog starts clean.
pub fn takeDialogCloseRectOverride() ?dvui.Rect.Physical {
    const id = dialogCloseRectId();
    const rect = dvui.dataGet(null, id, dialog_close_rect_key, dvui.Rect.Physical) orelse return null;
    dvui.dataRemove(null, id, dialog_close_rect_key);
    return rect;
}

pub const DisplayFn = *const fn (dvui.Id) anyerror!bool;
pub const CallAfterFn = *const fn (dvui.Id, dvui.enums.DialogResponse) anyerror!void;

/// Header type icon for `windowHeader` (glyph only). Placement follows `dvui.currentWindow().button_order`:
/// `.cancel_ok` (macOS): dismiss close on the leading edge, icon on the trailing edge.
/// `.ok_cancel` (e.g. Windows): icon on the leading edge, close on the trailing edge.
pub const DialogHeaderKind = enum(u8) {
    none = 0,
    info,
    warning,
    err,
};

/// Yellow for `.warning` header glyphs (readable in light and dark themes).
pub const dialog_header_warning_fill: dvui.Color = .{ .r = 234, .g = 179, .b = 8 };

/// Emerald success green for save-complete checkmarks (not theme `.highlight`).
pub fn saveDoneCheckFill(alpha: f32) dvui.Color {
    const c: dvui.Color = if (dvui.themeGet().dark)
        .{ .r = 74, .g = 222, .b = 128 }
    else
        .{ .r = 22, .g = 163, .b = 74 };
    return c.opacity(alpha);
}

pub const DialogOptions = struct {
    window: ?*dvui.Window = null,
    id_extra: usize = 0,
    windowFn: dvui.Dialog.DisplayFn = dialogWindow,
    displayFn: DisplayFn = defaultDialogDisplay,
    callafterFn: CallAfterFn = defaultDialogCallAfter,
    resizeable: bool = true,
    modal: bool = true,
    title: []const u8 = "",
    ok_label: []const u8 = "Ok",
    cancel_label: []const u8 = "Cancel",
    default: dvui.enums.DialogResponse = .ok,
    /// When set, caps the floating window content (e.g. unsaved prompt). Omit for Export / New File so they can grow vertically.
    max_size: ?dvui.Options.MaxSize = null,
    /// When true, only the header and `displayFn` are shown; footer OK/Cancel are omitted (e.g. three custom actions).
    hide_footer: bool = false,
    /// Optional header type icon; side follows `button_order` like the footer (see `DialogHeaderKind`).
    header_kind: DialogHeaderKind = .none,
};

pub fn defaultDialogDisplay(id: dvui.Id) anyerror!bool {
    // Placeholder body; every real dialog supplies its own `displayFn`. Kept free
    // of plugin (atlas/sprite) draws so the core dialog code stays plugin-agnostic.
    _ = id;
    return true;
}

pub fn defaultDialogCallAfter(id: dvui.Id, response: dvui.enums.DialogResponse) anyerror!void {
    switch (response) {
        .ok => {
            dvui.log.info("Dialog callafter for {d} returned {any}", .{ id, response });
        },
        .cancel => {
            dvui.log.info("Dialog callafter for {d} returned {any}", .{ id, response });
        },
        else => {},
    }
}

/// True when a document canvas should not hide the OS cursor, draw tool cursors, or consume
/// pointer events. Asked while the canvas draws, of the subwindow it draws in: the main window's,
/// or a float's (`app/layout/Floats.zig`), whose canvas takes the pointer as one in the main
/// window does.
/// - Modal dialogs: always block the canvas (not in-dialog previews).
/// - Any other window over the pointer — a non-modal dialog (e.g. Export), a menu, a float over
///   the canvas's own — blocks it only while the pointer is over that window.
pub fn canvasPointerInputSuppressed() bool {
    const cw = dvui.currentWindow();
    const here = dvui.subwindowCurrentId();
    for (cw.subwindows.stack.items[1..]) |sub| {
        if (sub.modal and sub.id != here) return true;
    }
    const target = cw.subwindows.windowFor(cw.mouse_pt);
    return target != .zero and target != here;
}

/// In-dialog preview canvases (Grid Layout): allow pan/zoom while the pointer is over the
/// dialog subwindow that owns the preview.
pub fn dialogCanvasPointerInputSuppressed() bool {
    const cw = dvui.currentWindow();
    const sub = cw.subwindows.current() orelse return true;
    const target = cw.subwindows.windowFor(cw.mouse_pt);
    return target != sub.id;
}

/// Creates a new file dialog with necessary data set and returns the id mutex.
/// Caller must unlock the mutex after setting any additional data on the id.
pub fn dialog(src: std.builtin.SourceLocation, opts: DialogOptions) dvui.IdMutex {
    // The default frame is the host's where there is one (see `HostChrome`); a caller that
    // brought its own `windowFn` keeps it.
    const window_fn: dvui.Dialog.DisplayFn = if (opts.windowFn == &dialogWindow)
        (if (host_chrome) |h| h.dialog_window else opts.windowFn)
    else
        opts.windowFn;
    const id_mutex = dvui.dialogAdd(opts.window, src, opts.id_extra, window_fn);
    const id = id_mutex.id;

    dvui.dataSet(opts.window, id, "_modal", opts.modal);
    // Where dialogs are windows of their own, a dialog belongs to the window it was asked from — a
    // float that is out, or the main window — and opens over it (`screens.screenFor`).
    if (screens.nativeDialogs()) dvui.dataSet(opts.window, id, "_center_on", screens.screenFor((opts.window orelse dvui.currentWindow()).subwindows.current_rect));
    dvui.dataSetSlice(opts.window, id, "_title", opts.title);
    //dvui.dataSet(opts.window, id, "_center_on", (opts.window orelse dvui.currentWindow()).subwindows.current_rect);
    dvui.dataSetSlice(opts.window, id, "_ok_label", opts.ok_label);
    dvui.dataSetSlice(opts.window, id, "_cancel_label", opts.cancel_label);
    dvui.dataSet(opts.window, id, "_default", opts.default);
    dvui.dataSet(opts.window, id, "_callafter", opts.callafterFn);
    dvui.dataSet(opts.window, id, "_displayFn", opts.displayFn);
    dvui.dataSet(opts.window, id, "_resizeable", opts.resizeable);
    dvui.dataSet(opts.window, id, "_hide_footer", opts.hide_footer);
    if (opts.max_size) |ms| {
        dvui.dataSet(opts.window, id, "_max_size", ms);
    }
    dvui.dataSet(opts.window, id, "_open", true);
    dvui.dataSet(opts.window, id, "_header_kind", @intFromEnum(opts.header_kind));

    return id_mutex;
}

/// Shrink the current modal subwindow to a point to run the standard close animation. Call from dialog content (e.g. custom buttons).
pub fn closeFloatingDialogAnchored() void {
    const sub = dvui.currentWindow().subwindows.current() orelse return;
    var close_rect = sub.rect_pixels;
    close_rect.x = close_rect.center().x;
    close_rect.y = close_rect.center().y;
    close_rect.w = 1;
    close_rect.h = 1;
    dvui.dataSet(null, sub.id, "_close_rect", close_rect);
}

pub fn dialogWindow(id: dvui.Id) anyerror!void {
    const modal = dvui.dataGet(null, id, "_modal", bool) orelse {
        dvui.log.err("dialogDisplay lost data for dialog {x}\n", .{id});
        dvui.dialogRemove(id);
        return;
    };

    // In a window of its own (`screens.nativeDialogs`), the main window is left as it is.
    const native = screens.nativeDialogs();
    if (modal and !native) {
        modal_dim_titlebar = true;
    }

    const title = dvui.dataGetSlice(null, id, "_title", []u8) orelse {
        dvui.log.err("dialogDisplay lost data for dialog {x}\n", .{id});
        dvui.dialogRemove(id);
        return;
    };

    const ok_label = dvui.dataGetSlice(null, id, "_ok_label", []u8) orelse {
        dvui.log.err("dialogDisplay lost data for dialog {x}\n", .{id});
        dvui.dialogRemove(id);
        return;
    };

    const resizeable = dvui.dataGet(null, id, "_resizeable", bool) orelse false;

    const center_on = dvui.dataGet(null, id, "_center_on", dvui.Rect.Natural) orelse dvui.currentWindow().subwindows.current_rect;

    const cancel_label = dvui.dataGetSlice(null, id, "_cancel_label", []u8);
    const default = dvui.dataGet(null, id, "_default", dvui.enums.DialogResponse);

    const callafter = dvui.dataGet(null, id, "_callafter", CallAfterFn);
    const displayFn = dvui.dataGet(null, id, "_displayFn", DisplayFn);

    const maxSize = dvui.dataGet(null, id, "_max_size", dvui.Options.MaxSize);
    const hide_footer = dvui.dataGet(null, id, "_hide_footer", bool) orelse false;

    var win = widgets.floatingWindow(@src(), .{
        .modal = modal,
        .modal_alpha = modalDimAlpha(1),
        .center_on = center_on,
        .window_avoid = .nudge,
        .process_events_in_deinit = true,
        .resize = if (resizeable) .all else .none,
        .frost = dialogFrost(),
        .native = native,
    }, .{
        .id_extra = id.asUsize(),
        .color_text = .black,
        .corners = rounding.all(rounding.control),
        .max_size_content = maxSize,
        .border = .all(0),
        .color_fill = .{ .color = dialogFill() },
        .box_shadow = .{
            .color = .black,
            .alpha = 0.35,
            .fade = 10,
            .corners = rounding.all(rounding.control),
        },
    });
    defer win.deinit();

    // Applied *before* the animation check, not as an `else if` to it: the OK handler below
    // starts the shrink-to-centre close immediately (so a dialog can never wedge open waiting
    // for a row that never arrives), which means by the time the tree has drawn the new row
    // there is always an animation in flight. Writing `_close_rect` re-aims it mid-flight.
    const close_override = takeDialogCloseRectOverride();
    if (close_override) |close_rect| {
        dvui.dataSet(null, win.data().id, "_close_rect", close_rect);
    }

    if (dvui.animationGet(win.data().id, "_close_x")) |a| {
        if (a.done()) {
            dvui.dialogRemove(id);
        }
    } else if (close_override == null) {
        win.autoSize();
    }

    { // Common window header
        var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
        defer vbox.deinit();

        const header_kind: DialogHeaderKind = switch (dvui.dataGet(null, id, "_header_kind", u8) orelse 0) {
            @intFromEnum(DialogHeaderKind.none) => .none,
            @intFromEnum(DialogHeaderKind.info) => .info,
            @intFromEnum(DialogHeaderKind.warning) => .warning,
            @intFromEnum(DialogHeaderKind.err) => .err,
            else => .none,
        };

        var header_openflag = true;
        win.dragAreaSet(windowHeader(title, "", &header_openflag, header_kind));
        if (!header_openflag) {
            if (callafter) |ca| {
                ca(id, .cancel) catch |err| {
                    dvui.log.err("Dialog callafter for {x} returned {s}", .{ id, @errorName(err) });
                    return;
                };
            }

            var close_rect = win.data().rectScale().r;
            close_rect.x = close_rect.center().x;
            close_rect.y = close_rect.center().y;
            close_rect.w = 1;
            close_rect.h = 1;

            dvui.dataSet(null, win.data().id, "_close_rect", close_rect);
        }
    }

    var valid: bool = true;

    { // Actual dialog content
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .padding = .all(8),
            .expand = .horizontal,
            .gravity_x = 0.5,
        });
        defer hbox.deinit();

        const clip = dvui.clip(hbox.data().contentRectScale().r);
        defer dvui.clipSet(clip);

        if (displayFn) |df| {
            valid = df(id) catch false;
        }
    }

    if (!hide_footer) { // OK and Cancel buttons
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5 });
        defer hbox.deinit();

        if (cancel_label) |cl| {
            var cancel_data: dvui.WidgetData = undefined;
            const gravx: f32, const tindex: u16 = switch (dvui.currentWindow().button_order) {
                .cancel_ok => .{ 0.0, 1 },
                .ok_cancel => .{ 1.0, 3 },
            };
            if (dvui.button(@src(), cl, .{}, .{
                .tab_index = tindex,
                .data_out = &cancel_data,
                .gravity_x = gravx,
                .box_shadow = .{
                    .color = .black,
                    .alpha = 0.25,
                    .offset = .{ .x = -4, .y = 4 },
                    .fade = 8,
                },
            })) {
                if (callafter) |ca| {
                    ca(id, .cancel) catch |err| {
                        dvui.log.err("Dialog callafter for {x} returned {s}", .{ id, @errorName(err) });
                        return;
                    };
                }

                var close_rect = win.data().rectScale().r;
                close_rect.x = close_rect.center().x;
                close_rect.y = close_rect.center().y;
                close_rect.w = 1;
                close_rect.h = 1;

                dvui.dataSet(null, win.data().id, "_close_rect", close_rect);
            }
            if (default != null and dvui.firstFrame(hbox.data().id) and default.? == .cancel and !valid) {
                dvui.focusWidget(cancel_data.id, null, null);
            }
        }

        const alpha = dvui.alpha(if (valid) 1.0 else 0.5);
        defer dvui.alphaSet(alpha);

        var ok_data: dvui.WidgetData = undefined;
        const ok_opts: dvui.Options = .{
            .tab_index = 2,
            .data_out = &ok_data,
            .style = if (valid) .highlight else .control,
            .box_shadow = .{
                .color = .black,
                .alpha = 0.25,
                .offset = .{ .x = -4, .y = 4 },
                .fade = 8,
            },
        };
        var ok_button: dvui.ButtonWidget = undefined;
        ok_button.init(@src(), .{}, ok_opts);

        if (valid) ok_button.processEvents();
        ok_button.drawFocus();
        ok_button.drawBackground();

        dvui.labelNoFmt(@src(), ok_label, .{}, ok_opts.strip().override(ok_button.style()).override(.{ .gravity_x = 0.5, .gravity_y = 0.5 }));

        defer ok_button.deinit();

        if (ok_button.clicked()) {
            if (!valid) return;
            if (callafter) |ca| {
                ca(id, .ok) catch |err| {
                    dvui.log.err("Dialog callafter for {x} returned {s}", .{ id, @errorName(err) });
                    return;
                };
            }
            // Always close on OK, and always with a real destination — the dialog's own centre.
            // An earlier version instead *withheld* the close for a "New File" dialog created
            // inside an explorer folder, waiting for the tree to spot the new file and supply a
            // row to fly into; when that row failed to appear the dialog wedged open with no
            // fallback. Starting the close unconditionally removes the failure mode: if the row
            // does show up mid-animation it re-aims the close through
            // `setDialogCloseRectOverride` (handled at the top of this function), and if it never
            // does, this shrink-to-centre is what the user sees.
            var close_rect_ok = win.data().rectScale().r;
            close_rect_ok.x = close_rect_ok.center().x;
            close_rect_ok.y = close_rect_ok.center().y;
            close_rect_ok.w = 1;
            close_rect_ok.h = 1;
            dvui.dataSet(null, win.data().id, "_close_rect", close_rect_ok);
        }
        if (default != null and dvui.firstFrame(hbox.data().id) and default.? == .ok and valid) {
            dvui.focusWidget(ok_data.id, null, null);
        }
    }
}

/// Margin on the circular close control in `windowHeader`. Keep in sync with title label padding in `windowHeader`.
pub const window_header_close_margin = dvui.Rect.all(6);

/// Sum of top + bottom padding on the `windowHeader` title label (`.padding` `.y` + `.h`).
pub const window_header_title_vertical_pad: f32 = 8.0;

/// Inner width/height of the red close circle (dialog header + workspace tabs).
/// Blends the full title-row target (tab-style) with cap-height (what a ratio-only overlay close tended to land on) so both match.
pub fn windowHeaderCloseInnerSide() f32 {
    const fh = dvui.themeGet().font_heading;
    const row = fh.lineHeight() + window_header_title_vertical_pad;
    const m = window_header_close_margin.y + window_header_close_margin.h;
    const row_inner = @max(6.0, row - m);
    const cap_inner = @max(6.0, fh.textHeight());
    return (row_inner + cap_inner) * 0.5;
}

/// Base `Options` for the dialog header close button. Tabs pass `.override(.{ .expand = .none, .min_size_content = …, .id_extra = … })`.
pub fn windowHeaderCloseButtonOptions(over: dvui.Options) dvui.Options {
    const base: dvui.Options = .{
        // Its only content is an X: the name a screen reader or a script reads instead.
        .label = .{ .text = "Close" },
        .font = .theme(.heading),
        .corners = dvui.CornerRect.all(1000),
        .padding = dvui.Rect.all(0),
        .margin = window_header_close_margin,
        .gravity_y = 0.5,
        .expand = .ratio,
        .style = .err,
        .box_shadow = .{
            .color = .black,
            .alpha = 0.25,
            .offset = .{ .x = -2, .y = 2 },
            .fade = 4,
        },
    };
    return base.override(over);
}

/// Where the last `windowHeader` drew its close button, physical pixels (`windowHeaderCloseRect`).
var header_close: ?dvui.Rect.Physical = null;

/// Where the `windowHeader` just drawn has its close button, physical pixels — null without one.
/// What a header the OS drags its window by leaves to the app (a popped-out float's).
pub fn windowHeaderCloseRect() ?dvui.Rect.Physical {
    return header_close;
}

fn windowHeaderPaintClose(openflag: ?*bool) void {
    if (openflag) |of| {
        const close_side = windowHeaderCloseInnerSide();
        // Hovered, the button grows to fit its icon. It grows inside a footprint that does not:
        // a box as big as the grown button, whose margins give back what it grows by, so at rest
        // the button sits where it always did and hovered it grows into its own margins — the
        // title beside it, centred in the room the button leaves, moved with it.
        const hover_side = @max(close_side, dvui.Font.theme(.body).textHeight());
        const give = (hover_side - close_side) / 2;
        const m = window_header_close_margin;
        var spot = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .min_size_content = .{ .w = hover_side, .h = hover_side },
            .margin = .{ .x = @max(0, m.x - give), .y = @max(0, m.y - give), .w = @max(0, m.w - give), .h = @max(0, m.h - give) },
            .padding = .{},
            .gravity_y = 0.5,
        });
        defer spot.deinit();
        header_close = spot.data().borderRectScale().r;

        var button: dvui.ButtonWidget = undefined;
        button.init(@src(), .{}, windowHeaderCloseButtonOptions(.{
            .min_size_content = .{ .w = close_side, .h = close_side },
            .expand = .none,
            .margin = .{},
            .gravity_x = 0.5,
        }));
        defer button.deinit();
        // For a tape to close the dialog as a person does (docs/AUTOMATION.md, "Anchors").
        anchor.mark(button.data(), "fizzy.dialog.close", .{});

        button.processEvents();
        button.drawBackground();
        button.drawFocus();

        if (button.hovered()) {
            icon_tex.icon(@src(), "close", icons.tvg.lucide.x, .{
                .stroke_color = .{ .color = dvui.themeGet().color(.err, .fill).lighten(if (dvui.themeGet().dark) -10 else 10) },
                .fill_color = .{ .color = dvui.themeGet().color(.err, .fill).lighten(if (dvui.themeGet().dark) -10 else 10) },
            }, .{
                .min_size_content = .{ .w = hover_side, .h = hover_side },
                .expand = .ratio,
                .gravity_x = 0.5,
                .gravity_y = 0.5,
                .color_text = .white,
            });
        }

        if (button.clicked()) {
            of.* = false;
        }
    }
}

fn windowHeaderPaintKindIcon(header_kind: DialogHeaderKind) void {
    if (header_kind == .none) return;

    const close_side = windowHeaderCloseInnerSide();
    const tvg = switch (header_kind) {
        .none => unreachable,
        .info => icons.tvg.lucide.@"circle-help",
        .warning, .err => icons.tvg.lucide.@"circle-alert",
    };
    const icon_color: dvui.Color = switch (header_kind) {
        .none => unreachable,
        .info => dvui.themeGet().color(.content, .text),
        .warning => dialog_header_warning_fill,
        .err => dvui.themeGet().color(.err, .fill),
    };

    icon_tex.icon(@src(), "dialog_header_accent", tvg, .{
        .stroke_color = .{ .color = icon_color },
        .fill_color = .{ .color = icon_color },
    }, .{
        .expand = .none,
        .min_size_content = .{ .w = close_side, .h = close_side },
        .margin = window_header_close_margin,
        .gravity_y = 0.5,
        .color_text = .white,
    });
}

pub fn windowHeader(str: []const u8, right_str: []const u8, openflag: ?*bool, header_kind: DialogHeaderKind) dvui.Rect.Physical {
    // Order matches dialog footer `button_order`: `.cancel_ok` → dismiss (close) leading like Cancel;
    // `.ok_cancel` → icon leading, dismiss trailing (same role split as OK vs Cancel horizontal placement).
    const dismiss_close_leading = switch (dvui.currentWindow().button_order) {
        .cancel_ok => true,
        .ok_cancel => false,
    };
    header_close = null;

    // No fill of its own: the window's frost and tint run under the header the same as under
    // the body, so a dialog is one pane of glass, not a lid on a box.
    // Stood in from the window's corners by what their rounding takes (`cornerInset`): the close
    // button sits in the corner, and at full roundness it sat right against the curve.
    const inset = cornerInset(rounding.scaled(rounding.control));
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .name = "WindowHeader",
        .background = false,
        .corners = rounding.all(rounding.control),
        .padding = .{ .x = inset, .y = inset, .w = inset },
    });
    defer row.deinit();

    if (dismiss_close_leading) {
        windowHeaderPaintClose(openflag);
    } else {
        windowHeaderPaintKindIcon(header_kind);
    }

    dvui.labelNoFmt(@src(), str, .{ .align_x = 0.5 }, .{
        .expand = .horizontal,
        .font = .theme(.heading),
        .gravity_y = 0.5,
        .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
        .label = .{ .for_id = dvui.subwindowCurrentId() },
    });

    dvui.labelNoFmt(@src(), right_str, .{}, .{ .expand = .none, .gravity_y = 0.5 });

    if (dismiss_close_leading) {
        windowHeaderPaintKindIcon(header_kind);
    } else {
        windowHeaderPaintClose(openflag);
    }

    const evts = dvui.events();
    for (evts) |*e| {
        if (!dvui.eventMatch(e, .{ .id = row.data().id, .r = row.data().contentRectScale().r }))
            continue;

        if (e.evt == .mouse and e.evt.mouse.action == .press and e.evt.mouse.button.pointer()) {
            // raise this subwindow but let the press continue so the window
            // will do the drag-move
            dvui.raiseSubwindow(dvui.subwindowCurrentId());
        } else if (e.evt == .mouse and e.evt.mouse.action == .focus) {
            // our window will already be focused, but this prevents the window
            // from clearing the focused widget
            e.handle(@src(), row.data());
        }
    }

    return row.data().rectScale().r;
}

pub const SpinnerOptions = struct {
    end_time: i32 = 1_000_000,
};

pub fn spinner(src: std.builtin.SourceLocation, spinner_opts: SpinnerOptions, opts: dvui.Options) void {
    var defaults: dvui.Options = .{
        .name = "Spinner",
        .min_size_content = .{ .w = 50, .h = 50 },
    };
    const options = defaults.override(opts);
    var wd = dvui.WidgetData.init(src, .{}, options);
    wd.register();
    wd.minSizeSetAndRefresh();
    wd.minSizeReportToParent();

    if (wd.rect.empty()) {
        return;
    }

    const rs = wd.contentRectScale();
    const r = rs.r;

    var t: f32 = 0;
    const spin = dvui.Animation{ .end_time = spinner_opts.end_time };
    if (dvui.animationGet(wd.id, "_t")) |a| {
        // existing animation
        var aa = a;
        if (aa.done()) {
            // this animation is expired, seamlessly transition to next animation
            aa = spin;
            aa.start_time = a.end_time;
            aa.end_time += a.end_time;
            dvui.animation(wd.id, "_t", aa);
        }
        t = aa.value();
    } else {
        // first frame we are seeing the spinner
        dvui.animation(wd.id, "_t", spin);
    }

    var path: dvui.Path.Builder = .init(dvui.currentWindow().lifo());
    defer path.deinit();

    const full_circle = 2 * std.math.pi;
    // start begins fast, speeding away from end
    const start = full_circle * dvui.easing.outSine(t);
    // end begins slow, catching up to start
    const end = full_circle * dvui.easing.inSine(t);

    path.addArc(r.center(), @min(r.w, r.h) / 3, start, end, false);
    path.build().stroke(.{ .thickness = 3.0 * rs.s, .color = .{ .color = options.color(.text) } });
}

pub fn toastDisplay(id: dvui.Id) !void {
    const message = dvui.dataGetSlice(null, id, "_message", []u8) orelse {
        // The `_message` slice is dvui frame-data: it is freed after any frame where
        // nothing touches the key. A toast anchored to a subwindow that stops being
        // drawn (tab switch, pane closed, canvas hidden) therefore loses its message
        // permanently. Drop the toast like `dvui.toastDisplay` does — otherwise it
        // sits in the queue forever and re-logs this every single frame.
        dvui.log.err("toastDisplay lost data for toast {x}", .{id});
        dvui.toastRemove(id);
        return;
    };

    var box = dvui.box(@src(), .{}, .{
        .id_extra = id.asUsize(),
        .background = true,
        .corners = dvui.CornerRect.all(1000),
        .margin = .all(2),
        .padding = .{ .x = 2, .y = 2, .w = 2, .h = 2 },
        .color_fill = .{ .color = dvui.themeGet().color(.control, .fill) },
        .box_shadow = .{
            .color = .black,
            .offset = .{ .x = -2.0, .y = 2.0 },
            .fade = 6.0,
            .alpha = 0.25,
            .corners = dvui.CornerRect.all(10000),
        },
        .gravity_x = 0.5,
    });
    defer box.deinit();

    var animator = dvui.animate(@src(), .{ .kind = .alpha, .duration = motion.duration(400_000) }, .{ .id_extra = id.asUsize(), .gravity_x = 0.5 });
    defer animator.deinit();

    dvui.labelNoFmt(@src(), message, .{}, .{
        .gravity_x = 0.5,
    });

    if (dvui.timerDone(id)) {
        animator.startEnd();
    }

    if (animator.end()) {
        dvui.toastRemove(id);
    }
}

pub const BubbleSpinnerInit = struct {
    complete_elapsed_ns: ?i128 = null,
};

/// Finish animation after save (wall-clock, driven by the file flash timer):
/// 1. **Sync** — bubbles around the ring sequentially grow to the same size, filling the ring.
/// 2. **Pop** — ring radius expands quickly while dots shrink and fade.
/// 3. **Check** — only the highlight checkmark until the flash window ends.
const bubble_save_sync_ns: i128 = 400 * std.time.ns_per_ms;
const bubble_save_pop_ns: i128 = 160 * std.time.ns_per_ms;
pub const bubble_save_transition_ns: i128 = bubble_save_sync_ns + bubble_save_pop_ns;

/// True when save-complete feedback is showing the check (tab close may appear on hover).
pub fn bubbleSpinnerSaveInCheckPhase(complete_elapsed_ns: i128) bool {
    return complete_elapsed_ns >= bubble_save_transition_ns;
}
const bubble_save_check_fade_ns: i128 = 120 * std.time.ns_per_ms;
const bubble_spinner_period_micros: i32 = 1_050_000;
const bubble_dot_count: u32 = 9;

/// Fizzy-themed bubble spinner. N small filled dots arranged on a ring; each pulses size
/// and alpha in a sine wave with a phase offset around the circle, giving a wave of
/// brightness that rotates — like bubbles rising in a fizzy drink.
///
/// When `init.save_done_elapsed_ns` is set, plays the save-complete finish (sync → pop → check)
/// instead of the looping wave. `options.color(.text)` is the dot colour.
pub fn bubbleSpinner(
    src: std.builtin.SourceLocation,
    opts: dvui.Options,
    init: BubbleSpinnerInit,
) void {
    var defaults: dvui.Options = .{
        .name = "BubbleSpinner",
        .min_size_content = .{ .w = 50, .h = 50 },
    };
    const options = defaults.override(opts);
    var wd = dvui.WidgetData.init(src, .{}, options);
    wd.register();
    wd.minSizeSetAndRefresh();
    wd.minSizeReportToParent();
    if (wd.rect.empty()) return;

    const rs = wd.contentRectScale();
    const text_color = options.color(.text).toColor();

    if (init.complete_elapsed_ns) |elapsed_ns| {
        if (elapsed_ns >= bubble_save_transition_ns) {
            const check_elapsed = elapsed_ns - bubble_save_transition_ns;
            const check_alpha = if (check_elapsed >= bubble_save_check_fade_ns)
                1.0
            else
                @as(f32, @floatFromInt(check_elapsed)) / @as(f32, @floatFromInt(bubble_save_check_fade_ns));
            bubbleSpinnerPaintCheck(rs, check_alpha);
            return;
        }
        if (elapsed_ns < bubble_save_sync_ns) {
            var spin_t: f32 = 0;
            const spin: dvui.Animation = .{ .end_time = bubble_spinner_period_micros };
            if (dvui.animationGet(wd.id, "_t")) |a| {
                var aa = a;
                if (aa.done()) {
                    aa = spin;
                    aa.start_time = a.end_time;
                    aa.end_time += a.end_time;
                    dvui.animation(wd.id, "_t", aa);
                }
                spin_t = aa.value();
            } else {
                dvui.animation(wd.id, "_t", spin);
            }
            bubbleSpinnerPaintSaveSync(rs.r, spin_t, text_color, elapsed_ns);
            return;
        }
        bubbleSpinnerPaintSavePop(rs.r, text_color, elapsed_ns - bubble_save_sync_ns);
        return;
    }

    var t: f32 = 0;
    const spin: dvui.Animation = .{ .end_time = bubble_spinner_period_micros };
    if (dvui.animationGet(wd.id, "_t")) |a| {
        var aa = a;
        if (aa.done()) {
            aa = spin;
            aa.start_time = a.end_time;
            aa.end_time += a.end_time;
            dvui.animation(wd.id, "_t", aa);
        }
        t = aa.value();
    } else {
        dvui.animation(wd.id, "_t", spin);
    }

    bubbleSpinnerPaintSpin(rs.r, t, text_color);
}

fn bubbleSpinnerGeom(r: dvui.Rect.Physical) struct {
    center: dvui.Point.Physical,
    ring_radius: f32,
    dot_max_radius: f32,
} {
    const bounding_radius = @min(r.w, r.h) * 0.5;
    return .{
        .center = r.center(),
        .ring_radius = bounding_radius * 0.78,
        .dot_max_radius = bounding_radius * 0.18,
    };
}

/// Centered in the same content rect as the bubble ring (not a child `icon` widget).
fn bubbleSpinnerPaintCheck(rs: dvui.RectScale, alpha: f32) void {
    // Match tab close X (`expand = .ratio` in the same slot). Lucide `check` has a bit more
    // viewbox padding than `x`, so render slightly larger than the content square.
    const slot = @min(rs.r.w, rs.r.h);
    const side = slot * 1.08;
    const cx = rs.r.x + rs.r.w * 0.5;
    const cy = rs.r.y + rs.r.h * 0.5;
    const icon_rs: dvui.RectScale = .{
        .r = .{
            .x = cx - side * 0.5,
            .y = cy - side * 0.5,
            .w = side,
            .h = side,
        },
        .s = rs.s,
    };
    const check_color = saveDoneCheckFill(alpha);
    dvui.renderIcon("bubble_save_done", icons.tvg.lucide.check, icon_rs, .{}, .{
        .stroke_color = .{ .color = check_color },
        .fill_color = .{ .color = check_color },
    }) catch |err| {
        dvui.logError(@src(), err, "bubble save check icon", .{});
    };
}

fn bubbleSpinnerPaintDot(
    center: dvui.Point.Physical,
    ring_radius: f32,
    angle: f32,
    dot_radius: f32,
    color: dvui.Color,
) void {
    const dot_center: dvui.Point.Physical = .{
        .x = center.x + ring_radius * @cos(angle),
        .y = center.y + ring_radius * @sin(angle),
    };
    var path: dvui.Path.Builder = .init(dvui.currentWindow().lifo());
    defer path.deinit();
    path.addArc(dot_center, dot_radius, 2 * std.math.pi, 0, true);
    path.build().fillConvex(.{ .color = .{ .color = color } });
}

fn bubbleSpinnerSmoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0, 1);
    return t * t * (3.0 - 2.0 * t);
}

fn bubbleSpinnerPaintSpin(r: dvui.Rect.Physical, t: f32, text_color: dvui.Color) void {
    const geom = bubbleSpinnerGeom(r);
    const dot_min_scale: f32 = 0.35;
    const base_alpha_f: f32 = @floatFromInt(text_color.a);
    const n = @as(f32, @floatFromInt(bubble_dot_count));

    var i: u32 = 0;
    while (i < bubble_dot_count) : (i += 1) {
        const angle = -std.math.pi * 0.5 + 2 * std.math.pi * @as(f32, @floatFromInt(i)) / n;
        const phase = @as(f32, @floatFromInt(i)) / n;
        const local_t = @mod(t + phase, 1.0);
        const pulse = @sin(std.math.pi * local_t);
        const dot_radius = geom.dot_max_radius * (dot_min_scale + (1.0 - dot_min_scale) * pulse);
        const alpha_floor: f32 = 0.25;
        const alpha_mul = alpha_floor + (1.0 - alpha_floor) * pulse;
        const dot_color: dvui.Color = .{
            .r = text_color.r,
            .g = text_color.g,
            .b = text_color.b,
            .a = @intFromFloat(base_alpha_f * alpha_mul),
        };
        bubbleSpinnerPaintDot(geom.center, geom.ring_radius, angle, dot_radius, dot_color);
    }
}

/// Sequential sync: each bubble in turn reaches full size so the ring reads as filled.
fn bubbleSpinnerPaintSaveSync(r: dvui.Rect.Physical, spin_t: f32, text_color: dvui.Color, elapsed_ns: i128) void {
    const geom = bubbleSpinnerGeom(r);
    const dot_min_scale: f32 = 0.35;
    const fill_scale: f32 = 1.08; // slightly oversized so adjacent dots meet on the ring
    const base_alpha_f: f32 = @floatFromInt(text_color.a);
    const n = @as(f32, @floatFromInt(bubble_dot_count));
    const sync_p = @as(f32, @floatFromInt(elapsed_ns)) / @as(f32, @floatFromInt(bubble_save_sync_ns));

    var i: u32 = 0;
    while (i < bubble_dot_count) : (i += 1) {
        const angle = -std.math.pi * 0.5 + 2 * std.math.pi * @as(f32, @floatFromInt(i)) / n;
        const phase = @as(f32, @floatFromInt(i)) / n;
        const local_t = @mod(spin_t + phase, 1.0);
        const wave = @sin(std.math.pi * local_t);

        const slot = (@as(f32, @floatFromInt(i)) + 0.5) / n;
        const lock = bubbleSpinnerSmoothstep(slot - 0.12, slot + 0.08, sync_p);
        const pulse = wave * (1.0 - lock) + lock;
        const dot_radius = geom.dot_max_radius * (dot_min_scale + (1.0 - dot_min_scale) * pulse * fill_scale);
        const alpha_floor: f32 = 0.25;
        const alpha_mul = alpha_floor + (1.0 - alpha_floor) * pulse;
        const dot_color: dvui.Color = .{
            .r = text_color.r,
            .g = text_color.g,
            .b = text_color.b,
            .a = @intFromFloat(base_alpha_f * alpha_mul),
        };
        bubbleSpinnerPaintDot(geom.center, geom.ring_radius, angle, dot_radius, dot_color);
    }
}

/// Ring expands outward while dots shrink and vanish.
fn bubbleSpinnerPaintSavePop(r: dvui.Rect.Physical, text_color: dvui.Color, pop_elapsed_ns: i128) void {
    const geom = bubbleSpinnerGeom(r);
    const base_alpha_f: f32 = @floatFromInt(text_color.a);
    const n = @as(f32, @floatFromInt(bubble_dot_count));
    const pop_p = std.math.clamp(
        @as(f32, @floatFromInt(pop_elapsed_ns)) / @as(f32, @floatFromInt(bubble_save_pop_ns)),
        0,
        1,
    );
    const pop_ease = 1.0 - std.math.pow(f32, 1.0 - pop_p, 3.0);
    const ring_mul = 1.0 + 0.62 * pop_ease;
    const dot_scale = 1.08 * (1.0 - pop_ease);
    const alpha_mul = 1.0 - pop_ease;

    var i: u32 = 0;
    while (i < bubble_dot_count) : (i += 1) {
        const angle = -std.math.pi * 0.5 + 2 * std.math.pi * @as(f32, @floatFromInt(i)) / n;
        const dot_radius = geom.dot_max_radius * dot_scale;
        const dot_color: dvui.Color = .{
            .r = text_color.r,
            .g = text_color.g,
            .b = text_color.b,
            .a = @intFromFloat(base_alpha_f * alpha_mul),
        };
        bubbleSpinnerPaintDot(geom.center, geom.ring_radius * ring_mul, angle, dot_radius, dot_color);
    }
}

/// Subwindow id used for save-complete toasts. Distinct from the canvas subwindow so
/// `Workspace.drawCanvas`'s `toastsShow` won't render them — instead `Editor.drawSaveToasts`
/// iterates this id and renders centered cards matching the loading-overlay style.
pub const save_toast_subwindow_id: dvui.Id = @enumFromInt(0xF12_5A4E_71D0_5A4E);

/// Custom toast display for save-complete events. Visually matches `Editor.drawLoadingOverlay`:
/// content-fill @ 0.85 background, drop shadow, checkmark icon + "Saved <basename>" label.
/// Auto-fades when the toast timer expires. The message is read from `_message` data on the
/// toast id (set by `toastAdd` caller).
pub fn saveCompleteToastDisplay(id: dvui.Id) !void {
    const message = dvui.dataGetSlice(null, id, "_message", []u8) orelse {
        // Same frame-data expiry as `toastDisplay` — remove instead of spinning.
        dvui.log.err("saveCompleteToastDisplay lost data for toast {x}", .{id});
        dvui.toastRemove(id);
        return;
    };

    var animator = dvui.animate(@src(), .{ .kind = .alpha, .duration = motion.duration(350_000) }, .{
        .id_extra = id.asUsize(),
    });
    defer animator.deinit();

    var card = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id.asUsize(),
        .background = true,
        .corners = rounding.all(rounding.surface),
        .padding = .{ .x = 16, .y = 12, .w = 16, .h = 12 },
        .color_fill = .{ .color = dvui.themeGet().color(.content, .fill).opacity(0.85) },
        .box_shadow = .{
            .color = .black,
            .offset = .{ .x = -2.0, .y = 2.0 },
            .fade = 12.0,
            .alpha = 0.35,
            .corners = rounding.all(rounding.surface),
        },
    });
    defer card.deinit();

    icon_tex.icon(@src(), "save_check", icons.tvg.lucide.check, .{
        .stroke_color = .{ .color = dvui.themeGet().color(.highlight, .fill) },
        .fill_color = .{ .color = dvui.themeGet().color(.highlight, .fill) },
    }, .{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 20, .h = 20 },
        .padding = .{ .w = 10 },
    });

    dvui.labelNoFmt(@src(), message, .{}, .{
        .gravity_y = 0.5,
        .color_text = .{ .color = dvui.themeGet().color(.content, .text) },
    });

    if (dvui.timerDone(id)) {
        animator.startEnd();
    }
    if (animator.end()) {
        dvui.toastRemove(id);
    }
}
