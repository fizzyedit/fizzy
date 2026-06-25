const std = @import("std");
const icons = @import("icons");
const dvui = @import("dvui");
const pixi_mod = @import("../../pixi.zig");
const runtime = @import("../runtime.zig");
const ReflectionLagSample = pixi_mod.sprite_render.ReflectionLagSample;
const reflection_surface_cols = pixi_mod.sprite_render.reflection_surface_cols;
const wsurf = pixi_mod.water_surface;

const Sprites = @This();

/// Side-card fly-out / fly-in master timeline (microseconds, linear 0↔1).
const fly_anim_duration_us: i64 = 750_000;
/// Normalised fly speed below which a card stops stirring the water.
const ripple_vel_dead: f32 = 0.06;
/// Per-slot reflection bookkeeping arrays are indexed by `it.d + field_center`.
const max_refl_ripple_slots: usize = wsurf.max_slots;
/// Mean per-cell surface energy below which the water is settled (stop refreshing).
const water_settle_energy: f32 = 0.006;
/// Fly motion → velocity impulse (normalised fly speed × k).
const water_stir_k: f32 = 68.0;
/// Inertial drag wake: velocity impulse per unit change in shelf speed (slots/s),
/// injected as a localized splash (like fly-in) so it ripples rather than uniformly
/// shrinking the reflections. Acceleration-driven, so small quick shakes read big
/// and an abrupt stop throws a forward wake, while a steady drag stays calm.
const water_drag_k: f32 = 20.0;
/// Inject radius (field columns) for the drag wake. Wider than a point so the
/// per-frame scroll stir excites smooth, propagating ripples instead of grid-scale
/// spikes (a 1-cell impulse shimmers in place; a broad bump travels and reads watery).
const water_drag_radius: f32 = 10.0;
/// Steady drag/coast bow wake: dv-only injects vanish at constant speed, so a small
/// per-frame velocity stir keeps ripples visible under the finger (scaled by dt).
const water_scroll_bow_k: f32 = 3.2;
/// Extra reflection refraction while the shelf is actively moving.
const water_scroll_disp_boost: f32 = 1.25;
/// Fly-out transition splash at the centre (velocity impulse).
const water_fly_out_impulse: f32 = -10.5;
/// Fly-in: card bottom is `baseline_y - fly_offset`; ripple only once this close.
/// Fly-out: stir while the card is still near the line as it lifts away.
const water_fly_out_near_k: f32 = 0.22;
/// Downward velocity impulse when a flown-in card splashes back through the waterline.
const water_land_impulse: f32 = -20.0;
/// Surface slope → horizontal refraction at the waterline (fraction of card height).
const water_disp_k: f32 = 1.1;
/// Fly stir / splash: Gaussian radius as a fraction of one card's field span.
/// Wider + more taps than a point inject — spreads energy instead of column bars.
const water_fly_stir_radius_frac: f32 = 0.24;
/// Fly in/out impulses are scaled down vs scroll/drag — staggered lifts otherwise
/// over-drive the surface and pull the reflection seam up.
const water_fly_impulse_scale: f32 = 0.36;
/// Reflection wobble while `fly_t > 0` (field still ripples, seam rise reads softer).
const water_fly_refl_scale: f32 = 0.40;
/// Fly stir velocity dead-zone — higher than scroll so only brisk line contact stirs.
const water_fly_vel_dead: f32 = 0.11;
/// Scroll wake spread (slots): the head-on cards each carve their own wake, fading
/// to nothing ~this many slots out, so ripples emanate from every card the shelf
/// drags across instead of one point at the focus.
const wake_spread_slots: f32 = 3.5;

/// Per-card scroll-wake weight by screen offset — 1 at the focus, linear to 0 at
/// `wake_spread_slots`. Used to distribute the shelf's stir across the visible cards.
fn wakeWeight(off: f32) f32 {
    return @max(0.0, 1.0 - @abs(off) / wake_spread_slots);
}

const FlowItem = struct { idx: usize, off: f32, d: i64, id: usize, center: bool };

/// Spread a fly velocity impulse across a card's width with per-card phase so
/// staggered fly-in/out stirs don't line up as slot-column vertical bars.
fn injectFlyRipple(water: *wsurf.WaterSurface, slot_d: i64, vel_strength: f32, phase: f32) void {
    const strength = vel_strength * water_fly_impulse_scale;
    if (@abs(strength) < 0.0001) return;
    const left = wsurf.slotLeftCol(slot_d);
    const span: f32 = @as(f32, @floatFromInt(wsurf.cols_per_slot));
    const r = span * water_fly_stir_radius_frac;
    const wobble = std.math.sin(phase + @as(f32, @floatFromInt(slot_d)) * 2.17) * span * 0.11;
    const taps = [_]struct { t: f32, w: f32 }{
        .{ .t = 0.18, .w = 0.28 },
        .{ .t = 0.40, .w = 0.26 },
        .{ .t = 0.62, .w = 0.24 },
        .{ .t = 0.82, .w = 0.22 },
    };
    for (taps) |tap| {
        water.inject(left + tap.t * span + wobble, r, 0, strength * tap.w);
    }
}

/// True once a flying side card's bottom has reached the shared waterline.
fn flyCardTouchesWater(fly_offset: f32, fly_anim_out: bool, max_fly_off: f32) bool {
    if (fly_anim_out) return fly_offset < max_fly_off * water_fly_out_near_k;
    return fly_offset <= 0.0;
}

const CardDraw = struct {
    item: FlowItem,
    rect: dvui.Rect,
    w: f32,
    h: f32,
    depth: f32,
    opacity: f32,
    item_scale: f32,
    fly_offset: f32,
    off: f32,
    is_focus: bool,
};

/// Stable widget id for a cover-flow slot (sprite draw + reflection ripple share this).
const SpriteSlot = struct {
    fn src() std.builtin.SourceLocation {
        return @src();
    }
    fn id(id_extra: usize) dvui.Id {
        return dvui.parentGet().extendId(src(), id_extra);
    }
};

