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

const Seam = LiquidField.Seam;
const Panel = LiquidField.Panel;
const panel_rect: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 400, .h = 120 };

fn panelField(seams: []const Seam) LiquidField {
    return .{ .panel = .{ .rect = panel_rect, .radii = @splat(20), .seams = seams } };
}

fn parentField(rect: dvui.Rect.Physical, radius: f32) LiquidField {
    var f: LiquidField = .{};
    f.add(.{ .rect = rect, .radii = @splat(radius) });
    return f;
}

fn panelSample(f: *const LiquidField, x: f32, y: f32) Sample {
    return f.sampleWith(.{ .x = x, .y = y }, dropLook());
}

fn checkPieces(f: *const LiquidField) !void {
    var storage: [16]Shape = undefined;
    const parts = LiquidField.pieces(f.panel.?, &storage);
    var expected: LiquidField = .{};
    for (parts) |part| expected.add(part);
    // The contour and its anti-aliasing band, including every cut corner.
    for (0..129) |yi| for (0..409) |xi| {
        const x = @as(f32, @floatFromInt(xi)) - 4;
        const y = @as(f32, @floatFromInt(yi)) - 4;
        const a = panelSample(f, x, y);
        const b = panelSample(&expected, x, y);
        if (@abs(a.d) <= 1 or @abs(b.d) <= 1) try testing.expectApproxEqAbs(b.d, a.d, 0.25);
    };
}

/// The narrowest remaining neck across 32 parallel rays through the seam's centre.
fn neckWidth(f: *const LiquidField, at: f32, height: f32) f32 {
    var width: f32 = height;
    for (0..32) |ray| {
        const x = at + (@as(f32, @floatFromInt(ray)) / 31 - 0.5) * 0.5;
        var run: f32 = 0;
        var longest: f32 = 0;
        var y: f32 = 0;
        while (y < height) : (y += 0.25) {
            if (panelSample(f, x, y).coverage >= 0.5) {
                run += 0.25;
                longest = @max(longest, run);
            } else run = 0;
        }
        width = @min(width, longest);
    }
    return width;
}

fn checkNeck(nested: bool) !void {
    var seams = [_]Seam{
        .{ .axis = .horizontal, .at = 60, .reach = 12 },
        .{ .axis = .vertical, .at = 200, .span = .{ 0, 60 }, .reach = 12 },
    };
    if (!nested) seams[1].span = null;
    var previous: f32 = if (nested) 60 else 120;
    const total = previous;
    for (0..61) |step| {
        seams[1].gap = @as(f32, @floatFromInt(step)) / 60 * 12;
        const f = panelField(if (nested) &seams else seams[1..]);
        const width = neckWidth(&f, 200, total);
        try testing.expect(width <= previous + 0.25);
        try testing.expect(previous - width <= total * 0.15);
        previous = width;
    }
    try testing.expectEqual(@as(f32, 0), previous);
}

/// Opt-in headless evidence; ordinary test runs write no files.
fn dumpPanelCoverage() !void {
    const destination = testing.environ.getAlloc(testing.allocator, "FIZZY_PANEL_DUMPS") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return,
        else => return err,
    };
    defer testing.allocator.free(destination);
    var dir = try std.Io.Dir.cwd().openDir(testing.io, destination, .{});
    defer dir.close(testing.io);
    const width = 408;
    const height = 128;
    const header = "P5\n408 128\n255\n";
    const bytes = try testing.allocator.alloc(u8, header.len + width * height);
    defer testing.allocator.free(bytes);
    @memcpy(bytes[0..header.len], header);
    for (0..5) |step| {
        const gap = @as(f32, @floatFromInt(step)) * 3;
        const seams = [_]Seam{
            .{ .axis = .horizontal, .at = 60, .gap = gap, .reach = 12 },
            .{ .axis = .vertical, .at = 200, .span = .{ 0, 60 }, .gap = gap, .reach = 12 },
        };
        const f = panelField(&seams);
        for (0..height) |y| for (0..width) |x| {
            const coverage = panelSample(&f, @as(f32, @floatFromInt(x)) - 4, @as(f32, @floatFromInt(y)) - 4).coverage;
            bytes[header.len + y * width + x] = @intFromFloat(coverage * 255);
        };
        var name: [32]u8 = undefined;
        const filename = try std.mem.print(&name, "panel-{d}.pgm", .{step});
        try dir.writeFile(testing.io, .{ .sub_path = filename, .data = bytes });
    }
}

