//! Build helpers for third-party Fizzy plugin dylibs.
//!
//! Required in your project (see `docs/PLUGINS.md` §2):
//! - `plugin.zig` — `register(host)` + `Plugin` vtable; read `sdk.allocator()` / `sdk.host()`.
//!   This is the module root: everything under `src/` imports it via relative paths, and the
//!   shared deps (`fizzy_sdk`/`core`/`dvui`/`proxy_bridge`) are named imports (`@import("fizzy_sdk")`, …).
//! - `plugin.zig.zon` — identity only (`id`/`name`/`version`/`min_sdk_version`). Read
//!   at configure time by `create` below; also embedded verbatim into the dylib (`fizzy_plugin_
//!   manifest_zon`) so a disabled/unloaded plugin's identity can still be probed. There is no
//!   on-disk sidecar — the plugins dir holds only the built dylib.
//! - `build.zig` / `build.zig.zon` — declare `fizzy`, call `fizzy.plugin.create` + `.install`.
//!
//! `root.zig` is **not** part of the author's repo: `create` generates a tiny hidden dylib root
//! (the `std_options` + `exportEntry` comptime block) in the cache, so the author's `plugin.zig`
//! never carries C-ABI export boilerplate — see `docs/PLUGIN_MANIFEST_PLAN.md`'s "Streamlining
//! outcome" for why that generated root can't just be merged into `plugin.zig` itself.
const std = @import("std");

/// Shared with the runtime loader so install + load locations never drift (see its doc comment).
const core_paths = @import("src/core/paths.zig");

/// C-ABI entry symbols every plugin dylib must export.
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

pub const Modules = struct {
    core: *std.Build.Module,
    sdk: *std.Build.Module,
    dvui: *std.Build.Module,
    proxy_bridge: *std.Build.Module,
};

pub const ModulesOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

pub const ModuleOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    root_source_file: std.Build.LazyPath,
    link_libc: bool = true,
};

/// Plugin identity read from `plugin.zig.zon` at configure time — see `readManifest` and
/// `manifest_identity.zig`'s doc comment for why this is a plain relative `@import` (shared
/// with `src/plugins/shared/build/helpers.zig`'s twin `readManifestAt`) rather than a duplicate
/// struct.
pub const IdentityManifest = @import("src/sdk/manifest_identity.zig").IdentityManifest;

/// Derived from `src/sdk/sdk_version.zig` (`std`-only, unlike `src/sdk/version.zig` itself,
/// which transitively reaches "dvui"/"proxy_bridge" — named imports this compilation unit
/// doesn't carry; see `dylib_exports` above for the same "avoid a deep import" reasoning) rather
/// than duplicated as a literal: a hand-copied version string here silently drifted out of sync
/// with every `sdk_version` bump for a long stretch before this, since nothing forced anyone to
/// notice. `src/plugins/shared/build/helpers.zig`'s `current_sdk_version` mirrors this the same way.
pub const current_sdk_version: []const u8 = std.fmt.comptimePrint("{d}.{d}.{d}", .{
    version_number.sdk_version.major,
    version_number.sdk_version.minor,
    version_number.sdk_version.patch,
});
const version_number = @import("src/sdk/sdk_version.zig");

/// Read and validate a plugin's `plugin.zig.zon` (identity only; `ignore_unknown_fields` so a
/// field the build doesn't read doesn't need to be part of `Target` below). Panics clearly on a
/// missing file, a parse error, or non-semver `version`/`min_sdk_version`, since a plugin
/// without a valid manifest cannot build.
pub fn readManifest(b: *std.Build) IdentityManifest {
    return readManifestAt(b, "plugin.zig.zon");
}

