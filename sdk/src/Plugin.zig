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
const core = @import("core");
const DocHandle = @import("DocHandle.zig");
const EditorAPI = @import("EditorAPI.zig");
const infobar = @import("infobar.zig");

pub const Plugin = @This();

/// Opaque, plugin-owned state passed back to every vtable call.
state: *anyopaque,
vtable: *const VTable,

/// Stable, unique identifier (snake_case), e.g. "pixi", "workbench".
id: []const u8,
/// User-facing name shown in UI.
display_name: []const u8,

/// Fizzy's own, not something a user installed. Kept out of the plugin store's lists and out
/// of anything else that offers to enable, update or remove a plugin, because none of those
/// verbs mean anything for it: it is part of the binary.
///
/// The app registers a few of these so its own things can use the plugin machinery — the store
/// page owner is a document owner, which *is* a plugin as far as document routing is concerned.
/// A flag rather than an id
/// convention: "starts with fizzy." is a rule nothing enforces and an app built on fizzy would
/// not share.
internal: bool = false,

/// The encoding of the steps this plugin records and applies (`Step`, `VTable.applyStep`), which
/// it numbers: bumped when a step it writes would be misread by the build before. A tape names it
/// beside each file (`Tape.File.format`), and an app plays only the steps of formats the owner
/// reads. 0: records no steps.
step_format: u32 = 0,

/// Names an error this plugin returned. Zig numbers errors per compilation, so `@errorName` in
/// the host on a dylib's error reads the host's table and prints an unrelated name. The default
/// is evaluated in the binary that builds this struct — the plugin's own — so it reads the
/// plugin's table. Leave it alone; call `errorName`.
error_name: *const fn (code: ErrorInt) [:0]const u8 = &localErrorName,

pub const ErrorInt = @Int(.unsigned, @bitSizeOf(anyerror));

/// `@errorName` in whichever binary this is compiled into.
pub fn localErrorName(code: ErrorInt) [:0]const u8 {
    return @errorName(@errorFromInt(code));
}

/// The name of `err`, which this plugin returned.
pub fn errorName(self: Plugin, err: anyerror) [:0]const u8 {
    return self.error_name(@intFromError(err));
}

/// The name of `err`, returned by a contribution `owner` registered, or by fizzy itself when it
/// has none.
pub fn errorNameOf(owner: ?*const Plugin, err: anyerror) [:0]const u8 {
    return if (owner) |o| o.errorName(err) else @errorName(err);
}

/// A call into this plugin failed: say why, by the plugin's own name for it, and hand the caller
/// an error that means the same thing in the caller's binary.
pub fn failed(self: Plugin, what: []const u8, err: anyerror) error{PluginFailed} {
    std.log.err("{s}: {s} failed: {s}", .{ self.id, what, self.errorName(err) });
    return error.PluginFailed;
}

/// A document's history as a line (`historyLine`): each step it can undo, oldest first, then
/// each it can redo, and how many are applied. The app draws it as a timeline the person scrubs.
pub const HistoryLine = struct {
    /// Changes whenever the line does — a step added, undone or redone — so a caller keeps the
    /// last line and asks again only when this moved.
    version: u64,
    entries: []const Entry,
    /// How many of `entries` are applied; the rest are what redo brings back.
    at: usize,

    pub const Entry = struct {
        /// The step's own, for its life: the app goes to a step, and keys who made it, by this.
        /// Never 0.
        id: u64,
        /// What it did, short: "Typing", "Draw", "Add Layer".
        title: []const u8,
    };
};

/// A document's history to put back (`restoreHistory`), as its track recorded it: each entry on
/// it, oldest first, and how many are applied, the rest being what redo brings back. The document
/// already stands where they leave it (applied, every entry up to `applied` is in it).
pub const RestoredHistory = struct {
    entries: []const Entry,
    /// How many of `entries` are applied.
    applied: usize,

    pub const Entry = struct {
        /// The entry's own id (`Step.id`, `HistoryLine.Entry.id`), kept: steps reported after
        /// the restore name it by this.
        id: u64,
        /// What the entry did, in the owner's `step_format`, as it reported it: the `effect` of
        /// its `added` step, then each `joined` part after it.
        parts: []const []const u8,
    };
};

