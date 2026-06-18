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
pub const algorithms = @import("plugins/pixelart/algorithms/algorithms.zig");
pub const fa = @import("tools/font_awesome.zig");
pub const fs = @import("tools/fs.zig");
pub const image = @import("gfx/image.zig");
pub const render = @import("plugins/pixelart/render.zig");

/// Atlas-consumer sprite rendering library (lives in the pixel-art plugin,
/// consumed by the shell/workbench to draw sprites from a packed atlas).
pub const sprite_render = @import("plugins/pixelart/sprite_render.zig");
pub const perf = @import("gfx/perf.zig");
pub const water_surface = @import("gfx/water_surface.zig");
pub const math = @import("math/math.zig");

pub const App = @import("App.zig");
pub const Editor = @import("editor/Editor.zig");
pub const Explorer = @import("editor/explorer/Explorer.zig");
pub const Fling = @import("editor/Fling.zig");
pub const Packer = @import("plugins/pixelart/Packer.zig");
//pub const Popups = @import("editor/popups/Popups.zig");
pub const Sidebar = @import("editor/Sidebar.zig");

// Global pointers
pub var app: *App = undefined;
pub var editor: *Editor = undefined;
pub var packer: *Packer = undefined;

/// Internal types
/// These types contain additional data to support the editor
/// An example of this is File. fizzy.File matches the file type to read from JSON,
/// while the fizzy.Internal.File contains cameras, timers, file-specific editor fields.
pub const Internal = struct {
    pub const Animation = @import("plugins/pixelart/internal/Animation.zig");
    pub const Atlas = @import("plugins/pixelart/internal/Atlas.zig");
    pub const Buffers = @import("plugins/pixelart/internal/Buffers.zig");
    pub const File = @import("plugins/pixelart/internal/File.zig");
    pub const History = @import("plugins/pixelart/internal/History.zig");
    pub const Layer = @import("plugins/pixelart/internal/Layer.zig");
    pub const Palette = @import("plugins/pixelart/internal/Palette.zig");
    pub const Sprite = @import("plugins/pixelart/internal/Sprite.zig");
};

/// Frame-by-frame sprite animation
pub const Animation = @import("plugins/pixelart/Animation.zig");

/// Contains lists of sprites and animations
pub const Atlas = @import("plugins/pixelart/Atlas.zig");

/// The data that gets written to disk in a .pixi file and read back into this type
pub const File = @import("plugins/pixelart/File.zig");

/// Contains information such as the name, visibility and collapse settings of a texture layer
pub const Layer = @import("plugins/pixelart/Layer.zig");

/// Source location within the atlas texture and origin location
pub const Sprite = @import("plugins/pixelart/Sprite.zig");

/// Runtime platform detection (`isMacOS()` etc.) that's accurate on wasm web
/// builds, where `builtin.os.tag` is always `.freestanding`.
pub const platform = @import("platform.zig");

/// Plugin SDK surface
pub const sdk = @import("sdk/sdk.zig");

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
