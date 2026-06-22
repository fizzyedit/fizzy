const std = @import("std");

const plugin = @import("../plugin_sdk.zig");
const dvui = @import("dvui");
const velopack = @import("velopack.zig");

pub const Options = struct {
    windows_msvc_libc_opt: ?[]const u8 = null,
    fetch_msvc_opt: ?bool = null,
    macos_sign_app_identity: ?[]const u8 = null,
    macos_sign_install_identity: ?[]const u8 = null,
    macos_notary_profile: ?[]const u8 = null,
};

pub fn build(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, opts: Options) !void {
    const windows_msvc_libc_opt = opts.windows_msvc_libc_opt;
    const fetch_msvc_opt = opts.fetch_msvc_opt;
    const macos_sign_app_identity = opts.macos_sign_app_identity;
    const macos_sign_install_identity = opts.macos_sign_install_identity;
    const macos_notary_profile = opts.macos_notary_profile;

    // Resolve Velopack lazily. This runs only on app builds (never on the plugin-SDK path,
    // which returns from the root build before reaching here), so plugin builds never fetch
    // it. On the first configure pass this returns null → Zig fetches velopack_zig and
    // re-runs build(); the second pass proceeds with a valid handle.
    const vz = b.lazyDependency("velopack_zig", .{}) orelse return;

    const common = @import("common.zig");
    const plugins = @import("plugins.zig");
    const sdk = @import("sdk.zig");
    const fizzy_exe = @import("exe.zig");
    const web = @import("web.zig");
    const package = @import("package.zig");
    const msvc = @import("msvc.zig");

    const workbench_plugin = plugins.workbench;
    const text_plugin = plugins.text;
    const image_plugin = plugins.image;
    const FizzyExecutable = fizzy_exe.FizzyExecutable;

    // Built-in plugins are embedded by importing their `static/integration.zig` directly
    // (via build/plugins.zig); the root build owns the module graph, so there is no plugin
    // package dependency to resolve here. Their canonical `build.zig` is only for the
    // standalone (`cd src/plugins/<name> && zig build`) third-party-shape build.

    const macos_sdl_paths = try common.macosSdlPathsForExplicitTarget(b, target);
    const zig_out_subdir = common.zigOutSubdirForTarget(b, target);
    const zig_out_install_dir: std.Build.InstallDir = .{ .custom = zig_out_subdir };

    const target_is_windows_msvc = target.result.os.tag == .windows and target.result.abi == .msvc;
    const cross_win_msvc = target_is_windows_msvc and b.graph.host.result.os.tag != .windows;

    // Auto-fetch defaults: on Windows hosts targeting *-windows-msvc, downloading the
    // MSVC SDK into .velopack-msvc/ is the deterministic path — Zig's auto-detection
    // of a system Visual Studio install picks up whatever's currently installed, which
    // makes packaged release builds non-reproducible. The same .velopack-msvc/ tree is
    // used on macOS/Linux cross-compile hosts, so all three triples land on the same
    // SDK headers + libs. Explicit `-Dfetch-msvc=false` opts out (use system VS); an
    // explicit `-Dwindows-msvc-libc=...` overrides the discovery entirely.
    const fetch_msvc = fetch_msvc_opt orelse (target_is_windows_msvc and windows_msvc_libc_opt == null);

    const win_libc = velopack.resolveWindowsMsvcLibc(b, target, .{ // vendored: pure path logic, no velopack dep needed
        .explicit_path = windows_msvc_libc_opt,
        .install_dir_name = ".velopack-msvc",
        .fetch_if_missing = fetch_msvc,
    });

    var effective_win_libc: ?[]const u8 = win_libc.libc_path;
    if (effective_win_libc == null) {
        if (cross_win_msvc) effective_win_libc = b.libc_file;
    }

    // Velopack in the dev/install exe is opt-in (`-Dvelopack=true`). Release
    // packaging (`zig build package`) still links Velopack when the ABI supports
    // it via a second compile, so `zig build` / `run` / `test` never pull dotnet
    // or the static Velopack lib unless you ask. Windows *-gnu targets are
    // unchanged (no Velopack prebuilt for that ABI).
    const velopack_supported_for_target = !(target.result.os.tag == .windows and target.result.abi != .msvc);
    const velopack_enabled = b.option(
        bool,
        "velopack",
        "Link Velopack runtime in the install/run exe (auto-update). Default: false. `package` still produces a Velopack-linked binary when supported.",
    ) orelse false;

    if (velopack_enabled and !velopack_supported_for_target) {
        std.log.err(
            "-Dvelopack=true is unsupported for target ABI {s}: Velopack on Windows requires -Dtarget=x86_64-windows-msvc or -Dtarget=aarch64-windows-msvc.",
            .{@tagName(target.result.abi)},
        );
        return error.WindowsMsvcAbiRequired;
    }

    // Fail loudly when the *-windows-msvc target has no headers/libs to compile against.
    // On a non-Windows host this happens whenever `.velopack-msvc/` is missing and the
    // user didn't pass `-Dfetch-msvc` or `-Dwindows-msvc-libc=…`. On a Windows host the
    // auto-fetch default makes this unreachable unless the user explicitly opted out
    // with `-Dfetch-msvc=false` — in which case Zig falls back to system Visual Studio
    // auto-detection, which we can't validate here.
    const velopack_required_fail: ?*std.Build.Step = if (cross_win_msvc and effective_win_libc == null)
        &b.addFail(
            \\*-windows-msvc needs MSVC + Windows SDK headers/libs.
            \\  One-shot install (macOS/Linux/Windows): zig build msvcup-setup
            \\  Then: zig build package -Dtarget=x86_64-windows-msvc   (auto-uses .velopack-msvc/zig-libc-x64.ini)
            \\  Or auto-download in this build: add -Dfetch-msvc       (default on Windows hosts; forwards through packageall)
            \\  Or pass: --libc path.ini  /  -Dwindows-msvc-libc=path.ini
        ).step
    else
        null;

    const no_emit = b.option(bool, "no-emit", "Check for compile errors without emitting any code") orelse false;

    const app_version_opt = b.option([]const u8, "app_version", "App version for vpk packVersion and startup log; defaults to VERSION file");

    // GitHub repo URL baked into the binary so Velopack's auto-update can find
    // the latest release via the GitHub Releases API. Override at build time
    // with `-Drepo-url=...` (e.g. when shipping a fork). At runtime, the env
    // var `FIZZY_AUTOUPDATE_URL` still overrides this for local feed testing.
    const app_repo_url = b.option([]const u8, "repo-url", "GitHub repo URL used by Velopack auto-update (e.g. https://github.com/fizzyedit/fizzy)") orelse "https://github.com/fizzyedit/fizzy";

    // Comma-separated fallback repo URLs checked (in order) after `app_repo_url`
    // yields no update. Lets a build survive a repo move/rename: ship a binary
    // whose primary points at the new home and whose fallback points at the old
    // one (where the transitional release is published), then transfer the repo.
    // Empty by default (no fallback).
    const app_repo_url_fallback = b.option([]const u8, "repo-url-fallback", "Comma-separated fallback GitHub repo URLs for Velopack auto-update, tried after -Drepo-url") orelse "";

    var version_owned: ?[]u8 = null;
    defer if (version_owned) |buf| b.allocator.free(buf);

    const app_version: []const u8 = if (app_version_opt) |v| v else blk: {
        const raw = b.build_root.handle.readFileAlloc(b.graph.io, "VERSION", b.allocator, std.Io.Limit.limited(256)) catch |e| std.debug.panic("read VERSION: {}", .{e});
        version_owned = raw;
        break :blk std.mem.trimEnd(u8, raw, "\r\n");
    };

    const build_opts = b.addOptions();
    build_opts.addOption([]const u8, "app_version", app_version);
    build_opts.addOption([]const u8, "app_repo_url", app_repo_url);
    build_opts.addOption([]const u8, "app_repo_url_fallback", app_repo_url_fallback);
    build_opts.addOption(bool, "velopack_enabled", velopack_enabled);
    const static_workbench = b.option(
        bool,
        "static-workbench",
        "Keep workbench statically registered on native (skip built-in dylib load)",
    ) orelse false;
    build_opts.addOption(bool, "static_workbench", static_workbench);
    const static_text = b.option(
        bool,
        "static-text",
        "Keep text plugin statically registered on native (skip built-in dylib load)",
    ) orelse false;
    build_opts.addOption(bool, "static_text", static_text);
    const static_image = b.option(
        bool,
        "static-image",
        "Keep image plugin statically registered on native (skip built-in dylib load)",
    ) orelse false;
    build_opts.addOption(bool, "static_image", static_image);
    const workbench_file_tree = b.option(
        bool,
        "workbench-file-tree",
        "Register the workbench Files sidebar view (file tree)",
    ) orelse true;
    const workbench_opts = b.addOptions();
    workbench_opts.addOption(bool, "file_tree", workbench_file_tree);

    common.addUpdateStep(b);

    const msvcup_before_compile = velopack.addMsvcupSetupStep(b, vz, ".velopack-msvc");
    const msvcup_setup_step = b.step("msvcup-setup", "Download MSVC SDK into .velopack-msvc/ via velopack-zig (writes zig-libc-*.ini)");
    msvcup_setup_step.dependOn(&msvcup_before_compile.step);

    const accesskit = b.option(dvui.AccesskitOptions, "accesskit", "Enable accesskit") orelse .off;

    const assetpack = @import("assetpack");
    const assets_module = assetpack.pack(b, b.path("assets"), .{});

    // ---------------------------------------------------------------
    // Web (wasm) build — entirely separate from the native exe so it can't disturb
    // packaging / SDL / Velopack paths. `zig build web` produces `zig-out/web/{web.wasm,
    // web.js, index.html, NotoSansKR-Regular.ttf}`, deployable as-is to a static host.
    // ---------------------------------------------------------------

    web.addSteps(b, optimize, build_opts, workbench_opts, assets_module);

    const main_fizzy = try fizzy_exe.addFizzyExecutableForTarget(b, vz, target, optimize, accesskit, build_opts, workbench_opts, assets_module, macos_sdl_paths, velopack_enabled);
    const exe = main_fizzy.exe;

    const package_fizzy: FizzyExecutable = package_blk: {
        if (velopack_enabled) break :package_blk main_fizzy;
        if (!velopack_supported_for_target) break :package_blk main_fizzy;
        const pack_opts = b.addOptions();
        pack_opts.addOption([]const u8, "app_version", app_version);
        pack_opts.addOption([]const u8, "app_repo_url", app_repo_url);
        pack_opts.addOption([]const u8, "app_repo_url_fallback", app_repo_url_fallback);
        pack_opts.addOption(bool, "velopack_enabled", true);
        pack_opts.addOption(bool, "static_workbench", static_workbench);
        pack_opts.addOption(bool, "static_text", static_text);
        pack_opts.addOption(bool, "static_image", static_image);
        break :package_blk try fizzy_exe.addFizzyExecutableForTarget(b, vz, target, optimize, accesskit, pack_opts, workbench_opts, assets_module, macos_sdl_paths, true);
    };
    const exe_for_package = package_fizzy.exe;

    if (no_emit) {
        b.getInstallStep().dependOn(&exe.step);
        if (main_fizzy.workbench_dylib) |workbench_dylib| {
            const plugins_install_dir: std.Build.InstallDir = .{ .custom = b.fmt("{s}/plugins", .{zig_out_subdir}) };
            common.attachBuiltinPluginInstall(b, b.getInstallStep(), workbench_dylib, "workbench", plugins_install_dir);
        }
        if (main_fizzy.text_dylib) |text_dylib| {
            const plugins_install_dir: std.Build.InstallDir = .{ .custom = b.fmt("{s}/plugins", .{zig_out_subdir}) };
            common.attachBuiltinPluginInstall(b, b.getInstallStep(), text_dylib, "text", plugins_install_dir);
        }
        if (main_fizzy.markdown_dylib) |markdown_dylib| {
            const plugins_install_dir: std.Build.InstallDir = .{ .custom = b.fmt("{s}/plugins", .{zig_out_subdir}) };
            common.attachBuiltinPluginInstall(b, b.getInstallStep(), markdown_dylib, "markdown", plugins_install_dir);
        }
        if (main_fizzy.image_dylib) |image_dylib| {
            const plugins_install_dir: std.Build.InstallDir = .{ .custom = b.fmt("{s}/plugins", .{zig_out_subdir}) };
            common.attachBuiltinPluginInstall(b, b.getInstallStep(), image_dylib, "image", plugins_install_dir);
        }
    } else {
        const install_artifact = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = zig_out_install_dir },
        });

        const run_cmd = b.addRunArtifact(exe);
        const run_step = b.step("run", "Run the app (does not run Velopack)");

        run_cmd.step.dependOn(&install_artifact.step);
        run_step.dependOn(&run_cmd.step);
        b.getInstallStep().dependOn(&install_artifact.step);

        if (main_fizzy.workbench_dylib) |workbench_dylib| {
            const plugins_install_dir: std.Build.InstallDir = .{ .custom = b.fmt("{s}/plugins", .{zig_out_subdir}) };
            common.attachBuiltinPluginInstall(b, b.getInstallStep(), workbench_dylib, "workbench", plugins_install_dir);
            common.attachBuiltinPluginInstall(b, &run_cmd.step, workbench_dylib, "workbench", plugins_install_dir);
        }
        if (main_fizzy.text_dylib) |text_dylib| {
            const plugins_install_dir: std.Build.InstallDir = .{ .custom = b.fmt("{s}/plugins", .{zig_out_subdir}) };
            common.attachBuiltinPluginInstall(b, b.getInstallStep(), text_dylib, "text", plugins_install_dir);
            common.attachBuiltinPluginInstall(b, &run_cmd.step, text_dylib, "text", plugins_install_dir);
        }
        if (main_fizzy.markdown_dylib) |markdown_dylib| {
            const plugins_install_dir: std.Build.InstallDir = .{ .custom = b.fmt("{s}/plugins", .{zig_out_subdir}) };
            common.attachBuiltinPluginInstall(b, b.getInstallStep(), markdown_dylib, "markdown", plugins_install_dir);
            common.attachBuiltinPluginInstall(b, &run_cmd.step, markdown_dylib, "markdown", plugins_install_dir);
        }
        if (main_fizzy.image_dylib) |image_dylib| {
            const plugins_install_dir: std.Build.InstallDir = .{ .custom = b.fmt("{s}/plugins", .{zig_out_subdir}) };
            common.attachBuiltinPluginInstall(b, b.getInstallStep(), image_dylib, "image", plugins_install_dir);
            common.attachBuiltinPluginInstall(b, &run_cmd.step, image_dylib, "image", plugins_install_dir);
        }
    }

    if (main_fizzy.workbench_dylib) |workbench_dylib| {
        const plugins_install_dir: std.Build.InstallDir = .{ .custom = b.fmt("{s}/plugins", .{zig_out_subdir}) };
        const install_workbench = plugin.installBuiltinPlugin(b, workbench_dylib, "workbench", plugins_install_dir);
        const workbench_dylib_step = b.step(
            "workbench-dylib",
            "Build the workbench plugin as a dynamic library into zig-out/<target>/plugins/ (native only)",
        );
        workbench_dylib_step.dependOn(&install_workbench.step);
    }

    if (main_fizzy.text_dylib) |text_dylib| {
        const plugins_install_dir: std.Build.InstallDir = .{ .custom = b.fmt("{s}/plugins", .{zig_out_subdir}) };
        const install_text = plugin.installBuiltinPlugin(b, text_dylib, "text", plugins_install_dir);
        const text_dylib_step = b.step(
            "text-dylib",
            "Build the text plugin as a dynamic library into zig-out/<target>/plugins/ (native only)",
        );
        text_dylib_step.dependOn(&install_text.step);
    }

    if (main_fizzy.markdown_dylib) |markdown_dylib| {
        const plugins_install_dir: std.Build.InstallDir = .{ .custom = b.fmt("{s}/plugins", .{zig_out_subdir}) };
        const install_markdown = plugin.installBuiltinPlugin(b, markdown_dylib, "markdown", plugins_install_dir);
        const markdown_dylib_step = b.step(
            "markdown-dylib",
            "Build the markdown plugin as a dynamic library into zig-out/<target>/plugins/ (native only)",
        );
        markdown_dylib_step.dependOn(&install_markdown.step);
    }

    if (main_fizzy.image_dylib) |image_dylib| {
        const plugins_install_dir: std.Build.InstallDir = .{ .custom = b.fmt("{s}/plugins", .{zig_out_subdir}) };
        const install_image = plugin.installBuiltinPlugin(b, image_dylib, "image", plugins_install_dir);
        const image_dylib_step = b.step(
            "image-dylib",
            "Build the image plugin as a dynamic library into zig-out/<target>/plugins/ (native only)",
        );
        image_dylib_step.dependOn(&install_image.step);
    }

    _ = package.addSteps(.{
        .b = b,
        .vz = vz,
        .target = target,
        .optimize = optimize,
        .app_version = app_version,
        .zig_out_subdir = zig_out_subdir,
        .zig_out_install_dir = zig_out_install_dir,
        .no_emit = no_emit,
        .velopack_required_fail = velopack_required_fail,
        .exe_for_package = exe_for_package,
        .package_fizzy = package_fizzy,
        .macos_sign_app_identity = macos_sign_app_identity,
        .macos_sign_install_identity = macos_sign_install_identity,
        .macos_notary_profile = macos_notary_profile,
        .windows_msvc_libc_opt = windows_msvc_libc_opt,
        .fetch_msvc = fetch_msvc,
    });

    // ---------------------------------------------------------------
    // Tests
    // ---------------------------------------------------------------
    //
    // Fizzy has two test layers (see tests/README.md):
    //
    //   1. Unit tests — pure-logic only (math, palette parsing, layer
    //      order). The test root imports nothing but std + the pure
    //      modules under test, so it compiles in well under a second
    //      and never needs dvui/SDL/assets.
    //
    //   2. Integration tests use dvui's testing backend and exercise
    //      real fizzy drawing functions in a headless Window.
    //
    // Both share the same `zig build test` and `zig build check`
    // entry points.

    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match any filter",
    ) orelse &[0][]const u8{};

    const tests_module = b.addModule("fizzy-tests", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("tests/root.zig"),
    });

    inline for (.{
        .{ "fizzy-direction", "src/core/math/direction.zig" },
        .{ "fizzy-easing", "src/core/math/easing.zig" },
        .{ "fizzy-layout-anchor", "src/core/math/layout_anchor.zig" },
        .{ "fizzy-window-layout", "src/backend/window_layout.zig" },
        .{ "fizzy-plugin-dylib", "src/sdk/dylib.zig" },
        .{ "fizzy-plugin-store", "src/backend/plugin_store/store.zig" },
    }) |entry| {
        tests_module.addAnonymousImport(entry[0], .{
            .root_source_file = b.path(entry[1]),
            .target = target,
            .optimize = optimize,
        });
    }

    const unit_tests = b.addTest(.{
        .name = "fizzy-unit-tests",
        .root_module = tests_module,
        .filters = test_filters,
    });

    // `zig build test` is the CI entry point and must stay self-contained: pure
    // unit tests only, no dvui/SDL/Velopack/MSVC. Integration tests live under
    // `zig build test-integration` (Velopack + dvui-testing + comctl32 on Windows
    // → needs MSVC SDK on Windows hosts). `zig build test-all` runs both.
    const test_step = b.step("test", "Run fizzy unit tests (pure-logic only, no dvui/SDL/Velopack)");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // `check` mirrors the split so editor compile-error checking matches CI.
    const check_step = b.step("check", "Compile fizzy unit tests without running them");
    check_step.dependOn(&unit_tests.step);

    // ---------------------------------------------------------------
    // Layer 2: headless integration tests against dvui's testing
    // backend. Wired under separate `test-integration` / `check-integration`
    // steps so `zig build test` stays MSVC-free on Windows CI runners. Skipped
    // when cross-compiling to *-windows-msvc without an MSVC libc INI.
    // ---------------------------------------------------------------
    const test_integration_step = b.step("test-integration", "Run fizzy headless integration tests (dvui-testing; needs MSVC on Windows)");
    const check_integration_step = b.step("check-integration", "Compile fizzy integration tests without running them");
    const test_all_step = b.step("test-all", "Run unit + integration tests");
    test_all_step.dependOn(test_step);
    test_all_step.dependOn(test_integration_step);

    const test_sdk_version_step = b.step(
        "test-sdk-version",
        "Verify SDK version ↔ ABI fingerprint lock (compiles SDK + plugin dylib)",
    );
    if (main_fizzy.workbench_dylib) |dylib| {
        test_sdk_version_step.dependOn(&dylib.step);
    } else {
        test_sdk_version_step.dependOn(&exe.step);
    }
    test_all_step.dependOn(test_sdk_version_step);

    if (velopack_required_fail) |fail_step| {
        test_integration_step.dependOn(fail_step);
        check_integration_step.dependOn(fail_step);
        return;
    }

    const dvui_testing_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .testing,
        .accesskit = accesskit,
    });
    const dvui_test_proxy_bridge = sdk.addProxyBridgeModule(b, target, optimize, dvui_testing_dep, dvui_testing_dep.module("dvui_testing"));

    // Build a module rooted at `src/fizzy.zig` carrying all the same
    // imports the production exe carries. Because fizzy.zig's transitive
    // imports (App.zig, Editor.zig, …) reference `dvui`, `assets`, etc. by
    // name, those names must be wired here.
    // We point dvui at the *testing* backend so calling drawing
    // functions doesn't try to open a real OS window.
    const fizzy_test_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/fizzy.zig"),
    });
    fizzy_test_module.addImport("dvui", dvui_testing_dep.module("dvui_testing"));
    fizzy_test_module.addImport("backend", dvui_testing_dep.module("testing"));
    fizzy_test_module.addImport("assets", assets_module);
    fizzy_test_module.addOptions("build_opts", build_opts);
    if (b.lazyDependency("icons", .{ .target = target, .optimize = optimize })) |dep| {
        fizzy_test_module.addImport("icons", dep.module("icons"));
    }

    // Shared `core` module for the test build (dvui testing backend variant).
    const core_module_test = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/core/core.zig"),
    });
    core_module_test.addImport("dvui", dvui_testing_dep.module("dvui_testing"));
    if (b.lazyDependency("icons", .{ .target = target, .optimize = optimize })) |dep| {
        core_module_test.addImport("icons", dep.module("icons"));
    }
    fizzy_test_module.addImport("core", core_module_test);

    const sdk_module_test = sdk.wireSdkModule(b, target, optimize, dvui_testing_dep.module("dvui_testing"), dvui_test_proxy_bridge, core_module_test, fizzy_test_module);
    _ = workbench_plugin.addStaticModule(b, target, optimize, .{
        .dvui = dvui_testing_dep.module("dvui_testing"),
        .core = core_module_test,
        .sdk = sdk_module_test,
        .icons = if (b.lazyDependency("icons", .{ .target = target, .optimize = optimize })) |dep| dep.module("icons") else null,
        .backend = dvui_testing_dep.module("testing"),
    }, workbench_opts, fizzy_test_module);
    _ = text_plugin.addStaticModule(b, target, optimize, .{
        .dvui = dvui_testing_dep.module("dvui_testing"),
        .core = core_module_test,
        .sdk = sdk_module_test,
    }, fizzy_test_module);
    _ = plugins.markdown.addStaticModule(b, target, optimize, .{
        .dvui = dvui_testing_dep.module("dvui_testing"),
        .core = core_module_test,
        .sdk = sdk_module_test,
    }, fizzy_test_module);
    _ = image_plugin.addStaticModule(b, target, optimize, .{
        .dvui = dvui_testing_dep.module("dvui_testing"),
        .core = core_module_test,
        .sdk = sdk_module_test,
    }, fizzy_test_module);

    if (target.result.os.tag == .macos) {
        if (b.lazyDependency("zig_objc", .{ .target = target, .optimize = optimize })) |dep| {
            fizzy_test_module.addImport("objc", dep.module("objc"));
        }
    } else if (target.result.os.tag == .windows) {
        if (b.lazyDependency("zigwin32", .{})) |dep| {
            fizzy_test_module.addImport("win32", dep.module("win32"));
        }
    }

    const integration_module = b.addModule("fizzy-integration-tests", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("tests/integration.zig"),
    });
    integration_module.addImport("fizzy", fizzy_test_module);
    integration_module.addImport("dvui", dvui_testing_dep.module("dvui_testing"));

    const integration_tests = b.addTest(.{
        .name = "fizzy-integration-tests",
        .root_module = integration_module,
        .filters = test_filters,
    });

    if (target.result.os.tag == .windows) {
        integration_tests.root_module.linkSystemLibrary("comctl32", .{});
    }
    // Zig's bundled libc++/libcxxabi cannot compile against MSVC headers from
    // --libc (vcruntime_typeinfo.h vs libc++ type_info, etc.), so libc++ must be
    // off for the msvc ABI regardless of host (cross or native Windows).
    integration_tests.root_module.link_libcpp = !target_is_windows_msvc;
    if (velopack_enabled) {
        try velopack.linkVelopack(b, vz, integration_tests, .{ .target = target, .optimize = optimize });
    }

    test_integration_step.dependOn(&b.addRunArtifact(integration_tests).step);
    check_integration_step.dependOn(&integration_tests.step);

    if (win_libc.needs_setup) {
        exe.step.dependOn(&msvcup_before_compile.step);
        if (!velopack_enabled and velopack_supported_for_target) {
            exe_for_package.step.dependOn(&msvcup_before_compile.step);
        }
        integration_tests.step.dependOn(&msvcup_before_compile.step);
        unit_tests.step.dependOn(&msvcup_before_compile.step);
    }

    if (target.result.os.tag == .windows and target.result.abi == .msvc) {
        var roots: [4]*std.Build.Step.Compile = undefined;
        var n: usize = 0;
        roots[n] = exe;
        n += 1;
        roots[n] = unit_tests;
        n += 1;
        roots[n] = integration_tests;
        n += 1;
        if (!velopack_enabled and velopack_supported_for_target) {
            roots[n] = exe_for_package;
            n += 1;
        }

        // Always apply the translate-c shim + SIZE_MAX define for windows-msvc, regardless of
        // whether we're using a downloaded SDK or the host's system MSVC. translate-c uses aro
        // (not MSVC cl.exe), and aro rejects literals like `0xffffffffffffffffui64` from MSVC's
        // <stdint.h>. The shim shadows stdint.h via `-I` (search order beats `-isystem`); the
        // defineCMacro adds belt-and-suspenders by predefining SIZE_MAX before any include so
        // MSVC's stdint.h `#ifndef SIZE_MAX` skips its own definition entirely.
        msvc.applyMsvcTranslateCShim(b, roots[0..n]) catch |e| {
            std.debug.panic("MSVC translate-c shim wiring failed: {s}", .{@errorName(e)});
        };

        if (effective_win_libc) |ini| {
            if (cross_win_msvc) b.libc_file = null;
            const libc_lp: std.Build.LazyPath = .{ .cwd_relative = ini };
            velopack.applyWindowsMsvcLibcRecursive(b, roots[0..n], libc_lp);

            const ini_exists = blk: {
                b.build_root.handle.access(b.graph.io, ini, .{}) catch break :blk false;
                break :blk true;
            };
            if (ini_exists) {
                // Adds explicit MSVC/UCRT/SDK `-isystem` paths from the libc INI to each reachable
                // translate-c step. Only relevant when cross-compiling with .velopack-msvc/; on a
                // Windows host with system MSVC, Zig auto-discovers these paths itself.
                msvc.applyMsvcIncludesToReachableTranslateC(b, roots[0..n], ini) catch |e| {
                    std.debug.panic("MSVC translate-c include fixup failed: {s}", .{@errorName(e)});
                };
            } else {
                // The INI is written by `msvcup-setup` (a make-phase step), but the translate-c
                // `-isystem` paths embed the SDK version subdir, which is only known after the SDK
                // is installed — so they must be wired at configure time, before that step runs.
                // A one-shot `zig build package -Dfetch-msvc` against a clean .velopack-msvc can't
                // satisfy that ordering. Fail only the compiles that need it (not `msvcup-setup`,
                // which has no such dependency), so running setup first still works.
                const fail = &b.addFail(
                    \\*-windows-msvc has no .velopack-msvc/zig-libc INI yet, so translate-c can't be wired.
                    \\The SDK install must run as its own step before packaging (it can't be done in one
                    \\pass — the translate-c include paths depend on the installed SDK version):
                    \\  zig build msvcup-setup
                    \\  zig build package -Dtarget=x86_64-windows-msvc
                ).step;
                for (roots[0..n]) |rc| rc.step.dependOn(fail);
            }
        }
    }
}
