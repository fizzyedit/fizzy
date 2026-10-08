//! The drop target over a place while something is dragged: a wheel in the place's middle — a
//! circle for the place itself and a ring of four around it, one for each side it could split
//! on — or, in a long, skinny place, the same circles in a strip along it. Only the place under
//! the pointer shows one; moving to another place, the old wheel goes as the new one comes in.
//!
//! **One geometry, one look, for every drag.** A view dragged between places and a file or tab
//! dragged onto a pane read the pointer against the same wheel (`wheel`, `at`) and draw the same
//! one (`draw`), so a drop means the same thing wherever it lands and looks the same getting
//! there.
//!
//! **Small, and in one place.** The wheel is the size of pixi's tool wheel, whatever the size of
//! the place, and sits in its middle — the place stays in view around it, and the choices are
//! where the eye already is. A release off the wheel does nothing: every drop is one the wheel
//! lit first. Where windows lie over the place it sits in the middle of the part they leave clear
//! (`uncovered`): a drop under a window could be neither seen whole nor aimed at.
//!
//! **A strip where a wheel would shrink.** A place too narrow for the wheel at its size — a bottom
//! panel, a narrow sidebar — would shrink every bubble to fit its short side. Where a line of them
//! along the place would be markedly bigger (`strip_gain`), that is what it shows: the place's two
//! ends at the ends of the line, its other two sides either side of the middle, the trash past the
//! end. The middle is still the place's middle, and each bubble as big as the place's length
//! allows.
//!
//! **A change of shape is liquid.** A drop whose place changes size under it — a strip offering
//! itself across the place's top — may be given the other shape. It does not cut to it: over
//! `reshape_ms` its bubbles run together into one bar of glass and pull apart into the other
//! shape, the glass's own merge doing the joining. Settled, each zone is a bubble of its own
//! again. A drop comes in already in its shape. So it is with where it is: a drop given another
//! middle and size — the part of its place it sits in changed, a window over the place stepping
//! aside or coming back — slides there over the same time, its bubbles drawn together on the way
//! and apart where it settles.
//!
//! **The look is liquid glass.** The wheel is one disc of the dialogs' own frost over what is
//! under it, drawn through `core.liquid_glass`, its sides marked off by faint lines and each
//! carrying an icon for what it does; the part under the pointer lights as dvui lights a hovered
//! fill. It grows out of the place's middle on the app's motion as its frost comes in, and goes
//! back into it, quicker.

const std = @import("std");
const dvui = @import("dvui");
const native_glass = @import("../native_glass.zig");
const dialogs = @import("../dialogs.zig");
const widgets = @import("../widgets.zig");
const BlurBackdrop = @import("BlurBackdrop.zig");
const icons = @import("icons");
const icon_tex = @import("../gfx/icon.zig");
const motion = @import("../motion.zig");
const liquid_glass = @import("../gfx/liquid_glass.zig");
const LiquidField = @import("../gfx/LiquidField.zig");

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

/// The drop over one place, in physical pixels: a cluster of bubbles in its middle — a wheel, or
/// a strip along a place too narrow for one.
pub const Wheel = struct {
    /// The middle bubble's centre: the place's.
    center: dvui.Point.Physical,
    /// Physical pixels per point of the layout below — the display scale, less if the place is
    /// too small for the whole cluster in its shape.
    unit: f32,
    /// Whether the trash is one of the bubbles.
    remove: bool = false,
    /// 0…1: the cluster's shape — 0 the wheel, 1 the strip, and between them the way from one to
    /// the other (`offset`), which only a drop changing shape is drawn at (`draw`).
    strip: f32 = 0,
    /// Which way a strip runs: along the place's longer side.
    dir: dvui.enums.Direction = .horizontal,
    /// What `unit` is fitted to (`shaped`): the place's size, physical, and the display scale.
    room: dvui.Size.Physical = .{},
    scale: f32 = 1,

    /// Where zone `z`'s bubble settles.
    pub fn bubble(self: Wheel, z: Zone) Disc {
        const off = offset(z, self.strip, self.dir);
        return .{ .c = .{ .x = self.center.x + off[0] * self.unit, .y = self.center.y + off[1] * self.unit }, .r = radiusOf(z) * self.unit };
    }

    /// The rect the settled cluster fits in: a square for the wheel, a long one for a strip —
    /// longer on the trash's side when it is offered, since the middle stays in the middle.
    pub fn rect(self: Wheel) dvui.Rect.Physical {
        const s = extents(self.strip, self.dir, self.remove);
        return .{ .x = self.center.x + s.x * self.unit, .y = self.center.y + s.y * self.unit, .w = s.w * self.unit, .h = s.h * self.unit };
    }

    /// The same drop in shape `strip`, running `dir`, in the same room. The wheel and the strip
    /// are each fitted to it (`fitted`); between them the size goes from one's to the other's as
    /// the bubbles move, rather than being fitted afresh to every arrangement on the way.
    pub fn shaped(self: Wheel, strip: f32, dir: dvui.enums.Direction) Wheel {
        var w = self;
        w.strip = strip;
        w.dir = dir;
        const k = smooth(std.math.clamp(strip, 0, 1));
        w.unit = if (k <= 0) self.fitted(0, dir) else if (k >= 1) self.fitted(1, dir) else std.math.lerp(self.fitted(0, dir), self.fitted(1, dir), k);
        return w;
    }

    /// Physical pixels per point for shape `strip` running `dir` in this room: the cluster no more
    /// than `fit` of the place either side of the middle, and no bigger than the display scale.
    fn fitted(self: Wheel, strip: f32, dir: dvui.enums.Direction) f32 {
        const s = extents(strip, dir, self.remove);
        const half_w = @max(-s.x, s.x + s.w);
        const half_h = @max(-s.y, s.y + s.h);
        return @max(0, @min(self.scale, @min(self.room.w * fit / half_w, self.room.h * fit / half_h)));
    }
};

