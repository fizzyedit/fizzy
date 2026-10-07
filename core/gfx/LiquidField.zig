//! One layer of liquid glass: rounded boxes that run together where they come close, drawn as
//! frosted, refracting glass in one pass at every pixel (`shaders/liquid_glass.glsl`).
//!
//! **What it is.** Each shape is a rounded box — a circle is a square rounded all the way, a
//! capsule a rect rounded across its short side. Their outlines are joined by a smooth minimum
//! (iq's quadratic, `merge_px` wide): far apart they are separate pieces of glass, within
//! `merge_px` of each other a bridge grows between them, and as they part it thins to a neck and
//! lets go — a drop splitting, or two running together. Only the two nearest shapes at a point
//! are joined, so however many crowd together the outline swells by at most `merge_px / 4`.
//!
//! **What it costs.** Nothing on the CPU worth the name: a quad per group of shapes that touch
//! (`clusters`) and some floats a frame. The meshed union this replaces (`liquid_blob`) built
//! tens of thousands of vertices a frame for the same picture.
//!
//! **What it looks like.** Today's panes, exactly, when there is one shape: the frost mixed with
//! the tint, the rim refracting what is just beyond the edge and clearer than the face, the lift
//! and the line of light round the border (`liquid_glass`, whose numbers it takes). What differs
//! between shapes — how blurred, how bent, how lit — blends across a bridge by each shape's share
//! of it, so the light on one bubble runs into the neck rather than stopping at a seam.
//!
//! **Drawing.** Inside a layer's `dvui.deferRender` job, after its capture: `draw` with the
//! frost and what it covers. False where the backend has no programs (`core.gfx.programs`) or the
//! program is not ready yet, and the caller draws its meshes instead, without the joins. A lens
//! over a picture of the caller's own (a magnifier) needs no capture: `drawPicture` queues itself.
//!
//! Layers do not join each other: a dialog over a drop is two layers, the dialog's capture taken
//! with the drop already on the frame.
const std = @import("std");
const dvui = @import("dvui");
const programs = @import("programs.zig");
const liquid_glass = @import("liquid_glass.zig");
const glass_look = @import("glass_look.zig");

const LiquidField = @This();

pub const max_shapes = 16;

/// Uniform vec4s before the shapes (`Uniforms`), and per shape.
const header_vec4s = 7;
const shape_vec4s = 3;

/// A piece of glass. Physical pixels, window coordinates.
pub const Shape = struct {
    rect: dvui.Rect.Physical,
    /// Corner radii: top-left, top-right, bottom-right, bottom-left. Clamped to half the
    /// shorter side, so `@splat(big)` is a circle or a capsule.
    radii: [4]f32 = @splat(0),
    /// 0 (the scene behind, sharp) to 1 (the frost): how far its blur has come in.
    blur: f32 = 1,
    /// 0…1 (past 1 while it overshoots): how much its edge bends, clears and lights.
    lens: f32 = 1,
    /// White added over it, 0…1 — lit, the bubble under the pointer.
    light: f32 = 0,
    /// The edge bends along the outline's own normal — round for a circle, as a drop is — rather
    /// than a pane's soft field of its four sides (`liquid_glass.fieldAt`), which never folds at a
    /// rect's corner but is square on a circle.
    round: bool = false,

    pub fn circle(c: dvui.Point.Physical, r: f32) Shape {
        return .{ .rect = .{ .x = c.x - r, .y = c.y - r, .w = 2 * r, .h = 2 * r }, .radii = @splat(r), .round = true };
    }
};

