//! The text editor plugin: universal fallback owner for plain-text documents, rendered as
//! editable, monospace tabs. Registration + the document vtable. Registered from
//! `Editor.postInit`; document state lives in `State.docs`.
const std = @import("std");
const internal = @import("../text.zig");
const sdk = internal.sdk;
const dvui = internal.dvui;
const State = internal.State;
const Document = internal.Document;
const TextEditor = internal.TextEditor;
const Settings = internal.Settings;
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
    .createDocument = createDocument,
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
    .revealPosition = revealPosition,
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
    .saveDocumentAs = saveDocumentAs,
    .undo = undoDocument,
    .redo = redoDocument,
    .canUndo = canUndoDocument,
    .canRedo = canRedoDocument,
};

comptime {
    sdk.Plugin.assertEditorVTable(vtable);
}

pub fn register(host: *sdk.Host) !void {
    const gpa = host.allocator;

    const st = try gpa.create(State);
    errdefer gpa.destroy(st);
    st.* = .{};
    Settings.load(host, st);
    plugin.state = @ptrCast(st);

    try host.registerPlugin(&plugin);
    try Settings.registerSection(host, st);
    try host.registerFileIcon(.{ .owner = &plugin, .draw = drawFileIcon });
    try host.registerCommand(.{
        .id = sdk.Plugin.commandId("text", "copy"),
        .owner = &plugin,
        .title = "Copy",
        .run = cmdCopy,
        .isEnabled = cmdCopyEnabled,
    });
    try host.registerCommand(.{
        .id = sdk.Plugin.commandId("text", "paste"),
        .owner = &plugin,
        .title = "Paste",
        .run = cmdPaste,
    });
    try host.registerCommand(.{
        .id = sdk.Plugin.commandId("text", "format"),
        .owner = &plugin,
        .title = "Format Document",
        .run = cmdFormat,
        .isEnabled = cmdFormatEnabled,
    });

    // "Format Document" is only meaningful when a language plugin claims the active
    // document's extension (today, `zig` via zls) — inject it into the shell's existing
    // "Edit" menu (in-app + native) rather than showing a permanently-greyed generic verb.
    try host.registerMenuSection(.{
        .id = "text.menu.edit_section",
        .parent_menu_id = "shell.menu.edit",
        .owner = &plugin,
        .draw = drawEditMenuSection,
    });
    try host.registerNativeMenuItem(.{
        .id = "text.native.format",
        .owner = &plugin,
        .parent_menu_id = "shell.menu.edit",
        .title = "Format Document",
        .run = nativeFormat,
    });
}

/// Stable `*Plugin` for constructing `DocHandle.owner` fields / lookups.
pub fn pluginPtr() *sdk.Plugin {
    return &plugin;
}

