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
pub const Secrets = @import("Secrets.zig");
const sdk = @import("fizzy_sdk");
const builtin = @import("builtin");
const build_opts = @import("build_opts");
const SettingsPluginsZon = @import("settings/SettingsPluginsZon.zig");

const App = @This();

/// A file's mtime + size, the pair every "did this build change underneath us?" check in this
/// file compares. Zeroes when the file could not be stat'd, which reads as "matches nothing".
pub const FileStamp = struct {
    mtime_ns: i128 = 0,
    size: u64 = 0,

    pub fn of(path: []const u8) FileStamp {
        if (comptime builtin.target.cpu.arch == .wasm32) return .{};
        const st = std.Io.Dir.cwd().statFile(dvui.io, path, .{}) catch return .{};
        return .{ .mtime_ns = st.mtime.nanoseconds, .size = st.size };
    }

    pub fn eql(self: FileStamp, other: FileStamp) bool {
        return self.mtime_ns == other.mtime_ns and self.size == other.size;
    }
};

/// Three-way form of `readPluginEnabled`: `.unset` (no `.enabled` field on record at all) is
/// what separates a freshly dropped-in plugin from one the user deliberately switched off — both
/// are "not enabled", but only the first is an undecided offer (see `undecided_plugin_ids`).
pub const PluginEnabledState = enum { unset, enabled, disabled };

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
/// Credentials plugins keep on the user's behalf, out of `settings.zon`. See `Secrets.zig`.
secrets: Secrets,

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

/// True when `id` takes store updates — the default for every plugin, so this answers "not on the
/// opt-out list". Says nothing about *how* an update is applied: that is
/// `Settings.plugin_update_mode`, which `PluginStore`'s pass reads once for all plugins.
pub fn isPluginAutoUpdate(app: *const App, id: []const u8) bool {
    for (app.auto_update_off_ids.items) |d| {
        if (std.mem.eql(u8, d, id)) return false;
    }
    return true;
}

pub fn isPluginDisabled(app: *App, id: []const u8) bool {
    for (app.disabled_plugin_ids.items) |d| {
        if (std.mem.eql(u8, d, id)) return true;
    }
    return false;
}

/// True when `id` is on disk but fizzy has never been told whether to run it (no
/// `.plugins.<id>.enabled` on record) — see `undecided_plugin_ids`. The store draws these with a
/// "Load" button rather than the settled Enabled checkbox a deliberately-disabled plugin gets.
pub fn isPluginUndecided(app: *const App, id: []const u8) bool {
    for (app.undecided_plugin_ids.items) |d| {
        if (std.mem.eql(u8, d, id)) return true;
    }
    return false;
}

/// True when `id` looks like a real plugin id (ASCII identifier), not corrupted settings data.
pub fn isValidPluginId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    if (!std.unicode.utf8ValidateSlice(id)) return false;
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

/// Mirror `id`'s auto-update flag into the runtime opt-out list. Runtime bookkeeping only —
/// persistence goes through `setPluginAutoUpdate`.
pub fn trackAutoUpdate(app: *App, id: []const u8, on: bool) !void {
    if (on) {
        for (app.auto_update_off_ids.items, 0..) |d, i| {
            if (std.mem.eql(u8, d, id)) {
                app.gpa.free(app.auto_update_off_ids.orderedRemove(i));
                return;
            }
        }
        return;
    }
    if (!app.isPluginAutoUpdate(id)) return; // already opted out
    if (!isValidPluginId(id)) return error.InvalidPluginId;
    const dup = try app.gpa.dupe(u8, id);
    errdefer app.gpa.free(dup);
    try app.auto_update_off_ids.append(app.gpa, dup);
}

/// Add `id` to the runtime disabled bookkeeping list if not already present. Does **not**
/// write settings — a freshly dropped-in plugin stays off-disk-silent until the user enables it.
pub fn trackDisabledPlugin(app: *App, id: []const u8) !void {
    if (app.isPluginDisabled(id)) return;
    if (!isValidPluginId(id)) return error.InvalidPluginId;
    const dup = try app.gpa.dupe(u8, id);
    errdefer app.gpa.free(dup);
    try app.disabled_plugin_ids.append(app.gpa, dup);
}