/// A question an owner wants asked before fizzy saves a document (`saveQuestion`): a save that
/// would flatten layers, drop data, change an encoding. fizzy asks it wherever a save starts
/// (Save, Save All, Save and Close, the quit walk) and goes on by itself with the answer.
pub const SaveQuestion = struct {
    title: []const u8,
    message: []const u8,
    /// The button that saves as asked ("Save Flattened").
    proceed: []const u8,
    /// An offer to save in another format instead, as Save As with the name kept and this
    /// extension (".pixi"), and its button. Empty `extension`: not offered.
    instead_extension: []const u8 = "",
    instead: []const u8 = "",
};

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
//
// **Document verbs are commands, not hooks.** An owner registers `<id>.<action>` (with
// `isEnabled`) and fizzy routes its own Copy, Paste, Undo, Redo, Delete, … to the active
// document's owner: `copy`, `paste`, `undo`, `redo`, `deleteSelection` (see fizzy's
// `Keybinds.document_verbs`). Revealing a position (go to definition, a backlink) calls
// `<id>.goToLine` with `.{ .path, .line, .column }`, counted from 1. A plugin offers New File
// entries with `<id>.new`, or `<id>.new.<kind>` once per kind of thing it makes (the command's
// title and icon are the entry's), taking `.{ .parent_path = "" }`: the folder to create in, or
// empty for an untitled document.
//
// **An `anyerror` here never reaches the caller as itself.** Zig numbers error values per
// compilation, so the integer a plugin returns means something else in the host's own error set
// — `@errorName` on it prints an unrelated name, and comparing it to `error.Something` is
// meaningless. So the wrappers below never hand one on: they log it by the plugin's own name
// (`error_name`) and return `error.PluginFailed`, and `EditorAPI`'s do the same the other way
// with `error.HostFailed`. Anything else that calls a plugin's function pointer directly names
// its error with `errorNameOf(owner, err)`, never `@errorName`.
pub const VTable = struct {
    /// Tear down `state`. Called when the plugin is unregistered / app shuts down.
    deinit: ?*const fn (state: *anyopaque) void = null,
    /// One-time plugin setup (e.g. background worker threads). Runs after the host has
    /// injected its dvui globals into the plugin's image — unlike `register`, where in a dylib
    /// `dvui.io` / `dvui.currentWindow()` are not yet valid. Anything that captures them
    /// (a transport, a worker) belongs here.
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
    loadDocumentFromBytes: ?*const fn (
        state: *anyopaque,
        path: []const u8,
        bytes: []const u8,
        out_doc: *anyopaque,
    ) anyerror!void = null,
    /// Open `bytes` as an untitled document named `title` (`untitled-1`), as `createDocument`
    /// would have made it with these contents: never saved, and dirty. `bytes` are what
    /// `documentBytes` encoded for it under `bytes_path` (`bytesPath`: the name Save As offers,
    /// `untitled.pixi`), which says their format. How a crash or a restart brings back a document
    /// that was never saved; without it, one comes back only as far as its state restores
    /// into an empty document. Synchronous.
    loadUntitledDocument: ?*const fn (
        state: *anyopaque,
        title: []const u8,
        bytes_path: []const u8,
        bytes: []const u8,
        out_doc: *anyopaque,
    ) anyerror!void = null,
    /// Size of the plugin's document type for stack/heap staging buffers (`loadDocument`, etc.).
    documentStackSize: ?*const fn (state: *anyopaque) usize = null,
    documentStackAlign: ?*const fn (state: *anyopaque) usize = null,
    documentIdFromBuffer: ?*const fn (state: *anyopaque, doc: *anyopaque) u64 = null,
    deinitDocumentBuffer: ?*const fn (state: *anyopaque, doc: *anyopaque) void = null,
    setDocumentGroupingOnBuffer: ?*const fn (state: *anyopaque, doc: *anyopaque, grouping: u64) void = null,
    createDocument: ?*const fn (
        state: *anyopaque,
        path: []const u8,
        grid: EditorAPI.NewDocGrid,
        out_doc: *anyopaque,
    ) anyerror!void = null,
    saveDocument: ?*const fn (state: *anyopaque, doc: DocHandle) anyerror!void = null,
    /// Saving, in two halves, so the UI thread does only the first
    /// (plans/PLUGIN_INTERACTION_PLAN.md, "Every save is a snapshot then an encode"). fizzy writes
    /// the bytes wherever the document lives (the disk, a mounted drive, a zip, the browser's
    /// download), so an owner never knows what a `gdrive://` path is. `saveDocument` stays the
    /// disk-only path for an owner that writes its files itself.
    ///
    /// On the UI thread, as a save of `doc` to `path` starts: take what the save needs and nothing
    /// more (a text buffer's copy, a canvas's layers, a composite read back from the GPU), quickly:
    /// the person is waiting on this frame. Remember which edit it stands for, so
    /// `documentWritten` cleans the document up to that edit and not past it. `path` is where it
    /// is going: a Save As may change the format. Owned by the plugin until `releaseSnapshot`.
    documentSnapshot: ?*const fn (
        state: *anyopaque,
        doc: DocHandle,
        path: []const u8,
        allocator: std.mem.Allocator,
    ) anyerror!*anyopaque = null,
    /// On a fizzy worker thread: `snapshot` encoded as `path`'s format (its extension says which).
    /// Touches nothing but the snapshot: no dvui, no GPU, no document, no plugin state another
    /// thread changes. The bytes are allocated with `allocator` and owned by the caller.
    encodeSnapshot: ?*const fn (
        state: *anyopaque,
        snapshot: *anyopaque,
        path: []const u8,
        allocator: std.mem.Allocator,
    ) anyerror![]u8 = null,
    /// On the UI thread, once the encode is done or the save abandoned: free a snapshot.
    releaseSnapshot: ?*const fn (state: *anyopaque, snapshot: *anyopaque) void = null,
    /// fizzy wrote a snapshot's bytes to `path`. Clean the document up to the edit that snapshot
    /// stood for, as `saveDocument` would; when `path` differs from the document's own, adopt it
    /// (Save As).
    documentWritten: ?*const fn (state: *anyopaque, doc: DocHandle, path: []const u8) anyerror!void = null,
    /// On the UI thread: `doc` as it stands, encoded as `path`'s format, the bytes a save would
    /// write, for a copy that is not a save. fizzy takes these for a crash checkpoint (every few
    /// seconds while someone types), for a restart or a plugin reload carrying unsaved work, for a
    /// tape's file, and for a `fizzy.document.changed` listener. So none of a save's bookkeeping
    /// or side effects: no format on save, no edit remembered for `documentWritten`, no undo stop,
    /// nothing the person sees change. Owned by the caller, allocated with `allocator`. Absent =
    /// fizzy takes the save's two halves instead (`documentSnapshot` + `encodeSnapshot`), and
    /// whatever those do to the document happens on every checkpoint too.
    documentBytes: ?*const fn (
        state: *anyopaque,
        doc: DocHandle,
        path: []const u8,
        allocator: std.mem.Allocator,
    ) anyerror![]u8 = null,
    closeDocument: ?*const fn (state: *anyopaque, doc: DocHandle) void = null,
    /// Reload `doc` from its on-disk path, replacing in-memory contents and clearing dirty
    /// state / undo history as appropriate. Called by fizzy's document watcher when a
    /// clean open file changes externally. Absent = fizzy skips auto-reload for this
    /// owner (dirty conflict detection on save still works via content hashing).
    reloadDocument: ?*const fn (state: *anyopaque, doc: DocHandle) anyerror!void = null,
    /// `doc` as it is right now — its contents, caret and selection, scroll, whatever else the
    /// owner needs to put it back exactly — as bytes only the owner reads, owned by the caller
    /// and allocated with `allocator`. Two consumers: a demo's seek snapshot (`app.automation`),
    /// and this plugin's own reload, which carries each open document, unsaved edits included,
    /// from the running build to the rebuilt one. Held in memory and never written anywhere, so
    /// the format is the owner's and may change freely, but a reload hands one build's bytes to
    /// the next: start them with a version the next build checks (`restoreDocumentState`).
    /// Absent = a demo cannot snapshot a moment with this document open, and a reload of this
    /// plugin refuses while the document has unsaved changes.
    captureDocumentState: ?*const fn (
        state: *anyopaque,
        doc: DocHandle,
        allocator: std.mem.Allocator,
    ) anyerror![]u8 = null,
    /// Put `doc` back to what `captureDocumentState` returned for it, in place: the same
    /// document in the same pane, its contents, caret and scroll as they were, dirty or clean
    /// as it was. Undo history may be dropped. `bytes` is only valid for the call, and may come
    /// from an earlier build of this plugin (a reload): fail on what this build does not read,
    /// never misread it. The app then opens the document as saved and keeps its unsaved
    /// contents in a recovery file.
    restoreDocumentState: ?*const fn (state: *anyopaque, doc: DocHandle, bytes: []const u8) anyerror!void = null,
    /// `restoreDocumentState`, as one step of `doc`'s history that undo takes back: `doc` was just
    /// opened from its file, and `bytes` are its unsaved changes coming back without the history
    /// that made them (after a crash, or a reload or restart whose history could not be kept). The
    /// step goes back to the file, so the person can always return to what is on disk, and the
    /// document is never dirty with nothing to undo. Fails as `restoreDocumentState` does, leaving
    /// `doc` as opened. Absent = the state is restored as `restoreDocumentState` does it.
    recoverDocumentState: ?*const fn (state: *anyopaque, doc: DocHandle, bytes: []const u8) anyerror!void = null,
    /// A hash of what in `doc` decides what happens next — its contents and caret, not its
    /// scroll — with no side effects. A demo compares it when a replay reaches a moment it
    /// snapshotted before, to catch a tape that does not replay exactly.
    documentFingerprint: ?*const fn (state: *anyopaque, doc: DocHandle) u64 = null,
    /// `doc`'s history as a line (`HistoryLine`): every step, oldest first, and how many are
    /// applied — the rest are what redo brings back. Its `version` changes whenever the line
    /// does, so the app asks again only then. Entries and titles in `arena`. Absent = no
    /// timeline for this owner's documents; undo and redo work as ever.
    historyLine: ?*const fn (state: *anyopaque, doc: DocHandle, arena: std.mem.Allocator) anyerror!HistoryLine = null,
    /// Undo or redo `doc` until step `id` (`HistoryLine.Entry.id`) is the last one applied; 0
    /// goes back before the first. An id not on the line is an error, and nothing moves.
    /// `fizzy.undo`/`fizzy.redo` with a `path` or an `expect` go through it too, so a document
    /// can be undone without being the active one. `error.PersonBusy` refuses while the person has
    /// a gesture open (a stroke under their hand) and someone else is acting: the caller is told
    /// to try again once it ends.
    historyGoTo: ?*const fn (state: *anyopaque, doc: DocHandle, id: u64) anyerror!void = null,
    /// Apply a step this owner recorded (`Step`, `Host.recordStep`) to `doc`, forward, as a new
    /// entry on its history: `effect` and `motion` in the owner's `step_format`. `ms` asks for it
    /// to be shown being made over that long (a replay at pace); 0 lands it at once (a seek). A
    /// step that does not fit what `doc` holds is an error, and `doc` is left as it was. Absent =
    /// tapes of this owner's documents cannot be played.
    applyStep: ?*const fn (
        state: *anyopaque,
        doc: DocHandle,
        effect: []const u8,
        motion: []const u8,
        ms: u32,
    ) anyerror!void = null,
    /// Put `doc`'s history back as its track recorded it (`RestoredHistory`), in place of what it
    /// holds: a document opened again picks up the history it had. `doc` already stands where
    /// the history leaves it; nothing in it changes, and it is not dirty for it. Each entry keeps
    /// its id. A history that does not fit `doc` (an effect of another format, or one that does
    /// not undo to a document) is an error, and `doc`'s history is left as it was. Absent = a
    /// document of this owner opens with no history, as ever.
    restoreHistory: ?*const fn (state: *anyopaque, doc: DocHandle, history: RestoredHistory) anyerror!void = null,
    isDirty: ?*const fn (state: *anyopaque, doc: DocHandle) bool = null,

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

    /// Bind a document to a workbench pane before `drawDocument` (canvas id, workspace handle,
    /// center flag).
    bindDocumentToPane: ?*const fn (
        state: *anyopaque,
        doc: DocHandle,
        canvas_id: dvui.Id,
        workspace_handle: *anyopaque,
        center: bool,
    ) void = null,
    documentGrouping: ?*const fn (state: *anyopaque, doc: DocHandle) u64 = null,
    setDocumentGrouping: ?*const fn (state: *anyopaque, doc: DocHandle, grouping: u64) void = null,
    documentPath: ?*const fn (state: *anyopaque, doc: DocHandle) []const u8 = null,
    setDocumentPath: ?*const fn (state: *anyopaque, doc: DocHandle, path: []const u8) anyerror!void = null,
    documentHasNativeExtension: ?*const fn (state: *anyopaque, doc: DocHandle) bool = null,
    /// True when `saveDocument` can write the document without Save As (e.g. `.fiz` or flat image).
    documentHasRecognizedSaveExtension: ?*const fn (state: *anyopaque, doc: DocHandle) bool = null,
    documentDefaultSaveAsFilename: ?*const fn (
        state: *anyopaque,
        doc: DocHandle,
        allocator: std.mem.Allocator,
    ) anyerror![]const u8 = null,
    // ---- render hooks (the plugin draws its own dvui UI into the host window) ----
    // Sidebar/explorer panes and bottom-panel tabs are NOT vtable hooks — plugins
    // contribute them as named, owned `Surface`s via `Host.registerSurface`, and the app's
    // layout matches them to a region by keyword, rendering a tab strip when more than one
    // lands in the same place. Only per-document rendering routes through the vtable below.
    /// Draw an open document (center/workspace region), dispatched via `DocHandle.owner`.
    drawDocument: ?*const fn (state: *anyopaque, doc: DocHandle) anyerror!void = null,

    /// What this document's tab says, or null to use the file name.
    ///
    /// For a document whose path is an address rather than a name: a store page lives at
    /// `store://pages/<plugin id>.fizzyplugin`, because a path has to be stable enough to
    /// reopen from a saved layout, and its tab should still read "Google Drive". Or for one whose
    /// name is not its path: a chat reads as its first question.
    ///
    /// Asked when the document's tab is made, and again whenever the owner calls
    /// `Host.documentTitleChanged`; the Host keeps a copy, so the slice need only last the call.
    documentTitle: ?*const fn (state: *anyopaque, doc: DocHandle) ?[]const u8 = null,

    /// The context menu to open on a right-click inside this document, or null for none.
    ///
    /// Null is the default, and the default is *no menu*: a right-click belongs to whoever
    /// drew what is under it. Pixi uses it for the colour dropper, and a menu appearing over
    /// the canvas would be a bug rather than a feature. A plugin that wants one — the text
    /// editor, with cut/copy/paste — returns its own menu id and registers sections into it
    /// with `Host.registerMenuSection`, the same call every other menu is extended through.
    documentContextMenu: ?*const fn (state: *anyopaque, doc: DocHandle) ?[]const u8 = null,
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

    // ---- save protocol ----
    /// A question to ask before fizzy saves `doc` to `path` (`SaveQuestion`), or null to save
    /// straight away. Strings in `allocator` (the frame's arena), copied by fizzy. fizzy asks it,
    /// shows the saving and its end, and once the person has said to go ahead it does not ask
    /// again while the document stays open. The owner never drives a save itself.
    saveQuestion: ?*const fn (
        state: *anyopaque,
        doc: DocHandle,
        path: []const u8,
        allocator: std.mem.Allocator,
    ) ?SaveQuestion = null,

    // ---- settings ----
    /// [requested] This plugin's persisted settings blob changed while the plugin is loaded —
    /// `blob` is the whole, freshly-serialized zon text (same shape `Host.loadPluginSettings`
    /// returns), not a diff. Fires from **two** sources, and a plugin implementing this should
    /// not assume which one: (1) fizzy's settings pane edited it in-app (see
    /// `Host.storePluginSettings`), or (2) an external edit to `settings.zon` (hand edit, another
    /// tool) was picked up live by the settings watcher and reconciled (see R11 in
    /// plans/PLUGIN_MANIFEST_PLAN.md) — in that case this fires with no settings-pane interaction
    /// having happened at all. A plugin that keeps its own in-memory copy of settings (e.g. to
    /// avoid re-parsing zon every draw) should re-parse and apply it here instead of only reading
    /// the blob once at `register`. Absent = the plugin only ever reads its settings at
    /// `register`/`initPlugin`.
    settingsChanged: ?*const fn (state: *anyopaque, blob: []const u8) void = null,

    // NOTE: editing actions (copy / paste / transform / accept-edit / cancel-edit /
    // delete-selection) are deliberately NOT hooks here. They are user-invoked and their meaning
    // varies per editor, so a plugin registers them as `Command`s (e.g. `"pixi.copy"`) and
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
        // Required rather than optional because omitting it *loses information silently*: the app
        // writes the target grouping onto the staging buffer before the load lands, so a plugin
        // without this hook opens every document in the pane the user was already in and "Open to
        // the side" appears to do nothing. The image plugin shipped that way, and nothing —
        // not a log line, not a failed load — said so.
        if (vt.setDocumentGroupingOnBuffer == null)
            @compileError("Editor vtable missing required hook: setDocumentGroupingOnBuffer " ++
                "(a document that ignores its grouping cannot be opened to the side)");
        if (vt.documentGrouping == null) @compileError("Editor vtable missing required hook: documentGrouping");
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
        if (vt.registerOpenDocument != null)
            @compileError("Utility vtable must not implement document hook: registerOpenDocument");
        if (vt.createDocument != null) @compileError("Utility vtable must not implement document hook: createDocument");
    }
}

