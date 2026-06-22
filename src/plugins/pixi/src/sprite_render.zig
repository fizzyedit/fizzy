//! Sprite/atlas rendering library for the pixel-art plugin.
//!
//! Heavy rendering on top of `core.Sprite` rects: layer compositing, file previews,
//! reflections, and water-surface meshes. Shell/workbench UI icons use
//! `pixi_mod.core_sprite.draw` from core instead of this module.
const std = @import("std");
const dvui = @import("dvui");
const pixi_mod = @import("../pixi.zig");
const runtime = @import("runtime.zig");

pub const SpriteInitOptions = struct {
    source: dvui.ImageSource,
    file: ?*pixi_mod.internal.File = null,
    alpha_source: ?dvui.ImageSource = null,
    sprite: pixi_mod.core_sprite,
    scale: f32 = 1.0,
    depth: f32 = 0.0, // -1.0 is front, 1.0 is back
    reflection: bool = false,
    overlap: f32 = 0.0,
    /// Overall opacity in [0, 1]; 1.0 is fully opaque. Used to fade cards out
    /// toward the background the further they sit from the focus.
    opacity: f32 = 1.0,
    /// Vertical shift (logical px, positive = down) applied to the reflection
    /// only. Lets the reflection slide away from the card — e.g. as a card flies
    /// up out of view, its reflection sinks down, like peeling off a waterline.
    reflection_offset: f32 = 0.0,
    /// Depth-lagged reflection grid (logical px); rows shear while scrolling and ripple on settle.
    reflection_lag: ?ReflectionLagSample = null,
    /// Reflection mesh density multiplier in (0, 1]. 1.0 = full per-zoom density;
    /// lower values coarsen the (O(n²)) mesh. Callers pass <1 for distant/skewed
    /// cards so only the head-on focus cards pay for a fine, high-res reflection.
    reflection_detail: f32 = 1.0,
};

/// Columns the reflection mesh samples across a card's width (waterline strip).
/// Matches `water_surface.cols_per_slot` (+1) so finer ripples render per card.
pub const reflection_surface_cols = pixi_mod.water_surface.reflection_surface_cols;

/// Reflection-only waterline sample across the card width (logical px). `cols_dx`
/// is horizontal refraction from surface slope; `cols_dy` is vertical height at
/// the seam (positive = down). The card itself stays flat — only the reflection
/// mesh pins its top edge and propagates ripples downward.
pub const ReflectionLagSample = struct {
    cols_dx: [reflection_surface_cols]f32 = .{0} ** reflection_surface_cols,
    cols_dy: [reflection_surface_cols]f32 = .{0} ** reflection_surface_cols,
};

