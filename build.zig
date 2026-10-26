const std = @import("std");

/// App-side re-export of the plugin build API (lives in `sdk/`). Plugins should depend on
/// the `sdk/` package directly — see AGENTS.md — not this root package.
///
/// Reached through the dependency rather than by path (`sdk/plugin_sdk.zig`): the app consumes
/// `sdk/` as a package so the two can share one dvui pin, and a file may belong to only one module,
/// so claiming these for the root's build module would make that impossible.
pub const plugin = @import("fizzy_sdk").plugin;

pub fn build(b: *std.Build) !void {
    const lint = b.addExecutable(.{
        .name = "fizzy-lint",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/lint.zig"),
            .target = b.graph.host,
        }),
    });
    const run_lint = b.addRunArtifact(lint);
    if (b.option(bool, "lint-verbose", "Print all lint findings") orelse false)
        run_lint.addArg("--verbose");
    run_lint.setCwd(b.path("."));
    run_lint.has_side_effects = true;
    b.step("lint", "Check Zig source against lint budgets").dependOn(&run_lint.step);

    const windows_msvc_libc_opt = b.option(
        []const u8,
        "windows-msvc-libc",
        "zig libc manifest for *-windows-msvc when cross-compiling; forwarded by " ++
            "packageall for Windows children",
    ) orelse null;
    const fetch_msvc_opt = b.option(
        bool,
        "fetch-msvc",
        "If *-windows-msvc libc is missing under .velopack-msvc/, run msvcup-setup " ++
            "first (downloads MSVC+SDK; requires network). Defaults to true on Windows " ++
            "hosts targeting *-windows-msvc.",
    ) orelse null;

    // Options only, never the environment: Zig 0.17 caches the build's configuration without
    // regard to it, so a variable read here would be seen once and then ignored.
    // `scripts/release.sh` and `release.yml` turn the FIZZY_MACOS_* variables into these.
    const macos_sign_app_identity = b.option(
        []const u8,
        "macos-sign-app",
        "macOS codesign identity for the app bundle (e.g. 'Developer ID " ++
            "Application: NAME (TEAMID)')",
    );
    const macos_sign_install_identity = b.option(
        []const u8,
        "macos-sign-installer",
        "macOS codesign identity for the installer pkg (e.g. 'Developer ID " ++
            "Installer: NAME (TEAMID)')",
    );
    const macos_notary_profile = b.option(
        []const u8,
        "macos-notary-profile",
        "notarytool keychain profile name (run `xcrun notarytool store-credentials " ++
            "<name>` first)",
    );
    const macos_sdk = b.option(
        []const u8,
        "macos-sdk",
        "macOS SDK path for an explicit -Dtarget=*-macos (default: `xcrun --sdk " ++
            "macosx --show-sdk-path`)",
    );

    // Windows 10 1803 at least: AF_UNIX arrived there, and std offers it only to a target whose
    // minimum is that (`std.Io.net.has_unix_sockets`) — the control server's socket
    // (`app/control/Server.zig`). Every Windows still supported by Microsoft is newer.
    const target = target: {
        const asked = b.standardTargetOptions(.{});
        if (asked.result.os.tag != .windows or
            asked.result.os.isAtLeast(.windows, .win10_rs4) == true) break :target asked;
        if (asked.result.os.version_range.windows.max.isAtLeast(.win10_rs4) != true)
            std.debug.panic("fizzy needs Windows 10 1803 (win10_rs4) or newer; -Dtarget asks for an older range", .{});
        var query = asked.query;
        query.os_version_min = .{ .windows = .win10_rs4 };
        break :target b.resolveTargetQuery(query);
    };
    const optimize = b.standardOptimizeOption(.{});

    const base: @import("build/app.zig").Options = .{
        .windows_msvc_libc_opt = windows_msvc_libc_opt,
        .fetch_msvc_opt = fetch_msvc_opt,
        .macos_sign_app_identity = macos_sign_app_identity,
        .macos_sign_install_identity = macos_sign_install_identity,
        .macos_notary_profile = macos_notary_profile,
        .macos_sdk = macos_sdk,
        // What fizzy-the-app ships in its web build beyond the built-ins. The browser cannot
        // load a plugin at runtime, so this is the one place a third-party plugin is named
        // in this repo — as build data, the way an app built on fizzy lists its own. By
        // directory while the plugin is a sibling checkout (see `Options.web_plugin_dirs`);
        // by URL-pinned dependency (`web_plugin_deps`) once it is published.
        // Empty on purpose: web plugins load at runtime as side modules (`?plugin=<id>`, and
        // the store). A checkout can still be bundled statically here while developing it —
        // `.{ .dir = "../fizzyedit/atlas", .modules = &.{ .{ .name = "batch2d", .root =
        // "src/batch2d/root.zig" }, … } }`.
        .web_plugin_dirs = &.{},
        // Fizzy's own identity, for fizzy alone: the root package. Reached as a dependency
        // (`buildApp`), it is an app's build, which gets none of it.
        .own = if (b.pkg_hash.len == 0) .{
            .bundle_id = "com.foxnne.fizzy",
            .repo_url = "https://github.com/fizzyedit/fizzy",
            .version_file = "VERSION",
            .png = "assets/icon.png",
            .ico = "assets/windows/fizzy.ico",
            .rc = "assets/windows/fizzy.rc",
            .icns = "assets/macos/fizzy.icns",
            .plist = "assets/macos/info.plist",
        } else null,
    };

    // A consumer that bundles plugins of its own cannot say so through `b.dependency`
    // options (a plugin is a module from another package, not a value), so it passes
    // `defer-app` here and calls `buildApp` below with its plugin modules instead.
    const app = @import("build/app.zig");
    const cfg = try app.readConfig(b, target, base);
    const defer_app = b.option(
        bool,
        "defer-app",
        "Do not build the application here; the consumer calls `buildApp` with its " ++
            "own plugins",
    ) orelse false;
    if (defer_app) {
        deferred = .{ .target = target, .optimize = optimize, .base = base, .cfg = cfg };
        return;
    }
    var frameworks: app.Frameworks = .{};
    _ = try app.construct(b, target, optimize, base, cfg, &frameworks);
    // On the configure pass that fetches Velopack there is no `package` step to run.
    if (cfg.vz != null) @import("build/package.zig").addPackageAllStep(b, cfg.no_emit);
}

