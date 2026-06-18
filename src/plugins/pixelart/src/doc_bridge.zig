//! Document metadata + pane-binding hooks for shell/workbench routing without
//! typing `Internal.File` at the SDK boundary.
const std = @import("std");
const dvui = @import("dvui");
const pixelart = @import("../pixelart.zig");
const Globals = pixelart.Globals;
const State = pixelart.State;
const Internal = pixelart.internal;
const DocHandle = pixelart.sdk.DocHandle;

fn docFile(st: *State, doc: DocHandle) ?*Internal.File {
    return st.docs.fileById(doc.id);
}

pub fn bindDocumentToPane(
    st: *State,
    doc: DocHandle,
    canvas_id: dvui.Id,
    workspace_handle: *anyopaque,
    center: bool,
) void {
    const file = docFile(st, doc) orelse return;
    file.editor.canvas.id = canvas_id;
    file.editor.workspace_handle = workspace_handle;
    file.editor.center = center;
}

pub fn documentGrouping(st: *State, doc: DocHandle) u64 {
    const file = docFile(st, doc) orelse return 0;
    return file.editor.grouping;
}

pub fn setDocumentGrouping(st: *State, doc: DocHandle, grouping: u64) void {
    const file = docFile(st, doc) orelse return;
    file.editor.grouping = grouping;
}

pub fn documentPath(st: *State, doc: DocHandle) []const u8 {
    const file = docFile(st, doc) orelse return "";
    return file.path;
}

pub fn setDocumentPath(st: *State, doc: DocHandle, path: []const u8) !void {
    const file = docFile(st, doc) orelse return error.DocumentNotFound;
    const gpa = Globals.allocator();
    gpa.free(file.path);
    file.path = try gpa.dupe(u8, path);
}

pub fn documentHasNativeExtension(st: *State, doc: DocHandle) bool {
    const file = docFile(st, doc) orelse return false;
    return Internal.File.isFizzyExtension(std.fs.path.extension(file.path));
}

pub fn showsSaveStatusIndicator(st: *State, doc: DocHandle) bool {
    const file = docFile(st, doc) orelse return false;
    return file.showsSaveStatusIndicator();
}

pub fn isDocumentSaving(st: *State, doc: DocHandle) bool {
    const file = docFile(st, doc) orelse return false;
    return file.isSaving();
}

pub fn shouldConfirmFlatRasterSave(st: *State, doc: DocHandle) bool {
    const file = docFile(st, doc) orelse return false;
    return file.shouldConfirmFlatRasterSave();
}

pub fn saveDocumentAsync(st: *State, doc: DocHandle) !void {
    const file = docFile(st, doc) orelse return error.DocumentNotFound;
    try file.saveAsync();
}

pub fn timeSinceSaveCompleteNs(st: *State, doc: DocHandle) ?i128 {
    const file = docFile(st, doc) orelse return null;
    return file.timeSinceSaveComplete();
}
