const std = @import("std");
const fizzy = @import("../../fizzy.zig");
const dvui = @import("dvui");
const zigimg = @import("zigimg");
const msf_gif = @import("msf_gif");
const sdl3 = @import("backend").c;
const zstbi = @import("zstbi");

const Dialogs = @import("Dialogs.zig");

pub var mode: enum(usize) {
    single,
    animation,
    layer,
    all,
} = .animation;

pub var scale: f32 = 1.0;

pub var scroll_info: dvui.ScrollInfo = .{
    .horizontal = .auto,
    .vertical = .auto,
};

pub var scroll_info_full: dvui.ScrollInfo = .{
    .horizontal = .auto,
    .vertical = .auto,
};

pub const max_size: [2]u32 = .{ 4096, 4096 };
pub const min_size: [2]u32 = .{ 1, 1 };

pub const min_scale: u32 = 1;

pub var anim_frame_index: usize = 0;

pub fn dialog(id: dvui.Id) anyerror!bool {
    var outer_box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer outer_box.deinit();

    { // Mode selector

        var horizontal_box = dvui.box(@src(), .{ .dir = .horizontal, .equal_space = true }, .{ .expand = .none, .gravity_x = 0.5, .margin = .all(4) });
        defer horizontal_box.deinit();

        const field_names = std.meta.fieldNames(@TypeOf(mode));

        for (field_names, 0..) |tag, i| {
            const corner_radius: dvui.Rect = if (i == 0) .{
                .x = 100000,
                .h = 100000,
            } else if (i == field_names.len - 1) .{
                .y = 100000,
                .w = 100000,
            } else .all(0);

            var name = dvui.currentWindow().arena().dupe(u8, tag) catch {
                dvui.log.err("Failed to dupe tag {s}", .{tag});
                return false;
            };
            @memcpy(name.ptr, tag);
            name[0] = std.ascii.toUpper(name[0]);

            var button: dvui.ButtonWidget = undefined;
            button.init(@src(), .{}, .{
                .corner_radius = corner_radius,
                .id_extra = i,
                .margin = .{ .y = 2, .h = 4 },
                .padding = .all(6),
                .expand = .horizontal,
                .color_fill = if (mode == @as(@TypeOf(mode), @enumFromInt(i))) dvui.themeGet().color(.window, .fill).lighten(-4) else dvui.themeGet().color(.control, .fill),
                .box_shadow = if (i != @intFromEnum(mode)) .{
                    .color = .black,
                    .offset = .{ .x = 0.0, .y = 2 },
                    .fade = 7.0,
                    .alpha = 0.2,
                    .corner_radius = corner_radius,
                    .shrink = 0,
                } else null,
            });
            defer button.deinit();
            if (i != @intFromEnum(mode)) {
                button.processEvents();
            }

            var clip_rect = button.data().rectScale().r;

            clip_rect.y -= 10000;
            clip_rect.h += 20000;

            if (i == 0) {
                clip_rect.x -= 10000;
                clip_rect.w += 10000;
            } else if (i == field_names.len - 1) {
                clip_rect.w += 10000;
            }

            const clip = dvui.clip(clip_rect);
            defer dvui.clipSet(clip);

            button.drawFocus();
            button.drawBackground();

            dvui.labelNoFmt(@src(), name, .{}, .{
                .gravity_x = 0.5,
                .gravity_y = 0.5,
                .color_text = if (mode == @as(@TypeOf(mode), @enumFromInt(i))) dvui.themeGet().color(.window, .text) else dvui.themeGet().color(.control, .text),
                .margin = .all(0),
                .padding = .all(0),
            });

            if (button.clicked()) {
                mode = @enumFromInt(i);
                // Second layout pass after the scroll+preview id stabilizes; avoids one blank frame.
                dvui.currentWindow().extra_frames_needed = 2;
            }
        }
    }

    const mode_valid: bool = switch (mode) {
        .single => try singleDialog(id),
        .animation => try animationDialog(id),
        .layer => try layerDialog(id),
        .all => try allDialog(id),
    };

    return mode_valid and (fizzy.editor.activeFile() != null);
}

