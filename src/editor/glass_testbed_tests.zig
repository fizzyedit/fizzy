const std = @import("std");
const bed = @import("GlassTestbed.zig");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;

test "pair parsing requires a scene and output directory" {
    try std.testing.expectEqualStrings("/tmp/x", bed.parse("pair:/tmp/x").?.dir);
    try expect(bed.parse("pair") == null);
    try expect(bed.parse("nope:/tmp/x") == null);
    try expect(bed.parse("pair:") == null);
}

test "pair steps and drop geometry follow the console join" {
    try equal(26, bed.steps);
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
    const ghost = bed.ghostMax(&a, &b, 8, .{ .w = 8, .h = 8 });
    try std.testing.expectApproxEqAbs(@as(f32, 20.0 / 255.0), ghost.max, 0.000001);
    try equal(3, ghost.x);
    try equal(3, ghost.y);
}
