//! Fizzy-internal build helpers for the static-embed + bundled-dylib graph of built-in
//! plugins. These always run from the fizzy build root, so every path is a single
//! fizzy-relative `b.path(...)` — there is no plugin-package root to disambiguate.
//! Third-party plugins never touch this; they use `fizzy.plugin.create` / `.install`
//! (`plugin_sdk.zig`), which this file deliberately mirrors in shape (see its doc comments for
//! the "why" behind the generated-root / named-import design — duplicated here rather than
//! imported to avoid pulling fizzy's build-module graph into a place it doesn't belong).
const std = @import("std");

/// C-ABI entry symbols the host looks up. Kept in sync with `plugin_sdk.dylib_exports`
/// (the third-party path); duplicated here to avoid a deep relative import.
pub const dylib_exports = [_][]const u8{
    "fizzy_plugin_abi_fingerprint",
    "fizzy_plugin_sdk_version",
    "fizzy_plugin_min_sdk_version",
    "fizzy_plugin_version",
    "fizzy_plugin_id",
    "fizzy_plugin_manifest_zon",
    "fizzy_plugin_register",
    "fizzy_plugin_set_dvui_context",
    "fizzy_plugin_set_render_bridge",
    "fizzy_plugin_set_globals",
};

/// Module name of the injected build-options bundle. Kept in sync with
/// `plugin_sdk.plugin_options_import` (the third-party path); duplicated here to avoid a deep
/// relative import, same as `dylib_exports` above.
pub const plugin_options_import = "fizzy_plugin_options";

/// Derived from `src/sdk/sdk_version.zig` (`std`-only, unlike `version.zig` itself — see that
/// file's doc comment for why this can't just `@import` `version.zig` directly) rather than
/// duplicated as a literal: a hand-copied version string here silently drifted out of sync with
/// every `sdk_version` bump for a long stretch before this, since nothing forced anyone to
/// notice. `plugin_sdk.current_sdk_version` (the third-party path) mirrors this the same way.
pub const current_sdk_version: []const u8 = std.fmt.comptimePrint("{d}.{d}.{d}", .{
    version_number.sdk_version.major,
    version_number.sdk_version.minor,
    version_number.sdk_version.patch,
});
const version_number = @import("../../../sdk/sdk_version.zig");

/// Identity read from a built-in's `plugin.zig.zon` at configure time, plus its raw source.
/// Same type as `plugin_sdk.IdentityManifest` (both `@import` `manifest_identity.zig` directly)
/// — only `readManifestAt` below stays duplicated, since sharing *that* would pull one build
/// graph into the other (see this file's top doc comment).
pub const IdentityManifest = @import("../../../sdk/manifest_identity.zig").IdentityManifest;

/// Read and validate a built-in plugin's `plugin.zig.zon`. `zon_rel_path` is fizzy-build-root
/// relative (e.g. `"src/plugins/image/plugin.zig.zon"`). Read (not comptime `@import`) on
/// purpose: `@import`ing the manifest here would attach it to fizzy's build-module graph and
/// collide with the same file when the plugin is built standalone (its own `build.zig` already
/// `@import`s it via `plugin_sdk.readManifest`). Panics clearly on a missing/invalid manifest.
pub fn readManifestAt(b: *std.Build, zon_rel_path: []const u8) IdentityManifest {
    const raw = b.build_root.handle.readFileAlloc(b.graph.io, zon_rel_path, b.allocator, std.Io.Limit.limited(256 * 1024)) catch |e|
        std.debug.panic("fizzy: could not read {s}: {}", .{ zon_rel_path, e });
    const src = b.allocator.dupeZ(u8, raw) catch @panic("OOM");
    const Target = struct {
        id: []const u8,
        name: []const u8,
        version: []const u8,
        min_sdk_version: []const u8 = "",
    };
    const parsed = std.zon.parse.fromSliceAlloc(Target, b.allocator, src, null, .{ .ignore_unknown_fields = true }) catch |e|
        std.debug.panic("fizzy: failed to parse {s}: {}", .{ zon_rel_path, e });
    _ = std.SemanticVersion.parse(parsed.version) catch
        std.debug.panic("fizzy: {s} .version \"{s}\" is not valid semver", .{ zon_rel_path, parsed.version });
    if (parsed.min_sdk_version.len > 0) {
        _ = std.SemanticVersion.parse(parsed.min_sdk_version) catch
            std.debug.panic("fizzy: {s} .min_sdk_version \"{s}\" is not valid semver", .{ zon_rel_path, parsed.min_sdk_version });
    }
    return .{
        .id = parsed.id,
        .name = parsed.name,
        .version = parsed.version,
        .min_sdk_version = parsed.min_sdk_version,
        .raw = raw,
    };
}

