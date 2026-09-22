//! The services fizzy exposes to plugins, and the registries it owns. Plugins
//! receive a `*Host` instead of reaching into editor globals; it holds the plugin
//! registry, fizzy region registries, and a service locator. The Host is
//! embedded in `Editor`.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const core = @import("core");
const runtime = @import("runtime.zig");
const Plugin = @import("Plugin.zig");
const EditorAPI = @import("EditorAPI.zig");
const DocHandle = @import("DocHandle.zig");
const RegionSpec = @import("RegionSpec.zig");
const language = @import("language.zig");
const settings = @import("settings.zig");

pub const Host = @This();

pub const SettingsSchema = settings.SettingsSchema;

pub const LanguageSupport = language.LanguageSupport;
pub const TreeSitterHighlight = language.TreeSitterHighlight;
pub const HighlightStyle = language.HighlightStyle;

pub const Surface = @import("Surface.zig");
pub const keywords = @import("keywords.zig");
// Not `const menus = @import("menus.zig")`: `Host` already has a `menus` *field* (the
// registry), and a file-scope import is a struct member too.
pub const MenuContribution = @import("menus.zig").MenuContribution;
pub const MenuSectionContribution = @import("menus.zig").MenuSectionContribution;
pub const NativeMenuItem = @import("menus.zig").NativeMenuItem;
pub const RailItemContribution = @import("menus.zig").RailItemContribution;
pub const OpenAction = @import("menus.zig").OpenAction;
pub const accounts = @import("accounts.zig");
pub const Command = @import("Command.zig");

/// Per-plugin opaque settings blobs pending a write: plugin id -> serialized zon text, or `null`
/// meaning "remove this id's `.settings` section entirely" (R12's non-default-only persistence —
/// see `sdk/settings.zig`'s `Schema(T).diffSerialize`: a value that's back to all-defaults has
/// nothing worth writing). The Host owns the key + (when present) value strings. This is a write
/// buffer only, not the source of truth — `Editor.writeMergedSettings` (via
/// `takePendingPluginSettings`) composes each entry into fizzy's own `<config>/settings.zon`
/// under `.plugins.<id>.settings` (a real, human-editable nested ZON struct literal, not an
/// escaped-string blob — see `src/editor/SettingsPluginsZon.zig` and
/// `docs/PLUGIN_MANIFEST_PLAN.md` R10/R12) and never interprets the contents.
pub const PluginSettings = std.StringArrayHashMapUnmanaged(?[]const u8);

/// Optional tint for a workbench file-tree row background. `color_index` is the row's
/// stable index during the current tree draw (workbench increments per file). Return
/// null to defer to the next resolver or the theme default.
pub const FileRowFillColor = struct {
    /// Contributing plugin (null = fizzy built-in). Used to scope teardown in
    /// `unregisterPlugin` when a plugin is unloaded at runtime.
    owner: ?*Plugin = null,
    ctx: ?*anyopaque = null,
    color: *const fn (ctx: ?*anyopaque, color_index: usize) ?dvui.Color,
};

/// A registered inter-plugin service plus the plugin that owns it, so a runtime
/// unload can remove the owner's services. `owner` is null for fizzy-registered
/// services with no single plugin owner.
pub const ServiceEntry = struct {
    /// The service's name. Borrowed: a plugin's `service_name` is a string literal in its own
    /// image, which `unregisterPlugin` drops before `dlclose`.
    name: []const u8,
    ptr: *anyopaque,
    /// The provider's declared `service_version`. Checked on every typed lookup: a downstream
    /// app's own service cannot be covered by `recorded_sdk_shape_fingerprint` — that hash is
    /// over *this* SDK's shape and knows nothing about a CAD app's geometry API — so without a
    /// version a changed struct is a silent vtable-shape mismatch across `dlopen`, which is the
    /// worst failure this codebase can produce. Bump it whenever the type's layout changes.
    version: u32,
    owner: ?*Plugin = null,
};

/// What *kind* of thing a file is — "image", "source", "sprite" — as opposed to how it looks.
///
/// This is the same split as `Surface.keywords`: the plugin says what something *is*, the app
/// decides how to present it. A plugin knows `.png` is an image; it does not know whether this
/// app draws images with an entypo glyph, a custom SVG, or a thumbnail, and it should not have
/// to. Before this, `registerFileIcon` made every plugin pick a glyph — and both in-tree
/// painters did exactly that, drawing `entypo.image` / `entypo.code` off nothing but the
/// extension.
///
/// It also fixes agreement for free. The file tree and the tab bar are drawn by entirely
/// separate code, and had to agree on a file's icon; they now both resolve kind -> glyph through
/// one app-side table rather than both happening to call the same plugin.
///
/// Kinds are free-form strings for the same reason keywords are: a plugin inventing "shader"
/// must not need an SDK change, and an app that has never heard of "shader" simply falls back.
pub const FileKind = struct {
    owner: ?*Plugin = null,
    ctx: ?*anyopaque = null,
    /// The kind this extension is, or null to decline.
    kind: *const fn (ctx: ?*anyopaque, ext: []const u8) ?[]const u8,
};

/// A plugin-provided **painter**: fizzy reserves a rect, the painter fills it.
///
/// One type rather than the `FileIcon` / `PluginIcon` pair it replaces. Those differed only in
/// what fizzy told the drawer — a file's extension, path and colour, or nothing at all — and
/// `core.widgets.treeRowGlyph` already documented a single contract for both: "fizzy reserves the
/// rect; the plugin draws into it with `expand = .ratio`". Two registries, two registrars and
/// two dispatchers for one idea is the kind of accidental specialisation that makes the surface
/// look bigger than it is.
///
/// **Size is the host's to decide, not yours.** Every call site reserves a fixed square slot
/// (`core.widgets.treeRowGlyph`, sized from the user's font settings) and your painter runs inside
/// it. Draw with `expand = .ratio` so your artwork fits that slot at its own aspect ratio; a
/// hard-coded size or scale makes tree rows taller than every other row, and drawing without a
/// reserved slot (e.g. bare in a tab row) lets ratio+gravity center the icon in the whole parent.
///
/// The parameters are a tagged union rather than a type parameter because this crosses a dylib
/// boundary: a generic would have to monomorphise, and the function pointer must be one
/// concrete type on both sides.
///
/// Return false to decline, so the caller can fall back — the file tree to a generic glyph, the
/// store to its placeholder, the settings tree to the plugin's initial letter.
pub const Painter = struct {
    owner: ?*Plugin = null,
    ctx: ?*anyopaque = null,
    draw: *const fn (ctx: ?*anyopaque, subject: Subject) bool,

    /// What is being painted. Sizing contract is the same for every case: the caller reserves
    /// the slot (a tree row glyph, a 32px store card, a tab row) and the painter fills it with
    /// `expand = .ratio`. Drawing at a fixed size looks right in one place and wrong in the rest.
    pub const Subject = union(enum) {
        /// A file, in the tree or on a tab.
        file: struct {
            ext: []const u8,
            path: []const u8,
            color: dvui.Color,
        },
        /// The owning plugin's own logo, for the store card and the settings tree branch.
        plugin_logo,
    };
};

allocator: std.mem.Allocator,

/// All registered plugins (statically compiled in, or loaded from a runtime dylib).
plugins: std.ArrayListUnmanaged(*Plugin) = .empty,

/// The plugin whose "new document" dialog is currently open, set by `requestNewDocument`
/// right before dispatching to that plugin's `requestNewDocumentDialog` and consumed
/// (cleared) by the very next `Editor.newFile` call. Once more than one plugin implements
/// `createDocument` (e.g. both `pixi` and the bundled `text` fallback), the dialog's own
/// "OK" handler calling the generic `host.createDocument(path, grid)` is otherwise
/// ambiguous — `pluginWithCreateDocument` would pick whichever plugin registered first,
/// not necessarily the one whose dialog just closed.
pending_new_document_owner: ?*Plugin = null,

/// Service locator for inter-plugin APIs: name -> opaque service vtable. E.g. the
/// workbench plugin registers "workbench" so editor plugins can place tabs and
/// draw per-branch explorer decorations without a compile-time dependency on it.
/// Registered services, in registration order.
///
/// A list rather than a map keyed by name, because **several providers may share a name**: that
/// is what a hook is. An app defines `"cad.hooks"`, every plugin that wants to observe it
/// registers an implementation, and the app calls each in turn (`servicesNamed`). A map silently
/// dropped all but the last, which is a fine answer for "who provides X" and a wrong one for
/// "who is listening to X".
services: std.ArrayListUnmanaged(ServiceEntry) = .empty,

/// The project's file set — one cached, searchable view of what is on disk, owned by the app and
/// shared by every plugin that draws files. Null in a headless host.
///
/// **This is the shape inter-plugin sharing takes when the thing being shared is data rather
/// than behaviour, and it needs no vtable.** A service (above) is a `{ctx, vtable}` pair because
/// its implementation lives in a *plugin* the host cannot name; a `core.FileTable` is a plain
/// struct declared in the framework, so both images know its layout and plugin code calls its
/// methods directly. Function pointers are only for calls that go *into* a plugin.
///
/// It replaces a real defect rather than adding a capability: the file tree kept these caches as
/// module-level `var`s, and its module is compiled into both fizzy and the workbench dylib — so
/// there were two of every cache, reconciled by a `disk_generation` counter each copy polled to
/// know when to discard its own work. A tab strip wanting the same listings would have been a
/// third. One table, no counter.
files: ?*core.FileTable = null,

/// The app's own pointer, handed to `layout(ctx, *Layout)` each frame. Fizzy
/// passes `*Editor` here; another app puts its own state. Same `?*anyopaque`
/// idiom as `Surface.draw` and `Region.Content`.
layout_ctx: ?*anyopaque = null,

/// Fizzy's read/utility surface (arena, folder, shared settings, dirty mark),
/// installed by fizzy during startup. Null until installed (headless/test).
fizzy_api: ?EditorAPI = null,

/// The one plugin that opens anything no other plugin owns (`text`). Set by
/// `registerFallbackEditor`, cleared in `unregisterPlugin`. Null in a headless host, or
/// before the fallback editor has registered.
fallback_editor: ?*Plugin = null,

/// Not-yet-flushed per-plugin settings writes (see `PluginSettings`); drained by
/// `takePendingPluginSettings`. Whether the composed merge write actually touches disk is
/// decided once, over the *whole* merged file, by `Editor.writeMergedSettings` — there is no
/// separate per-plugin dedup here (see R10's decision log for why that collapsed once settings
/// moved into one file).
plugin_settings_pending: PluginSettings = .empty,

/// `<config_folder>/plugins` — where every plugin's own `<id>/<id>.{dylib,so,dll}` directory
/// lives (see `pluginInstallDir`; built-ins that compile static have no dylib there). No longer
/// where settings live — those are a `.plugins.<id>` field inside fizzy's own
/// `<config_folder>/settings.zon` (see R10). Set once by fizzy during startup
/// (`Editor.init`); null on wasm (no filesystem) or in headless/tests, in which case settings
/// load/store are no-ops.
plugins_dir: ?[]const u8 = null,

/// File-tree row fill tints (workbench asks the Host; editor plugins register).
file_row_fill_colors: std.ArrayListUnmanaged(FileRowFillColor) = .empty,

/// File-tree row icon drawers (workbench asks the Host; plugins register for their file types).
painters: std.ArrayListUnmanaged(Painter) = .empty,
/// Extension -> kind declarations; see `FileKind`.
file_kinds: std.ArrayListUnmanaged(FileKind) = .empty,

/// Loaded plugins' settings schemas (`sdk.settings.Schema(...)`), drawn by fizzy's settings
/// pane while each owner stays registered — see `settings.zig`'s "loaded-only" module doc note.
/// Cleared for `plugin`'s entries in `unregisterPlugin`; there is no on-disk/embedded fallback
/// for a disabled or failed-to-load plugin.
settings_schemas: std.ArrayListUnmanaged(SettingsSchema) = .empty,

