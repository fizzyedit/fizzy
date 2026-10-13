//! A picture of the window as the app drew it, read back from the app's own frame target: what an
//! agent looks at, with or without the window on screen. A window on another Space, occluded or
//! minimized is presented nowhere, but the app's frames still draw into the target, so the picture
//! is there to read; and nothing outside the app — no screen recording, no window list — is asked.
//!
//! Only what the app draws: what the OS composites over or behind the window (its materials, a
//! window of Liquid Glass) is not in it, and shows as the target's own transparency.
//!
//! Asked for like a `Snapshot` (`request`, then `get` once taken): the next frame the app draws
//! is read back at its end (`endFrame`), encoded as a PNG, and kept until the next is taken.
const Capture = @This();

const std = @import("std");
const dvui = @import("dvui");

gpa: std.mem.Allocator,
pending: bool = false,
/// How many have been taken; the last is `taken`.
taken: u32 = 0,
png: std.ArrayListUnmanaged(u8) = .empty,

pub fn init(gpa: std.mem.Allocator) Capture {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Capture) void {
    self.png.deinit(self.gpa);
}

/// Ask for a picture of the next frame: the app wakes for it. Asking again before it is taken
/// names the same one.
pub fn request(self: *Capture) u32 {
    if (!self.pending) {
        self.pending = true;
        dvui.refresh(null, @src(), null);
    }
    return self.taken + 1;
}

/// The frame drawn into `target`, its top-left `w` by `h` pixels (a target can be kept larger than
/// the frame), read back and encoded: at the end of the app's frame, after everything has drawn
/// into the target. Between `Window.begin` and `Window.end`.
pub fn endFrame(self: *Capture, target: dvui.Texture.Target, w: u32, h: u32) void {
    if (!self.pending) return;
    self.pending = false;
    var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const all = dvui.Texture.readTarget(arena, target) catch |err| {
        dvui.log.warn("capture: could not read the frame back: {t}", .{err});
        return;
    };
    const cw = @min(w, target.width);
    const ch = @min(h, target.height);
    // The frame's pixels, premultiplied as drawn, as straight alpha for the PNG.
    const rgba = arena.alloc(u8, @as(usize, cw) * ch * 4) catch return;
    for (0..ch) |y| for (0..cw) |x| {
        const p = all[y * target.width + x];
        const o = (y * cw + x) * 4;
        const a: u32 = p.a;
        rgba[o + 0] = if (a == 0) 0 else @intCast(@min(255, (@as(u32, p.r) * 255 + a / 2) / a));
        rgba[o + 1] = if (a == 0) 0 else @intCast(@min(255, (@as(u32, p.g) * 255 + a / 2) / a));
        rgba[o + 2] = if (a == 0) 0 else @intCast(@min(255, (@as(u32, p.b) * 255 + a / 2) / a));
        rgba[o + 3] = p.a;
    };
    // The encoder writes its chunks straight into the writer's buffer: it must hold one.
    self.png.clearRetainingCapacity();
    self.png.ensureTotalCapacity(self.gpa, @max(dvui.PNGEncoder.min_buffer_size, 64 * 1024)) catch return;
    var out: std.Io.Writer.Allocating = .fromArrayList(self.gpa, &self.png);
    dvui.PNGEncoder.write(&out.writer, rgba, cw, ch) catch |err| {
        dvui.log.warn("capture: could not encode: {t}", .{err});
        self.png = out.toArrayList();
        return;
    };
    self.png = out.toArrayList();
    self.taken += 1;
}

/// Picture `n` as a PNG, while it is the last one taken; null before it is, or once another is.
/// Valid until the next is taken.
pub fn get(self: *const Capture, n: u32) ?[]const u8 {
    return if (n == self.taken and n != 0) self.png.items else null;
}
