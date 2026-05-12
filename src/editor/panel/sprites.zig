const std = @import("std");
const icons = @import("icons");
const dvui = @import("dvui");
const fizzy = @import("../../fizzy.zig");
const Editor = fizzy.Editor;

const Sprites = @This();

var prev_scale: f32 = 1.0;
var current_scale: f32 = 1.0;

pub fn draw(self: *Sprites) !void {
    if (fizzy.editor.activeFile()) |file| {
        const prev_clip = dvui.clip(dvui.parentGet().data().rectScale().r);
        defer dvui.clipSet(prev_clip);

        if (dvui.parentGet().data().rect.h < 32.0) {
            return;
        }

        self.drawAnimationControlsDialog();

        // Since not all panel screens will likely want shadows, which should be reserved for canvases?
        // Text editors, consoles, etc would likely want flat panels or to handle shadows themselves.
        defer {
            fizzy.dvui.drawEdgeShadow(dvui.parentGet().data().rectScale(), .top, .{ .opacity = 0.15 });
            fizzy.dvui.drawEdgeShadow(dvui.parentGet().data().rectScale(), .bottom, .{ .opacity = 0.15 });
            fizzy.dvui.drawEdgeShadow(dvui.parentGet().data().rectScale(), .left, .{ .opacity = 0.15 });
            fizzy.dvui.drawEdgeShadow(dvui.parentGet().data().rectScale(), .right, .{ .opacity = 0.15 });
        }

        const parent = dvui.parentGet().data().rect;
        const parent_height = parent.h;

        var index: usize = 0;
        var src_rect = file.spriteRect(index); // Default to the first sprite

        if (file.editor.playing) {
            if (file.selected_animation_index) |i| {
                index = i;
                const animation = file.animations.get(index);
                const frame_index = file.selected_animation_frame_index;

                if (frame_index < animation.frames.len) {
                    src_rect = file.spriteRect(animation.frames[frame_index].sprite_index);
                }
            }
        } else {
            if (file.editor.canvas.hovered) {
                if (file.spriteIndex(file.editor.canvas.dataFromScreenPoint(dvui.currentWindow().mouse_pt_prev))) |sprite_index| {
                    src_rect = file.spriteRect(sprite_index);
                    index = sprite_index;
                }
            } else if (file.editor.selected_sprites.count() > 0) {
                if (file.editor.selected_sprites.findLastSet()) |last| {
                    src_rect = file.spriteRect(last);
                    index = last;
                }
            } else {
                if (file.selected_animation_index) |animation_index| {
                    const animation = file.animations.get(animation_index);
                    if (animation.frames.len > 0 and file.selected_animation_frame_index < animation.frames.len) {
                        src_rect = file.spriteRect(animation.frames[file.selected_animation_frame_index].sprite_index);
                    }
                }
            }
        }

        const scale = blk: {
            const steps = fizzy.editor.settings.zoom_steps;
            const sprite_width = src_rect.w * 1.2;
            const sprite_height = src_rect.h * 1.2;
            const target_width = if (sprite_width < parent.w) parent.w else sprite_width;
            const target_height = if (sprite_height < parent.h) parent.h else sprite_height;
            var target_scale: f32 = 1.0;

            for (steps, 0..) |zoom, i| {
                if ((sprite_width * zoom) >= target_width or (sprite_height * zoom) >= target_height) {
                    if (i > 0) {
                        target_scale = steps[i - 1];
                        break;
                    }
                    target_scale = steps[i];
                    break;
                }
            }

            if (target_scale != current_scale) {
                if (dvui.animationGet(dvui.parentGet().data().id, "scale")) |a| {
                    if (a.done()) {
                        current_scale = target_scale;
                        prev_scale = current_scale;
                    } else {
                        if (a.end_val != target_scale) {
                            _ = dvui.currentWindow().animations.remove(dvui.parentGet().data().id.update("scale"));
                            dvui.animation(dvui.parentGet().data().id, "scale", .{
                                .end_time = 600_000,
                                .easing = dvui.easing.outBack,
                                .start_val = a.value(),
                                .end_val = target_scale,
                            });
                        } else {
                            current_scale = a.value();
                        }
                    }
                } else {
                    prev_scale = current_scale;
                    dvui.animation(dvui.parentGet().data().id, "scale", .{
                        .end_time = 600_000,
                        .easing = dvui.easing.outBack,
                        .start_val = prev_scale,
                        .end_val = target_scale,
                    });
                }
            }

            break :blk current_scale;
        };

        var rect = dvui.Rect{
            .x = parent.center().x,
            .y = parent.center().y,
            .w = @as(f32, @floatFromInt(file.column_width)) * scale,
            .h = @as(f32, @floatFromInt(file.row_height)) * scale,
        };

        rect.x -= rect.w / 2.0;
        rect.y -= rect.h / 2.0;

        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .none,
            .rect = rect,
            .border = .all(0),
            .color_border = dvui.themeGet().color(.control, .text),
            .box_shadow = .{
                .color = .black,
                .offset = .{ .x = 0.0, .y = 8.0 },
                .fade = 12.0,
                .alpha = 0.25,
                .corner_radius = dvui.Rect.all(parent_height / 32.0),
            },
            .min_size_content = .{ .w = 32.0, .h = 32.0 },
        });
        defer hbox.deinit();

        if (parent.h < 32.0) {
            return;
        }

        const perf_sp = fizzy.perf.spritePreviewBegin();
        defer fizzy.perf.spritePreviewEnd(perf_sp);

        _ = fizzy.dvui.sprite(@src(), .{
            .source = file.layers.items(.source)[file.selected_layer_index],
            .file = file,
            .alpha_source = file.editor.checkerboard_tile,
            .sprite = .{
                .source = .{
                    @intFromFloat(src_rect.x),
                    @intFromFloat(src_rect.y),
                    @intFromFloat(src_rect.w),
                    @intFromFloat(src_rect.h),
                },
                .origin = .{
                    0,
                    0,
                },
            },
            .scale = scale,
            // Compute a normalized depth in [-1.0, 1.0] where 0.0 is the center of the viewport
            // .depth = blk: {
            //     const viewport = fizzy.editor.panel.scroll_info.viewport;
            //     const cx = viewport.x + viewport.w / 2.0;
            //     const px = hbox.data().rectScale().r.center().x;
            //     break :blk (px - cx) / (viewport.w / 2.0);
            // },
            //.overlap = 0.8,
            .reflection = true,
        }, .{
            .id_extra = index,
            .margin = .all(0),
            .padding = .all(0),
            //.border = .all(1),
            //.color_border = dvui.themeGet().color(.control, .text),
        });
    }
}

