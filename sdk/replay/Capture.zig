//! A picture of a window as the app drew it, read back from the target the app drew it into: what
//! an agent looks at, with or without the window on screen. A window on another Space, occluded or
//! minimized is presented nowhere, but the app's frames still draw into its target, so the picture
//! is there to read; and nothing outside the app — no screen recording, no window list — is asked.
//!
//! Only what the app draws: what the OS composites over or behind the window (its materials, a
//! window of Liquid Glass) is not in it, and shows as the target's own transparency.
//!
//! An app that shows parts of its frame in OS windows of their own — a dialog, a menu, a view
//! popped out — hands each window's target over too (`Source`), named as a snapshot names the
//! window (`Snapshot.Window.tag`). A picture is asked for by that name: the main window's by none,
//! and every window at once, laid out as they lie on the desktop round the main one, by `all`.
//!
//! Asked for like a `Snapshot` (`request`, then `get` once taken): the next frame the app draws
//! is read back at its end (`endFrame`) and kept, as the raw premultiplied pixels it drew, until the
//! next is taken. Nothing is encoded here: the frame pays for one read back and one copy, and
//! whoever wants an image file (the agent's bridge, in its own process) scales and encodes it.
const Capture = @This();

const std = @import("std");
const dvui = @import("dvui");

gpa: std.mem.Allocator,
pending: bool = false,
/// The window the pending picture is of (`request`).
window_buf: [256]u8 = undefined,
window_len: usize = 0,
/// How many have been taken; the last is `taken`.
taken: u32 = 0,
/// The last picture taken: premultiplied RGBA, row by row, `width` by `height`.
pixels: std.ArrayListUnmanaged(u8) = .empty,
width: u32 = 0,
height: u32 = 0,

/// The name that asks for every window at once (`request`).
pub const all = "*";

/// A window the app drew this frame, for a picture of it.
pub const Source = struct {
    /// The name it is asked for by: its window's tag in a snapshot. The main window is the first
    /// source, and is asked for by none as well.
    tag: []const u8,
    target: dvui.Texture.Target,
    /// The frame's part of the target, from its top left (a target can be kept larger).
    w: u32,
    h: u32,
    /// Where the window lies over the main window, physical pixels from its top left: where it goes
    /// in a picture of every window (`all`).
    at: dvui.Point.Physical = .{},
    /// What it stands on in a picture of every window: the colour the OS's material under it
    /// reads as. A window on the OS's glass draws nothing there, and over the main window would
    /// show the main window through it. Null: nothing under it.
    backing: ?dvui.Color = null,
};

pub fn init(gpa: std.mem.Allocator) Capture {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Capture) void {
    self.pixels.deinit(self.gpa);
}

/// Ask for a picture of the next frame of `window` — a window's tag, none for the main window, or
/// `all` — and the app wakes for it. Asking again before it is taken names the same one, of the
/// window first asked for.
pub fn request(self: *Capture, window: []const u8) u32 {
    if (!self.pending) {
        self.pending = true;
        self.window_len = @min(window.len, self.window_buf.len);
        @memcpy(self.window_buf[0..self.window_len], window[0..self.window_len]);
        dvui.refresh(null, @src(), null);
    }
    return self.taken + 1;
}

/// Whether a picture is waiting for this frame: the app need not name its windows otherwise.
pub fn wanted(self: *const Capture) bool {
    return self.pending;
}

/// At the end of the app's frame, after everything has drawn into the windows' targets: the
/// picture asked for is read back and kept — empty when no window has the name it was asked for
/// by. `sources` are this frame's windows, the main one first. Between `Window.begin` and
/// `Window.end`.
pub fn endFrame(self: *Capture, sources: []const Source) void {
    if (!self.pending or sources.len == 0) return;
    self.pending = false;
    self.pixels.clearRetainingCapacity();
    self.width = 0;
    self.height = 0;
    self.taken += 1;
    var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const window = self.window_buf[0..self.window_len];
    const picture = (if (std.mem.eql(u8, window, all)) everyWindow(arena, sources) else one: {
        const src = if (window.len == 0) sources[0] else for (sources) |s| {
            if (std.mem.eql(u8, s.tag, window)) break s;
        } else return;
        break :one read(arena, src);
    }) catch |err| {
        dvui.log.warn("capture: could not read the frame back: {t}", .{err});
        return;
    };
    self.pixels.appendSlice(self.gpa, picture.pma) catch return;
    self.width = picture.w;
    self.height = picture.h;
}

