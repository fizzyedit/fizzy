//! A feature module that plugs into the editor shell. Today plugins are compiled
//! in and registered statically; the same vtable shape is what a prebuilt plugin
//! dylib will expose at runtime. All hooks are optional function pointers taking
//! the plugin's own opaque `state`, so a plugin implements only what it needs
//! (e.g. the workbench plugin has no `drawDocument`; an editor plugin does).
//!
//! Cross-boundary types may be normal Zig types (not strict C-ABI): host and
//! plugins are pinned to the same SDK build, so layouts match. Only the dlopen
//! entry symbols need `callconv(.c)`.
const std = @import("std");
const dvui = @import("dvui");
const DocHandle = @import("DocHandle.zig");
const EditorAPI = @import("EditorAPI.zig");

pub const Plugin = @This();

/// Opaque, plugin-owned state passed back to every vtable call.
state: *anyopaque,
vtable: *const VTable,

/// Stable, unique identifier (snake_case), e.g. "pixelart", "workbench".
id: []const u8,
/// User-facing name shown in UI.
display_name: []const u8,

/// Context for an owner's "save would flatten lossy data" confirmation
/// (`requestFlatRasterSaveWarning`). `editor_save` is a plain in-place save; `save_and_close`
/// is part of a close/quit flow and resumes the shell close walk once the save settles.
pub const FlatRasterSaveMode = enum { editor_save, save_and_close };