pub fn sprite(src: std.builtin.SourceLocation, init_opts: SpriteInitOptions, opts: dvui.Options) dvui.WidgetData {
    const source_size: dvui.Size = dvui.imageSize(init_opts.source) catch .{ .w = 0, .h = 0 };

    const overlap: f32 = 1.0 - init_opts.overlap;

    const uv = dvui.Rect{
        .x = @as(f32, @floatFromInt(init_opts.sprite.source[0])) / source_size.w,
        .y = @as(f32, @floatFromInt(init_opts.sprite.source[1])) / source_size.h,
        .w = @as(f32, @floatFromInt(init_opts.sprite.source[2])) / source_size.w,
        .h = @as(f32, @floatFromInt(init_opts.sprite.source[3])) / source_size.h,
    };

    const options = (dvui.Options{ .name = "sprite" }).override(opts);

    var size = dvui.Size{};
    if (options.min_size_content) |msc| {
        // user gave us a min size, use it
        size = msc;
    } else {
        // user didn't give us one, use natural size
        size = .{ .w = @as(f32, @floatFromInt(init_opts.sprite.source[2])) * init_opts.scale * overlap, .h = @as(f32, @floatFromInt(init_opts.sprite.source[3])) * init_opts.scale * overlap };
    }

    var wd = dvui.WidgetData.init(src, .{}, options.override(.{ .min_size_content = size }));
    wd.register();

    const cr = wd.contentRect();
    const ms = wd.options.min_size_contentGet();

    var too_big = false;
    if (ms.w > cr.w or ms.h > cr.h) {
        too_big = true;
    }

    var e = wd.options.expandGet();
    const g = wd.options.gravityGet();
    var rect = dvui.placeIn(cr, ms, e, g);

    if (too_big and e != .ratio) {
        if (ms.w > cr.w and !e.isHorizontal()) {
            rect.w = ms.w;
            rect.x -= g.x * (ms.w - cr.w);
        }

        if (ms.h > cr.h and !e.isVertical()) {
            rect.h = ms.h;
            rect.y -= g.y * (ms.h - cr.h);
        }
    }

    // rect is the content rect, so expand to the whole rect
    wd.rect = rect.outset(wd.options.paddingGet()).outset(wd.options.borderGet()).outset(wd.options.marginGet());

    var renderBackground: ?dvui.Color = if (wd.options.backgroundGet()) wd.options.color(.fill) else null;

    if (wd.options.rotationGet() == 0.0) {
        wd.borderAndBackground(.{});
        renderBackground = null;
    } else {
        if (wd.options.borderGet().nonZero()) {
            dvui.log.debug("image {x} can't render border while rotated\n", .{wd.id});
        }
    }

    var path: dvui.Path.Builder = .init(dvui.currentWindow().arena());
    defer path.deinit();

    var top_left = wd.contentRectScale().r.topLeft();
    var top_right = wd.contentRectScale().r.topRight();
    var bottom_right = wd.contentRectScale().r.bottomRight();
    var bottom_left = wd.contentRectScale().r.bottomLeft();

    if (init_opts.depth > 0) {
        top_left = top_left.plus(bottom_right.diff(top_left).normalize().scale(init_opts.depth * wd.contentRectScale().r.w * -1.0, dvui.Point.Physical));
        bottom_left = bottom_left.plus(top_right.diff(bottom_left).normalize().scale(init_opts.depth * wd.contentRectScale().r.w * -1.0, dvui.Point.Physical));
    } else {
        top_right = top_right.plus(bottom_right.diff(top_right).normalize().scale(init_opts.depth * wd.contentRectScale().r.w, dvui.Point.Physical));
        bottom_right = bottom_right.plus(top_right.diff(bottom_right).normalize().scale(init_opts.depth * wd.contentRectScale().r.w, dvui.Point.Physical));
    }

    const lag_active = init_opts.reflection_lag != null;
    const reflection_lag_phys: ?ReflectionLagSample = if (lag_active) reflectionLagSamplePhysical(
        init_opts.reflection_lag.?,
        wd.contentRectScale().s,
    ) else null;

    path.addPoint(top_left);
    path.addPoint(top_right);
    path.addPoint(bottom_right);
    path.addPoint(bottom_left);

    // Distance fade toward transparent: `fade_white` tints textured draws by the
    // card opacity, and `op` scales the alpha of solid fills. No-ops at op == 1.
    const op = std.math.clamp(init_opts.opacity, 0.0, 1.0);
    const fade_white = dvui.Color.white.opacity(op);

    // Cover-flow fast path: when a file's layer stack is fully flattenable, the
    // checker + layers + selection + temp are baked into one texture once per
    // frame, so each card (front and reflection) is a single textured pass
    // instead of several overlapping alpha-blended fills. Null → multi-pass path.
    const preview_tex: ?dvui.Texture = if (init_opts.file) |f| pixi_mod.render.spritePreviewComposite(f) else null;

    if (init_opts.reflection) {
        var path2: dvui.Path.Builder = .init(dvui.currentWindow().arena());
        defer path2.deinit();

        // Direct vertical mirror: reflect each (already skewed) top corner straight
        // down through its bottom corner, so the reflection is a true flip of the
        // card — same width and skew at every height, sharing the bottom edge —
        // rather than a trapezoid that flares outward. pathToSubdividedQuad reads
        // these as (tl, tr, br, bl); the far edge (tl, tr) samples the sprite top
        // and the near edge (br, bl) the sprite bottom, giving the mirrored uv.
        // `refl_off` slides the whole reflection down independently of the card.
        const refl_off = dvui.Point.Physical{ .x = 0.0, .y = init_opts.reflection_offset * wd.contentRectScale().s };
        path2.addPoint(bottom_left.plus(bottom_left.diff(top_left)).plus(refl_off));
        path2.addPoint(bottom_right.plus(bottom_right.diff(top_right)).plus(refl_off));
        path2.addPoint(bottom_right.plus(refl_off));
        path2.addPoint(bottom_left.plus(refl_off));

        const preview_extent = @min(wd.contentRectScale().r.w, wd.contentRectScale().r.h);
        // Subdivide in proportion to on-screen size so the *physical* ripple density
        // stays constant across zoom — a big (zoomed-in) card gets many more verts,
        // rendering the fine field detail instead of undersampling it into coarse
        // waves. (The field already carries dense ripples at `cols_per_slot`.)
        const base_subdivisions_f = std.math.clamp(preview_extent / 13.0, 14.0, 44.0);
        // The mesh is O(subdivisions²) and is rebuilt + rendered per layer for every
        // card. Only the head-on focus cards need the fine, high-res ripple; skewed
        // shelf cards pass a low `reflection_detail` so they fall to the coarse floor
        // and stay cheap, which is what keeps the shelf affordable on slower GPUs.
        const detail = std.math.clamp(init_opts.reflection_detail, 0.0, 1.0);
        const subdivisions_f = @max(6.0, base_subdivisions_f * detail);
        const subdivisions: usize = @intFromFloat(subdivisions_f);

        if (init_opts.alpha_source) |alpha_source| preview: {
            const reflection_path = path2.build();

            const reflection_lag = reflection_lag_phys orelse ReflectionLagSample{};
            const displacement_max = wd.contentRectScale().r.h * 0.52;
            const refl_lag = if (lag_active) reflection_lag else null;

            if (preview_tex) |ptex| {
                // Single textured pass: checker + layers + selection + temp are
                // pre-flattened into the preview composite, so the reflection is one
                // draw instead of replaying the whole stack per card.
                var refl = pathToSubdividedQuad(reflection_path, dvui.currentWindow().arena(), .{
                    .subdivisions = subdivisions,
                    .uv = uv,
                    .vertical_fade = true,
                    .color_mod = fade_white,
                    .reflection_lag = refl_lag,
                    .waterline_propagate = true,
                    .displacement_max = displacement_max,
                }) catch unreachable;
                defer refl.deinit(dvui.currentWindow().arena());
                dvui.renderTriangles(refl, ptex) catch {
                    dvui.log.err("Failed to render reflection preview composite", .{});
                };
                break :preview;
            }

            // Build two meshes from the same path so vertex positions match (shared
            // ripple) but UVs differ: bg uses the full quad for checkerboard alpha,
            // layers use the sprite atlas rect.
            var reflection_triangles_bg = pathToSubdividedQuad(reflection_path, dvui.currentWindow().arena(), .{
                .subdivisions = subdivisions,
                .color_mod = dvui.themeGet().color(.content, .fill).lighten(4.0).opacity(op),
                .vertical_fade = true,
                .reflection_lag = refl_lag,
                .waterline_propagate = true,
                .displacement_max = displacement_max,
            }) catch unreachable;
            defer reflection_triangles_bg.deinit(dvui.currentWindow().arena());

            var reflection_triangles_layers = pathToSubdividedQuad(reflection_path, dvui.currentWindow().arena(), .{
                .subdivisions = subdivisions,
                .uv = uv,
                .vertical_fade = true,
                .color_mod = fade_white,
                .reflection_lag = refl_lag,
                .waterline_propagate = true,
                .displacement_max = displacement_max,
            }) catch unreachable;
            defer reflection_triangles_layers.deinit(dvui.currentWindow().arena());

            var reflection_triangles_layers_dimmed = reflection_triangles_layers.dupe(dvui.currentWindow().arena()) catch unreachable;
            defer reflection_triangles_layers_dimmed.deinit(dvui.currentWindow().arena());
            reflection_triangles_layers_dimmed.color(.gray);

            dvui.renderTriangles(reflection_triangles_bg, alpha_source.getTexture() catch null) catch {
                dvui.log.err("Failed to render triangles", .{});
            };

            if (init_opts.file) |file| {
                const preview_opts = pixi_mod.render.RenderFileOptions{
                    .file = file,
                    .rs = .{
                        .r = wd.contentRectScale().r,
                        .s = wd.contentRectScale().s,
                    },
                    .uv = uv,
                    .corner_radius = .all(0),
                };
                pixi_mod.render.renderReflectionLayerStack(preview_opts, reflection_triangles_layers, reflection_triangles_layers_dimmed) catch |err| {
                    dvui.log.err("Failed to render reflection layer stack: {any}", .{err});
                };

                dvui.renderTriangles(reflection_triangles_layers, file.editor.selection_layer.source.getTexture() catch null) catch {
                    dvui.log.err("Failed to render triangles", .{});
                };

                // Match renderLayers: use cached GPU texture when the canvas has already uploaded this frame.
                // Avoids getTexture() on .pixelsPMA sources (would upload when invalidation is .always).
                if (file.editor.temp_layer_has_content or file.editor.temp_gpu_dirty_rect != null) {
                    const temp_src = file.editor.temporary_layer.source;
                    const temp_key = temp_src.hash();
                    if (dvui.textureGetCached(temp_key)) |tex| {
                        dvui.renderTriangles(reflection_triangles_layers, tex) catch {
                            dvui.log.err("Failed to render triangles", .{});
                        };
                    } else {
                        dvui.renderTriangles(reflection_triangles_layers, temp_src.getTexture() catch null) catch {
                            dvui.log.err("Failed to render triangles", .{});
                        };
                    }
                }
            } else {
                dvui.renderTriangles(reflection_triangles_layers, init_opts.source.getTexture() catch null) catch {
                    dvui.log.err("Failed to render triangles", .{});
                };
            }
        }
    }

    // The preview composite already bakes the content-fill base + checkerboard,
    // so skip the separate base/checker passes when it's in use.
    if (preview_tex == null) {
        if (init_opts.alpha_source) |alpha_source| {
            if (init_opts.depth != 0.0) {
                // Skew the opaque base along with the art so no axis-aligned sliver
                // of fill colour pokes out past the receding edge.
            var base_triangles = pathToSubdividedQuad(path.build(), dvui.currentWindow().arena(), .{
                .subdivisions = 8,
                .color_mod = dvui.themeGet().color(.content, .fill).opacity(op),
            }) catch unreachable;
            defer base_triangles.deinit(dvui.currentWindow().arena());
            dvui.renderTriangles(base_triangles, null) catch {
                dvui.log.err("Failed to render triangles", .{});
            };
        } else {
            wd.contentRectScale().r.fill(.all(0), .{ .color = dvui.themeGet().color(.content, .fill).opacity(op), .fade = 1.5 });
        }

        const alpha_triangles = pathToSubdividedQuad(path.build(), dvui.currentWindow().arena(), .{
            .subdivisions = 8,
            .color_mod = dvui.themeGet().color(.content, .fill).lighten(6.0).opacity(0.5).opacity(op),
        }) catch unreachable;
        dvui.renderTriangles(alpha_triangles, alpha_source.getTexture() catch null) catch {
            dvui.log.err("Failed to render triangles", .{});
        };
        }
    }

    if (preview_tex) |ptex| {
        // Front card: one textured pass from the baked preview composite. Skewed
        // cards build a subdivided quad so the art tilts like a record on a shelf;
        // head-on cards use the plain quad.
        const front_path = if (init_opts.depth != 0.0) blk: {
            var q: dvui.Path.Builder = .init(dvui.currentWindow().arena());
            q.addPoint(top_left);
            q.addPoint(top_right);
            q.addPoint(bottom_right);
            q.addPoint(bottom_left);
            break :blk q.build();
        } else path.build();
        var tris = pathToSubdividedQuad(front_path, dvui.currentWindow().arena(), .{
            .subdivisions = 8,
            .uv = uv,
            .color_mod = fade_white,
        }) catch unreachable;
        defer tris.deinit(dvui.currentWindow().arena());
        dvui.renderTriangles(tris, ptex) catch {
            dvui.log.err("Failed to render sprite preview composite", .{});
        };
    } else if (init_opts.file) |file| {
        pixi_mod.render.renderLayers(.{
            .file = file,
            .rs = .{
                .r = wd.contentRectScale().r,
                .s = wd.contentRectScale().s,
            },
            .uv = uv,
            .corner_radius = .all(0),
            .color_mod = fade_white,
            // When skewed, render the layer stack into the same quad as the
            // background so the art tilts like a record on a shelf.
            .quad = if (init_opts.depth != 0.0) .{ top_left, top_right, bottom_right, bottom_left } else null,
        }) catch {
            dvui.log.err("Failed to render layers", .{});
        };
    } else {
        const triangles = pathToSubdividedQuad(path.build(), dvui.currentWindow().arena(), .{
            .subdivisions = 8,
            .uv = uv,
            .color_mod = fade_white,
        }) catch unreachable;

        dvui.renderTriangles(triangles, init_opts.source.getTexture() catch null) catch {
            dvui.log.err("Failed to render triangles", .{});
        };
    }

    path.build().stroke(.{ .color = opts.color_border orelse .transparent, .thickness = 1.0, .closed = true });

    wd.minSizeSetAndRefresh();
    wd.minSizeReportToParent();

    return wd;
}

