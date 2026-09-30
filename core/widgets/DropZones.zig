//! The drop target over a place while something is dragged: a wheel in the place's middle — a
//! circle for the place itself and a ring of four around it, one for each side it could split
//! on. Only the place under the pointer shows one; moving to another place, the old wheel goes as
//! the new one comes in.
//!
//! **One geometry, one look, for every drag.** A view dragged between places and a file or tab
//! dragged onto a pane read the pointer against the same wheel (`wheel`, `at`) and draw the same
//! one (`draw`), so a drop means the same thing wherever it lands and looks the same getting
//! there.
//!
//! **Small, and in one place.** The wheel is the size of pixi's tool wheel, whatever the size of
//! the place, and sits in its middle — the place stays in view around it, and the choices are
//! where the eye already is. A release off the wheel does nothing: every drop is one the wheel
//! lit first.
//!
//! **The look is liquid glass.** The wheel is one disc of the dialogs' own frost over what is
//! under it, drawn through `core.liquid_glass`, its sides marked off by faint lines and each
//! carrying an icon for what it does; the part under the pointer lights as dvui lights a hovered
//! fill. It grows out of the place's middle on the app's motion as its frost comes in, and goes
//! back into it, quicker.

const std = @import("std");
const dvui = @import("dvui");
const dialogs = @import("../dialogs.zig");
const widgets = @import("../widgets.zig");
const BlurBackdrop = @import("BlurBackdrop.zig");
const icons = @import("icons");
const icon_tex = @import("../gfx/icon.zig");
const motion = @import("../motion.zig");
const liquid_glass = @import("../gfx/liquid_glass.zig");
const liquid_blob = @import("../gfx/liquid_blob.zig");

pub const Side = enum { left, right, top, bottom };

pub const Zone = union(enum) {
    /// Into the place itself: a trade for a place that shows one view, a new tab for one that
    /// shows several.
    center,
    /// A split on that edge.
    edge: Side,
    /// Out of the layout altogether: the trash.
    remove,

    pub fn eql(a: Zone, b: Zone) bool {
        return switch (a) {
            .center => b == .center,
            .edge => |s| b == .edge and b.edge == s,
            .remove => b == .remove,
        };
    }
};

/// One bubble of the drop: its centre and radius, physical.
pub const Disc = struct {
    c: dvui.Point.Physical,
    r: f32,
};

/// The drop over one place, in physical pixels: a cluster of bubbles in its middle.
pub const Wheel = struct {
    center: dvui.Point.Physical,
    /// Physical pixels per point of the layout below — the display scale, less if the place is
    /// too small for the whole cluster.
    unit: f32,
    /// Whether the trash is one of the bubbles.
    remove: bool = false,

    /// Where zone `z`'s bubble settles.
    pub fn bubble(self: Wheel, z: Zone) Disc {
        const off: [2]f32, const r: f32 = switch (z) {
            .center => .{ .{ 0, 0 }, center_r },
            .edge => |sd| .{ switch (sd) {
                .left => .{ -side_d, 0 },
                .right => .{ side_d, 0 },
                .top => .{ 0, -side_d },
                .bottom => .{ 0, side_d },
            }, side_r },
            .remove => .{ .{ remove_d, remove_d }, remove_r },
        };
        return .{ .c = .{ .x = self.center.x + off[0] * self.unit, .y = self.center.y + off[1] * self.unit }, .r = r * self.unit };
    }

    /// The square the settled cluster fits in.
    pub fn rect(self: Wheel) dvui.Rect.Physical {
        const e = extent * self.unit;
        return .{ .x = self.center.x - e, .y = self.center.y - e, .w = 2 * e, .h = 2 * e };
    }
};

/// Every zone, in the order they are drawn and stored.
pub const all = [_]Zone{ .center, .{ .edge = .left }, .{ .edge = .right }, .{ .edge = .top }, .{ .edge = .bottom }, .remove };

/// Points: the bubbles' layout — the middle, the four sides at `side_d` from it, the trash on the
/// diagonal between the right and the bottom — about 300 across: big enough to aim at without
/// looking, small enough to leave the place in view round it.
const center_r: f32 = 52;
const side_r: f32 = 40;
const side_d: f32 = 108;
const remove_r: f32 = 30;
const remove_d: f32 = 88;
/// Points: a bubble's icon, as a share of its radius.
const bubble_icon: f32 = 0.6;
/// How far out from the centre the cluster reaches.
const extent: f32 = side_d + side_r;
/// At most this share of the place's shorter side, so a small place still shows all of it.
pub const fit: f32 = 0.45;
/// How far past its edge a bubble still takes the pointer, as a share of its radius: a drop
/// aimed at a bubble's rim is aimed at the bubble.
const reach: f32 = 1.25;

