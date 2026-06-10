const std = @import("std");
const mach = @import("mach");
const Core = mach.Core;

pub const version: std.SemanticVersion = .{
    .major = 0,
    .minor = 2,
    .patch = 0,
};

// Generated files, these contain helpers for autocomplete
// So you can get a named index into atlas.sprites
pub const atlas = @import("generated/atlas.zig");

// Other helpers and namespaces
pub const algorithms = @import("algorithms/algorithms.zig");
pub const fa = @import("tools/font_awesome.zig");
pub const fs = @import("tools/fs.zig");
pub const image = @import("gfx/image.zig");
pub const render = @import("gfx/render.zig");
pub const perf = @import("gfx/perf.zig");
pub const water_surface = @import("gfx/water_surface.zig");
pub const math = @import("math/math.zig");

pub const App = @import("App.zig");
pub const Assets = @import("Assets.zig");
pub const Editor = @import("editor/Editor.zig");
pub const Explorer = @import("editor/explorer/Explorer.zig");
pub const Fling = @import("editor/Fling.zig");
pub const Packer = @import("tools/Packer.zig");
//pub const Popups = @import("editor/popups/Popups.zig");
pub const Sidebar = @import("editor/Sidebar.zig");

// Global pointers
pub var app: *App = undefined;
pub var editor: *Editor = undefined;
pub var packer: *Packer = undefined;
pub var assets: *Assets = undefined;

/// Internal types
/// These types contain additional data to support the editor
/// An example of this is File. fizzy.File matches the file type to read from JSON,
/// while the fizzy.Internal.File contains cameras, timers, file-specific editor fields.
pub const Internal = struct {
    pub const Animation = @import("internal/Animation.zig");
    pub const Atlas = @import("internal/Atlas.zig");
    pub const Buffers = @import("internal/Buffers.zig");
    pub const File = @import("internal/File.zig");
    pub const History = @import("internal/History.zig");
    pub const Layer = @import("internal/Layer.zig");
    pub const Palette = @import("internal/Palette.zig");
    pub const Sprite = @import("internal/Sprite.zig");
};

/// Frame-by-frame sprite animation
pub const Animation = @import("Animation.zig");

/// Contains lists of sprites and animations
pub const Atlas = @import("Atlas.zig");

/// The data that gets written to disk in a .pixi file and read back into this type
pub const File = @import("File.zig");

/// Contains information such as the name, visibility and collapse settings of a texture layer
pub const Layer = @import("Layer.zig");

/// Source location within the atlas texture and origin location
pub const Sprite = @import("Sprite.zig");

/// Runtime platform detection (`isMacOS()` etc.) that's accurate on wasm web
/// builds, where `builtin.os.tag` is always `.freestanding`.
pub const platform = @import("platform.zig");

/// Custom dvui stuff
pub const dvui = @import("dvui.zig");

/// Custom backend stuff. Split per-arch: native uses SDL3 + objc + win32; web is a
/// no-op stub layer (no window chrome, no native dialogs, no native menu bar).
/// Zig only semantically analyzes the chosen branch, so the wasm build never sees
/// the SDL3 / objc / win32 imports inside `backend_native.zig`.
pub const backend = if (@import("builtin").target.cpu.arch == .wasm32)
    @import("backend_web.zig")
else
    @import("backend_native.zig");

pub const paths = @import("paths.zig");

/// Returns a `std.process.Environ` populated from the libc `environ` global.
/// Used to bridge APIs (like `known-folders.getPath`) that require an
/// `Environ.Map` constructed from the parent process's environment.
pub fn processEnviron() std.process.Environ {
    if (@import("builtin").os.tag == .windows) {
        return .{ .block = .global };
    }
    var n: usize = 0;
    while (std.c.environ[n] != null) : (n += 1) {}
    const slice: [:null]const ?[*:0]const u8 = @as([*:null]const ?[*:0]const u8, @ptrCast(std.c.environ))[0..n :null];
    return .{ .block = .{ .slice = slice } };
}
