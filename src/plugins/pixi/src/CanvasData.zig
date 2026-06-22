//! The pixel-art plugin's per-workspace-pane data. Each plugin that renders documents into a
//! workbench pane will typically want a struct like this to hold its per-pane state; pixel art
//! uses it for the canvas UI that wraps a document inside the workbench-provided content region:
//! the column/row rulers, the floating Edit pill and color-sample button, the transform dialog,
//! and the grid (column/row) reorder drag state, plus the matching draw helpers.
//!
//! It is pixel-art-owned and lives per workspace pane (keyed by workbench `grouping` id on
//! `State.canvas_by_grouping`). The workbench never dereferences it; `State.removeCanvasPane`
//! frees it when a pane is torn down.
//! State the shell itself needs (the pane's physical content rect, used to center load/save
//! toasts) stays on the workbench `Workspace` and is exposed through `WorkbenchPaneView`.
const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const FileWidget = @import("widgets/FileWidget.zig");
const Export = @import("dialogs/Export.zig");
const GridLayout = @import("dialogs/GridLayout.zig");
const Clipboard = @import("clipboard.zig");
const TransformOp = @import("transform_op.zig");
const DocLifecycle = @import("doc_lifecycle.zig");
const pixi_mod = @import("../pixi.zig");
const runtime = @import("runtime.zig");

const File = pixi_mod.internal.File;

const CanvasData = @This();

// Grid (column/row) reorder drag state. Set by the rulers (`drawRulerContent`), consumed by
// `FileWidget` (reorder preview) and committed by `processColumnReorder`/`processRowReorder`.
columns_drag_name: []const u8 = undefined,
columns_drag_index: ?usize = null,
columns_target_id: ?dvui.Id = null,
columns_target_index: ?usize = null,
columns_removed_index: ?usize = null,
columns_insert_before_index: ?usize = null,

rows_drag_name: []const u8 = undefined,
rows_drag_index: ?usize = null,
rows_target_id: ?dvui.Id = null,
rows_target_index: ?usize = null,
rows_removed_index: ?usize = null,
rows_insert_before_index: ?usize = null,

horizontal_scroll_info: dvui.ScrollInfo = .{ .vertical = .given, .horizontal = .given },
vertical_scroll_info: dvui.ScrollInfo = .{ .vertical = .given, .horizontal = .given },

horizontal_ruler_height: f32 = 0.0,
vertical_ruler_width: f32 = 0.0,

/// Floating Edit-pill quick-access bar collapse state. Starts collapsed (single hamburger
/// button); the user toggles to expand the full action row.
edit_pill_expanded: bool = false,

pub fn init(grouping: u64) CanvasData {
    return .{
        .columns_drag_name = std.fmt.allocPrint(runtime.allocator(), "column_drag_{d}", .{grouping}) catch "column_drag",
        .rows_drag_name = std.fmt.allocPrint(runtime.allocator(), "row_drag_{d}", .{grouping}) catch "row_drag",
    };
}

/// The drag names are intentionally not freed here: `init` may have fallen back to a static
/// string literal on (effectively impossible) OOM, and freeing a literal is UB. The names are
/// short-lived and never freed.
pub fn deinit(_: *CanvasData) void {}

/// Per-pane chrome for `grouping`, lazily allocated on first document draw.
pub fn forGrouping(grouping: u64) *CanvasData {
    return runtime.state().canvasForGrouping(grouping);
}

pub const RulerOrientation = enum {
    horizontal,
    vertical,
};

pub fn drawRuler(self: *CanvasData, file: *File, orientation: RulerOrientation) void {
    const font = dvui.Font.theme(.body).larger(-1);

    const largest_label = std.fmt.allocPrint(dvui.currentWindow().arena(), "{d}", .{file.rows - 1}) catch {
        dvui.log.err("Failed to allocate largest label", .{});
        return;
    };
    const largest_label_size = font.textSize(largest_label);
    const natural_scale = dvui.currentWindow().natural_scale;
    const largest_label_phys = largest_label_size.scale(natural_scale, dvui.Size.Physical);
    const base_ruler_size = largest_label_size.w + runtime.state().settings.ruler_padding;

    const ruler_thickness: f32 = switch (orientation) {
        .horizontal => blk: {
            self.horizontal_ruler_height = font.textSize("M").h + runtime.state().settings.ruler_padding;
            break :blk self.horizontal_ruler_height;
        },
        .vertical => blk: {
            self.vertical_ruler_width = @max(base_ruler_size, font.textSize("M").h + runtime.state().settings.ruler_padding);
            break :blk self.vertical_ruler_width;
        },
    };

    switch (orientation) {
        .horizontal => {
            var canvas_hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
            });
            defer canvas_hbox.deinit();

            var corner_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .none,
                .min_size_content = .{ .h = self.vertical_ruler_width, .w = self.vertical_ruler_width },
                .background = true,
                .color_fill = dvui.themeGet().color(.window, .fill),
            });
            corner_box.deinit();

            var top_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .min_size_content = .{ .h = ruler_thickness, .w = ruler_thickness },
                .background = true,
                .color_fill = dvui.themeGet().color(.window, .fill),
            });
            defer top_box.deinit();

            self.drawRulerContent(file, font, orientation, ruler_thickness, largest_label, null);
        },
        .vertical => {
            var ruler_box = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .vertical,
                .min_size_content = .{ .w = ruler_thickness, .h = 1.0 },
                .background = true,
                .color_fill = dvui.themeGet().color(.window, .fill),
            });
            defer ruler_box.deinit();

            self.drawRulerContent(file, font, orientation, ruler_thickness, largest_label, largest_label_phys);
        },
    }
}