/// Every zone, in the order they are drawn and stored.
pub const all = [_]Zone{ .center, .{ .edge = .left }, .{ .edge = .right }, .{ .edge = .top }, .{ .edge = .bottom }, .remove };

/// Points: the bubbles' layout as a wheel — the middle, the four sides round it, the trash in the
/// crook between the right and the bottom — about 345 across: big enough to aim at without
/// looking, small enough to leave the place in view round it. Each bubble rests `gap` from the
/// ones beside it.
/// The middle a quarter bigger than it was (52): the drop reads as one glass round it, not a
/// cross of equals (the user).
const center_r: f32 = 65;
const side_r: f32 = 40;
const remove_r: f32 = 30;
/// Points between a bubble and the ones beside it, at rest: past where two run together (half of
/// `merge`, for the glass's smooth union and the OS's container alike, measured), so each bubble is
/// born inside the middle, pinches off it on its way out (`grow`) and rests a drop of its own —
/// until the carried view is aimed at one, which swells (`join_swell`) until it runs into those
/// beside it. Resting joined, they read as merged all the time; just past half the merge, they
/// still reached for each other (the user).
const gap: f32 = merge * 0.75;
const side_d: f32 = center_r + side_r + gap;
/// How much bigger the bubble the carried view is aimed at grows, as it lights: enough to close the
/// gap to the bubbles beside it, so it runs into them — a side into the middle, the middle into
/// every side — and into what is carried. The bubble alone, not the whole drop (the user).
pub const join_swell: f32 = 0.3;
/// Points the trash keeps from the others even while one beside it swells: a drop of its own,
/// joining none.
const remove_apart: f32 = merge / 2 + 1;
/// The trash on the diagonal, `remove_apart` from the right and the bottom swollen —
/// |(side_d − x, x)| is d = side_r·(1 + join_swell) + remove_r + remove_apart at
/// x = (side_d + √(2·d² − side_d²)) / 2, the root out from the middle — and from the middle swollen.
const remove_d: f32 = blk: {
    const d = side_r * (1 + join_swell) + remove_r + remove_apart;
    const from_sides = (side_d + @sqrt(2 * d * d - side_d * side_d)) / 2;
    const from_middle = (center_r * (1 + join_swell) + remove_r + remove_apart) / std.math.sqrt2;
    break :blk @max(from_sides, from_middle);
};
/// Points: as a strip, one line with the wheel's own gap between each bubble and the next — the
/// two sides the place's ends are at `end_d`, the other two beside the middle at `side_d`, and the
/// trash apart past the end on its side. Across a place: left, top, middle, bottom, right, trash; down
/// one: top, left, middle, right, bottom, trash. The icons say which edge each is.
const end_d: f32 = side_d + 2 * side_r + gap;
const strip_remove_d: f32 = end_d + side_r * (1 + join_swell) + remove_apart + remove_r;
/// Points: a bubble's icon, as a share of its radius.
const bubble_icon: f32 = 0.6;
/// How far the cluster may reach either side of the middle, as a share of the place's size that
/// way: a small place still shows all of it.
pub const fit: f32 = 0.45;
/// How much bigger a strip must make the bubbles before a place shows one rather than the wheel.
/// It is for a place long and narrow enough that the wheel would shrink well under its size — a
/// bottom panel, a narrow sidebar — not one where the two would be about the same size, which
/// keeps the wheel.
pub const strip_gain: f32 = 1.15;
/// How far past its edge a bubble still takes the pointer, as a share of its radius: a drop
/// aimed at a bubble's rim is aimed at the bubble.
const reach: f32 = 1.25;
/// How near a drop takes a bubble, as a share of the two radii together between their middles: a
/// little before they touch, so the drop reaches for the bubble rather than having to be pushed
/// into it (the user: more attraction near the bubbles).
const disc_reach: f32 = 1.2;

/// Where the drop sits over `bounds`: in its middle, as a wheel — or, where a strip along the
/// place would make the bubbles `strip_gain` bigger than a wheel fitted to it, as that strip.
/// `remove` offers the trash.
///
/// A shape, not a blend: between the two the bubbles cross and run together (`offset`), which is
/// for a drop changing shape — held still it would be a blob, not a target for each zone. A view
/// drag reads each place as the rect it was at the lift, so a place on the line between the two
/// cannot flicker from one to the other.
pub fn wheel(bounds: dvui.Rect.Physical, scale: f32, remove: bool) Wheel {
    const base: Wheel = .{
        .center = bounds.center(),
        .unit = 0,
        .remove = remove,
        .dir = if (bounds.w >= bounds.h) .horizontal else .vertical,
        .room = .{ .w = bounds.w, .h = bounds.h },
        .scale = scale,
    };
    const round = base.shaped(0, base.dir);
    const strip = base.shaped(1, base.dir);
    return if (strip.unit > round.unit * strip_gain) strip else round;
}

