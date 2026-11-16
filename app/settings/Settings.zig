const builtin = @import("builtin");
const core = @import("core");
const sdk = @import("fizzy_sdk");
const std = @import("std");
const dvui = @import("dvui");
const SettingsMigration = @import("SettingsMigration.zig");
const build_opts = @import("build_opts");

const Settings = @This();

pub const Field = std.meta.FieldEnum(Settings);
/// Which fields a stored settings file sets (`load`, `parseOnly`): the rest follow the defaults.
pub const Fields = std.EnumSet(Field);

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

/// Which layout the window is drawn with. `auto` follows the detected device; `mobile` and
/// `desktop` force a shape on any device, so a desktop window can try mobile.
pub const LayoutMode = core.platform.form_factor.LayoutMode;

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

/// The window's glass, per theme (`core.glass_look`): its opacity - above 0 frosted glass at one
/// frost, the window's colour over it from a little to the window's fill, opaque, at 1; 0 a clear
/// window, no glass at all, which the settings pane does not offer. On macOS and Windows the window
/// itself is that glass, and every glass the app draws (dialogs, menus, drops) is too; elsewhere,
/// where the window is opaque, the glass the app draws. (A `window_roughness_*` from before there
/// was one value is read past and dropped.)
window_opacity_dark: f32 = default_glass.opacity_dark,
window_opacity_light: f32 = default_glass.opacity_light,

/// Opacity of the content area (also drives plugin panes that match fizzy chrome).
content_opacity: f32 = 0.7,
/// The most steps a document's undo history keeps, in every editor (`Host.historyLimit`): going
/// back and then editing keeps what was gone back over, so the line grows each time; past this the
/// oldest steps go, as an undo history's limit does. Each plugin that owns a history trims its own.
history_limit: u32 = 10_000,

/// How much a modal dialog or the palette dims everything behind it, 0 (none) to 1.
modal_dim: f32 = 0.0,

/// How round the app's corners are, 0 (square) to 1 (twice as round); 0.5 is as designed.
/// Published each frame through `core.corners`, which every radius scales by, and applied to the
/// theme's own corner. All the way round by default, on every platform.
corner_roundness: f32 = 1.0,

/// How fast the interface moves, 0 (slow) to 1 (fast): half as fast to twice as fast as written,
/// 0.5 as written. Never stops motion - that is `motion` at 0.
motion_speed: f32 = core.motion.default_speed,

/// What the app's windows are made of (`core.material`): opaque (`none`), clear (`transparent`),
/// blurred, frosted, or Liquid Glass. A kind the platform cannot draw is drawn as the richest glass
/// below it that it can, else opaque (`Material.effective`), and stays saved for a machine that
/// can. Opaque until a person turns glass on. Applied at once; `FIZZY_GLASS` overrides it.
window_material: core.material.Kind = .none,

/// What the glass the app draws itself is made of (`core.material.inApp`): dialogs, menus, toasts
/// and floats drawn in the window. Null, the window's (`window_material`), as drawn; a kind, that one wherever the
/// app's renderer can draw it, whatever the windows are made of, else the richest glass below it.
in_app_material: ?core.material.Kind = null,

/// Whether glass is drawn by the glass program (`core.LiquidField`) where the backend has one -
/// shapes that run together, in one pass a pixel - rather than by its meshes. On; a switch to
/// compare the two.
glass_shader: bool = true,

/// Whether a float can leave the main window into an OS window of its own, and a view be carried
/// past the main window to open one there. Taken at launch: a change waits for a restart, which the
/// app says (`Editor.restartPending`). On by default on macOS; `FIZZY_POPOUT` overrides it.
float_windows: bool = builtin.target.os.tag == .macos,

/// Whether a view drag's glass - the carried view and the drop zones - is the OS's own (Liquid Glass,
/// macOS 26) rather than the app's, where floats are windows. Applied at once; `FIZZY_NATIVE_GLASS`
/// overrides it.
native_glass: bool = true,

/// Whether menus open in OS windows of their own - the OS's material, shadow and corners, over every
/// window, past the window's edge - rather than drawn inside the window they open from, where floats
/// are windows. Applied at once; `FIZZY_NATIVE_MENUS` overrides it.
native_menus: bool = true,

/// Whether dialogs open in OS windows of their own - the OS's material, shadow and corners, riding
/// on the main window - rather than drawn inside it, where floats are windows. Applied at once;
/// `FIZZY_NATIVE_DIALOGS` overrides it.
native_dialogs: bool = true,

