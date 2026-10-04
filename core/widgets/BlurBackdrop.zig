//! Cached, downsampled "blurred backdrop" for content behind modals, floating
//! windows, or transparent bars (e.g. a nav bar over scrolling content).
//! Approximates CSS `backdrop-filter: blur(radius_px)` using a dual-Kawase
//! blur (the cheap wide-blur trick browsers/game engines use): repeated
//! halving down, then repeated doubling back up, with a multi-tap offset
//! blend at every pass.
//!
//! Unlike a live per-frame blur, this only re-captures the background when
//! it actually changed - every other frame it just redraws a small cached
//! texture (one cheap textured quad). This matters because dvui's renderer
//! is deferred: replaying a subwindow's `RenderCommand`s re-runs real glyph
//! shaping / path triangulation, not just a GPU blit, so doing it every
//! frame is a real (avoidable) CPU cost.
//!
//! Usage (bracket the background content you want blurred):
//! ```
//! const blur = dvui.BlurBackdrop.get(@src());
//! blur.init(rect, .{scroll_offset, window_w}); // witness: anything that should invalidate the cache when it changes
//! // ... draw background widgets (scroll area, page content, etc) ...
//! blur.deinit();
//! blur.draw(); // draws cached blurred texture over `rect`
//! // ... draw modal / nav bar contents on top ...
//! ```
//!
//! Cache invalidation is automatic for anything captured in `rect` and
//! `witness` (hashed and compared to the previous frame's). Call
//! `markDirty()` yourself only for changes that hash can't see, e.g. the
//! background content itself changed shape/content without `rect` or
//! `witness` changing.

const std = @import("std");
const dvui = @import("dvui");
const motion = @import("../motion.zig");
const liquid_glass = @import("../gfx/liquid_glass.zig");
const LiquidField = @import("../gfx/LiquidField.zig");
const FrameTarget = @import("../gfx/FrameTarget.zig");

const Rect = dvui.Rect;
const Size = dvui.Size;
const Texture = dvui.Texture;

const BlurBackdrop = @This();

/// Physical-pixel rect this backdrop covers. Set by `init`.
rect: Rect.Physical = .{},
/// Fizzy addition: the physical pixels the last capture actually copied — `rect` snapped to whole
/// pixels, less a pixel lost to halving an odd size. `small` and `sharpTexture` are pictures of
/// exactly this; map texture coordinates through it (`coverage`), not `rect`, or the picture
/// sits up to a pixel off, and slides by a different fraction every time the pane moves.
covered: Rect.Physical = .{},
/// CSS `backdrop-filter: blur(radius_px)`-equivalent blur strength.
radius_px: f32 = 16,
/// Cached small texture, redrawn as-is on non-dirty frames. A view of the pyramid's last
/// level (`levels`), so it lives and dies with that.
small: ?Texture = null,
/// Fizzy addition: the pyramid's targets, kept from one capture to the next and reused when
/// the size still fits. Creating a target is a texture allocation plus a clear — a render-target
/// switch and a pipeline flush — and a capture needs a dozen; that was most of what a capture
/// cost, and why one could not be afforded every frame. Slot 0 is the copy of the rect, then
/// the halvings, then the doublings.
levels: [max_levels]?Texture.Target = @splat(null),
/// True until the next `deinit` runs a real capture.
dirty: bool = true,
/// Hash of the last `init`'s `rect` + `witness`, for auto-dirty.
last_hash: u64 = 0,

cmd_start: usize = undefined,
prev_rendering: bool = undefined,
/// Fizzy addition: how the backdrop gets the pixels under it. `.replay` is upstream's — defer
/// the bracketed draws and replay them into a capture target. `.readback` reads the rectangle
/// back from the window after the bracketed draws have landed there (`Backend.readPixels`),
/// which needs no cooperation from anything drawn inside the bracket — a `Picture` capture, a
/// front-to-back region, a plugin drawing through a bridge — where the replay repeats commands
/// that were only meant to run once. Costs a GPU→CPU→GPU round trip of the rect on dirty frames.
mode: Mode = .replay,
/// Fizzy addition: blur without the pyramid (`runFine`), for a frost whose content moves under
/// it — a canvas zooming — where the pyramid's coarse levels, on a grid fixed to the screen,
/// shimmer. Any radius: a big one is box-averaged down first, which stays put as content slides
/// under it. Off, the pyramid serves every radius (the cheap default — dialogs, menus, the
/// palette).
stable: bool = false,
/// Fizzy addition: how much definition the frost keeps, 0…1. On the way back up the pyramid,
/// each doubling mixes in the downsample level of its size by this much — a blur with a
/// sharper core and the same soft reach, so shapes behind read through the frost instead of
/// washing out. 0 is the plain dual-Kawase blur. Never the unblurred source: at most it
/// softens toward the first halving, so there is no sharp double image.
detail: f32 = 0,
/// Fizzy addition: how formed the frost is, 0 (the scene, sharp) to 1 (the full blur). The
/// pyramid is always built for `radius_px`, so its levels keep their sizes and are reused; on the
/// way back up, the doubling at the blur forming has reached takes that downsample level in place
/// of the coarser blur above it (`runKawase`). Growing the radius instead gave every level a new
/// size each frame — new targets every frame a menu, a dialog or a drop was forming. The fine
/// blur (`stable`) does not form; give it a smaller radius.
form: f32 = 1,

pub const Mode = enum { replay, readback };

/// Fizzy addition: what lies behind one pane, given by whoever knows better than the target it is
/// drawn on — a float out of the main window (`fizzy`'s `Popout`), drawn on its own window's target
/// where its glass would read the window's clear margin, reads the main window's picture instead,
/// as it does in the main window. Set for the replay that draws the pane (`frostPane`); while it
/// is, the pane keyed `id` captures from `picture`, and every other pane from its target as ever.
pub const Behind = struct {
    /// The pane's key (`frostPane`'s `id`).
    id: dvui.Id,
    ctx: ?*anyopaque = null,
    /// What lies behind the pane over `rect` (physical, in the frame), and where in the frame that
    /// picture lies. Called with the pane's target bound, which it leaves bound. Null: the target.
    picture: *const fn (ctx: ?*anyopaque, rect: Rect.Physical) ?Picture,

    pub const Picture = struct {
        texture: Texture,
        origin: dvui.Point.Physical,
    };
};

/// See `Behind`.
pub var behind: ?Behind = null;
/// The pane capturing now (`FrostJob.draw`), for `behind` to know it.
var capturing: ?dvui.Id = null;

/// Enough for a 16k-pixel rect at radius 2^11, in both directions.
const max_levels = 24;

/// Get the persistent `BlurBackdrop` for this call site, creating it on
/// first call. Registers its GPU-texture teardown with dvui's data store so
/// the cached texture is freed automatically once this storage key stops
/// being touched (e.g. the tab/panel it lives in closes) - unlike a bare
/// `dataGetPtrDefault`, which would otherwise silently leak `self.small`.
///
/// Safe to call every frame, any time before `init`/`deinit` - in
/// particular, before other same-frame code needs to mutate fields on the
/// returned pointer (e.g. a slider bound to `&backdrop.radius_px`).
pub fn get(src: std.builtin.SourceLocation) *BlurBackdrop {
    const id = dvui.parentGet().extendId(src, 0);
    const self = dvui.dataGetPtrDefault(null, id, "blur_backdrop", BlurBackdrop, .{});
    dvui.dataSetDeinitFunction(null, id, "blur_backdrop", &releaseTexture);
    return self;
}

/// Force a re-capture on the next `init`/`deinit` bracket, for invalidation
/// that `init`'s rect/witness hash can't see (e.g. modal reopened,
/// background content changed shape without `rect` moving).
pub fn markDirty(self: *BlurBackdrop) void {
    self.dirty = true;
}

/// Call immediately before drawing the background content that should show
/// through the blur. `witness` is anything (a value or tuple) that should
/// invalidate the cache when it changes - e.g. scroll offset, window width.
/// Cheap and safe to call every frame even when not dirty. Per-frame
/// bracket-open; does not allocate or own any resources itself (see `get`
/// for the one-time setup and `releaseTexture` for GPU teardown).
pub fn init(self: *BlurBackdrop, rect: Rect, witness: anytype) void {
    self.rect = dvui.windowRectScale().rectToPhysical(rect);

    var hasher = dvui.fnv.init();
    hasher.update(std.mem.asBytes(&rect));
    hasher.update(std.mem.asBytes(&witness));
    const h = hasher.final();
    if (h != self.last_hash) self.dirty = true;
    self.last_hash = h;

    if (!self.dirty) return;
    // A frame nobody will see captures nothing; still dirty, the next one shown does.
    if (FrameTarget.unseen()) return;
    // Readback wants the content *on the target* when `deinit` runs, so it must not defer.
    if (self.mode == .readback) return;

    const cw = dvui.currentWindow();
    const sw = cw.subwindows.current() orelse &cw.subwindows.stack.items[0];
    self.cmd_start = sw.render_cmds.items.len;

    // Rendering defaults to immediate (draws straight to the current
    // target as each widget call happens), so without this the bracketed
    // draws below never get queued into `sw.render_cmds` and there's
    // nothing to replay into the offscreen texture. Force deferred mode
    // so we can replay the same commands twice below: once onscreen
    // (so the background stays visible) and once into the capture target.
    self.prev_rendering = dvui.renderingSet(false);
}

