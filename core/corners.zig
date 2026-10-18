//! How round the app's corners are: one user setting, **Corner roundness**, that every rounded
//! surface draws through — from square, through as designed, to twice as round.
//!
//! A call site keeps the radius it was designed with and asks for it at the user's roundness:
//! `dvui.CornerRect.all(core.corners.scaled(8))`, or by name — `surface`, `card`, `control`,
//! `row`, `small` — for the sizes the app shares. Anything meant to be fully round (a pill, a dot)
//! is not a radius but a shape, and stays as it is. dvui's own widgets take their corner from the
//! theme, which the host scales by the same factor when it applies one.
//!
//! **One value everywhere.** The host publishes the setting into the shared dvui window each
//! frame (`publish`); a plugin dylib's copy of this file reads it from there, the way it reads the
//! dialog style and `core.motion`.
const std = @import("std");
const dvui = @import("dvui");

/// The setting's middle: every radius as designed.
pub const default_roundness: f32 = 0.5;

/// Points, as designed: dialogs, menus, popovers, tooltips.
pub const surface: f32 = 8;
/// Points, as designed: the window's places, the drag card, cards inside a plugin.
pub const card: f32 = 12;
/// Points, as designed: buttons and fields inside a surface.
pub const control: f32 = 10;
/// Points, as designed: a row's hover wash, a corner button, small chips.
pub const row: f32 = 4;
pub const small: f32 = 6;

const publish_id: dvui.Id = @fromBackingInt(@intCast(0x6669_7a7a_636f_726e)); // "fizzcorn"
const publish_key = "_corner_roundness";

/// Host only, each frame: the Corner roundness setting, 0 (square) to 1 (twice as round).
pub fn publish(setting: f32) void {
    if (dvui.current_window == null) return;
    dvui.dataSet(null, publish_id, publish_key, std.math.clamp(setting, 0, 1));
}

/// What every radius is multiplied by: 0 square, 1 as designed, 2 twice as round.
pub fn factor() f32 {
    if (dvui.current_window == null) return 1;
    return 2 * (dvui.dataGet(null, publish_id, publish_key, f32) orelse default_roundness);
}

/// The factor a setting gives, for the host scaling a theme before anything is published.
pub fn factorFor(setting: f32) f32 {
    return 2 * std.math.clamp(setting, 0, 1);
}

/// A radius designed as `base` points, at the user's roundness.
pub fn scaled(base: f32) f32 {
    return base * factor();
}

/// `dvui.CornerRect.all` (the theme's kind of corner) at `base` points, scaled.
pub fn all(base: f32) dvui.CornerRect {
    return .all(scaled(base));
}

/// `dvui.CornerRect.round` (always round) at `base` points, scaled.
pub fn round(base: f32) dvui.CornerRect {
    return .round(scaled(base));
}