/// Mark `id` as an undiscovered-until-now drop-in. Writes nothing: the whole point is that no
/// `.enabled` field exists yet.
pub fn trackUndecidedPlugin(app: *App, id: []const u8) !void {
    if (app.isPluginUndecided(id)) return;
    if (!isValidPluginId(id)) return error.InvalidPluginId;
    const dup = try app.gpa.dupe(u8, id);
    errdefer app.gpa.free(dup);
    try app.undecided_plugin_ids.append(app.gpa, dup);
}

pub fn untrackDisabledPlugin(app: *App, id: []const u8) void {
    for (app.disabled_plugin_ids.items, 0..) |d, i| {
        if (std.mem.eql(u8, d, id)) {
            const owned = app.disabled_plugin_ids.orderedRemove(i);
            app.gpa.free(owned);
            return;
        }
    }
}

/// Drop `id`'s undecided status — called from every path that records an explicit decision
/// (`setPluginEnabledPersisted`, either direction) or removes the plugin entirely
/// (`uninstallPlugin`).
pub fn untrackUndecidedPlugin(app: *App, id: []const u8) void {
    for (app.undecided_plugin_ids.items, 0..) |d, i| {
        if (std.mem.eql(u8, d, id)) {
            app.gpa.free(app.undecided_plugin_ids.orderedRemove(i));
            return;
        }
    }
}

/// How many on-disk plugins are waiting for a load decision — what the sidebar's Plugins badge
/// counts (see `Sidebar.drawOption`). Kept honest by `pruneMissingUndecidedPlugins`.
pub fn undecidedPluginCount(app: *const App) usize {
    return app.undecided_plugin_ids.items.len;
}

pub fn appendLoadedPluginLib(app: *App, loaded: PluginLoader.LoadedLib) !void {
    const id_owned = try app.gpa.dupe(u8, loaded.plugin_id);
    var stored = loaded;
    stored.plugin_id = id_owned;
    try app.loaded_plugin_libs.append(app.gpa, stored);
}

/// Drop any recorded load-failure for `id` (freeing its strings). Called when the plugin later
/// loads successfully or is uninstalled, so a stale failure no longer lingers in the UI / dialog.
pub fn clearFailedUserPlugin(app: *App, id: []const u8) void {
    var i: usize = 0;
    while (i < app.failed_user_plugins.items.len) {
        if (std.mem.eql(u8, app.failed_user_plugins.items[i].id, id)) {
            const f = app.failed_user_plugins.orderedRemove(i);
            app.gpa.free(f.id);
            app.gpa.free(f.reason);
            if (f.detail) |d| app.gpa.free(d);
        } else i += 1;
    }
}

/// `Host.pluginForExtension`, but pretending `skip` is not loaded — what would open `ext` if this
/// plugin had never arrived. Mirrors that function's resolution order exactly, including its
/// alphabetical tie-break, so the "prior owner" shown in the dialog is the one the user would
/// actually have gotten.
pub fn extensionOwnerExcluding(app: *App, raw_ext: []const u8, skip: *sdk.Plugin) ?*sdk.Plugin {
    var buf: [64]u8 = undefined;
    const ext = sdk.Host.lowerExtension(&buf, raw_ext);
    if (app.extension_owner.get(ext)) |owner_id| {
        if (app.host.pluginById(owner_id)) |p| {
            if (p != skip and app.host.ownsExtension(p, ext)) return p;
        }
    }
    var best: ?*sdk.Plugin = null;
    for (app.host.plugins.items) |plugin| {
        if (plugin == skip) continue;
        for (plugin.fileTypes()) |e| {
            if (std.mem.eql(u8, e, ext)) {
                if (best == null or std.mem.lessThan(u8, plugin.id, best.?.id)) best = plugin;
                break;
            }
        }
    }
    if (best) |p| return p;
    return app.host.fallback_editor;
}

pub fn clearExtensionOwnerCache(app: *App) void {
    const gpa = app.gpa;
    {
        var it = app.extension_owner.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            gpa.free(e.value_ptr.*);
        }
        app.extension_owner.clearAndFree(gpa);
    }
    for (app.extension_conflicts.items) |c| {
        gpa.free(c.ext);
        gpa.free(c.loser);
        if (c.winner) |w| gpa.free(w);
    }
    app.extension_conflicts.clearAndFree(gpa);
}

