//! The code editor plugin: owns text documents (`.zig`/`.json`/…) and renders them as
//! editable, monospace tabs. Registration + the document vtable. Registered from
//! `Editor.postInit`; document state lives in `State.docs`.
const std = @import("std");
const code = @import("../code.zig");
const sdk = code.sdk;
const dvui = code.dvui;
const Globals = code.Globals;
const State = code.State;
const Document = code.Document;
const DocHandle = sdk.DocHandle;

var plugin: sdk.Plugin = .{
    .state = undefined,
    .vtable = &vtable,
    .id = "code",
    .display_name = "Code",
};

const vtable: sdk.Plugin.VTable = .{
    .deinit = deinit,
    .fileTypePriority = fileTypePriority,
    // document staging buffer (shell allocates, plugin fills, then registers)
    .documentStackSize = documentStackSize,
    .documentStackAlign = documentStackAlign,
    .loadDocument = loadDocument,
    .loadDocumentFromBytes = loadDocumentFromBytes,
    .setDocumentGroupingOnBuffer = setDocumentGroupingOnBuffer,
    .documentIdFromBuffer = documentIdFromBuffer,
    .deinitDocumentBuffer = deinitDocumentBuffer,
    // open-document registry
    .registerOpenDocument = registerOpenDocument,
    .documentPtr = documentPtr,
    .documentByPath = documentByPath,
    .unregisterDocument = unregisterDocument,
    // document metadata (shell/workbench routing)
    .documentGrouping = documentGrouping,
    .setDocumentGrouping = setDocumentGrouping,
    .documentPath = documentPath,
    .setDocumentPath = setDocumentPath,
    .bindDocumentToPane = bindDocumentToPane,
    .documentHasNativeExtension = documentHasNativeExtension,
    .documentHasRecognizedSaveExtension = documentHasRecognizedSaveExtension,
    // rendering + lifecycle
    .drawDocument = drawDocument,
    .closeDocument = closeDocument,
    .isDirty = isDirty,
    .saveDocument = saveDocument,
    // text saves are small and synchronous, so the async path just saves in place
    .saveDocumentAsync = saveDocument,
    .documentDefaultSaveAsFilename = documentDefaultSaveAsFilename,
};

pub fn register(host: *sdk.Host) !void {
    // Adopt the app-owned state as this plugin's vtable `state` (mirrors pixelart).
    plugin.state = @ptrCast(Globals.state);
    try host.registerPlugin(&plugin);
}

/// Stable `*Plugin` for constructing `DocHandle.owner` fields / lookups.
pub fn pluginPtr() *sdk.Plugin {
    return &plugin;
}

fn deinit(state: *anyopaque) void {
    const st: *State = @ptrCast(@alignCast(state));
    st.deinit(Globals.allocator());
}

// ---- file type ownership -----------------------------------------------------

/// Text/source extensions this plugin opens. Lower priority value wins; pixel-art
/// owns image/`.fiz` extensions, so there is no overlap.
const text_extensions = [_][]const u8{
    ".zig",  ".zon", ".json", ".txt", ".md",  ".toml", ".yaml", ".yml",
    ".glsl", ".c",   ".h",    ".cpp", ".hpp", ".js",   ".ts",   ".css",
    ".html", ".xml", ".sh",   ".py",  ".lua",
};

fn fileTypePriority(_: *anyopaque, ext: []const u8) ?u8 {
    for (text_extensions) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return 50;
    }
    return null;
}

// ---- document staging buffer -------------------------------------------------

fn documentStackSize(_: *anyopaque) usize {
    return @sizeOf(Document);
}
fn documentStackAlign(_: *anyopaque) usize {
    return @alignOf(Document);
}
fn loadDocument(_: *anyopaque, path: []const u8, out_doc: *anyopaque) anyerror!void {
    docBuf(out_doc).* = try Document.fromPath(path);
}
fn loadDocumentFromBytes(_: *anyopaque, path: []const u8, bytes: []const u8, out_doc: *anyopaque) anyerror!void {
    docBuf(out_doc).* = try Document.fromBytes(path, bytes);
}
fn setDocumentGroupingOnBuffer(_: *anyopaque, doc: *anyopaque, grouping: u64) void {
    docBuf(doc).grouping = grouping;
}
fn documentIdFromBuffer(_: *anyopaque, doc: *anyopaque) u64 {
    return docBuf(doc).id;
}
fn deinitDocumentBuffer(_: *anyopaque, doc: *anyopaque) void {
    docBuf(doc).deinit();
}

