const builtin = @import("builtin");
const fizzy = @import("../fizzy.zig");
const std = @import("std");
const dvui = @import("dvui");

const Settings = @This();

pub const default_theme = "Fizzy Dark";

/// Duration after the last edit before autosave runs (during normal operation).
pub const autosave_timeout_ns: i128 = 500 * 1_000_000;

pub var parsed: ?std.json.Parsed(Settings) = null;

pub const FlipbookView = enum { sequential, grid };
pub const Compatibility = enum { none, ldtk };

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
font_mono_size: f32 = 9,

/// Opacity of the background window
/// CURRENTLY ONLY SUPPORTED ON MACOS and Windows
window_opacity_dark: f32 = 0.7,
window_opacity_light: f32 = 0.3,

/// Opacity of the content area (also drives plugin panes that match the shell chrome).
content_opacity: f32 = 0.7,

/// Plugin ids the user has disabled in the store. Skipped at startup by
/// `Editor.loadUserPlugins` and unloaded live by `Editor.setPluginEnabled`. The slice
/// is pointed at an `Editor`-owned list at runtime (see `Editor.disabled_plugin_ids`);
/// it is only read here for (de)serialization.
///
/// Default disables the bundled `example` plugin on a fresh install (it is a template, not a
/// day-to-day tool). An existing `settings.json` overrides this — once the user enables it the
/// persisted list no longer contains "example", so the choice sticks.
disabled_plugins: []const []const u8 = &.{"example"},

titlebar_height: f32 = 26.0, // This is the height of the titlebar in pixels

/// Empty strip below the top window edge (non-macOS), above the main title row (in-window menu, etc.).
titlebar_top_buffer: f32 = 10.0,

fn default(allocator: std.mem.Allocator) !Settings {
    return .{
        .theme = try allocator.dupe(u8, default_theme),
    };
}

pub fn setThemeName(settings: *Settings, allocator: std.mem.Allocator, name: []const u8) !void {
    if (std.mem.eql(u8, settings.theme, name)) return;
    const copy = try allocator.dupe(u8, name);
    allocator.free(settings.theme);
    settings.theme = copy;
}

/// Loads settings (`theme` is always heap-owned after successful return — see `setThemeName` / `deinit`).
/// Unknown keys (e.g. the "plugins" object, parsed separately by `loadPluginStore`) are ignored.
pub fn load(allocator: std.mem.Allocator, path: []const u8) !Settings {
    // Wasm: no on-disk config; `fizzy.fs.read` uses `Io.Dir.cwd()` (posix.AT).
    if (comptime builtin.target.cpu.arch == .wasm32) return default(allocator);
    const maybe_data = fizzy.fs.read(allocator, dvui.io, path) catch null;
    const data = maybe_data orelse return default(allocator);
    defer allocator.free(data);

    const options = std.json.ParseOptions{
        .duplicate_field_behavior = .use_first,
        .ignore_unknown_fields = true,
        // Copy *every* parsed string into the parse arena (kept alive in `parsed` until `deinit`).
        .allocate = .alloc_always,
    };
    const p = std.json.parseFromSlice(Settings, allocator, data, options) catch |err| {
        dvui.log.warn("Could not parse settings.json ({s}); using defaults.", .{@errorName(err)});
        parsed = null;
        return default(allocator);
    };

    parsed = p;
    var result = p.value;
    // Own theme independently of JSON parse arena (arena is freed in `deinit`).
    result.theme = try allocator.dupe(u8, p.value.theme);
    return result;
}

/// Serialize the shell settings plus the opaque per-plugin store into a single
/// settings.json document: `{ <shell fields…>, "plugins": { <id>: <blob>, … } }`. The
/// plugin blobs are already-serialized JSON objects, spliced in verbatim — the shell
/// never interprets them.
pub fn serialize(
    settings: *const Settings,
    plugin_settings: *const std.StringArrayHashMapUnmanaged([]const u8),
    allocator: std.mem.Allocator,
) ![]u8 {
    const fields = try std.json.Stringify.valueAlloc(allocator, settings, .{});
    defer allocator.free(fields);
    // `fields` is a `{…}` object with at least one member, so dropping the trailing
    // brace and appending `,"plugins":{…}}` always yields valid JSON.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, fields[0 .. fields.len - 1]);
    try out.appendSlice(allocator, ",\"plugins\":{");
    var first = true;
    var it = plugin_settings.iterator();
    while (it.next()) |e| {
        if (!first) try out.append(allocator, ',');
        first = false;
        const key = try std.json.Stringify.valueAlloc(allocator, e.key_ptr.*, .{});
        defer allocator.free(key);
        try out.appendSlice(allocator, key);
        try out.append(allocator, ':');
        try out.appendSlice(allocator, e.value_ptr.*);
    }
    try out.appendSlice(allocator, "}}");
    return out.toOwnedSlice(allocator);
}

pub fn save(
    settings: *Settings,
    plugin_settings: *const std.StringArrayHashMapUnmanaged([]const u8),
    allocator: std.mem.Allocator,
    path: []const u8,
) !void {
    const str = try serialize(settings, plugin_settings, allocator);
    defer allocator.free(str);

    try std.Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = path, .data = str });
}

/// Populate `store` (id -> owned JSON blob) from the "plugins" object in settings.json.
/// One-time migration: a legacy flat settings.json (no "plugins" object) seeds the
/// pixel-art blob from the whole root so its moved fields (show_rulers, input_scheme, …)
/// survive the format change — pixel art ignores unknown keys, and the next save rewrites
/// the blob cleanly.
pub fn loadPluginStore(
    allocator: std.mem.Allocator,
    path: []const u8,
    store: *std.StringArrayHashMapUnmanaged([]const u8),
) void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    const data = fizzy.fs.read(allocator, dvui.io, path) catch return;
    defer allocator.free(data);

    var parsed_v = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return;
    defer parsed_v.deinit();

    const root = switch (parsed_v.value) {
        .object => |o| o,
        else => return,
    };

    if (root.get("plugins")) |plugins_val| {
        switch (plugins_val) {
            .object => |plugins| {
                var it = plugins.iterator();
                while (it.next()) |e| {
                    const blob = std.json.Stringify.valueAlloc(allocator, e.value_ptr.*, .{}) catch continue;
                    const key = allocator.dupe(u8, e.key_ptr.*) catch {
                        allocator.free(blob);
                        continue;
                    };
                    store.put(allocator, key, blob) catch {
                        allocator.free(key);
                        allocator.free(blob);
                    };
                }
                return;
            },
            else => {},
        }
    }

    // Legacy flat settings.json: seed the pixel-art blob from the whole root.
    const legacy_blob = std.json.Stringify.valueAlloc(allocator, parsed_v.value, .{}) catch return;
    const key = allocator.dupe(u8, "pixi") catch {
        allocator.free(legacy_blob);
        return;
    };
    store.put(allocator, key, legacy_blob) catch {
        allocator.free(key);
        allocator.free(legacy_blob);
    };
}

pub fn deinit(settings: *Settings, allocator: std.mem.Allocator) void {
    allocator.free(settings.theme);
    defer parsed = null;
    if (parsed) |pr| pr.deinit();
}
