const std = @import("std");
const math = std.math;
const dvui = @import("dvui");
const fizzy = @import("../../fizzy.zig");
const builtin = @import("builtin");
const sdl3 = @import("backend").c;

const Options = dvui.Options;
const Rect = dvui.Rect;
const Point = dvui.Point;

const BoxWidget = dvui.BoxWidget;
const ButtonWidget = dvui.ButtonWidget;
const ScrollAreaWidget = dvui.ScrollAreaWidget;
const ScrollContainerWidget = dvui.ScrollContainerWidget;
const ScaleWidget = dvui.ScaleWidget;

pub const FileWidget = @This();
const CanvasWidget = @import("CanvasWidget.zig");
const icons = @import("icons");

init_options: InitOptions,
options: Options,
drag_data_point: ?dvui.Point = null,
/// Absolute Δx/Δy from opposite corner → dragged corner at transform vertex press; used for default (no-mod) aspect lock.
transform_aspect_w: ?f32 = null,
transform_aspect_h: ?f32 = null,
sample_data_point: ?dvui.Point = null,
resize_data_point: ?dvui.Point = null,
previous_mods: dvui.enums.Mod = .none,
left_mouse_down: bool = false,
right_mouse_down: bool = false,
sample_key_down: bool = false,
shift_key_down: bool = false,
hide_distance_bubble: bool = false,
hovered_bubble_sprite_index: ?usize = null,
grid_reorder_point: ?dvui.Point = null,
cell_reorder_point: ?dvui.Point = null,
cell_reorder_mode: SpriteReorderMode = .replace,

removed_sprite_indices: ?[]usize = null,
insert_before_sprite_indices: ?[]usize = null,

const SpriteReorderMode = enum {
    replace,
    insert,
};

pub const InitOptions = struct {
    file: *fizzy.Internal.File,
    center: bool = false,
};

pub const temp_ms: u32 = 1000; // Default 1 second

pub fn init(src: std.builtin.SourceLocation, init_opts: InitOptions, opts: Options) FileWidget {
    const fw: FileWidget = .{
        .init_options = init_opts,
        .options = opts,
        .drag_data_point = if (dvui.dataGet(null, init_opts.file.editor.canvas.id, "drag_data_point", dvui.Point)) |point| point else null,
        .transform_aspect_w = dvui.dataGet(null, init_opts.file.editor.canvas.id, "transform_aspect_w", f32),
        .transform_aspect_h = dvui.dataGet(null, init_opts.file.editor.canvas.id, "transform_aspect_h", f32),
        .sample_data_point = if (dvui.dataGet(null, init_opts.file.editor.canvas.id, "sample_data_point", dvui.Point)) |point| point else null,
        .sample_key_down = if (dvui.dataGet(null, init_opts.file.editor.canvas.id, "sample_key_down", bool)) |key| key else false,
        .resize_data_point = if (dvui.dataGet(null, init_opts.file.editor.canvas.id, "resize_data_point", dvui.Point)) |point| point else null,
        .grid_reorder_point = if (dvui.dataGet(null, init_opts.file.editor.canvas.id, "grid_reorder_point", dvui.Point)) |point| point else null,
        .cell_reorder_point = if (dvui.dataGet(null, init_opts.file.editor.canvas.id, "cell_reorder_point", dvui.Point)) |point| point else null,
        .right_mouse_down = if (dvui.dataGet(null, init_opts.file.editor.canvas.id, "right_mouse_down", bool)) |key| key else false,
        .left_mouse_down = if (dvui.dataGet(null, init_opts.file.editor.canvas.id, "left_mouse_down", bool)) |key| key else false,
        .hide_distance_bubble = if (dvui.dataGet(null, init_opts.file.editor.canvas.id, "hide_distance_bubble", bool)) |key| key else false,
        .removed_sprite_indices = if (dvui.dataGetSlice(null, init_opts.file.editor.canvas.id, "removed_sprite_indices", []usize)) |slice| slice else null,
    };

    init_opts.file.editor.canvas.install(src, .{
        .id = init_opts.file.editor.canvas.id,
        .data_size = .{
            .w = @floatFromInt(init_opts.file.width()),
            .h = @floatFromInt(init_opts.file.height()),
        },
        .center = init_opts.center,
    }, opts);

    return fw;
}

pub fn processSample(self: *FileWidget) void {
    const file = self.init_options.file;

    const current_mods = dvui.currentWindow().modifiers;

    if (current_mods.matchBind("ctrl/cmd") and !self.previous_mods.matchBind("ctrl/cmd") and (self.right_mouse_down or self.sample_key_down)) {
        const current_point = self.init_options.file.editor.canvas.dataFromScreenPoint(dvui.currentWindow().mouse_pt);
        self.sample(file, current_point, true, true);
    }

    if (current_mods.matchBind("sample") and !self.previous_mods.matchBind("sample")) {
        self.sample_key_down = true;
        const current_point = self.init_options.file.editor.canvas.dataFromScreenPoint(dvui.currentWindow().mouse_pt);
        self.sample(file, current_point, self.right_mouse_down or self.left_mouse_down, false);
    } else if (!current_mods.matchBind("sample") and self.sample_key_down) {
        self.sample_key_down = false;
        if (!self.right_mouse_down) {
            self.sample_data_point = null;
        }
    }

    for (dvui.events()) |*e| {
        switch (e.evt) {
            .mouse => |me| {
                if (!self.init_options.file.editor.canvas.scroll_container.matchEvent(e)) {
                    continue;
                }
                const current_point = self.init_options.file.editor.canvas.dataFromScreenPoint(me.p);

                if (me.action == .press and me.button.pointer()) {
                    dvui.refresh(null, @src(), self.init_options.file.editor.canvas.scroll_container.data().id);
                    self.left_mouse_down = true;
                    if (dvui.dragging(me.p, "sample_drag")) |_| {
                        self.sample(file, current_point, true, false);
                    }
                } else if (me.action == .release and me.button.pointer()) {
                    dvui.refresh(null, @src(), self.init_options.file.editor.canvas.scroll_container.data().id);
                    self.left_mouse_down = false;
                }

                if (me.action == .press and me.button == .right) {
                    dvui.refresh(null, @src(), self.init_options.file.editor.canvas.scroll_container.data().id);
                    self.right_mouse_down = true;
                    e.handle(@src(), self.init_options.file.editor.canvas.scroll_container.data());
                    dvui.captureMouse(self.init_options.file.editor.canvas.scroll_container.data(), e.num);
                    dvui.dragPreStart(me.p, .{ .name = "sample_drag" });
                    self.drag_data_point = current_point;

                    self.sample(file, current_point, self.sample_key_down or self.left_mouse_down, false);

                    clearTempPreview(&file.editor);
                    if (file.editor.temp_layer_has_content) {
                        @memset(file.editor.temporary_layer.pixels(), .{ 0, 0, 0, 0 });
                    }
                    file.editor.temp_layer_has_content = false;
                    file.editor.temporary_layer.dirty = false;
                } else if (me.action == .release and me.button == .right) {
                    dvui.refresh(null, @src(), self.init_options.file.editor.canvas.scroll_container.data().id);
                    self.right_mouse_down = false;
                    self.sample(file, current_point, self.sample_key_down or self.left_mouse_down, true);
                    if (dvui.captured(self.init_options.file.editor.canvas.scroll_container.data().id)) {
                        e.handle(@src(), self.init_options.file.editor.canvas.scroll_container.data());
                        dvui.captureMouse(null, e.num);
                        dvui.dragEnd();

                        if (!self.sample_key_down) {
                            self.drag_data_point = null;
                            self.sample_data_point = null;
                        }
                    }
                } else if (me.action == .motion or me.action == .wheel_x or me.action == .wheel_y) {
                    if (dvui.captured(self.init_options.file.editor.canvas.scroll_container.data().id)) {
                        if (dvui.dragging(me.p, "sample_drag")) |diff| {
                            const previous_point = current_point.plus(self.init_options.file.editor.canvas.dataFromScreenPoint(diff));
                            // Construct a rect spanning between current_point and previous_point
                            const min_x = @min(previous_point.x, current_point.x);
                            const min_y = @min(previous_point.y, current_point.y);
                            const max_x = @max(previous_point.x, current_point.x);
                            const max_y = @max(previous_point.y, current_point.y);
                            const span_rect = dvui.Rect{
                                .x = min_x,
                                .y = min_y,
                                .w = max_x - min_x + 5,
                                .h = max_y - min_y + 5,
                            };

                            const screen_rect = self.init_options.file.editor.canvas.screenFromDataRect(span_rect);

                            dvui.scrollDrag(.{
                                .mouse_pt = me.p,
                                .screen_rect = screen_rect,
                            });

                            self.sample(file, current_point, self.sample_key_down or self.left_mouse_down or current_mods.matchBind("ctrl/cmd"), false);
                            e.handle(@src(), self.init_options.file.editor.canvas.scroll_container.data());
                        }
                    } else if (self.right_mouse_down or self.sample_key_down) {
                        self.sample(file, current_point, self.right_mouse_down and (self.sample_key_down or self.left_mouse_down or current_mods.matchBind("ctrl/cmd")), false);
                    }
                }
            },
            else => {},
        }
    }
}

fn sample(self: *FileWidget, file: *fizzy.Internal.File, point: dvui.Point, change_layer: bool, change_tool: bool) void {
    self.sample_data_point = point;
    var color: [4]u8 = .{ 0, 0, 0, 0 };

    var min_layer_index: usize = 0;

    if (file.editor.isolate_layer) {
        if (file.peek_layer_index) |peek_layer_index| {
            min_layer_index = peek_layer_index;
        } else if (!fizzy.editor.explorer.tools.layersHovered()) {
            min_layer_index = file.selected_layer_index;
        }
    }

    var layer_index: usize = file.layers.len;
    while (layer_index > min_layer_index) {
        layer_index -= 1;
        var layer = file.layers.get(layer_index);
        if (!layer.visible) continue;
        if (layer.pixelIndex(point)) |index| {
            const c = layer.pixels()[index];
            if (c[3] > 0) {
                color = c;
                if (change_layer and !file.editor.isolate_layer) {
                    file.selected_layer_index = layer_index;
                    file.peek_layer_index = layer_index;
                }
            }
        }
    }

    if (change_tool) {
        if (color[3] == 0) {
            if (fizzy.editor.tools.current != .eraser) {
                fizzy.editor.tools.set(.eraser);
            }
        } else {
            fizzy.editor.colors.primary = color;
            if (switch (fizzy.editor.tools.current) {
                .pencil, .bucket => false,
                else => true,
            })
                fizzy.editor.tools.set(fizzy.editor.tools.previous_drawing_tool);
        }
    }
}

/// Responsible for changing the currently selected animation index, the animation frame index, and the animations scroll to index
/// when the user clicks on a sprite that is part of an animation.
///
/// This is not restricted to any pane or tool, and will change on hover for any tool except the pointer tool.
pub fn processAnimationSelection(self: *FileWidget) void {
    const file = self.init_options.file;
    for (dvui.events()) |*e| {
        if (!self.init_options.file.editor.canvas.scroll_container.matchEvent(e)) {
            continue;
        }

        switch (e.evt) {
            .mouse => |me| {
                if ((me.button.pointer() and me.action == .press and !me.mod.matchBind("ctrl/cmd") and !me.mod.matchBind("shift")) or (fizzy.editor.tools.current != .pointer and self.sample_data_point == null)) {
                    if (file.spriteIndex(self.init_options.file.editor.canvas.dataFromScreenPoint(me.p))) |sprite_index| {
                        var found: bool = false;
                        for (file.animations.items(.frames), 0..) |frames, anim_index| {
                            for (frames, 0..) |frame, frame_index| {
                                if (frame.sprite_index == sprite_index) {
                                    file.selected_animation_index = anim_index;
                                    file.editor.animations_scroll_to_index = anim_index;

                                    if (!file.editor.playing)
                                        file.selected_animation_frame_index = frame_index;

                                    file.collapseAnimationSelectionToPrimary();
                                    found = true;
                                    break;
                                }
                                if (found) break;
                            }
                            if (found) break;
                        }
                    }
                }
            },
            else => {},
        }
    }
}

pub fn processCellReorder(self: *FileWidget) void {
    if (fizzy.editor.tools.current != .pointer) return;
    if (self.init_options.file.editor.transform != null) return;
    if (self.sample_data_point != null) return;
    if (self.drag_data_point != null) return;
    if (dvui.currentWindow().modifiers.matchBind("shift")) return;

    const file = self.init_options.file;

    for (dvui.events()) |*e| {
        if (!file.editor.canvas.scroll_container.matchEvent(e)) {
            continue;
        }

        switch (e.evt) {
            .mouse => |me| {
                const current_point = file.editor.canvas.dataFromScreenPoint(dvui.currentWindow().mouse_pt);

                var selected_sprite_move_hovered: bool = false;

                var iter = file.editor.selected_sprites.iterator(.{ .kind = .set, .direction = .forward });
                while (iter.next()) |sprite_index| {
                    const sprite_rect = file.spriteRect(sprite_index);
                    if (sprite_rect.contains(current_point)) {
                        selected_sprite_move_hovered = true;
                        break;
                    }
                }

                if (selected_sprite_move_hovered) {
                    dvui.cursorSet(.hand);
                }

                if (me.action == .press and me.button.pointer()) {
                    if (file.editor.selected_sprites.count() > 0) {
                        if (selected_sprite_move_hovered) {
                            e.handle(@src(), file.editor.canvas.scroll_container.data());
                            dvui.captureMouse(file.editor.canvas.scroll_container.data(), e.num);

                            const index = file.spriteIndex(current_point);
                            var offset: dvui.Point = .{};
                            if (index) |i| {
                                offset = file.spriteRect(i).topLeft().diff(current_point);
                            }
                            dvui.dragPreStart(me.p, .{ .name = "sprite_reorder_drag", .offset = file.editor.canvas.screenFromDataPoint(offset) });

                            self.cell_reorder_point = current_point;
                        }
                    }
                } else if (me.action == .release and me.button.pointer()) {
                    if (dvui.captured(file.editor.canvas.scroll_container.data().id) and dvui.dragging(me.p, "sprite_reorder_drag") != null) {
                        e.handle(@src(), file.editor.canvas.scroll_container.data());
                        dvui.captureMouse(null, e.num);
                        dvui.dragEnd();
                        dvui.refresh(null, @src(), file.editor.canvas.scroll_container.data().id);
                    }

                    if (self.cell_reorder_point) |cell_reorder_point| {
                        defer self.cell_reorder_point = null;
                        const drag_index = file.spriteIndex(cell_reorder_point.plus(file.editor.canvas.dataFromScreenPoint(dvui.dragOffset())));
                        if (drag_index) |di| {
                            if (di != file.spriteIndex(current_point)) {
                                // Drag has moved to a new cell, so we have shifted some sprites around
                                // and we have released, so we need to allocate a new array of insert_before_sprite_indices

                                if (self.removed_sprite_indices) |removed_sprite_indices| {
                                    if (self.insert_before_sprite_indices) |insert_before_sprite_indices| {
                                        fizzy.app.allocator.free(insert_before_sprite_indices);
                                        self.insert_before_sprite_indices = null;
                                    }

                                    // This will actually trigger the drag/drop
                                    var insert_before_sprite_indices = fizzy.app.allocator.alloc(usize, file.editor.selected_sprites.count()) catch {
                                        dvui.log.err("Failed to allocate insert before sprite indices", .{});
                                        return;
                                    };
                                    for (removed_sprite_indices, 0..) |removed_sprite_index, i| {
                                        const removed_sprite_rect = file.spriteRect(removed_sprite_index);
                                        const difference = current_point.diff(cell_reorder_point);

                                        if (file.spriteIndex(removed_sprite_rect.center().plus(difference))) |index| {
                                            insert_before_sprite_indices[i] = index;
                                        } else {
                                            insert_before_sprite_indices[i] = file.wrappedSpriteIndex(removed_sprite_rect.center().plus(difference));
                                        }
                                    }

                                    self.insert_before_sprite_indices = insert_before_sprite_indices;

                                    // This is where we will call reorder
                                    file.reorderCells(removed_sprite_indices, insert_before_sprite_indices, .replace, false) catch {
                                        dvui.log.err("Failed to reorder sprites", .{});
                                        return;
                                    };

                                    file.history.append(.{
                                        .reorder_cell = .{
                                            .removed_sprite_indices = fizzy.app.allocator.dupe(usize, removed_sprite_indices) catch {
                                                dvui.log.err("Failed to duplicate removed sprite indices", .{});
                                                return;
                                            },
                                            .insert_before_sprite_indices = fizzy.app.allocator.dupe(usize, insert_before_sprite_indices) catch {
                                                dvui.log.err("Failed to duplicate insert before sprite indices", .{});
                                                return;
                                            },
                                        },
                                    }) catch {
                                        dvui.log.err("Failed to append history", .{});
                                        return;
                                    };
                                }
                            }
                        }
                    }

                    if (self.removed_sprite_indices) |_| {
                        self.removed_sprite_indices = null;
                        dvui.dataRemove(null, file.editor.canvas.id, "removed_sprite_indices");
                    }
                } else if (me.action == .motion or me.action == .wheel_x or me.action == .wheel_y) {
                    if (dvui.captured(file.editor.canvas.scroll_container.data().id)) {
                        if (dvui.dragging(me.p, "sprite_reorder_drag")) |_| {
                            dvui.cursorSet(.hand);
                            defer e.handle(@src(), file.editor.canvas.scroll_container.data());
                            if (self.removed_sprite_indices == null and file.editor.selected_sprites.count() > 0) {
                                var removed_sprite_indices = fizzy.app.allocator.alloc(usize, file.editor.selected_sprites.count()) catch {
                                    dvui.log.err("Failed to allocate removed sprite indices", .{});
                                    return;
                                };
                                var i: usize = 0;
                                var sprite_iter = file.editor.selected_sprites.iterator(.{ .kind = .set, .direction = .forward });
                                while (sprite_iter.next()) |sprite_index| {
                                    removed_sprite_indices[i] = sprite_index;
                                    i += 1;
                                }
                                self.removed_sprite_indices = removed_sprite_indices;
                                dvui.dataSetSlice(null, file.editor.canvas.id, "removed_sprite_indices", removed_sprite_indices);
                            }
                        }
                    }
                }
            },
            else => {},
        }
    }
}

/// Responsible for handling rough/broad sprite selection (grid tiles)
/// Sprites can only be selected with the pointer tool.
///
/// Supports add/remove, drag selection, etc.
pub fn processSpriteSelection(self: *FileWidget) void {
    if (fizzy.editor.tools.current != .pointer) return;
    if (self.init_options.file.editor.transform != null) return;
    if (self.sample_data_point != null) return;

    const file = self.init_options.file;

    // A second finger landing on a pending single-finger press promotes the touch to a
    // pan/pinch gesture (see CanvasWidget.updateTouchGesture). The first press already
    // ran through this handler and seeded `drag_data_point` / a `sprite_selection_drag`,
    // which would otherwise render the marquee box while the user pans. The gesture
    // takeover already reassigned mouse capture to the scaler, so just clear our own
    // drag state and end the named drag.
    if (file.editor.canvas.gesture_active) {
        if (self.drag_data_point != null) {
            self.drag_data_point = null;
            if (dvui.dragName("sprite_selection_drag")) {
                dvui.dragEnd();
            }
            dvui.refresh(null, @src(), file.editor.canvas.scroll_container.data().id);
        }
        return;
    }

    for (dvui.events()) |*e| {
        if (!file.editor.canvas.scroll_container.matchEvent(e)) {
            continue;
        }

        switch (e.evt) {
            .key => |ke| {
                if (ke.mod.matchBind("shift")) {
                    switch (ke.action) {
                        .down, .repeat => {
                            self.shift_key_down = true;
                        },
                        .up => {
                            self.shift_key_down = false;
                        },
                    }
                }
            },
            .mouse => |me| {
                const current_point = self.init_options.file.editor.canvas.dataFromScreenPoint(me.p);

                if (me.action == .press and me.button.pointer()) {
                    if (me.mod.matchBind("shift")) {
                        self.shift_key_down = true;
                        if (file.spriteIndex(self.init_options.file.editor.canvas.dataFromScreenPoint(me.p))) |sprite_index| {
                            file.editor.selected_sprites.unset(sprite_index);
                        }
                    } else if (me.mod.matchBind("ctrl/cmd")) {
                        if (file.spriteIndex(self.init_options.file.editor.canvas.dataFromScreenPoint(me.p))) |sprite_index| {
                            file.editor.selected_sprites.set(sprite_index);
                        }
                    } else {
                        if (file.spriteIndex(self.init_options.file.editor.canvas.dataFromScreenPoint(me.p))) |sprite_index| {
                            const selected = file.editor.selected_sprites.isSet(sprite_index);
                            file.clearSelectedSprites();

                            if (!selected) {
                                file.editor.selected_sprites.set(sprite_index);
                            }
                        } else if (!file.editor.canvas.hovered) {
                            fizzy.editor.cancel() catch {
                                dvui.log.err("Failed to cancel", .{});
                            };
                        }
                    }

                    e.handle(@src(), self.init_options.file.editor.canvas.scroll_container.data());
                    dvui.captureMouse(self.init_options.file.editor.canvas.scroll_container.data(), e.num);
                    dvui.dragPreStart(me.p, .{ .name = "sprite_selection_drag" });

                    self.drag_data_point = current_point;
                } else if (me.action == .release and me.button.pointer()) {
                    if (dvui.captured(self.init_options.file.editor.canvas.scroll_container.data().id) and dvui.dragging(me.p, "sprite_selection_drag") != null) {
                        e.handle(@src(), self.init_options.file.editor.canvas.scroll_container.data());
                        dvui.captureMouse(null, e.num);
                        dvui.dragEnd();
                        dvui.refresh(null, @src(), self.init_options.file.editor.canvas.scroll_container.data().id);
                    }
                    self.drag_data_point = null;
                } else if (me.action == .motion or me.action == .wheel_x or me.action == .wheel_y) {
                    if (dvui.captured(self.init_options.file.editor.canvas.scroll_container.data().id)) {
                        if (dvui.dragging(me.p, "sprite_selection_drag")) |_| {
                            if (self.drag_data_point) |previous_point| {
                                e.handle(@src(), self.init_options.file.editor.canvas.scroll_container.data());
                                const min_x = @min(previous_point.x, current_point.x);
                                const min_y = @min(previous_point.y, current_point.y);
                                const max_x = @max(previous_point.x, current_point.x);
                                const max_y = @max(previous_point.y, current_point.y);
                                const span_rect = dvui.Rect{
                                    .x = min_x,
                                    .y = min_y,
                                    .w = @max(max_x - min_x, 1),
                                    .h = @max(max_y - min_y, 1),
                                };

                                const screen_selection_rect = self.init_options.file.editor.canvas.screenFromDataRect(span_rect);

                                dvui.scrollDrag(.{
                                    .mouse_pt = me.p,
                                    .screen_rect = screen_selection_rect,
                                });

                                if (me.mod.matchBind("shift")) {
                                    file.setSpriteSelection(span_rect, false);
                                    self.shift_key_down = true;
                                    //selection_color = dvui.themeGet().color(.err, .fill).opacity(0.5);
                                } else if (me.mod.matchBind("ctrl/cmd")) {
                                    file.setSpriteSelection(span_rect, true);
                                    self.shift_key_down = false;
                                } else {
                                    self.shift_key_down = false;
                                    file.clearSelectedSprites();
                                    file.setSpriteSelection(span_rect, true);
                                }
                            }
                        }
                    }
                }
            },
            else => {},
        }
    }
}

/// Cached once per `drawSpriteBubbles` / grid batch — avoids per-sprite `matchBind`, `count`, and `animationGet`.
const BubblePanShared = struct {
    bubble_open: ?dvui.Animation,
    bubble_close: ?dvui.Animation,
    peek: bool,
    selection_nonempty: bool,
    tool_not_pointer: bool,
};

/// Same read-only state as `drawSpriteBubbles` uses for `BubblePanShared` (no animation side effects).
fn bubblePanSharedForGrid(self: *FileWidget) ?BubblePanShared {
    if (self.init_options.file.editor.transform != null) return null;
    if (self.resize_data_point != null) return null;
    if (self.init_options.file.editor.workspace.columns_drag_index != null) return null;
    if (self.init_options.file.editor.workspace.rows_drag_index != null) return null;
    if (self.removed_sprite_indices != null) return null;
    if (!(self.active() or self.hovered())) return null;

    const animation_id = self.init_options.file.editor.canvas.scroll_container.data().id;
    const cw = dvui.currentWindow();
    const tool_not_pointer = fizzy.editor.tools.current != .pointer;
    const mod_shift = cw.modifiers.matchBind("shift");
    const mod_ctrl_cmd = cw.modifiers.matchBind("ctrl/cmd");
    const sample_active = self.sample_data_point != null;
    const drag_sprite_selection = dvui.dragName("sprite_selection_drag");

    return .{
        .bubble_open = dvui.animationGet(animation_id, "bubble_open"),
        .bubble_close = dvui.animationGet(animation_id, "bubble_close"),
        .peek = drag_sprite_selection or mod_shift or mod_ctrl_cmd or tool_not_pointer or sample_active,
        .selection_nonempty = self.init_options.file.editor.selected_sprites.count() > 0,
        .tool_not_pointer = tool_not_pointer,
    };
}

/// Returns whether `drawSpriteBubbles` will invoke `drawSpriteBubble` for this sprite (same
/// conditions as the inner loop, without the shadow/bubble pass split). Used so horizontal grid
/// can be drawn per cell: we skip the flat grid segment where the bubble arc replaces it.
/// Pass shared bubble state from `bubblePanSharedForGrid` when iterating many sprites (avoids repeated `animationGet`).
fn spriteDrawsBubbleTopEdge(self: *FileWidget, sprite_index: usize, pan: ?BubblePanShared) bool {
    const p = pan orelse return false;

    const sprite_rect = self.init_options.file.spriteRect(sprite_index);

    var automatic_animation: bool = false;
    var animation_index: ?usize = null;

    if (self.init_options.file.selected_animation_index) |selected_animation_index| {
        for (self.init_options.file.animations.items(.frames)[selected_animation_index], 0..) |frame, i| {
            _ = i;
            if (frame.sprite_index == sprite_index) {
                animation_index = selected_animation_index;
                break;
            }
        }
    }

    if (animation_index == null) {
        anim_blk: for (self.init_options.file.animations.items(.frames), 0..) |frames, i| {
            for (frames, 0..) |frame, j| {
                _ = j;
                if (frame.sprite_index == sprite_index) {
                    animation_index = i;
                    break :anim_blk;
                }
            }
        }
    }

    if (animation_index) |ai| {
        if (self.init_options.file.selected_animation_index == ai) {
            automatic_animation = true;
        }
    }

    const sel_nonempty = p.selection_nonempty;
    if (sel_nonempty) {
        if (self.init_options.file.editor.selected_sprites.isSet(sprite_index)) {
            automatic_animation = true;
        }
    }

    if (automatic_animation) {
        return true;
    }

    if (sel_nonempty) {
        if (!self.init_options.file.editor.selected_sprites.isSet(sprite_index) or (animation_index != self.init_options.file.selected_animation_index and !self.init_options.file.editor.selected_sprites.isSet(sprite_index))) {
            return false;
        }
    }

    var max_distance: f32 = sprite_rect.h * 1.2;

    if (p.bubble_open) |anim| {
        max_distance += (max_distance * 0.5) * (1.0 - anim.value());
    } else if (p.bubble_close) |anim| {
        max_distance += (max_distance * 0.5) * (1.0 - anim.value());
    } else {
        max_distance += (max_distance * 0.5) * if (!self.hide_distance_bubble) @as(f32, 0.0) else @as(f32, 1.0);
    }

    const current_point = self.init_options.file.editor.canvas.dataFromScreenPoint(dvui.currentWindow().mouse_pt);

    const dx = @abs(current_point.x - (sprite_rect.x + sprite_rect.w * 0.5));
    const dy = @abs(current_point.y - (sprite_rect.y - sprite_rect.h * 0.25));
    const distance = @sqrt((dx * dx) * 0.5 + (dy * dy) * 2.0);

    return distance < (max_distance * 2.0);
}

/// Accumulator that merges multiple Triangles batches into a single draw call.
const TriAcc = struct {
    vtx: std.ArrayList(dvui.Vertex) = .empty,
    idx: std.ArrayList(dvui.Vertex.Index) = .empty,
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator) TriAcc {
        return .{ .alloc = alloc };
    }

    fn append(self: *TriAcc, tris: dvui.Triangles) void {
        const base: dvui.Vertex.Index = @intCast(self.vtx.items.len);
        self.vtx.appendSlice(self.alloc, tris.vertexes) catch return;
        self.idx.ensureUnusedCapacity(self.alloc, tris.indices.len) catch return;
        for (tris.indices) |idx| {
            self.idx.appendAssumeCapacity(idx + base);
        }
    }

    fn render(self: *const TriAcc, tex: ?dvui.Texture) void {
        if (self.vtx.items.len == 0) return;
        var min_x: f32 = std.math.floatMax(f32);
        var min_y: f32 = std.math.floatMax(f32);
        var max_x: f32 = -std.math.floatMax(f32);
        var max_y: f32 = -std.math.floatMax(f32);
        for (self.vtx.items) |v| {
            min_x = @min(min_x, v.pos.x);
            min_y = @min(min_y, v.pos.y);
            max_x = @max(max_x, v.pos.x);
            max_y = @max(max_y, v.pos.y);
        }
        dvui.renderTriangles(.{
            .vertexes = self.vtx.items,
            .indices = self.idx.items,
            .bounds = .{ .x = min_x, .y = min_y, .w = max_x - min_x, .h = max_y - min_y },
        }, tex) catch {};
    }

    fn clear(self: *TriAcc) void {
        self.vtx.clearRetainingCapacity();
        self.idx.clearRetainingCapacity();
    }
};

const BubbleAccs = struct {
    shadow: TriAcc,
    fill: TriAcc,
    tex: TriAcc,
    outline: TriAcc,

    fn init(alloc: std.mem.Allocator) BubbleAccs {
        return .{
            .shadow = TriAcc.init(alloc),
            .fill = TriAcc.init(alloc),
            .tex = TriAcc.init(alloc),
            .outline = TriAcc.init(alloc),
        };
    }

    fn clearAll(self: *BubbleAccs) void {
        self.shadow.clear();
        self.fill.clear();
        self.tex.clear();
        self.outline.clear();
    }
};

