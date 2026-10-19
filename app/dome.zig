//! A transport's dome: a small glass on the middle of the bottom edge of what the transport
//! drives, standing on the edge so it covers next to nothing, holding an opaque liquid that says
//! how far along it is (a document's history, a tape's play). At rest it is quiet, mostly
//! see-through (`rules.Presence`); the pointer on it, a step or a slosh brings it up. The pointer
//! held on it a moment (`rules.Dwell`) grows the transport's bar out of it, the dome lightening as
//! the moment runs; a press brings the bar at once. Growing, the bar's bubbles bud out of the dome
//! one after another (`bud`, `emerge`) and pull away to their places, the dome in the same glass
//! and shrinking into its edge as they leave it (`shrinking`), the glass between them reaching
//! further while they are near (`merge`): they run together and part as drops do. What is on them
//! shows late (`contentAlpha`), and the liquid flows out of the dome into the bar's line
//! (`pourTube`). Going, it runs backwards. A grown bar has a tab over it, a chevron down
//! (`tabRect`, `chevron`), that sends it back in.
//!
//! The history transport (`HistoryTransport`) and the demo's tape player
//! (`automation/overlay.zig`) both hide into one; the rules are `dome_rules.zig`. Nothing here
//! asks for a frame: a dome sitting still costs only its draw.
//!
//! **Toward a pocket** (`plans/POCKETS_PLAN.md`: a control tucked under a card's edge that slides
//! out and back, `core.widgets.Pocket`). What a dome looks like is apart from where it is and what
//! takes its input: `paint` draws it at whatever shape it is handed, and the growth (`bud`,
//! `emerge`, `shrinking`, `pool`) is geometry from the dome's rect. The placement and input are
//! the callers': `draw`'s floating widget for the history grip, the overlay's layer and
//! `Player`'s hit-testing for the tape's. A pocket takes over that part and hands `paint` its
//! current shape, and nothing else moves.
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const icons = @import("icons");
const rules = @import("dome_rules.zig");
const Liquid = @import("Liquid.zig");

/// The dome's radius: a semicircle twice as wide as it is tall.
pub const radius: f32 = 13;
/// How far round the dome the pointer is on it.
pub const reach: f32 = 8;
/// The collapse tab's size, and its gap over the bar.
pub const tab_d: f32 = 24;
pub const tab_gap: f32 = 6;

/// The dome standing on `edge_y` (natural) centred on `cx`, `r` its radius: the semicircle's box.
pub fn rect(cx: f32, edge_y: f32, r: f32) dvui.Rect {
    return .{ .x = cx - r, .y = edge_y - r, .w = 2 * r, .h = r };
}

/// How long a bar takes to grow out of its dome, and to go back in: a surface's opening time.
pub fn growNs() i128 {
    return @as(i128, core.motion.duration(grow_us)) * std.time.ns_per_us;
}
/// Microseconds, as written, a bar takes to grow out of its grip: slower than a surface opening,
/// so it reads as one liquid swelling and parting into drops, not controls flung out.
const grow_us: i32 = 620_000;

/// The one curve the growing runs on, both ways: eased in and out, with no swing past and no
/// drawing back, so nothing about it jumps.
pub fn smooth(t: f32) f32 {
    const k = std.math.clamp(t, 0, 1);
    return if (k < 0.5) 4 * k * k * k else 1 - std.math.pow(f32, -2 * k + 2, 3) / 2;
}

/// Where the bar's bubbles bud from in the dome at `from` (physical, the semicircle's box): a
/// round drop in its middle.
pub fn bud(from: dvui.Rect.Physical) dvui.Rect.Physical {
    return .{ .x = from.x + from.w / 2 - from.h * 0.6, .y = from.y + from.h * 0.15, .w = from.h * 1.2, .h = from.h * 1.2 };
}

/// How far a bubble that buds at `delay` (a share of the growing) has come at `p` (0 gone to 1
/// in), on the arriving curve: lerp it from `bud` to its place by this.
pub fn emerge(p: f32, delay: f32) f32 {
    return core.motion.enterFull(std.math.clamp((p - delay) / (1 - delay), 0, 1));
}

