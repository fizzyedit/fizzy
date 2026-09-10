//! A single open image document: path, decoded pixels, and per-document canvas state.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const core = @import("core");
const sdk = @import("fizzy_sdk");

const is_wasm = builtin.target.cpu.arch == .wasm32;

const CanvasWidget = core.widgets.CanvasWidget;

const Document = @This();

id: u64,
path: []u8,
grouping: u64 = 0,
source: dvui.ImageSource,
width: u32,
height: u32,
checkerboard_tile: ?dvui.Texture = null,
canvas: CanvasWidget = .{},

pub fn fromBytes(path: []const u8, bytes: []const u8) !Document {
    const gpa = sdk.allocator();
    const path_copy = try gpa.dupe(u8, path);
    errdefer gpa.free(path_copy);

    const name = std.fs.path.basename(path);
    const source = try core.image.fromImageFileBytes(name, bytes, .ptr);
    const size = core.image.size(source);

    return .{
        .id = sdk.host().allocDocId(),
        .path = path_copy,
        .source = source,
        .width = @intFromFloat(size.w),
        .height = @intFromFloat(size.h),
    };
}

pub fn fromPath(path: []const u8) !Document {
    if (comptime is_wasm) return error.Unsupported;
    const gpa = sdk.allocator();
    const path_copy = try gpa.dupe(u8, path);
    errdefer gpa.free(path_copy);

    const name = std.fs.path.basename(path);
    const source = try core.image.fromImageFilePath(name, path, .ptr);
    const size = core.image.size(source);

    return .{
        .id = sdk.host().allocDocId(),
        .path = path_copy,
        .source = source,
        .width = @intFromFloat(size.w),
        .height = @intFromFloat(size.h),
    };
}

pub fn isDirty(_: *const Document) bool {
    return false;
}

pub fn save(_: *Document) !void {}

/// Re-decode pixels from `path`, keeping id/path/grouping/canvas. Used when the file
/// changes on disk while this tab is open.
pub fn reloadFromDisk(self: *Document) !void {
    if (comptime is_wasm) return error.Unsupported;
    const gpa = sdk.allocator();
    const name = std.fs.path.basename(self.path);
    const new_source = try core.image.fromImageFilePath(name, self.path, .ptr);
    const size = core.image.size(new_source);

    switch (self.source) {
        .pixelsPMA => |p| gpa.free(p.rgba),
        .pixels => |p| gpa.free(p.rgba),
        .imageFile => |f| gpa.free(f.bytes),
        .texture => |t| dvui.textureDestroyLater(t),
    }
    if (self.checkerboard_tile) |t| {
        dvui.textureDestroyLater(t);
        self.checkerboard_tile = null;
    }

    self.source = new_source;
    self.width = @intFromFloat(size.w);
    self.height = @intFromFloat(size.h);
}

pub fn deinit(self: *Document) void {
    const gpa = sdk.allocator();
    switch (self.source) {
        .pixelsPMA => |p| gpa.free(p.rgba),
        .pixels => |p| gpa.free(p.rgba),
        .imageFile => |f| gpa.free(f.bytes),
        .texture => |t| dvui.textureDestroyLater(t),
    }
    gpa.free(self.path);
    if (self.checkerboard_tile) |t| dvui.textureDestroyLater(t);
    if (self.canvas.installed) self.canvas.deinit();
}