/// A picture as it was drawn: premultiplied RGBA, row by row.
pub const Image = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
};

/// Picture `n`, while it is the last one taken — empty (0 by 0) when no window had the name it was
/// asked for by; null before it is taken, or once another is. Valid until the next is taken.
pub fn get(self: *const Capture, n: u32) ?Image {
    if (n != self.taken or n == 0) return null;
    return .{ .pixels = self.pixels.items, .width = self.width, .height = self.height };
}

/// A picture, premultiplied RGBA, row by row.
const Pixels = struct { pma: []u8, w: u32, h: u32 };

/// `src`'s part of its target.
fn read(arena: std.mem.Allocator, src: Source) !Pixels {
    const t = src.target;
    const px = try dvui.Texture.readTarget(arena, t);
    const w = @min(src.w, t.width);
    const h = @min(src.h, t.height);
    // `Color.PMA` is four bytes in RGBA order, so a row of the target is a row of the picture.
    const bytes = std.mem.sliceAsBytes(px);
    const row = @as(usize, w) * 4;
    if (w == t.width) return .{ .pma = bytes[0 .. row * h], .w = w, .h = h };
    const out = try arena.alloc(u8, row * h);
    for (0..h) |y| @memcpy(out[y * row ..][0..row], bytes[y * @as(usize, t.width) * 4 ..][0..row]);
    return .{ .pma = out, .w = w, .h = h };
}

/// The most a picture of every window spans each way, physical pixels: a window far off the main
/// one is cut off, rather than the picture taking in all the desktop between them.
const max_side: f32 = 8192;

/// Every window, each where it lies round the main window, a later one over an earlier.
fn everyWindow(arena: std.mem.Allocator, sources: []const Source) !Pixels {
    var span: dvui.Rect.Physical = .{ .w = @floatFromInt(sources[0].w), .h = @floatFromInt(sources[0].h) };
    for (sources[1..]) |s| span = span.unionWith(.{ .x = s.at.x, .y = s.at.y, .w = @floatFromInt(s.w), .h = @floatFromInt(s.h) });
    const w: u32 = @intFromFloat(@min(@round(span.w), max_side));
    const h: u32 = @intFromFloat(@min(@round(span.h), max_side));
    const out = try arena.alloc(u8, @as(usize, w) * h * 4);
    @memset(out, 0);
    for (sources) |s| {
        const pic = try read(arena, s);
        const ox: i64 = @intFromFloat(@round(s.at.x - span.x));
        const oy: i64 = @intFromFloat(@round(s.at.y - span.y));
        if (s.backing) |c| for (0..pic.h) |y| {
            const cy = oy + @as(i64, @intCast(y));
            if (cy < 0 or cy >= h) continue;
            for (0..pic.w) |x| {
                const cx = ox + @as(i64, @intCast(x));
                if (cx < 0 or cx >= w) continue;
                out[(@as(usize, @intCast(cy)) * w + @as(usize, @intCast(cx))) * 4 ..][0..4].* = .{ c.r, c.g, c.b, 255 };
            }
        };
        for (0..pic.h) |y| {
            const cy = oy + @as(i64, @intCast(y));
            if (cy < 0 or cy >= h) continue;
            for (0..pic.w) |x| {
                const cx = ox + @as(i64, @intCast(x));
                if (cx < 0 or cx >= w) continue;
                const from = pic.pma[(y * pic.w + x) * 4 ..][0..4];
                const into = out[(@as(usize, @intCast(cy)) * w + @as(usize, @intCast(cx))) * 4 ..][0..4];
                // Over, premultiplied.
                const keep: u32 = 255 - from[3];
                for (into, from) |*d, sv| d.* = @intCast(@min(255, @as(u32, sv) + (@as(u32, d.*) * keep + 127) / 255));
            }
        }
    }
    return .{ .pma = out, .w = w, .h = h };
}