pub const PathToSubdividedQuadOptions = struct {
    subdivisions: usize = 4,
    uv: ?dvui.Rect = null,
    vertical_fade: bool = false,
    color_mod: dvui.Color = .white,
    reflection_lag: ?ReflectionLagSample = null,
    /// When true, reflection meshes refract ripples deeper below the seam.
    waterline_propagate: bool = true,
    /// Cap vertex offset (physical px) so ripples stay inside the reflection.
    displacement_max: f32 = 0.0,
};

fn reflectionLagSamplePhysical(sample: ReflectionLagSample, scale: f32) ReflectionLagSample {
    var out = sample;
    for (&out.cols_dx) |*c| c.* *= scale;
    for (&out.cols_dy) |*c| c.* *= scale;
    return out;
}

/// Linear interpolation across the column strip by horizontal fraction `t_x`.
/// Per-row reflection factors, hoisted out of the per-vertex loop. The two `pow`
/// calls (depth lag + seam pin) depend only on the row (`t_y`), so computing them
/// once per row instead of per vertex removes thousands of `pow` calls per frame.
const ReflectionRow = struct {
    low_submerge: bool,
    lag: f32,
    lag_mix: f32, // already × 0.55
    submerge_scale: f32, // lerp(1, 1.25, submerge)
    dx_pin: f32,
};

