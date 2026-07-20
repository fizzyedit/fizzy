//! The workbench plugin: file management. Registration + vtable, and the module root — the
//! shell resolves `@import("workbench")` to this file when compiled into the app (static embed);
//! files under `src/` use named imports (`sdk`/`core`/`dvui`) and reach this file's siblings via
//! relative imports.
//!
//! Re-exports the handful of types/values the shell still reaches through `@import("workbench")`
//! directly (`Workspace`/`Workbench`/`FileLoadJob`/`runtime`/`files`/`has_file_tree`) — see
//! `docs/PLUGIN_MANIFEST_PLAN.md`'s "static module root" decision: the hub dies as an
//! intra-plugin import surface, but the shell's `@import("workbench")` needs *something* to
//! resolve `Workspace` etc. against, so those re-exports move onto the module root instead.
const std = @import("std");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const core = @import("core");

pub const runtime = @import("src/runtime.zig");
pub const files = @import("src/files.zig");
pub const Workspace = @import("src/Workspace.zig");
pub const Workbench = @import("src/Workbench.zig");
pub const FileLoadJob = @import("src/FileLoadJob.zig");

const workbench_opts = @import("workbench_opts");

/// Stable contribution ids (plugin-namespaced) referenced across modules.
pub const view_files = "workbench.files";
pub const center_workspaces = "workbench.workspaces";

/// Injected at build time from `plugin.zig.zon` (see `static/integration.zig` /
/// `src/plugins/shared/build/helpers.zig`'s `pluginOptions`) — one source of truth for
/// identity, not duplicated as string literals here.
pub const plugin_options = @import("fizzy_plugin_options");

/// This plugin's stable id — the single source of truth other modules (e.g. the shell's
/// `Editor.isBundledPluginId`) read instead of retyping the string.
pub const plugin_id = plugin_options.id;

var plugin: sdk.Plugin = .{
    .state = undefined,
    .vtable = &vtable,
    .id = plugin_id,
    .display_name = plugin_options.name,
};

const vtable: sdk.Plugin.VTable = .{
    .contributeKeybinds = contributeKeybinds,
};

/// When false at compile time (`-Dworkbench-file-tree=false`), the Files sidebar is not registered.
pub const has_file_tree = workbench_opts.file_tree;

pub fn register(host: *sdk.Host) !void {
    plugin.state = @ptrCast(runtime.workbench());
    try host.registerPlugin(&plugin);
    if (comptime has_file_tree) {
        try host.registerSidebarView(.{
            .id = view_files,
            .owner = &plugin,
            .icon = dvui.entypo.folder,
            .title = "Files",
            .draw = drawFiles,
        });
    }
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
    return runtime.host().drawWorkspaces(0);
}

/// File-management keybinds (open / save). The shell registers its own
/// global/region binds in `Keybinds.register`; this fills in the file half.
fn contributeKeybinds(_: *anyopaque, win: *dvui.Window) anyerror!void {
    if (core.platform.isMacOS()) {
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
