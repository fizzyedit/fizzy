//! Liquid glass in the shape of a few discs run together — a drop, or a drop splitting.
//!
//! `core.liquid_glass` bends a picture through panes: rounded rects, meshed as rings. This is
//! the same glass for a shape no ring can follow: the *smooth union* of some discs, the field
//! `-k·ln Σ e^(-dᵢ/k)` over each disc's signed distance `dᵢ`. Discs far apart are just discs;
//! close together the field bridges them, and as they part the bridge thins to a neck and lets
//! go — one drop becoming several, the way water does. `k` is how far the bridging reaches.
//!
//! **How it is drawn.** The field is sampled on a grid over the discs and meshed by marching
//! squares: a cell wholly inside is a quad, a cell the edge crosses is the part of it inside,
//! and every piece of the edge gets a one-pixel fringe outward along the field's gradient, as
//! dvui fades a rounded fill. The frost is laid down on that mesh through the refraction the
//! panes have — the rim shows what lies just beyond it, pulled in — then the tint, then the
//! lift with a thin rim of light. What each disc is (lit, for one) blends across the union by
//! each disc's share of the field at a point, so the light on one bubble runs into the neck to
//! its neighbour rather than stopping at a seam.
const std = @import("std");
const dvui = @import("dvui");
const liquid_glass = @import("liquid_glass.zig");

pub const Disc = struct {
    c: dvui.Point.Physical,
    r: f32,
    /// 0…1: how lit — the bubble under the pointer.
    lit: f32 = 0,
};

/// The field at a point: signed distance to the union's edge (negative inside), the unit
/// direction out of it, and how lit the discs make it there.
pub const Sample = struct {
    d: f32,
    out: dvui.Point.Physical,
    lit: f32,
};

/// The smooth union of `discs`, bridging over `k` physical pixels, at `p`: the nearest disc's
/// distance, less a polynomial bridge `(k − δ)²/4k` for every other disc within `k` of it (δ how
/// much further it is) — with two discs, exactly the polynomial smooth minimum.
///
/// Every disc near enough, and none favoured, so the edge has no seam and no lean. Blending only
/// the two nearest flipped which disc counted wherever three came close — at the neck between a
/// drop and two of its bubbles — and the direction out of the edge (its fringe, rim light and
/// refraction) jumped there, drawn as a stair; folding them all in one order was smooth but
/// leaned toward the first. Polynomial, not the exponential soft minimum, which swells by
/// `k·ln n` wherever they overlap.
pub fn field(discs: []const Disc, k: f32, p: dvui.Point.Physical) Sample {
    var ds: [max_discs]f32 = undefined;
    var ns: [max_discs]dvui.Point.Physical = undefined;
    const count = @min(discs.len, max_discs);
    var near: usize = 0;
    for (discs[0..count], 0..) |dc, i| {
        const dx = p.x - dc.c.x;
        const dy = p.y - dc.c.y;
        const len = @sqrt(dx * dx + dy * dy);
        ds[i] = len - dc.r;
        ns[i] = if (len > 1e-4) .{ .x = dx / len, .y = dy / len } else .{ .x = 0, .y = -1 };
        if (ds[i] < ds[near]) near = i;
    }
    if (count == 0) return .{ .d = std.math.floatMax(f32), .out = .{ .x = 0, .y = -1 }, .lit = 0 };
    var d = ds[near];
    var gx = ns[near].x;
    var gy = ns[near].y;
    var lit = discs[near].lit;
    for (0..count) |i| {
        if (i == near) continue;
        const delta = ds[i] - ds[near];
        if (delta >= k) continue;
        const reach = k - delta;
        d -= reach * reach / (4 * k);
        // The bridge's pull on the gradient and on what the discs are: (k − δ)/2k of the way
        // from the nearest toward this one — a half each where the two are level.
        const w = reach / (2 * k);
        gx += w * (ns[i].x - ns[near].x);
        gy += w * (ns[i].y - ns[near].y);
        lit += w * (discs[i].lit - discs[near].lit);
    }
    const glen = @sqrt(gx * gx + gy * gy);
    return .{
        .d = d,
        .out = if (glen > 1e-5) .{ .x = gx / glen, .y = gy / glen } else ns[near],
        .lit = std.math.clamp(lit, 0, 1),
    };
}

/// The most discs one union takes: the drop zones' six.
pub const max_discs = 8;

