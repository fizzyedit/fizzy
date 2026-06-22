const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const pixi_mod = @import("../../pixi.zig");
const runtime = @import("../runtime.zig");

const Sprites = @This();

/// Edge shadows on animation/frame lists only when scroll range exceeds this (avoids subpixel overflow).
const scroll_list_shadow_deadzone_ns: f32 = 4.0;

fn pointerReleaseInRectWithoutSelectionModifier(r: dvui.Rect.Physical) bool {
    for (dvui.events()) |*e| {
        switch (e.evt) {
            .mouse => |me| {
                if (me.action == .release and me.button.pointer() and r.contains(me.p)) {
                    return !me.mod.shift() and !me.mod.control() and !me.mod.command();
                }
            },
            else => {},
        }
    }
    return false;
}

/// In-flight primary-button gesture for the animation list (reorder / click / rename).
const AnimationRowGesture = struct {
    file_id: u64,
    press_idx: usize,
    press_p: dvui.Point.Physical,
    drag_branch: ?usize,
    moved: bool,
    reorder_drag: bool,
    /// Finder-style: plain click on an already-multi-selected row preserves the set while the
    /// user might start a drag; if they release without dragging, narrow to just this row.
    narrow_on_release: bool,
};
var animation_row_gesture: ?AnimationRowGesture = null;
var anim_rename_hit_te_id: ?dvui.Id = null;
var anim_rename_hit_rect: ?dvui.Rect.Physical = null;

/// In-flight primary-button gesture for the frame list (reorder / click).
const FrameRowGesture = struct {
    file_id: u64,
    anim_id: u64,
    press_idx: usize,
    press_p: dvui.Point.Physical,
    drag_branch: ?usize,
    moved: bool,
    reorder_drag: bool,
    narrow_on_release: bool,
};
var frame_row_gesture: ?FrameRowGesture = null;

/// Sorted (ascending) indices whose animation-tree branch reported `removed()` last frame. Used
/// by the drop handler to move multiple selected animations as a group.
var removed_animation_indices_buf: [64]usize = undefined;
var removed_animation_indices_len: usize = 0;

/// Sorted (ascending) frame indices whose frame-tree branch reported `removed()` last frame.
var removed_frame_indices_buf: [256]usize = undefined;
var removed_frame_indices_len: usize = 0;

animation_insert_before_index: ?usize = null,
sprite_insert_before_index: ?usize = null,
edit_anim_id: ?u64 = null,
prev_anim_count: usize = 0,
prev_anim_id: u64 = 0,
prev_sprite_count: usize = 0,

/// Origin axis values for sprites tab (slider + text); resync when `origin_fields_sync_key` changes.
origin_edit_x: f32 = 0,
origin_edit_y: f32 = 0,
origin_fields_sync_key: u64 = 0,

/// Mouse-drag batching for origin sliders: snapshot until drag ends, then one history step if origins changed.
origin_x_drag_indices: ?[]usize = null,
origin_x_drag_old_vals: ?[][2]f32 = null,
origin_x_slider_drag_prev: bool = false,
origin_y_drag_indices: ?[]usize = null,
origin_y_drag_old_vals: ?[][2]f32 = null,
origin_y_slider_drag_prev: bool = false,

/// Visible clip of the animation list scroll area (for pointer gating, same idea as layers).
animations_scroll_viewport_rect: ?dvui.Rect.Physical = null,
/// Visible clip of the frames list scroll area.
frames_scroll_viewport_rect: ?dvui.Rect.Physical = null,

pub fn init() Sprites {
    return .{};
}

fn selectionUiKey(file: *pixi_mod.internal.File) u64 {
    const c = file.editor.selected_sprites.count();
    if (c == 0) return 0;
    const first = file.editor.selected_sprites.findFirstSet() orelse return 0;
    const last = file.editor.selected_sprites.findLastSet() orelse return 0;
    // Widen to u64 before shifting: `usize` is `u32` on wasm32, so `c << 48`
    // would overflow without the cast.
    return (@as(u64, c) << 48) ^ (@as(u64, first) << 24) ^ @as(u64, last);
}

fn selectionOriginsDifferFrom(file: *pixi_mod.internal.File, indices: []const usize, old_vals: []const [2]f32) bool {
    for (indices, old_vals) |si, ov| {
        const cur = file.sprites.get(si).origin;
        if (cur[0] != ov[0] or cur[1] != ov[1]) return true;
    }
    return false;
}

fn freeOriginAxisDragSnapshot(self: *Sprites, axis: enum { x, y }) void {
    switch (axis) {
        .x => {
            if (self.origin_x_drag_indices) |s| {
                runtime.allocator().free(s);
                self.origin_x_drag_indices = null;
            }
            if (self.origin_x_drag_old_vals) |v| {
                runtime.allocator().free(v);
                self.origin_x_drag_old_vals = null;
            }
        },
        .y => {
            if (self.origin_y_drag_indices) |s| {
                runtime.allocator().free(s);
                self.origin_y_drag_indices = null;
            }
            if (self.origin_y_drag_old_vals) |v| {
                runtime.allocator().free(v);
                self.origin_y_drag_old_vals = null;
            }
        },
    }
}

fn beginOriginAxisDragSnapshot(self: *Sprites, file: *pixi_mod.internal.File, axis: enum { x, y }) !void {
    switch (axis) {
        .x => if (self.origin_x_drag_indices != null) return,
        .y => if (self.origin_y_drag_indices != null) return,
    }
    const count = file.editor.selected_sprites.count();
    const indices = try runtime.allocator().alloc(usize, count);
    errdefer runtime.allocator().free(indices);
    const old_vals = try runtime.allocator().alloc([2]f32, count);
    var iter = file.editor.selected_sprites.iterator(.{ .kind = .set, .direction = .forward });
    var i: usize = 0;
    while (iter.next()) |si| : (i += 1) {
        indices[i] = si;
        old_vals[i] = file.sprites.items(.origin)[si];
    }
    switch (axis) {
        .x => {
            self.origin_x_drag_indices = indices;
            self.origin_x_drag_old_vals = old_vals;
        },
        .y => {
            self.origin_y_drag_indices = indices;
            self.origin_y_drag_old_vals = old_vals;
        },
    }
}

fn appendOriginsHistory(file: *pixi_mod.internal.File, indices: []usize, old_vals: [][2]f32) !void {
    file.history.append(.{ .origins = .{ .indices = indices, .values = old_vals } }) catch |err| {
        runtime.allocator().free(indices);
        runtime.allocator().free(old_vals);
        return err;
    };
}

fn applySpriteOriginAxisNoHistory(file: *pixi_mod.internal.File, axis: enum { x, y }, new_val: f32) void {
    const cw = @as(f32, @floatFromInt(file.column_width));
    const rh = @as(f32, @floatFromInt(file.row_height));
    const max_v: f32 = switch (axis) {
        .x => cw,
        .y => rh,
    };
    const clamped = std.math.clamp(new_val, 0, max_v);
    var iter = file.editor.selected_sprites.iterator(.{ .kind = .set, .direction = .forward });
    while (iter.next()) |si| {
        switch (axis) {
            .x => file.sprites.items(.origin)[si][0] = clamped,
            .y => file.sprites.items(.origin)[si][1] = clamped,
        }
    }
}

fn commitSpriteOriginAxis(file: *pixi_mod.internal.File, axis: enum { x, y }, new_val: f32) !void {
    const cw = @as(f32, @floatFromInt(file.column_width));
    const rh = @as(f32, @floatFromInt(file.row_height));
    const max_v: f32 = switch (axis) {
        .x => cw,
        .y => rh,
    };
    const clamped = std.math.clamp(new_val, 0, max_v);

    const count = file.editor.selected_sprites.count();
    if (count == 0) return;

    const indices = try runtime.allocator().alloc(usize, count);
    errdefer runtime.allocator().free(indices);
    const old_vals = try runtime.allocator().alloc([2]f32, count);
    errdefer runtime.allocator().free(old_vals);

    var iter = file.editor.selected_sprites.iterator(.{ .kind = .set, .direction = .forward });
    var i: usize = 0;
    while (iter.next()) |si| : (i += 1) {
        indices[i] = si;
        old_vals[i] = file.sprites.items(.origin)[si];
    }

    for (indices) |si| {
        switch (axis) {
            .x => file.sprites.items(.origin)[si][0] = clamped,
            .y => file.sprites.items(.origin)[si][1] = clamped,
        }
    }

    file.history.append(.{ .origins = .{ .indices = indices, .values = old_vals } }) catch |err| {
        for (indices, 0..) |si, j| {
            file.sprites.items(.origin)[si] = old_vals[j];
        }
        runtime.allocator().free(indices);
        runtime.allocator().free(old_vals);
        return err;
    };
}

pub fn draw(self: *Sprites) !void {
    if (runtime.state().docs.activeFile(runtime.state().host)) |file| {
        const parent_height = dvui.parentGet().data().rect.h - 2.0 * dvui.currentWindow().natural_scale;
        const parent_data = dvui.parentGet().data();

        const vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
            .max_size_content = .{ .w = std.math.floatMax(f32), .h = parent_height },
        });
        defer vbox.deinit();

        const hbox = dvui.box(@src(), .{
            .dir = .vertical,
            .equal_space = false,
        }, .{
            .expand = .horizontal,
            .background = false,
        });
        defer hbox.deinit();

        self.drawOriginControls() catch {
            dvui.log.err("Failed to draw origin controls", .{});
        };

        {
            var animations_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
            });
            defer animations_box.deinit();

            self.drawAnimations() catch {
                dvui.log.err("Failed to draw layers", .{});
            };

            if (file.selected_animation_index != null) {
                self.drawFrames() catch {
                    dvui.log.err("Failed to draw sprites", .{});
                };
            }
        }

        for (dvui.events()) |*e| {
            if (e.evt == .mouse and e.evt.mouse.action == .press) {
                if (dvui.eventMatchSimple(e, parent_data)) {
                    const p = e.evt.mouse.p;
                    var in_sprite_list: bool = false;
                    if (self.animations_scroll_viewport_rect) |r| {
                        if (r.contains(p)) in_sprite_list = true;
                    }
                    if (self.frames_scroll_viewport_rect) |r| {
                        if (r.contains(p)) in_sprite_list = true;
                    }
                    if (!in_sprite_list) {
                        file.clearSelectedSprites();
                    }
                }
            }
        }
    }
}

