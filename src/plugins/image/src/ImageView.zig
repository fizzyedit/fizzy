//! Read-only image viewer: zoom/pan canvas with checkerboard transparency background.
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const sdk = @import("fizzy_sdk");
const Document = @import("Document.zig");

const CanvasWidget = core.dvui.CanvasWidget;

const checker_even: [4]u8 = .{ 255, 255, 255, 255 };
const checker_odd: [4]u8 = .{ 175, 175, 175, 255 };
const checker_tile_pixels: u32 = 8;
const checker_cells_per_axis: f32 = 8.0;

pub fn draw(doc: *Document) !void {
    const image_rect = dvui.Rect{
        .x = 0,
        .y = 0,
        .w = @floatFromInt(doc.width),
        .h = @floatFromInt(doc.height),
    };

    doc.canvas.install(@src(), .{
        .id = doc.canvas.id,
        .data_size = .{ .w = image_rect.w, .h = image_rect.h },
        .pan_zoom_scheme = canvasPanZoomScheme(),
    }, .{ .expand = .both });
    defer doc.canvas.deinit();

    drawShadow(&doc.canvas, image_rect);
    drawFill(image_rect);
    try drawCheckerboard(doc, image_rect);
    try drawImage(doc);
    drawOutline(&doc.canvas);
    doc.canvas.processEvents();
}

fn drawShadow(canvas: *CanvasWidget, image_rect: dvui.Rect) void {
    const inv_scale = 1 / canvas.scale;
    const shadow_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .none,
        .rect = image_rect,
        .border = dvui.Rect.all(0),
        .box_shadow = .{
            .fade = 20 * inv_scale,
            .corners = dvui.CornerRect.all(2 * inv_scale),
            .alpha = if (dvui.themeGet().dark) 0.4 else 0.2,
            .offset = .{
                .x = 2 * inv_scale,
                .y = 2 * inv_scale,
            },
        },
    });
    shadow_box.deinit();
}

fn drawFill(image_rect: dvui.Rect) void {
    const fill_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .none,
        .rect = image_rect,
        .border = dvui.Rect.all(0),
        .background = true,
        .color_fill = dvui.themeGet().color(.window, .fill),
    });
    fill_box.deinit();
}

fn drawCheckerboard(doc: *Document, data_rect: dvui.Rect) !void {
    const bg_screen = doc.canvas.screenFromDataRect(data_rect);
    bg_screen.fill(.all(0), .{ .color = dvui.themeGet().color(.content, .fill), .fade = 1.5 });
    if (doc.canvas.scale < 0.1) return;
    if (data_rect.w <= 0 or data_rect.h <= 0) return;

    if (doc.checkerboard_tile == null) {
        doc.checkerboard_tile = core.image.checkerboardTile(checker_tile_pixels, checker_tile_pixels, checker_even, checker_odd);
    }
    const tex = doc.checkerboard_tile orelse return;

    const uv = core.image.checkerboardUvFixedCells(data_rect, checker_cells_per_axis) orelse return;

    try dvui.renderTexture(tex, .{ .r = bg_screen, .s = doc.canvas.screen_rect_scale.s }, .{
        .colormod = dvui.themeGet().color(.content, .fill).lighten(6.0).opacity(0.5),
        .uv = uv,
    });
}

fn drawImage(doc: *Document) !void {
    try dvui.renderImage(doc.source, .{
        .r = doc.canvas.rect,
        .s = doc.canvas.scale,
    }, .{});
}

fn drawOutline(canvas: *CanvasWidget) void {
    dvui.Path.stroke(.{ .points = &.{
        canvas.rect.topLeft(),
        canvas.rect.topRight(),
        canvas.rect.bottomRight(),
        canvas.rect.bottomLeft(),
    } }, .{ .thickness = 1, .color = dvui.themeGet().color(.control, .fill_hover), .closed = true });
}

fn canvasPanZoomScheme() CanvasWidget.PanZoomScheme {
    return switch (sdk.host().panZoomScheme()) {
        .mouse => .mouse,
        .trackpad => .trackpad,
    };
}
