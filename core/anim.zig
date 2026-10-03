//! `core.anim` — reveals, cross-fades and transitions.
//!
//! One place for "what happens while the thing on screen changes", because fizzy had this twice:
//! a reveal keyed by document id for tab-content swaps, and a bespoke capture-and-fade for
//! surface swaps. `Layout.draw` still fades a first appearance through `reveal`; a swap that
//! must keep the outgoing pixels (center, a region's selected surface) goes through
//! `transition`, which can fade those pixels or blur them first.
//!
//! Sits under `core` rather than the layout because a plugin dylib animates its own content with
//! the same code — see `core.widgets` for the divide.
const std = @import("std");
const dvui = @import("dvui");
const motion = @import("motion.zig");
const builtin = @import("builtin");
const icons = @import("icons");
const platform = @import("platform.zig");
const reveal_phase = @import("reveal.zig");
const BlurBackdrop = @import("widgets/BlurBackdrop.zig");
const dialogs = @import("dialogs.zig");
const FrameTarget = @import("gfx/FrameTarget.zig");
pub const crossfade = @import("crossfade.zig");
pub const Kind = crossfade.Kind;

/// How a pane *travels* when the layout moves it: a region folding away, a sidebar coming back,
/// a document pane opening beside its neighbour.
///
/// Two curves rather than one, because opening and closing are not the same gesture. A pane
/// sliding **out** is arriving, and overshooting slightly (`outBack`) is what gives it weight —
/// it reads as a panel thrown into place. A pane sliding **in** is leaving, and must not
/// overshoot at all: `outBack` on the way to zero pulls the edge *past* the edge of the window
/// and snaps back, which reads as a glitch rather than a fold.
///
/// Durations are long enough to see. The first pass at this was 220ms in both directions with no
/// overshoot, which is the timing you pick when you are watching a split you dragged yourself;
/// watched from outside it reads as a jump-cut.
///
/// One home for them because three places move panes — `core.widgets.Split.eased`, the layout's
/// `Region`, and the pane tree — and a layout whose sidebar and whose documents slide at
/// different speeds feels broken in a way nobody can name.
pub const slide = struct {
    pub const out_ms: i32 = 380;
    pub const in_ms: i32 = 300;

    /// `opening` is "is the thing getting bigger", which is the only question either curve needs.
    pub fn ms(opening: bool) i32 {
        return if (opening) out_ms else in_ms;
    }

    pub fn easing(opening: bool) *const dvui.easing.EasingFn {
        return if (opening) motion.enter else motion.settle;
    }
};

/// Hides a pane for the single frame dvui needs to lay out newly-swapped content, then fades it
/// in — so switching store pages, document tabs or center providers reads as a quick cross-fade
/// instead of a flash of half-built layout. See `core/reveal.zig` for why that frame exists.
///
/// `key` identifies *what* is being shown (a plugin id hash, a document id, a center id). A new
/// key restarts the reveal; the same key every frame is free after the fade ends.
///
/// `id` must be a stable widget id for the pane itself — the reveal's own state lives under it.
/// Typically the enclosing box's `data().id`, which does not change when the content does.
///
///     var pane = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
///     defer pane.deinit();
///     const rv = core.anim.reveal(pane.data().id, doc_id, .{});
///     defer rv.deinit();
pub fn reveal(id: dvui.Id, key: u64, opts: RevealOptions) Reveal {
    const anim_key = "fizzy_reveal";
    const running = dvui.animationGet(id, anim_key) != null;

    const prev_key = dvui.dataGet(null, id, "fizzy_reveal_key", u64);
    const prev_phase = dvui.dataGet(null, id, "fizzy_reveal_phase", reveal_phase.Phase) orelse .shown;
    const phase = reveal_phase.next(prev_key, key, prev_phase, running);

    dvui.dataSet(null, id, "fizzy_reveal_key", key);
    dvui.dataSet(null, id, "fizzy_reveal_phase", phase);

    switch (phase) {
        .hidden => {
            // Nothing to animate yet — this frame exists only so dvui can measure. Ask for the
            // next one, otherwise an idle app would sleep with the pane still invisible.
            dvui.refresh(null, @src(), id);
            return .{ .prev_alpha = dvui.alpha(0), .value = 0 };
        },
        .fading => {
            if (!running) {
                dvui.animation(id, anim_key, .{ .start_time = 0, .end_time = motion.duration(opts.duration_micros) });
            }
            const v = if (dvui.animationGet(id, anim_key)) |a| std.math.clamp(a.value(), 0, 1) else 1;
            return .{ .prev_alpha = dvui.alpha(v), .value = v };
        },
        .shown => return .{ .prev_alpha = dvui.currentWindow().alpha, .value = 1 },
    }
}

pub const RevealOptions = struct {
    /// Short on purpose: long enough to hide the settle frame and read as intentional, short
    /// enough that switching tabs still feels instant. Matches `CanvasWidget`'s reveal.
    duration_micros: i32 = 120_000,
};

