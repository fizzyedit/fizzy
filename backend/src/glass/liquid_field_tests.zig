//! Unit coverage for the liquid field, kept apart so importing it for drawing does not run
//! these arithmetic tests again in the headless integration artifacts.
const std = @import("std");
const dvui = @import("dvui");
const glass_look = @import("glass_look");
const LiquidField = @import("LiquidField.zig");
const Shape = LiquidField.Shape;
const Sample = LiquidField.Sample;
const testing = std.testing;
const Point = dvui.Point.Physical;

/// A round-edged 200 x 100 card at (100, 50), corner radius 20 (points), at `scale`: its outline
/// follows the true normal, as a drop's does.
fn testCard(scale: f32) LiquidField {
    var f: LiquidField = .{ .scale = scale, .merge_px = 24 * scale };
    var sh = Shape{ .rect = .{ .x = 0, .y = 0, .w = 200 * scale, .h = 100 * scale }, .radii = @splat(20 * scale) };
    sh.round = true;
    f.add(sh);
    return f;
}

/// The point of the card's outline that faces `toward`, `inset` pixels inside it.
fn litPlace(f: *const LiquidField, toward: [2]f32, inset: f32) Point {
    const sh = f.shapes[0];
    const r = sh.radii[0];
    const qx: f32 = if (toward[0] < 0) -1 else 1;
    const qy: f32 = if (toward[1] < 0) -1 else 1;
    const cx = sh.rect.x + sh.rect.w / 2;
    const cy = sh.rect.y + sh.rect.h / 2;
    return .{
        .x = cx + qx * (sh.rect.w / 2 - r) + (r - inset) * toward[0],
        .y = cy + qy * (sh.rect.h / 2 - r) + (r - inset) * toward[1],
    };
}

fn dropLook() glass_look.Look {
    return glass_look.forDrops(glass_look.inApp(0.5));
}

test "the light packs on every look" {
    var f: LiquidField = .{};
    f.add(Shape.circle(.{ .x = 50, .y = 50 }, 40));
    const order = [_]u8{0};
    const area: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    var u = f.pack(area, false, &order);
    try testing.expectApproxEqAbs(@as(f32, -0.707), u.light[0], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, -0.707), u.light[1], 1e-3);
    try testing.expectEqual([4]f32{ 0, 0, 0, 0 }, u.edge);
    f.light_across = true;
    u = f.pack(area, false, &order);
    try testing.expectApproxEqAbs(@as(f32, 0.707), u.light[0], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, -0.707), u.light[1], 1e-3);
    var console = dropLook();
    console.light_angle = 119.6;
    f.applyLook(&u, console);
    f.light_across = false;
    var v = f.pack(area, false, &order);
    f.applyLook(&v, console);
    try testing.expectApproxEqAbs(@as(f32, 0.494), v.light[0], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, -0.870), v.light[1], 1e-3);
}

test "the lit edge is 0 inside a neck and rim_line at the outline" {
    var f: LiquidField = .{ .merge_px = 24 };
    for ([_]f32{ 0, 108 }) |x| {
        var sh = Shape{ .rect = .{ .x = x, .y = 0, .w = 100, .h = 60 }, .radii = @splat(12) };
        sh.round = true;
        f.add(sh);
    }
    var l = dropLook();
    l.rim_line = 0.8;
    l.rim_width = 20;
    l.rim_extent = 1e4;
    l.light_angle = 90;
    const neck = f.sampleWith(.{ .x = 104, .y = 30 }, l);
    try testing.expectApproxEqAbs(@as(f32, 0), neck.edge_line, 1e-4);
    // The top of the joined outline, half a pixel inside it, faces the light.
    const top = f.sampleWith(.{ .x = 50, .y = 0.5 }, l);
    try testing.expectApproxEqAbs(@as(f32, 0.8), top.edge_line, 0.05);
}

