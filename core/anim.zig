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
const builtin = @import("builtin");
const icons = @import("icons");
const platform = @import("platform.zig");
const reveal_phase = @import("reveal.zig");
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
/// `Region`, and `core.widgets.Panes` — and a layout whose sidebar and whose documents slide at
/// different speeds feels broken in a way nobody can name.
pub const slide = struct {
    pub const out_ms: i32 = 380;
    pub const in_ms: i32 = 300;

    /// `opening` is "is the thing getting bigger", which is the only question either curve needs.
    pub fn ms(opening: bool) i32 {
        return if (opening) out_ms else in_ms;
    }

    pub fn easing(opening: bool) *const dvui.easing.EasingFn {
        return if (opening) dvui.easing.outBack else dvui.easing.outQuint;
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
                dvui.animation(id, anim_key, .{ .start_time = 0, .end_time = opts.duration_micros });
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
/// incoming subtree. A fade just drops that overlay's alpha. A blur smears it first, crosses
/// to a snapshot of the incoming view (itself fully smeared, so a settle frame or a plugin
/// load can happen underneath), then unsmears. See `core/crossfade.zig` for the clock.
///
/// Prefer `transition` for call sites — it owns swap detection, capture isolation, and teardown.
/// `CrossFade` remains the low-level primitive those helpers drive.
///
/// The caller owns the state (one per swapping region) and must `discard` it on teardown.
pub const CrossFade = struct {
    /// Owned outright — not in dvui's texture cache, so it survives across frames and must be
    /// destroyed explicitly.
    texture: ?dvui.Texture = null,
    incoming: ?dvui.Texture = null,
    /// Physical rect matching the captured texture exactly (`Picture.start` enlarges to pixel
    /// boundaries; blitting a smaller rect would sample the wrong UVs).
    rect: dvui.Rect.Physical = .{},
    incoming_rect: dvui.Rect.Physical = .{},
    start_ns: i128 = 0,
    duration_ns: i128 = crossfade.fade_ns,
    kind: Kind = .fade,
    /// Frames to wait after the outgoing capture before photographing the incoming view —
    /// one settle frame under the opaque overlay.
    incoming_wait: u8 = 0,
    have_incoming: bool = false,

    /// Begin recording instead of drawing to the screen. Null when the backend has no
    /// texture targets (web) or the region is empty — callers then swap without a fade, which is
    /// exactly the old behaviour rather than a broken one.
    pub fn beginCapture(rect: dvui.Rect.Physical) ?dvui.Picture {
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

        var s = crossfade.sample(self.kind, t, pending);
        // No incoming picture yet: keep the outgoing cover so the live view
        // cannot flash through a half-dissolved overlay.
        if (self.kind == .blur and self.incoming == null) {
            s.in_alpha = 0;
            s.out_alpha = 1;
        }
        if (self.kind == .blur) {
            if (self.incoming) |tex| blit(tex, self.incoming_rect, s.in_blur, s.in_alpha);
        }
        if (self.texture) |tex| blit(tex, self.rect, s.out_blur, s.out_alpha);

        // Nothing else is animating, so without this an idle app would sleep mid-fade.
        dvui.refresh(null, @src(), null);
    }

    fn progress(self: *CrossFade, pending: bool) f32 {
        const now = dvui.currentWindow().frame_time_ns;
        if (pending) {
            // Park the clock at the pose `sample(..., pending)` will report, so when the
            // hold lifts the remaining timeline starts from there rather than from wherever
            // wall time has wandered.
            const parked: f32 = switch (self.kind) {
                .fade => 0,
                .blur => crossfade.hold,
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
        if (self.incoming) |tex| dvui.Texture.destroyLater(tex);
        self.texture = null;
        self.incoming = null;
        self.have_incoming = false;
        self.incoming_wait = 0;
    }
};

/// Offset-sample smear. dvui has no GPU blur; a centre plus two rings of eight spokes,
/// clipped to the dest, is cheap enough to run every overlay frame on every backend.
pub fn blit(tex: dvui.Texture, dest: dvui.Rect.Physical, blur: f32, alpha: f32) void {
    if (alpha <= 0.001) return;
    if (blur <= 0.001) {
        dvui.renderTexture(tex, .{ .r = dest, .s = 1 }, .{
            .colormod = dvui.Color.white.opacity(alpha),
        }) catch {};
        return;
    }

    const max_r = @min(22.0, @min(dest.w, dest.h) * 0.10);
    const radius = blur * max_r;

    const prev_clip = dvui.clipGet();
    dvui.clipSet(prev_clip.intersect(dest));
    defer dvui.clipSet(prev_clip);

    // A covering copy first so the smear never punches a hole. Offsets sit
    // on top at low alpha — splitting the only copy across samples used to
    // make the overlay look grainy and half-transparent.
    dvui.renderTexture(tex, .{ .r = dest, .s = 1 }, .{
        .colormod = dvui.Color.white.opacity(alpha),
    }) catch {};

    const rings = [_]f32{ 0.45, 0.8, 1.15 };
    const weights = [_]f32{ 0.22, 0.14, 0.08 };
    const spokes: u32 = 8;
    const smear = alpha * blur;

    var i: u32 = 0;
    while (i < spokes) : (i += 1) {
        const angle = @as(f32, @floatFromInt(i)) * (std.math.tau / @as(f32, @floatFromInt(spokes)));
        const cx = @cos(angle);
        const sy = @sin(angle);
        for (rings, weights) |ring, weight| {
            var r = dest;
            r.x += cx * radius * ring;
            r.y += sy * radius * ring;
            dvui.renderTexture(tex, .{ .r = r, .s = 1 }, .{
                .colormod = dvui.Color.white.opacity(smear * weight),
            }) catch {};
        }
    }
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
    /// Fade the outgoing snapshot, or blur out / hand off / unblur in. Fade is the default
    /// so existing call sites keep their 150ms cross-fade.
    kind: Kind = .fade,
    /// Hold at the outgoing peak this frame. Or set `Transition.pending` and leave this false.
    pending: bool = false,
    /// Override the kind's default duration. Null uses `crossfade.durationNs`.
    duration_ns: ?i128 = null,
    /// How to draw the *outgoing* screen. Called only on the swap frame, and only when the
    /// backend supports render targets. Ignored when `key` is unchanged or this is the first
    /// frame for the region.
    ///
    /// Must run under the **same parent** the screen used last frame (stable widget ids). A
    /// temporary isolate parent gives every widget a new id, which restarts `reveal` at alpha 0
    /// and freezes min-size caches — the capture comes out empty/wrong and there is no fade.
    draw_previous: ?*const fn (*anyopaque) void = null,
    /// Called after a successful capture, before the incoming screen packs. Use it to clear the
    /// parent's pack state so the capture's expanded child does not make the incoming one trip
    /// `rectFor() got child after expanded child`.
    after_capture: ?*const fn (*anyopaque) void = null,
    ctx: *anyopaque = undefined,
};

/// Per-frame handle from `transition`. `defer` its `deinit` so the snapshot is blitted after
/// the incoming content draws — and so an incoming capture started this frame is saved.
pub const TransitionFrame = struct {
    cross_fade: *CrossFade,
    incoming: ?dvui.Picture = null,
    prev_clip: ?dvui.Rect.Physical = null,
    pending: bool = false,

    pub fn deinit(self: *TransitionFrame) void {
        if (self.incoming) |*pic| {
            self.cross_fade.endIncoming(pic);
            if (self.prev_clip) |c| dvui.clipSet(c);
        }
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

    if (had_prev and key_changed) {
        state.cross_fade.kind = opts.kind;
        state.cross_fade.duration_ns = opts.duration_ns orelse crossfade.durationNs(opts.kind);
        if (opts.draw_previous) |draw_prev| {
            if (CrossFade.beginCapture(opts.rect)) |captured| {
                var pic = captured;
                // Match CacheWidget: clip to the capture region so we don't paint outside the
                // target, and restore afterward so the incoming screen sees the normal clip.
                const prev_clip = dvui.clipGet();
                dvui.clipSet(opts.rect);
                draw_prev(opts.ctx);
                dvui.clipSet(prev_clip);
                state.cross_fade.endCapture(&pic);
                if (opts.kind == .blur) {
                    state.cross_fade.incoming_wait = 1;
                    state.cross_fade.have_incoming = false;
                }
                if (opts.after_capture) |cb| cb(opts.ctx);
            }
        }
    } else if (opts.kind == .blur and !state.cross_fade.have_incoming and state.cross_fade.texture != null) {
        // Photograph incoming at the hold, after `reveal`'s settle+fade (120ms)
        // has finished under the opaque outgoing overlay (hold is 40% of 480ms).
        // `pending` keeps a one-frame wait so a just-loaded plugin is not
        // snapped on its first paint.
        if (pending) {
            state.cross_fade.incoming_wait = 1;
        } else if (state.cross_fade.incoming_wait > 0) {
            state.cross_fade.incoming_wait -= 1;
        } else if (crossedHold(&state.cross_fade)) {
            if (CrossFade.beginCapture(opts.rect)) |pic| {
                const prev_clip = dvui.clipGet();
                dvui.clipSet(opts.rect);
                state.prev_key = opts.key;
                return .{
                    .cross_fade = &state.cross_fade,
                    .incoming = pic,
                    .prev_clip = prev_clip,
                    .pending = pending,
                };
            }
            state.cross_fade.have_incoming = true;
        }
    }

    state.prev_key = opts.key;
    return .{ .cross_fade = &state.cross_fade, .pending = pending };
}

fn crossedHold(cf: *const CrossFade) bool {
    if (cf.duration_ns <= 0) return true;
    const elapsed = dvui.currentWindow().frame_time_ns - cf.start_ns;
    if (elapsed <= 0) return false;
    const t: f32 = @floatCast(@as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(cf.duration_ns)));
    return t >= crossfade.hold;
}
