//! The **split**: the draggable divider between two regions.
//!
//! Lives apart from `Layout` so it can be tested against dvui's testing backend without an
//! `Editor` — this path has been wrong twice in ways no amount of reading caught (a drag that
//! took capture and then froze; a handle that filled its whole strip), and both were dvui
//! event-routing rules rather than layout logic. It depends on nothing but dvui.
const std = @import("std");
const dvui = @import("dvui");
const icon_tex = @import("../gfx/icon.zig");
const icons = @import("icons");
const anim = @import("../anim.zig");

const Split = @This();

/// The separator's own box. A split is a widget you get back and `deinit`, like any dvui
/// widget — it has a
/// rect, a lifetime and drag state, so it is a type rather than a bag of functions over one.
box: *dvui.BoxWidget,
axis: dvui.enums.Direction,

/// Set `FIZZY_SPLIT_DEBUG=1` to log what each drag computes. Temporary: a split that stops short
/// has now survived three rounds of reasoning about it, so the next step is numbers.
pub var debug: bool = false;

/// Thickness of a split, and how near the pointer must be before it shows itself. Fizzy's tuned
/// values: a thinner target is measurably harder to grab.
pub const handle_size: f32 = 10;
pub const handle_dist: f32 = 60;

/// What the container knows that a single split does not: how much room there is, how much of it
/// the base region insists on keeping, and which other regions exist on the same axis.
///
/// This is why a split *requests* an extent rather than setting one. Growing into the flex
/// gap takes from the gap; when the gap is gone the opposite side yields. `push_out` only
/// moves trays behind this one. The container arbitrates; the regions stop owning their
/// sizes independently.
pub const Constraint = struct {
    /// The container's own extent along the axis — one number, the same word every other
    /// distance along a layout axis uses (`Region.default_extent`, `Layout.Container.extent`).
    extent: f32 = 0,
    /// The base region's declared minimum — `min_size_content` on the region that is not
    /// resizable. Declared by the app, never inferred from a plugin's content, or the plugin
    /// would be setting the app's proportions.
    base_min: f32 = 0,
    /// Total length the splits themselves take.
    handles: f32 = 0,
    /// The other resizable regions in this container, in declaration order. Left/top
    /// trays are listed outer-first; right/bottom trays inner-first, so "behind" and
    /// "opposite" are just index comparisons against `target` and `sign`.
    others: []const dvui.Id = &.{},
    /// +1 when the target sits before the split (left/top), -1 when it sits after
    /// (right/bottom). `resolve` uses this to tell same-side from opposite-side trays.
    sign: f32 = 1,
};

/// Whether `o` sits further toward the window edge than `target` (same side), or
/// on the other side of the flex gap.
fn relation(o: dvui.Id, target: dvui.Id, others: []const dvui.Id, sign: f32) enum { skip, behind, opposite } {
    if (o == target) return .skip;
    const ti = indexOf(target, others) orelse return .opposite;
    const oi = indexOf(o, others) orelse return .opposite;
    if (sign > 0) {
        return if (oi < ti) .behind else .opposite;
    }
    return if (oi > ti) .behind else .opposite;
}

fn indexOf(id: dvui.Id, others: []const dvui.Id) ?usize {
    for (others, 0..) |o, i| {
        if (o == id) return i;
    }
    return null;
}

fn shrink(id: dvui.Id, give: f32) void {
    if (give <= 0) return;
    const had = dvui.dataGet(null, id, "_size", f32) orelse 0;
    const next = @max(0, had - give);
    dvui.dataSet(null, id, "_size", next);
    dvui.dataSet(null, id, "_shown", next);
}

