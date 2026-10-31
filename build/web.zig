const std = @import("std");
const common = @import("common.zig");
const helpers = @import("../plugins/shared/build/helpers.zig");
const core_mod = @import("fizzy_sdk").core_module;
const plugins = @import("plugins.zig");
const sdk = @import("sdk.zig");
const rehome_fixture = @import("rehome_fixture.zig");

/// What `build` made: the wasm module, and the site around it.
pub const Web = struct {
    wasm: *std.Build.Step.Compile,
    /// The whole site, deployable as it is: `files` and `page`.
    site: std.Build.LazyPath,
    /// Everything but the page: the wasm, `fizzy.js`, `web.js`, the worker, the font, the OAuth page, the
    /// hosted demo tapes under `demos/` (fizzy's own build) and each plugin's pages under
    /// `plugins/<id>/`.
    files: std.Build.LazyPath,
    /// `index.html`, stamped with `fizzy.js`'s hash.
    page: std.Build.LazyPath,
    /// Fizzy's own build: a native-built plugin graph re-homed to wasm32 and compiled apart from
    /// the app, for `check-web`.
    rehome_fixture: ?*std.Build.Step.Compile,
    /// The hosted demo tapes alone (fizzy's own build), which the `demos` step installs without
    /// building the rest of the site.
    demos: ?std.Build.LazyPath,
};

pub fn target(b: *std.Build) std.Build.ResolvedTarget {
    return b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_features_add = std.Target.wasm.featureSet(&.{
            .atomics,
            .multivalue,
            .bulk_memory,
        }),
    });
}

/// What the web executable links and builds its plugins against (`exe.NativeFramework`'s twin).
pub const Framework = struct {
    dvui_dep: *std.Build.Dependency,
    dvui: *std.Build.Module,
    backend: *std.Build.Module,
    core: *std.Build.Module,
    sdk: *std.Build.Module,
    icons: ?*std.Build.Module,
};

pub fn framework(b: *std.Build, optimize: std.lang.OptimizeMode) Framework {
    const web_target = target(b);
    // The web backend is fizzy's own (`src/backend/WebBackend.zig` + dvui's `web.js`, patched:
    // `patchedWebJs`), started as a copy of dvui's: dvui is built in its `custom` mode and our backend linked to it, as dvui's
    // build does for its own (`linkBackend`). Every option is the one dvui's `web` mode sets, so
    // dvui's shape — and with it the plugin fingerprint — is exactly what it was.
    const dvui_web_dep = sdk.dvuiDependency(b, .{
        .target = web_target,
        .optimize = optimize,
        .backend = .custom,
        .@"vertex-index" = .u16,
        .libc = false,
        .freetype = false,
        .@"tiny-file-dialogs" = false,
        .@"stb-image" = true,
        .@"tree-sitter" = false,
    });
    const dvui_web = dvui_web_dep.module("dvui");
    dvui_web.single_threaded = true;
    const web_backend = b.createModule(.{
        .root_source_file = b.path("src/backend/WebBackend.zig"),
        .target = web_target,
        .optimize = optimize,
        .single_threaded = true,
    });
    // What the page calls into (`web.js`): dvui's web exports.
    web_backend.export_symbol_names = &.{
        "dvui_init",
        "dvui_deinit",
        "dvui_update",
        "add_event",
        "arena_u8",
        "gpa_u8",
        "gpa_free",
        "new_font",
    };
    web_backend.addImport("dvui", dvui_web);
    dvui_web.addImport("backend", web_backend);
    const dvui_web_proxy_bridge = sdk.addProxyBridgeModule(b, web_target, optimize, dvui_web_dep, dvui_web);

    // Shared `core` module for the wasm build (dvui web backend variant).
    const core_module_web = b.createModule(.{
        .target = web_target,
        .optimize = optimize,
        .root_source_file = b.path("core/core.zig"),
        .link_libc = false,
        .single_threaded = true,
    });
    const icons_web = core_mod.addImports(
        b,
        core_module_web,
        dvui_web,
        b.dependency("fizzy_sdk", .{}).builder,
        web_target,
        optimize,
        null,
        null,
    );
    // The motion clock the backend's `nanoTime` runs on (`glass.MotionClock`).
    web_backend.addImport("glass", core_module_web.import_table.get("glass").?);
    return .{
        .dvui_dep = dvui_web_dep,
        .dvui = dvui_web,
        .backend = web_backend,
        .core = core_module_web,
        .sdk = sdk.wireSdkModule(b, web_target, optimize, dvui_web, dvui_web_proxy_bridge, core_module_web, null),
        .icons = icons_web,
    };
}

