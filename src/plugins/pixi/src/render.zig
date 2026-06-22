const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const pixi_mod = @import("../pixi.zig");
const runtime = @import("runtime.zig");
const perf = pixi_mod.perf;

/// Monotonic frame counter, incremented once per frame from Editor.tick.
pub var frame_index: u64 = 0;

pub const RenderFileOptions = struct {
    file: *pixi_mod.internal.File,
    rs: dvui.RectScale,
    color_mod: dvui.Color = .white,
    fade: f32 = 0.0,
    uv: dvui.Rect = .{ .w = 1.0, .h = 1.0 },
    corner_radius: dvui.Rect = .all(0),
    allow_peek: bool = true,
    /// Optional skewed quad in physical corner order (tl, tr, br, bl). When set,
    /// the layer stack renders into this quad instead of the axis-aligned `rs.r`,
    /// so perspective/depth skew applies to the art itself — not just the
    /// background. Leave null for normal (canvas) rendering.
    quad: ?[4]dvui.Point.Physical = null,
    quad_subdivisions: usize = 8,
};

/// Web backends without `textureUpdateSubRect` recreate the GPU texture on upload; sync the cache
/// when the pointer changes so we do not keep drawing a texture id that was destroyLater'd.
fn uploadSubRectAndSyncCache(
    key: u64,
    tex: *dvui.Texture,
    pixels: [*]const u8,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
) void {
    const prev_ptr = tex.ptr;
    tex.updateSubRect(pixels, x, y, w, h) catch |err| {
        dvui.log.err("Sub-rect texture upload failed: {any}", .{err});
        return;
    };
    if (tex.ptr != prev_ptr) {
        dvui.textureAddToCache(key, tex.*);
    }
}

/// Pushes pending CPU pixel edits to GPU textures. Must run even when `renderLayers` returns early
/// (scale zero / clip empty): otherwise `defer` blocks that normally perform uploads are never
/// registered, and `temp_gpu_dirty_rect` keeps unioning every frame until it covers the whole image.
fn flushPendingLayerTextureUploads(init_opts: RenderFileOptions) void {
    const file = init_opts.file;

    if (file.editor.active_layer_dirty_rect) |dirty| {
        if (dirty.w > 0 and dirty.h > 0) {
            perf.draw_active_rect_area += @intFromFloat(dirty.w * dirty.h);
            const source = file.layers.items(.source)[file.selected_layer_index];
            const source_key = source.hash();
            if (dvui.textureGetCached(source_key)) |cached| {
                var tex = cached;
                uploadSubRectAndSyncCache(
                    source_key,
                    &tex,
                    pixi_mod.image.bytes(source).ptr,
                    @intFromFloat(dirty.x),
                    @intFromFloat(dirty.y),
                    @intFromFloat(dirty.w),
                    @intFromFloat(dirty.h),
                );
            }
        }
        file.editor.active_layer_dirty_rect = null;
    }

    if (file.editor.temp_layer_has_content or
        file.editor.temp_gpu_dirty_rect != null)
    {
        const temp_source = file.editor.temporary_layer.source;
        const temp_key = temp_source.hash();
        if (dvui.textureGetCached(temp_key)) |cached| {
            if (file.editor.temp_gpu_dirty_rect) |dirty| {
                if (dirty.w > 0 and dirty.h > 0) {
                    perf.draw_temp_rect_area += @intFromFloat(dirty.w * dirty.h);
                    var tex = cached;
                    uploadSubRectAndSyncCache(
                        temp_key,
                        &tex,
                        pixi_mod.image.bytes(temp_source).ptr,
                        @intFromFloat(dirty.x),
                        @intFromFloat(dirty.y),
                        @intFromFloat(dirty.w),
                        @intFromFloat(dirty.h),
                    );
                }
                file.editor.temp_gpu_dirty_rect = null;
            } else if (file.editor.temp_layer_has_content) {
                // CPU redraw (e.g. selection overlay via setColorFromMask) may leave the cache valid
                // without a dirty rect; sync the full texture so the GPU matches the pixel buffer.
                _ = temp_source.getTexture() catch null;
            }
        } else if (file.editor.temp_layer_has_content) {
            _ = temp_source.getTexture() catch null;
            file.editor.temp_gpu_dirty_rect = null;
        } else if (file.editor.temp_gpu_dirty_rect != null) {
            file.editor.temp_gpu_dirty_rect = null;
        }
    }
}