/// What `build` parsed for a `defer-app` consumer, so `buildApp` need not re-declare the
/// standard options on the same builder.
var deferred: ?struct {
    target: std.Build.ResolvedTarget,
    optimize: std.lang.OptimizeMode,
    base: @import("build/app.zig").Options,
    cfg: @import("build/app.zig").Config,
    /// `buildApp` has run (`addPackageSteps` needs its steps).
    built: bool = false,
    /// What `framework` made before `buildApp`, which builds the executables with it.
    frameworks: @import("build/app.zig").Frameworks = .{},
} = null;

pub const BundledPlugin = @import("build/sdk.zig").BundledPlugin;

/// Fizzy's own plugins, as entries in the list `buildApp` links: `fizzy.plugins.text`, or
/// `fizzy.plugins.all` for every one in fizzy's own order. Fizzy builds each for every executable.
/// `workbench` must be listed for now, because the editor still holds its state
/// (fizzyedit/plans#13).
pub const plugins = @import("build/plugins.zig").entries;

/// One of the app's executables as the plugins it links see it: its target and framework modules
/// (`framework`).
pub const Framework = plugin.Framework;

pub const Platform = @import("build/sdk.zig").Platform;

/// The framework modules the app's `platform` executables link, to build a plugin against before
/// `buildApp` lists it. A plugin module built against them is linked as it is: its dependencies
/// keep the modules, target and C sources its own build gave them, so a plugin can bring a C
/// library of its own, such as a tree-sitter grammar. A module that is not (the
/// unwired `"plugin"` module a plugin package exports) is copied for each executable instead.
///
/// ```zig
/// const hello = b.dependency("hello", .{});
/// try fizzy.buildApp(fizzy_dep, &.{
///     fizzy.plugins.workbench,
///     .{ .name = "hello", .module = @import("hello").staticModule(hello.builder, fizzy.framework(fizzy_dep, .native)) },
/// });
/// ```
pub fn framework(fizzy_dep: *std.Build.Dependency, platform: Platform) Framework {
    if (deferred == null) @panic("fizzy.framework: pass `.@\"defer-app\" = true` to b.dependency(\"fizzy\", …) first");
    const d = &deferred.?;
    const b = fizzy_dep.builder;
    switch (platform) {
        .native => {
            const fw = d.frameworks.getNative(b, d.target, d.optimize, d.cfg);
            return .{ .target = d.target, .optimize = d.optimize, .dvui = fw.native.dvui, .core = fw.core, .sdk = fw.sdk, .icons = fw.icons };
        },
        .web => {
            const fw = d.frameworks.getWeb(b, d.optimize);
            return .{ .target = @import("build/web.zig").target(b), .optimize = d.optimize, .dvui = fw.dvui, .core = fw.core, .sdk = fw.sdk, .icons = fw.icons };
        },
    }
}

