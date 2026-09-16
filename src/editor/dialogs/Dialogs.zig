const builtin = @import("builtin");
const dvui = @import("dvui");

const Dialogs = @This();

// Only fizzy-level dialogs. Plugin-owned dialogs (New File, Export, …) are reached through
// plugin vtable hooks / `Host.requestNewDocument`; fizzy never names a plugin's dialog.
pub const UnsavedClose = @import("UnsavedClose.zig");
pub const FileChangedOnDisk = @import("FileChangedOnDisk.zig");
pub const AppQuitUnsaved = @import("AppQuitUnsaved.zig");
pub const AboutFizzy = @import("AboutFizzy.zig");
pub const PluginUpdates = @import("PluginUpdates.zig");
pub const FileTypeDefaults = @import("FileTypeDefaults.zig");
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
