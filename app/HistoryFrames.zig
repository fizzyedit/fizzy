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
//! Each picture also knows where its step changed the document (`Picture.change`): compared with
//! the picture of the step before, column by column (`columnPrints`), once, as it lands. The strip
//! shows each step's slice there, so it reads as the steps themselves.
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
due: ?Step = null,
/// A picture taken last frame, still the target it was drawn into: read the frame after, once
/// its copy has landed, for where its content is (`land`).
unread: ?struct { step: Step, target: dvui.TextureTarget, source: [2]u32 } = null,

/// A step's picture to take: the entry on top, and the one under it (null before any), whose
/// picture it is compared with for what the step changed.
const Step = struct { top: u64, below: ?u64 };

/// A picture of the document, and where in it the content is (`content`): what differs from its
/// background, as fractions of it; null where nothing does (an empty document).
pub const Picture = struct {
    tex: dvui.Texture,
    content: ?rules.Frac,
    /// Each column's print (`columnPrints`), owned; empty when it could not be read.
    prints: []u32 = &.{},
    /// The size of the pane's part it was taken from, in physical pixels: two pictures are
    /// compared only when taken from the same, or the scaling alone would differ everywhere.
    source: [2]u32 = .{ 0, 0 },
    /// The middle of what this step changed from the one before, as a fraction across; null when
    /// nothing visibly did, or the step before has no picture to compare with.
    change: ?f32 = null,
};

/// At most this many pictures a document: 48 of 384 by 192 is about 14 MB.
pub const cap = 48;
/// A picture's height in pixels; its width keeps the pane's shape, up to `max_w`. Fine enough for
/// the strip to frame a few lines of a document close (`paintStrip`) and still read them.
pub const height: u32 = 192;
pub const max_w: u32 = 384;

/// The document's history moved and now has `top` (its entry on top, 0 for none) on top, `below`
/// the one under it (0 for none, null when `top` is 0), and the frame the app is drawing shows it:
/// the next frame takes the picture from it. The app asks after
/// the document draws, and sees a move once its owner has reported it: an edit made in the
/// document's own draw or before it is in the frame, and the transport's jumps (made after the
/// document drew) are seen the frame after, which draws them.
pub fn moved(self: *HistoryFrames, top: u64, below: ?u64) void {
    self.due = .{ .top = top, .below = below };
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
    const step = self.due orelse return;
    self.due = null;
    var r = pane;
    r.h -= bar_h;
    if (r.w < 8 or r.h < 8) return;
    const prof = core.profile.begin("fizzy", "history.frame");
    defer prof.end();
    const h: f32 = @floatFromInt(height);
    const w: u32 = @intFromFloat(@min(@as(f32, @floatFromInt(max_w)), @round(h * r.w / r.h)));
    const target = core.FrameTarget.snapshotTarget(r, .{ @max(w, 1), height }) orelse return;
    self.unread = .{ .step = step, .target = target, .source = .{ @intFromFloat(@round(r.w)), @intFromFloat(@round(r.h)) } };
    // The frame that reads it back.
    dvui.refresh(null, @src(), null);
}

