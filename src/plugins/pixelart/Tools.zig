const std = @import("std");
const fizzy = @import("../../fizzy.zig");
const dvui = @import("dvui");

const Tools = @This();

pub const max_brush_size: u32 = 256;
pub const max_brush_size_float: f32 = @as(f32, @floatFromInt(max_brush_size));
pub const min_full_stroke_size: u32 = 10;

pub const Tool = enum(u32) {
    pointer,
    pencil,
    eraser,
    bucket,
    selection,
};

pub const Shape = enum(u32) {
    circle,
    square,
};

/// Pixel selection uses the brush stroke; box selection uses a rectangular marquee;
/// color selection flood-fills contiguous pixels of the clicked color on the active layer.
pub const SelectionMode = enum {
    pixel,
    box,
    color,
};

pub const RadialMenu = struct {
    mouse_position: dvui.Point.Physical = .{ .x = 0.0, .y = 0.0 },
    center: dvui.Point.Physical = .{ .x = 0.0, .y = 0.0 },
    visible: bool = false,
    /// Opened by press-and-hold on empty workspace (not Space / quick-tools). Both paths pin
    /// `center` at open; this flag only selects hold-specific dismiss behavior.
    opened_by_press: bool = false,
    /// Ignore the first pointer release after a hold-open (lifting the opening finger).
    suppress_next_pointer_release: bool = false,
    /// Press began outside the menu while it is hold-open; used for click-outside dismiss.
    outside_click_press_p: ?dvui.Point.Physical = null,

    pub fn close(self: *RadialMenu) void {
        self.visible = false;
        self.opened_by_press = false;
        self.suppress_next_pointer_release = false;
        self.outside_click_press_p = null;
    }

    /// Physical hit radius for the radial tool ring (matches `drawRadialMenu` outer disc).
    pub fn hitRadiusPhysical() f32 {
        return 165.0;
    }

    pub fn containsPhysical(self: RadialMenu, p: dvui.Point.Physical) bool {
        const r = hitRadiusPhysical();
        const dx = p.x - self.center.x;
        const dy = p.y - self.center.y;
        return dx * dx + dy * dy <= r * r;
    }
};

pub const default_pencil_stroke_size: u8 = 1;
pub const default_selection_stroke_size: u8 = 6;

current: Tool = .pointer,
previous: Tool = .pointer,
/// The stroke size for the currently active tool. Mirrors either
/// `pencil_stroke_size` or `selection_stroke_size` depending on `current`.
stroke_size: u8 = default_pencil_stroke_size,
/// Independent stroke size used by pencil/eraser/bucket.
pencil_stroke_size: u8 = default_pencil_stroke_size,
/// Independent stroke size used by the selection tool.
selection_stroke_size: u8 = default_selection_stroke_size,
stroke_shape: Shape = .circle,
previous_drawing_tool: Tool = .pencil,
radial_menu: RadialMenu = .{},
selection_mode: SelectionMode = .box,

stroke: std.StaticBitSet(max_brush_size * max_brush_size) = .initEmpty(),
offset_table: [][2]f32 = undefined,

pub fn init(allocator: std.mem.Allocator) !Tools {
    var tools: Tools = .{
        .offset_table = try allocator.alloc([2]f32, max_brush_size * max_brush_size),
    };

    for (0..(max_brush_size * max_brush_size)) |index| {
        const center: dvui.Point = .{ .x = @floor(max_brush_size_float / 2), .y = @floor(max_brush_size_float / 2) };
        const x: f32 = @as(f32, @floatFromInt(@mod(index, max_brush_size)));
        const y: f32 = @as(f32, @floatFromInt(index)) / max_brush_size_float;
        tools.offset_table[index] = .{ @floor(x - center.x), @floor(y - center.y) };
    }

    tools.setStrokeSize(tools.strokeSizeFor(tools.current));

    return tools;
}

/// Returns the stored stroke size for the given tool.
fn strokeSizeFor(self: *const Tools, tool: Tool) u8 {
    return switch (tool) {
        .selection => self.selection_stroke_size,
        else => self.pencil_stroke_size,
    };
}

