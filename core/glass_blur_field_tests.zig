//! A feathered frost shares the layer's capture without contributing glass shapes.
const std = @import("std");
const dvui = @import("dvui");
const glass = @import("glass");
const ink = @import("glass.zig");

const id: dvui.Id = @fromBackingInt(804);
const field: ink.BlurField = .{ .rect = .{ .x = 20, .y = 20, .w = 400, .h = 600 }, .radius = 40, .feather = 48 };

fn drawField(f: ink.BlurField, boxes: usize, reach: ?dvui.Size.Physical) !void {
    var layer = ink.layer(id, .{ .blur_field = f, .reach = reach, .shadow = 0 });
    defer layer.end();
    try std.testing.expect(layer.active());
    try std.testing.expectEqual(f, ink.current().job.?.pane.blur_field.?);
    try std.testing.expectEqual(reach, ink.current().job.?.pane.reach);
    for (0..boxes) |i| {
        try std.testing.expect(layer.add(.{ .shape = .{ .box = .{
            .rect = .{ .x = 40 + @as(f32, @floatFromInt(i)) * 80, .y = 40, .w = 60, .h = 60 },
            .radii = @splat(12),
        } }, .group = 1 }));
    }
    layer.end();
}

test "a field alone makes one capture and no glass" {
    var window = try dvui.testing.init(.{});
    defer window.deinit();
    glass.LiquidField.readyInTest(true);
    const before = ink.drawnDetails();
    try drawField(field, 0, null);
    const details = ink.drawnDetails();
    try std.testing.expectEqual(1, details.jobs - before.jobs);
    try std.testing.expectEqual(1, details.captures - before.captures);
    try std.testing.expectEqual(0, details.shapes);
    try std.testing.expectEqual(0, details.fields);
}

test "a closed field costs nothing" {
    var window = try dvui.testing.init(.{});
    defer window.deinit();
    glass.LiquidField.readyInTest(true);
    var closed = field;
    closed.strength = 0;
    const before = ink.drawnDetails();
    try drawField(closed, 0, null);
    try std.testing.expectEqual(0, ink.drawnDetails().captures - before.captures);
}

test "a field under bubbles shares their capture" {
    var window = try dvui.testing.init(.{});
    defer window.deinit();
    glass.LiquidField.readyInTest(true);
    const before = ink.drawnDetails();
    try drawField(field, 3, null);
    const details = ink.drawnDetails();
    try std.testing.expectEqual(1, details.captures - before.captures);
    try std.testing.expectEqual(3, details.shapes);
    try std.testing.expectEqual(1, details.fields);
    if (dvui.dataGet(null, id, "_frost_job", glass.BlurBackdrop.FrostJob)) |job| {
        try std.testing.expectEqual(field, job.blur_field.?);
        try std.testing.expectEqual(field.rect, job.rect);
    }
}

test "a growing field with reach keeps one capture" {
    var window = try dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 860 } });
    defer window.deinit();
    glass.LiquidField.readyInTest(true);
    var last: ?dvui.Size = null;
    var changes: usize = 0;
    for (0..17) |frame| {
        if (frame > 0) {
            const cw = dvui.currentWindow();
            _ = try cw.end(.{});
            try cw.begin(cw.frame_time_ns + 16 * std.time.ns_per_ms);
        }
        const progress = @as(f32, @floatFromInt(frame)) / 16;
        var growing = field;
        growing.rect.h = 600 * progress;
        growing.strength = progress;
        try drawField(growing, 0, .{ .w = 400, .h = 600 });
        if (dvui.dataGet(null, id, "_frost_cap", dvui.Size)) |cap| {
            if (last) |prev| {
                if (!std.meta.eql(prev, cap)) changes += 1;
            }
            last = cap;
        }
    }
    try std.testing.expectEqual(0, changes);
    if (last) |cap| try std.testing.expect(cap.w >= 400 and cap.h >= 600);
}

test "no shadow or edge on the field" {
    var window = try dvui.testing.init(.{});
    defer window.deinit();
    glass.LiquidField.readyInTest(true);
    try drawField(field, 0, null);
    const details = ink.drawnDetails();
    try std.testing.expectEqual(0, details.fields);
    try std.testing.expectEqual(0, details.shapes);
}
