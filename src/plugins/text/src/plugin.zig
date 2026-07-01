//! The text editor plugin: universal fallback owner for plain-text documents, rendered as
//! editable, monospace tabs. Registration + the document vtable. Registered from
//! `Editor.postInit`; document state lives in `State.docs`.
const std = @import("std");
const internal = @import("../text.zig");
const sdk = internal.sdk;
const dvui = internal.dvui;
const State = internal.State;
const Document = internal.Document;
const CodeEditor = internal.CodeEditor;
const DocHandle = sdk.DocHandle;

/// Version forwarded from `build.zig.zon` via the build-injected options module — bump it there.
const plugin_options = @import("fizzy_plugin_options");

pub const manifest = sdk.PluginManifest{
    .id = "text",
    .name = "Text",
    .version = plugin_options.version,
};

var plugin: sdk.Plugin = .{
    .state = undefined,
    .vtable = &vtable,
    .id = "text",
    .display_name = "Text",
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

comptime {
    sdk.Plugin.assertEditorVTable(vtable);
}

pub fn register(host: *sdk.Host) !void {
    const gpa = host.allocator;

    const st = try gpa.create(State);
    errdefer gpa.destroy(st);
    st.* = .{};
    plugin.state = @ptrCast(st);

    try host.registerPlugin(&plugin);
    try host.registerFileIcon(.{ .owner = &plugin, .draw = drawFileIcon });
}

/// Stable `*Plugin` for constructing `DocHandle.owner` fields / lookups.
pub fn pluginPtr() *sdk.Plugin {
    return &plugin;
}

fn deinit(state: *anyopaque) void {
    const st: *State = @ptrCast(@alignCast(state));
    const gpa = sdk.allocator();
    st.deinit(gpa);
    gpa.destroy(st);
}

// ---- file type ownership -----------------------------------------------------

/// Fallback text editor: opens any file when no other plugin claims the extension.
/// Pixel-art wins for `.fiz`/`.pixi` (0) and flat images (10); everything else
/// opens here — including extensionless paths and renamed `.txt` → `.foo`.
fn fileTypePriority(_: *anyopaque, ext: []const u8) ?u8 {
    _ = ext;
    return sdk.Plugin.file_type_fallback_priority;
}

/// Source/text extensions this editor draws a code glyph for in the file tree. Anything else
/// (archives, unknown binaries, …) returns false so the workbench draws its generic icon.
fn isTextIconExt(ext: []const u8) bool {
    const text_exts = [_][]const u8{
        ".zig",  ".json", ".txt",  ".atlas", ".md",   ".markdown", ".c",   ".h",   ".cpp",
        ".hpp",  ".cc",   ".js",   ".ts",    ".jsx",  ".tsx",      ".html", ".htm", ".css",
        ".xml",  ".yml",  ".yaml", ".toml",  ".ini",  ".sh",       ".bash", ".zsh", ".py",
        ".rs",   ".go",   ".lua",  ".rb",    ".java", ".cs",       ".php",  ".sql", ".csv",
        ".log",  ".conf", ".cfg",
    };
    for (text_exts) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

fn drawFileIcon(_: ?*anyopaque, ext: []const u8, _: []const u8, color: dvui.Color) bool {
    if (!isTextIconExt(ext)) return false;
    dvui.icon(@src(), "CodeFileIcon", dvui.entypo.code, .{ .stroke_color = color, .fill_color = color }, .{
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(3),
        .background = false,
    });
    return true;
}

// ---- document staging buffer -------------------------------------------------

fn documentStackSize(_: *anyopaque) usize {
    return @sizeOf(Document);
}
fn documentStackAlign(_: *anyopaque) usize {
    return @alignOf(Document);
}
fn loadDocument(_: *anyopaque, path: []const u8, out_doc: *anyopaque) anyerror!void {
    try sdk.document.loadPathInto(Document, path, docBuf(out_doc));
}
fn loadDocumentFromBytes(_: *anyopaque, path: []const u8, bytes: []const u8, out_doc: *anyopaque) anyerror!void {
    try sdk.document.loadBytesInto(Document, path, bytes, docBuf(out_doc));
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
    try st.docs.put(sdk.allocator(), doc.id, doc.*);
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
    const gpa = sdk.allocator();
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
    if (try CodeEditor.draw(doc, handle.id, sdk.allocator())) {
        doc.dirty = true;
    }
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

fn docBuf(buf: *anyopaque) *Document {
    return @ptrCast(@alignCast(buf));
}
fn docFrom(handle: DocHandle) ?*Document {
    const st: *State = @ptrCast(@alignCast(plugin.state));
    return st.docById(handle.id);
}
