//! A feature module that plugs into the editor fizzy. Today plugins are compiled
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
const infobar = @import("infobar.zig");

pub const Plugin = @This();

/// One filesystem change under the open root folder, delivered via
/// `VTable.folderPathsChanged`.
pub const PathEvent = struct {
    /// Absolute path of the affected object. Valid only for the duration of the call.
    path: []const u8,
    kind: Kind,
    object: ObjectType,
    /// The pre-rename path, for `.renamed` only — and only on platforms whose watcher can pair
    /// the two halves (Linux, Windows). Elsewhere a rename arrives as `.deleted` + `.created`,
    /// which is why a consumer must handle that shape regardless.
    old_path: []const u8 = "",

    pub const Kind = enum { created, modified, deleted, renamed };
    /// `.unknown` happens when the object is already gone by the time fizzy looks (a delete on
    /// Windows, mostly) — treat it as "could be either".
    pub const ObjectType = enum { file, dir, unknown };
};

/// A coalesced batch of filesystem changes.
pub const PathChanges = struct {
    /// Valid only for the duration of the call — copy anything you keep. Already filtered
    /// against fizzy's ignore rules, so `.git`, build caches and gitignored paths never appear.
    events: []const PathEvent,
    /// More changes arrived than fizzy could buffer, so `events` is an incomplete picture of
    /// what happened. A consumer that must not miss anything should rescan the folder rather
    /// than trusting the list. Expect this during a build, a branch switch, or an npm install.
    truncated: bool,
};

/// Opaque, plugin-owned state passed back to every vtable call.
state: *anyopaque,
vtable: *const VTable,

/// Stable, unique identifier (snake_case), e.g. "pixelart", "workbench".
id: []const u8,
/// User-facing name shown in UI.
display_name: []const u8,

/// Mode for an owner's pre-save confirmation (`requestSaveConfirmation`). `editor_save` is a
/// plain in-place save; `save_and_close` is part of a close/quit flow and resumes fizzy
/// close walk once the save settles.
pub const SaveConfirmMode = enum { editor_save, save_and_close };

