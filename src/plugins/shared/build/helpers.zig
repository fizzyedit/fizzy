//! Fizzy-internal build helpers for the static-embed + bundled-dylib graph of built-in
//! plugins. These always run from the fizzy build root, so every path is a single
//! fizzy-relative `b.path(...)` — there is no plugin-package root to disambiguate.
//! Third-party plugins never touch this; they use `fizzy.plugin.create` / `.install`.
const std = @import("std");

/// C-ABI entry symbols the host looks up. Kept in sync with `plugin_sdk.dylib_exports`
/// (the third-party path); duplicated here to avoid a deep relative import.
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

pub const StaticModuleOptions = struct {
    import_name: []const u8,
    root_source_file: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options_name: ?[]const u8 = null,
    options: ?*std.Build.Step.Options = null,
};

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
    name: []const u8,
    root_source_file: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options_name: ?[]const u8 = null,
    options: ?*std.Build.Step.Options = null,
};

pub fn addDylib(
    b: *std.Build,
    opts: DylibOptions,
) *std.Build.Step.Compile {
    const dylib_module = b.createModule(.{
        .target = opts.target,
        .optimize = opts.optimize,
        .root_source_file = opts.root_source_file,
        .link_libc = true,
    });
    if (opts.options_name) |name| {
        if (opts.options) |o| dylib_module.addOptions(name, o);
    }
    const lib = b.addLibrary(.{
        .name = opts.name,
        .linkage = .dynamic,
        .root_module = dylib_module,
    });
    lib.linker_allow_shlib_undefined = true;
    lib.root_module.export_symbol_names = &dylib_exports;
    return lib;
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