pub fn recordExtensionConflict(
    app: *App,
    ext: []const u8,
    winner: ?[]const u8,
    loser: []const u8,
    kind: ExtensionConflict.Kind,
) void {
    const gpa = app.gpa;
    const ext_owned = gpa.dupe(u8, ext) catch return;
    errdefer gpa.free(ext_owned);
    const loser_owned = gpa.dupe(u8, loser) catch {
        gpa.free(ext_owned);
        return;
    };
    errdefer gpa.free(loser_owned);
    const winner_owned: ?[]const u8 = if (winner) |w| (gpa.dupe(u8, w) catch {
        gpa.free(ext_owned);
        gpa.free(loser_owned);
        return;
    }) else null;
    app.extension_conflicts.append(gpa, .{
        .ext = ext_owned,
        .winner = winner_owned,
        .loser = loser_owned,
        .kind = kind,
    }) catch {
        gpa.free(ext_owned);
        gpa.free(loser_owned);
        if (winner_owned) |w| gpa.free(w);
    };
}

pub fn docAt(app: *App, index: usize) ?sdk.DocHandle {
    if (index >= app.open_files.values().len) return null;
    return app.open_files.values()[index];
}

pub fn docById(app: *App, id: u64) ?sdk.DocHandle {
    return app.open_files.get(id);
}

pub fn newFileID(app: *App) u64 {
    app.file_id_counter += 1;
    return app.file_id_counter;
}

/// Heap-owned path like `untitled-1`, unique among open-document basenames.
pub fn allocNextUntitledPath(app: *App) ![]u8 {
    var max_n: u32 = 0;
    for (app.open_files.values()) |doc| {
        const base = std.fs.path.basename(doc.owner.documentPath(doc));
        if (std.mem.startsWith(u8, base, "untitled-")) {
            const suffix = base["untitled-".len..];
            const n = std.fmt.parseUnsigned(u32, suffix, 10) catch continue;
            max_n = @max(max_n, n);
        } else if (std.mem.eql(u8, base, "untitled")) {
            max_n = @max(max_n, 1);
        }
    }
    return std.fmt.allocPrint(app.gpa, "untitled-{d}", .{max_n + 1});
}

pub fn abortSaveAllQuit(app: *App) void {
    app.quit_save_all_ids.clearAndFree(app.gpa);
    app.quit_saves_in_flight.clearRetainingCapacity();
    app.quit_in_progress = false;
    app.pending_close_file_id = null;
    app.pending_quit_continue = false;
}

/// Move the current folder string out of `folder` without freeing it — see `folder_retired`.
pub fn retireFolder(app: *App) void {
    const folder = app.folder orelse return;
    app.folder = null;
    app.folder_retired.append(app.gpa, folder) catch app.gpa.free(folder);
}

/// Release folder strings retired by earlier frames. Called at the top of `tick`, before
/// anything draws, which is the one point at which nothing can still be holding one.
pub fn releaseRetiredFolders(app: *App) void {
    for (app.folder_retired.items) |folder| app.gpa.free(folder);
    app.folder_retired.clearRetainingCapacity();
}

/// `<config>/plugins/<id>/<id>.<ext>` — where a user plugin's build lives. Caller frees.
pub fn userPluginPath(gpa: std.mem.Allocator, app: *App, id: []const u8) ![]u8 {
    const file_name = try PluginLoader.pluginFilename(id, gpa);
    defer gpa.free(file_name);
    return std.fs.path.join(gpa, &.{ app.config_folder, "plugins", id, file_name });
}

/// Point a loaded plugin's stamp at whatever is on disk now. See the re-stamp comment in
/// `reconcileChangedPluginBinaries`; no-op if `id` isn't loaded or the file can't be stat'd.
pub fn restampLoadedPlugin(app: *App, id: []const u8) void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    for (app.loaded_plugin_libs.items) |*loaded| {
        if (!std.mem.eql(u8, loaded.plugin_id, id)) continue;
        const st = std.Io.Dir.cwd().statFile(dvui.io, loaded.path, .{}) catch return;
        loaded.source_mtime_ns = st.mtime.nanoseconds;
        loaded.source_size = st.size;
        return;
    }
}

/// True if `plugin` owns any currently-dirty open document.
pub fn pluginHasDirtyDocs(app: *App, plugin: *sdk.Plugin) bool {
    for (app.open_files.values()) |doc| {
        if (doc.owner == plugin and doc.owner.isDirty(doc)) return true;
    }
    return false;
}

