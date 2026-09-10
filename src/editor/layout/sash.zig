//! The **sash**: the interactive half of a `split`.
//!
//! Lives apart from `Frame` so it can be tested against dvui's testing backend without an
//! `Editor` — this path has been wrong twice in ways no amount of reading caught (a drag that
//! took capture and then froze; a handle that filled its whole strip), and both were dvui
//! event-routing rules rather than layout logic. It depends on nothing but dvui.
const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");

/// Thickness of a sash, and how near the pointer must be before it shows itself. Fizzy's tuned
/// values: a thinner target is measurably harder to grab.
pub const handle_size: f32 = 10;
pub const handle_dist: f32 = 60;

/// What the container knows that a single sash does not: how much room there is, how much of it
/// the base region insists on keeping, and which other regions can give way.
///
/// This is why a sash *requests* an extent rather than setting one. With a left and a right tray
/// over one centre, dragging the left one past the point where the centre is at its minimum has
/// to push the right one out of the way — an answer no region owns on its own. The container
/// arbitrates; the regions stop owning their sizes independently.
pub const Constraint = struct {
    /// The container's length along the axis.
    length: f32 = 0,
    /// The base region's declared minimum — `min_size_content` on the region that is not
    /// resizable. Declared by the app, never inferred from a plugin's content, or the plugin
    /// would be setting the app's proportions.
    base_min: f32 = 0,
    /// Total length the sashes themselves take.
    handles: f32 = 0,
    /// The other resizable regions in this container, which yield once the base is at its
    /// minimum and the drag still wants more.
    others: []const dvui.Id = &.{},
};

/// Resolve a requested extent for `target` against the container's constraint, pushing the other
/// trays back if that is the only way to honour it.
///
/// Returns the extent `target` should take. Anything the others had to give up has already been
/// written to them.
pub fn resolve(target: dvui.Id, want: f32, c: Constraint, opts: Options) f32 {
    // `std.math.clamp` asserts `lower <= upper`, so an explicit `max` below `min` would panic
    // inside the clamp rather than reaching any guard after it.
    const limit = @max(opts.min, opts.max orelse (c.length - handle_size));
    var size = std.math.clamp(want, opts.min, limit);
    if (c.length <= 0) return size;

    // What the trays may occupy between them once the base has kept its minimum. Never negative:
    // a container too small for the base alone leaves the trays nothing rather than a negative
    // budget that would read as unlimited room.
    const room = @max(0, c.length - c.base_min - c.handles);

    var others: f32 = 0;
    for (c.others) |o| {
        if (o == target) continue;
        others += dvui.dataGet(null, o, "_size", f32) orelse 0;
    }

    if (size + others <= room) return size;

    // Over budget. Constraints are resolved in a fixed order so a conflict has one answer rather
    // than depending on which sash the user happens to be dragging:
    //
    //   1. The other trays give way, nearest the budget first — "push the far sidebar out of the
    //      way", the behaviour the whole mechanism exists for.
    //   2. If they are all shut and it still does not fit, the dragged tray stops.
    //   3. If even that is not enough — every tray at a declared minimum, and the container
    //      still too small — the **base** is squeezed below `base_min`. It yields last because
    //      it is the region with somewhere to go: it can scroll or clip, and a tray pinned to a
    //      minimum by the app cannot.
    //
    // Nothing here can produce a negative extent, which is the failure that would otherwise turn
    // a conflict into a layout that inverts.
    var excess = size + others - room;
    for (c.others) |o| {
        if (o == target or excess <= 0) continue;
        const had = dvui.dataGet(null, o, "_size", f32) orelse 0;
        const give = @min(had, excess);
        if (give > 0) dvui.dataSet(null, o, "_size", had - give);
        excess -= give;
    }
    if (excess > 0) size = @max(opts.min, size - excess);
    return @max(0, size);
}

