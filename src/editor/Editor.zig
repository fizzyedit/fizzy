const std = @import("std");
const builtin = @import("builtin");
const icons = @import("icons");
const assets = @import("assets");
const objc = @import("objc");

const cozette_ttf = assets.files.fonts.@"CozetteVector.ttf";
const cozette_bold_ttf = assets.files.fonts.@"CozetteVectorBold.ttf";

const comfortaa_ttf = assets.files.fonts.@"Comfortaa-Regular.ttf";
const comfortaa_bold_ttf = assets.files.fonts.@"Comfortaa-Bold.ttf";

const nunito_ttf = assets.files.fonts.@"Nunito-Regular.ttf";
const nunito_bold_ttf = assets.files.fonts.@"Nunito-Bold.ttf";
const nunito_italic_ttf = assets.files.fonts.@"Nunito-Italic.ttf";
const nunito_bold_italic_ttf = assets.files.fonts.@"Nunito-BoldItalic.ttf";

const plus_jakarta_sans_ttf = assets.files.fonts.@"PlusJakartaSans-Regular.ttf";
const plus_jakarta_sans_bold_ttf = assets.files.fonts.@"PlusJakartaSans-Bold.ttf";
const plus_jakarta_sans_italic_ttf = assets.files.fonts.@"PlusJakartaSans-Italic.ttf";
const plus_jakarta_sans_bold_italic_ttf = assets.files.fonts.@"PlusJakartaSans-BoldItalic.ttf";

const build_opts = @import("build_opts");

const fizzy = @import("../fizzy.zig");
const dvui = @import("dvui");
const core = @import("core");
const update_notify = @import("app").update.update_notify;

const Entry = fizzy.Entry;
const Editor = @This();
pub const App = @import("app").App;
pub const ExtensionConflict = App.ExtensionConflict;
pub const PendingPluginFlags = App.PendingPluginFlags;
pub const FailedPlugin = App.FailedPlugin;
pub const PendingReveal = App.PendingReveal;

pub const Recents = @import("app").Recents;
pub const Settings = @import("app").settings.Settings;

pub const Dialogs = @import("dialogs/Dialogs.zig");

pub const Keybinds = @import("Keybinds.zig");
const KeybindSettings = @import("KeybindSettings.zig");
const Accounts = @import("Accounts.zig");
pub const menu_model = @import("menu_model.zig");

const workbench_mod = @import("workbench");

/// The plugins this application links in, as the build listed them (`bundled_plugins` is
/// generated — see `build/sdk.zig`'s `bundledPluginsModule`). Each exports `plugin_id`,
/// `plugin_options.manifest_zon` and `register(host)`.
const bundled_plugins = @import("bundled_plugins").modules;

const PluginLoader = @import("app").store.Loader;
const PluginStore = @import("app").store.Store;
const PluginManager = @import("app").store.Manager;
/// Fizzy's implementation of the `files` service. Public so a test — or an app copying fizzy —
/// can register it explicitly rather than only through `postInit`.
pub const FilesService = @import("FilesService.zig");
const SettingsTree = @import("SettingsTree.zig");
const OutputPanel = @import("OutputPanel.zig");
const SettingsPluginsZon = @import("app").settings.PluginsZon;
const file_glyphs = @import("file_glyphs.zig");
const SettingsWatcher = @import("app").watch.SettingsWatcher;
const Constants = @import("Constants.zig");
const DocumentWatcher = @import("DocumentWatcher.zig");
const DocumentIo = @import("DocumentIo.zig");
const Watch = @import("app").watch;
const FolderWatcher = Watch.FolderWatcher;

pub const Workspace = workbench_mod.Workspace;
pub const Explorer = @import("explorer/Explorer.zig");
pub const IgnoreRules = @import("explorer/IgnoreRules.zig");
pub const Panel = @import("panel/Panel.zig");
pub const Sidebar = @import("Sidebar.zig");
pub const Infobar = @import("Infobar.zig");
pub const Menu = @import("Menu.zig");
/// Fizzy's own shape. A consumer that wants another one passes `-Dapp-layout=`.
const fizzy_layout = @import("layout.zig");
pub const Layout = @import("app").layout.Layout;
pub const Region = @import("app").layout.Region;
const AppInfo = @import("app").AppInfo;
pub const FileLoadJob = workbench_mod.FileLoadJob;

pub const sdk = fizzy.sdk;
pub const Host = sdk.Host;

/// Workbench: the file-management home — file tree, open/load flow, and the
/// workspace/tabs/splits system, plus the per-branch explorer decoration registry.
pub const Workbench = workbench_mod.Workbench;

/// The host runtime — everything an application on fizzy runs unchanged.
app: App,

/// File-management workbench (per-branch explorer decorations, …)
workbench: Workbench,

/// Which default keymap fizzy starts from.
keybind_profile: Keybinds.Profile = .vscode,

/// VSCode-style Quick Open / command palette overlay.
command_palette: @import("CommandPalette.zig") = .{},

explorer: *Explorer,

panel: *Panel,

last_titlebar_color: dvui.Color,

sidebar: Sidebar,

infobar: Infobar,

/// Whether a text-input widget held keyboard focus at the end of the last frame.
///
/// `dvui.wantTextInput` is the cross-cutting signal — dvui's own `TextEntryWidget`, the text
/// plugin's fork, and any plugin entry all call it on frames they have focus — but it is reset
/// by `Window.begin` and filled in as widgets draw, so it can only be read as last frame's
/// answer. That is fine for deciding who owns a clipboard verb: focus doesn't change between
/// the keystroke and the frame that handles it.
text_input_focused: bool = false,

/// Whether any plugin asked to keep painting this frame — one poll of every plugin's
/// `needsContinuousRepaint`, sampled in `tick` and read by everything that needs the answer.
///
/// One poll, not several, because the hook is allowed to be a *consuming* read: a plugin whose
/// panel is only sometimes drawn answers from a "did I draw" flag it clears as it reports (atlas
/// does exactly this), so a second poll in the same frame answers false and the two callers
/// disagree about the same frame.
plugins_drawing: bool = false,

/// From `.fizignore` (preferred) or `.gitignore` at the project root; used by the Files explorer.
ignore: IgnoreRules = .{},

themes: std.ArrayList(dvui.Theme) = .empty,

/// An open document's presence in the surface registry, by document id. A document is a surface
/// for exactly as long as it is open: registered in `insertOpenDoc`, taken back on close. What
/// this buys is that a document is addressable like every other surface — assigned to a pane
/// region by name, listed by the picker, restored with a session — while document plugins keep
/// exactly the vtable they have: the surface's `draw` is `owner.drawDocument`.
doc_surfaces: std.AutoHashMapUnmanaged(u64, *DocSurface) = .empty,

/// Background file-load jobs in flight. Keyed by absolute path. Each job's worker thread loads
/// the document bytes off the main thread; the main thread polls via `processLoadingJobs`
/// and moves completed results into `open_files`. The map owns its key strings via each job's
/// `path` allocation; the StringHashMap stores key slices that point into job memory.
loading_jobs: std.StringHashMapUnmanaged(*FileLoadJob) = .empty,

/// True iff a loading job should set its target file as the active file once it lands.
/// `setActiveFile`-on-completion respects the most recent open request — multiple in-flight
/// loads only auto-focus the most recently requested one.
last_load_request_path: ?[]const u8 = null,

window_opacity: f32 = 1.0,

/// Animated window-background opacity multiplier. Eases toward the windowed
/// target (translucent, vibrancy shows through) or 1.0 (opaque) when
/// maximized/fullscreen, so the vibrancy fades in/out across fullscreen
/// transitions instead of snapping. `< 0` is a sentinel meaning "snap to the
/// target on the first frame" so there is no fade at launch.
window_opacity_anim: f32 = -1.0,

/// Menu-bar clicks waiting for a safe point in the frame. Each is a `menu_model` tag.
pending_native_menu_actions: [16]fizzy.backend.NativeMenuAction = undefined,

pending_native_menu_actions_len: u8 = 0,

/// Same queue/flush shape as `pending_native_menu_actions`, but for the generic macOS
/// dispatch path: indices into `host.native_menu_items` (see `rebuildDynamicNativeMenus`).
pending_native_menu_item_indices: [16]usize = undefined,

pending_native_menu_item_indices_len: u8 = 0,

/// When set, next `tick` runs `warmupDrawingComposites` on the active file (after open or drawing-tool select).
pending_composite_warmup: bool = false,

/// Watches each open on-disk document for external edits. Clean docs reload via
/// `Plugin.reloadDocument`; dirty docs set a conflict flag and `save` shows
/// `FileChangedOnDisk`. Null on wasm / unsupported OS / start failure — best-effort.
document_watcher: ?DocumentWatcher = null,

/// The host's document reader/writer: every save whose owner can serialize, and every open
/// on a mount. `undefined` until `init` has a stable `*Editor` to hand it (it calls back into
/// the editor on completion).
doc_io: DocumentIo = undefined,

/// Timestamp of the most recent touch press anywhere in the app, or null if there
/// hasn't been one. `Editor.draw` forces a per-frame refresh during the post-press
/// grace window so `dvui.ContextWidget.updateHold` actually re-runs and gets a chance
/// to open the hold-to-context menu on touch-only hardware.
last_touch_press_ns: ?i128 = null,

/// dvui resolves a `Font` to a source by exact `(family, weight, style)`; it never synthesizes
/// an oblique or an embolden. A style with no source here silently falls back to the nearest
/// same-family face, so *emphasis renders as plain text*.
///
/// The rule that follows: any family a theme points `font_body` or `font_heading` at must ship
/// all four faces, because those are the fonts document content (markdown `*em*`/`**strong**`,
/// and anything else a plugin styles per-span) is rendered in.
///
/// Two families here deliberately ship fewer, and both are safe only because no theme uses them
/// for body or heading text:
///   - CozetteVector (`font_mono`) is a pixel face with no italic cut; slanting one would smear
///     the pixel grid, so mono italics fall back to upright by design.
///   - Comfortaa (`font_title`) has no italic cut in the family at all. Titles are chrome, never
///     document content, so nothing asks it for a style it can't serve — don't repoint
///     `font_body` at it.
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
        .family = dvui.Font.array("Nunito"),
        .bytes = nunito_ttf,
    },
    .{
        .family = dvui.Font.array("Nunito"),
        .bytes = nunito_bold_ttf,
        .weight = .bold,
    },
    .{
        .family = dvui.Font.array("Nunito"),
        .bytes = nunito_italic_ttf,
        .style = .italic,
    },
    .{
        .family = dvui.Font.array("Nunito"),
        .bytes = nunito_bold_italic_ttf,
        .weight = .bold,
        .style = .italic,
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
    .{
        .family = dvui.Font.array("PlusJakartaSans"),
        .bytes = plus_jakarta_sans_italic_ttf,
        .style = .italic,
    },
    .{
        .family = dvui.Font.array("PlusJakartaSans"),
        .bytes = plus_jakarta_sans_bold_italic_ttf,
        .weight = .bold,
        .style = .italic,
    },
};

pub fn init(
    app: *Entry,
) !Editor {
    const arena = dvui.currentWindow().arena();
    // Wasm: skip the env-map / known-folders lookup. `std.process.Environ.put`
    // analyzes a `block.view()` call that doesn't compile on freestanding (where
    // `Block == GlobalBlock`), and the browser has no concept of OS user dirs
    // anyway. `app.root_path` ("." on wasm) is the only sensible fallback.
    const config_root: []const u8 = if (comptime builtin.target.cpu.arch == .wasm32)
        app.root_path
    else config_root_blk: {
        break :config_root_blk try fizzy.core.paths.configRoot(dvui.io, arena, fizzy.core.platform.processEnviron(), app.root_path);
    };
    const config_folder: []const u8 = if (comptime builtin.target.cpu.arch == .wasm32)
        app.root_path
    else config_folder_blk: {
        break :config_folder_blk try fizzy.core.paths.configFolder(app.allocator, dvui.io, arena, fizzy.core.platform.processEnviron(), app.root_path, AppInfo.current.config_dir);
    };

    // One-time migration: pre-rename builds used `Fizzy/` (capitalized).
    // On case-insensitive filesystems (Windows NTFS, macOS APFS) `fizzy/` already
    // resolves to that same directory, so the rename is a no-op and the
    // failure is ignored. On case-sensitive filesystems (most Linux) the legacy
    // dir is otherwise orphaned, so we move it across to preserve user settings.
    // Wasm: no filesystem, no migration; `Io.Dir.renameAbsolute` pulls in posix.AT.
    // Fizzy's own one-time migration, not something an app built on fizzy inherits.
    if (comptime builtin.target.cpu.arch != .wasm32 and std.mem.eql(u8, AppInfo.current.name, "fizzy")) {
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
    const palette_folder = std.fs.path.join(app.allocator, &.{ config_folder, "palettes" }) catch config_folder;

    var editor: Editor = .{
        .app = .{
            .gpa = app.allocator,
            .arena = .init(std.heap.page_allocator),
            .config_folder = config_folder,
            .palette_folder = palette_folder,
            .host = .init(app.allocator),
            .file_table = .init(app.allocator, dvui.io),
            .secrets = try .init(app.allocator, dvui.io, config_folder),
        },
        .explorer = try app.allocator.create(Explorer),
        .panel = try app.allocator.create(Panel),
        .sidebar = try .init(),
        .infobar = try .init(),
        .last_titlebar_color = dvui.themeGet().color(.control, .fill),
        .themes = .empty,
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
        try std.fs.path.join(app.allocator, &.{ editor.app.config_folder, "plugins" });
    editor.app.host.plugins_dir = plugins_dir;

    {
        const settings_path = try std.fs.path.join(app.allocator, &.{ editor.app.config_folder, "settings.zon" });
        editor.app.settings = try Settings.load(app.allocator, settings_path, plugins_dir);
    }

    {
        // What `layout.zon` remembers per region: its extent, and what the user put in it.
        const saved = fizzy.backend.loadRegions(app.allocator, editor.app.config_folder);
        defer fizzy.backend.freeRegions(app.allocator, saved);
        for (saved) |r| {
            if (r.extent) |e| _ = editor.app.layout.setExtent(app.allocator, r.name, e);
            if (r.surfaces) |ids| editor.app.layout.assign(app.allocator, r.name, ids) catch continue;
            if (r.shows) |s| editor.app.layout.setShows(app.allocator, r.name, switch (s) {
                .one => .one,
                .many => .many,
            });
        }
        loadRuntimeSplits(&editor.app.layout, app.allocator, saved);
        if (fizzy.backend.loadTree(app.allocator, editor.app.config_folder)) |d| {
            editor.app.layout.pending_dock = d;
        }
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
        fizzy_dark.font_body = .find(.{ .family = "Nunito", .size = editor.app.settings.font_body_size });
        fizzy_dark.font_title = .find(.{ .family = "Comfortaa", .size = editor.app.settings.font_title_size, .weight = .bold });
        fizzy_dark.font_heading = .find(.{ .family = "PlusJakartaSans", .size = editor.app.settings.font_heading_size, .weight = .bold });
        fizzy_dark.font_mono = .find(.{ .family = "CozetteVector", .size = editor.app.settings.font_mono_size });

        var strawberry: dvui.Theme = fizzy_dark;
        strawberry.dark = true;
        strawberry.name = "Strawberry";
        strawberry.window = .{
            .fill = .{ .r = 96, .g = 12, .b = 32, .a = 255 },
            .border = .{ .r = 131, .g = 46, .b = 59, .a = 255 },
            .text = .{ .r = 247, .g = 210, .b = 184, .a = 255 },
        };

        strawberry.control = .{
            .fill = .{ .r = 188, .g = 46, .b = 72, .a = 255 },
            .fill_hover = .{ .r = 178, .g = 44, .b = 66, .a = 255 },
            .fill_press = .{ .r = 150, .g = 34, .b = 56, .a = 255 },
            .border = .{ .r = 102, .g = 19, .b = 42, .a = 255 },
            .text = .{ .r = 252, .g = 223, .b = 205, .a = 255 },
            .text_hover = .{ .r = 255, .g = 240, .b = 228, .a = 255 },
        };
        strawberry.highlight = .{
            .fill = .{ .r = 47, .g = 179, .b = 135, .a = 255 },
            .border = .{ .r = 47, .g = 179, .b = 135, .a = 255 },
            .text = .{ .r = 58, .g = 10, .b = 26, .a = 255 },
        };
        strawberry.err = .{
            .fill = .{ .r = 199, .g = 17, .b = 20, .a = 255 },
            .text = .{ .r = 255, .g = 238, .b = 228, .a = 255 },
        };

        // theme.content
        strawberry.fill = .{ .r = 165, .g = 24, .b = 64, .a = 255 };
        strawberry.fill_hover = .{ .r = 148, .g = 30, .b = 63, .a = 255 };
        strawberry.fill_press = .{ .r = 104, .g = 18, .b = 42, .a = 255 };
        strawberry.text = strawberry.window.text.?;
        strawberry.text_hover = .{ .r = 255, .g = 238, .b = 224, .a = 255 };
        strawberry.border = .{ .r = 131, .g = 46, .b = 59, .a = 255 };
        strawberry.focus = strawberry.highlight.fill.?;

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

        editor.themes.append(app.allocator, fizzy_light) catch {
            dvui.log.err("Failed to append fizzy light theme", .{});
            return error.FailedToAppendFizzyLightTheme;
        };

        editor.themes.append(app.allocator, strawberry) catch {
            dvui.log.err("Failed to append moi theme", .{});
            return error.FailedToAppendMoiTheme;
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
        if (std.fs.path.isAbsolute(editor.app.config_folder)) {
            std.Io.Dir.accessAbsolute(dvui.io, editor.app.config_folder, .{ .read = true }) catch {
                valid_path = false;
            };

            if (!valid_path) {
                std.Io.Dir.createDirAbsolute(dvui.io, editor.app.config_folder, .default_dir) catch |err| dvui.log.err("Failed to create config folder: {s}: {any}", .{ editor.app.config_folder, err });
            }
        }

        valid_path = true;
        if (std.fs.path.isAbsolute(editor.app.palette_folder)) {
            std.Io.Dir.accessAbsolute(dvui.io, editor.app.palette_folder, .{ .read = true }) catch {
                valid_path = false;
            };

            if (!valid_path) {
                std.Io.Dir.createDirAbsolute(dvui.io, editor.app.palette_folder, .default_dir) catch |err| dvui.log.err("Failed to create palette folder: {s}: {any}", .{ editor.app.palette_folder, err });
            }
        }
    }

    fizzy.core.perf.console_logging_enabled = Constants.perf_logging;
    editor.app.recents = Recents.load(app.allocator, try std.fs.path.join(app.allocator, &.{ editor.app.config_folder, "recents.zon" })) catch .{
        .folders = .init(app.allocator),
    };

    fizzy.backend.setTitlebarColor(dvui.currentWindow(), dvui.themeGet().color(.content, .fill).opacity(if (dvui.themeGet().dark) editor.app.settings.window_opacity_dark else editor.app.settings.window_opacity_light));

    editor.explorer.* = .init();
    editor.panel.* = .init();
    editor.app.open_files = .empty;
    try editor.workbench.initDefaultWorkspace();

    // Capture dvui's defaults before fizzy's own binds land, so `rebuildKeybinds` can
    // restore them after clearing the map.
    editor.app.dvui_default_keybinds = try dvui.currentWindow().keybinds.clone(app.allocator);

    try Keybinds.register();

    // Collect the initial settings.zon text for autosave dedup — must match exactly what
    // `writeMergedSettings` would produce with no pending plugin writes (same composer, empty
    // overlay), otherwise the very first autosave after startup would spuriously rewrite the
    // file just because this seed only accounted for fizzy's own fields, not `.plugins`.
    if (comptime builtin.target.cpu.arch == .wasm32) {
        const serialized = try Settings.serialize(&editor.app.settings, app.allocator);
        defer app.allocator.free(serialized);
        editor.app.settings_last_saved_hash = std.hash.Wyhash.hash(0, serialized);
    } else {
        const settings_path = try std.fs.path.join(app.allocator, &.{ editor.app.config_folder, "settings.zon" });
        defer app.allocator.free(settings_path);
        const composed = try editor.composeSettingsText(app.allocator, settings_path, &.{});
        defer app.allocator.free(composed);
        editor.app.settings_last_saved_hash = std.hash.Wyhash.hash(0, composed);
    }

    return editor;
}

/// Second-stage init that needs the editor at its FINAL heap address. `init`
/// builds an `Editor` by value and the caller copies it to the heap, so anything
/// that captures `&editor.*` (e.g. a service whose `ctx` is the editor pointer)
/// must run here — not in `init`, where it would point at the stack temporary.
/// Called from `App.AppInit` right after the heap copy. (The built-in branch
/// decorators registered in `init` are exempt: they store fn pointers, not `&editor`.)
/// Stable fizzy-builtin contribution id.
pub const view_settings = "fizzy.settings";

/// Stable workbench sidebar view id (matches `workbench.view_files`).
pub const workbench_files_view = workbench_mod.view_files;

pub fn loadUserPlugins(editor: *Editor, config_folder: []const u8) void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;

    const plugins_dir = std.fs.path.join(editor.app.gpa, &.{ config_folder, "plugins" }) catch return;
    defer editor.app.gpa.free(plugins_dir);

    const ext_suffix: []const u8 = switch (builtin.os.tag) {
        .windows => ".dll",
        .macos => ".dylib",
        else => ".so",
    };

    App.migrateFlatPluginLayout(editor.app.gpa, plugins_dir, ext_suffix);

    // Leftover fresh-load temp copies from a previous run (see `PluginLoader.copyToFreshLoadPath`)
    // — safe to clear unconditionally here since nothing is loaded from this directory yet.
    PluginLoader.sweepLoadTempDir(editor.app.gpa, plugins_dir);

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
        if (editor.app.isPluginDisabled(plugin_id)) {
            dvui.log.info("user plugin '{s}' is disabled; skipped", .{plugin_id});
            continue;
        }

        const file_name = PluginLoader.pluginFilename(plugin_id, editor.app.gpa) catch continue;
        defer editor.app.gpa.free(file_name);
        const path = std.fs.path.join(editor.app.gpa, &.{ plugins_dir, plugin_id, file_name }) catch continue;

        if (editor.app.host.pluginById(plugin_id) != null) {
            // A fizzy built-in (`text`/`workbench`/`image`/`markdown`) is loaded via its own
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
                editor.app.recordPluginFailure(plugin_id, "id already registered by a built-in plugin", null, if (probe) |info| info.plugin_version else null, .of(path));
            }
            editor.app.gpa.free(path);
            continue;
        }

        const load_start = std.Io.Clock.boot.now(dvui.io).nanoseconds;
        const loaded = PluginLoader.loadAndRegister(&editor.app.host, editor.app.gpa, path, plugin_id, .{
            .gpa = &editor.app.gpa,
            .arg_b = @ptrCast(&editor.app.host),
            .arg_c = null,
        }) catch |err| {
            dvui.log.err("user plugin '{s}' ({s}): load failed: {s} — {s}", .{ plugin_id, path, @errorName(err), App.pluginLoadFailureReason(err) });
            editor.app.recordLoadFailure(plugin_id, path, err);
            editor.app.gpa.free(path);
            continue;
        };

        App.appendLoadedPluginLib(&editor.app, loaded) catch {
            dvui.log.err("user plugin '{s}': out of memory storing LoadedLib", .{plugin_id});
            editor.app.recordPluginFailure(plugin_id, "ran out of memory while loading", null, loaded.version_info.plugin_version, .of(loaded.path));
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
        App.syncLoadedPluginDvuiContexts(&editor.app);
        App.syncLoadedPluginRenderBridge(&editor.app);
    }
}

fn unloadPluginLibs(editor: *Editor) void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    for (editor.app.loaded_plugin_libs.items) |*entry| {
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
        editor.app.gpa.free(entry.plugin_id);
        editor.app.gpa.free(entry.path);
    }
    editor.app.loaded_plugin_libs.deinit(editor.app.gpa);

    for (editor.app.failed_user_plugins.items) |f| {
        editor.app.gpa.free(f.id);
        editor.app.gpa.free(f.reason);
        if (f.detail) |d| editor.app.gpa.free(d);
    }
    editor.app.failed_user_plugins.deinit(editor.app.gpa);

    for (editor.app.disabled_plugin_ids.items) |id| editor.app.gpa.free(id);
    editor.app.disabled_plugin_ids.deinit(editor.app.gpa);

    for (editor.app.undecided_plugin_ids.items) |id| editor.app.gpa.free(id);
    editor.app.undecided_plugin_ids.deinit(editor.app.gpa);

    for (editor.app.auto_update_off_ids.items) |id| editor.app.gpa.free(id);
    editor.app.auto_update_off_ids.deinit(editor.app.gpa);

    {
        var it = editor.app.plugin_flags_pending.iterator();
        while (it.next()) |e| editor.app.gpa.free(e.key_ptr.*);
        editor.app.plugin_flags_pending.deinit(editor.app.gpa);
    }

    {
        var it = editor.app.plugin_extensions_pending.iterator();
        while (it.next()) |e| {
            editor.app.gpa.free(e.key_ptr.*);
            SettingsPluginsZon.freeExtensions(editor.app.gpa, e.value_ptr.*);
        }
        editor.app.plugin_extensions_pending.deinit(editor.app.gpa);
    }
    editor.app.clearExtensionOwnerCache();

    editor.app.dvui_default_keybinds.deinit(editor.app.gpa);
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
    inline for (bundled_plugins) |m| {
        if (std.mem.eql(u8, m.plugin_id, id)) return true;
    }
    return false;
}

