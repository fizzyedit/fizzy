//! **Panes**: N panes sharing one axis by *share*, with a draggable boundary between each pair.
//!
//! The second of fizzy's two sizing models, and the difference between them is what the size
//! *means* — which is a question about the thing being sized, not about the widget:
//!
//! - `Split` + `Region` size in **points**. A sidebar is 260pt wide because that is how wide a
//!   file tree wants to be; widening the window gives the extra room to the documents, not to
//!   the tree. One number per region, and a window resize leaves it alone.
//!
//! - `Panes` sizes by **share**. Three documents side by side are a third each *of whatever
//!   there is*; widening the window widens all three. Nothing here has an opinion in points, so
//!   there is nothing for a resize to invalidate.
//!
//! Documents are the second kind, and giving them the first is what made them feel wrong. Under
//! points, one pane had to absorb the remainder and every other pane carried a fixed width — so
//! dragging the boundary between panes 2 and 3 grew pane 3 while pane 2 kept its width and
//! *slid*, moving every divider left of the one under the pointer; and once the absorbing pane
//! hit the minimum its content asked for, every split locked at once. Both are the same bug:
//! with one flexible pane, a boundary is not a boundary.
//!
//! A share also makes a drag *positional*: a boundary is a distance from the row's leading edge,
//! which is a number that does not move while you drag it. From that one number the rest of the
//! row follows by one rule, applied on both sides — **the pane touching the boundary absorbs the
//! change, and what it cannot absorb cascades outward**. Drag right and the next pane shrinks,
//! then shuts, then the one past it shuts; drag back and the room returns nearest-first. There is
//! no minimum, so "as far as it will go" means gone, and the collapsed panes' handles stack at
//! the edge of the row where they can be picked up again.
//!
//! ```zig
//! var ids: [8]dvui.Id = undefined;
//! for (groups, 0..) |g, i| ids[i] = paneId(g);
//!
//! var panes = core.widgets.panes(@src(), .horizontal, ids[0..groups.len]);
//! defer panes.deinit();
//! for (groups, 0..) |g, i| {
//!     panes.divider(@src(), i); // no-op before the first pane
//!     var p = panes.pane(@src(), i);
//!     defer p.deinit();
//!     drawGroup(g);
//! }
//! ```
//!
//! Ids are the caller's, and they must be keyed by *what the pane holds* rather than by its
//! position — keyed by index, closing a pane hands its share to whatever slides into the slot.
const std = @import("std");
const dvui = @import("dvui");
const Split = @import("Split.zig");

const Panes = @This();

/// Shares live under the pane's own id, beside the extents a `Split` would have written there.
const share_key = "_share";
const shown_key = "_share_shown";
const anim_key = "_share_ease";

/// There is deliberately **no minimum size and no maximum count**.
///
/// A pane collapses all the way to nothing, like every other split in the app, and its divider
/// stays where it is — several collapsed panes stack their handles at the edge of the row, each
/// still grabbable, which is how you get them back. A minimum in points could not be honoured
/// anyway: shares scale with the row, so a floor that holds at one window width is breached by
/// narrowing the window, and a drag that refuses to move because the pair is already under the
/// floor is exactly the "locked, then jumps" feel a minimum was supposed to prevent.
///
/// A cap on the count would mean the app's "open to the side" quietly doing nothing once enough
/// documents are open, which is worse than a row too crowded to use — that one the user chose and
/// can undo by dragging. Past the point where the handles alone fill the row the panes are simply
/// nothing wide.
axis: dvui.enums.Direction,
/// The row. Opened by `init` so the panes and the dividers are its children and nothing else is.
box: *dvui.BoxWidget,
ids: []const dvui.Id,
/// Room for the panes themselves: the row's extent less what the dividers take.
available: f32 = 0,
/// Sum of the *shown* shares, which is what a width is a fraction of. Tracked rather than
/// recomputed per pane so a pane sliding in (shown share travelling up from zero) narrows its
/// neighbours smoothly instead of overflowing the row.
total: f32 = 0,
/// Every pane's drawn extent and leading offset, measured once in `init` and used for the whole
/// frame. In the frame arena, so a row holds as many panes as the user opens.
///
/// A snapshot rather than a fresh read per pane, because a drag rewrites *every* pane's share
/// (that is what pushing a collapsed neighbour means) and the panes before the boundary have
/// already been laid out by then. Reading the store per pane would apply half the new row this
/// frame and half the next, which shows up as the far panes jumping ahead of the near ones.
w: []f32 = &.{},
off: []f32 = &.{},
/// Whether one of this row's boundaries is being dragged right now. Callers that reflow their
/// content while the row is still — the workbench re-centres a document when the panel moves —
/// need to leave it alone mid-drag.
dragging: bool = false,

