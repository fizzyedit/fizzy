//! Vendored + trimmed from dvui `widgets/FloatingTooltipWidget.zig`. Fizzy's own styling
//! (explorer-panel background, standard 8px corner radius, no border, soft drop shadow) is
//! baked in directly here rather than left to caller-supplied `Options` — the upstream
//! widget draws its background/border/box_shadow via an inner `ScaleWidget` fed from
//! `self.options`, and overriding `color_fill`/`box_shadow` through that path did not
//! reliably show up on screen. Painting via this widget's own top-level `WidgetData`
//! instead (the same simple `register()` + `borderAndBackground()` pattern every plain
//! `dvui.box` uses) sidesteps that entirely.
//!
//! Also drops generality this editor never needs: nested-tooltip chaining, horizontal/
//! vertical/absolute positioning modes (always "sticky" — appears where the mouse is,
//! stays put), and pinch-zoom scale. This widget only ever needs to appear near the mouse
//! and stay open while the mouse is on it.
//!
//! **Open/close delay + fade, not exact reachability tracking.** Earlier revisions tried to
//! keep the tooltip alive by precisely tracking whether the mouse's *current* position was
//! within some "safe" zone every single frame while it traveled from the hovered token to
//! the tooltip — but dvui only matches a mouse-position event against a widget when the
//! event's recorded topmost subwindow (assigned once, by z-order, at the moment the OS event
//! was received) equals whichever subwindow is *current* when `eventMatch` runs; a rect
//! widened from *inside* this widget's own already-installed subwindow context can only ever
//! match points already inside the tooltip's actual on-screen rect, no matter how the rect
//! is padded. Getting this right in general needs real geometry (the hovered token's own
//! screen rect, which isn't plumbed through) and was never fully reliable in practice.
//! Instead: don't require the mouse to be "good" every frame at all. Closing only starts
//! after the mouse has failed every check for `close_delay_us` straight, fading out over
//! that window (and snapping back to fully open if the mouse recovers before it finishes) —
//! however imprecisely or slowly the mouse actually gets there, it has the whole grace
//! window to arrive. Opening fades in over `open_delay_us` for the same reason real tooltips
//! dwell before appearing: a quick pass-over shouldn't flash one open at all.
const std = @import("std");
const internal = @import("../../text.zig");
const dvui = internal.dvui;

const TooltipWidget = @This();

/// Short cosmetic fade once the tooltip has actually committed to showing (see
/// `InitOptions.open_delay_ms` for the real "don't flash on a quick pass" gate — this used to
/// carry that job alone, fading in over 300ms while `install()`/the content fetch happened
/// immediately regardless of the fade's progress, which is why rapid mouse movement across
/// many terms could still feel "stuck": the expensive part (installing a subwindow, fetching
/// hover content) fired on every momentary hover even though the fade made it barely visible).
const open_delay_us: i32 = 100_000;
/// How long the mouse gets, after failing every "still good" check, before the tooltip
/// actually closes (fading out over the same window) — the real fix for "I can't reach the
/// tooltip before it disappears": the mouse just needs to arrive within this window, not
/// satisfy a precise geometric test on every single frame along the way.
const close_delay_us: i32 = 250_000;

