//! A plain dvui app — no fizzy — that plays a tape into its own window (`replay`), draws the
//! tape's pointer, and prints what is on screen as text. The whole of what it takes to give any
//! dvui app tape playback.
const std = @import("std");
const fizzy_sdk = @import("fizzy_sdk");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // dvui as any app has it: the SDK pins it, and this app picks its own backend.
    const sdk = b.dependency("fizzy_sdk", .{ .target = target, .optimize = optimize });
    const dvui_dep = sdk.builder.dependency("dvui", .{ .target = target, .optimize = optimize, .backend = .sdl3 });
    const dvui_mod = dvui_dep.module("dvui_sdl3");

    // `tape` and `replay`, built against that dvui.
    const automation = fizzy_sdk.replay.modules(b, sdk.builder, dvui_mod, target, optimize);

    const exe = b.addExecutable(.{
        .name = "replay-app",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/main.zig"),
        }),
    });
    exe.root_module.addImport("dvui", dvui_mod);
    exe.root_module.addImport("tape", automation.tape);
    exe.root_module.addImport("replay", automation.replay);
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the replay example").dependOn(&run.step);
}
