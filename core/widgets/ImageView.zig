//! Read-only image viewer: zoom/pan canvas with checkerboard transparency background.
const ImageView = @This();

const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const CanvasWidget = @import("CanvasWidget.zig");
const glass_button = @import("glass_button.zig");
const gfx_image = @import("../gfx/image.zig");

/// The caller sets `canvas.id` before the first `draw`.
canvas: CanvasWidget = .{},
checkerboard_tile: ?dvui.Texture = null,

const checker_even: [4]u8 = .{ 255, 255, 255, 255 };
const checker_odd: [4]u8 = .{ 175, 175, 175, 255 };
const checker_tile_pixels: u32 = 8;
const checker_cells_per_axis: f32 = 8.0;

pub const Image = struct {
    source: dvui.ImageSource,
    width: u32,
    height: u32,
    /// Which frame of an animation `source` is: it only tells the Fit button what is under it.
    frame: usize = 0,
};

pub const Options = struct {
    pan_zoom_scheme: CanvasWidget.PanZoomScheme,
    fit_button: bool = true,
};

pub fn draw(self: *ImageView, image: Image, opts: Options) !void {
    const image_rect = dvui.Rect{
        .x = 0,
        .y = 0,
        .w = @floatFromInt(image.width),
        .h = @floatFromInt(image.height),
    };

    // The viewport is the pane it sits in: no fill of its own (the place card behind it is the
    // background, at the app's content opacity, the same as under pixi's canvas). Its edge
    // shadows are the canvas widget's own.

    const view = view: {
        self.canvas.install(@src(), .{
            .id = self.canvas.id,
            .data_size = .{ .w = image_rect.w, .h = image_rect.h },
            .pan_zoom_scheme = opts.pan_zoom_scheme,
        }, .{ .expand = .both, .background = false, .color_fill = .{ .color = .transparent } });
        defer self.canvas.deinit();

        drawShadow(&self.canvas, image_rect);
        drawFill(image_rect);
        try drawCheckerboard(self, image_rect);
        try drawImage(self, image);
        drawOutline(&self.canvas);
        self.canvas.processEvents();
        break :view self.canvas.scroll_container.data().contentRectScale().r.toNatural();
    };
    // Outside the canvas: a floating widget made inside it takes the canvas's zoom.
    if (opts.fit_button) drawFitButton(self, image, view);
}

/// Frees the checkerboard tile and ends a canvas left installed.
pub fn deinit(self: *ImageView) void {
    if (self.checkerboard_tile) |t| dvui.textureDestroyLater(t);
    self.checkerboard_tile = null;
    if (self.canvas.installed) self.canvas.deinit();
}

/// Fit to View as a glass bubble at the viewport's top left, where pixi keeps its canvas controls.
fn drawFitButton(self: *ImageView, image: Image, view: dvui.Rect.Natural) void {
    const margin: f32 = 10;
    const size = glass_button.size;
    if (view.w < size + 2 * margin or view.h < size + 2 * margin) return;
    // What is under it: the image, where it is and how big, and which of its frames shows.
    var under = std.hash.Wyhash.init(0);
    under.update(std.mem.asBytes(&.{ self.canvas.screen_rect_scale.r.x, self.canvas.screen_rect_scale.r.y, self.canvas.screen_rect_scale.s }));
    under.update(std.mem.asBytes(&.{ image.width, image.height, image.frame }));
    const rect: dvui.Rect = .{ .x = view.x + margin, .y = view.y + margin, .w = size, .h = size };
    if (glass_button.bubble(@src(), rect, icons.tvg.lucide.scan, .{ .label = "Fit to View", .witness_under = under.final() })) {
        self.canvas.fitToView();
    }
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

fn drawCheckerboard(self: *ImageView, data_rect: dvui.Rect) !void {
    const bg_screen = self.canvas.screenFromDataRect(data_rect);
    bg_screen.fill(.all(0), .{ .color = .{ .color = dvui.themeGet().color(.content, .fill) }, .fade = 1.5 });
    if (data_rect.w <= 0 or data_rect.h <= 0) return;
    // The cells scale with the image (`checker_cells_per_axis` across it), so the board stays
    // legible however far out the view goes; the only zoom at which drawing it is pointless is
    // one where a cell is narrower than a pixel and the texture can no longer show squares.
    if (data_rect.w * self.canvas.scale / checker_cells_per_axis < 1) return;

    if (self.checkerboard_tile == null) {
        self.checkerboard_tile = gfx_image.checkerboardTile(checker_tile_pixels, checker_tile_pixels, checker_even, checker_odd);
    }
    const tex = self.checkerboard_tile orelse return;

    const uv = gfx_image.checkerboardUvFixedCells(data_rect, checker_cells_per_axis) orelse return;

    try dvui.renderTexture(tex, .{ .r = bg_screen, .s = self.canvas.screen_rect_scale.s }, .{
        .colormod = dvui.themeGet().color(.content, .fill).lighten(6.0).opacity(0.5),
        .uv = uv,
    });
}

fn drawImage(self: *ImageView, image: Image) !void {
    try dvui.renderImage(image.source, .{
        .r = self.canvas.rect,
        .s = self.canvas.scale,
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
