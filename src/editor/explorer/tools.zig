const std = @import("std");
const builtin = @import("builtin");
const fizzy = @import("../../fizzy.zig");
const dvui = @import("dvui");
const icons = @import("icons");
const assets = @import("assets");

const Tools = @This();

var insert_before_index: ?usize = null;
/// Sorted (ascending) list of layer indices whose TreeWidget branch reported `removed()` on the
/// last frame's drag completion. Used by the drop handler to reorder multiple selected layers as
/// a group. Bounded because layer count is expected to be modest in practice.
var removed_layer_indices_buf: [64]usize = undefined;
var removed_layer_indices_len: usize = 0;
var edit_layer_id: ?u64 = null;
var prev_layer_count: usize = 0;
var max_split_ratio: f32 = 0.4;

/// In-flight primary-button gesture for the active file's layer list (reorder / click / rename).
/// Not stored in `dvui.data`: a single path at end of `drawLayers` processes events after rename `textEntry`.
const LayerRowGesture = struct {
    file_id: u64,
    press_idx: usize,
    press_p: dvui.Point.Physical,
    drag_branch: ?usize,
    moved: bool,
    reorder_drag: bool,
    /// True when the press landed on a row that was already part of the current multi-selection
    /// with no modifier key. We preserve the full selection so the user can drag the whole group;
    /// on release without drag we narrow the selection to just `press_idx` (Finder-style).
    narrow_on_release: bool,
};
var layer_row_gesture: ?LayerRowGesture = null;

/// Filled while the layer rename text entry exists so `processLayerTreePointerEvents` can skip those hits.
var layer_rename_hit_te_id: ?dvui.Id = null;
var layer_rename_hit_rect: ?dvui.Rect.Physical = null;

layers_rect: ?dvui.Rect.Physical = null,
/// Visible clip of the layer list (scroll container content rect). Rows can have screen rects that
/// extend below this when scrolled; without gating, those rects overlap the palettes pane and steal hover/input.
layers_scroll_viewport_rect: ?dvui.Rect.Physical = null,

pub fn init() Tools {
    return .{};
}

pub fn draw(self: *Tools) !void {
    var tools_top = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = false,
    });
    defer tools_top.deinit();

    // First time (or after the tools pane was not drawn last frame), horizontal boxes lack
    // published min sizes and can lay out like a vertical stack for one frame. Clip drawing
    // until the next frame when sizes settle.
    const tools_top_settling = dvui.firstFrame(tools_top.data().id);
    const prev_clip: ?dvui.Rect.Physical = if (tools_top_settling)
        dvui.clip(.{ .x = 0, .y = 0, .w = 0, .h = 0 })
    else
        null;

    drawTools() catch {};
    if (prev_clip) |p| dvui.clipSet(p);
    drawColors() catch {};
    drawLayerControls() catch {};

    // Collect layers length to trigger a refit of the panel
    const layer_count: usize = if (fizzy.editor.activeFile()) |file| file.layers.len else 0;
    defer prev_layer_count = layer_count;

    var paned = fizzy.dvui.paned(@src(), .{
        .direction = .vertical,
        .collapsed_size = 0,
        .handle_size = 10,
        .handle_dynamic = .{},
    }, .{ .expand = .both, .background = false });
    defer paned.deinit();

    if (paned.dragging) {
        max_split_ratio = paned.split_ratio.*;
        fizzy.editor.explorer.layers_ratio = paned.split_ratio.*;
    }

    if (paned.showFirst()) {
        self.layers_rect = self.drawLayers() catch {
            dvui.log.err("Failed to draw layers", .{});
            return;
        };
    } else {
        self.layers_rect = null;
        self.layers_scroll_viewport_rect = null;
    }

    const autofit = !paned.dragging and !paned.collapsed_state and !paned.animating;

    // Refit must be done between showFirst and showSecond
    if (((dvui.firstFrame(paned.data().id) or prev_layer_count != layer_count) or autofit) and !fizzy.editor.explorer.pinned_palettes) {
        if (dvui.firstFrame(paned.data().id) and layer_count == 0)
            paned.split_ratio.* = 0.0;

        // `firstFrame` is also true the first time we see the paned after it was not drawn
        // (e.g. another explorer tab was active). Min sizes for the subtree are not published
        // from the prior frame, so getFirstFittedRatio can be clamped to max_split, then a
        // second pass animates to the true fit. Restore from the saved ratio; refit+animate
        // next frame when min sizes are valid.
        if (dvui.firstFrame(paned.data().id) and layer_count > 0) {
            paned.split_ratio.* = 0.01;
            //fizzy.editor.explorer.layers_ratio = paned.split_ratio.*;
        } else {
            const ratio = paned.getFirstFittedRatio(
                .{
                    .min_split = 0,
                    .max_split = @min(max_split_ratio, 0.75),
                    .min_size = 0,
                },
            );

            const diff = @abs(ratio - paned.split_ratio.*);

            if (diff > 0.000001 and layer_count > 0) {
                paned.animateSplit(ratio, dvui.easing.outBack);
            }
        }
    } else {
        if (dvui.firstFrame(paned.data().id)) {
            if (layer_count == 0)
                paned.split_ratio.* = 0.0
            else
                paned.split_ratio.* = fizzy.editor.explorer.layers_ratio;

            fizzy.editor.explorer.layers_ratio = paned.split_ratio.*;
        }
    }

    if (paned.showSecond()) {
        drawPaletteControls() catch {};
        drawPalettes() catch {};
    }
}

pub fn layersHovered(self: *Tools) bool {
    const mp = dvui.currentWindow().mouse_pt;
    if (self.layers_scroll_viewport_rect) |vr| {
        if (!vr.contains(mp)) return false;
    }
    if (self.layers_rect) |rect| {
        return rect.contains(mp);
    }
    return false;
}

