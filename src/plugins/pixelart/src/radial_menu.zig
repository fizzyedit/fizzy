//! Radial tool menu overlay — opened via Space / hold on empty workspace.
const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const pixelart = @import("../pixelart.zig");
const Globals = pixelart.Globals;
const Tools = pixelart.Tools;

pub fn visible() bool {
    return Globals.state.tools.radial_menu.visible;
}

pub fn processHoldOpenInput() void {
    const rm = &Globals.state.tools.radial_menu;
    if (!rm.visible or !rm.opened_by_press) {
        rm.outside_click_press_p = null;
        return;
    }

    const dismiss_move_threshold: f32 = dvui.Dragging.threshold;

    for (dvui.events()) |*e| {
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        rm.mouse_position = me.p;

        const primary = me.button.pointer() or me.button.touch();
        if (!primary) continue;

        switch (me.action) {
            .press => {
                if (!rm.containsPhysical(me.p)) {
                    rm.outside_click_press_p = me.p;
                } else {
                    rm.outside_click_press_p = null;
                }
            },
            .motion => {
                if (rm.outside_click_press_p) |press_p| {
                    if (me.p.diff(press_p).length() > dismiss_move_threshold) {
                        rm.outside_click_press_p = null;
                    }
                }
            },
            .release => {
                if (rm.suppress_next_pointer_release) {
                    rm.suppress_next_pointer_release = false;
                    rm.outside_click_press_p = null;
                    continue;
                }
                if (rm.outside_click_press_p) |press_p| {
                    const moved = me.p.diff(press_p).length() > dismiss_move_threshold;
                    if (!moved and !rm.containsPhysical(me.p) and !rm.containsPhysical(press_p)) {
                        rm.close();
                    }
                    rm.outside_click_press_p = null;
                }
            },
            else => {},
        }
    }
}