// Thin wrappers so callers don't repeat the optional-vtable dance.

pub fn fileTypes(self: Plugin) []const []const u8 {
    const prof = core.profile.begin(self.id, "fileTypes");
    defer prof.end();
    return if (self.vtable.fileTypes) |f| f(self.state) else &.{};
}

pub fn contributeKeybinds(self: Plugin, win: *dvui.Window) !void {
    const prof = core.profile.begin(self.id, "contributeKeybinds");
    defer prof.end();
    if (self.vtable.contributeKeybinds) |f| f(self.state, win) catch |err|
        return self.failed("contributeKeybinds", err);
}

pub fn tickKeybinds(self: Plugin) !void {
    const prof = core.profile.begin(self.id, "tickKeybinds");
    defer prof.end();
    if (self.vtable.tickKeybinds) |f| f(self.state) catch |err| return self.failed("tickKeybinds", err);
}

pub fn drawOverlay(self: Plugin) !void {
    const prof = core.profile.begin(self.id, "drawOverlay");
    defer prof.end();
    if (self.vtable.drawOverlay) |f| f(self.state) catch |err| return self.failed("drawOverlay", err);
}

pub fn registerOpenDocument(self: Plugin, file: *anyopaque) !*anyopaque {
    const prof = core.profile.begin(self.id, "registerOpenDocument");
    defer prof.end();
    return if (self.vtable.registerOpenDocument) |f| (f(self.state, file) catch |err|
        return self.failed("registerOpenDocument", err)) else error.Unsupported;
}