fn readManifestAt(b: *std.Build, rel_path: []const u8) IdentityManifest {
    const raw = b.build_root.handle.readFileAlloc(b.graph.io, rel_path, b.allocator, std.Io.Limit.limited(256 * 1024)) catch |e|
        std.debug.panic(
            "fizzy: could not read {s}: {}\nEvery plugin needs a `plugin.zig.zon` manifest at its root (id/name/version) — see docs/PLUGINS.md.",
            .{ rel_path, e },
        );
    const src = b.allocator.dupeZ(u8, raw) catch @panic("OOM");
    const Target = struct {
        id: []const u8,
        name: []const u8,
        version: []const u8,
        min_sdk_version: []const u8 = "",
    };
    const parsed = std.zon.parse.fromSliceAlloc(Target, b.allocator, src, null, .{ .ignore_unknown_fields = true }) catch |e|
        std.debug.panic("fizzy: failed to parse {s}: {}", .{ rel_path, e });
    _ = std.SemanticVersion.parse(parsed.version) catch
        std.debug.panic("fizzy: {s} .version \"{s}\" is not valid semver (expected e.g. 1.2.3)", .{ rel_path, parsed.version });
    if (parsed.min_sdk_version.len > 0) {
        _ = std.SemanticVersion.parse(parsed.min_sdk_version) catch
            std.debug.panic("fizzy: {s} .min_sdk_version \"{s}\" is not valid semver", .{ rel_path, parsed.min_sdk_version });
    }
    return .{
        .id = parsed.id,
        .name = parsed.name,
        .version = parsed.version,
        .min_sdk_version = parsed.min_sdk_version,
        .raw = raw,
    };
}

/// Module name of the build-options bundle injected into every plugin build. Only the author's
/// `plugin.zig` reads `@import(plugin_options_import)` directly — it must, via `pub const
/// plugin_options = @import("fizzy_plugin_options");` (see `generatedDylibRoot`'s doc comment for
/// why the generated root reaches through that export instead of importing this module itself).
pub const plugin_options_import = "fizzy_plugin_options";