/// Where the drop sits over `bounds`: in its middle. `remove` offers the trash.
pub fn wheel(bounds: dvui.Rect.Physical, scale: f32, remove: bool) Wheel {
    const room = @min(bounds.w, bounds.h) * fit / extent;
    return .{ .center = bounds.center(), .unit = @max(0, @min(scale, room)), .remove = remove };
}

/// The zone a point reads as: the bubble it is on (or near), and nothing off every bubble.
pub fn at(w: Wheel, p: dvui.Point.Physical) ?Zone {
    var best: ?Zone = null;
    var best_d: f32 = std.math.floatMax(f32);
    for (all) |z| {
        if (z == .remove and !w.remove) continue;
        const b = w.bubble(z);
        const dx = p.x - b.c.x;
        const dy = p.y - b.c.y;
        const d = @sqrt(dx * dx + dy * dy) / @max(b.r, 0.001);
        if (d <= reach and d < best_d) {
            best = z;
            best_d = d;
        }
    }
    return best;
}

fn inset(r: dvui.Rect.Physical, dx: f32, dy: f32) dvui.Rect.Physical {
    return .{ .x = r.x + dx, .y = r.y + dy, .w = @max(0, r.w - 2 * dx), .h = @max(0, r.h - 2 * dy) };
}

/// How long the drop takes to come in and to go, in milliseconds. In carries the drop forming
/// and splitting, watched as the place is arrived at. Out runs it backwards — the bubbles back
/// together into one drop that shrinks away — quickly, but slowly enough to be seen doing it
/// rather than popping.
pub const appear_ms: f32 = 420;
pub const vanish_ms: f32 = 380;
/// A time constant: how quickly a zone lights or dims under the pointer, most of the way in
/// about three of these.
pub const light_ms: f32 = 55;

const State = struct {
    /// 0…1, linear in time; shaped when read (`grow`, `frost`).
    shown: f32 = 0,
    /// Which way `shown` is going, and what the drop looked like when it last turned round:
    /// the gap between that and where the new way's curve starts, faded out over the new way,
    /// so a drop that turns mid-way carries on from where it was rather than jumping.
    leaving: bool = false,
    part: f32 = 0,
    swell: f32 = 0,
    turn_shown: f32 = 0,
    turn_part: f32 = 0,
    turn_swell: f32 = 0,
    /// 0…1: how lit — the zone under the pointer.
    lit: [all.len]f32 = @splat(0),
    last_ns: i128 = 0,
};

/// What dropping in the middle does, for its icon: trade places with the one view a place shows,
/// add to the several it shows, join it with the place beside it into one — or nothing, the
/// middle of the place a view was lifted from, which is bare glass.
pub const Center = enum { replace, add, join, none };

/// How one place's zones are drawn this frame.
pub const Look = struct {
    /// The zone under the pointer, which lights.
    hovered: ?Zone = null,
    /// False sends them all away — the pointer left the place, or the drag ended — until
    /// `showing` says they are gone.
    target: bool = true,
    /// The middle's icon.
    center: Center = .replace,
};

/// How much a lit zone's glass changes, as dvui changes a hovered fill (`Theme.adjustColorForState`,
/// ±10% by `dark`): lighter over a dark theme, darker over a light one — a pale zone brightening
/// on a pale theme barely shows.
const lit_lift: f32 = 0.10;

/// The colour a lit zone's glass moves toward: white in a dark theme, black in a light one.
fn litToward() dvui.Color {
    return if (dvui.themeGet().dark) .white else .black;
}
/// Points: an icon's size.
const icon_size: f32 = 18;

