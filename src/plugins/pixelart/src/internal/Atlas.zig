const std = @import("std");
const dvui = @import("dvui");

const Atlas = @This();
const ExternalAtlas = @import("../Atlas.zig");
const pixelart = @import("../../pixelart.zig");
const Globals = pixelart.Globals;

const alpha_checkerboard_count: u32 = 8;

/// The packed atlas texture
source: dvui.ImageSource,
canvas: pixelart.core.dvui.CanvasWidget = .{},

/// Checkerboard tile for the project-tab atlas preview (not tied to open files).
checkerboard_tile: ?dvui.Texture = null,

// /// The packed atlas heightmap
// heightmap: ?fizzy.gfx.Texture = null,

/// The actual atlas, which contains the sprites and animations data
data: ExternalAtlas,

pub fn initCheckerboardTile(atlas: *Atlas) void {
    deinitCheckerboardTile(atlas);
    atlas.checkerboard_tile = pixelart.image.checkerboardTile(
        alpha_checkerboard_count,
        alpha_checkerboard_count,
        Globals.state.settings.checker_color_even,
        Globals.state.settings.checker_color_odd,
    );
}

pub fn deinitCheckerboardTile(atlas: *Atlas) void {
    if (atlas.checkerboard_tile) |t| {
        dvui.textureDestroyLater(t);
        atlas.checkerboard_tile = null;
    }
}

pub const Selector = enum {
    source,
    data,
};

pub fn save(atlas: Atlas, path: []const u8, selector: Selector) !void {
    // Wasm: there's no on-disk path to write to. Encode the atlas into a buffer
    // and trigger a browser download via `wasm_download_data`. The native path
    // below writes through `std.Io.Dir.cwd()` which requires `posix.AT` (not
    // available on `wasm32-freestanding`).
    if (comptime @import("builtin").target.cpu.arch == .wasm32) {
        const allocator = Globals.state.host.arena();
        switch (selector) {
            .source => {
                const ext = std.fs.path.extension(path);
                var out = std.Io.Writer.Allocating.init(allocator);
                errdefer out.deinit();
                if (std.mem.eql(u8, ext, ".png")) {
                    try pixelart.image.writePngToWriter(atlas.source, &out.writer, 72);
                } else if (std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg")) {
                    try pixelart.image.writeJpgPpiToWriter(atlas.source, &out.writer, 72);
                } else {
                    std.log.debug("File name must end with .png, .jpg, or .jpeg extension!", .{});
                    return error.InvalidExtension;
                }
                const bytes = try out.toOwnedSlice();
                defer allocator.free(bytes);
                try @import("../../../../editor/WebFileIo.zig").downloadBytes(path, bytes);
            },
            .data => {
                if (!std.mem.eql(u8, ".atlas", std.fs.path.extension(path))) {
                    std.log.debug("File name must end with .atlas extension!", .{});
                    return error.InvalidExtension;
                }
                const options: std.json.Stringify.Options = .{};
                const output = try std.json.Stringify.valueAlloc(allocator, atlas.data, options);
                defer allocator.free(output);
                try @import("../../../../editor/WebFileIo.zig").downloadBytes(path, output);
            },
        }
        return;
    }

    switch (selector) {
        .source => {
            const ext = std.fs.path.extension(path);
            const write_path = std.fmt.allocPrintSentinel(Globals.state.host.arena(), "{s}", .{path}, 0) catch unreachable;

            if (std.mem.eql(u8, ext, ".png")) {
                try pixelart.image.writeToPng(atlas.source, write_path);
            } else if (std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg")) {
                try pixelart.image.writeToJpg(atlas.source, write_path);
            } else {
                std.log.debug("File name must end with .png, .jpg, or .jpeg extension!", .{});
                return error.InvalidExtension;
            }
        },
        .data => {
            if (!std.mem.eql(u8, ".atlas", std.fs.path.extension(path))) {
                std.log.debug("File name must end with .atlas extension!", .{});
                return error.InvalidExtension;
            }
            const options: std.json.Stringify.Options = .{};

            const output = try std.json.Stringify.valueAlloc(Globals.state.host.arena(), atlas.data, options);

            std.Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = path, .data = output }) catch return error.CouldNotWriteAtlasData;
        },
    }
}