test "a closed panel is its parent" {
    const seams = [_]Seam{
        .{ .axis = .horizontal, .at = 30, .reach = 12 },
        .{ .axis = .vertical, .at = 150, .reach = 12 },
        .{ .axis = .vertical, .at = 270, .span = .{ 0, 30 }, .reach = 12 },
    };
    const rect: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 400, .h = 60 };
    const f: LiquidField = .{ .panel = .{ .rect = rect, .radii = @splat(30), .seams = &seams } };
    const parent = parentField(rect, 30);
    for (0..69) |yi| for (0..409) |xi| {
        const x = @as(f32, @floatFromInt(xi)) - 4;
        const y = @as(f32, @floatFromInt(yi)) - 4;
        const a = panelSample(&f, x, y);
        const b = panelSample(&parent, x, y);
        try testing.expectApproxEqAbs(b.coverage, a.coverage, 0.25);
        try testing.expectApproxEqAbs(b.d, a.d, 0.25);
    };
    const groups = f.clusters();
    try testing.expectEqual(@as(usize, 1), groups.count);
    try testing.expectEqual(@as(u8, 1), groups.size[0]);
    const uniforms = f.pack(rect, false, groups.order[0..1]);
    try testing.expectEqual(@as(f32, 0), uniforms.shapes[15][2][2]);
    try testing.expectEqual(@as(f32, 4), uniforms.shapes[15][2][3]);
}

test "no bump at the seam while it opens" {
    var seams = [_]Seam{.{ .axis = .vertical, .at = 200, .reach = 12 }};
    const parent = parentField(panel_rect, 20);
    for (0..19) |step| {
        seams[0].gap = @as(f32, @floatFromInt(step)) / 60 * 12;
        const f = panelField(&seams);
        for (0..41) |xi| {
            const x = 180 + @as(f32, @floatFromInt(xi));
            try testing.expect(panelSample(&f, x, 0).d >= panelSample(&parent, x, 0).d - 0.01);
        }
    }
}

test "a through seam's pieces are rounded rects" {
    const seams = [_]Seam{.{ .axis = .vertical, .at = 200, .gap = 12, .reach = 12 }};
    const f = panelField(&seams);
    try checkPieces(&f);
}

test "the neck moves smoothly" {
    try checkNeck(false);
}

test "2D: closed is the parent" {
    var seams = [_]Seam{
        .{ .axis = .horizontal, .at = 60, .reach = 12 },
        .{ .axis = .vertical, .at = 200, .span = .{ 0, 60 }, .reach = 12 },
    };
    const parent = parentField(panel_rect, 20);
    for ([_]f32{ 0, 1e-6 }) |gap| {
        for (&seams) |*seam| seam.gap = gap;
        const f = panelField(&seams);
        for (0..129) |yi| for (0..409) |xi| {
            const x = @as(f32, @floatFromInt(xi)) - 4;
            const y = @as(f32, @floatFromInt(yi)) - 4;
            try testing.expectApproxEqAbs(panelSample(&parent, x, y).d, panelSample(&f, x, y).d, 0.01);
        };
    }
}

test "2D: three rounded pieces" {
    const seams = [_]Seam{
        .{ .axis = .horizontal, .at = 60, .gap = 12, .reach = 12 },
        .{ .axis = .vertical, .at = 200, .span = .{ 0, 60 }, .gap = 12, .reach = 12 },
    };
    const f = panelField(&seams);
    try checkPieces(&f);
    const groups = f.clusters();
    const u = f.pack(panel_rect, false, groups.order[0..1]);
    try testing.expectEqual(@as(f32, 2), u.shapes[15][2][2]);
    try testing.expectEqual([4]f32{ 12, 12, 6, 1 }, u.shapes[13][1]);
    try testing.expectEqual(@as(f32, 1), u.shapes[13][2][0]);
}