/// The web (wasm) build, apart from the native exe so it cannot disturb packaging, SDL or
/// Velopack. Adds no step of its own; `install` puts it under `zig-out/web/`.
pub fn build(
    b: *std.Build,
    fw: Framework,
    optimize: std.lang.OptimizeMode,
    build_opts: *std.Build.Step.Options,
    workbench_opts: *std.Build.Step.Options,
    assets_module: *std.Build.Module,
    /// The window's icon (`app.Branding.png`); `src/Entry.zig` imports it.
    app_icon_module: *std.Build.Module,
    app_layout: ?std.Build.LazyPath,
    app_plugins: []const sdk.BundledPlugin,
    web_plugin_deps: []const []const u8,
    web_plugin_dirs: []const @import("app.zig").WebPluginDir,
    /// Fizzy's own build (`Options.own`): the hosted demo tapes come from `docs/demos/` and
    /// `scripts/`, which fizzy's package leaves out, so an app built on fizzy has none.
    own: bool,
) Web {
    const web_target = target(b);
    const dvui_web_dep = fw.dvui_dep;
    const dvui_web = fw.dvui;
    const web_backend = fw.backend;

    const web_exe = b.addExecutable(.{
        .name = "web",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/web_main.zig"),
            .target = web_target,
            .optimize = optimize,
            .link_libc = false,
            .single_threaded = true,
            .strip = optimize == .fast or optimize == .small,
        }),
    });
    web_exe.entry = .disabled;
    web_exe.root_module.addImport("dvui", dvui_web);
    // A page has one canvas: `backend_web.viewports`.
    web_exe.root_module.addImport(
        "viewports_none",
        @import("fizzy_backend").viewportsNoneModule(@import("exe.zig").backendDependency(b), dvui_web),
    );
    web_exe.root_module.addImport("web-backend", web_backend);

    // Extra wasm exports beyond dvui's own (`dvui_init`/`dvui_update`/etc.). The wasm
    // linker only emits symbols listed here, so `export fn` in Zig isn't enough on its
    // own — without this line our trackpad pinch entry point would compile cleanly but
    // be missing from `instance.exports`, and the JS bootstrap in `web/fizzy.js`
    // would never be able to forward pinch deltas into the canvas widget. The image
    // trio is the other half of that seam: JS rasterizes a remote URL and writes the
    // pixels back through these.
    web_exe.root_module.export_symbol_names = &[_][]const u8{
        "FizzyWebTrackpadMagnification",
        "FizzyWebKeyBuffer",
        "FizzyWebKeyBound",
        "FizzyWebSetFormFactor",
        "FizzyWebGlassBench",
        "FizzyWebSetKeyboardInset",
        "FizzyWebImageAlloc",
        "FizzyWebImageReady",
        "FizzyWebImageFailed",
        "FizzyWebFetchAlloc",
        "FizzyWebFetchReady",
        "FizzyWebFetchFailed",
        "FizzyWebRequestAlloc",
        "FizzyWebRequestReady",
        "FizzyWebRequestFailed",
        "FizzyWebOAuthAlloc",
        "FizzyWebOAuthResult",
        "FizzyWebOAuthFailed",
        // Plugins loaded at runtime (wasm side modules — `web/fizzy.js`'s `loadPlugin`):
        // the host's side of the handshake, and what a side module links against — the
        // stack pointer it shares, dvui's C shims and stb, which it imports from `env`.
        "FizzyWebPluginAlloc",
        "FizzyWebPluginReady",
        "FizzyWebPluginFailed",
        "FizzyWebPluginRequest",
        "FizzyWebStartupPluginsRequested",
        "FizzyWebOpenBytes",
        "FizzyWebShowInRoot",
        // `?demo=`: a bundled demo by name, or a fetched tape (`Editor.Demo`).
        "FizzyWebPlayDemo",
        // `?tape=`: a shared tape, played once the plugins it needs are loaded (`TapeTabs`).
        "FizzyWebPlayTape",
        "__stack_pointer",
        "dvui_c_alloc",
        "dvui_c_free",
        "dvui_c_realloc_sized",
        "dvui_c_panic",
        "dvui_c_sqrt",
        "dvui_c_pow",
        "dvui_c_floor",
        "dvui_c_ceil",
        "dvui_c_fmod",
        "dvui_c_cos",
        "dvui_c_acos",
        "dvui_c_fabs",
        "dvui_c_strlen",
        "stbi_load_from_memory",
        "stbi_failure_reason",
        "stbi_image_free",
        "stbi_info_from_memory",
        // libm entry points a plugin's optimized build calls by name (`src/web_main.zig`
        // defines them for this purpose: a side module has no compiler-rt of its own).
        "ldexpf",
        "ldexp",
    };
    // The function table is the page's (growable), so a plugin's functions can join it.
    web_exe.import_table = true;

    // `icons` (pure-Zig icon data) is referenced at file scope in
    // `src/dvui.zig` and `src/editor/Infobar.zig`. Wired in so any future
    // wasm-reachable code that pulls those files in compiles cleanly.
    if (b.lazyDependency("icons", .{ .target = web_target, .optimize = optimize })) |dep| {
        web_exe.root_module.addImport("icons", dep.module("icons"));
    }

    // `assets` is generated at build time by assetpack (pure `@embedFile`s,
    // target-independent). Same instance as native — no extra build cost.
    web_exe.root_module.addImport("assets", assets_module);
    web_exe.root_module.addImport("app_icon", app_icon_module);

    // `build_opts` (app_version, app_repo_url, velopack_enabled) — shared
    // with native. velopack_enabled is whatever was passed via `-Dvelopack`;
    // wasm path is gated by `arch != .wasm32` in `auto_update.impl`.
    web_exe.root_module.addImport("build_opts", sdk.buildOptsModule(build_opts));

    const core_module_web = fw.core;
    const icons_web = fw.icons;
    web_exe.root_module.addImport("core", core_module_web);
    if (icons_web) |icons| web_exe.root_module.addImport("icons", icons);
    const sdk_module_web = fw.sdk;
    web_exe.root_module.addImport("fizzy_sdk", sdk_module_web);

    // Three editor files have `const sdl3 = @import("backend").c;` at file
    // scope. After refactoring all `sdl3.SDL_DialogFileFilter` references
    // to `fizzy.backend.DialogFileFilter`, those decls became dead — Zig's
    // lazy analysis skips file-scope consts that no reachable body uses.
    // So no `backend` module is wired in for the web build.

    // What the application links, as the native exe has it (`build/exe.zig`), fizzy's own built
    // here for wasm and the application's re-homed: modules made for the native target get this
    // build's framework modules, their own imports kept.
    const wiring: plugins.Wiring = .{
        .target = web_target,
        .optimize = optimize,
        .dvui = dvui_web,
        .core = core_module_web,
        .sdk = sdk_module_web,
        .icons = icons_web,
        .backend = null,
        .workbench_opts = workbench_opts,
        .consumer = web_exe.root_module,
    };
    const linked = plugins.link(b, wiring, app_plugins);
    const markdown_module_web = linked.markdown;
    var bundled_list: std.ArrayList(sdk.BundledPlugin) = .empty;
    bundled_list.appendSlice(b.allocator, linked.plugins) catch @panic("OOM");
    // And the named dependencies, resolved directly for wasm.
    for (web_plugin_deps) |dep_name| {
        const dep = b.lazyDependency(dep_name, .{ .target = web_target, .optimize = optimize }) orelse continue;
        bundled_list.append(
            b.allocator,
            .{ .name = dep_name, .module = plugins.rehome(b, wiring, dep_name, dep.module("plugin")) },
        ) catch @panic("OOM");
    }
    // A plugin may ship pages of its own beside the app (its `web/` directory → `plugins/<id>/`):
    // the far end of a popup round trip that is the plugin's, not fizzy's — a provider's
    // folder picker, say. `core.transport.WebOAuth.pageUrl` finds them.
    var web_pages: std.ArrayList(struct { id: []const u8, dir: []const u8 }) = .empty;
    for (web_plugin_dirs) |wp| {
        const dir = wp.dir;
        const zon_path = b.pathJoin(&.{ dir, "plugin.zig.zon" });
        common.dependOnPathExistence(b, zon_path);
        b.root.access(b.graph.io, zon_path, .{}) catch {
            std.debug.print("fizzy web: plugin checkout '{s}' not found; the web build goes without it\n", .{dir});
            continue;
        };
        const manifest = helpers.readManifestAt(b, zon_path);
        const m = b.createModule(.{
            .target = web_target,
            .optimize = optimize,
            .root_source_file = b.path(b.pathJoin(&.{ dir, "plugin.zig" })),
            .link_libc = false,
            .single_threaded = true,
        });
        m.addAnonymousImport("plugin_zon", .{ .root_source_file = b.path(zon_path) });
        m.addOptions(helpers.plugin_options_import, helpers.pluginOptionsFor(b, zon_path));
        m.addImport("dvui", dvui_web);
        m.addImport("core", core_module_web);
        m.addImport("fizzy_sdk", sdk_module_web);
        if (icons_web) |icons| m.addImport("icons", icons);
        for (wp.modules) |extra| {
            const em = b.createModule(.{
                .target = web_target,
                .optimize = optimize,
                .root_source_file = b.path(b.pathJoin(&.{ dir, extra.root })),
                .link_libc = false,
                .single_threaded = true,
            });
            if (extra.dvui) em.addImport("dvui", dvui_web);
            if (extra.core) em.addImport("core", core_module_web);
            m.addImport(extra.name, em);
        }
        bundled_list.append(b.allocator, .{ .name = b.dupe(manifest.id), .module = m }) catch @panic("OOM");
        web_pages.append(b.allocator, .{ .id = b.dupe(manifest.id), .dir = dir }) catch @panic("OOM");
    }
    const bundled_web = sdk.bundledPluginsModule(b, web_target, optimize, bundled_list.items);
    web_exe.root_module.addImport("bundled_plugins", bundled_web);

    // The `app` framework module (the plugin store). Wired exactly as the native build wires
    // it — one helper, so the two cannot drift.
    const app_module_web = sdk.wireAppModule(
        b,
        web_target,
        optimize,
        dvui_web,
        core_module_web,
        sdk_module_web,
        icons_web,
        markdown_module_web,
        null,
        build_opts,
        null,
        web_exe.root_module,
    );
    app_module_web.addImport("bundled_plugins", bundled_web);
    sdk.wireAppLayout(
        b,
        web_target,
        optimize,
        app_layout,
        dvui_web,
        app_module_web,
        core_module_web,
        sdk_module_web,
        web_exe.root_module,
    );

    // Cache-buster: stamps a 64-char hash into the index.html / fizzy.js placeholders so
    // the browser picks up new wasm builds without manual hard-reloads. Re-implements
    // upstream DVUI's `addWebExample` machinery so we don't have to invoke its step.
    const cb = b.addExecutable(.{
        .name = "cacheBuster",
        .root_module = b.createModule(.{
            .root_source_file = dvui_web_dep.path("src/cacheBuster.zig"),
            .target = b.graph.host,
        }),
    });
    const web_js = patchedWebJs(b, dvui_web_dep);
    // `fizzy.js` names what it loads by their hash, and the page names `fizzy.js` by its own.
    const cb_js = b.addRunArtifact(cb);
    cb_js.addFileArg(stampStorage(b));
    cb_js.addFileArg(web_js);
    cb_js.addFileArg(b.path("web/fizzy-worker.js"));
    cb_js.addFileArg(web_exe.getEmittedBin());
    const fizzy_js = cb_js.captureStdOut(.{});
    const cb_page = b.addRunArtifact(cb);
    cb_page.addFileArg(b.path("web/index.html"));
    cb_page.addFileArg(fizzy_js);
    const index_html_with_hash = cb_page.captureStdOut(.{});

    const dir = b.addWriteFiles();
    _ = dir.addCopyFile(web_exe.getEmittedBin(), web_exe.out_filename);
    _ = dir.addCopyFile(fizzy_js, "fizzy.js");
    _ = dir.addCopyFile(web_js, "web.js");
    // Worker mode (`?worker=1`): the editor in a worker, drawing through an OffscreenCanvas.
    _ = dir.addCopyFile(b.path("web/fizzy-worker.js"), "fizzy-worker.js");
    _ = dir.addCopyFile(dvui_web_dep.path("src/fonts/NotoSansKR-Regular.ttf"), "NotoSansKR-Regular.ttf");
    // The far end of a web OAuth round trip (`core.transport.WebOAuth`): the page a provider
    // redirects back to, which posts its location to the opener and closes.
    _ = dir.addCopyFile(b.path("web/oauth-callback.html"), "oauth-callback.html");
    // The installable page (relative paths, so /app/ and /testapp/ both work) and the icons it
    // and the iOS home-screen entry name.
    for ([_][]const u8{ "manifest.webmanifest", "icon-192.png", "icon-512.png", "icon-maskable-512.png" }) |name| {
        _ = dir.addCopyFile(b.path(b.pathJoin(&.{ "web", name })), name);
    }
    // The tapes the page can fetch (`?demo=demos/<name>.tape`), built from this commit's scripts.
    const demos: ?std.Build.LazyPath = if (own) demoTapes(b) else null;
    if (demos) |tapes| _ = dir.addCopyDirectory(tapes, "demos", .{});
    for (web_pages.items) |page| {
        const web_dir = b.pathJoin(&.{ page.dir, "web" });
        var d = b.root.openDir(b.graph.io, web_dir, .{ .iterate = true }) catch {
            common.dependOnPathExistence(b, web_dir);
            continue;
        };
        b.dependOnDirectoryContents(b.path(web_dir));
        defer d.close(b.graph.io);
        var it = d.iterate();
        while (it.next(b.graph.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            _ = dir.addCopyFile(
                b.path(b.pathJoin(&.{ web_dir, entry.name })),
                b.pathJoin(&.{ "plugins", page.id, entry.name }),
            );
        }
    }

    const rehome_check: ?*std.Build.Step.Compile = if (own) blk: {
        const fixture = rehome_fixture.graph(b, b.resolveTargetQuery(.{}), optimize);
        var fixture_wiring = wiring;
        fixture_wiring.consumer = b.createModule(
            .{ .target = web_target, .optimize = optimize, .link_libc = false, .single_threaded = true },
        );
        const module = plugins.rehome(b, fixture_wiring, "rehome_fixture", fixture);
        rehome_fixture.check(b, fixture, module, false);
        break :blk b.addObject(.{ .name = "rehome-fixture-web", .root_module = module });
    } else null;

    const site = b.addWriteFiles();
    _ = site.addCopyDirectory(dir.getDirectory(), "", .{});
    _ = site.addCopyFile(index_html_with_hash, "index.html");
    // For an app built on fizzy, which installs it into its own prefix: a dependency's prefix is a
    // directory in the cache.
    b.addNamedLazyPath("web", site.getDirectory());
    return .{
        .wasm = web_exe,
        .site = site.getDirectory(),
        .files = dir.getDirectory(),
        .page = index_html_with_hash,
        .rehome_fixture = rehome_check,
        .demos = demos,
    };
}

