//! Native runtime loader for Fizzy plugin dylibs.
//!
//! Opens a prebuilt plugin library, checks the SDK ABI fingerprint and version, and calls
//! `fizzy_plugin_register`. The returned `std.DynLib` must stay open for the app's lifetime.
//!
//! **Native targets only.** Wasm imports `PluginLoader_stub.zig` instead.
const std = @import("std");
const builtin = @import("builtin");

const sdk = @import("sdk");
const Host = sdk.Host;
const dylib_api = sdk.dylib;
const dvui_context = sdk.dvui_context;
const version = sdk.version;

/// Zig 0.16.0's `std.DynLib` dropped Windows support; this thin wrapper restores it for
/// Windows while delegating elsewhere. Shape matches `std.DynLib.{open, close, lookup}`.
pub const DynLib = if (builtin.os.tag == .windows) WindowsDynLib else std.DynLib;

const WindowsDynLib = struct {
    const windows = std.os.windows;

    extern "kernel32" fn LoadLibraryW(lpLibFileName: [*:0]const u16) callconv(.winapi) ?windows.HMODULE;
    extern "kernel32" fn GetProcAddress(hModule: windows.HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn FreeLibrary(hLibModule: windows.HMODULE) callconv(.winapi) windows.BOOL;

    handle: windows.HMODULE,

    pub const Error = error{ FileNotFound, InvalidUtf8 };

    pub fn open(path: []const u8) Error!WindowsDynLib {
        var buf: [windows.PATH_MAX_WIDE:0]u16 = undefined;
        const len = std.unicode.wtf8ToWtf16Le(buf[0..], path) catch return error.InvalidUtf8;
        if (len >= buf.len) return error.FileNotFound;
        buf[len] = 0;
        const wide_path: [*:0]const u16 = buf[0..len :0].ptr;
        const handle = LoadLibraryW(wide_path) orelse return error.FileNotFound;
        return .{ .handle = handle };
    }

    pub fn close(self: *WindowsDynLib) void {
        _ = FreeLibrary(self.handle);
        self.* = undefined;
    }

    pub fn lookup(self: *WindowsDynLib, comptime T: type, name: [:0]const u8) ?T {
        if (GetProcAddress(self.handle, name.ptr)) |sym| {
            return @as(T, @ptrCast(@alignCast(sym)));
        }
        return null;
    }
};

pub const LoadError = error{
    DylibOpenFailed,
    AbiFingerprintSymbolMissing,
    RegisterSymbolMissing,
    SetGlobalsSymbolMissing,
    SetDvuiContextSymbolMissing,
    SetRenderBridgeSymbolMissing,
    SdkVersionSymbolMissing,
    AbiMismatch,
    SdkVersionMismatch,
    PluginIdMismatch,
    RegisterRejected,
};

pub const PluginVersionInfo = struct {
    plugin_version: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 },
    built_with_sdk_version: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 },
    min_sdk_version: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 },
    declared_id: ?[]const u8 = null,
};

pub const LoadedLib = struct {
    lib: DynLib,
    path: []const u8,
    /// Declared plugin id from the dylib (must match filename basename).
    plugin_id: []const u8,
    version_info: PluginVersionInfo = .{},
    set_globals: dylib_api.SetGlobalsFn,
    set_dvui_context: dvui_context.SetContextFn,
    set_render_bridge: sdk.render_bridge.SetRenderBridgeFn,
};

/// Host-owned pointers injected into the plugin image immediately before `register`.
pub const PreRegister = struct {
    gpa: ?*const std.mem.Allocator = null,
    arg_b: ?*anyopaque = null,
    arg_c: ?*anyopaque = null,
};

/// Platform-specific plugin dylib extension.
pub fn pluginExtension() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "dll",
        .macos => "dylib",
        else => "so",
    };
}

/// `{name}.{ext}` — flat layout under `{dir}/plugins/`.
pub fn pluginFilename(name: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ name, pluginExtension() });
}