fn reflectionRowFactors(t_y: f32) ReflectionRow {
    const submerge = 1.0 - std.math.clamp(t_y, 0, 1);
    const seam_t = std.math.clamp(t_y, 0, 1);
    return .{
        .low_submerge = submerge <= 0.001,
        .lag = std.math.pow(f32, submerge, 1.55) * 0.74,
        .lag_mix = std.math.clamp(submerge * submerge * 0.9, 0, 1) * 0.55,
        .submerge_scale = std.math.lerp(1.0, 1.25, submerge),
        .dx_pin = 1.0 - std.math.pow(f32, seam_t, 4.5),
    };
}

/// Horizontal refraction for one vertex using precomputed row factors. Equivalent
/// to `reflectionMeshDisplacement(.x)`, just with the row-constant work hoisted.
fn reflectionRowDx(t_x: f32, dx_seam: f32, row: ReflectionRow, sample: ReflectionLagSample) f32 {
    // `dx_seam` (the column's refraction at the seam) is supplied precomputed — it
    // depends only on t_x, so the caller resolves it once per column. Only the
    // depth-lagged sample, which shifts t_x by the row's phase lag, needs an interp.
    const t_lag = if (row.low_submerge)
        t_x
    else
        std.math.clamp(t_x - (if (dx_seam >= 0) row.lag else -row.lag), 0, 1);
    const dx_lag = if (row.low_submerge) dx_seam else interpolateReflectionCols(&sample.cols_dx, t_lag);
    return std.math.lerp(dx_seam, dx_lag, row.lag_mix) * row.submerge_scale * row.dx_pin;
}