/// The most the union of `n` discs reaches past them, for `k`: `k/4` for each disc over the
/// first, all on top of one another.
fn swell(k: f32, n: usize) f32 {
    return @as(f32, @floatFromInt(n -| 1)) * k / 4;
}

/// How the glass looks, as `liquid_glass.Look` plus what a pane's frost job composes over it.
pub const Look = struct {
    /// 0…1: the rim's refraction and light (`core.motion.liquid`, and how formed the glass is).
    lens: f32 = 1,
    /// The dialogs' refraction setting, 0…2.
    refraction: f32 = 1,
    /// The frost's own weight (`1 - mix` under a tint).
    frost: dvui.Color = .white,
    tint: ?dvui.Color = null,
    mix: f32 = 0,
    /// White over the whole shape, 0…1.
    lift: f32 = 0,
    /// How much a lit part changes, and toward what (lighter on a dark theme, darker on a light).
    lit_amount: f32 = 0.1,
    lit_toward: dvui.Color = .white,
    /// 0…1: how strong the whole thing is — the glass forming.
    strength: f32 = 1,
    blend_over: ?*const fn (dvui.Texture, bool) void = null,
};

/// Points a grid cell is: fine enough that the edge between the fringe's samples reads as a
/// curve, even round the tight bend of a neck — at 4 the neck between a drop and a bubble it was
/// letting go of showed its straight pieces as stairs. The mesh is drawn only while bubbles are
/// joined, a fraction of a second at a time.
const cell_points: f32 = 2.5;

const Vert = struct {
    p: dvui.Point.Physical,
    s: Sample,
    /// 1 inside, fading to 0 across the fringe.
    a: f32,
};

/// Lay the frost `tex` — a picture of `tex_bounds` — down in the shape of `discs` smoothly
/// united over `k` (physical), bent and lit per `look`. Call from where the frost is drawn
/// (a deferred job, once what is under it is on the frame), at full alpha.
pub fn draw(tex: dvui.Texture, tex_bounds: dvui.Rect.Physical, discs: []const Disc, k: f32, scale: f32, look: Look) void {
    if (discs.len == 0 or tex_bounds.w < 1 or tex_bounds.h < 1) return;
    const arena = dvui.currentWindow().arena();
    var mesh = build(arena, discs, @max(k, 0.5), scale) orelse return;
    defer mesh.deinit(arena);
    if (mesh.inner.items.len == 0) return;

    const depth = liquid_glass.falloff * scale * (1 + liquid_glass.depth_gain * std.math.clamp(look.refraction - 1, 0, 1));
    const reach_px = liquid_glass.refraction * scale * look.lens * look.refraction;

    // The frost: inside in its own blend (it replaces what it covers, as every frost does), the
    // fringe blended over what is behind so the edge is smooth.
    {
        const frost = dvui.Color.PMA.fromColor(look.frost);
        var b = dvui.Triangles.Builder.init(arena, mesh.verts.items.len, mesh.inner.items.len) catch return;
        defer b.deinit(arena);
        for (mesh.verts.items) |v| b.appendVertex(.{ .pos = v.p, .col = frost, .uv = seen(v, depth, reach_px, tex_bounds) });
        b.appendTriangles(mesh.inner.items);
        dvui.renderTriangles(b.build_unowned(), tex) catch {};
    }
    if (mesh.fringe.items.len > 0) {
        var b = dvui.Triangles.Builder.init(arena, mesh.verts.items.len, mesh.fringe.items.len) catch return;
        defer b.deinit(arena);
        for (mesh.verts.items) |v| b.appendVertex(.{ .pos = v.p, .col = dvui.Color.PMA.fromColor(look.frost.opacity(v.a)), .uv = seen(v, depth, reach_px, tex_bounds) });
        b.appendTriangles(mesh.fringe.items);
        if (look.blend_over) |set| set(tex, true);
        dvui.renderTriangles(b.build_unowned(), tex) catch {};
        if (look.blend_over) |set| set(tex, false);
    }

    // The tint over it, as a pane's frost composes one.
    if (look.tint) |tint| {
        const mix = std.math.clamp(look.mix, 0, 1);
        paint(arena, &mesh, struct {
            fn color(v: Vert, ctx: ColorCtx) dvui.Color {
                return ctx.c.opacity(@as(f32, @floatFromInt(ctx.c.a)) / 255 * ctx.x * v.a);
            }
        }.color, .{ .c = tint, .x = mix });
    }

    // The lift, the rim's thin line of light (brightest facing the top left, as the panes'), and
    // a lit bubble lightening — in one white pass; a light theme's lit bubble darkens instead.
    const Rim = struct {
        fn color(v: Vert, ctx: ColorCtx) dvui.Color {
            const facing = std.math.clamp(-(v.s.out.x + v.s.out.y) * std.math.sqrt1_2, 0, 1);
            const line = @exp(-@abs(@min(v.s.d, 0)) / ctx.y) * (0.06 + 0.4 * facing);
            const lit_up: f32 = if (ctx.dark) ctx.w * v.s.lit else 0;
            return dvui.Color.white.opacity(std.math.clamp((ctx.x + ctx.z * line + lit_up) * v.a, 0, 1));
        }
    };
    const dark = look.lit_toward.r > 127;
    paint(arena, &mesh, Rim.color, .{ .c = .white, .x = look.lift * look.strength, .y = 0.9 * scale, .z = look.lens * look.strength, .w = look.lit_amount * look.strength, .dark = dark });
    if (!dark) paint(arena, &mesh, struct {
        fn color(v: Vert, ctx: ColorCtx) dvui.Color {
            return dvui.Color.black.opacity(std.math.clamp(ctx.x * v.s.lit * v.a, 0, 1));
        }
    }.color, .{ .c = .black, .x = look.lit_amount * look.strength });
}