pub fn singleDialog(_: dvui.Id) anyerror!bool {
    const max_gif_size: [2]f32 = .{ 1024, 1024 };
    var max_scale: f32 = 16.0;
    var valid: bool = false;

    if (fizzy.editor.activeFile()) |file| {
        if (file.editor.selected_sprites.findFirstSet() != null) {
            max_scale = @min(@divTrunc(max_gif_size[0], @as(f32, @floatFromInt(file.column_width))), @divTrunc(max_gif_size[1], @as(f32, @floatFromInt(file.row_height))));
            valid = true;
        }
    }

    if (fizzy.editor.activeFile()) |file| {
        if (file.editor.selected_sprites.findFirstSet()) |sprite_index| {
            renderExportPreviewSprite(file, sprite_index);
        }
    }

    exportScaleSlider(max_scale);

    if (fizzy.editor.activeFile()) |file| {
        if (file.editor.selected_sprites.findFirstSet() != null) {
            const column_width: u32 = @intFromFloat(@as(f32, @floatFromInt(file.column_width)) * scale);
            const row_height: u32 = @intFromFloat(@as(f32, @floatFromInt(file.row_height)) * scale);
            exportDimensionsLabelForExport(column_width, row_height);
        }
    }

    return valid;
}

pub fn animationDialog(id: dvui.Id) anyerror!bool {
    const max_gif_size: [2]f32 = .{ 1024, 1024 };
    var max_scale: f32 = 16.0;
    var preview_sprite: ?usize = null;

    if (fizzy.editor.activeFile()) |file| {
        max_scale = @min(
            @divTrunc(max_gif_size[0], @as(f32, @floatFromInt(file.column_width))),
            @divTrunc(max_gif_size[1], @as(f32, @floatFromInt(file.row_height))),
        );
        if (file.selected_animation_index) |animation_index| {
            const anim = file.animations.get(animation_index);
            if (anim.frames.len > 0) {
                if (dvui.timerDoneOrNone(id)) {
                    if (anim_frame_index >= anim.frames.len - 1) {
                        anim_frame_index = 0;
                    } else {
                        anim_frame_index += 1;
                    }
                    const millis_per_frame = anim.frames[anim_frame_index].ms;
                    dvui.timer(id, @intCast(millis_per_frame * 1000));
                }
                if (anim_frame_index >= anim.frames.len) {
                    anim_frame_index = 0;
                }
                preview_sprite = anim.frames[anim_frame_index].sprite_index;
            }
        }
    }

    if (fizzy.editor.activeFile()) |file| {
        if (preview_sprite) |sprite_index| {
            renderExportPreviewSprite(file, sprite_index);
        }
    }

    exportScaleSlider(max_scale);

    if (preview_sprite) |_| {
        if (fizzy.editor.activeFile()) |file| {
            const column_width: u32 = @intFromFloat(@as(f32, @floatFromInt(file.column_width)) * scale);
            const row_height: u32 = @intFromFloat(@as(f32, @floatFromInt(file.row_height)) * scale);
            exportDimensionsLabelForExport(column_width, row_height);
        }
    }

    return preview_sprite != null;
}

pub fn layerDialog(_: dvui.Id) anyerror!bool {
    if (fizzy.editor.activeFile()) |file| {
        renderExportPreview(file, .layer);
    }
    if (fizzy.editor.activeFile()) |file| {
        exportDimensionsLabelForExport(file.width(), file.height());
    }
    return true;
}

pub fn allDialog(_: dvui.Id) anyerror!bool {
    if (fizzy.editor.activeFile()) |file| {
        renderExportPreview(file, .composite);
    }
    if (fizzy.editor.activeFile()) |file| {
        exportDimensionsLabelForExport(file.width(), file.height());
    }
    return true;
}

