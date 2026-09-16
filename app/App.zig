//! The host runtime: the state an application built on fizzy runs unchanged.
//!
//! Plugins, their lifecycle and file-type ownership; the open documents and the save/close
//! bookkeeping; settings, recents and the keymap as the user configured them; the layout
//! state and the watchers. Fizzy's `Editor` embeds one and adds what is fizzy's own — its
//! shape, its menus, its commands and settings groups. The methods still live on `Editor`
//! and move here section by section; the fields moved first so every caller already names
//! the right owner.
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const sdk = @import("fizzy_sdk");

const App = @This();

const Layout = @import("layout/Layout.zig");
const Host = sdk.Host;
const PluginLoader = @import("root.zig").store.Loader;
const SettingsWatcher = @import("watch/SettingsWatcher.zig");
const FolderWatcher = @import("watch/FolderWatcher.zig");
const Keymap = @import("keymap/Keymap.zig");
pub const Settings = @import("settings/Settings.zig");
pub const Recents = @import("Recents.zig");

/// The app-wide general-purpose allocator.
gpa: std.mem.Allocator,

layout: Layout.State = .{},

/// The per-frame `Layout`, live only while the shape is drawing. A plugin declaring a region
/// through `Host.region` needs it, and it is a local in the draw loop by design — nothing about a
/// layout should outlive the frame that drew it.
frame_layout: ?*Layout = null,

/// Small per-frame allocations — path joins, null terminations, labels. Never freed one by
/// one; reset (`retain_capacity`) every frame.
arena: std.heap.ArenaAllocator,

/// Positions to reveal once their not-yet-open path finishes loading. Set by `revealPosition`
/// when the target is not open yet and drained once per frame. Rare and short-lived (usually at
/// most one, from a single goto-definition), so a linear per-frame scan is fine.
pending_reveals: std.ArrayListUnmanaged(PendingReveal) = .empty,

config_folder: []const u8,

palette_folder: []const u8,

/// Plugin registry + service locator exposed to plugins
host: Host,

/// Fizzy's implementation of the `files` service, registered in `postInit`. A field rather than
/// a temporary because the host stores the pointer.
files_service: sdk.services.files.Api = undefined,

/// The project's file set, shared with every plugin through `host.files`. The app owns it
/// because more than one plugin reads it — see `core.FileTable`. Its `env` is wired in
/// `postInit`, since the ignore rules and the watcher it asks about live on this same `Editor`
/// and so need its final address.
file_table: core.FileTable,

/// Keeps plugin dylibs mapped while their vtables are live (native only).
loaded_plugin_libs: std.ArrayListUnmanaged(PluginLoader.LoadedLib) = .empty,

/// Runtime bookkeeping of user-plugin ids that are present on disk but not loaded
/// (explicitly disabled, or freshly dropped into `plugins/` with no `.enabled = true`).
/// Persistence lives per-plugin as `.plugins.<id>.enabled` in `settings.zon` (R12) — this
/// list is only the UI/skip-load set for the current session. Freed in `deinit`.
disabled_plugin_ids: std.ArrayListUnmanaged([]const u8) = .empty,

/// Subset of `disabled_plugin_ids`: on disk with **no `.plugins.<id>.enabled` field on record at
/// all** — i.e. a build the user dropped in (or `zig build install`ed from a plugin repo) that
/// fizzy has never been told to run. Distinct from a plugin the user deliberately switched off,
/// which carries an explicit `.enabled = false`: that one is a settled decision and must stay
/// quiet, while this one is an undecided offer and gets the store's "Load" button plus the
/// file-association prompt on its first load (see `setPluginEnabled`). Runtime-only, like
/// `disabled_plugin_ids`; a decision either way (or an uninstall) drops the entry. Freed in
/// `deinit`.
undecided_plugin_ids: std.ArrayListUnmanaged([]const u8) = .empty,

