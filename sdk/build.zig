//! Plugin-facing Fizzy package. Plugins depend on this directory (not the repo root) so
//! app-only deps like Velopack never enter their zon graph — see CLAUDE.md.
const std = @import("std");

// Build-time surface of this package, for the app as well as third-party plugins. The app consumes
// `sdk/` as a dependency and reaches these through it (`@import("fizzy_sdk").plugin`) rather than by
// relative path: a file may belong to only one module, and importing these from the root build
// scripts by path would claim them for the root's build module and make this package unusable as a
// dependency of it. Going through the dependency is also what lets the app share this package's
// dvui instead of pinning its own — see `build/sdk.zig`'s `dvuiDependency`.
pub const plugin = @import("plugin_sdk.zig");
pub const core_module = @import("core_module.zig");
/// dvui's *build* API (`AccesskitOptions` and friends), re-exported because this package owns the
/// only dvui pin in the repo, so the app cannot `@import("dvui")` on its own.
pub const dvui = @import("dvui");
/// The SDK version triplet's single edit site. Built-in plugins' build glue reads it from here
/// rather than by relative path for the one-module-per-file reason above.
pub const sdk_version = @import("sdk_version.zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Accepted for compatibility with `b.dependency("fizzy", .{ .plugin_sdk = true })`.
    // This package always exports plugin modules; it never builds the app.
    _ = b.option(
        bool,
        "plugin_sdk",
        "Export core/sdk modules for plugin builds (always on in this package)",
    );

    try plugin.exportModules(b, target, optimize);
}
