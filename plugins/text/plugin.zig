//! The text editor plugin: universal fallback owner for plain-text documents, rendered as
//! editable, monospace tabs. Registration + the document vtable. Registered from
//! `Editor.postInit`; document state lives in `State.docs`.
const std = @import("std");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const icons = @import("icons");
const State = @import("src/State.zig");
const Document = @import("src/Document.zig");
const TextEditor = @import("src/TextEditor.zig");
const DocHandle = sdk.DocHandle;

/// Injected at build time from `plugin.zig.zon` (see `static/integration.zig` /
/// `plugins/shared/build/helpers.zig`'s `pluginOptions`) — one source of truth for
/// identity, not duplicated as string literals here.
pub const plugin_options = @import("fizzy_plugin_options");

/// This plugin's stable id — the single source of truth other modules (e.g. fizzy's
/// `Editor.isBundledPluginId`) read instead of retyping the string.
pub const plugin_id = plugin_options.id;

/// The editing widget, re-exported so `tests/integration.zig` can drive it against dvui's
/// headless testing backend (a file belongs to exactly one module, so the tests reach it
/// through this plugin's module rather than rooting their own at the widget). Nothing in the
/// app imports it this way — `TextEditor.zig` uses the relative path directly.
pub const TextEntryWidget = @import("src/widgets/TextEntryWidget.zig");

var plugin: sdk.Plugin = .{
    .state = undefined,
    .vtable = &vtable,
    .id = plugin_id,
    .display_name = plugin_options.name,
};