// Every field below is an optional fn pointer, so the type system requires *nothing*. But to
// function as an **editor** (open / draw / save files) a plugin must implement the document
// cluster — the load+staging hooks (`documentStackSize`/`documentStackAlign`/
// `loadDocument`/`documentIdFromBuffer`/`registerOpenDocument`/`deinitDocumentBuffer`),
// `drawDocument`, `saveDocument`, `isDirty`, and `documentPtr`. Everything else is genuinely
// optional. Each hook's doc comment tags how fizzy invokes it:
//   [broadcast]  — fizzy calls it for every plugin at a fixed point each frame
//   [active-doc] — fizzy calls `doc.owner.hook(doc)` only for the focused document
//   [requested]  — only fires after the plugin asks for it via a `host.*` call
// A plugin that is *not* an editor (the workbench file tree) implements none of the document
// hooks; it contributes panes + a center provider instead.
pub const VTable = struct {
    /// Tear down `state`. Called when the plugin is unregistered / app shuts down.
    deinit: ?*const fn (state: *anyopaque) void = null,
    /// One-time plugin setup (e.g. background worker threads).
    initPlugin: ?*const fn (state: *anyopaque) anyerror!void = null,

    /// The static, enumerable set of file extensions (each including the dot, e.g. ".fiz")
    /// this plugin can own. Absent or empty = the plugin offers nothing to file-type routing
    /// (`workbench`, `markdown`, language-support-only plugins).
    ///
    /// This is an *offer*, not a claim: which loaded plugin actually opens a given extension
    /// is the user's persisted choice, resolved by `Host.pluginForExtension`. There is no
    /// numeric priority — a plugin cannot outrank another by declaring a smaller number.
    /// The returned slice must stay valid for the plugin's lifetime (a static array).
    ///
    /// A plugin that opens *anything* no one else claims does not enumerate extensions here;
    /// it calls `Host.registerFallbackEditor` once from its `register` instead.
    fileTypes: ?*const fn (state: *anyopaque) []const []const u8 = null,

    // ---- document lifecycle (operates on the plugin's own type via DocHandle) ----
    /// Load the document at `path`, constructing the plugin's own document value in
    /// place at `out_doc`. Fizzy owns the typed buffer behind `out_doc` (for pixel
    /// art a `*Internal.File`); the SDK stays type-agnostic. Runs on fizzy's load
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
    /// Reload `doc` from its on-disk path, replacing in-memory contents and clearing dirty
    /// state / undo history as appropriate. Called by fizzy's document watcher when a
    /// clean open file changes externally. Absent = fizzy skips auto-reload for this
    /// owner (dirty conflict detection on save still works via content hashing).
    reloadDocument: ?*const fn (state: *anyopaque, doc: DocHandle) anyerror!void = null,
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
    /// Move the caret to `line`/`character` (0-based; `character` a byte count within the
    /// line, clamped to its actual length) in `doc`, applied on its next draw (mirrors the
    /// `pending_cursor` pattern the text editor already uses internally for undo/redo/paste).
    /// The owner resolves this against its own already-loaded buffer — see
    /// `sdk.language.DefinitionLocation`'s doc comment for why the line/character-vs-byte-
    /// offset split is deliberate. Used by `gotoDefinition` navigation via the workbench-api
    /// `revealPosition` service.
    revealPosition: ?*const fn (state: *anyopaque, doc: DocHandle, line: u32, character: u32) void = null,
    documentHasNativeExtension: ?*const fn (state: *anyopaque, doc: DocHandle) bool = null,
    /// True when `saveDocument` can write the document without Save As (e.g. `.fiz` or flat image).
    documentHasRecognizedSaveExtension: ?*const fn (state: *anyopaque, doc: DocHandle) bool = null,
    showsSaveStatusIndicator: ?*const fn (state: *anyopaque, doc: DocHandle) bool = null,
    isDocumentSaving: ?*const fn (state: *anyopaque, doc: DocHandle) bool = null,
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

    // ---- render hooks (the plugin draws its own dvui UI into the host window) ----
    // Sidebar/explorer panes and bottom-panel tabs are NOT vtable hooks — plugins
    // contribute them as named, owned views via `Host.registerSidebarView` /
    // `Host.registerBottomView`, which fizzy renders as tab strips when more than
    // one is registered. Only per-document rendering routes through the vtable below.
    /// Draw an open document (center/workspace region), dispatched via `DocHandle.owner`.
    drawDocument: ?*const fn (state: *anyopaque, doc: DocHandle) anyerror!void = null,
    /// Infobar chips for this frame. Fizzy draws each as icon + text after its own items
    /// (logo, project folder) — do not draw into the bar. Return a slice that stays valid
    /// until the next call (plugin scratch or `host.arena()`). Empty / absent = nothing
    /// this frame. `active_doc` is the focused document (possibly owned by another plugin);
    /// inspect `ptr` only when `active_doc.owner` is you.
    infobarEntries: ?*const fn (state: *anyopaque, active_doc: ?DocHandle) []const infobar.Entry = null,

    // ---- fizzy contributions ----
    contributeMenu: ?*const fn (state: *anyopaque) anyerror!void = null,
    contributeKeybinds: ?*const fn (state: *anyopaque, win: *dvui.Window) anyerror!void = null,

    // ---- per-frame fizzy phases (fizzy calls these for every plugin each frame, in
    //      this order). A plugin does its own per-frame work (caches, playback, overlays)
    //      inside these generic phases; none carry domain meaning. ----
    /// [broadcast] Top of frame, before workspace rebuild / any document drawing. Advance the
    /// frame clock / invalidate per-frame caches.
    beginFrame: ?*const fn (state: *anyopaque) void = null,
    /// [requested] A one-shot pre-draw pass: runs after layout but before document draw, and
    /// **only on a frame where the plugin asked for it** via `host.requestPrepareFrame()` (not
    /// every frame). Use to warm expensive render data for the upcoming draw. A plugin that
    /// never calls `requestPrepareFrame` never sees this.
    prepareFrame: ?*const fn (state: *anyopaque) void = null,
    /// [broadcast] Process the plugin's own per-frame keyboard shortcuts (distinct from
    /// `contributeKeybinds`, which registers them once). Runs before fizzy's global keybinds.
    tickKeybinds: ?*const fn (state: *anyopaque) anyerror!void = null,
    /// [broadcast] Advance the plugin's open documents; return true to request a follow-up
    /// animation frame (e.g. an in-progress save-status fade).
    tickOpenDocuments: ?*const fn (state: *anyopaque) bool = null,
    /// [broadcast] Advance time-based state for the active document (animation playback, a
    /// blinking cursor, …). `timer_host_id` is the active document container's widget id, to
    /// anchor any dvui timer/animation the plugin schedules.
    tickActiveDocument: ?*const fn (state: *anyopaque, timer_host_id: dvui.Id) void = null,
    /// [broadcast] Draw a plugin-owned floating overlay (tool menu, HUD) on top of the frame,
    /// after the center region is drawn.
    drawOverlay: ?*const fn (state: *anyopaque) anyerror!void = null,
    /// [broadcast] End of the center draw — reset per-frame scratch state held across the draw
    /// (symmetric counterpart to `beginFrame`).
    endFrame: ?*const fn (state: *anyopaque) void = null,
    /// [broadcast] True while the plugin needs fizzy to keep repainting continuously (an
    /// active stroke, a running animation, a background job) rather than idling until input.
    ///
    /// Polled once per frame, from inside the frame, before most plugin drawing happens — so a
    /// plugin that answers out of "was I drawn" state is reporting on the *previous* frame, and
    /// may consume that state as it answers. Returning true asks for one more frame, not a
    /// permanent wakeup: keep returning it for as long as the work lasts.
    ///
    /// This is a request to fizzy, not a substitute for `dvui.refresh` from a *background
    /// thread* — a worker that finishes while the app is asleep still has to wake the loop
    /// itself (`sdk.refresh()`), because nothing is polling anything until something does.
    needsContinuousRepaint: ?*const fn (state: *anyopaque) bool = null,

    // ---- folder lifecycle ----
    /// [broadcast] Fired just before the open root folder changes or closes — a plugin can
    /// persist any state it keyed to that folder (open tabs, view state, …).
    onFolderClose: ?*const fn (state: *anyopaque) void = null,
    /// [broadcast] Fired after a new root folder has opened (read it via `host.folder()`) — a
    /// plugin can load state it keyed to that folder.
    onFolderOpen: ?*const fn (state: *anyopaque, allocator: std.mem.Allocator) void = null,

    // ---- document content ----
    /// [broadcast] An open document's in-memory contents changed. Fired for *every* registered
    /// plugin, not just the owner — the point is to let a plugin that doesn't own the document
    /// observe it anyway (a link indexer watching markdown it will never render, say). The
    /// owner is the one that reports the change, via `Host.notifyDocumentContentChanged`.
    ///
    /// Owners are expected to **debounce**: report after a short lull in typing (a few hundred
    /// ms) and immediately on save, never per keystroke. `path` is the document's path, empty
    /// for an unsaved buffer. `bytes` is the live buffer and is only valid for the duration of
    /// the call — copy anything you keep.
    ///
    /// This is a hint about *unsaved* state; the file on disk still says something else. A
    /// consumer that also watches the filesystem should treat this as an overlay it can drop
    /// once the on-disk version catches up, not as a reason to write anything through.
    documentContentChanged: ?*const fn (state: *anyopaque, path: []const u8, bytes: []const u8) void = null,

    // ---- filesystem ----
    /// [broadcast] Files under the open root folder changed **on disk**. Fired for every
    /// registered plugin — a file tree keeping itself current, a link indexer, a language
    /// server syncing `didChangeWatchedFiles`.
    ///
    /// The counterpart to `documentContentChanged`, and the two are not interchangeable: that
    /// one reports *unsaved buffers* fizzy already knows about, this one reports *the disk*,
    /// including files nothing has open and changes fizzy had no part in — an agent editing
    /// the tree, a `git checkout`, another editor. Neither implies the other, and a plugin
    /// wanting a complete picture wants both.
    ///
    /// Contract:
    /// - Delivered on the **UI thread**, from fizzy's frame tick — never the watcher's thread.
    ///   A dylib must not take a callback on a thread it did not create.
    /// - **Coalesced** (~200ms) so one logical save doesn't arrive as five events, and
    ///   **pre-filtered** against fizzy's ignore rules, so `.git`, build output and gitignored
    ///   paths are already gone.
    /// - Best-effort. Not every platform has a working watcher, and one that does can still
    ///   drop events under load (see `PathChanges.truncated`). Treat this as a prompt to go
    ///   look, not as a ledger. `host.folderWatchActive()` says whether it is running at all;
    ///   a plugin that must stay correct should keep a slow rescan for when it isn't.
    folderPathsChanged: ?*const fn (state: *anyopaque, changes: PathChanges) void = null,

    // ---- save protocol ----
    /// [active-doc] True when the owner wants a confirmation before `saveDocument` (e.g. a save
    /// that would flatten lossy data, change encoding, or overwrite an on-disk change). When
    /// true fizzy calls `requestSaveConfirmation` instead of saving directly.
    saveNeedsConfirmation: ?*const fn (state: *anyopaque, doc: DocHandle) bool = null,
    /// [active-doc] Open the owner's pre-save confirmation dialog for `doc` (only called when
    /// `saveNeedsConfirmation(doc)` is true). The dialog drives the save through fizzy
    /// save/close API. `from_save_all_quit` marks requests issued during the quit walk.
    requestSaveConfirmation: ?*const fn (state: *anyopaque, doc: DocHandle, mode: SaveConfirmMode, from_save_all_quit: bool) void = null,

    // ---- settings ----
    /// [requested] This plugin's persisted settings blob changed while the plugin is loaded —
    /// `blob` is the whole, freshly-serialized zon text (same shape `Host.loadPluginSettings`
    /// returns), not a diff. Fires from **two** sources, and a plugin implementing this should
    /// not assume which one: (1) fizzy's settings pane edited it in-app (see
    /// `Host.storePluginSettings`), or (2) an external edit to `settings.zon` (hand edit, another
    /// tool) was picked up live by the settings watcher and reconciled (see R11 in
    /// docs/PLUGIN_MANIFEST_PLAN.md) — in that case this fires with no settings-pane interaction
    /// having happened at all. A plugin that keeps its own in-memory copy of settings (e.g. to
    /// avoid re-parsing zon every draw) should re-parse and apply it here instead of only reading
    /// the blob once at `register`. Absent = the plugin only ever reads its settings at
    /// `register`/`initPlugin`.
    settingsChanged: ?*const fn (state: *anyopaque, blob: []const u8) void = null,

    // NOTE: editing actions (copy / paste / transform / accept-edit / cancel-edit /
    // delete-selection) are deliberately NOT hooks here. They are user-invoked and their meaning
    // varies per editor, so a plugin registers them as `Command`s (e.g. `"pixelart.copy"`) and
    // fizzy dispatches its Edit-menu / keybinds to `"<active_owner_id>.<action>"`. See the
    // commands section in docs/PLUGINS.md.
};

