const std = @import("std");
const fizzy = @import("../fizzy.zig");
const dvui = @import("dvui");

const Recents = @This();

const RecentsJson = struct {
    last_save_folder: []const u8,
    last_open_folder: []const u8,
    folders: [][]const u8,
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

    if (fizzy.fs.read(allocator, dvui.io, path) catch null) |read| {
        defer allocator.free(read);

        const options = std.json.ParseOptions{ .duplicate_field_behavior = .use_first, .ignore_unknown_fields = true };
        if (std.json.parseFromSlice(RecentsJson, allocator, read, options) catch null) |parsed| {
            defer parsed.deinit();

            for (parsed.value.folders) |folder| {
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
                .last_open_folder = if (parsed.value.last_open_folder.len > 0)
                    try allocator.dupe(u8, trimTrailingPathSeparators(parsed.value.last_open_folder))
                else
                    null,
                .last_save_folder = if (parsed.value.last_save_folder.len > 0)
                    try allocator.dupe(u8, trimTrailingPathSeparators(parsed.value.last_save_folder))
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
    const recents_json = RecentsJson{
        .folders = recents.folders.items,
        .last_save_folder = recents.last_save_folder orelse "",
        .last_open_folder = recents.last_open_folder orelse "",
    };

    const str = try std.json.Stringify.valueAlloc(allocator, recents_json, .{});
    defer allocator.free(str);

    try std.Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = path, .data = str });
}

pub fn deinit(recents: *Recents, allocator: std.mem.Allocator) void {
    for (recents.folders.items) |folder| {
        allocator.free(folder);
    }

    recents.folders.clearAndFree();
    recents.folders.deinit();
}
