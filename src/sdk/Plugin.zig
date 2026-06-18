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

pub const Plugin = @This();

/// Opaque, plugin-owned state passed back to every vtable call.
state: *anyopaque,
vtable: *const VTable,

/// Stable, unique identifier (snake_case), e.g. "pixelart", "workbench".
id: []const u8,
/// User-facing name shown in UI.
display_name: []const u8,

pub const VTable = struct {
    /// Tear down `state`. Called when the plugin is unregistered / app shuts down.
    deinit: ?*const fn (state: *anyopaque) void = null,

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
    saveDocument: ?*const fn (state: *anyopaque, doc: DocHandle) anyerror!void = null,
    closeDocument: ?*const fn (state: *anyopaque, doc: DocHandle) void = null,
    isDirty: ?*const fn (state: *anyopaque, doc: DocHandle) bool = null,
    undo: ?*const fn (state: *anyopaque, doc: DocHandle) anyerror!void = null,
    redo: ?*const fn (state: *anyopaque, doc: DocHandle) anyerror!void = null,

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
    documentPath: ?*const fn (state: *anyopaque, doc: DocHandle) []const u8 = null,
    setDocumentPath: ?*const fn (state: *anyopaque, doc: DocHandle, path: []const u8) anyerror!void = null,
    documentHasNativeExtension: ?*const fn (state: *anyopaque, doc: DocHandle) bool = null,
    showsSaveStatusIndicator: ?*const fn (state: *anyopaque, doc: DocHandle) bool = null,
    isDocumentSaving: ?*const fn (state: *anyopaque, doc: DocHandle) bool = null,
    shouldConfirmFlatRasterSave: ?*const fn (state: *anyopaque, doc: DocHandle) bool = null,
    saveDocumentAsync: ?*const fn (state: *anyopaque, doc: DocHandle) anyerror!void = null,
    timeSinceSaveCompleteNs: ?*const fn (state: *anyopaque, doc: DocHandle) ?i128 = null,

    // ---- render hooks (the plugin draws its own dvui UI into the host window) ----
    /// Draw the plugin's explorer/sidebar pane (left region).
    drawExplorerPane: ?*const fn (state: *anyopaque) anyerror!void = null,
    /// Draw an open document (center/workspace region).
    drawDocument: ?*const fn (state: *anyopaque, doc: DocHandle) anyerror!void = null,
    /// Draw the plugin's bottom panel content.
    drawBottomPanel: ?*const fn (state: *anyopaque) anyerror!void = null,

    // ---- shell contributions ----
    contributeMenu: ?*const fn (state: *anyopaque) anyerror!void = null,
    contributeKeybinds: ?*const fn (state: *anyopaque, win: *dvui.Window) anyerror!void = null,

    // ---- per-frame shell hooks (global keybinds, overlays) ----
    tickKeybinds: ?*const fn (state: *anyopaque) anyerror!void = null,
    processRadialMenuInput: ?*const fn (state: *anyopaque) void = null,
    radialMenuVisible: ?*const fn (state: *anyopaque) bool = null,
    drawRadialMenu: ?*const fn (state: *anyopaque) anyerror!void = null,

    // ---- editing + project pack (pixel-art today; future plugins opt in) ----
    transform: ?*const fn (state: *anyopaque) anyerror!void = null,
    copy: ?*const fn (state: *anyopaque) anyerror!void = null,
    paste: ?*const fn (state: *anyopaque) anyerror!void = null,
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

pub fn documentPath(self: Plugin, doc: DocHandle) []const u8 {
    return if (self.vtable.documentPath) |f| f(self.state, doc) else "";
}

pub fn setDocumentPath(self: Plugin, doc: DocHandle, path: []const u8) !void {
    if (self.vtable.setDocumentPath) |f| try f(self.state, doc, path);
}

pub fn documentHasNativeExtension(self: Plugin, doc: DocHandle) bool {
    return if (self.vtable.documentHasNativeExtension) |f| f(self.state, doc) else false;
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

pub fn deinit(self: Plugin) void {
    if (self.vtable.deinit) |f| f(self.state);
}