fn layerViewStateForRender(init_opts: RenderFileOptions) struct { min_layer_index: usize, needs_dimmed: bool } {
    var min_layer_index: usize = 0;
    if (init_opts.allow_peek) {
        if (init_opts.file.editor.isolate_layer) {
            if (init_opts.file.peek_layer_index) |peek_layer_index| {
                min_layer_index = peek_layer_index;
            } else if (!runtime.state().tools_pane.layersHovered()) {
                min_layer_index = init_opts.file.selected_layer_index;
            }
        }
    }
    const needs_dimmed = init_opts.allow_peek and init_opts.file.peek_layer_index != null;
    return .{ .min_layer_index = min_layer_index, .needs_dimmed = needs_dimmed };
}

/// Non-null while layer list DnD preview is active (`File.editor.layer_drag_preview_*`); maps list position → storage index.
fn layerOrderBufForDragPreview(file: *pixi_mod.internal.File, buf: []usize) ?[]const usize {
    const r = file.editor.layer_drag_preview_removed orelse return null;
    const ins = file.editor.layer_drag_preview_insert_before orelse return null;
    if (file.layers.len == 0 or file.layers.len > buf.len) return null;
    pixi_mod.internal.File.layerOrderAfterMove(file.layers.len, r, ins, buf[0..file.layers.len]);
    return buf[0..file.layers.len];
}

/// Builds the same cached composites `renderLayers` would use (split when drawing, full when idle),
/// so callers (e.g. sprite preview reflection) can draw before `renderLayers` runs.
pub fn ensureLayerCompositesForPreview(init_opts: RenderFileOptions) !void {
    const vs = layerViewStateForRender(init_opts);
    if (splitCompositeEligible(init_opts, vs.min_layer_index, vs.needs_dimmed)) {
        try syncSplitComposite(init_opts.file);
    } else if (fullCompositeEligible(init_opts, vs.min_layer_index, vs.needs_dimmed)) {
        try syncLayerComposite(init_opts.file);
    }
}

fn renderTransformIfActive(init_opts: RenderFileOptions, triangles: dvui.Triangles) void {
    if (init_opts.file.editor.transform) |*transform| {
        if (dvui.textureFromTarget(transform.target_texture) catch null) |tex| {
            dvui.renderTriangles(triangles, tex) catch {
                dvui.log.err("Failed to render transform layer", .{});
            };
        }
    }
}

/// Draws the layer stack for the sprite-panel reflection using the same composite paths as
/// `renderLayers` (1–3 draws) instead of N per-layer draws when possible.
pub fn renderReflectionLayerStack(
    init_opts: RenderFileOptions,
    reflection_tris: dvui.Triangles,
    reflection_tris_dimmed: dvui.Triangles,
) !void {
    const file = init_opts.file;
    const vs = layerViewStateForRender(init_opts);
    try ensureLayerCompositesForPreview(init_opts);

    var order_buf: [1024]usize = undefined;
    const order_opt = layerOrderBufForDragPreview(file, order_buf[0..]);

    if (file.peek_layer_index != null) {
        var list_pos: usize = file.layers.len;
        while (list_pos > vs.min_layer_index) {
            list_pos -= 1;
            const layer_index = if (order_opt) |o| o[list_pos] else list_pos;
            const visible = file.layers.items(.visible)[layer_index];
            var tris = reflection_tris;
            if (vs.needs_dimmed) {
                if (file.peek_layer_index) |peek_layer_index| {
                    if (peek_layer_index != layer_index) {
                        tris = reflection_tris_dimmed;
                    }
                }
            }
            if (visible) {
                dvui.renderTriangles(tris, file.layers.items(.source)[layer_index].getTexture() catch null) catch {
                    dvui.log.err("Failed to render reflection layer", .{});
                };
            }
            if (layer_index == file.selected_layer_index) {
                renderTransformIfActive(init_opts, reflection_tris);
            }
        }
        return;
    }

    if (splitCompositeEligible(init_opts, vs.min_layer_index, vs.needs_dimmed)) {
        if (order_opt != null) {
            var list_pos: usize = file.layers.len;
            while (list_pos > vs.min_layer_index) {
                list_pos -= 1;
                const layer_index = order_opt.?[list_pos];
                const visible = file.layers.items(.visible)[layer_index];
                var tris = reflection_tris;
                if (vs.needs_dimmed) {
                    if (file.peek_layer_index) |peek_layer_index| {
                        if (peek_layer_index != layer_index) {
                            tris = reflection_tris_dimmed;
                        }
                    }
                }
                if (visible) {
                    dvui.renderTriangles(tris, file.layers.items(.source)[layer_index].getTexture() catch null) catch {
                        dvui.log.err("Failed to render reflection layer", .{});
                    };
                }
                if (layer_index == file.selected_layer_index) {
                    renderTransformIfActive(init_opts, reflection_tris);
                }
            }
            return;
        }
        if (file.editor.split_composite_below) |ct| {
            if (dvui.Texture.fromTargetTemp(ct) catch null) |tex| {
                dvui.renderTriangles(reflection_tris, tex) catch {
                    dvui.log.err("Failed to render reflection below composite", .{});
                };
            }
        }
        const active_source = file.layers.items(.source)[file.selected_layer_index];
        if (file.layers.items(.visible)[file.selected_layer_index]) {
            if (active_source.getTexture() catch null) |tex| {
                dvui.renderTriangles(reflection_tris, tex) catch {
                    dvui.log.err("Failed to render reflection active layer", .{});
                };
            }
        }
        renderTransformIfActive(init_opts, reflection_tris);
        if (file.editor.split_composite_above) |ct| {
            if (dvui.Texture.fromTargetTemp(ct) catch null) |tex| {
                dvui.renderTriangles(reflection_tris, tex) catch {
                    dvui.log.err("Failed to render reflection above composite", .{});
                };
            }
        }
        return;
    }

    if (fullCompositeEligible(init_opts, vs.min_layer_index, vs.needs_dimmed)) {
        if (file.editor.layer_composite_target) |ct| {
            if (dvui.Texture.fromTargetTemp(ct) catch null) |ctex| {
                dvui.renderTriangles(reflection_tris, ctex) catch {
                    dvui.log.err("Failed to render reflection full composite", .{});
                };
                return;
            }
        }
    }

    var list_pos2: usize = file.layers.len;
    while (list_pos2 > vs.min_layer_index) {
        list_pos2 -= 1;
        const layer_index = if (order_opt) |o| o[list_pos2] else list_pos2;
        const visible = file.layers.items(.visible)[layer_index];
        var tris = reflection_tris;
        if (vs.needs_dimmed) {
            if (file.peek_layer_index) |peek_layer_index| {
                if (peek_layer_index != layer_index) {
                    tris = reflection_tris_dimmed;
                }
            }
        }
        if (visible) {
            dvui.renderTriangles(tris, file.layers.items(.source)[layer_index].getTexture() catch null) catch {
                dvui.log.err("Failed to render reflection layer stack fallback", .{});
            };
        }
        if (layer_index == file.selected_layer_index) {
            renderTransformIfActive(init_opts, reflection_tris);
        }
    }
}