pub const Options = struct {
    /// False draws the gap but does not let the user move it.
    resize: bool = true,
    /// Smallest extent the dragged neighbour may be squeezed to. Zero by default, so a sash can
    /// be dragged fully closed — a region you cannot shut is a region the user has to fight.
    min: f32 = 0,
    /// Largest, or null to allow the full length of the container minus the sash itself, so a
    /// region can be dragged fully open. A number here is a deliberate cap, not a default.
    max: ?f32 = null,
};

/// The handle itself: takes `handle_size` along the container's axis and stretches across it, so
/// `dvui.box` reserves the gap the way it reserves any other child.
pub fn handle(src: std.builtin.SourceLocation, axis: dvui.enums.Direction) *dvui.BoxWidget {
    return dvui.box(src, .{ .dir = axis }, .{
        .min_size_content = switch (axis) {
            .horizontal => .{ .w = handle_size },
            .vertical => .{ .h = handle_size },
        },
        .expand = switch (axis) {
            .horizontal => .vertical,
            .vertical => .horizontal,
        },
        .background = false,
    });
}

/// A region's persisted extent along its parent's axis, in points.
pub fn storedSize(id: dvui.Id, default: f32) f32 {
    return dvui.dataGet(null, id, "_size", f32) orelse default;
}

/// Record where a resizable region's edges are, so a sash can size it from a fixed anchor
/// instead of correcting itself frame to frame.
///
/// The anchor is the edge the region does **not** grow from: the far edge of a region before the
/// sash, or the near edge of one after it. Neither moves while dragging, which is what makes the
/// arithmetic absolute.
pub fn recordEdges(id: dvui.Id, wd: *dvui.WidgetData, axis: dvui.enums.Direction) void {
    const r = wd.borderRectScale().r;
    switch (axis) {
        .horizontal => {
            dvui.dataSet(null, id, "_org", r.x);
            dvui.dataSet(null, id, "_end", r.x + r.w);
        },
        .vertical => {
            dvui.dataSet(null, id, "_org", r.y);
            dvui.dataSet(null, id, "_end", r.y + r.h);
        },
    }
}