/// `largest_row_index_*` come from `drawRuler` (widest row index string and its measured size in physical pixels).
fn drawRulerContent(
    self: *CanvasData,
    file: *File,
    font: dvui.Font,
    orientation: RulerOrientation,
    ruler_size: f32,
    largest_row_index_label: []const u8,
    largest_row_index_size_phys: ?dvui.Size.Physical,
) void {
    const scale = file.editor.canvas.scale;
    const canvas = file.editor.canvas;

    switch (orientation) {
        .horizontal => {
            self.horizontal_scroll_info.virtual_size.w = canvas.scroll_info.virtual_size.w;
            self.horizontal_scroll_info.virtual_size.h = ruler_size;
            self.horizontal_scroll_info.viewport.w = canvas.scroll_info.viewport.w;
            self.horizontal_scroll_info.viewport.x = canvas.scroll_info.viewport.x;
        },
        .vertical => {
            self.vertical_scroll_info.virtual_size.h = canvas.scroll_info.virtual_size.h;
            self.vertical_scroll_info.virtual_size.w = ruler_size;
            self.vertical_scroll_info.viewport.h = canvas.scroll_info.viewport.h;
            self.vertical_scroll_info.viewport.y = canvas.scroll_info.viewport.y;
        },
    }

    const scroll_info = switch (orientation) {
        .horizontal => &self.horizontal_scroll_info,
        .vertical => &self.vertical_scroll_info,
    };

    var scroll_area = dvui.scrollArea(@src(), .{
        .scroll_info = scroll_info,
        .container = true,
        .process_events_after = true,
        .horizontal_bar = .hide,
        .vertical_bar = .hide,
    }, .{ .expand = .both });
    defer scroll_area.deinit();

    const scale_rect = switch (orientation) {
        .horizontal => dvui.Rect{ .x = -canvas.origin.x, .y = 0, .w = 0, .h = 0 },
        .vertical => dvui.Rect{ .x = 0, .y = -canvas.origin.y, .w = 0, .h = 0 },
    };
    var scaler = dvui.scale(@src(), .{ .scale = &file.editor.canvas.scale }, .{ .rect = scale_rect });
    defer scaler.deinit();

    const outer_rect: dvui.Rect = switch (orientation) {
        .horizontal => .{
            .x = 0,
            .y = 0,
            .w = @as(f32, @floatFromInt(file.width())),
            .h = ruler_size / scale,
        },
        .vertical => .{
            .x = 0,
            .y = 0,
            .w = ruler_size / scale,
            .h = @as(f32, @floatFromInt(file.height())),
        },
    };
    var outer_box = dvui.box(@src(), .{ .dir = switch (orientation) {
        .horizontal => .horizontal,
        .vertical => .horizontal,
    } }, .{
        .expand = .none,
        .rect = outer_rect,
    });
    defer outer_box.deinit();

    const drag_name = switch (orientation) {
        .horizontal => self.columns_drag_name,
        .vertical => self.rows_drag_name,
    };

    var reorder = pixi_mod.core.dvui.reorder(@src(), .{ .drag_name = drag_name }, .{
        .expand = .both,
        .margin = dvui.Rect.all(0),
        .padding = dvui.Rect.all(0),
        .background = false,
        .corner_radius = dvui.Rect.all(0),
    });
    defer reorder.deinit();

    const reorder_box_dir: dvui.enums.Direction = switch (orientation) {
        .horizontal => .horizontal,
        .vertical => .vertical,
    };
    var reorder_box = dvui.box(@src(), .{ .dir = reorder_box_dir }, .{
        .expand = .both,
        .background = false,
        .corner_radius = dvui.Rect.all(0),
        .margin = dvui.Rect.all(0),
        .padding = dvui.Rect.all(0),
    });
    defer reorder_box.deinit();

    const ruler_stroke_color = dvui.themeGet().color(.control, .fill_hover).lighten(switch (orientation) {
        .horizontal => 2.0,
        .vertical => 0.0,
    });

    const edge_stroke_points = switch (orientation) {
        .horizontal => .{
            reorder_box.data().rectScale().r.topRight(),
            reorder_box.data().rectScale().r.bottomRight(),
        },
        .vertical => .{
            reorder_box.data().rectScale().r.bottomRight(),
            reorder_box.data().rectScale().r.bottomLeft(),
        },
    };
    defer dvui.Path.stroke(.{ .points = &edge_stroke_points }, .{
        .color = ruler_stroke_color,
        .thickness = 1.0,
    });

    const count = switch (orientation) {
        .horizontal => file.columns,
        .vertical => file.rows,
    };
    const cell_min_size: dvui.Size = switch (orientation) {
        .horizontal => .{ .w = @as(f32, @floatFromInt(file.column_width)), .h = 1.0 },
        .vertical => .{ .w = 1.0, .h = @as(f32, @floatFromInt(file.row_height)) },
    };
    const reorder_mode: pixi_mod.core.dvui.ReorderWidget.Reorderable.Mode = switch (orientation) {
        .horizontal => .any_y,
        .vertical => .any_x,
    };
    const reorder_expand: dvui.Options.Expand = switch (orientation) {
        .horizontal => .vertical,
        .vertical => .horizontal,
    };

    // Shared layout width for every row tick (widest index string); actual glyph size may differ per cell.
    const vertical_row_layout_size_phys: ?dvui.Size.Physical = switch (orientation) {
        .vertical => largest_row_index_size_phys,
        .horizontal => null,
    };

    // Captured during iteration: the highlighted target slot (drop location) screen rect.
    var target_rs_screen: ?dvui.RectScale = null;

    var index: usize = 0;
    while (index < count) : (index += 1) {
        var reorderable = reorder.reorderable(@src(), .{
            .mode = reorder_mode,
            .clamp_to_edges = true,
        }, .{
            .expand = reorder_expand,
            .id_extra = index,
            .padding = dvui.Rect.all(0),
            .margin = dvui.Rect.all(0),
            .min_size_content = cell_min_size,
        });
        defer reorderable.deinit();

        if (reorderable.targetRectScale()) |trs| {
            target_rs_screen = trs;
        }

        var button_color = if (reorder.drag_point != null) dvui.themeGet().color(.control, .fill).opacity(0.85) else dvui.themeGet().color(.window, .fill);

        if (pixi_mod.core.dvui.hovered(reorderable.data())) {
            button_color = dvui.themeGet().color(.control, .fill_hover);
            dvui.cursorSet(.hand);
        }

        var cell_box: dvui.BoxWidget = undefined;
        cell_box.init(@src(), .{ .dir = .horizontal }, .{
            .expand = .both,
            .background = true,
            .color_fill = button_color,
            .id_extra = index,
        });

        switch (orientation) {
            .horizontal => {
                if (reorderable.floating()) {
                    self.columns_drag_index = index;
                    reorder.reorderable_size.h = 0.0;
                    dvui.cursorSet(.hand);
                }
                if (reorderable.removed()) self.columns_removed_index = index;
                if (reorderable.insertBefore()) self.columns_insert_before_index = index;
                if (reorderable.targetID()) |target_id| self.columns_target_id = target_id;
                if (self.columns_drag_index) |_| {
                    var mouse_pt = @constCast(&file.editor.canvas).dataFromScreenPoint(dvui.currentWindow().mouse_pt);
                    mouse_pt.y = 0.0;
                    mouse_pt.x = std.math.clamp(mouse_pt.x, 0.0, @as(f32, @floatFromInt(file.width() - 1)));
                    self.columns_target_index = file.columnIndex(mouse_pt);
                }
            },
            .vertical => {
                if (reorderable.floating()) {
                    self.rows_drag_index = index;
                    reorder.reorderable_size.w = 0.0;
                    dvui.cursorSet(.hand);
                }
                if (reorderable.removed()) self.rows_removed_index = index;
                if (reorderable.insertBefore()) self.rows_insert_before_index = index;
                if (reorderable.targetID()) |target_id| self.rows_target_id = target_id;
                if (self.rows_drag_index) |_| {
                    var mouse_pt = @constCast(&file.editor.canvas).dataFromScreenPoint(dvui.currentWindow().mouse_pt);
                    mouse_pt.x = 0.0;
                    mouse_pt.y = std.math.clamp(mouse_pt.y, 0.0, @as(f32, @floatFromInt(file.height() - 1)));
                    self.rows_target_index = file.rowIndex(mouse_pt);
                }
            },
        }

        {
            defer cell_box.deinit();

            // The dragged item's cell_box is parented to the reorderable's floating widget
            // (rendered at the mouse position). We collapse that floating widget to h/w = 0
            // above, but `dvui.renderText` is not clipped by that, so the label would still
            // appear at the cursor. Skip the visible cell rendering entirely while floating;
            // the dragged label is drawn over the highlighted target slot below instead.
            if (!reorderable.floating()) {
                cell_box.drawBackground();

                const label = switch (orientation) {
                    .horizontal => file.fmtColumn(dvui.currentWindow().arena(), @intCast(index)) catch {
                        dvui.log.err("Failed to allocate label", .{});
                        return;
                    },
                    .vertical => std.fmt.allocPrint(dvui.currentWindow().arena(), "{d}", .{index}) catch {
                        dvui.log.err("Failed to allocate label", .{});
                        return;
                    },
                };

                self.drawRulerLabel(.{
                    .font = font,
                    .label = label,
                    .rect = cell_box.data().rectScale().r,
                    .color = dvui.themeGet().color(.control, .text).opacity(0.5),
                    .mode = switch (orientation) {
                        .horizontal => .horizontal,
                        .vertical => .vertical,
                    },
                    .largest_label = if (orientation == .vertical) largest_row_index_label else null,
                    .ref_size_physical = vertical_row_layout_size_phys,
                });

                const cell_rect = cell_box.data().rectScale().r;
                const cell_stroke_points = switch (orientation) {
                    .horizontal => .{ cell_rect.topLeft(), cell_rect.bottomLeft() },
                    .vertical => .{ cell_rect.topLeft(), cell_rect.topRight() },
                };
                dvui.Path.stroke(.{ .points = &cell_stroke_points }, .{ .color = ruler_stroke_color, .thickness = 2.0 });
            }

            loop: for (dvui.events()) |*e| {
                if (!cell_box.matchEvent(e)) continue;

                switch (e.evt) {
                    .mouse => |me| {
                        if (me.action == .press and me.button.pointer()) {
                            e.handle(@src(), cell_box.data());
                            dvui.captureMouse(cell_box.data(), e.num);
                            dvui.dragPreStart(me.p, .{
                                .size = reorderable.data().rectScale().r.size(),
                                .offset = reorderable.data().rectScale().r.topLeft().diff(me.p),
                            });
                        } else if (me.action == .release and me.button.pointer()) {
                            dvui.captureMouse(null, e.num);
                            dvui.dragEnd();
                            switch (orientation) {
                                .horizontal => self.columns_drag_index = null,
                                .vertical => self.rows_drag_index = null,
                            }
                        } else if (me.action == .motion) {
                            if (dvui.captured(cell_box.data().id)) {
                                e.handle(@src(), cell_box.data());
                                if (dvui.dragging(me.p, null)) |_| {
                                    reorderable.reorder.dragStart(reorderable.data().id.asUsize(), me.p, 0);
                                    break :loop;
                                }
                            }
                        }
                    },
                    else => {},
                }
            }
        }
    }

    const final_slot_id = switch (orientation) {
        .horizontal => file.columns,
        .vertical => file.rows,
    };
    if (reorder.needFinalSlot()) {
        var reorderable = reorder.reorderable(@src(), .{
            .mode = reorder_mode,
            .last_slot = true,
            .clamp_to_edges = true,
        }, .{
            .expand = reorder_expand,
            .id_extra = final_slot_id,
            .padding = dvui.Rect.all(0),
            .margin = dvui.Rect.all(0),
            .min_size_content = cell_min_size,
        });
        defer reorderable.deinit();

        if (reorderable.targetRectScale()) |trs| {
            target_rs_screen = trs;
        }

        if (reorderable.insertBefore()) {
            switch (orientation) {
                .horizontal => self.columns_insert_before_index = final_slot_id,
                .vertical => self.rows_insert_before_index = final_slot_id,
            }
        }
    }

    // Drag overlay: draw the dragged column/row label on the highlighted target slot in
    // highlight-text color (no extra fill, the reorderable's own focus fill is the
    // background) and a thick err-colored marker line at the dragged-from position in the
    // ruler that lines up with the equivalent indicator in the file canvas.
    const drag_idx_for_overlay = switch (orientation) {
        .horizontal => self.columns_drag_index,
        .vertical => self.rows_drag_index,
    };
    if (drag_idx_for_overlay) |di| {
        const target_idx_opt = switch (orientation) {
            .horizontal => self.columns_target_index,
            .vertical => self.rows_target_index,
        };
        const same_slot = target_idx_opt == di;

        if (target_rs_screen) |trs| {
            const drag_label_opt: ?[]const u8 = switch (orientation) {
                .horizontal => file.fmtColumn(dvui.currentWindow().arena(), @intCast(di)) catch null,
                .vertical => std.fmt.allocPrint(dvui.currentWindow().arena(), "{d}", .{di}) catch null,
            };
            if (drag_label_opt) |drag_label| {
                if (same_slot) {
                    // Reorderable still draws theme focus fill for the drop target; paint control
                    // hover on top so "no move" matches ruler button hover styling.
                    trs.r.fill(.all(0), .{ .color = dvui.themeGet().color(.control, .fill_hover), .fade = 1.0 });
                }
                self.drawRulerLabel(.{
                    .font = font,
                    .label = drag_label,
                    .rect = trs.r,
                    .color = if (same_slot)
                        dvui.themeGet().color(.control, .text).opacity(0.5)
                    else
                        dvui.themeGet().color(.highlight, .text),
                    .mode = switch (orientation) {
                        .horizontal => .horizontal,
                        .vertical => .vertical,
                    },
                    .largest_label = if (orientation == .vertical) largest_row_index_label else null,
                    .ref_size_physical = vertical_row_layout_size_phys,
                });
            }
        }

        // Use the canvas data->screen mapping for the cross-axis position so the marker
        // line aligns exactly with the err indicator drawn over the file canvas grid.
        // The other axis uses the ruler's own screen extents so the line fills the ruler.
        const target_idx_for_line = switch (orientation) {
            .horizontal => self.columns_target_index,
            .vertical => self.rows_target_index,
        };
        if (target_idx_for_line) |ti| {
            if (di != ti) {
                const removed_data_rect = switch (orientation) {
                    .horizontal => file.columnRect(di),
                    .vertical => file.rowRect(di),
                };
                const removed_canvas_screen = file.editor.canvas.screenFromDataRect(removed_data_rect);
                const ruler_screen = outer_box.data().contentRectScale().r;
                const err_color = dvui.themeGet().color(.err, .fill);
                const thickness = 3.0 * dvui.currentWindow().natural_scale;
                switch (orientation) {
                    .horizontal => {
                        const edge_x = if (di < ti)
                            removed_canvas_screen.x
                        else
                            removed_canvas_screen.x + removed_canvas_screen.w;
                        dvui.Path.stroke(.{ .points = &.{
                            .{ .x = edge_x, .y = ruler_screen.y },
                            .{ .x = edge_x, .y = ruler_screen.y + ruler_screen.h },
                        } }, .{ .thickness = thickness, .color = err_color });
                    },
                    .vertical => {
                        const edge_y = if (di < ti)
                            removed_canvas_screen.y
                        else
                            removed_canvas_screen.y + removed_canvas_screen.h;
                        dvui.Path.stroke(.{ .points = &.{
                            .{ .x = ruler_screen.x, .y = edge_y },
                            .{ .x = ruler_screen.x + ruler_screen.w, .y = edge_y },
                        } }, .{ .thickness = thickness, .color = err_color });
                    },
                }
            }
        }
    }
}

