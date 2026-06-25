const std = @import("std");
const zgui = @import("zgui");
const History = @This();
const dvui = @import("dvui");
const Layer = @import("Layer.zig");
const pixi_mod = @import("../../pixi.zig");
const plugin = @import("../plugin.zig");
const runtime = @import("../runtime.zig");

pub const Action = enum { undo, redo };
pub const RestoreDelete = enum { restore, delete };
pub const ChangeType = enum {
    pixels,
    origins,
    animation_name,
    animation_frames,
    animation_settings,
    animation_order,
    animation_restore_delete,
    layers_order,
    layer_restore_delete,
    layer_name,
    layer_settings,
    resize,
    reorder_col_row,
    reorder_cell,
    layer_merge,
    grid_layout,
};

pub const Change = union(ChangeType) {
    pub const Pixels = struct {
        layer_id: u64,
        indices: []usize,
        values: [][4]u8,
        temporary: bool = false,
    };

    pub const Origins = struct {
        indices: []usize,
        values: [][2]f32,
    };

    pub const AnimationName = struct {
        index: usize,
        name: []u8,
    };

    pub const AnimationSettings = struct {
        index: usize,
        fps: f32,
    };

    pub const AnimationOrder = struct {
        order: []u64,
        selected: usize,
    };

    pub const AnimationFrames = struct {
        index: usize,
        frames: []pixi_mod.Animation.Frame,
    };

    pub const AnimationRestoreDelete = struct {
        index: usize,
        action: RestoreDelete,
    };

    pub const LayersOrder = struct {
        order: []u64,
        selected: usize,
    };

    pub const LayerRestoreDelete = struct {
        index: usize,
        action: RestoreDelete,
    };

    pub const LayerMerge = struct {
        pub const Kind = enum { up, down };

        kind: Kind,
        /// Index of the merged-away layer before removal.
        source_index: usize,
        dest_layer_id: u64,
        source_layer_id: u64,
        dest_pixels_before: [][4]u8,
        dest_mask_before: std.DynamicBitSet,
    };
    pub const LayerName = struct {
        index: usize,
        name: []u8,
    };
    pub const LayerSettings = struct {
        index: usize,
        visible: bool,
        collapse: bool,
    };

    pub const Resize = struct {
        width: u32,
        height: u32,
    };

    pub const ColumnRowReorder = struct {
        pub const Mode = enum {
            columns,
            rows,
        };

        mode: Mode,
        removed_index: usize,
        insert_before_index: usize,
    };

    pub const CellReorder = struct {
        removed_sprite_indices: []usize,
        insert_before_sprite_indices: []usize,
    };

    /// Snapshot of all state that `File.applyGridLayout` mutates. Stored on the undo/redo stacks
    /// as the *previous* full state; `undoRedo` swaps the snapshot with the live file state to
    /// move forward or back. All slices are owned by the snapshot and freed in `deinit`.
    pub const GridLayout = struct {
        column_width: u32,
        row_height: u32,
        columns: u32,
        rows: u32,

        /// Layer ids in the order layers existed when the snapshot was captured. Pixel buffers are
        /// matched to live layers by id, not index, so layer-list reorderings between snapshots
        /// don't corrupt the restore.
        layer_ids: []u64,
        /// One full pixel buffer per id in `layer_ids`, sized `column_width * columns * row_height * rows`.
        layer_pixels: [][][4]u8,

        sprite_origins: [][2]f32,

        selected_animation_index: ?usize,
        selected_animation_frame_index: usize,
        selected_layer_index: usize,
    };

    pixels: Pixels,
    origins: Origins,
    animation_name: AnimationName,
    animation_frames: AnimationFrames,
    animation_settings: AnimationSettings,
    animation_order: AnimationOrder,
    animation_restore_delete: AnimationRestoreDelete,
    layers_order: LayersOrder,
    layer_restore_delete: LayerRestoreDelete,
    layer_name: LayerName,
    layer_settings: LayerSettings,
    resize: Resize,
    reorder_col_row: ColumnRowReorder,
    reorder_cell: CellReorder,
    layer_merge: LayerMerge,
    grid_layout: GridLayout,

    pub fn create(allocator: std.mem.Allocator, field: ChangeType, len: usize) !Change {
        return switch (field) {
            .pixels => .{
                .pixels = .{
                    .layer_id = 0,
                    .indices = try allocator.alloc(usize, len),
                    .values = try allocator.alloc([4]u8, len),
                    .temporary = false,
                },
            },
            .origins => .{
                .origins = .{
                    .indices = try allocator.alloc(usize, len),
                    .values = try allocator.alloc([2]f32, len),
                },
            },
            .animation => .{
                .animation = .{
                    .index = 0,
                    .name = undefined,
                    .fps = 1,
                    .start = 0,
                    .length = 1,
                },
            },
            .layers_order => .{ .layers_order = .{
                .order = try allocator.alloc(usize, len),
                .selected = 0,
            } },
            .layer_name => .{ .animation_name = .{
                .name = [_:0]u8{0} ** pixi_mod.max_name_len,
                .index = 0,
            } },
            else => error.NotSupported,
        };
    }

    pub fn deinit(self: *Change) void {
        switch (self.*) {
            .pixels => |*pixels| {
                runtime.allocator().free(pixels.indices);
                runtime.allocator().free(pixels.values);
            },
            .origins => |*origins| {
                runtime.allocator().free(origins.indices);
                runtime.allocator().free(origins.values);
            },
            .layers_order => |*layers_order| {
                runtime.allocator().free(layers_order.order);
            },
            .layer_merge => |*layer_merge| {
                runtime.allocator().free(layer_merge.dest_pixels_before);
                layer_merge.dest_mask_before.deinit();
            },
            .grid_layout => |*gl| {
                for (gl.layer_pixels) |buf| runtime.allocator().free(buf);
                runtime.allocator().free(gl.layer_pixels);
                runtime.allocator().free(gl.layer_ids);
                runtime.allocator().free(gl.sprite_origins);
            },
            else => {},
        }
    }
};

