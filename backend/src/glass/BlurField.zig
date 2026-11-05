//! A feathered rounded frost mask in physical pixels, sampling a layer's shared capture.
const std = @import("std");
const dvui = @import("dvui");
const BlurBackdrop = @import("BlurBackdrop.zig");

const BlurField = @This();

/// The outer bound, inset from the screen by the caller.
rect: dvui.Rect.Physical,
radius: f32 = 0,
/// Inward ramp width; the mesh reduces it to fit a nonempty inner ring.
feather: f32,
/// Animate this alpha, 0…1, while keeping the layer's blur radius constant.
strength: f32 = 1,
/// Colour over the frost, with the same mask; its alpha is the amount.
tint: ?dvui.Color = null,

pub const rings = 7;

/// Alpha at distance `d` inward from the outer bound.
pub fn alphaAt(self: BlurField, d: f32) f32 {
    if (d < 0) return 0;
    if (self.feather <= 0) return self.strength;
    const t = std.math.clamp(d / self.feather, 0, 1);
    return self.strength * t * t * (3 - 2 * t);
}

/// Number of vertices required by `mesh`.
pub fn vertexCount(self: BlurField) usize {
    return self.ringCount() * self.pointsPerRing();
}

/// Append a white premultiplied mask; `coverage` is the texture's window-space coverage.
pub fn mesh(self: BlurField, b: *dvui.Triangles.Builder, coverage: dvui.Rect.Physical) void {
    const n = self.pointsPerRing();
    const count = self.ringCount();
    var mask = self;
    mask.feather = self.fittedFeather();
    for (0..count) |k| {
        const distance = mask.ringInset(k);
        const c: u8 = @intFromFloat(@round(255 * std.math.clamp(mask.alphaAt(distance), 0, 1)));
        for (0..n) |i| {
            const p = mask.ringPoint(k, i);
            b.appendVertex(.{
                .pos = p,
                .col = .{ .r = c, .g = c, .b = c, .a = c },
                .uv = .{ (p.x - coverage.x) / coverage.w, (p.y - coverage.y) / coverage.h },
            });
        }
    }
    for (1..n - 1) |i| b.appendTriangles(&.{ 0, @intCast(i), @intCast(i + 1) });
    for (0..count - 1) |k| {
        for (0..n) |i| {
            const j = (i + 1) % n;
            b.appendTriangles(&.{
                @intCast((k + 1) * n + i), @intCast((k + 1) * n + j), @intCast(k * n + j),
                @intCast((k + 1) * n + i), @intCast(k * n + j),       @intCast(k * n + i),
            });
        }
    }
}

/// Draw over the scene; restores the frost texture's copy blend before returning.
pub fn draw(self: BlurField, tex: dvui.Texture, coverage: dvui.Rect.Physical) void {
    if (self.strength < 0.004 or self.rect.empty()) return;
    const lifo = dvui.currentWindow().lifo();
    const n = self.pointsPerRing();
    const indices = (n - 2) * 3 + (self.ringCount() - 1) * n * 6;
    var b = dvui.Triangles.Builder.init(lifo, self.vertexCount(), indices) catch return;
    defer b.deinit(lifo);
    self.mesh(&b, coverage);
    {
        BlurBackdrop.blendOver(tex, true);
        defer BlurBackdrop.blendOver(tex, false);
        dvui.renderTriangles(b.build_unowned(), tex) catch {};
    }
    if (self.tint) |tint| {
        const triangles = b.build_unowned();
        for (triangles.vertexes) |*v| {
            const a = @as(f32, @floatFromInt(v.col.a)) / 255;
            v.col = dvui.Color.PMA.fromColor(tint.opacity(a));
        }
        dvui.renderTriangles(triangles, null) catch {};
    }
}

fn fittedFeather(self: BlurField) f32 {
    // Leave a nonempty inner ring even when the requested ramps meet in the middle.
    return @max(0, @min(self.feather, @min(self.rect.w, self.rect.h) * 0.499));
}

fn ringCount(self: BlurField) usize {
    return if (self.fittedFeather() > 0) rings else 1;
}

fn pointsPerRing(self: BlurField) usize {
    // At most about 0.5 px chord error, based on the OUTER radius for every ring.
    const r = @min(@max(0, self.radius), @min(self.rect.w, self.rect.h) / 2);
    const segments: usize = @intFromFloat(@ceil(@max(1, std.math.pi / 2.0 * @sqrt(@max(r, self.fittedFeather())))));
    return 4 * (segments + 1);
}

fn ringInset(self: BlurField, k: usize) f32 {
    return self.fittedFeather() * (1 - @as(f32, @floatFromInt(k)) / (rings - 1));
}

fn ringPoint(self: BlurField, k: usize, i: usize) dvui.Point.Physical {
    const inset = self.ringInset(k);
    const rect = self.rect.insetAll(inset);
    const outer_radius = @min(@max(0, self.radius), @min(self.rect.w, self.rect.h) / 2);
    const r = @max(0, outer_radius - inset);
    const per_corner = self.pointsPerRing() / 4;
    const corner = i / per_corner;
    const angle = (@as(f32, @floatFromInt(corner)) + @as(f32, @floatFromInt(i % per_corner)) / @as(f32, @floatFromInt(per_corner - 1))) * (std.math.pi / 2.0) + std.math.pi;
    const centers = [4]dvui.Point.Physical{
        .{ .x = rect.x + r, .y = rect.y + r },
        .{ .x = rect.x + rect.w - r, .y = rect.y + r },
        .{ .x = rect.x + rect.w - r, .y = rect.y + rect.h - r },
        .{ .x = rect.x + r, .y = rect.y + rect.h - r },
    };
    return .{ .x = centers[corner].x + r * @cos(angle), .y = centers[corner].y + r * @sin(angle) };
}

