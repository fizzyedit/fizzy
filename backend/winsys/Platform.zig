//! What a windowing backend is: a `{ctx, vtable}` the app calls to make windows and read
//! events, and nothing else. SDL3 (`backend/src/SDLBackend.zig`), a Sim that replays a tape, and
//! the native Zig platforms are each one; the app cannot tell which.
//!
//! **Threading.** Every function is called from the one thread that polls, except `wake`, which
//! any thread may call. **Errors.** A function that can fail for a reason the app can act on
//! returns an error; one that merely may not be honoured (a title, a cursor) returns void and
//! the platform does its best. **Ownership.** Anything a function returns that is not borrowed
//! says whose allocator made it. Events borrow (`Event`).
const std = @import("std");
const geometry = @import("geometry.zig");
const Window = @import("Window.zig");
const Display = @import("Display.zig");
const Event = @import("Event.zig");
const Drop = @import("Drop.zig");
const Ime = @import("Ime.zig");
const Clipboard = @import("Clipboard.zig");

const Platform = @This();

ctx: *anyopaque,
vtable: *const VTable,
/// What this platform can do at all, fixed for its life; what it can do *now* (a compositor that
/// lost its blur) is asked of the window.
caps: Caps,

/// Why a call that can fail did. Not an `anyerror`: a caller can act on each.
pub const Error = std.mem.Allocator.Error || error{
    /// The platform cannot do it (a window kind on the web, a second window on a phone).
    Unsupported,
    /// It can, but not now: too many windows, no display, the OS refused.
    PlatformFailed,
};

pub const Caps = struct {
    /// Which `Window.MaterialKind`s it can draw.
    materials: std.EnumSet(Window.MaterialKind) = .initOne(.none),
    /// More than one window at once: false on the web and on a phone.
    multiple_windows: bool = true,
    /// `Window.Kind.overlay`: non-activating, click-through windows. Opening one elsewhere is
    /// `error.Unsupported`.
    overlay: bool = false,
};

/// The platform's own report of when pictures reach the screen: the frame-pacing seam. The
/// presenting side (display link on macOS and iOS, DWM on Windows, presentation feedback on
/// Wayland) knows when the next vsync is and how long a frame has; a loop that asks does not
/// have to sleep and guess. It is a seam, not the whole feature: submitting a frame *at* a
/// time, and learning when one *was* shown, are deferred and will be `VTable` functions beside
/// this one. Fixing the question now lets the conformance suite pin a pacing test (plans#51,
/// step 6) against any platform.
pub const FrameTiming = struct {
    /// The time between presents on the display the window is on.
    refresh_ns: u64,
    /// When the next present will happen, on the `Platform.now` clock. If it cannot be known,
    /// the last one plus `refresh_ns`, with `source` saying so.
    next_present_ns: u64,
    source: enum { display_link, dwm, presentation_feedback, estimate },
};