/// A bundled built-in's whole parsed manifest, straight off its own compiled-in
/// `plugin_options.manifest_zon` — no dylib/dlopen involved, since a static built-in has no
/// separate file to probe (`PluginLoader.probeManifestInfo` is the dylib-path equivalent for
/// everything else). Null when `id` isn't a built-in or its manifest doesn't parse.
///
/// Returned in the editor's per-frame arena, not the persistent allocator — this is a UI display
/// helper meant to be called fresh every frame (like the store card labels), so the caller never
/// has to free it, and no `manifest_cache` entry is needed for built-ins.
pub fn builtinManifest(editor: *Editor, id: []const u8) ?sdk.Manifest {
    inline for (bundled_plugins) |m| {
        if (std.mem.eql(u8, m.plugin_id, id)) {
            const frame_gpa = editor.app.arena.allocator();
            const zon = frame_gpa.dupeZ(u8, m.plugin_options.manifest_zon) catch return null;
            return sdk.Manifest.parse(frame_gpa, zon) catch return null;
        }
    }
    return null;
}

/// True when `id` names a runtime-loaded user plugin that may be unloaded/disabled.
pub fn isUnloadablePlugin(editor: *Editor, id: []const u8) bool {
    if (isBundledPluginId(id)) return false;
    for (editor.app.loaded_plugin_libs.items) |loaded| {
        if (std.mem.eql(u8, loaded.plugin_id, id)) return true;
    }
    return false;
}

/// Seed the runtime per-plugin flag sets from on-disk plugin directories: `disabled_plugin_ids`
/// from every `.plugins.<id>.enabled` that is not `true` (absent entry / omitted field / explicit
/// false all mean disabled — R12), and `auto_update_off_ids` from every `.plugins.<id>.auto_update`
/// that is explicitly `false`. One directory walk and one settings read for both.
/// Call once after settings load, before `loadUserPlugins`.
fn seedPluginFlags(editor: *Editor) void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    const gpa = editor.app.gpa;
    const plugins_dir = std.fs.path.join(gpa, &.{ editor.app.config_folder, "plugins" }) catch return;
    defer gpa.free(plugins_dir);

    const settings_path = std.fs.path.join(gpa, &.{ editor.app.config_folder, "settings.zon" }) catch return;
    defer gpa.free(settings_path);
    const data = fizzy.core.fs.readZ(gpa, dvui.io, settings_path) catch null;
    defer if (data) |d| gpa.free(d);

    var dir = std.Io.Dir.cwd().openDir(dvui.io, plugins_dir, .{ .iterate = true }) catch return;
    defer dir.close(dvui.io);
    var iter = dir.iterate();
    while (iter.next(dvui.io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const id = entry.name;
        if (id.len == 0 or id[0] == '.') continue;
        if (!App.isValidPluginId(id)) continue;
        if (isBundledPluginId(id)) continue;
        // The two flags are independent: a disabled plugin can still be opted out of updates
        // (which takes effect the moment it is enabled again), so neither read short-circuits
        // the other.
        editor.app.trackAutoUpdate(id, App.readPluginAutoUpdate(gpa, data, id)) catch {};
        const state = App.readPluginEnabledState(gpa, data, id);
        if (state == .enabled) continue;
        editor.app.trackDisabledPlugin(id) catch {};
        // Never asked about: a build that appeared while fizzy wasn't running. Offer it in the
        // store rather than leaving it looking like a plugin the user had switched off.
        if (state == .unset) editor.app.trackUndecidedPlugin(id) catch {};
    }
}

/// Opt `id` in or out of store updates, persisting the choice immediately (same reasoning as
/// `setPluginEnabled`: a discrete deliberate toggle should not ride the debounced autosave).
/// Nothing is downloaded or unloaded here — the next `PluginStore` pass simply starts or stops
/// considering this plugin.
pub fn setPluginAutoUpdate(editor: *Editor, id: []const u8, on: bool) !void {
    if (isBundledPluginId(id)) return error.NotUnloadable; // shipped with the exe; the store never updates it
    if (editor.app.isPluginAutoUpdate(id) == on) return;
    try editor.app.trackAutoUpdate(id, on);
    errdefer editor.app.trackAutoUpdate(id, !on) catch {};
    try editor.setPluginFlagsPersisted(id, .{ .auto_update = on });
}

/// Buffer per-plugin fizzy-reserved field writes (`.enabled` / `.auto_update`) and flush
/// `settings.zon` **immediately**. Each of these is a discrete, infrequent, important action, so
/// it is flushed synchronously rather than through the debounced autosave (same reasoning the old
/// `setDisabledPersisted` had: losing an explicit toggle to a skipped autosave window is worse
/// than one extra write). Null fields in `flags` are left untouched — a buffered write from
/// earlier this cycle survives, and anything neither call set is read back off disk by
/// `writeMergedSettings`.
fn setPluginFlagsPersisted(editor: *Editor, id: []const u8, flags: PendingPluginFlags) !void {
    if (!App.isValidPluginId(id)) {
        // A `true` enable is the one case allowed through for an id fizzy already loaded from a
        // path it validated itself; every other write to a bogus id is refused.
        if (flags.enabled != true or flags.auto_update != null) return error.InvalidPluginId;
    }
    const gpa = editor.app.gpa;
    if (editor.app.plugin_flags_pending.getPtr(id)) |slot| {
        if (flags.erase) {
            slot.* = .{ .erase = true };
        } else {
            if (flags.enabled) |e| slot.enabled = e;
            if (flags.auto_update) |a| slot.auto_update = a;
        }
    } else {
        const key = try gpa.dupe(u8, id);
        errdefer gpa.free(key);
        try editor.app.plugin_flags_pending.put(gpa, key, flags);
    }
    if (comptime builtin.target.cpu.arch == .wasm32) {
        editor.app.host.markSettingsDirty();
    } else {
        editor.saveSettingsRaw() catch |err| {
            dvui.log.err("Failed to persist plugin flags immediately ({s}); deferring to autosave", .{@errorName(err)});
            editor.app.host.markSettingsDirty();
        };
    }
}

fn setPluginEnabledPersisted(editor: *Editor, id: []const u8, enabled: bool) !void {
    // Either direction is a decision, so the plugin stops being an undecided drop-in offer.
    editor.app.untrackUndecidedPlugin(id);
    return editor.setPluginFlagsPersisted(id, .{ .enabled = enabled });
}

/// Erase fizzy's decision record for `id` — the `.enabled` field and the `.extensions` list —
/// leaving the plugin's own `.settings` block alone. Called from `uninstallPlugin`, and only
/// from there.
///
/// This is the whole mechanism behind "uninstalling makes a reinstall ask again": with no
/// `.enabled` on record the plugin comes back as *undecided* (rail badge + Load button), and with
/// no `.extensions` on record it has no claim on any file type, so the first load recomputes the
/// ownership question from scratch. Enable, disable and update all leave the record intact and
/// therefore stay silent. Settings survive because they are the plugin's own data, not a fizzy
/// decision — the pre-existing "reinstalling picks your config back up" promise (docs/PLUGINS.md
/// §3.1) is about exactly that half.
fn clearPluginOwnershipRecord(editor: *Editor, id: []const u8) void {
    editor.setPluginFlagsPersisted(id, .{ .erase = true }) catch |err|
        dvui.log.warn("uninstall '{s}': could not clear its enabled/extensions record: {s}", .{ id, @errorName(err) });
}

// ---- file-type ownership (`.plugins.<id>.extensions`) -------------------------------
//
// Which plugin opens a given extension is an explicit, persisted, per-extension user choice —
// there is no numeric priority contest between plugin authors. `Host.pluginForExtension`
// resolves it as: the user's assignment (via `EditorAPI.extensionOwnerOverride`, backed by
// `extension_owner` below) → the unique plugin offering it via `fileTypes` → the fallback
// editor. Everything here interprets `settings.zon`; only `resolveExtensionConflict` writes it.

/// Rebuild `extension_owner` (and `extension_conflicts`) from the persisted `.extensions` lists
/// of the **currently loaded** plugins. Call after any change to that set: startup load, install,
/// update/reload, enable/disable, unload, and every File Types settings edit.
///
/// **Strictly read-only.** `settings.zon` is watched live and reconciled externally (see
/// `SettingsWatcher`), so a self-heal that wrote as a side effect of loading would race that
/// watcher instead of composing with it. Two on-disk states are therefore *interpreted*, never
/// corrected, and both are recorded in `extension_conflicts` for the File Types table to surface:
///
///   1. **Stale** — the entry names an extension the plugin no longer offers via `fileTypes`
///      (an update dropped support). Ignored, so the extension falls through to ordinary
///      resolution. The fallback editor is exempt: it legitimately owns anything.
///   2. **Duplicate** — two loaded plugins persist the same extension, only reachable from a
///      hand-edited file. The alphabetically-first id wins, so the result never depends on
///      dylib load/scan order.
///
/// Iterating only *loaded* plugins is also what makes uninstall compose for free: an uninstalled
/// plugin's block deliberately survives in `settings.zon`, and its claim simply doesn't appear
/// while it's gone — then comes back intact if it is reinstalled.
pub fn rebuildExtensionOwnerCache(editor: *Editor) void {
    const gpa = editor.app.gpa;
    editor.app.clearExtensionOwnerCache();
    if (comptime builtin.target.cpu.arch == .wasm32) return;

    const settings_path = std.fs.path.join(gpa, &.{ editor.app.config_folder, "settings.zon" }) catch return;
    defer gpa.free(settings_path);
    const data = fizzy.core.fs.readZ(gpa, dvui.io, settings_path) catch null;
    defer if (data) |d| gpa.free(d);

    // Stable order: sort ids so a duplicate's winner matches `Host.pluginForExtension`'s own
    // alphabetical tie-break rather than depending on registration order.
    var ids: std.ArrayListUnmanaged([]const u8) = .empty;
    defer ids.deinit(gpa);
    for (editor.app.host.plugins.items) |plugin| ids.append(gpa, plugin.id) catch return;
    std.mem.sort([]const u8, ids.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    for (ids.items) |id| {
        const plugin = editor.app.host.pluginById(id) orelse continue;
        const exts = App.readPluginExtensions(gpa, data, id);
        defer SettingsPluginsZon.freeExtensions(gpa, exts);

        for (exts) |ext| {
            if (!editor.app.host.ownsExtension(plugin, ext)) {
                editor.app.recordExtensionConflict(ext, null, id, .stale);
                continue;
            }
            if (editor.app.extension_owner.get(ext)) |winner| {
                // Alphabetical order means the incumbent always wins; this entry is the loser.
                editor.app.recordExtensionConflict(ext, winner, id, .duplicate);
                continue;
            }
            const key = gpa.dupe(u8, ext) catch continue;
            const val = gpa.dupe(u8, id) catch {
                gpa.free(key);
                continue;
            };
            editor.app.extension_owner.put(gpa, key, val) catch {
                gpa.free(key);
                gpa.free(val);
            };
        }
    }
}

/// **The only function that writes `.extensions` to disk**, and it runs only in direct response
/// to an explicit user decision — the install-time dialog's Confirm, or a File Types dropdown.
/// No load or reconcile path may call it.
///
/// Single-writer-per-extension: `ext` is added to `chosen_id`'s list *and* stripped from every
/// other plugin that currently lists it, which is what keeps fizzy from ever producing the
/// duplicate state `rebuildExtensionOwnerCache` has to tolerate from hand-edited files. It is
/// also how a repair works — assigning an owner in a conflicted row rewrites both sides.
///
/// `chosen_id` may be the fallback editor's own id ("keep Plain Text for `.foo`"): `ownsExtension`
/// treats the fallback editor as owning anything, so that is a legal, meaningful entry.
pub fn resolveExtensionConflict(editor: *Editor, ext: []const u8, chosen_id: []const u8) !void {
    const gpa = editor.app.gpa;
    if (ext.len == 0) return error.InvalidExtension;

    const settings_path = try std.fs.path.join(gpa, &.{ editor.app.config_folder, "settings.zon" });
    defer gpa.free(settings_path);
    const data = fizzy.core.fs.readZ(gpa, dvui.io, settings_path) catch null;
    defer if (data) |d| gpa.free(d);

    // Every id with a block on disk, not just the loaded ones — a disabled or uninstalled
    // plugin's stale claim on `ext` must be stripped too, or it would come back the moment
    // that plugin loads again and silently re-contest an extension the user just decided.
    const entries = try SettingsPluginsZon.listPluginBlocks(gpa, data);
    defer SettingsPluginsZon.freeEntries(gpa, entries);

    var seen_chosen = false;
    for (entries) |entry| {
        const is_chosen = std.mem.eql(u8, entry.id, chosen_id);
        if (is_chosen) seen_chosen = true;
        const current = App.readPluginExtensions(gpa, data, entry.id);
        defer SettingsPluginsZon.freeExtensions(gpa, current);

        var next: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (next.items) |e| gpa.free(e);
            next.deinit(gpa);
        }
        var changed = false;
        var already_has = false;
        for (current) |e| {
            if (std.mem.eql(u8, e, ext)) {
                if (is_chosen) {
                    already_has = true;
                } else {
                    changed = true; // strip: this plugin is no longer the owner
                    continue;
                }
            }
            try next.append(gpa, try gpa.dupe(u8, e));
        }
        if (is_chosen and !already_has) {
            try next.append(gpa, try gpa.dupe(u8, ext));
            changed = true;
        }
        if (!changed) {
            for (next.items) |e| gpa.free(e);
            next.deinit(gpa);
            continue;
        }
        try editor.app.setPluginExtensionsPersisted(entry.id, try next.toOwnedSlice(gpa));
    }

    // The chosen plugin may have no block on disk yet (first ever decision about it).
    if (!seen_chosen) {
        var next: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (next.items) |e| gpa.free(e);
            next.deinit(gpa);
        }
        try next.append(gpa, try gpa.dupe(u8, ext));
        try editor.app.setPluginExtensionsPersisted(chosen_id, try next.toOwnedSlice(gpa));
    }

    try editor.flushPluginExtensionWrites();
    editor.rebuildExtensionOwnerCache();
}

/// Flush buffered `.extensions` writes immediately, like `setPluginFlagsPersisted` does for the
/// boolean flags: an explicit ownership decision is discrete and important enough that losing it
/// to a skipped autosave window is worse than one extra write.
fn flushPluginExtensionWrites(editor: *Editor) !void {
    if (comptime builtin.target.cpu.arch == .wasm32) {
        editor.app.host.markSettingsDirty();
        return;
    }
    editor.saveSettingsRaw() catch |err| {
        dvui.log.err("Failed to persist file-type ownership immediately ({s}); deferring to autosave", .{@errorName(err)});
        editor.app.host.markSettingsDirty();
    };
}

/// Offer the user a decision about any extension `id` offers that something else already opens.
///
/// **Only ever called when a plugin *arrives*:** `installAndLoadPlugin` (a store install) and
/// `setPluginEnabled`'s first load of an undecided drop-in. Never from the plain startup load
/// path (`loadUserPlugins`/`loadUserPluginById`), and — since the R19 follow-up — never from
/// `updatePlugin` either: an update is the same plugin the user already answered for, and
/// prompting on every store update or every local rebuild is nagging, not consent.
///
/// That scoping is the entire mechanism keeping an unresolved conflict from nagging, and it is
/// why no per-extension "already asked" flag is persisted anywhere. What *is* persisted is the
/// coarser record: `.plugins.<id>.enabled`'s presence means "fizzy has asked about this plugin".
/// Enable, disable and update leave it be; only `uninstallPlugin` erases it
/// (`clearPluginOwnershipRecord`), which is what lets a reinstall ask again.
///
/// A conflict is "some *other* plugin currently opens this extension" — including the case where
/// that other plugin is only the `text` fallback, which is the ".txt claimed by a new plugin"
/// scenario. A plugin-vs-plugin overlap and a plugin-vs-builtin overlap go through this one path
/// identically; there is no special-casing of builtins.
pub fn maybeShowFileTypeDialog(editor: *Editor, id: []const u8) !void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    const gpa = editor.app.gpa;
    const plugin = editor.app.host.pluginById(id) orelse return;

    var rows: std.ArrayListUnmanaged(Dialogs.FileTypeDefaults.Row) = .empty;
    errdefer {
        for (rows.items) |r| freeFileTypeDialogRow(gpa, r);
        rows.deinit(gpa);
    }

    for (plugin.fileTypes()) |ext| {
        // Resolve as if this plugin were not loaded: it registered before we got here, so a
        // plain `pluginForExtension` could simply answer "you". Done inline rather than as a new
        // SDK surface — this is the only call site that ever needs it.
        const prior = editor.app.extensionOwnerExcluding(ext, plugin) orelse continue;
        if (prior == plugin) continue;
        try editor.appendFileTypeDialogRow(&rows, plugin, ext, prior);
    }

    if (rows.items.len == 0) {
        rows.deinit(gpa);
        return;
    }
    // The dialog takes ownership of the rows (and frees them in its `callAfter`).
    Dialogs.FileTypeDefaults.request(plugin.id, plugin.display_name, try rows.toOwnedSlice(gpa));
}

fn freeFileTypeDialogRow(gpa: std.mem.Allocator, r: Dialogs.FileTypeDefaults.Row) void {
    gpa.free(r.ext);
    for (r.choices) |c| {
        gpa.free(c.id);
        gpa.free(c.name);
    }
    if (r.choices.len > 0) gpa.free(r.choices);
}

fn appendFileTypeChoice(
    gpa: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(Dialogs.FileTypeDefaults.Choice),
    id: []const u8,
    name: []const u8,
    is_builtin: bool,
) !void {
    const id_d = try gpa.dupe(u8, id);
    errdefer gpa.free(id_d);
    const name_d = try gpa.dupe(u8, name);
    errdefer gpa.free(name_d);
    try list.append(gpa, .{ .id = id_d, .name = name_d, .builtin = is_builtin });
}

fn fileTypeChoicesContain(choices: []const Dialogs.FileTypeDefaults.Choice, id: []const u8) bool {
    for (choices) |c| {
        if (std.mem.eql(u8, c.id, id)) return true;
    }
    return false;
}

/// One dialog row: the arriving plugin first (and pre-selected), then other loaded plugins that
/// offer `ext`, then fizzy's built-ins, then the fallback editor if it is not already in the
/// list. Every string is duped — `FileTypeDefaults` owns the row past this call, and a plugin
/// pointer would dangle the moment that dylib unloads.
fn appendFileTypeDialogRow(
    editor: *Editor,
    rows: *std.ArrayListUnmanaged(Dialogs.FileTypeDefaults.Row),
    arriving: *sdk.Plugin,
    ext: []const u8,
    prior: *sdk.Plugin,
) !void {
    const gpa = editor.app.gpa;
    const Choice = Dialogs.FileTypeDefaults.Choice;

    var choices: std.ArrayListUnmanaged(Choice) = .empty;
    errdefer {
        for (choices.items) |c| {
            gpa.free(c.id);
            gpa.free(c.name);
        }
        choices.deinit(gpa);
    }

    try appendFileTypeChoice(gpa, &choices, arriving.id, arriving.display_name, isBundledPluginId(arriving.id));

    var plugins: std.ArrayListUnmanaged(*sdk.Plugin) = .empty;
    defer plugins.deinit(gpa);
    var builtins: std.ArrayListUnmanaged(*sdk.Plugin) = .empty;
    defer builtins.deinit(gpa);

    for (editor.app.host.plugins.items) |p| {
        if (p == arriving) continue;
        if (p == editor.app.host.fallback_editor) continue;
        if (!editor.app.host.ownsExtension(p, ext)) continue;
        if (isBundledPluginId(p.id)) {
            try builtins.append(gpa, p);
        } else {
            try plugins.append(gpa, p);
        }
    }

    const by_id = struct {
        fn lt(_: void, a: *sdk.Plugin, b: *sdk.Plugin) bool {
            return std.mem.lessThan(u8, a.id, b.id);
        }
    }.lt;
    std.mem.sort(*sdk.Plugin, plugins.items, {}, by_id);
    std.mem.sort(*sdk.Plugin, builtins.items, {}, by_id);

    for (plugins.items) |p| {
        try appendFileTypeChoice(gpa, &choices, p.id, p.display_name, false);
    }
    for (builtins.items) |p| {
        try appendFileTypeChoice(gpa, &choices, p.id, p.display_name, true);
    }
    if (editor.app.host.fallback_editor) |text| {
        if (!fileTypeChoicesContain(choices.items, text.id)) {
            try appendFileTypeChoice(gpa, &choices, text.id, "Text (fallback)", true);
        }
    }

    var current: ?usize = null;
    for (choices.items, 0..) |c, i| {
        if (std.mem.eql(u8, c.id, prior.id)) {
            current = i;
            break;
        }
    }

    const owned = try choices.toOwnedSlice(gpa);
    errdefer {
        for (owned) |c| {
            gpa.free(c.id);
            gpa.free(c.name);
        }
        if (owned.len > 0) gpa.free(owned);
    }

    const ext_d = try gpa.dupe(u8, ext);
    errdefer gpa.free(ext_d);

    try rows.append(gpa, .{
        .ext = ext_d,
        .choices = owned,
        .current = current,
        .selected = 0,
    });
}

/// Reopen every *clean* document in `doc_ids` so it lands under whichever plugin now owns its
/// extension. Dirty documents are deliberately skipped and counted rather than closed — a
/// file-type preference must never be able to discard unsaved work; the caller tells the user
/// how many were left alone. Returns `.{ reopened, skipped_dirty }`.
pub fn reopenDocsUnderCurrentOwner(editor: *Editor, doc_ids: []const u64) struct { usize, usize } {
    const gpa = editor.app.gpa;
    var reopened: usize = 0;
    var skipped: usize = 0;
    for (doc_ids) |doc_id| {
        const doc = editor.app.open_files.get(doc_id) orelse continue;
        if (doc.owner.isDirty(doc)) {
            skipped += 1;
            continue;
        }
        // Both the path and the grouping live in the owner's image / bookkeeping, which the
        // close below tears down — copy them first.
        const path = gpa.dupe(u8, doc.owner.documentPath(doc)) catch continue;
        defer gpa.free(path);
        const grouping = doc.owner.documentGrouping(doc);
        editor.rawCloseFileID(doc_id) catch |err| {
            dvui.log.err("reopen '{s}': close failed: {s}", .{ path, @errorName(err) });
            continue;
        };
        _ = editor.openFilePath(path, grouping) catch |err| {
            dvui.log.err("reopen '{s}': open failed: {s}", .{ path, @errorName(err) });
            continue;
        };
        reopened += 1;
    }
    return .{ reopened, skipped };
}

/// Rebuild the whole window keybind map from scratch: fizzy binds + every *currently
/// registered* plugin's `contributeKeybinds`. Used after a plugin is unregistered so its
/// binds (whose key strings live in the soon-to-be-`dlclose`d image) are dropped. Also
/// called after the Keyboard Shortcuts pane writes `keybinds.zon`.
pub fn rebuildKeybinds(editor: *Editor) void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    const window = dvui.currentWindow();
    window.keybinds.clearRetainingCapacity();
    var defaults = editor.app.dvui_default_keybinds.iterator();
    while (defaults.next()) |kv| {
        window.keybinds.put(window.gpa, kv.key_ptr.*, kv.value_ptr.*) catch |err|
            dvui.log.err("keybind rebuild (dvui default '{s}') failed: {s}", .{ kv.key_ptr.*, @errorName(err) });
    }
    Keybinds.register() catch |err| dvui.log.err("keybind rebuild (fizzy) failed: {s}", .{@errorName(err)});
    for (editor.app.host.plugins.items) |plugin| {
        // No `@errorName` on anything a plugin returned: error values are numbered per
        // compilation, so the name this side would print is another compilation's error
        // entirely (see `Plugin.VTable`'s doc comment). The plugin logs its own reason.
        plugin.contributeKeybinds(window) catch
            dvui.log.err("keybind rebuild ('{s}') failed — see the plugin's own log", .{plugin.id});
    }
    // Lift the finished bind map into the command keymap that `Keybinds.tick` dispatches from.
    Keybinds.buildKeymap(editor) catch |err|
        dvui.log.err("keymap rebuild failed: {s}", .{@errorName(err)});
}

pub const UnloadError = error{ NotUnloadable, DirtyDocuments };

/// Load `{config}/plugins/{id}/{id}.{ext}` live and register it. Reuses the same loader +
/// dvui/render-bridge sync path as `loadUserPlugins`. Caller ensures `id` is not already
/// registered. On success the lib is appended to `loaded_plugin_libs`.
pub fn loadUserPluginById(editor: *Editor, id: []const u8) !void {
    if (comptime builtin.target.cpu.arch == .wasm32) return error.NotUnloadable;
    const path = try App.userPluginPath(editor.app.gpa, &editor.app, id);
    errdefer editor.app.gpa.free(path);

    const loaded = PluginLoader.loadAndRegister(&editor.app.host, editor.app.gpa, path, id, .{
        .gpa = &editor.app.gpa,
        .arg_b = @ptrCast(&editor.app.host),
        .arg_c = null,
    }) catch |err| {
        // Leave the same actionable record the startup scan leaves (see `recordLoadFailure`), so
        // a build that fails a live load stays visible in the store's installed pane with its
        // Reinstall/Uninstall controls instead of disappearing until the next restart.
        dvui.log.err("user plugin '{s}' ({s}): load failed: {s} — {s}", .{ id, path, @errorName(err), App.pluginLoadFailureReason(err) });
        editor.app.recordLoadFailure(id, path, err);
        return err;
    };
    try editor.app.appendLoadedPluginLib(loaded);
    App.syncLoadedPluginDvuiContexts(&editor.app);
    App.syncLoadedPluginRenderBridge(&editor.app);
    // The same one-time setup startup gives every plugin (`initPlugin`), now that this image
    // has the host's dvui globals — a plugin that spawns a worker or captures `dvui.io` there
    // must see the real one, not the `undefined` it had during `register`.
    for (editor.app.host.plugins.items) |p| {
        if (std.mem.eql(u8, p.id, id)) try p.initPlugin();
    }
    rebuildKeybinds(editor);
    fizzy.backend.rebuildDynamicNativeMenus();
    // The plugin now loads cleanly; drop any prior failure record so the store/dialog stop
    // showing it as broken (e.g. after installing a compatible rebuild over a mismatched one).
    editor.app.clearFailedUserPlugin(id);
}

