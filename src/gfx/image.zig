const std = @import("std");
const fizzy = @import("../fizzy.zig");
const dvui = @import("dvui");
const zip = @import("zip");

pub fn init(width: u32, height: u32, default_color: dvui.Color.PMA, invalidation: dvui.ImageSource.InvalidationStrategy) !dvui.ImageSource {
    const num_pixels = width * height;
    if (num_pixels == 0) return error.InvalidImageSize;
    const p = fizzy.app.allocator.alloc(dvui.Color.PMA, num_pixels) catch return error.MemoryAllocationFailed;

    @memset(p, default_color);

    return .{
        .pixelsPMA = .{
            .rgba = p,
            .width = width,
            .height = height,
            .interpolation = .nearest,
            .invalidation = invalidation,
        },
    };
}

pub fn fromImageFileBytes(name: []const u8, file_bytes: []const u8, invalidation: dvui.ImageSource.InvalidationStrategy) !dvui.ImageSource {
    var w: c_int = undefined;
    var h: c_int = undefined;
    var channels_in_file: c_int = undefined;
    const data = dvui.c.stbi_load_from_memory(file_bytes.ptr, @as(c_int, @intCast(file_bytes.len)), &w, &h, &channels_in_file, 4);
    if (data == null) {
        dvui.log.warn("imageTexture stbi_load error on image \"{s}\": {s}\n", .{ name, dvui.c.stbi_failure_reason() });
        return dvui.StbImageError.stbImageError;
    }
    defer dvui.c.stbi_image_free(data);

    return .{
        .pixelsPMA = .{
            .rgba = dvui.Color.PMA.sliceFromRGBA(fizzy.app.allocator.dupe(u8, data[0..@intCast(w * h * @sizeOf(dvui.Color.PMA))]) catch return error.MemoryAllocationFailed),
            .width = @as(u32, @intCast(w)),
            .height = @as(u32, @intCast(h)),
            .interpolation = .nearest,
            .invalidation = invalidation,
        },
    };
}

pub fn fromImageFilePath(name: []const u8, path: []const u8, invalidation: dvui.ImageSource.InvalidationStrategy) !dvui.ImageSource {
    const file_byes = try fizzy.fs.read(fizzy.app.allocator, dvui.io, path);
    defer fizzy.app.allocator.free(file_byes);
    return fromImageFileBytes(name, file_byes, invalidation);
}

pub fn fromPixelsPMA(pixel_data: []dvui.Color.PMA, width: u32, height: u32, invalidation: dvui.ImageSource.InvalidationStrategy) !dvui.ImageSource {
    return .{
        .pixelsPMA = .{
            .rgba = fizzy.app.allocator.dupe(dvui.Color.PMA, pixel_data) catch return error.MemoryAllocationFailed,
            .interpolation = .nearest,
            .invalidation = invalidation,
            .width = width,
            .height = height,
        }, // TODO: Check if this is correct
    };
}

pub fn fromPixels(pixel_data: []u8, width: u32, height: u32, invalidation: dvui.ImageSource.InvalidationStrategy) !dvui.ImageSource {
    return .{
        .pixels = .{
            .rgba = fizzy.app.allocator.dupe(u8, pixel_data) catch return error.MemoryAllocationFailed,
            .interpolation = .nearest,
            .invalidation = invalidation,
            .width = width,
            .height = height,
        }, // TODO: Check if this is correct
    };
}

pub fn fromTexture(name: []const u8, texture: dvui.Texture, invalidation: dvui.ImageSource.InvalidationStrategy) dvui.ImageSource {
    return .{
        .name = fizzy.app.allocator.dupe(u8, name) catch name,
        .texture = texture,
        .invalidation = invalidation,
        .interpolation = .nearest,
    };
}

pub fn size(source: dvui.ImageSource) dvui.Size {
    return dvui.imageSize(source) catch .{ .w = 0, .h = 0 };
}

pub fn pixels(source: dvui.ImageSource) [][4]u8 {
    switch (source) {
        .pixels => |p| return @as([*][4]u8, @ptrCast(@constCast(p.rgba.ptr)))[0..(p.width * p.height)],
        .pixelsPMA => |p| return @as([*][4]u8, @ptrCast(@constCast(p.rgba.ptr)))[0..(p.width * p.height)],
        .texture => |t| return @as([*][4]u8, @ptrCast(t.ptr))[0..(t.width * t.height)],
        else => {},
    }
    return &.{};
}

