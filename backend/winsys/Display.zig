//! A display (monitor), as the platform found it at the moment it was asked.
//!
//! A snapshot, not a live object: displays come and go (a laptop closed, a cable pulled), and
//! ordering is not stable across that, so keep `id`, not an index. Units are in `geometry.zig`:
//! bounds in desktop points, `scale` the pixels per point.
const geometry = @import("geometry.zig");

const Display = @This();

/// Stable while the display stays connected, never reused for a different one.
id: u64,
/// UTF-8. Every name in a `Platform.displays` result is its own allocation from the caller's
/// allocator (an empty name is an empty allocation, never a literal), so `freeDisplays` can
/// free each.
name: []const u8,
/// The whole display on the desktop. Not necessarily positive: a display left of or above the
/// primary one has negative origin.
bounds: geometry.DesktopRect,
/// The part of `bounds` left after system UI (menu bar, dock, task bar).
usable: geometry.DesktopRect,
/// Physical pixels per desktop point. 1 on a standard display, 2 on a typical high-density one,
/// fractional under Windows or Wayland scaling.
scale: f32 = 1,
/// Hz; zero when the platform cannot say. Variable-rate displays report their maximum.
refresh_hz: f32 = 0,
primary: bool = false,