/// The steps over `build`'s result: `web` installs it into `zig-out/web/`, and the ones that
/// serve, copy or only compile it. `web-wasm` hands a consuming app the module itself.
pub fn install(b: *std.Build, web: Web) void {
    b.addNamedLazyPath("web-wasm", web.wasm.getEmittedBin());
    const web_install_dir: std.Build.InstallDir = .{ .custom = "web" };
    const install_site = b.addInstallDirectory(.{
        .source_dir = web.site,
        .install_dir = web_install_dir,
        .install_subdir = "",
    });

    const web_step = b.step("web", "Build the fizzy web (wasm) app into zig-out/web/");
    web_step.dependOn(&install_site.step);
    if (web.demos) |tapes| {
        const install_demos = b.addInstallDirectory(.{
            .source_dir = tapes,
            .install_dir = web_install_dir,
            .install_subdir = "demos",
        });
        b.step("demos", "Build every hosted demo tape into zig-out/web/demos/").dependOn(&install_demos.step);
    }

    // Compile-only smoke check for the wasm target. Pairs with `check` (unit
    // tests). Catches regressions where someone reaches a wasm-incompatible
    // code path (thread spawn, std.posix surface, missing module import)
    // from the wasm root. No install — just compile.
    const check_web_step = b.step("check-web", "Compile fizzy web (wasm) without installing artifacts");
    check_web_step.dependOn(&web.wasm.step);
    if (web.rehome_fixture) |fixture| check_web_step.dependOn(&fixture.step);

    // Copy zig-out/web into web/app/ for local preview at the production
    // `/app/` path: `cd web && python3 -m http.server` then open
    // http://localhost:8000/app/. The landing page lives in fizzyedit/website.
    const web_docs_step = b.step("web-docs", "Build web app and copy into web/app/ for local /app/ preview");
    web_docs_step.dependOn(web_step);
    const cp_web_to_docs = b.addSystemCommand(&.{ "sh", "-c" });
    cp_web_to_docs.addArg("mkdir -p web/app && cp -R zig-out/web/. web/app/");
    cp_web_to_docs.step.dependOn(web_step);
    web_docs_step.dependOn(&cp_web_to_docs.step);

    const serve_web_cmd = b.addSystemCommand(&.{ "sh", "scripts/serve-web.sh" });
    serve_web_cmd.step.dependOn(web_step);
    _ = b.step(
        "serve-web",
        "Serve zig-out/web at http://127.0.0.1:8765/ (builds web first; frees stale :8765)",
    ).dependOn(&serve_web_cmd.step);
}