/// Returns a slice of pixels from the image source that fit within the specified rect
/// Caller owns the memory returned
pub fn pixelsFromRect(allocator: std.mem.Allocator, source: dvui.ImageSource, rect: dvui.Rect) ?[][4]u8 {
    // Return early if invalid rectangle
    if (rect.w <= 0 or rect.h <= 0) {
        return null;
    }

    // Calculate target dimensions
    const width: usize = @intFromFloat(rect.w);
    const height: usize = @intFromFloat(rect.h);
    var output_pixels = allocator.alloc([4]u8, width * height) catch return null;

    const all_pixels = pixels(source);
    const s = size(source);

    // Image bounds
    const img_w: usize = @intFromFloat(s.w);
    const img_h: usize = @intFromFloat(s.h);

    // Clamp rect start to image bounds
    const rect_start_x: usize = @intFromFloat(rect.x);
    const rect_start_y: usize = @intFromFloat(rect.y);

    // Compute clamp ranges inside source image
    const start_x = @max(0, rect_start_x);
    const start_y = @max(0, rect_start_y);
    const end_x = @min(rect_start_x + width, img_w);
    const end_y = @min(rect_start_y + height, img_h);

    const clamp_x0 = start_x;
    const clamp_x1 = end_x;
    const clamp_y0 = start_y;
    const clamp_y1 = end_y;

    // Fill transparent by default for out-of-bounds
    @memset(output_pixels, .{ 0, 0, 0, 0 });

    // Fast-fill output buffer for the intersection of the rect and the image bounds
    var out_row: usize = 0;
    for (clamp_y0..clamp_y1) |src_y| {
        const rel_y = src_y - rect_start_y;

        // Calculate input/output ranges for this row
        const in_row_start = clamp_x0;
        const in_row_end = clamp_x1;
        var in_idx = src_y * img_w + in_row_start;

        // Bulk copy pixels for the valid intersection region
        for (in_row_start..in_row_end) |src_x| {
            const out_x = src_x - rect_start_x;
            if (rel_y < height and out_x < width and in_idx < all_pixels.len) {
                output_pixels[rel_y * width + out_x] = all_pixels[in_idx];
            }
            in_idx += 1;
        }
        out_row += 1;
    }

    return output_pixels;
}

pub fn bytes(source: dvui.ImageSource) []u8 {
    switch (source) {
        .pixels => |p| return @as([*]u8, @ptrCast(@constCast(p.rgba.ptr)))[0..(p.width * p.height * 4)],
        .pixelsPMA => |p| return @as([*]u8, @ptrCast(@constCast(p.rgba.ptr)))[0..(p.width * p.height * 4)],
        .texture => |t| return @as([*]u8, @ptrCast(t.ptr))[0..(t.width * t.height * 4)],
        else => {},
    }
    return &.{};
}

pub fn pixelIndex(source: dvui.ImageSource, px: dvui.Point) ?usize {
    if (px.x < 0 or px.y < 0) {
        return null;
    }

    const s = size(source);

    if (px.x > s.w or px.y > s.h) {
        return null;
    }

    const p: [2]usize = .{ @intFromFloat(px.x), @intFromFloat(px.y) };

    const index = p[0] + p[1] * @as(usize, @intFromFloat(s.w));
    if (index >= pixels(source).len) {
        return null;
    }
    return index;
}

pub fn point(source: dvui.ImageSource, index: usize) ?dvui.Point {
    if (index >= pixels(source).len) {
        return null;
    }
    const s = size(source);

    return .{ .x = @floatFromInt(index % @as(usize, @intFromFloat(s.w))), .y = @floatFromInt(index / @as(usize, @intFromFloat(s.w))) };
}

pub fn pixel(source: dvui.ImageSource, p: dvui.Point) ?[4]u8 {
    if (pixelIndex(source, p)) |index| {
        return pixels(source)[index];
    }
    return null;
}

pub fn setPixel(source: dvui.ImageSource, p: dvui.Point, color: [4]u8) void {
    if (pixelIndex(source, p)) |index| {
        pixels(source)[index] = color;
    }
}

pub fn setPixelIndex(source: dvui.ImageSource, index: usize, color: [4]u8) void {
    if (index >= pixels(source).len) {
        return;
    }
    pixels(source)[index] = color;
}

pub fn clearRect(source: dvui.ImageSource, rect: dvui.Rect) void {
    setRect(source, rect, .{ 0, 0, 0, 0 });
}

