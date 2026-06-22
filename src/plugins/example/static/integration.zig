//! Example plugin — fizzy-internal static-embed + bundled-dylib module graph.
//! Runs only from the fizzy build root, so paths are single fizzy-relative literals.
const std = @import("std");
const helpers = @import("../../shared/build/helpers.zig");

pub const id = "example";
pub const installDylib = helpers.installDylib;

const module_path = "src/plugins/example/example.zig";
const dylib_path = "src/plugins/example/root.zig";

pub const ModuleImports = struct {
    dvui: *std.Build.Module,
    core: *std.Build.Module,
    sdk: *std.Build.Module,
    proxy_bridge: ?*std.Build.Module = null,
};

fn applyImports(module: *std.Build.Module, imports: ModuleImports) void {
    module.addImport("dvui", imports.dvui);
    module.addImport("core", imports.core);
    module.addImport("sdk", imports.sdk);
    if (imports.proxy_bridge) |proxy_bridge| module.addImport("proxy_bridge", proxy_bridge);
}

/// Static `@import("example")` module for exe / web / tests.
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
    applyImports(mod, imports);
    return mod;
}

/// Native dynamic library bundled beside the app (`example.dylib` / `.dll` / `.so`).
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
    applyImports(lib.root_module, imports);
    return lib;
}