/// Responsible for drawing the indicators for animation frames as bubbles over each sprite.
///
/// Bubbles contain a button that acts as a toggle for adding/removing a sprite from an animation.
/// When using the pointer tool, bubbles will be drawn based on distance from the mouse location, as well as the currently selected animation frames.
/// When using other tools, bubbles will be drawn based on the currently selected animation frames.
///
/// Bubbles use a elastic animation, and also display the currently viewed animation frame in the panel.
pub fn drawSpriteBubbles(self: *FileWidget) void {
    if (self.init_options.file.editor.transform != null) return;
    if (self.resize_data_point != null) return;

    const animation_id = self.init_options.file.editor.canvas.scroll_container.data().id;
    const cw = dvui.currentWindow();
    const drag_sprite_selection = dvui.dragName("sprite_selection_drag");
    const tool_not_pointer = fizzy.editor.tools.current != .pointer;
    const mod_shift = cw.modifiers.matchBind("shift");
    const mod_ctrl_cmd = cw.modifiers.matchBind("ctrl/cmd");
    const radial_visible = fizzy.editor.tools.radial_menu.visible;
    const sample_active = self.sample_data_point != null;

    { // Create animations for closing or opening bubbles
        const bubble_open_hdr = dvui.animationGet(animation_id, "bubble_open");
        const bubble_close_hdr = dvui.animationGet(animation_id, "bubble_close");

        if ((drag_sprite_selection or tool_not_pointer or mod_shift or mod_ctrl_cmd) or
            radial_visible or
            sample_active)
        {
            if (bubble_close_hdr) |anim| {
                if (anim.done()) {
                    self.hide_distance_bubble = true;
                }
            } else if (bubble_open_hdr != null) {
                _ = dvui.currentWindow().animations.remove(animation_id.update("bubble_open"));
                dvui.animation(animation_id, "bubble_close", .{
                    .easing = dvui.easing.outQuint,
                    .end_time = 200_000,
                    .start_val = 1.0,
                    .end_val = 0.0,
                });
            } else if (!self.hide_distance_bubble) {
                dvui.animation(animation_id, "bubble_close", .{
                    .easing = dvui.easing.outQuint,
                    .end_time = 200_000,
                    .start_val = 1.0,
                    .end_val = 0.0,
                });
            }
        } else {
            if (bubble_open_hdr) |anim| {
                if (anim.done()) {
                    self.hide_distance_bubble = false;
                }
            } else if (bubble_close_hdr != null) {
                _ = dvui.currentWindow().animations.remove(animation_id.update("bubble_close"));

                dvui.animation(animation_id, "bubble_open", .{
                    .easing = dvui.easing.outElastic,
                    .end_time = 900_000,
                    .start_val = 0.0,
                    .end_val = 1.0,
                });
            } else if (self.hide_distance_bubble) {
                dvui.animation(animation_id, "bubble_open", .{
                    .easing = dvui.easing.outElastic,
                    .end_time = 900_000,
                    .start_val = 0.0,
                    .end_val = 1.0,
                });
            }
        }
    }

    const bubble_open_draw = dvui.animationGet(animation_id, "bubble_open");
    const bubble_close_draw = dvui.animationGet(animation_id, "bubble_close");
    const selection_nonempty = self.init_options.file.editor.selected_sprites.count() > 0;
    const pan_shared: BubblePanShared = .{
        .bubble_open = bubble_open_draw,
        .bubble_close = bubble_close_draw,
        .peek = drag_sprite_selection or mod_shift or mod_ctrl_cmd or tool_not_pointer or sample_active,
        .selection_nonempty = selection_nonempty,
        .tool_not_pointer = tool_not_pointer,
    };

    const visible_data = self.init_options.file.editor.canvas.dataFromScreenRect(self.init_options.file.editor.canvas.rect);
    const file = self.init_options.file;
    const cols = file.columns;
    const total_rows = file.rows;
    if (total_rows == 0 or cols == 0) return;

    const row_h: f32 = @floatFromInt(file.row_height);
    const col_w: f32 = @floatFromInt(file.column_width);
    if (row_h <= 0 or col_w <= 0) return;
    const bubble_headroom = @max(row_h, col_w);

    // Determine the visible row range to skip entire offscreen rows.
    // Use explicit comparisons rather than clamp to be NaN-safe
    // (NaN comparisons are always false, so NaN falls through to 0).
    const max_row_f: f32 = @floatFromInt(total_rows);
    const first_vis_f = (visible_data.y - bubble_headroom) / row_h;
    const first_vis_row: usize = if (first_vis_f > 0 and first_vis_f < max_row_f)
        @intFromFloat(first_vis_f)
    else if (first_vis_f >= max_row_f)
        total_rows
    else
        0;
    const last_vis_f = (visible_data.y + visible_data.h) / row_h + 2.0;
    const last_vis_row: usize = if (last_vis_f > 0 and last_vis_f < max_row_f)
        @intFromFloat(last_vis_f)
    else if (last_vis_f >= max_row_f)
        total_rows
    else
        0;

    const checkerboard_tex = file.editor.checkerboard_tile.getTexture() catch null;
    var accs = BubbleAccs.init(dvui.currentWindow().arena());

    // Row-based iteration with batched geometry rendering.
    // Geometry is accumulated into TriAccs and rendered in bulk to minimize draw calls.
    //
    // `hovered_bubble_sprite_index` is set from geometry hit tests; it must reflect the
    // bubble button under the mouse across *all* visible rows before any row's UI runs.
    // Otherwise a vertical selection shows stale plus/minus hints on rows drawn earlier.
    self.hovered_bubble_sprite_index = null;

    const vx0 = visible_data.x;
    const vx1 = visible_data.x + visible_data.w;

    for (0..2) |pass_i| {
        var row: usize = first_vis_row;
        while (row < last_vis_row) : (row += 1) {
            const row_start = row * cols;
            const row_end = @min(row_start + cols, file.spriteCount());
            if (row_end <= row_start) continue;

            const row_span = row_end - row_start;
            const base_y = @as(f32, @floatFromInt(row)) * row_h;

            // Horizontal clip: only columns whose cells can intersect the visible rect in x.
            // Avoids spriteRect + cull for off-screen tiles (major win when zoomed / panned).
            var col_lo: usize = 0;
            if (vx0 > 0) col_lo = @intFromFloat(@floor(vx0 / col_w));
            if (vx1 <= 0) continue;
            var col_hi_excl: usize = @intFromFloat(@ceil(vx1 / col_w));
            col_lo = @min(col_lo, row_span);
            col_hi_excl = @min(col_hi_excl, row_span);
            if (col_lo >= col_hi_excl) continue;

            const si_start = row_start + col_lo;
            const si_end_excl = row_start + col_hi_excl;

            const first_sprite = dvui.Rect{
                .x = 0,
                .y = base_y,
                .w = col_w,
                .h = row_h,
            };
            const row_clip_screen = file.editor.canvas.screenFromDataRect(.{
                .x = first_sprite.x,
                .y = first_sprite.y - bubble_headroom,
                .w = col_w * @as(f32, @floatFromInt(cols)),
                .h = bubble_headroom,
            });

            if (pass_i == 0) {
                // Pass 0 — geometry: accumulate shadow + fill + tex + outline in one pass.
                {
                    var si: usize = si_end_excl;
                    while (si > si_start) {
                        si -= 1;
                        const col_in_row = si - row_start;
                        const sprite_rect = bubbleSpriteDataRect(col_in_row, base_y, col_w, row_h);
                        if (!spriteCullVisible(sprite_rect, bubble_headroom, visible_data)) continue;
                        drawSpriteBubbleForRow(self, file, si, sprite_rect, &accs, pan_shared);
                    }
                }

                // Render all accumulated geometry under the row clip
                {
                    const prev_clip = dvui.clip(row_clip_screen);
                    defer dvui.clipSet(prev_clip);
                    accs.shadow.render(null);
                    accs.fill.render(null);
                    accs.tex.render(checkerboard_tex);
                    accs.outline.render(null);
                }
                accs.clearAll();
            } else {
                // Pass 1 — UI: buttons, text, icons rendered per-sprite.
                {
                    var si: usize = si_end_excl;
                    while (si > si_start) {
                        si -= 1;
                        const col_in_row = si - row_start;
                        const sprite_rect = bubbleSpriteDataRect(col_in_row, base_y, col_w, row_h);
                        if (!spriteCullVisible(sprite_rect, bubble_headroom, visible_data)) continue;
                        drawSpriteBubbleForRow(self, file, si, sprite_rect, null, pan_shared);
                    }
                }
            }
        }
    }
}

fn spriteCullVisible(sprite_rect: dvui.Rect, headroom: f32, visible: dvui.Rect) bool {
    const cull = dvui.Rect{
        .x = sprite_rect.x,
        .y = sprite_rect.y - headroom,
        .w = sprite_rect.w,
        .h = sprite_rect.h + headroom,
    };
    return !cull.intersect(visible).empty();
}

/// Data-space rect for sprite `si` when `row_start == row * cols` (same as `file.spriteRect(si)`).
fn bubbleSpriteDataRect(col_in_row: usize, base_y: f32, col_w: f32, row_h: f32) dvui.Rect {
    return .{
        .x = @as(f32, @floatFromInt(col_in_row)) * col_w,
        .y = base_y,
        .w = col_w,
        .h = row_h,
    };
}

/// Per-sprite bubble logic extracted for use in the row-based loop.
/// Computes animation state and progress, then calls drawSpriteBubble.
/// When `accs` is non-null, geometry is accumulated instead of rendered.
/// When `accs` is null and `shadow_only` is false, only UI elements are drawn.
fn drawSpriteBubbleForRow(
    self: *FileWidget,
    file: *fizzy.Internal.File,
    sprite_index: usize,
    sprite_rect: dvui.Rect,
    accs: ?*BubbleAccs,
    pan: BubblePanShared,
) void {
    var color = dvui.themeGet().color(.window, .fill);

    var automatic_animation: bool = false;
    var automatic_animation_frame_i: usize = 0;

    var animation_index: ?usize = null;

    if (file.selected_animation_index) |selected_animation_index| {
        for (file.animations.items(.frames)[selected_animation_index], 0..) |frame, i| {
            if (frame.sprite_index == sprite_index) {
                automatic_animation_frame_i = i;
                animation_index = selected_animation_index;
                break;
            }
        }
    }

    if (animation_index == null) {
        anim_blk: for (file.animations.items(.frames), 0..) |frames, i| {
            for (frames, 0..) |frame, j| {
                if (frame.sprite_index == sprite_index) {
                    automatic_animation_frame_i = j;
                    animation_index = i;
                    break :anim_blk;
                }
            }
        }
    }

    if (animation_index) |ai| {
        const id = file.animations.get(ai).id;
        if (fizzy.editor.colors.file_tree_palette) |*palette| {
            color = palette.getDVUIColor(@intCast(id));
        }
        if (file.selected_animation_index == ai) {
            automatic_animation = true;
        }
    }

    if (pan.selection_nonempty) {
        if (file.editor.selected_sprites.isSet(sprite_index)) {
            automatic_animation = true;
            if (animation_index) |ai| {
                if (ai != file.selected_animation_index) {
                    color = dvui.themeGet().color(.control, .fill_hover);
                }
            }
        }
    }

    if (automatic_animation) {
        const total_duration: i32 = 1_500_000;
        const max_step_duration: i32 = @divTrunc(total_duration, 3);

        var duration_step = max_step_duration;

        if (animation_index) |ai| {
            duration_step = std.math.clamp(@divTrunc(total_duration, @as(i32, @intCast(file.animations.get(ai).frames.len))), 0, max_step_duration);
        }

        const duration = max_step_duration + (duration_step * @as(i32, @intCast(automatic_animation_frame_i + 1)));

        var open: bool = true;
        var id_extra: usize = sprite_index;

        if (animation_index) |ai| {
            id_extra = dvui.Id.extendId(@enumFromInt(sprite_index), @src(), ai).asUsize();
        }

        {
            const current_point = file.editor.canvas.dataFromScreenPoint(dvui.currentWindow().mouse_pt);

            const max_distance: f32 = @max(sprite_rect.h, sprite_rect.w) * 1.5;

            const dx = @abs(current_point.x - (sprite_rect.x + sprite_rect.w * 0.5));
            const dy = @abs(current_point.y - (sprite_rect.y) + sprite_rect.h * 0.5);
            const distance = @sqrt(dx * dx + dy * dy);

            if (distance < max_distance and pan.peek and current_point.y - sprite_rect.y < 0.0 and current_point.y - sprite_rect.y > -sprite_rect.h) {
                open = false;
                id_extra = dvui.Id.update(@enumFromInt(id_extra), "peek").asUsize();
            } else {
                id_extra = dvui.Id.update(@enumFromInt(id_extra), "unpeek").asUsize();
            }
        }

        if (accs != null) {
            id_extra = dvui.Id.update(@enumFromInt(id_extra), "geom").asUsize();
        } else {
            id_extra = dvui.Id.update(@enumFromInt(id_extra), "ui").asUsize();
        }

        var t: f32 = 0.0;

        const anim = dvui.animate(@src(), .{
            .duration = if (open) duration else @divTrunc(duration, 4),
            .kind = .vertical,
            .easing = if (open) dvui.easing.outElastic else dvui.easing.outQuint,
        }, .{
            .id_extra = id_extra,
        });
        defer anim.deinit();

        t = if (open) anim.val orelse 1.0 else std.math.clamp(1.0 - (anim.val orelse 1.0), 0.0, 2.0);

        if (drawSpriteBubble(self, sprite_index, sprite_rect, t, color, animation_index, accs, pan.bubble_open, pan.bubble_close, pan.tool_not_pointer)) {
            self.hovered_bubble_sprite_index = sprite_index;
        }
    } else {
        if (pan.selection_nonempty) {
            if (!file.editor.selected_sprites.isSet(sprite_index) or (animation_index != file.selected_animation_index and !file.editor.selected_sprites.isSet(sprite_index))) {
                return;
            }
        }

        const current_point = file.editor.canvas.dataFromScreenPoint(dvui.currentWindow().mouse_pt);

        var max_distance: f32 = sprite_rect.h * 1.2;

        if (pan.bubble_open) |anim| {
            max_distance += (max_distance * 0.5) * (1.0 - anim.value());
        } else if (pan.bubble_close) |anim| {
            max_distance += (max_distance * 0.5) * (1.0 - anim.value());
        } else {
            max_distance += (max_distance * 0.5) * if (!self.hide_distance_bubble) @as(f32, 0.0) else @as(f32, 1.0);
        }

        const dx = @abs(current_point.x - (sprite_rect.x + sprite_rect.w * 0.5));
        const dy = @abs(current_point.y - (sprite_rect.y - sprite_rect.h * 0.25));
        const distance = @sqrt((dx * dx) * 0.5 + (dy * dy) * 2.0);

        if (distance < (max_distance * 2.0)) {
            var t: f32 = distance / max_distance;

            if (pan.bubble_open) |anim| {
                t = (1.0 - t) * anim.value();
            } else if (pan.bubble_close) |anim| {
                t = (1.0 - t) * anim.value();
            } else {
                t = (1.0 - t) * if (self.hide_distance_bubble) @as(f32, 0.0) else @as(f32, 1.0);
            }

            t = std.math.clamp(t, 0.0, 2.0);

            if (drawSpriteBubble(
                self,
                sprite_index,
                sprite_rect,
                t,
                dvui.themeGet().color(.window, .fill).lerp(color, 1.0 - (distance / (max_distance * 2.0))),
                animation_index,
                accs,
                pan.bubble_open,
                pan.bubble_close,
                pan.tool_not_pointer,
            )) {
                self.hovered_bubble_sprite_index = sprite_index;
            }
        }
    }
}

/// Draw a single sprite bubble based on sprite index and progress. Animation index just lets us know if not null, its part of an animation,
/// and if its equal to the currently selected animation index, we need to draw a checkmark in the bubble because its part of the currently selected animation.
/// When `accs` is non-null, triangle geometry is accumulated into the
/// accumulators instead of being rendered immediately. Pass null for the
/// UI-only phase so that only buttons/text/icons are drawn.
pub fn drawSpriteBubble(
    self: *FileWidget,
    sprite_index: usize,
    sprite_rect: dvui.Rect,
    progress: f32,
    color: dvui.Color,
    animation_index: ?usize,
    accs: ?*BubbleAccs,
    bubble_open: ?dvui.Animation,
    bubble_close: ?dvui.Animation,
    tool_not_pointer: bool,
) bool {

    // Would this sprite be removed if the user clicked the button?
    var remove: bool = false;
    if (self.init_options.file.selected_animation_index) |anim_index| {
        const anim = self.init_options.file.animations.get(anim_index);
        for (anim.frames) |frame| {
            if (frame.sprite_index == sprite_index) {
                remove = true;
            }
        }
    }

    //if (sprite_index != 0) return;
    const t = progress;

    const cell_tint = checkerboardTintAtSpriteCellCenter(self.init_options.file, sprite_index);

    const target_button_height: f32 = 24.0;
    // Figure out artwork's baseline size (width or height, whichever is smaller)
    const baseline_sprite_size: f32 = 64.0;
    const min_sprite_size: f32 = @min(sprite_rect.w, sprite_rect.h);
    const baseline_scale: f32 = baseline_sprite_size / min_sprite_size;
    // Compensate the button size so that it stays visually consistent even if the tile is smaller/larger than 64x64
    var button_height = std.math.clamp((target_button_height * dvui.easing.outBack(t) / self.init_options.file.editor.canvas.scale), 0.0, min_sprite_size / 3.0);

    const sprite_rect_scale: dvui.RectScale = .{
        .r = self.init_options.file.editor.canvas.screenFromDataRect(sprite_rect),
        .s = self.init_options.file.editor.canvas.scale,
    };

    var bubble_max_height: f32 = @min(sprite_rect.h, sprite_rect.w) * 0.5;

    if (self.init_options.file.selected_animation_index) |ai| {
        if (self.init_options.file.selected_animation_frame_index < self.init_options.file.animations.get(ai).frames.len) {
            const animation = self.init_options.file.animations.get(ai);
            if (animation.frames.len > 0) {
                const frame = animation.frames[self.init_options.file.selected_animation_frame_index];
                if (frame.sprite_index != sprite_index and animation_index == ai) {
                    bubble_max_height = @min(sprite_rect.h, sprite_rect.w) * 0.3333;
                }
            }
        }
    }

    const bubble_height = std.math.clamp((bubble_max_height * t / self.init_options.file.editor.canvas.scale) * baseline_scale, 0.0, bubble_max_height * t);
    const bubble_rect = dvui.Rect{
        .x = sprite_rect.x,
        .y = sprite_rect.y - bubble_height,
        .w = sprite_rect.w,
        .h = bubble_height,
    };

    var bubble_rect_scale: dvui.RectScale = .{
        .r = self.init_options.file.editor.canvas.screenFromDataRect(bubble_rect),
        .s = self.init_options.file.editor.canvas.scale,
    };

    var path = dvui.Path.Builder.init(dvui.currentWindow().lifo());

    const center = bubble_rect.center();

    // Choose a font size that fits scaled to button size.
    const font = dvui.Font.theme(.body);

    const sprite_label = self.init_options.file.fmtSprite(dvui.currentWindow().arena(), sprite_index, .grid) catch {
        dvui.log.err("Failed to format sprite index", .{});
        return false;
    };

    const text_size = font.textSize(sprite_label);

    var button_width = @max(button_height, (text_size.w + 4.0) / self.init_options.file.editor.canvas.scale);

    if (bubble_close) |anim| {
        button_height *= anim.value();
        button_width *= anim.value();
    } else if (bubble_open) |anim| {
        button_height *= anim.value();
        button_width *= anim.value();
    } else if (tool_not_pointer or self.hide_distance_bubble) {
        button_height = 0.0;
        button_width = 0.0;
    }

    const button_rect = dvui.Rect{ .x = center.x - button_width / 2, .y = center.y - (button_height / 2), .w = button_width, .h = button_height };

    if (bubble_rect_scale.r.h <= dvui.currentWindow().natural_scale) {
        if (accs) |a| {
            path.addPoint(bubble_rect_scale.r.topRight());
            path.addPoint(bubble_rect_scale.r.topLeft());
            const tris = path.build().strokeTriangles(dvui.currentWindow().arena(), .{ .thickness = 1, .color = color }) catch return false;
            a.shadow.append(tris);
        }
        return false;
    } else {
        const ns = dvui.currentWindow().natural_scale;
        // Upper bound can drop below `ns` when the sprite is only a few physical pixels (zoomed far out);
        // `std.math.clamp` panics if min > max.
        const sprite_screen_min = @min(sprite_rect_scale.r.h, sprite_rect_scale.r.w);
        const arc_upper = sprite_screen_min * 0.5 - ns;
        const arc_height = std.math.clamp(bubble_rect_scale.r.h, ns, @max(ns, arc_upper));

        const d = bubble_rect_scale.r.w / 2;

        const radius: f32 = (d * d + arc_height * arc_height) / (2 * arc_height);

        const center_x: f32 = sprite_rect_scale.r.x + (sprite_rect_scale.r.w / 2);

        const arc_center: dvui.Point.Physical = .{ .x = center_x, .y = sprite_rect_scale.r.y + radius - arc_height };

        const end_angle: f32 = std.math.atan2(arc_center.y - sprite_rect_scale.r.topLeft().y, arc_center.x - sprite_rect_scale.r.topLeft().x);
        const start_angle: f32 = std.math.atan2(arc_center.y - sprite_rect_scale.r.topRight().y, arc_center.x - sprite_rect_scale.r.topRight().x);

        path.addArc(arc_center, radius, dvui.math.pi + start_angle, dvui.math.pi + end_angle, false);

        const built = path.build();
        defer path.deinit();

        // Geometry phase: accumulate shadow + fill + outline into accumulators.
        if (accs) |a| {
            const shadow_fade = arc_height * 0.66 * dvui.easing.outExpo(t);
            const shadow_color = dvui.Color.black.opacity(0.25);
            var shadow_path = dvui.Path.Builder.init(dvui.currentWindow().arena());
            shadow_path.addArc(arc_center, radius, dvui.math.pi + start_angle, dvui.math.pi + end_angle, false);
            const shadow_tris = shadow_path.build().fillConvexTriangles(dvui.currentWindow().arena(), .{ .color = shadow_color, .fade = shadow_fade }) catch return false;
            a.shadow.append(shadow_tris);

            if (self.init_options.file.editor.canvas.scale < 0.1) {
                const fill_tris = built.fillConvexTriangles(dvui.currentWindow().arena(), .{ .color = cell_tint, .fade = 0.0 }) catch return false;
                a.fill.append(fill_tris);
            } else {
                const fill_tris = built.fillConvexTriangles(dvui.currentWindow().arena(), .{ .color = cell_tint, .fade = 1.0 }) catch return false;
                a.fill.append(fill_tris);
                var tex_tris = built.fillConvexTriangles(dvui.currentWindow().arena(), .{ .color = cell_tint, .fade = 0.0 }) catch return false;
                const h_ratio = arc_height / sprite_rect_scale.r.h;
                tex_tris.uvFromRectuv(bubble_rect_scale.r, .{ .x = 0.0, .w = 1.0, .y = 1.0 - h_ratio, .h = h_ratio });
                a.tex.append(tex_tris);
            }
            const outline_tris = built.strokeTriangles(dvui.currentWindow().arena(), .{ .color = color, .thickness = dvui.currentWindow().natural_scale }) catch return false;
            a.outline.append(outline_tris);

            const mouse_data_pt = self.init_options.file.editor.canvas.dataFromScreenPoint(dvui.currentWindow().mouse_pt);
            return button_rect.contains(mouse_data_pt);
        }

        // UI-only phase: geometry was already batched, draw interactive content only.
        // Dont draw any buttons if the button is too small or too large.
        if (button_rect.w > bubble_rect.w * 0.666 or button_rect.w < bubble_rect.w * 0.001) return false;

        var add_rem_message: ?[]const u8 = null;

        var border_color = dvui.themeGet().color(.control, .fill_hover);
        if (fizzy.editor.colors.file_tree_palette) |*palette| {
            if (self.init_options.file.selected_animation_index) |index| {
                border_color = palette.getDVUIColor(@intCast(self.init_options.file.animations.get(index).id));
                add_rem_message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s}", .{self.init_options.file.animations.get(index).name}) catch {
                    dvui.log.err("Failed to allocate add/remove message", .{});
                    return false;
                };
            } else {
                add_rem_message = std.fmt.allocPrint(dvui.currentWindow().arena(), "New Animation", .{}) catch {
                    dvui.log.err("Failed to allocate add/remove message", .{});
                    return false;
                };
            }
        }

        var show_hint: bool = false;
        if (self.hovered_bubble_sprite_index) |hovered_button_index| {
            var iter = self.init_options.file.editor.selected_sprites.iterator(.{ .kind = .set, .direction = .forward });
            while (iter.next()) |selected_index| {
                if (selected_index == sprite_index) {
                    show_hint = true;
                }
            }

            if (self.init_options.file.selected_animation_index) |selected_animation_index| {
                const selected_animation = self.init_options.file.animations.get(selected_animation_index);
                if (selected_animation.frames.len > 0) {
                    var hovered_in_animation: bool = false;
                    for (selected_animation.frames) |frame| {
                        if (frame.sprite_index == hovered_button_index) {
                            hovered_in_animation = true;
                            break;
                        }
                    }

                    var current_in_animation: bool = false;
                    for (selected_animation.frames) |frame| {
                        if (frame.sprite_index == sprite_index) {
                            current_in_animation = true;
                            break;
                        }
                    }

                    if (hovered_in_animation != current_in_animation) {
                        show_hint = false;
                    }
                }
            }

            var found_current_in_selection: bool = false;

            iter = self.init_options.file.editor.selected_sprites.iterator(.{ .kind = .set, .direction = .forward });
            while (iter.next()) |selected_index| {
                if (selected_index == hovered_button_index) {
                    found_current_in_selection = true;
                }
            }

            if (!found_current_in_selection)
                show_hint = false;
        }

        var button: dvui.ButtonWidget = undefined;
        button.init(@src(), .{
            .draw_focus = false,
        }, .{
            .rect = button_rect,
            .margin = .all(0),
            .padding = .all(0),
            .id_extra = sprite_index,
            .color_fill = dvui.themeGet().color(.control, .fill).lighten(if (dvui.themeGet().dark) 10.0 else -10.0),
            //.color_border = dvui.themeGet().color(.control, .fill),
            //.border = dvui.Rect.all(1).scale(1.0 / self.init_options.file.editor.canvas.scale, dvui.Rect),
            .box_shadow = .{
                .color = .black,
                .offset = .{ .x = -0.05 * button_height, .y = 0.08 * button_height },
                .fade = (button_height / 10) * t,
                .alpha = 0.5 * t,
            },
            .corner_radius = dvui.Rect.all(1000000),
            .gravity_x = 0.5,
            .gravity_y = 0.5,
        });
        defer button.deinit();

        button.processEvents();

        if (button.hovered() or show_hint) {
            if (remove) {
                button.data().options.color_border = dvui.themeGet().color(.err, .fill).opacity(0.75);
            } else {
                button.data().options.color_border = dvui.themeGet().color(.highlight, .fill).opacity(0.75);
            }
        }

        button.drawBackground();

        if (button.clicked()) { // Toggle animation frame on or off for this selection/animation
            if (self.init_options.file.selected_animation_index) |anim_index| {
                // TODO: Efficiently resize the animation frames array instead of duplicating it

                var anim = self.init_options.file.animations.get(anim_index);

                var frames = std.array_list.Managed(fizzy.Animation.Frame).init(fizzy.app.allocator);
                frames.appendSlice(anim.frames) catch {
                    dvui.log.err("Failed to append frames", .{});
                    return false;
                };

                for (frames.items, 0..) |frame, i| {
                    if (frame.sprite_index == sprite_index) {

                        // First remove the currently clicked frame, regardless
                        _ = frames.orderedRemove(i);
                    }
                }

                if (self.init_options.file.editor.selected_sprites.count() > 0) {
                    var in_selection: bool = false;
                    var iter = self.init_options.file.editor.selected_sprites.iterator(.{ .kind = .set, .direction = .forward });
                    while (iter.next()) |selected_index| {
                        if (selected_index == sprite_index) {
                            in_selection = true;
                            break;
                        }
                    }

                    if (in_selection) {
                        // Remove all selected_sprite_index values from frames, regardless of their position.
                        // To avoid skipping items due to shifting, iterate backward through frames.
                        iter = self.init_options.file.editor.selected_sprites.iterator(.{ .kind = .set, .direction = .forward });
                        while (iter.next()) |selected_sprite_index| {
                            var j: usize = frames.items.len;
                            while (j > 0) : (j -= 1) {
                                if (frames.items[j - 1].sprite_index == selected_sprite_index) {
                                    _ = frames.orderedRemove(j - 1);
                                }
                            }
                        }
                    }
                }

                if (!remove) {
                    if (self.init_options.file.editor.selected_sprites.count() > 0) {
                        var in_selection: bool = false;

                        var iter = self.init_options.file.editor.selected_sprites.iterator(.{ .kind = .set, .direction = .forward });
                        while (iter.next()) |selected_index| {
                            if (selected_index == sprite_index) {
                                in_selection = true;
                                break;
                            }
                        }

                        if (in_selection) {
                            iter = self.init_options.file.editor.selected_sprites.iterator(.{ .kind = .set, .direction = .forward });
                            while (iter.next()) |selected_index| {
                                frames.append(.{ .sprite_index = selected_index, .ms = temp_ms }) catch {
                                    dvui.log.err("Failed to append frame", .{});
                                    return false;
                                };
                            }
                        } else {
                            frames.append(.{ .sprite_index = sprite_index, .ms = temp_ms }) catch {
                                dvui.log.err("Failed to append frame", .{});
                                return false;
                            };
                        }
                    } else {
                        frames.append(.{ .sprite_index = sprite_index, .ms = temp_ms }) catch {
                            dvui.log.err("Failed to append frame", .{});
                            return false;
                        };
                    }
                }

                if (!anim.eqlFrames(frames.items)) {
                    self.init_options.file.history.append(.{
                        .animation_frames = .{
                            .index = anim_index,
                            .frames = fizzy.app.allocator.dupe(fizzy.Animation.Frame, anim.frames) catch {
                                dvui.log.err("Failed to dupe frames", .{});
                                return false;
                            },
                        },
                    }) catch {
                        dvui.log.err("Failed to append history", .{});
                    };

                    fizzy.app.allocator.free(anim.frames);
                    anim.frames = frames.toOwnedSlice() catch {
                        dvui.log.err("Failed to free frames", .{});
                        return false;
                    };

                    self.init_options.file.animations.set(anim_index, anim);
                }
            } else {
                if (self.init_options.file.createAnimation() catch null) |anim_index| {
                    self.init_options.file.selected_animation_index = anim_index;
                    self.init_options.file.collapseAnimationSelectionToPrimary();
                    self.init_options.file.editor.animations_scroll_to_index = anim_index;
                    fizzy.editor.explorer.sprites.edit_anim_id = self.init_options.file.animations.items(.id)[anim_index];
                    fizzy.editor.explorer.pane = .sprites;

                    var anim = self.init_options.file.animations.get(anim_index);
                    if (anim.frames.len == 0) {
                        anim.appendFrame(fizzy.app.allocator, .{ .sprite_index = sprite_index, .ms = temp_ms }) catch {
                            dvui.log.err("Failed to append frame", .{});
                            return false;
                        };
                    }
                    self.init_options.file.animations.set(anim_index, anim);

                    self.init_options.file.history.append(.{
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

        if (button.data().contentRectScale().r.w > text_size.w) {
            // Determine the rect to draw in
            const btn_rect = button.data().contentRectScale().r;

            const scaled_text_size = text_size.scale(dvui.currentWindow().natural_scale, dvui.Size.Physical);

            const text_rect = dvui.Rect.Physical{
                .x = btn_rect.x + (btn_rect.w - scaled_text_size.w) / 2,
                .y = btn_rect.y + (btn_rect.h - scaled_text_size.h) / 2,
                .w = scaled_text_size.w,
                .h = scaled_text_size.h,
            };

            const color_main = if (button.hovered() or animation_index == self.init_options.file.selected_animation_index) dvui.themeGet().color(.window, .text) else dvui.themeGet().color(.control, .text);

            dvui.renderText(.{
                .text = sprite_label,
                .font = font,
                .color = color_main.opacity(progress),
                .rs = .{ .r = text_rect, .s = dvui.currentWindow().natural_scale },
            }) catch {
                dvui.log.err("Failed to render text", .{});
                return false;
            };

            var icon_rect = button.data().rectScale().r;
            icon_rect.x += icon_rect.w;
            icon_rect.w = icon_rect.w / 2.0;
            icon_rect.h = icon_rect.h / 2.0;
            icon_rect.x = icon_rect.x - icon_rect.w / 1.5;
            icon_rect.y = icon_rect.y - icon_rect.h / 3;

            var fill_rect = icon_rect;
            fill_rect.x += icon_rect.w + (2.0 * dvui.currentWindow().natural_scale);

            // Center fill_rect over the button rect if there is more than one selected sprite.
            if (self.init_options.file.editor.selected_sprites.count() > 1) {
                // Center fill_rect horizontally and vertically over button rect
                fill_rect.x = button.data().rectScale().r.x + (button.data().rectScale().r.w - fill_rect.w) / 2.0;

                fill_rect.y -= fill_rect.h + fill_rect.h / 3;
            }

            if (button.hovered() or show_hint) {
                var icon_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .none,
                    .rect = button.data().rectScale().rectFromPhysical(icon_rect),
                    .border = dvui.Rect.all(0),
                    .background = true,
                    .corner_radius = dvui.Rect.all(1000000),
                    .box_shadow = .{
                        .color = .black,
                        .offset = .{ .x = -0.05 * button_height, .y = 0.08 * button_height },
                        .fade = (button_height / 10) * t,
                        .alpha = 0.35 * t,
                    },
                    .color_fill = if (remove) dvui.themeGet().color(.err, .fill).opacity(0.75) else dvui.themeGet().color(.highlight, .fill).opacity(0.75),
                });

                dvui.renderIcon("close", if (remove) icons.tvg.lucide.minus else icons.tvg.lucide.plus, .{ .r = icon_box.data().rectScale().r, .s = dvui.currentWindow().natural_scale }, .{}, .{}) catch {
                    dvui.log.err("Failed to render icon", .{});
                    return false;
                };
                icon_box.deinit();

                var message_size: dvui.Size = .{};

                if (add_rem_message) |message| {
                    message_size.w = font.textSize(message).w * dvui.currentWindow().natural_scale;
                    message_size.h = font.textSize(message).h * dvui.currentWindow().natural_scale + 2.0 * dvui.currentWindow().natural_scale;

                    fill_rect.w += message_size.w * 1.5;
                    fill_rect.h = @max(fill_rect.h, message_size.h);
                }
                if (button.hovered()) {
                    if (add_rem_message) |message| {
                        const fill_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                            .expand = .none,
                            .rect = button.data().rectScale().rectFromPhysical(fill_rect),
                            .border = dvui.Rect.all(0),
                            .background = true,
                            .corner_radius = dvui.Rect.all(1000000),
                            .box_shadow = .{
                                .color = .black,
                                .offset = .{ .x = -0.05 * button_height, .y = 0.08 * button_height },
                                .fade = (button_height / 10) * t,
                                .alpha = 0.35 * t,
                            },
                            .color_fill = if (remove) dvui.themeGet().color(.err, .fill).opacity(0.75) else dvui.themeGet().color(.highlight, .fill).opacity(0.75),
                        });
                        defer fill_box.deinit();

                        var text_box = fill_box.data().contentRectScale().r;
                        text_box.x += (text_box.w - (message_size.w)) / 2.0;
                        text_box.y += (text_box.h - (message_size.h)) / 2.0;

                        dvui.renderText(.{
                            .text = message,
                            .font = font,
                            .color = .white,
                            .rs = .{ .r = text_box, .s = dvui.currentWindow().natural_scale },
                        }) catch {
                            dvui.log.err("Failed to render text", .{});
                        };
                    }
                }
            }
        }
    }

    return false;
}

