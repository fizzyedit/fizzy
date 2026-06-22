const std = @import("std");
const zstbi = @import("zstbi");
const dvui = @import("dvui");
const pixi_mod = @import("../pixi.zig");
const runtime = @import("runtime.zig");


pub const LDTKTileset = @import("LDTKTileset.zig");

const Packer = @This();

pub const Image = struct {
    width: usize,
    height: usize,
    pixels: [][4]u8,

    pub fn deinit(self: Image, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

pub const Sprite = struct {
    image: ?Image = null,
    origin: [2]f32 = .{ 0.0, 0.0 },

    pub fn deinit(self: *Sprite, allocator: std.mem.Allocator) void {
        if (self.image) |*image| {
            image.deinit(allocator);
        }
    }
};

frames: std.array_list.Managed(zstbi.Rect),
sprites: std.array_list.Managed(Sprite),
animations: std.array_list.Managed(pixi_mod.Animation),
id_counter: u32 = 0,
placeholder: Image,
contains_height: bool = false,
open_files: std.array_list.Managed(pixi_mod.internal.File),
target: PackTarget = .project,
//camera: fizzy.gfx.Camera = .{},
atlas: ?pixi_mod.internal.Atlas = null,

/// Monotonic time (`pixi_mod.perf.nanoTimestamp`) when the current in-memory atlas was last installed.
last_packed_at_ns: ?i128 = null,

ldtk: bool = false,
ldtk_tilesets: std.array_list.Managed(LDTKTileset),

pub const PackTarget = enum {
    project,
    all_open,
    single_open,
};

pub fn init(allocator: std.mem.Allocator) !Packer {
    const pixels: [][4]u8 = try allocator.alloc([4]u8, 4);
    for (pixels) |*pixel| {
        pixel[3] = 0;
    }

    return .{
        .sprites = std.array_list.Managed(Sprite).init(allocator),
        .frames = std.array_list.Managed(zstbi.Rect).init(allocator),
        .animations = std.array_list.Managed(pixi_mod.Animation).init(allocator),
        .open_files = std.array_list.Managed(pixi_mod.internal.File).init(allocator),
        .placeholder = .{ .width = 2, .height = 2, .pixels = pixels },
        .ldtk_tilesets = std.array_list.Managed(LDTKTileset).init(allocator),
    };
}

pub fn newId(self: *Packer) u32 {
    const i = self.id_counter;
    self.id_counter += 1;
    return i;
}

pub fn deinit(self: *Packer) void {
    runtime.allocator().free(self.placeholder.pixels);
    self.clearAndFree();
    self.sprites.deinit();
    self.frames.deinit();
    self.animations.deinit();
    self.ldtk_tilesets.deinit();
}

pub fn clearAndFree(self: *Packer) void {
    for (self.sprites.items) |*sprite| {
        sprite.deinit(runtime.allocator());
    }
    for (self.animations.items) |*animation| {
        runtime.allocator().free(animation.name);
    }
    for (self.ldtk_tilesets.items) |*tileset| {
        for (tileset.layer_paths) |path| {
            runtime.allocator().free(path);
        }
        runtime.allocator().free(tileset.sprites);
        runtime.allocator().free(tileset.layer_paths);
    }
    self.frames.clearAndFree();
    self.sprites.clearAndFree();
    self.animations.clearAndFree();
    self.contains_height = false;
    self.ldtk_tilesets.clearAndFree();

    for (self.open_files.items) |*file| {
        file.deinit();
    }
    self.open_files.clearAndFree();
}

pub fn append(self: *Packer, file: *pixi_mod.internal.File) !void {
    std.log.info("Appending file with sprites: {d}", .{file.sprites.slice().len});
    var layer_opt: ?pixi_mod.Layer = null;
    var index: usize = 0;
    while (index < file.layers.slice().len) : (index += 1) {
        var layer = file.layers.get(index);
        if (!layer.visible) continue;

        const last_item: bool = index == file.layers.slice().len - 1;

        // If this layer is collapsed, we need to record its texture to survive the next loop
        if ((layer.collapse and !last_item) or ((index != 0 and file.layers.slice().get(index - 1).collapse))) {
            const current_layer = if (layer_opt) |carry_over_layer| carry_over_layer else try pixi_mod.Layer.init(
                0,
                "",
                file.width(),
                file.height(),
                .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .ptr,
            );

            const src_pixels = layer.pixels();
            const dst_pixels = current_layer.pixels();

            for (src_pixels, dst_pixels) |src, *dst| {
                if (src[3] != 0 and dst[3] == 0) { //alpha
                    dst.* = src;
                }
            }
            layer_opt = current_layer;

            if (layer.collapse and !last_item) {
                continue;
            }
        }

        var current_layer = if (layer_opt) |carry_over_layer| carry_over_layer else layer;

        const size: dvui.Size = dvui.imageSize(layer.source) catch .{ .w = 0, .h = 0 };

        const layer_width = @as(usize, @intFromFloat(size.w));
        var sprite_index: usize = 0;
        while (sprite_index < file.spriteCount()) : (sprite_index += 1) {
            const sprite = file.sprites.slice().get(sprite_index);
            const columns = file.columns;

            const column = @mod(@as(u32, @intCast(sprite_index)), columns);
            const row = @divTrunc(@as(u32, @intCast(sprite_index)), columns);

            const src_x = std.math.clamp(column * file.column_width, 0, file.width());
            const src_y = std.math.clamp(row * file.row_height, 0, file.height());

            const src_rect: dvui.Rect = .{ .x = @floatFromInt(src_x), .y = @floatFromInt(src_y), .w = @floatFromInt(file.column_width), .h = @floatFromInt(file.row_height) };

            if (current_layer.reduce(src_rect)) |reduced_rect| {
                const reduced_src_x: usize = @intFromFloat(reduced_rect.x);
                const reduced_src_y: usize = @intFromFloat(reduced_rect.y);
                const reduced_src_width: usize = @intFromFloat(reduced_rect.w);
                const reduced_src_height: usize = @intFromFloat(reduced_rect.h);

                const offset = .{ reduced_src_x - src_x, reduced_src_y - src_y };
                const src_pixels = current_layer.pixels();

                // Allocate pixels for reduced image
                var image: Image = .{
                    .width = reduced_src_width,
                    .height = reduced_src_height,
                    .pixels = try runtime.allocator().alloc([4]u8, reduced_src_width * reduced_src_height),
                };

                @memset(image.pixels, .{ 0, 0, 0, 0 });

                // Copy pixels to image
                {
                    var y: usize = reduced_src_y;
                    while (y < reduced_src_y + reduced_src_height) : (y += 1) {
                        const start = reduced_src_x + y * layer_width;
                        const src = src_pixels[start .. start + reduced_src_width];
                        const dst = image.pixels[(y - reduced_src_y) * image.width .. (y - reduced_src_y) * image.width + image.width];
                        @memcpy(dst, src);
                    }
                }

                try self.sprites.append(.{
                    .image = image,
                    //.heightmap_image = heightmap_image,
                    .origin = .{ sprite.origin[0] - @as(f32, @floatFromInt(offset[0])), sprite.origin[1] - @as(f32, @floatFromInt(offset[1])) },
                });

                try self.frames.append(.{ .id = self.newId(), .w = @as(c_ushort, @intCast(image.width)), .h = @as(c_ushort, @intCast(image.height)) });

                const new_sprite_index = self.sprites.items.len - 1;
                for (0..file.animations.len) |animation_index| {
                    const animation = file.animations.get(animation_index);
                    if (animation.frames[0].sprite_index == sprite_index) {
                        const frames = try runtime.allocator().alloc(pixi_mod.Animation.Frame, animation.frames.len);
                        for (frames, animation.frames, 0..) |*current_frame, file_anim_frame, i| {
                            current_frame.sprite_index = new_sprite_index + i;
                            current_frame.ms = file_anim_frame.ms;
                        }
                        try self.animations.append(.{
                            .name = try std.fmt.allocPrint(runtime.allocator(), "{s}_{s}", .{ animation.name, layer.name }),
                            .frames = frames,
                        });
                    }
                }
            } else {
                var animation_index: usize = 0;
                while (animation_index < file.animations.slice().len) : (animation_index += 1) {
                    const animation = file.animations.slice().get(animation_index);

                    for (animation.frames) |frame| {
                        if (frame.sprite_index == sprite_index) {

                            // Sprite contains no pixels but is part of an animation
                            // To preserve the animation, add a blank pixel to the sprites list
                            try self.sprites.append(.{
                                .image = null,
                                .origin = .{ 0, 0 },
                            });

                            try self.frames.append(.{
                                .id = self.newId(),
                                .w = 2,
                                .h = 2,
                            });
                        }
                    }
                }
            }
        }

        if (layer_opt) |*t| {
            t.deinit();
            layer_opt = null;
        }
    }
}

pub fn appendProject(packer: *Packer) !void {
    if (runtime.state().host.folder()) |root_directory| {
        try recurseFiles(packer, root_directory);
    }
}

pub fn recurseFiles(packer: *Packer, root_directory: []const u8) !void {
    const recursor = struct {
        fn search(p: *Packer, directory: []const u8) !void {
            const io = dvui.io;
            var dir = try std.Io.Dir.cwd().openDir(io, directory, .{ .access_sub_paths = true, .iterate = true });
            defer dir.close(io);

            var iter = dir.iterate();
            while (try iter.next(io)) |entry| {
                if (entry.kind == .file) {
                    const ext = std.fs.path.extension(entry.name);
                    if (pixi_mod.internal.File.isFizzyExtension(ext)) {
                        const abs_path = try std.fs.path.joinZ(runtime.allocator(), &.{ directory, entry.name });
                        defer runtime.allocator().free(abs_path);

                        if (runtime.state().docs.fileFromPath(abs_path)) |file| {
                            try p.append(file);
                        } else {
                            if (try pixi_mod.internal.File.fromPath(abs_path)) |file| {
                                try p.open_files.append(file);
                                try p.append(&p.open_files.items[p.open_files.items.len - 1]);
                            }
                        }
                    }
                } else if (entry.kind == .directory) {
                    const abs_path = try std.fs.path.joinZ(runtime.allocator(), &[_][]const u8{ directory, entry.name });
                    defer runtime.allocator().free(abs_path);
                    try search(p, abs_path);
                }
            }
        }
    }.search;

    try recursor(packer, root_directory);

    return;
}

pub fn packAndClear(packer: *Packer) !void {
    if (try packer.packRects()) |size| {
        //var atlas_texture = try fizzy.gfx.Texture.createEmpty(size[0], size[1], .{});
        var atlas_layer = try pixi_mod.Layer.init(
            0,
            "",
            size[0],
            size[1],
            .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .ptr,
        );

        for (packer.frames.items, packer.sprites.items) |frame, sprite| {
            if (sprite.image) |image| {
                const slice = frame.slice();

                atlas_layer.blit(image.pixels, .{
                    .x = @floatFromInt(slice[0]),
                    .y = @floatFromInt(slice[1]),
                    .w = @floatFromInt(slice[2]),
                    .h = @floatFromInt(slice[3]),
                }, .{});
            }
        }
        atlas_layer.invalidate();

        const atlas: pixi_mod.internal.Atlas = .{
            .sprites = try runtime.allocator().alloc(pixi_mod.internal.Atlas.Sprite, packer.sprites.items.len),
            .animations = try runtime.allocator().alloc(pixi_mod.Animation, packer.animations.items.len),
        };

        for (atlas.sprites, packer.sprites.items, packer.frames.items) |*dst, src, src_rect| {
            dst.source = .{ src_rect.x, src_rect.y, src_rect.w, src_rect.h };
            dst.origin = src.origin;
        }

        for (atlas.animations, packer.animations.items) |*dst, src| {
            dst.name = try runtime.allocator().dupe(u8, src.name);
            dst.frames = try runtime.allocator().dupe(pixi_mod.Animation.Frame, src.frames);
            //dst.length = src.length;
            // dst.start = src.start;
        }

        if (packer.atlas) |*current_atlas| {
            current_atlas.deinitCheckerboardTile();
            for (current_atlas.data.animations) |*animation| {
                runtime.allocator().free(animation.name);
            }
            runtime.allocator().free(current_atlas.data.sprites);
            runtime.allocator().free(current_atlas.data.animations);

            runtime.allocator().free(pixi_mod.image.bytes(current_atlas.source));

            current_atlas.data = atlas;
            current_atlas.source = atlas_layer.source;
            current_atlas.initCheckerboardTile();
        } else {
            packer.atlas = .{
                .source = atlas_layer.source,
                .data = atlas,
            };
            packer.atlas.?.initCheckerboardTile();
        }

        packer.last_packed_at_ns = pixi_mod.perf.nanoTimestamp();
        packer.clearAndFree();
    }
}

pub fn packRects(self: *Packer) !?[2]u16 {
    if (self.frames.items.len == 0) return null;

    var ctx: zstbi.Context = undefined;
    const node_count = 4096 * 2;
    var nodes: [node_count]zstbi.Node = undefined;

    const texture_sizes = [_][2]u32{
        [_]u32{ 256, 256 },   [_]u32{ 512, 256 },   [_]u32{ 256, 512 },
        [_]u32{ 512, 512 },   [_]u32{ 1024, 512 },  [_]u32{ 512, 1024 },
        [_]u32{ 1024, 1024 }, [_]u32{ 2048, 1024 }, [_]u32{ 1024, 2048 },
        [_]u32{ 2048, 2048 }, [_]u32{ 4096, 2048 }, [_]u32{ 2048, 4096 },
        [_]u32{ 4096, 4096 }, [_]u32{ 8192, 4096 }, [_]u32{ 4096, 8192 },
    };

    for (texture_sizes) |tex_size| {
        zstbi.initTarget(&ctx, tex_size[0], tex_size[1], &nodes);
        zstbi.setupHeuristic(&ctx, zstbi.Heuristic.skyline_bl_sort_height);
        if (zstbi.packRects(&ctx, self.frames.items) == 1) {
            return .{ @as(u16, @intCast(tex_size[0])), @as(u16, @intCast(tex_size[1])) };
        }
    }

    return null;
}
