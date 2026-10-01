//! Icons drawn as a cached texture rather than a replayed mesh.
//!
//! dvui tessellates a TVG icon into a triangle mesh once and replays that mesh every frame:
//! a dupe, a transform over every vertex, and a draw call of its own. The meshes are bigger
//! than they look — a stroked chevron is several hundred vertices — so a tree of rows with
//! two icons each spends more of the frame on icons than on anything else in it.
//!
//! Here the mesh is drawn once, into a texture the size the icon is drawn at, and every frame
//! after that is one textured quad: four vertices, keyed into dvui's texture cache, which keeps
//! it as long as it is drawn at least once a frame. dvui's own `iconWidth`/`IconWidget` do the
//! layout, so `icon` lays out exactly as `dvui.icon` and takes the same arguments.
//!
//! Colour is applied to the quad, not baked, whenever the icon is one flat colour — which is
//! nearly every icon fizzy draws. A colour that changes every frame (a hover ramp) then never
//! misses the cache; baking it would rebuild the texture per frame, which is worse than the
//! mesh. Icons with two colours, a gradient, or their own palette are baked as they are, and
//! a gradient falls through to dvui's mesh path, which knows how to sample it.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");

/// `dvui.icon`, drawn through the texture cache. Same layout, same options.
pub fn icon(src: std.builtin.SourceLocation, name: []const u8, tvg_bytes: []const u8, icon_opts: dvui.IconRenderOptions, opts: dvui.Options) void {
    var iw: dvui.IconWidget = undefined;
    iw.init(src, name, tvg_bytes, icon_opts, opts);
    defer iw.deinit();
    draw(&iw);
}

/// The draw half of `icon`, for a caller that has laid out an `IconWidget` itself. Replaces
/// `IconWidget.draw`, including its rule for tinting: white defaults tint with the widget's
/// text colour, an explicit `color_text` tints a custom rasterization.
pub fn draw(iw: *dvui.IconWidget) void {
    const rs = iw.data().parent.screenRectScale(iw.data().contentRect());
    var tex_opts: dvui.RenderTextureOptions = .{ .rotation = iw.data().options.rotationGet() };
    const white: ?dvui.ColorOrGradient = .white;
    if (std.meta.eql(iw.icon_opts.fill_color, white) and std.meta.eql(iw.icon_opts.stroke_color, white)) {
        tex_opts.colormod = iw.data().options.color(.text).toColor();
    } else if (iw.data().options.color_text) |ct| {
        tex_opts.colormod = ct.toColor();
    }
    render(iw.name, iw.tvg_bytes, rs, tex_opts, iw.icon_opts);
}

/// `dvui.renderIcon` through the texture cache. `opts.colormod` multiplies the result the way
/// it does for any texture.
pub fn render(name: []const u8, tvg_bytes: []const u8, rs: dvui.RectScale, opts: dvui.RenderTextureOptions, icon_opts: dvui.IconRenderOptions) void {
    renderRaster(name, tvg_bytes, rs, null, opts, icon_opts);
}

/// `render`, rasterized at `raster` pixels (its size at rest) and stretched to `rs` — for an icon
/// whose size animates. Rasterized at every size it passes through, it made a texture (and two
/// render-target switches) every frame of the animation; stretched a little either way, one
/// texture serves the whole of it. Null `raster` is `render`.
pub fn renderRaster(name: []const u8, tvg_bytes: []const u8, rs: dvui.RectScale, raster: ?dvui.Size.Physical, opts: dvui.RenderTextureOptions, icon_opts: dvui.IconRenderOptions) void {
    if (rs.s == 0 or rs.r.w < 1 or rs.r.h < 1) return;
    if (dvui.clipGet().intersect(rs.r).empty()) return;
    if (builtin.target.cpu.arch == .wasm32) {
        // The web backend draws a target-rendered icon soft and heavy (the ⌘ glyphs in the
        // menus were the tell); the mesh path is crisp there, and the web build has no
        // per-frame dylib cost to hide behind a texture. Native keeps the cache.
        dvui.renderIcon(name, tvg_bytes, rs, opts, icon_opts) catch {};
        return;
    }

    // Gradients are dvui's to sample across the mesh; don't second-guess them.
    if (isGradient(icon_opts.fill_color) or isGradient(icon_opts.stroke_color)) {
        dvui.renderIcon(name, tvg_bytes, rs, opts, icon_opts) catch {};
        return;
    }
    renderTextured(name, tvg_bytes, rs, raster orelse rs.r.size(), opts, icon_opts);
}

/// The icon soft: rasterized at `raster_px` (its height in pixels) and drawn stretched to `rs`
/// with smooth filtering, so the smaller the raster the more blurred — on every target, the web
/// included, where `renderRaster` draws the crisp mesh. For an icon coming into focus as the
/// glass it sits on forms. Sizes are kept to a few steps, so one coming sharp is rasterized a
/// handful of times rather than every frame.
pub fn renderSoft(name: []const u8, tvg_bytes: []const u8, rs: dvui.RectScale, raster_px: f32, opts: dvui.RenderTextureOptions, icon_opts: dvui.IconRenderOptions) void {
    if (rs.s == 0 or rs.r.w < 1 or rs.r.h < 1) return;
    if (dvui.clipGet().intersect(rs.r).empty()) return;
    const px = @max(2, @exp2(@round(@log2(@max(raster_px, 2)) * 2) / 2));
    renderTextured(name, tvg_bytes, rs, .{ .w = px * rs.r.w / rs.r.h, .h = px }, opts, icon_opts);
}

