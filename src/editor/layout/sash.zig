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

pub const Options = struct {
    /// False draws the gap but does not let the user move it.
    resize: bool = true,
    /// Smallest extent the dragged neighbour may be squeezed to.
    min: f32 = 40,
    /// Largest, or null for no limit. Stops a panel from swallowing the window.
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
                if (dvui.dragging(e.evt.mouse.p, null)) |delta| {
                    const start = dvui.dataGet(null, wd.id, "_start", f32) orelse 0;
                    const moved = sign * switch (axis) {
                        .horizontal => delta.x,
                        .vertical => delta.y,
                    } / srs.s;
                    const want = start + moved;
                    const capped = if (opts.max) |m| @min(want, m) else want;
                    dvui.dataSet(null, target, "_size", @max(opts.min, capped));
                    dvui.refresh(null, @src(), wd.id);
                }
            },
            .position => dvui.cursorSet(cursor),
            else => {},
        }
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
    }

    var sep = handle(@src(), .horizontal);
    {
        const srs = sep.data().borderRectScale();
        t_sep_x = srs.r.x + srs.r.w / 2;
        t_scale = srs.s;
        interact(row, sep, .horizontal, t_target, 1, .{ .min = 20 });
        t_captured = dvui.captured(sep.data().id);
    }
    sep.deinit();

    {
        var right = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
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

test "a drag cannot squeeze the region below its minimum" {
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
