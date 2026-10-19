//! An orb's geometry (`plans/LIQUID_EDGE_PLAN.md`, "The orb system"): the shapes a control of glass
//! is made of, how one becomes another, and the polygons the no-glass path fills.
//!
//! - A **shape** is a rounded box: a circle, a capsule or a panel, by its centre, half-size and
//!   four corner radii (top-left, top-right, bottom-right, bottom-left; y down), as the glass
//!   program and `LiquidField.Shape` take it.
//! - A **place** is the outline that holds a control's shapes: a card's rect and corners. Glass is
//!   cut by it (`LiquidField.edge`); here `cut` does the same to a shape's polygon.
//! - A **transition** is shapes interpolated (`lerp`): position, size and corners eased by one
//!   curve, so a state becomes another by geometry alone and the material never changes.
//!
//! std-only, so it tests without a window (`build/app.zig`, `fizzy-orb-geometry-tests`). Physical
//! pixels throughout, as the glass works in.
const std = @import("std");

pub const Pt = [2]f32;

/// A rounded box: `center`, `half` its half-size, `radii` each corner's, held to half the shorter
/// side when drawn (`radius`).
pub const Shape = struct {
    center: Pt,
    half: Pt,
    radii: [4]f32 = @splat(0),

    pub fn circle(center: Pt, r: f32) Shape {
        return .{ .center = center, .half = .{ r, r }, .radii = @splat(r) };
    }

    /// A box `rect` (x, y, w, h) with its corners' `radii` (top-left, top-right, bottom-right,
    /// bottom-left); all of them at half the shorter side is a capsule.
    pub fn box(x: f32, y: f32, w: f32, h: f32, radii: [4]f32) Shape {
        return .{ .center = .{ x + w / 2, y + h / 2 }, .half = .{ w / 2, h / 2 }, .radii = radii };
    }

    /// Corner `i` (top-left, top-right, bottom-right, bottom-left) as drawn: at most half the
    /// shorter side.
    pub fn radius(self: Shape, i: usize) f32 {
        return @max(0, @min(self.radii[i], @min(self.half[0], self.half[1])));
    }

    /// Signed distance from `p` to the outline: negative inside.
    pub fn distance(self: Shape, p: Pt) f32 {
        const d: Pt = .{ p[0] - self.center[0], p[1] - self.center[1] };
        const i: usize = if (d[0] > 0) (if (d[1] > 0) 2 else 1) else (if (d[1] > 0) 3 else 0);
        const r = self.radius(i);
        const q: Pt = .{ @abs(d[0]) - self.half[0] + r, @abs(d[1]) - self.half[1] + r };
        const outside = @sqrt(@max(q[0], 0) * @max(q[0], 0) + @max(q[1], 0) * @max(q[1], 0));
        return @min(@max(q[0], q[1]), 0) + outside - r;
    }

    /// The outline as a convex polygon, clockwise on screen (y down), `per_corner` points round
    /// each corner (a square corner is one point), into `out`; the points written.
    pub fn outline(self: Shape, per_corner: usize, out: []Pt) []Pt {
        const n = @max(per_corner, 2);
        var len: usize = 0;
        // Corner centres and the angle each corner's arc starts at, going clockwise from the top left.
        const sx = [4]f32{ -1, 1, 1, -1 };
        const sy = [4]f32{ -1, -1, 1, 1 };
        const start = [4]f32{ std.math.pi, 1.5 * std.math.pi, 0, 0.5 * std.math.pi };
        for (0..4) |c| {
            const r = self.radius(c);
            const cx = self.center[0] + sx[c] * (self.half[0] - r);
            const cy = self.center[1] + sy[c] * (self.half[1] - r);
            if (r <= 0) {
                if (len < out.len) out[len] = .{ cx, cy };
                len += 1;
                continue;
            }
            for (0..n) |k| {
                const a = start[c] + 0.5 * std.math.pi * @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(n - 1));
                if (len < out.len) out[len] = .{ cx + r * @cos(a), cy + r * @sin(a) };
                len += 1;
            }
        }
        return out[0..@min(len, out.len)];
    }
};

/// `a` to `b`, `t` of the way (0…1): centre, size and corners together. A state into another by
/// geometry alone: the corner's quarter sliding in and growing into its button, a button into a
/// panel.
pub fn lerp(a: Shape, b: Shape, t: f32) Shape {
    const k = std.math.clamp(t, 0, 1);
    var s: Shape = .{
        .center = .{ std.math.lerp(a.center[0], b.center[0], k), std.math.lerp(a.center[1], b.center[1], k) },
        .half = .{ std.math.lerp(a.half[0], b.half[0], k), std.math.lerp(a.half[1], b.half[1], k) },
    };
    for (&s.radii, 0..) |*r, i| r.* = std.math.lerp(a.radius(i), b.radius(i), k);
    return s;
}