/// Cover-flow scrub momentum tuning (sprite-index units). See `pixi_mod.Fling`.
/// Mouse/trackpad release velocity is measured over a position/time window
/// (`releaseWindowed`), not a per-frame EMA — the EMA converged per frame, so a quick
/// flick built up too little velocity at 60 Hz (e.g. Safari on a deployed build) even
/// though it worked at 120 Hz. The window is wall-clock based, so it's refresh-independent.
const sprite_fling: pixi_mod.Fling.Tuning = .{
    .decay = 4.0,
    .min_start = 1.2,
    .stop = 0.6,
    .max = 50.0,
    .idle_s = 0.12,
};
/// Window the mouse/trackpad release velocity is averaged over (s).
const sprite_fling_window_s: f32 = 0.08;
/// Touch scrub: a finger flick is short and bursty, so start coasting at a lower
/// speed and tolerate the small gap the browser leaves before `touchend`. Velocity is
/// measured over a position/time window (`releaseWindowed`) rather than the last frame.
const sprite_fling_touch: pixi_mod.Fling.Tuning = .{
    .decay = 4.0,
    .min_start = 0.6,
    .stop = 0.6,
    .max = 50.0,
    .idle_s = 0.2,
};
/// Window the touch release velocity is averaged over (s).
const sprite_fling_touch_window_s: f32 = 0.1;
/// Upper bound on the per-frame delta fed to the passive cover-flow ease.
const max_ease_dt: f32 = 1.0 / 30.0;
/// Extra skewed shelf slots drawn beyond the pane-fit estimate (each side).
const shelf_edge_extra: i64 = 2;
/// Slot distance past `flat_zone` over which skewed shelf cards fade out. Kept
/// short so a wide pane doesn't spread a gentle fade across the whole window.
const shelf_opacity_fade_span: f32 = 2.5 + @as(f32, @floatFromInt(shelf_edge_extra));
/// Pane-edge distance (in card widths) over which cards fade to transparent.
const shelf_edge_fade_w: f32 = 2.5;
/// Below this opacity a non-focus card is invisible — skip building/rendering its
/// (expensive O(n²)) reflection mesh entirely rather than drawing it transparent.
const card_cull_opacity: f32 = 0.012;
/// Reflection mesh density for a fully-skewed shelf card, as a fraction of the
/// head-on (focus) density. The head-on three cards render at full detail; skewed
/// cards ramp down to this so the off-axis shelf stays cheap on slower GPUs.
const skewed_reflection_detail: f32 = 0.3;
/// Draw an on-screen readout of the last touch fling decision (velocity / idle / coast)
/// so the touch-only momentum can be tuned on a real device. Set false to hide.
const debug_touch_fling = false;

// Animated fit-scale state (shared, like a singleton preview).
var prev_scale: f32 = 1.0;
var current_scale: f32 = 1.0;

// ---- Cover-flow state (persisted on the Panel's Sprites instance) ----
/// Current fractional center index that the flow is rendered around. The sprite
/// nearest this value is drawn flat and on top; neighbours rotate away like
/// records on a shelf.
scroll_pos: f32 = 0.0,
/// Index the flow is easing toward. Driven either by the editor selection or by
/// the user scrolling/dragging the flow itself.
goal: f32 = 0.0,
/// Last virtual center index we observed from the rest of the editor, so we
/// can tell an external selection change apart from one we caused ourselves.
last_sel_virtual: usize = std.math.maxInt(usize),
/// Last virtual index we pushed into editor state from the cover flow.
last_committed_virtual: usize = std.math.maxInt(usize),
/// Accumulates fractional wheel deltas until they cross a whole step.
wheel_accum: f32 = 0.0,
/// True only on frames where the user is actively dragging the flow.
drag_active: bool = false,
/// Whether the pointer moved between press and release (drag vs. click).
moved_since_press: bool = false,
/// True when the active scrub began with a touch press (not mouse).
drag_was_touch: bool = false,
/// Release momentum for the scrub: coasts the flow after a flick, then snaps.
fling: pixi_mod.Fling = .{},
/// Set once we've seeded `scroll_pos` from the initial selection.
initialized: bool = false,
/// Previous "flown" state (see `sideCardsFlown`), so we can fire the fly-out /
/// fly-in transition the frame it flips. While flown, the side cards lift up
/// out of view so only the focused card shows (less distracting).
was_flown: bool = false,
/// Direction of the in-flight `play_fly` animation (outBack vs inBack).
fly_anim_out: bool = false,
/// Shared water surface (slot space) all reflections ripple in. See `water_surface.zig`.
water: wsurf.WaterSurface = .{},
/// Focused slot index last frame — re-anchors the water field as the shelf scrolls.
prev_center_i: i64 = 0,
/// Per-slot previous fly offset for velocity estimation (indexed by `d + field_center`).
prev_fly_offset: [max_refl_ripple_slots]f32 = .{0} ** max_refl_ripple_slots,
/// Per-slot: card dipped below the waterline (fly-in inBack overshoot), awaiting a splash.
was_dipping: [max_refl_ripple_slots]bool = .{false} ** max_refl_ripple_slots,
/// Previous `scroll_pos` — the per-frame delta drives the inertial slosh.
prev_scroll_pos: f32 = 0.0,
/// Smoothed shelf velocity (slots/s); its per-frame change tilts the water.
shelf_vel: f32 = 0.0,

