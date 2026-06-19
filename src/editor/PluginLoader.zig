//! Native runtime loader for Fizzy plugin dylibs (Phase 5b.3).
//!
//! Opens a prebuilt plugin library, checks the SDK ABI version, and calls
//! `fizzy_plugin_register`. The returned `std.DynLib` must stay open for the
//! app's lifetime — vtable hooks live in the dylib image.
//!
//! **Native targets only.** Wasm imports `PluginLoader_stub.zig` instead.
const std = @import("std");
const builtin = @import("builtin");

const sdk = @import("sdk");
const Host = sdk.Host;
const dylib_api = sdk.dylib;
const dvui_context = sdk.dvui_context;

pub const LoadError = error{
    DylibOpenFailed,
    AbiSymbolMissing,
    RegisterSymbolMissing,
    SetGlobalsSymbolMissing,
    SetDvuiContextSymbolMissing,
    AbiMismatch,
    RegisterRejected,
};

pub const LoadedLib = struct {
    lib: std.DynLib,
    path: []const u8,
    /// Built-in plugin id (`"pixelart"`, `"workbench"`, …).
    plugin_id: []const u8,
    set_globals: dylib_api.SetGlobalsFn,
    set_dvui_context: dvui_context.SetContextFn,
};

/// Host-owned pointers injected into the plugin image immediately before `register`.
pub const PreRegister = struct {
    gpa: ?*const std.mem.Allocator = null,
    state: ?*anyopaque = null,
    packer: ?*anyopaque = null,
};

/// `{exe_dir}/plugins/{pluginFilename(name)}`
pub fn builtinPluginPath(
    allocator: std.mem.Allocator,
    exe_dir: []const u8,
    name: []const u8,
) ![]const u8 {
    const file_name = switch (builtin.os.tag) {
        .windows => try std.fmt.allocPrint(allocator, "{s}.dll", .{name}),
        .macos => try std.fmt.allocPrint(allocator, "lib{s}.dylib", .{name}),
        else => try std.fmt.allocPrint(allocator, "lib{s}.so", .{name}),
    };
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

pub fn loadAndRegister(
    host: *Host,
    path: []const u8,
    plugin_id: []const u8,
    pre: ?PreRegister,
) LoadError!LoadedLib {
    var lib = std.DynLib.open(path) catch return error.DylibOpenFailed;
    errdefer lib.close();

    const abi_fn = lib.lookup(
        *const fn () callconv(.c) u32,
        dylib_api.symbol_abi_version,
    ) orelse return error.AbiSymbolMissing;
    if (!dylib_api.abiMatches(abi_fn())) return error.AbiMismatch;

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

    if (pre) |inject| {
        set_globals(
            if (inject.gpa) |gpa| @ptrCast(gpa) else null,
            inject.state,
            inject.packer,
        );
    }

    const status: dylib_api.RegisterStatus = @enumFromInt(reg_fn(host));
    switch (status) {
        .ok => {},
        .err_abi_mismatch => return error.AbiMismatch,
        else => return error.RegisterRejected,
    }

    return .{
        .lib = lib,
        .path = path,
        .plugin_id = plugin_id,
        .set_globals = set_globals,
        .set_dvui_context = set_ctx,
    };
}

test "builtin plugin path joins exe_dir/plugins" {
    const path = try builtinPluginPath(std.testing.allocator, "/app", "pixelart");
    defer std.testing.allocator.free(path);
    switch (builtin.os.tag) {
        .windows => try std.testing.expectEqualStrings("/app/plugins/pixelart.dll", path),
        .macos => try std.testing.expectEqualStrings("/app/plugins/libpixelart.dylib", path),
        else => try std.testing.expectEqualStrings("/app/plugins/libpixelart.so", path),
    }
}