/// Build the `fizzy_plugin_options` step carrying full plugin identity + raw manifest text —
/// mirrors `plugin_sdk.pluginOptions`, one source of truth per built-in: its own
/// `plugin.zig.zon`.
pub fn pluginOptions(
    b: *std.Build,
    id: []const u8,
    name: []const u8,
    version: []const u8,
    min_sdk_version: []const u8,
    manifest_zon: []const u8,
) *std.Build.Step.Options {
    const sv = std.SemanticVersion.parse(version) catch
        std.debug.panic("fizzy: plugin version \"{s}\" is not valid semver", .{version});
    const min_sdk_str = if (min_sdk_version.len > 0) min_sdk_version else current_sdk_version;
    const min_sv = std.SemanticVersion.parse(min_sdk_str) catch
        std.debug.panic("fizzy: plugin min_sdk_version \"{s}\" is not valid semver", .{min_sdk_str});

    const opts = b.addOptions();
    opts.addOption([]const u8, "id", id);
    opts.addOption([]const u8, "name", name);
    opts.addOption(std.SemanticVersion, "version", sv);
    opts.addOption(std.SemanticVersion, "min_sdk_version", min_sv);
    opts.addOption([]const u8, "manifest_zon", manifest_zon);
    return opts;
}

/// Memoized per `zon_rel_path`. A built-in that compiles both static-embed and bundled-dylib
/// (`addStaticModule` + `addDylib`, each called independently from `build/app.zig`/`exe.zig`/
/// `web.zig`) must attach the *same* `fizzy_plugin_options` step to both — two separate
/// `pluginOptions()` calls for the same manifest produce two distinct `Step.Options` that Zig's
/// build graph refuses to both register under that one import name against `plugin.zig` (root
/// file shared by both link modes): "file exists in modules 'fizzy_plugin_options' and
/// 'fizzy_plugin_options0'".
var options_cache: std.StringHashMapUnmanaged(*std.Build.Step.Options) = .empty;

pub fn pluginOptionsFor(b: *std.Build, zon_rel_path: []const u8) *std.Build.Step.Options {
    if (options_cache.get(zon_rel_path)) |cached| return cached;
    const m = readManifestAt(b, zon_rel_path);
    const opts = pluginOptions(b, m.id, m.name, m.version, m.min_sdk_version, m.raw);
    options_cache.put(b.allocator, zon_rel_path, opts) catch @panic("OOM");
    return opts;
}

pub const StaticModuleOptions = struct {
    import_name: []const u8,
    /// The plugin's root `plugin.zig` (module root — no more `<name>.zig` hub).
    root_source_file: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options_name: ?[]const u8 = null,
    options: ?*std.Build.Step.Options = null,
};

/// Static `@import("<name>")` module for the exe / web / tests build — the author's `plugin.zig`
/// compiled directly into the host binary. No generated root: static embed needs no C-ABI
/// exports (host and plugin share one binary), so `register` is reachable directly as
/// `<name>_mod.register`.
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
    /// The plugin's root `plugin.zig` — becomes `plugin_impl` in the generated dylib root.
    root_source_file: std.Build.LazyPath,
    /// Fizzy-build-root-relative path to the plugin's `plugin.zig.zon` (e.g.
    /// `"src/plugins/image/plugin.zig.zon"`).
    manifest_zon_path: []const u8,
    /// The `sdk` module the generated root's `@import("fizzy_sdk")` resolves to — must be the same
    /// module instance the caller also imports onto `plugin_impl` (see `Created.module`).
    sdk: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options_name: ?[]const u8 = null,
    options: ?*std.Build.Step.Options = null,
};