pub fn draw(self: *Sprites) !void {
    if (runtime.state().docs.activeFile(runtime.state().host)) |file| {
        const content_slot = dvui.parentGet().data();
        const parent = content_slot.contentRect();
        if (parent.h < 32.0) {
            return;
        }

        const prev_clip = dvui.clip(content_slot.rectScale().r);
        defer dvui.clipSet(prev_clip);

        self.drawAnimationControlsDialog();

        const parent_height = parent.h;

        const mode = scrollMode(file);
        const count = scrollCount(file, mode);
        if (count == 0) {
            return;
        }

        // ---- Fly-out / fly-in master timeline. `fly_t` runs 0 (all cards at
        // rest) → 1 (side cards lifted out of view) as a linear master clock; each
        // card derives a staggered, eased offset from it below. We flip the target
        // the frame playback starts/stops. ----
        const playing = file.editor.playing;
        const flown = sideCardsFlown(playing);
        const panel_id = content_slot.id;
        if (flown != self.was_flown) {
            const cur: f32 = if (dvui.animationGet(panel_id, "play_fly")) |a| a.value() else (if (self.was_flown) 1.0 else 0.0);
            self.fly_anim_out = flown;
            dvui.animation(panel_id, "play_fly", .{
                .end_time = fly_anim_duration_us,
                .easing = dvui.easing.linear,
                .start_val = cur,
                .end_val = if (flown) 1.0 else 0.0,
            });
            if (flown) {
                @memset(&self.water.height, 0);
                @memset(&self.water.vel, 0);
                if (!dvui.reduce_motion) {
                    injectFlyRipple(&self.water, 0, water_fly_out_impulse, cur);
                }
            } else {
                @memset(&self.was_dipping, false);
            }
            self.was_flown = flown;
        }
        const fly_t: f32 = if (dvui.animationGet(panel_id, "play_fly")) |a|
            std.math.clamp(a.value(), 0.0, 1.0)
        else if (flown) 1.0 else 0.0;

        // Every sprite in a file shares the same cell size, so any sprite rect
        // works for sizing the flow.
        const src_rect = file.spriteRect(0);

        // ---- Animated fit-scale: aim the front sprite at a fraction of the
        // pane so several neighbours are visible at once. ----
        const scale = blk: {
            const steps = runtime.state().settings.zoom_steps;
            const sprite_width = src_rect.w;
            const sprite_height = src_rect.h;
            const target_width = parent.w * 0.34;
            const target_height = parent.h * 0.62;
            var target_scale: f32 = 1.0;

            for (steps, 0..) |zoom, i| {
                if ((sprite_width * zoom) >= target_width or (sprite_height * zoom) >= target_height) {
                    if (i > 0) {
                        target_scale = steps[i - 1];
                        break;
                    }
                    target_scale = steps[i];
                    break;
                }
            }

            if (target_scale != current_scale) {
                if (dvui.animationGet(dvui.parentGet().data().id, "scale")) |a| {
                    if (a.done()) {
                        current_scale = target_scale;
                        prev_scale = current_scale;
                    } else {
                        if (a.end_val != target_scale) {
                            _ = dvui.currentWindow().animations.remove(dvui.parentGet().data().id.update("scale"));
                            dvui.animation(dvui.parentGet().data().id, "scale", .{
                                .end_time = 600_000,
                                .easing = dvui.easing.outBack,
                                .start_val = a.value(),
                                .end_val = target_scale,
                            });
                        } else {
                            current_scale = a.value();
                        }
                    }
                } else {
                    prev_scale = current_scale;
                    dvui.animation(dvui.parentGet().data().id, "scale", .{
                        .end_time = 600_000,
                        .easing = dvui.easing.outBack,
                        .start_val = prev_scale,
                        .end_val = target_scale,
                    });
                }
            }

            break :blk current_scale;
        };

        const item_w = @as(f32, @floatFromInt(file.column_width)) * scale;
        const item_h = @as(f32, @floatFromInt(file.row_height)) * scale;

        // Front group: the focus card plus `flat_zone` neighbours each side sit
        // flat, spaced `front_gap` apart. Past the group a `shelf_gap` opens up
        // (eased in, not a hard step) and the rest tile `far_spread` apart while
        // rotating onto the shelf over `tilt_ramp` index units.
        const front_gap = item_w * 1.2;
        const shelf_gap = item_w * 0.5;
        const far_spread = item_w * 0.62;
        const max_depth: f32 = 0.55;
        const flat_zone: f32 = 1.0;
        const tilt_ramp: f32 = 1.5;
        const gap_ramp: f32 = 1.0;

        // ---- Seed the flow position from the current selection on first frame. ----
        const sel_virtual = currentVirtualTarget(file, mode, count);
        if (!self.initialized) {
            self.scroll_pos = @floatFromInt(sel_virtual);
            self.goal = self.scroll_pos;
            self.prev_scroll_pos = self.scroll_pos;
            self.prev_center_i = @intFromFloat(@floor(self.scroll_pos));
            self.last_sel_virtual = sel_virtual;
            self.last_committed_virtual = sel_virtual;
            self.initialized = true;
        }

        // ---- User input (wheel / drag) may override the flow and the selection. ----
        self.handleInput(file, mode, count, front_gap, flown);

        if (debug_touch_fling) {
            const d = self.fling.last_debug;
            dvui.label(@src(), "touch fling: vel {d:.2}  idle {d:.3}s  dt {d:.3}s  n {d}  coast {}", .{
                d.vel, d.idle_s, d.dt, d.samples, d.coasted,
            }, .{
                .color_text = dvui.themeGet().color(.content, .text),
                .background = true,
                .color_fill = dvui.themeGet().color(.window, .fill),
            });
        }

        // An external selection change (clicking a sprite, picking an animation,
        // playback advancing a frame) retargets the flow. Pick the wrapped
        // representative nearest the current position so we ease the short way
        // around the loop (e.g. from the first sprite leftwards to the last).
        if (!self.drag_active and sel_virtual != self.last_sel_virtual) {
            self.goal = nearestWrapped(self.scroll_pos, sel_virtual, count);
            self.last_sel_virtual = sel_virtual;
            self.last_committed_virtual = sel_virtual;
        }

        // ---- Move toward the goal. While cards are flown (playback, drawing
        // tools, or the preview toggle) we snap so the focus card swaps instantly
        // instead of sliding through neighbours; reduce_motion snaps always.
        // Otherwise ease (frame-rate independent). ----
        if (flown or dvui.reduce_motion) {
            self.scroll_pos = self.goal;
            self.fling.cancel();
            self.commitCenteredIfNeeded(file, mode, count);
        } else if (self.drag_active) {
            // Position is driven directly by the drag in handleInput.
            self.fling.cancel();
        } else if (self.fling.coasting) {
            // Coast with decaying momentum from the release, then snap to (and
            // select) the nearest sprite once the coast slows to a stop.
            if (self.fling.step(sprite_fling)) |d| {
                self.scroll_pos += d;
                self.goal = self.scroll_pos;
            }
            if (!self.fling.coasting) {
                const snapped: i64 = @intFromFloat(@round(self.scroll_pos));
                self.goal = @floatFromInt(snapped);
            }
            dvui.refresh(null, @src(), dvui.parentGet().data().id);
        } else {
            const diff = self.goal - self.scroll_pos;
            if (@abs(diff) > 0.001) {
                // Clamp dt so a wake-from-idle frame (huge secondsSinceLastFrame) doesn't
                // collapse the ease into a single-frame snap. See `max_ease_dt`.
                const dt = @min(dvui.secondsSinceLastFrame(), max_ease_dt);
                const t = 1.0 - @exp(-12.0 * dt);
                self.scroll_pos += diff * t;
                dvui.refresh(null, @src(), dvui.parentGet().data().id);
            } else {
                self.scroll_pos = self.goal;
                // Passive ease finished — sync editor state once at the destination.
                self.commitCenteredIfNeeded(file, mode, count);
            }
        }
        // Infinite wrap: keep scroll_pos (and the goal it chases) within one loop
        // by shifting both by whole turns. The wrapped rendering below is identical
        // regardless of which turn we're on, so this is seamless even mid-ease.
        {
            const c: f32 = @floatFromInt(count);
            const k = @floor(self.scroll_pos / c);
            if (k != 0.0) {
                self.scroll_pos -= k * c;
                self.goal -= k * c;
                self.prev_scroll_pos -= k * c;
            }
        }

        // Only push selection / frame changes while the user is actively scrubbing.
        // During passive ease toward a goal, scroll_pos lags behind — per-frame
        // commits would fight wheel/drag commits and retrigger canvas bubble animations.
        if (self.drag_active or self.fling.coasting) {
            self.commitCenteredIfNeeded(file, mode, count);
        }

        if (parent.h < 32.0) {
            return;
        }

        const perf_sp = pixi_mod.perf.spritePreviewBegin();
        defer pixi_mod.perf.spritePreviewEnd(perf_sp);

        const center_x = parent.center().x;
        // Card rects are positioned in the content slot's *content-local* space, where
        // y = 0 is the top of the content area (below the tab strip). So the vertical
        // center is half the content height, NOT `parent.center().y`: `parent.y` is the
        // slot's offset under the tabs, and including it would push the cards down by a
        // fixed tab-height that grows as a fraction of the pane as it shrinks (the
        // "drifts off the bottom when small" bug). Horizontal centering uses
        // `parent.center().x` only because the slot has no left offset (`parent.x ≈ 0`).
        //
        // Nudge the centerline up by a fraction of the card height so the reflection
        // hanging below the baseline doesn't read as bottom-heavy. The nudge scales
        // with `item_h`, so it stays proportional across pane sizes (a fixed pixel
        // offset would drift the cards as the pane shrank).
        const center_y = parent.h / 2.0 - item_h * 0.10;
        // The waterline: the shared bottom edge every card stands on (the focus
        // card's full-height bottom). Side cards pin their bottom here too.
        const baseline_y = center_y + item_h / 2.0;

        // ---- Collect a window of sprites around the centre and draw them back
        // to front so the focused sprite lands on top. The window grows with the
        // pane so we show as many cards as actually fit, up to a sane cap. ----
        const max_window: i64 = 12;
        const window: i64 = blk: {
            const half_visible = parent.w / 2.0 + item_w;
            const front_extent = flat_zone * front_gap + shelf_gap;
            if (far_spread <= 0.0 or half_visible <= front_extent) break :blk @max(1, @as(i64, @intFromFloat(flat_zone)));
            const extra = @floor((half_visible - front_extent) / far_spread);
            const fit = @as(i64, @intFromFloat(flat_zone)) + 1 + @as(i64, @intFromFloat(extra)) + shelf_edge_extra;
            break :blk std.math.clamp(fit, 1, max_window);
        };

        // Floor (not round) so the focused slot doesn't swap at half-integers while
        // scroll_pos eases toward goal after a slow release.
        const center_i: i64 = @intFromFloat(@floor(self.scroll_pos));

        const scroll_dt = @max(dvui.secondsSinceLastFrame(), 0.0001);
        // Signed slots the shelf moved this frame — covers drag, ease, and fling
        // coast alike (they all move scroll_pos). This single delta drives the wake.
        const scroll_travel = self.scroll_pos - self.prev_scroll_pos;
        self.prev_scroll_pos = self.scroll_pos;

        // ---- Advance the shared water surface. Ripples live in cover-flow slot
        // space anchored to the focused card. While side cards are flown out,
        // scroll snaps instantly (playback / focus mode) — skip stir and reset on
        // slot change so frame advances don't retrigger endless waves. ----
        const water_live = !dvui.reduce_motion;
        const water_scroll_stir = water_live and !flown;
        // Scroll-wake velocity impulses for this frame, distributed across the
        // visible cards in pass 1 (so each head-on card stirs its own slot) rather
        // than injected at one point here. `dv` ≈ acceleration; `bow` is the steady
        // drag/coast stir. Both are computed once and shared out by `wakeWeight`.
        var wake_dv_impulse: f32 = 0;
        var wake_bow_impulse: f32 = 0;
        if (water_live) {
            if (flown) {
                if (center_i != self.prev_center_i) {
                    @memset(&self.water.height, 0);
                    @memset(&self.water.vel, 0);
                }
            } else {
                self.water.reanchor(center_i - self.prev_center_i);
            }
            self.water.step(scroll_dt);

            if (water_scroll_stir) {
                // Inertial drag wake: the same localized splash the fly-in uses, but
                // triggered by the *change* in shelf speed (≈ acceleration) rather
                // than a bulk tilt. A localized impulse makes curved, propagating
                // ripples — the watery look — whereas tilting the whole field just
                // shifts each reflection uniformly. Driving by velocity-change means
                // a small quick shake fires a big ripple and an abrupt stop throws a
                // forward wake, while a steady drag stays calm. Zero-mean over a
                // gesture, so it settles on its own.
                const v_raw = scroll_travel / scroll_dt; // signed slots/s
                // Smooth the shelf-velocity estimate more (was 42): pointer input is
                // noisy frame-to-frame, and `dv` drives the wake — a gentler tracker
                // means a steadier stir instead of a jittery stream of impulses.
                const v_new = std.math.lerp(self.shelf_vel, v_raw, 1.0 - @exp(-18.0 * scroll_dt));
                const dv = v_new - self.shelf_vel;
                self.shelf_vel = v_new;
                if (@abs(dv) > 0.0001) {
                    wake_dv_impulse = -dv * water_drag_k;
                }
                // Acceleration injects miss steady drags — add a bow wake while moving.
                if (@abs(v_new) > 0.22 and (self.drag_active or self.fling.coasting)) {
                    wake_bow_impulse = -v_new * water_scroll_bow_k * scroll_dt;
                }
            } else {
                self.shelf_vel = 0;
            }
        }
        self.prev_center_i = center_i;

        // `slot` is the unwrapped position (so `off` and the skew stay continuous);
        // `idx` is the wrapped sprite it shows; `id` is a per-slot widget id so
        // duplicate sprites (loop shorter than the window) don't collide.
        var items: [2 * 12 + 1]FlowItem = undefined;
        var n: usize = 0;
        var d: i64 = -window;
        while (d <= window) : (d += 1) {
            const slot = center_i + d;
            const virtual = wrapIndex(slot, count);
            items[n] = .{
                .idx = virtualToSpriteIndex(file, mode, virtual),
                .off = @as(f32, @floatFromInt(slot)) - self.scroll_pos,
                .d = d,
                .id = @intCast(d + window),
                .center = d == 0,
            };
            n += 1;
        }

        const SortCtx = struct {
            fn lessThan(_: void, a: FlowItem, b: FlowItem) bool {
                return @abs(a.off) > @abs(b.off);
            }
        };
        std.sort.pdq(FlowItem, items[0..n], {}, SortCtx.lessThan);

        // Total wake weight across the visible cards, so the per-card stir in pass 1
        // shares out the *same* total energy as the old single-point wake — just
        // spread over the cards by `wakeWeight` instead of all at the focus.
        var wake_w_total: f32 = 0;
        if (water_scroll_stir and (wake_dv_impulse != 0 or wake_bow_impulse != 0)) {
            for (items[0..n]) |it| wake_w_total += wakeWeight(it.off);
        }

        // Cull side cards only once the fly-out has finished — not when outBack
        // crosses 1 mid-animation (that overshoot is the visible fling).
        const fly_cull_side_cards = blk: {
            if (dvui.animationGet(panel_id, "play_fly")) |a| break :blk a.done() and flown;
            break :blk flown;
        };

        var draws: [max_refl_ripple_slots]CardDraw = undefined;
        var draw_n: usize = 0;
        // Pass 1 — layout, then inject this card's motion into the shared water.
        for (items[0..n]) |it| {
            const off = it.off;

            // Per-card scroll wake: stir this card's own patch of water (its slot's
            // sample band) so ripples are born under each head-on card and fade out
            // as cards skew toward the edges — not all from the focus. The normalized
            // weight keeps the total energy equal to the old single wake.
            if (water_scroll_stir and wake_w_total > 0.0) {
                const w = wakeWeight(off) / wake_w_total;
                if (w > 0.0) {
                    const col = wsurf.slotCenterCol(it.d);
                    if (wake_dv_impulse != 0) self.water.inject(col, water_drag_radius, 0, wake_dv_impulse * w);
                    if (wake_bow_impulse != 0) self.water.inject(col, water_drag_radius * 1.15, 0, wake_bow_impulse * w);
                }
            }

            const a = std.math.clamp(off, -flat_zone, flat_zone);
            const beyond = off - a;

            const tilt = std.math.clamp((@abs(off) - flat_zone) / tilt_ramp, 0.0, 1.0);
            const gap_t = std.math.clamp((@abs(off) - flat_zone) / gap_ramp, 0.0, 1.0);
            const x_off = a * front_gap + beyond * far_spread + std.math.sign(off) * gap_t * shelf_gap;

            const depth = -std.math.sign(off) * tilt * max_depth;

            // Every card is the same size: the three head-on cards match, and each
            // skewed card's standing (baseline) edge is full height too. Depth reads
            // from the perspective fold, shelf spacing, and opacity fade — not from
            // shrinking the cards (which would also distort the sprite's aspect).
            const item_scale: f32 = 1.0;
            const w = item_w * item_scale;
            const h = item_h * item_scale;

            // Head-on cards (inside `flat_zone`) stay fully opaque. Skewed shelf
            // cards fade over `shelf_opacity_fade_span` slots — not the full window
            // — so outer cards fall off quickly on wide panes. Pane-edge clipping
            // fades further when cards actually run into the sides.
            const card_x = center_x + x_off;
            const abs_off = @abs(off);
            const opacity: f32 = if (abs_off <= flat_zone) 1.0 else blk: {
                const skew_t = std.math.clamp((abs_off - flat_zone) / shelf_opacity_fade_span, 0.0, 1.0);
                const slot_op = 1.0 - skew_t;
                const edge_dist = @min(card_x - parent.x, (parent.x + parent.w) - card_x);
                const edge_op = std.math.clamp(edge_dist / (item_w * shelf_edge_fade_w), 0.0, 1.0);
                break :blk @min(slot_op, edge_op);
            };
            const is_focus = it.center;

            const si: usize = @intCast(it.d + @as(i64, @intCast(wsurf.field_center)));
            const max_fly_off = parent.h + item_h;

            var fly_offset: f32 = 0.0;
            if (!is_focus and fly_t > 0.0) {
                const s = std.math.clamp((@abs(off) - 1.0) / @as(f32, @floatFromInt(window)), 0.0, 1.0);
                const stagger_span: f32 = 0.5;
                const local = std.math.clamp((fly_t - s * stagger_span) / (1.0 - stagger_span), 0.0, 1.0);
                const f = if (self.fly_anim_out) dvui.easing.outBack(local) else dvui.easing.inBack(local);
                fly_offset = f * max_fly_off;
                if (fly_cull_side_cards and f >= 1.0) {
                    self.prev_fly_offset[si] = fly_offset;
                    continue;
                }
            }

            // Index per-slot bookkeeping by slot position (d + field_center), so the
            // arrays track the card currently at each screen slot as the shelf flows.
            const fly_delta = fly_offset - self.prev_fly_offset[si];
            // Cards culled during fly-out reappear with a huge position jump — don't
            // treat that as velocity or the water ripples before they reach the line.
            const fly_teleport = @abs(fly_delta) > max_fly_off * 0.4;
            const fly_vel: f32 = if (fly_teleport) 0 else fly_delta / scroll_dt;
            self.prev_fly_offset[si] = fly_offset;

            // Stand every card on a shared waterline: pin the bottom edge to the
            // baseline (so shrunk side cards drop to the same line as the focus
            // card). Per-column wobble is applied in the sprite mesh via
            // `reflection_lag.cols_dy`; the rect stays on the resting line.
            const rect = dvui.Rect{
                .x = center_x + x_off - w / 2.0,
                .y = baseline_y - h - fly_offset,
                .w = w,
                .h = h,
            };

            if (water_live and !is_focus and fly_t > 0.0) {
                const fly_speed = fly_vel / @max(parent.h, 1.0);
                const touches_water = flyCardTouchesWater(fly_offset, self.fly_anim_out, max_fly_off);
                const ripple_phase = fly_offset * 0.008 + fly_t * 6.28 + @as(f32, @floatFromInt(it.id)) * 0.41;

                if (touches_water and !fly_teleport and @abs(fly_speed) > water_fly_vel_dead) {
                    injectFlyRipple(&self.water, it.d, -fly_speed * water_stir_k, ripple_phase);
                }

                const dipping = !self.fly_anim_out and touches_water and fly_offset < -1.0;
                if (dipping) {
                    self.was_dipping[si] = true;
                } else if (self.was_dipping[si] and fly_offset >= -0.3) {
                    self.was_dipping[si] = false;
                    injectFlyRipple(&self.water, it.d, water_land_impulse, ripple_phase + 1.9);
                }
            } else if (fly_cull_side_cards or fly_t <= 0.0) {
                self.was_dipping[si] = false;
            }

            draws[draw_n] = .{
                .item = it,
                .rect = rect,
                .w = w,
                .h = h,
                .depth = depth,
                .opacity = opacity,
                .item_scale = item_scale,
                .fly_offset = fly_offset,
                .off = off,
                .is_focus = is_focus,
            };
            draw_n += 1;
        }

        const max_fly_off_draw = parent.h + item_h;

        // Pass 2 — draw cards; reflections sample the shared water surface across
        // each card's slot span, so adjacent reflections distort continuously.
        for (draws[0..draw_n]) |cd| {
            // Faded-out edge cards are invisible — skip them so we don't build and
            // render their reflection meshes (the per-card hot path) for nothing.
            if (!cd.is_focus and cd.opacity <= card_cull_opacity) continue;

            const it = cd.item;

            // Grow the shadow smoothly as a card nears the centre (1 at the focus,
            // 0 by one slot out) instead of a hard focus/non-focus switch — so the
            // heavier shadow doesn't snap between cards as the focus flips on scroll.
            const focusness = std.math.clamp(1.0 - @abs(cd.off), 0.0, 1.0);
            var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = it.id,
                .expand = .none,
                .rect = cd.rect,
                .box_shadow = .{
                    .color = .black,
                    .offset = .{ .x = 0.0, .y = std.math.lerp(5.0, 8.0, focusness) },
                    .fade = std.math.lerp(8.0, 12.0, focusness),
                    .alpha = std.math.lerp(0.2, 0.25, focusness) * cd.opacity,
                    .corner_radius = dvui.Rect.all(parent_height / 32.0),
                },
            });
            defer hbox.deinit();

            const item_src = file.spriteRect(it.idx);

            // Sample the shared surface once the card bottom is on the waterline.
            // During fly-in the reflection travels with the card but the surface
            // field stays flat until contact — avoids the line rising early.
            var lag_sample: ReflectionLagSample = .{};
            const touches_water_draw = flyCardTouchesWater(cd.fly_offset, self.fly_anim_out, max_fly_off_draw);
            const refl_water = !dvui.reduce_motion and (it.center or fly_t <= 0.0 or touches_water_draw);
            if (refl_water) {
                const left_col = wsurf.slotLeftCol(it.d);
                const span: f32 = @floatFromInt(wsurf.cols_per_slot);
                const refl_scale: f32 = if (fly_t > 0.0) water_fly_refl_scale else 1.0;
                // Horizontal refraction only — cols_dy is unused (vertical mesh warp squished
                // the reflection while the field was active).
                const scroll_wake_disp: f32 = if (flown or fly_t > 0.0 or
                    !(self.drag_active or self.fling.coasting or @abs(self.shelf_vel) > 0.45))
                    1.0
                else
                    water_scroll_disp_boost;
                inline for (0..reflection_surface_cols) |c| {
                    const t = @as(f32, @floatFromInt(c)) / @as(f32, @floatFromInt(reflection_surface_cols - 1));
                    const col = left_col + t * span;
                    const slope = self.water.visualSlopeAt(col);
                    lag_sample.cols_dx[c] = slope * cd.h * water_disp_k * refl_scale * scroll_wake_disp;
                }
            }

            // Head-on cards (no skew → depth 0) get the full, high-res reflection
            // mesh; skewed shelf cards ramp down to `skewed_reflection_detail` so the
            // off-axis cards stay cheap. Ramps with the tilt so there's no pop as a
            // card scrolls between the flat group and the shelf.
            const tiltness = if (max_depth > 0.0) std.math.clamp(@abs(cd.depth) / max_depth, 0.0, 1.0) else 0.0;
            const refl_detail = std.math.lerp(1.0, skewed_reflection_detail, tiltness);

            _ = pixi_mod.sprite_render.sprite(SpriteSlot.src(), .{
                .source = file.layers.items(.source)[file.selected_layer_index],
                .file = file,
                .alpha_source = if (file.checkerboardTileTexture()) |t| dvui.ImageSource{ .texture = t } else null,
                .sprite = .{
                    .source = .{
                        @intFromFloat(item_src.x),
                        @intFromFloat(item_src.y),
                        @intFromFloat(item_src.w),
                        @intFromFloat(item_src.h),
                    },
                    .origin = .{ 0, 0 },
                },
                .scale = scale * cd.item_scale,
                .depth = cd.depth,
                .opacity = cd.opacity,
                .reflection = true,
                // Peel the reflection down as the card lifts (2× fly_offset). 1:1 left the
                // seam at the waterline while the card rose — reflection stayed put and
                // vanished on cull. Seam pinning + no fly cols_dy keeps 2× from reading
                // as the old ~⅛-card rise.
                .reflection_offset = 2.0 * cd.fly_offset,
                .reflection_lag = if (refl_water) lag_sample else null,
                .reflection_detail = refl_detail,
            }, .{
                .id_extra = it.id,
                .margin = .all(0),
                .padding = .all(0),
            });
        }

        // Keep animating until the water settles, so ripples decay smoothly after
        // the cards stop moving. Crucially, stay awake (and never hard-reset) while
        // the shelf is still moving: a small drag injects only a little localized
        // velocity, so its mean energy can sit below `water_settle_energy` for the
        // first frames — without this, the reset below would wipe the disturbance
        // the same frame it's injected, before the wave develops into ripples (the
        // intermittent "sometimes no ripple" bug).
        if (!dvui.reduce_motion) {
            const e = self.water.energy();
            const moving = self.drag_active or self.fling.coasting or @abs(scroll_travel) > 1e-5;
            if (e > water_settle_energy or moving) {
                dvui.refresh(null, @src(), panel_id);
            } else if (e > 0.0001) {
                @memset(&self.water.height, 0);
                @memset(&self.water.vel, 0);
            }
        }
    }
}

