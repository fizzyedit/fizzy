const std = @import("std");
const builtin = @import("builtin");
const icons = @import("icons");
const assets = @import("assets");
const objc = @import("objc");

const cozette_ttf = assets.files.fonts.@"CozetteVector.ttf";
const cozette_bold_ttf = assets.files.fonts.@"CozetteVectorBold.ttf";

const comfortaa_ttf = assets.files.fonts.@"Comfortaa-Regular.ttf";
const comfortaa_bold_ttf = assets.files.fonts.@"Comfortaa-Bold.ttf";

const plus_jakarta_sans_ttf = assets.files.fonts.@"PlusJakartaSans-Regular.ttf";
const plus_jakarta_sans_bold_ttf = assets.files.fonts.@"PlusJakartaSans-Bold.ttf";

const build_opts = @import("build_opts");

const fizzy = @import("../fizzy.zig");
const dvui = @import("dvui");
const update_notify = @import("../backend/update_notify.zig");

const App = fizzy.App;
const Editor = @This();

pub const Recents = @import("Recents.zig");
pub const Settings = @import("Settings.zig");
pub const Dialogs = @import("dialogs/Dialogs.zig");

pub const Keybinds = @import("Keybinds.zig");
const KeybindSettings = @import("KeybindSettings.zig");
pub const menu_model = @import("menu_model.zig");

const workbench_mod = @import("workbench");
const text_mod = @import("text");
const markdown_mod = @import("markdown");
const image_mod = @import("image");

/// The bundled built-in modules, exactly the ones `postInit` imports and registers above.
/// Each exports its own `pub const plugin_id` (single source of truth — see e.g. `text_mod.plugin_id`)
/// instead of this list retyping the id strings a second time; adding a 5th built-in is one
/// line here, alongside its import/registration, not a separately-maintained string list.
const bundled_modules = .{ workbench_mod, text_mod, image_mod, markdown_mod };

const PluginLoader = if (builtin.target.cpu.arch == .wasm32)
    @import("PluginLoader_stub.zig")
else
    @import("PluginLoader.zig");
const PluginStore = @import("PluginStore.zig");
const PluginSettingsPane = @import("PluginSettingsPane.zig");
const SettingsTree = @import("SettingsTree.zig");
const OutputPanel = @import("OutputPanel.zig");
const SettingsPluginsZon = @import("SettingsPluginsZon.zig");
const SettingsWatcher = @import("SettingsWatcher.zig");
const Constants = @import("Constants.zig");
const DocumentWatcher = @import("DocumentWatcher.zig");

pub const Workspace = workbench_mod.Workspace;
pub const Explorer = @import("explorer/Explorer.zig");
pub const IgnoreRules = @import("explorer/IgnoreRules.zig");
pub const Panel = @import("panel/Panel.zig");
pub const Sidebar = @import("Sidebar.zig");
pub const Infobar = @import("Infobar.zig");
pub const Menu = @import("Menu.zig");
pub const FileLoadJob = workbench_mod.FileLoadJob;

pub const sdk = fizzy.sdk;
pub const Host = sdk.Host;

/// Workbench: the file-management home — file tree, open/load flow, and the
/// workspace/tabs/splits system, plus the per-branch explorer decoration registry.
pub const Workbench = workbench_mod.Workbench;

/// This arena is for small per-frame editor allocations, such as path joins, null terminations and labels.
/// Do not free these allocations, instead, this allocator will be .reset(.retain_capacity) each frame
arena: std.heap.ArenaAllocator,

config_folder: []const u8,
palette_folder: []const u8,

/// Plugin registry + service locator exposed to plugins
host: Host,

/// File-management workbench (per-branch explorer decorations, …)
workbench: Workbench,

/// Keeps plugin dylibs mapped while their vtables are live (native only).
loaded_plugin_libs: std.ArrayListUnmanaged(PluginLoader.LoadedLib) = .empty,

/// Runtime bookkeeping of user-plugin ids that are present on disk but not loaded
/// (explicitly disabled, or freshly dropped into `plugins/` with no `.enabled = true`).
/// Persistence lives per-plugin as `.plugins.<id>.enabled` in `settings.zon` (R12) — this
/// list is only the UI/skip-load set for the current session. Freed in `deinit`.
disabled_plugin_ids: std.ArrayListUnmanaged([]const u8) = .empty,

/// Shell-only pending `.plugins.<id>.enabled` writes (id → new bool), drained by
/// `writeMergedSettings` alongside `host.plugin_settings_pending`. Never touched by a
/// plugin itself — only by `setPluginEnabled` / store install. Keys are app-allocator-owned.
plugin_enabled_pending: std.StringArrayHashMapUnmanaged(bool) = .empty,

/// Snapshot of dvui's *built-in* keybinds (`char_left`, `copy`, `next_widget`, …), taken in
/// `init` before the shell adds its own. `Window.init` installs these once and never again,
/// so `rebuildKeybinds` — which wipes the map to drop an unloaded plugin's binds — must put
/// them back or every widget's caret/clipboard handling silently dies after the first plugin
/// load or unload. Keys are dvui's own static literals; only the map itself is owned here.
dvui_default_keybinds: std.StringHashMapUnmanaged(dvui.enums.Keybind) = .empty,
/// Resolved keybinding table: chord -> command id. Rebuilt by `Keybinds.buildKeymap`
/// whenever `rebuildKeybinds` runs (plugin load/unload), so a plugin's binds never outlive
/// the image their strings live in.
keymap: @import("keymap/keymap.zig").Keymap = .{},
/// Parsed `keybinds.zon`. Held because `keymap` borrows its command-id and owner-id strings —
/// it must outlive the keymap and is replaced wholesale on every rebuild.
keybinds_overrides: ?@import("keymap/keymap.zig").zon.File = null,
/// Cached `Keymap.conflicts()` result from the last rebuild — owned, freed on next rebuild.
keybind_conflicts: ?[]@import("keymap/keymap.zig").Conflict = null,
/// Which default keymap the shell starts from.
keybind_profile: Keybinds.Profile = .vscode,
/// VSCode-style Quick Open / command palette overlay.
command_palette: @import("CommandPalette.zig") = .{},

/// User plugins that failed to load this session, so the UI can tell the author what
/// went wrong instead of failing silently into the log. Populated by `loadUserPlugins`;
/// strings are owned here and freed in `deinit`. Surfaced in the Plugins store tab
/// (`PluginStore.zig`), not a startup dialog.
failed_user_plugins: std.ArrayListUnmanaged(FailedPlugin) = .empty,

settings: Settings = undefined,
recents: Recents = undefined,

explorer: *Explorer,
panel: *Panel,

last_titlebar_color: dvui.Color,

sidebar: Sidebar,
infobar: Infobar,

/// The root folder that will be searched for files and a .fizproject file
folder: ?[]const u8 = null,

/// Whether a text-input widget held keyboard focus at the end of the last frame.
///
/// `dvui.wantTextInput` is the cross-cutting signal — dvui's own `TextEntryWidget`, the text
/// plugin's fork, and any plugin entry all call it on frames they have focus — but it is reset
/// by `Window.begin` and filled in as widgets draw, so it can only be read as last frame's
/// answer. That is fine for deciding who owns a clipboard verb: focus doesn't change between
/// the keystroke and the frame that handles it.
text_input_focused: bool = false,
/// From `.fizignore` (preferred) or `.gitignore` at the project root; used by the Files explorer.
ignore: IgnoreRules = .{},

themes: std.ArrayList(dvui.Theme) = .empty,

open_files: std.AutoArrayHashMapUnmanaged(u64, sdk.DocHandle) = .empty,

/// Background file-load jobs in flight. Keyed by absolute path. Each job's worker thread loads
/// the document bytes off the main thread; the main thread polls via `processLoadingJobs`
/// and moves completed results into `open_files`. The map owns its key strings via each job's
/// `path` allocation; the StringHashMap stores key slices that point into job memory.
loading_jobs: std.StringHashMapUnmanaged(*FileLoadJob) = .empty,

/// True iff a loading job should set its target file as the active file once it lands.
/// `setActiveFile`-on-completion respects the most recent open request — multiple in-flight
/// loads only auto-focus the most recently requested one.
last_load_request_path: ?[]const u8 = null,

file_id_counter: u64 = 0,

window_opacity: f32 = 1.0,

/// Animated window-background opacity multiplier. Eases toward the windowed
/// target (translucent, vibrancy shows through) or 1.0 (opaque) when
/// maximized/fullscreen, so the vibrancy fades in/out across fullscreen
/// transitions instead of snapping. `< 0` is a sentinel meaning "snap to the
/// target on the first frame" so there is no fade at launch.
window_opacity_anim: f32 = -1.0,

/// Menu-bar clicks waiting for a safe point in the frame. Each is a `menu_model` tag.
pending_native_menu_actions: [16]usize = undefined,
pending_native_menu_actions_len: u8 = 0,

/// Same queue/flush shape as `pending_native_menu_actions`, but for the generic macOS
/// dispatch path: indices into `host.native_menu_items` (see `rebuildDynamicNativeMenus`).
pending_native_menu_item_indices: [16]usize = undefined,
pending_native_menu_item_indices_len: u8 = 0,

/// When set, next `tick` runs `warmupDrawingComposites` on the active file (after open or drawing-tool select).
pending_composite_warmup: bool = false,

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

/// Explorer/panel split ratios — "window shape" state persisted in `window.zon`, not
/// `settings.zon` (dragging a splitter fires every frame; keeping it out of the settings file
/// means normal window use never dirties a git-tracked settings.zon). Loaded once at startup
/// (see `init`); defaults match the pre-move `Settings` field defaults.
explorer_ratio: f32 = 0.35,
panel_ratio: f32 = 0.25,
/// Debounced-save bookkeeping for the ratios above, separate from `settings_dirty`/
/// `settings_save_deadline_ns` — sidebar/panel dragging must not force a settings.zon write
/// attempt on every drag frame.
window_ratios_dirty: bool = false,
window_ratios_save_deadline_ns: i128 = 0,

/// Watches `<config>/` recursively (via nightwatch — see R12) for external `settings.zon`
/// changes and newly-created plugin directories, reconciling them live via `tick`. Null on wasm,
/// on an unsupported OS, or if starting the watch failed — all best-effort: fizzy must never
/// fail to launch because the watcher couldn't start, it just silently doesn't get live
/// reconciliation. Set up in `postInit` (needs `editor` at its final heap address — see
/// `SettingsWatcher.start`'s doc comment), torn down first in `deinit`.
settings_watcher: ?SettingsWatcher = null,

/// Watches each open on-disk document for external edits. Clean docs reload via
/// `Plugin.reloadDocument`; dirty docs set a conflict flag and `save` shows
/// `FileChangedOnDisk`. Null on wasm / unsupported OS / start failure — best-effort.
document_watcher: ?DocumentWatcher = null,

/// Timestamp of the most recent touch press anywhere in the app, or null if there
/// hasn't been one. `Editor.draw` forces a per-frame refresh during the post-press
/// grace window so `dvui.ContextWidget.updateHold` actually re-runs and gets a chance
/// to open the hold-to-context menu on touch-only hardware.
last_touch_press_ns: ?i128 = null,

const embedded_fonts: []const dvui.Font.Source = &.{
    .{
        .family = dvui.Font.array("CozetteVector"),
        .bytes = cozette_ttf,
    },
    .{
        .family = dvui.Font.array("CozetteVector"),
        .bytes = cozette_bold_ttf,
        .weight = .bold,
    },

    .{
        .family = dvui.Font.array("Comfortaa"),
        .bytes = comfortaa_ttf,
    },
    .{
        .family = dvui.Font.array("Comfortaa"),
        .bytes = comfortaa_bold_ttf,
        .weight = .bold,
    },
    .{
        .family = dvui.Font.array("PlusJakartaSans"),
        .bytes = plus_jakarta_sans_ttf,
    },
    .{
        .family = dvui.Font.array("PlusJakartaSans"),
        .bytes = plus_jakarta_sans_bold_ttf,
        .weight = .bold,
    },
};

pub fn init(
    app: *App,
) !Editor {
    const arena = dvui.currentWindow().arena();
    // Wasm: skip the env-map / known-folders lookup. `std.process.Environ.put`
    // analyzes a `block.view()` call that doesn't compile on freestanding (where
    // `Block == GlobalBlock`), and the browser has no concept of OS user dirs
    // anyway. `app.root_path` ("." on wasm) is the only sensible fallback.
    const config_root: []const u8 = if (comptime builtin.target.cpu.arch == .wasm32)
        app.root_path
    else config_root_blk: {
        break :config_root_blk try fizzy.paths.configRoot(dvui.io, arena, fizzy.processEnviron(), app.root_path);
    };
    const config_folder: []const u8 = if (comptime builtin.target.cpu.arch == .wasm32)
        app.root_path
    else config_folder_blk: {
        break :config_folder_blk try fizzy.paths.configFolder(fizzy.app.allocator, dvui.io, arena, fizzy.processEnviron(), app.root_path);
    };

    // One-time migration: pre-rename builds used `Fizzy/` (capitalized).
    // On case-insensitive filesystems (Windows NTFS, macOS APFS) `fizzy/` already
    // resolves to that same directory, so the rename is a no-op and the
    // failure is ignored. On case-sensitive filesystems (most Linux) the legacy
    // dir is otherwise orphaned, so we move it across to preserve user settings.
    // Wasm: no filesystem, no migration; `Io.Dir.renameAbsolute` pulls in posix.AT.
    if (comptime builtin.target.cpu.arch != .wasm32) {
        const legacy = std.fs.path.join(arena, &.{ config_root, "Fizzy" }) catch null;
        if (legacy) |legacy_path| {
            // Only rename if the new path doesn't already have content.
            const new_exists = blk: {
                std.Io.Dir.accessAbsolute(dvui.io, config_folder, .{ .read = true }) catch break :blk false;
                break :blk true;
            };
            const legacy_exists = blk: {
                std.Io.Dir.accessAbsolute(dvui.io, legacy_path, .{ .read = true }) catch break :blk false;
                break :blk true;
            };
            if (legacy_exists and !new_exists) {
                std.Io.Dir.renameAbsolute(legacy_path, config_folder, dvui.io) catch |err| {
                    std.log.warn("legacy config folder migration ({s} -> {s}) failed: {s}", .{ legacy_path, config_folder, @errorName(err) });
                };
            }
        }
    }
    const palette_folder = std.fs.path.join(fizzy.app.allocator, &.{ config_folder, "palettes" }) catch config_folder;

    var editor: Editor = .{
        .config_folder = config_folder,
        .palette_folder = palette_folder,
        .explorer = try app.allocator.create(Explorer),
        .panel = try app.allocator.create(Panel),
        .sidebar = try .init(),
        .infobar = try .init(),
        .arena = .init(std.heap.page_allocator),
        .last_titlebar_color = dvui.themeGet().color(.control, .fill),
        .themes = .empty,
        .host = .init(app.allocator),
        .workbench = .init(app.allocator),
    };

    try editor.workbench.registerBuiltins();

    // Each plugin persists its own `<plugins_dir>/<id>.settings.zon` (see `Host.
    // loadPluginSettings`/`flushPluginSettings`) rather than a blob embedded in settings.zon.
    // Set before `Settings.load` (which may one-shot migrate a legacy settings.json's plugin
    // blobs out to these files) and before any plugin registers and reads its own settings.
    const plugins_dir: ?[]const u8 = if (comptime builtin.target.cpu.arch == .wasm32)
        null
    else
        try std.fs.path.join(app.allocator, &.{ editor.config_folder, "plugins" });
    editor.host.plugins_dir = plugins_dir;

    {
        const settings_path = try std.fs.path.join(app.allocator, &.{ editor.config_folder, "settings.zon" });
        editor.settings = try Settings.load(app.allocator, settings_path, plugins_dir);
    }

    if (comptime builtin.target.cpu.arch != .wasm32) {
        const ratios = fizzy.backend.loadWindowRatios(editor.config_folder);
        editor.explorer_ratio = ratios.explorer_ratio;
        editor.panel_ratio = ratios.panel_ratio;
    }

    // Save-queue worker is owned by the pixel-art plugin (`initPlugin` in `postInit`).

    { // Setup themes
        var fizzy_dark = dvui.themeGet();
        fizzy_dark.embedded_fonts = embedded_fonts;

        fizzy_dark.window = .{
            .fill = .{ .r = 28, .g = 29, .b = 36, .a = 255 },
            .border = .{ .r = 34, .g = 35, .b = 42, .a = 255 },
            .text = .{ .r = 206, .g = 163, .b = 127, .a = 255 },
        };

        fizzy_dark.control = .{
            .fill = .{ .r = 28, .g = 29, .b = 36, .a = 255 },
            .border = .{ .r = 34, .g = 35, .b = 42, .a = 255 },
            .text = .{ .r = 134, .g = 138, .b = 148, .a = 255 },
        };

        fizzy_dark.highlight = .{
            .fill = .{ .r = 47, .g = 179, .b = 135, .a = 255 },
            .border = .{ .r = 47, .g = 179, .b = 135, .a = 255 },
            .text = fizzy_dark.window.fill,
        };

        fizzy_dark.err = .{
            .fill = .{ .r = 109, .g = 35, .b = 54, .a = 255 },
        };

        // theme.content
        fizzy_dark.fill = .{ .r = 42, .g = 44, .b = 54, .a = 255 };
        fizzy_dark.text = fizzy_dark.window.text.?;
        fizzy_dark.focus = fizzy_dark.highlight.fill.?;

        fizzy_dark.dark = true;
        fizzy_dark.name = "Fizzy Dark";
        fizzy_dark.font_body = .find(.{ .family = "Comfortaa", .size = editor.settings.font_body_size });
        fizzy_dark.font_title = .find(.{ .family = "Comfortaa", .size = editor.settings.font_title_size, .weight = .bold });
        fizzy_dark.font_heading = .find(.{ .family = "PlusJakartaSans", .size = editor.settings.font_heading_size, .weight = .bold });
        fizzy_dark.font_mono = .find(.{ .family = "CozetteVector", .size = editor.settings.font_mono_size });

        var moi: dvui.Theme = fizzy_dark;
        moi.name = "Moi";
        moi.window = .{
            .fill = .{ .r = 84, .g = 12, .b = 26, .a = 255 },
            .border = .{ .r = 104, .g = 62, .b = 72, .a = 255 },
            .text = .{ .r = 255, .g = 190, .b = 190, .a = 240 },
        };

        moi.control = .{
            .fill = moi.window.fill.?.lighten(10),
            .border = .{ .r = 104, .g = 62, .b = 72, .a = 255 },
            .text = .{ .r = 255, .g = 235, .b = 235, .a = 200 },
        };
        moi.highlight = .{
            .fill = moi.window.fill.?.lighten(10),
        };

        moi.fill = moi.control.fill.?;
        moi.text = moi.window.text.?;
        moi.focus = moi.highlight.fill.?;

        var fizzy_light = fizzy_dark;
        fizzy_light.dark = false;
        fizzy_light.name = "Fizzy Light";

        fizzy_light.window = .{
            .fill = .{ .r = 240, .g = 240, .b = 245, .a = 255 },
            .border = dvui.Theme.builtin.adwaita_light.window.border,
            .text = .{ .r = 120, .g = 70, .b = 65, .a = 255 },
        };

        fizzy_light.control = dvui.Theme.builtin.adwaita_light.control;

        fizzy_light.highlight = .{
            .fill = .{ .r = 170, .g = 130, .b = 140, .a = 255 },
            .text = fizzy_light.window.fill,
        };

        fizzy_light.err = .{
            .fill = .{ .r = 109, .g = 35, .b = 54, .a = 255 },
        };

        // theme.content
        fizzy_light.fill = .{ .r = 200, .g = 200, .b = 205, .a = 255 };
        fizzy_light.text = .{ .r = 40, .g = 40, .b = 45, .a = 255 };
        fizzy_light.focus = fizzy_light.highlight.fill.?;

        // User-themes scan reads a directory off disk (Io.Dir.cwd → posix.AT / NAME_MAX),
        // unavailable on wasm32-freestanding. No persistent FS in browser anyway.
        if (comptime builtin.target.cpu.arch != .wasm32) {
            appendUserThemes(app.allocator, &editor) catch |err| {
                dvui.log.err("Failed to prepare user themes folder: {s}", .{@errorName(err)});
            };
        }

        editor.themes.append(app.allocator, fizzy_dark) catch {
            dvui.log.err("Failed to append theme", .{});
            return error.FailedToAppendTheme;
        };

        editor.themes.append(app.allocator, moi) catch {
            dvui.log.err("Failed to append moi theme", .{});
            return error.FailedToAppendMoiTheme;
        };

        editor.themes.append(app.allocator, fizzy_light) catch {
            dvui.log.err("Failed to append fizzy light theme", .{});
            return error.FailedToAppendFizzyLightTheme;
        };

        for (dvui.Theme.builtins) |b| {
            editor.themes.append(app.allocator, b) catch {
                dvui.log.err("Failed to append builtin theme", .{});
                return error.FailedToAppendBuiltinTheme;
            };
        }

        try editor.applySettingsTheme();
        editor.applyHoldMenuDuration();
    }

    // Config + palette folder creation and recents-from-disk load are no-ops on
    // wasm: `Io.Dir.accessAbsolute` / `createDirAbsolute` / `Recents.load` all
    // walk `Io.Dir.cwd()` (posix.AT), unavailable on wasm32-freestanding.
    if (comptime builtin.target.cpu.arch != .wasm32) {
        var valid_path: bool = true;
        if (std.fs.path.isAbsolute(editor.config_folder)) {
            std.Io.Dir.accessAbsolute(dvui.io, editor.config_folder, .{ .read = true }) catch {
                valid_path = false;
            };

            if (!valid_path) {
                std.Io.Dir.createDirAbsolute(dvui.io, editor.config_folder, .default_dir) catch |err| dvui.log.err("Failed to create config folder: {s}: {any}", .{ editor.config_folder, err });
            }
        }

        valid_path = true;
        if (std.fs.path.isAbsolute(editor.palette_folder)) {
            std.Io.Dir.accessAbsolute(dvui.io, editor.palette_folder, .{ .read = true }) catch {
                valid_path = false;
            };

            if (!valid_path) {
                std.Io.Dir.createDirAbsolute(dvui.io, editor.palette_folder, .default_dir) catch |err| dvui.log.err("Failed to create palette folder: {s}: {any}", .{ editor.palette_folder, err });
            }
        }
    }

    fizzy.perf.console_logging_enabled = Constants.perf_logging;
    editor.recents = if (comptime builtin.target.cpu.arch == .wasm32)
        .{ .folders = .init(app.allocator) }
    else
        Recents.load(app.allocator, try std.fs.path.join(app.allocator, &.{ editor.config_folder, "recents.zon" })) catch .{
            .folders = .init(app.allocator),
        };

    fizzy.backend.setTitlebarColor(dvui.currentWindow(), dvui.themeGet().color(.content, .fill).opacity(if (dvui.themeGet().dark) editor.settings.window_opacity_dark else editor.settings.window_opacity_light));

    editor.explorer.* = .init();
    editor.panel.* = .init();
    editor.open_files = .empty;
    try editor.workbench.initDefaultWorkspace();

    // Capture dvui's defaults before the shell's own binds land, so `rebuildKeybinds` can
    // restore them after clearing the map.
    editor.dvui_default_keybinds = try dvui.currentWindow().keybinds.clone(fizzy.app.allocator);

    try Keybinds.register();

    // Collect the initial settings.zon text for autosave dedup — must match exactly what
    // `writeMergedSettings` would produce with no pending plugin writes (same composer, empty
    // overlay), otherwise the very first autosave after startup would spuriously rewrite the
    // file just because this seed only accounted for the shell's own fields, not `.plugins`.
    if (comptime builtin.target.cpu.arch == .wasm32) {
        const serialized = try Settings.serialize(&editor.settings, fizzy.app.allocator);
        defer fizzy.app.allocator.free(serialized);
        editor.settings_last_saved_hash = std.hash.Wyhash.hash(0, serialized);
    } else {
        const settings_path = try std.fs.path.join(fizzy.app.allocator, &.{ editor.config_folder, "settings.zon" });
        defer fizzy.app.allocator.free(settings_path);
        const composed = try editor.composeSettingsText(fizzy.app.allocator, settings_path, &.{});
        defer fizzy.app.allocator.free(composed);
        editor.settings_last_saved_hash = std.hash.Wyhash.hash(0, composed);
    }

    return editor;
}

