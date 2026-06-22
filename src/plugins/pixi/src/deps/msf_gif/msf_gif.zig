const std = @import("std");

pub extern var msf_gif_alpha_threshold: u32;

pub const MSFGifResult = extern struct {
    data: ?[*]u8,
    dataSize: usize,
    allocSize: usize,
    contextPointer: ?*anyopaque,
};

pub const MSFGifCookedFrame = extern struct {
    pixels: ?[*]u32,
    depth: c_int,
    count: c_int,
    rbits: c_int,
    gbits: c_int,
    bbits: c_int,
};

pub const MSFGifBuffer = extern struct {
    next: ?*MSFGifBuffer,
    size: usize,
    data: [1]u8, // flexible array member in C
};

pub const MSFGifState = extern struct {
    fileWriteFunc: ?*const fn (?*const anyopaque, usize, usize, ?*anyopaque) callconv(.c) usize,
    fileWriteData: ?*anyopaque,
    previousFrame: MSFGifCookedFrame,
    currentFrame: MSFGifCookedFrame,
    lzwMem: ?*anyopaque,
    tlbMem: ?*anyopaque,
    usedMem: ?*anyopaque,
    listHead: ?*MSFGifBuffer,
    listTail: ?*MSFGifBuffer,
    width: c_int,
    height: c_int,
    customAllocatorContext: ?*anyopaque,
    framesSubmitted: c_int,
};

pub extern fn msf_gif_begin(
    handle: *MSFGifState,
    width: c_int,
    height: c_int,
) c_int;

pub extern fn msf_gif_frame(
    handle: *MSFGifState,
    pixel_data: [*]u8,
    centi_seconds_per_frame: c_int,
    quality: c_int,
    pitch_in_bytes: c_int,
) c_int;

pub extern fn msf_gif_end(
    handle: *MSFGifState,
) MSFGifResult;

pub extern fn msf_gif_free(
    result: MSFGifResult,
) void;

// Helper Zig wrappers

pub fn begin(handle: *MSFGifState, width: u32, height: u32) c_int {
    return msf_gif_begin(handle, @intCast(width), @intCast(height));
}

pub fn frame(
    handle: *MSFGifState,
    pixel_data: [*]u8,
    centi_seconds_per_frame: i32,
    //quality: i32, // 16 is recommended, can be lowered for faster exports but may look worse
    //pitch_in_bytes: i32, // 0 means contiguous rows, negative means reversed rows
) c_int {
    return msf_gif_frame(handle, pixel_data, @intCast(centi_seconds_per_frame), 16, 0);
}

pub fn end(handle: *MSFGifState) MSFGifResult {
    return msf_gif_end(handle);
}

pub fn free(result: MSFGifResult) void {
    msf_gif_free(result);
}
