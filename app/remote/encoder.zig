//! What a remote view is sent. For now a solid fill the size of the view, as one quad, so a host
//! can prove the whole path (a view, input, a frame back) before the real encoder lands:
//! `TODO(seam)`: the draw-list encoder replaces `solidFill` behind `RemoteViewHost.end`, taking
//! the frame's triangles and texture changes where this takes a colour.
const std = @import("std");
const message = @import("remote").message;

/// The colour of the stub's fill: fizzy's accent.
pub const fill_rgba: u32 = 0xff8a4bff;

/// One untextured quad over `width` x `height`. Allocated from `arena`.
pub fn solidFill(arena: std.mem.Allocator, width: u32, height: u32, rgba: u32) error{OutOfMemory}!message.DrawList {
    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);
    const vertices = try arena.dupe(message.Vertex, &.{
        .{ .x = 0, .y = 0, .u = 0, .v = 0, .rgba = rgba },
        .{ .x = w, .y = 0, .u = 0, .v = 0, .rgba = rgba },
        .{ .x = w, .y = h, .u = 0, .v = 0, .rgba = rgba },
        .{ .x = 0, .y = h, .u = 0, .v = 0, .rgba = rgba },
    });
    const indices = try arena.dupe(u32, &.{ 0, 1, 2, 0, 2, 3 });
    const cmds = try arena.dupe(message.DrawCmd, &.{.{ .texture = 0, .index_offset = 0, .index_count = 6 }});
    return .{ .vertices = vertices, .indices = indices, .cmds = cmds };
}

test "the fill is one quad covering the view" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const list = try solidFill(arena_state.allocator(), 640, 480, fill_rgba);
    try std.testing.expectEqual(@as(usize, 4), list.vertices.len);
    try std.testing.expectEqual(@as(f32, 640), list.vertices[2].x);
    try std.testing.expectEqual(@as(f32, 480), list.vertices[2].y);
    try std.testing.expectEqual(@as(u32, 6), list.cmds[0].index_count);
}