/// Drag `target`'s stored extent, and draw the sash. `sign` is +1 when the target is the region
/// *before* the sash and -1 when it is the one after, so dragging always moves the edge the way
/// the pointer goes.
pub fn interact(
    container: *dvui.BoxWidget,
    sep: *dvui.BoxWidget,
    axis: dvui.enums.Direction,
    target: dvui.Id,
    sign: f32,
    opts: Options,
    c: Constraint,
) void {
    const wd = sep.data();
    const srs = wd.borderRectScale();
    const cursor: dvui.enums.Cursor = switch (axis) {
        .horizontal => .arrow_w_e,
        .vertical => .arrow_n_s,
    };

    // The centre line of the split, and how far the pointer is from it.
    const centre = switch (axis) {
        .horizontal => srs.r.x + srs.r.w / 2,
        .vertical => srs.r.y + srs.r.h / 2,
    };

    // Events are matched against the **container**, not this thin strip, so the sash can grow as
    // the pointer approaches rather than only reacting once it is already on top of a 10pt
    // target. `PanedWidget` does the same, and it is the difference between a sash that feels
    // findable and one that does not. Nothing is handled unless the pointer is actually close.
    //
    // **Except while we hold capture.** dvui's `eventMatch` refuses every widget that is not the
    // capture holder once a capture is live ("someone else has capture"), so continuing to match
    // on the container during a drag rejects the motion and release events too — the drag
    // freezes on the first pixel, capture is never given back, and the resize cursor sticks. So
    // once captured we match on ourselves, which the capture branch admits regardless of rect.
    var dist: f32 = std.math.floatMax(f32);
    // Where the pointer wants the sash, taken from the last motion of the frame and applied once
    // after the loop. Applying inside it would over-shoot: every motion event would be measured
    // against the same stale sash position.
    var drag_to: ?f32 = null;
    for (dvui.events()) |*e| {
        if (e.evt != .mouse) continue;

        const captured = dvui.captured(wd.id);
        if (captured) {
            if (!dvui.eventMatchSimple(e, wd)) continue;
            dist = 0;
        } else {
            const cbox = container;
            if (!dvui.eventMatchSimple(e, cbox.data())) continue;
            const p = switch (axis) {
                .horizontal => e.evt.mouse.p.x,
                .vertical => e.evt.mouse.p.y,
            };
            dist = @abs(p - centre) / srs.s;
            if (dist > handle_size) continue;
        }

        switch (e.evt.mouse.action) {
            .press => if (e.evt.mouse.button.pointer()) {
                e.handle(@src(), wd);
                dvui.captureMouse(wd, e.num);
                dvui.dragPreStart(e.evt.mouse.button, e.evt.mouse.p, .{ .cursor = cursor });
                // The extent at grab time, so the drag is measured from where it started
                // instead of accumulating rounding every frame.
                dvui.dataSet(null, wd.id, "_start", dvui.dataGet(null, target, "_size", f32) orelse currentExtent(target, axis));
            },
            .release => if (e.evt.mouse.button.pointer() and captured) {
                e.handle(@src(), wd);
                dvui.captureMouse(null, e.num);
                dvui.dragEnd();
            },
            .motion => if (captured) {
                e.handle(@src(), wd);
                if (dvui.dragging(e.evt.mouse.p, null) != null) {
                    drag_to = switch (axis) {
                        .horizontal => e.evt.mouse.p.x,
                        .vertical => e.evt.mouse.p.y,
                    };
                }
            },
            .position => dvui.cursorSet(cursor),
            else => {},
        }
    }

    // Drive the size from where the pointer is relative to the sash, not from an accumulated
    // delta.
    //
    // `dvui.dragging` returns the difference since the **previous call**, not since the press
    // (see `Dragging.get`), so adding it to a baseline captured at press time applies exactly one
    // frame of movement and then stops — the sash pops once and sits there. Summing it instead
    // would work but drifts, and drops any motion a frame misses.
    //
    // The sash is drawn wherever the stored size puts it, so moving the size by the pointer's
    // offset from the sash lands the sash under the pointer, and stays exact from then on with
    // nothing accumulated. `PanedWidget` drives its ratio from the absolute pointer position for
    // the same reason.
    if (drag_to) |p| {
        // Size from the region's fixed edge, not from a correction applied to the current size.
        //
        // A relative correction winds up: once the size clamps at a limit the pointer keeps
        // travelling past the sash, and dragging back has to walk off that overshoot before
        // anything moves — the sash sticks at the end of its range and then lags. Measuring from
        // an edge that does not move during the drag makes the size a pure function of where the
        // pointer is, so it leaves a limit the instant the pointer does.
        const current = dvui.dataGet(null, target, "_size", f32) orelse currentExtent(target, axis);
        const anchor = dvui.dataGet(null, target, if (sign > 0) "_org" else "_end", f32);
        const want = if (anchor) |a|
            (if (sign > 0) (p - a) else (a - p)) / srs.s - handle_size / 2
        else
            current + sign * (p - centre) / srs.s;

        dvui.dataSet(null, target, "_size", resolve(target, want, c, opts));
        dvui.refresh(null, @src(), wd.id);
    }

    if (dvui.captured(wd.id)) dist = 0;
    drawSash(wd, srs, axis, dist);
}

