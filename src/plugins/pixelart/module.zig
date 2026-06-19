//! Pixel-art plugin compile-time module root.
//!
//! Wired in `build.zig` as `b.addModule("pixelart", .{ .root_source_file = "module.zig" })`.
//! Shell code imports this as `@import("pixelart")`. Plugin files inside `src/` import
//! `../pixelart.zig` for shared types and `Globals`.
pub const pixelart = @import("pixelart.zig");
pub const Globals = pixelart.Globals;
pub const State = @import("src/State.zig");
pub const Settings = @import("src/Settings.zig");
pub const Docs = @import("src/Docs.zig");
pub const Tools = @import("src/Tools.zig");
pub const Transform = @import("src/Transform.zig");
pub const Project = @import("src/Project.zig");
pub const Colors = @import("src/Colors.zig");
pub const Packer = @import("src/Packer.zig");
pub const PackJob = @import("src/PackJob.zig");
pub const plugin = @import("src/plugin.zig");

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

pub const render = @import("src/render.zig");
pub const sprite_render = @import("src/sprite_render.zig");
pub const algorithms = @import("src/algorithms/algorithms.zig");

/// On-disk / JSON types.
pub const File = @import("src/File.zig");
pub const Layer = @import("src/Layer.zig");
pub const Sprite = @import("src/Sprite.zig");
pub const Atlas = @import("src/Atlas.zig");
pub const Animation = @import("src/Animation.zig");

/// Editor/runtime types (cameras, history, buffers, …).
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