pub const TextLabelOptions = struct {
    pub const Mode = enum {
        horizontal,
        vertical,
    };

    font: dvui.Font,
    label: []const u8,
    rect: dvui.Rect.Physical,
    color: dvui.Color,
    mode: Mode = .horizontal,
    /// Widest row index string (e.g. `"99"`); layout cell size uses this, text may be a shorter index.
    largest_label: ?[]const u8 = null,
    /// When set, layout size for that widest string (already × `natural_scale`); skips `textSize(largest_label)` per cell.
    ref_size_physical: ?dvui.Size.Physical = null,
};

pub fn drawRulerLabel(_: *CanvasData, options: TextLabelOptions) void {
    const font = options.font;
    const label = options.label;
    const rect = options.rect;
    const color = options.color;
    const natural = dvui.currentWindow().natural_scale;

    const ref_for_layout = options.largest_label orelse label;
    const label_size = options.ref_size_physical orelse font.textSize(ref_for_layout).scale(natural, dvui.Size.Physical);
    const actual_label_size = if (std.mem.eql(u8, ref_for_layout, label))
        label_size
    else
        font.textSize(label).scale(natural, dvui.Size.Physical);

    const padding = runtime.state().settings.ruler_padding * natural;

    var label_rect = rect;

    if (label_size.w + padding <= label_rect.w and options.mode == .horizontal) {
        label_rect.h = label_size.h + padding;
        label_rect.x += (label_rect.w - actual_label_size.w) / 2.0;
        label_rect.y += (label_rect.h - actual_label_size.h) / 2.0;

        dvui.renderText(.{
            .text = label,
            .font = font,
            .color = color,
            .rs = .{
                .r = label_rect,
                .s = natural,
            },
        }) catch {
            dvui.log.err("Failed to render text", .{});
        };
    } else if (label_size.h + padding <= label_rect.h and options.mode == .vertical) {
        label_rect.w = label_size.h + padding;
        label_rect.x += (label_rect.w - actual_label_size.w) / 2.0;
        label_rect.y += (label_rect.h - actual_label_size.h) / 2.0;

        dvui.renderText(.{
            .text = label,
            .font = font,
            .color = color,
            .rs = .{
                .r = label_rect,
                .s = natural,
            },
        }) catch {
            dvui.log.err("Failed to render text", .{});
        };
    }
}

