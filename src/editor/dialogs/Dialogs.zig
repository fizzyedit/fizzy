const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const fizzy = @import("../../fizzy.zig");

const Dialogs = @This();

pub const NewFile = fizzy.pixelart_mod.dialogs.NewFile;
pub const Export = fizzy.pixelart_mod.dialogs.Export;
pub const UnsavedClose = @import("UnsavedClose.zig");
pub const AppQuitUnsaved = @import("AppQuitUnsaved.zig");
pub const GridLayout = fizzy.pixelart_mod.dialogs.GridLayout;
pub const FlatRasterSaveWarning = fizzy.pixelart_mod.dialogs.FlatRasterSaveWarning;
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

pub fn drawDimensionsLabel(src: std.builtin.SourceLocation, width: u32, height: u32, font: dvui.Font, unit: []const u8, opts: dvui.Options) void {
    {
        var hbox = dvui.box(src, .{ .dir = .horizontal }, opts);
        defer hbox.deinit();

        dvui.label(
            src,
            "{d}",
            .{width},
            .{
                .font = font,
                .margin = .{ .x = 1, .w = 1 },
                .padding = .all(0),
                .gravity_y = 1.0,
                .id_extra = 1,
            },
        );

        dvui.label(
            src,
            "{s}",
            .{unit},
            .{
                .font = dvui.Font.theme(.body).withSize(font.size - 1.0),
                .margin = .{ .x = 1, .w = 1 },
                .padding = .all(0),
                .gravity_y = 0.5,
                .id_extra = 2,
            },
        );

        dvui.label(
            src,
            "x",
            .{},
            .{
                .font = dvui.Font.theme(.body).withSize(font.size - 1.0),
                .margin = .{ .x = 1, .w = 1 },
                .padding = .all(0),
                .gravity_y = 0.5,
                .id_extra = 3,
            },
        );

        dvui.label(
            src,
            "{d}",
            .{height},
            .{
                .font = font,
                .margin = .{ .x = 1, .w = 1 },
                .padding = .all(0),
                .gravity_y = 0.5,
                .id_extra = 4,
            },
        );

        dvui.label(
            src,
            "{s}",
            .{unit},
            .{
                .font = dvui.Font.theme(.body).withSize(font.size - 1.0),
                .margin = .{ .x = 1, .w = 1 },
                .padding = .all(0),
                .gravity_y = 0.5,
                .id_extra = 5,
            },
        );
    }
}