/// Draw layers into the **current** render target using cached composites only (no `sync*` rebinding).
/// Caller must run `ensureLayerCompositesForPreview` first while the screen target is active.
pub fn renderLayersMagnifierSample(init_opts: RenderFileOptions) !void {
    flushPendingLayerTextureUploads(init_opts);

    if (init_opts.rs.s == 0) return;
    if (dvui.clipGet().intersect(init_opts.rs.r).empty()) return;

    const vs = layerViewStateForRender(init_opts);

    var path: dvui.Path.Builder = .init(runtime.allocator());
    defer path.deinit();

    path.addRect(init_opts.rs.r, dvui.Rect.Physical.all(0));

    var triangles = try path.build().fillConvexTriangles(runtime.allocator(), .{ .color = init_opts.color_mod, .fade = init_opts.fade });
    defer triangles.deinit(runtime.allocator());

    triangles.uvFromRectuv(init_opts.rs.r, init_opts.uv);

    var dimmed_triangles: ?dvui.Triangles = null;
    defer {
        if (dimmed_triangles) |*dt| dt.deinit(runtime.allocator());
    }
    if (vs.needs_dimmed) {
        var dt = try triangles.dupe(runtime.allocator());
        dt.color(.gray);
        dimmed_triangles = dt;
    }

    const dimmed = dimmed_triangles orelse triangles;
    try renderReflectionLayerStack(init_opts, triangles, dimmed);

    if (dvui.textureGetCached(init_opts.file.editor.selection_layer.source.hash()) == null)
        perf.draw_texture_creates += 1;
    dvui.renderTriangles(triangles, init_opts.file.editor.selection_layer.source.getTexture() catch null) catch {
        dvui.log.err("Failed to render magnifier selection layer", .{});
    };

    if (init_opts.file.editor.temp_layer_has_content) {
        const temp_source = init_opts.file.editor.temporary_layer.source;
        if (dvui.textureGetCached(temp_source.hash()) == null)
            perf.draw_texture_creates += 1;
        if (dvui.textureGetCached(temp_source.hash())) |cached| {
            dvui.renderTriangles(triangles, cached) catch {
                dvui.log.err("Failed to render magnifier temporary layer", .{});
            };
        } else {
            dvui.renderTriangles(triangles, temp_source.getTexture() catch null) catch {
                dvui.log.err("Failed to render magnifier temporary layer", .{});
            };
        }
    }
}

