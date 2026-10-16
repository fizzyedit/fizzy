const std = @import("std");
const core = @import("core");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const RecentsMigration = @import("RecentsMigration.zig");
const RecentCommands = @import("RecentCommands.zig");
const max_recents: usize = 10;

const Recents = @This();

/// On-disk shape of `recents.zon`.
const Disk = struct {
    last_save_folder: []const u8 = "",
    last_open_folder: []const u8 = "",
    folders: []const []const u8 = &.{},
    commands: []const []const u8 = &.{},
};

last_save_folder: ?[]const u8 = null,
last_open_folder: ?[]const u8 = null,
folders: std.array_list.Managed([]const u8),
/// Commands run from the command palette — what it lists as recently used (`RecentCommands`).
commands: RecentCommands = .{},

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

/// Everything stored in `folders` / `last_*_folder` is canonical (`core.paths.normalize`), so
/// `/foo` and `/foo/.` are one entry rather than two rows pointing at the same directory.
/// Applied on load as well as on append: files written before this normalization existed can
/// still hold the odd spellings, and those must collapse instead of surviving forever.
fn canonicalize(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return core.paths.normalize(allocator, trimTrailingPathSeparators(path));
}

pub fn load(allocator: std.mem.Allocator, path: []const u8) !Recents {
    var folders = std.array_list.Managed([]const u8).init(allocator);

    RecentsMigration.migrateIfNeeded(allocator, path);

    if (core.fs.readZ(allocator, dvui.io, path) catch null) |data| {
        defer allocator.free(data);

        var disk_arena: std.heap.ArenaAllocator = .init(allocator);
        defer disk_arena.deinit();
        var disk_diag: std.zon.parse.Diagnostics = undefined;
        if (std.zon.parse.fromSlice(Disk, .{ .gpa = allocator, .arena = disk_arena.allocator(), .source = data, .diagnostics = &disk_diag, .ignore_unknown_fields = true }) catch null) |disk| {
            for (disk.folders) |folder| {
                // A folder on a mount (`gdrive://…`) is not the disk's to check: it exists
                // whenever its plugin is signed in, which is decided at open time.
                const present = core.paths.isMountPath(folder) or core.LocalFs.isDirAbsolute(dvui.io, folder);
                if (present) {
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
                }
            }

            return .{
                .folders = folders,
                .commands = RecentCommands.fromIds(allocator, disk.commands),
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

    const canon_key = canonicalize(recents.folders.allocator, path) catch null;
    defer if (canon_key) |k| recents.folders.allocator.free(k);
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
        defer recents.folders.allocator.free(path);
        break :dup try canonicalize(recents.folders.allocator, path);
    };

    if (recents.indexOfFolder(canon_owned)) |index| {
        recents.folders.allocator.free(canon_owned);
        const folder = recents.folders.orderedRemove(index);
        try recents.folders.append(folder);
        return;
    }

    if (recents.folders.items.len >= max_recents) {
        const oldest = recents.folders.orderedRemove(0);
        recents.folders.allocator.free(oldest);
    }

    try recents.folders.append(canon_owned);
}

/// Record `id` as just run from the command palette (`RecentCommands.use`).
pub fn useCommand(recents: *Recents, id: []const u8) !void {
    try recents.commands.use(recents.folders.allocator, id);
}

/// How recently `id` was run from the palette: 0 for the most recent, null if not remembered.
pub fn commandRecency(recents: *const Recents, id: []const u8) ?usize {
    return recents.commands.recency(id);
}

pub fn save(recents: *Recents, allocator: std.mem.Allocator, path: []const u8) !void {
    const disk: Disk = .{
        .folders = recents.folders.items,
        .commands = recents.commands.ids.items,
        .last_save_folder = recents.last_save_folder orelse "",
        .last_open_folder = recents.last_open_folder orelse "",
    };

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try std.zon.stringify.serialize(disk, .{}, &aw.writer);

    try core.fs.write(dvui.io, path, aw.written());
}

pub fn deinit(recents: *Recents, allocator: std.mem.Allocator) void {
    for (recents.folders.items) |folder| {
        allocator.free(folder);
    }

    recents.folders.clearAndFree();
    recents.folders.deinit();

    recents.commands.deinit(allocator);
}