/// Open the row. `ids` is one stable id per pane, in the order they are drawn.
pub fn init(
    src: std.builtin.SourceLocation,
    axis: dvui.enums.Direction,
    ids: []const dvui.Id,
) Panes {
    var self: Panes = .{
        .axis = axis,
        .ids = ids,
        .box = dvui.box(src, .{ .dir = axis }, .{ .expand = .both, .background = false }),
    };

    const content = self.box.data().contentRect();
    const room = switch (axis) {
        .horizontal => content.w,
        .vertical => content.h,
    };
    const dividers: f32 = if (ids.len > 1) @floatFromInt(ids.len - 1) else 0;
    self.available = @max(0, room - Split.handle_size * dividers);

    // Seed any pane that has never been sized. A new pane takes an **equal** share, which is
    // what "open to the side" means once shares are the unit: two panes are half each, three are
    // a third each, and the user drags from there.
    var known: f32 = 0;
    var known_count: f32 = 0;
    for (ids) |id| {
        if (dvui.dataGet(null, id, share_key, f32)) |s| {
            known += s;
            known_count += 1;
        }
    }
    for (ids) |id| {
        if (dvui.dataGet(null, id, share_key, f32) != null) continue;
        const share = if (known_count > 0) known / known_count else 1;
        dvui.dataSet(null, id, share_key, share);
        // Arriving beside something: start at nothing and slide out. Arriving into an empty row
        // there is nothing to slide against, and a lone pane fading in from zero width just
        // looks like the app is slow to start.
        if (known_count > 0) {
            dvui.dataSet(null, id, shown_key, @as(f32, 0));
            dvui.refresh(null, @src(), id);
        }
    }

    const arena = dvui.currentWindow().arena();
    self.w = arena.alloc(f32, ids.len) catch |err| {
        // An empty snapshot is a row of equal panes that cannot be dragged: the layout still
        // draws, which is the right failure for a frame allocation nobody can do anything about.
        dvui.logError(@src(), err, "pane row of {d}", .{ids.len});
        return self;
    };
    self.off = arena.alloc(f32, ids.len) catch |err| {
        dvui.logError(@src(), err, "pane row of {d}", .{ids.len});
        self.w = &.{};
        return self;
    };

    for (ids, 0..) |id, i| {
        const target = dvui.dataGet(null, id, share_key, f32) orelse 1;
        self.w[i] = Split.easedKey(id, target, anim_key, shown_key);
        self.total += self.w[i];
    }
    var x: f32 = 0;
    for (ids, 0..) |_, i| {
        self.w[i] = if (self.total > 0)
            self.available * self.w[i] / self.total
        else
            self.available / @as(f32, @floatFromInt(ids.len));
        // Pane 0 starts at the row's edge; every pane after it is preceded by its divider.
        if (i > 0) x += Split.handle_size;
        self.off[i] = x;
        x += self.w[i];
    }
    return self;
}

pub fn deinit(self: *Panes) void {
    self.box.deinit();
}

