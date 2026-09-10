//! The **sash**: the draggable divider between two regions.
//!
//! Lives apart from `Frame` so it can be tested against dvui's testing backend without an
//! `Editor` — this path has been wrong twice in ways no amount of reading caught (a drag that
//! took capture and then froze; a handle that filled its whole strip), and both were dvui
//! event-routing rules rather than layout logic. It depends on nothing but dvui.
const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");

const Sash = @This();

/// The separator's own box. A sash is a widget you get back and `end`, like `Tabs` — it has a
/// rect, a lifetime and drag state, so it is a type rather than a bag of functions over one.
box: *dvui.BoxWidget,
axis: dvui.enums.Direction,

/// Set `FIZZY_SASH_DEBUG=1` to log what each drag computes. Temporary: a sash that stops short
/// has now survived three rounds of reasoning about it, so the next step is numbers.
pub var debug: bool = false;

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
        if (give > 0) {
            dvui.dataSet(null, o, "_size", had - give);
            dvui.dataSet(null, o, "_shown", had - give);
        }
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

/// Open a sash: it takes `handle_size` along the container's axis and stretches across it, so
/// `dvui.box` reserves the gap the way it reserves any other child.
pub fn begin(src: std.builtin.SourceLocation, axis: dvui.enums.Direction) Sash {
    return .{ .axis = axis, .box = dvui.box(src, .{ .dir = axis }, .{
        .min_size_content = switch (axis) {
            .horizontal => .{ .w = handle_size },
            .vertical => .{ .h = handle_size },
        },
        .expand = switch (axis) {
            .horizontal => .vertical,
            .vertical => .horizontal,
        },
        .background = false,
    }) };
}

pub fn end(self: *Sash) void {
    self.box.deinit();
}

/// A region's extent, and opening or shutting it from outside the layout.
///
/// These are the whole protocol for driving a region programmatically — the rail button, a
/// command, a keybind. They move the *stored* size; `Frame.region` eases the drawn size toward
/// it, so a caller gets the animation without knowing there is one.
///
/// Before this, opening the explorer meant reaching for the `PanedWidget` behind it and calling
/// `animateSplit`. That only worked while a region *was* a paned, which is exactly the kind of
/// reach-through that made the old shell impossible to reshape.
pub fn sizeOf(id: dvui.Id) f32 {
    return dvui.dataGet(null, id, "_size", f32) orelse 0;
}

pub fn isClosed(id: dvui.Id) bool {
    return sizeOf(id) <= 0;
}

/// Shut it, remembering how big it was so `open` can put it back.
pub fn close(id: dvui.Id) void {
    const cur = sizeOf(id);
    if (cur > 0) dvui.dataSet(null, id, "_open", cur);
    dvui.dataSet(null, id, "_size", @as(f32, 0));
}

/// Reopen to the remembered extent, or `fallback` if it has never been open.
pub fn open(id: dvui.Id, fallback: f32) void {
    const was = dvui.dataGet(null, id, "_open", f32) orelse fallback;
    dvui.dataSet(null, id, "_size", @max(1, was));
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
pub fn drag(
    self: *Sash,
    container: *dvui.BoxWidget,
    target: dvui.Id,
    sign: f32,
    opts: Options,
    c: Constraint,
) void {
    const axis = self.axis;
    const wd = self.box.data();
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

        const resolved = resolve(target, want, c, opts);
        if (debug) dvui.log.err(
            "[sash] axis={s} sign={d} p={d} centre={d} anchor={?d} scale={d} | want={d} resolved={d} | min={d} max={?d} len={d} base_min={d} handles={d} others={d}",
            .{ @tagName(axis), sign, p, centre, anchor, srs.s, want, resolved, opts.min, opts.max, c.length, c.base_min, c.handles, c.others.len },
        );
        dvui.dataSet(null, target, "_size", resolved);
        // Keep the shown extent in step with the target during a drag, so the region does not
        // read this as a change to ease into. A sash belongs under the pointer, not on a curve.
        dvui.dataSet(null, target, "_shown", resolved);
        dvui.refresh(null, @src(), wd.id);
    }

    if (dvui.captured(wd.id)) dist = 0;

    // A sash whose region is shut has nothing beside it to imply that it is there, so it keeps a
    // resting line at the edge and grows the grip out of that on approach. Without it a closed
    // region is indistinguishable from no region, and the way back is invisible.
    //
    // Several shut regions in a row — a few markdown previews opened to the side — do not pile up
    // on one another: a sash still takes its own `handle_size` in the layout even when what it
    // resizes is zero, so they sit side by side and read as the several separate handles they
    // are.
    const at_rest = (dvui.dataGet(null, target, "_shown", f32) orelse 1) <= 0;
    drawSash(wd, srs, axis, dist, at_rest);
}

