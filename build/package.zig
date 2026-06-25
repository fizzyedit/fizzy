const std = @import("std");
const velopack = @import("velopack_zig");
const exe = @import("exe.zig");

pub const Options = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    app_version: []const u8,
    zig_out_subdir: []const u8,
    zig_out_install_dir: std.Build.InstallDir,
    no_emit: bool,
    velopack_required_fail: ?*std.Build.Step,
    exe_for_package: *std.Build.Step.Compile,
    package_fizzy: exe.FizzyExecutable,
    macos_sign_app_identity: ?[]const u8,
    macos_sign_install_identity: ?[]const u8,
    macos_notary_profile: ?[]const u8,
    windows_msvc_libc_opt: ?[]const u8,
    fetch_msvc: bool,
};

pub fn addSteps(opts: Options) *std.Build.Step {
    const b = opts.b;
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
    const windows_msvc_libc_opt = opts.windows_msvc_libc_opt;
    const fetch_msvc = opts.fetch_msvc;

    const package_step = b.step("package", "Velopack release artifacts (strip + vpk); not part of install or run");
    // The default native target on a Windows host resolves to x86_64-windows-gnu,
    // for which `velopack_supported_for_target` is false — exe_for_package falls
    // back to the plain (Velopack-less) exe. vpk would still wrap it as a Velopack
    // installer, but the install hook never runs: Setup.exe hangs with "the
    // application install hook failed". Fail loudly instead of shipping that trap.
    const windows_non_msvc = target.result.os.tag == .windows and target.result.abi != .msvc;
    if (velopack_required_fail) |fail_step| {
        package_step.dependOn(fail_step);
    } else if (windows_non_msvc) {
        package_step.dependOn(&b.addFail(
            \\`zig build package` for Windows requires the MSVC ABI so Velopack is linked.
            \\The default native target resolves to x86_64-windows-gnu, which builds a binary
            \\WITHOUT the Velopack runtime. vpk would still wrap it as a Velopack installer, but
            \\the install hook never runs and Setup.exe hangs ("the application install hook failed").
            \\
            \\Build with the MSVC target instead:
            \\  zig build package -Dtarget=x86_64-windows-msvc -Dfetch-msvc
            \\(needs Windows SDK 10.0.26100+ for SDL's GameInput backend.)
        ).step);
    } else if (no_emit) {
        package_step.dependOn(&b.addFail("cannot run `package` with -Dno-emit").step);
    } else switch (target.result.os.tag) {
        .linux, .macos, .windows => {
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
            const skip_strip = host_is_windows or optimize == .Debug or cross_for_strip;
            const strip_release_sh = if (host_is_windows) blk: {
                const sh = b.addSystemCommand(&.{ "cmd", "/c", "exit", "0" });
                sh.step.dependOn(&exe_for_package.step);
                break :blk sh;
            } else blk: {
                const sh = b.addSystemCommand(&.{if (skip_strip) "touch" else "strip"});
                sh.addFileArg(exe_for_package.getEmittedBin());
                break :blk sh;
            };
    
            //const dotnet_tool_restore = velopack.addDotnetToolRestoreStep(b);
            //const vpk_vendor_repair = velopack.addVpkVendorRepairStep(b);
            //vpk_vendor_repair.step.dependOn(&dotnet_tool_restore.step);
    
            const vpk_pkg_sh = b.addSystemCommand(&.{"dotnet"});
            vpk_pkg_sh.addArg("vpk");
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
            vpk_pkg_sh.addArg("fizzy");
            vpk_pkg_sh.addArg("--packVersion");
            vpk_pkg_sh.addArg(app_version);
            // Channel = zig-out subdir (`<arch>-<os>`, NuGet-safe — no underscores). Baked into
            // the binary by vpk; the updater matches this to release assets. Distinct per triple
            // so parallel `vpk pack` runs don't collide on RELEASES / nupkg names.
            vpk_pkg_sh.addArg("--channel");
            vpk_pkg_sh.addArg(zig_out_subdir);
            vpk_pkg_sh.addArg("--mainExe");
            vpk_pkg_sh.addArg(switch (target.result.os.tag) {
                .windows => "fizzy.exe",
                else => "fizzy",
            });
    
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
            const pack_stage_tail = exe.addVelopackPackDirInstall(
                b,
                exe_for_package,
                package_fizzy,
                pack_input_subdir,
                pack_plugins_subdir,
                &strip_release_sh.step,
            );
            vpk_pkg_sh.addArg("--packDir");
            vpk_pkg_sh.addArg(b.getInstallPath(.{ .custom = pack_input_subdir }, ""));
            switch (target.result.os.tag) {
                .windows => {
                    // Sets the installer's icon and the Start Menu shortcut icon. The
                    // exe's own icon is already embedded via assets/windows/fizzy.rc.
                    vpk_pkg_sh.addArg("--icon");
                    const ico_path = b.path("assets/windows/fizzy.ico").getPath3(b, &vpk_pkg_sh.step).toString(b.allocator) catch |e| std.debug.panic("ico path: {}", .{e});
                    vpk_pkg_sh.addArg(ico_path);
                    // Velopack's installer is silent (no shortcut-choice UI). Default is
                    // Desktop,StartMenu; restrict to StartMenu so we don't drop an
                    // unrequested icon on the user's desktop.
                    vpk_pkg_sh.addArg("--shortcuts");
                    vpk_pkg_sh.addArg("StartMenu");
                },
                .macos => {
                    vpk_pkg_sh.addArg("--packTitle");
                    vpk_pkg_sh.addArg("fizzy");
                    // Bundle id / document types / versions: assets/macos/info.plist (vpk rejects --bundleId with --plist).
                    vpk_pkg_sh.addArg("--plist");
                    const plist_path = b.path("assets/macos/info.plist").getPath3(b, &vpk_pkg_sh.step).toString(b.allocator) catch |e| std.debug.panic("plist path: {}", .{e});
                    vpk_pkg_sh.addArg(plist_path);
                    vpk_pkg_sh.addArg("--icon");
                    const icns_path = b.path("assets/macos/fizzy.icns").getPath3(b, &vpk_pkg_sh.step).toString(b.allocator) catch |e| std.debug.panic("icns path: {}", .{e});
                    vpk_pkg_sh.addArg(icns_path);
    
                    if (macos_sign_app_identity) |id| {
                        vpk_pkg_sh.addArg("--signAppIdentity");
                        vpk_pkg_sh.addArg(id);
                        // Required for notarization: enables hardened runtime + secure timestamp on
                        // every nested binary (vpk forwards the file to `codesign --entitlements`).
                        // Without this, Apple's notary service rejects with "signature does not
                        // include a secure timestamp" / "hardened runtime not enabled".
                        vpk_pkg_sh.addArg("--signEntitlements");
                        const entitlements_path = b.path("assets/macos/Fizzy.entitlements").getPath3(b, &vpk_pkg_sh.step).toString(b.allocator) catch |e| std.debug.panic("entitlements path: {}", .{e});
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
                else => {},
            }
            vpk_pkg_sh.setEnvironmentVariable("DOTNET_ROLL_FORWARD", "Major");
            // Stream vpk's stdout/stderr live so failures surface their actual
            // diagnostic instead of just an exit-code-N message from the build
            // runner. With `addOutputDirectoryArg` in play, `infer_from_args`
            // can otherwise capture+drop stdio on certain runner configs.
            vpk_pkg_sh.stdio = .inherit;
            try velopack.attachMksquashfsToVpkRun(b, vpk_pkg_sh, target);
    
            //vpk_pkg_sh.step.dependOn(&vpk_vendor_repair.step);
            vpk_pkg_sh.step.dependOn(pack_stage_tail);
    
            const build_package_install = b.addInstallDirectory(.{
                .source_dir = vpk_pkg_out_dir,
                .install_dir = zig_out_install_dir,
                .install_subdir = "",
            });
    
            package_step.dependOn(&build_package_install.step);
        },
        else => {
            package_step.dependOn(&b.addFail("Velopack packaging is only supported for Linux, macOS, and Windows targets").step);
        },
    }
    
    const desktop_step = b.step("desktop", "Alias for `zig build package`");
    desktop_step.dependOn(package_step);
    
    const packageall_step = b.step("packageall", "Six zig build package runs; use -Dwindows-msvc-libc= or -Dfetch-msvc for Windows children from macOS/Linux");
    if (no_emit) {
        packageall_step.dependOn(&b.addFail("cannot run `packageall` with -Dno-emit").step);
    } else {
        const packageall_optimize_arg = b.fmt("-Doptimize={s}", .{@tagName(optimize)});
    
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
            const zig_pkg_run = b.addSystemCommand(&.{
                b.graph.zig_exe,
                "build",
                "package",
                packageall_optimize_arg,
                b.fmt("-Dtarget={s}", .{triple}),
            });
            if (std.mem.endsWith(u8, triple, "-windows-msvc")) {
                if (windows_msvc_libc_opt) |libc_path| {
                    zig_pkg_run.addArg(b.fmt("-Dwindows-msvc-libc={s}", .{libc_path}));
                }
                if (fetch_msvc) zig_pkg_run.addArg("-Dfetch-msvc");
            }
            zig_pkg_run.setCwd(b.path("."));
            if (prev_step) |p| {
                zig_pkg_run.step.dependOn(p);
            }
            prev_step = &zig_pkg_run.step;
        }
        packageall_step.dependOn(prev_step.?);
    }
    
    return package_step;
}
