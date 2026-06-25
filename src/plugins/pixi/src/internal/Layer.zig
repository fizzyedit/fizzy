const std = @import("std");
const dvui = @import("dvui");
const zip = @import("zip");
const pixi_mod = @import("../../pixi.zig");
const runtime = @import("../runtime.zig");

const Layer = @This();

/// Bit count for layer masks must match `pixels(source).len`. Do not use `imageSize` float
/// products: `s.w * s.h` loses integer precision once the true pixel count exceeds ~2^24.
fn pixelCountForSource(source: dvui.ImageSource) usize {
    return switch (source) {
        .pixelsPMA => |p| @as(usize, @intCast(p.width)) * @as(usize, @intCast(p.height)),
        .pixels => |p| @as(usize, @intCast(p.width)) * @as(usize, @intCast(p.height)),
        .texture => |t| @as(usize, @intCast(t.width)) * @as(usize, @intCast(t.height)),
        .imageFile => |f| blk: {
            var w: c_int = undefined;
            var h: c_int = undefined;
            var n: c_int = undefined;
            if (dvui.c.stbi_info_from_memory(f.bytes.ptr, @as(c_int, @intCast(f.bytes.len)), &w, &h, &n) != 1)
                break :blk 0;
            break :blk @as(usize, @intCast(w)) * @as(usize, @intCast(h));
        },
    };
}

id: u64,
name: []const u8,
source: dvui.ImageSource,
mask: std.DynamicBitSet,
visible: bool = true,
collapse: bool = false,
dirty: bool = false,

pub fn init(id: u64, name: []const u8, width: u32, height: u32, default_color: dvui.Color, invalidation: dvui.ImageSource.InvalidationStrategy) !Layer {
    const num_pixels = width * height;
    const p = runtime.allocator().alloc([4]u8, num_pixels) catch return error.MemoryAllocationFailed;

    @memset(p, default_color.toRGBA());

    return .{
        .id = id,
        .name = runtime.allocator().dupe(u8, name) catch return error.MemoryAllocationFailed,
        .source = .{
            .pixelsPMA = .{
                .rgba = @ptrCast(p),
                .width = width,
                .height = height,
                .interpolation = .nearest,
                .invalidation = invalidation,
            },
        },
        .mask = std.DynamicBitSet.initEmpty(runtime.allocator(), num_pixels) catch return error.MemoryAllocationFailed,
    };
}

pub fn fromImageFilePath(id: u64, name: []const u8, path: []const u8, invalidation: dvui.ImageSource.InvalidationStrategy) !Layer {
    const source = pixi_mod.image.fromImageFilePath(name, path, invalidation) catch return error.ErrorCreatingImageSource;
    const mask = std.DynamicBitSet.initEmpty(runtime.allocator(), pixelCountForSource(source)) catch return error.MemoryAllocationFailed;

    return .{
        .id = id,
        .name = runtime.allocator().dupe(u8, name) catch return error.MemoryAllocationFailed,
        .source = source,
        .mask = mask,
    };
}

pub fn fromImageFileBytes(id: u64, name: []const u8, image_bytes: []const u8, invalidation: dvui.ImageSource.InvalidationStrategy) !Layer {
    const source = pixi_mod.image.fromImageFileBytes(name, image_bytes, invalidation) catch return error.ErrorCreatingImageSource;
    const mask = std.DynamicBitSet.initEmpty(runtime.allocator(), pixelCountForSource(source)) catch return error.MemoryAllocationFailed;

    return .{
        .id = id,
        .name = runtime.allocator().dupe(u8, name) catch return error.MemoryAllocationFailed,
        .source = source,
        .mask = mask,
    };
}