/// Whether the black box keeps the last minute of input, frame by frame, in memory, for a capture
/// that replays exactly (`fizzy.capture`). Nothing of it is written except a capture someone asks
/// for. A copy of each frame's events: nanoseconds.
black_box: bool = true,

/// Whether each open document's history is recorded as it is made (`app.Tracks`): what lets the
/// transport's strip show it and its export share it as a tape. Kept in memory while the document
/// is open, and in the profile (`<config>/tracks`) once it closes, so it opens again with its
/// history. Off, documents keep only their undo history, and what was recorded is forgotten.
record_history: bool = true,

/// How much of the profile kept history may take, all told, in GB (`Tracks.kept_cap`): past it,
/// the oldest closed documents' history goes first.
kept_history_gb: f32 = 2,

/// Whether a rebuild of the app's own executable restarts the app into it, keeping every open
/// document (`ExecutableWatcher`). On in a source build, which is what rebuilds; off in a release
/// built to update itself (Velopack), whose binary only changes through its own updater.
restart_on_rebuild: bool = !build_opts.velopack_enabled,

/// Whether the app answers HTTP on a Unix socket in its config folder (`control/control.sock`), its
/// commands as the API, so a script or an agent can drive it with `curl` (`app.control`). Only this
/// user can open the socket. Native only.
control_server: bool = true,

/// Canvas zoom/pan control scheme shared by the image viewer, pixi, and any other
/// `CanvasWidget` consumer. `auto` picks mouse vs trackpad from `dvui.mouseType()`.
input_scheme: InputScheme = .auto,

/// Mobile or desktop layout, or whichever fits the device. A web visit's `?form=` still wins for
/// that visit and is never stored here.
layout_mode: LayoutMode = .auto,

/// How updates found by `PluginStore`'s post-launch pass are applied - prompted, or silent.
/// Only covers plugins that haven't individually opted out via `.plugins.<id>.auto_update`.
plugin_update_mode: PluginUpdateMode = .prompt,

/// The window's glass as it comes, per platform. Where the window is the glass (macOS, Windows), as
/// fizzy's windows have been: mostly the window's colour in a dark theme, little in a light one,
/// frosted. Where the window is opaque (the web, Linux), the glass the app draws over it: little
/// colour, well frosted - the dialogs' glass as it was.
pub const GlassDefaults = struct { opacity_dark: f32, opacity_light: f32 };
pub const default_glass: GlassDefaults = if (builtin.target.cpu.arch == .wasm32 or (builtin.target.os.tag != .macos and builtin.target.os.tag != .windows))
    .{ .opacity_dark = 0.2, .opacity_light = 0.2 }
else
    .{ .opacity_dark = 0.7, .opacity_light = 0.3 };

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

/// Loads settings (`theme` is always heap-owned after successful return - see `setThemeName` / `deinit`).
/// `stored` gets which fields the file sets; it runs before any plugin, so the rest are the
/// built-in defaults until `applyDefault` moves them.
/// One-shot migrates any pre-R10 `<plugins_dir>/<id>.settings.zon` files into this file's
/// `.plugins.<id>` field first (see `SettingsMigration.mergeLegacyPerPluginFiles`), then any
/// pre-R12 flat plugin blocks + top-level `disabled_plugins` into nested
/// `.{ .enabled, .settings }` (see `SettingsMigration.migrateToPerPluginEnabled`). Unknown
/// fields (including `.plugins`, which this struct doesn't itself model - see
/// `serialize`'s doc comment) are ignored, both for forward-compat with newer on-disk shapes and
/// because `.plugins` is read separately, per-plugin, via `Host.loadPluginSettings`.
pub fn load(allocator: std.mem.Allocator, path: []const u8, plugins_dir: ?[]const u8, stored: *Fields) !Settings {
    // The web has no per-plugin files to migrate; its settings are `localStorage` behind
    // `core.fs`, the same call as the disk.
    if (comptime builtin.target.cpu.arch != .wasm32) {
        SettingsMigration.mergeLegacyPerPluginFiles(allocator, path, plugins_dir);
        SettingsMigration.migrateToPerPluginEnabled(allocator, path, plugins_dir);
    }

    stored.* = .empty;
    const data = core.fs.readZ(allocator, dvui.io, path) catch return default(allocator);
    defer allocator.free(data);

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const parsed = parseOnly(allocator, arena.allocator(), data, &builtin_defaults, stored) catch |err| {
        dvui.log.warn("Could not parse settings.zon ({s}); using defaults.", .{@errorName(err)});
        return default(allocator);
    };

    var result = parsed;
    // Own `theme` for the process lifetime (freed in `deinit`); every other field is scalar.
    result.theme = try allocator.dupe(u8, parsed.theme);
    return result;
}