pub fn documentPtr(self: Plugin, id: u64) ?*anyopaque {
    const prof = core.profile.begin(self.id, "documentPtr");
    defer prof.end();
    return if (self.vtable.documentPtr) |f| f(self.state, id) else null;
}

pub fn documentByPath(self: Plugin, path: []const u8) ?*anyopaque {
    const prof = core.profile.begin(self.id, "documentByPath");
    defer prof.end();
    return if (self.vtable.documentByPath) |f| f(self.state, path) else null;
}

pub fn unregisterDocument(self: Plugin, id: u64) void {
    const prof = core.profile.begin(self.id, "unregisterDocument");
    defer prof.end();
    if (self.vtable.unregisterDocument) |f| f(self.state, id);
}

pub fn bindDocumentToPane(
    self: Plugin,
    doc: DocHandle,
    canvas_id: dvui.Id,
    workspace_handle: *anyopaque,
    center: bool,
) void {
    const prof = core.profile.begin(self.id, "bindDocumentToPane");
    defer prof.end();
    if (self.vtable.bindDocumentToPane) |f| f(self.state, doc, canvas_id, workspace_handle, center);
}

pub fn documentGrouping(self: Plugin, doc: DocHandle) u64 {
    const prof = core.profile.begin(self.id, "documentGrouping");
    defer prof.end();
    return if (self.vtable.documentGrouping) |f| f(self.state, doc) else 0;
}