pub const InitOptions = struct {
    /// Show when the mouse enters this physical rect.
    active_rect: dvui.Rect.Physical,
    /// The on-screen span this tooltip is *about* (e.g. the hovered token's own bounding
    /// box) — when set, positioning prefers sitting directly above it, left-edge flush with
    /// `anchor_rect`'s left edge and bottom edge flush with its top edge, falling back to
    /// directly below (top edge flush with `anchor_rect`'s bottom edge) only when there isn't
    /// room above. When null, falls back to the older sticky-mouse-point placement (offset
    /// up-and-right from wherever the mouse was when the tooltip first appeared).
    anchor_rect: ?dvui.Rect.Physical = null,
    /// Let the mouse move onto the tooltip itself (e.g. to scroll a long one) without it
    /// closing.
    interactive: bool = true,
    /// Disambiguates this tooltip's widget id from others at the same call site (e.g. the
    /// same document drawn in more than one split at once).
    id_extra: u64 = 0,
    /// Set true the frame the hover target changes (e.g. the mouse glides directly from one
    /// token onto an adjacent one with no gap frame where the tooltip fully closes) so the
    /// sticky spawn point below gets recaptured at the current mouse position. Without this,
    /// re-anchoring only happens via `dvui.firstFrame`, which is keyed to this *widget id*
    /// (reused for every hover in this pane) having gone undrawn for a frame — not to which
    /// token is actually being hovered — so a seamless token-to-token glide would keep
    /// showing content for the new token positioned at the *previous* token's spawn point.
    ///
    /// Deliberately does *not* also restart the open-fade animation in `install` (only
    /// `dvui.firstFrame` does) — the caller derives this from comparing hovered byte spans
    /// frame to frame, which can flip on ordinary mouse jitter near a token boundary (e.g.
    /// `foo.bar`, or the edge of an identifier). Tying an animation restart to that would
    /// mean the animation never reaches `.done()` while the mouse sits near such a boundary,
    /// which stops dvui from ever settling into an idle/no-redraw state — a real "hovering
    /// pins the CPU" regression hit in practice. A cheap position `dataSet` on the same
    /// signal is harmless even if it fires spuriously; restarting an animation every frame
    /// is not.
    reanchor: bool = false,
    /// How long the mouse must stay somewhere within `active_rect` before the tooltip
    /// actually commits to showing — before `install()` runs and the caller's content-fetch
    /// happens at all, not just before it's visible. Configurable so rapid mouse movement
    /// across many terms in quick succession never triggers a fetch (or a subwindow install)
    /// for any of them; only settling in one place for this long does. Deliberately keyed to
    /// "still somewhere in `active_rect`", not to `reanchor` staying false — see `reanchor`'s
    /// own doc comment on why tying anything timing-sensitive to it risks never completing
    /// while the mouse jitters near a token boundary. `reset_dwell` above is the actual per-
    /// target measurement; this field only sets the window's length.
    open_delay_ms: i32 = 500,
    /// True when the caller already knows there's nothing to show for the current target
    /// (e.g. a language provider's hover answered "definitively nothing here" — see
    /// `sdk.language.HoverResult`'s doc comment). Checked at two points in `shown()`: while
    /// still dwelling, the completed dwell never commits to showing at all (so `install()`
    /// never runs and no box ever appears); if a target answers *after* this tooltip was
    /// already open showing something else, it's folded into the exact same close-fade
    /// `deinit()` already uses for "the mouse left" (via `mouse_good_this_frame`), rather than
    /// abruptly halting `install()` mid-lifecycle and stranding an already-installed
    /// subwindow. Callers should draw nothing while `shown()` returns due to a suppressed
    /// target — any content drawn during the transitional close-fade frames renders inside a
    /// box that's already shrinking to nothing, not a stable "no info" state worth labeling.
    suppress: bool = false,
};

wd: dvui.WidgetData,
init_options: InitOptions,
prev_windowInfo: dvui.subwindowCurrentSetReturn = undefined,
prev_scroll: ?*dvui.ScrollContainerWidget = undefined,
prevClip: dvui.Rect.Physical = undefined,
prev_alpha: f32 = 1.0,
render_ftb: dvui.RenderFrontToBack = undefined,
showing: bool = false,
mouse_good_this_frame: bool = false,
installed: bool = false,

