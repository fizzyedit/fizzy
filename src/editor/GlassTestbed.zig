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

/// The backend keeps health counters (fizzy's native backend does; the test backend does not).
const has_health = builtin.target.cpu.arch != .wasm32 and @hasDecl(dvui.backend, "Health");

/// `pair`: a drop meeting the bar, glass against glass. `shadow`: the shadow joined glass casts,
/// against the same outline drawn as one piece. `pulldown`: the console's pull-down sheet opening
/// and closing over a blur field, with what each frame cost.
pub const Scene = enum { pair, shadow, pulldown };
pub const Config = struct { scene: Scene, dir: []const u8 };
pub fn steps(scene: Scene) usize {
    return switch (scene) {
        .pair => 26,
        .shadow => 1,
        .pulldown => 42,
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

/// Points: how near the shadow scene's pieces come before their glass joins.
pub const shadow_merge: f32 = 12;
/// A rounded box, points.
pub const Box = struct { rect: dvui.Rect, radius: f32 };
/// The shadow scene's one step, "inside": picture A (the bar), picture B (the bar with a drop
/// joined wholly inside it) and the region where B's shadow must be A's, less the hole the
/// drop's own glass fills. Points.
pub const ShadowPictures = struct {
    a: Box,
    b: [2]Box,
    region: dvui.Rect,
    hole: dvui.Rect,
};
/// The pictures centred in `window`, for a shadow that fades over `fade` points
/// (`dialogs.surfaceShadow`'s). A drop wholly inside the bar casts nothing: the joined outline
/// is the bar's.
pub fn shadowPictures(window: dvui.Rect, fade: f32) ShadowPictures {
    const bar: Box = .{ .rect = .{ .x = (window.w - 340) / 2, .y = (window.h - 64) / 2, .w = 340, .h = 64 }, .radius = 24 };
    const drop: Box = .{ .rect = .{ .x = bar.rect.x + 150, .y = bar.rect.y + 12, .w = 40, .h = 40 }, .radius = 20 };
    return .{
        .a = bar,
        .b = .{ bar, drop },
        .region = drop.rect.outsetAll(fade).intersect(bar.rect),
        .hole = drop.rect,
    };
}

/// Points: the pull-down's phone-sized frame, centred in the window.
pub const pulldown_size: dvui.Size = .{ .w = 412, .h = 915 };
/// How open the pull-down is at `step`, 0…1: opening over the first 21 steps, closing over the rest.
pub fn openAt(step: usize) f32 {
    std.debug.assert(step < steps(.pulldown));
    const i: f32 = @floatFromInt(if (step < 21) step else 41 - step);
    return i / 20;
}
/// How far the input has come down from the bar at openness `o`, 0…1.
pub fn inputEntrance(o: f32) f32 {
    return smoothstep(o / 0.35);
}
/// How far the bubbles have come out of the bar at openness `o`, 0…1: after the input has mostly.
pub fn bubbleEntrance(o: f32) f32 {
    return smoothstep((o - 0.25) / 0.4);
}
fn smoothstep(x: f32) f32 {
    const t = std.math.clamp(x, 0, 1);
    return t * t * (3 - 2 * t);
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
    if (comptime has_health) core.widgets.BlurBackdrop.capture_count = &dvui.backend.Health.current.counts.captures;
    return .{ .config = config, .capture = .init(gpa), .rows = .init(gpa) };
}
pub fn deinit(self: *GlassTestbed) void {
    if (comptime has_health) core.widgets.BlurBackdrop.capture_count = null;
    self.paired.deinit(self.capture.gpa);
    self.capture.deinit();
    self.rows.deinit();
}

pub fn draw(self: *GlassTestbed) void {
    const rs = dvui.parentGet().screenRectScale(.{});
    const window = rs.rectFromPhysical(dvui.windowRectPixels());
    backdrop(rs, window);
    if (self.config.scene == .pulldown) {
        if (!self.warm()) return;
        self.drawPulldown(rs, window);
        self.serial = self.capture.request("");
        return;
    }
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
            const pictures = shadowPictures(window, core.dialogs.surfaceShadow().fade);
            const boxes: []const Box = if (self.host) &pictures.b else (&pictures.a)[0..1];
            for (boxes, 0..) |box, i| bubbles[i] = .{ .rect = rs.rectToPhysical(box.rect), .radius = box.radius * rs.s };
            len = boxes.len;
            opts = .{ .merge = shadow_merge, .shadow = 1 };
            self.region = rs.rectToPhysical(pictures.region);
            self.hole = rs.rectToPhysical(pictures.hole);
        },
        .pulldown => unreachable,
    }
    if (!self.warm()) return;
    core.dialogs.glassBubbles(dvui.Id.zero.update("glass-testbed"), bubbles[0..len], rs.s, opts);
    self.serial = self.capture.request("");
}

/// False while the glass program is still compiling: native programs compile on first use, and
/// their fallback frame is not measured.
fn warm(self: *GlassTestbed) bool {
    core.LiquidField.publishEnabled(true);
    if (core.LiquidField.ready()) return true;
    self.warmup_frames += 1;
    if (self.warmup_frames > 600) {
        std.log.err("glass testbed: liquid shader unavailable", .{});
        std.process.exit(1);
    }
    dvui.refresh(null, @src(), null);
    return false;
}

