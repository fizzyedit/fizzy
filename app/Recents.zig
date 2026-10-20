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
    /// When each of `folders` was last opened (`Folder.opened`), row for row. A list of its own
    /// rather than a field on each row, so a fizzy from before times reads this file unchanged
    /// (it ignores a field it does not know), and a file it wrote reads here with every time
    /// unknown.
    folders_opened: []const i64 = &.{},
    commands: []const []const u8 = &.{},
    move_declined_version: []const u8 = "",
};

/// A remembered folder.
pub const Folder = struct {
    /// Canonical (`canonicalize`), owned by the list's allocator.
    path: []const u8,
    /// When it was last opened, in seconds since the Unix epoch. 0 when not known: a folder
    /// remembered before fizzy kept times.
    opened: i64 = 0,
};

last_save_folder: ?[]const u8 = null,
last_open_folder: ?[]const u8 = null,
/// Oldest first: the last row is the folder opened most recently.
folders: std.array_list.Managed(Folder),
/// Commands run from the command palette — what it lists as recently used (`RecentCommands`).
commands: RecentCommands = .{},
/// The app version whose offer to move to /Applications the user put off (`update.move_offer`);
/// the offer comes back with any other. Owned by the list's allocator.
move_declined_version: ?[]const u8 = null,

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
    var folders = std.array_list.Managed(Folder).init(allocator);

    RecentsMigration.migrateIfNeeded(allocator, path);

    if (core.fs.readZ(allocator, dvui.io, path) catch null) |data| {
        defer allocator.free(data);

        var disk_arena: std.heap.ArenaAllocator = .init(allocator);
        defer disk_arena.deinit();
        var disk_diag: std.zon.parse.Diagnostics = undefined;
        if (std.zon.parse.fromSlice(Disk, .{ .gpa = allocator, .arena = disk_arena.allocator(), .source = data, .diagnostics = &disk_diag, .ignore_unknown_fields = true }) catch null) |disk| {
            for (disk.folders, 0..) |folder, row| {
                // A folder on a mount (`gdrive://…`) is not the disk's to check: it exists
                // whenever its plugin is signed in, which is decided at open time.
                const present = core.paths.isMountPath(folder) or core.LocalFs.isDirAbsolute(dvui.io, folder);
                if (present) {
                    const canon = canonicalize(allocator, folder) catch continue;

                    // Duplicates collapse onto the *later* row — the list is ordered
                    // oldest-first, so the last spelling of a directory is the recent one.
                    for (folders.items, 0..) |existing, i| {
                        if (std.mem.eql(u8, existing.path, canon)) {
                            allocator.free(folders.orderedRemove(i).path);
                            break;
                        }
                    }

                    const opened = if (row < disk.folders_opened.len) disk.folders_opened[row] else 0;
                    try folders.append(.{ .path = canon, .opened = opened });
                }
            }

            return .{
                .folders = folders,
                .commands = RecentCommands.fromIds(allocator, disk.commands),
                .move_declined_version = if (disk.move_declined_version.len > 0)
                    try allocator.dupe(u8, disk.move_declined_version)
                else
                    null,
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
        if (std.mem.eql(u8, folder.path, key))
            return i;
    }
    return null;
}

/// Remember `path` as the folder opened most recently, at `opened` (seconds since the Unix
/// epoch). Takes ownership of `path`.
pub fn appendFolder(recents: *Recents, path: []const u8, opened: i64) !void {
    const canon_owned = dup: {
        defer recents.folders.allocator.free(path);
        break :dup try canonicalize(recents.folders.allocator, path);
    };

    if (recents.indexOfFolder(canon_owned)) |index| {
        recents.folders.allocator.free(canon_owned);
        var folder = recents.folders.orderedRemove(index);
        folder.opened = opened;
        try recents.folders.append(folder);
        return;
    }

    if (recents.folders.items.len >= max_recents) {
        const oldest = recents.folders.orderedRemove(0);
        recents.folders.allocator.free(oldest.path);
    }

    try recents.folders.append(.{ .path = canon_owned, .opened = opened });
}

/// Forget the folder at `index`.
pub fn removeFolder(recents: *Recents, index: usize) void {
    recents.folders.allocator.free(recents.folders.orderedRemove(index).path);
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
    const paths = try allocator.alloc([]const u8, recents.folders.items.len);
    defer allocator.free(paths);
    const opened = try allocator.alloc(i64, recents.folders.items.len);
    defer allocator.free(opened);
    for (recents.folders.items, paths, opened) |f, *p, *o| {
        p.* = f.path;
        o.* = f.opened;
    }
    const disk: Disk = .{
        .folders = paths,
        .folders_opened = opened,
        .commands = recents.commands.ids.items,
        .last_save_folder = recents.last_save_folder orelse "",
        .last_open_folder = recents.last_open_folder orelse "",
        .move_declined_version = recents.move_declined_version orelse "",
    };

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try std.zon.stringify.serialize(disk, .{}, &aw.writer);

    try core.fs.write(dvui.io, path, aw.written());
}

pub fn deinit(recents: *Recents, allocator: std.mem.Allocator) void {
    for (recents.folders.items) |folder| {
        allocator.free(folder.path);
    }

    recents.folders.clearAndFree();
    recents.folders.deinit();

    recents.commands.deinit(allocator);
    if (recents.move_declined_version) |v| allocator.free(v);
    recents.move_declined_version = null;
}

/// Two folders made in a fresh temporary directory, and where `recents.zon` goes beside them.
const TestDirs = struct {
    tmp: std.testing.TmpDir,
    a: []const u8,
    b: []const u8,
    zon: []const u8,

    fn init(gpa: std.mem.Allocator) !TestDirs {
        dvui.io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(dvui.io, "a");
        try tmp.dir.createDirPath(dvui.io, "b");
        const root = try tmp.dir.realPathFileAlloc(dvui.io, ".", gpa);
        defer gpa.free(root);
        return .{
            .tmp = tmp,
            .a = try std.fs.path.join(gpa, &.{ root, "a" }),
            .b = try std.fs.path.join(gpa, &.{ root, "b" }),
            .zon = try std.fs.path.join(gpa, &.{ root, "recents.zon" }),
        };
    }

    fn deinit(self: *TestDirs, gpa: std.mem.Allocator) void {
        gpa.free(self.a);
        gpa.free(self.b);
        gpa.free(self.zon);
        self.tmp.cleanup();
    }
};

test "a recents.zon from before times reads in order, every time unknown" {
    const gpa = std.testing.allocator;
    var dirs = try TestDirs.init(gpa);
    defer dirs.deinit(gpa);

    const old = try gpa.print(".{{ .last_open_folder = \"\", .folders = .{{ \"{s}\", \"{s}\" }}, .commands = .{{}} }}", .{ dirs.a, dirs.b });
    defer gpa.free(old);
    try core.fs.write(dvui.io, dirs.zon, old);

    var recents = try Recents.load(gpa, dirs.zon);
    defer recents.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), recents.folders.items.len);
    try std.testing.expectEqualStrings(dirs.a, recents.folders.items[0].path);
    try std.testing.expectEqualStrings(dirs.b, recents.folders.items[1].path);
    for (recents.folders.items) |f| try std.testing.expectEqual(@as(i64, 0), f.opened);
}