/// Restores the alpha `reveal` multiplied. Always `defer`red immediately after the call.
pub const Reveal = struct {
    prev_alpha: f32,
    /// How far the fade has got, 0 (hidden) to 1 (fully revealed).
    value: f32,

    pub fn deinit(self: Reveal) void {
        dvui.alphaSet(self.prev_alpha);
    }
};

/// A swap between two entirely different subtrees, for cases where revealing the incoming
/// content is not enough on its own.
///
/// `reveal` works when the pane's chrome stays put and only its contents change (a document tab,
/// a store page). It cannot work when the *background is part of what changes*: center providers
/// each paint their own pane — the workbench's document canvas is square and full-bleed, the
/// homepage, the pack-project window and the store's detail page are rounded cards — so fading
/// the incoming one up from nothing exposes the window behind it, and the corner shape visibly
/// changes mid-swap. There is no backdrop the host could draw that is right for both.
///
/// So don't guess: keep the pixels. The last frame of the outgoing screen is recorded into a
/// texture (`dvui.Picture` redirects rendering into a render target) and drawn *over* the
/// incoming subtree. A fade just drops that overlay's alpha. A blur runs a dual-Kawase pass
/// on it first, then dissolves — the incoming view is whatever is drawing live underneath.
/// See `core/crossfade.zig` for the clock.
///
/// Prefer `transition` for call sites — it owns swap detection, capture isolation, and teardown.
/// `CrossFade` remains the low-level primitive those helpers drive.
///
/// The caller owns the state (one per swapping region) and must `discard` it on teardown.
pub const CrossFade = struct {
    /// Owned outright — not in dvui's texture cache, so it survives across frames and must be
    /// destroyed explicitly.
    texture: ?dvui.Texture = null,
    /// Full-res Kawase frost of `texture`. Built at capture so the dissolve is
    /// two quads a frame. Dropped with `texture`.
    frost: Frost = .{},
    incoming: ?dvui.Texture = null,
    /// The incoming snapshot's frost — what "sharpens in" over the live incoming view.
    incoming_frost: Frost = .{},
    /// Physical rect matching the captured texture exactly (`Picture.start` enlarges to pixel
    /// boundaries; blitting a smaller rect would sample the wrong UVs).
    rect: dvui.Rect.Physical = .{},
    incoming_rect: dvui.Rect.Physical = .{},
    /// The place itself, when the snapshots take in a margin around it for the blur to bleed
    /// into (`TransitionOptions.bleed`): the overlay covers this fully and fades out across the
    /// margin. Null — the overlay covers `rect` edge to edge.
    inner: ?dvui.Rect.Physical = null,
    start_ns: i128 = 0,
    duration_ns: i128 = crossfade.fade_ns,
    /// Shapes the clock before the kind's curves read it (`TransitionOptions.easing`).
    easing: *const fn (f32) f32 = dvui.easing.linear,
    kind: Kind = .fade,
    /// The snapshots carry their region's backdrop, so they are opaque wherever they cover and
    /// blend exactly with plain source-over (`blitOpaque`).
    opaque_snapshots: bool = false,
    /// Frames to wait after the outgoing capture before photographing the incoming view —
    /// one settle frame under the opaque overlay.
    incoming_wait: u8 = 0,
    have_incoming: bool = false,

    /// Begin recording instead of drawing to the screen. Null when the backend has no
    /// texture targets (web), the region is empty or the frame is unseen
    /// (`FrameTarget.unseen`) — callers then swap without a fade, which is exactly the old
    /// behaviour rather than a broken one.
    pub fn beginCapture(rect: dvui.Rect.Physical) ?dvui.Picture {
        if (FrameTarget.unseen()) return null;
        var pic = dvui.Picture.start(rect) orelse return null;
        // `textureCreateTarget` claims to start transparent, but some backends leave
        // `textureClearTarget` unimplemented — clear explicitly so pixel-boundary padding
        // around the content never samples uninitialized target memory.
        pic.texture.clear();
        return pic;
    }

    /// Take ownership of what `beginCapture` recorded as the *outgoing* snapshot.
    ///
    /// Deliberately not `dvui.Picture.deinit`, which draws the texture and destroys it — the
    /// whole point is to keep it for later frames. Any snapshot still fading is dropped first,
    /// so switching rapidly always fades from the most recent frame rather than stacking.
    ///
    /// The blit rect is `pic.r` (the pixel-enlarged capture), not the caller's original rect —
    /// those can disagree by up to 1px per edge after `Picture.start`'s `@floor`/`@ceil`.
    pub fn endCapture(self: *CrossFade, pic: *dvui.Picture) void {
        pic.stop();
        // Consumes the render target (destroying it) and hands back a sampleable texture.
        const tex = dvui.textureFromTarget(pic.texture) catch return;
        self.discard();
        self.texture = tex;
        self.rect = pic.r;
        self.start_ns = dvui.currentWindow().frame_time_ns;
        if (self.kind != .fade) self.frost.prepare(tex);
    }

    /// Take ownership of an *incoming* snapshot. Does not restart the clock or drop the
    /// outgoing texture — both stay up for the handoff.
    pub fn endIncoming(self: *CrossFade, pic: *dvui.Picture) void {
        pic.stop();
        const tex = dvui.textureFromTarget(pic.texture) catch {
            self.have_incoming = true;
            return;
        };
        if (self.incoming) |old| dvui.Texture.destroyLater(old);
        self.incoming = tex;
        self.incoming_rect = pic.r;
        self.have_incoming = true;
    }

    /// Draw the snapshot(s) over what was just drawn. Call last, and every frame — it is a
    /// no-op with nothing captured. `pending` freezes the timeline at the hold pose.
    pub fn draw(self: *CrossFade, pending: bool) void {
        if (self.texture == null and self.incoming == null) return;

        const t = self.progress(pending);
        if (t >= 1 and !pending) {
            self.discard();
            return;
        }

        const s = crossfade.sample(self.kind, std.math.clamp(self.easing(t), 0, 1), pending);
        // Bottom to top: the live incoming view (drawn by the caller), its own frost thinning
        // over it, then the outgoing snapshot. Both snapshots carry the region's backdrop
        // (`TransitionOptions.backdrop`), so neither has transparent holes for the blur to
        // spread into — which is what once made a second layer read as grey glare.
        const mode: BlitMode = if (self.opaque_snapshots) .over else .lerp;
        if (self.incoming) |tex| blitWith(tex, &self.incoming_frost, self.incoming_rect, self.inner, s.in_blur, s.in_alpha, mode);
        if (self.texture) |tex| blitWith(tex, &self.frost, self.rect, self.inner, s.out_blur, s.out_alpha, mode);

        // Nothing else is animating, so without this an idle app would sleep mid-fade.
        dvui.refresh(null, @src(), null);
    }

    fn progress(self: *CrossFade, pending: bool) f32 {
        const now = dvui.currentWindow().frame_time_ns;
        if (pending) {
            // Park the clock at the pose `sample(..., pending)` will report, so when the
            // hold lifts the remaining timeline starts from there rather than from wherever
            // wall time has wandered.
            // The clock is eased before it is read, so park where the *eased* clock is at the
            // hold.
            const parked: f32 = switch (self.kind) {
                .fade => 0,
                .blur, .frost => easedTimeOf(self.easing, crossfade.hold),
            };
            const parked_ns: i128 = @intFromFloat(@as(f64, parked) * @as(f64, @floatFromInt(self.duration_ns)));
            self.start_ns = now - parked_ns;
            return parked;
        }
        if (self.duration_ns <= 0) return 1;
        const elapsed = now - self.start_ns;
        if (elapsed >= self.duration_ns) return 1;
        return @floatCast(@as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(self.duration_ns)));
    }

    pub fn discard(self: *CrossFade) void {
        if (self.texture) |tex| dvui.Texture.destroyLater(tex);
        self.frost.drop();
        if (self.incoming) |tex| dvui.Texture.destroyLater(tex);
        self.incoming_frost.drop();
        self.texture = null;
        self.incoming = null;
        self.have_incoming = false;
        self.incoming_wait = 0;
    }
};

