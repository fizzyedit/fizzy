//! Image plugin — fizzy-internal static-embed + bundled-dylib module graph.
//! Runs only from the fizzy build root, so paths are single fizzy-relative literals.
const std = @import("std");
const helpers = @import("../../shared/build/helpers.zig");

pub const id = "image";
pub const installDylib = helpers.installDylib;

const module_path = "src/plugins/image/image.zig";
const dylib_path = "src/plugins/image/root.zig";

/// Forward the plugin version from its own `build.zig.zon` (single source of truth) into the
/// built-in build, matching the third-party `fizzy.plugin.create` path. Read at configure time
/// (see `helpers.pluginVersionFromZon`), not comptime-imported.
const zon_path = "src/plugins/image/build.zig.zon";

pub const ModuleImports = struct {
    dvui: *std.Build.Module,
    core: *std.Build.Module,
    sdk: *std.Build.Module,
    proxy_bridge: ?*std.Build.Module = null,
};

fn applyImports(b: *std.Build, module: *std.Build.Module, imports: ModuleImports) void {
    module.addImport("dvui", imports.dvui);
    module.addImport("core", imports.core);
    module.addImport("sdk", imports.sdk);
    if (imports.proxy_bridge) |proxy_bridge| module.addImport("proxy_bridge", proxy_bridge);
    module.addOptions(helpers.plugin_options_import, helpers.pluginOptions(b, id, helpers.pluginVersionFromZon(b, zon_path)));
}

/// Static `@import("image")` module for exe / web / tests.
pub fn addStaticModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    imports: ModuleImports,
    consumer: *std.Build.Module,
) *std.Build.Module {
    const mod = helpers.addStaticModule(b, .{
        .import_name = id,
        .root_source_file = b.path(module_path),
        .target = target,
        .optimize = optimize,
    }, consumer);
    applyImports(b, mod, imports);
    return mod;
}

/// Native dynamic library bundled beside the app (`image.dylib` / `.dll` / `.so`).
pub fn addDylib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    imports: ModuleImports,
) *std.Build.Step.Compile {
    const lib = helpers.addDylib(b, .{
        .name = id,
        .root_source_file = b.path(dylib_path),
        .target = target,
        .optimize = optimize,
    });
    applyImports(b, lib.root_module, imports);
    return lib;
}