// ---- fizzy region registries -----------------------------------------------
// Fizzy iterates these instead of hardcoded enums/switches. Items keep their
// registration order, which is the order they appear in the UI.

/// Left-region (explorer) views, one per sidebar icon.
/// Bottom-panel views (shown as a tab strip).
/// Center ("main window") providers; the active one draws the whole center.
/// Menubar contributions (non-macOS in-app menu bar).
menus: std.ArrayListUnmanaged(MenuContribution) = .empty,
/// Nested items contributed into an open parent menu (e.g. View > Example).
menu_sections: std.ArrayListUnmanaged(MenuSectionContribution) = .empty,
/// Plugin-drawn items at the bottom of the rail (`RailItemContribution`).
rail_items: std.ArrayListUnmanaged(RailItemContribution) = .empty,
/// More ways to open something, listed beside fizzy's own (`OpenAction`).
open_actions: std.ArrayListUnmanaged(OpenAction) = .empty,
/// Who the user is signed in as, per service (`accounts.Provider`). The host draws the disc.
account_providers: std.ArrayListUnmanaged(accounts.Provider) = .empty,
/// Pure-data menu leaf items the native (macOS NSMenu) menu builder consumes; see
/// `NativeMenuItem`.
native_menu_items: std.ArrayListUnmanaged(NativeMenuItem) = .empty,
/// Plugin-contributed commands, invoked by id (menus, keybinds, palette) — see `Command`.
commands: std.ArrayListUnmanaged(Command) = .empty,
/// Pluggable language/format support (syntax highlighting, preview panes).
language_support: std.ArrayListUnmanaged(LanguageSupport) = .empty,

/// Every UI a plugin contributes, of every kind. A `Surface` carries keywords rather than a
/// region name, so the app's layout decides where it lands and the SDK never has to grow a new
/// registry for a new kind of place.
surfaces: std.ArrayListUnmanaged(Surface) = .empty,

/// Active selection by contribution id (null = use the first registered).
/// Which surface is selected, per keyword group.
///
/// One store rather than the three named fields it replaces (`active_sidebar_view`,
/// `active_bottom_view`, `active_center`). Those named the three regions fizzy happens to have,
/// so the layout had to special-case them to avoid keeping a second, disagreeing copy — and a
/// fourth kind of region could not have a selection at all. The named accessors below are now
/// views onto this.
selections: std.AutoHashMapUnmanaged(u64, []const u8) = .empty,

pub fn init(allocator: std.mem.Allocator) Host {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Host) void {
    self.plugins.deinit(self.allocator);
    self.services.deinit(self.allocator);
    self.selections.deinit(self.allocator);
    self.surfaces.deinit(self.allocator);
    self.menus.deinit(self.allocator);
    self.menu_sections.deinit(self.allocator);
    self.rail_items.deinit(self.allocator);
    self.open_actions.deinit(self.allocator);
    self.account_providers.deinit(self.allocator);
    self.native_menu_items.deinit(self.allocator);
    self.commands.deinit(self.allocator);
    self.language_support.deinit(self.allocator);
    self.file_row_fill_colors.deinit(self.allocator);
    self.painters.deinit(self.allocator);
    self.file_kinds.deinit(self.allocator);

    self.settings_schemas.deinit(self.allocator);
    {
        var it = self.plugin_settings_pending.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            if (e.value_ptr.*) |v| self.allocator.free(v);
        }
        self.plugin_settings_pending.deinit(self.allocator);
    }
}

// ---- fizzy services (installed by fizzy itself during startup) -------------

/// Install fizzy's own read/utility surface. Called once during startup.
pub fn installFizzyApi(self: *Host, api: EditorAPI) void {
    self.fizzy_api = api;
}

/// Per-frame arena allocator (reset every frame; do not free). Asserts fizzy's API is installed.
pub fn arena(self: *Host) std.mem.Allocator {
    return self.fizzy_api.?.arena();
}

/// Open project root folder, or null when none is open.
pub fn folder(self: *Host) ?[]const u8 {
    return if (self.fizzy_api) |a| a.folder() else null;
}

/// User palettes folder (config), or null on platforms without one.
pub fn paletteFolder(self: *Host) ?[]const u8 {
    return if (self.fizzy_api) |a| a.paletteFolder() else null;
}

/// A credential the plugin keeps on the user's behalf — a refresh token, an API key — stored
/// by the app outside `settings.zon` (which is exported, diffed, watched and drawn in a pane):
/// a `0600` file today, the OS keychain behind the same call later. Keys are plugin-namespaced
/// (`drive.refresh_token`). Borrowed until the next `setSecret` of that key; null when unset,
/// and always null on the web, which has no private storage — keep a session token in memory
/// there and ask again.
pub fn getSecret(self: *Host, key: []const u8) ?[]const u8 {
    return if (self.fizzy_api) |a| a.getSecret(key) else null;
}

/// Store a credential (an empty value removes it). Errors where there is nowhere private to
/// put it.
pub fn setSecret(self: *Host, key: []const u8, value: []const u8) !void {
    const a = self.fizzy_api orelse return error.FizzyApiNotInstalled;
    try a.setSecret(key, value);
}

/// Mark fizzy settings dirty so the debounced autosave persists them.
pub fn markSettingsDirty(self: *Host) void {
    if (self.fizzy_api) |a| a.markSettingsDirty();
}

/// Fizzy-owned content-area opacity (matches fizzy's own chrome). 1.0 if fizzy isn't installed.
pub fn contentOpacity(self: *Host) f32 {
    return if (self.fizzy_api) |a| a.contentOpacity() else 1.0;
}

/// Whether the OS window is currently maximized. False if fizzy isn't installed (headless/web).
pub fn isMaximized(self: *Host) bool {
    return if (self.fizzy_api) |a| a.isMaximized() else false;
}

pub fn isMacOS(self: *Host) bool {
    return if (self.fizzy_api) |a| a.isMacOS() else false;
}

pub fn appliesNativeWindowOpacity(self: *Host) bool {
    return if (self.fizzy_api) |a| a.appliesNativeWindowOpacity() else false;
}

pub fn panZoomScheme(self: *Host) EditorAPI.PanZoomScheme {
    return if (self.fizzy_api) |a| a.panZoomScheme() else .mouse;
}

/// The explorer pane's content rect (fizzy layout). Zero rect if fizzy isn't installed.
pub fn explorerRect(self: *Host) dvui.Rect {
    return if (self.fizzy_api) |a| a.explorerRect() else .{};
}

/// The explorer scroll area's virtual content size (fizzy layout). Zero size if fizzy isn't installed.
pub fn explorerVirtualSize(self: *Host) dvui.Size {
    return if (self.fizzy_api) |a| a.explorerVirtualSize() else .{};
}

/// Run the platform's native "save file" dialog. No-op if fizzy isn't installed (headless/test).
pub fn showSaveDialog(
    self: *Host,
    cb: EditorAPI.SaveDialogCallback,
    filters: []const EditorAPI.SaveDialogFilter,
    default_filename: []const u8,
    default_folder: ?[]const u8,
) void {
    if (self.fizzy_api) |a| a.showSaveDialog(cb, filters, default_filename, default_folder);
}

/// The actively focused open document, or null when none.
pub fn activeDoc(self: *Host) ?DocHandle {
    return if (self.fizzy_api) |a| a.activeDoc() else null;
}

pub fn docByIndex(self: *Host, index: usize) ?DocHandle {
    return if (self.fizzy_api) |a| a.docByIndex(index) else null;
}

pub fn docById(self: *Host, id: u64) ?DocHandle {
    return if (self.fizzy_api) |a| a.docById(id) else null;
}

pub fn docIndex(self: *Host, id: u64) ?usize {
    return if (self.fizzy_api) |a| a.docIndex(id) else null;
}

pub fn openDocCount(self: *Host) usize {
    return if (self.fizzy_api) |a| a.openDocCount() else 0;
}

pub fn setActiveDocIndex(self: *Host, index: usize) void {
    if (self.fizzy_api) |a| a.setActiveDocIndex(index);
}

pub fn allocDocId(self: *Host) u64 {
    return if (self.fizzy_api) |a| a.allocDocId() else 0;
}

pub fn explorerViewportWidth(self: *Host) f32 {
    return if (self.fizzy_api) |a| a.explorerViewportWidth() else 0;
}

pub fn docFromPath(self: *Host, path: []const u8) ?DocHandle {
    return if (self.fizzy_api) |a| a.docFromPath(path) else null;
}

/// Open `path` if needed and put the caret at `line`/`character`. Host state — a plugin doing
/// goto-definition needs no workbench service for this. Returns false when nothing can open it.
/// An open plugin region: what a plugin holds between declaring a place and closing it.
///
/// `init`/`deinit` like the box it is, because that is what a region is everywhere else in fizzy
/// — a shape scopes one and defers its `deinit`, and a plugin subdividing a region it was given
/// should read the same way.
pub const Region = struct {
    host: *Host,
    token: RegionSpec.Token,

    /// Draw the surfaces this region accepts, at this point in the plugin's own drawing.
    pub fn drawContents(self: Region) !dvui.App.Result {
        return if (self.host.fizzy_api) |a| try a.drawRegionContents(self.token) else .ok;
    }

    /// What this region shows, in order. A plugin drawing its own chooser (a tab strip) draws it
    /// from this — the list is the app's, so the picker, an assignment and the strip agree.
    pub fn matching(self: Region) []const *Surface {
        return if (self.host.fizzy_api) |a| a.regionMatching(self.token) else &.{};
    }

    /// The one currently shown, or null when the region is empty.
    pub fn selected(self: Region) ?*Surface {
        return if (self.host.fizzy_api) |a| a.regionSelected(self.token) else null;
    }

    pub fn select(self: Region, id: []const u8) void {
        if (self.host.fizzy_api) |a| a.regionSelect(self.token, id);
    }

    pub fn deinit(self: Region) void {
        if (self.host.fizzy_api) |a| a.endRegion(self.token);
    }
};

/// Declare a region inside the one this plugin is drawing in — a document pane inside the main
/// area, a sub-pane of a sidebar. Null when the app declined (nested too deep, or called from
/// outside the shape), which a caller should treat as "draw it yourself, plainly".
///
/// The region is the app's: it registers in the app's registry, remembers its size and the user's
/// assignment under `spec.name`, and answers the app's picker — so a plugin's subdivision gets
/// everything the shape's own regions have instead of reimplementing a worse version of it. What
/// the plugin keeps is the *contents*: where its chrome goes, and where `drawContents` puts the
/// surfaces. See `RegionSpec`.
pub fn region(self: *Host, spec: RegionSpec) ?Region {
    const api = self.fizzy_api orelse return null;
    const token = api.beginRegion(spec) orelse return null;
    return .{ .host = self, .token = token };
}

/// Set what the region named `region_name` shows — the same list the picker writes; `null` hands
/// it back to its keywords. Addressed by name so a plugin can write to a region it is not
/// drawing this instant: another pane a tab was dropped on, a pane that does not exist yet, or
/// last session's panes before any has been declared.
pub fn assignSurfaces(self: *Host, region_name: []const u8, ids: ?[]const []const u8) !void {
    if (self.fizzy_api) |a| return a.assignSurfaces(region_name, ids);
}

/// The assignment under `region_name`, or null when the user never chose. Borrowed; copy before
/// the next `assignSurfaces`.
pub fn assignedSurfaces(self: *Host, region_name: []const u8) ?[]const []const u8 {
    return if (self.fizzy_api) |a| a.assignedSurfaces(region_name) else null;
}