pub fn setDocumentGrouping(self: Plugin, doc: DocHandle, grouping: u64) void {
    const prof = core.profile.begin(self.id, "setDocumentGrouping");
    defer prof.end();
    if (self.vtable.setDocumentGrouping) |f| f(self.state, doc, grouping);
}

pub fn documentPath(self: Plugin, doc: DocHandle) []const u8 {
    const prof = core.profile.begin(self.id, "documentPath");
    defer prof.end();
    return if (self.vtable.documentPath) |f| f(self.state, doc) else "";
}

pub fn setDocumentPath(self: Plugin, doc: DocHandle, path: []const u8) !void {
    const prof = core.profile.begin(self.id, "setDocumentPath");
    defer prof.end();
    if (self.vtable.setDocumentPath) |f| f(self.state, doc, path) catch |err|
        return self.failed("setDocumentPath", err);
}

pub fn documentHasNativeExtension(self: Plugin, doc: DocHandle) bool {
    const prof = core.profile.begin(self.id, "documentHasNativeExtension");
    defer prof.end();
    return if (self.vtable.documentHasNativeExtension) |f| f(self.state, doc) else false;
}

pub fn documentHasRecognizedSaveExtension(self: Plugin, doc: DocHandle) bool {
    const prof = core.profile.begin(self.id, "documentHasRecognizedSaveExtension");
    defer prof.end();
    return if (self.vtable.documentHasRecognizedSaveExtension) |f| f(self.state, doc) else false;
}

// ---- document lifecycle wrappers (operate on a DocHandle this plugin owns) ----

/// Load `path` into fizzy-owned buffer at `out_doc`. Returns whether the plugin
/// handled it; `false` means this plugin exposes no loader (fizzy should treat the
/// open as failed). See the `loadDocument` vtable field for the threading contract.
pub fn loadDocument(self: Plugin, path: []const u8, out_doc: *anyopaque) !bool {
    const prof = core.profile.begin(self.id, "loadDocument");
    defer prof.end();
    if (self.vtable.loadDocument) |f| {
        f(self.state, path, out_doc) catch |err| return self.failed("loadDocument", err);
        return true;
    }
    return false;
}

/// `loadDocument`, but from in-memory `bytes` (browser file picker).
pub fn loadDocumentFromBytes(self: Plugin, path: []const u8, bytes: []const u8, out_doc: *anyopaque) !bool {
    const prof = core.profile.begin(self.id, "loadDocumentFromBytes");
    defer prof.end();
    if (self.vtable.loadDocumentFromBytes) |f| {
        f(self.state, path, bytes, out_doc) catch |err| return self.failed("loadDocumentFromBytes", err);
        return true;
    }
    return false;
}