pub const VTable = struct {
    // ---- the loop ------------------------------------------------------------------------
    /// The monotonic clock events are stamped on, nanoseconds.
    now: *const fn (ctx: *anyopaque) u64,
    /// The next event, or null if none is waiting. The previous event's borrowed memory is
    /// invalidated by this call.
    poll: *const fn (ctx: *anyopaque) ?Event,
    /// Blocks until an event is waiting, `wake` is called or `timeout_ns` passes (null: forever).
    /// How an idle app costs nothing between frames.
    wait: *const fn (ctx: *anyopaque, timeout_ns: ?u64) void,
    /// Wakes a `wait` from any thread (a background job finished); `wait` then returns at once.
    wake: *const fn (ctx: *anyopaque) void,
    /// Null if the platform cannot say; callers then pace by `Display.refresh_hz`.
    frame_timing: ?*const fn (ctx: *anyopaque, window: Window) ?FrameTiming = null,

    // ---- windows -------------------------------------------------------------------------
    open_window: *const fn (ctx: *anyopaque, options: Window.Options) Error!Window,
    /// Closes it now. Idempotent; events already queued for it are still delivered.
    close_window: *const fn (ctx: *anyopaque, window: Window) void,
    set_title: *const fn (ctx: *anyopaque, window: Window, title: []const u8) void,
    window_size: *const fn (ctx: *anyopaque, window: Window) geometry.Size,
    set_window_size: *const fn (ctx: *anyopaque, window: Window, size: geometry.DesktopSize) void,
    window_scale: *const fn (ctx: *anyopaque, window: Window) f32,
    window_position: *const fn (ctx: *anyopaque, window: Window) geometry.DesktopPoint,
    set_window_position: *const fn (ctx: *anyopaque, window: Window, at: geometry.DesktopPoint) void,
    window_state: *const fn (ctx: *anyopaque, window: Window) Window.State,
    /// A request; the OS may defer it (a full-screen transition animates), and the `state` and
    /// `resized` events say when it happened. Never nests a frame: a caller inside a frame may
    /// call it and the platform defers the work (`backend/AGENTS.md`, "Full screen").
    set_window_state: *const fn (ctx: *anyopaque, window: Window, state: Window.State) void,
    /// Shows a window made with `visible = false`, or one hidden since.
    show_window: *const fn (ctx: *anyopaque, window: Window, visible: bool) void,
    /// Brings it forward and gives it keyboard focus.
    raise_window: *const fn (ctx: *anyopaque, window: Window) void,
    set_cursor: *const fn (ctx: *anyopaque, window: Window, cursor: Window.Cursor) void,
    set_hints: *const fn (ctx: *anyopaque, window: Window, hints: Window.Hints) void,
    set_material: *const fn (ctx: *anyopaque, window: Window, material: Window.MaterialSpec) void,
    /// The kind the window is made of now, which is `set_material`'s if the platform could.
    window_material: *const fn (ctx: *anyopaque, window: Window) Window.MaterialKind,
    /// The display most of the window is on; null while it is on none.
    display_of: *const fn (ctx: *anyopaque, window: Window) ?u64,

    // ---- displays ------------------------------------------------------------------------
    /// Every display now, in the platform's order; `allocator` owns the slice and the names
    /// (free with `freeDisplays`).
    displays: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) Error![]Display,

    // ---- text input ----------------------------------------------------------------------
    /// Whether keystrokes in the window are offered as `text`/`ime` events. On while an editor
    /// has focus, off otherwise, so a phone's keyboard comes and goes with it.
    set_text_input: *const fn (ctx: *anyopaque, window: Window, on: bool) void,
    set_ime_area: *const fn (ctx: *anyopaque, window: Window, area: Ime.Area) void,

    // ---- clipboard -----------------------------------------------------------------------
    /// A write by `set_clipboard_text` changes the serial but sends no event.
    clipboard_serial: *const fn (ctx: *anyopaque) Clipboard,
    /// The text on the clipboard, or null if it holds none; `allocator` owns the result.
    clipboard_text: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) Error!?[]u8,
    /// The platform copies `text` before returning.
    set_clipboard_text: *const fn (ctx: *anyopaque, text: []const u8) Error!void,

    // ---- drops from other programs -----------------------------------------------
    drop_respond: *const fn (ctx: *anyopaque, window: Window, response: Drop.Response) void,
};

// The functions below are the interface's surface, one per `VTable` function (as `std.Io` does):
// a call site reads `platform.poll()` and not a vtable, and a platform that lacks an optional
// function is answered for here. They are the interface, not wrappers over a library call.

pub fn now(self: Platform) u64 {
    return self.vtable.now(self.ctx);
}

pub fn poll(self: Platform) ?Event {
    return self.vtable.poll(self.ctx);
}

pub fn wait(self: Platform, timeout_ns: ?u64) void {
    self.vtable.wait(self.ctx, timeout_ns);
}

pub fn wake(self: Platform) void {
    self.vtable.wake(self.ctx);
}