test "a symmetric neck's midline gives no NaN" {
    var f: LiquidField = .{ .merge_px = 24 };
    for ([_]f32{ 0, 108 }) |x| {
        f.add(.{ .rect = .{ .x = x, .y = 0, .w = 100, .h = 60 }, .radii = @splat(12) });
    }
    var l = dropLook();
    l.rim_line = 0.8;
    l.rim_glow = 0.5;
    l.glow_width = 6;
    l.rim_shade = 0.4;
    l.rim_extent = 30;
    var y: f32 = 5;
    while (y < 60) : (y += 11) {
        const s = f.sampleWith(.{ .x = 104, .y = y }, l);
        inline for (comptime std.meta.fieldNames(Sample)) |name| {
            const v = @field(s, name);
            switch (@typeInfo(@TypeOf(v))) {
                .float => try testing.expect(std.math.isFinite(v)),
                .@"struct" => {
                    try testing.expect(std.math.isFinite(v.x));
                    try testing.expect(std.math.isFinite(v.y));
                },
                else => unreachable,
            }
        }
    }
}

test "the light side is brighter than the far side" {
    const f = testCard(1);
    var l = dropLook();
    l.light_angle = 51.7;
    l.rim_line = 0.8;
    l.rim_glow = 0.5;
    l.rim_width = 1;
    l.glow_width = 20;
    l.rim_back = 0.3;
    const toward = glass_look.lightVector(51.7);
    // The glow lies just inside the line, so a pixel and a half in.
    const near = f.sampleWith(litPlace(&f, toward, 1.5), l);
    const far = f.sampleWith(litPlace(&f, .{ -toward[0], -toward[1] }, 1.5), l);
    try testing.expect(near.edge_line > far.edge_line);
    try testing.expect(near.edge_glow > 0);
    try testing.expectApproxEqAbs(@as(f32, 0.3), far.edge_glow / near.edge_glow, 0.05);
}

test "at 45 degrees the top-left and bottom-right corners are lit" {
    const f = testCard(1);
    var l = dropLook();
    l.diagonal = 0.6;
    l.rim_extent = 0;
    const r: f32 = 1.0 / @sqrt(2.0);
    const tl: [2]f32 = .{ -r, -r };
    const tr: [2]f32 = .{ r, -r };
    for ([_]f32{ 45, 135 }) |angle| {
        l.light_angle = angle;
        const lit_a: [2]f32 = if (angle == 45) tl else tr;
        const lit_b: [2]f32 = .{ -lit_a[0], -lit_a[1] };
        const dark_a: [2]f32 = if (angle == 45) tr else tl;
        const dark_b: [2]f32 = .{ -dark_a[0], -dark_a[1] };
        try testing.expectApproxEqAbs(@as(f32, 0.6), f.sampleWith(litPlace(&f, lit_a, 0), l).edge_spec, 0.02);
        try testing.expectApproxEqAbs(@as(f32, 0.6), f.sampleWith(litPlace(&f, lit_b, 0), l).edge_spec, 0.02);
        try testing.expect(f.sampleWith(litPlace(&f, dark_a, 0), l).edge_spec < 0.01);
        try testing.expect(f.sampleWith(litPlace(&f, dark_b, 0), l).edge_spec < 0.01);
    }
    for ([_]f32{ 0, 45 }) |angle| {
        l.light_angle = angle;
        try testing.expectEqual(@as(f32, 0), f.sampleWith(.{ .x = 100, .y = 0 }, l).edge_spec);
    }
}

/// The distance, in points, from the top left lit place of `f` to the top side's point at `x`.
fn chordTo(f: *const LiquidField, x: f32) f32 {
    const r: f32 = 1.0 / @sqrt(2.0);
    const from = litPlace(f, .{ -r, -r }, 0);
    return @sqrt((x - from.x) * (x - from.x) + from.y * from.y) / f.scale;
}