/// Second-stage init that needs the editor at its FINAL heap address. `init`
/// builds an `Editor` by value and the caller copies it to the heap, so anything
/// that captures `&editor.*` (e.g. a service whose `ctx` is the editor pointer)
/// must run here — not in `init`, where it would point at the stack temporary.
/// Called from `App.AppInit` right after the heap copy. (The built-in branch
/// decorators registered in `init` are exempt: they store fn pointers, not `&editor`.)
/// Stable shell-builtin contribution id.
pub const view_settings = "shell.settings";

fn loadWorkbenchFromDylibEnabled() bool {
    if (comptime builtin.target.cpu.arch == .wasm32) return false;
    if (comptime build_opts.static_workbench) return false;
    if (std.process.Environ.getAlloc(fizzy.processEnviron(), fizzy.app.allocator, "FIZZY_STATIC_WORKBENCH")) |v| {
        defer fizzy.app.allocator.free(v);
        return v.len == 0 or v[0] == '0';
    } else |_| {}
    return true;
}

fn loadTextFromDylibEnabled() bool {
    if (comptime builtin.target.cpu.arch == .wasm32) return false;
    if (comptime build_opts.static_text) return false;
    if (std.process.Environ.getAlloc(fizzy.processEnviron(), fizzy.app.allocator, "FIZZY_STATIC_TEXT")) |v| {
        defer fizzy.app.allocator.free(v);
        return v.len == 0 or v[0] == '0';
    } else |_| {}
    return true;
}

fn loadMarkdownFromDylibEnabled() bool {
    if (comptime builtin.target.cpu.arch == .wasm32) return false;
    if (std.process.Environ.getAlloc(fizzy.processEnviron(), fizzy.app.allocator, "FIZZY_STATIC_MARKDOWN")) |v| {
        defer fizzy.app.allocator.free(v);
        return v.len == 0 or v[0] == '0';
    } else |_| {}
    return true;
}

fn loadImageFromDylibEnabled() bool {
    if (comptime builtin.target.cpu.arch == .wasm32) return false;
    if (comptime build_opts.static_image) return false;
    if (std.process.Environ.getAlloc(fizzy.processEnviron(), fizzy.app.allocator, "FIZZY_STATIC_IMAGE")) |v| {
        defer fizzy.app.allocator.free(v);
        return v.len == 0 or v[0] == '0';
    } else |_| {}
    return true;
}

/// Stable workbench sidebar view id (matches `workbench.view_files`).
pub const workbench_files_view = workbench_mod.view_files;

/// Registered workbench plugin (dylib or static). Panics if missing after `postInit`.
pub fn workbenchPlugin(editor: *Editor) *sdk.Plugin {
    return editor.host.pluginById("workbench") orelse @panic("workbench plugin not registered");
}

/// Registered text plugin (dylib or static). Panics if missing after `postInit`.
pub fn textPlugin(editor: *Editor) *sdk.Plugin {
    return editor.host.pluginById("text") orelse @panic("text plugin not registered");
}

/// Push host dvui state into every loaded plugin dylib image.
pub fn syncLoadedPluginDvuiContexts(editor: *Editor) void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    for (editor.loaded_plugin_libs.items) |loaded| {
        sdk.dvui_context.syncHostIntoPlugin(loaded.set_dvui_context);
    }
}

/// Inject the host render bridge into every loaded plugin dylib (proxy backend).
pub fn syncLoadedPluginRenderBridge(editor: *Editor) void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    for (editor.loaded_plugin_libs.items) |loaded| {
        sdk.render_bridge.syncHostIntoPlugin(loaded.set_render_bridge);
    }
}

fn syncLoadedPluginGlobals(editor: *Editor, plugin_id: []const u8, arg_b: *anyopaque, arg_c: ?*anyopaque) void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    for (editor.loaded_plugin_libs.items) |loaded| {
        if (!std.mem.eql(u8, loaded.plugin_id, plugin_id)) continue;
        loaded.set_globals(@ptrCast(&fizzy.app.allocator), arg_b, arg_c);
    }
}

/// Re-inject host-owned Globals into a loaded workbench dylib.
pub fn syncLoadedWorkbenchGlobals(editor: *Editor) void {
    syncLoadedPluginGlobals(editor, "workbench", @ptrCast(&editor.host), @ptrCast(&editor.workbench));
}

fn appendLoadedPluginLib(editor: *Editor, loaded: PluginLoader.LoadedLib) !void {
    const id_owned = try fizzy.app.allocator.dupe(u8, loaded.plugin_id);
    var stored = loaded;
    stored.plugin_id = id_owned;
    try editor.loaded_plugin_libs.append(fizzy.app.allocator, stored);
}

/// Load `{exe_dir}/plugins/workbench.{ext}` and register via dylib entry.
pub fn loadWorkbenchDylib(editor: *Editor, exe_dir: []const u8) !void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    const path = try PluginLoader.builtinPluginPath(fizzy.app.allocator, exe_dir, "workbench");
    errdefer fizzy.app.allocator.free(path);
    const loaded = try PluginLoader.loadAndRegister(&editor.host, fizzy.app.allocator, path, "workbench", .{
        .gpa = &fizzy.app.allocator,
        .arg_b = @ptrCast(&editor.host), // workbench convention: arg_b = *Host
        .arg_c = @ptrCast(&editor.workbench), // arg_c = *Workbench
    });
    try appendLoadedPluginLib(editor, loaded);
    syncLoadedPluginDvuiContexts(editor);
    syncLoadedPluginRenderBridge(editor);
}

/// Load `{exe_dir}/plugins/text.{ext}` and register via dylib entry.
pub fn loadTextDylib(editor: *Editor, exe_dir: []const u8) !void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    const path = try PluginLoader.builtinPluginPath(fizzy.app.allocator, exe_dir, "text");
    errdefer fizzy.app.allocator.free(path);
    const loaded = try PluginLoader.loadAndRegister(&editor.host, fizzy.app.allocator, path, "text", .{
        .gpa = &fizzy.app.allocator,
        .arg_b = @ptrCast(&editor.host),
        .arg_c = null,
    });
    try appendLoadedPluginLib(editor, loaded);
    syncLoadedPluginDvuiContexts(editor);
    syncLoadedPluginRenderBridge(editor);
}

/// Load `{exe_dir}/plugins/markdown.{ext}` and register via dylib entry.
pub fn loadMarkdownDylib(editor: *Editor, exe_dir: []const u8) !void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    const path = try PluginLoader.builtinPluginPath(fizzy.app.allocator, exe_dir, "markdown");
    errdefer fizzy.app.allocator.free(path);
    const loaded = try PluginLoader.loadAndRegister(&editor.host, fizzy.app.allocator, path, "markdown", .{
        .gpa = &fizzy.app.allocator,
        .arg_b = @ptrCast(&editor.host),
        .arg_c = null,
    });
    try appendLoadedPluginLib(editor, loaded);
    syncLoadedPluginDvuiContexts(editor);
    syncLoadedPluginRenderBridge(editor);
}

/// Load `{exe_dir}/plugins/image.{ext}` and register via dylib entry.
pub fn loadImageDylib(editor: *Editor, exe_dir: []const u8) !void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    const path = try PluginLoader.builtinPluginPath(fizzy.app.allocator, exe_dir, "image");
    errdefer fizzy.app.allocator.free(path);
    const loaded = try PluginLoader.loadAndRegister(&editor.host, fizzy.app.allocator, path, "image", .{
        .gpa = &fizzy.app.allocator,
        .arg_b = @ptrCast(&editor.host),
        .arg_c = null,
    });
    try appendLoadedPluginLib(editor, loaded);
    syncLoadedPluginDvuiContexts(editor);
    syncLoadedPluginRenderBridge(editor);
}

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
};

/// Record a failed user-plugin load so the UI can surface it. `id` and `reason` are copied
/// (the caller keeps ownership of its arguments). Best-effort: on OOM the failure is dropped
/// after being logged at the call site.
fn recordPluginFailure(editor: *Editor, id: []const u8, reason: []const u8, detail: ?[]const u8, plugin_version: ?std.SemanticVersion) void {
    const id_owned = fizzy.app.allocator.dupe(u8, id) catch return;
    const reason_owned = fizzy.app.allocator.dupe(u8, reason) catch {
        fizzy.app.allocator.free(id_owned);
        return;
    };
    const detail_owned: ?[]const u8 = if (detail) |d| fizzy.app.allocator.dupe(u8, d) catch null else null;
    if (detail_owned == null and detail != null) {
        fizzy.app.allocator.free(id_owned);
        fizzy.app.allocator.free(reason_owned);
        return;
    }
    editor.failed_user_plugins.append(fizzy.app.allocator, .{
        .id = id_owned,
        .reason = reason_owned,
        .detail = detail_owned,
        .plugin_version = plugin_version,
    }) catch {
        fizzy.app.allocator.free(id_owned);
        fizzy.app.allocator.free(reason_owned);
        if (detail_owned) |d| fizzy.app.allocator.free(d);
    };
}

/// True if `id` is a user plugin present on disk that failed to load (ABI/SDK mismatch, etc.).
/// Lets the store offer replace/uninstall actions for a broken build instead of a dead end.
pub fn isFailedUserPlugin(editor: *Editor, id: []const u8) bool {
    for (editor.failed_user_plugins.items) |f| {
        if (std.mem.eql(u8, f.id, id)) return true;
    }
    return false;
}

/// Drop any recorded load-failure for `id` (freeing its strings). Called when the plugin later
/// loads successfully or is uninstalled, so a stale failure no longer lingers in the UI / dialog.
fn clearFailedUserPlugin(editor: *Editor, id: []const u8) void {
    var i: usize = 0;
    while (i < editor.failed_user_plugins.items.len) {
        if (std.mem.eql(u8, editor.failed_user_plugins.items[i].id, id)) {
            const f = editor.failed_user_plugins.orderedRemove(i);
            fizzy.app.allocator.free(f.id);
            fizzy.app.allocator.free(f.reason);
            if (f.detail) |d| fizzy.app.allocator.free(d);
        } else i += 1;
    }
}

fn formatPluginProbeDetail(allocator: std.mem.Allocator, info: PluginLoader.PluginVersionInfo) ![]const u8 {
    return std.fmt.allocPrint(allocator, "plugin {d}.{d}.{d}, min SDK {d}.{d}.{d}", .{
        info.plugin_version.major,
        info.plugin_version.minor,
        info.plugin_version.patch,
        info.min_sdk_version.major,
        info.min_sdk_version.minor,
        info.min_sdk_version.patch,
    });
}

