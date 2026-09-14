//! The frame, drawn into a texture the size of the window and blitted to the window at the end.
//!
//! Exists for one reason: anything that wants "what is under me" — a frosted window, a
//! frosted palette, a region blurring under a drag — can then take it from a texture the GPU
//! already holds (`BlurBackdrop`'s target copy) instead of reading the framebuffer back through
//! the CPU. A readback is a GPU sync plus a copy in each direction: ~9 ms per frost in Debug,
//! and a pipeline stall on top, which is what dropped the frame rate with the palette open.
//! Drawing the frame to a target costs one full-window textured quad per frame.
//!
//! Wraps the app's frame function: `begin` after `Window.begin`, `end` before `Window.end`.
//! `end` runs dvui's own end-of-frame rendering (the deferred subwindows: floating windows,
//! dialogs, the palette) so those land in the target too, then unbinds it and draws it. On a
//! backend without render targets neither does anything and the frame draws as before.
const std = @import("std");
const dvui = @import("dvui");

const FrameTarget = @This();

target: ?dvui.Texture.Target = null,
bound: bool = false,

/// Bind a window-sized target, made fresh when the window's pixel size changes.
pub fn begin(self: *FrameTarget) void {
    const win = dvui.windowRectPixels();
    const w: u32 = @intFromFloat(@max(1, @round(win.w)));
    const h: u32 = @intFromFloat(@max(1, @round(win.h)));
    if (self.target) |t| {
        if (t.width != w or t.height != h) {
            t.destroyLater();
            self.target = null;
        }
    }
    if (self.target == null) {
        self.target = dvui.textureCreateTarget(.{ .width = w, .height = h, .interpolation = .nearest }) catch return;
    }
    const t = self.target.?;
    // `create` clears once; every frame after starts from what the last one left.
    t.clear();
    var rt = dvui.currentWindow().render_target;
    rt.texture = t;
    rt.offset = .{};
    _ = dvui.renderTarget(rt);
    self.bound = true;
}

/// Finish dvui's rendering into the target, then draw the target over the window.
pub fn end(self: *FrameTarget) void {
    if (!self.bound) return;
    self.bound = false;
    const cw = dvui.currentWindow();
    // Deferred subwindows and toasts render here, still into the target. `Window.end` sees
    // this was done and does not do it again.
    cw.endRendering(.{});

    var rt = cw.render_target;
    rt.texture = null;
    rt.offset = .{};
    _ = dvui.renderTarget(rt);

    const tex = dvui.Texture.fromTargetTemp(self.target.?) catch return;
    const prev_rendering = dvui.renderingSet(true);
    defer _ = dvui.renderingSet(prev_rendering);
    const prev_clip = dvui.clipGet();
    defer dvui.clipSet(prev_clip);
    dvui.clipSet(dvui.windowRectPixels());
    const prev_alpha = dvui.alpha(1);
    defer dvui.alphaSet(prev_alpha);
    // The window was cleared to transparent by the backend, so drawing the (premultiplied)
    // frame over it reproduces exactly what drawing straight to the window would have.
    dvui.renderTexture(tex, .{ .r = dvui.windowRectPixels(), .s = 1 }, .{}) catch {};
}

/// Drop the target. Only valid between `Window.begin` and `Window.end`.
pub fn deinit(self: *FrameTarget) void {
    if (self.target) |t| t.destroyLater();
    self.* = .{};
}