/// One full-res Kawase frost of a captured snapshot. Built at capture so the
/// dissolve is two quads a frame, not a stall. Dropped with the snapshot.
pub const Frost = struct {
    texture: ?dvui.Texture = null,
    tried: bool = false,

    pub fn prepare(self: *Frost, sharp: dvui.Texture) void {
        if (self.tried) return;
        self.tried = true;
        const radius = blurRadius();
        if (radius < 1) return;
        self.texture = BlurBackdrop.blurred(sharp, radius);
    }

    pub fn drop(self: *Frost) void {
        if (self.texture) |t| dvui.Texture.destroyLater(t);
        self.* = .{};
    }
};

/// How far a transition blurs: the app's one blur setting, the radius dialogs frost with
/// (`core.dialogs.Style.blur`). Below 1 the blur is off, and every swap is a plain fade — there
/// is nothing to blur between.
pub fn blurRadius() f32 {
    return dialogs.style().blur;
}

/// The clock time at which `easing` reaches `v`: bisected, so any monotonic curve works (an
/// overshooting one gives its first crossing).
fn easedTimeOf(easing: *const fn (f32) f32, v: f32) f32 {
    var lo: f32 = 0;
    var hi: f32 = 1;
    for (0..24) |_| {
        const mid = (lo + hi) / 2;
        if (easing(mid) < v) lo = mid else hi = mid;
    }
    return (lo + hi) / 2;
}

