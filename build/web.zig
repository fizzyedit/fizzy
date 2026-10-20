const std = @import("std");
const common = @import("common.zig");
const helpers = @import("../plugins/shared/build/helpers.zig");
const core_mod = @import("fizzy_sdk").core_module;
const plugins = @import("plugins.zig");
const sdk = @import("sdk.zig");

pub fn addSteps(
    b: *std.Build,
    optimize: std.lang.OptimizeMode,
    build_opts: *std.Build.Step.Options,
    workbench_opts: *std.Build.Step.Options,
    assets_module: *std.Build.Module,
    /// The window's icon (`app.Branding.png`); `src/Entry.zig` imports it.
    app_icon_module: *std.Build.Module,
    app_plugins: []const sdk.BundledPlugin,
    web_plugin_deps: []const []const u8,
    web_plugin_dirs: []const @import("app.zig").WebPluginDir,
    /// Fizzy's own build (`Options.own`): the hosted demo tapes come from `docs/demos/` and
    /// `scripts/`, which fizzy's package leaves out, so an app built on fizzy has none.
    own: bool,
) void {
    const web_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_features_add = std.Target.wasm.featureSet(&.{
            .atomics,
            .multivalue,
            .bulk_memory,
        }),
    });

    // The web backend is fizzy's own (`src/backend/WebBackend.zig` + `web/web.js`), started as a
    // copy of dvui's: dvui is built in its `custom` mode and our backend linked to it, as dvui's
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
    // What the page calls into (`web/web.js`): dvui's web exports.
    web_backend.export_symbol_names = &.{ "dvui_init", "dvui_deinit", "dvui_update", "add_event", "arena_u8", "gpa_u8", "gpa_free", "new_font" };
    web_backend.addImport("dvui", dvui_web);
    dvui_web.addImport("backend", web_backend);
    const dvui_web_proxy_bridge = sdk.addProxyBridgeModule(b, web_target, optimize, dvui_web_dep, dvui_web);

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
    web_exe.root_module.addImport("viewports_none", @import("fizzy_backend").viewportsNoneModule(@import("exe.zig").backendDependency(b), dvui_web));
    web_exe.root_module.addImport("web-backend", web_backend);

    // Extra wasm exports beyond dvui's own (`dvui_init`/`dvui_update`/etc.). The wasm
    // linker only emits symbols listed here, so `export fn` in Zig isn't enough on its
    // own — without this line our trackpad pinch entry point would compile cleanly but
    // be missing from `instance.exports`, and the JS bootstrap in `web/index.html`
    // would never be able to forward pinch deltas into the canvas widget. The image
    // trio is the other half of that seam: JS rasterizes a remote URL and writes the
    // pixels back through these.
    web_exe.root_module.export_symbol_names = &[_][]const u8{
        "FizzyWebTrackpadMagnification",
        "FizzyWebKeyBuffer",
        "FizzyWebKeyBound",
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
        // Plugins loaded at runtime (wasm side modules — `web/index.html`'s `loadPlugin`):
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

    // Shared `core` module for the wasm build (dvui web backend variant).
    const core_module_web = b.createModule(.{
        .target = web_target,
        .optimize = optimize,
        .root_source_file = b.path("core/core.zig"),
        .link_libc = false,
        .single_threaded = true,
    });
    const icons_web = core_mod.addImports(b, core_module_web, dvui_web, b.dependency("fizzy_sdk", .{}).builder, web_target, optimize, null, null);
    web_exe.root_module.addImport("core", core_module_web);
    if (icons_web) |icons| web_exe.root_module.addImport("icons", icons);
    const sdk_module_web = sdk.wireSdkModule(b, web_target, optimize, dvui_web, dvui_web_proxy_bridge, core_module_web, web_exe.root_module);

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
        bundled_list.append(b.allocator, .{ .name = dep_name, .module = plugins.rehome(b, wiring, dep_name, dep.module("plugin")) }) catch @panic("OOM");
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
    const app_module_web = sdk.wireAppModule(b, web_target, optimize, dvui_web, core_module_web, sdk_module_web, icons_web, markdown_module_web, null, build_opts, null, web_exe.root_module);
    app_module_web.addImport("bundled_plugins", bundled_web);

    const web_install_dir: std.Build.InstallDir = .{ .custom = "web" };
    const install_wasm = b.addInstallArtifact(web_exe, .{
        .dest_dir = .{ .override = web_install_dir },
    });

    // Cache-buster: stamps a 64-char hash into the index.html / web.js placeholders so
    // the browser picks up new wasm builds without manual hard-reloads. Re-implements
    // upstream DVUI's `addWebExample` machinery so we don't have to invoke its step.
    const cb = b.addExecutable(.{
        .name = "cacheBuster",
        .root_module = b.createModule(.{
            .root_source_file = dvui_web_dep.path("src/cacheBuster.zig"),
            .target = b.graph.host,
        }),
    });
    const cb_run = b.addRunArtifact(cb);
    cb_run.addFileArg(stampStorage(b));
    cb_run.addFileArg(b.path("web/web.js"));
    cb_run.addFileArg(b.path("web/fizzy-worker.js"));
    cb_run.addFileArg(web_exe.getEmittedBin());
    const index_html_with_hash = cb_run.captureStdOut(.{});

    const web_step = b.step("web", "Build the fizzy web (wasm) app into zig-out/web/");
    web_step.dependOn(&install_wasm.step);
    web_step.dependOn(&b.addInstallFileWithDir(
        index_html_with_hash,
        web_install_dir,
        "index.html",
    ).step);
    web_step.dependOn(&b.addInstallFileWithDir(
        b.path("web/web.js"),
        web_install_dir,
        "web.js",
    ).step);
    // Worker mode (`?worker=1`): the editor in a worker, drawing through an OffscreenCanvas.
    web_step.dependOn(&b.addInstallFileWithDir(
        b.path("web/fizzy-worker.js"),
        web_install_dir,
        "fizzy-worker.js",
    ).step);
    web_step.dependOn(&b.addInstallFileWithDir(
        dvui_web_dep.path("src/fonts/NotoSansKR-Regular.ttf"),
        web_install_dir,
        "NotoSansKR-Regular.ttf",
    ).step);
    // The far end of a web OAuth round trip (`core.transport.WebOAuth`): the page a provider
    // redirects back to, which posts its location to the opener and closes.
    web_step.dependOn(&b.addInstallFileWithDir(
        b.path("web/oauth-callback.html"),
        web_install_dir,
        "oauth-callback.html",
    ).step);
    // The tapes the page can fetch (`?demo=demos/<name>.tape`), built from this commit's scripts.
    if (own) {
        const install_demos = b.addInstallDirectory(.{
            .source_dir = demoTapes(b),
            .install_dir = web_install_dir,
            .install_subdir = "demos",
        });
        web_step.dependOn(&install_demos.step);
        b.step("demos", "Build every hosted demo tape into zig-out/web/demos/").dependOn(&install_demos.step);
    }
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
            web_step.dependOn(&b.addInstallFileWithDir(
                b.path(b.pathJoin(&.{ web_dir, entry.name })),
                web_install_dir,
                b.pathJoin(&.{ "plugins", page.id, entry.name }),
            ).step);
        }
    }

    // Compile-only smoke check for the wasm target. Pairs with `check` (unit
    // tests). Catches regressions where someone reaches a wasm-incompatible
    // code path (thread spawn, std.posix surface, missing module import)
    // from the wasm root. No install — just compile.
    const check_web_step = b.step("check-web", "Compile fizzy web (wasm) without installing artifacts");
    check_web_step.dependOn(&web_exe.step);

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

