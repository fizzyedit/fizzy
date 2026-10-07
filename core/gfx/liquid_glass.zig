//! Frosted glass shaped like a drop of water.
//!
//! A frost is a blurred picture of what is under a pane. Laid down as a flat textured rect it is
//! a sheet of paper; laid down as a mesh whose texture coordinates follow the shape of a drop, it
//! is glass. A drop is flat across the middle and curves down to its rim, so near the rim it
//! **refracts**: it shows what lies just beyond its edge, squeezed into a sliver along it, most at
//! the very edge and fading softly inward. Its border catches **light**: a thin line, brightest
//! at the top left and bottom right (`drawLift`, in one pass with the pane's lift).
//!
//! **One smooth field, not a bevel.** Both come from a soft distance to the pane's edges — the
//! four sides blended, not the nearest one taken — whose gradient turns smoothly round a corner.
//! A bevel of rings, each bent along its own normal, folded along every corner's diagonal like a
//! mitred frame; a band with a fixed profile drew a line where it met the face. The field has no
//! crease anywhere, so neither does the glass.
//!
//! The rim is also **clearer** than the face: the picture before the blur shows through it,
//! bent the same way, strongest at the very edge and fading into the frost with the drop's
//! steepness. (Through a bevel's creases the same picture drew streaks; through a smooth field it
//! is only bent.)
//!
//! How much of it is the caller's (`Look`): the app scales it by `core.motion.liquid` and the
//! user's dialog refraction, so the glass is flat when motion is off.
//!
//! **Every pane is glass, whatever its size.** The rim's geometry — how deep its curve runs, how
//! far out it reaches, how softly its corners turn — is sized for a dialog. A pane too small to
//! hold it (a tooltip, a pill, a bar's bubble) gets the same rim scaled down to fit (`fit`): a
//! small drop of glass, as refracting, as clear at the edge and as lit as a big one, rather than
//! one that is all rim — or, as it once was, plain frost with the edge taken away.
const std = @import("std");
const dvui = @import("dvui");

/// Points: how far *out*, at the very rim, the drop reaches for what it shows (times
/// `Look.refraction`); how far in its curve fades by a factor of e; and how softly its sides blend
/// into each other round a corner.
///
/// Out, not in: the rim of a drop shows what lies just beyond it, squeezed into a sliver along its
/// edge — an icon beside a pane curls round into its rim. Reaching *in* instead magnified the
/// pane's own face, which is subtler, and folded back on itself into a mirror line when pushed;
/// reaching out only ever compresses, so it never folds at any strength. The frost has to have
/// what lies out there in it: a caller captures `margin` beyond the pane.
pub const refraction: f32 = 22;
pub const falloff: f32 = 6;
pub const softness: f32 = 10;

/// How much deeper than `falloff` the curve runs at the strongest refraction: past the setting's
/// middle it does not only bend harder, it bends further in — at the top of the scale the drop's
/// edge reaches `1 + depth_gain` times as far across the pane.
pub const depth_gain: f32 = 1.5;

/// Physical pixels the drop's curve fades over by a factor of e, at `look`: `falloff`, deepened
/// past the middle of the refraction setting (`depth_gain`).
pub fn depthPx(look: Look, scale: f32) f32 {
    return falloff * scale * (1 + depth_gain * std.math.clamp(look.refraction - 1, 0, 1));
}

/// Physical pixels a caller should capture beyond a pane for it to refract, at `look`.
pub fn margin(look: Look, scale: f32) f32 {
    if (!bends(look)) return 0;
    return @ceil(refraction * scale * look.lens * look.refraction) + 2;
}
/// How much of the unblurred picture the rim shows at its very edge, 0…1: glass is clearer
/// where it is thin and steep, frosted across its face.
pub const clarity: f32 = 0.75;

/// A pane's corner radii in physical pixels, in the order its rings run: top-left, bottom-left,
/// bottom-right, top-right. Per corner, so a pane can be square where it meets another and
/// round where it does not (a drop zone splitting from a solid pane).
pub const Radii = [4]f32;

pub fn uniform(radius: f32) Radii {
    return @splat(radius);
}

