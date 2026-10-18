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
//! never carries C-ABI export boilerplate — see `plans/PLUGIN_MANIFEST_PLAN.md`'s "Streamlining
//! outcome" for why that generated root can't just be merged into `plugin.zig` itself.
const std = @import("std");

/// Shared with the runtime loader so install + load locations never drift (see its doc comment).
/// Lives in this package; keep `localConfigRoot` in sync with `core/paths.zig`.
/// The `core` module's import set, shared with the app build so a dependency can't reach four of
/// the five `core` compiles and miss this one (see its doc comment).
const core_module = @import("core_module.zig");

const repoPath = core_module.repoPath;

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
/// with `plugins/shared/build/helpers.zig`'s twin `readManifestAt`) rather than a duplicate
/// struct.
pub const IdentityManifest = @import("manifest_identity.zig").IdentityManifest;

/// Derived from `sdk_version.zig` (`std`-only, unlike `src/version.zig` itself,
/// which transitively reaches "dvui"/"proxy_bridge" — named imports this compilation unit
/// doesn't carry; see `dylib_exports` above for the same "avoid a deep import" reasoning) rather
/// than duplicated as a literal: a hand-copied version string here silently drifted out of sync
/// with every `sdk_version` bump for a long stretch before this, since nothing forced anyone to
/// notice. `plugins/shared/build/helpers.zig`'s `current_sdk_version` mirrors this the same way.
pub const current_sdk_version: []const u8 = std.fmt.comptimePrint("{d}.{d}.{d}", .{
    version_number.sdk_version.major,
    version_number.sdk_version.minor,
    version_number.sdk_version.patch,
});
const version_number = @import("sdk_version.zig");

/// Read and validate a plugin's `plugin.zig.zon` (identity only; `ignore_unknown_fields` so a
/// field the build doesn't read doesn't need to be part of `Target` below). Panics clearly on a
/// missing file, a parse error, or non-semver `version`/`min_sdk_version`, since a plugin
/// without a valid manifest cannot build.
pub fn readManifest(b: *std.Build) IdentityManifest {
    return readManifestAt(b, "plugin.zig.zon");
}

fn readManifestAt(b: *std.Build, rel_path: []const u8) IdentityManifest {
    b.dependOnFileContents(b.path(rel_path));
    const raw = std.Io.Dir.cwd().readFileAlloc(b.graph.io, b.root.joinString(b.allocator, rel_path) catch @panic("OOM"), b.allocator, std.Io.Limit.limited(256 * 1024)) catch |e|
        std.debug.panic(
            "fizzy: could not read {s}: {}\nEvery plugin needs a `plugin.zig.zon` manifest at its root (id/name/version) — see docs/PLUGINS.md.",
            .{ rel_path, e },
        );
    const src = b.allocator.dupeSentinel(u8, raw, 0) catch @panic("OOM");
    const Target = struct {
        id: []const u8,
        name: []const u8,
        version: []const u8,
        min_sdk_version: []const u8 = "",
    };
    // The build's allocator is freed only when the build ends: the manifest is read into it.
    var diag: std.zon.parse.Diagnostics = undefined;
    const parsed = std.zon.parse.fromSlice(Target, .{ .gpa = b.allocator, .arena = b.allocator, .source = src, .diagnostics = &diag, .ignore_unknown_fields = true }) catch |e|
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

/// Wire `zig build install` for a plugin: emit `zig-out/{name}.{ext}` (a flat single-file
/// artifact for packaging / store CI / release uploads) **and** drop a copy into this OS's fizzy
/// plugins dir, under its own `{name}/{name}.{ext}` directory (see
/// plans/PLUGIN_MANIFEST_PLAN.md R10 — every installed plugin gets its own directory; only this
/// dev-convenience copy is nested, not the flat release artifact above), so the editor loads it
/// on next launch. `{name}` must equal the plugin's manifest `id`. This is the canonical
/// plugin-dev command — `zig build install` is all an author needs. There is no on-disk `.zon`
/// sidecar — the plugin's directory holds only the built dylib; the loader reads identity from
/// the dylib's own exports.
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

    // {config}/fizzy/plugins/{name}/{name}.{ext} — so the running editor picks it up (dev
    // convenience). Not for a wasm build: the browser has no plugins directory, and the desktop
    // editor would only find a file it cannot open.
    if (lib.rootModuleTarget().cpu.arch == .wasm32) return;
    addDevInstall(b, lib, name, dest, b.fmt("install plugin '{s}' into fizzy plugins dir", .{name}));
}