test "a held swap parks where the eased clock is at the hold" {
    const t = easedTimeOf(dvui.easing.outCubic, crossfade.hold);
    try testing.expectApproxEqAbs(crossfade.hold, dvui.easing.outCubic(t), 1e-4);
    try testing.expectApproxEqAbs(crossfade.hold, easedTimeOf(dvui.easing.linear, crossfade.hold), 1e-4);
}

/// The app's swap curve — every `transition` unless it asks for another.
pub const swap_easing = motion.fade;

/// Which edges of a place a swap's blur bleeds across (`TransitionOptions.bleed`).
pub const Bleed = packed struct {
    top: bool = false,
    right: bool = false,
    bottom: bool = false,
    left: bool = false,

    pub const none: Bleed = .{};
    pub const all: Bleed = .{ .top = true, .right = true, .bottom = true, .left = true };

    fn any(self: Bleed) bool {
        return self.top or self.right or self.bottom or self.left;
    }

    /// `r` grown by `w` on each bleeding edge.
    fn outset(self: Bleed, r: dvui.Rect.Physical, w: f32) dvui.Rect.Physical {
        const t: f32 = if (self.top) w else 0;
        const l: f32 = if (self.left) w else 0;
        return .{
            .x = r.x - l,
            .y = r.y - t,
            .w = r.w + l + (if (self.right) w else 0),
            .h = r.h + t + (if (self.bottom) w else 0),
        };
    }
};

/// How far past its place a bleeding blur spreads (`TransitionOptions.bleed`), in physical
/// pixels: about as far as the blur itself reaches.
pub fn bleedWidth() f32 {
    return 2 * blurRadius();
}

/// `kind` as the blur setting allows it: a blur or frost with the blur off is a fade.
pub fn effectiveKind(kind: Kind) Kind {
    return if (kind != .fade and blurRadius() < 1) .fade else kind;
}

/// Draw a captured overlay. `blur` 0 is a sharp blit. Above that, mix the
/// snapshot with its one Kawase frost so the ramp is a defocus, not a snap.
pub fn blit(tex: dvui.Texture, frost: ?*Frost, dest: dvui.Rect.Physical, blur: f32, alpha: f32) void {
    blitWith(tex, frost, dest, null, blur, alpha, .lerp);
}

/// `blit` for a snapshot that is opaque wherever it covers (it carries its backdrop —
/// `TransitionOptions.backdrop`). Plain source-over is exact for it: `a` of the snapshot where it
/// covers, and untouched frame where it is transparent. `blit`'s lerp is for translucent
/// snapshots, and it scales *every* pixel of the rect — including a rounded region's corners,
/// where the snapshot has nothing, which then flashed as square corners at the start of a swap.
pub fn blitOpaque(tex: dvui.Texture, frost: ?*Frost, dest: dvui.Rect.Physical, blur: f32, alpha: f32) void {
    blitWith(tex, frost, dest, null, blur, alpha, .over);
}

const BlitMode = enum { lerp, over };

/// `inner`, when set, is the part of `dest` covered fully; across the margin between them the
/// snapshot fades out to nothing, so a blur that bleeds past its place feathers into what is
/// there instead of ending at a hard edge.
fn blitWith(tex: dvui.Texture, frost: ?*Frost, dest: dvui.Rect.Physical, inner: ?dvui.Rect.Physical, blur: f32, alpha: f32, mode: BlitMode) void {
    if (alpha <= 0.001) return;
    if (frost) |f| {
        if (blur > 0.001) f.prepare(tex);
    }

    var r = dest;
    r.x = @round(r.x);
    r.y = @round(r.y);
    r.w = @round(r.w);
    r.h = @round(r.h);
    if (r.w < 1 or r.h < 1) return;

    const prev_clip = dvui.clipGet();
    dvui.clipSet(prev_clip.intersect(r));
    defer dvui.clipSet(prev_clip);

    const mix = std.math.clamp(blur, 0, 1);
    const frost_tex: ?dvui.Texture = if (frost) |f| f.texture else null;
    const use_frost = mix > 0.001 and frost_tex != null;

    // A snapshot of a translucent pane (fizzy's are, at content opacity) drawn source-over lets
    // `(1 - snapshot alpha)` of the live view through even at full overlay alpha — the sharp
    // incoming view showing through its own blur, which reads as contour rings on pixel art.
    // What a dissolve means is `dst = (1 - a) * dst + a * snapshot`; no single blend factor
    // does that, but two do: copy `(1 - a) * under` (the frame, read back from its target),
    // then add `a * snapshot`. Only immediate rendering can do it — a deferred draw would
    // queue the blend changes out of order — so a floating card's sharp blit takes the
    // plain path below, where alpha 1 over an opaque card is exact anyway.
    if (mode == .lerp) if (lerpUnder(r, inner, alpha)) |under| {
        defer dvui.textureDestroyLater(under);
        const a = alpha * dvui.currentWindow().alpha;
        const prev_alpha = dvui.alpha(1);
        defer dvui.alphaSet(prev_alpha);
        if (!use_frost) {
            addOne(tex, r, inner, a);
        } else {
            addOne(frost_tex.?, r, inner, a * mix);
            addOne(tex, r, inner, a * (1 - mix));
        }
        return;
    };
    // Deferred or without blend control: no feathering, the place alone.
    if (inner) |in| dvui.clipSet(dvui.clipGet().intersect(in));

    if (!use_frost) {
        blitOne(tex, r, alpha);
        return;
    }
    // t=1 is only sharp; t=0 is only frost.
    blitPair(frost_tex.?, tex, r, 1 - mix, alpha);
}