/// The drawn extent of pane `i` along the axis, in points.
pub fn extent(self: *Panes, i: usize) f32 {
    if (i >= self.w.len) return self.available / @as(f32, @floatFromInt(@max(1, self.ids.len)));
    return self.w[i];
}

/// Where pane `i` and the divider before it sit, in the row's own coordinates. Explicit because
/// the row places its children itself — see `pane`.
fn slot(self: *Panes, i: usize, size: f32) dvui.Rect {
    const at = if (i < self.off.len) self.off[i] else 0;
    return switch (self.axis) {
        .horizontal => .{ .x = at, .w = size },
        .vertical => .{ .y = at, .h = size },
    };
}

/// One open pane: the box to draw into, and the clip it replaced.
pub const Pane = struct {
    box: *dvui.BoxWidget,
    prev_clip: dvui.Rect.Physical,

    pub fn data(self: *const Pane) *dvui.WidgetData {
        return self.box.data();
    }

    pub fn deinit(self: *Pane) void {
        self.box.deinit();
        dvui.clipSet(self.prev_clip);
    }
};

/// Open pane `i`, placed at its share of the row. `deinit` it before the next divider.
///
/// **Placed, not asked for.** The obvious way to size a pane is `min_size_content`, and it is
/// wrong here: dvui's `minSize` returns the *larger* of what a widget asks for and what it
/// reported last frame (a label that grows has to be able to say so), so a pane that shrinks
/// keeps last frame's width for one frame. In a packed row that pushes everything after it along
/// and the last pane absorbs the difference — so dragging one boundary tugged at a boundary two
/// panes away, a frame behind, which is exactly as bad as it sounds.
///
/// The row already knows every offset, so it hands each child a rect instead and no negotiation
/// happens at all: no stale floor, no packing, no pane absorbing anyone else's error. The
/// `max_size_content` stays to keep the pane from *reporting* its content's width upward, which
/// is what would otherwise make the row demand more room than it has.
///
/// **And a pane clips what it holds**, exactly as a region does. Placing the pane exactly only
/// fixes the pane: its *content* still has that stale minimum a frame behind, so a shrinking pane
/// spills its content over its own trailing edge and paints across the handle — which looks like
/// the boundary itself lurching about, and is even more obviously wrong when a pane is collapsed
/// to nothing and still drawing.
pub fn pane(self: *Panes, src: std.builtin.SourceLocation, i: usize) Pane {
    const size = self.extent(i);
    const box = dvui.box(src, .{ .dir = .vertical }, .{
        .id_extra = i,
        .rect = self.slot(i, size),
        .expand = switch (self.axis) {
            .horizontal => .vertical,
            .vertical => .horizontal,
        },
        .background = false,
        .max_size_content = switch (self.axis) {
            .horizontal => .width(size),
            .vertical => .height(size),
        },
    });
    return .{ .box = box, .prev_clip = dvui.clip(box.data().contentRectScale().r) };
}

/// The draggable boundary before pane `i`. A no-op for `i == 0`, so a caller's loop can call it
/// unconditionally.
pub fn divider(self: *Panes, src: std.builtin.SourceLocation, i: usize) void {
    if (i == 0 or i >= self.ids.len) return;

    // In the gap the offsets left for it, for the same reason the panes are placed: a handle that
    // packs sits wherever the pane before it ended up, which during a drag is a frame stale.
    var at = self.slot(i, Split.handle_size);
    switch (self.axis) {
        .horizontal => at.x -= Split.handle_size,
        .vertical => at.y -= Split.handle_size,
    }
    var split = Split.init(src, self.axis, i, at);
    defer split.deinit();

    const grabbed = split.grab(self.box);
    if (dvui.captured(split.box.data().id)) self.dragging = true;
    if (grabbed.to) |p| {
        self.dragTo(i, p, grabbed.scale);
        dvui.refresh(null, @src(), split.box.data().id);
    }

    split.draw(grabbed.dist);
}

