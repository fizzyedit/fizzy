//! How things move: one user setting, `level`, that every animation in the app — and in any
//! plugin that asks — reads to decide its character.
//!
//! The setting is a gradient, not a switch:
//!
//!   * **0, off** — nothing animates. dvui's own animations end the frame they start
//!     (`dvui.reduce_motion`), and everything drawn here should jump straight to where it is
//!     going (`off`). A system asking for reduced motion puts the app here whatever the setting.
//!   * **up to 0.5, minimal** — plain motion: linear, constant speed, nothing overshoots.
//!   * **0.5 to 1, playful** — things carry on past where they are going and settle back, more
//!     the further up: at 1 about 12% past. Frosted glass has a refracting edge from minimal on
//!     (`liquid`).
//!
//! **Every level arrives on time.** A motion reaches its target at `arrival` of the duration it
//! was given — the share the app's durations were tuned for, when its curves overshot and so
//! arrived well before they ended — whatever the level. The overshoot is not squeezed into the
//! approach (a curve that arrives earlier to make room for its swing reads as faster, and the
//! slider was changing speed where it should only change character): it swings after the
//! arrival, in time the duration already had, and what is left after that the motion holds
//! still. So the slider changes how a motion ends, never how fast it gets there; how fast is the
//! **speed** setting's, a window from half as fast to twice as fast which never stops motion
//! outright — that is off's job.
//!
//! **Ask by intent, not by curve.** A call site says what the motion *is* — something arriving
//! (`enter`), leaving (`exit`), moving to a new place (`settle`), or fading (`fade`) — and gets the
//! curve the level gives that. They are plain `fn (f32) f32`, the shape `dvui.animation` takes, so
//! they drop in wherever a `dvui.easing` function went; they read the level when evaluated.
//! Effects that are not curves ask for an amount: `liquid`, for how much frosted glass's bevel
//! refracts and catches the light.
//!
//! **One value everywhere.** The host publishes the level into the shared dvui window each frame
//! (`publish`); a plugin dylib's copy of this file reads it from there, the way it reads the
//! dialog style. A plugin that wants its motion to match the app's calls these and nothing else.
const std = @import("std");
const dvui = @import("dvui");

/// The level when nothing has been published: minimal, the app's own character.
pub const default_level: f32 = 0.5;
/// The speed setting's middle: durations as written.
pub const default_speed: f32 = 0.5;
/// How much faster the fastest speed is than as written, and the slowest slower.
pub const speed_range: f32 = 2;

const publish_id: dvui.Id = @enumFromInt(0x6669_7a7a_6d6f_7469); // "fizzmoti"
const publish_key = "_motion";

/// What the host publishes each frame.
const Published = struct {
    level: f32 = default_level,
    /// How many times faster than written: `1 / speed_range` to `speed_range`.
    rate: f32 = 1,
};

/// Host only, once a frame before anything animates: this frame's level and speed, where every
/// image's copy of this file finds them, and dvui's own animations told whether to run at all.
/// `level` and `speed` are the settings, each 0 to 1. A system that asks for reduced motion gets
/// off, whatever the setting says.
pub fn publish(level_setting: f32, speed_setting: f32, system_prefers_reduced: bool) void {
    const v: f32 = if (system_prefers_reduced) 0 else std.math.clamp(level_setting, 0, 1);
    dvui.dataSet(null, publish_id, publish_key, Published{ .level = v, .rate = rateFor(speed_setting) });
    apply();
}

/// The speed setting (0 slow, 0.5 as written, 1 fast) as a rate: evenly spaced in doublings, so
/// the middle of the slider is the middle of how it feels.
pub fn rateFor(speed_setting: f32) f32 {
    const s = std.math.clamp(speed_setting, 0, 1);
    return std.math.pow(f32, speed_range, (s - 0.5) * 2);
}

fn published() Published {
    if (dvui.current_window == null) return .{};
    return dvui.dataGet(null, publish_id, publish_key, Published) orelse .{};
}

/// Bring this image's copy of dvui in line with the published level — the host's in `publish`,
/// a plugin's when the host hands it the window (`sdk.dvui_context.inject`).
pub fn apply() void {
    dvui.reduce_motion = off();
}

/// 0 (off) to 1 (playful). Minimal, 0.5, outside a window or before anything was published.
pub fn level() f32 {
    return published().level;
}