/// The sash itself: a short rounded bar across the middle of the gap with a grip on it, fading
/// in as the pointer approaches. Deliberately **not** a fill of the whole separator — the strip
/// spans the entire edge, and painting all of it reads as a solid divider rather than something
/// you can grab.
fn drawSash(wd: *dvui.WidgetData, srs: dvui.RectScale, axis: dvui.enums.Direction, dist: f32) void {
    if (dist > handle_size + handle_dist) return;

    var len_ratio: f32 = 1.0 / 5.0;
    len_ratio *= 1.0 - std.math.clamp((dist - handle_size) / handle_dist, 0.0, 1.0);
    if (len_ratio <= 0.001) return;

    const thick = handle_size * srs.s;
    var r = srs.r;
    switch (axis) {
        .horizontal => {
            r.x = srs.r.x + srs.r.w / 2 - thick / 2;
            r.w = thick;
            const h = srs.r.h * len_ratio;
            r.y = srs.r.y + srs.r.h / 2 - h / 2;
            r.h = h;
        },
        .vertical => {
            r.y = srs.r.y + srs.r.h / 2 - thick / 2;
            r.h = thick;
            const w = srs.r.w * len_ratio;
            r.x = srs.r.x + srs.r.w / 2 - w / 2;
            r.w = w;
        },
    }
    r.fill(.all(thick), .{ .color = wd.options.color(.text).opacity(0.5), .fade = 1.0 });

    // The grip, so the sash reads as something you grab rather than a bar that happens to be
    // there. Same icon and placement as `PanedWidget`, because these are the same affordance and
    // fizzy's sashes should not differ depending on which one drew them.
    const grip = switch (axis) {
        .horizontal => icons.tvg.lucide.@"grip-vertical",
        .vertical => icons.tvg.lucide.@"grip-horizontal",
    };
    var g = r;
    switch (axis) {
        .horizontal => {
            g.h = dvui.iconWidth("grip", grip, g.w) catch g.w;
            g.y = (srs.r.y + srs.r.h / 2) - g.h / 2;
        },
        .vertical => {
            g.w = dvui.iconWidth("grip", grip, g.h) catch g.h;
            g.x = (srs.r.x + srs.r.w / 2) - g.w / 2;
        },
    }
    g = g.outset(dvui.Rect.Physical.all(2 * srs.s));
    dvui.icon(@src(), "grip", grip, .{
        .stroke_color = dvui.themeGet().color(.content, .fill),
    }, .{ .rect = srs.rectFromPhysical(g) });
}

/// A resizable region's current extent, used as the starting point for the first drag before any
/// size has been stored.
fn currentExtent(target: dvui.Id, axis: dvui.enums.Direction) f32 {
    const r = dvui.minSizeGet(target) orelse return 0;
    return switch (axis) {
        .horizontal => r.w,
        .vertical => r.h,
    };
}


// ── Tests ───────────────────────────────────────────────────────────────────────────────────
//
// Against dvui's testing backend, because every bug this file has had was a dvui event-routing
// rule rather than arithmetic, and reading the code did not catch any of them.

const testing = std.testing;

var t_target: dvui.Id = undefined;
var t_size: f32 = 0;
var t_captured: bool = false;
var t_sep_x: f32 = 0;
var t_scale: f32 = 1;
var t_room: f32 = 0;
var t_min: f32 = 0;
/// The container in **physical** pixels — mouse events are posted in those, `contentRect` is in
/// points, and mixing them is a test that fails for a reason unrelated to the widget.
var t_room_px: f32 = 0;
var t_org_px: f32 = 0;

/// A horizontal container: a fixed-width region, a sash, and a stretchy one. The same shape as
/// a sidebar beside a main area.
fn twoPaneFrame() !dvui.App.Result {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer row.deinit();

    {
        const w = storedSize(t_target, 100);

        var left = dvui.box(@src(), .{ .dir = .vertical }, .{
            .min_size_content = .{ .w = w },
            .max_size_content = .width(w),
            .expand = .vertical,
        });
        defer left.deinit();
        t_target = left.data().id;
        dvui.dataSet(null, t_target, "_size", w);
        recordEdges(t_target, left.data(), .horizontal);
    }

    var sep = handle(@src(), .horizontal);
    {
        const srs = sep.data().borderRectScale();
        t_sep_x = srs.r.x + srs.r.w / 2;
        t_scale = srs.s;
        t_room = row.data().contentRect().w;
        t_room_px = row.data().borderRectScale().r.w;
        t_org_px = row.data().borderRectScale().r.x;
        interact(row, sep, .horizontal, t_target, 1, .{ .min = t_min }, .{ .length = row.data().contentRect().w });
        t_captured = dvui.captured(sep.data().id);
    }
    sep.deinit();

    {
        // A real minimum on the far side, which is what makes the open limit *unreachable*: the
        // stored size can be clamped to a value the layout cannot actually give, and then the
        // sash sits short of it. That gap is where windup lives, so a test frame without it
        // cannot show the bug.
        var right = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
            .min_size_content = .{ .w = 120 },
        });
        defer right.deinit();
    }

    t_size = storedSize(t_target, 100);
    return .ok;
}

