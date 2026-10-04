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
const builtin = @import("builtin");
const dvui = @import("dvui");
const profile = @import("../profile.zig");

const FrameTarget = @This();

/// Two window-sized targets, drawn into in turn: the one not being drawn this frame still holds
/// the last frame, whole, for `snapshot`. Costs a second texture and no drawing.
targets: [2]?dvui.Texture.Target = .{ null, null },
/// Which of `targets` this frame draws into.
index: u1 = 0,
/// Whether each of `targets` holds the frame after the one before it — false once a frame has
/// been drawn straight to the window, so `snapshot` never hands back a stale picture.
fresh: [2]bool = .{ false, false },
/// Frames since anything last asked to read the frame (`want`).
unread: u32 = 0,
/// This frame's target (`targets[index]`), bound between `begin` and `end`.
target: ?dvui.Texture.Target = null,
bound: bool = false,

/// The frame target in use, for `snapshot`. One per image: set by the host's `begin`, so a
/// plugin image's copy stays null and asks the host (`Host`/`Editor`) instead.
var current: ?*FrameTarget = null;

/// Once, after the backend exists: stop it clearing the window each frame (see above). The
/// SDL backend is the only one that does; others have nothing to turn off.
pub fn init() void {
    const impl = dvui.currentWindow().backend.impl;
    if (@hasField(@TypeOf(impl.*), "clear_window_on_begin")) impl.clear_window_on_begin = false;
}

/// Only on the web, frames nothing reads are drawn straight to the window. A phone's GPU tiles:
/// every frame drawn into a window-sized texture is written out whole and read back whole for
/// the blit — ~30 MB a frame at a phone's resolution, for a home screen with no glass on it.
/// Natively the target stays: on Metal it is also what defers acquiring the drawable to the
/// end of the frame (see above), and the desktop GPU does not notice the copy.
const skip_unread = builtin.target.cpu.arch == .wasm32;

/// Frames the target stays bound after the last `want`: a tooltip or menu opening and shutting
/// should not flip it on and off, and glass coming back finds it still there.
const linger_frames: u32 = 60;

const unseen_id: dvui.Id = @enumFromInt(0x6669_7a7a_756e_736e); // "fizzunsn"
const unseen_key = "_frame_unseen";

/// Mark the frame running as one nobody will see — a demo catching up (`automation.Player.frames`)
/// — or not. Only where the backend drops what such a frame draws to the window (an `unseen`
/// switch, the web's): elsewhere every frame draws, and none is marked. Through the shared dvui
/// window, so every image reads it (`unseen`), a plugin's glass as much as the host's. Returns
/// whether the frame is unseen now.
pub fn setUnseen(on: bool) bool {
    const cw = dvui.currentWindow();
    const impl = cw.backend.impl;
    if (!@hasField(@TypeOf(impl.*), "unseen")) return false;
    impl.unseen = on;
    if (on) dvui.dataSet(null, unseen_id, unseen_key, true) else dvui.dataRemove(null, unseen_id, unseen_key);
    return on;
}

/// The frame running is one nobody will see (`setUnseen`). What only a frame's picture needs can
/// be left out of it: the frame target here, a frost's capture (`BlurBackdrop`), a cross-fade's
/// (`anim.CrossFade`).
pub fn unseen() bool {
    if (dvui.current_window == null) return false;
    return dvui.dataGet(null, unseen_id, unseen_key, bool) orelse false;
}

const want_id: dvui.Id = @enumFromInt(0x6669_7a7a_6672_6d77); // "fizzfrmw"
const want_key = "_frame_target_wanted";

/// Something will read what is under it this frame (a frost, `BlurBackdrop`) — keep the frame in
/// a texture. Any image may call it: it goes through the shared dvui window, so a plugin's glass
/// counts as much as the host's. On a frame drawn straight to the window the read finds no
/// texture and draws no frost; the target is bound from the next frame on — a pane's first
/// frame, which every glass surface fades in from.
pub fn want() void {
    if (dvui.current_window == null) return;
    dvui.dataSet(null, want_id, want_key, true);
}

