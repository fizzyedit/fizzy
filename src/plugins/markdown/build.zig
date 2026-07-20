const std = @import("std");
const fizzy = @import("fizzy");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const plugin = fizzy.plugin.create(b, .{ .target = target, .optimize = optimize });
    linkCmark(b, target, optimize, plugin.module);

    fizzy.plugin.install(b, plugin.lib, .{});
}

/// Duplicated from `static/integration.zig`'s `linkCmark` — deliberately, not `@import`ed:
/// `static/integration.zig` is fizzy-internal glue, itself reachable through the `fizzy` package
/// dependency's own build graph (`build/plugins.zig` imports every built-in's, markdown
/// included). Importing it directly from here makes the same physical file reachable through two
/// disjoint module trees within one `zig build` invocation — markdown's own local "root.@build"
/// and the "root.@dependencies" tree pulled in via `fizzy.plugin.create`'s `b.dependency("fizzy",
/// …)` — which Zig's build graph refuses ("file exists in modules 'root.@build' and
/// 'root.@dependencies...'"). Matches text/image/workbench's standalone `build.zig`, none of
/// which ever reach into their own `static/` either — see docs/PLUGINS.md's "canonical
/// third-party shape" note on why `build.zig` mirrors what any real external plugin would write.
fn linkCmark(
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
    module.addIncludePath(b.path("src/md"));
}