fn fullCompositeEligible(
    init_opts: RenderFileOptions,
    min_layer_index: usize,
    needs_dimmed: bool,
) bool {
    if (needs_dimmed) return false;
    if (min_layer_index != 0) return false;
    if (init_opts.fade != 0) return false;
    // A uniform color_mod (e.g. the cover-flow opacity fade) is correct to apply
    // once to the flattened composite — and avoids the per-layer translucency
    // artifacts you'd get fading each layer separately.
    if (init_opts.file.editor.transform != null) return false;
    if (init_opts.file.editor.active_drawing) return false;
    const ce = layerCompositeExtent(init_opts.file);
    if (ce.w == 0 or ce.h == 0) return false;
    return true;
}

fn splitCompositeEligible(
    init_opts: RenderFileOptions,
    min_layer_index: usize,
    needs_dimmed: bool,
) bool {
    if (!init_opts.file.editor.active_drawing and init_opts.file.editor.transform == null) return false;
    if (needs_dimmed) return false;
    if (min_layer_index != 0) return false;
    if (init_opts.fade != 0) return false;
    // See fullCompositeEligible: a uniform color_mod applies cleanly to the
    // split composites too, so it no longer forces the per-layer path.
    const ce = layerCompositeExtent(init_opts.file);
    if (ce.w == 0 or ce.h == 0) return false;
    return true;
}

/// Pixel size of the flattened layer stack — prefers the first layer (`canvasPixelSize`) so the
/// composite matches bitmap data even when `columns × column_width` / `rows × row_height` disagree
/// (slice/grid previews use the canvas as the locked image rect).
fn layerCompositeExtent(file: *pixi_mod.internal.File) struct { w: u32, h: u32 } {
    const c = file.canvasPixelSize();
    if (c.w > 0 and c.h > 0) return .{ .w = c.w, .h = c.h };
    const w = file.width();
    const h = file.height();
    return .{ .w = w, .h = h };
}

/// Pixel format for off-screen render targets (layer composites, transforms).
/// The web backend only supports `.rgba_32`.
pub fn compositeTargetPixelFormat() dvui.enums.TexturePixelFormat {
    return if (comptime builtin.target.cpu.arch == .wasm32)
        .rgba_32
    else
        .rgba_8_8_8_8;
}

/// Rebuilds the full-canvas flattened layer texture (all layers included).
/// Used when NOT actively drawing.
pub fn syncLayerComposite(file: *pixi_mod.internal.File) !void {
    const ce = layerCompositeExtent(file);
    const w = ce.w;
    const h = ce.h;
    if (w == 0 or h == 0) return;

    if (file.editor.layer_composite_frame_built == frame_index) return;
    file.editor.layer_composite_frame_built = frame_index;

    if (file.editor.layer_composite_target) |t| {
        if (t.width != w or t.height != h) {
            t.destroyLater();
            file.editor.layer_composite_target = null;
        }
    }

    var needs_rebuild = file.editor.layer_composite_target == null or file.editor.layer_composite_dirty;

    if (!needs_rebuild) {
        var i: usize = file.layers.len;
        while (i > 0) {
            i -= 1;
            if (!file.layers.items(.visible)[i]) continue;
            if (dvui.textureGetCached(file.layers.items(.source)[i].hash()) == null) {
                needs_rebuild = true;
                break;
            }
        }
    }

    if (!needs_rebuild) return;

    perf.draw_full_composite_rebuilds += 1;

    const sc_t0 = perf.syncCompositeBegin();
    defer perf.syncCompositeEnd(sc_t0);

    const target = if (file.editor.layer_composite_target) |t| t else blk: {
        const nt = try dvui.textureCreateTarget(.{ .width = w, .height = h, .format = compositeTargetPixelFormat(), .interpolation = .nearest });
        file.editor.layer_composite_target = nt;
        break :blk nt;
    };

    try renderLayersIntoTarget(file, target, 0, file.layers.len, null);
    file.editor.layer_composite_dirty = false;
    file.editor.layer_composite_generation +%= 1;
}

