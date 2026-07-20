const std = @import("std");
const fizzy = @import("../fizzy.zig");
const dvui = @import("dvui");
const RecentsMigration = @import("RecentsMigration.zig");

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

                    const canon = trimTrailingPathSeparators(folder);

                    var found = false;
                    for (folders.items) |existing| {
                        if (std.mem.eql(u8, trimTrailingPathSeparators(existing), canon)) {
                            found = true;
                            break;
                        }
                    }
                    if (found) continue;

                    try folders.append(try allocator.dupe(u8, canon));
                } else |_| {}
            }

            return .{
                .folders = folders,
                .last_open_folder = if (disk.last_open_folder.len > 0)
                    try allocator.dupe(u8, trimTrailingPathSeparators(disk.last_open_folder))
                else
                    null,
                .last_save_folder = if (disk.last_save_folder.len > 0)
                    try allocator.dupe(u8, trimTrailingPathSeparators(disk.last_save_folder))
                else
                    null,
            };
        }
    }

    return .{
        .folders = folders,
    };
}

pub fn indexOfFolder(recents: *Recents, path: []const u8) ?usize {
    if (recents.folders.items.len == 0) return null;

    const key = trimTrailingPathSeparators(path);
    for (recents.folders.items, 0..) |folder, i| {
        if (std.mem.eql(u8, trimTrailingPathSeparators(folder), key))
            return i;
    }
    return null;
}

pub fn appendFolder(recents: *Recents, path: []const u8) !void {
    const canon_owned = dup: {
        const t = trimTrailingPathSeparators(path);
        const duped = try fizzy.app.allocator.dupe(u8, t);
        fizzy.app.allocator.free(path);
        break :dup duped;
    };

    if (recents.indexOfFolder(canon_owned)) |index| {
        fizzy.app.allocator.free(canon_owned);
        const folder = recents.folders.orderedRemove(index);
        try recents.folders.append(folder);
        return;
    }

    if (recents.folders.items.len >= fizzy.editor.settings.max_recents) {
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