pub fn drawOriginControls(self: *Sprites) !void {
    if (runtime.state().docs.activeFile(runtime.state().host)) |file| {
        if (file.editor.selected_sprites.count() == 0) return;

        const key = selectionUiKey(file);
        if (key != self.origin_fields_sync_key) {
            self.origin_fields_sync_key = key;
            freeOriginAxisDragSnapshot(self, .x);
            freeOriginAxisDragSnapshot(self, .y);
            self.origin_x_slider_drag_prev = false;
            self.origin_y_slider_drag_prev = false;

            var ox_unified: ?f32 = null;
            var oy_unified: ?f32 = null;
            if (file.editor.selected_sprites.findFirstSet()) |first_si| {
                const first_sp = file.sprites.get(first_si);
                ox_unified = first_sp.origin[0];
                oy_unified = first_sp.origin[1];

                var iter = file.editor.selected_sprites.iterator(.{ .direction = .forward, .kind = .set });
                while (iter.next()) |si| {
                    const sp = file.sprites.get(si);
                    if (ox_unified) |u| {
                        if (sp.origin[0] != u) ox_unified = null;
                    }
                    if (oy_unified) |u| {
                        if (sp.origin[1] != u) oy_unified = null;
                    }
                    if (ox_unified == null and oy_unified == null) break;
                }
            }

            self.origin_edit_x = ox_unified orelse if (file.editor.selected_sprites.findFirstSet()) |first_si| file.sprites.get(first_si).origin[0] else 0;
            self.origin_edit_y = oy_unified orelse if (file.editor.selected_sprites.findFirstSet()) |first_si| file.sprites.get(first_si).origin[1] else 0;
        }

        const cw = @as(f32, @floatFromInt(file.column_width));
        const rh = @as(f32, @floatFromInt(file.row_height));

        var mixed_x = false;
        var mixed_y = false;
        if (file.editor.selected_sprites.findFirstSet()) |first_si| {
            const o0 = file.sprites.get(first_si).origin;
            var iter = file.editor.selected_sprites.iterator(.{ .direction = .forward, .kind = .set });
            while (iter.next()) |si| {
                const o = file.sprites.get(si).origin;
                if (o[0] != o0[0]) mixed_x = true;
                if (o[1] != o0[1]) mixed_y = true;
            }
        }

        var origin_group = dvui.groupBox(@src(), "Origin", .{
            .expand = .horizontal,
        });
        defer origin_group.deinit();

        var animation = dvui.animate(@src(), .{ .duration = 400_000, .easing = dvui.easing.outBack, .kind = .vertical }, .{
            .expand = .horizontal,
        });
        defer animation.deinit();

        var fields = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
        });
        defer fields.deinit();

        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
            });
            defer row.deinit();

            dvui.labelNoFmt(@src(), "X", .{}, .{ .font = dvui.Font.theme(.body) });
            if (mixed_x) {
                dvui.icon(@src(), "OriginXIcon", icons.tvg.lucide.@"link-2-off", .{
                    .stroke_color = dvui.themeGet().color(.control, .text),
                }, .{
                    .gravity_y = 0.5,
                    .expand = .none,
                    .margin = dvui.Rect.all(0),
                    .padding = dvui.Rect.all(0),
                });
            } else {
                dvui.icon(@src(), "OriginXIcon", icons.tvg.lucide.@"link-2", .{
                    .stroke_color = dvui.themeGet().color(.control, .text),
                }, .{
                    .gravity_y = 0.5,
                    .expand = .none,
                    .margin = dvui.Rect.all(0),
                    .padding = dvui.Rect.all(0),
                });
            }
            var x_slider_wd: dvui.WidgetData = undefined;
            const x_changed = dvui.sliderEntry(@src(), "{d:0.0}", .{
                .value = &self.origin_edit_x,
                .min = 0,
                .max = cw,
                .interval = 1,
            }, .{
                .id_extra = 0xb00001,
                .expand = .horizontal,
                .data_out = &x_slider_wd,
            });
            const x_slider_dragging = dvui.dataGet(null, x_slider_wd.id, "_start_v", f32) != null;

            if (x_slider_dragging and self.origin_x_drag_indices == null) {
                try beginOriginAxisDragSnapshot(self, file, .x);
            }

            if (x_changed) {
                const cl = std.math.clamp(self.origin_edit_x, 0, cw);
                if (x_slider_dragging) {
                    applySpriteOriginAxisNoHistory(file, .x, cl);
                } else {
                    freeOriginAxisDragSnapshot(self, .x);
                    try commitSpriteOriginAxis(file, .x, cl);
                }
                self.origin_edit_x = cl;
            }

            if (self.origin_x_slider_drag_prev and !x_slider_dragging) {
                if (self.origin_x_drag_indices) |indices| {
                    const old_vals = self.origin_x_drag_old_vals.?;
                    defer {
                        self.origin_x_drag_indices = null;
                        self.origin_x_drag_old_vals = null;
                    }
                    if (selectionOriginsDifferFrom(file, indices, old_vals)) {
                        try appendOriginsHistory(file, indices, old_vals);
                    } else {
                        runtime.allocator().free(indices);
                        runtime.allocator().free(old_vals);
                    }
                }
            }
            self.origin_x_slider_drag_prev = x_slider_dragging;
        }
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
            });
            defer row.deinit();

            dvui.labelNoFmt(@src(), "Y", .{}, .{ .font = dvui.Font.theme(.body) });
            if (mixed_y) {
                dvui.icon(@src(), "OriginYIcon", icons.tvg.lucide.@"link-2-off", .{
                    .stroke_color = dvui.themeGet().color(.control, .text),
                }, .{
                    .gravity_y = 0.5,
                    .expand = .none,
                    .margin = dvui.Rect.all(0),
                    .padding = dvui.Rect.all(0),
                });
            } else {
                dvui.icon(@src(), "OriginYIcon", icons.tvg.lucide.@"link-2", .{
                    .stroke_color = dvui.themeGet().color(.control, .text),
                }, .{
                    .gravity_y = 0.5,
                    .expand = .none,
                    .margin = dvui.Rect.all(0),
                    .padding = dvui.Rect.all(0),
                });
            }
            var y_slider_wd: dvui.WidgetData = undefined;
            const y_changed = dvui.sliderEntry(@src(), "{d:0.0}", .{
                .value = &self.origin_edit_y,
                .min = 0,
                .max = rh,
                .interval = 1,
            }, .{
                .id_extra = 0xb00002,
                .expand = .horizontal,
                .data_out = &y_slider_wd,
            });
            const y_slider_dragging = dvui.dataGet(null, y_slider_wd.id, "_start_v", f32) != null;

            if (y_slider_dragging and self.origin_y_drag_indices == null) {
                try beginOriginAxisDragSnapshot(self, file, .y);
            }

            if (y_changed) {
                const cl = std.math.clamp(self.origin_edit_y, 0, rh);
                if (y_slider_dragging) {
                    applySpriteOriginAxisNoHistory(file, .y, cl);
                } else {
                    freeOriginAxisDragSnapshot(self, .y);
                    try commitSpriteOriginAxis(file, .y, cl);
                }
                self.origin_edit_y = cl;
            }

            if (self.origin_y_slider_drag_prev and !y_slider_dragging) {
                if (self.origin_y_drag_indices) |indices| {
                    const old_vals = self.origin_y_drag_old_vals.?;
                    defer {
                        self.origin_y_drag_indices = null;
                        self.origin_y_drag_old_vals = null;
                    }
                    if (selectionOriginsDifferFrom(file, indices, old_vals)) {
                        try appendOriginsHistory(file, indices, old_vals);
                    } else {
                        runtime.allocator().free(indices);
                        runtime.allocator().free(old_vals);
                    }
                }
            }
            self.origin_y_slider_drag_prev = y_slider_dragging;
        }
    }
}

pub fn drawAnimationControls(self: *Sprites) !void {
    var box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .none,
    });
    defer box.deinit();

    const icon_color = dvui.themeGet().color(.control, .text);

    if (runtime.state().docs.activeFile(runtime.state().host)) |file| {
        {
            var add_animation_button: dvui.ButtonWidget = undefined;
            add_animation_button.init(@src(), .{}, .{
                .expand = .none,
                .gravity_y = 0.5,
                .padding = dvui.Rect.all(4),
                .corner_radius = dvui.Rect.all(1000),
                .box_shadow = .{
                    .color = .black,
                    .offset = .{ .x = -2.0, .y = 2.0 },
                    .fade = 6.0,
                    .alpha = 0.15,
                    .corner_radius = dvui.Rect.all(1000),
                },
                .color_fill = dvui.themeGet().color(.control, .fill),
            });
            defer add_animation_button.deinit();

            add_animation_button.processEvents();
            add_animation_button.drawBackground();

            dvui.icon(
                @src(),
                "AddAnimationIcon",
                icons.tvg.lucide.plus,
                .{
                    .fill_color = icon_color,
                    .stroke_color = icon_color,
                },
                .{
                    .gravity_x = 0.5,
                    .gravity_y = 0.5,
                    .expand = .ratio,
                    .color_text = add_animation_button.data().options.color_text,
                    .margin = dvui.Rect.all(0),
                    .padding = dvui.Rect.all(0),
                },
            );

            if (add_animation_button.clicked()) {
                const anim_index = try file.createAnimation();
                file.selected_animation_index = anim_index;
                file.editor.animations_scroll_to_index = anim_index;
                self.edit_anim_id = file.animations.items(.id)[anim_index];

                file.history.append(.{
                    .animation_restore_delete = .{
                        .action = .delete,
                        .index = anim_index,
                    },
                }) catch {
                    dvui.log.err("Failed to append history", .{});
                };
            }
        }

        {
            var duplicate_animation_button: dvui.ButtonWidget = undefined;
            duplicate_animation_button.init(@src(), .{}, .{
                .expand = .none,
                .gravity_y = 0.5,
                .padding = dvui.Rect.all(4),
                .corner_radius = dvui.Rect.all(1000),
                .box_shadow = .{
                    .color = .black,
                    .offset = .{ .x = -2.0, .y = 2.0 },
                    .fade = 6.0,
                    .alpha = 0.15,
                    .corner_radius = dvui.Rect.all(1000),
                },
                .color_fill = dvui.themeGet().color(.control, .fill),
            });

            defer duplicate_animation_button.deinit();
            duplicate_animation_button.processEvents();
            const alpha = dvui.alpha(if (file.selected_animation_index != null and file.animations.len > 0) 1.0 else 0.5);
            duplicate_animation_button.drawBackground();

            dvui.icon(
                @src(),
                "DuplicateAnimationIcon",
                icons.tvg.lucide.@"copy-plus",
                .{ .fill_color = icon_color, .stroke_color = icon_color },
                .{
                    .gravity_x = 0.5,
                    .gravity_y = 0.5,
                    .expand = .ratio,
                    .color_text = duplicate_animation_button.data().options.color_text,
                    .margin = dvui.Rect.all(0),
                    .padding = dvui.Rect.all(0),
                },
            );

            dvui.alphaSet(alpha);

            if (duplicate_animation_button.clicked()) {
                if (file.animations.len > 0) {
                    if (file.selected_animation_index) |index| {
                        const anim_index = try file.duplicateAnimation(index);
                        file.selected_animation_index = anim_index;
                        file.editor.animations_scroll_to_index = anim_index;
                        self.edit_anim_id = file.animations.items(.id)[anim_index];

                        file.history.append(.{
                            .animation_restore_delete = .{
                                .action = .delete,
                                .index = anim_index,
                            },
                        }) catch {
                            dvui.log.err("Failed to append history", .{});
                        };
                    }
                }
            }
        }

        {
            var delete_animation_button: dvui.ButtonWidget = undefined;
            delete_animation_button.init(@src(), .{}, .{
                .expand = .none,
                .gravity_y = 0.5,
                .padding = dvui.Rect.all(4),
                .corner_radius = dvui.Rect.all(1000),
                .box_shadow = .{
                    .color = .black,
                    .offset = .{ .x = -2.0, .y = 2.0 },
                    .fade = 6.0,
                    .alpha = 0.15,
                    .corner_radius = dvui.Rect.all(1000),
                },
                .color_fill = dvui.themeGet().color(.err, .fill),
            });
            defer delete_animation_button.deinit();
            delete_animation_button.processEvents();

            const alpha = dvui.alpha(if (file.selected_animation_index != null and file.animations.len > 0) 1.0 else 0.5);
            delete_animation_button.drawBackground();

            dvui.icon(
                @src(),
                "DeleteAnimationIcon",
                icons.tvg.lucide.trash,
                .{ .fill_color = dvui.themeGet().color(.window, .fill), .stroke_color = dvui.themeGet().color(.window, .fill) },
                .{
                    .gravity_x = 0.5,
                    .gravity_y = 0.5,
                    .expand = .ratio,
                    .margin = dvui.Rect.all(0),
                    .padding = dvui.Rect.all(0),
                },
            );

            dvui.alphaSet(alpha);

            if (delete_animation_button.clicked()) {
                if (file.animations.len > 0) {
                    if (file.selected_animation_index) |index| {
                        file.deleteAnimation(index) catch {
                            dvui.log.err("Failed to delete animation", .{});
                        };
                        if (index > 0) {
                            file.selected_animation_index = index - 1;
                        } else {
                            file.selected_animation_index = null;
                        }
                    }
                }
            }
        }
    }
}

