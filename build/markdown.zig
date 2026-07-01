//! Build wiring for the in-tree markdown render library (`src/markdown`).
//!
//! Native-only: the engine links the `cmark-gfm` C library, which needs libc and so cannot
//! build for the `wasm32-freestanding` web target. Callers wire this into the native exe and
//! the (native) integration-test module; the web build never imports `markdown`.
const std = @import("std");

/// Create the `markdown` module (rooted at `src/markdown/markdown.zig`), link the cmark-gfm C
/// library + extensions, set include paths, and import it into `consumer` as `"markdown"`.
pub fn addModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dvui_module: *std.Build.Module,
    consumer: *std.Build.Module,
) *std.Build.Module {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/markdown/markdown.zig"),
        .link_libc = true,
    });
    mod.addImport("dvui", dvui_module);

    const cmark_gfm = b.dependency("cmark_gfm", .{ .target = target, .optimize = optimize });
    mod.linkLibrary(cmark_gfm.artifact("cmark-gfm"));
    mod.linkLibrary(cmark_gfm.artifact("cmark-gfm-extensions"));
    mod.addIncludePath(cmark_gfm.path("src"));
    mod.addIncludePath(cmark_gfm.path("extensions"));
    mod.addIncludePath(b.path("src/markdown/md"));

    consumer.addImport("markdown", mod);
    return mod;
}