/// What the web load/update pair can fail with. Spelled out rather than inferred: the two call
/// each other (a request for an id already running is an update), and inferred sets cannot.
pub const WebLoadError = UnloadError || error{ OutOfMemory, NotUnloadable };

/// Web: fetch and link a plugin built as a wasm side module from `url`, then register it
/// exactly as `loadUserPluginById` would — on the frame the page reports it linked. `id` is
/// what the plugin must declare. The URL is kept for the loaded-libs list.
pub fn loadWebPlugin(editor: *Editor, id: []const u8, url: []const u8) WebLoadError!void {
    if (comptime builtin.target.cpu.arch != .wasm32) return error.NotUnloadable;
    if (editor.app.host.pluginById(id) != null) {
        // Already running. Asked for from somewhere else — a different build of the same id —
        // that is an update, not a duplicate: hand the id to the new module (`updateWebPlugin`).
        for (editor.app.loaded_plugin_libs.items) |loaded| {
            if (!std.mem.eql(u8, loaded.plugin_id, id)) continue;
            if (std.mem.eql(u8, loaded.path, url)) return; // the very same build
            return editor.updateWebPlugin(id, url);
        }
        return;
    }
    return editor.beginWebPluginLoad(id, url, false);
}

/// The half of `loadWebPlugin` after the "is it already running" question, so an update can ask
/// for a build of an id that *is* running. `replace` says the plugin under this id is to be
/// handed over once the new module has passed every check (`WebPluginRequest.arrived`).
fn beginWebPluginLoad(editor: *Editor, id: []const u8, url: []const u8, replace: bool) WebLoadError!void {
    // Two requests for one id before the first lands (the page's remembered list and a
    // `?plugin=` of the same id, say) would register it twice; the second one waits for nothing.
    if (web_loads_in_flight.contains(id)) return;
    const gpa = editor.app.gpa;
    try web_loads_in_flight.put(gpa, try gpa.dupe(u8, id), {});
    const req = try gpa.create(WebPluginRequest);
    errdefer gpa.destroy(req);
    req.* = .{ .editor = editor, .id = try gpa.dupe(u8, id), .url = try gpa.dupe(u8, url), .replace = replace };
    _ = try PluginLoader.begin(gpa, req.id, req.url, WebPluginRequest.arrived, req);
}

const WebPluginRequest = struct {
    editor: *Editor,
    id: []u8,
    url: []u8,
    /// This build is taking over from one that is already running: the old plugin is unloaded
    /// only once the new module has passed every check, so a refused build costs nothing.
    replace: bool = false,

    fn arrived(ctx: ?*anyopaque, arrival: PluginLoader.Arrival) void {
        const req: *WebPluginRequest = @ptrCast(@alignCast(ctx.?));
        const editor = req.editor;
        const gpa = editor.app.gpa;
        var registered = false;
        defer {
            if (web_loads_in_flight.fetchRemove(req.id)) |kv| gpa.free(kv.key);
            if (!registered) PluginStore.webLoadFailed(req.id);
            gpa.free(req.id);
            gpa.destroy(req);
            // `url` lives on as `LoadedLib.path` when the load succeeded.
        }
        const lib = arrival.lib orelse {
            dvui.log.err("web plugin '{s}' ({s}): the page could not load it", .{ req.id, req.url });
            gpa.free(req.url);
            return;
        };

        // Everything that can refuse this build happens here, while the plugin it may be
        // replacing is still running and still owns its documents.
        const ready = PluginLoader.prepare(req.url, req.id, lib) catch |err| {
            dvui.log.err("web plugin '{s}' ({s}): refused: {s}", .{ req.id, req.url, @errorName(err) });
            gpa.free(req.url);
            return;
        };

        if (req.replace) {
            // `force = false`: a plugin with unsaved documents keeps them, and the update stays
            // on offer. The module just linked is wasted, which costs the page some memory and
            // the user nothing.
            editor.unloadPlugin(req.id, false) catch |err| {
                dvui.log.err("web plugin '{s}': cannot take over: {s}", .{ req.id, @errorName(err) });
                gpa.free(req.url);
                return;
            };
        }

        const loaded = ready.register(&editor.app.host, .{
            .gpa = &editor.app.gpa,
            .arg_b = @ptrCast(&editor.app.host),
            .arg_c = null,
        }) catch |err| {
            dvui.log.err("web plugin '{s}' ({s}): register failed: {s}", .{ req.id, req.url, @errorName(err) });
            gpa.free(req.url);
            return;
        };
        editor.app.appendLoadedPluginLib(loaded) catch {
            dvui.log.err("web plugin '{s}': out of memory storing LoadedLib", .{req.id});
            return;
        };
        registered = true;
        App.syncLoadedPluginDvuiContexts(&editor.app);
        App.syncLoadedPluginRenderBridge(&editor.app);
        for (editor.app.host.plugins.items) |p| {
            if (std.mem.eql(u8, p.id, req.id)) p.initPlugin() catch {
                dvui.log.err("web plugin '{s}': initPlugin failed — see the plugin's own log", .{req.id});
            };
        }
        rebuildKeybinds(editor);
        editor.rebuildExtensionOwnerCache();
        // Remembered here, not by the page when it linked the module: the page cannot know
        // whether this host will accept the build (fingerprint, SDK version, declared id), and a
        // remembered build that is refused would greet the user with the same failure every
        // visit. What is remembered is what ran.
        PluginLoader.remember(req.id, req.url);
        PluginStore.webLoadSucceeded(req.id);
        dvui.log.info("web plugin '{s}' loaded from {s}", .{ req.id, req.url });
        editor.app.host.refresh();
    }
};

/// The page asks for a plugin: `?plugin=<id>` on the URL (`plugins/<id>/<id>.wasm` beside
/// the app), or one it remembered from a store install (by its URL).
export fn FizzyWebPluginRequest(id_ptr: [*]const u8, id_len: usize, url_ptr: [*]const u8, url_len: usize) void {
    if (comptime builtin.target.cpu.arch != .wasm32) return;
    const editor = web_editor orelse return;
    const id = id_ptr[0..id_len];
    // The id reaches this from the page's query string, and with no URL it is interpolated
    // straight into a path. Same rule the plugins-directory scan applies on the desktop.
    if (!App.isValidPluginId(id)) {
        dvui.log.warn("web plugin request: '{s}' is not a valid plugin id", .{id});
        return;
    }
    // A plugin the user turned off stays off across reloads: the page remembers every plugin it
    // ever linked, and without this the disable would last exactly one visit.
    if (editor.app.isPluginDisabled(id)) return;
    var buf: [512]u8 = undefined;
    const url = if (url_len != 0) url_ptr[0..url_len] else std.fmt.bufPrint(&buf, "plugins/{s}/{s}.wasm", .{ id, id }) catch return;
    editor.loadWebPlugin(id, url) catch |err| dvui.log.err("web plugin '{s}': {s}", .{ id, @errorName(err) });
}
/// The page opens a file it fetched (`?open=<url>` — a zip vault for a demo, say) exactly as
/// an upload: by name and bytes, through the plugin that owns the extension.
export fn FizzyWebOpenBytes(name_ptr: [*]const u8, name_len: usize, bytes_ptr: [*]u8, bytes_len: usize) void {
    if (comptime builtin.target.cpu.arch != .wasm32) return;
    const editor = web_editor orelse return;
    const bytes = bytes_ptr[0..bytes_len];
    defer editor.app.gpa.free(bytes);
    const path = editor.app.gpa.dupe(u8, name_ptr[0..name_len]) catch return;
    if (editor.openFileFromBytes(path, bytes, 0)) |doc_id| {
        if (editor.app.open_files.getIndex(doc_id)) |idx| {
            editor.workbench.setActiveDocIndex(idx);
            editor.pending_composite_warmup = true;
        }
    } else |err| dvui.log.err("web: could not open {s}: {s}", .{ name_ptr[0..name_len], @errorName(err) });
    editor.app.host.refresh();
}

/// The one editor, for the page's calls. Set by `postInit` on the web.
var web_editor: ?*Editor = null;
/// Plugin ids the page is fetching for us right now.
var web_loads_in_flight: std.StringHashMapUnmanaged(void) = .empty;

/// Install (file already downloaded to the plugins dir by the store backend) + load live.
/// Writes `.plugins.<id>.enabled = true` immediately so the plugin stays enabled across restarts
/// (store installs auto-load; a manually dropped-in dylib does not — see R12).
pub fn installAndLoadPlugin(editor: *Editor, id: []const u8) !void {
    if (isBundledPluginId(id)) return error.NotUnloadable;
    if (editor.app.host.pluginById(id) != null) return; // already loaded
    editor.app.untrackDisabledPlugin(id);
    try editor.setPluginEnabledPersisted(id, true);
    try editor.loadUserPluginById(id);
    editor.rebuildExtensionOwnerCache();
    try editor.maybeShowFileTypeDialog(id);
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
    defer owned.deinit(editor.app.gpa);
    {
        var it = editor.loading_jobs.valueIterator();
        while (it.next()) |job_ptr| {
            if (job_ptr.*.owner == plugin) owned.append(editor.app.gpa, job_ptr.*) catch {};
        }
    }

    for (owned.items) |job| {
        // Block until the worker has fully left the dylib before we free through the owner —
        // a futex wait on the job's `Future` (see `Editor.openFilePath`), not the
        // `std.Thread.yield()` busy-spin this replaced.
        if (job.future) |*f| f.await(io);
        _ = editor.loading_jobs.remove(job.path);
        // Drop the partial open without inserting it into `open_files`. Only `ready` holds a
        // constructed document needing exactly one `deinitDocumentBuffer`.
        switch (job.currentPhase()) {
            .ready => job.owner.deinitDocumentBuffer(job.doc_buf.ptr),
            // `failed` never constructed a document (see `processLoadingJobs`); `cancelled`
            // was freed by the worker or never built.
            else => {},
        }
        job.destroy(io);
    }
}

/// Unload a runtime user plugin live: close its documents, tear down its contributions,
/// deinit its state, then `dlclose`. With `force == false`, aborts with `DirtyDocuments`
/// if any owned document is dirty (the caller decides whether to prompt/save first).
/// On the web this unregisters the plugin without unmapping anything: a side module cannot leave
/// the page's function table, so its code and data stay resident for the rest of the visit, inert.
/// That is the whole difference — every other step (dirty documents, in-flight saves and loads,
/// documents closed, contributions withdrawn, `deinit`) is the same, and `WebDynLib.close` is a
/// no-op. Slices into the image stay readable afterwards, which is what makes the desktop's
/// "persist before unload" hazard a non-issue here.
pub fn unloadPlugin(editor: *Editor, id: []const u8, force: bool) UnloadError!void {
    if (!editor.isUnloadablePlugin(id)) return error.NotUnloadable;
    const plugin = editor.app.host.pluginById(id) orelse return error.NotUnloadable;

    const lib_index: usize = blk: {
        for (editor.app.loaded_plugin_libs.items, 0..) |loaded, i| {
            if (std.mem.eql(u8, loaded.plugin_id, id)) break :blk i;
        }
        return error.NotUnloadable;
    };

    if (!force and editor.app.pluginHasDirtyDocs(plugin)) return error.DirtyDocuments;

    // Let in-flight async saves finish while the owning `File` records still exist.
    editor.app.waitForPluginSaves(plugin);

    // Cancel + await any in-flight file loads owned by this plugin so no worker calls into
    // the dylib after we `dlclose` it below.
    editor.cancelPluginLoadingJobs(plugin);

    // Close every document this plugin owns. Collect ids first — closing mutates
    // `open_files` underneath us.
    var owned: std.ArrayListUnmanaged(u64) = .empty;
    defer owned.deinit(editor.app.gpa);
    for (editor.app.open_files.values()) |doc| {
        if (doc.owner == plugin) owned.append(editor.app.gpa, doc.id) catch {};
    }
    for (owned.items) |doc_id| editor.rawCloseFileID(doc_id) catch |err|
        dvui.log.err("unloadPlugin '{s}': closing doc {d} failed: {s}", .{ id, doc_id, @errorName(err) });

    // Drop empty workspace panes (and plugin canvas chrome) before plugin `deinit`.
    editor.rebuildWorkspaces() catch |err|
        dvui.log.err("unloadPlugin '{s}': rebuildWorkspaces failed: {s}", .{ id, @errorName(err) });

    // Remove all contributions + services + active-id references (before dlclose), then
    // run the plugin's own teardown.
    editor.app.host.unregisterPlugin(plugin);
    // The bottom panel borrows `BottomView.id` slices (grouping keys, per-split active tab)
    // that live in the image we're about to unmap — drop them while they're still readable.
    editor.panel.forgetUnregisteredSurfaces(&editor.app.host);
    fizzy.backend.rebuildDynamicNativeMenus();
    plugin.deinit();

    // Drop the unloaded plugin's keybinds by rebuilding from the survivors.
    rebuildKeybinds(editor);

    // Unmap the image and free our bookkeeping for it.
    var loaded = editor.app.loaded_plugin_libs.orderedRemove(lib_index);
    loaded.lib.close();
    editor.app.gpa.free(loaded.plugin_id);
    editor.app.gpa.free(loaded.path);
}

/// Enable or disable a plugin, persisting the choice and applying it live: disabling
/// unloads now; enabling loads the installed dylib now.
pub fn setPluginEnabled(editor: *Editor, id: []const u8, enabled: bool, force: bool) !void {
    if (isBundledPluginId(id)) return error.NotUnloadable;

    // Read before `setPluginEnabledPersisted` settles it: enabling a plugin fizzy has never been
    // told to run is the same event as installing one from the store, so it gets the same
    // file-association prompt at the end (see `maybeShowFileTypeDialog`'s scoping note — this is
    // a genuine install-equivalent, not the startup load path).
    const first_load = enabled and editor.app.isPluginUndecided(id);

    if (enabled) {
        editor.app.untrackDisabledPlugin(id);
        try editor.setPluginEnabledPersisted(id, true);
        if (editor.app.host.pluginById(id) == null) {
            if (comptime builtin.target.cpu.arch == .wasm32) {
                // No plugins directory to look in: what the page remembers for this id *is* the
                // installed build. A plugin disabled and re-enabled in one session takes this
                // path, as does one the user turns back on after a reload.
                var buf: [1024]u8 = undefined;
                const url = PluginLoader.rememberedUrl(id, &buf) orelse return error.NotUnloadable;
                try editor.loadWebPlugin(id, url);
            } else {
                try editor.loadUserPluginById(id);
            }
        }
    } else {
        // Persist before unload: `id` may point at static memory inside the plugin image.
        try editor.app.trackDisabledPlugin(id);
        try editor.setPluginEnabledPersisted(id, false);
        if (editor.app.host.pluginById(id) != null) try editor.unloadPlugin(id, force);
    }
    // The *cache* drops (or regains) this plugin's claims immediately; `settings.zon` keeps
    // remembering them non-destructively, so re-enabling restores ownership with no re-prompt.
    editor.rebuildExtensionOwnerCache();
    if (first_load) try editor.maybeShowFileTypeDialog(id);
}

/// Replace an installed plugin with a freshly downloaded build (in the plugins dir already)
/// by unloading then reloading. `force` controls dirty-document handling on the unload.
/// Deliberately does **not** raise the file-type prompt: an update is the same plugin the user
/// already answered for, and re-asking on every store update (or every `zig build` of a plugin
/// you are developing, via `reconcileChangedPluginBinaries`) would be pure nagging. The prompt
/// belongs to arrival — a store install, or the first load of a dropped-in build — and uninstall
/// is what makes a plugin able to arrive again (`clearPluginOwnershipRecord`).
///
/// The gap this leaves on purpose: an update that starts offering a *new* extension does not
/// prompt. It falls through the normal resolution order (unique claimant, else the fallback
/// editor), and Settings > File Types is where to override it.
/// The web's update: link the new build alongside the old one and hand the id over. The page
/// cannot unlink what it linked, so the previous module's code and data stay resident for the
/// rest of the visit — a version's worth of memory per update, which is the price of not making
/// the user reload. The new URL is remembered only once the new module has actually registered
/// (`WebPluginRequest.arrived`), so a build this host refuses leaves the next visit pointed at
/// the one that worked.
pub fn updateWebPlugin(editor: *Editor, id: []const u8, url: []const u8) WebLoadError!void {
    if (comptime builtin.target.cpu.arch != .wasm32) return error.NotUnloadable;
    if (editor.app.host.pluginById(id)) |plugin| {
        // Asked here, before anything is fetched, so the answer is a refusal the store can show
        // beside an offer that is still standing — not a surprise after the running plugin is
        // already gone. Asked again at the swap, where the documents are actually closed.
        if (editor.app.pluginHasDirtyDocs(plugin)) return error.DirtyDocuments;
    }
    try editor.beginWebPluginLoad(id, url, true);
}

pub fn updatePlugin(editor: *Editor, id: []const u8, force: bool) !void {
    if (isBundledPluginId(id)) return error.NotUnloadable;
    try editor.unloadPlugin(id, force);
    try editor.loadUserPluginById(id);
    editor.rebuildExtensionOwnerCache();
}

/// Fully remove a user plugin: unload it if loaded, clear any disabled flag, and delete its
/// whole `{config}/plugins/{id}/` directory — not just the dylib, since that directory is also
/// where the plugin may have stored its own assets/data (see `Host.pluginInstallDir`). Note that
/// the plugin's own *settings* (`.plugins.<id>` in `settings.zon`) deliberately survive this, same
/// as before R10 — see `docs/PLUGINS.md`'s "only the dylib/directory is deleted on uninstall"
/// note, so reinstalling later restores the old configuration. `force` controls dirty-document
/// handling on the unload.
pub fn uninstallPlugin(editor: *Editor, id: []const u8, force: bool) !void {
    if (comptime builtin.target.cpu.arch == .wasm32) {
        // The module itself stays in the page — nothing can unlink it — but the plugin goes now,
        // and the page forgets it so the next visit does not bring it back.
        PluginLoader.forget(id);
        editor.unloadPlugin(id, force) catch |err| switch (err) {
            error.NotUnloadable => {}, // already gone
            else => return err,
        };
        editor.rebuildExtensionOwnerCache();
        return;
    }
    if (isBundledPluginId(id)) return error.NotUnloadable;
    if (editor.app.host.pluginById(id) != null) try editor.unloadPlugin(id, force);
    // Drop runtime disabled bookkeeping — the plugin no longer exists to be disabled. Its
    // `.plugins.<id>` settings block deliberately survives (reinstall restores config); a
    // later store install writes `.enabled = true` fresh.
    editor.app.untrackDisabledPlugin(id);
    editor.app.untrackUndecidedPlugin(id);
    // Uninstall is the one lifecycle event that resets "we have already asked about this plugin".
    editor.clearPluginOwnershipRecord(id);

    const plugin_dir = try std.fs.path.join(editor.app.gpa, &.{ editor.app.config_folder, "plugins", id });
    defer editor.app.gpa.free(plugin_dir);
    std.Io.Dir.cwd().deleteTree(dvui.io, plugin_dir) catch |err|
        dvui.log.warn("uninstallPlugin '{s}': could not delete {s}: {s}", .{ id, plugin_dir, @errorName(err) });
    // A broken (failed-to-load) build can be uninstalled too; clear its failure record so the
    // card disappears instead of lingering as "Failed".
    editor.app.clearFailedUserPlugin(id);
    editor.rebuildExtensionOwnerCache();
}

fn storeUninstalled(arena: std.mem.Allocator) []const @import("app").layout.State.StoreOffer {
    const raw = PluginStore.uninstalledCatalog(arena);
    const out = arena.alloc(@import("app").layout.State.StoreOffer, raw.len) catch return &.{};
    for (raw, out) |r, *o| o.* = .{ .id = r.id, .title = r.title };
    return out;
}

pub fn postInit(editor: *Editor) !void {
    if (comptime build_opts.has_app_layout) {
        dvui.log.info("layout: app-supplied", .{});
    } else {
        dvui.log.info("layout: fizzy", .{});
    }
    editor.app.layout.store_catalog = .{
        .uninstalled = storeUninstalled,
        .install = PluginStore.queueInstall,
        .installing = PluginStore.isInstalling,
    };

    if (comptime builtin.target.cpu.arch != .wasm32) {
        if (std.process.Environ.getAlloc(fizzy.core.platform.processEnviron(), editor.app.gpa, "FIZZY_SPLIT_DEBUG")) |v| {
            editor.app.gpa.free(v);
            core.widgets.Split.debug = true;
            dvui.log.info("layout: split debug logging on", .{});
        } else |_| {}
    }
    sdk.installRuntime(&editor.app.gpa, &editor.app.host, null);

    // Fizzy commands must be registered against the Editor's *final* address — `init` returns
    // an Editor by value, so a pointer taken there would dangle the moment it's moved.
    try Keybinds.registerCommands(editor);

    // Install fizzy's read/utility surface so plugins reach shared fizzy state
    // (per-frame arena, project folder, content opacity, settings dirty-mark) through
    // the Host instead of importing the concrete Editor.
    editor.app.host.installFizzyApi(.{ .ctx = editor, .vtable = &fizzy_api_vtable });

    // Publish the shared file set. Same reason as the commands above: `env.ctx` is this
    // editor's final address. The table answers three questions it can't itself — where the
    // project is, whether the watcher is live, which paths are ignored — and in exchange holds
    // the caches every plugin that draws files then shares.
    editor.doc_io = DocumentIo.init(editor);
    editor.app.file_table.env = .{
        .ctx = editor,
        .root = fileTableRoot,
        .watching = fileTableWatching,
        .refresh = fileTableRefresh,
        .unmounting = fileTableUnmounting,
        .ignored = fileTableIgnored,
    };
    editor.app.host.files = &editor.app.file_table;
    // The web transport's JS callbacks are wasm exports, which exist only if the file is
    // analysed; a plugin that mounts a cloud drive is what uses it, but the page must have
    // the exports whether or not one is bundled.
    if (comptime builtin.target.cpu.arch == .wasm32) {
        comptime {
            _ = fizzy.core.transport.Web;
            _ = fizzy.core.transport.WebOAuth;
        }
    }

    // Register plugin contributions (sidebar/bottom/center/menus). These are the
    // near-empty fizzy's content: it iterates the Host registries rather than
    // hardcoding panes. Web-safe — the draw fns reach the same inline code the
    // editor tick already runs on wasm. Order = sidebar order.
    // Every bundled plugin: its dylib beside the exe when there is one, else the copy linked
    // in. None of the bundled four ship as dylibs today, so the load "fails" and the static
    // copy registers on every run; not worth logging until that changes. The workbench's
    // dylib entry takes the workbench state fizzy still holds as `arg_c`.
    inline for (bundled_plugins) |m| {
        const extra: ?*anyopaque = if (comptime std.mem.eql(u8, m.plugin_id, "workbench")) @ptrCast(&editor.workbench) else null;
        if (App.bundledDylibEnabled(editor.app.gpa, m.plugin_id)) {
            editor.app.loadBundledDylib(fizzy.entry().root_path, m.plugin_id, extra) catch {
                try m.register(&editor.app.host);
            };
        } else {
            try m.register(&editor.app.host);
        }
    }

    // Seed the runtime disabled / auto-update-off sets from settings before scanning, so
    // disabled plugins are skipped at startup and the store's auto-update pass already knows
    // which plugins opted out.
    editor.seedPluginFlags();
    // User-installed plugins from `<config>/plugins/{id}.{dylib,so,dll}`.
    editor.loadUserPlugins(editor.app.config_folder);

    // Now that the loaded-plugin set is final, interpret the persisted `.extensions` lists into
    // the routing cache `Host.pluginForExtension` reads. Read-only — see its doc comment.
    editor.rebuildExtensionOwnerCache();

    for (editor.app.host.plugins.items) |p| try p.initPlugin();
    if (comptime builtin.target.cpu.arch == .wasm32) {
        web_editor = editor;
        PluginLoader.init(editor.app.gpa);
    }

    // Fizzy built-in: Plugin store (owner = null; not a plugin). Registered just before
    // Settings so its icon sits directly above the cog in the sidebar rail.
    try PluginStore.register(editor.pluginManager());

    // Fizzy built-in: Settings (owner = null; not a plugin).
    try editor.app.host.registerSurface(.{
        .id = view_settings,
        .icon = .{ .tvg = dvui.entypo.cog },
        .title = "Settings",
        .keywords = sdk.keywords.ide.sidebar,
        .draw = drawSettingsPane,
    });

    // Fizzy built-in: Output (owner = null; not a plugin). `persistent` keeps it visible
    // even with no document open, since it's a diagnostic view, not a per-file one.
    try editor.app.host.registerSurface(.{
        .id = "fizzy.output",
        .title = "Output",
        .keywords = sdk.keywords.ide.panel,
        .persistent = true,
        .draw = OutputPanel.draw,
    });

    // Menu bar contributions (non-macOS in-app bar). The File/Edit draw bodies still live
    // in fizzy's `Menu.zig`; a later step could move them into the workbench / pixel-art
    // plugins so those self-register. Order = bar order.
    // One registration per `menu_model.menu_bar` entry, all pointing at the same generic
    // renderer with the model node as `ctx`. There is no longer a per-menu draw function that
    // could disagree with the macOS builder walking the same tree.
    inline for (&menu_model.menu_bar) |*sub| {
        try editor.app.host.registerMenu(.{
            .id = sub.id,
            .title = sub.title,
            .draw = Menu.drawModelMenu,
            .ctx = @ptrCast(@constCast(sub)),
        });
    }

    // Keybind contributions: each plugin registers its own binds into the window's
    // keybind map. Fizzy already registered its global/navigation/region binds
    // in `Keybinds.register` (during `init`, before this runs), so the two halves
    // are disjoint — no `putNoClobber` clash. Runs on all targets (web included).
    App.syncLoadedPluginDvuiContexts(&editor.app);
    const window = dvui.currentWindow();
    for (editor.app.host.plugins.items) |plugin| try plugin.contributeKeybinds(window);
    // Startup's only pass over the finished bind map. `rebuildKeybinds` covers later plugin
    // load/unload, but it never runs during boot — without this the keymap stays empty and no
    // fizzy shortcut works until a plugin happens to be reloaded.
    try Keybinds.buildKeymap(editor);

    // The workbench-api is the file explorer's programmatic surface and drives OS
    // file management (open/create/rename/delete/move on disk). The web build has
    // no filesystem API, so the workbench *service* is left out there for now.
    // Keeping it behind a comptime gate also keeps its native-only fn bodies out of
    // wasm analysis entirely (the codebase's dead-branch convention; see
    // `web_main.zig`).
    if (comptime builtin.target.cpu.arch != .wasm32) {
        editor.workbench.initService(&editor.app.host);
        try editor.app.host.registerService(
            Workbench.Api,
            &editor.workbench.api,
            editor.app.host.pluginById("workbench"),
        );
    }

    // Fizzy's own `files` service: create/rename/delete/move with open documents kept in step.
    // Registered by the app, not built into the contract — see `FilesService.zig`.
    //
    // Not on the web, which has no filesystem to manage: the file tree there is read-only, and a
    // plugin asking for this service simply does not get one — which is the degradation every
    // caller already handles. The comptime guard also keeps the implementation out of the wasm
    // build entirely, since taking a function's address forces its analysis.
    if (comptime builtin.target.cpu.arch != .wasm32) {
        editor.app.files_service = FilesService.api(editor);
        try editor.app.host.registerService(sdk.services.files.Api, &editor.app.files_service, null);
    }

    // Live external-edit reconciliation for settings.zon + dropped-in plugin discovery (see
    // R11/R12 in docs/PLUGIN_MANIFEST_PLAN.md). Must happen here, in `postInit`, not `init` —
    // nightwatch retains `&editor.app.settings_watcher.handler`, so `editor` has to already be at
    // its final heap address (see `SettingsWatcher.start`'s doc comment). Best-effort
    // throughout: fizzy must never fail to launch just because the watcher couldn't start.
    if (comptime builtin.target.cpu.arch != .wasm32) {
        // Before any watcher starts: a watcher thread has buffered something and the UI thread
        // may be parked in the event loop with nothing to draw. `app/watch/` does not know whose
        // window that is; this is the app answering once.
        Watch.wake.setHook(wakeEventLoop);

        editor.app.settings_watcher = SettingsWatcher.init(editor.app.gpa, editor.app.config_folder) catch |err| blk: {
            dvui.log.warn("settings watcher: failed to init ({s}); external hand-edits / dropped-in plugins won't be picked up live", .{@errorName(err)});
            break :blk null;
        };
        if (editor.app.settings_watcher) |*w| {
            w.start() catch |err| {
                dvui.log.warn("settings watcher: failed to start ({s}); external hand-edits / dropped-in plugins won't be picked up live", .{@errorName(err)});
                w.stop();
                editor.app.settings_watcher = null;
            };
        }

        // Open-document external-change watching (reload clean tabs; conflict dialog on save).
        editor.document_watcher = DocumentWatcher.init(editor.app.gpa);
        if (editor.document_watcher) |*w| {
            w.start() catch |err| {
                dvui.log.warn("document watcher: failed to start ({s}); open files won't pick up external edits live", .{@errorName(err)});
                w.stop();
                editor.document_watcher = null;
            };
        }

        // Project-wide on-disk change broadcast for plugins (`folderPathsChanged`). Only the
        // buffers are set up here; the watch itself is armed by `setProjectFolder`, which may
        // already have run — hence the catch-up call below.
        editor.app.folder_watcher = FolderWatcher.init(editor.app.gpa) catch |err| blk: {
            dvui.log.warn("folder watcher: failed to init ({s}); plugins won't be told about on-disk changes", .{@errorName(err)});
            break :blk null;
        };
        if (editor.app.folder_watcher) |*w| {
            if (editor.app.folder) |f| w.setFolder(f);
        }
    }
}

