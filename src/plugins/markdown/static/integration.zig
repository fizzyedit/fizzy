//! Markdown plugin — fizzy-internal static-embed + bundled-dylib module graph.
const std = @import("std");
const helpers = @import("../../shared/build/helpers.zig");

pub const id = "markdown";
pub const installDylib = helpers.installDylib;

const module_path = "src/plugins/markdown/markdown.zig";
const dylib_path = "src/plugins/markdown/root.zig";
const zon_path = "src/plugins/markdown/build.zig.zon";

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

pub fn linkCmark(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    module: *std.Build.Module,
) void {
    const cmark_gfm = b.lazyDependency("cmark_gfm", .{
        .target = target,
        .optimize = optimize,
    }) orelse return;

    module.link_libc = true;
    module.linkLibrary(cmark_gfm.artifact("cmark-gfm"));
    module.linkLibrary(cmark_gfm.artifact("cmark-gfm-extensions"));
    module.addIncludePath(cmark_gfm.path("src"));
    module.addIncludePath(cmark_gfm.path("extensions"));
    module.addIncludePath(b.path("src/plugins/markdown/src/md"));
}

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
    linkCmark(b, target, optimize, mod);
    return mod;
}

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
    linkCmark(b, target, optimize, lib.root_module);
    return lib;
}