test "dragging the sash resizes the region before it" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 300 } });
    defer t.deinit();

    try dvui.testing.settle(twoPaneFrame);
    const before = t_size;
    const grab = t_sep_x;

    const cw = dvui.currentWindow();
    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = grab, .y = 100 } });
    _ = try dvui.testing.step(twoPaneFrame);

    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(twoPaneFrame);
    try testing.expect(t_captured);

    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = grab + 80, .y = 100 } });
    _ = try dvui.testing.step(twoPaneFrame);

    // The regression: with capture held, matching events on the container makes dvui reject
    // every one of them ("someone else has capture"), so the drag freezes on the first pixel.
    try testing.expect(t_size > before);

    // ...and it must move *by the drag distance*, not merely increase. A baseline taken from
    // anything other than the region's current extent — its natural content minimum, say — makes
    // the first press jump the region to that width before applying the delta, which reads as
    // the sash popping to a different size the moment you grab it.
    try testing.expectApproxEqAbs(before + 80 / t_scale, t_size, 1.0);
}

test "the sash follows the pointer across a multi-step drag" {
    // The regression this exists for: `dvui.dragging` reports the delta since the *previous
    // call*, so a single-motion test cannot tell a cumulative baseline from an incremental one —
    // they agree on the first event and only diverge from the second. A real drag is many motion
    // events across many frames, and the buggy version moved on the first and then sat still.
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 300 } });
    defer t.deinit();

    try dvui.testing.settle(twoPaneFrame);
    const before = t_size;
    const grab = t_sep_x;
    const cw = dvui.currentWindow();

    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = grab, .y = 100 } });
    _ = try dvui.testing.step(twoPaneFrame);
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(twoPaneFrame);

    // Six frames of 20 physical pixels each, the way a real drag arrives.
    var moved: f32 = 0;
    for (0..6) |_| {
        moved += 20;
        _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = grab + moved, .y = 100 } });
        _ = try dvui.testing.step(twoPaneFrame);
    }
    _ = try cw.addEventMouseButton(.left, .release);
    _ = try dvui.testing.step(twoPaneFrame);

    try testing.expectApproxEqAbs(before + moved / t_scale, t_size, 2.0);
    // And the sash itself ends up under the pointer, which is what "follows the mouse" means.
    try testing.expectApproxEqAbs(grab + moved, t_sep_x, 4.0);
}

test "releasing gives capture back, so the cursor does not stick" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 300 } });
    defer t.deinit();

    try dvui.testing.settle(twoPaneFrame);
    const grab = t_sep_x;
    const cw = dvui.currentWindow();

    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = grab, .y = 100 } });
    _ = try dvui.testing.step(twoPaneFrame);
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(twoPaneFrame);
    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = grab + 40, .y = 100 } });
    _ = try dvui.testing.step(twoPaneFrame);
    _ = try cw.addEventMouseButton(.left, .release);
    _ = try dvui.testing.step(twoPaneFrame);

    try testing.expect(!t_captured);
}

test "a sash can be dragged fully closed and fully open" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 300 } });
    defer t.deinit();

    try dvui.testing.settle(twoPaneFrame);
    const cw = dvui.currentWindow();

    // All the way to the near edge: shut, not stopped short by a floor nobody asked for.
    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = t_sep_x, .y = 100 } });
    _ = try dvui.testing.step(twoPaneFrame);
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(twoPaneFrame);
    for (0..8) |_| {
        _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = -400, .y = 100 } });
        _ = try dvui.testing.step(twoPaneFrame);
    }
    try testing.expectApproxEqAbs(@as(f32, 0), t_size, 0.001);

    // ...and all the way to the far edge, which is the container's length less the sash.
    for (0..8) |_| {
        _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = 4000, .y = 100 } });
        _ = try dvui.testing.step(twoPaneFrame);
    }
    _ = try cw.addEventMouseButton(.left, .release);
    _ = try dvui.testing.step(twoPaneFrame);

    try testing.expect(t_size > 150);
    try testing.expectApproxEqAbs(t_room - handle_size, t_size, 2.0);
}

