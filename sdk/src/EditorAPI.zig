//! Fizzy's own read/utility surface, reached by a plugin through the `Host`.
//!
//! Fizzy installs one of these on the `Host` during startup (`Host.installFizzyApi`);
//! plugins call the convenience forwarders on `Host` (e.g. `host.arena()`), which
//! dispatch through this vtable. It exposes only the genuinely shared state a
//! plugin still needs — the per-frame arena, the open project folder, the few fizzy-
//! owned settings plugins read, and the dirty-mark hook — without leaking the concrete
//! `Editor` type across the SDK boundary.
const std = @import("std");
const dvui = @import("dvui");
const DocHandle = @import("DocHandle.zig");
const RegionSpec = @import("RegionSpec.zig");
const Surface = @import("Surface.zig");

const EditorAPI = @This();

/// A name/extension-pattern pair for a native save dialog. Layout matches the backend's
/// `DialogFileFilter` (which mirrors `SDL_DialogFileFilter`), so fizzy forwards a slice
/// of these straight to the backend without a copy. `pattern` is a `;`-separated extension
/// list, e.g. `"png;jpg;jpeg"`.
pub const SaveDialogFilter = extern struct {
    name: [*:0]const u8,
    pattern: [*:0]const u8,
};

/// Invoked when a native save dialog resolves: the chosen paths, or null if cancelled.
pub const SaveDialogCallback = *const fn (?[][:0]const u8) void;

/// Invoked when a native open-file/folder dialog resolves.
pub const OpenPathsCallback = *const fn (?[][:0]const u8) void;

/// Grid dimensions for `createDocument`.
pub const NewDocGrid = struct {
    columns: u32 = 1,
    rows: u32 = 1,
    column_width: u32,
    row_height: u32,
};

/// Web save-dialog kind (wasm only; native ignores).
pub const WebSaveKind = enum { save, save_as };

/// Resolved canvas zoom/pan control style (mouse: scroll zooms, middle-button pans;
/// trackpad: scroll pans, ctrl/cmd+scroll zooms). Matches `core.widgets.CanvasWidget.PanZoomScheme`.
pub const PanZoomScheme = enum { mouse, trackpad };

