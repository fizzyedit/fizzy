//! A document's history as pictures: a crop of its pane at each step it has stood at, for the
//! transport's strip (`HistoryTransport`), as a video's scrubber shows frames.
//!
//! Owner-agnostic: a picture is what the pane drew, read from the frame the app already keeps in
//! a texture (`core.FrameTarget.snapshot`), so any document has frames without its owner knowing.
//! Taken only after the document's history moved (`moved`): the frame after an edit lands, an
//! undo, a redo, a scrub's jump. Each is the pane above the bar, keyed by the history entry on top
//! then (0 before any). A step the document never stood at while open here has no picture: the
//! strip shows it plain until a scrub passes over it.
//!
//! A picture is the strip's size, cut from the frame at its own pixels round where its step changed
//! the document (`Picture.change`), so the strip draws it one pixel for one and it reads as
//! crisply as the pane. Where it changed is found on a small copy of the pane, compared with the
//! step before's column by column and row by row (`prints`), once, as it lands.
//!
//! Costs nothing on a frame the history did not move; on one it did, two copies of the pane on the
//! GPU (the whole one into a target kept while the history keeps moving, `whole`), and the next
//! frame a read of the small one and a crop of the other. At most `cap` pictures
//! a document, the oldest taken going first.
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
/// its copy has landed, for where it changed, and cropped from `whole` (`land`).
unread: ?Unread = null,
/// The pane at its own pixels, as the last picture taken saw it: what its crop is cut from. Kept
/// while the history moves frame after frame (a held undo, a scrub), so each step is a copy into
/// it rather than a new pane-sized target; let go of the first frame no picture is asked for.
whole: ?dvui.TextureTarget = null,

const Unread = struct {
    step: Step,
    /// The pane, small (`height` high): read back for where its step changed.
    small: dvui.TextureTarget,
    /// The size of `whole` when it was taken, in pixels.
    source: [2]u32,
    /// The crop's size: the strip's, in pixels.
    crop: [2]u32,
};

/// A step's picture to take: the entry on top, and the one under it (null before any), whose
/// picture it is compared with for what the step changed.
const Step = struct { top: u64, below: ?u64 };

/// A crop of the document's pane at a step, the strip's size at its own pixels, and where the step
/// changed it.
pub const Picture = struct {
    tex: dvui.Texture,
    /// The small copy's prints (`prints`): each column's, then each row's; owned, empty when it
    /// could not be read.
    prints: []u32 = &.{},
    /// The size of the pane's part it was taken from, in physical pixels: two pictures are
    /// compared only when taken from the same, or the scaling alone would differ everywhere.
    source: [2]u32 = .{ 0, 0 },
    /// What this step changed from the one before, as fractions of the pane; null when nothing
    /// visibly did, or the step before has no picture to compare with.
    change: ?rules.Frac = null,
};

/// At most this many pictures a document: each the strip's size, 4 bytes a pixel (a 600 by 104
/// strip on a Retina screen is 250 KB, so 48 are about 12 MB).
pub const cap = 48;
/// The small copy's height in pixels, only for where a step changed; its width keeps the pane's
/// shape, up to `max_w`.
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
/// the strip itself. `strip` is the strip's size in physical pixels (`HistoryTransport.stripPixels`):
/// the crop's; null where the pane has no room for the bar, and no picture is taken.
pub fn take(self: *HistoryFrames, gpa: std.mem.Allocator, pane: dvui.Rect.Physical, bar_h: f32, strip: ?[2]u32) void {
    self.land(gpa);
    const step = self.due orelse {
        self.dropWhole();
        return;
    };
    self.due = null;
    const crop = strip orelse return self.dropWhole();
    // On whole pixels, so the copy at its own size is the pane's pixels, not a blend of two.
    var r: dvui.Rect.Physical = .{ .x = @round(pane.x), .y = @round(pane.y), .w = @round(pane.w), .h = @round(pane.h - bar_h) };
    r = r.intersect(dvui.windowRectPixels());
    if (r.w < 8 or r.h < 8 or crop[0] == 0 or crop[1] == 0) return self.dropWhole();
    const prof = core.profile.begin("fizzy", "history.frame");
    defer prof.end();
    const source: [2]u32 = .{ @intFromFloat(r.w), @intFromFloat(r.h) };
    if (self.whole) |t| if (t.width != source[0] or t.height != source[1]) self.dropWhole();
    const whole = self.whole orelse (dvui.textureCreateTarget(.{ .width = source[0], .height = source[1], .interpolation = .linear }) catch return);
    self.whole = whole;
    const h: f32 = @floatFromInt(height);
    const w: u32 = @intFromFloat(@min(@as(f32, @floatFromInt(max_w)), @round(h * r.w / r.h)));
    if (!core.FrameTarget.snapshotInto(r, whole)) return;
    const small = core.FrameTarget.snapshotTarget(r, .{ @max(w, 1), height }) orelse return;
    self.unread = .{ .step = step, .small = small, .source = source, .crop = crop };
    // The frame that reads it back.
    dvui.refresh(null, @src(), null);
}