pub fn drawTools() !void {
    const toolbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .none,
        .gravity_x = 0.5,
        .padding = .{ .h = 10.0, .w = 4.0, .x = 4.0, .y = 4.0 },
    });
    defer toolbox.deinit();
    for (0..std.meta.fields(fizzy.Editor.Tools.Tool).len) |i| {
        const tool: fizzy.Editor.Tools.Tool = @enumFromInt(i);
        const id_extra = i;

        const selected = fizzy.editor.tools.current == tool;

        var color = dvui.themeGet().color(.control, .fill_hover);
        if (fizzy.editor.colors.file_tree_palette) |*palette| {
            color = palette.getDVUIColor(i);
        }

        const selection_sprite = switch (fizzy.editor.tools.selection_mode) {
            .pixel => fizzy.editor.atlas.data.sprites[fizzy.atlas.sprites.pixel_selection_default],
            .box => fizzy.editor.atlas.data.sprites[fizzy.atlas.sprites.box_selection_default],
            .color => fizzy.editor.atlas.data.sprites[fizzy.atlas.sprites.color_selection_default],
        };

        const sprite = switch (tool) {
            .pointer => fizzy.editor.atlas.data.sprites[fizzy.atlas.sprites.cursor_default],
            .pencil => fizzy.editor.atlas.data.sprites[fizzy.atlas.sprites.pencil_default],
            .eraser => fizzy.editor.atlas.data.sprites[fizzy.atlas.sprites.eraser_default],
            .bucket => fizzy.editor.atlas.data.sprites[fizzy.atlas.sprites.bucket_default],
            .selection => selection_sprite,
        };
        var button: dvui.ButtonWidget = undefined;
        button.init(@src(), .{}, .{
            .expand = .none,
            .min_size_content = .{ .w = 40, .h = 40 },
            .id_extra = id_extra,
            .background = true,
            .corner_radius = dvui.Rect.all(1000),
            .color_fill = if (selected) dvui.themeGet().color(.content, .fill) else .transparent,
            .color_fill_hover = dvui.themeGet().color(.content, .fill).lighten(if (dvui.themeGet().dark) 10.0 else -10.0),
            .box_shadow = if (selected) .{
                .color = .black,
                .offset = .{ .x = -2.5, .y = 2.5 },
                .fade = 4.0,
                .alpha = 0.25,
            } else null,
            .padding = .all(0),
            //.border = dvui.Rect.all(1.0),
            //.color_border = if (selected) color else dvui.themeGet().color(.control, .fill),
        });
        defer button.deinit();

        fizzy.editor.tools.drawTooltip(tool, button.data().rectScale().r, id_extra) catch {};

        if (button.hovered()) {
            button.data().options.color_border = color;
        }

        const size: dvui.Size = dvui.imageSize(fizzy.editor.atlas.source) catch .{ .w = 0, .h = 0 };

        const uv = dvui.Rect{
            .x = @as(f32, @floatFromInt(sprite.source[0])) / size.w,
            .y = @as(f32, @floatFromInt(sprite.source[1])) / size.h,
            .w = @as(f32, @floatFromInt(sprite.source[2])) / size.w,
            .h = @as(f32, @floatFromInt(sprite.source[3])) / size.h,
        };

        button.processEvents();
        button.drawBackground();

        var rs = button.data().contentRectScale();

        const width = @as(f32, @floatFromInt(sprite.source[2])) * rs.s;
        const height = @as(f32, @floatFromInt(sprite.source[3])) * rs.s;

        rs.r.x = @round(rs.r.x + (rs.r.w - width) / 2.0);
        rs.r.y = @round(rs.r.y + (rs.r.h - height) / 2.0);
        rs.r.w = width;
        rs.r.h = height;

        dvui.renderImage(fizzy.editor.atlas.source, rs, .{
            .uv = uv,
            .fade = 0.0,
        }) catch {
            dvui.log.err("Failed to render image", .{});
        };

        if (button.clicked()) {
            fizzy.editor.tools.set(tool);
        }
    }
}

pub fn drawLayerControls() !void {
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = false,
    });
    defer box.deinit();
    dvui.labelNoFmt(@src(), "LAYERS", .{}, .{ .font = dvui.Font.theme(.heading), .gravity_y = 0.5 });

    if (fizzy.editor.activeFile()) |file| {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .none,
            .background = false,
            .gravity_x = 1.0,
        });
        defer hbox.deinit();

        const merge_up_enabled = file.selected_layer_index > 0;
        const merge_down_enabled = file.selected_layer_index + 1 < file.layers.len;

        {
            const a = dvui.alpha(if (merge_up_enabled) 1.0 else 0.35);
            defer dvui.alphaSet(a);
            if (dvui.buttonIcon(@src(), "MergeLayerUp", icons.tvg.lucide.@"arrow-up-to-line", .{}, .{}, .{
                .expand = .none,
                .gravity_y = 0.5,
                .corner_radius = dvui.Rect.all(1000),
                .box_shadow = .{
                    .color = .black,
                    .offset = .{ .x = -2.0, .y = 2.0 },
                    .fade = 6.0,
                    .alpha = 0.15,
                    .corner_radius = dvui.Rect.all(1000),
                },
                .color_fill = dvui.themeGet().color(.control, .fill),
            })) {
                if (merge_up_enabled) {
                    file.mergeSelectedLayerUp() catch {
                        dvui.log.err("Failed to merge layer up", .{});
                    };
                }
            }
        }

        {
            const a = dvui.alpha(if (merge_down_enabled) 1.0 else 0.35);
            defer dvui.alphaSet(a);
            if (dvui.buttonIcon(@src(), "MergeLayerDown", icons.tvg.lucide.@"arrow-down-to-line", .{}, .{}, .{
                .expand = .none,
                .gravity_y = 0.5,
                .corner_radius = dvui.Rect.all(1000),
                .box_shadow = .{
                    .color = .black,
                    .offset = .{ .x = -2.0, .y = 2.0 },
                    .fade = 6.0,
                    .alpha = 0.15,
                    .corner_radius = dvui.Rect.all(1000),
                },
                .color_fill = dvui.themeGet().color(.control, .fill),
            })) {
                if (merge_down_enabled) {
                    file.mergeSelectedLayerDown() catch {
                        dvui.log.err("Failed to merge layer down", .{});
                    };
                }
            }
        }

        if (dvui.buttonIcon(
            @src(),
            "TogglePeek",
            if (file.editor.isolate_layer) icons.tvg.lucide.@"layers-2" else icons.tvg.lucide.layers,
            .{},
            .{},
            .{
                .expand = .none,
                .gravity_y = 0.5,
                .corner_radius = dvui.Rect.all(1000),
                .box_shadow = .{
                    .color = .black,
                    .offset = .{ .x = -2.0, .y = 2.0 },
                    .fade = 6.0,
                    .alpha = 0.15,
                    .corner_radius = dvui.Rect.all(1000),
                },
                .style = if (file.editor.isolate_layer) .highlight else .control,
            },
        )) {
            file.editor.isolate_layer = !file.editor.isolate_layer;
        }

        if (dvui.buttonIcon(@src(), "AddLayer", icons.tvg.lucide.plus, .{}, .{}, .{
            .expand = .none,
            .gravity_y = 0.5,
            .corner_radius = dvui.Rect.all(1000),
            .box_shadow = .{
                .color = .black,
                .offset = .{ .x = -2.0, .y = 2.0 },
                .fade = 6.0,
                .alpha = 0.15,
                .corner_radius = dvui.Rect.all(1000),
            },
            .color_fill = dvui.themeGet().color(.control, .fill),
        })) {
            if (file.createLayer() catch null) |id| {
                edit_layer_id = id;
            }
        }

        if (dvui.buttonIcon(@src(), "DuplicateLayer", icons.tvg.lucide.@"copy-plus", .{}, .{}, .{
            .expand = .none,
            .gravity_y = 0.5,
            .corner_radius = dvui.Rect.all(1000),
            .box_shadow = .{
                .color = .black,
                .offset = .{ .x = -2.0, .y = 2.0 },
                .fade = 6.0,
                .alpha = 0.15,
                .corner_radius = dvui.Rect.all(1000),
            },
            .color_fill = dvui.themeGet().color(.control, .fill),
        })) {
            if (file.duplicateLayer(file.selected_layer_index) catch null) |id| {
                edit_layer_id = id;
            }
        }

        if (file.layers.len > 1) {
            if (dvui.buttonIcon(@src(), "DeleteLayer", icons.tvg.lucide.trash, .{}, .{ .stroke_color = dvui.themeGet().color(.window, .fill) }, .{
                .style = .err,
                .expand = .none,
                .gravity_y = 0.5,
                .corner_radius = dvui.Rect.all(1000),
                .box_shadow = .{
                    .color = .black,
                    .offset = .{ .x = -2.0, .y = 2.0 },
                    .fade = 6.0,
                    .alpha = 0.15,
                    .corner_radius = dvui.Rect.all(1000),
                },
            })) {
                file.deleteLayer(file.selected_layer_index) catch {
                    dvui.log.err("Failed to delete layer", .{});
                };
            }
        }
    }
}

