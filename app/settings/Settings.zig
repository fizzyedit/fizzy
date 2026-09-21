const builtin = @import("builtin");
const core = @import("core");
const sdk = @import("fizzy_sdk");
const std = @import("std");
const dvui = @import("dvui");
const SettingsMigration = @import("SettingsMigration.zig");

const Settings = @This();

pub const default_theme = "Fizzy Dark";

/// Duration after the last edit before autosave runs (during normal operation).
pub const autosave_timeout_ns: i128 = 500 * 1_000_000;

/// What fizzy does when the plugin store has newer compatible builds of installed plugins.
/// Per-plugin participation is `.plugins.<id>.auto_update` (default true); this is the one
/// app-wide choice of *how* those updates land, so opting a single plugin out stays a rare,
/// deliberate act rather than the only available control.
pub const PluginUpdateMode = enum {
    /// Collect them into the "Plugin updates" window shortly after launch and let the user
    /// apply them (individually, or all at once). The default: an update swaps out code the
    /// user is about to run, so the quiet path is opt-in, not assumed.
    prompt,
    /// Download and apply them with no interaction.
    silent,
};

pub const FlipbookView = enum { sequential, grid };
pub const Compatibility = enum { none, ldtk };

/// Canvas zoom/pan control preference. `auto` follows `dvui.mouseType()` after scroll events
/// (macOS defaults to trackpad when still unknown).
pub const InputScheme = enum { auto, mouse, trackpad };

/// Resolved zoom/pan style after applying `input_scheme`.
pub const ResolvedPanZoomScheme = enum { mouse, trackpad };

/// Touch or long-press duration (ms) before a context menu opens instead of a normal click.
/// A real user (accessibility/touch) preference, unlike the dev-only knobs in `Constants.zig`.
hold_menu_duration_ms: u32 = 500,

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

/// Opacity of the content area (also drives plugin panes that match fizzy chrome).
content_opacity: f32 = 0.7,

/// How much a modal dialog or the palette dims everything behind it, 0 (none) to 1.
modal_dim: f32 = 0.8,

/// How opaque a dialog's or the palette's own fill is over its frosted backdrop, 0 to 1.
dialog_opacity: f32 = 0.3,

/// Blur radius of the frosted backdrop under dialogs and the palette; 0 turns it off.
dialog_blur: f32 = 20,

/// How much lighter a dialog or the palette is than what is behind it, 0 to 1.
dialog_lift: f32 = 0.3,

/// Canvas zoom/pan control scheme shared by the image viewer, pixi, and any other
/// `CanvasWidget` consumer. `auto` picks mouse vs trackpad from `dvui.mouseType()`.
input_scheme: InputScheme = .auto,

/// How updates found by `PluginStore`'s post-launch pass are applied — prompted, or silent.
/// Only covers plugins that haven't individually opted out via `.plugins.<id>.auto_update`.
plugin_update_mode: PluginUpdateMode = .prompt,

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
/// One-shot migrates any pre-R10 `<plugins_dir>/<id>.settings.zon` files into this file's
/// `.plugins.<id>` field first (see `SettingsMigration.mergeLegacyPerPluginFiles`), then any
/// pre-R12 flat plugin blocks + top-level `disabled_plugins` into nested
/// `.{ .enabled, .settings }` (see `SettingsMigration.migrateToPerPluginEnabled`). Unknown
/// fields (including `.plugins`, which this struct doesn't itself model — see
/// `serialize`'s doc comment) are ignored, both for forward-compat with newer on-disk shapes and
/// because `.plugins` is read separately, per-plugin, via `Host.loadPluginSettings`.
pub fn load(allocator: std.mem.Allocator, path: []const u8, plugins_dir: ?[]const u8) !Settings {
    // The web has no per-plugin files to migrate; its settings are `localStorage` behind
    // `core.fs`, the same call as the disk.
    if (comptime builtin.target.cpu.arch != .wasm32) {
        SettingsMigration.mergeLegacyPerPluginFiles(allocator, path, plugins_dir);
        SettingsMigration.migrateToPerPluginEnabled(allocator, path, plugins_dir);
    }

    const data = core.fs.readZ(allocator, dvui.io, path) catch return default(allocator);
    defer allocator.free(data);

    const parsed = parseOnly(allocator, data) catch |err| {
        dvui.log.warn("Could not parse settings.zon ({s}); using defaults.", .{@errorName(err)});
        return default(allocator);
    };

    defer freeParsed(allocator, parsed);

    var result = parsed;
    // Own `theme` for the process lifetime (freed in `deinit`); every other field is scalar.
    result.theme = try allocator.dupe(u8, parsed.theme);
    return result;
}