bookmark: i32 = 0,
undo_stack: std.array_list.Managed(Change),
redo_stack: std.array_list.Managed(Change),

undo_layer_data_stack: std.array_list.Managed([][][4]u8),
redo_layer_data_stack: std.array_list.Managed([][][4]u8),

undo_animation_data_stack: std.array_list.Managed([][]pixi_mod.Animation.Frame),
redo_animation_data_stack: std.array_list.Managed([][]pixi_mod.Animation.Frame),

undo_sprite_data_stack: std.array_list.Managed([][2]f32),
redo_sprite_data_stack: std.array_list.Managed([][2]f32),

pub fn init(allocator: std.mem.Allocator) History {
    return .{
        .undo_stack = std.array_list.Managed(Change).init(allocator),
        .redo_stack = std.array_list.Managed(Change).init(allocator),

        .undo_layer_data_stack = std.array_list.Managed([][][4]u8).init(allocator),
        .redo_layer_data_stack = std.array_list.Managed([][][4]u8).init(allocator),

        .undo_animation_data_stack = std.array_list.Managed([][]pixi_mod.Animation.Frame).init(allocator),
        .redo_animation_data_stack = std.array_list.Managed([][]pixi_mod.Animation.Frame).init(allocator),

        .undo_sprite_data_stack = std.array_list.Managed([][2]f32).init(allocator),
        .redo_sprite_data_stack = std.array_list.Managed([][2]f32).init(allocator),
    };
}