/// Draw the drop `w`, keyed by `id` (the place's).
///
/// Call every frame the pointer is over the place, and after while `showing`, after what the
/// drop covers has drawn. Gone, a place forgets its drop, so the next arrival comes in anew.
pub fn draw(id: dvui.Id, w: Wheel, scale: f32, look: Look) void {
    const st = dvui.dataGetPtrDefault(null, id, "_drop_zones", State, .{});
    const now = dvui.currentWindow().frame_time_ns;
    // Where it was is kept until it has gone (`forget`), however long between frames: a drag
    // held still asks for none, and treating the gap as a new visit replayed the entrance on the
    // next twitch of the pointer.
    if (st.last_ns == 0) st.last_ns = now;
    const dt_ms: f32 = @as(f32, @floatFromInt(now - st.last_ns)) / std.time.ns_per_ms;
    st.last_ns = now;

    const want_shown: f32 = if (look.target) 1 else 0;
    st.shown = step(st.shown, want_shown, dt_ms, motion.durationMs(if (want_shown > st.shown) appear_ms else vanish_ms));
    var moving = st.shown != want_shown;
    for (all, 0..) |z, i| {
        const want_lit: f32 = if (look.target) (if (look.hovered) |h| (if (h.eql(z)) 1 else 0) else 0) else 0;
        st.lit[i] = approach(st.lit[i], want_lit, dt_ms, motion.durationMs(light_ms));
        if (st.lit[i] != want_lit) moving = true;
    }

    const g = frost(st.shown);
    if (g > 0.01 and w.unit > 0) {
        // One drop, then its bubbles: during `drop_phase` of the way in a single bubble swells in
        // the middle; after it the bubbles part toward where they settle — past it and back at
        // the app's motion — while how far the field bridges them falls, so the necks between
        // them thin and let go. Leaving, the same phases backwards but plainly eased: the arrival's
        // swing run in reverse was a push outward before they gathered, and another swell before
        // the drop shrank — two bounces in one join.
        const leaving = want_shown < st.shown or (want_shown == st.shown and !look.target);
        const shape = phases(st.shown, leaving);
        if (leaving != st.leaving) {
            st.leaving = leaving;
            st.turn_shown = st.shown;
            st.turn_part = st.part - shape.part;
            st.turn_swell = st.swell - shape.swell;
        }
        // How much of the gap at the turn is left: all of it there, none at the end of the way.
        const left = if (leaving)
            (if (st.turn_shown > 0) std.math.clamp(st.shown / st.turn_shown, 0, 1) else 0)
        else
            (if (st.turn_shown < 1) std.math.clamp((1 - st.shown) / (1 - st.turn_shown), 0, 1) else 0);
        const part = @max(0, shape.part + st.turn_part * left);
        const swell = @max(0, shape.swell + st.turn_swell * left);
        st.part = part;
        st.swell = swell;
        var discs: [all.len]liquid_blob.Disc = undefined;
        var zones: [all.len]usize = undefined;
        var n: usize = 0;
        for (all, 0..) |z, i| {
            if (z == .remove and !w.remove) continue;
            const b = w.bubble(z);
            discs[n] = .{
                .c = .{ .x = w.center.x + (b.c.x - w.center.x) * part, .y = w.center.y + (b.c.y - w.center.y) * part },
                .r = b.r * swell,
                .lit = st.lit[i],
            };
            zones[n] = i;
            n += 1;
        }
        const k = (bridge_start + (bridge_end - bridge_start) * std.math.clamp(part, 0, 1)) * w.unit;
        if (apart(discs[0..n], k)) {
            // Parted, each bubble is a circle: the panes' own glass (`liquid_glass`), a pane
            // with corners of its whole radius — a fraction of the union's mesh to draw, and its
            // rim light is the panes', fine along the edge where the union's grid is coarse.
            var panes: [all.len]Pane = undefined;
            for (discs[0..n], 0..) |dc, i| panes[i] = .{
                .r = .{ .x = dc.c.x - dc.r, .y = dc.c.y - dc.r, .w = 2 * dc.r, .h = 2 * dc.r },
                .lit = dc.lit,
                .radii = liquid_glass.uniform(dc.r),
            };
            glass(id, panes[0..n], w.rect(), g, scale);
        } else {
            blob(id, discs[0..n], k, w.rect(), g, scale);
        }
        // The icons, once the bubbles have come apart enough to hold them.
        const settle = std.math.clamp((part - 0.55) / 0.45, 0, 1);
        if (settle > 0.01) for (discs[0..n], zones[0..n]) |dc, i| {
            const z = all[i];
            if (z == .center and look.center == .none) continue;
            const zr: dvui.Rect.Physical = .{ .x = dc.c.x - dc.r, .y = dc.c.y - dc.r, .w = 2 * dc.r, .h = 2 * dc.r };
            drawIcon(zr, iconFor(z, look.center), g * settle, st.lit[i], scale, dc.r * bubble_icon / scale, w.bubble(z).r * bubble_icon);
        };
    }

    if (moving) {
        dvui.refresh(null, @src(), id);
    } else if (!look.target) {
        forget(id);
    }
}