/// Build the `fizzy_plugin_options` module carrying full plugin identity + the raw manifest
/// text, so both have exactly one source of truth: `plugin.zig.zon` (see `readManifest`).
/// `min_sdk_version`, when empty, defaults to `current_sdk_version` (the plugin was built
/// against — and is assumed compatible with — whatever SDK it just compiled against).
pub fn pluginOptions(
    b: *std.Build,
    id: []const u8,
    name: []const u8,
    version: []const u8,
    min_sdk_version: []const u8,
    manifest_zon: []const u8,
) *std.Build.Step.Options {
    const sv = std.SemanticVersion.parse(version) catch
        std.debug.panic("fizzy: plugin version \"{s}\" is not valid semver (expected e.g. 1.2.3)", .{version});
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

fn fizzyDep(b: *std.Build, opts: ModulesOptions) *std.Build.Dependency {
    return b.dependency("fizzy", .{
        .target = opts.target,
        .optimize = opts.optimize,
        .plugin_sdk = true,
    });
}

fn modulesFromDep(fizzy_dep: *std.Build.Dependency) Modules {
    return .{
        .core = fizzy_dep.module("core"),
        .sdk = fizzy_dep.module("fizzy_sdk"),
        .dvui = fizzy_dep.module("dvui"),
        .proxy_bridge = fizzy_dep.module("proxy_bridge"),
    };
}

pub fn modules(b: *std.Build, opts: ModulesOptions) Modules {
    return modulesFromDep(fizzyDep(b, opts));
}

pub fn addImports(mod: *std.Build.Module, plugin_modules: Modules) void {
    mod.addImport("core", plugin_modules.core);
    mod.addImport("fizzy_sdk", plugin_modules.sdk);
    mod.addImport("dvui", plugin_modules.dvui);
    mod.addImport("proxy_bridge", plugin_modules.proxy_bridge);
}

fn module(
    b: *std.Build,
    plugin_modules: Modules,
    opts: ModuleOptions,
) *std.Build.Module {
    const mod = b.createModule(.{
        .target = opts.target,
        .optimize = opts.optimize,
        .root_source_file = opts.root_source_file,
        .link_libc = opts.link_libc,
    });
    addImports(mod, plugin_modules);
    return mod;
}

pub fn createModule(b: *std.Build, opts: ModuleOptions) *std.Build.Module {
    return module(b, modules(b, .{
        .target = opts.target,
        .optimize = opts.optimize,
    }), opts);
}

pub const InstallOptions = struct {
    /// Install under `<prefix>/{name}.{ext}`. Defaults to `lib` compile artifact name.
    name: ?[]const u8 = null,
};

/// Wire `zig build install` for a plugin: emit `zig-out/{name}.{ext}` (for packaging / store CI)
/// **and** drop it into this OS's fizzy plugins dir, so the editor loads it on next launch.
/// `{name}` must equal the plugin's manifest `id`. This is the canonical plugin-dev command —
/// `zig build install` is all an author needs. There is no on-disk `.zon` sidecar — the plugins
/// dir holds only the built dylib; the loader reads identity from the dylib's own exports.
///
/// Also wires a `check` step (see `addSdkCheck`) and emits `zig-out/sdk-meta.json` (see
/// `addSdkMeta`) so store CI can read `fizzy_sdk_version` / `abi_fingerprint` on every target —
/// including Windows and cross-compiles — without dlopen.
///
///     const created = fizzy.plugin.create(b, .{ .target = target, .optimize = optimize });
///     fizzy.plugin.install(b, created.lib, .{});
pub fn install(b: *std.Build, lib: *std.Build.Step.Compile, opts: InstallOptions) void {
    const name = opts.name orelse lib.name;
    const dest = b.fmt("{s}.{s}", .{ name, pluginExt(lib.rootModuleTarget().os.tag) });

    lib.step.dependOn(addSdkCheck(b));

    // zig-out/{name}.{ext} — packaging / store CI grabs this.
    const install_step = b.addInstallArtifact(lib, .{
        .dest_dir = .{ .override = .prefix },
        .dest_sub_path = dest,
    });
    b.getInstallStep().dependOn(&install_step.step);

    // zig-out/sdk-meta.json — same pin/optimize-class as the dylib; CI reads this on all targets.
    b.getInstallStep().dependOn(addSdkMeta(b, lib));

    // {config}/fizzy/plugins/{name}.{ext} — so the running editor picks it up (dev convenience).
    const dev = b.allocator.create(DevInstall) catch @panic("OOM");
    dev.* = .{
        .step = std.Build.Step.init(.{
            .id = .custom,
            .name = b.fmt("install plugin '{s}' into the fizzy plugins dir", .{name}),
            .owner = b,
            .makeFn = DevInstall.make,
        }),
        .lib = lib,
        .file_name = dest,
    };
    dev.step.dependOn(&lib.step);
    b.getInstallStep().dependOn(&dev.step);
}

/// Write `zig-out/sdk-meta.json` via a host exe compiled at the plugin's optimize mode (so the
/// abi_fingerprint safety class matches the dylib). Identity comes from `plugin.zig.zon`.
/// No dlopen — works for Windows and cross-compiles.
fn addSdkMeta(b: *std.Build, lib: *std.Build.Step.Compile) *std.Build.Step {
    const optimize = lib.root_module.optimize orelse .Debug;
    // One meta emitter per optimize class — Debug vs ReleaseFast disagree on abi_fingerprint.
    const step_name = b.fmt("sdk-meta-{s}", .{@tagName(optimize)});
    if (b.top_level_steps.get(step_name)) |existing| return &existing.step;

    const step = b.step(step_name, "Write zig-out/sdk-meta.json for store CI");

    const m = readManifest(b);
    const meta_opts = b.addOptions();
    meta_opts.addOption([]const u8, "id", m.id);
    meta_opts.addOption([]const u8, "version", m.version);
    meta_opts.addOption([]const u8, "min_sdk_version", m.min_sdk_version);

    const fizzy_dep = fizzyDep(b, .{ .target = b.graph.host, .optimize = optimize });
    const meta_mod = b.createModule(.{
        .root_source_file = fizzy_dep.path("build/plugin_sdk_meta.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    meta_mod.addImport("fizzy_sdk", fizzy_dep.module("fizzy_sdk"));
    meta_mod.addOptions("plugin_meta", meta_opts);

    const meta_exe = b.addExecutable(.{
        .name = b.fmt("fizzy-plugin-sdk-meta-{s}", .{@tagName(optimize)}),
        .root_module = meta_mod,
    });
    const run = b.addRunArtifact(meta_exe);
    const out_file = run.addOutputFileArg("sdk-meta.json");
    const install_meta = b.addInstallFile(out_file, "sdk-meta.json");
    step.dependOn(&install_meta.step);
    return step;
}

/// Registers (or reuses) the `check` step: prints the pinned fizzy commit's `sdk_version` +
/// ReleaseFast `abi_fingerprint`. If a *legacy* `release.yml` still hand-copies those as
/// workflow inputs, diffs them (plugin-build-action v3+ derives them from the built dylib).
/// A no-op if the plugin has no release.yml yet.
fn addSdkCheck(b: *std.Build) *std.Build.Step {
    if (b.top_level_steps.get("check")) |existing| return &existing.step;

    const step = b.step("check", "Print pinned fizzy SDK version + abi fingerprint (and catch legacy release.yml drift)");

    const release_yml = ".github/workflows/release.yml";
    b.build_root.handle.access(b.graph.io, release_yml, .{}) catch return step;

    const fizzy_dep = fizzyDep(b, .{ .target = b.graph.host, .optimize = .ReleaseFast });
    const check_mod = b.createModule(.{
        .root_source_file = fizzy_dep.path("build/plugin_sdk_check.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    });
    check_mod.addImport("fizzy_sdk", fizzy_dep.module("fizzy_sdk"));
    const check_exe = b.addExecutable(.{ .name = "fizzy-plugin-sdk-check", .root_module = check_mod });
    const run_check = b.addRunArtifact(check_exe);
    run_check.addFileArg(b.path(release_yml));
    step.dependOn(&run_check.step);
    return step;
}

/// Platform extension for a dynamic plugin library, for the given target OS.
fn pluginExt(os_tag: std.Target.Os.Tag) []const u8 {
    return switch (os_tag) {
        .windows => "dll",
        .macos => "dylib",
        else => "so",
    };
}

/// Resolve `{local_config}/fizzy/plugins` on the build host — exactly where the app scans for
/// user plugins. Must mirror `known-folders` `.local_configuration` (what the runtime loader
/// uses, see `src/core/paths.zig`) + `fizzy/plugins`:
///   macOS   `~/Library/Application Support/fizzy/plugins`
///   Linux   `$XDG_CONFIG_HOME/fizzy/plugins` (or `~/.config/fizzy/plugins`)
///   Windows `%LOCALAPPDATA%/fizzy/plugins`   (FOLDERID_LocalAppData — *not* Roaming/`%APPDATA%`)
fn fizzyPluginsDir(b: *std.Build) ![]const u8 {
    const env = &b.graph.environ_map;
    const config_root = (try core_paths.localConfigRoot(
        b.graph.host.result.os.tag,
        b.allocator,
        env.get("HOME"),
        env.get("XDG_CONFIG_HOME"),
        env.get("LOCALAPPDATA"),
    )) orelse return error.NoConfigHome;
    return std.fs.path.join(b.allocator, &.{ config_root, "fizzy", "plugins" });
}

/// Custom step: copy the built dylib into the host's fizzy plugins dir as `{id}.{ext}`. No
/// `.zon` sidecar — the dylib's own exports (`fizzy_plugin_id`/`fizzy_plugin_manifest_zon`/…)
/// are identity's only on-disk-adjacent copy.
const DevInstall = struct {
    step: std.Build.Step,
    lib: *std.Build.Step.Compile,
    file_name: []const u8,

    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
        const self: *DevInstall = @fieldParentPtr("step", step);
        const b = step.owner;
        const io = b.graph.io;

        // Skip gracefully if the host has no resolvable config home (e.g. a bare CI runner) so a
        // plain `zig build` for packaging never fails on the dev convenience.
        const dir = fizzyPluginsDir(b) catch |err| {
            std.log.warn("fizzy: skipping plugin dev install (no config home: {s})", .{@errorName(err)});
            return;
        };
        // Create `{config}/fizzy` then `{config}/fizzy/plugins` (the config root already exists);
        // "already exists" is fine.
        const fizzy_dir = std.fs.path.dirname(dir).?;
        std.Io.Dir.createDirAbsolute(io, fizzy_dir, .default_dir) catch {};
        std.Io.Dir.createDirAbsolute(io, dir, .default_dir) catch {};

        // `getPath2` is relative to the build root (the runner's cwd); the dest is absolute.
        const src = self.lib.getEmittedBin().getPath2(b, step);
        const dest = try std.fs.path.join(b.allocator, &.{ dir, self.file_name });
        const data = try std.Io.Dir.cwd().readFileAlloc(io, src, b.allocator, .limited(512 * 1024 * 1024));
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dest, .data = data });
        std.log.info("fizzy: installed plugin → {s}", .{dest});
    }
};

/// A C source file + its compile flags, for `addCModule`.
pub const CSourceFile = struct {
    file: std.Build.LazyPath,
    flags: []const []const u8 = &.{},
};

pub const CModuleOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// Zig bindings root (e.g. `zstbi.zig`).
    root_source_file: std.Build.LazyPath,
    /// C translation units compiled into the module.
    c_sources: []const CSourceFile = &.{},
    /// `-I` include dirs for the C sources.
    include_paths: []const std.Build.LazyPath = &.{},
    link_libc: bool = true,
    single_threaded: bool = false,
};

/// Build a Zig module backed by vendored C sources (an image/codec/archive lib, etc.) and
/// return it for `mod.addImport(...)`. The C compiles into whatever artifact imports the
/// returned module. All inputs are caller-supplied `LazyPath`s, so this works unchanged whether
/// invoked from the fizzy build root (static embed / bundled dylib) or a standalone plugin
/// build — there is no shared, location-bound build file to collide between the two graphs.
pub fn addCModule(b: *std.Build, opts: CModuleOptions) *std.Build.Module {
    const mod = b.createModule(.{
        .target = opts.target,
        .optimize = opts.optimize,
        .root_source_file = opts.root_source_file,
        .link_libc = opts.link_libc,
        .single_threaded = opts.single_threaded,
    });
    for (opts.include_paths) |path| mod.addIncludePath(path);
    for (opts.c_sources) |c| mod.addCSourceFile(.{ .file = c.file, .flags = c.flags });
    return mod;
}

pub const CreateOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    link_libc: bool = true,
    /// Override the author's module root — defaults to `b.path("plugin.zig")`. Only for edge
    /// cases (e.g. a built-in whose author-facing file doesn't sit at the plugin's repo root).
    root_source_file: ?std.Build.LazyPath = null,
};

pub const PluginArtifact = struct {
    /// The dylib artifact. Its `.root_module` is the *generated* dylib root (`std_options` +
    /// `exportEntry`), not `module` below — a `build.zig` that needs to attach extra
    /// imports/options to the author's own code (e.g. a compile-time flag module) must add them
    /// to `module`, not `lib.root_module`.
    lib: *std.Build.Step.Compile,
    /// The author's `plugin.zig` module — importable from the generated root as `"plugin_impl"`
    /// (an internal wiring detail; the field here is named for what it actually is).
    module: *std.Build.Module,
};

/// Generate the hidden dylib root module: `std_options` (routes this dylib's `std.log`/`dvui.log`
/// into the shell's Output panel) + the `exportEntry` comptime block (C-ABI entry symbols
/// wired to `plugin_impl.register` + the identity/manifest carried by `plugin_options`). This
/// exists so the author's `plugin.zig` never carries C-ABI export boilerplate, and so every
/// built-in can compile into one static binary without colliding on duplicate `fizzy_plugin_*`
/// symbols (only a real dylib artifact gets one of these generated roots).
///
/// **Every author's `plugin.zig` must declare `pub const plugin_options =
/// @import("fizzy_plugin_options");`** — this root reaches identity through `plugin_impl`'s own
/// export rather than importing `fizzy_plugin_options` a second time itself. That's not
/// stylistic: a *second* attachment of the same generated options step to a second module here,
/// alongside the one already on `plugin_impl`, makes Zig's build graph treat the file as the root
/// of two modules at once and refuse it ("file exists in modules 'fizzy_plugin_options' and
/// 'fizzy_plugin_options0'") the moment `plugin.zig` itself references the import — which fizzy's
/// own built-ins now do (see `src/plugins/shared/build/helpers.zig`'s twin `generatedDylibRoot`).
fn generatedDylibRoot(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sdk_mod: *std.Build.Module,
    plugin_mod: *std.Build.Module,
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
    mod.addImport("plugin_impl", plugin_mod);
    return mod;
}

/// Build a plugin dylib: `plugin.zig` (the author's `module`, named imports for
/// `sdk`/`core`/`dvui`/`proxy_bridge`) + a generated dylib root carrying the C-ABI exports —
/// identity and the raw manifest text come from `plugin.zig.zon` (`readManifest`), not
/// caller-supplied options, so there is exactly one source of truth for both.
pub fn create(b: *std.Build, opts: CreateOptions) PluginArtifact {
    const m = readManifest(b);
    const plugin_modules = modules(b, .{ .target = opts.target, .optimize = opts.optimize });

    const plugin_module = b.createModule(.{
        .target = opts.target,
        .optimize = opts.optimize,
        .root_source_file = opts.root_source_file orelse b.path("plugin.zig"),
        .link_libc = opts.link_libc,
    });
    addImports(plugin_module, plugin_modules);
    plugin_module.addAnonymousImport("plugin_zon", .{ .root_source_file = b.path("plugin.zig.zon") });

    const plugin_options = pluginOptions(b, m.id, m.name, m.version, m.min_sdk_version, m.raw);
    plugin_module.addOptions(plugin_options_import, plugin_options);

    const root_mod = generatedDylibRoot(b, opts.target, opts.optimize, plugin_modules.sdk, plugin_module);

    const lib = b.addLibrary(.{
        .name = m.id,
        .linkage = .dynamic,
        .root_module = root_mod,
    });
    lib.linker_allow_shlib_undefined = true;
    lib.root_module.export_symbol_names = &dylib_exports;
    return .{ .lib = lib, .module = plugin_module };
}

pub fn exportModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !void {
    const dvui_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .proxy,
        .accesskit = .off,
    });
    const dvui_proxy_mod = dvui_dep.module("dvui_proxy");
    const proxy_bridge_mod = dvui_dep.module("proxy_bridge");

    const core_mod = b.addModule("core", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/core/core.zig"),
        .link_libc = true,
    });
    core_mod.addImport("dvui", dvui_proxy_mod);
    if (b.lazyDependency("icons", .{ .target = target, .optimize = optimize })) |dep| {
        core_mod.addImport("icons", dep.module("icons"));
    }

    const sdk_mod = b.addModule("fizzy_sdk", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/sdk/sdk.zig"),
    });
    sdk_mod.addImport("dvui", dvui_proxy_mod);
    sdk_mod.addImport("proxy_bridge", proxy_bridge_mod);
    sdk_mod.addImport("core", core_mod);

    b.modules.put(b.graph.arena, b.dupe("dvui"), dvui_proxy_mod) catch @panic("OOM");
    b.modules.put(b.graph.arena, b.dupe("proxy_bridge"), proxy_bridge_mod) catch @panic("OOM");
}

/// Install a built-in plugin dylib as `{name}.{ext}` under `plugins/`. No `.zon` sidecar — the
/// dylib's own exports carry identity (see `helpers.zig`'s `addDylib`/`generatedDylibRoot`).
pub fn installBuiltinPlugin(
    b: *std.Build,
    lib: *std.Build.Step.Compile,
    name: []const u8,
    plugins_install_dir: std.Build.InstallDir,
) *std.Build.Step.InstallArtifact {
    const ext: []const u8 = switch (lib.rootModuleTarget().os.tag) {
        .windows => "dll",
        .macos => "dylib",
        else => "so",
    };
    return b.addInstallArtifact(lib, .{
        .dest_dir = .{ .override = plugins_install_dir },
        .dest_sub_path = b.fmt("{s}.{s}", .{ name, ext }),
    });
}