test "rim_extent runs the light along a straight side, and 1e4 lights it whole" {
    for ([_]f32{ 1, 2 }) |scale| {
        const f = testCard(scale);
        var l = dropLook();
        l.diagonal = 0.6;
        l.light_angle = 45;
        l.rim_extent = 1e4;
        const middle = f.sampleWith(.{ .x = 100 * scale, .y = 0 }, l);
        try testing.expectApproxEqAbs(@as(f32, 0.6), middle.edge_spec, 0.02);
        // Past the corner's arc (which lights a drop on its own, 15.7 points on) only the reach
        // is left: the first point under 0.01 is 24 points from the lit place.
        l.rim_extent = 24;
        var x: f32 = 20 * scale;
        while (x < 100 * scale) : (x += 0.05 * scale) {
            if (f.sampleWith(.{ .x = x, .y = 0 }, l).edge_spec < 0.01) break;
        }
        try testing.expectApproxEqAbs(@as(f32, 24), chordTo(&f, x), 1);
    }
}

test "rim_extent 0 is today's edge" {
    const joined = blk: {
        var f: LiquidField = .{ .merge_px = 24 };
        for ([_]f32{ 0, 108 }) |x| {
            var sh = Shape{ .rect = .{ .x = x, .y = 0, .w = 100, .h = 60 }, .radii = @splat(12) };
            sh.round = true;
            f.add(sh);
        }
        break :blk f;
    };
    for ([_]LiquidField{ testCard(1), joined }) |base| {
        for ([_]bool{ false, true }) |across| {
            var f = base;
            f.light_across = across;
            var l = dropLook();
            l.rim_extent = 0;
            const light = glass_look.lightVector(l.light_angle);
            const lx: f32 = if (across) -light[0] else light[0];
            for (0..40) |i| {
                for (0..20) |j| {
                    const p: Point = .{ .x = @as(f32, @floatFromInt(i)) * 5.4 + 0.3, .y = @as(f32, @floatFromInt(j)) * 3 - 1 };
                    const s = f.sampleWith(p, l);
                    const af = @abs(s.out.x * lx + s.out.y * light[1]);
                    const t = std.math.clamp((af - 0.75) / 0.25, 0, 1);
                    try testing.expectApproxEqAbs(l.diagonal * t * t * (3 - 2 * t), s.edge_spec, 1e-6);
                }
            }
        }
    }
}

test "rim_falloff shapes the fade, rim_extent ends it" {
    const falloffs = [_]f32{ 0, 0.25, 0.5, 1 };
    for ([_]f32{ 1, 2 }) |scale| {
        const f = testCard(scale);
        // For each falloff: the walk along the top side, in steps of a tenth of a point, from the
        // arc's end, and where it first falls under full light.
        var ramp_start: [falloffs.len]f32 = undefined;
        var prev: [1200]f32 = @splat(1);
        for (falloffs, 0..) |falloff, k| {
            var l = dropLook();
            l.diagonal = 0.6;
            l.rim_extent = 24;
            l.rim_falloff = falloff;
            var last: f32 = 1;
            var start: ?f32 = null;
            var ended: ?f32 = null;
            for (0..1200) |i| {
                const x = (20 + @as(f32, @floatFromInt(i)) * 0.05) * scale;
                const v = f.sampleWith(.{ .x = x, .y = 0 }, l).edge_spec;
                try testing.expect(v <= last + 1e-6);
                last = v;
                // A larger falloff is never brighter.
                try testing.expect(v <= prev[i] + 1e-6);
                prev[i] = v;
                const d = chordTo(&f, x);
                if (start == null and v < 0.6 * 0.99) start = d;
                if (ended == null and v < 0.001) ended = d;
            }
            try testing.expectApproxEqAbs(@as(f32, 24), ended.?, 1);
            ramp_start[k] = start.?;
            if (falloff == 0) try testing.expectApproxEqAbs(@as(f32, 23), start.?, 1);
            if (k > 0) try testing.expect(ramp_start[k] <= ramp_start[k - 1] + 0.1);
        }
        // With no reach, every falloff is main's.
        for (falloffs) |falloff| {
            var l = dropLook();
            l.rim_extent = 0;
            l.rim_falloff = falloff;
            const s = f.sampleWith(.{ .x = 60 * scale, .y = 0 }, l);
            try testing.expectEqual(@as(f32, 0), s.edge_spec);
        }
    }
}