/// The Settings sidebar view: a single searchable tree (`SettingsTree`) whose "Fizzy" branch
/// carries fizzy's own categories (`Explorer.settings.groups`) and whose remaining branches
/// are one per plugin — loaded plugins' schema fields drawn by `PluginSettingsPane.drawField`,
/// failed plugins' failure reason.
fn drawSettingsPane(_: ?*anyopaque) anyerror!dvui.App.Result {
    try SettingsTree.draw();
    return .ok;
}

// ---- EditorAPI: fizzy-provided read/utility surface for plugins ----------
// Installed on the Host in `postInit`; `ctx` is this `*Editor`.

const fizzy_api_vtable: sdk.EditorAPI.VTable = .{
    .arena = fizzyArena,
    .extensionOwnerOverride = fizzyExtensionOwnerOverride,
    .folder = fizzyFolder,
    .paletteFolder = fizzyPaletteFolder,
    .getSecret = fizzyGetSecret,
    .setSecret = fizzySetSecret,
    .markSettingsDirty = fizzyMarkSettingsDirty,
    .contentOpacity = fizzyContentOpacity,
    .dialogWindow = fizzyDialogWindow,
    .frostPane = fizzyFrostPane,
    .isMaximized = fizzyIsMaximized,
    .isMacOS = fizzyIsMacOS,
    .appliesNativeWindowOpacity = fizzyAppliesNativeWindowOpacity,
    .panZoomScheme = fizzyPanZoomScheme,
    .explorerRect = fizzyExplorerRect,
    .explorerVirtualSize = fizzyExplorerVirtualSize,
    .showSaveDialog = fizzyShowSaveDialog,
    .activeDoc = fizzyActiveDoc,
    .docByIndex = fizzyDocByIndex,
    .docById = fizzyDocById,
    .docIndex = fizzyDocIndex,
    .openDocCount = fizzyOpenDocCount,
    .setActiveDocIndex = fizzySetActiveDocIndex,
    .allocDocId = fizzyAllocDocId,
    .explorerViewportWidth = fizzyExplorerViewportWidth,
    .docFromPath = fizzyDocFromPath,
    .openFilePath = fizzyOpenFilePath,
    .openOrFocusFileAtGrouping = fizzyOpenOrFocusFileAtGrouping,
    .revealPosition = fizzyRevealPosition,
    .beginRegion = fizzyBeginRegion,
    .drawRegionContents = fizzyDrawRegionContents,
    .endRegion = fizzyEndRegion,
    .regionMatching = fizzyRegionMatching,
    .regionSelected = fizzyRegionSelected,
    .regionSelect = fizzyRegionSelect,
    .assignSurfaces = fizzyAssignSurfaces,
    .assignedSurfaces = fizzyAssignedSurfaces,
    .assignedRegionNames = fizzyAssignedRegionNames,
    .selectInRegion = fizzySelectInRegion,
    .drawFileKindGlyph = fizzyDrawFileKindGlyph,
    .closeDocById = fizzyCloseDocById,
    .setProjectFolder = fizzySetProjectFolder,
    .closeProjectFolder = fizzyCloseProjectFolder,
    .recentFolderCount = fizzyRecentFolderCount,
    .recentFolderAt = fizzyRecentFolderAt,
    .openInFileBrowser = fizzyOpenInFileBrowser,
    .isPathIgnored = fizzyIsPathIgnored,
    .folderWatchActive = fizzyFolderWatchActive,
    .explorerBranchIsOpen = fizzyExplorerBranchIsOpen,
    .setExplorerBranchOpen = fizzySetExplorerBranchOpen,
    .drawWorkspaces = fizzyDrawWorkspaces,
    .showOpenFolderDialog = fizzyShowOpenFolderDialog,
    .showOpenFileDialog = fizzyShowOpenFileDialog,
    .save = fizzySave,
    .requestPrepareFrame = fizzyRequestCompositeWarmup,
    .refresh = fizzyRefresh,
    .allocUntitledPath = fizzyAllocUntitledPath,
    .createDocument = fizzyCreateDocument,
    .setExplorerNewFilePath = fizzySetExplorerNewFilePath,
    .requestSaveAs = fizzyRequestSaveAs,
    .requestWebSave = fizzyRequestWebSave,
    .cancelPendingSaveDialog = fizzyCancelPendingSaveDialog,
    .setPendingCloseDocId = fizzySetPendingCloseDocId,
    .queueCloseAfterSave = fizzyQueueCloseAfterSave,
    .trackQuitSaveInFlight = fizzyTrackQuitSaveInFlight,
    .resumeSaveAllQuit = fizzyResumeSaveAllQuit,
    .abortSaveAllQuit = fizzyAbortSaveAllQuit,
    .logLine = fizzyLogLine,
    .drawMenuItem = fizzyDrawMenuItem,
    .loadPluginSettingsFile = fizzyLoadPluginSettingsFile,
};

fn fizzyLogLine(ctx: *anyopaque, level: std.log.Level, scope: []const u8, message: []const u8) void {
    _ = ctx;
    fizzy.OutputLog.appendLine(level, scope, message);
}

/// See `EditorAPI.VTable.drawMenuItem`'s doc comment for why this widget construction has to
/// happen here (in fizzy) rather than in the calling plugin.
///
/// `enabled` is read straight off the registered `Command` (absent `isEnabled` = enabled) rather
/// than threaded through the vtable as its own parameter, so a plugin section's row can be greyed
/// out — same as fizzy's own menu rows (`Menu.menuItemWithHotkey`) — without an SDK/ABI
/// change: `Host.commandEnabled` already existed for the command palette. A plugin draws its
/// row unconditionally and gets correct greying for free, on both menu bars.
///
/// Draws no separator of its own — `Menu.drawMenuSections` draws exactly one ahead of the whole
/// plugin-contributed group for a menu, not one per row, or every greyed-out row would look
/// like its own group.
fn fizzyDrawMenuItem(ctx: *anyopaque, title: []const u8, command_id: ?[]const u8) bool {
    const editor = fizzyCtx(ctx);
    const enabled = if (command_id) |id| editor.app.host.commandEnabled(id) else true;
    // Same command lookup `commandEnabled` above just did — reused here for the icon rather than
    // threaded through the vtable as its own parameter, same reasoning as `enabled`: additive on
    // `sdk.Command` (a plain data struct plugins already construct), not a vtable/ABI change.
    const icon: ?[]const u8 = if (command_id) |id| blk: {
        const c = editor.app.host.command(id) orelse break :blk null;
        break :blk c.icon;
    } else null;
    // Same resolution fizzy's own menu rows use (`Menu.hotkeyFor`), so a plugin row and a
    // fizzy row bound to the same chord can never disagree about what to display.
    const kb: dvui.enums.Keybind = if (command_id) |id|
        Keybinds.menuKeybindFor(editor, id)
    else
        .{};
    // A row in the account flyout (`Accounts`) is a popover row, not a dvui menu item.
    if (Accounts.drawing_rows) return Accounts.drawMenuRow(title, icon, kb, enabled);
    var mi = dvui.menuItem(@src(), .{}, .{
        .expand = .horizontal,
        // `Wyhash.hash` always returns `u64`; `id_extra` is `usize`, which is 32-bit on
        // wasm32 — truncate rather than relying on the width match that only holds natively.
        .id_extra = @truncate(std.hash.Wyhash.hash(0, title)),
    });
    defer mi.deinit();
    const clicked = enabled and mi.activeRect() != null;
    const id_extra: usize = @truncate(std.hash.Wyhash.hash(0, title));
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = id_extra });
    defer row.deinit();
    fizzy.core.draw.menuRowIcon(icon, dvui.themeGet().color(.window, .text), enabled, id_extra);
    fizzy.core.draw.labelWithKeybind(title, kb, enabled, .{ .expand = .horizontal }, .{ .expand = .horizontal });
    return clicked;
}

/// See `EditorAPI.VTable.loadPluginSettingsFile`'s doc comment for why this must run here
/// (fizzy's own compiled code) rather than inside `Host.loadPluginSettings` directly.
/// Reads the whole merged `<config>/settings.zon` and pulls out just `id`'s
/// `.plugins.<id>.settings` blob (R12 nested shape — author fields live under `.settings` so
/// they can never collide with fizzy-reserved `.enabled`).
fn fizzyLoadPluginSettingsFile(ctx: *anyopaque, id: []const u8) ?[]u8 {
    // Wasm: no filesystem; `fizzy.core.fs.readZ` uses `Io.Dir.cwd()` (posix.AT), which doesn't exist
    // for this target — `Host.loadPluginSettings` already short-circuits before ever calling
    // through to here, but this vtable entry is still type-checked for every target regardless.
    if (comptime builtin.target.cpu.arch == .wasm32) return null;
    const editor = fizzyCtx(ctx);
    const path = std.fs.path.join(editor.app.gpa, &.{ editor.app.config_folder, "settings.zon" }) catch return null;
    defer editor.app.gpa.free(path);
    const data = fizzy.core.fs.readZ(editor.app.host.allocator, dvui.io, path) catch return null;
    defer editor.app.host.allocator.free(data);
    return App.readPluginSettingsText(editor.app.host.allocator, data, id);
}

fn fizzyCtx(ctx: *anyopaque) *Editor {
    return @ptrCast(@alignCast(ctx));
}
fn fizzyArena(ctx: *anyopaque) std.mem.Allocator {
    return fizzyCtx(ctx).app.arena.allocator();
}

fn fizzyExtensionOwnerOverride(ctx: *anyopaque, ext: []const u8) ?[]const u8 {
    const editor: *Editor = @ptrCast(@alignCast(ctx));
    return editor.app.extension_owner.get(ext);
}
fn fizzyFolder(ctx: *anyopaque) ?[]const u8 {
    return fizzyCtx(ctx).app.folder;
}
fn fizzyPaletteFolder(ctx: *anyopaque) ?[]const u8 {
    return fizzyCtx(ctx).app.palette_folder;
}
fn fizzyGetSecret(ctx: *anyopaque, key: []const u8) ?[]const u8 {
    return fizzyCtx(ctx).app.secrets.get(key);
}
fn fizzySetSecret(ctx: *anyopaque, key: []const u8, value: []const u8) anyerror!void {
    return fizzyCtx(ctx).app.secrets.set(key, value);
}
fn fizzyMarkSettingsDirty(ctx: *anyopaque) void {
    fizzyCtx(ctx).markSettingsDirty();
}
fn fizzyDialogWindow(_: *anyopaque) dvui.Dialog.DisplayFn {
    return &fizzy.core.dialogs.dialogWindow;
}

fn fizzyFrostPane(_: *anyopaque, id: dvui.Id, rect: dvui.Rect.Physical, corners: dvui.CornerRect, scale: f32) bool {
    return fizzy.core.dialogs.frostPane(id, rect, corners, scale);
}

fn fizzyContentOpacity(ctx: *anyopaque) f32 {
    return fizzyCtx(ctx).app.settings.content_opacity;
}
fn fizzyIsMaximized(ctx: *anyopaque) bool {
    _ = ctx;
    return fizzy.backend.isMaximized(dvui.currentWindow());
}
fn fizzyIsMacOS(_: *anyopaque) bool {
    return fizzy.core.platform.isMacOS();
}
fn fizzyAppliesNativeWindowOpacity(_: *anyopaque) bool {
    if (comptime builtin.target.cpu.arch == .wasm32) return false;
    return builtin.os.tag == .macos or builtin.os.tag == .windows;
}
fn fizzyPanZoomScheme(ctx: *anyopaque) sdk.EditorAPI.PanZoomScheme {
    const editor = fizzyCtx(ctx);
    return switch (Settings.resolvedPanZoomScheme(&editor.app.settings, fizzy.core.platform.isMacOS())) {
        .mouse => .mouse,
        .trackpad => .trackpad,
    };
}
fn fizzyExplorerRect(ctx: *anyopaque) dvui.Rect {
    return fizzyCtx(ctx).explorer.rect;
}
fn fizzyExplorerVirtualSize(ctx: *anyopaque) dvui.Size {
    return fizzyCtx(ctx).explorer.scroll_info.virtual_size;
}
fn fizzyShowSaveDialog(
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
fn fizzyActiveDoc(ctx: *anyopaque) ?sdk.DocHandle {
    return fizzyCtx(ctx).activeDoc();
}
fn fizzyDocByIndex(ctx: *anyopaque, index: usize) ?sdk.DocHandle {
    return fizzyCtx(ctx).app.docAt(index);
}
fn fizzyDocById(ctx: *anyopaque, id: u64) ?sdk.DocHandle {
    return fizzyCtx(ctx).app.docById(id);
}
fn fizzyDocIndex(ctx: *anyopaque, id: u64) ?usize {
    return fizzyCtx(ctx).app.open_files.getIndex(id);
}
fn fizzyOpenDocCount(ctx: *anyopaque) usize {
    return fizzyCtx(ctx).app.open_files.count();
}
fn fizzySetActiveDocIndex(ctx: *anyopaque, index: usize) void {
    fizzyCtx(ctx).workbench.setActiveDocIndex(index);
}
fn fizzyAllocDocId(ctx: *anyopaque) u64 {
    return fizzyCtx(ctx).app.newFileID();
}
fn fizzyExplorerViewportWidth(ctx: *anyopaque) f32 {
    return fizzyCtx(ctx).explorer.scroll_info.viewport.w;
}
fn fizzyDocFromPath(ctx: *anyopaque, path: []const u8) ?sdk.DocHandle {
    return fizzyCtx(ctx).docFromPath(path);
}
fn fizzyOpenFilePath(ctx: *anyopaque, path: []const u8, grouping: u64) anyerror!bool {
    return fizzyCtx(ctx).openFilePath(path, grouping);
}
fn fizzyOpenOrFocusFileAtGrouping(ctx: *anyopaque, path: []const u8, grouping: u64) anyerror!?usize {
    return fizzyCtx(ctx).openOrFocusFileAtGrouping(path, grouping);
}
fn fizzyCloseDocById(ctx: *anyopaque, id: u64) anyerror!void {
    return fizzyCtx(ctx).closeFileID(id);
}
fn fizzySetProjectFolder(ctx: *anyopaque, path: []const u8) anyerror!void {
    return fizzyCtx(ctx).setProjectFolder(path);
}
fn fizzyCloseProjectFolder(ctx: *anyopaque) void {
    fizzyCtx(ctx).app.closeProjectFolder();
}
fn fizzyRecentFolderCount(ctx: *anyopaque) usize {
    return fizzyCtx(ctx).app.recents.folders.items.len;
}
fn fizzyRecentFolderAt(ctx: *anyopaque, index: usize) ?[]const u8 {
    const editor = fizzyCtx(ctx);
    if (index >= editor.app.recents.folders.items.len) return null;
    return editor.app.recents.folders.items[index];
}
fn fizzyOpenInFileBrowser(ctx: *anyopaque, path: []const u8) anyerror!void {
    return fizzyCtx(ctx).openInFileBrowser(path);
}
fn fizzyFolderWatchActive(ctx: *anyopaque) bool {
    const editor = fizzyCtx(ctx);
    return if (editor.app.folder_watcher) |*w| w.active() else false;
}

// `core.FileTable.Env` — the three things the shared file set has to ask this editor. Separate
// from the `fizzy_api_vtable` thunks above because the table is `core`, not `sdk`: it takes an
// `?*anyopaque` and knows nothing about `EditorAPI`.
fn fileTableRoot(ctx: ?*anyopaque) ?[]const u8 {
    return fizzyCtx(ctx.?).app.folder;
}
fn fileTableWatching(ctx: ?*anyopaque) bool {
    return fizzyFolderWatchActive(ctx.?);
}
fn fileTableRefresh(ctx: ?*anyopaque) void {
    fizzyRefresh(ctx.?);
}
fn fileTableUnmounting(ctx: ?*anyopaque, prefix: []const u8) void {
    const editor = fizzyCtx(ctx.?);
    editor.doc_io.unmounting(prefix);
    // The root was this mount (a drive signed out, an archive tab closed): close it, the way a
    // deleted folder would leave nothing to show. Queued, not applied, since an unmount can
    // arrive from inside a draw.
    if (editor.app.folder) |f| {
        if (std.mem.startsWith(u8, f, prefix) and (f.len == prefix.len or f[prefix.len] == '/')) {
            editor.app.host.closeProjectFolder();
        }
    }
}
fn fileTableIgnored(
    ctx: ?*anyopaque,
    project_root: []const u8,
    abs_path: []const u8,
    name: []const u8,
    kind: std.Io.File.Kind,
) bool {
    return fizzyCtx(ctx.?).ignore.isIgnored(project_root, abs_path, name, kind);
}

fn fizzyIsPathIgnored(
    ctx: *anyopaque,
    project_root: []const u8,
    abs_path: []const u8,
    name: []const u8,
    kind: std.Io.File.Kind,
) bool {
    return fizzyCtx(ctx).ignore.isIgnored(project_root, abs_path, name, kind);
}
fn fizzyExplorerBranchIsOpen(ctx: *anyopaque, branch_id: dvui.Id) bool {
    return fizzyCtx(ctx).explorer.open_branches.contains(branch_id);
}
fn fizzySetExplorerBranchOpen(ctx: *anyopaque, branch_id: dvui.Id, open: bool) void {
    const editor = fizzyCtx(ctx);
    if (open) {
        editor.explorer.open_branches.put(branch_id, {}) catch {};
    } else {
        _ = editor.explorer.open_branches.remove(branch_id);
    }
}
fn fizzyDrawWorkspaces(ctx: *anyopaque, index: usize) anyerror!dvui.App.Result {
    return fizzyCtx(ctx).workbench.drawWorkspaces(index);
}
fn fizzyShowOpenFolderDialog(ctx: *anyopaque, cb: sdk.EditorAPI.OpenPathsCallback, default_folder: ?[]const u8) void {
    _ = ctx;
    fizzy.backend.showOpenFolderDialog(cb, default_folder);
}
fn fizzyShowOpenFileDialog(
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
fn fizzySave(ctx: *anyopaque) anyerror!void {
    return fizzyCtx(ctx).save();
}
fn fizzyRequestCompositeWarmup(ctx: *anyopaque) void {
    fizzyCtx(ctx).requestPrepareFrame();
}
/// How a watcher thread wakes this app — the one thing `app/watch/` cannot answer for itself.
/// Set before any watcher starts; same call as `fizzyRefresh`, which is why it forwards there.
fn wakeEventLoop() void {
    fizzyRefresh(undefined);
}

fn fizzyRefresh(ctx: *anyopaque) void {
    _ = ctx;
    // Safe from any thread (see `SDLBackend.refresh`'s doc comment) — a single call reliably
    // wakes the blocked event loop and produces exactly one composited frame; see
    // `render_bridge.refresh`'s doc comment for how that was verified.
    fizzy.entry().window.backend.refresh();
}
fn fizzyAllocUntitledPath(ctx: *anyopaque) anyerror![]u8 {
    return fizzyCtx(ctx).app.allocNextUntitledPath();
}
fn fizzyCreateDocument(ctx: *anyopaque, path: []const u8, grid: sdk.EditorAPI.NewDocGrid) anyerror!sdk.DocHandle {
    return fizzyCtx(ctx).newFile(path, grid);
}
fn fizzySetExplorerNewFilePath(ctx: *anyopaque, path: []const u8) anyerror!void {
    const editor = fizzyCtx(ctx);
    try editor.workbench.setPendingNewFilePath(path);
    // A plugin reaching this has just written `path` with its own save routine, not through
    // `files.createFilePath`, so nothing has dropped the shared listing cache and that cache
    // still predates the file. Left stale, the row never appears on the next frame: the match in
    // `files.zig` never runs, no inline rename opens, and the dialog still closing over the top
    // of it has no row to fly into. This is the only thing standing between "the file exists"
    // and "the user can see and rename it".
    editor.app.file_table.invalidateAll();
}
fn fizzyRequestSaveAs(ctx: *anyopaque) void {
    fizzyCtx(ctx).requestSaveAs();
}
fn fizzyRequestWebSave(ctx: *anyopaque, kind: sdk.EditorAPI.WebSaveKind) void {
    const native_kind: Dialogs.WebSaveAs.Kind = switch (kind) {
        .save => .save,
        .save_as => .save_as,
    };
    fizzyCtx(ctx).requestWebSaveDialog(native_kind);
}
fn fizzyCancelPendingSaveDialog(ctx: *anyopaque) void {
    fizzyCtx(ctx).cancelPendingSaveDialog();
}
fn fizzySetPendingCloseDocId(ctx: *anyopaque, id: u64) void {
    fizzyCtx(ctx).app.pending_close_file_id = id;
}
fn fizzyQueueCloseAfterSave(ctx: *anyopaque, id: u64) anyerror!void {
    const editor = fizzyCtx(ctx);
    try fizzyCtx(ctx).app.pending_close_after_save.put(editor.app.gpa, id, {});
}
fn fizzyTrackQuitSaveInFlight(ctx: *anyopaque, id: u64) anyerror!void {
    const editor = fizzyCtx(ctx);
    try fizzyCtx(ctx).app.quit_saves_in_flight.put(editor.app.gpa, id, {});
}
fn fizzyResumeSaveAllQuit(ctx: *anyopaque) void {
    fizzyCtx(ctx).app.pending_quit_continue = true;
}
fn fizzyAbortSaveAllQuit(ctx: *anyopaque) void {
    fizzyCtx(ctx).app.abortSaveAllQuit();
}

/// Store a loaded/created document in the plugin registry and register its handle.
const DocSurface = struct {
    editor: *Editor,
    doc_id: u64,
    /// `<owner>.doc:<path>`, gpa-owned; the surface's title is the basename, a slice of it.
    id: []u8,
};

pub fn insertOpenDoc(editor: *Editor, doc_buf: *anyopaque, owner: *sdk.Plugin, id: u64) !void {
    const ptr = try owner.registerOpenDocument(doc_buf);
    try editor.app.open_files.put(editor.app.gpa, id, .{
        .ptr = ptr,
        .owner = owner,
        .id = id,
    });
    if (editor.document_watcher) |*w| {
        if (editor.app.docById(id)) |doc| w.track(doc);
    }
    if (editor.app.docById(id)) |doc| editor.registerDocSurface(doc) catch |err| {
        dvui.log.err("document surface for {s}: {t}", .{ owner.documentPath(doc), err });
    };
}

fn registerDocSurface(editor: *Editor, doc: sdk.DocHandle) !void {
    const gpa = editor.app.gpa;
    const ds = try gpa.create(DocSurface);
    errdefer gpa.destroy(ds);
    const path = doc.owner.documentPath(doc);
    ds.* = .{
        .editor = editor,
        .doc_id = doc.id,
        .id = try sdk.document.surfaceId(gpa, doc.owner.id, path),
    };
    errdefer gpa.free(ds.id);
    try editor.doc_surfaces.put(gpa, doc.id, ds);
    errdefer _ = editor.doc_surfaces.remove(doc.id);
    try editor.app.host.registerSurface(.{
        .id = ds.id,
        .owner = doc.owner,
        // The path half of the id, not the whole id: a browser upload's path is a bare name
        // with no separator, and `basename` of the whole id would then be `owner.doc:name`.
        .title = std.fs.path.basename(sdk.document.pathOfSurfaceId(ds.id) orelse ds.id),
        .keywords = sdk.document.keywords,
        .ctx = ds,
        .draw = drawDocSurface,
    });
}

fn unregisterDocSurface(editor: *Editor, doc_id: u64) void {
    const kv = editor.doc_surfaces.fetchRemove(doc_id) orelse return;
    editor.app.host.unregisterSurface(kv.value.id);
    editor.app.gpa.free(kv.value.id);
    editor.app.gpa.destroy(kv.value);
}

/// The document's path has already changed (an explorer rename, a directory rename above it, a
/// Save As) and everything keyed by the old spelling has to follow: the surface — its id *is*
/// `<owner>.doc:<path>` — the pane tab that names that id, and the on-disk watch. Called by
/// whoever changed the path, after it did; the plugin's `setDocumentPath` is only the string.
pub fn documentPathChanged(editor: *Editor, doc: sdk.DocHandle) void {
    const gpa = editor.app.gpa;
    const old_id = if (editor.doc_surfaces.get(doc.id)) |ds| gpa.dupe(u8, ds.id) catch null else null;
    defer if (old_id) |id| gpa.free(id);

    editor.unregisterDocSurface(doc.id);
    editor.registerDocSurface(doc) catch |err| {
        dvui.log.err("document surface for {s}: {t}", .{ doc.owner.documentPath(doc), err });
    };
    if (old_id) |id| editor.workbench.documentRenamed(doc, id);
    if (editor.document_watcher) |*w| w.retarget(doc);
    // Titlebar, tab and menu enablement were drawn this frame from the old path.
    dvui.refresh(null, @src(), null);
}

/// A document drawn as a surface: the canvas box around it, then the owner's `drawDocument`. The document is looked up by id each time — a plugin can unload
/// between frames, and the handle in `open_files` is the one that is current.
fn drawDocSurface(ctx: ?*anyopaque) anyerror!dvui.App.Result {
    const ds: *DocSurface = @ptrCast(@alignCast(ctx orelse return .ok));
    const editor = ds.editor;
    const doc = editor.app.docById(ds.doc_id) orelse return .ok;

    // No fill: the place card the region draws is the document's background. A second coat of
    // the same translucent fill here doubled it — darker, and more opaque than the chrome
    // around it.
    var canvas = sdk.pane_layout.mainCanvasVbox(dvui.themeGet().color(.window, .fill), false, @truncate(ds.doc_id));
    defer {
        dvui.toastsShow(canvas.data().id, canvas.data().contentRectScale().r.toNatural());
        canvas.deinit();
    }
    // The handle is opaque to every plugin (pixi stores it, never reads through it); the canvas
    // box id is what a plugin keys its per-pane state on.
    doc.owner.bindDocumentToPane(doc, canvas.data().id, ds, false);
    _ = try doc.owner.drawDocument(doc);
    return .ok;
}

pub fn activeDoc(editor: *Editor) ?sdk.DocHandle {
    return editor.workbench.activeDoc();
}

/// Files sidebar inactive — drop tree dvui stash and tab-drag state.
pub fn resetFileTreeWhenFilesHidden(editor: *Editor) void {
    editor.workbench.clearFileTreeDataId();
    editor.clearFileTreeTabDragDropState();
}

/// Draws whichever center provider is active, blur-fading when that changes.
///
/// Swapping providers replaces the entire center subtree, and each provider paints its own pane
/// — square and full-bleed for a document canvas, a rounded card for the homepage, the
/// pack-project window and the store's detail page. So this cannot be a fade-in: there is no
/// background the host could hold underneath that is correct for both shapes, and dvui also
/// needs a frame to size the incoming subtree from a cold min-size cache.
///
/// Instead the outgoing provider gets one more draw, recorded into a texture rather than shown.
/// That snapshot blurs out, the incoming view is photographed at max blur (so it can settle
/// underneath), and the overlay unsmears. Set `center_transition.pending` to hold at peak
/// blur until a plugin is ready — nothing here loads one. See `core.anim.transition`.
pub fn drawActiveCenter(editor: *Editor) !dvui.App.Result {
    const center = editor.app.host.selectedSurface(sdk.keywords.ide.main) orelse {
        editor.app.layout.center_transition.discard();
        editor.app.layout.center_prev_id = null;
        return .ok;
    };

    // Stable slot under the center region. Both the capture pass and the live provider parent
    // here, so widget ids match last frame during capture (`reveal` stays shown, min-sizes stay
    // warm). The slot is also the paned/box's only expanded child, so packing the capture and
    // then the incoming screen only needs a reset of *this* box's pack state — not the outer
    // paned's.
    var slot = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = false,
        .padding = .{},
        .margin = .{},
        .border = .{},
    });
    defer slot.deinit();

    const rs = slot.data().contentRectScale();

    const CaptureCtx = struct {
        editor: *Editor,
        prev_id: []const u8,
        slot: *dvui.BoxWidget,

        fn draw(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            // Look up by id rather than caching the pointer: a plugin can be unloaded between
            // frames, and its `draw` pointer would be dangling. Errors are ignored — a provider
            // failing here must not take down the swap, it just means no fade.
            if (self.editor.app.host.surfaceById(self.prev_id)) |outgoing| {
                _ = outgoing.draw(outgoing.ctx) catch {};
            }
        }

        fn afterCapture(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            // The capture just packed an expanded child into `slot`. Clear pack state so the
            // incoming provider is once again this box's first child this frame.
            self.slot.first_child = true;
            self.slot.packed_children = 0;
            self.slot.total_weight = 0;
            self.slot.min_space_taken = 0;
            if (builtin.mode == .Debug) self.slot.child_id = .zero;
        }
    };

    const prev_id = editor.app.layout.center_prev_id;
    var capture_ctx: CaptureCtx = .{
        .editor = editor,
        .prev_id = prev_id orelse "",
        .slot = slot,
    };

    var frame = core.anim.transition(&editor.app.layout.center_transition, .{
        .key = std.hash.Wyhash.hash(0, center.id),
        .rect = rs.r,
        .kind = .blur,
        .draw_previous = if (prev_id != null) CaptureCtx.draw else null,
        .after_capture = if (prev_id != null) CaptureCtx.afterCapture else null,
        .ctx = @ptrCast(&capture_ctx),
    });
    defer frame.deinit();

    editor.app.layout.center_prev_id = center.id;
    return try center.draw(center.ctx);
}