/// The plugin's own runtime state — e.g. `TextEditor.zig` reads indentation settings off
/// this at draw time.
pub fn statePtr() *State {
    return @ptrCast(@alignCast(plugin.state));
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
        ".zig", ".json", ".txt",  ".atlas", ".md",   ".markdown", ".c",    ".h",   ".cpp",
        ".hpp", ".cc",   ".js",   ".ts",    ".jsx",  ".tsx",      ".html", ".htm", ".css",
        ".xml", ".yml",  ".yaml", ".toml",  ".ini",  ".sh",       ".bash", ".zsh", ".py",
        ".rs",  ".go",   ".lua",  ".rb",    ".java", ".cs",       ".php",  ".sql", ".csv",
        ".log", ".conf", ".cfg",
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
fn createDocument(_: *anyopaque, path: []const u8, _: sdk.EditorAPI.NewDocGrid, out_doc: *anyopaque) anyerror!void {
    const doc = docBuf(out_doc);
    doc.* = try Document.fromBytes(path, "");
    doc.unsaved = true;
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
    const gpa = sdk.allocator();
    const heap_doc = try gpa.create(Document);
    errdefer gpa.destroy(heap_doc);
    heap_doc.* = doc.*;
    try st.docs.put(gpa, doc.id, heap_doc);
    return heap_doc;
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
    if (st.docs.fetchSwapRemove(id)) |kv| sdk.allocator().destroy(kv.value);
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
fn revealPosition(_: *anyopaque, handle: DocHandle, line: u32, character: u32) void {
    const doc = docFrom(handle) orelse return;
    doc.pending_cursor = doc.byteOffsetForLineCharacter(line, character);
    doc.pending_scroll_line = line;
}
fn bindDocumentToPane(_: *anyopaque, _: DocHandle, _: dvui.Id, _: *anyopaque, _: bool) void {
    // Text editing needs no pane/canvas binding; the text widget manages its own state.
}
fn documentHasNativeExtension(_: *anyopaque, _: DocHandle) bool {
    return true;
}
fn documentHasRecognizedSaveExtension(_: *anyopaque, handle: DocHandle) bool {
    const doc = docFrom(handle) orelse return true;
    return !doc.unsaved;
}

// ---- rendering + lifecycle ---------------------------------------------------

fn drawDocument(_: *anyopaque, handle: DocHandle) anyerror!void {
    const doc = docFrom(handle) orelse return;
    _ = try TextEditor.draw(doc, handle.id, sdk.allocator());
}

fn closeDocument(_: *anyopaque, handle: DocHandle) void {
    (docFrom(handle) orelse return).deinit();
}
fn isDirty(_: *anyopaque, handle: DocHandle) bool {
    return (docFrom(handle) orelse return false).isDirty();
}
fn saveDocument(state: *anyopaque, handle: DocHandle) anyerror!void {
    const doc = docFrom(handle) orelse return;
    const st: *State = @ptrCast(@alignCast(state));
    if (st.format_on_save) formatDocument(doc);
    try doc.save();
}
fn documentDefaultSaveAsFilename(_: *anyopaque, handle: DocHandle, allocator: std.mem.Allocator) anyerror![]const u8 {
    const doc = docFrom(handle) orelse return error.DocumentNotFound;
    return allocator.dupe(u8, std.fs.path.basename(doc.path));
}
fn saveDocumentAs(_: *anyopaque, handle: DocHandle, path: []const u8, _: *dvui.Window) anyerror!void {
    const doc = docFrom(handle) orelse return error.DocumentNotFound;
    try doc.saveAs(path);
}

// ---- undo / redo --------------------------------------------------------------

fn undoDocument(_: *anyopaque, handle: DocHandle) anyerror!void {
    (docFrom(handle) orelse return).undo();
}
fn redoDocument(_: *anyopaque, handle: DocHandle) anyerror!void {
    (docFrom(handle) orelse return).redo();
}
fn canUndoDocument(_: *anyopaque, handle: DocHandle) bool {
    const doc = docFrom(handle) orelse return false;
    return doc.history.canUndo();
}
fn canRedoDocument(_: *anyopaque, handle: DocHandle) bool {
    const doc = docFrom(handle) orelse return false;
    return doc.history.canRedo();
}

// ---- copy / paste commands -----------------------------------------------------

fn cmdCopyEnabled(state: *anyopaque) bool {
    const doc = activeTextDoc(state) orelse return false;
    return doc.sel_start != doc.sel_end;
}
fn cmdCopy(state: *anyopaque) anyerror!void {
    const doc = activeTextDoc(state) orelse return;
    if (doc.sel_start == doc.sel_end) return;
    dvui.clipboardTextSet(doc.text.items[doc.sel_start..doc.sel_end]);
}
fn cmdPaste(state: *anyopaque) anyerror!void {
    const doc = activeTextDoc(state) orelse return;
    const clip = dvui.clipboardText();
    if (clip.len == 0) return;
    try doc.replaceRange(doc.sel_start, doc.sel_end, clip);
}

// ---- format command -------------------------------------------------------------

fn cmdFormatEnabled(state: *anyopaque) bool {
    const doc = activeTextDoc(state) orelse return false;
    return sdk.host().canFormatExt(std.fs.path.extension(doc.path));
}
fn cmdFormat(state: *anyopaque) anyerror!void {
    const doc = activeTextDoc(state) orelse return;
    formatDocument(doc);
}

/// Reformats `doc` in place via the first registered `LanguageSupport.format` provider for its
/// extension, as one undoable edit — a no-op (including "no such provider" and "provider
/// returned unchanged text") rather than an error, since both `Edit > Format Document` and
/// format-on-save call this best-effort.
fn formatDocument(doc: *Document) void {
    const ext = std.fs.path.extension(doc.path);
    if (!sdk.host().canFormatExt(ext)) return;
    const formatted = sdk.host().formatFor(ext, doc.path, doc.text.items) orelse return;
    if (std.mem.eql(u8, formatted, doc.text.items)) return;

    // `replaceRange` moves the caret to the end of the replacement (whole-document
    // replacement, so "end" is the end of the file) — restore the pre-format position
    // (clamped to the new length) instead, so formatting doesn't fling the cursor around.
    const restore_cursor = @min(doc.sel_start, formatted.len);
    doc.replaceRange(0, doc.text.items.len, formatted) catch |err| {
        dvui.log.warn("text: format edit failed: {any}", .{err});
        return;
    };
    doc.sel_start = restore_cursor;
    doc.sel_end = restore_cursor;
    doc.pending_cursor = restore_cursor;
}

/// In-app "Edit" menu section (see `Host.registerMenuSection`) — only draws while the active
/// document belongs to this plugin and a language provider can format its extension, so the
/// item disappears entirely rather than sitting there disabled.
///
/// Draws via `Host.drawMenuItem` rather than calling `dvui.menuItem()`/`dvui.separator()`
/// directly — see that function's doc comment for why a menu section contribution can't safely
/// touch dvui's menu widgets itself.
fn drawEditMenuSection(ctx: ?*anyopaque) anyerror!void {
    _ = ctx;
    if (!cmdFormatEnabled(plugin.state)) return;

    if (sdk.host().drawMenuItem("Format Document", "format")) {
        sdk.host().runCommand(sdk.Plugin.commandId("text", "format")) catch |err| {
            dvui.log.err("text: format command failed: {any}", .{err});
        };
    }
}

/// The native macOS Edit menu is a static bar rebuilt only on plugin load/unload, so this item
/// is always present — this guard is what actually keeps it inert for a non-formattable
/// document, matching the in-app menu's behavior (mirrors `pixi`'s native Transform/Grid
/// Layout items).
fn nativeFormat(_: ?*anyopaque) anyerror!void {
    if (!cmdFormatEnabled(plugin.state)) return;
    try sdk.host().runCommand(sdk.Plugin.commandId("text", "format"));
}

/// Resolves the currently-focused document, but only when it belongs to this plugin — a
/// `Command`'s `run`/`isEnabled` only receive the plugin's own opaque `state`, not a doc, so
/// they always need to ask the shell which document is active.
fn activeTextDoc(state: *anyopaque) ?*Document {
    const handle = sdk.host().activeDoc() orelse return null;
    if (handle.owner != &plugin) return null;
    const st: *State = @ptrCast(@alignCast(state));
    return st.docById(handle.id);
}

// ---- helpers -----------------------------------------------------------------

fn docBuf(buf: *anyopaque) *Document {
    return @ptrCast(@alignCast(buf));
}
fn docFrom(handle: DocHandle) ?*Document {
    const st: *State = @ptrCast(@alignCast(plugin.state));
    return st.docById(handle.id);
}
