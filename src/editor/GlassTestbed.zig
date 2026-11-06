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
/// Where B is measured against A this step, and the hole in it B's own glass fills, physical.
region: dvui.Rect.Physical = .{},
hole: ?dvui.Rect.Physical = null,
field: core.LiquidField = .{},

/// `pair`: a drop meeting the bar, glass against glass. `shadow`: the shadow joined glass casts,
/// against the same outline drawn as one piece.
pub const Scene = enum { pair, shadow };
pub const Config = struct { scene: Scene, dir: []const u8 };
pub fn steps(scene: Scene) usize {
    return switch (scene) {
        .pair => 26,
        .shadow => std.enums.values(ShadowCase).len,
    };
}
/// "<scene>:<dir>".
pub fn parse(raw: []const u8) ?Config {
    const colon = std.mem.indexOfScalar(u8, raw, ':') orelse return null;
    const scene = std.meta.stringToEnum(Scene, raw[0..colon]) orelse return null;
    if (colon + 1 == raw.len) return null;
    return .{ .scene = scene, .dir = raw[colon + 1 ..] };
}
pub fn gapAt(step: usize) f32 {
    std.debug.assert(step < steps(.pair));
    return if (step == 25) -40 else 12 - @as(f32, @floatFromInt(step));
}
pub fn dropRadii(gap: f32) [4]f32 {
    return if (gap <= 0) .{ 20, 20, 0, 0 } else @splat(20);
}
pub fn mergeAt(gap: f32) f32 {
    const ct = std.math.clamp((gap + 40) / 9, 0, 1);
    return 36 * ct * ct;
}

/// The shadow scene's steps, in order.
pub const ShadowCase = enum { inside, overlap };
/// Points: how near the shadow scene's pieces come before their glass joins.
pub const shadow_merge: f32 = 12;
/// A rounded box, points.
pub const Box = struct { rect: dvui.Rect, radius: f32 };
/// A shadow step: picture A (one piece of glass), picture B (the same outline with a second
/// piece joined to it) and the region where B's shadow must be A's, less a hole B's own glass
/// fills. Points.
pub const ShadowPictures = struct {
    a: [2]Box = undefined,
    a_len: usize,
    b: [2]Box,
    region: dvui.Rect,
    hole: ?dvui.Rect = null,

    pub fn pictureA(self: *const ShadowPictures) []const Box {
        return self.a[0..self.a_len];
    }
};
/// `case`'s pictures centred in `window`, for a shadow that fades over `fade` and drops by
/// `offset` (points, `dialogs.surfaceShadow`'s).
pub fn shadowPictures(case: ShadowCase, window: dvui.Rect, fade: f32, offset: f32) ShadowPictures {
    switch (case) {
        // A drop wholly inside the bar casts nothing: the joined outline is the bar's.
        .inside => {
            const bar: Box = .{ .rect = .{ .x = (window.w - 340) / 2, .y = (window.h - 64) / 2, .w = 340, .h = 64 }, .radius = 24 };
            const drop: Box = .{ .rect = .{ .x = bar.rect.x + 150, .y = bar.rect.y + 12, .w = 40, .h = 40 }, .radius = 20 };
            return .{
                .a = .{ bar, undefined },
                .a_len = 1,
                .b = .{ bar, drop },
                .region = drop.rect.outsetAll(fade).intersect(bar.rect),
                .hole = drop.rect,
            };
        },
        // Two boxes overlapping by 40 pt cast one shadow, not two stacked under the overlap.
        .overlap => {
            const x = (window.w - 160) / 2;
            const y = (window.h - 60) / 2;
            return .{
                .a = .{ .{ .rect = .{ .x = x, .y = y, .w = 160, .h = 60 }, .radius = 20 }, undefined },
                .a_len = 1,
                .b = .{
                    .{ .rect = .{ .x = x, .y = y, .w = 100, .h = 60 }, .radius = 20 },
                    .{ .rect = .{ .x = x + 60, .y = y, .w = 100, .h = 60 }, .radius = 20 },
                },
                .region = .{ .x = x + 60, .y = y + 60, .w = 40, .h = fade + offset },
            };
        },
    }
}

/// `boxes` as `glassBubbles` joins them, placed by `rs`.
pub fn shadowField(boxes: []const Box, rs: dvui.RectScale) core.LiquidField {
    var field: core.LiquidField = .{ .scale = rs.s, .merge_px = shadow_merge * rs.s };
    for (boxes) |box| field.add(.{ .rect = rs.rectToPhysical(box.rect), .radii = @splat(box.radius * rs.s), .round = true });
    return field;
}

/// `region` moved down, its height kept, until no pixel of it is glass `field` covers at all, its
/// antialiased edge included. The join bulges `merge / 4` below the boxes it joins, so a band
/// under them would otherwise measure B's glass as its shadow.
pub fn belowGlass(region: dvui.Rect.Physical, field: *const core.LiquidField) dvui.Rect.Physical {
    var out = region;
    out.y = @floor(region.y);
    while (rowCovered(out, field)) out.y += 1;
    return out;
}

fn rowCovered(region: dvui.Rect.Physical, field: *const core.LiquidField) bool {
    var x = @floor(region.x);
    while (x < region.x + region.w) : (x += 1) {
        if (field.sampleWith(.{ .x = x + 0.5, .y = region.y + 0.5 }, core.glass_look.inApp(1)).coverage > 0) return true;
    }
    return false;
}