/// Put the boundary before pane `i` where the pointer is, and let the rest of the row give way.
///
/// **The boundary is absolute**: its distance from the row's own leading edge, which does not
/// move during a drag. Not a delta, and not a position inside the pair it divides — measuring
/// from an edge that is itself being pushed is what made a drag windup, stall and then jump.
///
/// From that one number the whole row follows, and it is the same rule on both sides of the
/// boundary: **the pane touching it absorbs the change, and what it cannot absorb cascades
/// outward.** Dragging a boundary toward its neighbour shrinks that neighbour, and when the
/// neighbour is shut the drag keeps going and shuts the one past it — so pushing right collapses
/// pane after pane and stacks their handles at the edge, and dragging back out hands the room
/// back nearest-first. Nothing has a floor, so "as far as it will go" means gone.
///
/// The panes further out keep their widths while they can, which is the part that makes this feel
/// local: touching one boundary must not redistribute the whole row.
fn dragTo(self: *Panes, i: usize, p: f32, s: f32) void {
    const n = self.ids.len;
    if (self.available <= 0 or n < 2) return;

    const rs = self.box.data().contentRectScale();
    const origin = switch (self.axis) {
        .horizontal => rs.r.x,
        .vertical => rs.r.y,
    };
    // Everything left of this boundary: the panes before it plus the dividers before it. The
    // pointer is on the divider's centre line, so half a handle comes off too.
    const handles_before = Split.handle_size * @as(f32, @floatFromInt(i - 1));
    const want = std.math.clamp(
        (p - origin) / s - handles_before - Split.handle_size / 2,
        0,
        self.available,
    );

    var w = self.w;

    // Before the boundary. `w[i - 1]` takes up the slack; if the boundary has gone past where
    // pane i-1 even starts, that pane is shut and the deficit walks leftward.
    var before: f32 = 0;
    for (w[0 .. i - 1]) |x| before += x;
    if (want >= before) {
        w[i - 1] = want - before;
    } else {
        w[i - 1] = 0;
        var deficit = before - want;
        var k = i - 1;
        while (k > 0 and deficit > 0) {
            k -= 1;
            const give = @min(w[k], deficit);
            w[k] -= give;
            deficit -= give;
        }
    }

    // After it, mirrored.
    var after: f32 = 0;
    for (w[i + 1 .. n]) |x| after += x;
    const room = self.available - want;
    if (room >= after) {
        w[i] = room - after;
    } else {
        w[i] = 0;
        var deficit = after - room;
        var k = i + 1;
        while (k < n and deficit > 0) : (k += 1) {
            const give = @min(w[k], deficit);
            w[k] -= give;
            deficit -= give;
        }
    }

    // Widths back to shares. The row's total share is preserved (the widths still sum to
    // `available`), so nothing outside this row has to know a drag happened — and the next frame
    // reads the same numbers whatever the window does in between.
    const scale = self.total / self.available;
    for (self.ids, 0..) |id, k| setShare(id, w[k] * scale);
}

/// Write a share and keep the drawn one with it: a boundary belongs under the pointer, not on a
/// curve behind it. Same exemption a dragged split gets, and for the same reason.
///
/// Deliberately not applied to `self.w` — this frame is already half laid out, and a row that
/// changed width mid-frame would show the far panes one frame ahead of the near ones.
fn setShare(id: dvui.Id, share: f32) void {
    dvui.dataSet(null, id, share_key, share);
    dvui.dataSet(null, id, shown_key, share);
}

// ── Tests ───────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Three panes in a row, the shape a document area with two splits has.
var t_ids: [3]dvui.Id = .{ @enumFromInt(0x51), @enumFromInt(0x52), @enumFromInt(0x53) };
var t_count: usize = 3;
var t_extents: [3]f32 = @splat(0);
var t_divider_x: [3]f32 = @splat(0);