/// Call immediately after drawing the background content bracketed by
/// `init`. Re-captures + re-blurs only when dirty. Per-frame bracket-close -
/// call every frame, cheap when not dirty. Does not free the cached
/// texture; see `releaseTexture` for that.
pub fn deinit(self: *BlurBackdrop) void {
    if (!self.dirty) return;
    // As `init` left it: nothing deferred, nothing to capture.
    if (FrameTarget.unseen()) return;
    defer self.dirty = false;
    defer self.frostReplaces();
    if (self.mode == .readback) return self.deinitReadback();

    const cw = dvui.currentWindow();
    _ = dvui.renderingSet(self.prev_rendering);

    const sw = cw.subwindows.current() orelse &cw.subwindows.stack.items[0];
    // Left in the subwindow's normal queue (not stripped, not replayed here)
    // so they draw exactly once, in their natural queue order, via the
    // normal `Window.endRendering` deferred replay - same as any other
    // widget's deferred draws. Replaying them immediately here (as an
    // earlier version did) drew them "now" during build, which is fine at
    // top level but wrong when this widget is nested inside another
    // floating window: an enclosing background fill queued *earlier* in the
    // same subwindow only actually draws *later*, at `endRendering`, and
    // painted right over content already drawn early by an immediate
    // replay - the bracketed content (e.g. a checkerboard background)
    // vanishing behind the enclosing window every dirty frame.
    const cmds = sw.render_cmds.items[self.cmd_start..];

    var r = self.rect;
    if (r.empty()) return;
    // enlarge to pixel boundaries, same as Picture.start
    const x_start = @floor(r.x);
    const x_end = @ceil(r.x + r.w);
    r.x = x_start;
    r.w = @round(x_end - x_start);
    const y_start = @floor(r.y);
    const y_end = @ceil(r.y + r.h);
    r.y = y_start;
    r.h = @round(y_end - y_start);
    if (r.w < 1 or r.h < 1) return;
    r = within(r, dvui.windowRectPixels()) orelse return;

    // The rest of this function renders into offscreen targets (the full-res
    // capture, then each downsample/upsample pass) and must happen
    // immediately, not be deferred - `renderTexture` silently queues a
    // `RenderCommand` instead of drawing when `rendering` is false, which is
    // the ambient state whenever this whole widget is itself nested inside
    // another deferred floating window. Left alone, every blur pass would be
    // queued instead of drawn, its offscreen target would stay blank, and
    // `self.small` would end up fully transparent.
    const blur_prev_rendering = dvui.renderingSet(true);
    defer _ = dvui.renderingSet(blur_prev_rendering);

    // capture the bracketed commands at full res into an offscreen target.
    // Stays bound to offscreen targets for the whole downsample/upsample
    // pipeline below - restored to `prev1` (the real onscreen/window
    // target) exactly once at the end. Restoring it between passes (as a
    // naive save/restore per pass would) touches the live window target
    // once per blur pass for no reason, and on backends that clear-on-bind
    // that flashes away whatever was already drawn there - a visible
    // flicker every dirty frame (e.g. every tick while dragging the radius
    // slider).
    const full_target = dvui.textureCreateTarget(.{ .width = @intFromFloat(r.w), .height = @intFromFloat(r.h) }) catch return;
    const prev1 = dvui.renderTarget(.{ .texture = full_target, .offset = r.topLeft() });
    defer _ = dvui.renderTarget(prev1);
    cw.renderCommands(cmds) catch {};

    const cur = dvui.textureFromTarget(full_target) catch return; // destroys full_target
    defer dvui.textureDestroyLater(cur);
    // Capture target is already bound; the outer `defer` restores the window.
    _ = self.runKawase(cur, false, 1, 1);
}

/// Fizzy addition: the fast `.readback`. When the frame is being drawn into a texture
/// (`core.FrameTarget`, or any bound target — a `Picture` capture mid-transition), "what is
/// under me" is already on the GPU: copy `rect` out of it into a target of its own and blur
/// that. No sync, no CPU copy — ~1 ms in Debug against ~9 for the framebuffer read. False when
/// nothing is bound (the window itself is the target) and the read has to happen.
fn deinitFromTarget(self: *BlurBackdrop) bool {
    const cw = dvui.currentWindow();
    const bound = cw.render_target.texture orelse return false;
    var r = self.rect;
    if (r.empty()) return true;
    r.x = @floor(r.x);
    r.y = @floor(r.y);
    r.w = @round(r.w);
    r.h = @round(r.h);
    if (r.w < 1 or r.h < 1) return true;
    // Never more than the picture it reads (`within`): the bound target's own part of the frame.
    r = within(r, .{ .x = cw.render_target.offset.x, .y = cw.render_target.offset.y, .w = @floatFromInt(bound.width), .h = @floatFromInt(bound.height) }) orelse return true;
    // What is behind the pane, from whoever gives it (`Behind`), or the target it is drawn on.
    const given: ?Behind.Picture = if (behind) |b|
        (if (capturing == b.id) b.picture(b.ctx, r) else null)
    else
        null;
    const src = if (given) |g| g.texture else dvui.Texture.fromTargetTemp(bound) catch return false;
    // At any real radius the copy is taken at half size: the first halving is the largest
    // pass of the pyramid and the blur that follows swallows what decimating loses, so it is
    // folded into the copy. The result stops at half size on the way back up for the same
    // reason (`runKawase`), and the final quad stretches it — the two most expensive passes
    // of every capture, gone, on a frost that is re-read every frame.
    const shrink = self.coarse();
    const w: u32 = @max(1, @as(u32, @intFromFloat(r.w)) / shrink);
    const h: u32 = @max(1, @as(u32, @intFromFloat(r.h)) / shrink);

    const blur_prev_rendering = dvui.renderingSet(true);
    defer _ = dvui.renderingSet(blur_prev_rendering);
    // `alphaSet`, not `alpha(1)`: that multiplies the current alpha by 1, which is no change —
    // under a fade the copy (and every pass after it) came out see-through.
    const prev_alpha = dvui.currentWindow().alpha;
    dvui.alphaSet(1);
    defer dvui.alphaSet(prev_alpha);

    const step = self.level(0, w, h) orelse return false;
    self.covered = .{ .x = r.x, .y = r.y, .w = @floatFromInt(w * shrink), .h = @floatFromInt(h * shrink) };
    var rt = cw.render_target;
    const off = if (given) |g| g.origin else rt.offset;
    rt.texture = step;
    rt.offset = .{};
    const prev = dvui.renderTarget(rt);
    {
        const prev_clip = dvui.clipGet();
        defer dvui.clipSet(prev_clip);
        const dest: dvui.Rect.Physical = .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
        dvui.clipSet(dest);
        // `rect` is in window pixels; the bound target (or the given picture) may sit at an
        // offset in the window.
        const sw: f32 = @floatFromInt(src.width);
        const sh: f32 = @floatFromInt(src.height);
        // Copy, not over: the level holds the last capture, and the source's alpha (a
        // see-through window) must land as it is rather than over the old pixels.
        const copy = tapsBlend(src, .copy);
        if (!copy) step.clear();
        defer if (copy) tapsEnd(src, true);
        const uv: dvui.Rect = .{ .x = (r.x - off.x) / sw, .y = (r.y - off.y) / sh, .w = r.w / sw, .h = r.h / sh };
        if (shrink > 1 and copy) {
            // The frame target samples `.nearest`, so a single tap at half size keeps one
            // pixel of every 2×2 block and drops the rest: a 1px edge (pixel-art outlines,
            // text) lands in or out of the copy as content moves under the frost by a pixel,
            // and the blur, fed a different picture each frame, flickers. Four taps, one on
            // each pixel's centre, summed at a quarter each — a true box average.
            // Exactly 2:1, so each tap lands on a pixel centre (an odd rect drops its last
            // row/column, as the integer halving of `w`/`h` already does).
            var box = uv;
            box.w = @as(f32, @floatFromInt(w * shrink)) / sw;
            box.h = @as(f32, @floatFromInt(h * shrink)) / sh;
            const du = 0.5 / sw;
            const dv = 0.5 / sh;
            const offsets = [4][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ -1, 1 }, .{ 1, 1 } };
            for (offsets, 0..) |o, i| {
                var tap = box;
                tap.x += o[0] * du;
                tap.y += o[1] * dv;
                dvui.renderTexture(src, .{ .r = dest, .s = 1 }, .{
                    .uv = tap,
                    .colormod = tapWeight(@floatFromInt(i), 1, 4),
                }) catch {};
                if (i == 0) _ = tapsBlend(src, .add);
            }
        } else {
            dvui.renderTexture(src, .{ .r = dest, .s = 1 }, .{ .uv = uv }) catch {};
        }
    }
    // Straight from the copy into the passes, and back to the frame once at the end: the frame's
    // target is the whole window, and on a tiling GPU (a phone's) every bind of it reloads all of
    // it — rebinding it between the copy and the passes did that once more per capture, for no
    // drawing at all. The passes bind their own levels first; with nothing to blur (a radius too
    // small for a pass) the copy is simply left and the frame rebound.
    defer _ = dvui.renderTarget(prev);
    const source = dvui.Texture.fromTargetTemp(step) catch return false;
    _ = self.runKawase(source, false, 1, shrink);
    return true;
}

/// Fizzy addition: `r` (whole pixels) as a capture of what lies in `span` may take it: `r` itself
/// while it is no larger than `span` either way — a pane partly off the window keeps its whole
/// rect, and so its capture size (`captureSize`) — else cut to `span`. Null when nothing is left.
/// A pane spanning places in two windows' parts of the frame (a view drag's drop zones, drawn
/// across every screen, with a float out of the main window: `core.screens.markEverywhere`) asked
/// for a capture the size of the gap between them, 46424 pixels wide, and Metal aborts at a
/// texture past 32768.
pub fn within(r: Rect.Physical, span: Rect.Physical) ?Rect.Physical {
    if (r.w <= span.w and r.h <= span.h) return r;
    var c = r.intersect(span);
    c.x = @floor(c.x);
    c.y = @floor(c.y);
    c.w = @floor(c.w);
    c.h = @floor(c.h);
    if (c.w < 1 or c.h < 1) return null;
    return c;
}

