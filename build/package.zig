const std = @import("std");
const build_common = @import("common.zig");
// Vendored Velopack glue — see build/velopack.zig header (never `@import("velopack_zig")`).
const velopack = @import("velopack.zig");
const exe = @import("exe.zig");

pub const Options = struct {
    b: *std.Build,
    vz: velopack.Dep,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.OptimizeMode,
    app_version: []const u8,
    /// `--packId`, and the executable's name (`--mainExe`).
    app_name: []const u8,
    /// `--bundleId` on macOS when `branding.plist` is null.
    app_bundle_id: []const u8,
    branding: @import("app.zig").Branding,
    zig_out_subdir: []const u8,
    zig_out_install_dir: std.Build.InstallDir,
    no_emit: bool,
    velopack_required_fail: ?*std.Build.Step,
    exe_for_package: *std.Build.Step.Compile,
    package_fizzy: exe.FizzyExecutable,
    /// Directories whose files go beside the executable, after it and the plugin dylibs.
    package_dirs: []const std.Build.LazyPath,
    /// Passed to `vpk pack` after fizzy's own arguments.
    vpk_args: []const []const u8,
    macos_sign_app_identity: ?[]const u8,
    macos_sign_install_identity: ?[]const u8,
    macos_notary_profile: ?[]const u8,
};