pub fn callAfter(_: dvui.Id, response: dvui.enums.DialogResponse) anyerror!void {
    switch (response) {
        .ok => {
            switch (mode) {
                .animation => {
                    const default = blk: {
                        const file = fizzy.editor.activeFile() orelse {
                            break :blk "animation.gif";
                        };

                        const default_filename: [:0]const u8 = std.fmt.allocPrintSentinel(fizzy.app.allocator, "{s}.gif", .{
                            if (file.selected_animation_index) |animation_index| file.animations.items(.name)[animation_index] else "animation",
                        }, 0) catch {
                            dvui.log.err("Failed to allocate filename", .{});
                            return;
                        };

                        break :blk default_filename;
                    };

                    fizzy.backend.showSaveFileDialog(
                        saveAnimationCallback,
                        &[_]sdl3.SDL_DialogFileFilter{.{ .name = "GIF", .pattern = "gif" }},
                        default,
                        null, // Passing null here means use the last save folder location
                    );
                },
                .single => {
                    const file = fizzy.editor.activeFile() orelse return;
                    const sprite_index = file.editor.selected_sprites.findFirstSet() orelse return;

                    const base = file.spriteExportName(fizzy.app.allocator, sprite_index) catch {
                        dvui.log.err("Failed to allocate default export name", .{});
                        return;
                    };
                    defer fizzy.app.allocator.free(base);

                    const default = std.fmt.allocPrintSentinel(fizzy.app.allocator, "{s}.png", .{base}, 0) catch {
                        dvui.log.err("Failed to allocate filename", .{});
                        return;
                    };
                    defer fizzy.app.allocator.free(default);

                    fizzy.backend.showSaveFileDialog(
                        exportCurrentSpriteCallback,
                        &[_]sdl3.SDL_DialogFileFilter{
                            .{ .name = "PNG", .pattern = "png" },
                            .{ .name = "JPEG", .pattern = "jpg;jpeg" },
                        },
                        default,
                        null,
                    );
                },
                .layer => {
                    const file = fizzy.editor.activeFile() orelse return;
                    const base = file.layerExportBaseName(fizzy.app.allocator) catch {
                        dvui.log.err("Failed to allocate default export name", .{});
                        return;
                    };
                    defer fizzy.app.allocator.free(base);

                    const default = std.fmt.allocPrintSentinel(fizzy.app.allocator, "{s}.png", .{base}, 0) catch {
                        dvui.log.err("Failed to allocate filename", .{});
                        return;
                    };
                    defer fizzy.app.allocator.free(default);

                    fizzy.backend.showSaveFileDialog(
                        exportLayerCallback,
                        &[_]sdl3.SDL_DialogFileFilter{
                            .{ .name = "PNG", .pattern = "png" },
                            .{ .name = "JPEG", .pattern = "jpg;jpeg" },
                        },
                        default,
                        null,
                    );
                },
                .all => {
                    const file = fizzy.editor.activeFile() orelse return;
                    const base = file.allExportBaseName(fizzy.app.allocator) catch {
                        dvui.log.err("Failed to allocate default export name", .{});
                        return;
                    };
                    defer fizzy.app.allocator.free(base);

                    const default = std.fmt.allocPrintSentinel(fizzy.app.allocator, "{s}.png", .{base}, 0) catch {
                        dvui.log.err("Failed to allocate filename", .{});
                        return;
                    };
                    defer fizzy.app.allocator.free(default);

                    fizzy.backend.showSaveFileDialog(
                        exportAllCallback,
                        &[_]sdl3.SDL_DialogFileFilter{
                            .{ .name = "PNG", .pattern = "png" },
                            .{ .name = "JPEG", .pattern = "jpg;jpeg" },
                        },
                        default,
                        null,
                    );
                },
            }
        },
        .cancel => {},
        else => {},
    }
}