fn dropWhole(self: *HistoryFrames) void {
    if (self.whole) |t| t.destroyLater();
    self.whole = null;
}

/// The picture taken last frame (`unread`), its copies landed: the small one read back for where
/// it changed from the step before (`prints`) and let go of, and the crop round that cut from
/// `whole` at its own pixels (`history_transport.cropAt`). A read of one small picture and a copy
/// the strip's size, once per move.
fn land(self: *HistoryFrames, gpa: std.mem.Allocator) void {
    const u = self.unread orelse return;
    self.unread = null;
    defer u.small.destroyLater();
    const whole_target = self.whole orelse return;
    const prof = core.profile.begin("fizzy", "history.frame.crop");
    defer prof.end();
    const w = u.small.width;
    const h = u.small.height;
    var pic: Picture = .{ .tex = undefined, .source = u.source };
    var content: ?rules.Frac = null;
    // Compared with: null when there is nothing to compare with, so a picture taken again keeps
    // what it knew.
    var compared = false;
    if (dvui.Texture.readTarget(dvui.currentWindow().arena(), u.small)) |px| {
        content = contentOf(px, w, h);
        if (gpa.alloc(u32, w + h)) |p| {
            prints(px, w, h, p);
            pic.prints = p;
            if (u.step.below) |b| if (self.frames.get(b)) |before| if (before.prints.len == p.len and std.mem.eql(u32, &before.source, &pic.source)) {
                compared = true;
                const cols = rules.changedSpan(before.prints[0..w], p[0..w]);
                const rows = rules.changedSpan(before.prints[w..], p[w..]);
                if (cols) |c| if (rows) |r| {
                    pic.change = .{ .x = c.lo, .w = c.hi - c.lo, .y = r.lo, .h = r.hi - r.lo };
                };
            };
        } else |_| {}
    } else |_| {}
    const top = u.step.top;
    // Taken again, not compared: what it knew, when taken from the same view of it (from another,
    // it is somewhere else now).
    if (self.frames.get(top)) |old| if (!compared and std.mem.eql(u32, &old.source, &pic.source)) {
        pic.change = old.change;
    };
    // Round what the step changed; one that changed nothing visible, round the document's content,
    // or the pane's middle.
    const round = pic.change orelse content orelse rules.Frac{};
    const sw: f32 = @floatFromInt(u.source[0]);
    const sh: f32 = @floatFromInt(u.source[1]);
    const c = rules.cropAt(.{ (round.x + round.w / 2) * sw, (round.y + round.h / 2) * sh }, u.crop, u.source);
    const whole = dvui.Texture.fromTargetTemp(whole_target) catch {
        gpa.free(pic.prints);
        return;
    };
    const rect: dvui.Rect.Physical = .{ .x = @floatFromInt(c.x), .y = @floatFromInt(c.y), .w = @floatFromInt(c.w), .h = @floatFromInt(c.h) };
    const cropped = core.FrameTarget.copyRect(whole, rect, .{ c.w, c.h }, .nearest) orelse {
        gpa.free(pic.prints);
        return;
    };
    pic.tex = dvui.Texture.fromTarget(cropped) catch {
        cropped.destroyLater();
        gpa.free(pic.prints);
        return;
    };
    // Taken again: the newest, so the last to go.
    if (self.frames.fetchOrderedRemove(top)) |kv| release(gpa, kv.value);
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

/// A print of each column of a picture of `w` by `h` pixels, then of each row, into `out` (`w + h`
/// long): a hash of their pixels, so two pictures of the same size differ in a column or a row
/// exactly where their prints do (`history_transport.changedSpan`). The bands along the bottom and
/// right edges are left out, as for the content (`contentOf`): a scrollbar moving is not the step's
/// change.
pub fn prints(px: []const dvui.Color.PMA, w: u32, h: u32, out: []u32) void {
    @memset(out, 2166136261);
    if (w == 0 or h == 0 or px.len < @as(usize, w) * h or out.len < w + h) return;
    const scan_w = w -| @as(u32, @intFromFloat(@ceil(@as(f32, @floatFromInt(w)) * edge_band)));
    const scan_h = h -| @as(u32, @intFromFloat(@ceil(@as(f32, @floatFromInt(h)) * edge_band)));
    const cols = out[0..w];
    const rows = out[w..][0..h];
    // Row by row, each column's print taking its pixel in turn, and the row's each of its pixels:
    // in memory order.
    for (0..scan_h) |y| {
        const row = px[y * w ..][0..scan_w];
        var r = rows[y];
        for (row, cols[0..scan_w]) |p, *o| {
            const v = @as(u32, p.r) | @as(u32, p.g) << 8 | @as(u32, p.b) << 16 | @as(u32, p.a) << 24;
            o.* = (o.* ^ v) *% 16777619;
            r = (r ^ v) *% 16777619;
        }
        rows[y] = r;
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
        if (self.unread) |u| u.small.destroyLater();
        if (self.whole) |t| t.destroyLater();
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

test "a step's change is the box of columns and rows where its picture differs from the one before" {
    const bg: dvui.Color.PMA = .{ .r = 30, .g = 30, .b = 34, .a = 255 };
    const ink: dvui.Color.PMA = .{ .r = 220, .g = 180, .b = 120, .a = 255 };
    const w = 40;
    const h = 20;
    var before: [w * h]dvui.Color.PMA = @splat(bg);
    // A mark already there, at the left.
    for (2..6) |y| before[y * w + 3] = ink;
    var after = before;
    // The step draws a stroke across columns 20 to 25, on rows 8 and 9.
    for (20..26) |x| for (8..10) |y| {
        after[y * w + x] = ink;
    };
    var pa: [w + h]u32 = undefined;
    var pb: [w + h]u32 = undefined;
    prints(&before, w, h, &pa);
    prints(&after, w, h, &pb);
    const cols = rules.changedSpan(pa[0..w], pb[0..w]).?;
    try std.testing.expectEqual(@as(f32, 20.0 / 40.0), cols.lo);
    try std.testing.expectEqual(@as(f32, 26.0 / 40.0), cols.hi);
    const rows = rules.changedSpan(pa[w..], pb[w..]).?;
    try std.testing.expectEqual(@as(f32, 8.0 / 20.0), rows.lo);
    try std.testing.expectEqual(@as(f32, 10.0 / 20.0), rows.hi);
    // Nothing visible changed: no span either way.
    try std.testing.expectEqual(@as(?rules.Span, null), rules.changedSpan(pa[0..w], pa[0..w]));
    try std.testing.expectEqual(@as(?rules.Span, null), rules.changedSpan(pa[w..], pa[w..]));
    // A change only in the right-hand band (a scrollbar) is not the step's.
    var bar = before;
    for (0..h) |y| bar[y * w + w - 1] = ink;
    prints(&bar, w, h, &pb);
    try std.testing.expectEqual(@as(?rules.Span, null), rules.changedSpan(pa[0..w], pb[0..w]));
    try std.testing.expectEqual(@as(?rules.Span, null), rules.changedSpan(pa[w..], pb[w..]));
}