/// How much smaller than the rect the copy the blur starts from is: for the pyramid, 2 at a
/// radius it blurs; for a `stable` blur, 2 once `fineShrink` wants any shrinking (the copy's
/// 2×2 box average is the first halving), else 1.
fn coarse(self: *const BlurBackdrop) u32 {
    if (self.stable) return if (self.fineShrink() >= 2) 2 else 1;
    return if (self.radius_px >= 4) 2 else 1;
}

/// How far a `stable` blur box-averages down before its passes: halvings until the radius in
/// those texels is under `fine_texel_radius_max`, so the passes stay few (~7) at any radius.
fn fineShrink(self: *const BlurBackdrop) u32 {
    var k: u32 = 1;
    while (self.radius_px / @as(f32, @floatFromInt(k)) >= fine_texel_radius_max and k < 32) k *= 2;
    return k;
}

/// The most blur `runFine` does in passes at one resolution (texels). Past it, halving first is
/// cheaper than the passes it saves — and past ~40 same-size taps start to read as shifted
/// copies rather than a wider blur.
const fine_texel_radius_max: f32 = 20;

/// Fizzy addition: the pyramid target for slot `i` at `w`×`h`, kept from the last capture when
/// it is that size already, made (and so cleared) otherwise. Null when the backend has none.
fn level(self: *BlurBackdrop, i: usize, w: u32, h: u32) ?Texture.Target {
    if (i >= max_levels) return null;
    if (self.levels[i]) |t| {
        if (t.width == w and t.height == h) return t;
        t.destroyLater();
        self.levels[i] = null;
    }
    const t = Texture.Target.create(.{ .width = w, .height = h, .interpolation = .linear, .precision = .high }) catch return null;
    self.levels[i] = t;
    return t;
}

/// Drop every level. `small` is a view of one of them, so it goes too.
fn releaseLevels(self: *BlurBackdrop) void {
    for (&self.levels) |*slot| {
        if (slot.*) |t| t.destroyLater();
        slot.* = null;
    }
    self.small = null;
}