/// Human-readable, actionable explanation for a `PluginLoader.LoadError`.
fn pluginLoadFailureReason(err: PluginLoader.LoadError) []const u8 {
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

/// One-shot: moves any pre-R10 flat `{plugins_dir}/{id}.{ext}` into its own
/// `{plugins_dir}/{id}/{id}.{ext}` directory (see docs/PLUGIN_MANIFEST_PLAN.md R10). Collects the
/// list of flat files first, then renames in a second pass, so mutating the directory never races
/// the iterator that's still walking it. Best-effort: a single failed rename is logged and
/// skipped rather than aborting the rest.
fn migrateFlatPluginLayout(allocator: std.mem.Allocator, plugins_dir: []const u8, ext_suffix: []const u8) void {
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

pub fn loadUserPlugins(editor: *Editor, config_folder: []const u8) void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;

    const plugins_dir = std.fs.path.join(fizzy.app.allocator, &.{ config_folder, "plugins" }) catch return;
    defer fizzy.app.allocator.free(plugins_dir);

    const ext_suffix: []const u8 = switch (builtin.os.tag) {
        .windows => ".dll",
        .macos => ".dylib",
        else => ".so",
    };

    migrateFlatPluginLayout(fizzy.app.allocator, plugins_dir, ext_suffix);

    // Leftover fresh-load temp copies from a previous run (see `PluginLoader.copyToFreshLoadPath`)
    // — safe to clear unconditionally here since nothing is loaded from this directory yet.
    PluginLoader.sweepLoadTempDir(fizzy.app.allocator, plugins_dir);

    var dir = std.Io.Dir.cwd().openDir(dvui.io, plugins_dir, .{ .iterate = true }) catch return;
    defer dir.close(dvui.io);

    var loaded_any = false;
    var loaded_count: usize = 0;
    // Startup cost attributable to user plugins. `PluginLoader` logs any individual load over
    // its slow threshold; this is the number to watch when "fizzy got slower to launch".
    const scan_start = std.Io.Clock.boot.now(dvui.io).nanoseconds;

    var iter = dir.iterate();
    while (iter.next(dvui.io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const plugin_id = entry.name;
        // Skip `.load-tmp` and any other dotfile/directory — not a plugin id.
        if (plugin_id.len == 0 or plugin_id[0] == '.') continue;

        // User-disabled plugins (store "disable") stay on disk but are not loaded.
        if (editor.isPluginDisabled(plugin_id)) {
            dvui.log.info("user plugin '{s}' is disabled; skipped", .{plugin_id});
            continue;
        }

        const file_name = PluginLoader.pluginFilename(plugin_id, fizzy.app.allocator) catch continue;
        defer fizzy.app.allocator.free(file_name);
        const path = std.fs.path.join(fizzy.app.allocator, &.{ plugins_dir, plugin_id, file_name }) catch continue;

        if (editor.host.pluginById(plugin_id) != null) {
            // A shell built-in (`text`/`workbench`/`image`/`markdown`) is loaded via its own
            // static/dylib path (see `postInit` above) and may *also* have its dylib sitting in
            // this same shared plugins directory — built-ins compile "the same third-party
            // shape" a real third-party plugin would, and `zig build install` drops every
            // plugin's dylib here alike (see CLAUDE.md). Rediscovering a built-in's own binary
            // here is expected, not a failure: recording it as one would surface the same id
            // twice in the settings pane (once as the loaded built-in, once as a "failed" user
            // plugin), which collides on the shared heading widget id. Only a genuine third-party
            // id clash (some other plugin trying to claim an id a built-in already owns) is
            // worth surfacing.
            if (isBundledPluginId(plugin_id)) {
                dvui.log.info("user plugin '{s}': already loaded as a built-in; skipped", .{plugin_id});
            } else {
                dvui.log.err("user plugin '{s}': id already registered by a built-in; skipped", .{plugin_id});
                const probe = PluginLoader.probeVersionInfo(path);
                editor.recordPluginFailure(plugin_id, "id already registered by a built-in plugin", null, if (probe) |info| info.plugin_version else null);
            }
            fizzy.app.allocator.free(path);
            continue;
        }

        const load_start = std.Io.Clock.boot.now(dvui.io).nanoseconds;
        const loaded = PluginLoader.loadAndRegister(&editor.host, fizzy.app.allocator, path, plugin_id, .{
            .gpa = &fizzy.app.allocator,
            .arg_b = @ptrCast(&editor.host),
            .arg_c = null,
        }) catch |err| {
            const reason = pluginLoadFailureReason(err);
            const probe = PluginLoader.probeVersionInfo(path);
            const detail_owned: ?[]const u8 = if (probe) |info|
                formatPluginProbeDetail(fizzy.app.allocator, info) catch null
            else
                null;
            dvui.log.err("user plugin '{s}' ({s}): load failed: {s} — {s}", .{ plugin_id, path, @errorName(err), reason });
            editor.recordPluginFailure(plugin_id, reason, detail_owned, if (probe) |info| info.plugin_version else null);
            fizzy.app.allocator.free(path);
            continue;
        };

        appendLoadedPluginLib(editor, loaded) catch {
            dvui.log.err("user plugin '{s}': out of memory storing LoadedLib", .{plugin_id});
            editor.recordPluginFailure(plugin_id, "ran out of memory while loading", null, loaded.version_info.plugin_version);
            continue;
        };
        dvui.log.info("user plugin '{s}' loaded from {s} in {d}ms", .{
            plugin_id,
            path,
            @divTrunc(std.Io.Clock.boot.now(dvui.io).nanoseconds - load_start, std.time.ns_per_ms),
        });
        loaded_any = true;
        loaded_count += 1;
    }

    dvui.log.info("loaded {d} user plugin(s) in {d}ms", .{
        loaded_count,
        @divTrunc(std.Io.Clock.boot.now(dvui.io).nanoseconds - scan_start, std.time.ns_per_ms),
    });

    if (loaded_any) {
        syncLoadedPluginDvuiContexts(editor);
        syncLoadedPluginRenderBridge(editor);
    }
}

fn unloadPluginLibs(editor: *Editor) void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    for (editor.loaded_plugin_libs.items) |*entry| {
        // Deliberately not `entry.lib.close()`: this only runs from `Editor.deinit`, called
        // by `AppDeinit` — which the doc comment on `AppDeinit` notes runs *before*
        // `dvui.Window.deinit()`. That later call walks dvui's window-level `data_store` and
        // invokes each entry's `deinit` function pointer, which for data a plugin stored via
        // `dvui.dataSet`/`dataSetSlice` is a comptime-specialized function compiled into that
        // plugin's own dylib. Closing the dylib here first and freeing the data store second
        // means calling through a function pointer into memory the OS already unmapped —
        // caused a reliable segfault on exit whenever a plugin (e.g. widget state for an open
        // document) still had a live data-store entry. `PluginLoader.zig`'s `DynLib` doc
        // comment already says the handle "must stay open for the app's lifetime"; the process
        // exiting reclaims it for free, same tradeoff as the leaked `FileLoadJob`s below.
        fizzy.app.allocator.free(entry.plugin_id);
        fizzy.app.allocator.free(entry.path);
    }
    editor.loaded_plugin_libs.deinit(fizzy.app.allocator);

    for (editor.failed_user_plugins.items) |f| {
        fizzy.app.allocator.free(f.id);
        fizzy.app.allocator.free(f.reason);
        if (f.detail) |d| fizzy.app.allocator.free(d);
    }
    editor.failed_user_plugins.deinit(fizzy.app.allocator);

    for (editor.disabled_plugin_ids.items) |id| fizzy.app.allocator.free(id);
    editor.disabled_plugin_ids.deinit(fizzy.app.allocator);

    {
        var it = editor.plugin_enabled_pending.iterator();
        while (it.next()) |e| fizzy.app.allocator.free(e.key_ptr.*);
        editor.plugin_enabled_pending.deinit(fizzy.app.allocator);
    }

    editor.dvui_default_keybinds.deinit(fizzy.app.allocator);
}

// ---- runtime plugin lifecycle (store: install / enable / disable / update) ---------
//
// Only dylib-loaded *user* plugins are managed here. Bundled built-ins (pixi/workbench/
// code) ship in the app and are never unloaded, even though they also appear in
// `loaded_plugin_libs` when loaded from their bundled dylibs.

/// True when `id` names one of the bundled built-ins (ships in the app, must never be
/// store-managed, and may legitimately be rediscovered under its own id while scanning the
/// user plugins directory — see `loadUserPlugins`'s already-registered branch).
fn isBundledPluginId(id: []const u8) bool {
    inline for (bundled_modules) |m| {
        if (std.mem.eql(u8, m.plugin_id, id)) return true;
    }
    return false;
}

/// True when `id` names a runtime-loaded user plugin that may be unloaded/disabled.
pub fn isUnloadablePlugin(editor: *Editor, id: []const u8) bool {
    if (isBundledPluginId(id)) return false;
    for (editor.loaded_plugin_libs.items) |loaded| {
        if (std.mem.eql(u8, loaded.plugin_id, id)) return true;
    }
    return false;
}

pub fn isPluginDisabled(editor: *Editor, id: []const u8) bool {
    for (editor.disabled_plugin_ids.items) |d| {
        if (std.mem.eql(u8, d, id)) return true;
    }
    return false;
}

/// True when `id` looks like a real plugin id (ASCII identifier), not corrupted settings data.
fn isValidPluginId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    if (!std.unicode.utf8ValidateSlice(id)) return false;
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

/// Seed the runtime disabled set from on-disk plugin directories whose `.plugins.<id>.enabled`
/// is not `true` (absent entry / omitted field / explicit false all mean disabled — R12).
/// Call once after settings load, before `loadUserPlugins`.
fn seedDisabledPlugins(editor: *Editor) void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    const gpa = fizzy.app.allocator;
    const plugins_dir = std.fs.path.join(gpa, &.{ editor.config_folder, "plugins" }) catch return;
    defer gpa.free(plugins_dir);

    const settings_path = std.fs.path.join(gpa, &.{ editor.config_folder, "settings.zon" }) catch return;
    defer gpa.free(settings_path);
    const data = fizzy.fs.readZ(gpa, dvui.io, settings_path) catch null;
    defer if (data) |d| gpa.free(d);

    var dir = std.Io.Dir.cwd().openDir(dvui.io, plugins_dir, .{ .iterate = true }) catch return;
    defer dir.close(dvui.io);
    var iter = dir.iterate();
    while (iter.next(dvui.io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const id = entry.name;
        if (id.len == 0 or id[0] == '.') continue;
        if (!isValidPluginId(id)) continue;
        if (isBundledPluginId(id)) continue;
        if (readPluginEnabled(gpa, data, id)) continue;
        editor.trackDisabledPlugin(id) catch {};
    }
}

/// Add `id` to the runtime disabled bookkeeping list if not already present. Does **not**
/// write settings — a freshly dropped-in plugin stays off-disk-silent until the user enables it.
fn trackDisabledPlugin(editor: *Editor, id: []const u8) !void {
    if (editor.isPluginDisabled(id)) return;
    if (!isValidPluginId(id)) return error.InvalidPluginId;
    const dup = try fizzy.app.allocator.dupe(u8, id);
    errdefer fizzy.app.allocator.free(dup);
    try editor.disabled_plugin_ids.append(fizzy.app.allocator, dup);
}

fn untrackDisabledPlugin(editor: *Editor, id: []const u8) void {
    for (editor.disabled_plugin_ids.items, 0..) |d, i| {
        if (std.mem.eql(u8, d, id)) {
            const owned = editor.disabled_plugin_ids.orderedRemove(i);
            fizzy.app.allocator.free(owned);
            return;
        }
    }
}

/// Reads `.plugins.<id>.enabled` from already-loaded `settings_data` (null source → false).
/// Missing `.plugins` / missing id / missing or non-`true` `.enabled` all mean disabled.
fn readPluginEnabled(gpa: std.mem.Allocator, settings_data: ?[:0]const u8, id: []const u8) bool {
    const data = settings_data orelse return false;
    const plugins = SettingsPluginsZon.extractField(gpa, data, "plugins") orelse return false;
    defer gpa.free(plugins);
    const plugins_z = gpa.dupeZ(u8, plugins) catch return false;
    defer gpa.free(plugins_z);
    const id_block = SettingsPluginsZon.extractField(gpa, plugins_z, id) orelse return false;
    defer gpa.free(id_block);
    const id_z = gpa.dupeZ(u8, id_block) catch return false;
    defer gpa.free(id_z);
    const enabled_text = SettingsPluginsZon.extractField(gpa, id_z, "enabled") orelse return false;
    defer gpa.free(enabled_text);
    const trimmed = std.mem.trim(u8, enabled_text, " \t\r\n");
    return std.mem.eql(u8, trimmed, "true");
}

/// Reads `.plugins.<id>.settings` from already-loaded `settings_data`. Null if absent.
fn readPluginSettingsText(gpa: std.mem.Allocator, settings_data: ?[:0]const u8, id: []const u8) ?[]u8 {
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

/// Buffer a per-plugin `.enabled` write and flush `settings.zon` **immediately**.
/// Enable/disable is a discrete, infrequent, important action, so it is flushed synchronously
/// rather than through the debounced autosave (same reasoning the old `setDisabledPersisted`
/// had: losing an explicit toggle to a skipped autosave window is worse than one extra write).
fn setPluginEnabledPersisted(editor: *Editor, id: []const u8, enabled: bool) !void {
    if (!enabled and !isValidPluginId(id)) return error.InvalidPluginId;
    const gpa = fizzy.app.allocator;
    if (editor.plugin_enabled_pending.getPtr(id)) |slot| {
        slot.* = enabled;
    } else {
        const key = try gpa.dupe(u8, id);
        errdefer gpa.free(key);
        try editor.plugin_enabled_pending.put(gpa, key, enabled);
    }
    if (comptime builtin.target.cpu.arch == .wasm32) {
        editor.host.markSettingsDirty();
    } else {
        editor.saveSettingsRaw() catch |err| {
            dvui.log.err("Failed to persist plugin enabled state immediately ({s}); deferring to autosave", .{@errorName(err)});
            editor.host.markSettingsDirty();
        };
    }
}

/// Rebuild the whole window keybind map from scratch: shell binds + every *currently
/// registered* plugin's `contributeKeybinds`. Used after a plugin is unregistered so its
/// binds (whose key strings live in the soon-to-be-`dlclose`d image) are dropped. Also
/// called after the Keyboard Shortcuts pane writes `keybinds.zon`.
pub fn rebuildKeybinds(editor: *Editor) void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    const window = dvui.currentWindow();
    window.keybinds.clearRetainingCapacity();
    var defaults = editor.dvui_default_keybinds.iterator();
    while (defaults.next()) |kv| {
        window.keybinds.put(window.gpa, kv.key_ptr.*, kv.value_ptr.*) catch |err|
            dvui.log.err("keybind rebuild (dvui default '{s}') failed: {s}", .{ kv.key_ptr.*, @errorName(err) });
    }
    Keybinds.register() catch |err| dvui.log.err("keybind rebuild (shell) failed: {s}", .{@errorName(err)});
    for (editor.host.plugins.items) |plugin| {
        plugin.contributeKeybinds(window) catch |err|
            dvui.log.err("keybind rebuild ('{s}') failed: {s}", .{ plugin.id, @errorName(err) });
    }
    // Lift the finished bind map into the command keymap that `Keybinds.tick` dispatches from.
    Keybinds.buildKeymap(editor) catch |err|
        dvui.log.err("keymap rebuild failed: {s}", .{@errorName(err)});
}

/// True if `plugin` owns any currently-dirty open document.
fn pluginHasDirtyDocs(editor: *Editor, plugin: *sdk.Plugin) bool {
    for (editor.open_files.values()) |doc| {
        if (doc.owner == plugin and doc.owner.isDirty(doc)) return true;
    }
    return false;
}

pub const UnloadError = error{ NotUnloadable, DirtyDocuments };

/// Load `{config}/plugins/{id}/{id}.{ext}` live and register it. Reuses the same loader +
/// dvui/render-bridge sync path as `loadUserPlugins`. Caller ensures `id` is not already
/// registered. On success the lib is appended to `loaded_plugin_libs`.
pub fn loadUserPluginById(editor: *Editor, id: []const u8) !void {
    if (comptime builtin.target.cpu.arch == .wasm32) return error.NotUnloadable;
    const file_name = try PluginLoader.pluginFilename(id, fizzy.app.allocator);
    defer fizzy.app.allocator.free(file_name);
    const path = try std.fs.path.join(fizzy.app.allocator, &.{ editor.config_folder, "plugins", id, file_name });
    errdefer fizzy.app.allocator.free(path);

    const loaded = try PluginLoader.loadAndRegister(&editor.host, fizzy.app.allocator, path, id, .{
        .gpa = &fizzy.app.allocator,
        .arg_b = @ptrCast(&editor.host),
        .arg_c = null,
    });
    try editor.appendLoadedPluginLib(loaded);
    syncLoadedPluginDvuiContexts(editor);
    syncLoadedPluginRenderBridge(editor);
    rebuildKeybinds(editor);
    fizzy.backend.rebuildDynamicNativeMenus();
    // The plugin now loads cleanly; drop any prior failure record so the store/dialog stop
    // showing it as broken (e.g. after installing a compatible rebuild over a mismatched one).
    editor.clearFailedUserPlugin(id);
}

/// Install (file already downloaded to the plugins dir by the store backend) + load live.
/// Writes `.plugins.<id>.enabled = true` immediately so the plugin stays enabled across restarts
/// (store installs auto-load; a manually dropped-in dylib does not — see R12).
pub fn installAndLoadPlugin(editor: *Editor, id: []const u8) !void {
    if (isBundledPluginId(id)) return error.NotUnloadable;
    if (editor.host.pluginById(id) != null) return; // already loaded
    editor.untrackDisabledPlugin(id);
    try editor.setPluginEnabledPersisted(id, true);
    try editor.loadUserPluginById(id);
}

/// True if `plugin` owns any document with an async save still in flight.
fn pluginHasSavingDocs(editor: *Editor, plugin: *sdk.Plugin) bool {
    for (editor.open_files.values()) |doc| {
        if (doc.owner == plugin and doc.owner.isDocumentSaving(doc)) return true;
    }
    return false;
}

/// Spin until none of `plugin`'s open documents report `isDocumentSaving`. Called from
/// `unloadPlugin` on the GUI thread while the save-queue worker runs concurrently.
fn waitForPluginSaves(editor: *Editor, plugin: *sdk.Plugin) void {
    while (pluginHasSavingDocs(editor, plugin)) {
        std.Thread.yield() catch {};
    }
}

/// Cancel and await every in-flight `FileLoadJob` owned by `plugin`, then drop its staging
/// buffer — so `unloadPlugin` can never `dlclose` the image while a worker thread is still
/// inside `owner.loadDocument` / `deinitDocumentBuffer` (use-after-free). Owner-scoped so a
/// load belonging to an unrelated plugin survives. Mirrors `waitForPluginSaves`; runs on the
/// GUI thread before any teardown.
fn cancelPluginLoadingJobs(editor: *Editor, plugin: *sdk.Plugin) void {
    if (editor.loading_jobs.count() == 0) return;
    const io = dvui.io;

    // Signal cancellation first so a worker that has not yet entered (or has just exited) the
    // loader bails at its next checkpoint instead of re-entering the soon-unmapped image.
    {
        var it = editor.loading_jobs.valueIterator();
        while (it.next()) |job_ptr| {
            if (job_ptr.*.owner == plugin) job_ptr.*.cancelled.store(true, .monotonic);
        }
    }

    // Collect this plugin's jobs up front — cleanup mutates `loading_jobs`, so we can't hold
    // the map iterator across removal.
    var owned: std.ArrayListUnmanaged(*FileLoadJob) = .empty;
    defer owned.deinit(fizzy.app.allocator);
    {
        var it = editor.loading_jobs.valueIterator();
        while (it.next()) |job_ptr| {
            if (job_ptr.*.owner == plugin) owned.append(fizzy.app.allocator, job_ptr.*) catch {};
        }
    }

    for (owned.items) |job| {
        // Block until the worker has fully left the dylib before we free through the owner —
        // a futex wait on the job's `Future` (see `Editor.openFilePath`), not the
        // `std.Thread.yield()` busy-spin this replaced.
        if (job.future) |*f| f.await(io);
        _ = editor.loading_jobs.remove(job.path);
        // Drop the partial open without inserting it into `open_files`. `ready`/`failed`
        // need exactly one `deinitDocumentBuffer`; a `cancelled` job was either freed by the
        // worker (late cancel) or never constructed (early cancel), so skip it to avoid a
        // double-free / deinit-on-uninitialized buffer.
        switch (job.currentPhase()) {
            .ready, .failed => job.owner.deinitDocumentBuffer(job.doc_buf.ptr),
            else => {},
        }
        job.destroy(io);
    }
}

/// Unload a runtime user plugin live: close its documents, tear down its contributions,
/// deinit its state, then `dlclose`. With `force == false`, aborts with `DirtyDocuments`
/// if any owned document is dirty (the caller decides whether to prompt/save first).
pub fn unloadPlugin(editor: *Editor, id: []const u8, force: bool) UnloadError!void {
    if (comptime builtin.target.cpu.arch == .wasm32) return error.NotUnloadable;
    if (!editor.isUnloadablePlugin(id)) return error.NotUnloadable;
    const plugin = editor.host.pluginById(id) orelse return error.NotUnloadable;

    const lib_index: usize = blk: {
        for (editor.loaded_plugin_libs.items, 0..) |loaded, i| {
            if (std.mem.eql(u8, loaded.plugin_id, id)) break :blk i;
        }
        return error.NotUnloadable;
    };

    if (!force and editor.pluginHasDirtyDocs(plugin)) return error.DirtyDocuments;

    // Let in-flight async saves finish while the owning `File` records still exist.
    editor.waitForPluginSaves(plugin);

    // Cancel + await any in-flight file loads owned by this plugin so no worker calls into
    // the dylib after we `dlclose` it below.
    editor.cancelPluginLoadingJobs(plugin);

    // Close every document this plugin owns. Collect ids first — closing mutates
    // `open_files` underneath us.
    var owned: std.ArrayListUnmanaged(u64) = .empty;
    defer owned.deinit(fizzy.app.allocator);
    for (editor.open_files.values()) |doc| {
        if (doc.owner == plugin) owned.append(fizzy.app.allocator, doc.id) catch {};
    }
    for (owned.items) |doc_id| editor.rawCloseFileID(doc_id) catch |err|
        dvui.log.err("unloadPlugin '{s}': closing doc {d} failed: {s}", .{ id, doc_id, @errorName(err) });

    // Drop empty workspace panes (and plugin canvas chrome) before plugin `deinit`.
    editor.rebuildWorkspaces() catch |err|
        dvui.log.err("unloadPlugin '{s}': rebuildWorkspaces failed: {s}", .{ id, @errorName(err) });

    // Remove all contributions + services + active-id references (before dlclose), then
    // run the plugin's own teardown.
    editor.host.unregisterPlugin(plugin);
    fizzy.backend.rebuildDynamicNativeMenus();
    plugin.deinit();

    // Drop the unloaded plugin's keybinds by rebuilding from the survivors.
    rebuildKeybinds(editor);

    // Unmap the image and free our bookkeeping for it.
    var loaded = editor.loaded_plugin_libs.orderedRemove(lib_index);
    loaded.lib.close();
    fizzy.app.allocator.free(loaded.plugin_id);
    fizzy.app.allocator.free(loaded.path);
}

/// Enable or disable a plugin, persisting the choice and applying it live: disabling
/// unloads now; enabling loads the installed dylib now.
pub fn setPluginEnabled(editor: *Editor, id: []const u8, enabled: bool, force: bool) !void {
    if (isBundledPluginId(id)) return error.NotUnloadable;

    if (enabled) {
        editor.untrackDisabledPlugin(id);
        try editor.setPluginEnabledPersisted(id, true);
        if (editor.host.pluginById(id) == null) try editor.loadUserPluginById(id);
    } else {
        // Persist before unload: `id` may point at static memory inside the plugin image.
        try editor.trackDisabledPlugin(id);
        try editor.setPluginEnabledPersisted(id, false);
        if (editor.host.pluginById(id) != null) try editor.unloadPlugin(id, force);
    }
}

/// Replace an installed plugin with a freshly downloaded build (in the plugins dir already)
/// by unloading then reloading. `force` controls dirty-document handling on the unload.
pub fn updatePlugin(editor: *Editor, id: []const u8, force: bool) !void {
    if (isBundledPluginId(id)) return error.NotUnloadable;
    try editor.unloadPlugin(id, force);
    try editor.loadUserPluginById(id);
}

/// Fully remove a user plugin: unload it if loaded, clear any disabled flag, and delete its
/// whole `{config}/plugins/{id}/` directory — not just the dylib, since that directory is also
/// where the plugin may have stored its own assets/data (see `Host.pluginInstallDir`). Note that
/// the plugin's own *settings* (`.plugins.<id>` in `settings.zon`) deliberately survive this, same
/// as before R10 — see `docs/PLUGINS.md`'s "only the dylib/directory is deleted on uninstall"
/// note, so reinstalling later restores the old configuration. `force` controls dirty-document
/// handling on the unload.
pub fn uninstallPlugin(editor: *Editor, id: []const u8, force: bool) !void {
    if (comptime builtin.target.cpu.arch == .wasm32) return error.NotUnloadable;
    if (isBundledPluginId(id)) return error.NotUnloadable;
    if (editor.host.pluginById(id) != null) try editor.unloadPlugin(id, force);
    // Drop runtime disabled bookkeeping — the plugin no longer exists to be disabled. Its
    // `.plugins.<id>` settings block deliberately survives (reinstall restores config); a
    // later store install writes `.enabled = true` fresh.
    editor.untrackDisabledPlugin(id);

    const plugin_dir = try std.fs.path.join(fizzy.app.allocator, &.{ editor.config_folder, "plugins", id });
    defer fizzy.app.allocator.free(plugin_dir);
    std.Io.Dir.cwd().deleteTree(dvui.io, plugin_dir) catch |err|
        dvui.log.warn("uninstallPlugin '{s}': could not delete {s}: {s}", .{ id, plugin_dir, @errorName(err) });
    // A broken (failed-to-load) build can be uninstalled too; clear its failure record so the
    // card disappears instead of lingering as "Failed".
    editor.clearFailedUserPlugin(id);
}

pub fn postInit(editor: *Editor) !void {
    sdk.installRuntime(&fizzy.app.allocator, &editor.host, null);

    // Shell commands must be registered against the Editor's *final* address — `init` returns
    // an Editor by value, so a pointer taken there would dangle the moment it's moved.
    try Keybinds.registerCommands(editor);

    // Install the shell's read/utility surface so plugins reach shared shell state
    // (per-frame arena, project folder, content opacity, settings dirty-mark) through
    // the Host instead of importing the concrete Editor.
    editor.host.installShell(.{ .ctx = editor, .vtable = &shell_api_vtable });

    // Register plugin contributions (sidebar/bottom/center/menus). These are the
    // near-empty shell's content: it iterates the Host registries rather than
    // hardcoding panes. Web-safe — the draw fns reach the same inline code the
    // editor tick already runs on wasm. Order = sidebar order.
    // These 4 built-ins default to dylib-first with a static fallback, but none of them
    // are actually shipped as dylibs right now (they keep the third-party shape purely as
    // a template/example) — so the dylib load "fails" and falls back to static on every
    // run. Not worth logging until that changes.
    if (loadWorkbenchFromDylibEnabled()) {
        editor.loadWorkbenchDylib(fizzy.app.root_path) catch {
            try workbench_mod.register(&editor.host);
        };
    } else {
        try workbench_mod.register(&editor.host);
    }
    if (loadTextFromDylibEnabled()) {
        editor.loadTextDylib(fizzy.app.root_path) catch {
            try text_mod.register(&editor.host);
        };
    } else {
        try text_mod.register(&editor.host);
    }
    if (loadImageFromDylibEnabled()) {
        editor.loadImageDylib(fizzy.app.root_path) catch {
            try image_mod.register(&editor.host);
        };
    } else {
        try image_mod.register(&editor.host);
    }
    if (comptime builtin.target.cpu.arch != .wasm32) {
        if (loadMarkdownFromDylibEnabled()) {
            editor.loadMarkdownDylib(fizzy.app.root_path) catch {
                try markdown_mod.register(&editor.host);
            };
        } else {
            try markdown_mod.register(&editor.host);
        }
    }

    // Seed the runtime disabled set from settings (and re-point the persisted slice at
    // it) before scanning, so disabled plugins are skipped at startup.
    editor.seedDisabledPlugins();

    // User-installed plugins from `<config>/plugins/{id}.{dylib,so,dll}`.
    editor.loadUserPlugins(editor.config_folder);

    for (editor.host.plugins.items) |p| try p.initPlugin();

    // Shell built-in: Plugin store (owner = null; not a plugin). Registered just before
    // Settings so its icon sits directly above the cog in the sidebar rail.
    try PluginStore.register(&editor.host);

    // Shell built-in: Settings (owner = null; not a plugin).
    try editor.host.registerSidebarView(.{
        .id = view_settings,
        .icon = dvui.entypo.cog,
        .title = "Settings",
        .draw = drawSettingsPane,
    });

    // Shell built-in: Output (owner = null; not a plugin). `persistent` keeps it visible
    // even with no document open, since it's a diagnostic view, not a per-file one.
    try editor.host.registerBottomView(.{
        .id = "shell.output",
        .title = "Output",
        .persistent = true,
        .draw = OutputPanel.draw,
    });

    // Menu bar contributions (non-macOS in-app bar). The File/Edit draw bodies still live
    // in the shell's `Menu.zig`; a later step could move them into the workbench / pixel-art
    // plugins so those self-register. Order = bar order.
    // One registration per `menu_model.menu_bar` entry, all pointing at the same generic
    // renderer with the model node as `ctx`. There is no longer a per-menu draw function that
    // could disagree with the macOS builder walking the same tree.
    inline for (&menu_model.menu_bar) |*sub| {
        try editor.host.registerMenu(.{
            .id = sub.id,
            .title = sub.title,
            .draw = Menu.drawModelMenu,
            .ctx = @constCast(@ptrCast(sub)),
        });
    }

    // Keybind contributions: each plugin registers its own binds into the window's
    // keybind map. The shell already registered its global/navigation/region binds
    // in `Keybinds.register` (during `init`, before this runs), so the two halves
    // are disjoint — no `putNoClobber` clash. Runs on all targets (web included).
    syncLoadedPluginDvuiContexts(editor);
    const window = dvui.currentWindow();
    for (editor.host.plugins.items) |plugin| try plugin.contributeKeybinds(window);
    // Startup's only pass over the finished bind map. `rebuildKeybinds` covers later plugin
    // load/unload, but it never runs during boot — without this the keymap stays empty and no
    // shell shortcut works until a plugin happens to be reloaded.
    try Keybinds.buildKeymap(editor);

    // The workbench-api is the file explorer's programmatic surface and drives OS
    // file management (open/create/rename/delete/move on disk). The web build has
    // no filesystem API, so the workbench *service* is left out there for now.
    // Keeping it behind a comptime gate also keeps its native-only fn bodies out of
    // wasm analysis entirely (the codebase's dead-branch convention; see
    // `web_main.zig`).
    if (comptime builtin.target.cpu.arch != .wasm32) {
        editor.workbench.initService(&editor.host);
        try editor.host.registerService(
            Workbench.Api.service_name,
            &editor.workbench.api,
            editor.host.pluginById("workbench"),
        );
    }

    // Live external-edit reconciliation for settings.zon + dropped-in plugin discovery (see
    // R11/R12 in docs/PLUGIN_MANIFEST_PLAN.md). Must happen here, in `postInit`, not `init` —
    // nightwatch retains `&editor.settings_watcher.handler`, so `editor` has to already be at
    // its final heap address (see `SettingsWatcher.start`'s doc comment). Best-effort
    // throughout: fizzy must never fail to launch just because the watcher couldn't start.
    if (comptime builtin.target.cpu.arch != .wasm32) {
        editor.settings_watcher = SettingsWatcher.init(fizzy.app.allocator, editor.config_folder) catch |err| blk: {
            dvui.log.warn("settings watcher: failed to init ({s}); external hand-edits / dropped-in plugins won't be picked up live", .{@errorName(err)});
            break :blk null;
        };
        if (editor.settings_watcher) |*w| {
            w.start() catch |err| {
                dvui.log.warn("settings watcher: failed to start ({s}); external hand-edits / dropped-in plugins won't be picked up live", .{@errorName(err)});
                w.stop();
                editor.settings_watcher = null;
            };
        }

        // Open-document external-change watching (reload clean tabs; conflict dialog on save).
        editor.document_watcher = DocumentWatcher.init(fizzy.app.allocator);
        if (editor.document_watcher) |*w| {
            w.start() catch |err| {
                dvui.log.warn("document watcher: failed to start ({s}); open files won't pick up external edits live", .{@errorName(err)});
                w.stop();
                editor.document_watcher = null;
            };
        }
    }
}

/// The Settings sidebar view: a single searchable tree (`SettingsTree`) whose "Fizzy" branch
/// carries the shell's own categories (`Explorer.settings.groups`) and whose remaining branches
/// are one per plugin — loaded plugins' schema fields drawn by `PluginSettingsPane.drawField`,
/// failed plugins' failure reason.
fn drawSettingsPane(_: ?*anyopaque) anyerror!void {
    try SettingsTree.draw();
}

// ---- EditorAPI: the shell-provided read/utility surface for plugins ----------
// Installed on the Host in `postInit`; `ctx` is this `*Editor`.

const shell_api_vtable: sdk.EditorAPI.VTable = .{
    .arena = shellArena,
    .folder = shellFolder,
    .paletteFolder = shellPaletteFolder,
    .markSettingsDirty = shellMarkSettingsDirty,
    .contentOpacity = shellContentOpacity,
    .isMaximized = shellIsMaximized,
    .isMacOS = shellIsMacOS,
    .appliesNativeWindowOpacity = shellAppliesNativeWindowOpacity,
    .panZoomScheme = shellPanZoomScheme,
    .explorerRect = shellExplorerRect,
    .explorerVirtualSize = shellExplorerVirtualSize,
    .showSaveDialog = shellShowSaveDialog,
    .activeDoc = shellActiveDoc,
    .docByIndex = shellDocByIndex,
    .docById = shellDocById,
    .docIndex = shellDocIndex,
    .openDocCount = shellOpenDocCount,
    .setActiveDocIndex = shellSetActiveDocIndex,
    .swapDocs = shellSwapDocs,
    .allocDocId = shellAllocDocId,
    .explorerViewportWidth = shellExplorerViewportWidth,
    .docFromPath = shellDocFromPath,
    .openFilePath = shellOpenFilePath,
    .openOrFocusFileAtGrouping = shellOpenOrFocusFileAtGrouping,
    .closeDocById = shellCloseDocById,
    .setProjectFolder = shellSetProjectFolder,
    .closeProjectFolder = shellCloseProjectFolder,
    .recentFolderCount = shellRecentFolderCount,
    .recentFolderAt = shellRecentFolderAt,
    .openInFileBrowser = shellOpenInFileBrowser,
    .isPathIgnored = shellIsPathIgnored,
    .explorerBranchIsOpen = shellExplorerBranchIsOpen,
    .setExplorerBranchOpen = shellSetExplorerBranchOpen,
    .drawWorkspaces = shellDrawWorkspaces,
    .showOpenFolderDialog = shellShowOpenFolderDialog,
    .showOpenFileDialog = shellShowOpenFileDialog,
    .save = shellSave,
    .requestPrepareFrame = shellRequestCompositeWarmup,
    .refresh = shellRefresh,
    .allocUntitledPath = shellAllocUntitledPath,
    .createDocument = shellCreateDocument,
    .setExplorerNewFilePath = shellSetExplorerNewFilePath,
    .requestSaveAs = shellRequestSaveAs,
    .requestWebSave = shellRequestWebSave,
    .cancelPendingSaveDialog = shellCancelPendingSaveDialog,
    .setPendingCloseDocId = shellSetPendingCloseDocId,
    .queueCloseAfterSave = shellQueueCloseAfterSave,
    .trackQuitSaveInFlight = shellTrackQuitSaveInFlight,
    .resumeSaveAllQuit = shellResumeSaveAllQuit,
    .abortSaveAllQuit = shellAbortSaveAllQuit,
    .logLine = shellLogLine,
    .drawMenuItem = shellDrawMenuItem,
    .loadPluginSettingsFile = shellLoadPluginSettingsFile,
};

fn shellLogLine(ctx: *anyopaque, level: std.log.Level, scope: []const u8, message: []const u8) void {
    _ = ctx;
    fizzy.OutputLog.appendLine(level, scope, message);
}

/// See `EditorAPI.VTable.drawMenuItem`'s doc comment for why this widget construction has to
/// happen here (in the shell) rather than in the calling plugin.
fn shellDrawMenuItem(ctx: *anyopaque, title: []const u8, command_id: ?[]const u8) bool {
    const editor = shellCtx(ctx);
    _ = dvui.separator(@src(), .{ .expand = .horizontal });
    var mi = dvui.menuItem(@src(), .{}, .{
        .expand = .horizontal,
        // `Wyhash.hash` always returns `u64`; `id_extra` is `usize`, which is 32-bit on
        // wasm32 — truncate rather than relying on the width match that only holds natively.
        .id_extra = @truncate(std.hash.Wyhash.hash(0, title)),
    });
    defer mi.deinit();
    const clicked = mi.activeRect() != null;
    // Same resolution the shell's own menu rows use (`Menu.hotkeyFor`), so a plugin row and a
    // shell row bound to the same chord can never disagree about what to display.
    const kb: dvui.enums.Keybind = if (command_id) |id|
        Keybinds.menuKeybindFor(editor, id)
    else
        .{};
    fizzy.dvui.labelWithKeybind(title, kb, true, .{ .expand = .horizontal }, .{ .expand = .horizontal });
    return clicked;
}

/// See `EditorAPI.VTable.loadPluginSettingsFile`'s doc comment for why this must run here
/// (the shell's own compiled code) rather than inside `Host.loadPluginSettings` directly.
/// Reads the whole merged `<config>/settings.zon` and pulls out just `id`'s
/// `.plugins.<id>.settings` blob (R12 nested shape — author fields live under `.settings` so
/// they can never collide with the shell-reserved `.enabled`).
fn shellLoadPluginSettingsFile(ctx: *anyopaque, id: []const u8) ?[]u8 {
    // Wasm: no filesystem; `fizzy.fs.readZ` uses `Io.Dir.cwd()` (posix.AT), which doesn't exist
    // for this target — `Host.loadPluginSettings` already short-circuits before ever calling
    // through to here, but this vtable entry is still type-checked for every target regardless.
    if (comptime builtin.target.cpu.arch == .wasm32) return null;
    const editor = shellCtx(ctx);
    const path = std.fs.path.join(fizzy.app.allocator, &.{ editor.config_folder, "settings.zon" }) catch return null;
    defer fizzy.app.allocator.free(path);
    const data = fizzy.fs.readZ(editor.host.allocator, dvui.io, path) catch return null;
    defer editor.host.allocator.free(data);
    return readPluginSettingsText(editor.host.allocator, data, id);
}

fn shellCtx(ctx: *anyopaque) *Editor {
    return @ptrCast(@alignCast(ctx));
}
fn shellArena(ctx: *anyopaque) std.mem.Allocator {
    return shellCtx(ctx).arena.allocator();
}
fn shellFolder(ctx: *anyopaque) ?[]const u8 {
    return shellCtx(ctx).folder;
}
fn shellPaletteFolder(ctx: *anyopaque) ?[]const u8 {
    return shellCtx(ctx).palette_folder;
}
fn shellMarkSettingsDirty(ctx: *anyopaque) void {
    shellCtx(ctx).markSettingsDirty();
}
fn shellContentOpacity(ctx: *anyopaque) f32 {
    return shellCtx(ctx).settings.content_opacity;
}
fn shellIsMaximized(ctx: *anyopaque) bool {
    _ = ctx;
    return fizzy.backend.isMaximized(dvui.currentWindow());
}
fn shellIsMacOS(_: *anyopaque) bool {
    return fizzy.platform.isMacOS();
}
fn shellAppliesNativeWindowOpacity(_: *anyopaque) bool {
    if (comptime builtin.target.cpu.arch == .wasm32) return false;
    return builtin.os.tag == .macos or builtin.os.tag == .windows;
}
fn shellPanZoomScheme(ctx: *anyopaque) sdk.EditorAPI.PanZoomScheme {
    const editor = shellCtx(ctx);
    return switch (Settings.resolvedPanZoomScheme(&editor.settings, fizzy.platform.isMacOS())) {
        .mouse => .mouse,
        .trackpad => .trackpad,
    };
}
fn shellExplorerRect(ctx: *anyopaque) dvui.Rect {
    return shellCtx(ctx).explorer.rect;
}
fn shellExplorerVirtualSize(ctx: *anyopaque) dvui.Size {
    return shellCtx(ctx).explorer.scroll_info.virtual_size;
}
fn shellShowSaveDialog(
    ctx: *anyopaque,
    cb: sdk.EditorAPI.SaveDialogCallback,
    filters: []const sdk.EditorAPI.SaveDialogFilter,
    default_filename: []const u8,
    default_folder: ?[]const u8,
) void {
    _ = ctx;
    // `SaveDialogFilter` shares `DialogFileFilter`'s layout, so the slice forwards as-is.
    const native_filters: [*]const fizzy.backend.DialogFileFilter = @ptrCast(filters.ptr);
    fizzy.backend.showSaveFileDialog(cb, native_filters[0..filters.len], default_filename, default_folder);
}
fn shellActiveDoc(ctx: *anyopaque) ?sdk.DocHandle {
    return shellCtx(ctx).activeDoc();
}
fn shellDocByIndex(ctx: *anyopaque, index: usize) ?sdk.DocHandle {
    return shellCtx(ctx).docAt(index);
}
fn shellDocById(ctx: *anyopaque, id: u64) ?sdk.DocHandle {
    return shellCtx(ctx).docById(id);
}
fn shellDocIndex(ctx: *anyopaque, id: u64) ?usize {
    return shellCtx(ctx).open_files.getIndex(id);
}
fn shellOpenDocCount(ctx: *anyopaque) usize {
    return shellCtx(ctx).open_files.count();
}
fn shellSetActiveDocIndex(ctx: *anyopaque, index: usize) void {
    shellCtx(ctx).setActiveFile(index);
}
fn shellSwapDocs(ctx: *anyopaque, a: usize, b: usize) void {
    const editor = shellCtx(ctx);
    std.mem.swap(sdk.DocHandle, &editor.open_files.values()[a], &editor.open_files.values()[b]);
    std.mem.swap(u64, &editor.open_files.keys()[a], &editor.open_files.keys()[b]);
}
fn shellAllocDocId(ctx: *anyopaque) u64 {
    return shellCtx(ctx).newFileID();
}
fn shellExplorerViewportWidth(ctx: *anyopaque) f32 {
    return shellCtx(ctx).explorer.scroll_info.viewport.w;
}
fn shellDocFromPath(ctx: *anyopaque, path: []const u8) ?sdk.DocHandle {
    return shellCtx(ctx).docFromPath(path);
}
fn shellOpenFilePath(ctx: *anyopaque, path: []const u8, grouping: u64) anyerror!bool {
    return shellCtx(ctx).openFilePath(path, grouping);
}
fn shellOpenOrFocusFileAtGrouping(ctx: *anyopaque, path: []const u8, grouping: u64) anyerror!?usize {
    return shellCtx(ctx).openOrFocusFileAtGrouping(path, grouping);
}
fn shellCloseDocById(ctx: *anyopaque, id: u64) anyerror!void {
    return shellCtx(ctx).closeFileID(id);
}
fn shellSetProjectFolder(ctx: *anyopaque, path: []const u8) anyerror!void {
    return shellCtx(ctx).setProjectFolder(path);
}
fn shellCloseProjectFolder(ctx: *anyopaque) void {
    shellCtx(ctx).closeProjectFolder();
}
fn shellRecentFolderCount(ctx: *anyopaque) usize {
    return shellCtx(ctx).recents.folders.items.len;
}
fn shellRecentFolderAt(ctx: *anyopaque, index: usize) ?[]const u8 {
    const editor = shellCtx(ctx);
    if (index >= editor.recents.folders.items.len) return null;
    return editor.recents.folders.items[index];
}
fn shellOpenInFileBrowser(ctx: *anyopaque, path: []const u8) anyerror!void {
    return shellCtx(ctx).openInFileBrowser(path);
}
fn shellIsPathIgnored(
    ctx: *anyopaque,
    project_root: []const u8,
    abs_path: []const u8,
    name: []const u8,
    kind: std.Io.File.Kind,
) bool {
    return shellCtx(ctx).ignore.isIgnored(project_root, abs_path, name, kind);
}
fn shellExplorerBranchIsOpen(ctx: *anyopaque, branch_id: dvui.Id) bool {
    return shellCtx(ctx).explorer.open_branches.contains(branch_id);
}
fn shellSetExplorerBranchOpen(ctx: *anyopaque, branch_id: dvui.Id, open: bool) void {
    const editor = shellCtx(ctx);
    if (open) {
        editor.explorer.open_branches.put(branch_id, {}) catch {};
    } else {
        _ = editor.explorer.open_branches.remove(branch_id);
    }
}
fn shellDrawWorkspaces(ctx: *anyopaque, index: usize) anyerror!dvui.App.Result {
    return drawWorkspaces(shellCtx(ctx), index);
}
fn shellShowOpenFolderDialog(ctx: *anyopaque, cb: sdk.EditorAPI.OpenPathsCallback, default_folder: ?[]const u8) void {
    _ = ctx;
    fizzy.backend.showOpenFolderDialog(cb, default_folder);
}
fn shellShowOpenFileDialog(
    ctx: *anyopaque,
    cb: sdk.EditorAPI.OpenPathsCallback,
    filters: []const sdk.EditorAPI.SaveDialogFilter,
    default_filename: []const u8,
    default_folder: ?[]const u8,
) void {
    _ = ctx;
    const native_filters: [*]const fizzy.backend.DialogFileFilter = @ptrCast(filters.ptr);
    fizzy.backend.showOpenFileDialog(cb, native_filters[0..filters.len], default_filename, default_folder);
}
fn shellSave(ctx: *anyopaque) anyerror!void {
    return shellCtx(ctx).save();
}
fn shellRequestCompositeWarmup(ctx: *anyopaque) void {
    shellCtx(ctx).requestPrepareFrame();
}
fn shellRefresh(ctx: *anyopaque) void {
    _ = ctx;
    // Safe from any thread (see `SDLBackend.refresh`'s doc comment) — a single call reliably
    // wakes the blocked event loop and produces exactly one composited frame; see
    // `render_bridge.refresh`'s doc comment for how that was verified.
    fizzy.app.window.backend.refresh();
}
fn shellAllocUntitledPath(ctx: *anyopaque) anyerror![]u8 {
    return shellCtx(ctx).allocNextUntitledPath();
}
fn shellCreateDocument(ctx: *anyopaque, path: []const u8, grid: sdk.EditorAPI.NewDocGrid) anyerror!sdk.DocHandle {
    return shellCtx(ctx).newFile(path, grid);
}
fn shellSetExplorerNewFilePath(ctx: *anyopaque, path: []const u8) anyerror!void {
    const Files = fizzy.Explorer.files;
    if (Files.new_file_path) |old| {
        fizzy.app.allocator.free(old);
    }
    Files.new_file_path = try fizzy.app.allocator.dupe(u8, path);
    _ = ctx;
}
fn shellRequestSaveAs(ctx: *anyopaque) void {
    shellCtx(ctx).requestSaveAs();
}
fn shellRequestWebSave(ctx: *anyopaque, kind: sdk.EditorAPI.WebSaveKind) void {
    const native_kind: Dialogs.WebSaveAs.Kind = switch (kind) {
        .save => .save,
        .save_as => .save_as,
    };
    shellCtx(ctx).requestWebSaveDialog(native_kind);
}
fn shellCancelPendingSaveDialog(ctx: *anyopaque) void {
    shellCtx(ctx).cancelPendingSaveDialog();
}
fn shellSetPendingCloseDocId(ctx: *anyopaque, id: u64) void {
    shellCtx(ctx).pending_close_file_id = id;
}
fn shellQueueCloseAfterSave(ctx: *anyopaque, id: u64) anyerror!void {
    try shellCtx(ctx).pending_close_after_save.put(fizzy.app.allocator, id, {});
}
fn shellTrackQuitSaveInFlight(ctx: *anyopaque, id: u64) anyerror!void {
    try shellCtx(ctx).quit_saves_in_flight.put(fizzy.app.allocator, id, {});
}
fn shellResumeSaveAllQuit(ctx: *anyopaque) void {
    shellCtx(ctx).pending_quit_continue = true;
}
fn shellAbortSaveAllQuit(ctx: *anyopaque) void {
    shellCtx(ctx).abortSaveAllQuit();
}

/// Store a loaded/created document in the plugin registry and register its handle.
pub fn insertOpenDoc(editor: *Editor, doc_buf: *anyopaque, owner: *sdk.Plugin, id: u64) !void {
    const ptr = try owner.registerOpenDocument(doc_buf);
    try editor.open_files.put(fizzy.app.allocator, id, .{
        .ptr = ptr,
        .owner = owner,
        .id = id,
    });
    if (editor.document_watcher) |*w| {
        if (editor.docById(id)) |doc| w.track(editor, doc);
    }
}
pub fn docAt(editor: *Editor, index: usize) ?sdk.DocHandle {
    if (index >= editor.open_files.values().len) return null;
    return editor.open_files.values()[index];
}

pub fn docById(editor: *Editor, id: u64) ?sdk.DocHandle {
    return editor.open_files.get(id);
}

pub fn activeDoc(editor: *Editor) ?sdk.DocHandle {
    return editor.workbench.activeDoc();
}

pub fn clearFileTreeDataId(editor: *Editor) void {
    editor.workbench.clearFileTreeDataId();
}

/// Files sidebar inactive — drop tree dvui stash and tab-drag state.
pub fn resetFileTreeWhenFilesHidden(editor: *Editor) void {
    editor.clearFileTreeDataId();
    editor.clearFileTreeTabDragDropState();
}

pub fn clearAllWorkspaceCenter(editor: *Editor) void {
    editor.workbench.clearAllWorkspaceCenter();
}

/// Workbench routing helpers (type-agnostic; dispatch through `doc.owner`).
pub fn docGrouping(_: *Editor, doc: sdk.DocHandle) u64 {
    return doc.owner.documentGrouping(doc);
}

pub fn setDocGrouping(_: *Editor, doc: sdk.DocHandle, grouping: u64) void {
    doc.owner.setDocumentGrouping(doc, grouping);
}

pub fn docPath(_: *Editor, doc: sdk.DocHandle) []const u8 {
    return doc.owner.documentPath(doc);
}

/// Looks up an open document by path. Exact match first (the hot path — file-tree paint hits
/// this every frame with already-canonical abs paths); on miss, collapses `.` / `..` /
/// duplicate separators so a caller holding `a/./b.zig` still finds a doc stored as `a/b.zig`
/// (and vice versa for anything opened before `openFilePath` started normalizing). See
/// `fizzy.paths.normalize`.
pub fn docFromPath(editor: *Editor, path: []const u8) ?sdk.DocHandle {
    for (editor.open_files.values()) |doc| {
        if (std.mem.eql(u8, editor.docPath(doc), path)) return doc;
    }

    const key = fizzy.paths.normalize(fizzy.app.allocator, path) catch return null;
    defer fizzy.app.allocator.free(key);

    for (editor.open_files.values()) |doc| {
        const stored = editor.docPath(doc);
        if (std.mem.eql(u8, stored, key)) return doc;
        // Skip a second normalize when the stored spelling already matched `path` above, or
        // already equals `key`. Only needed when a pre-normalization doc still carries a `.`
        // component that the caller's key has already collapsed.
        if (std.mem.eql(u8, stored, path)) continue;
        const stored_canon = fizzy.paths.normalize(fizzy.app.allocator, stored) catch continue;
        defer fizzy.app.allocator.free(stored_canon);
        if (std.mem.eql(u8, stored_canon, key)) return doc;
    }
    return null;
}

pub fn bindDocToPane(_: *Editor, doc: sdk.DocHandle, canvas_id: dvui.Id, workspace: *anyopaque, center: bool) void {
    doc.owner.bindDocumentToPane(doc, canvas_id, workspace, center);
}

/// Ensures `{config}/themes` exists and scans `*.json` for future user themes (loaded entries are prepended before Fizzy themes).
fn appendUserThemes(gpa: std.mem.Allocator, editor: *Editor) !void {
    const themes_dir = try std.fs.path.join(gpa, &.{ editor.config_folder, "themes" });

    if (!std.fs.path.isAbsolute(themes_dir)) {
        gpa.free(themes_dir);
        return;
    }
    defer gpa.free(themes_dir);

    std.Io.Dir.accessAbsolute(dvui.io, themes_dir, .{ .read = true }) catch {
        try std.Io.Dir.createDirAbsolute(dvui.io, themes_dir, .default_dir);
    };

    var dir = try std.Io.Dir.cwd().openDir(dvui.io, themes_dir, .{ .access_sub_paths = false, .iterate = true });
    defer dir.close(dvui.io);

    var iter = dir.iterate();
    while (try iter.next(dvui.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        // Future: parse Theme JSON and append before Fizzy themes so folder overrides builtins by list order.
    }
}

/// Clamp settings font sizes (6–20), apply those sizes to every registered theme (preserving each theme’s font families), and refresh the active DVUI theme.
pub fn applyFontSizesFromSettings(editor: *Editor) void {
    const clampFontSize = struct {
        fn f(sz: f32) f32 {
            return @floatCast(std.math.clamp(@round(sz), 6.0, 20.0));
        }
    }.f;

    const sb = clampFontSize(editor.settings.font_body_size);
    const st = clampFontSize(editor.settings.font_title_size);
    const sh = clampFontSize(editor.settings.font_heading_size);
    const sm = clampFontSize(editor.settings.font_mono_size);

    editor.settings.font_body_size = sb;
    editor.settings.font_title_size = st;
    editor.settings.font_heading_size = sh;
    editor.settings.font_mono_size = sm;

    for (editor.themes.items) |*t| {
        t.font_body = t.font_body.withSize(sb);
        t.font_title = t.font_title.withSize(st);
        t.font_heading = t.font_heading.withSize(sh);
        t.font_mono = t.font_mono.withSize(sm);
    }

    const active_name = dvui.themeGet().name;
    for (editor.themes.items) |*t| {
        if (std.mem.eql(u8, t.name, active_name)) {
            dvui.themeSet(t.*);
            break;
        }
    }
}

fn themeFilenameToName(trimmed: []const u8) ?[]const u8 {
    const pairs = [_]struct { stub: []const u8, canonical: []const u8 }{
        .{ .stub = "fizzy_dark.json", .canonical = "Fizzy Dark" },
        .{ .stub = "fizzy_light.json", .canonical = "Fizzy Light" },
    };
    for (pairs) |p| {
        if (std.mem.eql(u8, trimmed, p.stub)) return p.canonical;
    }
    return null;
}

/// Select a theme from `editor.themes` matching `settings.theme`: trim, legacy file-name aliases, then exact and case-insensitive name match. Falls back to `Settings.default_theme`, then the first entry, and logs if the stored value did not match anything.
fn resolveSettingsTheme(editor: *Editor) *dvui.Theme {
    const trimmed = std.mem.trim(u8, editor.settings.theme, &std.ascii.whitespace);
    const candidate = themeFilenameToName(trimmed) orelse trimmed;

    for (editor.themes.items) |*t| {
        if (std.mem.eql(u8, t.name, candidate)) return t;
    }
    for (editor.themes.items) |*t| {
        if (std.ascii.eqlIgnoreCase(t.name, candidate)) return t;
    }
    dvui.log.warn(
        "Saved theme \"{s}\" did not match any known theme; falling back to \"{s}\".",
        .{ trimmed, Settings.default_theme },
    );
    for (editor.themes.items) |*t| {
        if (std.mem.eql(u8, t.name, Settings.default_theme)) return t;
    }
    std.debug.assert(editor.themes.items.len > 0);
    return &editor.themes.items[0];
}

pub fn applySettingsTheme(editor: *Editor) !void {
    const t = resolveSettingsTheme(editor);
    if (!std.mem.eql(u8, editor.settings.theme, t.name)) {
        try Settings.setThemeName(&editor.settings, fizzy.app.allocator, t.name);
    }
    dvui.themeSet(t.*);
    editor.applyFontSizesFromSettings();
}

pub fn applyHoldMenuDuration(editor: *Editor) void {
    const ms = @max(@as(u32, 100), editor.settings.hold_menu_duration_ms);
    fizzy.app.window.hold_menu_duration_ns = @as(i128, ms) * 1_000_000;
}

pub fn currentGroupingID(editor: *Editor) u64 {
    return editor.workbench.currentGroupingID();
}

pub fn newGroupingID(editor: *Editor) u64 {
    return editor.workbench.newGroupingID();
}

pub fn newFileID(editor: *Editor) u64 {
    editor.file_id_counter += 1;
    return editor.file_id_counter;
}

pub fn markSettingsDirty(editor: *Editor) void {
    editor.settings_dirty = true;
    editor.settings_save_deadline_ns = fizzy.perf.nanoTimestamp() + Settings.autosave_timeout_ns;
}

/// Same debou
/// nce shape as `markSettingsDirty`, but for `window.zon`'s explorer/panel ratios —
/// kept separate so dragging a splitter (which calls this every frame) never forces a
/// settings.zon write attempt.
pub fn markWindowRatiosDirty(editor: *Editor) void {
    editor.window_ratios_dirty = true;
    editor.window_ratios_save_deadline_ns = fizzy.perf.nanoTimestamp() + Settings.autosave_timeout_ns;
}

fn activelyDrawing(editor: *Editor) bool {
    for (editor.host.plugins.items) |plugin| {
        if (plugin.needsContinuousRepaint()) return true;
    }
    return false;
}

/// Composes the shell's own fields (`Settings.serialize`) together with every plugin's pending
/// settings write into one `<config>/settings.zon` and writes it in a single pass (see
/// `docs/PLUGIN_MANIFEST_PLAN.md` R10). This *must* stay one combined write: writing the shell's
/// fields and the plugins' blobs independently would let whichever write ran second silently
/// drop the other's data, since `Settings.serialize` only knows the shell's own fields and has no
/// notion of `.plugins` at all. `settings_last_saved_hash` dedupes over the *whole* composed
/// text, so a plugin-only settings change still triggers a real write even when the shell's own
/// fields haven't moved.
///
/// Shared by `writeMergedSettings` and the startup dedup-hash seed (see `init`): composes the
/// merged `settings.zon` text from the shell's current in-memory fields plus `overlay`'s plugin
/// blocks, layered onto whatever is already on disk at `settings_path` (see
/// `SettingsPluginsZon.composeMergedText`'s doc comment for exactly what's preserved vs.
/// overlaid). External hand-edits are reconciled live by `SettingsWatcher` (R11/R12) before the
/// next autosave can clobber them. Caller-owned; free with `gpa`.
fn composeSettingsText(editor: *Editor, gpa: std.mem.Allocator, settings_path: []const u8, overlay: []const SettingsPluginsZon.Entry) ![]u8 {
    const shell_text = try Settings.serialize(&editor.settings, gpa);
    defer gpa.free(shell_text);

    const existing = fizzy.fs.readZ(gpa, dvui.io, settings_path) catch null;
    defer if (existing) |e| gpa.free(e);

    return SettingsPluginsZon.composeMergedText(gpa, shell_text, existing, overlay);
}

fn writeMergedSettings(editor: *Editor, settings_path: []const u8) !void {
    // Wasm: no on-disk config; `composeSettingsText` reads via `Io.Dir.cwd()` (posix.AT), which
    // doesn't exist for this target.
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    const gpa = fizzy.app.allocator;

    var pending_settings = editor.host.takePendingPluginSettings();
    defer {
        var it = pending_settings.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            if (e.value_ptr.*) |v| gpa.free(v);
        }
        pending_settings.deinit(gpa);
    }

    var pending_enabled = editor.plugin_enabled_pending;
    editor.plugin_enabled_pending = .empty;
    defer {
        var it = pending_enabled.iterator();
        while (it.next()) |e| gpa.free(e.key_ptr.*);
        pending_enabled.deinit(gpa);
    }

    // Union of ids touched by either buffer this cycle.
    var touched: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer touched.deinit(gpa);
    {
        var it = pending_settings.iterator();
        while (it.next()) |e| try touched.put(gpa, e.key_ptr.*, {});
    }
    {
        var it = pending_enabled.iterator();
        while (it.next()) |e| try touched.put(gpa, e.key_ptr.*, {});
    }

    const existing = fizzy.fs.readZ(gpa, dvui.io, settings_path) catch null;
    defer if (existing) |e| gpa.free(e);

    var overlay: std.ArrayListUnmanaged(SettingsPluginsZon.Entry) = .empty;
    defer {
        for (overlay.items) |e| {
            if (e.text) |t| gpa.free(t);
        }
        overlay.deinit(gpa);
    }

    var tit = touched.iterator();
    while (tit.next()) |te| {
        const id = te.key_ptr.*;

        // Base from disk, then overlay whichever of the two buffers changed this cycle.
        var enabled = readPluginEnabled(gpa, existing, id);
        var settings_owned = readPluginSettingsText(gpa, existing, id);
        defer if (settings_owned) |s| gpa.free(s);
        var settings_text: ?[]const u8 = settings_owned;

        if (pending_enabled.get(id)) |e| enabled = e;
        if (pending_settings.get(id)) |maybe| {
            // Pending owns this blob (freed with `pending_settings`); borrow for composition.
            if (settings_owned) |s| {
                gpa.free(s);
                settings_owned = null;
            }
            settings_text = maybe;
        }

        if (!enabled and settings_text == null) {
            try overlay.append(gpa, .{ .id = id, .text = null });
        } else {
            const block = try SettingsPluginsZon.composePluginIdBlock(gpa, enabled, settings_text);
            try overlay.append(gpa, .{ .id = id, .text = block });
        }
    }

    const composed = try editor.composeSettingsText(gpa, settings_path, overlay.items);
    defer gpa.free(composed);

    const hash = std.hash.Wyhash.hash(0, composed);
    if (editor.settings_last_saved_hash == hash) return;

    try std.Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = settings_path, .data = composed });
    editor.settings_last_saved_hash = hash;
    // Open settings.zon tab (if any) must pick this up — don't wait on a per-file FS event.
    if (editor.document_watcher) |*w| w.notifyPathChanged(editor, settings_path);
}

