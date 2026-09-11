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
//! A share makes a drag local. Dragging the boundary between two panes moves **only** those two:
//! their shares trade, their sum is preserved, so every other pane is untouched by construction
//! and there is no global budget to run out of. A minimum can pin the pair without pinning the
//! row.
//!
//! ```zig
//! var ids: [8]dvui.Id = undefined;
//! for (groups, 0..) |g, i| ids[i] = paneId(g);
//!
//! var panes = core.widgets.panes(@src(), .horizontal, ids[0..groups.len], .{});
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
const anim = @import("../anim.zig");
const Split = @import("Split.zig");

const Panes = @This();

/// Shares live under the pane's own id, beside the extents a `Split` would have written there.
const share_key = "_share";
const shown_key = "_share_shown";
const anim_key = "_share_ease";

pub const Options = struct {
    /// The smallest a pane may be dragged to, in points. Unlike a region's minimum this is a
    /// property of the *row* — every pane in a row of documents is as squeezable as any other.
    min: f32 = 80,
};

axis: dvui.enums.Direction,
opts: Options,
/// The row. Opened by `init` so the panes and the dividers are its children and nothing else is.
box: *dvui.BoxWidget,
ids: []const dvui.Id,
/// Room for the panes themselves: the row's extent less what the dividers take.
available: f32 = 0,
/// Sum of the *shown* shares, which is what a width is a fraction of. Tracked rather than
/// recomputed per pane so a pane sliding in (shown share travelling up from zero) narrows its
/// neighbours smoothly instead of overflowing the row.
total: f32 = 0,
/// Whether one of this row's boundaries is being dragged right now. Callers that reflow their
/// content while the row is still — the workbench re-centres a document when the panel moves —
/// need to leave it alone mid-drag.
dragging: bool = false,