pub fn commandId(comptime plugin_id: []const u8, comptime action: []const u8) [:0]const u8 {
    return plugin_id ++ "." ++ action;
}

/// Comptime check that a vtable implements the document cluster required for an editor plugin.
pub fn assertEditorVTable(comptime vt: VTable) void {
    comptime {
        if (vt.loadDocument == null) @compileError("Editor vtable missing required hook: loadDocument");
        if (vt.documentStackSize == null) @compileError("Editor vtable missing required hook: documentStackSize");
        if (vt.documentStackAlign == null) @compileError("Editor vtable missing required hook: documentStackAlign");
        if (vt.registerOpenDocument == null) @compileError("Editor vtable missing required hook: registerOpenDocument");
        if (vt.drawDocument == null) @compileError("Editor vtable missing required hook: drawDocument");
        if (vt.documentPtr == null) @compileError("Editor vtable missing required hook: documentPtr");
        if (vt.isDirty == null) @compileError("Editor vtable missing required hook: isDirty");
        if (vt.saveDocument == null) @compileError("Editor vtable missing required hook: saveDocument");
        if (vt.closeDocument == null) @compileError("Editor vtable missing required hook: closeDocument");
    }
}

/// Comptime check that a vtable does not implement document hooks (menu-only / utility profile).
pub fn assertUtilityVTable(comptime vt: VTable) void {
    comptime {
        if (vt.loadDocument != null) @compileError("Utility vtable must not implement document hook: loadDocument");
        if (vt.drawDocument != null) @compileError("Utility vtable must not implement document hook: drawDocument");
        if (vt.registerOpenDocument != null) @compileError("Utility vtable must not implement document hook: registerOpenDocument");
        if (vt.createDocument != null) @compileError("Utility vtable must not implement document hook: createDocument");
    }
}

