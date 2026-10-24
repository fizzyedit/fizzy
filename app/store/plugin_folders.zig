//! The folders in `plugins/`, by the names the filesystem keeps for them, and the two questions a
//! plugin id asks of them before anything touches the disk: does another plugin's folder already
//! stand there in another case, and may uninstalling this id delete what is there.
//!
//! On macOS and Windows `plugins/Graphl` *is* `plugins/graphl`: writing or deleting one writes or
//! deletes the other. So the answers come from the listing the filesystem gives, read fresh at the
//! user's action, and anything that cannot be read answers the safe way: refuse the install, keep
//! the folder.
//!
//! std-only, so its rules are tested without a window (`build/app.zig`'s unit list).
const std = @import("std");

/// The names in `plugins/`, owned.
pub const Folders = struct {
    names: []const []const u8,

    pub fn deinit(self: Folders, gpa: std.mem.Allocator) void {
        for (self.names) |n| gpa.free(n);
        gpa.free(self.names);
    }
};

/// Read `plugins_dir`'s entries (folders and links to them). A folder not made yet holds nothing;
/// one that cannot be read is `error.Unreadable`, which a caller treats as a possible clash.
pub fn read(gpa: std.mem.Allocator, io: std.Io, plugins_dir: []const u8) error{ Unreadable, OutOfMemory }!Folders {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var dir = std.Io.Dir.cwd().openDir(io, plugins_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .{ .names = try names.toOwnedSlice(gpa) },
        else => return error.Unreadable,
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch return error.Unreadable) |entry| {
        if (entry.kind != .directory and entry.kind != .sym_link) continue;
        const name = try gpa.dupe(u8, entry.name);
        names.append(gpa, name) catch |err| {
            gpa.free(name);
            return err;
        };
    }
    return .{ .names = try names.toOwnedSlice(gpa) };
}

/// The name in `names` that is `id` in another case, borrowed from `names`: another plugin's
/// folder, which on a case-insensitive filesystem is `plugins/<id>` itself.
pub fn clash(names: []const []const u8, id: []const u8) ?[]const u8 {
    for (names) |n| {
        if (!std.mem.eql(u8, n, id) and std.ascii.eqlIgnoreCase(n, id)) return n;
    }
    return null;
}

/// What uninstalling `id` may delete in `plugins/`.
pub const Deletable = enum {
    /// Nothing: no entry of exactly that name, a case variant stands beside it (on a
    /// case-insensitive filesystem, the same folder as `plugins/<id>`), the listing cannot be
    /// read, or `id` is not a plain name.
    keep,
    /// Its own folder: delete the tree.
    folder,
    /// A link of exactly that name (a dev setup's): remove the link, never what it points at.
    link,
};

/// Whether `plugins/<id>` is `id`'s alone to delete, by the names listed now: an entry of exactly
/// that name, and no other entry `id` in another case. On a case-insensitive filesystem that
/// second rule is what keeps an installed plugin, loaded or not, from going with a refused
/// variant's card.
pub fn deletable(io: std.Io, plugins_dir: []const u8, id: []const u8) Deletable {
    if (!plainName(id)) return .keep;
    var dir = std.Io.Dir.cwd().openDir(io, plugins_dir, .{ .iterate = true }) catch return .keep;
    defer dir.close(io);
    var own: ?std.Io.File.Kind = null;
    var it = dir.iterate();
    while (it.next(io) catch return .keep) |entry| {
        if (std.mem.eql(u8, entry.name, id)) {
            own = entry.kind;
        } else if (std.ascii.eqlIgnoreCase(entry.name, id)) return .keep;
    }
    return switch (own orelse return .keep) {
        .directory => .folder,
        .sym_link => .link,
        else => .keep,
    };
}

/// A name that stays inside `plugins/`: no separators, not `.` or `..`, not empty.
fn plainName(id: []const u8) bool {
    if (id.len == 0 or std.mem.eql(u8, id, ".") or std.mem.eql(u8, id, "..")) return false;
    for (id) |c| if (c == '/' or c == '\\' or c == 0) return false;
    return true;
}

test "a name in another case clashes, the same name does not" {
    const names: []const []const u8 = &.{ "pixi", "Graphl" };
    try std.testing.expectEqualStrings("Graphl", clash(names, "graphl").?);
    try std.testing.expect(clash(names, "Graphl") == null);
    try std.testing.expect(clash(names, "atlas") == null);
}

test "uninstall deletes only an entry of exactly the name, with no variant beside it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];

    try tmp.dir.createDirPath(io, "solo");
    try tmp.dir.createDirPath(io, "Graphl");
    try std.testing.expectEqual(Deletable.folder, deletable(io, root, "solo"));
    // A variant stands there: on this filesystem or not, never deleted for `graphl`.
    try std.testing.expectEqual(Deletable.keep, deletable(io, root, "graphl"));
    try std.testing.expectEqual(Deletable.folder, deletable(io, root, "Graphl"));
    try std.testing.expectEqual(Deletable.keep, deletable(io, root, "absent"));
    try std.testing.expectEqual(Deletable.keep, deletable(io, root, ".."));
    try std.testing.expectEqual(Deletable.keep, deletable(io, root, "a/b"));
    // A folder that cannot be read keeps everything.
    try std.testing.expectEqual(Deletable.keep, deletable(io, "/nonexistent/plugins", "solo"));

    // A link of exactly the name is the link to remove, never what it points at.
    tmp.dir.symLink(io, "solo", "linked", .{ .is_directory = true }) catch return error.SkipZigTest;
    try std.testing.expectEqual(Deletable.link, deletable(io, root, "linked"));
}

test "a listing reads folders and links, and a folder not made yet holds nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    try tmp.dir.createDirPath(io, "pixi");
    try tmp.dir.writeFile(io, .{ .sub_path = "stray.txt", .data = "" });
    const folders = try read(std.testing.allocator, io, root);
    defer folders.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), folders.names.len);
    try std.testing.expectEqualStrings("pixi", folders.names[0]);

    const none = try read(std.testing.allocator, io, "/nonexistent/plugins/at/all");
    defer none.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), none.names.len);
}