/// Builds two split composites that exclude the active (selected) layer.
/// The "below" target flattens layers visually below (higher index), and
/// the "above" target flattens layers visually above (lower index).
/// Only rebuilt when the split layer changes or a structural change occurs.
fn syncSplitComposite(file: *pixi_mod.internal.File) !void {
    const ce = layerCompositeExtent(file);
    const w = ce.w;
    const h = ce.h;
    if (w == 0 or h == 0) return;

    if (file.editor.split_composite_frame_built == frame_index) return;
    file.editor.split_composite_frame_built = frame_index;

    // Prevent the full composite from also rebuilding this frame (e.g. from
    // the sprite panel reflection calling syncLayerComposite directly).
    file.editor.layer_composite_frame_built = frame_index;

    const active_idx = file.selected_layer_index;

    var needs_rebuild = file.editor.split_composite_dirty or
        file.editor.split_composite_layer == null or
        file.editor.split_composite_layer.? != active_idx;

    inline for (&[_]*?dvui.Texture.Target{
        &file.editor.split_composite_below,
        &file.editor.split_composite_above,
    }) |target_ptr| {
        if (target_ptr.*) |t| {
            if (t.width != w or t.height != h) {
                t.destroyLater();
                target_ptr.* = null;
                needs_rebuild = true;
            }
        } else {
            needs_rebuild = true;
        }
    }

    if (!needs_rebuild) {
        var i: usize = file.layers.len;
        while (i > 0) {
            i -= 1;
            if (i == active_idx) continue;
            if (!file.layers.items(.visible)[i]) continue;
            if (dvui.textureGetCached(file.layers.items(.source)[i].hash()) == null) {
                needs_rebuild = true;
                break;
            }
        }
    }

    if (!needs_rebuild) return;

    perf.draw_split_rebuilds += 1;

    const sc_t0 = perf.syncCompositeBegin();
    defer perf.syncCompositeEnd(sc_t0);

    const below = if (file.editor.split_composite_below) |t| t else blk: {
        const nt = try dvui.textureCreateTarget(.{ .width = w, .height = h, .format = compositeTargetPixelFormat(), .interpolation = .nearest });
        file.editor.split_composite_below = nt;
        break :blk nt;
    };

    const above = if (file.editor.split_composite_above) |t| t else blk: {
        const nt = try dvui.textureCreateTarget(.{ .width = w, .height = h, .format = compositeTargetPixelFormat(), .interpolation = .nearest });
        file.editor.split_composite_above = nt;
        break :blk nt;
    };

    const t_below = perf.nanoTimestamp();
    try renderLayersIntoTarget(file, below, active_idx + 1, file.layers.len, null);
    if (perf.record) {
        perf.split_composite_below_ns = @intCast(perf.nanoTimestamp() - t_below);
    }

    const t_above = perf.nanoTimestamp();
    try renderLayersIntoTarget(file, above, 0, active_idx, null);
    if (perf.record) {
        perf.split_composite_above_ns = @intCast(perf.nanoTimestamp() - t_above);
    }

    file.editor.split_composite_layer = active_idx;
    file.editor.split_composite_dirty = false;
}

/// Pre-builds split-composite GPU targets and touches temp/selection textures so the first
/// stroke does not pay allocation + flatten cost. Safe to call once after open or when
/// selecting a drawing tool; no-op if composites are already current.
pub fn warmupDrawingComposites(file: *pixi_mod.internal.File) !void {
    const w0 = perf.nanoTimestamp();
    try syncSplitComposite(file);
    _ = file.editor.temporary_layer.source.getTexture() catch null;
    _ = file.editor.selection_layer.source.getTexture() catch null;
    perf.composite_warmup_last_ns = @intCast(perf.nanoTimestamp() - w0);
    perf.composite_warmup_total +%= 1;
}

/// Renders a range of visible layers into a render target. Layers are drawn
/// from high index (visually bottom) to low index (visually top). An optional
/// `skip_index` excludes a single layer.
fn renderLayersIntoTarget(
    file: *pixi_mod.internal.File,
    target: dvui.Texture.Target,
    min_index: usize,
    max_index: usize,
    skip_index: ?usize,
) !void {
    const ce = layerCompositeExtent(file);
    const w = ce.w;
    const h = ce.h;
    const image_rect = dvui.Rect.Physical{
        .x = 0,
        .y = 0,
        .w = @floatFromInt(w),
        .h = @floatFromInt(h),
    };

    target.clear();
    const prev_target = dvui.renderTarget(.{ .texture = target, .offset = image_rect.topLeft() });
    defer _ = dvui.renderTarget(prev_target);

    const prev_clip = dvui.clipGet();
    defer dvui.clipSet(prev_clip);
    dvui.clipSet(image_rect);

    var path: dvui.Path.Builder = .init(runtime.allocator());
    defer path.deinit();
    path.addRect(image_rect, dvui.Rect.Physical.all(0));

    var tris = try path.build().fillConvexTriangles(runtime.allocator(), .{ .color = .white, .fade = 0 });
    defer tris.deinit(runtime.allocator());
    tris.uvFromRectuv(image_rect, .{ .x = 0, .y = 0, .w = 1, .h = 1 });

    var order_buf: [1024]usize = undefined;
    const order_opt = layerOrderBufForDragPreview(file, order_buf[0..]);

    var list_pos: usize = max_index;
    while (list_pos > min_index) {
        list_pos -= 1;
        const i = if (order_opt) |o| o[list_pos] else list_pos;
        if (skip_index) |skip| {
            if (i == skip) continue;
        }
        if (!file.layers.items(.visible)[i]) continue;
        const source = file.layers.items(.source)[i];
        if (source.getTexture() catch null) |tex| {
            dvui.renderTriangles(tris, tex) catch {
                dvui.log.err("Failed to render layer into composite target", .{});
            };
        }
    }
}

