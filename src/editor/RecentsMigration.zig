//! One-shot migration of the legacy `recents.json` into `recents.zon` (see
//! docs/PLUGIN_MANIFEST_PLAN.md R3). All `std.json` usage on the recents path is isolated
//! to this file so it can be deleted once every install has migrated.
const std = @import("std");
const fizzy = @import("../fizzy.zig");
const dvui = @import("dvui");

/// Legacy `recents.json` shape (see pre-R3 `Recents.zig`).
const LegacyRecents = struct {
    last_save_folder: []const u8,
    last_open_folder: []const u8,
    folders: [][]const u8,
};

/// On-disk shape of `recents.zon` — mirrors `Recents.Disk`.
const Disk = struct {
    last_save_folder: []const u8 = "",
    last_open_folder: []const u8 = "",
    folders: []const []const u8 = &.{},
};

/// If `zon_path` doesn't exist yet but its sibling `<name>.json` does, parse the legacy
/// JSON, write an equivalent `zon_path`, and delete the JSON file. No-op (including on
/// any failure along the way — the caller falls back to defaults as usual) otherwise.
pub fn migrateIfNeeded(allocator: std.mem.Allocator, zon_path: []const u8) void {
    if (fizzy.fs.read(allocator, dvui.io, zon_path) catch null) |existing| {
        allocator.free(existing);
        return;
    }

    const json_path = siblingJsonPath(allocator, zon_path) catch return;
    defer allocator.free(json_path);

    const data = fizzy.fs.read(allocator, dvui.io, json_path) catch return;
    defer allocator.free(data);

    migrate(allocator, zon_path, json_path, data) catch |err| {
        dvui.log.warn("recents: failed to migrate {s} to zon: {s}", .{ json_path, @errorName(err) });
    };
}

fn siblingJsonPath(allocator: std.mem.Allocator, zon_path: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, zon_path, ".zon")) {
        return std.fmt.allocPrint(allocator, "{s}json", .{zon_path[0 .. zon_path.len - 3]});
    }
    return std.fmt.allocPrint(allocator, "{s}.json", .{zon_path});
}

fn migrate(allocator: std.mem.Allocator, zon_path: []const u8, json_path: []const u8, data: []const u8) !void {
    const options = std.json.ParseOptions{ .duplicate_field_behavior = .use_first, .ignore_unknown_fields = true };
    var parsed = try std.json.parseFromSlice(LegacyRecents, allocator, data, options);
    defer parsed.deinit();

    const disk: Disk = .{
        .last_save_folder = parsed.value.last_save_folder,
        .last_open_folder = parsed.value.last_open_folder,
        .folders = parsed.value.folders,
    };

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try std.zon.stringify.serialize(disk, .{}, &aw.writer);

    try std.Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = zon_path, .data = aw.written() });
    std.Io.Dir.deleteFileAbsolute(dvui.io, json_path) catch |err| {
        dvui.log.warn("recents: migrated to zon but failed to delete legacy {s}: {s}", .{ json_path, @errorName(err) });
    };
}
