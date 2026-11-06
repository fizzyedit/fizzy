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
/// The pull-down: this frame is the bare picture, drawn once before step 0's A.
bare: bool = false,
/// The pull-down's bare picture, and picture A's frame cost, kept for the step's row.
bare_pixels: std.ArrayList(u8) = .empty,
cost: Cost = .{},
/// Where the pull-down was drawn, for measuring its pictures.
rs: dvui.RectScale = .{},
window: dvui.Rect = .{},

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

/// Points, LiquidField's `merge` for the pull-down's sheet.
pub const pulldown_merge: f32 = 14;
/// The pull-down at openness `o`, centred in `window`: where the draw puts each piece and where
/// the measurements look. Points.
pub const Pulldown = struct {
    o: f32,
    e_in: f32,
    e_b: f32,
    frame: dvui.Rect,
    bar: dvui.Rect,
    /// The blur field: the open area, as far down as the sheet has opened.
    field: dvui.Rect,
    /// Where the field reaches when wholly open.
    open: dvui.Rect,
    input: dvui.Rect,
    bubbles: [3]dvui.Rect,
    /// The bubbles' resting row, where their icons sit.
    cell_y: f32,

    /// The calm metric's squares, between neighbouring bubbles at rest.
    pub fn gaps(p: Pulldown) [2]dvui.Rect {
        const bar_x = p.bar.x + p.bar.w / 2;
        return .{
            .{ .x = bar_x - 36 - 6, .y = p.cell_y - 6, .w = 12, .h = 12 },
            .{ .x = bar_x + 36 - 6, .y = p.cell_y - 6, .w = 12, .h = 12 },
        };
    }
    /// Halfway between the bar's bottom edge and bubble `k`'s top edge, or null while the bubble
    /// has not cleared the bar.
    pub fn neckPoint(p: Pulldown, k: usize) ?dvui.Point {
        const bottom = p.bar.y + p.bar.h;
        const b = p.bubbles[k];
        if (b.y - bottom <= 0) return null;
        return .{ .x = b.x + b.w / 2, .y = (bottom + b.y) / 2 };
    }
};
pub fn pulldownAt(window: dvui.Rect, o: f32) Pulldown {
    const frame: dvui.Rect = .{ .x = (window.w - pulldown_size.w) / 2, .y = (window.h - pulldown_size.h) / 2, .w = pulldown_size.w, .h = pulldown_size.h };
    const bar: dvui.Rect = .{ .x = frame.x + (frame.w - 380) / 2, .y = frame.y + 16, .w = 380, .h = 56 };
    const bar_bottom = bar.y + bar.h;
    const bar_x = bar.x + bar.w / 2;
    const bar_y = bar.y + bar.h / 2;
    const open: dvui.Rect = .{ .x = frame.x + 20, .y = bar_bottom, .w = frame.w - 40, .h = frame.y + frame.h - 20 - bar_bottom };
    var field = open;
    field.h *= o;
    const e_in = inputEntrance(o);
    const e_b = bubbleEntrance(o);
    const cell_y = bar_bottom + 24 + 23;
    var bubbles: [3]dvui.Rect = undefined;
    for (&bubbles, 0..) |*b, i| {
        const cx = bar_x + 72 * (@as(f32, @floatFromInt(i)) - 1);
        b.* = centred(std.math.lerp(bar_x, cx, e_b), std.math.lerp(bar_y, cell_y, e_b), 46, 46);
    }
    return .{
        .o = o,
        .e_in = e_in,
        .e_b = e_b,
        .frame = frame,
        .bar = bar,
        .field = field,
        .open = open,
        .input = centred(bar_x, std.math.lerp(bar_y, frame.y + frame.h - 16 - 22, e_in), 380, 44),
        .bubbles = bubbles,
        .cell_y = cell_y,
    };
}
fn centred(cx: f32, cy: f32, w: f32, h: f32) dvui.Rect {
    return .{ .x = cx - w / 2, .y = cy - h / 2, .w = w, .h = h };
}