/// Where a bubble of the bar is, `p` of the way out (0 in its grip `from`, 1 at its place `to`),
/// budding at `delay` (a share of the growing): a drop pulled out of the grip rather than a button
/// sliding. Small while it travels, inflating as it nears its place; along an arc, up and then
/// across, rather than straight, `arc` times the usual height (so bubbles leaving together fan out
/// rather than travel stacked); on one smooth curve (`smooth`) both ways, so going back is coming
/// played backwards — in the reverse order, as the later a bubble buds, the sooner it is in.
pub fn pull(from: dvui.Rect.Physical, to: dvui.Rect.Physical, p: f32, delay: f32, arc: f32) dvui.Rect.Physical {
    const k = std.math.clamp((p - delay) / (1 - delay), 0, 1);
    const t = smooth(k);
    if (t <= 0) return bud(from);
    const a = bud(from);
    const ac: [2]f32 = .{ a.x + a.w / 2, a.y + a.h / 2 };
    const bc: [2]f32 = .{ to.x + to.w / 2, to.y + to.h / 2 };
    // Up off the straight line, most of the way out at the middle of the way.
    const dist = @sqrt((bc[0] - ac[0]) * (bc[0] - ac[0]) + (bc[1] - ac[1]) * (bc[1] - ac[1]));
    const lift = dist * pull_arc * arc * @sin(std.math.pi * std.math.clamp(t, 0, 1));
    const c: [2]f32 = .{ std.math.lerp(ac[0], bc[0], t), std.math.lerp(ac[1], bc[1], t) - lift };
    // A drop while it travels, as big as the grip's bud at most; its place's size once near it.
    const drop = @min(a.h, @min(to.w, to.h) * pull_drop);
    const grow = std.math.clamp((t - pull_inflate) / (1 - pull_inflate), 0, 1);
    const g = grow * grow * (3 - 2 * grow);
    const w = std.math.lerp(drop, to.w, g);
    const h = std.math.lerp(drop, to.h, g);
    // Past its place in a swing, past its size a little too.
    const swell = if (t > 1) t else 1;
    return .{ .x = c[0] - w * swell / 2, .y = c[1] - h * swell / 2, .w = w * swell, .h = h * swell };
}
/// How far up off the straight way a pulled bubble arcs, as a share of the way; how big it is
/// while it travels, as a share of its place's size; and how far along it starts to inflate.
const pull_arc: f32 = 0.14;
// Not much smaller than its place: the glass's rim is one for the whole field, fitted to its
// smallest shape, and a tiny drop is all rim — a darker drop among the rest.
const pull_drop: f32 = 0.7;
const pull_inflate: f32 = 0.55;

/// The dome at `from` itself in the bar's glass while the bar is `p` of the way out, shrinking into
/// its edge as the bubbles leave it. Clip the glass to the edge (`aboveEdge`).
pub fn shrinking(from: dvui.Rect.Physical, p: f32) core.dialogs.Bubble {
    const d = from.w * (1 - core.motion.enterFull(p));
    return .{ .rect = .{ .x = from.x + from.w / 2 - d / 2, .y = from.y + from.h - d / 2, .w = d, .h = d } };
}

/// How near the bar's bubbles reach for each other `p` of the way out: far through the first
/// half, so they and the grip swell as one blob, then falling to `settled` over the second, so the
/// necks between them thin and let go as each nears its place, and they part as drops do.
pub fn merge(p: f32, settled: f32) f32 {
    return std.math.lerp(28, settled, smooth((p - 0.3) / 0.6));
}

/// The clip that keeps the glass growing out of the dome at `from` from reaching past the edge it
/// stands on; set it round the glass, and put the previous one back after.
pub fn aboveEdge(from: dvui.Rect.Physical) dvui.Rect.Physical {
    return .{ .x = 0, .y = 0, .w = std.math.floatMax(f32) / 4, .h = from.y + from.h };
}