/// Called from `SettingsWatcher.tick` when the background watcher noticed a change to
/// `settings.zon` — reconciles that external change (hand edit, another tool) into fizzy's live
/// state instead of letting the next autosave silently overwrite it. See R11 in
/// docs/PLUGIN_MANIFEST_PLAN.md for the full design; `SettingsWatcher` itself never touches file
/// content, only detects "something changed" — this is the half that actually reads and applies.
pub fn reconcileExternalSettingsChange(editor: *Editor) void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    const gpa = fizzy.app.allocator;

    const settings_path = std.fs.path.join(gpa, &.{ editor.config_folder, "settings.zon" }) catch return;
    defer gpa.free(settings_path);

    const data = fizzy.fs.readZ(gpa, dvui.io, settings_path) catch return; // deleted/unreadable: nothing to reconcile
    defer gpa.free(data);

    const hash = std.hash.Wyhash.hash(0, data);
    if (editor.settings_last_saved_hash) |last| {
        if (last == hash) return; // our own last write, or nothing's actually changed
    }
    dvui.log.info("settings watcher: external change to settings.zon detected; reconciling", .{});

    // Always refresh an open settings.zon tab from disk first — even if the shell fails to
    // parse the file below. The text buffer should still track what the user (or another
    // tool) wrote; parse failure must not leave the tab stuck on a stale snapshot.
    if (editor.document_watcher) |*w| w.notifyPathChanged(editor, settings_path);

    // Parse without falling back to defaults on failure (see `Settings.parseOnly`'s doc
    // comment) — a torn/partial read here must never reset every shell field and every
    // plugin's settings. Left unreconciled until another external change retriggers a read
    // (rare in practice: the watcher's debounce already gives a normal atomic save time to
    // settle before this runs at all).
    const parsed = Settings.parseOnly(gpa, data) catch |err| {
        dvui.log.warn("settings watcher: could not parse external settings.zon change ({s}); skipping this reconciliation", .{@errorName(err)});
        return;
    };
    defer Settings.freeParsed(gpa, parsed);

    // Shell fields, one at a time rather than `editor.settings = parsed` wholesale: `theme` is
    // runtime-owned (see its doc comment on `Settings`) and must not be clobbered by the raw
    // parsed copy, which is exactly what a whole-struct assign would do. If you add a field to
    // `Settings`, add it here too, unless it's `theme`.
    editor.settings.setThemeName(gpa, parsed.theme) catch |err|
        dvui.log.warn("settings watcher: failed to apply external theme change: {s}", .{@errorName(err)});
    editor.settings.hold_menu_duration_ms = parsed.hold_menu_duration_ms;
    editor.settings.font_body_size = parsed.font_body_size;
    editor.settings.font_title_size = parsed.font_title_size;
    editor.settings.font_heading_size = parsed.font_heading_size;
    editor.settings.font_mono_size = parsed.font_mono_size;
    editor.settings.window_opacity_dark = parsed.window_opacity_dark;
    editor.settings.window_opacity_light = parsed.window_opacity_light;
    editor.settings.content_opacity = parsed.content_opacity;
    editor.settings.input_scheme = parsed.input_scheme;

    // Re-apply the existing idempotent appliers unconditionally — cheap, and each already
    // no-ops when nothing relevant changed.
    editor.applySettingsTheme() catch |err|
        dvui.log.warn("settings watcher: applySettingsTheme failed: {s}", .{@errorName(err)});
    editor.applyFontSizesFromSettings();
    editor.applyHoldMenuDuration();

    editor.reconcilePluginEnabled(data);
    editor.reconcileDiscoveredPlugins();
    editor.reconcilePluginSettings();

    // Mark this content as "known" now that it's fully applied, so neither the next autosave
    // nor a spurious re-wake re-triggers this same reconciliation again. Note a later call in
    // this same pass (`setPluginEnabled` → `setPluginEnabledPersisted` → `saveSettingsRaw`,
    // inside `reconcilePluginEnabled` above) may already have overwritten this with the hash of
    // its own fresh write — also correct, just redundant.
    editor.settings_last_saved_hash = hash;
}