/// Whether the field bridges none of `discs` any more: every pair further apart than the union
/// reaches across (a few `k`), so each is a circle of its own.
fn apart(discs: []const liquid_blob.Disc, k: f32) bool {
    for (discs, 0..) |a, i| for (discs[i + 1 ..]) |b| {
        const dx = a.c.x - b.c.x;
        const dy = a.c.y - b.c.y;
        if (@sqrt(dx * dx + dy * dy) - a.r - b.r < 4 * k) return false;
    };
    return true;
}

/// The share of the way in the drop spends as one bubble, before it splits.
const drop_phase: f32 = 0.3;

const Shape = struct { part: f32, swell: f32 };

/// How far the bubbles have parted and how big the drop is at `shown`: arriving on the app's
/// motion (its swing, when playful), leaving on a plain ease with no swing.
fn phases(shown: f32, leaving: bool) Shape {
    const form = std.math.clamp(shown / drop_phase, 0, 1);
    const split = std.math.clamp((shown - drop_phase) / (1 - drop_phase), 0, 1);
    if (leaving) return .{ .part = smooth(split), .swell = smooth(form) };
    return .{ .part = motion.enterFull(split), .swell = motion.enterFull(form) };
}

fn smooth(t: f32) f32 {
    return t * t * (3 - 2 * t);
}
/// Points: how far the field bridges the bubbles as they begin to part, and once they have —
/// enough at the start that they leave as one drop, little enough at the end that settled
/// bubbles a few points apart stand clear of each other.
const bridge_start: f32 = 16;
const bridge_end: f32 = 1.5;

/// The drop's glass: one read and blur of `area` (where it settles), the discs' union laid down
/// on it (`liquid_blob`) with the dialogs' tint and lift, at strength `g`. With the blur off,
/// the dialogs' fill disc by disc.
fn blob(id: dvui.Id, discs: []const liquid_blob.Disc, k: f32, area: dvui.Rect.Physical, g: f32, scale: f32) void {
    const base = widgets.menuFrost() orelse {
        const fill = dialogs.dialogFill();
        for (discs) |dc| {
            const r: dvui.Rect.Physical = .{ .x = dc.c.x - dc.r, .y = dc.c.y - dc.r, .w = 2 * dc.r, .h = 2 * dc.r };
            if (r.w < 1) continue;
            const c = fill.lerp(litToward(), lit_lift * dc.lit);
            r.fill(.round(dc.r), .{ .color = .{ .color = c.opacity(@as(f32, @floatFromInt(c.a)) / 255 * g) }, .fade = 1.0 });
        }
        return;
    };
    const job = dvui.dataGetPtrDefault(null, id, "_drop_blob_job", BlobJob, .{});
    job.* = .{
        .backdrop = job.backdrop,
        .scale = scale,
        .strength = g,
        .k = k,
        .lens = motion.liquid() * liquid_glass.blurRamp(base.radius),
    };
    for (discs) |dc| {
        if (dc.r < 0.5) continue;
        job.discs[job.count] = dc;
        job.count += 1;
    }
    if (job.count == 0) return;
    const bounds = area.insetAll(-liquid_glass.margin(.{ .lens = job.lens, .refraction = base.refraction }, scale));
    job.pane = scaled(base, g);
    if (job.pane.radius < BlurBackdrop.min_blur) {
        job.count = 0;
        return;
    }
    job.bounds = bounds;
    const backdrop = dvui.dataGetPtrDefault(null, id, "_drop_zones_frost", BlurBackdrop, .{});
    dvui.dataSetDeinitFunction(null, id, "_drop_zones_frost", &BlurBackdrop.releaseTexture);
    backdrop.mode = .readback;
    backdrop.radius_px = job.pane.radius;
    backdrop.detail = job.pane.detail;
    backdrop.share = true;
    // Read every frame, as the dialogs' glass is: what moves under the drop moves in it.
    backdrop.init(dvui.windowRectScale().rectFromPhysical(bounds), .{ bounds, dvui.currentWindow().frame_time_ns, job.pane.radius });
    job.backdrop = backdrop;
    dvui.deferRender(job, BlobJob.draw);
}

