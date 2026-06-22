//! Fizzy-internal build helpers for the static-embed + bundled-dylib graph of built-in
//! plugins. These always run from the fizzy build root, so every path is a single
//! fizzy-relative `b.path(...)` — there is no plugin-package root to disambiguate.
//! Third-party plugins never touch this; they use `fizzy.plugin.create` / `.install`.
const std = @import("std");

/// C-ABI entry symbols the host looks up. Kept in sync with `plugin_sdk.dylib_exports`
/// (the third-party path); duplicated here to avoid a deep relative import.
pub const dylib_exports = [_][]const u8{
    "fizzy_plugin_abi_fingerprint",
    "fizzy_plugin_sdk_version",
    "fizzy_plugin_min_sdk_version",
    "fizzy_plugin_version",
    "fizzy_plugin_id",
    "fizzy_plugin_register",
    "fizzy_plugin_set_dvui_context",
    "fizzy_plugin_set_render_bridge",
    "fizzy_plugin_set_globals",
};

/// Module name of the injected build-options bundle. Kept in sync with
/// `plugin_sdk.plugin_options_import` (the third-party path); duplicated here to avoid a deep
/// relative import, same as `dylib_exports` above.
pub const plugin_options_import = "fizzy_plugin_options";

/// Build the `fizzy_plugin_options` step carrying the plugin's parsed release version and id, so a
/// built-in plugin's `manifest.version` is forwarded from its own `build.zig.zon` — one source of
/// truth, identical to the third-party `plugin_sdk.pluginOptions`. `id` disambiguates the generated
/// options file so several built-ins statically linked into one binary don't collide on an
/// identical content-addressed path.
/// Read a built-in plugin's release version from its own `build.zig.zon` at configure time. Read
/// (not comptime `@import`) on purpose: `@import`ing the manifest here would attach it to fizzy's
/// build-module graph and collide with the same file when the plugin is built standalone (its own
/// `build.zig` already `@import`s it). `zon_rel_path` is fizzy-build-root relative.
pub fn pluginVersionFromZon(b: *std.Build, zon_rel_path: []const u8) []const u8 {
    const raw = b.build_root.handle.readFileAlloc(b.graph.io, zon_rel_path, b.allocator, std.Io.Limit.limited(64 * 1024)) catch |e|
        std.debug.panic("fizzy: read {s}: {}", .{ zon_rel_path, e });
    const src = b.allocator.dupeZ(u8, raw) catch @panic("OOM");
    const Manifest = struct { version: []const u8 = "0.0.0" };
    const parsed = std.zon.parse.fromSliceAlloc(Manifest, b.allocator, src, null, .{ .ignore_unknown_fields = true }) catch |e|
        std.debug.panic("fizzy: parse version from {s}: {}", .{ zon_rel_path, e });
    return parsed.version;
}

pub fn pluginOptions(b: *std.Build, id: []const u8, version: []const u8) *std.Build.Step.Options {
    const sv = std.SemanticVersion.parse(version) catch
        std.debug.panic("fizzy: plugin version \"{s}\" is not valid semver (expected e.g. 1.2.3)", .{version});
    const opts = b.addOptions();
    opts.addOption(std.SemanticVersion, "version", sv);
    opts.addOption([]const u8, "id", id);
    return opts;
}

pub const StaticModuleOptions = struct {
    import_name: []const u8,
    root_source_file: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options_name: ?[]const u8 = null,
    options: ?*std.Build.Step.Options = null,
};

pub fn addStaticModule(
    b: *std.Build,
    opts: StaticModuleOptions,
    consumer: *std.Build.Module,
) *std.Build.Module {
    const mod = b.createModule(.{
        .target = opts.target,
        .optimize = opts.optimize,
        .root_source_file = opts.root_source_file,
        .link_libc = opts.target.result.cpu.arch != .wasm32,
        .single_threaded = opts.target.result.cpu.arch == .wasm32,
    });
    if (opts.options_name) |name| {
        if (opts.options) |o| mod.addOptions(name, o);
    }
    consumer.addImport(opts.import_name, mod);
    return mod;
}

pub const DylibOptions = struct {
    name: []const u8,
    root_source_file: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options_name: ?[]const u8 = null,
    options: ?*std.Build.Step.Options = null,
};

pub fn addDylib(
    b: *std.Build,
    opts: DylibOptions,
) *std.Build.Step.Compile {
    const dylib_module = b.createModule(.{
        .target = opts.target,
        .optimize = opts.optimize,
        .root_source_file = opts.root_source_file,
        .link_libc = true,
    });
    if (opts.options_name) |name| {
        if (opts.options) |o| dylib_module.addOptions(name, o);
    }
    const lib = b.addLibrary(.{
        .name = opts.name,
        .linkage = .dynamic,
        .root_module = dylib_module,
    });
    lib.linker_allow_shlib_undefined = true;
    lib.root_module.export_symbol_names = &dylib_exports;
    return lib;
}

pub fn installDylib(b: *std.Build, lib: *std.Build.Step.Compile, name: []const u8) void {
    const ext: []const u8 = switch (lib.rootModuleTarget().os.tag) {
        .windows => "dll",
        .macos => "dylib",
        else => "so",
    };
    const dest = b.fmt("{s}.{s}", .{ name, ext });
    const install_step = b.addInstallArtifact(lib, .{
        .dest_dir = .{ .override = .prefix },
        .dest_sub_path = dest,
    });
    b.getInstallStep().dependOn(&install_step.step);
}
