//! Settings → Plugins: a pointer to the dedicated **Plugins** sidebar tab, which now owns the
//! full inventory + install/enable/disable/update controls (see `PluginStore.zig`). Kept as a
//! thin breadcrumb so users who look under Settings are directed to the right place.
const std = @import("std");
const dvui = @import("dvui");
const sdk = @import("sdk");

pub fn register(host: *sdk.Host) !void {
    try host.registerSettingsSection(.{
        .id = "shell.settings.plugins",
        .title = "Plugins",
        .draw = drawPlugins,
    });
}

fn drawPlugins(_: ?*anyopaque) anyerror!void {
    var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
    defer vbox.deinit();
    dvui.labelNoFmt(
        @src(),
        "Browse, install, enable/disable, and update plugins in the Plugins tab (the bag icon in the sidebar, above Settings).",
        .{},
        .{ .margin = .{ .y = 4 } },
    );
}