shapes: [max_shapes]Shape = undefined,
len: usize = 0,
/// Physical pixels: how far apart two shapes still bridge. 0 never joins.
merge_px: f32 = 0,
scale: f32 = 1,
/// The pane's colour, mixed with the frost: `(1 − mix) · frost + mix · tint`, as `BlurBackdrop.Pane`.
tint: ?dvui.Color = null,
mix: f32 = 0,
/// White over the whole of it after the mix, where it has a tint.
lift: f32 = 0,
/// How far the edge refracts, 0 (none) to 2 (`liquid_glass.Look.refraction`): the window's
/// roughness (`core.dialogs.refraction`).
refraction: f32 = 1,
/// It carries text — a dialog, a menu — and takes the window's colour as the opacity has it
/// (`glass_look.forText`).
text: bool = false,
/// It is a lens over a picture of the caller's own (`drawPicture`): its middle the picture as it
/// is, only the band along its edge glass (`glass_look.forLens`).
lens: bool = false,

pub fn add(self: *LiquidField, shape: Shape) void {
    if (self.len >= max_shapes) return;
    self.shapes[self.len] = shape;
    self.len += 1;
}

/// What the shapes cover, with room for their bridges' swell.
pub fn bounds(self: *const LiquidField) dvui.Rect.Physical {
    var r: dvui.Rect.Physical = .{};
    for (self.shapes[0..self.len], 0..) |s, i| r = if (i == 0) s.rect else r.unionWith(s.rect);
    return r.outsetAll(self.merge_px * 0.25 + 1);
}

// ── Groups ──────────────────────────────────────────────────────────────────────────────────────

/// The shapes in groups that touch — any two within `merge_px` are in one — each drawn as its own
/// quad, so glass with room between its pieces shades only where they are.
pub const Clusters = struct {
    /// Shape indices, a group's together.
    order: [max_shapes]u8 = undefined,
    /// Each group's first in `order` and how many; `count` of them.
    first: [max_shapes]u8 = undefined,
    size: [max_shapes]u8 = undefined,
    count: usize = 0,
};

pub fn clusters(self: *const LiquidField) Clusters {
    var parent: [max_shapes]u8 = undefined;
    for (0..self.len) |i| parent[i] = @intCast(i);
    const find = struct {
        fn f(p: *[max_shapes]u8, i: u8) u8 {
            var x = i;
            while (p[x] != x) x = p[x];
            return x;
        }
    }.f;
    const reach = self.merge_px * 0.5;
    for (0..self.len) |i| for (i + 1..self.len) |j| {
        const a = self.shapes[i].rect.outsetAll(reach);
        const b = self.shapes[j].rect.outsetAll(reach);
        if (a.intersect(b).empty()) continue;
        const ri = find(&parent, @intCast(i));
        const rj = find(&parent, @intCast(j));
        if (ri != rj) parent[rj] = ri;
    };
    var out: Clusters = .{};
    var n: u8 = 0;
    for (0..self.len) |root| {
        if (find(&parent, @intCast(root)) != root) continue;
        out.first[out.count] = n;
        var size: u8 = 0;
        for (0..self.len) |i| {
            if (find(&parent, @intCast(i)) != root) continue;
            out.order[n] = @intCast(i);
            n += 1;
            size += 1;
        }
        out.size[out.count] = size;
        out.count += 1;
    }
    return out;
}

// ── Uniforms ────────────────────────────────────────────────────────────────────────────────────

pub const uniform_vec4s = header_vec4s + shape_vec4s * max_shapes;

/// What the program reads, `uData` in `shaders/liquid_glass.glsl`.
pub const Uniforms = extern struct {
    /// Where the frost starts, and 1 / its size: physical pixels to its uv.
    frost_map: [4]f32,
    /// Merge width, the soft field's softness, the refraction's depth, the light's depth.
    depths: [4]f32,
    /// How far the rim reaches out, how clear it is, the rim line's width, how much light.
    rim: [4]f32,
    /// Premultiplied.
    tint: [4]f32,
    /// Mix, lift, has a tint, has the sharp picture.
    face: [4]f32,
    /// Dither amplitude; then Apple's lens (`applyLook`): the bending band's share of the shape's
    /// shorter half, how far it bends in bands, how much darker the folded band is. A band share of
    /// 0 is the earlier glass, pulled from outside.
    dither: [4]f32,
    /// 1 where the window is opaque behind its content (`publishOpaqueWindow`): the glass is
    /// then opaque, whatever the alpha of the picture it covers. The window's, not the field's:
    /// `draw` sets it, in the frame; `pack` leaves it 0. Then Apple's lens: its colour fringe, the
    /// light across its band, the band's widest (physical pixels).
    backdrop: [4]f32 = @splat(0),
    shapes: [max_shapes][shape_vec4s][4]f32,

    pub fn vec4s(self: *const Uniforms) [*]const [4]f32 {
        return @ptrCast(self);
    }
};

