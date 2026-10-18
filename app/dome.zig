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
    return @as(i128, core.motion.duration(core.motion.open_us)) * std.time.ns_per_us;
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

/// The dome at `from` itself in the bar's glass while the bar is `p` of the way out, shrinking into
/// its edge as the bubbles leave it. Clip the glass to the edge (`aboveEdge`).
pub fn shrinking(from: dvui.Rect.Physical, p: f32) core.dialogs.Bubble {
    const d = from.w * (1 - core.motion.enterFull(p));
    return .{ .rect = .{ .x = from.x + from.w / 2 - d / 2, .y = from.y + from.h - d / 2, .w = d, .h = d } };
}

/// How near the bar's bubbles reach for each other `p` of the way out: further while they are
/// near the dome, so they run together, and `settled` once out.
pub fn merge(p: f32, settled: f32) f32 {
    return std.math.lerp(40, settled, core.motion.enterFull(p));
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
    const tube = if (from_pool) |f| lerpRect(f, done, out) else done;
    var outline: [4 * (rules.corner_points + 1)]rules.Pt = undefined;
    var kept: [outline.len + 1]rules.Pt = undefined;
    const vessel = rules.roundedOutline(tube.x, tube.y, tube.w, tube.h, @min(tube.w, tube.h) / 2, &outline);
    const a = tilt * 0.6;
    pour(rules.cut(vessel, .{ tube.x + tube.w, tube.y + tube.h / 2 }, .{ @cos(a), @sin(a) }, &kept), color);
}