// ---- open-document registry --------------------------------------------------

fn registerOpenDocument(state: *anyopaque, file: *anyopaque) anyerror!*anyopaque {
    const st: *State = @ptrCast(@alignCast(state));
    const doc = docBuf(file);
    try st.docs.put(Globals.allocator(), doc.id, doc.*);
    return st.docs.getPtr(doc.id).?;
}
fn documentPtr(state: *anyopaque, id: u64) ?*anyopaque {
    const st: *State = @ptrCast(@alignCast(state));
    return st.docById(id);
}
fn documentByPath(state: *anyopaque, path: []const u8) ?*anyopaque {
    const st: *State = @ptrCast(@alignCast(state));
    return st.docByPath(path);
}
fn unregisterDocument(state: *anyopaque, id: u64) void {
    const st: *State = @ptrCast(@alignCast(state));
    _ = st.docs.swapRemove(id);
}

// ---- document metadata -------------------------------------------------------

fn documentGrouping(_: *anyopaque, handle: DocHandle) u64 {
    return (docFrom(handle) orelse return 0).grouping;
}
fn setDocumentGrouping(_: *anyopaque, handle: DocHandle, grouping: u64) void {
    (docFrom(handle) orelse return).grouping = grouping;
}
fn documentPath(_: *anyopaque, handle: DocHandle) []const u8 {
    return (docFrom(handle) orelse return "").path;
}
fn setDocumentPath(_: *anyopaque, handle: DocHandle, path: []const u8) anyerror!void {
    const doc = docFrom(handle) orelse return error.DocumentNotFound;
    const gpa = Globals.allocator();
    const new_path = try gpa.dupe(u8, path);
    gpa.free(doc.path);
    doc.path = new_path;
}
fn bindDocumentToPane(_: *anyopaque, _: DocHandle, _: dvui.Id, _: *anyopaque, _: bool) void {
    // Text editing needs no pane/canvas binding; the text widget manages its own state.
}
fn documentHasNativeExtension(_: *anyopaque, _: DocHandle) bool {
    return true;
}
fn documentHasRecognizedSaveExtension(_: *anyopaque, _: DocHandle) bool {
    return true; // a text document always saves in place over its own file
}

// ---- rendering + lifecycle ---------------------------------------------------

fn drawDocument(_: *anyopaque, handle: DocHandle) anyerror!void {
    const doc = docFrom(handle) orelse return;
    const gpa = Globals.allocator();

    var te = dvui.textEntry(@src(), .{
        .multiline = true,
        .break_lines = false,
        .text = .{ .array_list = .{ .backing = &doc.text, .allocator = gpa, .limit = max_text_bytes } },
    }, .{
        .expand = .both,
        .font = dvui.Font.theme(.mono),
        // Key the widget by document id so its cursor/scroll follow the document across
        // tab switches within a pane, not the pane slot.
        .id_extra = @intCast(handle.id),
        .background = false,
    });
    defer te.deinit();

    if (te.text_changed) doc.dirty = true;
}

fn closeDocument(_: *anyopaque, handle: DocHandle) void {
    (docFrom(handle) orelse return).deinit();
}
fn isDirty(_: *anyopaque, handle: DocHandle) bool {
    return (docFrom(handle) orelse return false).dirty;
}
fn saveDocument(_: *anyopaque, handle: DocHandle) anyerror!void {
    try (docFrom(handle) orelse return).save();
}
fn documentDefaultSaveAsFilename(_: *anyopaque, handle: DocHandle, allocator: std.mem.Allocator) anyerror![]const u8 {
    const doc = docFrom(handle) orelse return error.DocumentNotFound;
    return allocator.dupe(u8, std.fs.path.basename(doc.path));
}

// ---- helpers -----------------------------------------------------------------

const max_text_bytes: usize = 64 * 1024 * 1024;

fn docBuf(buf: *anyopaque) *Document {
    return @ptrCast(@alignCast(buf));
}
fn docFrom(handle: DocHandle) ?*Document {
    return Globals.state.docById(handle.id);
}