/// Frees a `parseOnly`/`load` result. Not `std.zon.parse.free` directly: since R12 the file only
/// records non-default fields, so a missing `theme` is filled by `std.zon.parse` with *this
/// struct's declared default* — a comptime string literal, not an allocation — and handing that
/// pointer to the allocator would be an invalid free. Zeroing it first makes the whole-struct
/// free a no-op for that field (`Allocator.free` returns early on an empty slice) while still
/// covering any other allocated field.
pub fn freeParsed(allocator: std.mem.Allocator, parsed: Settings) void {
    var value = parsed;
    if (value.theme.ptr == default_theme.ptr) value.theme = "";
    std.zon.parse.free(allocator, value);
}

/// Parses `data` (already-read `settings.zon` bytes) into a `Settings` value, ignoring unknown
/// fields (forward-compat + `.plugins` is handled separately — see `load`'s doc comment above).
/// Unlike `load`, this returns the raw parse error on failure instead of falling back to
/// defaults — defaulting is only correct when there's no existing live state to fall back *to*
/// (startup); `Editor.reconcileExternalSettingsChange` (external hand-edit reconciliation, R11)
/// has existing state and must not let a transient torn-write read reset every fizzy field and
/// every plugin's settings. Caller frees the result with `freeParsed` (not `Settings.deinit`,
/// which owns the live value's long-lived `theme`).
pub fn parseOnly(allocator: std.mem.Allocator, data: [:0]const u8) !Settings {
    @setEvalBranchQuota(10_000);
    return std.zon.parse.fromSliceAlloc(Settings, allocator, data, null, .{ .ignore_unknown_fields = true });
}

/// The value every field is diffed against by `serialize` — this struct's own declared defaults.
const default_value: Settings = .{};

fn fieldEqual(comptime FT: type, a: FT, b: FT) bool {
    return switch (@typeInfo(FT)) {
        .bool, .int, .float, .@"enum" => a == b,
        .pointer => |p| if (p.size == .slice and p.child == u8) std.mem.eql(u8, a, b) else false,
        else => false,
    };
}

/// Serialize fizzy's own fields as `.{ ...fizzy fields... }`, emitting **only the fields that
/// differ from the declared defaults above** — the same non-default-only rule plugin settings
/// follow (`sdk.settings.Schema(T).diffSerialize`, R12 in docs/PLUGIN_MANIFEST_PLAN.md), so both
/// halves of `settings.zon` record just what the user actually changed. An untouched fizzy
/// serializes to `.{}`; a field hand-written back at its default drops out on the next write.
/// Reading back is unaffected: `load`/`parseOnly` fill every missing field from these same
/// defaults (see `freeParsed` for the one ownership wrinkle that creates).
///
/// This is *not* the whole `settings.zon` file — plugin settings are a separate
/// `.plugins = .{ .<id> = .{...}, ... }` field spliced on afterward by
/// `Editor.composeSettingsText`/`SettingsPluginsZon.composeMergedText` (R10).
/// `Editor.writeMergedSettings` is the only writer of `settings.zon` — there is no standalone
/// fizzy-only save path anymore, since writing this half alone would silently drop the
/// `.plugins` half.
pub fn serialize(settings: *const Settings, allocator: std.mem.Allocator) ![]u8 {
    @setEvalBranchQuota(10_000);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    var any = false;
    inline for (std.meta.fields(Settings)) |f| {
        if (!fieldEqual(f.type, @field(settings, f.name), @field(default_value, f.name))) {
            if (!any) try aw.writer.writeAll(".{\n");
            any = true;
            try aw.writer.print("    .{f} = ", .{std.zig.fmtId(f.name)});
            try std.zon.stringify.serialize(@field(settings, f.name), .{}, &aw.writer);
            try aw.writer.writeAll(",\n");
        }
    }
    if (!any) return allocator.dupe(u8, ".{}");
    try aw.writer.writeAll("}");
    return aw.toOwnedSlice();
}

pub fn deinit(settings: *Settings, allocator: std.mem.Allocator) void {
    allocator.free(settings.theme);
}