/// Bakes the cover-flow preview composite — checkerboard backdrop + flattened
/// layers + selection + temp, all at canvas resolution — into one texture. The
/// sprite panel then draws each card (front and reflection) as a single textured
/// pass sampling this, instead of replaying the whole stack as several
/// overlapping alpha-blended fills per card. Rebuilt at most once per frame.
pub fn syncPreviewComposite(file: *pixi_mod.internal.File) !void {
    const ce = layerCompositeExtent(file);
    const w = ce.w;
    const h = ce.h;
    if (w == 0 or h == 0) return;

    if (file.editor.preview_composite_frame_built == frame_index) return;
    file.editor.preview_composite_frame_built = frame_index;

    // The flattened layer stack feeds the bake; build/refresh it first.
    try syncLayerComposite(file);

    var fresh = false;
    if (file.editor.preview_composite_target) |t| {
        if (t.width != w or t.height != h) {
            t.destroyLater();
            file.editor.preview_composite_target = null;
        }
    }
    const target = if (file.editor.preview_composite_target) |t| t else blk: {
        const nt = try dvui.textureCreateTarget(.{ .width = w, .height = h, .format = compositeTargetPixelFormat(), .interpolation = .nearest });
        file.editor.preview_composite_target = nt;
        fresh = true;
        break :blk nt;
    };

    // Skip the (clear + several renderTriangles) re-bake when nothing that feeds
    // the composite changed. The cover-flow reflections animate via mesh
    // displacement only, so during a ripple the baked sprite content is identical
    // frame to frame — this turns a per-frame bake into a no-op while idle/rippling.
    const theme_fill = dvui.themeGet().color(.content, .fill);
    var sig: u64 = file.editor.layer_composite_generation;
    sig = sig *% 1000003 +% file.editor.selection_layer.source.hash();
    if (file.editor.temp_layer_has_content) {
        // `.ptr` invalidation makes `source.hash()` content-blind (it only sees the
        // stable buffer pointer), so a moved hover/brush preview that reuses the same
        // buffer wouldn't change the signature. Use the content generation instead.
        sig = sig *% 1000003 +% file.editor.temp_layer_generation;
    }
    const fill_packed: u32 = @as(u32, theme_fill.r) | @as(u32, theme_fill.g) << 8 | @as(u32, theme_fill.b) << 16 | @as(u32, theme_fill.a) << 24;
    sig = sig *% 1000003 +% @as(u64, fill_packed);
    sig = sig *% 1000003 +% (@as(u64, @intCast(file.columns)) << 16 | @as(u64, @intCast(file.rows)));

    if (!fresh and file.editor.preview_composite_valid and sig == file.editor.preview_composite_sig) return;
    file.editor.preview_composite_sig = sig;
    file.editor.preview_composite_valid = true;

    const sc_t0 = perf.syncCompositeBegin();
    defer perf.syncCompositeEnd(sc_t0);

    const image_rect = dvui.Rect.Physical{ .x = 0, .y = 0, .w = @floatFromInt(w), .h = @floatFromInt(h) };

    target.clear();
    const prev_target = dvui.renderTarget(.{ .texture = target, .offset = image_rect.topLeft() });
    defer _ = dvui.renderTarget(prev_target);

    const prev_clip = dvui.clipGet();
    defer dvui.clipSet(prev_clip);
    dvui.clipSet(image_rect);

    // 1) Opaque content-fill base — the transparency backdrop, matching the card.
    {
        var path: dvui.Path.Builder = .init(runtime.allocator());
        defer path.deinit();
        path.addRect(image_rect, dvui.Rect.Physical.all(0));
        var tris = try path.build().fillConvexTriangles(runtime.allocator(), .{ .color = dvui.themeGet().color(.content, .fill), .fade = 0 });
        defer tris.deinit(runtime.allocator());
        dvui.renderTriangles(tris, null) catch {};
    }

    // 2) Checkerboard tile — one tile per sprite cell (uv repeats columns × rows).
    if (file.checkerboardTileTexture()) |checker| {
        var path: dvui.Path.Builder = .init(runtime.allocator());
        defer path.deinit();
        path.addRect(image_rect, dvui.Rect.Physical.all(0));
        const tint = dvui.themeGet().color(.content, .fill).lighten(6.0).opacity(0.5);
        var tris = try path.build().fillConvexTriangles(runtime.allocator(), .{ .color = tint, .fade = 0 });
        defer tris.deinit(runtime.allocator());
        tris.uvFromRectuv(image_rect, .{ .x = 0, .y = 0, .w = @floatFromInt(file.columns), .h = @floatFromInt(file.rows) });
        dvui.renderTriangles(tris, checker) catch {};
    }

    // 3) Flattened layers, then selection + temp overlays — sampled 1:1.
    var path: dvui.Path.Builder = .init(runtime.allocator());
    defer path.deinit();
    path.addRect(image_rect, dvui.Rect.Physical.all(0));
    var tris = try path.build().fillConvexTriangles(runtime.allocator(), .{ .color = .white, .fade = 0 });
    defer tris.deinit(runtime.allocator());
    tris.uvFromRectuv(image_rect, .{ .x = 0, .y = 0, .w = 1, .h = 1 });

    if (file.editor.layer_composite_target) |ct| {
        if (dvui.Texture.fromTargetTemp(ct) catch null) |ctex| {
            dvui.renderTriangles(tris, ctex) catch {};
        }
    }
    dvui.renderTriangles(tris, file.editor.selection_layer.source.getTexture() catch null) catch {};
    if (file.editor.temp_layer_has_content) {
        dvui.renderTriangles(tris, file.editor.temporary_layer.source.getTexture() catch null) catch {};
    }
}