fn interpolateReflectionCols(cols: []const f32, t_x: f32) f32 {
    if (cols.len == 0) return 0;
    if (cols.len == 1) return cols[0];
    const f = std.math.clamp(t_x, 0, 1) * @as(f32, @floatFromInt(cols.len - 1));
    const idx0: usize = @intFromFloat(@floor(f));
    const idx1 = @min(idx0 + 1, cols.len - 1);
    const t = f - @as(f32, @floatFromInt(idx0));
    return std.math.lerp(cols[idx0], cols[idx1], t);
}

fn clampDisplacement(d: dvui.Point.Physical, max_mag: f32) dvui.Point.Physical {
    if (max_mag <= 0.0001) return d;
    const mag = @sqrt(d.x * d.x + d.y * d.y);
    if (mag <= max_mag) return d;
    const s = max_mag / mag;
    return .{ .x = d.x * s, .y = d.y * s };
}

/// Depth into the reflection body (0 at the waterline seam, 1 at the far edge).
fn reflectionSubmergeDepth(t_y: f32) f32 {
    return 1.0 - std.math.clamp(t_y, 0, 1);
}

/// Expanding ripple: larger displacement toward the reflection bottom. Rises
/// quickly just below the seam (so the effect is still strong in the upper region
/// that stays on-screen when zoomed in and the reflection's bottom is clipped),
/// then keeps growing toward the far edge for the full zoomed-out slosh.
fn reflectionDepthAmplitude(submerge: f32) f32 {
    const d = std.math.clamp(submerge, 0, 1);
    return 1.0 + d * (1.8 + 1.4 * d);
}

