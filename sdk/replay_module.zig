//! `tape` and `replay` for any dvui app: the build half of "play a tape into a dvui window".
//!
//! `replay` drives a dvui window, so it has to be compiled against the app's own dvui — whatever
//! backend that app chose. This builds both modules for a given dvui module; fizzy's `core` gets
//! its pair from here too (`core_module.addImports`). A non-fizzy app depends on this package
//! (`fizzy-sdk-v*.tar.gz`, or `sdk/` by path) and, in its `build.zig`:
//!
//! ```zig
//! const sdk = b.dependency("fizzy_sdk", .{});
//! const automation = @import("fizzy_sdk").replay.modules(b, sdk.builder, my_dvui_module, target, optimize);
//! exe.root_module.addImport("tape", automation.tape);
//! exe.root_module.addImport("replay", automation.replay);
//! ```
//!
//! fizzyedit/example-app's replay app (`replay/main.zig`) is the whole of it in a plain dvui app.
//!
//! Pure `std.Build` glue — lives in the `sdk/` package so it ships in the tarball.
const std = @import("std");

pub const Modules = struct {
    /// The tape format, its codecs, the sequencer, the script builder, key spelling. std-only.
    tape: *std.Build.Module,
    /// Playing a tape into the window, the snapshot, anchors, the plain overlay. dvui and `tape`.
    replay: *std.Build.Module,
};

/// `tape` and `replay`, built against `dvui_mod`. `sdk_pkg` is this package's builder — the
/// dependency's `.builder`, or `b` inside this package's own build — whose root holds `tape/`
/// and `replay/` in both layouts (in-repo `sdk/`, and the tarball).
pub fn modules(
    b: *std.Build,
    sdk_pkg: *std.Build,
    dvui_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) Modules {
    const tape = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = sdk_pkg.path("tape/root.zig"),
    });
    const replay = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = sdk_pkg.path("replay/root.zig"),
    });
    replay.addImport("dvui", dvui_mod);
    replay.addImport("tape", tape);
    return .{ .tape = tape, .replay = replay };
}
