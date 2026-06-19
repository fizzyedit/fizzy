//! The workbench plugin: file management. Registered from `Editor.postInit`.
const std = @import("std");
const dvui = @import("dvui");
const wb = @import("../workbench.zig");
const sdk = wb.sdk;
const Globals = @import("Globals.zig");
const files = @import("files.zig");

/// Stable contribution ids (plugin-namespaced) referenced across modules.
pub const view_files = "workbench.files";
pub const center_workspaces = "workbench.workspaces";

var plugin: sdk.Plugin = .{
    .state = undefined,
    .vtable = &vtable,
    .id = "workbench",
    .display_name = "Workbench",
};

const vtable: sdk.Plugin.VTable = .{
    .contributeKeybinds = contributeKeybinds,
};

pub fn register(host: *sdk.Host) !void {
    try host.registerPlugin(&plugin);
    try host.registerSidebarView(.{
        .id = view_files,
        .owner = &plugin,
        .icon = dvui.entypo.folder,
        .title = "Files",
        .draw = drawFiles,
    });
    // The workbench owns the center "main window": the tabs/splits layout + canvas.
    try host.registerCenterProvider(.{
        .id = center_workspaces,
        .owner = &plugin,
        .draw = drawCenter,
    });
}

fn drawFiles(_: ?*anyopaque) anyerror!void {
    try files.draw();
}

fn drawCenter(_: ?*anyopaque) anyerror!dvui.App.Result {
    return Globals.host.drawWorkspaces(0);
}

/// File-management keybinds (open / save). The shell registers its own
/// global/region binds in `Keybinds.register`; this fills in the file half.
/// Platform: see `Keybinds.register` for why `fizzy.platform.isMacOS()` is used.
fn contributeKeybinds(_: *anyopaque, win: *dvui.Window) anyerror!void {
    if (wb.platform.isMacOS()) {
        try win.keybinds.putNoClobber(win.gpa, "open_folder", .{ .key = .f, .command = true });
        try win.keybinds.putNoClobber(win.gpa, "open_files", .{ .key = .o, .command = true });
        try win.keybinds.putNoClobber(win.gpa, "save", .{ .command = true, .key = .s });
        try win.keybinds.putNoClobber(win.gpa, "save_as", .{ .command = true, .shift = true, .key = .s });
        try win.keybinds.putNoClobber(win.gpa, "save_all", .{ .command = true, .alt = true, .key = .s });
    } else {
        try win.keybinds.putNoClobber(win.gpa, "open_folder", .{ .key = .f, .control = true });
        try win.keybinds.putNoClobber(win.gpa, "open_files", .{ .key = .o, .control = true });
        try win.keybinds.putNoClobber(win.gpa, "save", .{ .control = true, .key = .s });
        try win.keybinds.putNoClobber(win.gpa, "save_as", .{ .control = true, .shift = true, .key = .s });
        try win.keybinds.putNoClobber(win.gpa, "save_all", .{ .control = true, .alt = true, .key = .s });
    }
}