/// Side cards lift away during playback, while a drawing tool is active, or when
/// `settings.scrolling_cards` is off (focus mode; toggled in settings or the sprites pane).
fn sideCardsFlown(playing: bool) bool {
    return playing or drawingToolActive() or !runtime.state().settings.scrolling_cards;
}

/// Pencil, eraser, and bucket — not pointer (navigate) or selection (marquee).
fn drawingToolActive() bool {
    return switch (runtime.state().tools.current) {
        .pointer, .selection => false,
        .pencil, .eraser, .bucket => true,
    };
}

/// How the cover-flow loop and scroll-to-editor sync behave.
const ScrollMode = enum {
    /// All sprites; scrolling does not change selection or animation frame.
    all_passive,
    /// All sprites; the centered sprite becomes the sole selection.
    all_follow_selection,
    /// Animation frames only; the active frame follows the center; no sprite selection.
    animation_passive,
    /// Animation frames; active frame and a single in-animation sprite follow the center.
    animation_follow_selection,
    /// Multi-sprite selection only; primary tile follows the centered sprite.
    selection_only,
};

fn scrollMode(file: anytype) ScrollMode {
    const sel_count = file.editor.selected_sprites.count();
    if (sel_count > 1) return .selection_only;

    if (file.selected_animation_index) |ai| {
        const frames = file.animations.get(ai).frames;
        if (frames.len == 0) return .all_passive;
        if (sel_count == 1) {
            const si = file.editor.selected_sprites.findFirstSet() orelse return .all_passive;
            for (frames) |f| {
                if (f.sprite_index == si) return .animation_follow_selection;
            }
            return .all_follow_selection;
        }
        return .animation_passive;
    }

    if (sel_count == 1) return .all_follow_selection;
    return .all_passive;
}