pub fn draw() !void {
    var fw: dvui.FloatingWidget = undefined;
    fw.init(@src(), .{}, .{
        .rect = .cast(dvui.windowRect()),
    });
    defer fw.deinit();

    const menu_color = dvui.themeGet().color(.content, .fill).lighten(4.0);
    const center = fw.data().rectScale().pointFromPhysical(Globals.state.tools.radial_menu.center);
    const tool_count: usize = std.meta.fields(Tools.Tool).len;
    const radius: f32 = 50.0;
    const width: f32 = radius * 2.0;
    const height: f32 = radius * 2.0;
    const step: f32 = (2.0 * std.math.pi) / @as(f32, @floatFromInt(tool_count));
    var angle: f32 = 180.0;

    var outer_anim = dvui.animate(@src(), .{ .duration = 400_000, .kind = .horizontal, .easing = dvui.easing.outBack }, .{});
    const temp_radius: f32 = 3.0 * radius * (outer_anim.val orelse 1.0);
    var outer_rect = dvui.Rect.fromPoint(center);
    outer_rect.w = temp_radius;
    outer_rect.h = temp_radius;
    outer_rect.x -= outer_rect.w / 2.0;
    outer_rect.y -= outer_rect.h / 2.0;

    var box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .rect = outer_rect,
        .expand = .none,
        .background = true,
        .corner_radius = dvui.Rect.all(100000),
        .box_shadow = .{
            .color = .black,
            .offset = .{ .x = -4.0, .y = 4.0 },
            .fade = 8.0,
            .alpha = 0.35,
        },
        .color_fill = menu_color.opacity(0.75),
        .border = dvui.Rect.all(0.0),
    });
    box.deinit();
    outer_anim.deinit();

    const ui_atlas = Globals.state.host.uiAtlas();

    for (0..tool_count) |i| {
        var anim = dvui.animate(@src(), .{ .duration = 100_000 + 50_000 * @as(i32, @intCast(i)), .kind = .alpha, .easing = dvui.easing.linear }, .{
            .id_extra = i,
        });
        defer anim.deinit();

        if (anim.val) |val| {
            angle += ((1 - val) * 100.0) * 0.015;
        }

        var color = dvui.themeGet().color(.control, .fill_hover);
        if (Globals.state.colors.file_tree_palette) |*palette| {
            color = palette.getDVUIColor(i);
        }

        const x: f32 = std.math.round(width / 2.0 + radius * std.math.cos(angle) - width / 2.0);
        const y: f32 = std.math.round(height / 2.0 + radius * std.math.sin(angle) - height / 2.0);
        const new_center = center.plus(.{ .x = x, .y = y });
        var rect = dvui.Rect.fromPoint(new_center);
        rect.w = 40.0;
        rect.h = 40.0;
        rect.x -= rect.w / 2.0;
        rect.y -= rect.h / 2.0;

        const tool = @as(Tools.Tool, @enumFromInt(i));
        var button: dvui.ButtonWidget = undefined;
        button.init(@src(), .{}, .{
            .rect = rect,
            .id_extra = i,
            .corner_radius = dvui.Rect.all(1000.0),
            .color_fill = if (tool == Globals.state.tools.current) dvui.themeGet().color(.content, .fill) else .transparent,
            .box_shadow = if (tool == Globals.state.tools.current) .{
                .color = .black,
                .offset = .{ .x = -2.5, .y = 2.5 },
                .fade = 4.0,
                .alpha = 0.25,
                .corner_radius = dvui.Rect.all(1000),
            } else null,
            .padding = .all(0),
            .margin = .all(0),
        });

        Globals.state.tools.drawTooltip(tool, button.data().rectScale().r, i) catch {};

        const selection_sprite = switch (Globals.state.tools.selection_mode) {
            .box => ui_atlas.sprites[pixelart.atlas.sprites.box_selection_default],
            .pixel => ui_atlas.sprites[pixelart.atlas.sprites.pixel_selection_default],
            .color => ui_atlas.sprites[pixelart.atlas.sprites.color_selection_default],
        };

        const sprite = switch (tool) {
            .pointer => ui_atlas.sprites[pixelart.atlas.sprites.cursor_default],
            .pencil => ui_atlas.sprites[pixelart.atlas.sprites.pencil_default],
            .eraser => ui_atlas.sprites[pixelart.atlas.sprites.eraser_default],
            .bucket => ui_atlas.sprites[pixelart.atlas.sprites.bucket_default],
            .selection => selection_sprite,
        };

        const size: dvui.Size = dvui.imageSize(ui_atlas.source) catch .{ .w = 1, .h = 1 };
        const atlas_w = if (size.w > 0) size.w else 1;
        const atlas_h = if (size.h > 0) size.h else 1;
        const uv = dvui.Rect{
            .x = @as(f32, @floatFromInt(sprite.source[0])) / atlas_w,
            .y = @as(f32, @floatFromInt(sprite.source[1])) / atlas_h,
            .w = @as(f32, @floatFromInt(sprite.source[2])) / atlas_w,
            .h = @as(f32, @floatFromInt(sprite.source[3])) / atlas_h,
        };

        button.processEvents();
        button.drawBackground();

        var rs = button.data().contentRectScale();
        const sw = @as(f32, @floatFromInt(sprite.source[2])) * rs.s;
        const sh = @as(f32, @floatFromInt(sprite.source[3])) * rs.s;
        rs.r.x += (rs.r.w - sw) / 2.0;
        rs.r.y += (rs.r.h - sh) / 2.0;
        rs.r.w = sw;
        rs.r.h = sh;

        dvui.renderImage(ui_atlas.source, rs, .{
            .uv = uv,
            .fade = 0.0,
        }) catch {
            std.log.err("Failed to render image", .{});
        };
        angle += step;

        if (button.hovered()) {
            Globals.state.tools.set(tool);
        }
        if (button.clicked()) {
            Globals.state.tools.set(tool);
            Globals.state.tools.radial_menu.close();
        }

        button.deinit();
    }

    var anim = dvui.animate(@src(), .{ .duration = 100_000, .kind = .alpha, .easing = dvui.easing.linear }, .{
        .id_extra = tool_count + 1,
    });
    defer anim.deinit();

    var rect = dvui.Rect.fromPoint(center);
    rect.w = 40.0;
    rect.h = 40.0;
    rect.x -= rect.w / 2.0;
    rect.y -= rect.h / 2.0;

    if (Globals.state.host.activeDoc()) |doc| {
        if (Globals.state.docs.fileById(doc.id)) |file| {
            if (dvui.buttonIcon(@src(), "Play", if (file.editor.playing) icons.tvg.entypo.pause else icons.tvg.entypo.play, .{}, .{}, .{
                .expand = .none,
                .corner_radius = dvui.Rect.all(1000),
                .box_shadow = .{
                    .color = .black,
                    .offset = .{ .x = -2.5, .y = 2.5 },
                    .fade = 4.0,
                    .alpha = 0.25,
                    .corner_radius = dvui.Rect.all(1000),
                },
                .color_fill = dvui.themeGet().color(.control, .fill_hover),
                .rect = rect,
            })) {
                file.editor.playing = !file.editor.playing;
                if (Globals.state.tools.radial_menu.opened_by_press) {
                    Globals.state.tools.radial_menu.close();
                }
            }
        }
    }
}