pub fn processColumnReorder(self: *CanvasData, file: *File) void {
    if (self.columns_removed_index) |columns_removed_index| {
        if (self.columns_insert_before_index) |columns_insert_before_index| {
            defer self.columns_removed_index = null;
            defer self.columns_insert_before_index = null;

            if (columns_removed_index == columns_insert_before_index or columns_removed_index + 1 == columns_insert_before_index) return;

            file.reorderColumns(columns_removed_index, columns_insert_before_index) catch {
                dvui.log.err("Failed to reorder columns", .{});
                return;
            };

            // We'll store the previous indices for clarity.
            const prev_removed_index = columns_removed_index;
            const prev_insert_before_index = columns_insert_before_index;

            if (prev_removed_index < prev_insert_before_index) {
                file.history.append(.{
                    .reorder_col_row = .{
                        .mode = .columns,
                        .removed_index = prev_insert_before_index - 1,
                        .insert_before_index = prev_removed_index,
                    },
                }) catch {
                    dvui.log.err("Failed to append history", .{});
                };
            } else {
                file.history.append(.{
                    .reorder_col_row = .{
                        .mode = .columns,
                        .removed_index = prev_insert_before_index,
                        .insert_before_index = prev_removed_index + 1,
                    },
                }) catch {
                    dvui.log.err("Failed to append history", .{});
                };
            }
        }
    }
}

