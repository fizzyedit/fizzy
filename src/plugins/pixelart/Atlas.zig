const std = @import("std");

const Atlas = @This();

pub const Sprite = struct {
    origin: [2]f32 = .{ 0.0, 0.0 },
    source: [4]u32,
};

const Animation = @import("Animation.zig");

sprites: []Sprite,
animations: []Animation,

const AtlasV2 = struct {
    sprites: []Sprite,
    animations: []Animation.AnimationV2,
};

const AtlasV1 = struct {
    sprites: []Sprite,
    animations: []Animation.AnimationV1,
};

pub fn loadFromFile(allocator: std.mem.Allocator, io: std.Io, file: []const u8) !Atlas {
    const cwd = std.Io.Dir.cwd();
    const handle = try cwd.openFile(io, file, .{});
    defer handle.close(io);

    var buf: [4096]u8 = undefined;
    var rdr = handle.reader(io, &buf);
    const read = try rdr.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(read);

    return loadFromBytes(allocator, read);
}

pub fn loadFromBytes(allocator: std.mem.Allocator, bytes: []const u8) !Atlas {
    const options = std.json.ParseOptions{ .duplicate_field_behavior = .use_first, .ignore_unknown_fields = true };

    if (std.json.parseFromSlice(Atlas, allocator, bytes, options) catch null) |parsed| {
        const animations = try allocator.dupe(Animation, parsed.value.animations);

        for (animations) |*animation| {
            animation.name = try allocator.dupe(u8, animation.name);
        }

        return .{
            .sprites = try allocator.dupe(Sprite, parsed.value.sprites),
            .animations = animations,
        };
    } else if (std.json.parseFromSlice(AtlasV2, allocator, bytes, options) catch null) |parsed| {
        const animations = try allocator.alloc(Animation, parsed.value.animations.len);
        for (animations, parsed.value.animations) |*animation, old_animation| {
            animation.name = try allocator.dupe(u8, old_animation.name);
            animation.frames = try allocator.alloc(Animation.Frame, old_animation.frames.len);
            for (animation.frames, old_animation.frames) |*frame, old_frame| {
                frame.sprite_index = old_frame;
                const fps = if (old_animation.fps > 0) old_animation.fps else 1.0;
                frame.ms = @intFromFloat(1000.0 / fps);
            }
        }

        return .{
            .sprites = try allocator.dupe(Sprite, parsed.value.sprites),
            .animations = animations,
        };
    } else if (std.json.parseFromSlice(AtlasV1, allocator, bytes, options) catch null) |parsed| {
        const animations = try allocator.alloc(Animation, parsed.value.animations.len);
        for (animations, parsed.value.animations) |*animation, old_animation| {
            animation.name = try allocator.dupe(u8, old_animation.name);
            animation.frames = try allocator.alloc(Animation.Frame, old_animation.length);
            for (animation.frames, old_animation.start..old_animation.start + old_animation.length) |*frame, frame_index| {
                frame.sprite_index = frame_index;
                const fps = if (old_animation.fps > 0) old_animation.fps else 1.0;
                frame.ms = @intFromFloat(1000.0 / fps);
            }
        }

        return .{
            .sprites = try allocator.dupe(Sprite, parsed.value.sprites),
            .animations = animations,
        };
    }

    return error.CannotLoadAtlas;
}

pub fn spriteName(atlas: *Atlas, allocator: std.mem.Allocator, index: usize) ![]const u8 {
    for (atlas.animations) |animation| {
        for (animation.frames, 0..) |frame, frame_index| {
            if (frame.sprite_index != index) continue;

            if (animation.frames.len > 1) {
                return std.fmt.allocPrint(allocator, "{s}_{d}", .{ animation.name, frame_index });
            } else {
                return std.fmt.allocPrint(allocator, "{s}", .{animation.name});
            }
        }
    }

    return std.fmt.allocPrint(allocator, "Sprite_{d}", .{index});
}

pub fn deinit(atlas: *Atlas, allocator: std.mem.Allocator) void {
    for (atlas.animations) |*animation| {
        allocator.free(animation.name);
    }

    allocator.free(atlas.sprites);
    allocator.free(atlas.animations);
}
