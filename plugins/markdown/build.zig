const std = @import("std");
const fizzy = @import("fizzy");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const plugin = fizzy.plugin.create(b, .{ .target = target, .optimize = optimize });
    plugin.module.addImport("md4zig", md4zigModule(b, target, optimize));

    fizzy.plugin.install(b, plugin.lib, .{});

    // `zig build test` — the parts of the preview that are claims about what the
    // *parser* does, and so can only be tested with md4c linked: the AST built
    // from md4c's event stream (`src/md/ast.zig`), and the escape handling that
    // tells `[[A]]` from `\[\[A]]` (`src/md/wikilink_scan.zig`). Pure-logic tests
    // live in fizzy's own list in `build/app.zig` instead.
    const test_step = b.step("test", "Run the markdown plugin's unit tests");
    for ([_][]const u8{ "src/md/ast.zig", "src/md/wikilink_scan.zig" }) |path| {
        const tests = b.addTest(.{
            .name = b.fmt("markdown-{s}-tests", .{std.fs.path.stem(path)}),
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .root_source_file = b.path(path),
            }),
        });
        tests.root_module.addImport("fizzy_sdk", plugin.module.import_table.get("fizzy_sdk").?);
        tests.root_module.addImport("md4zig", md4zigModule(b, target, optimize));
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}

/// md4c, via our wrapper. The module carries md4c's C sources and include paths,
/// so importing it is all a consumer has to do — including for wasm, where the
/// wrapper supplies the libc subset md4c needs.
fn md4zigModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.dependency("md4zig", .{
        .target = target,
        .optimize = optimize,
    }).module("md4zig");
}