pub const InstallBesideOptions = struct {
    /// The plugin's manifest `id`: the directory the artifact joins.
    plugin: []const u8,
};

/// Wire `zig build install` to drop a second artifact (a helper program the plugin starts, say)
/// into the plugin's own `{plugins}/{plugin}/` directory, beside the library `install` puts there,
/// under the artifact's own file name and with its permissions. Like `install`'s copy, a dev
/// convenience: a release ships what the plugin's `release.yml` uploads.
///
///     fizzy.plugin.installBeside(b, helper_exe, .{ .plugin = "agent" });
pub fn installBeside(b: *std.Build, artifact: *std.Build.Step.Compile, opts: InstallBesideOptions) void {
    if (artifact.rootModuleTarget().cpu.arch == .wasm32) return;
    addDevInstall(b, artifact, opts.plugin, artifact.out_filename, b.fmt("install '{s}' beside plugin '{s}'", .{ artifact.out_filename, opts.plugin }));
}

/// The helper `addDevInstall` runs, one per builder however many artifacts it installs. Debug:
/// it only copies a file, and a ReleaseFast compile of it cost a cold plugin build about 4 s.
fn devInstallExe(b: *std.Build) *std.Build.Step.Compile {
    const gop = dev_install_exes.getOrPut(b.allocator, b) catch @panic("OOM");
    if (!gop.found_existing) {
        const fizzy_dep = fizzyDep(b, .{ .target = b.graph.host, .optimize = .fast });
        gop.value_ptr.* = b.addExecutable(.{
            .name = "fizzy-plugin-dev-install",
            .root_module = b.createModule(.{
                .root_source_file = fizzy_dep.path("plugin_sdk_install.zig"),
                .target = b.graph.host,
                .optimize = .debug,
            }),
        });
    }
    return gop.value_ptr.*;
}
var dev_install_exes: std.AutoHashMapUnmanaged(*std.Build, *std.Build.Step.Compile) = .empty;

/// Copy `artifact` to `{plugins}/{dir_name}/{file_name}` on every `zig build install`, through
/// `plugin_sdk_install.zig`: Zig 0.17's build has no custom steps.
fn addDevInstall(b: *std.Build, artifact: *std.Build.Step.Compile, dir_name: []const u8, file_name: []const u8, step_name: []const u8) void {
    const dev = b.addRunArtifact(devInstallExe(b));
    dev.setName(step_name);
    dev.addArtifactArg(artifact);
    dev.addArgs(&.{ dir_name, file_name });
    // A relative `FIZZY_PROFILE` is taken from the plugin's own directory.
    dev.setCwd(b.path("."));
    // Every install, not only when the artifact changed: the copy in the plugins dir may have
    // been replaced or removed since.
    dev.has_side_effects = true;
    b.getInstallStep().dependOn(&dev.step);
}

/// Write `zig-out/sdk-meta.json` via a host exe compiled at the plugin's optimize mode (so the
/// abi_fingerprint safety class matches the dylib). Identity comes from `plugin.zig.zon`.
/// No dlopen — works for Windows and cross-compiles.
fn addSdkMeta(b: *std.Build, lib: *std.Build.Step.Compile) *std.Build.Step {
    const optimize = lib.root_module.optimize orelse .debug;
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
        .root_source_file = fizzy_dep.path("plugin_sdk_meta.zig"),
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
    dependOnPathExistence(b, release_yml);
    b.root.access(b.graph.io, release_yml, .{}) catch return step;

    const fizzy_dep = fizzyDep(b, .{ .target = b.graph.host, .optimize = .fast });
    const check_mod = b.createModule(.{
        .root_source_file = fizzy_dep.path("plugin_sdk_check.zig"),
        .target = b.graph.host,
        .optimize = .fast,
    });
    check_mod.addImport("fizzy_sdk", fizzy_dep.module("fizzy_sdk"));
    const check_exe = b.addExecutable(.{ .name = "fizzy-plugin-sdk-check", .root_module = check_mod });
    const run_check = b.addRunArtifact(check_exe);
    run_check.addFileArg(b.path(release_yml));
    step.dependOn(&run_check.step);
    return step;
}