/// Diffs each on-disk plugin directory's `.plugins.<id>.enabled` (freshly read) against the
/// live loaded/disabled state, loading/unloading to match — reusing `setPluginEnabled` so this
/// gets the exact same dirty-document safety guard the Plugins-tab toggle already has.
fn reconcilePluginEnabled(editor: *Editor, settings_data: [:0]const u8) void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    const gpa = fizzy.app.allocator;
    const plugins_dir = std.fs.path.join(gpa, &.{ editor.config_folder, "plugins" }) catch return;
    defer gpa.free(plugins_dir);

    var dir = std.Io.Dir.cwd().openDir(dvui.io, plugins_dir, .{ .iterate = true }) catch return;
    defer dir.close(dvui.io);
    var iter = dir.iterate();
    while (iter.next(dvui.io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const id = entry.name;
        if (id.len == 0 or id[0] == '.') continue;
        if (!isValidPluginId(id) or isBundledPluginId(id)) continue;

        const want_enabled = readPluginEnabled(gpa, settings_data, id);
        const is_disabled = editor.isPluginDisabled(id);
        const is_loaded = editor.host.pluginById(id) != null;

        if (want_enabled and (is_disabled or !is_loaded)) {
            const id_copy = gpa.dupe(u8, id) catch null;
            defer if (id_copy) |c| gpa.free(c);
            if (editor.setPluginEnabled(id, true, false)) {
                dvui.log.info("settings watcher: enabled '{s}' live (external edit)", .{id_copy orelse "?"});
            } else |err| {
                dvui.log.warn("settings watcher: could not enable '{s}' live ({s})", .{ id_copy orelse "?", @errorName(err) });
            }
        } else if (!want_enabled and is_loaded) {
            if (editor.setPluginEnabled(id, false, false)) {
                dvui.log.info("settings watcher: disabled '{s}' live (external edit)", .{id});
            } else |err| {
                dvui.log.warn("settings watcher: could not disable '{s}' live ({s}); it stays loaded", .{ id, @errorName(err) });
            }
        } else if (!want_enabled and !is_disabled) {
            // On disk, not enabled, not yet tracked — treat as a discovered-disabled entry.
            editor.trackDisabledPlugin(id) catch {};
        }
    }
}

/// Hot-reloads any loaded user plugin whose installed dylib changed on disk since we loaded it —
/// i.e. `zig build install` from a plugin repo, or the store writing an update, while fizzy runs.
///
/// Driven by `SettingsWatcher`'s existing recursive watch on `<config>/` (a plugin dylib write is
/// already an event there), but deliberately *outside* `reconcileExternalSettingsChange`: that one
/// gates on `settings.zon`'s content hash, which a dylib write never moves.
///
/// The comparison is mtime + size against the stamp `PluginLoader` recorded at load time. That
/// stamp reads from the *installed* path, which is never the mapped file (see
/// `PluginLoader.stableLoadCopyPath`), so a rebuild replacing it is safe on its own — this only
/// decides whether to pick the new build up now instead of at next launch.
pub fn reconcileChangedPluginBinaries(editor: *Editor) void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    const gpa = fizzy.app.allocator;

    // Collect first: `updatePlugin` unloads, which mutates `loaded_plugin_libs` (and frees the
    // entry's `plugin_id`, so the id has to be our own copy — the same reason
    // `setPluginEnabled`'s callers dupe before unloading).
    var changed: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (changed.items) |id| gpa.free(id);
        changed.deinit(gpa);
    }

    for (editor.loaded_plugin_libs.items) |loaded| {
        if (isBundledPluginId(loaded.plugin_id)) continue; // shipped beside the exe, not user-managed
        const st = std.Io.Dir.cwd().statFile(dvui.io, loaded.path, .{}) catch continue; // gone mid-write: leave it loaded
        if (st.mtime.nanoseconds == loaded.source_mtime_ns and st.size == loaded.source_size) continue;
        const id = gpa.dupe(u8, loaded.plugin_id) catch continue;
        changed.append(gpa, id) catch {
            gpa.free(id);
            continue;
        };
    }

    for (changed.items) |id| {
        if (editor.updatePlugin(id, false)) {
            dvui.log.info("plugin watcher: reloaded '{s}' from its rebuilt binary", .{id});
        } else |err| {
            dvui.log.warn("plugin watcher: could not reload rebuilt '{s}' ({s})", .{ id, @errorName(err) });
            // Re-stamp so a plugin we chose not to reload (unsaved documents, most likely) doesn't
            // re-trigger on every subsequent watcher event. The next rebuild moves the stamp again
            // and gets a fresh attempt; until then the running build stays, which is what the
            // failed unload already decided.
            editor.restampLoadedPlugin(id);
        }
    }
}

/// Point a loaded plugin's stamp at whatever is on disk now. See the re-stamp comment in
/// `reconcileChangedPluginBinaries`; no-op if `id` isn't loaded or the file can't be stat'd.
fn restampLoadedPlugin(editor: *Editor, id: []const u8) void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    for (editor.loaded_plugin_libs.items) |*loaded| {
        if (!std.mem.eql(u8, loaded.plugin_id, id)) continue;
        const st = std.Io.Dir.cwd().statFile(dvui.io, loaded.path, .{}) catch return;
        loaded.source_mtime_ns = st.mtime.nanoseconds;
        loaded.source_size = st.size;
        return;
    }
}

/// Rescans `<config>/plugins/` for directories not already loaded / tracked-disabled / failed,
/// and adds each as a disabled entry without writing settings.zon — a plugin dropped straight
/// into the folder must not auto-execute (R12). Store installs write `.enabled = true` themselves.
fn reconcileDiscoveredPlugins(editor: *Editor) void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    const gpa = fizzy.app.allocator;
    const plugins_dir = std.fs.path.join(gpa, &.{ editor.config_folder, "plugins" }) catch return;
    defer gpa.free(plugins_dir);

    const settings_path = std.fs.path.join(gpa, &.{ editor.config_folder, "settings.zon" }) catch return;
    defer gpa.free(settings_path);
    const data = fizzy.fs.readZ(gpa, dvui.io, settings_path) catch null;
    defer if (data) |d| gpa.free(d);

    var dir = std.Io.Dir.cwd().openDir(dvui.io, plugins_dir, .{ .iterate = true }) catch return;
    defer dir.close(dvui.io);
    var iter = dir.iterate();
    while (iter.next(dvui.io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const id = entry.name;
        if (id.len == 0 or id[0] == '.') continue;
        if (!isValidPluginId(id) or isBundledPluginId(id)) continue;
        if (editor.host.pluginById(id) != null) continue;
        if (editor.isPluginDisabled(id)) continue;
        const already_failed = blk: {
            for (editor.failed_user_plugins.items) |f| {
                if (std.mem.eql(u8, f.id, id)) break :blk true;
            }
            break :blk false;
        };
        if (already_failed) continue;

        // Only track as disabled when there's no `.enabled = true` on record — a store install
        // that raced the watcher will have written enabled=true and (usually) already loaded.
        if (readPluginEnabled(gpa, data, id)) continue;

        editor.trackDisabledPlugin(id) catch continue;
        dvui.log.info("settings watcher: discovered dropped-in plugin '{s}' (disabled until enabled in UI)", .{id});
    }
}

/// For every currently-loaded plugin with a registered settings schema, re-reads its
/// `.plugins.<id>.settings` blob and applies it if (and only if) it actually changed since the
/// last time we applied one — `SettingsSchema.last_applied_hash` is what stops a change to *one*
/// plugin's settings from spuriously renotifying *every other* loaded plugin just because the
/// whole file's hash moved (see `reconcileExternalSettingsChange`'s hash-gate, which only tells
/// us the file changed, not which plugin's part of it did).
fn reconcilePluginSettings(editor: *Editor) void {
    for (editor.host.settings_schemas.items) |*schema| {
        const blob = editor.host.loadPluginSettings(schema.owner.id) orelse {
            // Settings section removed (all-defaults) — apply an empty blob so the live value
            // resets to T's own declared defaults, but only when we previously had something.
            if (schema.last_applied_hash == 0) continue;
            schema.access.applyBlob(schema.value, schema.owner, ".{}");
            schema.last_applied_hash = 0;
            dvui.log.info("settings watcher: cleared settings for '{s}' (external edit)", .{schema.owner.id});
            continue;
        };
        defer editor.host.allocator.free(blob);
        const hash = std.hash.Wyhash.hash(0, blob);
        if (hash == schema.last_applied_hash) continue;
        schema.access.applyBlob(schema.value, schema.owner, blob);
        schema.last_applied_hash = hash;
        dvui.log.info("settings watcher: applied external settings change for '{s}'", .{schema.owner.id});
    }
}

/// Debounced autosave (defers while a canvas stroke is active).
fn saveSettingsGuarded(editor: *Editor) !void {
    // Wasm: settings live in memory only; `writeMergedSettings` uses `Io.Dir.cwd()` (posix.AT).
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    if (!editor.settings_dirty) return;

    const now = fizzy.perf.nanoTimestamp();
    if (now < editor.settings_save_deadline_ns) {
        scheduleSaveWakeup(editor.settings_save_deadline_ns - now, 0);
        return;
    }

    if (editor.activelyDrawing())
        return;

    const settings_path = try std.fs.path.join(fizzy.app.allocator, &.{ editor.config_folder, "settings.zon" });
    defer fizzy.app.allocator.free(settings_path);

    try editor.writeMergedSettings(settings_path);
    editor.settings_dirty = false;
}

/// Wake a frame once `remaining_ns` has elapsed so a debounced save actually fires while the app
/// is otherwise idle. Without this, the very event that dirtied the state (a settings-pane click,
/// a splitter drag release) is typically the *last* one before the app goes back to sleep, so no
/// frame ever runs to observe the deadline — the write, and everything that hangs off it (the
/// open settings.zon tab's reload via `writeMergedSettings`' `notifyPathChanged`), would wait on
/// some unrelated input instead. Same pattern/rationale as `drawSaveToasts`' threshold wakeup.
/// In-frame only; both callers run inside `tick`. `id_extra` keeps the two debounces from
/// sharing (and overwriting) one timer slot.
fn scheduleSaveWakeup(remaining_ns: i128, id_extra: usize) void {
    const remaining_us = @divTrunc(remaining_ns, std.time.ns_per_us);
    const clamped: i32 = if (remaining_us >= std.math.maxInt(i32))
        std.math.maxInt(i32)
    else
        @intCast(@max(1, remaining_us));
    dvui.timer(dvui.Id.extendId(null, @src(), id_extra), clamped);
}

/// Flush to disk regardless of idle/drawing deferral — used during shutdown only.
fn saveSettingsRaw(editor: *Editor) !void {
    const settings_path = try std.fs.path.join(fizzy.app.allocator, &.{ editor.config_folder, "settings.zon" });
    defer fizzy.app.allocator.free(settings_path);

    try editor.writeMergedSettings(settings_path);
    editor.settings_dirty = false;
}

/// Debounced `window.zon` ratio autosave — same shape/guards as `saveSettingsGuarded`, but
/// gated on `window_ratios_dirty` instead so a splitter drag never forces a settings.zon write.
fn saveWindowRatiosGuarded(editor: *Editor) void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    if (!editor.window_ratios_dirty) return;

    const now = fizzy.perf.nanoTimestamp();
    if (now < editor.window_ratios_save_deadline_ns) {
        scheduleSaveWakeup(editor.window_ratios_save_deadline_ns - now, 1);
        return;
    }

    if (editor.activelyDrawing())
        return;

    fizzy.backend.saveWindowRatios(editor.config_folder, editor.explorer_ratio, editor.panel_ratio);
    editor.window_ratios_dirty = false;
}

/// Flush to disk regardless of idle/drawing deferral — used during shutdown only.
fn saveWindowRatiosRaw(editor: *Editor) void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    fizzy.backend.saveWindowRatios(editor.config_folder, editor.explorer_ratio, editor.panel_ratio);
    editor.window_ratios_dirty = false;
}

const handle_size = 10;
const handle_dist = 60;