/// Returns the baked cover-flow preview composite texture for single-pass card
/// drawing, or null when the fast path isn't eligible (peek / isolate / dimming /
/// active drawing / transform). Callers fall back to the multi-pass stack.
pub fn spritePreviewComposite(file: *pixi_mod.internal.File) ?dvui.Texture {
    if (file.peek_layer_index != null) return null;
    if (file.editor.isolate_layer) return null;
    if (file.editor.transform != null) return null;
    if (file.editor.active_drawing) return null;
    const ce = layerCompositeExtent(file);
    if (ce.w == 0 or ce.h == 0) return null;
    syncPreviewComposite(file) catch return null;
    const t = file.editor.preview_composite_target orelse return null;
    return dvui.Texture.fromTargetTemp(t) catch null;
}

pub fn destroyLayerCompositeResources(file: *pixi_mod.internal.File) void {
    if (file.editor.layer_composite_target) |t| {
        t.destroyLater();
        file.editor.layer_composite_target = null;
    }
    file.editor.layer_composite_dirty = true;

    if (file.editor.preview_composite_target) |t| {
        t.destroyLater();
        file.editor.preview_composite_target = null;
    }
    file.editor.preview_composite_frame_built = 0;

    destroySplitCompositeResources(file);
}

pub fn destroySplitCompositeResources(file: *pixi_mod.internal.File) void {
    if (file.editor.split_composite_below) |t| {
        t.destroyLater();
        file.editor.split_composite_below = null;
    }
    if (file.editor.split_composite_above) |t| {
        t.destroyLater();
        file.editor.split_composite_above = null;
    }
    file.editor.split_composite_dirty = true;
    file.editor.split_composite_layer = null;
}