/// `loadUntitledDocument`. Returns whether the plugin handled it (`false` = no hook).
pub fn loadUntitledDocument(
    self: Plugin,
    title: []const u8,
    bytes_path: []const u8,
    bytes: []const u8,
    out_doc: *anyopaque,
) !bool {
    const prof = core.profile.begin(self.id, "loadUntitledDocument");
    defer prof.end();
    if (self.vtable.loadUntitledDocument) |f| {
        f(self.state, title, bytes_path, bytes, out_doc) catch |err| return self.failed("loadUntitledDocument", err);
        return true;
    }
    return false;
}

pub fn isDirty(self: Plugin, doc: DocHandle) bool {
    const prof = core.profile.begin(self.id, "isDirty");
    defer prof.end();
    return if (self.vtable.isDirty) |f| f(self.state, doc) else false;
}

pub fn saveDocument(self: Plugin, doc: DocHandle) !void {
    const prof = core.profile.begin(self.id, "saveDocument");
    defer prof.end();
    if (self.vtable.saveDocument) |f| f(self.state, doc) catch |err| return self.failed("saveDocument", err);
}

/// The first half of a save, on the UI thread. Null when the owner has no storage-agnostic save,
/// in which case fizzy cannot write it anywhere but the disk (`saveDocument`).
pub fn documentSnapshot(self: Plugin, doc: DocHandle, path: []const u8, allocator: std.mem.Allocator) !?*anyopaque {
    if (!self.canSaveThroughHost()) return null;
    const prof = core.profile.begin(self.id, "documentSnapshot");
    defer prof.end();
    return self.vtable.documentSnapshot.?(self.state, doc, path, allocator) catch |err|
        self.failed("documentSnapshot", err);
}

/// The second half, on a worker. No profiler scope and no logging here: neither is the worker's
/// to touch. The caller reports a failure from the UI thread.
pub fn encodeSnapshot(
    self: Plugin,
    snapshot: *anyopaque,
    path: []const u8,
    allocator: std.mem.Allocator,
) anyerror![]u8 {
    return self.vtable.encodeSnapshot.?(self.state, snapshot, path, allocator);
}

pub fn releaseSnapshot(self: Plugin, snapshot: *anyopaque) void {
    if (self.vtable.releaseSnapshot) |f| f(self.state, snapshot);
}

/// The path `doc`'s bytes are encoded under (`documentBytes`), owned by `allocator`: its own, or
/// for one never saved (`untitled-1`, which names no format), the name Save As offers
/// (`untitled.pixi`), so the bytes are what a save would write.
pub fn bytesPath(self: Plugin, doc: DocHandle, allocator: std.mem.Allocator) ![]const u8 {
    if (!self.documentHasRecognizedSaveExtension(doc)) {
        if (self.documentDefaultSaveAsFilename(doc, allocator)) |name| return name else |_| {}
    }
    return allocator.dupe(u8, self.documentPath(doc));
}

/// `doc`'s bytes as a save to `path` would write them, now, for a copy that is not a save (a crash
/// recovery file, a restart's kept documents, a tape's file): the owner's `documentBytes`, which
/// leaves the document as it was. An owner without it gives the two halves of a save
/// (`saveBytes`), bookkeeping included. Null when it can give neither.
pub fn documentBytes(self: Plugin, doc: DocHandle, path: []const u8, allocator: std.mem.Allocator) !?[]u8 {
    if (self.vtable.documentBytes) |f| {
        const prof = core.profile.begin(self.id, "documentBytes");
        defer prof.end();
        return f(self.state, doc, path, allocator) catch |err| self.failed("documentBytes", err);
    }
    return self.saveBytes(doc, path, allocator);
}

/// Both halves of a save at once, on the calling thread, for a save that needs its bytes now (the
/// browser's download). The owner remembers the edit they stand for, as at any save's start, so
/// `documentWritten` must follow once they are written. Null as `documentSnapshot`.
pub fn saveBytes(self: Plugin, doc: DocHandle, path: []const u8, allocator: std.mem.Allocator) !?[]u8 {
    const snapshot = (try self.documentSnapshot(doc, path, allocator)) orelse return null;
    defer self.releaseSnapshot(snapshot);
    return try self.encodeSnapshot(snapshot, path, allocator);
}

pub fn documentWritten(self: Plugin, doc: DocHandle, path: []const u8) !void {
    const prof = core.profile.begin(self.id, "documentWritten");
    defer prof.end();
    if (self.vtable.documentWritten) |f| f(self.state, doc, path) catch |err|
        return self.failed("documentWritten", err);
}

pub fn canSaveThroughHost(self: Plugin) bool {
    return self.vtable.documentSnapshot != null and self.vtable.encodeSnapshot != null;
}

/// Reload from disk. Returns whether the plugin handled it (`false` = no hook).
pub fn reloadDocument(self: Plugin, doc: DocHandle) bool {
    const prof = core.profile.begin(self.id, "reloadDocument");
    defer prof.end();
    if (self.vtable.reloadDocument) |f| {
        f(self.state, doc) catch |err| {
            std.log.err("{s}: reloadDocument failed: {s}", .{ self.id, self.errorName(err) });
            return false;
        };
        return true;
    }
    return false;
}

/// `doc`'s history as a line (`historyLine`), or null when the owner keeps none it shows.
pub fn historyLine(self: Plugin, doc: DocHandle, arena: std.mem.Allocator) ?HistoryLine {
    const f = self.vtable.historyLine orelse return null;
    return f(self.state, doc, arena) catch |err| {
        std.log.err("{s}: historyLine failed: {s}", .{ self.id, self.errorName(err) });
        return null;
    };
}