pub fn tick(editor: *Editor) !dvui.App.Result {
    editor.window_opacity = if (dvui.themeGet().dark) editor.settings.window_opacity_dark else editor.settings.window_opacity_light;

    // Ease the window background between translucent (windowed) and fully opaque
    // (maximized/fullscreen) so the vibrancy fades in/out across fullscreen
    // transitions rather than snapping. The draw uses `window_opacity_anim`.
    {
        const opaque_target: f32 = 1.0;
        const target: f32 = if (fizzy.backend.isMaximized(dvui.currentWindow())) opaque_target else editor.window_opacity;
        if (editor.window_opacity_anim < 0) {
            editor.window_opacity_anim = target;
        } else if (editor.window_opacity_anim != target) {
            const dt = dvui.secondsSinceLastFrame();
            const t = std.math.clamp(dt * 6.0, 0.0, 1.0);
            editor.window_opacity_anim += (target - editor.window_opacity_anim) * t;
            if (@abs(target - editor.window_opacity_anim) < 0.004) editor.window_opacity_anim = target;
            dvui.refresh(null, @src(), null);
        }
    }

    // Drain any "Save and Close" requests whose async save has settled.
    editor.tickPendingSaveCloses();

    // Complete any finished plugin downloads by loading them live. Done here, before the
    // Host-registry iterations below, so a newly-registered plugin never mutates a list
    // mid-iteration.
    PluginStore.tick();

    // Pick up any external edit to settings.zon (see R11 in docs/PLUGIN_MANIFEST_PLAN.md).
    // Cheap no-op unless the watcher thread actually saw a change.
    if (editor.settings_watcher) |*w| w.tick(editor);

    // Reload clean open docs / flag dirty conflicts when files change on disk.
    if (editor.document_watcher) |*w| w.tick(editor);

    var needs_save_status_anim_tick = false;
    for (editor.host.plugins.items) |plugin| {
        if (plugin.tickOpenDocuments()) needs_save_status_anim_tick = true;
    }
    // Re-poll the quit walker while saves are in flight on worker threads.
    if (editor.quit_saves_in_flight.count() > 0) editor.pending_quit_continue = true;
    if (editor.pending_quit_continue) {
        editor.pending_quit_continue = false;
        editor.advanceSaveAllQuit();
    }

    const wd = dvui.currentWindow().data();
    // Save spinner + finish animation are time-based; without input the loop would sleep and
    // frames would not advance (same pattern as `drawLoadingOverlay`).
    if (needs_save_status_anim_tick and dvui.timerDoneOrNone(wd.id)) {
        dvui.timer(wd.id, 16_000);
    }
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        if (!dvui.eventMatchSimple(e, wd)) continue;
        const want_quit = (e.evt == .window and e.evt.window.action == .close) or
            (e.evt == .app and e.evt.app.action == .quit);
        if (!want_quit) continue;

        var dirty_n: usize = 0;
        for (editor.open_files.values()) |doc| {
            if (doc.owner.isDirty(doc)) dirty_n += 1;
        }
        if (dirty_n == 0) continue;

        e.handle(@src(), wd);
        if (!Dialogs.AppQuitUnsaved.active(dvui.currentWindow()) and editor.quit_save_all_ids.items.len == 0) {
            Dialogs.AppQuitUnsaved.request();
        }
    }

    if (fizzy.backend.pollPendingAbout()) {
        // The app menu's "About fizzy" is AppKit's own item, so it has no model tag.
        editor.host.runCommand("fizzy.about") catch |err| {
            dvui.log.err("about command failed: {s}", .{@errorName(err)});
        };
    }
    if (fizzy.backend.pollPendingRecentFolder()) |i| {
        if (i < editor.recents.folders.items.len) {
            const folder = editor.recents.folders.items[i];
            editor.setProjectFolder(folder) catch |err| {
                dvui.log.err("open recent folder failed: {s}", .{@errorName(err)});
            };
        }
    }
    if (fizzy.backend.pollPendingNativeMenuAction()) |action| {
        editor.queueNativeMenuAction(action);
    }
    if (fizzy.backend.pollPendingGenericNativeMenuAction()) |idx| {
        editor.queueNativeMenuItem(idx);
    }
    // Native open/save dialog results complete asynchronously, outside Window.begin/end; run
    // their callbacks here (inside the frame) so callback code can safely touch dvui state.
    while (fizzy.backend.pollPendingDialogResult()) |result| {
        result.callback(result.files);
        if (result.files) |files| {
            for (files) |f| fizzy.app.allocator.free(f);
            fizzy.app.allocator.free(files);
        }
    }

    defer fizzy.dvui.modal_dim_titlebar = false;
    editor.setTitlebarColor();
    editor.setWindowStyle();

    syncLoadedPluginDvuiContexts(editor);
    for (editor.host.plugins.items) |plugin| plugin.beginFrame();
    if (fizzy.perf.record) fizzy.perf.beginFrame();
    defer if (fizzy.perf.record) fizzy.perf.endFrameAndMaybeLog();

    // Reap completed background file loads. Must run BEFORE `pending_composite_warmup` and any
    // workspace/file iteration so that a just-loaded file is visible to the rest of this frame.
    editor.processLoadingJobs();
    if (comptime builtin.target.cpu.arch == .wasm32) fizzy.backend.pollWebFileIo(editor);

    // Build workspaces AFTER reaping load jobs so a freshly-loaded file with a new grouping
    // (e.g. "Open to the side") gets its workspace created on the same frame it lands.
    // Otherwise the new pane only appears on the next frame, which won't happen until some
    // unrelated event (mouse move, key) wakes the loop.
    editor.rebuildWorkspaces() catch {
        dvui.log.err("Failed to rebuild workspaces", .{});
    };

    if (editor.pending_composite_warmup) {
        editor.pending_composite_warmup = false;
        for (editor.host.plugins.items) |plugin| plugin.prepareFrame();
    }

    {
        var any_drawing = false;
        fizzy.perf.draw_stroke_buf_count = 0;
        for (editor.host.plugins.items) |plugin| {
            if (plugin.needsContinuousRepaint()) any_drawing = true;
        }
        fizzy.perf.drawFrameBegin(any_drawing);
    }
    defer fizzy.perf.drawFrameEnd();

    // TODO: Does this need to be here for touchscreen zooming? Or does that belong in canvas?
    // var scaler = dvui.scale(
    //     @src(),
    //     .{ .scale = &dvui.currentWindow().content_scale, .pinch_zoom = .global },
    //     .{ .expand = .both },
    // );
    // defer scaler.deinit();

    {

        // First, window color is set to the opaque color.
        var window_color = dvui.themeGet().color(.content, .fill);

        switch (builtin.os.tag) {
            // `window_opacity_anim` eases between the windowed opacity and 1.0
            // (opaque) across fullscreen transitions; at 1.0 this is a no-op and
            // matches the old maximized branch exactly.
            .macos, .windows => {
                window_color = window_color.opacity(editor.window_opacity_anim).lighten((1.0 - editor.window_opacity_anim) * 4.0);
            },
            else => {},
        }

        var overall_box = dvui.box(
            @src(),
            .{ .dir = .vertical },
            .{
                .expand = .both,
                .background = true,
                .color_fill = window_color,
            },
        );
        defer overall_box.deinit();

        // Non-macOS: a thin strip below the top edge so the in-window title row (menu, etc.) is not flush
        // against the window border (complements the system caption area on Windows 11).
        if (builtin.os.tag != .macos) {
            var top_inset = dvui.box(
                @src(),
                .{ .dir = .horizontal },
                .{
                    .expand = .horizontal,
                    .background = false,
                    .min_size_content = .{ .w = 1, .h = Constants.titlebar_top_buffer },
                    .max_size_content = .{ .w = std.math.floatMax(f32), .h = Constants.titlebar_top_buffer },
                },
            );
            defer top_inset.deinit();
        }

        // Title bar handling:
        //  - macOS (not maximized): render an empty horizontal strip so AppKit's traffic lights have visual
        //    breathing room at the top-left. AppKit handles dragging natively.
        //  - Windows: the main UI (sidebar, menu) starts below `titlebar_top_buffer`. A floating overlay
        //    at the top-right corner (y=0) hosts the min/max/close buttons; a drag rect is pushed across the top so
        //    empty space (gaps between widgets) drags the window. Menu items and sidebar buttons push
        //    themselves as interactive rects so clicks on them still reach DVUI.
        if (builtin.os.tag == .windows) {
            fizzy.backend.resetTitleBarHints();

            const window_rect_natural = dvui.windowRect();
            const scale = dvui.windowNaturalScale();
            const title_strip_h = Constants.titlebar_top_buffer + Constants.titlebar_height;
            // Backend derives the drag strip's width live from GetClientRect; we only cache its height
            // and the client width as it stood this frame so right-anchored caption buttons survive
            // a one-frame staleness window after a resize.
            fizzy.backend.setTitleBarStrip(
                title_strip_h * scale,
                @intFromFloat(window_rect_natural.w * scale),
            );
        } else if (builtin.os.tag == .macos) {
            // Collapse while zoomed/fullscreen (chrome overlays on hover); grow with
            // AppKit safe-area inset when restoring to a normal window.
            const title_strip_h = fizzy.backend.titlebarStripHeight(dvui.currentWindow());
            if (title_strip_h > 0) {
                var titlebar_box = dvui.box(
                    @src(),
                    .{ .dir = .horizontal },
                    .{
                        .expand = .horizontal,
                        .background = false,
                        .min_size_content = .{ .w = 1, .h = title_strip_h },
                        .max_size_content = .{ .w = std.math.floatMax(f32), .h = title_strip_h },
                    },
                );
                defer titlebar_box.deinit();
            }
        }

        // Windows-only top-right overlay: minimize / maximize / close. Lives in a FloatingWidget
        // (a subwindow) so it doesn't take any space in the vertical overall_box layout — the main
        // UI below fills the entire window. Caption-button rects are pushed to the backend so
        // WM_NCHITTEST returns HTMINBUTTON/HTMAXBUTTON/HTCLOSE for them (snap-layouts + click).
        if (builtin.os.tag == .windows) {
            const button_w: f32 = 46;
            const button_h = Constants.titlebar_height;
            const overlay_w: f32 = button_w * 3;
            const win_rect = dvui.windowRect();

            var fw: dvui.FloatingWidget = undefined;
            fw.init(@src(), .{ .mouse_events = true }, .{
                .rect = .{ .x = win_rect.w - overlay_w, .y = 0, .w = overlay_w, .h = button_h },
            });
            defer fw.deinit();

            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
            defer row.deinit();

            const hovered = fizzy.backend.getHoveredTitleBarButton();
            const stroke = dvui.themeGet().color(.control, .text);
            const hover_fill = dvui.themeGet().color(.control, .fill_hover).lighten(if (dvui.themeGet().dark) 3 else -3);
            const close_hover_fill = dvui.Color{ .r = 232, .g = 17, .b = 35, .a = 255 };
            const close_hover_stroke = dvui.Color{ .r = 255, .g = 255, .b = 255, .a = 255 };

            // minimize
            {
                const is_hover = hovered == .minimize;
                var b = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .min_size_content = .{ .w = button_w, .h = button_h },
                    .expand = .vertical,
                    .background = is_hover,
                    .color_fill = hover_fill,
                });
                defer b.deinit();
                fizzy.backend.setTitleBarCaptionButtonRect(.minimize, b.data().rectScale().r);
                dvui.icon(@src(), "win_min", icons.tvg.feather.minus, .{ .stroke_color = stroke }, .{
                    .expand = .ratio,
                    .padding = .all(7),
                    .margin = .all(0),
                    .gravity_x = 0.5,
                });
            }
            // maximize / restore
            {
                const is_hover = hovered == .maximize;
                var b = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .min_size_content = .{ .w = button_w, .h = button_h },
                    .expand = .vertical,
                    .background = is_hover,
                    .color_fill = hover_fill,
                });
                defer b.deinit();
                fizzy.backend.setTitleBarCaptionButtonRect(.maximize, b.data().rectScale().r);
                dvui.icon(@src(), "win_max", icons.tvg.lucide.square, .{ .stroke_color = stroke }, .{
                    .expand = .ratio,
                    .padding = .all(9),
                    .margin = .all(0),
                    .gravity_x = 0.5,
                });
            }
            // close
            {
                const is_hover = hovered == .close;
                var b = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .min_size_content = .{ .w = button_w, .h = button_h },
                    .expand = .vertical,
                    .background = is_hover,
                    .color_fill = close_hover_fill.opacity(0.5),
                });
                defer b.deinit();
                fizzy.backend.setTitleBarCaptionButtonRect(.close, b.data().rectScale().r);
                dvui.icon(@src(), "win_close", icons.tvg.heroicons.outline.@"x-mark", .{
                    .stroke_color = if (is_hover) close_hover_stroke else stroke,
                }, .{
                    .expand = .ratio,
                    .padding = .all(5),
                    .margin = .all(0),
                    .gravity_x = 0.5,
                });
            }
        }

        var base_box = dvui.box(
            @src(),
            .{ .dir = .horizontal },
            .{
                .expand = .both,
            },
        );
        defer base_box.deinit();

        for (editor.host.plugins.items) |plugin| {
            plugin.tickActiveDocument(base_box.data().id);
        }

        // Always reset the peek layer index back, but we need to do this outside of the file widget so
        // other editor windows can use it
        defer for (editor.host.plugins.items) |plugin| plugin.endFrame();

        // Sidebar area
        // Since sidebar is drawn before the explorer, and we want to allow expanding the explorer
        // from clicking a sidebar option, we need to check if the sidebar was pressed. The
        // sidebar can't safely touch `editor.explorer.paned` itself — it runs before this
        // frame's paned widget is allocated below — so it reports an `Action` and we dispatch
        // after the paned is in place.
        const sidebar_action = editor.sidebar.draw() catch {
            dvui.log.err("Failed to draw sidebar", .{});
            return false;
        };

        var explorer_paned_box = dvui.box(
            @src(),
            .{ .dir = .vertical },
            .{
                .expand = .both,
                .background = false,
            },
        );
        defer explorer_paned_box.deinit();

        // Draw the infobar, but draw it at the bottom of the paned box (gravity_y = 1.0)
        {
            editor.infobar.draw() catch {
                dvui.log.err("Failed to draw infobar", .{});
            };
        }

        // Draw the explorer paned widget, which will recursively draw the workspaces in the second pane
        editor.explorer.paned = fizzy.dvui.paned(@src(), .{
            .direction = .horizontal,
            .collapsed_size = Constants.min_window_size[0] + 1,
            .handle_size = handle_size,
            .handle_dynamic = .{
                .handle_size_max = handle_size,
                .distance_max = handle_dist,
            },
            .uncollapse_ratio = fizzy.editor.explorer_ratio,
        }, .{
            .expand = .both,
            .background = false,
        });
        defer editor.explorer.paned.deinit();

        editor.flushQueuedNativeMenuActions();
        editor.flushQueuedNativeMenuItems();
        editor.processPendingSaveAs();

        if (dvui.firstFrame(editor.explorer.paned.wd.id)) {
            editor.explorer.paned.split_ratio.* = 0.0;

            // When the window is below the paned widget's collapse threshold (mobile / narrow
            // web viewport), start closed instead of animating open to the saved desktop ratio —
            // the user can sidebar-tap to peek the explorer in.
            const avail_w = editor.explorer.paned.wd.contentRect().w;
            const start_collapsed = avail_w < Constants.min_window_size[0];

            if (start_collapsed or fizzy.editor.explorer_ratio < 0.01) {
                editor.explorer.closed = true;
            } else {
                editor.explorer.paned.animateSplit(fizzy.editor.explorer_ratio, dvui.easing.outBack);
            }
        } else if (editor.explorer.paned.dragging) {
            editor.explorer_ratio = editor.explorer.paned.split_ratio.*;
            editor.markWindowRatiosDirty();
        }

        switch (sidebar_action) {
            .open => editor.explorer.open(),
            .close => editor.explorer.peekClose(),
            .none => {},
        }

        // Force continuous frames for a short grace window after every touch press.
        // `dvui.ContextWidget`'s hold-to-open check only re-runs while frames render,
        // and the engine otherwise settles after the press frame on idle touch
        // hardware — so without this, the hold timer freezes and the color-picker
        // context never opens. We do it at the editor level (rather than only inside
        // canvas) so it works even when no file is open or no canvas is interactive.
        {
            for (dvui.events()) |*e| {
                if (e.evt != .mouse) continue;
                const me = e.evt.mouse;
                switch (me.action) {
                    .press => if (me.button.touch()) {
                        editor.last_touch_press_ns = dvui.currentWindow().frame_time_ns;
                    },
                    .release => if (me.button.touch()) {
                        editor.last_touch_press_ns = null;
                    },
                    else => {},
                }
            }
            if (editor.last_touch_press_ns) |press_ns| {
                const now = dvui.currentWindow().frame_time_ns;
                const grace_ns: i128 = dvui.currentWindow().hold_menu_duration_ns + std.time.ns_per_ms * 100;
                if (now - press_ns < grace_ns) {
                    dvui.refresh(null, @src(), null);
                }
            }
        }

        if (editor.explorer.paned.showFirst()) {

            // Explorer area
            {
                const result = try editor.explorer.draw();
                if (result != .ok) {
                    return result;
                }
            }
        }

        if (editor.explorer.paned.showSecond()) {
            const bg_box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
            defer bg_box.deinit();

            // On macOS, the menu is handled natively, so we don't need to draw it here
            if (builtin.os.tag != .macos) {
                const result = try Menu.draw();
                if (result != .ok) {
                    return result;
                }
            }

            const workspace_vbox = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = false, .padding = .{ .w = handle_size } });
            defer workspace_vbox.deinit();

            if (editor.host.bottom_views.items.len > 0) {
                editor.panel.paned = fizzy.dvui.paned(@src(), .{
                    .direction = .vertical,
                    .collapsed_size = Constants.min_window_size[1] + 1,
                    .handle_size = handle_size,
                    .handle_dynamic = .{ .handle_size_max = handle_size, .distance_max = handle_dist },
                    .uncollapse_ratio = 1.0,
                }, .{
                    .expand = .both,
                    .background = false,
                });
                defer editor.panel.paned.deinit();

                if (!editor.panel.paned.dragging) {
                    const show_panel = editor.activeDoc() != null or editor.host.hasPersistentBottomView();
                    if (show_panel) {
                        if ((editor.panel.paned.split_ratio.* == 1.0 and !editor.panel.paned.collapsed()) and fizzy.editor.panel_ratio > 0.0) {
                            editor.panel.paned.animateSplit(1.0 - fizzy.editor.panel_ratio, dvui.easing.outQuint);
                        }
                    } else {
                        if (!editor.panel.paned.animating and editor.panel.paned.split_ratio.* < 1.0) {
                            editor.panel.paned.animateSplit(1.0, dvui.easing.outQuint);
                        }
                    }
                } else {
                    fizzy.editor.panel_ratio = 1.0 - editor.panel.paned.split_ratio.*;
                    fizzy.editor.markWindowRatiosDirty();
                }

                if (editor.panel.paned.showSecond()) {
                    const vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
                        .expand = .both,
                        .background = false,
                        .gravity_y = 0.0,
                    });
                    defer vbox.deinit();

                    const result = try editor.panel.draw();
                    if (result != .ok) {
                        return result;
                    }
                }

                if (editor.panel.paned.showFirst()) {
                    if (editor.host.activeCenter()) |center| {
                        const result = try center.draw(center.ctx);
                        if (result != .ok) {
                            return result;
                        }
                    }
                }
            } else if (editor.host.activeCenter()) |center| {
                const result = try center.draw(center.ctx);
                if (result != .ok) {
                    return result;
                }
            }
        } else {
            // Explorer peek/collapse hides the workspace subtree, so `drawWorkspaces` does not
            // run and `workspace.center` would otherwise stay latched from a prior panel animation.
            editor.clearAllWorkspaceCenter();
        }

        { // Plugin keybinds + per-frame overlays (e.g. pixel-art's radial menu)
            // While the palette owns the keyboard, plugin ticks must not run — otherwise a
            // plugin's `matchBind` (e.g. pixi Export on the same chord as Quick Open) steals
            // focus before the palette entry can claim it.
            // Recording a chord in settings blocks these for the same reason the palette does:
            // the keys are being captured, not invoked.
            if (!editor.command_palette.open and !KeybindSettings.isRecording()) {
                for (editor.host.plugins.items) |plugin| {
                    plugin.tickKeybinds() catch |err| {
                        dvui.log.err("Plugin keybind tick failed: {s}", .{@errorName(err)});
                    };
                }
            }
            Keybinds.tick() catch {
                dvui.log.err("Failed to tick hotkeys", .{});
            };

            for (editor.host.plugins.items) |plugin| {
                plugin.drawOverlay() catch |err| {
                    dvui.log.err("Plugin overlay draw failed: {s}", .{@errorName(err)});
                };
            }

            editor.command_palette.draw(editor);
        }

        // Arms the launch update toast once the background check reports a newer
        // version, then renders it in a custom rect anchored just above the infobar.
        // (We use a non-null subwindow_id on the toast so DVUI's default `toastsShow`
        // in Window.end skips it — see `update_notify.drawAbove`.)
        update_notify.tick();
        if (Infobar.last_top_y_physical) |infobar_y_physical| {
            // Bottom-flush against the infobar's top edge. `last_top_y_physical`
            // is in screen-space pixels so it matches FloatingWidget's `from`
            // coordinate system; `drawAbove` self-sizes the pill so the bottom
            // sits exactly at this y.
            update_notify.drawAbove(infobar_y_physical, 4.0);
        }
    }

    // look at demo() for examples of dvui widgets, shows in a floating window
    dvui.Examples.demo(.full);

    // Render a centered loading overlay for any background file-load job that has been
    // running long enough to warrant UI feedback. Small files complete before the threshold
    // and never flash this. Non-modal — user can keep working in other tabs while loading.
    editor.drawLoadingOverlay();
    // Render any save-complete toasts in the same centered, content-fill-styled card system.
    // The dvui toast queue holds them with a 2.5s timeout; each toast's display function fades
    // out and removes itself when the timer expires.
    editor.drawSaveToasts();

    // Every widget has drawn by now, so this is the frame's final answer about who holds
    // keyboard focus. Read next frame by the clipboard commands.
    editor.text_input_focused = dvui.currentWindow().textInputRequested() != null;

    editor.saveSettingsGuarded() catch |err| {
        dvui.log.err("Failed to autosave settings ({s})", .{@errorName(err)});
    };
    editor.saveWindowRatiosGuarded();

    _ = editor.arena.reset(.retain_capacity);

    if (editor.pending_app_close) {
        editor.pending_app_close = false;
        return .close;
    }

    return .ok;
}

fn queueNativeMenuAction(editor: *Editor, action: usize) void {
    if (editor.pending_native_menu_actions_len >= editor.pending_native_menu_actions.len) {
        // If we ever overflow, drop the action rather than crashing.
        return;
    }
    editor.pending_native_menu_actions[editor.pending_native_menu_actions_len] = action;
    editor.pending_native_menu_actions_len += 1;
}

fn flushQueuedNativeMenuActions(editor: *Editor) void {
    if (editor.pending_native_menu_actions_len == 0) return;
    const len: usize = editor.pending_native_menu_actions_len;
    editor.pending_native_menu_actions_len = 0;

    var i: usize = 0;
    while (i < len) : (i += 1) {
        editor.handleNativeMenuAction(editor.pending_native_menu_actions[i]) catch |err| {
            dvui.log.err("Native menu action failed: {any}", .{err});
        };
    }
}

fn queueNativeMenuItem(editor: *Editor, idx: usize) void {
    if (editor.pending_native_menu_item_indices_len >= editor.pending_native_menu_item_indices.len) {
        // If we ever overflow, drop the action rather than crashing.
        return;
    }
    editor.pending_native_menu_item_indices[editor.pending_native_menu_item_indices_len] = idx;
    editor.pending_native_menu_item_indices_len += 1;
}

/// Runs plugin-registered `NativeMenuItem`s chosen from the real macOS menu bar. `idx` is
/// resolved against the *current* `host.native_menu_items` — safe because a menu click and
/// this flush both happen on the main thread with no plugin load/unload in between.
fn flushQueuedNativeMenuItems(editor: *Editor) void {
    if (editor.pending_native_menu_item_indices_len == 0) return;
    const len: usize = editor.pending_native_menu_item_indices_len;
    editor.pending_native_menu_item_indices_len = 0;

    var i: usize = 0;
    while (i < len) : (i += 1) {
        const idx = editor.pending_native_menu_item_indices[i];
        if (idx >= editor.host.native_menu_items.items.len) continue;
        const item = &editor.host.native_menu_items.items[idx];
        item.run(item.ctx) catch |err| {
            dvui.log.err("Native menu item '{s}' failed: {any}", .{ item.id, err });
        };
    }
}

/// Run the command a menu-bar item stands for.
///
/// This used to be a switch that reimplemented every action a third time (`Menu.zig` had its
/// own inline copy, `Keybinds` had the command body), and the copies had drifted — the menu-bar
/// Open Folder went through `fizzy.backend` while the command went straight to
/// `dvui.dialogNative*`, which no-ops on web. The item now names a command and nothing else.
pub fn handleNativeMenuAction(editor: *Editor, tag: usize) !void {
    const item = menu_model.byTag(tag) orelse {
        dvui.log.err("native menu tag {d} is not a model item", .{tag});
        return;
    };
    const id = item.id;
    editor.host.runCommand(id) catch |err| {
        dvui.log.err("native menu command '{s}' failed: {s}", .{ id, @errorName(err) });
    };
}

pub fn setTitlebarColor(editor: *Editor) void {
    const color = if (fizzy.dvui.modal_dim_titlebar) dvui.themeGet().color(.control, .fill).lerp(.black, if (dvui.themeGet().dark) 60.0 / 255.0 else 80.0 / 255.0) else dvui.themeGet().color(.control, .fill);

    if (!std.mem.eql(u8, &editor.last_titlebar_color.toRGBA(), &color.toRGBA())) {
        editor.last_titlebar_color = color;
        fizzy.backend.setTitlebarColor(dvui.currentWindow(), color.opacity(if (dvui.themeGet().dark) editor.settings.window_opacity_dark else editor.settings.window_opacity_light));
    }
}

pub fn setWindowStyle(_: *Editor) void {
    fizzy.backend.setWindowStyle(dvui.currentWindow());
}

pub fn rebuildWorkspaces(editor: *Editor) !void {
    try editor.workbench.rebuildWorkspaces();
}

pub fn drawWorkspaces(editor: *Editor, index: usize) !dvui.App.Result {
    var full_split: f32 = 1.0;
    var dragging = false;
    var animating = false;
    var split_ratio: *f32 = &full_split;

    if (editor.host.bottom_views.items.len > 0) {
        const panel = editor.panel.paned;
        dragging = panel.dragging;
        animating = panel.animating;
        split_ratio = panel.split_ratio;
    }

    return editor.workbench.drawWorkspaces(.{
        .dragging = dragging,
        .animating = animating,
        .split_ratio = split_ratio,
    }, index);
}

pub fn abortSaveAllQuit(editor: *Editor) void {
    editor.quit_save_all_ids.clearAndFree(fizzy.app.allocator);
    editor.quit_saves_in_flight.clearRetainingCapacity();
    editor.quit_in_progress = false;
    editor.pending_close_file_id = null;
    editor.pending_quit_continue = false;
}

/// Close any file whose "save and close" save has finished. Called once per frame
/// at the top of `tick`. Files for which `saveAsync` didn't actually start a worker
/// (e.g. unrecognized extension) are dropped without close — the dialog flow handles
/// those via the Save As path. `quit_saves_in_flight` is drained by `advanceSaveAllQuit`.
///
/// Iteration note: `swapRemove` invalidates a captured `.keys()` slice (moves the
/// last entry into the removed slot, shrinks length). Re-fetch the keys slice every
/// iteration and use `count()` as the bound — otherwise we read stale memory and the
/// loop never terminates, hanging the GUI thread.
fn tickPendingSaveCloses(editor: *Editor) void {
    var i: usize = 0;
    while (i < editor.pending_close_after_save.count()) {
        const id = editor.pending_close_after_save.keys()[i];
        if (editor.docById(id)) |doc| {
            if (doc.owner.isDocumentSaving(doc)) {
                i += 1;
                continue;
            }
            editor.rawCloseFileID(id) catch |err| {
                dvui.log.err("Post-save close failed: {s}", .{@errorName(err)});
            };
        }
        // File gone (already closed elsewhere) or successfully closed: drop the
        // entry. Leave `i` where it is — the swapped-in entry needs checking next.
        _ = editor.pending_close_after_save.swapRemove(id);
    }
    // Worker threads also call `dvui.refresh(...)` from their completion defer to
    // wake the wait loop when no UI input is happening — between the two, the
    // walker reliably catches a save completion within one frame.
}

