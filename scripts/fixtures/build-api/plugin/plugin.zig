//! The build-API fixture plugin: one surface, built by `staticModule` for each kind of
//! executable. `scripts/check-examples.sh` links it into `app/`.
const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const fixture_lib = @import("fixture_lib");

pub const plugin_options = @import("fizzy_plugin_options");
pub const plugin_id = plugin_options.id;

// The native-only fixture is the same file under another id: a web build that links it
// fails here, which is how the check sees a `.native` entry kept out of the wasm.
comptime {
    if (std.mem.eql(u8, plugin_options.id, "fixture_native") and
        builtin.cpu.arch == .wasm32)
    {
        @compileError("a native-only plugin was linked into the web build");
    }
}

// The host writes plugin lifecycle state on the main UI thread.
var plugin: sdk.Plugin = .{
    .state = undefined,
    .vtable = &vtable,
    .id = plugin_id,
    .display_name = plugin_options.name,
};

const vtable: sdk.Plugin.VTable = .{};

pub fn register(host: *sdk.Host) !void {
    // Calls into the C source of the package's own dependency: it must have reached the link.
    if (fixture_lib.fixture_answer() != 42) return error.FixtureDependency;
    try host.registerPlugin(&plugin);
    try host.registerSurface(.{
        .id = plugin_id ++ ".surface",
        .owner = &plugin,
        .icon = .{ .tvg = dvui.entypo.emoji_happy },
        .title = plugin_options.name,
        .keywords = sdk.keywords.ide.sidebar,
        .draw = draw,
    });
}

fn draw(_: ?*anyopaque) !dvui.App.Result {
    dvui.label(@src(), "{s}", .{plugin_id}, .{});
    return .ok;
}
