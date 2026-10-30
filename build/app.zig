const std = @import("std");

// Through the `sdk/` dependency, not by relative path — see `build/sdk.zig`'s `dvuiDependency` for
// why the app consumes the SDK as a package, and `sdk/build.zig` for what it exposes. dvui's build
// API arrives the same way because `sdk/` owns the repo's only dvui pin.
const fizzy_sdk = @import("fizzy_sdk");
const plugin = fizzy_sdk.plugin;
const core_mod = fizzy_sdk.core_module;
const dvui = fizzy_sdk.dvui;
const velopack = @import("velopack.zig");
const rehome_fixture = @import("rehome_fixture.zig");
const FizzyExecutable = @import("exe.zig").FizzyExecutable;
const NativeFramework = @import("exe.zig").NativeFramework;
const web = @import("web.zig");

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

/// The type of `Chrome.sidebar_edge`, for the build option.
const ChromeEdge = enum { left, right };

/// Initial presentation preferences, used until the person makes a shared choice.
pub const Look = struct {
    /// Motion level from 0 (off) to 1 (playful). The OS reduced-motion request wins.
    motion: ?f32 = null,
};

pub const Options = struct {
    look: Look = .{},
    /// Every plugin the application links, fizzy's own among them, each in the executables its
    /// `targets` names — see `build.zig`'s `buildApp`.
    app_plugins: []const @import("sdk.zig").BundledPlugin = &@import("plugins.zig").entries.all,
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
    /// Fizzy's own build passes `Own`; an app built on fizzy leaves it null.
    own: ?Own = null,
    windows_msvc_libc_opt: ?[]const u8 = null,
    fetch_msvc_opt: ?bool = null,
    macos_sign_app_identity: ?[]const u8 = null,
    macos_sign_install_identity: ?[]const u8 = null,
    macos_notary_profile: ?[]const u8 = null,
    /// `-Dmacos-sdk`: the macOS SDK for an explicit `-Dtarget=*-macos`; null asks `xcrun`.
    macos_sdk: ?[]const u8 = null,
};

pub fn build(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.OptimizeMode, opts: Options) !void {
    const cfg = try readConfig(b, target, opts);
    var frameworks: Frameworks = .{};
    _ = try construct(b, target, optimize, opts, cfg, &frameworks);
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
    branding: Branding,
    app_config_dir: []const u8,
    app_registry_url: []const u8,
    app_repo_url: []const u8,
    app_repo_url_fallback: []const u8,
    app_is_fizzy: bool,
    app_repo_url_set: bool,
    app_issues_url: []const u8,
    app_layout_path: ?std.Build.LazyPath,
    static_workbench: bool,
    static_text: bool,
    static_image: bool,
    dynamic_plugins: bool,
    chrome_sidebar_edge: ChromeEdge,
    chrome_panel: bool,
    chrome_menu_bar: bool,
    chrome_infobar: bool,
    workbench_opts: *std.Build.Step.Options,
    /// Null on the configure pass that fetches Velopack (see `readConfig`).
    msvcup_before_compile: ?*std.Build.Step.Run,
    accesskit: dvui.AccesskitOptions,
    /// What the native executable draws with (`-Dnative-backend`, `build/exe.zig`).
    native_backend: @import("exe.zig").NativeBackend,
    test_filters: []const []const u8,
    /// `-Dpackage-dirs`, `-Dvpk-args` (`package.zig`).
    package_dirs: []const std.Build.LazyPath,
    vpk_args: []const []const u8,
    macos_sign_app_identity: ?[]const u8,
    macos_sign_install_identity: ?[]const u8,
    macos_notary_profile: ?[]const u8,
    win_libc: velopack.ResolvedWindowsMsvcLibc,
};

/// What says which application this is outside its own code: the icons its window, executable
/// and installers carry, macOS's Info.plist, and the title the installers give it. Fizzy's own
/// by default; an app built on fizzy passes its own through `b.dependency` (`-Dapp-icon=` …).
pub const Branding = struct {
    /// The window's icon (`src/Entry.zig`, as the `app_icon` module) and the Linux AppImage's.
    png: std.Build.LazyPath,
    /// `png` is fizzy's pixel art, drawn with nearest-neighbour sampling; an app's is smoothed.
    pixel_art: bool,
    /// The Windows installer's and its Start Menu shortcut's icon.
    ico: std.Build.LazyPath,
    /// The resource script embedded into the Windows executable: its icon and version details.
    rc: std.Build.LazyPath,
    /// The macOS bundle's icon.
    icns: std.Build.LazyPath,
    /// The macOS bundle's Info.plist. Null for an app other than fizzy without one: vpk then
    /// writes it from `--bundleId` (vpk takes one or the other, never both).
    plist: ?std.Build.LazyPath,
    /// `vpk pack --packTitle`: the name of the macOS bundle, the Windows shortcut and the Linux
    /// desktop entry.
    package_title: []const u8,
};

/// The application's identity, as `readBranding` needs it.
const Identity = struct {
    name: []const u8,
    display_name: []const u8,
    version: []const u8,
};

/// What only fizzy's own build passes (`build.zig`, when fizzy is the root package): its update
/// feed, its version file, its bundle id, and the plist and resource script that name it. An app
/// built on fizzy gets none of these by default.
pub const Own = struct {
    bundle_id: []const u8,
    /// The update feed (`repo-url`).
    repo_url: []const u8,
    /// Read for the version when `-Dapp_version` is not given. This and the files below are
    /// relative to fizzy's build root.
    version_file: []const u8,
    /// Fizzy's branding, a set: the plist names the executable and `fizzy.icns`, the resource
    /// script embeds `fizzy.ico`. The build takes all of it or none (`readBranding`).
    png: []const u8,
    ico: []const u8,
    rc: []const u8,
    icns: []const u8,
    plist: []const u8,
};

/// Fizzy's own branding as a whole (`Own`) while fizzy's build keeps fizzy's name and icons;
/// otherwise the app's: its icons (fizzy's art where it gives none), a generated resource script
/// and a plist vpk writes. `-Dapp-windows-rc` / `-Dapp-macos-plist` override either.
fn readBranding(b: *std.Build, id: Identity, own: ?Own, renamed: bool) Branding {
    const LazyPath = std.Build.LazyPath;
    const png_opt = b.option(
        LazyPath,
        "app-icon",
        "PNG icon: the window's, the infobar's and the Linux package's (default: fizzy's)",
    );
    const ico_opt = b.option(
        LazyPath,
        "app-icon-ico",
        "Windows .ico: the installer's, the Start Menu shortcut's, and the generated" ++
            " resource script's (default: fizzy's)",
    );
    const icns_opt = b.option(LazyPath, "app-icon-icns", "macOS .icns: the bundle's icon (default: fizzy's)");
    const rc_opt = b.option(
        LazyPath,
        "app-windows-rc",
        "Windows resource script embedded in the exe (default: fizzy's for fizzy, " ++
            "else one generated from the icon, names and version)",
    );
    const plist_opt = b.option(
        LazyPath,
        "app-macos-plist",
        "macOS Info.plist (default: fizzy's for fizzy, else one vpk writes from " ++
            "app-bundle-id)",
    );
    const package_title = b.option(
        []const u8,
        "app-package-title",
        "The installers' name for the app: the macOS bundle, the Windows shortcut " ++
            "(default: app-name)",
    ) orelse id.name;
    const own_set = if (renamed or png_opt != null or ico_opt != null or icns_opt != null) null else own;
    if (own_set) |o| return .{
        .png = b.path(o.png),
        .pixel_art = true,
        .ico = b.path(o.ico),
        .rc = rc_opt orelse b.path(o.rc),
        .icns = b.path(o.icns),
        .plist = plist_opt orelse b.path(o.plist),
        .package_title = package_title,
    };
    const ico = ico_opt orelse b.path("assets/windows/fizzy.ico");
    return .{
        .png = png_opt orelse b.path("assets/icon.png"),
        .pixel_art = png_opt == null,
        .ico = ico,
        .rc = rc_opt orelse windowsRc(b, id, ico),
        .icns = icns_opt orelse b.path("assets/macos/fizzy.icns"),
        .plist = plist_opt,
        .package_title = package_title,
    };
}