/// Resolve a requested extent for `target` against the container's constraint.
///
/// A pull takes space from the base. When the base still has room, other trays stay
/// put. When the base is gone, the opposite side yields so a drag from the other
/// edge can open a tray (a new flex gap). `push_out` shrinks only the trays behind
/// this one — a right sash past the edge does not close the left.
pub fn resolve(target: dvui.Id, want: f32, c: Constraint, opts: Options) f32 {
    // `std.math.clamp` asserts `lower <= upper`, so an explicit `max` below `min` would panic
    // inside the clamp rather than reaching any guard after it.
    const limit = @max(opts.min, opts.max orelse (c.extent - handle_size));
    var size = std.math.clamp(want, opts.min, limit);
    if (c.extent <= 0) return size;

    // What the trays may occupy between them once the base has kept its minimum. Never negative:
    // a container too small for the base alone leaves the trays nothing rather than a negative
    // budget that would read as unlimited room.
    const budget = @max(0, c.extent - c.base_min - c.handles);

    var others: f32 = 0;
    for (c.others) |o| {
        if (o == target) continue;
        others += dvui.dataGet(null, o, "_size", f32) orelse 0;
    }

    const room = @max(0, budget - others);
    if (size > room) {
        // Reclaim the opposite side only when the shape left the flex gap with
        // no floor (`base_min` is 0) and that gap is already gone. A declared
        // floor still means "stop", not "steal from the other edge".
        if (room == 0 and c.base_min <= 0) {
            var need = size;
            for (c.others) |o| {
                if (relation(o, target, c.others, c.sign) != .opposite or need <= 0) continue;
                const had = dvui.dataGet(null, o, "_size", f32) orelse 0;
                const give = @min(had, need);
                shrink(o, give);
                need -= give;
            }
            size = @max(opts.min, size - need);
        } else {
            size = @max(opts.min, room);
        }
    }

    // Push: the drag asked for less than `min`, so shrink the trays behind this one.
    if (opts.push_out and want < size) {
        var extra = size - want;
        for (c.others) |o| {
            if (relation(o, target, c.others, c.sign) != .behind or extra <= 0) continue;
            const had = dvui.dataGet(null, o, "_size", f32) orelse 0;
            const give = @min(had, extra);
            shrink(o, give);
            extra -= give;
        }
    }
    return size;
}

pub const Options = struct {
    /// False draws the gap but does not let the user move it.
    resize: bool = true,
    /// Smallest extent the dragged neighbour may be squeezed to. Zero by default, so a split can
    /// be dragged fully closed — a region you cannot shut is a region the user has to fight.
    min: f32 = 0,
    /// Largest, or null to allow the full length of the container minus the split itself, so a
    /// region can be dragged fully open. A number here is a deliberate cap, not a default.
    max: ?f32 = null,
    /// Distinguishes two splits declared from the same `@src()` — a loop of edge regions, each
    /// with a split after it. Zero for the ordinary case of one split per source line.
    id_extra: usize = 0,
    /// On release, an extent below this eases shut (`_size` goes to zero, `_shown` is left
    /// alone so `eased` plays the close). Null means the released size sticks.
    snap_below: ?f32 = null,
    /// When the drag asks for less than `min`, shrink the other trays on this container
    /// instead of stopping — so an inner tray can push an accidental outer one off the edge.
    push_out: bool = false,
};

/// Open a split: by default it takes `handle_size` along the container's axis and stretches
/// across it, so `dvui.box` reserves the gap the way it reserves any other child.
///
/// `at` places the handle without packing it. Region containers pass `overlayRect` so a new
/// sentinel does not insert `handle_size` into the box. `Panes` places its own children the
/// same way — a packed handle would sit wherever the pane before it was laid out, which
/// during a drag is a frame stale. `null` still packs, for a caller that wants a reserved gap.
///
/// `init` + `deinit`, the pairing every dvui widget uses, because that is what this is. The
/// verb form lives in the namespace above the type — `core.widgets.split(...)` for a plugin,
/// `Layout.split(...)` for a shape — exactly as `dvui.box()` sits above `BoxWidget.init`.
pub fn init(
    src: std.builtin.SourceLocation,
    axis: dvui.enums.Direction,
    id_extra: usize,
    at: ?dvui.Rect,
) Split {
    return initSized(src, axis, id_extra, at, handle_size);
}

