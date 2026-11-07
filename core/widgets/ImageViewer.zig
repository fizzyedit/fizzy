//! A picture shown on its own over the content it was tapped in: an `ImageView` filling the rect
//! it is given, on the theme's window fill, with a close bubble at the top right. It fades in and
//! out, closes on Esc, and takes every tap over its rect while it shows.
//!
//!     viewer: core.widgets.ImageViewer = .{},
//!
//!     if (thumbnail_tapped) state.viewer.open(.{ .source = src, .width = w, .height = h });
//!     // ... the rest of the frame ...
//!     try state.viewer.draw(content_rect, .{ .pan_zoom_scheme = scheme });
//!
//!     state.viewer.deinit();
//!
//! Draw it last in the frame: its floating widget is a subwindow above what was drawn before it,
//! and it takes the Esc nothing else did.
const ImageViewer = @This();

const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const motion = @import("glass").motion;
const ImageView = @import("ImageView.zig");
const glass_button = @import("glass_button.zig");

view: ImageView = .{},
/// What shows; null when closed. The caller owns its pixels and keeps them alive while open.
image: ?ImageView.Image = null,
/// Fading out: `image` is dropped when the fade ends.
closing: bool = false,
/// `open` or `close` asked for a fade the next `draw` starts (they may run outside a frame).
fade_pending: bool = false,

const fade_us = 180_000;
const fade_key = "image_viewer_fade";
const backdrop_opacity = 0.92;
const close_inset: f32 = 10;
/// The smallest close bubble drawn, in points.
const close_min_size: f32 = 24;

/// Shows `image`, fitted to the rect until the person moves it.
pub fn open(self: *ImageViewer, image: ImageView.Image) void {
    self.image = image;
    self.closing = false;
    self.fade_pending = true;
    self.view.canvas = .{ .id = self.view.canvas.id };
}

pub fn isOpen(self: *const ImageViewer) bool {
    return self.image != null;
}

/// Starts the fade out; `isOpen` turns false when it ends.
pub fn close(self: *ImageViewer) void {
    if (self.image == null or self.closing) return;
    self.closing = true;
    self.fade_pending = true;
}

/// Draws the viewer over `rect` (natural, the caller's content) when open.
pub fn draw(self: *ImageViewer, rect: dvui.Rect.Natural, opts: ImageView.Options) !void {
    const image = self.image orelse return;

    // Keyed by the state's address, so two viewers under one parent keep their own subwindow,
    // fade and canvas. State that moves starts its fade over.
    var fw: dvui.FloatingWidget = undefined;
    fw.init(@src(), .{}, .{ .rect = .cast(rect), .expand = .none, .background = false, .id_extra = @intFromPtr(self) });
    defer fw.deinit();
    const id = fw.data().id;
    // A floating widget clips to the window; what the viewer draws stays in its rect.
    const prev_clip = dvui.clip(fw.data().rectScale().r);
    defer dvui.clipSet(prev_clip);

    if (self.fade_pending) {
        self.fade_pending = false;
        // From wherever a fade under way has got to, so a close mid-open turns back smoothly.
        const from: f32 = if (dvui.animationGet(id, fade_key)) |a| a.value() else if (self.closing) 1 else 0;
        dvui.animation(id, fade_key, .{ .start_val = from, .end_val = if (self.closing) 0 else 1, .end_time = motion.duration(fade_us) });
    }
    const fade = dvui.animationGet(id, fade_key);
    const shown: f32 = if (fade) |a| std.math.clamp(a.value(), 0, 1) else if (self.closing) 0 else 1;
    if (self.closing and (fade == null or fade.?.done())) {
        self.image = null;
        self.closing = false;
        return;
    }

    const prev_alpha = dvui.alpha(shown);
    defer dvui.alphaSet(prev_alpha);

    fw.data().rectScale().r.fill(.all(0), .{ .color = .{ .color = dvui.themeGet().color(.window, .fill).opacity(backdrop_opacity) }, .fade = 0 });

    self.view.canvas.id = id.update("canvas");
    try self.view.draw(image, .{ .pan_zoom_scheme = opts.pan_zoom_scheme, .fit_button = true });

    // The bubble floats clipped only to the screen, so it is sized to stay inside the rect, and
    // left out where it would be too small to hit: Esc still closes.
    const pad = fw.data().options.paddingGet();
    const room = @min(rect.w - pad.x - pad.w, rect.h - pad.y - pad.h) - 2 * close_inset;
    const size = @min(glass_button.size, room);
    if (size >= close_min_size) {
        const close_rect: dvui.Rect = .{
            .x = rect.x + rect.w - pad.w - close_inset - size,
            .y = rect.y + pad.y + close_inset,
            .w = size,
            .h = size,
        };
        if (glass_button.bubble(@src(), close_rect, icons.tvg.lucide.x, .{ .label = "Close" })) self.close();
    }

    // Drawn last, so an Esc still unhandled here was wanted by nothing under it.
    for (dvui.events()) |*e| {
        if (e.handled or e.evt != .key) continue;
        const key = e.evt.key;
        if (key.action != .down or key.code != .escape) continue;
        e.handle(@src(), fw.data());
        self.close();
    }
}

/// Ends the view's canvas and frees its checkerboard.
pub fn deinit(self: *ImageViewer) void {
    self.view.deinit();
}
