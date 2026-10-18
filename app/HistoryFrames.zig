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

/// Each picture, by the history entry on top when it was taken; oldest taken first.
frames: std.AutoArrayHashMapUnmanaged(u64, dvui.Texture) = .empty,
/// The entry on top the frame just drawn shows, to be taken from it at the next (`take`).
due: ?u64 = null,

/// At most this many pictures a document: 64 of 192 by 96 is under 5 MB.
pub const cap = 64;
/// A picture's height in pixels; its width keeps the pane's shape, up to `max_w`.
pub const height: u32 = 96;
pub const max_w: u32 = 192;

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
    const top = self.due orelse return;
    self.due = null;
    var r = pane;
    r.h -= bar_h;
    if (r.w < 8 or r.h < 8) return;
    const prof = core.profile.begin("fizzy", "history.frame");
    defer prof.end();
    const h: f32 = @floatFromInt(height);
    const w: u32 = @intFromFloat(@min(@as(f32, @floatFromInt(max_w)), @round(h * r.w / r.h)));
    const tex = core.FrameTarget.snapshot(r, .{ @max(w, 1), height }) orelse return;
    const gop = self.frames.getOrPut(gpa, top) catch {
        dvui.textureDestroyLater(tex);
        return;
    };
    if (gop.found_existing) {
        // Taken again: the newest, so the last to go.
        dvui.textureDestroyLater(gop.value_ptr.*);
        _ = self.frames.orderedRemove(top);
        self.frames.put(gpa, top, tex) catch dvui.textureDestroyLater(tex);
    } else gop.value_ptr.* = tex;
    while (self.frames.count() > cap) {
        dvui.textureDestroyLater(self.frames.values()[0]);
        self.frames.orderedRemoveAt(0);
    }
}

/// The picture of the document with `top` on top, if one was taken.
pub fn get(self: *const HistoryFrames, top: u64) ?dvui.Texture {
    return self.frames.get(top);
}

pub fn deinit(self: *HistoryFrames, gpa: std.mem.Allocator) void {
    // Destroyed with a frame, and only in one: let go of at teardown (the app quitting) there is
    // no window, and the GPU goes with the process.
    if (dvui.current_window != null) for (self.frames.values()) |t| dvui.textureDestroyLater(t);
    self.frames.deinit(gpa);
}