pub fn drawLayers(tools: *Tools) !?dvui.Rect.Physical {
    tools.layers_scroll_viewport_rect = null;

    const vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = false,
    });
    defer vbox.deinit();

    if (fizzy.editor.activeFile()) |file| {
        layer_rename_hit_te_id = null;
        layer_rename_hit_rect = null;
        file.editor.layer_drag_preview_removed = null;
        file.editor.layer_drag_preview_insert_before = null;

        var scroll_area = dvui.scrollArea(@src(), .{ .scroll_info = &file.editor.layers_scroll_info }, .{
            .expand = .both,
            .background = false,
            .corner_radius = dvui.Rect.all(1000),
        });

        defer scroll_area.deinit();

        // Visible clip for the layer list (same rect used for scroll content clipping). Row widgets can
        // still have screen rects extending below this when scrolled; gate hover/hits to this rect.
        if (dvui.ScrollContainerWidget.current()) |sc| {
            tools.layers_scroll_viewport_rect = sc.data().contentRectScale().r;
        }

        const vertical_scroll = file.editor.layers_scroll_info.offset(.vertical);

        var tree = fizzy.dvui.TreeWidget.tree(@src(), .{ .enable_reordering = true }, .{
            .expand = .horizontal,
            .background = false,
        });
        defer tree.deinit();

        var layer_hits_buf: [256]LayerRowHit = undefined;
        var layer_hits_len: usize = 0;

        // Drag and drop is completing — supports single- and multi-row drags.
        if (insert_before_index) |insert_before_raw| {
            if (removed_layer_indices_len > 0) {
                const sources = removed_layer_indices_buf[0..removed_layer_indices_len];

                const prev_order = try fizzy.app.allocator.alloc(u64, file.layers.len);
                for (file.layers.items(.id), 0..) |id, i| {
                    prev_order[i] = id;
                }

                const primary_before = file.selected_layer_index;
                var primary_was_moved: bool = false;
                var primary_pos_in_sources: usize = 0;
                for (sources, 0..) |s, pi| {
                    if (s == primary_before) {
                        primary_was_moved = true;
                        primary_pos_in_sources = pi;
                        break;
                    }
                }

                // Snapshot moved layers before any removal so indices stay valid.
                var moved = try fizzy.app.allocator.alloc(fizzy.Internal.Layer, sources.len);
                defer fizzy.app.allocator.free(moved);
                for (sources, 0..) |s, i| {
                    moved[i] = file.layers.get(s);
                }

                // Remove from highest → lowest so earlier indices aren't shifted.
                var ri = sources.len;
                while (ri > 0) {
                    ri -= 1;
                    file.layers.orderedRemove(sources[ri]);
                }

                const target_raw = fizzy.dvui.TreeSelection.adjustInsertBeforeForRemovals(sources, insert_before_raw);
                const target = @min(target_raw, file.layers.len);

                for (moved, 0..) |layer, i| {
                    file.layers.insert(fizzy.app.allocator, target + i, layer) catch {
                        dvui.log.err("Failed to insert layer", .{});
                    };
                }

                file.editor.layer_composite_dirty = true;
                file.editor.split_composite_dirty = true;

                if (primary_was_moved) {
                    file.selected_layer_index = target + primary_pos_in_sources;
                }

                // After a group move the moved rows become contiguous; resync multi-selection to reflect that.
                file.editor.selected_layer_indices.clearRetainingCapacity();
                for (0..moved.len) |i| {
                    file.editor.selected_layer_indices.append(fizzy.app.allocator, target + i) catch {
                        dvui.log.err("Failed to update layer selection", .{});
                    };
                }
                file.editor.layer_selection_anchor = file.selected_layer_index;

                if (!std.mem.eql(u64, file.layers.items(.id)[0..file.layers.len], prev_order)) {
                    file.history.append(.{
                        .layers_order = .{
                            .order = prev_order,
                            // Layer ids are u64 on disk; convert to the usize the
                            // history's `selected` field expects.
                            .selected = @intCast(file.layers.items(.id)[file.selected_layer_index]),
                        },
                    }) catch {
                        dvui.log.err("Failed to append history", .{});
                    };
                } else {
                    fizzy.app.allocator.free(prev_order);
                }

                insert_before_index = null;
                removed_layer_indices_len = 0;
            } else {
                insert_before_index = null;
            }
        } else if (removed_layer_indices_len > 0) {
            // Drag ended without a valid drop target; discard the removal intent.
            removed_layer_indices_len = 0;
        }

        // Sync the multi-selection list with the primary index each frame so it tracks operations
        // (delete/duplicate/merge) that only update `selected_layer_index`. The set must always
        // contain the primary — the editor cannot have zero selected layers.
        ensureLayerSelection(file);

        const box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .background = false,
            .corner_radius = dvui.Rect.all(1000),
            .margin = dvui.Rect.rect(4, 0, 4, 4),
        });
        defer box.deinit();

        for (file.layers.items(.id), 0..) |layer_id, layer_index| {
            const in_multi = layerIndexInMulti(file, layer_index);
            const is_primary_row = file.selected_layer_index == layer_index;
            const selected = if (edit_layer_id) |id| id == layer_id else (is_primary_row or in_multi);
            const visible = file.layers.items(.visible)[layer_index];
            const font = if (visible) dvui.Font.theme(.body) else dvui.Font.theme(.body).withStyle(.italic);

            var color = dvui.themeGet().color(.control, .fill_hover);
            if (fizzy.editor.colors.file_tree_palette) |*palette| {
                color = palette.getDVUIColor(@intCast(layer_id));
            }

            // `process_events` must be false: Tree Branch's header `ButtonWidget.processEvents` runs
            // `dvui.clicked`, which captures on press + dragPreStart for the full button rect (~row height),
            // stealing presses before label/sink (dvui `clickedEx` press handler).
            var branch = tree.branch(@src(), .{
                .expanded = false,
                .process_events = false,
                .can_accept_children = false,
                .animation_duration = 250_000,
                .animation_easing = dvui.easing.outBack,
            }, .{
                .id_extra = @intCast(layer_id),
                .expand = .horizontal,
                .corner_radius = dvui.Rect.all(1000),
                .background = false,
                .margin = .all(0),
                .padding = dvui.Rect.all(1),
            });
            defer branch.deinit();

            if (branch.removed()) {
                if (removed_layer_indices_len < removed_layer_indices_buf.len) {
                    removed_layer_indices_buf[removed_layer_indices_len] = layer_index;
                    removed_layer_indices_len += 1;
                }
            } else if (branch.insertBefore()) {
                insert_before_index = layer_index;
            }

            const row_r = branch.data().borderRectScale().r;
            const mp = dvui.currentWindow().mouse_pt;
            const row_hovered = row_r.contains(mp) and layerPointerInScrollViewport(mp, tools.layers_scroll_viewport_rect);

            if (tree.reorderDragActive()) {
                if (tree.id_branch) |idb| {
                    if (idb == branch.data().id.asUsize()) {
                        file.peek_layer_index = layer_index;
                    }
                }
            } else if (row_hovered) {
                file.peek_layer_index = layer_index;
            }

            var min_layer_index: usize = 0;
            if (file.editor.isolate_layer) {
                if (file.peek_layer_index) |peek_layer_index| {
                    min_layer_index = peek_layer_index;
                } else if (!fizzy.editor.explorer.tools.layersHovered()) {
                    min_layer_index = file.selected_layer_index;
                }
            }

            const below_mouse = dvui.currentWindow().mouse_pt.y > branch.data().contentRectScale().r.y + branch.data().contentRectScale().r.h;

            var alpha: f32 = dvui.alpha(1.0);
            if (file.editor.isolate_layer and (layer_index < min_layer_index or (below_mouse and tools.layersHovered()))) {
                alpha = dvui.alpha(0.5);
            }
            defer dvui.alphaSet(alpha);

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
                .color_fill = if ((selected or row_highlight) and !branch.floating())
                    ctrl_hover
                else
                    .transparent,
                .color_fill_hover = .transparent,
                .margin = dvui.Rect{},
                .padding = dvui.Rect.all(1),
                .corner_radius = dvui.Rect.all(8),
                .box_shadow = null,
            });
            defer hbox.deinit();

            // _ = dvui.icon(
            //     @src(),
            //     "LayerIcon",
            //     icons.tvg.heroicons.solid.@"square-3-stack-3d",
            //     .{
            //         .stroke_color = if (!(selected or row_hovered)) dvui.themeGet().color(.control, .fill) else if (selected) dvui.themeGet().color(.window, .text) else dvui.themeGet().color(.window, .fill),
            //         .fill_color = if (!(selected or row_hovered)) dvui.themeGet().color(.control, .fill) else if (selected) dvui.themeGet().color(.window, .text) else dvui.themeGet().color(.window, .fill),
            //     },
            //     .{ .expand = .none, .gravity_y = 0.5, .margin = .{ .x = 4, .w = 4 } },
            // );

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

            if (edit_layer_id != layer_id) {
                // Always use the same label wrapper so sibling widget ids (drag_sink, button_box) stay stable
                // when selection changes — otherwise the extra box only on the selected row causes a layout flash.
                var name_label_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .none,
                    .background = false,
                    .gravity_y = 0.5,
                    .margin = dvui.Rect.rect(2, 0, 2, 0),
                    .padding = dvui.Rect.all(0),
                });
                defer name_label_box.deinit();

                const name_text = file.layers.items(.name)[layer_index];
                const name_color: dvui.Color = if (!selected)
                    dvui.themeGet().color(.control, .text)
                else if (is_primary_row)
                    dvui.themeGet().color(.window, .text)
                else
                    dvui.themeGet().color(.control, .text);

                if (selected) {
                    if (dvui.labelClick(@src(), "{s}", .{name_text}, .{}, .{
                        .expand = .none,
                        .gravity_y = 0.5,
                        .margin = dvui.Rect{},
                        .font = font,
                        .padding = dvui.Rect.all(0),
                        .color_text = name_color,
                    })) {
                        const lr = name_label_box.data().borderRectScale().r;
                        if (pointerReleaseInRectWithoutSelectionModifier(lr)) {
                            edit_layer_id = layer_id;
                        }
                    }
                } else {
                    dvui.labelNoFmt(@src(), name_text, .{}, .{
                        .expand = .none,
                        .gravity_y = 0.5,
                        .margin = dvui.Rect{},
                        .font = font,
                        .padding = dvui.Rect.all(0),
                        .color_text = name_color,
                    });
                }
            } else {
                var te = dvui.textEntry(@src(), .{}, .{
                    .expand = .horizontal,
                    .background = false,
                    .padding = dvui.Rect.all(0),
                    .margin = dvui.Rect.all(0),
                    .font = font,
                    .gravity_y = 0.5,
                });
                defer te.deinit();

                if (dvui.firstFrame(te.data().id)) {
                    te.textSet(file.layers.items(.name)[layer_index], true);
                    dvui.focusWidget(te.data().id, null, null);
                }

                layer_rename_hit_te_id = te.data().id;
                layer_rename_hit_rect = te.data().borderRectScale().r;

                const should_commit_rename = te.enter_pressed or dvui.focusedWidgetId() != te.data().id;
                if (should_commit_rename) {
                    if (!std.mem.eql(u8, file.layers.items(.name)[layer_index], te.getText()) and te.getText().len > 0) {
                        file.history.append(.{
                            .layer_name = .{
                                .index = layer_index,
                                .name = try fizzy.app.allocator.dupe(u8, file.layers.items(.name)[layer_index]),
                            },
                        }) catch {
                            dvui.log.err("Failed to append history", .{});
                        };
                        fizzy.app.allocator.free(file.layers.items(.name)[layer_index]);
                        file.layers.items(.name)[layer_index] = try fizzy.app.allocator.dupe(u8, te.getText());
                    }
                    if (te.enter_pressed) {
                        file.selected_layer_index = layer_index;
                    }
                    dvui.captureMouse(null, 0);
                    dvui.focusWidget(null, null, null);
                    edit_layer_id = null;
                    dvui.refresh(null, @src(), tree.data().id);
                }
            }

            if (edit_layer_id != layer_id) {
                var drag_sink = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .both,
                    .background = false,
                    .min_size_content = .{ .w = 0, .h = 0 },
                    .gravity_y = 0.5,
                });
                defer drag_sink.deinit();

                var button_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .none,
                    .background = false,
                    .gravity_x = 1.0,
                    .gravity_y = 0.5,
                });
                defer button_box.deinit();

                if (dvui.buttonIcon(
                    @src(),
                    "collapse_button",
                    if (file.layers.items(.collapse)[layer_index]) icons.tvg.lucide.@"arrow-down-to-line" else icons.tvg.lucide.package,
                    .{ .draw_focus = false },
                    .{},
                    .{
                        .expand = .ratio,
                        .min_size_content = .{ .w = 1.0, .h = 11.0 },
                        .id_extra = layer_index,
                        .corner_radius = dvui.Rect.all(1000),
                        .margin = dvui.Rect.all(1),
                    },
                )) {
                    file.layers.items(.collapse)[layer_index] = !file.layers.items(.collapse)[layer_index];
                }

                if (dvui.buttonIcon(
                    @src(),
                    "hide_button",
                    if (file.layers.items(.visible)[layer_index]) icons.tvg.lucide.eye else icons.tvg.lucide.@"eye-closed",
                    .{ .draw_focus = false },
                    .{},
                    .{
                        .expand = .ratio,
                        .min_size_content = .{ .w = 1.0, .h = 11.0 },
                        .id_extra = layer_index,
                        .corner_radius = dvui.Rect.all(1000),
                        .margin = dvui.Rect.all(1),
                    },
                )) {
                    file.layers.items(.visible)[layer_index] = !file.layers.items(.visible)[layer_index];
                    file.editor.layer_composite_dirty = true;
                    file.editor.split_composite_dirty = true;
                }

                if (layer_hits_len < layer_hits_buf.len) {
                    layer_hits_buf[layer_hits_len] = .{
                        .row_r = branch.data().borderRectScale().r,
                        .buttons_r = button_box.data().borderRectScale().r,
                        .branch_usize = branch.data().id.asUsize(),
                        .layer_index = layer_index,
                        .hbox_tl = hbox.data().rectScale().r.topLeft(),
                    };
                    layer_hits_len += 1;
                }

                if (row_hovered) {
                    if (!button_box.data().borderRectScale().r.contains(mp)) {
                        dvui.cursorSet(.hand);
                    }
                }
            } else {
                var button_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .none,
                    .background = false,
                    .gravity_x = 1.0,
                });
                defer button_box.deinit();

                if (dvui.buttonIcon(
                    @src(),
                    "collapse_button",
                    if (file.layers.items(.collapse)[layer_index]) icons.tvg.lucide.@"arrow-down-to-line" else icons.tvg.lucide.package,
                    .{ .draw_focus = false },
                    .{},
                    .{
                        .expand = .ratio,
                        .min_size_content = .{ .w = 1.0, .h = 11.0 },
                        .id_extra = layer_index,
                        .corner_radius = dvui.Rect.all(1000),
                        .margin = dvui.Rect.all(1),
                    },
                )) {
                    file.layers.items(.collapse)[layer_index] = !file.layers.items(.collapse)[layer_index];
                }

                if (dvui.buttonIcon(
                    @src(),
                    "hide_button",
                    if (file.layers.items(.visible)[layer_index]) icons.tvg.lucide.eye else icons.tvg.lucide.@"eye-closed",
                    .{ .draw_focus = false },
                    .{},
                    .{
                        .expand = .ratio,
                        .min_size_content = .{ .w = 1.0, .h = 11.0 },
                        .id_extra = layer_index,
                        .corner_radius = dvui.Rect.all(1000),
                        .margin = dvui.Rect.all(1),
                    },
                )) {
                    file.layers.items(.visible)[layer_index] = !file.layers.items(.visible)[layer_index];
                    file.editor.layer_composite_dirty = true;
                    file.editor.split_composite_dirty = true;
                }
            }
        }

        processLayerTreePointerEvents(tree, file, layer_hits_buf[0..layer_hits_len], tools.layers_scroll_viewport_rect);

        var layer_tail_branch_id: ?usize = null;
        if (tree.drag_point != null) {
            const tail = tree.branch(@src(), .{
                .expanded = false,
                .process_events = false,
                .can_accept_children = false,
            }, .{
                .id_extra = 0x7fff_fffe,
                .expand = .horizontal,
                .min_size_content = .{ .w = 0, .h = 14 },
                .color_fill = .transparent,
                .color_fill_hover = .transparent,
                .color_fill_press = .transparent,
            });
            defer tail.deinit();
            layer_tail_branch_id = tail.data().id.asUsize();
            if (tail.insertBefore()) {
                insert_before_index = file.layers.len;
            }
        }

        if (tree.reorderDragActive()) {
            if (tree.id_branch) |idb| {
                var from: ?usize = null;
                for (layer_hits_buf[0..layer_hits_len]) |h| {
                    if (h.branch_usize == idb) {
                        from = h.layer_index;
                        break;
                    }
                }
                if (from) |fr| {
                    var insert_before: ?usize = null;
                    if (tree.drop_target_branch_id) |dtb| {
                        if (dtb == idb) {
                            insert_before = fr;
                        } else if (layer_tail_branch_id) |tid| {
                            if (dtb == tid) {
                                insert_before = file.layers.len;
                            }
                        }
                        if (insert_before == null) {
                            for (layer_hits_buf[0..layer_hits_len]) |h| {
                                if (h.branch_usize == dtb) {
                                    insert_before = h.layer_index;
                                    break;
                                }
                            }
                        }
                    }
                    if (insert_before) |ins| {
                        if (fr != ins) {
                            file.editor.layer_drag_preview_removed = fr;
                            file.editor.layer_drag_preview_insert_before = ins;
                            file.editor.layer_composite_dirty = true;
                            file.editor.split_composite_dirty = true;
                        }
                    }
                }
            }
        }

        // Only draw shadow if the scroll bar has been scrolled some
        if (vertical_scroll > 0.0)
            fizzy.dvui.drawEdgeShadow(scroll_area.data().contentRectScale(), .top, .{});

        if (file.editor.layers_scroll_info.virtual_size.h > file.editor.layers_scroll_info.viewport.h + 1 and vertical_scroll < file.editor.layers_scroll_info.scrollMax(.vertical))
            fizzy.dvui.drawEdgeShadow(scroll_area.data().contentRectScale(), .bottom, .{});
    }

    if (fizzy.dvui.hovered(vbox.data())) {
        const mp = dvui.currentWindow().mouse_pt;
        if (tools.layers_scroll_viewport_rect) |vr| {
            if (!vr.contains(mp)) return null;
        }
        return vbox.data().contentRectScale().r;
    }

    return null;
}

