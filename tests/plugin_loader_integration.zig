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

    // Stand-in for app-owned `pixelart.State` — register only stores the pointer.
    var state_buf: [8192]u8 align(16) = undefined;

    const before = host.plugins.items.len;
    var loaded = try PluginLoader.loadAndRegister(&host, test_opts.pixelart_dylib, "pixelart", .{
        .gpa = &std.testing.allocator,
        .state = &state_buf,
        .packer = null,
    });
    defer loaded.lib.close();

    try std.testing.expect(host.plugins.items.len == before + 1);
    const pa = host.pluginById("pixelart") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("pixelart", pa.id);
    try std.testing.expect(host.sidebar_views.items.len >= 3);

    loaded.set_dvui_context(null, null, null, null);
    loaded.set_globals(@ptrCast(&std.testing.allocator), &state_buf, null);
}