/// The sash itself: a short rounded bar across the middle of the gap with a grip on it, fading
/// in as the pointer approaches. Deliberately **not** a fill of the whole separator — the strip
/// spans the entire edge, and painting all of it reads as a solid divider rather than something
/// you can grab.
fn drawSash(
    wd: *dvui.WidgetData,
    srs: dvui.RectScale,
    axis: dvui.enums.Direction,
    dist: f32,
    at_rest: bool,
) void {
    _ = at_rest;

    // A sash is **always** visible, as a short faint pill, and grows into the full grip as the
    // pointer approaches.
    //
    // It used to draw nothing until the pointer was near, which left a shut or nearly-shut region
    // indistinguishable from no region at all — and the way back to it unfindable. A resting mark
    // shown only at exactly zero does not fix that either: a region squeezed to a sliver is just
    // as unreadable and just as much in need of a "there is something here".
    const approach = 1.0 - std.math.clamp((dist - handle_size) / handle_dist, 0.0, 1.0);

    const edge = switch (axis) {
        .horizontal => srs.r.h,
        .vertical => srs.r.w,
    };
    // At rest a short pill; under the pointer a fifth of the edge, matching `PanedWidget`.
    const rest_len = @min(edge, 28 * srs.s);
    const full_len = edge / 5;
    const len = rest_len + (@max(full_len, rest_len) - rest_len) * approach;

    const rest_thick = 4 * srs.s;
    const thick = rest_thick + (handle_size * srs.s - rest_thick) * approach;
    const alpha = 0.18 + 0.32 * approach;

    var r = srs.r;
    switch (axis) {
        .horizontal => {
            r.x = srs.r.x + srs.r.w / 2 - thick / 2;
            r.w = thick;
            r.y = srs.r.y + srs.r.h / 2 - len / 2;
            r.h = len;
        },
        .vertical => {
            r.y = srs.r.y + srs.r.h / 2 - thick / 2;
            r.h = thick;
            r.x = srs.r.x + srs.r.w / 2 - len / 2;
            r.w = len;
        },
    }
    // `.round`, not `.all`. `CornerRect.all(r)` means "the theme's corner *kind*, at radius r",
    // and fizzy's theme squares its corners — so the radius was being honoured and the shape
    // ignored, and the pill came out a rectangle. `PanedWidget` has the same line and the same
    // square handle. A sash is a grip, not a panel: it should read as a pill whatever the theme
    // does to boxes.
    r.fill(.round(thick / 2), .{ .color = wd.options.color(.text).opacity(alpha), .fade = 1.0 });

    // The grip only once the pointer is close enough for the pill to have room for it — drawing
    // it into the resting pill would just be noise at the edge of every region.
    if (approach < 0.6) return;
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
        .stroke_color = dvui.themeGet().color(.content, .fill).opacity(approach),
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
        const w = (dvui.dataGet(null, t_target, "_size", f32) orelse 100);

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

    var sep = begin(@src(), .horizontal);
    {
        const srs = sep.box.data().borderRectScale();
        t_sep_x = srs.r.x + srs.r.w / 2;
        t_scale = srs.s;
        t_room = row.data().contentRect().w;
        t_room_px = row.data().borderRectScale().r.w;
        t_org_px = row.data().borderRectScale().r.x;
        sep.drag(row, t_target, 1, .{ .min = t_min }, .{ .length = row.data().contentRect().w });
        t_captured = dvui.captured(sep.box.data().id);
    }
    sep.end();

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

    t_size = (dvui.dataGet(null, t_target, "_size", f32) orelse 100);
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