pub fn drawColors() !void {
    dvui.labelNoFmt(@src(), "COLORS", .{}, .{ .font = dvui.Font.theme(.heading) });

    var hbox = dvui.box(@src(), .{ .dir = .horizontal, .equal_space = true }, .{
        .expand = .horizontal,
        .background = false,
        .min_size_content = .{ .w = 64.0, .h = 64.0 },
        .margin = dvui.Rect.all(4),
    });
    defer hbox.deinit();

    const primary: dvui.Color = .{ .r = fizzy.editor.colors.primary[0], .g = fizzy.editor.colors.primary[1], .b = fizzy.editor.colors.primary[2], .a = fizzy.editor.colors.primary[3] };
    const secondary: dvui.Color = .{ .r = fizzy.editor.colors.secondary[0], .g = fizzy.editor.colors.secondary[1], .b = fizzy.editor.colors.secondary[2], .a = fizzy.editor.colors.secondary[3] };

    const button_opts: dvui.Options = .{
        .expand = .both,
        .background = true,
        .corner_radius = dvui.Rect.all(8.0),
        .color_fill = primary,
        .color_fill_hover = primary,
        .color_fill_press = primary,
        .margin = dvui.Rect.all(4),
        .padding = dvui.Rect.all(0),
        .box_shadow = .{
            .color = .black,
            .offset = .{ .x = -2.0, .y = 2.0 },
            .fade = 6.0,
            .alpha = 0.15,
            .corner_radius = dvui.Rect.all(8.0),
        },
    };

    const secondary_overrider: dvui.Options = .{
        .color_fill = secondary,
        .color_fill_hover = secondary,
        .color_fill_press = secondary,
    };

    var clicked: bool = false;
    {
        var primary_button: dvui.ButtonWidget = undefined;
        primary_button.init(@src(), .{}, button_opts);
        defer primary_button.deinit();

        try drawColorPicker(primary_button.data().rectScale().r, &fizzy.editor.colors.primary, 0);

        primary_button.processEvents();
        primary_button.drawBackground();

        if (primary_button.clicked()) clicked = true;
    }

    {
        var secondary_button: dvui.ButtonWidget = undefined;
        secondary_button.init(@src(), .{}, button_opts.override(secondary_overrider));
        defer secondary_button.deinit();

        try drawColorPicker(secondary_button.data().rectScale().r, &fizzy.editor.colors.secondary, 1);

        secondary_button.processEvents();
        secondary_button.drawBackground();

        if (secondary_button.clicked()) clicked = true;
    }

    if (clicked) {
        std.mem.swap([4]u8, &fizzy.editor.colors.primary, &fizzy.editor.colors.secondary);
    }
}

