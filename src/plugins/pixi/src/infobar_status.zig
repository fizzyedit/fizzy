//! Active-document infobar status (path, dimensions, cursor) for the shell infobar.
const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const pixi_mod = @import("../pixi.zig");
const runtime = @import("runtime.zig");
const State = pixi_mod.State;
const Internal = pixi_mod.internal;
const DocHandle = pixi_mod.sdk.DocHandle;
const DimensionsLabel = @import("dialogs/dimensions_label.zig");

fn docFile(st: *State, doc: DocHandle) ?*Internal.File {
    return st.docs.fileById(doc.id);
}

pub fn drawDocumentInfobar(st: *State, doc: DocHandle) !void {
    const file = docFile(st, doc) orelse return;
    const font = dvui.Font.theme(.body).larger(-1.0);
    const font_mono = dvui.Font.theme(.mono);

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

    DimensionsLabel.drawDimensionsLabel(@src(), file.width(), file.height(), font_mono, "px", .{ .gravity_y = 0.5, .margin = .{ .x = 4 } });

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12 } });

    dvui.icon(
        @src(),
        "sprite_icon",
        dvui.entypo.grid,
        .{ .fill_color = dvui.themeGet().color(.window, .text) },
        .{ .gravity_y = 0.5 },
    );

    DimensionsLabel.drawDimensionsLabel(@src(), file.column_width, file.row_height, font_mono, "px", .{ .gravity_y = 0.5, .margin = .{ .x = 4 } });

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
        dvui.label(
            @src(),
            "{d:0.0},{d:0.0} - {d:0.0},{d:0.0}",
            .{
                @floor(data_pt.x),
                @floor(data_pt.y),
                @floor(sprite_pt.x / @as(f32, @floatFromInt(file.column_width))),
                @floor(sprite_pt.y / @as(f32, @floatFromInt(file.row_height))),
            },
            .{ .gravity_y = 0.5, .font = font_mono },
        );
    }
}