/// One call site for the export preview scroll+tile so widget ids (and first-frame layout) stay
/// stable when switching between Single and Animation. Otherwise `renderLayers` early-outs for
/// one frame with `content_rs.s == 0` on a fresh scroll id.
fn renderExportPreviewSprite(file: *fizzy.Internal.File, sprite_index: usize) void {
    const sprite_rect = file.spriteRect(sprite_index);
    const max_size_content: dvui.Size = .{
        .w = (dvui.currentWindow().rect_pixels.w / dvui.currentWindow().natural_scale) / 2,
        .h = (dvui.currentWindow().rect_pixels.h / dvui.currentWindow().natural_scale) / 2.0,
    };
    const min_size_content: dvui.Size = sprite_rect.justSize().scale(scale, dvui.Rect).size();

    var scroll_area = dvui.scrollArea(@src(), .{
        .scroll_info = &scroll_info,
        .horizontal_bar = .auto_overlay,
        .vertical_bar = .auto_overlay,
    }, .{
        .background = false,
        .expand = .both,
        .max_size_content = .{ .w = max_size_content.w, .h = max_size_content.h },
    });
    defer scroll_area.deinit();

    {
        var box = dvui.box(@src(), .{
            .dir = .horizontal,
        }, .{
            .expand = .none,
            .min_size_content = min_size_content,
            .gravity_x = 0.5,
        });
        defer box.deinit();

        const uv = dvui.Rect{
            .x = sprite_rect.x / @as(f32, @floatFromInt(file.width())),
            .y = sprite_rect.y / @as(f32, @floatFromInt(file.height())),
            .w = sprite_rect.w / @as(f32, @floatFromInt(file.width())),
            .h = sprite_rect.h / @as(f32, @floatFromInt(file.height())),
        };

        // Same tiled checker + tone as layer/all. Sprite box natural space is (0,0)–(sw×scale,sh×scale)
        // (see `min_size_content`), not file coordinates—geometry must be local, UVs use file `sprite_rect`.
        const local_natural = dvui.Rect{ .x = 0, .y = 0, .w = sprite_rect.w * scale, .h = sprite_rect.h * scale };
        drawCheckerboardTiled(file, sprite_rect, local_natural, box.data().rectScale());

        fizzy.render.renderLayers(.{
            .file = file,
            .rs = box.data().rectScale(),
            .uv = uv,
        }) catch {
            dvui.log.err("Failed to render layers", .{});
        };
    }
}

fn exportScaleSlider(max_scale_val: f32) void {
    if (dvui.sliderEntry(@src(), "Scale: {d}", .{ .value = &scale, .min = 1, .max = max_scale_val, .interval = 1 }, .{
        .expand = .horizontal,
        .box_shadow = .{
            .color = .black,
            .offset = .{ .x = 0.0, .y = 3 },
            .fade = 5.0,
            .alpha = 0.2,
            .corner_radius = .all(100000),
        },
        .color_fill = dvui.themeGet().color(.window, .fill).lighten(-4),
        .color_fill_hover = dvui.themeGet().color(.window, .fill).lighten(2),
        .corner_radius = .all(100000),
        .margin = .all(6),
    })) dvui.currentWindow().extra_frames_needed = 2;
}

fn exportDimensionsLabelForExport(column_w: u32, row_h: u32) void {
    const entry_font = dvui.Font.theme(.mono).larger(-2);
    Dialogs.drawDimensionsLabel(@src(), column_w, row_h, entry_font, "px", .{ .gravity_x = 0.5 });
}

const ExportFullPreviewKind = enum { layer, composite };