/// A split thinner than `handle_size`, for the one case that needs it: the gap beside a place
/// that is closing for good. A sash is 10pt of room, so leaving it at full width while the place
/// it divides shrinks to nothing means the pair still occupies 10pt when the place is gone, and
/// loses it in one step the frame the place is dropped. Closing it alongside costs nothing to
/// grab, because there will be nothing to grab.
pub fn initSized(
    src: std.builtin.SourceLocation,
    axis: dvui.enums.Direction,
    id_extra: usize,
    at: ?dvui.Rect,
    thickness: f32,
) Split {
    return .{ .axis = axis, .box = dvui.box(src, .{ .dir = axis }, .{
        .id_extra = id_extra,
        .rect = at,
        .min_size_content = switch (axis) {
            .horizontal => .{ .w = thickness },
            .vertical => .{ .h = thickness },
        },
        .expand = switch (axis) {
            .horizontal => .vertical,
            .vertical => .horizontal,
        },
        .background = false,
    }) };
}

pub fn deinit(self: *Split) void {
    self.box.deinit();
}

/// A region's extent, and opening or shutting it from outside the layout.
///
/// These are the whole protocol for driving a region programmatically — the rail button, a
/// command, a keybind. They move the *stored* size; `Frame.region` eases the drawn size toward
/// it, so a caller gets the animation without knowing there is one.
pub fn sizeOf(id: dvui.Id) f32 {
    return dvui.dataGet(null, id, "_size", f32) orelse 0;
}

pub fn isClosed(id: dvui.Id) bool {
    return sizeOf(id) <= 0;
}

/// Shut it, remembering how big it was so `open` can put it back.
/// Seeds `_shown` from the current extent so `eased` has somewhere to travel
/// from — the same trick `takeSlideOpen` uses the other way. Without that, a
/// missing or leftover-zero `_shown` makes the next frame treat target 0 as
/// already there, and the pane vanishes instead of folding.
pub fn close(id: dvui.Id) void {
    const cur = sizeOf(id);
    if (cur <= 0) return;
    dvui.dataSet(null, id, "_open", cur);
    const shown = dvui.dataGet(null, id, "_shown", f32) orelse cur;
    dvui.dataSet(null, id, "_shown", if (shown > 0) shown else cur);
    dvui.dataSet(null, id, "_size", @as(f32, 0));
    dvui.refresh(null, @src(), id);
}

/// Reopen to the remembered extent, or `fallback` if it has never been open.
pub fn open(id: dvui.Id, fallback: f32) void {
    const was = dvui.dataGet(null, id, "_open", f32) orelse fallback;
    dvui.dataSet(null, id, "_size", @max(1, was));
}

/// The drawn extent for `target`, easing toward it when it moved for a reason other than a drag
/// — a pane appearing, a region collapsing, a mode changing.
///
/// Callers that size a pane every frame use this instead of the stored size directly, so a new
/// split slides in rather than appearing at full width. A drag is exempt without a flag: the
/// drag writes `_shown` alongside `_size`, so the two agree and nothing starts.
///
/// The curve depends on which way the pane is going — see `core.anim.slide`. Overshooting on the
/// way *open* is the weight; overshooting on the way *shut* drags the edge past the edge of the
/// container and back, which is the jitter a closing pane used to have.
pub fn eased(id: dvui.Id, target: f32) f32 {
    return easedKey(id, target, "_ease", "_shown");
}

/// `eased` against a caller-chosen pair of keys, so a second number on the same id can travel on
/// the same curve — `Panes` eases a *share* while a split eases an extent, and both belong to the
/// pane they size.
pub fn easedKey(id: dvui.Id, target: f32, anim_key: []const u8, shown_key: []const u8) f32 {
    if (dvui.animationGet(id, anim_key)) |a| {
        const v = a.value();
        dvui.dataSet(null, id, shown_key, v);
        // dvui does not keep the window awake for a data-id animation.
        // Without this a close rides whatever else is refreshing, then
        // parks until the next mouse move — and persistExtent collapses
        // the leaf in one frame.
        dvui.refresh(null, @src(), id);
        return v;
    }
    const shown = dvui.dataGet(null, id, shown_key, f32) orelse target;
    if (shown != target) {
        const opening = target > shown;
        dvui.animation(id, anim_key, .{
            .start_val = shown,
            .end_val = target,
            .end_time = anim.slide.ms(opening) * std.time.us_per_ms,
            .easing = anim.slide.easing(opening),
        });
        dvui.dataSet(null, id, shown_key, shown);
        dvui.refresh(null, @src(), id);
        return shown;
    }
    dvui.dataSet(null, id, shown_key, target);
    return target;
}

