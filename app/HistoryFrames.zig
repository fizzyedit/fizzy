//! A document's history as pictures: a small copy of its pane at each step it has stood at, for
//! the transport's strip (`HistoryTransport`), as a video's scrubber shows frames.
//!
//! Owner-agnostic: a picture is what the pane drew, read from the frame the app already keeps in
//! a texture (`core.FrameTarget.snapshot`, scaled down on the GPU), so any document has frames
//! without its owner knowing. Taken only after the document's history moved (`moved`): the frame
//! after an edit lands, an undo, a redo, a scrub's jump. Each is the pane above the bar, keyed by
//! the history entry on top then (0 before any). A step the document never stood at while open
//! here has no picture: the strip shows it plain until a scrub passes over it.
//!
//! Costs nothing on a frame the history did not move; on one it did, a copy of the pane into a
//! texture the strip's size. At most `cap` pictures a document, the oldest taken going first.
const HistoryFrames = @This();

const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const rules = @import("history_transport.zig");

/// Each picture, by the history entry on top when it was taken; oldest taken first.
frames: std.AutoArrayHashMapUnmanaged(u64, Picture) = .empty,
/// The entry on top the frame just drawn shows, to be taken from it at the next (`take`).
due: ?u64 = null,
/// A picture taken last frame, still the target it was drawn into: read the frame after, once
/// its copy has landed, for where its content is (`land`).
unread: ?struct { top: u64, target: dvui.TextureTarget } = null,

/// A picture of the document, and where in it the content is (`content`): what differs from its
/// background, as fractions of it; null where nothing does (an empty document).
pub const Picture = struct { tex: dvui.Texture, content: ?rules.Frac };

/// At most this many pictures a document: 48 of 384 by 192 is about 14 MB.
pub const cap = 48;
/// A picture's height in pixels; its width keeps the pane's shape, up to `max_w`. Fine enough for
/// the strip to frame a few lines of a document close (`paintStrip`) and still read them.
pub const height: u32 = 192;
pub const max_w: u32 = 384;

/// The document's history moved and now has `top` (its entry on top, 0 for none) on top, and the
/// frame the app is drawing shows it: the next frame takes the picture from it. The app asks after
/// the document draws, and sees a move once its owner has reported it: an edit made in the
/// document's own draw or before it is in the frame, and the transport's jumps (made after the
/// document drew) are seen the frame after, which draws them.
pub fn moved(self: *HistoryFrames, top: u64) void {
    self.due = top;
    // Keep the frame in a texture to read from, on a backend that would draw it straight to the
    // window (the web).
    core.FrameTarget.want();
    dvui.refresh(null, @src(), null);
}

/// Before the document draws: take the picture asked for (`moved`) from what the last frame drew of
/// `pane` (physical), above `bar_h` (physical) of its bottom, where the transport and the feed
/// are drawn over it: the bar's height as it stands, its strip included, so a picture never holds
/// the strip itself.
pub fn take(self: *HistoryFrames, gpa: std.mem.Allocator, pane: dvui.Rect.Physical, bar_h: f32) void {
    self.land(gpa);
    const top = self.due orelse return;
    self.due = null;
    var r = pane;
    r.h -= bar_h;
    if (r.w < 8 or r.h < 8) return;
    const prof = core.profile.begin("fizzy", "history.frame");
    defer prof.end();
    const h: f32 = @floatFromInt(height);
    const w: u32 = @intFromFloat(@min(@as(f32, @floatFromInt(max_w)), @round(h * r.w / r.h)));
    const target = core.FrameTarget.snapshotTarget(r, .{ @max(w, 1), height }) orelse return;
    self.unread = .{ .top = top, .target = target };
    // The frame that reads it back.
    dvui.refresh(null, @src(), null);
}

/// The picture taken last frame (`unread`), its copy landed: read back for where its content is
/// (`contentOf`), then kept as a texture. A read of one small picture, once per move.
fn land(self: *HistoryFrames, gpa: std.mem.Allocator) void {
    const u = self.unread orelse return;
    self.unread = null;
    const prof = core.profile.begin("fizzy", "history.frame.content");
    defer prof.end();
    const content = if (dvui.Texture.readTarget(dvui.currentWindow().arena(), u.target)) |px| contentOf(px, u.target.width, u.target.height) else |_| null;
    const tex = dvui.Texture.fromTarget(u.target) catch return;
    const pic: Picture = .{ .tex = tex, .content = content };
    const gop = self.frames.getOrPut(gpa, u.top) catch {
        dvui.textureDestroyLater(tex);
        return;
    };
    if (gop.found_existing) {
        // Taken again: the newest, so the last to go.
        dvui.textureDestroyLater(gop.value_ptr.tex);
        _ = self.frames.orderedRemove(u.top);
        self.frames.put(gpa, u.top, pic) catch dvui.textureDestroyLater(tex);
    } else gop.value_ptr.* = pic;
    while (self.frames.count() > cap) {
        dvui.textureDestroyLater(self.frames.values()[0].tex);
        self.frames.orderedRemoveAt(0);
    }
}