/// `uv_file` is the region in file pixel coordinates; UVs tile by column/row (same as
/// `FileWidget.drawCheckerboardCellsBatched` for `transparency_effect == .none`).
/// `geometry_natural` is the rect in the widget’s natural space used for `rectToPhysical` (matches
/// full file for layer/all, or `0,0,sw×scale,sh×scale` for the sprite export box).
fn drawCheckerboardTiled(
    file: *fizzy.Internal.File,
    uv_file: dvui.Rect,
    geometry_natural: dvui.Rect,
    rs_box: dvui.RectScale,
) void {
    const col_w = @as(f32, @floatFromInt(file.column_width));
    const row_h = @as(f32, @floatFromInt(file.row_height));
    if (col_w <= 0 or row_h <= 0) return;
    const r = rs_box.rectToPhysical(geometry_natural);
    const tl = r.topLeft();
    const tr = r.topRight();
    const br = r.bottomRight();
    const bl = r.bottomLeft();
    const uv_x0 = uv_file.x / col_w;
    const uv_y0 = uv_file.y / row_h;
    const uv_x1 = (uv_file.x + uv_file.w) / col_w;
    const uv_y1 = (uv_file.y + uv_file.h) / row_h;
    const tone = dvui.themeGet().color(.content, .fill).lighten(6.0).opacity(0.5).opacity(dvui.currentWindow().alpha);
    const pma = dvui.Color.PMA.fromColor(tone);
    const arena = dvui.currentWindow().arena();
    var builder = dvui.Triangles.Builder.init(arena, 4, 6) catch return;
    defer builder.deinit(arena);
    builder.appendVertex(.{ .pos = tl, .col = pma, .uv = .{ uv_x0, uv_y0 } });
    builder.appendVertex(.{ .pos = tr, .col = pma, .uv = .{ uv_x1, uv_y0 } });
    builder.appendVertex(.{ .pos = br, .col = pma, .uv = .{ uv_x1, uv_y1 } });
    builder.appendVertex(.{ .pos = bl, .col = pma, .uv = .{ uv_x0, uv_y1 } });
    builder.appendTriangles(&.{ 1, 0, 3, 1, 3, 2 });
    const triangles = builder.build();
    dvui.renderTriangles(triangles, file.editor.checkerboard_tile.getTexture() catch null) catch {
        dvui.log.err("Failed to render export preview checkerboard", .{});
    };
}

/// Full-canvas preview at 1:1 logical pixels: checkerboard + either the selected layer only or the
/// flattened composite (all visible layers). One scroll + box `call site for stable widget ids.
fn renderExportPreview(file: *fizzy.Internal.File, kind: ExportFullPreviewKind) void {
    const w = file.width();
    const h = file.height();
    if (w == 0 or h == 0) return;

    if (kind == .composite) {
        fizzy.render.syncLayerComposite(file) catch {
            dvui.log.err("Export preview: failed to build layer composite", .{});
            return;
        };
    }

    const max_size_content: dvui.Size = .{
        .w = (dvui.currentWindow().rect_pixels.w / dvui.currentWindow().natural_scale) / 2,
        .h = (dvui.currentWindow().rect_pixels.h / dvui.currentWindow().natural_scale) / 2.0,
    };
    const min_size_content: dvui.Size = .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };

    var scroll_area = dvui.scrollArea(@src(), .{
        .scroll_info = &scroll_info_full,
        .horizontal_bar = .auto_overlay,
        .vertical_bar = .auto_overlay,
    }, .{
        .background = false,
        .expand = .both,
        .max_size_content = .{ .w = max_size_content.w, .h = max_size_content.h },
    });
    defer scroll_area.deinit();

    {
        var box = dvui.box(@src(), .{
            .dir = .horizontal,
        }, .{
            .expand = .none,
            .min_size_content = min_size_content,
            .gravity_x = 0.5,
        });
        defer box.deinit();

        // Tiled cell UVs over the full image (same as `FileWidget.drawCheckerboardCellsBatched` for
        // `transparency_effect == .none` — not one stretched cell across the whole preview).
        const full_r = dvui.Rect{ .x = 0, .y = 0, .w = @floatFromInt(w), .h = @floatFromInt(h) };
        drawCheckerboardTiled(file, full_r, full_r, box.data().rectScale());

        const full_uv = dvui.Rect{ .x = 0, .y = 0, .w = 1, .h = 1 };
        const rs = box.data().rectScale();

        var path_tris: dvui.Path.Builder = .init(fizzy.app.allocator);
        defer path_tris.deinit();
        path_tris.addRect(rs.r, .all(0));
        var tris = path_tris.build().fillConvexTriangles(fizzy.app.allocator, .{ .color = .white, .fade = 0.0 }) catch {
            return;
        };
        defer tris.deinit(fizzy.app.allocator);
        tris.uvFromRectuv(rs.r, full_uv);

        switch (kind) {
            .layer => {
                const layer = file.layers.get(file.selected_layer_index);
                if (layer.visible) {
                    if (layer.source.getTexture() catch null) |tex| {
                        dvui.renderTriangles(tris, tex) catch {
                            dvui.log.err("Failed to render layer for export preview", .{});
                        };
                    }
                }
            },
            .composite => {
                if (file.editor.layer_composite_target) |ct| {
                    if (dvui.Texture.fromTargetTemp(ct) catch null) |ctex| {
                        dvui.renderTriangles(tris, ctex) catch {
                            dvui.log.err("Failed to draw composite for export preview", .{});
                        };
                    }
                }
            },
        }
    }
}