/// What is on the bar's bubbles, `p` of the way out: once they are most of the way.
pub fn contentAlpha(p: f32) f32 {
    return std.math.clamp((p - 0.55) / 0.45, 0, 1);
}

pub fn lerpRect(a: dvui.Rect.Physical, b: dvui.Rect.Physical, t: f32) dvui.Rect.Physical {
    return .{ .x = std.math.lerp(a.x, b.x, t), .y = std.math.lerp(a.y, b.y, t), .w = std.math.lerp(a.w, b.w, t), .h = std.math.lerp(a.h, b.h, t) };
}

/// The collapse tab over the middle of the bar `whole` (natural).
pub fn tabRect(whole: dvui.Rect) dvui.Rect {
    return .{ .x = whole.x + whole.w / 2 - tab_d / 2, .y = whole.y - tab_gap - tab_d, .w = tab_d, .h = tab_d };
}

/// The tab's chevron, in the middle of its bubble `r` (window-natural; `bounds` the layer's).
pub fn chevron(bounds: dvui.Rect, r: dvui.Rect, color: dvui.Color) void {
    const d = r.w * 0.44;
    core.icon.icon(@src(), "dome_collapse", icons.tvg.lucide.@"chevron-down", .{
        .stroke_color = .{ .color = color },
        .fill_color = .{ .color = color },
    }, .{ .rect = .{ .x = r.x + (r.w - d) / 2 - bounds.x, .y = r.y + (r.h - d) / 2 - bounds.y, .w = d, .h = d } });
}

/// The liquid's colour: the highlight, opaque, brightened by `glow` (0 to 1).
pub fn liquidColor(glow: f32) dvui.Color {
    return dvui.themeGet().color(.highlight, .fill).lerp(.white, 0.25 * glow);
}

/// Fill the convex outline `poly` (physical) with `color`, its edge smoothed as dvui's fills are.
pub fn pour(poly: []const rules.Pt, color: dvui.Color) void {
    if (poly.len < 3) return;
    var path: dvui.Path.Builder = .init(dvui.currentWindow().lifo());
    defer path.deinit();
    for (poly) |q| path.addPoint(.{ .x = q[0], .y = q[1] });
    path.build().fillConvex(.{ .color = .{ .color = color }, .fade = 1 });
}

/// How a dome looks this frame.
pub const Look = struct {
    alpha: f32 = 1,
    /// The pointer is on it.
    lit: bool = false,
    /// How far through the wait before the bar grows the pointer is, 0 to 1: it lightens.
    held: f32 = 0,
    /// How full it is, 0 to 1 (`rules.stepsFill`, `rules.progressFill`).
    fill: f32 = 0,
    /// A brightening, 1 as something lands to 0.
    glow: f32 = 0,
    /// How tipped its liquid is, -1 to 1 (`rules.Slosh`).
    tilt: f32 = 0,
    /// A corner vial's liquid, its surface and drops (`paintCorner`): drawn from it rather than
    /// from `fill` and `tilt`.
    liquid: ?*const Liquid = null,
};

/// The pool in the dome at `from` (physical, the semicircle's box) the liquid flows out of into
/// the bar, and back into as it goes: as much as the dome holds (`fill`, 0 to 1), at its level, so
/// the liquid leaves the dome as it stood.
pub fn pool(from: dvui.Rect.Physical, fill: f32) dvui.Rect.Physical {
    const h = @max(1, from.h * rules.fill_top * fill);
    return .{ .x = from.x + from.w * 0.2, .y = from.y + from.h - h, .w = from.w * 0.6, .h = h };
}

/// The bar's glass alpha `p` of the way out of a dome showing `presence` of itself: as present as
/// the dome was, coming up to all of it as the bar comes out, so neither end of the growing jumps.
pub fn glassAlpha(presence: f32, p: f32) f32 {
    return std.math.lerp(presence, 1, @min(1, p * 3));
}