/// The part of `bounds` clear of every rect in `covers` that the drop sits in (`wheel`): of the
/// rects that fit between them, the one where the drop is biggest, and the largest of those. Null
/// when nothing of `bounds` is clear. `covers` are the windows over a place — a drop under one could
/// not be aimed at — and `bounds` itself when none of them reaches it.
///
/// Every rect that cannot grow is bounded on each side by `bounds` or one of `covers`, so its left
/// and right are among their edges: each pair of those is a band down `bounds`, and the gaps down
/// it between the covers that cross it are the rects to weigh.
pub fn uncovered(bounds: dvui.Rect.Physical, covers: []const dvui.Rect.Physical, scale: f32, remove: bool) ?dvui.Rect.Physical {
    var cut: [max_covers]dvui.Rect.Physical = undefined;
    var n: usize = 0;
    for (covers) |c| {
        if (n == max_covers) break;
        const i = bounds.intersect(c);
        if (i.w <= 0 or i.h <= 0) continue;
        cut[n] = i;
        n += 1;
    }
    if (n == 0) return bounds;
    var xs: [2 + 2 * max_covers]f32 = undefined;
    xs[0] = bounds.x;
    xs[1] = bounds.x + bounds.w;
    for (cut[0..n], 0..) |c, i| {
        xs[2 + 2 * i] = c.x;
        xs[3 + 2 * i] = c.x + c.w;
    }
    const edges = xs[0 .. 2 + 2 * n];
    std.mem.sort(f32, edges, {}, std.sort.asc(f32));
    var best: ?dvui.Rect.Physical = null;
    var best_unit: f32 = 0;
    var best_area: f32 = 0;
    for (edges, 0..) |x0, i| for (edges[i + 1 ..]) |x1| {
        if (x1 - x0 < 1) continue;
        // The covers across this band, as spans down it, top first.
        var spans: [max_covers][2]f32 = undefined;
        var m: usize = 0;
        for (cut[0..n]) |c| {
            if (c.x >= x1 or c.x + c.w <= x0) continue;
            spans[m] = .{ c.y, c.y + c.h };
            m += 1;
        }
        std.mem.sort([2]f32, spans[0..m], {}, struct {
            fn lt(_: void, a: [2]f32, b: [2]f32) bool {
                return a[0] < b[0];
            }
        }.lt);
        var y = bounds.y;
        for (0..m + 1) |k| {
            const top = if (k < m) spans[k][0] else bounds.y + bounds.h;
            if (top - y >= 1) {
                const r: dvui.Rect.Physical = .{ .x = x0, .y = y, .w = x1 - x0, .h = top - y };
                const unit = wheel(r, scale, remove).unit;
                const area = r.w * r.h;
                // Bigger by more than a rounding: the drop is what is aimed at, so its size comes
                // first, and between places it is as big in, the more of the place round it.
                const bigger = unit > best_unit + 0.001 * scale;
                const as_big = @abs(unit - best_unit) <= 0.001 * scale;
                if (best == null or bigger or (as_big and area > best_area)) {
                    best = r;
                    best_unit = unit;
                    best_area = area;
                }
            }
            if (k < m) y = @max(y, spans[k][1]);
        }
    };
    return best;
}

/// The most covers `uncovered` weighs; past this, the topmost windows over a place are the ones
/// that count, and a place under so many has little left to drop on.
pub const max_covers = 16;

/// Points: zone `z`'s bubble's radius.
fn radiusOf(z: Zone) f32 {
    return switch (z) {
        .center => center_r,
        .edge => side_r,
        .remove => remove_r,
    };
}

/// Points: where zone `z`'s bubble sits from the middle, in shape `strip` (0 the wheel, 1 the
/// strip) running `dir`. Between the two, each bubble is on the straight way from its place in
/// one to its place in the other, drawn in toward the middle as it goes (`gather`): crossing,
/// they run together (`merge`), the wheel stretching into one bar of glass that breaks into the
/// strip's beads as it settles, and back.
fn offset(z: Zone, strip: f32, dir: dvui.enums.Direction) [2]f32 {
    const from = wheelAt(z);
    const to = stripAt(z, dir);
    const t = std.math.clamp(strip, 0, 1);
    const k = smooth(t);
    // Drawn in most halfway and not at all at either end, where every bubble stands clear.
    const drawn_in = 1 - gather * 4 * t * (1 - t);
    return .{ std.math.lerp(from[0], to[0], k) * drawn_in, std.math.lerp(from[1], to[1], k) * drawn_in };
}

/// How far toward the middle the bubbles are drawn halfway through a change of shape, as a share
/// of where they would be: enough to close every gap along the line as it forms, so it is one bar
/// rather than a row of beads crossing.
const gather: f32 = 0.2;

/// Points: zone `z`'s place in the wheel, from its middle.
fn wheelAt(z: Zone) [2]f32 {
    return switch (z) {
        .center => .{ 0, 0 },
        .edge => |sd| switch (sd) {
            .left => .{ -side_d, 0 },
            .right => .{ side_d, 0 },
            .top => .{ 0, -side_d },
            .bottom => .{ 0, side_d },
        },
        .remove => .{ remove_d, remove_d },
    };
}

/// Points: zone `z`'s place in a strip running `dir`, from its middle. A strip down a place is one
/// across it turned over its diagonal.
fn stripAt(z: Zone, dir: dvui.enums.Direction) [2]f32 {
    const along: f32 = switch (if (dir == .horizontal) z else turned(z)) {
        .center => 0,
        .edge => |sd| switch (sd) {
            .left => -end_d,
            .top => -side_d,
            .bottom => side_d,
            .right => end_d,
        },
        .remove => strip_remove_d,
    };
    return if (dir == .horizontal) .{ along, 0 } else .{ 0, along };
}

/// The zone whose place in a strip across is `z`'s in a strip down: the top and left trade, the
/// bottom and right.
fn turned(z: Zone) Zone {
    return switch (z) {
        .edge => |sd| .{ .edge = switch (sd) {
            .left => .top,
            .top => .left,
            .right => .bottom,
            .bottom => .right,
        } },
        else => z,
    };
}

/// Smoothstep: 0 to 1, easing out of 0 and into 1.
fn smooth(t: f32) f32 {
    return t * t * (3 - 2 * t);
}

