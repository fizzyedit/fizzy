const std = @import("std");

const Layer = @This();

name: []const u8,
visible: bool = true,
collapse: bool = false,

pub fn deinit(layer: *Layer, allocator: std.mem.Allocator) void {
    allocator.free(layer.name);
}