/// Phase lag vs depth — deeper rows follow the same wave, slower and larger.
fn reflectionDepthLag(submerge: f32) f32 {
    const d = std.math.clamp(submerge, 0, 1);
    return std.math.pow(f32, d, 1.55) * 0.74;
}

/// Sample the surface field with increasing horizontal phase lag at depth.
fn reflectionLaggedTx(t_x: f32, cols_dx: []const f32, submerge: f32) f32 {
    if (submerge <= 0.001) return t_x;
    const lag = reflectionDepthLag(submerge);
    const slope = interpolateReflectionCols(cols_dx, t_x);
    const dir: f32 = if (slope >= 0) 1 else -1;
    return std.math.clamp(t_x - dir * lag, 0, 1);
}

/// Reflection mesh: seam pinned at the waterline; the body carries horizontal
/// refraction ripples that phase-lag with depth. cols_dy is not applied.
fn reflectionMeshDisplacement(t_x: f32, t_y: f32, sample: ReflectionLagSample) dvui.Point.Physical {
    const submerge = reflectionSubmergeDepth(t_y);
    const t_lag = reflectionLaggedTx(t_x, &sample.cols_dx, submerge);
    const lag_mix = std.math.clamp(submerge * submerge * 0.9, 0, 1);

    const seam_t = std.math.clamp(t_y, 0, 1);
    // Peak refraction just under the card base (not mid-body / far edge); seam
    // corners stay pinned so the base width still matches the card.
    const dx_pin = std.math.pow(f32, seam_t, 1.4) * (1.0 - std.math.pow(f32, seam_t, 12.0));
    const dx_seam = interpolateReflectionCols(&sample.cols_dx, t_x);
    const dx_lag = interpolateReflectionCols(&sample.cols_dx, t_lag);
    const dx = std.math.lerp(dx_seam, dx_lag, lag_mix * 0.55) * std.math.lerp(1.0, 1.25, submerge) * dx_pin;

    return .{ .x = dx, .y = 0 };
}