/// Every region name with an assignment, arena-allocated.
pub fn assignedRegionNames(self: *Host) []const []const u8 {
    return if (self.fizzy_api) |a| a.assignedRegionNames() else &.{};
}

/// Make `id` what the region named `region_name` shows, from outside its draw.
pub fn selectInRegion(self: *Host, region_name: []const u8, id: []const u8) void {
    if (self.fizzy_api) |a| a.selectInRegion(region_name, id);
}

pub fn revealPosition(self: *Host, path: []const u8, line: u32, character: u32, open_side: bool) !bool {
    return if (self.fizzy_api) |a| a.revealPosition(path, line, character, open_side) else false;
}

pub fn openFilePath(self: *Host, path: []const u8, grouping: u64) !bool {
    return if (self.fizzy_api) |a| try a.openFilePath(path, grouping) else false;
}

pub fn openOrFocusFileAtGrouping(self: *Host, path: []const u8, grouping: u64) !?usize {
    return if (self.fizzy_api) |a| try a.openOrFocusFileAtGrouping(path, grouping) else null;
}

pub fn closeDocById(self: *Host, id: u64) !void {
    if (self.fizzy_api) |a| return a.closeDocById(id);
}

pub fn setProjectFolder(self: *Host, path: []const u8) !void {
    return if (self.fizzy_api) |a| try a.setProjectFolder(path) else error.FizzyApiNotInstalled;
}

pub fn closeProjectFolder(self: *Host) void {
    if (self.fizzy_api) |a| a.closeProjectFolder();
}

pub fn recentFolderCount(self: *Host) usize {
    return if (self.fizzy_api) |a| a.recentFolderCount() else 0;
}

pub fn recentFolderAt(self: *Host, index: usize) ?[]const u8 {
    return if (self.fizzy_api) |a| a.recentFolderAt(index) else null;
}

pub fn openInFileBrowser(self: *Host, path: []const u8) !void {
    return if (self.fizzy_api) |a| try a.openInFileBrowser(path) else error.FizzyApiNotInstalled;
}

pub fn isPathIgnored(
    self: *Host,
    project_root: []const u8,
    abs_path: []const u8,
    name: []const u8,
    kind: std.Io.File.Kind,
) bool {
    return if (self.fizzy_api) |a| a.isPathIgnored(project_root, abs_path, name, kind) else false;
}

/// True when fizzy has a live filesystem watcher on the open root folder — i.e. when
/// `Plugin.VTable.folderPathsChanged` will actually fire. A plugin that must stay correct
/// (an index, a file tree) should keep a slow rescan for when this is false, and can skip it
/// entirely when it is true.
pub fn folderWatchActive(self: *Host) bool {
    return if (self.fizzy_api) |a| a.folderWatchActive() else false;
}

pub fn explorerBranchIsOpen(self: *Host, branch_id: dvui.Id) bool {
    return if (self.fizzy_api) |a| a.explorerBranchIsOpen(branch_id) else false;
}

pub fn setExplorerBranchOpen(self: *Host, branch_id: dvui.Id, open: bool) void {
    if (self.fizzy_api) |a| a.setExplorerBranchOpen(branch_id, open);
}

pub fn drawWorkspaces(self: *Host, index: usize) !dvui.App.Result {
    return if (self.fizzy_api) |a| try a.drawWorkspaces(index) else .ok;
}

pub fn showOpenFolderDialog(self: *Host, cb: EditorAPI.OpenPathsCallback, default_folder: ?[]const u8) void {
    if (self.fizzy_api) |a| a.showOpenFolderDialog(cb, default_folder);
}

pub fn showOpenFileDialog(
    self: *Host,
    cb: EditorAPI.OpenPathsCallback,
    filters: []const EditorAPI.SaveDialogFilter,
    default_filename: []const u8,
    default_folder: ?[]const u8,
) void {
    if (self.fizzy_api) |a| a.showOpenFileDialog(cb, filters, default_filename, default_folder);
}

pub fn save(self: *Host) !void {
    if (self.fizzy_api) |a| return a.save();
}

pub fn requestPrepareFrame(self: *Host) void {
    if (self.fizzy_api) |a| a.requestPrepareFrame();
}

pub fn refresh(self: *Host) void {
    if (self.fizzy_api) |a| a.refresh();
}

/// Mount a filesystem at `prefix` (`gdrive://<account>`): every path under it — in the file
/// tree, the `files` service, document open and save — is answered by `fs` instead of the disk,
/// with the prefix stripped so the backend sees `/Notes/a.md`. The host pumps `fs` once per
/// frame; the plugin keeps it alive until `unmount`. An app with no file table (nothing to
/// draw a mount in) refuses rather than pretending. See `core.FileTable` and `core.vfs`.
pub fn mount(self: *Host, prefix: []const u8, fs: core.vfs.Fs) !void {
    const files = self.files orelse return error.NoFileTable;
    try files.mount(prefix, fs);
}

/// Release a mount. Listings under it are dropped and its in-flight requests cancelled, so
/// nothing calls back into a filesystem the plugin is about to tear down.
pub fn unmount(self: *Host, prefix: []const u8) void {
    if (self.files) |files| files.unmount(prefix);
}

pub fn allocUntitledPath(self: *Host) ![]u8 {
    return if (self.fizzy_api) |a| try a.allocUntitledPath() else error.FizzyApiNotInstalled;
}

pub fn createDocument(self: *Host, path: []const u8, grid: EditorAPI.NewDocGrid) !DocHandle {
    return if (self.fizzy_api) |a| try a.createDocument(path, grid) else error.FizzyApiNotInstalled;
}

pub fn setExplorerNewFilePath(self: *Host, path: []const u8) !void {
    return if (self.fizzy_api) |a| try a.setExplorerNewFilePath(path) else error.FizzyApiNotInstalled;
}

pub fn requestSaveAs(self: *Host) void {
    if (self.fizzy_api) |a| a.requestSaveAs();
}

pub fn requestWebSave(self: *Host, kind: EditorAPI.WebSaveKind) void {
    if (self.fizzy_api) |a| a.requestWebSave(kind);
}

pub fn cancelPendingSaveDialog(self: *Host) void {
    if (self.fizzy_api) |a| a.cancelPendingSaveDialog();
}

pub fn setPendingCloseDocId(self: *Host, id: u64) void {
    if (self.fizzy_api) |a| a.setPendingCloseDocId(id);
}

pub fn queueCloseAfterSave(self: *Host, id: u64) !void {
    if (self.fizzy_api) |a| return a.queueCloseAfterSave(id);
}

pub fn trackQuitSaveInFlight(self: *Host, id: u64) !void {
    if (self.fizzy_api) |a| return a.trackQuitSaveInFlight(id);
}

pub fn resumeSaveAllQuit(self: *Host) void {
    if (self.fizzy_api) |a| a.resumeSaveAllQuit();
}

pub fn abortSaveAllQuit(self: *Host) void {
    if (self.fizzy_api) |a| a.abortSaveAllQuit();
}

/// Append a line to fizzy's "Output" bottom panel. No-op if fizzy isn't installed
/// (headless/tests). `scope` is a short plugin-chosen tag (e.g. "zig"); `message` is a
/// plain, already-formatted string — see `EditorAPI.logLine` for why this can't be a
/// `comptime`-generic `std.log`-style call like fizzy's own logging.
pub fn logLine(self: *Host, level: std.log.Level, scope: []const u8, message: []const u8) void {
    if (self.fizzy_api) |a| a.logLine(level, scope, message);
}

/// Draw a standard menu-item row inside the currently open menu; returns whether it was
/// clicked. `command_id` names the `Command` the row runs, and fizzy draws that command's
/// current chord beside it. False (never drawn/clicked) when fizzy isn't installed. See
/// `EditorAPI.VTable.drawMenuItem`'s doc comment — `Host.registerMenuSection` draw callbacks
/// must go through this instead of calling dvui's menu widgets directly.
pub fn drawMenuItem(self: *Host, title: []const u8, command_id: ?[]const u8) bool {
    return if (self.fizzy_api) |a| a.drawMenuItem(title, command_id) else false;
}

// ---- per-plugin settings store ---------------------------------------------
//
// Every plugin's settings live as a real, hand-editable ZON struct literal keyed by plugin id,
// nested inside fizzy's own `<config>/settings.zon` under a
// `.plugins = .{ .<id> = .{...}, ... }` field — not an escaped-string blob, and not one file per
// plugin (see `docs/PLUGIN_MANIFEST_PLAN.md` R10, superseding R8's one-file-per-plugin design).
// `SettingsPluginsZon` (in `src/editor/`) does the actual ZON text surgery; the Host only buffers
// pending writes and routes reads through `fizzy_api` — see `loadPluginSettings`'s doc comment
// for why that indirection is required. This is deliberately not cached across calls:
// `loadPluginSettings` is only ever called once per plugin, at `register()` time, so a fresh read
// costs nothing and keeps the Host from having to reason about staleness.

/// Reads `id`'s settings out of `<config>/settings.zon`'s `.plugins.<id>` field fresh off disk,
/// or null when unavailable (fizzy isn't installed, wasm/headless, or the field doesn't exist yet).
/// Caller-owned; free with `self.allocator`.
///
/// Routed through `fizzy_api` rather than reading the file directly here: `register()` — the
/// only caller of this, via `sdk.settings.Schema(T).load` — can run for a *dynamically-loaded*
/// plugin before the host has synced its per-dylib `dvui` globals (`dvui.io` et al. are
/// `pub var`s, duplicated per compiled dylib — see `dvui_context.zig`) into that dylib's own
/// copy. A direct file read here would run against that dylib's still-`undefined` `dvui.io` and
/// segfault. `fizzy_api`'s function pointers, by contrast, always execute as the host's own
/// compiled code no matter which dylib holds the call site, so they see the host's real `dvui.io`.
pub fn loadPluginSettings(self: *Host, id: []const u8) ?[]u8 {
    if (comptime builtin.target.cpu.arch == .wasm32) return null;
    return if (self.fizzy_api) |a| a.loadPluginSettingsFile(id) else null;
}

/// Buffers `blob` (serialized zon text) as `id`'s pending `.settings` write and marks fizzy
/// dirty; the debounced autosave composes it into the merged `settings.zon` (see
/// `Editor.writeMergedSettings`, which calls `takePendingPluginSettings` then
/// `SettingsPluginsZon.composeMergedText`). The Host copies both `id` and `blob`.
pub fn storePluginSettings(self: *Host, id: []const u8, blob: []const u8) !void {
    const dup = try self.allocator.dupe(u8, blob);
    errdefer self.allocator.free(dup);
    if (self.plugin_settings_pending.getPtr(id)) |slot| {
        if (slot.*) |old| self.allocator.free(old);
        slot.* = dup;
    } else {
        const key = try self.allocator.dupe(u8, id);
        try self.plugin_settings_pending.put(self.allocator, key, dup);
    }
    self.markSettingsDirty();
}

/// Buffers an explicit "remove `id`'s `.settings` section" — the non-default-only counterpart to
/// `storePluginSettings` (see `PluginSettings`). Used by `sdk.settings.Schema(T).store`/
/// `persist` when every field is back to its declared default.
pub fn removePluginSettings(self: *Host, id: []const u8) !void {
    if (self.plugin_settings_pending.getPtr(id)) |slot| {
        if (slot.*) |old| self.allocator.free(old);
        slot.* = null;
    } else {
        const key = try self.allocator.dupe(u8, id);
        try self.plugin_settings_pending.put(self.allocator, key, null);
    }
    self.markSettingsDirty();
}

/// Moves every buffered `storePluginSettings`/`removePluginSettings` entry out and resets the
/// pending buffer to empty. Called once by `Editor.writeMergedSettings`, right before composing
/// the merged file's `.plugins` block — the caller now owns every key/(optional) value in the
/// returned map and must free them (see `PluginSettings`'s doc comment). There is no per-plugin
/// write-dedup here anymore: whether the merge actually touches disk is decided once, over the
/// whole composed file, by the caller.
pub fn takePendingPluginSettings(self: *Host) PluginSettings {
    const taken = self.plugin_settings_pending;
    self.plugin_settings_pending = .empty;
    return taken;
}