/// How many times faster than written motion runs (the speed setting): 0.5 to 2, never 0.
pub fn rate() f32 {
    return published().rate;
}

/// Nothing moves: jump to where it is going.
pub fn off() bool {
    return level() <= 0.001;
}

/// How much frosted glass's bevelled edge refracts, clears and catches the light
/// (`core.liquid_glass`): none at off, rising to all of it by minimal, and no more past it.
pub fn liquid() f32 {
    return std.math.clamp(level() * 2, 0, 1);
}

/// A duration in microseconds as the user wants it: at their speed, and a single microsecond
/// (done at once) when motion is off. Pass every duration an animation runs for through this,
/// paired with one of the curves below.
pub fn duration(us: i32) i32 {
    if (off()) return 1;
    return @max(1, @as(i32, @intFromFloat(@as(f32, @floatFromInt(us)) / rate())));
}

/// The same in milliseconds, for animations stepped by hand: 0 when off.
pub fn durationMs(ms: f32) f32 {
    return if (off()) 0 else ms / rate();
}

/// Microseconds, as written (pass it through `duration`), that a floating surface takes to open:
/// a menu sliding down, a tooltip growing out of the pointer. One number, so they open together.
pub const open_us: i32 = 260_000;

/// When, as a share of its duration, every motion reaches its target, at every level.
pub const arrival: f32 = 0.4;
/// The share of a duration a leaving motion's draw back takes, at playful (`exit`).
pub const swing_max: f32 = 0.26;

/// The share of a duration the draw back before leaving takes at level `lv`: none up to minimal.
pub fn swingAt(lv: f32) f32 {
    return swing_max * std.math.clamp((lv - 0.5) * 2, 0, 1);
}

// ── Curves by intent ────────────────────────────────────────────────────────────────────────────

/// Something arriving — opening, appearing, growing into place: to its target by `arrival`, then,
/// above minimal, carrying on past it and settling back like a spring (`enterAt`).
pub fn enter(t: f32) f32 {
    return enterAt(level(), t);
}

/// Something growing into a thing that cannot swing with it — a carried glass into the OS window it
/// lands as, which shows at its own size: `enter`'s approach and its swing past and back over the
/// whole of `t` (`enterFull`), the swing `swing` of `enter`'s, at rest on the target at the end —
/// when the window takes over. With `enter`'s swing still going as the window came in, a tall
/// float's glass stood some 40 points past its window, which cut it to its size: an overshoot,
/// then a snap; with no swing at all it had none of the life the rest of the app's motion has
/// (the user: a small overshoot).
pub fn arrive(t: f32, swing: f32) f32 {
    const lv = level();
    const u = clamp01(t) * (arrival + (1 - arrival) * playfulness(lv));
    const e = enterAt(lv, u);
    return if (u <= arrival) e else 1 + (e - 1) * swing;
}

/// Something leaving — closing, shrinking away: above minimal it draws back first, then leaves at
/// constant speed, gone `arrival` after it set off, and holds there.
pub fn exit(t: f32) f32 {
    return exitAt(level(), t);
}

/// Something moving to a new place or size — a slide, a resize, a reorder. The same motion as
/// `enter`: every kind of motion arrives on the same clock.
pub fn settle(t: f32) f32 {
    return settleAt(level(), t);
}

/// Opacity: linear, there by `arrival`, and holding. Never past 1 — a fade has nowhere to
/// overshoot to.
pub fn fade(t: f32) f32 {
    return clamp01(t / arrival);
}

/// `enter` with no hold after it: the approach and the swing over the whole of `t`, for a caller
/// timing phases of its own (the drop zones' split), where a motion that finished early and sat
/// still would leave its phase dead. Arrives at the end at minimal, `arrival` in at playful — whose
/// swing already runs to the end.
pub fn enterFull(t: f32) f32 {
    const lv = level();
    return enterAt(lv, clamp01(t) * (arrival + (1 - arrival) * playfulness(lv)));
}

/// Glass's depth as it forms (`enterFull`), its swing past full `swell_gain` times as broad: a
/// window's refracting edge bulges as the glass arrives and settles back, the way a drop does.
/// At minimal and below it is `enterFull`, with no swing.
pub fn swell(t: f32) f32 {
    const e = enterFull(t);
    return if (e > 1) 1 + (e - 1) * swell_gain else e;
}
pub const swell_gain: f32 = 2.5;