/// The drop's layer, drawn at replay once everything under it is on the frame (`blob`).
const BlobJob = struct {
    backdrop: ?*BlurBackdrop = null,
    pane: BlurBackdrop.Pane = .{},
    bounds: dvui.Rect.Physical = .{},
    scale: f32 = 1,
    strength: f32 = 1,
    lens: f32 = 1,
    k: f32 = 1,
    discs: [all.len]liquid_blob.Disc = undefined,
    count: usize = 0,

    fn draw(ctx: ?*anyopaque) void {
        const self: *BlobJob = @ptrCast(@alignCast(ctx orelse return));
        const backdrop = self.backdrop orelse return;
        // At full alpha, as every frost draws: a frost at partial alpha is a hole.
        const prev_alpha = dvui.currentWindow().alpha;
        dvui.alphaSet(1);
        defer dvui.alphaSet(prev_alpha);
        backdrop.deinit();
        const tex = backdrop.small orelse return;
        const mix = std.math.clamp(self.pane.mix, 0, 1);
        liquid_blob.draw(tex, backdrop.coverage(), self.discs[0..self.count], self.k, self.scale, .{
            .lens = self.lens,
            .refraction = self.pane.refraction,
            .frost = if (self.pane.tint != null) dvui.Color.white.opacity(1 - mix) else .white,
            .tint = self.pane.tint,
            .mix = mix,
            .lift = self.pane.lift,
            .lit_amount = lit_lift,
            .lit_toward = litToward(),
            .strength = self.strength,
            .blend_over = &BlurBackdrop.blendOver,
        });
    }
};

/// How `drawSingle` lays its pane down.
pub const Single = struct {
    /// Points in from the rect the pane sits.
    inset: f32 = 0,
    /// What the pane's icon says; null for none (a slot too small for one).
    icon: ?Center = null,
    /// Points: the pane's corner radius; null for the app's surface rounding.
    radius: ?f32 = null,
};

/// One lit pane of the zones' glass over `rect`, coming in as it appears and going when `rect`
/// goes null — over the last rect it covered — keyed by `id`. The one target a thing offers when
/// it is not a place with edges to split: the join across two places, a chooser a view can be
/// dropped into, the slot a dragged item will land in along a chooser.
pub fn drawSingle(id: dvui.Id, rect: ?dvui.Rect.Physical, scale: f32, opts: Single) void {
    const SingleState = struct { shown: f32 = 0, last_ns: i128 = 0, rect: dvui.Rect.Physical = .{} };
    const st = dvui.dataGetPtr(null, id, "_drop_single", SingleState) orelse blk: {
        if (rect == null) return;
        break :blk dvui.dataGetPtrDefault(null, id, "_drop_single", SingleState, .{});
    };
    const now = dvui.currentWindow().frame_time_ns;
    // Kept until it has gone, however long between frames — see `draw`.
    if (st.last_ns == 0) st.last_ns = now;
    const dt_ms: f32 = @as(f32, @floatFromInt(now - st.last_ns)) / std.time.ns_per_ms;
    st.last_ns = now;
    if (rect) |rr| st.rect = inset(rr, opts.inset * scale, opts.inset * scale);
    const want: f32 = if (rect != null) 1 else 0;
    st.shown = step(st.shown, want, dt_ms, motion.durationMs(if (want > st.shown) appear_ms else vanish_ms));
    const moving = st.shown != want;
    const g = frost(st.shown);
    if (g > 0.01 and st.rect.w >= 1 and st.rect.h >= 1) {
        const k = 0.85 + 0.15 * grow(st.shown);
        const radius = if (opts.radius) |r| r * scale else surfaceRadius(scale);
        const pane: Pane = .{
            .r = scaleAbout(st.rect, k, k),
            .lit = 1,
            .radii = liquid_glass.uniform(radius),
        };
        glass(id, &.{pane}, st.rect, g, scale);
        if (opts.icon) |icon| drawIcon(pane.r, iconFor(.center, icon), g, 1, scale, icon_size, icon_size * scale);
    }
    if (moving) {
        dvui.refresh(null, @src(), id);
    } else if (rect == null) {
        dvui.dataRemove(null, id, "_drop_single");
    }
}

// ── Coming and going ────────────────────────────────────────────────────────────────────────────

/// How big a zone is at progress `t`: arriving, at the app's motion level (`motion.enter`) — a
/// slight bounce at minimal, a soft spring at playful, plain at the low end. Read backwards on the
/// way out, the same curve swells a touch and then goes.
fn grow(t: f32) f32 {
    // The whole curve over the phase, approach and swing, with no hold after: the zones time
    // their own phases, and one that arrived early and sat still would leave its phase dead.
    return @max(0, motion.enterFull(t));
}