// ---- plugin install directory -----------------------------------------------

/// `<plugins_dir>/<id>` — the directory a plugin (built-in or third-party) is installed into,
/// beside its own `<id>.{dylib,so,dll}` (see docs/PLUGIN_MANIFEST_PLAN.md R10: every plugin gets
/// its own directory rather than sitting flat in `plugins/`). A plugin can use this for its own
/// assets/data; the directory is not guaranteed to exist yet — create it (and any subpath) before
/// writing into it. Null when `plugins_dir` itself is unset (wasm/headless). Pure path join, no
/// filesystem access — caller-owned, free with `self.allocator`.
pub fn pluginInstallDir(self: *Host, id: []const u8) ?[]u8 {
    const dir = self.plugins_dir orelse return null;
    return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir, id }) catch null;
}

/// Register a plugin under its self-declared `id`. The `id` is the single source of truth
/// for routing (`pluginById`, `pluginForExtension`); a folder name or dylib path is not.
/// Rejects a second plugin claiming an already-registered `id` so routing can never become
/// ambiguous — the dylib loader turns this into a failed load the user is told about
/// (built-in ids always win, since they register first).
pub fn registerPlugin(self: *Host, plugin: *Plugin) !void {
    if (self.pluginById(plugin.id) != null) return error.DuplicatePluginId;
    try self.plugins.append(self.allocator, plugin);
}

/// Remove every contribution, service, and registry entry owned by `plugin`, then drop
/// the plugin itself. The inverse of `registerPlugin` + the `register*` calls a plugin
/// makes in its `register`. Used by the runtime unload path (the store's "disable" /
/// "uninstall"); built-in plugins are never unregistered.
///
/// **Ordering matters for the dylib case:** a contribution's `id`/`title` slices and the
/// `*Plugin` itself live in the plugin image's static memory. The caller must invoke
/// this *before* `dlclose`, so that the active-selection ids (which may point into that
/// image) are compared and reset while the memory is still mapped.
pub fn unregisterPlugin(self: *Host, plugin: *Plugin) void {
    removeOwned(Surface, &self.surfaces, plugin);
    removeOwned(MenuContribution, &self.menus, plugin);
    removeOwned(MenuSectionContribution, &self.menu_sections, plugin);
    removeOwned(OpenAction, &self.open_actions, plugin);
    removeOwned(RailItemContribution, &self.rail_items, plugin);
    removeOwned(accounts.Provider, &self.account_providers, plugin);
    removeOwned(NativeMenuItem, &self.native_menu_items, plugin);
    removeOwned(Command, &self.commands, plugin);
    removeOwned(LanguageSupport, &self.language_support, plugin);
    removeOwned(FileRowFillColor, &self.file_row_fill_colors, plugin);
    removeOwned(Painter, &self.painters, plugin);
    removeOwned(FileKind, &self.file_kinds, plugin);
    removeOwnedSettingsSchemas(&self.settings_schemas, plugin);
    if (self.fallback_editor == plugin) self.fallback_editor = null;

    // Services: drop this plugin's entries before its image goes away — both the vtable pointer
    // and the name string live in it.
    removeOwned(ServiceEntry, &self.services, plugin);

    // Drop the plugin from the registry (pointer identity; no `owner` field here).
    for (self.plugins.items, 0..) |p, i| {
        if (p == plugin) {
            _ = self.plugins.orderedRemove(i);
            break;
        }
    }

    // A selection may name a now-removed surface; drop it so the next frame falls back to a
    // still-registered one. Generic over every keyword group rather than the three that used to
    // have named fields — a fourth kind of region gets the same treatment for free.
    var it = self.selections.iterator();
    while (it.next()) |e| {
        const id = e.value_ptr.*;
        if (self.surfaceById(id) != null) continue;
        _ = self.selections.remove(e.key_ptr.*);
        it = self.selections.iterator();
    }
}

/// Compact a registry in place, dropping every entry whose `owner` is `plugin`.
/// `T` must have an `owner: ?*Plugin` field (all contribution structs do).
fn removeOwned(comptime T: type, list: *std.ArrayListUnmanaged(T), plugin: *Plugin) void {
    var w: usize = 0;
    for (list.items) |item| {
        const owned = if (item.owner) |o| o == plugin else false;
        if (!owned) {
            list.items[w] = item;
            w += 1;
        }
    }
    list.items.len = w;
}

/// `removeOwned`'s counterpart for `SettingsSchema`, whose `owner` is a required (non-optional)
/// `*Plugin` — every schema belongs to exactly one plugin, unlike fizzy-ownable
/// contribution structs `removeOwned` handles.
fn removeOwnedSettingsSchemas(list: *std.ArrayListUnmanaged(SettingsSchema), plugin: *Plugin) void {
    var w: usize = 0;
    for (list.items) |item| {
        if (item.owner != plugin) {
            list.items[w] = item;
            w += 1;
        }
    }
    list.items.len = w;
}

/// Lookup a registered plugin by stable id (`"pixi"`, `"workbench"`, …).
pub fn pluginById(self: *Host, id: []const u8) ?*Plugin {
    for (self.plugins.items) |plugin| {
        if (std.mem.eql(u8, plugin.id, id)) return plugin;
    }
    return null;
}

/// Broadcast an open document's in-memory content change to every registered plugin.
///
/// Called by the document's **owner** when its buffer settles after an edit — see
/// `Plugin.VTable.documentContentChanged` for the debouncing contract. This is how a plugin
/// that owns nothing (a link indexer, a word counter) sees unsaved text at all: nothing else
/// in the SDK exposes another plugin's live buffer.
///
/// The owner is included in the fan-out. That's deliberate — filtering it out would mean
/// owners behave differently from everyone else for no reason, and an owner that doesn't want
/// its own notification simply doesn't implement the hook.
pub fn notifyDocumentContentChanged(self: *Host, path: []const u8, bytes: []const u8) void {
    for (self.plugins.items) |plugin| plugin.documentContentChanged(path, bytes);
}

/// Broadcast a coalesced batch of on-disk changes under the open root folder to every plugin,
/// after applying it to the shared file set.
///
/// Called by `FolderWatcher.tick` on the UI thread, never from the watcher's own thread — see
/// `Plugin.VTable.folderPathsChanged` for the contract this upholds.
///
/// The file set is reconciled here rather than by whichever plugin happens to draw a tree: the
/// host owns both the watcher and the table, so no plugin should have to subscribe to disk
/// events just to keep shared state honest. A plugin's own hook is for what it *additionally*
/// wants to do with a change.
pub fn notifyFolderPathsChanged(self: *Host, changes: Plugin.PathChanges) void {
    if (self.files) |files| applyPathChanges(files, changes);
    for (self.plugins.items) |plugin| plugin.folderPathsChanged(changes);
}

/// Drop exactly the listings a batch of disk events invalidates.
///
/// Only the *parent* of each changed path is dropped: a file appearing in `a/b/c.md` says
/// nothing about `a`. A truncated batch means the event list is an incomplete picture, so the
/// whole cache goes instead.
fn applyPathChanges(files: *core.FileTable, changes: Plugin.PathChanges) void {
    if (changes.truncated) {
        files.invalidateListings();
        return;
    }

    for (changes.events) |event| {
        // A file's *contents* changing leaves every listing exactly as it was, and this is by
        // far the most common event there is — every save of every open document. Re-reading a
        // directory for it would put the full cost of a quarter-million-entry listing back on
        // the frame after each keystroke-triggered autosave. It can't be dropped outright
        // though: macOS reports a newly created file as `.modified` as well (see
        // `core.FileTable.noteFileModified`), so the listing is re-read when the name is one it
        // has never seen.
        if (event.kind == .modified and event.object == .file) {
            files.noteFileModified(event.path);
            continue;
        }

        if (std.fs.path.dirname(event.path)) |parent| files.invalidateListing(parent);
        // A rename's two halves can sit in different directories.
        if (event.old_path.len > 0) {
            if (std.fs.path.dirname(event.old_path)) |parent| files.invalidateListing(parent);
        }
        // A directory that itself appeared or vanished changes its own listing too. `.unknown`
        // is included deliberately: the object is already gone by the time fizzy looks, so it
        // could be either.
        if (event.object != .file) files.invalidateListing(event.path);
    }
}

/// First registered plugin that implements `createDocument` (for fizzy New File flows).
pub fn pluginWithCreateDocument(self: *Host) ?*Plugin {
    for (self.plugins.items) |plugin| {
        if (plugin.vtable.createDocument != null) return plugin;
    }
    return null;
}

pub fn registerFileRowFillColor(self: *Host, resolver: FileRowFillColor) !void {
    try self.file_row_fill_colors.append(self.allocator, resolver);
}

/// First non-null tint from registered resolvers, or null for the workbench theme default.
pub fn fileRowFillColor(self: *Host, color_index: usize) ?dvui.Color {
    for (self.file_row_fill_colors.items) |resolver| {
        if (resolver.color(resolver.ctx, color_index)) |color| return color;
    }
    return null;
}

/// Declare `plugin` the fallback editor: the owner of every extension no other plugin owns
/// and the user has not assigned elsewhere. Called once, from that plugin's own `register` —
/// exactly one plugin (`text`) has any business calling it.
///
/// A second caller is a plugin-author bug, not a user-facing conflict: the last registration
/// silently wins. Deliberately an opt-in call rather than a `Plugin` field, since the concept
/// is meaningless to every other plugin author (same shape as `registerPainter` below).
pub fn registerFallbackEditor(self: *Host, plugin: *Plugin) void {
    self.fallback_editor = plugin;
}

/// Declare what kinds of file this plugin recognises. Prefer this over `registerPainter`: it
/// leaves the look to the app, and makes the tree and the tab bar agree by construction.
pub fn registerFileKind(self: *Host, k: FileKind) !void {
    try self.file_kinds.append(self.allocator, k);
}

/// The kind declared for `ext`, or null when nothing claims it.
pub fn fileKind(self: *Host, ext: []const u8) ?[]const u8 {
    for (self.file_kinds.items) |k| {
        if (k.kind(k.ctx, ext)) |found| return found;
    }
    return null;
}

/// Draw a plugin-provided visual. The escape hatch for content-derived artwork — a sprite
/// thumbnail, an image preview — where the plugin genuinely must draw rather than name a kind.
pub fn registerPainter(self: *Host, drawer: Painter) !void {
    try self.painters.append(self.allocator, drawer);
}