/// Runtime bookkeeping of user-plugin ids the user opted **out** of store updates for
/// (`.plugins.<id>.auto_update = false` in `settings.zon`). Stored as the opt-out set rather than
/// the opt-in one because auto-update defaults to *on* — an absent entry is the overwhelmingly
/// common case and must not need a list membership to be right. Whether an update the pass finds
/// is applied silently or offered in the update window is `Settings.plugin_update_mode`, one
/// app-wide choice. Seeded by `seedPluginFlags`; freed in `deinit`.
auto_update_off_ids: std.ArrayListUnmanaged([]const u8) = .empty,

/// Fizzy-only pending `.plugins.<id>` reserved-field writes (id → changed fields), drained by
/// `writeMergedSettings` alongside `host.plugin_settings_pending`. Never touched by a
/// plugin itself — only by `setPluginEnabled` / `setPluginAutoUpdate` / store install. Keys are
/// app-allocator-owned.
plugin_flags_pending: std.StringArrayHashMapUnmanaged(PendingPluginFlags) = .empty,

/// Fizzy-only pending `.plugins.<id>.extensions` writes (id → the plugin's complete new list).
/// A separate map from `plugin_flags_pending` because the value is owned, variable-length data
/// rather than two bools: both the key and every extension string are app-allocator-owned and
/// freed when `writeMergedSettings` drains it. Written only by `resolveExtensionConflict`.
plugin_extensions_pending: std.StringArrayHashMapUnmanaged([]const []const u8) = .empty,

/// In-memory `ext → owning plugin id` map, rebuilt by `rebuildExtensionOwnerCache` from the
/// persisted per-plugin `.extensions` lists of the *currently loaded* plugins. Backs
/// `EditorAPI.extensionOwnerOverride`, i.e. step 1 of `Host.pluginForExtension`.
///
/// **Every string here is duped and owned by the Editor** — never a slice borrowed from
/// `plugin.id`, which lives inside a dylib image that `dlclose` can unmap out from under us
/// (see `Host.unregisterPlugin`'s ordering note).
extension_owner: std.StringArrayHashMapUnmanaged([]const u8) = .empty,

/// `.extensions` entries fizzy could not honor as written, rebuilt alongside `extension_owner`
/// and surfaced in Settings > File Types exactly as `keybind_conflicts` is surfaced in Keyboard
/// Shortcuts. Owned duped strings, freed on the next rebuild.
extension_conflicts: std.ArrayListUnmanaged(ExtensionConflict) = .empty,

/// Snapshot of dvui's *built-in* keybinds (`char_left`, `copy`, `next_widget`, …), taken in
/// `init` before fizzy adds its own. `Window.init` installs these once and never again,
/// so `rebuildKeybinds` — which wipes the map to drop an unloaded plugin's binds — must put
/// them back or every widget's caret/clipboard handling silently dies after the first plugin
/// load or unload. Keys are dvui's own static literals; only the map itself is owned here.
dvui_default_keybinds: std.StringHashMapUnmanaged(dvui.enums.Keybind) = .empty,

/// Resolved keybinding table: chord -> command id. Rebuilt by `Keybinds.buildKeymap`
/// whenever `rebuildKeybinds` runs (plugin load/unload), so a plugin's binds never outlive
/// the image their strings live in.
keymap: Keymap = .{},

/// Parsed `keybinds.zon`. Held because `keymap` borrows its command-id and owner-id strings —
/// it must outlive the keymap and is replaced wholesale on every rebuild.
keybinds_overrides: ?Keymap.zon.File = null,

/// Cached `Keymap.conflicts()` result from the last rebuild — owned, freed on next rebuild.
keybind_conflicts: ?[]Keymap.Conflict = null,

/// User plugins that failed to load this session, so the UI can tell the author what
/// went wrong instead of failing silently into the log. Populated by `loadUserPlugins`;
/// strings are owned here and freed in `deinit`. Surfaced in the Plugins store tab
/// (`PluginStore.zig`), not a startup dialog.
failed_user_plugins: std.ArrayListUnmanaged(FailedPlugin) = .empty,

settings: Settings = undefined,

recents: Recents = undefined,

/// The root folder that will be searched for files and a .fizproject file
folder: ?[]const u8 = null,