/// Renders visible layers of a file. Uses a cached composite texture when all
/// layers are drawn without peeking or dimming; falls back to per-layer draws
/// otherwise. During active drawing, uses split composites (below/above the
/// active layer) to avoid per-frame render target switches while still reducing
/// draw calls from N to 5.
pub fn renderLayers(init_opts: RenderFileOptions) !void {
    const t0 = perf.renderLayersBegin();
    defer perf.renderLayersEnd(t0);

    perf.draw_render_layers_calls += 1;

    const content_rs = init_opts.rs;

    flushPendingLayerTextureUploads(init_opts);

    if (content_rs.s == 0) return;
    if (dvui.clipGet().intersect(content_rs.r).empty()) return;

    const vs = layerViewStateForRender(init_opts);
    const min_layer_index = vs.min_layer_index;
    const needs_dimmed = vs.needs_dimmed;

    var triangles = if (init_opts.quad) |q| blk: {
        // Skewed quad: build a subdivided mesh so the texture follows the
        // perspective instead of being mapped onto an axis-aligned rect.
        var qpath: dvui.Path.Builder = .init(runtime.allocator());
        defer qpath.deinit();
        qpath.addPoint(q[0]);
        qpath.addPoint(q[1]);
        qpath.addPoint(q[2]);
        qpath.addPoint(q[3]);
        break :blk try pixi_mod.sprite_render.pathToSubdividedQuad(qpath.build(), runtime.allocator(), .{
            .subdivisions = init_opts.quad_subdivisions,
            .uv = init_opts.uv,
            .color_mod = init_opts.color_mod,
        });
    } else blk: {
        var path: dvui.Path.Builder = .init(runtime.allocator());
        defer path.deinit();

        path.addRect(content_rs.r, init_opts.corner_radius.scale(content_rs.s, dvui.Rect.Physical));

        var t = try path.build().fillConvexTriangles(runtime.allocator(), .{ .color = init_opts.color_mod, .fade = init_opts.fade });
        t.uvFromRectuv(content_rs.r, init_opts.uv);
        break :blk t;
    };
    defer triangles.deinit(runtime.allocator());

    var dimmed_triangles: ?dvui.Triangles = null;
    defer {
        if (dimmed_triangles) |*dt| dt.deinit(runtime.allocator());
    }
    if (needs_dimmed) {
        var dt = try triangles.dupe(runtime.allocator());
        dt.color(.gray);
        dimmed_triangles = dt;
    }

    defer {
        if (dvui.textureGetCached(init_opts.file.editor.selection_layer.source.hash()) == null)
            perf.draw_texture_creates += 1;
        dvui.renderTriangles(triangles, init_opts.file.editor.selection_layer.source.getTexture() catch null) catch {
            dvui.log.err("Failed to render selection layer", .{});
        };

        if (init_opts.file.editor.temp_layer_has_content) {
            const temp_source = init_opts.file.editor.temporary_layer.source;
            if (dvui.textureGetCached(temp_source.hash()) == null)
                perf.draw_texture_creates += 1;
            if (dvui.textureGetCached(temp_source.hash())) |cached| {
                dvui.renderTriangles(triangles, cached) catch {
                    dvui.log.err("Failed to render temporary layer", .{});
                };
            } else {
                dvui.renderTriangles(triangles, temp_source.getTexture() catch null) catch {
                    dvui.log.err("Failed to render temporary layer", .{});
                };
            }
        }
    }

    // Active stroke or transform: split composites (below + active + [transform] + above).
    if (splitCompositeEligible(init_opts, min_layer_index, needs_dimmed)) {
        syncSplitComposite(init_opts.file) catch |err| {
            dvui.log.err("Split composite sync failed: {any}", .{err});
        };

        const has_below = init_opts.file.editor.split_composite_below != null;
        const has_above = init_opts.file.editor.split_composite_above != null;

        if (has_below or has_above) {
            if (dvui.textureGetCached(init_opts.file.layers.items(.source)[init_opts.file.selected_layer_index].hash()) == null)
                perf.draw_texture_creates += 1;
            if (has_below) {
                if (dvui.Texture.fromTargetTemp(init_opts.file.editor.split_composite_below.?) catch null) |tex| {
                    dvui.renderTriangles(triangles, tex) catch {
                        dvui.log.err("Failed to render below composite", .{});
                    };
                }
            }

            const active_source = init_opts.file.layers.items(.source)[init_opts.file.selected_layer_index];
            if (init_opts.file.layers.items(.visible)[init_opts.file.selected_layer_index]) {
                if (active_source.getTexture() catch null) |tex| {
                    dvui.renderTriangles(triangles, tex) catch {
                        dvui.log.err("Failed to render active layer", .{});
                    };
                }
            }

            renderTransformIfActive(init_opts, triangles);

            if (has_above) {
                if (dvui.Texture.fromTargetTemp(init_opts.file.editor.split_composite_above.?) catch null) |tex| {
                    dvui.renderTriangles(triangles, tex) catch {
                        dvui.log.err("Failed to render above composite", .{});
                    };
                }
            }

            return;
        }
    }

    // When idle: use full composite (all layers = 1 draw)
    if (fullCompositeEligible(init_opts, min_layer_index, needs_dimmed)) {
        syncLayerComposite(init_opts.file) catch |err| {
            dvui.log.err("Layer composite sync failed: {any}", .{err});
        };
        if (init_opts.file.editor.layer_composite_target) |ct| {
            if (dvui.Texture.fromTargetTemp(ct) catch null) |ctex| {
                dvui.renderTriangles(triangles, ctex) catch {
                    dvui.log.err("Failed to render layer composite", .{});
                };
                return;
            }
        }
    }

    // Fallback: per-layer rendering
    var order_buf: [1024]usize = undefined;
    const order_opt = layerOrderBufForDragPreview(init_opts.file, order_buf[0..]);

    var list_pos: usize = init_opts.file.layers.len;
    while (list_pos > min_layer_index) {
        list_pos -= 1;
        const layer_index = if (order_opt) |o| o[list_pos] else list_pos;

        const visible = init_opts.file.layers.items(.visible)[layer_index];

        var tris = triangles;

        if (needs_dimmed) {
            if (init_opts.file.peek_layer_index) |peek_layer_index| {
                if (peek_layer_index != layer_index) {
                    tris = dimmed_triangles.?;
                }
            }
        }

        if (visible) {
            const source = init_opts.file.layers.items(.source)[layer_index];
            if (source.getTexture() catch null) |tex| {
                dvui.renderTriangles(tris, tex) catch {
                    dvui.log.err("Failed to render triangles", .{});
                };
            }
        }

        if (layer_index == init_opts.file.selected_layer_index) {
            renderTransformIfActive(init_opts, triangles);
        }
    }
}
