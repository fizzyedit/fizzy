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
pub const guides = @import("../plugins/guides/static/integration.zig");

/// Fizzy's own plugins, as entries in the list an application links (`fizzy.plugins`). An entry
/// with no module is built by fizzy for each executable, wired to that executable's framework.
pub const entries = struct {
    pub const workbench: BundledPlugin = .{ .name = "workbench" };
    pub const text: BundledPlugin = .{ .name = "text" };
    pub const image: BundledPlugin = .{ .name = "image" };
    pub const archive: BundledPlugin = .{ .name = "archive" };
    pub const markdown: BundledPlugin = .{ .name = "markdown" };
    pub const devtools: BundledPlugin = .{ .name = "devtools" };
    pub const guides: BundledPlugin = .{ .name = "guides" };

    /// What fizzy itself links, in its sidebar order.
    pub const all = [_]BundledPlugin{ @This().workbench, @This().text, @This().image, @This().archive, @This().markdown, @This().devtools, @This().guides };
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
    optimize: std.lang.OptimizeMode,
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

    var graph: Rehome = .{ .b = b, .w = w };
    defer graph.deinit();
    var out: std.ArrayList(BundledPlugin) = .empty;
    for (plugins) |p| {
        const m: ?*std.Build.Module = if (p.module) |src| graph.copy(p.name, src) else if (std.mem.eql(u8, p.name, "workbench"))
            workbench_mod
        else if (std.mem.eql(u8, p.name, "markdown"))
            markdown_mod
        else if (std.mem.eql(u8, p.name, "text"))
            text.addStaticModule(b, w.target, w.optimize, .{ .dvui = w.dvui, .core = w.core, .sdk = w.sdk, .icons = w.icons }, w.consumer)
        else if (std.mem.eql(u8, p.name, "image"))
            image.addStaticModule(b, w.target, w.optimize, .{ .dvui = w.dvui, .core = w.core, .sdk = w.sdk, .icons = w.icons }, w.consumer)
        else if (std.mem.eql(u8, p.name, "archive"))
            archive.addStaticModule(b, w.target, w.optimize, .{ .dvui = w.dvui, .core = w.core, .sdk = w.sdk }, w.consumer)
        else if (std.mem.eql(u8, p.name, "devtools"))
            devtools.addStaticModule(b, w.target, w.optimize, .{ .dvui = w.dvui, .core = w.core, .sdk = w.sdk }, w.consumer)
        else if (std.mem.eql(u8, p.name, "guides"))
            guides.addStaticModule(b, w.target, w.optimize, .{ .dvui = w.dvui, .core = w.core, .sdk = w.sdk }, w.consumer)
        else
            std.debug.panic("fizzy: plugin '{s}' has no module and is not one of fizzy's own (`fizzy.plugins`)", .{p.name});
        // A plugin this target does not build (markdown for the native exe on wasm) is left out.
        if (m) |module| {
            // Only an application's re-homed module is imported here, as `rehome` always did;
            // fizzy's own are wired to the consumer by their `addStaticModule`.
            if (p.module != null) w.consumer.addImport(p.name, module);
            out.append(b.allocator, .{ .name = p.name, .module = module }) catch @panic("OOM");
        }
    }
    return .{ .plugins = out.items, .workbench = workbench_mod, .markdown = markdown_mod };
}

/// Rebind the framework-dependent portion of a plugin graph for one executable.
/// Modules independent of the framework retain their identity. Web C modules must leave
/// `link_libc` unset or false; true declares a libc requirement and fails with the module name.
pub fn rehome(b: *std.Build, w: Wiring, name: []const u8, src: *std.Build.Module) *std.Build.Module {
    var graph: Rehome = .{ .b = b, .w = w };
    defer graph.deinit();
    const m = graph.copy(name, src);
    w.consumer.addImport(name, m);
    return m;
}