/// Recreates the stroke bitset and writes-through the size to the
/// per-tool storage for the currently active tool.
pub fn setStrokeSize(self: *Tools, size: u8) void {
    self.stroke_size = size;
    switch (self.current) {
        .selection => self.selection_stroke_size = size,
        .pencil, .eraser, .bucket => self.pencil_stroke_size = size,
        .pointer => {},
    }

    const stroke_size: usize = @intCast(size);

    self.stroke.setRangeValue(.{ .start = 0, .end = max_brush_size * max_brush_size }, false);

    const center: dvui.Point = .{ .x = @floor(max_brush_size_float / 2), .y = @floor(max_brush_size_float / 2) };

    for (0..(stroke_size * stroke_size)) |index| {
        if (self.getIndexShapeOffset(center, index)) |i| {
            self.stroke.set(i);
        }
    }
}

pub fn deinit(self: *Tools, allocator: std.mem.Allocator) void {
    allocator.free(self.offset_table);
}

pub fn set(self: *Tools, tool: Tool) void {
    if (self.current != tool) {
        // if (fizzy.editor.getFile(fizzy.editor.open_file_index)) |file| {
        //     // if (file.transform_texture != null and tool != .pointer)
        //     //     return;

        //     switch (tool) {
        //         .heightmap => {
        //             file.heightmap.enable();
        //             if (file.heightmap.layer == null)
        //                 return;
        //         },
        //         .pointer => {
        //             file.heightmap.disable();

        //             // if (self.current == .selection)
        //             //     file.selection_layer.clear(true);
        //         },
        //         else => {},
        //     }
        // }
        self.previous = self.current;
        switch (self.previous) {
            .pencil, .bucket => |t| self.previous_drawing_tool = t,
            else => {},
        }
        self.current = tool;
        self.setStrokeSize(self.strokeSizeFor(tool));
        if (tool == .pencil or tool == .eraser) {
            fizzy.editor.requestCompositeWarmup();
        }
    }
}

pub fn swap(self: *Tools) void {
    const temp = self.current;
    self.current = self.previous;
    self.previous = temp;
}

pub fn getIndex(_: *Tools, point: dvui.Point) ?usize {
    if (point.x < 0 or point.y < 0) {
        return null;
    }

    if (point.x >= max_brush_size_float or point.y >= max_brush_size_float) {
        return null;
    }

    const p: [2]usize = .{ @intFromFloat(point.x), @intFromFloat(point.y) };

    const index = p[0] + p[1] * @as(usize, @intFromFloat(max_brush_size_float));
    if (index >= max_brush_size * max_brush_size) {
        return 0;
    }
    return index;
}

/// Only used for handling getting the pixels surrounding the origin
/// for stroke sizes larger than 1
pub fn getIndexShapeOffset(self: *Tools, origin: dvui.Point, current_index: usize) ?usize {
    const shape = fizzy.pixelart.tools.stroke_shape;
    const s: i32 = @intCast(fizzy.pixelart.tools.stroke_size);

    if (s == 1) {
        if (current_index != 0)
            return null;

        if (self.getIndex(origin)) |index| {
            return index;
        }
    }

    const size_center_offset: i32 = -@divFloor(@as(i32, @intCast(s)), 2);
    const index_i32: i32 = @as(i32, @intCast(current_index));
    const pixel_offset: [2]i32 = .{ @mod(index_i32, s) + size_center_offset, @divFloor(index_i32, s) + size_center_offset };

    if (shape == .circle) {
        const extra_pixel_offset_circle: [2]i32 = if (@mod(s, 2) == 0) .{ 1, 1 } else .{ 0, 0 };
        const pixel_offset_circle: [2]i32 = .{ pixel_offset[0] * 2 + extra_pixel_offset_circle[0], pixel_offset[1] * 2 + extra_pixel_offset_circle[1] };
        const sqr_magnitude = pixel_offset_circle[0] * pixel_offset_circle[0] + pixel_offset_circle[1] * pixel_offset_circle[1];

        // adjust radius check for nicer looking circles
        const radius_check_mult: f32 = (if (s == 3 or s > 10) 0.7 else 0.8);

        if (@as(f32, @floatFromInt(sqr_magnitude)) > @as(f32, @floatFromInt(s * s)) * radius_check_mult) {
            return null;
        }
    }

    const pixel_i32: [2]i32 = .{ @as(i32, @intFromFloat(origin.x)) + pixel_offset[0], @as(i32, @intFromFloat(origin.y)) + pixel_offset[1] };
    const size_i32: [2]i32 = .{ @as(i32, @intCast(max_brush_size)), @as(i32, @intCast(max_brush_size)) };

    if (pixel_i32[0] < 0 or pixel_i32[1] < 0 or pixel_i32[0] >= size_i32[0] or pixel_i32[1] >= size_i32[1]) {
        return null;
    }

    const pixel: dvui.Point = .{ .x = @floatFromInt(pixel_i32[0]), .y = @floatFromInt(pixel_i32[1]) };

    if (self.getIndex(pixel)) |index| {
        return index;
    }

    return null;
}

