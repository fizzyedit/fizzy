const std = @import("std");

// Through the `sdk/` dependency, not by relative path — see `build/sdk.zig`'s `dvuiDependency` for
// why the app consumes the SDK as a package, and `sdk/build.zig` for what it exposes. dvui's build
// API arrives the same way because `sdk/` owns the repo's only dvui pin.
const fizzy_sdk = @import("fizzy_sdk");
const plugin = fizzy_sdk.plugin;
const core_mod = fizzy_sdk.core_module;
const dvui = fizzy_sdk.dvui;
const velopack = @import("velopack.zig");

/// A plugin checkout for the web build, with the modules its own `build.zig` would have added
/// beside the SDK's (a bundled library under `src/`, say) — the web build has no way to run that
/// `build.zig`, so they are named here.
pub const WebPluginDir = struct {
    dir: []const u8,
    modules: []const ExtraModule = &.{},
    pub const ExtraModule = struct {
        /// The import name the plugin uses.
        name: []const u8,
        /// Root source file, relative to `dir`.
        root: []const u8,
        /// Whether the module itself imports `dvui` / `core`.
        dvui: bool = true,
        core: bool = false,
    };
};

pub const Options = struct {
    /// Plugins the application bundles beyond fizzy's own — see `build.zig`'s `buildApp`.
    app_plugins: []const @import("sdk.zig").BundledPlugin = &.{},
    /// Dependencies (by the name in `build.zig.zon`) whose `"plugin"` module the **web** build
    /// links in. The browser cannot `dlopen`, so a plugin exists there only if the application
    /// bundles it; this is fizzy-the-app's list, resolved for the wasm target. Each is looked
    /// up lazily, so a missing dependency only costs the web target that plugin. For a
    /// URL-pinned package; a *path* to a sibling checkout cannot go here (its own `fizzy`
    /// dependency would name this repo's `sdk/` under a second path, which Zig refuses) —
    /// that is what `web_plugin_dirs` is for.
    web_plugin_deps: []const []const u8 = &.{},
    /// Plugin checkouts (directories holding `plugin.zig` + `plugin.zig.zon`) the **web** build
    /// links in, taken by path outside the package graph. Local development's answer to
    /// `web_plugin_deps`; a directory that is missing is skipped with a note.
    web_plugin_dirs: []const WebPluginDir = &.{},
    windows_msvc_libc_opt: ?[]const u8 = null,
    fetch_msvc_opt: ?bool = null,
    macos_sign_app_identity: ?[]const u8 = null,
    macos_sign_install_identity: ?[]const u8 = null,
    macos_notary_profile: ?[]const u8 = null,
};

pub fn build(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, opts: Options) !void {
    const cfg = try readConfig(b, target, opts);
    try construct(b, target, optimize, opts, cfg);
}

/// Everything `build` reads before it constructs anything — the options, the version, the
/// generated option steps. Split from the construction so a consumer that defers the app
/// (`build.zig`'s `defer-app`) consumes its options now and constructs later, with its own
/// plugins.
pub const Config = struct {
    /// Null on the configure pass that fetches Velopack (see `readConfig`).
    vz: ?velopack.Dep,
    macos_sdl_paths: ?@import("common.zig").MacosSdlPaths,
    zig_out_subdir: []const u8,
    zig_out_install_dir: std.Build.InstallDir,
    target_is_windows_msvc: bool,
    cross_win_msvc: bool,
    effective_win_libc: ?[]const u8,
    velopack_supported_for_target: bool,
    velopack_enabled: bool,
    velopack_required_fail: ?*std.Build.Step,
    no_emit: bool,
    app_version: []const u8,
    build_opts: *std.Build.Step.Options,
    app_name: []const u8,
    app_display_name: []const u8,
    app_bundle_id: []const u8,
    app_config_dir: []const u8,
    app_registry_url: []const u8,
    app_repo_url: []const u8,
    app_repo_url_fallback: []const u8,
    app_layout_path: ?std.Build.LazyPath,
    static_workbench: bool,
    static_text: bool,
    static_image: bool,
    workbench_opts: *std.Build.Step.Options,
    /// Null on the configure pass that fetches Velopack (see `readConfig`).
    msvcup_before_compile: ?*std.Build.Step.Run,
    accesskit: dvui.AccesskitOptions,
    /// What the native executable draws with (`-Dnative-backend`, `build/exe.zig`).
    native_backend: @import("exe.zig").NativeBackend,
    test_filters: []const []const u8,
    macos_sign_app_identity: ?[]const u8,
    macos_sign_install_identity: ?[]const u8,
    macos_notary_profile: ?[]const u8,
    windows_msvc_libc_opt: ?[]const u8,
    fetch_msvc: bool,
    win_libc: velopack.ResolvedWindowsMsvcLibc,
};