/// Points: the rect the cluster covers in shape `strip`, running `dir`, from the middle.
fn extents(strip: f32, dir: dvui.enums.Direction, remove: bool) dvui.Rect {
    var lo: [2]f32 = .{ 0, 0 };
    var hi: [2]f32 = .{ 0, 0 };
    for (all) |z| {
        if (z == .remove and !remove) continue;
        const o = offset(z, strip, dir);
        const r = radiusOf(z);
        for (0..2) |i| {
            lo[i] = @min(lo[i], o[i] - r);
            hi[i] = @max(hi[i], o[i] + r);
        }
    }
    return .{ .x = lo[0], .y = lo[1], .w = hi[0] - lo[0], .h = hi[1] - lo[1] };
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

/// The zone a drop of radius `r` centred on `c` reads as — a carried drop of glass, aimed by
/// where it is rather than by the finger beside it: of the bubbles it touches or nearly does
/// (`disc_reach`), the one it is most into (nearest for their sizes together), and nothing near
/// none. A point (`r` 0) reads as `at`.
pub fn atDisc(w: Wheel, c: dvui.Point.Physical, r: f32) ?Zone {
    if (r <= 0) return at(w, c);
    var best: ?Zone = null;
    var best_d: f32 = disc_reach;
    for (all) |z| {
        if (z == .remove and !w.remove) continue;
        const b = w.bubble(z);
        const dx = c.x - b.c.x;
        const dy = c.y - b.c.y;
        const d = @sqrt(dx * dx + dy * dy) / @max(b.r + r, 0.001);
        if (d < best_d) {
            best = z;
            best_d = d;
        }
    }
    return best;
}

fn inset(r: dvui.Rect.Physical, dx: f32, dy: f32) dvui.Rect.Physical {
    return .{ .x = r.x + dx, .y = r.y + dy, .w = @max(0, r.w - 2 * dx), .h = @max(0, r.h - 2 * dy) };
}

/// How long the drop takes to come in and to go, in milliseconds: the orbs growing into their
/// glass one after another, watched as the place is arrived at, and going the same way backwards —
/// quickly, but slowly enough to be seen doing it rather than popping.
pub const appear_ms: f32 = 380;
pub const vanish_ms: f32 = 380;
/// A time constant: how quickly a zone lights or dims under the pointer, most of the way in
/// about three of these.
pub const light_ms: f32 = 55;
/// How long a drop takes to change shape, in milliseconds — its place's room changed under it,
/// and a wheel became a strip or a strip a wheel: the bubbles running together and pulling apart
/// (`offset`), slowly enough to see which went where.
pub const reshape_ms: f32 = 420;

const State = struct {
    /// 0…1, linear in time; shaped when read (`grow`, `frost`).
    shown: f32 = 0,
    /// 0…1: how lit — the zone under the pointer.
    lit: [all.len]f32 = @splat(0),
    last_ns: i128 = 0,
    /// The shape as drawn (`Wheel.strip`, `Wheel.dir`), linear in time toward the one the drop is
    /// given; set from it on the first frame (`shaped`), so a drop comes in already in its shape.
    strip: f32 = 0,
    dir: dvui.enums.Direction = .horizontal,
    shaped: bool = false,
    /// Where the drop is drawn and how big (`Wheel.center`, `Wheel.unit`) as of last frame, and
    /// the slide it is on: from where it was drawn when it was given somewhere else (`from_at`,
    /// `from_unit`) to that place (`to_at`, `to_unit`), `slide` of the way there, linear in time.
    at: dvui.Point.Physical = .{},
    unit: f32 = 0,
    from_at: dvui.Point.Physical = .{},
    from_unit: f32 = 0,
    to_at: dvui.Point.Physical = .{},
    to_unit: f32 = 0,
    slide: f32 = 1,
    /// The drop as it was last given (`given`).
    given: Wheel = .{ .center = .{}, .unit = 0 },
    /// The icons `draw` laid out and left for `drawIcons` (`Look.icons = .later`), and the frame.
    icons: [all.len]IconAt = undefined,
    icon_n: usize = 0,
    icon_frame: i128 = 0,
};

/// An icon as `draw` laid it out: `drawIcon`'s arguments.
const IconAt = struct { r: dvui.Rect.Physical, glyph: Glyph, g: f32, lit: f32, size: f32, rest: f32, focus: f32 };

/// What dropping in the middle does, for its icon: trade places with the one view a place shows,
/// add to the several it shows, join it with the place beside it into one, float the view out of
/// the place it was lifted from into a window of its own — or nothing, the middle of that place
/// when the view cannot float, which is bare glass.
pub const Center = enum { replace, add, join, float, none };

/// How one place's zones are drawn this frame.
pub const Look = struct {
    /// The zone under the pointer, which lights.
    hovered: ?Zone = null,
    /// False sends them all away — the pointer left the place, or the drag ended — until
    /// `showing` says they are gone.
    target: bool = true,
    /// The middle's icon.
    center: Center = .replace,
    /// Glass carried over the drop — the dragged view's drop — run together with its bubbles
    /// where the glass program draws them (`LiquidField`), so the carried drop reaching a
    /// bubble bridges into it. Whether they were taken is `draw`'s answer.
    carried: []const LiquidField.Shape = &.{},
    /// When the icons are drawn: with the glass, or `.later` by the caller (`drawIcons`), over
    /// whatever it lays on the drop after it — the carried view's picture, which would otherwise
    /// cover the very bubble it is about to be dropped in.
    icons: enum { now, later } = .now,
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
pub fn draw(id: dvui.Id, w: Wheel, scale: f32, look: Look) bool {
    const st = dvui.dataGetPtrDefault(null, id, "_drop_zones", State, .{});
    st.given = w;
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

    // Given another shape — the place's room changed under the drop, a strip offering itself
    // across its top — it changes into it along the way `offset` takes rather than cutting to it,
    // and a strip turning to run the other way goes back through the wheel, where which way it
    // runs makes no difference. It is drawn as it is now but read as it will be — `at`, and a
    // release, which keep no state: for the moment a change takes, what lights is the bubble
    // arriving under the pointer rather than the one leaving it.
    if (!st.shaped) {
        st.strip = w.strip;
        st.to_at = w.center;
        st.to_unit = w.unit;
        st.at = w.center;
        st.unit = w.unit;
    }
    if (!st.shaped or st.strip == 0) st.dir = w.dir;
    st.shaped = true;
    st.strip = step(st.strip, if (st.dir == w.dir) w.strip else 0, dt_ms, motion.durationMs(reshape_ms));
    const reshaping = st.strip != w.strip or st.dir != w.dir;
    if (reshaping) moving = true;
    var drawn = if (reshaping) w.shaped(st.strip, st.dir) else w;
    // Given somewhere else in its place — the part of the place it sits in changed under it, a
    // window over the place stepping aside or coming back — it slides there and takes the size it
    // has there on the way, from wherever it is drawn now, on the motion every slide has: the
    // bubbles drawn in toward the middle as they go, so they run together into one piece of glass
    // and pull apart again where it settles. Read, like a change of shape, where it is going.
    if (w.center.x != st.to_at.x or w.center.y != st.to_at.y or w.unit != st.to_unit) {
        st.from_at = st.at;
        st.from_unit = st.unit;
        st.to_at = w.center;
        st.to_unit = w.unit;
        st.slide = 0;
    }
    st.slide = step(st.slide, 1, dt_ms, motion.durationMs(reshape_ms));
    const sliding = st.slide < 1;
    if (sliding) {
        moving = true;
        const k = motion.settle(st.slide);
        drawn.center = .{ .x = std.math.lerp(st.from_at.x, w.center.x, k), .y = std.math.lerp(st.from_at.y, w.center.y, k) };
        drawn.unit = @max(0, std.math.lerp(st.from_unit, drawn.unit, k));
    }
    st.at = drawn.center;
    st.unit = drawn.unit;
    // Drawn in most halfway through a slide and not at all at either end (`gather`, as a change
    // of shape draws them).
    const spread: f32 = if (sliding) 1 - gather * 4 * st.slide * (1 - st.slide) else 1;

    const g = frost(st.shown);
    var took = false;
    if (g > 0.01 and drawn.unit > 0) {
        // Each bubble is a glass orb of its own, where it settles: nothing moves but a drop
        // changing shape. Each grows from nothing to its size — past it and back when motion is
        // playful (`grow`) — the middle first, then the others one after another (`growOrder`, in
        // the shape it is given, so a change of shape does not reorder them partway in); leaving
        // is the same played backwards. Its refracting edge springs in with its size, its blur
        // comes in from sharp (`frost`), and its icon comes into focus with it. Separate panes
        // over one capture of the area they settle in: sizing them changes no capture, so it
        // costs nothing, and nothing joins, so there is no union to mesh.
        var order_buf: [all.len]usize = undefined;
        const order = growOrder(w, &order_buf);
        var panes: [all.len]Pane = undefined;
        var zones: [all.len]usize = undefined;
        var times: [all.len]f32 = undefined;
        var n: usize = 0;
        for (order, 0..) |zi, j| {
            const t = orbTime(st.shown, j, order.len);
            const k = grow(t);
            const b = drawn.bubble(all[zi]);
            // The bubble the carried view is aimed at swells as it lights (`join_swell`) — the
            // trash, a drop of its own, keeps its size.
            const r = b.r * k * (if (all[zi] == .remove) 1 else 1 + join_swell * st.lit[zi]);
            if (r < 0.5) continue;
            // Out of the middle to where it settles, on the same curve as its size: each bubble
            // is born inside the drop and pinches off it on its way out (`merge`), past its place
            // and back when motion is playful; leaving, it is drawn back in and poured into it.
            const c: dvui.Point.Physical = .{ .x = drawn.center.x + (b.c.x - drawn.center.x) * k * spread, .y = drawn.center.y + (b.c.y - drawn.center.y) * k * spread };
            panes[n] = .{ .r = .{ .x = c.x - r, .y = c.y - r, .w = 2 * r, .h = 2 * r }, .lit = st.lit[zi], .radii = liquid_glass.uniform(r), .lens = k };
            zones[n] = zi;
            times[n] = t;
            n += 1;
        }
        // Changing shape, what is read moves and grows with the bubbles: at a size kept while it
        // fits, as for the carried drop, so it is not new targets every frame of the change.
        // Where the OS draws a view drag's glass (`native_glass`), the bubbles are declared for it
        // instead: its glass runs them together, and into the carried drop, itself.
        took = if (native_glass.on()) native: {
            for (panes[0..n]) |pane| native_glass.add(.{ .rect = pane.r, .radius = pane.r.w / 2, .lit = pane.lit, .alpha = g });
            native_glass.mergeWithin(merge * drawn.unit);
            break :native false;
        } else glassCarrying(id, panes[0..n], swingRect(drawn), g, scale, merge * drawn.unit, look.carried, reshaping or sliding);
        st.icon_n = 0;
        st.icon_frame = now;
        for (panes[0..n], zones[0..n], times[0..n]) |pane, i, t| {
            const z = all[i];
            if (z == .center and look.center == .none) continue;
            const f = frost(t);
            st.icons[st.icon_n] = .{ .r = pane.r, .glyph = iconFor(z, look.center), .g = f, .lit = st.lit[i], .size = pane.r.w / 2 * bubble_icon / scale, .rest = w.bubble(z).r * bubble_icon, .focus = f };
            st.icon_n += 1;
        }
        if (look.icons == .now) drawIcons(id, scale);
    } else {
        st.icon_n = 0;
    }

    if (moving) {
        dvui.refresh(null, @src(), id);
    } else if (!look.target) {
        forget(id);
    } else {
        // Settled: stop keeping time. A drag held still asks for no frames, and the release after
        // it measured the whole pause as one step — past the entire leave, gone at once.
        st.last_ns = 0;
    }
    return took;
}

/// The icons this frame's `draw` of `id` laid out, over everything drawn since — for a caller that
/// passed `Look.icons = .later` and has laid the carried view over the drop.
pub fn drawIcons(id: dvui.Id, scale: f32) void {
    const st = dvui.dataGetPtr(null, id, "_drop_zones", State) orelse return;
    if (st.icon_frame != dvui.currentWindow().frame_time_ns) return;
    for (st.icons[0..st.icon_n]) |ic| drawIcon(ic.r, ic.glyph, ic.g, ic.lit, scale, ic.size, ic.rest, ic.focus);
}

/// Orb `j` of `n` (in `growOrder`)'s own time at `shown`, 0 gone … 1 settled: each over a window
/// of its own, `stagger` after the one before, so they grow one after another and, leaving, go
/// the other way round.
fn orbTime(shown: f32, j: usize, n: usize) f32 {
    const span = 1 - stagger * @as(f32, @floatFromInt(n -| 1));
    return std.math.clamp((shown - stagger * @as(f32, @floatFromInt(j))) / span, 0, 1);
}

/// Points: how far apart two shapes of glass start to run together (`LiquidField.merge_px`; they
/// join below half of it) — a side bubble's radius or so, so the carried drop reaches for a bubble
/// from well off and one leaving the drop draws a long neck out of it. A view carried as a drop is
/// drawn at it too, over a place or between them (`ViewDrag`): a join's swell is part of a shape's
/// size, so glass drawn at two merges is two sizes.
pub const merge: f32 = 36;

/// How far behind the one before each orb starts, as a share of `shown`.
const stagger: f32 = 0.06;

/// Where `w`'s bubbles settle, and as far again as they swing past their places and their sizes
/// when motion is playful (`grow`): what the glass under them reads.
fn swingRect(w: Wheel) dvui.Rect.Physical {
    const r = w.rect();
    const k = 1 + motion.overshoot_max;
    return .{ .x = w.center.x + (r.x - w.center.x) * k, .y = w.center.y + (r.y - w.center.y) * k, .w = r.w * k, .h = r.h * k };
}

/// The bubbles in the order they grow: the middle, then the others — round it clockwise from the
/// top for a wheel, out from it for a strip, the nearer first and the left (or upper) of two.
fn growOrder(w: Wheel, buf: *[all.len]usize) []const usize {
    buf[0] = 0; // `.center`
    var n: usize = 1;
    for (all, 0..) |z, i| {
        if (z == .center or (z == .remove and !w.remove)) continue;
        buf[n] = i;
        n += 1;
    }
    const Order = struct {
        fn angle(wh: Wheel, i: usize) f32 {
            const b = wh.bubble(all[i]);
            // Screen y runs down, so this climbs clockwise from the top (−½π).
            var a = std.math.atan2(b.c.y - wh.center.y, b.c.x - wh.center.x);
            if (a < -std.math.pi / 2.0) a += 2 * std.math.pi;
            return a;
        }
        /// Points along the strip from the middle.
        fn along(wh: Wheel, i: usize) f32 {
            const o = offset(all[i], wh.strip, wh.dir);
            return if (wh.dir == .horizontal) o[0] else o[1];
        }
        fn less(wh: Wheel, a: usize, b: usize) bool {
            if (wh.strip < 0.5) return angle(wh, a) < angle(wh, b);
            const pa = along(wh, a);
            const pb = along(wh, b);
            if (@abs(@abs(pa) - @abs(pb)) > 1) return @abs(pa) < @abs(pb);
            return pa < pb;
        }
    };
    std.mem.sort(usize, buf[1..n], w, Order.less);
    return buf[0..n];
}

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
            // The edge comes in with the blur, so a barely-frosted pane has barely an edge — past
            // its shape and back as it arrives when motion is playful, as a menu's does.
            .lens = grow(g),
        };
        glass(id, &.{pane}, st.rect, g, scale, 0);
        if (opts.icon) |icon| drawIcon(pane.r, iconFor(.center, icon), g, 1, scale, icon_size, icon_size * scale, g);
    }
    if (moving) {
        dvui.refresh(null, @src(), id);
    } else if (rect == null) {
        dvui.dataRemove(null, id, "_drop_single");
    }
}

