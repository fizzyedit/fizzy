const std = @import("std");
const dvui = @import("dvui");
const Animation = @This();
pub const Frame = @import("../Animation.zig").Frame;

// TODO: make the same type as external without id
id: u64,
name: []const u8,
frames: []Frame,

pub const AnimationV2 = struct {
    id: u64,
    name: []const u8,
    frames: []usize,
    fps: f32,
};

pub fn init(allocator: std.mem.Allocator, id: u64, name: []const u8, frames: []Frame) !Animation {
    return .{
        .id = id,
        .name = try allocator.dupe(u8, name),
        .frames = try allocator.dupe(Frame, frames),
    };
}

pub fn appendFrame(self: *Animation, allocator: std.mem.Allocator, frame: Frame) !void {
    var new_frames = std.array_list.Managed(Frame).init(allocator);
    new_frames.appendSlice(self.frames) catch |err| {
        dvui.log.err("Failed to append frames", .{});
        return err;
    };
    new_frames.append(frame) catch |err| {
        dvui.log.err("Failed to append frame", .{});
        return err;
    };

    allocator.free(self.frames);

    self.frames = new_frames.toOwnedSlice() catch |err| {
        dvui.log.err("Failed to free frames", .{});
        return err;
    };
}

pub fn appendFrames(self: *Animation, allocator: std.mem.Allocator, frames: []Frame) !void {
    var new_frames = std.array_list.Managed(Frame).init(allocator);
    new_frames.appendSlice(self.frames) catch |err| {
        dvui.log.err("Failed to append frames", .{});
        return err;
    };
    new_frames.appendSlice(frames) catch |err| {
        dvui.log.err("Failed to append frames", .{});
        return err;
    };

    allocator.free(self.frames);
    self.frames = new_frames.toOwnedSlice() catch |err| {
        dvui.log.err("Failed to free frames", .{});
        return err;
    };
}

pub fn insertFrame(self: *Animation, allocator: std.mem.Allocator, index: usize, frame: Frame) !void {
    var new_frames = std.array_list.Managed(Frame).init(allocator);
    new_frames.appendSlice(self.frames) catch |err| {
        dvui.log.err("Failed to append frames", .{});
        return err;
    };
    new_frames.insert(index, frame) catch |err| {
        dvui.log.err("Failed to insert frame", .{});
        return err;
    };

    allocator.free(self.frames);

    self.frames = new_frames.toOwnedSlice() catch |err| {
        dvui.log.err("Failed to free frames", .{});
        return err;
    };
}

pub fn removeFrame(self: *Animation, allocator: std.mem.Allocator, index: usize) void {
    var new_frames = std.array_list.Managed(Frame).init(allocator);
    new_frames.appendSlice(self.frames) catch {
        dvui.log.err("Failed to append frames", .{});
        return;
    };
    _ = new_frames.orderedRemove(index);

    allocator.free(self.frames);

    self.frames = new_frames.toOwnedSlice() catch {
        dvui.log.err("Failed to free frames", .{});
        return;
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
