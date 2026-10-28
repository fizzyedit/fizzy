//! The build-API fixture plugin: one surface, built by `staticModule` for each kind of
//! executable. `scripts/check-examples.sh` links it into `app/`.
const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const core = @import("core");
const tape = @import("tape");
const replay = @import("replay");
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

// `tape` and `replay` are `core`'s own instances (design/build-api.md): the anchors a plugin
// publishes through `core` are the very ones `replay` reads, so one file type serves both.
comptime {
    if (core.anchor != replay.anchor) @compileError("replay is not core's instance");
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
    if (fixture_lib.answer() != 42) return error.FixtureDependency;
    try writeAndLoadTape(host.allocator);
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

/// A plugin writes a demo with `tape.Script`, ships it as bytes and loads it back: the tape
/// library a plugin imports is the one the host plays with.
fn writeAndLoadTape(gpa: std.mem.Allocator) !void {
    var owned = owned: {
        var script: tape.Script = .init(gpa, plugin_id, plugin_options.name);
        errdefer script.deinit();
        try script.command(plugin_id ++ ".hello");
        break :owned try script.finish();
    };
    defer owned.deinit();
    const bytes = try tape.binary.encode(gpa, owned.tape, .{});
    defer gpa.free(bytes);
    var loaded = try tape.Tape.load(gpa, bytes, .{});
    defer loaded.deinit();
    if (!@hasDecl(replay.Player, "play")) return error.FixtureReplay;
}
