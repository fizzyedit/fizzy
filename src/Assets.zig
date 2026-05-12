const std = @import("std");
const zstbi = @import("zstbi");
const mach = @import("mach");
const builtin = @import("builtin");
const fizzy = @import("fizzy.zig");

const Assets = @This();

pub const AssetType = enum {
    texture,
    atlas,
    unsupported,
};

// Mach module, systems, and main
pub const mach_module = .assets;
pub const mach_systems = .{ .init, .listen, .deinit };
pub const mach_tags = .{ .auto_reload, .path };

const log = std.log.scoped(.watcher);
const ListenerFn = fn (self: *Assets, path: []const u8, name: []const u8) void;
const Watcher = switch (builtin.target.os.tag) {
    .linux => @import("tools/watcher/LinuxWatcher.zig"),
    .macos => @import("tools/watcher/MacosWatcher.zig"),
    .windows => @import("tools/watcher/WindowsWatcher.zig"),
    else => @compileError("unsupported platform"),
};

paths: mach.Objects(.{ .track_fields = false }, struct { value: [:0]const u8 }),
textures: mach.Objects(.{ .track_fields = false }, fizzy.gfx.Texture),
atlases: mach.Objects(.{ .track_fields = false }, fizzy.Atlas),

allocator: std.mem.Allocator,
watcher: Watcher = undefined,
thread: std.Thread = undefined,
watching: bool = false,

var gpa: std.heap.DebugAllocator(.{}) = .init;

pub fn init(assets: *Assets) !void {
    const allocator = gpa.allocator();

    zstbi.init(allocator);
    assets.* = .{
        .textures = assets.textures,
        .atlases = assets.atlases,
        .paths = assets.paths,
        .allocator = allocator,
    };
}

pub fn loadTexture(assets: *Assets, path: []const u8, options: fizzy.gfx.Texture.SamplerOptions) !?mach.ObjectID {
    assets.textures.lock();
    defer assets.textures.unlock();

    const term_path = try assets.allocator.dupeZ(u8, path);

    if (fizzy.gfx.Texture.loadFromFile(term_path, options) catch null) |texture| {
        const texture_id = try assets.textures.new(texture);
        const path_id = try assets.paths.new(.{ .value = term_path });

        try assets.textures.setTag(texture_id, Assets, .path, path_id);

        return texture_id;
    }

    return null;
}

pub fn loadAtlas(assets: *Assets, path: []const u8) !?mach.ObjectID {
    assets.atlases.lock();
    defer assets.atlases.unlock();

    const term_path = try assets.allocator.dupeZ(u8, path);

    if (fizzy.Atlas.loadFromFile(assets.allocator, term_path) catch null) |atlas| {
        const atlas_id = try assets.atlases.new(atlas);
        const path_id = try assets.paths.new(.{ .value = term_path });

        try assets.atlases.setTag(atlas_id, Assets, .path, path_id);

        return atlas_id;
    }

    return null;
}

pub fn reload(assets: *Assets, id: mach.ObjectID) !void {
    if (assets.textures.is(id)) {
        var old_texture = assets.textures.getValue(id);
        defer old_texture.deinitWithoutClear();

        if (assets.textures.getTag(id, Assets, .path)) |path_id| {
            const path = assets.paths.get(path_id, .value);

            if (fizzy.gfx.Texture.loadFromFile(path, .{
                .address_mode = old_texture.address_mode,
                .copy_dst = old_texture.copy_dst,
                .copy_src = old_texture.copy_src,
                .filter = old_texture.filter,
                .format = old_texture.format,
                .render_attachment = old_texture.render_attachment,
                .storage_binding = old_texture.storage_binding,
                .texture_binding = old_texture.texture_binding,
            }) catch null) |texture| {
                assets.textures.setValueRaw(id, texture);
            }
        }
    } else if (assets.atlases.is(id)) {
        var old_atlas = assets.atlases.getValue(id);
        defer old_atlas.deinit(assets.allocator);

        if (assets.atlases.getTag(id, Assets, .path)) |path_id| {
            const path = assets.paths.get(path_id, .value);

            if (fizzy.Atlas.loadFromFile(assets.allocator, path) catch null) |atlas| {
                assets.atlases.setValueRaw(id, atlas);
            }
        }
    }
}

pub fn getTexture(assets: *Assets, id: mach.ObjectID) fizzy.gfx.Texture {
    return assets.textures.getValue(id);
}

pub fn getAtlas(assets: *Assets, id: mach.ObjectID) fizzy.Atlas {
    return assets.atlases.getValue(id);
}