test "opening a folder records when, a reopened one moves last, and times survive a save" {
    const gpa = std.testing.allocator;
    var dirs = try TestDirs.init(gpa);
    defer dirs.deinit(gpa);

    var recents = try Recents.load(gpa, dirs.zon);
    try recents.appendFolder(try gpa.dupe(u8, dirs.a), 100);
    try recents.appendFolder(try gpa.dupe(u8, dirs.b), 200);
    try recents.appendFolder(try gpa.dupe(u8, dirs.a), 300);
    try recents.save(gpa, dirs.zon);
    recents.deinit(gpa);

    var back = try Recents.load(gpa, dirs.zon);
    defer back.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), back.folders.items.len);
    try std.testing.expectEqualStrings(dirs.b, back.folders.items[0].path);
    try std.testing.expectEqual(@as(i64, 200), back.folders.items[0].opened);
    try std.testing.expectEqualStrings(dirs.a, back.folders.items[1].path);
    try std.testing.expectEqual(@as(i64, 300), back.folders.items[1].opened);
}

test "a time stays with its folder when a row before it is gone from disk" {
    const gpa = std.testing.allocator;
    var dirs = try TestDirs.init(gpa);
    defer dirs.deinit(gpa);

    const zon = try gpa.print(".{{ .folders = .{{ \"{s}/gone\", \"{s}\" }}, .folders_opened = .{{ 100, 200 }} }}", .{ dirs.a, dirs.b });
    defer gpa.free(zon);
    try core.fs.write(dvui.io, dirs.zon, zon);

    var recents = try Recents.load(gpa, dirs.zon);
    defer recents.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), recents.folders.items.len);
    try std.testing.expectEqualStrings(dirs.b, recents.folders.items[0].path);
    try std.testing.expectEqual(@as(i64, 200), recents.folders.items[0].opened);
}

test "a put-off move to Applications survives a save" {
    const gpa = std.testing.allocator;
    var dirs = try TestDirs.init(gpa);
    defer dirs.deinit(gpa);

    var recents = try Recents.load(gpa, dirs.zon);
    try std.testing.expect(recents.move_declined_version == null);
    recents.move_declined_version = try gpa.dupe(u8, "1.2.3");
    try recents.save(gpa, dirs.zon);
    recents.deinit(gpa);

    var back = try Recents.load(gpa, dirs.zon);
    defer back.deinit(gpa);
    try std.testing.expectEqualStrings("1.2.3", back.move_declined_version.?);
}
