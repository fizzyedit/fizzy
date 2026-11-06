const std = @import("std");
const dvui = @import("dvui");
const bed = @import("GlassTestbed.zig");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;

test "parsing requires a known scene and an output directory" {
    try std.testing.expectEqualStrings("/tmp/x", bed.parse("pair:/tmp/x").?.dir);
    try equal(.pair, bed.parse("pair:/tmp/x").?.scene);
    try std.testing.expectEqualStrings("/tmp/y", bed.parse("shadow:/tmp/y").?.dir);
    try equal(.shadow, bed.parse("shadow:/tmp/y").?.scene);
    try expect(bed.parse("pair") == null);
    try expect(bed.parse("nope:/tmp/x") == null);
    try expect(bed.parse("pair:") == null);
    try expect(bed.parse("shadow:") == null);
}

test "pair steps and drop geometry follow the console join" {
    try equal(26, bed.steps(.pair));
    for (0..25) |i| try equal(12 - @as(f32, @floatFromInt(i)), bed.gapAt(i));
    try equal(-40, bed.gapAt(25));
    try equal([4]f32{ 20, 20, 20, 20 }, bed.dropRadii(6));
    for ([_]f32{ 0, -40 }) |gap| try equal([4]f32{ 20, 20, 0, 0 }, bed.dropRadii(gap));
    try equal(36, bed.mergeAt(6));
    try equal(36, bed.mergeAt(0));
    try equal(0, bed.mergeAt(-40));
}

test "ghost maximum ignores darkening outside the inset bar" {
    var a: [8 * 8 * 4]u8 = @splat(255);
    const b = a;
    for (0..3) |c| {
        a[(3 * 8 + 3) * 4 + c] = 235;
        a[c] = 0;
    }
    const ghost = bed.ghostMax(&a, &b, 8, .{ .w = 8, .h = 8 }, null);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0 / 255.0), ghost.max, 0.000001);
    try equal(3, ghost.x);
    try equal(3, ghost.y);
}

test "ghost maximum ignores its hole" {
    var a: [16 * 16 * 4]u8 = @splat(255);
    const b = a;
    for (0..3) |c| {
        a[(8 * 16 + 8) * 4 + c] = 200;
        a[(3 * 16 + 3) * 4 + c] = 235;
    }
    const ghost = bed.ghostMax(&a, &b, 16, .{ .w = 16, .h = 16 }, .{ .x = 8, .y = 8, .w = 1, .h = 1 });
    try equal(3, ghost.x);
    try equal(3, ghost.y);
}

test "shadow scene: one step measuring the ring round the drop, inside the bar" {
    try equal(1, bed.steps(.shadow));
    const pictures = bed.shadowPictures(.{ .w = 1280, .h = 1024 }, 8);
    const bar = pictures.a.rect;
    try equal(bar, pictures.b[0].rect);
    const region = pictures.region;
    try expect(region.x >= bar.x and region.y >= bar.y and region.x + region.w <= bar.x + bar.w and region.y + region.h <= bar.y + bar.h);
    // The drop's fade ring is wider than what `ghostMax` keeps clear on both its sides.
    const measured = region.insetAll(bed.ghost_inset);
    const hole = pictures.hole.outsetAll(bed.ghost_inset);
    try equal(pictures.b[1].rect, pictures.hole);
    try expect(measured.x < hole.x and measured.y < hole.y);
    try expect(measured.x + measured.w > hole.x + hole.w and measured.y + measured.h > hole.y + hole.h);
}