/// The CPU mirror of the sheet layer picture A draws: the bar, the input and the bubbles.
pub fn pulldownField(p: Pulldown, rs: dvui.RectScale) core.LiquidField {
    var field: core.LiquidField = .{ .scale = rs.s, .merge_px = pulldown_merge * rs.s };
    const pieces = [_]struct { dvui.Rect, f32, f32 }{ .{ p.bar, 1, 1 }, .{ p.input, 1, 1 }, .{ p.bubbles[0], 0, p.e_b }, .{ p.bubbles[1], 0, p.e_b }, .{ p.bubbles[2], 0, p.e_b } };
    for (pieces) |piece| {
        const item = pill(rs, piece[0], piece[1], piece[2]);
        const box = item.shape.box;
        field.add(.{ .rect = box.rect, .radii = box.radii, .round = box.round, .blur = item.blur, .lens = item.lens });
    }
    return field;
}
/// Whether the joined outline covers the point between the bar and bubble `k`: a neck.
pub fn neckAt(p: Pulldown, field: *const core.LiquidField, rs: dvui.RectScale, k: usize) bool {
    const at = p.neckPoint(k) orelse return false;
    return field.sampleWith(rs.pointToPhysical(at), core.glass_look.inApp(1)).coverage > 0.5;
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

/// What picture A's frame cost, from the backend's health counters.
const Cost = struct { captures: u32 = 0, program_px: u32 = 0, passes: u32 = 0, frame_ms: f32 = 0 };

/// One step's pictures, encoded RGBA of one size: A (the whole sheet), B (A without the bubbles)
/// and bare (the page alone).
pub const Pictures = struct { a: []const u8, b: []const u8, bare: []const u8, width: usize };
/// A pull-down step's numbers, each null where its picture shows nothing to measure.
pub const Metrics = struct {
    /// The page's contrast between the bubbles under the open field, against bare's. Only wholly open.
    calm: ?f32 = null,
    /// Points from 10 % to 90 % of A's difference from bare, across the field's left edge. Open half or more.
    edge_ramp_pt: ?f32 = null,
    /// The least luma step from a bubble's rim to its centre. Bubbles nearly out.
    rim_min: ?f32 = null,
    /// How much darker A is than B round the bar. Bubbles still hidden in it.
    hidden_dark_max: ?f32 = null,
    /// Whether the outline bridges the bar and each bubble.
    neck: [3]bool = @splat(false),
};

/// `shadow_reach`: points the sheet's shadow falls past its outline, fade and offset.
pub fn measure(p: Pulldown, rs: dvui.RectScale, pics: Pictures, shadow_reach: f32) Metrics {
    var m: Metrics = .{};
    if (p.o == 1) {
        var calm: f32 = std.math.floatMax(f32);
        for (p.gaps()) |gap| {
            const r = rs.rectToPhysical(gap);
            calm = @min(calm, contrast(pics.a, pics.width, r) / contrast(pics.bare, pics.width, r));
        }
        m.calm = calm;
    }
    if (p.o >= 0.5) {
        const y = rs.pointToPhysical(.{ .y = p.field.y + p.field.h / 2 }).y;
        m.edge_ramp_pt = edgeRamp(pics.a, pics.bare, pics.width, @intFromFloat(@max(y, 0))) / rs.s;
    }
    if (p.e_b >= 0.9) {
        var rim: f32 = std.math.floatMax(f32);
        for (p.bubbles) |b| rim = @min(rim, rimStep(pics.a, pics.width, rs.rectToPhysical(b)));
        m.rim_min = rim;
    }
    if (p.e_b < 0.05) {
        const around = rs.rectToPhysical(p.bar.outsetAll(shadow_reach));
        // `ghostMax(x, y)` is how much darker x is than y.
        m.hidden_dark_max = ghostMax(pics.a, pics.b, pics.width, around, null).max;
    }
    const field = pulldownField(p, rs);
    for (&m.neck, 0..) |*n, k| n.* = neckAt(p, &field, rs, k);
    return m;
}

fn luma(pixels: []const u8, i: usize) f32 {
    var y: f32 = 0;
    for ([_]f32{ 0.2126, 0.7152, 0.0722 }, 0..) |weight, channel| y += weight * @as(f32, @floatFromInt(pixels[i * 4 + channel])) / 255;
    return y;
}
/// The pixels whose centres lie in `r`, clipped to the picture: [x0, x1) × [y0, y1).
fn span(r: dvui.Rect.Physical, width: usize, height: usize) [4]usize {
    const x0: usize = @intFromFloat(std.math.clamp(@ceil(r.x - 0.5), 0, @as(f32, @floatFromInt(width))));
    const y0: usize = @intFromFloat(std.math.clamp(@ceil(r.y - 0.5), 0, @as(f32, @floatFromInt(height))));
    const x1: usize = @intFromFloat(std.math.clamp(@ceil(r.x + r.w - 0.5), @as(f32, @floatFromInt(x0)), @as(f32, @floatFromInt(width))));
    const y1: usize = @intFromFloat(std.math.clamp(@ceil(r.y + r.h - 0.5), @as(f32, @floatFromInt(y0)), @as(f32, @floatFromInt(height))));
    return .{ x0, y0, x1, y1 };
}
/// Luma max − min over `r`.
fn contrast(pixels: []const u8, width: usize, r: dvui.Rect.Physical) f32 {
    const s = span(r, width, pixels.len / 4 / width);
    var lo: f32 = 1;
    var hi: f32 = 0;
    for (s[1]..s[3]) |y| for (s[0]..s[2]) |x| {
        const l = luma(pixels, y * width + x);
        lo = @min(lo, l);
        hi = @max(hi, l);
    };
    return @max(hi - lo, 0);
}
/// Pixels from where |A − bare| on row `y` first reaches 10 % of its maximum to where it first
/// reaches 90 %, scanning in from the left: the field's left edge.
fn edgeRamp(a: []const u8, bare: []const u8, width: usize, y: usize) f32 {
    if (y >= a.len / 4 / width) return 0;
    var max: f32 = 0;
    for (0..width) |x| max = @max(max, @abs(luma(a, y * width + x) - luma(bare, y * width + x)));
    var low: ?usize = null;
    for (0..width) |x| {
        const d = @abs(luma(a, y * width + x) - luma(bare, y * width + x));
        if (low == null and d >= 0.1 * max) low = x;
        if (d >= 0.9 * max) return @floatFromInt(x - low.?);
    }
    return 0;
}
/// |mean luma of the 2 px ring inside the circle in `r` − mean of its centre's 6×6 px|.
fn rimStep(pixels: []const u8, width: usize, r: dvui.Rect.Physical) f32 {
    const height = pixels.len / 4 / width;
    const cx = r.x + r.w / 2;
    const cy = r.y + r.h / 2;
    const radius = @min(r.w, r.h) / 2;
    var ring: f32 = 0;
    var ring_n: f32 = 0;
    const s = span(r, width, height);
    for (s[1]..s[3]) |y| for (s[0]..s[2]) |x| {
        const d = std.math.hypot(@as(f32, @floatFromInt(x)) + 0.5 - cx, @as(f32, @floatFromInt(y)) + 0.5 - cy);
        if (d >= radius - 2 and d < radius) {
            ring += luma(pixels, y * width + x);
            ring_n += 1;
        }
    };
    var centre: f32 = 0;
    var centre_n: f32 = 0;
    const c = span(.{ .x = cx - 3, .y = cy - 3, .w = 6, .h = 6 }, width, height);
    for (c[1]..c[3]) |y| for (c[0]..c[2]) |x| {
        centre += luma(pixels, y * width + x);
        centre_n += 1;
    };
    if (ring_n == 0 or centre_n == 0) return 0;
    return @abs(ring / ring_n - centre / centre_n);
}

fn writePng(image: Capture.Image, path: []const u8, gpa: std.mem.Allocator) !void {
    var png: std.Io.Writer.Allocating = .init(gpa);
    defer png.deinit();
    try core.image.writePngToWriter(.{ .pixelsPMA = .{ .rgba = dvui.Color.PMA.sliceFromRGBA(@constCast(image.pixels)), .width = image.width, .height = image.height } }, &png.writer, 0);
    try std.Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = path, .data = png.written() });
}