/// How one pane of glass looks.
pub const Look = struct {
    /// 0…1: the drop's refraction and light.
    lens: f32 = 1,
    /// How far the drop refracts, times `refraction`: the user's dialog refraction setting,
    /// 0 (none) to 2.
    refraction: f32 = 1,
    /// The same picture before it was blurred, covering the same bounds, when there is one
    /// (`BlurBackdrop.sharpTexture`): what the clearer rim shows (`clarity`).
    sharp: ?dvui.Texture = null,
    /// Switches `tex` between blending over what is under it (true) and its own blend (false)
    /// — `BlurBackdrop.blendOver`. A frost *replaces* what it covers, which is right across its
    /// face and wrong at its edge: the edge's one-pixel fade has to blend onto what is behind,
    /// or it cuts a notch out of it and the curve shows its pixels. Null draws the edge in the
    /// texture's own blend.
    blend_over: ?*const fn (tex: dvui.Texture, over: bool) void = null,
};

/// A white that adds, for `drawLift`: `tex`, tiled one texel to every screen pixel over `tile`
/// pixels when it is a dither pattern (its uv follows the screen, so the pattern holds still as a
/// pane moves), and the `gain` that brings its mean back to white.
pub const Light = struct {
    tex: dvui.Texture,
    gain: f32 = 1,
    /// Screen pixels the texture repeats over; 0 for a plain white, sampled anywhere.
    tile: f32 = 0,

    fn uv(self: Light, p: dvui.Point.Physical) @Vector(2, f32) {
        if (self.tile <= 0) return .{ 0.5, 0.5 };
        return .{ p.x / self.tile, p.y / self.tile };
    }
};

/// How much of the rim's geometry a pane `r` has room for, its curve `depth_px` deep (`depthPx`):
/// all of it once its shorter half is `room` depths across — the curve has flattened into the
/// face by then — and on anything smaller that fraction, by which the curve, its reach and its
/// corners all shrink together (`rimScale`). Its strength is untouched: a tooltip refracts, clears
/// and catches the light at its edge as a dialog does, over a rim its own size.
pub fn fit(r: dvui.Rect.Physical, depth_px: f32) f32 {
    if (depth_px <= 0) return 1;
    return std.math.clamp(@min(r.w, r.h) / 2 / (room * depth_px), 0, 1);
}
/// Depths of the curve a pane's shorter half needs before its rim is drawn whole.
pub const room: f32 = 3;

/// The scale to draw a pane's rim at — `scale`, less what `fit` takes off for a pane too small
/// for the whole of it. Lines (the rim's light, the anti-aliased edge) keep `scale`.
pub fn rimScale(r: dvui.Rect.Physical, scale: f32, depth_px: f32) f32 {
    return scale * fit(r, depth_px);
}

/// Whether `look` bends anything at all — when it does not, a flat textured rect is the same
/// picture for a fraction of the work.
pub fn bends(look: Look) bool {
    return look.lens > 0.001;
}

/// How many rings a pane's curve is drawn with.
const ring_count = 10;

/// Where the rings of a pane sit, in physical pixels from the rim: each one a step of the same
/// size down the drop's steepness (`e^(-s/falloff)` from 1 toward 0), which puts them close at
/// the rim and further apart as it flattens — geometrically. The glass is straight lines between
/// rings, and the eye finds every kink in a gradient's slope as a band; spaced by fixed fractions
/// the rim got a few big kinks, contours round the pane, and the flat face rings it did not need.
/// The last ring sits well into the flat, where a fan to the centre takes over. Never past `cap`,
/// the most a small pane has room for.
fn ringInsets(buf: *[ring_count + 1]f32, l: f32, cap: f32) []const f32 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < ring_count) : (i += 1) {
        const k = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(ring_count));
        const d = @max(aa_in, -l * @log(1 - k));
        if (d >= cap) break;
        buf[n] = d;
        n += 1;
    }
    const last = @min(cap, buf[n - 1] + l);
    if (last > buf[n - 1] + 0.5) {
        buf[n] = last;
        n += 1;
    }
    return buf[0..n];
}
/// The light on a drop's rim (times the caller's `amount`, which carries the refraction setting).
/// Not a soft band across the curve: a thin line on the border itself, where the edge of the
/// glass catches it — brightest where the border faces along the light's diagonal, at the top
/// left, a little less at the bottom right where it shines through and off the far side, and a
/// faint line all the way round. A trace of a broad glow stays across the curve.
const line_diagonal: f32 = 0.45;
const line_far: f32 = 0.75;
const line_base: f32 = 0.06;
const broad_glow: f32 = 0.04;
/// Points: how quickly the rim line fades inward — about a point wide.
const line_width: f32 = 0.8;

