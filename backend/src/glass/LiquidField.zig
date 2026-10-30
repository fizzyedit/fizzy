//! One layer of liquid glass: rounded boxes that run together where they come close, drawn as
//! frosted, refracting glass in one pass at every pixel (`shaders/liquid_glass.fragment.hlsl`).
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
const builtin = @import("builtin");
const dvui = @import("dvui");
const programs = @import("programs.zig");
const liquid_glass = @import("liquid_glass.zig");
const glass_look = @import("glass_look");

const LiquidField = @This();

pub const max_shapes = 16;

/// Uniform vec4s before the shapes (`Uniforms`), and per shape.
const header_vec4s = 11;
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
/// The place the glass belongs to: a view's card, rounded or square. Its outside is one more
/// shape the others run into, so a shape near its outline joins the edge by a neck, metaball-like,
/// and its outline cuts the glass, so none of it crosses. Never drawn on its own: only the shapes,
/// and their necks where they come near the edge. It takes the program's last shape slot, so a
/// field with it holds one shape fewer.
edge: ?Edge = null,
/// Physical pixels: how far apart two shapes still bridge. 0 never joins.
merge_px: f32 = 0,
scale: f32 = 1,
/// The pane's colour, mixed with the frost: `(1 − mix) · frost + mix · tint`, as `BlurBackdrop.Pane`.
tint: ?dvui.Color = null,
mix: f32 = 0,
/// White over the whole of it after the mix, where it has a tint.
lift: f32 = 0,
/// How far the edge refracts, 0 (none) to 2 (`liquid_glass.Look.refraction`): the window's
/// frost (`core.dialogs.refraction`).
refraction: f32 = 1,
/// It carries text — a dialog, a menu — and takes the window's colour as the opacity has it
/// (`glass_look.forText`).
text: bool = false,
/// The window's own material (`tint`, the window's base colour, translucent): its colour in place
/// of what is behind it, as see-through as that colour is, so the desktop shows through it as it
/// does through the window round a card. Glass that reads as the window's edge reaching into a
/// card. Its tint is kept over the published look, as `surface`'s is.
window: bool = false,
/// Drawn as over an opaque window wherever it is (`publishOpaqueWindow`): glass that must be glass
/// even where the window is see-through behind it, as a place's corner button over the explorer,
/// which is the window's own material. Off, it is as see-through there as the window is.
solid: bool = false,
/// Its tint and mix are its own, kept over the look the app publishes (`core.material.publishLook`): glass that
/// must read as part of a surface, as a place's corner at rest does its card's fill.
surface: bool = false,
/// It is a lens over a picture of the caller's own (`drawPicture`): its middle the picture as it
/// is, only the band along its edge glass (`glass_look.forLens`).
lens: bool = false,
/// The look's light turned a quarter, to come from the top right rather than the top left at the
/// default angle: lit along the other diagonal, top right and bottom left, and shaded across top
/// left and bottom right. The glass program's only; the fallback without it (`liquid_glass`) keeps
/// its light at the top left. For glass whose edges that show face that way, as a piece in a
/// place's top-right corner does — its arc down and to the left, its cut up and to the right —
/// where the usual light would leave both in shade.
light_across: bool = false,
/// The look it is drawn with (`glass_look.Looks`), where it is not what its `lens` and `text` say.
role: ?glass_look.Role = null,

/// A place's outline (`edge`), physical: its rect and its corner radii, top-left, top-right,
/// bottom-right, bottom-left.
pub const Edge = struct {
    rect: dvui.Rect.Physical,
    radii: [4]f32 = @splat(0),
    /// Cut by the outline with an edge of its own there, rather than joined to the outside: a
    /// rim and a bend along the cut, as a piece of glass laid in the place, its edge against the
    /// place's, bending what lies along it (a focus ring, the place's border). Joined, the glass
    /// carries on past the outline as far as its light and bend go, and the cut shows neither.
    cut: bool = false,
};

/// Pixels past its place's outline the outside of the place begins: `EDGE_GAP` in the program.
const edge_gap: f32 = 1;

pub fn add(self: *LiquidField, shape: Shape) void {
    if (self.len >= max_shapes - 1 and self.edge != null) return;
    if (self.len >= max_shapes) return;
    self.shapes[self.len] = shape;
    self.len += 1;
}