fn scrollCount(file: anytype, mode: ScrollMode) usize {
    return switch (mode) {
        .all_passive, .all_follow_selection => file.spriteCount(),
        .animation_passive, .animation_follow_selection => blk: {
            const ai = file.selected_animation_index orelse return file.spriteCount();
            break :blk file.animations.get(ai).frames.len;
        },
        .selection_only => file.editor.selected_sprites.count(),
    };
}

fn nthSelectedSprite(file: anytype, n: usize) usize {
    var iter = file.editor.selected_sprites.iterator(.{ .kind = .set, .direction = .forward });
    var i: usize = 0;
    while (iter.next()) |si| {
        if (i == n) return si;
        i += 1;
    }
    return 0;
}

fn selectedSpriteVirtual(file: anytype, sprite_index: usize) ?usize {
    var iter = file.editor.selected_sprites.iterator(.{ .kind = .set, .direction = .forward });
    var i: usize = 0;
    while (iter.next()) |si| {
        if (si == sprite_index) return i;
        i += 1;
    }
    return null;
}

fn virtualToSpriteIndex(file: anytype, mode: ScrollMode, virtual: usize) usize {
    return switch (mode) {
        .all_passive, .all_follow_selection => virtual,
        .animation_passive, .animation_follow_selection => {
            const ai = file.selected_animation_index orelse return virtual;
            const frames = file.animations.get(ai).frames;
            if (frames.len == 0) return virtual;
            return frames[@min(virtual, frames.len - 1)].sprite_index;
        },
        .selection_only => nthSelectedSprite(file, virtual),
    };
}