/// How much frost a zone has at progress `t`: ahead of its size, so the glass is glass before it
/// has finished arriving.
fn frost(t: f32) f32 {
    return motion.fade(t);
}

/// The app's surface rounding in physical pixels. Finalized, as a widget's options would be: an
/// unresolved corner draws square whatever radius it names.
fn surfaceRadius(scale: f32) f32 {
    const theme = dvui.themeGet();
    return dialogs.surfaceCorners().finalize(&theme).tl.radius() * scale;
}

/// Per-corner radii (physical, ring order) as dvui corners in natural units at `scale`.
fn cornersOf(radii: liquid_glass.Radii, scale: f32) dvui.CornerRect {
    return .{
        .tl = .round(radii[0] / scale),
        .bl = .round(radii[1] / scale),
        .br = .round(radii[2] / scale),
        .tr = .round(radii[3] / scale),
    };
}

fn scaleAbout(r: dvui.Rect.Physical, kx: f32, ky: f32) dvui.Rect.Physical {
    const w = r.w * kx;
    const h = r.h * ky;
    return .{ .x = r.x + (r.w - w) / 2, .y = r.y + (r.h - h) / 2, .w = w, .h = h };
}

/// One pane of glass to lay down: where, how lit, its corner radii (physical), and how much of
/// its edge — refraction and light — it has yet.
const Pane = struct {
    r: dvui.Rect.Physical,
    lit: f32 = 0,
    radii: liquid_glass.Radii,
    lens: f32 = 1,
};



/// The frost under `panes` at strength `g`: one read of `area` and one blur for all of them,
/// laid down as a bent mesh each, tinted and lifted like the dialogs' glass, the lit ones
/// brighter. With the blur off it is the dialogs' fill, as much of it as `g`.
///
/// **Read rarely.** `area` is where the panes settle, not where they are this frame, so a pane
/// growing in does not move what is read; what is under it does not change during a drag (the
/// app under one stays put), so it is read again a few times a second, and when the blur has
/// grown a step. Reading and blurring a place every frame was most of what the glass cost.
fn glass(id: dvui.Id, panes: []const Pane, area: dvui.Rect.Physical, g: f32, scale: f32) void {
    const base = widgets.menuFrost() orelse {
        const fill = dialogs.dialogFill();
        for (panes) |pane| {
            if (pane.r.w < 1 or pane.r.h < 1) continue;
            const c = fill.lerp(litToward(), lit_lift * pane.lit);
            pane.r.fill(cornersOf(pane.radii, 1).scale(1, dvui.CornerRect.Physical), .{ .color = .{ .color = c.opacity(@as(f32, @floatFromInt(c.a)) / 255 * g) }, .fade = 1.0 });
        }
        return;
    };
    const job = dvui.dataGetPtrDefault(null, id, "_drop_zones_job", LayerJob, .{});
    job.* = .{
        .backdrop = job.backdrop,
        .scale = scale,
        .now = dvui.currentWindow().frame_time_ns,
        .strength = g,
        // The edge comes in with the blur, so a barely-frosted pane has barely an edge.
        .lens = motion.liquid() * liquid_glass.blurRamp(base.radius),
    };
    for (panes) |pane| {
        if (pane.r.w < 1 or pane.r.h < 1) continue;
        job.panes[job.count] = pane;
        job.count += 1;
    }
    if (job.count == 0) return;
    // The layer covers the place the panes settle in, and as far beyond as their edges reach for
    // what lies past them (`liquid_glass.margin`): what it reads back and blurs is what the glass
    // will show.
    const bounds = area.insetAll(-liquid_glass.margin(.{ .lens = job.lens, .refraction = base.refraction }, scale));
    job.pane = scaled(base, g);
    // Too little blur for the pyramid to make a pass: its picture would be an empty target, laid
    // down as a hole to the desktop (`BlurBackdrop.min_blur`). Glass barely there is none yet.
    if (job.pane.radius < BlurBackdrop.min_blur) {
        job.count = 0;
        return;
    }
    job.bounds = bounds;
    const backdrop = dvui.dataGetPtrDefault(null, id, "_drop_zones_frost", BlurBackdrop, .{});
    dvui.dataSetDeinitFunction(null, id, "_drop_zones_frost", &BlurBackdrop.releaseTexture);
    backdrop.mode = .readback;
    backdrop.radius_px = job.pane.radius;
    backdrop.detail = job.pane.detail;
    backdrop.share = true;
    // Read every frame, as the dialogs' glass is: what moves under the drop — a logo following
    // the pointer — moves in it at the frame rate, not in steps a few times a second.
    backdrop.init(dvui.windowRectScale().rectFromPhysical(bounds), .{ bounds, job.now, job.pane.radius });
    job.backdrop = backdrop;
    dvui.deferRender(job, LayerJob.draw);
}