pub const Ghost = struct { max: f32 = 0, x: usize = 0, y: usize = 0 };
/// Physical pixels `ghostMax` keeps clear of its rect's edges and its hole's, where edges blend.
pub const ghost_inset: f32 = 2;
/// Rec. 709 luma difference b − a on encoded RGBA, inside `rect` inset by `ghost_inset` and
/// outside `hole` outset by it.
pub fn ghostMax(a: []const u8, b: []const u8, width: usize, rect: dvui.Rect.Physical, hole: ?dvui.Rect.Physical) Ghost {
    std.debug.assert(a.len == b.len and a.len % (width * 4) == 0);
    var result: Ghost = .{};
    for (0..a.len / 4) |i| {
        const x = i % width;
        const y = i / width;
        const px = @as(f32, @floatFromInt(x)) + 0.5;
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        if (px < rect.x + ghost_inset or px >= rect.x + rect.w - ghost_inset or py < rect.y + ghost_inset or py >= rect.y + rect.h - ghost_inset) continue;
        if (hole) |h| if (px >= h.x - ghost_inset and px < h.x + h.w + ghost_inset and py >= h.y - ghost_inset and py < h.y + h.h + ghost_inset) continue;
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
    var bubbles: [2]core.dialogs.Bubble = undefined;
    var len: usize = 0;
    var opts: core.dialogs.BubblesOptions = undefined;
    switch (self.config.scene) {
        .pair => {
            const bar: dvui.Rect = .{ .x = (window.w - 340) / 2, .y = (window.h - 64) / 2, .w = 340, .h = 64 };
            self.region = rs.rectToPhysical(bar);
            const gap = gapAt(self.step);
            const drop: dvui.Rect = .{ .x = bar.x + 150, .y = bar.y - gap - 40, .w = 40, .h = 40 };
            var radii = dropRadii(gap);
            for (&radii) |*r| r.* *= rs.s;
            bubbles = .{
                .{ .rect = self.region, .radius = 24 * rs.s },
                .{ .rect = rs.rectToPhysical(drop), .radii = radii },
            };
            len = if (self.host) 1 else 2;
            opts = .{ .merge = mergeAt(gap), .shadow = 0 };
            self.field = .{ .len = 2, .scale = rs.s, .merge_px = mergeAt(gap) * rs.s, .refraction = core.dialogs.refraction() };
            self.field.shapes[0] = .{ .rect = self.region, .radii = @splat(24 * rs.s), .round = true };
            self.field.shapes[1] = .{ .rect = bubbles[1].rect, .radii = radii, .round = gap > 0 };
        },
        .shadow => {
            const bs = core.dialogs.surfaceShadow();
            const case: ShadowCase = @fromBackingInt(@intCast(self.step));
            const pictures = shadowPictures(case, window, bs.fade, bs.offset.y);
            const boxes = if (self.host) &pictures.b else pictures.pictureA();
            for (boxes, 0..) |box, i| bubbles[i] = .{ .rect = rs.rectToPhysical(box.rect), .radius = box.radius * rs.s };
            len = boxes.len;
            opts = .{ .merge = shadow_merge, .shadow = 1 };
            self.region = rs.rectToPhysical(pictures.region);
            // "inside" measures within B's glass on purpose; "overlap" measures only shadow.
            if (case == .overlap) {
                self.field = shadowField(&pictures.b, rs);
                self.region = belowGlass(self.region, &self.field);
            }
            self.hole = if (pictures.hole) |h| rs.rectToPhysical(h) else null;
        },
    }
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
    core.dialogs.glassBubbles(dvui.Id.zero.update("glass-testbed"), bubbles[0..len], rs.s, opts);
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
        switch (self.config.scene) {
            .pair => {
                const ghost = ghostMax(self.paired.items, image.pixels, image.width, self.region, null);
                var area: usize = 0;
                for (0..image.height) |y| for (0..image.width) |x| {
                    if (self.field.sampleWith(.{ .x = @as(f32, @floatFromInt(x)) + 0.5, .y = @as(f32, @floatFromInt(y)) + 0.5 }, core.glass_look.inApp(1)).coverage > 0.5) area += 1;
                };
                try self.rows.writer.print("{{\"step\":{d},\"gap_pt\":{d},\"k_px\":{d},\"area_px\":{d},\"ghost_max\":{d},\"ghost_x\":{d},\"ghost_y\":{d}}}\n", .{ self.step, gapAt(self.step), self.field.merge_px, area, ghost.max, ghost.x, ghost.y });
            },
            .shadow => {
                // B against A: how much darker B is.
                const dark = ghostMax(image.pixels, self.paired.items, image.width, self.region, self.hole);
                const case: ShadowCase = @fromBackingInt(@intCast(self.step));
                try self.rows.writer.print("{{\"scene\":\"shadow\",\"case\":\"{t}\",\"dark_max\":{d},\"x\":{d},\"y\":{d}}}\n", .{ case, dark.max, dark.x, dark.y });
            },
        }
        try cwd.writeFile(dvui.io, .{ .sub_path = try std.fs.path.join(arena, &.{ self.config.dir, "frames.jsonl" }), .data = self.rows.written() });
    }
    var png: std.Io.Writer.Allocating = .init(self.capture.gpa);
    defer png.deinit();
    try core.image.writePngToWriter(.{ .pixelsPMA = .{ .rgba = dvui.Color.PMA.sliceFromRGBA(@constCast(image.pixels)), .width = image.width, .height = image.height } }, &png.writer, 0);
    const name = try arena.print("{s}-{d:0>3}.png", .{ if (self.host) "host" else "frame", self.step });
    try cwd.writeFile(dvui.io, .{ .sub_path = try std.fs.path.join(arena, &.{ self.config.dir, name }), .data = png.written() });
    if (self.host) self.step += 1;
    self.host = !self.host;
    if (self.step == steps(self.config.scene)) std.process.exit(0);
    dvui.refresh(null, @src(), null);
}
