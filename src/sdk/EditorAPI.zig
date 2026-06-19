//! The shell-provided read/utility surface a plugin reaches through the `Host`.
//!
//! The shell installs one of these on the `Host` during startup (`Host.installShell`);
//! plugins call the convenience forwarders on `Host` (e.g. `host.arena()`), which
//! dispatch through this vtable. It exposes only the genuinely shared shell state a
//! plugin still needs — the per-frame arena, the open project folder, the few shell-
//! owned settings plugins read, and the dirty-mark hook — without leaking the concrete
//! `Editor` type across the SDK boundary.
const std = @import("std");
const dvui = @import("dvui");
const DocHandle = @import("DocHandle.zig");

const EditorAPI = @This();

/// Sub-rect within the shell UI spritesheet. Layout matches `core.Sprite`.
pub const UiSprite = struct {
    origin: [2]f32 = .{ 0.0, 0.0 },
    source: [4]u32,
};

/// Read-only view of the shell's UI icon atlas (source texture + sprite table).
pub const UiAtlasView = struct {
    source: dvui.ImageSource,
    sprites: []const UiSprite,
};

/// A name/extension-pattern pair for a native save dialog. Layout matches the backend's
/// `DialogFileFilter` (which mirrors `SDL_DialogFileFilter`), so the shell forwards a slice
/// of these straight to the backend without a copy. `pattern` is a `;`-separated extension
/// list, e.g. `"png;jpg;jpeg"`.
pub const SaveDialogFilter = extern struct {
    name: [*:0]const u8,
    pattern: [*:0]const u8,
};

/// Invoked when a native save dialog resolves: the chosen paths, or null if cancelled.
pub const SaveDialogCallback = *const fn (?[][:0]const u8) void;

/// Grid dimensions for `createDocument`.
pub const NewDocGrid = struct {
    columns: u32 = 1,
    rows: u32 = 1,
    column_width: u32,
    row_height: u32,
};

/// Web save-dialog kind (wasm only; native ignores).
pub const WebSaveKind = enum { save, save_as };