/// Segments in a corner's arc, for a pane with corner radii `radii` (physical): the fewest that
/// keep every segment within `arc_tolerance` of the true arc — a quarter pixel, under what the
/// edge's own anti-aliasing spreads over, so no corner reads as a polygon at any size. A segment
/// per few pixels of curve, the rule before, was twice the vertices on a large circle for nothing
/// the eye could see, and every vertex is work each frame the glass is drawn.
fn arcSteps(radii: Radii) usize {
    var r: f32 = 0;
    for (radii) |v| r = @max(r, v);
    if (r <= arc_tolerance) return 3;
    // A chord of angle θ strays r·(1 − cos θ/2) from its arc.
    const theta = 2 * std.math.acos(1 - arc_tolerance / r);
    return @intFromFloat(std.math.clamp(@ceil((std.math.pi / 2.0) / theta), 3, 32));
}
/// Physical pixels a corner's segment may stray from the true arc.
const arc_tolerance: f32 = 0.25;

/// Physical pixels: the edge fades from solid to clear across one pixel, half inside the outline
/// and half outside — dvui's own anti-aliasing of a rounded fill (`Path.fillConvexTriangles`,
/// `fade = 1`), so glass has the same smooth edge every other rounded surface has, at any scale.
const aa_in: f32 = 0.5;
const aa_out: f32 = 0.5;

/// The drop at a point: which way is out (a smooth blend of the sides' normals, shorter near a
/// corner where two share it), and how steep it is there (1 at the rim, fading inward).
pub const Field = struct {
    out: dvui.Point.Physical,
    steep: f32,
};

/// The drop's field at `p` in pane `r`, its curve `depth_px` deep (`depthPx`): a soft minimum of the distances to its four sides —
/// `-k·ln Σ e^(-dᵢ/k)` — so the corners are round and the gradient never turns sharply.
pub fn fieldAt(p: dvui.Point.Physical, r: dvui.Rect.Physical, scale: f32, depth_px: f32) Field {
    const k = softness * scale;
    const d = [4]f32{ p.x - r.x, r.x + r.w - p.x, p.y - r.y, r.y + r.h - p.y };
    const m = @min(@min(d[0], d[1]), @min(d[2], d[3]));
    var w: [4]f32 = undefined;
    var sum: f32 = 0;
    for (d, 0..) |di, i| {
        // Relative to the nearest side, so the exponentials never underflow deep inside.
        w[i] = @exp(-(di - m) / k);
        sum += w[i];
    }
    const soft = m - k * @log(sum);
    return .{
        .out = .{ .x = (w[1] - w[0]) / sum, .y = (w[3] - w[2]) / sum },
        .steep = @exp(-@max(0, soft) / depth_px),
    };
}