/// Looks up an open document by path. Exact match first (the hot path — file-tree paint hits
/// this every frame with already-canonical abs paths); on miss, collapses `.` / `..` /
/// duplicate separators so a caller holding `a/./b.zig` still finds a doc stored as `a/b.zig`
/// (and vice versa for anything opened before `openFilePath` started normalizing). See
/// `fizzy.core.paths.normalize`.
pub fn docFromPath(editor: *Editor, path: []const u8) ?sdk.DocHandle {
    for (editor.app.open_files.values()) |doc| {
        if (std.mem.eql(u8, doc.owner.documentPath(doc), path)) return doc;
    }

    // The file tree calls this once per row per frame, and the miss (file not open) is by far the
    // common case — so every allocation below is paid on every non-open row. Both normalizes are
    // skippable whenever the path is already canonical, which is the norm here: tree rows are
    // joined onto an absolute project root. Checking costs a scan, not a heap allocation.
    const path_canonical = fizzy.core.paths.isNormalizedAbsolute(path);
    const key: []const u8 = if (path_canonical)
        path
    else
        fizzy.core.paths.normalize(editor.app.gpa, path) catch return null;
    defer if (!path_canonical) editor.app.gpa.free(@constCast(key));

    for (editor.app.open_files.values()) |doc| {
        const stored = doc.owner.documentPath(doc);
        if (std.mem.eql(u8, stored, key)) return doc;
        // Skip a second normalize when the stored spelling already matched `path` above, or
        // already equals `key`. Only needed when a pre-normalization doc still carries a `.`
        // component that the caller's key has already collapsed.
        if (std.mem.eql(u8, stored, path)) continue;
        // A canonical `stored` normalizes to itself, and both comparisons above already ruled it
        // out — no need to allocate a copy just to re-compare it.
        if (fizzy.core.paths.isNormalizedAbsolute(stored)) continue;
        const stored_canon = fizzy.core.paths.normalize(editor.app.gpa, stored) catch continue;
        defer editor.app.gpa.free(stored_canon);
        if (std.mem.eql(u8, stored_canon, key)) return doc;
    }
    return null;
}

/// Ensures `{config}/themes` exists and scans `*.json` for future user themes (loaded entries are prepended before Fizzy themes).
fn appendUserThemes(gpa: std.mem.Allocator, editor: *Editor) !void {
    const themes_dir = try std.fs.path.join(gpa, &.{ editor.app.config_folder, "themes" });

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

    const sb = clampFontSize(editor.app.settings.font_body_size);
    const st = clampFontSize(editor.app.settings.font_title_size);
    const sh = clampFontSize(editor.app.settings.font_heading_size);
    const sm = clampFontSize(editor.app.settings.font_mono_size);

    editor.app.settings.font_body_size = sb;
    editor.app.settings.font_title_size = st;
    editor.app.settings.font_heading_size = sh;
    editor.app.settings.font_mono_size = sm;

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

/// Select a theme from `editor.themes` matching `settings.theme`: trim, legacy file-name aliases, then exact and case-insensitive name match. Falls back to `Settings.default_theme`, then the first entry, and logs if the stored value did not match anything.
fn resolveSettingsTheme(editor: *Editor) *dvui.Theme {
    const trimmed = std.mem.trim(u8, editor.app.settings.theme, &std.ascii.whitespace);
    const candidate = App.themeFilenameToName(trimmed) orelse trimmed;

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
    if (!std.mem.eql(u8, editor.app.settings.theme, t.name)) {
        try Settings.setThemeName(&editor.app.settings, editor.app.gpa, t.name);
    }
    dvui.themeSet(t.*);
    editor.applyFontSizesFromSettings();
}

pub fn applyHoldMenuDuration(editor: *Editor) void {
    const ms = @max(@as(u32, 100), editor.app.settings.hold_menu_duration_ms);
    fizzy.entry().window.hold_menu_duration_ns = @as(i128, ms) * 1_000_000;
}

pub fn markSettingsDirty(editor: *Editor) void {
    editor.app.settings_dirty = true;
    editor.app.settings_save_deadline_ns = fizzy.core.perf.nanoTimestamp() + Settings.autosave_timeout_ns;
}

/// Same debou
/// nce shape as `markSettingsDirty`, but for `window.zon`'s explorer/panel ratios —
/// kept separate so dragging a splitter (which calls this every frame) never forces a
/// settings.zon write attempt.
pub fn markWindowRatiosDirty(editor: *Editor) void {
    editor.app.layout.dirty = true;
    editor.app.layout.save_deadline_ns = fizzy.core.perf.nanoTimestamp() + Settings.autosave_timeout_ns;
}

/// Forget extents, assignments and runtime splits, write an empty region list,
/// and redraw. Window geometry in `layout.zon` is left alone.
pub fn resetLayout(editor: *Editor) void {
    editor.app.layout.resetLayout(editor.app.gpa);
    editor.saveRegions();
    editor.app.layout.dirty = false;
    dvui.refresh(null, @src(), null);
}

/// Hand the center region the whole viewport on a collapsed (phone / narrow web) layout: close
/// the explorer peek and swing the bottom panel shut. Call it right after a tap has put
/// something worth reading in the center — e.g. selecting a plugin in the store, whose detail
/// page renders as a center provider behind the peeked-open explorer.
///
/// No-op unless the explorer is *peeking* — open on a window too narrow to hold it beside the
/// center, which is exactly the state that draws the floating collapse-explorer button (see
/// `Explorer.drawCollapseButton`). On a desktop-width window both panes are visible at once, so
/// there is nothing to reveal and the user's layout is left alone.
///
/// Must be called from inside the frame's explorer/center subtree, where `explorer.paned`
/// exists — see the `Sidebar` note about deferring paned pokes to `tick`.
pub fn revealCenter(editor: *Editor) void {
    const sidebar = editor.regionFor(sdk.keywords.ide.sidebar) orelse return;
    if (!sidebar.isPeeking()) return;
    editor.explorer.peekClose(editor);
    // The panel goes too, for the same reason the explorer does: the center is what the tap
    // asked to see, and on this window it can only have the whole of it.
    if (editor.regionFor(sdk.keywords.ide.panel)) |panel| panel.close();
}

/// This frame's answer, sampled in `tick` — see `plugins_drawing`. Callers run after that
/// sample; on the first frame, before any sample, it reads false, which is the harmless
/// direction (an autosave happens one frame earlier than it might have).
fn activelyDrawing(editor: *const Editor) bool {
    return editor.plugins_drawing;
}

/// Composes fizzy's own fields (`Settings.serialize`) together with every plugin's pending
/// settings write into one `<config>/settings.zon` and writes it in a single pass (see
/// `docs/PLUGIN_MANIFEST_PLAN.md` R10). This *must* stay one combined write: writing fizzy's
/// fields and the plugins' blobs independently would let whichever write ran second silently
/// drop the other's data, since `Settings.serialize` only knows fizzy's own fields and has no
/// notion of `.plugins` at all. `settings_last_saved_hash` dedupes over the *whole* composed
/// text, so a plugin-only settings change still triggers a real write even when fizzy's own
/// fields haven't moved.
///
/// Shared by `writeMergedSettings` and the startup dedup-hash seed (see `init`): composes the
/// merged `settings.zon` text from fizzy's current in-memory fields plus `overlay`'s plugin
/// blocks, layered onto whatever is already on disk at `settings_path` (see
/// `SettingsPluginsZon.composeMergedText`'s doc comment for exactly what's preserved vs.
/// overlaid). External hand-edits are reconciled live by `SettingsWatcher` (R11/R12) before the
/// next autosave can clobber them. Caller-owned; free with `gpa`.
fn composeSettingsText(editor: *Editor, gpa: std.mem.Allocator, settings_path: []const u8, overlay: []const SettingsPluginsZon.Entry) ![]u8 {
    const fizzy_text = try Settings.serialize(&editor.app.settings, gpa);
    defer gpa.free(fizzy_text);

    const existing = fizzy.core.fs.readZ(gpa, dvui.io, settings_path) catch null;
    defer if (existing) |e| gpa.free(e);

    return SettingsPluginsZon.composeMergedText(gpa, fizzy_text, existing, overlay);
}

fn writeMergedSettings(editor: *Editor, settings_path: []const u8) !void {
    const gpa = editor.app.gpa;

    var pending_settings = editor.app.host.takePendingPluginSettings();
    defer {
        var it = pending_settings.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            if (e.value_ptr.*) |v| gpa.free(v);
        }
        pending_settings.deinit(gpa);
    }

    var pending_flags = editor.app.plugin_flags_pending;
    editor.app.plugin_flags_pending = .empty;
    defer {
        var it = pending_flags.iterator();
        while (it.next()) |e| gpa.free(e.key_ptr.*);
        pending_flags.deinit(gpa);
    }

    var pending_exts = editor.app.plugin_extensions_pending;
    editor.app.plugin_extensions_pending = .empty;
    defer {
        var it = pending_exts.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            SettingsPluginsZon.freeExtensions(gpa, e.value_ptr.*);
        }
        pending_exts.deinit(gpa);
    }

    // Union of ids touched by either buffer this cycle.
    var touched: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer touched.deinit(gpa);
    {
        var it = pending_settings.iterator();
        while (it.next()) |e| try touched.put(gpa, e.key_ptr.*, {});
    }
    {
        var it = pending_flags.iterator();
        while (it.next()) |e| try touched.put(gpa, e.key_ptr.*, {});
    }
    {
        var it = pending_exts.iterator();
        while (it.next()) |e| try touched.put(gpa, e.key_ptr.*, {});
    }

    const existing = fizzy.core.fs.readZ(gpa, dvui.io, settings_path) catch null;
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
        const disk_exts = App.readPluginExtensions(gpa, existing, id);
        defer SettingsPluginsZon.freeExtensions(gpa, disk_exts);
        var reserved: SettingsPluginsZon.Reserved = .{
            // Tri-state, not `readPluginEnabled`'s bool: an id that has never been decided about
            // must stay that way when some *other* part of its block is written (a plugin can
            // have `.settings` on disk long before anyone answers "should this load?").
            .enabled = switch (App.readPluginEnabledState(gpa, existing, id)) {
                .unset => null,
                .enabled => true,
                .disabled => false,
            },
            .auto_update = App.readPluginAutoUpdate(gpa, existing, id),
            .extensions = disk_exts,
        };
        var settings_owned = App.readPluginSettingsText(gpa, existing, id);
        defer if (settings_owned) |s| gpa.free(s);
        var settings_text: ?[]const u8 = settings_owned;

        if (pending_flags.get(id)) |f| {
            if (f.erase) {
                reserved.enabled = null;
                reserved.extensions = &.{};
            }
            if (f.enabled) |e| reserved.enabled = e;
            if (f.auto_update) |a| reserved.auto_update = a;
        }
        // Pending owns the list (freed with `pending_exts`); borrow it for composition.
        if (pending_exts.get(id)) |exts| reserved.extensions = exts;

        if (pending_settings.get(id)) |maybe| {
            // Pending owns this blob (freed with `pending_settings`); borrow for composition.
            if (settings_owned) |s| {
                gpa.free(s);
                settings_owned = null;
            }
            settings_text = maybe;
        }

        // Every reserved field back at its default *and* no author settings means the block
        // would compose to a bare `.{}` — drop the id from the file instead (R12). An explicit
        // `.enabled = false` is *not* a default: it is the user's recorded decision to keep this
        // plugin off, and dropping it would demote the plugin back to "never asked".
        // A non-empty `extensions` is a real, user-made decision — it keeps the id in the file
        // even when everything else sits at its default (e.g. an extension assigned to a plugin
        // that is currently disabled).
        if (reserved.enabled == null and reserved.auto_update and reserved.extensions.len == 0 and
            settings_text == null)
        {
            try overlay.append(gpa, .{ .id = id, .text = null });
        } else {
            const block = try SettingsPluginsZon.composePluginIdBlock(gpa, reserved, settings_text);
            try overlay.append(gpa, .{ .id = id, .text = block });
        }
    }

    const composed = try editor.composeSettingsText(gpa, settings_path, overlay.items);
    defer gpa.free(composed);

    const hash = std.hash.Wyhash.hash(0, composed);
    if (editor.app.settings_last_saved_hash == hash) return;

    try fizzy.core.fs.write(dvui.io, settings_path, composed);
    editor.app.settings_last_saved_hash = hash;
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
    const gpa = editor.app.gpa;

    const settings_path = std.fs.path.join(gpa, &.{ editor.app.config_folder, "settings.zon" }) catch return;
    defer gpa.free(settings_path);

    const data = fizzy.core.fs.readZ(gpa, dvui.io, settings_path) catch return; // deleted/unreadable: nothing to reconcile
    defer gpa.free(data);

    const hash = std.hash.Wyhash.hash(0, data);
    if (editor.app.settings_last_saved_hash) |last| {
        if (last == hash) return; // our own last write, or nothing's actually changed
    }
    dvui.log.info("settings watcher: external change to settings.zon detected; reconciling", .{});

    // Always refresh an open settings.zon tab from disk first — even if fizzy fails to
    // parse the file below. The text buffer should still track what the user (or another
    // tool) wrote; parse failure must not leave the tab stuck on a stale snapshot.
    if (editor.document_watcher) |*w| w.notifyPathChanged(editor, settings_path);

    // Parse without falling back to defaults on failure (see `Settings.parseOnly`'s doc
    // comment) — a torn/partial read here must never reset every fizzy field and every
    // plugin's settings. Left unreconciled until another external change retriggers a read
    // (rare in practice: the watcher's debounce already gives a normal atomic save time to
    // settle before this runs at all).
    const parsed = Settings.parseOnly(gpa, data) catch |err| {
        dvui.log.warn("settings watcher: could not parse external settings.zon change ({s}); skipping this reconciliation", .{@errorName(err)});
        return;
    };
    defer Settings.freeParsed(gpa, parsed);

    // Fizzy fields, one at a time rather than `editor.app.settings = parsed` wholesale: `theme` is
    // runtime-owned (see its doc comment on `Settings`) and must not be clobbered by the raw
    // parsed copy, which is exactly what a whole-struct assign would do. If you add a field to
    // `Settings`, add it here too, unless it's `theme`.
    editor.app.settings.setThemeName(gpa, parsed.theme) catch |err|
        dvui.log.warn("settings watcher: failed to apply external theme change: {s}", .{@errorName(err)});
    editor.app.settings.hold_menu_duration_ms = parsed.hold_menu_duration_ms;
    editor.app.settings.font_body_size = parsed.font_body_size;
    editor.app.settings.font_title_size = parsed.font_title_size;
    editor.app.settings.font_heading_size = parsed.font_heading_size;
    editor.app.settings.font_mono_size = parsed.font_mono_size;
    editor.app.settings.window_opacity_dark = parsed.window_opacity_dark;
    editor.app.settings.window_opacity_light = parsed.window_opacity_light;
    editor.app.settings.content_opacity = parsed.content_opacity;
    editor.app.settings.modal_dim = parsed.modal_dim;
    editor.app.settings.dialog_opacity = parsed.dialog_opacity;
    editor.app.settings.dialog_blur = parsed.dialog_blur;
    editor.app.settings.dialog_lift = parsed.dialog_lift;
    editor.app.settings.input_scheme = parsed.input_scheme;
    editor.app.settings.plugin_update_mode = parsed.plugin_update_mode;

    // Re-apply the existing idempotent appliers unconditionally — cheap, and each already
    // no-ops when nothing relevant changed.
    editor.applySettingsTheme() catch |err|
        dvui.log.warn("settings watcher: applySettingsTheme failed: {s}", .{@errorName(err)});
    editor.applyFontSizesFromSettings();
    editor.applyHoldMenuDuration();

    editor.reconcilePluginEnabled(data);
    editor.app.reconcilePluginSettings();

    // Mark this content as "known" now that it's fully applied, so neither the next autosave
    // nor a spurious re-wake re-triggers this same reconciliation again. Note a later call in
    // this same pass (`setPluginEnabled` → `setPluginEnabledPersisted` → `saveSettingsRaw`,
    // inside `reconcilePluginEnabled` above) may already have overwritten this with the hash of
    // its own fresh write — also correct, just redundant.
    editor.app.settings_last_saved_hash = hash;
}

/// Diffs each on-disk plugin directory's `.plugins.<id>.enabled` (freshly read) against the
/// live loaded/disabled state, loading/unloading to match — reusing `setPluginEnabled` so this
/// gets the exact same dirty-document safety guard the Plugins-tab toggle already has.
fn reconcilePluginEnabled(editor: *Editor, settings_data: [:0]const u8) void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    const gpa = editor.app.gpa;
    const plugins_dir = std.fs.path.join(gpa, &.{ editor.app.config_folder, "plugins" }) catch return;
    defer gpa.free(plugins_dir);

    var dir = std.Io.Dir.cwd().openDir(dvui.io, plugins_dir, .{ .iterate = true }) catch return;
    defer dir.close(dvui.io);
    var iter = dir.iterate();
    while (iter.next(dvui.io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const id = entry.name;
        if (id.len == 0 or id[0] == '.') continue;
        if (!App.isValidPluginId(id) or isBundledPluginId(id)) continue;

        // Auto-update is pure bookkeeping — nothing to load or unload — so the on-disk value
        // simply becomes the runtime one. No write back: the file is already what it says.
        editor.app.trackAutoUpdate(id, App.readPluginAutoUpdate(gpa, settings_data, id)) catch {};

        const want_enabled = App.readPluginEnabled(gpa, settings_data, id);
        const is_disabled = editor.app.isPluginDisabled(id);
        const is_loaded = editor.app.host.pluginById(id) != null;

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
            editor.app.trackDisabledPlugin(id) catch {};
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
    const gpa = editor.app.gpa;

    // Collect first: `updatePlugin` unloads, which mutates `loaded_plugin_libs` (and frees the
    // entry's `plugin_id`, so the id has to be our own copy — the same reason
    // `setPluginEnabled`'s callers dupe before unloading).
    var changed: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (changed.items) |id| gpa.free(id);
        changed.deinit(gpa);
    }

    for (editor.app.loaded_plugin_libs.items) |loaded| {
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
            editor.app.restampLoadedPlugin(id);
        }
    }
}