/// Parses `data` (already-read `settings.zon` bytes) into a `Settings` value, ignoring unknown
/// fields (forward-compat + `.plugins` is handled separately - see `load`'s doc comment above).
/// Unlike `load`, this returns the raw parse error on failure instead of falling back to
/// defaults - defaulting is only correct when there's no existing live state to fall back *to*
/// (startup); `Editor.reconcileExternalSettingsChange` (external hand-edit reconciliation, R11)
/// has existing state and must not let a transient torn-write read reset every fizzy field and
/// every plugin's settings. The result's strings live in `arena` (`allocator` is the parse's
/// scratch); `load` copies out the one it keeps. A field the file leaves out takes its value from
/// `defaults` (`builtin_defaults`, or the editor's with its plugins' defaults applied); `stored`,
/// when given, gets which fields the file sets.
pub fn parseOnly(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    data: [:0]const u8,
    defaults: *const Settings,
    stored: ?*Fields,
) !Settings {
    @setEvalBranchQuota(10_000);
    var diag: std.zon.parse.Diagnostics = undefined;
    var parsed = try std.zon.parse.fromSlice(Settings, .{
        .gpa = allocator,
        .arena = arena,
        .source = data,
        .diagnostics = &diag,
        .ignore_unknown_fields = true,
    });
    const set = try storedFields(allocator, data);
    inline for (@typeInfo(Settings).@"struct".field_names) |name| {
        if (!set.contains(@field(Field, name))) @field(parsed, name) = @field(defaults, name);
    }
    if (stored) |s| s.* = set;
    SettingsMigration.windowGlass(allocator, data, &parsed);
    return parsed;
}

/// The fields `data`'s top-level struct literal names (already known to parse).
fn storedFields(gpa: std.mem.Allocator, data: [:0]const u8) !Fields {
    var tree = try std.zig.Ast.parse(gpa, data, .{ .mode = .zon });
    defer tree.deinit(gpa);
    const zoir = try std.zig.ZonGen.generate(gpa, tree, .{ .parse_str_lits = false });
    defer zoir.deinit(gpa);
    var set: Fields = .empty;
    switch (std.zig.Zoir.Node.Index.root.get(&zoir)) {
        .struct_literal => |lit| for (lit.names) |n| {
            if (std.meta.stringToEnum(Field, n.get(&zoir))) |f| set.insert(f);
        },
        else => {},
    }
    return set;
}

/// This struct's own declared defaults: what `serialize` diffs against before any plugin gives a
/// setting a default of its own (`applyDefault`).
pub const builtin_defaults: Settings = .{};

/// A default a plugin gave setting `key` (`Host.settings.setDefault`), `zon` its value: `defaults`
/// takes it, and so does `settings` unless the stored file set the field (`stored`) or it has
/// changed since (it no longer equals the default it had). Strings parse into `arena`, which must
/// outlive `defaults`.
pub fn applyDefault(
    settings: *Settings,
    defaults: *Settings,
    stored: Fields,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    key: []const u8,
    zon: [:0]const u8,
) !void {
    @setEvalBranchQuota(10_000);
    const field = std.meta.stringToEnum(Field, key) orelse return error.UnknownSetting;
    switch (field) {
        inline else => |f| {
            const name = @tagName(f);
            const T = @FieldType(Settings, name);
            var diag: std.zon.parse.Diagnostics = undefined;
            const value = try std.zon.parse.fromSlice(T, .{
                .gpa = gpa,
                .arena = arena,
                .source = zon,
                .diagnostics = &diag,
            });
            const untouched = !stored.contains(f) and
                fieldEqual(T, @field(settings, name), @field(defaults, name));
            @field(defaults, name) = value;
            if (!untouched) return;
            if (comptime f == .theme) {
                try settings.setThemeName(gpa, value);
            } else {
                @field(settings, name) = value;
            }
        },
    }
}

fn fieldEqual(comptime FT: type, a: FT, b: FT) bool {
    return switch (@typeInfo(FT)) {
        .bool, .int, .float, .@"enum" => a == b,
        .pointer => |p| if (p.size == .slice and p.child == u8) std.mem.eql(u8, a, b) else false,
        .optional => |o| if (a == null or b == null) a == null and b == null else fieldEqual(o.child, a.?, b.?),
        else => false,
    };
}

