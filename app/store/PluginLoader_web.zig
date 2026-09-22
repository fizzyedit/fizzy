//! Runtime plugin loading on the web: a plugin built as a wasm *side module* (see
//! `sdk/plugin_sdk.zig`'s `create` for wasm32 and `docs/REVIEW_2026-09.md` §2), fetched and
//! linked into the page by `web/index.html`'s `loadPlugin`, which hands back one function-table
//! index per entry point. On wasm32 a function pointer *is* a table index, so from there this
//! runs the same sequence the desktop loader runs (`PluginLoader.loadAndRegister`): fingerprint,
//! versions, id, inject the host's globals, `fizzy_plugin_register`.
//!
//! The fetch is asynchronous, so a load is two halves: `begin` asks the page, and the page's
//! `FizzyWebPluginReady` lands in `pump`'s callback on the next frame. There is no unload — a
//! side module cannot leave the table — so "disable" is "hide", as the review notes.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");

const sdk = @import("fizzy_sdk");
const Host = sdk.Host;
const dylib_api = sdk.dylib;
const dvui_context = sdk.dvui_context;
const version = sdk.version;

comptime {
    if (builtin.target.cpu.arch != .wasm32) @compileError("PluginLoader_web is wasm-only");
}

pub const LoadError = error{
    Unsupported,
    LoadFailed,
    AbiMismatch,
    AbiBuildEnvMismatch,
    SdkVersionMismatch,
    PluginIdMismatch,
    RegisterRejected,
    OutOfMemory,
};

pub const PluginVersionInfo = struct {
    plugin_version: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 },
    built_with_sdk_version: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 },
    min_sdk_version: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 },
    declared_id: ?[]const u8 = null,
};

/// The web's "open library": the entry points' table indices. Same read-shape as the desktop's
/// `LoadedLib` for the code that lists loaded plugins.
pub const LoadedLib = struct {
    lib: WebDynLib,
    /// The URL it was fetched from (owned by the caller of `loadAndRegister`).
    path: []const u8,
    plugin_id: []const u8 = "",
    version_info: PluginVersionInfo = .{},
    source_mtime_ns: i128 = 0,
    source_size: u64 = 0,
    set_globals: dylib_api.SetGlobalsFn,
    set_dvui_context: dvui_context.SetContextFn,
    set_render_bridge: sdk.render_bridge.SetRenderBridgeFn,
};

pub const PreRegister = struct {
    gpa: ?*const std.mem.Allocator = null,
    arg_b: ?*anyopaque = null,
    arg_c: ?*anyopaque = null,
};

/// Entry points by name → table index, in the order `web/index.html`'s `pluginEntryPoints`
/// lists them (the same order as `plugin_sdk.dylib_exports`).
pub const WebDynLib = struct {
    indices: [entry_names.len]u32,

    pub const entry_names = [_][]const u8{
        "fizzy_plugin_abi_fingerprint",
        "fizzy_plugin_sdk_version",
        "fizzy_plugin_min_sdk_version",
        "fizzy_plugin_version",
        "fizzy_plugin_id",
        "fizzy_plugin_manifest_zon",
        "fizzy_plugin_register",
        "fizzy_plugin_set_dvui_context",
        "fizzy_plugin_set_render_bridge",
        "fizzy_plugin_set_globals",
    };

    pub fn lookup(self: *const WebDynLib, comptime T: type, name: [:0]const u8) ?T {
        inline for (entry_names, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) {
                const idx = self.indices[i];
                if (idx == 0) return null;
                return @ptrFromInt(idx);
            }
        }
        return null;
    }

    pub fn close(_: *WebDynLib) void {}
};

pub fn pluginExtension() []const u8 {
    return "wasm";
}

// ---- the asynchronous half ------------------------------------------------------------------

const wasm = struct {
    extern "fizzy" fn fizzy_web_plugin_load(req: u32, id_ptr: [*]const u8, id_len: usize, url_ptr: [*]const u8, url_len: usize) void;
    extern "fizzy" fn fizzy_web_plugin_forget(id_ptr: [*]const u8, id_len: usize) void;
    extern "fizzy" fn fizzy_web_plugin_remember(id_ptr: [*]const u8, id_len: usize, url_ptr: [*]const u8, url_len: usize) void;
    extern "fizzy" fn fizzy_web_plugin_remembered_url(id_ptr: [*]const u8, id_len: usize, buf: [*]u8, buf_len: usize) usize;
};