/// `base` at strength `g`: its tint and lift scaled together, so a weaker frost is the same
/// glass, thinner. Its blur stays whole: the drop forms by growing from nothing, and at the
/// dialogs' own radius every place's drop, coming or going, shares the frame's one capture
/// (`BlurBackdrop.share`) — at a radius of its own each fading place took a capture of its own.
fn scaled(base: BlurBackdrop.Pane, g: f32) BlurBackdrop.Pane {
    var pane = base;
    pane.mix = base.mix * g;
    pane.lift = base.lift * g;
    return pane;
}

/// The shared layer, drawn at replay once everything under the panes is on the frame: read and
/// blur `bounds` once, then lay each pane's bent slice of it down with the dialogs' tint and
/// lift, and a thin bright rim.
const LayerJob = struct {
    backdrop: ?*BlurBackdrop = null,
    pane: BlurBackdrop.Pane = .{},
    bounds: dvui.Rect.Physical = .{},
    scale: f32 = 1,
    now: i128 = 0,
    strength: f32 = 1,
    /// 0…1: the rim's lens and its light (`motion.liquid`).
    lens: f32 = 1,
    panes: [all.len]Pane = undefined,
    count: usize = 0,

    fn draw(ctx: ?*anyopaque) void {
        const self: *LayerJob = @ptrCast(@alignCast(ctx orelse return));
        const backdrop = self.backdrop orelse return;
        // At full alpha, as every frost draws (`BlurBackdrop.FrostJob`): the glass comes in by
        // its strength, and a frost at partial alpha is a hole.
        const prev_alpha = dvui.currentWindow().alpha;
        dvui.alphaSet(1);
        defer dvui.alphaSet(prev_alpha);
        backdrop.deinit();
        const tex = backdrop.small orelse return;
        if (self.bounds.w < 1 or self.bounds.h < 1) return;
        const mix = std.math.clamp(self.pane.mix, 0, 1);
        // As `frostPane` composes it: the frost at `1 - mix` of itself, then the tint and the
        // lift added over it.
        const frost_mod: dvui.Color = if (self.pane.tint != null) dvui.Color.white.opacity(1 - mix) else .white;
        const light = BlurBackdrop.additiveLight();
        for (self.panes[0..self.count]) |pane| {
            liquid_glass.drawPane(tex, backdrop.coverage(), pane.r, pane.radii, self.scale, frost_mod, .{
                .lens = self.lens * pane.lens,
                .refraction = self.pane.refraction,
                .sharp = backdrop.sharpTexture(),
                .blend_over = &BlurBackdrop.blendOver,
            });
            if (self.pane.tint) |tint| BlurBackdrop.addTint(pane.r, cornersOf(pane.radii, self.scale), self.scale, tint, mix);
            // The lift and the rim's light, in one pass after the tint so they stay white; a lit
            // zone is brighter and catches more.
            // Lit, the glass goes the way dvui takes a hovered fill: lighter in a dark theme (more
            // lift), darker in a light one (a shade over it once the light is on).
            const dark = dvui.themeGet().dark;
            const hover = lit_lift * pane.lit * self.strength;
            const lift = std.math.clamp(self.pane.lift + (if (dark) hover else 0), 0, 1);
            if (light) |l| liquid_glass.drawLift(l, pane.r, pane.radii, self.scale, lift, self.strength * self.lens * pane.lens * @min(1, self.pane.refraction) * (1 + 0.6 * pane.lit));
            if (!dark and hover > 0.002) {
                const corners = cornersOf(pane.radii, self.scale).scale(self.scale, dvui.CornerRect.Physical);
                pane.r.fill(corners, .{ .color = .{ .color = dvui.Color.black.opacity(hover) }, .fade = 1.0 });
            }
        }
    }
};

