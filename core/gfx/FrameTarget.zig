//! The frame, drawn into a texture the size of the window and blitted to the window at the end.
//!
//! Exists for one reason: anything that wants "what is under me" — a frosted window, a
//! frosted palette, a region blurring under a drag — can then take it from a texture the GPU
//! already holds (`BlurBackdrop`'s target copy) instead of reading the framebuffer back through
//! the CPU. A readback is a GPU sync plus a copy in each direction: ~9 ms per frost in Debug,
//! and a pipeline stall on top, which is what dropped the frame rate with the palette open.
//! Drawing the frame to a target costs one full-window textured quad per frame.
//!
//! The window itself is not touched until `end`. dvui's backend clears the window at
//! `Window.begin`; the first render-target switch of the frame flushes that clear, and on Metal
//! the window's first draw is what acquires the swapchain drawable — at the very start of the
//! frame, which stalls the CPU until the GPU has finished an earlier frame and holds the whole
//! frame's work back from overlapping it. So the backend's clear is turned off (`init`) and the
//! blit writes the frame with a copy blend over whatever the drawable held; the drawable is
//! then acquired at the end of the frame, when the frame is ready, and the CPU and GPU pipeline.
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

/// Once, after the backend exists: stop it clearing the window each frame (see above). The
/// SDL backend is the only one that does; others have nothing to turn off.
pub fn init() void {
    const impl = dvui.currentWindow().backend.impl;
    if (@hasField(@TypeOf(impl.*), "clear_window_on_begin")) impl.clear_window_on_begin = false;
}

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
    // Written, not blended: the window was not cleared (see above), so the frame's own alpha
    // must land as it is — a see-through window blended over last frame's pixels would not be.
    // Where the backend cannot set a copy blend the window is still cleared and over is exact.
    const copy = if (dvui.Backend.support_texture_blend) blk: {
        cw.backend.textureBlend(tex, .copy) catch break :blk false;
        break :blk true;
    } else false;
    defer if (copy) cw.backend.textureBlend(tex, .over) catch {};
    dvui.renderTexture(tex, .{ .r = dvui.windowRectPixels(), .s = 1 }, .{}) catch {};
}

/// Drop the target. Only valid between `Window.begin` and `Window.end`.
pub fn deinit(self: *FrameTarget) void {
    if (self.target) |t| t.destroyLater();
    self.* = .{};
}
