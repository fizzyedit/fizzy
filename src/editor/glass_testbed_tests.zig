const std = @import("std");
const core = @import("core");
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

test "shadow scene: two steps, each measuring a region outside B's glass" {
    try equal(2, bed.steps(.shadow));
    const window: dvui.Rect = .{ .w = 1280, .h = 1024 };
    for (std.enums.values(bed.ShadowCase)) |case| {
        const pictures = bed.shadowPictures(case, window, 8, 0);
        const measured = pictures.region.insetAll(bed.ghost_inset);
        try expect(measured.w > 0 and measured.h > 0);
        try equal(1, pictures.pictureA().len);
        if (case == .inside) {
            // The ring round the drop, inside the bar, is measured.
            try expect(pictures.hole.?.w < measured.w and pictures.hole.?.h < measured.h);
            try expect(pictures.b[0].rect.contains(pictures.region.topLeft()));
            continue;
        }
        // The join bulges below the boxes, most in the overlap's middle: no corner or the middle
        // of what is measured is glass, at either window scale.
        for ([_]f32{ 1, 2 }) |s| {
            const rs: dvui.RectScale = .{ .s = s };
            const field = bed.shadowField(&pictures.b, rs);
            const region = bed.belowGlass(rs.rectToPhysical(pictures.region), &field);
            try equal(rs.rectToPhysical(pictures.region).h, region.h);
            const inner = region.insetAll(bed.ghost_inset);
            try expect(inner.w > 0 and inner.h > 0);
            const mid = inner.center();
            for ([_]dvui.Point.Physical{ inner.topLeft(), inner.topRight(), inner.bottomLeft(), inner.bottomRight(), mid, .{ .x = mid.x, .y = inner.y } }) |p| {
                try equal(0, field.sampleWith(p, core.glass_look.inApp(1)).coverage);
            }
        }
    }
}

test "the overlap's band starts below the join's bulge" {
    const pictures = bed.shadowPictures(.overlap, .{ .w = 1280, .h = 1024 }, 8, 0);
    const rs: dvui.RectScale = .{ .s = 1 };
    const field = bed.shadowField(&pictures.b, rs);
    const region = bed.belowGlass(rs.rectToPhysical(pictures.region), &field);
    // Without the move its top row would sample B's glass.
    try expect(field.sampleWith(.{ .x = pictures.region.center().x, .y = pictures.region.y + 0.5 }, core.glass_look.inApp(1)).coverage > 0);
    try expect(region.y >= pictures.region.y + bed.shadow_merge / 4);
}