pub const VTable = struct {
    /// Tear down `state`. Called when the plugin is unregistered / app shuts down.
    deinit: ?*const fn (state: *anyopaque) void = null,
    /// One-time plugin setup (e.g. background worker threads).
    initPlugin: ?*const fn (state: *anyopaque) anyerror!void = null,

    /// Priority for opening files with extension `ext` (including the dot, e.g.
    /// ".fiz"); lower value wins. `null` = this plugin does not handle `ext`.
    /// A plugin may claim many extensions.
    fileTypePriority: ?*const fn (state: *anyopaque, ext: []const u8) ?u8 = null,

    // ---- document lifecycle (operates on the plugin's own type via DocHandle) ----
    /// Load the document at `path`, constructing the plugin's own document value in
    /// place at `out_doc`. The shell owns the typed buffer behind `out_doc` (for pixel
    /// art a `*Internal.File`); the SDK stays type-agnostic. Runs on the shell's load
    /// worker thread, so it must only touch the host allocator + the given buffer.
    loadDocument: ?*const fn (state: *anyopaque, path: []const u8, out_doc: *anyopaque) anyerror!void = null,
    /// `loadDocument`, but from in-memory bytes (browser file picker). `path` is used
    /// for extension detection + display name. Synchronous (web has no load worker).
    loadDocumentFromBytes: ?*const fn (state: *anyopaque, path: []const u8, bytes: []const u8, out_doc: *anyopaque) anyerror!void = null,
    /// Size of the plugin's document type for stack/heap staging buffers (`loadDocument`, etc.).
    documentStackSize: ?*const fn (state: *anyopaque) usize = null,
    documentStackAlign: ?*const fn (state: *anyopaque) usize = null,
    documentIdFromBuffer: ?*const fn (state: *anyopaque, doc: *anyopaque) u64 = null,
    deinitDocumentBuffer: ?*const fn (state: *anyopaque, doc: *anyopaque) void = null,
    setDocumentGroupingOnBuffer: ?*const fn (state: *anyopaque, doc: *anyopaque, grouping: u64) void = null,
    createDocument: ?*const fn (state: *anyopaque, path: []const u8, grid: EditorAPI.NewDocGrid, out_doc: *anyopaque) anyerror!void = null,
    saveDocument: ?*const fn (state: *anyopaque, doc: DocHandle) anyerror!void = null,
    closeDocument: ?*const fn (state: *anyopaque, doc: DocHandle) void = null,
    isDirty: ?*const fn (state: *anyopaque, doc: DocHandle) bool = null,
    undo: ?*const fn (state: *anyopaque, doc: DocHandle) anyerror!void = null,
    redo: ?*const fn (state: *anyopaque, doc: DocHandle) anyerror!void = null,
    canUndo: ?*const fn (state: *anyopaque, doc: DocHandle) bool = null,
    canRedo: ?*const fn (state: *anyopaque, doc: DocHandle) bool = null,

    /// Register a loaded/created document in the plugin's open-doc map. `file` points at
    /// the plugin's document type (for pixel art, `*Internal.File` on the caller's stack).
    /// Returns the stable registry pointer for `DocHandle.ptr`.
    registerOpenDocument: ?*const fn (state: *anyopaque, file: *anyopaque) anyerror!*anyopaque = null,
    /// Resolve a document id to the plugin's registry pointer, or null when not open.
    documentPtr: ?*const fn (state: *anyopaque, id: u64) ?*anyopaque = null,
    /// Lookup an open document by absolute path.
    documentByPath: ?*const fn (state: *anyopaque, path: []const u8) ?*anyopaque = null,
    /// Drop the registry entry after `closeDocument` has torn down resources.
    unregisterDocument: ?*const fn (state: *anyopaque, id: u64) void = null,

    /// Bind a document to a workbench pane before `drawDocument` (canvas id, workspace handle, center flag).
    bindDocumentToPane: ?*const fn (state: *anyopaque, doc: DocHandle, canvas_id: dvui.Id, workspace_handle: *anyopaque, center: bool) void = null,
    documentGrouping: ?*const fn (state: *anyopaque, doc: DocHandle) u64 = null,
    setDocumentGrouping: ?*const fn (state: *anyopaque, doc: DocHandle, grouping: u64) void = null,
    removeCanvasPane: ?*const fn (state: *anyopaque, grouping: u64, allocator: std.mem.Allocator) void = null,
    documentPath: ?*const fn (state: *anyopaque, doc: DocHandle) []const u8 = null,
    setDocumentPath: ?*const fn (state: *anyopaque, doc: DocHandle, path: []const u8) anyerror!void = null,
    documentHasNativeExtension: ?*const fn (state: *anyopaque, doc: DocHandle) bool = null,
    /// True when `saveDocument` can write the document without Save As (e.g. `.fiz` or flat image).
    documentHasRecognizedSaveExtension: ?*const fn (state: *anyopaque, doc: DocHandle) bool = null,
    showsSaveStatusIndicator: ?*const fn (state: *anyopaque, doc: DocHandle) bool = null,
    isDocumentSaving: ?*const fn (state: *anyopaque, doc: DocHandle) bool = null,
    shouldConfirmFlatRasterSave: ?*const fn (state: *anyopaque, doc: DocHandle) bool = null,
    saveDocumentAsync: ?*const fn (state: *anyopaque, doc: DocHandle) anyerror!void = null,
    timeSinceSaveCompleteNs: ?*const fn (state: *anyopaque, doc: DocHandle) ?i128 = null,
    documentDefaultSaveAsFilename: ?*const fn (state: *anyopaque, doc: DocHandle, allocator: std.mem.Allocator) anyerror![]const u8 = null,
    saveDocumentAs: ?*const fn (state: *anyopaque, doc: DocHandle, path: []const u8, window: *dvui.Window) anyerror!void = null,
    resetDocumentSaveUIState: ?*const fn (state: *anyopaque, doc: DocHandle) void = null,
    /// Open the owner's "new document" dialog. Not doc-scoped — the host dispatches to a plugin
    /// that provides one (see `Host.requestNewDocument`). `parent_path` (when set) creates the
    /// document on disk in that folder; `id_extra` disambiguates per-explorer-row launches.
    /// TODO: with more than one editor plugin this becomes a typed "New > <kind>" chooser.
    requestNewDocumentDialog: ?*const fn (state: *anyopaque, parent_path: ?[]const u8, id_extra: usize) void = null,
    /// Open the owner's grid-layout dialog for `doc` (pixel-art specific; the shell only
    /// resolves the active doc and dispatches here so it never names the plugin's dialog).
    requestGridLayoutDialog: ?*const fn (state: *anyopaque, doc: DocHandle) void = null,
    /// Open the owner's "save would flatten lossy data" confirmation for `doc`. The shell calls
    /// this when `shouldConfirmFlatRasterSave(doc)` is true; the dialog drives the save through
    /// the shell save/close API. `from_save_all_quit` marks requests issued during the quit walk.
    requestFlatRasterSaveWarning: ?*const fn (state: *anyopaque, doc: DocHandle, mode: FlatRasterSaveMode, from_save_all_quit: bool) void = null,

    // ---- render hooks (the plugin draws its own dvui UI into the host window) ----
    // Sidebar/explorer panes and bottom-panel tabs are NOT vtable hooks — plugins
    // contribute them as named, owned views via `Host.registerSidebarView` /
    // `Host.registerBottomView`, which the shell renders as tab strips when more than
    // one is registered. Only per-document rendering routes through the vtable below.
    /// Draw an open document (center/workspace region), dispatched via `DocHandle.owner`.
    drawDocument: ?*const fn (state: *anyopaque, doc: DocHandle) anyerror!void = null,
    /// Draw active-document status into the shell infobar (dimensions, cursor, etc.).
    drawDocumentInfobar: ?*const fn (state: *anyopaque, doc: DocHandle) anyerror!void = null,

    // ---- shell contributions ----
    contributeMenu: ?*const fn (state: *anyopaque) anyerror!void = null,
    contributeKeybinds: ?*const fn (state: *anyopaque, win: *dvui.Window) anyerror!void = null,

    // ---- per-frame shell hooks (global keybinds, overlays) ----
    /// Called once at the top of every shell frame, before any document drawing. Plugins
    /// use this to advance their internal frame clock / invalidate per-frame caches.
    beginFrame: ?*const fn (state: *anyopaque) void = null,
    tickKeybinds: ?*const fn (state: *anyopaque) anyerror!void = null,
    tickOpenDocuments: ?*const fn (state: *anyopaque) bool = null,
    tickActiveDocumentPlayback: ?*const fn (state: *anyopaque, timer_host_id: dvui.Id) void = null,
    resetDocumentPeekLayers: ?*const fn (state: *anyopaque) void = null,
    warmupActiveDocumentComposites: ?*const fn (state: *anyopaque) void = null,
    isAnyDocumentActivelyDrawing: ?*const fn (state: *anyopaque) bool = null,
    processRadialMenuInput: ?*const fn (state: *anyopaque) void = null,
    radialMenuVisible: ?*const fn (state: *anyopaque) bool = null,
    drawRadialMenu: ?*const fn (state: *anyopaque) anyerror!void = null,

    // ---- editing + project pack (pixel-art today; future plugins opt in) ----
    transform: ?*const fn (state: *anyopaque) anyerror!void = null,
    copy: ?*const fn (state: *anyopaque) anyerror!void = null,
    paste: ?*const fn (state: *anyopaque) anyerror!void = null,
    acceptEdit: ?*const fn (state: *anyopaque) void = null,
    cancelEdit: ?*const fn (state: *anyopaque) void = null,
    deleteSelection: ?*const fn (state: *anyopaque) void = null,
    startPackProject: ?*const fn (state: *anyopaque) anyerror!void = null,
    isPackingActive: ?*const fn (state: *const anyopaque) bool = null,
    tickPackJobs: ?*const fn (state: *anyopaque) void = null,
    runPackWorkers: ?*const fn (state: *anyopaque) void = null,
    persistProjectFolder: ?*const fn (state: *anyopaque) void = null,
    reloadProjectFolder: ?*const fn (state: *anyopaque, allocator: std.mem.Allocator) void = null,
};