/// Draw the highlight colored selection box for each selected sprite.
pub fn drawSpriteSelection(self: *FileWidget) void {
    if (fizzy.editor.tools.current != .pointer) return;
    if (self.init_options.file.editor.transform != null) return;
    if (self.sample_data_point != null) return;

    if (self.drag_data_point) |previous_point| {
        const current_point = self.init_options.file.editor.canvas.dataFromScreenPoint(dvui.currentWindow().mouse_pt);
        const min_x = @min(previous_point.x, current_point.x);
        const min_y = @min(previous_point.y, current_point.y);
        const max_x = @max(previous_point.x, current_point.x);
        const max_y = @max(previous_point.y, current_point.y);
        const span_rect = dvui.Rect{
            .x = min_x,
            .y = min_y,
            .w = max_x - min_x,
            .h = max_y - min_y,
        };

        const screen_selection_rect = self.init_options.file.editor.canvas.screenFromDataRect(span_rect);
        const selection_color = if (dvui.currentWindow().modifiers.matchBind("shift")) dvui.themeGet().color(.err, .fill).opacity(0.5) else dvui.themeGet().color(.highlight, .fill).opacity(0.5);
        screen_selection_rect.fill(
            dvui.Rect.Physical.all(6 * dvui.currentWindow().natural_scale),
            .{
                .color = selection_color,
            },
        );
    }
}

/// Arc-length point along a piecewise-linear polyline (`cum` = cumulative segment lengths).
fn marqueePointAtArcLength(
    points: []const dvui.Point.Physical,
    cum: []const f32,
    s: f32,
) dvui.Point.Physical {
    const n = points.len;
    std.debug.assert(n == cum.len);
    if (n == 0) return .{ .x = 0, .y = 0 };
    if (n == 1) return points[0];

    const total = cum[n - 1];
    const clamped = std.math.clamp(s, cum[0], total);

    var i: usize = 0;
    while (i + 1 < n and cum[i + 1] < clamped) {
        i += 1;
    }
    const seg_len = cum[i + 1] - cum[i];
    if (seg_len < 1e-5) {
        return points[i + 1];
    }
    const t = (clamped - cum[i]) / seg_len;
    return .{
        .x = points[i].x + (points[i + 1].x - points[i].x) * t,
        .y = points[i].y + (points[i + 1].y - points[i].y) * t,
    };
}

fn marqueeAppendSpan(
    points: []const dvui.Point.Physical,
    cum: []const f32,
    s0: f32,
    s1: f32,
    out: *std.array_list.Managed(dvui.Point.Physical),
) !void {
    out.clearRetainingCapacity();
    const eps = 1e-4;
    if (s1 <= s0 + eps) return;

    try out.append(marqueePointAtArcLength(points, cum, s0));

    const n = points.len;
    var k: usize = 1;
    while (k < n) : (k += 1) {
        const d = cum[k];
        if (d <= s0 + eps) continue;
        if (d >= s1 - eps) break;
        try out.append(points[k]);
    }

    const end_pt = marqueePointAtArcLength(points, cum, s1);
    const last = out.items[out.items.len - 1];
    const dx = end_pt.x - last.x;
    const dy = end_pt.y - last.y;
    if (dx * dx + dy * dy > 1e-8) {
        try out.append(end_pt);
    }
}

/// Dashed stroke along a polyline (same approach as graphl `previewStrokePolylineDashed`).
fn strokePolylineDashedPhysical(
    points: []const dvui.Point.Physical,
    dash_len: f32,
    gap_len: f32,
    stroke: dvui.Path.StrokeOptions,
) void {
    const n = points.len;
    if (n < 2) return;
    if (dash_len <= 0.0) return;
    const gap = @max(0.0, gap_len);
    const pattern = dash_len + gap;
    if (pattern < 1e-5) return;

    const arena = dvui.currentWindow().arena();
    const cum = arena.alloc(f32, n) catch return;
    cum[0] = 0;
    var i: usize = 1;
    while (i < n) : (i += 1) {
        cum[i] = cum[i - 1] + dvui.Point.Physical.diff(points[i], points[i - 1]).length();
    }

    const total = cum[n - 1];
    if (total < 1e-4) return;

    var buf = std.array_list.Managed(dvui.Point.Physical).init(arena);
    defer buf.deinit();

    const edge_eps = 1e-5;
    var s: f32 = 0;
    while (s < total - edge_eps) {
        const dash_end = @min(s + dash_len, total);
        if (dash_end <= s + edge_eps) break;
        marqueeAppendSpan(points, cum, s, dash_end, &buf) catch return;
        if (buf.items.len != 0) {
            dvui.Path.stroke(.{ .points = buf.items }, stroke);
        }
        s = dash_end + gap;
    }
}

fn drawBoxSelectionMarqueeOutline(self: *FileWidget) void {
    if (fizzy.editor.tools.current != .selection) return;
    if (fizzy.editor.tools.selection_mode != .box) return;
    const start = self.drag_data_point orelse return;
    if (dvui.dragging(dvui.currentWindow().mouse_pt, "stroke_drag") == null) return;

    const file = self.init_options.file;
    const canvas = &file.editor.canvas;
    const current = canvas.dataFromScreenPoint(dvui.currentWindow().mouse_pt);

    const min_x = @min(start.x, current.x);
    const min_y = @min(start.y, current.y);
    const max_x = @max(start.x, current.x);
    const max_y = @max(start.y, current.y);
    if (@abs(max_x - min_x) < 1e-4 and @abs(max_y - min_y) < 1e-4) return;

    const tl = canvas.screenFromDataPoint(.{ .x = min_x, .y = min_y });
    const tr = canvas.screenFromDataPoint(.{ .x = max_x, .y = min_y });
    const br = canvas.screenFromDataPoint(.{ .x = max_x, .y = max_y });
    const bl = canvas.screenFromDataPoint(.{ .x = min_x, .y = max_y });

    const arena = dvui.currentWindow().arena();
    const loop_buf = arena.alloc(dvui.Point.Physical, 5) catch return;
    loop_buf[0] = tl;
    loop_buf[1] = tr;
    loop_buf[2] = br;
    loop_buf[3] = bl;
    loop_buf[4] = tl;

    const rs = canvas.scroll_container.data().rectScale();
    const stroke_w = @max(1.0, 1.0 * rs.s);

    const outline_color = dvui.themeGet().color(.window, .text);

    const dash_px: f32 = 14.0;
    const gap_px: f32 = 8.75;

    strokePolylineDashedPhysical(loop_buf, dash_px, gap_px, .{
        .thickness = stroke_w,
        .color = outline_color,
        .endcap_style = .none,
        .after = true,
    });
}

/// Preview for rectangular selection while dragging (box mode).
fn applySelectionBoxPreview(
    file: *fizzy.Internal.File,
    active_layer: *const fizzy.Internal.Layer,
    start: dvui.Point,
    end: dvui.Point,
    mod: dvui.enums.Mod,
) void {
    const read_layer = file.layers.get(file.selected_layer_index);
    file.editor.temporary_layer.clearMask();
    file.editor.temporary_layer.mask.setUnion(file.editor.selection_layer.mask);
    file.editor.temporary_layer.mask.setIntersection(active_layer.mask);

    const x0: i32 = @intFromFloat(@floor(@min(start.x, end.x)));
    const y0: i32 = @intFromFloat(@floor(@min(start.y, end.y)));
    const x1: i32 = @intFromFloat(@floor(@max(start.x, end.x)));
    const y1: i32 = @intFromFloat(@floor(@max(start.y, end.y)));

    const iw: i32 = @intCast(file.width());
    const ih: i32 = @intCast(file.height());

    const sub = mod.matchBind("shift");

    var py = y0;
    while (py <= y1) : (py += 1) {
        if (py < 0 or py >= ih) continue;
        var px = x0;
        while (px <= x1) : (px += 1) {
            if (px < 0 or px >= iw) continue;
            const pt: dvui.Point = .{ .x = @floatFromInt(px), .y = @floatFromInt(py) };
            if (file.editor.temporary_layer.pixelIndex(pt)) |idx| {
                if (read_layer.pixels()[idx][3] == 0) continue;
                if (sub) {
                    file.editor.temporary_layer.mask.setValue(idx, false);
                } else {
                    file.editor.temporary_layer.mask.setValue(idx, true);
                }
            }
        }
    }
}

/// Responsible for processing events to create/modify the current fine-grained selection.
/// This selection is pixel-based, and includes shift/ctrl/cmd modifiers to support add/remove.
/// The selection uses the same logic as the stroke tool to brush the selection over existing pixels.
pub fn processSelection(self: *FileWidget) void {
    if (switch (fizzy.editor.tools.current) {
        .selection,
        => false,
        else => true,
    }) return;

    if (self.sample_key_down or self.right_mouse_down) return;

    const file = self.init_options.file;
    const widget_active = self.active();
    const active_layer = &file.layers.get(file.selected_layer_index);

    const selection_alpha: u8 = 185;
    const selection_color_primary: dvui.Color = .{ .r = 200, .g = 200, .b = 200, .a = selection_alpha };
    const selection_color_secondary: dvui.Color = .{ .r = 50, .g = 50, .b = 50, .a = selection_alpha };

    const selection_alpha_stroke: u8 = 225;
    var selection_color_primary_stroke: dvui.Color = .{ .r = 255, .g = 255, .b = 255, .a = selection_alpha_stroke };
    var selection_color_secondary_stroke: dvui.Color = .{ .r = 200, .g = 200, .b = 200, .a = selection_alpha_stroke };

    // Pixel mode: draw the committed selection before handling events (brush preview layers on top).
    // Box mode: skip — the mask is updated on mouse release in the same frame as this paint; drawing
    // here would use stale data until the next frame. Box repaints from the current mask after events.
    if (fizzy.editor.tools.selection_mode == .pixel or fizzy.editor.tools.selection_mode == .color) {
        @memset(file.editor.temporary_layer.pixels(), .{ 0, 0, 0, 0 });
        file.editor.temporary_layer.clearMask();

        file.editor.temporary_layer.mask.setUnion(file.editor.selection_layer.mask);
        file.editor.temporary_layer.mask.setIntersection(active_layer.mask);

        file.editor.temporary_layer.setColorFromMask(selection_color_primary);
        file.editor.temporary_layer.mask.setIntersection(file.editor.checkerboard);
        file.editor.temporary_layer.setColorFromMask(selection_color_secondary);
    }

    for (dvui.events()) |*e| {
        if (!self.init_options.file.editor.canvas.scroll_container.matchEvent(e)) {
            continue;
        }

        switch (e.evt) {
            .key => |ke| {
                var update: bool = false;
                if (fizzy.editor.tools.selection_mode == .pixel) {
                    if (ke.matchBind("increase_stroke_size") and (ke.action == .down or ke.action == .repeat)) {
                        if (fizzy.editor.tools.stroke_size < fizzy.Editor.Tools.max_brush_size - 1)
                            fizzy.editor.tools.stroke_size += 1;

                        fizzy.editor.tools.setStrokeSize(fizzy.editor.tools.stroke_size);
                        e.handle(@src(), self.init_options.file.editor.canvas.scroll_container.data());
                        update = true;
                    }

                    if (ke.matchBind("decrease_stroke_size") and (ke.action == .down or ke.action == .repeat)) {
                        if (fizzy.editor.tools.stroke_size > 1)
                            fizzy.editor.tools.stroke_size -= 1;

                        fizzy.editor.tools.setStrokeSize(fizzy.editor.tools.stroke_size);
                        e.handle(@src(), self.init_options.file.editor.canvas.scroll_container.data());
                        update = true;
                    }
                }

                if (update) {
                    const current_point = self.init_options.file.editor.canvas.dataFromScreenPoint(dvui.currentWindow().mouse_pt);
                    {

                        // Clear temporary layer pixels and mask
                        @memset(file.editor.temporary_layer.pixels(), .{ 0, 0, 0, 0 });
                        file.editor.temporary_layer.clearMask();

                        // Set the temporary layer mask to the selection layer mask
                        file.editor.temporary_layer.mask.setUnion(file.editor.selection_layer.mask);

                        // Draw the point at the stroke size to the temporary layer mask only
                        file.drawPoint(
                            current_point,
                            .temporary,
                            .{
                                .mask_only = true,
                                .stroke_size = fizzy.editor.tools.stroke_size,
                            },
                        );

                        // Intersect with the active layer mask so the stroke is confined to only non-transparent pixels
                        file.editor.temporary_layer.mask.setIntersection(active_layer.mask);
                        file.editor.temporary_layer.setColorFromMask(selection_color_primary);

                        // Intersect with the checkerboard mask so we can show the pattern
                        file.editor.temporary_layer.mask.setIntersection(file.editor.checkerboard);
                        file.editor.temporary_layer.setColorFromMask(selection_color_secondary);
                    }
                }
            },
            .mouse => |me| {
                const current_point = self.init_options.file.editor.canvas.dataFromScreenPoint(me.p);

                if (me.action == .position) {
                    const box_mode = fizzy.editor.tools.selection_mode == .box;
                    const color_mode = fizzy.editor.tools.selection_mode == .color;
                    const is_drag = dvui.dragging(me.p, "stroke_drag") != null;
                    const box_drag = box_mode and is_drag and self.drag_data_point != null;

                    if ((box_mode and !box_drag) or color_mode) {
                        // Box: committed selection is painted after events. Color: no brush preview.
                    } else {
                        // Clear the mask, we now need to only draw the point at the stroke size to the mask
                        file.editor.temporary_layer.clearMask();

                        if (box_drag) {
                            if (self.drag_data_point) |start| {
                                // Clear pixels so subtract preview can drop overlay where the mask is cleared
                                // (setColorFromMask only writes where the mask is set).
                                @memset(file.editor.temporary_layer.pixels(), .{ 0, 0, 0, 0 });
                                applySelectionBoxPreview(
                                    file,
                                    active_layer,
                                    start,
                                    current_point,
                                    me.mod,
                                );
                            }
                            // Same checkerboard two-tone as the committed selection (no err/highlight tint).
                            file.editor.temporary_layer.mask.setIntersection(active_layer.mask);
                            file.editor.temporary_layer.setColorFromMask(selection_color_primary);
                            file.editor.temporary_layer.mask.setIntersection(file.editor.checkerboard);
                            file.editor.temporary_layer.setColorFromMask(selection_color_secondary);
                        } else {
                            var default: bool = true;

                            if (me.mod.matchBind("shift")) {
                                default = false;
                                selection_color_primary_stroke = selection_color_primary_stroke.lerp(dvui.themeGet().color(.err, .fill), 0.7);
                                selection_color_primary_stroke.a = selection_alpha_stroke;
                                selection_color_secondary_stroke = selection_color_secondary_stroke.lerp(dvui.themeGet().color(.err, .fill), 0.7);
                                selection_color_secondary_stroke.a = selection_alpha_stroke;
                            } else if (me.mod.matchBind("ctrl/cmd")) {
                                default = false;
                                selection_color_primary_stroke = selection_color_primary_stroke.lerp(dvui.themeGet().color(.highlight, .fill), 0.7);
                                selection_color_primary_stroke.a = selection_alpha_stroke;
                                selection_color_secondary_stroke = selection_color_secondary_stroke.lerp(dvui.themeGet().color(.highlight, .fill), 0.7);
                                selection_color_secondary_stroke.a = selection_alpha_stroke;
                            }

                            // Draw the point at the stroke size to the temporary layer mask only
                            file.drawPoint(
                                current_point,
                                .temporary,
                                .{
                                    .mask_only = true,
                                    .stroke_size = fizzy.editor.tools.stroke_size,
                                },
                            );

                            // Only show stroke over relevant pixels to make selection clearer
                            if (me.mod.matchBind("shift")) {
                                file.editor.temporary_layer.mask.setIntersection(file.editor.selection_layer.mask);
                            } else if (me.mod.matchBind("ctrl/cmd")) {
                                var copy_mask = file.editor.selection_layer.mask.clone(dvui.currentWindow().arena()) catch {
                                    dvui.log.err("Failed to clone selection layer mask", .{});
                                    return;
                                };
                                copy_mask.toggleAll();
                                file.editor.temporary_layer.mask.setIntersection(copy_mask);
                            }

                            // Intersect with the active layer mask so the stroke is confined to only non-transparent pixels
                            file.editor.temporary_layer.mask.setIntersection(active_layer.mask);
                            file.editor.temporary_layer.setColorFromMask(selection_color_primary_stroke);

                            // Intersect with the checkerboard mask so we can show the pattern
                            file.editor.temporary_layer.mask.setIntersection(file.editor.checkerboard);
                            file.editor.temporary_layer.setColorFromMask(if (default) selection_color_secondary_stroke else selection_color_primary_stroke);
                        }
                    }
                }

                if (me.action == .press and me.button.pointer()) {
                    if (!widget_active) continue;
                    e.handle(@src(), self.init_options.file.editor.canvas.scroll_container.data());

                    if (fizzy.editor.tools.selection_mode == .color) {
                        // Only clear the mask if we don't have ctrl/cmd pressed
                        if (!me.mod.matchBind("ctrl/cmd") and !me.mod.matchBind("shift"))
                            file.editor.selection_layer.clearMask();

                        file.selectColorFloodFromPoint(current_point, !me.mod.matchBind("shift")) catch {
                            dvui.log.err("Color selection flood failed", .{});
                        };
                        continue;
                    }

                    dvui.captureMouse(self.init_options.file.editor.canvas.scroll_container.data(), e.num);
                    dvui.dragPreStart(me.p, .{ .name = "stroke_drag" });

                    // Only clear the mask if we don't have ctrl/cmd pressed
                    if (!me.mod.matchBind("ctrl/cmd") and !me.mod.matchBind("shift"))
                        file.editor.selection_layer.clearMask();

                    if (fizzy.editor.tools.selection_mode == .box) {
                        self.drag_data_point = current_point;
                    } else {
                        file.selectPoint(
                            current_point,
                            .{
                                .value = !me.mod.matchBind("shift"),
                                .stroke_size = fizzy.editor.tools.stroke_size,
                            },
                        );

                        self.drag_data_point = current_point;
                    }
                } else if (me.action == .release and me.button.pointer()) {
                    if (!widget_active) continue;
                    if (dvui.captured(self.init_options.file.editor.canvas.scroll_container.data().id)) {
                        e.handle(@src(), self.init_options.file.editor.canvas.scroll_container.data());
                        dvui.captureMouse(null, e.num);
                        dvui.dragEnd();

                        if (fizzy.editor.tools.selection_mode == .box) {
                            if (self.drag_data_point) |start| {
                                file.selectRectBetweenPoints(
                                    start,
                                    current_point,
                                    .{
                                        .value = !me.mod.matchBind("shift"),
                                        .stroke_size = fizzy.editor.tools.stroke_size,
                                    },
                                );
                            }
                        } else if (fizzy.editor.tools.selection_mode != .color) {
                            file.selectPoint(
                                current_point,
                                .{
                                    .value = !me.mod.matchBind("shift"),
                                    .stroke_size = fizzy.editor.tools.stroke_size,
                                },
                            );
                        }

                        self.drag_data_point = null;
                    }
                } else if (me.action == .position or me.action == .wheel_x or me.action == .wheel_y) {
                    if (dvui.captured(self.init_options.file.editor.canvas.scroll_container.data().id)) {
                        if (!widget_active) continue;
                        if (dvui.dragging(me.p, "stroke_drag")) |_| {
                            if (self.drag_data_point) |previous_point| {
                                // Construct a rect spanning between current_point and previous_point
                                const min_x = @min(previous_point.x, current_point.x);
                                const min_y = @min(previous_point.y, current_point.y);
                                const max_x = @max(previous_point.x, current_point.x);
                                const max_y = @max(previous_point.y, current_point.y);
                                const span_rect = dvui.Rect{
                                    .x = min_x,
                                    .y = min_y,
                                    .w = max_x - min_x + 1,
                                    .h = max_y - min_y + 1,
                                };

                                const screen_rect = self.init_options.file.editor.canvas.screenFromDataRect(span_rect);

                                dvui.scrollDrag(.{
                                    .mouse_pt = me.p,
                                    .screen_rect = screen_rect,
                                });
                            }

                            if (fizzy.editor.tools.selection_mode == .pixel) {
                                if (self.drag_data_point) |previous_point| {
                                    file.selectLine(
                                        previous_point,
                                        current_point,
                                        .{
                                            .value = !me.mod.matchBind("shift"),
                                            .stroke_size = fizzy.editor.tools.stroke_size,
                                        },
                                    );
                                }

                                self.drag_data_point = current_point;
                            }
                        }
                    }
                }
            },
            else => {},
        }
    }

    if (fizzy.editor.tools.selection_mode == .box) {
        const mouse_pt = dvui.currentWindow().mouse_pt;
        const is_drag = dvui.dragging(mouse_pt, "stroke_drag") != null;
        if (!(is_drag and self.drag_data_point != null)) {
            @memset(file.editor.temporary_layer.pixels(), .{ 0, 0, 0, 0 });
            file.editor.temporary_layer.clearMask();

            file.editor.temporary_layer.mask.setUnion(file.editor.selection_layer.mask);
            file.editor.temporary_layer.mask.setIntersection(active_layer.mask);

            file.editor.temporary_layer.setColorFromMask(selection_color_primary);
            file.editor.temporary_layer.mask.setIntersection(file.editor.checkerboard);
            file.editor.temporary_layer.setColorFromMask(selection_color_secondary);
        }
    }

    file.editor.temp_layer_has_content = true;
}

fn processStrokeDragSegment(
    self: *FileWidget,
    file: *fizzy.Internal.File,
    previous_point: dvui.Point,
    current_point: dvui.Point,
    screen_pt: dvui.Point.Physical,
    color: [4]u8,
    stroke_size: u8,
    shift: bool,
) void {
    const min_x = @min(previous_point.x, current_point.x);
    const min_y = @min(previous_point.y, current_point.y);
    const max_x = @max(previous_point.x, current_point.x);
    const max_y = @max(previous_point.y, current_point.y);
    const span_rect = dvui.Rect{
        .x = min_x,
        .y = min_y,
        .w = max_x - min_x + 1,
        .h = max_y - min_y + 1,
    };

    const screen_rect = self.init_options.file.editor.canvas.screenFromDataRect(span_rect);
    dvui.scrollDrag(.{
        .mouse_pt = screen_pt,
        .screen_rect = screen_rect,
    });

    if (shift) {
        const preview_clip = tempStrokePreviewClipRect(&self.init_options.file.editor.canvas, file, stroke_size);
        const line_cover = file.lineBrushCoverRect(previous_point, current_point, stroke_size);
        const dirty = dvui.Rect.intersect(line_cover, preview_clip);
        if (!dirty.empty()) {
            file.drawLine(
                previous_point,
                current_point,
                .temporary,
                .{
                    .color = .{ .r = color[0], .g = color[1], .b = color[2], .a = color[3] },
                    .stroke_size = stroke_size,
                    .clip_rect = preview_clip,
                },
            );
            file.editor.temp_preview_dirty_rect = dirty;
            file.editor.temp_layer_has_content = true;
            expandTempGpuDirtyRect(&file.editor, dirty);
        }
        return;
    }

    if (file.strokeUndoExpandToCoverRect(file.lineBrushCoverRect(previous_point, current_point, stroke_size))) |_| {
        file.drawLine(
            previous_point,
            current_point,
            .selected,
            .{
                .color = .{ .r = color[0], .g = color[1], .b = color[2], .a = color[3] },
                .invalidate = true,
                .to_change = false,
                .stroke_size = stroke_size,
            },
        );
        fizzy.perf.draw_event_count += 1;
    } else |err| {
        dvui.log.err("strokeUndoExpandToCoverRect failed: {}", .{err});
    }

    self.drag_data_point = current_point;

    if (self.init_options.file.editor.canvas.rect.contains(screen_pt) and self.sample_data_point == null) {
        if (self.sample_data_point == null or color[3] == 0) {
            clearTempPreview(&file.editor);
            const temp_color = if (fizzy.editor.tools.current != .eraser) color else [_]u8{ 255, 255, 255, 255 };
            file.drawPoint(
                current_point,
                .temporary,
                .{
                    .color = .{ .r = temp_color[0], .g = temp_color[1], .b = temp_color[2], .a = temp_color[3] },
                    .stroke_size = stroke_size,
                },
            );
            const brush_rect = tempBrushRect(current_point, stroke_size, file.width(), file.height());
            file.editor.temp_preview_dirty_rect = brush_rect;
            file.editor.temp_layer_has_content = true;
            expandTempGpuDirtyRect(&file.editor, brush_rect);
        }
    }
}