/// The first half of the lerp: `r` of the bound target, copied out and written back scaled by
/// `1 - alpha`. Null (nothing drawn) when the backend cannot: no target bound, no blend
/// control, or rendering deferred. The returned copy is the caller's to destroy.
fn lerpUnder(r: dvui.Rect.Physical, inner: ?dvui.Rect.Physical, alpha: f32) ?dvui.Texture {
    if (!dvui.Backend.support_texture_blend) return null;
    const under = copyFrame(r) orelse return null;
    const cw = dvui.currentWindow();
    // Written back with a copy blend, so the region holds exactly `(1 - a) * under`.
    cw.backend.textureBlend(under, .copy) catch {
        dvui.textureDestroyLater(under);
        return null;
    };
    const prev_alpha = dvui.alpha(1);
    defer dvui.alphaSet(prev_alpha);
    const keep = 1 - std.math.clamp(alpha * prev_alpha, 0, 1);
    // Across a feathered margin the frame is kept more and more, all of it at the outer edge.
    drawFeathered(under, r, inner, keep, 1);
    return under;
}

/// What the frame being drawn holds under `r`, copied out of the bound target: the true pixels,
/// window translucency and all. Null when there is no target to read (rendering straight to the
/// screen, or deferred). The copy is the caller's to destroy.
fn copyFrame(r: dvui.Rect.Physical) ?dvui.Texture {
    const cw = dvui.currentWindow();
    if (!cw.render_target.rendering) return null;
    const bound = cw.render_target.texture orelse return null;
    const src = dvui.Texture.fromTargetTemp(bound) catch return null;
    const w: u32 = @intFromFloat(r.w);
    const h: u32 = @intFromFloat(r.h);
    const step = dvui.textureCreateTarget(.{ .width = w, .height = h, .interpolation = .nearest }) catch return null;
    var rt = cw.render_target;
    const off = rt.offset;
    rt.texture = step;
    rt.offset = .{};
    const prev = dvui.renderTarget(rt);
    {
        const prev_clip = dvui.clipGet();
        defer dvui.clipSet(prev_clip);
        dvui.clipSet(.{ .w = r.w, .h = r.h });
        const prev_alpha = dvui.alpha(1);
        defer dvui.alphaSet(prev_alpha);
        const sw: f32 = @floatFromInt(src.width);
        const sh: f32 = @floatFromInt(src.height);
        dvui.renderTexture(src, .{ .r = .{ .w = r.w, .h = r.h }, .s = 1 }, .{
            .uv = .{ .x = (r.x - off.x) / sw, .y = (r.y - off.y) / sh, .w = r.w / sw, .h = r.h / sh },
        }) catch {};
    }
    _ = dvui.renderTarget(prev);
    return dvui.textureFromTarget(step) catch null;
}

/// `weight * tex` added onto the target. The texture's blend is put back to source-over after.
fn addOne(tex: dvui.Texture, dest: dvui.Rect.Physical, inner: ?dvui.Rect.Physical, weight: f32) void {
    if (weight <= 0.001) return;
    const cw = dvui.currentWindow();
    cw.backend.textureBlend(tex, .add) catch return;
    defer cw.backend.textureBlend(tex, .over) catch {};
    drawFeathered(tex, dest, inner, weight, 0);
}