fn drawColorPicker(rect: dvui.Rect.Physical, backing_color: *[4]u8, id_extra: usize) !void {
    var context = dvui.context(@src(), .{ .rect = rect }, .{ .id_extra = id_extra });
    defer context.deinit();

    if (context.activePoint()) |point| {
        var fw2 = dvui.floatingMenu(@src(), .{ .from = dvui.Rect.Natural.fromPoint(point) }, .{ .box_shadow = .{
            .color = .black,
            .offset = .{ .x = 0, .y = 0 },
            .shrink = 0,
            .fade = 10,
            .alpha = 0.15,
        } });
        defer fw2.deinit();

        var color: dvui.Color.HSV = .fromColor(.{
            .r = backing_color.*[0],
            .g = backing_color.*[1],
            .b = backing_color.*[2],
            .a = backing_color.*[3],
        });

        if (dvui.colorPicker(@src(), .{ .alpha = true, .hsv = &color }, .{
            .expand = .horizontal,
            .background = false,
            .corner_radius = dvui.Rect.all(1000),
            // Default saturation box is 100×100 and the sliders / hue strip size off of
            // that. Bumping the outer min_size_content to ~2× makes everything inside
            // (the value/saturation pad, the hue strip, the RGB+A sliders, the hex
            // entry) scale up via their `.expand = .ratio` / `.expand = .horizontal`,
            // giving a touch-friendly hit area without restyling each piece.
            .min_size_content = .{ .w = 220, .h = 220 },
        })) {
            const c = color.toColor();
            backing_color.* = .{
                c.r,
                c.g,
                c.b,
                c.a,
            };
        }
    }
}

