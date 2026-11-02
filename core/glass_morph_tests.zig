//! Glass morphs on real dvui frames, including interruption and motion preferences.
const std = @import("std");
const dvui = @import("dvui");
const glass = @import("glass");
const Morph = @import("glass.zig").Morph;
const Box = @import("glass.zig").Box;
const from: Box = .{ .rect = .{ .x = 100, .y = 100, .w = 40, .h = 40 }, .radii = @splat(20) };
const to: Box = .{ .rect = .{ .x = 200, .y = 300, .w = 300, .h = 200 }, .radii = @splat(12) };

fn frameAfter(level: f32) !void {
    const cw = dvui.currentWindow();
    _ = try cw.end(.{});
    try cw.begin(cw.frame_time_ns + 16 * std.time.ns_per_ms);
    glass.motion.publish(level, 0.5, false, false, 1);
}

fn landed(f: Morph.Frame, target: Box) !void {
    try std.testing.expectEqual(target.rect, f.box.rect);
    try std.testing.expectEqual(target.radii, f.box.radii);
    try std.testing.expectEqual(target.round, f.box.round);
    try std.testing.expectEqual(@as(f32, 1), f.t);
    try std.testing.expectEqual(@as(f32, 1), f.lens);
    try std.testing.expectEqual(@as(f32, 1), f.blur);
    try std.testing.expectEqual(@as(f32, 1), f.content_alpha);
    try std.testing.expect(!f.moving);
}

fn settle(m: *Morph, target: Box) !Morph.Frame {
    for (0..300) |_| {
        try frameAfter(1);
        const f = m.step(target, 0.016, 1, .{});
        if (!f.moving) return f;
    }
    return error.MorphDidNotSettle;
}

test "a morph grows from its source and lands exactly" {
    var test_window = try dvui.testing.init(.{});
    defer test_window.deinit();
    glass.motion.publish(1, 0.5, false, false, 1);
    var m: Morph = .{};
    m.start(from);
    const first = m.step(to, 0.016, 1, .{});
    try std.testing.expectEqual(from, first.box);
    try std.testing.expect(first.moving);
    try landed(try settle(&m, to), to);
}

test "the radii follow the size" {
    var test_window = try dvui.testing.init(.{});
    defer test_window.deinit();
    glass.motion.publish(1, 0.5, false, false, 1);
    var m: Morph = .{};
    m.start(from);
    var swung = false;
    for (0..300) |_| {
        const f = m.step(to, 0.016, 1, .{});
        swung = swung or f.t > 1;
        for (f.box.radii) |radius| try std.testing.expectApproxEqAbs(std.math.lerp(@as(f32, 20), 12, std.math.clamp(f.t, 0, 1)), radius, 1e-4);
        if (!f.moving) {
            try std.testing.expect(swung);
            return;
        }
        try frameAfter(1);
    }
    return error.MorphDidNotSettle;
}

test "a retarget turns it round without a jump" {
    var test_window = try dvui.testing.init(.{});
    defer test_window.deinit();
    glass.motion.publish(1, 0.5, false, false, 1);
    var m: Morph = .{};
    m.start(from);
    var previous: Morph.Frame = m.step(to, 0.016, 1, .{});
    for (0..6) |_| {
        try frameAfter(1);
        previous = m.step(to, 0.016, 1, .{});
    }
    const center_velocity = m.center.vel;
    const size_velocity = m.size.vel;
    try std.testing.expect(center_velocity.x > 0 and size_velocity.x > 0);
    try frameAfter(1);
    // Zero elapsed time isolates retargeting from acceleration during the spring's step.
    const turned = m.step(from, 0, 1, .{});
    try std.testing.expectEqual(center_velocity, m.center.vel);
    try std.testing.expectEqual(size_velocity, m.size.vel);
    try std.testing.expectEqual(previous.box, turned.box);
    try std.testing.expectEqual(previous.box, m.from);
    try landed(try settle(&m, from), from);
}

test "fast motion flattens the glass" {
    var test_window = try dvui.testing.init(.{});
    defer test_window.deinit();
    for ([_]f32{ 1, 0.5 }) |level| {
        glass.motion.publish(level, 0.5, false, false, 1);
        var m: Morph = .{};
        m.start(from);
        var fastest: f32 = 0;
        var fastest_lens: f32 = 1;
        var finished = false;
        for (0..300) |_| {
            const f = m.step(to, 0.016, 1, .{});
            const cv = m.center.vel;
            const sv = m.size.vel;
            const speed = @max(@sqrt(cv.x * cv.x + cv.y * cv.y), @sqrt(sv.x * sv.x + sv.y * sv.y));
            if (speed > fastest) {
                fastest = speed;
                fastest_lens = f.lens;
            }
            if (level == 0.5) {
                try std.testing.expectEqual(@as(f32, 1), f.lens);
                try std.testing.expect(f.box.rect.w <= to.rect.w and f.box.rect.h <= to.rect.h);
            }
            if (!f.moving) {
                try landed(f, to);
                finished = true;
                break;
            }
            try frameAfter(level);
        }
        try std.testing.expect(finished);
        if (level == 1) try std.testing.expect(fastest_lens < 1 - 0.5 * (Morph.Tune{}).flex);
        try frameAfter(level);
    }
}

test "motion off lands at once" {
    var test_window = try dvui.testing.init(.{});
    defer test_window.deinit();
    glass.motion.publish(0, 0.5, false, false, 1);
    var m: Morph = .{};
    m.start(from);
    try landed(m.step(to, 0.016, 1, .{}), to);
}

test "no start: the first step lands" {
    var test_window = try dvui.testing.init(.{});
    defer test_window.deinit();
    glass.motion.publish(1, 0.5, false, false, 1);
    var m: Morph = .{};
    try landed(m.step(to, 0.016, 1, .{}), to);
}