/// Build the application in a consumer's graph, with the plugins the consumer bundles.
///
/// ```zig
/// const fizzy = @import("fizzy");
/// const fizzy_dep = b.dependency("fizzy", .{
///     .target = target,
///     .optimize = optimize,
///     .@"defer-app" = true,
///     .@"app-name" = @as([]const u8, "myapp"),
///     .@"app-layout" = b.path("src/layout.zig"),
/// });
/// try fizzy.buildApp(fizzy_dep, &.{
///     fizzy.plugins.workbench,
///     fizzy.plugins.text,
///     .{
///         .name = "pixi",
///         .module = b.dependency("pixi", .{
///             .target = target,
///             .optimize = optimize,
///         }).module("plugin"),
///     },
/// });
/// b.installArtifact(fizzy_dep.artifact("myapp"));
/// ```
///
/// `linked` is everything the app links, in registration order (the order of the sidebar's
/// views): fizzy's own (`fizzy.plugins`) and the app's. For an app's, `name` is the plugin's id
/// (its root's `plugin_id`) and `module` its static module, which the plugin package exports and
/// which fizzy wires to `dvui`, `core`, `fizzy_sdk` and `icons`.
pub fn buildApp(fizzy_dep: *std.Build.Dependency, linked: []const BundledPlugin) !void {
    _ = try addApp(fizzy_dep, linked);
}

/// What `addApp` made, for steps of the app's own: `b.installArtifact(app.exe)`, say.
pub const App = struct {
    /// The desktop executable `zig build run` runs.
    exe: *std.Build.Step.Compile,
    /// The one `package` packs: `exe`, or the same linked with Velopack where the target has it.
    packaged: *std.Build.Step.Compile,
    /// The web executable, `web.wasm`.
    wasm: *std.Build.Step.Compile,
    /// The web build, a directory to deploy as it is: `web_page` and `web_files`.
    web: std.Build.LazyPath,
    /// Its `index.html`, and everything else in it, for an app that serves a page of its own.
    web_page: std.Build.LazyPath,
    web_files: std.Build.LazyPath,
};

/// `buildApp`, giving back what it made. An entry's `targets` names the kinds of executable that
/// link it, each with the module built against that kind's framework; a plugin the browser cannot
/// run names only `.native`.
///
/// ```zig
/// const app = try fizzy.addApp(fizzy_dep, &.{
///     fizzy.plugins.workbench,
///     .{ .name = "hello", .targets = &.{
///         .{ .target = .native, .module = hello.staticModule(hello_dep.builder, fizzy.framework(fizzy_dep, .native)) },
///         .{ .target = .web, .module = hello.staticModule(hello_dep.builder, fizzy.framework(fizzy_dep, .web)) },
///     } },
///     .{ .name = "shell", .module = shell_dep.module("plugin"), .targets = &.{.{ .target = .native }} },
/// });
/// ```
pub fn addApp(fizzy_dep: *std.Build.Dependency, linked: []const BundledPlugin) !App {
    const d = deferred orelse @panic("fizzy.addApp: pass `.@\"defer-app\" = true` to b.dependency(\"fizzy\", …) first");
    var opts = d.base;
    opts.app_plugins = try withFizzys(fizzy_dep.builder, linked);
    const built = try @import("build/app.zig").construct(fizzy_dep.builder, d.target, d.optimize, opts, d.cfg, &deferred.?.frameworks);
    deferred.?.built = true;
    return .{
        .exe = built.native.main.exe,
        .packaged = built.native.package.exe,
        .wasm = built.web.wasm,
        .web = built.web.site,
        .web_page = built.web.page,
        .web_files = built.web.files,
    };
}