test "leaving a limit tracks the pointer immediately" {
    // The windup this exists for: with the size corrected frame to frame, overshooting a limit
    // banks up the distance the pointer travelled past the sash, and dragging back has to spend
    // it all again before anything moves. The sash appears stuck at the end of its range.
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 300 } });
    defer t.deinit();

    try dvui.testing.settle(twoPaneFrame);
    const cw = dvui.currentWindow();

    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = t_sep_x, .y = 100 } });
    _ = try dvui.testing.step(twoPaneFrame);
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(twoPaneFrame);

    // Far past the open limit, by a long way.
    for (0..6) |_| {
        _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = 4000, .y = 100 } });
        _ = try dvui.testing.step(twoPaneFrame);
    }
    const at_limit = t_size;

    // Now come back to a position well inside the range. One frame should put the sash there.
    const target_x = t_org_px + t_room_px * 0.4;
    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = target_x, .y = 100 } });
    _ = try dvui.testing.step(twoPaneFrame);

    // The size responds on this frame...
    try testing.expect(t_size < at_limit - 20);

    // ...and the sash is drawn there two frames later. That is dvui's normal settle, not the
    // windup this test is about: a box places its children from the min size they reported *last*
    // frame, so a size written during one frame reaches the layout on the next. During a real
    // drag the pointer is moving continuously, so this is a frame of trail, not a stall.
    _ = try dvui.testing.step(twoPaneFrame);
    _ = try dvui.testing.step(twoPaneFrame);
    try testing.expectApproxEqAbs(target_x, t_sep_x, 4.0);
}

test "a drag cannot squeeze the region below its minimum" {
    t_min = 20;
    defer t_min = 0;
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 300 } });
    defer t.deinit();

    try dvui.testing.settle(twoPaneFrame);
    const grab = t_sep_x;
    const cw = dvui.currentWindow();

    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = grab, .y = 100 } });
    _ = try dvui.testing.step(twoPaneFrame);
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(twoPaneFrame);
    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = grab - 5000, .y = 100 } });
    _ = try dvui.testing.step(twoPaneFrame);

    try testing.expect(t_size >= 20);
}

test "a far-away press is not a grab" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 300 } });
    defer t.deinit();

    try dvui.testing.settle(twoPaneFrame);
    const before = t_size;
    const cw = dvui.currentWindow();

    // Well clear of the sash: pressing here belongs to whatever is under it, not to the split.
    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = t_sep_x + 200, .y = 100 } });
    _ = try dvui.testing.step(twoPaneFrame);
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(twoPaneFrame);
    try testing.expect(!t_captured);
    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = t_sep_x + 280, .y = 100 } });
    _ = try dvui.testing.step(twoPaneFrame);

    try testing.expectApproxEqAbs(before, t_size, 0.001);
}

test {
    testing.refAllDecls(@This());
}

// ── Constraint resolution ───────────────────────────────────────────────────────────────────
//
// `resolve` is pure arithmetic over dvui's data store, so it tests directly without a drag.

fn setSize(id: dvui.Id, v: f32) void {
    dvui.dataSet(null, id, "_size", v);
}
fn getSize(id: dvui.Id) f32 {
    return dvui.dataGet(null, id, "_size", f32) orelse 0;
}