fn virtualFromSprite(file: anytype, mode: ScrollMode, sprite_index: usize) ?usize {
    return switch (mode) {
        .all_passive, .all_follow_selection => sprite_index,
        .animation_passive, .animation_follow_selection => {
            const ai = file.selected_animation_index orelse return sprite_index;
            const frames = file.animations.get(ai).frames;
            for (frames, 0..) |f, i| {
                if (f.sprite_index == sprite_index) return i;
            }
            return null;
        },
        .selection_only => selectedSpriteVirtual(file, sprite_index),
    };
}

/// Virtual center index the cover flow eases toward when the user isn't driving it.
fn currentVirtualTarget(file: anytype, mode: ScrollMode, count: usize) usize {
    if (count == 0) return 0;

    if (file.editor.playing and (mode == .animation_passive or mode == .animation_follow_selection)) {
        return @min(file.selected_animation_frame_index, count - 1);
    }

    if (file.editor.canvas.hovered and drawingToolActive()) {
        if (file.spriteIndex(file.editor.canvas.dataFromScreenPoint(dvui.currentWindow().mouse_pt_prev))) |sprite_index| {
            if (virtualFromSprite(file, mode, sprite_index)) |v| return @min(v, count - 1);
        }
    }

    return switch (mode) {
        .all_passive, .all_follow_selection => blk: {
            if (file.editor.selected_sprites.count() > 0) {
                if (file.editor.selected_sprites.findLastSet()) |last| break :blk @min(last, count - 1);
            }
            break :blk 0;
        },
        .animation_passive, .animation_follow_selection => @min(file.selected_animation_frame_index, count - 1),
        .selection_only => blk: {
            if (file.primarySpriteIndex()) |primary| {
                if (selectedSpriteVirtual(file, primary)) |v| break :blk @min(v, count - 1);
            }
            break :blk 0;
        },
    };
}

/// Wrap an unbounded slot index into a real sprite index in [0, count).
fn wrapIndex(slot: i64, count: usize) usize {
    return @intCast(@mod(slot, @as(i64, @intCast(count))));
}