/// Fizzy addition: a part of the window another window stands over and shows instead, this frame
/// — a float out of the main window lying over it (fizzy's `Popout`). Cleared to nothing once the
/// frame has replayed (`end`), so behind the other window there is what is behind this one where
/// it is see-through: its material, the desktop blurred. The other window's glass is made as
/// see-through as what it reads and shows that through itself, as a float in this window does.
/// Left drawn, it showed this window's own picture there, blurred again by the other window's
/// material — the glass came out more opaque than in this window. Rounded with `corners` (natural
/// units, at `scale`; resolved against the theme — a theme corner unresolved cuts square). Only on
/// a frame drawn into a target: straight to the window, nothing is cut.
pub fn hole(r: dvui.Rect.Physical, corners: dvui.CornerRect, scale: f32) void {
    if (hole_count == holes.len) return;
    holes[hole_count] = .{ .r = r, .corners = corners, .scale = scale };
    hole_count += 1;
}

const Hole = struct { r: dvui.Rect.Physical, corners: dvui.CornerRect, scale: f32 };
var holes: [4]Hole = undefined;
var hole_count: usize = 0;
/// What a hole is drawn with: written with a copy blend, under a clear colour, so it lands as
/// nothing (`clearHoles`).
var hole_tex: ?dvui.Texture = null;

fn clearHoles() void {
    defer hole_count = 0;
    if (hole_count == 0 or !dvui.Backend.support_texture_blend) return;
    if (hole_tex == null) {
        const px = [1]dvui.Color.PMA{.{ .r = 255, .g = 255, .b = 255, .a = 255 }};
        hole_tex = dvui.textureCreate(&px, .{ .width = 1, .height = 1, .interpolation = .nearest }) catch return;
    }
    const tex = hole_tex.?;
    const cw = dvui.currentWindow();
    cw.backend.textureBlend(tex, .copy) catch return;
    defer cw.backend.textureBlend(tex, .over) catch {};
    const prev_rendering = dvui.renderingSet(true);
    defer _ = dvui.renderingSet(prev_rendering);
    const prev_clip = dvui.clipGet();
    defer dvui.clipSet(prev_clip);
    dvui.clipSet(dvui.windowRectPixels());
    const prev_alpha = dvui.alpha(1);
    defer dvui.alphaSet(prev_alpha);
    for (holes[0..hole_count]) |h| {
        dvui.renderTexture(tex, .{ .r = h.r, .s = h.scale }, .{ .corners = h.corners, .colormod = .{ .r = 0, .g = 0, .b = 0, .a = 0 } }) catch {};
    }
}

/// Bind a window-sized target, made fresh when the window's pixel size changes.
pub fn begin(self: *FrameTarget) void {
    if (unseen()) {
        // Straight to the window, where the backend drops it, and neither target touched: they
        // keep the last frame that was shown, for the next one shown to read. A want stays for
        // that frame too — read, not taken: data no frame reads is dropped at its end.
        if (skip_unread) _ = dvui.dataGet(null, want_id, want_key, bool);
        self.target = null;
        current = self;
        return;
    }
    if (skip_unread) {
        const wanted = dvui.dataGet(null, want_id, want_key, bool) orelse false;
        dvui.dataRemove(null, want_id, want_key);
        self.unread = if (wanted) 0 else self.unread +| 1;
        if (self.unread > linger_frames) {
            // Straight to the window (the web backend clears it every frame itself).
            self.index +%= 1;
            self.fresh[self.index] = false;
            self.target = null;
            current = self;
            return;
        }
    }
    const win = dvui.windowRectPixels();
    const w: u32 = @intFromFloat(@max(1, @round(win.w)));
    const h: u32 = @intFromFloat(@max(1, @round(win.h)));
    // A resize makes both stale: last frame's is the wrong size to be read as this one's.
    for (&self.targets) |*slot| if (slot.*) |t| {
        if (t.width != w or t.height != h) {
            t.destroyLater();
            slot.* = null;
        }
    };
    self.index +%= 1;
    if (self.targets[self.index] == null) {
        self.targets[self.index] = dvui.textureCreateTarget(.{ .width = w, .height = h, .interpolation = .nearest }) catch return;
    }
    self.target = self.targets[self.index];
    self.fresh[self.index] = true;
    current = self;
    const t = self.target.?;
    // `create` clears once; every frame after starts from what the last one left.
    {
        const prof = profile.begin("fizzy", "clear");
        defer prof.end();
        t.clear();
    }
    const prof_bind = profile.begin("fizzy", "bind");
    defer prof_bind.end();
    var rt = dvui.currentWindow().render_target;
    rt.texture = t;
    rt.offset = .{};
    _ = dvui.renderTarget(rt);
    self.bound = true;
}