pub fn init(config: Config, gpa: std.mem.Allocator) GlassTestbed {
    return .{ .config = config, .capture = .init(gpa), .rows = .init(gpa), .bare = config.scene == .pulldown };
}
pub fn deinit(self: *GlassTestbed) void {
    self.paired.deinit(self.capture.gpa);
    self.bare_pixels.deinit(self.capture.gpa);
    self.capture.deinit();
    self.rows.deinit();
}

pub fn draw(self: *GlassTestbed) void {
    const rs = dvui.parentGet().screenRectScale(.{});
    const window = rs.rectFromPhysical(dvui.windowRectPixels());
    backdrop(rs, window);
    if (self.config.scene == .pulldown) {
        if (!self.warm()) return;
        self.rs = rs;
        self.window = window;
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
/// The bare picture (`bare`) is the page alone: no field, no sheet.
fn drawPulldown(self: *const GlassTestbed, rs: dvui.RectScale, window: dvui.Rect) void {
    const p = pulldownAt(window, openAt(self.step));
    const bar_bottom = p.bar.y + p.bar.h;
    const bar_x = p.bar.x + p.bar.w / 2;

    // The page: a block of text lines, never changing.
    for (0..12) |i| {
        const width: f32 = if (i % 4 == 3) 0.55 else 1;
        rs.rectToPhysical(.{ .x = p.frame.x + 32, .y = bar_bottom + 40 + 8 * @as(f32, @floatFromInt(i)), .w = (p.frame.w - 64) * width, .h = 1 }).fill(.{}, .{ .color = .{ .color = .{ .r = 20, .g = 20, .b = 30, .a = 220 } } });
    }
    if (self.bare) return;

    var field = core.glass.layer(dvui.Id.zero.update("glass-testbed-field"), .{
        .witness = 1,
        .reach = .{ .w = p.open.w * rs.s, .h = p.open.h * rs.s },
        .blur_field = .{ .rect = rs.rectToPhysical(p.field), .feather = 24 * rs.s, .strength = smoothstep(p.o / 0.3) },
    });
    field.end();

    if (!self.host and p.e_b > 0.85) for (0..3) |i| {
        const cx = bar_x + 72 * (@as(f32, @floatFromInt(i)) - 1);
        rs.rectToPhysical(centred(cx, p.cell_y, 22, 22)).fill(dvui.CornerRect.Physical.all(11 * rs.s), .{ .color = .{ .color = .{ .r = 30, .g = 30, .b = 40 } } });
    };

    var sheet = core.glass.layer(dvui.Id.zero.update("glass-testbed-sheet"), .{ .merge = pulldown_merge, .shadow = 1 });
    defer sheet.end();
    _ = sheet.add(pill(rs, p.bar, 1, 1));
    _ = sheet.add(pill(rs, p.input, 1, 1));
    if (!self.host) for (p.bubbles) |b| {
        _ = sheet.add(pill(rs, b, 0, p.e_b));
    };
}

/// A round-ended piece of the sheet, group 1. `rect` in points.
fn pill(rs: dvui.RectScale, rect: dvui.Rect, blur: f32, lens: f32) core.glass.Item {
    return .{
        .shape = .{ .box = .{ .rect = rs.rectToPhysical(rect), .radii = @splat(@min(rect.w, rect.h) / 2 * rs.s), .round = true } },
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
    if (self.config.scene == .pulldown and self.bare) {
        try self.bare_pixels.resize(self.capture.gpa, image.pixels.len);
        @memcpy(self.bare_pixels.items, image.pixels);
        try writePng(image, try std.fs.path.join(arena, &.{ self.config.dir, "bare.png" }), self.capture.gpa);
        self.bare = false;
        dvui.refresh(null, @src(), null);
        return;
    }
    if (self.config.scene == .pulldown) {
        if (!self.host) {
            // Picture A's frame, which drew the whole sheet, as of its completed capture.
            if (comptime has_health) {
                const health = &dvui.backend.Health.current;
                self.cost = .{
                    .captures = health.counts.captures,
                    .program_px = health.counts.program_px,
                    .passes = health.counts.passes,
                    .frame_ms = @as(f32, @floatFromInt(dvui.backend.c.SDL_GetTicksNS() -| health.frame_start_ns)) / std.time.ns_per_ms,
                };
            }
            try self.paired.resize(self.capture.gpa, image.pixels.len);
            @memcpy(self.paired.items, image.pixels);
        } else {
            if (self.paired.items.len != image.pixels.len or self.bare_pixels.items.len != image.pixels.len) return error.FrameSizeChanged;
            const p = pulldownAt(self.window, openAt(self.step));
            const bs = core.dialogs.surfaceShadow();
            const m = measure(p, self.rs, .{ .a = self.paired.items, .b = image.pixels, .bare = self.bare_pixels.items, .width = image.width }, bs.fade + @max(@abs(bs.offset.x), @abs(bs.offset.y)));
            const c = self.cost;
            try self.rows.writer.print("{{\"scene\":\"pulldown\",\"step\":{d},\"open\":{d},\"calm\":{?d},\"edge_ramp_pt\":{?d},\"rim_min\":{?d},\"hidden_dark_max\":{?d},\"neck\":[{},{},{}],\"captures\":{d},\"program_px\":{d},\"passes\":{d},\"frame_ms\":{d:.3}}}\n", .{ self.step, p.o, m.calm, m.edge_ramp_pt, m.rim_min, m.hidden_dark_max, m.neck[0], m.neck[1], m.neck[2], c.captures, c.program_px, c.passes, c.frame_ms });
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
    const name = try arena.print("{s}-{d:0>3}.png", .{ if (self.host) "host" else "frame", self.step });
    try writePng(image, try std.fs.path.join(arena, &.{ self.config.dir, name }), self.capture.gpa);
    if (self.host) self.step += 1;
    self.host = !self.host;
    if (self.step == steps(self.config.scene)) std.process.exit(0);
    dvui.refresh(null, @src(), null);
}
