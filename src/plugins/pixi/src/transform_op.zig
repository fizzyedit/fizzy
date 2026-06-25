//! Begin a transform on the active document (selection → transform handles).
const dvui = @import("dvui");
const pixi_mod = @import("../pixi.zig");
const runtime = @import("runtime.zig");
const State = pixi_mod.State;
const Internal = pixi_mod.internal;

fn activeFile(st: *State) ?*Internal.File {
    const doc = st.host.activeDoc() orelse return null;
    return st.docs.fileById(doc.id);
}

pub fn begin(st: *State) !void {
    const file = activeFile(st) orelse return;
    if (file.editor.transform) |*t| {
        t.cancel();
    }

    var selected_layer = file.layers.get(file.selected_layer_index);

    switch (st.tools.current) {
        .selection => {
            file.editor.transform_layer.clear();
            var pixel_iterator = file.editor.selection_layer.mask.iterator(.{ .kind = .set, .direction = .forward });
            while (pixel_iterator.next()) |pixel_index| {
                @memcpy(&file.editor.transform_layer.pixels()[pixel_index], &selected_layer.pixels()[pixel_index]);
                selected_layer.pixels()[pixel_index] = .{ 0, 0, 0, 0 };
                file.editor.transform_layer.mask.set(pixel_index);
            }
            selected_layer.invalidate();
        },
        else => {
            file.editor.transform_layer.clear();

            if (file.editor.selected_sprites.count() > 0) {
                var sprite_iterator = file.editor.selected_sprites.iterator(.{ .kind = .set, .direction = .forward });

                while (sprite_iterator.next()) |index| {
                    const source_rect = file.spriteRect(index);
                    if (selected_layer.pixelsFromRect(
                        dvui.currentWindow().arena(),
                        source_rect,
                    )) |source_pixels| {
                        file.editor.transform_layer.blit(
                            source_pixels,
                            source_rect,
                            .{ .transparent = true, .mask = true },
                        );
                        selected_layer.clearRect(source_rect);
                    }
                }
            } else {
                if (file.editor.canvas.hovered) {
                    if (file.spriteIndex(file.editor.canvas.dataFromScreenPoint(dvui.currentWindow().mouse_pt))) |sprite_index| {
                        const rect = file.spriteRect(sprite_index);
                        if (selected_layer.pixelsFromRect(
                            dvui.currentWindow().arena(),
                            rect,
                        )) |source_pixels| {
                            file.editor.transform_layer.blit(
                                source_pixels,
                                rect,
                                .{ .transparent = true, .mask = true },
                            );
                            selected_layer.clearRect(rect);
                        }
                    }
                } else if (file.selected_animation_index) |animation_index| {
                    const animation = file.animations.get(animation_index);
                    if (file.selected_animation_frame_index < animation.frames.len) {
                        const source_rect = file.spriteRect(animation.frames[file.selected_animation_frame_index].sprite_index);
                        if (selected_layer.pixelsFromRect(
                            dvui.currentWindow().arena(),
                            source_rect,
                        )) |source_pixels| {
                            file.editor.transform_layer.blit(
                                source_pixels,
                                source_rect,
                                .{ .transparent = true, .mask = true },
                            );
                            selected_layer.clearRect(source_rect);
                        }
                    }
                }
            }
        },
    }

    const source_rect = dvui.Rect.fromSize(file.editor.transform_layer.size());
    if (file.editor.transform_layer.reduce(source_rect)) |reduced_data_rect| {
        defer file.editor.selection_layer.clearMask();
        const gpa = runtime.allocator();
        file.editor.transform = .{
            .target_texture = dvui.textureCreateTarget(.{ .width = file.width(), .height = file.height(), .format = pixi_mod.render.compositeTargetPixelFormat(), .interpolation = .nearest }) catch {
                dvui.log.err("Failed to create target texture", .{});
                return;
            },
            .file_id = file.id,
            .layer_id = selected_layer.id,
            .data_points = .{
                reduced_data_rect.topLeft(),
                reduced_data_rect.topRight(),
                reduced_data_rect.bottomRight(),
                reduced_data_rect.bottomLeft(),
                reduced_data_rect.center(),
                reduced_data_rect.center(),
            },
            .source = pixi_mod.image.fromPixelsPMA(
                @ptrCast(file.editor.transform_layer.pixelsFromRect(gpa, reduced_data_rect)),
                @intFromFloat(reduced_data_rect.w),
                @intFromFloat(reduced_data_rect.h),
                .ptr,
            ) catch return error.MemoryAllocationFailed,
        };

        for (file.editor.transform.?.data_points[0..4]) |*point| {
            const d = point.diff(file.editor.transform.?.point(.pivot).*);
            if (d.length() > file.editor.transform.?.radius) {
                file.editor.transform.?.radius = d.length() + 4;
            }
        }
    }
}