/// `tex` over `outer`, every channel scaled by `in_w` over `inner` and ramping linearly to
/// `out_w` at `outer`'s edge. No `inner`: `in_w` over all of `outer`. Immediate rendering only.
fn drawFeathered(tex: dvui.Texture, outer: dvui.Rect.Physical, inner: ?dvui.Rect.Physical, in_w: f32, out_w: f32) void {
    const in = inner orelse {
        dvui.renderTexture(tex, .{ .r = outer, .s = 1 }, .{ .colormod = dvui.Color.white.opacity(in_w) }) catch {};
        return;
    };
    const lifo = dvui.currentWindow().lifo();
    var b = dvui.Triangles.Builder.init(lifo, 8, 30) catch return;
    defer b.deinit(lifo);
    const rects = [2]dvui.Rect.Physical{ in, outer };
    const weights = [2]f32{ in_w, out_w };
    // Inner corners 0…3, outer 4…7, each clockwise from the top left.
    for (rects, weights) |rr, w| {
        const c: u8 = @intFromFloat(@round(255 * std.math.clamp(w, 0, 1)));
        const col: dvui.Color.PMA = .{ .r = c, .g = c, .b = c, .a = c };
        for ([4]dvui.Point.Physical{ rr.topLeft(), rr.topRight(), rr.bottomRight(), rr.bottomLeft() }) |p| {
            b.appendVertex(.{ .pos = p, .col = col, .uv = .{ (p.x - outer.x) / outer.w, (p.y - outer.y) / outer.h } });
        }
    }
    b.appendTriangles(&.{ 0, 1, 2, 0, 2, 3 });
    for (0..4) |i| {
        const j = (i + 1) % 4;
        const idx = [6]dvui.Vertex.Index{ @intCast(4 + i), @intCast(4 + j), @intCast(j), @intCast(4 + i), @intCast(j), @intCast(i) };
        b.appendTriangles(&idx);
    }
    dvui.renderTriangles(b.build_unowned(), tex) catch {};
}

/// `top` over `bottom` at mix `t` (1 = only top), covering exactly `alpha`
/// of the live view. The previous formula filled coverage with the sharp
/// layer on top, so frost was invisible until mix hit 1 — that snap is the
/// pop. Weights here are `alpha * t` of top and `alpha * (1-t)` of bottom.
fn mixAlphas(top_t: f32, alpha: f32) struct { bot: f32, top: f32 } {
    const t = std.math.clamp(top_t, 0, 1);
    const a = std.math.clamp(alpha, 0, 1);
    if (t >= 0.999) return .{ .bot = 0, .top = a };
    if (t <= 0.001) return .{ .bot = a, .top = 0 };
    const top_a = a * t;
    const bot_a = if (top_a >= 0.999) 0 else a * (1 - t) / (1 - top_a);
    return .{ .bot = bot_a, .top = top_a };
}

fn blitPair(bottom: dvui.Texture, top: dvui.Texture, dest: dvui.Rect.Physical, t: f32, alpha: f32) void {
    if (bottom.ptr == top.ptr) {
        blitOne(top, dest, alpha);
        return;
    }
    const a = mixAlphas(t, alpha);
    blitOne(bottom, dest, a.bot);
    blitOne(top, dest, a.top);
}

fn blitOne(tex: dvui.Texture, dest: dvui.Rect.Physical, alpha: f32) void {
    if (alpha <= 0.001) return;
    dvui.renderTexture(tex, .{ .r = dest, .s = 1 }, .{
        .colormod = dvui.Color.white.opacity(alpha),
    }) catch {};
}

/// Host-owned state for one "one of N screens" region. Pair with `transition` each frame.
pub const Transition = struct {
    cross_fade: CrossFade = .{},
    prev_key: ?u64 = null,
    /// Last surface drawn in this slot, so a swap can look the outgoing one up by id
    /// (never cache the pointer: a plugin can unload between frames).
    prev_id: []const u8 = "",
    /// Latch: hold at peak-blur outgoing until the incoming view is ready. Cleared by
    /// the caller; `transition` also accepts a per-frame flag.
    pending: bool = false,

    pub fn discard(self: *Transition) void {
        self.cross_fade.discard();
        self.prev_key = null;
        self.prev_id = "";
        self.pending = false;
    }
};

pub const TransitionOptions = struct {
    /// Identifies *what* is showing now (hash of a center id, document id, …). A new key on a
    /// subsequent frame triggers the capture of `draw_previous`.
    key: u64,
    /// Physical region to capture / blit. Typically the parent's `contentRectScale().r`.
    rect: dvui.Rect.Physical,
    /// Blur out / hand off / unblur in — the app's swap, everywhere a view changes — or just fade
    /// the outgoing snapshot. A blur with the blur setting off fades (`effectiveKind`).
    kind: Kind = .blur,
    /// Hold at the outgoing peak this frame. Or set `Transition.pending` and leave this false.
    pending: bool = false,
    /// Override the kind's default duration. Null uses `crossfade.durationNs`.
    duration_ns: ?i128 = null,
    /// Any `dvui.easing` curve, applied to the clock before the blur and fade read it. Out-curves
    /// front-load the swap: the old view is gone quickly and the new one spends the rest of
    /// the duration sharpening. Overshooting curves are clamped.
    easing: *const fn (f32) f32 = swap_easing,
    /// How to draw the *outgoing* screen. Called only on the swap frame, and only when the
    /// backend supports render targets. Ignored when `key` is unchanged or this is the first
    /// frame for the region.
    ///
    /// Must run under the **same parent** the screen used last frame (stable widget ids). A
    /// temporary isolate parent gives every widget a new id, which restarts `reveal` at alpha 0
    /// and freezes min-size caches — the capture comes out empty/wrong and there is no fade.
    draw_previous: ?*const fn (*anyopaque) void = null,
    /// What is behind the region: each snapshot is filled with it before the view is drawn into
    /// it, so a view that paints only part of its area (the region's fill is not its own)
    /// photographs as it looks on screen rather than with transparent holes.
    backdrop: ?Backdrop = null,
    /// The edges across which the blur spreads past `rect` and feathers into what is around it,
    /// rather than stop at it. The snapshots take in a margin of the frame as it stands there
    /// (`bleedWidth`), the views still draw only within `rect`, and the overlay fades out across
    /// the margin. Leave out an edge whose neighbour is part of the place's own chrome (a title
    /// drawn above it) — the margin would photograph that too, and blur it with the swap.
    bleed: Bleed = .none,
    /// Called after a successful capture, before the incoming screen packs. Use it to clear the
    /// parent's pack state so the capture's expanded child does not make the incoming one trip
    /// `rectFor() got child after expanded child`.
    after_capture: ?*const fn (*anyopaque) void = null,
    ctx: *anyopaque = undefined,
};