/// Draw the file-tree row icon for `ext`/`path`.
///
/// Order (first success wins):
/// 1. Language plugin that claims the extension (tree-sitter or preview) → that plugin's logo
/// 2. Explicit `registerPainter` drawers (pixi sprites, image glyph, text code glyph, …)
/// 3. Specialized document owner (offers `ext` via `fileTypes`, i.e. not the fallback editor)
///    → that plugin's logo
///
/// Returns false when nothing claimed it — caller draws a generic filesystem default.
/// **Caller must reserve a `core.widgets.treeRowGlyph` slot**; drawers use `expand = .ratio`.
pub fn drawFileIcon(self: *Host, ext: []const u8, path: []const u8, color: dvui.Color) bool {
    // Language plugins (zig, json, markdown, …) own the identity of their formats even when
    // `text` owns the document — prefer their logo over the generic code glyph.
    for (self.language_support.items) |*ls| {
        const owner = ls.owner orelse continue;
        var claimed = false;
        if (ls.vtable.treeSitterHighlight) |hook| {
            if (hook(owner.state, ext) != null) claimed = true;
        }
        if (!claimed) {
            if (ls.vtable.supportsPreview) |supports| {
                if (supports(owner.state, ext)) claimed = true;
            }
        }
        if (!claimed) continue;
        if (self.drawPluginIcon(owner.id)) return true;
    }

    // Painters first: they are the escape hatch for content-derived artwork (a sprite
    // thumbnail, an image preview), which should win over a generic per-kind glyph.
    for (self.painters.items) |drawer| {
        if (drawer.draw(drawer.ctx, .{ .file = .{ .ext = ext, .path = path, .color = color } })) return true;
    }

    // Then the declared kind, drawn by the *app*. This is the common path: a plugin says
    // `.png` is an "image", fizzy decides what an image looks like.
    if (self.fileKind(ext)) |kind| {
        if (self.fizzy_api) |a| {
            if (a.drawFileKindGlyph(kind, color)) return true;
        }
    }

    // Specialized document plugins (pixi, image, …) that didn't register a Painter
    // still get their logo when they uniquely claim the extension.
    if (self.pluginForExtension(ext)) |p| {
        if (p != self.fallback_editor) {
            if (self.drawPluginIcon(p.id)) return true;
        }
    }
    return false;
}

/// Register `plugin`'s settings schema (see `settings.zig`'s `make(T).register`). Typically
/// called once from a plugin's `register(host)`, after loading its persisted values.
pub fn registerSettingsSchema(self: *Host, schema: SettingsSchema) !void {
    try self.settings_schemas.append(self.allocator, schema);
}

/// Draw the plugin-store card logo for `plugin_id` via the registered drawer owned by that
/// plugin. Returns true if a loaded plugin drew its logo; false means the caller should draw
/// a generic default.
pub fn drawPluginIcon(self: *Host, plugin_id: []const u8) bool {
    for (self.painters.items) |drawer| {
        const owner = drawer.owner orelse continue;
        if (!std.mem.eql(u8, owner.id, plugin_id)) continue;
        if (drawer.draw(drawer.ctx, .plugin_logo)) return true;
    }
    return false;
}

/// Register a service under `T`'s declared name and version.
///
/// A service is how capability crosses the plugin boundary in *both* directions: an app offers
/// one for plugins to call (fizzy's `"workbench"`), and a plugin registers one for the app to
/// call back into (a hook the app defined). Nothing about it rides the SDK fingerprint, which is
/// the point — a downstream app can invent services its plugins use without fizzy knowing the
/// type exists, and adding one costs nobody a rebuild.
///
/// `owner` is the contributing plugin, so `unregisterPlugin` can drop the entry before the image
/// it points into is closed. Null for one the application itself provides.
pub fn registerService(self: *Host, comptime T: type, impl: *T, owner: ?*Plugin) !void {
    try self.services.append(self.allocator, .{
        .name = T.service_name,
        .ptr = impl,
        .version = serviceVersion(T),
        .owner = owner,
    });
}

/// Set false to silence the version-mismatch warning. Exists for the test that asserts the
/// refusal itself: the run fails on any log output, and the warning is the *symptom* being
/// tested, not the assertion.
pub var warn_on_service_mismatch: bool = true;

/// The version `T` declares, or 0 for a service that declares none.
///
/// Zero is not a free pass: it means "unversioned", it only matches other unversioned providers,
/// and every service in this SDK declares one. It exists so a service written before versioning
/// still resolves against itself rather than failing in a way its author cannot read.
fn serviceVersion(comptime T: type) u32 {
    return if (@hasDecl(T, "service_version")) T.service_version else 0;
}

/// The first provider of `name`, untyped. Prefer `getServiceTyped`, which checks the version.
pub fn getService(self: *Host, name: []const u8) ?*anyopaque {
    for (self.services.items) |e| {
        if (std.mem.eql(u8, e.name, name)) return e.ptr;
    }
    return null;
}

/// Typed service lookup. `T` must declare `service_name`; it should declare `service_version`.
///
/// Returns null when nothing provides the service **or** when the provider's version differs
/// from `T`'s — a mismatch is logged and refused rather than cast, because the two sides are
/// separate compilations and the wrong layout reinterpreted through a vtable is undebuggable.
/// A caller must handle null anyway: a service is optional by construction, and a plugin that
/// cannot find one should offer what it can rather than fail to load.
pub fn getServiceTyped(self: *Host, comptime T: type) ?*T {
    const want = serviceVersion(T);
    for (self.services.items) |e| {
        if (!std.mem.eql(u8, e.name, T.service_name)) continue;
        if (e.version != want) {
            // `warn`, not `err`: the caller has to handle null anyway — a service is optional by
            // construction — so this is a capability the plugin does without, not a fault the
            // app cannot continue past. It is still worth saying out loud, because the symptom
            // on the other side is a feature quietly missing.
            if (warn_on_service_mismatch) dvui.log.warn(
                "service '{s}': provider is version {d}, caller wants {d} — refusing",
                .{ T.service_name, e.version, want },
            );
            continue;
        }
        return @ptrCast(@alignCast(e.ptr));
    }
    return null;
}

/// Every provider of `T`, in registration order — the hook form. An app that defines a hook
/// calls this and invokes each implementation; a service with exactly one provider is just the
/// common case of the same thing.
///
/// The slice is the host's own storage: valid until the next registration or plugin unload, so
/// call it, walk it, and do not keep it.
pub fn servicesNamed(self: *Host, comptime T: type, buf: []*T) []*T {
    const want = serviceVersion(T);
    var n: usize = 0;
    for (self.services.items) |e| {
        if (n == buf.len) break;
        if (!std.mem.eql(u8, e.name, T.service_name)) continue;
        if (e.version != want) {
            if (warn_on_service_mismatch) dvui.log.warn(
                "service '{s}': provider is version {d}, caller wants {d} — skipping",
                .{ T.service_name, e.version, want },
            );
            continue;
        }
        buf[n] = @ptrCast(@alignCast(e.ptr));
        n += 1;
    }
    return buf[0..n];
}

// ---- region registration (called from a plugin's register / postInit) -------

/// Register a surface: a named drawable plus the keywords describing what kind of place its
/// content belongs. The app's layout decides where that lands; see `sdk/src/surface.zig`.
pub fn registerSurface(self: *Host, s: Surface) !void {
    try self.surfaces.append(self.allocator, s);
}

/// Remove a surface by id. Surfaces are registration data for a plugin's fixed panels, but a
/// document is a surface that exists exactly while its file is open — so the app registers one
/// per open file and takes it back here on close. Selections and assignments naming the id are
/// left alone: an assignment to a document that is not open is how a session is restored.
pub fn unregisterSurface(self: *Host, id: []const u8) void {
    for (self.surfaces.items, 0..) |*s, i| {
        if (std.mem.eql(u8, s.id, id)) {
            _ = self.surfaces.orderedRemove(i);
            return;
        }
    }
}

/// Runtime visibility, not registration data — the plugin store toggles a built-in without
/// unloading it.
pub fn setSurfaceHidden(self: *Host, id: []const u8, hidden: bool) void {
    for (self.surfaces.items) |*s| {
        if (std.mem.eql(u8, s.id, id)) {
            s.hidden = hidden;
            return;
        }
    }
}

/// Swap two surfaces' positions in the registry, by id. Registration order is the order they
/// appear in a chooser, so this is how a tab drag persists a reorder.
pub fn swapSurfaces(self: *Host, a_id: []const u8, b_id: []const u8) void {
    var ai: ?usize = null;
    var bi: ?usize = null;
    for (self.surfaces.items, 0..) |*s, i| {
        if (std.mem.eql(u8, s.id, a_id)) ai = i;
        if (std.mem.eql(u8, s.id, b_id)) bi = i;
    }
    const a = ai orelse return;
    const b = bi orelse return;
    if (a == b) return;
    const tmp = self.surfaces.items[a];
    self.surfaces.items[a] = self.surfaces.items[b];
    self.surfaces.items[b] = tmp;
}

pub fn surfaceById(self: *Host, id: []const u8) ?*Surface {
    for (self.surfaces.items) |*s| if (std.mem.eql(u8, s.id, id)) return s;
    return null;
}

/// The surface a keyword group currently shows: the user's selection if it still exists,
/// otherwise the first visible match — so a region never goes blank because the plugin that
/// owned the selected surface unloaded.
///
/// One function for every kind of region, rather than one per region the app happens to have.
pub fn selectedSurface(self: *Host, kw: []const []const u8) ?*Surface {
    if (self.selectionFor(kw)) |id| {
        if (self.surfaceById(id)) |s| if (!s.hidden) return s;
    }
    for (self.surfaces.items) |*s| {
        if (s.hidden) continue;
        if (keywords.accepts(kw, s.keywords)) return s;
    }
    return null;
}

/// True when some surface matching `kw` asks to stay visible with no document open — the bottom
/// panel's `persistent`, generalized.
pub fn hasPersistentSurface(self: *Host, kw: []const []const u8) bool {
    for (self.surfaces.items) |*s| {
        if (s.persistent and keywords.accepts(kw, s.keywords)) return true;
    }
    return false;
}

pub fn registerMenu(self: *Host, menu: MenuContribution) !void {
    try self.menus.append(self.allocator, menu);
}

pub fn registerMenuSection(self: *Host, section: MenuSectionContribution) !void {
    try self.menu_sections.append(self.allocator, section);
}

/// Put something small at the bottom of the rail — see `RailItemContribution`.
pub fn registerRailItem(self: *Host, item: RailItemContribution) !void {
    try self.rail_items.append(self.allocator, item);
}

/// Add a way to open something beside Open Folder / Open Files — see `OpenAction`.
pub fn registerOpenAction(self: *Host, action: OpenAction) !void {
    try self.open_actions.append(self.allocator, action);
}

/// Whether `action` should be listed right now: not hidden, and its command enabled.
pub fn openActionShown(self: *Host, action: OpenAction) bool {
    return !action.hidden and self.commandEnabled(action.command);
}

/// Tell the host about a service the user can be signed in to — see `accounts.Provider`. The
/// host draws the account disc in the rail and lists every provider's accounts in one menu.
pub fn registerAccountProvider(self: *Host, provider: accounts.Provider) !void {
    try self.account_providers.append(self.allocator, provider);
}

/// Register a native-menu leaf item; see `NativeMenuItem`. No-op on platforms with
/// no native menu builder (the registry entry just sits unread).
pub fn registerNativeMenuItem(self: *Host, item: NativeMenuItem) !void {
    try self.native_menu_items.append(self.allocator, item);
}

// ---- commands --------------------------------------------------------------

/// Register a plugin command. Ids should be plugin-namespaced (`"pixi.packProject"`).
pub fn registerCommand(self: *Host, cmd: Command) !void {
    try self.commands.append(self.allocator, cmd);
}

/// The registered command with `id`, or null.
pub fn command(self: *Host, id: []const u8) ?*Command {
    for (self.commands.items) |*c| {
        if (std.mem.eql(u8, c.id, id)) return c;
    }
    return null;
}

/// Whether `id` is registered at all, regardless of its current enabled state.
pub fn hasCommand(self: *Host, id: []const u8) bool {
    return self.command(id) != null;
}

/// Whether `id` is registered and currently enabled (absent `isEnabled` = enabled).
/// Unknown ids are treated as disabled.
pub fn commandEnabled(self: *Host, id: []const u8) bool {
    const c = self.command(id) orelse return false;
    const owner = c.owner orelse return true;
    return if (c.isEnabled) |f| f(owner.state) else true;
}

/// Run the command `id` (no-op when unknown). The owner's opaque `state` is passed to `run`.
pub fn runCommand(self: *Host, id: []const u8) !void {
    const c = self.command(id) orelse return;
    const owner = c.owner orelse return;
    try c.run(owner.state);
}

// ---- language support ------------------------------------------------------