/// A resource script with the build's own icon, and the version details Explorer shows from its
/// own names and version rather than fizzy.rc's.
fn windowsRc(b: *std.Build, id: Identity, ico: std.Build.LazyPath) std.Build.LazyPath {
    // `v1.2.3-dev+5` → 1,2,3,0: up to four numeric parts, anything else 0.
    var parts = [4]u16{ 0, 0, 0, 0 };
    const core = std.mem.trimStart(
        u8,
        id.version[0 .. std.mem.findAny(u8, id.version, "-+") orelse id.version.len],
        "vV",
    );
    var it = std.mem.splitScalar(u8, core, '.');
    for (&parts) |*part| part.* = std.fmt.parseInt(u16, it.next() orelse break, 10) catch 0;
    // An rc string literal holds no control characters (they are dropped), doubles its quotes
    // and escapes its backslashes.
    var strings: [3][]const u8 = .{ id.display_name, id.version, id.name };
    for (&strings) |*str| {
        var printable: std.ArrayList(u8) = .empty;
        for (str.*) |c| if (!std.ascii.isControl(c)) printable.append(b.allocator, c) catch @panic("OOM");
        str.* = printable.items;
        str.* = std.mem.replaceOwned(u8, b.allocator, str.*, "\\", "\\\\") catch @panic("OOM");
        str.* = std.mem.replaceOwned(u8, b.allocator, str.*, "\"", "\"\"") catch @panic("OOM");
    }
    const files = b.addWriteFiles();
    // The script names its icon relative to itself, so the two go in one directory.
    _ = files.addCopyFile(ico, "app.ico");
    return files.add("app.rc", b.fmt(
        \\#pragma code_page(65001)
        \\
        \\1 ICON "app.ico"
        \\
        \\1 VERSIONINFO
        \\FILEVERSION    {[numeric]s}
        \\PRODUCTVERSION {[numeric]s}
        \\FILEOS         0x4
        \\FILETYPE       0x1
        \\{{
        \\    BLOCK "StringFileInfo"
        \\    {{
        \\        BLOCK "040904B0"
        \\        {{
        \\            VALUE "FileDescription",  "{[display]s}"
        \\            VALUE "FileVersion",      "{[version]s}"
        \\            VALUE "InternalName",     "{[name]s}"
        \\            VALUE "OriginalFilename", "{[name]s}.exe"
        \\            VALUE "ProductName",      "{[display]s}"
        \\            VALUE "ProductVersion",   "{[version]s}"
        \\        }}
        \\    }}
        \\    BLOCK "VarFileInfo"
        \\    {{
        \\        VALUE "Translation", 0x0409, 0x04B0
        \\    }}
        \\}}
        \\
    , .{
        .numeric = b.fmt("{d},{d},{d},{d}", .{ parts[0], parts[1], parts[2], parts[3] }),
        .display = strings[0],
        .version = strings[1],
        .name = strings[2],
    }));
}

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

    const macos_sdl_paths = try common.macosSdlPathsForExplicitTarget(b, target, opts.macos_sdk);
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

    // Only `-Dwindows-msvc-libc` or the managed `.velopack-msvc/` tree: Zig 0.17 has no global
    // `--libc`.
    const effective_win_libc: ?[]const u8 = win_libc.libc_path;

    // Velopack in the dev/install exe is opt-in (`-Dvelopack=true`). Release
    // packaging (`zig build package`) still links Velopack when the ABI supports
    // it via a second compile, so `zig build` / `run` / `test` never pull dotnet
    // or the static Velopack lib unless you ask. Windows *-gnu targets are
    // unchanged (no Velopack prebuilt for that ABI).
    const velopack_supported_for_target = !(target.result.os.tag == .windows and target.result.abi != .msvc);
    const velopack_enabled = b.option(
        bool,
        "velopack",
        "Link Velopack runtime in the install/run exe (auto-update). Default: false." ++
            " `package` still produces a Velopack-linked binary when supported.",
    ) orelse false;

    if (velopack_enabled and !velopack_supported_for_target) {
        std.log.err(
            "-Dvelopack=true is unsupported for target ABI {s}: Velopack on Windows " ++
                "requires -Dtarget=x86_64-windows-msvc or -Dtarget=aarch64-windows-msvc.",
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

    const app_version_opt = b.option(
        []const u8,
        "app_version",
        "App version for vpk packVersion and startup log (default: fizzy's VERSION " ++
            "file for fizzy, else 0.0.0)",
    );

    // GitHub repo URL baked into the binary so Velopack's auto-update can find
    // the latest release via the GitHub Releases API. Override at build time
    // with `-Drepo-url=...` (e.g. when shipping a fork). At runtime, the env
    // var `FIZZY_AUTOUPDATE_URL` still overrides this for local feed testing.
    // An app built on fizzy has no feed unless it names one: fizzy's releases are not its updates.
    const repo_url_opt = b.option(
        []const u8,
        "repo-url",
        "GitHub repo URL used by Velopack auto-update (default: fizzy's for fizzy, " ++
            "else none)",
    );
    const app_repo_url = repo_url_opt orelse if (opts.own) |own| own.repo_url else "";

    // Comma-separated fallback repo URLs checked (in order) after `app_repo_url`
    // yields no update. Lets a build survive a repo move/rename: ship a binary
    // whose primary points at the new home and whose fallback points at the old
    // one (where the transitional release is published), then transfer the repo.
    // Empty by default (no fallback).
    const app_repo_url_fallback = b.option(
        []const u8,
        "repo-url-fallback",
        "Comma-separated fallback GitHub repo URLs for Velopack auto-update, tried " ++
            "after -Drepo-url",
    ) orelse "";

    var version_owned: ?[]u8 = null; // lives as long as the build process

    // An app's version is its own: it passes `.app_version` (its build root is not this
    // package's, so its VERSION file is out of reach here), else 0.0.0.
    const app_version: []const u8 = if (app_version_opt) |v| v else if (opts.own) |own| blk: {
        b.dependOnFileContents(b.path(own.version_file));
        const raw = std.Io.Dir.cwd().readFileAlloc(
            b.graph.io,
            b.root.joinString(b.allocator, own.version_file) catch @panic("OOM"),
            b.allocator,
            std.Io.Limit.limited(256),
        ) catch |e| std.debug.panic("read VERSION: {}", .{e});
        version_owned = raw;
        break :blk std.mem.trimEnd(u8, raw, "\r\n");
    } else "0.0.0";

    const build_opts = b.addOptions();
    build_opts.addOption([]const u8, "app_version", app_version);

    // Application identity (see app/AppInfo.zig). Options rather than literals so an app built
    // on fizzy as a library can set them; fizzy passes its own values.
    const app_name_opt = b.option(
        []const u8,
        "app-name",
        "Short lowercase app identifier (exe name, packId, config dir)",
    );
    const app_name = app_name_opt orelse "fizzy";
    const app_display_name = b.option([]const u8, "app-display-name", "Human-facing application name") orelse "Fizzy";
    // An app that names no bundle id gets one of its own, not fizzy's: `dev.fizzy.<app-name>`,
    // with anything a bundle id cannot hold made `-`.
    const app_bundle_id = b.option(
        []const u8,
        "app-bundle-id",
        "Reverse-DNS application identifier (default: fizzy's for fizzy, else " ++
            "dev.fizzy.<app-name>)",
    ) orelse
        if (opts.own) |own| own.bundle_id else b.fmt(
            "dev.fizzy.{s}",
            .{@import("bundle_id.zig").component(b.allocator, app_name)},
        );
    const app_config_dir = b.option(
        []const u8,
        "app-config-dir",
        "Config directory name (defaults to app-name)",
    ) orelse app_name;
    const app_registry_url = b.option(
        []const u8,
        "app-registry-url",
        "Plugin registry catalog URL; empty disables the store",
    ) orelse "https://plugins.fizzyed.it/catalog";
    const branding = readBranding(
        b,
        .{ .name = app_name, .display_name = app_display_name, .version = app_version },
        opts.own,
        app_name_opt != null,
    );
    build_opts.addOption([]const u8, "app_name", app_name);
    build_opts.addOption([]const u8, "app_display_name", app_display_name);
    build_opts.addOption([]const u8, "app_bundle_id", app_bundle_id);
    build_opts.addOption([]const u8, "app_config_dir", app_config_dir);
    build_opts.addOption([]const u8, "app_registry_url", app_registry_url);
    build_opts.addOption([]const u8, "app_repo_url", app_repo_url);
    build_opts.addOption([]const u8, "app_repo_url_fallback", app_repo_url_fallback);
    // Fizzy itself rather than an app built on it: fizzy's own build passes `own` (as the root
    // package, `build.zig`), an app reaches fizzy as a dependency (`buildApp`). Structural, so a
    // fork or a fizzy build that renames itself is still told apart from an app.
    const app_is_fizzy = opts.own != null;
    // Where Report a Bug goes. Not `repo-url` as such, which is the update feed and defaults to
    // fizzy's: an app reports to its own repo only when it named one (`issues_url.zig`).
    const app_issues_url = b.option(
        []const u8,
        "app-issues-url",
        "Where Report a Bug goes; empty disables it (default: an explicit repo-url's" ++
            " issues, fizzy's for fizzy)",
    ) orelse
        try @import("issues_url.zig").derive(b.allocator, repo_url_opt, app_is_fizzy);
    const app_repo_url_set = repo_url_opt != null and repo_url_opt.?.len > 0;
    build_opts.addOption(bool, "app_is_fizzy", app_is_fizzy);
    build_opts.addOption(bool, "app_repo_url_set", app_repo_url_set);
    build_opts.addOption([]const u8, "app_issues_url", app_issues_url);
    build_opts.addOption(bool, "velopack_enabled", velopack_enabled);
    build_opts.addOption(?f32, "look_motion", opts.look.motion);
    // Off, the app runs only the plugins it links (`buildApp`'s list): no plugin dylib is built,
    // and nothing loads at runtime — not fizzy's own dylibs, not the user plugins directory, not
    // the store, not a web page's `?plugin=`. Comptime, so none of it is checked per frame.
    const dynamic_plugins = b.option(
        bool,
        "dynamic-plugins",
        "Load plugins at runtime: fizzy's own dylibs, the user plugins directory, " ++
            "the store (default: true)",
    ) orelse true;
    build_opts.addOption(bool, "dynamic_plugins", dynamic_plugins);

    // A consumer that wants its own shape passes `-Dapp-layout=` (a LazyPath to
    // `pub fn layout(?*anyopaque, *Layout)`). Fizzy itself uses `src/editor/layout.zig`.
    // There is no `-Dlayout=` enum of shipped presets: the shapes are fizzyedit/example-app's.
    const app_layout_path = b.option(
        std.Build.LazyPath,
        "app-layout",
        "App-owned layout file (pub fn layout(?*anyopaque, *Layout))",
    );
    build_opts.addOption(bool, "has_app_layout", app_layout_path != null);
    // The frame of fizzy's own shape an app keeps (`src/editor/Chrome.zig`); the defaults are
    // fizzy's own.
    const chrome_sidebar_edge = b.option(
        ChromeEdge,
        "chrome-sidebar-edge",
        "Which end of the window the icon rail and Sidebar sit at: left (default) or right",
    ) orelse .left;
    const chrome_panel = b.option(bool, "chrome-panel", "Draw the bottom Panel and its Output view (default: true)") orelse true;
    const chrome_menu_bar = b.option(bool, "chrome-menu-bar", "Draw the in-window menu bar (default: true)") orelse true;
    const chrome_infobar = b.option(bool, "chrome-infobar", "Draw the infobar (default: true)") orelse true;
    build_opts.addOption(ChromeEdge, "chrome_sidebar_edge", chrome_sidebar_edge);
    build_opts.addOption(bool, "chrome_panel", chrome_panel);
    build_opts.addOption(bool, "chrome_menu_bar", chrome_menu_bar);
    build_opts.addOption(bool, "chrome_infobar", chrome_infobar);
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

    const msvcup_before_compile: ?*std.Build.Step.Run = if (vz) |v| velopack.addMsvcupSetupStep(
        b,
        v,
        ".velopack-msvc",
    ) else null;
    const msvcup_setup_step = b.step(
        "msvcup-setup",
        "Download MSVC SDK into .velopack-msvc/ via velopack-zig (writes zig-libc-*.ini)",
    );
    if (msvcup_before_compile) |m| msvcup_setup_step.dependOn(&m.step);

    const accesskit = b.option(dvui.AccesskitOptions, "accesskit", "Enable accesskit") orelse .off;
    const fizzy_exe = @import("exe.zig");
    const native_backend = b.option(
        fizzy_exe.NativeBackend,
        "native-backend",
        "Native renderer: fizzy (fizzy's own SDL_GPU backend, custom programs) or " ++
            "sdl3 (dvui's SDL_Renderer backend). Default: fizzy",
    ) orelse fizzy_exe.defaultNativeBackend(target);

    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match any filter",
    ) orelse &[0][]const u8{};

    // What an app's installers carry besides the executable and the plugin dylibs (a helper
    // program it starts, say), and what it tells vpk besides fizzy's own arguments.
    const package_dirs = b.option(
        []const std.Build.LazyPath,
        "package-dirs",
        "Directories whose files `package` ships beside the executable",
    ) orelse &.{};
    const vpk_args = b.option(
        []const []const u8,
        "vpk-args",
        "Arguments `package` passes `vpk pack` after its own",
    ) orelse &.{};
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
        .branding = branding,
        .app_config_dir = app_config_dir,
        .app_registry_url = app_registry_url,
        .app_repo_url = app_repo_url,
        .app_repo_url_fallback = app_repo_url_fallback,
        .app_is_fizzy = app_is_fizzy,
        .app_repo_url_set = app_repo_url_set,
        .app_issues_url = app_issues_url,
        .app_layout_path = app_layout_path,
        .static_workbench = static_workbench,
        .static_text = static_text,
        .static_image = static_image,
        .dynamic_plugins = dynamic_plugins,
        .chrome_sidebar_edge = chrome_sidebar_edge,
        .chrome_panel = chrome_panel,
        .chrome_menu_bar = chrome_menu_bar,
        .chrome_infobar = chrome_infobar,
        .workbench_opts = workbench_opts,
        .msvcup_before_compile = msvcup_before_compile,
        .accesskit = accesskit,
        .native_backend = native_backend,
        .test_filters = test_filters,
        .package_dirs = package_dirs,
        .vpk_args = vpk_args,
        .macos_sign_app_identity = macos_sign_app_identity,
        .macos_sign_install_identity = macos_sign_install_identity,
        .macos_notary_profile = macos_notary_profile,
        .win_libc = win_libc,
    };
}