/// `{exe_dir}/plugins/{name}.{ext}`
pub fn builtinPluginPath(
    allocator: std.mem.Allocator,
    exe_dir: []const u8,
    name: []const u8,
) ![]const u8 {
    const file_name = try pluginFilename(name, allocator);
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ exe_dir, "plugins", file_name });
}

/// Resolve a plugin dylib path: `FIZZY_PLUGIN_PATH` when set, else the built-in layout above.
pub fn resolvePluginPath(
    allocator: std.mem.Allocator,
    exe_dir: []const u8,
    builtin_name: []const u8,
) ![]const u8 {
    if (std.process.Environ.getAlloc(nativeEnviron(), allocator, "FIZZY_PLUGIN_PATH")) |override| {
        return override;
    } else |_| {}
    return builtinPluginPath(allocator, exe_dir, builtin_name);
}

fn nativeEnviron() std.process.Environ {
    if (builtin.os.tag == .windows) {
        return .{ .block = .global };
    }
    var n: usize = 0;
    while (std.c.environ[n] != null) : (n += 1) {}
    const slice: [:null]const ?[*:0]const u8 = @as([*:null]const ?[*:0]const u8, @ptrCast(std.c.environ))[0..n :null];
    return .{ .block = .{ .slice = slice } };
}

fn lookupVersionFn(lib: *DynLib, symbol: [:0]const u8) ?dylib_api.GetSdkVersionFn {
    return lib.lookup(dylib_api.GetSdkVersionFn, symbol);
}

fn lookupPluginIdFn(lib: *DynLib, symbol: [:0]const u8) ?dylib_api.GetPluginIdFn {
    return lib.lookup(dylib_api.GetPluginIdFn, symbol);
}

fn readVersionTriplet(get_fn: ?dylib_api.GetSdkVersionFn) std.SemanticVersion {
    if (get_fn) |f| {
        return dylib_api.semverFromTriplet(f());
    }
    return .{ .major = 0, .minor = 0, .patch = 0 };
}