comptime {
    std.debug.assert(@sizeOf(Uniforms) == uniform_vec4s * 16);
}

fn look(self: *const LiquidField) liquid_glass.Look {
    return .{ .refraction = self.refraction };
}

/// The scale the rim is drawn at (`liquid_glass.rimScale`), fitted to the smallest shape: the
/// program's rim is one for the whole field, and on a smaller shape a rim sized for a bigger one
/// would be all rim. Every shape is glass whatever its size (`liquid_glass.fit`).
fn rimScale(self: *const LiquidField, depth_px: f32) f32 {
    var f: f32 = 1;
    for (self.shapes[0..self.len]) |sh| f = @min(f, liquid_glass.fit(sh.rect, depth_px));
    return self.scale * f;
}

/// The uniforms for drawing over `frost`, a picture of `covered`, the shapes in `order`: the
/// field's own, so they are worked out with no window — what the window behind it is, `draw` adds.
pub fn pack(self: *const LiquidField, covered: dvui.Rect.Physical, has_sharp: bool, order: []const u8) Uniforms {
    const s = self.scale;
    const tint: [4]f32 = if (self.tint) |t| blk: {
        const a = @as(f32, @floatFromInt(t.a)) / 255;
        break :blk .{ @as(f32, @floatFromInt(t.r)) / 255 * a, @as(f32, @floatFromInt(t.g)) / 255 * a, @as(f32, @floatFromInt(t.b)) / 255 * a, a };
    } else @splat(0);
    // The curve, its reach and its corners at the fitted scale; the rim line at the field's.
    const rim = self.rimScale(liquid_glass.depthPx(self.look(), s));
    const glow = self.rimScale(liquid_glass.falloff * s);
    var u: Uniforms = .{
        .frost_map = .{ covered.x, covered.y, 1 / @max(covered.w, 1), 1 / @max(covered.h, 1) },
        .depths = .{ self.merge_px, liquid_glass.softness * rim, liquid_glass.depthPx(self.look(), rim), liquid_glass.falloff * glow },
        .rim = .{ liquid_glass.refraction * rim * self.refraction, liquid_glass.clarity * @min(1, self.refraction), rim_line_width * s, @min(1, self.refraction) },
        .tint = tint,
        .face = .{ std.math.clamp(self.mix, 0, 1), std.math.clamp(self.lift, 0, 1), if (self.tint != null) 1 else 0, if (has_sharp) 1 else 0 },
        .dither = .{ 1.0 / 255.0, 0, 0, 0 },
        .shapes = undefined,
    };
    @memset(std.mem.asBytes(&u.shapes), 0);
    for (order, 0..) |i, slot| {
        const sh = self.shapes[i];
        const r = sh.rect;
        u.shapes[slot] = .{
            .{ r.x + r.w / 2, r.y + r.h / 2, r.w / 2, r.h / 2 },
            sh.radii,
            .{ sh.blur, sh.lens, sh.light, if (sh.round) 1 else 0 },
        };
    }
    return u;
}

/// `liquid_glass`'s rim line width, in points.
const rim_line_width: f32 = 0.8;

// ── Drawing ─────────────────────────────────────────────────────────────────────────────────────

