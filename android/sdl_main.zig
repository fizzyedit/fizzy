const std = @import("std");
const android_lookup = @import("android_lookup");
const crash = @import("crash");

extern "c" var environ: ?[*:null]?[*:0]u8;
/// Null when SDL cannot get the app's files directory from Java.
extern fn SDL_GetAndroidInternalStoragePath() ?[*:0]const u8;
// Declared here: std.c has getenv but no setenv, and std.process cannot change the environment.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

/// SDL calls this from its activity thread in a JNI library: Zig's start.zig never runs,
/// so it never builds the std.process.Init the app needs. Hand-build the same minimal Init.
/// Default XDG_CONFIG_HOME to private app storage so settings, plugin data and secrets stay there.
// anytype: accepts both the editor main and dvui.App.main with their inferred error sets.
pub fn run(comptime main: anytype, argc: c_int, argv: [*][*:0]u8) c_int {
    return runMain(main, argc, argv) catch |err| {
        std.log.err("SDL_main failed: {t}", .{err});
        return 1;
    };
}

// anytype: forwards either app entry point while preserving its inferred error set.
fn runMain(comptime main: anytype, argc: c_int, argv: [*][*:0]u8) !u8 {
    const gpa = std.heap.c_allocator;

    var arena_allocator: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_allocator.deinit();

    if (std.c.getenv("XDG_CONFIG_HOME") == null) {
        // Unset, localConfigRoot falls back as on any Linux host.
        if (SDL_GetAndroidInternalStoragePath()) |path| _ = setenv("XDG_CONFIG_HOME", path, 0);
    }

    const args_vector: std.process.Args.Vector = argv[0..@intCast(argc)];
    const no_environ: [0:null]?[*:0]u8 = .{};
    const environ_block: std.process.Environ.Block = .{ .slice = std.mem.span(environ orelse &no_environ) };

    var lookup_vtable: std.Io.VTable = undefined;
    var threaded: std.Io.Threaded = .init(gpa, .{
        .argv0 = .init(.{ .vector = args_vector }),
        .environ = .{ .block = environ_block },
    });
    defer threaded.deinit();
    // Threaded.init's own install reached bionic as SIG_DFL, so its cancelling SIGIO killed the
    // app. deinit still restores right: bionic both wrote and reads its saved bytes in its layout.
    const interrupt: std.posix.Sigaction = .{ .handler = .{ .handler = doNothing }, .mask = std.posix.sigemptyset(), .flags = 0 };
    crash.sigaction(.IO, &interrupt, null);
    crash.sigaction(.PIPE, &interrupt, null);

    var environ_map = try std.process.Environ.createMap(.{ .block = environ_block }, gpa);
    defer environ_map.deinit();

    const preopens = try std.process.Preopens.init(arena_allocator.allocator());

    return main(.{
        .minimal = .{ .args = .{ .vector = args_vector }, .environ = .{ .block = environ_block } },
        .arena = &arena_allocator,
        .gpa = gpa,
        .io = android_lookup.wrap(threaded.io(), &lookup_vtable),
        .environ_map = &environ_map,
        .preopens = preopens,
    });
}

/// What std.Io.Threaded installs: a signal that only interrupts the blocked call it lands on.
fn doNothing(_: std.posix.SIG) callconv(.c) void {}