/// The URL the page has for `id`, copied into `buf`, or null when it remembers none or the URL
/// is longer than `buf`. This is where a disabled plugin's build lives while it is not loaded:
/// there is no plugins directory to look in, so enabling one again reads it back from here.
pub fn rememberedUrl(id: []const u8, buf: []u8) ?[]const u8 {
    const n = wasm.fizzy_web_plugin_remembered_url(id.ptr, id.len, buf.ptr, buf.len);
    if (n == std.math.maxInt(u32) or n == 0 or n > buf.len) return null;
    return buf[0..n];
}

/// Drop `id` from the plugins the page brings back on the next visit (the page remembers
/// every plugin it linked, in `localStorage`, and requests them again at startup).
pub fn forget(id: []const u8) void {
    wasm.fizzy_web_plugin_forget(id.ptr, id.len);
}

/// Point `id` at `url` for the next visit. Called once a module has *registered*, not when the
/// page linked it: the page cannot tell whether this host will accept a build, and a remembered
/// build that is refused would fail again on every visit.
pub fn remember(id: []const u8, url: []const u8) void {
    wasm.fizzy_web_plugin_remember(id.ptr, id.len, url.ptr, url.len);
}

/// What the page reports for a request, delivered on `pump`.
pub const Arrival = struct {
    req: u32,
    /// Null when the page could not load it (fetch failed, not a side module, missing entry).
    lib: ?WebDynLib,
};

pub const ArrivedFn = *const fn (ctx: ?*anyopaque, arrival: Arrival) void;

const Pending = struct {
    req: u32,
    cb: ArrivedFn,
    ctx: ?*anyopaque,
    result: ?Arrival = null,
};

var pending: std.ArrayListUnmanaged(Pending) = .empty;
var pending_gpa: ?std.mem.Allocator = null;
var next_req: u32 = 1;

/// The allocator the page's requests draw on. Set once the app is up, before the page can
/// ask for anything.
pub fn init(gpa: std.mem.Allocator) void {
    pending_gpa = gpa;
}

/// Ask the page to fetch and link `url`. `cb` is called from `pump` when it has, with the entry
/// points or null. `id` is the plugin this is meant to be: the page remembers a linked plugin
/// under it, so that what comes back next visit is keyed by the plugin's real id rather than by
/// whatever its file happens to be called.
pub fn begin(gpa: std.mem.Allocator, id: []const u8, url: []const u8, cb: ArrivedFn, ctx: ?*anyopaque) error{OutOfMemory}!u32 {
    pending_gpa = gpa;
    const req = next_req;
    next_req += 1;
    try pending.append(gpa, .{ .req = req, .cb = cb, .ctx = ctx });
    wasm.fizzy_web_plugin_load(req, id.ptr, id.len, url.ptr, url.len);
    return req;
}

/// Deliver finished loads, on the frame.
pub fn pump() void {
    var i: usize = 0;
    while (i < pending.items.len) {
        const p = pending.items[i];
        if (p.result) |arrival| {
            _ = pending.orderedRemove(i);
            p.cb(p.ctx, arrival);
            continue;
        }
        i += 1;
    }
}

comptime {
    _ = &FizzyWebPluginAlloc;
    _ = &FizzyWebPluginReady;
    _ = &FizzyWebPluginFailed;
}

/// The page's allocation for a plugin's data segment and for the index list it hands back.
/// The host's heap: a side module lives in the host's memory.
export fn FizzyWebPluginAlloc(size: usize, alignment: usize) usize {
    const gpa = pending_gpa orelse return 0;
    const a: std.mem.Alignment = .fromByteUnits(@max(alignment, 1));
    const buf = gpa.rawAlloc(@max(size, 1), a, @returnAddress()) orelse return 0;
    return @intFromPtr(buf);
}

export fn FizzyWebPluginReady(req: u32, list: [*]const u32, count: usize) void {
    var lib: WebDynLib = .{ .indices = @splat(0) };
    const n = @min(count, WebDynLib.entry_names.len);
    for (list[0..n], 0..) |idx, i| lib.indices[i] = idx;
    for (pending.items) |*p| {
        if (p.req == req) p.result = .{ .req = req, .lib = lib };
    }
}

export fn FizzyWebPluginFailed(req: u32) void {
    for (pending.items) |*p| {
        if (p.req == req) p.result = .{ .req = req, .lib = null };
    }
}

// ---- the synchronous half: the desktop loader's sequence over table indices --------------------

fn readVersionTriplet(get_fn: ?dylib_api.GetSdkVersionFn) std.SemanticVersion {
    if (get_fn) |f| return dylib_api.semverFromTriplet(f());
    return .{ .major = 0, .minor = 0, .patch = 0 };
}