/// Where in a picture of `w` by `h` pixels its content is: the box round every pixel that differs
/// from its background (its bottom-right pixel, where a document least often has anything), as
/// fractions of it. Null where none does. The bands along its bottom and right edges are left
/// out (`edge_band`): a pane's scrollbars and the grip live there, and a long line's horizontal
/// scrollbar made the whole picture content.
pub fn contentOf(px: []const dvui.Color.PMA, w: u32, h: u32) ?rules.Frac {
    if (w == 0 or h == 0 or px.len < @as(usize, w) * h) return null;
    const bg = px[@as(usize, w) * h - 1];
    const fw_band: u32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(w)) * edge_band));
    const fh_band: u32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(h)) * edge_band));
    const scan_w = w -| fw_band;
    const scan_h = h -| fh_band;
    var x0: u32 = w;
    var y0: u32 = h;
    var x1: u32 = 0;
    var y1: u32 = 0;
    for (0..scan_h) |y| for (0..scan_w) |x| {
        const p = px[y * w + x];
        const d = @as(u32, @abs(@as(i32, p.r) - bg.r)) + @abs(@as(i32, p.g) - bg.g) + @abs(@as(i32, p.b) - bg.b);
        if (d < content_contrast) continue;
        x0 = @min(x0, @as(u32, @intCast(x)));
        y0 = @min(y0, @as(u32, @intCast(y)));
        x1 = @max(x1, @as(u32, @intCast(x)) + 1);
        y1 = @max(y1, @as(u32, @intCast(y)) + 1);
    };
    if (x1 <= x0 or y1 <= y0) return null;
    const fw: f32 = @floatFromInt(w);
    const fh: f32 = @floatFromInt(h);
    return .{ .x = @as(f32, @floatFromInt(x0)) / fw, .y = @as(f32, @floatFromInt(y0)) / fh, .w = @as(f32, @floatFromInt(x1 - x0)) / fw, .h = @as(f32, @floatFromInt(y1 - y0)) / fh };
}

/// How far a pixel's colour, summed over its channels, is from the background before it counts as
/// content: past the noise of glass and a pane's gradient.
const content_contrast: u32 = 40;
/// The share of a picture along its bottom and right edges that is never content (`contentOf`).
const edge_band: f32 = 0.1;

/// The picture of the document with `top` on top, if one was taken.
pub fn get(self: *const HistoryFrames, top: u64) ?Picture {
    return self.frames.get(top);
}

pub fn deinit(self: *HistoryFrames, gpa: std.mem.Allocator) void {
    // Destroyed with a frame, and only in one: let go of at teardown (the app quitting) there is
    // no window, and the GPU goes with the process.
    if (dvui.current_window != null) {
        for (self.frames.values()) |p| dvui.textureDestroyLater(p.tex);
        if (self.unread) |u| u.target.destroyLater();
    }
    self.frames.deinit(gpa);
}

test "a picture's content is the box round what differs from its background" {
    const bg: dvui.Color.PMA = .{ .r = 30, .g = 30, .b = 34, .a = 255 };
    var px: [32]dvui.Color.PMA = @splat(bg);
    try std.testing.expectEqual(@as(?rules.Frac, null), contentOf(&px, 8, 4));
    // Two marks: the box round both.
    px[1 * 8 + 2] = .{ .r = 220, .g = 180, .b = 120, .a = 255 };
    px[2 * 8 + 5] = .{ .r = 220, .g = 180, .b = 120, .a = 255 };
    const c = contentOf(&px, 8, 4).?;
    try std.testing.expectEqual(@as(f32, 2.0 / 8.0), c.x);
    try std.testing.expectEqual(@as(f32, 1.0 / 4.0), c.y);
    try std.testing.expectEqual(@as(f32, 4.0 / 8.0), c.w);
    try std.testing.expectEqual(@as(f32, 2.0 / 4.0), c.h);
    // A shade within the noise is not content.
    px[3 * 8 + 0] = .{ .r = 40, .g = 36, .b = 34, .a = 255 };
    try std.testing.expectEqual(c.x, contentOf(&px, 8, 4).?.x);
}