/// Retries a plugin whose load failed once its build on disk changes.
///
/// The companion to `reconcileChangedPluginBinaries`, which only ever looks at plugins that are
/// *running* — a build that was rejected (wrong SDK, stale ABI fingerprint, a half-written file)
/// isn't in `loaded_plugin_libs` at all, so nothing rechecked it and the store's Retry button was
/// the only way back in. The overwhelmingly common case is an author rebuilding the plugin they
/// just got a load error for: the rebuild lands in the same `plugins/<id>/` directory the config
/// watcher already covers, so the fix is to compare the rejected build's stamp against disk and
/// load again when they differ.
///
/// A retry that fails re-records the failure with the *new* stamp, so a build that is simply
/// broken is attempted once per rebuild rather than once per watcher event. A plugin the user
/// disabled is left alone: "off" is a decision, not a failure to recover from.
pub fn reconcileFailedPluginBinaries(editor: *Editor) void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    const gpa = editor.app.gpa;

    // Collect first: a retry mutates `failed_user_plugins` (both on success, via
    // `clearFailedUserPlugin`, and on failure, which re-records), so the ids have to be our own
    // copies — the same reason `reconcileChangedPluginBinaries` collects before reloading.
    var retry: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (retry.items) |id| gpa.free(id);
        retry.deinit(gpa);
    }

    for (editor.app.failed_user_plugins.items) |f| {
        if (isBundledPluginId(f.id)) continue;
        if (editor.app.isPluginDisabled(f.id)) continue;
        const path = App.userPluginPath(gpa, &editor.app, f.id) catch continue;
        defer gpa.free(path);
        const stamp: App.FileStamp = .of(path);
        // Zeroes mean the build is gone or unreadable right now (a rebuild deletes and rewrites
        // it): nothing to load, and the next watcher event brings the finished file.
        if (stamp.mtime_ns == 0 and stamp.size == 0) continue;
        if (stamp.eql(.{ .mtime_ns = f.source_mtime_ns, .size = f.source_size })) continue;
        const id = gpa.dupe(u8, f.id) catch continue;
        retry.append(gpa, id) catch {
            gpa.free(id);
            continue;
        };
    }

    for (retry.items) |id| {
        // Exactly what the store's Retry button does (`PluginStore.queueSetEnabled(id, true)`),
        // so a recovered plugin ends up in the same state either way — enabled on record, loaded,
        // failure record cleared.
        if (editor.setPluginEnabled(id, true, false)) {
            dvui.log.info("plugin watcher: '{s}' loaded from its rebuilt binary after an earlier failure", .{id});
        } else |err| {
            // `loadUserPluginById` already logged and re-recorded the failure (with the new
            // stamp), so this build won't be retried again until it changes once more.
            dvui.log.info("plugin watcher: rebuilt '{s}' still fails to load ({s})", .{ id, @errorName(err) });
        }
    }
}

/// Rescans `<config>/plugins/` for directories not already loaded / tracked-disabled / failed,
/// and adds each as a disabled entry without writing settings.zon — a plugin dropped straight
/// into the folder must not auto-execute (R12). Store installs write `.enabled = true` themselves.
///
/// Driven from `SettingsWatcher.tick` and deliberately *outside* `reconcileExternalSettingsChange`,
/// for the same reason as `reconcileChangedPluginBinaries`: that one returns early unless
/// `settings.zon`'s content hash moved, and a brand-new `plugins/<id>/` directory never moves it.
/// Running it there meant a plugin built straight into the folder was only ever discovered at the
/// next launch — until then it had no `disabled_plugin_ids` entry, so the store drew it as a bare
/// `.on_disk` card with no way to load it.
pub fn reconcileDiscoveredPlugins(editor: *Editor) void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    const gpa = editor.app.gpa;
    const plugins_dir = std.fs.path.join(gpa, &.{ editor.app.config_folder, "plugins" }) catch return;
    defer gpa.free(plugins_dir);

    const settings_path = std.fs.path.join(gpa, &.{ editor.app.config_folder, "settings.zon" }) catch return;
    defer gpa.free(settings_path);
    const data = fizzy.core.fs.readZ(gpa, dvui.io, settings_path) catch null;
    defer if (data) |d| gpa.free(d);

    editor.app.pruneMissingUndecidedPlugins(plugins_dir);

    var dir = std.Io.Dir.cwd().openDir(dvui.io, plugins_dir, .{ .iterate = true }) catch return;
    defer dir.close(dvui.io);
    var iter = dir.iterate();
    while (iter.next(dvui.io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const id = entry.name;
        if (id.len == 0 or id[0] == '.') continue;
        if (!App.isValidPluginId(id) or isBundledPluginId(id)) continue;
        if (editor.app.host.pluginById(id) != null) continue;
        if (editor.app.isPluginDisabled(id)) continue;
        const already_failed = blk: {
            for (editor.app.failed_user_plugins.items) |f| {
                if (std.mem.eql(u8, f.id, id)) break :blk true;
            }
            break :blk false;
        };
        if (already_failed) continue;

        // Only track as disabled when there's no `.enabled = true` on record — a store install
        // that raced the watcher will have written enabled=true and (usually) already loaded.
        const state = App.readPluginEnabledState(gpa, data, id);
        if (state == .enabled) continue;

        editor.app.trackDisabledPlugin(id) catch continue;
        // No `.enabled` field at all: nobody has decided about this build yet, so it becomes a
        // "Load" offer in the store's installed pane instead of a switched-off row.
        if (state == .unset) editor.app.trackUndecidedPlugin(id) catch {};
        // The store caches what it found on disk (ids, probed names/versions) and only rescans
        // when told to; without this the new card shows up as a bare id, or not at all until the
        // user hits Refresh.
        PluginStore.markDiskScanDirty();
        dvui.log.info("settings watcher: discovered dropped-in plugin '{s}' (not loaded until the user says so)", .{id});
    }
}

/// Debounced autosave (defers while a canvas stroke is active).
fn saveSettingsGuarded(editor: *Editor) !void {
    if (!editor.app.settings_dirty) return;

    const now = fizzy.core.perf.nanoTimestamp();
    if (now < editor.app.settings_save_deadline_ns) {
        App.scheduleSaveWakeup(editor.app.settings_save_deadline_ns - now, 0);
        return;
    }

    if (editor.activelyDrawing())
        return;

    const settings_path = try std.fs.path.join(editor.app.gpa, &.{ editor.app.config_folder, "settings.zon" });
    defer editor.app.gpa.free(settings_path);

    try editor.writeMergedSettings(settings_path);
    editor.app.settings_dirty = false;
}

/// Flush to disk regardless of idle/drawing deferral — used during shutdown only.
fn saveSettingsRaw(editor: *Editor) !void {
    const settings_path = try std.fs.path.join(editor.app.gpa, &.{ editor.app.config_folder, "settings.zon" });
    defer editor.app.gpa.free(settings_path);

    try editor.writeMergedSettings(settings_path);
    editor.app.settings_dirty = false;
}

/// Debounced `window.zon` ratio autosave — same shape/guards as `saveSettingsGuarded`, but
/// gated on `window_ratios_dirty` instead so a splitter drag never forces a settings.zon write.
fn saveWindowRatiosGuarded(editor: *Editor) void {
    if (!editor.app.layout.dirty) return;

    const now = fizzy.core.perf.nanoTimestamp();
    if (now < editor.app.layout.save_deadline_ns) {
        App.scheduleSaveWakeup(editor.app.layout.save_deadline_ns - now, 1);
        return;
    }

    if (editor.activelyDrawing())
        return;

    editor.saveRegions();
    editor.app.layout.dirty = false;
}

/// Flush to disk regardless of idle/drawing deferral — used during shutdown only.
fn saveWindowRatiosRaw(editor: *Editor) void {
    editor.saveRegions();
    editor.app.layout.dirty = false;
}

const handle_size = 10;
const handle_dist = 60;