pub fn addSteps(opts: Options) *std.Build.Step {
    const b = opts.b;
    const vz = opts.vz;
    const target = opts.target;
    const optimize = opts.optimize;
    const app_version = opts.app_version;
    const zig_out_subdir = opts.zig_out_subdir;
    const zig_out_install_dir = opts.zig_out_install_dir;
    const no_emit = opts.no_emit;
    const velopack_required_fail = opts.velopack_required_fail;
    const exe_for_package = opts.exe_for_package;
    const package_fizzy = opts.package_fizzy;
    const macos_sign_app_identity = opts.macos_sign_app_identity;
    const macos_sign_install_identity = opts.macos_sign_install_identity;
    const macos_notary_profile = opts.macos_notary_profile;
    const app_name = opts.app_name;
    const branding = opts.branding;

    const package_step = b.step("package", "Velopack release artifacts (strip + vpk); not part of install or run");
    // The default native target on a Windows host resolves to x86_64-windows-gnu,
    // for which `velopack_supported_for_target` is false — exe_for_package falls
    // back to the plain (Velopack-less) exe. vpk would still wrap it as a Velopack
    // installer, but the install hook never runs: Setup.exe hangs with "the
    // application install hook failed". Fail loudly instead of shipping that trap.
    const windows_non_msvc = target.result.os.tag == .windows and target.result.abi != .msvc;
    const failure: ?*std.Build.Step = if (velopack_required_fail) |fail_step|
        fail_step
    else if (windows_non_msvc) &b.addFail(
        \\`zig build package` for Windows requires the MSVC ABI so Velopack is linked.
        \\The default native target resolves to x86_64-windows-gnu, which builds a binary
        \\WITHOUT the Velopack runtime. vpk would still wrap it as a Velopack installer, but
        \\the install hook never runs and Setup.exe hangs ("the application install hook failed").
        \\
        \\Build with the MSVC target instead:
        \\  zig build package -Dtarget=x86_64-windows-msvc -Dfetch-msvc
        \\(needs Windows SDK 10.0.26100+ for SDL's GameInput backend.)
    ).step else if (no_emit) &b.addFail("cannot run `package` with -Dno-emit").step else switch (target.result.os.tag) {
        .linux, .macos, .windows => null,
        else => &b.addFail("Velopack packaging is only supported for Linux, macOS, and Windows targets").step,
    };
    // The installers' directory: vpk's output, or, when this target can't be packaged, one whose
    // step fails saying why. Both `package` and an app's (`fizzy.addPackageSteps`) install it.
    const installers: std.Build.LazyPath = if (failure) |fail_step| failed: {
        const nothing = b.addWriteFiles();
        nothing.step.dependOn(fail_step);
        break :failed nothing.getDirectory();
    } else vpk: {
        // Host strip can't process foreign object files when cross-compiling.
        const cross_os = target.result.os.tag != b.graph.host.result.os.tag;
        // Same-OS / different-arch (e.g. aarch64-linux from x86_64-linux) also
        // breaks host strip — it errors with "Unable to recognise the format".
        const cross_for_strip = cross_os or target.result.cpu.arch != b.graph.host.result.cpu.arch;
        // Windows hosts don't ship `strip` or `touch`. Skip the external strip
        // step entirely there — Zig's linker already drops debug info in
        // release builds. Use `cmd /c exit 0` as the no-op and keep the
        // dependency on exe_for_package via the step graph.
        const host_is_windows = b.graph.host.result.os.tag == .windows;
        const skip_strip = host_is_windows or optimize == .debug or cross_for_strip;
        const strip_release_sh = if (host_is_windows) blk: {
            const sh = b.addSystemCommand(&.{ "cmd", "/c", "exit", "0" });
            sh.step.dependOn(&exe_for_package.step);
            break :blk sh;
        } else blk: {
            const sh = b.addSystemCommand(&.{if (skip_strip) "touch" else "strip"});
            sh.addFileArg(exe_for_package.getEmittedBin());
            break :blk sh;
        };

        const vpk_pkg_sh = try velopack.addVpkRun(b, vz, target);
        // When packaging a foreign-OS bundle, vpk needs an OS directive (e.g. `vpk [win] pack ...`)
        // because by default it auto-detects from the host OS.
        if (cross_os) {
            vpk_pkg_sh.addArg(switch (target.result.os.tag) {
                .windows => "[win]",
                .linux => "[linux]",
                .macos => "[osx]",
                else => unreachable,
            });
        }
        vpk_pkg_sh.addArg("pack");
        vpk_pkg_sh.addArg("--packId");
        vpk_pkg_sh.addArg(app_name);
        vpk_pkg_sh.addArg("--packVersion");
        vpk_pkg_sh.addArg(app_version);
        // Channel = zig-out subdir (`<arch>-<os>`, NuGet-safe — no underscores). Baked into
        // the binary by vpk; the updater matches this to release assets. Distinct per triple
        // so parallel `vpk pack` runs don't collide on RELEASES / nupkg names.
        vpk_pkg_sh.addArg("--channel");
        vpk_pkg_sh.addArg(zig_out_subdir);
        vpk_pkg_sh.addArg("--mainExe");
        vpk_pkg_sh.addArg(exe_for_package.out_filename);
        vpk_pkg_sh.addArg("--packTitle");
        vpk_pkg_sh.addArg(branding.package_title);

        vpk_pkg_sh.addArg("--delta");
        vpk_pkg_sh.addArg("None");
        vpk_pkg_sh.addArg("--yes");

        vpk_pkg_sh.addArg("--outputDir");
        // `addOutputDirectoryArg` takes a basename — Zig manages the actual
        // path under the run step's cache dir. The `addInstallDirectory`
        // below copies that into zig-out/<channel>/. Previously this passed
        // the full install path, which produced `.zig-cache\o\<hash>\C:\...`
        // on Windows (BadPathName).
        const vpk_pkg_out_dir = vpk_pkg_sh.addOutputDirectoryArg("desktop");
        // Stage exe + built-in plugin dylibs under zig-out/<channel>/.pack-input/
        // so vpk ships plugins/ next to the main binary.
        const pack_input_subdir = b.fmt("{s}/.pack-input", .{zig_out_subdir});
        const pack_plugins_subdir = b.fmt("{s}/.pack-input/plugins", .{zig_out_subdir});
        var pack_stage_tail = exe.addVelopackPackDirInstall(
            b,
            exe_for_package,
            package_fizzy,
            pack_input_subdir,
            pack_plugins_subdir,
            &strip_release_sh.step,
        );
        for (opts.package_dirs) |dir| {
            const install_dir = b.addInstallDirectory(.{
                .source_dir = dir,
                .install_dir = .{ .custom = pack_input_subdir },
                .install_subdir = "",
            });
            install_dir.step.dependOn(pack_stage_tail);
            pack_stage_tail = &install_dir.step;
        }
        vpk_pkg_sh.addArg("--packDir");
        vpk_pkg_sh.addDirectoryArg(build_common.installDirPath(.{ .custom = pack_input_subdir }));
        switch (target.result.os.tag) {
            .windows => {
                // Sets the installer's icon and the Start Menu shortcut icon. The
                // exe's own icon is already embedded via `branding.rc`.
                vpk_pkg_sh.addArg("--icon");
                vpk_pkg_sh.addFileArg(branding.ico);
                // Velopack's installer is silent (no shortcut-choice UI). Default is
                // Desktop,StartMenu; restrict to StartMenu so we don't drop an
                // unrequested icon on the user's desktop.
                vpk_pkg_sh.addArg("--shortcuts");
                vpk_pkg_sh.addArg("StartMenu");
            },
            .macos => {
                // Bundle id / document types / versions: fizzy's are in assets/macos/info.plist.
                // vpk rejects --bundleId with --plist, so an app with no plist of its own
                // gets one vpk writes from its bundle id.
                if (branding.plist) |plist| {
                    vpk_pkg_sh.addArg("--plist");
                    vpk_pkg_sh.addFileArg(plist);
                } else {
                    vpk_pkg_sh.addArg("--bundleId");
                    vpk_pkg_sh.addArg(opts.app_bundle_id);
                }
                vpk_pkg_sh.addArg("--icon");
                vpk_pkg_sh.addFileArg(branding.icns);

                if (macos_sign_app_identity) |id| {
                    vpk_pkg_sh.addArg("--signAppIdentity");
                    vpk_pkg_sh.addArg(id);
                    // Required for notarization: enables hardened runtime + secure timestamp on
                    // every nested binary (vpk forwards the file to `codesign --entitlements`).
                    // Without this, Apple's notary service rejects with "signature does not
                    // include a secure timestamp" / "hardened runtime not enabled".
                    vpk_pkg_sh.addArg("--signEntitlements");
                    const entitlements_path =
                        b.root.joinString(b.allocator, "assets/macos/Fizzy.entitlements") catch |e|
                            std.debug.panic("entitlements path: {}", .{e});
                    vpk_pkg_sh.addArg(entitlements_path);
                }
                if (macos_sign_install_identity) |id| {
                    vpk_pkg_sh.addArg("--signInstallIdentity");
                    vpk_pkg_sh.addArg(id);
                }
                if (macos_notary_profile) |profile| {
                    vpk_pkg_sh.addArg("--notaryProfile");
                    vpk_pkg_sh.addArg(profile);
                }
            },
            .linux => {
                // The AppImage's icon (its `.DirIcon` and desktop entry): a PNG.
                vpk_pkg_sh.addArg("--icon");
                vpk_pkg_sh.addFileArg(branding.png);
            },
            else => unreachable,
        }
        vpk_pkg_sh.addArgs(opts.vpk_args);
        // Stream vpk's stdout/stderr live so failures surface their actual
        // diagnostic instead of just an exit-code-N message from the build
        // runner. With `addOutputDirectoryArg` in play, `infer_from_args`
        // can otherwise capture+drop stdio on certain runner configs.
        vpk_pkg_sh.stdio = .inherit;
        vpk_pkg_sh.step.dependOn(pack_stage_tail);

        if (target.result.os.tag != .macos) break :vpk vpk_pkg_out_dir;

        // Beside the .pkg, a drag-to-Applications .dmg of the same signed bundle, named as vpk
        // names its own (`<packId>-<channel>-…`).
        const dmg_name = b.fmt("{s}-{s}.dmg", .{ app_name, zig_out_subdir });
        const dmg_sh = b.addSystemCommand(&.{"/bin/sh"});
        dmg_sh.addFileArg(b.path("build/macos_dmg.sh"));
        dmg_sh.addDirectoryArg(vpk_pkg_out_dir);
        dmg_sh.addArg(branding.package_title);
        dmg_sh.addArg(macos_sign_app_identity orelse "");
        dmg_sh.addArg(macos_notary_profile orelse "");
        const dmg = dmg_sh.addOutputFileArg(dmg_name);
        // Inherited stdio makes the step rerun each time, as vpk's does: its input directory's
        // path stays the same across vpk runs, so a cached image could hold a stale bundle.
        dmg_sh.stdio = .inherit;
        const with_dmg = b.addWriteFiles();
        _ = with_dmg.addCopyDirectory(vpk_pkg_out_dir, "", .{});
        _ = with_dmg.addCopyFile(dmg, dmg_name);
        break :vpk with_dmg.getDirectory();
    };
    package_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = installers,
        .install_dir = zig_out_install_dir,
        .install_subdir = "",
    }).step);
    // For an app built with `buildApp`, which installs them into its own prefix: a dependency's
    // prefix is a directory in the cache (`fizzy.addPackageSteps`).
    b.addNamedLazyPath("package", installers);

    const desktop_step = b.step("desktop", "Alias for `zig build package`");
    desktop_step.dependOn(package_step);

    return package_step;
}