/// Advance the cover flow by one whole item and snap `scroll_pos` to match (flown-out mode).
fn stepScrollGoal(self: *Sprites, file: anytype, mode: ScrollMode, count: usize, step: f32) void {
    const next_slot: i64 = @as(i64, @intFromFloat(@round(self.goal))) + @as(i64, @intFromFloat(step));
    const v = wrapIndex(next_slot, count);
    self.goal = @floatFromInt(v);
    self.scroll_pos = self.goal;
    self.fling.cancel();
    if (mode != .all_passive) {
        self.commitVirtualCenter(file, mode, v);
    }
}

/// The representative of sprite `target` nearest to `from` in the infinite wrapped
/// index space, so easing crosses the seam the short way round.
fn nearestWrapped(from: f32, target: usize, count: usize) f32 {
    const c: f32 = @floatFromInt(count);
    const base: f32 = @floatFromInt(target);
    return base + @round((from - base) / c) * c;
}

/// Sync editor state to the sprite/frame under the cover-flow center, if it changed.
fn commitCenteredIfNeeded(self: *Sprites, file: anytype, mode: ScrollMode, count: usize) void {
    if (mode == .all_passive or count == 0) return;
    const centered = wrapIndex(@intFromFloat(@round(self.scroll_pos)), count);
    if (centered == self.last_committed_virtual) return;
    self.commitVirtualCenter(file, mode, centered);
}

/// Apply the centered virtual index to editor state. Records the virtual index so
/// external-selection sync doesn't treat our own change as a new target to chase.
fn commitVirtualCenter(self: *Sprites, file: anytype, mode: ScrollMode, virtual: usize) void {
    switch (mode) {
        .all_passive => return,
        .all_follow_selection => {
            const si = virtualToSpriteIndex(file, mode, virtual);
            if (file.editor.selected_sprites.count() != 1 or
                si >= file.editor.selected_sprites.capacity() or
                !file.editor.selected_sprites.isSet(si))
            {
                file.clearSelectedSprites();
                if (si < file.editor.selected_sprites.capacity()) {
                    file.editor.selected_sprites.set(si);
                }
            }
            file.editor.primary_sprite_index = si;
        },
        .selection_only => {
            const si = virtualToSpriteIndex(file, mode, virtual);
            file.promotePrimarySprite(si);
        },
        .animation_passive => {
            if (file.selected_animation_frame_index != virtual) {
                file.selected_animation_frame_index = virtual;
            }
        },
        .animation_follow_selection => {
            const si = virtualToSpriteIndex(file, mode, virtual);
            if (file.selected_animation_frame_index != virtual or
                file.editor.selected_sprites.count() != 1 or
                si >= file.editor.selected_sprites.capacity() or
                !file.editor.selected_sprites.isSet(si))
            {
                file.selected_animation_frame_index = virtual;
                file.clearSelectedSprites();
                if (si < file.editor.selected_sprites.capacity()) {
                    file.editor.selected_sprites.set(si);
                }
            }
            file.promotePrimarySprite(si);
        },
    }
    self.last_committed_virtual = virtual;
    self.last_sel_virtual = virtual;
}

/// True when pointer events at `p` belong to the main workspace, not a floating
/// dialog/tooltip drawn above it (e.g. Grid Layout over this pane).
fn pointerTargetsMainPane(p: dvui.Point.Physical) bool {
    const cw = dvui.currentWindow();
    const main_id = cw.data().id;
    const target = cw.subwindows.windowFor(p);
    if (target != .zero and target != main_id) return false;
    for (cw.subwindows.stack.items[1..]) |sub| {
        if (sub.modal) return false;
    }
    return true;
}

/// Wheel scrolls one step at a time; horizontal drag scrubs the flow freely and
/// snaps to the nearest item on release. When `snap_scroll` (cards flown out),
/// every step jumps straight to the next centered sprite with no in-between pan.
fn handleInput(self: *Sprites, file: anytype, mode: ScrollMode, count: usize, px_per_index: f32, snap_scroll: bool) void {
    const pane = dvui.parentGet().data();
    const rs = pane.rectScale();
    const id = pane.id;

    self.drag_active = false;

    // Total drag distance (index units) accumulated across this frame's motion
    // events, plus whether a drag was released this frame — both finalized after
    // the loop so velocity is computed once per frame (frameTimeNS is per-frame).
    var frame_dx: f32 = 0.0;
    var released_moved = false;

    // Dialogs/subwindows stack above the sprites pane in z-order but share the same
    // screen rect — don't capture clicks meant for their footer or chrome.
    if (pixi_mod.core.dvui.canvasPointerInputSuppressed()) {
        if (dvui.captured(id)) {
            for (dvui.events()) |*e| {
                if (e.evt == .mouse and e.evt.mouse.action == .release and e.evt.mouse.button.pointer()) {
                    dvui.captureMouse(null, e.num);
                    dvui.dragEnd();
                }
            }
        }
        return;
    }

    for (dvui.events()) |*e| {
        if (e.handled) continue;
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        if (!pointerTargetsMainPane(me.p)) continue;
        const inside = rs.r.contains(me.p);
        if (!inside and !dvui.captured(id)) continue;

        switch (me.action) {
            .press => {
                if (me.button.pointer()) {
                    e.handle(@src(), pane);
                    dvui.captureMouse(pane, e.num);
                    dvui.dragPreStart(me.p, .{ .name = "coverflow_drag", .cursor = .hand });
                    self.moved_since_press = false;
                    self.drag_was_touch = me.button.touch();
                    self.wheel_accum = 0.0;
                    // Grabbing again cancels any in-flight coast and its velocity.
                    self.fling.begin();
                }
            },
            .release => {
                if (me.button.pointer() and dvui.captured(id)) {
                    e.handle(@src(), pane);
                    dvui.captureMouse(null, e.num);
                    dvui.dragEnd();
                    if (self.moved_since_press) released_moved = true;
                    self.moved_since_press = false;
                }
            },
            .motion => {
                if (!dvui.captured(id)) continue;
                // Touch moves use the event delta directly — waiting for the mouse drag
                // threshold drops most of the last samples before `touchend`.
                const dps: dvui.Point.Physical = if (me.button.touch())
                    me.action.motion
                else if (dvui.dragging(me.p, "coverflow_drag")) |d|
                    d
                else
                    continue;
                self.drag_active = true;
                self.moved_since_press = true;
                if (px_per_index > 0.0) {
                    const di = -dps.x / rs.s / px_per_index;
                    if (snap_scroll) {
                        self.wheel_accum += di;
                        while (@abs(self.wheel_accum) >= 1.0) {
                            const step: f32 = if (self.wheel_accum > 0.0) 1.0 else -1.0;
                            self.wheel_accum -= step;
                            stepScrollGoal(self, file, mode, count, step);
                        }
                    } else {
                        self.scroll_pos += di;
                        self.goal = self.scroll_pos;
                        frame_dx += di;
                    }
                }
                dvui.refresh(null, @src(), id);
            },
            .wheel_x, .wheel_y => {
                if (inside) {
                    e.handle(@src(), pane);
                    const amt = if (me.action == .wheel_x) me.action.wheel_x else me.action.wheel_y;
                    // A discrete mouse wheel advances one sprite per notch; a trackpad
                    // accumulates its stream of small deltas smoothly. We can't key off the
                    // raw magnitude: a single wheel notch is ~1.0
                    if (dvui.mouseType() == .mouse) {
                        self.wheel_accum += std.math.sign(amt);
                    } else {
                        self.wheel_accum += amt * 0.01;
                    }
                    while (@abs(self.wheel_accum) >= 1.0) {
                        const step: f32 = if (self.wheel_accum > 0.0) 1.0 else -1.0;
                        self.wheel_accum -= step;
                        if (snap_scroll) {
                            stepScrollGoal(self, file, mode, count, step);
                        } else {
                            const ng = @round(self.goal) + step;
                            self.goal = ng;
                            if (mode != .all_passive) {
                                const v = wrapIndex(@intFromFloat(ng), count);
                                self.commitVirtualCenter(file, mode, v);
                                // scroll_pos may still be easing toward ng; don't let a
                                // passive-ease commit revert this until we arrive.
                                self.last_committed_virtual = v;
                            }
                        }
                    }
                    dvui.refresh(null, @src(), id);
                }
            },
            else => {},
        }
    }

    if (!snap_scroll) {
        // Touch and mouse/trackpad share one path: record each moved frame into the
        // position/time history and, on release, coast from a velocity averaged over a
        // wall-clock window. That window is refresh-independent, so momentum is reliable
        // at 60 Hz and 120 Hz alike — unlike the old per-frame EMA, which underread short
        // flicks at lower refresh rates. Only the feel tuning differs per input type.
        if (self.drag_active) self.fling.sampleTimed(frame_dx);
        if (released_moved) {
            // The last move and the release commonly land on the same frame (more so at
            // low refresh), which leaves `drag_active` set. Clear it after sampling that
            // final move so draw()'s `drag_active` branch doesn't cancel the coast we
            // start here — that race was eating momentum on a large share of flicks.
            self.drag_active = false;
            const tuning = if (self.drag_was_touch) sprite_fling_touch else sprite_fling;
            const window_s = if (self.drag_was_touch) sprite_fling_touch_window_s else sprite_fling_window_s;
            if (!self.fling.releaseWindowed(tuning, window_s)) {
                const snapped: i64 = @intFromFloat(@round(self.scroll_pos));
                self.goal = @floatFromInt(snapped);
                dvui.refresh(null, @src(), id);
            }
        }
    } else if (released_moved) {
        const v = wrapIndex(@intFromFloat(@round(self.goal)), count);
        self.goal = @floatFromInt(v);
        self.scroll_pos = self.goal;
        self.fling.cancel();
        if (mode != .all_passive) {
            self.commitVirtualCenter(file, mode, v);
        }
    }
}

