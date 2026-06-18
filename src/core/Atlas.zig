//! A loaded spritesheet: GPU `source` texture + indexed sprite metadata.
//!
//! The shell's `editor.atlas` uses this minimal type for UI icons. The pixel-art
//! plugin's packed output uses the richer `Internal.Atlas` instead.
const std = @import("std");
const dvui = @import("dvui");

const Sprite = @import("Sprite.zig");

const Atlas = @This();

source: dvui.ImageSource,
sprites: []Sprite,

const SpritesOnly = struct {
    sprites: []Sprite,
};

/// Parse a `.atlas` JSON blob and return a duped sprite table. Animations and
/// other fields are ignored (`ignore_unknown_fields`).
pub fn loadSpritesFromBytes(allocator: std.mem.Allocator, bytes: []const u8) ![]Sprite {
    const options: std.json.ParseOptions = .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    };
    var parsed = try std.json.parseFromSlice(SpritesOnly, allocator, bytes, options);
    defer parsed.deinit();
    return try allocator.dupe(Sprite, parsed.value.sprites);
}

pub fn deinit(self: *Atlas, allocator: std.mem.Allocator) void {
    allocator.free(self.sprites);
    self.sprites = &.{};
}