/// Record where a resizable region's edges are, so a split can size it from a fixed anchor
/// instead of correcting itself frame to frame.
///
/// The anchor is the edge the region does **not** grow from: the far edge of a region before the
/// split, or the near edge of one after it. Neither moves while dragging, which is what makes the
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

/// A handle-sized strip on `target`'s moving edge, in the container's content
/// coordinates. Used as `init`'s `at` so the split is not a packed child — a packed
/// child is what makes a new sentinel shove every other split by `handle_size`.
pub fn overlayRect(
    container: *dvui.BoxWidget,
    target: dvui.Id,
    sign: f32,
    axis: dvui.enums.Direction,
) dvui.Rect {
    const cr = container.data().contentRect();
    const crs = container.data().contentRectScale();
    const edge = dvui.dataGet(null, target, if (sign > 0) "_end" else "_org", f32);
    switch (axis) {
        .horizontal => {
            const x = if (edge) |e| (e - crs.r.x) / crs.s else if (sign > 0) 0 else cr.w;
            const pos = if (sign > 0) x else x - handle_size;
            return .{ .x = pos, .y = 0, .w = handle_size, .h = cr.h };
        },
        .vertical => {
            const y = if (edge) |e| (e - crs.r.y) / crs.s else if (sign > 0) 0 else cr.h;
            const pos = if (sign > 0) y else y - handle_size;
            return .{ .x = 0, .y = pos, .w = cr.w, .h = handle_size };
        },
    }
}

/// What the pointer is doing to this split this frame: where it wants the boundary, and how near
/// it is (which is what the grip is drawn from).
///
/// Split out of `drag` so a second sizing model can share the event handling. Everything here is
/// dvui's routing rules — approach matching on the container, the capture switch, giving capture
/// back on release — and all of it has been wrong at least once. What a *number* means is the
/// part that differs: `drag` reads it as one region's extent in points, `Panes` reads it as a
/// boundary between two shares.
pub const Grab = struct {
    /// Pointer position along the axis, in **physical** pixels, on a frame the split is being
    /// dragged. Null on every other frame.
    to: ?f32 = null,
    /// Distance from the split's centre line in points; zero while captured.
    dist: f32 = std.math.floatMax(f32),
    /// The split's scale, for converting `to` into points.
    scale: f32 = 1,
};

/// Run the split's pointer handling: approach, press, drag, release, cursor.
///
/// Events are matched against the **container**, not this thin strip, so the split can grow as
/// the pointer approaches rather than only reacting once it is already on top of a 10pt target —
/// the difference between a split that feels findable and one that does not. Nothing is
/// handled unless the pointer is actually close.
///
/// **Except while we hold capture.** dvui's `eventMatch` refuses every widget that is not the
/// capture holder once a capture is live ("someone else has capture"), so continuing to match on
/// the container during a drag rejects the motion and release events too — the drag freezes on
/// the first pixel, capture is never given back, and the resize cursor sticks. So once captured
/// we match on ourselves, which the capture branch admits regardless of rect.
pub fn grab(self: *Split, container: *dvui.WidgetData) Grab {
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

    var out: Grab = .{ .scale = srs.s };
    for (dvui.events()) |*e| {
        if (e.evt != .mouse) continue;

        const captured = dvui.captured(wd.id);
        if (captured) {
            if (!dvui.eventMatchSimple(e, wd)) continue;
            out.dist = 0;
        } else {
            if (!dvui.eventMatchSimple(e, container)) continue;
            const p = switch (axis) {
                .horizontal => e.evt.mouse.p.x,
                .vertical => e.evt.mouse.p.y,
            };
            out.dist = @abs(p - centre) / srs.s;
            if (out.dist > handle_size) continue;
        }

        switch (e.evt.mouse.action) {
            .press => if (e.evt.mouse.button.pointer()) {
                e.handle(@src(), wd);
                dvui.captureMouse(wd, e.num);
                dvui.dragPreStart(e.evt.mouse.button, e.evt.mouse.p, .{ .cursor = cursor });
            },
            .release => if (e.evt.mouse.button.pointer() and captured) {
                e.handle(@src(), wd);
                dvui.captureMouse(null, e.num);
                dvui.dragEnd();
            },
            .motion => if (captured) {
                e.handle(@src(), wd);
                // Taken from the last motion of the frame and applied once by the caller.
                // Applying per event would over-shoot: every motion would be measured against
                // the same stale split position.
                if (dvui.dragging(e.evt.mouse.p, null) != null) {
                    out.to = switch (axis) {
                        .horizontal => e.evt.mouse.p.x,
                        .vertical => e.evt.mouse.p.y,
                    };
                }
            },
            .position => dvui.cursorSet(cursor),
            else => {},
        }
    }
    if (dvui.captured(wd.id)) out.dist = 0;
    return out;
}

