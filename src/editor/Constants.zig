//! Dev-level constants — not user-configurable, not persisted to `settings.zon`. Edit directly
//! and rebuild to change (mirrors the pattern pixi's own `State.zig` uses for its dev constants).
//! If a value here ever needs to become a real user preference, move it to `Settings.zig`
//! instead (which does persist and round-trip through the settings UI).

/// Height of the titlebar, in pixels.
pub const titlebar_height: f32 = 26.0;

// The infobar's height is not a constant: it scales with the body font. The one
// definition is `sdk.infobar` (`sdk/src/infobar.zig`). Plugins contribute `Entry`
// values (icon + text); fizzy draws them.

/// Empty strip below the top window edge (non-macOS), above the main title row (in-window menu, etc.).
pub const titlebar_top_buffer: f32 = 10.0;

/// The window's corner radius on Linux, where fizzy draws the window's shape itself (it is
/// undecorated and transparent): GNOME's own.
pub const linux_window_radius: f32 = 12.0;

/// The margin round the window's frame on Linux where fizzy draws the drop shadow a desktop gives
/// its own windows (`linux_titlebar.useClientDecorations`), in points; deeper below, where a
/// shadow falls. The compositor takes the frame inside it for the window.
pub const linux_window_shadow_insets = .{ .left = 20, .top = 14, .right = 20, .bottom = 26 };

pub const initial_window_size: [2]f32 = .{ 1200, 800 };

pub const min_window_size: [2]f32 = .{ 640, 480 };

/// Maximum number of recents before removing oldest.
pub const max_recents: usize = 10;

/// When true, print frame/draw perf stats to the console (Debug / ReleaseSafe only for tick stats).
pub const perf_logging: bool = false;

/// Pretend an app update is available (badge + launch toast) — a build-time debug flag now;
/// flip and rebuild to test the update-available UI.
pub const debug_simulate_update_available: bool = false;