const ColorCtx = struct { c: dvui.Color, x: f32 = 0, y: f32 = 1, z: f32 = 0, w: f32 = 0, dark: bool = false };

/// The whole shape, inside and fringe, untextured, each vertex coloured by `color`.
fn paint(arena: std.mem.Allocator, mesh: *const Mesh, comptime color: fn (Vert, ColorCtx) dvui.Color, ctx: ColorCtx) void {
    var b = dvui.Triangles.Builder.init(arena, mesh.verts.items.len, mesh.inner.items.len + mesh.fringe.items.len) catch return;
    defer b.deinit(arena);
    for (mesh.verts.items) |v| b.appendVertex(.{ .pos = v.p, .col = dvui.Color.PMA.fromColor(color(v, ctx)) });
    b.appendTriangles(mesh.inner.items);
    b.appendTriangles(mesh.fringe.items);
    dvui.renderTriangles(b.build_unowned(), null) catch {};
}

/// Where the glass at a vertex shows: further out along the field's gradient by as much of
/// `reach_px` as the drop is steep there — the panes' refraction (`liquid_glass`), on this shape.
fn seen(v: Vert, depth: f32, reach_px: f32, bd: dvui.Rect.Physical) @Vector(2, f32) {
    const steep = @exp(-@max(0, -v.s.d) / depth);
    const q: dvui.Point.Physical = .{ .x = v.p.x + v.s.out.x * reach_px * steep, .y = v.p.y + v.s.out.y * reach_px * steep };
    return .{ std.math.clamp((q.x - bd.x) / bd.w, 0, 1), std.math.clamp((q.y - bd.y) / bd.h, 0, 1) };
}

const Mesh = struct {
    verts: std.ArrayListUnmanaged(Vert) = .empty,
    inner: std.ArrayListUnmanaged(dvui.Vertex.Index) = .empty,
    fringe: std.ArrayListUnmanaged(dvui.Vertex.Index) = .empty,

    fn deinit(self: *Mesh, arena: std.mem.Allocator) void {
        self.verts.deinit(arena);
        self.inner.deinit(arena);
        self.fringe.deinit(arena);
    }
};

