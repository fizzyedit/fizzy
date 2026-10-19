//! An orb (`plans/LIQUID_EDGE_PLAN.md`, "The orb system"): a control of glass that lies in a place,
//! drawn one way wherever it is. One material — the drop zones' glass (`DropZones`): the dialog
//! style's frost and tint, its whole lens and bright rim — and one shadow, a soft radial falloff
//! outside it on what it lies over.
//! A place's outline (`Options.place`) cuts it; a place with none (the explorer) has it whole.
//!
//! Its shape is `orb_geometry`'s, so a state becomes the next by geometry alone (`orb_geometry.lerp`):
//! the material and the shadow never change mid-way. Without the glass program the same shape is
//! filled as a polygon, cut by the place the same way, so the shape, its motion and its shadow are
//! the same with glass or without; only the material differs.
const std = @import("std");
const dvui = @import("dvui");
const geometry = @import("../orb_geometry.zig");
const dialogs = @import("../dialogs.zig");
const widgets = @import("../widgets.zig");
const glass_button = @import("glass_button.zig");

pub const Shape = geometry.Shape;

pub const Options = struct {
    /// The place it lies in: its outline cuts it (`LiquidField.edge`). Null: whole.
    place: ?widgets.LiquidField.Edge = null,
    /// How much of a lens it is, 0…1: its rim's bend and light. The drop zones': all of it.
    lens: f32 = 1,
    /// How frosted, 0 (what is behind, sharp) to 1. The drop zones': all of it.
    frost: f32 = 1,
    /// How much of the window's colour is in it, 0…1, over the dialog style's. Null: the style's,
    /// as every glass of the app has (the drop zones'). An orb that must read lighter or clearer than
    /// the rest of the glass sets it; none does yet.
    tint: ?f32 = null,
    /// White added over it, 0…1: lit under the pointer.
    light: f32 = 0,
    /// Its shadow's strength at its edge, 0…1, and how far it falls off, in points.
    shadow: f32 = 0.3,
    shadow_reach: f32 = 12,
    /// A signature of what lies under it (`BlurBackdrop.Pane.witness`): the frost is read again only
    /// when it changes. Null reads it every frame.
    witness: ?u64 = null,
    /// A drop's rim lit from the top right (`LiquidField.light_across`): an orb whose edges that
    /// show face across the usual light, as one in a place's top-right corner does.
    light_across: bool = false,
};

/// The orb at `shape` (physical), as `opts` says: its shadow on what it lies over, then its glass, or
/// without the glass program its shape filled. `id` keys its frost.
pub fn draw(id: dvui.Id, shape: Shape, scale: f32, opts: Options) void {
    const prev_clip = dvui.clipGet();
    defer dvui.clipSet(prev_clip);
    if (opts.place) |p| dvui.clipSet(prev_clip.intersect(p.rect));
    if (opts.shadow > 0) drawShadow(shape, scale, opts.shadow, opts.shadow_reach);
    const r = rectOf(shape);
    if (widgets.LiquidField.ready() and widgets.liquidFrost() != null) {
        // A round shape (a circle, a capsule) goes as a drop does, its edge bending along its own
        // outline: the drop zones' bright rim. Given its corners it would be a box's, flat to its
        // sides, and no rim shows round a circle.
        const full = @min(shape.half[0], shape.half[1]) - 0.5;
        const round = for (0..4) |i| {
            if (shape.radius(i) < full) break false;
        } else true;
        dialogs.glassBubbles(id, &.{.{ .rect = r, .radii = if (round) null else shape.radii, .lens = opts.lens, .blur = opts.frost, .light = opts.light }}, scale, .{
            .shadow = 0,
            .edge = opts.place,
            .tint = if (opts.tint != null) dialogs.style().chromeColor() else null,
            .mix = opts.tint orelse 1,
            .witness = opts.witness,
            .light_across = opts.light_across,
        });
        return;
    }
    // Without the glass program: the same shape, cut by its place the same way, in the dialogs'
    // fill (the colour glass falls back to), lit as the glass is.
    var pts: [160]geometry.Pt = undefined;
    var place_pts: [160]geometry.Pt = undefined;
    var out: [320]geometry.Pt = undefined;
    var scratch: [320]geometry.Pt = undefined;
    var poly = shape.outline(24, &pts);
    if (opts.place) |p| {
        const place = Shape.box(p.rect.x, p.rect.y, p.rect.w, p.rect.h, p.radii);
        poly = geometry.cut(poly, place.outline(16, &place_pts), &out, &scratch);
    }
    if (poly.len < 3) return;
    const fill = dialogs.dialogFill().lerp(.white, std.math.clamp(opts.light, 0, 1));
    var path: dvui.Path.Builder = .init(dvui.currentWindow().lifo());
    defer path.deinit();
    for (poly) |pt| path.addPoint(.{ .x = pt[0], .y = pt[1] });
    path.build().fillConvex(.{ .color = .{ .color = fill }, .fade = 1 });
}

/// The rect a shape's glass is drawn in.
pub fn rectOf(shape: Shape) dvui.Rect.Physical {
    return .{ .x = shape.center[0] - shape.half[0], .y = shape.center[1] - shape.half[1], .w = 2 * shape.half[0], .h = 2 * shape.half[1] };
}

/// A shape's own `witness`: what lies under a resting orb is what was there, so its frost is read
/// again only when it moves or the glass's style changes.
pub fn witness(shape: Shape) u64 {
    return glass_button.witness(rectOf(shape), 0);
}

/// The orb's shadow: a soft radial falloff from its outline outward, `strength` at the outline and
/// nothing `reach` points beyond it, drawn on what it lies over, under the glass, which covers what
/// is inside. Round shapes take it round; a box takes its largest inscribed circle's, which a panel
/// growing out of a round button keeps continuous — but which falls short of a long panel's sides:
/// an orb that becomes a panel (the picker, `plans/LIQUID_EDGE_PLAN.md`) wants a box's shadow here.
fn drawShadow(shape: Shape, scale: f32, strength_in: f32, reach_pt: f32) void {
    const r = @min(shape.half[0], shape.half[1]);
    if (r <= 0 or reach_pt <= 0) return;
    const strength = std.math.clamp(strength_in, 0, 1);
    const reach = reach_pt * scale;
    const outer = r + reach;
    const at = r / outer;
    const stops = [_]dvui.Gradient.Stop{
        .{ .color = dvui.Color.black.opacity(0), .offset = 0 },
        .{ .color = dvui.Color.black.opacity(0), .offset = @max(0, at - 0.02) },
        .{ .color = dvui.Color.black.opacity(strength), .offset = at },
        .{ .color = dvui.Color.black.opacity(strength * 0.35), .offset = at + (1 - at) * 0.4 },
        .{ .color = dvui.Color.black.opacity(0), .offset = 1 },
    };
    const box: dvui.Rect.Physical = .{ .x = shape.center[0] - outer, .y = shape.center[1] - outer, .w = 2 * outer, .h = 2 * outer };
    box.fill(.all(outer), .{ .color = .{ .gradient = .{ .radial = .{ .stops = &stops, .shape = .{ .circle = .{} }, .extent = .closest_side } } } });
}
