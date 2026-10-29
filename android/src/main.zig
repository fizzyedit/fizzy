//! The Android hello: a dvui App on the SDL3 backend. A tap on the button changes what is drawn.
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

// SDL's activity looks this symbol up in the library and calls it on its own thread. This is a
// static lib linked into a JNI library, so zig's start.zig never runs and never builds the
// std.process.Init dvui.App.main needs; hand-build the same minimal Init here.
export fn SDL_main(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    return runDvuiMain(argc, argv) catch |err| {
        std.log.err("SDL_main failed: {t}", .{err});
        return 1;
    };
}

extern "c" var environ: ?[*:null]?[*:0]u8;

fn runDvuiMain(argc: c_int, argv: [*][*:0]u8) !u8 {
    const gpa = std.heap.c_allocator;

    var arena_allocator: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_allocator.deinit();

    const args_vector: std.process.Args.Vector = argv[0..@intCast(argc)];
    const no_environ: [0:null]?[*:0]u8 = .{};
    const environ_block: std.process.Environ.Block = .{ .slice = std.mem.span(environ orelse &no_environ) };

    var threaded: std.Io.Threaded = .init(gpa, .{
        .argv0 = .init(.{ .vector = args_vector }),
        .environ = .{ .block = environ_block },
    });
    defer threaded.deinit();

    var environ_map = try std.process.Environ.createMap(.{ .block = environ_block }, gpa);
    defer environ_map.deinit();

    const preopens = try std.process.Preopens.init(arena_allocator.allocator());

    return dvui.App.main(.{
        .minimal = .{ .args = .{ .vector = args_vector }, .environ = .{ .block = environ_block } },
        .arena = &arena_allocator,
        .gpa = gpa,
        .io = threaded.io(),
        .environ_map = &environ_map,
        .preopens = preopens,
    });
}
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{
    .logFn = dvui.App.logFn,
};

// Written only by appFrame on SDL's application thread (the thread running SDL_main).
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
