//! Core module root: shared infrastructure (gfx, math, fs, generated atlas,
//! platform, paths, the generic dvui hub + generic widgets) that both the shell
//! and the plugins depend on. Core never imports the `fizzy` app hub.
//!
//! Cross-cutting app resources (the allocator, platform input) are injected at
//! startup via the context fields below so core stays decoupled from the App.
const std = @import("std");

/// Process allocator, set once at startup by the shell (`App`/`web_main`).
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
pub const perf = @import("gfx/perf.zig");
pub const water_surface = @import("gfx/water_surface.zig");
pub const math = @import("math/math.zig");
pub const fs = @import("fs.zig");
pub const platform = @import("platform.zig");
pub const paths = @import("paths.zig");

/// Generated atlas index (named sprite lookups). Written by the build's
/// process-assets step into `src/core/generated/`.
pub const atlas = @import("generated/atlas.zig");

/// Generic dvui hub: dialog framework, helpers, and the generic widgets.
pub const dvui = @import("dvui.zig");

/// Generic momentum/fling helper (pan, scrub, cover-flow).
pub const Fling = @import("Fling.zig");

/// Generic sprite sub-rect within an atlas texture.
pub const Sprite = @import("Sprite.zig");

/// Generic loaded spritesheet (`source` texture + sprite table).
pub const Atlas = @import("Atlas.zig");