/// Register a language/format support provider (syntax highlighting and/or preview pane).
pub fn registerLanguageSupport(self: *Host, ls: LanguageSupport) !void {
    try self.language_support.append(self.allocator, ls);
}

/// Tree-sitter highlighting for `ext`, or null when no provider claims it.
pub fn treeSitterHighlightFor(self: *Host, ext: []const u8) ?TreeSitterHighlight {
    for (self.language_support.items) |*ls| {
        const hook = ls.vtable.treeSitterHighlight orelse continue;
        const owner = ls.owner orelse continue;
        if (hook(owner.state, ext)) |ts| return ts;
    }
    return null;
}

/// The first provider whose preview hook accepts `ext`, or null.
pub fn previewProviderFor(self: *Host, ext: []const u8) ?*LanguageSupport {
    for (self.language_support.items) |*ls| {
        if (ls.vtable.previewPane == null) continue;
        const owner = ls.owner orelse continue;
        if (ls.vtable.supportsPreview) |supports| {
            if (!supports(owner.state, ext)) continue;
        }
        return ls;
    }
    return null;
}

/// Notify every language provider that a document was opened/reloaded. Providers gate on
/// `ext` themselves (see `LanguageSupport.VTable.documentOpened`). Non-blocking.
pub fn documentOpenedFor(self: *Host, ext: []const u8, path: []const u8, bytes: []const u8) void {
    for (self.language_support.items) |*ls| {
        const hook = ls.vtable.documentOpened orelse continue;
        const owner = ls.owner orelse continue;
        hook(owner.state, ext, path, bytes);
    }
}

/// Non-blocking hover lookup: the first provider with a cached/ready hover result for
/// `byte_offset` in `bytes` (the document at `path`), or null. See
/// `LanguageSupport.VTable.hover`.
pub fn hoverFor(self: *Host, ext: []const u8, path: []const u8, bytes: []const u8, byte_offset: usize) ?language.HoverResult {
    for (self.language_support.items) |*ls| {
        const hook = ls.vtable.hover orelse continue;
        const owner = ls.owner orelse continue;
        if (hook(owner.state, ext, path, bytes, byte_offset)) |r| return r;
    }
    return null;
}

/// The first provider that resolves a definition for `byte_offset` in `bytes` (the document
/// at `path`), or null. May block briefly — see `LanguageSupport.VTable.gotoDefinition`.
pub fn gotoDefinitionFor(self: *Host, ext: []const u8, path: []const u8, bytes: []const u8, byte_offset: usize) ?language.DefinitionLocation {
    for (self.language_support.items) |*ls| {
        const hook = ls.vtable.gotoDefinition orelse continue;
        const owner = ls.owner orelse continue;
        if (hook(owner.state, ext, path, bytes, byte_offset)) |loc| return loc;
    }
    return null;
}

/// Non-blocking inline-completion lookup: the first provider with a cached/ready suggestion
/// for the cursor at `byte_offset` in `bytes` (the document at `path`), or null. See
/// `LanguageSupport.VTable.completion`.
pub fn completionFor(self: *Host, ext: []const u8, path: []const u8, bytes: []const u8, byte_offset: usize) ?[]const language.CompletionItem {
    for (self.language_support.items) |*ls| {
        const hook = ls.vtable.completion orelse continue;
        const owner = ls.owner orelse continue;
        if (hook(owner.state, ext, path, bytes, byte_offset)) |items| return items;
    }
    return null;
}

/// Non-blocking completion-documentation resolve: the first provider with a cached/ready
/// resolved documentation string for candidate `index` from the completion result at
/// `byte_offset` in `bytes` (the document at `path`), or null. See
/// `LanguageSupport.VTable.resolveCompletionDocumentation`.
pub fn resolveCompletionDocumentationFor(self: *Host, ext: []const u8, path: []const u8, bytes: []const u8, byte_offset: usize, index: usize) ?[]const u8 {
    for (self.language_support.items) |*ls| {
        const hook = ls.vtable.resolveCompletionDocumentation orelse continue;
        const owner = ls.owner orelse continue;
        if (hook(owner.state, ext, path, bytes, byte_offset, index)) |text| return text;
    }
    return null;
}

/// Non-blocking signature-help lookup: the first provider with a cached/ready result for the
/// call the cursor at `byte_offset` in `bytes` (the document at `path`) currently sits inside,
/// or null. See `LanguageSupport.VTable.signatureHelp`.
pub fn signatureHelpFor(self: *Host, ext: []const u8, path: []const u8, bytes: []const u8, byte_offset: usize) ?language.SignatureHelpResult {
    for (self.language_support.items) |*ls| {
        const hook = ls.vtable.signatureHelp orelse continue;
        const owner = ls.owner orelse continue;
        if (hook(owner.state, ext, path, bytes, byte_offset)) |result| return result;
    }
    return null;
}

/// Whether any registered provider can format `ext` — non-blocking, safe to call every frame
/// to decide whether to show/enable a "Format Document" affordance. See
/// `LanguageSupport.VTable.supportsFormat`.
pub fn canFormatExt(self: *Host, ext: []const u8) bool {
    for (self.language_support.items) |*ls| {
        const hook = ls.vtable.supportsFormat orelse continue;
        const owner = ls.owner orelse continue;
        if (hook(owner.state, ext)) return true;
    }
    return false;
}

/// The first provider that returns reformatted text for `bytes` (the document at `path`), or
/// null. May block briefly — see `LanguageSupport.VTable.format`.
pub fn formatFor(self: *Host, ext: []const u8, path: []const u8, bytes: []const u8) ?[]const u8 {
    for (self.language_support.items) |*ls| {
        const hook = ls.vtable.format orelse continue;
        const owner = ls.owner orelse continue;
        if (hook(owner.state, ext, path, bytes)) |text| return text;
    }
    return null;
}

// ---- active selection ------------------------------------------------------

/// The surface id selected for `keywords`, or null if nothing has been chosen yet.
pub fn selectionFor(self: *Host, kw: []const []const u8) ?[]const u8 {
    return self.selections.get(keywords.groupKey(kw));
}

/// Choose the surface for `keywords`. Regions written with the same keywords share this, which
/// is how a chooser and the region it chooses for stay in step with nothing wired between them.
pub fn setSelectionFor(self: *Host, kw: []const []const u8, id: []const u8) void {
    self.setSelectionForKey(keywords.groupKey(kw), id);
}

/// The same map under an arbitrary key — how a region that resolves by name rather than by
/// keyword group (a plugin's document panes) keeps a selection of its own. The app computes
/// the key (`Region.selectionKey`); nothing else should.
pub fn selectionForKey(self: *Host, key: u64) ?[]const u8 {
    return self.selections.get(key);
}

pub fn setSelectionForKey(self: *Host, key: u64, id: []const u8) void {
    // Store the registry pointer, never a frame-arena copy. A view-drag
    // used to hand an arena id to a new split; the next frame's `pick`
    // then compared against freed bytes.
    const stable = if (self.surfaceById(id)) |s| s.id else return;
    self.selections.put(self.allocator, key, stable) catch {};
}

/// Whether `plugin` may legitimately own `ext`: it either offers `ext` via `fileTypes`, or it
/// is the registered fallback editor (which owns anything, `fileTypes` notwithstanding). Used
/// to validate a persisted assignment before honoring it — a plugin that dropped support for an
/// extension since the user assigned it no longer owns it.
pub fn ownsExtension(self: *Host, plugin: *Plugin, ext: []const u8) bool {
    for (plugin.fileTypes()) |e| {
        if (std.ascii.eqlIgnoreCase(e, ext)) return true;
    }
    return plugin == self.fallback_editor;
}

/// `ext` lowercased into `buf`, so `.JPG` resolves like `.jpg`: plugins declare lowercase
/// extensions and the user's `.extensions` record is keyed the same way. An extension too long
/// for the buffer matches nothing anyway and is returned as is.
pub fn lowerExtension(buf: *[64]u8, ext: []const u8) []const u8 {
    if (ext.len > buf.len) return ext;
    return std.ascii.lowerString(buf, ext);
}

/// The plugin that opens files with extension `ext` (including the dot, `""` for none), or
/// null if nothing can. Fully deterministic and non-numeric — a plugin cannot outrank another
/// by declaring a smaller number, because there are no numbers:
///
///   1. The user's persisted assignment for `ext`, if its owner is loaded and still owns it.
///   2. Otherwise the unique remaining plugin offering `ext` via `fileTypes`. Two or more
///      offers with no assignment is a genuine ambiguity that the install-time dialog should
///      already have caught; as a safety net, pick the alphabetically-first id so the result
///      never depends on dylib load/scan order. Nothing is written to disk here.
///   3. Otherwise the registered fallback editor.
pub fn pluginForExtension(self: *Host, raw_ext: []const u8) ?*Plugin {
    var buf: [64]u8 = undefined;
    const ext = lowerExtension(&buf, raw_ext);
    if (self.fizzy_api) |a| {
        if (a.extensionOwnerOverride(ext)) |owner_id| {
            if (self.pluginById(owner_id)) |p| {
                if (self.ownsExtension(p, ext)) return p;
            }
        }
    }

    var best: ?*Plugin = null;
    for (self.plugins.items) |plugin| {
        for (plugin.fileTypes()) |e| {
            if (std.mem.eql(u8, e, ext)) {
                if (best == null or std.mem.lessThan(u8, plugin.id, best.?.id)) best = plugin;
                break;
            }
        }
    }
    if (best) |p| return p;

    return self.fallback_editor;
}

/// Whether `plugin` should appear in the New File flow.
///
/// Two ways to qualify, because "can create a new document" and "owns documents" are not the
/// same claim. A document owner (`createDocument`) creates one it will then own. A *utility*
/// plugin (`assertUtilityVTable` forbids it `createDocument`) can still offer a New Document
/// entry by implementing only `requestNewDocumentDialog` — atlas creating a `.md` note that the
/// text plugin goes on to own is the case this exists for. Gating on `createDocument` alone shut
/// those out of the chooser entirely.
fn offersNewDocument(plugin: *const Plugin) bool {
    return plugin.vtable.createDocument != null or plugin.vtable.requestNewDocumentDialog != null;
}

/// Open a "new document" flow. `parent_path` (when set) targets an on-disk folder; `id_extra`
/// disambiguates launches from distinct explorer rows.
///
/// With no plugin offering one (`offersNewDocument`), this is a no-op — nothing can create a
/// file. With exactly one, it's dispatched to directly — its own dialog if it has one (e.g.
/// `pixi`), or straight to an untitled in-memory document if not (e.g. the bundled `text`
/// fallback editor). With two or more, which plugin should handle the new file is ambiguous, so
/// a picker (`showNewDocumentChooser`) is shown first; the user's choice is then dispatched the
/// same way a lone candidate would be.
pub fn requestNewDocument(self: *Host, parent_path: ?[]const u8, id_extra: usize) void {
    var only: ?Candidate = null;
    var count: usize = 0;
    var it = self.newDocumentCandidates();
    while (it.next()) |c| {
        count += 1;
        if (only == null) only = c;
    }

    if (count >= 2) {
        showNewDocumentChooser(parent_path, id_extra);
        return;
    }

    const single = only orelse return;
    self.dispatchNewDocumentToPlugin(single.plugin, single.kind, parent_path, id_extra);
}

/// One entry in the New File flow: a plugin, and which of its kinds this entry stands for.
/// A plugin that declares no kinds contributes exactly one entry with `kind == null`.
pub const Candidate = struct {
    plugin: *Plugin,
    kind: ?Plugin.NewDocumentKind = null,
};

/// Walks every plugin that offers a new document, expanded by kind — so a plugin offering a
/// sprite and a palette is two entries, and the chooser asks what to make rather than who
/// should make it. Ordered by plugin registration, then by the plugin's own kind order.
pub fn newDocumentCandidates(self: *Host) CandidateIterator {
    return .{ .host = self };
}