pub fn drawTooltip(_: Tools, tool: Tool, rect: dvui.Rect.Physical, id_extra: u64) !void {
    const tool_name = switch (tool) {
        .pointer => "POINTER",
        .pencil => "PENCIL",
        .eraser => "ERASER",
        .bucket => "BUCKET",
        .selection => "SELECTION",
    };

    const tool_description = switch (tool) {
        .pointer => "Select and move cells, rows, or columns. \n" ++
            "Hold cmd/ctrl to add to selection, and shift to subtract. \n" ++
            "Dragging can add multiple cells at once.",
        .pencil => "Draw on the canvas with the left mouse button.\n" ++
            "Right click to pick up a color from the canvas. \n" ++
            "[ & ] keys increase and decrease the stroke size.",
        .eraser => "Erase on the canvas.\n" ++
            "Right click an empty area to switch to the eraser tool. \n" ++
            "[ & ] keys increase and decrease the erase size.",
        .bucket => "Fill the canvas with a color.\n" ++ "Hold cmd/ctrl to replace all color, non-contiguously.\n",
        .selection => "Pixel mode brushes with stroke size.\nBox mode drags a rectangular marquee.\nColor mode selects contiguous pixels of the clicked color.\n" ++ "Hold cmd/ctrl to add to selection, and shift to subtract.\n",
    };

    var tooltip: dvui.FloatingTooltipWidget = undefined;
    tooltip.init(@src(), .{
        .active_rect = rect,
        .delay = 500_000,
        .interactive = if (tool == .selection) true else false,
    }, .{
        .id_extra = @intCast(id_extra),
        .color_fill = dvui.themeGet().color(.content, .fill).opacity(0.9),
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
        var animator = dvui.animate(@src(), .{
            .kind = .alpha,
            .duration = 500_000,
        }, .{
            .expand = .both,
        });
        defer animator.deinit();

        var vbox2 = dvui.box(@src(), .{ .dir = .vertical }, dvui.FloatingTooltipWidget.defaults.override(.{
            .background = false,
            .expand = .both,
            .border = dvui.Rect.all(0),
        }));
        defer vbox2.deinit();

        fizzy.dvui.labelWithKeybind(
            tool_name,
            switch (tool) {
                .pointer => dvui.currentWindow().keybinds.get("pointer") orelse .{},
                .pencil => dvui.currentWindow().keybinds.get("pencil") orelse .{},
                .eraser => dvui.currentWindow().keybinds.get("eraser") orelse .{},
                .bucket => dvui.currentWindow().keybinds.get("bucket") orelse .{},
                .selection => dvui.currentWindow().keybinds.get("selection") orelse .{},
            },
            true,
            .{
                .font = dvui.Font.theme(.heading),
            },
            .{
                .font = dvui.Font.theme(.mono).larger(-2.0),
                .margin = dvui.Rect.all(4),
            },
        );

        _ = dvui.separator(@src(), .{ .expand = .horizontal });

        dvui.labelNoFmt(@src(), tool_description, .{}, .{
            .font = dvui.Font.theme(.body).larger(-1.0),
            .margin = dvui.Rect.all(4),
        });

        if (tool == .selection) {
            _ = dvui.separator(@src(), .{ .expand = .horizontal });

            var mode_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .none,
                .gravity_x = 0.5,
                .margin = dvui.Rect.all(4),
            });
            defer mode_row.deinit();

            const atlas_size: dvui.Size = dvui.imageSize(fizzy.pixelart.host.uiAtlas().source) catch .{ .w = 0, .h = 0 };

            var mode_color = dvui.themeGet().color(.control, .fill_hover);
            if (fizzy.pixelart.colors.file_tree_palette) |*palette| {
                mode_color = palette.getDVUIColor(4);
            }

            {
                var mode_box = dvui.groupBox(@src(), "SELECTION MODE", .{
                    .expand = .horizontal,
                    .margin = dvui.Rect.all(4),
                    .font = dvui.Font.theme(.heading),
                });
                defer mode_box.deinit();

                var mode_arrange_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .none,
                });
                defer mode_arrange_box.deinit();

                for (0..3) |mi| {
                    const mode: SelectionMode = switch (mi) {
                        0 => .box,
                        1 => .pixel,
                        2 => .color,
                        else => unreachable,
                    };
                    const cap = switch (mi) {
                        0 => "BOX",
                        1 => "PIXEL",
                        2 => "COLOR",
                        else => unreachable,
                    };
                    const selected = fizzy.pixelart.tools.selection_mode == mode;

                    var mode_col = dvui.box(@src(), .{ .dir = .vertical }, .{
                        .expand = .none,
                        .margin = dvui.Rect.rect(6, 0, 6, 0),
                        .id_extra = @intCast(id_extra * 10 + mi),
                    });
                    defer mode_col.deinit();

                    const sprite = switch (mode) {
                        .box => fizzy.pixelart.host.uiAtlas().sprites[fizzy.atlas.sprites.box_selection_default],
                        .pixel => fizzy.pixelart.host.uiAtlas().sprites[fizzy.atlas.sprites.pixel_selection_default],
                        .color => fizzy.pixelart.host.uiAtlas().sprites[fizzy.atlas.sprites.color_selection_default],
                    };
                    const uv = dvui.Rect{
                        .x = @as(f32, @floatFromInt(sprite.source[0])) / atlas_size.w,
                        .y = @as(f32, @floatFromInt(sprite.source[1])) / atlas_size.h,
                        .w = @as(f32, @floatFromInt(sprite.source[2])) / atlas_size.w,
                        .h = @as(f32, @floatFromInt(sprite.source[3])) / atlas_size.h,
                    };

                    dvui.labelNoFmt(@src(), cap, .{}, .{
                        .font = dvui.Font.theme(.heading),
                        .gravity_x = 0.5,
                        .margin = dvui.Rect.rect(0, 0, 0, 6),
                        .id_extra = @intCast(id_extra * 10 + mi),
                    });

                    var mode_button: dvui.ButtonWidget = undefined;
                    mode_button.init(@src(), .{}, .{
                        .expand = .none,
                        .min_size_content = .{ .w = 40, .h = 40 },
                        .id_extra = @intCast(id_extra * 10 + mi + 1),
                        .background = true,
                        .corner_radius = dvui.Rect.all(1000),
                        .color_fill = if (selected) dvui.themeGet().color(.content, .fill) else .transparent,
                        .color_fill_hover = dvui.themeGet().color(.content, .fill).lighten(if (dvui.themeGet().dark) 10.0 else -10.0),
                        .box_shadow = if (selected) .{
                            .color = .black,
                            .offset = .{ .x = -2.5, .y = 2.5 },
                            .fade = 4.0,
                            .alpha = 0.25,
                            .corner_radius = dvui.Rect.all(1000),
                        } else null,
                        .padding = .all(0),
                    });
                    defer mode_button.deinit();

                    if (mode_button.hovered()) {
                        mode_button.data().options.color_border = mode_color;
                    }

                    mode_button.processEvents();
                    mode_button.drawBackground();

                    var rs = mode_button.data().contentRectScale();
                    const width = @as(f32, @floatFromInt(sprite.source[2])) * rs.s;
                    const height = @as(f32, @floatFromInt(sprite.source[3])) * rs.s;
                    rs.r.x = @round(rs.r.x + (rs.r.w - width) / 2.0);
                    rs.r.y = @round(rs.r.y + (rs.r.h - height) / 2.0);
                    rs.r.w = width;
                    rs.r.h = height;

                    dvui.renderImage(fizzy.pixelart.host.uiAtlas().source, rs, .{
                        .uv = uv,
                        .fade = 0.0,
                    }) catch {
                        std.log.err("Failed to render selection mode icon", .{});
                    };

                    if (mode_button.clicked()) {
                        fizzy.pixelart.tools.selection_mode = mode;
                    }
                }
            }
        }
    }
}