/// Kick off async saves for as many queued files as possible, then drain the
/// in-flight set as workers finish. Called on the first quit frame
/// (`pending_quit_continue`) AND every frame afterwards while there is work left.
/// .fizzy saves run in parallel on worker threads. PNG/JPG saves still block the
/// GUI thread (they hit the GPU) — those are done one per call so the UI can paint
/// between them.
pub fn advanceSaveAllQuit(editor: *Editor) void {
    if (editor.quit_save_all_ids.items.len == 0 and editor.quit_saves_in_flight.count() == 0) return;

    // Pass 1: kick off any queued saves we haven't started yet.
    while (editor.quit_save_all_ids.items.len > 0) {
        const id = editor.quit_save_all_ids.items[0];
        const doc = editor.docById(id) orelse {
            _ = editor.quit_save_all_ids.swapRemove(0);
            continue;
        };
        if (!doc.owner.isDirty(doc)) {
            _ = editor.quit_save_all_ids.swapRemove(0);
            continue;
        }

        if (!doc.owner.documentHasRecognizedSaveExtension(doc)) {
            // Save As dialog needs a single active file — bail out of the parallel
            // kickoff for this one and let the existing Save As + pending_close_file_id
            // flow handle it. Next frame, pending_quit_continue will re-enter us.
            if (editor.open_files.getIndex(id)) |idx| editor.setActiveFile(idx);
            editor.pending_close_file_id = id;
            editor.quit_in_progress = true;
            editor.requestSaveAs();
            return;
        }
        if (doc.owner.saveNeedsConfirmation(doc)) {
            // Flat-raster prompt is a modal dialog — same reason as Save As, do
            // it serially and rejoin afterwards.
            if (editor.open_files.getIndex(id)) |idx| editor.setActiveFile(idx);
            doc.owner.requestSaveConfirmation(doc, .save_and_close, true);
            return;
        }
        if (editor.document_watcher) |*w| {
            if (w.hasDiskConflict(id)) {
                // Same serial treatment as Save As / flat-raster confirm.
                if (editor.open_files.getIndex(id)) |idx| editor.setActiveFile(idx);
                Dialogs.FileChangedOnDisk.request(id);
                return;
            }
            w.markPendingBaseline(id);
        }

        // Async-safe path: kick off, move to in-flight, drop from queue.
        doc.owner.saveDocumentAsync(doc) catch |err| {
            dvui.log.err("Save all quit kickoff: {s}", .{@errorName(err)});
            editor.abortSaveAllQuit();
            return;
        };
        editor.quit_saves_in_flight.put(fizzy.app.allocator, id, {}) catch |err| {
            dvui.log.err("Save all quit track: {s}", .{@errorName(err)});
            editor.abortSaveAllQuit();
            return;
        };
        _ = editor.quit_save_all_ids.swapRemove(0);
    }

    // Pass 2: drain completed in-flight saves. Same iteration pattern as
    // `tickPendingSaveCloses` — re-fetch keys each iteration since swapRemove
    // invalidates a previously-captured slice.
    {
        var i: usize = 0;
        while (i < editor.quit_saves_in_flight.count()) {
            const id = editor.quit_saves_in_flight.keys()[i];
            if (editor.docById(id)) |doc| {
                if (doc.owner.isDocumentSaving(doc)) {
                    i += 1;
                    continue;
                }
                editor.rawCloseFileID(id) catch |err| {
                    dvui.log.err("Save all quit close: {s}", .{@errorName(err)});
                };
            }
            _ = editor.quit_saves_in_flight.swapRemove(id);
        }
    }

    if (editor.quit_save_all_ids.items.len == 0 and editor.quit_saves_in_flight.count() == 0) {
        editor.quit_in_progress = false;
        editor.pending_app_close = true;
    }
    // No re-arming refresh here on purpose — the worker threads themselves call
    // `dvui.refresh(window, ...)` from their completion defer (see
    // `File.saveZipFromSnapshot`). Spinning a polling loop on the GUI thread
    // starves the workers for CPU and serializes contention on `dvui.toastAdd`,
    // which one worker reaches before the GUI's wakeup yields.
}

pub fn close(app: *App, editor: *Editor) void {
    _ = app;
    if (editor.open_files.count() == 0) {
        editor.pending_app_close = true;
        return;
    }
    var dirty_n: usize = 0;
    for (editor.open_files.values()) |doc| {
        if (doc.owner.isDirty(doc)) dirty_n += 1;
    }
    if (dirty_n > 0) {
        Dialogs.AppQuitUnsaved.request();
    } else {
        editor.pending_app_close = true;
    }
}

/// The single choke point every folder open funnels through (CLI argv, menus, recents, the
/// SDK's `Host.setProjectFolder`), so `path` is canonicalized here once — plugins, recents and
/// anything deriving a key from `editor.folder` (a language server's `rootUri`, notably) then
/// can't disagree about how the same directory is spelled. See `fizzy.paths.normalize`.
pub fn setProjectFolder(editor: *Editor, path_in: []const u8) !void {
    const path = try fizzy.paths.normalize(fizzy.app.allocator, path_in);
    defer fizzy.app.allocator.free(path);

    if (editor.folder) |folder| {
        editor.ignore.deinit(fizzy.app.allocator);
        for (editor.host.plugins.items) |plugin| plugin.onFolderClose();
        fizzy.app.allocator.free(folder);
    }
    editor.folder = try fizzy.app.allocator.dupe(u8, path);
    editor.command_palette.invalidate();
    try editor.recents.appendFolder(try fizzy.app.allocator.dupe(u8, path));
    // The dvui menu re-reads recents every frame; the macOS submenu is retained state.
    fizzy.backend.rebuildNativeRecentFolders();
    if (editor.host.firstVisibleSidebarView()) |view| {
        editor.host.setActiveSidebarView(view.id);
    }

    for (editor.host.plugins.items) |plugin| plugin.onFolderOpen(fizzy.app.allocator);
    editor.ignore = try IgnoreRules.load(fizzy.app.allocator, path);
}

pub fn closeProjectFolder(editor: *Editor) void {
    if (editor.folder) |folder| {
        editor.ignore.deinit(fizzy.app.allocator);
        for (editor.host.plugins.items) |plugin| plugin.onFolderClose();
        fizzy.app.allocator.free(folder);
        editor.folder = null;
    }
}

pub fn saving(editor: *Editor) bool {
    for (editor.open_files.values()) |doc| {
        if (doc.owner.isDocumentSaving(doc)) return true;
    }
    return false;
}

/// Returns true if a new file was opened.
/// The editor doesn't care what type of file is being opened,
/// File.fromPath will handle the file type
/// Open `path` if needed, set its grouping, focus it, and return its index in `open_files`.
/// If the file at `path` is already open, reassigns its grouping and returns its `open_files`
/// index. If it's not open, queues an async load with `grouping` as the target and returns
/// `null` — callers must NOT treat that case as if the file is already present, since the
/// worker hasn't landed it yet and there is no valid `open_files` index to act on. The async
/// load will auto-focus once the worker completes (see `processLoadingJobs`).
pub fn openOrFocusFileAtGrouping(editor: *Editor, path: []const u8, grouping: u64) !?usize {
    if (editor.docFromPath(path)) |doc| {
        const idx = editor.open_files.getIndex(doc.id) orelse return error.Unexpected;
        editor.setDocGrouping(doc, grouping);
        editor.setActiveFile(idx);
        return idx;
    }
    _ = try editor.openFilePath(path, grouping);
    return null;
}

/// After a workspace drop from the Files tree or when `tab_drag` ends; frees path and clears tree reorder stash.
pub fn clearFileTreeTabDragDropState(editor: *Editor) void {
    editor.workbench.clearFileTreeTabDragDropState();
    if (editor.workbench.file_tree_data_id) |id| {
        dvui.dataRemove(null, id, "removed_path");
    }
    // `file_tree_data_id` is reassigned each `drawFiles` frame; do not clear the id here so
    // multiple workspace `processTabDrag` calls in one frame do not race.
}

/// Choke point for every file open (CLI argv, file tree, palette, drag-drop, SDK
/// `Host.openFilePath`). Canonicalizes `path_in` once so `loading_jobs`, the document's stored
/// path, and later `docFromPath` lookups all agree — otherwise `foo/./bar.zig` and `foo/bar.zig`
/// would open as two documents. See `fizzy.paths.normalize`.
pub fn openFilePath(editor: *Editor, path_in: []const u8, grouping: u64) !bool {
    const path = try fizzy.paths.normalize(fizzy.app.allocator, path_in);
    defer fizzy.app.allocator.free(path);

    // Already open? Just focus it. (`docFromPath` also collapses lexical variants, so a doc
    // opened under a pre-normalization spelling is still found.)
    if (editor.docFromPath(path)) |doc| {
        if (editor.open_files.getIndex(doc.id)) |i| {
            editor.setActiveFile(i);
        }
        return false;
    }

    // Already loading? Mark this as the most-recent request so it gets focused on completion.
    // Jobs always key on the canonical path (see `FileLoadJob.create` below), so a second open
    // with a `.`-suffixed spelling collapses onto the in-flight one rather than spawning two.
    if (editor.loading_jobs.getKey(path)) |existing_key| {
        editor.last_load_request_path = existing_key;
        return false;
    }

    // Resolve the owning plugin from the file-type registry before spawning. No owner
    // means no plugin claims this extension — reject here rather than spawning a worker
    // that would only fail with InvalidFile.
    const owner = editor.host.pluginForExtension(std.fs.path.extension(path)) orelse {
        dvui.log.warn("No plugin handles file: {s}", .{path});
        return false;
    };

    // Spawn a worker. The job owns the (already canonical) path string we'll key the map by.
    const io = dvui.io;
    const job = try FileLoadJob.create(fizzy.app.allocator, path, owner, grouping);
    errdefer job.destroy(io);

    try editor.loading_jobs.put(fizzy.app.allocator, job.path, job);
    editor.last_load_request_path = job.path;

    if (comptime builtin.target.cpu.arch == .wasm32) {
        // Wasm has no Io.concurrent worker pool. File-open from a wasm-reachable path needs
        // a synchronous load (the file picker hands us bytes inline). Not yet
        // implemented — drop the job here and report unsupported.
        _ = editor.loading_jobs.remove(job.path);
        job.destroy(io);
        dvui.log.warn("Async file load not yet supported on web", .{});
        return false;
    }
    // `Io.concurrent`, not a raw `std.Thread.spawn` + `.detach()`: dispatches onto
    // `Io.Threaded`'s pooled workers (opening many files at once — a project-wide search
    // result, a multi-file drag-drop — no longer means one fresh OS thread each), and the
    // returned `Future` gives `cancelPluginLoadingJobs`/`destroy` a proper futex-based wait
    // instead of the `std.Thread.yield()` busy-spin this replaced.
    job.future = io.concurrent(FileLoadJob.workerMain, .{job}) catch |err| {
        _ = editor.loading_jobs.remove(job.path);
        job.destroy(io);
        return err;
    };

    return true;
}

/// Synchronous open from browser file-picker bytes. Takes ownership of `path_in` and registers
/// the document under its canonical spelling (same contract as `openFilePath`). Returns its id.
pub fn openFileFromBytes(editor: *Editor, path_in: []u8, bytes: []const u8, grouping: u64) !u64 {
    const path = blk: {
        defer fizzy.app.allocator.free(path_in);
        break :blk try fizzy.paths.normalize(fizzy.app.allocator, path_in);
    };

    // Freed on every exit path below except the success transfer into the plugin document
    // (loaders dupe `path`). Cleared to null after that free so a later `errdefer` can't
    // double-free if `insertOpenDoc` fails.
    var path_owned: ?[]u8 = path;
    errdefer if (path_owned) |p| fizzy.app.allocator.free(p);

    if (editor.docFromPath(path)) |existing| {
        if (editor.open_files.getIndex(existing.id)) |idx| {
            editor.setActiveFile(idx);
        }
        return error.AlreadyOpen;
    }

    const owner = editor.host.pluginForExtension(std.fs.path.extension(path)) orelse {
        return error.InvalidExtension;
    };

    const staging = try owner.allocDocumentBuffer(fizzy.app.allocator);
    defer fizzy.app.allocator.free(staging.backing);

    const handled = try owner.loadDocumentFromBytes(path, bytes, staging.buf.ptr);
    if (!handled) return error.InvalidFile;

    fizzy.app.allocator.free(path);
    path_owned = null;

    owner.setDocumentGroupingOnBuffer(staging.buf.ptr, grouping);
    const id = owner.documentIdFromBuffer(staging.buf.ptr);
    try editor.insertOpenDoc(staging.buf.ptr, owner, id);
    return id;
}

/// Per-frame sweep called from `tick`. Moves completed load jobs into `open_files`, cleans up
/// failed/cancelled jobs, and focuses the most-recently-requested file as it completes.
pub fn processLoadingJobs(editor: *Editor) void {
    if (editor.loading_jobs.count() == 0) return;
    const io = dvui.io;

    // Snapshot the job pointers because we'll be mutating the map during iteration.
    var to_remove: std.ArrayListUnmanaged(*FileLoadJob) = .empty;
    defer to_remove.deinit(fizzy.app.allocator);

    var it = editor.loading_jobs.valueIterator();
    while (it.next()) |job_ptr| {
        const job = job_ptr.*;
        if (!job.done.load(.acquire)) continue;
        to_remove.append(fizzy.app.allocator, job) catch continue;
    }

    for (to_remove.items) |job| {
        _ = editor.loading_jobs.remove(job.path);

        const phase = job.currentPhase();
        switch (phase) {
            .ready => {
                const owner = job.owner;
                owner.setDocumentGroupingOnBuffer(job.doc_buf.ptr, job.target_grouping);
                const id = owner.documentIdFromBuffer(job.doc_buf.ptr);

                editor.insertOpenDoc(job.doc_buf.ptr, owner, id) catch {
                    dvui.log.err("Failed to insert loaded file into open_files: {s}", .{job.path});
                    owner.deinitDocumentBuffer(job.doc_buf.ptr);
                    job.destroy(io);
                    continue;
                };

                const should_focus = editor.last_load_request_path != null and
                    std.mem.eql(u8, editor.last_load_request_path.?, job.path);
                if (should_focus) {
                    if (editor.open_files.getIndex(id)) |idx| {
                        editor.setActiveFile(idx);
                        editor.last_load_request_path = null;
                    }
                    editor.pending_composite_warmup = true;
                }
            },
            .failed => {
                dvui.log.err("Failed to open file: {s} ({any})", .{ job.path, job.err });
                job.owner.deinitDocumentBuffer(job.doc_buf.ptr);
            },
            .cancelled => {
                job.owner.deinitDocumentBuffer(job.doc_buf.ptr);
            },
            else => {
                dvui.log.err("Load job finished in unexpected phase {s}: {s}", .{ @tagName(phase), job.path });
            },
        }

        job.destroy(io);
    }
}

pub fn activeWorkspaceCanvasRectPhysical(editor: *Editor) ?dvui.Rect.Physical {
    return editor.workbench.activeWorkspaceCanvasRectPhysical();
}

/// Cancel every in-flight load. Workers exit at the next cancellation checkpoint (after
/// `fromPath` returns) and discard their results. Used on app quit.
pub fn cancelAllLoadingJobs(editor: *Editor) void {
    var it = editor.loading_jobs.valueIterator();
    while (it.next()) |job_ptr| {
        job_ptr.*.cancelled.store(true, .monotonic);
    }
}

/// Iterates the save-complete toast subwindow (`fizzy.dvui.save_toast_subwindow_id`) and
/// renders each toast inside a self-sized floating column anchored to the bottom-center of
/// the viewport, so back-to-back saves stack vertically rather than overlapping. Each toast's
/// display function (`saveCompleteToastDisplay`) builds its own card body + fade-out animator
/// + self-remove on timer expiry.
pub fn drawSaveToasts(editor: *Editor) void {
    if (dvui.toastsFor(fizzy.dvui.save_toast_subwindow_id) == null) return;

    // Anchor at the center of the active workspace's canvas rect (in physical pixels). Using
    // `from` + `from_gravity = 0.5,0.5` lets the FloatingWidget self-size to the toast column
    // and centers it around the anchor. Falls back to the window center if no workspace has
    // rendered yet.
    const anchor_physical: dvui.Point.Physical = if (editor.activeWorkspaceCanvasRectPhysical()) |r| .{
        .x = r.x + r.w * 0.5,
        .y = r.y + r.h * 0.5,
    } else blk: {
        const win_pix = dvui.windowRectPixels();
        break :blk .{
            .x = win_pix.x + win_pix.w * 0.5,
            .y = win_pix.y + win_pix.h * 0.5,
        };
    };

    var fw: dvui.FloatingWidget = undefined;
    fw.init(@src(), .{
        .mouse_events = false,
        .from = anchor_physical,
        .from_gravity_x = 0.5,
        .from_gravity_y = 0.5,
    }, .{});
    defer fw.deinit();

    var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .none });
    defer col.deinit();

    var it = dvui.toastsFor(fizzy.dvui.save_toast_subwindow_id) orelse return;
    while (it.next()) |t| {
        t.display(t.id) catch |err| {
            dvui.log.err("save toast display: {any}", .{err});
        };
    }
}

/// Centered floating card listing in-flight file loads that have been running long enough to
/// warrant UI feedback. Non-modal: the user can keep interacting with the rest of the editor.
/// Called once per frame from `tick`.
pub fn drawLoadingOverlay(editor: *Editor) void {
    if (editor.loading_jobs.count() == 0) return;

    // Skip jobs that completed in under `toast_threshold_ms` to avoid flashing the UI for
    // small files. If every in-flight job is still under the threshold, render nothing.
    const toast_threshold_ms: i64 = 150;
    var visible_count: usize = 0;
    var earliest_pending_start_ns: ?i128 = null;
    var it_count = editor.loading_jobs.valueIterator();
    while (it_count.next()) |job_ptr| {
        if (job_ptr.*.elapsedExceeds(toast_threshold_ms)) {
            visible_count += 1;
        } else {
            const start = job_ptr.*.started_at_ns;
            if (earliest_pending_start_ns == null or start < earliest_pending_start_ns.?) {
                earliest_pending_start_ns = start;
            }
        }
    }
    // If we have pending jobs that haven't crossed the threshold yet, the app would otherwise
    // sleep on the click event that started them and the overlay would never appear until some
    // unrelated input (mouse move, etc.) ticks a frame. Schedule a wakeup at the threshold
    // boundary so the overlay shows on time even with the cursor parked.
    if (earliest_pending_start_ns) |start_ns| {
        const elapsed_ms = @divTrunc(fizzy.perf.nanoTimestamp() - start_ns, std.time.ns_per_ms);
        const remaining_ms: i64 = toast_threshold_ms - @as(i64, @intCast(elapsed_ms));
        if (remaining_ms > 0) {
            dvui.timer(dvui.currentWindow().data().id, @intCast(remaining_ms * std.time.us_per_ms));
        } else {
            dvui.refresh(null, @src(), dvui.currentWindow().data().id);
        }
    }
    if (visible_count == 0) return;

    // Prefer centering over the active workspace's canvas rect so the toast appears where the
    // user is looking. Fall back to the OS window rect on the very first frame before any
    // workspace has drawn, or if there's no active workspace (e.g., empty app state).
    //
    // Single-line rows keep multi-file loads compact: spinner + "<basename> — <phase>…" on one
    // baseline. `row_h` is the natural-pixel height each row contributes to the card; the
    // header band adds a fixed amount on top.
    const card_w: f32 = 320;
    const row_h: f32 = 26;
    const header_h: f32 = 32;
    const card_h: f32 = header_h + @as(f32, @floatFromInt(visible_count)) * row_h;
    const card_rect: dvui.Rect = blk: {
        if (editor.activeWorkspaceCanvasRectPhysical()) |rs_phys| {
            const rs_natural = rs_phys.toNatural();
            break :blk .{
                .x = rs_natural.x + (rs_natural.w - card_w) * 0.5,
                .y = rs_natural.y + (rs_natural.h - card_h) * 0.5,
                .w = card_w,
                .h = card_h,
            };
        }
        const window_rect = dvui.windowRect();
        break :blk .{
            .x = (window_rect.w - card_w) * 0.5,
            .y = (window_rect.h - card_h) * 0.5,
            .w = card_w,
            .h = card_h,
        };
    };

    var fw: dvui.FloatingWidget = undefined;
    fw.init(@src(), .{ .mouse_events = false }, .{
        .rect = card_rect,
        .background = true,
        // Content-fill @ 0.85 matches the look of the other dialog-style popups in the editor.
        .color_fill = dvui.themeGet().color(.content, .fill).opacity(0.85),
        .corners = dvui.CornerRect.all(8),
        .box_shadow = .{
            .color = .black,
            .offset = .{ .x = -2.0, .y = 2.0 },
            .fade = 12.0,
            .alpha = 0.35,
            .corners = dvui.CornerRect.all(8),
        },
    });
    defer fw.deinit();

    var outer = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
    });
    defer outer.deinit();

    dvui.labelNoFmt(@src(), "Loading…", .{}, .{
        .font = dvui.Font.theme(.heading),
        .color_text = dvui.themeGet().color(.content, .text),
        .padding = .{ .h = 2 },
    });

    var key_it = editor.loading_jobs.iterator();
    var entry_idx: usize = 0;
    while (key_it.next()) |entry| : (entry_idx += 1) {
        const job = entry.value_ptr.*;
        if (!job.elapsedExceeds(toast_threshold_ms)) continue;

        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = entry_idx,
            .expand = .horizontal,
            .padding = .{ .y = 1, .h = 1 },
        });
        defer row.deinit();

        // Single-line layout: small bubble spinner + "<basename> — <phase>…" on one baseline.
        // Keeps multi-file load lists compact (each row ~26 nat-px tall) while still showing
        // both the file identity and what's currently happening to it.
        fizzy.dvui.bubbleSpinner(@src(), .{
            .min_size_content = .{ .w = 18, .h = 18 },
            .gravity_y = 0.5,
            .color_text = dvui.themeGet().color(.content, .text),
            .padding = .{ .w = 8 },
        }, .{});

        const basename = std.fs.path.basename(job.path);
        const phase = job.currentPhase();
        dvui.label(@src(), "{s} — {s}…", .{ basename, FileLoadJob.phaseLabel(phase) }, .{
            .expand = .horizontal,
            .gravity_y = 0.5,
            .color_text = dvui.themeGet().color(.content, .text),
        });
    }
}

pub fn requestPrepareFrame(editor: *Editor) void {
    editor.pending_composite_warmup = true;
}