/// It's expected to call this when `self` is `undefined`.
pub fn init(self: *TooltipWidget, src: std.builtin.SourceLocation, init_opts: InitOptions) void {
    const options: dvui.Options = .{
        .name = "FizzyTooltip",
        .color_fill = dvui.themeGet().color(.window, .fill).lighten(if (dvui.themeGet().dark) 5 else -5),
        .corners = dvui.CornerRect.all(8),
        .border = dvui.Rect.all(0),
        .background = true,
        .box_shadow = .{
            .color = .black,
            .shrink = 0,
            .corners = dvui.CornerRect.all(8),
            .offset = .{ .x = 0, .y = 2 },
            .fade = 4,
            .alpha = 0.2,
        },
        // Passing a non-null rect stops WidgetData.init from calling rectFor/
        // minSizeForChild, which matters because we're outside normal layout.
        .rect = .{},
        .id_extra = @intCast(init_opts.id_extra),
    };
    self.* = .{
        .wd = dvui.WidgetData.init(src, .{ .subwindow = true }, options),
        .init_options = init_opts,
    };
    if (dvui.dataGet(null, self.wd.id, "_showing", bool)) |showing| self.showing = showing;
}

pub fn shown(self: *TooltipWidget) bool {
    // Protect against this being called multiple times.
    if (self.installed) return true;

    if (self.init_options.reanchor) {
        // Hover target changed this frame (see `InitOptions.reset_dwell`) — drop whatever
        // dwell/showing state the previous target left behind so the gate below re-measures
        // `open_delay_ms` for the new one instead of reusing it (or, worse, reusing an
        // already-elapsed timestamp and committing instantly).
        //
        // Persist `_showing = false` directly, not just the local `self.showing` field: the
        // dwell gate below almost always rejects this exact frame (a fresh dwell period has
        // barely started), meaning `shown()` returns before `install()` ever runs — so
        // `self.installed` stays false and `deinit()`'s `if (!self.installed) return;` skips
        // writing `_showing` back to storage at all this frame. Without this direct write,
        // the *next* frame's `init()` reloads the *previous* target's still-`true` persisted
        // `_showing` (this reset trigger only fires for the one transition frame) and skips
        // the dwell gate entirely — the tooltip flashes open one frame into a brand-new
        // hover instead of after the intended delay, which reproduced as "the dwell timer
        // only works the very first time; token-to-token still reveals instantly."
        self.showing = false;
        dvui.dataSet(null, self.data().id, "_showing", false);
        dvui.dataRemove(null, self.data().id, "_dwell_start_ns");
    }

    const evts = dvui.events();
    var mouse_here_this_frame = false;
    for (evts) |*e| {
        if (!dvui.eventMatch(e, .{ .id = self.data().id, .r = self.init_options.active_rect })) continue;
        if (e.evt == .mouse and e.evt.mouse.action == .position) {
            self.mouse_good_this_frame = true;
            mouse_here_this_frame = true;
        }
    }

    if (!self.showing) {
        // Dwell gate: don't commit to showing (install a subwindow, let the caller fetch
        // content) until the mouse has sat somewhere in `active_rect` continuously for
        // `open_delay_ms`. Reset the instant the mouse leaves entirely; a momentary hover
        // during rapid mouse movement across many terms never gets far enough to commit.
        if (!mouse_here_this_frame) {
            dvui.dataRemove(null, self.data().id, "_dwell_start_ns");
            return false;
        }
        if (dvui.dataGet(null, self.data().id, "_dwell_start_ns", i128) == null) {
            dvui.dataSet(null, self.data().id, "_dwell_start_ns", dvui.frameTimeNS());
        }
        const dwell_start = dvui.dataGet(null, self.data().id, "_dwell_start_ns", i128).?;
        const elapsed_ms = @divTrunc(dvui.frameTimeNS() - dwell_start, std.time.ns_per_ms);
        if (elapsed_ms < self.init_options.open_delay_ms) {
            // Not there yet — ask for another frame so we notice once the timer elapses even
            // if the mouse stops moving entirely (no further position events would otherwise
            // fire to re-run this check).
            dvui.refresh(null, @src(), self.data().id);
            return false;
        }
        dvui.dataRemove(null, self.data().id, "_dwell_start_ns");
        if (self.init_options.suppress) {
            // Dwell finished, but the caller already knows there's nothing to show for this
            // target — never commit to showing at all, so `install()` never runs and no box
            // ever appears. No `dvui.refresh` here (unlike the "not there yet" branch above):
            // if the mouse doesn't move, nothing needs to happen again until it does.
            return false;
        }
        self.showing = true;
    }

    // From here, `self.showing` is true — either just committed above, or persisted from a
    // prior frame. If the caller now knows there's nothing to show for a target that answered
    // *after* this tooltip was already open (e.g. showing "Just a moment"), fold that into the
    // same close-fade path `deinit()` already uses for "the mouse left" rather than abruptly
    // stopping `install()` mid-lifecycle, which would strand an already-installed subwindow
    // with no code left to tear it down.
    if (self.init_options.suppress) {
        self.mouse_good_this_frame = false;
    }

    // Sticky positioning: captured once when the tooltip (re)appears, then stays there until
    // the hover target changes (doesn't chase the mouse around while shown over the same
    // token, and doesn't re-derive the anchor's rect as the mouse wobbles within it either).
    if (dvui.firstFrame(self.data().id) or self.init_options.reanchor) {
        if (self.init_options.anchor_rect) |ar| {
            dvui.dataSet(null, self.data().id, "_sticky_anchor", ar.toNatural());
        } else {
            const mp = dvui.currentWindow().mouse_pt.toNatural();
            dvui.dataSet(null, self.data().id, "_sticky_pt", mp);
        }
    }

    var r: dvui.Rect.Natural = undefined;
    if (dvui.dataGet(null, self.data().id, "_sticky_anchor", dvui.Rect.Natural)) |anchor| {
        const size: dvui.Size = self.data().rect.size();
        const window_rect = dvui.windowRect();
        // Prefer directly above the anchor, left edges flush, sitting right against its top
        // edge so the mouse never has to leave the term's span to reach the tooltip.
        const above = dvui.Rect.Natural{ .x = anchor.x, .y = anchor.y - size.h, .w = size.w, .h = size.h };
        r = if (above.y >= window_rect.y) above else .{
            // Doesn't fit above — flip below, top edge flush with the anchor's bottom edge.
            .x = anchor.x,
            .y = anchor.y + anchor.h,
            .w = size.w,
            .h = size.h,
        };
    } else {
        const mp = dvui.dataGet(null, self.data().id, "_sticky_pt", dvui.Point.Natural) orelse dvui.Point.Natural{};
        r = dvui.Rect.Natural.fromPoint(mp).toSize(.cast(self.data().rect.size()));
        r.x += 10;
        r.y -= r.h + 10;
    }
    self.data().rect = .cast(dvui.placeOnScreen(dvui.windowRect(), .{}, .none, r));

    self.install();

    // Skipped while suppressed: the mouse resting on an already-closing (empty, fading) box
    // must not be able to re-set `mouse_good_this_frame` and keep it open.
    if (self.init_options.interactive and !self.init_options.suppress) {
        for (evts) |*e| {
            if (!dvui.eventMatch(e, .{ .id = self.data().id, .r = self.data().borderRectScale().r })) continue;
            if (e.evt == .mouse and e.evt.mouse.action == .position) self.mouse_good_this_frame = true;
        }
    }

    return true;
}

