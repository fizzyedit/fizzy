const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
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
    try std.testing.expectEqualStrings("/tmp/z", bed.parse("pulldown:/tmp/z").?.dir);
    try equal(.pulldown, bed.parse("pulldown:/tmp/z").?.scene);
}

test "pulldown opens and closes symmetrically over 42 steps" {
    try equal(42, bed.steps(.pulldown));
    for (0..42) |i| try equal(bed.openAt(i), bed.openAt(41 - i));
    try equal(1, bed.openAt(20));
    try equal(1, bed.openAt(21));
    try equal(0, bed.openAt(0));
}

test "pulldown entrances run 0 to 1, the input well ahead of the bubbles" {
    try equal(0, bed.inputEntrance(0));
    try equal(1, bed.inputEntrance(1));
    try equal(0, bed.bubbleEntrance(0));
    try equal(1, bed.bubbleEntrance(1));
    try expect(bed.inputEntrance(0.25) > 0.5);
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

const window: dvui.Rect = .{ .w = 1280, .h = 1024 };
const one: dvui.RectScale = .{ .s = 1 };

test "pulldown: the calm metric's gaps lie outside every bubble's coverage when open" {
    const p = bed.pulldownAt(window, 1);
    const field = bed.pulldownField(p, one);
    for (p.gaps()) |gap| {
        for (p.bubbles) |b| try expect(gap.intersect(b).empty());
        var y = gap.y;
        while (y <= gap.y + gap.h) : (y += 1) {
            var x = gap.x;
            while (x <= gap.x + gap.w) : (x += 1) try equal(0, field.sampleWith(.{ .x = x, .y = y }, core.glass_look.inApp(1)).coverage);
        }
    }
}

test "pulldown: no neck while a bubble is inside the bar" {
    for ([_]f32{ 0, 0.25, 0.3 }) |o| {
        const p = bed.pulldownAt(window, o);
        const field = bed.pulldownField(p, one);
        for (0..3) |k| {
            try expect(p.bubbles[k].y <= p.bar.y + p.bar.h);
            try expect(!bed.neckAt(p, &field, one, k));
        }
    }
}

test "pulldown: each metric is null exactly where its definition says" {
    const gpa = std.testing.allocator;
    const w: usize = 1280;
    const len = w * 1024 * 4;
    const a = try gpa.alloc(u8, len);
    defer gpa.free(a);
    const bare = try gpa.alloc(u8, len);
    defer gpa.free(bare);
    for (0..len / 4) |i| {
        const x = i % w;
        const y = i / w;
        for (0..3) |c| {
            bare[i * 4 + c] = @intCast((x * 7 + y * 13) % 256);
            a[i * 4 + c] = @intCast((x * 3 + y * 5) % 256);
        }
        bare[i * 4 + 3] = 255;
        a[i * 4 + 3] = 255;
    }
    for (0..bed.steps(.pulldown)) |step| {
        const p = bed.pulldownAt(window, bed.openAt(step));
        const m = bed.measure(p, one, .{ .a = a, .b = bare, .bare = bare, .width = w }, 8);
        try equal(p.o == 1, m.calm != null);
        try equal(p.o >= 0.5, m.edge_ramp_pt != null);
        try equal(p.e_b >= 0.9, m.rim_min != null);
        try equal(p.e_b < 0.05, m.hidden_dark_max != null);
        for (m.neck, 0..) |n, k| if (p.neckPoint(k) == null) try expect(!n);
    }
}

test "pulldown scene: the field's blur fades in over at least 20 pt and keeps it once open" {
    // A smoothstep goes from 10 % to 90 % over 0.608 of its width (S1 line 1).
    try expect(0.608 * bed.field_feather_pt >= 20);
    // BlurField.fittedFeather caps the feather under half the field's height, about 600 pt open.
    try expect(bed.field_feather_pt < 600 / 2);
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