fn testMesh(field: BlurField, coverage: dvui.Rect.Physical) !dvui.Triangles.Builder {
    const n = field.pointsPerRing();
    var b = try dvui.Triangles.Builder.init(std.testing.allocator, field.vertexCount(), (n - 2) * 3 + (field.ringCount() - 1) * n * 6);
    field.mesh(&b, coverage);
    return b;
}

fn signedDistance(p: dvui.Point.Physical, rect: dvui.Rect.Physical, radius: f32) f32 {
    const qx = @abs(p.x - rect.x - rect.w / 2) - (rect.w / 2 - radius);
    const qy = @abs(p.y - rect.y - rect.h / 2) - (rect.h / 2 - radius);
    return @sqrt(@max(qx, 0) * @max(qx, 0) + @max(qy, 0) * @max(qy, 0)) + @min(@max(qx, qy), 0) - radius;
}

test "alpha is 0 at the bound, half mid-ramp, full inside" {
    var f: BlurField = .{ .rect = .{ .w = 400, .h = 600 }, .feather = 48 };
    for ([_]f32{ 1, 0.5 }) |strength| {
        f.strength = strength;
        for ([_]f32{ 0, 24, 48, 200 }, [_]f32{ 0, 0.5, 1, 1 }) |d, alpha| {
            try std.testing.expectApproxEqAbs(alpha * strength, f.alphaAt(d), 0.0001);
        }
    }
    f.feather = 0;
    try std.testing.expectEqual(f.strength, f.alphaAt(0));
    try std.testing.expectEqual(f.strength, f.alphaAt(200));
    try std.testing.expectEqual(0, f.alphaAt(-1));
    try std.testing.expectEqual(1, f.ringCount());
}

test "every ring lies at its distance from the bound" {
    const f: BlurField = .{ .rect = .{ .w = 400, .h = 600 }, .radius = 40, .feather = 48 };
    var b = try testMesh(f, f.rect);
    defer b.deinit(std.testing.allocator);
    const n = f.pointsPerRing();
    for (0..rings) |k| {
        const distance = 48 * (1 - @as(f32, @floatFromInt(k)) / 6);
        for (b.vertexes.items[k * n ..][0..n]) |v| {
            try std.testing.expectApproxEqAbs(-distance, signedDistance(v.pos, f.rect, 40), 0.6);
            try std.testing.expectApproxEqAbs(f.alphaAt(distance), @as(f32, @floatFromInt(v.col.a)) / 255, 0.01);
        }
    }
}

test "the outer ring is the bound" {
    for ([_]f32{ 0, 40 }) |radius| {
        const f: BlurField = .{ .rect = .{ .x = 20, .y = 30, .w = 400, .h = 600 }, .radius = radius, .feather = 48 };
        var b = try testMesh(f, f.rect);
        defer b.deinit(std.testing.allocator);
        const n = f.pointsPerRing();
        var min_x: f32 = std.math.inf(f32);
        var min_y: f32 = std.math.inf(f32);
        var max_x: f32 = -std.math.inf(f32);
        var max_y: f32 = -std.math.inf(f32);
        for (b.vertexes.items[6 * n ..]) |v| {
            min_x = @min(min_x, v.pos.x);
            min_y = @min(min_y, v.pos.y);
            max_x = @max(max_x, v.pos.x);
            max_y = @max(max_y, v.pos.y);
            try std.testing.expectApproxEqAbs(@as(f32, 0), signedDistance(v.pos, f.rect, radius), 0.6);
        }
        try std.testing.expectApproxEqAbs(f.rect.x, min_x, 0.01);
        try std.testing.expectApproxEqAbs(f.rect.y, min_y, 0.01);
        try std.testing.expectApproxEqAbs(f.rect.x + f.rect.w, max_x, 0.01);
        try std.testing.expectApproxEqAbs(f.rect.y + f.rect.h, max_y, 0.01);
        if (radius == 0) try std.testing.expectEqual(f.rect.topLeft(), b.vertexes.items[6 * n].pos);
    }
}

test "a field narrower than two feathers shrinks the feather" {
    const f: BlurField = .{ .rect = .{ .w = 60, .h = 600 }, .radius = 40, .feather = 48 };
    try std.testing.expect(f.fittedFeather() < 30);
    var previous = f.rect.insetAll(f.ringInset(0));
    for (0..rings) |k| {
        const rect = f.rect.insetAll(f.ringInset(k));
        try std.testing.expect(!rect.empty());
        try std.testing.expect(rect.x <= previous.x and rect.y <= previous.y);
        try std.testing.expect(rect.x + rect.w >= previous.x + previous.w);
        try std.testing.expect(rect.y + rect.h >= previous.y + previous.h);
        previous = rect;
    }
    var b = try testMesh(f, f.rect);
    defer b.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 255), b.vertexes.items[0].col.a);
}

test "uv maps the coverage" {
    const f: BlurField = .{ .rect = .{ .x = 40, .y = 50, .w = 400, .h = 600 }, .radius = 40, .feather = 48 };
    const coverage: dvui.Rect.Physical = .{ .x = 10, .y = 20, .w = 512, .h = 768 };
    var b = try testMesh(f, coverage);
    defer b.deinit(std.testing.allocator);
    for (b.vertexes.items) |v| {
        try std.testing.expectApproxEqAbs((v.pos.x - coverage.x) / coverage.w, v.uv[0], 0.0001);
        try std.testing.expectApproxEqAbs((v.pos.y - coverage.y) / coverage.h, v.uv[1], 0.0001);
    }
}