/// A zone's icon, over its glass (queued after it, so drawn after it). Faint until lit, and in
/// only once the glass is mostly there; blended toward the glass rather than made translucent,
/// so a glyph's crossing strokes never show.
/// `rest` is the icon's side in physical pixels once its bubble has settled: it is rasterized at
/// that and stretched as its bubble swells and shrinks (`icon.renderRaster`).
fn drawIcon(zr: dvui.Rect.Physical, glyph: Glyph, g: f32, lit: f32, scale: f32, size: f32, rest: f32) void {
    const side = size * scale;
    if (zr.w < side * 1.5 or zr.h < side * 1.5) return;
    const arrive = std.math.clamp((g - 0.45) / 0.55, 0, 1);
    if (arrive <= 0.01) return;
    const theme = dvui.themeGet();
    const ink = theme.color(.window, .text);
    // Full ink whether lit or not: every bubble is a live option, and a glyph mixed toward the
    // dialog fill read as see-through over frost that is not that colour — the lit glass says
    // which one a release takes. Mixed in only as the bubble arrives.
    _ = lit;
    const glass_c = dialogs.dialogFill().opacity(1);
    const color = glass_c.lerp(ink, arrive);
    const at_r: dvui.Rect.Physical = .{ .x = zr.x + (zr.w - side) / 2, .y = zr.y + (zr.h - side) / 2, .w = side, .h = side };
    icon_tex.renderRaster(glyph.name, glyph.tvg, .{ .r = at_r, .s = scale }, .{ .w = @round(rest), .h = @round(rest) }, .{}, .{
        .stroke_color = .{ .color = color },
        .fill_color = .transparent,
    });
}

const Glyph = struct { name: []const u8, tvg: []const u8 };

/// What each zone's icon shows: a pane opening on that side, or the middle's trade, add or join.
fn iconFor(z: Zone, center: Center) Glyph {
    return switch (z) {
        .center => switch (center) {
            .replace => .{ .name = "drop_zone_replace", .tvg = icons.tvg.lucide.replace },
            .add => .{ .name = "drop_zone_add", .tvg = icons.tvg.lucide.@"square-plus" },
            .join, .none => .{ .name = "drop_zone_join", .tvg = icons.tvg.lucide.@"squares-unite" },
        },
        .edge => |side| switch (side) {
            .left => .{ .name = "drop_zone_left", .tvg = icons.tvg.lucide.@"panel-left" },
            .right => .{ .name = "drop_zone_right", .tvg = icons.tvg.lucide.@"panel-right" },
            .top => .{ .name = "drop_zone_top", .tvg = icons.tvg.lucide.@"panel-top" },
            .bottom => .{ .name = "drop_zone_bottom", .tvg = icons.tvg.lucide.@"panel-bottom" },
        },
        .remove => .{ .name = "drop_zone_remove", .tvg = icons.tvg.lucide.@"trash-2" },
    };
}

/// `v` moved toward `target` at a constant rate: all the way in `dur_ms`, at once in none.
fn step(v: f32, target: f32, dt_ms: f32, dur_ms: f32) f32 {
    if (dur_ms <= 0) return target;
    if (dt_ms <= 0) return v;
    const d = dt_ms / dur_ms;
    return if (target > v) @min(target, v + d) else @max(target, v - d);
}

/// Whether `id`'s zones are still on screen: shown, or going.
pub fn showing(id: dvui.Id) bool {
    const st = dvui.dataGetPtr(null, id, "_drop_zones", State) orelse return false;
    return st.shown > 0;
}

/// Drop `id`'s zones outright: the next time its place is the target they come in from nothing.
pub fn forget(id: dvui.Id) void {
    dvui.dataRemove(null, id, "_drop_zones");
}

/// Take `drawSingle`'s pane away at once rather than letting it fade: for a slot whose drop has
/// landed, where the item now stands in it — a slot fading round the item that just arrived read
/// as a bubble the item grew to fill.
pub fn forgetSingle(id: dvui.Id) void {
    dvui.dataRemove(null, id, "_drop_single");
}

/// `v` eased toward `target` over `dt_ms`, with time constant `tau_ms`.
fn approach(v: f32, target: f32, dt_ms: f32, tau_ms: f32) f32 {
    if (tau_ms <= 0) return target;
    if (dt_ms <= 0) return v;
    const k = 1 - @exp(-dt_ms / tau_ms);
    const next = v + (target - v) * k;
    return if (@abs(next - target) < 0.002) target else next;
}