ctx: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    /// The shell's per-frame arena allocator (reset every frame; do not free).
    arena: *const fn (ctx: *anyopaque) std.mem.Allocator,
    /// The open project root folder, or null when none is open.
    folder: *const fn (ctx: *anyopaque) ?[]const u8,
    /// The user palettes folder (config), or null on platforms without one (web).
    paletteFolder: *const fn (ctx: *anyopaque) ?[]const u8,
    /// Mark shell settings dirty so the debounced autosave persists them.
    markSettingsDirty: *const fn (ctx: *anyopaque) void,
    /// Shell-owned content-area opacity (also drives the shell's own panes); plugins
    /// read it to match the shell chrome.
    contentOpacity: *const fn (ctx: *anyopaque) f32,
    /// Whether the OS window is currently maximized (always false on web).
    isMaximized: *const fn (ctx: *anyopaque) bool,
    /// Runtime macOS detection (uses `navigator.platform` on web, `os.tag` on native).
    isMacOS: *const fn (ctx: *anyopaque) bool,
    /// True on native macOS/Windows where unfocused window chrome dims content opacity.
    appliesNativeWindowOpacity: *const fn (ctx: *anyopaque) bool,
    /// The explorer pane's content rect (shell layout); plugins drawn inside the explorer
    /// read it to size their content. Zero rect when no shell is installed.
    explorerRect: *const fn (ctx: *anyopaque) dvui.Rect,
    /// The explorer scroll area's virtual content size (shell layout). Zero size when no
    /// shell is installed.
    explorerVirtualSize: *const fn (ctx: *anyopaque) dvui.Size,
    /// Run the platform's native "save file" dialog (native: OS dialog; web: download
    /// picker). `cb` is invoked when it resolves. No-op when no shell is installed.
    showSaveDialog: *const fn (
        ctx: *anyopaque,
        cb: SaveDialogCallback,
        filters: []const SaveDialogFilter,
        default_filename: []const u8,
        default_folder: ?[]const u8,
    ) void,
    /// Shell-owned UI icon spritesheet (cursors, tool icons, logo). Stable for the
    /// editor lifetime; plugins read `.source` / `.sprites` but never mutate it.
    uiAtlas: *const fn (ctx: *anyopaque) UiAtlasView,
    /// The actively focused open document, or null when none.
    activeDoc: *const fn (ctx: *anyopaque) ?DocHandle,
    /// Open document by ordered index (tab order), or null when out of range.
    docByIndex: *const fn (ctx: *anyopaque, index: usize) ?DocHandle,
    /// Open document by stable id, or null when not open.
    docById: *const fn (ctx: *anyopaque, id: u64) ?DocHandle,
    /// Ordered index of document `id`, or null when not open.
    docIndex: *const fn (ctx: *anyopaque, id: u64) ?usize,
    /// Number of open documents.
    openDocCount: *const fn (ctx: *anyopaque) usize,
    /// Focus the document at `index` (updates workspace tab selection).
    setActiveDocIndex: *const fn (ctx: *anyopaque, index: usize) void,
    /// Swap the open documents at indices `a` and `b` (used by tab drag-reorder). The shell
    /// owns the open-document collection; this is the only mutation of its order plugins do.
    swapDocs: *const fn (ctx: *anyopaque, a: usize, b: usize) void,
    /// Allocate the next shell document id (monotonic).
    allocDocId: *const fn (ctx: *anyopaque) u64,

    // ---- document editing (active file) ----
    accept: *const fn (ctx: *anyopaque) anyerror!void,
    cancel: *const fn (ctx: *anyopaque) anyerror!void,
    copy: *const fn (ctx: *anyopaque) anyerror!void,
    paste: *const fn (ctx: *anyopaque) anyerror!void,
    transform: *const fn (ctx: *anyopaque) anyerror!void,
    save: *const fn (ctx: *anyopaque) anyerror!void,
    requestCompositeWarmup: *const fn (ctx: *anyopaque) void,

    // ---- new document ----
    /// Heap-owned unique basename like `untitled-1`; caller frees with the app allocator.
    allocUntitledPath: *const fn (ctx: *anyopaque) anyerror![]u8,
    /// Create and open a new document at `path` (path ownership transfers to the shell).
    createDocument: *const fn (ctx: *anyopaque, path: []const u8, grid: NewDocGrid) anyerror!DocHandle,
    /// Hint the files tree to scroll/highlight a path just created (e.g. New File dialog).
    setExplorerNewFilePath: *const fn (ctx: *anyopaque, path: []const u8) anyerror!void,

    // ---- save / quit flow ----
    requestSaveAs: *const fn (ctx: *anyopaque) void,
    requestWebSave: *const fn (ctx: *anyopaque, kind: WebSaveKind) void,
    cancelPendingSaveDialog: *const fn (ctx: *anyopaque) void,
    setPendingCloseDocId: *const fn (ctx: *anyopaque, id: u64) void,
    queueCloseAfterSave: *const fn (ctx: *anyopaque, id: u64) anyerror!void,
    trackQuitSaveInFlight: *const fn (ctx: *anyopaque, id: u64) anyerror!void,
    resumeSaveAllQuit: *const fn (ctx: *anyopaque) void,
    abortSaveAllQuit: *const fn (ctx: *anyopaque) void,

    // ---- project pack ----
    startPackProject: *const fn (ctx: *anyopaque) anyerror!void,
    isPackingActive: *const fn (ctx: *anyopaque) bool,
};

pub fn arena(self: EditorAPI) std.mem.Allocator {
    return self.vtable.arena(self.ctx);
}

pub fn folder(self: EditorAPI) ?[]const u8 {
    return self.vtable.folder(self.ctx);
}

pub fn paletteFolder(self: EditorAPI) ?[]const u8 {
    return self.vtable.paletteFolder(self.ctx);
}

pub fn markSettingsDirty(self: EditorAPI) void {
    self.vtable.markSettingsDirty(self.ctx);
}

pub fn contentOpacity(self: EditorAPI) f32 {
    return self.vtable.contentOpacity(self.ctx);
}

pub fn isMaximized(self: EditorAPI) bool {
    return self.vtable.isMaximized(self.ctx);
}

pub fn isMacOS(self: EditorAPI) bool {
    return self.vtable.isMacOS(self.ctx);
}

pub fn appliesNativeWindowOpacity(self: EditorAPI) bool {
    return self.vtable.appliesNativeWindowOpacity(self.ctx);
}

pub fn explorerRect(self: EditorAPI) dvui.Rect {
    return self.vtable.explorerRect(self.ctx);
}

