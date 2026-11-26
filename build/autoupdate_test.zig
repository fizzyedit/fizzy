//! `zig build test-autoupdate`: the app packaged twice, as an old and a new version, and
//! `tests/autoupdate.zig` run against the two: the new one's feed served over HTTP, the old
//! install updating itself in place. Linux, macOS and Windows, and not part of `zig build test`:
//! the two packages take minutes.
//!
//! For a target of another OS than the host's (`-Dtarget=x86_64-windows-msvc` on Linux, as fizzy's
//! releases build Windows), nothing runs: the test and both packages are installed into
//! `<prefix>/autoupdate/` to be copied to a machine of that OS and run there as
//!
//!     autoupdate/fizzy-autoupdate-test <app-name> <display-name> autoupdate/1.0.0 1.0.0 autoupdate/1.0.1 1.0.1
const std = @import("std");
const package = @import("package.zig");

const versions = [_][]const u8{ "1.0.0", "1.0.1" };

/// Adds `test-autoupdate` to `b`, the root build: fizzy's own, or an app's built on fizzy
/// (`fizzy.addAutoUpdateTestStep`). Each version is `zig build package` of `b`'s build file again,
/// with its command line but the version, for `target` (Windows' MSVC ABI, the one Velopack
/// links), into a prefix of its own. `fizzy_b` is fizzy's builder, where the test's source is.
/// `app_name` is the executable and Velopack's pack id, `display_name` what the startup log line
/// calls the app.
pub fn addStep(
    b: *std.Build,
    fizzy_b: *std.Build,
    target: std.Build.ResolvedTarget,
    app_name: []const u8,
    display_name: []const u8,
) void {
    const step = b.step(
        "test-autoupdate",
        "Package the app as 1.0.0 and 1.0.1 and check that 1.0.0 updates itself to 1.0.1 " ++
            "(minutes; not part of `test`; for another OS, installs the test into autoupdate/)",
    );
    const os = target.result.os.tag;
    const arch = target.result.cpu.arch;
    // The test needs no libc, and no MSVC SDK when cross-compiled.
    var test_query = target.query;
    if (os == .windows) test_query.abi = .gnu;
    const exe = fizzy_b.addExecutable(.{
        .name = "fizzy-autoupdate-test",
        .root_module = fizzy_b.createModule(.{
            .root_source_file = fizzy_b.path("tests/autoupdate.zig"),
            .target = fizzy_b.resolveTargetQuery(test_query),
        }),
    });
    const native = os == b.graph.host.result.os.tag and arch == b.graph.host.result.cpu.arch;
    const run = if (native) fizzy_b.addRunArtifact(exe) else null;
    if (run) |r| {
        r.stdio = .inherit;
        r.has_side_effects = true;
        step.dependOn(&r.step);
        r.addArgs(&.{ app_name, display_name });
    } else {
        step.dependOn(&b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "autoupdate" } } }).step);
    }
    // Elsewhere the test says it skipped, with nothing packaged.
    if (os != .linux and os != .macos and os != .windows) return;

    const skip = [_][]const u8{ "target", "cpu", "ofmt", "dynamic-linker", "app_version" };
    const options = package.commandLineOptions(b, &skip, &.{});
    const target_arg: ?[]const u8 = if (os == .windows)
        b.fmt("-Dtarget={t}-windows-msvc", .{arch})
    else if (target.query.isNative())
        null
    else
        b.fmt("-Dtarget={s}", .{target.query.zigTriple(b.allocator) catch @panic("OOM")});
    var prev: ?*std.Build.Step = null;
    for (versions) |version| {
        const pkg = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "package", b.fmt("-Dapp_version={s}", .{version}) });
        if (target_arg) |arg| pkg.addArg(arg);
        pkg.addArgs(options.common);
        pkg.addArgs(&.{ "--build-file", b.root.joinString(b.allocator, "build.zig") catch @panic("OOM") });
        pkg.addArg("--prefix");
        const prefix = pkg.addOutputDirectoryArg(version);
        // Its inputs are the whole source tree, which this step cannot list: the nested build
        // decides what is stale.
        pkg.has_side_effects = true;
        pkg.stdio = .inherit;
        // One at a time: both build the same executables in the same cache.
        if (prev) |p| pkg.step.dependOn(p);
        prev = &pkg.step;
        if (run) |r| {
            r.addDirectoryArg(prefix);
            r.addArg(version);
        } else {
            // What the test reads: the package, its release list and the full package it lists.
            step.dependOn(&b.addInstallDirectory(.{
                .source_dir = prefix,
                .install_dir = .prefix,
                .install_subdir = b.fmt("autoupdate/{s}", .{version}),
                .include_extensions = &.{ ".AppImage", ".zip", ".nupkg", ".json" },
            }).step);
        }
    }
}
