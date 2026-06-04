const std = @import("std");
const icons = @import("icons");
const dvui = @import("dvui");
const fizzy = @import("../../fizzy.zig");
const Editor = fizzy.Editor;

const Sprites = @This();

/// Side-card fly-out / fly-in master timeline (microseconds, linear 0↔1).
const fly_anim_duration_us: i64 = 750_000;

/// Cover-flow scrub momentum tuning (sprite-index units). See `fizzy.Fling`.
const sprite_fling: fizzy.Fling.Tuning = .{
    .decay = 4.0,
    .min_start = 1.2,
    .stop = 0.6,
    .max = 50.0,
    .idle_s = 0.08,
};

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
/// Release momentum for the scrub: coasts the flow after a flick, then snaps.
fling: fizzy.Fling = .{},
/// Set once we've seeded `scroll_pos` from the initial selection.
initialized: bool = false,
/// Previous "flown" state (see `sideCardsFlown`), so we can fire the fly-out /
/// fly-in transition the frame it flips. While flown, the side cards lift up
/// out of view so only the focused card shows (less distracting).
was_flown: bool = false,
/// Direction of the in-flight `play_fly` animation (outBack vs inBack).
fly_anim_out: bool = false,

pub fn draw(self: *Sprites) !void {
    if (fizzy.editor.activeFile()) |file| {
        const prev_clip = dvui.clip(dvui.parentGet().data().rectScale().r);
        defer dvui.clipSet(prev_clip);

        if (dvui.parentGet().data().rect.h < 32.0) {
            return;
        }

        self.drawAnimationControlsDialog();

        // Since not all panel screens will likely want shadows, which should be reserved for canvases?
        // Text editors, consoles, etc would likely want flat panels or to handle shadows themselves.
        defer {
            fizzy.dvui.drawEdgeShadow(dvui.parentGet().data().rectScale(), .top, .{ .opacity = 0.15 });
            fizzy.dvui.drawEdgeShadow(dvui.parentGet().data().rectScale(), .bottom, .{ .opacity = 0.15 });
            fizzy.dvui.drawEdgeShadow(dvui.parentGet().data().rectScale(), .left, .{ .opacity = 0.15 });
            fizzy.dvui.drawEdgeShadow(dvui.parentGet().data().rectScale(), .right, .{ .opacity = 0.15 });
        }

        const parent = dvui.parentGet().data().rect;
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
        const panel_id = dvui.parentGet().data().id;
        if (flown != self.was_flown) {
            const cur: f32 = if (dvui.animationGet(panel_id, "play_fly")) |a| a.value() else (if (self.was_flown) 1.0 else 0.0);
            self.fly_anim_out = flown;
            dvui.animation(panel_id, "play_fly", .{
                .end_time = fly_anim_duration_us,
                .easing = dvui.easing.linear,
                .start_val = cur,
                .end_val = if (flown) 1.0 else 0.0,
            });
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
            const steps = fizzy.editor.settings.zoom_steps;
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
            self.last_sel_virtual = sel_virtual;
            self.last_committed_virtual = sel_virtual;
            self.initialized = true;
        }

        // ---- User input (wheel / drag) may override the flow and the selection. ----
        self.handleInput(file, mode, count, front_gap, flown);

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
                self.commitVirtualCenter(file, mode, wrapIndex(snapped, count));
            }
            dvui.refresh(null, @src(), dvui.parentGet().data().id);
        } else {
            const diff = self.goal - self.scroll_pos;
            if (@abs(diff) > 0.001) {
                const dt = dvui.secondsSinceLastFrame();
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

        const perf_sp = fizzy.perf.spritePreviewBegin();
        defer fizzy.perf.spritePreviewEnd(perf_sp);

        const center_x = parent.center().x;
        // Lift the row a little so the reflection has room below it.
        const center_y = parent.center().y - item_h * 0.10;

        // ---- Collect a window of sprites around the centre and draw them back
        // to front so the focused sprite lands on top. The window grows with the
        // pane so we show as many cards as actually fit, up to a sane cap. ----
        const max_window: i64 = 12;
        const window: i64 = blk: {
            const half_visible = parent.w / 2.0 + item_w;
            const front_extent = flat_zone * front_gap + shelf_gap;
            if (far_spread <= 0.0 or half_visible <= front_extent) break :blk @max(1, @as(i64, @intFromFloat(flat_zone)));
            const extra = @floor((half_visible - front_extent) / far_spread);
            const fit = @as(i64, @intFromFloat(flat_zone)) + 1 + @as(i64, @intFromFloat(extra));
            break :blk std.math.clamp(fit, 1, max_window);
        };
        const center_i: i64 = @intFromFloat(@round(self.scroll_pos));

        // `slot` is the unwrapped position (so `off` and the skew stay continuous);
        // `idx` is the wrapped sprite it shows; `id` is a per-slot widget id so
        // duplicate sprites (loop shorter than the window) don't collide.
        const Item = struct { idx: usize, off: f32, id: usize, center: bool };
        var items: [2 * 12 + 1]Item = undefined;
        var n: usize = 0;
        var d: i64 = -window;
        while (d <= window) : (d += 1) {
            const slot = center_i + d;
            const virtual = wrapIndex(slot, count);
            items[n] = .{
                .idx = virtualToSpriteIndex(file, mode, virtual),
                .off = @as(f32, @floatFromInt(slot)) - self.scroll_pos,
                .id = @intCast(d + window),
                .center = d == 0,
            };
            n += 1;
        }

        const SortCtx = struct {
            fn lessThan(_: void, a: Item, b: Item) bool {
                return @abs(a.off) > @abs(b.off);
            }
        };
        std.sort.pdq(Item, items[0..n], {}, SortCtx.lessThan);

        // Cull side cards only once the fly-out has finished — not when outBack
        // crosses 1 mid-animation (that overshoot is the visible fling).
        const fly_cull_side_cards = blk: {
            if (dvui.animationGet(panel_id, "play_fly")) |a| break :blk a.done() and flown;
            break :blk flown;
        };

        for (items[0..n]) |it| {
            const off = it.off;
            const a = std.math.clamp(off, -flat_zone, flat_zone);
            const beyond = off - a;

            // Tilt eases in over `tilt_ramp` cards (so the flat/skewed boundary is
            // soft); the separation gap eases in faster, over `gap_ramp`. Both
            // ramps start at 0 at the edge of the flat group, keeping x continuous
            // so cards never pop as you scroll.
            const tilt = std.math.clamp((@abs(off) - flat_zone) / tilt_ramp, 0.0, 1.0);
            const gap_t = std.math.clamp((@abs(off) - flat_zone) / gap_ramp, 0.0, 1.0);
            const x_off = a * front_gap + beyond * far_spread + std.math.sign(off) * gap_t * shelf_gap;

            // Left side recedes on its left edge, right side on its right edge.
            const depth = -std.math.sign(off) * tilt * max_depth;

            // Subtle shrink with distance to reinforce depth.
            const dist = @min(@abs(off), 4.0);
            const item_scale = 1.0 - 0.05 * dist;
            const w = item_w * item_scale;
            const h = item_h * item_scale;

            // Fade cards out toward the background the further they sit from the
            // focus; the front card and its immediate neighbours stay opaque.
            const opacity = std.math.clamp(1.0 - 0.28 * (@abs(off) - 1.0), 0.0, 1.0);

            const is_focus = it.center;

            // Side cards lift up and out of view (staggered by distance from the
            // focus) and drop back on fly-in. The focus card never moves. `local`
            // is this card's slice of the master `fly_t` clock; outBack flings out,
            // inBack settles back with a matching overshoot.
            var fly_offset: f32 = 0.0;
            if (!is_focus and fly_t > 0.0) {
                const s = std.math.clamp((@abs(off) - 1.0) / @as(f32, @floatFromInt(window)), 0.0, 1.0);
                const stagger_span: f32 = 0.5;
                const local = std.math.clamp((fly_t - s * stagger_span) / (1.0 - stagger_span), 0.0, 1.0);
                const f = if (self.fly_anim_out) dvui.easing.outBack(local) else dvui.easing.inBack(local);
                if (fly_cull_side_cards and f >= 1.0) continue;
                fly_offset = f * (parent.h + item_h);
            }

            const rect = dvui.Rect{
                .x = center_x + x_off - w / 2.0,
                .y = center_y - h / 2.0 - fly_offset,
                .w = w,
                .h = h,
            };

            // Every card casts a shadow so the stack reads with depth; the shadow
            // softens and fades as cards recede, the focus card keeps the deepest.
            var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = it.id,
                .expand = .none,
                .rect = rect,
                .box_shadow = .{
                    .color = .black,
                    .offset = .{ .x = 0.0, .y = if (is_focus) 8.0 else 5.0 },
                    .fade = if (is_focus) 12.0 else 8.0,
                    .alpha = (if (is_focus) @as(f32, 0.25) else @as(f32, 0.2)) * opacity,
                    .corner_radius = dvui.Rect.all(parent_height / 32.0),
                },
            });
            defer hbox.deinit();

            const item_src = file.spriteRect(it.idx);

            _ = fizzy.dvui.sprite(@src(), .{
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
                .scale = scale * item_scale,
                .depth = depth,
                .opacity = opacity,
                .reflection = true,
                // The card lifts up by `fly_offset`; sink the reflection by twice
                // that so it mirrors across the resting waterline — the card peels
                // up and out the top while its reflection sinks down and out the
                // bottom.
                .reflection_offset = 2.0 * fly_offset,
            }, .{
                .id_extra = it.id,
                .margin = .all(0),
                .padding = .all(0),
            });
        }
    }
}