/// Serialize fizzy's own fields as `.{ ...fizzy fields... }`, emitting **only the fields that
/// differ from `defaults`** (`builtin_defaults`, or the editor's with its plugins' defaults applied) - the same non-default-only rule plugin settings
/// follow (`sdk.settings.Schema(T).diffSerialize`, R12 in plans/PLUGIN_MANIFEST_PLAN.md), so both
/// halves of `settings.zon` record just what the user actually changed. An untouched fizzy
/// serializes to `.{}`; a field hand-written back at its default drops out on the next write.
/// Reading back is unaffected: `parseOnly` fills every missing field from the same defaults.
///
/// This is *not* the whole `settings.zon` file - plugin settings are a separate
/// `.plugins = .{ .<id> = .{...}, ... }` field spliced on afterward by
/// `Editor.composeSettingsText`/`SettingsPluginsZon.composeMergedText` (R10).
/// `Editor.writeMergedSettings` is the only writer of `settings.zon` - there is no standalone
/// fizzy-only save path anymore, since writing this half alone would silently drop the
/// `.plugins` half.
pub fn serialize(settings: *const Settings, defaults: *const Settings, allocator: std.mem.Allocator) ![]u8 {
    @setEvalBranchQuota(10_000);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    var any = false;
    inline for (@typeInfo(Settings).@"struct".field_names, @typeInfo(Settings).@"struct".field_types, @typeInfo(Settings).@"struct".field_attrs) |f_name, f_type, _| {
        if (!fieldEqual(f_type, @field(settings, f_name), @field(defaults, f_name))) {
            if (!any) try aw.writer.writeAll(".{\n");
            any = true;
            try aw.writer.print("    .{f} = ", .{std.zig.fmtId(f_name)});
            try std.zon.stringify.serialize(@field(settings, f_name), .{}, &aw.writer);
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

test "layout_mode defaults to auto and reads back from settings.zon" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const empty = try parseOnly(std.testing.allocator, arena, ".{}", &builtin_defaults, null);
    try std.testing.expectEqual(LayoutMode.auto, empty.layout_mode);
    const mobile = try parseOnly(std.testing.allocator, arena, ".{ .layout_mode = .mobile }", &builtin_defaults, null);
    try std.testing.expectEqual(LayoutMode.mobile, mobile.layout_mode);
}

test "a plugin's default moves settings the user has not set, and serialize leaves it out" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var stored: Fields = .empty;
    var settings = try parseOnly(gpa, arena, ".{ .history_limit = 10000, .modal_dim = 0.5 }", &builtin_defaults, &stored);
    settings.theme = try gpa.dupe(u8, settings.theme);
    defer settings.deinit(gpa);
    try std.testing.expect(stored.contains(.history_limit));
    try std.testing.expect(!stored.contains(.layout_mode));

    var defaults: Settings = builtin_defaults;
    try applyDefault(&settings, &defaults, stored, gpa, arena, "theme", "\"Graphl Dark\"");
    try applyDefault(&settings, &defaults, stored, gpa, arena, "layout_mode", ".mobile");
    // Stored at the built-in default, so the user's choice: kept.
    try applyDefault(&settings, &defaults, stored, gpa, arena, "history_limit", "50");
    try std.testing.expectError(error.UnknownSetting, applyDefault(&settings, &defaults, stored, gpa, arena, "nope", "1"));
    try std.testing.expectError(error.ParseZon, applyDefault(&settings, &defaults, stored, gpa, arena, "modal_dim", "\"x\""));

    try std.testing.expectEqualStrings("Graphl Dark", settings.theme);
    try std.testing.expectEqual(LayoutMode.mobile, settings.layout_mode);
    try std.testing.expectEqual(@as(u32, 10_000), settings.history_limit);
    try std.testing.expectEqual(@as(f32, 0.5), settings.modal_dim);

    // Changed since: a later default leaves it alone.
    settings.layout_mode = .desktop;
    try applyDefault(&settings, &defaults, stored, gpa, arena, "layout_mode", ".auto");
    try std.testing.expectEqual(LayoutMode.desktop, settings.layout_mode);

    const text = try serialize(&settings, &defaults, gpa);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "theme") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, ".history_limit = 10000") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, ".layout_mode = .desktop") != null);

    // Read back over the same defaults: the plugin's theme, the user's history limit.
    var again_stored: Fields = .empty;
    const again = try parseOnly(gpa, arena, try arena.dupeSentinel(u8, text, 0), &defaults, &again_stored);
    try std.testing.expectEqualStrings("Graphl Dark", again.theme);
    try std.testing.expectEqual(@as(u32, 10_000), again.history_limit);
    try std.testing.expect(!again_stored.contains(.theme));
}