pub fn drawPaletteControls() !void {
    var box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = false,
    });
    defer box.deinit();

    dvui.labelNoFmt(@src(), "PALETTES", .{}, .{ .font = dvui.Font.theme(.heading) });

    if (dvui.buttonIcon(@src(), "PinPalettes", dvui.entypo.pin, .{ .draw_focus = false }, .{}, .{
        .expand = .none,
        .gravity_y = 0.5,
        .gravity_x = 1.0,
        .corner_radius = dvui.Rect.all(1000),
        .box_shadow = .{
            .color = .black,
            .offset = .{ .x = -2.0, .y = 2.0 },
            .fade = 6.0,
            .alpha = 0.15,
            .corner_radius = dvui.Rect.all(1000),
        },
        .rotation = std.math.pi * 0.25,
        .style = if (fizzy.editor.explorer.pinned_palettes) .highlight else .control,
    })) {
        fizzy.editor.explorer.pinned_palettes = !fizzy.editor.explorer.pinned_palettes;
    }
}

pub fn drawPalettes() !void {
    var scroll_area = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .background = false,
    });
    defer scroll_area.deinit();

    // Palette search dropdown
    {
        const oldt = dvui.themeGet();
        var t = oldt;
        t.control.fill = t.window.fill;
        dvui.themeSet(t);
        defer dvui.themeSet(oldt);

        var dropdown: dvui.DropdownWidget = undefined;
        dropdown.init(@src(), .{ .label = "Palette" }, .{
            .expand = .horizontal,
            .corner_radius = dvui.Rect.all(1000),
        });

        defer dropdown.deinit();

        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .vertical,
            .gravity_x = 1.0,
        });

        if (fizzy.editor.colors.palette) |*palette| {
            dvui.label(@src(), "{s}", .{palette.name}, .{ .margin = .all(0), .padding = .all(0) });
        } else {
            dvui.label(@src(), "Palette Search", .{}, .{ .margin = .all(0), .padding = .all(0) });
        }

        dvui.icon(
            @src(),
            "dropdown_triangle",
            dvui.entypo.triangle_down,
            .{},
            .{ .gravity_y = 0.5 },
        );

        hbox.deinit();

        if (dropdown.dropped()) {
            dvui.labelNoFmt(@src(), "Built-in", .{}, .{
                .margin = .all(0),
                .gravity_x = 0.5,
            });
            _ = dvui.separator(@src(), .{ .expand = .horizontal });

            var it = (try assets.root.dir("palettes")).iterate();
            while (it.next()) |entry| {
                switch (entry.data) {
                    .file => |data| {
                        const ext = std.fs.path.extension(entry.name);
                        if (std.mem.eql(u8, ext, ".hex")) {
                            if (dropdown.addChoiceLabel(entry.name)) {
                                fizzy.editor.colors.palette = fizzy.Internal.Palette.loadFromBytes(fizzy.app.allocator, entry.name, data) catch |err| {
                                    dvui.log.err("Failed to load palette: {s}", .{@errorName(err)});
                                    return error.FailedToLoadPalette;
                                };
                            }
                        }
                    },
                    .dir => {},
                }
            }

            _ = dvui.separator(@src(), .{ .expand = .horizontal });
            // User palette folder scan uses Io.Dir.iterate (NAME_MAX) — unavailable on wasm.
            if (comptime builtin.target.cpu.arch != .wasm32) {
                searchPalettes(&dropdown) catch {
                    dvui.log.err("Failed to search palettes", .{});
                };
            }
        }

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 10, .h = 10 } });
    }

    {
        if (fizzy.editor.colors.palette) |*palette| {
            var flex_box = dvui.flexbox(@src(), .{ .justify_content = .start }, .{
                .expand = .horizontal,
                .max_size_content = .{
                    .w = fizzy.editor.explorer.rect.w - 20 * dvui.currentWindow().natural_scale,
                    .h = fizzy.editor.explorer.rect.h - 20 * dvui.currentWindow().natural_scale,
                },
            });

            var triangles = dvui.Triangles.Builder.init(dvui.currentWindow().arena(), palette.colors.len * 300, palette.colors.len * 300 * 30) catch return;

            for (palette.colors, 0..) |color, i| {
                var anim = dvui.animate(
                    @src(),
                    .{
                        .duration = 250_000 + 10_000 * @as(i32, @intCast(i)),
                        .kind = .horizontal,
                        .easing = dvui.easing.outBack,
                    },
                    .{
                        .expand = .none,
                        .id_extra = dvui.Id.extendId(flex_box.data().id, @src(), i).update(palette.name).asUsize(),
                    },
                );
                defer anim.deinit();

                var box_widget = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .none,
                    .min_size_content = .{ .w = 18.0, .h = 18.0 },
                    .id_extra = i,
                    .background = false,
                    .margin = dvui.Rect.all(1),
                });

                const button_center = box_widget.data().rectScale().r.center();
                const dist = dvui.currentWindow().mouse_pt.diff(button_center).length();

                // Calculate scale based on mouse distance (closer = larger)
                const max_distance = 24.0 * dvui.currentWindow().natural_scale; // Maximum distance for scaling effect
                const scale_factor = if (dist < max_distance)
                    1.0 + (1.0 - (dist / max_distance)) * 0.5 // Scale up to 1.5x when very close
                else
                    1.0;

                var path = dvui.Path.Builder.init(dvui.currentWindow().arena());
                defer path.deinit();

                var rect = box_widget.data().rect.scale(scale_factor, dvui.Rect);
                rect.x = box_widget.data().rect.center().x - rect.w / 2.0;
                rect.y = box_widget.data().rect.center().y - rect.h / 2.0;

                box_widget.deinit();

                var button_widget: dvui.ButtonWidget = undefined;
                button_widget.init(@src(), .{ .touch_drag = false }, .{
                    .expand = .none,
                    .rect = rect,
                    .id_extra = i,
                });

                defer button_widget.deinit();

                path.addRect(button_widget.data().rectScale().r, .all(1000));

                const base_index: u16 = @intCast(triangles.vertexes.items.len);

                const b = path.build().fillConvexTriangles(
                    dvui.currentWindow().arena(),
                    .{ .color = .{
                        .r = color[0],
                        .g = color[1],
                        .b = color[2],
                        .a = color[3],
                    }, .fade = 1.0 },
                ) catch return;
                for (b.vertexes) |vertex| {
                    triangles.appendVertex(vertex);
                }
                for (b.indices) |*index| {
                    index.* += @as(u16, @intCast(base_index));
                }
                triangles.appendTriangles(b.indices);

                if (dvui.clickedEx(button_widget.data(), .{ .buttons = .any, .touch_drag = true })) |evt| {
                    switch (evt) {
                        .mouse => |mouse_evt| {
                            if (mouse_evt.button.pointer() or mouse_evt.button.touch()) {
                                @memcpy(&fizzy.editor.colors.primary, &color);
                            } else if (mouse_evt.button == .right) {
                                @memcpy(&fizzy.editor.colors.secondary, &color);
                            }
                        },
                        else => {},
                    }
                }
            }

            flex_box.deinit();

            const clip = dvui.clip(dvui.currentWindow().rect_pixels);
            defer dvui.clipSet(clip);

            dvui.renderTriangles(triangles.build(), null) catch {
                dvui.log.err("Failed to render triangles", .{});
            };
        }
    }
}
fn searchPalettes(dropdown: *dvui.DropdownWidget) !void {
    const io = dvui.io;
    var dir_opt = std.Io.Dir.cwd().openDir(io, fizzy.editor.palette_folder, .{ .access_sub_paths = false, .iterate = true }) catch null;
    if (dir_opt) |*dir| {
        defer dir.close(io);
        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            if (entry.kind == .file) {
                const ext = std.fs.path.extension(entry.name);
                if (std.mem.eql(u8, ext, ".hex")) {
                    const label = try std.fmt.allocPrint(dvui.currentWindow().arena(), "{s}", .{entry.name});
                    if (dropdown.addChoiceLabel(label)) {
                        const abs_path = try std.fs.path.join(dvui.currentWindow().arena(), &.{ fizzy.editor.palette_folder, entry.name });

                        if (fizzy.editor.colors.palette) |*palette|
                            palette.deinit();

                        fizzy.editor.colors.palette = fizzy.Internal.Palette.loadFromFile(fizzy.app.allocator, abs_path) catch |err| {
                            dvui.log.err("Failed to load palette: {s}", .{@errorName(err)});
                            return error.FailedToLoadPalette;
                        };
                    }
                }
            }
        }
    }
}