pub fn fromPixelsPMA(id: u64, name: []const u8, pixel_data: []dvui.Color.PMA, width: u32, height: u32, invalidation: dvui.ImageSource.InvalidationStrategy) !Layer {
    if (pixel_data.len != width * height) return error.InvalidPixelDataLength;
    const source = pixi_mod.image.fromPixelsPMA(pixel_data, width, height, invalidation) catch return error.ErrorCreatingImageSource;
    const mask = std.DynamicBitSet.initEmpty(runtime.allocator(), @as(usize, @intCast(width * height))) catch return error.MemoryAllocationFailed;

    return .{
        .id = id,
        .name = runtime.allocator().dupe(u8, name) catch return error.MemoryAllocationFailed,
        .source = source,
        .mask = mask,
    };
}

pub fn fromPixels(id: u64, name: []const u8, pixel_data: []u8, width: u32, height: u32, invalidation: dvui.ImageSource.InvalidationStrategy) !Layer {
    if (pixel_data.len != width * height) return error.InvalidPixelDataLength;
    const source = pixi_mod.image.fromPixels(pixel_data, width, height, invalidation) catch return error.ErrorCreatingImageSource;
    const mask = std.DynamicBitSet.initEmpty(runtime.allocator(), @as(usize, @intCast(width * height))) catch return error.MemoryAllocationFailed;

    return .{
        .id = id,
        .name = runtime.allocator().dupe(u8, name) catch return error.MemoryAllocationFailed,
        .source = source,
        .mask = mask,
    };
}

pub fn fromTexture(id: u64, name: []const u8, texture: dvui.Texture, invalidation: dvui.ImageSource.InvalidationStrategy) Layer {
    const source = pixi_mod.fs.sourceFromTexture(name, texture, invalidation) catch return error.ErrorCreatingImageSource;
    const mask = std.DynamicBitSet.initEmpty(runtime.allocator(), pixelCountForSource(source)) catch return error.MemoryAllocationFailed;

    return .{
        .id = id,
        .name = runtime.allocator().dupe(u8, name) catch return error.MemoryAllocationFailed,
        .source = source,
        .mask = mask,
    };
}

pub fn size(self: Layer) dvui.Size {
    return dvui.imageSize(self.source) catch .{ .w = 0, .h = 0 };
}

pub fn deinit(self: *Layer) void {
    switch (self.source) {
        .imageFile => |image| runtime.allocator().free(image.bytes),
        .pixels => |p| runtime.allocator().free(p.rgba),
        .pixelsPMA => |p| runtime.allocator().free(p.rgba),
        .texture => |t| dvui.textureDestroyLater(t),
    }

    runtime.allocator().free(self.name);
    self.mask.deinit();
}

/// Casts the source pixels into a slice of [4]u8
pub fn pixels(self: *const Layer) [][4]u8 {
    return pixi_mod.image.pixels(self.source);
}

/// Caller owns memory that must be freed!
pub fn pixelsFromRect(self: *const Layer, allocator: std.mem.Allocator, rect: dvui.Rect) ?[][4]u8 {
    return pixi_mod.image.pixelsFromRect(allocator, self.source, rect);
}

/// Casts the source pixels into a slice of bytes
pub fn bytes(self: *const Layer) []u8 {
    return pixi_mod.image.bytes(self.source);
}

/// Returns the index of the pixel at the given point
/// returns null if the point is out of bounds
pub fn pixelIndex(self: *Layer, p: dvui.Point) ?usize {
    return pixi_mod.image.pixelIndex(self.source, p);
}

/// Returns the point at the given index
/// returns null if the index is out of bounds
pub fn point(self: *Layer, index: usize) ?dvui.Point {
    return pixi_mod.image.point(self.source, index);
}

/// Returns the color at the given point
/// returns null if the point is out of bounds
pub fn pixel(self: *Layer, p: dvui.Point) ?[4]u8 {
    return pixi_mod.image.pixel(self.source, p);
}

/// Sets the color at the given point
/// does not invalidate the layer
pub fn setPixel(self: *Layer, p: dvui.Point, color: [4]u8) void {
    pixi_mod.image.setPixel(self.source, p, color);
}

