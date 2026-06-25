//! Build helpers for third-party Fizzy plugin dylibs.
//!
//! Required in your project (see `docs/PLUGINS.md` §2):
//! - `root.zig` — copy from `fizzy/src/plugins/root.zig` (one `sdk.dylib.exportEntry` call)
//! - `src/plugin.zig` — `register(host)` + `Plugin` vtable + `manifest`; read `sdk.allocator()` / `sdk.host()`
//! - `build.zig` / `build.zig.zon` — declare `fizzy`, call `fizzy.plugin.create` + `.install` below
const std = @import("std");

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
    link_libc: bool = true,
    root_source_file: ?std.Build.LazyPath = null,
};

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

/// Install `lib` as `{name}.{dylib,dll,so}` under the install prefix.
///
///     const lib = fizzy.plugin.create(b, .{ .name = "markdown", .target = target, .optimize = optimize });
///     fizzy.plugin.install(b, lib, .{});
pub fn install(b: *std.Build, lib: *std.Build.Step.Compile, opts: InstallOptions) void {
    const ext: []const u8 = switch (lib.rootModuleTarget().os.tag) {
        .windows => "dll",
        .macos => "dylib",
        else => "so",
    };
    const name = opts.name orelse lib.name;
    const dest = b.fmt("{s}.{s}", .{ name, ext });
    const install_step = b.addInstallArtifact(lib, .{
        .dest_dir = .{ .override = .prefix },
        .dest_sub_path = dest,
    });
    b.getInstallStep().dependOn(&install_step.step);
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

    const known_folders = b.dependency("known_folders", .{
        .target = target,
        .optimize = optimize,
    }).module("known-folders");

    const core_mod = b.addModule("core", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/core/core.zig"),
        .link_libc = true,
    });
    core_mod.addImport("dvui", dvui_proxy_mod);
    core_mod.addImport("known-folders", known_folders);
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