ctx: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    /// Fizzy's per-frame arena allocator (reset every frame; do not free).
    arena: *const fn (ctx: *anyopaque) std.mem.Allocator,
    /// The open project root folder, or null when none is open.
    folder: *const fn (ctx: *anyopaque) ?[]const u8,
    /// The user palettes folder (config), or null on platforms without one (web).
    paletteFolder: *const fn (ctx: *anyopaque) ?[]const u8,
    /// Mark fizzy's settings dirty so the debounced autosave persists them.
    markSettingsDirty: *const fn (ctx: *anyopaque) void,
    /// A credential kept for a plugin, by key (`<plugin>.<what>`), outside `settings.zon` —
    /// see `Host.getSecret`. Borrowed until the next set of that key; null when unset.
    getSecret: *const fn (ctx: *anyopaque, key: []const u8) ?[]const u8,
    /// Store (an empty value removes). Fails on a build with no private storage (the web).
    setSecret: *const fn (ctx: *anyopaque, key: []const u8, value: []const u8) anyerror!void,
    /// Fizzy-owned content-area opacity (also drives fizzy's own panes); plugins
    /// read it to match fizzy's own chrome.
    contentOpacity: *const fn (ctx: *anyopaque) f32,
    /// The host's dialog frame: the function `core.dialogs.dialog` registers with dvui so
    /// the host draws the window (frost, header, footer, modal dim) around a plugin's body.
    /// Installed into the dylib's `core.dialogs.host_chrome` at load.
    dialogWindow: *const fn (ctx: *anyopaque) dvui.Dialog.DisplayFn,
    /// The host's `core.dialogs.frostPane`, for a plugin's own floating surfaces.
    frostPane: *const fn (ctx: *anyopaque, id: dvui.Id, rect: dvui.Rect.Physical, corners: dvui.CornerRect, scale: f32) bool,
    /// Whether the OS window is currently maximized (always false on web).
    isMaximized: *const fn (ctx: *anyopaque) bool,
    /// Runtime macOS detection (uses `navigator.platform` on web, `os.tag` on native).
    isMacOS: *const fn (ctx: *anyopaque) bool,
    /// True on native macOS/Windows where unfocused window chrome dims content opacity.
    appliesNativeWindowOpacity: *const fn (ctx: *anyopaque) bool,
    /// Fizzy-resolved canvas zoom/pan scheme (mouse vs trackpad wheel mapping).
    panZoomScheme: *const fn (ctx: *anyopaque) PanZoomScheme,
    /// The explorer pane's content rect (fizzy's own layout); plugins drawn inside the explorer
    /// read it to size their content. Zero rect when fizzy's API isn't installed.
    explorerRect: *const fn (ctx: *anyopaque) dvui.Rect,
    /// The explorer scroll area's virtual content size (fizzy's own layout). Zero size when
    /// fizzy's API isn't installed.
    explorerVirtualSize: *const fn (ctx: *anyopaque) dvui.Size,
    /// Run the platform's native "save file" dialog (native: OS dialog; web: download
    /// picker). `cb` is invoked when it resolves. No-op when fizzy's API isn't installed.
    showSaveDialog: *const fn (
        ctx: *anyopaque,
        cb: SaveDialogCallback,
        filters: []const SaveDialogFilter,
        default_filename: []const u8,
        default_folder: ?[]const u8,
    ) void,
    /// The actively focused open document, or null when none.
    activeDoc: *const fn (ctx: *anyopaque) ?DocHandle,
    /// Open document by index in **open order** — the order documents were opened, which is the
    /// only order the host knows. It is not tab order: tabs belong to whichever plugin lays
    /// documents out (the workbench, say), and only that plugin can answer in its own order.
    /// Null when out of range.
    docByIndex: *const fn (ctx: *anyopaque, index: usize) ?DocHandle,
    /// Open document by stable id, or null when not open.
    docById: *const fn (ctx: *anyopaque, id: u64) ?DocHandle,
    /// Index of document `id` in open order (see `docByIndex`), or null when not open.
    docIndex: *const fn (ctx: *anyopaque, id: u64) ?usize,
    /// Number of open documents — the range `docByIndex` accepts.
    openDocCount: *const fn (ctx: *anyopaque) usize,
    /// Focus the document at `index` (updates workspace tab selection).
    setActiveDocIndex: *const fn (ctx: *anyopaque, index: usize) void,
    /// Allocate the next fizzy document id (monotonic).
    allocDocId: *const fn (ctx: *anyopaque) u64,

    /// Explorer scroll viewport width (0 when unavailable).
    explorerViewportWidth: *const fn (ctx: *anyopaque) f32,
    /// Lookup an open document by absolute path.
    docFromPath: *const fn (ctx: *anyopaque, path: []const u8) ?DocHandle,
    /// Open `path` in `grouping` (async load when needed). Returns true when a new load started.
    openFilePath: *const fn (ctx: *anyopaque, path: []const u8, grouping: u64) anyerror!bool,
    /// Focus an open doc or queue load; returns index when already open, null when loading.
    openOrFocusFileAtGrouping: *const fn (ctx: *anyopaque, path: []const u8, grouping: u64) anyerror!?usize,
    /// Ensure `path` is open and move the caret to `line`/`character` (0-based; `character` a
    /// byte count within the line), opening it asynchronously if needed — so this may land a
    /// frame or more later.
    ///
    /// **This is host state, not workbench state.** It used to live only on the `workbench-api`
    /// service, which meant a plugin doing goto-definition (text, markdown) depended on
    /// workbench being installed. But the implementation was already written almost entirely
    /// against the host — `docFromPath`, `doc.owner.revealPosition`, `setActiveDocIndex`,
    /// `pluginForExtension` — with only a small pending-reveal queue that was workbench's by
    /// accident rather than by meaning. Moving it here is what lets those plugins load in any
    /// fizzy-based app, per the portability goal.
    ///
    /// `open_side` opens into a new grouping when the path is not already open; it is ignored
    /// when the target is open anywhere, which just focuses it where it lives (mirroring the
    /// file tree's "Open to the side"). Returns false when no plugin can open `path` at all.
    revealPosition: *const fn (ctx: *anyopaque, path: []const u8, line: u32, character: u32, open_side: bool) anyerror!bool,
    /// The split governing the region matching these keywords, or null when the app's layout
    /// declared no such split — a normal answer, not an error.
    ///
    /// A plugin drawing into a region legitimately needs this: workbench coordinates its own
    /// pane animation with the bottom split. Before, it was smuggled in as three out-parameters
    /// on `drawWorkspaces`, which only worked because fizzy's own shape has a panel — an app
    /// with a differently-shaped bottom had no way to answer.
    /// Open a region inside the one this plugin is drawing in, and hand back the app's handle to
    /// it. Null when the app cannot: nested too deep, or called outside the shape.
    ///
    /// The three of these are the whole seam, and the reason it is a seam at all rather than the
    /// layout API moving into the SDK: a region is the *app's* — it registers in the app's
    /// registry, persists its size and its assignment under the app's name, answers the app's
    /// picker. A plugin says what place it wants and the app makes one, exactly as it already
    /// does for the shape's own regions. The plugin's keywords are qualified by the enclosing
    /// region on the way in, so a declaration cannot reach outside the place it was given.
    ///
    /// Strictly nested, like the box it is: close the innermost one first.
    beginRegion: *const fn (ctx: *anyopaque, spec: RegionSpec) ?RegionSpec.Token,
    /// Draw the surfaces the region accepts, *here* — wherever the plugin has reached in its own
    /// chrome. Separate from `beginRegion` because a tab strip has to be laid out before the
    /// document it labels, and only the plugin knows where its content goes.
    drawRegionContents: *const fn (ctx: *anyopaque, token: RegionSpec.Token) anyerror!dvui.App.Result,
    /// Close it. The box closes, the clip is restored, and the region is left in the registry for
    /// the frame — a region that drew is a region the user can place things in.
    endRegion: *const fn (ctx: *anyopaque, token: RegionSpec.Token) void,
    /// The surfaces the region shows, in order — the user's assignment, else what its keywords
    /// accept. Arena-allocated, valid this frame. A plugin's own chooser (a tab strip) is drawn
    /// from this and never from a list of its own.
    regionMatching: *const fn (ctx: *anyopaque, token: RegionSpec.Token) []const *Surface,
    /// The surface the region currently shows: the selection if it still exists, else the first.
    regionSelected: *const fn (ctx: *anyopaque, token: RegionSpec.Token) ?*Surface,
    regionSelect: *const fn (ctx: *anyopaque, token: RegionSpec.Token, id: []const u8) void,
    /// Set what a region shows, by the name it is declared under — the same list the picker
    /// writes. `null` returns the region to its keywords. By name rather than by token so a
    /// plugin can address a region it is not drawing right now: a tab dropped on another pane,
    /// a pane that does not exist yet, a session being restored before anything has drawn.
    assignSurfaces: *const fn (ctx: *anyopaque, region: []const u8, ids: ?[]const []const u8) anyerror!void,
    /// The assignment for a region name, or null if the user never chose. Borrowed from the app;
    /// copy before the next assignment write.
    assignedSurfaces: *const fn (ctx: *anyopaque, region: []const u8) ?[]const []const u8,
    /// Every region name that has an assignment, arena-allocated. How a plugin finds the panes
    /// it declared last session before it has declared any this one.
    assignedRegionNames: *const fn (ctx: *anyopaque) []const []const u8,
    /// Make `id` the selection of the region named `region` — the by-name form of
    /// `regionSelect`, for a region the caller is not drawing right now: focusing the file a
    /// load just landed in whichever pane it landed in.
    selectInRegion: *const fn (ctx: *anyopaque, region: []const u8, id: []const u8) void,
    /// Draw the app's glyph for a declared file kind ("image", "source", …), or return false if
    /// this app has no glyph for it.
    ///
    /// The kind comes from a plugin (`Host.FileKind`); the *look* is the app's, which is why
    /// this crosses back over rather than living in the SDK. Fizzy's table is one file,
    /// `editor/file_glyphs.zig`, so the file tree and the tab bar cannot disagree; an app that
    /// ships no table simply falls through to the caller's generic icon.
    drawFileKindGlyph: *const fn (ctx: *anyopaque, kind: []const u8, color: dvui.Color) bool,
    /// Close document `id` (may prompt when dirty).
    closeDocById: *const fn (ctx: *anyopaque, id: u64) anyerror!void,
    /// Open/switch the project root folder.
    setProjectFolder: *const fn (ctx: *anyopaque, path: []const u8) anyerror!void,
    /// Close the current project folder (no-op when none open).
    closeProjectFolder: *const fn (ctx: *anyopaque) void,
    /// Recent project folders (most recent last).
    recentFolderCount: *const fn (ctx: *anyopaque) usize,
    recentFolderAt: *const fn (ctx: *anyopaque, index: usize) ?[]const u8,
    /// Reveal `path` in the OS file browser.
    openInFileBrowser: *const fn (ctx: *anyopaque, path: []const u8) anyerror!void,
    /// True when `abs_path` is ignored by `.fizignore`/`.gitignore` at `project_root`.
    isPathIgnored: *const fn (
        ctx: *anyopaque,
        project_root: []const u8,
        abs_path: []const u8,
        name: []const u8,
        kind: std.Io.File.Kind,
    ) bool,
    /// True when fizzy has a live filesystem watcher on the open root folder, i.e. when
    /// `Plugin.VTable.folderPathsChanged` can be relied on to fire. False with no folder open,
    /// on a platform with no watcher backend, or when starting one failed.
    folderWatchActive: *const fn (ctx: *anyopaque) bool,
    /// Explorer tree branch expanded state.
    explorerBranchIsOpen: *const fn (ctx: *anyopaque, branch_id: dvui.Id) bool,
    setExplorerBranchOpen: *const fn (ctx: *anyopaque, branch_id: dvui.Id, open: bool) void,
    /// Draw workspace panes (center region); `index` is the root pane (usually 0).
    drawWorkspaces: *const fn (ctx: *anyopaque, index: usize) anyerror!dvui.App.Result,
    /// Native open-folder dialog (no-op on web).
    showOpenFolderDialog: *const fn (ctx: *anyopaque, cb: OpenPathsCallback, default_folder: ?[]const u8) void,
    /// Native open-file dialog (web: file picker).
    showOpenFileDialog: *const fn (
        ctx: *anyopaque,
        cb: OpenPathsCallback,
        filters: []const SaveDialogFilter,
        default_filename: []const u8,
        default_folder: ?[]const u8,
    ) void,

    save: *const fn (ctx: *anyopaque) anyerror!void,
    requestPrepareFrame: *const fn (ctx: *anyopaque) void,
    /// Wake the app event loop for another frame. Safe from worker threads (PTY readers, etc.).
    refresh: *const fn (ctx: *anyopaque) void,

    // ---- new document ----
    /// Heap-owned unique basename like `untitled-1`; caller frees with the app allocator.
    allocUntitledPath: *const fn (ctx: *anyopaque) anyerror![]u8,
    /// Create and open a new document at `path` (path ownership transfers to fizzy).
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

    /// Append a line to fizzy's "Output" bottom panel. `scope` and `message` are plain
    /// runtime strings (not `comptime`, unlike `std.log`) — a plugin builds `.dylib`/`.so`
    /// separately from fizzy, so it can't share fizzy's `std.log` sink; this is the
    /// cross-ABI equivalent for anything a plugin wants visible there (e.g. a child
    /// process's stderr).
    logLine: *const fn (ctx: *anyopaque, level: std.log.Level, scope: []const u8, message: []const u8) void,

    /// Draws a standard menu-item row (separator above, label + keybind hint, click-detect)
    /// inside whatever menu is currently open, and returns whether it was clicked this frame.
    /// `command_id` is the registered `Command` this row runs (e.g. `"text.format"`), or null
    /// for a row that is not a command; fizzy resolves its current chord from the keymap
    /// and draws it as the accelerator, so a user rebinding it in the Keyboard Shortcuts pane
    /// updates the row with no further work from the plugin. `title` also seeds the widget's
    /// id — use a distinct title per call site.
    ///
    /// This took a dvui *bind name* before (`"format"`, `"grid_layout"`). Those names are a
    /// separate, flat namespace that plugin commands generally have no entry in, so the hint was
    /// blank for every plugin item in practice, and rebinding could not reach it at all.
    ///
    /// Menu section contributions (`Host.registerMenuSection`) must draw items through this
    /// rather than calling `dvui.menuItem()`/`dvui.separator()` directly: dvui tracks "the
    /// currently open menu" via a private module-level variable in `MenuWidget.zig`, and each
    /// plugin dylib compiles its own separate copy of that variable. A plugin calling dvui's
    /// menu widgets directly sees its own copy's default (never set, since only fizzy opens
    /// menus), and `MenuItemWidget` unwrapping that stale `null` is a use-after-free-shaped
    /// crash waiting to happen (safety-panics in Debug, silently corrupts memory in
    /// ReleaseFast). Routing through this function keeps the actual widget construction in the
    /// fizzy's own compiled code, where that state is always valid — the plugin just gets a
    /// plain bool back, the same shape as every other fizzy-owned-context call on this vtable.
    drawMenuItem: *const fn (ctx: *anyopaque, title: []const u8, command_id: ?[]const u8) bool,

    /// Reads `<plugins_dir>/<id>.settings.zon`, or null if absent/unavailable. Caller-owned
    /// (free with the same allocator `Host` uses).
    ///
    /// `Host.loadPluginSettings` routes through this instead of reading the file itself for the
    /// same reason `drawMenuItem` above routes through fizzy: it can be called from a
    /// dynamically-loaded plugin's own `register()`, before the host has synced that dylib's
    /// per-compilation-unit `dvui` globals (`dvui.io` et al., each a `pub var` duplicated per
    /// dylib). A direct file read at that point would run against the calling dylib's own
    /// still-`undefined` `dvui.io` and segfault. This function pointer, like every other one on
    /// this vtable, always executes as fizzy's own compiled code regardless of which dylib
    /// holds the call site, so it always sees fizzy's real, initialized `dvui.io`.
    loadPluginSettingsFile: *const fn (ctx: *anyopaque, id: []const u8) ?[]u8,

    /// The plugin id the user has assigned as the default owner of `ext` (with dot), or null
    /// when they have made no explicit choice for it. Backed by fizzy's in-memory cache of the
    /// per-plugin `.extensions` lists in `settings.zon`, so it never touches disk.
    ///
    /// The returned slice is owned by fizzy and valid only until the cache is next rebuilt
    /// (a plugin install / update / unload, or a File Types settings edit) — copy it if you
    /// need to keep it. `Host.pluginForExtension` consumes it immediately, which is the only
    /// intended use.
    extensionOwnerOverride: *const fn (ctx: *anyopaque, ext: []const u8) ?[]const u8,
};