/// Returns the watch paths for the currently loaded assets.
/// Caller owns the memory.
pub fn getWatchPaths(assets: *Assets, allocator: std.mem.Allocator) ![]const []const u8 {
    var out_paths = std.ArrayList([]const u8).init(allocator);

    var paths = assets.paths.slice();
    while (paths.next()) |id| {
        const path = paths.objs.get(id, .value);
        for (out_paths.items) |out_path| {
            if (std.mem.eql(u8, path, out_path)) {
                continue;
            }
        }
        try out_paths.append(path);
    }

    return out_paths.toOwnedSlice();
}

/// Returns the watch directories for the currently loaded assets.
/// Caller owns the memory.
pub fn getWatchDirs(assets: *Assets, allocator: std.mem.Allocator) ![]const []const u8 {
    var out_dirs = std.ArrayList([]const u8).init(allocator);

    var paths = assets.paths.slice();
    path_blk: while (paths.next()) |id| {
        if (std.fs.path.dirname(paths.objs.get(id, .value))) |new_dir| {
            for (out_dirs.items) |dir| {
                if (std.mem.eql(u8, dir, new_dir)) {
                    continue :path_blk;
                }
            }

            try out_dirs.append(new_dir);
        }
    }

    return out_dirs.toOwnedSlice();
}

/// Spawns a watch thread for all of the currently registered assets
/// If you add or change assets, you need to call stopWatch and then watch again to reset the background thread
pub fn watch(assets: *Assets) !void {
    if (!assets.watching)
        try spawnWatchThread(assets);
}

/// Stops the asset watching thread
pub fn stopWatching(assets: *Assets) void {
    assets.stopWatchThread();
}

fn spawnWatchThread(assets: *Assets) !void {
    assets.watcher = try Watcher.init(assets.allocator);
    assets.thread = try std.Thread.spawn(.{}, listen, .{assets});
    assets.thread.detach();
    assets.watching = true;
}

fn stopWatchThread(assets: *Assets) void {
    assets.watching = false;
    assets.watcher.stop();
    //assets.thread.join();
    //assets.thread = undefined;
}

/// Kicks off the listening loop, this will not return
pub fn listen(assets: *Assets) !void {
    try assets.watcher.listen(assets);
}

fn comparePaths(allocator: std.mem.Allocator, path1: []const u8, path2: []const u8) !bool {
    const rel_1 = try std.fs.path.relative(allocator, fizzy.app.root_path, path1);
    const rel_2 = try std.fs.path.relative(allocator, fizzy.app.root_path, path2);

    defer allocator.free(rel_1);
    defer allocator.free(rel_2);

    return std.mem.eql(u8, rel_1, rel_2);
}

/// Called from the watchers when assets change, this is where we reload our assets based on path.
pub fn onAssetChange(assets: *Assets, path: []const u8, name: []const u8) void {
    const changed_path = std.fs.path.join(assets.allocator, &.{ path, name }) catch return;
    defer assets.allocator.free(changed_path);

    const extension = std.fs.path.extension(name);

    var asset_type: AssetType = .unsupported;

    if (std.mem.eql(u8, extension, ".png") or std.mem.eql(u8, extension, ".jpg"))
        asset_type = .texture
    else if (std.mem.eql(u8, extension, ".atlas"))
        asset_type = .atlas;

    switch (asset_type) {
        .texture => {
            var textures = assets.textures.slice();
            while (textures.next()) |texture_id| {
                if (!assets.textures.hasTag(texture_id, Assets, .auto_reload)) continue;

                if (assets.textures.getTag(texture_id, Assets, .path)) |path_id| {
                    if (comparePaths(assets.allocator, changed_path, assets.paths.get(path_id, .value)) catch false) {
                        assets.reload(texture_id) catch log.debug("Texture failed to reload: {s}", .{changed_path});
                    }
                }
            }
        },
        .atlas => {
            var atlases = assets.atlases.slice();
            while (atlases.next()) |atlas_id| {
                if (!assets.atlases.hasTag(atlas_id, Assets, .auto_reload)) continue;

                if (assets.atlases.getTag(atlas_id, Assets, .path)) |path_id| {
                    if (comparePaths(assets.allocator, changed_path, assets.paths.get(path_id, .value)) catch false) {
                        assets.reload(atlas_id) catch log.debug("Atlas failed to reload: {s}", .{changed_path});
                    }
                }
            }
        },
        .unsupported => {},
    }
}

pub fn deinit(assets: *Assets) void {
    assets.stopWatching();

    var textures = assets.textures.slice();
    while (textures.next()) |id| {
        var t = assets.textures.getValue(id);
        t.deinit();
    }

    var atlases = assets.atlases.slice();
    while (atlases.next()) |id| {
        var a = assets.atlases.getValue(id);
        a.deinit(assets.allocator);
    }

    var paths = assets.paths.slice();
    while (paths.next()) |id| {
        assets.allocator.free(assets.paths.get(id, .value));
    }

    zstbi.deinit();
}