/// Sets the mask at the given point
pub fn setMaskPoint(self: *Layer, p: dvui.Point) void {
    if (self.pixelIndex(p)) |index| {
        self.mask.set(index);
    }
}

/// Clears the layer mask
pub fn clearMask(self: *Layer) void {
    self.mask.setRangeValue(.{ .start = 0, .end = self.mask.capacity() }, false);
}

/// Sets all pixels in the mask that match the given color
pub fn setMaskFromColor(self: *Layer, color: dvui.Color, value: bool) void {
    const test_color: [4]u8 = color.toRGBA();
    for (self.pixels(), 0..) |*p, index| {
        if (std.meta.eql(test_color, p.*)) {
            self.mask.setValue(index, value);
        }
    }
}

/// Sets all pixels in the mask that are not transparent
pub fn setMaskFromTransparency(self: *Layer, value: bool) void {
    const pix_n = self.pixels().len;
    if (self.mask.capacity() != pix_n) {
        self.mask.resize(pix_n, false) catch return;
    }
    for (self.pixels(), 0..) |*p, index| {
        if (p[3] != 0) {
            self.mask.setValue(index, value);
        }
    }
}

/// Sets all pixels in the layer that are in the mask to the given color
pub fn setColorFromMask(self: *Layer, color: dvui.Color) void {
    var iter = self.mask.iterator(.{ .kind = .set, .direction = .forward });
    while (iter.next()) |index| {
        self.pixels()[index] = color.toRGBA();
    }
}

/// Flood fill a pixel and mark the flood to the mask, so you can handle changes.
pub fn floodMaskPoint(layer: *Layer, p: dvui.Point, bounds: dvui.Rect, value: bool) !void {
    if (!bounds.contains(p)) return;

    var queue = std.array_list.Managed(dvui.Point).init(runtime.allocator());
    defer queue.deinit();
    queue.append(p) catch return error.MemoryAllocationFailed;

    const directions: [4]dvui.Point = .{
        .{ .x = 0, .y = -1 },
        .{ .x = 0, .y = 1 },
        .{ .x = -1, .y = 0 },
        .{ .x = 1, .y = 0 },
    };

    if (layer.pixelIndex(p)) |index| {
        layer.mask.setValue(index, value);
        const original_color = layer.pixels()[index];

        while (queue.pop()) |qp| {
            for (directions) |direction| {
                const new_point = qp.plus(direction);
                if (layer.pixelIndex(new_point)) |iter_index| {
                    if (layer.mask.isSet(iter_index)) continue;
                    if (!std.meta.eql(original_color, layer.pixels()[iter_index])) continue;
                    if (!bounds.contains(new_point)) continue;

                    queue.append(new_point) catch return error.MemoryAllocationFailed;
                    layer.mask.setValue(iter_index, value);
                }
            }
        }
    }
}

pub fn setPixelIndex(self: *Layer, index: usize, color: [4]u8) void {
    pixi_mod.image.setPixelIndex(self.source, index, color);
}

pub const ShapeOffsetResult = struct {
    index: usize,
    color: [4]u8,
    point: dvui.Point,
};

pub fn invalidate(self: *Layer) void {
    dvui.textureInvalidateCache(self.source.hash());
    self.dirty = false;
}

