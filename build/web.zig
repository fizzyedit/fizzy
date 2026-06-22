const std = @import("std");
const plugins = @import("plugins.zig");
const sdk = @import("sdk.zig");

const workbench_plugin = plugins.workbench;
const text_plugin = plugins.text;
const example_plugin = plugins.example;

pub fn addSteps(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    build_opts: *std.Build.Step.Options,
    workbench_opts: *std.Build.Step.Options,
    assets_module: *std.Build.Module,
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

    const dvui_web_dep = b.dependency("dvui", .{
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
    // be missing from `instance.exports`, and the JS bootstrap in `web/shell.html`
    // would never be able to forward pinch deltas into the canvas widget.
    web_exe.root_module.export_symbol_names = &[_][]const u8{
        "FizzyWebTrackpadMagnification",
    };

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
    web_exe.root_module.addOptions("build_opts", build_opts);

    // Shared `core` module for the wasm build (dvui web backend variant).
    const core_module_web = b.createModule(.{
        .target = web_target,
        .optimize = optimize,
        .root_source_file = b.path("src/core/core.zig"),
        .link_libc = false,
        .single_threaded = true,
    });
    core_module_web.addImport("dvui", dvui_web_dep.module("dvui_web"));
    if (b.lazyDependency("icons", .{ .target = web_target, .optimize = optimize })) |dep| {
        core_module_web.addImport("icons", dep.module("icons"));
    }
    web_exe.root_module.addImport("core", core_module_web);
    const sdk_module_web = sdk.wireSdkModule(b, web_target, optimize, dvui_web_dep.module("dvui_web"), dvui_web_proxy_bridge, core_module_web, web_exe.root_module);

    // Three editor files have `const sdl3 = @import("backend").c;` at file
    // scope. After refactoring all `sdl3.SDL_DialogFileFilter` references
    // to `fizzy.backend.DialogFileFilter`, those decls became dead — Zig's
    // lazy analysis skips file-scope consts that no reachable body uses.
    // So no `backend` module is wired in for the web build.

    _ = workbench_plugin.addStaticModule(b, web_target, optimize, .{
        .dvui = dvui_web_dep.module("dvui_web"),
        .core = core_module_web,
        .sdk = sdk_module_web,
        .icons = if (b.lazyDependency("icons", .{ .target = web_target, .optimize = optimize })) |dep| dep.module("icons") else null,
        .backend = null,
    }, workbench_opts, web_exe.root_module);
    _ = text_plugin.addStaticModule(b, web_target, optimize, .{
        .dvui = dvui_web_dep.module("dvui_web"),
        .core = core_module_web,
        .sdk = sdk_module_web,
    }, web_exe.root_module);
    _ = example_plugin.addStaticModule(b, web_target, optimize, .{
        .dvui = dvui_web_dep.module("dvui_web"),
        .core = core_module_web,
        .sdk = sdk_module_web,
    }, web_exe.root_module);

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
    cb_run.addFileArg(b.path("web/shell.html"));
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
