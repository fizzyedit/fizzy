const std = @import("std");

const fizzy = @import("../../fizzy.zig");
const dvui = @import("dvui");

pub const Widgets = @This();

pub const FileWidget = @import("../../plugins/pixelart/widgets/FileWidget.zig");
pub const ImageWidget = @import("../../plugins/pixelart/widgets/ImageWidget.zig");
pub const CanvasWidget = @import("CanvasWidget.zig");
pub const ReorderWidget = @import("ReorderWidget.zig");
pub const PanedWidget = @import("PanedWidget.zig");
pub const FloatingWindowWidget = @import("FloatingWindowWidget.zig");
pub const TreeWidget = @import("TreeWidget.zig");
pub const TreeSelection = @import("TreeSelection.zig");