pub fn tick(editor: *Editor) !dvui.App.Result {
    // How dialogs look this frame — the settings, plus what a bare stretch of chrome is on
    // screen (the window base: content fill at window opacity over the OS material; opaque
    // when maximized). Published into the shared dvui window so plugin dylibs' dialogs read
    // the same values; see `core.dialogs.Style`.
    {
        const fill: dvui.Color = dvui.themeGet().color(.content, .fill);
        const chrome = fill;
        fizzy.core.dialogs.publishStyle(.{
            .modal_dim = editor.app.settings.modal_dim,
            .opacity = editor.app.settings.dialog_opacity,
            .blur = editor.app.settings.dialog_blur,
            .lift = editor.app.settings.dialog_lift,
            .chrome = .{ chrome.r, chrome.g, chrome.b, chrome.a },
            .has_chrome = true,
        });
    }
    // CORS-fail README images are `<img>` overlays, not canvas pixels. JS hides any
    // overlay this frame doesn't place — but only after a real frame, so sleeping the
    // window (mouse left) does not blank them. See `net_image.beginOverlayFrame`.
    // A bundled plugin that needs a call each frame declares one; on web the markdown
    // preview's remote-image overlay is the one that does.
    if (comptime builtin.target.cpu.arch == .wasm32) {
        inline for (bundled_plugins) |m| {
            if (comptime @hasDecl(m, "beginWebOverlayFrame")) m.beginWebOverlayFrame();
        }
        // Plugins the page has finished linking since last frame register now.
        PluginLoader.pump();
    }

    // Folder lifetime, before anything draws: free the strings earlier frames retired, then
    // apply a close queued from last frame's draw. `EditorAPI.folder` hands out the pointer
    // itself, so both have to land where no draw can be holding it. See `folder_retired`.
    editor.app.releaseRetiredFolders();
    editor.applyPendingFolderClose();
    // Mounted filesystems deliver here — a cloud listing that landed since last frame is in
    // the table's cache before the tree asks for it.
    editor.app.file_table.pump();

    editor.window_opacity = if (dvui.themeGet().dark) editor.app.settings.window_opacity_dark else editor.app.settings.window_opacity_light;

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

    const hitch_watchers = fizzy.core.hitch.begin(.watchers);
    // Pick up any external edit to settings.zon (see R11 in docs/PLUGIN_MANIFEST_PLAN.md).
    // Cheap no-op unless the watcher thread actually saw a change.
    if (editor.app.settings_watcher) |*w| w.tick(editor.configWatchSink());

    // Reload clean open docs / flag dirty conflicts when files change on disk.
    if (editor.document_watcher) |*w| w.tick(editor);

    // Fan out on-disk changes under the root folder to plugins. Cheap no-op unless the watcher
    // thread buffered something.
    if (editor.app.folder_watcher) |*w| w.tick(editor.folderWatchSink());
    hitch_watchers.end();

    var needs_save_status_anim_tick = false;
    for (editor.app.host.plugins.items) |plugin| {
        if (plugin.tickOpenDocuments()) needs_save_status_anim_tick = true;
    }
    // Re-poll the quit walker while saves are in flight on worker threads.
    if (editor.app.quit_saves_in_flight.count() > 0) editor.app.pending_quit_continue = true;
    if (editor.app.pending_quit_continue) {
        editor.app.pending_quit_continue = false;
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
        for (editor.app.open_files.values()) |doc| {
            if (doc.owner.isDirty(doc)) dirty_n += 1;
        }
        if (dirty_n == 0) continue;

        e.handle(@src(), wd);
        if (!Dialogs.AppQuitUnsaved.active(dvui.currentWindow()) and editor.app.quit_save_all_ids.items.len == 0) {
            Dialogs.AppQuitUnsaved.request();
        }
    }

    if (fizzy.backend.pollPendingAbout()) {
        // The app menu's "About fizzy" is AppKit's own item, so it has no model tag.
        editor.app.host.runCommand("fizzy.about") catch |err| {
            dvui.log.err("about command failed: {s}", .{@errorName(err)});
        };
    }
    if (fizzy.backend.pollPendingRecentFolder()) |i| {
        if (i < editor.app.recents.folders.items.len) {
            const folder = editor.app.recents.folders.items[i];
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
            for (files) |f| editor.app.gpa.free(f);
            editor.app.gpa.free(files);
        }
    }

    defer fizzy.core.dialogs.modal_dim_titlebar = false;
    editor.setTitlebarColor();
    editor.setWindowStyle();

    App.syncLoadedPluginDvuiContexts(&editor.app);
    {
        const t = fizzy.core.hitch.begin(.plugin_hooks);
        defer t.end();
        for (editor.app.host.plugins.items) |plugin| plugin.beginFrame();
    }
    if (fizzy.core.perf.record) fizzy.core.perf.beginFrame();
    defer if (fizzy.core.perf.record) fizzy.core.perf.endFrameAndMaybeLog();

    // Reap completed background file loads. Must run BEFORE `pending_composite_warmup` and any
    // workspace/file iteration so that a just-loaded file is visible to the rest of this frame.
    {
        const t = fizzy.core.hitch.begin(.loading_jobs);
        defer t.end();
        editor.processLoadingJobs();
    }
    if (comptime builtin.target.cpu.arch == .wasm32) fizzy.backend.pollWebFileIo(editor);

    // Build workspaces AFTER reaping load jobs so a freshly-loaded file with a new grouping
    // (e.g. "Open to the side") gets its workspace created on the same frame it lands.
    // Otherwise the new pane only appears on the next frame, which won't happen until some
    // unrelated event (mouse move, key) wakes the loop.
    {
        const t = fizzy.core.hitch.begin(.rebuild_workspaces);
        defer t.end();
        editor.rebuildWorkspaces() catch {
            dvui.log.err("Failed to rebuild workspaces", .{});
        };
    }

    if (editor.pending_composite_warmup) {
        const t = fizzy.core.hitch.begin(.plugin_hooks);
        defer t.end();
        editor.pending_composite_warmup = false;
        for (editor.app.host.plugins.items) |plugin| plugin.prepareFrame();
    }

    {
        var any_drawing = false;
        fizzy.core.perf.draw_stroke_buf_count = 0;
        // Every plugin, with no early exit: the hook is a broadcast, and a plugin that clears
        // per-frame state as it answers (see `plugins_drawing`) must be asked on every frame it
        // could be drawn on, not only until the first `true`.
        for (editor.app.host.plugins.items) |plugin| {
            if (plugin.needsContinuousRepaint()) any_drawing = true;
        }
        editor.plugins_drawing = any_drawing;
        // The hook's whole promise: "keep repainting rather than idling until input". Without
        // this it was only ever telemetry — dvui decides on its own whether to sleep, and it has
        // no idea a plugin is mid-animation, waiting on a worker it can only collect from a
        // frame, or counting down a debounce that only advances on frames that run. Every such
        // plugin had to call `dvui.refresh` itself and the hook did nothing, which is exactly the
        // "it starts, then freezes until I move the mouse" the graph panel showed once the app
        // was allowed to sleep.
        if (any_drawing) dvui.refresh(null, @src(), null);
        fizzy.core.perf.drawFrameBegin(any_drawing);
    }
    defer fizzy.core.perf.drawFrameEnd();

    // TODO: Does this need to be here for touchscreen zooming? Or does that belong in canvas?
    // var scaler = dvui.scale(
    //     @src(),
    //     .{ .scale = &dvui.currentWindow().content_scale, .pinch_zoom = .global },
    //     .{ .expand = .both },
    // );
    // defer scaler.deinit();

    const hitch_draw = fizzy.core.hitch.begin(.draw);
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
                .color_fill = .{ .color = window_color },
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
                    .color_fill = .{ .color = hover_fill },
                });
                defer b.deinit();
                fizzy.backend.setTitleBarCaptionButtonRect(.minimize, b.data().rectScale().r);
                core.icon.icon(@src(), "win_min", icons.tvg.feather.minus, .{ .stroke_color = .{ .color = stroke } }, .{
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
                    .color_fill = .{ .color = hover_fill },
                });
                defer b.deinit();
                fizzy.backend.setTitleBarCaptionButtonRect(.maximize, b.data().rectScale().r);
                core.icon.icon(@src(), "win_max", icons.tvg.lucide.square, .{ .stroke_color = .{ .color = stroke } }, .{
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
                    .color_fill = .{ .color = close_hover_fill.opacity(0.5) },
                });
                defer b.deinit();
                fizzy.backend.setTitleBarCaptionButtonRect(.close, b.data().rectScale().r);
                core.icon.icon(@src(), "win_close", icons.tvg.heroicons.outline.@"x-mark", .{
                    .stroke_color = .{ .color = if (is_hover) close_hover_stroke else stroke },
                }, .{
                    .expand = .ratio,
                    .padding = .all(5),
                    .margin = .all(0),
                    .gravity_x = 0.5,
                });
            }
        }

        editor.pollPendingReveals();

        {
            // Layout lifecycle and housekeeping belong to the framework, not to a shape: every
            // layout needed these five calls verbatim, and getting one wrong is a bug an app
            // author has no way to diagnose. A shape declares regions; it does not run the
            // frame.
            var layout_root = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = false });
            for (editor.app.host.plugins.items) |plugin| plugin.tickActiveDocument(layout_root.data().id);
            editor.flushQueuedNativeMenuActions();
            editor.flushQueuedNativeMenuItems();
            editor.processPendingSaveAs();

            var layout: Layout = .init(&editor.app.host, &editor.app.layout, editor.app.gpa, editor.app.arena.allocator());
            // Published for the duration of the shape, so a plugin drawing inside a region can
            // declare one of its own through `Host.region`. Cleared below: a `*Layout` that
            // outlives the frame points at a dead local.
            editor.app.frame_layout = &layout;
            // Same slot fizzy fills with `*Editor`: a consumer sets `Host.layout_ctx`, or
            // exports `context()` from its layout file.
            const ctx: ?*anyopaque = if (comptime build_opts.has_app_layout) blk: {
                const supplied = @import("app_layout");
                if (comptime @hasDecl(supplied, "context")) break :blk supplied.context();
                break :blk editor.app.host.layout_ctx;
            } else editor;
            layout.ctx = ctx;
            const shell_result = if (comptime build_opts.has_app_layout)
                @import("app_layout").layout(ctx, &layout)
            else
                fizzy_layout.layout(ctx, &layout);

            // The shape has finished declaring regions: publish them. Until this point
            // `regionFor` answered from the previous frame, which is what lets a command
            // dispatched between frames drive a region (see `Layout.State.regions`).
            editor.app.layout.publishRegions();
            // A drag or a collapse moved a region: fizzy's answer to "remember that" is a
            // debounced write to `layout.zon`.
            if (layout.extents_changed) editor.markWindowRatiosDirty();
            // The picker photographs surfaces that drew nowhere this frame, and floats above
            // everything the shape drew.
            layout.captureUnplaced();
            editor.app.layout.picker.draw(&layout);
            editor.app.frame_layout = null;

            // A region is a box, so a shape that declares one and never scopes it leaves the box
            // open and dvui reports the mismatch two widgets later ("not at the top of the widget
            // stack"), naming a box the shape author never wrote. Say it here instead, while the
            // count still means "regions this shape forgot to deinit".
            if (layout.depth != 0) dvui.log.err(
                "layout left {d} region(s) open — a region is a box: scope it and `defer r.deinit()`",
                .{layout.depth},
            );

            for (editor.app.host.plugins.items) |plugin| plugin.endFrame();
            layout_root.deinit();

            if (try shell_result != .ok) return try shell_result;
        }

        { // Plugin keybinds + per-frame overlays (e.g. pixel-art's radial menu)
            // While the palette owns the keyboard, plugin ticks must not run — otherwise a
            // plugin's `matchBind` (e.g. pixi Export on the same chord as Quick Open) steals
            // focus before the palette entry can claim it.
            // Recording a chord in settings blocks these for the same reason the palette does:
            // the keys are being captured, not invoked.
            if (!editor.command_palette.open and !KeybindSettings.isRecording()) {
                for (editor.app.host.plugins.items) |plugin| {
                    plugin.tickKeybinds() catch {
                        dvui.log.err("plugin '{s}': keybind tick failed — see its own log", .{plugin.id});
                    };
                }
            }
            Keybinds.tick() catch {
                dvui.log.err("Failed to tick hotkeys", .{});
            };

            for (editor.app.host.plugins.items) |plugin| {
                plugin.drawOverlay() catch {
                    dvui.log.err("plugin '{s}': overlay draw failed — see its own log", .{plugin.id});
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
    hitch_draw.end();

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

    _ = editor.app.arena.reset(.retain_capacity);

    if (editor.app.pending_app_close) {
        editor.app.pending_app_close = false;
        return .close;
    }

    return .ok;
}

fn queueNativeMenuAction(editor: *Editor, action: fizzy.backend.NativeMenuAction) void {
    if (editor.pending_native_menu_actions_len >= editor.pending_native_menu_actions.len) {
        // If we ever overflow, drop the action rather than crashing.
        return;
    }
    editor.pending_native_menu_actions[editor.pending_native_menu_actions_len] = action;
    editor.pending_native_menu_actions_len += 1;
}

pub fn flushQueuedNativeMenuActions(editor: *Editor) void {
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
pub fn flushQueuedNativeMenuItems(editor: *Editor) void {
    if (editor.pending_native_menu_item_indices_len == 0) return;
    const len: usize = editor.pending_native_menu_item_indices_len;
    editor.pending_native_menu_item_indices_len = 0;

    var i: usize = 0;
    while (i < len) : (i += 1) {
        const idx = editor.pending_native_menu_item_indices[i];
        if (idx >= editor.app.host.native_menu_items.items.len) continue;
        const item = &editor.app.host.native_menu_items.items[idx];
        item.run(item.ctx) catch |err| {
            dvui.log.err("Native menu item '{s}' failed: {any}", .{ item.id, err });
        };
    }
}

/// Run the command a menu-bar item stands for. The item names a command and nothing else.
pub fn handleNativeMenuAction(editor: *Editor, action: fizzy.backend.NativeMenuAction) !void {
    const item = menu_model.byTag(action.index) orelse {
        dvui.log.err("native menu tag {d} is not a model item", .{action.index});
        return;
    };
    const id = item.id;
    // A key equivalent's keystroke is still on its way through SDL to the focused widget;
    // tell the command so it doesn't synthesize a second one (a pasted-twice text field).
    const run = if (action.from_key) Keybinds.runCommandWithKeyEventInFlight(editor, id) else editor.app.host.runCommand(id);
    run catch |err| {
        dvui.log.err("native menu command '{s}' failed: {s}", .{ id, @errorName(err) });
    };
}

pub fn setTitlebarColor(editor: *Editor) void {
    const color = if (fizzy.core.dialogs.modal_dim_titlebar) dvui.themeGet().color(.control, .fill).lerp(.black, if (dvui.themeGet().dark) 60.0 / 255.0 else 80.0 / 255.0) else dvui.themeGet().color(.control, .fill);

    if (!std.mem.eql(u8, &editor.last_titlebar_color.toRGBA(), &color.toRGBA())) {
        editor.last_titlebar_color = color;
        fizzy.backend.setTitlebarColor(dvui.currentWindow(), color.opacity(if (dvui.themeGet().dark) editor.app.settings.window_opacity_dark else editor.app.settings.window_opacity_light));
    }
}

pub fn setWindowStyle(_: *Editor) void {
    fizzy.backend.setWindowStyle(dvui.currentWindow());
}

pub fn rebuildWorkspaces(editor: *Editor) !void {
    try editor.workbench.rebuildWorkspaces();
}

/// Write every region's extent and assignment to `layout.zon`, by name. One record per region
/// whichever half it has, so a region emptied on purpose is written as an empty list.
fn saveRegions(editor: *Editor) void {
    const gpa = editor.app.gpa;
    var by_name: std.StringArrayHashMapUnmanaged(fizzy.backend.SavedRegion) = .empty;
    defer by_name.deinit(gpa);
    {
        var it = editor.app.layout.extents.iterator();
        while (it.next()) |e| {
            const gop = by_name.getOrPut(gpa, e.key_ptr.*) catch return;
            if (!gop.found_existing) gop.value_ptr.* = .{ .name = e.key_ptr.* };
            gop.value_ptr.extent = e.value_ptr.*;
        }
    }
    {
        var it = editor.app.layout.assignments.iterator();
        while (it.next()) |e| {
            const gop = by_name.getOrPut(gpa, e.key_ptr.*) catch return;
            if (!gop.found_existing) gop.value_ptr.* = .{ .name = e.key_ptr.* };
            gop.value_ptr.surfaces = e.value_ptr.*;
        }
    }
    {
        const links = editor.app.layout.splits.collectLinks(gpa);
        defer gpa.free(links);
        for (links) |l| {
            const gop = by_name.getOrPut(gpa, l.name) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = .{ .name = l.name };
            gop.value_ptr.parent = l.parent;
            gop.value_ptr.from = @tagName(l.side);
        }
    }
    {
        var it = editor.app.layout.shows.iterator();
        while (it.next()) |e| {
            const gop = by_name.getOrPut(gpa, e.key_ptr.*) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = .{ .name = e.key_ptr.* };
            gop.value_ptr.shows = switch (e.value_ptr.*) {
                .one => .one,
                .many => .many,
            };
        }
    }
    fizzy.backend.saveRegions(editor.app.config_folder, by_name.values());
    if (editor.app.layout.dock) |*d| {
        const snap = d.snapshot(gpa) catch return;
        defer snap.deinit(gpa);
        fizzy.backend.saveTree(editor.app.config_folder, snap);
    } else if (editor.app.layout.tree_cleared) {
        fizzy.backend.saveTree(editor.app.config_folder, null);
        editor.app.layout.tree_cleared = false;
    }
}

fn loadRuntimeSplits(state: *Layout.State, gpa: std.mem.Allocator, saved: []const fizzy.backend.SavedRegion) void {
    const intern = struct {
        var st: *Layout.State = undefined;
        fn go(a: std.mem.Allocator, name: []const u8) []const u8 {
            return st.internName(a, name);
        }
    };
    intern.st = state;
    const order = gpa.alloc(fizzy.backend.SavedRegion, saved.len) catch return;
    defer gpa.free(order);
    @memcpy(order, saved);
    std.mem.sort(fizzy.backend.SavedRegion, order, {}, struct {
        fn less(_: void, a: fizzy.backend.SavedRegion, b: fizzy.backend.SavedRegion) bool {
            return std.mem.count(u8, a.name, "/") < std.mem.count(u8, b.name, "/");
        }
    }.less);
    for (order) |r| {
        const parent = r.parent orelse continue;
        const side = Layout.State.SplitTree.parseSide(r.from orelse continue) orelse continue;
        _ = state.splits.split(gpa, intern.go, parent, side, r.extent orelse 0, r.name);
    }
}

/// The region accepting `keywords`, or null when this app's shape declared none — a normal
/// state, not an error.
pub fn regionFor(editor: *Editor, keywords: []const []const u8) ?Region {
    return editor.app.layout.regionFor(keywords);
}

pub fn revealPosition(editor: *Editor, path: []const u8, line: u32, character: u32, open_side: bool) !bool {
    if (editor.docFromPath(path)) |doc| {
        doc.owner.revealPosition(doc, line, character);
        // `revealPosition` alone only sets `pending_cursor` on a possibly-background document —
        // nothing else made this path the *visible* one. Without this, jumping to a definition
        // in a non-active tab silently sets the caret and stops: the tab never gets focus, so
        // the document is never drawn to consume `pending_cursor`, and the jump looks like a
        // no-op. `open_side` is ignored here — an already-open target is focused where it
        // lives, the same way the file tree's "Open to the side" does not move an open file.
        if (editor.app.open_files.getIndex(doc.id)) |idx| editor.workbench.setActiveDocIndex(idx);
        return true;
    }

    // Nothing claims this extension, so `openFilePath` would reject it — fail fast rather than
    // queueing a reveal that could never resolve.
    if (editor.app.host.pluginForExtension(std.fs.path.extension(path)) == null) return false;

    // Same canonical spelling `openFilePath` stores on the document, so `pollPendingReveals`'
    // exact `docFromPath` cannot miss a `.`-laden URI-derived path.
    const owned_path = try std.fs.path.resolve(editor.app.gpa, &.{path});
    errdefer editor.app.gpa.free(owned_path);
    try editor.app.pending_reveals.append(editor.app.gpa, .{ .path = owned_path, .line = line, .character = character });

    // `open_side`: mint a fresh grouping so the load lands in a new split rather than the current
    // one — mirrors the file tree's "Open to the side" exactly.
    const target_grouping: u64 = if (open_side) editor.workbench.newGroupingID() else editor.workbench.currentGroupingID();

    // Pass `owned_path`, not `path`: the canonical spelling is the one `openFilePath` stores on
    // the document, and `pollPendingReveals` matches on it exactly.
    _ = editor.openFilePath(owned_path, target_grouping) catch |err| {
        editor.app.pending_reveals.items.len -= 1;
        editor.app.gpa.free(owned_path);
        return err;
    };
    // Deliberately `true`, not `openFilePath`'s result. A `false` there (as opposed to an error)
    // only ever means "a load for this exact path is already in flight" — "already open" was
    // ruled out by `docFromPath` above and "no owner plugin" by the extension check. The file
    // WILL finish loading and `pollPendingReveals` will apply the reveal, so returning `false`
    // here would drop a goto-definition target whenever a load happened to be in progress:
    // "opened the file, caret never moved".
    return true;
}

pub fn pollPendingReveals(editor: *Editor) void {
    if (editor.app.pending_reveals.items.len == 0) return;
    var i: usize = 0;
    while (i < editor.app.pending_reveals.items.len) {
        const pr = editor.app.pending_reveals.items[i];
        if (editor.docFromPath(pr.path)) |doc| {
            doc.owner.revealPosition(doc, pr.line, pr.character);
            editor.app.gpa.free(pr.path);
            _ = editor.app.pending_reveals.swapRemove(i);
        } else {
            i += 1;
        }
    }
}

fn fizzyDrawFileKindGlyph(_: *anyopaque, kind: []const u8, color: dvui.Color) bool {
    const glyph = file_glyphs.glyphFor(kind) orelse return false;
    // Same sizing contract every file glyph uses: the caller reserved the slot, so fit to it
    // with `expand = .ratio` rather than picking a size here.
    core.icon.icon(@src(), "FileKindGlyph", glyph, .{ .stroke_color = .{ .color = color }, .fill_color = .{ .color = color } }, .{
        .expand = .ratio,
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(0),
        .margin = dvui.Rect.all(0),
        .background = false,
    });
    return true;
}

// A plugin declaring a region needs the `Layout` this frame's shape is running with, which is a
// local in the draw loop — there is one only while the shape is being drawn, which is exactly
// when a plugin can be drawing too. Outside that window these answer "no", and a plugin that
// asked for a region gets null and draws its contents plainly.
fn fizzyBeginRegion(ctx: *anyopaque, spec: sdk.RegionSpec) ?sdk.RegionSpec.Token {
    const editor = fizzyCtx(ctx);
    const layout = editor.app.frame_layout orelse {
        dvui.log.err("plugin region \"{s}\" declared outside the layout", .{spec.name});
        return null;
    };
    return layout.beginPluginRegion(spec);
}

fn fizzyDrawRegionContents(ctx: *anyopaque, token: sdk.RegionSpec.Token) anyerror!dvui.App.Result {
    const layout = fizzyCtx(ctx).app.frame_layout orelse return .ok;
    return layout.drawPluginRegionContents(token);
}

fn fizzyEndRegion(ctx: *anyopaque, token: sdk.RegionSpec.Token) void {
    const layout = fizzyCtx(ctx).app.frame_layout orelse return;
    layout.endPluginRegion(token);
}

fn fizzyRegionMatching(ctx: *anyopaque, token: sdk.RegionSpec.Token) []const *sdk.Surface {
    const layout = fizzyCtx(ctx).app.frame_layout orelse return &.{};
    return layout.pluginRegionMatching(token);
}

fn fizzyRegionSelected(ctx: *anyopaque, token: sdk.RegionSpec.Token) ?*sdk.Surface {
    const layout = fizzyCtx(ctx).app.frame_layout orelse return null;
    return layout.pluginRegionSelected(token);
}

fn fizzyRegionSelect(ctx: *anyopaque, token: sdk.RegionSpec.Token, id: []const u8) void {
    const layout = fizzyCtx(ctx).app.frame_layout orelse return;
    layout.pluginRegionSelect(token, id);
}

fn fizzyAssignSurfaces(ctx: *anyopaque, region: []const u8, ids: ?[]const []const u8) anyerror!void {
    const editor = fizzyCtx(ctx);
    if (ids) |list| try editor.app.layout.assign(editor.app.gpa, region, list) else editor.app.layout.unassign(editor.app.gpa, region);
    editor.app.layout.markDirty();
}

fn fizzyAssignedSurfaces(ctx: *anyopaque, region: []const u8) ?[]const []const u8 {
    return fizzyCtx(ctx).app.layout.assignment(region);
}

fn fizzySelectInRegion(ctx: *anyopaque, region: []const u8, id: []const u8) void {
    const editor = fizzyCtx(ctx);
    // Either list: this frame's if the shape has declared it already, else last frame's. A
    // region that exists in neither has not been drawn yet, and its first draw selects the
    // first thing it shows — which for a pane just created around one document is that one.
    for (editor.app.layout.regions_building.items) |r| if (std.mem.eql(u8, r.name, region)) {
        editor.app.host.setSelectionForKey(r.selectionKey(), id);
        return;
    };
    for (editor.app.layout.regions.items) |r| if (std.mem.eql(u8, r.name, region)) {
        editor.app.host.setSelectionForKey(r.selectionKey(), id);
        return;
    };
}

fn fizzyAssignedRegionNames(ctx: *anyopaque) []const []const u8 {
    const editor = fizzyCtx(ctx);
    const arena = editor.app.arena.allocator();
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = editor.app.layout.assignments.keyIterator();
    while (it.next()) |k| out.append(arena, k.*) catch break;
    return out.items;
}

fn fizzyRevealPosition(ctx: *anyopaque, path: []const u8, line: u32, character: u32, open_side: bool) anyerror!bool {
    return revealPosition(fizzyCtx(ctx), path, line, character, open_side);
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
    while (i < editor.app.pending_close_after_save.count()) {
        const id = editor.app.pending_close_after_save.keys()[i];
        if (editor.app.docById(id)) |doc| {
            if (editor.docSaving(doc)) {
                i += 1;
                continue;
            }
            if (doc.owner.isDirty(doc)) {
                // Save-then-close whose save failed: keep the tab, and its edits, open.
                dvui.log.err("{s} did not save; leaving it open", .{doc.owner.documentPath(doc)});
                _ = editor.app.pending_close_after_save.swapRemove(id);
                continue;
            }
            editor.rawCloseFileID(id) catch |err| {
                dvui.log.err("Post-save close failed: {s}", .{@errorName(err)});
            };
        }
        // File gone (already closed elsewhere) or successfully closed: drop the
        // entry. Leave `i` where it is — the swapped-in entry needs checking next.
        _ = editor.app.pending_close_after_save.swapRemove(id);
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
    if (editor.app.quit_save_all_ids.items.len == 0 and editor.app.quit_saves_in_flight.count() == 0) return;

    // Pass 1: kick off any queued saves we haven't started yet.
    while (editor.app.quit_save_all_ids.items.len > 0) {
        const id = editor.app.quit_save_all_ids.items[0];
        const doc = editor.app.docById(id) orelse {
            _ = editor.app.quit_save_all_ids.swapRemove(0);
            continue;
        };
        if (!doc.owner.isDirty(doc)) {
            _ = editor.app.quit_save_all_ids.swapRemove(0);
            continue;
        }

        if (!doc.owner.documentHasRecognizedSaveExtension(doc)) {
            // Save As dialog needs a single active file — bail out of the parallel
            // kickoff for this one and let the existing Save As + pending_close_file_id
            // flow handle it. Next frame, pending_quit_continue will re-enter us.
            if (editor.app.open_files.getIndex(id)) |idx| editor.workbench.setActiveDocIndex(idx);
            editor.app.pending_close_file_id = id;
            editor.app.quit_in_progress = true;
            editor.requestSaveAs();
            return;
        }
        if (doc.owner.saveNeedsConfirmation(doc)) {
            // Flat-raster prompt is a modal dialog — same reason as Save As, do
            // it serially and rejoin afterwards.
            if (editor.app.open_files.getIndex(id)) |idx| editor.workbench.setActiveDocIndex(idx);
            doc.owner.requestSaveConfirmation(doc, .save_and_close, true);
            return;
        }
        if (editor.document_watcher) |*w| {
            if (w.hasDiskConflict(id)) {
                // Same serial treatment as Save As / flat-raster confirm.
                if (editor.app.open_files.getIndex(id)) |idx| editor.workbench.setActiveDocIndex(idx);
                Dialogs.FileChangedOnDisk.request(id);
                return;
            }
            w.markPendingBaseline(id);
        }

        // Async-safe path: kick off, move to in-flight, drop from queue. A mounted document's
        // write is async by nature and `docSaving` below waits on it.
        if (editor.hostWrites(doc)) {
            editor.saveThroughHost(doc) catch |err| {
                dvui.log.err("Save all quit kickoff: {s}", .{@errorName(err)});
                editor.app.abortSaveAllQuit();
                return;
            };
        } else doc.owner.saveDocumentAsync(doc) catch |err| {
            dvui.log.err("Save all quit kickoff: {s}", .{@errorName(err)});
            editor.app.abortSaveAllQuit();
            return;
        };
        editor.app.quit_saves_in_flight.put(editor.app.gpa, id, {}) catch |err| {
            dvui.log.err("Save all quit track: {s}", .{@errorName(err)});
            editor.app.abortSaveAllQuit();
            return;
        };
        _ = editor.app.quit_save_all_ids.swapRemove(0);
    }

    // Pass 2: drain completed in-flight saves. Same iteration pattern as
    // `tickPendingSaveCloses` — re-fetch keys each iteration since swapRemove
    // invalidates a previously-captured slice.
    {
        var i: usize = 0;
        while (i < editor.app.quit_saves_in_flight.count()) {
            const id = editor.app.quit_saves_in_flight.keys()[i];
            if (editor.app.docById(id)) |doc| {
                if (editor.docSaving(doc)) {
                    i += 1;
                    continue;
                }
                if (doc.owner.isDirty(doc)) {
                    // The write did not land (a mount that refused, a network that went
                    // away); closing now would discard the only copy. Stay open.
                    dvui.log.err("Save all quit: {s} did not save; not quitting", .{doc.owner.documentPath(doc)});
                    editor.app.abortSaveAllQuit();
                    return;
                }
                editor.rawCloseFileID(id) catch |err| {
                    dvui.log.err("Save all quit close: {s}", .{@errorName(err)});
                };
            }
            _ = editor.app.quit_saves_in_flight.swapRemove(id);
        }
    }

    if (editor.app.quit_save_all_ids.items.len == 0 and editor.app.quit_saves_in_flight.count() == 0) {
        editor.app.quit_in_progress = false;
        editor.app.pending_app_close = true;
    }
    // No re-arming refresh here on purpose — the worker threads themselves call
    // `dvui.refresh(window, ...)` from their completion defer (see
    // `File.saveZipFromSnapshot`). Spinning a polling loop on the GUI thread
    // starves the workers for CPU and serializes contention on `dvui.toastAdd`,
    // which one worker reaches before the GUI's wakeup yields.
}

pub fn close(app: *Entry, editor: *Editor) void {
    _ = app;
    if (editor.app.open_files.count() == 0) {
        editor.app.pending_app_close = true;
        return;
    }
    var dirty_n: usize = 0;
    for (editor.app.open_files.values()) |doc| {
        if (doc.owner.isDirty(doc)) dirty_n += 1;
    }
    if (dirty_n > 0) {
        Dialogs.AppQuitUnsaved.request();
    } else {
        editor.app.pending_app_close = true;
    }
}

/// The single choke point every folder open funnels through (CLI argv, menus, recents, the
/// SDK's `Host.setProjectFolder`), so `path` is canonicalized here once — plugins, recents and
/// anything deriving a key from `editor.app.folder` (a language server's `rootUri`, notably) then
/// can't disagree about how the same directory is spelled. See `fizzy.core.paths.normalize`.
pub fn setProjectFolder(editor: *Editor, path_in: []const u8) !void {
    const path = try fizzy.core.paths.normalize(editor.app.gpa, path_in);
    defer editor.app.gpa.free(path);

    // A root on a mount — a drive, a zip — is only openable while that mount exists. From
    // Recents after a sign-out, it does not.
    const on_mount = fizzy.core.paths.isMountPath(path);
    if (on_mount and !editor.app.file_table.isMounted(path)) {
        dvui.toast(@src(), .{ .message = std.fmt.allocPrint(
            editor.app.arena.allocator(),
            "{s} is not connected. Sign in or open it first.",
            .{path[0..(fizzy.core.paths.mountPrefixLen(path) orelse path.len)]},
        ) catch "That location is not connected." });
        return error.NotMounted;
    }

    // Opening a folder makes a close queued during this frame's draw moot.
    editor.app.pending_folder_close = false;

    if (editor.app.folder != null) {
        editor.ignore.deinit(editor.app.gpa);
        for (editor.app.host.plugins.items) |plugin| plugin.onFolderClose();
        // Not freed here: this runs from menus and plugin draws, and the outgoing string may
        // still be borrowed by whoever is mid-frame. See `folder_retired`.
        editor.app.retireFolder();
    }
    editor.app.folder = try editor.app.gpa.dupe(u8, path);
    editor.command_palette.invalidate();
    try editor.app.recents.appendFolder(try editor.app.gpa.dupe(u8, path));
    // Written now, not only at quit: a browser tab is closed, never quit, so the web keeps
    // recents only if they are stored as they change. Cheap enough to do everywhere.
    if (std.fs.path.join(editor.app.gpa, &.{ editor.app.config_folder, "recents.zon" })) |recents_path| {
        defer editor.app.gpa.free(recents_path);
        editor.app.recents.save(editor.app.gpa, recents_path) catch |err| dvui.log.warn("recents: not saved: {s}", .{@errorName(err)});
    } else |_| {}
    // The dvui menu re-reads recents every frame; the macOS submenu is retained state.
    fizzy.backend.rebuildNativeRecentFolders();
    if (editor.app.host.selectedSurface(sdk.keywords.ide.sidebar)) |s| {
        editor.app.host.setSelectionFor(sdk.keywords.ide.sidebar, s.id);
    }

    for (editor.app.host.plugins.items) |plugin| plugin.onFolderOpen(editor.app.gpa);
    // `.gitignore` and the folder watcher are the disk's; a mount's freshness is its plugin's
    // (a drive's change feed), and its listings hide nothing.
    editor.ignore = if (on_mount) .{} else try IgnoreRules.load(editor.app.gpa, path);
    // After `ignore` — `FolderWatcher.tick` filters through it, and arming first would let a
    // burst arrive while the rules still belong to the previous folder.
    if (editor.app.folder_watcher) |*w| w.setFolder(if (on_mount) null else editor.app.folder);
}

/// Perform a close queued by `closeProjectFolder` during an earlier frame.
fn applyPendingFolderClose(editor: *Editor) void {
    if (!editor.app.pending_folder_close) return;
    editor.app.pending_folder_close = false;
    if (editor.app.folder == null) return;
    if (editor.app.folder_watcher) |*w| w.setFolder(null);
    editor.ignore.deinit(editor.app.gpa);
    for (editor.app.host.plugins.items) |plugin| plugin.onFolderClose();
    editor.app.retireFolder();
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
        const idx = editor.app.open_files.getIndex(doc.id) orelse return error.Unexpected;
        doc.owner.setDocumentGrouping(doc, grouping);
        editor.workbench.setActiveDocIndex(idx);
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
/// would open as two documents. See `fizzy.core.paths.normalize`.
pub fn openFilePath(editor: *Editor, path_in: []const u8, grouping: u64) !bool {
    const path = try fizzy.core.paths.normalize(editor.app.gpa, path_in);
    defer editor.app.gpa.free(path);

    // Already open? Just focus it. (`docFromPath` also collapses lexical variants, so a doc
    // opened under a pre-normalization spelling is still found.)
    if (editor.docFromPath(path)) |doc| {
        if (editor.app.open_files.getIndex(doc.id)) |i| {
            editor.workbench.setActiveDocIndex(i);
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

    // A mounted path has no file for a worker to open: it is read through the mount and
    // opened from the bytes when they land — on any target, the browser included.
    if (editor.doc_io.owns(path)) return editor.doc_io.open(path, grouping);

    // Resolve the owning plugin from the file-type registry before spawning. No owner
    // means no plugin claims this extension — reject here rather than spawning a worker
    // that would only fail with InvalidFile.
    const owner = editor.app.host.pluginForExtension(std.fs.path.extension(path)) orelse {
        dvui.log.warn("No plugin handles file: {s}", .{path});
        return false;
    };

    // Spawn a worker. The job owns the (already canonical) path string we'll key the map by.
    const io = dvui.io;
    const job = try FileLoadJob.create(editor.app.gpa, path, owner, grouping);
    errdefer job.destroy(io);

    try editor.loading_jobs.put(editor.app.gpa, job.path, job);
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
        defer editor.app.gpa.free(path_in);
        break :blk try fizzy.core.paths.normalize(editor.app.gpa, path_in);
    };

    // Freed on every exit path below except the success transfer into the plugin document
    // (loaders dupe `path`). Cleared to null after that free so a later `errdefer` can't
    // double-free if `insertOpenDoc` fails.
    var path_owned: ?[]u8 = path;
    errdefer if (path_owned) |p| editor.app.gpa.free(p);

    if (editor.docFromPath(path)) |existing| {
        if (editor.app.open_files.getIndex(existing.id)) |idx| {
            editor.workbench.setActiveDocIndex(idx);
        }
        return error.AlreadyOpen;
    }

    const owner = editor.app.host.pluginForExtension(std.fs.path.extension(path)) orelse {
        return error.InvalidExtension;
    };

    const staging = try owner.allocDocumentBuffer(editor.app.gpa);
    defer editor.app.gpa.free(staging.backing);

    const handled = try owner.loadDocumentFromBytes(path, bytes, staging.buf.ptr);
    if (!handled) return error.InvalidFile;

    editor.app.gpa.free(path);
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
    defer to_remove.deinit(editor.app.gpa);

    var it = editor.loading_jobs.valueIterator();
    while (it.next()) |job_ptr| {
        const job = job_ptr.*;
        if (!job.done.load(.acquire)) continue;
        to_remove.append(editor.app.gpa, job) catch continue;
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
                    if (editor.app.open_files.getIndex(id)) |idx| {
                        editor.workbench.setActiveDocIndex(idx);
                        editor.last_load_request_path = null;
                    }
                    editor.pending_composite_warmup = true;
                }
            },
            // A failed load wrote nothing into the staging buffer — `loadDocument` errors
            // before `out.* = ...` — so there is no document to deinit, only bytes to free.
            // Deiniting here freed pointers that were never assigned.
            .failed => {
                // `job.err` is not named here on purpose. A Zig error is an integer numbered
                // per compilation, so one returned across the dylib boundary carries the
                // plugin's numbering and `@errorName` would print whichever of *our* errors
                // happens to share it. Only the plugin can say why; it logs that itself.
                dvui.log.err("Failed to open file: {s}", .{job.path});
                dvui.toast(@src(), .{ .message = std.fmt.allocPrint(
                    editor.app.arena.allocator(),
                    "Could not open {s}.",
                    .{std.fs.path.basename(job.path)},
                ) catch "Could not open file." });
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

/// Cancel every in-flight load. Workers exit at the next cancellation checkpoint (after
/// `fromPath` returns) and discard their results. Used on app quit.
pub fn cancelAllLoadingJobs(editor: *Editor) void {
    var it = editor.loading_jobs.valueIterator();
    while (it.next()) |job_ptr| {
        job_ptr.*.cancelled.store(true, .monotonic);
    }
}

/// Iterates the save-complete toast subwindow (`fizzy.core.dialogs.save_toast_subwindow_id`) and
/// renders each toast inside a self-sized floating column anchored to the bottom-center of
/// the viewport, so back-to-back saves stack vertically rather than overlapping. Each toast's
/// display function (`saveCompleteToastDisplay`) builds its own card body + fade-out animator
/// + self-remove on timer expiry.
pub fn drawSaveToasts(editor: *Editor) void {
    if (dvui.toastsFor(fizzy.core.dialogs.save_toast_subwindow_id) == null) return;

    // Anchor at the center of the active workspace's canvas rect (in physical pixels). Using
    // `from` + `from_gravity = 0.5,0.5` lets the FloatingWidget self-size to the toast column
    // and centers it around the anchor. Falls back to the window center if no workspace has
    // rendered yet.
    const anchor_physical: dvui.Point.Physical = if (editor.workbench.activeWorkspaceCanvasRectPhysical()) |r| .{
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

    var it = dvui.toastsFor(fizzy.core.dialogs.save_toast_subwindow_id) orelse return;
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
        const elapsed_ms = @divTrunc(fizzy.core.perf.nanoTimestamp() - start_ns, std.time.ns_per_ms);
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
    // The card is sized by its content, the way dvui sizes a floating widget: last frame's
    // recorded min size. That is only known after a frame has drawn it, so the first frame
    // estimates and asks for another — a fixed height fit the default font and clipped the
    // rows under a larger one.
    const src = @src();
    const card_id = dvui.parentGet().extendId(src, 0);
    const measured = dvui.minSizeGet(card_id);
    if (measured == null) dvui.refresh(null, @src(), card_id);
    const card_w: f32 = @max(320, if (measured) |m| m.w else 0);
    const row_h: f32 = 26;
    const header_h: f32 = 32;
    const card_h: f32 = if (measured) |m| m.h else header_h + @as(f32, @floatFromInt(visible_count)) * row_h;
    const card_rect: dvui.Rect = blk: {
        if (editor.workbench.activeWorkspaceCanvasRectPhysical()) |rs_phys| {
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
    fw.init(src, .{ .mouse_events = false }, .{
        .rect = card_rect,
        .background = true,
        // Content-fill @ 0.85 matches the look of the other dialog-style popups in the editor.
        .color_fill = .{ .color = dvui.themeGet().color(.content, .fill).opacity(0.85) },
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
        .color_text = .{ .color = dvui.themeGet().color(.content, .text) },
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
        fizzy.core.dialogs.bubbleSpinner(@src(), .{
            .min_size_content = .{ .w = 18, .h = 18 },
            .gravity_y = 0.5,
            .color_text = .{ .color = dvui.themeGet().color(.content, .text) },
            .padding = .{ .w = 8 },
        }, .{});

        const basename = std.fs.path.basename(job.path);
        const phase = job.currentPhase();
        dvui.label(@src(), "{s} — {s}…", .{ basename, FileLoadJob.phaseLabel(phase) }, .{
            .expand = .horizontal,
            .gravity_y = 0.5,
            .color_text = .{ .color = dvui.themeGet().color(.content, .text) },
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
    const pending_owner = editor.app.host.pending_new_document_owner;
    editor.app.host.pending_new_document_owner = null;
    const owner = pending_owner orelse editor.app.host.pluginWithCreateDocument() orelse return error.NoEditorPlugin;
    const staging = try owner.allocDocumentBuffer(editor.app.gpa);
    defer editor.app.gpa.free(staging.backing);

    owner.createDocument(path, grid, staging.buf.ptr) catch {
        owner.deinitDocumentBuffer(staging.buf.ptr);
        dvui.log.err("Failed to create file: {s}", .{path});
        return error.FailedToCreateFile;
    };

    const id = owner.documentIdFromBuffer(staging.buf.ptr);
    try editor.insertOpenDoc(staging.buf.ptr, owner, id);
    editor.workbench.setActiveDocIndex(editor.app.open_files.count() - 1);
    editor.pending_composite_warmup = true;

    return editor.app.docById(id) orelse return error.FailedToCreateFile;
}

/// Dispatch a generic fizzy action to the active document owner's command (`<owner_id>.<action>`).
/// No active doc, or an owner that registered no such command, is a clean no-op. This is how the
/// fizzy's Edit menu / keybinds reach per-editor actions without naming any plugin.
fn runActiveDocCommand(editor: *Editor, action: []const u8) !void {
    const doc = editor.activeDoc() orelse return;
    const id = try std.fmt.allocPrint(editor.app.arena.allocator(), "{s}.{s}", .{ doc.owner.id, action });
    try editor.app.host.runCommand(id);
}

/// Whether the active document's owner registered `action` as a command.
pub fn activeDocCommandEnabled(editor: *Editor, action: []const u8) bool {
    const doc = editor.activeDoc() orelse return false;
    var buf: [128]u8 = undefined;
    const id = std.fmt.bufPrint(&buf, "{s}.{s}", .{ doc.owner.id, action }) catch return false;
    return editor.app.host.commandEnabled(id);
}

/// Whether the active document's owner registered `action` as a command at all (regardless of
/// its current enabled state). Menus use this to decide whether to show the item in the first
/// place — an owner that never registered the action shouldn't get a permanently-greyed entry.
pub fn activeDocHasCommand(editor: *Editor, action: []const u8) bool {
    const doc = editor.activeDoc() orelse return false;
    var buf: [128]u8 = undefined;
    const id = std.fmt.bufPrint(&buf, "{s}.{s}", .{ doc.owner.id, action }) catch return false;
    return editor.app.host.hasCommand(id);
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
/// focused widget with its own copy/paste handling — fizzy's Output Panel, a plugin's search
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
    if (editor.hostWrites(doc)) {
        try editor.saveThroughHost(doc);
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

/// Whether the host writes this document (`DocumentIo`) rather than its owner: always on a
/// mount, and on the disk whenever the owner can serialize. An owner without `documentBytes`
/// writes its own files — and can only ever reach the disk.
fn hostWrites(editor: *Editor, doc: sdk.DocHandle) bool {
    if (editor.doc_io.owns(doc.owner.documentPath(doc))) return true;
    if (comptime builtin.target.cpu.arch == .wasm32) return false; // the disk does not exist there
    return doc.owner.canSaveThroughHost();
}

/// Save through the host: its owner serializes, the path's filesystem writes, and the owner
/// hears back when the write lands. An owner without `documentBytes` cannot save to a mount
/// at all, which is said once rather than failing silently.
fn saveThroughHost(editor: *Editor, doc: sdk.DocHandle) !void {
    editor.doc_io.save(doc, doc.owner.documentPath(doc)) catch |err| switch (err) {
        error.SaveInProgress => {},
        error.OwnerCannotSaveToMount => {
            dvui.log.err("{s} cannot be saved to a mounted drive by its editor", .{doc.owner.documentPath(doc)});
            dvui.toast(@src(), .{ .message = "This editor cannot save to a mounted drive." });
        },
        else => return err,
    };
}

/// Web only: serialize `doc` and hand it to the browser as a download named `path`'s basename,
/// then tell the owner it was written under that name.
fn downloadDocument(editor: *Editor, doc: sdk.DocHandle, path: []const u8) !void {
    if (comptime builtin.target.cpu.arch != .wasm32) return error.Unsupported;
    const bytes = (try doc.owner.documentBytes(doc, editor.app.gpa)) orelse return error.Unsupported;
    defer editor.app.gpa.free(bytes);
    try dvui.backend.downloadData(std.fs.path.basename(path), bytes);
    try doc.owner.documentWritten(doc, path);
    editor.documentPathChanged(doc);
}

/// Whether a save is in flight for `doc`, whichever side is doing the writing.
pub fn docSaving(editor: *Editor, doc: sdk.DocHandle) bool {
    return doc.owner.isDocumentSaving(doc) or editor.doc_io.saving(doc.id);
}

/// Browser: pick download filename/extension before encoding (`processPendingSaveAs`).
pub fn requestWebSaveDialog(editor: *Editor, kind: Dialogs.WebSaveAs.Kind) void {
    if (comptime builtin.target.cpu.arch != .wasm32) return;
    const doc = editor.activeDoc() orelse return;
    Dialogs.WebSaveAs.request(std.fs.path.basename(doc.owner.documentPath(doc)), kind);
}

/// Kick off an async save for every dirty file with a recognized extension.
/// Each save lands in the single save-queue worker and runs serially in the
/// background; the GUI stays responsive. Files that need Save As (no extension),
/// flat-raster confirmation, or an unresolved on-disk conflict are skipped — the
/// user can save those individually. Files that are already saving are also
/// skipped (their `saveAsync` no-ops).
pub fn saveAll(editor: *Editor) !void {
    for (editor.app.open_files.values()) |doc| {
        if (!doc.owner.isDirty(doc)) continue;
        if (!doc.owner.documentHasRecognizedSaveExtension(doc)) continue;
        if (doc.owner.saveNeedsConfirmation(doc)) continue;
        if (editor.document_watcher) |*w| {
            if (w.hasDiskConflict(doc.id)) continue;
        }
        if (editor.hostWrites(doc)) {
            editor.saveThroughHost(doc) catch |err| {
                dvui.log.err("Save All: file {s} failed: {s}", .{ doc.owner.documentPath(doc), @errorName(err) });
            };
            continue;
        }
        if (editor.document_watcher) |*w| w.markPendingBaseline(doc.id);
        doc.owner.saveDocument(doc) catch {
            dvui.log.err("Save All: file {s} failed — see {s}'s own log", .{ doc.owner.documentPath(doc), doc.owner.id });
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
pub fn requestSaveAs(editor: *Editor) void {
    const doc = editor.activeDoc() orelse return;
    const def = doc.owner.documentDefaultSaveAsFilename(doc, editor.app.gpa) catch {
        std.log.err("Failed to build default save-as name", .{});
        return;
    };
    defer editor.app.gpa.free(def);
    const current_file_dir: ?[]const u8 = std.fs.path.dirname(doc.owner.documentPath(doc));
    fizzy.backend.showSaveFileDialog(saveAsDialogCallback, &save_as_dialog_filters, def, current_file_dir);
}

/// Clears pending save-as / save-and-close state when the user dismisses a save dialog.
pub fn cancelPendingSaveDialog(editor: *Editor) void {
    if (editor.app.pending_save_as_path) |p| {
        editor.app.gpa.free(p);
        editor.app.pending_save_as_path = null;
    }
    if (comptime builtin.target.cpu.arch == .wasm32) {
        const WebFileIo = @import("WebFileIo.zig");
        if (WebFileIo.pending_save_filename) |p| {
            editor.app.gpa.free(p);
            WebFileIo.pending_save_filename = null;
        }
    }

    const file_id = editor.app.pending_close_file_id orelse if (editor.activeDoc()) |doc| doc.id else null;
    editor.app.pending_close_file_id = null;

    if (file_id) |id| {
        _ = editor.app.pending_close_after_save.swapRemove(id);
        if (editor.app.docById(id)) |doc| {
            doc.owner.resetDocumentSaveUIState(doc);
        }
    } else if (editor.activeDoc()) |doc| {
        doc.owner.resetDocumentSaveUIState(doc);
    }

    if (editor.app.quit_save_all_ids.items.len > 0 or editor.app.quit_in_progress) {
        editor.app.abortSaveAllQuit();
    }
}

/// Save dialog may invoke this from AppKit outside `Window.begin` / `end`; do not use `currentWindow` here.
pub fn saveAsDialogCallback(paths: ?[][:0]const u8) void {
    if (paths == null) {
        fizzy.editor().cancelPendingSaveDialog();
        return;
    }
    const p = paths.?;
    if (p.len == 0) return;
    const path0 = p[0];
    if (path0.len == 0) return;
    if (fizzy.editor().app.pending_save_as_path) |old| {
        fizzy.entry().allocator.free(old);
    }
    fizzy.editor().app.pending_save_as_path = fizzy.entry().allocator.dupe(u8, path0[0..path0.len]) catch {
        dvui.log.err("Save As: out of memory queuing path", .{});
        return;
    };
}

pub fn processPendingSaveAs(editor: *Editor) void {
    const path = blk: {
        if (editor.app.pending_save_as_path) |p| break :blk p;
        if (comptime builtin.target.cpu.arch == .wasm32) {
            const WebFileIo = @import("WebFileIo.zig");
            if (WebFileIo.pending_save_filename) |p| break :blk p;
        }
        return;
    };
    const owned_by_editor = editor.app.pending_save_as_path != null;
    editor.app.pending_save_as_path = null;
    if (comptime builtin.target.cpu.arch == .wasm32) {
        if (!owned_by_editor) {
            const WebFileIo = @import("WebFileIo.zig");
            WebFileIo.pending_save_filename = null;
        }
    }
    defer editor.app.gpa.free(path);

    const doc = editor.activeDoc() orelse {
        editor.app.pending_close_file_id = null;
        return;
    };

    if (comptime builtin.target.cpu.arch == .wasm32) {
        // The browser's "save" is a download. An owner with the storage-agnostic hooks needs
        // no code of its own for it: serialize, hand the bytes to the browser, and treat the
        // chosen name as the document's from here on.
        if (doc.owner.canSaveThroughHost()) {
            editor.downloadDocument(doc, path) catch |err| dvui.log.err("Save As: {any}", .{err});
            return;
        }
    }
    const host_writes_here = editor.doc_io.owns(path) or (builtin.target.cpu.arch != .wasm32 and doc.owner.canSaveThroughHost());
    if (host_writes_here) {
        // The owner adopts the new path when the write lands (`documentWritten`), and
        // `documentPathChanged` runs there; nothing below applies until then.
        editor.doc_io.save(doc, path) catch |err| switch (err) {
            error.OwnerCannotSaveToMount => dvui.toast(@src(), .{ .message = "This editor cannot save to a mounted drive." }),
            else => dvui.log.err("Save As: {any}", .{err}),
        };
        return;
    }
    doc.owner.saveDocumentAs(doc, path, dvui.currentWindow()) catch |err| {
        if (err == error.UnsupportedSaveExtension) {
            dvui.log.err("Save As: choose extension .fiz, .png, .jpg, or .jpeg (got {s})", .{std.fs.path.extension(path)});
        } else {
            dvui.log.err("Save As: {any}", .{err});
        }
        return;
    };
    // The path and dirty flag both just changed, part-way through a frame that several
    // consumers have already drawn with the old values; this re-keys what the path names and
    // asks for the frame that shows the new one.
    editor.documentPathChanged(doc);

    if (editor.app.pending_close_file_id) |cid| {
        if (doc.id == cid) {
            editor.app.pending_close_file_id = null;
            editor.rawCloseFileID(cid) catch |err| {
                dvui.log.err("Failed to close file after Save As: {s}", .{@errorName(err)});
            };
            if (editor.app.quit_save_all_ids.items.len > 0) {
                if (std.mem.indexOfScalar(u64, editor.app.quit_save_all_ids.items, cid)) |ix| {
                    _ = editor.app.quit_save_all_ids.swapRemove(ix);
                }
                editor.app.pending_quit_continue = true;
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

pub fn openInFileBrowser(editor: *Editor, path: []const u8) !void {
    // Darwin goes through `darwin_spawn` rather than `std.process.run`: the latter walks the
    // `environ` array captured at startup, which any `unsetenv` elsewhere in the process (SDL,
    // a plugin, a system framework) shrinks *in place* — leaving a NULL before the captured
    // length and segfaulting the whole app on the next spawn. See `darwin_spawn.zig`.
    if (builtin.os.tag == .macos) {
        // `posix_spawn` (unlike `posix_spawnp`) does not search `$PATH`, so name `open` in full.
        const child = fizzy.core.darwin_spawn.spawn(editor.app.gpa, .{
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
        const arg = try std.fmt.allocPrint(editor.app.gpa, "/select,{s}", .{path});
        defer editor.app.gpa.free(arg);
        _ = std.process.run(editor.app.gpa, dvui.io, .{ .argv = &.{ "explorer.exe", arg } }) catch {
            dvui.log.err("Failed to open file browser", .{});
            return;
        };
        return;
    }
    _ = std.process.run(editor.app.gpa, dvui.io, .{ .argv = &.{ "xdg-open", path } }) catch {
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
    if (editor.app.open_files.get(id)) |doc| {
        if (doc.owner.isDirty(doc)) {
            Dialogs.UnsavedClose.request(id);
            return;
        }
        try editor.rawCloseFileID(id);
    }
}

pub fn closeFile(editor: *Editor, index: usize) !void {
    const doc = editor.app.docAt(index) orelse return;
    try editor.closeFileID(doc.id);
}

pub fn rawCloseFile(editor: *Editor, index: usize) !void {
    const doc = editor.app.docAt(index) orelse return;
    editor.workbench.documentClosed(doc);

    if (editor.document_watcher) |*w| w.untrack(doc.id);
    editor.doc_io.documentClosed(doc.id);
    editor.unregisterDocSurface(doc.id);
    editor.app.closeDocumentResources(doc);
    editor.app.open_files.orderedRemoveAt(index);
}

pub fn rawCloseFileID(editor: *Editor, id: u64) !void {
    const doc = editor.app.open_files.get(id) orelse return;
    editor.workbench.documentClosed(doc);

    if (editor.document_watcher) |*w| w.untrack(doc.id);
    editor.doc_io.documentClosed(doc.id);
    editor.unregisterDocSurface(doc.id);
    editor.app.closeDocumentResources(doc);
    _ = editor.app.open_files.orderedRemove(id);
}

pub fn deinit(editor: *Editor) !void {
    // Owned outright rather than cached by dvui, so it has to be released explicitly.
    editor.app.layout.center_transition.discard();
    editor.app.layout.center_prev_id = null;
    editor.app.layout.view_drag.discard();
    editor.app.layout.deinitSwaps(editor.app.gpa);
    editor.app.layout.regions.deinit(editor.app.gpa);
    editor.app.layout.regions_building.deinit(editor.app.gpa);

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
    if (editor.app.settings_watcher) |*w| {
        w.stop();
        editor.app.settings_watcher = null;
    }
    // Before the plugin `deinit` loop below: `tick` fans out into plugin vtables, and this
    // joins the thread that feeds it.
    if (editor.app.folder_watcher) |*w| {
        w.deinit();
        editor.app.folder_watcher = null;
    }

    // Tear workspaces down first: `Workspace.deinit` calls back into the owning plugin
    // (e.g. `removeCanvasPane`), so it must run while plugin state is still alive — i.e. before
    // the plugin `deinit` loop below frees it.
    editor.workbench.deinitWorkspaces();

    // Drain & join the save-queue worker before tearing anything else down. Any
    // queued jobs need to finish writing or be dropped before File data is freed.
    for (editor.app.host.plugins.items) |plugin| plugin.deinit();
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
        editor.loading_jobs.deinit(editor.app.gpa);
    }
    editor.doc_io.deinit();

    editor.workbench.clearFileTreeTabDragDropState();

    if (editor.app.pending_save_as_path) |p| {
        editor.app.gpa.free(p);
        editor.app.pending_save_as_path = null;
    }

    editor.app.quit_save_all_ids.deinit(editor.app.gpa);
    editor.app.quit_saves_in_flight.deinit(editor.app.gpa);
    editor.app.pending_close_after_save.deinit(editor.app.gpa);

    editor.app.recents.save(editor.app.gpa, try std.fs.path.join(editor.app.gpa, &.{ editor.app.config_folder, "recents.zon" })) catch {
        dvui.log.err("Failed to save recents", .{});
    };
    editor.app.recents.deinit(editor.app.gpa);

    try saveSettingsRaw(editor);
    saveWindowRatiosRaw(editor);
    // Only after the flush above, which writes the assignments out.
    editor.app.layout.deinitAssignments(editor.app.gpa);
    editor.app.layout.deinitExtents(editor.app.gpa);
    editor.app.layout.deinitQualified(editor.app.gpa);
    editor.app.layout.clearPendingStore(editor.app.gpa);
    editor.app.layout.picker.close(editor.app.gpa);
    {
        // The registry itself goes with `host.deinit` below; these are the app's own strings.
        var it = editor.doc_surfaces.valueIterator();
        while (it.next()) |ds| {
            editor.app.gpa.free(ds.*.id);
            editor.app.gpa.destroy(ds.*);
        }
        editor.doc_surfaces.deinit(editor.app.gpa);
    }
    editor.app.settings.deinit(editor.app.gpa);

    editor.explorer.deinit();
    editor.panel.deinit(editor.app.gpa);
    editor.app.gpa.destroy(editor.panel);

    PluginStore.deinit();
    editor.unloadPluginLibs();
    editor.app.host.deinit();
    editor.workbench.deinit();
    // After the plugin `deinit` loop above and after `host.deinit`: plugin teardown can still
    // reach `host.files`, and this frees what it would read.
    editor.app.host.files = null;
    editor.app.file_table.deinit();
    editor.app.secrets.deinit();

    // Pixel-art state is owned by the pixi plugin now: its `pluginDeinit` (run in the plugin
    // loop above) persists the project and frees its own state + packer.

    editor.ignore.deinit(editor.app.gpa);

    if (editor.app.keybind_conflicts) |c| {
        editor.app.gpa.free(c);
        editor.app.keybind_conflicts = null;
    }
    if (editor.app.keybinds_overrides) |*f| {
        f.deinit(editor.app.gpa);
        editor.app.keybinds_overrides = null;
    }
    KeybindSettings.deinit(editor.app.gpa);
    editor.app.keymap.deinit(editor.app.gpa);

    if (editor.app.folder) |folder| editor.app.gpa.free(folder);
    editor.app.releaseRetiredFolders();
    editor.app.folder_retired.deinit(editor.app.gpa);
    editor.app.arena.deinit();
}

// ---- SettingsWatcher.Sink: what fizzy reconciles when its config folder changes -------------
//
// Four passes in a deliberate order, which is exactly the kind of thing that belongs to the app
// rather than the watcher: an external enable/disable should settle before a rebuilt dylib is
// considered for reload.

fn configWatchSink(editor: *Editor) SettingsWatcher.Sink {
    return .{ .ctx = editor, .changed = configChanged };
}

fn configChanged(ctx: *anyopaque) void {
    const editor: *Editor = @ptrCast(@alignCast(ctx));
    editor.reconcileExternalSettingsChange();
    // Same watch, different trigger: a rebuilt/reinstalled plugin dylib is an event in this tree
    // but never moves `settings.zon`'s hash, so it needs its own pass — after the settings one.
    editor.reconcileChangedPluginBinaries();
    // And the mirror of that pass for a plugin that is *not* running because its last load
    // failed: a rebuild is invisible to both `settings.zon`'s hash and `loaded_plugin_libs`.
    editor.reconcileFailedPluginBinaries();
    // Same again for a plugin directory that appeared (a `zig build install` from a plugin repo,
    // or a hand-copied build). Tracked as disabled — never auto-loaded (R12) — so the Plugins tab
    // can offer it.
    editor.reconcileDiscoveredPlugins();
}

// ---- FolderWatcher.Sink: what fizzy does with on-disk changes -----------------------------
//
// The watcher coalesces and hands over; these two answer "which of these matter" and "who hears
// about them" — both of which are fizzy's policy, not the watcher's.

fn folderWatchSink(editor: *Editor) FolderWatcher.Sink {
    return .{ .ctx = editor, .wanted = folderEventWanted, .changed = folderPathsChanged };
}

fn folderEventWanted(ctx: *anyopaque, path: []const u8, name: []const u8, kind: std.Io.File.Kind) bool {
    const editor: *Editor = @ptrCast(@alignCast(ctx));
    const folder = editor.app.folder orelse return false;
    return !editor.ignore.isIgnored(folder, path, name, kind);
}

fn folderPathsChanged(ctx: *anyopaque, events: []const sdk.Plugin.PathEvent, truncated: bool) void {
    const editor: *Editor = @ptrCast(@alignCast(ctx));
    editor.app.host.notifyFolderPathsChanged(.{ .events = events, .truncated = truncated });
}

// ---- PluginManager: what the store needs from this application --------------------------
//
// Fizzy filling in the seam the store talks to (`PluginManager.zig`). Every member forwards to
// state fizzy owns; the store never reaches for `fizzy.editor()`, so a different app supplies
// its own and gets the same store.

fn pmSelf(ctx: *anyopaque) *Editor {
    return @ptrCast(@alignCast(ctx));
}

const plugin_manager_vtable: PluginManager.VTable = .{
    .isDisabled = struct {
        fn f(ctx: *anyopaque, id: []const u8) bool {
            return pmSelf(ctx).app.isPluginDisabled(id);
        }
    }.f,
    .isUndecided = struct {
        fn f(ctx: *anyopaque, id: []const u8) bool {
            return pmSelf(ctx).app.isPluginUndecided(id);
        }
    }.f,
    .isAutoUpdate = struct {
        fn f(ctx: *anyopaque, id: []const u8) bool {
            return pmSelf(ctx).app.isPluginAutoUpdate(id);
        }
    }.f,
    .setAutoUpdate = struct {
        fn f(ctx: *anyopaque, id: []const u8, on: bool) anyerror!void {
            return pmSelf(ctx).setPluginAutoUpdate(id, on);
        }
    }.f,
    .updateMode = struct {
        fn f(ctx: *anyopaque) PluginManager.UpdateMode {
            return switch (pmSelf(ctx).app.settings.plugin_update_mode) {
                .prompt => .prompt,
                .silent => .silent,
            };
        }
    }.f,
    .disabledIds = struct {
        fn f(ctx: *anyopaque) []const []const u8 {
            return pmSelf(ctx).app.disabled_plugin_ids.items;
        }
    }.f,
    .loadedLibs = struct {
        fn f(ctx: *anyopaque) []const PluginLoader.LoadedLib {
            return pmSelf(ctx).app.loaded_plugin_libs.items;
        }
    }.f,
    .failures = struct {
        fn f(ctx: *anyopaque) []const PluginManager.Failure {
            const editor = pmSelf(ctx);
            // Rebuilt in the frame arena rather than stored twice: `FailedPlugin` carries
            // reconciliation bookkeeping (the rejected build's mtime + size) that is fizzy's
            // business and none of the store's.
            const a = editor.app.arena.allocator();
            var out = a.alloc(PluginManager.Failure, editor.app.failed_user_plugins.items.len) catch return &.{};
            for (editor.app.failed_user_plugins.items, 0..) |failed, i| {
                out[i] = .{
                    .id = failed.id,
                    .reason = failed.reason,
                    .detail = failed.detail,
                    .plugin_version = failed.plugin_version,
                };
            }
            return out;
        }
    }.f,
    .builtinManifest = struct {
        fn f(ctx: *anyopaque, id: []const u8) ?sdk.Manifest {
            return pmSelf(ctx).builtinManifest(id);
        }
    }.f,
    .install = struct {
        fn f(ctx: *anyopaque, id: []const u8) anyerror!void {
            return pmSelf(ctx).installAndLoadPlugin(id);
        }
    }.f,
    .installFromUrl = struct {
        fn f(ctx: *anyopaque, id: []const u8, url: []const u8) anyerror!void {
            return pmSelf(ctx).loadWebPlugin(id, url);
        }
    }.f,
    .updateFromUrl = struct {
        fn f(ctx: *anyopaque, id: []const u8, url: []const u8) anyerror!void {
            return pmSelf(ctx).updateWebPlugin(id, url);
        }
    }.f,
    .update = struct {
        fn f(ctx: *anyopaque, id: []const u8, force: bool) anyerror!void {
            return pmSelf(ctx).updatePlugin(id, force);
        }
    }.f,
    .uninstall = struct {
        fn f(ctx: *anyopaque, id: []const u8, force: bool) anyerror!void {
            return pmSelf(ctx).uninstallPlugin(id, force);
        }
    }.f,
    .setEnabled = struct {
        fn f(ctx: *anyopaque, id: []const u8, enabled: bool, force: bool) anyerror!void {
            return pmSelf(ctx).setPluginEnabled(id, enabled, force);
        }
    }.f,
    .reconcileDiscovered = struct {
        fn f(ctx: *anyopaque) void {
            pmSelf(ctx).reconcileDiscoveredPlugins();
        }
    }.f,
    .appUpdate = struct {
        fn f(_: *anyopaque) PluginManager.AppUpdate {
            return switch (update_notify.appUpdateState()) {
                .checking => .checking,
                .available, .installing => .pending,
                .none => .none,
            };
        }
    }.f,
    .offerUpdates = struct {
        fn f(_: *anyopaque) void {
            Dialogs.PluginUpdates.request();
        }
    }.f,
    .revealMain = struct {
        fn f(ctx: *anyopaque) void {
            pmSelf(ctx).revealCenter();
        }
    }.f,
};

pub fn pluginManager(editor: *Editor) PluginManager {
    return .{
        .ctx = editor,
        .host = &editor.app.host,
        .gpa = editor.app.gpa,
        .config_folder = editor.app.config_folder,
        .root_path = std.mem.sliceTo(fizzy.entry().root_path, 0),
        .registry_url = AppInfo.current.registry_url,
        .vtable = &plugin_manager_vtable,
    };
}