/// Geometry for one layer row, collected while drawing; used for a single chronological pointer pass.
const LayerRowHit = struct {
    row_r: dvui.Rect.Physical,
    buttons_r: dvui.Rect.Physical,
    branch_usize: usize,
    layer_index: usize,
    hbox_tl: dvui.Point.Physical,
};

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

fn layerGestureMatches(file: *const fizzy.Internal.File) bool {
    return layer_row_gesture != null and layer_row_gesture.?.file_id == file.id;
}

/// True if `layer_index` is present in the multi-selection set (the primary index is always implicitly selected).
fn layerIndexInMulti(file: *const fizzy.Internal.File, layer_index: usize) bool {
    for (file.editor.selected_layer_indices.items) |i| {
        if (i == layer_index) return true;
    }
    return false;
}

/// Sync the multi-selection list with `file.selected_layer_index` and the current layer count.
/// The primary must always be present; stale / out-of-range entries from deletions are dropped.
fn ensureLayerSelection(file: *fizzy.Internal.File) void {
    var sel = &file.editor.selected_layer_indices;

    // Drop out-of-range entries.
    var write: usize = 0;
    for (sel.items) |i| {
        if (i < file.layers.len) {
            sel.items[write] = i;
            write += 1;
        }
    }
    sel.items.len = write;

    // Clamp primary to valid range (should already be, but be defensive).
    if (file.selected_layer_index >= file.layers.len) {
        file.selected_layer_index = if (file.layers.len == 0) 0 else file.layers.len - 1;
    }

    // Guarantee the primary index is present.
    var has_primary = false;
    for (sel.items) |i| {
        if (i == file.selected_layer_index) {
            has_primary = true;
            break;
        }
    }
    if (!has_primary and file.layers.len > 0) {
        sel.append(fizzy.app.allocator, file.selected_layer_index) catch return;
        std.sort.pdq(usize, sel.items, {}, std.sort.asc(usize));
    }
}

/// Apply a modifier-aware click to the layer multi-selection. Returns the new primary index and
/// whether the narrow-on-release deferral should be armed (true when a plain click lands on a row
/// that is already part of a multi-selection: selection stays until the user releases without
/// dragging, at which point we narrow to just that row).
const LayerClickApplied = struct {
    primary: usize,
    narrow_on_release: bool,
};

fn applyLayerClick(
    file: *fizzy.Internal.File,
    clicked: usize,
    mode: fizzy.dvui.TreeSelection.ClickMode,
) LayerClickApplied {
    const count_before = file.editor.selected_layer_indices.items.len;

    // Plain click on a row that is already part of the current multi-selection preserves the set
    // so the user can drag the whole group. We narrow later on release if no drag happened.
    if (mode == .replace and layerIndexInMulti(file, clicked) and count_before > 1) {
        return .{ .primary = clicked, .narrow_on_release = true };
    }

    var tmp: std.ArrayList(usize) = .empty;
    defer tmp.deinit(fizzy.app.allocator);

    const res = fizzy.dvui.TreeSelection.applyClickUsize(
        fizzy.app.allocator,
        file.editor.selected_layer_indices.items,
        file.selected_layer_index,
        file.editor.layer_selection_anchor,
        clicked,
        mode,
        true, // require_primary: layers always has ≥ 1 selected
        &tmp,
    ) catch return .{ .primary = file.selected_layer_index, .narrow_on_release = false };

    file.editor.selected_layer_indices.clearRetainingCapacity();
    file.editor.selected_layer_indices.appendSlice(fizzy.app.allocator, tmp.items) catch {};

    const new_primary = res.primary orelse clicked;
    file.selected_layer_index = new_primary;
    file.editor.layer_selection_anchor = res.anchor;

    return .{ .primary = new_primary, .narrow_on_release = false };
}

/// Narrow the multi-selection to just `clicked` — used when the user performed a plain press on an
/// already-multi-selected row and released without dragging. Mirrors Finder-style behavior.
fn narrowLayerSelectionTo(file: *fizzy.Internal.File, clicked: usize) void {
    file.editor.selected_layer_indices.clearRetainingCapacity();
    file.editor.selected_layer_indices.append(fizzy.app.allocator, clicked) catch {};
    file.selected_layer_index = clicked;
    file.editor.layer_selection_anchor = clicked;
}

/// Build a list of branch widget ids (one per selected layer) to pass into `tree.dragStartMulti`.
/// Uses the per-row `LayerRowHit` geometry captured during drawing. Only layers currently visible
/// in the row-hits buffer are included (out-of-viewport selections are allowed because hits are
/// populated for every drawn row, not just hovered ones).
fn buildLayerMultiDragIds(
    file: *const fizzy.Internal.File,
    hits: []const LayerRowHit,
    out: []usize,
) usize {
    var n: usize = 0;
    for (file.editor.selected_layer_indices.items) |layer_index| {
        for (hits) |h| {
            if (h.layer_index == layer_index) {
                if (n < out.len) {
                    out[n] = h.branch_usize;
                    n += 1;
                }
                break;
            }
        }
    }
    return n;
}

/// Clear in-flight gesture only (no `dragEnd`). Used before arming a new row press.
fn layerTreeClearGestureKeysOnly(_: *const fizzy.Internal.File) void {
    layer_row_gesture = null;
}

/// Clear gesture and global `Dragging` (stale prestart/drag from other widgets).
fn layerTreeResetRowPointerGesture(_: *const fizzy.Internal.File) void {
    dvui.dragEnd();
    layer_row_gesture = null;
}