/// Flatten visible layers for one sprite tile. Layer index `0` is the front (drawn last on canvas);
/// higher indices sit behind. `blitData` composites its **first** buffer (upper) over the **second** (lower).
fn compositedSpritePixels(allocator: std.mem.Allocator, file: *fizzy.Internal.File, sprite_index: usize) ![][4]u8 {
    const sprite_rect = file.spriteRect(sprite_index);
    const w: usize = @intFromFloat(sprite_rect.w);
    const h: usize = @intFromFloat(sprite_rect.h);

    var front: usize = 0;
    while (front < file.layers.len) : (front += 1) {
        const layer = file.layers.get(front);
        if (!layer.visible) continue;

        const pixels = layer.pixelsFromRect(allocator, sprite_rect) orelse continue;
        errdefer allocator.free(pixels);

        var behind = front + 1;
        while (behind < file.layers.len) : (behind += 1) {
            const lower = file.layers.get(behind);
            if (!lower.visible) continue;

            const layer_pixels = lower.pixelsFromRect(allocator, sprite_rect) orelse continue;
            defer allocator.free(layer_pixels);

            fizzy.image.blitData(pixels, w, h, layer_pixels, sprite_rect.justSize(), true);
        }

        return pixels;
    }

    return error.NoPixels;
}

// This is for use with the SDL dialogs, but currently the SDL dialogs dont support sending the default path
// on macOS, so we are going to use the native dialogs instead.
pub fn saveAnimationCallback(paths: ?[][:0]const u8) void {
    if (paths) |paths_| {
        for (paths_) |path| {
            createAnimationGif(path) catch |err| {
                dvui.log.err("Failed to save animation: {any}", .{err});
            };
        }
    }
}

pub fn exportCurrentSpriteCallback(paths: ?[][:0]const u8) void {
    if (paths) |paths_| {
        for (paths_) |path| {
            exportCurrentSprite(path) catch |err| {
                dvui.log.err("Failed to save image: {any}", .{err});
            };
        }
    }
}

pub fn exportLayerCallback(paths: ?[][:0]const u8) void {
    if (paths) |paths_| {
        for (paths_) |path| {
            exportLayerToPath(path) catch |err| {
                dvui.log.err("Failed to save layer: {any}", .{err});
            };
        }
    }
}

pub fn exportAllCallback(paths: ?[][:0]const u8) void {
    if (paths) |paths_| {
        for (paths_) |path| {
            exportAllToPath(path) catch |err| {
                dvui.log.err("Failed to save image: {any}", .{err});
            };
        }
    }
}

