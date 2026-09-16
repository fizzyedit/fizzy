//! Runtime platform detection that works on both native and wasm.
//!
//! On native, `builtin.os.tag` is the truth. On `wasm32-freestanding` it's
//! always `.freestanding`, so any `builtin.os.tag == .macos` check classifies
//! macOS web as "not mac" — which breaks ctrl/cmd shortcuts, pan/zoom defaults,
//! menu glyphs, etc. This module gives fizzy a single source of truth that
//! correctly reflects the running platform.
//!
//! On web we detect macOS by inspecting DVUI's own keybind selection. DVUI reads
//! `navigator.platform` in its `dvui_init` and installs either Windows-style
//! bindings (`ctrl+X` for cut, etc.) or Mac-style (`cmd+X`). The `"ctrl/cmd"`
//! binding is `{ .command = true }` on Mac and `{ .control = true }` on
//! Windows-style — that's the authoritative signal.
//!
//! Cache the result so we're not probing a hashmap every frame. `cacheFromWindow`
//! must be called once after `dvui.Window.init` (e.g. from `App.AppInit`).

const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");

/// Cached result. Read via `isMacOS()`. Defaults to the native `os.tag` value;
/// on wasm `cacheFromWindow` updates it once the DVUI window is initialized.
var cached_is_macos: bool = builtin.os.tag.isDarwin();

/// Call once after `dvui.Window.init`. On native this is a no-op (the comptime
/// `builtin.os.tag` default is already correct). On wasm this probes DVUI's
/// `"ctrl/cmd"` binding to discover whether the browser's `navigator.platform`
/// looked like macOS.
pub fn cacheFromWindow(win: *dvui.Window) void {
    if (comptime builtin.target.cpu.arch != .wasm32) return;
    const kb = win.keybinds.get("ctrl/cmd") orelse return;
    cached_is_macos = kb.command orelse false;
}

/// True if the running platform is macOS — unlike `builtin.os.tag == .macos`, right on web too.
pub inline fn isMacOS() bool {
    return cached_is_macos;
}

/// Returns a `std.process.Environ` populated from the libc `environ` global.
/// Used to bridge APIs (like `known-folders.getPath`) that require an
/// `Environ.Map` constructed from the parent process's environment.
pub fn processEnviron() std.process.Environ {
    if (comptime @import("builtin").target.cpu.arch == .wasm32) {
        const empty: [:null]const ?[*:0]const u8 = &.{};
        return .{ .block = .{ .slice = empty } };
    }
    if (@import("builtin").os.tag == .windows) {
        return .{ .block = .global };
    }
    var n: usize = 0;
    while (std.c.environ[n] != null) : (n += 1) {}
    const slice: [:null]const ?[*:0]const u8 = @as([*:null]const ?[*:0]const u8, @ptrCast(std.c.environ))[0..n :null];
    return .{ .block = .{ .slice = slice } };
}