pub fn setRect(source: dvui.ImageSource, rect: dvui.Rect, color: [4]u8) void {
    const x = @as(usize, @intFromFloat(rect.x));
    const y = @as(usize, @intFromFloat(rect.y));
    const width = @as(usize, @intFromFloat(rect.w));
    const height = @as(usize, @intFromFloat(rect.h));

    const image_size = size(source);

    const tex_width = @as(usize, @intFromFloat(image_size.w));

    var yy = y;
    var h = height;

    var d = pixels(source)[x + yy * tex_width .. x + yy * tex_width + width];
    var src_y: usize = 0;
    while (h > 0) {
        h -= 1;
        @memset(d, color);

        // next row and move our slice to it as well
        src_y += 1;
        yy += 1;

        const next_row_start = x + yy * tex_width;
        const next_row_end = next_row_start + width;
        if (next_row_start < pixels(source).len and next_row_end <= pixels(source).len) {
            d = pixels(source)[next_row_start..next_row_end];
        }
    }
}

pub fn blit(source: dvui.ImageSource, dst_pixels: [][4]u8, dst_rect: dvui.Rect, transparent: bool) void {
    const image_size = size(source);

    blitData(pixels(source), @intFromFloat(image_size.w), @intFromFloat(image_size.h), dst_pixels, dst_rect, transparent);
}

/// When `transparent` is true: composite **src_pixels** (upper) overlaid on **dst_pixels** (lower)
/// and write the result back into **src_pixels** (used by multi-layer CPU flattening).
/// When false: copies each row of `dst_pixels` into the corresponding row of `src_pixels`.
pub fn blitData(src_pixels: [][4]u8, src_width: usize, src_height: usize, dst_pixels: [][4]u8, dst_rect: dvui.Rect, transparent: bool) void {
    const x = @as(usize, @intFromFloat(dst_rect.x));
    const y = @as(usize, @intFromFloat(dst_rect.y));
    const width = @as(usize, @intFromFloat(dst_rect.w));
    const height = @as(usize, @intFromFloat(dst_rect.h));

    const image_size: dvui.Size = .{ .w = @floatFromInt(src_width), .h = @floatFromInt(src_height) };

    const tex_width = @as(usize, @intFromFloat(image_size.w));

    var yy = y;
    var h = height;

    var source_row = src_pixels[x + yy * tex_width .. x + yy * tex_width + width];
    var src_y: usize = 0;
    while (h > 0) {
        h -= 1;
        const dst_row = dst_pixels[src_y * width .. (src_y * width) + width];
        if (!transparent) {
            @memcpy(source_row, dst_row);
        } else {
            for (source_row, dst_row) |*top_px, bot_px| {
                const top_c = dvui.Color{ .r = top_px[0], .g = top_px[1], .b = top_px[2], .a = top_px[3] };
                const bot_c = dvui.Color{ .r = bot_px[0], .g = bot_px[1], .b = bot_px[2], .a = bot_px[3] };
                const tpm = dvui.Color.PMA.fromColor(top_c);
                const bpm = dvui.Color.PMA.fromColor(bot_c);
                const out_pma = fizzy.Internal.Layer.blendPmaSrcOver(@bitCast(tpm), @bitCast(bpm));
                top_px.* = @as(dvui.Color.PMA, @bitCast(out_pma)).toColor().toRGBA();
            }
        }

        // next row and move our slice to it as well
        src_y += 1;
        yy += 1;

        const next_row_start = x + yy * tex_width;
        const next_row_end = next_row_start + width;
        if (next_row_start < src_pixels.len and next_row_end <= src_pixels.len) {
            source_row = src_pixels[next_row_start..next_row_end];
        }
    }
}

fn ensurePngWriterBuffer(writer: *std.Io.Writer) !void {
    if (writer.buffer.len < dvui.PNGEncoder.min_buffer_size) {
        try writer.rebase(0, dvui.PNGEncoder.min_buffer_size);
    }
}

pub fn writeToZip(
    source: dvui.ImageSource,
    zip_file: ?*anyopaque,
    resolution: u32,
) !void {
    const s: dvui.Size = dvui.imageSize(source) catch .{ .w = 0, .h = 0 };

    const w = @as(c_int, @intFromFloat(s.w));
    const h = @as(c_int, @intFromFloat(s.h));

    var writer = std.Io.Writer.Allocating.init(fizzy.editor.arena.allocator());

    try ensurePngWriterBuffer(&writer.writer);
    try dvui.PNGEncoder.writeWithResolution(&writer.writer, fizzy.image.bytes(source), @intCast(w), @intCast(h), resolution);

    if (@as(?*zip.struct_zip_t, @ptrCast(zip_file))) |z| {
        _ = zip.zip_entry_write(z, writer.written().ptr, @as(usize, writer.written().len));
    }
}