// Thin wrappers so callers don't repeat the optional-vtable dance.

pub fn fileTypePriority(self: Plugin, ext: []const u8) ?u8 {
    return if (self.vtable.fileTypePriority) |f| f(self.state, ext) else null;
}

pub fn contributeKeybinds(self: Plugin, win: *dvui.Window) !void {
    if (self.vtable.contributeKeybinds) |f| try f(self.state, win);
}

pub fn tickKeybinds(self: Plugin) !void {
    if (self.vtable.tickKeybinds) |f| try f(self.state);
}

pub fn processRadialMenuInput(self: Plugin) void {
    if (self.vtable.processRadialMenuInput) |f| f(self.state);
}

pub fn radialMenuVisible(self: Plugin) bool {
    return if (self.vtable.radialMenuVisible) |f| f(self.state) else false;
}

pub fn drawRadialMenu(self: Plugin) !void {
    if (self.vtable.drawRadialMenu) |f| try f(self.state);
}

pub fn copy(self: Plugin) !void {
    if (self.vtable.copy) |f| try f(self.state);
}

pub fn paste(self: Plugin) !void {
    if (self.vtable.paste) |f| try f(self.state);
}

pub fn startPackProject(self: Plugin) !void {
    if (self.vtable.startPackProject) |f| try f(self.state);
}