/// Fizzy addition: the `.readback` capture. Reads `rect` back from the current target as it
/// stands, uploads it, and runs the same pipeline `deinit` does on a replayed capture.
fn deinitReadback(self: *BlurBackdrop) void {
    // Keep the frame in a texture for as long as frosts read it (`FrameTarget.want`).
    FrameTarget.want();
    if (self.deinitFromTarget()) return;
    if (!dvui.Backend.support_read_pixels) return;
    var r = self.rect;
    if (r.empty()) return;
    r.x = @floor(r.x);
    r.y = @floor(r.y);
    r.w = @round(r.w);
    r.h = @round(r.h);
    if (r.w < 1 or r.h < 1) return;
    r = within(r, dvui.windowRectPixels()) orelse return;
    const w: u32 = @intFromFloat(r.w);
    const h: u32 = @intFromFloat(r.h);

    const cw = dvui.currentWindow();
    // The texture is always the full rect, cleared to nothing; only the part of it that is on
    // the window is read. A rect half off the edge used to fail the read outright and leave the
    // previous frost drawn at the new position — the blur "moving with" the card past the edge.
    const pixels = cw.arena().alloc(dvui.Color.PMA, w * h) catch return;
    @memset(pixels, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    const vis = r.intersect(dvui.windowRectPixels());
    var vr = vis;
    vr.x = @floor(vr.x);
    vr.y = @floor(vr.y);
    vr.w = @floor(vr.w);
    vr.h = @floor(vr.h);
    if (vr.w >= 1 and vr.h >= 1) {
        const vw: usize = @intFromFloat(vr.w);
        const vh: usize = @intFromFloat(vr.h);
        const read = cw.arena().alloc(u8, vw * vh * 4) catch return;
        cw.backend.readPixels(vr, read.ptr) catch return;
        const ox: usize = @intFromFloat(vr.x - r.x);
        const oy: usize = @intFromFloat(vr.y - r.y);
        // The drawable holds what dvui blended into it, and dvui blends premultiplied — so
        // these bytes already are PMA and copy straight across. Premultiplying again
        // (`PMA.fromColor`) squared the alpha into the colour and a see-through window read
        // back as near-black.
        for (0..vh) |y| {
            const row = read[y * vw * 4 .. (y + 1) * vw * 4];
            const dst = std.mem.sliceAsBytes(pixels[(oy + y) * w + ox ..][0..vw]);
            @memcpy(dst, row);
        }
    }
    const source = dvui.textureCreate(pixels, .{ .width = w, .height = h, .interpolation = .linear }) catch return;
    self.covered = r;
    defer dvui.textureDestroyLater(source);

    const blur_prev_rendering = dvui.renderingSet(true);
    defer _ = dvui.renderingSet(blur_prev_rendering);
    _ = self.runKawase(source, true, 1, 1);
}

/// Fizzy addition (proposed for upstream): a dual-Kawase blur of an already-captured texture,
/// as a new texture the caller owns (destroy it with `dvui.textureDestroyLater`). Exactly the
/// pipeline `deinit` runs after its own capture — halve with the 4-tap kernel until the radius
/// is reached, double back with the 8-tap kernel — without the bracket. `tex` is not touched.
/// Null when the backend has no render targets, or `radius_px` is too small for a single pass.
///
/// Not a same-size "classic" Kawase: at full resolution the growing offsets stop being
/// sub-texel after the first pass, and bilinear sampling then returns shifted *copies* rather
/// than a wider kernel — the result reads as a multiple exposure with a blocky halo. Halving
/// first is what keeps every tap inside a texel of its neighbour, which is the whole reason
/// dual-Kawase is smooth.
pub fn blurred(tex: Texture, radius_px: f32) ?Texture {
    if (tex.width < 2 or tex.height < 2) return null;
    var tmp: BlurBackdrop = .{ .radius_px = radius_px };
    const prev_rendering = dvui.renderingSet(true);
    defer _ = dvui.renderingSet(prev_rendering);
    defer tmp.releaseLevels();
    const last = tmp.runKawase(tex, true, 1, 1) orelse return null;
    // Take the last level out of the pyramid as the caller's own texture; `releaseLevels`
    // then drops the rest.
    const out = dvui.textureFromTarget(tmp.levels[last].?) catch return null;
    tmp.levels[last] = null;
    return out;
}

/// The pyramid's levels are precise targets (`CreateOptions.precision = .high`: float where the
/// backend has it). At 8 bits a dark theme's frost lives in ~30 levels, and rounding it at
/// every one of the ~8 passes — coarsest at the small levels, then magnified back up — drew
/// contour blobs instead of a gradient. Only the final texture is 8-bit again.
///
/// Dual-Kawase downsample / upsample used by both `deinit` (after capturing
/// into `full_target`) and `blurred` (from an existing snapshot).
///
/// `source` is the caller's; it is never destroyed here. The passes run through `levels`
/// from slot `first` on, and the slot of the last level written comes back — `small` is a
/// view of it. Null when no pass ran (`radius_px <= 1` → downscale=1, loops don't run) or
/// the backend has no targets; `small` is then left as it was.
///
/// `restore_target` saves/restores the current render target around the
/// passes (`blurred`). `deinit` already has an outer restore to the
/// window target and passes false so we don't rebind a destroyed capture
/// target mid-pipeline. Restore happens only if a pass actually bound a
/// step target — a no-op restore would rebind the window (clear-on-bind
/// flicker).
///
/// `source_coarse` is how many rect pixels one source texel already stands for, so the
/// radius means the same thing whether the copy was taken full size or not.
fn runKawase(self: *BlurBackdrop, source: Texture, restore_target: bool, first: usize, source_coarse: u32) ?usize {
    if (self.stable) return self.runFine(source, restore_target, first, source_coarse);
    var cur = source;
    // The downsample levels as they are made, for `detail` to mix back in on the way up.
    var downs: [max_levels]Texture = undefined;
    var n_downs: usize = 0;
    var slot = first;
    var last: ?usize = null;
    // The taps are weights of their own; the ambient alpha (a region fading in around the
    // caller) must not scale them too.
    // `alphaSet`, not `alpha(1)`: that multiplies the current alpha by 1, which is no change —
    // under a fade the copy (and every pass after it) came out see-through.
    const prev_alpha = dvui.currentWindow().alpha;
    dvui.alphaSet(1);
    defer dvui.alphaSet(prev_alpha);

    var prev1: dvui.RenderTarget = undefined;
    var switched = false;
    defer if (restore_target and switched) {
        _ = dvui.renderTarget(prev1);
    };

    // Each halving pass roughly doubles the effective blur radius in source
    // pixels, so after n halvings the total radius is ~2^n. Inverting that
    // gives the downscale factor to hit a given radius: 1/radius_px.
    // Approximate (not a real Gaussian-equivalent radius), but tracks CSS
    // intuition well enough: bigger radius looks blurrier, and doubling it
    // looks like about one more halving pass, same as the browser.
    const downscale = @as(f32, @floatFromInt(source_coarse)) / @max(1.0, self.radius_px);
    const src_w: f32 = @floatFromInt(source.width);
    const src_h: f32 = @floatFromInt(source.height);
    const target_w: u32 = @max(1, @as(u32, @intFromFloat(@round(src_w * downscale))));
    const target_h: u32 = @max(1, @as(u32, @intFromFloat(@round(src_h * downscale))));

    while (cur.width > target_w or cur.height > target_h) {
        const next_w = @max(target_w, cur.width / 2);
        const next_h = @max(target_h, cur.height / 2);
        const step_target = self.level(slot, next_w, next_h) orelse break;
        // Switches straight from `cur`'s target to `step_target` - no need
        // to save/restore per pass, see comment above the outer `defer`.
        const prev = dvui.renderTarget(.{ .texture = step_target, .offset = .{} });
        if (!switched) {
            prev1 = prev;
            switched = true;
        }
        // The ambient clip rect is in window coordinates (wherever this
        // widget happens to be laid out) and is meaningless once rendering
        // targets `step_target`, whose content is addressed from (0,0) - a
        // clip that doesn't happen to cover the origin (e.g. a widget
        // scrolled/nested away from the top-left) would silently clip away
        // every tap draw below and leave `step_target` blank.
        const prev_clip = dvui.clipGet();
        dvui.clipSet(.{ .w = @floatFromInt(next_w), .h = @floatFromInt(next_h) });
        defer dvui.clipSet(prev_clip);

        const dest_r: dvui.Rect.Physical = .{ .w = @floatFromInt(next_w), .h = @floatFromInt(next_h) };
        {
            // 4-tap diagonal-offset downsample, sampled further out (1.5 source
            // texels) than the ~0.5-texel implicit box a plain halving pass
            // would land on - that wider kernel is what keeps the blur
            // spreading pass over pass instead of just antialiasing. Scaled by
            // passStrength so a partial (non-halving) pass spreads less.
            const kawase_offset_texels: f32 = 1.5;
            const half_u = kawase_offset_texels * passStrength(next_w, cur.width) / @as(f32, @floatFromInt(cur.width));
            const half_v = kawase_offset_texels * passStrength(next_h, cur.height) / @as(f32, @floatFromInt(cur.height));
            const taps = [4]dvui.Point{
                .{ .x = -half_u, .y = -half_v },
                .{ .x = half_u, .y = -half_v },
                .{ .x = -half_u, .y = half_v },
                .{ .x = half_u, .y = half_v },
            };
            const add = tapsBegin(cur, step_target);
            defer tapsEnd(cur, add);
            for (taps, 0..) |tap, i| {
                const mod = if (add)
                    tapWeight(@floatFromInt(i), 1, 4)
                else
                    dvui.Color.white.opacity(1.0 / @as(f32, @floatFromInt(i + 1)));
                dvui.renderTexture(cur, .{ .r = dest_r }, .{
                    .uv = .{ .x = tap.x, .y = tap.y, .w = 1, .h = 1 },
                    .colormod = mod,
                }) catch {};
                if (add and i == 0) _ = tapsBlend(cur, .add);
            }
        }

        cur = dvui.Texture.fromTargetTemp(step_target) catch break;
        last = slot;
        slot += 1;
        if (n_downs < downs.len) {
            downs[n_downs] = cur;
            n_downs += 1;
        }
    }

    const detail = std.math.clamp(self.detail, 0, 0.9);

    // Forming (`form`): octaves are counted down from the source. The blur has reached `reach`
    // of the pyramid's `full`; a doubling that ends at or above it is the downsample level of its
    // size outright, and the one that crosses it mixes that level in by how far past it the
    // blur is — so the blur grows smoothly from the source up through the levels as `form` does.
    const src_wf: f32 = @floatFromInt(source.width);
    const full = @log2(src_wf / @as(f32, @floatFromInt(@max(1, cur.width))));
    const forming = self.form < 0.999;
    const reach = std.math.clamp(self.form, 0, 1) * full;
    var octave_prev = full;

    // Upsample back to full size with progressive doubling + a wide
    // multi-tap kernel each step (real "dual Kawase" blur), instead of one
    // big bilinear stretch, which would just show the downsampled blocks.
    const final_w: u32 = source.width;
    const final_h: u32 = source.height;
    while (cur.width < final_w or cur.height < final_h) {
        const next_w = @min(final_w, cur.width * 2);
        const next_h = @min(final_h, cur.height * 2);
        const octave_now = @log2(src_wf / @as(f32, @floatFromInt(next_w)));
        defer octave_prev = octave_now;
        // How much of this doubling is the level of its size rather than the blur above it.
        const take: f32 = if (forming) std.math.clamp((octave_prev - reach) / @max(octave_prev - octave_now, 0.0001), 0, 1) else 0;
        const level_tex: ?Texture = if (take <= 0.001) null else if (octave_now < 0.5) source else nearest: {
            var best: ?Texture = null;
            for (downs[0..n_downs]) |d| {
                if (best == null or @abs(@as(f32, @floatFromInt(d.width)) - @as(f32, @floatFromInt(next_w))) < @abs(@as(f32, @floatFromInt(best.?.width)) - @as(f32, @floatFromInt(next_w)))) best = d;
            }
            break :nearest best;
        };
        const step_target = self.level(slot, next_w, next_h) orelse break;
        const prev = dvui.renderTarget(.{ .texture = step_target, .offset = .{} });
        if (!switched) {
            prev1 = prev;
            switched = true;
        }
        // See matching comment in the downsample loop above.
        const prev_clip = dvui.clipGet();
        dvui.clipSet(.{ .w = @floatFromInt(next_w), .h = @floatFromInt(next_h) });
        defer dvui.clipSet(prev_clip);

        const dest_r: dvui.Rect.Physical = .{ .w = @floatFromInt(next_w), .h = @floatFromInt(next_h) };
        if (level_tex != null and take >= 0.999) {
            // Wholly the level: the blur has not reached this far yet.
            const lvl = level_tex.?;
            const lvl_copy = tapsBegin(lvl, step_target);
            defer tapsEnd(lvl, lvl_copy);
            dvui.renderTexture(lvl, .{ .r = dest_r }, .{}) catch {};
        } else {
            // 8-tap "dual filter" upsample kernel: 4 cardinal taps (weight 1)
            // plus 4 diagonal taps (weight 2), offset in units of the smaller
            // *source* texture's texel size. Composited with the same running-
            // weighted-average alpha trick as the downsample taps above
            // (alpha_i = w_i / cumulative_weight_i). Scaled by passStrength so
            // a partial (non-doubling) pass spreads less, matching the
            // downsample side.
            const ou_x = passStrength(cur.width, next_w) / @as(f32, @floatFromInt(cur.width));
            const ou_y = passStrength(cur.height, next_h) / @as(f32, @floatFromInt(cur.height));
            const Tap = struct { x: f32, y: f32, w: f32 };
            const taps = [8]Tap{
                .{ .x = 0, .y = 2 * ou_y, .w = 1 },
                .{ .x = ou_x, .y = ou_y, .w = 2 },
                .{ .x = 2 * ou_x, .y = 0, .w = 1 },
                .{ .x = ou_x, .y = -ou_y, .w = 2 },
                .{ .x = 0, .y = -2 * ou_y, .w = 1 },
                .{ .x = -ou_x, .y = -ou_y, .w = 2 },
                .{ .x = -2 * ou_x, .y = 0, .w = 1 },
                .{ .x = -ou_x, .y = ou_y, .w = 2 },
            };
            // `detail`: the two downsample levels either side of this doubling in scale — the
            // finer (wider) one and the coarser — blended by where the doubling falls between
            // them (in octaves), stretched to fit, and mixed in as extra taps weighted so they are
            // `detail` of the result (against the kernel's 12). The way down halves from the
            // source and the way up doubles from `size / radius`, so the doublings drift between
            // the down levels as the radius moves; a single nearest level drifted up to half an
            // octave finer then snapped coarser (38 blurrier than 42). Weighted by position, the
            // mixed-in scale tracks the doubling's own and the blur changes smoothly with radius.
            // The unblurred source is never a candidate, so near the top its share is dropped
            // and detail fades out rather than sharpening into a double image.
            var finer: ?Texture = null;
            var coarser: ?Texture = null;
            if (detail > 0.001) {
                for (downs[0..n_downs]) |d| {
                    if (d.width >= next_w) {
                        if (finer == null or d.width < finer.?.width) finer = d;
                    } else {
                        if (coarser == null or d.width > coarser.?.width) coarser = d;
                    }
                }
            }
            const nw: f32 = @floatFromInt(next_w);
            // Octaves from the finer level (or, with none, from the source a level above) down
            // to this doubling, over the octaves to the coarser level.
            const frac: f32 = blk: {
                const hi_w: f32 = if (finer) |f| @floatFromInt(f.width) else @floatFromInt(source.width);
                const lo_w: f32 = if (coarser) |c| @floatFromInt(c.width) else nw;
                const span = @log2(hi_w / lo_w);
                break :blk if (span > 0.001) std.math.clamp(@log2(hi_w / nw) / span, 0, 1) else 0;
            };
            const d_fine: f32 = if (finer != null) detail * (1 - frac) else 0;
            const d_coarse: f32 = if (coarser != null) detail * frac else 0;
            const d_tot = d_fine + d_coarse;
            const skip_tot: f32 = if (d_tot > 0.001) 12 * d_tot / (1 - d_tot) else 0;
            const w_fine: f32 = if (d_tot > 0.001) skip_tot * d_fine / d_tot else 0;
            const w_coarse: f32 = if (d_tot > 0.001) skip_tot * d_coarse / d_tot else 0;
            // Forming: the level of this size, as `take` of the result.
            const w_level: f32 = if (level_tex != null) (12 + skip_tot) * take / (1 - take) else 0;
            const total: f32 = 12 + skip_tot + w_level;

            const add = tapsBegin(cur, step_target);
            defer tapsEnd(cur, add);
            var cum_w: f32 = 0;
            for (taps, 0..) |tap, i| {
                const mod = if (add)
                    tapWeight(cum_w, tap.w, total)
                else
                    dvui.Color.white.opacity(tap.w / (cum_w + tap.w));
                cum_w += tap.w;
                dvui.renderTexture(cur, .{ .r = dest_r }, .{
                    .uv = .{ .x = tap.x, .y = tap.y, .w = 1, .h = 1 },
                    .colormod = mod,
                }) catch {};
                if (add and i == 0) _ = tapsBlend(cur, .add);
            }
            const extras = [3]struct { tex: ?Texture, w: f32 }{
                .{ .tex = finer, .w = w_fine },
                .{ .tex = coarser, .w = w_coarse },
                .{ .tex = level_tex, .w = w_level },
            };
            for (extras) |e| {
                const d = e.tex orelse continue;
                if (e.w <= 0.001) continue;
                const mod = if (add)
                    tapWeight(cum_w, e.w, total)
                else
                    dvui.Color.white.opacity(e.w / (cum_w + e.w));
                cum_w += e.w;
                const d_add = add and tapsBlend(d, .add);
                defer tapsEnd(d, d_add);
                dvui.renderTexture(d, .{ .r = dest_r }, .{ .colormod = mod }) catch {};
            }
        }

        cur = dvui.Texture.fromTargetTemp(step_target) catch break;
        last = slot;
        slot += 1;
    }

    // Nothing blurred (a radius too small for a pass): no result — not the last capture's.
    // Left in place, `small` was drawn at this capture's rect as if it were current, and a
    // tooltip fading in from a sub-pixel blur flashed its previous showing's backdrop.
    const done = last orelse {
        self.small = null;
        return null;
    };
    dither(cur);
    self.small = cur;
    return done;
}

/// Fizzy addition: a blur that holds still under moving content — classic (same-size) Kawase,
/// after box-averaging down (`fineShrink`) when the radius is big. Each pass averages four
/// diagonal bilinear taps `o` texels out, which adds `o² + ¼` to the variance per axis (each tap
/// is itself a 2-texel average); passes run at o = ½, 1½, 2½ … until the variance reaches σ² for
/// σ = radius/2 in the working texels, the last pass at whatever offset lands it exactly, so the
/// blur grows continuously with the radius.
///
/// Why it is stable where the pyramid shimmers: the pyramid's levels are *decimated*, so what a
/// coarse texel holds jumps as content slides a pixel; a box average changes by exactly the
/// pixel that slid, and the blur above it is shift-invariant. Each halving here is one bilinear
/// tap on the corner four texels share — their exact mean. `source` (already `source_coarse`
/// down, by the copy's own 2×2 box) is never written; halvings take slots from `first`, and the
/// passes ping-pong between the next two.
fn runFine(self: *BlurBackdrop, source: Texture, restore_target: bool, first: usize, source_coarse: u32) ?usize {
    // `alphaSet`, not `alpha(1)`: that multiplies the current alpha by 1, which is no change —
    // under a fade the copy (and every pass after it) came out see-through.
    const prev_alpha = dvui.currentWindow().alpha;
    dvui.alphaSet(1);
    defer dvui.alphaSet(prev_alpha);

    var prev1: dvui.RenderTarget = undefined;
    var switched = false;
    defer if (restore_target and switched) {
        _ = dvui.renderTarget(prev1);
    };

    var cur = source;
    var last: ?usize = null;
    var slot = first;
    var scale = source_coarse;
    const want = @max(self.fineShrink(), source_coarse);
    while (scale < want and cur.width >= 4 and cur.height >= 4) : (scale *= 2) {
        const nw = cur.width / 2;
        const nh = cur.height / 2;
        const step_target = self.level(slot, nw, nh) orelse break;
        const prev = dvui.renderTarget(.{ .texture = step_target, .offset = .{} });
        if (!switched) {
            prev1 = prev;
            switched = true;
        }
        const prev_clip = dvui.clipGet();
        defer dvui.clipSet(prev_clip);
        dvui.clipSet(.{ .w = @floatFromInt(nw), .h = @floatFromInt(nh) });
        // Exactly 2:1 (an odd edge drops its last texel), so each output centre lands on the
        // corner four source texels share and linear filtering returns their mean.
        dvui.renderTexture(cur, .{ .r = .{ .w = @floatFromInt(nw), .h = @floatFromInt(nh) } }, .{
            .uv = .{
                .w = @as(f32, @floatFromInt(nw * 2)) / @as(f32, @floatFromInt(cur.width)),
                .h = @as(f32, @floatFromInt(nh * 2)) / @as(f32, @floatFromInt(cur.height)),
            },
        }) catch {};
        cur = dvui.Texture.fromTargetTemp(step_target) catch break;
        last = slot;
        slot += 1;
    }

    const w = cur.width;
    const h = cur.height;
    const sigma = self.radius_px * 0.5 / @as(f32, @floatFromInt(scale));
    var remaining = sigma * sigma;
    var pass: usize = 0;
    while (remaining > 0.01 and pass < 16) : (pass += 1) {
        var o: f32 = @as(f32, @floatFromInt(pass)) + 0.5;
        if (o * o + 0.25 > remaining) o = @sqrt(@max(remaining - 0.25, 0));
        remaining -= o * o + 0.25;

        const pslot = slot + pass % 2;
        const step_target = self.level(pslot, w, h) orelse break;
        const prev = dvui.renderTarget(.{ .texture = step_target, .offset = .{} });
        if (!switched) {
            prev1 = prev;
            switched = true;
        }
        // See the matching comment in `runKawase`: the ambient clip means nothing here.
        const prev_clip = dvui.clipGet();
        dvui.clipSet(.{ .w = @floatFromInt(w), .h = @floatFromInt(h) });
        defer dvui.clipSet(prev_clip);

        const dest_r: dvui.Rect.Physical = .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
        const du = o / @as(f32, @floatFromInt(w));
        const dv = o / @as(f32, @floatFromInt(h));
        const taps = [4]dvui.Point{
            .{ .x = -du, .y = -dv },
            .{ .x = du, .y = -dv },
            .{ .x = -du, .y = dv },
            .{ .x = du, .y = dv },
        };
        const add = tapsBegin(cur, step_target);
        defer tapsEnd(cur, add);
        for (taps, 0..) |tap, i| {
            const mod = if (add)
                tapWeight(@floatFromInt(i), 1, 4)
            else
                dvui.Color.white.opacity(1.0 / @as(f32, @floatFromInt(i + 1)));
            dvui.renderTexture(cur, .{ .r = dest_r }, .{
                .uv = .{ .x = tap.x, .y = tap.y, .w = 1, .h = 1 },
                .colormod = mod,
            }) catch {};
            if (add and i == 0) _ = tapsBlend(cur, .add);
        }

        cur = dvui.Texture.fromTargetTemp(step_target) catch break;
        last = pslot;
    }

    // Nothing blurred (a radius too small for a pass): no result — not the last capture's.
    // Left in place, `small` was drawn at this capture's rect as if it were current, and a
    // tooltip fading in from a sub-pixel blur flashed its previous showing's backdrop.
    const done = last orelse {
        self.small = null;
        return null;
    };
    dither(cur);
    self.small = cur;
    return done;
}

/// Fizzy addition: ordered dithering, so the one quantising write left — the finished frost
/// onto the 8-bit frame — does not step. A dark theme's frost spans ~40 levels, and a smooth
/// ramp across 200px is then a staircase of 4px treads, which the eye picks out on dark tones
/// however exact the pyramid was. Adding a tiled 8×8 Bayer pattern at 0…1 LSB into the last
/// (float) level breaks each tread into a pattern that averages to the true value; the final
/// draw rounds signal plus noise once. Only worth doing when the level really is float — into
/// an 8-bit level the sub-LSB noise itself rounds away to nothing.
///
/// The pattern is positive-only (an additive draw cannot subtract), which biases the frost by
/// half a level; invisible, and less than the bias the taps' own rounding carried before.
fn dither(last: Texture) void {
    if (!dvui.Backend.support_precise_targets) return;
    const noise = ditherTexture() orelse return;
    const cw = dvui.currentWindow();
    if (!tapsBlend(noise, .add)) return;
    defer cw.backend.textureBlend(noise, .over) catch {};
    const prev = dvui.renderTarget(.{ .texture = Texture.Target.cast(last), .offset = .{}, .rendering = cw.render_target.rendering });
    defer _ = dvui.renderTarget(prev);
    const w: f32 = @floatFromInt(last.width);
    const h: f32 = @floatFromInt(last.height);
    const prev_clip = dvui.clipGet();
    defer dvui.clipSet(prev_clip);
    dvui.clipSet(.{ .w = w, .h = h });
    // `alphaSet`, not `alpha(1)`: that multiplies the current alpha by 1, which is no change —
    // under a fade the copy (and every pass after it) came out see-through.
    const prev_alpha = dvui.currentWindow().alpha;
    dvui.alphaSet(1);
    defer dvui.alphaSet(prev_alpha);
    // The texture holds 0…63 (in 1/255 units); 1/64 of that is 0…1 LSB. Tiled by uv > 1.
    dvui.renderTexture(noise, .{ .r = .{ .w = w, .h = h }, .s = 1 }, .{
        .uv = .{ .w = w / bayer_size, .h = h / bayer_size },
        .colormod = dvui.Color.white.opacity(1.0 / 64.0),
    }) catch {};
}

const bayer_size: f32 = 8;
var dither_tex: ?Texture = null;

/// The 8×8 Bayer matrix as a repeating texture, made once per process (per dylib, which is
/// fine: it is 256 bytes). Never destroyed — it lives as long as the renderer.
fn ditherTexture() ?Texture {
    if (dither_tex) |t| return t;
    // Recursive definition: B(2n) = [4B(n)+0, 4B(n)+2; 4B(n)+3, 4B(n)+1].
    var px: [64]dvui.Color.PMA = undefined;
    for (0..8) |y| {
        for (0..8) |x| {
            var v: u8 = 0;
            var bit: u3 = 0;
            var xx = x;
            var yy = y;
            while (bit < 3) : (bit += 1) {
                const xb: u8 = @intCast(xx & 1);
                const yb: u8 = @intCast(yy & 1);
                v = v * 4 + (xb ^ yb) * 2 + yb;
                xx >>= 1;
                yy >>= 1;
            }
            // Bit-reversal above ordered from the finest level; the value set is 0…63 either way.
            px[y * 8 + x] = .{ .r = v, .g = v, .b = v, .a = v };
        }
    }
    dither_tex = dvui.textureCreate(&px, .{ .width = 8, .height = 8, .interpolation = .nearest, .wrap_u = .repeat, .wrap_v = .repeat }) catch return null;
    return dither_tex;
}

/// Draw the cached blurred texture over `rect` (set by the last
/// `init`). Cheap: just queues one textured-quad render command.
/// Must be the first thing drawn wherever content on top of the blur goes,
/// so that content paints over it.
pub fn draw(self: *BlurBackdrop) void {
    self.drawRounded(.{}, 1);
}

/// Fizzy addition: `draw` with rounded corners (natural units, scaled by `scale`), for a frost
/// under a card that has them.
pub fn drawRounded(self: *BlurBackdrop, corners: dvui.CornerRect, scale: f32) void {
    const tex = self.small orelse return;
    dvui.renderTexture(tex, .{ .r = self.rect, .s = scale }, .{ .corners = corners, .uv = self.rectUv() }) catch {};
}

/// Fizzy addition: where `rect` lies in `small`, which pictures `coverage` — the pane's margin
/// for its edge.
fn rectUv(self: *const BlurBackdrop) dvui.Rect {
    const c = self.coverage();
    return .{ .x = (self.rect.x - c.x) / c.w, .y = (self.rect.y - c.y) / c.h, .w = self.rect.w / c.w, .h = self.rect.h / c.h };
}

/// Fizzy addition: how a frosted pane is composed. See `frostPane`.
pub const Pane = struct {
    /// Blur strength — halvings; 8 a soft focus, 16 a heavy frost, 32 a wash of colour.
    radius: f32 = 20,
    /// How often to re-read what is underneath while the pane's geometry holds. Zero re-reads
    /// every frame, which is the default now that a re-read is a handful of draws into targets
    /// the pane keeps: content scrolling under a window moves in its blur at the frame rate.
    refresh_ms: u32 = 0,
    /// The pane's own colour, composited with the frost: `out = (1 - mix) * frost + mix * tint`.
    /// The tint's alpha is the coverage the whole thing ends up with. Null keeps only the frost.
    tint: ?dvui.Color = null,
    /// 0 is all frost, 1 is all tint.
    mix: f32 = 0.5,
    /// White added over the whole pane after the mix, 0…1 — a glass material's lift.
    lift: f32 = 0,
    /// How much definition the frost keeps, 0…1 (`BlurBackdrop.detail`).
    detail: f32 = 0,
    /// How far the pane's bevelled edge refracts what it shows, 0 (none) to 2
    /// (`liquid_glass.Look.refraction`).
    refraction: f32 = 1,
    /// How formed the glass is, 0 (not there yet) to 1. Its edge comes in with it — the
    /// refraction squeezing in from none, swelling past its depth and settling — while the frost,
    /// tint and lift are whole from the first frame it is drawn, so the pane stands off from what
    /// is behind it at once. Null forms it by itself as the pane first appears (`form_ms`, at the
    /// app's motion); a caller that knows better — a window closing, a tooltip on its own fade —
    /// passes its own.
    form: ?f32 = null,
    /// A signature, kept by the caller, of what lies under the pane. Set, it replaces
    /// `refresh_ms`: what is underneath is read again only when the signature changes (or the
    /// pane moves, resizes or forms), however many frames pass. For chrome that sits over
    /// something the caller can describe — a button over a canvas it knows the art, zoom and pan
    /// of — where a re-read every frame is a blur's worth of work for a picture that has not
    /// changed.
    witness: ?u64 = null,
    /// Clear glass: what is behind it unblurred — bent at its edge, tinted and lit as frost is —
    /// for the blur turned off where the glass program draws (`LiquidField`), so liquid glass is
    /// still glass. Its capture runs at `min_blur`, for the picture before the blur.
    clear: bool = false,
    /// The size the pane is growing into, physical: a window growing into place. Its capture is
    /// made that size from the first frame (`captureSize`), so it has one set of targets for the
    /// whole growth — growing from a drop to a window several times its size, it outgrew each
    /// capture in turn and made a new pyramid for each, all in the motion's first frames.
    reach: ?Size.Physical = null,
};

/// Physical pixels: the least blur a frost is drawn with (`frostPane`).
pub const min_blur: f32 = 3;

/// How long a pane takes to form by itself, as written (`core.motion.durationMs`).
pub const form_ms: f32 = 525;

/// Fizzy addition: a frosted pane — what is under `rect`, blurred, composed with a tint and a
/// lift per `pane`, drawn with `corners`. Keyed by `id`, so the blur texture lives and dies with
/// the widget that owns it (a floating window, a menu, a popover).
///
/// Declared now, done later: the copy of "what is under me" and the draw are queued with
/// `dvui.deferRender`, so they run when this subwindow's commands replay at the end of the
/// frame — after every subwindow below it has rendered. Taken at declaration, a frost saw only
/// the main window: another floating window under this one had queued its draws but put
/// nothing on the frame yet, and the frost looked straight through it.
///
/// Draw order is the caller's: shadow first (a box shadow covers the pane's interior too, and
/// the frost replaces what it covers, so a shadow drawn first survives only outside), then this,
/// then the contents. The caller paints no fill of its own — the tint is the fill.
pub fn frostPane(id: dvui.Id, rect: Rect.Physical, corners: dvui.CornerRect, scale: f32, pane: Pane) void {
    queuePane(id, rect, corners, scale, pane, null);
}

/// Fizzy addition: `field`'s shapes as one pane of glass, run together where they are close
/// (`LiquidField`): frosted like `frostPane`, its blur, tint and lift per `pane` and its shapes'
/// own edges. Only where the glass program is (`LiquidField.ready`); otherwise draw panes.
pub fn fieldPane(id: dvui.Id, field: LiquidField, scale: f32, pane: Pane) void {
    if (field.len == 0) return;
    queuePane(id, field.bounds(), .{}, scale, pane, field);
}

fn queuePane(id: dvui.Id, rect: Rect.Physical, corners: dvui.CornerRect, scale: f32, pane: Pane, field: ?LiquidField) void {
    const job = dvui.dataGetPtrDefault(null, id, "_frost_job", FrostJob, .{});
    const backdrop = dvui.dataGetPtrDefault(null, id, "_frost", BlurBackdrop, .{});
    dvui.dataSetDeinitFunction(null, id, "_frost", &releaseTexture);
    const now = dvui.currentWindow().frame_time_ns;
    // How formed it is: the caller's, or its own from when it first came up. Per id, so it
    // lives exactly as long as the pane is drawn and a pane that comes back forms anew.
    const form = std.math.clamp(pane.form orelse selfForm(id, now), 0, 1);
    // The blur comes in from sharp (`form`, at the full radius — see `BlurBackdrop.form`); the
    // edge squeezes in on the arrival curve, past its final shape and back when motion is playful.
    const radius = pane.radius;
    // Under a few pixels of blur the pyramid makes no pass, and the picture it hands back is an
    // empty target — which a frost, replacing what it covers, lays down as a hole: the desktop
    // showed through. Glass that is barely there is the scene behind it, so draw none.
    if (radius < min_blur or form < 0.02) return;
    // Only the edge forms: it swells past its depth and settles as the glass arrives
    // (`motion.swell`). The frost, tint and lift are whole from the first frame, so a window is
    // set off from what is under it as soon as it is there — glass that came in clear began
    // with no contrast — and, whole, the blur is not read again for every step of forming.
    const edge = @max(0, motion.swell(form));
    backdrop.mode = .readback;
    backdrop.radius_px = radius;
    backdrop.detail = pane.detail;
    backdrop.form = 1;

    // The glass's edge shows what lies just beyond it (`liquid_glass`), so the capture reaches
    // that far past the pane; flat glass needs none. As far as the whole edge reaches, however
    // much of it has formed: a capture growing with it was a new size, and new targets, a frame.
    // Clear glass has the whole edge: it is thick glass that happens not to be frosted.
    const ramp = if (pane.clear) 1 else liquid_glass.blurRamp(pane.radius);
    // The whole edge on every pane, whatever its size: the rim fits the pane (`liquid_glass.fit`).
    const lens_full = motion.liquid() * ramp;
    const lens = lens_full * edge;
    const margin = liquid_glass.margin(.{ .lens = lens_full * (1 + motion.overshoot_max * motion.swell_gain), .refraction = pane.refraction }, scale);
    // A size it keeps while it can (`captureSize`): a pane that changes size — a menu sliding
    // open, a dragged view shrinking into its card — keeps one capture size, and so one set of
    // targets, for many frames, where an exact capture was a new pyramid every frame it moved.
    const need = rect.insetAll(-margin);
    const cap = dvui.dataGetPtrDefault(null, id, "_frost_cap", dvui.Size, .{});
    const want: dvui.Size = if (pane.reach) |r|
        .{ .w = @max(need.w, r.w + 2 * margin), .h = @max(need.h, r.h + 2 * margin) }
    else
        .{ .w = need.w, .h = need.h };
    cap.* = captureSize(cap.*, want);
    const captured: Rect.Physical = .{ .x = need.x, .y = need.y, .w = cap.w, .h = cap.h };
    // `init` takes a rect in *window* coordinates.
    const nat = dvui.windowRectScale().rectFromPhysical(captured);
    // A witness that changes with the geometry and, coarsely, with time.
    const tick: i128 = if (pane.witness) |w|
        @intCast(w)
    else if (pane.refresh_ms == 0)
        now
    else
        @divTrunc(now, @as(i128, pane.refresh_ms) * std.time.ns_per_ms);
    // How formed too, so a pane forming blurs again every frame it changes, whatever its refresh.
    backdrop.init(nat, .{ captured, tick, @round(radius) });

    job.* = .{
        .id = id,
        .backdrop = backdrop,
        .corners = corners,
        .scale = scale,
        .rect = rect,
        .tint = pane.tint,
        .mix = std.math.clamp(pane.mix, 0, 1),
        .lift = std.math.clamp(pane.lift, 0, 1),
        // The edge comes in with the blur, so a barely-frosted pane has barely an edge.
        .lens = lens,
        .refraction = pane.refraction,
        .field = field,
        .clear = pane.clear,
    };
    dvui.deferRender(job, FrostJob.draw);
}

/// The capture size for a pane needing `need`, given what it captured last (`prev`, zero at
/// first). Kept while `need` fits in it and fills more than half of it each way, so a pane
/// shrinking keeps its targets until it has halved — a view shrinking into its card crossed a
/// quarter-octave bucket every frame or two, a new pyramid each time. Otherwise `need` rounded
/// up to a bucket (`bucket`), with a quarter more room ahead of a pane that is growing.
pub fn captureSize(prev: dvui.Size, need: dvui.Size) dvui.Size {
    const Fits = struct {
        fn of(p: f32, n: f32) bool {
            return n <= p and n * 2 > p;
        }
    };
    if (Fits.of(prev.w, need.w) and Fits.of(prev.h, need.h)) return prev;
    const growing = prev.w > 0 and (need.w > prev.w or need.h > prev.h);
    const room: f32 = if (growing) 1.25 else 1;
    return .{ .w = bucket(need.w * room), .h = bucket(need.h * room) };
}

/// `v` rounded up to a size bucket: whole pixels up to 64, then quarter-octave steps — never more
/// than a fifth bigger than asked.
fn bucket(v: f32) f32 {
    if (v <= 64) return @ceil(v);
    return @ceil(@exp2(@ceil(@log2(v) * 4) / 4));
}

/// How formed a pane is by itself: from nothing when it first came up to whole over `form_ms`,
/// keeping frames coming while it forms.
fn selfForm(id: dvui.Id, now: i128) f32 {
    const born = dvui.dataGetPtrDefault(null, id, "_frost_born", i128, now);
    const ms = motion.durationMs(form_ms);
    if (ms <= 0) return 1;
    const t = @as(f32, @floatFromInt(now - born.*)) / std.time.ns_per_ms / ms;
    if (t < 1) dvui.refresh(null, @src(), id);
    return std.math.clamp(t, 0, 1);
}

/// What `frostPane` hands to the replay. Lives in the data store under the owner's id, so the
/// pointer is good until the frame ends.
const FrostJob = struct {
    /// The pane's key (`frostPane`), for `behind`.
    id: dvui.Id = .zero,
    backdrop: *BlurBackdrop = undefined,
    corners: dvui.CornerRect = .{},
    scale: f32 = 1,
    rect: Rect.Physical = .{},
    tint: ?dvui.Color = null,
    mix: f32 = 0,
    lift: f32 = 0,
    /// 0…1: how much the glass's bevel bends, clears and lights (`motion.liquid`).
    lens: f32 = 0,
    /// How far the bevel refracts (`Pane.refraction`).
    refraction: f32 = 1,
    /// Shapes run together, drawn by the glass program, instead of the one rounded rect
    /// (`fieldPane`).
    field: ?LiquidField = null,
    /// Clear glass (`Pane.clear`): the picture before the blur.
    clear: bool = false,

    fn draw(ctx: ?*anyopaque) void {
        const self: *FrostJob = @ptrCast(@alignCast(ctx orelse return));
        const prof = @import("../profile.zig").begin("fizzy", "frost pane");
        defer prof.end();
        // At full alpha, whatever alpha the pane was queued under. The replay runs under the
        // alpha of the moment it was queued, and a pane drawn inside a fade — a tooltip fading in
        // under its own alpha — is queued at partial alpha; but a frost *replaces* what it covers,
        // so at partial alpha it writes a half-transparent patch — a hole to the desktop through
        // a see-through window. The glass fades by forming (`Pane.form`), never by alpha.
        const prev_alpha = dvui.currentWindow().alpha;
        dvui.alphaSet(1);
        defer dvui.alphaSet(prev_alpha);
        // The capture, now that everything below this pane is on the target.
        capturing = self.id;
        self.backdrop.deinit();
        capturing = null;
        // Through the glass program where there is one: the same pane in one pass a pixel.
        if (self.field) |field| {
            const tex = self.backdrop.small orelse return;
            var f = field;
            f.scale = self.scale;
            f.tint = self.tint;
            f.mix = self.mix;
            f.lift = self.lift;
            f.refraction = self.refraction;
            // Each shape's edge as far as the pane's has formed (and the motion level allows).
            for (f.shapes[0..f.len]) |*sh| {
                sh.lens *= self.lens;
                if (self.clear) sh.blur = 0;
            }
            const sharp = self.backdrop.sharpTexture();
            const distinct = if (sharp) |t| t.ptr != tex.ptr else false;
            _ = f.draw(tex, self.backdrop.coverage(), if (distinct) sharp else null);
            return;
        }
        if (self.drawField()) return;
        const weight: f32 = if (self.tint != null) 1 - self.mix else 1;
        self.drawFrost(weight);
        if (self.tint) |tint| addTint(self.rect, self.corners, self.scale, tint, self.mix);
        // The lift and the bevel's light, in one pass after the tint so they stay white.
        const lift: f32 = if (self.tint != null) self.lift else 0;
        if (liquid_glass.bends(.{ .lens = self.lens })) {
            if (additiveLight()) |light| liquid_glass.drawLift(light, self.rect, self.radii(), self.scale, lift, self.lens * @min(1, self.refraction));
        } else if (lift > 0) {
            addTint(self.rect, self.corners, self.scale, .white, lift);
        }
    }

    /// The pane as a one-shape `LiquidField`, drawn by the glass program. False where there is
    /// none, and the meshes draw it.
    fn drawField(self: *const FrostJob) bool {
        const tex = self.backdrop.small orelse return false;
        if (!LiquidField.ready()) return false;
        const c = self.finalCorners();
        const s = self.scale;
        var field: LiquidField = .{
            .scale = s,
            .tint = self.tint,
            .mix = self.mix,
            .lift = self.lift,
            .refraction = self.refraction,
        };
        field.add(.{
            .rect = self.rect,
            .radii = .{ c.tl.radius() * s, c.tr.radius() * s, c.br.radius() * s, c.bl.radius() * s },
            .lens = self.lens,
            .blur = if (self.clear) 0 else 1,
        });
        const sharp = self.backdrop.sharpTexture();
        const distinct = if (sharp) |t| t.ptr != tex.ptr else false;
        return field.draw(tex, self.backdrop.coverage(), if (distinct) sharp else null);
    }

    /// The frost at `weight` of itself: through a bevelled edge when the motion level asks for
    /// it (`liquid_glass`), a flat rect when it does not.
    fn drawFrost(self: *const FrostJob, weight: f32) void {
        const look: liquid_glass.Look = .{ .lens = self.lens, .refraction = self.refraction, .sharp = self.backdrop.sharpTexture(), .blend_over = &blendOver };
        const tex = self.backdrop.small orelse return;
        if (!liquid_glass.bends(look)) {
            self.backdrop.drawAt(self.rect, self.corners, self.scale, weight);
            return;
        }
        liquid_glass.drawPane(tex, self.backdrop.coverage(), self.rect, self.radii(), self.scale, dvui.Color.white.opacity(weight), look);
    }

    /// The pane's corner radii in physical pixels, in `liquid_glass`'s ring order.
    fn radii(self: *const FrostJob) liquid_glass.Radii {
        const c = self.finalCorners();
        const s = self.scale;
        return .{ c.tl.radius() * s, c.bl.radius() * s, c.br.radius() * s, c.tr.radius() * s };
    }

    /// The pane's corners as drawn: a theme corner resolved to the theme's own.
    fn finalCorners(self: *const FrostJob) dvui.CornerRect {
        const theme = dvui.themeGet();
        return self.corners.finalize(&theme);
    }
};

/// Fizzy addition: the rect `small` is a picture of (`covered`), or `rect` before any capture.
pub fn coverage(self: *const BlurBackdrop) Rect.Physical {
    return if (self.covered.w > 0 and self.covered.h > 0) self.covered else self.rect;
}

/// Fizzy addition: switch a frost texture between blending over what is under it and replacing
/// it, as a frost does across its face — for `liquid_glass.Look.blend_over`, which draws a pane's
/// one-pixel edge fade over what is behind so the curve is smooth.
pub fn blendOver(tex: Texture, over: bool) void {
    _ = tapsBlend(tex, if (over) .over else .copy);
}

/// Fizzy addition: the picture this backdrop blurred, before the blur — the copy of the rect the
/// pyramid starts from (half size at any real radius). Null when the capture read the window
/// back instead of copying it on the GPU, or the blur has no pyramid. Good until the next capture.
pub fn sharpTexture(self: *const BlurBackdrop) ?Texture {
    if (self.stable or self.mode != .readback) return null;
    const t = self.levels[0] orelse return null;
    return Texture.fromTargetTemp(t) catch null;
}

/// Fizzy addition: `drawRounded` at `weight` of itself — the frost half of a frost/tint mix.
/// The texture's copy blend writes exactly `weight * frost`, alpha included.
/// Fizzy addition: `rect` of the frost — any part of what it pictures, not only the rect it was
/// asked for (`frostPane` captures a size bucket around its pane) — at `weight`.
pub fn drawAt(self: *BlurBackdrop, rect: Rect.Physical, corners: dvui.CornerRect, scale: f32, weight: f32) void {
    const tex = self.small orelse return;
    const c = self.coverage();
    const uv: dvui.Rect = .{ .x = (rect.x - c.x) / c.w, .y = (rect.y - c.y) / c.h, .w = rect.w / c.w, .h = rect.h / c.h };
    dvui.renderTexture(tex, .{ .r = rect, .s = scale }, .{ .corners = corners, .colormod = dvui.Color.white.opacity(weight), .uv = uv }) catch {};
}

pub fn drawRoundedScaled(self: *BlurBackdrop, corners: dvui.CornerRect, scale: f32, weight: f32) void {
    const tex = self.small orelse return;
    dvui.renderTexture(tex, .{ .r = self.rect, .s = scale }, .{ .corners = corners, .colormod = dvui.Color.white.opacity(weight), .uv = self.rectUv() }) catch {};
}

/// Fizzy addition: the tint half of a frost/tint mix — `weight * tint` added onto `rect`, with
/// the window's corners. A 1×1 white texture that carries an additive blend, so it queues like
/// any other texture draw (a deferred floating window renders it later, blend intact).
pub fn addTint(rect: Rect.Physical, corners: dvui.CornerRect, scale: f32, tint: dvui.Color, weight: f32) void {
    const white = whiteTexture() orelse return;
    const w = std.math.clamp(weight, 0, 1);
    if (w <= 0.001) return;
    var c = tint;
    c.a = @intFromFloat(@round(@as(f32, @floatFromInt(tint.a)) * w));
    dvui.renderTexture(white, .{ .r = rect, .s = scale }, .{ .corners = corners, .colormod = c }) catch {};
}

/// Fizzy addition: the white texture tints are added with — anything drawn with it adds its
/// vertex colour onto what is there. Null where the backend cannot blend that way.
pub fn additiveWhite() ?Texture {
    return whiteTexture();
}

/// Fizzy addition: what a pane's lift and rim light add themselves with (`liquid_glass.drawLift`)
/// — a white that adds, dithered. A faint light fading over tens of pixels has a few dozen 8-bit
/// levels to do it in, and drawn in one flat white each level is a visible tread; the dither has
/// to be inside that same draw, since the frame rounds once per draw and noise added after would
/// only be added to the steps. So the white is an 8×8 ordered pattern a few percent under white
/// (`dither_depth`), tiled one texel to a screen pixel, and `gain` brings the mean back to what
/// was asked: each level's edge breaks into a pattern that averages to the true value. Falls back
/// to the plain white where the backend cannot keep the pattern.
pub fn additiveLight() ?liquid_glass.Light {
    if (lightDitherTexture()) |t| return .{ .tex = t, .gain = 1 / (1 - dither_depth * 63.0 / 128.0), .tile = bayer_size };
    const w = whiteTexture() orelse return null;
    return .{ .tex = w };
}

/// How far under white the pattern's darkest texel sits.
const dither_depth: f32 = 0.12;
var light_dither_tex: ?Texture = null;

fn lightDitherTexture() ?Texture {
    if (light_dither_tex) |t| return t;
    if (!dvui.Backend.support_texture_blend) return null;
    var px: [64]dvui.Color.PMA = undefined;
    for (0..8) |y| {
        for (0..8) |x| {
            var n: u8 = 0;
            var bit: u3 = 0;
            var xx = x;
            var yy = y;
            while (bit < 3) : (bit += 1) {
                const xb: u8 = @intCast(xx & 1);
                const yb: u8 = @intCast(yy & 1);
                n = n * 4 + (xb ^ yb) * 2 + yb;
                xx >>= 1;
                yy >>= 1;
            }
            const v: u8 = @intFromFloat(@round(255 * (1 - dither_depth * @as(f32, @floatFromInt(n)) / 64)));
            px[y * 8 + x] = .{ .r = v, .g = v, .b = v, .a = v };
        }
    }
    const t = dvui.textureCreate(&px, .{ .width = 8, .height = 8, .interpolation = .nearest, .wrap_u = .repeat, .wrap_v = .repeat }) catch return null;
    if (!tapsBlend(t, .add)) {
        dvui.textureDestroyLater(t);
        return null;
    }
    light_dither_tex = t;
    return t;
}

var white_tex: ?Texture = null;

fn whiteTexture() ?Texture {
    if (white_tex) |t| return t;
    if (!dvui.Backend.support_texture_blend) return null;
    const px = [_]dvui.Color.PMA{.{ .r = 255, .g = 255, .b = 255, .a = 255 }};
    const t = dvui.textureCreate(&px, .{ .width = 1, .height = 1, .interpolation = .nearest }) catch return null;
    if (!tapsBlend(t, .add)) {
        dvui.textureDestroyLater(t);
        return null;
    }
    white_tex = t;
    return t;
}

/// Fizzy addition: a frosted pane *replaces* what is under it. Drawn source-over, the frost of
/// a see-through window (alpha ~0.7) let 30% of the sharp content through, and the sharp edges
/// read as "not blurred". So the cached frost carries a copy blend: wherever it is drawn it
/// writes its own colour and alpha, and the OS's blur of the desktop shows through it exactly
/// as it did through the content. Set on the texture, not around the draw — the draw is
/// usually queued inside a floating window and runs at the end of the frame.
fn frostReplaces(self: *BlurBackdrop) void {
    if (self.small) |tex| _ = tapsBlend(tex, .copy);
}

/// Release the pyramid (and with it the cached texture). Never called directly by user code -
/// registered by `get` as the data store's deinit function for this key, so
/// dvui calls it exactly once, whenever the storage key is finally
/// reclaimed (e.g. the widget that owns it stops being touched).
pub fn releaseTexture(ptr: *anyopaque) void {
    const self: *BlurBackdrop = @ptrCast(@alignCast(ptr));
    self.releaseLevels();
    self.* = undefined;
}

/// Fizzy addition: the taps of one pass are a weighted *mean* of the source, and a mean is a
/// sum. Where the backend can blend additively each tap is drawn at its own weight and the
/// sum is exact for any source alpha. The fallback is upstream's running-weight source-over
/// (weights 1, ½, ⅓ …), which is only a mean when the source is opaque: a translucent source
/// — a see-through window read back, a pane photographed with its fill at content opacity —
/// gains ~20% colour *and* alpha per pass, alpha saturates, and the colour overshoots it into
/// glare. Returns whether additive is on; `tapsEnd` puts the texture's blend back.
/// The first tap of a pass *writes* (`.copy`) and the rest add: a reused level still holds
/// the last capture, and a copy over it is what a clear plus a sum would give, without the
/// clear's target switch and flush. The caller switches the source to `.add` after its first
/// draw. Without blend control the level is cleared here and the taps composite as before.
/// An additive tap's weight `w` (of `total`, with `before` handed out already) as a colormod.
/// The alpha is a byte, and truncating each tap's share on its own lost the remainder every
/// pass — 0.25 is 63/255, four of them 252/255 — so ~12 passes of a frost came out ~13% less
/// opaque and darker than what they blurred: a see-through window showed through the blur.
/// Cumulative rounding hands out whole bytes that always sum to exactly 255.
fn tapWeight(before: f32, w: f32, total: f32) dvui.Color {
    const lo: u8 = @intFromFloat(@round(255 * before / total));
    const hi: u8 = @intFromFloat(@round(255 * (before + w) / total));
    return .{ .r = 255, .g = 255, .b = 255, .a = hi - lo };
}

test "additive tap weights sum to exactly one" {
    var sum: u32 = 0;
    for (0..4) |i| sum += tapWeight(@floatFromInt(i), 1, 4).a;
    try std.testing.expectEqual(@as(u32, 255), sum);
    sum = 0;
    var before: f32 = 0;
    for ([_]f32{ 1, 2, 1, 2, 1, 2, 1, 2 }) |w| {
        sum += tapWeight(before, w, 12).a;
        before += w;
    }
    try std.testing.expectEqual(@as(u32, 255), sum);
}

fn tapsBegin(cur: Texture, into: Texture.Target) bool {
    if (tapsBlend(cur, .copy)) return true;
    into.clear();
    return false;
}

fn tapsBlend(tex: Texture, blend: dvui.Backend.TextureBlend) bool {
    if (!dvui.Backend.support_texture_blend) return false;
    dvui.currentWindow().backend.textureBlend(tex, blend) catch return false;
    return true;
}

fn tapsEnd(cur: Texture, add: bool) void {
    if (!add) return;
    dvui.currentWindow().backend.textureBlend(cur, .over) catch {};
}

/// How much of a full kawase pass's blur spread a size change from `a` to
/// `b` (in either order) is "worth": 1.0 for a full halving/doubling, down
/// to 0.0 for no size change at all. Used to scale tap offsets so a partial
/// leftover pass (whenever radius_px doesn't land on a clean power-of-two
/// fraction of the source size) contributes proportionally less blur,
/// instead of every pass - full or barely-there - applying the same fixed
/// offset. That fixed-offset behavior is what made `radius_px` feel like it
/// jumped in big steps: crossing the threshold where an extra pass kicks in
/// used to snap in a whole pass's worth of blur at once.
fn passStrength(a: u32, b: u32) f32 {
    const af: f32 = @floatFromInt(a);
    const bf: f32 = @floatFromInt(b);
    const ratio = @min(af, bf) / @max(af, bf);
    return @min(1.0, 2 * (1 - ratio));
}