pub fn append(self: *History, change: Change) !void {
    const track_pixels = pixi_mod.perf.record and std.meta.activeTag(change) == .pixels;
    const pixel_slots: usize = if (track_pixels) switch (change) {
        .pixels => |p| p.indices.len,
        else => 0,
    } else 0;
    const t_hist: i128 = if (track_pixels) pixi_mod.perf.nanoTimestamp() else 0;

    if (self.redo_stack.items.len > 0) {
        for (self.redo_stack.items) |*c| {
            Change.deinit(c);
        }
        self.redo_stack.clearRetainingCapacity();
    }

    if (self.redo_layer_data_stack.items.len > 0) {
        for (self.redo_layer_data_stack.items) |data| {
            for (data) |layer| {
                runtime.allocator().free(layer);
            }
            runtime.allocator().free(data);
        }
        self.redo_layer_data_stack.clearRetainingCapacity();
    }

    // Equality check, don't append if equal
    var equal: bool = self.undo_stack.items.len > 0;
    if (self.undo_stack.getLastOrNull()) |last| {
        const last_active_tag = std.meta.activeTag(last);
        const change_active_tag = std.meta.activeTag(change);

        if (last_active_tag == change_active_tag) {
            switch (last) {
                .origins => |origins| {
                    if (std.mem.eql(usize, origins.indices, change.origins.indices)) {
                        for (origins.values, 0..) |value, i| {
                            if (!std.mem.eql(f32, &value, &change.origins.values[i])) {
                                equal = false;
                                break;
                            }
                        }
                    } else {
                        equal = false;
                    }
                },
                .pixels => |pixels| {
                    equal = pixels.layer_id == change.pixels.layer_id;
                    if (equal) {
                        equal = std.mem.eql(usize, pixels.indices, change.pixels.indices);
                    }
                    if (equal) {
                        for (pixels.values, 0..) |value, i| {
                            equal = std.mem.eql(u8, &value, &change.pixels.values[i]);
                            if (!equal) break;
                        }
                    }
                },
                .animation_name => {
                    equal = false;
                },
                .animation_frames => {
                    equal = false;
                },
                .animation_settings => {
                    equal = false;
                },
                .animation_order => {
                    equal = false;
                },
                .animation_restore_delete => {
                    equal = false;
                },
                .layers_order => {
                    equal = false;
                },
                .layer_restore_delete => {
                    equal = false;
                },
                .layer_name => {
                    equal = false;
                },
                .layer_settings => {
                    equal = false;
                },
                .resize => {
                    equal = false;
                },
                .reorder_col_row => {
                    equal = false;
                },
                .reorder_cell => {
                    equal = false;
                },
                .layer_merge => {
                    equal = false;
                },
                .grid_layout => {
                    equal = false;
                },
            }
        } else equal = false;
    }

    if (equal) {
        var discard = change;
        Change.deinit(&discard);
    } else {
        try self.undo_stack.append(change);
        self.bookmark += 1;
    }

    if (track_pixels and t_hist != 0) {
        pixi_mod.perf.history_append_pixels_ns +%= @intCast(pixi_mod.perf.nanoTimestamp() - t_hist);
        pixi_mod.perf.history_append_pixels_calls += 1;
        pixi_mod.perf.history_append_pixels_slots +%= pixel_slots;
    }
}

fn layerMergeUndo(file: *pixi_mod.internal.File, lm: *Change.LayerMerge) !void {
    const dest_i = for (file.layers.items(.id), 0..) |id, i| {
        if (id == lm.dest_layer_id) break i;
    } else return error.InvalidLayerMerge;

    var dest = file.layers.get(dest_i);
    @memcpy(dest.pixels(), lm.dest_pixels_before);
    dest.mask.deinit();
    dest.mask = try lm.dest_mask_before.clone(runtime.allocator());
    dest.invalidate();
    file.layers.set(dest_i, dest);

    const restored = file.deleted_layers.pop() orelse return error.InvalidLayerMerge;
    try file.layers.insert(runtime.allocator(), lm.source_index, restored);

    file.editor.layer_composite_dirty = true;
    file.editor.split_composite_dirty = true;
    file.selected_layer_index = lm.source_index;
    runtime.state().host.setActiveSidebarView(plugin.view_tools);
    file.invalidateActiveLayerTransparencyMaskCache();
}