pub fn isPackingActive(self: Plugin) bool {
    return if (self.vtable.isPackingActive) |f| f(self.state) else false;
}

pub fn tickPackJobs(self: Plugin) void {
    if (self.vtable.tickPackJobs) |f| f(self.state);
}

pub fn runPackWorkers(self: Plugin) void {
    if (self.vtable.runPackWorkers) |f| f(self.state);
}

pub fn transform(self: Plugin) !void {
    if (self.vtable.transform) |f| try f(self.state);
}

pub fn registerOpenDocument(self: Plugin, file: *anyopaque) !*anyopaque {
    return if (self.vtable.registerOpenDocument) |f| try f(self.state, file) else error.Unsupported;
}

pub fn documentPtr(self: Plugin, id: u64) ?*anyopaque {
    return if (self.vtable.documentPtr) |f| f(self.state, id) else null;
}

pub fn documentByPath(self: Plugin, path: []const u8) ?*anyopaque {
    return if (self.vtable.documentByPath) |f| f(self.state, path) else null;
}

pub fn unregisterDocument(self: Plugin, id: u64) void {
    if (self.vtable.unregisterDocument) |f| f(self.state, id);
}

pub fn persistProjectFolder(self: Plugin) void {
    if (self.vtable.persistProjectFolder) |f| f(self.state);
}

pub fn reloadProjectFolder(self: Plugin, allocator: std.mem.Allocator) void {
    if (self.vtable.reloadProjectFolder) |f| f(self.state, allocator);
}

pub fn bindDocumentToPane(self: Plugin, doc: DocHandle, canvas_id: dvui.Id, workspace_handle: *anyopaque, center: bool) void {
    if (self.vtable.bindDocumentToPane) |f| f(self.state, doc, canvas_id, workspace_handle, center);
}

pub fn documentGrouping(self: Plugin, doc: DocHandle) u64 {
    return if (self.vtable.documentGrouping) |f| f(self.state, doc) else 0;
}

pub fn setDocumentGrouping(self: Plugin, doc: DocHandle, grouping: u64) void {
    if (self.vtable.setDocumentGrouping) |f| f(self.state, doc, grouping);
}

pub fn removeCanvasPane(self: Plugin, grouping: u64, allocator: std.mem.Allocator) void {
    if (self.vtable.removeCanvasPane) |f| f(self.state, grouping, allocator);
}

pub fn documentPath(self: Plugin, doc: DocHandle) []const u8 {
    return if (self.vtable.documentPath) |f| f(self.state, doc) else "";
}

pub fn setDocumentPath(self: Plugin, doc: DocHandle, path: []const u8) !void {
    if (self.vtable.setDocumentPath) |f| try f(self.state, doc, path);
}

pub fn documentHasNativeExtension(self: Plugin, doc: DocHandle) bool {
    return if (self.vtable.documentHasNativeExtension) |f| f(self.state, doc) else false;
}

pub fn documentHasRecognizedSaveExtension(self: Plugin, doc: DocHandle) bool {
    return if (self.vtable.documentHasRecognizedSaveExtension) |f| f(self.state, doc) else false;
}

pub fn showsSaveStatusIndicator(self: Plugin, doc: DocHandle) bool {
    return if (self.vtable.showsSaveStatusIndicator) |f| f(self.state, doc) else false;
}