/// Only used for handling getting the pixels surrounding the origin
/// for stroke sizes larger than 1
pub fn getIndexShapeOffset(self: *Layer, origin: dvui.Point, current_index: usize) ?ShapeOffsetResult {
    const shape = runtime.state().tools.stroke_shape;
    const s: i32 = @intCast(runtime.state().tools.stroke_size);

    if (s == 1) {
        if (current_index != 0)
            return null;

        if (self.pixelIndex(origin)) |index| {
            return .{
                .index = index,
                .color = self.pixels()[index],
                .point = origin,
            };
        }
    }

    const size_center_offset: i32 = -@divFloor(@as(i32, @intCast(s)), 2);
    const index_i32: i32 = @as(i32, @intCast(current_index));
    const pixel_offset: [2]i32 = .{ @mod(index_i32, s) + size_center_offset, @divFloor(index_i32, s) + size_center_offset };

    if (shape == .circle) {
        const extra_pixel_offset_circle: [2]i32 = if (@mod(s, 2) == 0) .{ 1, 1 } else .{ 0, 0 };
        const pixel_offset_circle: [2]i32 = .{ pixel_offset[0] * 2 + extra_pixel_offset_circle[0], pixel_offset[1] * 2 + extra_pixel_offset_circle[1] };
        const sqr_magnitude = pixel_offset_circle[0] * pixel_offset_circle[0] + pixel_offset_circle[1] * pixel_offset_circle[1];

        // adjust radius check for nicer looking circles
        const radius_check_mult: f32 = (if (s == 3 or s > 10) 0.7 else 0.8);

        if (@as(f32, @floatFromInt(sqr_magnitude)) > @as(f32, @floatFromInt(s * s)) * radius_check_mult) {
            return null;
        }
    }

    const pixel_i32: [2]i32 = .{ @as(i32, @intFromFloat(origin.x)) + pixel_offset[0], @as(i32, @intFromFloat(origin.y)) + pixel_offset[1] };
    const size_i32: [2]i32 = .{ @as(i32, @intFromFloat(self.size().w)), @as(i32, @intFromFloat(self.size().h)) };

    if (pixel_i32[0] < 0 or pixel_i32[1] < 0 or pixel_i32[0] >= size_i32[0] or pixel_i32[1] >= size_i32[1]) {
        return null;
    }

    const p: dvui.Point = .{ .x = @floatFromInt(pixel_i32[0]), .y = @floatFromInt(pixel_i32[1]) };

    if (self.pixelIndex(p)) |index| {
        return .{
            .index = index,
            .color = self.pixels()[index],
            .point = p,
        };
    }

    return null;
}

/// Porter–Duff "source over" for premultiplied RGBA (`pixelsPMA` byte layout).
/// `top` is composited over `bottom`. The implementation is generic byte math and
/// lives in `core` math; re-exported here for the pixel-art call sites.
pub const blendPmaSrcOver = pixi_mod.math.blendPmaSrcOver;

pub fn clearRect(self: *Layer, rect: dvui.Rect) void {
    pixi_mod.image.clearRect(self.source, rect);
    self.invalidate();
}

pub fn setRect(self: *Layer, rect: dvui.Rect, color: [4]u8) void {
    pixi_mod.image.setRect(self.source, rect, color);
    self.invalidate();
}

pub const BlitOptions = struct {
    transparent: bool = true,
    mask: bool = false,
};

pub fn blit(self: *Layer, src_pixels: [][4]u8, dst_rect: dvui.Rect, options: BlitOptions) void {
    if (src_pixels.len != @as(usize, @intFromFloat(dst_rect.w)) * @as(usize, @intFromFloat(dst_rect.h))) {
        dvui.log.err("Source pixel length {d} does not match destination rectangle size {any}", .{ src_pixels.len, dst_rect });
        return;
    }
    const self_size = self.size();

    const x = @as(usize, @intFromFloat(dst_rect.x));
    const y = @as(usize, @intFromFloat(dst_rect.y));
    const width = @as(usize, @intFromFloat(dst_rect.w));
    const height = @as(usize, @intFromFloat(dst_rect.h));

    const tex_width = @as(usize, @intFromFloat(self_size.w));

    var yy = y;
    var h = height;

    var d = self.pixels()[x + yy * tex_width .. x + yy * tex_width + width];
    var src_y: usize = 0;
    while (h > 0) {
        h -= 1;
        const src_row = src_pixels[src_y * width .. (src_y * width) + width];
        if (!options.transparent) {
            if (options.mask) {
                self.mask.setRangeValue(
                    .{ .start = x + yy * tex_width, .end = x + yy * tex_width + width },
                    true,
                );
            }

            @memcpy(d, src_row);
        } else {
            for (src_row, d, 0..) |src, *dst, index| {
                if (src[3] > 0) {
                    if (options.mask)
                        self.mask.set(x + yy * tex_width + index);

                    dst.* = src;
                }
            }
        }

        // next row and move our slice to it as well
        src_y += 1;
        yy += 1;

        const next_row_start = x + yy * tex_width;
        const next_row_end = next_row_start + width;
        // Exclusive end must satisfy `next_row_end <= len` (`== len` is valid for the bottom row).
        if (next_row_start < self.pixels().len and next_row_end <= self.pixels().len) {
            d = self.pixels()[next_row_start..next_row_end];
        }
    }
    self.invalidate();
}