fn layerMergeRedo(file: *pixi_mod.internal.File, lm: *Change.LayerMerge) !void {
    const src_i = for (file.layers.items(.id), 0..) |id, i| {
        if (id == lm.source_layer_id) break i;
    } else return error.InvalidLayerMerge;
    const dest_i = for (file.layers.items(.id), 0..) |id, i| {
        if (id == lm.dest_layer_id) break i;
    } else return error.InvalidLayerMerge;

    switch (lm.kind) {
        .up => if (dest_i + 1 != src_i) return error.InvalidLayerMerge,
        .down => if (src_i + 1 != dest_i) return error.InvalidLayerMerge,
    }

    var dest = file.layers.get(dest_i);
    const src = file.layers.get(src_i);

    for (0..dest.pixels().len) |i| {
        const dpx = dest.pixels()[i];
        const spx = src.pixels()[i];
        dest.pixels()[i] = switch (lm.kind) {
            .up => Layer.blendPmaSrcOver(dpx, spx),
            .down => Layer.blendPmaSrcOver(spx, dpx),
        };
    }
    dest.mask.setUnion(src.mask);
    dest.invalidate();
    file.layers.set(dest_i, dest);

    try file.deleted_layers.append(runtime.allocator(), file.layers.slice().get(src_i));
    file.layers.orderedRemove(src_i);

    file.editor.layer_composite_dirty = true;
    file.editor.split_composite_dirty = true;

    file.selected_layer_index = switch (lm.kind) {
        .up => dest_i,
        .down => dest_i - 1,
    };
    runtime.state().host.setActiveSidebarView(plugin.view_tools);
    file.invalidateActiveLayerTransparencyMaskCache();
}