/// A linked module that has passed every check and has not yet been registered. Split from
/// `register` so an update can find out whether the new build is acceptable *before* the running
/// one is torn down: everything that can reject a module (fingerprint, SDK version, declared id,
/// missing entry points) happens in `prepare`, and only the call into the plugin happens after.
pub const Prepared = struct {
    lib: WebDynLib,
    url: []const u8,
    plugin_id: []const u8,
    version_info: PluginVersionInfo,
    set_globals: dylib_api.SetGlobalsFn,
    set_ctx: dvui_context.SetContextFn,
    set_bridge: sdk.render_bridge.SetRenderBridgeFn,
    reg_fn: *const fn (?*Host) callconv(.c) u32,

    /// Hand the module the host's globals and let it register. The only step that runs code the
    /// page fetched, and the only one that cannot be undone by walking away.
    pub fn register(self: Prepared, host: *Host, pre: ?PreRegister) LoadError!LoadedLib {
        if (pre) |inject| {
            self.set_globals(if (inject.gpa) |gpa| @ptrCast(gpa) else null, inject.arg_b, inject.arg_c);
        }
        const status: dylib_api.RegisterStatus = @enumFromInt(self.reg_fn(host));
        switch (status) {
            .ok => {},
            .err_abi_mismatch => return error.AbiMismatch,
            .err_sdk_version => return error.SdkVersionMismatch,
            else => return error.RegisterRejected,
        }
        return .{
            .lib = self.lib,
            .path = self.url,
            .plugin_id = self.plugin_id,
            .version_info = self.version_info,
            .set_globals = self.set_globals,
            .set_dvui_context = self.set_ctx,
            .set_render_bridge = self.set_bridge,
        };
    }
};

/// Everything that can refuse a module the page has linked. `url` is kept as `LoadedLib.path`.
pub fn prepare(url: []const u8, expected_id: []const u8, lib_in: WebDynLib) LoadError!Prepared {
    var lib = lib_in;
    const abi_fp_fn = lib.lookup(dylib_api.GetAbiFingerprintFn, dylib_api.symbol_abi_fingerprint) orelse return error.LoadFailed;
    const plugin_fp = abi_fp_fn();
    if (!dylib_api.fingerprintMatches(plugin_fp)) {
        const built_with = readVersionTriplet(lib.lookup(dylib_api.GetSdkVersionFn, dylib_api.symbol_sdk_version));
        if (std.SemanticVersion.order(built_with, version.sdk_version) == .eq) return error.AbiBuildEnvMismatch;
        return error.AbiMismatch;
    }

    const get_sdk_version = lib.lookup(dylib_api.GetSdkVersionFn, dylib_api.symbol_sdk_version);
    const get_min_sdk = lib.lookup(dylib_api.GetSdkVersionFn, dylib_api.symbol_min_sdk_version);
    const get_plugin_version = lib.lookup(dylib_api.GetSdkVersionFn, dylib_api.symbol_plugin_version);
    const get_plugin_id = lib.lookup(dylib_api.GetPluginIdFn, dylib_api.symbol_plugin_id);

    const built_with = readVersionTriplet(get_sdk_version);
    const min_sdk = readVersionTriplet(get_min_sdk);
    const plugin_version = readVersionTriplet(get_plugin_version);
    if (get_min_sdk != null and !version.sdkVersionSatisfies(version.sdk_version, min_sdk)) return error.SdkVersionMismatch;
    if (get_plugin_id) |id_fn| {
        if (!std.mem.eql(u8, std.mem.span(id_fn()), expected_id)) return error.PluginIdMismatch;
    }

    return .{
        .lib = lib,
        .url = url,
        .plugin_id = expected_id,
        .version_info = .{
            .plugin_version = plugin_version,
            .built_with_sdk_version = built_with,
            .min_sdk_version = min_sdk,
            .declared_id = if (get_plugin_id) |f| std.mem.span(f()) else null,
        },
        .set_globals = lib.lookup(dylib_api.SetGlobalsFn, dylib_api.symbol_set_globals) orelse return error.LoadFailed,
        .set_ctx = lib.lookup(dvui_context.SetContextFn, dylib_api.symbol_set_dvui_context) orelse return error.LoadFailed,
        .set_bridge = lib.lookup(sdk.render_bridge.SetRenderBridgeFn, dylib_api.symbol_set_render_bridge) orelse return error.LoadFailed,
        .reg_fn = lib.lookup(*const fn (?*Host) callconv(.c) u32, dylib_api.symbol_register) orelse return error.LoadFailed,
    };
}

/// Check and register in one step — the desktop loader's shape, for a plain load.
pub fn loadAndRegister(
    host: *Host,
    allocator: std.mem.Allocator,
    url: []const u8,
    expected_id: []const u8,
    lib_in: WebDynLib,
    pre: ?PreRegister,
) LoadError!LoadedLib {
    _ = allocator;
    const ready = try prepare(url, expected_id, lib_in);
    return ready.register(host, pre);
}