/// `subject` (any polygon) cut by the convex polygon `clip`, both clockwise on screen: the part of
/// `subject` inside `clip` (Sutherland–Hodgman), into `out` using `scratch`; the points written.
/// Both buffers want room for `subject.len + clip.len` points.
pub fn cut(subject: []const Pt, clip: []const Pt, out: []Pt, scratch: []Pt) []Pt {
    var src: []Pt = scratch[0..@min(subject.len, scratch.len)];
    @memcpy(src, subject[0..src.len]);
    var dst = out;
    var len: usize = src.len;
    for (clip, 0..) |a, i| {
        const b = clip[(i + 1) % clip.len];
        var n: usize = 0;
        for (0..len) |j| {
            const p = src[j];
            const q = src[(j + 1) % len];
            const pin = side(a, b, p) >= 0;
            const qin = side(a, b, q) >= 0;
            if (pin and n < dst.len) {
                dst[n] = p;
                n += 1;
            }
            if (pin != qin and n < dst.len) {
                dst[n] = cross(a, b, p, q);
                n += 1;
            }
        }
        len = n;
        if (len == 0) return out[0..0];
        // Swap: what was just written is the next pass's input.
        const written = dst[0..len];
        dst = if (dst.ptr == out.ptr) scratch else out;
        src = written;
    }
    // Within `out` whatever `scratch` held: a larger scratch could have held more than fits.
    const n = @min(len, out.len);
    if (src.ptr != out.ptr) @memcpy(out[0..n], src[0..n]);
    return out[0..n];
}

/// Which side of the edge `a`→`b` `p` is on: positive inside a clockwise (y-down) polygon.
fn side(a: Pt, b: Pt, p: Pt) f32 {
    return (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0]);
}

/// Where the segment `p`→`q` crosses the line through `a`, `b`.
fn cross(a: Pt, b: Pt, p: Pt, q: Pt) Pt {
    const sp = side(a, b, p);
    const sq = side(a, b, q);
    const t = sp / (sp - sq);
    return .{ p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t };
}

/// A polygon's area (positive for clockwise on screen).
pub fn area(poly: []const Pt) f32 {
    var a: f32 = 0;
    for (poly, 0..) |p, i| {
        const q = poly[(i + 1) % poly.len];
        a += p[0] * q[1] - q[0] * p[1];
    }
    return a / 2;
}

test "a circle's outline is round, and its area a circle's" {
    var buf: [256]Pt = undefined;
    const c = Shape.circle(.{ 50, 50 }, 20);
    const poly = c.outline(32, &buf);
    for (poly) |p| try std.testing.expectApproxEqAbs(@as(f32, 0), c.distance(p), 0.01);
    try std.testing.expectApproxEqRel(std.math.pi * 20 * 20, area(poly), 0.01);
}

test "a square corner is one point, and a box's area is its rect's" {
    var buf: [64]Pt = undefined;
    const b = Shape.box(0, 0, 100, 60, @splat(0));
    try std.testing.expectEqual(@as(usize, 4), b.outline(16, &buf).len);
    try std.testing.expectApproxEqAbs(@as(f32, 6000), area(b.outline(16, &buf)), 0.01);
}

test "a circle on a square place's corner, cut by the place, is a quarter" {
    var a: [256]Pt = undefined;
    var b: [256]Pt = undefined;
    var out: [512]Pt = undefined;
    var scratch: [512]Pt = undefined;
    const place = Shape.box(0, 0, 200, 100, @splat(0));
    const orb = Shape.circle(.{ 200, 0 }, 20);
    const q = cut(orb.outline(48, &a), place.outline(8, &b), &out, &scratch);
    try std.testing.expectApproxEqRel(@as(f32, std.math.pi * 20 * 20) / 4, area(q), 0.02);
    for (q) |p| try std.testing.expect(place.distance(p) <= 0.01);
}

test "cut by a rounded place, the quarter follows its curve: smaller, and none of it past the curve" {
    var a: [256]Pt = undefined;
    var b: [256]Pt = undefined;
    var out: [512]Pt = undefined;
    var scratch: [512]Pt = undefined;
    const place = Shape.box(0, 0, 200, 100, .{ 0, 24, 0, 0 });
    const orb = Shape.circle(.{ 200, 0 }, 24 * (std.math.sqrt2 - 1) + 12);
    const q = cut(orb.outline(48, &a), place.outline(24, &b), &out, &scratch);
    try std.testing.expect(area(q) > 0);
    try std.testing.expect(area(q) < std.math.pi * orb.half[0] * orb.half[0] / 4);
    for (q) |p| try std.testing.expect(place.distance(p) <= 0.05);
}

test "lerp carries centre, size and corners together, and stops at its ends" {
    const a = Shape.circle(.{ 200, 0 }, 20);
    const b = Shape.box(150, 20, 36, 36, @splat(18));
    const mid = lerp(a, b, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 184), mid.center[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 19), mid.half[0], 0.01);
    try std.testing.expectEqual(a, lerp(a, b, -1));
    try std.testing.expectEqual(b.center, lerp(a, b, 2).center);
}