/// Mesh the union: marching squares over a grid covering the discs, the inside of each cell as
/// a fan, and a one-pixel fringe out from every piece of the edge.
///
/// Fine only where the edge can be. The grid is coarse — `per_coarse` cells a side — and a coarse
/// cell wholly inside is one quad, one wholly outside nothing; only one the edge might cross is
/// marched at the fine size. Fine everywhere, the drop was tens of thousands of vertices a pass,
/// several passes a frame, and a phone's frame rate went with it.
fn build(arena: std.mem.Allocator, discs: []const Disc, k: f32, scale: f32) ?Mesh {
    var lo: dvui.Point.Physical = .{ .x = std.math.floatMax(f32), .y = std.math.floatMax(f32) };
    var hi: dvui.Point.Physical = .{ .x = -std.math.floatMax(f32), .y = -std.math.floatMax(f32) };
    for (discs) |dc| {
        lo = .{ .x = @min(lo.x, dc.c.x - dc.r), .y = @min(lo.y, dc.c.y - dc.r) };
        hi = .{ .x = @max(hi.x, dc.c.x + dc.r), .y = @max(hi.y, dc.c.y + dc.r) };
    }
    // The union reaches past the discs where it bridges them (`swell`); the grid covers that.
    const pad = swell(k, discs.len) + 2 * scale;
    lo = .{ .x = lo.x - pad, .y = lo.y - pad };
    hi = .{ .x = hi.x + pad, .y = hi.y + pad };
    if (hi.x - lo.x < 1 or hi.y - lo.y < 1) return null;

    const fine = cell_points * @max(scale, 0.5);
    const coarse = fine * @as(f32, @floatFromInt(per_coarse));
    const nx: usize = @min(200, @as(usize, @intFromFloat(@ceil((hi.x - lo.x) / coarse))) + 1);
    const ny: usize = @min(200, @as(usize, @intFromFloat(@ceil((hi.y - lo.y) / coarse))) + 1);
    const grid = arena.alloc(Sample, nx * ny) catch return null;
    for (0..ny) |j| for (0..nx) |i| {
        grid[j * nx + i] = field(discs, k, .{ .x = lo.x + @as(f32, @floatFromInt(i)) * coarse, .y = lo.y + @as(f32, @floatFromInt(j)) * coarse });
    };

    // A coarse cell whose corners are all further than this from the edge has none of it: the
    // field changes by at most `lipschitz` a pixel, so across the cell's diagonal by less.
    const clear = coarse * std.math.sqrt2 * lipschitz;
    var mesh: Mesh = .{};
    var local: [(per_coarse + 1) * (per_coarse + 1)]Sample = undefined;
    for (0..ny - 1) |j| for (0..nx - 1) |i| {
        const x0 = lo.x + @as(f32, @floatFromInt(i)) * coarse;
        const y0 = lo.y + @as(f32, @floatFromInt(j)) * coarse;
        const cs = [4]Sample{ grid[j * nx + i], grid[j * nx + i + 1], grid[(j + 1) * nx + i + 1], grid[(j + 1) * nx + i] };
        var dmin: f32 = cs[0].d;
        var dmax: f32 = cs[0].d;
        for (cs[1..]) |c| {
            dmin = @min(dmin, c.d);
            dmax = @max(dmax, c.d);
        }
        if (dmin > clear) continue;
        const corners = [4]dvui.Point.Physical{
            .{ .x = x0, .y = y0 },
            .{ .x = x0 + coarse, .y = y0 },
            .{ .x = x0 + coarse, .y = y0 + coarse },
            .{ .x = x0, .y = y0 + coarse },
        };
        if (dmax < -clear) {
            if (!march(arena, &mesh, discs, k, scale, corners, cs)) return null;
            continue;
        }
        // The edge may be in here: march it at the fine size.
        const m = per_coarse + 1;
        for (0..m) |b| for (0..m) |a| {
            local[b * m + a] = field(discs, k, .{ .x = x0 + @as(f32, @floatFromInt(a)) * fine, .y = y0 + @as(f32, @floatFromInt(b)) * fine });
        };
        for (0..per_coarse) |b| for (0..per_coarse) |a| {
            const fx = x0 + @as(f32, @floatFromInt(a)) * fine;
            const fy = y0 + @as(f32, @floatFromInt(b)) * fine;
            const fc = [4]dvui.Point.Physical{
                .{ .x = fx, .y = fy },
                .{ .x = fx + fine, .y = fy },
                .{ .x = fx + fine, .y = fy + fine },
                .{ .x = fx, .y = fy + fine },
            };
            const fs = [4]Sample{ local[b * m + a], local[b * m + a + 1], local[(b + 1) * m + a + 1], local[(b + 1) * m + a] };
            if (!march(arena, &mesh, discs, k, scale, fc, fs)) return null;
        };
    };
    return mesh;
}

/// Fine cells a coarse cell is split into, a side (`build`).
const per_coarse = 4;
/// The most the field changes over a pixel: 1 for one disc, a little more where the bridges
/// between several pull the gradient past it.
const lipschitz: f32 = 1.5;