pub fn drawAnimations(self: *Sprites) !void {
    const outer_box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = false,
    });
    defer outer_box.deinit();

    const parent_width = dvui.parentGet().data().rect.w;
    const controls_box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = false,
    });
    dvui.labelNoFmt(@src(), "ANIMATIONS", .{}, .{ .font = dvui.Font.theme(.heading) });

    self.drawAnimationControls() catch {};

    controls_box.deinit();

    if (runtime.state().docs.activeFile(runtime.state().host)) |file| {
        // Make sure to update the prev anim count!
        defer self.prev_anim_count = file.animations.len;

        self.animations_scroll_viewport_rect = null;
        anim_rename_hit_te_id = null;
        anim_rename_hit_rect = null;

        var scroll_area = dvui.scrollArea(@src(), .{
            .scroll_info = &file.editor.animations_scroll_info,
            .horizontal_bar = .auto_overlay,
            .vertical_bar = .auto_overlay,
        }, .{
            .expand = .horizontal,
            .background = false,

            .max_size_content = .{ .h = std.math.floatMax(f32), .w = parent_width / 2.0 },
        });
        defer scroll_area.deinit();

        if (dvui.ScrollContainerWidget.current()) |sc| {
            self.animations_scroll_viewport_rect = sc.data().contentRectScale().r;
        }

        var inner_box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
            .background = false,
            .margin = .{ .h = 6, .w = 6 },
        });
        defer inner_box.deinit();

        defer {
            if (file.editor.animations_scroll_info.viewport.w < file.editor.animations_scroll_info.virtual_size.w) {
                if (file.editor.animations_scroll_info.offset(.horizontal) < file.editor.animations_scroll_info.scrollMax(.horizontal)) {
                    pixi_mod.core.dvui.drawEdgeShadow(scroll_area.data().contentRectScale(), .right, .{});
                }
                if (file.editor.animations_scroll_info.offset(.horizontal) > 0.0) {
                    pixi_mod.core.dvui.drawEdgeShadow(scroll_area.data().contentRectScale(), .left, .{});
                }
            }
        }

        const vertical_scroll = file.editor.animations_scroll_info.offset(.vertical);

        var tree = pixi_mod.core.dvui.TreeWidget.tree(@src(), .{ .enable_reordering = true }, .{
            .expand = .horizontal,
            .background = false,
        });
        defer tree.deinit();

        var anim_hits_buf: [256]AnimationRowHit = undefined;
        var anim_hits_len: usize = 0;

        // Drag and drop is completing — supports single- and multi-row drags.
        if (self.animation_insert_before_index) |insert_before_raw| {
            if (removed_animation_indices_len > 0) {
                const sources = removed_animation_indices_buf[0..removed_animation_indices_len];

                const primary_before_opt = file.selected_animation_index;
                var primary_was_moved = false;
                var primary_pos_in_sources: usize = 0;
                if (primary_before_opt) |pb| {
                    for (sources, 0..) |s, pi| {
                        if (s == pb) {
                            primary_was_moved = true;
                            primary_pos_in_sources = pi;
                            break;
                        }
                    }
                }

                var moved = try runtime.allocator().alloc(pixi_mod.internal.Animation, sources.len);
                defer runtime.allocator().free(moved);
                for (sources, 0..) |s, i| {
                    moved[i] = file.animations.get(s);
                }

                var ri = sources.len;
                while (ri > 0) {
                    ri -= 1;
                    file.animations.orderedRemove(sources[ri]);
                }

                const target_raw = pixi_mod.core.dvui.TreeSelection.adjustInsertBeforeForRemovals(sources, insert_before_raw);
                const target = @min(target_raw, file.animations.len);

                for (moved, 0..) |anim, i| {
                    file.animations.insert(runtime.allocator(), target + i, anim) catch {
                        dvui.log.err("Failed to insert animation", .{});
                    };
                }

                if (primary_was_moved) {
                    file.selected_animation_index = target + primary_pos_in_sources;
                }

                file.editor.selected_animation_indices.clearRetainingCapacity();
                for (0..moved.len) |i| {
                    file.editor.selected_animation_indices.append(runtime.allocator(), target + i) catch {
                        dvui.log.err("Failed to update animation selection", .{});
                    };
                }
                file.editor.animation_selection_anchor = file.selected_animation_index;

                self.animation_insert_before_index = null;
                removed_animation_indices_len = 0;
            } else {
                self.animation_insert_before_index = null;
            }
        } else if (removed_animation_indices_len > 0) {
            removed_animation_indices_len = 0;
        }

        ensureAnimationSelection(file);

        const box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .background = false,
            .corner_radius = dvui.Rect.all(1000),
            .margin = dvui.Rect.rect(4, 0, 4, 4),
        });
        defer box.deinit();

        const no_buttons_r: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

        for (file.animations.items(.id), 0..) |anim_id, anim_index| {
            const in_multi = animationIndexInMulti(file, anim_index);
            const is_primary_row = if (file.selected_animation_index) |p| p == anim_index else false;
            const selected = if (self.edit_anim_id) |id| id == anim_id else (is_primary_row or in_multi);

            var color = dvui.themeGet().color(.control, .fill_hover);
            if (runtime.state().colors.file_tree_palette) |*palette| {
                color = palette.getDVUIColor(@intCast(anim_id));
            }

            var branch = tree.branch(@src(), .{
                .expanded = false,
                .process_events = false,
                .can_accept_children = false,
                .animation_duration = 250_000,
                .animation_easing = dvui.easing.outBack,
            }, .{
                .id_extra = @intCast(anim_id),
                .expand = .horizontal,
                .corner_radius = dvui.Rect.all(1000),
                .background = false,
                .margin = .all(0),
                .padding = dvui.Rect.all(1),
            });
            defer branch.deinit();

            if (branch.removed()) {
                if (removed_animation_indices_len < removed_animation_indices_buf.len) {
                    removed_animation_indices_buf[removed_animation_indices_len] = anim_index;
                    removed_animation_indices_len += 1;
                }
            } else if (branch.insertBefore()) {
                self.animation_insert_before_index = anim_index;
            }

            const row_r = branch.data().borderRectScale().r;
            const mp = dvui.currentWindow().mouse_pt;
            const row_hovered = row_r.contains(mp) and animationPointerInScrollViewport(mp, self.animations_scroll_viewport_rect);

            const ctrl_hover = dvui.themeGet().color(.control, .fill).opacity(0.5);
            const row_highlight = blk: {
                if (tree.reorderDragActive()) {
                    if (tree.id_branch) |idb| {
                        break :blk idb == branch.data().id.asUsize();
                    }
                    break :blk false;
                }
                break :blk row_hovered and tree.drag_point == null;
            };

            var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .both,
                .background = true,
                .color_fill = if (branch.floating())
                    .transparent
                else if (selected or row_highlight)
                    ctrl_hover
                else
                    .transparent,
                .color_fill_hover = .transparent,
                .margin = .all(0),
                .padding = dvui.Rect.all(5),
                .corner_radius = dvui.Rect.all(8),
            });
            defer hbox.deinit();

            var color_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .none,
                .background = true,
                .gravity_y = 0.5,
                .min_size_content = .{ .w = 8.0, .h = 8.0 },
                .color_fill = color,
                .corner_radius = dvui.Rect.all(1000),
                .margin = dvui.Rect.all(2),
                .padding = dvui.Rect.all(0),
            });
            color_box.deinit();

            const font = dvui.Font.theme(.body);
            const rename_padding = dvui.Rect.all(0);

            if (self.edit_anim_id != anim_id) {
                var name_label_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .none,
                    .background = false,
                    .gravity_y = 0.5,
                    .margin = dvui.Rect.rect(2, 0, 2, 0),
                    .padding = dvui.Rect.all(0),
                });
                defer name_label_box.deinit();

                const anim_name = file.animations.items(.name)[anim_index];
                const name_color: dvui.Color = if (!selected)
                    dvui.themeGet().color(.control, .text)
                else if (is_primary_row)
                    dvui.themeGet().color(.window, .text)
                else
                    dvui.themeGet().color(.control, .text);

                if (selected) {
                    if (dvui.labelClick(@src(), "{s}", .{anim_name}, .{ .label_opts = .{ .ellipsize = true } }, .{
                        .expand = .none,
                        .gravity_y = 0.5,
                        .margin = dvui.Rect{},
                        .font = font,
                        .padding = .{ .y = 1 },
                        .color_text = name_color,
                    })) {
                        const lr = name_label_box.data().borderRectScale().r;
                        if (pointerReleaseInRectWithoutSelectionModifier(lr)) {
                            self.edit_anim_id = anim_id;
                        }
                    }
                } else {
                    dvui.labelNoFmt(@src(), anim_name, .{ .ellipsize = true }, .{
                        .expand = .none,
                        .gravity_y = 0.5,
                        .margin = dvui.Rect{},
                        .font = font,
                        .padding = .{ .y = 1 },
                        .color_text = name_color,
                    });
                }

                var drag_sink = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .both,
                    .background = false,
                    .min_size_content = .{ .w = 0, .h = 0 },
                    .gravity_y = 0.5,
                });
                defer drag_sink.deinit();

                if (row_hovered and animationPointerInScrollViewport(mp, self.animations_scroll_viewport_rect)) {
                    dvui.cursorSet(.hand);
                }

                if (anim_hits_len < anim_hits_buf.len) {
                    anim_hits_buf[anim_hits_len] = .{
                        .row_r = branch.data().borderRectScale().r,
                        .buttons_r = no_buttons_r,
                        .branch_usize = branch.data().id.asUsize(),
                        .anim_index = anim_index,
                        .hbox_tl = hbox.data().rectScale().r.topLeft(),
                    };
                    anim_hits_len += 1;
                }
            } else {
                var te = dvui.textEntry(@src(), .{}, .{
                    .expand = .horizontal,
                    .background = false,
                    .padding = rename_padding,
                    .margin = dvui.Rect.all(0),
                    .font = font,
                    .gravity_y = 0.5,
                });
                defer te.deinit();

                if (dvui.firstFrame(te.data().id)) {
                    te.textSet(file.animations.items(.name)[anim_index], true);
                    dvui.focusWidget(te.data().id, null, null);
                }

                anim_rename_hit_te_id = te.data().id;
                anim_rename_hit_rect = te.data().borderRectScale().r;

                const should_commit_rename = te.enter_pressed or dvui.focusedWidgetId() != te.data().id;
                if (should_commit_rename) {
                    if (!std.mem.eql(u8, file.animations.items(.name)[anim_index], te.getText()) and te.getText().len > 0) {
                        file.history.append(.{
                            .animation_name = .{
                                .index = anim_index,
                                .name = try runtime.allocator().dupe(u8, file.animations.items(.name)[anim_index]),
                            },
                        }) catch {
                            dvui.log.err("Failed to append history", .{});
                        };
                        runtime.allocator().free(file.animations.items(.name)[anim_index]);
                        file.animations.items(.name)[anim_index] = try runtime.allocator().dupe(u8, te.getText());
                    }
                    if (te.enter_pressed) {
                        file.selected_animation_index = anim_index;
                    }
                    dvui.captureMouse(null, 0);
                    dvui.focusWidget(null, null, null);
                    self.edit_anim_id = null;
                    dvui.refresh(null, @src(), tree.data().id);
                }
            }

            if (file.editor.animations_scroll_to_index != null and dvui.timerGet(hbox.data().id) == null) {
                dvui.timer(hbox.data().id, 1);
            }

            if (dvui.timerDone(hbox.data().id)) {
                if (file.editor.animations_scroll_to_index) |index| {
                    if (index == anim_index) {
                        dvui.scrollTo(.{ .screen_rect = hbox.data().rectScale().r, .over_scroll = true });
                        file.editor.animations_scroll_to_index = null;
                    }
                }
            }
        }

        processAnimationTreePointerEvents(self, tree, file, anim_hits_buf[0..anim_hits_len], self.animations_scroll_viewport_rect);

        if (tree.drag_point != null) {
            var tail = tree.branch(@src(), .{
                .expanded = false,
                .process_events = false,
                .can_accept_children = false,
            }, .{
                .id_extra = 0x7fff_fffd,
                .expand = .horizontal,
                .min_size_content = .{ .w = 0, .h = 14 },
                .color_fill = .transparent,
                .color_fill_hover = .transparent,
                .color_fill_press = .transparent,
            });
            defer tail.deinit();
            if (tail.insertBefore()) {
                self.animation_insert_before_index = file.animations.len;
            }
        }

        const anim_si = file.editor.animations_scroll_info;
        const anim_v_max = anim_si.scrollMax(.vertical);
        if (vertical_scroll > scroll_list_shadow_deadzone_ns)
            pixi_mod.core.dvui.drawEdgeShadow(scroll_area.data().contentRectScale(), .top, .{});

        if (anim_v_max > scroll_list_shadow_deadzone_ns and vertical_scroll < anim_v_max - scroll_list_shadow_deadzone_ns)
            pixi_mod.core.dvui.drawEdgeShadow(scroll_area.data().contentRectScale(), .bottom, .{});
    }
}