pub fn processRowReorder(self: *CanvasData, file: *File) void {
    if (self.rows_removed_index) |rows_removed_index| {
        if (self.rows_insert_before_index) |rows_insert_before_index| {
            defer self.rows_removed_index = null;
            defer self.rows_insert_before_index = null;
            if (rows_removed_index == rows_insert_before_index or rows_removed_index + 1 == rows_insert_before_index) return;

            file.reorderRows(rows_removed_index, rows_insert_before_index) catch {
                dvui.log.err("Failed to reorder rows", .{});
                return;
            };

            // We'll store the previous indices for clarity.
            const prev_removed_index = rows_removed_index;
            const prev_insert_before_index = rows_insert_before_index;

            if (prev_removed_index < prev_insert_before_index) {
                file.history.append(.{
                    .reorder_col_row = .{
                        .mode = .rows,
                        .removed_index = prev_insert_before_index - 1,
                        .insert_before_index = prev_removed_index,
                    },
                }) catch {
                    dvui.log.err("Failed to append history", .{});
                };
            } else {
                file.history.append(.{
                    .reorder_col_row = .{
                        .mode = .rows,
                        .removed_index = prev_insert_before_index,
                        .insert_before_index = prev_removed_index + 1,
                    },
                }) catch {
                    dvui.log.err("Failed to append history", .{});
                };
            }
        }
    }
}

pub fn drawTransformDialog(_: *CanvasData, file: *File, container: *dvui.WidgetData) void {
    if (file.editor.transform) |*transform| {
        var rect = container.rect;
        rect.w = 0;
        rect.h = 0;

        var fw: dvui.FloatingWidget = undefined;
        fw.init(@src(), .{}, .{
            .rect = .{ .x = container.rectScale().r.toNatural().x + 10, .y = container.rectScale().r.toNatural().y + 10, .w = 0, .h = 0 },
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

        var anim = dvui.animate(@src(), .{ .kind = .vertical, .duration = 450_000, .easing = dvui.easing.outBack }, .{});
        defer anim.deinit();

        var anim_box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
            .background = false,
        });
        defer anim_box.deinit();

        dvui.labelNoFmt(@src(), "TRANSFORM", .{ .align_x = 0.5 }, .{
            .padding = dvui.Rect.all(4),
            .expand = .horizontal,
            .font = dvui.Font.theme(.heading).withWeight(.bold),
        });
        _ = dvui.separator(@src(), .{ .expand = .horizontal });

        _ = dvui.spacer(@src(), .{ .expand = .horizontal });

        var degrees: f32 = std.math.radiansToDegrees(transform.rotation);

        var slider_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = false,
        });

        if (dvui.sliderEntry(@src(), "{d:0.0}°", .{
            .value = &degrees,
            .min = 0,
            .max = 360,
            .interval = 1,
        }, .{ .expand = .horizontal, .color_fill = dvui.themeGet().color(.window, .fill) })) {
            transform.rotation = std.math.degreesToRadians(degrees);
        }
        slider_box.deinit();

        if (transform.ortho) {
            var box = dvui.box(@src(), .{ .dir = .horizontal, .equal_space = true }, .{
                .expand = .horizontal,
                .background = false,
            });
            defer box.deinit();
            dvui.label(@src(), "Width: {d:0.0}", .{transform.point(.bottom_left).diff(transform.point(.bottom_right).*).length()}, .{ .expand = .horizontal, .font = dvui.Font.theme(.heading) });
            dvui.label(@src(), "Height: {d:0.0}", .{transform.point(.top_left).diff(transform.point(.bottom_left).*).length()}, .{ .expand = .horizontal, .font = dvui.Font.theme(.heading) });
        }

        {
            var box = dvui.box(@src(), .{ .dir = .horizontal, .equal_space = true }, .{
                .expand = .horizontal,
                .background = false,
            });
            defer box.deinit();
            if (dvui.buttonIcon(@src(), "transform_cancel", icons.tvg.lucide.@"trash-2", .{}, .{ .stroke_color = dvui.themeGet().color(.window, .fill) }, .{ .style = .err, .expand = .horizontal })) {
                DocLifecycle.cancelEdit(runtime.state());
            }
            if (dvui.buttonIcon(@src(), "transform_accept", icons.tvg.lucide.check, .{}, .{ .stroke_color = dvui.themeGet().color(.window, .fill) }, .{ .style = .highlight, .expand = .horizontal })) {
                DocLifecycle.acceptEdit(runtime.state());
            }
        }
    }
}