/// What is on screen behind a region's contents, rebuilt in a snapshot: the window `base` (opaque
/// — a snapshot has nothing further behind it), then the region's own `fill` over it. A region's
/// fill is translucent at the window's content opacity, so on screen it is what it is only over
/// the window; alone in a texture it came out lighter, and the swap read as a haze.
pub const Backdrop = struct {
    base: dvui.Color,
    fill: dvui.Color,
    corners: dvui.CornerRect.Physical = .{},
};

/// Start a snapshot of `rect` over what is behind it: the frame's own pixels under it when they
/// can be read (exact whoever painted them — the region, or a card further out — and its
/// corners match the frame, so `blit`'s lerp is exact over them), else the `Backdrop` rebuilt
/// from colours, which only `blitOpaque` blends correctly, else nothing.
fn beginBackdropCapture(cf: *CrossFade, place: dvui.Rect.Physical, backdrop: ?Backdrop) ?dvui.Picture {
    // Before the frame is copied: a frame nobody sees has no snapshot to take (`beginCapture`).
    if (FrameTarget.unseen()) return null;
    // On the whole pixels `Picture.start` grows the snapshot to, not the place's fractional
    // rect: the frame pasted at the fractional one left the snapshot's left/top edge a
    // part-covered pixel — a 1px seam wherever the view drew nothing over it.
    const rect = pixelBounds(place);
    const under = copyFrame(rect);
    var pic = CrossFade.beginCapture(rect) orelse {
        if (under) |u| dvui.textureDestroyLater(u);
        return null;
    };
    // Under the snapshot's own rect, not the caller's clip: a transition that bleeds past its
    // place (`TransitionOptions.bleed`) is called from inside that place's clip, and pasting
    // the frame under it left the margin transparent — the blur then pulled that in, and the
    // window showed through as a lighter band.
    const prev_clip = dvui.clipGet();
    dvui.clipSet(pic.r);
    defer dvui.clipSet(prev_clip);
    if (under) |u| {
        defer dvui.textureDestroyLater(u);
        const prev_alpha = dvui.alpha(1);
        defer dvui.alphaSet(prev_alpha);
        dvui.renderTexture(u, .{ .r = rect, .s = 1 }, .{}) catch {};
        cf.opaque_snapshots = false;
    } else if (backdrop != null) {
        fillBackdrop(rect, backdrop);
        cf.opaque_snapshots = true;
    }
    _ = &pic;
    return pic;
}

/// `r` grown out to whole pixels — the rect `dvui.Picture.start` records.
fn pixelBounds(r: dvui.Rect.Physical) dvui.Rect.Physical {
    const x = @floor(r.x);
    const y = @floor(r.y);
    return .{ .x = x, .y = y, .w = @round(@ceil(r.x + r.w) - x), .h = @round(@ceil(r.y + r.h) - y) };
}

fn fillBackdrop(rect: dvui.Rect.Physical, backdrop: ?Backdrop) void {
    const b = backdrop orelse return;
    var base = b.base;
    base.a = 255;
    // Both rounded like the region: beyond its corners the snapshot stays transparent, so the
    // live frame shows there as it does on screen, not a square of window colour.
    rect.fill(b.corners, .{ .color = .{ .color = base } });
    rect.fill(b.corners, .{ .color = .{ .color = b.fill } });
}

/// Per-frame handle from `transition`. `defer` its `deinit` so the snapshot is blitted after
/// the incoming content draws — and so an incoming capture started this frame is saved.
pub const TransitionFrame = struct {
    cross_fade: *CrossFade,
    incoming: ?dvui.Picture = null,
    prev_clip: ?dvui.Rect.Physical = null,
    pending: bool = false,
    /// The snapshots' rect when it bleeds past the caller's clip (`TransitionOptions.bleed`):
    /// the overlay is drawn over all of it.
    reach: ?dvui.Rect.Physical = null,

    pub fn deinit(self: *TransitionFrame) void {
        if (self.incoming) |*pic| {
            self.cross_fade.endIncoming(pic);
            if (self.prev_clip) |c| dvui.clipSet(c);
        }
        const clip = dvui.clipGet();
        if (self.reach) |r| dvui.clipSet(r);
        defer dvui.clipSet(clip);
        self.cross_fade.draw(self.pending);
    }
};