/// The dome at `r` (natural, the semicircle's box), as `look` says, in a floating widget of its
/// own that takes its presses (`id_extra` keeps one apart from another), named for a tape or a test
/// to aim at by `anchor_fmt`/`anchor_args`. Returns whether it was pressed: a press is the dome's,
/// not what is under it. A transport whose input is taken elsewhere (the tape player's, by
/// `Player.frame`) draws it with `paint` instead.
pub fn draw(r: dvui.Rect, id_extra: usize, look: Look, comptime anchor_fmt: []const u8, anchor_args: anytype) bool {
    var float: dvui.FloatingWidget = undefined;
    float.init(@src(), .{}, .{ .rect = r.outset(.{ .x = reach, .y = reach, .w = reach }), .id_extra = id_extra });
    defer float.deinit();
    const pr = dvui.windowRectScale().rectToPhysical(r);
    core.anchor.markRect(float.data().id, pr, true, anchor_fmt, anchor_args);
    var pressed = false;
    for (dvui.events()) |*e| {
        if (!dvui.eventMatch(e, .{ .id = float.data().id, .r = float.data().borderRectScale().r })) continue;
        if (e.evt == .mouse and e.evt.mouse.action == .press and e.evt.mouse.button.pointer()) {
            e.handle(@src(), float.data());
            pressed = true;
        }
    }
    paint(float.data().id, pr, look);
    return pressed;
}

/// The dome's pixels at `pr` (physical, the semicircle's box): its glass, and the liquid in it up to
/// its level, its surface tipped by its slosh. `id` is the glass's.
pub fn paint(id: dvui.Id, pr: dvui.Rect.Physical, look: Look) void {
    const theme = dvui.themeGet();
    const s = dvui.windowRectScale().s;
    // A circle on the edge, its lower half past it: `pr` is its upper half. (Corners round to at
    // most half the shorter side, so a box `pr`'s size would be a tab, not a dome.)
    const R = pr.w / 2;
    const edge = pr.y + pr.h;
    const disc: dvui.Rect.Physical = .{ .x = pr.x, .y = pr.y, .w = pr.w, .h = pr.w };
    const prev = dvui.clip(pr);
    defer dvui.clipSet(prev);
    const ink = theme.color(.window, .text);
    const glass = core.widgets.LiquidField.ready() and core.widgets.liquidFrost() != null;
    if (glass) {
        // Over the glass, inside its rim: a dome this small frosts nearly all of what is under it.
        {
            const prev_alpha = dvui.alpha(look.alpha);
            defer dvui.alphaSet(prev_alpha);
            core.dialogs.glassBubbles(id, &.{.{
                .rect = disc,
                // Lit under the pointer, lighter still as the wait before the bar runs.
                .light = if (look.lit) std.math.lerp(core.dialogs.bubble_hover, core.dialogs.bubble_press, look.held) else 0,
            }}, s, .{ .shadow = 0.5 });
        }
        // Its body and rim of its own, over the glass: glass at full opacity is the card's colour,
        // and a dome of only that is not there.
        disc.fill(.round(R), .{ .color = .{ .color = ink.opacity(look.alpha * @as(f32, if (look.lit) 0.16 else 0.08)) }, .fade = 1 });
        disc.insetAll(0.5 * s).stroke(.round(R), .{ .color = .{ .color = ink.opacity(look.alpha * 0.28) }, .thickness = 1 * s });
    } else disc.fill(.round(R), .{ .color = .{ .color = ink.opacity(look.alpha * @as(f32, if (look.lit) 0.45 else 0.22)) }, .fade = 1 });
    if (look.fill > 0) {
        const inset = 2 * s;
        var outline: [4 * (rules.corner_points + 1)]rules.Pt = undefined;
        var half: [outline.len + 1]rules.Pt = undefined;
        var kept: [outline.len + 2]rules.Pt = undefined;
        const vessel = rules.roundedOutline(pr.x + inset, edge - R + inset, 2 * (R - inset), 2 * (R - inset), R - inset, &outline);
        const above = rules.cut(vessel, .{ 0, edge }, .{ 0, 1 }, &half);
        const a = look.tilt * 0.45;
        // Never full: at most `fill_top` of the way up, so there is always room for it to swing.
        const level = edge - (R - inset) * rules.fill_top * look.fill;
        pour(rules.cut(above, .{ pr.x + R, level }, .{ @sin(a), -@cos(a) }, &kept), liquidColor(@max(look.glow, 0.6 * look.held)).opacity(look.alpha));
    }
}