/// Folder strings unlinked from `folder` but possibly still borrowed by the frame in progress.
///
/// `EditorAPI.folder` hands plugins the pointer itself, and a plugin can close or switch the
/// project from *inside* its own draw — the file tree's project row does exactly that from its
/// context menu, then keeps drawing with the `path` it read at the top of the function. Freeing
/// there is a use-after-free in every caller still holding the slice, so the old string is
/// parked here and released at the top of the next frame instead (the same shape as the
/// workbench's retired directory listings).
folder_retired: std.ArrayListUnmanaged([]const u8) = .empty,

/// Set by `closeProjectFolder`; the teardown itself runs at the top of the next frame so plugin
/// `onFolderClose` hooks and the ignore-rule teardown never fire mid-draw either.
pending_folder_close: bool = false,

open_files: std.AutoArrayHashMapUnmanaged(u64, sdk.DocHandle) = .empty,

file_id_counter: u64 = 0,

/// Filled from the async SDL save dialog callback, then applied inside `tick` (when `currentWindow` is valid).
pending_save_as_path: ?[]u8 = null,

/// After Save As from "Save and Close", close this file id once save completes.
pending_close_file_id: ?u64 = null,

/// Files whose async save was kicked off by "Save and Close" (single-doc) — once
/// `File.isSaving()` clears, `tickPendingSaveCloses` closes the file. Set is fine
/// because at most one entry per file (saveAsync no-ops while already saving).
pending_close_after_save: std.AutoArrayHashMapUnmanaged(u64, void) = .empty,

/// "Save all and quit" queue. Walked by `advanceSaveAllQuit`: items move from this
/// queue into `quit_saves_in_flight` when their save kicks off, then drop out when
/// their save completes and the file closes. Non-empty (or in-flight non-empty) ⇒
/// save-all quit in progress.
quit_save_all_ids: std.ArrayListUnmanaged(u64) = .empty,

/// Files whose async save was started as part of save-all quit and we're waiting on.
/// When this AND `quit_save_all_ids` are both empty, the quit completes.
quit_saves_in_flight: std.AutoArrayHashMapUnmanaged(u64, void) = .empty,

/// True during save-all quit (nested Save As / flat-raster prompts).
quit_in_progress: bool = false,

/// Next frame: continue save-all quit (`advanceSaveAllQuit`).
pending_quit_continue: bool = false,

/// End this frame with `App.Result.close` (e.g. quit finished).
pending_app_close: bool = false,

/// Hash of the last serialized settings.zon text written or captured at startup; avoids
/// redundant writes without keeping a full duplicate copy of the text around. Doubles as the
/// "was that change ours" filter for `settings_watcher` (see R11 in
/// docs/PLUGIN_MANIFEST_PLAN.md) — a change to disk whose hash matches this is our own last
/// write, not an external edit worth reconciling.
settings_last_saved_hash: ?u64 = null,

/// True after user-driven settings edits until successfully persisted or snapshot matches disk.
settings_dirty: bool = false,

/// Monotonic deadline (`perf.nanoTimestamp()`): autosave runs when dirty and `now >= deadline`.
settings_save_deadline_ns: i128 = 0,

/// Watches `<config>/` recursively (via nightwatch — see R12) for external `settings.zon`
/// changes and newly-created plugin directories, reconciling them live via `tick`. Null on wasm,
/// on an unsupported OS, or if starting the watch failed — all best-effort: fizzy must never
/// fail to launch because the watcher couldn't start, it just silently doesn't get live
/// reconciliation. Set up in `postInit` (needs `editor` at its final heap address — see
/// `SettingsWatcher.start`'s doc comment), torn down first in `deinit`.
settings_watcher: ?SettingsWatcher = null,

/// Recursive watch on the open root folder, fanned out to plugins as `folderPathsChanged`.
/// Same final-address constraint as the two above — started in `postInit`, retargeted whenever
/// the root folder changes.
folder_watcher: ?FolderWatcher = null,