/// Lay `tex` — a picture of `tex_bounds` — down over `r` with corner radii `radii`, every vertex
/// coloured `mod` (the frost half of a frost/tint mix), bent through the drop per `look`. Rings
/// of vertices through its curve and a fan over the flat middle: a pane is its corners' arcs times
/// a handful of rings, whatever its size.
pub fn drawPane(tex: dvui.Texture, tex_bounds: dvui.Rect.Physical, r: dvui.Rect.Physical, radii: Radii, scale: f32, mod: dvui.Color, look: Look) void {
    const half = @min(r.w, r.h) / 2;
    if (half < 1 or tex_bounds.w < 1 or tex_bounds.h < 1) return;
    // The rim, fitted to the pane (`fit`).
    const rim = rimScale(r, scale, depthPx(look, scale));
    const depth = depthPx(look, rim);
    var insets_buf: [ring_count + 1]f32 = undefined;
    const insets = ringInsets(&insets_buf, depth, half * 0.9);
    const arc_steps = arcSteps(radii);
    const per_ring = 4 * (arc_steps + 1);
    const arena = dvui.currentWindow().arena();
    const col = dvui.Color.PMA.fromColor(mod);
    const clear = dvui.Color.PMA.fromColor(.transparent);
    const pts = arena.alloc(dvui.Point.Physical, per_ring) catch return;
    const reach_px = refraction * rim * look.lens * look.refraction;

    // The face: the rings through the curve, from half a pixel inside the outline, and a fan
    // over the flat middle — in the texture's own blend.
    const key = paneKey(r, radii, scale, mod, look, tex_bounds);
    if (cachedMesh(key ^ 1)) |tris| {
        dvui.renderTriangles(tris, tex) catch {};
    } else {
        const rings = insets.len;
        const vtx_count = per_ring * rings + 1;
        var b = dvui.Triangles.Builder.init(arena, vtx_count, per_ring * 6 * (rings - 1) + per_ring * 3) catch return;
        defer b.deinit(arena);
        for (insets) |d| {
            ringPoints(pts, null, r, radii, d, arc_steps, 1, 1);
            for (pts) |p| b.appendVertex(.{ .pos = p, .col = col, .uv = seen(p, r, rim, depth, reach_px, tex_bounds) });
        }
        const c = r.center();
        b.appendVertex(.{ .pos = c, .col = col, .uv = seen(c, r, rim, depth, reach_px, tex_bounds) });
        appendRingStrips(&b, per_ring, rings);
        appendFan(&b, per_ring, rings - 1, vtx_count - 1);
        const tris = b.build_unowned();
        keepMesh(key ^ 1, tris);
        dvui.renderTriangles(tris, tex) catch {};
    }

    // The edge: solid half a pixel inside the outline to clear half a pixel outside it
    // (`aa_in`, `aa_out`, as dvui fades a rounded fill), blended over what is behind.
    {
        if (look.blend_over) |set| set(tex, true);
        defer if (look.blend_over) |set| set(tex, false);
        if (cachedMesh(key ^ 2)) |tris| {
            dvui.renderTriangles(tris, tex) catch {};
        } else {
            var b = dvui.Triangles.Builder.init(arena, per_ring * 2, per_ring * 6) catch return;
            defer b.deinit(arena);
            ringPoints(pts, null, r, radii, -aa_out, arc_steps, 1, 1);
            for (pts) |p| b.appendVertex(.{ .pos = p, .col = clear, .uv = seen(p, r, rim, depth, reach_px, tex_bounds) });
            ringPoints(pts, null, r, radii, aa_in, arc_steps, 1, 1);
            for (pts) |p| b.appendVertex(.{ .pos = p, .col = col, .uv = seen(p, r, rim, depth, reach_px, tex_bounds) });
            appendRingStrips(&b, per_ring, 2);
            const tris = b.build_unowned();
            keepMesh(key ^ 2, tris);
            dvui.renderTriangles(tris, tex) catch {};
        }
    }

    if (look.sharp) |sharp| drawClear(sharp, tex_bounds, r, radii, rim, mod, look, insets, key ^ 3);
}

