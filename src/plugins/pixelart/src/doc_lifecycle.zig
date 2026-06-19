//! Document create/load buffer contract + shell frame hooks without typing
//! `Internal.File` at the SDK boundary.
const std = @import("std");
const dvui = @import("dvui");
const pixelart = @import("../pixelart.zig");
const Globals = pixelart.Globals;
const State = pixelart.State;
const Internal = pixelart.internal;
const DocHandle = pixelart.sdk.DocHandle;
const NewDocGrid = pixelart.sdk.EditorAPI.NewDocGrid;

fn docFile(st: *State, doc: DocHandle) ?*Internal.File {
    return st.docs.fileById(doc.id);
}

fn activeFile(st: *State) ?*Internal.File {
    const doc = st.host.activeDoc() orelse return null;
    return docFile(st, doc);
}

pub fn documentStackSize(_: *State) usize {
    return @sizeOf(Internal.File);
}

pub fn documentStackAlign(_: *State) usize {
    return @alignOf(Internal.File);
}

pub fn documentIdFromBuffer(_: *State, doc: *anyopaque) u64 {
    const file: *Internal.File = @ptrCast(@alignCast(doc));
    return file.id;
}

pub fn deinitDocumentBuffer(_: *State, doc: *anyopaque) void {
    const file: *Internal.File = @ptrCast(@alignCast(doc));
    file.deinit();
}

pub fn setDocumentGroupingOnBuffer(_: *State, doc: *anyopaque, grouping: u64) void {
    const file: *Internal.File = @ptrCast(@alignCast(doc));
    file.editor.grouping = grouping;
}

pub fn createDocument(_: *State, path: []const u8, grid: NewDocGrid, out_doc: *anyopaque) !void {
    const file: *Internal.File = @ptrCast(@alignCast(out_doc));
    file.* = try Internal.File.init(path, .{
        .columns = grid.columns,
        .rows = grid.rows,
        .column_width = grid.column_width,
        .row_height = grid.row_height,
    });
}

pub fn documentDefaultSaveAsFilename(st: *State, doc: DocHandle, allocator: std.mem.Allocator) ![]const u8 {
    const file = docFile(st, doc) orelse return error.DocumentNotFound;
    return Internal.File.defaultSaveAsFilename(allocator, file.path);
}

pub fn saveDocumentAs(st: *State, doc: DocHandle, path: []const u8, window: *dvui.Window) !void {
    const file = docFile(st, doc) orelse return error.DocumentNotFound;
    const ext = std.fs.path.extension(path);
    if (Internal.File.isFizzyExtension(ext)) {
        try file.saveAsFizzy(path, window);
    } else if (std.mem.eql(u8, ext, ".png") or std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg")) {
        try file.saveAsFlattened(path, window);
    } else {
        return error.UnsupportedSaveExtension;
    }
}

pub fn resetDocumentSaveUIState(st: *State, doc: DocHandle) void {
    const file = docFile(st, doc) orelse return;
    file.resetSaveUIState();
}

pub fn tickOpenDocuments(st: *State) bool {
    var needs_save_status_anim_tick = false;
    for (st.docs.files.values()) |*file| {
        file.tickSaveDoneFlash();
        if (file.showsSaveStatusIndicator()) needs_save_status_anim_tick = true;
    }
    return needs_save_status_anim_tick;
}

pub fn resetDocumentPeekLayers(st: *State) void {
    for (st.docs.files.values()) |*file| {
        if (file.editor.isolate_layer) {
            file.peek_layer_index = file.selected_layer_index;
        } else {
            file.peek_layer_index = null;
        }
    }
}

pub fn tickActiveDocumentPlayback(st: *State, timer_host_id: dvui.Id) void {
    const file = activeFile(st) orelse return;
    if (!file.editor.playing) return;
    if (file.selected_animation_index) |index| {
        const animation = file.animations.get(index);
        if (animation.frames.len == 0) return;
        if (dvui.timerDoneOrNone(timer_host_id)) {
            if (file.selected_animation_frame_index >= animation.frames.len - 1) {
                file.selected_animation_frame_index = 0;
            } else {
                file.selected_animation_frame_index += 1;
            }
            const millis_per_frame = animation.frames[file.selected_animation_frame_index].ms;
            dvui.timer(timer_host_id, @intCast(millis_per_frame * 1000));
        }
    }
}

pub fn warmupActiveDocumentComposites(st: *State) void {
    const file = activeFile(st) orelse return;
    const w = file.width();
    const h = file.height();
    if (w == 0 or h == 0) return;
    const area = @as(u64, w) * @as(u64, h);
    if (area < 512 * 512) return;
    pixelart.render.warmupDrawingComposites(file) catch |err| {
        dvui.log.err("Composite warmup failed: {any}", .{err});
    };
}

pub fn isAnyDocumentActivelyDrawing(st: *State) bool {
    for (st.docs.files.values()) |*file| {
        if (file.editor.active_drawing) return true;
    }
    return false;
}

pub fn acceptEdit(st: *State) void {
    const file = activeFile(st) orelse return;
    if (file.editor.transform) |*t| t.accept();
}

pub fn cancelEdit(st: *State) void {
    const file = activeFile(st) orelse return;
    if (file.editor.transform) |*t| t.cancel();
    if (file.editor.selected_sprites.count() > 0) file.clearSelectedSprites();
    if (file.selected_animation_index != null) file.selected_animation_index = null;
}

pub fn deleteSelection(st: *State) void {
    const file = activeFile(st) orelse return;
    file.deleteSelectedContents();
}

pub fn initPlugin(_: *State) !void {
    try Internal.File.initSaveQueue();
}

pub fn deinitPlugin(_: *State) void {
    Internal.File.deinitSaveQueue();
}