// Thin wrappers so callers don't repeat the optional-vtable dance.

pub fn fileTypes(self: Plugin) []const []const u8 {
    return if (self.vtable.fileTypes) |f| f(self.state) else &.{};
}

pub fn contributeKeybinds(self: Plugin, win: *dvui.Window) !void {
    if (self.vtable.contributeKeybinds) |f| try f(self.state, win);
}

pub fn tickKeybinds(self: Plugin) !void {
    if (self.vtable.tickKeybinds) |f| try f(self.state);
}

pub fn drawOverlay(self: Plugin) !void {
    if (self.vtable.drawOverlay) |f| try f(self.state);
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

pub fn onFolderClose(self: Plugin) void {
    if (self.vtable.onFolderClose) |f| f(self.state);
}

pub fn onFolderOpen(self: Plugin, allocator: std.mem.Allocator) void {
    if (self.vtable.onFolderOpen) |f| f(self.state, allocator);
}

pub fn documentContentChanged(self: Plugin, path: []const u8, bytes: []const u8) void {
    if (self.vtable.documentContentChanged) |f| f(self.state, path, bytes);
}

pub fn folderPathsChanged(self: Plugin, changes: PathChanges) void {
    if (self.vtable.folderPathsChanged) |f| f(self.state, changes);
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

pub fn revealPosition(self: Plugin, doc: DocHandle, line: u32, character: u32) void {
    if (self.vtable.revealPosition) |f| f(self.state, doc, line, character);
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

pub fn saveNeedsConfirmation(self: Plugin, doc: DocHandle) bool {
    return if (self.vtable.saveNeedsConfirmation) |f| f(self.state, doc) else false;
}

pub fn saveDocumentAsync(self: Plugin, doc: DocHandle) !void {
    if (self.vtable.saveDocumentAsync) |f| try f(self.state, doc);
}

pub fn timeSinceSaveCompleteNs(self: Plugin, doc: DocHandle) ?i128 {
    return if (self.vtable.timeSinceSaveCompleteNs) |f| f(self.state, doc) else null;
}

// ---- document lifecycle wrappers (operate on a DocHandle this plugin owns) ----

/// Load `path` into fizzy-owned buffer at `out_doc`. Returns whether the plugin
/// handled it; `false` means this plugin exposes no loader (fizzy should treat the
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

/// Reload from disk. Returns whether the plugin handled it (`false` = no hook).
pub fn reloadDocument(self: Plugin, doc: DocHandle) bool {
    if (self.vtable.reloadDocument) |f| {
        f(self.state, doc) catch |err| {
            std.log.err("reloadDocument failed: {s}", .{@errorName(err)});
            return false;
        };
        return true;
    }
    return false;
}

/// Tear down an open document. Returns whether the plugin handled it, so fizzy
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

pub fn infobarEntries(self: Plugin, active_doc: ?DocHandle) []const infobar.Entry {
    return if (self.vtable.infobarEntries) |f| f(self.state, active_doc) else &.{};
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

pub fn requestSaveConfirmation(self: Plugin, doc: DocHandle, mode: SaveConfirmMode, from_save_all_quit: bool) void {
    if (self.vtable.requestSaveConfirmation) |f| f(self.state, doc, mode, from_save_all_quit);
}

pub fn settingsChanged(self: Plugin, blob: []const u8) void {
    if (self.vtable.settingsChanged) |f| f(self.state, blob);
}

pub fn requestNewDocumentDialog(self: Plugin, parent_path: ?[]const u8, id_extra: usize) void {
    if (self.vtable.requestNewDocumentDialog) |f| f(self.state, parent_path, id_extra);
}

pub fn beginFrame(self: Plugin) void {
    if (self.vtable.beginFrame) |f| f(self.state);
}

pub fn prepareFrame(self: Plugin) void {
    if (self.vtable.prepareFrame) |f| f(self.state);
}

pub fn endFrame(self: Plugin) void {
    if (self.vtable.endFrame) |f| f(self.state);
}

pub fn tickOpenDocuments(self: Plugin) bool {
    return if (self.vtable.tickOpenDocuments) |f| f(self.state) else false;
}

pub fn tickActiveDocument(self: Plugin, timer_host_id: dvui.Id) void {
    if (self.vtable.tickActiveDocument) |f| f(self.state, timer_host_id);
}

pub fn needsContinuousRepaint(self: Plugin) bool {
    return if (self.vtable.needsContinuousRepaint) |f| f(self.state) else false;
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