/// What the shapes cover, with room for their bridges' swell.
pub fn bounds(self: *const LiquidField) dvui.Rect.Physical {
    var r: dvui.Rect.Physical = .{};
    for (self.shapes[0..self.len], 0..) |s, i| r = if (i == 0) s.rect else r.unionWith(s.rect);
    return self.withReach(r);
}

/// `r`, some shapes' rect, with room for what joins them: the bridges between them, and with an
/// edge, the neck to it (as far as a shape can be from the outline and still join it, half the
/// merge width), kept inside the place.
fn withReach(self: *const LiquidField, r: dvui.Rect.Physical) dvui.Rect.Physical {
    const e = self.edge orelse return r.outsetAll(self.merge_px * 0.25 + 1);
    return r.outsetAll(self.merge_px * 0.5 + 1).intersect(e.rect.outsetAll(1));
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

/// What the program reads, `uData` in `shaders/liquid_glass.fragment.hlsl`.
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
    /// `draw` sets it, in the frame; `pack` leaves it 0. Then Apple's lens: its colour fringe,
    /// a drop's diagonal light (0: a window's hairline), the band's widest (physical pixels).
    backdrop: [4]f32 = @splat(0),
    /// The look's brightness curves (`applyLook`): the wash at the shape's top and at its bottom,
    /// the sweep, the luminance ceiling. Identity: no wash, no sweep, a ceiling of 1.
    curves: [4]f32 = .{ 0, 0, 0, 1 },
    /// How dark the window's hairline edge is; then the lit edge's line width, its glow's width
    /// and the length of its falloff ramp (`rim_falloff` of `rim_extent`), physical pixels.
    widths: [4]f32 = .{ 0.85, 0, 0, 0 },
    /// The light (`glass_look.Look.light_angle`): the unit vector toward it, physical pixels, y
    /// down; its height; the far side's share of it. Packed on every look.
    light: [4]f32 = .{ -0.70710678, -0.70710678, 0.5, 0 },
    /// The lit edge: line, glow, shade, and how far the light runs along the outline from its lit
    /// corners (`rim_extent`, physical pixels). All 0: the lit edge is off, and a drop's edge
    /// reads only the light.
    edge: [4]f32 = @splat(0),
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
        .face = .{ if (self.window) 2 else std.math.clamp(self.mix, 0, 1), std.math.clamp(self.lift, 0, 1), if (self.tint != null) 1 else 0, if (has_sharp) 1 else 0 },
        .dither = .{ 1.0 / 255.0, 0, 0, 0 },
        .shapes = undefined,
    };
    // The light of the default look: on every field, a look or none.
    const lanes = self.edgeLanes(glass_look.inApp(1));
    u.light = lanes.light;
    u.edge = lanes.edge;
    u.widths[1..4].* = lanes.widths;
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
    if (self.edge) |e| {
        // In the last slot, flagged 2: the program reads it there, whatever the groups. Its glass is
        // the first shape's, where they meet.
        const first: Shape = if (self.len > 0) self.shapes[0] else .{ .rect = e.rect };
        u.shapes[max_shapes - 1] = .{
            .{ e.rect.x + e.rect.w / 2, e.rect.y + e.rect.h / 2, e.rect.w / 2, e.rect.h / 2 },
            e.radii,
            // 3: cut, with an edge of its own (`Edge.cut`); 2: joined to the outside.
            .{ first.blur, first.lens, 0, if (e.cut) 3 else 2 },
        };
    }
    return u;
}

/// `liquid_glass`'s rim line width, in points.
const rim_line_width: f32 = 0.8;

// ── Drawing ─────────────────────────────────────────────────────────────────────────────────────

/// The program, written once in `shaders/liquid_glass.fragment.hlsl` and compiled from it for every
/// backend (`scripts/compile-shaders.sh`, checked in CI): SPIR-V and DXIL for the native backend on
/// Vulkan and D3D12, Metal for it on macOS, GLSL ES 3.00 for the web. The binary forms are copied
/// out of the embed to be aligned: Vulkan takes SPIR-V as 32-bit words.
const compiled = struct {
    const spirv align(8) = @embedFile("shaders/compiled/spv/liquid_glass.fragment.spv").*;
    const dxil align(8) = @embedFile("shaders/compiled/dxil/liquid_glass.fragment.dxil").*;
};