/// Finish dvui's rendering into the target, then draw the target over the window.
pub fn end(self: *FrameTarget) void {
    if (!self.bound) {
        hole_count = 0;
        return;
    }
    self.bound = false;
    const cw = dvui.currentWindow();
    // Deferred subwindows and toasts render here, still into the target. `Window.end` sees
    // this was done and does not do it again.
    {
        const prof = profile.begin("fizzy", "deferred subwindows (floating windows, dialogs)");
        defer prof.end();
        cw.endRendering(.{});
    }
    // Then what other windows show instead, everything under them drawn (`hole`).
    clearHoles();

    {
        // On Metal the window's first draw of the frame acquires its drawable: this waits here
        // when the GPU is still behind on earlier frames.
        const prof = profile.begin("fizzy", "bind the window");
        defer prof.end();
        var rt = cw.render_target;
        rt.texture = null;
        rt.offset = .{};
        _ = dvui.renderTarget(rt);
    }
    const prof_blit = profile.begin("fizzy", "blit");
    defer prof_blit.end();

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

/// This frame's picture as drawn so far — everything drawn straight into it, before `end` replays
/// the deferred subwindows — as a texture to draw from, while the frame target is bound; null
/// otherwise. What a popped-out float's window puts behind its glass where the main window lies
/// under it, so the glass frosts there what it frosts in the main window (`Popout.behindGlass`).
pub fn frameTexture() ?dvui.Texture {
    const self = current orelse return null;
    if (!self.bound) return null;
    const t = self.target orelse return null;
    return dvui.Texture.fromTargetTemp(t) catch null;
}

/// Drop the targets. Only valid between `Window.begin` and `Window.end`.
pub fn deinit(self: *FrameTarget) void {
    for (self.targets) |slot| if (slot) |t| t.destroyLater();
    if (current == self) current = null;
    self.* = .{};
}

/// `rect` (window pixels) as the last frame drew it, copied into a texture the caller owns
/// (`dvui.textureDestroyLater` it). What a pane showed a moment ago, after what it showed has
/// gone: a document closing can unload at once and its pane still slide shut over the picture
/// of it. Null before a frame has been drawn, off the window, or on a backend without targets.
pub fn snapshot(rect: dvui.Rect.Physical) ?dvui.Texture {
    const self = current orelse return null;
    // The last frame shown: the other target while one is bound; in a frame nobody will see, the
    // one bound last (`begin` leaves the targets as they were).
    const last = if (self.bound) self.index +% 1 else if (unseen()) self.index else return null;
    if (!self.fresh[last]) return null;
    const prev = self.targets[last] orelse return null;
    const r = rect.intersect(dvui.windowRectPixels());
    if (r.w < 1 or r.h < 1) return null;
    const w: u32 = @intFromFloat(@round(r.w));
    const h: u32 = @intFromFloat(@round(r.h));
    const src = dvui.Texture.fromTargetTemp(prev) catch return null;
    const out = dvui.textureCreateTarget(.{ .width = w, .height = h, .interpolation = .linear }) catch return null;

    const prev_rendering = dvui.renderingSet(true);
    defer _ = dvui.renderingSet(prev_rendering);
    const prev_alpha = dvui.alpha(1);
    defer dvui.alphaSet(prev_alpha);
    var rt = dvui.currentWindow().render_target;
    rt.texture = out;
    rt.offset = .{};
    const was = dvui.renderTarget(rt);
    {
        const prev_clip = dvui.clipGet();
        defer dvui.clipSet(prev_clip);
        const dest: dvui.Rect.Physical = .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
        dvui.clipSet(dest);
        const sw: f32 = @floatFromInt(src.width);
        const sh: f32 = @floatFromInt(src.height);
        const copy = if (dvui.Backend.support_texture_blend) blk: {
            dvui.currentWindow().backend.textureBlend(src, .copy) catch break :blk false;
            break :blk true;
        } else false;
        defer if (copy) dvui.currentWindow().backend.textureBlend(src, .over) catch {};
        dvui.renderTexture(src, .{ .r = dest, .s = 1 }, .{ .uv = .{ .x = r.x / sw, .y = r.y / sh, .w = r.w / sw, .h = r.h / sh } }) catch {};
    }
    _ = dvui.renderTarget(was);
    return dvui.textureFromTarget(out) catch null;
}