pub fn drawFrameControls(_: *Sprites) !void {
    var box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .none,
    });
    defer box.deinit();

    if (runtime.state().docs.activeFile(runtime.state().host)) |file| {
        const index = if (file.selected_animation_index) |i| i else 0;
        var animation = file.animations.get(index);

        const icon_color = dvui.themeGet().color(.control, .text);

        {
            var sort_anim_asc_button: dvui.ButtonWidget = undefined;
            sort_anim_asc_button.init(@src(), .{}, .{
                .expand = .none,
                .gravity_y = 0.5,
                .padding = dvui.Rect.all(4),
                .corner_radius = dvui.Rect.all(1000),
                .box_shadow = .{
                    .color = .black,
                    .offset = .{ .x = -2.0, .y = 2.0 },
                    .fade = 6.0,
                    .alpha = 0.15,
                    .corner_radius = dvui.Rect.all(1000),
                },
                .color_fill = dvui.themeGet().color(.control, .fill),
            });

            defer sort_anim_asc_button.deinit();
            sort_anim_asc_button.processEvents();
            const alpha = dvui.alpha(if (file.selected_animation_index != null and file.animations.len > 0) 1.0 else 0.5);
            sort_anim_asc_button.drawBackground();

            dvui.icon(
                @src(),
                "SortAnimationAscIcon",
                icons.tvg.lucide.@"arrow-up-from-line",
                .{ .fill_color = icon_color, .stroke_color = icon_color },
                .{
                    .gravity_x = 0.5,
                    .gravity_y = 0.5,
                    .expand = .ratio,
                    .color_text = sort_anim_asc_button.data().options.color_text,
                    .margin = dvui.Rect.all(0),
                    .padding = dvui.Rect.all(0),
                },
            );

            dvui.alphaSet(alpha);

            if (sort_anim_asc_button.clicked()) {
                const prev_order = try runtime.allocator().dupe(pixi_mod.Animation.Frame, animation.frames);
                std.mem.sort(pixi_mod.Animation.Frame, animation.frames, {}, FrameSort.asc);

                if (!animation.eqlFrames(prev_order)) {
                    file.history.append(.{
                        .animation_frames = .{
                            .index = index,
                            .frames = prev_order,
                        },
                    }) catch {
                        dvui.log.err("Failed to append history", .{});
                    };

                    file.animations.set(index, animation);
                } else {
                    runtime.allocator().free(prev_order);
                }
            }
        }
        {
            {
                var sort_anim_desc_button: dvui.ButtonWidget = undefined;
                sort_anim_desc_button.init(@src(), .{}, .{
                    .expand = .none,
                    .gravity_y = 0.5,
                    .padding = dvui.Rect.all(4),
                    .corner_radius = dvui.Rect.all(1000),
                    .box_shadow = .{
                        .color = .black,
                        .offset = .{ .x = -2.0, .y = 2.0 },
                        .fade = 6.0,
                        .alpha = 0.15,
                        .corner_radius = dvui.Rect.all(1000),
                    },
                    .color_fill = dvui.themeGet().color(.control, .fill),
                });

                defer sort_anim_desc_button.deinit();
                sort_anim_desc_button.processEvents();
                const alpha = dvui.alpha(if (file.selected_animation_index != null and file.animations.len > 0) 1.0 else 0.5);
                sort_anim_desc_button.drawBackground();

                dvui.icon(
                    @src(),
                    "SortAnimationDescIcon",
                    icons.tvg.lucide.@"arrow-down-from-line",
                    .{ .fill_color = icon_color, .stroke_color = icon_color },
                    .{
                        .gravity_x = 0.5,
                        .gravity_y = 0.5,
                        .expand = .ratio,
                        .color_text = sort_anim_desc_button.data().options.color_text,
                        .margin = dvui.Rect.all(0),
                        .padding = dvui.Rect.all(0),
                    },
                );

                dvui.alphaSet(alpha);

                if (sort_anim_desc_button.clicked()) {
                    const prev_order = try runtime.allocator().dupe(pixi_mod.Animation.Frame, animation.frames);
                    std.mem.sort(pixi_mod.Animation.Frame, animation.frames, {}, FrameSort.desc);

                    if (!animation.eqlFrames(prev_order)) {
                        file.history.append(.{
                            .animation_frames = .{
                                .index = index,
                                .frames = prev_order,
                            },
                        }) catch {
                            dvui.log.err("Failed to append history", .{});
                        };

                        file.animations.set(index, animation);
                    } else {
                        runtime.allocator().free(prev_order);
                    }
                }
            }
        }

        {
            var add_sprite_button: dvui.ButtonWidget = undefined;
            add_sprite_button.init(@src(), .{}, .{
                .expand = .none,
                .gravity_y = 0.5,
                .padding = dvui.Rect.all(4),
                .corner_radius = dvui.Rect.all(1000),
                .box_shadow = .{
                    .color = .black,
                    .offset = .{ .x = -2.0, .y = 2.0 },
                    .fade = 6.0,
                    .alpha = 0.15,
                    .corner_radius = dvui.Rect.all(1000),
                },
                .color_fill = dvui.themeGet().color(.control, .fill),
            });

            defer add_sprite_button.deinit();
            add_sprite_button.processEvents();
            const alpha = dvui.alpha(if (file.selected_animation_index != null and file.animations.len > 0) 1.0 else 0.5);
            add_sprite_button.drawBackground();

            dvui.icon(
                @src(),
                "AddSpriteIcon",
                icons.tvg.lucide.plus,
                .{ .fill_color = icon_color, .stroke_color = icon_color },
                .{
                    .gravity_x = 0.5,
                    .gravity_y = 0.5,
                    .expand = .ratio,
                    .color_text = add_sprite_button.data().options.color_text,
                    .margin = dvui.Rect.all(0),
                    .padding = dvui.Rect.all(0),
                },
            );

            dvui.alphaSet(alpha);

            if (add_sprite_button.clicked()) {
                if (file.editor.selected_sprites.count() > 0) {
                    var iter = file.editor.selected_sprites.iterator(.{ .kind = .set, .direction = .forward });
                    var frames = std.array_list.Managed(pixi_mod.Animation.Frame).init(dvui.currentWindow().arena());
                    while (iter.next()) |sprite_index| {
                        frames.append(.{
                            .sprite_index = sprite_index,
                            .ms = @intFromFloat(1000.0 / @as(f32, @floatFromInt(file.editor.selected_sprites.count()))),
                        }) catch {
                            dvui.log.err("Failed to append frame", .{});
                            return;
                        };
                    }

                    const prev_order = try runtime.allocator().dupe(pixi_mod.Animation.Frame, animation.frames);

                    animation.appendFrames(runtime.allocator(), frames.items) catch {
                        dvui.log.err("Failed to append frames", .{});
                    };

                    if (!animation.eqlFrames(prev_order)) {
                        file.history.append(.{
                            .animation_frames = .{
                                .index = index,
                                .frames = prev_order,
                            },
                        }) catch {
                            dvui.log.err("Failed to append history", .{});
                        };

                        file.animations.set(index, animation);
                    } else {
                        runtime.allocator().free(prev_order);
                    }
                }
            }
        }

        var selection_in_animation = false;

        var selection_iter = file.editor.selected_sprites.iterator(.{ .kind = .set, .direction = .forward });
        blk: while (selection_iter.next()) |sprite_index| {
            for (animation.frames) |frame| {
                if (frame.sprite_index == sprite_index) {
                    selection_in_animation = true;
                    break :blk;
                }
            }
        }

        {
            var duplicate_animation_button: dvui.ButtonWidget = undefined;
            duplicate_animation_button.init(@src(), .{}, .{
                .expand = .none,
                .gravity_y = 0.5,
                .padding = dvui.Rect.all(4),
                .corner_radius = dvui.Rect.all(1000),
                .box_shadow = .{
                    .color = .black,
                    .offset = .{ .x = -2.0, .y = 2.0 },
                    .fade = 6.0,
                    .alpha = 0.15,
                    .corner_radius = dvui.Rect.all(1000),
                },
                .color_fill = dvui.themeGet().color(.control, .fill),
            });

            defer duplicate_animation_button.deinit();
            duplicate_animation_button.processEvents();
            const alpha = dvui.alpha(if (selection_in_animation) 1.0 else 0.5);
            duplicate_animation_button.drawBackground();

            dvui.icon(
                @src(),
                "DuplicateAnimationIcon",
                icons.tvg.lucide.@"copy-plus",
                .{ .fill_color = icon_color, .stroke_color = icon_color },
                .{
                    .gravity_x = 0.5,
                    .gravity_y = 0.5,
                    .expand = .ratio,
                    .color_text = duplicate_animation_button.data().options.color_text,
                    .margin = dvui.Rect.all(0),
                    .padding = dvui.Rect.all(0),
                },
            );

            dvui.alphaSet(alpha);

            if (duplicate_animation_button.clicked()) {
                var iter = file.editor.selected_sprites.iterator(.{ .kind = .set, .direction = .forward });
                const prev_order = try runtime.allocator().dupe(pixi_mod.Animation.Frame, animation.frames);

                while (iter.next()) |sprite_index| {
                    for (animation.frames) |frame| {
                        if (frame.sprite_index == sprite_index) {
                            try animation.appendFrame(runtime.allocator(), .{
                                .sprite_index = frame.sprite_index,
                                .ms = frame.ms,
                            });
                            break;
                        }
                    }
                }

                if (!animation.eqlFrames(prev_order)) {
                    file.history.append(.{
                        .animation_frames = .{
                            .index = index,
                            .frames = prev_order,
                        },
                    }) catch {
                        dvui.log.err("Failed to append history", .{});
                    };
                    file.selected_animation_frame_index = 0;
                    file.animations.set(index, animation);
                } else {
                    runtime.allocator().free(prev_order);
                }
            }
        }

        {
            var delete_animation_button: dvui.ButtonWidget = undefined;
            delete_animation_button.init(@src(), .{}, .{
                .expand = .none,
                .gravity_y = 0.5,
                .padding = dvui.Rect.all(4),
                .corner_radius = dvui.Rect.all(1000),
                .box_shadow = .{
                    .color = .black,
                    .offset = .{ .x = -2.0, .y = 2.0 },
                    .fade = 6.0,
                    .alpha = 0.15,
                    .corner_radius = dvui.Rect.all(1000),
                },
                .color_fill = dvui.themeGet().color(.err, .fill).opacity(0.75),
            });

            defer delete_animation_button.deinit();
            delete_animation_button.processEvents();
            const alpha = dvui.alpha(if (selection_in_animation) 1.0 else 0.5);
            delete_animation_button.drawBackground();

            dvui.icon(
                @src(),
                "DeleteAnimationIcon",
                icons.tvg.lucide.minus,
                .{ .fill_color = dvui.themeGet().color(.err, .text), .stroke_color = dvui.themeGet().color(.err, .text) },
                .{
                    .gravity_x = 0.5,
                    .gravity_y = 0.5,
                    .color_text = dvui.themeGet().color(.err, .text),
                    .expand = .ratio,
                    .margin = dvui.Rect.all(0),
                    .padding = dvui.Rect.all(0),
                },
            );

            dvui.alphaSet(alpha);

            if (delete_animation_button.clicked()) {
                var iter = file.editor.selected_sprites.iterator(.{ .kind = .set, .direction = .forward });
                const prev_order = try runtime.allocator().dupe(pixi_mod.Animation.Frame, animation.frames);

                while (iter.next()) |sprite_index| {
                    var i: usize = animation.frames.len;
                    while (i > 0) : (i -= 1) {
                        if (animation.frames[i - 1].sprite_index == sprite_index) {
                            animation.removeFrame(runtime.allocator(), i - 1);
                            break;
                        }
                    }
                }

                if (!animation.eqlFrames(prev_order)) {
                    file.history.append(.{
                        .animation_frames = .{
                            .index = index,
                            .frames = prev_order,
                        },
                    }) catch {
                        dvui.log.err("Failed to append history", .{});
                    };
                    file.selected_animation_frame_index = 0;
                    file.animations.set(index, animation);
                } else {
                    runtime.allocator().free(prev_order);
                }
            }
        }
    }
}