// ── Coming and going ────────────────────────────────────────────────────────────────────────────

/// How big a zone is at progress `t`, and how much of its edge it has: arriving, at the app's motion level (`motion.enter`) — a
/// slight bounce at minimal, a soft spring at playful, plain at the low end. Read backwards on the
/// way out, the same curve swells a touch and then goes.
fn grow(t: f32) f32 {
    // The whole curve over the phase, approach and swing, with no hold after: the zones time
    // their own phases, and one that arrived early and sat still would leave its phase dead.
    return @max(0, motion.enterFull(t));
}

/// How much frost a zone has at progress `t`: linear, whole by `frost_by` of the way — ahead
/// of its size, so the glass is glass before it has finished arriving, but slowly enough to be
/// seen forming.
fn frost(t: f32) f32 {
    return std.math.clamp(t / frost_by, 0, 1);
}
const frost_by: f32 = 0.6;

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
fn glass(id: dvui.Id, panes: []const Pane, area: dvui.Rect.Physical, g: f32, scale: f32, merge_px: f32) void {
    _ = glassCarrying(id, panes, area, g, scale, merge_px, &.{}, false);
}

/// `glass`, with `carried` shapes run in with the panes where the glass program draws them:
/// whether it took them. `moving`: `area` changes from frame to frame.
fn glassCarrying(id: dvui.Id, panes: []const Pane, area_in: dvui.Rect.Physical, g: f32, scale: f32, merge_px: f32, carried_in: []const LiquidField.Shape, moving: bool) bool {
    const carried = if (LiquidField.ready()) carried_in[0..@min(carried_in.len, max_carried)] else carried_in[0..0];
    // What is read covers the carried glass too, at a size kept while it fits (as a moving pane's
    // is, `BlurBackdrop.captureSize`), so a drop dragged about the place — or one changing shape —
    // does not make new targets every frame.
    var area = area_in;
    if (carried.len > 0 or moving) {
        for (carried) |c| area = area.unionWith(c.rect.outsetAll(merge_px));
        const cap = dvui.dataGetPtrDefault(null, id, "_drop_zones_cap", dvui.Size, .{});
        cap.* = BlurBackdrop.captureSize(cap.*, .{ .w = area.w, .h = area.h });
        area.w = cap.w;
        area.h = cap.h;
    }
    const base = widgets.liquidFrost() orelse {
        const fill = dialogs.dialogFill();
        for (panes) |pane| {
            if (pane.r.w < 1 or pane.r.h < 1) continue;
            const c = fill.lerp(litToward(), lit_lift * pane.lit);
            pane.r.fill(cornersOf(pane.radii, 1).scale(1, dvui.CornerRect.Physical), .{ .color = .{ .color = c.opacity(@as(f32, @floatFromInt(c.a)) / 255 * g) }, .fade = 1.0 });
        }
        return false;
    };
    const job = dvui.dataGetPtrDefault(null, id, "_drop_zones_job", LayerJob, .{});
    const lens_full = motion.liquid() * (if (base.clear) 1 else liquid_glass.blurRamp(base.radius));
    job.* = .{
        .backdrop = job.backdrop,
        .scale = scale,
        .now = dvui.currentWindow().frame_time_ns,
        .strength = g,
        .merge_px = merge_px,
        // How much of it each pane has is the pane's own (`Pane.lens`): a drop's orbs each form
        // their edge on their own way out.
        .lens = lens_full,
    };
    for (panes) |pane| {
        if (pane.r.w < 1 or pane.r.h < 1) continue;
        job.panes[job.count] = pane;
        job.count += 1;
    }
    for (carried, 0..) |c, i| job.carried[i] = c;
    job.carried_n = carried.len;
    if (job.count == 0 and carried.len == 0) return false;
    // The layer covers the place the panes settle in, and as far beyond as their edges reach for
    // what lies past them (`liquid_glass.margin`): what it reads back and blurs is what the glass
    // will show. As far as the whole edge reaches at its swing, however much of it has formed — a
    // capture that grew with it was a new size, and new targets, every frame.
    const bounds = area.insetAll(-liquid_glass.margin(.{ .lens = lens_full * (1 + motion.overshoot_max), .refraction = base.refraction }, scale));
    // Whole from the first frame, as every pane's frost is (`BlurBackdrop.Pane.form`): the
    // bubbles come in by their size and their edge, never as glass that has not frosted yet.
    job.pane = base;
    // Too little blur for the pyramid to make a pass: its picture would be an empty target, laid
    // down as a hole to the desktop (`BlurBackdrop.min_blur`). Glass barely there is none yet.
    if (job.pane.radius < BlurBackdrop.min_blur or g < 0.02) {
        job.count = 0;
        job.carried_n = 0;
        return false;
    }
    job.bounds = bounds;
    const backdrop = dvui.dataGetPtrDefault(null, id, "_drop_zones_frost", BlurBackdrop, .{});
    dvui.dataSetDeinitFunction(null, id, "_drop_zones_frost", &BlurBackdrop.releaseTexture);
    backdrop.mode = .readback;
    backdrop.radius_px = job.pane.radius;
    backdrop.detail = job.pane.detail;
    backdrop.form = 1;
    // Read every frame, as the dialogs' glass is: what moves under the drop — a logo following the
    // pointer — moves in it at the frame rate.
    backdrop.init(dvui.windowRectScale().rectFromPhysical(bounds), .{ bounds, job.now, job.pane.radius });
    job.backdrop = backdrop;
    dvui.deferRender(job, LayerJob.draw);
    return carried.len > 0;
}

