const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The shared "dvui-like" source. Imported by both artifacts; each compiles
    // its own copy (as dvui would be compiled into host and plugin alike).
    const core_mod = b.createModule(.{
        .root_source_file = b.path("core.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Plugin: a dynamic library, prebuilt and dlopen'd at runtime.
    const plugin = b.addLibrary(.{
        .name = "plugin",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("plugin.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    plugin.root_module.addImport("core", core_mod);
    // Allow symbols to be resolved at load time (needed if we test Mechanism A).
    plugin.linker_allow_shlib_undefined = true;
    b.installArtifact(plugin);

    // Host: the near-empty exe that owns the Window and loads the plugin.
    const host = b.addExecutable(.{
        .name = "host",
        .root_module = b.createModule(.{
            .root_source_file = b.path("host.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    host.root_module.addImport("core", core_mod);
    // Export the host's dynamic symbols so a plugin could interpose (Mechanism A).
    host.rdynamic = true;
    b.installArtifact(host);

    const run = b.addRunArtifact(host);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "build everything and run the host").dependOn(&run.step);
}
