//! Writes paired frame-NNN.png/host-NNN.png pictures and frames.jsonl measurements.
//! The scene owns time: only completed A/B captures advance its step index.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const core = @import("core");
const Capture = @import("app").automation.Capture;
const GlassTestbed = @This();

config: Config,
capture: Capture,
step: usize = 0,
host: bool = false,
serial: u32 = 0,
warmup_frames: usize = 0,
paired: std.ArrayList(u8) = .empty,
rows: std.Io.Writer.Allocating,
bar: dvui.Rect.Physical = .{},
field: core.LiquidField = .{},

pub const Config = struct { dir: []const u8 };
pub const steps = 26;
pub fn parse(raw: []const u8) ?Config {
    if (!std.mem.startsWith(u8, raw, "pair:") or raw.len == 5) return null;
    return .{ .dir = raw[5..] };
}
pub fn gapAt(step: usize) f32 {
    std.debug.assert(step < steps);
    return if (step == 25) -40 else 12 - @as(f32, @floatFromInt(step));
}
pub fn dropRadii(gap: f32) [4]f32 {
    return if (gap <= 0) .{ 20, 20, 0, 0 } else @splat(20);
}
pub fn mergeAt(gap: f32) f32 {
    const ct = std.math.clamp((gap + 40) / 9, 0, 1);
    return 36 * ct * ct;
}

pub const Ghost = struct { max: f32 = 0, x: usize = 0, y: usize = 0 };
/// Rec. 709 luma difference on encoded RGBA, inside rect inset by two physical pixels.
pub fn ghostMax(a: []const u8, b: []const u8, width: usize, rect: dvui.Rect.Physical) Ghost {
    std.debug.assert(a.len == b.len and a.len % (width * 4) == 0);
    var result: Ghost = .{};
    for (0..a.len / 4) |i| {
        const x = i % width;
        const y = i / width;
        const px = @as(f32, @floatFromInt(x)) + 0.5;
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        if (px < rect.x + 2 or px >= rect.x + rect.w - 2 or py < rect.y + 2 or py >= rect.y + rect.h - 2) continue;
        var diff: f32 = 0;
        for ([_]f32{ 0.2126, 0.7152, 0.0722 }, 0..) |weight, channel| {
            diff += weight * (@as(f32, @floatFromInt(b[i * 4 + channel])) - @as(f32, @floatFromInt(a[i * 4 + channel]))) / 255;
        }
        if (diff > result.max) result = .{ .max = diff, .x = x, .y = y };
    }
    return result;
}

pub fn init(config: Config, gpa: std.mem.Allocator) GlassTestbed {
    return .{ .config = config, .capture = .init(gpa), .rows = .init(gpa) };
}
pub fn deinit(self: *GlassTestbed) void {
    self.paired.deinit(self.capture.gpa);
    self.capture.deinit();
    self.rows.deinit();
}

pub fn draw(self: *GlassTestbed) void {
    const rs = dvui.parentGet().screenRectScale(.{});
    const window = rs.rectFromPhysical(dvui.windowRectPixels());
    backdrop(rs, window);
    const bar: dvui.Rect = .{ .x = (window.w - 340) / 2, .y = (window.h - 64) / 2, .w = 340, .h = 64 };
    self.bar = rs.rectToPhysical(bar);
    const gap = gapAt(self.step);
    const drop: dvui.Rect = .{ .x = bar.x + 150, .y = bar.y - gap - 40, .w = 40, .h = 40 };
    var radii = dropRadii(gap);
    for (&radii) |*r| r.* *= rs.s;
    const bubbles = [_]core.dialogs.Bubble{
        .{ .rect = self.bar, .radius = 24 * rs.s },
        .{ .rect = rs.rectToPhysical(drop), .radii = radii },
    };
    self.field = .{ .len = 2, .scale = rs.s, .merge_px = mergeAt(gap) * rs.s, .refraction = core.dialogs.refraction() };
    self.field.shapes[0] = .{ .rect = self.bar, .radii = @splat(24 * rs.s), .round = true };
    self.field.shapes[1] = .{ .rect = bubbles[1].rect, .radii = radii, .round = gap > 0 };
    core.LiquidField.publishEnabled(true);
    // Native programs compile on first use. Do not measure their fallback frame.
    if (!core.LiquidField.ready()) {
        self.warmup_frames += 1;
        if (self.warmup_frames > 600) {
            std.log.err("glass testbed: liquid shader unavailable", .{});
            std.process.exit(1);
        }
        dvui.refresh(null, @src(), null);
        return;
    }
    core.dialogs.glassBubbles(dvui.Id.zero.update("glass-testbed"), bubbles[0..if (self.host) 1 else 2], rs.s, .{ .merge = mergeAt(gap), .shadow = 0 });
    self.serial = self.capture.request("");
}