/// The console's pull-down at this step's openness, in its draw order: the field layer, the
/// content, the sheet layer. Picture B (`host`) leaves the bubbles, and their icons, out.
fn drawPulldown(self: *const GlassTestbed, rs: dvui.RectScale, window: dvui.Rect) void {
    const o = openAt(self.step);
    const frame: dvui.Rect = .{ .x = (window.w - pulldown_size.w) / 2, .y = (window.h - pulldown_size.h) / 2, .w = pulldown_size.w, .h = pulldown_size.h };
    const bar: dvui.Rect = .{ .x = frame.x + (frame.w - 380) / 2, .y = frame.y + 16, .w = 380, .h = 56 };
    const bar_bottom = bar.y + bar.h;
    const bar_x = bar.x + bar.w / 2;
    const bar_y = bar.y + bar.h / 2;

    // The page: a block of text lines, never changing.
    for (0..12) |i| {
        const width: f32 = if (i % 4 == 3) 0.55 else 1;
        rs.rectToPhysical(.{ .x = frame.x + 32, .y = bar_bottom + 40 + 8 * @as(f32, @floatFromInt(i)), .w = (frame.w - 64) * width, .h = 1 }).fill(.{}, .{ .color = .{ .color = .{ .r = 20, .g = 20, .b = 30, .a = 220 } } });
    }

    const open: dvui.Rect = .{ .x = frame.x + 20, .y = bar_bottom, .w = frame.w - 40, .h = frame.y + frame.h - 20 - bar_bottom };
    var field_rect = open;
    field_rect.h *= o;
    var field = core.glass.layer(dvui.Id.zero.update("glass-testbed-field"), .{
        .witness = 1,
        .reach = .{ .w = open.w * rs.s, .h = open.h * rs.s },
        .blur_field = .{ .rect = rs.rectToPhysical(field_rect), .feather = 24 * rs.s, .strength = smoothstep(o / 0.3) },
    });
    field.end();

    const e_in = inputEntrance(o);
    const e_b = bubbleEntrance(o);
    const cell_y = bar_bottom + 24 + 23;
    if (!self.host and e_b > 0.85) for (0..3) |i| {
        const cx = bar_x + 72 * (@as(f32, @floatFromInt(i)) - 1);
        rs.rectToPhysical(.{ .x = cx - 11, .y = cell_y - 11, .w = 22, .h = 22 }).fill(dvui.CornerRect.Physical.all(11 * rs.s), .{ .color = .{ .color = .{ .r = 30, .g = 30, .b = 40 } } });
    };

    var sheet = core.glass.layer(dvui.Id.zero.update("glass-testbed-sheet"), .{ .merge = 14, .shadow = 1 });
    defer sheet.end();
    _ = sheet.add(pill(rs, bar_x, bar_y, bar.w, bar.h, 1, 1));
    const input_y = std.math.lerp(bar_y, frame.y + frame.h - 16 - 22, e_in);
    _ = sheet.add(pill(rs, bar_x, input_y, 380, 44, 1, 1));
    if (!self.host) for (0..3) |i| {
        const cx = bar_x + 72 * (@as(f32, @floatFromInt(i)) - 1);
        _ = sheet.add(pill(rs, std.math.lerp(bar_x, cx, e_b), std.math.lerp(bar_y, cell_y, e_b), 46, 46, 0, e_b));
    };
}

/// A round-ended piece of the sheet, group 1, centred at (`cx`, `cy`). Points.
fn pill(rs: dvui.RectScale, cx: f32, cy: f32, w: f32, h: f32, blur: f32, lens: f32) core.glass.Item {
    return .{
        .shape = .{ .box = .{ .rect = rs.rectToPhysical(.{ .x = cx - w / 2, .y = cy - h / 2, .w = w, .h = h }), .radii = @splat(h / 2 * rs.s), .round = true } },
        .group = 1,
        .blur = blur,
        .lens = lens,
    };
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
    if (self.config.scene == .pulldown) {
        // Picture A's frame, which drew the whole sheet, as of its completed capture.
        if (!self.host) {
            var captures: u32 = 0;
            var program_px: u32 = 0;
            var passes: u32 = 0;
            var frame_ms: f32 = 0;
            if (comptime has_health) {
                const health = &dvui.backend.Health.current;
                captures = health.counts.captures;
                program_px = health.counts.program_px;
                passes = health.counts.passes;
                frame_ms = @as(f32, @floatFromInt(dvui.backend.c.SDL_GetTicksNS() -| health.frame_start_ns)) / std.time.ns_per_ms;
            }
            try self.rows.writer.print("{{\"scene\":\"pulldown\",\"step\":{d},\"open\":{d},\"captures\":{d},\"program_px\":{d},\"passes\":{d},\"frame_ms\":{d:.3}}}\n", .{ self.step, openAt(self.step), captures, program_px, passes, frame_ms });
            try cwd.writeFile(dvui.io, .{ .sub_path = try std.fs.path.join(arena, &.{ self.config.dir, "frames.jsonl" }), .data = self.rows.written() });
        }
    } else if (!self.host) {
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
                try self.rows.writer.print("{{\"scene\":\"shadow\",\"case\":\"inside\",\"dark_max\":{d},\"x\":{d},\"y\":{d}}}\n", .{ dark.max, dark.x, dark.y });
            },
            .pulldown => unreachable,
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