/// The icon from its cached texture at `size` pixels, drawn to `rs`.
fn renderTextured(name: []const u8, tvg_bytes: []const u8, rs: dvui.RectScale, size: dvui.Size.Physical, opts: dvui.RenderTextureOptions, icon_opts: dvui.IconRenderOptions) void {

    // One flat colour is drawn white and tinted on the quad, so the texture is shared by every
    // colour the icon is ever drawn in: fill and stroke the same, or one of them clear (a line
    // icon with no fill). Baked in its own colour instead, an icon whose colour animates — fading
    // in, lighting under the pointer — is rasterized again every frame it moves.
    var bake = icon_opts;
    var tint = opts;
    const fill = flat(icon_opts.fill_color);
    const stroke = flat(icon_opts.stroke_color);
    if (fill != null and stroke != null) {
        const f = fill.?;
        const k = stroke.?;
        const one: ?dvui.Color = if (std.meta.eql(f, k)) f else if (f.a == 0) k else if (k.a == 0) f else null;
        if (one) |c| {
            bake.fill_color = if (f.a == 0) .transparent else .white;
            bake.stroke_color = if (k.a == 0) .transparent else .white;
            tint.colormod = multiply(opts.colormod, c);
        }
    }

    // The texture is the icon at the size it is drawn (or rests at), in pixels.
    const h: u32 = @intFromFloat(@ceil(size.h));
    const w: u32 = @intFromFloat(@ceil(size.w));
    if (w == 0 or h == 0) return;
    // Its strokes at the scale of the size it is rasterized at, not the one it is drawn at.
    const raster_s = rs.s * size.h / rs.r.h;

    const key = cacheKey(tvg_bytes, w, h, bake);
    const tex = dvui.textureGetCached(key) orelse blk: {
        const made = rasterize(name, tvg_bytes, w, h, raster_s, bake) orelse {
            dvui.renderIcon(name, tvg_bytes, rs, opts, icon_opts) catch {};
            return;
        };
        dvui.textureAddToCache(key, made);
        break :blk made;
    };
    dvui.renderTexture(tex, rs, tint) catch {};
}

/// Draw the icon's mesh once, into a fresh target of `w`×`h` pixels. Immediate, whatever the
/// ambient rendering mode: a target is drawn now or not at all.
fn rasterize(name: []const u8, tvg_bytes: []const u8, w: u32, h: u32, scale: f32, icon_opts: dvui.IconRenderOptions) ?dvui.Texture {
    const target = dvui.Texture.Target.create(.{ .width = w, .height = h, .interpolation = .linear }) catch return null;
    const cw = dvui.currentWindow();
    const prev_rendering = dvui.renderingSet(true);
    defer _ = dvui.renderingSet(prev_rendering);
    const prev_alpha = dvui.alpha(1);
    defer dvui.alphaSet(prev_alpha);
    const prev_clip = dvui.clipGet();
    defer dvui.clipSet(prev_clip);

    var rt = cw.render_target;
    rt.texture = target;
    rt.offset = .{};
    const prev_target = dvui.renderTarget(rt);
    defer _ = dvui.renderTarget(prev_target);

    const size: dvui.Rect.Physical = .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
    dvui.clipSet(size);
    dvui.renderIcon(name, tvg_bytes, .{ .r = size, .s = scale }, .{}, icon_opts) catch {
        target.destroyLater();
        return null;
    };
    return dvui.textureFromTarget(target) catch null;
}

fn cacheKey(tvg_bytes: []const u8, w: u32, h: u32, icon_opts: dvui.IconRenderOptions) dvui.Texture.Cache.Key {
    var hasher = std.hash.Wyhash.init(0x1c0);
    hasher.update("fizzy_icon");
    hasher.update(std.mem.asBytes(&tvg_bytes.ptr));
    hasher.update(std.mem.asBytes(&tvg_bytes.len));
    hasher.update(std.mem.asBytes(&w));
    hasher.update(std.mem.asBytes(&h));
    hashColor(&hasher, icon_opts.fill_color);
    hashColor(&hasher, icon_opts.stroke_color);
    hasher.update(std.mem.asBytes(&icon_opts.stroke_width));
    return hasher.final();
}

fn hashColor(hasher: *std.hash.Wyhash, c: ?dvui.ColorOrGradient) void {
    const tag: u8 = if (c == null) 0 else 1;
    hasher.update(std.mem.asBytes(&tag));
    if (flat(c)) |col| hasher.update(std.mem.asBytes(&col));
}

fn isGradient(c: ?dvui.ColorOrGradient) bool {
    return if (c) |cg| cg == .gradient else false;
}

fn flat(c: ?dvui.ColorOrGradient) ?dvui.Color {
    const cg = c orelse return null;
    return switch (cg) {
        .color => |col| col,
        .gradient => null,
    };
}

/// Two tints in a row: the caller's `colormod` and the icon's own colour.
fn multiply(a: ?dvui.Color, b: dvui.Color) dvui.Color {
    const m = a orelse return b;
    return .{
        .r = @intCast((@as(u32, m.r) * b.r + 127) / 255),
        .g = @intCast((@as(u32, m.g) * b.g + 127) / 255),
        .b = @intCast((@as(u32, m.b) * b.b + 127) / 255),
        .a = @intCast((@as(u32, m.a) * b.a + 127) / 255),
    };
}