/// The program for the native backend on Vulkan and D3D12, compiled by shadercross from
/// `shaders/liquid_glass.fragment.hlsl` (the commands are at its top). Copied out of the embed to
/// be aligned: Vulkan takes SPIR-V as 32-bit words.
const compiled = struct {
    const spirv align(8) = @embedFile("shaders/compiled/spv/liquid_glass.fragment.spv").*;
    const dxil align(8) = @embedFile("shaders/compiled/dxil/liquid_glass.fragment.dxil").*;
};

var program: programs.Program = .from(.{
    .glsl = @embedFile("shaders/liquid_glass.glsl"),
    .msl = @embedFile("shaders/liquid_glass.metal"),
    .spirv = &compiled.spirv,
    .dxil = &compiled.dxil,
}, .{ .textures = 1, .uniform_vec4s = uniform_vec4s });

/// Whether glass is drawn through the program at all — the app's switch (Settings → Debugging →
/// Glass renderer), published each frame, so the meshes can be compared against it.
pub fn publishEnabled(on: bool) void {
    if (dvui.current_window == null) return;
    dvui.dataSet(null, enabled_id, "_liquid_field", on);
}

fn enabled() bool {
    return dvui.dataGet(null, enabled_id, "_liquid_field", bool) orelse true;
}

const enabled_id: dvui.Id = @enumFromInt(0x6c69_7166);

/// Whether the window is opaque behind its content — no desktop material shows through it (Linux,
/// the web) — published each frame by the app. The glass is as see-through as what it covers
/// where the window is translucent over the desktop's material (macOS's vibrancy, Windows'
/// Acrylic); where it is opaque, the alpha in its picture is only the window's shape — its
/// rounded corners, the margin its shadow is drawn in — and glass near those edges, blurring that
/// alpha in, let whatever is behind the window through. Opaque, the glass is opaque.
pub fn publishOpaqueWindow(on: bool) void {
    if (dvui.current_window == null) return;
    dvui.dataSet(null, enabled_id, "_liquid_opaque_window", on);
}

fn opaqueWindow() bool {
    return dvui.dataGet(null, enabled_id, "_liquid_opaque_window", bool) orelse false;
}

/// The app's glass at the window's opacity and roughness this frame (`glass_look.inApp`), published
/// by the app before anything draws where there is OS glass beside it to match (macOS): every
/// field — dialogs, menus, drops — is drawn as it says, Apple's lens on the two sliders. Null
/// (nothing published: the web, a plugin's own window): the earlier glass, as each field's own
/// tint, lift and blur say. Every form of the program draws the lens — the GLSL, the Metal, and the
/// SPIR-V and DXIL compiled from the HLSL — as long as the last two are compiled again whenever the
/// HLSL changes (the commands are at its top).
pub fn publishLook(slider_look: ?glass_look.InApp) void {
    if (dvui.current_window == null) return;
    if (slider_look) |l| dvui.dataSet(null, enabled_id, "_liquid_look", l) else dvui.dataRemove(null, enabled_id, "_liquid_look");
}

fn publishedLook() ?glass_look.InApp {
    return dvui.dataGet(null, enabled_id, "_liquid_look", glass_look.InApp);
}

/// `look` into what the program reads: the lens's own uniforms, and the tint, lift, clarity, rim
/// light and frost the sliders set in place of the field's own. The bend follows the field's
/// `refraction` (2, the whole of it, where the look is published).
fn applyLook(self: *const LiquidField, u: *Uniforms, l: glass_look.InApp) void {
    const bend_scale = std.math.clamp(self.refraction / 2, 0, 1);
    u.dither[1] = @max(l.bevel, 0.0001);
    u.dither[2] = l.bend * bend_scale;
    u.dither[3] = l.shade;
    u.backdrop[1] = l.dispersion;
    u.backdrop[2] = l.bevel_light;
    u.backdrop[3] = l.bevel_cap * self.scale;
    u.rim[1] = l.clarity * bend_scale;
    u.rim[3] = l.rim;
    u.face[0] = std.math.clamp(l.mix, 0, 1);
    u.face[1] = std.math.clamp(l.lift, 0, 1);
    for (u.shapes[0..self.len]) |*sh| sh[2][0] *= l.frost;
}