pub fn drawAnimationControlsDialog(_: *Sprites) void {
    if (runtime.state().docs.activeFile(runtime.state().host)) |file| {
        const rect = dvui.parentGet().data().rectScale().r;

        if (dvui.parentGet().data().rect.h < 48.0) {
            return;
        }

        // Round controls floating in the top-left corner. Mirrors the workspace
        // hamburger / sample buttons: content-fill circles with a soft drop
        // shadow and a centered icon.
        const button_size: f32 = 32;
        const gap: f32 = 6;
        const base_x = rect.toNatural().x + 10;
        const base_y = rect.toNatural().y + 10;

        // Play / pause. Always present; "disabled" (muted, no action) when no
        // animation is selected.
        const play_enabled = file.selected_animation_index != null;
        if (drawRoundButton(
            @src(),
            base_x,
            base_y,
            button_size,
            "Play",
            if (file.editor.playing) icons.tvg.entypo.pause else icons.tvg.entypo.play,
            play_enabled,
            file.editor.playing,
        ) and play_enabled) {
            file.editor.playing = !file.editor.playing;
        }

        // Fly-out preview. Toggles the side cards out / in without advancing
        // playback — a static look at the focused-card layout. Highlighted while
        // active; inert while playback or drawing tools already flew them.
        const playing = file.editor.playing;
        const flown = sideCardsFlown(playing);
        const fly_forced = playing or drawingToolActive();
        if (drawRoundButton(
            @src(),
            base_x + button_size + gap,
            base_y,
            button_size,
            "Toggle card focus",
            if (flown) icons.tvg.entypo.doc else icons.tvg.entypo.docs,
            !fly_forced,
            flown,
        ) and !fly_forced) {
            runtime.state().settings.scrolling_cards = !runtime.state().settings.scrolling_cards;
            runtime.state().settings.save(runtime.state().host);
            dvui.refresh(null, @src(), dvui.parentGet().data().id);
        }
    }
}

/// One round, floating action button matching the workspace hamburger / sample
/// buttons. Returns true on click. `enabled` mutes the icon (the caller also
/// gates the action on it); `active` tints the fill to show a toggled-on state.
/// Each call site supplies its own `@src()` for a stable, distinct id.
fn drawRoundButton(
    src: std.builtin.SourceLocation,
    x: f32,
    y: f32,
    size: f32,
    name: []const u8,
    icon_tvg: []const u8,
    enabled: bool,
    active: bool,
) bool {
    const btn_radius: f32 = size / 2;
    const icon_padding: f32 = size * 0.33;

    var fw: dvui.FloatingWidget = undefined;
    fw.init(src, .{}, .{
        .rect = .{ .x = x, .y = y, .w = size, .h = size },
        .expand = .none,
        .background = false,
    });
    defer fw.deinit();

    const fill = if (active)
        dvui.themeGet().color(.highlight, .fill)
    else
        dvui.themeGet().color(.content, .fill);

    var btn: dvui.ButtonWidget = undefined;
    btn.init(src, .{}, .{
        .expand = .both,
        .min_size_content = .{ .w = size, .h = size },
        .background = true,
        .corner_radius = dvui.Rect.all(btn_radius),
        .color_fill = fill,
        .color_fill_hover = fill.lighten(if (dvui.themeGet().dark) 10.0 else -10.0),
        .color_border = .transparent,
        // Inset lives on the button (not the icon): a uniform pad on the icon
        // would force its content rect square and skew non-square glyphs like
        // the entypo play/pause. Padding here keeps the icon's own rect free to
        // take the glyph's native aspect under `expand = .ratio`.
        .padding = dvui.Rect.all(icon_padding),
        .margin = .{},
        .box_shadow = .{
            .color = .black,
            .alpha = 0.2,
            .fade = 4,
            .offset = .{ .x = 0, .y = 2 },
            .corner_radius = dvui.Rect.all(btn_radius),
        },
    });
    defer btn.deinit();
    btn.processEvents();
    btn.drawBackground();

    const text_color = if (active)
        dvui.themeGet().color(.highlight, .text)
    else
        dvui.themeGet().color(.content, .text);
    const icon_color = if (enabled) text_color else text_color.opacity(0.35);

    // `min_size_content.h` must be a real height: IconWidget derives width as
    // `iconWidth(h)` but clamps it up to at least `min_size_content.w`. With a
    // height of 1 a glyph taller than wide derives width < 1, gets clamped to a
    // square min size, and `expand = .ratio` then stretches it. A full-size
    // height keeps the derived width true to the glyph's aspect.
    dvui.icon(
        src,
        name,
        icon_tvg,
        .{ .stroke_color = icon_color, .fill_color = icon_color },
        .{
            .expand = .ratio,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 1.0, .h = size },
        },
    );

    return btn.clicked();
}