/// Draw the split itself: a resting pill that grows into a grip as the pointer approaches.
pub fn draw(self: *Split, dist: f32) void {
    const wd = self.box.data();
    drawSplit(wd, wd.borderRectScale(), self.axis, dist, false);
}

/// Drag `target`'s stored extent, and draw the split. `sign` is +1 when the target is the region
/// *before* the split and -1 when it is the one after, so dragging always moves the edge the way
/// the pointer goes.
pub fn drag(
    self: *Split,
    container: *dvui.BoxWidget,
    target: dvui.Id,
    sign: f32,
    opts: Options,
    c: Constraint,
) void {
    const axis = self.axis;
    const wd = self.box.data();
    const srs = wd.borderRectScale();

    const centre = switch (axis) {
        .horizontal => srs.r.x + srs.r.w / 2,
        .vertical => srs.r.y + srs.r.h / 2,
    };

    const grabbed = self.grab(container.data());
    const dist = grabbed.dist;
    const drag_to = grabbed.to;
    const was = dvui.dataGet(null, wd.id, "_held", bool) orelse false;
    const now = dvui.captured(wd.id);

    // Drive the size from where the pointer is relative to the split, not from an accumulated
    // delta.
    //
    // `dvui.dragging` returns the difference since the **previous call**, not since the press
    // (see `Dragging.get`), so adding it to a baseline captured at press time applies exactly one
    // frame of movement and then stops — the split pops once and sits there. Summing it instead
    // would work but drifts, and drops any motion a frame misses.
    //
    // The split is drawn wherever the stored size puts it, so moving the size by the pointer's
    // offset from the split lands the split under the pointer, and stays exact from then on with
    // nothing accumulated.
    if (drag_to) |p| {
        // Size from the region's fixed edge, not from a correction applied to the current size.
        //
        // A relative correction winds up: once the size clamps at a limit the pointer keeps
        // travelling past the split, and dragging back has to walk off that overshoot before
        // anything moves — the split sticks at the end of its range and then lags. Measuring from
        // an edge that does not move during the drag makes the size a pure function of where the
        // pointer is, so it leaves a limit the instant the pointer does.
        const current = dvui.dataGet(null, target, "_size", f32) orelse currentExtent(target, axis);
        // The fixed edge at press, not the live `_org`/`_end`. A new sentinel
        // insets the region and would rewrite those, which shrinks `want` by
        // `handle_size` and the tray jumps shut.
        if (dvui.dataGet(null, target, "_drag_anchor", f32) == null) {
            if (dvui.dataGet(null, target, if (sign > 0) "_org" else "_end", f32)) |a| {
                dvui.dataSet(null, target, "_drag_anchor", a);
            }
        }
        const anchor = dvui.dataGet(null, target, "_drag_anchor", f32);
        const want = if (anchor) |a|
            (if (sign > 0) (p - a) else (a - p)) / srs.s - handle_size / 2
        else
            current + sign * (p - centre) / srs.s;

        const resolved = resolve(target, want, c, opts);
        if (debug) dvui.log.err(
            "[split] axis={s} sign={d} p={d} centre={d} anchor={?d} scale={d} | want={d} resolved={d} | min={d} max={?d} extent={d} base_min={d} handles={d} others={d}",
            .{ @tagName(axis), sign, p, centre, anchor, srs.s, want, resolved, opts.min, opts.max, c.extent, c.base_min, c.handles, c.others.len },
        );
        dvui.dataSet(null, target, "_size", resolved);
        // Keep the shown extent in step with the target during a drag, so the region does not
        // read this as a change to ease into. A split belongs under the pointer, not on a curve.
        dvui.dataSet(null, target, "_shown", resolved);
        dvui.dataSet(null, target, "_drag", true);
        dvui.refresh(null, @src(), wd.id);
    } else if (was and !now) {
        dvui.dataRemove(null, target, "_drag");
        dvui.dataRemove(null, target, "_drag_anchor");
        if (opts.snap_below) |floor| {
            const sz = dvui.dataGet(null, target, "_size", f32) orelse 0;
            if (sz > 0 and sz < floor) {
                dvui.dataSet(null, target, "_size", @as(f32, 0));
                dvui.refresh(null, @src(), wd.id);
            }
        }
    }
    dvui.dataSet(null, wd.id, "_held", now);

    // A split whose region is shut has nothing beside it to imply that it is there, so it keeps a
    // resting line at the edge and grows the grip out of that on approach. Without it a closed
    // region is indistinguishable from no region, and the way back is invisible.
    //
    // Several shut regions in a row — a few markdown previews opened to the side — do not pile up
    // on one another: a split still takes its own `handle_size` in the layout even when what it
    // resizes is zero, so they sit side by side and read as the several separate handles they
    // are.
    const at_rest = (dvui.dataGet(null, target, "_shown", f32) orelse 1) <= 0;
    drawSplit(wd, srs, axis, dist, at_rest);
}