/// dvui's `web.js` with `web/patches/dvui/*.patch` applied, in name order, by zig-patch: what
/// fizzy's web backend (`src/backend/WebBackend.zig`) needs of it, each patch a dvui commit
/// written to go upstream. How they are made: docs/DEPENDENCIES.md.
fn patchedWebJs(b: *std.Build, dvui_dep: *std.Build.Dependency) std.Build.LazyPath {
    const io = b.graph.io;
    const patches_dir = "web/patches/dvui";
    b.dependOnDirectoryContents(b.path(patches_dir));
    var names: std.ArrayList([]const u8) = .empty;
    var dir = b.root.openDir(io, patches_dir, .{ .iterate = true }) catch |err|
        std.debug.panic("fizzy web: open {s}: {t}", .{ patches_dir, err });
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch |err| std.debug.panic("fizzy web: list {s}: {t}", .{ patches_dir, err })) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".patch")) continue;
        names.append(b.allocator, b.dupe(entry.name)) catch @panic("OOM");
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, l: []const u8, r: []const u8) bool {
            return std.mem.lessThan(u8, l, r);
        }
    }.lessThan);
    const patches = b.allocator.alloc(std.Build.LazyPath, names.items.len) catch @panic("OOM");
    for (patches, names.items) |*p, name| p.* = b.path(b.pathJoin(&.{ patches_dir, name }));
    const patched = b.dependency("patch", .{ .source = dvui_dep.path(""), .patches = patches }).namedLazyPath("patched");
    return patched.path(b, "src/backends/web.js");
}