pub fn explorerVirtualSize(self: EditorAPI) dvui.Size {
    return self.vtable.explorerVirtualSize(self.ctx);
}

pub fn showSaveDialog(
    self: EditorAPI,
    cb: SaveDialogCallback,
    filters: []const SaveDialogFilter,
    default_filename: []const u8,
    default_folder: ?[]const u8,
) void {
    self.vtable.showSaveDialog(self.ctx, cb, filters, default_filename, default_folder);
}

pub fn uiAtlas(self: EditorAPI) UiAtlasView {
    return self.vtable.uiAtlas(self.ctx);
}

pub fn activeDoc(self: EditorAPI) ?DocHandle {
    return self.vtable.activeDoc(self.ctx);
}

pub fn docByIndex(self: EditorAPI, index: usize) ?DocHandle {
    return self.vtable.docByIndex(self.ctx, index);
}

pub fn docById(self: EditorAPI, id: u64) ?DocHandle {
    return self.vtable.docById(self.ctx, id);
}

pub fn docIndex(self: EditorAPI, id: u64) ?usize {
    return self.vtable.docIndex(self.ctx, id);
}

pub fn openDocCount(self: EditorAPI) usize {
    return self.vtable.openDocCount(self.ctx);
}

pub fn setActiveDocIndex(self: EditorAPI, index: usize) void {
    self.vtable.setActiveDocIndex(self.ctx, index);
}

pub fn swapDocs(self: EditorAPI, a: usize, b: usize) void {
    self.vtable.swapDocs(self.ctx, a, b);
}

pub fn allocDocId(self: EditorAPI) u64 {
    return self.vtable.allocDocId(self.ctx);
}

pub fn accept(self: EditorAPI) !void {
    return self.vtable.accept(self.ctx);
}

pub fn cancel(self: EditorAPI) !void {
    return self.vtable.cancel(self.ctx);
}

pub fn copy(self: EditorAPI) !void {
    return self.vtable.copy(self.ctx);
}

pub fn paste(self: EditorAPI) !void {
    return self.vtable.paste(self.ctx);
}

pub fn transform(self: EditorAPI) !void {
    return self.vtable.transform(self.ctx);
}

pub fn save(self: EditorAPI) !void {
    return self.vtable.save(self.ctx);
}

pub fn requestCompositeWarmup(self: EditorAPI) void {
    self.vtable.requestCompositeWarmup(self.ctx);
}

pub fn allocUntitledPath(self: EditorAPI) ![]u8 {
    return self.vtable.allocUntitledPath(self.ctx);
}

pub fn createDocument(self: EditorAPI, path: []const u8, grid: NewDocGrid) !DocHandle {
    return self.vtable.createDocument(self.ctx, path, grid);
}

pub fn setExplorerNewFilePath(self: EditorAPI, path: []const u8) !void {
    return self.vtable.setExplorerNewFilePath(self.ctx, path);
}

pub fn requestSaveAs(self: EditorAPI) void {
    self.vtable.requestSaveAs(self.ctx);
}

pub fn requestWebSave(self: EditorAPI, kind: WebSaveKind) void {
    self.vtable.requestWebSave(self.ctx, kind);
}

pub fn cancelPendingSaveDialog(self: EditorAPI) void {
    self.vtable.cancelPendingSaveDialog(self.ctx);
}

pub fn setPendingCloseDocId(self: EditorAPI, id: u64) void {
    self.vtable.setPendingCloseDocId(self.ctx, id);
}

pub fn queueCloseAfterSave(self: EditorAPI, id: u64) !void {
    return self.vtable.queueCloseAfterSave(self.ctx, id);
}

pub fn trackQuitSaveInFlight(self: EditorAPI, id: u64) !void {
    return self.vtable.trackQuitSaveInFlight(self.ctx, id);
}

pub fn resumeSaveAllQuit(self: EditorAPI) void {
    self.vtable.resumeSaveAllQuit(self.ctx);
}

pub fn abortSaveAllQuit(self: EditorAPI) void {
    self.vtable.abortSaveAllQuit(self.ctx);
}

pub fn startPackProject(self: EditorAPI) !void {
    return self.vtable.startPackProject(self.ctx);
}

pub fn isPackingActive(self: EditorAPI) bool {
    return self.vtable.isPackingActive(self.ctx);
}
