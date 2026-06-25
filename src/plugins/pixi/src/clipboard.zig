//! Sprite copy/paste for the pixel-art plugin. Backs the `pixi_mod.copy` / `pixi_mod.paste`
//! commands and pixel-art's own canvas handlers; the shell never owns this logic.
const std = @import("std");
const dvui = @import("dvui");
const pixi_mod = @import("../pixi.zig");
const runtime = @import("runtime.zig");
const State = pixi_mod.State;
const Internal = pixi_mod.internal;

fn activeFile(st: *State) ?*Internal.File {
    const doc = st.host.activeDoc() orelse return null;
    return st.docs.fileById(doc.id);
}

pub fn copy(st: *State) !void {
    const file = activeFile(st) orelse return;
    if (file.editor.transform != null) return;

    if (st.sprite_clipboard) |*clipboard| {
        runtime.allocator().free(pixi_mod.image.bytes(clipboard.source));
        st.sprite_clipboard = null;
    }

    file.editor.transform_layer.clear();

    var selected_layer = file.layers.get(file.selected_layer_index);
    switch (st.tools.current) {
        .selection => {
            var pixel_iterator = file.editor.selection_layer.mask.iterator(.{ .kind = .set, .direction = .forward });
            while (pixel_iterator.next()) |pixel_index| {
                @memcpy(&file.editor.transform_layer.pixels()[pixel_index], &selected_layer.pixels()[pixel_index]);
                file.editor.transform_layer.mask.set(pixel_index);
            }
        },
        else => {
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
                        }
                    }
                } else if (file.selected_animation_index) |animation_index| {
                    const animation = file.animations.get(animation_index);
                    if (file.selected_animation_frame_index < animation.frames.len) {
                        const rect = file.spriteRect(animation.frames[file.selected_animation_frame_index].sprite_index);
                        if (selected_layer.pixelsFromRect(
                            dvui.currentWindow().arena(),
                            rect,
                        )) |source_pixels| {
                            file.editor.transform_layer.blit(
                                source_pixels,
                                rect,
                                .{ .transparent = true, .mask = true },
                            );
                        }
                    }
                }
            }
        },
    }

    const source_rect = dvui.Rect.fromSize(file.editor.transform_layer.size());
    if (file.editor.transform_layer.reduce(source_rect)) |reduced_data_rect| {
        const sprite_tl = file.spritePoint(reduced_data_rect.topLeft());
        const gpa = runtime.allocator();

        st.sprite_clipboard = .{
            .source = pixi_mod.image.fromPixelsPMA(
                @ptrCast(file.editor.transform_layer.pixelsFromRect(gpa, reduced_data_rect)),
                @intFromFloat(reduced_data_rect.w),
                @intFromFloat(reduced_data_rect.h),
                .ptr,
            ) catch return error.MemoryAllocationFailed,
            .offset = reduced_data_rect.topLeft().diff(sprite_tl),
        };

        const id_mutex = dvui.toastAdd(dvui.currentWindow(), @src(), 0, file.editor.canvas.id, pixi_mod.core.dvui.toastDisplay, 2_000_000);
        const id = id_mutex.id;
        const message = std.fmt.allocPrint(dvui.currentWindow().arena(), "Copied selection", .{}) catch "Copied selection.";
        dvui.dataSetSlice(dvui.currentWindow(), id, "_message", message);
        id_mutex.mutex.unlock(dvui.io);
    }
}