/// `web/fizzy.js` with the name the app files what it keeps in the browser under stamped in
/// (`storageName` there): `-Dweb-storage`, or "fizzy". Every copy of the app on one site shares
/// the browser's storage for it, so a test build served beside the real one — fizzyed.it/testapp/
/// beside /app/ — is built with a name of its own and keeps out of the real one's settings.
fn stampStorage(b: *std.Build) std.Build.LazyPath {
    const name = b.option(
        []const u8,
        "web-storage",
        "What the web app files its browser storage under (default \"fizzy\"); give a " ++
            "test build served beside the real one a name of its own",
    ) orelse "fizzy";
    for (name) |c| switch (c) {
        'a'...'z', '0'...'9', '-', '_' => {},
        else => std.debug.panic("-Dweb-storage={s}: only a-z, 0-9, '-' and '_'", .{name}),
    };
    const token = "__FIZZY_WEB_STORAGE__";
    b.dependOnFileContents(b.path("web/fizzy.js"));
    const js = std.Io.Dir.cwd().readFileAlloc(
        b.graph.io,
        b.root.joinString(b.allocator, "web/fizzy.js") catch @panic("OOM"),
        b.allocator,
        .unlimited,
    ) catch |err|
        std.debug.panic("web/fizzy.js: {t}", .{err});
    if (std.mem.find(u8, js, token) == null) std.debug.panic("web/fizzy.js: no {s} to stamp", .{token});
    const stamped = std.mem.replaceOwned(u8, b.allocator, js, token, name) catch @panic("OOM");
    return b.addWriteFiles().add("fizzy.js", stamped);
}

