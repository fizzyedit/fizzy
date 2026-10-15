//! Built-in plugin build integration — the static-embed + bundled-dylib module graph.
//!
//! Each built-in plugin keeps its fizzy-internal static-embed glue self-contained in
//! `plugins/<name>/static/integration.zig`, separate from the canonical third-party files
//! at the plugin-folder root (fizzy's `@import("<name>")` resolves to the root
//! `<name>.zig`). Fizzy root aggregates those integration files here, and `link` turns the list
//! an application gives into modules for one executable.
const std = @import("std");
const BundledPlugin = @import("sdk.zig").BundledPlugin;

pub const workbench = @import("../plugins/workbench/static/integration.zig");
pub const text = @import("../plugins/text/static/integration.zig");
pub const markdown = @import("../plugins/markdown/static/integration.zig");
pub const image = @import("../plugins/image/static/integration.zig");
pub const archive = @import("../plugins/archive/static/integration.zig");
pub const devtools = @import("../plugins/devtools/static/integration.zig");

/// Fizzy's own plugins, as entries in the list an application links (`fizzy.plugins`). An entry
/// with no module is built by fizzy for each executable, wired to that executable's framework.
pub const entries = struct {
    pub const workbench: BundledPlugin = .{ .name = "workbench" };
    pub const text: BundledPlugin = .{ .name = "text" };
    pub const image: BundledPlugin = .{ .name = "image" };
    pub const archive: BundledPlugin = .{ .name = "archive" };
    pub const markdown: BundledPlugin = .{ .name = "markdown" };
    pub const devtools: BundledPlugin = .{ .name = "devtools" };

    /// What fizzy itself links, in its sidebar order.
    pub const all = [_]BundledPlugin{ @This().workbench, @This().text, @This().image, @This().archive, @This().markdown, @This().devtools };
};

/// Whether `plugins` links fizzy's own `name`, rather than leaving it out or bringing a module of
/// its own under that id.
pub fn linksFizzys(plugins: []const BundledPlugin, name: []const u8) bool {
    for (plugins) |p| if (p.module == null and std.mem.eql(u8, p.name, name)) return true;
    return false;
}

/// What one executable gives the plugins it links.
pub const Wiring = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dvui: *std.Build.Module,
    core: *std.Build.Module,
    sdk: *std.Build.Module,
    icons: ?*std.Build.Module,
    /// workbench's: the native backend, null on the web.
    backend: ?*std.Build.Module,
    workbench_opts: *std.Build.Step.Options,
    /// The executable's root module, which imports each plugin by its name.
    consumer: *std.Build.Module,
    /// False where markdown does not build (the native exe for wasm).
    markdown: bool = true,
};

pub const Linked = struct {
    /// The modules for `bundledPluginsModule`, in the order the application listed them.
    plugins: []const BundledPlugin,
    /// Built whether or not they are listed: fizzy's own code imports both. The editor holds
    /// workbench's state, and the store draws a plugin's README with markdown. A module is made
    /// once for its consumer, so a listed one is this one.
    workbench: *std.Build.Module,
    markdown: ?*std.Build.Module,
};

/// Make the modules for `plugins`: fizzy's own built for this executable, an application's
/// re-homed onto it. workbench must be listed, because the editor still holds its state
/// (fizzyedit/plans#13).
pub fn link(b: *std.Build, w: Wiring, plugins: []const BundledPlugin) Linked {
    if (!linksFizzys(plugins, "workbench")) std.debug.panic("fizzy: the plugin list must include `fizzy.plugins.workbench`; the editor still holds its state (fizzyedit/plans#13)", .{});

    const workbench_mod = workbench.addStaticModule(b, w.target, w.optimize, .{
        .dvui = w.dvui,
        .core = w.core,
        .sdk = w.sdk,
        .icons = w.icons,
        .backend = w.backend,
    }, w.workbench_opts, w.consumer);
    const markdown_mod: ?*std.Build.Module = if (w.markdown) markdown.addStaticModule(b, w.target, w.optimize, .{ .dvui = w.dvui, .core = w.core, .sdk = w.sdk }, w.consumer) else null;

    var out: std.ArrayList(BundledPlugin) = .empty;
    for (plugins) |p| {
        const m: ?*std.Build.Module = if (p.module) |src| rehome(b, w, p.name, src) else if (std.mem.eql(u8, p.name, "workbench"))
            workbench_mod
        else if (std.mem.eql(u8, p.name, "markdown"))
            markdown_mod
        else if (std.mem.eql(u8, p.name, "text"))
            text.addStaticModule(b, w.target, w.optimize, .{ .dvui = w.dvui, .core = w.core, .sdk = w.sdk, .icons = w.icons }, w.consumer)
        else if (std.mem.eql(u8, p.name, "image"))
            image.addStaticModule(b, w.target, w.optimize, .{ .dvui = w.dvui, .core = w.core, .sdk = w.sdk }, w.consumer)
        else if (std.mem.eql(u8, p.name, "archive"))
            archive.addStaticModule(b, w.target, w.optimize, .{ .dvui = w.dvui, .core = w.core, .sdk = w.sdk }, w.consumer)
        else if (std.mem.eql(u8, p.name, "devtools"))
            devtools.addStaticModule(b, w.target, w.optimize, .{ .dvui = w.dvui, .core = w.core, .sdk = w.sdk }, w.consumer)
        else
            std.debug.panic("fizzy: plugin '{s}' has no module and is not one of fizzy's own (`fizzy.plugins`)", .{p.name});
        // A plugin this target does not build (markdown for the native exe on wasm) is left out.
        if (m) |module| out.append(b.allocator, .{ .name = p.name, .module = module }) catch @panic("OOM");
    }
    return .{ .plugins = out.items, .workbench = workbench_mod, .markdown = markdown_mod };
}

/// A copy of an application's plugin module for this executable, not the plugin package's module
/// itself: one application builds several executables (the packaged, Velopack-linked one beside
/// the plain one, the web one), each with its own `dvui`/`core`/`fizzy_sdk`, and one module cannot
/// import both sets. The copy keeps the plugin's own imports (its manifest options, its
/// dependencies) and gets this executable's framework modules.
pub fn rehome(b: *std.Build, w: Wiring, name: []const u8, src: *std.Build.Module) *std.Build.Module {
    const wasm = w.target.result.cpu.arch == .wasm32;
    const m = b.createModule(.{
        .target = w.target,
        .optimize = w.optimize,
        .root_source_file = src.root_source_file,
        .link_libc = !wasm,
        .single_threaded = if (wasm) true else null,
    });
    var it = src.import_table.iterator();
    while (it.next()) |kv| {
        const import = kv.key_ptr.*;
        if (std.mem.eql(u8, import, "dvui") or std.mem.eql(u8, import, "core") or std.mem.eql(u8, import, "fizzy_sdk") or std.mem.eql(u8, import, "icons")) continue;
        m.addImport(import, kv.value_ptr.*);
    }
    m.addImport("dvui", w.dvui);
    m.addImport("core", w.core);
    m.addImport("fizzy_sdk", w.sdk);
    if (w.icons) |icons| m.addImport("icons", icons);
    w.consumer.addImport(name, m);
    return m;
}