/// The most carried shapes a drop runs in with its bubbles.
const max_carried = 4;

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
    /// Physical pixels: how far apart panes still run together, where the glass program draws
    /// them (`LiquidField`).
    merge_px: f32 = 0,
    panes: [all.len]Pane = undefined,
    carried: [max_carried]LiquidField.Shape = undefined,
    carried_n: usize = 0,
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
        if (drawFieldImpl(self, tex, backdrop)) return;
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

/// The panes as one `LiquidField`, run together where they are close: a drop and the bubbles
/// leaving it. False where there is no glass program, and the panes are drawn one by one.
fn drawFieldImpl(self: *const LayerJob, tex: dvui.Texture, backdrop: *BlurBackdrop) bool {
    if (!LiquidField.ready()) return false;
    const dark = dvui.themeGet().dark;
    var field: LiquidField = .{
        .merge_px = self.merge_px,
        .scale = self.scale,
        .tint = self.pane.tint,
        .mix = self.pane.mix,
        .lift = self.pane.lift,
        .refraction = self.pane.refraction,
    };
    for (self.panes[0..self.count]) |pane| {
        const hover = lit_lift * pane.lit * self.strength;
        field.add(.{
            .rect = pane.r,
            .radii = .{ pane.radii[0], pane.radii[3], pane.radii[2], pane.radii[1] },
            .lens = self.lens * pane.lens * (1 + 0.6 * pane.lit),
            // Lit, lighter in a dark theme, as dvui takes a hovered fill.
            .light = if (dark) hover else 0,
            .round = true,
            .blur = if (self.pane.clear) 0 else 1,
        });
    }
    for (self.carried[0..self.carried_n]) |c| {
        var sh = c;
        sh.lens *= self.lens;
        if (self.pane.clear) sh.blur = 0;
        field.add(sh);
    }
    const sharp = backdrop.sharpTexture();
    const distinct = if (sharp) |t| t.ptr != tex.ptr else false;
    return field.draw(tex, backdrop.coverage(), if (distinct) sharp else null);
}

