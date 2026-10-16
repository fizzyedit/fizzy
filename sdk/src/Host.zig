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
const document = @import("document.zig");
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
pub const Claim = @import("Claim.zig");
pub const Step = @import("Step.zig");
pub const Author = @import("Author.zig");
pub const events = @import("events.zig");

/// Per-plugin opaque settings blobs pending a write: plugin id -> serialized zon text, or `null`
/// meaning "remove this id's `.settings` section entirely" (R12's non-default-only persistence —
/// see `sdk/settings.zig`'s `Schema(T).diffSerialize`: a value that's back to all-defaults has
/// nothing worth writing). The Host owns the key + (when present) value strings. This is a write
/// buffer only, not the source of truth — `Editor.writeMergedSettings` (via
/// `takePendingPluginSettings`) composes each entry into fizzy's own `<config>/settings.zon`
/// under `.plugins.<id>.settings` (a real, human-editable nested ZON struct literal, not an
/// escaped-string blob — see `src/editor/SettingsPluginsZon.zig` and
/// `plans/PLUGIN_MANIFEST_PLAN.md` R10/R12) and never interprets the contents.
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

/// Something drawn at the end of a file-tree row for the file at `path` — a status dot, a badge.
/// Called once per visible file row, inside the row, after its label.
///
/// The host's, not the workbench service's `BranchDecorator`, because it is owned: a plugin
/// unloaded at runtime has its decorators dropped by `unregisterPlugin` before its image goes,
/// where a `BranchDecorator` registered from a dylib would be called after it had gone.
pub const FileRowDecorator = struct {
    /// Contributing plugin (null = fizzy built-in). Scopes teardown in `unregisterPlugin`.
    owner: ?*Plugin = null,
    ctx: ?*anyopaque = null,
    draw: *const fn (ctx: ?*anyopaque, path: []const u8, id_extra: usize) void,
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
/// right before running that plugin's New File command (`<id>.new`) and consumed
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
file_row_decorators: std.ArrayListUnmanaged(FileRowDecorator) = .empty,

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
/// What the context menu being drawn is about — set by `drawMenuSections` for exactly as long as
/// its sections draw, and read back through `menuContext`. On the Host rather than the app so
/// that whoever opens a menu can set it: the workbench opens the tab and tree menus, and it is a
/// plugin with no way to reach an app global.
menu_context: ?EditorAPI.MenuContext = null,
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
/// The commands run on documents lately, oldest first and at most `activity_cap`, for each
/// document's panes to show as they run: by whoever ran them (a person, a tape, an agent). Titles
/// are copies, so an entry outlives the plugin that ran it.
activity: std.ArrayListUnmanaged(Activity) = .empty,
activity_seq: u64 = 0,
/// No activity is noted while set: a tape seeking replays its commands where nobody watches.
activity_muted: bool = false,
/// How long the last command called with arguments goes on showing its work
/// (`Command.Call.showing_ms`), for whoever called it.
last_showing_ms: u32 = 0,
/// The command whose body is running, if any: the edits made meanwhile are its (`documentEdited`).
running_command: ?*const Command = null,
/// While above 0, documents opened or created land beside the pane the person is in
/// (`EditorAPI.OpenOptions.beside`), not in it: an agent's work opens where it will be seen,
/// rather than over the person's document and then moved. Nested scopes count; UI thread only.
open_beside: u32 = 0,
/// Counts command runs, so one run that edits several times shows once.
command_runs: u64 = 0,
activity_run: u64 = 0,

/// Documents held by a plugin while it works on them (`Claim`).
claims: std.ArrayListUnmanaged(Claim) = .empty,
/// Who records documents' steps (`recordStep`): the app's tracks. Null, nobody does, and owners
/// encode nothing.
recorder: ?Recorder = null,
/// Every author that has acted, interned by identity (`Author.same`); `Acting` and the step map
/// hold indices into it. Strings are copies, so a label outlives the plugin that gave it.
authors: std.ArrayListUnmanaged(Author) = .empty,
/// Who is acting now (`act`): an index into `authors`, and the run it belongs to. Null: nobody.
acting: Acting = .{},
/// The frame's input author, set by the app where input is consumed (`setInputAuthor`): the
/// person's, or a tape's while one drives. Null outside those places.
input_author: ?u32 = null,
/// Runs started (`act`): one per outermost `act`.
runs: u64 = 0,
/// Who made each step not the person's, per document (`recordStep`). A document gets an entry only
/// once someone other than the person acts on it, so working alone this stays empty.
step_authors: std.AutoHashMapUnmanaged(u64, DocAuthors) = .empty,
/// Steps recorded where nobody acts (`Author.Kind.unattributed`): a missed site. The integration
/// tests assert it stays 0.
unattributed_steps: u64 = 0,
next_claim_id: u32 = 1,
/// Pluggable language/format support (syntax highlighting, preview panes).
language_support: std.ArrayListUnmanaged(LanguageSupport) = .empty,
/// Who listens for which events (`subscribe`), and what plugins say they announce
/// (`declareEvent`). See `events.zig`.
subscriptions: std.ArrayListUnmanaged(events.Subscription) = .empty,
event_declarations: std.ArrayListUnmanaged(events.Declaration) = .empty,
/// Emitted and not yet delivered (`emit`, `deliverEvents`), under `event_lock`: `emit` may come
/// from any thread. `listening` is whether anyone subscribes, read without the lock so an event no
/// one hears costs nothing.
event_queue: std.ArrayListUnmanaged(events.Queued) = .empty,
event_lock: std.atomic.Mutex = .unlocked,
listening: std.atomic.Value(bool) = .init(false),

/// Every UI a plugin contributes, of every kind. A `Surface` carries keywords rather than a
/// region name, so the app's layout decides where it lands and the SDK never has to grow a new
/// registry for a new kind of place.
surfaces: std.ArrayListUnmanaged(Surface) = .empty,
/// Titles given after registration (`setSurfaceTitle`), by surface id: the Host's own copies,
/// which those surfaces' `title` points at. Freed with the surface.
surface_titles: std.StringHashMapUnmanaged([]u8) = .empty,

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
    for (self.activity.items) |a| self.allocator.free(a.title);
    self.activity.deinit(self.allocator);

    for (self.claims.items) |c| self.allocator.free(c.label);
    self.claims.deinit(self.allocator);
    for (self.authors.items) |a| {
        self.allocator.free(a.plugin);
        self.allocator.free(a.label);
    }
    self.authors.deinit(self.allocator);
    var docs = self.step_authors.valueIterator();
    while (docs.next()) |d| d.steps.deinit(self.allocator);
    self.step_authors.deinit(self.allocator);
    self.plugins.deinit(self.allocator);
    self.services.deinit(self.allocator);
    self.selections.deinit(self.allocator);
    self.surfaces.deinit(self.allocator);
    var titles = self.surface_titles.iterator();
    while (titles.next()) |e| {
        self.allocator.free(e.key_ptr.*);
        self.allocator.free(e.value_ptr.*);
    }
    self.surface_titles.deinit(self.allocator);
    self.menus.deinit(self.allocator);
    self.menu_sections.deinit(self.allocator);
    self.rail_items.deinit(self.allocator);
    self.open_actions.deinit(self.allocator);
    self.account_providers.deinit(self.allocator);
    self.native_menu_items.deinit(self.allocator);
    self.commands.deinit(self.allocator);
    self.language_support.deinit(self.allocator);
    self.subscriptions.deinit(self.allocator);
    self.event_declarations.deinit(self.allocator);
    for (self.event_queue.items) |e| freeQueued(self.allocator, e);
    self.event_queue.deinit(self.allocator);
    self.file_row_fill_colors.deinit(self.allocator);
    self.file_row_decorators.deinit(self.allocator);
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

    /// This region's own chooser — the tab strip drawn for it — is at `bounds` this frame. Call
    /// it each frame the strip draws. While a view is carried the strip is chrome: over it the
    /// drop is into this region (`RegionSpec.Drop.on_chooser`, with where along it), the view
    /// rides as a tab, not a preview, and the drop zones cover the region less the strip. True
    /// while a carried view this region can take is over it: show where it would go in.
    pub fn offerChooser(self: Region, bounds: dvui.Rect.Physical) bool {
        return if (self.host.fizzy_api) |a| a.offerRegionChooser(self.token, bounds) else false;
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

/// Start the app's view drag for surface `id` — or for a document not open yet, by the id it will
/// have — from `from`: see `EditorAPI.beginViewDrag`.
pub fn beginViewDrag(self: *Host, id: []const u8, from: dvui.Rect.Physical) void {
    if (self.fizzy_api) |a| a.beginViewDrag(id, from);
}

/// Start the app's view drag for several things lifted together — a selection out of a file tree,
/// a folder — from `from`: see `EditorAPI.beginViewDragMany`.
pub fn beginViewDragMany(self: *Host, items: []const EditorAPI.Carried, from: dvui.Rect.Physical) void {
    if (self.fizzy_api) |a| a.beginViewDragMany(items, from);
}

/// The id of the surface the app's view drag is carrying, or null. A tab strip leaves that tab
/// out while it is in the hand.
pub fn viewDragSurface(self: *Host) ?[]const u8 {
    return if (self.fizzy_api) |a| a.viewDragSurface() else null;
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

/// Bring the surface `id` into sight wherever it lives: selected in the region that shows it (its
/// default place, or wherever the user moved it, floats included), and that region opened if it
/// was shut or folded away. False when no region shows it: the app's shape has no place for it,
/// or it is hidden.
///
/// What a plugin's "Show X" command calls: it names its view, never a place, so it works in any
/// app's shape. Consumers: the dashboard's "Toggle Profiler", `fizzy.reveal` (keybinds, tapes,
/// agents), a terminal's or a chat list's "Show" command.
pub fn revealSurface(self: *Host, id: []const u8) bool {
    const a = self.fizzy_api orelse return false;
    return a.revealSurface(id);
}

pub fn revealPosition(self: *Host, path: []const u8, line: u32, character: u32, open_side: bool) !bool {
    return if (self.fizzy_api) |a| a.revealPosition(path, line, character, open_side) else false;
}

/// Open documents beside the person until `endOpenBeside` (`open_beside`).
pub fn openBeside(self: *Host) void {
    self.open_beside += 1;
}
pub fn endOpenBeside(self: *Host) void {
    self.open_beside -|= 1;
}

/// Open a file — see `EditorAPI.OpenOptions`. Returns true when a new load started.
pub fn openFile(self: *Host, opts: EditorAPI.OpenOptions) !bool {
    return if (self.fizzy_api) |a| try a.openFile(opts) else false;
}

/// Whether this open document is a preview tab (italic, replaced by the next one).
pub fn documentIsPreview(self: *Host, doc_id: u64) bool {
    return if (self.fizzy_api) |a| a.documentIsPreview(doc_id) else false;
}

/// Keep a preview tab, or make a kept one a preview again.
pub fn setDocumentPreview(self: *Host, doc_id: u64, preview: bool) void {
    if (self.fizzy_api) |a| a.setDocumentPreview(doc_id, preview);
}

/// What the context menu currently being drawn is about — see `EditorAPI.MenuContext`. Null
/// outside a context-menu draw.
pub fn menuContext(self: *Host) ?EditorAPI.MenuContext {
    return self.menu_context;
}

/// Draw every section contributed to `ctx.menu_id`, with `ctx` as the answer to `menuContext`
/// while they draw. What whoever opens a context menu calls after its own rows, so a plugin's
/// "Reveal in Finder" and fizzy's "Rename" sit in one menu instead of two competing ones.
///
/// A separator goes before the first contributed row and nowhere else: one line between what
/// the menu's owner put there and what others added, not one per contributor. `after_rows =
/// false` for a menu that is *only* contributions — a document's, which its owner fills through
/// the same sections everyone else uses — where a line above the first row would be a line
/// under nothing.
pub fn drawMenuSections(self: *Host, ctx: EditorAPI.MenuContext, after_rows: bool) void {
    const prev = self.menu_context;
    self.menu_context = ctx;
    defer self.menu_context = prev;

    var drew_separator = !after_rows;
    for (self.menu_sections.items) |*section| {
        if (section.hidden) continue;
        if (!std.mem.eql(u8, section.parent_menu_id, ctx.menu_id)) continue;
        if (!drew_separator) {
            _ = dvui.separator(@src(), .{ .expand = .horizontal });
            drew_separator = true;
        }
        const prof = core.profile.begin(if (section.owner) |o| o.id else "fizzy", section.id);
        defer prof.end();
        section.draw(section.ctx) catch |err| {
            dvui.log.err("menu section '{s}' failed: {s}", .{ section.id, Plugin.errorNameOf(section.owner, err) });
        };
    }
}

/// Whether `path` is reached over a network. Ask before crawling: a window that suits a disk
/// is a spent API quota on a cloud mount.
pub fn isRemotePath(self: *Host, path: []const u8) bool {
    return if (self.fizzy_api) |a| a.isRemotePath(path) else false;
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
/// `fizzy.files.changed` (`events.FilesChanged`) will actually be emitted. A plugin that must stay correct
/// (an index, a file tree) should keep a slow rescan for when this is false, and can skip it
/// entirely when it is true.
pub fn folderWatchActive(self: *Host) bool {
    return if (self.fizzy_api) |a| a.folderWatchActive() else false;
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

/// How a document's saving stands (`EditorAPI.SaveState`): for an indicator. Not saving and
/// never saved when fizzy isn't installed.
pub fn saveState(self: *Host, doc_id: u64) EditorAPI.SaveState {
    return if (self.fizzy_api) |a| a.saveState(doc_id) else .{};
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
// plugin (see `plans/PLUGIN_MANIFEST_PLAN.md` R10, superseding R8's one-file-per-plugin design).
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
/// beside its own `<id>.{dylib,so,dll}` (see plans/PLUGIN_MANIFEST_PLAN.md R10: every plugin gets
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
    for (self.surfaces.items) |s| if (s.owner == plugin) self.dropSurfaceTitle(s.id);
    removeOwned(Surface, &self.surfaces, plugin);
    removeOwned(MenuContribution, &self.menus, plugin);
    removeOwned(MenuSectionContribution, &self.menu_sections, plugin);
    removeOwned(OpenAction, &self.open_actions, plugin);
    removeOwned(RailItemContribution, &self.rail_items, plugin);
    removeOwned(accounts.Provider, &self.account_providers, plugin);
    removeOwned(NativeMenuItem, &self.native_menu_items, plugin);
    removeOwned(Command, &self.commands, plugin);
    {
        var i: usize = 0;
        while (i < self.claims.items.len) {
            if (self.claims.items[i].owner == plugin) {
                self.allocator.free(self.claims.items[i].label);
                _ = self.claims.orderedRemove(i);
            } else i += 1;
        }
    }
    removeOwned(LanguageSupport, &self.language_support, plugin);
    removeOwned(FileRowFillColor, &self.file_row_fill_colors, plugin);
    removeOwned(FileRowDecorator, &self.file_row_decorators, plugin);
    removeOwned(Painter, &self.painters, plugin);
    removeOwned(FileKind, &self.file_kinds, plugin);
    removeOwnedSettingsSchemas(&self.settings_schemas, plugin);
    if (self.fallback_editor == plugin) self.fallback_editor = null;

    // Services: drop this plugin's entries before its image goes away — both the vtable pointer
    // and the name string live in it.
    removeOwned(ServiceEntry, &self.services, plugin);
    // Its handlers too, and what it said it announces: both point into its image.
    self.removeEventsOf(plugin);

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
/// `plugin` has been torn down (`Plugin.deinit`) while its image stays loaded, as at quit: drop
/// what other plugins reach it through, its services, commands and language support, so a plugin
/// torn down after it finds it gone rather than calling into freed state. `unregisterPlugin` does
/// this and more for a plugin that is going away while the app runs.
pub fn withdrawPlugin(self: *Host, plugin: *Plugin) void {
    removeOwned(ServiceEntry, &self.services, plugin);
    removeOwned(Command, &self.commands, plugin);
    removeOwned(LanguageSupport, &self.language_support, plugin);
    self.removeEventsOf(plugin);
}

fn removeEventsOf(self: *Host, plugin: *Plugin) void {
    removeOwned(events.Subscription, &self.subscriptions, plugin);
    removeOwned(events.Declaration, &self.event_declarations, plugin);
    self.listening.store(self.subscriptions.items.len > 0, .release);
}

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

/// An open document's unsaved contents settled after an edit: announces `fizzy.document.changed`
/// (`events.Path`). Called by the document's **owner** after a short lull in typing (a few hundred
/// ms) and on save, never per keystroke. This is how a plugin that owns nothing (a link indexer,
/// a word counter) learns a buffer is in flux. It says which, not what it now holds: a listener
/// that wants the text asks the owner (`Plugin.documentBytes`), so no buffer is copied for
/// listeners that do not care about it.
pub fn notifyDocumentContentChanged(self: *Host, path: []const u8) void {
    self.emitZon("fizzy.document.changed", events.Path{ .path = path });
}

/// A coalesced batch of on-disk changes under the open root folder, from fizzy's watcher on the UI
/// thread: applied to the shared file set, then announced as `fizzy.files.changed`
/// (`events.FilesChanged`).
///
/// The file set is reconciled here rather than by whichever plugin happens to draw a tree: the
/// host owns both the watcher and the table, so no plugin should have to listen to disk events
/// just to keep shared state honest. A listener is for what it *additionally* wants to do.
pub fn notifyFolderPathsChanged(self: *Host, changes: events.FilesChanged) void {
    if (self.files) |files| applyPathChanges(files, changes);
    self.emitZon("fizzy.files.changed", changes);
}

/// Drop exactly the listings a batch of disk events invalidates.
///
/// Only the *parent* of each changed path is dropped: a file appearing in `a/b/c.md` says
/// nothing about `a`. A truncated batch means the event list is an incomplete picture, so the
/// whole cache goes instead.
fn applyPathChanges(files: *core.FileTable, changes: events.FilesChanged) void {
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

pub fn registerFileRowDecorator(self: *Host, decorator: FileRowDecorator) !void {
    try self.file_row_decorators.append(self.allocator, decorator);
}

/// Every registered decorator's mark for the file row at `path`. Called by whatever draws a file
/// tree, inside the row.
pub fn drawFileRowDecorations(self: *Host, path: []const u8, id_extra: usize) void {
    for (self.file_row_decorators.items) |decorator| decorator.draw(decorator.ctx, path, id_extra);
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
        const prof = core.profile.begin(if (drawer.owner) |o| o.id else "fizzy", "painter.file");
        defer prof.end();
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
            self.dropSurfaceTitle(id);
            _ = self.surfaces.orderedRemove(i);
            return;
        }
    }
}

/// Rename a surface: what its tab, the picker and menus call it from now on. The Host keeps its
/// own copy, so `title` need not outlive the call. A surface registered with a fixed title keeps
/// it until this is called; nothing asks again. No-op for an id no surface has.
pub fn setSurfaceTitle(self: *Host, id: []const u8, title: []const u8) !void {
    const s = self.surfaceById(id) orelse return;
    const copy = try self.allocator.dupe(u8, title);
    errdefer self.allocator.free(copy);
    const gop = try self.surface_titles.getOrPut(self.allocator, id);
    if (gop.found_existing) {
        self.allocator.free(gop.value_ptr.*);
    } else {
        gop.key_ptr.* = self.allocator.dupe(u8, id) catch |err| {
            self.surface_titles.removeByPtr(gop.key_ptr);
            return err;
        };
    }
    gop.value_ptr.* = copy;
    s.title = copy;
}

/// A document's title changed (`Plugin.VTable.documentTitle`): its tab is renamed to it once,
/// here, rather than asked every frame. Called by the owner whenever its answer changes, and by
/// the app when it registers the document's surface. An owner with no answer keeps the file name.
pub fn documentTitleChanged(self: *Host, doc: DocHandle) void {
    const title = doc.owner.documentTitle(doc) orelse return;
    const id = document.surfaceId(self.allocator, doc.owner.id, doc.owner.documentPath(doc)) catch return;
    defer self.allocator.free(id);
    self.setSurfaceTitle(id, title) catch {};
}

fn dropSurfaceTitle(self: *Host, id: []const u8) void {
    const kv = self.surface_titles.fetchRemove(id) orelse return;
    self.allocator.free(kv.key);
    self.allocator.free(kv.value);
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
/// Refused when the command has neither `run` nor `runWith`, so nothing could invoke it.
pub fn registerCommand(self: *Host, cmd: Command) !void {
    if (cmd.run == null and cmd.runWith == null) return error.CommandCannotRun;
    try self.commands.append(self.allocator, cmd);
}

/// How many commands are registered — with `commandAt`, the way to list them without reaching
/// into the registry's storage.
pub fn commandCount(self: *Host) usize {
    return self.commands.items.len;
}

/// The `index`th registered command, in registration order, or null past the end.
pub fn commandAt(self: *Host, index: usize) ?*const Command {
    if (index >= self.commands.items.len) return null;
    return &self.commands.items[index];
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

// ---- claims ----------------------------------------------------------------------------------

/// Hold `doc_id` for `owner` while it works on it (`Claim`): the person's input to the document is
/// held back until `releaseClaim`, or until they stop it from its panes. `label` names the holder
/// to the person. A document holds one claim: another plugin's is `error.DocumentClaimed`; the
/// same plugin claiming again gets its claim back, relabelled.
pub fn claimDocument(self: *Host, owner: *Plugin, doc_id: u64, label: []const u8) !u32 {
    if (self.documentClaim(doc_id)) |c| {
        if (c.owner != owner) return error.DocumentClaimed;
        const i = self.claimIndex(c.id).?;
        const owned = try self.allocator.dupe(u8, label);
        self.allocator.free(self.claims.items[i].label);
        self.claims.items[i].label = owned;
        return c.id;
    }
    const owned = try self.allocator.dupe(u8, label);
    errdefer self.allocator.free(owned);
    const id = self.next_claim_id;
    try self.claims.append(self.allocator, .{ .id = id, .doc_id = doc_id, .label = owned, .owner = owner });
    self.next_claim_id +%= 1;
    if (self.next_claim_id == 0) self.next_claim_id = 1;
    self.refresh();
    return id;
}

/// Let go of a claim. Unknown ids (already released, or stopped by the person) are a no-op.
pub fn releaseClaim(self: *Host, id: u32) void {
    const i = self.claimIndex(id) orelse return;
    self.allocator.free(self.claims.items[i].label);
    _ = self.claims.orderedRemove(i);
    self.refresh();
}

/// The claim on `doc_id`, if one holds it. A holder that finds its claim gone was stopped.
pub fn documentClaim(self: *const Host, doc_id: u64) ?Claim {
    for (self.claims.items) |c| {
        if (c.doc_id == doc_id) return c;
    }
    return null;
}

/// Whether claim `id` still holds.
pub fn claimHolds(self: *const Host, id: u32) bool {
    return self.claimIndex(id) != null;
}

/// Drop every claim on `doc_id`: the document closed.
pub fn releaseDocumentClaims(self: *Host, doc_id: u64) void {
    var i: usize = 0;
    while (i < self.claims.items.len) {
        if (self.claims.items[i].doc_id == doc_id) {
            self.allocator.free(self.claims.items[i].label);
            _ = self.claims.orderedRemove(i);
        } else i += 1;
    }
}

fn claimIndex(self: *const Host, id: u32) ?usize {
    for (self.claims.items, 0..) |c, i| {
        if (c.id == id) return i;
    }
    return null;
}

/// The claim that refuses the person command `c` on the active document: the document is claimed
/// and `c` belongs to the plugin that draws it (Undo, Copy and Delete reach it as `<owner>.<verb>`).
fn claimRefusing(self: *Host, c: *const Command) ?Claim {
    // Nothing held, nothing to ask: a command costs no more than before.
    if (self.claims.items.len == 0) return null;
    const owner = c.owner orelse return null;
    const doc = self.activeDoc() orelse return null;
    if (doc.owner != owner) return null;
    return self.documentClaim(doc.id);
}

// ---- recording -------------------------------------------------------------------------------

/// What keeps the steps owners report: set by the app, never by a plugin.
pub const Recorder = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Whether `doc_id`'s steps are wanted. Asked before every step, so it is cheap.
        wants: *const fn (ctx: *anyopaque, doc_id: u64) bool,
        /// Keep `step` of `doc_id`. Its bytes are only valid for the call.
        step: *const fn (ctx: *anyopaque, doc_id: u64, step: Step) void,
    };
};

/// Whether `doc_id`'s steps are recorded. An owner asks before it encodes one, so a document
/// nobody records costs nothing.
pub fn recording(self: *const Host, doc_id: u64) bool {
    const r = self.recorder orelse return false;
    return r.vtable.wants(r.ctx, doc_id);
}

/// A step of `doc_id`'s history, from its **owner**, as it happens (`Step`): each entry added or
/// joined, undone or redone, and the history starting over. Every step, recorded or not: the host
/// keeps who made it (`stepAuthor`) and the document's top (`topStep`). An owner encodes `effect`
/// only while `recording(doc_id)`; the recorder hears the step only then.
pub fn recordStep(self: *Host, doc_id: u64, step: Step) void {
    self.noteAuthor(doc_id, step);
    if (self.recording(doc_id)) {
        const r = self.recorder.?;
        r.vtable.step(r.ctx, doc_id, step);
    }
}

// ---- authors (`plans/SHARED_HISTORY_PLAN.md`) ------------------------------------------------

/// Who is acting, to restore with `endAct` or to store and act as again later (`actAgain`): an
/// index into the host's authors, and the run.
pub const Acting = struct {
    author: ?u32 = null,
    run: u64 = 0,
};

/// One document's authors: who made each step that is not the person's, by step id, and the step
/// on top.
pub const DocAuthors = struct {
    steps: std.AutoHashMapUnmanaged(u64, StepAuthor) = .empty,
    top: u64 = 0,
};

pub const StepAuthor = struct {
    /// Index into the host's authors.
    author: u32,
    /// The run it was made in (`act`): one MCP call of an agent's, one op of a tape's.
    run: u64,
};

/// Act as `author` until `endAct` with what this returns: the steps recorded meanwhile are
/// theirs. The outermost `act` starts a run; one inside it keeps it. Innermost wins. UI thread
/// only.
pub fn act(self: *Host, who: Author) Acting {
    const outer = self.acting;
    const index = self.intern(who);
    self.acting = .{
        .author = index,
        .run = if (outer.author == null) run: {
            self.runs += 1;
            break :run self.runs;
        } else outer.run,
    };
    return outer;
}

/// Act as before: `stored` is what `acted` said when a call was put off (pixi's call waiting out
/// the person's stroke), so its steps are still that author's, in that run.
pub fn actAgain(self: *Host, stored: Acting) Acting {
    const outer = self.acting;
    self.acting = stored;
    return outer;
}

/// Who is acting now, to store with work done later (`actAgain`).
pub fn acted(self: *const Host) Acting {
    return self.acting;
}

pub fn endAct(self: *Host, outer: Acting) void {
    self.acting = outer;
}

/// Who is acting now: the innermost `act`, else the frame's input author where input is being
/// consumed, else nobody known.
pub fn author(self: *const Host) Author {
    const index = self.acting.author orelse self.input_author orelse return .unattributed;
    return self.authors.items[index];
}

/// The frame's input author (the app's to set, around where input is consumed): the person's, or
/// a tape's while one drives. Null where no input is consumed.
pub fn setInputAuthor(self: *Host, who: ?Author) void {
    self.input_author = if (who) |a| self.intern(a) else null;
}

/// Who made step `id` of `doc_id`: the person when none other is kept.
pub fn stepAuthor(self: *const Host, doc_id: u64, id: u64) Author {
    const doc = self.step_authors.getPtr(doc_id) orelse return .person;
    const s = doc.steps.get(id) orelse return .person;
    return self.authors.items[s.author];
}

pub const TopStep = struct { id: u64, author: Author };

/// The step on top of `doc_id`'s history and who made it, when the host knows it: once someone
/// other than the person has acted on the document, from the steps its owner reports.
pub fn topStep(self: *const Host, doc_id: u64) ?TopStep {
    const doc = self.step_authors.getPtr(doc_id) orelse return null;
    if (doc.top == 0) return null;
    return .{ .id = doc.top, .author = self.stepAuthor(doc_id, doc.top) };
}

/// Whether the acting author may fold an edit into step `id` of `doc_id`: when `id` is theirs (a
/// step with no author kept is the person's). False ends a run of typing: the owner starts a new
/// step, so an agent's keystrokes never join the person's.
pub fn mayMerge(self: *const Host, doc_id: u64, id: u64) bool {
    const who = self.author();
    const made = self.stepAuthor(doc_id, id);
    // Nobody known acting is a missed site (`unattributed_steps`); it merges as the person would.
    if (who.kind == .unattributed) return made.kind == .person;
    return who.same(made);
}

/// Forget `doc_id`'s authors: the document closed.
pub fn forgetDocumentAuthors(self: *Host, doc_id: u64) void {
    var entry = self.step_authors.fetchRemove(doc_id) orelse return;
    entry.value.steps.deinit(self.allocator);
}

fn intern(self: *Host, who: Author) u32 {
    for (self.authors.items, 0..) |*a, i| {
        if (!a.same(who)) continue;
        // The label may come later (an agent's name, known once its client says hello).
        if (who.label.len > 0 and !std.mem.eql(u8, a.label, who.label)) {
            if (self.allocator.dupe(u8, who.label)) |label| {
                self.allocator.free(a.label);
                a.label = label;
            } else |_| {}
        }
        return @intCast(i);
    }
    const plugin = self.allocator.dupe(u8, who.plugin) catch return self.internFailed();
    const label = self.allocator.dupe(u8, who.label) catch {
        self.allocator.free(plugin);
        return self.internFailed();
    };
    self.authors.append(self.allocator, .{ .kind = who.kind, .plugin = plugin, .session = who.session, .label = label }) catch {
        self.allocator.free(plugin);
        self.allocator.free(label);
        return self.internFailed();
    };
    return @intCast(self.authors.items.len - 1);
}

/// Out of memory interning: nobody known, rather than wrongly the person. Its strings are static,
/// so `deinit` frees nothing it did not allocate: an empty slice frees as a no-op.
fn internFailed(self: *Host) u32 {
    for (self.authors.items, 0..) |a, i| if (a.kind == .unattributed and a.plugin.len == 0) return @intCast(i);
    self.authors.append(self.allocator, .unattributed) catch {};
    return @intCast(self.authors.items.len -| 1);
}

/// Keep who made `step`, and `doc_id`'s top (`recordStep`).
fn noteAuthor(self: *Host, doc_id: u64, step: Step) void {
    const who = self.author();
    if (who.kind == .unattributed and step.kind != .restarted) self.unattributed_steps += 1;
    const theirs = who.kind != .person;
    // Working alone, nothing is kept: a document gets an entry the first time someone else acts.
    const doc = if (self.step_authors.getPtr(doc_id)) |d| d else if (theirs) blk: {
        const gop = self.step_authors.getOrPut(self.allocator, doc_id) catch return;
        gop.value_ptr.* = .{};
        break :blk gop.value_ptr;
    } else return;
    switch (step.kind) {
        .restarted => {
            doc.steps.clearRetainingCapacity();
            doc.top = 0;
        },
        .added => {
            if (theirs) {
                const index = self.acting.author orelse self.input_author orelse self.internFailed();
                doc.steps.put(self.allocator, step.id, .{ .author = index, .run = self.acting.run }) catch {};
            }
            doc.top = if (step.top != 0) step.top else step.id;
        },
        // A step joined keeps the author it began with (`mayMerge` decided it could join).
        .joined => doc.top = if (step.top != 0) step.top else step.id,
        .undone, .redone => doc.top = step.top,
    }
}

// ---- activity --------------------------------------------------------------------------------

/// A command that edited a document (`activity`).
pub const Activity = struct {
    /// Increasing: a reader keeps the last it saw and takes those after it.
    seq: u64,
    doc_id: u64,
    /// The command's title, as a person reads it: `Draw`, `Undo`. Owned by the host.
    title: []const u8,
};

const activity_cap = 32;

/// An open document was just edited (an undo step was recorded, or undone): its **owner** calls
/// this for every edit. When a command is running, the edit is that command's, and the document's
/// panes show it (`activity`), once per run of the command.
pub fn documentEdited(self: *Host, doc_id: u64) void {
    const c = self.running_command orelse return;
    if (self.activity_muted) return;
    if (self.activity.getLastOrNull()) |last| {
        if (self.activity_run == self.command_runs and last.doc_id == doc_id) return;
    }
    const title = self.allocator.dupe(u8, std.mem.trimEnd(u8, c.title, "…")) catch return;
    if (self.activity.items.len == activity_cap) {
        self.allocator.free(self.activity.items[0].title);
        _ = self.activity.orderedRemove(0);
    }
    self.activity_seq += 1;
    self.activity_run = self.command_runs;
    self.activity.append(self.allocator, .{ .seq = self.activity_seq, .doc_id = doc_id, .title = title }) catch {
        self.allocator.free(title);
        return;
    };
    self.refresh();
}

/// Run a command's body as the running command, so the edits it makes are its own.
fn running(self: *Host, c: *const Command) ?*const Command {
    const outer = self.running_command;
    self.running_command = c;
    self.command_runs += 1;
    return outer;
}
/// Run the command `id` with no arguments (no-op when unknown), as a menu row or a keybind
/// does. The owner's opaque `state` is passed to `run`. A command with only `runWith` runs it
/// with no arguments, unless a parameter is required: then the app is asked to collect them
/// (`EditorAPI.askCommandArguments` — fizzy opens the palette on the command), and without an
/// app that can, the run fails with `error.MissingArguments`.
pub fn runCommand(self: *Host, id: []const u8) !void {
    const c = self.command(id) orelse return;
    const owner = c.owner orelse return;
    // A person's command on a document someone holds waits until they let go (`Claim`). The
    // holder reaches it through `callCommand`.
    if (self.claimRefusing(c)) |claim| {
        std.log.info("{s}: {s} is working on this document", .{ id, claim.label });
        return error.DocumentClaimed;
    }
    if (c.run) |run| {
        const prof = core.profile.begin(owner.id, c.id);
        defer prof.end();
        const outer = self.running(c);
        defer self.running_command = outer;
        run(owner.state) catch |err| return owner.failed(c.id, err);
        return;
    }
    if (Command.requiresArguments(c.params)) {
        if (self.fizzy_api) |api| {
            if (api.askCommandArguments(id)) return;
        }
        std.log.err("{s}: needs arguments, and nothing here can ask for them", .{id});
        return error.MissingArguments;
    }
    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    switch (self.callCommand(id, "", arena_state.allocator())) {
        .ok, .unknown => {},
        .disabled => return error.CommandDisabled,
        .bad_args, .failed => |msg| {
            std.log.err("{s}: {s}", .{ id, msg });
            return error.PluginFailed;
        },
    }
}

/// What came of `callCommand`. Results and messages live in the arena the caller passed.
pub const CommandOutcome = union(enum) {
    /// It ran. Its result as ZON, or null when it returns nothing.
    ok: ?[]const u8,
    /// No command is registered by that id.
    unknown,
    /// It is registered and not enabled now (`Command.isEnabled`).
    disabled,
    /// The arguments did not fit its parameters — the message says where.
    bad_args: []const u8,
    /// It ran and failed — the message is the command's own, or its error's name.
    failed: []const u8,
};

/// Run the command `id` with `args`, ZON keyed by its parameters (`.{ .line = 12 }`; empty for
/// none), and get its result back. `results` is the caller's arena and holds everything
/// returned. A
/// command without `runWith` takes no arguments: it runs through `run` when `args` is empty, and
/// is refused otherwise.
// ---- events -------------------------------------------------------------------------------

/// Listen for an event, a prefix of them (`"fizzy.document.*"`) or every one (`"*"`). The handler
/// runs on the UI thread, once per event, in the order they were emitted (`events.zig`).
/// `sub.event` and the handler live in the subscriber's image; they go with it.
pub fn subscribe(self: *Host, sub: events.Subscription) !void {
    try self.subscriptions.append(self.allocator, sub);
    self.listening.store(true, .release);
}

/// Say what an event means and what its payload holds, for tooling and agents to list.
pub fn declareEvent(self: *Host, decl: events.Declaration) !void {
    try self.event_declarations.append(self.allocator, decl);
}

/// Announce `name` (`<emitter>.<event>`) with a ZON `payload`, copied. Delivered before the next
/// frame's `beginFrame`, never inside this call, so it is safe from any thread and from inside a
/// handler. An event no one listens for costs a load and a return.
pub fn emit(self: *Host, name: []const u8, payload: []const u8) void {
    if (!self.listening.load(.acquire)) return;
    const n = self.allocator.dupe(u8, name) catch return;
    const p = self.allocator.dupe(u8, payload) catch {
        self.allocator.free(n);
        return;
    };
    self.lockEvents();
    self.event_queue.append(self.allocator, .{ .name = n, .payload = p }) catch {
        self.event_lock.unlock();
        freeQueued(self.allocator, .{ .name = n, .payload = p });
        return;
    };
    self.event_lock.unlock();
    // From a worker the app may be asleep: wake it for the delivery.
    self.refresh();
}

/// Deliver what was emitted since the last delivery, each event to every subscription that takes
/// it. The app calls this once a frame on the UI thread, before plugins' `beginFrame`. What a
/// handler emits waits for the next delivery; a subscription added during delivery hears the
/// events after it.
pub fn deliverEvents(self: *Host) void {
    if (self.event_queue.items.len == 0) return;
    self.lockEvents();
    var batch = self.event_queue;
    self.event_queue = .empty;
    self.event_lock.unlock();
    defer {
        for (batch.items) |e| freeQueued(self.allocator, e);
        batch.deinit(self.allocator);
    }
    for (batch.items) |e| {
        // By index, and bounded by what there was: a handler may subscribe while it runs.
        const n = self.subscriptions.items.len;
        var i: usize = 0;
        while (i < @min(n, self.subscriptions.items.len)) : (i += 1) {
            const sub = self.subscriptions.items[i];
            if (!events.matches(sub.event, e.name)) continue;
            const owner = sub.owner orelse continue;
            const prof = core.profile.begin(owner.id, e.name);
            defer prof.end();
            sub.handler(owner.state, .{ .name = e.name, .payload = e.payload });
        }
    }
}

/// `emit` with `value` written as ZON, written only when someone listens.
pub fn emitZon(self: *Host, name: []const u8, value: anytype) void {
    if (!self.listening.load(.acquire)) return;
    var out: std.Io.Writer.Allocating = .init(self.allocator);
    defer out.deinit();
    std.zon.stringify.serialize(value, .{ .whitespace = false }, &out.writer) catch return;
    self.emit(name, out.written());
}

/// Held only for a list append or a swap. The web is one thread, so it is never contended there,
/// and wasm has no yield.
fn lockEvents(self: *Host) void {
    while (!self.event_lock.tryLock()) {
        if (comptime builtin.target.cpu.arch != .wasm32) std.Thread.yield() catch {};
    }
}

fn freeQueued(allocator: std.mem.Allocator, e: events.Queued) void {
    allocator.free(e.name);
    allocator.free(e.payload);
}

pub fn callCommand(self: *Host, id: []const u8, args: []const u8, results: std.mem.Allocator) CommandOutcome {
    const c = self.command(id) orelse return .unknown;
    const owner = c.owner orelse return .unknown;
    if (c.isEnabled) |enabled| {
        if (!enabled(owner.state)) return .disabled;
    }
    const prof = core.profile.begin(owner.id, c.id);
    defer prof.end();
    const run_with = c.runWith orelse {
        const trimmed = std.mem.trim(u8, args, " \t\r\n");
        if (trimmed.len > 0 and !std.mem.eql(u8, trimmed, ".{}")) return .{ .bad_args = "this command takes no arguments" };
        const outer = self.running(c);
        defer self.running_command = outer;
        c.run.?(owner.state) catch |err| return .{ .failed = owner.errorName(err) };
        return .{ .ok = null };
    };
    self.last_showing_ms = 0;
    var call: Command.Call = .{ .args = args, .arena = results };
    const outer = self.running(c);
    defer self.running_command = outer;
    run_with(owner.state, &call) catch |err| {
        const msg = call.message orelse owner.errorName(err);
        return if (call.bad_args) .{ .bad_args = msg } else .{ .failed = msg };
    };
    self.last_showing_ms = call.showing_ms;
    return .{ .ok = call.result };
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

/// Whether `id` is one of `owner`'s New File commands: `<owner>.new`, or `<owner>.new.<kind>`.
fn isNewDocumentCommand(owner_id: []const u8, id: []const u8) bool {
    if (!std.mem.startsWith(u8, id, owner_id)) return false;
    const action = id[owner_id.len..];
    return std.mem.eql(u8, action, ".new") or std.mem.startsWith(u8, action, ".new.");
}

/// Open a "new document" flow. `parent_path` (when set) targets an on-disk folder.
///
/// The entries are every plugin's New File commands (`<id>.new`, `<id>.new.<kind>`: a plugin
/// offering a sprite and a palette is two entries, so the chooser asks what to make rather than
/// who should make it), and a document owner with none (`createDocument` only, the bundled
/// `text`) as itself. With none this is a no-op; with exactly one it runs directly; with two or
/// more a picker (`showNewDocumentChooser`) asks first.
pub fn requestNewDocument(self: *Host, parent_path: ?[]const u8) void {
    var only: ?Candidate = null;
    var count: usize = 0;
    var it = self.newDocumentCandidates();
    while (it.next()) |c| {
        count += 1;
        if (only == null) only = c;
    }

    if (count >= 2) {
        showNewDocumentChooser(parent_path);
        return;
    }

    const single = only orelse return;
    self.dispatchNewDocument(single, parent_path);
}

/// One entry in the New File flow: a plugin's New File command, or (`command == null`) a
/// document owner that offers none, standing for itself.
pub const Candidate = struct {
    plugin: *Plugin,
    command: ?*const Command = null,

    /// What the chooser calls it: the command's title, or the plugin's name.
    pub fn title(self: Candidate) []const u8 {
        return if (self.command) |c| c.title else self.plugin.display_name;
    }
};

/// Walks every New File entry, in plugin registration order, then each plugin's command order.
pub fn newDocumentCandidates(self: *Host) CandidateIterator {
    return .{ .host = self };
}

pub const CandidateIterator = struct {
    host: *Host,
    plugin_index: usize = 0,
    command_index: usize = 0,
    /// Whether the current plugin has yielded a command yet.
    found: bool = false,

    pub fn next(self: *CandidateIterator) ?Candidate {
        while (self.plugin_index < self.host.plugins.items.len) {
            const plugin = self.host.plugins.items[self.plugin_index];
            const commands = self.host.commands.items;
            while (self.command_index < commands.len) {
                const c = &commands[self.command_index];
                self.command_index += 1;
                if (c.owner != plugin or !isNewDocumentCommand(plugin.id, c.id)) continue;
                self.found = true;
                return .{ .plugin = plugin, .command = c };
            }
            const stands_for_itself = !self.found and plugin.vtable.createDocument != null;
            self.plugin_index += 1;
            self.command_index = 0;
            self.found = false;
            if (stands_for_itself) return .{ .plugin = plugin };
        }
        return null;
    }
};

/// Run a New File entry: its command, with the folder to create in, or straight to an untitled
/// in-memory document for an owner that offers no command.
fn dispatchNewDocument(self: *Host, candidate: Candidate, parent_path: ?[]const u8) void {
    const owner = candidate.plugin;
    // Only claim the pending slot for a plugin that can actually take the document back: it
    // exists to disambiguate a later `host.createDocument(path, grid)`, and a utility plugin
    // never makes that call. Leaving a stale owner parked here would misroute the *next*
    // create — the one a different plugin makes — to a plugin with no `createDocument` at all.
    self.pending_new_document_owner = if (owner.vtable.createDocument != null) owner else null;

    const c = candidate.command orelse {
        self.createUntitledDocumentDirect(parent_path) catch |err| {
            dvui.log.err("New File: {s}", .{@errorName(err)});
        };
        return;
    };
    var args: std.Io.Writer.Allocating = .init(self.arena());
    std.zon.stringify.serialize(.{ .parent_path = parent_path orelse "" }, .{ .whitespace = false }, &args.writer) catch return;
    switch (self.callCommand(c.id, args.written(), self.arena())) {
        .ok => {},
        .failed => |why| dvui.log.err("New File: {s}: {s}", .{ c.id, why }),
        else => dvui.log.err("New File: {s} did not run", .{c.id}),
    }
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
fn showNewDocumentChooser(parent_path: ?[]const u8) void {
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
    dvui.dataSet(null, mutex.id, "_nf_has_parent", parent_path != null);
    if (parent_path) |p| dvui.dataSetSlice(null, mutex.id, "_nf_parent_path", p);
    mutex.mutex.unlock(dvui.io);
}

fn newDocumentChooserDisplay(id: dvui.Id) anyerror!bool {
    const host = runtime.host();
    const has_parent = dvui.dataGet(null, id, "_nf_has_parent", bool) orelse false;
    const parent_path: ?[]const u8 = if (has_parent) dvui.dataGetSlice(null, id, "_nf_parent_path", []u8) else null;

    var outer = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .all(12) });
    defer outer.deinit();

    dvui.labelNoFmt(@src(), "What would you like to create?", .{}, .{ .font = dvui.Font.theme(.body) });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 16 } });

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .gravity_x = 0.5 });
    defer row.deinit();

    var index: usize = 0;
    var it = host.newDocumentCandidates();
    while (it.next()) |candidate| : (index += 1) {
        var cell = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = index, .margin = .all(6) });
        defer cell.deinit();

        if (newDocumentChooserButton(host, candidate, index)) {
            host.dispatchNewDocument(candidate, parent_path);
            core.dialogs.closeFloatingDialogAnchored();
        }

        _ = dvui.spacer(@src(), .{ .id_extra = index, .min_size_content = .{ .w = 1, .h = 6 } });
        dvui.labelNoFmt(@src(), candidate.title(), .{}, .{
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
        // Named by the caption drawn below it, outside the button.
        .label = .{ .text = candidate.title() },
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

    const drew_kind_icon = if (candidate.command) |c| blk: {
        const bytes = c.icon orelse break :blk false;
        core.icon.icon(@src(), c.id, bytes, .{}, .{
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
    const noDecoration = struct {
        fn f(_: ?*anyopaque, _: []const u8, _: usize) void {}
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
    try host.registerFileRowDecorator(.{ .owner = &plugin, .draw = noDecoration });
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
    try testing.expectEqual(@as(usize, 0), host.file_row_decorators.items.len);
    try testing.expectEqual(@as(usize, 0), host.painters.items.len);
    try testing.expectEqual(@as(usize, 0), host.settings_schemas.items.len);
    try testing.expect(host.getService("victim.svc") == null);

    // Selections that named removed surfaces reset to null; the next frame falls back to a
    // still-registered one.
    try testing.expect(host.selectionFor(keywords.ide.sidebar) == null);
    try testing.expect(host.selectionFor(keywords.ide.panel) == null);
    try testing.expect(host.selectionFor(keywords.ide.main) == null);
}

test "a withdrawn plugin is out of reach: its services, commands and highlighting" {
    var host = Host.init(testing.allocator);
    defer host.deinit();
    const vtable = Plugin.VTable{};
    var gone = Plugin{ .state = undefined, .vtable = &vtable, .id = "gone", .display_name = "Gone" };
    var stays = Plugin{ .state = undefined, .vtable = &vtable, .id = "stays", .display_name = "Stays" };
    try host.registerPlugin(&stays);
    try host.registerPlugin(&gone);
    const Svc = struct {
        pub const service_name = "gone.svc";
        pub const service_version: u32 = 1;
        value: u32 = 0,
    };
    var svc: Svc = .{};
    try host.registerService(Svc, &svc, &gone);
    const noopRun = struct {
        fn f(_: *anyopaque) anyerror!void {}
    }.f;
    try host.registerCommand(.{ .id = "gone.cmd", .owner = &gone, .title = "G", .run = noopRun });
    try host.registerCommand(.{ .id = "stays.cmd", .owner = &stays, .title = "S", .run = noopRun });

    host.withdrawPlugin(&gone);
    try testing.expect(host.getServiceTyped(Svc) == null);
    try testing.expect(host.command("gone.cmd") == null);
    try testing.expect(host.command("stays.cmd") != null);
    // Still registered: only what others reach it through is gone.
    try testing.expectEqual(@as(usize, 2), host.plugins.items.len);
}

const EventLog = struct {
    seen: [16][48]u8 = undefined,
    lens: [16]usize = @splat(0),
    n: usize = 0,
    /// Emit this from the handler, once, to see it wait for the next delivery.
    echo: ?*Host = null,

    fn handler(state: *anyopaque, e: events.Event) void {
        const self: *EventLog = @ptrCast(@alignCast(state));
        if (self.n == self.seen.len) return;
        const text = std.fmt.bufPrint(&self.seen[self.n], "{s} {s}", .{ e.name, e.payload }) catch return;
        self.lens[self.n] = text.len;
        self.n += 1;
        if (self.echo) |h| {
            self.echo = null;
            h.emit("test.echo", "");
        }
    }
    fn at(self: *const EventLog, i: usize) []const u8 {
        return self.seen[i][0..self.lens[i]];
    }
};

test "events wait for delivery, then reach every subscription that takes them, in order" {
    var host = Host.init(testing.allocator);
    defer host.deinit();
    const vtable = Plugin.VTable{};
    var exact_log: EventLog = .{};
    var prefix_log: EventLog = .{};
    var all_log: EventLog = .{};
    var exact = Plugin{ .state = &exact_log, .vtable = &vtable, .id = "exact", .display_name = "E" };
    var prefix = Plugin{ .state = &prefix_log, .vtable = &vtable, .id = "prefix", .display_name = "P" };
    var all = Plugin{ .state = &all_log, .vtable = &vtable, .id = "all", .display_name = "A" };

    // No one listens: nothing is queued.
    host.emit("fizzy.document.saved", ".{}");
    try testing.expectEqual(@as(usize, 0), host.event_queue.items.len);

    try host.subscribe(.{ .event = "fizzy.document.saved", .owner = &exact, .handler = EventLog.handler });
    try host.subscribe(.{ .event = "fizzy.document.*", .owner = &prefix, .handler = EventLog.handler });
    try host.subscribe(.{ .event = "*", .owner = &all, .handler = EventLog.handler });
    all_log.echo = &host;
    host.emit("fizzy.document.opened", ".{ .path = \"a\" }");
    host.emitZon("fizzy.document.saved", .{ .path = "a" });
    host.emit("chat.turn_ended", "");
    // Nothing runs inside `emit`.
    try testing.expectEqual(@as(usize, 0), all_log.n);

    host.deliverEvents();
    try testing.expectEqual(@as(usize, 1), exact_log.n);
    try testing.expectEqualStrings("fizzy.document.saved .{.path=\"a\"}", exact_log.at(0));
    try testing.expectEqual(@as(usize, 2), prefix_log.n);
    try testing.expectEqualStrings("fizzy.document.opened .{ .path = \"a\" }", prefix_log.at(0));
    try testing.expectEqual(@as(usize, 3), all_log.n);
    try testing.expectEqualStrings("chat.turn_ended ", all_log.at(2));
    // What a handler emitted waits for the next delivery.
    try testing.expectEqual(@as(usize, 1), host.event_queue.items.len);
    host.deliverEvents();
    try testing.expectEqualStrings("test.echo ", all_log.at(3));

    // From another thread: queued, and delivered on the UI thread's next delivery.
    const t = try std.Thread.spawn(.{}, struct {
        fn run(h: *Host) void {
            h.emit("worker.done", ".{}");
        }
    }.run, .{&host});
    t.join();
    try testing.expectEqual(@as(usize, 4), all_log.n);
    host.deliverEvents();
    try testing.expectEqualStrings("worker.done .{}", all_log.at(4));

    // A withdrawn plugin hears nothing more.
    host.withdrawPlugin(&all);
    host.emit("fizzy.document.saved", "");
    host.deliverEvents();
    try testing.expectEqual(@as(usize, 5), all_log.n);
    try testing.expectEqual(@as(usize, 2), exact_log.n);
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

test "new-document candidates: each New File command, else the owner itself" {
    const Fake = struct {
        fn run(_: *anyopaque) anyerror!void {}
        fn create(_: *anyopaque, _: []const u8, _: EditorAPI.NewDocGrid, _: *anyopaque) anyerror!void {}
    };

    var host = Host.init(testing.allocator);
    defer host.deinit();

    // Offers two kinds through commands of its own, and owns documents.
    const pixi_vt = Plugin.VTable{ .createDocument = Fake.create };
    // Creates documents but has no command: one entry, the plugin itself.
    const text_vt = Plugin.VTable{ .createDocument = Fake.create };
    // A command that is not a New File one, and nothing to create: not in the flow at all.
    const viewer_vt = Plugin.VTable{};
    var pixi = Plugin{ .state = undefined, .vtable = &pixi_vt, .id = "pixi", .display_name = "Pixi" };
    var text = Plugin{ .state = undefined, .vtable = &text_vt, .id = "text", .display_name = "Text" };
    var viewer = Plugin{ .state = undefined, .vtable = &viewer_vt, .id = "image", .display_name = "Image" };
    try host.registerPlugin(&pixi);
    try host.registerPlugin(&text);
    try host.registerPlugin(&viewer);
    try host.registerCommand(.{ .id = "pixi.new.sprite", .owner = &pixi, .title = "Sprite", .run = Fake.run });
    try host.registerCommand(.{ .id = "image.newer", .owner = &viewer, .title = "Not one", .run = Fake.run });
    try host.registerCommand(.{ .id = "pixi.new.palette", .owner = &pixi, .title = "Palette", .run = Fake.run });

    var it = host.newDocumentCandidates();
    const first = it.next().?;
    try testing.expectEqual(&pixi, first.plugin);
    try testing.expectEqualStrings("Sprite", first.title());
    const second = it.next().?;
    try testing.expectEqual(&pixi, second.plugin);
    try testing.expectEqualStrings("Palette", second.title());
    const third = it.next().?;
    try testing.expectEqual(&text, third.plugin);
    try testing.expect(third.command == null);
    try testing.expectEqualStrings("Text", third.title());
    try testing.expectEqual(@as(?Host.Candidate, null), it.next());
}

test "commands with arguments: callCommand, runCommand's fallback, and listing" {
    var host = Host.init(testing.allocator);
    defer host.deinit();

    const S = struct {
        var moved_to: ?u32 = null;
        var plain_runs: u32 = 0;
        var asked: ?[]const u8 = null;
        var enabled = true;

        const GoTo = Command.Params(struct {
            line: Command.Arg(u32, .{ .description = "The line." }),
            column: Command.Arg(u32, .{ .description = "The column." }) = .init(1),
        });
        const Tidy = Command.Params(struct {
            width: Command.Arg(u32, .{ .description = "How wide." }) = .init(80),
        });

        fn goTo(_: *anyopaque, args: GoTo.Args, call: *Command.Call) anyerror!void {
            if (args.line == 0) return call.fail("lines count from 1", .{});
            moved_to = args.line;
            try call.returns(.{ .line = args.line, .column = args.column });
        }
        fn tidy(_: *anyopaque, args: Tidy.Args, _: *Command.Call) anyerror!void {
            moved_to = args.width;
        }
        fn plain(_: *anyopaque) anyerror!void {
            plain_runs += 1;
        }
        fn isEnabled(_: *anyopaque) bool {
            return enabled;
        }
        fn ask(_: *anyopaque, id: []const u8) bool {
            asked = id;
            return true;
        }
    };

    const vtable = Plugin.VTable{};
    var state: u8 = 0;
    var plugin = Plugin{ .state = &state, .vtable = &vtable, .id = "t", .display_name = "T" };

    // A command that could never run is refused at registration.
    try testing.expectError(error.CommandCannotRun, host.registerCommand(.{ .id = "t.none", .owner = &plugin, .title = "None" }));

    try host.registerCommand(.{ .id = "t.goTo", .owner = &plugin, .title = "Go To", .params = S.GoTo.params, .runWith = S.GoTo.bind(S.goTo), .isEnabled = S.isEnabled });
    try host.registerCommand(.{ .id = "t.tidy", .owner = &plugin, .title = "Tidy", .params = S.Tidy.params, .runWith = S.Tidy.bind(S.tidy) });
    try host.registerCommand(.{ .id = "t.plain", .owner = &plugin, .title = "Plain", .run = S.plain });

    try testing.expectEqual(@as(usize, 3), host.commandCount());
    try testing.expectEqualStrings("t.tidy", host.commandAt(1).?.id);
    try testing.expectEqual(@as(?*const Command, null), host.commandAt(3));

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const results = arena_state.allocator();

    // Arguments in, result out.
    const ok = host.callCommand("t.goTo", ".{ .line = 12 }", results);
    try testing.expectEqualStrings(".{ .line = 12, .column = 1 }", ok.ok.?);
    try testing.expectEqual(@as(?u32, 12), S.moved_to);

    // Arguments that do not fit, and a command that refuses: each says why, in words.
    const missing = host.callCommand("t.goTo", "", results);
    try testing.expect(std.mem.indexOf(u8, missing.bad_args, "line") != null);
    try testing.expectEqualStrings("lines count from 1", host.callCommand("t.goTo", ".{ .line = 0 }", results).failed);

    // Disabled and unknown are their own answers, not failures.
    S.enabled = false;
    try testing.expect(host.callCommand("t.goTo", ".{ .line = 3 }", results) == .disabled);
    S.enabled = true;
    try testing.expect(host.callCommand("t.nope", "", results) == .unknown);

    // A command without `runWith` takes no arguments.
    try testing.expect(host.callCommand("t.plain", "", results).ok == null);
    try testing.expectEqual(@as(u32, 1), S.plain_runs);
    try testing.expect(host.callCommand("t.plain", ".{ .x = 1 }", results) == .bad_args);
    try testing.expectEqual(@as(u32, 1), S.plain_runs);

    // `runCommand` on a `runWith`-only command: nothing required runs it with its defaults...
    try host.runCommand("t.tidy");
    try testing.expectEqual(@as(?u32, 80), S.moved_to);

    // ...and something required has the app ask for it.
    var api_vt: EditorAPI.VTable = undefined;
    api_vt.askCommandArguments = S.ask;
    var ctx: u8 = 0;
    host.installFizzyApi(.{ .ctx = &ctx, .vtable = &api_vt });
    try host.runCommand("t.goTo");
    try testing.expectEqualStrings("t.goTo", S.asked.?);
}

test "a surface's title can change: the Host keeps the copy, and frees it with the surface" {
    const noopCenter = struct {
        fn f(_: ?*anyopaque) anyerror!dvui.App.Result {
            return .ok;
        }
    }.f;
    var host = Host.init(testing.allocator);
    defer host.deinit();
    const Doc = struct {
        var title: []const u8 = "";
        fn path(_: *anyopaque, _: DocHandle) []const u8 {
            return "/chats/a.chat";
        }
        fn named(_: *anyopaque, _: DocHandle) ?[]const u8 {
            return if (title.len > 0) title else null;
        }
    };
    const vt = Plugin.VTable{ .documentPath = Doc.path, .documentTitle = Doc.named };
    var plugin = Plugin{ .state = undefined, .vtable = &vt, .id = "chat", .display_name = "Chat" };
    try host.registerPlugin(&plugin);

    // A plugin renames its own surface; the title it passed need not outlive the call.
    try host.registerSurface(.{ .id = "chat.chats", .owner = &plugin, .title = "Chats", .keywords = keywords.ide.sidebar, .draw = noopCenter });
    {
        var scratch = "Chats (3)".*;
        try host.setSurfaceTitle("chat.chats", &scratch);
        scratch[0] = 'X';
    }
    try testing.expectEqualStrings("Chats (3)", host.surfaceById("chat.chats").?.title);
    try host.setSurfaceTitle("chat.chats", "Chats (4)");
    try testing.expectEqualStrings("Chats (4)", host.surfaceById("chat.chats").?.title);
    try host.setSurfaceTitle("no.such", "ignored");

    // A document's tab keeps its file name until its owner names it, then follows the name.
    try host.registerSurface(.{ .id = "chat.doc:/chats/a.chat", .owner = &plugin, .title = "a.chat", .keywords = keywords.ide.main, .draw = noopCenter });
    const doc: DocHandle = .{ .ptr = undefined, .id = 1, .owner = &plugin };
    host.documentTitleChanged(doc);
    try testing.expectEqualStrings("a.chat", host.surfaceById("chat.doc:/chats/a.chat").?.title);
    Doc.title = "What is on the screen?";
    host.documentTitleChanged(doc);
    try testing.expectEqualStrings("What is on the screen?", host.surfaceById("chat.doc:/chats/a.chat").?.title);

    // Closing the document and unloading the plugin free the copies (the testing allocator checks).
    host.unregisterSurface("chat.doc:/chats/a.chat");
    host.unregisterPlugin(&plugin);
    try testing.expectEqual(@as(u32, 0), host.surface_titles.count());
}

test "a step is its author's, the person's when nobody else acts, and the top follows the owner" {
    var host: Host = .init(std.testing.allocator);
    defer host.deinit();
    const doc: u64 = 7;
    const claude: Author = .{ .kind = .agent, .plugin = "agent", .session = 1, .label = "Claude" };

    // Working alone: nothing kept.
    host.setInputAuthor(.person);
    host.recordStep(doc, .{ .kind = .added, .id = 1 });
    try std.testing.expectEqual(@as(usize, 0), host.step_authors.count());
    try std.testing.expect(host.topStep(doc) == null);

    // An agent's call: its step is its own, in one run, and on top.
    const outer = host.act(claude);
    host.recordStep(doc, .{ .kind = .added, .id = 2 });
    host.recordStep(doc, .{ .kind = .added, .id = 3 });
    host.endAct(outer);
    try std.testing.expect(host.stepAuthor(doc, 2).same(claude));
    try std.testing.expectEqualStrings("Claude", host.stepAuthor(doc, 3).label);
    try std.testing.expectEqual(host.step_authors.getPtr(doc).?.steps.get(2).?.run, host.step_authors.getPtr(doc).?.steps.get(3).?.run);
    try std.testing.expectEqual(@as(u64, 3), host.topStep(doc).?.id);

    // The person's step after it is theirs, and the top.
    host.recordStep(doc, .{ .kind = .added, .id = 4 });
    try std.testing.expectEqual(Author.Kind.person, host.stepAuthor(doc, 4).kind);
    try std.testing.expectEqual(Author.Kind.person, host.topStep(doc).?.author.kind);

    // The person undoes theirs: the agent's is on top again, as the owner says.
    host.recordStep(doc, .{ .kind = .undone, .id = 4, .top = 3 });
    try std.testing.expect(host.topStep(doc).?.author.same(claude));

    // A history started over knows no authors.
    host.recordStep(doc, .{ .kind = .restarted, .id = 0 });
    try std.testing.expectEqual(Author.Kind.person, host.stepAuthor(doc, 2).kind);
    try std.testing.expect(host.topStep(doc) == null);

    host.forgetDocumentAuthors(doc);
    try std.testing.expectEqual(@as(usize, 0), host.step_authors.count());
    try std.testing.expectEqual(@as(u64, 0), host.unattributed_steps);
}

test "acting: innermost wins, a run is the outermost act, and work put off acts again" {
    var host: Host = .init(std.testing.allocator);
    defer host.deinit();
    const claude: Author = .{ .kind = .agent, .plugin = "agent", .session = 1 };
    const tour: Author = .{ .kind = .tape, .plugin = "fizzy", .session = 9, .label = "the tour" };

    try std.testing.expectEqual(Author.Kind.unattributed, host.author().kind);
    host.setInputAuthor(.person);
    try std.testing.expectEqual(Author.Kind.person, host.author().kind);

    const a = host.act(claude);
    const run = host.acted().run;
    const b = host.act(tour);
    try std.testing.expect(host.author().same(tour));
    try std.testing.expectEqual(run, host.acted().run);
    host.endAct(b);
    try std.testing.expect(host.author().same(claude));
    const stored = host.acted();
    host.endAct(a);
    try std.testing.expectEqual(Author.Kind.person, host.author().kind);

    // A second call is a second run; the stored one acts again as itself.
    const c = host.act(claude);
    try std.testing.expect(host.acted().run != run);
    host.endAct(c);
    const d = host.actAgain(stored);
    try std.testing.expectEqual(run, host.acted().run);
    host.endAct(d);

    // The same author interned once; a label given later is kept.
    _ = host.act(.{ .kind = .agent, .plugin = "agent", .session = 1, .label = "Claude" });
    try std.testing.expectEqual(@as(usize, 3), host.authors.items.len);
    try std.testing.expectEqualStrings("Claude", host.author().label);
}

test "mayMerge: only the author's own step, so an agent never joins the person's run of typing" {
    var host: Host = .init(std.testing.allocator);
    defer host.deinit();
    const doc: u64 = 3;
    const claude: Author = .{ .kind = .agent, .plugin = "agent", .session = 1 };
    host.setInputAuthor(.person);
    host.recordStep(doc, .{ .kind = .added, .id = 1 });
    try std.testing.expect(host.mayMerge(doc, 1));

    const outer = host.act(claude);
    try std.testing.expect(!host.mayMerge(doc, 1));
    host.recordStep(doc, .{ .kind = .added, .id = 2 });
    try std.testing.expect(host.mayMerge(doc, 2));
    host.endAct(outer);
    try std.testing.expect(!host.mayMerge(doc, 2));

    // Nobody known acting is counted, and merges as the person would.
    host.setInputAuthor(null);
    try std.testing.expect(host.mayMerge(doc, 1));
    host.recordStep(doc, .{ .kind = .added, .id = 3 });
    try std.testing.expectEqual(@as(u64, 1), host.unattributed_steps);
}