/// `zig build packageall`: `zig build package` once for each of the six release targets, run from
/// `b`'s build root with the options `b` was given on its command line. `b` is the root builder:
/// fizzy's own (`build.zig`), or an app's built on fizzy (`fizzy.addPackageSteps`), whose
/// `build.zig` passes fizzy its options again in each run.
pub fn addPackageAllStep(b: *std.Build, no_emit: bool) void {
    const packageall_step = b.step(
        "packageall",
        "zig build package for each of the six release targets, with this build's -D " ++
            "options but the target's; -Dwindows-msvc-libc= and -Dfetch-msvc reach the " ++
            "*-windows-msvc runs only",
    );
    if (no_emit) {
        packageall_step.dependOn(&b.addFail("cannot run `packageall` with -Dno-emit").step);
        return;
    }

    // This build's command-line options, sorted so the command lines are the same each run.
    // Not the target's own (each run names its own target), and the Windows MSVC ones only for
    // the runs that build for it. `-Doptimize` only as given: an app's build may not declare it.
    const target_options = [_][]const u8{ "target", "cpu", "ofmt", "dynamic-linker" };
    const msvc_options = [_][]const u8{ "windows-msvc-libc", "fetch-msvc" };
    var common: std.ArrayList([]const u8) = .empty;
    var msvc_only: std.ArrayList([]const u8) = .empty;
    switch (b.graph.release_mode) {
        .off => {},
        .any => common.append(b.allocator, "--release") catch @panic("OOM"),
        else => |mode| common.append(b.allocator, b.fmt("--release={s}", .{@tagName(mode)})) catch @panic("OOM"),
    }
    var it = b.user_input_options.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (isOneOf(name, &target_options)) continue;
        const list = if (isOneOf(name, &msvc_options)) &msvc_only else &common;
        switch (entry.value_ptr.*) {
            .flag => list.append(b.allocator, b.fmt("-D{s}", .{name})) catch @panic("OOM"),
            .scalar => |v| list.append(b.allocator, b.fmt("-D{s}={s}", .{ name, v })) catch @panic("OOM"),
            .list => |l| for (l.items) |v|
                list.append(b.allocator, b.fmt("-D{s}={s}", .{ name, v })) catch @panic("OOM"),
            // Only a `b.dependency` call passes these, never a command line.
            .map, .lazy_path, .lazy_path_list => {},
        }
    }
    for ([_][][]const u8{ common.items, msvc_only.items }) |items| std.mem.sort([]const u8, items, {}, struct {
        fn lessThan(_: void, l: []const u8, r: []const u8) bool {
            return std.mem.lessThan(u8, l, r);
        }
    }.lessThan);

    // Build order is deliberately fail-fast: Windows first (most likely to
    // fail on a fresh CI runner because of MSVC SDK setup, libc.ini paths,
    // and cross-compile ABI surprises), then Linux (mksquashfs / AppImage
    // packaging quirks), then macOS last (native, lowest risk). When a
    // release run is going to break, this ordering surfaces the failure
    // 5-10 minutes sooner than the alphabetical order did.
    const packageall_triples = [_][]const u8{
        "x86_64-windows-msvc",
        "aarch64-windows-msvc",
        "x86_64-linux-gnu",
        "aarch64-linux-gnu",
        "x86_64-macos",
        "aarch64-macos",
    };

    var prev_step: ?*std.Build.Step = null;
    for (packageall_triples) |triple| {
        const zig_pkg_run = b.addSystemCommand(
            &.{ b.graph.zig_exe, "build", "package", b.fmt("-Dtarget={s}", .{triple}) },
        );
        zig_pkg_run.addArgs(common.items);
        if (std.mem.endsWith(u8, triple, "-windows-msvc")) zig_pkg_run.addArgs(msvc_only.items);
        // This build's own build file, from the cwd this build was run in (inherited): a
        // relative path option (`-Dapp-icon=…`) is relative to that cwd, as it was here.
        zig_pkg_run.addArgs(&.{ "--build-file", b.root.joinString(b.allocator, "build.zig") catch @panic("OOM") });
        if (prev_step) |p| zig_pkg_run.step.dependOn(p);
        prev_step = &zig_pkg_run.step;
    }
    packageall_step.dependOn(prev_step.?);
}

fn isOneOf(name: []const u8, names: []const []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}