pub fn drawFrames(self: *Sprites) !void {
    if (runtime.state().docs.activeFile(runtime.state().host)) |file| {
        var anim = dvui.animate(@src(), .{ .kind = .horizontal, .duration = 450_000, .easing = dvui.easing.outBack }, .{});
        defer anim.deinit();

        const outer_box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .background = false,
        });
        defer outer_box.deinit();

        const controls_box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .none,
            .background = false,
        });
        dvui.labelNoFmt(@src(), "FRAMES", .{}, .{ .font = dvui.Font.theme(.heading) });

        self.drawFrameControls() catch {};

        controls_box.deinit();

        self.frames_scroll_viewport_rect = null;

        // Vertical-only: wide frame rows widen this column; the explorer scroll pans horizontally so
        // controls stay reachable. A nested horizontal scroller here fought the explorer at limits (bounce).
        file.editor.sprites_scroll_info.horizontal = .none;
        file.editor.sprites_scroll_info.viewport.x = 0;
        file.editor.sprites_scroll_info.velocity.x = 0;

        var scroll_area = dvui.scrollArea(@src(), .{ .scroll_info = &file.editor.sprites_scroll_info, .horizontal_bar = .hide, .vertical_bar = .auto_overlay }, .{
            .expand = .horizontal,
            .background = false,
            .corner_radius = dvui.Rect.all(1000),
        });

        defer scroll_area.deinit();

        if (dvui.ScrollContainerWidget.current()) |sc| {
            self.frames_scroll_viewport_rect = sc.data().contentRectScale().r;
        }

        var inner_box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
            .background = false,
            .margin = .{ .h = 6, .w = 6 },
        });
        defer inner_box.deinit();

        const vertical_scroll = file.editor.sprites_scroll_info.offset(.vertical);

        if (file.selected_animation_index) |animation_index| {
            var animation = file.animations.get(animation_index);
            if (animation.id != self.prev_anim_id) {
                frame_row_gesture = null;
            }

            defer self.prev_sprite_count = animation.frames.len;
            defer self.prev_anim_id = animation.id;

            var tree = pixi_mod.core.dvui.TreeWidget.tree(@src(), .{ .enable_reordering = true }, .{
                .expand = .horizontal,
                .background = false,
            });
            defer tree.deinit();

            var frame_hits_buf: [512]FrameRowHit = undefined;
            var frame_hits_len: usize = 0;

            if (self.sprite_insert_before_index) |insert_before_raw| {
                if (removed_frame_indices_len > 0) {
                    const sources = removed_frame_indices_buf[0..removed_frame_indices_len];

                    const prev_order = try runtime.allocator().dupe(pixi_mod.Animation.Frame, animation.frames);
                    defer file.animations.set(animation_index, animation);

                    const primary_before = file.selected_animation_frame_index;
                    var primary_was_moved = false;
                    var primary_pos_in_sources: usize = 0;
                    for (sources, 0..) |s, pi| {
                        if (s == primary_before) {
                            primary_was_moved = true;
                            primary_pos_in_sources = pi;
                            break;
                        }
                    }

                    var moved = try runtime.allocator().alloc(pixi_mod.Animation.Frame, sources.len);
                    defer runtime.allocator().free(moved);
                    for (sources, 0..) |s, i| {
                        moved[i] = animation.frames[s];
                    }

                    var remaining = try runtime.allocator().alloc(pixi_mod.Animation.Frame, animation.frames.len - sources.len);
                    defer runtime.allocator().free(remaining);
                    {
                        var ri: usize = 0;
                        var wi: usize = 0;
                        for (animation.frames, 0..) |f, idx| {
                            _ = f;
                            var is_source = false;
                            for (sources) |s| if (s == idx) {
                                is_source = true;
                                break;
                            };
                            if (!is_source) {
                                remaining[wi] = animation.frames[idx];
                                wi += 1;
                            }
                            ri += 1;
                        }
                    }

                    const target_raw = pixi_mod.core.dvui.TreeSelection.adjustInsertBeforeForRemovals(sources, insert_before_raw);
                    const target = @min(target_raw, remaining.len);

                    var wi: usize = 0;
                    for (remaining[0..target]) |f| {
                        animation.frames[wi] = f;
                        wi += 1;
                    }
                    for (moved) |f| {
                        animation.frames[wi] = f;
                        wi += 1;
                    }
                    for (remaining[target..]) |f| {
                        animation.frames[wi] = f;
                        wi += 1;
                    }

                    if (primary_was_moved) {
                        file.selected_animation_frame_index = target + primary_pos_in_sources;
                    }

                    file.editor.selected_frame_indices.clearRetainingCapacity();
                    for (0..moved.len) |i| {
                        file.editor.selected_frame_indices.append(runtime.allocator(), target + i) catch {
                            dvui.log.err("Failed to update frame selection", .{});
                        };
                    }
                    file.editor.selected_frame_indices_for_animation_id = animation.id;
                    file.editor.frame_selection_anchor = file.selected_animation_frame_index;
                    syncSpritesFromCurrentFrameSelection(file, animation_index);

                    if (!animation.eqlFrames(prev_order)) {
                        file.history.append(.{
                            .animation_frames = .{
                                .index = animation_index,
                                .frames = prev_order,
                            },
                        }) catch {
                            dvui.log.err("Failed to append history", .{});
                        };
                    } else {
                        runtime.allocator().free(prev_order);
                    }

                    self.sprite_insert_before_index = null;
                    removed_frame_indices_len = 0;
                } else {
                    self.sprite_insert_before_index = null;
                }
            } else if (removed_frame_indices_len > 0) {
                removed_frame_indices_len = 0;
            }

            ensureFrameSelection(file, animation_index, animation.id);

            const box = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .horizontal,
                .background = false,
                .corner_radius = dvui.Rect.all(1000),
                .margin = dvui.Rect.rect(4, 0, 4, 4),
            });
            defer box.deinit();

            for (animation.frames, 0..) |*frame, frame_index| {
                var anim_color = dvui.themeGet().color(.control, .fill_hover);
                if (runtime.state().colors.file_tree_palette) |*palette| {
                    anim_color = palette.getDVUIColor(@intCast(animation.id));
                }

                var branch = tree.branch(@src(), .{
                    .expanded = false,
                    .process_events = false,
                    .can_accept_children = false,
                    .animation_duration = 250_000,
                    .animation_easing = dvui.easing.outBack,
                }, .{
                    .id_extra = @intCast(frame_index),
                    .expand = .horizontal,
                    .corner_radius = dvui.Rect.all(1000),
                    .background = false,
                    .margin = .all(0),
                    .padding = dvui.Rect.all(1),
                });
                defer branch.deinit();

                if (branch.removed()) {
                    if (removed_frame_indices_len < removed_frame_indices_buf.len) {
                        removed_frame_indices_buf[removed_frame_indices_len] = frame_index;
                        removed_frame_indices_len += 1;
                    }
                } else if (branch.insertBefore()) {
                    self.sprite_insert_before_index = frame_index;
                }

                const row_r = branch.data().borderRectScale().r;
                const mp = dvui.currentWindow().mouse_pt;
                const row_hovered = row_r.contains(mp) and animationPointerInScrollViewport(mp, self.frames_scroll_viewport_rect);

                const sprite_selected = if (frame.sprite_index < file.editor.selected_sprites.capacity()) file.editor.selected_sprites.isSet(frame.sprite_index) else false;
                const ctrl_hover = dvui.themeGet().color(.control, .fill).opacity(0.5);
                const row_highlight = blk: {
                    if (tree.reorderDragActive()) {
                        if (tree.id_branch) |idb| {
                            break :blk idb == branch.data().id.asUsize();
                        }
                        break :blk false;
                    }
                    break :blk row_hovered and tree.drag_point == null;
                };

                var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .both,
                    .background = true,
                    .color_fill = if (branch.floating())
                        .transparent
                    else if ((sprite_selected or row_highlight))
                        ctrl_hover
                    else
                        .transparent,
                    .color_fill_hover = .transparent,
                    .margin = dvui.Rect{},
                    .padding = .{ .x = 5, .y = 3, .w = 5, .h = 2 },
                    .corner_radius = dvui.Rect.all(8),
                });
                defer hbox.deinit();

                var color_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .none,
                    .background = true,
                    .gravity_y = 0.5,
                    .min_size_content = .{ .w = 8.0, .h = 8.0 },
                    .color_fill = anim_color,
                    .corner_radius = dvui.Rect.all(1000),
                    .margin = .{ .x = 2, .w = 4 },
                    .padding = dvui.Rect.all(0),
                });
                color_box.deinit();

                dvui.labelNoFmt(@src(), try file.fmtSprite(dvui.currentWindow().arena(), frame.sprite_index, .grid), .{}, .{
                    .expand = .none,
                    .gravity_y = 0.5,
                    .margin = dvui.Rect.rect(2, 0, 2, 0),
                    .padding = dvui.Rect.all(0),
                    .corner_radius = dvui.Rect.all(1000),
                    .color_text = if (sprite_selected) dvui.themeGet().color(.control, .text) else dvui.themeGet().color(.control, .text),
                });

                var drag_sink = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .both,
                    .background = false,
                    .min_size_content = .{ .w = 0, .h = 0 },
                    .gravity_y = 0.5,
                });
                defer drag_sink.deinit();

                var ms_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .none,
                    .background = false,
                    .gravity_y = 0.5,
                    .gravity_x = 1.0,
                    .padding = dvui.Rect.all(0),
                    .margin = dvui.Rect.all(0),
                });
                defer ms_box.deinit();

                const frame_ms_text = std.fmt.allocPrint(dvui.currentWindow().arena(), "{d}", .{frame.ms}) catch {
                    dvui.log.err("Failed to allocate frame ms text", .{});
                    return;
                };

                const frame_font = dvui.Font.theme(.mono);
                const result = dvui.textEntryNumber(@src(), u32, .{ .value = &frame.ms, .min = 0, .max = 9999999 }, .{
                    .expand = .horizontal,
                    .background = false,
                    .padding = dvui.Rect.all(2),
                    .margin = dvui.Rect.all(0),
                    .border = dvui.Rect.all(0),
                    .min_size_content = .{
                        .w = frame_font.textSize(frame_ms_text).w + 2.0,
                        .h = frame_font.textSize(frame_ms_text).h + 2.0,
                    },
                    .font = frame_font,
                    .gravity_y = 0.5,
                });

                if (result.changed) {
                    if (result.value == .Valid) {
                        for (animation.frames) |*f| {
                            if (file.editor.selected_sprites.isSet(f.sprite_index) and file.editor.selected_sprites.isSet(frame.sprite_index)) {
                                f.ms = result.value.Valid;
                            }
                        }
                    }
                }

                dvui.labelNoFmt(@src(), "ms", .{}, .{
                    .gravity_y = 0.5,
                    .margin = dvui.Rect.all(0),
                    .font = frame_font,
                    .padding = .{ .x = 2, .w = 6 },
                });

                if (row_hovered and animationPointerInScrollViewport(mp, self.frames_scroll_viewport_rect)) {
                    dvui.cursorSet(.hand);
                }

                const ms_buttons_r = ms_box.data().borderRectScale().r;
                if (frame_hits_len < frame_hits_buf.len) {
                    // Hit-test the actual row chrome (hbox), not the branch shell — the branch
                    // border rect can be taller/wider than the interactive row and skew pick-one
                    // resolution when several rows' rects overlap the same point.
                    frame_hits_buf[frame_hits_len] = .{
                        .row_r = hbox.data().borderRectScale().r,
                        .buttons_r = ms_buttons_r,
                        .branch_usize = branch.data().id.asUsize(),
                        .frame_index = frame_index,
                        .sprite_index = frame.sprite_index,
                        .hbox_tl = hbox.data().rectScale().r.topLeft(),
                    };
                    frame_hits_len += 1;
                }
            }

            processFrameTreePointerEvents(tree, file, animation.id, animation_index, frame_hits_buf[0..frame_hits_len], self.frames_scroll_viewport_rect);

            if (tree.drag_point != null) {
                var tail = tree.branch(@src(), .{
                    .expanded = false,
                    .process_events = false,
                    .can_accept_children = false,
                }, .{
                    .id_extra = 0x7fff_fffc,
                    .expand = .horizontal,
                    .min_size_content = .{ .w = 0, .h = 14 },
                    .color_fill = .transparent,
                    .color_fill_hover = .transparent,
                    .color_fill_press = .transparent,
                });
                defer tail.deinit();
                if (tail.insertBefore()) {
                    self.sprite_insert_before_index = animation.frames.len;
                }
            }
        }

        const frames_si = file.editor.sprites_scroll_info;
        const frames_v_max = frames_si.scrollMax(.vertical);
        if (vertical_scroll > scroll_list_shadow_deadzone_ns)
            pixi_mod.core.dvui.drawEdgeShadow(scroll_area.data().contentRectScale(), .top, .{});

        if (frames_v_max > scroll_list_shadow_deadzone_ns and vertical_scroll < frames_v_max - scroll_list_shadow_deadzone_ns)
            pixi_mod.core.dvui.drawEdgeShadow(scroll_area.data().contentRectScale(), .bottom, .{});
    }
}