/// Every tape fizzy hosts, built on the host (`scripts/demos.zig`): the bundled demos from their
/// scripts, which need only `tape`, and each hand-written tape in `docs/demos/`.
fn demoTapes(b: *std.Build) std.Build.LazyPath {
    const tape = b.createModule(.{
        .target = b.graph.host,
        .root_source_file = b.path("sdk/tape/root.zig"),
    });
    const demos = b.createModule(.{
        .target = b.graph.host,
        .root_source_file = b.path("src/editor/demos/catalog.zig"),
    });
    demos.addImport("tape", tape);
    const tool = b.addExecutable(.{
        .name = "demos",
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .root_source_file = b.path("scripts/demos.zig"),
        }),
    });
    tool.root_module.addImport("tape", tape);
    tool.root_module.addImport("demos", demos);
    const run = b.addRunArtifact(tool);
    const out = run.addOutputDirectoryArg("demos");
    // Declared, so a demo added or removed reconfigures the build.
    b.dependOnDirectoryContents(b.path("docs/demos"));
    var dir = b.root.openDir(b.graph.io, "docs/demos", .{ .iterate = true }) catch |err|
        std.debug.panic("docs/demos: {t}", .{err});
    defer dir.close(b.graph.io);
    var it = dir.iterate();
    while (it.next(b.graph.io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zon")) continue;
        run.addFileArg(b.path(b.pathJoin(&.{ "docs/demos", entry.name })));
    }
    return out;
}