/// Whether `draw` would draw now: programs here, switched on, compiled.
pub fn ready() bool {
    if (!enabled()) return false;
    const h = programs.hooks() orelse return false;
    return program.ready(h) != null;
}

/// Draw the shapes: `frost` a picture of `covered` (the blurred capture), `sharp` the same before
/// the blur where there is one. Each group of shapes is a quad drawn twice — punching its
/// coverage out of what is there, then adding the glass — which writes
/// `glass · coverage + what was there · (1 − coverage)`, colour and alpha: glass replaces what it
/// covers, as a frost does, with an anti-aliased edge. False, having drawn nothing, where there
/// is no program to draw with.
pub fn draw(self: *const LiquidField, frost: dvui.Texture, covered: dvui.Rect.Physical, sharp: ?dvui.Texture) bool {
    if (self.len == 0) return true;
    if (!enabled()) return false;
    const h = programs.hooks() orelse return false;
    const id = program.ready(h) orelse return false;
    const groups = self.clusters();
    var u = self.pack(covered, sharp != null, groups.order[0..self.len]);
    // The window behind the glass, published for this frame.
    u.backdrop[0] = if (opaqueWindow()) 1 else 0;
    // And the glass the sliders make of it this frame (`publishLook`).
    if (publishedLook()) |l| self.applyLook(&u, if (self.lens) glass_look.forLens(l) else if (self.text) glass_look.forText(l) else glass_look.forDrops(l));
    const textures = [_]?*anyopaque{programs.handle(sharp)};
    if (!h.begin(id, &textures, textures.len, u.vec4s(), uniform_vec4s)) return false;
    defer h.end();
    for ([_]programs.Blend{ .punch, .add }) |pass| {
        h.blend(@intFromEnum(pass));
        self.quads(groups, pass == .add, frost);
    }
    return true;
}

/// The shapes as a lens over a picture of the caller's own — a magnifier's zoom, a loupe — rather
/// than over what is behind them. `picture` is a picture of `covered` (physical pixels, window
/// coordinates), reaching `pictureMargin` past the shapes. Its middle is the picture as it is,
/// unblurred, untinted and unlit, so a colour picked through it is the colour under it; only the
/// band along its edge is glass (`lens`, `glass_look.forLens`). Where the app publishes no look
/// (the web), it is the earlier glass, its rim pulling from just outside the shape, which is what
/// the margin is for. Nothing under it is read, so it costs no capture.
///
/// Queued in order with the frame (`dvui.deferRender`), as every glass is, and drawn at full
/// alpha: glass replaces what it covers, and at part alpha it left a hole. `picture` must live
/// until the frame ends. False, having queued nothing, where there is no glass program (`ready`):
/// draw the picture some other way.
pub fn drawPicture(self: *const LiquidField, picture: dvui.Texture, covered: dvui.Rect.Physical) bool {
    if (self.len == 0) return true;
    if (!ready()) return false;
    const job = dvui.currentWindow().arena().create(PictureJob) catch return false;
    job.* = .{ .field = self.*, .picture = picture, .covered = covered };
    job.field.lens = true;
    job.field.tint = null;
    job.field.mix = 0;
    job.field.lift = 0;
    for (job.field.shapes[0..job.field.len]) |*sh| sh.blur = 0;
    dvui.deferRender(job, PictureJob.run);
    return true;
}

/// Physical pixels the picture `drawPicture` lays the glass over should reach past the shapes: as
/// far as the earlier glass's rim reaches out (`liquid_glass.margin`), at the strongest of its
/// shapes' lenses. Apple's lens pulls only from inside the shape and needs none of it.
pub fn pictureMargin(self: *const LiquidField) f32 {
    var lens: f32 = 0;
    for (self.shapes[0..self.len]) |sh| lens = @max(lens, sh.lens);
    return liquid_glass.margin(.{ .lens = lens, .refraction = self.refraction }, self.scale);
}