/// The rim's clearer glass: the unblurred picture over the frost, bent the same way, as much of
/// it as `clarity` times the drop's steepness — sharpest at the very edge, gone where the face
/// is flat. Drawn at the frost's weight (`mod`), so it takes the pane's tint and lift afterwards
/// like the frost does. `rim` is the pane's rim scale (`rimScale`).
fn drawClear(sharp: dvui.Texture, tex_bounds: dvui.Rect.Physical, r: dvui.Rect.Physical, radii: Radii, rim: f32, mod: dvui.Color, look: Look, insets: []const f32, key: u64) void {
    if (cachedMesh(key)) |tris| {
        dvui.renderTriangles(tris, sharp) catch {};
        return;
    }
    // With the refraction setting, up to as designed: a flat edge is a clear one no more.
    const amount = clarity * look.lens * @min(1, look.refraction) * @as(f32, @floatFromInt(mod.a)) / 255;
    if (amount <= 0.01) return;
    const arc_steps = arcSteps(radii);
    const per_ring = 4 * (arc_steps + 1);
    const arena = dvui.currentWindow().arena();
    // Only as far in as the clear glass shows: it fades with the steepness squared, so past about
    // two falloffs there is nothing of it left to draw.
    const depth = depthPx(look, rim);
    const reach_in = depth * 2.2;
    var rings: usize = 0;
    while (rings < insets.len and (rings < 2 or insets[rings - 1] <= reach_in)) rings += 1;
    const used = insets[0..rings];
    var b = dvui.Triangles.Builder.init(arena, per_ring * (rings + 1), per_ring * 6 * rings) catch return;
    defer b.deinit(arena);
    const pts = arena.alloc(dvui.Point.Physical, per_ring) catch return;
    const clear = dvui.Color.PMA.fromColor(.transparent);
    const reach_px = refraction * rim * look.lens * look.refraction;
    ringPoints(pts, null, r, radii, -aa_out, arc_steps, 1, 1);
    for (pts) |p| b.appendVertex(.{ .pos = p, .col = clear, .uv = seen(p, r, rim, depth, reach_px, tex_bounds) });
    for (used) |d| {
        ringPoints(pts, null, r, radii, d, arc_steps, 1, 1);
        for (pts) |p| {
            const steep = fieldAt(p, r, rim, depth).steep;
            // Squared, so the clear glass hugs the edge and the face stays frosted.
            const col = dvui.Color.PMA.fromColor(dvui.Color.white.opacity(amount * steep * steep));
            b.appendVertex(.{ .pos = p, .col = col, .uv = seen(p, r, rim, depth, reach_px, tex_bounds) });
        }
    }
    appendRingStrips(&b, per_ring, rings + 1);
    const tris = b.build_unowned();
    keepMesh(key, tris);
    dvui.renderTriangles(tris, sharp) catch {};
}

/// Where the glass at `p` shows: further out, along the drop's outward direction, by as much of
/// `reach_px` as the drop is steep there.
fn seen(p: dvui.Point.Physical, r: dvui.Rect.Physical, scale: f32, depth: f32, reach_px: f32, bd: dvui.Rect.Physical) @Vector(2, f32) {
    const f = fieldAt(p, r, scale, depth);
    const reach = reach_px * f.steep;
    const q: dvui.Point.Physical = .{ .x = p.x + f.out.x * reach, .y = p.y + f.out.y * reach };
    return .{
        std.math.clamp((q.x - bd.x) / bd.w, 0, 1),
        std.math.clamp((q.y - bd.y) / bd.h, 0, 1),
    };
}

