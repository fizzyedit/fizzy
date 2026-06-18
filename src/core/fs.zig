const std = @import("std");
const Io = std.Io;

/// reads the contents of a file. Returned value is owned by the caller and must be freed!
pub fn read(allocator: std.mem.Allocator, io: Io, filename: []const u8) ![]u8 {
    const cwd = Io.Dir.cwd();
    const file = try cwd.openFile(io, filename, .{});
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var rdr = file.reader(io, &buf);
    return try rdr.interface.allocRemaining(allocator, .unlimited);
}

/// reads the contents of a file. Returned value is owned by the caller and must be freed!
pub fn readZ(allocator: std.mem.Allocator, io: Io, filename: []const u8) ![:0]u8 {
    const data = try read(allocator, io, filename);
    defer allocator.free(data);
    const buffer = try allocator.allocSentinel(u8, data.len, 0);
    @memcpy(buffer, data);
    return buffer;
}