/// What `construct` made, for an app built on fizzy to build steps of its own over.
pub const Built = struct {
    native: Native,
    web: web.Web,
};

/// Phase two of `build`: the executables, the web build, tests, packaging. `frameworks` holds any
/// an app asked for first (`fizzy.framework`), and gets the rest.
pub fn construct(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.OptimizeMode,
    opts: Options,
    cfg: Config,
    frameworks: *Frameworks,
) !Built {
    const assetpack = @import("assetpack");
    const assets_module = assetpack.pack(b, b.path("assets"), .{});
    // The window's icon, apart from `assets` so an app built on fizzy can give its own.
    const app_icon_files = b.addWriteFiles();
    _ = app_icon_files.addCopyFile(cfg.branding.png, "icon.png");
    const app_icon_module = b.createModule(.{
        .root_source_file = app_icon_files.add("app_icon.zig", b.fmt(
            \\pub const png = @embedFile("icon.png");
            \\/// Fizzy's icon is pixel art, kept sharp; an app's is smoothed.
            \\pub const pixel_art = {};
            \\
        , .{cfg.branding.pixel_art})),
    });

    // `zig build web` produces `zig-out/web/{web.wasm, fizzy.js, web.js, index.html, …}`,
    // deployable as-is to a static host.
    const w = web.build(
        b,
        frameworks.getWeb(b, optimize),
        optimize,
        cfg.build_opts,
        cfg.workbench_opts,
        assets_module,
        app_icon_module,
        cfg.app_layout_path,
        try @import("sdk.zig").pluginsFor(b, opts.app_plugins, .web),
        opts.web_plugin_deps,
        opts.web_plugin_dirs,
        opts.own != null,
    );
    const built = try native(
        b,
        target,
        optimize,
        opts,
        cfg,
        frameworks.getNative(b, target, optimize, cfg),
        assets_module,
        app_icon_module,
    );
    install(b, target, optimize, cfg, w, built);
    try addTests(b, target, optimize, cfg, built, assets_module, app_icon_module);
    return .{ .native = built, .web = w };
}

/// Each kind of executable's framework, made the first time it is asked for: by `construct`, or
/// before it by an app (`fizzy.framework`), whose plugins are then built against the very modules
/// its executables link.
pub const Frameworks = struct {
    native: ?NativeFramework = null,
    web: ?web.Framework = null,

    pub fn getNative(
        self: *Frameworks,
        b: *std.Build,
        target: std.Build.ResolvedTarget,
        optimize: std.lang.OptimizeMode,
        cfg: Config,
    ) NativeFramework {
        if (self.native == null) self.native = @import("exe.zig").nativeFramework(
            b,
            target,
            optimize,
            cfg.accesskit,
            cfg.native_backend,
            cfg.macos_sdl_paths,
        );
        return self.native.?;
    }

    pub fn getWeb(self: *Frameworks, b: *std.Build, optimize: std.lang.OptimizeMode) web.Framework {
        if (self.web == null) self.web = web.framework(b, optimize);
        return self.web.?;
    }
};