/// Until fizzyedit/example-app lists fizzy's plugins itself (its CI and fizzy's build each other's
/// main): a list naming none of fizzy's gets all of them ahead of its own, as before. Goes in
/// fizzyedit/plans#13 step 2.
fn withFizzys(b: *std.Build, linked: []const BundledPlugin) ![]const BundledPlugin {
    for (linked) |p| if (p.isFizzys()) return linked;
    return std.mem.concat(b.allocator, BundledPlugin, &.{ &plugins.all, linked });
}

/// `zig build package` (and its alias `desktop`) and `zig build packageall` for an app built with
/// `buildApp`, as steps of the app's own build `b`: a dependency's steps are not the command
/// line's. `package` packages the app for the target the app gave fizzy, into the app's
/// `zig-out/<channel>`; `packageall` runs `zig build package` for each of the six release
/// targets from the app's build root, with the options the app's build was given. An app that
/// already has a step by one of these names gets `error.PackageStepTaken`: `packageall`'s runs
/// call `package` by name.
///
/// ```zig
/// try fizzy.buildApp(fizzy_dep, &.{ … });
/// try fizzy.addPackageSteps(b, fizzy_dep);
/// ```
///
/// What the installers call the app and what they carry come from fizzy's options, passed in
/// `b.dependency`: `app-name` (`--packId`, the executable), `app-bundle-id`, `app_version`,
/// `repo-url` (the update feed; none by default), `app-package-title`, `app-icon` (PNG: the
/// window, the infobar, Linux), `app-icon-ico`, `app-windows-rc`, `app-icon-icns`,
/// `app-macos-plist`. The icons default to fizzy's art; the resource script is generated and
/// vpk writes the plist. `package-dirs` (a `[]const LazyPath`) adds each directory's files beside
/// the executable, and `vpk-args` (a `[]const []const u8`) is passed to `vpk pack` after fizzy's
/// own arguments:
///
/// ```zig
/// const helpers = b.addWriteFiles();
/// _ = helpers.addCopyFile(helper_exe.getEmittedBin(), helper_exe.out_filename);
/// const fizzy_dep = b.dependency("fizzy", .{
///     // …
///     .@"package-dirs" = &[_]std.Build.LazyPath{helpers.getDirectory()},
///     .@"vpk-args" = &[_][]const u8{ "--releaseNotes", "notes.md" },
/// });
/// ```
///
/// `packageall` passes each run the options the app's own command line was given, so the
/// Windows MSVC ones reach fizzy only if the app declares `windows-msvc-libc` / `fetch-msvc` and
/// passes them on in `b.dependency`. Without them, a `*-windows-msvc` run fetches MSVC itself.
pub fn addPackageSteps(b: *std.Build, fizzy_dep: *std.Build.Dependency) !void {
    const d = deferred orelse @panic(
        "fizzy.addPackageSteps: pass `.@\"defer-app\" = true` to " ++
            "b.dependency(\"fizzy\", …) and call fizzy.buildApp first",
    );
    const names = [_][]const u8{ "package", "desktop", "packageall" };
    for (names) |name| if (b.top_level_steps.contains(name)) {
        std.log.err(
            "fizzy.addPackageSteps: this build already has a `{s}` step; `package`, " ++
                "`desktop` and `packageall` are the names it adds",
            .{name},
        );
        return error.PackageStepTaken;
    };
    if (!d.built) @panic("fizzy.addPackageSteps: call fizzy.buildApp first");
    // The configure pass that fetches Velopack builds no package steps.
    if (d.cfg.vz == null) return;
    const package = fizzy_dep.builder.top_level_steps.get("package").?;
    // Into the app's prefix (`zig-out/<channel>`), once. Fizzy's own `package` step would
    // install them into its prefix as a dependency, a directory in the cache
    // (`std.Build.createChild` gives it `.zig-cache/i/<hash>`), so it is not run: the installers'
    // directory carries the vpk run, or the failure saying why this target can't be packaged.
    const step = b.step("package", package.description);
    step.dependOn(&b.addInstallDirectory(.{
        .source_dir = fizzy_dep.namedLazyPath("package"),
        .install_dir = .{ .custom = d.cfg.zig_out_subdir },
        .install_subdir = "",
    }).step);
    b.step("desktop", "Alias for `zig build package`").dependOn(step);
    @import("build/package.zig").addPackageAllStep(b, d.cfg.no_emit);
}