pub fn clear(self: *Layer) void {
    @memset(self.pixels(), .{ 0, 0, 0, 0 });
    self.invalidate();
    self.dirty = false;
}

pub fn writeSourceToZip(
    layer: *const Layer,
    zip_file: ?*anyopaque,
    resolution: u32,
) !void {
    const source = layer.source;
    const s: dvui.Size = dvui.imageSize(source) catch .{ .w = 0, .h = 0 };

    const w = @as(c_int, @intFromFloat(s.w));
    const h = @as(c_int, @intFromFloat(s.h));

    var writer = std.Io.Writer.Allocating.init(runtime.state().host.arena());

    try pixi_mod.image.ensurePngWriterBuffer(&writer.writer);
    try dvui.PNGEncoder.writeWithResolution(&writer.writer, pixi_mod.image.bytes(source), @intCast(w), @intCast(h), resolution);

    if (@as(?*zip.struct_zip_t, @ptrCast(zip_file))) |z| {
        _ = zip.zip_entry_write(z, writer.written().ptr, @as(usize, writer.written().len));
    }
}

pub fn writeSourceToPng(layer: *const Layer, path: []const u8) !void {
    return pixi_mod.fs.writeSourceToPng(layer.source, path);
}

pub fn resize(layer: *Layer, new_size: dvui.Size) !void {
    const layer_size = layer.size();
    if (layer_size.w == new_size.w and layer_size.h == new_size.h) return;

    var new_layer = Layer.init(
        layer.id,
        runtime.allocator().dupe(u8, layer.name) catch return error.MemoryAllocationFailed,
        @as(u32, @intFromFloat(new_size.w)),
        @as(u32, @intFromFloat(new_size.h)),
        .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .ptr,
    ) catch return error.MemoryAllocationFailed;

    new_layer.blit(layer.pixelsFromRect(dvui.currentWindow().arena(), .{
        .x = 0,
        .y = 0,
        .w = new_size.w,
        .h = new_size.h,
    }) orelse return error.MemoryAllocationFailed, .{
        .x = 0,
        .y = 0,
        .w = new_size.w,
        .h = new_size.h,
    }, .{});

    new_layer.invalidate();

    layer.deinit();
    layer.* = new_layer;
}

/// Tighten `src` to the smallest sub-rect of this layer containing every opaque pixel.
/// Returns null when `src` is empty, off-layer, or covers only fully-transparent pixels.
///
/// Pure scalar logic lives in `pixi_mod.algorithms.reduce.reduce` so it can be exercised by
/// unit tests without dvui / fizzy globals — see that module for the contract details.
pub fn reduce(layer: *Layer, src: dvui.Rect) ?dvui.Rect {
    const sz = layer.size();
    const layer_w: u32 = @intFromFloat(sz.w);
    const layer_h: u32 = @intFromFloat(sz.h);

    const r = pixi_mod.algorithms.reduce.reduce(layer.pixels(), layer_w, layer_h, .{
        .x = @intFromFloat(src.x),
        .y = @intFromFloat(src.y),
        .w = @intFromFloat(src.w),
        .h = @intFromFloat(src.h),
    }) orelse return null;

    return .{
        .x = @floatFromInt(r.x),
        .y = @floatFromInt(r.y),
        .w = @floatFromInt(r.w),
        .h = @floatFromInt(r.h),
    };
}