/// The liquid in the bar's line: a tube `done` (physical) from the line's start to how far along,
/// its head tipped by `tilt` (-1 to 1); growing out of the dome, it runs out of the dome's `pool`,
/// `out` (0 to 1) of the way, and back as it goes. At `alpha`, its own: it shows while the bubbles
/// grow, before what is on them does.
pub fn pourTube(done: dvui.Rect.Physical, tilt: f32, from_pool: ?dvui.Rect.Physical, out: f32, alpha: f32, color: dvui.Color) void {
    const prev = dvui.alpha(1);
    dvui.alphaSet(alpha);
    defer dvui.alphaSet(prev);
    const pool_r = from_pool orelse return fillTube(done, tilt, color);
    // Poured: a stream from the pool to the knob, the end of the line's liquid nearest the pool,
    // then the liquid spreading from there back to the line's start.
    const k = std.math.clamp(out, 0, 1);
    // The stream's head runs from the pool to the line over the first part; its tail leaves the
    // pool once the line is filling, and runs into the line after the head.
    const head = smooth(k / pour_stream);
    const tail = smooth((k - pour_stream) / (pour_fill - pour_stream));
    const th = done.h;
    const lip: [2]f32 = .{ pool_r.x + pool_r.w * 0.3, pool_r.y + @min(pool_r.h, th) / 2 };
    const end: [2]f32 = .{ done.x + done.w - th / 2, done.y + th / 2 };
    if (tail < 1 and head > 0) pourStream(lip, end, tail, head, th, color);
    // The line fills from the knob back to its start once the stream reaches it.
    const fill = smooth((k - pour_stream * 0.8) / (1 - pour_stream * 0.8));
    const w = @max(th, std.math.lerp(th, done.w, fill));
    if (fill > 0) fillTube(.{ .x = done.x + done.w - w, .y = done.y, .w = w, .h = th }, tilt * fill, color);
}

/// How far into the pour (0 to 1) the stream reaches the line, and lets go of the pool.
const pour_stream: f32 = 0.4;
const pour_fill: f32 = 0.75;

/// The line's liquid in `tube` (physical): a capsule, its head tipped by `tilt` (-1 to 1).
fn fillTube(tube: dvui.Rect.Physical, tilt: f32, color: dvui.Color) void {
    var outline: [4 * (rules.corner_points + 1)]rules.Pt = undefined;
    var kept: [outline.len + 1]rules.Pt = undefined;
    const vessel = rules.roundedOutline(tube.x, tube.y, tube.w, tube.h, @min(tube.w, tube.h) / 2, &outline);
    const a = tilt * 0.6;
    pour(rules.cut(vessel, .{ tube.x + tube.w, tube.y + tube.h / 2 }, .{ @cos(a), @sin(a) }, &kept), color);
}

// ── The grip as a corner vial ────────────────────────────────────────────────────────────────
//
// The history's grip in the bottom-right corner of the card its document is on, the way a place's
// arrange button is in its top-right (`layout/Region.zig`, `cornerPiece`): an orb on the card's
// corner point, cut by the card's outline with an edge of its own (`LiquidField.Edge.cut`), one
// radius on every card and reaching out by part of what a rounder corner's curve cuts off. The
// corner is the one place on a card no split's bar is (they run along the middle of its edges),
// and the quarter is room for the liquid to show. A history icon sits in it, over the liquid.

/// The orb's radius in points, and how much of what the card's curve cuts off it reaches out by:
/// the arrange corner's (`Region.corner_grown_radius`, `corner_curve_reach`).
pub const corner_radius: f32 = 30;
pub const corner_curve_reach: f32 = 0.5;
/// The history icon's size in points, and how far in from the quarter's middle it sits.
const corner_icon: f32 = 13;