/// The split itself: a short rounded bar across the middle of the gap with a grip on it, fading
/// in as the pointer approaches. Deliberately **not** a fill of the whole separator — the strip
/// spans the entire edge, and painting all of it reads as a solid divider rather than something
/// you can grab.
fn drawSplit(
    wd: *dvui.WidgetData,
    srs: dvui.RectScale,
    axis: dvui.enums.Direction,
    dist: f32,
    at_rest: bool,
) void {
    _ = at_rest;

    // A split is **always** visible, as a short faint pill, and grows into the full grip as the
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
    // At rest a short pill; under the pointer a fifth of the edge.
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
    // ignored, and the pill came out a rectangle. A split is a grip, not a panel: it should read
    // as a pill whatever the theme does to boxes.
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
    icon_tex.icon(@src(), "grip", grip, .{
        .stroke_color = .{ .color = dvui.themeGet().color(.content, .fill).opacity(approach) },
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

/// A horizontal container: a fixed-width region, a split, and a stretchy one. The same shape as
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

    var divider = init(@src(), .horizontal, 0, null);
    {
        const srs = divider.box.data().borderRectScale();
        t_sep_x = srs.r.x + srs.r.w / 2;
        t_scale = srs.s;
        t_room = row.data().contentRect().w;
        t_room_px = row.data().borderRectScale().r.w;
        t_org_px = row.data().borderRectScale().r.x;
        divider.drag(row, t_target, 1, .{ .min = t_min }, .{ .extent = row.data().contentRect().w });
        t_captured = dvui.captured(divider.box.data().id);
    }
    divider.deinit();

    {
        // A real minimum on the far side, which is what makes the open limit *unreachable*: the
        // stored size can be clamped to a value the layout cannot actually give, and then the
        // split sits short of it. That gap is where windup lives, so a test frame without it
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

test "dragging the split resizes the region before it" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 300 } });
    defer t.deinit();

    try dvui.testing.settle(twoPaneFrame);
    const before = t_size;
    const grab_x = t_sep_x;

    const cw = dvui.currentWindow();
    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = grab_x, .y = 100 } });
    _ = try dvui.testing.step(twoPaneFrame);

    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(twoPaneFrame);
    try testing.expect(t_captured);

    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = grab_x + 80, .y = 100 } });
    _ = try dvui.testing.step(twoPaneFrame);

    // The regression: with capture held, matching events on the container makes dvui reject
    // every one of them ("someone else has capture"), so the drag freezes on the first pixel.
    try testing.expect(t_size > before);

    // ...and it must move *by the drag distance*, not merely increase. A baseline taken from
    // anything other than the region's current extent — its natural content minimum, say — makes
    // the first press jump the region to that width before applying the delta, which reads as
    // the split popping to a different size the moment you grab it.
    try testing.expectApproxEqAbs(before + 80 / t_scale, t_size, 1.0);
}