pub fn install(self: *TooltipWidget) void {
    self.installed = true;

    self.data().register();
    dvui.parentSet(self.widget());

    // standard subwindow stuff
    {
        const rs = self.data().rectScale();
        self.render_ftb.initReset();
        self.prev_windowInfo = dvui.subwindowCurrentSet(self.data().id, null);
        dvui.subwindowAdd(self.data().id, self.data().rect, rs.r, false, self.prev_windowInfo.id, true);
        dvui.captureMouseMaintain(.{ .id = self.data().id, .rect = rs.r, .subwindow_id = self.data().id });
        self.prevClip = dvui.clipGet();
        dvui.clipSet(dvui.windowRectPixels()); // break out of whatever clipping we were in
        self.prev_scroll = dvui.ScrollContainerWidget.scrollSet(null);
    }

    // Fade in on first appearance, fade out while closing (see `deinit`). Applies to
    // everything drawn for this tooltip, background/shadow included, since it's a plain
    // global alpha multiplier restored to its previous value below in `deinit`. Gated on
    // `dvui.firstFrame` only — see `InitOptions.reanchor`'s doc comment for why it must not
    // also restart this.
    if (dvui.firstFrame(self.data().id)) {
        dvui.animation(self.data().id, "_open", .{ .start_val = 0, .end_val = 1, .end_time = open_delay_us });
    }
    const closing = dvui.dataGet(null, self.data().id, "_closing", bool) orelse false;
    const a: f32 = if (closing)
        // No `_close` entry should be reachable here (it's always started in the same
        // `deinit` call that sets `_closing = true`) — if it somehow is, fail toward
        // invisible rather than fully opaque.
        (dvui.animationGet(self.data().id, "_close") orelse dvui.Animation{ .start_val = 0, .end_val = 0, .end_time = 0 }).value()
    else
        (dvui.animationGet(self.data().id, "_open") orelse dvui.Animation{ .start_val = 1, .end_val = 1, .end_time = 0 }).value();
    self.prev_alpha = dvui.alpha(a);

    self.data().borderAndBackground(.{});
}

