//! The few plain shapes the interface speaks in, and the unit each one is in.
//!
//! Two units, never mixed in one type:
//!
//! - **Physical pixels** (`f32`/`u32`): everything about a window's own picture. The size of its
//!   drawable, a pointer's place in it from its top left, a touch's, a wheel's. This is dvui's
//!   "natural" pixel, and what the renderer draws in; a platform does the dividing by the display's
//!   scale itself, so nothing above it learns what a point is.
//! - **Desktop points** (`i32`): where a window stands among the displays, and the displays'
//!   bounds. The OS places windows in points and so does a saved window position
//!   (`viewport_map.ScreenRect`), so the interface does not round-trip them through pixels, which
//!   is ambiguous when two displays have different scales. `Window.scale` and `Display.scale` are
//!   the pixels per point that convert one to the other, for that window or display only.
//!
//! The origin of both is the top left, y down, and desktop points may be negative (a display left
//! of or above the primary one).

/// A place in a window, in physical pixels from its top left.
pub const Point = struct {
    x: f32 = 0,
    y: f32 = 0,
};

/// A window's drawable size, in physical pixels. Never negative; zero while minimized or not yet
/// laid out, which the renderer must treat as "do not draw".
pub const Size = struct {
    w: u32 = 0,
    h: u32 = 0,
};

/// A position across a window as a fraction of it: 0..1 from the top left. For devices that
/// have no pixel of their own (a touch screen reports where on itself, not where on the window).
pub const Norm = struct {
    x: f32 = 0,
    y: f32 = 0,
};

/// A size in desktop points: how big to make a window before the display it lands on, and so its
/// scale, is known.
pub const DesktopSize = struct {
    w: u32 = 0,
    h: u32 = 0,
};

/// A place on the desktop, in desktop points.
pub const DesktopPoint = struct {
    x: i32 = 0,
    y: i32 = 0,
};

/// A rectangle on the desktop, in desktop points.
pub const DesktopRect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
};

/// A rectangle in a window, in physical pixels from its top left.
pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
};