/// The picture taken last frame (`unread`), its copy landed: read back for where its content is
/// (`contentOf`) and where it changed from the step before (`columnPrints`), then kept as a
/// texture. A read of one small picture, once per move.
fn land(self: *HistoryFrames, gpa: std.mem.Allocator) void {
    const u = self.unread orelse return;
    self.unread = null;
    const prof = core.profile.begin("fizzy", "history.frame.content");
    defer prof.end();
    const w = u.target.width;
    const h = u.target.height;
    var pic: Picture = .{ .tex = undefined, .content = null, .source = u.source };
    // Compared with: null when there is nothing to compare with, so a picture taken again keeps
    // what it knew.
    var compared = false;
    if (dvui.Texture.readTarget(dvui.currentWindow().arena(), u.target)) |px| {
        pic.content = contentOf(px, w, h);
        if (gpa.alloc(u32, w)) |prints| {
            columnPrints(px, w, h, prints);
            pic.prints = prints;
            if (u.step.below) |b| if (self.frames.get(b)) |before| if (before.prints.len == prints.len and prints.len > 0 and std.mem.eql(u32, &before.source, &pic.source)) {
                compared = true;
                if (rules.changedSpan(before.prints, prints)) |c| pic.change = (c.lo + c.hi) / 2;
            };
        } else |_| {}
    } else |_| {}
    pic.tex = dvui.Texture.fromTarget(u.target) catch {
        gpa.free(pic.prints);
        return;
    };
    const top = u.step.top;
    if (self.frames.fetchOrderedRemove(top)) |kv| {
        // Taken again: the newest, so the last to go.
        // Kept only from the same view of it: from another, it is somewhere else now.
        if (!compared and std.mem.eql(u32, &kv.value.source, &pic.source)) pic.change = kv.value.change;
        release(gpa, kv.value);
    }
    self.frames.put(gpa, top, pic) catch release(gpa, pic);
    while (self.frames.count() > cap) {
        release(gpa, self.frames.values()[0]);
        self.frames.orderedRemoveAt(0);
    }
}

fn release(gpa: std.mem.Allocator, pic: Picture) void {
    dvui.textureDestroyLater(pic.tex);
    gpa.free(pic.prints);
}

/// A print of each column of a picture of `w` by `h` pixels into `out` (`w` long): a hash of its
/// pixels, so two pictures of the same size differ in a column exactly where their prints do
/// (`history_transport.changedSpan`). The bands along the bottom and right edges are left out, as
/// for the content (`contentOf`): a scrollbar moving is not the step's change.
pub fn columnPrints(px: []const dvui.Color.PMA, w: u32, h: u32, out: []u32) void {
    @memset(out, 2166136261);
    if (w == 0 or h == 0 or px.len < @as(usize, w) * h or out.len < w) return;
    const scan_w = w -| @as(u32, @intFromFloat(@ceil(@as(f32, @floatFromInt(w)) * edge_band)));
    const scan_h = h -| @as(u32, @intFromFloat(@ceil(@as(f32, @floatFromInt(h)) * edge_band)));
    // Row by row, each column's print taking its pixel in turn: in memory order.
    for (0..scan_h) |y| {
        const row = px[y * w ..][0..scan_w];
        for (row, out[0..scan_w]) |p, *o| o.* = (o.* ^ (@as(u32, p.r) | @as(u32, p.g) << 8 | @as(u32, p.b) << 16 | @as(u32, p.a) << 24)) *% 16777619;
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
    for (self.frames.values()) |p| gpa.free(p.prints);
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

test "a step's change is the span of columns where its picture differs from the one before" {
    const bg: dvui.Color.PMA = .{ .r = 30, .g = 30, .b = 34, .a = 255 };
    const ink: dvui.Color.PMA = .{ .r = 220, .g = 180, .b = 120, .a = 255 };
    const w = 40;
    const h = 20;
    var before: [w * h]dvui.Color.PMA = @splat(bg);
    // A mark already there, at the left.
    for (2..6) |y| before[y * w + 3] = ink;
    var after = before;
    // The step draws a stroke across columns 20 to 25, on two rows.
    for (20..26) |x| for (8..10) |y| {
        after[y * w + x] = ink;
    };
    var pa: [w]u32 = undefined;
    var pb: [w]u32 = undefined;
    columnPrints(&before, w, h, &pa);
    columnPrints(&after, w, h, &pb);
    const span = rules.changedSpan(&pa, &pb).?;
    try std.testing.expectEqual(@as(f32, 20.0 / 40.0), span.lo);
    try std.testing.expectEqual(@as(f32, 26.0 / 40.0), span.hi);
    // Nothing visible changed: no span, and the slice stays where it was.
    try std.testing.expectEqual(@as(?rules.Span, null), rules.changedSpan(&pa, &pa));
    // A change only in the right-hand band (a scrollbar) is not the step's.
    var bar = before;
    for (0..h) |y| bar[y * w + w - 1] = ink;
    columnPrints(&bar, w, h, &pb);
    try std.testing.expectEqual(@as(?rules.Span, null), rules.changedSpan(&pa, &pb));
}