/// Apply a recorded step to `doc` (`applyStep`). Returns whether it landed.
pub fn applyStep(self: Plugin, doc: DocHandle, effect: []const u8, motion: []const u8, ms: u32) bool {
    const prof = core.profile.begin(self.id, "applyStep");
    defer prof.end();
    const f = self.vtable.applyStep orelse return false;
    f(self.state, doc, effect, motion, ms) catch |err| {
        std.log.err("{s}: applyStep failed: {s}", .{ self.id, self.errorName(err) });
        return false;
    };
    return true;
}

/// Put `doc`'s history back from its track (`restoreHistory`). Returns whether it did.
pub fn restoreHistory(self: Plugin, doc: DocHandle, history: RestoredHistory) bool {
    const prof = core.profile.begin(self.id, "restoreHistory");
    defer prof.end();
    const f = self.vtable.restoreHistory orelse return false;
    f(self.state, doc, history) catch |err| {
        std.log.err("{s}: restoreHistory failed: {s}", .{ self.id, self.errorName(err) });
        return false;
    };
    return true;
}

/// Go to step `id` of `doc`'s history (`historyGoTo`). Returns whether it went.
pub fn historyGoTo(self: Plugin, doc: DocHandle, id: u64) bool {
    const why = self.historyGoToWhy(doc, id) orelse return true;
    std.log.err("{s}: historyGoTo failed: {s}", .{ self.id, why });
    return false;
}

/// `historyGoTo`, answering why it did not go (the owner's error, by name: `PersonBusy`), or null
/// when it went. Logs nothing: the caller says it.
pub fn historyGoToWhy(self: Plugin, doc: DocHandle, id: u64) ?[:0]const u8 {
    const f = self.vtable.historyGoTo orelse return "NoHistory";
    f(self.state, doc, id) catch |err| return self.errorName(err);
    return null;
}

/// `doc`'s state for a demo's snapshot (`captureDocumentState`). Null when the owner has no
/// hook or it failed — the moment is then not snapshotted.
pub fn captureDocumentState(self: Plugin, doc: DocHandle, allocator: std.mem.Allocator) ?[]u8 {
    const prof = core.profile.begin(self.id, "captureDocumentState");
    defer prof.end();
    const f = self.vtable.captureDocumentState orelse return null;
    return f(self.state, doc, allocator) catch |err| {
        std.log.err("{s}: captureDocumentState failed: {s}", .{ self.id, self.errorName(err) });
        return null;
    };
}

/// Put `doc` back as `captureDocumentState` found it. Returns whether it was.
pub fn restoreDocumentState(self: Plugin, doc: DocHandle, bytes: []const u8) bool {
    const prof = core.profile.begin(self.id, "restoreDocumentState");
    defer prof.end();
    const f = self.vtable.restoreDocumentState orelse return false;
    f(self.state, doc, bytes) catch |err| {
        std.log.err("{s}: restoreDocumentState failed: {s}", .{ self.id, self.errorName(err) });
        return false;
    };
    return true;
}

/// Bring `doc`, opened from its file, to the state `bytes` as one step undo takes back
/// (`recoverDocumentState`). False when the owner has no hook, or it failed: `doc` is as opened.
pub fn recoverDocumentState(self: Plugin, doc: DocHandle, bytes: []const u8) bool {
    const prof = core.profile.begin(self.id, "recoverDocumentState");
    defer prof.end();
    const f = self.vtable.recoverDocumentState orelse return false;
    f(self.state, doc, bytes) catch |err| {
        std.log.err("{s}: recoverDocumentState failed: {s}", .{ self.id, self.errorName(err) });
        return false;
    };
    return true;
}

/// `doc`'s `documentFingerprint`, or null when the owner has none.
pub fn documentFingerprint(self: Plugin, doc: DocHandle) ?u64 {
    const f = self.vtable.documentFingerprint orelse return null;
    return f(self.state, doc);
}

/// Tear down an open document. Returns whether the plugin handled it, so fizzy
/// can fall back to its own teardown when no plugin claims the document.
pub fn closeDocument(self: Plugin, doc: DocHandle) bool {
    const prof = core.profile.begin(self.id, "closeDocument");
    defer prof.end();
    if (self.vtable.closeDocument) |f| {
        f(self.state, doc);
        return true;
    }
    return false;
}

// ---- render hook wrappers ----

/// Draw an open document into the current dvui parent (the workbench sets up the
/// container, then routes here). Returns whether the plugin drew anything.
/// What `doc`'s tab says, or null for the file name.
pub fn documentTitle(self: Plugin, doc: DocHandle) ?[]const u8 {
    const prof = core.profile.begin(self.id, "documentTitle");
    defer prof.end();
    const f = self.vtable.documentTitle orelse return null;
    return f(self.state, doc);
}

/// The menu id for a right-click inside `doc`, or null when this plugin keeps its right-click.
pub fn documentContextMenu(self: Plugin, doc: DocHandle) ?[]const u8 {
    const prof = core.profile.begin(self.id, "documentContextMenu");
    defer prof.end();
    const f = self.vtable.documentContextMenu orelse return null;
    return f(self.state, doc);
}

pub fn drawDocument(self: Plugin, doc: DocHandle) !bool {
    const prof = core.profile.begin(self.id, "drawDocument");
    defer prof.end();
    if (self.vtable.drawDocument) |f| {
        f(self.state, doc) catch |err| return self.failed("drawDocument", err);
        return true;
    }
    return false;
}