/// Rename `textEntry` is drawn above the row; skip layer-tree handling when it already consumed the event
/// or the pointer maps to its rect (runs after `textEntry()` so rects/targets are valid this frame).
fn layerPointerRenameConsumes(e: *const dvui.Event, me: dvui.Event.Mouse) bool {
    if (e.handled) return true;
    if (layer_rename_hit_te_id) |rid| {
        if (e.target_widgetId) |tid| {
            if (tid == rid) return true;
        }
    }
    if (layer_rename_hit_rect) |r| {
        if (r.contains(me.p)) return true;
    }
    return false;
}

/// Layer row rects can extend outside the scroll viewport when content is scrolled; only treat the
/// pointer as interacting with the list when it lies inside the scroll container's visible clip.
fn layerPointerInScrollViewport(p: dvui.Point.Physical, viewport_r: ?dvui.Rect.Physical) bool {
    if (viewport_r) |r| return r.contains(p);
    return true;
}

fn layerTreePointerInTreeSurface(tree: *fizzy.dvui.TreeWidget, p: dvui.Point.Physical, floating_win: dvui.Id) bool {
    if (floating_win != dvui.subwindowCurrentId()) return false;
    const tr = tree.data().borderRectScale().r;
    if (!tr.contains(p)) return false;
    if (!dvui.clipGet().contains(p)) return false;
    return true;
}

fn layerTreePointerInTreeBorder(tree: *fizzy.dvui.TreeWidget, p: dvui.Point.Physical, floating_win: dvui.Id) bool {
    if (floating_win != dvui.subwindowCurrentId()) return false;
    return tree.data().borderRectScale().r.contains(p);
}

/// While another widget holds capture, `target_widgetId` may not be the tree. Allow starting a reorder drag
/// when the pointer is over the tree border (scroll clip can disagree with visible row geometry).
fn layerTreeMotionAllowsLayerReorder(tree: *fizzy.dvui.TreeWidget, e: *dvui.Event) bool {
    if (e.target_widgetId) |fwid| {
        if (fwid == tree.data().id) return true;
    }
    const cw = dvui.currentWindow();
    if (cw.dragging.state == .dragging and cw.dragging.name != null) return false;
    const me = e.evt.mouse;
    const in_surface = layerTreePointerInTreeSurface(tree, me.p, me.floating_win);
    const in_border = layerTreePointerInTreeBorder(tree, me.p, me.floating_win);
    return in_surface or in_border;
}

/// One pass over `events()` in frame order: press → motion → release.
/// Runs after layer rows (and rename `textEntry`) are built so geometry and `e.handled` reflect z-order.
fn processLayerTreePointerEvents(tree: *fizzy.dvui.TreeWidget, file: *fizzy.Internal.File, hits: []const LayerRowHit, layers_viewport_r: ?dvui.Rect.Physical) void {
    if (!tree.init_options.enable_reordering) return;

    for (dvui.events()) |*e| {
        switch (e.evt) {
            .mouse => |me| {
                if (me.action == .press and me.button.pointer()) {
                    if (layerPointerRenameConsumes(e, me)) continue;
                    if (!layerPointerInScrollViewport(me.p, layers_viewport_r)) continue;

                    var row_hit: ?LayerRowHit = null;
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
                        layerTreeClearGestureKeysOnly(file);
                        dvui.dragPreStart(me.p, .{ .offset = h.hbox_tl.diff(me.p) });

                        const mode = fizzy.dvui.TreeSelection.clickModeFromMod(me.mod);
                        const applied = applyLayerClick(file, h.layer_index, mode);

                        layer_row_gesture = .{
                            .file_id = file.id,
                            .press_idx = h.layer_index,
                            .press_p = me.p,
                            .drag_branch = h.branch_usize,
                            .moved = false,
                            .reorder_drag = false,
                            .narrow_on_release = applied.narrow_on_release,
                        };
                    } else {
                        layerTreeResetRowPointerGesture(file);
                    }
                    continue;
                }

                if (me.action == .motion) {
                    if (layerPointerRenameConsumes(e, me)) continue;

                    if (layer_row_gesture) |*g| {
                        if (g.file_id == file.id) {
                            const dx = me.p.x - g.press_p.x;
                            const dy = me.p.y - g.press_p.y;
                            if (dx * dx + dy * dy > 16.0) {
                                g.moved = true;
                            }
                        }
                    }

                    // After `tree.dragStart`, `drag_branch` is cleared — do not gate `matchEvent` on it.
                    if (tree.reorderDragActive()) {
                        _ = tree.matchEvent(e);
                        continue;
                    }

                    const branch_usize = if (layerGestureMatches(file)) layer_row_gesture.?.drag_branch else null;
                    if (branch_usize == null) continue;
                    _ = tree.matchEvent(e);
                    if (!layerTreeMotionAllowsLayerReorder(tree, e)) continue;

                    const prev_th = dvui.Dragging.threshold;
                    dvui.Dragging.threshold = @max(prev_th, 8.0);
                    defer dvui.Dragging.threshold = prev_th;
                    if (dvui.dragging(me.p, null)) |_| {
                        // Row size in natural units; `.{}` → `TreeWidget.dragStart` uses `branch_size`.
                        var row_size: dvui.Size = .{};
                        for (hits) |h| {
                            if (h.branch_usize == branch_usize.?) {
                                const rn = h.row_r.toNatural();
                                row_size = .{ .w = rn.w, .h = rn.h };
                                break;
                            }
                        }

                        var multi_buf: [128]usize = undefined;
                        const multi_len = buildLayerMultiDragIds(file, hits, multi_buf[0..]);
                        if (multi_len > 1) {
                            tree.dragStartMulti(branch_usize.?, multi_buf[0..multi_len], me.p, row_size);
                        } else {
                            tree.dragStart(branch_usize.?, me.p, row_size);
                        }

                        if (layer_row_gesture) |*g| {
                            if (g.file_id == file.id) {
                                g.reorder_drag = true;
                                g.drag_branch = null;
                                g.narrow_on_release = false;
                            }
                        }
                    }
                } else if (me.action == .release and me.button.pointer()) {
                    if (layerPointerRenameConsumes(e, me)) continue;

                    const release_in_vp = layerPointerInScrollViewport(me.p, layers_viewport_r);

                    var release_layer: ?usize = null;
                    var rj = hits.len;
                    while (rj > 0) {
                        rj -= 1;
                        const h = hits[rj];
                        if (release_in_vp and h.row_r.contains(me.p) and !h.buttons_r.contains(me.p)) {
                            release_layer = h.layer_index;
                            break;
                        }
                    }

                    const idx_opt: ?usize = if (layerGestureMatches(file)) layer_row_gesture.?.press_idx else null;
                    const did_reorder = if (layerGestureMatches(file)) layer_row_gesture.?.reorder_drag else false;
                    const narrow = if (layerGestureMatches(file)) layer_row_gesture.?.narrow_on_release else false;

                    var selection_changed = false;
                    if (!did_reorder and !tree.drag_ending and release_in_vp and narrow) {
                        if (idx_opt) |pi| {
                            narrowLayerSelectionTo(file, pi);
                            selection_changed = true;
                        }
                    }

                    if (idx_opt != null) {
                        layerTreeResetRowPointerGesture(file);
                        if (!did_reorder and !dvui.captured(tree.data().id)) {
                            dvui.captureMouse(null, e.num);
                        }
                    }

                    if (selection_changed) {
                        dvui.refresh(null, @src(), tree.data().id);
                    }
                }
            },
            else => {},
        }
    }
}
