//! Workbench plugin — fizzy-internal static-embed + bundled-dylib module graph.
//! Runs only from the fizzy build root, so paths are single fizzy-relative literals.
const std = @import("std");
const helpers = @import("../../shared/build/helpers.zig");

pub const id = "workbench";
pub const installDylib = helpers.installDylib;

const module_path = "src/plugins/workbench/plugin.zig";
const zon_path = "src/plugins/workbench/plugin.zig.zon";

pub const ModuleImports = struct {
    dvui: *std.Build.Module,
    core: *std.Build.Module,
    sdk: *std.Build.Module,
    proxy_bridge: ?*std.Build.Module = null,
    icons: ?*std.Build.Module = null,
    backend: ?*std.Build.Module = null,
};

fn applyImports(module: *std.Build.Module, imports: ModuleImports) void {
    module.addImport("dvui", imports.dvui);
    module.addImport("core", imports.core);
    module.addImport("fizzy_sdk", imports.sdk);
    if (imports.proxy_bridge) |proxy_bridge| module.addImport("proxy_bridge", proxy_bridge);
    if (imports.icons) |icons| module.addImport("icons", icons);
    if (imports.backend) |backend| module.addImport("backend", backend);
}

pub fn addStaticModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    imports: ModuleImports,
    workbench_opts: *std.Build.Step.Options,
    consumer: *std.Build.Module,
) *std.Build.Module {
    const mod = helpers.addStaticModule(b, .{
        .import_name = id,
        .root_source_file = b.path(module_path),
        .target = target,
        .optimize = optimize,
        .options_name = "workbench_opts",
        .options = workbench_opts,
    }, consumer);
    // Shared with `addDylib` below via `pluginOptionsFor`'s per-manifest memoization — both
    // link modes must attach the *same* options step (see its doc comment for why).
    mod.addOptions(helpers.plugin_options_import, helpers.pluginOptionsFor(b, zon_path));
    applyImports(mod, imports);
    return mod;
}

pub fn addDylib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    imports: ModuleImports,
    workbench_opts: *std.Build.Step.Options,
) *std.Build.Step.Compile {
    const created = helpers.addDylib(b, .{
        .root_source_file = b.path(module_path),
        .manifest_zon_path = zon_path,
        .sdk = imports.sdk,
        .target = target,
        .optimize = optimize,
        .options_name = "workbench_opts",
        .options = workbench_opts,
    });
    applyImports(created.module, imports);
    return created.lib;
}