pub fn writePngToWriter(source: dvui.ImageSource, writer: *std.Io.Writer, resolution: u32) !void {
    const flat = try flatRgbaForEncode(source);
    try ensurePngWriterBuffer(writer);
    if (resolution > 0) {
        try dvui.PNGEncoder.writeWithResolution(writer, flat.data, flat.w, flat.h, resolution);
    } else {
        try dvui.PNGEncoder.write(writer, flat.data, flat.w, flat.h);
    }
}

pub fn writeJpgPpiToWriter(source: dvui.ImageSource, writer: *std.Io.Writer, ppi: u16) !void {
    const flat = try flatRgbaForEncode(source);
    var enc = dvui.JPGEncoder.initDensity(writer, ppi);
    try enc.writeWithQuality(flat.data, flat.w, flat.h, 90);
}

pub fn writeToPng(source: dvui.ImageSource, path: []const u8) !void {
    const s: dvui.Size = dvui.imageSize(source) catch .{ .w = 0, .h = 0 };

    const w: u32 = @intFromFloat(s.w);
    const h: u32 = @intFromFloat(s.h);
    const data: []u8 = switch (source) {
        .pixels => |p| @as([*]u8, @ptrCast(@constCast(p.rgba.ptr)))[0..(p.width * p.height * 4)],
        .pixelsPMA => |p| @as([*]u8, @ptrCast(@constCast(p.rgba.ptr)))[0..(p.width * p.height * 4)],
        else => return error.InvalidImageSource,
    };

    const io = dvui.io;
    var handle = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer handle.close(io);

    var buffer: [512]u8 = undefined;
    var writer = handle.writer(io, &buffer);

    try dvui.PNGEncoder.write(&writer.interface, data, w, h);
    try writer.end();
}

pub fn writeToPngResolution(source: dvui.ImageSource, path: []const u8, resolution: u32) !void {
    const s: dvui.Size = dvui.imageSize(source) catch .{ .w = 0, .h = 0 };

    const w: u32 = @intFromFloat(s.w);
    const h: u32 = @intFromFloat(s.h);
    const data: []u8 = switch (source) {
        .pixels => |p| @as([*]u8, @ptrCast(@constCast(p.rgba.ptr)))[0..(p.width * p.height * 4)],
        .pixelsPMA => |p| @as([*]u8, @ptrCast(@constCast(p.rgba.ptr)))[0..(p.width * p.height * 4)],
        else => return error.InvalidImageSource,
    };

    const io = dvui.io;
    var handle = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer handle.close(io);

    var buffer: [512]u8 = undefined;
    var writer = handle.writer(io, &buffer);

    try dvui.PNGEncoder.writeWithResolution(&writer.interface, data, w, h, resolution);
    try writer.end();
}

fn flatRgbaForEncode(source: dvui.ImageSource) !struct { data: []u8, w: u32, h: u32 } {
    const s: dvui.Size = dvui.imageSize(source) catch .{ .w = 0, .h = 0 };
    const w: u32 = @intFromFloat(s.w);
    const h: u32 = @intFromFloat(s.h);
    const data: []u8 = switch (source) {
        .pixels => |p| @as([*]u8, @ptrCast(@constCast(p.rgba.ptr)))[0..(p.width * p.height * 4)],
        .pixelsPMA => |p| @as([*]u8, @ptrCast(@constCast(p.rgba.ptr)))[0..(p.width * p.height * 4)],
        else => return error.InvalidImageSource,
    };
    return .{ .data = data, .w = w, .h = h };
}

pub fn writeToJpg(source: dvui.ImageSource, path: []const u8) !void {
    const flat = try flatRgbaForEncode(source);

    const io = dvui.io;
    var handle = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer handle.close(io);

    var buffer: [512]u8 = undefined;
    var writer = handle.writer(io, &buffer);

    try dvui.JPGEncoder.write(&writer.interface, flat.data, flat.w, flat.h);
    try writer.end();
}

/// `ppi` is pixels per inch (e.g. from `round(window.natural_scale * 72)`). Safe for use off the UI thread
/// when the value is computed on the main thread.
pub fn writeToJpgPpi(source: dvui.ImageSource, path: []const u8, ppi: u16) !void {
    const flat = try flatRgbaForEncode(source);

    const io = dvui.io;
    var handle = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer handle.close(io);

    var buffer: [512]u8 = undefined;
    var writer = handle.writer(io, &buffer);

    var enc = dvui.JPGEncoder.initDensity(&writer.interface, ppi);
    try enc.writeWithQuality(flat.data, flat.w, flat.h, 90);
    try writer.end();
}