/// What `native` made: the executable, and the one `package` packs.
pub const Native = struct {
    main: FizzyExecutable,
    /// `main`, unless it has no Velopack and the target supports it: then a second, with it.
    package: FizzyExecutable,
};

fn native(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.OptimizeMode,
    opts: Options,
    cfg: Config,
    framework: NativeFramework,
    assets_module: *std.Build.Module,
    app_icon_module: *std.Build.Module,
) !Native {
    const fizzy_exe = @import("exe.zig");
    const vz = cfg.vz;
    const macos_sdl_paths = cfg.macos_sdl_paths;
    const velopack_supported_for_target = cfg.velopack_supported_for_target;
    const velopack_enabled = cfg.velopack_enabled;
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
    const dynamic_plugins = cfg.dynamic_plugins;
    const workbench_opts = cfg.workbench_opts;
    const native_backend = cfg.native_backend;
    const app_plugins = try @import("sdk.zig").pluginsFor(b, opts.app_plugins, .native);

    const main_fizzy = try fizzy_exe.addFizzyExecutableForTarget(
        b,
        vz,
        target,
        optimize,
        framework,
        native_backend,
        build_opts,
        workbench_opts,
        assets_module,
        app_icon_module,
        cfg.branding.rc,
        macos_sdl_paths,
        velopack_enabled,
        app_name,
        app_layout_path,
        app_plugins,
        dynamic_plugins,
    );

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
        pack_opts.addOption(bool, "app_is_fizzy", cfg.app_is_fizzy);
        pack_opts.addOption(bool, "app_repo_url_set", cfg.app_repo_url_set);
        pack_opts.addOption([]const u8, "app_issues_url", cfg.app_issues_url);
        pack_opts.addOption(bool, "velopack_enabled", true);
        pack_opts.addOption(?f32, "look_motion", opts.look.motion);
        pack_opts.addOption(bool, "static_workbench", static_workbench);
        pack_opts.addOption(bool, "static_text", static_text);
        pack_opts.addOption(bool, "static_image", static_image);
        pack_opts.addOption(bool, "dynamic_plugins", dynamic_plugins);
        pack_opts.addOption(bool, "has_app_layout", app_layout_path != null);
        pack_opts.addOption(ChromeEdge, "chrome_sidebar_edge", cfg.chrome_sidebar_edge);
        pack_opts.addOption(bool, "chrome_panel", cfg.chrome_panel);
        pack_opts.addOption(bool, "chrome_menu_bar", cfg.chrome_menu_bar);
        pack_opts.addOption(bool, "chrome_infobar", cfg.chrome_infobar);
        break :package_blk try fizzy_exe.addFizzyExecutableForTarget(
            b,
            vz,
            target,
            optimize,
            framework,
            native_backend,
            pack_opts,
            workbench_opts,
            assets_module,
            app_icon_module,
            cfg.branding.rc,
            macos_sdl_paths,
            true,
            app_name,
            app_layout_path,
            app_plugins,
            dynamic_plugins,
        );
    };

    return .{ .main = main_fizzy, .package = package_fizzy };
}

/// The steps over what `web.build` and `native` made: the installs, `run`, the dylib steps,
/// packaging.
fn install(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.OptimizeMode,
    cfg: Config,
    w: web.Web,
    built: Native,
) void {
    const common = @import("common.zig");
    const package = @import("package.zig");
    const vz = cfg.vz;
    const zig_out_subdir = cfg.zig_out_subdir;
    const zig_out_install_dir = cfg.zig_out_install_dir;
    const velopack_required_fail = cfg.velopack_required_fail;
    const no_emit = cfg.no_emit;
    const app_version = cfg.app_version;
    const app_name = cfg.app_name;
    const app_bundle_id = cfg.app_bundle_id;
    const macos_sign_app_identity = cfg.macos_sign_app_identity;
    const macos_sign_install_identity = cfg.macos_sign_install_identity;
    const macos_notary_profile = cfg.macos_notary_profile;

    web.install(b, w);

    const exe = built.main.exe;
    const plugins_install_dir: std.Build.InstallDir = .{ .custom = b.fmt("{s}/plugins", .{zig_out_subdir}) };
    if (no_emit) {
        b.getInstallStep().dependOn(&exe.step);
        for (built.main.dylibs) |dylib| common.attachBuiltinPluginInstall(
            b,
            b.getInstallStep(),
            dylib.compile,
            dylib.id,
            plugins_install_dir,
        );
    } else {
        const install_artifact = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = zig_out_install_dir },
        });
        // A running fizzy holds its executable on Windows: set it aside first, or the install
        // fails.
        if (b.graph.host.result.os.tag == .windows and target.result.os.tag == .windows) {
            const aside_exe = b.addExecutable(.{
                .name = "set-aside",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("build/set_aside.zig"),
                    .target = b.graph.host,
                    .optimize = .fast,
                }),
            });
            const aside = b.addRunArtifact(aside_exe);
            aside.setName("set aside a running executable");
            aside.addDirectoryArg(common.installDirPath(zig_out_install_dir));
            aside.addArg(exe.out_filename);
            aside.has_side_effects = true;
            aside.step.dependOn(&exe.step);
            install_artifact.step.dependOn(&aside.step);
        }

        const run_cmd = b.addRunArtifact(exe);
        const run_step = b.step("run", "Run the app (does not run Velopack)");

        run_cmd.step.dependOn(&install_artifact.step);
        run_step.dependOn(&run_cmd.step);
        b.getInstallStep().dependOn(&install_artifact.step);

        for (built.main.dylibs) |dylib| {
            common.attachBuiltinPluginInstall(b, b.getInstallStep(), dylib.compile, dylib.id, plugins_install_dir);
            common.attachBuiltinPluginInstall(b, &run_cmd.step, dylib.compile, dylib.id, plugins_install_dir);
        }
    }

    for (built.main.dylibs) |dylib| {
        const install_dylib = plugin.installBuiltinPlugin(b, dylib.compile, dylib.id, plugins_install_dir);
        b.step(
            b.fmt("{s}-dylib", .{dylib.id}),
            b.fmt(
                "Build the {s} plugin as a dynamic library into zig-out/<target>/plugins/ " ++
                    "(native only)",
                .{dylib.id},
            ),
        ).dependOn(&install_dylib.step);
    }

    if (vz) |v| _ = package.addSteps(.{
        .b = b,
        .vz = v,
        .target = target,
        .optimize = optimize,
        .app_version = app_version,
        .app_name = app_name,
        .app_bundle_id = app_bundle_id,
        .branding = cfg.branding,
        .zig_out_subdir = zig_out_subdir,
        .zig_out_install_dir = zig_out_install_dir,
        .no_emit = no_emit,
        .velopack_required_fail = velopack_required_fail,
        .exe_for_package = built.package.exe,
        .package_fizzy = built.package,
        .package_dirs = cfg.package_dirs,
        .vpk_args = cfg.vpk_args,
        .macos_sign_app_identity = macos_sign_app_identity,
        .macos_sign_install_identity = macos_sign_install_identity,
        .macos_notary_profile = macos_notary_profile,
    });
}