// Handling cases in this function details how an undo/redo action works, and must be symmetrical.
// This means that `change` needs to be modified to contain the active state prior to changing the active state
pub fn undoRedo(self: *History, file: *pixi_mod.internal.File, action: Action) !void {
    var active_stack = switch (action) {
        .undo => &self.undo_stack,
        .redo => &self.redo_stack,
    };

    var other_stack = switch (action) {
        .undo => &self.redo_stack,
        .redo => &self.undo_stack,
    };

    if (active_stack.items.len == 0) return;

    var temporary: bool = false;

    // Modify this change before its put into the other stack.
    var change = active_stack.pop().?;

    defer {
        // Microseconds-since-epoch (~1.7e15) overflows a 32-bit `usize` on wasm32, so a
        // direct `@intCast` to `usize` crashes the safe-mode build with an "integer cast
        // truncates value" panic every time the user undoes/redoes. `id_extra` only needs
        // to be a salt that varies between toasts, so truncate via u128 → low bits of usize.
        const ts_us: u128 = @intCast(@divTrunc(pixi_mod.perf.nanoTimestamp(), 1000));
        const id_mutex = dvui.toastAdd(dvui.currentWindow(), @src(), @truncate(ts_us), file.editor.canvas.id, pixi_mod.core.dvui.toastDisplay, 2_000_000);
        const id = id_mutex.id;
        const action_text = switch (action) {
            .undo => "Undo:",
            .redo => "Redo:",
        };
        var message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s}", .{action_text}) catch "Invalid change";

        switch (change) {
            .pixels => |*pixels| {
                for (file.layers.items(.name), file.layers.items(.id)) |name, layer_id| {
                    if (layer_id == pixels.layer_id) {
                        message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} Layer {s} pixels modified", .{ action_text, name }) catch "Invalid change";
                        break;
                    }
                }
            },
            .origins => {
                message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} Sprite origins modified", .{action_text}) catch "Invalid change";
            },
            .animation_name => |*animation_name| {
                message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} Animation name {s} -> {s}", .{
                    action_text,
                    animation_name.name,
                    file.animations.items(.name)[animation_name.index],
                }) catch "Invalid change";
            },
            .animation_frames => |*animation_frames| {
                message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} Animation {s} frames modified", .{
                    action_text,
                    file.animations.items(.name)[animation_frames.index],
                }) catch "Invalid change";
            },
            .animation_settings => |*animation_settings| {
                message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} Animation {s} settings modified", .{
                    action_text,
                    file.animations.items(.name)[animation_settings.index],
                }) catch "Invalid change";
            },
            .animation_order => {
                message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} Animations order modified", .{action_text}) catch "Invalid change";
            },
            .animation_restore_delete => |*animation_restore_delete| {
                switch (animation_restore_delete.action) {
                    .restore => {
                        message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} Animation {s} deleted", .{
                            action_text,
                            file.deleted_animations.items(.name)[file.deleted_animations.len - 1],
                        }) catch "Invalid change";
                    },
                    .delete => {
                        message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} Animation {s} created", .{
                            action_text,
                            file.animations.items(.name)[animation_restore_delete.index],
                        }) catch "Invalid change";
                    },
                }
            },
            .layers_order => {
                message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} Layers order modified", .{action_text}) catch "Invalid change";
            },
            .layer_restore_delete => |*layer_restore_delete| {
                switch (layer_restore_delete.action) {
                    .restore => {
                        message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} Layer {s} deleted", .{
                            action_text,
                            file.deleted_layers.items(.name)[file.deleted_layers.len - 1],
                        }) catch "Invalid change";
                    },
                    .delete => {
                        message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} Layer {s} created", .{
                            action_text,
                            file.layers.items(.name)[layer_restore_delete.index],
                        }) catch "Invalid change";
                    },
                }
            },
            .layer_name => |*layer_name| {
                message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} Layer name {s} -> {s}", .{
                    action_text,
                    layer_name.name,
                    file.layers.items(.name)[layer_name.index],
                }) catch "Invalid change";
            },
            .layer_settings => |*layer_settings| {
                message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} Layer {s} settings modified", .{
                    action_text,
                    file.layers.items(.name)[layer_settings.index],
                }) catch "Invalid change";
            },
            .resize => {
                message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} File resized to {d}x{d}", .{
                    action_text,
                    file.width(),
                    file.height(),
                }) catch "Invalid change";
            },
            .reorder_col_row => |*reorder| {
                const removed = reorder.removed_index;
                const insert_before = reorder.insert_before_index;
                switch (reorder.mode) {
                    .columns => {
                        const removed_column_name = file.fmtColumn(dvui.currentWindow().arena(), removed) catch "Invalid change";
                        const insert_before_column_name = file.fmtColumn(dvui.currentWindow().arena(), insert_before - 1) catch "Invalid change";
                        message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} Column {s} moved to {s}", .{ action_text, insert_before_column_name, removed_column_name }) catch "Invalid change";
                    },
                    .rows => {
                        message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} Row {d} moved to {d}", .{ action_text, insert_before, removed }) catch "Invalid change";
                    },
                }
            },
            .reorder_cell => {
                message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} Cells reordered", .{action_text}) catch "Invalid change";
            },
            .layer_merge => {
                message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} Layer merge", .{action_text}) catch "Invalid change";
            },
            .grid_layout => {
                message = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} Grid layout {d}×{d} cells of {d}×{d}", .{
                    action_text,
                    file.columns,
                    file.rows,
                    file.column_width,
                    file.row_height,
                }) catch "Invalid change";
            },
        }

        dvui.dataSetSlice(dvui.currentWindow(), id, "_message", message);
        id_mutex.mutex.unlock(dvui.io);
    }

    switch (change) {
        .pixels => |*pixels| {
            if (pixels.temporary) temporary = true;

            const layer_index = for (file.layers.slice().items(.id), 0..) |layer_id, i| {
                if (layer_id == pixels.layer_id) break i;
            } else 0;

            var layer = file.layers.slice().get(layer_index);

            for (pixels.indices, 0..) |pixel_index, i| {
                std.mem.swap([4]u8, &pixels.values[i], &layer.pixels()[pixel_index]);
            }

            layer.invalidate();
            file.selected_layer_index = layer_index;
            file.invalidateActiveLayerTransparencyMaskCache();
        },
        .origins => |*origins| {
            //file.editor.selected_sprites.clearAndFree();
            for (origins.indices, 0..) |sprite_index, i| {
                const origin = origins.values[i];
                origins.values[i] = file.sprites.items(.origin)[sprite_index];
                file.sprites.items(.origin)[sprite_index] = origin;

                //try file.editor.selected_sprites.append(sprite_index);
            }
            runtime.state().host.setActiveSidebarView(plugin.view_sprites);
        },
        .layers_order => |*layers_order| {
            file.editor.layer_composite_dirty = true;
            file.editor.split_composite_dirty = true;
            // `new_order` holds layer ids (u64 in the on-disk format), not
            // indices — `layers_order.order` below is `[]u64` so this matches.
            var new_order = try runtime.allocator().alloc(u64, layers_order.order.len);
            for (0..file.layers.len) |layer_index| {
                new_order[layer_index] = file.layers.items(.id)[layer_index];
            }

            const slice = file.layers.slice();

            for (layers_order.order, 0..) |id, i| {
                if (slice.items(.id)[i] == id) continue;

                // Save current layer
                const current_layer = slice.get(i);
                layers_order.order[i] = current_layer.id;

                // Make changes to the layers
                var other_layer_index: usize = 0;
                while (other_layer_index < file.layers.len) : (other_layer_index += 1) {
                    const layer = slice.get(other_layer_index);
                    if (layer.id == layers_order.selected) {
                        file.selected_layer_index = other_layer_index;
                    }
                    if (layer.id == id) {
                        file.layers.set(i, layer);
                        file.layers.set(other_layer_index, current_layer);
                        continue;
                    }
                }
            }

            @memcpy(layers_order.order, new_order);
            runtime.allocator().free(new_order);
            file.invalidateActiveLayerTransparencyMaskCache();
        },
        .layer_restore_delete => |*layer_restore_delete| {
            file.editor.layer_composite_dirty = true;
            file.editor.split_composite_dirty = true;
            const a = layer_restore_delete.action;
            switch (a) {
                .restore => {
                    try file.layers.insert(runtime.allocator(), layer_restore_delete.index, file.deleted_layers.pop().?);
                    layer_restore_delete.action = .delete;
                },
                .delete => {
                    try file.deleted_layers.append(runtime.allocator(), file.layers.slice().get(layer_restore_delete.index));
                    file.layers.orderedRemove(layer_restore_delete.index);
                    layer_restore_delete.action = .restore;
                },
            }
            runtime.state().host.setActiveSidebarView(plugin.view_tools);
            file.invalidateActiveLayerTransparencyMaskCache();
        },
        .layer_name => |*layer_name| {
            const name = try runtime.allocator().dupe(u8, file.layers.items(.name)[layer_name.index]);
            runtime.allocator().free(file.layers.items(.name)[layer_name.index]);
            file.layers.items(.name)[layer_name.index] = try runtime.allocator().dupe(u8, layer_name.name);
            layer_name.name = name;
            runtime.state().host.setActiveSidebarView(plugin.view_tools);
        },
        .layer_settings => |*layer_settings| {
            const idx = layer_settings.index;
            const cur_visible = file.layers.items(.visible)[idx];
            const cur_collapse = file.layers.items(.collapse)[idx];
            const incoming_visible = layer_settings.visible;
            const visibility_changed = cur_visible != incoming_visible;

            file.layers.items(.visible)[idx] = incoming_visible;
            file.layers.items(.collapse)[idx] = layer_settings.collapse;
            layer_settings.visible = cur_visible;
            layer_settings.collapse = cur_collapse;

            // Split composites only depend on layer visibility, not row collapse in the layer list.
            file.editor.layer_composite_dirty = true;
            if (visibility_changed) {
                file.editor.split_composite_dirty = true;
            }
            runtime.state().host.setActiveSidebarView(plugin.view_tools);
        },
        .animation_restore_delete => |*animation_restore_delete| {
            const a = animation_restore_delete.action;
            switch (a) {
                .restore => {
                    const animation = file.deleted_animations.pop().?;
                    try file.animations.insert(runtime.allocator(), animation_restore_delete.index, animation);
                    animation_restore_delete.action = .delete;
                    file.selected_animation_index = animation_restore_delete.index;
                },
                .delete => {
                    const animation = file.animations.slice().get(animation_restore_delete.index);
                    file.animations.orderedRemove(animation_restore_delete.index);
                    try file.deleted_animations.append(runtime.allocator(), animation);
                    animation_restore_delete.action = .restore;

                    if (file.selected_animation_index) |selected_animation_index| {
                        if (file.animations.len == 0) {
                            file.selected_animation_index = null;
                        } else if (selected_animation_index >= file.animations.len) {
                            file.selected_animation_index = file.animations.len - 1;
                        }
                    }
                },
            }
            runtime.state().host.setActiveSidebarView(plugin.view_sprites);
        },
        .animation_name => |*animation_name| {
            const name = try runtime.allocator().dupe(u8, file.animations.items(.name)[animation_name.index]);
            runtime.allocator().free(file.animations.items(.name)[animation_name.index]);
            file.animations.items(.name)[animation_name.index] = try runtime.allocator().dupe(u8, animation_name.name);
            animation_name.name = name;
            runtime.state().host.setActiveSidebarView(plugin.view_sprites);
        },
        .animation_settings => {},
        .animation_order => |*animation_order| {
            // `new_order` holds animation ids (u64), matching `animation_order.order: []u64`.
            var new_order = try dvui.currentWindow().arena().alloc(u64, animation_order.order.len);
            for (0..file.animations.len) |anim_index| {
                new_order[anim_index] = file.animations.items(.id)[anim_index];
            }

            for (animation_order.order, 0..) |id, i| {
                // Save current animation
                const current_animation = file.animations.get(i);
                animation_order.order[i] = current_animation.id;

                // Make changes to the animations
                var other_animation_index: usize = 0;
                while (other_animation_index < file.animations.len) : (other_animation_index += 1) {
                    const animation = file.animations.get(other_animation_index);
                    if (animation.id == animation_order.selected) {
                        file.selected_animation_index = other_animation_index;
                    }
                    if (animation.id == id and current_animation.id != id) {
                        file.animations.set(i, animation);
                        file.animations.set(other_animation_index, current_animation);
                        continue;
                    }
                }
            }

            @memcpy(animation_order.order, new_order);

            file.selected_animation_index = animation_order.selected;
        },
        .animation_frames => |*animation_frames| {
            const history_frames = &animation_frames.frames;
            const current_frames = &file.animations.items(.frames)[animation_frames.index];

            std.mem.swap([]pixi_mod.Animation.Frame, history_frames, current_frames);

            file.selected_animation_index = animation_frames.index;
        },
        .resize => |*resize| {
            const new_size_wide = resize.width;
            const new_size_high = resize.height;
            resize.width = file.width();
            resize.height = file.height();

            var layer_data: ?[][][4]u8 = null;
            var animation_data: ?[][]pixi_mod.Animation.Frame = null;
            var sprite_data: ?[][2]f32 = null;

            switch (action) {
                .undo => {
                    if (self.undo_layer_data_stack.pop()) |ld| {
                        try self.redo_layer_data_stack.append(ld);
                        layer_data = ld;
                    }

                    if (self.undo_animation_data_stack.pop()) |ad| {
                        animation_data = ad;

                        var anim_data = try runtime.allocator().alloc([]pixi_mod.Animation.Frame, file.animations.len);
                        for (0..file.animations.len) |animation_index| {
                            anim_data[animation_index] = runtime.allocator().dupe(pixi_mod.Animation.Frame, file.animations.items(.frames)[animation_index]) catch return error.MemoryAllocationFailed;
                        }
                        try self.redo_animation_data_stack.append(anim_data);
                    }

                    if (self.undo_sprite_data_stack.pop()) |sd| {
                        sprite_data = sd;

                        const new_sprite_data = try runtime.allocator().alloc([2]f32, file.spriteCount());
                        for (0..file.spriteCount()) |sprite_index| {
                            new_sprite_data[sprite_index] = file.sprites.items(.origin)[sprite_index];
                        }
                        try self.redo_sprite_data_stack.append(new_sprite_data);
                    }
                },
                .redo => {
                    if (self.redo_layer_data_stack.pop()) |ld| {
                        try self.undo_layer_data_stack.append(ld);
                        layer_data = ld;
                    }
                    if (self.redo_animation_data_stack.pop()) |ad| {
                        animation_data = ad;

                        var anim_data = try runtime.allocator().alloc([]pixi_mod.Animation.Frame, file.animations.len);
                        for (0..file.animations.len) |animation_index| {
                            anim_data[animation_index] = runtime.allocator().dupe(pixi_mod.Animation.Frame, file.animations.items(.frames)[animation_index]) catch return error.MemoryAllocationFailed;
                        }
                        try self.undo_animation_data_stack.append(anim_data);
                    }
                    if (self.redo_sprite_data_stack.pop()) |sd| {
                        sprite_data = sd;

                        const new_sprite_data = try runtime.allocator().alloc([2]f32, file.spriteCount());
                        for (0..file.spriteCount()) |sprite_index| {
                            new_sprite_data[sprite_index] = file.sprites.items(.origin)[sprite_index];
                        }
                        try self.undo_sprite_data_stack.append(new_sprite_data);
                    }
                },
            }

            file.resize(.{
                .columns = @divTrunc(new_size_wide, file.column_width),
                .rows = @divTrunc(new_size_high, file.row_height),
                .history = false,
                .layer_data = layer_data,
                .animation_data = animation_data,
                .sprite_data = sprite_data,
            }) catch return error.ResizeError;

            if (animation_data) |ad| {
                runtime.allocator().free(ad);
            }

            if (sprite_data) |sd| {
                runtime.allocator().free(sd);
            }

            file.invalidateActiveLayerTransparencyMaskCache();
        },
        .reorder_col_row => |*reorder| {
            switch (reorder.mode) {
                .columns => file.reorderColumns(reorder.removed_index, reorder.insert_before_index) catch return error.ReorderError,
                .rows => file.reorderRows(reorder.removed_index, reorder.insert_before_index) catch return error.ReorderError,
            }

            const prev_removed_index = reorder.removed_index;
            const prev_insert_before_index = reorder.insert_before_index;

            if (prev_removed_index < prev_insert_before_index) {
                // Column was removed before the insert position, so it "shifts left" after being inserted.
                reorder.removed_index = prev_insert_before_index - 1;
                reorder.insert_before_index = prev_removed_index;
            } else {
                reorder.removed_index = prev_insert_before_index;
                reorder.insert_before_index = prev_removed_index + 1;
            }

            file.invalidateActiveLayerTransparencyMaskCache();
        },

        .reorder_cell => |*reorder| {
            const reverse = (action == .undo);
            file.reorderCells(reorder.removed_sprite_indices, reorder.insert_before_sprite_indices, .replace, reverse) catch return error.ReorderError;
            file.invalidateActiveLayerTransparencyMaskCache();
        },
        .layer_merge => |*layer_merge| {
            switch (action) {
                .undo => try layerMergeUndo(file, layer_merge),
                .redo => try layerMergeRedo(file, layer_merge),
            }
        },
        .grid_layout => |*gl| {
            // Symmetric swap: capture live state into a fresh snapshot, restore the popped one
            // into the file, then put the fresh snapshot in place of the popped one (which is
            // now redundant — its data lives in the file again). The fresh snapshot rides the
            // normal `append` below to the opposite stack.
            const fresh = try file.captureGridLayoutSnapshot();
            file.applyGridLayoutSnapshot(gl.*) catch |err| {
                var fresh_ch = Change{ .grid_layout = fresh };
                Change.deinit(&fresh_ch);
                return err;
            };
            var old_ch = Change{ .grid_layout = gl.* };
            Change.deinit(&old_ch);
            gl.* = fresh;
        },
    }

    if (!temporary) {
        try other_stack.append(change);
    } else {
        var discard = change;
        Change.deinit(&discard);
    }

    self.bookmark += switch (action) {
        .undo => -1,
        .redo => 1,
    };
}

pub fn clearAndFree(self: *History) void {
    for (self.undo_stack.items) |*u| {
        Change.deinit(u);
    }
    for (self.redo_stack.items) |*r| {
        Change.deinit(r);
    }
    self.undo_stack.clearAndFree();
    self.redo_stack.clearAndFree();
}

pub fn clearRetainingCapacity(self: *History) void {
    for (self.undo_stack.items) |*u| {
        Change.deinit(u);
    }
    for (self.redo_stack.items) |*r| {
        Change.deinit(r);
    }
    self.undo_stack.clearRetainingCapacity();
    self.redo_stack.clearRetainingCapacity();
}

pub fn deinit(self: *History) void {
    for (self.undo_layer_data_stack.items) |data| {
        for (data) |layer| {
            runtime.allocator().free(layer);
        }
        runtime.allocator().free(data);
    }

    for (self.redo_layer_data_stack.items) |data| {
        for (data) |layer| {
            runtime.allocator().free(layer);
        }
        runtime.allocator().free(data);
    }

    self.undo_layer_data_stack.deinit();
    self.redo_layer_data_stack.deinit();
    self.clearAndFree();
    self.undo_stack.deinit();
    self.redo_stack.deinit();
}