/// True if `plugin` owns any document with an async save still in flight.
pub fn pluginHasSavingDocs(app: *App, plugin: *sdk.Plugin) bool {
    for (app.open_files.values()) |doc| {
        if (doc.owner == plugin and doc.owner.isDocumentSaving(doc)) return true;
    }
    return false;
}

pub fn saving(app: *App) bool {
    for (app.open_files.values()) |doc| {
        if (doc.owner.isDocumentSaving(doc)) return true;
    }
    return false;
}

/// Open documents of extension `ext` whose owner is no longer the plugin that would open `ext`
/// today — i.e. documents left behind by a reassignment. Reassigning never closes anything, so
/// these keep working under their original owner; this is what lets the File Types table offer
/// to reopen them. Returned ids are stable across the call; the slice is caller-owned.
pub fn staleOpenDocsForExtension(app: *App, gpa: std.mem.Allocator, ext: []const u8) ![]u64 {
    const want = app.host.pluginForExtension(ext) orelse return &.{};
    var out: std.ArrayListUnmanaged(u64) = .empty;
    errdefer out.deinit(gpa);
    for (app.open_files.values()) |doc| {
        if (doc.owner == want) continue;
        const path = doc.owner.documentPath(doc);
        if (!std.mem.eql(u8, std.fs.path.extension(path), ext)) continue;
        try out.append(gpa, doc.id);
    }
    return out.toOwnedSlice(gpa);
}

/// Reads `.plugins.<id>.auto_update` from already-loaded `settings_data`. **Defaults to true** —
/// a missing `.plugins`, a missing id, or an omitted field all mean "keep this plugin current";
/// only an explicit `false` opts out. Deliberately the inverse of `readPluginEnabled`'s default:
/// a plugin has to be turned on by hand, but once it is on it tracks the store unless told
/// otherwise.
pub fn readPluginAutoUpdate(gpa: std.mem.Allocator, settings_data: ?[:0]const u8, id: []const u8) bool {
    const text = readPluginReservedField(gpa, settings_data, id, "auto_update") orelse return true;
    defer gpa.free(text);
    return !std.mem.eql(u8, std.mem.trim(u8, text, " \t\r\n"), "false");
}

/// Reads `.plugins.<id>.enabled` from already-loaded `settings_data` (null source → false).
/// Missing `.plugins` / missing id / missing or non-`true` `.enabled` all mean disabled.
pub fn readPluginEnabled(gpa: std.mem.Allocator, settings_data: ?[:0]const u8, id: []const u8) bool {
    return readPluginEnabledState(gpa, settings_data, id) == .enabled;
}

pub fn readPluginEnabledState(gpa: std.mem.Allocator, settings_data: ?[:0]const u8, id: []const u8) PluginEnabledState {
    const text = readPluginReservedField(gpa, settings_data, id, "enabled") orelse return .unset;
    defer gpa.free(text);
    return if (std.mem.eql(u8, std.mem.trim(u8, text, " \t\r\n"), "true")) .enabled else .disabled;
}

/// Reads `.plugins.<id>.extensions` from already-loaded `settings_data`. Empty (never null) when
/// absent or unparseable — a hand-edited file must degrade to "no explicit choice", not an error.
/// Caller frees with `SettingsPluginsZon.freeExtensions`.
pub fn readPluginExtensions(gpa: std.mem.Allocator, settings_data: ?[:0]const u8, id: []const u8) []const []const u8 {
    const text = readPluginReservedField(gpa, settings_data, id, "extensions") orelse return &.{};
    defer gpa.free(text);
    return SettingsPluginsZon.parseExtensions(gpa, text) catch &.{};
}

/// Reads one fizzy-reserved `.plugins.<id>.<field>` value as verbatim text (caller-owned), or
/// null when any level of the nest is absent. Shared by the `.enabled` / `.auto_update` readers,
/// which differ only in how they interpret a missing value.
pub fn readPluginReservedField(gpa: std.mem.Allocator, settings_data: ?[:0]const u8, id: []const u8, field: []const u8) ?[]u8 {
    const data = settings_data orelse return null;
    const plugins = SettingsPluginsZon.extractField(gpa, data, "plugins") orelse return null;
    defer gpa.free(plugins);
    const plugins_z = gpa.dupeZ(u8, plugins) catch return null;
    defer gpa.free(plugins_z);
    const id_block = SettingsPluginsZon.extractField(gpa, plugins_z, id) orelse return null;
    defer gpa.free(id_block);
    const id_z = gpa.dupeZ(u8, id_block) catch return null;
    defer gpa.free(id_z);
    return SettingsPluginsZon.extractField(gpa, id_z, field);
}