var program: programs.Program = .from(.{
    .glsl = @embedFile("shaders/compiled/glsl/liquid_glass.fragment.glsl"),
    .msl = @embedFile("shaders/compiled/msl/liquid_glass.fragment.msl"),
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

const enabled_id: dvui.Id = @fromBackingInt(@intCast(glass_look.data_id_backing));

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

/// The app's looks this frame (`glass_look.Looks`: one per role, fizzy's from the window's opacity
/// where there is OS glass beside it to match, macOS), published once a frame before anything
/// draws: every field — dialogs, menus, drops — is drawn as its role's look says. Null (nothing
/// published: the web, a plugin's own window): the earlier glass, as each field's own tint, lift
/// and blur say. Every form of the program draws the lens — the GLSL, the Metal, and the SPIR-V and
/// DXIL compiled from the HLSL — as long as the last two are compiled again whenever the HLSL
/// changes (the commands are at its top). Apps call it as `core.material.publishLook`.
pub fn publishLook(looks: ?glass_look.Looks) void {
    if (dvui.current_window == null) return;
    if (looks) |l| dvui.dataSet(null, enabled_id, glass_look.data_key, l) else dvui.dataRemove(null, enabled_id, glass_look.data_key);
}

fn publishedLooks() ?glass_look.Looks {
    return dvui.dataGet(null, enabled_id, glass_look.data_key, glass_look.Looks);
}

/// The role a field is drawn as: its own (`role`), else what its `lens` and `text` flags say.
fn roleOf(self: *const LiquidField) glass_look.Role {
    return self.role orelse if (self.lens) .lens else if (self.text) .text else .drop;
}

/// The uniform lanes the light and the lit edge take from a look: `light`, `edge`, and `widths[1..]`.
const EdgeLanes = struct {
    light: [4]f32,
    edge: [4]f32,
    widths: [3]f32,
};

fn edgeLanes(self: *const LiquidField, l: glass_look.Look) EdgeLanes {
    var toward = glass_look.lightVector(l.light_angle);
    if (self.light_across) toward[0] = -toward[0];
    const s = self.scale;
    return .{
        .light = .{ toward[0], toward[1], l.light_height, l.rim_back },
        .edge = .{ l.rim_line, l.rim_glow, l.rim_shade, l.rim_extent * s },
        .widths = .{ l.rim_width * s, l.glow_width * s, std.math.clamp(l.rim_falloff, 0, 1) * l.rim_extent * s },
    };
}

/// `l` into what the program reads: the lens's own uniforms, and the tint, wash, clarity, rim
/// light and frost the look sets in place of the field's own. The bend follows the field's
/// `refraction` (2, the whole of it, where the look is published). Pure on the uniforms.
pub fn applyLook(self: *const LiquidField, u: *Uniforms, l: glass_look.Look) void {
    const bend_scale = std.math.clamp(self.refraction / 2, 0, 1);
    u.dither[1] = @max(l.bevel, 0.0001);
    u.dither[2] = l.bend * bend_scale;
    u.dither[3] = l.shade;
    u.backdrop[1] = l.dispersion;
    u.backdrop[2] = l.diagonal;
    u.backdrop[3] = l.bevel_cap * self.scale;
    u.rim[1] = l.clarity * bend_scale;
    u.rim[3] = l.rim;
    // A surface's or a window's colour is its own: it keeps its mix and lift, and no wash.
    if (!self.surface and !self.window) {
        u.face[0] = std.math.clamp(l.mix, 0, 1);
        u.face[1] = 0;
        u.curves[0] = std.math.clamp(l.wash_top, 0, 1);
        u.curves[1] = std.math.clamp(l.wash_bottom, 0, 1);
        u.curves[2] = std.math.clamp(l.sweep, 0, 1);
    }
    u.curves[3] = std.math.clamp(l.ceiling, 0, 1);
    const lanes = self.edgeLanes(l);
    u.widths = .{ l.edge_dark, lanes.widths[0], lanes.widths[1], lanes.widths[2] };
    u.light = lanes.light;
    u.edge = lanes.edge;
    for (u.shapes[0..self.len]) |*sh| sh[2][0] *= l.frost;
    if (self.edge != null) u.shapes[max_shapes - 1][2][0] *= l.frost;
}

/// Test seam: the testing backend has no glass program, so `ready` is false there and every
/// branch that turns on it goes unexercised. This makes `ready` answer `on` for the current
/// window (the flag lives in its data, so each test window starts unset). Draws nothing.
pub fn readyInTest(on: bool) void {
    if (!builtin.is_test) @compileError("LiquidField.readyInTest is for tests");
    dvui.dataSet(null, enabled_id, "_ready_in_test", on);
}

/// Whether `draw` would draw now: programs here, switched on, compiled.
pub fn ready() bool {
    if (builtin.is_test) {
        if (dvui.dataGet(null, enabled_id, "_ready_in_test", bool)) |on| return on;
    }
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
    u.backdrop[0] = if (opaqueWindow() or self.solid) 1 else 0;
    // And the glass the app's look makes of it this frame (`core.material.publishLook`).
    if (publishedLooks()) |looks| self.applyLook(&u, looks.get(self.roleOf()));
    const textures = [_]?*anyopaque{programs.handle(sharp)};
    if (!h.begin(id, &textures, textures.len, u.vec4s(), uniform_vec4s)) return false;
    defer h.end();
    for ([_]programs.Blend{ .punch, .add }) |pass| {
        h.blend(@backingInt(pass));
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
        r = self.withReach(r);
        if (r.empty()) continue;
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
    /// A drop's light at the point (`diagonal`, with the reach of `rim_extent`), before `lens` and
    /// the rim's strength: the program's `spec`.
    edge_spec: f32,
    /// The lit edge's line, glow and dark band at the point, 0 where `rim_line` is 0.
    edge_line: f32,
    edge_glow: f32,
    edge_shade: f32,
};

/// `sampleWith` the look the app published for this field's role, else the default.
pub fn sample(self: *const LiquidField, p: dvui.Point.Physical) Sample {
    const published = if (dvui.current_window != null) publishedLooks() else null;
    const l = if (published) |looks| looks.get(self.roleOf()) else glass_look.inApp(1);
    return self.sampleWith(p, l);
}

/// `shaders/liquid_glass.fragment.hlsl`'s field and its lit edge, line for line, over every
/// shape, drawn with `l`: for hit tests and tests. Change one with the other.
pub fn sampleWith(self: *const LiquidField, p: dvui.Point.Physical, l: glass_look.Look) Sample {
    const lanes = self.edgeLanes(l);
    const big = std.math.floatMax(f32);
    var d1: f32 = big;
    var d2: f32 = big;
    var m1: [3]f32 = @splat(0);
    var m2: [3]f32 = @splat(0);
    var f1: f32 = big;
    var f2: f32 = big;
    var o1: [2]f32 = @splat(0);
    var o2: [2]f32 = @splat(0);
    var al1: [2]f32 = @splat(0);
    var al2: [2]f32 = @splat(0);
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
        var al: [2]f32 = .{ 0, 0 };
        if (lanes.edge[3] > 0) {
            const box: [4]f32 = .{ c[0], c[1], half[0], half[1] };
            const toward: [2]f32 = .{ lanes.light[0], lanes.light[1] };
            al = .{
                alongEnd(.{ p.x, p.y }, box, radii, toward, lanes.edge[3], lanes.widths[2]),
                alongEnd(.{ p.x, p.y }, box, radii, .{ -toward[0], -toward[1] }, lanes.edge[3], lanes.widths[2]),
            };
        }
        if (d < d1) {
            d2 = d1;
            m2 = m1;
            al2 = al1;
            d1 = d;
            m1 = mat;
            al1 = al;
        } else if (d < d2) {
            d2 = d;
            m2 = mat;
            al2 = al;
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
    // The place (`edge`): its outside one more shape, its outline cutting the coverage.
    var in_place: f32 = -big;
    var place_out: [2]f32 = .{ 0, 0 };
    const cut = if (self.edge) |e| e.cut else false;
    if (self.edge) |e| {
        const c: [2]f32 = .{ e.rect.x + e.rect.w / 2, e.rect.y + e.rect.h / 2 };
        const half: [2]f32 = .{ e.rect.w / 2, e.rect.h / 2 };
        const lim = @min(half[0], half[1]);
        const radii: [4]f32 = .{ @min(e.radii[0], lim), @min(e.radii[1], lim), @min(e.radii[2], lim), @min(e.radii[3], lim) };
        var g: [2]f32 = undefined;
        in_place = roundBox(.{ p.x - c[0], p.y - c[1] }, half, radii, &g);
        place_out = g;
    }
    if (self.edge != null and !cut) {
        const d = edge_gap - in_place;
        const mat: [3]f32 = .{ m1[0], m1[1], 0 };
        if (d < d1) {
            d2 = d1;
            m2 = m1;
            al2 = al1;
            d1 = d;
            m1 = mat;
            al1 = .{ 0, 0 };
        } else if (d < d2) {
            d2 = d;
            m2 = mat;
            al2 = .{ 0, 0 };
        }
        const o: [2]f32 = .{ -place_out[0], -place_out[1] };
        if (d < f1) {
            f2 = f1;
            o2 = o1;
            f1 = d;
            o1 = o;
        } else if (d < f2) {
            f2 = d;
            o2 = o;
        }
    }
    const k = @max(self.merge_px, 0.0001);
    var wm: f32 = 0;
    var wf: f32 = 0;
    const d = smin(d1, d2, k, &wm);
    var f = smin(f1, f2, k, &wf);
    var out: [2]f32 = .{ std.math.lerp(o1[0], o2[0], wf), std.math.lerp(o1[1], o2[1], wf) };
    // Cut: where the place's outline is nearer than the shapes' own, the glass's edge is the cut.
    if (cut and in_place > f) {
        f = in_place;
        out = place_out;
    }
    const soft = @max(0, -f);
    const lens = std.math.lerp(m1[1], m2[1], wm);
    const reach = @min(@sqrt(out[0] * out[0] + out[1] * out[1]), 1);
    const along: [2]f32 = .{ std.math.lerp(al1[0], al2[0], wm) * reach, std.math.lerp(al1[1], al2[1], wm) * reach };
    const dist = @max(d, in_place);
    // A drop's light, and the lit edge (the program's `spec` and `litEdge` block).
    const af = @abs(out[0] * lanes.light[0] + out[1] * lanes.light[1]);
    const edge_spec = l.diagonal * @max(smoothstep(0.75, 1, af), @max(along[0], along[1]));
    var line: f32 = 0;
    var glow: f32 = 0;
    var shade: f32 = 0;
    if (lanes.edge[0] > 0) {
        const len2 = out[0] * out[0] + out[1] * out[1];
        const n2: [2]f32 = if (len2 > 1e-8) .{ out[0] / @sqrt(len2), out[1] / @sqrt(len2) } else .{ 0, 0 };
        const lf = n2[0] * lanes.light[0] + n2[1] * lanes.light[1];
        const pw = std.math.lerp(8, 1, lanes.light[2]);
        const back = lanes.light[3];
        const lit = std.math.pow(f32, @max(lf, 0), pw) + back * std.math.pow(f32, @max(-lf, 0), pw);
        const on = @min(lens, 1);
        const px = rim_line_width * self.scale * 1.25;
        line = lanes.edge[0] * @max(lit, @max(along[0], back * along[1])) * band(-dist, 0, lanes.widths[0]) * on;
        glow = lanes.edge[1] * lit * band(-dist, lanes.widths[0], lanes.widths[1]) * on;
        shade = lanes.edge[2] * (1 - @abs(lf)) * band(-dist, 0, 2 * px) * on;
    }
    return .{
        .d = dist,
        .coverage = std.math.clamp(0.5 - @max(d, in_place), 0, 1),
        .out = .{ .x = out[0], .y = out[1] },
        .steep = @exp(-soft / liquid_glass.depthPx(self.look(), rim)),
        .blur = std.math.lerp(m1[0], m2[0], wm),
        .lens = lens,
        .light = std.math.lerp(m1[2], m2[2], wm),
        .edge_spec = edge_spec,
        .edge_line = line,
        .edge_glow = glow,
        .edge_shade = shade,
    };
}

fn smoothstep(a: f32, b: f32, x: f32) f32 {
    const t = std.math.clamp((x - a) / (b - a), 0, 1);
    return t * t * (3 - 2 * t);
}

/// The program's `band`: a soft step in at `a`, then a fall over `w`.
fn band(x: f32, a: f32, w: f32) f32 {
    return smoothstep(a - 0.5, a + 0.5, x) * @exp(-@max(0, x - a) / @max(w, 1e-3));
}

/// The program's `alongEnd`: how far the light runs on from the place of a box (centre and half
/// size in `box`, corner radii `rad`) that faces `toward`, the unit vector toward the light: 1
/// there, a smoothstep to 0 at `ext`, over the last `ramp` (at least one pixel).
fn alongEnd(p: [2]f32, box: [4]f32, rad: [4]f32, toward: [2]f32, ext: f32, ramp: f32) f32 {
    const q: [2]f32 = .{ if (toward[0] < 0) -1 else 1, if (toward[1] < 0) -1 else 1 };
    const r = if (q[0] < 0) (if (q[1] < 0) rad[0] else rad[3]) else (if (q[1] < 0) rad[1] else rad[2]);
    const inner: [2]f32 = .{ @max(box[2] - r, 0), @max(box[3] - r, 0) };
    var at: [2]f32 = undefined;
    for (0..2) |i| {
        at[i] = if (@abs(toward[i]) < 1e-3)
            std.math.clamp(p[i], box[i] - inner[i], box[i] + inner[i]) + r * toward[i]
        else
            box[i] + q[i] * inner[i] + r * toward[i];
    }
    const dist = @sqrt((p[0] - at[0]) * (p[0] - at[0]) + (p[1] - at[1]) * (p[1] - at[1]));
    return 1 - smoothstep(@max(ext - @max(ramp, 1), 0), ext, dist);
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

// ── Tests ───────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;
const Point = dvui.Point.Physical;

/// A round-edged 200 x 100 card at (100, 50), corner radius 20 (points), at `scale`: its outline
/// follows the true normal, as a drop's does.
fn testCard(scale: f32) LiquidField {
    var f: LiquidField = .{ .scale = scale, .merge_px = 24 * scale };
    var sh = Shape{ .rect = .{ .x = 0, .y = 0, .w = 200 * scale, .h = 100 * scale }, .radii = @splat(20 * scale) };
    sh.round = true;
    f.add(sh);
    return f;
}

/// The point of the card's outline that faces `toward`, `inset` pixels inside it.
fn litPlace(f: *const LiquidField, toward: [2]f32, inset: f32) Point {
    const sh = f.shapes[0];
    const r = sh.radii[0];
    const qx: f32 = if (toward[0] < 0) -1 else 1;
    const qy: f32 = if (toward[1] < 0) -1 else 1;
    const cx = sh.rect.x + sh.rect.w / 2;
    const cy = sh.rect.y + sh.rect.h / 2;
    return .{
        .x = cx + qx * (sh.rect.w / 2 - r) + (r - inset) * toward[0],
        .y = cy + qy * (sh.rect.h / 2 - r) + (r - inset) * toward[1],
    };
}

fn dropLook() glass_look.Look {
    return glass_look.forDrops(glass_look.inApp(0.5));
}

test "the light packs on every look" {
    var f: LiquidField = .{};
    f.add(Shape.circle(.{ .x = 50, .y = 50 }, 40));
    const order = [_]u8{0};
    const area: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    var u = f.pack(area, false, &order);
    try testing.expectApproxEqAbs(@as(f32, -0.707), u.light[0], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, -0.707), u.light[1], 1e-3);
    try testing.expectEqual([4]f32{ 0, 0, 0, 0 }, u.edge);
    f.light_across = true;
    u = f.pack(area, false, &order);
    try testing.expectApproxEqAbs(@as(f32, 0.707), u.light[0], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, -0.707), u.light[1], 1e-3);
    var console = dropLook();
    console.light_angle = 119.6;
    f.applyLook(&u, console);
    f.light_across = false;
    var v = f.pack(area, false, &order);
    f.applyLook(&v, console);
    try testing.expectApproxEqAbs(@as(f32, 0.494), v.light[0], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, -0.870), v.light[1], 1e-3);
}

test "the lit edge is 0 inside a neck and rim_line at the outline" {
    var f: LiquidField = .{ .merge_px = 24 };
    for ([_]f32{ 0, 108 }) |x| {
        var sh = Shape{ .rect = .{ .x = x, .y = 0, .w = 100, .h = 60 }, .radii = @splat(12) };
        sh.round = true;
        f.add(sh);
    }
    var l = dropLook();
    l.rim_line = 0.8;
    l.rim_width = 20;
    l.rim_extent = 1e4;
    l.light_angle = 90;
    const neck = f.sampleWith(.{ .x = 104, .y = 30 }, l);
    try testing.expectApproxEqAbs(@as(f32, 0), neck.edge_line, 1e-4);
    // The top of the joined outline, half a pixel inside it, faces the light.
    const top = f.sampleWith(.{ .x = 50, .y = 0.5 }, l);
    try testing.expectApproxEqAbs(@as(f32, 0.8), top.edge_line, 0.05);
}

test "a symmetric neck's midline gives no NaN" {
    var f: LiquidField = .{ .merge_px = 24 };
    for ([_]f32{ 0, 108 }) |x| {
        f.add(.{ .rect = .{ .x = x, .y = 0, .w = 100, .h = 60 }, .radii = @splat(12) });
    }
    var l = dropLook();
    l.rim_line = 0.8;
    l.rim_glow = 0.5;
    l.glow_width = 6;
    l.rim_shade = 0.4;
    l.rim_extent = 30;
    var y: f32 = 5;
    while (y < 60) : (y += 11) {
        const s = f.sampleWith(.{ .x = 104, .y = y }, l);
        inline for (comptime std.meta.fieldNames(Sample)) |name| {
            const v = @field(s, name);
            switch (@typeInfo(@TypeOf(v))) {
                .float => try testing.expect(std.math.isFinite(v)),
                .@"struct" => {
                    try testing.expect(std.math.isFinite(v.x));
                    try testing.expect(std.math.isFinite(v.y));
                },
                else => unreachable,
            }
        }
    }
}

test "the light side is brighter than the far side" {
    const f = testCard(1);
    var l = dropLook();
    l.light_angle = 51.7;
    l.rim_line = 0.8;
    l.rim_glow = 0.5;
    l.rim_width = 1;
    l.glow_width = 20;
    l.rim_back = 0.3;
    const toward = glass_look.lightVector(51.7);
    // The glow lies just inside the line, so a pixel and a half in.
    const near = f.sampleWith(litPlace(&f, toward, 1.5), l);
    const far = f.sampleWith(litPlace(&f, .{ -toward[0], -toward[1] }, 1.5), l);
    try testing.expect(near.edge_line > far.edge_line);
    try testing.expect(near.edge_glow > 0);
    try testing.expectApproxEqAbs(@as(f32, 0.3), far.edge_glow / near.edge_glow, 0.05);
}

test "at 45 degrees the top-left and bottom-right corners are lit" {
    const f = testCard(1);
    var l = dropLook();
    l.diagonal = 0.6;
    l.rim_extent = 0;
    const r: f32 = 1.0 / @sqrt(2.0);
    const tl: [2]f32 = .{ -r, -r };
    const tr: [2]f32 = .{ r, -r };
    for ([_]f32{ 45, 135 }) |angle| {
        l.light_angle = angle;
        const lit_a: [2]f32 = if (angle == 45) tl else tr;
        const lit_b: [2]f32 = .{ -lit_a[0], -lit_a[1] };
        const dark_a: [2]f32 = if (angle == 45) tr else tl;
        const dark_b: [2]f32 = .{ -dark_a[0], -dark_a[1] };
        try testing.expectApproxEqAbs(@as(f32, 0.6), f.sampleWith(litPlace(&f, lit_a, 0), l).edge_spec, 0.02);
        try testing.expectApproxEqAbs(@as(f32, 0.6), f.sampleWith(litPlace(&f, lit_b, 0), l).edge_spec, 0.02);
        try testing.expect(f.sampleWith(litPlace(&f, dark_a, 0), l).edge_spec < 0.01);
        try testing.expect(f.sampleWith(litPlace(&f, dark_b, 0), l).edge_spec < 0.01);
    }
    for ([_]f32{ 0, 45 }) |angle| {
        l.light_angle = angle;
        try testing.expectEqual(@as(f32, 0), f.sampleWith(.{ .x = 100, .y = 0 }, l).edge_spec);
    }
}

/// The distance, in points, from the top left lit place of `f` to the top side's point at `x`.
fn chordTo(f: *const LiquidField, x: f32) f32 {
    const r: f32 = 1.0 / @sqrt(2.0);
    const from = litPlace(f, .{ -r, -r }, 0);
    return @sqrt((x - from.x) * (x - from.x) + from.y * from.y) / f.scale;
}

test "rim_extent runs the light along a straight side, and 1e4 lights it whole" {
    for ([_]f32{ 1, 2 }) |scale| {
        const f = testCard(scale);
        var l = dropLook();
        l.diagonal = 0.6;
        l.light_angle = 45;
        l.rim_extent = 1e4;
        const middle = f.sampleWith(.{ .x = 100 * scale, .y = 0 }, l);
        try testing.expectApproxEqAbs(@as(f32, 0.6), middle.edge_spec, 0.02);
        // Past the corner's arc (which lights a drop on its own, 15.7 points on) only the reach
        // is left: the first point under 0.01 is 24 points from the lit place.
        l.rim_extent = 24;
        var x: f32 = 20 * scale;
        while (x < 100 * scale) : (x += 0.05 * scale) {
            if (f.sampleWith(.{ .x = x, .y = 0 }, l).edge_spec < 0.01) break;
        }
        try testing.expectApproxEqAbs(@as(f32, 24), chordTo(&f, x), 1);
    }
}

test "rim_extent 0 is today's edge" {
    const joined = blk: {
        var f: LiquidField = .{ .merge_px = 24 };
        for ([_]f32{ 0, 108 }) |x| {
            var sh = Shape{ .rect = .{ .x = x, .y = 0, .w = 100, .h = 60 }, .radii = @splat(12) };
            sh.round = true;
            f.add(sh);
        }
        break :blk f;
    };
    for ([_]LiquidField{ testCard(1), joined }) |base| {
        for ([_]bool{ false, true }) |across| {
            var f = base;
            f.light_across = across;
            var l = dropLook();
            l.rim_extent = 0;
            const light = glass_look.lightVector(l.light_angle);
            const lx: f32 = if (across) -light[0] else light[0];
            for (0..40) |i| {
                for (0..20) |j| {
                    const p: Point = .{ .x = @as(f32, @floatFromInt(i)) * 5.4 + 0.3, .y = @as(f32, @floatFromInt(j)) * 3 - 1 };
                    const s = f.sampleWith(p, l);
                    const af = @abs(s.out.x * lx + s.out.y * light[1]);
                    try testing.expectApproxEqAbs(l.diagonal * smoothstep(0.75, 1, af), s.edge_spec, 1e-6);
                }
            }
        }
    }
}

test "rim_falloff shapes the fade, rim_extent ends it" {
    const falloffs = [_]f32{ 0, 0.25, 0.5, 1 };
    for ([_]f32{ 1, 2 }) |scale| {
        const f = testCard(scale);
        // For each falloff: the walk along the top side, in steps of a tenth of a point, from the
        // arc's end, and where it first falls under full light.
        var ramp_start: [falloffs.len]f32 = undefined;
        var prev: [1200]f32 = @splat(1);
        for (falloffs, 0..) |falloff, k| {
            var l = dropLook();
            l.diagonal = 0.6;
            l.rim_extent = 24;
            l.rim_falloff = falloff;
            var last: f32 = 1;
            var start: ?f32 = null;
            var ended: ?f32 = null;
            for (0..1200) |i| {
                const x = (20 + @as(f32, @floatFromInt(i)) * 0.05) * scale;
                const v = f.sampleWith(.{ .x = x, .y = 0 }, l).edge_spec;
                try testing.expect(v <= last + 1e-6);
                last = v;
                // A larger falloff is never brighter.
                try testing.expect(v <= prev[i] + 1e-6);
                prev[i] = v;
                const d = chordTo(&f, x);
                if (start == null and v < 0.6 * 0.99) start = d;
                if (ended == null and v < 0.001) ended = d;
            }
            try testing.expectApproxEqAbs(@as(f32, 24), ended.?, 1);
            ramp_start[k] = start.?;
            if (falloff == 0) try testing.expectApproxEqAbs(@as(f32, 23), start.?, 1);
            if (k > 0) try testing.expect(ramp_start[k] <= ramp_start[k - 1] + 0.1);
        }
        // With no reach, every falloff is main's.
        for (falloffs) |falloff| {
            var l = dropLook();
            l.rim_extent = 0;
            l.rim_falloff = falloff;
            const s = f.sampleWith(.{ .x = 60 * scale, .y = 0 }, l);
            try testing.expectEqual(@as(f32, 0), s.edge_spec);
        }
    }
}