/// Side cards lift away during playback, while a drawing tool is active, or when
/// `settings.scrolling_cards` is off (focus mode; toggled in settings or the sprites pane).
fn sideCardsFlown(playing: bool) bool {
    return playing or drawingToolActive() or !fizzy.editor.settings.scrolling_cards;
}

/// Pencil, eraser, and bucket — not pointer (navigate) or selection (marquee).
fn drawingToolActive() bool {
    return switch (fizzy.editor.tools.current) {
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
    if (fizzy.dvui.canvasPointerInputSuppressed()) {
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
                if (dvui.captured(id)) {
                    if (dvui.dragging(me.p, "coverflow_drag")) |dps| {
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
                    }
                }
            },
            .wheel_x, .wheel_y => {
                if (inside) {
                    e.handle(@src(), pane);
                    const amt = if (me.action == .wheel_x) me.action.wheel_x else me.action.wheel_y;
                    self.wheel_accum += amt * 0.01;
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

    // Sample the flick velocity once per frame the drag moved.
    if (self.drag_active and !snap_scroll) self.fling.sample(frame_dx);

    // On release, coast with the built-up velocity — unless the pointer had paused
    // or barely moved, in which case snap straight to the nearest sprite.
    if (released_moved) {
        if (snap_scroll) {
            const v = wrapIndex(@intFromFloat(@round(self.goal)), count);
            self.goal = @floatFromInt(v);
            self.scroll_pos = self.goal;
            self.fling.cancel();
            if (mode != .all_passive) {
                self.commitVirtualCenter(file, mode, v);
            }
        } else if (!self.fling.release(sprite_fling)) {
            const snapped: i64 = @intFromFloat(@round(self.scroll_pos));
            self.goal = @floatFromInt(snapped);
            if (mode != .all_passive) {
                self.commitVirtualCenter(file, mode, wrapIndex(snapped, count));
            }
        }
    }
}

pub fn drawAnimationControlsDialog(_: *Sprites) void {
    if (fizzy.editor.activeFile()) |file| {
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
            fizzy.editor.settings.scrolling_cards = !fizzy.editor.settings.scrolling_cards;
            fizzy.editor.markSettingsDirty();
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