/// The white a pane of glass adds over its tint — its `lift`, the whole pane — and the light its
/// rim catches on top: a thin line on the border, brightest at the top left and bottom right,
/// `amount` of it. One pass for both. `light` is a white texture that adds
/// (`BlurBackdrop.additiveLight`, dithered); draw this after the tint, so it stays white.
pub fn drawLift(light: Light, r: dvui.Rect.Physical, radii: Radii, scale: f32, lift_in: f32, amount_in: f32) void {
    // The texture sits a little under white on average; `gain` puts the mean back.
    const lift = lift_in * light.gain;
    const amount = amount_in * light.gain;
    if (lift <= 0.002 and amount <= 0.01) return;
    const half = @min(r.w, r.h) / 2;
    if (half < 1) return;
    const key = numbersKey(4, &.{ r.x, r.y, r.w, r.h, radii[0], radii[1], radii[2], radii[3], scale, lift, amount, light.gain, light.tile });
    if (cachedMesh(key)) |tris| {
        dvui.renderTriangles(tris, light.tex) catch {};
        return;
    }
    // The rim line needs rings of its own, a fraction of a point apart, before the curve's. The
    // line is a line at any size; the glow across the curve fits the pane (`fit`).
    var curve_buf: [ring_count + 1]f32 = undefined;
    const rim = rimScale(r, scale, falloff * scale);
    const depth = falloff * rim;
    const curve = ringInsets(&curve_buf, depth, half * 0.9);
    var insets_buf: [ring_count + 6]f32 = undefined;
    var n_insets: usize = 0;
    for ([_]f32{ 0, 0.5, 1.0, 1.6, 2.5 }) |pt| {
        const d = @max(aa_in, pt * scale);
        if (d >= half * 0.9) break;
        if (n_insets > 0 and d <= insets_buf[n_insets - 1] + 0.25) continue;
        insets_buf[n_insets] = d;
        n_insets += 1;
    }
    for (curve) |d| {
        if (d <= insets_buf[n_insets - 1] + 0.25) continue;
        // Past about two falloffs the broad glow is gone and the lift is flat: the fan does.
        if (d > depth * 2) break;
        insets_buf[n_insets] = d;
        n_insets += 1;
    }
    const insets = insets_buf[0..n_insets];
    const arc_steps = arcSteps(radii);
    const per_ring = 4 * (arc_steps + 1);
    const arena = dvui.currentWindow().arena();
    const rings = insets.len;
    const vtx_count = per_ring * (rings + 1) + 1;
    var b = dvui.Triangles.Builder.init(arena, vtx_count, per_ring * 6 * rings + per_ring * 3) catch return;
    defer b.deinit(arena);
    const pts = arena.alloc(dvui.Point.Physical, per_ring) catch return;
    const clear = dvui.Color.PMA.fromColor(.transparent);
    ringPoints(pts, null, r, radii, -aa_out, arc_steps, 1, 1);
    for (pts) |p| b.appendVertex(.{ .pos = p, .col = clear, .uv = light.uv(p) });
    // Along the diagonal from the top left, as a window's light usually is.
    const lx: f32 = -std.math.sqrt1_2;
    const ly: f32 = -std.math.sqrt1_2;
    for (insets) |d| {
        ringPoints(pts, null, r, radii, d, arc_steps, 1, 1);
        const line = @exp(-d / (line_width * scale));
        for (pts) |p| {
            const f = fieldAt(p, r, rim, depth);
            const facing = f.out.x * lx + f.out.y * ly;
            const toward = @max(0, facing);
            const away = @max(0, -facing);
            const spec = line_diagonal * (toward * @sqrt(toward) + line_far * away * @sqrt(away)) + line_base;
            const lit = line * spec + broad_glow * f.steep * toward;
            const col = dvui.Color.PMA.fromColor(dvui.Color.white.opacity(std.math.clamp(lift + amount * lit, 0, 1)));
            b.appendVertex(.{ .pos = p, .col = col, .uv = light.uv(p) });
        }
    }
    b.appendVertex(.{ .pos = r.center(), .col = dvui.Color.PMA.fromColor(dvui.Color.white.opacity(std.math.clamp(lift, 0, 1))), .uv = light.uv(r.center()) });
    appendRingStrips(&b, per_ring, rings + 1);
    appendFan(&b, per_ring, rings, vtx_count - 1);
    const tris = b.build_unowned();
    keepMesh(key, tris);
    dvui.renderTriangles(tris, light.tex) catch {};
}

// ── Meshes kept between frames ───────────────────────────────────────────────────────────────────
//
// A pane's meshes are the same frame after frame while it holds still — a dialog, a menu, the
// drop's bubbles once they have parted — and building them is most of what glass costs: the
// field and the refraction worked out at every vertex of every ring. So each is kept, keyed by
// every number it is built from, in dvui's data store, which lets go of it the first frame it is
// not asked for. A pane that moves builds anew each frame, as it always did.

/// A key for a mesh built from `numbers`, `tag` telling apart the meshes built from the same
/// ones. The numbers themselves, not a struct's bytes, whose padding is anything.
fn numbersKey(tag: u64, numbers: []const f32) u64 {
    var h = std.hash.Wyhash.init(tag);
    h.update(std.mem.sliceAsBytes(numbers));
    return h.final();
}

