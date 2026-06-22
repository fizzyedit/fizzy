const std = @import("std");

/// Shared infrastructure module (gfx, math, fs, platform, paths, the generic
/// dvui hub + widgets). Consumed by the shell and plugins.
pub const core = @import("core");

pub const version: std.SemanticVersion = .{
    .major = 0,
    .minor = 2,
    .patch = 0,
};

// Other helpers and namespaces
pub const fs = core.fs;
pub const image = core.image;
pub const perf = core.perf;
pub const water_surface = core.water_surface;
pub const math = core.math;

pub const App = @import("App.zig");
pub const Editor = @import("editor/Editor.zig");
pub const Explorer = @import("editor/explorer/Explorer.zig");
pub const Fling = core.Fling;
//pub const Popups = @import("editor/popups/Popups.zig");
pub const Sidebar = @import("editor/Sidebar.zig");

// Global pointers
pub var app: *App = undefined;
pub var editor: *Editor = undefined;

/// Runtime platform detection (`isMacOS()` etc.) that's accurate on wasm web
/// builds, where `builtin.os.tag` is always `.freestanding`.
pub const platform = core.platform;

/// Plugin SDK surface
pub const sdk = @import("sdk");

/// Custom dvui stuff
pub const dvui = core.dvui;

/// Custom backend stuff. Split per-arch: native uses SDL3 + objc + win32; web is a
/// no-op stub layer (no window chrome, no native dialogs, no native menu bar).
/// Zig only semantically analyzes the chosen branch, so the wasm build never sees
/// the SDL3 / objc / win32 imports inside `backend/backend_native.zig`.
pub const backend = if (@import("builtin").target.cpu.arch == .wasm32)
    @import("backend/backend_web.zig")
else
    @import("backend/backend_native.zig");

pub const paths = core.paths;

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