fn waterlineMeshDisplacement(
    t_x: f32,
    t_y: f32,
    sample: ReflectionLagSample,
    propagate: bool,
) dvui.Point.Physical {
    if (propagate) return reflectionMeshDisplacement(t_x, t_y, sample);
    const s = std.math.clamp(t_y, 0, 1);
    const strength = s * (0.1 + 0.9 * s);
    return .{
        .x = interpolateReflectionCols(&sample.cols_dx, t_x) * strength,
        .y = 0,
    };
}

fn reflectionCombinedDisplacement(t_x: f32, t_y: f32, options: PathToSubdividedQuadOptions) dvui.Point.Physical {
    var d: dvui.Point.Physical = .{ .x = 0, .y = 0 };
    if (options.reflection_lag) |sample| {
        d = d.plus(waterlineMeshDisplacement(t_x, t_y, sample, options.waterline_propagate));
    }
    return clampDisplacement(d, options.displacement_max);
}

pub fn pathToSubdividedQuad(path: dvui.Path, allocator: std.mem.Allocator, options: PathToSubdividedQuadOptions) std.mem.Allocator.Error!dvui.Triangles {
    if (path.points.len != 4) {
        return .empty;
    }

    const subdivs = options.subdivisions;
    const vtx_count = (subdivs + 1) * (subdivs + 1);
    const idx_count = 2 * subdivs * subdivs * 3;

    var builder = try dvui.Triangles.Builder.init(allocator, vtx_count, idx_count);
    errdefer comptime unreachable;

    // Four quad corners in order: tl, tr, br, bl
    const tl = path.points[0];
    const tr = path.points[1];
    const br = path.points[2];
    const bl = path.points[3];

    // Use given UV or default to (0,0,1,1)
    const base_uv = options.uv orelse dvui.Rect{ .x = 0, .y = 0, .w = 1, .h = 1 };

    {
        // The seam refraction for a reflection mesh depends only on the column
        // (t_x), so precompute it once per column and reuse it down every row
        // instead of re-interpolating cols_dx per vertex. Guarded by the buffer
        // size; non-reflection meshes and any unusually fine mesh fall back to the
        // inline interp below (`seam_cache` stays false).
        var dx_seam_col: [64]f32 = undefined;
        const seam_cache = options.reflection_lag != null and options.waterline_propagate and subdivs + 1 <= dx_seam_col.len;
        if (seam_cache) {
            const sample = options.reflection_lag.?;
            var x: usize = 0;
            while (x <= subdivs) : (x += 1) {
                const t_x = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(subdivs));
                dx_seam_col[x] = interpolateReflectionCols(&sample.cols_dx, t_x);
            }
        }

        var y: usize = 0;
        while (y <= subdivs) : (y += 1) { // vertical
            const t_y = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(subdivs));
            // Interpolate between tl/bl for left and tr/br for right
            const left = dvui.Point.Physical{
                .x = tl.x + (bl.x - tl.x) * t_y,
                .y = tl.y + (bl.y - tl.y) * t_y,
            };
            const right = dvui.Point.Physical{
                .x = tr.x + (br.x - tr.x) * t_y,
                .y = tr.y + (br.y - tr.y) * t_y,
            };
            // Keep each row monotonic in x so a steep ripple pinches instead of
            // folding back over itself. Overlapping triangles double-blend the
            // semi-transparent reflection, which reads as a too-bright seam where
            // the verts cross (most visible on the fly-in splash).
            const row_increasing = right.x >= left.x;
            // Hoist the per-row (pow-heavy) refraction factors out of the x-loop.
            const refl_row: ?ReflectionRow = if (options.reflection_lag != null and options.waterline_propagate)
                reflectionRowFactors(t_y)
            else
                null;
            // Vertex tint only depends on the row (vertical fade), so resolve the
            // colour and its PMA conversion once per row, not per vertex.
            var row_col: dvui.Color = options.color_mod;
            if (options.vertical_fade) row_col = row_col.opacity(0.5 * t_y);
            const row_col_pma = dvui.Color.PMA.fromColor(row_col);
            var prev_x: f32 = 0;
            var x: usize = 0;
            while (x <= subdivs) : (x += 1) { // horizontal
                const t_x = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(subdivs));
                var pos = dvui.Point.Physical{
                    .x = left.x + (right.x - left.x) * t_x,
                    .y = left.y + (right.y - left.y) * t_x,
                };
                if (options.reflection_lag) |sample| {
                    if (refl_row) |row| {
                        const dx_seam = if (seam_cache) dx_seam_col[x] else interpolateReflectionCols(&sample.cols_dx, t_x);
                        var dx = reflectionRowDx(t_x, dx_seam, row, sample);
                        // The reflection offset is purely horizontal (dy = 0), so the
                        // magnitude clamp is just |dx| — no Point/​sqrt needed.
                        const dmax = options.displacement_max;
                        if (dmax > 0.0001 and @abs(dx) > dmax) dx = std.math.sign(dx) * dmax;
                        pos.x += dx;
                    } else {
                        pos = pos.plus(reflectionCombinedDisplacement(t_x, t_y, options));
                    }
                    if (x > 0) {
                        if (row_increasing) {
                            pos.x = @max(pos.x, prev_x);
                        } else {
                            pos.x = @min(pos.x, prev_x);
                        }
                    }
                    prev_x = pos.x;
                }

                const uv = .{
                    base_uv.x + base_uv.w * t_x,
                    base_uv.y + base_uv.h * t_y,
                };

                builder.appendVertex(.{
                    .pos = pos,
                    .col = row_col_pma,
                    .uv = uv,
                });
            }
        }
    }

    // Generate indices for quads in row-major order
    for (0..subdivs) |j| {
        for (0..subdivs) |i| {
            const row_stride = subdivs + 1;
            const idx0 = j * row_stride + i;
            const idx1 = idx0 + 1;
            const idx2 = idx0 + row_stride;
            const idx3 = idx2 + 1;
            // 0---1
            // | / |
            // 2---3
            // first triangle (idx0, idx2, idx1)
            builder.appendTriangles(&.{
                @intCast(idx0),
                @intCast(idx2),
                @intCast(idx1),
            });
            // second triangle (idx1, idx2, idx3)
            builder.appendTriangles(&.{
                @intCast(idx1),
                @intCast(idx2),
                @intCast(idx3),
            });
        }
    }

    return builder.build();
}