pub fn paste(st: *State) !void {
    if (st.sprite_clipboard) |*clipboard| {
        const file = activeFile(st) orelse return;
    const active_layer = file.layers.get(file.selected_layer_index);

    var dst_rect: dvui.Rect = .fromSize(pixi_mod.image.size(clipboard.source));

    var sprite_iterator = file.editor.selected_sprites.iterator(.{ .kind = .set, .direction = .forward });
    while (sprite_iterator.next()) |sprite_index| {
        const sprite_rect = file.spriteRect(sprite_index);

        dst_rect.x = sprite_rect.x + clipboard.offset.x;
        dst_rect.y = sprite_rect.y + clipboard.offset.y;

        file.editor.transform = .{
            .target_texture = dvui.textureCreateTarget(.{ .width = file.width(), .height = file.height(), .format = pixi_mod.render.compositeTargetPixelFormat(), .interpolation = .nearest }) catch {
                dvui.log.err("Failed to create target texture", .{});
                return;
            },
            .file_id = file.id,
            .layer_id = active_layer.id,
            .data_points = .{
                dst_rect.topLeft(),
                dst_rect.topRight(),
                dst_rect.bottomRight(),
                dst_rect.bottomLeft(),
                dst_rect.center(),
                dst_rect.center(),
            },
            .source = clipboard.source,
        };

        for (file.editor.transform.?.data_points[0..4]) |*point| {
            const d = point.diff(file.editor.transform.?.point(.pivot).*);
            if (d.length() > file.editor.transform.?.radius) {
                file.editor.transform.?.radius = d.length() + 4;
            }
        }

        return;
    }

    dst_rect.x = clipboard.offset.x;
    dst_rect.y = clipboard.offset.y;

    if (file.spriteIndex(file.editor.canvas.dataFromScreenPoint(dvui.currentWindow().mouse_pt))) |sprite_index| {
        const rect = file.spriteRect(sprite_index);
        dst_rect.x = rect.x + clipboard.offset.x;
        dst_rect.y = rect.y + clipboard.offset.y;
    } else if (file.selected_animation_index) |animation_index| {
        const animation = file.animations.get(animation_index);

        if (file.selected_animation_frame_index < animation.frames.len) {
            const rect = file.spriteRect(animation.frames[file.selected_animation_frame_index].sprite_index);
            dst_rect.x = rect.x + clipboard.offset.x;
            dst_rect.y = rect.y + clipboard.offset.y;

            file.editor.transform = .{
                .target_texture = dvui.textureCreateTarget(.{ .width = file.width(), .height = file.height(), .format = pixi_mod.render.compositeTargetPixelFormat(), .interpolation = .nearest }) catch {
                    dvui.log.err("Failed to create target texture", .{});
                    return;
                },
                .file_id = file.id,
                .layer_id = active_layer.id,
                .data_points = .{
                    dst_rect.topLeft(),
                    dst_rect.topRight(),
                    dst_rect.bottomRight(),
                    dst_rect.bottomLeft(),
                    dst_rect.center(),
                    dst_rect.center(),
                },
                .source = clipboard.source,
            };

            for (file.editor.transform.?.data_points[0..4]) |*point| {
                const d = point.diff(file.editor.transform.?.point(.pivot).*);
                if (d.length() > file.editor.transform.?.radius) {
                    file.editor.transform.?.radius = d.length() + 4;
                }
            }

            return;
        }
    }

    file.editor.transform = .{
        .target_texture = dvui.textureCreateTarget(.{ .width = file.width(), .height = file.height(), .format = pixi_mod.render.compositeTargetPixelFormat(), .interpolation = .nearest }) catch {
            dvui.log.err("Failed to create target texture", .{});
            return;
        },
        .file_id = file.id,
        .layer_id = active_layer.id,
        .data_points = .{
            dst_rect.topLeft(),
            dst_rect.topRight(),
            dst_rect.bottomRight(),
            dst_rect.bottomLeft(),
            dst_rect.center(),
            dst_rect.center(),
        },
        .source = clipboard.source,
    };

        for (file.editor.transform.?.data_points[0..4]) |*point| {
            const d = point.diff(file.editor.transform.?.point(.pivot).*);
            if (d.length() > file.editor.transform.?.radius) {
                file.editor.transform.?.radius = d.length() + 4;
            }
        }
    }
}
