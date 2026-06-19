//! Intra-plugin import hub for the pixel-art plugin.
//!
//! Files inside `src/plugins/pixelart/src/**` import this as `../pixelart.zig` (or
//! `../../pixelart.zig` from nested dirs) instead of `fizzy.zig` for sdk/core/Globals
//! and shared plugin types. The compile-time module root for the build is `module.zig`
//! (`@import("pixelart")`); shell code imports the module directly.
const std = @import("std");

pub const sdk = @import("sdk");
pub const core = @import("core");
pub const dvui = @import("dvui");
pub const atlas = core.atlas;
pub const math = core.math;
pub const image = core.image;
pub const fs = core.fs;
pub const perf = core.perf;
pub const Fling = core.Fling;
pub const water_surface = core.water_surface;
pub const core_sprite = core.Sprite;
pub const Globals = @import("src/Globals.zig");

/// On-disk file format version stamp (kept in sync with `fizzy.version`).
pub const version: std.SemanticVersion = .{ .major = 0, .minor = 2, .patch = 0 };

pub const State = @import("src/State.zig");
pub const Settings = @import("src/Settings.zig");
pub const Docs = @import("src/Docs.zig");
pub const Tools = @import("src/Tools.zig");
pub const Transform = @import("src/Transform.zig");
pub const Animation = @import("src/Animation.zig");
pub const Layer = @import("src/Layer.zig");
pub const Sprite = @import("src/Sprite.zig");
pub const Atlas = @import("src/Atlas.zig");
pub const File = @import("src/File.zig");
pub const render = @import("src/render.zig");
pub const sprite_render = @import("src/sprite_render.zig");
pub const algorithms = @import("src/algorithms/algorithms.zig");

pub const explorer = struct {
    pub const project = @import("src/explorer/project.zig");
};

pub const internal = struct {
    pub const File = @import("src/internal/File.zig");
    pub const Layer = @import("src/internal/Layer.zig");
    pub const Palette = @import("src/internal/Palette.zig");
    pub const Atlas = @import("src/internal/Atlas.zig");
    pub const History = @import("src/internal/History.zig");
    pub const Buffers = @import("src/internal/Buffers.zig");
    pub const Animation = @import("src/internal/Animation.zig");
    pub const Sprite = @import("src/internal/Sprite.zig");
};

/// Layer rename buffer size (was `Editor.Constants.max_name_len`).
pub const max_name_len = 256;