/// One cell of the marching squares: its inside as a fan, and a one-pixel fringe out from each
/// piece of the edge crossing it. False when out of memory.
fn march(arena: std.mem.Allocator, mesh: *Mesh, discs: []const Disc, k: f32, scale: f32, corners: [4]dvui.Point.Physical, cs: [4]Sample) bool {
    const d = [4]f32{ cs[0].d, cs[1].d, cs[2].d, cs[3].d };
    var inside: u8 = 0;
    for (d) |v| {
        if (v < 0) inside += 1;
    }
    if (inside == 0) return true;
    const aa = scale;
    var poly: [8]dvui.Point.Physical = undefined;
    // The inside of the cell: its corners that are in, and where its sides cross the edge.
    var n: usize = 0;
    var samples: [8]Sample = undefined;
    var cuts: [4]dvui.Point.Physical = undefined;
    var ncut: usize = 0;
    for (0..4) |c| {
        const nxt = (c + 1) % 4;
        if (d[c] < 0) {
            poly[n] = corners[c];
            // A corner's field is the grid's; only the edge's crossings need their own.
            samples[n] = cs[c];
            n += 1;
        }
        if ((d[c] < 0) != (d[nxt] < 0)) {
            const t = d[c] / (d[c] - d[nxt]);
            const p: dvui.Point.Physical = .{ .x = corners[c].x + (corners[nxt].x - corners[c].x) * t, .y = corners[c].y + (corners[nxt].y - corners[c].y) * t };
            poly[n] = p;
            samples[n] = field(discs, k, p);
            n += 1;
            if (ncut < 4) {
                cuts[ncut] = p;
                ncut += 1;
            }
        }
    }
    if (n < 3) return true;
    const base: dvui.Vertex.Index = @intCast(mesh.verts.items.len);
    for (poly[0..n], samples[0..n]) |p, smp| mesh.verts.append(arena, .{ .p = p, .s = smp, .a = 1 }) catch return false;
    var t: usize = 1;
    while (t + 1 < n) : (t += 1) {
        mesh.inner.appendSlice(arena, &.{ base, base + @as(dvui.Vertex.Index, @intCast(t)), base + @as(dvui.Vertex.Index, @intCast(t + 1)) }) catch return false;
    }
    // The fringe: each piece of the edge in this cell, pushed out a pixel along the field.
    var c: usize = 0;
    while (c + 1 < ncut) : (c += 2) {
        const a = cuts[c];
        const b = cuts[c + 1];
        const sa = field(discs, k, a);
        const sb = field(discs, k, b);
        const fb: dvui.Vertex.Index = @intCast(mesh.verts.items.len);
        mesh.verts.appendSlice(arena, &.{
            .{ .p = a, .s = sa, .a = 1 },
            .{ .p = b, .s = sb, .a = 1 },
            .{ .p = .{ .x = b.x + sb.out.x * aa, .y = b.y + sb.out.y * aa }, .s = sb, .a = 0 },
            .{ .p = .{ .x = a.x + sa.out.x * aa, .y = a.y + sa.out.y * aa }, .s = sa, .a = 0 },
        }) catch return false;
        mesh.fringe.appendSlice(arena, &.{ fb, fb + 1, fb + 2, fb, fb + 2, fb + 3 }) catch return false;
    }
    return true;
}

test "far apart the union is its discs; together it bridges them" {
    const two = [_]Disc{ .{ .c = .{ .x = 0, .y = 0 }, .r = 10 }, .{ .c = .{ .x = 100, .y = 0 }, .r = 10 } };
    // Well away from both, the field is the nearer disc's distance.
    try std.testing.expectApproxEqAbs(@as(f32, -10), field(&two, 2, .{ .x = 0, .y = 0 }).d, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 5), field(&two, 2, .{ .x = 15, .y = 0 }).d, 0.01);
    // Midway between two close discs the union dips below either alone: the bridge.
    const close = [_]Disc{ .{ .c = .{ .x = 0, .y = 0 }, .r = 10 }, .{ .c = .{ .x = 22, .y = 0 }, .r = 10 } };
    try std.testing.expect(field(&close, 8, .{ .x = 11, .y = 0 }).d < 0);
    try std.testing.expect(field(&close, 0.5, .{ .x = 11, .y = 0 }).d > 0);
}

test "many discs run together swell no more than k/4 apiece" {
    var six: [6]Disc = undefined;
    for (&six) |*d| d.* = .{ .c = .{ .x = 0, .y = 0 }, .r = 10 };
    // All on top of each other: the union's edge is at most (n − 1)·k/4 past theirs.
    try std.testing.expect(field(&six, 8, .{ .x = 10 + swell(8, six.len) + 0.01, .y = 0 }).d > 0);
}