pub fn isDocumentSaving(self: Plugin, doc: DocHandle) bool {
    return if (self.vtable.isDocumentSaving) |f| f(self.state, doc) else false;
}

pub fn shouldConfirmFlatRasterSave(self: Plugin, doc: DocHandle) bool {
    return if (self.vtable.shouldConfirmFlatRasterSave) |f| f(self.state, doc) else false;
}

pub fn saveDocumentAsync(self: Plugin, doc: DocHandle) !void {
    if (self.vtable.saveDocumentAsync) |f| try f(self.state, doc);
}

pub fn timeSinceSaveCompleteNs(self: Plugin, doc: DocHandle) ?i128 {
    return if (self.vtable.timeSinceSaveCompleteNs) |f| f(self.state, doc) else null;
}

// ---- document lifecycle wrappers (operate on a DocHandle this plugin owns) ----

/// Load `path` into the shell-owned buffer at `out_doc`. Returns whether the plugin
/// handled it; `false` means this plugin exposes no loader (the shell should treat the
/// open as failed). See the `loadDocument` vtable field for the threading contract.
pub fn loadDocument(self: Plugin, path: []const u8, out_doc: *anyopaque) !bool {
    if (self.vtable.loadDocument) |f| {
        try f(self.state, path, out_doc);
        return true;
    }
    return false;
}

/// `loadDocument`, but from in-memory `bytes` (browser file picker).
pub fn loadDocumentFromBytes(self: Plugin, path: []const u8, bytes: []const u8, out_doc: *anyopaque) !bool {
    if (self.vtable.loadDocumentFromBytes) |f| {
        try f(self.state, path, bytes, out_doc);
        return true;
    }
    return false;
}

pub fn isDirty(self: Plugin, doc: DocHandle) bool {
    return if (self.vtable.isDirty) |f| f(self.state, doc) else false;
}

pub fn saveDocument(self: Plugin, doc: DocHandle) !void {
    if (self.vtable.saveDocument) |f| try f(self.state, doc);
}

/// Tear down an open document. Returns whether the plugin handled it, so the shell
/// can fall back to its own teardown when no plugin claims the document.
pub fn closeDocument(self: Plugin, doc: DocHandle) bool {
    if (self.vtable.closeDocument) |f| {
        f(self.state, doc);
        return true;
    }
    return false;
}

pub fn undo(self: Plugin, doc: DocHandle) !void {
    if (self.vtable.undo) |f| try f(self.state, doc);
}

pub fn redo(self: Plugin, doc: DocHandle) !void {
    if (self.vtable.redo) |f| try f(self.state, doc);
}

pub fn canUndo(self: Plugin, doc: DocHandle) bool {
    return if (self.vtable.canUndo) |f| f(self.state, doc) else false;
}

pub fn canRedo(self: Plugin, doc: DocHandle) bool {
    return if (self.vtable.canRedo) |f| f(self.state, doc) else false;
}

// ---- render hook wrappers ----

/// Draw an open document into the current dvui parent (the workbench sets up the
/// container, then routes here). Returns whether the plugin drew anything.
pub fn drawDocument(self: Plugin, doc: DocHandle) !bool {
    if (self.vtable.drawDocument) |f| {
        try f(self.state, doc);
        return true;
    }
    return false;
}

pub fn drawDocumentInfobar(self: Plugin, doc: DocHandle) !void {
    if (self.vtable.drawDocumentInfobar) |f| try f(self.state, doc);
}

pub fn deinit(self: Plugin) void {
    if (self.vtable.deinit) |f| f(self.state);
}

pub fn initPlugin(self: Plugin) !void {
    if (self.vtable.initPlugin) |f| try f(self.state);
}

pub fn documentStackSize(self: Plugin) usize {
    return if (self.vtable.documentStackSize) |f| f(self.state) else 0;
}

pub fn documentStackAlign(self: Plugin) usize {
    return if (self.vtable.documentStackAlign) |f| f(self.state) else 1;
}

pub fn documentIdFromBuffer(self: Plugin, doc: *anyopaque) u64 {
    return if (self.vtable.documentIdFromBuffer) |f| f(self.state, doc) else 0;
}