const Rehome = struct {
    b: *std.Build,
    w: Wiring,
    copies: std.AutoHashMapUnmanaged(*std.Build.Module, *std.Build.Module) = .empty,
    /// Every module seen so far; each is walked once however many plugins reach it.
    seen: std.AutoHashMapUnmanaged(*std.Build.Module, void) = .empty,
    /// The seen modules that must be copied for this consumer: the framework's dependants and
    /// whatever reaches one, or is pinned to a target or optimize mode this consumer is not.
    stale: std.AutoHashMapUnmanaged(*std.Build.Module, void) = .empty,

    /// The plugin root being copied: a native one links libc, as plugin roots always have.
    root: ?*std.Build.Module = null,

    fn deinit(self: *Rehome) void {
        self.copies.deinit(self.b.allocator);
        self.seen.deinit(self.b.allocator);
        self.stale.deinit(self.b.allocator);
    }

    fn framework(self: *const Rehome, name: []const u8) ?*std.Build.Module {
        if (std.mem.eql(u8, name, "dvui")) return self.w.dvui;
        if (std.mem.eql(u8, name, "core")) return self.w.core;
        if (std.mem.eql(u8, name, "fizzy_sdk")) return self.w.sdk;
        if (std.mem.eql(u8, name, "icons")) return self.w.icons;
        return null;
    }

    fn isFrameworkName(name: []const u8) bool {
        for ([_][]const u8{ "dvui", "core", "fizzy_sdk", "icons" }) |n| if (std.mem.eql(u8, name, n)) return true;
        return false;
    }

    /// A module pinned to a target or optimize mode other than the consumer's cannot be shared
    /// with it: a wasm build must not link a module still built for the native target.
    fn pinnedElsewhere(self: *const Rehome, m: *const std.Build.Module) bool {
        if (m.resolved_target) |t| {
            const mine = self.w.target.result;
            if (t.result.cpu.arch != mine.cpu.arch or t.result.os.tag != mine.os.tag or t.result.abi != mine.abi) return true;
        }
        if (m.optimize) |o| if (o != self.w.optimize) return true;
        return false;
    }

    /// Classify everything reachable from `src` that has not been seen. A module reached from
    /// `src` imports only modules that are new here or were fully classified before, so the
    /// fixed point over the new ones is the answer for all of them, cycles included.
    fn analyze(self: *Rehome, src: *std.Build.Module) void {
        const gpa = self.b.allocator;
        var fresh: std.ArrayList(*std.Build.Module) = .empty;
        defer fresh.deinit(gpa);
        var pending: std.ArrayList(*std.Build.Module) = .empty;
        defer pending.deinit(gpa);
        // Build setup cannot continue after allocation failure.
        pending.append(gpa, src) catch @panic("OOM");
        while (pending.pop()) |m| {
            if ((self.seen.getOrPut(gpa, m) catch @panic("OOM")).found_existing) continue;
            fresh.append(gpa, m) catch @panic("OOM");
            for (m.import_table.values()) |imported| pending.append(gpa, imported) catch @panic("OOM");
        }
        for (fresh.items) |m| {
            var direct = self.pinnedElsewhere(m);
            for (m.import_table.keys()) |name| direct = direct or isFrameworkName(name);
            if (direct) self.stale.put(gpa, m, {}) catch @panic("OOM");
        }
        var changed = true;
        while (changed) {
            changed = false;
            for (fresh.items) |m| {
                if (self.stale.contains(m)) continue;
                for (m.import_table.values()) |imported| if (self.stale.contains(imported)) {
                    self.stale.put(gpa, m, {}) catch @panic("OOM");
                    changed = true;
                    break;
                };
            }
        }
    }

    /// Re-create `src` for this consumer through `std.Build`'s public API, so the copy owns its
    /// lists outright (a struct copy would alias the source's backing storage, and every later
    /// `add*` on one would show in the other). Every input a module can carry is replayed.
    fn recreate(self: *Rehome, name: []const u8, src: *std.Build.Module) *std.Build.Module {
        const wasm = self.w.target.result.cpu.arch == .wasm32;
        const m = self.b.createModule(.{
            .root_source_file = src.root_source_file,
            .target = self.w.target,
            .optimize = self.w.optimize,
            .link_libc = if (wasm) false else if (src == self.root) true else (src.link_libc orelse self.w.consumer.link_libc),
            .link_libcpp = src.link_libcpp,
            .single_threaded = self.w.consumer.single_threaded,
            .strip = src.strip,
            .unwind_tables = src.unwind_tables,
            .dwarf_format = src.dwarf_format,
            .code_model = src.code_model,
            .stack_protector = src.stack_protector,
            .stack_check = src.stack_check,
            .sanitize_c = src.sanitize_c,
            .sanitize_thread = src.sanitize_thread,
            .fuzz = src.fuzz,
            .valgrind = src.valgrind,
            .pic = src.pic,
            .red_zone = src.red_zone,
            .omit_frame_pointer = src.omit_frame_pointer,
            .error_tracing = src.error_tracing,
            .no_builtin = src.no_builtin,
            .patchable_function_entry = src.patchable_function_entry,
        });
        m.export_symbol_names = src.export_symbol_names;
        for (src.link_objects.items) |object| switch (object) {
            .c_source_file => |f| {
                if (wasm and src.link_libc == true) std.debug.panic("fizzy: web module '{s}' has C sources requiring libc", .{name});
                m.addCSourceFile(f.*);
            },
            .c_source_files => |f| {
                if (wasm and src.link_libc == true) std.debug.panic("fizzy: web module '{s}' has C sources requiring libc", .{name});
                m.addCSourceFiles(.{ .root = f.root, .files = f.files, .flags = f.flags, .language = f.language });
            },
            .static_path => |p| m.addObjectFile(p),
            .assembly_file => |p| m.addAssemblyFile(p),
            .system_lib => |l| m.linkSystemLibrary(l.name, .{
                .needed = l.needed,
                .weak = l.weak,
                .use_pkg_config = l.use_pkg_config,
                .preferred_link_mode = l.preferred_link_mode,
                .search_strategy = l.search_strategy,
            }),
            .win32_resource_file => |f| m.addWin32ResourceFile(f.*),
            // A compile step is built for one target and cannot follow the module to another.
            .other_step => std.debug.panic("fizzy: module '{s}' links a compile step, which cannot be re-homed to another target", .{name}),
        };
        for (src.include_dirs.items) |dir| switch (dir) {
            .path => |p| m.addIncludePath(p),
            .path_system => |p| m.addSystemIncludePath(p),
            .path_after => |p| m.addAfterIncludePath(p),
            .framework_path => |p| m.addFrameworkPath(p),
            .framework_path_system => |p| m.addSystemFrameworkPath(p),
            .config_header_step => |h| m.addConfigHeader(h),
            .embed_path => |p| m.addEmbedPath(p),
            // The compile step itself was refused with its link object above.
            .other_step => {},
        };
        for (src.c_macros.items) |macro| {
            // `addCMacro` stores `-Dname=value`.
            const body = macro["-D".len..];
            const eq = std.mem.indexOfScalar(u8, body, '=') orelse body.len;
            m.addCMacro(body[0..eq], if (eq < body.len) body[eq + 1 ..] else "");
        }
        for (src.lib_paths.items) |p| m.addLibraryPath(p);
        for (src.rpaths.items) |r| switch (r) {
            .lazy_path => |p| m.addRPath(p),
            .special => |bytes| m.addRPathSpecial(bytes),
        };
        var frameworks = src.frameworks.iterator();
        while (frameworks.next()) |kv| m.linkFramework(kv.key_ptr.*, kv.value_ptr.*);
        return m;
    }

    /// A plugin's root module is always copied and always gets this consumer's framework modules,
    /// whether or not its own table named them: its build need not wire what its source imports.
    fn copy(self: *Rehome, name: []const u8, src: *std.Build.Module) *std.Build.Module {
        self.analyze(src);
        self.stale.put(self.b.allocator, src, {}) catch @panic("OOM");
        self.root = src;
        const m = self.copyAnalyzed(name, src);
        inline for (.{ "dvui", "core", "fizzy_sdk", "icons" }) |import_name| {
            if (m.import_table.get(import_name) == null) if (self.framework(import_name)) |fw| m.addImport(import_name, fw);
        }
        return m;
    }

    fn copyAnalyzed(self: *Rehome, name: []const u8, src: *std.Build.Module) *std.Build.Module {
        if (self.copies.get(src)) |m| return m;
        if (!self.stale.contains(src)) return src;
        const m = self.recreate(name, src);
        // Memoise before descending so cycles and diamond imports reuse the same copy.
        self.copies.put(self.b.allocator, src, m) catch @panic("OOM");
        var it = src.import_table.iterator();
        while (it.next()) |kv| {
            const import_name = kv.key_ptr.*;
            if (std.mem.eql(u8, import_name, "icons") and self.w.icons == null) continue;
            m.addImport(import_name, self.framework(import_name) orelse self.copyAnalyzed(import_name, kv.value_ptr.*));
        }
        return m;
    }
};
