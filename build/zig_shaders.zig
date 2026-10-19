//! `zig build zig-shaders`: the Zig shader spike (`backend/src/shaders/zig/README.md`). Each
//! program written in Zig compiles to SPIR-V with the Zig compiler alone — its self-hosted SPIR-V
//! backend, no LLVM — into `zig-out/shaders/zig/spv/`. `zig build zig-shaders-cross`, with
//! `spirv-cross` on PATH, also translates each to the forms the other backends take, as
//! `scripts/compile-shaders.sh` does for the HLSL: Metal (`msl/`, entry point `main0`) and
//! GLSL ES 3.00 for the web (`glsl/`).
//! Nothing is checked in or drawn from here: the programs fizzy draws are still the HLSL ones.
const std = @import("std");

/// The programs, each `backend/src/shaders/zig/<name>.zig`.
const programs = [_][]const u8{ "program_example", "liquid_glass" };

pub fn addSteps(b: *std.Build) void {
    const step = b.step("zig-shaders", "Compile the Zig shader spike to SPIR-V");
    const cross_step = b.step("zig-shaders-cross", "Compile the Zig shader spike to SPIR-V, then Metal and GLSL ES with spirv-cross (on PATH)");
    cross_step.dependOn(step);
    const target = b.resolveTargetQuery(.{ .cpu_arch = .spirv32, .os_tag = .vulkan });
    // Looked up when the step runs, not here: `findProgram` would poison every build's
    // configuration cache.
    const cross = "spirv-cross";
    for (programs) |name| {
        const obj = b.addObject(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("backend/src/shaders/zig/{s}.zig", .{name})),
                .target = target,
                .optimize = .ReleaseFast,
                // Not stripped: the web binds its uniforms and samplers by name (`uData`,
                // `uSampler`, `uTex1`), and stripped, the GLSL names them by id. The line numbers
                // that come with them double the SPIR-V (`spirv-opt --strip-debug` takes them out).
            }),
            .use_llvm = false,
            .use_lld = false,
        });
        const spv = obj.getEmittedBin();
        step.dependOn(&b.addInstallFile(spv, b.fmt("shaders/zig/spv/{s}.spv", .{name})).step);
        const msl = b.addSystemCommand(&.{ cross, "--msl", "--msl-version", "20100", "--rename-entry-point", "main", "main0", "frag" });
        msl.addFileArg(spv);
        msl.addArg("--output");
        cross_step.dependOn(&b.addInstallFile(msl.addOutputFileArg(b.fmt("{s}.msl", .{name})), b.fmt("shaders/zig/msl/{s}.msl", .{name})).step);
        // As `compile-shaders.sh` makes the web's: its inputs by the names `web/web.js` binds.
        const glsl = b.addSystemCommand(&.{
            cross,                         "--es",          "--version", "300",    "--flatten-ubo",               "--relax-nan-checks",
            "--rename-interface-variable", "in",            "0",         "vColor", "--rename-interface-variable", "in",
            "1",                           "vTextureCoord",
        });
        glsl.addFileArg(spv);
        glsl.addArg("--output");
        cross_step.dependOn(&b.addInstallFile(glsl.addOutputFileArg(b.fmt("{s}.glsl", .{name})), b.fmt("shaders/zig/glsl/{s}.glsl", .{name})).step);
    }
}