/// `zig build web` for an app built with `buildApp`, as a step of the app's own build `b`: fizzy's
/// web build installed into the app's `zig-out/web`. An app that already has a `web` step gets
/// `error.WebStepTaken`.
///
/// ```zig
/// try fizzy.buildApp(fizzy_dep, &.{ … });
/// try fizzy.addWebSteps(b, fizzy_dep);
/// ```
pub fn addWebSteps(b: *std.Build, fizzy_dep: *std.Build.Dependency) !void {
    if (b.top_level_steps.contains("web")) {
        std.log.err("fizzy.addWebSteps: this build already has a `web` step", .{});
        return error.WebStepTaken;
    }
    const d = deferred orelse @panic("fizzy.addWebSteps: pass `.@\"defer-app\" = true` to b.dependency(\"fizzy\", …) and call fizzy.buildApp first");
    if (!d.built) @panic("fizzy.addWebSteps: call fizzy.buildApp first");
    b.step("web", "Build the web (wasm) app into zig-out/web/").dependOn(&b.addInstallDirectory(.{
        .source_dir = fizzy_dep.namedLazyPath("web"),
        .install_dir = .{ .custom = "web" },
        .install_subdir = "",
    }).step);
}

/// What a dvui app of its own builds on (`addDvui`): fizzy's backend, with OS windows besides the
/// main one, or dvui's own SDL3 backend, with the main window only.
pub const NativeBackend = @import("build/exe.zig").NativeBackend;

/// A plain dvui app — dvui's widgets and `dvui.App`, nothing of fizzy the editor — on `backend`:
/// `root_module` gets `dvui` (fizzy's pin), its `backend`, and `viewports_none`, so the same code
/// builds on either backend:
///
/// ```zig
/// const backend = @import("backend");
/// const viewports = if (@hasDecl(backend, "viewports"))
///     backend.viewports
/// else
///     @import("viewports_none");
/// ```
///
/// On fizzy's backend it also gets `platform` (the window's chrome and state), and on macOS the
/// backend's Objective-C, compiled into it. Give `root_module` its target and optimize mode first.
pub fn addDvui(fizzy_dep: *std.Build.Dependency, root_module: *std.Build.Module, backend: NativeBackend) !void {
    const b = fizzy_dep.builder;
    const exe = @import("build/exe.zig");
    const target = root_module.resolved_target orelse @panic("fizzy.addDvui: give the root module its target first");
    const optimize = root_module.optimize orelse .debug;
    const macos_sdl_paths = try @import("build/common.zig").macosSdlPathsForExplicitTarget(b, target, null);
    const native = exe.nativeDvui(b, backend, target, optimize, .off, macos_sdl_paths);
    root_module.addImport("dvui", native.dvui);
    root_module.addImport("backend", native.backend);
    const backend_dep = exe.backendDependency(b);
    root_module.addImport("viewports_none", @import("fizzy_backend").viewportsNoneModule(backend_dep, native.dvui));
    if (backend == .fizzy) {
        root_module.addImport("platform", exe.platformModule(b, native, target, optimize, macos_sdl_paths));
        @import("fizzy_backend").addPlatformObjC(
            backend_dep,
            root_module,
            exe.backendOptions(
                target,
                optimize,
                macos_sdl_paths,
            ),
        );
    }
}