pub fn drawAnimationControlsDialog(_: *Sprites) void {
    if (fizzy.editor.activeFile()) |file| {
        if (file.selected_animation_index) |_| {
            var rect = dvui.parentGet().data().rectScale().r;

            if (dvui.parentGet().data().rect.h < 48.0) {
                return;
            }

            var fw: dvui.FloatingWidget = undefined;
            fw.init(@src(), .{}, .{
                .rect = .{ .x = rect.toNatural().x + 10, .y = rect.toNatural().y + 10, .w = 0, .h = 0 },
                .expand = .none,
                .background = true,
                .color_fill = dvui.themeGet().color(.control, .fill),
                .corner_radius = dvui.Rect.all(8),
                .box_shadow = .{
                    .color = .black,
                    .alpha = 0.2,
                    .fade = 8,
                    .corner_radius = dvui.Rect.all(8),
                },
            });
            defer fw.deinit();

            var anim = dvui.animate(@src(), .{ .kind = .alpha, .duration = 450_000, .easing = dvui.easing.outBack }, .{});
            defer anim.deinit();

            var anim_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .both,
                .background = false,
            });
            defer anim_box.deinit();

            {
                if (dvui.buttonIcon(@src(), "Play", if (file.editor.playing) icons.tvg.entypo.pause else icons.tvg.entypo.play, .{}, .{}, .{
                    .expand = .ratio,
                    .corner_radius = dvui.Rect.all(1000),
                    .box_shadow = .{
                        .color = .black,
                        .offset = .{ .x = -2.0, .y = 2.0 },
                        .fade = 6.0,
                        .alpha = 0.15,
                        .corner_radius = dvui.Rect.all(1000),
                    },
                    .color_fill = dvui.themeGet().color(.control, .fill),
                    .min_size_content = .{ .w = 1.0, .h = 12.0 },
                })) {
                    file.editor.playing = !file.editor.playing;
                }
            }
        }
    }
}