fn paneRowFrame() !dvui.App.Result {
    var row = Panes.init(@src(), .horizontal, t_ids[0..t_count]);
    defer row.deinit();

    for (0..t_count) |i| {
        if (i > 0) {
            var split = Split.init(@src(), .horizontal, i, null);
            t_divider_x[i] = split.box.data().borderRectScale().r.x + split.box.data().borderRectScale().r.w / 2;
            split.deinit();
        }
        var p = row.pane(@src(), i);
        defer p.deinit();
        t_extents[i] = row.extent(i);
    }
    return .ok;
}

/// The same row with real dividers, so a drag can be posted at one.
fn draggableRowFrame() !dvui.App.Result {
    var row = Panes.init(@src(), .horizontal, t_ids[0..t_count]);
    defer row.deinit();

    for (0..t_count) |i| {
        row.divider(@src(), i);
        var p = row.pane(@src(), i);
        defer p.deinit();
        t_extents[i] = row.extent(i);
        // The pane's *drawn* width, not the one it was given: the two differing is the bug the
        // explicit placement in `pane` exists to prevent.
        t_drawn[i] = p.data().borderRectScale().r.w / p.data().borderRectScale().s;
        t_clip[i] = dvui.clipGet();
        if (i > 0) t_divider_x[i] = p.data().borderRectScale().r.x - Split.handle_size / 2 * p.data().borderRectScale().s;
    }
    t_clip_after = dvui.clipGet();
    return .ok;
}

var t_drawn: [3]f32 = @splat(0);
var t_clip: [3]dvui.Rect.Physical = @splat(.{});
var t_clip_after: dvui.Rect.Physical = .{};

fn clearShares() void {
    for (t_ids) |id| {
        dvui.dataRemove(null, id, share_key);
        dvui.dataRemove(null, id, shown_key);
    }
}

test "panes with no history divide the row evenly" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 300 } });
    defer t.deinit();
    clearShares();

    try dvui.testing.settle(paneRowFrame);

    // 600 wide less two dividers, in thirds.
    const expect = (600 - Split.handle_size * 2) / 3;
    for (t_extents) |e| try testing.expectApproxEqAbs(expect, e, 1.0);
}

test "a pane's width is its share of whatever room there is" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 300 } });
    defer t.deinit();
    clearShares();
    try dvui.testing.settle(paneRowFrame);

    // Double the first pane's share and it is twice its neighbours, exactly. This is also what
    // makes a window resize proportional and free: a width is a pure function of share and room,
    // so there is no stored number for a resize to invalidate and nothing to reconcile.
    dvui.dataSet(null, t_ids[0], share_key, @as(f32, 2));
    dvui.dataSet(null, t_ids[0], shown_key, @as(f32, 2));
    try dvui.testing.settle(paneRowFrame);

    const room = 600 - Split.handle_size * 2;
    try testing.expectApproxEqAbs(room / 2, t_extents[0], 1.0);
    try testing.expectApproxEqAbs(room / 4, t_extents[1], 1.0);
    try testing.expectApproxEqAbs(room / 4, t_extents[2], 1.0);
}

/// Press on the divider before pane `i` and hold. Leaves the drag live.
fn grabDivider(i: usize) !void {
    const cw = dvui.currentWindow();
    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = t_divider_x[i], .y = 150 } });
    _ = try dvui.testing.step(draggableRowFrame);
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(draggableRowFrame);
}

/// Drag the held boundary to `x` (physical) over several frames, the way a real drag arrives.
fn dragToX(x: f32) !void {
    const cw = dvui.currentWindow();
    for (0..4) |_| {
        _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = x, .y = 150 } });
        _ = try dvui.testing.step(draggableRowFrame);
    }
}

fn release() !void {
    _ = try dvui.currentWindow().addEventMouseButton(.left, .release);
    try dvui.testing.settle(draggableRowFrame);
}