pub fn deinitDocumentBuffer(self: Plugin, doc: *anyopaque) void {
    if (self.vtable.deinitDocumentBuffer) |f| f(self.state, doc);
}

pub fn setDocumentGroupingOnBuffer(self: Plugin, doc: *anyopaque, grouping: u64) void {
    if (self.vtable.setDocumentGroupingOnBuffer) |f| f(self.state, doc, grouping);
}

pub fn createDocument(self: Plugin, path: []const u8, grid: EditorAPI.NewDocGrid, out_doc: *anyopaque) !void {
    if (self.vtable.createDocument) |f| try f(self.state, path, grid, out_doc) else return error.Unsupported;
}

pub fn documentDefaultSaveAsFilename(self: Plugin, doc: DocHandle, allocator: std.mem.Allocator) ![]const u8 {
    return if (self.vtable.documentDefaultSaveAsFilename) |f| try f(self.state, doc, allocator) else error.Unsupported;
}

pub fn saveDocumentAs(self: Plugin, doc: DocHandle, path: []const u8, window: *dvui.Window) !void {
    if (self.vtable.saveDocumentAs) |f| try f(self.state, doc, path, window) else return error.Unsupported;
}

pub fn resetDocumentSaveUIState(self: Plugin, doc: DocHandle) void {
    if (self.vtable.resetDocumentSaveUIState) |f| f(self.state, doc);
}

pub fn requestFlatRasterSaveWarning(self: Plugin, doc: DocHandle, mode: FlatRasterSaveMode, from_save_all_quit: bool) void {
    if (self.vtable.requestFlatRasterSaveWarning) |f| f(self.state, doc, mode, from_save_all_quit);
}

pub fn requestNewDocumentDialog(self: Plugin, parent_path: ?[]const u8, id_extra: usize) void {
    if (self.vtable.requestNewDocumentDialog) |f| f(self.state, parent_path, id_extra);
}

pub fn requestGridLayoutDialog(self: Plugin, doc: DocHandle) void {
    if (self.vtable.requestGridLayoutDialog) |f| f(self.state, doc);
}

pub fn beginFrame(self: Plugin) void {
    if (self.vtable.beginFrame) |f| f(self.state);
}

pub fn tickOpenDocuments(self: Plugin) bool {
    return if (self.vtable.tickOpenDocuments) |f| f(self.state) else false;
}

pub fn tickActiveDocumentPlayback(self: Plugin, timer_host_id: dvui.Id) void {
    if (self.vtable.tickActiveDocumentPlayback) |f| f(self.state, timer_host_id);
}

pub fn resetDocumentPeekLayers(self: Plugin) void {
    if (self.vtable.resetDocumentPeekLayers) |f| f(self.state);
}

pub fn warmupActiveDocumentComposites(self: Plugin) void {
    if (self.vtable.warmupActiveDocumentComposites) |f| f(self.state);
}

pub fn isAnyDocumentActivelyDrawing(self: Plugin) bool {
    return if (self.vtable.isAnyDocumentActivelyDrawing) |f| f(self.state) else false;
}

pub fn acceptEdit(self: Plugin) void {
    if (self.vtable.acceptEdit) |f| f(self.state);
}

pub fn cancelEdit(self: Plugin) void {
    if (self.vtable.cancelEdit) |f| f(self.state);
}

pub fn deleteSelection(self: Plugin) void {
    if (self.vtable.deleteSelection) |f| f(self.state);
}

/// Allocate a buffer suitable for staging `loadDocument` / `createDocument`. Caller frees `backing`.
pub fn allocDocumentBuffer(self: Plugin, allocator: std.mem.Allocator) !struct { backing: []u8, buf: []u8 } {
    const size = self.documentStackSize();
    const align_req = self.documentStackAlign();
    if (size == 0 or align_req == 0) return error.Unsupported;
    const pad = align_req - 1;
    const backing = try allocator.alloc(u8, size + pad);
    const offset = std.mem.alignForward(usize, @intFromPtr(backing.ptr), align_req) - @intFromPtr(backing.ptr);
    return .{ .backing = backing, .buf = backing[offset..][0..size] };
}