pub const CandidateIterator = struct {
    host: *Host,
    plugin_index: usize = 0,
    kind_index: usize = 0,

    pub fn next(self: *CandidateIterator) ?Candidate {
        while (self.plugin_index < self.host.plugins.items.len) {
            const plugin = self.host.plugins.items[self.plugin_index];
            if (!offersNewDocument(plugin)) {
                self.plugin_index += 1;
                continue;
            }
            const kinds = plugin.newDocumentKinds();
            if (kinds.len == 0) {
                self.plugin_index += 1;
                return .{ .plugin = plugin };
            }
            if (self.kind_index < kinds.len) {
                const kind = kinds[self.kind_index];
                self.kind_index += 1;
                return .{ .plugin = plugin, .kind = kind };
            }
            self.plugin_index += 1;
            self.kind_index = 0;
        }
        return null;
    }
};

/// Hand the "new document" flow to a specific plugin: its own dialog if it has one, otherwise
/// straight to an untitled in-memory document. `owner` must satisfy `offersNewDocument` (the
/// only two callers — `requestNewDocument`'s single-candidate path and the chooser dialog's
/// button handler — both filter on that already).
fn dispatchNewDocumentToPlugin(self: *Host, owner: *Plugin, kind: ?Plugin.NewDocumentKind, parent_path: ?[]const u8, id_extra: usize) void {
    // Only claim the pending slot for a plugin that can actually take the document back: it
    // exists to disambiguate a later `host.createDocument(path, grid)`, and a utility plugin
    // never makes that call. Leaving a stale owner parked here would misroute the *next*
    // create — the one a different plugin makes — to a plugin with no `createDocument` at all.
    self.pending_new_document_owner = if (owner.vtable.createDocument != null) owner else null;

    if (owner.vtable.requestNewDocumentDialog) |f| {
        f(owner.state, if (kind) |k| k.id else null, parent_path, id_extra);
        return;
    }
    self.createUntitledDocumentDirect(parent_path) catch |err| {
        dvui.log.err("New File: {s}", .{@errorName(err)});
    };
}

/// True if the chooser is already showing (guards repeated hotkey presses / menu clicks from
/// stacking duplicate pickers), mirroring `AboutFizzy.active`.
fn newDocumentChooserActive(win: *dvui.Window) bool {
    var it = win.dialogs.iterator(null);
    while (it.next()) |d| {
        const df = dvui.dataGet(null, d.id, "_displayFn", core.dialogs.DisplayFn) orelse continue;
        if (df == newDocumentChooserDisplay) return true;
    }
    return false;
}

/// Modal picker shown when more than one plugin can create a new document: a rounded-square,
/// drop-shadowed button per candidate (its registered plugin-store icon, falling back to its
/// name) via `core.dialogs.dialog` — the same chrome every other fizzy dialog uses. Picking one
/// dispatches exactly as `requestNewDocument` would with a single candidate.
fn showNewDocumentChooser(parent_path: ?[]const u8, id_extra: usize) void {
    if (newDocumentChooserActive(dvui.currentWindow())) return;
    var mutex = core.dialogs.dialog(@src(), .{
        .displayFn = newDocumentChooserDisplay,
        .title = "New File",
        .ok_label = "",
        .cancel_label = "",
        .resizeable = false,
        .default = .cancel,
        .hide_footer = true,
    });
    dvui.dataSet(null, mutex.id, "_nf_id_extra", id_extra);
    dvui.dataSet(null, mutex.id, "_nf_has_parent", parent_path != null);
    if (parent_path) |p| dvui.dataSetSlice(null, mutex.id, "_nf_parent_path", p);
    mutex.mutex.unlock(dvui.io);
}

fn newDocumentChooserDisplay(id: dvui.Id) anyerror!bool {
    const host = runtime.host();
    const id_extra = dvui.dataGet(null, id, "_nf_id_extra", usize) orelse 0;
    const has_parent = dvui.dataGet(null, id, "_nf_has_parent", bool) orelse false;
    const parent_path: ?[]const u8 = if (has_parent) dvui.dataGetSlice(null, id, "_nf_parent_path", []u8) else null;

    var outer = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .all(12) });
    defer outer.deinit();

    var any_kind = false;
    {
        var probe = host.newDocumentCandidates();
        while (probe.next()) |c| {
            if (c.kind != null) {
                any_kind = true;
                break;
            }
        }
    }
    dvui.labelNoFmt(
        @src(),
        if (any_kind) "What would you like to create?" else "Which plugin should create the file?",
        .{},
        .{ .font = dvui.Font.theme(.body) },
    );
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 16 } });

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .gravity_x = 0.5 });
    defer row.deinit();

    var index: usize = 0;
    var it = host.newDocumentCandidates();
    while (it.next()) |candidate| : (index += 1) {
        var cell = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = index, .margin = .all(6) });
        defer cell.deinit();

        if (newDocumentChooserButton(host, candidate, index)) {
            host.dispatchNewDocumentToPlugin(candidate.plugin, candidate.kind, parent_path, id_extra);
            core.dialogs.closeFloatingDialogAnchored();
        }

        _ = dvui.spacer(@src(), .{ .id_extra = index, .min_size_content = .{ .w = 1, .h = 6 } });
        dvui.labelNoFmt(@src(), if (candidate.kind) |k| k.title else candidate.plugin.display_name, .{}, .{
            .id_extra = index,
            .gravity_x = 0.5,
            .font = dvui.Font.theme(.body),
        });
    }

    return true;
}

/// One candidate's rounded-square, drop-shadowed icon button (matches the plugin-store card
/// aesthetic). Falls back to a large initial-letter monogram when the plugin has no registered
/// store icon — the name itself is already shown in the caption label below the button, so
/// repeating it inside the button too would just be the same text twice.
fn newDocumentChooserButton(host: *Host, candidate: Candidate, index: usize) bool {
    const plugin = candidate.plugin;
    const theme = dvui.themeGet();
    const size: f32 = 64;

    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{}, .{
        .id_extra = index,
        .min_size_content = .{ .w = size, .h = size },
        .padding = .all(10),
        .corners = dvui.CornerRect.all(12),
        .background = true,
        .color_fill = .{ .color = theme.color(.content, .fill) },
        .color_fill_hover = .{ .color = theme.color(.control, .fill).opacity(0.5) },
        .color_fill_press = .{ .color = theme.color(.control, .fill_press) },
        .box_shadow = .{
            .color = .black,
            .corners = dvui.CornerRect.all(12),
            .fade = 6,
            .alpha = 0.25,
            .offset = .{ .x = 0, .y = 2 },
        },
    });
    defer bw.deinit();
    bw.processEvents();
    bw.drawFocus();
    bw.drawBackground();

    const drew_kind_icon = if (candidate.kind) |k| blk: {
        const bytes = k.icon orelse break :blk false;
        core.icon.icon(@src(), k.id, bytes, .{}, .{
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 32, .h = 32 },
            .color_text = .{ .color = dvui.themeGet().color(.window, .text) },
        });
        break :blk true;
    } else false;

    if (!drew_kind_icon and !host.drawPluginIcon(plugin.id)) {
        const initial = [1]u8{if (plugin.display_name.len > 0) std.ascii.toUpper(plugin.display_name[0]) else '?'};
        dvui.labelNoFmt(@src(), &initial, .{}, .{
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .font = dvui.Font.theme(.title).larger(16.0),
            .color_text = .{ .color = theme.color(.window, .text) },
        });
    }

    return bw.clicked();
}