/// The unit and integration tests, the benchmarks, and the checks over them.
fn addTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.OptimizeMode,
    cfg: Config,
    built: Native,
    assets_module: *std.Build.Module,
    app_icon_module: *std.Build.Module,
) !void {
    const plugins = @import("plugins.zig");
    const sdk = @import("sdk.zig");
    const fizzy_exe = @import("exe.zig");
    const msvc = @import("msvc.zig");
    const workbench_plugin = plugins.workbench;
    const text_plugin = plugins.text;
    const image_plugin = plugins.image;
    const vz = cfg.vz;
    const macos_sdl_paths = cfg.macos_sdl_paths;
    const target_is_windows_msvc = cfg.target_is_windows_msvc;
    const effective_win_libc = cfg.effective_win_libc;
    const velopack_supported_for_target = cfg.velopack_supported_for_target;
    const velopack_enabled = cfg.velopack_enabled;
    const velopack_required_fail = cfg.velopack_required_fail;
    const build_opts = cfg.build_opts;
    const workbench_opts = cfg.workbench_opts;
    const msvcup_before_compile = cfg.msvcup_before_compile;
    const accesskit = cfg.accesskit;
    const test_filters = cfg.test_filters;
    const win_libc = cfg.win_libc;
    const main_fizzy = built.main;
    const package_fizzy = built.package;
    const exe = main_fizzy.exe;
    const exe_for_package = package_fizzy.exe;

    // ---------------------------------------------------------------
    // Tests
    // ---------------------------------------------------------------
    //
    // Fizzy has two test layers (see tests/README.md):
    //
    //   1. Unit tests — pure logic (math, palette parsing, layer order), without
    //      windows or native backends. Glass arithmetic also imports dvui's types.
    //
    //   2. Integration tests use dvui's testing backend and exercise
    //      real fizzy drawing functions in a headless Window.
    //
    // Unit tests use `test` / `check`; integration tests use
    // `test-integration` / `check-integration`.

    // `zig build test` is the CI entry point and must stay self-contained: pure
    // unit tests only, no windows/SDL/Velopack/MSVC. Glass arithmetic uses dvui types.
    // Integration tests live under `zig build test-integration`
    // (Velopack + dvui-testing + comctl32 on Windows
    // → needs MSVC SDK on Windows hosts). `zig build test-all` runs both.
    const test_step = b.step("test", "Run fizzy unit tests (pure-logic only, no windows/SDL/Velopack)");

    // `check` mirrors the split so editor compile-error checking matches CI.
    const check_step = b.step("check", "Compile fizzy unit tests without running them");

    // Zig collects `test` blocks only from files belonging to an artifact's **root
    // module** — a file pulled in as a *named* import (`addImport` /
    // `addAnonymousImport`) is a separate module whose tests are never run. That is
    // how `fizzy-unit-tests` silently ran zero tests behind a green build. So: one
    // `addTest` per pure-logic root, each rooted directly at the file under test.
    // Files reached from such a root by relative `@import` (the registry client's
    // registry/compat/download, say) are part of the same module and *are* collected.
    var unit_test_artifacts: std.ArrayList(*std.Build.Step.Compile) = .empty;

    inline for (.{
        .{ "fizzy-lint-tests", "scripts/lint.zig" },
        .{ "fizzy-direction-tests", "core/math/direction.zig" },
        .{ "fizzy-easing-tests", "core/math/easing.zig" },
        .{ "fizzy-layout-anchor-tests", "core/math/layout_anchor.zig" },
        .{ "fizzy-plugin-store-tests", "app/store/registry/store.zig" },
        .{ "fizzy-paths-tests", "core/paths.zig" },
        // `core.viz`'s arithmetic: a chart's scale, the slot under the pointer, a bar's fill.
        .{ "fizzy-viz-scale-tests", "core/viz/scale.zig" },
        // The profiler's lookback: 30 seconds of windows a reader can sum over, and the frames
        // that went over budget.
        .{ "fizzy-profile-lookback-tests", "core/profile/Lookback.zig" },
        // Spans on any thread: kept whole while threads write at once, summed by name, and
        // written as a Chrome trace that reads back as JSON.
        .{ "fizzy-profile-spans-tests", "core/profile/Spans.zig" },
        .{ "fizzy-profile-causes-tests", "core/profile/FrameCauses.zig" },
        // The login-shell PATH cache: it owns its string whatever allocator the first caller
        // passed, and threads that ask at once resolve once. The shell spawn itself is not run.
        .{ "fizzy-shell-env-tests", "core/shell_env.zig" },
        // The environment a macOS spawn hands its child: the fixed allowlist plus only the names a
        // caller opted in. The test skips off macOS; the root keeps it reached.
        .{ "fizzy-darwin-spawn-tests", "core/darwin_spawn.zig" },
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
        // `FIZZY_QUIET`: read from the environment (the flag is `single_instance.resolveArgs`).
        // std-only.
        .{ "fizzy-quiet-tests", "app/quiet.zig" },
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
        // Mobile, tablet or desktop from the page's pointer and viewport. std-only (see
        // form_factor.zig); `platform.zig` holds the live value.
        .{ "fizzy-form-factor-tests", "core/form_factor.zig" },
        // Fade / blur-fade timeline. std-only (see crossfade.zig) — pictures and the clock
        // live in core/anim.zig.
        .{ "fizzy-crossfade-tests", "core/crossfade.zig" },
        // Hold / slop / tap rules of touch selection. std-only (see TouchHold.zig) — the dvui
        // half is widgets/SelectableText.zig.
        .{ "fizzy-touch-hold-tests", "core/TouchHold.zig" },
        .{ "fizzy-person-tests", "core/person.zig" },
        // A motion's clock stepped by its frames, a long one held to a step. std-only (see
        // FrameClock.zig); the floats' landing and ghost run on it.
        .{ "fizzy-frame-clock-tests", "backend/src/glass/FrameClock.zig" },
        // Variable-height row bookkeeping for a virtualized list. std-only, so anchors, measurements
        // and width changes are tested without a Window.
        .{ "fizzy-height-index-tests", "core/HeightIndex.zig" },
        // Ring buffering and dot-segment filtering for the folder watcher. std-only so it can
        // be tested here; FolderWatcher.zig itself needs a live editor.
        .{ "fizzy-folder-events-tests", "app/watch/folder_events.zig" },
        // Where a macOS bundle runs from: whether it updates, is offered the move to
        // /Applications, and what happens to the copy it leaves. std-only (see
        // install_location.zig); `macos_bundle.zig` asks the system and acts on it.
        .{ "fizzy-install-location-tests", "app/update/install_location.zig" },
        // The command palette's recently used commands: order, re-use, the cap. std-only
        // (see RecentCommands.zig); `Recents` holds it and stores it in recents.zon.
        .{ "fizzy-recent-commands-tests", "app/RecentCommands.zig" },
        // Which plugin folders a case variant clashes with, and what an uninstall may delete
        // there. std-only (see plugin_folders.zig); the store and the loader ask it.
        .{ "fizzy-plugin-folders-tests", "app/store/plugin_folders.zig" },
        // Where a floating view's window opens, what keeps it reachable, its name, the floats'
        // stacking and where a closed float's views go. std-only (see float_rules.zig);
        // `Floats.zig` and `ViewDrag.zig` apply it, covered by `tests/integration.zig`.
        .{ "fizzy-float-rules-tests", "app/layout/float_rules.zig" },
        // Where a new view goes by the shape of the room, and which way an adaptive split runs.
        // std-only (see placement.zig); the workbench and the docking widget ask it.
        .{ "fizzy-placement-tests", "core/placement.zig" },
        // Std-only card level hysteresis and visibility during shell size changes.
        .{ "fizzy-card-level-tests", "core/card_level.zig" },
        // Keyed layout motion and release arithmetic, independent of drawing.
        .{ "fizzy-rearrange-tests", "core/rearrange.zig" },
        // A document state as the bytes that differ from another: how a track's checkpoints
        // stay small. std-only (see state_delta.zig); `Tracks` keeps its checkpoints with it.
        .{ "fizzy-state-delta-tests", "app/state_delta.zig" },
        // A state packed for a track file (zero runs, then deflate): lossless, so a canvas of
        // transparent pixels is not stored as tens of megabytes. std-only (see state_pack.zig).
        .{ "fizzy-state-pack-tests", "app/state_pack.zig" },
        // Image diff (RGBA8 to rects) and text diff (histogram lines, unified output). std-only
        // (see
        // core/diff.zig); `bench-diff` measures it.
        .{ "fizzy-diff-tests", "core/diff.zig" },
        // When a document's transport shows and for how long, how far a held undo goes, which
        // step a point on its line is. std-only (see history_transport.zig); `HistoryTransport`
        // draws it.
        .{ "fizzy-history-transport-tests", "app/history_transport.zig" },
        // How high the activity feed stands as what is under it comes and goes: eased on a change,
        // following its target otherwise. std-only (see feed_lift.zig); `ActivityFeed` draws it.
        .{ "fizzy-feed-lift-tests", "app/feed_lift.zig" },
        // A transport's dome: how long the pointer is held before its bar grows, how full it
        // is, its liquid's swing and shapes. std-only (see dome_rules.zig); `dome.zig` draws it.
        .{ "fizzy-dome-tests", "app/dome_rules.zig" },
        // The control server's JSON at its edge, ZON inside, and its transport: a request over
        // the socket reaching the UI thread and its answer going back. std-only (see
        // control/json.zig, control/Server.zig); `control/routes.zig` answers over the Host,
        // covered by `tests/integration.zig`.
        .{ "fizzy-control-json-tests", "app/control/json.zig" },
        // MCP tool names from command ids and back, and which id keeps a shared name. std-only
        // (see mcp_names.zig); `mcp.zig` applies it to the registry.
        .{ "fizzy-mcp-names-tests", "app/mcp_names.zig" },
        .{ "fizzy-control-server-tests", "app/control/Server.zig" },
        // The screen as changes on a base: keys that stay put, and what changed between two.
        .{ "fizzy-control-screen-diff-tests", "app/control/screen_diff.zig" },
        // One material on two sliders: what every glass is at the window's opacity and roughness,
        // the OS's form and the app's. std-only (see glass_look.zig); `LiquidField` and `Popout`
        // apply it.
        .{ "fizzy-glass-look-tests", "backend/src/glass_look.zig" },
        // What the app's windows are made of, and the fallback to what the backend can show.
        // std-only but for `publish`/`get`, which reach dvui and are not under test here.
        .{ "fizzy-material-tests", "core/material.zig" },
        // An orb's geometry: shapes, how one becomes another, the polygons the no-glass path fills
        // (plans/LIQUID_EDGE_PLAN.md, "The orb system"). std-only.
        .{ "fizzy-orb-geometry-tests", "core/orb_geometry.zig" },
        // The liquid in a history vial: its waves, its drops, and when it is still. std-only.
        .{ "fizzy-liquid-tests", "app/Liquid.zig" },
        // The in-app menu bar's order: fizzy's menus, then plugins', then Help. std-only (see
        // menu_order.zig); `Menu.draw` walks it.
        .{ "fizzy-menu-order-tests", "src/editor/menu_order.zig" },
        // Demo automation's std-only core (`sdk/tape/`): the tape format and its codecs, the
        // sequencer that replays it deterministically, the script builder and key spelling. The
        // dvui half (`sdk/replay/`) compiles on its own below, and is covered by
        // `tests/integration.zig`.
        .{ "fizzy-tape-tests", "sdk/tape/root.zig" },
        // Where Report a Bug goes when the build isn't told. std-only (see issues_url.zig); the
        // build is its only user.
        .{ "fizzy-issues-url-tests", "build/issues_url.zig" },
        // The default bundle id an app built on fizzy gets. std-only, like issues_url.zig.
        .{ "fizzy-bundle-id-tests", "build/bundle_id.zig" },
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
    const tour_tests = b.addTest(.{
        .name = "fizzy-tour-tests",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/editor/demos/tour.zig"),
        }),
        .filters = test_filters,
    });
    tour_tests.root_module.addImport("tape", b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.dependency("fizzy_sdk", .{}).path("tape/root.zig"),
    }));
    try unit_test_artifacts.append(b.allocator, tour_tests);

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
            .root_source_file = b.dependency("fizzy_sdk", .{}).path("tape/root.zig"),
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

    {
        // The remote-view protocol (`sdk/remote/`, plans/EMBEDDED_EDITOR_PLAN.md steps 2 and 5):
        // messages, framing, the connection rules, and the client that finds, starts and connects
        // to fizzy, against a fake fizzy executable built here. std-only, so a host's adapter can
        // link it.
        const fake_fizzy = b.addExecutable(.{
            .name = "fake-fizzy",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .root_source_file = b.dependency("fizzy_sdk", .{}).path("remote/fake_fizzy.zig"),
            }),
        });
        const fake_options = b.addOptions();
        fake_options.addOptionPath("fake_fizzy", fake_fizzy.getEmittedBin());
        const remote_tests = b.addTest(.{
            .name = "fizzy-remote-tests",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .root_source_file = b.dependency("fizzy_sdk", .{}).path("remote/root.zig"),
                .imports = &.{.{ .name = "fake_fizzy_options", .module = fake_options.createModule() }},
            }),
            .filters = test_filters,
        });
        try unit_test_artifacts.append(b.allocator, remote_tests);
    }

    const dvui_testing_dep = sdk.dvuiDependency(b, .{
        .target = target,
        .optimize = optimize,
        .backend = .testing,
        .accesskit = accesskit,
    });

    // Shared `core` module for the test build (dvui testing backend variant).
    const core_module_test = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("core/core.zig"),
    });
    const icons_test = core_mod.addImports(
        b,
        core_module_test,
        dvui_testing_dep.module("dvui_testing"),
        b.dependency("fizzy_sdk", .{}).builder,
        target,
        optimize,
        null,
        null,
    );

    // The liquid field's packing and edge-light arithmetic needs dvui's geometry types,
    // but no Window or native backend. Keep it in `test`, apart from the glass window tests.
    const liquid_field_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("backend/src/glass/liquid_field_tests.zig"),
    });
    liquid_field_module.addImport("dvui", dvui_testing_dep.module("dvui_testing"));
    liquid_field_module.addImport("glass_look", core_module_test.import_table.get("glass_look").?);
    try unit_test_artifacts.append(b.allocator, b.addTest(.{
        .name = "fizzy-liquid-field-tests",
        .root_module = liquid_field_module,
        .filters = test_filters,
    }));

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
    const test_integration_step = b.step(
        "test-integration",
        "Run fizzy headless integration tests (dvui-testing; needs MSVC on Windows)",
    );
    const check_integration_step = b.step("check-integration", "Compile fizzy integration tests without running them");
    const test_all_step = b.step("test-all", "Run unit + integration tests");
    test_all_step.dependOn(test_step);
    test_all_step.dependOn(test_integration_step);

    const test_sdk_version_step = b.step(
        "test-sdk-version",
        "Verify SDK version ↔ ABI fingerprint lock (compiles SDK + plugin dylib)",
    );
    const sdk_probe = for (main_fizzy.dylibs) |dylib| {
        if (std.mem.eql(u8, dylib.id, "workbench")) break dylib.compile;
    } else exe;
    test_sdk_version_step.dependOn(&sdk_probe.step);
    test_all_step.dependOn(test_sdk_version_step);

    if (velopack_required_fail) |fail_step| {
        test_integration_step.dependOn(fail_step);
        check_integration_step.dependOn(fail_step);
        return;
    }

    const dvui_test_proxy_bridge = sdk.addProxyBridgeModule(
        b,
        target,
        optimize,
        dvui_testing_dep,
        dvui_testing_dep.module("dvui_testing"),
    );

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
    fizzy_test_module.addImport(
        "viewports_none",
        @import("fizzy_backend").viewportsNoneModule(
            fizzy_exe.backendDependency(b),
            dvui_testing_dep.module("dvui_testing"),
        ),
    );
    fizzy_test_module.addImport("assets", assets_module);
    fizzy_test_module.addImport("app_icon", app_icon_module);
    fizzy_test_module.addImport("build_opts", sdk.buildOptsModule(build_opts));

    fizzy_test_module.addImport("core", core_module_test);
    if (icons_test) |icons| fizzy_test_module.addImport("icons", icons);

    // `replay` (`sdk/replay/`) on its own: dvui and `tape`, nothing of fizzy's. A reach into
    // `core` or `app` fails to compile here, which is what keeps it a library any dvui app can
    // take (`plans/AUTOMATION_PLAN.md`, "The libraries").
    {
        const replay_only = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.dependency("fizzy_sdk", .{}).path("replay/root.zig"),
        });
        replay_only.addImport("dvui", dvui_testing_dep.module("dvui_testing"));
        replay_only.addImport("tape", b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.dependency("fizzy_sdk", .{}).path("tape/root.zig"),
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

    const sdk_module_test = sdk.wireSdkModule(
        b,
        target,
        optimize,
        dvui_testing_dep.module("dvui_testing"),
        dvui_test_proxy_bridge,
        core_module_test,
        fizzy_test_module,
    );
    if (cfg.app_is_fizzy) {
        const fixture = rehome_fixture.graph(b, target, optimize);
        const consumer = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
        const module = @import("plugins.zig").rehome(b, .{
            .target = target,
            .optimize = optimize,
            .dvui = dvui_testing_dep.module("dvui_testing"),
            .core = core_module_test,
            .sdk = sdk_module_test,
            .icons = icons_test,
            .backend = null,
            .workbench_opts = workbench_opts,
            .consumer = consumer,
        }, "rehome_fixture", fixture);
        // The same target as the source: the independent module is shared, the rest copied.
        rehome_fixture.check(b, fixture, module, true);
        const fixture_test = b.addTest(.{ .name = "rehome-fixture", .root_module = module });
        test_step.dependOn(&b.addRunArtifact(fixture_test).step);
    }
    // What a plugin does with `tape` and `replay` (`tests/fixtures/tape-plugin/play.zig`), through
    // the path an application's plugin takes: its own `staticModule`, then `rehome` onto this
    // executable's framework. The fixture's own build tests the same file as a dylib.
    // Fizzy's own build only: the fixture is not in `.paths`, so an app fetching fizzy lacks it.
    if (cfg.app_is_fizzy) if (b.lazyDependency("tape_fixture", .{})) |fixture_dep| {
        const source = b.lazyImport(@This(), "tape_fixture").?.staticModule(fixture_dep.builder, .{
            .target = target,
            .optimize = optimize,
            .dvui = dvui_testing_dep.module("dvui_testing"),
            .core = core_module_test,
            .sdk = sdk_module_test,
            .icons = icons_test,
        });
        const consumer = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
        const module = @import("plugins.zig").rehome(b, .{
            .target = target,
            .optimize = optimize,
            .dvui = dvui_testing_dep.module("dvui_testing"),
            .core = core_module_test,
            .sdk = sdk_module_test,
            .icons = icons_test,
            .backend = null,
            .workbench_opts = workbench_opts,
            .consumer = consumer,
        }, "tape_fixture", source);
        const play_tests = b.addTest(.{
            .name = "fizzy-tape-plugin-bundled-tests",
            .root_module = module,
            .filters = test_filters,
        });
        test_integration_step.dependOn(&b.addRunArtifact(play_tests).step);
        check_integration_step.dependOn(&play_tests.step);
    };
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
    const app_module_test = sdk.wireAppModule(
        b,
        target,
        optimize,
        dvui_testing_dep.module("dvui_testing"),
        core_module_test,
        sdk_module_test,
        icons_test,
        markdown_module_test,
        if (nightwatch_test_dep) |dep| dep.module("nightwatch") else null,
        build_opts,
        singleton_test_dep.module("singleton_app"),
        fizzy_test_module,
    );
    const image_module_test = image_plugin.addStaticModule(b, target, optimize, .{
        .dvui = dvui_testing_dep.module("dvui_testing"),
        .core = core_module_test,
        .sdk = sdk_module_test,
        .icons = icons_test,
    }, fizzy_test_module);
    const devtools_module_test = plugins.devtools.addStaticModule(b, target, optimize, .{
        .dvui = dvui_testing_dep.module("dvui_testing"),
        .core = core_module_test,
        .sdk = sdk_module_test,
    }, fizzy_test_module);
    const dashboard_module_test = plugins.dashboard.addStaticModule(b, target, optimize, .{
        .dvui = dvui_testing_dep.module("dvui_testing"),
        .core = core_module_test,
        .sdk = sdk_module_test,
    }, fizzy_test_module);
    // A `.zip` opened as a mounted folder, as the web opens the site (`tests/demos.zig`).
    const archive_module_test = plugins.archive.addStaticModule(b, target, optimize, .{
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
        .{ .name = "devtools", .module = devtools_module_test },
        .{ .name = "dashboard", .module = dashboard_module_test },
        .{ .name = "archive", .module = archive_module_test },
    }));

    if (target.result.os.tag == .macos) {
        if (@import("fizzy_backend").objcModule(
            fizzy_exe.backendDependency(b),
            fizzy_exe.backendOptions(target, optimize, macos_sdl_paths),
        )) |objc| {
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
    integration_module.addImport("dashboard", dashboard_module_test);
    integration_module.addAnonymousImport("markdown_sample", .{ .root_source_file = b.path("docs/PLUGINS.md") });
    // The synthetic document with the 48KB table of wrapping cells — the case table-row culling
    // exists for, and the one it could get wrong. Generated by `markdown_sample_tables.py` beside
    // it.
    integration_module.addAnonymousImport(
        "markdown_sample_tables",
        .{ .root_source_file = b.path("tests/data/markdown_sample_tables.md") },
    );
    // The image-heavy fixture. Both docs above are prose and tables, so without this no test ever
    // laid out an image block — the one block kind whose height nothing in the source predicts
    // and which rescales with the pane right up until the pane is wider than the image.
    integration_module.addAnonymousImport(
        "markdown_sample_images",
        .{ .root_source_file = b.path("tests/data/markdown_sample_images.md") },
    );
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
    integration_module.addAnonymousImport(
        "soak_expect",
        .{ .root_source_file = b.path("tests/tapes/soak.expect.zon") },
    );

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
        try velopack.linkVelopack(
            b,
            v,
            integration_tests,
            .{ .target = target, .optimize = optimize, .c_modules = &.{app_module_test} },
        );
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
            try velopack.linkVelopack(
                b,
                v,
                demo_tests,
                .{ .target = target, .optimize = optimize, .c_modules = &.{app_module_test} },
            );
        };
        test_integration_step.dependOn(&b.addRunArtifact(demo_tests).step);
        check_integration_step.dependOn(&demo_tests.step);
    }

    {
        const fuzz_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("tests/fuzz_tapes.zig"),
        });
        fuzz_module.addImport("fizzy", fizzy_test_module);
        fuzz_module.addImport("dvui", dvui_testing_dep.module("dvui_testing"));
        fuzz_module.addImport("app", app_module_test);
        fuzz_module.addImport("workbench", workbench_module_test);
        fuzz_module.addAnonymousImport("hello", .{ .root_source_file = b.path("docs/demos/hello.zon") });
        const fuzz_tests = b.addTest(.{
            .name = "fizzy-fuzz-tapes",
            .root_module = fuzz_module,
            .filters = test_filters,
        });
        if (target.result.os.tag == .windows) fuzz_tests.root_module.linkSystemLibrary("comctl32", .{});
        fuzz_tests.root_module.link_libcpp = !target_is_windows_msvc;
        if (velopack_enabled) if (vz) |v| {
            try velopack.linkVelopack(
                b,
                v,
                fuzz_tests,
                .{ .target = target, .optimize = optimize, .c_modules = &.{app_module_test} },
            );
        };
        // Its output is the report, so a cached run must not hide it.
        const fuzz_run = b.addRunArtifact(fuzz_tests);
        fuzz_run.has_side_effects = true;
        b.step("fuzz-tapes", "Explore seeded tape interruptions and print shrunk findings")
            .dependOn(&fuzz_run.step);
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

    // The markdown preview's claims about what md4c parses: the AST built from its events and
    // `[[wikilink]]` escaping. They need md4c linked, so they sit outside the std-only list;
    // `wikilink_scan.zig` reaches `ast.zig`. The plugin's own `zig build test` runs the same.
    {
        const md_parser_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("plugins/markdown/src/md/wikilink_scan.zig"),
        });
        md_parser_module.addImport("fizzy_sdk", sdk_module_test);
        plugins.markdown.addMd4zig(b, target, optimize, md_parser_module);
        const md_parser_tests = b.addTest(.{
            .name = "fizzy-md-parser-tests",
            .root_module = md_parser_module,
            .filters = test_filters,
        });
        test_integration_step.dependOn(&b.addRunArtifact(md_parser_tests).step);
        check_integration_step.dependOn(&md_parser_tests.step);
    }

    // The frame profiler's own tests (`core/profile.zig`): it publishes itself through dvui's
    // window store and reads dvui's clock, so it is not one of the std-only roots above, and as
    // part of the named `core` module its tests were never collected. Rooted at the file, against
    // dvui's testing backend.
    {
        const profile_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("core/profile.zig"),
        });
        profile_module.addImport("dvui", dvui_testing_dep.module("dvui_testing"));
        // `core/profile.zig` times the in-app glass through `glass.prof`.
        profile_module.addImport("glass", core_module_test.import_table.get("glass").?);
        const profile_tests = b.addTest(.{
            .name = "fizzy-profile-tests",
            .root_module = profile_module,
            .filters = test_filters,
        });
        if (target.result.os.tag == .windows) profile_tests.root_module.linkSystemLibrary("comctl32", .{});
        profile_tests.root_module.link_libcpp = !target_is_windows_msvc;
        test_integration_step.dependOn(&b.addRunArtifact(profile_tests).step);
        check_integration_step.dependOn(&profile_tests.step);
    }

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
        bench_module.addAnonymousImport(
            "sample_prose",
            .{ .root_source_file = b.path("tests/data/markdown_sample_tables.md") },
        );
        bench_module.addAnonymousImport("sample_medium", .{ .root_source_file = b.path("AGENTS.md") });
        bench_module.addAnonymousImport(
            "sample_small",
            .{ .root_source_file = b.path("docs/MODULARIZATION_RELEASE_NOTES.md") },
        );

        const bench_markdown = b.addTest(.{ .name = "fizzy-bench-markdown", .root_module = bench_module });
        bench_markdown.root_module.link_libcpp = !target_is_windows_msvc;
        if (target.result.os.tag == .windows) {
            bench_markdown.root_module.linkSystemLibrary("comctl32", .{});
        }

        const bench_step = b.step(
            "bench-markdown",
            "Benchmark the markdown preview's per-frame draw cost (prints timings)",
        );
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
            try velopack.linkVelopack(
                b,
                v,
                bench_replay,
                .{ .target = target, .optimize = optimize, .c_modules = &.{app_module_test} },
            );
        };

        const check_bench_replay_step = b.step("check-bench-replay", "Compile fizzy bench-replay without running it");
        check_bench_replay_step.dependOn(&bench_replay.step);

        const bench_step = b.step(
            "bench-replay",
            "Benchmark a demo seek, silent against shown frame by frame (prints timings)",
        );
        const run_bench = b.addRunArtifact(bench_replay);
        run_bench.has_side_effects = true;
        bench_step.dependOn(&run_bench.step);
    }

    // `zig build bench-tracks` — what a document's track costs (`app.Tracks`): a step, a frame's
    // top idle and with a checkpoint, a replay, what a session holds. Same rules as `bench-text`.
    {
        const bench_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("tests/bench/bench_tracks.zig"),
        });
        bench_module.addImport("app", app_module_test);
        bench_module.addImport("fizzy_sdk", sdk_module_test);

        const bench_tracks = b.addTest(.{ .name = "fizzy-bench-tracks", .root_module = bench_module });
        bench_tracks.root_module.link_libcpp = !target_is_windows_msvc;
        if (target.result.os.tag == .windows) {
            bench_tracks.root_module.linkSystemLibrary("comctl32", .{});
        }
        if (velopack_enabled) if (vz) |v| {
            try velopack.linkVelopack(b, v, bench_tracks, .{ .target = target, .optimize = optimize });
        };

        const bench_step = b.step(
            "bench-tracks",
            "Benchmark a document's track: steps, checkpoints, replays (prints timings)",
        );
        const run_bench = b.addRunArtifact(bench_tracks);
        run_bench.has_side_effects = true;
        bench_step.dependOn(&run_bench.step);
    }

    // `zig build bench-diff` — core.diff on a 4K image, a 2048x2048 sprite of 50 layers and 1 MB of
    // text (prints
    // timings). Same rules as `bench-tape`; std-only, so it needs no window.
    {
        const bench_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("tests/bench/bench_diff.zig"),
        });
        bench_module.addImport("diff", b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("core/diff.zig"),
        }));
        const bench_diff = b.addTest(.{ .name = "fizzy-bench-diff", .root_module = bench_module });

        const bench_step = b.step(
            "bench-diff",
            "Benchmark core.diff: a 4K image, a 50-layer sprite, 1 MB of text (prints timings)",
        );
        const run_bench = b.addRunArtifact(bench_diff);
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
            .root_source_file = b.dependency("fizzy_sdk", .{}).path("tape/root.zig"),
        }));
        const bench_tape = b.addTest(.{ .name = "fizzy-bench-tape", .root_module = bench_module });

        const bench_step = b.step(
            "bench-tape",
            "Benchmark saving and loading demo tapes, ZON against binary (prints timings)",
        );
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
        const sdk_tests_module = sdk.wireSdkModule(
            b,
            target,
            optimize,
            dvui_testing_dep.module("dvui_testing"),
            dvui_test_proxy_bridge,
            core_module_test,
            null,
        );
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
        split_tests_module.addImport("tape", core_module_test.import_table.get("tape").?);
        split_tests_module.addImport("replay", core_module_test.import_table.get("replay").?);
        split_tests_module.addImport("glass_look", core_module_test.import_table.get("glass_look").?);
        split_tests_module.addImport("glass", core_module_test.import_table.get("glass").?);

        // The in-app glass (`backend/src/glass/root.zig`): the frost's capture sizes and the
        // blobs' smooth union, over dvui's testing backend.
        const glass_tests_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("backend/src/glass/root.zig"),
        });
        glass_tests_module.addImport("dvui", dvui_testing_dep.module("dvui_testing"));
        glass_tests_module.addImport("glass_look", core_module_test.import_table.get("glass_look").?);

        inline for (.{
            .{ "fizzy-sdk-tests", sdk_tests_module },
            .{ "fizzy-sizing-tests", split_tests_module },
            .{ "fizzy-glass-tests", glass_tests_module },
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

    // The text plugin's own tests: its entry widget's buffer handling, against a real headless
    // Window. The integration tests import the plugin as a module, and `addTest` collects only
    // from its root module, so they never ran these.
    {
        const text_plugin_tests = b.addTest(.{
            .name = "fizzy-text-plugin-tests",
            .root_module = text_module_test,
            .filters = test_filters,
        });
        text_plugin_tests.root_module.link_libcpp = !target_is_windows_msvc;
        test_integration_step.dependOn(&b.addRunArtifact(text_plugin_tests).step);
        check_integration_step.dependOn(&text_plugin_tests.step);
    }

    // The dashboard plugin's own tests (its carousel state and demo provider). The integration
    // tests import it as a module, and `addTest` collects only from a root module.
    {
        const dashboard_plugin_tests = b.addTest(.{
            .name = "fizzy-dashboard-plugin-tests",
            .root_module = dashboard_module_test,
            .filters = test_filters,
        });
        test_integration_step.dependOn(&b.addRunArtifact(dashboard_plugin_tests).step);
        check_integration_step.dependOn(&dashboard_plugin_tests.step);
    }

    // Give the file extension tests a root; the plugin's lazy exports do not collect them.
    {
        const files_tests_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("plugins/workbench/src/files.zig"),
        });
        var imports = workbench_module_test.import_table.iterator();
        while (imports.next()) |entry| {
            files_tests_module.addImport(entry.key_ptr.*, entry.value_ptr.*);
        }
        const workbench_tests = b.addTest(.{
            .name = "fizzy-workbench-plugin-tests",
            .root_module = files_tests_module,
            .filters = test_filters,
        });
        test_integration_step.dependOn(&b.addRunArtifact(workbench_tests).step);
        check_integration_step.dependOn(&workbench_tests.step);
    }

    // Every `test` block in the repo is in a binary some step builds (`scripts/tests_reached.zig`):
    // `test`, `test-integration`, a `bench-*`. The binaries come from the steps themselves, so a
    // test root added to any of them is counted without being listed here.
    {
        const tool = b.addExecutable(.{
            .name = "tests-reached",
            .root_module = b.createModule(.{
                .target = b.graph.host,
                .root_source_file = b.path("scripts/tests_reached.zig"),
            }),
        });
        const run = b.addRunArtifact(tool);
        run.addDirectoryArg(b.path("."));
        var seen: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
        for (b.top_level_steps.values()) |top| try addTestBinaryArgs(b, run, &seen, &top.step);
        b.step("check-tests-reached", "Check every test block is compiled into a test that runs").dependOn(&run.step);
    }

    if (win_libc.needs_setup) if (msvcup_before_compile) |msvcup| {
        exe.step.dependOn(&msvcup.step);
        if (!velopack_enabled and velopack_supported_for_target) {
            exe_for_package.step.dependOn(&msvcup.step);
        }
        integration_tests.step.dependOn(&msvcup.step);
        for (unit_test_artifacts.items) |unit_test| unit_test.step.dependOn(&msvcup.step);
        inline for (.{ main_fizzy, package_fizzy }) |fizzy_exe_result| {
            for (fizzy_exe_result.dylibs) |dylib| dylib.compile.step.dependOn(&msvcup.step);
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
            for (fizzy_exe_result.dylibs) |dylib| {
                roots[n] = dylib.compile;
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
            const libc_lp: std.Build.LazyPath = .{ .cwd_relative = ini };
            velopack.applyWindowsMsvcLibcRecursive(b, roots[0..n], libc_lp);

            // Absolute, and already declared to the configure cache where it was resolved
            // (`velopack.resolveWindowsMsvcLibc`).
            const ini_exists = blk: {
                std.Io.Dir.cwd().access(b.graph.io, ini, .{}) catch break :blk false;
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

/// Each test compile `step` depends on, through its run steps, as `<root source file> <binary>`
/// arguments of `run`. A compile's own dependencies are other compiles, not tests, so the walk
/// stops at one.
fn addTestBinaryArgs(
    b: *std.Build,
    run: *std.Build.Step.Run,
    seen: *std.AutoHashMapUnmanaged(*std.Build.Step, void),
    step: *std.Build.Step,
) !void {
    for (step.dependencies.items) |dep| {
        if ((try seen.getOrPut(b.allocator, dep)).found_existing) continue;
        if (dep.cast(std.Build.Step.Compile)) |compile| {
            if (compile.kind != .@"test") continue;
            run.addFileArg(compile.root_module.root_source_file.?);
            run.addArtifactArg(compile);
        } else try addTestBinaryArgs(b, run, seen, dep);
    }
}
