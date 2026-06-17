//! The pixel-art editor plugin. Phase 2 thin shim — the pixel-art stack still
//! lives inline under `src/editor/` (Phase 3 relocates it whole behind this
//! plugin). For now its contributions point at the existing draw entry points
//! through the `fizzy.*` globals. Registered from `Editor.postInit`.
const std = @import("std");
const fizzy = @import("../fizzy.zig");
const dvui = @import("dvui");
const sdk = fizzy.sdk;

const DocHandle = sdk.DocHandle;
const Internal = fizzy.Internal;

/// Stable contribution ids (plugin-namespaced) referenced across modules.
pub const view_tools = "pixelart.tools";
pub const view_sprites = "pixelart.sprites";
pub const view_project = "pixelart.project";
pub const bottom_sprites = "pixelart.sprites_panel";

var plugin: sdk.Plugin = .{
    .state = undefined,
    .vtable = &vtable,
    .id = "pixelart",
    .display_name = "Pixel Art",
};

const vtable: sdk.Plugin.VTable = .{
    .fileTypePriority = fileTypePriority,
    .contributeKeybinds = contributeKeybinds,
    .isDirty = isDirty,
    .undo = undo,
    .redo = redo,
};

/// A `DocHandle` whose `ptr` is one of this plugin's `*Internal.File`s. The shell
/// gets the owning plugin from the file-type registry and round-trips the document
/// back through these hooks, so it never needs to know the concrete pixel-art type.
fn docFile(doc: DocHandle) *Internal.File {
    return @ptrCast(@alignCast(doc.ptr));
}

/// Priority for opening `ext` (lower wins). Pixel art owns its native `.fiz`/`.pixi`
/// and flat-image `.png`/`.jpg`/`.jpeg`; native formats win over flat images when
/// some future plugin also claims an image type.
fn fileTypePriority(_: *anyopaque, ext: []const u8) ?u8 {
    if (Internal.File.isFizzyExtension(ext)) return 0;
    if (Internal.File.isFlatImageExtension(ext)) return 10;
    return null;
}

fn isDirty(_: *anyopaque, doc: DocHandle) bool {
    return docFile(doc).dirty();
}

fn undo(_: *anyopaque, doc: DocHandle) anyerror!void {
    const file = docFile(doc);
    try file.history.undoRedo(file, .undo);
}

fn redo(_: *anyopaque, doc: DocHandle) anyerror!void {
    const file = docFile(doc);
    try file.history.undoRedo(file, .redo);
}

pub fn register(host: *sdk.Host) !void {
    try host.registerPlugin(&plugin);
    try host.registerSidebarView(.{
        .id = view_tools,
        .owner = &plugin,
        .icon = dvui.entypo.pencil,
        .title = "Tools",
        .draw = drawTools,
    });
    try host.registerSidebarView(.{
        .id = view_sprites,
        .owner = &plugin,
        .icon = dvui.entypo.grid,
        .title = "Sprites",
        .draw = drawSprites,
    });
    try host.registerSidebarView(.{
        .id = view_project,
        .owner = &plugin,
        .icon = dvui.entypo.box,
        .title = "Project",
        .draw = drawProject,
    });
    try host.registerBottomView(.{
        .id = bottom_sprites,
        .owner = &plugin,
        .title = "Sprites",
        .draw = drawSpritesPanel,
    });
}

fn drawTools(_: ?*anyopaque) anyerror!void {
    try fizzy.editor.explorer.tools.draw();
}
fn drawSprites(_: ?*anyopaque) anyerror!void {
    try fizzy.editor.explorer.sprites.draw();
}
fn drawProject(_: ?*anyopaque) anyerror!void {
    try fizzy.Editor.Explorer.project.draw();
}
fn drawSpritesPanel(_: ?*anyopaque) anyerror!void {
    try fizzy.editor.panel.sprites.draw();
}

/// Pixel-art editing + tool keybinds. The shell registers its own global/region
/// binds in `Keybinds.register`; this fills in the pixel-art half. Platform: see
/// `Keybinds.register` for why `fizzy.platform.isMacOS()` (not `builtin`) is used.
fn contributeKeybinds(_: *anyopaque, win: *dvui.Window) anyerror!void {
    if (fizzy.platform.isMacOS()) {
        try win.keybinds.putNoClobber(win.gpa, "new_file", .{ .key = .n, .command = true });
        try win.keybinds.putNoClobber(win.gpa, "undo", .{ .key = .z, .command = true, .shift = false });
        try win.keybinds.putNoClobber(win.gpa, "redo", .{ .key = .z, .command = true, .shift = true });
        try win.keybinds.putNoClobber(win.gpa, "zoom", .{ .command = true });
        try win.keybinds.putNoClobber(win.gpa, "sample", .{ .control = true });
        try win.keybinds.putNoClobber(win.gpa, "transform", .{ .command = true, .key = .t });
        try win.keybinds.putNoClobber(win.gpa, "grid_layout", .{ .command = true, .key = .g });
        try win.keybinds.putNoClobber(win.gpa, "export", .{ .command = true, .key = .p });
        try win.keybinds.putNoClobber(win.gpa, "delete_selection_contents", .{ .key = .backspace });
    } else {
        try win.keybinds.putNoClobber(win.gpa, "new_file", .{ .key = .n, .control = true });
        try win.keybinds.putNoClobber(win.gpa, "undo", .{ .key = .z, .control = true, .shift = false });
        try win.keybinds.putNoClobber(win.gpa, "redo", .{ .key = .z, .control = true, .shift = true });
        try win.keybinds.putNoClobber(win.gpa, "zoom", .{ .control = true });
        try win.keybinds.putNoClobber(win.gpa, "sample", .{ .alt = true });
        try win.keybinds.putNoClobber(win.gpa, "transform", .{ .control = true, .key = .t });
        try win.keybinds.putNoClobber(win.gpa, "grid_layout", .{ .control = true, .key = .g });
        try win.keybinds.putNoClobber(win.gpa, "export", .{ .control = true, .key = .p });
        try win.keybinds.putNoClobber(win.gpa, "delete_selection_contents", .{ .key = .delete });
    }

    try win.keybinds.putNoClobber(win.gpa, "increase_stroke_size", .{ .key = .right_bracket });
    try win.keybinds.putNoClobber(win.gpa, "decrease_stroke_size", .{ .key = .left_bracket });
    try win.keybinds.putNoClobber(win.gpa, "quick_tools", .{ .key = .space });

    try win.keybinds.putNoClobber(win.gpa, "pencil", .{ .key = .d, .command = false, .control = false, .alt = false, .shift = false });
    try win.keybinds.putNoClobber(win.gpa, "eraser", .{ .key = .e, .command = false, .control = false, .alt = false, .shift = false });
    try win.keybinds.putNoClobber(win.gpa, "bucket", .{ .key = .b, .command = false, .control = false, .alt = false, .shift = false });
    try win.keybinds.putNoClobber(win.gpa, "selection", .{ .key = .s, .command = false, .control = false, .alt = false, .shift = false });
    try win.keybinds.putNoClobber(win.gpa, "pointer", .{ .key = .escape });
}