pub fn arena(self: EditorAPI) std.mem.Allocator {
    return self.vtable.arena(self.ctx);
}

pub fn extensionOwnerOverride(self: EditorAPI, ext: []const u8) ?[]const u8 {
    return self.vtable.extensionOwnerOverride(self.ctx, ext);
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

pub fn getSecret(self: EditorAPI, key: []const u8) ?[]const u8 {
    return self.vtable.getSecret(self.ctx, key);
}

pub fn setSecret(self: EditorAPI, key: []const u8, value: []const u8) anyerror!void {
    return self.vtable.setSecret(self.ctx, key, value);
}

pub fn dialogWindow(self: EditorAPI) dvui.Dialog.DisplayFn {
    return self.vtable.dialogWindow(self.ctx);
}

pub fn frostPane(self: EditorAPI, id: dvui.Id, rect: dvui.Rect.Physical, corners: dvui.CornerRect, scale: f32) bool {
    return self.vtable.frostPane(self.ctx, id, rect, corners, scale);
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

pub fn panZoomScheme(self: EditorAPI) PanZoomScheme {
    return self.vtable.panZoomScheme(self.ctx);
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

pub fn allocDocId(self: EditorAPI) u64 {
    return self.vtable.allocDocId(self.ctx);
}

pub fn explorerViewportWidth(self: EditorAPI) f32 {
    return self.vtable.explorerViewportWidth(self.ctx);
}

pub fn docFromPath(self: EditorAPI, path: []const u8) ?DocHandle {
    return self.vtable.docFromPath(self.ctx, path);
}

pub fn openFilePath(self: EditorAPI, path: []const u8, grouping: u64) !bool {
    return self.vtable.openFilePath(self.ctx, path, grouping);
}

pub fn openOrFocusFileAtGrouping(self: EditorAPI, path: []const u8, grouping: u64) !?usize {
    return self.vtable.openOrFocusFileAtGrouping(self.ctx, path, grouping);
}

pub fn revealPosition(self: EditorAPI, path: []const u8, line: u32, character: u32, open_side: bool) !bool {
    return self.vtable.revealPosition(self.ctx, path, line, character, open_side);
}

pub fn beginRegion(self: EditorAPI, spec: RegionSpec) ?RegionSpec.Token {
    return self.vtable.beginRegion(self.ctx, spec);
}

pub fn drawRegionContents(self: EditorAPI, token: RegionSpec.Token) !dvui.App.Result {
    return self.vtable.drawRegionContents(self.ctx, token);
}

pub fn endRegion(self: EditorAPI, token: RegionSpec.Token) void {
    self.vtable.endRegion(self.ctx, token);
}

pub fn regionMatching(self: EditorAPI, token: RegionSpec.Token) []const *Surface {
    return self.vtable.regionMatching(self.ctx, token);
}

pub fn regionSelected(self: EditorAPI, token: RegionSpec.Token) ?*Surface {
    return self.vtable.regionSelected(self.ctx, token);
}

pub fn regionSelect(self: EditorAPI, token: RegionSpec.Token, id: []const u8) void {
    self.vtable.regionSelect(self.ctx, token, id);
}

pub fn assignSurfaces(self: EditorAPI, region: []const u8, ids: ?[]const []const u8) !void {
    return self.vtable.assignSurfaces(self.ctx, region, ids);
}

pub fn assignedSurfaces(self: EditorAPI, region: []const u8) ?[]const []const u8 {
    return self.vtable.assignedSurfaces(self.ctx, region);
}

pub fn assignedRegionNames(self: EditorAPI) []const []const u8 {
    return self.vtable.assignedRegionNames(self.ctx);
}

pub fn selectInRegion(self: EditorAPI, region: []const u8, id: []const u8) void {
    self.vtable.selectInRegion(self.ctx, region, id);
}

pub fn drawFileKindGlyph(self: EditorAPI, kind: []const u8, color: dvui.Color) bool {
    return self.vtable.drawFileKindGlyph(self.ctx, kind, color);
}

pub fn closeDocById(self: EditorAPI, id: u64) !void {
    return self.vtable.closeDocById(self.ctx, id);
}

pub fn setProjectFolder(self: EditorAPI, path: []const u8) !void {
    return self.vtable.setProjectFolder(self.ctx, path);
}

pub fn closeProjectFolder(self: EditorAPI) void {
    self.vtable.closeProjectFolder(self.ctx);
}

pub fn recentFolderCount(self: EditorAPI) usize {
    return self.vtable.recentFolderCount(self.ctx);
}

pub fn recentFolderAt(self: EditorAPI, index: usize) ?[]const u8 {
    return self.vtable.recentFolderAt(self.ctx, index);
}

pub fn openInFileBrowser(self: EditorAPI, path: []const u8) !void {
    return self.vtable.openInFileBrowser(self.ctx, path);
}

pub fn isPathIgnored(
    self: EditorAPI,
    project_root: []const u8,
    abs_path: []const u8,
    name: []const u8,
    kind: std.Io.File.Kind,
) bool {
    return self.vtable.isPathIgnored(self.ctx, project_root, abs_path, name, kind);
}

pub fn folderWatchActive(self: EditorAPI) bool {
    return self.vtable.folderWatchActive(self.ctx);
}

pub fn explorerBranchIsOpen(self: EditorAPI, branch_id: dvui.Id) bool {
    return self.vtable.explorerBranchIsOpen(self.ctx, branch_id);
}

pub fn setExplorerBranchOpen(self: EditorAPI, branch_id: dvui.Id, open: bool) void {
    self.vtable.setExplorerBranchOpen(self.ctx, branch_id, open);
}

pub fn drawWorkspaces(self: EditorAPI, index: usize) !dvui.App.Result {
    return self.vtable.drawWorkspaces(self.ctx, index);
}

pub fn showOpenFolderDialog(self: EditorAPI, cb: OpenPathsCallback, default_folder: ?[]const u8) void {
    self.vtable.showOpenFolderDialog(self.ctx, cb, default_folder);
}

pub fn showOpenFileDialog(
    self: EditorAPI,
    cb: OpenPathsCallback,
    filters: []const SaveDialogFilter,
    default_filename: []const u8,
    default_folder: ?[]const u8,
) void {
    self.vtable.showOpenFileDialog(self.ctx, cb, filters, default_filename, default_folder);
}

pub fn save(self: EditorAPI) !void {
    return self.vtable.save(self.ctx);
}

pub fn requestPrepareFrame(self: EditorAPI) void {
    self.vtable.requestPrepareFrame(self.ctx);
}

pub fn refresh(self: EditorAPI) void {
    self.vtable.refresh(self.ctx);
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

pub fn logLine(self: EditorAPI, level: std.log.Level, scope: []const u8, message: []const u8) void {
    self.vtable.logLine(self.ctx, level, scope, message);
}

pub fn drawMenuItem(self: EditorAPI, title: []const u8, command_id: ?[]const u8) bool {
    return self.vtable.drawMenuItem(self.ctx, title, command_id);
}

pub fn loadPluginSettingsFile(self: EditorAPI, id: []const u8) ?[]u8 {
    return self.vtable.loadPluginSettingsFile(self.ctx, id);
}
