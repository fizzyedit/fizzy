//! Pixi plugin — fizzy-internal static-embed + bundled-dylib module graph.
//! Runs only from the fizzy build root, so paths are single fizzy-relative literals.
//!
//! The vendored `zstbi`/`msf_gif` modules are built via the reusable `fizzy.plugin.addCModule`
//! helper (same one a third-party C plugin uses, and the one pixi's own standalone `build.zig`
//! calls) — so the build *logic* lives in one place. `zip` keeps its purpose-built
//! `src/deps/zip/build.zig` (a distinct "C into the consumer + wasm libc shim" pattern).
const std = @import("std");
const helpers = @import("../../shared/build/helpers.zig");
const fizzy_plugin = @import("../../../../plugin_sdk.zig");
const zip_mod = @import("../src/deps/zip/build.zig");

pub const id = "pixi";
pub const installDylib = helpers.installDylib;

const deps_root = "src/plugins/pixi/src/deps";

pub const ZipPackage = zip_mod.Package;
pub fn zipPackage(b: *std.Build) ZipPackage {
    return zip_mod.package(b, .{});
}
pub fn linkZipNative(exe: *std.Build.Step.Compile) void {
    zip_mod.link(exe);
}
pub fn linkZipWasm(exe: *std.Build.Step.Compile) void {
    zip_mod.linkWasm(exe);
}

pub fn addZstbiModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    web: bool,
) *std.Build.Module {
    const web_cflags = [_][]const u8{ "-DSTBI_NO_STDLIB=1", "-DSTBI_NO_SIMD=1" };
    const c_sources = if (web) &[_]fizzy_plugin.CSourceFile{
        .{ .file = b.path(deps_root ++ "/stbi/zstbi.c"), .flags = &web_cflags },
        .{ .file = b.path(deps_root ++ "/stbi/fizzy_stbi_libc.c"), .flags = &web_cflags },
    } else &[_]fizzy_plugin.CSourceFile{
        .{ .file = b.path(deps_root ++ "/stbi/zstbi.c") },
    };
    return fizzy_plugin.addCModule(b, .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path(deps_root ++ "/stbi/zstbi.zig"),
        .c_sources = c_sources,
        .link_libc = !web,
        .single_threaded = web,
    });
}

pub fn addMsfGifModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    web: bool,
) *std.Build.Module {
    const web_cflags = [_][]const u8{"-I" ++ deps_root ++ "/msf_gif/wasm_shim"};
    const c_sources = if (web) &[_]fizzy_plugin.CSourceFile{
        .{ .file = b.path(deps_root ++ "/msf_gif/fizzy_msf_gif_wasm.c"), .flags = &web_cflags },
    } else &[_]fizzy_plugin.CSourceFile{
        .{ .file = b.path(deps_root ++ "/msf_gif/msf_gif.c") },
    };
    return fizzy_plugin.addCModule(b, .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path(deps_root ++ "/msf_gif/msf_gif.zig"),
        .c_sources = c_sources,
        .link_libc = !web,
        .single_threaded = web,
    });
}

const module_path = "src/plugins/pixi/pixi.zig";
const dylib_path = "src/plugins/pixi/root.zig";

pub const ModuleImports = struct {
    dvui: *std.Build.Module,
    core: *std.Build.Module,
    sdk: *std.Build.Module,
    proxy_bridge: ?*std.Build.Module = null,
    assets: *std.Build.Module,
    zip: *std.Build.Module,
    zstbi: *std.Build.Module,
    msf_gif: *std.Build.Module,
    icons: ?*std.Build.Module = null,
    backend: ?*std.Build.Module = null,
};

fn applyImports(module: *std.Build.Module, imports: ModuleImports) void {
    module.addImport("dvui", imports.dvui);
    module.addImport("core", imports.core);
    module.addImport("sdk", imports.sdk);
    if (imports.proxy_bridge) |proxy_bridge| module.addImport("proxy_bridge", proxy_bridge);
    module.addImport("assets", imports.assets);
    module.addImport("zip", imports.zip);
    module.addImport("zstbi", imports.zstbi);
    module.addImport("msf_gif", imports.msf_gif);
    if (imports.icons) |icons| module.addImport("icons", icons);
    if (imports.backend) |backend| module.addImport("backend", backend);
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
    applyImports(mod, imports);
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
    applyImports(lib.root_module, imports);
    return lib;
}
