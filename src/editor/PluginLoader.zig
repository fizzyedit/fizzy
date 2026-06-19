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
    SetDvuiContextSymbolMissing,
    AbiMismatch,
    RegisterRejected,
};

pub const LoadedLib = struct {
    lib: std.DynLib,
    path: []const u8,
    set_dvui_context: dvui_context.SetContextFn,
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
    if (std.process.getEnvVarOwned(allocator, "FIZZY_PLUGIN_PATH")) |override| {
        return override;
    } else |_| {}
    return builtinPluginPath(allocator, exe_dir, builtin_name);
}

pub fn loadAndRegister(host: *Host, path: []const u8) LoadError!LoadedLib {
    var lib = std.DynLib.open(path) catch return error.DylibOpenFailed;
    errdefer lib.close();

    const abi_fn = lib.lookup(
        *const fn () callconv(.c) u32,
        dylib_api.symbol_abi_version,
    ) orelse return error.AbiSymbolMissing;
    if (!dylib_api.abiMatches(abi_fn())) return error.AbiMismatch;

    const reg_fn = lib.lookup(
        *const fn (?*Host) callconv(.c) u32,
        dylib_api.symbol_register,
    ) orelse return error.RegisterSymbolMissing;
    const status: dylib_api.RegisterStatus = @enumFromInt(reg_fn(host));
    switch (status) {
        .ok => {},
        .err_abi_mismatch => return error.AbiMismatch,
        else => return error.RegisterRejected,
    }

    const set_ctx = lib.lookup(
        dvui_context.SetContextFn,
        dylib_api.symbol_set_dvui_context,
    ) orelse return error.SetDvuiContextSymbolMissing;

    return .{
        .lib = lib,
        .path = path,
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