test "dragging one boundary leaves the next one exactly where it was, every frame" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 300 } });
    defer t.deinit();
    clearShares();
    try dvui.testing.settle(draggableRowFrame);

    const start = t_divider_x[1];
    const pinned = t_divider_x[2];
    const third = t_extents[2];

    // Frame by frame, because the failure this guards against was one frame deep: sizing a pane
    // with `min_size_content` means dvui hands it `max(asked, last frame's)`, so a shrinking pane
    // stays wide for a frame, the packed row runs off its end and the *last* pane makes up the
    // difference. Dragging the first boundary visibly tugged the second one along with it.
    try grabDivider(1);
    const cw = dvui.currentWindow();
    var off: f32 = 0;
    for (0..8) |_| {
        off += 20;
        _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = start - off, .y = 150 } });
        _ = try dvui.testing.step(draggableRowFrame);

        try testing.expectApproxEqAbs(pinned, t_divider_x[2], 0.5);
        try testing.expectApproxEqAbs(third, t_extents[2], 0.5);
        // And every pane is drawn at the width it was given, which is the same statement from
        // the other side.
        for (0..t_count) |i| try testing.expectApproxEqAbs(t_extents[i], t_drawn[i], 0.5);
    }
    try release();
}

/// A row of arbitrarily many panes, for the tests that care about the count rather than the drag.
const BigRow = struct {
    var ids: [256]dvui.Id = undefined;
    var all: []dvui.Id = &.{};
    var last_end: f32 = 0;
    var smallest: f32 = 0;

    fn use(n: usize) void {
        for (&ids, 0..) |*id, i| id.* = @enumFromInt(0x9000 + i);
        for (ids) |id| {
            dvui.dataRemove(null, id, share_key);
            dvui.dataRemove(null, id, shown_key);
        }
        all = ids[0..n];
    }

    fn frame() !dvui.App.Result {
        var row = Panes.init(@src(), .horizontal, all);
        defer row.deinit();
        smallest = std.math.floatMax(f32);
        for (0..all.len) |i| {
            row.divider(@src(), i);
            var p = row.pane(@src(), i);
            defer p.deinit();
            const rs = p.data().borderRectScale();
            last_end = (rs.r.x + rs.r.w) / rs.s;
            smallest = @min(smallest, row.extent(i));
        }
        return .ok;
    }
};

test "a pane clips what it holds, and gives the clip back" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 300 } });
    defer t.deinit();
    clearShares();

    const outer = dvui.Rect.Physical{ .w = 1200, .h = 600 };
    try dvui.testing.settle(draggableRowFrame);

    // Placing the pane exactly is not enough on its own: its *content* still carries dvui's
    // minimum from last frame, so a shrinking pane would spill over its own trailing edge and
    // paint across the handle beside it. A collapsed pane would keep drawing at its old width
    // entirely outside itself.
    for (0..t_count) |i| {
        try testing.expectApproxEqAbs(t_extents[i], t_clip[i].w / 2, 0.5);
    }
    // And the handles are drawn after the pane before them, so the clip has to be handed back.
    try testing.expectEqual(outer.w, t_clip_after.w);
}

test "a row holds as many panes as it is given" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1200, .h = 300 } });
    defer t.deinit();

    // No cap, and no stack array behind one: "open to the side" must not quietly start doing
    // nothing at some arbitrary count. Forty panes is already a layout nobody wants, which is the
    // user's call to make and to undo by dragging.
    BigRow.use(40);
    try dvui.testing.settle(BigRow.frame);

    // The last pane ends where the row ends: the offsets accounted for all forty panes and all
    // thirty-nine handles, with nothing left over and nothing overrun.
    try testing.expectApproxEqAbs(@as(f32, 1200), BigRow.last_end, 1.0);
    try testing.expect(BigRow.smallest > 1);
}