/// A card's bottom-right corner, physical: its rect and its corners (top-left, top-right,
/// bottom-right, bottom-left).
pub const Corner = struct {
    card: dvui.Rect.Physical,
    radii: [4]f32 = @splat(0),

    fn curveIn(self: Corner) f32 {
        return self.radii[2] * (std.math.sqrt2 - 1);
    }

    /// The card's corner point.
    pub fn point(self: Corner) [2]f32 {
        return .{ self.card.x + self.card.w, self.card.y + self.card.h };
    }

    /// The orb's radius, physical.
    pub fn radiusPx(self: Corner, s: f32) f32 {
        return corner_radius * s + self.curveIn() * corner_curve_reach;
    }

    /// The square from the corner the quarter lies in: where the pointer is on it, and what the
    /// bar grows out of.
    pub fn box(self: Corner, s: f32) dvui.Rect.Physical {
        const r = self.radiusPx(s);
        const p = self.point();
        return .{ .x = p[0] - r, .y = p[1] - r, .w = r, .h = r };
    }

    /// The orb, `t` of its size (1 whole, 0 nothing), on the corner point.
    pub fn shape(self: Corner, s: f32, t: f32) core.widgets.orb.Shape {
        return .circle(self.point(), self.radiusPx(s) * @max(0, t));
    }

    /// The card's outline, which cuts it.
    pub fn place(self: Corner) core.widgets.LiquidField.Edge {
        return .{ .rect = self.card, .radii = self.radii, .cut = true };
    }

    /// Where the pointer is on it: the square from the corner that lies inside the quarter drawn
    /// (its far corner on the circle), so nothing past the glass — the document's last columns,
    /// a scroll bar's end — is taken for the grip's.
    pub fn hit(self: Corner, s: f32) dvui.Rect.Physical {
        const d = self.radiusPx(s) * std.math.sqrt1_2;
        const p = self.point();
        return .{ .x = p[0] - d, .y = p[1] - d, .w = d, .h = d };
    }

    /// Where the icon is centred: on the diagonal, in the middle of what of the quarter shows.
    pub fn iconCenter(self: Corner, s: f32) [2]f32 {
        const axis = self.radii[2] * (1 - std.math.sqrt1_2);
        const in = axis + @max(0, self.radiusPx(s) - self.curveIn()) / 2 * std.math.sqrt1_2;
        const p = self.point();
        return .{ p[0] - in, p[1] - in };
    }
};

/// The vial at `c`, as `look` says, in a floating widget of its own that takes its presses, named
/// for a tape or a test to aim at. Returns whether it was pressed.
pub fn drawCorner(c: Corner, id_extra: usize, look: Look, comptime anchor_fmt: []const u8, anchor_args: anytype) bool {
    const wrs = dvui.windowRectScale();
    const s = wrs.s;
    const pr = c.hit(s);
    var float: dvui.FloatingWidget = undefined;
    float.init(@src(), .{}, .{ .rect = wrs.rectFromPhysical(pr), .id_extra = id_extra });
    defer float.deinit();
    core.anchor.markRect(float.data().id, pr, true, anchor_fmt, anchor_args);
    var pressed = false;
    for (dvui.events()) |*e| {
        if (!dvui.eventMatch(e, .{ .id = float.data().id, .r = float.data().borderRectScale().r })) continue;
        // A pointing hand over it, as over the place's arrange button: it is a button.
        if (e.evt == .mouse and e.evt.mouse.action == .position) dvui.cursorSet(.hand);
        if (e.evt == .mouse and e.evt.mouse.action == .press and e.evt.mouse.button.pointer()) {
            e.handle(@src(), float.data());
            pressed = true;
        }
    }
    paintCorner(float.data().id, c, 1, look);
    // The history icon over the liquid: grey at rest, the text colour while it is in use.
    const theme = dvui.themeGet();
    const grey = theme.color(.window, .fill).lerp(if (theme.dark) dvui.Color.white else dvui.Color.black, 0.3).opacity(1);
    const lit: f32 = if (look.lit) 1 else std.math.clamp(@max(look.glow, look.held), 0, 1);
    const ic = c.iconCenter(s);
    const d = corner_icon * s;
    const bounds = float.data().borderRectScale().r;
    core.icon.icon(@src(), "history_grip", icons.tvg.lucide.history, .{
        .stroke_color = .white,
        .fill_color = .white,
    }, .{
        .rect = .{ .x = (ic[0] - d / 2 - bounds.x) / s, .y = (ic[1] - d / 2 - bounds.y) / s, .w = corner_icon, .h = corner_icon },
        .color_text = .{ .color = grey.lerp(theme.color(.content, .text), lit) },
    });
    return pressed;
}

