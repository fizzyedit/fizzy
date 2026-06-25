pub const version = @import("std").SemanticVersion{ .major = 0, .minor = 9, .patch = 3 };
const std = @import("std");
const assert = std.debug.assert;

pub const Rect = extern struct {
    id: u32,
    w: u16,
    h: u16,
    x: u16 = 0,
    y: u16 = 0,
    was_packed: i32 = 0,

    pub fn slice(self: Rect) [4]u32 {
        return .{
            @intCast(self.x),
            @intCast(self.y),
            @intCast(self.w),
            @intCast(self.h),
        };
    }
};

pub const Node = extern struct {
    x: u16,
    y: u16,
    next: [*c]Node,
};

pub const Context = extern struct {
    width: i32,
    height: i32,
    @"align": i32,
    init_mode: i32,
    heuristic: i32,
    num_nodes: i32,
    active_head: [*c]Node,
    free_head: [*c]Node,
    extra: [2]Node,
};

pub const Heuristic = enum(u32) {
    skyline_default,
    skyline_bl_sort_height,
    skyline_bf_sort_height,
};

pub fn initTarget(context: *Context, width: u32, height: u32, nodes: []Node) void {
    stbrp_init_target(context, width, height, nodes.ptr, nodes.len);
}

pub fn packRects(context: *Context, rects: []Rect) usize {
    return @as(usize, @intCast(stbrp_pack_rects(context, rects.ptr, rects.len)));
}

pub fn setupHeuristic(context: *Context, heuristic: Heuristic) void {
    stbrp_setup_heuristic(context, @as(u32, @intCast(@intFromEnum(heuristic))));
}

pub extern fn stbrp_init_target(context: [*c]Context, width: u32, height: u32, nodes: [*c]Node, num_nodes: usize) void;
pub extern fn stbrp_pack_rects(context: [*c]Context, rects: [*c]Rect, num_rects: usize) usize;
pub extern fn stbrp_setup_allow_out_of_mem(context: [*c]Context, allow_out_of_mem: u32) void;
pub extern fn stbrp_setup_heuristic(context: [*c]Context, heuristic: u32) void;

pub const stbir_pixel_layout = enum(i32) {
    STBIR_1CHANNEL = 1,
    STBIR_2CHANNEL = 2,
    STBIR_RGB = 3, // 3-chan, with order specified (for channel flipping)
    STBIR_BGR = 0, // 3-chan, with order specified (for channel flipping)
    STBIR_4CHANNEL = 5,

    STBIR_RGBA = 4, // alpha formats, where alpha is NOT premultiplied into color channels
    STBIR_BGRA = 6,
    STBIR_ARGB = 7,
    STBIR_ABGR = 8,
    STBIR_RA = 9,
    STBIR_AR = 10,

    STBIR_RGBA_PM = 11, // alpha formats, where alpha is premultiplied into color channels
    STBIR_BGRA_PM = 12,
    STBIR_ARGB_PM = 13,
    STBIR_ABGR_PM = 14,
    STBIR_RA_PM = 15,
    STBIR_AR_PM = 16,
};

pub fn resize(input_pixels: [][4]u8, input_w: u32, input_h: u32, output_pixels: [][4]u8, output_w: u32, output_h: u32) ?[]u8 {
    const input_slice = @as([*]u8, @ptrCast(input_pixels.ptr))[0..@intCast(input_w * input_h * 4)];
    const output_slice = @as([*]u8, @ptrCast(output_pixels.ptr))[0..@intCast(output_w * output_h * 4)];
    const output = stbir_resize_uint8_linear(input_slice.ptr, @intCast(input_w), @intCast(input_h), @intCast(input_w * 4), output_slice.ptr, @intCast(output_w), @intCast(output_h), @intCast(output_w * 4), .STBIR_RGBA);
    if (output == null) return null;
    return output_slice;
}

pub extern fn stbir_resize_uint8_srgb(input_pixels: [*c]u8, input_w: i32, input_h: i32, input_stride_in_bytes: i32, output_pixels: [*c]u8, output_w: i32, output_h: i32, output_stride_in_bytes: i32, pixel_type: stbir_pixel_layout) [*c]u8;
pub extern fn stbir_resize_uint8_linear(input_pixels: [*c]u8, input_w: i32, input_h: i32, input_stride_in_bytes: i32, output_pixels: [*c]u8, output_w: i32, output_h: i32, output_stride_in_bytes: i32, pixel_type: stbir_pixel_layout) [*c]u8;