/// `-Dplugin-use-llvm`, declared on the first plugin a builder makes and remembered for the rest:
/// fizzy's own build makes several plugins on one builder, and an option may be declared only
/// once. An option, not an environment variable: Zig 0.17 caches the build's configuration
/// without regard to the environment, so a variable read here would be seen once and then ignored.
fn pluginUseLlvm(b: *std.Build) ?bool {
    const gop = plugin_use_llvm.getOrPut(b.allocator, b) catch @panic("OOM");
    if (!gop.found_existing) gop.value_ptr.* = b.option(bool, "plugin-use-llvm", "Force (true) or forbid (false) LLVM for plugin builds; unset, Zig chooses");
    return gop.value_ptr.*;
}
var plugin_use_llvm: std.AutoHashMapUnmanaged(*std.Build, ?bool) = .empty;

/// Platform extension for a dynamic plugin library, for the given target OS.
fn pluginExt(os_tag: std.Target.Os.Tag) []const u8 {
    return switch (os_tag) {
        .windows => "dll",
        .macos => "dylib",
        .freestanding => "wasm",
        else => "so",
    };
}

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
/// invoked from fizzy build root (static embed / bundled dylib) or a standalone plugin
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
    /// The same source as a module an application bundles statically, exported from the package
    /// as `"plugin"`. A `build.zig` that adds the plugin's own dependencies to `module` adds
    /// them here too.
    static: *std.Build.Module,
};

/// Generate the hidden dylib root module: `std_options` (routes this dylib's `std.log`/`dvui.log`
/// into fizzy's Output panel) + the `exportEntry` comptime block (C-ABI entry symbols
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
/// own built-ins now do (see `plugins/shared/build/helpers.zig`'s twin `generatedDylibRoot`).
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
        \\pub const panic = sdk.dylib.panic;
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
        .link_libc = target.result.cpu.arch != .wasm32,
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
        .link_libc = opts.link_libc and opts.target.result.cpu.arch != .wasm32,
    });
    addImports(plugin_module, plugin_modules);
    plugin_module.addAnonymousImport("plugin_zon", .{ .root_source_file = b.path("plugin.zig.zon") });

    const plugin_options = pluginOptions(b, m.id, m.name, m.version, m.min_sdk_version, m.raw);
    plugin_module.addOptions(plugin_options_import, plugin_options);

    const root_mod = generatedDylibRoot(b, opts.target, opts.optimize, plugin_modules.sdk, plugin_module);

    const is_wasm = opts.target.result.cpu.arch == .wasm32;
    const lib = b.addLibrary(.{
        .name = m.id,
        .linkage = .dynamic,
        .root_module = root_mod,
    });
    lib.linker_allow_shlib_undefined = true;
    lib.root_module.export_symbol_names = &dylib_exports;
    // The id a crash report names this exact binary by (fizzy's `app/crash/image.zig`). Mach-O
    // always carries one (LC_UUID) and PE one with its PDB; an ELF image only when asked.
    if (opts.target.result.ofmt == .elf) lib.build_id = .fast;
    // `-Dplugin-use-llvm=true|false` forces the code generator for a plugin build; unset, Zig
    // chooses its default for the target. For measuring the rebuild loop per backend
    // (`scripts/plugin-loop/bench.py --backend`, `.github/workflows/plugin-loop.yml`).
    if (pluginUseLlvm(b)) |v| lib.use_llvm = v;
    if (is_wasm) {
        // A wasm *side module* (Emscripten's term): position-independent, no entry, no
        // threads, loaded into the web host's memory and function table at runtime — the
        // dylib model with table indices for function pointers. See `plans/REVIEW_2026-09.md`
        // §2 and `web/index.html`'s loader.
        lib.root_module.pic = true;
        lib.root_module.single_threaded = true;
        lib.entry = .disabled;
        lib.rdynamic = true;
        // Whatever the module does not define is an `env` import the loader resolves from
        // the host: dvui's C shims (`dvui_c_alloc`, …) and the `fizzy_web_*` JS calls.
        lib.import_symbols = true;
    }

    // The same `plugin.zig` as a module an application can link in (`fizzy.buildApp`), exported
    // as `"plugin"`. Its `dvui`/`core`/`fizzy_sdk` imports are the application's, wired by
    // fizzy's build when it bundles the plugin; only the plugin's own dependencies and its
    // manifest are attached here. A separate options step from the dylib's, so the generated
    // file never belongs to two modules of one compilation.
    const static_module = b.addModule("plugin", .{
        .target = opts.target,
        .optimize = opts.optimize,
        .root_source_file = opts.root_source_file orelse b.path("plugin.zig"),
        .link_libc = opts.link_libc and opts.target.result.cpu.arch != .wasm32,
    });
    static_module.addAnonymousImport("plugin_zon", .{ .root_source_file = b.path("plugin.zig.zon") });
    static_module.addOptions(plugin_options_import, pluginOptions(b, m.id, m.name, m.version, m.min_sdk_version, m.raw));

    return .{ .lib = lib, .module = plugin_module, .static = static_module };
}

