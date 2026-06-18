const std = @import("std");
const builtin = @import("builtin");
const pixelart = @import("pixelart");
const dvui = @import("dvui");

const Dialogs = @This();

pub const NewFile = pixelart.dialogs.NewFile;
pub const Export = pixelart.dialogs.Export;
pub const UnsavedClose = @import("UnsavedClose.zig");
pub const AppQuitUnsaved = @import("AppQuitUnsaved.zig");
pub const GridLayout = pixelart.dialogs.GridLayout;
pub const FlatRasterSaveWarning = pixelart.dialogs.FlatRasterSaveWarning;
pub const AboutFizzy = @import("AboutFizzy.zig");
pub const WebFolderUnavailable = if (builtin.target.cpu.arch == .wasm32)
    @import("WebFolderUnavailable.zig")
else
    struct {
        pub fn request() void {}
        pub fn active(_: *dvui.Window) bool {
            return false;
        }
    };
pub const WebSaveAs = if (builtin.target.cpu.arch == .wasm32)
    @import("WebSaveAs.zig")
else
    struct {
        pub const Kind = enum { save, save_as };
        pub fn request(_: []const u8, _: Kind) void {}
        pub fn active(_: *dvui.Window) bool {
            return false;
        }
    };

pub fn drawDimensionsLabel(
    src: std.builtin.SourceLocation,
    width: u32,
    height: u32,
    font: dvui.Font,
    unit: []const u8,
    opts: dvui.Options,
) void {
    pixelart.dialogs.DimensionsLabel.drawDimensionsLabel(src, width, height, font, unit, opts);
}