/// Cross-fade (or blur-fade) between screens in a host-owned region. Plugins draw normally;
/// the host wraps the swap so the outgoing frame is captured and drawn over the incoming one.
///
///     var frame = core.anim.transition(&state, .{
///         .key = current_key,
///         .rect = rs.r,
///         .kind = .blur,
///         .pending = plugin_not_ready,
///         .draw_previous = drawOutgoing,
///         .ctx = ctx,
///     });
///     defer frame.deinit();
///     drawIncoming();
///
/// On backends without render targets the capture is skipped and the swap is instant — same as
/// before `CrossFade` existed.
///
/// The capture pass re-draws the outgoing screen under the **current parent** so widget ids match
/// last frame (`reveal` stays shown, min-size caches stay warm). That packs an expanded child
/// into the parent; the caller must clear pack state in `after_capture` before drawing the
/// incoming screen, or dvui logs `rectFor() got child after expanded child` and paints a red
/// `errorOutline`.
pub fn transition(state: *Transition, opts: TransitionOptions) TransitionFrame {
    const had_prev = state.prev_key != null;
    const key_changed = !had_prev or state.prev_key.? != opts.key;
    const pending = opts.pending or state.pending;
    // A fade has no blur to bleed.
    const bleeding = opts.bleed.any() and effectiveKind(opts.kind) != .fade;
    const rect = if (bleeding) opts.bleed.outset(opts.rect, bleedWidth()).intersect(dvui.windowRectPixels()) else opts.rect;

    if (had_prev and key_changed) {
        const kind = effectiveKind(opts.kind);
        state.cross_fade.kind = kind;
        state.cross_fade.inner = if (bleeding) opts.rect else null;
        state.cross_fade.opaque_snapshots = false;
        state.cross_fade.duration_ns = opts.duration_ns orelse crossfade.durationNs(kind);
        state.cross_fade.easing = opts.easing;
        if (FrameTarget.unseen()) {
            // Swapped in a frame nobody sees: nothing to fade from in the next one shown — and
            // no fade left from before, which would play over the new view under its settings.
            state.cross_fade.discard();
        } else if (opts.draw_previous) |draw_prev| {
            if (beginBackdropCapture(&state.cross_fade, rect, opts.backdrop)) |captured| {
                var pic = captured;
                // The outgoing view draws where it lives: within `opts.rect` and the caller's
                // clip. Restored afterward so the incoming screen sees the normal clip.
                const prev_clip = dvui.clip(opts.rect);
                draw_prev(opts.ctx);
                dvui.clipSet(prev_clip);
                state.cross_fade.endCapture(&pic);
                if (opts.after_capture) |cb| cb(opts.ctx);
            }
        }
    }

    state.prev_key = opts.key;

    // A blur swap also photographs the incoming view once, a settle frame after the swap (the
    // first frame it draws has no sizes from last frame and is not what it will look like),
    // so `CrossFade.draw` can sharpen it in. Fade does not need it.
    var frame: TransitionFrame = .{
        .cross_fade = &state.cross_fade,
        .pending = pending,
        .reach = if (bleeding) rect else null,
    };
    const cf = &state.cross_fade;
    if (cf.kind == .blur and cf.texture != null and cf.incoming == null and !cf.have_incoming and !key_changed) {
        if (cf.incoming_wait < 1) {
            cf.incoming_wait += 1;
        } else if (beginBackdropCapture(cf, rect, opts.backdrop)) |pic| {
            frame.incoming = pic;
            frame.prev_clip = dvui.clip(opts.rect);
        }
    }
    return frame;
}

const testing = std.testing;

test "mix alphas lerp two opaque layers without a snap at 1" {
    const mid = mixAlphas(0.5, 1);
    // bottom fully drawn, top at 0.5 over it → 50/50, not "sharp covering frost"
    try testing.expectApproxEqAbs(@as(f32, 1), mid.bot, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), mid.top, 1e-5);
    const coverage = mid.bot + mid.top * (1 - mid.bot);
    try testing.expectApproxEqAbs(@as(f32, 1), coverage, 1e-5);
    const frost_w = mid.bot * (1 - mid.top);
    try testing.expectApproxEqAbs(@as(f32, 0.5), frost_w, 1e-5);
}

test "mix alphas keep coverage equal to overlay alpha while fading" {
    const a = mixAlphas(0.5, 0.5);
    const coverage = a.bot + a.top * (1 - a.bot);
    try testing.expectApproxEqAbs(@as(f32, 0.5), coverage, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.25), a.top, 1e-5);
}
