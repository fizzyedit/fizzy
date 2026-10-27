//! Fixture: a plugin that imports `tape` and `replay`, built as a dylib to show a store plugin gets
//! both (`play.zig` holds what it does with them). Registers nothing but itself.
const sdk = @import("fizzy_sdk");

pub const plugin_options = @import("fizzy_plugin_options");

var plugin: sdk.Plugin = .{
    .state = undefined,
    .vtable = &vtable,
    .id = plugin_options.id,
    .display_name = plugin_options.name,
};

const vtable: sdk.Plugin.VTable = .{};

pub fn register(host: *sdk.Host) !void {
    try host.registerPlugin(&plugin);
}

test {
    _ = @import("play.zig");
}