fn paneKey(r: dvui.Rect.Physical, radii: Radii, scale: f32, mod: dvui.Color, look: Look, tb: dvui.Rect.Physical) u64 {
    return numbersKey(0x91a55, &.{
        r.x,                  r.y,                  r.w,                  r.h,
        radii[0],             radii[1],             radii[2],             radii[3],
        scale,                @floatFromInt(mod.r), @floatFromInt(mod.g), @floatFromInt(mod.b),
        @floatFromInt(mod.a), look.lens,            look.refraction,      tb.x,
        tb.y,                 tb.w,                 tb.h,
    }) & ~@as(u64, 3);
}

fn meshId(key: u64) dvui.Id {
    return @enumFromInt(key);
}

fn cachedMesh(key: u64) ?dvui.Triangles {
    const id = meshId(key);
    const v = dvui.dataGetSlice(null, id, "_glass_v", []dvui.Vertex) orelse return null;
    const i = dvui.dataGetSlice(null, id, "_glass_i", []dvui.Vertex.Index) orelse return null;
    const bounds = dvui.dataGet(null, id, "_glass_b", dvui.Rect.Physical) orelse return null;
    return .{ .vertexes = v, .indices = i, .bounds = bounds };
}

fn keepMesh(key: u64, tris: dvui.Triangles) void {
    const id = meshId(key);
    dvui.dataSetSlice(null, id, "_glass_v", tris.vertexes);
    dvui.dataSetSlice(null, id, "_glass_i", tris.indices);
    dvui.dataSet(null, id, "_glass_b", tris.bounds);
}

/// A pane's drop shadow as a ring round it: from its outline — `radii` at every step, grown with
/// the ring — fading outward over `fade_px`, the outer part shifted by `offset` so it falls the
/// way a shadow falls. Nothing inside the outline: a box shadow is a faded rect that covers the
/// pane's interior too, and glass laid over it blurs it in — a darker middle and a halo round the
/// edges. Draw it *after* the glass, which then never sees it.
pub fn drawShadow(r: dvui.Rect.Physical, radii: Radii, fade_px: f32, offset: dvui.Point.Physical, color: dvui.Color, alpha: f32) void {
    if (alpha <= 0.002 or fade_px < 0.5 or r.w < 1 or r.h < 1) return;
    const steps = [_]f32{ 0, 0.12, 0.28, 0.48, 0.72, 1.0 };
    const arc_steps = arcSteps(.{ radii[0] + fade_px, radii[1] + fade_px, radii[2] + fade_px, radii[3] + fade_px });
    const per_ring = 4 * (arc_steps + 1);
    const arena = dvui.currentWindow().arena();
    var b = dvui.Triangles.Builder.init(arena, per_ring * steps.len, per_ring * 6 * (steps.len - 1)) catch return;
    defer b.deinit(arena);
    const pts = arena.alloc(dvui.Point.Physical, per_ring) catch return;
    for (steps) |x| {
        const out = x * fade_px;
        const grown: Radii = .{ radii[0] + out, radii[1] + out, radii[2] + out, radii[3] + out };
        ringPoints(pts, null, r, grown, -out, arc_steps, 1, 1);
        const fall = 1 - x;
        const col = dvui.Color.PMA.fromColor(color.opacity(alpha * fall * fall));
        for (pts) |p| b.appendVertex(.{ .pos = .{ .x = p.x + offset.x * x, .y = p.y + offset.y * x }, .col = col });
    }
    appendRingStrips(&b, per_ring, steps.len);
    dvui.renderTriangles(b.build_unowned(), null) catch {};
}

/// Quads between `count` neighbouring rings of `per_ring` vertices each, laid down one after
/// another from the outermost, wound the way dvui winds a path's fill.
fn appendRingStrips(b: *dvui.Triangles.Builder, per_ring: usize, count: usize) void {
    const n: dvui.Vertex.Index = @intCast(per_ring);
    var k: usize = 0;
    while (k + 1 < count) : (k += 1) {
        const outer: dvui.Vertex.Index = @intCast(k * per_ring);
        const inner: dvui.Vertex.Index = @intCast((k + 1) * per_ring);
        var i: dvui.Vertex.Index = 0;
        while (i < n) : (i += 1) {
            const j = (i + 1) % n;
            b.appendTriangles(&.{ outer + i, outer + j, inner + i, outer + j, inner + j, inner + i });
        }
    }
}