/// Responsible for processing events to modify pixels on the current layer for strokes of various size
/// Supports using shift to draw a line between two points, and increasing/decreasing stroke size
pub fn processStroke(self: *FileWidget) void {
    const file = self.init_options.file;
    const stroke_size = fizzy.editor.tools.stroke_size;
    const widget_active = self.active();

    if (self.cell_reorder_point != null) return;

    if (switch (fizzy.editor.tools.current) {
        .pencil,
        .eraser,
        => false,
        else => true,
    }) return;

    if (self.sample_key_down or self.right_mouse_down) return;

    const color: [4]u8 = switch (fizzy.editor.tools.current) {
        .pencil => fizzy.editor.colors.primary,
        .eraser => [_]u8{ 0, 0, 0, 0 },
        else => unreachable,
    };

    for (dvui.events()) |*e| {
        if (!self.init_options.file.editor.canvas.scroll_container.matchEvent(e)) {
            continue;
        }

        switch (e.evt) {
            .mouse => |me| {
                const current_point = self.init_options.file.editor.canvas.dataFromScreenPoint(me.p);

                if (me.action == .press and me.button.pointer()) {
                    if (!widget_active) continue;
                    e.handle(@src(), self.init_options.file.editor.canvas.scroll_container.data());
                    dvui.captureMouse(self.init_options.file.editor.canvas.scroll_container.data(), e.num);
                    dvui.dragPreStart(me.p, .{ .name = "stroke_drag" });
                    file.editor.active_drawing = true;

                    file.buffers.stroke.clearAndFree();
                    file.strokeUndoBegin(file.brushStampRect(current_point, stroke_size)) catch |err| {
                        dvui.log.err("strokeUndoBegin failed: {}", .{err});
                    };

                    if (!me.mod.matchBind("shift")) {
                        file.drawPoint(
                            current_point,
                            .selected,
                            .{
                                .color = .{ .r = color[0], .g = color[1], .b = color[2], .a = color[3] },
                                .invalidate = true,
                                .to_change = false,
                                .stroke_size = stroke_size,
                            },
                        );
                    }

                    self.drag_data_point = current_point;
                } else if (me.action == .release and me.button.pointer()) {
                    if (!widget_active) continue;
                    if (dvui.captured(self.init_options.file.editor.canvas.scroll_container.data().id)) {
                        e.handle(@src(), self.init_options.file.editor.canvas.scroll_container.data());
                        dvui.captureMouse(null, e.num);
                        dvui.dragEnd();

                        // Touch drags do not get `.position` hover updates, so the per-frame temp
                        // cleanup in `process()` may not run after lift. Clear any brush preview now.
                        resetTempLayerPreview(&file.editor);

                        if (me.mod.matchBind("shift")) {
                            if (self.drag_data_point) |previous_point| {
                                if (file.strokeUndoExpandToCoverRect(file.lineBrushCoverRect(previous_point, current_point, stroke_size))) |_| {
                                    file.drawLine(
                                        previous_point,
                                        current_point,
                                        .selected,
                                        .{
                                            .color = .{ .r = color[0], .g = color[1], .b = color[2], .a = color[3] },
                                            .invalidate = true,
                                            .to_change = true,
                                            .stroke_size = stroke_size,
                                        },
                                    );
                                } else |err| {
                                    dvui.log.err("strokeUndoExpandToCoverRect failed: {}", .{err});
                                }
                            }
                        } else {
                            if (self.drag_data_point) |start| {
                                const full_cover = file.lineBrushCoverRect(start, current_point, stroke_size);
                                if (file.strokeUndoExpandToCoverRect(full_cover)) |_| {} else |err| {
                                    dvui.log.err("strokeUndoExpandToCoverRect failed: {}", .{err});
                                }
                            }

                            file.drawPoint(
                                current_point,
                                .selected,
                                .{
                                    .color = .{ .r = color[0], .g = color[1], .b = color[2], .a = color[3] },
                                    .invalidate = true,
                                    .to_change = true,
                                    .stroke_size = stroke_size,
                                },
                            );
                        }

                        // Redraw without the temp brush overlay; needed when hover stops after touch lift.
                        dvui.refresh(null, @src(), self.init_options.file.editor.canvas.scroll_container.data().id);

                        // End active drawing after committing the release stroke.
                        // Reset the composite frame guard so the canvas renderLayers
                        // (which runs later this frame) can rebuild the full composite
                        // immediately rather than showing a stale pre-drawing composite.
                        file.editor.active_drawing = false;
                        file.editor.layer_composite_dirty = true;
                        file.editor.layer_composite_frame_built = 0;

                        self.drag_data_point = null;
                    }
                } else if (me.action == .motion and me.button.touch()) {
                    if (dvui.captured(self.init_options.file.editor.canvas.scroll_container.data().id)) {
                        if (!widget_active) continue;
                        if (dvui.dragging(me.p, "stroke_drag")) |_| {
                            if (self.drag_data_point) |previous_point| {
                                processStrokeDragSegment(
                                    self,
                                    file,
                                    previous_point,
                                    current_point,
                                    me.p,
                                    color,
                                    stroke_size,
                                    me.mod.matchBind("shift"),
                                );
                            }
                        }
                    }
                } else if (me.action == .position or me.action == .wheel_x or me.action == .wheel_y) {
                    if (dvui.captured(self.init_options.file.editor.canvas.scroll_container.data().id)) {
                        if (!widget_active) continue;
                        if (dvui.dragging(me.p, "stroke_drag")) |_| {
                            if (self.drag_data_point) |previous_point| {
                                processStrokeDragSegment(
                                    self,
                                    file,
                                    previous_point,
                                    current_point,
                                    me.p,
                                    color,
                                    stroke_size,
                                    me.mod.matchBind("shift"),
                                );
                            }
                        }
                    } else {
                        if (self.init_options.file.editor.canvas.rect.contains(me.p) and self.sample_data_point == null) {
                            clearTempPreview(&file.editor);
                            const temp_color = if (fizzy.editor.tools.current != .eraser) color else [_]u8{ 255, 255, 255, 255 };
                            file.drawPoint(
                                current_point,
                                .temporary,
                                .{
                                    .stroke_size = stroke_size,
                                    .color = .{ .r = temp_color[0], .g = temp_color[1], .b = temp_color[2], .a = temp_color[3] },
                                },
                            );
                            const brush_rect = tempBrushRect(current_point, stroke_size, file.width(), file.height());
                            file.editor.temp_preview_dirty_rect = brush_rect;
                            file.editor.temp_layer_has_content = true;
                            expandTempGpuDirtyRect(&file.editor, brush_rect);
                        }
                    }
                }
            },
            else => {},
        }
    }
}

/// Responsible for processing events to fill pixels on the current layer with a solid color.
/// Supports using ctrl/cmd to replace all existing pixels of the same color with the new color,
/// or without modifiers to flood fill the layer with the new color.
pub fn processFill(self: *FileWidget) void {
    if (fizzy.editor.tools.current != .bucket) return;
    if (self.sample_key_down) return;
    const file = self.init_options.file;
    const color = fizzy.editor.colors.primary;
    const widget_active = self.active();

    if (self.init_options.file.editor.canvas.rect.contains(dvui.currentWindow().mouse_pt) and self.sample_data_point == null) {
        clearTempPreview(&file.editor);
        const temp_color = if (fizzy.editor.tools.current != .eraser) color else [_]u8{ 255, 255, 255, 255 };
        const fill_preview_pt = self.init_options.file.editor.canvas.dataFromScreenPoint(dvui.currentWindow().mouse_pt);
        file.drawPoint(
            fill_preview_pt,
            .temporary,
            .{
                .stroke_size = 1,
                .color = .{ .r = temp_color[0], .g = temp_color[1], .b = temp_color[2], .a = temp_color[3] },
            },
        );
        const brush_rect = tempBrushRect(fill_preview_pt, 1, file.width(), file.height());
        file.editor.temp_preview_dirty_rect = brush_rect;
        file.editor.temp_layer_has_content = true;
        expandTempGpuDirtyRect(&file.editor, brush_rect);
    }

    for (dvui.events()) |*e| {
        if (!self.init_options.file.editor.canvas.scroll_container.matchEvent(e)) {
            continue;
        }

        switch (e.evt) {
            .mouse => |me| {
                const current_point = self.init_options.file.editor.canvas.dataFromScreenPoint(me.p);

                if (me.action == .press and me.button.pointer()) {
                    if (!widget_active) continue;
                    file.fillPoint(current_point, .selected, .{
                        .color = .{ .r = color[0], .g = color[1], .b = color[2], .a = color[3] },
                        .invalidate = true,
                        .to_change = true,
                        .replace = me.mod.matchBind("ctrl/cmd"),
                    });
                }
            },
            else => {},
        }
    }
}

