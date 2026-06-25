//! Pixi plugin root module **and** intra-plugin import hub.
//!
//! - The shell resolves `@import("pixi")` to this file when the plugin is compiled into the app
//!   (static embed) and reaches its public surface here.
//! - Files under `src/` import it as `../pixi.zig` for the shared deps (`sdk`/`core`/`dvui` +
//!   core conveniences) and sibling types — the conventional `<package>.zig` namespace.
//!
//! It must sit at the plugin root: a Zig module cannot import files above its root file's
//! directory, so this has to be beside `src/` to re-export from it. The build-side static-embed
//! glue lives in `static/`.
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

/// On-disk file format version stamp (kept in sync with `fizzy.version`).
pub const version: std.SemanticVersion = .{ .major = 0, .minor = 2, .patch = 0 };
/// Layer rename buffer size (was `Editor.Constants.max_name_len`).
pub const max_name_len = 256;

pub const plugin = @import("src/plugin.zig");
pub const runtime = @import("src/runtime.zig");

pub const State = @import("src/State.zig");
pub const Settings = @import("src/Settings.zig");
pub const Docs = @import("src/Docs.zig");
pub const Tools = @import("src/Tools.zig");
pub const Transform = @import("src/Transform.zig");
pub const Project = @import("src/Project.zig");
pub const Colors = @import("src/Colors.zig");
pub const Packer = @import("src/Packer.zig");
pub const PackJob = @import("src/PackJob.zig");
pub const File = @import("src/File.zig");
pub const Layer = @import("src/Layer.zig");
pub const Sprite = @import("src/Sprite.zig");
pub const Atlas = @import("src/Atlas.zig");
pub const Animation = @import("src/Animation.zig");

pub const render = @import("src/render.zig");
pub const sprite_render = @import("src/sprite_render.zig");
pub const algorithms = @import("src/algorithms/algorithms.zig");

pub const dialogs = struct {
    pub const NewFile = @import("src/dialogs/NewFile.zig");
    pub const Export = @import("src/dialogs/Export.zig");
    pub const GridLayout = @import("src/dialogs/GridLayout.zig");
    pub const FlatRasterSaveWarning = @import("src/dialogs/FlatRasterSaveWarning.zig");
    pub const DimensionsLabel = @import("src/dialogs/dimensions_label.zig");
};

pub const explorer = struct {
    pub const project = @import("src/explorer/project.zig");
};

pub const widgets = struct {
    pub const FileWidget = @import("src/widgets/FileWidget.zig");
    pub const ImageWidget = @import("src/widgets/ImageWidget.zig");
    pub const CanvasBridge = @import("src/widgets/CanvasBridge.zig");
};

pub const internal = struct {
    pub const Animation = @import("src/internal/Animation.zig");
    pub const Atlas = @import("src/internal/Atlas.zig");
    pub const Buffers = @import("src/internal/Buffers.zig");
    pub const File = @import("src/internal/File.zig");
    pub const History = @import("src/internal/History.zig");
    pub const Layer = @import("src/internal/Layer.zig");
    pub const Palette = @import("src/internal/Palette.zig");
    pub const Sprite = @import("src/internal/Sprite.zig");
};
