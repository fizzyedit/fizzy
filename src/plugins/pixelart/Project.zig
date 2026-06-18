const std = @import("std");
const builtin = @import("builtin");
const fizzy = @import("../../fizzy.zig");
const dvui = @import("dvui");

const Project = @This();

pub var parsed: ?std.json.Parsed(Project) = null;
pub var read: ?[]u8 = null;

/// Path for the final packed texture to save
packed_image_output: ?[]const u8 = null,

/// Path for the final packed heightmap to save
//packed_heightmap_output: ?[]const u8 = null,

/// Path for the final packed atlas to save
packed_atlas_output: ?[]const u8 = null,

/// If true, the entire project will be repacked and exported on any project file save
pack_on_save: bool = false,

pub fn load(allocator: std.mem.Allocator) !?Project {
    if (comptime builtin.target.cpu.arch == .wasm32) return null;
    if (fizzy.editor.folder) |folder| {
        const file = try std.fs.path.join(fizzy.editor.arena.allocator(), &.{ folder, ".fizproject" });

        if (fizzy.fs.read(allocator, dvui.io, file) catch null) |r| {
            read = r;

            const options = std.json.ParseOptions{ .duplicate_field_behavior = .use_first, .ignore_unknown_fields = true };
            if (std.json.parseFromSlice(Project, allocator, r, options) catch null) |p| {
                parsed = p;

                // if (p.value.packed_atlas_output) |packed_atlas_output| {
                //     @memcpy(fizzy.editor.buffers.atlas_path[0..packed_atlas_output.len], packed_atlas_output);
                // }

                // if (p.value.packed_image_output) |packed_image_output| {
                //     @memcpy(fizzy.editor.buffers.texture_path[0..packed_image_output.len], packed_image_output);
                // }

                // if (p.value.packed_heightmap_output) |packed_heightmap_output| {
                //     @memcpy(fizzy.editor.buffers.heightmap_path[0..packed_heightmap_output.len], packed_heightmap_output);
                // }

                return .{
                    .packed_atlas_output = if (p.value.packed_atlas_output) |output| allocator.dupe(u8, output) catch null else null,
                    .packed_image_output = if (p.value.packed_image_output) |output| allocator.dupe(u8, output) catch null else null,
                    .pack_on_save = p.value.pack_on_save,
                };
            } else {
                std.log.debug("Failed to parse project file!", .{});
            }
        }
    }

    return null;
}

pub fn save(project: *Project) !void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    if (fizzy.editor.folder) |folder| {
        const file = try std.fs.path.join(fizzy.editor.arena.allocator(), &.{ folder, ".fizproject" });
        const options = std.json.Stringify.Options{};

        const str = try std.json.Stringify.valueAlloc(fizzy.app.allocator, Project{
            .packed_atlas_output = project.packed_atlas_output,
            .packed_image_output = project.packed_image_output,
            //.packed_heightmap_output = project.packed_heightmap_output,
            .pack_on_save = project.pack_on_save,
        }, options);

        try std.Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = file, .data = str });

        return;
    }

    return error.FailedToSaveProject;
}

/// Project output assets will be exported to a join of parent_folder and the individual output paths for each asset
pub fn exportAssets(project: *Project) !void {
    if (project.packed_atlas_output) |packed_atlas_output| {
        try fizzy.editor.atlas.save(packed_atlas_output, .data);
    }

    if (project.packed_image_output) |packed_image_output| {
        try fizzy.editor.atlas.save(packed_image_output, .source);
    }

    // if (project.packed_heightmap_output) |packed_heightmap_output| {
    //     const path = try std.fs.path.joinZ(fizzy.editor.arena.allocator(), &.{ parent_folder, packed_heightmap_output });
    //     try fizzy.editor.atlas.save(path, .heightmap);
    // }
}

pub fn deinit(self: *Project, allocator: std.mem.Allocator) void {
    if (read) |r| allocator.free(r);

    if (parsed) |p| {
        p.deinit();
        parsed = null;
    }

    if (self.packed_atlas_output) |output| {
        allocator.free(output);
    }

    if (self.packed_image_output) |output| {
        allocator.free(output);
    }
}
