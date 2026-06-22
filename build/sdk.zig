const std = @import("std");

pub fn addProxyBridgeModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dvui_dep: *std.Build.Dependency,
    dvui_module: *std.Build.Module,
) *std.Build.Module {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = dvui_dep.path("src/backends/proxy_bridge.zig"),
    });
    mod.addImport("dvui", dvui_module);
    return mod;
}

pub fn wireSdkModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dvui_module: *std.Build.Module,
    proxy_bridge_module: *std.Build.Module,
    core_module: *std.Build.Module,
    consumer: ?*std.Build.Module,
) *std.Build.Module {
    const sdk_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/sdk/sdk.zig"),
    });
    sdk_module.addImport("dvui", dvui_module);
    sdk_module.addImport("proxy_bridge", proxy_bridge_module);
    sdk_module.addImport("core", core_module);
    if (consumer) |c| c.addImport("sdk", sdk_module);
    return sdk_module;
}
