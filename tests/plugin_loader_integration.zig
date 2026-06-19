//! Integration test: dlopen the pixelart dylib and register into a Host.
const std = @import("std");
const builtin = @import("builtin");

const sdk = @import("sdk");
const PluginLoader = @import("plugin_loader");
const test_opts = @import("plugin_loader_test_opts");

test "load pixelart dylib and register" {
    if (comptime builtin.target.cpu.arch == .wasm32) return error.SkipZigTest;

    var host = sdk.Host.init(std.testing.allocator);
    defer host.deinit();

    const before = host.plugins.items.len;
    var loaded = try PluginLoader.loadAndRegister(&host, test_opts.pixelart_dylib);
    defer loaded.lib.close();

    try std.testing.expect(host.plugins.items.len == before + 1);
    const pa = host.pluginById("pixelart") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("pixelart", pa.id);
    try std.testing.expect(host.sidebar_views.items.len >= 3);

    // Mechanism B: context setter is required and callable (no window needed for init io/debug).
    loaded.set_dvui_context(null, null, null, null);
}