pub fn renderSprite(source: dvui.ImageSource, s: pixi_mod.core_sprite, data_point: dvui.Point, scale: f32, opts: dvui.RenderTextureOptions) !void {
    const atlas_size = dvui.imageSize(source) catch {
        std.log.err("Failed to get atlas size", .{});
        return;
    };

    var opt = opts;

    const uv = dvui.Rect{
        .x = (@as(f32, @floatFromInt(s.source[0])) / atlas_size.w),
        .y = (@as(f32, @floatFromInt(s.source[1])) / atlas_size.h),
        .w = (@as(f32, @floatFromInt(s.source[2])) / atlas_size.w),
        .h = (@as(f32, @floatFromInt(s.source[3])) / atlas_size.h),
    };

    opt.uv = uv;

    const origin = dvui.Point{
        .x = @as(f32, @floatFromInt(s.origin[0])) * 1 / scale,
        .y = @as(f32, @floatFromInt(s.origin[1])) * 1 / scale,
    };

    const position = data_point.diff(origin);

    const box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .none,
        .rect = .{
            .x = position.x,
            .y = position.y,
            .w = @as(f32, @floatFromInt(s.source[2])) * scale,
            .h = @as(f32, @floatFromInt(s.source[3])) * scale,
        },
        .border = dvui.Rect.all(0),
        .corner_radius = .{ .x = 0, .y = 0 },
        .padding = .{ .x = 0, .y = 0 },
        .margin = .{ .x = 0, .y = 0 },
        .background = false,
        .color_fill = dvui.themeGet().color(.err, .fill),
    });
    defer box.deinit();

    const rs = box.data().rectScale();

    try dvui.renderImage(source, rs, opt);
}