test "the split follows the pointer across a multi-step drag" {
    // The regression this exists for: `dvui.dragging` reports the delta since the *previous
    // call*, so a single-motion test cannot tell a cumulative baseline from an incremental one —
    // they agree on the first event and only diverge from the second. A real drag is many motion
    // events across many frames, and the buggy version moved on the first and then sat still.
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 300 } });
    defer t.deinit();

    try dvui.testing.settle(twoPaneFrame);
    const before = t_size;
    const grab_x = t_sep_x;
    const cw = dvui.currentWindow();

    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = grab_x, .y = 100 } });
    _ = try dvui.testing.step(twoPaneFrame);
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(twoPaneFrame);

    // Six frames of 20 physical pixels each, the way a real drag arrives.
    var moved: f32 = 0;
    for (0..6) |_| {
        moved += 20;
        _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = grab_x + moved, .y = 100 } });
        _ = try dvui.testing.step(twoPaneFrame);
    }
    _ = try cw.addEventMouseButton(.left, .release);
    _ = try dvui.testing.step(twoPaneFrame);

    try testing.expectApproxEqAbs(before + moved / t_scale, t_size, 2.0);
    // And the split itself ends up under the pointer, which is what "follows the mouse" means.
    try testing.expectApproxEqAbs(grab_x + moved, t_sep_x, 4.0);
}

test "releasing gives capture back, so the cursor does not stick" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 300 } });
    defer t.deinit();

    try dvui.testing.settle(twoPaneFrame);
    const grab_x = t_sep_x;
    const cw = dvui.currentWindow();

    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = grab_x, .y = 100 } });
    _ = try dvui.testing.step(twoPaneFrame);
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(twoPaneFrame);
    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = grab_x + 40, .y = 100 } });
    _ = try dvui.testing.step(twoPaneFrame);
    _ = try cw.addEventMouseButton(.left, .release);
    _ = try dvui.testing.step(twoPaneFrame);

    try testing.expect(!t_captured);
}

test "a split can be dragged fully closed and fully open" {
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

    // ...and all the way to the far edge, which is the container's length less the split.
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
    // banks up the distance the pointer travelled past the split, and dragging back has to spend
    // it all again before anything moves. The split appears stuck at the end of its range.
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

    // Now come back to a position well inside the range. One frame should put the split there.
    const target_x = t_org_px + t_room_px * 0.4;
    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = target_x, .y = 100 } });
    _ = try dvui.testing.step(twoPaneFrame);

    // The size responds on this frame...
    try testing.expect(t_size < at_limit - 20);

    // ...and the split is drawn there two frames later. That is dvui's normal settle, not the
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
    const grab_x = t_sep_x;
    const cw = dvui.currentWindow();

    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = grab_x, .y = 100 } });
    _ = try dvui.testing.step(twoPaneFrame);
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(twoPaneFrame);
    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = grab_x - 5000, .y = 100 } });
    _ = try dvui.testing.step(twoPaneFrame);

    try testing.expect(t_size >= 20);
}

test "a far-away press is not a grab" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 300 } });
    defer t.deinit();

    try dvui.testing.settle(twoPaneFrame);
    const before = t_size;
    const cw = dvui.currentWindow();

    // Well clear of the split: pressing here belongs to whatever is under it, not to the split.
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

    const c: Constraint = .{ .extent = 1000, .base_min = 400, .handles = 20, .others = &.{ left, right } };
    try testing.expectApproxEqAbs(@as(f32, 300), resolve(left, 300, c, .{}), 0.001);
    // The other tray is untouched: there was room for both.
    try testing.expectApproxEqAbs(@as(f32, 100), getSize(right), 0.001);
}

