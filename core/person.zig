//! The person's preferences, shared by every application built on fizzy.
const std = @import("std");
const builtin = @import("builtin");
const fs = @import("fs.zig");

pub const Person = struct {
    motion: ?f32 = null,
};

/// Whether a failed save is news: the first failure after a success is; the retries of the same failure are not.
pub const SaveStreak = struct {
    failing: bool = false,

    pub fn failed(s: *SaveStreak) bool {
        const first = !s.failing;
        s.failing = true;
        return first;
    }

    pub fn saved(s: *SaveStreak) void {
        s.failing = false;
    }
};

/// Missing or invalid preferences leave the application's defaults in effect.
pub fn load(io: std.Io, dir: []const u8) Person {
    // Preferences contain one scalar; bounded scratch also bounds malformed input.
    var scratch: [8192]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&scratch);
    const gpa = fixed.allocator();
    const path = if (builtin.target.cpu.arch == .wasm32) "fizzyedit.person" else std.fs.path.join(gpa, &.{ dir, "person.zon" }) catch return .{};
    const data = fs.readZ(gpa, io, path) catch return .{};
    var diag: std.zon.parse.Diagnostics = undefined;
    const person = std.zon.parse.fromSlice(Person, .{ .gpa = gpa, .arena = gpa, .source = data, .diagnostics = &diag, .ignore_unknown_fields = true }) catch return .{};
    if (person.motion) |level| if (!std.math.isFinite(level) or level < 0 or level > 1) return .{};
    return person;
}

/// Atomically replaces the preferences. Creates `dir` if needed on desktop.
pub fn save(io: std.Io, dir: []const u8, person: Person) !void {
    var buffer: [128]u8 = undefined;
    const data = if (person.motion) |level|
        try std.mem.print(&buffer, ".{{ .motion = {d} }}", .{level})
    else
        ".{}";
    if (builtin.target.cpu.arch == .wasm32) return fs.write(io, "fizzyedit.person", data);
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, dir);
    var folder = try cwd.openDir(io, dir, .{});
    defer folder.close(io);
    var atomic = try folder.createFileAtomic(io, "person.zon", .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, data);
    try atomic.replace(io);
}

/// The person's choice supersedes an application's initial look.
pub fn motionLevel(person: Person, app_default: ?f32) f32 {
    return person.motion orelse app_default orelse 1;
}

test "preferences round trip, invalid files, and atomic replacement" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    try std.testing.expectEqual(Person{}, load(io, dir));
    try tmp.dir.writeFile(io, .{ .sub_path = "person.zon", .data = "garbage" });
    try std.testing.expectEqual(Person{}, load(io, dir));
    try tmp.dir.writeFile(io, .{ .sub_path = "person.zon", .data = ".{ .motion = 0.4, .future = true }" });
    try std.testing.expectEqual(@as(?f32, 0.4), load(io, dir).motion);
    try save(io, dir, .{ .motion = 0.4 });
    try std.testing.expectEqual(@as(?f32, 0.4), load(io, dir).motion);
    try save(io, dir, .{ .motion = 0.8 });
    var iter = tmp.dir.iterate();
    const entry = (try iter.next(io)).?;
    try std.testing.expectEqualStrings("person.zon", entry.name);
    try std.testing.expectEqual(@as(?std.Io.Dir.Entry, null), try iter.next(io));
    try std.testing.expectEqual(@as(f32, 0.3), motionLevel(.{}, 0.3));
    try std.testing.expectEqual(@as(f32, 0.8), motionLevel(load(io, dir), 0.3));
    try std.testing.expectEqual(@as(f32, 0.8), motionLevel(load(io, dir), 1));
}

test "a failing save reports once per streak until a save succeeds" {
    var s: SaveStreak = .{};
    try std.testing.expect(s.failed());
    try std.testing.expect(!s.failed());
    try std.testing.expect(!s.failed());
    s.saved();
    try std.testing.expect(s.failed());
}