const vtable: sdk.Plugin.VTable = .{
    .deinit = deinit,
    // document staging buffer (fizzy allocates, plugin fills, then registers)
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
    // document metadata (fizzy/workbench routing)
    .documentGrouping = documentGrouping,
    .setDocumentGrouping = setDocumentGrouping,
    .documentPath = documentPath,
    .setDocumentPath = setDocumentPath,
    .revealPosition = revealPosition,
    .bindDocumentToPane = bindDocumentToPane,
    .documentHasNativeExtension = documentHasNativeExtension,
    .documentHasRecognizedSaveExtension = documentHasRecognizedSaveExtension,
    // rendering + lifecycle
    .tickOpenDocuments = tickOpenDocuments,
    .drawDocument = drawDocument,
    .documentContextMenu = documentContextMenu,
    .infobarEntries = infobarEntries,
    .closeDocument = closeDocument,
    .reloadDocument = reloadDocument,
    .captureDocumentState = captureDocumentState,
    .restoreDocumentState = restoreDocumentState,
    .documentFingerprint = documentFingerprint,
    .isDirty = isDirty,
    .saveDocument = saveDocument,
    .documentBytes = documentBytes,
    .documentWritten = documentWritten,
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
    State.Schema.load(host, "text", &st.settings);
    plugin.state = @ptrCast(st);

    try host.registerPlugin(&plugin);
    // Loaded-only settings UI (see `plans/PLUGIN_MANIFEST_PLAN.md`): the schema lives in the
    // Host's registry only while this plugin stays registered. Registered directly against
    // `&st.settings`, so fizzy's pane edits land straight on the live struct — no
    // `settingsChanged` sync hook needed.
    try st.registerSettings(host, &plugin);
    // The fallback editor: opens anything no other plugin owns — including extensionless
    // paths and renamed `.txt` → `.foo`. Deliberately does *not* implement `fileTypes`; its
    // claim set is unbounded, so it can never appear as a specialized claimant in the File
    // Types table, only as the implicit "Text (fallback)" option.
    host.registerFallbackEditor(&plugin);
    try host.registerFileKind(.{ .owner = &plugin, .kind = fileKind });
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
        .isEnabled = cmdPasteEnabled,
    });
    try host.registerCommand(.{
        .id = sdk.Plugin.commandId("text", "format"),
        .owner = &plugin,
        .title = "Format Document",
        .run = cmdFormat,
        .isEnabled = cmdFormatEnabled,
        .icon = icons.tvg.lucide.@"align-left",
    });
    try host.registerCommand(.{
        .id = sdk.Plugin.commandId("text", "goToLine"),
        .owner = &plugin,
        .title = "Go to Line…",
        .params = GoToLine.params,
        .runWith = GoToLine.bind(cmdGoToLine),
        .isEnabled = cmdGoToLineEnabled,
        .icon = icons.tvg.lucide.@"arrow-down-to-line",
    });

    // What a snippet keybind, a tape or an agent edits through: each one undoable edit to the
    // active document, scrolled into view, as typing or a paste would be.
    try host.registerCommand(.{
        .id = sdk.Plugin.commandId("text", "insert"),
        .owner = &plugin,
        .title = "Insert Text…",
        .params = Insert.params,
        .runWith = Insert.bind(cmdInsert),
        .isEnabled = cmdGoToLineEnabled,
        .icon = icons.tvg.lucide.@"text-cursor-input",
    });
    try host.registerCommand(.{
        .id = sdk.Plugin.commandId("text", "replace"),
        .owner = &plugin,
        .title = "Replace Text…",
        .params = Replace.params,
        .runWith = Replace.bind(cmdReplace),
        .isEnabled = cmdGoToLineEnabled,
        .icon = icons.tvg.lucide.replace,
    });
    try host.registerCommand(.{
        .id = sdk.Plugin.commandId("text", "read"),
        .owner = &plugin,
        .title = "Read Text",
        .params = Read.params,
        .runWith = Read.bind(cmdRead),
        .isEnabled = cmdGoToLineEnabled,
        .icon = icons.tvg.lucide.@"file-text",
    });

    // "Format Document" is only meaningful when a language plugin claims the active
    // document's extension (today, `zig` via zls) — inject it into fizzy's existing
    // "Edit" menu (in-app + native) rather than showing a permanently-greyed generic verb.
    // The editor's own right-click menu (`documentContextMenu` below names it). Filled through
    // the same contribution point anyone else would use, so a language plugin can add "Go to
    // Definition" beside Copy without the text plugin knowing it exists.
    try host.registerMenuSection(.{
        .id = "text.menu.document.clipboard",
        .parent_menu_id = document_menu_id,
        .owner = &plugin,
        .draw = drawDocumentMenu,
    });

    try host.registerMenuSection(.{
        .id = "text.menu.edit_section",
        .parent_menu_id = "fizzy.menu.edit",
        .owner = &plugin,
        .draw = drawEditMenuSection,
    });
    try host.registerNativeMenuItem(.{
        .id = "text.native.format",
        .owner = &plugin,
        .parent_menu_id = "fizzy.menu.edit",
        .title = "Format Document",
        // Naming the command is what gets this item's chord onto the macOS menu — and keeps it
        // there across a rebind. `run` is still the click path.
        .command = sdk.Plugin.commandId("text", "format"),
        .sf_symbol = "text.alignleft",
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

/// What kind of file this is — not what it looks like. See `image/plugin.zig`'s note.
fn fileKind(_: ?*anyopaque, ext: []const u8) ?[]const u8 {
    return if (isTextIconExt(ext)) "source" else null;
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
    // Kick language-server warmup (spawn + didOpen) before the first hover/completion so
    // cold-start latency isn't paid on first use — see `LanguageSupport.VTable.documentOpened`.
    sdk.host().documentOpenedFor(std.fs.path.extension(heap_doc.path), heap_doc.path, heap_doc.text.items);
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
    doc.pending_sel = .collapsed(doc.byteOffsetForLineCharacter(line, character));
    doc.pending_scroll_line = line;
    // Both panes show the same document, so a reveal means both. Set unconditionally — whether
    // the extension has a preview, and whether it is on screen, is `TextEditor`'s to know.
    doc.pending_preview_line = line;
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

fn infobarEntries(_: *anyopaque, active_doc: ?DocHandle) []const sdk.infobar.Entry {
    const handle = active_doc orelse return &.{};
    if (handle.owner != &plugin) return &.{};
    const doc = docFrom(handle) orelse return &.{};
    const arena = sdk.host().arena();
    const pos = doc.lineCharacterForByteOffset(doc.sel_start);
    const pos_text = std.fmt.allocPrint(arena, "Ln {d}, Col {d}", .{ pos.line + 1, pos.character + 1 }) catch return &.{};
    const name = std.fs.path.basename(doc.path);
    const entries = arena.alloc(sdk.infobar.Entry, 2) catch return &.{};
    entries[0] = .{
        .icon = icons.tvg.lucide.file,
        .text = if (name.len > 0) name else "Untitled",
    };
    entries[1] = .{ .text = pos_text };
    return entries;
}

fn closeDocument(_: *anyopaque, handle: DocHandle) void {
    (docFrom(handle) orelse return).deinit();
}
fn reloadDocument(_: *anyopaque, handle: DocHandle) anyerror!void {
    const doc = docFrom(handle) orelse return error.DocumentNotFound;
    try doc.reloadFromDisk();
    sdk.host().documentOpenedFor(std.fs.path.extension(doc.path), doc.path, doc.text.items);
}
fn captureDocumentState(_: *anyopaque, handle: DocHandle, allocator: std.mem.Allocator) anyerror![]u8 {
    const doc = docFrom(handle) orelse return error.DocumentNotFound;
    return doc.captureState(allocator);
}
fn restoreDocumentState(_: *anyopaque, handle: DocHandle, bytes: []const u8) anyerror!void {
    const doc = docFrom(handle) orelse return error.DocumentNotFound;
    try doc.restoreState(bytes);
}
fn documentFingerprint(_: *anyopaque, handle: DocHandle) u64 {
    const doc = docFrom(handle) orelse return 0;
    return doc.fingerprint();
}
fn isDirty(_: *anyopaque, handle: DocHandle) bool {
    return (docFrom(handle) orelse return false).isDirty();
}

/// Drive each open document's content-change debounce. Returns true while any of them still
/// owes a notification, so fizzy keeps drawing until the burst settles instead of idling with
/// one pending.
fn tickOpenDocuments(state: *anyopaque) bool {
    const st: *State = @ptrCast(@alignCast(state));
    var pending = false;
    for (st.docs.values()) |doc| {
        if (doc.tickContentChanged()) pending = true;
    }
    return pending;
}
fn saveDocument(state: *anyopaque, handle: DocHandle) anyerror!void {
    const doc = docFrom(handle) orelse return;
    const st: *State = @ptrCast(@alignCast(state));
    if (st.settings.format_on_save.get()) formatDocument(doc);
    try doc.save();
}
/// The storage-agnostic half of saving: the host writes these wherever the document lives
/// (a mounted drive) and reports back through `documentWritten`. Format-on-save applies here
/// exactly as it does in `saveDocument`.
fn documentBytes(state: *anyopaque, handle: DocHandle, allocator: std.mem.Allocator) anyerror![]u8 {
    const doc = docFrom(handle) orelse return error.DocumentNotFound;
    const st: *State = @ptrCast(@alignCast(state));
    if (st.settings.format_on_save.get()) formatDocument(doc);
    return doc.savedBytes(allocator);
}
fn documentWritten(_: *anyopaque, handle: DocHandle, path: []const u8) anyerror!void {
    const doc = docFrom(handle) orelse return error.DocumentNotFound;
    try doc.written(path);
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
//
// Both report enabled only while this editor holds keyboard focus. That is fizzy's
// discriminator for routing a clipboard verb here versus to another focused text input — a
// search box, the Output Panel — which it otherwise has no way to tell apart (see
// `Keybinds.clipboardVerb` in fizzy, and `Document.editor_focused`). Reporting enabled
// while focus is elsewhere would make Copy in that search box copy this document instead.

fn cmdCopyEnabled(state: *anyopaque) bool {
    const doc = activeTextDoc(state) orelse return false;
    return doc.editor_focused and doc.sel_start != doc.sel_end;
}
fn cmdCopy(state: *anyopaque) anyerror!void {
    const doc = activeTextDoc(state) orelse return;
    if (doc.sel_start == doc.sel_end) return;
    dvui.clipboardTextSet(doc.text.items[doc.sel_start..doc.sel_end]);
}
fn cmdPasteEnabled(state: *anyopaque) bool {
    const doc = activeTextDoc(state) orelse return false;
    return doc.editor_focused;
}
fn cmdPaste(state: *anyopaque) anyerror!void {
    const doc = activeTextDoc(state) orelse return;
    const clip = dvui.clipboardText();
    if (clip.len == 0) return;
    try doc.replaceRange(doc.sel_start, doc.sel_end, clip);
}

// ---- format command -------------------------------------------------------------

const GoToLine = sdk.Command.Params(struct {
    line: sdk.Command.Arg(u32, .{ .description = "The line to go to, counting from 1.", .min = 1 }),
    column: sdk.Command.Arg(u32, .{ .description = "The column on that line, counting from 1.", .min = 1 }) = .init(1),
});
fn cmdGoToLineEnabled(state: *anyopaque) bool {
    return activeTextDoc(state) != null;
}
/// Puts the caret at `line`:`column` of the active document, clamped to it, and returns where it
/// landed (`.{ .line, .column }`, from 1).
fn cmdGoToLine(state: *anyopaque, args: GoToLine.Args, call: *sdk.Command.Call) anyerror!void {
    const doc = activeTextDoc(state) orelse return call.fail("no text document is active", .{});
    const offset = doc.byteOffsetForLineCharacter(args.line -| 1, args.column -| 1);
    const at = doc.lineCharacterForByteOffset(offset);
    doc.pending_sel = .collapsed(offset);
    doc.pending_scroll_line = at.line;
    doc.pending_preview_line = at.line;
    try call.returns(.{ .line = at.line + 1, .column = at.character + 1 });
}
const Insert = sdk.Command.Params(struct {
    text: sdk.Command.Arg([]const u8, .{ .description = "The text to insert." }),
    line: sdk.Command.Arg(u32, .{ .description = "The line to insert at, counting from 1. 0 inserts at the caret, replacing any selection, as typing does." }) = .init(0),
    column: sdk.Command.Arg(u32, .{ .description = "The column on that line, counting from 1.", .min = 1 }) = .init(1),
});
/// Inserts `text` as one undoable edit and returns where the caret landed, after it
/// (`.{ .line, .column }`, from 1).
fn cmdInsert(state: *anyopaque, args: Insert.Args, call: *sdk.Command.Call) anyerror!void {
    const doc = activeTextDoc(state) orelse return call.fail("no text document is active", .{});
    const start, const end = if (args.line == 0)
        .{ @min(doc.sel_start, doc.sel_end), @max(doc.sel_start, doc.sel_end) }
    else blk: {
        const at = doc.byteOffsetForLineCharacter(args.line - 1, args.column -| 1);
        break :blk .{ at, at };
    };
    try doc.replaceRange(@min(start, doc.text.items.len), @min(end, doc.text.items.len), args.text);
    try returnCaret(doc, call);
}

const Replace = sdk.Command.Params(struct {
    find: sdk.Command.Arg([]const u8, .{ .description = "The exact text to find. Without `all`, it must occur exactly once." }),
    with: sdk.Command.Arg([]const u8, .{ .description = "What to put in its place." }),
    all: sdk.Command.Arg(bool, .{ .description = "Replace every occurrence rather than the one." }) = .init(false),
});
/// Replaces `find` with `with`, as one undoable edit. Without `all`, a `find` that occurs more
/// than once is refused rather than guessed at: the caller narrows it with more context. Returns
/// how many were replaced and where the caret landed.
fn cmdReplace(state: *anyopaque, args: Replace.Args, call: *sdk.Command.Call) anyerror!void {
    const doc = activeTextDoc(state) orelse return call.fail("no text document is active", .{});
    if (args.find.len == 0) return call.fail("find is empty", .{});
    const text = doc.text.items;
    const count = std.mem.count(u8, text, args.find);
    if (count == 0) return call.fail("not found: the text does not occur in {s}", .{std.fs.path.basename(doc.path)});
    if (count > 1 and !args.all) return call.fail("found {d} times: give more of the surrounding text, or all = true", .{count});

    if (count == 1) {
        const at = std.mem.indexOf(u8, text, args.find).?;
        try doc.replaceRange(at, at + args.find.len, args.with);
    } else {
        // Every occurrence, as one edit: one undo puts them all back.
        const replaced = try std.mem.replaceOwned(u8, call.arena, text, args.find, args.with);
        const first = std.mem.indexOf(u8, text, args.find).?;
        try doc.replaceRange(0, text.len, replaced);
        const caret = first + args.with.len;
        doc.sel_start = caret;
        doc.sel_end = caret;
        doc.pending_sel = .collapsed(caret);
    }
    const at = doc.lineCharacterForByteOffset(doc.sel_start);
    doc.pending_scroll_line = at.line;
    try call.returns(.{ .replaced = count, .line = at.line + 1, .column = at.character + 1 });
}

const Read = sdk.Command.Params(struct {
    from_line: sdk.Command.Arg(u32, .{ .description = "The first line to read, counting from 1.", .min = 1 }) = .init(1),
    to_line: sdk.Command.Arg(u32, .{ .description = "The last line to read. 0 reads to the end." }) = .init(0),
});
/// The active document as it is in the editor, unsaved edits included: its path, the lines
/// asked for, how many lines it has, and where the caret is.
fn cmdRead(state: *anyopaque, args: Read.Args, call: *sdk.Command.Call) anyerror!void {
    const doc = activeTextDoc(state) orelse return call.fail("no text document is active", .{});
    const first = args.from_line - 1;
    const start = doc.byteOffsetForLineCharacter(first, 0);
    const end = if (args.to_line == 0 or args.to_line >= doc.line_count)
        doc.text.items.len
    else
        doc.byteOffsetForLineCharacter(args.to_line, 0);
    const caret = doc.lineCharacterForByteOffset(doc.sel_start);
    try call.returns(.{
        .path = doc.path,
        .lines = doc.line_count,
        .from_line = args.from_line,
        .text = doc.text.items[@min(start, end)..end],
        .caret = .{ .line = caret.line + 1, .column = caret.character + 1 },
        .unsaved = doc.isDirty(),
    });
}

/// Scroll the caret into view and return where it is, from 1.
fn returnCaret(doc: *Document, call: *sdk.Command.Call) !void {
    const at = doc.lineCharacterForByteOffset(doc.sel_start);
    doc.pending_scroll_line = at.line;
    try call.returns(.{ .line = at.line + 1, .column = at.character + 1 });
}

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
    doc.pending_sel = .collapsed(restore_cursor);
}

/// The id of the editor's right-click menu. Other plugins contribute to it by this name.
pub const document_menu_id = "text.menu.document";

/// A text document has a right-click menu; see `Plugin.VTable.documentContextMenu` for why that
/// is the owner's call and not fizzy's.
fn documentContextMenu(_: *anyopaque, _: sdk.DocHandle) ?[]const u8 {
    return document_menu_id;
}

/// Copy and Paste — as *commands*, `fizzy.copy`/`fizzy.paste`, the same ones ⌘C and ⌘V run. While
/// this menu is open the active document is still this one, which is exactly what those route
/// to, so the row and the keybind can never disagree about what gets copied. `drawMenuItem`
/// shows the chord beside each and greys a row its command says is disabled.
fn drawDocumentMenu(_: ?*anyopaque) anyerror!void {
    const host = sdk.host();
    inline for (.{ .{ "Copy", "fizzy.copy" }, .{ "Paste", "fizzy.paste" } }) |row| {
        if (host.drawMenuItem(row[0], row[1])) {
            host.runCommand(row[1]) catch |err| dvui.log.err("text: {s} failed: {t}", .{ row[1], err });
        }
    }
}

/// In-app "Edit" menu section (see `Host.registerMenuSection`) — always drawn; `Host.drawMenuItem`
/// greys the row itself by reading the command's registered `isEnabled` (`cmdFormatEnabled`
/// below), so this no longer has to early-return to keep the row from being a permanently-live
/// no-op for a non-formattable document. That early return used to make the row disappear
/// entirely here while the *native* macOS menu — a static bar with no per-row enabled hook —
/// kept showing it regardless, so the two disagreed on every document that couldn't format.
///
/// Draws via `Host.drawMenuItem` rather than calling `dvui.menuItem()`/`dvui.separator()`
/// directly — see that function's doc comment for why a menu section contribution can't safely
/// touch dvui's menu widgets itself.
fn drawEditMenuSection(ctx: ?*anyopaque) anyerror!void {
    _ = ctx;
    if (sdk.host().drawMenuItem("Format Document", sdk.Plugin.commandId("text", "format"))) {
        sdk.host().runCommand(sdk.Plugin.commandId("text", "format")) catch |err| {
            dvui.log.err("text: format command failed: {any}", .{err});
        };
    }
}

/// The native macOS Edit menu is a static bar rebuilt only on plugin load/unload, so this item
/// is always present; the native menu has no per-row enabled hook to grey it, so this guard is
/// what actually keeps it inert for a non-formattable document (mirrors `pixi`'s native
/// Transform/Grid Layout items).
fn nativeFormat(_: ?*anyopaque) anyerror!void {
    if (!cmdFormatEnabled(plugin.state)) return;
    try sdk.host().runCommand(sdk.Plugin.commandId("text", "format"));
}

/// Resolves the currently-focused document, but only when it belongs to this plugin — a
/// `Command`'s `run`/`isEnabled` only receive the plugin's own opaque `state`, not a doc, so
/// they always need to ask fizzy which document is active.
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