test "a tray takes what it asks for while there is room" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 300 } });
    defer t.deinit();
    _ = try dvui.testing.step(twoPaneFrame);

    const left: dvui.Id = @enumFromInt(0xA1);
    const right: dvui.Id = @enumFromInt(0xA2);
    setSize(left, 100);
    setSize(right, 100);

    const c: Constraint = .{ .length = 1000, .base_min = 400, .handles = 20, .others = &.{ left, right } };
    try testing.expectApproxEqAbs(@as(f32, 300), resolve(left, 300, c, .{}), 0.001);
    // The other tray is untouched: there was room for both.
    try testing.expectApproxEqAbs(@as(f32, 100), getSize(right), 0.001);
}

test "the far tray is pushed back once the base is at its minimum" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 300 } });
    defer t.deinit();
    _ = try dvui.testing.step(twoPaneFrame);

    const left: dvui.Id = @enumFromInt(0xB1);
    const right: dvui.Id = @enumFromInt(0xB2);
    setSize(left, 200);
    setSize(right, 200);

    // 1000 long, base keeps 400, sashes take 20 -> 580 for the trays. Asking for 500 on the left
    // leaves 80 for the right, so it has to give up 120.
    const c: Constraint = .{ .length = 1000, .base_min = 400, .handles = 20, .others = &.{ left, right } };
    try testing.expectApproxEqAbs(@as(f32, 500), resolve(left, 500, c, .{}), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 80), getSize(right), 0.001);
}

test "a tray that pushes everything shut then stops" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 300 } });
    defer t.deinit();
    _ = try dvui.testing.step(twoPaneFrame);

    const left: dvui.Id = @enumFromInt(0xC1);
    const right: dvui.Id = @enumFromInt(0xC2);
    setSize(left, 200);
    setSize(right, 200);

    const c: Constraint = .{ .length = 1000, .base_min = 400, .handles = 20, .others = &.{ left, right } };
    // Far more than the whole budget: the right shuts, and the left stops at what is left.
    const got = resolve(left, 5000, c, .{});
    try testing.expectApproxEqAbs(@as(f32, 0), getSize(right), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 580), got, 0.001);
}

test "conflicting minimums squeeze the base rather than inverting the layout" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 300 } });
    defer t.deinit();
    _ = try dvui.testing.step(twoPaneFrame);

    const left: dvui.Id = @enumFromInt(0xD1);
    const right: dvui.Id = @enumFromInt(0xD2);
    setSize(left, 100);
    setSize(right, 100);

    // No room for the base's minimum and both trays' declared minimums at once.
    const c: Constraint = .{ .length = 300, .base_min = 280, .handles = 20, .others = &.{ left, right } };
    const got = resolve(left, 200, c, .{ .min = 60 });
    // The tray keeps its declared minimum, the base is the one that yields, and nothing is
    // negative — a conflict must not produce an inverted layout.
    try testing.expectApproxEqAbs(@as(f32, 60), got, 0.001);
    try testing.expect(got >= 0);
    try testing.expect(getSize(right) >= 0);
}

test "a container smaller than the base leaves the trays nothing" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 300 } });
    defer t.deinit();
    _ = try dvui.testing.step(twoPaneFrame);

    const only: dvui.Id = @enumFromInt(0xE1);
    setSize(only, 100);

    // base_min alone exceeds the container: room is zero, not negative.
    const c: Constraint = .{ .length = 200, .base_min = 400, .handles = 10, .others = &.{only} };
    try testing.expectApproxEqAbs(@as(f32, 0), resolve(only, 150, c, .{}), 0.001);
}

test "a max below the min does not panic in the clamp" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 300 } });
    defer t.deinit();
    _ = try dvui.testing.step(twoPaneFrame);

    const only: dvui.Id = @enumFromInt(0xF1);
    setSize(only, 50);

    // `std.math.clamp` asserts lower <= upper, so a contradictory pair has to be reconciled
    // before it reaches the clamp rather than after.
    const c: Constraint = .{ .length = 1000, .base_min = 100, .handles = 10, .others = &.{only} };
    const got = resolve(only, 500, c, .{ .min = 200, .max = 50 });
    try testing.expectApproxEqAbs(@as(f32, 200), got, 0.001);
}