/// Geometry for one frame row; used for tree pointer pass (reorder / click).
const FrameRowHit = struct {
    row_r: dvui.Rect.Physical,
    buttons_r: dvui.Rect.Physical,
    branch_usize: usize,
    frame_index: usize,
    sprite_index: usize,
    hbox_tl: dvui.Point.Physical,
};

fn frameGestureMatches(file: *const pixi_mod.internal.File, anim_id: u64) bool {
    return frame_row_gesture != null and frame_row_gesture.?.file_id == file.id and frame_row_gesture.?.anim_id == anim_id;
}

fn frameTreeClearGestureKeysOnly(_: *const pixi_mod.internal.File) void {
    frame_row_gesture = null;
}

fn frameTreeResetRowPointerGesture(_: *const pixi_mod.internal.File) void {
    dvui.dragEnd();
    frame_row_gesture = null;
}

/// After `selected_frame_indices` changes, make tile selection match exactly those frames' sprites.
fn syncSpritesFromCurrentFrameSelection(file: *pixi_mod.internal.File, anim_index: usize) void {
    const frames = file.animations.get(anim_index).frames;
    file.clearSelectedSprites();
    for (file.editor.selected_frame_indices.items) |fi| {
        if (fi >= frames.len) continue;
        const si = frames[fi].sprite_index;
        if (si < file.editor.selected_sprites.capacity()) file.editor.selected_sprites.set(si);
    }
}

/// Frame selection is scoped to one animation at a time. `selected_frame_indices` always mirrors
/// `selected_sprites` for this animation's frames (so canvas changes can't leave stale tree state).
fn ensureFrameSelection(file: *pixi_mod.internal.File, anim_index: usize, anim_id: u64) void {
    const frames = file.animations.get(anim_index).frames;

    if (file.editor.selected_frame_indices_for_animation_id != anim_id) {
        file.editor.selected_frame_indices.clearRetainingCapacity();
        file.editor.frame_selection_anchor = null;
        file.editor.selected_frame_indices_for_animation_id = anim_id;
    }

    if (frames.len == 0) {
        file.editor.selected_frame_indices.clearRetainingCapacity();
        file.editor.frame_selection_anchor = null;
        file.selected_animation_frame_index = 0;
        return;
    }

    if (file.selected_animation_frame_index >= frames.len) {
        file.selected_animation_frame_index = frames.len - 1;
    }

    file.editor.selected_frame_indices.clearRetainingCapacity();
    for (frames, 0..) |f, i| {
        if (f.sprite_index < file.editor.selected_sprites.capacity() and file.editor.selected_sprites.isSet(f.sprite_index)) {
            file.editor.selected_frame_indices.append(runtime.allocator(), i) catch return;
        }
    }
    std.sort.pdq(usize, file.editor.selected_frame_indices.items, {}, std.sort.asc(usize));

    if (file.editor.frame_selection_anchor) |a| {
        var need_reanchor = false;
        if (a >= frames.len) {
            need_reanchor = true;
        } else {
            const spr = frames[a].sprite_index;
            if (spr >= file.editor.selected_sprites.capacity() or !file.editor.selected_sprites.isSet(spr)) {
                need_reanchor = true;
            }
        }
        if (need_reanchor) {
            // While animation plays, `selected_animation_frame_index` is the playhead and must not
            // be used to re-establish shift-range / TreeSelection "primary" when the user changes
            // which frames are selected (e.g. canvas rect select).
            if (file.editor.selected_frame_indices.items.len > 0) {
                file.editor.frame_selection_anchor = file.editor.selected_frame_indices.items[0];
            } else if (file.editor.playing) {
                file.editor.frame_selection_anchor = null;
            } else {
                file.editor.frame_selection_anchor = file.selected_animation_frame_index;
            }
        }
    }
}