test "a row of more handles than room gives every pane nothing, not less than nothing" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 300 } });
    defer t.deinit();

    // 256 handles need 2550pt and the row has 600, so there is no room for a pane at all. The
    // row still draws: the panes are nothing wide and the handles run off the end, which is the
    // shape of "unusable" — not a negative width, a division by zero or a refusal to lay out.
    BigRow.use(256);
    try dvui.testing.settle(BigRow.frame);

    try testing.expectEqual(@as(f32, 0), BigRow.smallest);
}

test "a boundary dragged a little takes from its neighbour and leaves the rest alone" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 300 } });
    defer t.deinit();
    clearShares();
    try dvui.testing.settle(draggableRowFrame);

    const before_first = t_extents[0];
    const grab = t_divider_x[2]; // the boundary between panes 1 and 2

    try grabDivider(2);
    try dragToX(grab - 80);
    try release();

    // Pane 1 gave up what pane 2 took...
    try testing.expect(t_extents[1] < t_extents[2]);
    // ...and pane 0 did not move. Touching one boundary must not redistribute the whole row,
    // which is the failure the points model had (its one flexible pane absorbed everything).
    try testing.expectApproxEqAbs(before_first, t_extents[0], 2.0);
}

test "dragging a boundary to the end shuts its neighbour, then the pane past it" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 300 } });
    defer t.deinit();
    clearShares();
    try dvui.testing.settle(draggableRowFrame);

    // The first boundary, pushed to the far edge. Pane 1 runs out of room first and the drag
    // keeps going into pane 2 — "push the second split until it collapses, then the first
    // collapses onto it, leaving the handles stacked at the edge".
    try grabDivider(1);
    try dragToX(4000);
    try release();

    try testing.expectApproxEqAbs(@as(f32, 0), t_extents[1], 0.5);
    try testing.expectApproxEqAbs(@as(f32, 0), t_extents[2], 0.5);
    try testing.expectApproxEqAbs(600 - Split.handle_size * 2, t_extents[0], 1.0);
}

test "a pane collapses all the way, and dragging back out restores it" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 300 } });
    defer t.deinit();
    clearShares();
    try dvui.testing.settle(draggableRowFrame);

    const room = 600 - Split.handle_size * 2;

    // Nothing has a floor: the first pane goes to nothing, like any other split in the app.
    try grabDivider(1);
    try dragToX(-2000);
    try release();
    try testing.expectApproxEqAbs(@as(f32, 0), t_extents[0], 0.5);
    // The room went to the pane that touches the boundary, not to the whole row.
    try testing.expectApproxEqAbs(room * 2 / 3, t_extents[1], 2.0);
    try testing.expectApproxEqAbs(room / 3, t_extents[2], 2.0);

    // ...and the handle is still there to drag back out, which is the only way back. The drag is
    // posted in physical pixels, so 200 points of travel is 200 * scale.
    const s = dvui.windowNaturalScale();
    try grabDivider(1);
    try dragToX(t_divider_x[1] + 200 * s);
    try release();
    try testing.expectApproxEqAbs(@as(f32, 200), t_extents[0], 6.0);
    // What pane 0 took came back out of its neighbour, nearest-first, and pane 2 kept its third.
    try testing.expectApproxEqAbs(room / 3, t_extents[2], 2.0);
}

test "a pane that appears beside others slides out from nothing" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 300 } });
    defer t.deinit();
    clearShares();

    t_count = 2;
    try dvui.testing.settle(paneRowFrame);
    const settled = t_extents[1];

    // A document opened to the side: the row grows a pane it has never seen.
    t_count = 3;
    defer t_count = 3;
    _ = try dvui.testing.step(paneRowFrame);
    try testing.expectApproxEqAbs(@as(f32, 0), t_extents[2], 0.001);

    // ...and ends up sharing the row equally, without the panes already there jumping.
    try dvui.testing.settle(paneRowFrame);
    try testing.expect(t_extents[2] > settled / 2);
    try testing.expectApproxEqAbs(t_extents[1], t_extents[2], 2.0);
}

test {
    testing.refAllDecls(@This());
}
