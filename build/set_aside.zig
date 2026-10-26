//! Set aside a running fizzy's executable before the build installs over it: run by a Run step
//! on a Windows host, where a running program holds its file and the install fails. Renamed, the
//! path is free, and the running app keeps its open file. Zig 0.17's build has no custom steps.
//!
//! Usage: `set_aside <install dir> <file name>`. Nothing installed yet, or not held: nothing to do.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: set_aside <install dir> <file name>\n", .{});
        std.process.exit(2);
    }
    const path = try std.fs.path.join(arena, &.{ args[1], args[2] });
    const cwd = std.Io.Dir.cwd();
    var file = cwd.openFile(io, path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            // Held: a running app. Renamed, the install's path is free.
            const aside = try arena.print("{s}.{d}.old", .{ path, std.Io.Clock.real.now(io).nanoseconds });
            std.Io.Dir.rename(cwd, path, cwd, aside, io) catch |rename_err| {
                std.log.warn(
                    "{s} is in use and could not be set aside ({t}); the install will fail until it " ++
                        "quits",
                    .{ path, rename_err },
                );
                return;
            };
            std.log.info("{s} is running: set aside as {s}", .{ path, std.fs.path.basename(aside) });
            return;
        },
    };
    file.close(io);
}