/// What `drawPicture` hands to the replay, in the frame's arena.
const PictureJob = struct {
    field: LiquidField,
    picture: dvui.Texture,
    covered: dvui.Rect.Physical,

    fn run(ctx: ?*anyopaque) void {
        const self: *PictureJob = @ptrCast(@alignCast(ctx orelse return));
        const prev_alpha = dvui.currentWindow().alpha;
        dvui.alphaSet(1);
        defer dvui.alphaSet(prev_alpha);
        _ = self.field.draw(self.picture, self.covered, null);
    }
};

/// One quad per group, its vertex colour telling the program which pass and which shapes.
fn quads(self: *const LiquidField, groups: Clusters, glass: bool, frost: dvui.Texture) void {
    const arena = dvui.currentWindow().arena();
    var b = dvui.Triangles.Builder.init(arena, 4 * groups.count, 6 * groups.count) catch return;
    defer b.deinit(arena);
    for (0..groups.count) |g| {
        const first = groups.first[g];
        const n = groups.size[g];
        var r = self.shapes[groups.order[first]].rect;
        for (groups.order[first..][0..n]) |i| r = r.unionWith(self.shapes[i].rect);
        r = r.outsetAll(self.merge_px * 0.25 + 1);
        const col: dvui.Color.PMA = .{ .r = if (glass) 255 else 0, .g = first, .b = n, .a = 255 };
        const base: dvui.Vertex.Index = @intCast(4 * g);
        for ([_]dvui.Point.Physical{ r.topLeft(), r.topRight(), r.bottomRight(), r.bottomLeft() }) |p| {
            // The uv is the point itself, in the window's pixels: where the program works out the
            // shapes. `renderTriangles` moves the position by the target's offset, never the uv.
            b.appendVertex(.{ .pos = p, .col = col, .uv = .{ p.x, p.y } });
        }
        b.appendTriangles(&.{ base, base + 1, base + 2, base, base + 2, base + 3 });
    }
    const tris = b.build_unowned();
    dvui.renderTriangles(tris, frost) catch {};
}

// ── The same on the CPU ─────────────────────────────────────────────────────────────────────────

/// The field at a point, as the program sees it: the joined outline's signed distance (negative
/// inside), its coverage, which way is out for the refraction, and how steep the glass is there.
pub const Sample = struct {
    d: f32,
    coverage: f32,
    out: dvui.Point.Physical,
    steep: f32,
    /// The blended material: blur, lens, light.
    blur: f32,
    lens: f32,
    light: f32,
};

/// `shaders/liquid_glass.glsl`'s field, line for line, over every shape: for hit tests and tests.
pub fn sample(self: *const LiquidField, p: dvui.Point.Physical) Sample {
    const big = std.math.floatMax(f32);
    var d1: f32 = big;
    var d2: f32 = big;
    var m1: [3]f32 = @splat(0);
    var m2: [3]f32 = @splat(0);
    var f1: f32 = big;
    var f2: f32 = big;
    var o1: [2]f32 = @splat(0);
    var o2: [2]f32 = @splat(0);
    const rim = self.rimScale(liquid_glass.depthPx(self.look(), self.scale));
    const soft_k = liquid_glass.softness * rim;
    for (self.shapes[0..self.len]) |sh| {
        const c: [2]f32 = .{ sh.rect.x + sh.rect.w / 2, sh.rect.y + sh.rect.h / 2 };
        const half: [2]f32 = .{ sh.rect.w / 2, sh.rect.h / 2 };
        var g: [2]f32 = undefined;
        const lim = @min(half[0], half[1]);
        const radii: [4]f32 = .{ @min(sh.radii[0], lim), @min(sh.radii[1], lim), @min(sh.radii[2], lim), @min(sh.radii[3], lim) };
        const d = roundBox(.{ p.x - c[0], p.y - c[1] }, half, radii, &g);
        const mat: [3]f32 = .{ sh.blur, sh.lens, sh.light };
        if (d < d1) {
            d2 = d1;
            m2 = m1;
            d1 = d;
            m1 = mat;
        } else if (d < d2) {
            d2 = d;
            m2 = mat;
        }
        var o: [2]f32 = g;
        const f = if (sh.round) d else softBox(.{ p.x, p.y }, c, half, soft_k, &o);
        if (f < f1) {
            f2 = f1;
            o2 = o1;
            f1 = f;
            o1 = o;
        } else if (f < f2) {
            f2 = f;
            o2 = o;
        }
    }
    const k = @max(self.merge_px, 0.0001);
    var wm: f32 = 0;
    var wf: f32 = 0;
    const d = smin(d1, d2, k, &wm);
    const f = smin(f1, f2, k, &wf);
    const soft = @max(0, -f);
    return .{
        .d = d,
        .coverage = std.math.clamp(0.5 - d, 0, 1),
        .out = .{ .x = std.math.lerp(o1[0], o2[0], wf), .y = std.math.lerp(o1[1], o2[1], wf) },
        .steep = @exp(-soft / liquid_glass.depthPx(self.look(), rim)),
        .blur = std.math.lerp(m1[0], m2[0], wm),
        .lens = std.math.lerp(m1[1], m2[1], wm),
        .light = std.math.lerp(m1[2], m2[2], wm),
    };
}

