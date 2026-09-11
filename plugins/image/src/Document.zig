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
/// What is drawn this frame. For a still image, the only pixels there are; for an animation,
/// an alias of `animation.frames[frame]`, owned by the animation and never freed on its own.
source: dvui.ImageSource,
width: u32,
height: u32,
/// Every frame, when the file has more than one. The view advances `frame` on its own timer.
animation: ?core.image.Animation = null,
frame: usize = 0,
checkerboard_tile: ?dvui.Texture = null,
canvas: CanvasWidget = .{},

pub fn fromBytes(path: []const u8, bytes: []const u8) !Document {
    const gpa = sdk.allocator();
    const path_copy = try gpa.dupe(u8, path);
    errdefer gpa.free(path_copy);

    const decoded = try decode(path, bytes);
    const size = core.image.size(decoded.source);

    return .{
        .id = sdk.host().allocDocId(),
        .path = path_copy,
        .source = decoded.source,
        .animation = decoded.animation,
        .width = @intFromFloat(size.w),
        .height = @intFromFloat(size.h),
    };
}

const Decoded = struct { source: dvui.ImageSource, animation: ?core.image.Animation };

/// One decode path for open and reload. A GIF comes back as all of its frames and shows the
/// first; anything else is a single still.
fn decode(path: []const u8, bytes: []const u8) !Decoded {
    const name = std.fs.path.basename(path);
    if (std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".gif")) {
        const anim = try core.image.fromGifFileBytesAlloc(sdk.allocator(), name, bytes, .ptr);
        if (anim.frames.len > 1) return .{ .source = anim.frames[0], .animation = anim };
        // A single-frame GIF is a still; keep it as one so the view has no timer to run.
        const only = anim.frames[0];
        sdk.allocator().free(anim.frames);
        sdk.allocator().free(anim.delays_ms);
        return .{ .source = only, .animation = null };
    }
    return .{ .source = try core.image.fromImageFileBytes(name, bytes, .ptr), .animation = null };
}

/// Release the decoded pixels — the animation's frames, or the lone still.
fn freePixels(self: *Document) void {
    const gpa = sdk.allocator();
    if (self.animation) |*anim| {
        anim.deinit(gpa);
        self.animation = null;
        return;
    }
    switch (self.source) {
        .pixelsPMA => |p| gpa.free(p.rgba),
        .pixels => |p| gpa.free(p.rgba),
        .imageFile => |f| gpa.free(f.bytes),
        .texture => |t| dvui.textureDestroyLater(t),
    }
}

pub fn fromPath(path: []const u8) !Document {
    if (comptime is_wasm) return error.Unsupported;
    const gpa = sdk.allocator();
    const bytes = try core.fs.read(gpa, dvui.io, path);
    defer gpa.free(bytes);
    return fromBytes(path, bytes);
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
    const bytes = try core.fs.read(gpa, dvui.io, self.path);
    defer gpa.free(bytes);
    const decoded = try decode(self.path, bytes);
    const size = core.image.size(decoded.source);

    self.freePixels();
    if (self.checkerboard_tile) |t| {
        dvui.textureDestroyLater(t);
        self.checkerboard_tile = null;
    }

    self.source = decoded.source;
    self.animation = decoded.animation;
    self.frame = 0;
    self.width = @intFromFloat(size.w);
    self.height = @intFromFloat(size.h);
}

pub fn deinit(self: *Document) void {
    const gpa = sdk.allocator();
    self.freePixels();
    gpa.free(self.path);
    if (self.checkerboard_tile) |t| dvui.textureDestroyLater(t);
    if (self.canvas.installed) self.canvas.deinit();
}
