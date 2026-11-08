//! The Android hello: a dvui App on fizzy's backend. A tap on the button changes what is drawn.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");

pub const dvui_app: dvui.App = .{
    .config = .{
        .options = .{
            .size = .{ .w = 800.0, .h = 600.0 },
            .min_size = .{ .w = 250.0, .h = 350.0 },
            .title = "Fizzy",
        },
    },
    .frameFn = appFrame,
};
pub const main = dvui.App.main;

export fn SDL_main(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    return @import("android_sdl_main").run(dvui.App.main, argc, argv);
}

pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{
    .logFn = dvui.App.logFn,
};

// Written only by appFrame on SDL's application thread (running SDL_main): one writer, so no atomic.
var taps: u32 = 0;

fn appFrame() !dvui.App.Result {
    var root = dvui.box(@src(), .{}, .{ .expand = .both, .style = .window, .background = true });
    defer root.deinit();

    dvui.label(@src(), "Fizzy on Android", .{}, .{ .font = .theme(.title), .gravity_x = 0.5 });
    dvui.label(@src(), "{s} on {s}", .{ @tagName(dvui.backend.kind), @tagName(builtin.cpu.arch) }, .{ .gravity_x = 0.5 });
    dvui.label(@src(), "taps: {d}", .{taps}, .{ .gravity_x = 0.5, .tag = "tap-count" });

    if (dvui.button(@src(), "Tap me", .{}, .{ .gravity_x = 0.5, .min_size_content = .{ .w = 240, .h = 120 }, .tag = "tap-button" })) taps += 1;
    return .ok;
}