/// Whether `p` is on the glass.
pub fn hit(self: *const LiquidField, p: dvui.Point.Physical) bool {
    return self.len > 0 and self.sample(p).d <= 0;
}

/// Signed distance to a box of half-size `b` at the origin with corner radii `r` (tl, tr, br, bl;
/// y down), and which way is out, into `g`.
pub fn roundBox(p: [2]f32, b: [2]f32, r: [4]f32, g: *[2]f32) f32 {
    const rr = if (p[0] > 0) (if (p[1] > 0) r[2] else r[1]) else (if (p[1] > 0) r[3] else r[0]);
    const q: [2]f32 = .{ @abs(p[0]) - b[0] + rr, @abs(p[1]) - b[1] + rr };
    const sx: f32 = if (p[0] < 0) -1 else 1;
    const sy: f32 = if (p[1] < 0) -1 else 1;
    if (q[0] > 0 and q[1] > 0) {
        const len = @sqrt(q[0] * q[0] + q[1] * q[1]);
        g.* = .{ q[0] / len * sx, q[1] / len * sy };
    } else if (q[0] > q[1]) {
        g.* = .{ sx, 0 };
    } else {
        g.* = .{ 0, sy };
    }
    const outside = @sqrt(@max(q[0], 0) * @max(q[0], 0) + @max(q[1], 0) * @max(q[1], 0));
    return @min(@max(q[0], q[1]), 0) + outside - rr;
}

/// `liquid_glass.fieldAt`'s soft minimum of a box's four sides, signed (negative inside), and its
/// way out into `o`.
pub fn softBox(p: [2]f32, c: [2]f32, half: [2]f32, k: f32, o: *[2]f32) f32 {
    const d = [4]f32{ p[0] - c[0] + half[0], c[0] + half[0] - p[0], p[1] - c[1] + half[1], c[1] + half[1] - p[1] };
    const m = @min(@min(d[0], d[1]), @min(d[2], d[3]));
    var w: [4]f32 = undefined;
    var sum: f32 = 0;
    for (d, 0..) |di, i| {
        w[i] = @exp((m - di) / k);
        sum += w[i];
    }
    o.* = .{ (w[1] - w[0]) / sum, (w[3] - w[2]) / sum };
    return k * @log(sum) - m;
}

/// iq's quadratic smooth minimum of `a` and `b` over `k`, and how much of `b` is in it, into `m`.
pub fn smin(a: f32, b: f32, k: f32, m: *f32) f32 {
    const h = @max(k - @abs(a - b), 0) / k;
    m.* = h * h * 0.5;
    if (b < a) m.* = 1 - m.*;
    return @min(a, b) - h * h * k * 0.25;
}
