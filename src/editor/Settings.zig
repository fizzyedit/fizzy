const builtin = @import("builtin");
const fizzy = @import("../fizzy.zig");
const std = @import("std");
const dvui = @import("dvui");
const SettingsMigration = @import("SettingsMigration.zig");

const Settings = @This();

pub const default_theme = "Fizzy Dark";

/// Duration after the last edit before autosave runs (during normal operation).
pub const autosave_timeout_ns: i128 = 500 * 1_000_000;

/// The zon-parsed on-disk value backing the most recent successful `load`, kept alive
/// for the process lifetime (freed in `deinit`) because `disabled_plugins` below borrows
/// straight out of it — see `Editor.seedDisabledPlugins`, which runs well after `load`
/// returns. `theme` is independently heap-owned (duped in `load`), so it survives even
/// though this is freed at shutdown rather than right after load.
var loaded: ?Settings = null;

pub const FlipbookView = enum { sequential, grid };
pub const Compatibility = enum { none, ldtk };

/// Canvas zoom/pan control preference. `auto` follows `dvui.mouseType()` after scroll events
/// (macOS defaults to trackpad when still unknown).
pub const InputScheme = enum { auto, mouse, trackpad };

/// Resolved zoom/pan style after applying `input_scheme`.
pub const ResolvedPanZoomScheme = enum { mouse, trackpad };

/// The ratio of the explorer to the artboard.
explorer_ratio: f32 = 0.35,

/// Height of the flipbook window.
panel_ratio: f32 = 0.25,

min_window_size: [2]f32 = .{ 640, 480 },

initial_window_size: [2]f32 = .{ 1280, 720 },

/// Touch or long-press duration (ms) before a context menu opens instead of a normal click.
hold_menu_duration_ms: u32 = 500,

/// When true, print frame/draw perf stats to the console (Debug / ReleaseSafe only for tick stats).
perf_logging: bool = false,

/// Pretend an app update is available (badge + launch toast). Restart after toggling.
debug_simulate_update_available: bool = false,

/// Maximum number of recents before removing oldest
max_recents: usize = 10,

/// Last selected UI theme (`dvui.Theme.name`). Always allocator-owned after `load`; see `setThemeName` / `deinit`.
theme: []const u8 = default_theme,

/// Logical font sizes applied to body / title / heading / mono slots for every theme (families unchanged).
font_body_size: f32 = 9,
font_title_size: f32 = 9,
font_heading_size: f32 = 8,
font_mono_size: f32 = 8,

/// Opacity of the background window
/// CURRENTLY ONLY SUPPORTED ON MACOS and Windows
window_opacity_dark: f32 = 0.7,
window_opacity_light: f32 = 0.3,

/// Opacity of the content area (also drives plugin panes that match the shell chrome).
content_opacity: f32 = 0.7,

/// Canvas zoom/pan control scheme shared by the image viewer, pixi, and any other
/// `CanvasWidget` consumer. `auto` picks mouse vs trackpad from `dvui.mouseType()`.
input_scheme: InputScheme = .auto,

/// Plugin ids the user has disabled in the store. Skipped at startup by
/// `Editor.loadUserPlugins` and unloaded live by `Editor.setPluginEnabled`. The slice
/// is pointed at an `Editor`-owned list at runtime (see `Editor.disabled_plugin_ids`);
/// it is only read here for (de)serialization.
disabled_plugins: []const []const u8 = &.{},

titlebar_height: f32 = 26.0, // This is the height of the titlebar in pixels

/// Empty strip below the top window edge (non-macOS), above the main title row (in-window menu, etc.).
titlebar_top_buffer: f32 = 10.0,

fn default(allocator: std.mem.Allocator) !Settings {
    return .{
        .theme = try allocator.dupe(u8, default_theme),
    };
}

pub fn resolvedPanZoomScheme(settings: *const Settings, is_macos: bool) ResolvedPanZoomScheme {
    return switch (settings.input_scheme) {
        .auto => switch (dvui.mouseType()) {
            .unknown => if (is_macos) .trackpad else .mouse,
            .mouse => .mouse,
            .trackpad => .trackpad,
        },
        .mouse => .mouse,
        .trackpad => .trackpad,
    };
}

pub fn setThemeName(settings: *Settings, allocator: std.mem.Allocator, name: []const u8) !void {
    if (std.mem.eql(u8, settings.theme, name)) return;
    const copy = try allocator.dupe(u8, name);
    allocator.free(settings.theme);
    settings.theme = copy;
}

/// Loads settings (`theme` is always heap-owned after successful return — see `setThemeName` / `deinit`).
/// One-shot migrates a legacy `settings.json` sibling to `settings.zon` first (see
/// `SettingsMigration.migrateIfNeeded`), splitting any legacy per-plugin blobs out to their own
/// `<plugins_dir>/<id>.settings.zon` files. Unknown fields are ignored (forward-compat with
/// newer on-disk shapes).
pub fn load(allocator: std.mem.Allocator, path: []const u8, plugins_dir: ?[]const u8) !Settings {
    // Wasm: no on-disk config; `fizzy.fs` uses `Io.Dir.cwd()` (posix.AT).
    if (comptime builtin.target.cpu.arch == .wasm32) return default(allocator);

    @setEvalBranchQuota(10_000);
    SettingsMigration.migrateIfNeeded(allocator, path, plugins_dir);

    const data = fizzy.fs.readZ(allocator, dvui.io, path) catch return default(allocator);
    defer allocator.free(data);

    // Older builds embedded each plugin's settings as an escaped-string blob in settings.zon's
    // own `plugins` list; split any of those out to their own file before parsing (which just
    // ignores the now-unknown `plugins` key below).
    SettingsMigration.splitEmbeddedPluginsIfNeeded(allocator, data, plugins_dir);

    const parsed = std.zon.parse.fromSliceAlloc(Settings, allocator, data, null, .{ .ignore_unknown_fields = true }) catch |err| {
        dvui.log.warn("Could not parse settings.zon ({s}); using defaults.", .{@errorName(err)});
        return default(allocator);
    };

    if (loaded) |old| std.zon.parse.free(allocator, old);
    loaded = parsed;

    var result = parsed;
    // Own theme independently of `loaded` (freed in `deinit`, long after this returns).
    result.theme = try allocator.dupe(u8, parsed.theme);
    return result;
}

/// Serialize the shell's own settings into `settings.zon`. Per-plugin settings no longer live
/// here at all — each plugin persists its own `<plugins_dir>/<id>.settings.zon` directly (see
/// `Host.flushPluginSettings`), so there is nothing opaque left to splice in.
pub fn serialize(settings: *const Settings, allocator: std.mem.Allocator) ![]u8 {
    @setEvalBranchQuota(10_000);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try std.zon.stringify.serialize(settings.*, .{}, &aw.writer);
    return aw.toOwnedSlice();
}

pub fn save(settings: *Settings, allocator: std.mem.Allocator, path: []const u8) !void {
    const str = try serialize(settings, allocator);
    defer allocator.free(str);

    try std.Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = path, .data = str });
}

pub fn deinit(settings: *Settings, allocator: std.mem.Allocator) void {
    allocator.free(settings.theme);
    if (loaded) |d| {
        std.zon.parse.free(allocator, d);
        loaded = null;
    }
}