fn createUntitledDocumentDirect(self: *Host, parent_path: ?[]const u8) !void {
    const base = try self.allocUntitledPath();
    defer self.allocator.free(base);
    const path = if (parent_path) |p| try std.fs.path.join(self.allocator, &.{ p, base }) else base;
    defer if (parent_path != null) self.allocator.free(path);
    // `grid` is a pixel-art-only concept; the plugin that actually creates the document
    // (`text`, here) ignores it entirely.
    _ = try self.createDocument(path, .{ .column_width = 0, .row_height = 0 });
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

test "pluginForExtension resolves by assignment, unique claimant, then fallback" {
    const imageTypes = struct {
        fn f(_: *anyopaque) []const []const u8 {
            return &.{ ".png", ".jpg" };
        }
    }.f;
    const pixiTypes = struct {
        fn f(_: *anyopaque) []const []const u8 {
            return &.{ ".fiz", ".png" };
        }
    }.f;

    var host = Host.init(testing.allocator);
    defer host.deinit();

    const image_vt = Plugin.VTable{ .fileTypes = imageTypes };
    const pixi_vt = Plugin.VTable{ .fileTypes = pixiTypes };
    const text_vt = Plugin.VTable{};
    var image = Plugin{ .state = undefined, .vtable = &image_vt, .id = "image", .display_name = "Image" };
    var pixi = Plugin{ .state = undefined, .vtable = &pixi_vt, .id = "pixi", .display_name = "Pixi" };
    var text = Plugin{ .state = undefined, .vtable = &text_vt, .id = "text", .display_name = "Text" };

    // No fallback editor registered yet: an unclaimed extension resolves to nothing.
    try host.registerPlugin(&image);
    try testing.expectEqual(@as(?*Plugin, null), host.pluginForExtension(".zig"));

    host.registerFallbackEditor(&text);
    try host.registerPlugin(&text);

    // Unique claimant wins; everything else falls to the fallback editor.
    try testing.expectEqual(&image, host.pluginForExtension(".png").?);
    try testing.expectEqual(&text, host.pluginForExtension(".zig").?);
    try testing.expectEqual(&text, host.pluginForExtension("").?);

    // Two claimants, no user assignment: deterministic alphabetical tie-break, never load order.
    try host.registerPlugin(&pixi);
    try testing.expectEqual(&image, host.pluginForExtension(".png").?);
    try testing.expectEqual(&pixi, host.pluginForExtension(".fiz").?);

    // `ownsExtension`: offered extensions, plus anything for the fallback editor.
    try testing.expect(host.ownsExtension(&pixi, ".fiz"));
    try testing.expect(!host.ownsExtension(&image, ".fiz"));
    try testing.expect(host.ownsExtension(&text, ".anything"));

    // Unregistering the fallback editor clears it, so unclaimed extensions resolve to nothing.
    host.unregisterPlugin(&text);
    try testing.expectEqual(@as(?*Plugin, null), host.fallback_editor);
    try testing.expectEqual(@as(?*Plugin, null), host.pluginForExtension(".zig"));
}

test "pluginForExtension honors a user assignment and ignores a stale one" {
    const Fake = struct {
        var override: ?[]const u8 = null;

        fn extensionOwnerOverride(_: *anyopaque, ext: []const u8) ?[]const u8 {
            // Only `.png` is ever assigned in this test.
            return if (std.mem.eql(u8, ext, ".png")) override else null;
        }
        fn imageTypes(_: *anyopaque) []const []const u8 {
            return &.{".png"};
        }
        fn pixiTypes(_: *anyopaque) []const []const u8 {
            return &.{".fiz"}; // deliberately does NOT offer .png
        }
    };

    var host = Host.init(testing.allocator);
    defer host.deinit();

    const image_vt = Plugin.VTable{ .fileTypes = Fake.imageTypes };
    const pixi_vt = Plugin.VTable{ .fileTypes = Fake.pixiTypes };
    const text_vt = Plugin.VTable{};
    var image = Plugin{ .state = undefined, .vtable = &image_vt, .id = "image", .display_name = "Image" };
    var pixi = Plugin{ .state = undefined, .vtable = &pixi_vt, .id = "pixi", .display_name = "Pixi" };
    var text = Plugin{ .state = undefined, .vtable = &text_vt, .id = "text", .display_name = "Text" };
    try host.registerPlugin(&image);
    try host.registerPlugin(&pixi);
    try host.registerPlugin(&text);
    host.registerFallbackEditor(&text);

    // Only the one vtable member `pluginForExtension` reaches; the rest stay unreachable here.
    var api_vt: EditorAPI.VTable = undefined;
    api_vt.extensionOwnerOverride = Fake.extensionOwnerOverride;
    var ctx: u8 = 0;
    host.installFizzyApi(.{ .ctx = &ctx, .vtable = &api_vt });

    // An assignment to a plugin that offers the extension is honored over the unique claimant.
    Fake.override = "image";
    try testing.expectEqual(&image, host.pluginForExtension(".png").?);

    // Stale: `pixi` no longer offers `.png`, so its assignment is ignored and `.png` falls
    // through to ordinary resolution rather than routing to a plugin that cannot open it.
    Fake.override = "pixi";
    try testing.expectEqual(&image, host.pluginForExtension(".png").?);

    // An assignment naming a plugin that is not loaded is likewise ignored.
    Fake.override = "ghost";
    try testing.expectEqual(&image, host.pluginForExtension(".png").?);

    // The fallback editor legitimately owns anything, so assigning it is honored.
    Fake.override = "text";
    try testing.expectEqual(&text, host.pluginForExtension(".png").?);

    Fake.override = null;
}

test "unregisterPlugin removes a plugin's contributions, service, and resets active ids" {
    const noopDraw = struct {
        fn f(_: ?*anyopaque) anyerror!void {}
    }.f;
    const noopCenter = struct {
        fn f(_: ?*anyopaque) anyerror!dvui.App.Result {
            return .ok;
        }
    }.f;
    const noopRun = struct {
        fn f(_: *anyopaque) anyerror!void {}
    }.f;
    const noColor = struct {
        fn f(_: ?*anyopaque, _: usize) ?dvui.Color {
            return null;
        }
    }.f;
    const noPaint = struct {
        fn f(_: ?*anyopaque, _: Painter.Subject) bool {
            return false;
        }
    }.f;

    var host = Host.init(testing.allocator);
    defer host.deinit();

    const vtable = Plugin.VTable{};
    var plugin = Plugin{ .state = undefined, .vtable = &vtable, .id = "victim", .display_name = "Victim" };

    // A second, surviving plugin so we can prove only the victim's entries are removed.
    var keeper = Plugin{ .state = undefined, .vtable = &vtable, .id = "keeper", .display_name = "Keeper" };

    try host.registerPlugin(&keeper);
    try host.registerPlugin(&plugin);
    try host.registerSurface(.{ .id = "keeper.view", .owner = &keeper, .title = "K", .keywords = keywords.ide.sidebar, .draw = noopCenter });
    try host.registerSurface(.{ .id = "victim.view", .owner = &plugin, .title = "V", .keywords = keywords.ide.sidebar, .draw = noopCenter });
    try host.registerSurface(.{ .id = "victim.bottom", .owner = &plugin, .title = "V", .keywords = keywords.ide.panel, .draw = noopCenter });
    try host.registerSurface(.{ .id = "victim.center", .owner = &plugin, .title = "V", .keywords = keywords.ide.main, .draw = noopCenter });
    try host.registerMenu(.{ .id = "victim.menu", .owner = &plugin, .draw = noopDraw });
    try host.registerMenuSection(.{ .id = "victim.section", .parent_menu_id = "fizzy.menu.view", .owner = &plugin, .draw = noopDraw });
    try host.registerNativeMenuItem(.{ .id = "victim.native", .parent_menu_id = "fizzy.menu.view", .owner = &plugin, .title = "V", .run = noopDraw });
    try host.registerCommand(.{ .id = "victim.cmd", .owner = &plugin, .title = "V", .run = noopRun });
    try host.registerFileRowFillColor(.{ .owner = &plugin, .color = noColor });
    try host.registerPainter(.{ .owner = &plugin, .draw = noPaint });
    const empty_access: settings.Access = .{
        .getBool = struct {
            fn f(_: *anyopaque, _: usize) bool {
                return false;
            }
        }.f,
        .setBool = struct {
            fn f(_: *anyopaque, _: usize, _: bool) void {}
        }.f,
        .getInt = struct {
            fn f(_: *anyopaque, _: usize) i64 {
                return 0;
            }
        }.f,
        .setInt = struct {
            fn f(_: *anyopaque, _: usize, _: i64) void {}
        }.f,
        .getFloat = struct {
            fn f(_: *anyopaque, _: usize) f64 {
                return 0;
            }
        }.f,
        .setFloat = struct {
            fn f(_: *anyopaque, _: usize, _: f64) void {}
        }.f,
        .getEnumIndex = struct {
            fn f(_: *anyopaque, _: usize) usize {
                return 0;
            }
        }.f,
        .setEnumIndex = struct {
            fn f(_: *anyopaque, _: usize, _: usize) void {}
        }.f,
        .getString = struct {
            fn f(_: *anyopaque, _: usize) []const u8 {
                return "";
            }
        }.f,
        .setString = struct {
            fn f(_: *anyopaque, _: usize, _: []const u8) void {}
        }.f,
        .getZonText = struct {
            fn f(_: *anyopaque, _: usize, _: std.mem.Allocator) []const u8 {
                return "";
            }
        }.f,
        .setZonText = struct {
            fn f(_: *anyopaque, _: usize, _: []const u8) bool {
                return false;
            }
        }.f,
        .persist = struct {
            fn f(_: *anyopaque, _: *Plugin) void {}
        }.f,
        .applyBlob = struct {
            fn f(_: *anyopaque, _: *Plugin, _: []const u8) void {}
        }.f,
    };
    var dummy_value: u8 = 0;
    try host.registerSettingsSchema(.{
        .owner = &plugin,
        .title = "Victim",
        .fields = &.{},
        .value = &dummy_value,
        .access = &empty_access,
    });
    const VictimSvc = struct {
        pub const service_name = "victim.svc";
        pub const service_version: u32 = 1;
        value: u32,
    };
    var victim_svc: VictimSvc = .{ .value = 0 };
    try host.registerService(VictimSvc, &victim_svc, &plugin);

    // Each region's selection points at the victim (keeper registered first, but force it).
    host.setSelectionFor(keywords.ide.sidebar, "victim.view");
    host.setSelectionFor(keywords.ide.panel, "victim.bottom");
    host.setSelectionFor(keywords.ide.main, "victim.center");

    host.unregisterPlugin(&plugin);

    // The victim is gone; the keeper survives.
    try testing.expect(host.pluginById("victim") == null);
    try testing.expect(host.pluginById("keeper") != null);

    // Every victim contribution is gone; the keeper's surface remains.
    try testing.expectEqual(@as(usize, 1), host.surfaces.items.len);
    try testing.expectEqualStrings("keeper.view", host.surfaces.items[0].id);
    try testing.expectEqual(@as(usize, 0), host.menus.items.len);
    try testing.expectEqual(@as(usize, 0), host.menu_sections.items.len);
    try testing.expectEqual(@as(usize, 0), host.native_menu_items.items.len);
    try testing.expectEqual(@as(usize, 0), host.commands.items.len);
    try testing.expectEqual(@as(usize, 0), host.file_row_fill_colors.items.len);
    try testing.expectEqual(@as(usize, 0), host.painters.items.len);
    try testing.expectEqual(@as(usize, 0), host.settings_schemas.items.len);
    try testing.expect(host.getService("victim.svc") == null);

    // Selections that named removed surfaces reset to null; the next frame falls back to a
    // still-registered one.
    try testing.expect(host.selectionFor(keywords.ide.sidebar) == null);
    try testing.expect(host.selectionFor(keywords.ide.panel) == null);
    try testing.expect(host.selectionFor(keywords.ide.main) == null);
}

test "a service whose provider is a different version is refused, not cast" {
    var host = Host.init(testing.allocator);
    defer host.deinit();

    // Same name, different declared version — the exact shape of a downstream app whose service
    // struct changed under a plugin built against the older one.
    const V1 = struct {
        pub const service_name = "geometry";
        pub const service_version: u32 = 1;
        value: u32,
    };
    const V2 = struct {
        pub const service_name = "geometry";
        pub const service_version: u32 = 2;
        value: u32,
        added: u32,
    };

    var v1: V1 = .{ .value = 7 };
    try host.registerService(V1, &v1, null);

    // The matching version resolves.
    const same = host.getServiceTyped(V1) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 7), same.value);

    // The mismatched one does not — this is the cast that would otherwise read `added` off the
    // end of a `V1`. The refusal warns in production; here the assertion is the refusal.
    warn_on_service_mismatch = false;
    defer warn_on_service_mismatch = true;
    try testing.expect(host.getServiceTyped(V2) == null);
}

test "several providers can share one name, which is what a hook is" {
    var host = Host.init(testing.allocator);
    defer host.deinit();

    const Hook = struct {
        pub const service_name = "cad.hooks";
        pub const service_version: u32 = 1;
        id: u32,
    };
    var a: Hook = .{ .id = 1 };
    var b: Hook = .{ .id = 2 };
    try host.registerService(Hook, &a, null);
    try host.registerService(Hook, &b, null);

    var buf: [4]*Hook = undefined;
    const found = host.servicesNamed(Hook, &buf);
    try testing.expectEqual(@as(usize, 2), found.len);
    // Registration order, so an app calling hooks in turn gets a stable, explicable order.
    try testing.expectEqual(@as(u32, 1), found[0].id);
    try testing.expectEqual(@as(u32, 2), found[1].id);

    // The single-provider lookup still answers with the first, which is what every existing
    // caller of a one-provider service expects.
    const first = host.getServiceTyped(Hook) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 1), first.id);
}

test "new-document candidates expand a plugin's kinds, one entry each" {
    const Fake = struct {
        fn kinds(_: *anyopaque) []const Plugin.NewDocumentKind {
            return &.{
                .{ .id = "sprite", .title = "Sprite" },
                .{ .id = "palette", .title = "Palette" },
            };
        }
        fn dialog(_: *anyopaque, _: ?[]const u8, _: ?[]const u8, _: usize) void {}
        fn create(_: *anyopaque, _: []const u8, _: EditorAPI.NewDocGrid, _: *anyopaque) anyerror!void {}
    };

    var host = Host.init(testing.allocator);
    defer host.deinit();

    // Offers two kinds through its own dialog.
    const pixi_vt = Plugin.VTable{ .requestNewDocumentDialog = Fake.dialog, .newDocumentKinds = Fake.kinds };
    // Creates documents but names no kinds: one entry, the plugin itself.
    const text_vt = Plugin.VTable{ .createDocument = Fake.create };
    // Neither creates nor offers a dialog: not in the flow at all.
    const viewer_vt = Plugin.VTable{};
    var pixi = Plugin{ .state = undefined, .vtable = &pixi_vt, .id = "pixi", .display_name = "Pixi" };
    var text = Plugin{ .state = undefined, .vtable = &text_vt, .id = "text", .display_name = "Text" };
    var viewer = Plugin{ .state = undefined, .vtable = &viewer_vt, .id = "image", .display_name = "Image" };
    try host.registerPlugin(&pixi);
    try host.registerPlugin(&text);
    try host.registerPlugin(&viewer);

    var it = host.newDocumentCandidates();
    const first = it.next().?;
    try testing.expectEqual(&pixi, first.plugin);
    try testing.expectEqualStrings("sprite", first.kind.?.id);
    const second = it.next().?;
    try testing.expectEqual(&pixi, second.plugin);
    try testing.expectEqualStrings("palette", second.kind.?.id);
    const third = it.next().?;
    try testing.expectEqual(&text, third.plugin);
    try testing.expectEqual(@as(?Plugin.NewDocumentKind, null), third.kind);
    try testing.expectEqual(@as(?Host.Candidate, null), it.next());
}