/// Reads `.plugins.<id>.settings` from already-loaded `settings_data`. Null if absent.
pub fn readPluginSettingsText(gpa: std.mem.Allocator, settings_data: ?[:0]const u8, id: []const u8) ?[]u8 {
    const data = settings_data orelse return null;
    const plugins = SettingsPluginsZon.extractField(gpa, data, "plugins") orelse return null;
    defer gpa.free(plugins);
    const plugins_z = gpa.dupeZ(u8, plugins) catch return null;
    defer gpa.free(plugins_z);
    const id_block = SettingsPluginsZon.extractField(gpa, plugins_z, id) orelse return null;
    defer gpa.free(id_block);
    const id_z = gpa.dupeZ(u8, id_block) catch return null;
    defer gpa.free(id_z);
    return SettingsPluginsZon.extractField(gpa, id_z, "settings");
}

/// Wake a frame once `remaining_ns` has elapsed so a debounced save actually fires while the app
/// is otherwise idle. Without this, the very event that dirtied the state (a settings-pane click,
/// a splitter drag release) is typically the *last* one before the app goes back to sleep, so no
/// frame ever runs to observe the deadline — the write, and everything that hangs off it (the
/// open settings.zon tab's reload via `writeMergedSettings`' `notifyPathChanged`), would wait on
/// some unrelated input instead. Same pattern/rationale as `drawSaveToasts`' threshold wakeup.
/// In-frame only; both callers run inside `tick`. `id_extra` keeps the two debounces from
/// sharing (and overwriting) one timer slot.
pub fn scheduleSaveWakeup(remaining_ns: i128, id_extra: usize) void {
    const remaining_us = @divTrunc(remaining_ns, std.time.ns_per_us);
    const clamped: i32 = if (remaining_us >= std.math.maxInt(i32))
        std.math.maxInt(i32)
    else
        @intCast(@max(1, remaining_us));
    dvui.timer(dvui.Id.extendId(null, @src(), id_extra), clamped);
}

pub fn themeFilenameToName(trimmed: []const u8) ?[]const u8 {
    const pairs = [_]struct { stub: []const u8, canonical: []const u8 }{
        .{ .stub = "fizzy_dark.json", .canonical = "Fizzy Dark" },
        .{ .stub = "fizzy_light.json", .canonical = "Fizzy Light" },
    };
    for (pairs) |p| {
        if (std.mem.eql(u8, trimmed, p.stub)) return p.canonical;
    }
    return null;
}

/// Human-readable, actionable explanation for a `PluginLoader.LoadError`.
pub fn pluginLoadFailureReason(err: PluginLoader.LoadError) []const u8 {
    return switch (err) {
        error.AbiMismatch => "built against an incompatible Fizzy SDK — rebuild the plugin against this Fizzy build",
        error.AbiBuildEnvMismatch => "SDK versions match, but optimize mode does not match",
        error.SdkVersionMismatch => "requires a newer Fizzy SDK — update Fizzy or install a matching plugin build",
        error.PluginIdMismatch => "plugin id in the dylib does not match its filename — rename the file or fix manifest.id",
        error.DylibOpenFailed => "the plugin library could not be opened (missing file, wrong architecture, or unresolved symbols)",
        error.RegisterRejected => "the plugin's register() was rejected (often a duplicate plugin id — a built-in or another plugin already claims it)",
        error.AbiFingerprintSymbolMissing,
        error.RegisterSymbolMissing,
        error.SetGlobalsSymbolMissing,
        error.SetDvuiContextSymbolMissing,
        error.SetRenderBridgeSymbolMissing,
        error.SdkVersionSymbolMissing,
        => "the plugin is missing required entry symbols — rebuild it from a current root.zig template",
    };
}

