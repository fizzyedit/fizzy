const std = @import("std");
const fizzy = @import("../fizzy.zig");
const dvui = @import("dvui");
const RecentsMigration = @import("RecentsMigration.zig");
const Constants = @import("Constants.zig");

const Recents = @This();

/// On-disk shape of `recents.zon`.
const Disk = struct {
    last_save_folder: []const u8 = "",
    last_open_folder: []const u8 = "",
    folders: []const []const u8 = &.{},
};

last_save_folder: ?[]const u8 = null,
last_open_folder: ?[]const u8 = null,
folders: std.array_list.Managed([]const u8),

/// Treats "/" and `\` at the end like extra directory hints: `/foo` and `/foo/` compare equal.
fn trimTrailingPathSeparators(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1) {
        const c = path[end - 1];
        if (c != '/' and c != '\\') break;
        end -= 1;
    }
    return path[0..end];
}

/// Everything stored in `folders` / `last_*_folder` is canonical (`fizzy.paths.normalize`), so
/// `/foo` and `/foo/.` are one entry rather than two rows pointing at the same directory.
/// Applied on load as well as on append: files written before this normalization existed can
/// still hold the odd spellings, and those must collapse instead of surviving forever.
fn canonicalize(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return fizzy.paths.normalize(allocator, trimTrailingPathSeparators(path));
}

pub fn load(allocator: std.mem.Allocator, path: []const u8) !Recents {
    var folders = std.array_list.Managed([]const u8).init(allocator);

    RecentsMigration.migrateIfNeeded(allocator, path);

    if (fizzy.fs.readZ(allocator, dvui.io, path) catch null) |data| {
        defer allocator.free(data);

        if (std.zon.parse.fromSliceAlloc(Disk, allocator, data, null, .{ .ignore_unknown_fields = true }) catch null) |disk| {
            defer std.zon.parse.free(allocator, disk);

            for (disk.folders) |folder| {
                if (std.Io.Dir.openDirAbsolute(dvui.io, folder, .{})) |d| {
                    var dd = d;
                    dd.close(dvui.io);

                    const canon = canonicalize(allocator, folder) catch continue;

                    // Duplicates collapse onto the *later* row — the list is ordered
                    // oldest-first, so the last spelling of a directory is the recent one.
                    for (folders.items, 0..) |existing, i| {
                        if (std.mem.eql(u8, existing, canon)) {
                            allocator.free(folders.orderedRemove(i));
                            break;
                        }
                    }

                    try folders.append(canon);
                } else |_| {}
            }

            return .{
                .folders = folders,
                .last_open_folder = if (disk.last_open_folder.len > 0)
                    try canonicalize(allocator, disk.last_open_folder)
                else
                    null,
                .last_save_folder = if (disk.last_save_folder.len > 0)
                    try canonicalize(allocator, disk.last_save_folder)
                else
                    null,
            };
        }
    }

    return .{
        .folders = folders,
    };
}

/// `path` may be spelled however the caller got it; stored entries are canonical, so the key is
/// canonicalized before comparing (falling back to a trailing-separator trim if that allocation
/// fails, which at worst misses a match and adds a duplicate row).
pub fn indexOfFolder(recents: *Recents, path: []const u8) ?usize {
    if (recents.folders.items.len == 0) return null;

    const canon_key = canonicalize(fizzy.app.allocator, path) catch null;
    defer if (canon_key) |k| fizzy.app.allocator.free(k);
    const key: []const u8 = canon_key orelse trimTrailingPathSeparators(path);

    for (recents.folders.items, 0..) |folder, i| {
        if (std.mem.eql(u8, folder, key))
            return i;
    }
    return null;
}

/// Takes ownership of `path`.
pub fn appendFolder(recents: *Recents, path: []const u8) !void {
    const canon_owned = dup: {
        defer fizzy.app.allocator.free(path);
        break :dup try canonicalize(fizzy.app.allocator, path);
    };

    if (recents.indexOfFolder(canon_owned)) |index| {
        fizzy.app.allocator.free(canon_owned);
        const folder = recents.folders.orderedRemove(index);
        try recents.folders.append(folder);
        return;
    }

    if (recents.folders.items.len >= Constants.max_recents) {
        const oldest = recents.folders.orderedRemove(0);
        fizzy.app.allocator.free(oldest);
    }

    try recents.folders.append(canon_owned);
}

pub fn save(recents: *Recents, allocator: std.mem.Allocator, path: []const u8) !void {
    const disk: Disk = .{
        .folders = recents.folders.items,
        .last_save_folder = recents.last_save_folder orelse "",
        .last_open_folder = recents.last_open_folder orelse "",
    };

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try std.zon.stringify.serialize(disk, .{}, &aw.writer);

    try std.Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = path, .data = aw.written() });
}

pub fn deinit(recents: *Recents, allocator: std.mem.Allocator) void {
    for (recents.folders.items) |folder| {
        allocator.free(folder);
    }

    recents.folders.clearAndFree();
    recents.folders.deinit();
}