/// A zone's icon, over its glass (queued after it, so drawn after it). Dimmed until lit — the
/// bubble a release would take stands out in full ink, a little larger, the others recede; the
/// trash lights red, as a close button does — and
/// in only once the glass is mostly there; blended toward the glass rather than made translucent,
/// so a glyph's crossing strokes never show.
/// `rest` is the icon's side in physical pixels once its bubble has settled: it is rasterized at
/// that and stretched as its bubble swells and shrinks (`icon.renderRaster`).
/// `focus`, 0…1: how sharp — from a blur, as the glass under it forms, to crisp at 1.
fn drawIcon(zr: dvui.Rect.Physical, glyph: Glyph, g: f32, lit: f32, scale: f32, size: f32, rest_side: f32, focus: f32) void {
    if (zr.w < size * scale * 1.5 or zr.h < size * scale * 1.5) return;
    const arrive = std.math.clamp(g / 0.7, 0, 1);
    if (arrive <= 0.01) return;
    const on = std.math.clamp(lit, 0, 1);
    const grown = 1 + (lit_icon_grow - 1) * on;
    const side = size * scale * grown;
    // Rasterized at its lit size, so the one a release takes is crisp; the others draw it smaller.
    const rest = rest_side * lit_icon_grow;
    const theme = dvui.themeGet();
    const ink = theme.color(.window, .text);
    // Opaque at both ends, so the mix is: the dialog fill is translucent (`opacity` scales alpha,
    // it does not set it), and a translucent glyph doubles where its strokes cross.
    var glass_c = dialogs.dialogFill();
    glass_c.a = 255;
    var ink_c = ink;
    ink_c.a = 255;
    var color = glass_c.lerp(ink_c, arrive * (dim_icon + (1 - dim_icon) * on));
    if (glyph.danger) {
        var err_c = theme.color(.err, .fill);
        err_c.a = 255;
        color = color.lerp(err_c, arrive * on);
    }
    const at_r: dvui.Rect.Physical = .{ .x = zr.x + (zr.w - side) / 2, .y = zr.y + (zr.h - side) / 2, .w = side, .h = side };
    const icon_opts: dvui.IconRenderOptions = .{ .stroke_color = .{ .color = color }, .fill_color = .transparent };
    const sharp = std.math.clamp(focus, 0, 1);
    if (sharp >= 0.999) {
        icon_tex.renderRaster(glyph.name, glyph.tvg, .{ .r = at_r, .s = scale }, .{ .w = @round(rest), .h = @round(rest) }, .{}, icon_opts);
    } else {
        // From an eighth of its size, stretched — a blur — up to whole as it comes sharp.
        icon_tex.renderSoft(glyph.name, glyph.tvg, .{ .r = at_r, .s = scale }, rest * (focus_from + (1 - focus_from) * sharp * sharp), .{}, icon_opts);
    }
}