/// Null when the platform cannot say.
pub fn frameTiming(self: Platform, window: Window) ?FrameTiming {
    const f = self.vtable.frame_timing orelse return null;
    return f(self.ctx, window);
}

pub fn openWindow(self: Platform, options: Window.Options) Error!Window {
    return self.vtable.open_window(self.ctx, options);
}

pub fn closeWindow(self: Platform, window: Window) void {
    self.vtable.close_window(self.ctx, window);
}

pub fn setTitle(self: Platform, window: Window, title: []const u8) void {
    self.vtable.set_title(self.ctx, window, title);
}

pub fn windowSize(self: Platform, window: Window) geometry.Size {
    return self.vtable.window_size(self.ctx, window);
}

pub fn setWindowSize(self: Platform, window: Window, size: geometry.DesktopSize) void {
    self.vtable.set_window_size(self.ctx, window, size);
}

pub fn windowScale(self: Platform, window: Window) f32 {
    return self.vtable.window_scale(self.ctx, window);
}

pub fn windowPosition(self: Platform, window: Window) geometry.DesktopPoint {
    return self.vtable.window_position(self.ctx, window);
}

pub fn setWindowPosition(self: Platform, window: Window, at: geometry.DesktopPoint) void {
    self.vtable.set_window_position(self.ctx, window, at);
}

pub fn windowState(self: Platform, window: Window) Window.State {
    return self.vtable.window_state(self.ctx, window);
}

pub fn setWindowState(self: Platform, window: Window, state: Window.State) void {
    self.vtable.set_window_state(self.ctx, window, state);
}

pub fn showWindow(self: Platform, window: Window, visible: bool) void {
    self.vtable.show_window(self.ctx, window, visible);
}

pub fn raiseWindow(self: Platform, window: Window) void {
    self.vtable.raise_window(self.ctx, window);
}

pub fn setCursor(self: Platform, window: Window, cursor: Window.Cursor) void {
    self.vtable.set_cursor(self.ctx, window, cursor);
}

pub fn setHints(self: Platform, window: Window, hints: Window.Hints) void {
    self.vtable.set_hints(self.ctx, window, hints);
}

pub fn setMaterial(self: Platform, window: Window, material: Window.MaterialSpec) void {
    self.vtable.set_material(self.ctx, window, material);
}

pub fn windowMaterial(self: Platform, window: Window) Window.MaterialKind {
    return self.vtable.window_material(self.ctx, window);
}

pub fn displayOf(self: Platform, window: Window) ?u64 {
    return self.vtable.display_of(self.ctx, window);
}

/// Free with `freeDisplays` and the same allocator.
pub fn displays(self: Platform, allocator: std.mem.Allocator) Error![]Display {
    return self.vtable.displays(self.ctx, allocator);
}

/// Frees a `displays` result: the names and the slice.
pub fn freeDisplays(allocator: std.mem.Allocator, list: []Display) void {
    for (list) |d| allocator.free(d.name);
    allocator.free(list);
}

pub fn setTextInput(self: Platform, window: Window, on: bool) void {
    self.vtable.set_text_input(self.ctx, window, on);
}

pub fn setImeArea(self: Platform, window: Window, area: Ime.Area) void {
    self.vtable.set_ime_area(self.ctx, window, area);
}

pub fn clipboardSerial(self: Platform) Clipboard {
    return self.vtable.clipboard_serial(self.ctx);
}

/// Free the result with `allocator`.
pub fn clipboardText(self: Platform, allocator: std.mem.Allocator) Error!?[]u8 {
    return self.vtable.clipboard_text(self.ctx, allocator);
}

pub fn setClipboardText(self: Platform, text: []const u8) Error!void {
    return self.vtable.set_clipboard_text(self.ctx, text);
}

pub fn dropRespond(self: Platform, window: Window, response: Drop.Response) void {
    self.vtable.drop_respond(self.ctx, window, response);
}