pub fn formatPluginProbeDetail(allocator: std.mem.Allocator, info: PluginLoader.PluginVersionInfo) ![]const u8 {
    return std.fmt.allocPrint(allocator, "plugin {d}.{d}.{d}, min SDK {d}.{d}.{d}", .{
        info.plugin_version.major,
        info.plugin_version.minor,
        info.plugin_version.patch,
        info.min_sdk_version.major,
        info.min_sdk_version.minor,
        info.min_sdk_version.patch,
    });
}

/// Tear down a document via its owning plugin, falling back to a direct `deinit`.
/// Removes the entry from the plugin's document registry; fizzy still removes
/// the matching `DocHandle` from `open_files`.
pub fn closeDocumentResources(_: *App, doc: sdk.DocHandle) void {
    _ = doc.owner.closeDocument(doc);
    doc.owner.unregisterDocument(doc.id);
}

/// Queue the project close; the teardown runs at the top of the next frame
/// (`applyPendingFolderClose`).
///
/// Deferred because this is reachable from inside a plugin's draw — the file tree's
/// project-row context menu calls it through `Host.closeProjectFolder` and then goes on to
/// draw the project row, its rows, and its ignore-screened listings using the folder it read
/// before the menu ran. Tearing all of that down underneath the draw that is still using it
/// crashes in whatever touches the folder string next.
pub fn closeProjectFolder(app: *App) void {
    if (app.folder == null) return;
    app.pending_folder_close = true;
}

/// One-shot: moves any pre-R10 flat `{plugins_dir}/{id}.{ext}` into its own
/// `{plugins_dir}/{id}/{id}.{ext}` directory (see docs/PLUGIN_MANIFEST_PLAN.md R10). Collects the
/// list of flat files first, then renames in a second pass, so mutating the directory never races
/// the iterator that's still walking it. Best-effort: a single failed rename is logged and
/// skipped rather than aborting the rest.
pub fn migrateFlatPluginLayout(allocator: std.mem.Allocator, plugins_dir: []const u8, ext_suffix: []const u8) void {
    var flat_ids: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (flat_ids.items) |id| allocator.free(id);
        flat_ids.deinit(allocator);
    }
    {
        var dir = std.Io.Dir.cwd().openDir(dvui.io, plugins_dir, .{ .iterate = true }) catch return;
        defer dir.close(dvui.io);
        var iter = dir.iterate();
        while (iter.next(dvui.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ext_suffix)) continue;
            const dot = std.mem.lastIndexOf(u8, entry.name, ".") orelse continue;
            const id = entry.name[0..dot];
            if (id.len == 0) continue;
            const dup = allocator.dupe(u8, id) catch continue;
            flat_ids.append(allocator, dup) catch allocator.free(dup);
        }
    }

    for (flat_ids.items) |id| {
        const new_dir = std.fs.path.join(allocator, &.{ plugins_dir, id }) catch continue;
        defer allocator.free(new_dir);
        std.Io.Dir.createDirAbsolute(dvui.io, new_dir, .default_dir) catch {}; // best-effort; exists is fine

        const file_name = PluginLoader.pluginFilename(id, allocator) catch continue;
        defer allocator.free(file_name);
        const old_path = std.fs.path.join(allocator, &.{ plugins_dir, file_name }) catch continue;
        defer allocator.free(old_path);
        const new_path = std.fs.path.join(allocator, &.{ new_dir, file_name }) catch continue;
        defer allocator.free(new_path);

        std.Io.Dir.renameAbsolute(old_path, new_path, dvui.io) catch |err| {
            dvui.log.warn("plugin '{s}': failed to migrate to its own directory: {s}", .{ id, @errorName(err) });
        };
    }
}

/// Drop undecided entries whose `plugins/<id>/` directory is gone — the author deleted or moved
/// the build instead of answering the offer. Without this the rail badge would advertise a
/// decision the user can no longer make. Called from `reconcileDiscoveredPlugins`, which the
/// watcher already runs for any change under `<config>/` (a deleted directory very much included).
pub fn pruneMissingUndecidedPlugins(app: *App, plugins_dir: []const u8) void {
    const gpa = app.gpa;
    var i: usize = app.undecided_plugin_ids.items.len;
    while (i > 0) {
        i -= 1;
        const id = app.undecided_plugin_ids.items[i];
        const dir_path = std.fs.path.join(gpa, &.{ plugins_dir, id }) catch continue;
        defer gpa.free(dir_path);
        var dir = std.Io.Dir.cwd().openDir(dvui.io, dir_path, .{}) catch {
            gpa.free(app.undecided_plugin_ids.orderedRemove(i));
            continue;
        };
        dir.close(dvui.io);
    }
}

