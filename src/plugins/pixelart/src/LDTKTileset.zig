const std = @import("std");
const core = @import("mach").core;

pub const LDTKCompatibility = struct {
    tilesets: []LDTKTileset,
};

const LDTKTileset = @This();

pub const LDTKSprite = struct {
    src: [2]u32,
};

layer_paths: [][:0]const u8,
sprite_size: [2]u32,
sprites: []LDTKSprite,