fn applyFrameClick(
    file: *pixi_mod.internal.File,
    anim_index: usize,
    anim_id: u64,
    clicked: usize,
    mode: pixi_mod.core.dvui.TreeSelection.ClickMode,
) !bool {
    ensureFrameSelection(file, anim_index, anim_id);

    const prev_multi = file.editor.selected_frame_indices.items;

    var clicked_in_prev = false;
    for (prev_multi) |i| {
        if (i == clicked) {
            clicked_in_prev = true;
            break;
        }
    }
    const defer_narrow = (mode == .replace and prev_multi.len > 1 and clicked_in_prev);

    if (defer_narrow) {
        file.selected_animation_frame_index = clicked;
        return true;
    }

    var out: std.ArrayList(usize) = .empty;
    defer out.deinit(runtime.allocator());

    // When anchor is null, shift-extend uses `primary_opt` as the range endpoint. During playback
    // that index is the animated playhead, not the editor's last stable focus — use a selection
    // bound instead.
    const primary_for_tree: ?usize = if (mode == .extend and
        file.editor.playing and
        file.editor.frame_selection_anchor == null and
        file.editor.selected_frame_indices.items.len > 0) blk: {
        break :blk file.editor.selected_frame_indices.items[0];
    } else file.selected_animation_frame_index;

    const res = try pixi_mod.core.dvui.TreeSelection.applyClickUsize(
        runtime.allocator(),
        prev_multi,
        primary_for_tree,
        file.editor.frame_selection_anchor,
        clicked,
        mode,
        false,
        &out,
    );

    file.editor.selected_frame_indices.clearRetainingCapacity();
    try file.editor.selected_frame_indices.appendSlice(runtime.allocator(), out.items);
    file.editor.selected_frame_indices_for_animation_id = anim_id;
    file.editor.frame_selection_anchor = res.anchor;
    if (res.primary) |p| file.selected_animation_frame_index = p;
    syncSpritesFromCurrentFrameSelection(file, anim_index);
    return false;
}

fn narrowFrameSelectionTo(file: *pixi_mod.internal.File, anim_index: usize, anim_id: u64, clicked: usize) void {
    file.editor.selected_frame_indices.clearRetainingCapacity();
    file.editor.selected_frame_indices.append(runtime.allocator(), clicked) catch return;
    file.editor.selected_frame_indices_for_animation_id = anim_id;
    file.editor.frame_selection_anchor = clicked;
    file.selected_animation_frame_index = clicked;
    syncSpritesFromCurrentFrameSelection(file, anim_index);
}

fn buildFrameMultiDragIds(file: *const pixi_mod.internal.File, animation_index: usize, hits: []const FrameRowHit, out: []usize) []usize {
    const frames = file.animations.get(animation_index).frames;
    var len: usize = 0;
    const playhead = file.selected_animation_frame_index;
    const primary: usize = if (file.editor.selected_frame_indices.items.len > 0) blk: {
        for (file.editor.selected_frame_indices.items) |fi| {
            if (fi == playhead) break :blk playhead;
        }
        break :blk file.editor.selected_frame_indices.items[0];
    } else playhead;
    for (hits) |h| {
        if (h.frame_index == primary) {
            if (len < out.len) {
                out[len] = h.branch_usize;
                len += 1;
            }
            break;
        }
    }
    for (frames, 0..) |f, i| {
        if (i == primary) continue;
        if (f.sprite_index < file.editor.selected_sprites.capacity() and file.editor.selected_sprites.isSet(f.sprite_index)) {
            for (hits) |h| {
                if (h.frame_index == i) {
                    if (len < out.len) {
                        out[len] = h.branch_usize;
                        len += 1;
                    }
                    break;
                }
            }
        }
    }
    return out[0..len];
}

fn processFrameTreePointerEvents(
    tree: *pixi_mod.core.dvui.TreeWidget,
    file: *pixi_mod.internal.File,
    anim_id: u64,
    animation_index: usize,
    hits: []const FrameRowHit,
    viewport_r: ?dvui.Rect.Physical,
) void {
    if (!tree.init_options.enable_reordering) return;

    for (dvui.events()) |*e| {
        switch (e.evt) {
            .mouse => |me| {
                if (me.action == .press and me.button.pointer()) {
                    if (!animationPointerInScrollViewport(me.p, viewport_r)) continue;

                    var row_hit: ?FrameRowHit = null;
                    var ri = hits.len;
                    while (ri > 0) {
                        ri -= 1;
                        const h = hits[ri];
                        if (h.row_r.contains(me.p) and !h.buttons_r.contains(me.p)) {
                            row_hit = h;
                            break;
                        }
                    }
                    if (row_hit) |h| {
                        const cw = dvui.currentWindow();
                        if (cw.dragging.state != .none) dvui.dragEnd();
                        frameTreeClearGestureKeysOnly(file);
                        dvui.dragPreStart(me.p, .{ .offset = h.hbox_tl.diff(me.p) });

                        const mode = pixi_mod.core.dvui.TreeSelection.clickModeFromMod(me.mod);
                        const narrow_on_release = applyFrameClick(file, animation_index, anim_id, h.frame_index, mode) catch blk: {
                            dvui.log.err("Failed to apply frame click", .{});
                            break :blk false;
                        };

                        frame_row_gesture = .{
                            .file_id = file.id,
                            .anim_id = anim_id,
                            .press_idx = h.frame_index,
                            .press_p = me.p,
                            .drag_branch = h.branch_usize,
                            .moved = false,
                            .reorder_drag = false,
                            .narrow_on_release = narrow_on_release,
                        };

                        dvui.refresh(null, @src(), tree.data().id);
                    } else {
                        frameTreeResetRowPointerGesture(file);
                    }
                    continue;
                }

                if (me.action == .motion) {
                    if (frame_row_gesture) |*g| {
                        if (g.file_id == file.id and g.anim_id == anim_id) {
                            const dx = me.p.x - g.press_p.x;
                            const dy = me.p.y - g.press_p.y;
                            if (dx * dx + dy * dy > 16.0) {
                                g.moved = true;
                            }
                        }
                    }

                    if (tree.reorderDragActive()) {
                        _ = tree.matchEvent(e);
                        continue;
                    }

                    const branch_usize = if (frameGestureMatches(file, anim_id)) frame_row_gesture.?.drag_branch else null;
                    if (branch_usize == null) continue;
                    _ = tree.matchEvent(e);
                    if (!animationTreeMotionAllowsReorder(tree, e)) continue;

                    const prev_th = dvui.Dragging.threshold;
                    dvui.Dragging.threshold = @max(prev_th, 8.0);
                    defer dvui.Dragging.threshold = prev_th;
                    if (dvui.dragging(me.p, null)) |_| {
                        var row_size: dvui.Size = .{};
                        for (hits) |h| {
                            if (h.branch_usize == branch_usize.?) {
                                const rn = h.row_r.toNatural();
                                row_size = .{ .w = rn.w, .h = rn.h };
                                break;
                            }
                        }

                        var multi_buf: [256]usize = undefined;
                        const multi_ids = buildFrameMultiDragIds(file, animation_index, hits, &multi_buf);
                        if (multi_ids.len > 1) {
                            tree.dragStartMulti(branch_usize.?, multi_ids, me.p, row_size);
                        } else {
                            tree.dragStart(branch_usize.?, me.p, row_size);
                        }

                        if (frame_row_gesture) |*g| {
                            if (g.file_id == file.id and g.anim_id == anim_id) {
                                g.reorder_drag = true;
                                g.drag_branch = null;
                                g.narrow_on_release = false;
                            }
                        }
                    }
                } else if (me.action == .release and me.button.pointer()) {
                    const release_in_vp = animationPointerInScrollViewport(me.p, viewport_r);

                    var release_frame_idx: ?usize = null;
                    var rj = hits.len;
                    while (rj > 0) {
                        rj -= 1;
                        const h = hits[rj];
                        if (release_in_vp and h.row_r.contains(me.p) and !h.buttons_r.contains(me.p)) {
                            release_frame_idx = h.frame_index;
                            break;
                        }
                    }

                    const idx_opt: ?usize = if (frameGestureMatches(file, anim_id)) frame_row_gesture.?.press_idx else null;
                    const did_reorder = if (frameGestureMatches(file, anim_id)) frame_row_gesture.?.reorder_drag else false;
                    const narrow_on_release = if (frameGestureMatches(file, anim_id)) frame_row_gesture.?.narrow_on_release else false;

                    var selected_on_release = false;
                    // Finder-style narrow on release: only when a plain click lands & releases on
                    // the same already-multi-selected row.
                    if (!did_reorder and !tree.drag_ending and narrow_on_release and release_in_vp) {
                        if (release_frame_idx) |rh| {
                            if (idx_opt) |pi| if (rh == pi) {
                                narrowFrameSelectionTo(file, animation_index, anim_id, rh);
                                selected_on_release = true;
                            };
                        }
                    }

                    if (idx_opt != null) {
                        frameTreeResetRowPointerGesture(file);
                        if (!did_reorder and !dvui.captured(tree.data().id)) {
                            dvui.captureMouse(null, e.num);
                        }
                    }

                    if (selected_on_release) {
                        dvui.refresh(null, @src(), tree.data().id);
                    }
                }
            },
            else => {},
        }
    }
}

/// Geometry for one animation row; used for tree pointer pass (reorder / click / rename).
const AnimationRowHit = struct {
    row_r: dvui.Rect.Physical,
    buttons_r: dvui.Rect.Physical,
    branch_usize: usize,
    anim_index: usize,
    hbox_tl: dvui.Point.Physical,
};

fn animationGestureMatches(file: *const pixi_mod.internal.File) bool {
    return animation_row_gesture != null and animation_row_gesture.?.file_id == file.id;
}

fn animationTreeClearGestureKeysOnly(_: *const pixi_mod.internal.File) void {
    animation_row_gesture = null;
}

fn animationTreeResetRowPointerGesture(_: *const pixi_mod.internal.File) void {
    dvui.dragEnd();
    animation_row_gesture = null;
}

fn animationPointerRenameConsumes(e: *const dvui.Event, me: dvui.Event.Mouse) bool {
    if (e.handled) return true;
    if (anim_rename_hit_te_id) |rid| {
        if (e.target_widgetId) |tid| {
            if (tid == rid) return true;
        }
    }
    if (anim_rename_hit_rect) |r| {
        if (r.contains(me.p)) return true;
    }
    return false;
}

fn animationPointerInScrollViewport(p: dvui.Point.Physical, viewport_r: ?dvui.Rect.Physical) bool {
    if (viewport_r) |r| return r.contains(p);
    return true;
}

fn animationTreePointerInTreeSurface(tree: *pixi_mod.core.dvui.TreeWidget, p: dvui.Point.Physical, floating_win: dvui.Id) bool {
    if (floating_win != dvui.subwindowCurrentId()) return false;
    const tr = tree.data().borderRectScale().r;
    if (!tr.contains(p)) return false;
    if (!dvui.clipGet().contains(p)) return false;
    return true;
}

fn animationTreePointerInTreeBorder(tree: *pixi_mod.core.dvui.TreeWidget, p: dvui.Point.Physical, floating_win: dvui.Id) bool {
    if (floating_win != dvui.subwindowCurrentId()) return false;
    return tree.data().borderRectScale().r.contains(p);
}

fn animationTreeMotionAllowsReorder(tree: *pixi_mod.core.dvui.TreeWidget, e: *dvui.Event) bool {
    if (e.target_widgetId) |fwid| {
        if (fwid == tree.data().id) return true;
    }
    const cw = dvui.currentWindow();
    if (cw.dragging.state == .dragging and cw.dragging.name != null) return false;
    const me = e.evt.mouse;
    const in_surface = animationTreePointerInTreeSurface(tree, me.p, me.floating_win);
    const in_border = animationTreePointerInTreeBorder(tree, me.p, me.floating_win);
    return in_surface or in_border;
}

