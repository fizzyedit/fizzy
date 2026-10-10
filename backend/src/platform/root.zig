//! What an app gets from its window beyond drawing into it — native file dialogs, files the OS
//! asks it to open, trackpad gestures, the window's chrome and state — for apps on dvui's SDL3
//! backends, fizzy's own (this package's `SDLBackend`) and dvui's. Each piece takes the SDL window and
//! nothing of any one app: where an app has a say (which folder a dialog opens in, what to do
//! with a file the OS hands over) it plugs in through a small hook.
//!
//! An app reaches it as the `platform` module, or through fizzy's backend (`backend.platform`).
pub const dialogs = @import("dialogs.zig");
pub const open_events = @import("open_events.zig");
pub const gestures = @import("gestures.zig");
pub const window = @import("window.zig");
pub const titlebar = @import("titlebar.zig");
pub const win32_titlebar = @import("win32_titlebar.zig");
pub const linux_titlebar = @import("linux_titlebar.zig");
pub const geometry = @import("geometry.zig");
pub const macos_monitor = @import("macos_monitor.zig");
pub const window_layout = @import("window_layout.zig");
pub const menu = @import("menu.zig");

/// Whether the app is on this package's backend (`SDLBackend`, which imports these pieces) rather
/// than dvui's own SDL3 backend. What they reach into beyond SDL's window — floats' windows, the
/// window skin, the present hook — is there only; on dvui's, those parts do nothing. One flag, not
/// a `@hasField` per field: a field renamed on this backend then fails its build, not goes quiet.
pub const own_backend = @hasDecl(@import("backend"), "platform");
