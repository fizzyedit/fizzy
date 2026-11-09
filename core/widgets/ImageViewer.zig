//! A picture shown on its own over the content it was tapped in: an `ImageView` filling the rect
//! it is given, on the theme's window fill, with a close bubble at the top right. It fades in and
//! out with `open`, or grows from and back into a thumbnail with `openFrom`. It closes on Esc,
//! and takes every tap over its rect while it shows.
//!
//!     viewer: core.widgets.ImageViewer = .{},
//!
//!     if (thumbnail_tapped) state.viewer.openFrom(.{ .source = src, .width = w, .height = h }, thumbnail_rect);
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
const glass = @import("../glass.zig");
const motion = @import("glass").motion;
const ImageView = @import("ImageView.zig");
const glass_button = @import("glass_button.zig");

view: ImageView = .{},
/// What shows; null when closed. The caller owns its pixels and keeps them alive while open.
image: ?ImageView.Image = null,
/// Closing: `image` is dropped when the fade or growth ends.
closing: bool = false,
/// `open` or `close` asked for a fade the next `draw` starts (they may run outside a frame).
fade_pending: bool = false,
/// The tapped picture it grows out of and back into; null fades instead.
from: ?dvui.Rect.Natural = null,
/// The picture's box between `from` and the rect `draw` is given.
morph: glass.Morph = .{},
/// this frame's growth while a picture grows from `from`; null when it fades or is closed
growing: ?Grow = null,

const fade_us = 180_000;
const fade_key = "image_viewer_fade";
const backdrop_opacity = 0.92;
const close_inset: f32 = 10;
/// The smallest close bubble drawn, in points.
const close_min_size: f32 = 24;

/// Shows `image`, fitted to the rect until the person moves it.
pub fn open(self: *ImageViewer, image: ImageView.Image) void {
    self.openAt(image, null);
}

/// Shows `image`, growing from and closing back into `from` (natural coordinates).
pub fn openFrom(self: *ImageViewer, image: ImageView.Image, from: dvui.Rect.Natural) void {
    self.openAt(image, from);
}

fn openAt(self: *ImageViewer, image: ImageView.Image, from: ?dvui.Rect.Natural) void {
    if (self.image == null) self.morph = .{};
    // A reopen mid-close turns back from where it is and keeps growing if it was.
    self.from = from orelse if (self.image != null) self.from else null;
    self.image = image;
    self.closing = false;
    self.fade_pending = true;
    self.view.canvas = .{ .id = self.view.canvas.id };
}

pub fn isOpen(self: *const ImageViewer) bool {
    return self.image != null;
}

/// Starts closing; `isOpen` turns false when it ends.
pub fn close(self: *ImageViewer) void {
    if (self.image == null or self.closing) return;
    self.closing = true;
    self.fade_pending = true;
}

pub const Grow = struct {
    /// Where the picture is drawn.
    rect: dvui.Rect.Natural,
    /// Its grown share, 0..1.
    backdrop: f32,
    /// Whether the picture is still moving.
    moving: bool,
};

/// Steps the morph toward `rect`, or back to `from` while closing.
fn grow(self: *ImageViewer, from: dvui.Rect.Natural, rect: dvui.Rect.Natural) Grow {
    const scale = dvui.windowNaturalScale();
    if (!self.morph.started) self.morph.start(.{ .rect = from.scale(scale, dvui.Rect.Physical) });
    self.fade_pending = false;
    const target = if (self.closing) from else rect;
    const f = self.morph.step(.{ .rect = target.scale(scale, dvui.Rect.Physical) }, dvui.secondsSinceLastFrame(), scale, .{});
    if (f.moving) dvui.refresh(null, @src(), null);
    const now = f.box.rect.scale(1 / scale, dvui.Rect.Natural);
    const dw = rect.w - from.w;
    const dh = rect.h - from.h;
    const span = dw * dw + dh * dh;
    return .{ .rect = now, .backdrop = if (span == 0) 1 else std.math.clamp(((now.w - from.w) * dw + (now.h - from.h) * dh) / span, 0, 1), .moving = f.moving };
}

/// Draws the viewer over `rect` (natural, the caller's content) when open.
pub fn draw(self: *ImageViewer, rect: dvui.Rect.Natural, opts: ImageView.Options) !void {
    const image = self.image orelse return;

    self.growing = if (self.from) |from| self.grow(from, rect) else null;
    const growing = self.growing;
    if (self.closing and growing != null and !growing.?.moving) {
        self.image = null;
        self.growing = null;
        self.closing = false;
        return;
    }

    // Keyed by the state's address, so two viewers under one parent keep their own subwindow,
    // fade and canvas. State that moves starts its fade over.
    const over = if (growing) |g| rect.unionWith(g.rect) else rect;
    var fw: dvui.FloatingWidget = undefined;
    fw.init(@src(), .{}, .{ .rect = .cast(over), .expand = .none, .background = false, .id_extra = @intFromPtr(self) });
    defer fw.deinit();
    const id = fw.data().id;
    // A floating widget clips to the window; what the viewer draws stays in its rect.
    const prev_clip = dvui.clip(fw.data().rectScale().r);
    defer dvui.clipSet(prev_clip);

    if (growing == null) {
        if (self.fade_pending) {
            self.fade_pending = false;
            // From wherever a fade under way has got to, so a close mid-open turns back smoothly.
            const from: f32 = if (dvui.animationGet(id, fade_key)) |a| a.value() else if (self.closing) 1 else 0;
            dvui.animation(id, fade_key, .{ .start_val = from, .end_val = if (self.closing) 0 else 1, .end_time = motion.duration(fade_us) });
        }
        const fade = dvui.animationGet(id, fade_key);
        if (self.closing and (fade == null or fade.?.done())) {
            self.image = null;
            self.growing = null;
            self.closing = false;
            return;
        }
    }

    const shown: f32 = if (growing != null) 1 else if (dvui.animationGet(id, fade_key)) |a| std.math.clamp(a.value(), 0, 1) else 1;
    const prev_alpha = dvui.alpha(shown);
    defer dvui.alphaSet(prev_alpha);

    fw.data().rectScale().r.fill(.all(0), .{ .color = .{ .color = dvui.themeGet().color(.window, .fill).opacity(backdrop_opacity * if (growing) |g| g.backdrop else @as(f32, 1)) }, .fade = 0 });

    self.view.canvas.id = id.update("canvas");
    const picture = if (growing) |g| g.rect else rect;
    const box = dvui.box(@src(), .{}, .{ .rect = .{ .x = picture.x - over.x, .y = picture.y - over.y, .w = picture.w, .h = picture.h }, .expand = .none });
    defer box.deinit();
    try self.view.draw(image, .{ .pan_zoom_scheme = opts.pan_zoom_scheme, .fit_button = true });

    // The bubble floats clipped only to the screen, so it is sized to stay inside the rect, and
    // left out where it would be too small to hit: Esc still closes.
    const pad = fw.data().options.paddingGet();
    const room = @min(rect.w - pad.x - pad.w, rect.h - pad.y - pad.h) - 2 * close_inset;
    const size = @min(glass_button.size, room);
    if (size >= close_min_size and (growing == null or !growing.?.moving)) {
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