/// For every currently-loaded plugin with a registered settings schema, re-reads its
/// `.plugins.<id>.settings` blob and applies it if (and only if) it actually changed since the
/// last time we applied one — `SettingsSchema.last_applied_hash` is what stops a change to *one*
/// plugin's settings from spuriously renotifying *every other* loaded plugin just because the
/// whole file's hash moved (see `reconcileExternalSettingsChange`'s hash-gate, which only tells
/// us the file changed, not which plugin's part of it did).
pub fn reconcilePluginSettings(app: *App) void {
    for (app.host.settings_schemas.items) |*schema| {
        const blob = app.host.loadPluginSettings(schema.owner.id) orelse {
            // Settings section removed (all-defaults) — apply an empty blob so the live value
            // resets to T's own declared defaults, but only when we previously had something.
            if (schema.last_applied_hash == 0) continue;
            schema.access.applyBlob(schema.value, schema.owner, ".{}");
            schema.last_applied_hash = 0;
            dvui.log.info("settings watcher: cleared settings for '{s}' (external edit)", .{schema.owner.id});
            continue;
        };
        defer app.host.allocator.free(blob);
        const hash = std.hash.Wyhash.hash(0, blob);
        if (hash == schema.last_applied_hash) continue;
        schema.access.applyBlob(schema.value, schema.owner, blob);
        schema.last_applied_hash = hash;
        dvui.log.info("settings watcher: applied external settings change for '{s}'", .{schema.owner.id});
    }
}

/// Record a load failure for `id` (probing the on-disk build at `path` for its version/detail),
/// replacing any earlier record for the same id.
///
/// Every path that loads a user plugin routes its failures here — the startup scan *and* the live
/// ones (`loadUserPluginById`, reached from enable, store install, and update), so a failed
/// plugin is always in one of the three lists the store's installed pane is built from
/// (loaded / disabled / failed) rather than vanishing from the UI.
pub fn recordLoadFailure(app: *App, id: []const u8, path: []const u8, err: PluginLoader.LoadError) void {
    const reason = App.pluginLoadFailureReason(err);
    const probe = PluginLoader.probeVersionInfo(path);
    const detail: ?[]const u8 = if (probe) |info|
        App.formatPluginProbeDetail(app.gpa, info) catch null
    else
        null;
    defer if (detail) |d| app.gpa.free(d);
    // `recordPluginFailure` appends unconditionally; drop any prior record so repeated attempts
    // (enable → fail → enable → fail) leave one row, not a growing pile of duplicate cards.
    app.clearFailedUserPlugin(id);
    app.recordPluginFailure(id, reason, detail, if (probe) |info| info.plugin_version else null, .of(path));
}

/// Record a failed user-plugin load so the UI can surface it. `id` and `reason` are copied
/// (the caller keeps ownership of its arguments). Best-effort: on OOM the failure is dropped
/// after being logged at the call site.
pub fn recordPluginFailure(
    app: *App,
    id: []const u8,
    reason: []const u8,
    detail: ?[]const u8,
    plugin_version: ?std.SemanticVersion,
    stamp: FileStamp,
) void {
    const id_owned = app.gpa.dupe(u8, id) catch return;
    const reason_owned = app.gpa.dupe(u8, reason) catch {
        app.gpa.free(id_owned);
        return;
    };
    const detail_owned: ?[]const u8 = if (detail) |d| app.gpa.dupe(u8, d) catch null else null;
    if (detail_owned == null and detail != null) {
        app.gpa.free(id_owned);
        app.gpa.free(reason_owned);
        return;
    }
    app.failed_user_plugins.append(app.gpa, .{
        .id = id_owned,
        .reason = reason_owned,
        .detail = detail_owned,
        .plugin_version = plugin_version,
        .source_mtime_ns = stamp.mtime_ns,
        .source_size = stamp.size,
    }) catch {
        app.gpa.free(id_owned);
        app.gpa.free(reason_owned);
        if (detail_owned) |d| app.gpa.free(d);
    };
}