/// A fan from the vertex at `center` to the innermost ring, ring number `ring` counting the
/// fringe as ring 0.
fn appendFan(b: *dvui.Triangles.Builder, per_ring: usize, ring: usize, center: usize) void {
    const n: dvui.Vertex.Index = @intCast(per_ring);
    const last: dvui.Vertex.Index = @intCast(ring * per_ring);
    const c: dvui.Vertex.Index = @intCast(center);
    var i: dvui.Vertex.Index = 0;
    while (i < n) : (i += 1) b.appendTriangles(&.{ c, last + i, last + (i + 1) % n });
}

/// The points of one ring: `r` pushed in by `d` (out, when negative) with corner radii `radii` —
/// the ring's own, so every ring of a pane keeps its corners round — from the top-left corner
/// down the left side, along the bottom, up the right and back along the top: the order dvui's
/// own paths run (`Path.Builder.addRect`). `normals`, when given, gets each point's outward unit
/// normal: straight out from its corner's centre on an arc, square to its side on a side.
pub fn ringPoints(out: []dvui.Point.Physical, normals: ?[]dvui.Point.Physical, r: dvui.Rect.Physical, radii: Radii, d: f32, steps_per_arc: usize, side_x: usize, side_y: usize) void {
    const x0 = r.x + d;
    const y0 = r.y + d;
    const x1 = r.x + r.w - d;
    const y1 = r.y + r.h - d;
    const max_rad = @max(0.01, @min(x1 - x0, y1 - y0) / 2);
    var rad: [4]f32 = undefined;
    for (radii, 0..) |v, i| rad[i] = std.math.clamp(v, 0.01, max_rad);
    const pi = std.math.pi;
    var n: usize = 0;
    const Corner = struct { cx: f32, cy: f32, a0: f32, a1: f32, rad: f32 };
    const corners = [_]Corner{
        .{ .cx = x0 + rad[0], .cy = y0 + rad[0], .a0 = 1.5 * pi, .a1 = pi, .rad = rad[0] },
        .{ .cx = x0 + rad[1], .cy = y1 - rad[1], .a0 = pi, .a1 = 0.5 * pi, .rad = rad[1] },
        .{ .cx = x1 - rad[2], .cy = y1 - rad[2], .a0 = 0.5 * pi, .a1 = 0, .rad = rad[2] },
        .{ .cx = x1 - rad[3], .cy = y0 + rad[3], .a0 = 2 * pi, .a1 = 1.5 * pi, .rad = rad[3] },
    };
    // The outward normal of the straight run after each corner: left, bottom, right, top.
    const side_normals = [_]dvui.Point.Physical{ .{ .x = -1 }, .{ .y = 1 }, .{ .x = 1 }, .{ .y = -1 } };
    for (corners, 0..) |c, ci| {
        var k: usize = 0;
        while (k <= steps_per_arc) : (k += 1) {
            const t = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(steps_per_arc));
            const a = c.a0 + (c.a1 - c.a0) * t;
            out[n] = .{ .x = c.cx + c.rad * @cos(a), .y = c.cy + c.rad * @sin(a) };
            if (normals) |ns| ns[n] = .{ .x = @cos(a), .y = @sin(a) };
            n += 1;
        }
        // The straight run to the next corner, cut into steps.
        const next = corners[(ci + 1) % corners.len];
        const from = out[n - 1];
        const to: dvui.Point.Physical = .{ .x = next.cx + next.rad * @cos(next.a0), .y = next.cy + next.rad * @sin(next.a0) };
        const steps = if (ci % 2 == 0) side_y else side_x;
        var k2: usize = 1;
        while (k2 < steps) : (k2 += 1) {
            const t = @as(f32, @floatFromInt(k2)) / @as(f32, @floatFromInt(steps));
            out[n] = .{ .x = from.x + (to.x - from.x) * t, .y = from.y + (to.y - from.y) * t };
            if (normals) |ns| ns[n] = side_normals[ci];
            n += 1;
        }
    }
    std.debug.assert(n == out.len);
}
