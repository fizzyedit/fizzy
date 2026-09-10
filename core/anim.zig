//! `core.anim` — reveals, cross-fades and transitions.
//!
//! One place for "what happens while the thing on screen changes", because fizzy had this twice:
//! a reveal keyed by document id for tab-content swaps, and a bespoke capture-and-fade for
//! surface swaps. `Layout.draw` runs every region swap through `reveal` now, so a region
//! cross-fades whatever it shows without the shape asking for it.
//!
//! Sits under `core` rather than the layout because a plugin dylib animates its own content with
//! the same code — see `core.widgets` for the divide.
const std = @import("std");
const dvui = @import("dvui");
const builtin = @import("builtin");
const icons = @import("icons");
const platform = @import("platform.zig");
const reveal_phase = @import("reveal.zig");

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

/// A cross-fade between two entirely different subtrees, for swaps where revealing the incoming
/// content is not enough on its own.
///
/// `reveal` works when the pane's chrome stays put and only its contents change (a document tab,
/// a store page). It cannot work when the *background is part of what changes*: center providers
/// each paint their own pane — the workbench's document canvas is square and full-bleed, the
/// homepage, the pack-project window and the store's detail page are rounded cards — so fading
/// the incoming one up from nothing exposes the window behind it, and the corner shape visibly
/// changes mid-swap. There is no backdrop the host could draw that is right for both.
///
/// So don't guess: keep the outgoing pixels. The last frame of the outgoing provider is recorded
/// into a texture (`dvui.Picture` redirects rendering into a render target), then drawn *over*
/// the incoming provider and faded out. Nothing is ever transparent, no shape is assumed, and the
/// incoming subtree's settle frame happens underneath a fully opaque snapshot.
///
/// Prefer `transition` for call sites — it owns swap detection, capture isolation, and teardown.
/// `CrossFade` remains the low-level primitive those helpers drive.
///
/// The caller owns the state (one per swapping region) and must `discard` it on teardown.
pub const CrossFade = struct {
    /// Owned outright — not in dvui's texture cache, so it survives across frames and must be
    /// destroyed explicitly.
    texture: ?dvui.Texture = null,
    /// Physical rect matching the captured texture exactly (`Picture.start` enlarges to pixel
    /// boundaries; blitting a smaller rect would sample the wrong UVs).
    rect: dvui.Rect.Physical = .{},
    start_ns: i128 = 0,
    duration_ns: i128 = 150 * std.time.ns_per_ms,

    /// Begin recording the outgoing content instead of drawing it. Null when the backend has no
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

    /// Take ownership of what `beginCapture` recorded.
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

    /// Draw the outgoing snapshot over what was just drawn, fading out. Call last, and every
    /// frame — it is a no-op with nothing captured.
    pub fn draw(self: *CrossFade) void {
        const tex = self.texture orelse return;

        const elapsed = dvui.currentWindow().frame_time_ns - self.start_ns;
        if (elapsed >= self.duration_ns or self.duration_ns <= 0) {
            self.discard();
            return;
        }
        const t: f32 = @floatCast(@as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(self.duration_ns)));

        dvui.renderTexture(tex, .{ .r = self.rect, .s = 1 }, .{
            .colormod = dvui.Color.white.opacity(1 - dvui.easing.outQuad(t)),
        }) catch {};

        // Nothing else is animating, so without this an idle app would sleep mid-fade.
        dvui.refresh(null, @src(), null);
    }

    pub fn discard(self: *CrossFade) void {
        if (self.texture) |tex| dvui.Texture.destroyLater(tex);
        self.texture = null;
    }
};

/// Host-owned state for one "one of N screens" region. Pair with `transition` each frame.
pub const Transition = struct {
    cross_fade: CrossFade = .{},
    prev_key: ?u64 = null,

    pub fn discard(self: *Transition) void {
        self.cross_fade.discard();
        self.prev_key = null;
    }
};

pub const TransitionOptions = struct {
    /// Identifies *what* is showing now (hash of a center id, document id, …). A new key on a
    /// subsequent frame triggers the capture of `draw_previous`.
    key: u64,
    /// Physical region to capture / blit. Typically the parent's `contentRectScale().r`.
    rect: dvui.Rect.Physical,
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
/// the incoming content draws.
pub const TransitionFrame = struct {
    cross_fade: *CrossFade,

    pub fn deinit(self: *TransitionFrame) void {
        self.cross_fade.draw();
    }
};

/// Cross-fade between screens in a host-owned region. Plugins draw normally; the host wraps the
/// swap so the outgoing frame is captured and faded out over the incoming one.
///
///     var frame = core.anim.transition(&state, .{
///         .key = current_key,
///         .rect = rs.r,
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

    if (had_prev and key_changed) {
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
                if (opts.after_capture) |cb| cb(opts.ctx);
            }
        }
    }

    state.prev_key = opts.key;
    return .{ .cross_fade = &state.cross_fade };
}