pub const Created = struct {
    lib: *std.Build.Step.Compile,
    /// The plugin's `plugin.zig` module — attach the rest of its named imports
    /// (`dvui`/`core`/`proxy_bridge`/…) here, not `lib.root_module` (the generated root).
    module: *std.Build.Module,
};

/// Mirrors `plugin_sdk.generatedDylibRoot` — see that function's doc comment for the "why".
///
/// Reaches identity through `plugin.plugin_options` (`plugin_impl`'s own `pub const
/// plugin_options = @import("fizzy_plugin_options")`) rather than importing
/// `fizzy_plugin_options` a second time here: `plugin_impl` is the same `plugin.zig` file a
/// built-in *also* compiles as its static-embed module in this same `zig build` graph (see
/// `addStaticModule` callers). A second attachment of the options step to this generated root, on
/// top of the one already on `plugin_impl`, makes Zig's build graph treat the single generated
/// options file as the root of two modules at once and refuse it — regardless of what name each
/// attachment uses, and regardless of whether the two attachments share one `Step.Options` object
/// or use two separately-created ones with identical content. Reaching through `plugin_impl`
/// avoids a second attachment entirely.
fn generatedDylibRoot(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sdk_mod: *std.Build.Module,
    plugin_impl: *std.Build.Module,
) *std.Build.Module {
    const wf = b.addWriteFiles();
    const root_path = wf.add("plugin_root.zig",
        \\const std = @import("std");
        \\const sdk = @import("fizzy_sdk");
        \\const plugin = @import("plugin_impl");
        \\const opts = plugin.plugin_options;
        \\pub const std_options: std.Options = sdk.dylib.stdOptions(opts.id);
        \\comptime {
        \\    sdk.dylib.exportEntry(plugin, .{
        \\        .id = opts.id,
        \\        .name = opts.name,
        \\        .version = opts.version,
        \\        .min_sdk_version = opts.min_sdk_version,
        \\    }, opts.manifest_zon ++ "\x00");
        \\}
        \\
    );
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = root_path,
        .link_libc = true,
    });
    mod.addImport("fizzy_sdk", sdk_mod);
    mod.addImport("plugin_impl", plugin_impl);
    return mod;
}

/// Native dynamic library bundled beside the app (`{name}.dylib` / `.dll` / `.so`) — a built-in
/// compiled the same way a third-party plugin's dylib would be (`plugin_sdk.create`), just
/// sourced from `src/plugins/<name>/` instead of a separate package. `name`/identity come from
/// `manifest_zon_path`, not a caller-supplied string, so there is one source of truth.
pub fn addDylib(b: *std.Build, opts: DylibOptions) Created {
    const m = readManifestAt(b, opts.manifest_zon_path);

    const plugin_impl = b.createModule(.{
        .target = opts.target,
        .optimize = opts.optimize,
        .root_source_file = opts.root_source_file,
        .link_libc = true,
    });
    if (opts.options_name) |name| {
        if (opts.options) |o| plugin_impl.addOptions(name, o);
    }

    const plugin_options = pluginOptionsFor(b, opts.manifest_zon_path);
    plugin_impl.addOptions(plugin_options_import, plugin_options);

    const root_mod = generatedDylibRoot(b, opts.target, opts.optimize, opts.sdk, plugin_impl);

    const lib = b.addLibrary(.{
        .name = m.id,
        .linkage = .dynamic,
        .root_module = root_mod,
    });
    lib.linker_allow_shlib_undefined = true;
    lib.root_module.export_symbol_names = &dylib_exports;
    return .{ .lib = lib, .module = plugin_impl };
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
