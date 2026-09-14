//! Read-only image viewer: zoom/pan canvas with checkerboard transparency background.
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const sdk = @import("fizzy_sdk");
const Document = @import("Document.zig");

const CanvasWidget = core.widgets.CanvasWidget;

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

    // The viewport is the pane it sits in: no fill of its own (the place card behind it is the
    // background, at the app's content opacity, the same as under pixi's canvas), and the same
    // edge shadows pixi draws at the top and left, so the two viewers read as one.
    const container = dvui.parentGet().data();
    defer if (!dvui.firstFrame(container.id)) {
        core.draw.drawEdgeShadow(container.rectScale(), .top, .{});
        core.draw.drawEdgeShadow(container.rectScale(), .left, .{});
    };

    doc.canvas.install(@src(), .{
        .id = doc.canvas.id,
        .data_size = .{ .w = image_rect.w, .h = image_rect.h },
        .pan_zoom_scheme = canvasPanZoomScheme(),
    }, .{ .expand = .both, .background = false, .color_fill = .{ .color = .transparent } });
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
        .color_fill = .{ .color = dvui.themeGet().color(.window, .fill) },
    });
    fill_box.deinit();
}

fn drawCheckerboard(doc: *Document, data_rect: dvui.Rect) !void {
    const bg_screen = doc.canvas.screenFromDataRect(data_rect);
    bg_screen.fill(.all(0), .{ .color = .{ .color = dvui.themeGet().color(.content, .fill) }, .fade = 1.5 });
    if (data_rect.w <= 0 or data_rect.h <= 0) return;
    // The cells scale with the image (`checker_cells_per_axis` across it), so the board stays
    // legible however far out the view goes; the only zoom at which drawing it is pointless is
    // one where a cell is narrower than a pixel and the texture can no longer show squares.
    if (data_rect.w * doc.canvas.scale / checker_cells_per_axis < 1) return;

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

/// Step an animation to whichever frame is due, and arm a timer for the next one.
///
/// The timer is dvui's own: it wakes the window exactly when the frame's delay elapses, so an
/// idle viewer with a GIF open redraws at the GIF's rate and not at all otherwise. A frame
/// that is *overdue* (the window was hidden, a long frame) is not skipped ahead — the next one
/// simply shows now, which is what every browser does with a stalled GIF.
fn advanceAnimation(doc: *Document) void {
    const anim = &(doc.animation orelse return);
    const id = doc.canvas.id.update("gif frame");
    if (dvui.timerGet(id)) |remaining| {
        if (remaining > 0) return;
        doc.frame = (doc.frame + 1) % anim.frames.len;
        doc.source = anim.frames[doc.frame];
    }
    dvui.timer(id, @intCast(@as(u64, anim.delays_ms[doc.frame]) * std.time.us_per_ms));
}

fn drawImage(doc: *Document) !void {
    advanceAnimation(doc);
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
    } }, .{ .thickness = 1, .color = .{ .color = dvui.themeGet().color(.control, .fill_hover) }, .closed = true });
}

fn canvasPanZoomScheme() CanvasWidget.PanZoomScheme {
    return switch (sdk.host().panZoomScheme()) {
        .mouse => .mouse,
        .trackpad => .trackpad,
    };
}