test "a pull stops when the base is at its minimum and leaves the other tray" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 300 } });
    defer t.deinit();
    _ = try dvui.testing.step(twoPaneFrame);

    const left: dvui.Id = @enumFromInt(0xB1);
    const right: dvui.Id = @enumFromInt(0xB2);
    setSize(left, 200);
    setSize(right, 200);

    // 1000 long, base keeps 400, splits take 20 -> 580 for the trays. Asking for 500 on the
    // left would need the right to move; a pull does not, so the left stops at 380.
    const c: Constraint = .{ .extent = 1000, .base_min = 400, .handles = 20, .others = &.{ left, right } };
    try testing.expectApproxEqAbs(@as(f32, 380), resolve(left, 500, c, .{}), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 200), getSize(right), 0.001);
}

test "a pull that asks for more than the whole budget still leaves the other tray" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 300 } });
    defer t.deinit();
    _ = try dvui.testing.step(twoPaneFrame);

    const left: dvui.Id = @enumFromInt(0xC1);
    const right: dvui.Id = @enumFromInt(0xC2);
    setSize(left, 200);
    setSize(right, 200);

    const c: Constraint = .{ .extent = 1000, .base_min = 400, .handles = 20, .others = &.{ left, right } };
    const got = resolve(left, 5000, c, .{});
    try testing.expectApproxEqAbs(@as(f32, 200), getSize(right), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 380), got, 0.001);
}

test "push_out past min shrinks the tray behind" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 300 } });
    defer t.deinit();
    _ = try dvui.testing.step(twoPaneFrame);

    const inner: dvui.Id = @enumFromInt(0xC3);
    const outer: dvui.Id = @enumFromInt(0xC4);
    setSize(inner, 0);
    setSize(outer, 120);

    // Right-style: inner then outer, sign -1. Behind is the outer tray.
    const c: Constraint = .{ .extent = 1000, .base_min = 400, .handles = 20, .others = &.{ inner, outer }, .sign = -1 };
    const got = resolve(inner, -80, c, .{ .push_out = true });
    try testing.expectApproxEqAbs(@as(f32, 0), got, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 40), getSize(outer), 0.001);
}

test "push_out on the right does not close the left" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 300 } });
    defer t.deinit();
    _ = try dvui.testing.step(twoPaneFrame);

    const left: dvui.Id = @enumFromInt(0xC5);
    const right: dvui.Id = @enumFromInt(0xC6);
    setSize(left, 160);
    setSize(right, 0);

    const c: Constraint = .{ .extent = 1000, .base_min = 0, .handles = 20, .others = &.{ left, right }, .sign = -1 };
    const got = resolve(right, -80, c, .{ .push_out = true });
    try testing.expectApproxEqAbs(@as(f32, 0), got, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 160), getSize(left), 0.001);
}

test "a pull with no flex left reclaims the opposite side" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 300 } });
    defer t.deinit();
    _ = try dvui.testing.step(twoPaneFrame);

    const left: dvui.Id = @enumFromInt(0xC7);
    const right: dvui.Id = @enumFromInt(0xC8);
    setSize(left, 0);
    setSize(right, 980);

    // Budget is 980; the right tray has it all. Opening the left takes from the right.
    const c: Constraint = .{ .extent = 1000, .base_min = 0, .handles = 20, .others = &.{ left, right }, .sign = 1 };
    const got = resolve(left, 120, c, .{});
    try testing.expectApproxEqAbs(@as(f32, 120), got, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 860), getSize(right), 0.001);
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
    const c: Constraint = .{ .extent = 300, .base_min = 280, .handles = 20, .others = &.{ left, right } };
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
    const c: Constraint = .{ .extent = 200, .base_min = 400, .handles = 10, .others = &.{only} };
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
    const c: Constraint = .{ .extent = 1000, .base_min = 100, .handles = 10, .others = &.{only} };
    const got = resolve(only, 500, c, .{ .min = 200, .max = 50 });
    try testing.expectApproxEqAbs(@as(f32, 200), got, 0.001);
}
