//! Small files the app keeps for itself — `settings.zon`, `recents.zon`, `layout.zon` — read
//! and written whole. On the desktop that is the config directory; on the web, where there is
//! no filesystem, the same calls go to the page's `localStorage`, keyed by the path. One seam,
//! so the code that persists a setting is the same on both and neither side carries a
//! `wasm32` gate for it.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const is_wasm = builtin.target.cpu.arch == .wasm32;

const web = struct {
    /// Copies the value for `key` into `buf`, returning the length it needs (may exceed
    /// `buf.len`), or `max` when there is no value.
    extern "fizzy" fn fizzy_web_storage_get(key_ptr: [*]const u8, key_len: usize, buf: [*]u8, buf_len: usize) usize;
    extern "fizzy" fn fizzy_web_storage_set(key_ptr: [*]const u8, key_len: usize, val: [*]const u8, val_len: usize) void;
    extern "fizzy" fn fizzy_web_storage_remove(key_ptr: [*]const u8, key_len: usize) void;
};

/// reads the contents of a file. Returned value is owned by the caller and must be freed!
pub fn read(allocator: std.mem.Allocator, io: Io, filename: []const u8) ![]u8 {
    if (is_wasm) {
        const n = web.fizzy_web_storage_get(filename.ptr, filename.len, undefined, 0);
        if (n == std.math.maxInt(usize)) return error.FileNotFound;
        const buf = try allocator.alloc(u8, n);
        errdefer allocator.free(buf);
        _ = web.fizzy_web_storage_get(filename.ptr, filename.len, buf.ptr, buf.len);
        return buf;
    }
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

/// Writes `data` as the whole of `filename`, replacing what was there.
pub fn write(io: Io, filename: []const u8, data: []const u8) !void {
    if (is_wasm) {
        web.fizzy_web_storage_set(filename.ptr, filename.len, data.ptr, data.len);
        return;
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = filename, .data = data });
}

/// Removes `filename`. A file that was not there is not an error.
pub fn remove(io: Io, filename: []const u8) !void {
    if (is_wasm) {
        web.fizzy_web_storage_remove(filename.ptr, filename.len);
        return;
    }
    Io.Dir.cwd().deleteFile(io, filename) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}