pub fn exportCurrentSprite(path: []const u8) anyerror!void {
    const ext = std.fs.path.extension(path);
    const is_png = std.mem.eql(u8, ext, ".png");
    const is_jpg = std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg");
    if (!is_png and !is_jpg) {
        dvui.log.err("Export: File must be .png or .jpg, got {s}", .{ext});
        return error.InvalidExtension;
    }

    const file = fizzy.editor.activeFile() orelse {
        dvui.log.err("Export: No active file", .{});
        return error.NoActiveFile;
    };
    const sprite_index = file.editor.selected_sprites.findFirstSet() orelse {
        dvui.log.err("Export: No tile selected", .{});
        return error.NoSelectedTile;
    };

    var export_width: u32 = file.column_width;
    var export_height: u32 = file.row_height;
    if (scale != 1.0) {
        export_width = @intFromFloat(@as(f32, @floatFromInt(file.column_width)) * scale);
        export_height = @intFromFloat(@as(f32, @floatFromInt(file.row_height)) * scale);
    }

    const pixels = try compositedSpritePixels(fizzy.app.allocator, file, sprite_index);
    defer fizzy.app.allocator.free(pixels);

    if (scale != 1.0) {
        const resized = fizzy.app.allocator.alloc([4]u8, export_width * export_height) catch {
            return error.OutOfMemory;
        };
        defer fizzy.app.allocator.free(resized);
        if (zstbi.resize(
            pixels,
            file.column_width,
            file.row_height,
            resized,
            export_width,
            export_height,
        ) == null) {
            return error.ResizeFailed;
        }

        const src: dvui.ImageSource = .{ .pixels = .{
            .rgba = std.mem.sliceAsBytes(resized),
            .width = export_width,
            .height = export_height,
        } };
        // `writeToPng` / `writeToJpg` use `windowNaturalScale` and require `Window.begin`/`end`.
        // File dialog callbacks (e.g. NSOpenPanel) can run when `currentWindow` is null.
        if (is_png) {
            try fizzy.image.writeToPngResolution(src, path, 0);
        } else {
            try fizzy.image.writeToJpgPpi(src, path, 0);
        }
    } else {
        const src: dvui.ImageSource = .{ .pixels = .{
            .rgba = std.mem.sliceAsBytes(pixels),
            .width = file.column_width,
            .height = file.row_height,
        } };
        if (is_png) {
            try fizzy.image.writeToPngResolution(src, path, 0);
        } else {
            try fizzy.image.writeToJpgPpi(src, path, 0);
        }
    }
}

pub fn exportLayerToPath(path: []const u8) anyerror!void {
    const ext = std.fs.path.extension(path);
    const is_png = std.mem.eql(u8, ext, ".png");
    const is_jpg = std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg");
    if (!is_png and !is_jpg) {
        dvui.log.err("Export: File must be .png, .jpg, or .jpeg, got {s}", .{ext});
        return error.InvalidExtension;
    }

    const file = fizzy.editor.activeFile() orelse {
        dvui.log.err("Export: No active file", .{});
        return error.NoActiveFile;
    };

    const layer = file.layers.get(file.selected_layer_index);
    const src = layer.source;
    if (is_png) {
        try fizzy.image.writeToPngResolution(src, path, 0);
    } else {
        try fizzy.image.writeToJpgPpi(src, path, 0);
    }
}

pub fn exportAllToPath(path: []const u8) anyerror!void {
    const ext = std.fs.path.extension(path);
    const is_png = std.mem.eql(u8, ext, ".png");
    const is_jpg = std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg");
    if (!is_png and !is_jpg) {
        dvui.log.err("Export: File must be .png, .jpg, or .jpeg, got {s}", .{ext});
        return error.InvalidExtension;
    }

    const file = fizzy.editor.activeFile() orelse {
        dvui.log.err("Export: No active file", .{});
        return error.NoActiveFile;
    };

    const w = file.width();
    const h = file.height();
    if (w == 0 or h == 0) return error.InvalidImageSize;

    try fizzy.render.syncLayerComposite(file);
    const target = file.editor.layer_composite_target orelse {
        return error.NoLayerComposite;
    };

    const pma_read: []dvui.Color.PMA = try dvui.Texture.readTarget(fizzy.app.allocator, target);
    defer {
        const byte_len = pma_read.len * @sizeOf(dvui.Color.PMA);
        fizzy.app.allocator.free(@as([*]u8, @ptrCast(pma_read.ptr))[0..byte_len]);
    }

    var tmp_layer: fizzy.Internal.Layer = try .fromPixelsPMA(0, "export", pma_read, w, h, .ptr);
    defer tmp_layer.deinit();

    if (is_png) {
        try fizzy.image.writeToPngResolution(tmp_layer.source, path, 0);
    } else {
        try fizzy.image.writeToJpgPpi(tmp_layer.source, path, 0);
    }
}