/// The vial's pixels at `c`, `t` of its size (1 whole; less while the bar grows out of it): its
/// glass, an orb cut by the card, and the liquid in it up to its level, tipped by its slosh.
pub fn paintCorner(id: dvui.Id, c: Corner, t: f32, look: Look) void {
    const s = dvui.windowRectScale().s;
    const prev = dvui.clip(c.card);
    defer dvui.clipSet(prev);
    const shape = c.shape(s, t);
    if (shape.half[0] < 1) return;
    core.widgets.orb.draw(id, shape, s, .{
        .place = c.place(),
        // Lit under the pointer, lighter still as the wait before the bar runs.
        .light = if (look.lit) std.math.lerp(core.dialogs.bubble_hover, core.dialogs.bubble_press, look.held) else 0,
    });
    if (look.fill <= 0) return;
    // The vessel: the glass a little in from its rim, cut by the card a little in from its edge.
    const inset = liquid_inset * s;
    const geometry = core.orb_geometry;
    var a: [160]geometry.Pt = undefined;
    var b: [160]geometry.Pt = undefined;
    var out: [320]geometry.Pt = undefined;
    var scratch: [320]geometry.Pt = undefined;
    const inner: geometry.Shape = .circle(shape.center, @max(0, shape.half[0] - inset));
    const card = c.card.insetAll(inset);
    const card_radii: [4]f32 = .{ @max(0, c.radii[0] - inset), @max(0, c.radii[1] - inset), @max(0, c.radii[2] - inset), @max(0, c.radii[3] - inset) };
    const vessel = geometry.cut(inner.outline(24, &a), geometry.Shape.box(card.x, card.y, card.w, card.h, card_radii).outline(16, &b), &out, &scratch);
    if (vessel.len < 3) return;
    const p = c.point();
    if (look.liquid) |liq| return pourLiquid(vessel, liq, p[1] - (shape.half[0] - inset), p[1] - inset, s, liquidColor(@max(look.glow, 0.6 * look.held)));
    // Never full: at most `fill_top` of the way up what shows, so there is always room to swing.
    const top = p[1] - (shape.half[0] - inset);
    const level = std.math.lerp(p[1] - inset, top, rules.fill_top * look.fill);
    const tip = look.tilt * 0.45;
    var kept: [321]rules.Pt = undefined;
    pour(rules.cut(vessel, .{ p[0] - shape.half[0] / 2, level }, .{ @sin(tip), -@cos(tip) }, &kept), liquidColor(@max(look.glow, 0.6 * look.held)));
}

/// How far in from the glass and the card's edge the liquid keeps, points.
const liquid_inset: f32 = 2.5;