/// How much of the ink an icon has while its bubble is not the one a release takes — mixed toward
/// the glass, so it still reads over frost and over the carried view's picture alike.
const dim_icon: f32 = 0.45;
/// How much larger the icon of the bubble a release takes is drawn.
const lit_icon_grow: f32 = 1.15;

/// How small an icon is rasterized at its blurriest, as a share of its size.
const focus_from: f32 = 0.125;

const Glyph = struct {
    name: []const u8,
    tvg: []const u8,
    /// Lit in the theme's error colour, as a close button is: the trash.
    danger: bool = false,
};

/// What each zone's icon shows: a pane opening on that side, or the middle's trade, add, join or float.
fn iconFor(z: Zone, center: Center) Glyph {
    return switch (z) {
        .center => switch (center) {
            .replace => .{ .name = "drop_zone_replace", .tvg = icons.tvg.lucide.replace },
            .add => .{ .name = "drop_zone_add", .tvg = icons.tvg.lucide.@"square-plus" },
            .join, .none => .{ .name = "drop_zone_join", .tvg = icons.tvg.lucide.@"squares-unite" },
            .float => .{ .name = "drop_zone_float", .tvg = icons.tvg.lucide.@"app-window" },
        },
        .edge => |side| switch (side) {
            .left => .{ .name = "drop_zone_left", .tvg = icons.tvg.lucide.@"panel-left" },
            .right => .{ .name = "drop_zone_right", .tvg = icons.tvg.lucide.@"panel-right" },
            .top => .{ .name = "drop_zone_top", .tvg = icons.tvg.lucide.@"panel-top" },
            .bottom => .{ .name = "drop_zone_bottom", .tvg = icons.tvg.lucide.@"panel-bottom" },
        },
        .remove => .{ .name = "drop_zone_remove", .tvg = icons.tvg.lucide.@"trash-2", .danger = true },
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

/// The shape `id`'s drop is drawn in (`Wheel.strip`, `Wheel.dir`), and where and how big
/// (`Wheel.center`, `Wheel.unit`): as it was given, or on its way there (`reshape_ms`). Null with
/// no drop.
pub fn shapeOf(id: dvui.Id) ?struct { strip: f32, dir: dvui.enums.Direction, center: dvui.Point.Physical, unit: f32 } {
    const st = dvui.dataGetPtr(null, id, "_drop_zones", State) orelse return null;
    return .{ .strip = st.strip, .dir = st.dir, .center = st.at, .unit = st.unit };
}

/// The drop `id` was last given to draw, while it is on screen: for one whose place has none to
/// give it now, to finish going where it was.
pub fn given(id: dvui.Id) ?Wheel {
    const st = dvui.dataGetPtr(null, id, "_drop_zones", State) orelse return null;
    return if (st.shown > 0) st.given else null;
}

/// Drop `id`'s zones outright: the next time its place is the target they come in from nothing.
pub fn forget(id: dvui.Id) void {
    dvui.dataRemove(null, id, "_drop_zones");
}

/// Hand the drop `from` is drawing over to `to`, which has none yet: `to` starts out as `from`'s
/// glass, where it is and as big and as far in, and changes into its own shape and place from there
/// as any drop given somewhere else does (`draw`) — one drop running into another rather than one
/// going while the other comes over it. `from` is gone. Nothing lights until `to` says so.
pub fn handOff(from: dvui.Id, to: dvui.Id) void {
    const st = dvui.dataGetPtr(null, from, "_drop_zones", State) orelse return;
    var next = st.*;
    next.lit = @splat(0);
    next.icon_n = 0;
    dvui.dataSet(null, to, "_drop_zones", next);
    forget(from);
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
