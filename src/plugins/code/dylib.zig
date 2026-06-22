//! Dynamic-library root for the code plugin.
//!
//! Static/desktop and web builds link `module.zig` into the exe. Native dylib builds use
//! this file as `addLibrary(.dynamic)` root so only the C entry symbols are exported.
const sdk = @import("sdk");
const dvui = @import("dvui");
const plugin = @import("src/plugin.zig");

export fn fizzy_plugin_abi_version() callconv(.c) u32 {
    return sdk.dylib.abi_version;
}

export fn fizzy_plugin_register(host: ?*sdk.Host) callconv(.c) u32 {
    if (host == null) return @intFromEnum(sdk.dylib.RegisterStatus.err_null_host);
    plugin.register(host.?) catch return @intFromEnum(sdk.dylib.RegisterStatus.err_register);
    return @intFromEnum(sdk.dylib.RegisterStatus.ok);
}

export fn fizzy_plugin_set_dvui_context(
    window: ?*dvui.Window,
    io: ?*anyopaque,
    ft2lib: ?*anyopaque,
    debug: ?*dvui.Debug,
) callconv(.c) void {
    sdk.dvui_context.inject(window, io, ft2lib, debug);
}

/// Code convention: `gpa`, `host`, `state` (see `Globals.installRuntime`).
export fn fizzy_plugin_set_globals(
    gpa: ?*const anyopaque,
    host: ?*anyopaque,
    state: ?*anyopaque,
) callconv(.c) void {
    const Globals = @import("src/Globals.zig");
    Globals.installRuntime(
        if (gpa) |p| @ptrCast(@alignCast(p)) else null,
        if (host) |p| @ptrCast(@alignCast(p)) else null,
        if (state) |p| @ptrCast(@alignCast(p)) else null,
    );
}