/// How far toward playful level `lv` is, 0 up to minimal to 1 at playful.
fn playfulness(lv: f32) f32 {
    return std.math.clamp((lv - 0.5) * 2, 0, 1);
}

/// How far past its target `enter` carries at playful.
pub const overshoot_max: f32 = 0.12;
/// The approach's speed as it leaves and as it reaches the target, at playful, relative to
/// constant speed: quicker away, and slower into the target so the swing past it is carried, not
/// flung. Between them a smooth ease-out.
const leave_speed: f32 = 1.5;
const arrive_speed: f32 = 0.6;
/// How quickly the swing dies down, as a share of how quickly it turns: each half turn is
/// `e^(-damping·π)` of the one before — a broad swing past, a small one back, then rest.
const damping: f32 = 0.6;

/// `enter` at a given level, for a call site (or a test) that has its own.
///
/// Up to minimal, constant speed to the target at `arrival`, then still. Above it an ease-out
/// to the target, reaching it at `arrival` all the same, then a damped spring that leaves it at
/// the approach's own speed — no kink as it passes — swings past (up to `overshoot_max` at
/// playful), back a little, and comes to rest by the end. The swing takes the whole of the rest of
/// the duration rather than a short burst after the arrival, so it reads as mass settling, not a
/// flick.
pub fn enterAt(lv: f32, t: f32) f32 {
    const u = clamp01(t);
    const k = playfulness(lv);
    // The approach: a cubic from 0 to 1 over [0, arrival], leaving and arriving at `m0`, `m1`
    // times constant speed — both 1 at minimal, which is the straight line.
    const m0 = 1 + (leave_speed - 1) * k;
    const m1 = 1 + (arrive_speed - 1) * k;
    if (u <= arrival) {
        const x = u / arrival;
        const x2 = x * x;
        const x3 = x2 * x;
        return (x3 - 2 * x2 + x) * m0 + (-2 * x3 + 3 * x2) + (x3 - x2) * m1;
    }
    if (k <= 0.001) return 1;
    // The swing: 1 + (v/ω)·e^(-σ·τ)·sin(ω·τ), which leaves 1 at the arrival speed `v`; ω is set
    // by how far past it should carry, since that peak is (v/ω)·g for the damping's g.
    const v = m1 / arrival;
    const peak_turn = std.math.atan(1 / damping);
    const g = @exp(-damping * peak_turn) * @sin(peak_turn);
    const w = v * g / (overshoot_max * k);
    const sigma = damping * w;
    const tau = u - arrival;
    const rest = 1 - arrival;
    // What is left of the swing fades out over the last of the duration, so it is at rest at
    // the end rather than stopped there.
    const fade_from = 0.7 * rest;
    const fx = std.math.clamp((tau - fade_from) / (rest - fade_from), 0, 1);
    const window = 1 - fx * fx * (3 - 2 * fx);
    return 1 + (v / w) * @exp(-sigma * tau) * @sin(w * tau) * window;
}

/// `exit` at a given level: the swing run backwards first — a draw back — then the approach run
/// backwards, gone at `arrival` after it set off.
pub fn exitAt(lv: f32, t: f32) f32 {
    const swing = swingAt(lv);
    const span = arrival + swing;
    const u = clamp01(t);
    if (u >= span) return 1;
    return 1 - swingEnterAt(lv, span - u);
}

/// The arrival `exit` runs backwards: constant speed to the target at `arrival`, then a short
/// swing that leaves with the approach's speed and comes back to rest `swingAt` later — a quick
/// draw back before something leaves, where a long one would only delay it.
fn swingEnterAt(lv: f32, t: f32) f32 {
    const u = clamp01(t);
    if (u <= arrival) return u / arrival;
    const swing = swingAt(lv);
    if (swing <= 0 or u >= arrival + swing) return 1;
    const x = (u - arrival) / swing;
    // y = 1 + B·sin(πx)·(1 − x): leaves 1 with slope B·π/swing, which is the approach's
    // 1/arrival, and lands back on 1 at rest.
    const b = swing / (std.math.pi * arrival);
    return 1 + b * @sin(std.math.pi * x) * (1 - x);
}

/// `settle` at a given level.
pub fn settleAt(lv: f32, t: f32) f32 {
    return enterAt(lv, t);
}

fn clamp01(t: f32) f32 {
    return std.math.clamp(t, 0, 1);
}
