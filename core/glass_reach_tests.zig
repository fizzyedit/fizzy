//! A growing glass layer and its capture size, on real dvui frames.
const std = @import("std");
const dvui = @import("dvui");
const glass = @import("glass");
const ink = @import("glass.zig");

const id: dvui.Id = @fromBackingInt(803);
const target: dvui.Size.Physical = .{ .w = 600, .h = 860 };
const frames = 17;

fn sizeAt(frame: usize) dvui.Size.Physical {
    const t = @as(f32, @floatFromInt(frame)) / (frames - 1);
    const left = 1 - t;
    const grow = 1 - left * left * left;
    return .{ .w = std.math.lerp(@as(f32, 80), target.w, grow), .h = std.math.lerp(@as(f32, 80), target.h, grow) };
}

fn drawFrame(frame: usize, reach: ?dvui.Size.Physical) !?dvui.Size {
    const size = sizeAt(frame);
    var layer = ink.layer(id, .{ .reach = reach });
    try std.testing.expect(layer.active());
    try std.testing.expectEqual(reach, ink.current().job.?.pane.reach);
    try std.testing.expect(layer.add(.{ .shape = .{ .box = .{
        .rect = .{ .x = 600 - size.w, .y = 0, .w = size.w, .h = size.h },
    } } }));
    layer.end();
    return dvui.dataGet(null, id, "_frost_cap", dvui.Size);
}

const Captures = struct {
    last: ?dvui.Size = null,
    changes: usize = 0,

    fn observe(self: *Captures, size: dvui.Size) void {
        if (self.last) |prev| {
            if (!std.meta.eql(prev, size)) self.changes += 1;
        }
        self.last = size;
    }
};

fn growingLayer(reach: ?dvui.Size.Physical) !Captures {
    var window = try dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 860 } });
    defer window.deinit();
    glass.LiquidField.readyInTest(true);
    var captures: Captures = .{};
    for (0..frames) |frame| {
        if (frame > 0) {
            const cw = dvui.currentWindow();
            _ = try cw.end(.{});
            try cw.begin(cw.frame_time_ns + 16 * std.time.ns_per_ms);
        }
        if (try drawFrame(frame, reach)) |cap| captures.observe(cap);
    }
    return captures;
}

test "a growing layer without reach makes new captures" {
    const captures = try growingLayer(null);
    if (captures.last != null) {
        std.debug.print("growing layer without reach: {d} capture changes\n", .{captures.changes});
        try std.testing.expect(captures.changes >= 3);
    } else {
        std.debug.print("headless layer: _frost_cap is absent; reach checked on the job\n", .{});
    }
}

test "a growing layer with reach keeps one capture" {
    const captures = try growingLayer(target);
    try std.testing.expectEqual(0, captures.changes);
    if (captures.last) |cap| {
        try std.testing.expect(cap.w >= target.w and cap.h >= target.h);
    }
}

test "capture sizes across a menu growth with and without reach" {
    var growing: Captures = .{};
    var reached: Captures = .{};
    for (0..frames) |frame| {
        const size = sizeAt(frame);
        // queuePane folds reach into need before captureSize; zero margin isolates growth.
        growing.observe(glass.BlurBackdrop.captureSize(growing.last orelse .{}, .{ .w = size.w, .h = size.h }));
        reached.observe(glass.BlurBackdrop.captureSize(reached.last orelse .{}, .{
            .w = @max(size.w, target.w),
            .h = @max(size.h, target.h),
        }));
    }
    std.debug.print("menu growth capture changes: without reach {d}, with reach {d}\n", .{ growing.changes, reached.changes });
    try std.testing.expect(growing.changes >= 3);
    try std.testing.expectEqual(0, reached.changes);
    try std.testing.expect(reached.last.?.w >= target.w and reached.last.?.h >= target.h);
}