/// The liquid `liq` in `vessel` (physical, convex), its top `top` and its bottom `bottom` (y): the
/// surface drawn column to column in strips, each cut by the vessel, with a lighter line along
/// its top, and the drops in the air, cut by the vessel too, so one coming in emerges from the
/// glass rather than over it.
fn pourLiquid(vessel: []const rules.Pt, liq: *const Liquid, top: f32, bottom: f32, s: f32, color: dvui.Color) void {
    const geometry = core.orb_geometry;
    var minx: f32 = std.math.floatMax(f32);
    var maxx: f32 = -std.math.floatMax(f32);
    for (vessel) |q| {
        minx = @min(minx, q[0]);
        maxx = @max(maxx, q[0]);
    }
    const level_y = std.math.lerp(bottom, top, rules.fill_top * liq.level);
    const dx = (maxx - minx) / @as(f32, Liquid.columns - 1);
    const shine = color.lerp(.white, 0.35);
    var out: [256]geometry.Pt = undefined;
    var scratch: [256]geometry.Pt = undefined;
    for (0..Liquid.columns - 1) |i| {
        const x0 = minx + dx * @as(f32, @floatFromInt(i));
        // A hair past the next column, so the strips' smoothed edges do not show as seams.
        const x1 = x0 + dx + 0.75 * s;
        const y0 = level_y - liq.h[i];
        const y1 = level_y - liq.h[i + 1];
        const strip = [_]geometry.Pt{ .{ x0, y0 }, .{ x1, y1 }, .{ x1, bottom + 2 * s }, .{ x0, bottom + 2 * s } };
        pour(geometry.cut(&strip, vessel, &out, &scratch), color);
        const line = [_]geometry.Pt{ .{ x0, y0 - 0.5 * s }, .{ x1, y1 - 0.5 * s }, .{ x1, y1 + 0.9 * s }, .{ x0, y0 + 0.9 * s } };
        pour(geometry.cut(&line, vessel, &out, &scratch), shine);
    }
}

/// The stream poured from `lip` (the pool's surface) to `end` (the line's knob), physical, from
/// `tail` to `head` of the way along (0 to 1): up off the pool and over in an arc, thin at the lip
/// and the line's width where it lands, as a stream running out of a vessel thins at its lip.
fn pourStream(lip: [2]f32, end: [2]f32, tail: f32, head: f32, th: f32, color: dvui.Color) void {
    // A quadratic arc, its control point up off the middle by a part of the way across.
    const span = @abs(end[0] - lip[0]) + @abs(end[1] - lip[1]);
    const ctrl: [2]f32 = .{ (lip[0] + end[0]) / 2, @min(lip[1], end[1]) - span * 0.18 };
    const at = struct {
        fn f(a: [2]f32, b: [2]f32, c: [2]f32, u: f32) [2]f32 {
            const v = 1 - u;
            return .{ v * v * a[0] + 2 * v * u * b[0] + u * u * c[0], v * v * a[1] + 2 * v * u * b[1] + u * u * c[1] };
        }
    }.f;
    const n = 18;
    var prev = at(lip, ctrl, end, tail);
    var prev_w = std.math.lerp(th * 0.45, th, tail) / 2;
    for (1..n + 1) |i| {
        const u = std.math.lerp(tail, head, @as(f32, @floatFromInt(i)) / n);
        const p = at(lip, ctrl, end, u);
        const w = std.math.lerp(th * 0.45, th, u) / 2;
        const dx = p[0] - prev[0];
        const dy = p[1] - prev[1];
        const len = @max(0.001, @sqrt(dx * dx + dy * dy));
        const nx = -dy / len;
        const ny = dx / len;
        // A hair longer than the step, so the segments' smoothed edges do not show as seams.
        const ex = dx / len * 0.4;
        const ey = dy / len * 0.4;
        const quad = [_]rules.Pt{
            .{ prev[0] + nx * prev_w - ex, prev[1] + ny * prev_w - ey },
            .{ p[0] + nx * w + ex, p[1] + ny * w + ey },
            .{ p[0] - nx * w + ex, p[1] - ny * w + ey },
            .{ prev[0] - nx * prev_w - ex, prev[1] - ny * prev_w - ey },
        };
        pour(&quad, color);
        prev = p;
        prev_w = w;
    }
    // A round head where it is running.
    const h = at(lip, ctrl, end, head);
    const hw = std.math.lerp(th * 0.45, th, head) / 2;
    const r: dvui.Rect.Physical = .{ .x = h[0] - hw, .y = h[1] - hw, .w = 2 * hw, .h = 2 * hw };
    r.fill(.all(hw), .{ .color = .{ .color = color }, .fade = 1 });
}
