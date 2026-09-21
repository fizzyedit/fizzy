const std = @import("std");
const helpers = @import("../plugins/shared/build/helpers.zig");
const core_mod = @import("fizzy_sdk").core_module;
const plugins = @import("plugins.zig");
const sdk = @import("sdk.zig");

const workbench_plugin = plugins.workbench;
const text_plugin = plugins.text;
const image_plugin = plugins.image;
const archive_plugin = plugins.archive;
const markdown_plugin = plugins.markdown;

pub fn addSteps(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    build_opts: *std.Build.Step.Options,
    workbench_opts: *std.Build.Step.Options,
    assets_module: *std.Build.Module,
    app_plugins: []const sdk.BundledPlugin,
    web_plugin_deps: []const []const u8,
    web_plugin_dirs: []const @import("app.zig").WebPluginDir,
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

    const dvui_web_dep = sdk.dvuiDependency(b, .{
        .target = web_target,
        .optimize = optimize,
        .backend = .web,
        .freetype = false,
    });
    const dvui_web_proxy_bridge = sdk.addProxyBridgeModule(b, web_target, optimize, dvui_web_dep, dvui_web_dep.module("dvui_web"));

    const web_exe = b.addExecutable(.{
        .name = "web",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/web_main.zig"),
            .target = web_target,
            .optimize = optimize,
            .link_libc = false,
            .single_threaded = true,
            .strip = optimize == .ReleaseFast or optimize == .ReleaseSmall,
        }),
    });
    web_exe.entry = .disabled;
    web_exe.root_module.addImport("dvui", dvui_web_dep.module("dvui_web"));
    web_exe.root_module.addImport("web-backend", dvui_web_dep.module("web"));

    // Extra wasm exports beyond dvui's own (`dvui_init`/`dvui_update`/etc.). The wasm
    // linker only emits symbols listed here, so `export fn` in Zig isn't enough on its
    // own — without this line our trackpad pinch entry point would compile cleanly but
    // be missing from `instance.exports`, and the JS bootstrap in `web/index.html`
    // would never be able to forward pinch deltas into the canvas widget. The image
    // trio is the other half of that seam: JS rasterizes a remote URL and writes the
    // pixels back through these.
    web_exe.root_module.export_symbol_names = &[_][]const u8{
        "FizzyWebTrackpadMagnification",
        "FizzyWebImageAlloc",
        "FizzyWebImageReady",
        "FizzyWebImageFailed",
        "FizzyWebImageOverlay",
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
        "FizzyWebOpenBytes",
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
    const icons_web = core_mod.addImports(b, core_module_web, dvui_web_dep.module("dvui_web"), web_target, optimize);
    web_exe.root_module.addImport("core", core_module_web);
    if (icons_web) |icons| web_exe.root_module.addImport("icons", icons);
    const sdk_module_web = sdk.wireSdkModule(b, web_target, optimize, dvui_web_dep.module("dvui_web"), dvui_web_proxy_bridge, core_module_web, web_exe.root_module);

    // Three editor files have `const sdl3 = @import("backend").c;` at file
    // scope. After refactoring all `sdl3.SDL_DialogFileFilter` references
    // to `fizzy.backend.DialogFileFilter`, those decls became dead — Zig's
    // lazy analysis skips file-scope consts that no reachable body uses.
    // So no `backend` module is wired in for the web build.

    const workbench_module_web = workbench_plugin.addStaticModule(b, web_target, optimize, .{
        .dvui = dvui_web_dep.module("dvui_web"),
        .core = core_module_web,
        .sdk = sdk_module_web,
        .icons = icons_web,
        .backend = null,
    }, workbench_opts, web_exe.root_module);
    const text_module_web = text_plugin.addStaticModule(b, web_target, optimize, .{
        .dvui = dvui_web_dep.module("dvui_web"),
        .core = core_module_web,
        .sdk = sdk_module_web,
        .icons = icons_web,
    }, web_exe.root_module);
    const image_module_web = image_plugin.addStaticModule(b, web_target, optimize, .{
        .dvui = dvui_web_dep.module("dvui_web"),
        .core = core_module_web,
        .sdk = sdk_module_web,
    }, web_exe.root_module);
    const archive_module_web = archive_plugin.addStaticModule(b, web_target, optimize, .{
        .dvui = dvui_web_dep.module("dvui_web"),
        .core = core_module_web,
        .sdk = sdk_module_web,
    }, web_exe.root_module);
    const markdown_module_web = markdown_plugin.addStaticModule(b, web_target, optimize, .{
        .dvui = dvui_web_dep.module("dvui_web"),
        .core = core_module_web,
        .sdk = sdk_module_web,
    }, web_exe.root_module);
    var bundled_list: std.ArrayList(sdk.BundledPlugin) = .empty;
    bundled_list.appendSlice(b.allocator, &.{
        .{ .name = "workbench", .module = workbench_module_web },
        .{ .name = "text", .module = text_module_web },
        .{ .name = "image", .module = image_module_web },
        .{ .name = "archive", .module = archive_module_web },
        .{ .name = "markdown", .module = markdown_module_web },
    }) catch @panic("OOM");
    // Out-of-tree plugins the web build links in: the application's own list (`buildApp`),
    // whose modules were made for the native target and are re-homed here, and the named
    // dependencies resolved directly for wasm. Same re-homing the native exe does — a copy
    // with this build's framework modules and the plugin's own imports kept.
    for (app_plugins) |p| {
        const src_mod = p.module orelse continue;
        bundled_list.append(b.allocator, .{ .name = p.name, .module = rehome(b, web_target, optimize, src_mod, dvui_web_dep.module("dvui_web"), core_module_web, sdk_module_web, icons_web) }) catch @panic("OOM");
    }
    for (web_plugin_deps) |dep_name| {
        const dep = b.lazyDependency(dep_name, .{ .target = web_target, .optimize = optimize }) orelse continue;
        bundled_list.append(b.allocator, .{ .name = dep_name, .module = rehome(b, web_target, optimize, dep.module("plugin"), dvui_web_dep.module("dvui_web"), core_module_web, sdk_module_web, icons_web) }) catch @panic("OOM");
    }
    // A plugin may ship pages of its own beside the app (its `web/` directory → `plugins/<id>/`):
    // the far end of a popup round trip that is the plugin's, not fizzy's — a provider's
    // folder picker, say. `core.transport.WebOAuth.pageUrl` finds them.
    var web_pages: std.ArrayList(struct { id: []const u8, dir: []const u8 }) = .empty;
    for (web_plugin_dirs) |wp| {
        const dir = wp.dir;
        const zon_path = b.pathJoin(&.{ dir, "plugin.zig.zon" });
        b.build_root.handle.access(b.graph.io, zon_path, .{}) catch {
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
        m.addImport("dvui", dvui_web_dep.module("dvui_web"));
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
            if (extra.dvui) em.addImport("dvui", dvui_web_dep.module("dvui_web"));
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
    const app_module_web = sdk.wireAppModule(b, web_target, optimize, dvui_web_dep.module("dvui_web"), core_module_web, sdk_module_web, icons_web, markdown_module_web, null, build_opts, null, web_exe.root_module);
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
    cb_run.addFileArg(b.path("web/index.html"));
    cb_run.addFileArg(dvui_web_dep.path("src/backends/web.js"));
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
        dvui_web_dep.path("src/backends/web.js"),
        web_install_dir,
        "web.js",
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
    for (web_pages.items) |page| {
        const web_dir = b.pathJoin(&.{ page.dir, "web" });
        var d = b.build_root.handle.openDir(b.graph.io, web_dir, .{ .iterate = true }) catch continue;
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
fn rehome(
    b: *std.Build,
    web_target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    src_mod: *std.Build.Module,
    dvui_mod: *std.Build.Module,
    core_module: *std.Build.Module,
    sdk_mod: *std.Build.Module,
    icons_mod: ?*std.Build.Module,
) *std.Build.Module {
    const m = b.createModule(.{
        .target = web_target,
        .optimize = optimize,
        .root_source_file = src_mod.root_source_file,
        .link_libc = false,
        .single_threaded = true,
    });
    var it = src_mod.import_table.iterator();
    while (it.next()) |kv| {
        const name = kv.key_ptr.*;
        if (std.mem.eql(u8, name, "dvui") or std.mem.eql(u8, name, "core") or std.mem.eql(u8, name, "fizzy_sdk") or std.mem.eql(u8, name, "icons")) continue;
        m.addImport(name, kv.value_ptr.*);
    }
    m.addImport("dvui", dvui_mod);
    m.addImport("core", core_module);
    m.addImport("fizzy_sdk", sdk_mod);
    if (icons_mod) |icons| m.addImport("icons", icons);
    return m;
}