test "2D: pills part, the brief stays whole" {
    const seams = [_]Seam{
        .{ .axis = .horizontal, .at = 60, .reach = 12 },
        .{ .axis = .vertical, .at = 200, .span = .{ 0, 60 }, .gap = 12, .reach = 12 },
    };
    const f = panelField(&seams);
    const parent = parentField(panel_rect, 20);
    var storage: [8]Shape = undefined;
    const parts = LiquidField.pieces(f.panel.?, &storage);
    try testing.expectEqual(@as(f32, 20), parts[0].radii[2]);
    // The half-pixel below the host belongs to the continuous antialiasing band.
    for (0..120) |yi| for (0..401) |xi| {
        const x: f32 = @floatFromInt(xi);
        const y = 60.5 + @as(f32, @floatFromInt(yi)) * 0.5;
        try testing.expectApproxEqAbs(panelSample(&parent, x, y).coverage, panelSample(&f, x, y).coverage, 0.001);
    };
    try checkNeck(true);
}

test "pieces() is the console's model" {
    const seams = [_]Seam{
        .{ .axis = .horizontal, .at = 60, .reach = 12 },
        Seam.between(.vertical, 197, 203, .{ 0, 60 }, 12),
    };
    const f = panelField(&seams);
    var storage: [8]Shape = undefined;
    const parts = LiquidField.pieces(f.panel.?, &storage);
    try testing.expectEqual(@as(usize, 3), parts.len);
    try testing.expectEqual(@as(f32, 10), parts[0].radii[1]);
    try testing.expectEqual(@as(f32, 10), parts[0].radii[2]);
    try testing.expectEqual(@as(f32, 10), parts[2].radii[0]);
    try testing.expectEqual(@as(f32, 10), parts[2].radii[3]);
    var area: f32 = 0;
    for (parts) |part| area += part.rect.w * part.rect.h;
    try testing.expectEqual(@as(f32, 400 * 120 - 6 * 60), area);
}

test "a drop still runs into a panel" {
    var f = panelField(&.{});
    f.merge_px = 16;
    f.add(Shape.circle(.{ .x = 200, .y = -18 }, 10));
    // At exactly half the merge width the quadratic minimum is tangent at coverage 0.5.
    try testing.expectApproxEqAbs(@as(f32, 0.5), panelSample(&f, 200, -4).coverage, 0.001);
    f.shapes[0].rect.y += 0.1;
    try testing.expect(panelSample(&f, 200, -4).coverage > 0.5);
    f.merge_px = 0;
    try testing.expectEqual(@as(f32, 0), panelSample(&f, 200, -4).coverage);
}

test "panel coverage evidence" {
    try dumpPanelCoverage();
}

test "a drop cannot animate the panel material" {
    var f = panelField(&.{});
    f.panel.?.blur = 0.7;
    f.panel.?.lens = 0.8;
    f.add(.{ .rect = .{ .x = 500, .y = 0, .w = 20, .h = 20 }, .blur = 0.1, .lens = 0.2 });
    const before = panelSample(&f, 100, 40);
    f.shapes[0].blur = 0.9;
    f.shapes[0].lens = 1.2;
    const after = panelSample(&f, 100, 40);
    try testing.expectEqual(before, after);
    const groups = f.clusters();
    const u = f.pack(panel_rect, false, groups.order[0..2]);
    try testing.expectApproxEqAbs(@as(f32, 0.7), u.shapes[15][2][0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.8), u.shapes[15][2][1], 0.001);
}

test "nested seam tolerates coordinate rounding" {
    const seams = [_]Seam{
        .{ .axis = .horizontal, .at = 60, .gap = 12, .reach = 12 },
        .{ .axis = .vertical, .at = 200, .span = .{ 0, 60.000004 }, .gap = 12, .reach = 12 },
    };
    const f = panelField(&seams);
    const u = f.pack(panel_rect, false, &.{0});
    try testing.expectEqual(@as(f32, 1), u.shapes[13][2][0]);
    try testing.expectEqual(@as(f32, 1), u.shapes[13][1][3]);
}

test "panel outlines draw in a frame" {
    var window = try dvui.testing.init(.{ .allocator = testing.allocator });
    defer window.deinit();
    const seams = [_]Seam{
        .{ .axis = .horizontal, .at = 60, .gap = 12, .reach = 12 },
        .{ .axis = .vertical, .at = 200, .span = .{ 0, 60 }, .gap = 12, .reach = 12 },
    };
    const f = panelField(&seams);
    f.drawOutlines(.white);
}