fn syncAnimationSelectionFrames(file: *pixi_mod.internal.File, anim_index: usize) void {
    const anim = file.animations.get(anim_index);
    if (anim.frames.len > 0) {
        if (file.selected_animation_frame_index >= anim.frames.len) {
            file.selected_animation_frame_index = anim.frames.len - 1;
        }
    } else {
        file.selected_animation_frame_index = 0;
    }
}

fn animationIndexInMulti(file: *const pixi_mod.internal.File, anim_index: usize) bool {
    for (file.editor.selected_animation_indices.items) |i| {
        if (i == anim_index) return true;
    }
    return false;
}

/// Keep `selected_animation_indices` consistent with the authoritative single-selection and the
/// current animation count. The set may be empty (no animations yet), but if `selected_animation_index`
/// is set we guarantee it appears in the set.
fn ensureAnimationSelection(file: *pixi_mod.internal.File) void {
    const count = file.animations.len;
    if (count == 0) {
        file.editor.selected_animation_indices.clearRetainingCapacity();
        file.editor.animation_selection_anchor = null;
        file.selected_animation_index = null;
        return;
    }

    var w: usize = 0;
    var items = file.editor.selected_animation_indices.items;
    for (items) |v| {
        if (v < count) {
            items[w] = v;
            w += 1;
        }
    }
    file.editor.selected_animation_indices.shrinkRetainingCapacity(w);

    if (file.selected_animation_index) |p| {
        if (p >= count) file.selected_animation_index = null;
    }
    if (file.selected_animation_index) |p| {
        var found = false;
        for (file.editor.selected_animation_indices.items) |v| {
            if (v == p) {
                found = true;
                break;
            }
        }
        if (!found) {
            file.editor.selected_animation_indices.append(runtime.allocator(), p) catch return;
            std.sort.pdq(usize, file.editor.selected_animation_indices.items, {}, std.sort.asc(usize));
        }
    }

    if (file.editor.animation_selection_anchor) |a| {
        if (a >= count) file.editor.animation_selection_anchor = file.selected_animation_index;
    }
}

/// Apply a modifier-aware click to the animation selection. Returns whether the click should defer
/// narrowing until release (Finder-style): plain click on an already-multi-selected row.
fn applyAnimationClick(file: *pixi_mod.internal.File, clicked: usize, mode: pixi_mod.core.dvui.TreeSelection.ClickMode) !bool {
    const prev_multi = file.editor.selected_animation_indices.items;
    const was_in_multi = animationIndexInMulti(file, clicked);
    const was_multi = prev_multi.len > 1;

    const defer_narrow = (mode == .replace and was_multi and was_in_multi);

    var out: std.ArrayList(usize) = .empty;
    defer out.deinit(runtime.allocator());

    if (defer_narrow) {
        try out.appendSlice(runtime.allocator(), prev_multi);
        std.sort.pdq(usize, out.items, {}, std.sort.asc(usize));
        file.editor.selected_animation_indices.clearRetainingCapacity();
        try file.editor.selected_animation_indices.appendSlice(runtime.allocator(), out.items);
        file.selected_animation_index = clicked;
        syncAnimationSelectionFrames(file, clicked);
        return true;
    }

    const res = try pixi_mod.core.dvui.TreeSelection.applyClickUsize(
        runtime.allocator(),
        prev_multi,
        file.selected_animation_index,
        file.editor.animation_selection_anchor,
        clicked,
        mode,
        false,
        &out,
    );

    file.editor.selected_animation_indices.clearRetainingCapacity();
    try file.editor.selected_animation_indices.appendSlice(runtime.allocator(), out.items);
    file.editor.animation_selection_anchor = res.anchor;
    file.selected_animation_index = res.primary;
    if (res.primary) |p| syncAnimationSelectionFrames(file, p);
    return false;
}

fn narrowAnimationSelectionTo(file: *pixi_mod.internal.File, clicked: usize) void {
    file.editor.selected_animation_indices.clearRetainingCapacity();
    file.editor.selected_animation_indices.append(runtime.allocator(), clicked) catch return;
    file.editor.animation_selection_anchor = clicked;
    file.selected_animation_index = clicked;
    syncAnimationSelectionFrames(file, clicked);
}

/// Populate `out` with the branch-ids of every selected animation row (primary first), for
/// `TreeWidget.dragStartMulti`. Returns a slice into `out` with just the written entries.
fn buildAnimationMultiDragIds(file: *const pixi_mod.internal.File, hits: []const AnimationRowHit, out: []usize) []usize {
    var len: usize = 0;
    const primary = file.selected_animation_index;
    if (primary) |p| {
        for (hits) |h| {
            if (h.anim_index == p) {
                if (len < out.len) {
                    out[len] = h.branch_usize;
                    len += 1;
                }
                break;
            }
        }
    }
    for (file.editor.selected_animation_indices.items) |i| {
        if (primary) |p| if (i == p) continue;
        for (hits) |h| {
            if (h.anim_index == i) {
                if (len < out.len) {
                    out[len] = h.branch_usize;
                    len += 1;
                }
                break;
            }
        }
    }
    return out[0..len];
}

fn processAnimationTreePointerEvents(_: *Sprites, tree: *pixi_mod.core.dvui.TreeWidget, file: *pixi_mod.internal.File, hits: []const AnimationRowHit, viewport_r: ?dvui.Rect.Physical) void {
    if (!tree.init_options.enable_reordering) return;

    for (dvui.events()) |*e| {
        switch (e.evt) {
            .mouse => |me| {
                if (me.action == .press and me.button.pointer()) {
                    if (animationPointerRenameConsumes(e, me)) continue;
                    if (!animationPointerInScrollViewport(me.p, viewport_r)) continue;

                    var row_hit: ?AnimationRowHit = null;
                    var ri = hits.len;
                    while (ri > 0) {
                        ri -= 1;
                        const h = hits[ri];
                        if (h.row_r.contains(me.p) and !h.buttons_r.contains(me.p)) {
                            row_hit = h;
                            break;
                        }
                    }
                    if (row_hit) |h| {
                        const cw = dvui.currentWindow();
                        if (cw.dragging.state != .none) dvui.dragEnd();
                        animationTreeClearGestureKeysOnly(file);
                        dvui.dragPreStart(me.p, .{ .offset = h.hbox_tl.diff(me.p) });

                        const mode = pixi_mod.core.dvui.TreeSelection.clickModeFromMod(me.mod);
                        const narrow_on_release = applyAnimationClick(file, h.anim_index, mode) catch blk: {
                            dvui.log.err("Failed to apply animation click", .{});
                            break :blk false;
                        };

                        animation_row_gesture = .{
                            .file_id = file.id,
                            .press_idx = h.anim_index,
                            .press_p = me.p,
                            .drag_branch = h.branch_usize,
                            .moved = false,
                            .reorder_drag = false,
                            .narrow_on_release = narrow_on_release,
                        };

                        dvui.refresh(null, @src(), tree.data().id);
                    } else {
                        animationTreeResetRowPointerGesture(file);
                    }
                    continue;
                }

                if (me.action == .motion) {
                    if (animationPointerRenameConsumes(e, me)) continue;

                    if (animation_row_gesture) |*g| {
                        if (g.file_id == file.id) {
                            const dx = me.p.x - g.press_p.x;
                            const dy = me.p.y - g.press_p.y;
                            if (dx * dx + dy * dy > 16.0) {
                                g.moved = true;
                            }
                        }
                    }

                    if (tree.reorderDragActive()) {
                        _ = tree.matchEvent(e);
                        continue;
                    }

                    const branch_usize = if (animationGestureMatches(file)) animation_row_gesture.?.drag_branch else null;
                    if (branch_usize == null) continue;
                    _ = tree.matchEvent(e);
                    if (!animationTreeMotionAllowsReorder(tree, e)) continue;

                    const prev_th = dvui.Dragging.threshold;
                    dvui.Dragging.threshold = @max(prev_th, 8.0);
                    defer dvui.Dragging.threshold = prev_th;
                    if (dvui.dragging(me.p, null)) |_| {
                        var row_size: dvui.Size = .{};
                        for (hits) |h| {
                            if (h.branch_usize == branch_usize.?) {
                                const rn = h.row_r.toNatural();
                                row_size = .{ .w = rn.w, .h = rn.h };
                                break;
                            }
                        }

                        var multi_buf: [64]usize = undefined;
                        const multi_ids = buildAnimationMultiDragIds(file, hits, &multi_buf);
                        if (multi_ids.len > 1) {
                            tree.dragStartMulti(branch_usize.?, multi_ids, me.p, row_size);
                        } else {
                            tree.dragStart(branch_usize.?, me.p, row_size);
                        }

                        if (animation_row_gesture) |*g| {
                            if (g.file_id == file.id) {
                                g.reorder_drag = true;
                                g.drag_branch = null;
                                g.narrow_on_release = false;
                            }
                        }
                    }
                } else if (me.action == .release and me.button.pointer()) {
                    if (animationPointerRenameConsumes(e, me)) continue;

                    const release_in_vp = animationPointerInScrollViewport(me.p, viewport_r);

                    var release_anim: ?usize = null;
                    var rj = hits.len;
                    while (rj > 0) {
                        rj -= 1;
                        const h = hits[rj];
                        if (release_in_vp and h.row_r.contains(me.p) and !h.buttons_r.contains(me.p)) {
                            release_anim = h.anim_index;
                            break;
                        }
                    }

                    const idx_opt: ?usize = if (animationGestureMatches(file)) animation_row_gesture.?.press_idx else null;
                    const did_reorder = if (animationGestureMatches(file)) animation_row_gesture.?.reorder_drag else false;
                    const narrow_on_release = if (animationGestureMatches(file)) animation_row_gesture.?.narrow_on_release else false;
                    var selected_on_release = false;
                    if (!did_reorder and !tree.drag_ending and narrow_on_release and release_in_vp) {
                        if (release_anim) |rh| {
                            if (idx_opt) |pi| if (rh == pi) {
                                narrowAnimationSelectionTo(file, rh);
                                selected_on_release = true;
                            };
                        }
                    }

                    if (idx_opt != null) {
                        animationTreeResetRowPointerGesture(file);
                        if (!did_reorder and !dvui.captured(tree.data().id)) {
                            dvui.captureMouse(null, e.num);
                        }
                    }

                    if (selected_on_release) {
                        dvui.refresh(null, @src(), tree.data().id);
                    }
                }
            },
            else => {},
        }
    }
}

const FrameSort = struct {
    pub fn asc(_: void, a: pixi_mod.Animation.Frame, b: pixi_mod.Animation.Frame) bool {
        return a.sprite_index < b.sprite_index;
    }

    pub fn desc(_: void, a: pixi_mod.Animation.Frame, b: pixi_mod.Animation.Frame) bool {
        return a.sprite_index > b.sprite_index;
    }
};