/// Buffer `id`'s complete new `.extensions` list. Takes ownership of `exts` and every string in
/// it. Buffered rather than written per call so one Confirm covering several extensions produces
/// a single `settings.zon` write; `resolveExtensionConflict` flushes at the end.
pub fn setPluginExtensionsPersisted(app: *App, id: []const u8, exts: []const []const u8) !void {
    const gpa = app.gpa;
    errdefer SettingsPluginsZon.freeExtensions(gpa, exts);
    if (app.plugin_extensions_pending.getPtr(id)) |slot| {
        SettingsPluginsZon.freeExtensions(gpa, slot.*);
        slot.* = exts;
        return;
    }
    const key = try gpa.dupe(u8, id);
    errdefer gpa.free(key);
    try app.plugin_extensions_pending.put(gpa, key, exts);
}

/// Push host dvui state into every loaded plugin dylib image.
pub fn syncLoadedPluginDvuiContexts(app: *App) void {
    for (app.loaded_plugin_libs.items) |loaded| {
        sdk.dvui_context.syncHostIntoPlugin(loaded.set_dvui_context);
    }
}

pub fn syncLoadedPluginGlobals(app: *App, plugin_id: []const u8, arg_b: *anyopaque, arg_c: ?*anyopaque) void {
    for (app.loaded_plugin_libs.items) |loaded| {
        if (!std.mem.eql(u8, loaded.plugin_id, plugin_id)) continue;
        loaded.set_globals(@ptrCast(&app.gpa), arg_b, arg_c);
    }
}

/// Inject the host render bridge into every loaded plugin dylib (proxy backend).
pub fn syncLoadedPluginRenderBridge(app: *App) void {
    for (app.loaded_plugin_libs.items) |loaded| {
        sdk.render_bridge.syncHostIntoPlugin(loaded.set_render_bridge);
    }
}

/// Spin until none of `plugin`'s open documents report `isDocumentSaving`. Called from
/// `unloadPlugin` on the GUI thread while the save-queue worker runs concurrently.
///
/// Nothing to wait for on the web, and nothing to wait *with*: there are no threads there, so a
/// save either finished inline or is a frame-driven task this spin would deadlock against.
pub fn waitForPluginSaves(app: *App, plugin: *sdk.Plugin) void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    while (app.pluginHasSavingDocs(plugin)) {
        std.Thread.yield() catch {};
    }
}

/// Whether a bundled plugin should be loaded from `{exe_dir}/plugins/<id>/` rather than the
/// copy linked in: never on wasm, not when the build pinned it static
/// (`build_opts.static_<id>`), and not when `FIZZY_STATIC_<ID>=1` is set — the bisection
/// switch for dylib loading trouble.
pub fn bundledDylibEnabled(gpa: std.mem.Allocator, comptime id: []const u8) bool {
    if (comptime builtin.target.cpu.arch == .wasm32) return false;
    if (comptime @hasDecl(build_opts, "static_" ++ id)) {
        if (comptime @field(build_opts, "static_" ++ id)) return false;
    }
    const env_name = comptime blk: {
        var buf: [id.len]u8 = undefined;
        for (id, 0..) |c, i| buf[i] = std.ascii.toUpper(c);
        break :blk "FIZZY_STATIC_" ++ buf;
    };
    if (std.process.Environ.getAlloc(core.platform.processEnviron(), gpa, env_name)) |v| {
        defer gpa.free(v);
        return v.len == 0 or v[0] == '0';
    } else |_| {}
    return true;
}

/// Load `{exe_dir}/plugins/<id>/<id>.{ext}` and register it through its dylib entry. `extra`
/// is the entry's third argument — what a plugin's dylib convention asks the application for,
/// null for most.
pub fn loadBundledDylib(app: *App, exe_dir: []const u8, id: []const u8, extra: ?*anyopaque) !void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    const path = try PluginLoader.builtinPluginPath(app.gpa, exe_dir, id);
    errdefer app.gpa.free(path);
    const loaded = try PluginLoader.loadAndRegister(&app.host, app.gpa, path, id, .{
        .gpa = &app.gpa,
        .arg_b = @ptrCast(&app.host),
        .arg_c = extra,
    });
    try app.appendLoadedPluginLib(loaded);
    app.syncLoadedPluginDvuiContexts();
    app.syncLoadedPluginRenderBridge();
}
