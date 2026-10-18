//! Shared wiring for the `core` module's imports.
//!
//! `core/core.zig` is compiled five separate times against five different dvui flavors —
//! native exe (`dvui_sdl3`), the dylib-facing proxy (`dvui_proxy`), web (`dvui_web`), unit tests
//! (`dvui_testing`), and the plugin-SDK export path (`plugin_sdk.zig`'s `exportModules`). The
//! *module options* legitimately differ per site (`link_libc`, `single_threaded`, …), but the
//! *import set* must not: a dependency added to four of the five compiles fine right up until
//! someone builds the fifth. That is exactly how this drifted before — hence one function,
//! called from all five.
//!
//! Pure `std.Build` glue with no app-only dependencies — lives in the `sdk/` package so plugin
//! builds never open the repo-root zon (see `AGENTS.md`).
const std = @import("std");

/// Add every import `core` needs to `mod`, and return the `icons` module when that lazy
/// dependency is available — callers that also wire `icons` into a sibling module (the exe's own
/// root, the proxy `core`) reuse the handle instead of resolving it twice.
///
/// `core` gets `tape` and `replay` here too, built against the same dvui, and anything that uses
/// them beside `core` takes these from `mod.import_table` (the `app` module, the SDK's exports):
/// a second `tape` would be a second `Tape` type, and a `replay` over another dvui flavour would
/// not compile against this `core` at all. `sdk_pkg` is this package's builder, whose root holds
/// `tape/` and `replay/` in both layouts: `b` from the SDK's own build, the `fizzy_sdk`
/// dependency's builder from the repo root.
///
/// `glass_look` and `glass` are the backend's (`backend/build.zig`'s `glassLookModule` and
/// `glassModule`) where the build links `core` beside fizzy's backend, which draws the same glass;
/// null makes them from the files, beside this package in-repo and vendored into it in the release
/// tarball. `glass` is built over `dvui_mod`, as `core` is.
pub fn addImports(
    b: *std.Build,
    mod: *std.Build.Module,
    dvui_mod: *std.Build.Module,
    sdk_pkg: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    glass_look: ?*std.Build.Module,
    glass: ?*std.Build.Module,
) ?*std.Build.Module {
    mod.addImport("dvui", dvui_mod);
    const look = glass_look orelse sdk_pkg.createModule(.{
        .root_source_file = repoPath(sdk_pkg, "backend/src/glass_look.zig"),
    });
    mod.addImport("glass_look", look);
    mod.addImport("glass", glass orelse blk: {
        const g = sdk_pkg.createModule(.{ .root_source_file = repoPath(sdk_pkg, "backend/src/glass/root.zig") });
        g.addImport("dvui", dvui_mod);
        g.addImport("glass_look", look);
        break :blk g;
    });
    mod.addImport("zf", zfModule(b, target, optimize));

    // Demos and recordings: `tape` is the format and its engine (std-only), `replay` drives a
    // dvui window with it (dvui and `tape`, nothing else) — the same pair any dvui app builds.
    const automation = @import("replay_module.zig").modules(b, sdk_pkg, dvui_mod, target, optimize);
    mod.addImport("tape", automation.tape);
    mod.addImport("replay", automation.replay);

    if (b.lazyDependency("icons", .{ .target = target, .optimize = optimize })) |dep| {
        const icons = dep.module("icons");
        mod.addImport("icons", icons);
        return icons;
    }
    return null;
}

/// LazyPath to a source tree this package needs (`src/…` for the SDK itself, `core/…` for the
/// shared floor, `backend/src/glass_look.zig`).
///
/// The SDK's own source lives inside this package (`sdk/src/`) and resolves directly. `core/`
/// and the glass look do not: in-repo they sit beside this package (`../core/…`), and in the
/// release tarball (`fizzy-sdk-v*.tar.gz`) they are vendored at the archive root, which *is* this
/// package — so the access check below picks whichever layout is present.
pub fn repoPath(b: *std.Build, sub_path: []const u8) std.Build.LazyPath {
    b.root.access(b.graph.io, sub_path, .{}) catch {
        return .{ .cwd_relative = b.root.joinString(b.allocator, b.pathJoin(&.{ "..", sub_path })) catch @panic("OOM") };
    };
    return b.path(sub_path);
}

/// The fuzzy matcher behind `core.fuzzy` — shared by fizzy and, through `core`, by every
/// plugin. `with_tui = false` matters: zf's default build wires up its standalone terminal
/// binary, whose `libvaxis` dependency would otherwise be fetched into every plugin build for a
/// binary nobody here builds.
pub fn zfModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.dependency("zf", .{
        .target = target,
        .optimize = optimize,
        .with_tui = false,
    }).module("zf");
}
