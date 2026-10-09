//! Core module root: shared infrastructure (gfx, math, fs, generated atlas,
//! platform, paths, the generic dvui hub + generic widgets) that both fizzy
//! and the plugins depend on. Core never imports the `fizzy` app hub.
//!
//! Cross-cutting app resources (the allocator, platform input) are injected at
//! startup via the context fields below so core stays decoupled from the App.
const std = @import("std");

/// Process allocator, set once at startup by fizzy itself (`App`/`web_main`).
/// Core infrastructure (e.g. `gfx.image`) allocates through this instead of
/// reaching into the App hub.
pub var gpa: std.mem.Allocator = undefined;

/// Trackpad pinch-zoom accessor, wired at startup by the platform backend
/// (native/web). Defaults to a no-op so headless/test builds work without it.
pub var takeTrackpadPinchRatio: *const fn () f32 = defaultTrackpadPinchRatio;

fn defaultTrackpadPinchRatio() f32 {
    return 1.0;
}

// Shared infrastructure re-exports.
pub const image = @import("gfx/image.zig");
pub const icon = @import("gfx/icon.zig");
pub const perf = @import("gfx/perf.zig");
pub const FrameTarget = @import("gfx/FrameTarget.zig");
/// TEMPORARY frame-hitch profiler (`FIZZY_HITCH_MS`).
pub const hitch = @import("hitch.zig");
/// The frame profiler behind the profiler window: fizzy's phases, plugin hooks and surfaces,
/// and the sections plugins mark in their own code.
pub const profile = @import("profile.zig");
pub const water_surface = @import("gfx/water_surface.zig");
pub const math = @import("math/math.zig");
pub const fs = @import("fs.zig");
pub const platform = @import("platform.zig");
pub const paths = @import("paths.zig");

/// Resolves the user's real login-shell `PATH` — see `shell_env.zig`.
pub const shell_env = @import("shell_env.zig");

/// Darwin-only raw `posix_spawn` wrapper — see `darwin_spawn.zig` for why.
pub const darwin_spawn = @import("darwin_spawn.zig");

/// The widgets both an app and a plugin dylib draw with: splits, tabs, trees, the canvas.
pub const widgets = @import("widgets.zig");
/// Reveals, cross-fades and transitions — the animation any region or pane swap runs through.
pub const anim = @import("anim.zig");
/// How things move: the one motion setting every animation reads (off, minimal, playful).
pub const motion = @import("motion.zig");
/// A motion's clock stepped by its frames, so a long frame holds it rather than skipping it on.
pub const FrameClock = @import("FrameClock.zig");
/// How round the app's corners are: the one Corner roundness setting every radius scales by.
pub const corners = @import("corners.zig");
/// Frosted glass that bends what it shows — lens at the rim, ripples through it.
pub const liquid_glass = @import("gfx/liquid_glass.zig");
pub const liquid_blob = @import("gfx/liquid_blob.zig");
/// One material on two sliders: every glass at the window's opacity and roughness, the OS's form
/// and the app's.
pub const glass_look = @import("gfx/glass_look.zig");
pub const LiquidField = @import("gfx/LiquidField.zig");
pub const programs = @import("gfx/programs.zig");
pub const Spring = @import("Spring.zig");
/// The dialog framework, its window chrome, and the toasts and spinners that share it.
pub const dialogs = @import("dialogs.zig");
/// Drawing helpers with no widget of their own: highlighted labels, menu rows, edge shadows.
pub const draw = @import("draw.zig");
/// How a keybind is drawn: glyphs and keycaps, in each platform's modifier order.
pub const keycaps = @import("keycaps.zig");
/// Names for what a demo points at — `dvui.tag` with a name built from data (a file's row, its
/// editor), free unless a demo is loaded.
pub const anchor = @import("anchor.zig");
/// The screens floating things are placed on: the main window's, and a popped-out float's.
pub const screens = @import("screens.zig");
/// Glass the OS draws in place of the app's: a view drag's, as Liquid Glass on macOS 26.
pub const native_glass = @import("native_glass.zig");

/// Generic momentum/fling helper (pan, scrub, cover-flow).
pub const Fling = @import("Fling.zig");

/// Generic sprite sub-rect within an atlas texture.
///
/// Nothing in fizzy draws a sprite any more — the editor's own icons went to tvg. These two
/// survive because **pixi** loads its packed UI atlas through them from inside its dylib
/// (`pixi/src/State.zig`, `runtime.zig`), and core is the only floor a plugin can reach. They
/// belong in pixi, and should move there the next time that repo is opened; core keeps them
/// until then so an out-of-tree plugin does not break mid-experiment.
pub const Sprite = @import("Sprite.zig");

/// Generic loaded spritesheet (`source` texture + sprite table). See `Sprite` above.
pub const Atlas = @import("Atlas.zig");

/// Server-agnostic LSP client (JSON-RPC framing, caching, threading) shared by every
/// language plugin. See `lsp/lsp.zig`.
pub const lsp = @import("lsp/lsp.zig");

/// Shared fuzzy matcher (zf) behind every filter box in the app. See `fuzzy.zig` — note that
/// lower scores are better.
pub const fuzzy = @import("fuzzy.zig");

/// The project's file set: one cached, searchable view of what is on disk, owned by the host and
/// shared by every plugin that cares about files. See `FileTable.zig`.
pub const FileTable = @import("FileTable.zig");
/// The mountable-filesystem contract (`vfs.Fs`): path-addressed, completion-based, wasm-safe.
/// A cloud plugin mounts one on the host's `FileTable`; the local disk is `LocalFs` behind the
/// same interface. See `docs/CLOUD_FS_PLAN.md`.
pub const vfs = @import("vfs/vfs.zig");
pub const LocalFs = @import("LocalFs.zig");
/// Long-running work as a stepped `Task`, run on a thread natively or from the frame on the
/// web — one implementation for both. See `work.zig`.
pub const work = @import("work.zig");
/// `vfs.http.Transport` implementations: the browser's `fetch` on the web build, a
/// `std.http.Client` per request on a thread everywhere else. A cloud plugin picks by target.
pub const transport = struct {
    pub const Web = if (@import("builtin").target.cpu.arch == .wasm32) @import("transport/WebTransport.zig") else struct {};
    /// A popup-based OAuth round trip for any provider (wasm only): open the URL, get the
    /// redirect's query/fragment back. What a cloud plugin signs in with on the web.
    pub const WebOAuth = if (@import("builtin").target.cpu.arch == .wasm32) @import("transport/WebOAuth.zig") else struct {};
    pub const Native = if (@import("builtin").target.cpu.arch != .wasm32) @import("transport/NativeTransport.zig") else struct {};
};

/// Fixed Fizzy accent colours — theme-independent. See `palette.zig`.
pub const palette = @import("palette.zig");