/// One id's pending fizzy-reserved `.plugins.<id>` field writes. A null field means "not
/// touched this cycle" — `writeMergedSettings` reads that half back off disk instead, so
/// toggling auto-update can never clobber a concurrent enable/disable or vice versa.
/// One persisted `.extensions` entry fizzy declined to honor, surfaced to the user rather than
/// silently ignored — the same treatment `Keymap.Conflict` gets in the Keyboard Shortcuts pane.
///
/// **Fizzy never produces one of these itself.** `resolveExtensionConflict` is the app's single
/// writer and always strips an extension from every other plugin's list before adding it, so a
/// conflict only ever arrives via a hand-edited (or hand-merged, e.g. synced across machines)
/// `settings.zon`. Reconciliation is read-only: the file is left exactly as the user wrote it
/// until they repair it from the File Types table.
pub const ExtensionConflict = struct {
    /// The extension (with dot) the unhonored entry names. Owned.
    ext: []const u8,
    /// The plugin id fizzy actually routes `ext` to. Null for `.stale`, where the entry is
    /// simply ignored and `ext` falls through to ordinary resolution. Owned when non-null.
    winner: ?[]const u8,
    /// The plugin id whose persisted entry was not honored. Owned.
    loser: []const u8,
    kind: Kind,

    pub const Kind = enum {
        /// Two or more loaded plugins persist the same extension. Alphabetically-first id wins.
        duplicate,
        /// The plugin no longer offers `ext` via `fileTypes` — an update dropped support — and
        /// it is not the fallback editor, so the entry no longer means anything.
        stale,
    };
};

pub const PendingPluginFlags = struct {
    /// `null` = leave whatever is on disk alone. Note the *value* is itself tri-state on disk
    /// (see `SettingsPluginsZon.Reserved.enabled`); use `erase` to get back to "no decision".
    enabled: ?bool = null,
    auto_update: ?bool = null,
    /// Wipe fizzy's decision record for this id — `.enabled` removed entirely and `.extensions`
    /// emptied, leaving the plugin's own `.settings` block untouched. Uninstall's flag, and the
    /// one thing that makes a later reinstall ask about file types again. Applied before the
    /// other fields, so an `.{ .erase = true, .enabled = true }` would still end up enabled.
    erase: bool = false,
};

/// Scan `<config_folder>/plugins/` for user-installed plugin dylibs and load each one.
///
/// Each sub-directory that contains `plugin.<ext>` is attempted in iteration order.
/// Failures are logged and skipped — a bad plugin never prevents the others from loading.
/// Built-in plugin IDs ("workbench", "text") are never overridden; any
/// user directory whose name collides with an already-registered plugin is skipped.
///
/// On success each loaded lib is appended to `loaded_plugin_libs` and the dvui context
/// + render bridge are synced once at the end. On wasm this is a no-op.
///
/// The user plugin directory does not need to exist; a missing directory is silently ignored.
/// A user plugin that failed to load, retained so the UI can surface it. `id` and `reason`
/// are heap-owned (app allocator) and freed in `deinit`.
pub const FailedPlugin = struct {
    id: []const u8,
    reason: []const u8,
    /// Optional version / SDK detail when the dylib could be opened for probing.
    detail: ?[]const u8 = null,
    /// The plugin's own declared version, probed straight from the dylib without registering
    /// it. Lets the store show "current version" for a build that is on disk but rejected —
    /// null only when the dylib couldn't even be opened for probing.
    plugin_version: ?std.SemanticVersion = null,
    /// The rejected build's mtime + size when it was recorded, so
    /// `reconcileFailedPluginBinaries` can tell "still the same broken file" from "the author
    /// rebuilt it". Both zero when the stat failed, which reads as "never matches" — the safe
    /// direction, same as `PluginLoader.LoadedLib`'s stamp.
    source_mtime_ns: i128 = 0,
    source_size: u64 = 0,
};

/// Applies and clears any pending reveal whose target has finished loading. Called once per
/// frame from `tick`.
pub const PendingReveal = struct {
    path: []const u8,
    line: u32,
    character: u32,
};