/// Open the row. `ids` is one stable id per pane, in the order they are drawn.
pub fn init(
    src: std.builtin.SourceLocation,
    axis: dvui.enums.Direction,
    ids: []const dvui.Id,
    opts: Options,
) Panes {
    var self: Panes = .{
        .axis = axis,
        .opts = opts,
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

    for (ids) |id| {
        const target = dvui.dataGet(null, id, share_key, f32) orelse 1;
        self.total += Split.easedKey(id, target, anim_key, shown_key);
    }
    return self;
}

pub fn deinit(self: *Panes) void {
    self.box.deinit();
}

/// The drawn extent of pane `i` along the axis, in points.
pub fn extent(self: *Panes, i: usize) f32 {
    if (self.total <= 0) return self.available;
    const shown = dvui.dataGet(null, self.ids[i], shown_key, f32) orelse 0;
    return self.available * shown / self.total;
}

/// Open pane `i`: a box pinned to its share of the row. `deinit` it before the next divider.
///
/// Pinned at both ends, like a resizable region: a minimum alone is a floor, so a pane whose
/// content wants to be wider than its share simply stays wider and the boundary appears to stop
/// responding. The pane clips, so nothing escapes; it just stops pushing back.
pub fn pane(self: *Panes, src: std.builtin.SourceLocation, i: usize) *dvui.BoxWidget {
    const size = self.extent(i);
    const box = dvui.box(src, .{ .dir = .vertical }, .{
        .id_extra = i,
        .expand = switch (self.axis) {
            .horizontal => .vertical,
            .vertical => .horizontal,
        },
        .background = false,
        .min_size_content = switch (self.axis) {
            .horizontal => .{ .w = size },
            .vertical => .{ .h = size },
        },
        .max_size_content = switch (self.axis) {
            .horizontal => .width(size),
            .vertical => .height(size),
        },
    });
    // The pair's outer edges, which is what a drag measures from. They do not move while the
    // boundary between them does, so the arithmetic is absolute and nothing winds up.
    Split.recordEdges(self.ids[i], box.data(), self.axis);
    return box;
}

/// The draggable boundary before pane `i`. A no-op for `i == 0`, so a caller's loop can call it
/// unconditionally.
///
/// The drag trades share between panes `i - 1` and `i` and touches nothing else. Their combined
/// width is fixed by the other panes, so the pointer picks a point inside a span whose ends are
/// known — the arithmetic is a division of one number, not a negotiation with the row.
pub fn divider(self: *Panes, src: std.builtin.SourceLocation, i: usize) void {
    if (i == 0 or i >= self.ids.len) return;
    const before = self.ids[i - 1];
    const after = self.ids[i];

    var split = Split.init(src, self.axis, i);
    defer split.deinit();

    const grabbed = split.grab(self.box);
    if (dvui.captured(split.box.data().id)) self.dragging = true;
    if (grabbed.to) |p| {
        // The span the pair occupies, from the far edge of the pane before to the far edge of the
        // pane after. Both are last frame's, and both are still where they were: only the
        // boundary inside them is moving.
        const org = dvui.dataGet(null, before, "_org", f32);
        const end = dvui.dataGet(null, after, "_end", f32);
        if (org != null and end != null) {
            const s = grabbed.scale;
            const span = (end.? - org.?) / s - Split.handle_size;
            const want = (p - org.?) / s - Split.handle_size / 2;
            if (span > self.opts.min * 2) {
                const left = std.math.clamp(want, self.opts.min, span - self.opts.min);
                const pair = (dvui.dataGet(null, before, share_key, f32) orelse 1) +
                    (dvui.dataGet(null, after, share_key, f32) orelse 1);
                const share = pair * left / span;
                setShare(before, share);
                setShare(after, pair - share);
                dvui.refresh(null, @src(), split.box.data().id);
            }
        }
    }

    split.draw(grabbed.dist);
}

/// Write a share and keep the drawn one with it: a boundary belongs under the pointer, not on a
/// curve behind it. Same exemption a dragged split gets, and for the same reason.
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
    var row = Panes.init(@src(), .horizontal, t_ids[0..t_count], .{ .min = 40 });
    defer row.deinit();

    for (0..t_count) |i| {
        if (i > 0) {
            var split = Split.init(@src(), .horizontal, i);
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
    var row = Panes.init(@src(), .horizontal, t_ids[0..t_count], .{ .min = 40 });
    defer row.deinit();

    for (0..t_count) |i| {
        row.divider(@src(), i);
        var p = row.pane(@src(), i);
        defer p.deinit();
        t_extents[i] = row.extent(i);
        if (i > 0) t_divider_x[i] = p.data().borderRectScale().r.x - Split.handle_size / 2 * p.data().borderRectScale().s;
    }
    return .ok;
}

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

test "dragging a boundary moves only the two panes it divides" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 300 } });
    defer t.deinit();
    clearShares();
    try dvui.testing.settle(draggableRowFrame);

    const before_first = t_extents[0];
    const grab = t_divider_x[2]; // the boundary between panes 1 and 2
    const cw = dvui.currentWindow();

    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = grab, .y = 150 } });
    _ = try dvui.testing.step(draggableRowFrame);
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(draggableRowFrame);

    var moved: f32 = 0;
    for (0..4) |_| {
        moved += 20;
        _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = grab - moved, .y = 150 } });
        _ = try dvui.testing.step(draggableRowFrame);
    }
    _ = try cw.addEventMouseButton(.left, .release);
    try dvui.testing.settle(draggableRowFrame);

    // Pane 1 gave up what pane 2 took...
    try testing.expect(t_extents[1] < t_extents[2]);
    // ...and pane 0 — which under the points model would have absorbed all of it — did not move.
    // This is the whole reason shares exist here.
    try testing.expectApproxEqAbs(before_first, t_extents[0], 2.0);
}

test "a boundary cannot squeeze either of its panes away" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 300 } });
    defer t.deinit();
    clearShares();
    try dvui.testing.settle(draggableRowFrame);

    const grab = t_divider_x[1];
    const cw = dvui.currentWindow();

    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = grab, .y = 150 } });
    _ = try dvui.testing.step(draggableRowFrame);
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(draggableRowFrame);
    for (0..6) |_| {
        _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = -2000, .y = 150 } });
        _ = try dvui.testing.step(draggableRowFrame);
    }
    _ = try cw.addEventMouseButton(.left, .release);
    try dvui.testing.settle(draggableRowFrame);

    // The minimum pins the pair, not the row: pane 0 is at its floor and pane 2 never moved.
    try testing.expect(t_extents[0] >= 30);
    try testing.expect(t_extents[2] > 100);
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
