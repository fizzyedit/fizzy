//! Standalone build for the pixi plugin — the canonical third-party shape.
//! `cd src/plugins/pixi && zig build` produces `pixi.<dylib|dll|so>`. Pixi has vendored C
//! deps (stbi, msf_gif, zip) and a packed `assets` module, so its `build.zig` attaches a few
//! extra modules onto the `fizzy.plugin.create` lib — exactly how any third-party plugin with
//! native deps would.
//!
//! `zstbi`/`msf_gif` are built with the shared `fizzy.plugin.addCModule` helper (the same one a
//! third-party C plugin uses), so the build logic isn't duplicated — only the plugin-relative
//! paths are supplied here. `zip` is wired inline (its `zip.zig` module + C compiled into this
//! dylib); it isn't shared with fizzy's own build graph, so there's no two-modules collision.
const std = @import("std");
const fizzy = @import("fizzy");
const assetpack = @import("assetpack");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = fizzy.plugin.create(b, .{
        .name = "pixi",
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("root.zig"),
    });

    // Packed assets (the repo's assets/ tree, three levels up from this plugin).
    lib.root_module.addImport("assets", assetpack.pack(b, b.path("../../../assets"), .{}));

    // zstbi (image decode/resize + rect pack) + msf_gif (GIF export) via the shared helper.
    lib.root_module.addImport("zstbi", fizzy.plugin.addCModule(b, .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/deps/stbi/zstbi.zig"),
        .c_sources = &.{.{ .file = b.path("src/deps/stbi/zstbi.c") }},
    }));
    lib.root_module.addImport("msf_gif", fizzy.plugin.addCModule(b, .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/deps/msf_gif/msf_gif.zig"),
        .c_sources = &.{.{ .file = b.path("src/deps/msf_gif/msf_gif.c") }},
    }));

    // zip (atlas/project archives).
    lib.root_module.addImport("zip", b.createModule(.{ .root_source_file = b.path("src/deps/zip/zip.zig") }));
    lib.root_module.link_libc = true;
    lib.root_module.addIncludePath(b.path("src/deps/zip/src"));
    lib.root_module.addCSourceFile(.{
        .file = b.path("src/deps/zip/src/zip.c"),
        .flags = &.{"-fno-sanitize=undefined"},
    });

    if (b.lazyDependency("icons", .{ .target = target, .optimize = optimize })) |dep| {
        lib.root_module.addImport("icons", dep.module("icons"));
    }

    fizzy.plugin.install(b, lib, .{});
}
