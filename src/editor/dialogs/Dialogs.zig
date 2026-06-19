const builtin = @import("builtin");
const dvui = @import("dvui");

const Dialogs = @This();

// Plugin-owned dialogs (New File, Grid Layout, Export, Flat-raster save warning) are no longer
// re-exported here. The shell triggers them through plugin vtable hooks / `Host.requestNewDocument`
// so it never names a plugin's dialog implementation. This hub owns only shell-level dialogs.
pub const UnsavedClose = @import("UnsavedClose.zig");
pub const AppQuitUnsaved = @import("AppQuitUnsaved.zig");
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
