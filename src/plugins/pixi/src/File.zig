const std = @import("std");

const Layer = @import("Layer.zig");
const Sprite = @import("Sprite.zig");
const Animation = @import("Animation.zig");

const File = @This();

/// Version of fizzy that created this file
version: std.SemanticVersion,

// Grid data
columns: u32,
rows: u32,
column_width: u32,
row_height: u32,

// Layer data
layers: []Layer,
// Origins of sprites
sprites: []Sprite,
// Lists of sprite indexes and timings
animations: []Animation,

pub fn deinit(self: *File, allocator: std.mem.Allocator) void {
    for (self.layers) |*layer| {
        allocator.free(layer.name);
    }
    for (self.animations) |*animation| {
        allocator.free(animation.frames);
        allocator.free(animation.name);
    }
    allocator.free(self.layers);
    allocator.free(self.sprites);
    allocator.free(self.animations);
}

/// Older file format, describes animations by frame indices with no duration information
pub const FileV3 = struct {
    version: std.SemanticVersion,
    columns: u32,
    rows: u32,
    column_width: u32,
    row_height: u32,
    layers: []Layer,
    sprites: []Sprite,
    animations: []Animation.AnimationV2,

    pub fn deinit(self: *File, allocator: std.mem.Allocator) void {
        for (self.layers) |*layer| {
            allocator.free(layer.name);
        }
        for (self.animations) |*animation| {
            allocator.free(animation.name);
        }
        allocator.free(self.layers);
        allocator.free(self.sprites);
        allocator.free(self.animations);
    }
};

/// Older file format, describes files by width and height and tile size
pub const FileV2 = struct {
    version: std.SemanticVersion,
    width: u32,
    height: u32,
    tile_width: u32,
    tile_height: u32,
    layers: []Layer,
    sprites: []Sprite,
    animations: []Animation.AnimationV2,

    pub fn deinit(self: *File, allocator: std.mem.Allocator) void {
        for (self.layers) |*layer| {
            allocator.free(layer.name);
        }
        for (self.animations) |*animation| {
            allocator.free(animation.name);
        }
        allocator.free(self.layers);
        allocator.free(self.sprites);
        allocator.free(self.animations);
    }
};

/// Original file format, has a different animation format
pub const FileV1 = struct {
    version: std.SemanticVersion,
    width: u32,
    height: u32,
    tile_width: u32,
    tile_height: u32,
    layers: []Layer,
    sprites: []Sprite,
    animations: []Animation.AnimationV1,

    pub fn deinit(self: *File, allocator: std.mem.Allocator) void {
        for (self.layers) |*layer| {
            allocator.free(layer.name);
        }
        for (self.animations) |*animation| {
            allocator.free(animation.name);
        }
        allocator.free(self.layers);
        allocator.free(self.sprites);
        allocator.free(self.animations);
    }
};
