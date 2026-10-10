//! `viewports` for a backend without OS windows besides the main one — dvui's own SDL3 backend,
//! its testing backend, the web (one canvas): the same names as the backend package's own
//! (`viewports.zig`), every call saying there are none. `available` is false and `open` gives
//! null, so an app's floats, menus and dialogs stay in the main window.
//!
//! An app that builds on either kind of backend imports this beside it and takes the backend's
//! own where it has one:
//!
//!     const viewports = if (@hasDecl(backend, "viewports")) backend.viewports else @import("viewports_none");
const dvui = @import("dvui");

/// A window's Liquid Glass this frame, as the backend package's (`platform.window.WindowGlassLook`):
/// there is none here, but an app still says what it would be.
pub const WindowGlassLook = struct {
    under_variant: i32,
    under_style: i32,
    over_variant: i32,
    over_style: i32,
    frost: f32,
    blur: f32,
    glass: f32,
    fill: dvui.Color,
    fill_opacity: f32,
    top_fill: f32,
    radius: f32,
    clear: f32,
    feather: f32,
};

pub const supported = false;
pub fn available() bool {
    return false;
}
pub const Viewport = struct {};
pub const Rect = struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, h: f32 = 0 };

pub fn open(_: Rect, _: [:0]const u8) ?*Viewport {
    return null;
}
pub fn close(_: *Viewport) void {}
pub fn frameOf(_: *const Viewport) Rect {
    return .{};
}
pub fn place(_: *Viewport, frame: Rect) Rect {
    return frame;
}
pub fn present(_: *Viewport, _: ?dvui.TextureTarget) void {}
pub fn inMain(_: *const Viewport) Rect {
    return .{};
}
pub const os_frame = false;
pub const os_buttons = false;
pub const carries = false;
pub fn seeThrough(_: *Viewport, _: bool) void {}
pub fn fade(_: *Viewport, _: f32) void {}
pub fn maximized(_: *const Viewport) bool {
    return false;
}
pub fn coversDesktop(_: *const Viewport) bool {
    return false;
}
pub fn enteringSpace(_: *const Viewport) bool {
    return false;
}
pub fn spaceFullness(_: *const Viewport) ?f32 {
    return null;
}
pub fn carryShape(_: *Viewport, _: ?f32, _: f32) void {}
pub fn carryLens(_: *Viewport, _: bool) void {}
/// Any look, `WindowGlassLook` or the backend package's (an app on dvui's own SDL3 backend still
/// dresses its main window with `platform`'s): there is no viewport to give it to.
pub fn windowGlass(_: *Viewport, _: anytype) bool {
    return false;
}
pub fn underMain(_: *Viewport) bool {
    return false;
}
pub fn buttonsWidth(_: *Viewport) f32 {
    return 0;
}
pub fn windowRadius() f32 {
    return 0;
}
pub fn openCarry(_: Rect) ?*Viewport {
    return null;
}
pub const menus = false;
pub fn appActive() bool {
    return true;
}
pub const Ride = union(enum) { none, main, viewport: *Viewport };
pub fn orderAbove(_: *Viewport, _: *Viewport) void {}
pub fn lift(_: *Viewport, _: *Viewport) void {}
pub fn settle(_: *Viewport) void {}
pub fn placeRiding(_: *Viewport, frame: Rect, _: Rect) Rect {
    return frame;
}
pub fn openMenu(_: Rect, _: f32, _: Ride, _: bool) ?*Viewport {
    return null;
}
pub fn mainOffset(_: *Viewport, _: dvui.Point.Physical) void {}
pub const GlassShape = extern struct { x: f64, y: f64, w: f64, h: f64, radius: f64, lit: f64, alpha: f64, frost: f64 };
pub fn liquidGlass() bool {
    return false;
}
pub fn openOverlay(_: Rect) ?*Viewport {
    return null;
}
pub const GlassMaterial = struct { variant: i32, style: i32 };
pub const GlassLook = struct {
    under: GlassMaterial,
    over: GlassMaterial,
    over_share: f32,
    glass: f32 = 1,
    fill: dvui.Color = .black,
    fill_opacity: f32 = 0,
    lit_toward: dvui.Color = .white,
    lit_amount: f32 = 0,
    bevel: f32 = 0,
    bevel_cap: f32 = 0,
    bevel_clear: f32 = 0,
    blur: f32 = 0,
};
pub fn overlayGlass(_: *Viewport, _: []const GlassShape, _: f32, _: GlassLook) void {}
pub const OverlayPhoto = struct { rect: Rect, radius: f32, image: Rect, fill: dvui.Color, alpha: f32 = 1, blur: f32 = 0 };
pub fn overlayPhotoImage(_: *Viewport, _: ?[]const u8, _: u32, _: u32) void {}
pub fn overlayPhoto(_: *Viewport, _: ?OverlayPhoto) void {}
pub fn displayInMain() Rect {
    return .{};
}
pub const Hints = struct { drag: Rect, keep: Rect, glass: Rect, edge: f32, app_side: f32 = 0, app_corner: f32 = 0 };
pub fn hints(_: *Viewport, _: ?Hints) void {}
pub fn osPlaced(_: *Viewport) ?Rect {
    return null;
}
pub const MoveEnd = struct { resized: bool };
pub fn osMoveEnded(_: *Viewport) ?MoveEnd {
    return null;
}
pub fn dragMove(_: *Viewport) bool {
    return false;
}
pub fn minSize(_: *Viewport, _: f32, _: f32) void {}
pub fn setTitle(_: *Viewport, _: []const u8) void {}
pub fn glass(_: *Viewport, _: f32, _: f32, _: bool) bool {
    return false;
}
pub fn placeMain(_: *Viewport, frame: Rect) Rect {
    return frame;
}
pub fn bandFromMain(_: *const Viewport, frame: Rect) Rect {
    return frame;
}
pub fn shown(_: *const Viewport) bool {
    return false;
}
pub const Pin = union(enum) { none, main, viewport: *Viewport };
pub fn pinPointer(_: Pin) void {}
pub fn closeRequested(_: *const Viewport) bool {
    return false;
}