pub fn loadAndRegister(
    host: *Host,
    path: []const u8,
    expected_id: []const u8,
    pre: ?PreRegister,
) LoadError!LoadedLib {
    var lib = DynLib.open(path) catch return error.DylibOpenFailed;
    errdefer lib.close();

    const abi_fp_fn = lib.lookup(
        dylib_api.GetAbiFingerprintFn,
        dylib_api.symbol_abi_fingerprint,
    ) orelse return error.AbiFingerprintSymbolMissing;
    const plugin_fp = abi_fp_fn();
    if (!dylib_api.fingerprintMatches(plugin_fp)) {
        if (allowAbiWarn()) {
            std.log.warn("plugin '{s}': ABI fingerprint mismatch (host 0x{x}, plugin 0x{x}) — loading anyway (FIZZY_PLUGIN_ABI_WARN)", .{
                expected_id,
                dylib_api.abi_fingerprint,
                plugin_fp,
            });
        } else {
            return error.AbiMismatch;
        }
    }

    const get_sdk_version = lookupVersionFn(&lib, dylib_api.symbol_sdk_version);
    const get_min_sdk = lookupVersionFn(&lib, dylib_api.symbol_min_sdk_version);
    const get_plugin_version = lookupVersionFn(&lib, dylib_api.symbol_plugin_version);
    const get_plugin_id = lookupPluginIdFn(&lib, dylib_api.symbol_plugin_id);

    const built_with = readVersionTriplet(get_sdk_version);
    const min_sdk = readVersionTriplet(get_min_sdk);
    const plugin_version = readVersionTriplet(get_plugin_version);

    if (get_min_sdk != null and !version.sdkVersionSatisfies(version.sdk_version, min_sdk)) {
        return error.SdkVersionMismatch;
    }

    if (get_plugin_id) |id_fn| {
        const declared = std.mem.span(id_fn());
        if (!std.mem.eql(u8, declared, expected_id)) return error.PluginIdMismatch;
    }

    const set_globals = lib.lookup(
        dylib_api.SetGlobalsFn,
        dylib_api.symbol_set_globals,
    ) orelse return error.SetGlobalsSymbolMissing;

    const reg_fn = lib.lookup(
        *const fn (?*Host) callconv(.c) u32,
        dylib_api.symbol_register,
    ) orelse return error.RegisterSymbolMissing;

    const set_ctx = lib.lookup(
        dvui_context.SetContextFn,
        dylib_api.symbol_set_dvui_context,
    ) orelse return error.SetDvuiContextSymbolMissing;

    const set_bridge = lib.lookup(
        sdk.render_bridge.SetRenderBridgeFn,
        dylib_api.symbol_set_render_bridge,
    ) orelse return error.SetRenderBridgeSymbolMissing;

    if (pre) |inject| {
        set_globals(
            if (inject.gpa) |gpa| @ptrCast(gpa) else null,
            inject.arg_b,
            inject.arg_c,
        );
    }

    const status: dylib_api.RegisterStatus = @enumFromInt(reg_fn(host));
    switch (status) {
        .ok => {},
        .err_abi_mismatch => return error.AbiMismatch,
        .err_sdk_version => return error.SdkVersionMismatch,
        else => return error.RegisterRejected,
    }

    return .{
        .lib = lib,
        .path = path,
        .plugin_id = expected_id,
        .version_info = .{
            .plugin_version = plugin_version,
            .built_with_sdk_version = built_with,
            .min_sdk_version = min_sdk,
            .declared_id = if (get_plugin_id) |f| std.mem.span(f()) else null,
        },
        .set_globals = set_globals,
        .set_dvui_context = set_ctx,
        .set_render_bridge = set_bridge,
    };
}

fn allowAbiWarn() bool {
    if (builtin.mode != .Debug) return false;
    if (std.c.getenv("FIZZY_PLUGIN_ABI_WARN")) |v| {
        return std.mem.eql(u8, std.mem.span(v), "1");
    }
    return false;
}

/// Best-effort read of version exports from a dylib (for failure diagnostics).
pub fn probeVersionInfo(path: []const u8) ?PluginVersionInfo {
    var lib = DynLib.open(path) catch return null;
    defer lib.close();
    const get_sdk_version = lookupVersionFn(&lib, dylib_api.symbol_sdk_version);
    const get_min_sdk = lookupVersionFn(&lib, dylib_api.symbol_min_sdk_version);
    const get_plugin_version = lookupVersionFn(&lib, dylib_api.symbol_plugin_version);
    return .{
        .plugin_version = readVersionTriplet(get_plugin_version),
        .built_with_sdk_version = readVersionTriplet(get_sdk_version),
        .min_sdk_version = readVersionTriplet(get_min_sdk),
    };
}

test "builtin plugin path joins exe_dir/plugins" {
    const path = try builtinPluginPath(std.testing.allocator, "/app", "pixi");
    defer std.testing.allocator.free(path);
    switch (builtin.os.tag) {
        .windows => try std.testing.expectEqualStrings("/app/plugins/pixi.dll", path),
        .macos => try std.testing.expectEqualStrings("/app/plugins/pixi.dylib", path),
        else => try std.testing.expectEqualStrings("/app/plugins/pixi.so", path),
    }
}

test "sdk version satisfy" {
    try std.testing.expect(version.sdkVersionSatisfies(.{ .major = 0, .minor = 2, .patch = 0 }, .{ .major = 0, .minor = 1, .patch = 5 }));
    try std.testing.expect(!version.sdkVersionSatisfies(.{ .major = 0, .minor = 0, .patch = 9 }, .{ .major = 0, .minor = 1, .patch = 0 }));
}
