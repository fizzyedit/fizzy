const std = @import("std");
const dvui = @import("dvui");
const pixi_mod = @import("../../pixi.zig");
const runtime = @import("../runtime.zig");

pub fn process(start: dvui.Point, end: dvui.Point) ![]dvui.Point {
    // Bresenham's line algorithm for integer grid points
    var output = std.array_list.Managed(dvui.Point).init(runtime.state().host.arena());

    // Round input points to nearest integer grid
    const x0: i32 = @intFromFloat(@floor(start.x));
    const y0: i32 = @intFromFloat(@floor(start.y));
    const x1: i32 = @intFromFloat(@floor(end.x));
    const y1: i32 = @intFromFloat(@floor(end.y));

    const dx: i32 = @intCast(@abs(x1 - x0));
    const dy: i32 = @intCast(@abs(y1 - y0));

    var x: i32 = x0;
    var y: i32 = y0;

    const sx: i32 = if (x0 < x1) 1 else -1;
    const sy: i32 = if (y0 < y1) 1 else -1;

    var err: i32 = dx - dy;

    while (true) {
        try output.append(.{ .x = @floatFromInt(x), .y = @floatFromInt(y) });

        if (x == x1 and y == y1) break;

        const e2 = 2 * err;
        if (e2 > -dy) {
            err -= dy;
            x += sx;
        }
        if (e2 < dx) {
            err += dx;
            y += sy;
        }
    }

    return output.items;
}