pub fn widget(self: *TooltipWidget) dvui.Widget {
    return dvui.Widget.init(self, data, rectFor, screenRectScale, minSizeForChild);
}

pub fn data(self: *TooltipWidget) *dvui.WidgetData {
    return self.wd.validate();
}

pub fn rectFor(self: *TooltipWidget, id: dvui.Id, min_size: dvui.Size, e: dvui.Options.Expand, g: dvui.Options.Gravity) dvui.Rect {
    _ = id;
    return dvui.placeIn(self.data().contentRect().justSize(), min_size, e, g);
}

pub fn screenRectScale(self: *TooltipWidget, rect: dvui.Rect) dvui.RectScale {
    return self.data().contentRectScale().rectToRectScale(rect);
}

pub fn minSizeForChild(self: *TooltipWidget, s: dvui.Size) void {
    self.data().minSizeMax(self.data().options.padSize(s));
}

pub fn deinit(self: *TooltipWidget) void {
    defer if (dvui.widgetIsAllocated(self)) dvui.widgetFree(self);
    defer self.* = undefined;
    if (!self.installed) return;

    if (self.mouse_good_this_frame) {
        // Mouse is fine (or just recovered) — cancel any in-progress close-fade so the
        // tooltip snaps back to fully visible rather than continuing toward closed.
        dvui.dataSet(null, self.data().id, "_closing", false);
        dvui.dataSet(null, self.data().id, "_showing", true);
    } else {
        const was_closing = dvui.dataGet(null, self.data().id, "_closing", bool) orelse false;
        if (!was_closing) {
            // Just failed the "still good" check for the first time this session — start
            // the close-delay grace window instead of closing immediately.
            dvui.dataSet(null, self.data().id, "_closing", true);
            dvui.animation(self.data().id, "_close", .{ .start_val = 1, .end_val = 0, .end_time = close_delay_us });
        }
        const done = if (dvui.animationGet(self.data().id, "_close")) |anim| anim.done() else true;
        if (done) {
            dvui.dataRemove(null, self.data().id, "_showing");
            dvui.dataRemove(null, self.data().id, "_closing");
        } else {
            dvui.dataSet(null, self.data().id, "_showing", true);
        }
        // Either the close-fade needs another frame to progress, or state just changed to
        // hidden — both need a repaint even if the mouse never moves again.
        dvui.refresh(null, @src(), self.data().id);
    }

    dvui.alphaSet(self.prev_alpha);

    self.data().minSizeSetAndRefresh();

    // outside normal layout, don't call minSizeForChild or self.data().minSizeReportToParent();
    dvui.parentReset(self.data().id, self.data().parent);

    // standard subwindow stuff
    {
        _ = dvui.ScrollContainerWidget.scrollSet(self.prev_scroll);
        _ = dvui.subwindowCurrentSet(self.prev_windowInfo.id, self.prev_windowInfo.rect);
        dvui.clipSet(self.prevClip);
        self.render_ftb.deinit();
    }
}