pub fn createAnimationGif(path: []const u8) anyerror!void {
    const ext = std.fs.path.extension(path);
    const is_gif = std.mem.eql(u8, ext, ".gif");

    if (!is_gif) {
        dvui.log.err("Export: File must end with .gif extension, got {s}", .{ext});
        return error.InvalidExtension;
    }

    const file = fizzy.editor.activeFile() orelse {
        dvui.log.err("Export: No active file", .{});
        return error.NoActiveFile;
    };

    if (file.animations.len == 0) {
        dvui.log.err("Export: No animations in file", .{});
        return error.NoAnimations;
    }

    if (file.selected_animation_index) |animation_index| {
        const anim: fizzy.Internal.Animation = file.animations.get(animation_index);

        var export_width = file.column_width;
        var export_height = file.row_height;

        if (scale != 1.0) {
            export_width = @intFromFloat(@as(f32, @floatFromInt(file.column_width)) * scale);
            export_height = @intFromFloat(@as(f32, @floatFromInt(file.row_height)) * scale);
        }

        var handle: msf_gif.MSFGifState = undefined;
        _ = msf_gif.begin(&handle, export_width, export_height);

        // Anything less than this number will be considered transparent
        // When resizing, sometimes we see a small outline of the pixels?
        // Only see in some gif readers, but not all.
        msf_gif.msf_gif_alpha_threshold = 240;

        for (anim.frames) |frame| {
            const pixels = compositedSpritePixels(fizzy.app.allocator, file, frame.sprite_index) catch |err| {
                if (err == error.NoPixels) continue;
                return err;
            };
            defer fizzy.app.allocator.free(pixels);

            { // msf_gif will error if there are only transparent pixels
                const valid = blk: {
                    for (pixels) |pixel| {
                        if (pixel[3] > msf_gif.msf_gif_alpha_threshold) {
                            break :blk true;
                        }
                    }

                    break :blk false;
                };

                if (!valid) {
                    dvui.log.debug("Export: No valid pixels, skipping animation frame", .{});
                    continue;
                }
            }

            if (scale != 1.0) {
                const resized_pixels = fizzy.app.allocator.alloc([4]u8, export_width * export_height) catch {
                    dvui.log.err("Failed to allocate resized pixels", .{});
                    continue;
                };
                defer fizzy.app.allocator.free(resized_pixels);

                _ = zstbi.resize(
                    pixels,
                    file.column_width,
                    file.row_height,
                    resized_pixels,
                    export_width,
                    export_height,
                );

                _ = msf_gif.frame(&handle, @ptrCast(resized_pixels.ptr), @divTrunc(@as(i32, @intCast(frame.ms)), 10));
            } else {
                _ = msf_gif.frame(&handle, @ptrCast(pixels.ptr), @divTrunc(@as(i32, @intCast(frame.ms)), 10));
            }
        }

        const result = msf_gif.end(&handle);
        defer msf_gif.free(result);

        // // Now write to file using the new Writer interface
        if (result.data) |data| {
            std.Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = path, .data = data[0..result.dataSize] }) catch {
                dvui.log.err("Failed to write to file {s}", .{path});
                return;
            };
        }

        return;
    }

    return error.NoSelectedAnimation;
}