/// Floating rounded-pill quick-access bar anchored to the top-right of the workspace
/// canvas. Mirrors the Edit menu (Undo / Redo / Copy / Paste / Transform / Grid Layout)
/// with icon-only round buttons sized to match the toolbox buttons. Starts collapsed as a
/// single hamburger circle; tapping toggles the row of action buttons in/out with a
/// width animation.
pub fn drawEditPill(self: *CanvasData, container: *dvui.WidgetData) void {
    const file = runtime.state().docs.activeFile(runtime.state().host) orelse return;

    const button_size: f32 = 36;
    const button_gap: f32 = 6;
    const pill_padding: f32 = 6;
    const margin: f32 = 10;
    // Canvas scroll area uses a non-overlay vertical bar on the right edge; keep the
    // pill clear of it (see `CanvasWidget.install` + dvui `ScrollBarWidget` width).
    const right_margin: f32 = margin + dvui.ScrollBarWidget.defaults.min_sizeGet().w;
    // Icons render at ~60% of their previous size — previous padding was 0.22 (icon
    // ≈ 56% of button); new padding is 0.33 so the icon ends up ≈ 34% of the button,
    // which is roughly 60% of the prior icon footprint.
    const icon_padding: f32 = button_size * 0.33;

    const Action = enum { save, exportd, undo, redo, copy, paste, transform, grid_layout };
    const Entry = struct {
        action: Action,
        tvg: []const u8,
        tooltip: []const u8,
    };

    const entries = [_]Entry{
        .{ .action = .save, .tvg = icons.tvg.lucide.save, .tooltip = "Save" },
        .{ .action = .exportd, .tvg = icons.tvg.lucide.@"file-output", .tooltip = "Export" },
        .{ .action = .undo, .tvg = icons.tvg.lucide.undo, .tooltip = "Undo" },
        .{ .action = .redo, .tvg = icons.tvg.lucide.redo, .tooltip = "Redo" },
        .{ .action = .copy, .tvg = icons.tvg.lucide.copy, .tooltip = "Copy" },
        .{ .action = .paste, .tvg = icons.tvg.lucide.@"clipboard-paste", .tooltip = "Paste" },
        .{ .action = .transform, .tvg = icons.tvg.lucide.scaling, .tooltip = "Transform" },
        .{ .action = .grid_layout, .tvg = icons.tvg.lucide.@"layout-grid", .tooltip = "Grid Layout" },
    };

    // Vertical pill: width is fixed (one button + padding), height animates between a
    // single-button "collapsed" state and the full-stack "expanded" state. Most screens
    // have more vertical real estate than horizontal, so growing the pill downward keeps
    // it from eating into the canvas's working width.
    const pill_w: f32 = button_size + 2 * pill_padding;
    const collapsed_h: f32 = button_size + 2 * pill_padding;
    const expanded_h: f32 = @as(f32, @floatFromInt(entries.len + 1)) * button_size +
        @as(f32, @floatFromInt(entries.len)) * button_gap + 2 * pill_padding;
    const pill_radius: f32 = pill_w / 2;
    const btn_radius: f32 = button_size / 2;

    // Drive the expand/collapse with a dvui animation. Look up the current value, and on
    // a toggle click kick off a new animation between the current value and the target.
    const anim_id = dvui.Id.update(container.id, "edit_pill_expand");
    var anim_value: f32 = if (self.edit_pill_expanded) 1.0 else 0.0;
    if (dvui.animationGet(anim_id, "_t")) |a| anim_value = std.math.clamp(a.value(), 0.0, 1.0);

    const pill_h: f32 = collapsed_h + (expanded_h - collapsed_h) * anim_value;

    // Compute the scroll-area rect — the canvas region inside the rulers. We pull this
    // off the live `canvas_vbox` (so the values are this frame's, not a stale latch) and
    // subtract the ruler thickness from the top/left. Anchoring against this rect means
    // the pill follows the workspace exactly: as a split is dragged shut the canvas area
    // shrinks, and once it's narrower than the pill we bail and draw nothing this frame —
    // so closing splits cleanly hides the menu.
    const wb = container.rectScale().r.toNatural();
    const ruler_top: f32 = if (runtime.state().settings.show_rulers) self.horizontal_ruler_height else 0;
    const ruler_left: f32 = if (runtime.state().settings.show_rulers) self.vertical_ruler_width else 0;
    const canvas_nat = dvui.Rect{
        .x = wb.x + ruler_left,
        .y = wb.y + ruler_top,
        .w = wb.w - ruler_left,
        .h = wb.h - ruler_top,
    };

    if (canvas_nat.w < pill_w + margin + right_margin or canvas_nat.h < collapsed_h + 2 * margin) return;

    const pill_x: f32 = canvas_nat.x + canvas_nat.w - right_margin - pill_w;
    const pill_y: f32 = canvas_nat.y + margin;

    // Clamp the bottom edge so the expanded pill never spills past the canvas area —
    // FloatingWidget bypasses parent clipping, so we cap the height explicitly.
    const max_pill_h: f32 = canvas_nat.h - 2 * margin;
    const effective_pill_h: f32 = @min(pill_h, max_pill_h);

    var fw: dvui.FloatingWidget = undefined;
    fw.init(@src(), .{}, .{
        .rect = .{
            .x = pill_x,
            .y = pill_y,
            .w = pill_w,
            .h = effective_pill_h,
        },
        .expand = .none,
        .background = self.edit_pill_expanded,
        .color_fill = dvui.themeGet().color(.window, .fill),
        .corner_radius = dvui.Rect.all(pill_radius),
        .box_shadow = if (self.edit_pill_expanded) .{
            .color = .black,
            .alpha = 0.25,
            .fade = 10,
            .offset = .{ .x = 0, .y = 3 },
            .corner_radius = dvui.Rect.all(pill_radius),
        } else null,
    });
    defer fw.deinit();

    var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = false,
        .padding = dvui.Rect.all(pill_padding),
    });
    defer vbox.deinit();

    // Hamburger toggle is always present at the top of the pill; the stack of action
    // buttons grows downward beneath it as the pill expands.
    {
        var btn: dvui.ButtonWidget = undefined;
        btn.init(@src(), .{}, .{
            .id_extra = entries.len, // distinct from action button ids below
            .min_size_content = .{ .w = button_size, .h = button_size },
            .expand = .none,
            .gravity_x = 0.5,
            .gravity_y = 0.0,
            .background = true,
            .corner_radius = dvui.Rect.all(btn_radius),
            .color_fill = dvui.themeGet().color(.content, .fill),
            .color_fill_hover = dvui.themeGet().color(.content, .fill).lighten(if (dvui.themeGet().dark) 10.0 else -10.0),
            .color_border = .transparent,
            .padding = .all(0),
            .margin = .{},
            .box_shadow = .{
                .color = .black,
                .alpha = 0.2,
                .fade = 4,
                .offset = .{ .x = 0, .y = 2 },
                .corner_radius = dvui.Rect.all(btn_radius),
            },
        });
        defer btn.deinit();
        btn.processEvents();
        btn.drawBackground();

        const icon_color = dvui.themeGet().color(.content, .text);
        dvui.icon(
            @src(),
            "edit_pill_toggle",
            icons.tvg.lucide.menu,
            .{ .stroke_color = icon_color, .fill_color = icon_color },
            .{
                .expand = .ratio,
                .gravity_x = 0.5,
                .gravity_y = 0.5,
                .min_size_content = .{ .w = 1.0, .h = 1.0 },
                .padding = dvui.Rect.all(icon_padding),
            },
        );

        if (btn.clicked()) {
            self.edit_pill_expanded = !self.edit_pill_expanded;
            const target: f32 = if (self.edit_pill_expanded) 1.0 else 0.0;
            dvui.animation(anim_id, "_t", .{
                .start_val = anim_value,
                .end_val = target,
                .end_time = 250_000,
                .easing = dvui.easing.outBack,
            });
        }
    }

    // Action buttons live inside a scroll area so the pill stays the right width and
    // never visually "squishes" when there isn't enough vertical room — instead the
    // overflow buttons become reachable via vertical scroll inside the pill. Bars are
    // hidden to preserve the rounded-pill look; touch / wheel still drives the scroll.
    var actions_scroll = dvui.scrollArea(@src(), .{
        .vertical_bar = .hide,
        .horizontal_bar = .hide,
    }, .{
        .expand = .both,
        .background = false,
        .padding = .{},
        .margin = .{},
        .border = dvui.Rect.all(0),
        .color_fill = .transparent,
    });
    defer actions_scroll.deinit();

    // Action buttons stacked below the hamburger. We draw them all and let the
    // scrollArea handle any overflow when the pill is clamped to the canvas height.
    for (entries, 0..) |entry, i| {
        const enabled: bool = switch (entry.action) {
            .save => file.dirty(),
            .undo => file.history.undo_stack.items.len > 0,
            .redo => file.history.redo_stack.items.len > 0,
            else => true,
        };

        var btn: dvui.ButtonWidget = undefined;
        btn.init(@src(), .{}, .{
            .id_extra = i,
            .min_size_content = .{ .w = button_size, .h = button_size },
            .expand = .none,
            .gravity_x = 0.5,
            .background = true,
            .corner_radius = dvui.Rect.all(btn_radius),
            .color_fill = dvui.themeGet().color(.content, .fill),
            .color_fill_hover = dvui.themeGet().color(.content, .fill).lighten(if (dvui.themeGet().dark) 10.0 else -10.0),
            .color_border = .transparent,
            .padding = .all(0),
            .margin = .{ .y = button_gap },
            .box_shadow = .{
                .color = .black,
                .alpha = 0.2,
                .fade = 4,
                .offset = .{ .x = 0, .y = 2 },
                .corner_radius = dvui.Rect.all(btn_radius),
            },
        });
        defer btn.deinit();
        btn.processEvents();
        btn.drawBackground();

        const icon_color = if (enabled) dvui.themeGet().color(.content, .text) else dvui.themeGet().color(.content, .text).opacity(0.35);

        dvui.icon(
            @src(),
            entry.tooltip,
            entry.tvg,
            .{ .stroke_color = icon_color, .fill_color = icon_color },
            .{
                .expand = .ratio,
                .gravity_x = 0.5,
                .gravity_y = 0.5,
                .min_size_content = .{ .w = 1.0, .h = 1.0 },
                .padding = dvui.Rect.all(icon_padding),
            },
        );

        // Suppress activation while collapsed (or mid-animation) so a stray tap on a
        // partially-visible button doesn't fire an Edit action behind the hamburger.
        const fully_expanded = anim_value >= 0.999;
        if (btn.clicked() and enabled and fully_expanded) {
            switch (entry.action) {
                .save => runtime.state().host.save() catch {
                    dvui.log.err("Failed to save", .{});
                },
                .exportd => {
                    // Open the Export dialog (same configuration the `export` keybind uses).
                    var mutex = pixi_mod.core.dvui.dialog(@src(), .{
                        .displayFn = Export.dialog,
                        .callafterFn = Export.callAfter,
                        .title = "Export...",
                        .ok_label = "Export",
                        .cancel_label = "Cancel",
                        .resizeable = false,
                        .modal = false,
                        .header_kind = .info,
                        .default = .ok,
                    });
                    mutex.mutex.unlock(dvui.io);
                },
                .undo => file.history.undoRedo(file, .undo) catch {
                    dvui.log.err("Failed to undo", .{});
                },
                .redo => file.history.undoRedo(file, .redo) catch {
                    dvui.log.err("Failed to redo", .{});
                },
                .copy => Clipboard.copy(runtime.state()) catch {
                    dvui.log.err("Failed to copy", .{});
                },
                .paste => Clipboard.paste(runtime.state()) catch {
                    dvui.log.err("Failed to paste", .{});
                },
                .transform => TransformOp.begin(runtime.state()) catch {
                    dvui.log.err("Failed to start transform", .{});
                },
                .grid_layout => {
                    if (runtime.state().host.activeDoc()) |doc| GridLayout.request(doc.id);
                },
            }
        }
    }
}

