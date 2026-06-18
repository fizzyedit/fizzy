const std = @import("std");
const Animation = @This();

name: []const u8,
frames: []Frame,

pub const Frame = struct {
    sprite_index: usize,
    ms: u32,
};

pub const AnimationV2 = struct {
    name: []const u8,
    frames: []usize,
    fps: f32,
};

pub const AnimationV1 = struct {
    name: []const u8,
    start: usize,
    length: usize,
    fps: f32,
};

pub fn init(allocator: std.mem.Allocator, name: []const u8, frames: []usize) !Animation {
    return .{
        .name = try allocator.dupe(u8, name),
        .frames = try allocator.dupe(Frame, frames),
    };
}

pub fn eql(a: Animation, b: Animation) bool {
    var e: bool = true;
    if (a.frames.len != b.frames.len) {
        return false;
    }

    for (a.frames, b.frames) |frame_a, frame_b| {
        if (frame_a.sprite_index != frame_b.sprite_index) {
            e = false;
            break;
        } else if (frame_a.ms != frame_b.ms) {
            e = false;
            break;
        }
    }

    return e;
}

pub fn eqlFrames(a: Animation, frames: []Frame) bool {
    var e: bool = true;

    if (a.frames.len != frames.len) {
        return false;
    }

    for (a.frames, frames) |frame_a, frame_b| {
        if (frame_a.sprite_index != frame_b.sprite_index) {
            e = false;
            break;
        } else if (frame_a.ms != frame_b.ms) {
            e = false;
            break;
        }
    }

    return e;
}

pub fn deinit(self: *Animation, allocator: std.mem.Allocator) void {
    allocator.free(self.name);
    allocator.free(self.frames);
}

// ----------------------------------------------------------------
// Tests
// ----------------------------------------------------------------

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "eql: identical frame lists compare equal" {
    var f_a = [_]Frame{
        .{ .sprite_index = 0, .ms = 100 },
        .{ .sprite_index = 1, .ms = 100 },
        .{ .sprite_index = 2, .ms = 100 },
    };
    var f_b = [_]Frame{
        .{ .sprite_index = 0, .ms = 100 },
        .{ .sprite_index = 1, .ms = 100 },
        .{ .sprite_index = 2, .ms = 100 },
    };
    const a: Animation = .{ .name = "idle", .frames = &f_a };
    const b: Animation = .{ .name = "idle", .frames = &f_b };
    try expect(eql(a, b));
}

test "eql: differing sprite_index makes animations unequal" {
    var f_a = [_]Frame{.{ .sprite_index = 0, .ms = 100 }};
    var f_b = [_]Frame{.{ .sprite_index = 1, .ms = 100 }};
    const a: Animation = .{ .name = "idle", .frames = &f_a };
    const b: Animation = .{ .name = "idle", .frames = &f_b };
    try expect(!eql(a, b));
}

test "eql: differing ms makes animations unequal" {
    var f_a = [_]Frame{.{ .sprite_index = 0, .ms = 100 }};
    var f_b = [_]Frame{.{ .sprite_index = 0, .ms = 250 }};
    const a: Animation = .{ .name = "idle", .frames = &f_a };
    const b: Animation = .{ .name = "idle", .frames = &f_b };
    try expect(!eql(a, b));
}

test "eql: differing frame counts make animations unequal" {
    var f_a = [_]Frame{
        .{ .sprite_index = 0, .ms = 100 },
        .{ .sprite_index = 1, .ms = 100 },
    };
    var f_b = [_]Frame{
        .{ .sprite_index = 0, .ms = 100 },
    };
    const a: Animation = .{ .name = "idle", .frames = &f_a };
    const b: Animation = .{ .name = "idle", .frames = &f_b };
    try expect(!eql(a, b));
}

test "eqlFrames: matches when contents match exactly" {
    var f = [_]Frame{
        .{ .sprite_index = 5, .ms = 50 },
        .{ .sprite_index = 6, .ms = 50 },
    };
    var probe = [_]Frame{
        .{ .sprite_index = 5, .ms = 50 },
        .{ .sprite_index = 6, .ms = 50 },
    };
    const a: Animation = .{ .name = "x", .frames = &f };
    try expect(eqlFrames(a, &probe));
}

test "eqlFrames: empty frames compare equal" {
    var empty: [0]Frame = .{};
    const a: Animation = .{ .name = "empty", .frames = &empty };
    try expect(eqlFrames(a, &empty));
}