pub fn infobarEntries(self: Plugin, active_doc: ?DocHandle) []const infobar.Entry {
    const prof = core.profile.begin(self.id, "infobarEntries");
    defer prof.end();
    return if (self.vtable.infobarEntries) |f| f(self.state, active_doc) else &.{};
}

pub fn deinit(self: Plugin) void {
    const prof = core.profile.begin(self.id, "deinit");
    defer prof.end();
    if (self.vtable.deinit) |f| f(self.state);
}

pub fn initPlugin(self: Plugin) !void {
    const prof = core.profile.begin(self.id, "initPlugin");
    defer prof.end();
    if (self.vtable.initPlugin) |f| f(self.state) catch |err| return self.failed("initPlugin", err);
}

pub fn documentStackSize(self: Plugin) usize {
    const prof = core.profile.begin(self.id, "documentStackSize");
    defer prof.end();
    return if (self.vtable.documentStackSize) |f| f(self.state) else 0;
}

pub fn documentStackAlign(self: Plugin) usize {
    const prof = core.profile.begin(self.id, "documentStackAlign");
    defer prof.end();
    return if (self.vtable.documentStackAlign) |f| f(self.state) else 1;
}

pub fn documentIdFromBuffer(self: Plugin, doc: *anyopaque) u64 {
    const prof = core.profile.begin(self.id, "documentIdFromBuffer");
    defer prof.end();
    return if (self.vtable.documentIdFromBuffer) |f| f(self.state, doc) else 0;
}

pub fn deinitDocumentBuffer(self: Plugin, doc: *anyopaque) void {
    const prof = core.profile.begin(self.id, "deinitDocumentBuffer");
    defer prof.end();
    if (self.vtable.deinitDocumentBuffer) |f| f(self.state, doc);
}

pub fn setDocumentGroupingOnBuffer(self: Plugin, doc: *anyopaque, grouping: u64) void {
    const prof = core.profile.begin(self.id, "setDocumentGroupingOnBuffer");
    defer prof.end();
    if (self.vtable.setDocumentGroupingOnBuffer) |f| f(self.state, doc, grouping);
}

pub fn createDocument(self: Plugin, path: []const u8, grid: EditorAPI.NewDocGrid, out_doc: *anyopaque) !void {
    const prof = core.profile.begin(self.id, "createDocument");
    defer prof.end();
    if (self.vtable.createDocument) |f| (f(self.state, path, grid, out_doc) catch |err|
        return self.failed("createDocument", err)) else return error.Unsupported;
}

pub fn documentDefaultSaveAsFilename(self: Plugin, doc: DocHandle, allocator: std.mem.Allocator) ![]const u8 {
    const prof = core.profile.begin(self.id, "documentDefaultSaveAsFilename");
    defer prof.end();
    return if (self.vtable.documentDefaultSaveAsFilename) |f| (f(self.state, doc, allocator) catch |err|
        return self.failed("documentDefaultSaveAsFilename", err)) else error.Unsupported;
}

pub fn saveQuestion(self: Plugin, doc: DocHandle, path: []const u8, allocator: std.mem.Allocator) ?SaveQuestion {
    const prof = core.profile.begin(self.id, "saveQuestion");
    defer prof.end();
    const f = self.vtable.saveQuestion orelse return null;
    return f(self.state, doc, path, allocator);
}

pub fn settingsChanged(self: Plugin, blob: []const u8) void {
    const prof = core.profile.begin(self.id, "settingsChanged");
    defer prof.end();
    if (self.vtable.settingsChanged) |f| f(self.state, blob);
}

pub fn beginFrame(self: Plugin) void {
    const prof = core.profile.begin(self.id, "beginFrame");
    defer prof.end();
    if (self.vtable.beginFrame) |f| f(self.state);
}

pub fn prepareFrame(self: Plugin) void {
    const prof = core.profile.begin(self.id, "prepareFrame");
    defer prof.end();
    if (self.vtable.prepareFrame) |f| f(self.state);
}

pub fn endFrame(self: Plugin) void {
    const prof = core.profile.begin(self.id, "endFrame");
    defer prof.end();
    if (self.vtable.endFrame) |f| f(self.state);
}

pub fn tickOpenDocuments(self: Plugin) bool {
    const prof = core.profile.begin(self.id, "tickOpenDocuments");
    defer prof.end();
    return if (self.vtable.tickOpenDocuments) |f| f(self.state) else false;
}

pub fn tickActiveDocument(self: Plugin, timer_host_id: dvui.Id) void {
    const prof = core.profile.begin(self.id, "tickActiveDocument");
    defer prof.end();
    if (self.vtable.tickActiveDocument) |f| f(self.state, timer_host_id);
}

pub fn needsContinuousRepaint(self: Plugin) bool {
    const prof = core.profile.begin(self.id, "needsContinuousRepaint");
    defer prof.end();
    return if (self.vtable.needsContinuousRepaint) |f| f(self.state) else false;
}

/// Allocate a buffer suitable for staging `loadDocument` / `createDocument`. Caller frees
/// `backing`.
pub fn allocDocumentBuffer(self: Plugin, allocator: std.mem.Allocator) !struct { backing: []u8, buf: []u8 } {
    const size = self.documentStackSize();
    const align_req = self.documentStackAlign();
    if (size == 0 or align_req == 0) return error.Unsupported;
    const pad = align_req - 1;
    const backing = try allocator.alloc(u8, size + pad);
    const offset = std.mem.alignForward(usize, @intFromPtr(backing.ptr), align_req) - @intFromPtr(backing.ptr);
    return .{ .backing = backing, .buf = backing[offset..][0..size] };
}
