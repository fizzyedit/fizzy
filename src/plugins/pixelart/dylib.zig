//! Dynamic-library root for the pixel-art plugin (Phase 5b).
//!
//! Static/desktop and web builds link `module.zig` into the exe. Native dylib builds use
//! this file as `addLibrary(.dynamic)` root so only the C entry symbols are exported.
const sdk = @import("sdk");
const plugin = @import("src/plugin.zig");

export fn fizzy_plugin_abi_version() callconv(.c) u32 {
    return sdk.dylib.abi_version;
}

export fn fizzy_plugin_register(host: ?*sdk.Host) callconv(.c) u32 {
    if (host == null) return @intFromEnum(sdk.dylib.RegisterStatus.err_null_host);
    plugin.register(host.?) catch return @intFromEnum(sdk.dylib.RegisterStatus.err_register);
    return @intFromEnum(sdk.dylib.RegisterStatus.ok);
}