/// Responsible for processing events to create/modify a transform. A transform is basically a quad with controls on each corner, and
/// allows moving, rotating, skewing and scaling the quad. The controls also include a pivot point for the rotation.
pub fn processTransform(self: *FileWidget) void {
    const file = self.init_options.file;
    const image_rect = dvui.Rect.fromSize(.{ .w = @floatFromInt(file.width()), .h = @floatFromInt(file.height()) });
    const image_rect_physical = dvui.Rect.Physical.fromSize(.{ .w = image_rect.w, .h = image_rect.h });

    if (file.editor.transform) |*transform| {

        // Data path is necessary to build and fill with convex triangles, which will be how we render to the target texture
        var data_path: dvui.Path.Builder = .init(dvui.currentWindow().arena());
        for (transform.data_points[0..4]) |*point| {
            data_path.addPoint(.{ .x = point.x, .y = point.y });
        }

        // Calculate the centroid of the four corner points
        const centroid = transform.centroid();

        var triangle_opts: ?dvui.Triangles = data_path.build().fillConvexTriangles(dvui.currentWindow().arena(), .{
            .center = .{ .x = centroid.x, .y = centroid.y },
            .color = .white,
        }) catch null;

        { // Update the rotate point to locate towards the mouse
            const diff = self.init_options.file.editor.canvas.dataFromScreenPoint(dvui.currentWindow().mouse_pt).diff(transform.point(.pivot).*);
            transform.point(.rotate).* = transform.point(.pivot).plus(diff.normalize().scale(transform.radius, dvui.Point));
        }

        if (triangle_opts) |*triangles| {
            // First, we rotate the triangles to match the angle
            triangles.rotate(.{ .x = transform.point(.pivot).x, .y = transform.point(.pivot).y }, transform.rotation);

            for (transform.data_points[0..6], 0..) |*data_point, point_index| {
                const transform_point = @as(fizzy.Editor.Transform.TransformPoint, @enumFromInt(point_index));
                const screen_point = if (point_index < 4) file.editor.canvas.screenFromDataPoint(.{ .x = triangles.vertexes[point_index].pos.x, .y = triangles.vertexes[point_index].pos.y }) else file.editor.canvas.screenFromDataPoint(data_point.*);

                var screen_rect = dvui.Rect.Physical.fromPoint(screen_point);
                screen_rect.w = 16 * dvui.currentWindow().natural_scale;
                screen_rect.h = 16 * dvui.currentWindow().natural_scale;
                screen_rect.x -= screen_rect.w / 2;
                screen_rect.y -= screen_rect.h / 2;

                for (dvui.events()) |*e| {
                    if (!self.init_options.file.editor.canvas.scroll_container.matchEvent(e)) {
                        continue;
                    }

                    if (screen_rect.contains(dvui.currentWindow().mouse_pt)) {
                        dvui.cursorSet(.hand);
                    } else if (transform.active_point) |active_point| {
                        if (active_point == @as(fizzy.Editor.Transform.TransformPoint, @enumFromInt(point_index))) {
                            dvui.cursorSet(.hand);
                        }
                    }

                    switch (e.evt) {
                        .key => |ke| {
                            if ((ke.action == .down or ke.action == .repeat) and ke.matchBind("up")) {
                                transform.move(.{ .x = 0, .y = -1 });
                                e.handle(@src(), self.init_options.file.editor.canvas.scroll_container.data());
                                dvui.refresh(null, @src(), self.init_options.file.editor.canvas.scroll_container.data().id);
                            }
                            if ((ke.action == .down or ke.action == .repeat) and ke.matchBind("down")) {
                                transform.move(.{ .x = 0, .y = 1 });
                                e.handle(@src(), self.init_options.file.editor.canvas.scroll_container.data());
                                dvui.refresh(null, @src(), self.init_options.file.editor.canvas.scroll_container.data().id);
                            }
                            if ((ke.action == .down or ke.action == .repeat) and ke.matchBind("left")) {
                                transform.move(.{ .x = -1, .y = 0 });
                                e.handle(@src(), self.init_options.file.editor.canvas.scroll_container.data());
                                dvui.refresh(null, @src(), self.init_options.file.editor.canvas.scroll_container.data().id);
                            }
                            if ((ke.action == .down or ke.action == .repeat) and ke.matchBind("right")) {
                                transform.move(.{ .x = 1, .y = 0 });
                                e.handle(@src(), self.init_options.file.editor.canvas.scroll_container.data());
                                dvui.refresh(null, @src(), self.init_options.file.editor.canvas.scroll_container.data().id);
                            }
                        },
                        .mouse => |me| {
                            const current_point = self.init_options.file.editor.canvas.dataFromScreenPoint(me.p);

                            if (me.action == .press and me.button.pointer()) {
                                if (screen_rect.contains(me.p)) {
                                    transform.active_point = @enumFromInt(point_index);
                                    e.handle(@src(), self.init_options.file.editor.canvas.scroll_container.data());
                                    dvui.captureMouse(self.init_options.file.editor.canvas.scroll_container.data(), e.num);
                                    dvui.dragPreStart(me.p, .{ .name = "transform_vertex_drag" });
                                    self.drag_data_point = current_point;
                                    transform.start_rotation = transform.rotation;
                                    if (point_index < 4) {
                                        const oi: usize = switch (point_index) {
                                            0 => 2,
                                            1 => 3,
                                            2 => 0,
                                            3 => 1,
                                            else => unreachable,
                                        };
                                        const opp = transform.data_points[oi];
                                        const cur = transform.data_points[point_index];
                                        self.transform_aspect_w = @abs(cur.x - opp.x);
                                        self.transform_aspect_h = @abs(cur.y - opp.y);
                                    }
                                }
                            } else if (me.action == .release and me.button.pointer()) {
                                if (dvui.captured(self.init_options.file.editor.canvas.scroll_container.data().id)) {
                                    if (transform.active_point) |active_point| {
                                        if (active_point == .pivot and transform.dragging == false) {
                                            transform.point(.pivot).* = transform.centroid();
                                            transform.updateRadius();
                                        }
                                    }

                                    e.handle(@src(), self.init_options.file.editor.canvas.scroll_container.data());
                                    dvui.captureMouse(null, e.num);
                                    dvui.dragEnd();
                                    transform.active_point = null;
                                    dvui.refresh(null, @src(), self.init_options.file.editor.canvas.scroll_container.data().id);
                                    self.drag_data_point = null;
                                    self.transform_aspect_w = null;
                                    self.transform_aspect_h = null;
                                    transform.dragging = false;
                                }
                            } else if (me.action == .motion or me.action == .wheel_x or me.action == .wheel_y) {
                                if (dvui.captured(self.init_options.file.editor.canvas.scroll_container.data().id)) {
                                    if (dvui.dragging(me.p, "transform_vertex_drag")) |_| {
                                        transform.dragging = true;
                                        if (transform.active_point) |active_point| {
                                            if (@intFromEnum(active_point) == point_index) {
                                                e.handle(@src(), self.init_options.file.editor.canvas.scroll_container.data());

                                                // Set this state in advance so we can use it for the radius calculation
                                                transform.track_pivot = active_point == .pivot;

                                                // This is the new data point of the dragged point
                                                var new_point = file.editor.canvas.dataFromScreenPoint(me.p);

                                                // Calculate the radius of the transform no matter what point is changing
                                                defer transform.updateRadius();

                                                if (point_index < 4) {
                                                    // Only round the corner points
                                                    new_point.x = @round(new_point.x);
                                                    new_point.y = @round(new_point.y);

                                                    // Now we have to un-rotate the vertex and set the original location
                                                    new_point = fizzy.math.rotate(new_point, transform.point(.pivot).*, -transform.rotation);

                                                    const opposite_index: usize = switch (point_index) {
                                                        0 => 2,
                                                        1 => 3,
                                                        2 => 0,
                                                        3 => 1,
                                                        else => unreachable,
                                                    };

                                                    // ctrl/cmd: free skew. shift: axis-aligned rect (old default). no mod: same rect + locked aspect vs opposite corner.
                                                    if (me.mod.matchBind("ctrl/cmd")) {
                                                        data_point.* = new_point;
                                                        transform.ortho = false;
                                                    } else {
                                                        transform.ortho = true;
                                                        if (me.mod.matchBind("shift")) {
                                                            data_point.* = new_point;
                                                        } else {
                                                            const opp = transform.data_points[opposite_index];
                                                            var constrained = new_point;
                                                            if (self.transform_aspect_w) |aw| {
                                                                if (self.transform_aspect_h) |ah| {
                                                                    if (aw > 1e-4 and ah > 1e-4) {
                                                                        const mx = new_point.x - opp.x;
                                                                        const my = new_point.y - opp.y;
                                                                        const ax = @abs(mx);
                                                                        const ay = @abs(my);
                                                                        const den = aw * aw + ah * ah;
                                                                        if (den > 1e-8) {
                                                                            const t = (aw * ax + ah * ay) / den;
                                                                            constrained.x = @round(opp.x + math.copysign(aw * t, mx));
                                                                            constrained.y = @round(opp.y + math.copysign(ah * t, my));
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                            data_point.* = constrained;
                                                        }

                                                        blk_vert: {
                                                            // Find adjacent verts
                                                            const adjacent_index_cw = if (point_index < 3) point_index + 1 else 0;
                                                            const adjacent_index_ccw = if (point_index > 0) point_index - 1 else 3;

                                                            // Get the adjacent points
                                                            const adjacent_point_cw = &transform.data_points[adjacent_index_cw];
                                                            const adjacent_point_ccw = &transform.data_points[adjacent_index_ccw];

                                                            const opposite_point = &transform.data_points[opposite_index];

                                                            var rotation_direction: dvui.Point = fizzy.math.rotate(dvui.Point{ .x = 1, .y = 0 }, transform.point(.pivot).*, 0);
                                                            var rotation_perp: dvui.Point = fizzy.math.rotate(dvui.Point{ .x = 0, .y = 1 }, transform.point(.pivot).*, 0);

                                                            // Calculate the difference between the adjacent points and the new point

                                                            { // Calculate intersection point to set adjacent vert
                                                                const as = data_point.*;
                                                                const bs = opposite_point.*;
                                                                const ad = rotation_direction.scale(-1.0, dvui.Point);
                                                                const bd = rotation_perp;
                                                                const dx = bs.x - as.x;
                                                                const dy = bs.y - as.y;
                                                                const det = bd.x * ad.y - bd.y * ad.x;
                                                                if (det == 0.0) break :blk_vert;
                                                                const u = (dy * bd.x - dx * bd.y) / det;
                                                                switch (point_index) {
                                                                    0, 2 => adjacent_point_cw.* = as.plus(ad.scale(u, dvui.Point)),
                                                                    1, 3 => adjacent_point_ccw.* = as.plus(ad.scale(u, dvui.Point)),
                                                                    else => unreachable,
                                                                }
                                                            }

                                                            { // Calculate intersection point to set adjacent vert
                                                                const as = data_point.*;
                                                                const bs = opposite_point.*;
                                                                const ad = rotation_perp.scale(-1.0, dvui.Point);
                                                                const bd = rotation_direction;
                                                                const dx = bs.x - as.x;
                                                                const dy = bs.y - as.y;
                                                                const det = bd.x * ad.y - bd.y * ad.x;
                                                                if (det == 0.0) break :blk_vert;
                                                                const u = (dy * bd.x - dx * bd.y) / det;
                                                                switch (point_index) {
                                                                    0, 2 => adjacent_point_ccw.* = as.plus(ad.scale(u, dvui.Point)),
                                                                    1, 3 => adjacent_point_cw.* = as.plus(ad.scale(u, dvui.Point)),
                                                                    else => unreachable,
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                                if (active_point == .pivot) {
                                                    data_point.* = new_point;
                                                }
                                                if (transform_point == .rotate) {
                                                    if (self.drag_data_point) |drag_data_point| {
                                                        const drag_diff = drag_data_point.diff(transform.point(.pivot).*);
                                                        const drag_angle = std.math.atan2(drag_diff.y, drag_diff.x);

                                                        const diff = new_point.diff(transform.point(.pivot).*);
                                                        const angle = std.math.atan2(diff.y, diff.x);

                                                        transform.rotation = std.math.degreesToRadians(@round(std.math.radiansToDegrees(transform.start_rotation + (angle - drag_angle))));

                                                        if (me.mod.matchBind("ctrl/cmd")) { // Lock rotation to cardinal directions
                                                            const direction = fizzy.math.Direction.fromRadians(transform.rotation);
                                                            transform.rotation = switch (direction) {
                                                                .n => std.math.pi / 2.0,
                                                                .ne => std.math.pi / 4.0,
                                                                .e => 0,
                                                                .s => (3.0 * std.math.pi) / 2.0,
                                                                .nw => (3.0 * std.math.pi) / 4.0,
                                                                .w => std.math.pi,
                                                                .sw => (5.0 * std.math.pi) / 4.0,
                                                                .se => (7.0 * std.math.pi) / 4.0,
                                                                else => unreachable,
                                                            };
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        },
                        else => {},
                    }
                }
            }

            // Now if we havent selected any of the points, we need to handle dragging the interior of the polygon
            // to move the entire transform
            if (transform.active_point == null) {
                for (dvui.events()) |*e| {
                    if (!self.init_options.file.editor.canvas.scroll_container.matchEvent(e)) {
                        continue;
                    }

                    var is_hovered: bool = false;

                    if (transform.hovered(file.editor.canvas.dataFromScreenPoint(dvui.currentWindow().mouse_pt))) {
                        dvui.cursorSet(.hand);
                        is_hovered = true;
                    }

                    switch (e.evt) {
                        .mouse => |me| {
                            if (me.action == .press and me.button.pointer()) {
                                //if (is_hovered or me.mod.matchBind("ctrl/cmd")) {
                                e.handle(@src(), self.init_options.file.editor.canvas.scroll_container.data());
                                dvui.captureMouse(self.init_options.file.editor.canvas.scroll_container.data(), e.num);
                                dvui.dragPreStart(me.p, .{ .name = "transform_drag" });
                                //}
                            } else if (me.action == .motion or me.action == .wheel_x or me.action == .wheel_y) {
                                if (dvui.captured(self.init_options.file.editor.canvas.scroll_container.data().id)) {
                                    if (dvui.dragging(me.p, "transform_drag")) |_| {
                                        dvui.cursorSet(.hand);
                                        transform.dragging = true;
                                        e.handle(@src(), self.init_options.file.editor.canvas.scroll_container.data());

                                        var prev_point = file.editor.canvas.dataFromScreenPoint(dvui.currentWindow().mouse_pt_prev);
                                        prev_point.x = @round(prev_point.x);
                                        prev_point.y = @round(prev_point.y);
                                        var new_point = file.editor.canvas.dataFromScreenPoint(dvui.currentWindow().mouse_pt);
                                        new_point.x = @round(new_point.x);
                                        new_point.y = @round(new_point.y);

                                        transform.move(new_point.diff(prev_point));
                                        dvui.refresh(null, @src(), self.init_options.file.editor.canvas.scroll_container.data().id);
                                    }
                                }
                            }
                        },
                        else => {},
                    }
                }
            }

            // Here pass in the data rect, since we will be rendering directly to the low-res texture

            transform.target_texture.clear();
            const previous_target = dvui.renderTarget(.{ .texture = transform.target_texture, .offset = image_rect_physical.topLeft() });

            // Make sure we clip to the image rect, if we don't  and the texture overlaps the canvas,
            // the rendering will be clipped incorrectly
            // Use clipSet instead of clip, clip unions with current clip
            const clip_rect = image_rect_physical;
            const prev_clip = dvui.clipGet();
            dvui.clipSet(clip_rect);

            // Set UVs, there are 5 vertexes, or 1 more than the number of triangles, and is at the center
            triangles.vertexes[0].uv = .{ 0.0, 0.0 }; // TL
            triangles.vertexes[1].uv = .{ 1.0, 0.0 }; // TR
            triangles.vertexes[2].uv = .{ 1.0, 1.0 }; // BR
            triangles.vertexes[3].uv = .{ 0.0, 1.0 }; // BL
            triangles.vertexes[4].uv = .{ 0.5, 0.5 }; // C

            dvui.renderTriangles(triangles.*, transform.source.getTexture() catch null) catch {
                dvui.log.err("Failed to render triangles", .{});
            };

            // Restore the previous clip
            dvui.clipSet(prev_clip);
            // Set the target back
            _ = dvui.renderTarget(previous_target);

            // Read the target texture and copy it to the selection layer
            // This is currently very slow, and is a bottleneck for the editor
            // TODO: look into how to draw the target texture without needing to read the target back
            // if (dvui.textureReadTarget(dvui.currentWindow().arena(), transform.target_texture) catch null) |image_data| {
            //     @memcpy(file.editor.temporary_layer.bytes(), @as([*]u8, @ptrCast(image_data.ptr)));
            //     file.editor.temporary_layer.invalidate();
            // } else {
            //     dvui.log.err("Failed to read target", .{});
            // }
        } else {
            dvui.log.err("Failed to fill triangles", .{});
        }
    }
}

/// Responsible for drawing the transform guides and controls for the current transform after processing.
/// Includes guides for the sprite size and angle in appropriately scaled text labels.
pub fn drawTransform(self: *FileWidget) void {
    const file = self.init_options.file;

    if (file.editor.transform) |*transform| {
        const show_ortho_dims = transform.ortho and blk: {
            if (transform.active_point) |ap| {
                break :blk @intFromEnum(ap) < 4;
            }
            break :blk transform.dragging;
        };
        const dim_cell_opt: ?usize = if (show_ortho_dims) file.spriteIndex(transform.centroid()) else null;

        var path = dvui.Path.Builder.init(dvui.currentWindow().arena());
        for (transform.data_points[0..4]) |*point| {
            const screen_point = file.editor.canvas.screenFromDataPoint(point.*);
            path.addPoint(screen_point);
        }

        var centroid = transform.centroid();
        centroid = fizzy.math.rotate(centroid, transform.point(.pivot).*, transform.rotation);

        // Full-sprite center guides (magenta). When ortho cell dimensions are shown, centering is
        // indicated on those dimension lines (blue) instead — avoids overlapping magenta guides.
        if (dim_cell_opt == null) {
            if (file.spriteIndex(centroid)) |sprite_index| {
                const sprite_rect = file.spriteRect(sprite_index);
                const sprite_center = sprite_rect.center();

                const sprite_diff = sprite_center.diff(centroid);

                if (@floor(sprite_diff.x) == 0) {
                    const point_1: dvui.Point = .{ .x = sprite_center.x, .y = sprite_rect.topLeft().y };
                    const point_2: dvui.Point = .{ .x = sprite_center.x, .y = sprite_rect.bottomRight().y };

                    dvui.Path.stroke(.{ .points = &.{
                        file.editor.canvas.screenFromDataPoint(point_1),
                        file.editor.canvas.screenFromDataPoint(point_2),
                    } }, .{ .thickness = 1, .color = .magenta });
                }

                if (@floor(sprite_diff.y) == 0) {
                    const point_1: dvui.Point = .{ .x = sprite_rect.topLeft().x, .y = sprite_center.y };
                    const point_2: dvui.Point = .{ .x = sprite_rect.bottomRight().x, .y = sprite_center.y };

                    dvui.Path.stroke(.{ .points = &.{
                        file.editor.canvas.screenFromDataPoint(point_1),
                        file.editor.canvas.screenFromDataPoint(point_2),
                    } }, .{ .thickness = 1, .color = .magenta });
                }
            }
        }

        {
            const centroid_rect = dvui.Rect.fromPoint(centroid);
            var centroid_screen_rect = file.editor.canvas.screenFromDataRect(centroid_rect);
            centroid_screen_rect.w = 8 * dvui.currentWindow().natural_scale;
            centroid_screen_rect.h = 8 * dvui.currentWindow().natural_scale;
            centroid_screen_rect.x -= centroid_screen_rect.w / 2;
            centroid_screen_rect.y -= centroid_screen_rect.h / 2;

            centroid_screen_rect.fill(dvui.Rect.Physical.all(100000), .{
                .color = dvui.themeGet().color(.control, .fill),
            });

            centroid_screen_rect = centroid_screen_rect.insetAll(2 * dvui.currentWindow().natural_scale);
            centroid_screen_rect.fill(dvui.Rect.Physical.all(100000), .{
                .color = dvui.themeGet().color(.window, .text),
            });
        }

        if (!show_ortho_dims) {
            { // Draw circular outline for the rotation path
                var rotate_path = dvui.Path.Builder.init(dvui.currentWindow().arena());
                var outline_rect = dvui.Rect.fromSize(.{ .w = transform.radius * 2, .h = transform.radius * 2 });

                outline_rect.x = transform.point(.pivot).x - transform.radius;
                outline_rect.y = transform.point(.pivot).y - transform.radius;
                const outline_screen_rect = file.editor.canvas.screenFromDataRect(outline_rect);

                rotate_path.addRect(outline_screen_rect, dvui.Rect.Physical.all(100000));
                rotate_path.build().stroke(.{
                    .thickness = 4 * dvui.currentWindow().natural_scale,
                    .color = dvui.themeGet().color(.control, .fill),
                    .closed = true,
                    .endcap_style = .square,
                });
                rotate_path.build().stroke(.{
                    .thickness = 2,
                    .color = dvui.themeGet().color(.window, .text),
                    .closed = true,
                    .endcap_style = .square,
                });
            }

            if (transform.active_point) |active_point| {
                if (active_point == .rotate) {
                    // Draw the arms of the rotation
                    if (self.drag_data_point) |drag_data_point| {
                        const diff = drag_data_point.diff(transform.point(.pivot).*);

                        // Start angle
                        doubleStroke(&.{
                            file.editor.canvas.screenFromDataPoint(transform.point(.pivot).*),
                            file.editor.canvas.screenFromDataPoint(transform.point(.pivot).plus(diff.normalize().scale(transform.radius, dvui.Point))),
                        }, dvui.themeGet().color(.control, .text), 2);

                        // New angle
                        doubleStroke(&.{
                            file.editor.canvas.screenFromDataPoint(transform.point(.pivot).*),
                            file.editor.canvas.screenFromDataPoint(transform.point(.rotate).*),
                        }, dvui.themeGet().color(.control, .text), 2);
                    }
                }
            }
        }

        var triangles_opt = path.build().fillConvexTriangles(dvui.currentWindow().arena(), .{
            .center = .{ .x = centroid.x, .y = centroid.y },
            .color = .white,
        }) catch null;

        if (triangles_opt) |*triangles| {
            triangles.rotate(file.editor.canvas.screenFromDataPoint(transform.point(.pivot).*), transform.rotation);

            { // Draw the outline of the triangles
                const is_hovered = transform.hovered(file.editor.canvas.dataFromScreenPoint(dvui.currentWindow().mouse_pt));
                var outline_path = dvui.Path.Builder.init(dvui.currentWindow().arena());
                for (triangles.vertexes[0..4]) |*vertex| {
                    outline_path.addPoint(.{ .x = vertex.pos.x, .y = vertex.pos.y });
                }

                outline_path.build().stroke(.{
                    .thickness = 4 * dvui.currentWindow().natural_scale,
                    .color = dvui.themeGet().color(.control, .fill),
                    .closed = true,
                    .endcap_style = .square,
                });
                outline_path.build().stroke(.{
                    .thickness = 2,
                    .color = if ((is_hovered and transform.active_point == null) or transform.dragging) dvui.themeGet().color(.highlight, .fill) else dvui.themeGet().color(.window, .text),
                    .closed = true,
                    .endcap_style = .square,
                });
            }

            // Dimensions and angle labels
            {
                const dim_font = dvui.Font.theme(.mono).larger(-2);

                if (show_ortho_dims) {
                    const ns = dvui.currentWindow().natural_scale;
                    const canvas = &file.editor.canvas;
                    const px_per_data_x = blk: {
                        const a = canvas.screenFromDataPoint(.{ .x = 0, .y = 0 });
                        const b = canvas.screenFromDataPoint(.{ .x = 1, .y = 0 });
                        break :blk @max(@abs(b.x - a.x), 0.001);
                    };
                    const px_per_data_y = blk: {
                        const a = canvas.screenFromDataPoint(.{ .x = 0, .y = 0 });
                        const b = canvas.screenFromDataPoint(.{ .x = 0, .y = 1 });
                        break :blk @max(@abs(b.y - a.y), 0.001);
                    };
                    const tick_half_px = 2.9 * ns;
                    const label_off_screen = 9 * ns;

                    const tl_d = transform.data_points[0];
                    const tr_d = transform.data_points[1];
                    const br_d = transform.data_points[2];
                    const bl_d = transform.data_points[3];
                    const bbox_min_x = @min(@min(tl_d.x, tr_d.x), @min(bl_d.x, br_d.x));
                    const bbox_max_x = @max(@max(tl_d.x, tr_d.x), @max(bl_d.x, br_d.x));
                    const bbox_min_y = @min(@min(tl_d.y, tr_d.y), @min(bl_d.y, br_d.y));
                    const bbox_max_y = @max(@max(tl_d.y, tr_d.y), @max(bl_d.y, br_d.y));

                    const cell_cap_x: f32 = if (dim_cell_opt) |ci| file.spriteRect(ci).w else bbox_max_x - bbox_min_x;
                    const cell_cap_y: f32 = if (dim_cell_opt) |ci| file.spriteRect(ci).h else bbox_max_y - bbox_min_y;
                    const arm_x_data = @max(0.2, @min(tick_half_px / px_per_data_x, cell_cap_x * 0.11));
                    const arm_y_data = @max(0.2, @min(tick_half_px / px_per_data_y, cell_cap_y * 0.11));
                    const dim_tick_thick: f32 = 0.65;

                    const x_c = (bbox_min_x + bbox_max_x) * 0.5;
                    const y_c = (bbox_min_y + bbox_max_y) * 0.5;

                    if (dim_cell_opt) |ci| {
                        const cell = file.spriteRect(ci);
                        const cell_left = cell.x;
                        const cell_right = cell.x + cell.w;
                        const cell_top = cell.y;
                        const cell_bot = cell.y + cell.h;
                        const arena = dvui.currentWindow().arena();
                        const sprite_c = cell.center();
                        const sd = sprite_c.diff(centroid);
                        const dim_inner_h: dvui.Color = if (@floor(sd.x) == 0) .blue else .magenta;
                        const dim_inner_v: dvui.Color = if (@floor(sd.y) == 0) .blue else .magenta;

                        // Left: edge midpoint (bbox left, vertical center) → cell left; label near line.
                        {
                            const span = bbox_min_x - cell_left;
                            if (@abs(span) > 0.001) {
                                doubleStrokeDimensionTickColor(&.{
                                    canvas.screenFromDataPoint(.{ .x = cell_left, .y = y_c }),
                                    canvas.screenFromDataPoint(.{ .x = bbox_min_x, .y = y_c }),
                                }, 1, dim_inner_h);
                                doubleStrokeDimensionTickColor(&.{
                                    canvas.screenFromDataPoint(.{ .x = cell_left, .y = y_c - arm_y_data }),
                                    canvas.screenFromDataPoint(.{ .x = cell_left, .y = y_c + arm_y_data }),
                                }, dim_tick_thick, dim_inner_h);
                                doubleStrokeDimensionTickColor(&.{
                                    canvas.screenFromDataPoint(.{ .x = bbox_min_x, .y = y_c - arm_y_data }),
                                    canvas.screenFromDataPoint(.{ .x = bbox_min_x, .y = y_c + arm_y_data }),
                                }, dim_tick_thick, dim_inner_h);
                                const t = std.fmt.allocPrint(arena, "{d}", .{@as(i32, @intFromFloat(@round(span)))}) catch "—";
                                var lp = canvas.screenFromDataPoint(.{ .x = (cell_left + bbox_min_x) * 0.5, .y = y_c });
                                lp.x -= label_off_screen;
                                renderTransformDimLabel(dim_font, t, lp);
                            }
                        }
                        // Right: bbox right → cell right
                        {
                            const span = cell_right - bbox_max_x;
                            if (@abs(span) > 0.001) {
                                doubleStrokeDimensionTickColor(&.{
                                    canvas.screenFromDataPoint(.{ .x = bbox_max_x, .y = y_c }),
                                    canvas.screenFromDataPoint(.{ .x = cell_right, .y = y_c }),
                                }, 1, dim_inner_h);
                                doubleStrokeDimensionTickColor(&.{
                                    canvas.screenFromDataPoint(.{ .x = bbox_max_x, .y = y_c - arm_y_data }),
                                    canvas.screenFromDataPoint(.{ .x = bbox_max_x, .y = y_c + arm_y_data }),
                                }, dim_tick_thick, dim_inner_h);
                                doubleStrokeDimensionTickColor(&.{
                                    canvas.screenFromDataPoint(.{ .x = cell_right, .y = y_c - arm_y_data }),
                                    canvas.screenFromDataPoint(.{ .x = cell_right, .y = y_c + arm_y_data }),
                                }, dim_tick_thick, dim_inner_h);
                                const t = std.fmt.allocPrint(arena, "{d}", .{@as(i32, @intFromFloat(@round(span)))}) catch "—";
                                var lp = canvas.screenFromDataPoint(.{ .x = (bbox_max_x + cell_right) * 0.5, .y = y_c });
                                lp.x += label_off_screen;
                                renderTransformDimLabel(dim_font, t, lp);
                            }
                        }
                        // Top: horizontal center of top edge → cell top
                        {
                            const span = bbox_min_y - cell_top;
                            if (@abs(span) > 0.001) {
                                doubleStrokeDimensionTickColor(&.{
                                    canvas.screenFromDataPoint(.{ .x = x_c, .y = cell_top }),
                                    canvas.screenFromDataPoint(.{ .x = x_c, .y = bbox_min_y }),
                                }, 1, dim_inner_v);
                                doubleStrokeDimensionTickColor(&.{
                                    canvas.screenFromDataPoint(.{ .x = x_c - arm_x_data, .y = cell_top }),
                                    canvas.screenFromDataPoint(.{ .x = x_c + arm_x_data, .y = cell_top }),
                                }, dim_tick_thick, dim_inner_v);
                                doubleStrokeDimensionTickColor(&.{
                                    canvas.screenFromDataPoint(.{ .x = x_c - arm_x_data, .y = bbox_min_y }),
                                    canvas.screenFromDataPoint(.{ .x = x_c + arm_x_data, .y = bbox_min_y }),
                                }, dim_tick_thick, dim_inner_v);
                                const t = std.fmt.allocPrint(arena, "{d}", .{@as(i32, @intFromFloat(@round(span)))}) catch "—";
                                var lp = canvas.screenFromDataPoint(.{ .x = x_c, .y = (cell_top + bbox_min_y) * 0.5 });
                                lp.y -= label_off_screen;
                                renderTransformDimLabel(dim_font, t, lp);
                            }
                        }
                        // Bottom: bbox bottom → cell bottom
                        {
                            const span = cell_bot - bbox_max_y;
                            if (@abs(span) > 0.001) {
                                doubleStrokeDimensionTickColor(&.{
                                    canvas.screenFromDataPoint(.{ .x = x_c, .y = bbox_max_y }),
                                    canvas.screenFromDataPoint(.{ .x = x_c, .y = cell_bot }),
                                }, 1, dim_inner_v);
                                doubleStrokeDimensionTickColor(&.{
                                    canvas.screenFromDataPoint(.{ .x = x_c - arm_x_data, .y = bbox_max_y }),
                                    canvas.screenFromDataPoint(.{ .x = x_c + arm_x_data, .y = bbox_max_y }),
                                }, dim_tick_thick, dim_inner_v);
                                doubleStrokeDimensionTickColor(&.{
                                    canvas.screenFromDataPoint(.{ .x = x_c - arm_x_data, .y = cell_bot }),
                                    canvas.screenFromDataPoint(.{ .x = x_c + arm_x_data, .y = cell_bot }),
                                }, dim_tick_thick, dim_inner_v);
                                const t = std.fmt.allocPrint(arena, "{d}", .{@as(i32, @intFromFloat(@round(span)))}) catch "—";
                                var lp = canvas.screenFromDataPoint(.{ .x = x_c, .y = (bbox_max_y + cell_bot) * 0.5 });
                                lp.y += label_off_screen;
                                renderTransformDimLabel(dim_font, t, lp);
                            }
                        }

                        // Transform width (bottom edge) and height (left edge): labels only, no dimension lines.
                        {
                            const top_left_v = triangles.vertexes[0].pos;
                            const bottom_left_v = triangles.vertexes[3].pos;
                            const bottom_right_v = triangles.vertexes[2].pos;

                            const offset_v = fizzy.math.rotate(
                                dvui.Point{ .x = label_off_screen, .y = 0 },
                                .{ .x = 0, .y = 0 },
                                transform.rotation,
                            );
                            const off_v: dvui.Point.Physical = .{ .x = offset_v.x, .y = offset_v.y };

                            const center_v = top_left_v.plus(bottom_left_v).scale(0.5, dvui.Point.Physical);
                            const inner_h_f = transform.data_points[0].diff(transform.data_points[3]).length();
                            const simple_v = std.fmt.allocPrint(arena, "{d}", .{@as(i32, @intFromFloat(@round(inner_h_f)))}) catch "—";
                            renderTransformDimLabel(dim_font, simple_v, center_v.plus(off_v));

                            const offset_h = fizzy.math.rotate(
                                dvui.Point{ .x = 0, .y = -label_off_screen },
                                .{ .x = 0, .y = 0 },
                                transform.rotation,
                            );
                            const off_h: dvui.Point.Physical = .{ .x = offset_h.x, .y = offset_h.y };

                            const center_h = bottom_right_v.plus(bottom_left_v).scale(0.5, dvui.Point.Physical);
                            const inner_w_f = transform.data_points[3].diff(transform.data_points[2]).length();
                            const simple_h = std.fmt.allocPrint(arena, "{d}", .{@as(i32, @intFromFloat(@round(inner_w_f)))}) catch "—";
                            renderTransformDimLabel(dim_font, simple_h, center_h.plus(off_h));
                        }
                    } else {
                        const top_left = triangles.vertexes[0].pos;
                        const bottom_left = triangles.vertexes[3].pos;
                        const bottom_right = triangles.vertexes[2].pos;

                        const offset_v = fizzy.math.rotate(
                            dvui.Point{ .x = label_off_screen, .y = 0 },
                            .{ .x = 0, .y = 0 },
                            transform.rotation,
                        );
                        const off_v: dvui.Point.Physical = .{ .x = offset_v.x, .y = offset_v.y };

                        const center_v = top_left.plus(bottom_left).scale(0.5, dvui.Point.Physical);
                        const inner_h_f = transform.data_points[0].diff(transform.data_points[3]).length();
                        const simple_v = std.fmt.allocPrint(
                            dvui.currentWindow().arena(),
                            "{d}",
                            .{@as(i32, @intFromFloat(@round(inner_h_f)))},
                        ) catch "—";
                        renderTransformDimLabel(dim_font, simple_v, center_v.plus(off_v));

                        const offset_h = fizzy.math.rotate(
                            dvui.Point{ .x = 0, .y = -label_off_screen },
                            .{ .x = 0, .y = 0 },
                            transform.rotation,
                        );
                        const off_h: dvui.Point.Physical = .{ .x = offset_h.x, .y = offset_h.y };

                        const center_h = bottom_right.plus(bottom_left).scale(0.5, dvui.Point.Physical);
                        const inner_w_f = transform.data_points[3].diff(transform.data_points[2]).length();
                        const simple_h = std.fmt.allocPrint(
                            dvui.currentWindow().arena(),
                            "{d}",
                            .{@as(i32, @intFromFloat(@round(inner_w_f)))},
                        ) catch "—";
                        renderTransformDimLabel(dim_font, simple_h, center_h.plus(off_h));
                    }
                }

                if (transform.active_point == .rotate and !show_ortho_dims) {
                    // Draw a stroke from transform.point(.rotate).* to the point on the circle at the midpoint of the rotation arc,
                    // but if the arc is > 180 degrees, the midpoint angle needs to be flipped 180 degrees.
                    const pivot = transform.point(.pivot).*;
                    const radius = transform.radius;

                    // Find the angle of the start (drag) and end (current) rotation arms
                    const start_angle = blk: {
                        if (self.drag_data_point) |drag_data_point| {
                            const drag_diff = drag_data_point.diff(pivot);
                            break :blk std.math.atan2(drag_diff.y, drag_diff.x);
                        } else {
                            // Fallback: use current rotation
                            break :blk std.math.atan2(transform.point(.rotate).y - pivot.y, transform.point(.rotate).x - pivot.x);
                        }
                    };

                    // Compute the shortest arc between start and end
                    var delta_angle = transform.rotation - transform.start_rotation;
                    // Normalize to [-pi, pi]
                    if (delta_angle > std.math.pi) {
                        delta_angle -= 2.0 * std.math.pi;
                    } else if (delta_angle < -std.math.pi) {
                        delta_angle += 2.0 * std.math.pi;
                    }

                    // The midpoint angle along the arc
                    var mid_angle = start_angle + delta_angle / 2.0;

                    // If the arc is more than 180 degrees, flip the midpoint angle by 180 degrees
                    if (delta_angle < 0) {
                        mid_angle += std.math.pi;
                    }

                    // Calculate the point on the circle at the midpoint angle
                    const center = file.editor.canvas.screenFromDataPoint(pivot.plus(.{
                        .x = radius * (1.0 + 0.075 * dvui.currentWindow().natural_scale) * std.math.cos(mid_angle),
                        .y = radius * (1.0 + 0.075 * dvui.currentWindow().natural_scale) * std.math.sin(mid_angle),
                    }));

                    var degrees = std.math.radiansToDegrees(delta_angle);
                    if (degrees < 0) degrees += 360.0;

                    const angle_text = std.fmt.allocPrint(
                        dvui.currentWindow().arena(),
                        "{d}°",
                        .{@as(i32, @intFromFloat(@round(degrees)))},
                    ) catch "—";

                    renderTransformDimLabel(dim_font, angle_text, center);
                }
            }

            for (transform.data_points[0..6], 0..) |*point, point_index| {
                if (show_ortho_dims and point_index == 5) continue;
                if (transform.active_point) |active_point| {
                    if (active_point == .pivot) {
                        if (point_index == 5) continue; // skip drawing the rotate point if we are dragging the pivot
                    }
                }

                var screen_point = file.editor.canvas.screenFromDataPoint(point.*);

                // Use the triangle points for the corners
                if (point_index < 4)
                    screen_point = triangles.vertexes[point_index].pos;

                var screen_rect = dvui.Rect.Physical.fromPoint(screen_point);
                screen_rect.w = 16 * dvui.currentWindow().natural_scale;
                screen_rect.h = 16 * dvui.currentWindow().natural_scale;
                screen_rect.x -= screen_rect.w / 2;
                screen_rect.y -= screen_rect.h / 2;

                screen_rect.fill(dvui.Rect.Physical.all(100000), .{
                    .color = dvui.themeGet().color(.control, .fill),
                });

                screen_rect = screen_rect.inset(dvui.Rect.Physical.all(1 * dvui.currentWindow().natural_scale));

                var color = dvui.themeGet().color(.window, .text);

                if (transform.active_point) |active_point| {
                    if (active_point == @as(fizzy.Editor.Transform.TransformPoint, @enumFromInt(point_index))) {
                        color = dvui.themeGet().color(.highlight, .fill);
                    }
                } else if (screen_rect.contains(dvui.currentWindow().mouse_pt)) {
                    color = dvui.themeGet().color(.highlight, .fill);
                }

                screen_rect.fill(dvui.Rect.Physical.all(100000), .{
                    .color = color,
                });

                screen_rect = screen_rect.inset(dvui.Rect.Physical.all(2 * dvui.currentWindow().natural_scale));
                screen_rect.fill(dvui.Rect.Physical.all(100000), .{
                    .color = dvui.themeGet().color(.control, .fill),
                });
            }
        }
    }
}

/// Text size in physical pixels for `renderText` with `.rs.s == render_s` (must stay in sync with
/// `dvui.renderText` / `Font.textSizeEx` fraction rules).
fn transformDimTextSizePhysical(font: dvui.Font, text: []const u8, render_s: f32) dvui.Size {
    if (text.len == 0 or render_s == 0) return .{};
    const cw = dvui.currentWindow();
    const target_size = font.size * render_s;
    const sized_font = font.withSize(target_size);
    const fce = dvui.fontCacheGet(sized_font) catch return .{};
    const target_fraction = if (cw.snap_to_pixels) 1.0 else target_size / fce.em_height;
    var opts: dvui.Font.TextSizeOptions = .{};
    opts.kerning = cw.kerning;
    const s = fce.textSizeRaw(cw.gpa, text, opts) catch return .{};
    return s.scale(target_fraction, dvui.Size);
}

/// Constant on-screen size: render at `natural_scale` only.
fn renderTransformDimLabel(font: dvui.Font, text: []const u8, center_phys: dvui.Point.Physical) void {
    const ns = dvui.currentWindow().natural_scale;
    const ts = transformDimTextSizePhysical(font, text, ns);
    const pad = 2 * ns;
    const text_rect = dvui.Rect.Physical.rect(
        center_phys.x - ts.w / 2,
        center_phys.y - ts.h / 2,
        ts.w,
        ts.h,
    );
    var outline_rect = text_rect.outsetAll(pad);
    const corner = @min(4 * ns, @min(outline_rect.w, outline_rect.h) * 0.48);
    outline_rect.fill(dvui.Rect.Physical.all(corner), .{
        .color = dvui.themeGet().color(.control, .fill).opacity(0.85),
    });
    dvui.renderText(.{
        .text = text,
        .font = font,
        .color = dvui.themeGet().color(.window, .text),
        .rs = .{ .r = text_rect, .s = ns },
    }) catch {
        dvui.log.err("Failed to render transform dimension label", .{});
    };
}

fn doubleStroke(points: []const dvui.Point.Physical, color: dvui.Color, thickness: f32) void {
    dvui.Path.stroke(.{
        .points = points,
    }, .{
        .thickness = thickness * 2 * dvui.currentWindow().natural_scale,
        .color = dvui.themeGet().color(.control, .fill),
    });
    dvui.Path.stroke(.{
        .points = points,
    }, .{
        .thickness = thickness,
        .color = color,
    });
}

/// Double stroke for dimension lines: outer control fill, inner accent color.
fn doubleStrokeDimensionLike(points: []const dvui.Point.Physical, thickness: f32, inner_thickness: f32, inner_color: dvui.Color) void {
    const ns = dvui.currentWindow().natural_scale;
    dvui.Path.stroke(.{
        .points = points,
    }, .{
        .thickness = thickness * 2 * ns,
        .color = dvui.themeGet().color(.control, .fill),
    });
    dvui.Path.stroke(.{
        .points = points,
    }, .{
        .thickness = inner_thickness,
        .color = inner_color,
    });
}

fn doubleStrokeDimension(points: []const dvui.Point.Physical, thickness: f32) void {
    doubleStrokeDimensionLike(points, thickness, thickness, .magenta);
}

/// Tick marks: inner stroke is one physical pixel thicker for visibility.
fn doubleStrokeDimensionTick(points: []const dvui.Point.Physical, thickness: f32) void {
    doubleStrokeDimensionLike(points, thickness, thickness + 1.0, .magenta);
}

fn doubleStrokeDimensionTickColor(points: []const dvui.Point.Physical, thickness: f32, inner_color: dvui.Color) void {
    doubleStrokeDimensionLike(points, thickness, thickness + 1.0, inner_color);
}

/// Batches all grid lines into a single draw call. Each line becomes a thin
/// axis-aligned quad (4 vertices, 2 triangles) submitted via one `renderTriangles`.
fn drawBatchedGridLines(
    self: *FileWidget,
    file: *fizzy.Internal.File,
    columns: usize,
    rows: usize,
    grid_color: dvui.Color,
    grid_thickness: f32,
    grid_x0: f32,
    grid_x1: f32,
    grid_y0: f32,
    grid_y1: f32,
    vertical_inner: usize,
) void {
    const canvas = &self.init_options.file.editor.canvas;
    const half = @max(grid_thickness, 1.0) * 0.5;

    const cw = dvui.currentWindow();
    const pma_col: dvui.Color.PMA = .fromColor(grid_color.opacity(cw.alpha));

    var max_lines: usize = 0;
    if (vertical_inner > 1) max_lines += vertical_inner - 1;
    if (columns > file.columns) max_lines += columns - file.columns;
    max_lines += file.spriteCount();
    if (columns > file.columns) {
        const row_horiz_end = if (rows > file.rows) file.rows else rows;
        if (row_horiz_end > 1) max_lines += row_horiz_end - 1;
    }
    if (rows > file.rows) max_lines += rows - file.rows;
    if (self.resize_data_point != null) max_lines += 2;

    if (max_lines == 0) return;

    var builder = dvui.Triangles.Builder.init(cw.arena(), max_lines * 4, max_lines * 6) catch return;
    defer builder.deinit(cw.arena());

    const screen_y0 = canvas.screenFromDataPoint(.{ .x = 0, .y = grid_y0 }).y;
    const screen_y1 = canvas.screenFromDataPoint(.{ .x = 0, .y = grid_y1 }).y;

    const grid_pan = bubblePanSharedForGrid(self);

    // Vertical lines: inner columns
    for (1..vertical_inner) |i| {
        const x = @as(f32, @floatFromInt(i * file.column_width));
        const sx = canvas.screenFromDataPoint(.{ .x = x, .y = 0 }).x;
        appendLineQuad(&builder, .{ .x = sx - half, .y = screen_y0 }, .{ .x = sx + half, .y = screen_y1 }, pma_col);
    }

    // Vertical lines: preview columns beyond the sprite grid
    if (columns > file.columns) {
        for (file.columns..columns) |k| {
            const x = @as(f32, @floatFromInt(k * file.column_width));
            const sx = canvas.screenFromDataPoint(.{ .x = x, .y = 0 }).x;
            appendLineQuad(&builder, .{ .x = sx - half, .y = screen_y0 }, .{ .x = sx + half, .y = screen_y1 }, pma_col);
        }
    }

    // Horizontal lines: sprite row-top edges (visible rows/columns; coalesce runs without bubbles)
    if (fileCanvasVisibleGridParams(file)) |gp| {
        if (gp.vx1 > 0) {
            var row: usize = @max(1, gp.first_vis_row);
            while (row < gp.last_vis_row) : (row += 1) {
                const row_start = row * gp.cols;
                const row_end = @min(row_start + gp.cols, file.spriteCount());
                if (row_end <= row_start) continue;

                const row_span = row_end - row_start;
                var col_lo: usize = 0;
                if (gp.vx0 > 0) col_lo = @intFromFloat(@floor(gp.vx0 / gp.col_w));
                var col_hi_excl: usize = @intFromFloat(@ceil(gp.vx1 / gp.col_w));
                col_lo = @min(col_lo, row_span);
                col_hi_excl = @min(col_hi_excl, row_span);
                appendHorizontalGridRunsForRow(self, &builder, canvas, grid_pan, row, row_start, col_lo, col_hi_excl, gp.col_w, gp.row_h, half, pma_col);
            }
        }
    }

    // Horizontal lines: extended strip rows (wider preview than sprite grid)
    if (columns > file.columns) {
        const x_strip = @as(f32, @floatFromInt(file.columns * file.column_width));
        const row_horiz_end = if (rows > file.rows) file.rows else rows;
        for (1..row_horiz_end) |k| {
            const y = @as(f32, @floatFromInt(k * file.row_height));
            const sl = canvas.screenFromDataPoint(.{ .x = x_strip, .y = y });
            const sr = canvas.screenFromDataPoint(.{ .x = grid_x1, .y = y });
            appendLineQuad(&builder, .{ .x = sl.x, .y = sl.y - half }, .{ .x = sr.x, .y = sr.y + half }, pma_col);
        }
    }

    // Horizontal lines: preview rows beyond the sprite grid
    if (rows > file.rows) {
        for (file.rows..rows) |k| {
            const y = @as(f32, @floatFromInt(k * file.row_height));
            const sl = canvas.screenFromDataPoint(.{ .x = grid_x0, .y = y });
            const sr = canvas.screenFromDataPoint(.{ .x = grid_x1, .y = y });
            appendLineQuad(&builder, .{ .x = sl.x, .y = sl.y - half }, .{ .x = sr.x, .y = sr.y + half }, pma_col);
        }
    }

    // Resize guide lines
    if (self.resize_data_point) |resize_data_point| {
        const rx = canvas.screenFromDataPoint(.{ .x = resize_data_point.x, .y = 0 }).x;
        appendLineQuad(&builder, .{ .x = rx - half, .y = screen_y0 }, .{ .x = rx + half, .y = screen_y1 }, pma_col);

        const ry = canvas.screenFromDataPoint(.{ .x = 0, .y = resize_data_point.y }).y;
        const sx0 = canvas.screenFromDataPoint(.{ .x = grid_x0, .y = 0 }).x;
        const sx1 = canvas.screenFromDataPoint(.{ .x = grid_x1, .y = 0 }).x;
        appendLineQuad(&builder, .{ .x = sx0, .y = ry - half }, .{ .x = sx1, .y = ry + half }, pma_col);
    }

    if (builder.vertexes.items.len == 0) return;

    const tris = builder.build_unowned();
    dvui.renderTriangles(tris, null) catch {
        dvui.log.err("Failed to render batched grid lines", .{});
    };
}

/// Appends a single axis-aligned quad (4 vertices, 2 triangles) from `tl` to `br`.
fn appendLineQuad(builder: *dvui.Triangles.Builder, tl: dvui.Point.Physical, br: dvui.Point.Physical, col: dvui.Color.PMA) void {
    const base: dvui.Vertex.Index = @intCast(builder.vertexes.items.len);
    builder.appendVertex(.{ .pos = tl, .col = col });
    builder.appendVertex(.{ .pos = .{ .x = br.x, .y = tl.y }, .col = col });
    builder.appendVertex(.{ .pos = br, .col = col });
    builder.appendVertex(.{ .pos = .{ .x = tl.x, .y = br.y }, .col = col });
    builder.appendTriangles(&.{ base, base + 1, base + 2, base, base + 2, base + 3 });
}

/// Viewport in data space + row/column index range for culling (matches bubble / grid logic).
fn fileCanvasVisibleGridParams(file: *fizzy.Internal.File) ?struct {
    visible_data: dvui.Rect,
    row_h: f32,
    col_w: f32,
    cols: usize,
    first_vis_row: usize,
    last_vis_row: usize,
    vx0: f32,
    vx1: f32,
} {
    const canvas = &file.editor.canvas;
    const visible_data = canvas.dataFromScreenRect(canvas.rect);
    const total_rows = file.rows;
    const cols = file.columns;
    if (total_rows == 0 or cols == 0) return null;
    const row_h: f32 = @floatFromInt(file.row_height);
    const col_w: f32 = @floatFromInt(file.column_width);
    if (row_h <= 0 or col_w <= 0) return null;
    const bubble_headroom = @max(row_h, col_w);
    const max_row_f: f32 = @floatFromInt(total_rows);
    const first_vis_f = (visible_data.y - bubble_headroom) / row_h;
    const first_vis_row: usize = if (first_vis_f > 0 and first_vis_f < max_row_f)
        @intFromFloat(first_vis_f)
    else if (first_vis_f >= max_row_f)
        total_rows
    else
        0;
    const last_vis_f = (visible_data.y + visible_data.h) / row_h + 2.0;
    const last_vis_row: usize = if (last_vis_f > 0 and last_vis_f < max_row_f)
        @intFromFloat(last_vis_f)
    else if (last_vis_f >= max_row_f)
        total_rows
    else
        0;
    return .{
        .visible_data = visible_data,
        .row_h = row_h,
        .col_w = col_w,
        .cols = cols,
        .first_vis_row = first_vis_row,
        .last_vis_row = last_vis_row,
        .vx0 = visible_data.x,
        .vx1 = visible_data.x + visible_data.w,
    };
}

/// Horizontal grid segments along row tops: one quad per maximal run of sprites without a bubble arc.
fn appendHorizontalGridRunsForRow(
    self: *FileWidget,
    builder: *dvui.Triangles.Builder,
    canvas: *CanvasWidget,
    grid_pan: ?BubblePanShared,
    row: usize,
    row_start: usize,
    col_lo: usize,
    col_hi_excl: usize,
    col_w: f32,
    row_h: f32,
    half: f32,
    pma_col: dvui.Color.PMA,
) void {
    if (col_lo >= col_hi_excl) return;
    var col = col_lo;
    while (col < col_hi_excl) {
        const si0 = row_start + col;
        if (self.spriteDrawsBubbleTopEdge(si0, grid_pan)) {
            col += 1;
            continue;
        }
        const run_start = col;
        col += 1;
        while (col < col_hi_excl) : (col += 1) {
            if (self.spriteDrawsBubbleTopEdge(row_start + col, grid_pan)) break;
        }
        const run_end_excl = col;
        const x_left = @as(f32, @floatFromInt(run_start)) * col_w;
        const x_right = @as(f32, @floatFromInt(run_end_excl)) * col_w;
        const y_top = @as(f32, @floatFromInt(row)) * row_h;
        const tl = canvas.screenFromDataPoint(.{ .x = x_left, .y = y_top });
        const tr = canvas.screenFromDataPoint(.{ .x = x_right, .y = y_top });
        appendLineQuad(builder, .{ .x = tl.x, .y = tl.y - half }, .{ .x = tr.x, .y = tr.y + half }, pma_col);
    }
}

/// Batches grid lines for the resize-shrink overlay (original layer_rect shown in error tint).
fn drawBatchedResizeOverlayGrid(
    self: *FileWidget,
    file: *fizzy.Internal.File,
    columns: usize,
    layer_rect: dvui.Rect,
    grid_thickness: f32,
) void {
    const canvas = &self.init_options.file.editor.canvas;
    const half = @max(grid_thickness, 1.0) * 0.5;
    const cw = dvui.currentWindow();
    const pma_col: dvui.Color.PMA = .fromColor(dvui.themeGet().color(.window, .fill).opacity(cw.alpha));

    var max_lines: usize = 0;
    if (columns > 1) max_lines += columns - 1;
    max_lines += file.spriteCount();
    if (max_lines == 0) return;

    var builder = dvui.Triangles.Builder.init(cw.arena(), max_lines * 4, max_lines * 6) catch return;
    defer builder.deinit(cw.arena());

    const screen_y0 = canvas.screenFromDataPoint(.{ .x = 0, .y = layer_rect.y }).y;
    const screen_y1 = canvas.screenFromDataPoint(.{ .x = 0, .y = layer_rect.y + layer_rect.h }).y;

    const grid_pan = bubblePanSharedForGrid(self);

    for (1..columns) |i| {
        const gx = @as(f32, @floatFromInt(i * file.column_width));
        const sx = canvas.screenFromDataPoint(.{ .x = gx, .y = 0 }).x;
        appendLineQuad(&builder, .{ .x = sx - half, .y = screen_y0 }, .{ .x = sx + half, .y = screen_y1 }, pma_col);
    }

    if (fileCanvasVisibleGridParams(file)) |gp| {
        if (gp.vx1 > 0) {
            var row: usize = @max(1, gp.first_vis_row);
            while (row < gp.last_vis_row) : (row += 1) {
                const row_start = row * gp.cols;
                const row_end = @min(row_start + gp.cols, file.spriteCount());
                if (row_end <= row_start) continue;

                const row_span = row_end - row_start;
                var col_lo: usize = 0;
                if (gp.vx0 > 0) col_lo = @intFromFloat(@floor(gp.vx0 / gp.col_w));
                var col_hi_excl: usize = @intFromFloat(@ceil(gp.vx1 / gp.col_w));
                col_lo = @min(col_lo, row_span);
                col_hi_excl = @min(col_hi_excl, row_span);
                appendHorizontalGridRunsForRow(self, &builder, canvas, grid_pan, row, row_start, col_lo, col_hi_excl, gp.col_w, gp.row_h, half, pma_col);
            }
        }
    }

    if (builder.vertexes.items.len == 0) return;

    const tris = builder.build_unowned();
    dvui.renderTriangles(tris, null) catch {
        dvui.log.err("Failed to render batched resize overlay grid", .{});
    };
}

fn checkerboardGridColorBilinear(c_tl: dvui.Color, c_tr: dvui.Color, c_bl: dvui.Color, c_br: dvui.Color, u: f32, v: f32) dvui.Color {
    const top = c_tl.lerp(c_tr, u);
    const bottom = c_bl.lerp(c_br, u);
    return top.lerp(bottom, v);
}

/// Near the smoothed mouse (mu, mv): flat `tone` (normal checkerboard tint). Far away: full bilinear corner colors at (u, v).
fn checkerboardVertexColor(
    c_tl: dvui.Color,
    c_tr: dvui.Color,
    c_bl: dvui.Color,
    c_br: dvui.Color,
    u: f32,
    v: f32,
    mu: f32,
    mv: f32,
    tone: dvui.Color,
) dvui.Color {
    const c_corner = checkerboardGridColorBilinear(c_tl, c_tr, c_bl, c_br, u, v);

    const du = u - mu;
    const dv = v - mv;
    const dist = math.sqrt(du * du + dv * dv);
    // 0 at cursor → tone only; 1 far away → full corner UV gradient (scaled for visible falloff in 0..1 UV space)
    var t = math.clamp(dist * 1.55, 0, 1);
    t = t * t * (3.0 - 2.0 * t);

    return tone.lerp(c_corner, t);
}

/// Animation color for transparency tint; matches bubble arc palette lookup order (selected animation first, else first containing animation).
fn spriteAnimationPaletteColor(file: *fizzy.Internal.File, sprite_index: usize) ?dvui.Color {
    if (fizzy.editor.colors.file_tree_palette) |*palette| {
        var animation_index: ?usize = null;

        if (file.selected_animation_index) |selected_animation_index| {
            for (file.animations.items(.frames)[selected_animation_index]) |frame| {
                if (frame.sprite_index == sprite_index) {
                    animation_index = selected_animation_index;
                    break;
                }
            }
        }

        if (animation_index == null) {
            anim_blk: for (file.animations.items(.frames), 0..) |frames, i| {
                for (frames) |frame| {
                    if (frame.sprite_index == sprite_index) {
                        animation_index = i;
                        break :anim_blk;
                    }
                }
            }
        }

        if (animation_index) |ai| {
            const id = file.animations.get(ai).id;
            return palette.getDVUIColor(@intCast(id));
        }
    }
    return null;
}

fn checkerboardCellCornerColor(
    effect: fizzy.Editor.Settings.TransparencyEffect,
    file: *fizzy.Internal.File,
    sprite_index: usize,
    c_tl: dvui.Color,
    c_tr: dvui.Color,
    c_bl: dvui.Color,
    c_br: dvui.Color,
    u: f32,
    v: f32,
    mu: f32,
    mv: f32,
    tone: dvui.Color,
) dvui.Color {
    switch (effect) {
        .none => return tone,
        .rainbow => return checkerboardVertexColor(c_tl, c_tr, c_bl, c_br, u, v, mu, mv, tone),
        .animation => {
            if (spriteAnimationPaletteColor(file, sprite_index)) |ac| {
                const row = file.rowFromIndex(sprite_index);
                const rows_f = @max(@as(f32, @floatFromInt(file.rows)), 1.0);
                const v_cell_top = @as(f32, @floatFromInt(row)) / rows_f;
                const v_cell_bot = @as(f32, @floatFromInt(row + 1)) / rows_f;
                const v_mid = (v_cell_top + v_cell_bot) * 0.5;
                // Top of cell: normal tone; bottom: animation tint (fade upward across the cell).
                if (v <= v_mid) return tone;
                return tone.lerp(ac, 0.4);
            }
            return tone;
        },
    }
}

fn checkerboardGridPalette() struct { tone: dvui.Color, c_tl: dvui.Color, c_tr: dvui.Color, c_bl: dvui.Color, c_br: dvui.Color } {
    const tone = dvui.themeGet().color(.content, .fill).lighten(6.0).opacity(0.5).opacity(dvui.currentWindow().alpha);
    const c_tl = tone;
    const c_tr = tone.lerp(.red, 0.18);
    const c_bl = tone.lerp(.blue, 0.12);
    const c_br = c_tr.lerp(c_bl, 0.5);
    return .{ .tone = tone, .c_tl = c_tl, .c_tr = c_tr, .c_bl = c_bl, .c_br = c_br };
}

/// Same tint as the batched checkerboard for the cell under `sprite_index` (center UV), for bubbles etc.
fn checkerboardTintAtSpriteCellCenter(file: *fizzy.Internal.File, sprite_index: usize) dvui.Color {
    const pal = checkerboardGridPalette();
    const tone = pal.tone;
    switch (fizzy.editor.settings.transparency_effect) {
        .none => return tone,
        .rainbow => {
            const mu_mv = dvui.dataGet(null, file.editor.canvas.id, "checkerboard_mouse_uv", dvui.Point) orelse dvui.Point{ .x = 0.5, .y = 0.5 };
            const cols_f = @max(@as(f32, @floatFromInt(file.columns)), 1.0);
            const rows_f = @max(@as(f32, @floatFromInt(file.rows)), 1.0);
            const col = file.columnFromIndex(sprite_index);
            const row = file.rowFromIndex(sprite_index);
            const u = (@as(f32, @floatFromInt(col)) + 0.5) / cols_f;
            const v = (@as(f32, @floatFromInt(row)) + 0.5) / rows_f;
            return checkerboardVertexColor(pal.c_tl, pal.c_tr, pal.c_bl, pal.c_br, u, v, mu_mv.x, mu_mv.y, tone);
        },
        // Bubbles: base checkerboard tone only (no animation palette tint; that applies on the canvas grid).
        .animation => return tone,
    }
}

/// Checkerboard behind layers: one batched quad per visible cell (UV 0..1 per cell so the tile repeats
/// with CLAMP_TO_EDGE textures). Vertex colors vary for rainbow / animation effects.
fn drawCheckerboardCellsBatched(file: *fizzy.Internal.File) void {
    const n = file.spriteCount();
    if (n == 0) return;

    const te = fizzy.editor.settings.transparency_effect;
    const pal = checkerboardGridPalette();
    const tone = pal.tone;
    const rs = file.editor.canvas.screen_rect_scale;

    // One quad per cell with UV 0..1 so the checker tile repeats correctly (textures use
    // CLAMP_TO_EDGE on web and desktop; a single quad with UV > 1 would not tile).
    const gp = fileCanvasVisibleGridParams(file) orelse return;
    if (gp.first_vis_row >= gp.last_vis_row or gp.vx1 <= 0) return;

    const arena = dvui.currentWindow().arena();
    var builder = dvui.Triangles.Builder.init(arena, n * 4, n * 6) catch {
        dvui.log.err("Failed to allocate checkerboard batch", .{});
        return;
    };
    defer builder.deinit(arena);

    const c_tl = pal.c_tl;
    const c_tr = pal.c_tr;
    const c_bl = pal.c_bl;
    const c_br = pal.c_br;

    const cols_f = @max(@as(f32, @floatFromInt(file.columns)), 1.0);
    const rows_f = @max(@as(f32, @floatFromInt(file.rows)), 1.0);

    const canvas = file.editor.canvas;
    const mouse_screen = dvui.currentWindow().mouse_pt;
    var target_mu: f32 = 0.5;
    var target_mv: f32 = 0.5;
    if (canvas.rect.contains(mouse_screen)) {
        const md = canvas.screen_rect_scale.pointFromPhysical(mouse_screen);
        const fw = @as(f32, @floatFromInt(file.width()));
        const fh = @as(f32, @floatFromInt(file.height()));
        if (fw > 0) target_mu = math.clamp(md.x / fw, 0, 1);
        if (fh > 0) target_mv = math.clamp(md.y / fh, 0, 1);
    }

    const prev_uv = dvui.dataGet(null, canvas.id, "checkerboard_mouse_uv", dvui.Point) orelse dvui.Point{ .x = 0.5, .y = 0.5 };
    const smooth_t: f32 = 0.15;
    const mu = prev_uv.x + (target_mu - prev_uv.x) * smooth_t;
    const mv = prev_uv.y + (target_mv - prev_uv.y) * smooth_t;
    dvui.dataSet(null, canvas.id, "checkerboard_mouse_uv", dvui.Point{ .x = mu, .y = mv });

    var quad_idx: usize = 0;
    var row: usize = gp.first_vis_row;
    while (row < gp.last_vis_row) : (row += 1) {
        const row_start = row * gp.cols;
        const row_end = @min(row_start + gp.cols, n);
        if (row_end <= row_start) continue;

        const row_span = row_end - row_start;
        var col_lo: usize = 0;
        if (gp.vx0 > 0) col_lo = @intFromFloat(@floor(gp.vx0 / gp.col_w));
        var col_hi_excl: usize = @intFromFloat(@ceil(gp.vx1 / gp.col_w));
        col_lo = @min(col_lo, row_span);
        col_hi_excl = @min(col_hi_excl, row_span);

        var col = col_lo;
        while (col < col_hi_excl) : (col += 1) {
            const i = row_start + col;
            const sr = file.spriteRect(i);
            if (gp.visible_data.intersect(sr).empty()) continue;

            const r = rs.rectToPhysical(sr);
            const tl = r.topLeft();
            const tr = r.topRight();
            const br = r.bottomRight();
            const bl = r.bottomLeft();

            const col_i = file.columnFromIndex(i);
            const row_i = file.rowFromIndex(i);
            const u_left = @as(f32, @floatFromInt(col_i)) / cols_f;
            const u_right = @as(f32, @floatFromInt(col_i + 1)) / cols_f;
            const v_top = @as(f32, @floatFromInt(row_i)) / rows_f;
            const v_bot = @as(f32, @floatFromInt(row_i + 1)) / rows_f;

            const pma_tl = dvui.Color.PMA.fromColor(checkerboardCellCornerColor(te, file, i, c_tl, c_tr, c_bl, c_br, u_left, v_top, mu, mv, tone));
            const pma_tr = dvui.Color.PMA.fromColor(checkerboardCellCornerColor(te, file, i, c_tl, c_tr, c_bl, c_br, u_right, v_top, mu, mv, tone));
            const pma_br = dvui.Color.PMA.fromColor(checkerboardCellCornerColor(te, file, i, c_tl, c_tr, c_bl, c_br, u_right, v_bot, mu, mv, tone));
            const pma_bl = dvui.Color.PMA.fromColor(checkerboardCellCornerColor(te, file, i, c_tl, c_tr, c_bl, c_br, u_left, v_bot, mu, mv, tone));

            builder.appendVertex(.{ .pos = tl, .col = pma_tl, .uv = .{ 0, 0 } });
            builder.appendVertex(.{ .pos = tr, .col = pma_tr, .uv = .{ 1, 0 } });
            builder.appendVertex(.{ .pos = br, .col = pma_br, .uv = .{ 1, 1 } });
            builder.appendVertex(.{ .pos = bl, .col = pma_bl, .uv = .{ 0, 1 } });

            const quad_base: dvui.Vertex.Index = @intCast(quad_idx * 4);
            builder.appendTriangles(&.{ quad_base + 1, quad_base + 0, quad_base + 3, quad_base + 1, quad_base + 3, quad_base + 2 });
            quad_idx += 1;
        }
    }

    if (quad_idx == 0) return;

    const triangles = builder.build();
    dvui.renderTriangles(triangles, file.editor.checkerboard_tile.getTexture() catch null) catch {
        dvui.log.err("Failed to render batched checkerboard", .{});
    };
}

pub fn active(self: *FileWidget) bool {
    if (fizzy.editor.activeFile()) |file| {
        if (file.id == self.init_options.file.id) {
            return true;
        }
    }
    return false;
}

pub fn drawCursor(self: *FileWidget) void {
    if (fizzy.editor.tools.current == .pointer and self.sample_data_point == null) return;
    if (fizzy.editor.tools.radial_menu.visible) return;
    if (self.init_options.file.editor.transform != null) return;

    var subtract = false;
    var add = false;

    if (self.init_options.file.editor.canvas.hovered) {
        _ = dvui.cursorSet(.hidden);
    }

    for (dvui.events()) |*e| {
        if (!self.init_options.file.editor.canvas.scroll_container.matchEvent(e)) {
            continue;
        }
        switch (e.evt) {
            .key => |ke| {
                if (ke.mod.matchBind("shift")) {
                    subtract = true;
                } else if (ke.mod.matchBind("ctrl/cmd")) {
                    add = true;
                }
            },
            .mouse => |me| {
                if (me.mod.matchBind("shift")) {
                    subtract = true;
                } else if (me.mod.matchBind("ctrl/cmd")) {
                    add = true;
                }
            },
            else => {},
        }
    }

    const data_point = self.init_options.file.editor.canvas.dataFromScreenPoint(dvui.currentWindow().mouse_pt);
    const mouse_point = dvui.currentWindow().mouse_pt;
    if (!self.init_options.file.editor.canvas.rect.contains(mouse_point)) return;
    if (self.sample_data_point != null) return;

    const selection_sprite = switch (fizzy.editor.tools.selection_mode) {
        .box => if (subtract) fizzy.editor.atlas.data.sprites[fizzy.atlas.sprites.box_selection_rem_default] else if (add) fizzy.editor.atlas.data.sprites[fizzy.atlas.sprites.box_selection_add_default] else fizzy.editor.atlas.data.sprites[fizzy.atlas.sprites.box_selection_default],
        .pixel => if (subtract) fizzy.editor.atlas.data.sprites[fizzy.atlas.sprites.pixel_selection_rem_default] else if (add) fizzy.editor.atlas.data.sprites[fizzy.atlas.sprites.pixel_selection_add_default] else fizzy.editor.atlas.data.sprites[fizzy.atlas.sprites.pixel_selection_default],
        .color => if (subtract) fizzy.editor.atlas.data.sprites[fizzy.atlas.sprites.color_selection_rem_default] else if (add) fizzy.editor.atlas.data.sprites[fizzy.atlas.sprites.color_selection_add_default] else fizzy.editor.atlas.data.sprites[fizzy.atlas.sprites.color_selection_default],
    };

    if (switch (fizzy.editor.tools.current) {
        .pencil => fizzy.editor.atlas.data.sprites[fizzy.atlas.sprites.pencil_default],
        .eraser => fizzy.editor.atlas.data.sprites[fizzy.atlas.sprites.eraser_default],
        .bucket => fizzy.editor.atlas.data.sprites[fizzy.atlas.sprites.bucket_default],
        .selection => selection_sprite,
        else => null,
    }) |sprite| {
        const atlas_size = dvui.imageSize(fizzy.editor.atlas.source) catch {
            dvui.log.err("Failed to get atlas size", .{});
            return;
        };

        const uv = dvui.Rect{
            .x = (@as(f32, @floatFromInt(sprite.source[0])) / atlas_size.w),
            .y = (@as(f32, @floatFromInt(sprite.source[1])) / atlas_size.h),
            .w = (@as(f32, @floatFromInt(sprite.source[2])) / atlas_size.w),
            .h = (@as(f32, @floatFromInt(sprite.source[3])) / atlas_size.h),
        };

        const origin = dvui.Point{
            .x = sprite.origin[0] * 1 / self.init_options.file.editor.canvas.scale,
            .y = sprite.origin[1] * 1 / self.init_options.file.editor.canvas.scale,
        };

        const position = data_point.diff(origin);

        const box = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .none,
            .rect = .{
                .x = position.x,
                .y = position.y,
                .w = @as(f32, @floatFromInt(sprite.source[2])) * 1 / self.init_options.file.editor.canvas.scale,
                .h = @as(f32, @floatFromInt(sprite.source[3])) * 1 / self.init_options.file.editor.canvas.scale,
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

        dvui.renderImage(fizzy.editor.atlas.source, rs, .{
            .uv = uv,
        }) catch {
            dvui.log.err("Failed to render cursor image", .{});
        };
    }
}

pub fn drawSample(self: *FileWidget) void {
    const file = self.init_options.file;
    const point = self.sample_data_point;

    if (point) |data_point| {
        const mouse_point = self.init_options.file.editor.canvas.screenFromDataPoint(data_point);
        if (!self.init_options.file.editor.canvas.rect.contains(mouse_point)) return;

        { // Draw a box around the hovered pixel at the correct scale
            const pixel_box_size = self.init_options.file.editor.canvas.scale * dvui.currentWindow().rectScale().s;

            const pixel_point: dvui.Point = .{
                .x = @round(data_point.x - 0.5),
                .y = @round(data_point.y - 0.5),
            };

            const pixel_box_point = self.init_options.file.editor.canvas.screenFromDataPoint(pixel_point);
            var pixel_box = dvui.Rect.Physical.fromSize(.{ .w = pixel_box_size, .h = pixel_box_size });
            pixel_box.x = pixel_box_point.x;
            pixel_box.y = pixel_box_point.y;
            dvui.Path.stroke(.{ .points = &.{
                pixel_box.topLeft(),
                pixel_box.topRight(),
                pixel_box.bottomRight(),
                pixel_box.bottomLeft(),
            } }, .{ .thickness = 2, .color = .white, .closed = true });
        }

        // The scale of the enlarged view varies based on the canvas scale
        // When canvas scale is small, we want more magnification
        // When canvas scale is large, we want less magnification
        const enlarged_scale: f32 = self.init_options.file.editor.canvas.scale * (8.0 / (1.0 + self.init_options.file.editor.canvas.scale));

        // The size of the sample box in screen space (constant size)
        const sample_box_size: f32 = 100.0 * 1 / self.init_options.file.editor.canvas.scale; // e.g. 100x80 pixels on screen

        const corner_radius = dvui.Rect{
            .y = 1000000,
            .w = 1000000,
            .h = 1000000,
        };

        // The size of the sample region in data (texture) space
        // This is how many data pixels are shown in the box, so that the box always shows the same number of data pixels at 2x the canvas scale
        const sample_region_size: f32 = sample_box_size / enlarged_scale;

        const border_width = 2 / self.init_options.file.editor.canvas.scale;

        // Position the sample box so that the data_point is at its center
        const box = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .none,
            .rect = .{
                .x = data_point.x,
                .y = data_point.y,
                .w = sample_box_size,
                .h = sample_box_size,
            },
            .border = dvui.Rect.all(border_width),
            .color_border = dvui.themeGet().color(.control, .text),
            .corner_radius = corner_radius,
            .background = true,
            .color_fill = dvui.themeGet().color(.window, .fill),
            .box_shadow = .{
                .fade = 15 * 1 / self.init_options.file.editor.canvas.scale,
                .corner_radius = .{
                    .x = sample_box_size / 12,
                    .y = sample_box_size / 2,
                    .w = sample_box_size / 2,
                    .h = sample_box_size / 2,
                },
                .alpha = 0.2,
                .offset = .{
                    .x = 2 * 1 / self.init_options.file.editor.canvas.scale,
                    .y = 2 * 1 / self.init_options.file.editor.canvas.scale,
                },
            },
        });
        defer box.deinit();

        // Compute UVs for the region to sample, normalized to [0,1]
        const uv_rect = dvui.Rect{
            .x = (data_point.x - sample_region_size / 2) / @as(f32, @floatFromInt(file.width())),
            .y = (data_point.y - sample_region_size / 2) / @as(f32, @floatFromInt(file.height())),
            .w = sample_region_size / @as(f32, @floatFromInt(file.width())),
            .h = sample_region_size / @as(f32, @floatFromInt(file.height())),
        };

        var rs = box.data().borderRectScale();
        rs.r = rs.r.inset(dvui.Rect.Physical.all(border_width * self.init_options.file.editor.canvas.scale * 2));

        const nat_scale: u32 = @intFromFloat(1.0);

        dvui.renderImage(file.editor.checkerboard_tile, rs, .{
            .colormod = dvui.themeGet().color(.content, .fill).lighten(12.0),
            .uv = .{
                .x = @mod(data_point.x - sample_region_size / 2, @as(f32, @floatFromInt(file.column_width * nat_scale))) / @as(f32, @floatFromInt(file.column_width * nat_scale)),
                .y = @mod(data_point.y - sample_region_size / 2, @as(f32, @floatFromInt(file.row_height * nat_scale))) / @as(f32, @floatFromInt(file.row_height * nat_scale)),
                .w = sample_region_size / @as(f32, @floatFromInt(file.column_width * nat_scale)),
                .h = sample_region_size / @as(f32, @floatFromInt(file.row_height * nat_scale)),
            },
            .corner_radius = .{
                .x = corner_radius.x * rs.s,
                .y = corner_radius.y * rs.s,
                .w = corner_radius.w * rs.s,
                .h = corner_radius.h * rs.s,
            },
        }) catch {
            dvui.log.err("Failed to render checkerboard", .{});
        };

        fizzy.render.renderLayers(.{
            .file = file,
            .rs = rs,
            .uv = uv_rect,
            .corner_radius = .{
                .x = corner_radius.x * rs.s,
                .y = corner_radius.y * rs.s,
                .w = corner_radius.w * rs.s,
                .h = corner_radius.h * rs.s,
            },
        }) catch {
            dvui.log.err("Failed to render layers", .{});
        };

        // Draw a cross at the center of the rounded sample box
        const center_x = rs.r.x + rs.r.w / 2;
        const center_y = rs.r.y + rs.r.h / 2;
        const cross_size = @min(rs.r.w, rs.r.h) * 0.2;

        dvui.Path.stroke(.{ .points = &.{
            .{ .x = center_x - cross_size / 2, .y = center_y },
            .{ .x = center_x + cross_size / 2, .y = center_y },
        } }, .{ .thickness = 4, .color = .white });

        dvui.Path.stroke(.{ .points = &.{
            .{ .x = center_x, .y = center_y - cross_size / 2 },
            .{ .x = center_x, .y = center_y + cross_size / 2 },
        } }, .{ .thickness = 4, .color = .white });

        dvui.Path.stroke(.{ .points = &.{
            .{ .x = center_x - cross_size / 2 + 4, .y = center_y },
            .{ .x = center_x + cross_size / 2 - 4, .y = center_y },
        } }, .{ .thickness = 2, .color = .black });

        dvui.Path.stroke(.{ .points = &.{
            .{ .x = center_x, .y = center_y - cross_size / 2 + 4 },
            .{ .x = center_x, .y = center_y + cross_size / 2 - 4 },
        } }, .{ .thickness = 2, .color = .black });
    }
}

pub fn updateActiveLayerMask(self: *FileWidget) void {
    var file = self.init_options.file;
    if (file.selected_layer_index >= file.layers.len) return;

    const source_hash = file.layers.items(.source)[file.selected_layer_index].hash();
    const cached = file.editor.mask_built_for_layer == file.selected_layer_index and
        file.editor.mask_built_source_hash == source_hash and
        dvui.textureGetCached(source_hash) != null;

    if (cached) return;

    var active_layer = file.layers.get(file.selected_layer_index);
    active_layer.clearMask();
    active_layer.setMaskFromTransparency(true);

    file.editor.mask_built_for_layer = file.selected_layer_index;
    file.editor.mask_built_source_hash = source_hash;
}

pub fn drawLayers(self: *FileWidget) void {
    const perf_t0 = fizzy.perf.drawLayersBegin();
    defer fizzy.perf.drawLayersEnd(perf_t0);

    var file = self.init_options.file;
    var columns: usize = file.columns;
    var rows: usize = file.rows;

    const layer_rect = self.init_options.file.editor.canvas.dataFromScreenRect(self.init_options.file.editor.canvas.rect);
    var canvas_rect = layer_rect;

    if (self.resize_data_point) |resize_data_point| {
        canvas_rect.w = resize_data_point.x;
        canvas_rect.h = resize_data_point.y;

        if (resize_data_point.x < layer_rect.x + layer_rect.w or resize_data_point.y < layer_rect.y + layer_rect.h) {
            const grid_thickness = std.math.clamp(dvui.currentWindow().natural_scale * self.init_options.file.editor.canvas.scale, 0, dvui.currentWindow().natural_scale);
            self.init_options.file.editor.canvas.screenFromDataRect(layer_rect).fill(.all(0), .{ .color = dvui.themeGet().color(.err, .fill).opacity(0.5), .fade = 1.5 });
            drawBatchedResizeOverlayGrid(self, file, columns, layer_rect, grid_thickness);
        }

        columns = @divTrunc(@as(u32, @intFromFloat(canvas_rect.w)), file.column_width);
        rows = @divTrunc(@as(u32, @intFromFloat(canvas_rect.h)), file.row_height);
    }

    const shadow_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .none,
        .rect = canvas_rect,
        .border = dvui.Rect.all(0),
        .box_shadow = .{
            .fade = 20 * 1 / self.init_options.file.editor.canvas.scale,
            .corner_radius = dvui.Rect.all(2 * 1 / self.init_options.file.editor.canvas.scale),
            .alpha = if (dvui.themeGet().dark) 0.4 else 0.2,
            .offset = .{
                .x = 2 * 1 / self.init_options.file.editor.canvas.scale,
                .y = 2 * 1 / self.init_options.file.editor.canvas.scale,
            },
        },
    });
    shadow_box.deinit();

    const fill_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .none,
        .rect = .{ .x = layer_rect.x, .y = layer_rect.y, .w = @min(canvas_rect.w, layer_rect.w), .h = @min(canvas_rect.h, layer_rect.h) },
        .border = dvui.Rect.all(0),
        .background = true,
        .color_fill = dvui.themeGet().color(.window, .fill),
    });
    fill_box.deinit();

    // Content fill + batched checkerboard (including resize and column/row reorder preview; skip during cell reorder).
    if (self.removed_sprite_indices == null) {
        const bg_rect = dvui.Rect{
            .x = layer_rect.x,
            .y = layer_rect.y,
            .w = @min(canvas_rect.w, layer_rect.w),
            .h = @min(canvas_rect.h, layer_rect.h),
        };
        const bg_screen = self.init_options.file.editor.canvas.screenFromDataRect(bg_rect);
        if (self.init_options.file.editor.canvas.scale < 0.1) {
            bg_screen.fill(.all(0), .{ .color = dvui.themeGet().color(.content, .fill), .fade = 1.5 });
        } else {
            bg_screen.fill(.all(0), .{ .color = dvui.themeGet().color(.content, .fill), .fade = 1.5 });
            drawCheckerboardCellsBatched(file);
        }
    }

    // Render all layers and update our bounding box;
    {
        if (self.removed_sprite_indices != null) {
            self.drawCellReorderPreview();
            return;
        } else if (file.editor.workspace.columns_drag_index != null or file.editor.workspace.rows_drag_index != null) {
            self.drawColumnRowReorderPreview();
            return;
        } else {
            fizzy.render.renderLayers(.{
                .file = file,
                .rs = .{
                    .r = self.init_options.file.editor.canvas.rect,
                    .s = self.init_options.file.editor.canvas.scale,
                },
            }) catch {
                dvui.log.err("Failed to render file image", .{});
                return;
            };
        }
    }

    // Draw the resize fill area if a resize is happening
    if (self.resize_data_point) |resize_data_point| {
        if (resize_data_point.x > layer_rect.x + layer_rect.w) {
            const new_tiles_rect = dvui.Rect{
                .x = layer_rect.topRight().x,
                .y = layer_rect.topRight().y,
                .w = resize_data_point.x - layer_rect.topRight().x,
                .h = @min(resize_data_point.y - layer_rect.topRight().y, layer_rect.h),
            };

            self.init_options.file.editor.canvas.screenFromDataRect(new_tiles_rect).fill(.all(0), .{ .color = dvui.themeGet().color(.highlight, .fill).opacity(0.5), .fade = 0.0 });
        }
        if (resize_data_point.y > layer_rect.y + layer_rect.h) {
            const new_tiles_rect = dvui.Rect{
                .x = layer_rect.topLeft().x,
                .y = layer_rect.bottomLeft().y,
                .w = resize_data_point.x,
                .h = resize_data_point.y - layer_rect.bottomLeft().y,
            };

            self.init_options.file.editor.canvas.screenFromDataRect(new_tiles_rect).fill(.all(0), .{ .color = dvui.themeGet().color(.highlight, .fill).opacity(0.5), .fade = 0.0 });
        }
    }

    // Draw the grid lines for the canvas as a single batched draw call.
    {
        const grid_color = dvui.themeGet().color(.control, .fill);
        const c_scale = self.init_options.file.editor.canvas.scale;
        const grid_thickness = std.math.clamp(dvui.currentWindow().natural_scale * c_scale, 0, dvui.currentWindow().natural_scale);
        const grid_y0 = canvas_rect.y;
        const grid_y1 = canvas_rect.y + canvas_rect.h;
        const grid_x0 = canvas_rect.x;
        const grid_x1 = canvas_rect.x + canvas_rect.w;
        const vertical_inner = @min(columns, file.columns);

        drawBatchedGridLines(self, file, columns, rows, grid_color, grid_thickness, grid_x0, grid_x1, grid_y0, grid_y1, vertical_inner);
    }

    // Draw the selection box for the selected sprites
    if (fizzy.editor.tools.current == .pointer and file.editor.transform == null and self.resize_data_point == null) {
        var iter = file.editor.selected_sprites.iterator(.{ .kind = .set, .direction = .forward });
        while (iter.next()) |i| {
            const sprite_rect = file.spriteRect(i);
            const sprite_rect_physical = self.init_options.file.editor.canvas.screenFromDataRect(sprite_rect);

            // Draw the origins when in the sprites pane
            if (fizzy.editor.explorer.pane == .sprites) {
                const origin: dvui.Point = .{ .x = sprite_rect.topLeft().x + file.sprites.get(i).origin[0], .y = sprite_rect.topLeft().y + file.sprites.get(i).origin[1] };

                const horizontal_line_start: dvui.Point = .{ .x = sprite_rect.topLeft().x, .y = origin.y };
                const horizontal_line_end: dvui.Point = .{ .x = sprite_rect.topRight().x, .y = origin.y };
                const vertical_line_start: dvui.Point = .{ .x = origin.x, .y = sprite_rect.topLeft().y };
                const vertical_line_end: dvui.Point = .{ .x = origin.x, .y = sprite_rect.bottomLeft().y };

                dvui.Path.stroke(.{ .points = &.{
                    file.editor.canvas.screenFromDataPoint(horizontal_line_start),
                    file.editor.canvas.screenFromDataPoint(horizontal_line_end),
                } }, .{ .thickness = 1, .color = dvui.themeGet().color(.err, .fill) });

                dvui.Path.stroke(.{ .points = &.{
                    file.editor.canvas.screenFromDataPoint(vertical_line_start),
                    file.editor.canvas.screenFromDataPoint(vertical_line_end),
                } }, .{ .thickness = 1, .color = dvui.themeGet().color(.err, .fill) });
            }

            sprite_rect_physical.inset(.all(dvui.currentWindow().natural_scale * 1.5)).stroke(dvui.Rect.Physical.all(@min(sprite_rect_physical.w, sprite_rect_physical.h) / 8), .{
                .thickness = 1.5 * dvui.currentWindow().natural_scale,
                .color = dvui.themeGet().color(.highlight, .fill),
                .closed = true,
            });
        }
    }
}

const ReorderAxis = enum { columns, rows };

fn mapDataRectToPhysicalStrip(sr: dvui.Rect, parent_data: dvui.Rect, parent_phys: dvui.Rect.Physical) dvui.Rect.Physical {
    const rel_x = sr.x - parent_data.x;
    const rel_y = sr.y - parent_data.y;
    return .{
        .x = parent_phys.x + rel_x / parent_data.w * parent_phys.w,
        .y = parent_phys.y + rel_y / parent_data.h * parent_phys.h,
        .w = sr.w / parent_data.w * parent_phys.w,
        .h = sr.h / parent_data.h * parent_phys.h,
    };
}

/// Checkerboard alpha over each cell of the floating column/row, matching `drawCheckerboardCellsBatched` tint/UVs at half opacity.
fn drawCheckerboardReorderFloatingStrip(
    self: *FileWidget,
    file: *fizzy.Internal.File,
    removed_data_rect: dvui.Rect,
    strip_phys: dvui.Rect.Physical,
    axis: ReorderAxis,
    removed_index: usize,
) void {
    _ = self;
    const pd = removed_data_rect;
    if (pd.w <= 0 or pd.h <= 0) return;
    if (strip_phys.w <= 0 or strip_phys.h <= 0) return;

    const n = switch (axis) {
        .columns => file.rows,
        .rows => file.columns,
    };
    if (n == 0) return;

    const arena = dvui.currentWindow().arena();
    var builder = dvui.Triangles.Builder.init(arena, n * 4, n * 6) catch {
        dvui.log.err("Failed to allocate reorder floating checkerboard", .{});
        return;
    };
    defer builder.deinit(arena);

    const pal = checkerboardGridPalette();
    const tone = pal.tone;
    const c_tl = pal.c_tl;
    const c_tr = pal.c_tr;
    const c_bl = pal.c_bl;
    const c_br = pal.c_br;
    const te = fizzy.editor.settings.transparency_effect;

    const cols_f = @max(@as(f32, @floatFromInt(file.columns)), 1.0);
    const rows_f = @max(@as(f32, @floatFromInt(file.rows)), 1.0);

    const mu_mv = dvui.dataGet(null, file.editor.canvas.id, "checkerboard_mouse_uv", dvui.Point) orelse dvui.Point{ .x = 0.5, .y = 0.5 };
    const mu = mu_mv.x;
    const mv = mu_mv.y;

    const half_op = dvui.Color.PMA{ .r = 128, .g = 128, .b = 128, .a = 128 };

    var quad_i: usize = 0;
    for (0..n) |i| {
        const si = switch (axis) {
            .columns => removed_index + i * file.columns,
            .rows => i + removed_index * file.columns,
        };
        const sr = file.spriteRect(si);
        const phys = mapDataRectToPhysicalStrip(sr, pd, strip_phys);
        const col = file.columnFromIndex(si);
        const row = file.rowFromIndex(si);
        const u_left = @as(f32, @floatFromInt(col)) / cols_f;
        const u_right = @as(f32, @floatFromInt(col + 1)) / cols_f;
        const v_top = @as(f32, @floatFromInt(row)) / rows_f;
        const v_bot = @as(f32, @floatFromInt(row + 1)) / rows_f;

        const pma_tl = dvui.Color.PMA.fromColor(checkerboardCellCornerColor(te, file, si, c_tl, c_tr, c_bl, c_br, u_left, v_top, mu, mv, tone)).multiply(half_op);
        const pma_tr = dvui.Color.PMA.fromColor(checkerboardCellCornerColor(te, file, si, c_tl, c_tr, c_bl, c_br, u_right, v_top, mu, mv, tone)).multiply(half_op);
        const pma_br = dvui.Color.PMA.fromColor(checkerboardCellCornerColor(te, file, si, c_tl, c_tr, c_bl, c_br, u_right, v_bot, mu, mv, tone)).multiply(half_op);
        const pma_bl = dvui.Color.PMA.fromColor(checkerboardCellCornerColor(te, file, si, c_tl, c_tr, c_bl, c_br, u_left, v_bot, mu, mv, tone)).multiply(half_op);

        const tl = phys.topLeft();
        const tr = phys.topRight();
        const br = phys.bottomRight();
        const bl = phys.bottomLeft();

        builder.appendVertex(.{ .pos = tl, .col = pma_tl, .uv = .{ 0, 0 } });
        builder.appendVertex(.{ .pos = tr, .col = pma_tr, .uv = .{ 1, 0 } });
        builder.appendVertex(.{ .pos = br, .col = pma_br, .uv = .{ 1, 1 } });
        builder.appendVertex(.{ .pos = bl, .col = pma_bl, .uv = .{ 0, 1 } });

        const quad_base: dvui.Vertex.Index = @intCast(quad_i * 4);
        builder.appendTriangles(&.{ quad_base + 1, quad_base + 0, quad_base + 3, quad_base + 1, quad_base + 3, quad_base + 2 });
        quad_i += 1;
    }

    const triangles = builder.build();
    dvui.renderTriangles(triangles, file.editor.checkerboard_tile.getTexture() catch null) catch {
        dvui.log.err("Failed to render reorder floating checkerboard", .{});
    };
}

/// Content fill + batched checkerboard for the file canvas (same as the normal `drawLayers` path).
fn drawCanvasCheckerboardBackground(self: *FileWidget) void {
    const file = self.init_options.file;
    const canvas = &file.editor.canvas;
    const layer_rect = canvas.dataFromScreenRect(canvas.rect);
    const bg_rect = dvui.Rect{
        .x = layer_rect.x,
        .y = layer_rect.y,
        .w = layer_rect.w,
        .h = layer_rect.h,
    };
    const bg_screen = canvas.screenFromDataRect(bg_rect);
    if (canvas.scale < 0.1) {
        bg_screen.fill(.all(0), .{ .color = dvui.themeGet().color(.content, .fill), .fade = 1.5 });
    } else {
        bg_screen.fill(.all(0), .{ .color = dvui.themeGet().color(.content, .fill), .fade = 1.5 });
        drawCheckerboardCellsBatched(file);
    }
}

fn drawColumnRowReorderPreview(self: *FileWidget) void {
    const file = self.init_options.file;
    const workspace = file.editor.workspace;
    if (workspace.columns_drag_index == null and workspace.rows_drag_index == null) return;

    const axis: ReorderAxis = if (workspace.columns_drag_index != null) .columns else .rows;
    const target_index = switch (axis) {
        .columns => workspace.columns_target_index,
        .rows => workspace.rows_target_index,
    };
    const removed_index = switch (axis) {
        .columns => workspace.columns_drag_index,
        .rows => workspace.rows_drag_index,
    } orelse return;

    self.drawReorderPreviewForAxis(file, axis, target_index, removed_index);
}

fn renderLayersInDataRect(
    self: *FileWidget,
    file: *fizzy.Internal.File,
    data_rect: dvui.Rect,
    screen_rect_override: ?dvui.Rect.Physical,
) void {
    const scale = self.init_options.file.editor.canvas.scale;
    const w = @as(f32, @floatFromInt(file.width()));
    const h = @as(f32, @floatFromInt(file.height()));
    const r = screen_rect_override orelse file.editor.canvas.screenFromDataRect(data_rect);
    fizzy.render.renderLayers(.{
        .file = file,
        .rs = .{ .r = r, .s = scale },
        .uv = .{
            .x = data_rect.x / w,
            .y = data_rect.y / h,
            .w = data_rect.w / w,
            .h = data_rect.h / h,
        },
    }) catch dvui.log.err("Failed to render file image", .{});
}

fn reorderSegmentRects(
    axis: ReorderAxis,
    file: *fizzy.Internal.File,
    target_index: usize,
    removed_index: usize,
    target_rect: dvui.Rect,
    removed_rect: dvui.Rect,
) struct {
    first: dvui.Rect,
    middle: ?dvui.Rect,
    last: dvui.Rect,
    middle_screen_offset: dvui.Point,
} {
    const slot_size = switch (axis) {
        .columns => file.column_width,
        .rows => file.row_height,
    };
    const slot_count = switch (axis) {
        .columns => file.columns,
        .rows => file.rows,
    };
    const slot_f = @as(f32, @floatFromInt(slot_size));
    const extent_other = switch (axis) {
        .columns => @as(f32, @floatFromInt(file.height())),
        .rows => @as(f32, @floatFromInt(file.width())),
    };

    if (target_index <= removed_index) {
        const first: dvui.Rect = switch (axis) {
            .columns => .{ .x = 0.0, .y = 0.0, .w = slot_f * @as(f32, @floatFromInt(target_index)), .h = extent_other },
            .rows => .{ .x = 0.0, .y = 0.0, .w = extent_other, .h = slot_f * @as(f32, @floatFromInt(target_index)) },
        };
        const middle_n = removed_index - target_index;
        const middle: ?dvui.Rect = if (middle_n >= 1)
            switch (axis) {
                .columns => .{ .x = target_rect.x, .y = 0.0, .w = slot_f * @as(f32, @floatFromInt(middle_n)), .h = extent_other },
                .rows => .{ .x = 0.0, .y = target_rect.y, .w = extent_other, .h = slot_f * @as(f32, @floatFromInt(middle_n)) },
            }
        else
            null;
        const last: dvui.Rect = switch (axis) {
            .columns => .{ .x = removed_rect.x + removed_rect.w, .y = 0.0, .w = slot_f * @as(f32, @floatFromInt(slot_count - removed_index - 1)), .h = extent_other },
            .rows => .{ .x = 0.0, .y = removed_rect.y + removed_rect.h, .w = extent_other, .h = slot_f * @as(f32, @floatFromInt(slot_count - removed_index - 1)) },
        };
        const middle_screen_offset: dvui.Point = switch (axis) {
            .columns => .{ .x = slot_f, .y = 0.0 },
            .rows => .{ .x = 0.0, .y = slot_f },
        };
        return .{ .first = first, .middle = middle, .last = last, .middle_screen_offset = middle_screen_offset };
    } else {
        const first: dvui.Rect = switch (axis) {
            .columns => .{ .x = 0.0, .y = 0.0, .w = slot_f * @as(f32, @floatFromInt(removed_index)), .h = extent_other },
            .rows => .{ .x = 0.0, .y = 0.0, .w = extent_other, .h = slot_f * @as(f32, @floatFromInt(removed_index)) },
        };
        const middle_n = target_index - removed_index;
        const middle: ?dvui.Rect = if (middle_n >= 1)
            switch (axis) {
                .columns => .{ .x = removed_rect.x + removed_rect.w, .y = 0.0, .w = slot_f * @as(f32, @floatFromInt(middle_n)), .h = extent_other },
                .rows => .{ .x = 0.0, .y = removed_rect.y + removed_rect.h, .w = extent_other, .h = slot_f * @as(f32, @floatFromInt(middle_n)) },
            }
        else
            null;
        const last: dvui.Rect = switch (axis) {
            .columns => .{ .x = target_rect.x + target_rect.w, .y = 0.0, .w = slot_f * @as(f32, @floatFromInt(slot_count - target_index - 1)), .h = extent_other },
            .rows => .{ .x = 0.0, .y = target_rect.y + target_rect.h, .w = extent_other, .h = slot_f * @as(f32, @floatFromInt(slot_count - target_index - 1)) },
        };
        const middle_screen_offset: dvui.Point = switch (axis) {
            .columns => .{ .x = -slot_f, .y = 0.0 },
            .rows => .{ .x = 0.0, .y = -slot_f },
        };
        return .{ .first = first, .middle = middle, .last = last, .middle_screen_offset = middle_screen_offset };
    }
}

fn drawReorderPreviewForAxis(
    self: *FileWidget,
    file: *fizzy.Internal.File,
    axis: ReorderAxis,
    target_index: ?usize,
    removed_index: usize,
) void {
    self.drawCanvasCheckerboardBackground();

    const canvas = &file.editor.canvas;
    const layer_rect = canvas.dataFromScreenRect(canvas.rect);
    const grid_y0 = layer_rect.y;
    const grid_y1 = layer_rect.y + layer_rect.h;
    const grid_x0 = layer_rect.x;
    const grid_x1 = layer_rect.x + layer_rect.w;
    const grid_thickness = std.math.clamp(dvui.currentWindow().natural_scale * canvas.scale, 0, dvui.currentWindow().natural_scale);
    const grid_color = dvui.themeGet().color(.control, .fill);

    const removed_rect = switch (axis) {
        .columns => file.columnRect(removed_index),
        .rows => file.rowRect(removed_index),
    };

    if (target_index == null) {
        // Dragging but not over canvas: draw full layers unchanged, then dim removed slot only

        {
            for (1..file.columns) |i| {
                const gx = @as(f32, @floatFromInt(i * file.column_width));
                dvui.Path.stroke(.{ .points = &.{
                    canvas.screenFromDataPoint(.{ .x = gx, .y = grid_y0 }),
                    canvas.screenFromDataPoint(.{ .x = gx, .y = grid_y1 }),
                } }, .{ .thickness = grid_thickness, .color = grid_color });
            }

            for (1..file.rows) |i| {
                const gy = @as(f32, @floatFromInt(i * file.row_height));
                dvui.Path.stroke(.{ .points = &.{
                    canvas.screenFromDataPoint(.{ .x = grid_x0, .y = gy }),
                    canvas.screenFromDataPoint(.{ .x = grid_x1, .y = gy }),
                } }, .{ .thickness = grid_thickness, .color = grid_color });
            }
        }

        const full_rect = dvui.Rect{
            .x = 0.0,
            .y = 0.0,
            .w = @floatFromInt(file.width()),
            .h = @floatFromInt(file.height()),
        };
        self.renderLayersInDataRect(file, full_rect, null);
        return;
    }

    const target_i = target_index.?;
    const same_slot = removed_index == target_i;

    const target_rect = switch (axis) {
        .columns => file.columnRect(target_i),
        .rows => file.rowRect(target_i),
    };

    const scale = file.editor.canvas.scale;
    const box_dir = switch (axis) {
        .columns => dvui.enums.Direction.horizontal,
        .rows => dvui.enums.Direction.vertical,
    };

    defer {
        var target_box_rect = target_rect;

        const tl = dvui.currentWindow().mouse_pt.plus(dvui.dragOffset());
        const data_tl = file.editor.canvas.dataFromScreenPoint(tl);

        switch (axis) {
            .columns => {
                target_box_rect.x = data_tl.x;
            },
            .rows => {
                target_box_rect.y = data_tl.y;
            },
        }

        var animated_target_box_rect = target_rect;

        {
            const current_tl: dvui.Point = self.grid_reorder_point orelse .{ .x = 0.0, .y = 0.0 };

            if (animated_target_box_rect.topLeft().x != current_tl.x or animated_target_box_rect.topLeft().y != current_tl.y) {
                defer self.grid_reorder_point = animated_target_box_rect.topLeft();

                if (self.grid_reorder_point != null) {
                    if (dvui.animationGet(self.init_options.file.editor.canvas.id, "reorder_target_rect_x")) |anim| {
                        if (anim.end_val != animated_target_box_rect.x) {
                            _ = dvui.currentWindow().animations.remove(self.init_options.file.editor.canvas.id.update("reorder_target_rect_x"));
                            dvui.animation(self.init_options.file.editor.canvas.id, "reorder_target_rect_x", .{
                                .start_val = anim.value(),
                                .end_val = animated_target_box_rect.x,
                                .end_time = 350_000,
                                .easing = dvui.easing.outBack,
                            });
                        }
                    } else if (animated_target_box_rect.x != current_tl.x) {

                        // If we are here, we need to trigger a new animation to move the resize button rect to the new point
                        dvui.animation(self.init_options.file.editor.canvas.id, "reorder_target_rect_x", .{
                            .start_val = current_tl.x,
                            .end_val = animated_target_box_rect.x,
                            .end_time = 350_000,
                            .easing = dvui.easing.outBack,
                        });
                    } else if (dvui.animationGet(self.init_options.file.editor.canvas.id, "reorder_target_rect_y")) |anim| {
                        if (anim.end_val != animated_target_box_rect.y) {
                            _ = dvui.currentWindow().animations.remove(self.init_options.file.editor.canvas.id.update("reorder_target_rect_y"));
                            dvui.animation(self.init_options.file.editor.canvas.id, "reorder_target_rect_y", .{
                                .start_val = anim.value(),
                                .end_val = animated_target_box_rect.y,
                                .end_time = 350_000,
                                .easing = dvui.easing.outBack,
                            });
                        }
                    } else if (animated_target_box_rect.y != current_tl.y) {

                        // If we are here, we need to trigger a new animation to move the resize button rect to the new point
                        dvui.animation(self.init_options.file.editor.canvas.id, "reorder_target_rect_y", .{
                            .start_val = current_tl.y,
                            .end_val = animated_target_box_rect.y,
                            .end_time = 350_000,
                            .easing = dvui.easing.outBack,
                        });
                    }
                }

                if (dvui.animationGet(self.init_options.file.editor.canvas.id, "reorder_target_rect_x")) |anim| {
                    animated_target_box_rect.x = anim.value();
                }

                if (dvui.animationGet(self.init_options.file.editor.canvas.id, "reorder_target_rect_y")) |anim| {
                    animated_target_box_rect.y = anim.value();
                }
            }
        }

        file.editor.canvas.screenFromDataRect(animated_target_box_rect).fill(.all(3.0 / scale), .{
            .color = if (same_slot)
                dvui.themeGet().color(.control, .fill).opacity(0.6)
            else
                dvui.themeGet().color(.highlight, .fill).opacity(0.6),
            .fade = 1.0,
        });

        {
            fizzy.dvui.drawEdgeShadow(.{ .r = file.editor.canvas.screenFromDataRect(animated_target_box_rect), .s = scale }, if (axis == .columns) .right else .top, .{
                .opacity = 0.5,
            });
            fizzy.dvui.drawEdgeShadow(.{ .r = file.editor.canvas.screenFromDataRect(animated_target_box_rect), .s = scale }, if (axis == .columns) .left else .bottom, .{
                .opacity = 0.5,
            });
        }

        const target_box = dvui.box(@src(), .{ .dir = box_dir }, .{
            .expand = .none,
            .rect = target_box_rect,
            .border = dvui.Rect.all(0),
            .background = true,
            .color_fill = if (same_slot)
                dvui.themeGet().color(.control, .fill).opacity(0.75)
            else
                dvui.themeGet().color(.control, .fill).opacity(0.75),
            .box_shadow = .{
                .color = .black,
                .offset = .{
                    .x = -4 / scale,
                    .y = 0.0,
                },
                .alpha = 0.25,
                .fade = 16 / scale,
                .corner_radius = dvui.Rect.all(target_rect.w / 2.0 / scale),
            },
        });
        defer target_box.deinit();

        self.renderLayersInDataRect(file, removed_rect, target_box.data().rectScale().r);
        self.drawCheckerboardReorderFloatingStrip(file, removed_rect, target_box.data().rectScale().r, axis, removed_index);
    }

    defer {
        const err_color = dvui.themeGet().color(.err, .fill);
        if (!same_slot) {
            // Tint the original removed slot with err color so the canvas matches the
            // dragged-from indicator used in our tree widgets (files / layers / animations).
            file.editor.canvas.screenFromDataRect(removed_rect).fill(.all(0), .{
                .color = err_color.opacity(0.25),
                .fade = 1.0,
            });
        }

        if (removed_index != target_i) {
            if (axis == .columns) {
                const top = if (removed_index < target_i) removed_rect.topLeft() else removed_rect.topRight();
                const bottom = if (removed_index < target_i) removed_rect.bottomLeft() else removed_rect.bottomRight();
                dvui.Path.stroke(.{ .points = &.{
                    file.editor.canvas.screenFromDataPoint(top),
                    file.editor.canvas.screenFromDataPoint(bottom),
                } }, .{ .thickness = 3, .color = err_color });

                dvui.Path.fillConvex(.{
                    .points = &.{
                        file.editor.canvas.screenFromDataPoint(top),
                        file.editor.canvas.screenFromDataPoint(top.plus(.{ .x = 5.0 / scale, .y = -10.0 / scale })),
                        file.editor.canvas.screenFromDataPoint(top.plus(.{ .x = -5.0 / scale, .y = -10.0 / scale })),
                    },
                }, .{
                    .color = err_color,
                    .fade = 1.0,
                });

                dvui.Path.fillConvex(.{
                    .points = &.{
                        file.editor.canvas.screenFromDataPoint(bottom),
                        file.editor.canvas.screenFromDataPoint(bottom.plus(.{ .x = 5.0 / scale, .y = 10.0 / scale })),
                        file.editor.canvas.screenFromDataPoint(bottom.plus(.{ .x = -5.0 / scale, .y = 10.0 / scale })),
                    },
                }, .{
                    .color = err_color,
                    .fade = 1.0,
                });
            } else {
                const left = if (removed_index < target_i) removed_rect.topLeft() else removed_rect.bottomLeft();
                const right = if (removed_index < target_i) removed_rect.topRight() else removed_rect.bottomRight();
                dvui.Path.stroke(.{ .points = &.{
                    file.editor.canvas.screenFromDataPoint(left),
                    file.editor.canvas.screenFromDataPoint(right),
                } }, .{ .thickness = 3, .color = err_color });

                dvui.Path.fillConvex(.{
                    .points = &.{
                        file.editor.canvas.screenFromDataPoint(left),
                        file.editor.canvas.screenFromDataPoint(left.plus(.{ .x = -8.0 / scale, .y = -5.0 / scale })),
                        file.editor.canvas.screenFromDataPoint(left.plus(.{ .x = -8.0 / scale, .y = 5.0 / scale })),
                    },
                }, .{
                    .color = err_color,
                    .fade = 1.0,
                });
                dvui.Path.fillConvex(.{
                    .points = &.{
                        file.editor.canvas.screenFromDataPoint(right),
                        file.editor.canvas.screenFromDataPoint(right.plus(.{ .x = 8.0 / scale, .y = -5.0 / scale })),
                        file.editor.canvas.screenFromDataPoint(right.plus(.{ .x = 8.0 / scale, .y = 5.0 / scale })),
                    },
                }, .{
                    .color = err_color,
                    .fade = 1.0,
                });
            }
        }
    }

    const segments = reorderSegmentRects(axis, file, target_i, removed_index, target_rect, removed_rect);

    self.renderLayersInDataRect(file, segments.first, null);
    if (segments.middle) |middle_rect| {
        const screen_rect = canvas.screenFromDataRect(middle_rect.offsetPoint(segments.middle_screen_offset));
        self.renderLayersInDataRect(file, middle_rect, screen_rect);
    }
    if (segments.last.w > 0.0 and segments.last.h > 0.0) {
        self.renderLayersInDataRect(file, segments.last, null);
    }

    {
        for (1..file.columns) |i| {
            const gx = @as(f32, @floatFromInt(i * file.column_width));
            dvui.Path.stroke(.{ .points = &.{
                canvas.screenFromDataPoint(.{ .x = gx, .y = grid_y0 }),
                canvas.screenFromDataPoint(.{ .x = gx, .y = grid_y1 }),
            } }, .{ .thickness = grid_thickness, .color = grid_color });
        }

        for (1..file.rows) |i| {
            const gy = @as(f32, @floatFromInt(i * file.row_height));
            dvui.Path.stroke(.{ .points = &.{
                canvas.screenFromDataPoint(.{ .x = grid_x0, .y = gy }),
                canvas.screenFromDataPoint(.{ .x = grid_x1, .y = gy }),
            } }, .{ .thickness = grid_thickness, .color = grid_color });
        }
    }
}

pub fn drawCellReorderPreview(self: *FileWidget) void {
    const file = self.init_options.file;
    self.drawCanvasCheckerboardBackground();

    const canvas = &file.editor.canvas;
    const layer_rect = canvas.dataFromScreenRect(canvas.rect);
    const grid_y0 = layer_rect.y;
    const grid_y1 = layer_rect.y + layer_rect.h;
    const grid_x0 = layer_rect.x;
    const grid_x1 = layer_rect.x + layer_rect.w;
    const grid_thickness = std.math.clamp(dvui.currentWindow().natural_scale * canvas.scale, 0, dvui.currentWindow().natural_scale);
    const grid_color = dvui.themeGet().color(.control, .fill);

    if (self.removed_sprite_indices) |removed_sprite_indices| {
        const insert_before_sprite_indices = dvui.currentWindow().arena().alloc(usize, removed_sprite_indices.len) catch {
            dvui.log.err("Failed to allocate insert before sprite indices", .{});
            return;
        };

        for (removed_sprite_indices, 0..) |removed_sprite_index, i| {
            if (self.cell_reorder_point) |cell_reorder_point| {
                const removed_sprite_rect = file.spriteRect(removed_sprite_index);
                const current_point = file.editor.canvas.dataFromScreenPoint(dvui.currentWindow().mouse_pt);
                const difference = current_point.diff(cell_reorder_point);

                if (file.spriteIndex(removed_sprite_rect.center().plus(difference))) |index| {
                    insert_before_sprite_indices[i] = index;
                } else {
                    insert_before_sprite_indices[i] = file.wrappedSpriteIndex(removed_sprite_rect.center().plus(difference));
                }
            }
        }

        const new_sprite_indices = file.getReorderIndices(
            dvui.currentWindow().arena(),
            removed_sprite_indices,
            insert_before_sprite_indices,
            .replace,
            false,
        ) catch |err| {
            dvui.log.err("Failed to get reorder indices {any}", .{err});
            return;
        };

        const file_width = @as(f32, @floatFromInt(file.width()));
        const file_height = @as(f32, @floatFromInt(file.height()));

        { // Draw all sprites except the ones that are being dragged
            var builder = dvui.Triangles.Builder.init(dvui.currentWindow().arena(), file.spriteCount() * 4, file.spriteCount() * 6) catch |err| {
                dvui.log.err("Failed to initialize triangles builder: {any}", .{err});
                return;
            };
            defer builder.deinit(dvui.currentWindow().arena());

            for (0..file.spriteCount()) |i| {
                const new_index = new_sprite_indices[i];
                const new_rect = file.spriteRect(new_index);
                const new_rect_physical = file.editor.canvas.screenFromDataRect(new_rect);
                const current_rect = file.spriteRect(i);

                const dragging: bool = file.editor.selected_sprites.isSet(i);

                // UVs: normalize sprite rect in data space to 0-1 over the layer texture (same size as file).
                // 0: TopLeft     → uv (umin, vmin)
                // 1: TopRight    → uv (umax, vmin)
                // 2: BottomRight → uv (umax, vmax)
                // 3: BottomLeft  → uv (umin, vmax)
                const umin = current_rect.x / file_width;
                const vmin = current_rect.y / file_height;
                const umax = (current_rect.x + current_rect.w) / file_width;
                const vmax = (current_rect.y + current_rect.h) / file_height;

                const col = if (!dragging) dvui.Color.PMA.fromColor(dvui.Color.white) else dvui.Color.PMA.fromColor(dvui.Color.transparent);

                builder.appendVertex(.{ .pos = new_rect_physical.topLeft(), .col = col, .uv = .{ umin, vmin } });
                builder.appendVertex(.{ .pos = new_rect_physical.topRight(), .col = col, .uv = .{ umax, vmin } });
                builder.appendVertex(.{ .pos = new_rect_physical.bottomRight(), .col = col, .uv = .{ umax, vmax } });
                builder.appendVertex(.{ .pos = new_rect_physical.bottomLeft(), .col = col, .uv = .{ umin, vmax } });

                const base: dvui.Vertex.Index = @intCast(i * 4);
                builder.appendTriangles(&.{ base + 1, base + 0, base + 3, base + 1, base + 3, base + 2 });
            }

            {
                var temp_selected_sprite = file.editor.selected_sprites.clone(dvui.currentWindow().arena()) catch {
                    dvui.log.err("Failed to clone selected sprites", .{});
                    return;
                };

                var temp_insert_before_sprite = file.editor.selected_sprites.clone(dvui.currentWindow().arena()) catch {
                    dvui.log.err("Failed to clone selected sprites", .{});
                    return;
                };

                temp_insert_before_sprite.setRangeValue(.{ .start = 0, .end = file.spriteCount() }, false);

                for (insert_before_sprite_indices) |insert_before_sprite_index| {
                    temp_selected_sprite.set(insert_before_sprite_index);
                    temp_insert_before_sprite.set(insert_before_sprite_index);
                }

                var iter = temp_selected_sprite.iterator(.{ .kind = .set, .direction = .forward });
                while (iter.next()) |sprite_index| {
                    const image_rect = file.spriteRect(sprite_index);

                    const image_rect_scale: dvui.RectScale = .{
                        .r = self.init_options.file.editor.canvas.screenFromDataRect(image_rect),
                        .s = self.init_options.file.editor.canvas.scale,
                    };

                    const highlight = dvui.themeGet().color(.highlight, .fill).opacity(0.5);
                    const err = dvui.themeGet().color(.err, .fill).opacity(0.5);

                    const color = if (temp_insert_before_sprite.isSet(sprite_index) and file.editor.selected_sprites.isSet(sprite_index)) highlight.average(err) else if (temp_insert_before_sprite.isSet(sprite_index)) highlight else if (file.editor.selected_sprites.isSet(sprite_index)) err else highlight;

                    image_rect_scale.r.fill(.all(0), .{ .color = color, .fade = 1.5 });

                    const left_index = file.spriteIndex(image_rect.center().diff(.{ .x = @as(f32, @floatFromInt(file.column_width)) }));
                    const right_index = file.spriteIndex(image_rect.center().plus(.{ .x = @as(f32, @floatFromInt(file.column_width)) }));
                    const top_index = file.spriteIndex(image_rect.center().diff(.{ .y = @as(f32, @floatFromInt(file.row_height)) }));
                    const bottom_index = file.spriteIndex(image_rect.center().plus(.{ .y = @as(f32, @floatFromInt(file.row_height)) }));

                    if (left_index) |left_index_value| {
                        if (!temp_selected_sprite.isSet(left_index_value)) {
                            fizzy.dvui.drawEdgeShadow(image_rect_scale, .left, .{ .opacity = 0.35 });
                        }
                    }
                    if (right_index) |right_index_value| {
                        if (!temp_selected_sprite.isSet(right_index_value)) {
                            fizzy.dvui.drawEdgeShadow(image_rect_scale, .right, .{ .opacity = 0.35 });
                        }
                    }
                    if (top_index) |top_index_value| {
                        if (!temp_selected_sprite.isSet(top_index_value)) {
                            fizzy.dvui.drawEdgeShadow(image_rect_scale, .top, .{ .opacity = 0.35 });
                        }
                    }
                    if (bottom_index) |bottom_index_value| {
                        if (!temp_selected_sprite.isSet(bottom_index_value)) {
                            fizzy.dvui.drawEdgeShadow(image_rect_scale, .bottom, .{ .opacity = 0.35 });
                        }
                    }
                }
            }

            { // Render once for each layer
                const grid_triangles = builder.build();

                var i: usize = file.layers.len;

                while (i > 0) {
                    i -= 1;
                    const source = file.layers.items(.source)[i];
                    dvui.renderTriangles(grid_triangles, source.getTexture() catch null) catch {
                        dvui.log.err("Failed to render triangles", .{});
                        return;
                    };
                }
            }

            {
                for (1..file.columns) |i| {
                    const gx = @as(f32, @floatFromInt(i * file.column_width));
                    dvui.Path.stroke(.{ .points = &.{
                        canvas.screenFromDataPoint(.{ .x = gx, .y = grid_y0 }),
                        canvas.screenFromDataPoint(.{ .x = gx, .y = grid_y1 }),
                    } }, .{ .thickness = grid_thickness, .color = grid_color });
                }

                for (1..file.rows) |i| {
                    const gy = @as(f32, @floatFromInt(i * file.row_height));
                    dvui.Path.stroke(.{ .points = &.{
                        canvas.screenFromDataPoint(.{ .x = grid_x0, .y = gy }),
                        canvas.screenFromDataPoint(.{ .x = grid_x1, .y = gy }),
                    } }, .{ .thickness = grid_thickness, .color = grid_color });
                }
            }
        }

        { // Render the sprites that are being dragged
            var builder = dvui.Triangles.Builder.init(dvui.currentWindow().arena(), file.spriteCount() * 4, file.spriteCount() * 6) catch |err| {
                dvui.log.err("Failed to initialize triangles builder: {any}", .{err});
                return;
            };
            defer builder.deinit(dvui.currentWindow().arena());

            for (removed_sprite_indices, 0..) |removed_sprite_index, i| {
                const base_quad: dvui.Vertex.Index = @intCast(i * 4);

                var shadow_path = dvui.Path.Builder.init(dvui.currentWindow().lifo());
                defer shadow_path.deinit();

                const new_rect = file.spriteRect(removed_sprite_index);
                var new_rect_physical = file.editor.canvas.screenFromDataRect(new_rect);

                if (self.cell_reorder_point) |cell_reorder_point| {
                    new_rect_physical = new_rect_physical.offsetPoint(dvui.currentWindow().mouse_pt.diff(file.editor.canvas.screenFromDataPoint(cell_reorder_point)));
                }

                // UVs: normalize sprite rect in data space to 0-1 over the layer texture (same size as file).
                // 0: TopLeft     → uv (umin, vmin)
                // 1: TopRight    → uv (umax, vmin)
                // 2: BottomRight → uv (umax, vmax)
                // 3: BottomLeft  → uv (umin, vmax)
                const umin = new_rect.x / file_width;
                const vmin = new_rect.y / file_height;
                const umax = (new_rect.x + new_rect.w) / file_width;
                const vmax = (new_rect.y + new_rect.h) / file_height;

                builder.appendVertex(.{
                    .pos = new_rect_physical.topLeft(),
                    .col = .white,
                    .uv = .{ umin, vmin },
                });
                builder.appendVertex(.{
                    .pos = new_rect_physical.topRight(),
                    .col = .white,
                    .uv = .{ umax, vmin },
                });
                builder.appendVertex(.{
                    .pos = new_rect_physical.bottomRight(),
                    .col = .white,
                    .uv = .{ umax, vmax },
                });
                builder.appendVertex(.{
                    .pos = new_rect_physical.bottomLeft(),
                    .col = .white,
                    .uv = .{ umin, vmax },
                });

                builder.appendTriangles(&.{ base_quad + 1, base_quad + 0, base_quad + 3, base_quad + 1, base_quad + 3, base_quad + 2 });
            }

            const triangles = builder.build();

            var i: usize = file.layers.len;
            while (i > 0) {
                i -= 1;
                const source = file.layers.items(.source)[i];
                dvui.renderTriangles(triangles, source.getTexture() catch null) catch {
                    dvui.log.err("Failed to render triangles", .{});
                    return;
                };
            }
        }
    }
}

/// Edge-auto-pan for the grid resize drag. Pushes the canvas viewport when the cursor
/// reaches/exceeds the scroll container edges; velocity ramps up as the cursor moves
/// further past the edge, so the user can grow the grid well beyond the current view.
fn autoPanForResize(self: *FileWidget, mouse_pt: dvui.Point.Physical) void {
    const canvas = &self.init_options.file.editor.canvas;
    const rs = canvas.scroll_container.data().contentRectScale();
    const r = rs.r;
    const win = dvui.currentWindow();
    const win_r = win.rect_pixels;

    // Distance past the edge (in screen px) drives velocity. Once `over >= ramp`, we're at
    // max speed; this prevents jitter from a cursor sitting exactly on the boundary.
    const ramp: f32 = 80.0 * win.natural_scale;
    const max_speed_px_per_sec: f32 = 2500.0 * win.natural_scale;

    // OS clamps the cursor at the window edge — if the canvas sits flush against that edge,
    // the user can only push a couple of pixels past `r`, leaving the ramp linger near zero.
    // Treat "cursor pinned to the window edge AND past the canvas edge" as full velocity.
    const edge_eps: f32 = 2.0 * win.natural_scale;

    var vx: f32 = 0;
    var vy: f32 = 0;

    if (mouse_pt.x < r.x) {
        const pinned = mouse_pt.x <= win_r.x + edge_eps;
        const t: f32 = if (pinned) 1.0 else @min((r.x - mouse_pt.x) / ramp, 1.0);
        vx = -t * max_speed_px_per_sec;
    } else if (mouse_pt.x > r.x + r.w) {
        const pinned = mouse_pt.x >= win_r.x + win_r.w - edge_eps;
        const t: f32 = if (pinned) 1.0 else @min((mouse_pt.x - (r.x + r.w)) / ramp, 1.0);
        vx = t * max_speed_px_per_sec;
    }

    if (mouse_pt.y < r.y) {
        const pinned = mouse_pt.y <= win_r.y + edge_eps;
        const t: f32 = if (pinned) 1.0 else @min((r.y - mouse_pt.y) / ramp, 1.0);
        vy = -t * max_speed_px_per_sec;
    } else if (mouse_pt.y > r.y + r.h) {
        const pinned = mouse_pt.y >= win_r.y + win_r.h - edge_eps;
        const t: f32 = if (pinned) 1.0 else @min((mouse_pt.y - (r.y + r.h)) / ramp, 1.0);
        vy = t * max_speed_px_per_sec;
    }

    if (vx == 0 and vy == 0) return;
    if (rs.s <= 0) return;

    const dt = dvui.secondsSinceLastFrame();
    const si = &canvas.scroll_info;
    si.viewport.x += vx * dt / rs.s;
    si.viewport.y += vy * dt / rs.s;

    // Grow virtual_size eagerly when panning down/right so we stay inside `scrollMax` and
    // the scroll container's bounce-back doesn't claw us back ~4 screen-px per frame.
    // (The up/left side is implicitly handled by CanvasWidget.deinit's bbox normalization,
    // which is why those directions already feel fast.)
    if (vx > 0) {
        const need_w = si.viewport.x + si.viewport.w;
        if (si.virtual_size.w < need_w) si.virtual_size.w = need_w;
    }
    if (vy > 0) {
        const need_h = si.viewport.y + si.viewport.h;
        if (si.virtual_size.h < need_h) si.virtual_size.h = need_h;
    }

    dvui.refresh(null, @src(), canvas.scroll_container.data().id);
    // Force a motion event next frame so the resize handle keeps tracking against the
    // newly-scrolled viewport even if the user holds the cursor stationary past the edge.
    dvui.currentWindow().inject_motion_event = true;
}

pub fn processResize(self: *FileWidget) void {
    if (fizzy.editor.tools.current != .pointer) return;
    if (self.init_options.file.editor.transform != null) return;
    if (self.sample_data_point != null) return;

    const file = self.init_options.file;
    const file_rect = dvui.Rect.fromSize(.{ .w = @floatFromInt(file.width()), .h = @floatFromInt(file.height()) });

    for (dvui.events()) |*e| {
        if (!self.init_options.file.editor.canvas.scroll_container.matchEvent(e)) {
            continue;
        }

        switch (e.evt) {
            .mouse => |me| {
                if (me.action == .release and me.button.pointer()) {
                    dvui.refresh(null, @src(), self.init_options.file.editor.canvas.id);
                }

                // Auto-pan the canvas while dragging the resize handle so the user can
                // grow the grid past the viewport edge without zooming out first.
                // `dvui.scrollDrag` caps at ~5 screen px/frame which feels glacial on a
                // wide canvas; we drive the canvas viewport directly with a velocity that
                // ramps up as the cursor pushes past the edge.
                if (me.action == .motion and dvui.dragName("resize_drag")) {
                    self.autoPanForResize(me.p);
                }
            },
            else => {},
        }
    }

    {
        const min_size: f32 = @as(f32, @floatFromInt(@min(file.column_width, file.row_height)));
        const baseline_size: f32 = 64.0;
        const baseline_scale: f32 = baseline_size / min_size;
        const target_button_height: f32 = min_size / 3.0;
        const button_size: f32 = std.math.clamp((target_button_height * 1.0 / self.init_options.file.editor.canvas.scale) * baseline_scale, 0.0, min_size);
        var resize_button_rect = dvui.Rect{
            .x = file_rect.x + file_rect.w - button_size / 2.0,
            .y = file_rect.y + file_rect.h - button_size / 2.0,
            .w = button_size,
            .h = button_size,
        };

        const offset_data_point = self.init_options.file.editor.canvas.dataFromScreenPoint(dvui.currentWindow().mouse_pt).plus(.{
            .x = @as(f32, @floatFromInt(file.column_width)) / 2.0,
            .y = @as(f32, @floatFromInt(file.row_height)) / 2.0,
        });

        const dragging = dvui.dragging(dvui.currentWindow().mouse_pt, "resize_drag") != null and self.active();

        if (self.resize_data_point != null or dragging) {
            const current_point: dvui.Point = self.resize_data_point orelse .{ .x = 0.0, .y = 0.0 };
            var new_point = self.init_options.file.spritePoint(offset_data_point);

            if (current_point.x != new_point.x or current_point.y != new_point.y) {
                new_point.x = std.math.clamp(new_point.x, @as(f32, @floatFromInt(file.column_width)), std.math.floatMax(f32));
                new_point.y = std.math.clamp(new_point.y, @as(f32, @floatFromInt(file.row_height)), std.math.floatMax(f32));

                if (self.resize_data_point != null) {
                    if (dvui.animationGet(self.init_options.file.editor.canvas.id, "resize_button_rect_x")) |anim| {
                        _ = dvui.currentWindow().animations.remove(self.init_options.file.editor.canvas.id.update("resize_button_rect_x"));
                        dvui.animation(self.init_options.file.editor.canvas.id, "resize_button_rect_x", .{
                            .start_val = anim.value(),
                            .end_val = new_point.x,
                            .end_time = 250_000,
                            .easing = dvui.easing.outBack,
                        });
                    } else {

                        // If we are here, we need to trigger a new animation to move the resize button rect to the new point
                        dvui.animation(self.init_options.file.editor.canvas.id, "resize_button_rect_x", .{
                            .start_val = current_point.x,
                            .end_val = new_point.x,
                            .end_time = 250_000,
                            .easing = dvui.easing.outBack,
                        });
                    }

                    if (dvui.animationGet(self.init_options.file.editor.canvas.id, "resize_button_rect_y")) |anim| {
                        _ = dvui.currentWindow().animations.remove(self.init_options.file.editor.canvas.id.update("resize_button_rect_y"));
                        dvui.animation(self.init_options.file.editor.canvas.id, "resize_button_rect_y", .{
                            .start_val = anim.value(),
                            .end_val = new_point.y,
                            .end_time = 250_000,
                            .easing = dvui.easing.outBack,
                        });
                    } else {

                        // If we are here, we need to trigger a new animation to move the resize button rect to the new point
                        dvui.animation(self.init_options.file.editor.canvas.id, "resize_button_rect_y", .{
                            .start_val = current_point.y,
                            .end_val = new_point.y,
                            .end_time = 250_000,
                            .easing = dvui.easing.outBack,
                        });
                    }
                }

                self.resize_data_point = new_point;
            }

            if (dvui.animationGet(self.init_options.file.editor.canvas.id, "resize_button_rect_x")) |anim| {
                resize_button_rect.x = anim.value();
            } else {
                resize_button_rect.x = new_point.x;
            }

            if (dvui.animationGet(self.init_options.file.editor.canvas.id, "resize_button_rect_y")) |anim| {
                resize_button_rect.y = anim.value();
            } else {
                resize_button_rect.y = new_point.y;
            }
        }

        var icon_button: dvui.ButtonWidget = undefined;
        icon_button.init(@src(), .{ .draw_focus = false }, .{
            .rect = resize_button_rect,
            .border = dvui.Rect.all(0),
            .margin = .all(0),
            .padding = .all(0),
            .background = false,
        });
        defer icon_button.deinit();
        icon_button.processEvents();

        if (dragging) {
            var bounds_rect = dvui.Rect.Physical.fromSize(.{ .w = @as(f32, @floatFromInt(file.column_width)), .h = @as(f32, @floatFromInt(file.row_height)) });
            bounds_rect = bounds_rect.scale(self.init_options.file.editor.canvas.scale * dvui.currentWindow().natural_scale, dvui.Rect.Physical);
            bounds_rect.x = icon_button.data().contentRectScale().r.topLeft().x - bounds_rect.w / 2.0;
            bounds_rect.y = icon_button.data().contentRectScale().r.topLeft().y - bounds_rect.h / 2.0;

            var path = dvui.Path.Builder.init(dvui.currentWindow().arena());
            path.addRect(bounds_rect, .{ .x = bounds_rect.w / 2.0, .y = bounds_rect.h / 2.0, .w = bounds_rect.w / 2.0, .h = bounds_rect.h / 2.0 });
            const built = path.build();
            built.fillConvex(.{ .color = dvui.themeGet().color(.window, .fill).opacity(0.5), .fade = 1.5 });
            built.stroke(.{ .color = dvui.themeGet().color(.control, .text).opacity(0.5), .thickness = 1.0, .closed = true });

            path = dvui.Path.Builder.init(dvui.currentWindow().arena());
            path.addPoint(icon_button.data().contentRectScale().r.topLeft());
            path.addRect(.{
                .x = dvui.currentWindow().mouse_pt.x - icon_button.data().contentRectScale().r.w / 8.0,
                .y = dvui.currentWindow().mouse_pt.y - icon_button.data().contentRectScale().r.h / 8.0,
                .w = icon_button.data().contentRectScale().r.w / 4.0,
                .h = icon_button.data().contentRectScale().r.h / 4.0,
            }, .all(icon_button.data().contentRectScale().r.w / 8.0));
            path.build().fillConvex(.{ .color = dvui.themeGet().color(.control, .text).opacity(0.5), .fade = 1.5 });

            path = dvui.Path.Builder.init(dvui.currentWindow().arena());
            path.addRect(.{
                .x = dvui.currentWindow().mouse_pt.x - icon_button.data().contentRectScale().r.w / 8.0,
                .y = dvui.currentWindow().mouse_pt.y - icon_button.data().contentRectScale().r.h / 8.0,
                .w = icon_button.data().contentRectScale().r.w / 4.0,
                .h = icon_button.data().contentRectScale().r.h / 4.0,
            }, .all(icon_button.data().contentRectScale().r.w / 8.0));
            path.build().fillConvex(.{ .color = dvui.themeGet().color(.highlight, .fill).opacity(0.5), .fade = 1.5 });
        } else {
            dvui.icon(@src(), "resize", if (dragging) icons.tvg.lucide.move else icons.tvg.lucide.@"move-diagonal-2", .{
                .stroke_color = if (icon_button.hover) dvui.themeGet().color(.highlight, .fill) else dvui.themeGet().color(.control, .text),
            }, .{
                .expand = .ratio,
                .min_size_content = .{ .w = 1.0, .h = 1.0 },
                .gravity_x = 0.5,
                .gravity_y = 0.5,
                .border = dvui.Rect.all(0),
                .margin = .all(0),
                .padding = .all(0),
                .background = false,
                .rotation = dvui.math.degreesToRadians(0.0),
            });
        }

        if (icon_button.pressed()) {
            dvui.dragStart(
                dvui.currentWindow().mouse_pt,
                .{ .name = "resize_drag", .cursor = .hidden },
            );
            dvui.captureMouse(self.init_options.file.editor.canvas.scroll_container.data(), 0);
        }

        if (dragging == false) {
            if (self.resize_data_point) |resize_data_point| {
                self.init_options.file.resize(.{
                    .columns = @divTrunc(@as(u32, @intFromFloat(resize_data_point.x)), self.init_options.file.column_width),
                    .rows = @divTrunc(@as(u32, @intFromFloat(resize_data_point.y)), self.init_options.file.row_height),
                    .history = true,
                }) catch |err| {
                    dvui.log.err("Failed to resize file: {s}", .{@errorName(err)});
                };
                self.resize_data_point = null;
                dvui.dragEnd();
                dvui.captureMouse(null, 0);
                dvui.refresh(null, @src(), self.init_options.file.editor.canvas.id);
            }
        }
    }
}

pub fn processEvents(self: *FileWidget) void {
    const transform = self.init_options.file.editor.transform != null;
    const reorder = self.init_options.file.editor.workspace.columns_drag_index != null or self.init_options.file.editor.workspace.rows_drag_index != null or self.removed_sprite_indices != null;

    // Try to ensure that selected animation frame index is valid
    if (self.init_options.file.selected_animation_index) |ai| {
        if (self.init_options.file.animations.get(ai).frames.len > 0) {
            if (self.init_options.file.selected_animation_frame_index >= self.init_options.file.animations.get(ai).frames.len) {
                self.init_options.file.selected_animation_frame_index = self.init_options.file.animations.get(ai).frames.len - 1;
            }
        } else {
            self.init_options.file.selected_animation_frame_index = 0;
        }
    }

    defer self.previous_mods = dvui.currentWindow().modifiers;

    defer if (self.drag_data_point) |drag_data_point| {
        dvui.dataSet(null, self.init_options.file.editor.canvas.id, "drag_data_point", drag_data_point);
    } else {
        dvui.dataRemove(null, self.init_options.file.editor.canvas.id, "drag_data_point");
    };

    defer if (self.transform_aspect_w) |v| {
        dvui.dataSet(null, self.init_options.file.editor.canvas.id, "transform_aspect_w", v);
    } else {
        dvui.dataRemove(null, self.init_options.file.editor.canvas.id, "transform_aspect_w");
    };
    defer if (self.transform_aspect_h) |v| {
        dvui.dataSet(null, self.init_options.file.editor.canvas.id, "transform_aspect_h", v);
    } else {
        dvui.dataRemove(null, self.init_options.file.editor.canvas.id, "transform_aspect_h");
    };

    defer if (self.sample_data_point) |sample_data_point| {
        dvui.dataSet(null, self.init_options.file.editor.canvas.id, "sample_data_point", sample_data_point);
    } else {
        dvui.dataRemove(null, self.init_options.file.editor.canvas.id, "sample_data_point");
    };

    defer if (self.resize_data_point) |resize_data_point| {
        dvui.dataSet(null, self.init_options.file.editor.canvas.id, "resize_data_point", resize_data_point);
    } else {
        dvui.dataRemove(null, self.init_options.file.editor.canvas.id, "resize_data_point");
    };

    defer if (self.grid_reorder_point) |grid_reorder_point| {
        dvui.dataSet(null, self.init_options.file.editor.canvas.id, "grid_reorder_point", grid_reorder_point);
    } else {
        dvui.dataRemove(null, self.init_options.file.editor.canvas.id, "grid_reorder_point");
    };

    defer if (self.cell_reorder_point) |cell_reorder_point| {
        dvui.dataSet(null, self.init_options.file.editor.canvas.id, "cell_reorder_point", cell_reorder_point);
    } else {
        dvui.dataRemove(null, self.init_options.file.editor.canvas.id, "cell_reorder_point");
    };

    defer if (self.sample_key_down) {
        dvui.dataSet(null, self.init_options.file.editor.canvas.id, "sample_key_down", self.sample_key_down);
    } else {
        dvui.dataRemove(null, self.init_options.file.editor.canvas.id, "sample_key_down");
    };

    defer if (self.right_mouse_down) {
        dvui.dataSet(null, self.init_options.file.editor.canvas.id, "right_mouse_down", self.right_mouse_down);
    } else {
        dvui.dataRemove(null, self.init_options.file.editor.canvas.id, "right_mouse_down");
    };

    defer if (self.left_mouse_down) {
        dvui.dataSet(null, self.init_options.file.editor.canvas.id, "left_mouse_down", self.left_mouse_down);
    } else {
        dvui.dataRemove(null, self.init_options.file.editor.canvas.id, "left_mouse_down");
    };

    defer if (self.hide_distance_bubble) {
        dvui.dataSet(null, self.init_options.file.editor.canvas.id, "hide_distance_bubble", self.hide_distance_bubble);
    } else {
        dvui.dataRemove(null, self.init_options.file.editor.canvas.id, "hide_distance_bubble");
    };

    // Cursor-leave: when hover transitions true → false, the last brush/fill preview
    // pixels are still painted on the temp layer. Clear them exactly once on the way out
    // (we deliberately do NOT clear every frame — the temp layer can be 64 MB on large
    // files and clearing it each frame murders performance for nothing).
    const canvas_ptr = &self.init_options.file.editor.canvas;
    if (canvas_ptr.prev_hovered and !canvas_ptr.hovered and self.init_options.file.editor.temp_layer_has_content) {
        resetTempLayerPreview(&self.init_options.file.editor);
        dvui.refresh(null, @src(), canvas_ptr.scroll_container.data().id);
    }

    // Gesture takeover: if a 2-finger pan just activated while a stroke / fill drag was
    // in progress, the release event for that touch was swallowed by the canvas — the
    // pixels were drawn but the history entry never got appended. Finalize the stroke
    // here so undo still works.
    if (!canvas_ptr.prev_gesture_active and canvas_ptr.gesture_active and self.init_options.file.editor.active_drawing) {
        self.cancelActiveDrawing();
    }

    // Hover alone is enough for brush/bucket/selection previews (e.g. sampling a color on one
    // document while hovering another). Pixel edits are still gated inside each tool via `active()`.
    // Skip everything when a 2-finger pan is active or while we're still deciding whether the
    // current single touch will become one — otherwise the bucket/pencil hover preview would
    // flash on the pinned finger as the user starts a pan gesture.
    if (self.hovered() and !self.init_options.file.editor.canvas.gestureActive()) {
        const pe_t0 = fizzy.perf.processEventsBegin();
        defer fizzy.perf.processEventsEnd(pe_t0);

        resetTempLayerPreview(&self.init_options.file.editor);

        {
            const mask_t0 = fizzy.perf.updateMaskBegin();
            defer fizzy.perf.updateMaskEnd(mask_t0);
            self.updateActiveLayerMask();
        }

        if (fizzy.editor.tools.current == .selection) {
            if (dvui.timerDoneOrNone(self.init_options.file.editor.canvas.scroll_container.data().id)) {
                self.init_options.file.editor.checkerboard.toggleAll();

                dvui.timer(self.init_options.file.editor.canvas.scroll_container.data().id, 500_000);
            }
        }

        if (self.init_options.file.editor.transform == null) {
            const tool_t0 = fizzy.perf.toolProcessBegin();
            switch (fizzy.editor.tools.current) {
                .bucket => self.processFill(),
                .pencil, .eraser => self.processStroke(),
                .selection => self.processSelection(),
                else => {},
            }
            self.processSample();
            fizzy.perf.toolProcessEnd(tool_t0);
        }
    } else if (self.hovered() and self.init_options.file.editor.canvas.gestureActive()) {
        // A 2-finger gesture (or its pending evaluation) just took over. Make sure any
        // hover brush / fill preview from a prior frame is cleared so it doesn't linger
        // under the panning fingers.
        resetTempLayerPreview(&self.init_options.file.editor);
    }

    // Use `active()`, not `hovered()`: `hovered` is tied to `canvas.rect` (image bounds in screen
    // space). The transform quad can extend outside that rect; we still need presses/drags there and
    // continued drags after the cursor leaves the image (capture + motion).
    const suppress = self.init_options.file.editor.canvas.gestureActive();

    if (self.active() and self.init_options.file.editor.transform != null and !suppress) {
        self.processTransform();
    }

    self.drawLayers();

    if (self.hovered() or dvui.captured(self.init_options.file.editor.canvas.scroll_container.data().id)) {
        self.drawBoxSelectionMarqueeOutline();
    }

    if ((self.active() or self.hovered()) and !transform and !reorder) {
        self.drawSpriteBubbles();
    }

    if (self.active() and !suppress) {
        self.processCellReorder();
    }

    if ((self.active() or self.hovered()) and !transform and !reorder and !suppress) {
        self.processResize();

        self.processAnimationSelection();

        self.processSpriteSelection();
        self.drawSpriteSelection();
    }

    // Draw shadows for the scroll container
    fizzy.dvui.drawEdgeShadow(self.init_options.file.editor.canvas.scroll_container.data().rectScale(), .top, .{ .opacity = 0.15 });
    fizzy.dvui.drawEdgeShadow(self.init_options.file.editor.canvas.scroll_container.data().rectScale(), .bottom, .{});
    fizzy.dvui.drawEdgeShadow(self.init_options.file.editor.canvas.scroll_container.data().rectScale(), .left, .{ .opacity = 0.15 });
    fizzy.dvui.drawEdgeShadow(self.init_options.file.editor.canvas.scroll_container.data().rectScale(), .right, .{});

    self.drawTransform();
    self.drawSample();
    if (self.hovered())
        self.drawCursor();

    // Then process the scroll and zoom events last
    self.init_options.file.editor.canvas.processEvents();
}

pub fn deinit(self: *FileWidget) void {
    self.init_options.file.editor.canvas.deinit();

    self.* = undefined;
}

pub fn hovered(self: *FileWidget) bool {
    return self.init_options.file.editor.canvas.hovered;
}

/// Tear down an in-progress brush/eraser stroke when a 2-finger pan steals the touch.
/// The release event never reaches `processStroke`, so its history-commit code doesn't
/// run. We finalize the deferred undo snapshot here so the pixels already drawn are
/// preserved in the undo stack, and drop the related capture/drag state.
fn cancelActiveDrawing(self: *FileWidget) void {
    const file = self.init_options.file;
    if (!file.editor.active_drawing) return;

    // Commit whatever pixels were drawn so far — `strokeUndoCommit` is safe even if the
    // stroke buffer ended up empty (it appends nothing in that case).
    file.strokeUndoCommit();

    if (dvui.captured(file.editor.canvas.scroll_container.data().id)) {
        dvui.captureMouse(null, 0);
    }
    if (dvui.dragName("stroke_drag")) {
        dvui.dragEnd();
    }

    resetTempLayerPreview(&file.editor);

    file.editor.active_drawing = false;
    file.editor.layer_composite_dirty = true;
    file.editor.layer_composite_frame_built = 0;
    self.drag_data_point = null;

    dvui.refresh(null, @src(), file.editor.canvas.scroll_container.data().id);
}

/// Computes the pixel bounding rect of a brush draw, clamped to image bounds.
fn tempBrushRect(point: dvui.Point, stroke_size: usize, img_w: u32, img_h: u32) dvui.Rect {
    const s: i32 = @intCast(stroke_size);
    const half: i32 = @divFloor(s, 2);
    const px: i32 = @intFromFloat(@floor(point.x));
    const py: i32 = @intFromFloat(@floor(point.y));
    const w: i32 = @intCast(img_w);
    const h: i32 = @intCast(img_h);
    const x0 = @max(px - half, 0);
    const y0 = @max(py - half, 0);
    const x1 = @min(px - half + s, w);
    const y1 = @min(py - half + s, h);
    return .{
        .x = @floatFromInt(x0),
        .y = @floatFromInt(y0),
        .w = @floatFromInt(@max(x1 - x0, 0)),
        .h = @floatFromInt(@max(y1 - y0, 0)),
    };
}

/// Data-space rect of the on-screen canvas, outset by brush size so edge stamps are not clipped.
fn tempStrokePreviewClipRect(canvas: *CanvasWidget, file: *const fizzy.Internal.File, stroke_size: usize) dvui.Rect {
    const vis = canvas.dataFromScreenRect(canvas.rect);
    const m: f32 = @floatFromInt(stroke_size);
    const inflated = vis.outsetAll(m);
    const iw = @as(f32, @floatFromInt(file.width()));
    const ih = @as(f32, @floatFromInt(file.height()));
    return dvui.Rect.intersect(inflated, .{ .x = 0, .y = 0, .w = iw, .h = ih });
}

fn expandTempGpuDirtyRect(editor: *fizzy.Internal.File.EditorData, rect: dvui.Rect) void {
    if (editor.temp_gpu_dirty_rect) |existing| {
        editor.temp_gpu_dirty_rect = existing.unionWith(rect);
    } else {
        editor.temp_gpu_dirty_rect = rect;
    }
}

/// Clears the pixels covered by the current temp preview dirty rect, then
/// resets the tracking state. Used before redrawing the brush preview at a
/// new position.
fn clearTempPreview(editor: *fizzy.Internal.File.EditorData) void {
    if (editor.temp_preview_dirty_rect) |dirty| {
        if (dirty.w > 0 and dirty.h > 0) {
            fizzy.image.clearRect(editor.temporary_layer.source, dirty);
            expandTempGpuDirtyRect(editor, dirty);
        }
    }
    editor.temp_preview_dirty_rect = null;
}

/// Clears the temporary brush preview layer and marks GPU/composite dirty.
fn resetTempLayerPreview(editor: *fizzy.Internal.File.EditorData) void {
    if (editor.temp_preview_dirty_rect) |dirty| {
        if (dirty.w > 0 and dirty.h > 0) {
            fizzy.image.clearRect(editor.temporary_layer.source, dirty);
            expandTempGpuDirtyRect(editor, dirty);
        }
        editor.temp_preview_dirty_rect = null;
    } else if (editor.temp_layer_has_content) {
        @memset(editor.temporary_layer.pixels(), .{ 0, 0, 0, 0 });
        editor.temporary_layer.invalidate();
        editor.temp_gpu_dirty_rect = null;
    }
    editor.temp_layer_has_content = false;
    editor.temporary_layer.clearMask();
}

test {
    @import("std").testing.refAllDecls(@This());
}