pub fn newFile(editor: *Editor, path: []const u8, grid: sdk.EditorAPI.NewDocGrid) !sdk.DocHandle {
    if (editor.docFromPath(path) != null) {
        return error.FileAlreadyExists;
    }

    // Prefer the plugin whose own "new document" dialog is pending (see
    // `Host.pending_new_document_owner`) over the generic first-match lookup — otherwise,
    // now that more than one plugin can implement `createDocument`, a dialog's own "OK"
    // handler calling the shared `host.createDocument` could hand the document to the
    // wrong plugin.
    const pending_owner = editor.host.pending_new_document_owner;
    editor.host.pending_new_document_owner = null;
    const owner = pending_owner orelse editor.host.pluginWithCreateDocument() orelse return error.NoEditorPlugin;
    const staging = try owner.allocDocumentBuffer(fizzy.app.allocator);
    defer fizzy.app.allocator.free(staging.backing);

    owner.createDocument(path, grid, staging.buf.ptr) catch {
        owner.deinitDocumentBuffer(staging.buf.ptr);
        dvui.log.err("Failed to create file: {s}", .{path});
        return error.FailedToCreateFile;
    };

    const id = owner.documentIdFromBuffer(staging.buf.ptr);
    try editor.insertOpenDoc(staging.buf.ptr, owner, id);
    editor.setActiveFile(editor.open_files.count() - 1);
    editor.pending_composite_warmup = true;

    return editor.docById(id) orelse return error.FailedToCreateFile;
}

/// Heap-owned path like `untitled-1`, unique among open-document basenames.
pub fn allocNextUntitledPath(editor: *Editor) ![]u8 {
    var max_n: u32 = 0;
    for (editor.open_files.values()) |doc| {
        const base = std.fs.path.basename(editor.docPath(doc));
        if (std.mem.startsWith(u8, base, "untitled-")) {
            const suffix = base["untitled-".len..];
            const n = std.fmt.parseUnsigned(u32, suffix, 10) catch continue;
            max_n = @max(max_n, n);
        } else if (std.mem.eql(u8, base, "untitled")) {
            max_n = @max(max_n, 1);
        }
    }
    return std.fmt.allocPrint(fizzy.app.allocator, "untitled-{d}", .{max_n + 1});
}

/// Opens the New File dialog via the plugin that provides one (dispatched by `Host`); on confirm
/// the owner creates an in-memory `untitled-n` document (or on-disk when a parent folder is set).
pub fn requestNewFileDialog(editor: *Editor) void {
    editor.host.requestNewDocument(null, 0);
}

pub fn setActiveFile(editor: *Editor, index: usize) void {
    editor.workbench.setActiveDocIndex(index);
}

pub fn forceCloseFile(editor: *Editor, index: usize) !void {
    if (editor.docAt(index) != null) {
        return editor.rawCloseFile(index);
    }
}

/// Dispatch a generic shell action to the active document owner's command (`<owner_id>.<action>`).
/// No active doc, or an owner that registered no such command, is a clean no-op. This is how the
/// shell's Edit menu / keybinds reach per-editor actions without naming any plugin.
fn runActiveDocCommand(editor: *Editor, action: []const u8) !void {
    const doc = editor.activeDoc() orelse return;
    const id = try std.fmt.allocPrint(editor.arena.allocator(), "{s}.{s}", .{ doc.owner.id, action });
    try editor.host.runCommand(id);
}

/// Whether the active document's owner registered `action` as a command.
pub fn activeDocCommandEnabled(editor: *Editor, action: []const u8) bool {
    const doc = editor.activeDoc() orelse return false;
    var buf: [128]u8 = undefined;
    const id = std.fmt.bufPrint(&buf, "{s}.{s}", .{ doc.owner.id, action }) catch return false;
    return editor.host.commandEnabled(id);
}

/// Whether the active document's owner registered `action` as a command at all (regardless of
/// its current enabled state). Menus use this to decide whether to show the item in the first
/// place — an owner that never registered the action shouldn't get a permanently-greyed entry.
pub fn activeDocHasCommand(editor: *Editor, action: []const u8) bool {
    const doc = editor.activeDoc() orelse return false;
    var buf: [128]u8 = undefined;
    const id = std.fmt.bufPrint(&buf, "{s}.{s}", .{ doc.owner.id, action }) catch return false;
    return editor.host.hasCommand(id);
}

pub fn accept(editor: *Editor) !void {
    try editor.runActiveDocCommand("acceptEdit");
}

pub fn cancel(editor: *Editor) !void {
    try editor.runActiveDocCommand("cancelEdit");
}

pub fn copy(editor: *Editor) !void {
    try editor.runActiveDocCommand("copy");
}

pub fn paste(editor: *Editor) !void {
    try editor.runActiveDocCommand("paste");
}

/// Forwards `name`'s keybind (e.g. "copy"/"paste") as a synthetic key-down event to whichever
/// widget currently holds dvui keyboard focus. On macOS, Cmd+C/Cmd+V only ever reach us as a
/// native menu action (see `Keybinds.tick`'s `builtin.os.tag != .macos` guard), and that path
/// otherwise only knows how to talk to the active *document* (`runActiveDocCommand`). Any other
/// focused widget with its own copy/paste handling — the shell's Output Panel, a plugin's search
/// box, dvui's own text-selection widgets — never sees the raw keystroke at all, unlike on
/// Windows/Linux where the un-marked-handled key event still reaches it normally. Synthesizing
/// the event here routes it through the same per-widget handling those platforms already use.
pub fn forwardKeybindToFocusedWidget(_: *Editor, name: []const u8) !void {
    const cw = dvui.currentWindow();
    const kb = cw.keybinds.get(name) orelse return;
    const key = kb.key orelse return;

    var mod: dvui.enums.Mod = .none;
    if (kb.shift orelse false) mod.combine(.lshift);
    if (kb.control orelse false) mod.combine(.lcontrol);
    if (kb.alt orelse false) mod.combine(.lalt);
    if (kb.command orelse false) mod.combine(.lcommand);

    // `addEventKey` writes `Window.modifiers` as *persistent* state, not per-event: whatever the
    // last key event carried is what the window reports as currently held until another key
    // event replaces it. Injecting a lone key-down therefore leaves the whole app believing
    // cmd/ctrl is held down forever — which is why pasting from the menu left documents stuck in
    // ctrl-hover mode, underlining words and treating clicks as go-to-definition. On the real
    // key path this never happens: the user's own key-up follows and clears it.
    //
    // So: send the matching release. Anything tracking press/release pairs sees a complete one,
    // and because the release carries no modifiers, `addEventKey` resets the window's held-key
    // state through dvui's own path — no reaching into `cw.modifiers` from out here. `.none` is
    // the honest value: a menu click means nothing is physically held.
    _ = try cw.addEventKey(.{ .code = key, .action = .down, .mod = mod });
    _ = try cw.addEventKey(.{ .code = key, .action = .up, .mod = .none });
}

pub fn deleteSelectedContents(editor: *Editor) void {
    editor.runActiveDocCommand("deleteSelection") catch |err| {
        dvui.log.err("deleteSelection command failed: {s}", .{@errorName(err)});
    };
}

/// Performs a save operation on the currently open file.
/// Paths without a recognized on-disk extension (e.g. in-memory `untitled-n`) open Save As instead.
pub fn save(editor: *Editor) !void {
    const doc = editor.activeDoc() orelse return;
    if (!doc.owner.documentHasRecognizedSaveExtension(doc)) {
        editor.requestSaveAs();
        return;
    }
    if (editor.document_watcher) |*w| {
        if (w.hasDiskConflict(doc.id)) {
            Dialogs.FileChangedOnDisk.request(doc.id);
            return;
        }
    }
    if (doc.owner.saveNeedsConfirmation(doc)) {
        doc.owner.requestSaveConfirmation(doc, .editor_save, false);
        return;
    }
    if (comptime builtin.target.cpu.arch == .wasm32) {
        editor.requestWebSaveDialog(.save);
        return;
    }
    if (editor.document_watcher) |*w| w.markPendingBaseline(doc.id);
    try doc.owner.saveDocument(doc);
    if (editor.document_watcher) |*w| w.noteSaved(doc.id);
}

/// Browser: pick download filename/extension before encoding (`processPendingSaveAs`).
pub fn requestWebSaveDialog(editor: *Editor, kind: Dialogs.WebSaveAs.Kind) void {
    if (comptime builtin.target.cpu.arch != .wasm32) return;
    const doc = editor.activeDoc() orelse return;
    Dialogs.WebSaveAs.request(std.fs.path.basename(editor.docPath(doc)), kind);
}

/// Kick off an async save for every dirty file with a recognized extension.
/// Each save lands in the single save-queue worker and runs serially in the
/// background; the GUI stays responsive. Files that need Save As (no extension),
/// flat-raster confirmation, or an unresolved on-disk conflict are skipped — the
/// user can save those individually. Files that are already saving are also
/// skipped (their `saveAsync` no-ops).
pub fn saveAll(editor: *Editor) !void {
    for (editor.open_files.values()) |doc| {
        if (!doc.owner.isDirty(doc)) continue;
        if (!doc.owner.documentHasRecognizedSaveExtension(doc)) continue;
        if (doc.owner.saveNeedsConfirmation(doc)) continue;
        if (editor.document_watcher) |*w| {
            if (w.hasDiskConflict(doc.id)) continue;
        }
        if (editor.document_watcher) |*w| w.markPendingBaseline(doc.id);
        doc.owner.saveDocument(doc) catch |err| {
            dvui.log.err("Save All: file {s} failed: {s}", .{ editor.docPath(doc), @errorName(err) });
            continue;
        };
        if (editor.document_watcher) |*w| w.noteSaved(doc.id);
    }
}

// Not owner-specific — every open document's Save As dialog shares this filter list
// regardless of which plugin owns it (a per-plugin filter set is a possible follow-up, but
// isn't worth a new SDK hook yet). "All Files" comes first so a plain-text document isn't
// stuck choosing among image/pixel-art extensions it doesn't use.
const save_as_dialog_filters: [4]fizzy.backend.DialogFileFilter = .{
    .{ .name = "All Files", .pattern = "*" },
    .{ .name = "fizzy", .pattern = "fiz;pixi" },
    .{ .name = "PNG", .pattern = "png" },
    .{ .name = "JPEG", .pattern = "jpg;jpeg" },
};

/// Opens a Save As dialog: any filename/extension the user types ("All Files"), `.fiz` (all
/// layers; `.pixi` also accepted for legacy), or flat `.png` / `.jpg` / `.jpeg` (visible layers composited).
pub fn requestSaveAs(_: *Editor) void {
    const doc = fizzy.editor.activeDoc() orelse return;
    const def = doc.owner.documentDefaultSaveAsFilename(doc, fizzy.app.allocator) catch {
        std.log.err("Failed to build default save-as name", .{});
        return;
    };
    defer fizzy.app.allocator.free(def);
    const current_file_dir: ?[]const u8 = std.fs.path.dirname(fizzy.editor.docPath(doc));
    fizzy.backend.showSaveFileDialog(saveAsDialogCallback, &save_as_dialog_filters, def, current_file_dir);
}

/// Clears pending save-as / save-and-close state when the user dismisses a save dialog.
pub fn cancelPendingSaveDialog(editor: *Editor) void {
    if (editor.pending_save_as_path) |p| {
        fizzy.app.allocator.free(p);
        editor.pending_save_as_path = null;
    }
    if (comptime builtin.target.cpu.arch == .wasm32) {
        const WebFileIo = @import("WebFileIo.zig");
        if (WebFileIo.pending_save_filename) |p| {
            fizzy.app.allocator.free(p);
            WebFileIo.pending_save_filename = null;
        }
    }

    const file_id = editor.pending_close_file_id orelse if (editor.activeDoc()) |doc| doc.id else null;
    editor.pending_close_file_id = null;

    if (file_id) |id| {
        _ = editor.pending_close_after_save.swapRemove(id);
        if (editor.docById(id)) |doc| {
            doc.owner.resetDocumentSaveUIState(doc);
        }
    } else if (editor.activeDoc()) |doc| {
        doc.owner.resetDocumentSaveUIState(doc);
    }

    if (editor.quit_save_all_ids.items.len > 0 or editor.quit_in_progress) {
        editor.abortSaveAllQuit();
    }
}

/// Save dialog may invoke this from AppKit outside `Window.begin` / `end`; do not use `currentWindow` here.
pub fn saveAsDialogCallback(paths: ?[][:0]const u8) void {
    if (paths == null) {
        fizzy.editor.cancelPendingSaveDialog();
        return;
    }
    const p = paths.?;
    if (p.len == 0) return;
    const path0 = p[0];
    if (path0.len == 0) return;
    if (fizzy.editor.pending_save_as_path) |old| {
        fizzy.app.allocator.free(old);
    }
    fizzy.editor.pending_save_as_path = fizzy.app.allocator.dupe(u8, path0[0..path0.len]) catch {
        dvui.log.err("Save As: out of memory queuing path", .{});
        return;
    };
}

fn processPendingSaveAs(editor: *Editor) void {
    const path = blk: {
        if (editor.pending_save_as_path) |p| break :blk p;
        if (comptime builtin.target.cpu.arch == .wasm32) {
            const WebFileIo = @import("WebFileIo.zig");
            if (WebFileIo.pending_save_filename) |p| break :blk p;
        }
        return;
    };
    const owned_by_editor = editor.pending_save_as_path != null;
    editor.pending_save_as_path = null;
    if (comptime builtin.target.cpu.arch == .wasm32) {
        if (!owned_by_editor) {
            const WebFileIo = @import("WebFileIo.zig");
            WebFileIo.pending_save_filename = null;
        }
    }
    defer fizzy.app.allocator.free(path);

    const doc = editor.activeDoc() orelse {
        editor.pending_close_file_id = null;
        return;
    };

    doc.owner.saveDocumentAs(doc, path, dvui.currentWindow()) catch |err| {
        if (err == error.UnsupportedSaveExtension) {
            dvui.log.err("Save As: choose extension .fiz, .png, .jpg, or .jpeg (got {s})", .{std.fs.path.extension(path)});
        } else {
            dvui.log.err("Save As: {any}", .{err});
        }
        return;
    };
    if (editor.document_watcher) |*w| w.retarget(editor, doc);

    if (editor.pending_close_file_id) |cid| {
        if (doc.id == cid) {
            editor.pending_close_file_id = null;
            editor.rawCloseFileID(cid) catch |err| {
                dvui.log.err("Failed to close file after Save As: {s}", .{@errorName(err)});
            };
            if (editor.quit_save_all_ids.items.len > 0) {
                if (std.mem.indexOfScalar(u64, editor.quit_save_all_ids.items, cid)) |ix| {
                    _ = editor.quit_save_all_ids.swapRemove(ix);
                }
                editor.pending_quit_continue = true;
            }
        }
    }
}

pub fn undo(editor: *Editor) !void {
    const doc = editor.activeDoc() orelse return;
    try doc.owner.undo(doc);
}

pub fn redo(editor: *Editor) !void {
    const doc = editor.activeDoc() orelse return;
    try doc.owner.redo(doc);
}

pub fn openInFileBrowser(_: *Editor, path: []const u8) !void {
    // Darwin goes through `darwin_spawn` rather than `std.process.run`: the latter walks the
    // `environ` array captured at startup, which any `unsetenv` elsewhere in the process (SDL,
    // a plugin, a system framework) shrinks *in place* — leaving a NULL before the captured
    // length and segfaulting the whole app on the next spawn. See `darwin_spawn.zig`.
    if (builtin.os.tag == .macos) {
        // `posix_spawn` (unlike `posix_spawnp`) does not search `$PATH`, so name `open` in full.
        const child = fizzy.core.darwin_spawn.spawn(fizzy.app.allocator, .{
            .argv = &.{ "/usr/bin/open", path },
            .stdin = .discard,
            .stdout = .discard,
            .stderr = .discard,
        }, null) catch {
            dvui.log.err("Failed to open file browser", .{});
            return;
        };
        // `open` exits as soon as Finder has the request, but that can take long enough to
        // stutter a frame — reap it off the draw thread so it doesn't linger as a zombie.
        if (child.id) |pid| {
            if (std.Thread.spawn(.{}, reapChild, .{pid})) |thread| {
                thread.detach();
            } else |_| {
                var status: c_int = undefined;
                _ = std.c.waitpid(pid, &status, 0);
            }
        }
        return;
    }
    // `start` is a cmd.exe builtin, not a standalone executable, so spawning it directly
    // (bypassing the shell) always fails on Windows — reveal via explorer.exe instead.
    if (builtin.os.tag == .windows) {
        const arg = try std.fmt.allocPrint(fizzy.app.allocator, "/select,{s}", .{path});
        defer fizzy.app.allocator.free(arg);
        _ = std.process.run(fizzy.app.allocator, dvui.io, .{ .argv = &.{ "explorer.exe", arg } }) catch {
            dvui.log.err("Failed to open file browser", .{});
            return;
        };
        return;
    }
    _ = std.process.run(fizzy.app.allocator, dvui.io, .{ .argv = &.{ "xdg-open", path } }) catch {
        dvui.log.err("Failed to open file browser", .{});
        return;
    };
}

/// Blocking `waitpid` for a fire-and-forget child, run on its own detached thread.
fn reapChild(pid: std.posix.pid_t) void {
    var status: c_int = undefined;
    _ = std.c.waitpid(pid, &status, 0);
}

pub fn closeFileID(editor: *Editor, id: u64) !void {
    if (editor.open_files.get(id)) |doc| {
        if (doc.owner.isDirty(doc)) {
            Dialogs.UnsavedClose.request(id);
            return;
        }
        try editor.rawCloseFileID(id);
    }
}

pub fn closeFile(editor: *Editor, index: usize) !void {
    const doc = editor.docAt(index) orelse return;
    try editor.closeFileID(doc.id);
}

/// Tear down a document via its owning plugin, falling back to a direct `deinit`.
/// Removes the entry from the plugin's document registry; the shell still removes
/// the matching `DocHandle` from `open_files`.
fn closeDocumentResources(_: *Editor, doc: sdk.DocHandle) void {
    _ = doc.owner.closeDocument(doc);
    doc.owner.unregisterDocument(doc.id);
}

pub fn rawCloseFile(editor: *Editor, index: usize) !void {
    const doc = editor.docAt(index) orelse return;
    const grouping = editor.docGrouping(doc);

    // Post-removal coordinates: `orderedRemoveAt(index)` shifts every later entry down
    // by one, so a neighbor found after `index` must be reported one lower than its
    // pre-removal position.
    const replacement_index: ?usize = blk: {
        for (editor.open_files.values(), 0..) |d, i| {
            if (i == index) continue;
            if (editor.docGrouping(d) == grouping) break :blk if (i > index) i - 1 else i;
        }
        break :blk null;
    };
    editor.workbench.adjustOpenFileIndexAfterClose(grouping, index, replacement_index);

    if (editor.document_watcher) |*w| w.untrack(doc.id);
    editor.closeDocumentResources(doc);
    editor.open_files.orderedRemoveAt(index);
}

pub fn rawCloseFileID(editor: *Editor, id: u64) !void {
    const doc = editor.open_files.get(id) orelse return;
    const index = editor.open_files.getIndex(id) orelse return;
    const grouping = editor.docGrouping(doc);

    // See `rawCloseFile`: neighbor index is reported in post-removal coordinates.
    const replacement_index: ?usize = blk: {
        for (editor.open_files.values(), 0..) |d, i| {
            if (i == index) continue;
            if (editor.docGrouping(d) == grouping) break :blk if (i > index) i - 1 else i;
        }
        break :blk null;
    };
    editor.workbench.adjustOpenFileIndexAfterClose(grouping, index, replacement_index);

    if (editor.document_watcher) |*w| w.untrack(doc.id);
    editor.closeDocumentResources(doc);
    _ = editor.open_files.orderedRemove(id);
}

pub fn deinit(editor: *Editor) !void {
    // Stop watchers first, before touching anything they could still be querying —
    // signals background threads, joins them, and tears down OS watches. Clearing the optionals
    // is part of stopping, not tidiness: `stop` frees the watcher's own state, and the rest of
    // this function still runs code that would otherwise query it — `saveSettingsRaw` below
    // reaches `writeMergedSettings`' `notifyPathChanged` (only on a real write, which is why
    // this crashed rarely rather than always).
    if (editor.document_watcher) |*w| {
        w.stop();
        editor.document_watcher = null;
    }
    if (editor.settings_watcher) |*w| {
        w.stop();
        editor.settings_watcher = null;
    }

    // Tear workspaces down first: `Workspace.deinit` calls back into the owning plugin
    // (e.g. `removeCanvasPane`), so it must run while plugin state is still alive — i.e. before
    // the plugin `deinit` loop below frees it.
    editor.workbench.deinitWorkspaces();

    // Drain & join the save-queue worker before tearing anything else down. Any
    // queued jobs need to finish writing or be dropped before File data is freed.
    for (editor.host.plugins.items) |plugin| plugin.deinit();
    // Signal cancel to any in-flight load workers. They check the flag after `fromPath` returns
    // and discard the result; we deliberately don't await their `Future`s here — `.cancel()`
    // still blocks until the worker's current `loadDocument` call returns (cancellation is
    // only observed *after* it returns — see `FileLoadJob`'s doc comment), which could be
    // slow, and we can't afford to block quit on that. We accept a brief window where a
    // worker may still be running with a discardable result.
    // Pooled-worker allocations (the job struct, and the `Io.Threaded` bookkeeping behind its
    // unawaited `Future`) are short-lived; leaking them on hard quit is acceptable here.
    editor.cancelAllLoadingJobs();
    // Drop our bookkeeping for the jobs. Worker threads still own their result memory until
    // they observe the cancellation and discard it; the process is exiting anyway.
    {
        var it = editor.loading_jobs.valueIterator();
        while (it.next()) |job_ptr| {
            // Detached worker still references the job. Leak the FileLoadJob struct on quit
            // — better than a use-after-free if the worker hasn't yet observed cancellation.
            _ = job_ptr;
        }
        editor.loading_jobs.deinit(fizzy.app.allocator);
    }

    editor.workbench.clearFileTreeTabDragDropState();

    if (editor.pending_save_as_path) |p| {
        fizzy.app.allocator.free(p);
        editor.pending_save_as_path = null;
    }

    editor.quit_save_all_ids.deinit(fizzy.app.allocator);
    editor.quit_saves_in_flight.deinit(fizzy.app.allocator);
    editor.pending_close_after_save.deinit(fizzy.app.allocator);

    // Recents persist via Io.Dir.cwd writes — no FS on wasm; skip persist.
    if (comptime builtin.target.cpu.arch != .wasm32) {
        editor.recents.save(fizzy.app.allocator, try std.fs.path.join(fizzy.app.allocator, &.{ editor.config_folder, "recents.zon" })) catch {
            dvui.log.err("Failed to save recents", .{});
        };
    }
    editor.recents.deinit(fizzy.app.allocator);

    if (comptime builtin.target.cpu.arch != .wasm32) try saveSettingsRaw(editor);
    saveWindowRatiosRaw(editor);
    editor.settings.deinit(fizzy.app.allocator);

    editor.explorer.deinit();
    editor.panel.deinit(fizzy.app.allocator);
    fizzy.app.allocator.destroy(editor.panel);

    PluginStore.deinit();
    editor.unloadPluginLibs();
    editor.host.deinit();
    editor.workbench.deinit();

    // Pixel-art state is owned by the pixi plugin now: its `pluginDeinit` (run in the plugin
    // loop above) persists the project and frees its own state + packer.

    editor.ignore.deinit(fizzy.app.allocator);

    if (editor.keybind_conflicts) |c| {
        fizzy.app.allocator.free(c);
        editor.keybind_conflicts = null;
    }
    if (editor.keybinds_overrides) |*f| {
        f.deinit(fizzy.app.allocator);
        editor.keybinds_overrides = null;
    }
    KeybindSettings.deinit(fizzy.app.allocator);
    editor.keymap.deinit(fizzy.app.allocator);

    if (editor.folder) |folder| fizzy.app.allocator.free(folder);
    editor.arena.deinit();
}
