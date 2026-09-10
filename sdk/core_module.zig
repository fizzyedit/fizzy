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
//! builds never open the repo-root zon (see `CLAUDE.md`).
const std = @import("std");

/// Add every import `core` needs to `mod`, and return the `icons` module when that lazy
/// dependency is available — callers that also wire `icons` into a sibling module (the exe's own
/// root, the proxy `core`) reuse the handle instead of resolving it twice.
pub fn addImports(
    b: *std.Build,
    mod: *std.Build.Module,
    dvui_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) ?*std.Build.Module {
    mod.addImport("dvui", dvui_mod);
    mod.addImport("zf", zfModule(b, target, optimize));

    if (b.lazyDependency("icons", .{ .target = target, .optimize = optimize })) |dep| {
        const icons = dep.module("icons");
        mod.addImport("icons", icons);
        return icons;
    }
    return null;
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
