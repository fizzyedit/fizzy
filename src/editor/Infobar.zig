const std = @import("std");
const pixi = @import("../pixi.zig");
const dvui = @import("dvui");
const icons = @import("icons");
const Dialogs = pixi.Editor.Dialogs;

pub const Infobar = @This();

pub fn init() !Infobar {
    return .{};
}

pub fn deinit() void {
    // TODO: Free memory
}

pub fn draw(_: Infobar) !void {
    const font = dvui.Font.theme(.body).larger(-1.0);
    const font_mono = dvui.Font.theme(.mono).larger(-3.0);

    var scrollarea = dvui.scrollArea(@src(), .{}, .{
        .expand = .horizontal,
        .background = false,
        .color_fill = dvui.themeGet().color(.control, .fill),
        .gravity_y = 1.0,
        .padding = .all(0),
        .margin = .all(0),
    });
    defer scrollarea.deinit();
    var infobox = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = false,
        .padding = .all(0),
        .margin = .all(0),
    });
    defer infobox.deinit();

    {
        var button: dvui.ButtonWidget = undefined;
        button.init(@src(), .{}, .{ .gravity_y = 0.5, .margin = .all(0), .padding = .all(0) });
        defer button.deinit();
        button.processEvents();
        button.drawBackground();

        var box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .all(0), .padding = .all(0) });
        defer box.deinit();

        dvui.icon(
            @src(),
            "info_icon",
            icons.tvg.entypo.@"info-circled",
            .{ .fill_color = dvui.themeGet().color(.window, .text) },
            .{ .gravity_y = 0.5, .padding = .{
                .x = 4,
            } },
        );
        dvui.label(@src(), "Pixi", .{}, .{ .font = font, .gravity_y = 0.5, .margin = .all(0) });

        if (button.clicked()) {
            Dialogs.AboutPixi.request();
        }
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12 } });

    if (pixi.editor.folder) |folder| {
        dvui.icon(
            @src(),
            "project_icon",
            icons.tvg.entypo.folder,
            .{ .stroke_color = dvui.themeGet().color(.window, .text), .fill_color = dvui.themeGet().color(.window, .text) },
            .{ .gravity_y = 0.5 },
        );
        dvui.label(@src(), "{s}", .{std.fs.path.basename(folder)}, .{ .font = font, .gravity_y = 0.5 });
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12 } });

    if (pixi.editor.activeFile()) |file| {
        dvui.icon(
            @src(),
            "file_icon",
            icons.tvg.lucide.file,
            .{ .stroke_color = dvui.themeGet().color(.window, .text) },
            .{ .gravity_y = 0.5 },
        );
        dvui.label(@src(), "{s}", .{std.fs.path.basename(file.path)}, .{ .font = font, .gravity_y = 0.5 });

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12 } });

        dvui.icon(
            @src(),
            "width_icon",
            icons.tvg.lucide.@"ruler-dimension-line",
            .{ .stroke_color = dvui.themeGet().color(.window, .text) },
            .{ .gravity_y = 0.5 },
        );

        pixi.Editor.Dialogs.drawDimensionsLabel(@src(), file.width(), file.height(), font_mono, "px", .{ .gravity_y = 0.5, .margin = .{ .x = 4 } });

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12 } });

        dvui.icon(
            @src(),
            "sprite_icon",
            dvui.entypo.grid,
            .{ .fill_color = dvui.themeGet().color(.window, .text) },
            .{ .gravity_y = 0.5 },
        );

        pixi.Editor.Dialogs.drawDimensionsLabel(@src(), file.column_width, file.row_height, font_mono, "px", .{ .gravity_y = 0.5, .margin = .{ .x = 4 } });

        //dvui.label(@src(), "{d}x{d} - {d}x{d}", .{ file.width(), file.height(), file.column_width, file.row_height }, .{ .font = font, .gravity_y = 0.5 });

        const mouse_pt = dvui.currentWindow().mouse_pt;
        const data_pt = file.editor.canvas.dataFromScreenPoint(mouse_pt);

        const file_rect = dvui.Rect.fromSize(.{ .w = @floatFromInt(file.width()), .h = @floatFromInt(file.height()) });

        if (file_rect.contains(data_pt)) {
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12 } });

            dvui.icon(
                @src(),
                "mouse_icon",
                icons.tvg.lucide.@"mouse-pointer",
                .{ .stroke_color = dvui.themeGet().color(.window, .text) },
                .{ .gravity_y = 0.5 },
            );

            const sprite_pt = file.spritePoint(data_pt);
            dvui.label(@src(), "{d:0.0},{d:0.0} - {d:0.0},{d:0.0}", .{ @floor(data_pt.x), @floor(data_pt.y), @floor(sprite_pt.x / @as(f32, @floatFromInt(file.column_width))), @floor(sprite_pt.y / @as(f32, @floatFromInt(file.row_height))) }, .{ .gravity_y = 0.5, .font = font_mono });
        }
    }
}
