//! A window: the handle a `Platform` hands out, and the plain types that create and describe one.
//!
//! The file is the handle. It is a small value, copied freely; everything about the window lives
//! in the platform and is asked for through it (`Platform.windowSize`, …). Geometry units are in
//! `geometry.zig`.
const std = @import("std");
const geometry = @import("geometry.zig");

const Window = @This();

/// Assigned by the platform, unique for the process's life and never reused, so an event that
/// arrives after its window closed names a window that is gone, never another one. Zero is never
/// a window.
id: u64,

/// What a platform needs to make a window. Defaults make the plain, framed, opaque, shown one.
pub const Options = struct {
    /// UTF-8, copied by the platform before `openWindow` returns.
    title: []const u8 = "",
    /// The size to ask for, in desktop points: pixels cannot be asked for, since the scale
    /// depends on the display the window lands on. The platform may give another (a tiling
    /// compositor, a display too small); the first `Event.Payload.resized` is the truth.
    size: geometry.DesktopSize = .{ .w = 1280, .h = 720 },
    /// Desktop points; null lets the OS place it.
    position: ?geometry.DesktopPoint = null,
    state: State = .normal,
    /// Shown as soon as it is made. False creates it hidden, to be drawn once and revealed
    /// (`Platform.showWindow`) so the first picture is the right one, not an undrawn flash.
    visible: bool = true,
    /// Takes keyboard focus when shown. Menus and tooltips say false.
    focusable: bool = true,
    resizable: bool = true,
    /// No OS frame: the app draws its own title bar (see `Hints`).
    borderless: bool = false,
    material: MaterialSpec = .{},
    /// The window it belongs to, if any: it closes with it and (menus, dialogs) stays over it.
    parent: ?Window = null,
    kind: Kind = .normal,
};

/// What the OS is told the window is for, which decides its stacking, its task-switcher entry
/// and whether it takes focus. The set fizzy really opens: its windows, floats, menus, dialogs.
pub const Kind = enum { normal, float, menu, dialog };

/// A window's place in the user's arrangement. Orthogonal to `visible`: a hidden window keeps the
/// state it returns to.
pub const State = enum { normal, minimized, maximized, fullscreen };

/// The kinds of window material, from the plainest to the richest. Today the same five as
/// `backend/src/materials.zig`'s `Kind`; the SDL adapter maps one to the other, and a platform
/// may add kinds of its own. Whether a platform can draw one is `Platform.Caps.materials`;
/// asking for one it cannot is not an error: the platform falls back to the nearest plainer
/// one, and `Platform.windowMaterial` says which it got.
pub const MaterialKind = enum(u8) { none, transparent, blur, frost, liquid };

/// What a window is made of behind its picture: the kind and how it is drawn. Every field but
/// the kind is a default a kind may ignore (`none` ignores them all), so a new knob costs the
/// callers that do not set it nothing.
pub const MaterialSpec = struct {
    kind: MaterialKind = .none,
    /// How much of the window's colour covers what is behind, 0 (clear) to 1.
    opacity: f32 = 1,
    /// How strongly the kind acts: blur radius scale, glass refraction. 1 is the kind's own look.
    strength: f32 = 1,
    /// A colour mixed over the material, straight RGBA bytes; null, none.
    tint: ?[4]u8 = null,
    /// Corner radius of the material, in the window's physical pixels; 0, square.
    radius: f32 = 0,
};

/// The mouse cursor over a window, by meaning, so each platform picks its own picture. The set
/// dvui draws with. `hidden` hides the cursor over the window; any other shows it.
pub const Cursor = enum {
    arrow,
    ibeam,
    wait,
    wait_arrow,
    crosshair,
    resize_nw_se,
    resize_ne_sw,
    resize_w_e,
    resize_n_s,
    move,
    not_allowed,
    pointer,
    hidden,
};

/// Where an app-drawn frame (`Options.borderless`) is still the OS's to move or resize by, as
/// `viewport_map.Hints` says of fizzy's floats today: the OS moves and resizes a window itself, so
/// it snaps, tiles and maximizes, from what the app says each frame about where its header and
/// edges are. Window pixels from its top left, physical.
pub const Hints = struct {
    /// The header: a press there is the OS's to move the window by.
    drag: geometry.Rect = .{},
    /// Inside `drag`, still the app's: the header's buttons.
    keep: geometry.Rect = .{},
    /// The window's visible frame, whose edges resize it, `edge` in from each side. Zero `edge`:
    /// the OS resizes nothing (the platform has no resize regions, or the window is maximized).
    glass: geometry.Rect = .{},
    edge: f32 = 0,
    /// Where the OS resizes nothing from a hit test (macOS): how far in from the glass's sides,
    /// and along them from its corners, a press is the app's however it lies over the header.
    app_side: f32 = 0,
    app_corner: f32 = 0,
};

test "a window handle is just its id" {
    try std.testing.expectEqual(@sizeOf(u64), @sizeOf(Window));
}