/// Phase one of `build`: read every option and set up the option steps.
pub fn readConfig(b: *std.Build, target: std.Build.ResolvedTarget, opts: Options) !Config {
    const windows_msvc_libc_opt = opts.windows_msvc_libc_opt;
    const fetch_msvc_opt = opts.fetch_msvc_opt;
    const macos_sign_app_identity = opts.macos_sign_app_identity;
    const macos_sign_install_identity = opts.macos_sign_install_identity;
    const macos_notary_profile = opts.macos_notary_profile;

    // Resolve Velopack lazily (app-only; plugins depend on `sdk/` which has no Velopack). Null on
    // the first configure pass of a cold cache: Zig fetches it and runs `build` again. That pass
    // configures the app all the same, leaving out only what links Velopack (packaging, the
    // MSVC setup, `-Dvelopack`), which nothing else waits on. Returning early instead left the
    // app unconfigured, and an app built on fizzy (`buildApp`) found no artifact and no options.
    const vz = b.lazyDependency("velopack_zig", .{});

    const common = @import("common.zig");

    // Built-in plugins are embedded by importing their `static/integration.zig` directly
    // (via build/plugins.zig); the root build owns the module graph, so there is no plugin
    // package dependency to resolve here. Their canonical `build.zig` is only for the
    // standalone (`cd plugins/<name> && zig build`) third-party-shape build.

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

    var version_owned: ?[]u8 = null; // lives as long as the build process

    const app_version: []const u8 = if (app_version_opt) |v| v else blk: {
        const raw = b.build_root.handle.readFileAlloc(b.graph.io, "VERSION", b.allocator, std.Io.Limit.limited(256)) catch |e| std.debug.panic("read VERSION: {}", .{e});
        version_owned = raw;
        break :blk std.mem.trimEnd(u8, raw, "\r\n");
    };

    const build_opts = b.addOptions();
    build_opts.addOption([]const u8, "app_version", app_version);

    // Application identity (see app/AppInfo.zig). Options rather than literals so an app built
    // on fizzy as a library can set them; fizzy passes its own values.
    const app_name = b.option([]const u8, "app-name", "Short lowercase app identifier (exe name, packId, config dir)") orelse "fizzy";
    const app_display_name = b.option([]const u8, "app-display-name", "Human-facing application name") orelse "Fizzy";
    const app_bundle_id = b.option([]const u8, "app-bundle-id", "Reverse-DNS application identifier") orelse "com.foxnne.fizzy";
    const app_config_dir = b.option([]const u8, "app-config-dir", "Config directory name (defaults to app-name)") orelse app_name;
    const app_registry_url = b.option([]const u8, "app-registry-url", "Plugin registry catalog URL; empty disables the store") orelse "https://plugins.fizzyed.it/catalog";
    build_opts.addOption([]const u8, "app_name", app_name);
    build_opts.addOption([]const u8, "app_display_name", app_display_name);
    build_opts.addOption([]const u8, "app_bundle_id", app_bundle_id);
    build_opts.addOption([]const u8, "app_config_dir", app_config_dir);
    build_opts.addOption([]const u8, "app_registry_url", app_registry_url);
    build_opts.addOption([]const u8, "app_repo_url", app_repo_url);
    build_opts.addOption([]const u8, "app_repo_url_fallback", app_repo_url_fallback);
    build_opts.addOption(bool, "velopack_enabled", velopack_enabled);

    // A consumer that wants its own shape passes `-Dapp-layout=` (a LazyPath to
    // `pub fn layout(?*anyopaque, *Layout)`). Fizzy itself uses `src/editor/layout.zig`.
    // There is no `-Dlayout=` enum of shipped presets: the shapes are fizzyedit/example-app's.
    const app_layout_path = b.option(std.Build.LazyPath, "app-layout", "App-owned layout file (pub fn layout(?*anyopaque, *Layout))");
    build_opts.addOption(bool, "has_app_layout", app_layout_path != null);
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

    const msvcup_before_compile: ?*std.Build.Step.Run = if (vz) |v| velopack.addMsvcupSetupStep(b, v, ".velopack-msvc") else null;
    const msvcup_setup_step = b.step("msvcup-setup", "Download MSVC SDK into .velopack-msvc/ via velopack-zig (writes zig-libc-*.ini)");
    if (msvcup_before_compile) |m| msvcup_setup_step.dependOn(&m.step);

    const accesskit = b.option(dvui.AccesskitOptions, "accesskit", "Enable accesskit") orelse .off;
    const fizzy_exe = @import("exe.zig");
    const native_backend = b.option(
        fizzy_exe.NativeBackend,
        "native-backend",
        "Native renderer: fizzy (fizzy's own SDL_GPU backend, custom programs) or sdl3 (dvui's SDL_Renderer backend). Default: fizzy",
    ) orelse fizzy_exe.defaultNativeBackend(target);

    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match any filter",
    ) orelse &[0][]const u8{};
    return .{
        .vz = vz,
        .macos_sdl_paths = macos_sdl_paths,
        .zig_out_subdir = zig_out_subdir,
        .zig_out_install_dir = zig_out_install_dir,
        .target_is_windows_msvc = target_is_windows_msvc,
        .cross_win_msvc = cross_win_msvc,
        .effective_win_libc = effective_win_libc,
        .velopack_supported_for_target = velopack_supported_for_target,
        .velopack_enabled = velopack_enabled,
        .velopack_required_fail = velopack_required_fail,
        .no_emit = no_emit,
        .app_version = app_version,
        .build_opts = build_opts,
        .app_name = app_name,
        .app_display_name = app_display_name,
        .app_bundle_id = app_bundle_id,
        .app_config_dir = app_config_dir,
        .app_registry_url = app_registry_url,
        .app_repo_url = app_repo_url,
        .app_repo_url_fallback = app_repo_url_fallback,
        .app_layout_path = app_layout_path,
        .static_workbench = static_workbench,
        .static_text = static_text,
        .static_image = static_image,
        .workbench_opts = workbench_opts,
        .msvcup_before_compile = msvcup_before_compile,
        .accesskit = accesskit,
        .native_backend = native_backend,
        .test_filters = test_filters,
        .macos_sign_app_identity = macos_sign_app_identity,
        .macos_sign_install_identity = macos_sign_install_identity,
        .macos_notary_profile = macos_notary_profile,
        .windows_msvc_libc_opt = windows_msvc_libc_opt,
        .fetch_msvc = fetch_msvc,
        .win_libc = win_libc,
    };
}

