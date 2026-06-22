//! Build helpers for third-party Fizzy plugin dylibs.
//!
//! Required in your project (see `docs/PLUGINS.md` §2):
//! - `root.zig` — copy from `fizzy/src/plugins/root.zig` (one `sdk.dylib.exportEntry` call)
//! - `src/plugin.zig` — `register(host)` + `Plugin` vtable + `manifest`; read `sdk.allocator()` / `sdk.host()`
//! - `build.zig` / `build.zig.zon` — declare `fizzy`, call `fizzy.plugin.create` + `.install` below
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

pub const CreateOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// Dylib artifact name and installed filename stem (e.g. `"markdown"` → `markdown.dylib`).
    name: []const u8,
    /// Plugin release version. Forwarded into `manifest.version` through the injected
    /// `@import("fizzy_plugin_options")` module so the number lives in exactly one place — pass
    /// `@import("build.zig.zon").version`. Defaults to `0.0.0` when omitted (a plugin whose
    /// `plugin.zig` still hard-codes `manifest.version` simply ignores the injected module).
    version: []const u8 = "0.0.0",
    link_libc: bool = true,
    root_source_file: ?std.Build.LazyPath = null,
};

/// Module name of the build-options bundle injected into every plugin build. The plugin source
/// reads `@import(plugin_options_import).version` to fill `manifest.version` from `build.zig.zon`
/// instead of duplicating the version literal in `plugin.zig`.
pub const plugin_options_import = "fizzy_plugin_options";

/// Build the `fizzy_plugin_options` step carrying the plugin's parsed release version and id.
/// Shared by the third-party (`create`) and built-in (integration.zig) build paths so
/// `manifest.version` has one source of truth: the author's `build.zig.zon`. The `id` is included
/// both as convenient identity and to keep each plugin's generated options file distinct — several
/// built-ins are statically linked into one binary, and two identical option files would otherwise
/// collide on the same content-addressed path.
pub fn pluginOptions(b: *std.Build, id: []const u8, version: []const u8) *std.Build.Step.Options {
    const sv = std.SemanticVersion.parse(version) catch
        std.debug.panic("fizzy: plugin version \"{s}\" is not valid semver (expected e.g. 1.2.3)", .{version});
    const opts = b.addOptions();
    opts.addOption(std.SemanticVersion, "version", sv);
    opts.addOption([]const u8, "id", id);
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
        .sdk = fizzy_dep.module("sdk"),
        .dvui = fizzy_dep.module("dvui"),
        .proxy_bridge = fizzy_dep.module("proxy_bridge"),
    };
}

pub fn modules(b: *std.Build, opts: ModulesOptions) Modules {
    return modulesFromDep(fizzyDep(b, opts));
}

pub fn addImports(mod: *std.Build.Module, plugin_modules: Modules) void {
    mod.addImport("core", plugin_modules.core);
    mod.addImport("sdk", plugin_modules.sdk);
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
/// **and** drop `{name}.{ext}` into this OS's fizzy plugins dir, so the editor loads it on next
/// launch. `{name}` must equal the plugin's `manifest.id`. This is the canonical plugin-dev
/// command — `zig build install` is all an author needs.
///
/// Also wires a `check` step (see `addSdkCheck`) as a dependency of `lib`, so every build —
/// `zig build`, `zig build install`, any `-Dtarget=` CI build — fails fast when the plugin's
/// pinned fizzy commit no longer matches what `.github/workflows/release.yml` declares, instead
/// of only surfacing at CI's dlopen-verify time on the 3 of 6 targets that happen to be a
/// runner's native arch.
///
///     const lib = fizzy.plugin.create(b, .{ .name = "markdown", .target = target, .optimize = optimize });
///     fizzy.plugin.install(b, lib, .{});
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

/// Registers (or reuses) the `check` step: diffs the plugin's `.github/workflows/release.yml`
/// `fizzy-sdk-version`/`abi-fingerprint`/`min-sdk-version` against what the pinned fizzy commit
/// actually computes, natively, forced `ReleaseFast` (the mode fizzy's release CI ships — see
/// `sdk/dylib.zig`'s `optimize_safety_class`). A no-op if the plugin has no release.yml yet, so
/// a brand-new plugin repo without CI set up still builds cleanly.
fn addSdkCheck(b: *std.Build) *std.Build.Step {
    if (b.top_level_steps.get("check")) |existing| return &existing.step;

    const step = b.step("check", "Diff release.yml's fizzy-sdk-version/abi-fingerprint against what the pinned fizzy commit computes");

    const release_yml = ".github/workflows/release.yml";
    b.build_root.handle.access(b.graph.io, release_yml, .{}) catch return step;

    const fizzy_dep = fizzyDep(b, .{ .target = b.graph.host, .optimize = .ReleaseFast });
    const check_mod = b.createModule(.{
        .root_source_file = fizzy_dep.path("build/plugin_sdk_check.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    });
    check_mod.addImport("sdk", fizzy_dep.module("sdk"));
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

/// Custom step: copy the built dylib into the host's fizzy plugins dir as `{id}.{ext}`.
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

pub fn create(b: *std.Build, opts: CreateOptions) *std.Build.Step.Compile {
    const root_source = opts.root_source_file orelse b.path("root.zig");
    const mod = module(b, modules(b, .{
        .target = opts.target,
        .optimize = opts.optimize,
    }), .{
        .target = opts.target,
        .optimize = opts.optimize,
        .root_source_file = root_source,
        .link_libc = opts.link_libc,
    });
    mod.addOptions(plugin_options_import, pluginOptions(b, opts.name, opts.version));

    const lib = b.addLibrary(.{
        .name = opts.name,
        .linkage = .dynamic,
        .root_module = mod,
    });
    lib.linker_allow_shlib_undefined = true;
    lib.root_module.export_symbol_names = &dylib_exports;
    return lib;
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

    const sdk_mod = b.addModule("sdk", .{
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

/// Install a built-in plugin dylib as `{name}.{ext}` under `plugins/`.
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