fn backdrop(rs: dvui.RectScale, window: dvui.Rect) void {
    rs.rectToPhysical(window).fill(.{}, .{ .color = .{ .gradient = .{ .linear = .{
        .angle_degrees = 45,
        .stops = &.{
            .{ .offset = 0, .color = .{ .r = 26, .g = 54, .b = 100 } },
            .{ .offset = 1.0 / 3.0, .color = .{ .r = 180, .g = 96, .b = 130 } },
            .{ .offset = 2.0 / 3.0, .color = .{ .r = 225, .g = 188, .b = 100 } },
            .{ .offset = 1, .color = .{ .r = 55, .g = 155, .b = 150 } },
        },
    } } } });
    var pos: f32 = 0;
    while (pos < @max(window.w, window.h)) : (pos += 16) {
        const color: dvui.Color = .{ .r = 255, .g = 255, .b = 255, .a = 70 };
        if (pos < window.w) rs.rectToPhysical(.{ .x = pos, .w = 1, .h = window.h }).fill(.{}, .{ .color = .{ .color = color } });
        if (pos < window.h) rs.rectToPhysical(.{ .y = pos, .w = window.w, .h = 1 }).fill(.{}, .{ .color = .{ .color = color } });
    }
}

pub fn frameEnd(self: *GlassTestbed, picture: ?Capture.Source) void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    if (self.serial == 0) return;
    self.saveFrame(picture) catch |err| {
        std.log.err("glass testbed step {d}: {t}", .{ self.step, err });
        std.process.exit(1);
    };
}

fn saveFrame(self: *GlassTestbed, picture: ?Capture.Source) !void {
    const source = picture orelse return error.NoFrameTarget;
    self.capture.endFrame(&.{source});
    const image = self.capture.get(self.serial) orelse return error.CaptureMissing;
    if (image.width == 0 or image.height == 0) return error.CaptureEmpty;
    const arena = dvui.currentWindow().arena();
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(dvui.io, self.config.dir);
    if (!self.host) {
        try self.paired.resize(self.capture.gpa, image.pixels.len);
        @memcpy(self.paired.items, image.pixels);
    } else {
        if (self.paired.items.len != image.pixels.len) return error.FrameSizeChanged;
        const ghost = ghostMax(self.paired.items, image.pixels, image.width, self.bar);
        var area: usize = 0;
        for (0..image.height) |y| for (0..image.width) |x| {
            if (self.field.sampleWith(.{ .x = @as(f32, @floatFromInt(x)) + 0.5, .y = @as(f32, @floatFromInt(y)) + 0.5 }, core.glass_look.inApp(1)).coverage > 0.5) area += 1;
        };
        try self.rows.writer.print("{{\"step\":{d},\"gap_pt\":{d},\"k_px\":{d},\"area_px\":{d},\"ghost_max\":{d},\"ghost_x\":{d},\"ghost_y\":{d}}}\n", .{ self.step, gapAt(self.step), self.field.merge_px, area, ghost.max, ghost.x, ghost.y });
        try cwd.writeFile(dvui.io, .{ .sub_path = try std.fs.path.join(arena, &.{ self.config.dir, "frames.jsonl" }), .data = self.rows.written() });
    }
    var png: std.Io.Writer.Allocating = .init(self.capture.gpa);
    defer png.deinit();
    try core.image.writePngToWriter(.{ .pixelsPMA = .{ .rgba = dvui.Color.PMA.sliceFromRGBA(@constCast(image.pixels)), .width = image.width, .height = image.height } }, &png.writer, 0);
    const name = try arena.print("{s}-{d:0>3}.png", .{ if (self.host) "host" else "frame", self.step });
    try cwd.writeFile(dvui.io, .{ .sub_path = try std.fs.path.join(arena, &.{ self.config.dir, name }), .data = png.written() });
    if (self.host) self.step += 1;
    self.host = !self.host;
    if (self.step == steps) std.process.exit(0);
    dvui.refresh(null, @src(), null);
}