/// Phase two of `build`: the executables, the web build, tests, packaging.
pub fn construct(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, opts: Options, cfg: Config) !void {
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
    const vz = cfg.vz;
    const macos_sdl_paths = cfg.macos_sdl_paths;
    const zig_out_subdir = cfg.zig_out_subdir;
    const zig_out_install_dir = cfg.zig_out_install_dir;
    const target_is_windows_msvc = cfg.target_is_windows_msvc;
    const cross_win_msvc = cfg.cross_win_msvc;
    const effective_win_libc = cfg.effective_win_libc;
    const velopack_supported_for_target = cfg.velopack_supported_for_target;
    const velopack_enabled = cfg.velopack_enabled;
    const velopack_required_fail = cfg.velopack_required_fail;
    const no_emit = cfg.no_emit;
    const app_version = cfg.app_version;
    const build_opts = cfg.build_opts;
    const app_name = cfg.app_name;
    const app_display_name = cfg.app_display_name;
    const app_bundle_id = cfg.app_bundle_id;
    const app_config_dir = cfg.app_config_dir;
    const app_registry_url = cfg.app_registry_url;
    const app_repo_url = cfg.app_repo_url;
    const app_repo_url_fallback = cfg.app_repo_url_fallback;
    const app_layout_path = cfg.app_layout_path;
    const static_workbench = cfg.static_workbench;
    const static_text = cfg.static_text;
    const static_image = cfg.static_image;
    const workbench_opts = cfg.workbench_opts;
    const msvcup_before_compile = cfg.msvcup_before_compile;
    const accesskit = cfg.accesskit;
    const native_backend = cfg.native_backend;
    const test_filters = cfg.test_filters;
    const macos_sign_app_identity = cfg.macos_sign_app_identity;
    const macos_sign_install_identity = cfg.macos_sign_install_identity;
    const macos_notary_profile = cfg.macos_notary_profile;
    const windows_msvc_libc_opt = cfg.windows_msvc_libc_opt;
    const fetch_msvc = cfg.fetch_msvc;
    const win_libc = cfg.win_libc;

    const assetpack = @import("assetpack");
    const assets_module = assetpack.pack(b, b.path("assets"), .{});

    // ---------------------------------------------------------------
    // Web (wasm) build — entirely separate from the native exe so it can't disturb
    // packaging / SDL / Velopack paths. `zig build web` produces `zig-out/web/{web.wasm,
    // web.js, index.html, NotoSansKR-Regular.ttf}`, deployable as-is to a static host.
    // ---------------------------------------------------------------

    web.addSteps(b, optimize, build_opts, workbench_opts, assets_module, opts.app_plugins, opts.web_plugin_deps, opts.web_plugin_dirs);

    const main_fizzy = try fizzy_exe.addFizzyExecutableForTarget(b, vz, target, optimize, accesskit, native_backend, build_opts, workbench_opts, assets_module, macos_sdl_paths, velopack_enabled, app_name, app_layout_path, opts.app_plugins);
    const exe = main_fizzy.exe;

    const package_fizzy: FizzyExecutable = package_blk: {
        if (velopack_enabled) break :package_blk main_fizzy;
        if (!velopack_supported_for_target) break :package_blk main_fizzy;
        if (vz == null) break :package_blk main_fizzy;
        const pack_opts = b.addOptions();
        pack_opts.addOption([]const u8, "app_version", app_version);
        // The same identity as `build_opts`: the packaged exe reads them through `AppInfo`
        // like the plain one does, and a missing one only fails a packaging (release) build.
        pack_opts.addOption([]const u8, "app_name", app_name);
        pack_opts.addOption([]const u8, "app_display_name", app_display_name);
        pack_opts.addOption([]const u8, "app_bundle_id", app_bundle_id);
        pack_opts.addOption([]const u8, "app_config_dir", app_config_dir);
        pack_opts.addOption([]const u8, "app_registry_url", app_registry_url);
        pack_opts.addOption([]const u8, "app_repo_url", app_repo_url);
        pack_opts.addOption([]const u8, "app_repo_url_fallback", app_repo_url_fallback);
        pack_opts.addOption(bool, "velopack_enabled", true);
        pack_opts.addOption(bool, "static_workbench", static_workbench);
        pack_opts.addOption(bool, "static_text", static_text);
        pack_opts.addOption(bool, "static_image", static_image);
        pack_opts.addOption(bool, "has_app_layout", app_layout_path != null);
        break :package_blk try fizzy_exe.addFizzyExecutableForTarget(b, vz, target, optimize, accesskit, native_backend, pack_opts, workbench_opts, assets_module, macos_sdl_paths, true, app_name, app_layout_path, opts.app_plugins);
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

    if (vz) |v| _ = package.addSteps(.{
        .b = b,
        .vz = v,
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

    // `zig build test` is the CI entry point and must stay self-contained: pure
    // unit tests only, no dvui/SDL/Velopack/MSVC. Integration tests live under
    // `zig build test-integration` (Velopack + dvui-testing + comctl32 on Windows
    // → needs MSVC SDK on Windows hosts). `zig build test-all` runs both.
    const test_step = b.step("test", "Run fizzy unit tests (pure-logic only, no dvui/SDL/Velopack)");

    // `check` mirrors the split so editor compile-error checking matches CI.
    const check_step = b.step("check", "Compile fizzy unit tests without running them");

    // Zig collects `test` blocks only from files belonging to an artifact's **root
    // module** — a file pulled in as a *named* import (`addImport` /
    // `addAnonymousImport`) is a separate module whose tests are never run. That is
    // how `fizzy-unit-tests` silently ran zero tests behind a green build. So: one
    // `addTest` per pure-logic root, each rooted directly at the file under test.
    // Files reached from such a root by relative `@import` (the registry client's
    // registry/compat/download, say) are part of the same module and *are* collected.
    var unit_test_artifacts: std.ArrayListUnmanaged(*std.Build.Step.Compile) = .empty;

    inline for (.{
        .{ "fizzy-direction-tests", "core/math/direction.zig" },
        .{ "fizzy-easing-tests", "core/math/easing.zig" },
        .{ "fizzy-layout-anchor-tests", "core/math/layout_anchor.zig" },
        .{ "fizzy-plugin-store-tests", "app/store/registry/store.zig" },
        .{ "fizzy-paths-tests", "core/paths.zig" },
        // `core.viz`'s arithmetic: a chart's scale, the slot under the pointer, a bar's fill.
        .{ "fizzy-viz-scale-tests", "core/viz/scale.zig" },
        // The login-shell PATH cache: it owns its string whatever allocator the first caller
        // passed, and threads that ask at once resolve once. The shell spawn itself is not run.
        .{ "fizzy-shell-env-tests", "core/shell_env.zig" },
        // The credential store behind `Host.secrets`: a 0600 file, keyed, round-tripped.
        .{ "fizzy-secrets-tests", "app/Secrets.zig" },
        .{ "fizzy-lsp-protocol-tests", "core/lsp/Protocol.zig" },
        .{ "fizzy-lsp-uri-tests", "core/lsp/UriUtil.zig" },
        .{ "fizzy-settings-plugins-zon-tests", "app/settings/SettingsPluginsZon.zig" },
        // std-only despite living under sdk/src/ — and the SDK-rooted test artifact
        // below never reaches it (nothing in the graph forces `sdk.Manifest`), so it
        // needs its own root either way.
        .{ "fizzy-sdk-manifest-tests", "sdk/src/Manifest.zig" },
        // The `[[wikilink]]` tokenizer. std-only on purpose: it's shared verbatim by the
        // markdown renderer and by out-of-tree indexers, so it must not depend on dvui or
        // anything else the SDK-rooted artifact drags in.
        .{ "fizzy-sdk-wikilink-tests", "sdk/src/services/wikilink.zig" },
        // The text plugin's headless editing model. Lives under plugins/ but is
        // deliberately dvui-free (see textcore.zig), so it tests as pure logic from the
        // app build. One root covers every file below it — they're relative imports.
        .{ "fizzy-textcore-tests", "plugins/text/src/textcore/textcore.zig" },
        // A text document's state as bytes, for a demo's snapshot. std-only (see doc_state.zig).
        .{ "fizzy-text-doc-state-tests", "plugins/text/src/doc_state.zig" },
        // Profiles: taking `--profile` out of argv, and each profile's own lock name. std-only;
        // where a profile's folders go is `single_instance` and the editor's, run by hand.
        .{ "fizzy-profile-tests", "app/profile.zig" },
        // `<img>` scanning for the markdown preview's raw-HTML blocks. Under plugins/
        // but std-only by design (see html_images.zig), so it tests from the app build.
        .{ "fizzy-md-html-images-tests", "plugins/markdown/src/md/html_images.zig" },
        // Resolving a fetched README's relative image paths against its source URL. std-only,
        // same reasoning as html_images above.
        .{ "fizzy-md-url-join-tests", "plugins/markdown/src/md/url_join.zig" },
        // Sniffing image bytes stb can't decode (SVG badges), so the preview never re-enters
        // stbi for them every frame. std-only, same reasoning as the two above.
        .{ "fizzy-md-image-format-tests", "plugins/markdown/src/md/image_format.zig" },
        // The markdown preview's block height table — placement, height trust, and the
        // never-blank visible-range guarantee. std-only by design (see block_heights.zig) so
        // the rules the preview's scroll stability rests on are testable without a Window.
        .{ "fizzy-md-block-heights-tests", "plugins/markdown/src/md/block_heights.zig" },
        // Fence language tag → file extension, which is the whole of what the markdown plugin
        // knows about languages: the grammar itself comes from whichever plugin claims that
        // extension. std-only, so the table is testable without a Window.
        .{ "fizzy-md-code-language-tests", "plugins/markdown/src/md/code_language.zig" },
        // Zine's SuperMD rewritten into the markdown it reads as, line for line. std-only, so
        // the rewrite is testable without a Window.
        .{ "fizzy-md-supermd-tests", "plugins/markdown/src/md/supermd.zig" },
        // Content-swap reveal phase machine. std-only by design (see reveal.zig) — the dvui
        // half is the thin wrapper in core/dvui.zig.
        .{ "fizzy-reveal-tests", "core/reveal.zig" },
        // Fade / blur-fade timeline. std-only (see crossfade.zig) — pictures and the clock
        // live in core/anim.zig.
        .{ "fizzy-crossfade-tests", "core/crossfade.zig" },
        // A motion's clock stepped by its frames, a long one held to a step. std-only (see
        // FrameClock.zig); the floats' landing and ghost run on it.
        .{ "fizzy-frame-clock-tests", "core/FrameClock.zig" },
        // Ring buffering and dot-segment filtering for the folder watcher. std-only so it can
        // be tested here; FolderWatcher.zig itself needs a live editor.
        .{ "fizzy-folder-events-tests", "app/watch/folder_events.zig" },
        // The command palette's recently used commands: order, re-use, the cap. std-only
        // (see RecentCommands.zig); `Recents` holds it and stores it in recents.zon.
        .{ "fizzy-recent-commands-tests", "app/RecentCommands.zig" },
        // Where a floating view's window opens, what keeps it reachable, its name, the floats'
        // stacking and where a closed float's views go. std-only (see float_rules.zig);
        // `Floats.zig` and `ViewDrag.zig` apply it, covered by `tests/integration.zig`.
        .{ "fizzy-float-rules-tests", "app/layout/float_rules.zig" },
        // One material on two sliders: what every glass is at the window's opacity and roughness,
        // the OS's form and the app's. std-only (see glass_look.zig); `LiquidField` and `Popout`
        // apply it.
        .{ "fizzy-glass-look-tests", "core/gfx/glass_look.zig" },
        // Demo automation's std-only core (`sdk/tape/`): the tape format and its codecs, the
        // sequencer that replays it deterministically, the script builder and key spelling. The
        // dvui half (`sdk/replay/`) compiles on its own below, and is covered by
        // `tests/integration.zig`.
        .{ "fizzy-tape-tests", "sdk/tape/root.zig" },
    }) |entry| {
        try unit_test_artifacts.append(b.allocator, b.addTest(.{
            .name = entry[0],
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .root_source_file = b.path(entry[1]),
            }),
            .filters = test_filters,
        }));
    }
    // The backend package's std-only tests (window layout, the title-bar hit test, the blur
    // region, the viewport map, the health counters), from its own list, so `zig build test`
    // here still runs them.
    const backend_dep = fizzy_exe.backendDependency(b);
    for (@import("fizzy_backend").unit_tests) |t| {
        try unit_test_artifacts.append(b.allocator, b.addTest(.{
            .name = t.name,
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .root_source_file = backend_dep.path(t.root),
            }),
            .filters = test_filters,
        }));
    }

    // The single-instance listener (`libs/dvui-singleton-app`): its shutdown wakes the thread
    // waiting in `accept`, which closing the socket does not on Linux. It talks to its socket
    // through libc.
    try unit_test_artifacts.append(b.allocator, b.addTest(.{
        .name = "fizzy-singleton-unix-tests",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("libs/dvui-singleton-app/src/unix_impl.zig"),
            .link_libc = true,
        }),
        .filters = test_filters,
    }));

    // Crash reports: the report's text, and the image (range, build id) holding an address.
    // std-only; it reads images and writes the report through libc.
    try unit_test_artifacts.append(b.allocator, b.addTest(.{
        .name = "fizzy-crash-tests",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("app/crash/crash.zig"),
            .link_libc = true,
        }),
        .filters = test_filters,
    }));

    // Keybinding parse/resolve core. Deliberately dvui-free (see Keymap.zig) — dvui's keybind map
    // can't express chords and is keyed by bind name, not command. Its key spelling is `tape`'s
    // (`sdk/tape/chord.zig`), the one dependency it has.
    {
        const keymap_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("app/keymap/Keymap.zig"),
        });
        keymap_module.addImport("tape", b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("sdk/tape/root.zig"),
        }));
        try unit_test_artifacts.append(b.allocator, b.addTest(.{
            .name = "fizzy-keymap-tests",
            .root_module = keymap_module,
            .filters = test_filters,
        }));
    }

    // `core.fuzzy` is pure logic too, but wraps zf — wire that single dependency
    // rather than dragging in all of `core`, which would pull in dvui.
    {
        const fuzzy_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("core/fuzzy.zig"),
        });
        fuzzy_module.addImport("zf", core_mod.zfModule(b, target, optimize));
        try unit_test_artifacts.append(b.allocator, b.addTest(.{
            .name = "fizzy-fuzzy-tests",
            .root_module = fuzzy_module,
            .filters = test_filters,
        }));
    }

    // `core.FileTable` — the shared project file set. Reaches `fuzzy.zig` by relative import so
    // it needs zf too, and nothing else: it takes its `std.Io` from the host rather than reading
    // `dvui.io`, precisely so the listing cache and the ranking are testable against a real
    // directory here instead of only under a running app.
    {
        const file_table_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("core/FileTable.zig"),
        });
        file_table_module.addImport("zf", core_mod.zfModule(b, target, optimize));
        try unit_test_artifacts.append(b.allocator, b.addTest(.{
            .name = "fizzy-file-table-tests",
            .root_module = file_table_module,
            .filters = test_filters,
        }));
    }

    // `core.transport.Native` — `std.http.Client` on a thread, tested against a loopback
    // `std.http.Server` — and the `core.vfs` contract's own tests (`Mem`, zip). No dvui.
    {
        const transport_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("core/transport_tests.zig"),
        });
        try unit_test_artifacts.append(b.allocator, b.addTest(.{
            .name = "fizzy-native-transport-tests",
            .root_module = transport_module,
            .filters = test_filters,
        }));
    }

    // `core.work`: a stepped task run both ways. No dvui, no Io.
    {
        const work_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("core/work.zig"),
        });
        try unit_test_artifacts.append(b.allocator, b.addTest(.{
            .name = "fizzy-work-tests",
            .root_module = work_module,
            .filters = test_filters,
        }));
    }

    for (unit_test_artifacts.items) |unit_test| {
        test_step.dependOn(&b.addRunArtifact(unit_test).step);
        check_step.dependOn(&unit_test.step);
    }

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

    const dvui_testing_dep = sdk.dvuiDependency(b, .{
        .target = target,
        .optimize = optimize,
        .backend = .testing,
        .accesskit = accesskit,
    });
    const dvui_test_proxy_bridge = sdk.addProxyBridgeModule(b, target, optimize, dvui_testing_dep, dvui_testing_dep.module("dvui_testing"));

    // Build a module rooted at `src/fizzy.zig` carrying all the same
    // imports the production exe carries. Because fizzy.zig's transitive
    // imports (Entry.zig, Editor.zig, …) reference `dvui`, `assets`, etc. by
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
    // The testing backend has no viewports (`backend_web.viewports`).
    fizzy_test_module.addImport("viewports_none", @import("fizzy_backend").viewportsNoneModule(fizzy_exe.backendDependency(b), dvui_testing_dep.module("dvui_testing")));
    fizzy_test_module.addImport("assets", assets_module);
    fizzy_test_module.addImport("build_opts", sdk.buildOptsModule(build_opts));

    // Shared `core` module for the test build (dvui testing backend variant).
    const core_module_test = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("core/core.zig"),
    });
    const icons_test = core_mod.addImports(b, core_module_test, dvui_testing_dep.module("dvui_testing"), b.dependency("fizzy_sdk", .{}).builder, target, optimize);
    fizzy_test_module.addImport("core", core_module_test);
    if (icons_test) |icons| fizzy_test_module.addImport("icons", icons);

    // `replay` (`sdk/replay/`) on its own: dvui and `tape`, nothing of fizzy's. A reach into
    // `core` or `app` fails to compile here, which is what keeps it a library any dvui app can
    // take (`plans/AUTOMATION_PLAN.md`, "The libraries").
    {
        const replay_only = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("sdk/replay/root.zig"),
        });
        replay_only.addImport("dvui", dvui_testing_dep.module("dvui_testing"));
        replay_only.addImport("tape", b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("sdk/tape/root.zig"),
        }));
        const replay_tests = b.addTest(.{
            .name = "fizzy-replay-tests",
            .root_module = replay_only,
            .filters = test_filters,
        });
        test_integration_step.dependOn(&b.addRunArtifact(replay_tests).step);
        check_integration_step.dependOn(&replay_tests.step);
    }
    // The native backend's health counters as SDL feeds them: its log counted, and passed on to
    // the output it had. Needs SDL, no window.
    if (main_fizzy.backend) |native_backend_module| {
        const health_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("tests/backend_health.zig"),
        });
        health_module.addImport("backend", native_backend_module);
        const health_tests = b.addTest(.{
            .name = "fizzy-backend-health-sdl-tests",
            .root_module = health_module,
            .filters = test_filters,
        });
        test_integration_step.dependOn(&b.addRunArtifact(health_tests).step);
        check_integration_step.dependOn(&health_tests.step);
    }
    // See `exe.zig` for why macOS needs the FSEvents backend.
    const nightwatch_test_dep = if (target.result.os.tag == .macos)
        b.lazyDependency("nightwatch", .{ .target = target, .optimize = optimize, .macos_fsevents = true })
    else
        b.lazyDependency("nightwatch", .{ .target = target, .optimize = optimize });
    if (nightwatch_test_dep) |dep| {
        fizzy_test_module.addImport("nightwatch", dep.module("nightwatch"));
    }

    const sdk_module_test = sdk.wireSdkModule(b, target, optimize, dvui_testing_dep.module("dvui_testing"), dvui_test_proxy_bridge, core_module_test, fizzy_test_module);
    const workbench_module_test = workbench_plugin.addStaticModule(b, target, optimize, .{
        .dvui = dvui_testing_dep.module("dvui_testing"),
        .core = core_module_test,
        .sdk = sdk_module_test,
        .icons = icons_test,
        .backend = dvui_testing_dep.module("testing"),
    }, workbench_opts, fizzy_test_module);
    const text_module_test = text_plugin.addStaticModule(b, target, optimize, .{
        .dvui = dvui_testing_dep.module("dvui_testing"),
        .core = core_module_test,
        .sdk = sdk_module_test,
        .icons = icons_test,
    }, fizzy_test_module);
    const markdown_module_test = plugins.markdown.addStaticModule(b, target, optimize, .{
        .dvui = dvui_testing_dep.module("dvui_testing"),
        .core = core_module_test,
        .sdk = sdk_module_test,
    }, fizzy_test_module);
    // The `app` framework module (the plugin store), wired the same way the exe and the web
    // build wire it — see `build/sdk.zig`.
    // The single-instance backend too, so its argv and profile handling are tested where the exe
    // is not built (`tests/integration.zig`, "profile").
    const singleton_test_dep = b.dependency("dvui_singleton_app", .{ .target = target, .optimize = optimize });
    const app_module_test = sdk.wireAppModule(b, target, optimize, dvui_testing_dep.module("dvui_testing"), core_module_test, sdk_module_test, icons_test, markdown_module_test, if (nightwatch_test_dep) |dep| dep.module("nightwatch") else null, build_opts, singleton_test_dep.module("singleton_app"), fizzy_test_module);
    const image_module_test = image_plugin.addStaticModule(b, target, optimize, .{
        .dvui = dvui_testing_dep.module("dvui_testing"),
        .core = core_module_test,
        .sdk = sdk_module_test,
    }, fizzy_test_module);
    // What the test build bundles, as the exe's does (`build/exe.zig`), so a test can bring up
    // the whole editor — `Editor.postInit` registers whatever is listed here.
    fizzy_test_module.addImport("bundled_plugins", sdk.bundledPluginsModule(b, target, optimize, &.{
        .{ .name = "workbench", .module = workbench_module_test },
        .{ .name = "text", .module = text_module_test },
        .{ .name = "image", .module = image_module_test },
        .{ .name = "markdown", .module = markdown_module_test },
    }));

    if (target.result.os.tag == .macos) {
        if (@import("fizzy_backend").objcModule(fizzy_exe.backendDependency(b), fizzy_exe.backendOptions(target, optimize, macos_sdl_paths))) |objc| {
            fizzy_test_module.addImport("objc", objc);
        }
    } else if (target.result.os.tag == .windows) {
        if (@import("fizzy_backend").win32Module(fizzy_exe.backendDependency(b))) |win32| {
            fizzy_test_module.addImport("win32", win32);
        }
    }

    const integration_module = b.addModule("fizzy-integration-tests", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("tests/integration.zig"),
    });
    integration_module.addImport("fizzy", fizzy_test_module);
    integration_module.addImport("dvui", dvui_testing_dep.module("dvui_testing"));

    // The endless shape (fizzyedit/example-app's `shapes/endless.zig`, copied here as a test
    // fixture) — not a shipped preset. Tests drive it the way a consumer would: as a file that
    // imports `app` / `dvui` / `core`.
    const endless_layout_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("tests/shapes/endless.zig"),
    });
    endless_layout_mod.addImport("dvui", dvui_testing_dep.module("dvui_testing"));
    endless_layout_mod.addImport("app", app_module_test);
    endless_layout_mod.addImport("core", core_module_test);
    endless_layout_mod.addImport("fizzy_sdk", sdk_module_test);
    integration_module.addImport("endless_layout", endless_layout_mod);

    // The text plugin itself, so integration tests can drive its `TextEntryWidget` directly in
    // a headless window. Its editing behavior splits in two: the *decisions* live in dvui-free
    // `textcore/` and are unit-tested there, but applying them (buffer memmoves + selection
    // arithmetic against a live `TextLayoutWidget`) only exists inside the widget, and that
    // half needs real frames and real key/text events to exercise. Reuses the module already
    // built above rather than rooting a second one at the widget — a file may belong to only
    // one module per compilation, and the plugin's own module already owns it.
    integration_module.addImport("text", text_module_test);
    // Same reasoning for the markdown preview: its block virtualization is a claim about what
    // gets *drawn*, which only a real headless frame can check.
    integration_module.addImport("markdown", markdown_module_test);
    // And the workbench's panes: whether a float lies over one is a reading of the window's
    // subwindows, which a headless frame with a float in it has.
    integration_module.addImport("workbench", workbench_module_test);
    integration_module.addAnonymousImport("markdown_sample", .{ .root_source_file = b.path("docs/PLUGINS.md") });
    // The synthetic document with the 48KB table of wrapping cells — the case table-row culling
    // exists for, and the one it could get wrong. Generated by `markdown_sample_tables.py` beside it.
    integration_module.addAnonymousImport("markdown_sample_tables", .{ .root_source_file = b.path("tests/data/markdown_sample_tables.md") });
    // The image-heavy fixture. Both docs above are prose and tables, so without this no test ever
    // laid out an image block — the one block kind whose height nothing in the source predicts
    // and which rescales with the pane right up until the pane is wider than the image.
    integration_module.addAnonymousImport("markdown_sample_images", .{ .root_source_file = b.path("tests/data/markdown_sample_images.md") });
    // A real tree-sitter grammar + queries, so the markdown code-fence highlighting path can be
    // executed rather than only compiled. The grammar itself is already linked into this binary
    // through the text module; the queries come from dvui's examples rather than a vendored copy,
    // exactly as `bench-text` takes them. In the app these arrive from the external `zig`
    // language plugin — what is under test is markdown's use of whatever the host hands back.
    integration_module.addAnonymousImport("ts_zig_queries", .{
        .root_source_file = dvui_testing_dep.path("src/Examples/tree_sitter_zig_queries.scm"),
    });
    integration_module.addImport("fizzy_sdk", sdk_module_test);
    // The framework itself, for what is tested against a bare window rather than through fizzy
    // (demo automation's player).
    integration_module.addImport("app", app_module_test);
    // The hand-written sample tape `docs/AUTOMATION.md` points at, so it cannot rot.
    integration_module.addAnonymousImport("demo_sample_tape", .{ .root_source_file = b.path("docs/demos/hello.zon") });
    integration_module.addAnonymousImport("soak_tape", .{ .root_source_file = b.path("tests/tapes/soak.zon") });
    integration_module.addAnonymousImport("soak_expect", .{ .root_source_file = b.path("tests/tapes/soak.expect.zon") });

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
    if (velopack_enabled) if (vz) |v| {
        try velopack.linkVelopack(b, v, integration_tests, .{ .target = target, .optimize = optimize });
    };

    test_integration_step.dependOn(&b.addRunArtifact(integration_tests).step);
    check_integration_step.dependOn(&integration_tests.step);

    // Every bundled demo played through fizzy's own stage in the whole editor (`tests/demos.zig`).
    // A process of its own: the editor going down leaves module state behind in the plugins it
    // links, so one process brings the whole editor up once, and `tests/integration.zig` already
    // does ("headless: …").
    {
        const demos_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("tests/demos.zig"),
        });
        demos_module.addImport("fizzy", fizzy_test_module);
        demos_module.addImport("dvui", dvui_testing_dep.module("dvui_testing"));
        demos_module.addImport("app", app_module_test);
        demos_module.addImport("workbench", workbench_module_test);
        const demo_tests = b.addTest(.{
            .name = "fizzy-demo-tests",
            .root_module = demos_module,
            .filters = test_filters,
        });
        if (target.result.os.tag == .windows) demo_tests.root_module.linkSystemLibrary("comctl32", .{});
        demo_tests.root_module.link_libcpp = !target_is_windows_msvc;
        if (velopack_enabled) if (vz) |v| {
            try velopack.linkVelopack(b, v, demo_tests, .{ .target = target, .optimize = optimize });
        };
        test_integration_step.dependOn(&b.addRunArtifact(demo_tests).step);
        check_integration_step.dependOn(&demo_tests.step);
    }

    // The `app` framework module's own tests — the split trees, seeds, drop plans and view drag
    // under `app/layout/` (`Layout.zig`'s `test` block). `addTest` collects from its root module
    // only, so the integration tests above, which import `app`, never ran them. Against dvui's
    // testing backend, as the module those tests import is wired.
    const app_tests = b.addTest(.{
        .name = "fizzy-app-tests",
        .root_module = app_module_test,
        .filters = test_filters,
    });
    if (target.result.os.tag == .windows) app_tests.root_module.linkSystemLibrary("comctl32", .{});
    app_tests.root_module.link_libcpp = !target_is_windows_msvc;
    test_integration_step.dependOn(&b.addRunArtifact(app_tests).step);
    check_integration_step.dependOn(&app_tests.step);

    // `zig build bench-text` — text editor frame-cost benchmark. Its own step, never wired into
    // `test`/`test-all`: it prints timings instead of asserting, and the numbers are
    // machine-dependent. Same headless harness as the integration tests, so it measures the
    // real widget rather than a model of it. Compare runs only at equal `-Doptimize` — the C
    // libraries inside dvui build at the app's optimize level (see the file's doc comment).
    {
        const bench_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("tests/bench/bench_text.zig"),
        });
        bench_module.addImport("dvui", dvui_testing_dep.module("dvui_testing"));
        bench_module.addImport("text", text_module_test);
        // The tree-sitter Zig queries the benchmark highlights with, taken from dvui's examples
        // instead of vendoring a copy into the repo. The real editor gets its queries from the
        // external `zig` language plugin; what the benchmark times (query + per-capture chunk
        // emission) doesn't depend on which of the two supplied them.
        bench_module.addAnonymousImport("ts_zig_queries", .{
            .root_source_file = dvui_testing_dep.path("src/Examples/tree_sitter_zig_queries.scm"),
        });
        // The documents it benchmarks are this repo's own sources — `@embedFile` can't reach
        // outside its package, so they arrive the same way.
        bench_module.addAnonymousImport("sample_large", .{ .root_source_file = b.path("src/editor/Editor.zig") });
        bench_module.addAnonymousImport("sample_small", .{ .root_source_file = b.path("src/Entry.zig") });

        const bench_text = b.addTest(.{ .name = "fizzy-bench-text", .root_module = bench_module });
        bench_text.root_module.link_libcpp = !target_is_windows_msvc;
        if (target.result.os.tag == .windows) {
            bench_text.root_module.linkSystemLibrary("comctl32", .{});
        }

        const bench_step = b.step("bench-text", "Benchmark the text editor's per-frame draw cost (prints timings)");
        const run_bench = b.addRunArtifact(bench_text);
        // Timings are the output — never serve a cached result, and don't let a parallel build
        // step's CPU contention skew them.
        run_bench.has_side_effects = true;
        bench_step.dependOn(&run_bench.step);
    }

    // `zig build bench-markdown` — markdown preview frame-cost benchmark. Same rules as
    // `bench-text` above: its own step, prints timings instead of asserting, only comparable at
    // equal `-Doptimize` (md4c and freetype build at the app's optimize level).
    {
        const bench_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("tests/bench/bench_markdown.zig"),
        });
        bench_module.addImport("dvui", dvui_testing_dep.module("dvui_testing"));
        bench_module.addImport("markdown", markdown_module_test);
        // This repo's own docs, as anonymous imports rather than checked-in fixtures — the same
        // reasoning as `bench-text`'s samples. `PLUGINS.md` is the document that prompted the
        // benchmark.
        bench_module.addAnonymousImport("sample_huge", .{ .root_source_file = b.path("docs/PLUGINS.md") });
        bench_module.addAnonymousImport("sample_prose", .{ .root_source_file = b.path("tests/data/markdown_sample_tables.md") });
        bench_module.addAnonymousImport("sample_medium", .{ .root_source_file = b.path("CLAUDE.md") });
        bench_module.addAnonymousImport("sample_small", .{ .root_source_file = b.path("docs/MODULARIZATION_RELEASE_NOTES.md") });

        const bench_markdown = b.addTest(.{ .name = "fizzy-bench-markdown", .root_module = bench_module });
        bench_markdown.root_module.link_libcpp = !target_is_windows_msvc;
        if (target.result.os.tag == .windows) {
            bench_markdown.root_module.linkSystemLibrary("comctl32", .{});
        }

        const bench_step = b.step("bench-markdown", "Benchmark the markdown preview's per-frame draw cost (prints timings)");
        const run_bench = b.addRunArtifact(bench_markdown);
        run_bench.has_side_effects = true;
        bench_step.dependOn(&run_bench.step);
    }

    // `zig build bench-replay` — what a demo seek costs: the player replaying a recording-shaped
    // tape over the text editor's widget, silently (`Player.frames`) and a displayed frame at a
    // time as it used to. Same rules and harness as `bench-text`.
    {
        const bench_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("tests/bench/bench_replay.zig"),
        });
        bench_module.addImport("dvui", dvui_testing_dep.module("dvui_testing"));
        bench_module.addImport("text", text_module_test);
        bench_module.addImport("app", app_module_test);
        bench_module.addAnonymousImport("sample", .{ .root_source_file = b.path("src/Entry.zig") });

        const bench_replay = b.addTest(.{ .name = "fizzy-bench-replay", .root_module = bench_module });
        bench_replay.root_module.link_libcpp = !target_is_windows_msvc;
        if (target.result.os.tag == .windows) {
            bench_replay.root_module.linkSystemLibrary("comctl32", .{});
        }
        if (velopack_enabled) if (vz) |v| {
            try velopack.linkVelopack(b, v, bench_replay, .{ .target = target, .optimize = optimize });
        };

        const check_bench_replay_step = b.step("check-bench-replay", "Compile fizzy bench-replay without running it");
        check_bench_replay_step.dependOn(&bench_replay.step);

        const bench_step = b.step("bench-replay", "Benchmark a demo seek, silent against shown frame by frame (prints timings)");
        const run_bench = b.addRunArtifact(bench_replay);
        run_bench.has_side_effects = true;
        bench_step.dependOn(&run_bench.step);
    }

    // `zig build bench-tape` — saving and loading a tape, ZON against the binary form, at the
    // sizes of a demo, a recording and a long session. Same rules as `bench-text`; std-only, so
    // it needs no window and builds in seconds.
    {
        const bench_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("tests/bench/bench_tape.zig"),
        });
        bench_module.addImport("tape", b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("sdk/tape/root.zig"),
        }));
        const bench_tape = b.addTest(.{ .name = "fizzy-bench-tape", .root_module = bench_module });

        const bench_step = b.step("bench-tape", "Benchmark saving and loading demo tapes, ZON against binary (prints timings)");
        const run_bench = b.addRunArtifact(bench_tape);
        run_bench.has_side_effects = true;
        bench_step.dependOn(&run_bench.step);
    }

    // Pure-logic tests that nevertheless sit in a file importing `dvui` (or the SDK)
    // can't join the unit layer, so they get their own roots here. Rooting at
    // `sdk/src/sdk.zig` collects every SDK file reachable from it by relative
    // import *and actually referenced* — dylib.zig, fingerprint.zig, settings.zig,
    // version.zig, Host.zig. A file only reached through an unreferenced `pub const
    // x = @import(…)` in sdk.zig is analyzed lazily and its tests never run (that is
    // why Manifest.zig has its own root in the unit list above); when adding tests
    // to a new SDK file, check the reported test count actually went up.
    {
        const sdk_tests_module = sdk.wireSdkModule(b, target, optimize, dvui_testing_dep.module("dvui_testing"), dvui_test_proxy_bridge, core_module_test, null);
        const plugin_loader_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("app/store/PluginLoader.zig"),
        });
        plugin_loader_module.addImport("dvui", dvui_testing_dep.module("dvui_testing"));
        plugin_loader_module.addImport("fizzy_sdk", sdk_module_test);
        plugin_loader_module.addImport("crash", sdk.crashModule(b, target, optimize));

        // How big a pane is: the split's drag, capture handoff and hit distance, and the pane
        // row's shares. Both need a real Window — every bug either has had was a dvui
        // event-routing or layout-settle rule, and those do not reproduce on paper. See
        // `core/sizing_tests.zig` for why the root sits a directory above them.
        const split_tests_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("core/sizing_tests.zig"),
        });
        split_tests_module.addImport("dvui", dvui_testing_dep.module("dvui_testing"));
        if (icons_test) |icons| split_tests_module.addImport("icons", icons);
        // `core/widgets.zig` names widgets through `replay`'s anchors; the test `core`'s own.
        split_tests_module.addImport("replay", core_module_test.import_table.get("replay").?);

        inline for (.{
            .{ "fizzy-sdk-tests", sdk_tests_module },
            .{ "fizzy-sizing-tests", split_tests_module },
            .{ "fizzy-plugin-loader-tests", plugin_loader_module },
        }) |entry| {
            const t = b.addTest(.{
                .name = entry[0],
                .root_module = entry[1],
                .filters = test_filters,
            });
            test_integration_step.dependOn(&b.addRunArtifact(t).step);
            check_integration_step.dependOn(&t.step);
            if (win_libc.needs_setup) if (msvcup_before_compile) |m| t.step.dependOn(&m.step);
        }
    }

    if (win_libc.needs_setup) if (msvcup_before_compile) |msvcup| {
        exe.step.dependOn(&msvcup.step);
        if (!velopack_enabled and velopack_supported_for_target) {
            exe_for_package.step.dependOn(&msvcup.step);
        }
        integration_tests.step.dependOn(&msvcup.step);
        for (unit_test_artifacts.items) |unit_test| unit_test.step.dependOn(&msvcup.step);
        inline for (.{ main_fizzy, package_fizzy }) |fizzy_exe_result| {
            if (fizzy_exe_result.workbench_dylib) |dylib| dylib.step.dependOn(&msvcup.step);
            if (fizzy_exe_result.text_dylib) |dylib| dylib.step.dependOn(&msvcup.step);
            if (fizzy_exe_result.markdown_dylib) |dylib| dylib.step.dependOn(&msvcup.step);
            if (fizzy_exe_result.image_dylib) |dylib| dylib.step.dependOn(&msvcup.step);
        }
    };

    if (target.result.os.tag == .windows and target.result.abi == .msvc) {
        var roots: [12]*std.Build.Step.Compile = undefined;
        var n: usize = 0;
        roots[n] = exe;
        n += 1;
        // The pure-logic unit tests are std-only (no C, hence no translate-c step
        // to fix up), so only the integration side needs the MSVC shim here.
        roots[n] = integration_tests;
        n += 1;
        if (!velopack_enabled and velopack_supported_for_target) {
            roots[n] = exe_for_package;
            n += 1;
        }
        // Built-in plugin dylibs (workbench/text/markdown/image) compile against a
        // `backend = .proxy` dvui dependency — a translate-c step distinct from the
        // app exe's `sdl3`-backend one above — so they need the same MSVC fixup
        // applied separately. `main_fizzy` and `package_fizzy` may share dylib
        // pointers (see `package_blk` above); `applyMsvcTranslateCShim` /
        // `applyMsvcIncludesToReachableTranslateC` dedup reachable TranslateC steps
        // via their own `seen` set, so passing the same root twice is harmless.
        inline for (.{ main_fizzy, package_fizzy }) |fizzy_exe_result| {
            if (fizzy_exe_result.workbench_dylib) |dylib| {
                roots[n] = dylib;
                n += 1;
            }
            if (fizzy_exe_result.text_dylib) |dylib| {
                roots[n] = dylib;
                n += 1;
            }
            if (fizzy_exe_result.markdown_dylib) |dylib| {
                roots[n] = dylib;
                n += 1;
            }
            if (fizzy_exe_result.image_dylib) |dylib| {
                roots[n] = dylib;
                n += 1;
            }
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