pub fn exportModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !void {
    // A wasm side module has no libc and no C libraries of its own: fonts and images are the
    // host's (rendered through the bridge), and the web has no tree-sitter to run.
    const is_wasm = target.result.cpu.arch == .wasm32;
    const dvui_dep = if (is_wasm) b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .proxy,
        .accesskit = .off,
        .libc = false,
        .freetype = false,
        .@"stb-image" = false,
        .@"tree-sitter" = false,
    }) else b.dependency("dvui", .{
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
        .root_source_file = repoPath(b, "core/core.zig"),
        .link_libc = !is_wasm,
    });
    _ = core_module.addImports(b, core_mod, dvui_proxy_mod, b, target, optimize, null, null);

    const sdk_mod = b.addModule("fizzy_sdk", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = repoPath(b, "src/sdk.zig"),
    });
    sdk_mod.addImport("dvui", dvui_proxy_mod);
    sdk_mod.addImport("proxy_bridge", proxy_bridge_mod);
    sdk_mod.addImport("core", core_mod);
    // See the matching comment in `build/sdk.zig`. `sdk_version.zig` needs no `repoPath` hop:
    // unlike `src/…`, it lives at this package's root in *both* layouts (in-repo `fizzy/sdk/`
    // and the release tarball, whose root is that same directory).
    sdk_mod.addImport("sdk_version", b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("sdk_version.zig"),
    }));

    // Demos and recordings as data (`tape/`): std-only, so a plugin can write a demo of itself.
    // And `replay/`, which plays one into a dvui window. Both are `core`'s own instances.
    b.modules.put(b.graph.arena, b.dupe("tape"), core_mod.import_table.get("tape").?) catch @panic("OOM");
    b.modules.put(b.graph.arena, b.dupe("replay"), core_mod.import_table.get("replay").?) catch @panic("OOM");

    b.modules.put(b.graph.arena, b.dupe("dvui"), dvui_proxy_mod) catch @panic("OOM");
    b.modules.put(b.graph.arena, b.dupe("proxy_bridge"), proxy_bridge_mod) catch @panic("OOM");
}

/// Install a built-in plugin dylib as `{name}/{name}.{ext}` under `plugins/` — each plugin gets
/// its own directory (see plans/PLUGIN_MANIFEST_PLAN.md R10), which it can also use at runtime for
/// its own assets/data (`Host.pluginInstallDir`). No `.zon` sidecar — the dylib's own exports
/// carry identity (see `helpers.zig`'s `addDylib`/`generatedDylibRoot`).
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
        .dest_sub_path = b.fmt("{s}/{s}.{s}", .{ name, name, ext }),
    });
}

/// Declare to Zig 0.17's configure cache that the build read whether `rel` exists: the file itself
/// when it does, and otherwise the nearest directory that exists, since the maker cannot load a
/// configuration that depends on a path inside a missing directory ("configuration failed:
/// FileSystemFailure"). Making the file changes that directory, so the build still reconfigures.
fn dependOnPathExistence(b: *std.Build, rel: []const u8) void {
    b.root.access(b.graph.io, rel, .{}) catch {
        var dir = std.fs.path.dirname(rel);
        while (dir) |d| : (dir = std.fs.path.dirname(d)) {
            b.root.access(b.graph.io, d, .{}) catch continue;
            return b.dependOnDirectoryMetadata(b.path(d));
        }
        return b.dependOnDirectoryMetadata(b.path("."));
    };
    b.dependOnFileMetadata(b.path(rel));
}