/// Floating round button anchored just to the left of the Edit pill at the top-right of
/// the canvas. Tapping it shows a tooltip explaining the gesture; the primary action is
/// to drag from the button toward whatever pixel you want to sample. The button itself
/// stays put — instead, while the drag is in progress, we route the touch position
/// through to `file.editor.canvas.sample_data_point` so `FileWidget.drawSample` renders
/// the existing color-dropper magnifier at the touch location. On release we read the
/// color underneath the sample point and apply it to the primary color slot.
pub fn drawSampleButton(self: *CanvasData, container: *dvui.WidgetData) void {
    const file = runtime.state().docs.activeFile(runtime.state().host) orelse return;

    const pill_button_size: f32 = 36;
    const pill_padding: f32 = 6;
    const pill_outer_w: f32 = pill_button_size + 2 * pill_padding;
    const button_size: f32 = 36;
    const btn_radius: f32 = button_size / 2;
    const icon_padding: f32 = button_size * 0.33;
    const margin: f32 = 10;
    const right_margin: f32 = margin + dvui.ScrollBarWidget.defaults.min_sizeGet().w;
    const gap: f32 = 6;

    // Anchor against the same canvas-scroll-area rect the pill uses.
    const wb = container.rectScale().r.toNatural();
    const ruler_top: f32 = if (runtime.state().settings.show_rulers) self.horizontal_ruler_height else 0;
    const ruler_left: f32 = if (runtime.state().settings.show_rulers) self.vertical_ruler_width else 0;
    const canvas_nat = dvui.Rect{
        .x = wb.x + ruler_left,
        .y = wb.y + ruler_top,
        .w = wb.w - ruler_left,
        .h = wb.h - ruler_top,
    };

    // Only draw when the canvas area can fit pill + gap + sample button + margins.
    if (canvas_nat.w < pill_outer_w + gap + button_size + margin + right_margin) return;
    if (canvas_nat.h < button_size + 2 * margin) return;

    const btn_x = canvas_nat.x + canvas_nat.w - right_margin - pill_outer_w - gap - button_size;
    // Match the hamburger row inside the pill (pill top + inner vbox padding).
    const btn_y = canvas_nat.y + margin + pill_padding;

    var fw: dvui.FloatingWidget = undefined;
    fw.init(@src(), .{}, .{
        .rect = .{ .x = btn_x, .y = btn_y, .w = button_size, .h = button_size },
        .expand = .none,
        .background = false,
    });
    defer fw.deinit();

    var btn: dvui.ButtonWidget = undefined;
    // `touch_drag = true` keeps `ButtonWidget`'s own capture alive while the touch is
    // dragging away from the button — without it, dvui's default `clickedEx` releases
    // capture as soon as the drag crosses the threshold (treating the gesture as a
    // canceled scroll), which would also cancel our custom drag-to-sample handler.
    btn.init(@src(), .{ .touch_drag = true }, .{
        .expand = .both,
        .background = true,
        .min_size_content = .{ .w = button_size, .h = button_size },
        .corner_radius = dvui.Rect.all(btn_radius),
        .color_fill = dvui.themeGet().color(.content, .fill),
        .color_fill_hover = dvui.themeGet().color(.content, .fill).lighten(if (dvui.themeGet().dark) 10.0 else -10.0),
        .color_border = .transparent,
        .padding = .all(0),
        .margin = .{},
        .box_shadow = .{
            .color = .black,
            .alpha = 0.2,
            .fade = 4,
            .offset = .{ .x = 0, .y = 2 },
            .corner_radius = dvui.Rect.all(btn_radius),
        },
    });
    defer btn.deinit();

    // Persistent drag state (a press is "drag-sampling" once motion clears the dvui drag
    // threshold). Stored via dataSet because the button widget is recreated each frame.
    const drag_state_id = dvui.Id.update(container.id, "sample_button_drag");
    var is_drag_sampling = dvui.dataGet(null, drag_state_id, "active", bool) orelse false;
    var did_sample = dvui.dataGet(null, drag_state_id, "did_sample", bool) orelse false;

    // The button's screen rect is the "press home base"; events that happen here belong
    // to us regardless of whether motion has carried the pointer away.
    const btn_rs = btn.data().rectScale();

    // Custom event handling runs *before* `btn.processEvents()` so we can claim the
    // press / motion / release events first. `ButtonWidget.clickedEx` ALWAYS releases
    // mouse capture and ends the drag on a release event (regardless of touch_drag) —
    // if we ran after it, our release branch would see `dvui.captured(...)` already
    // false and the magnifier would stay stuck on screen. Calling `e.handle(...)` here
    // makes `clickedEx`'s match-event check skip these events entirely, so the button
    // leaves our gesture alone.
    for (dvui.events()) |*e| {
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;

        switch (me.action) {
            .press => {
                if (!me.button.pointer()) continue;
                if (!btn_rs.r.contains(me.p)) continue;
                e.handle(@src(), btn.data());
                dvui.captureMouse(btn.data(), e.num);
                dvui.dragPreStart(me.p, .{ .name = "sample_button_drag" });
                is_drag_sampling = false;
                did_sample = false;
            },
            .motion => {
                if (!dvui.captured(btn.data().id)) continue;
                if (dvui.dragging(me.p, "sample_button_drag")) |_| {
                    is_drag_sampling = true;
                    if (file.editor.canvas.samplePointerInViewport(me.p)) {
                        const data_pt = file.editor.canvas.dataFromScreenPoint(me.p);
                        dvui.dataSet(null, file.editor.canvas.id, "sample_data_point", data_pt);
                        did_sample = true;
                    } else {
                        dvui.dataRemove(null, file.editor.canvas.id, "sample_data_point");
                    }
                    dvui.refresh(null, @src(), file.editor.canvas.id);
                    e.handle(@src(), btn.data());
                }
            },
            .release => {
                if (!me.button.pointer()) continue;
                if (!dvui.captured(btn.data().id)) continue;
                e.handle(@src(), btn.data());
                dvui.captureMouse(null, e.num);
                dvui.dragEnd();

                if (is_drag_sampling and did_sample and file.editor.canvas.samplePointerInViewport(me.p)) {
                    const data_pt = file.editor.canvas.dataFromScreenPoint(me.p);
                    FileWidget.sampleColorAtPoint(file, data_pt, false, true, true);
                }

                // Clear sample state so the magnifier disappears on the next frame.
                dvui.dataRemove(null, file.editor.canvas.id, "sample_data_point");
                is_drag_sampling = false;
                did_sample = false;
                dvui.refresh(null, @src(), file.editor.canvas.id);
            },
            else => {},
        }
    }

    // Persist the drag state for the next frame's widget recreate.
    dvui.dataSet(null, drag_state_id, "active", is_drag_sampling);
    dvui.dataSet(null, drag_state_id, "did_sample", did_sample);

    // Now let the button run its own pass to handle hover styling against any remaining
    // (non-claimed) events — i.e. plain mouse hover when we're not in a drag.
    btn.processEvents();
    btn.drawBackground();

    const icon_color = dvui.themeGet().color(.content, .text);
    dvui.icon(
        @src(),
        "sample_dropper",
        icons.tvg.lucide.pipette,
        .{ .stroke_color = icon_color, .fill_color = icon_color },
        .{
            .expand = .ratio,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 1.0, .h = 1.0 },
            .padding = dvui.Rect.all(icon_padding),
        },
    );

    // While the drag is in progress, hide the OS cursor entirely so only the canvas
    // magnifier (drawn at the touch point via `FileWidget.drawSample`) communicates
    // where the sample is happening. Set after `btn.processEvents()` so it overrides
    // the `.hand` hover cursor `clickedEx` would otherwise leave in place.
    if (is_drag_sampling) {
        dvui.cursorSet(.hidden);
    }

    // Tooltip prompting the gesture. We hide it during an active sample drag so it
    // doesn't compete with the magnifier on screen.
    if (!is_drag_sampling) {
        var tooltip: dvui.FloatingTooltipWidget = undefined;
        tooltip.init(@src(), .{
            .active_rect = btn.data().rectScale().r,
            .delay = 350_000,
        }, .{
            .color_fill = dvui.themeGet().color(.window, .fill),
            .border = dvui.Rect.all(0),
            .box_shadow = .{
                .color = .black,
                .shrink = 0,
                .corner_radius = dvui.Rect.all(8),
                .offset = .{ .x = 0, .y = 2 },
                .fade = 4,
                .alpha = 0.2,
            },
        });
        defer tooltip.deinit();

        if (tooltip.shown()) {
            var anim = dvui.animate(@src(), .{ .kind = .alpha, .duration = 250_000 }, .{ .expand = .both });
            defer anim.deinit();

            var tl = dvui.textLayout(@src(), .{}, .{
                .background = false,
                .padding = dvui.Rect.all(6),
            });
            tl.format("Drag to sample color", .{}, .{ .font = dvui.Font.theme(.body) });
            tl.deinit();
        }
    }
}