/// A plugin package's `"plugin"` module as this web build's own: the same root file and the
/// plugin's own imports (manifest options, its dependencies), with `dvui`/`core`/`fizzy_sdk`
/// swapped for the web build's. A module cannot import two frameworks, so it must be a copy.
/// `web/index.html` with the name the page files what it keeps in the browser under stamped in
/// (`storageName` there): `-Dweb-storage`, or "fizzy". Every copy of the app on one site shares
/// the browser's storage for it, so a test build served beside the real one — fizzyed.it/testapp/
/// beside /app/ — is built with a name of its own and keeps out of the real one's settings.
fn stampStorage(b: *std.Build) std.Build.LazyPath {
    const name = b.option([]const u8, "web-storage", "What the web app files its browser storage under (default \"fizzy\"); give a test build served beside the real one a name of its own") orelse "fizzy";
    for (name) |c| switch (c) {
        'a'...'z', '0'...'9', '-', '_' => {},
        else => std.debug.panic("-Dweb-storage={s}: only a-z, 0-9, '-' and '_'", .{name}),
    };
    const token = "__FIZZY_WEB_STORAGE__";
    b.dependOnFileContents(b.path("web/index.html"));
    const html = std.Io.Dir.cwd().readFileAlloc(b.graph.io, b.root.joinString(b.allocator, "web/index.html") catch @panic("OOM"), b.allocator, .unlimited) catch |err|
        std.debug.panic("web/index.html: {t}", .{err});
    if (std.mem.find(u8, html, token) == null) std.debug.panic("web/index.html: no {s} to stamp", .{token});
    const stamped = std.mem.replaceOwned(u8, b.allocator, html, token, name) catch @panic("OOM");
    return b.addWriteFiles().add("index.html", stamped);
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
