//! Wasm-target stubs for `backend.zig`'s public surface. Mirrors the native API so
//! `fizzy.backend.X` keeps type-checking on web — call sites that would do something
//! native-only (window decorations, native menus, OS file dialogs) compile to no-ops
//! or browser equivalents (file picker + download).

const std = @import("std");
const dvui = @import("dvui");
const builtin = @import("builtin");

const WebFileIo = if (builtin.target.cpu.arch == .wasm32)
    @import("editor/WebFileIo.zig")
else
    struct {};

// Mirrors `sdl3.SDL_DialogFileFilter`'s layout. Native backend re-exports
// the SDL3 type as `DialogFileFilter`; the editor uses `fizzy.backend.DialogFileFilter`
// at call sites so both arches see one coherent type.
pub const DialogFileFilter = extern struct {
    name: [*:0]const u8,
    pattern: [*:0]const u8,
};
/// Back-compat alias: a few internal callers still use the SDL-style name.
pub const SDL_DialogFileFilter = DialogFileFilter;

pub const NativeMenuAction = enum(c_int) {
    open_folder = 0,
    open_files = 1,
    save = 2,
    copy = 3,
    paste = 4,
    undo = 5,
    redo = 6,
    transform = 7,
    toggle_explorer = 8,
    show_dvui_demo = 9,
    save_as = 10,
    new_file = 11,
    grid_layout = 12,
    about = 13,
    check_for_updates = 14,
    report_bug = 15,
    save_all = 16,
};

pub const TitleBarButton = enum { minimize, maximize, close };

pub fn resetTitleBarHints() void {}

pub fn setTitleBarStrip(_: f32, _: i32) void {}

pub fn pushTitleBarInteractiveRect(_: dvui.Rect.Physical) void {}

pub fn setTitleBarCaptionButtonRect(_: TitleBarButton, _: dvui.Rect.Physical) void {}

pub fn getHoveredTitleBarButton() ?TitleBarButton {
    return null;
}

pub fn performWindowButton(_: *dvui.Window, _: TitleBarButton) void {}

pub fn isMaximized(_: *dvui.Window) bool {
    return true;
}

pub fn setWindowStyle(_: *dvui.Window) void {}

pub fn setTitlebarColor(_: *dvui.Window, _: dvui.Color) void {}

pub fn setSdlAppMetadata(_: [*:0]const u8, _: [*:0]const u8, _: [*:0]const u8) void {}

pub fn setupMacOSMenuBar() void {}

pub fn pollPendingNativeMenuAction() ?NativeMenuAction {
    return null;
}

pub fn showSimpleMessage(_: [:0]const u8, _: [:0]const u8) void {}

pub fn showSaveFileDialog(
    cb: *const fn (?[][:0]const u8) void,
    filters: []const DialogFileFilter,
    default_filename: []const u8,
    default_folder: ?[]const u8,
) void {
    if (comptime builtin.target.cpu.arch == .wasm32) {
        WebFileIo.showSaveFileDialog(cb, filters, default_filename, default_folder);
    }
}

pub fn showOpenFileDialog(
    cb: *const fn (?[][:0]const u8) void,
    filters: []const DialogFileFilter,
    default_filename: []const u8,
    default_folder: ?[]const u8,
) void {
    if (comptime builtin.target.cpu.arch == .wasm32) {
        WebFileIo.showOpenFileDialog(cb, filters, default_filename, default_folder);
    }
}

pub fn showOpenFolderDialog(
    _: *const fn (?[][:0]const u8) void,
    _: ?[]const u8,
) void {
    if (comptime builtin.target.cpu.arch == .wasm32) {
        const Dialogs = @import("editor/dialogs/Dialogs.zig");
        Dialogs.WebFolderUnavailable.request();
    }
}

pub fn installFileOpenEventHandling(_: *dvui.Window) void {}

/// Called from `Editor.tick` on wasm to consume file-picker uploads.
pub fn pollWebFileIo(editor: *anyopaque) void {
    if (comptime builtin.target.cpu.arch == .wasm32) {
        WebFileIo.pollOpenPicker(@ptrCast(@alignCast(editor)));
    }
}
