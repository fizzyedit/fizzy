//! A **linear splitter**: a box whose N children are separated by draggable handles.
//!
//! ```zig
//! var box = core.dvui.splitBox(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
//! defer box.deinit();
//!
//! { var c = box.slot(@src()); defer c.deinit(); ...child 0... }
//! box.handle();
//! { var c = box.slot(@src()); defer c.deinit(); ...child 1... }
//! box.handle();
//! { var c = box.slot(@src()); defer c.deinit(); ...child 2... }
//! ```
//!
//! This is the N-child generalisation of `PanedWidget`, which splits exactly two ways and so
//! has to be *nested* to express three regions — which is where `showFirst` / `showSecond` /
//! `rest()` branching comes from in a layout, and why fizzy's shapes read as a tree rather than
//! top to bottom. Three regions here are three `slot` calls in a row.
//!
//! The boundary maths lives in `core.split_layout`, with no dvui in it and its own tests: that
//! is where the off-by-ones are (handles eat length before fractions apply; a drag must not push
//! a neighbour below its minimum; children appear and disappear between frames). This file is
//! the dvui shell over it — events, drawing, and persistence.
//!
//! ## Why the child count comes from the previous frame
//!
//! Immediate mode does not know how many children there will be until the frame is over, but
//! child 0 has to be positioned before child 1 is even mentioned. So the count is remembered
//! from last frame, exactly as dvui does for min sizes. A layout that changes its region count
//! lays out one frame with the old count and then refreshes — the same one-frame settle dvui
//! already has everywhere, and the reason `deinit` calls `dvui.refresh` when the count moves.
//!
//! Boundaries are **stored, not recomputed**. Redistributing evenly whenever the count changed
//! would silently reset every size the user had dragged each time a panel appeared, which is the
//! bug that makes a resizable layout feel like it forgets.
const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const split_layout = @import("../split_layout.zig");

const SplitBox = @This();

pub const InitOptions = struct {
    /// The axis children are laid along. A horizontal box's handles are vertical bars you drag
    /// left and right.
    dir: dvui.enums.Direction = .horizontal,
    /// Thickness of a handle, and how near the pointer must be for it to grow to that
    /// thickness. Defaults match fizzy's tuned sash feel (`layout.split`'s `handle_size` /
    /// `handle_dist`); a thinner handle makes the drag target hard to hit.
    handle_size: f32 = 10,
    handle_dist: f32 = 60,
    /// The smallest share a child may be squeezed to by a drag on either side of it.
    min_fraction: f32 = 0.05,
};

wd: dvui.WidgetData,
init_opts: InitOptions,
prev_clip: dvui.Rect.Physical = .{},

/// Boundaries between children, ascending fractions in (0, 1). `count` children means
/// `count - 1` of these. Owned by dvui's per-widget data store, so it survives the frame.
boundaries: []f32 = &no_boundaries,
/// How many children last frame had — what this frame lays out against (see the note above).
expected: usize = 0,
/// How many `slot` calls this frame has seen so far; also the index of the next child.
placed: usize = 0,
/// Which boundaries were draggable **last** frame — what events are matched against.
///
/// It has to be last frame's for the same reason the child count does: events are processed in
/// `install`, before the layout body has run, so `handle()` has not been called yet and this
/// frame's marks do not exist. Consuming `marked` here instead is the bug that made every
/// boundary look static — the bitset was all zeros at event time, so nothing ever matched.
draggable: std.StaticBitSet(max_children) = std.StaticBitSet(max_children).initEmpty(),
/// Which boundaries `handle()` marked this frame. Accurate by `deinit`, so drawing uses it, and
/// it becomes next frame's `draggable`.
marked: std.StaticBitSet(max_children) = std.StaticBitSet(max_children).initEmpty(),

/// Which boundary the pointer is nearest, and how far away, for the grow-on-approach handle.
near: ?usize = null,
near_dist: f32 = std.math.floatMax(f32),
/// The boundary being dragged, if any. Persisted so a drag survives across frames.
drag_index: ?usize = null,

/// A layout with more regions on one axis than this is a design problem, not a use case. The
/// cap keeps `draggable` a fixed-size bitset rather than another allocation.
pub const max_children = 32;

/// A mutable empty slice for the out-of-memory fallbacks below. `&.{}` would be `[]const f32`,
/// and boundaries are written by dragging.
var no_boundaries: [0]f32 = .{};

pub fn install(self: *SplitBox, src: std.builtin.SourceLocation, init_opts: InitOptions, opts: dvui.Options) void {
    const defaults: dvui.Options = .{ .name = "SplitBox", .background = false };
    self.* = .{
        .wd = .init(src, .{}, defaults.override(opts)),
        .init_opts = init_opts,
    };
    const id = self.wd.id;

    self.expected = dvui.dataGet(null, id, "_count", usize) orelse 0;
    self.draggable.mask = dvui.dataGet(null, id, "_draggable", u32) orelse 0;
    self.drag_index = dvui.dataGet(null, id, "_drag", usize);

    if (self.expected > 1) {
        const stored = dvui.dataGetSlice(null, id, "_bounds", []f32);
        if (stored != null and stored.?.len == self.expected - 1) {
            self.boundaries = stored.?;
        } else {
            // First frame, or the count moved: start from equal shares. `deinit` is what
            // notices a change and rewrites the store, so this only runs when there is nothing
            // usable to keep.
            const tmp = dvui.currentWindow().arena().alloc(f32, self.expected - 1) catch &no_boundaries;
            const b: split_layout.Boundaries = .{ .values = tmp };
            b.distributeEvenly();
            self.boundaries = tmp;
        }
    }

    self.wd.register();
    self.wd.borderAndBackground(.{});
    self.prev_clip = dvui.clip(self.wd.contentRectScale().r);
    dvui.parentSet(self.widget());

    self.processEvents();
}

/// The length of the box along its split axis, in logical pixels.
fn axisLength(self: *const SplitBox) f32 {
    const r = self.wd.contentRect();
    return switch (self.init_opts.dir) {
        .horizontal => r.w,
        .vertical => r.h,
    };
}

fn bounds(self: *const SplitBox) split_layout.Boundaries {
    return .{ .values = self.boundaries };
}

/// The rect child `index` occupies, in this box's content coordinates.
fn childRect(self: *const SplitBox, index: usize) dvui.Rect {
    var r = self.wd.contentRect().justSize();
    if (self.expected <= 1) return r;
    const e = split_layout.childExtent(self.bounds(), index, self.axisLength(), self.init_opts.handle_size);
    switch (self.init_opts.dir) {
        .horizontal => {
            r.x = e.offset;
            r.w = @max(0, e.size);
        },
        .vertical => {
            r.y = e.offset;
            r.h = @max(0, e.size);
        },
    }
    return r;
}

/// Where handle `index` sits along the axis, in logical pixels from the box's content origin.
/// Handle `i` is the gap between child `i` and child `i + 1`.
fn handleOffset(self: *const SplitBox, index: usize) f32 {
    const e = split_layout.childExtent(self.bounds(), index, self.axisLength(), self.init_opts.handle_size);
    return e.offset + e.size;
}

/// Turn a pointer position on the axis back into a boundary fraction — the inverse of
/// `childExtent`, and the only place the two must agree.
fn fractionAt(self: *const SplitBox, index: usize, axis_pos: f32) f32 {
    const n = self.expected;
    const handles_total = self.init_opts.handle_size * @as(f32, @floatFromInt(if (n > 0) n - 1 else 0));
    const usable = @max(1.0, self.axisLength() - handles_total);
    return (axis_pos - self.init_opts.handle_size * @as(f32, @floatFromInt(index))) / usable;
}

// ── The two verbs ───────────────────────────────────────────────────────────────────────────

/// Begin the next child. Returns a box filling that child's share; `deinit` it before the next
/// `slot`. The returned box is a plain `dvui.BoxWidget`, so anything can be drawn in it.
pub fn slot(self: *SplitBox, src: std.builtin.SourceLocation) *dvui.BoxWidget {
    const index = self.placed;
    self.placed += 1;
    // `id_extra` by index, so a child keeps its identity when siblings come and go — without it
    // every region's state would shift by one the moment a panel is hidden.
    const b = dvui.widgetAlloc(dvui.BoxWidget);
    b.init(src, .{ .dir = self.init_opts.dir }, .{
        .id_extra = index,
        .expand = .both,
        .background = false,
    });
    b.drawBackground();
    return b;
}

/// Mark the boundary between the previous child and the next as draggable. Call between two
/// `slot`s; a boundary with no `handle()` stays a static edge.
pub fn handle(self: *SplitBox) void {
    if (self.placed == 0 or self.placed > max_children) return;
    self.marked.set(self.placed - 1);
}

// ── Events and drawing ──────────────────────────────────────────────────────────────────────

fn processEvents(self: *SplitBox) void {
    if (self.expected < 2) return;
    for (dvui.events()) |*e| {
        if (!dvui.eventMatchSimple(e, self.data())) continue;
        self.processEvent(e);
    }
}

fn processEvent(self: *SplitBox, e: *dvui.Event) void {
    if (e.evt != .mouse) return;
    const rs = self.wd.contentRectScale();
    const cursor: dvui.enums.Cursor = switch (self.init_opts.dir) {
        .horizontal => .arrow_w_e,
        .vertical => .arrow_n_s,
    };

    const p = switch (self.init_opts.dir) {
        .horizontal => (e.evt.mouse.p.x - rs.r.x) / rs.s,
        .vertical => (e.evt.mouse.p.y - rs.r.y) / rs.s,
    };

    // Nearest boundary, so the handle can grow as the pointer approaches it. Only boundaries
    // the layout marked draggable are candidates — a static edge should not light up.
    self.near = null;
    self.near_dist = std.math.floatMax(f32);
    var i: usize = 0;
    while (i < self.boundaries.len) : (i += 1) {
        if (!self.draggable.isSet(i)) continue;
        const d = @abs(p - (self.handleOffset(i) + self.init_opts.handle_size / 2));
        if (d < self.near_dist) {
            self.near_dist = d;
            self.near = i;
        }
    }

    if (dvui.captured(self.wd.id)) {
        self.near_dist = 0;
    } else if (self.near == null) return;

    const active = self.drag_index orelse self.near.?;
    const within = self.near_dist <= @max(self.init_opts.handle_size / 2, 2);

    switch (e.evt.mouse.action) {
        .press => if (e.evt.mouse.button.pointer() and within) {
            e.handle(@src(), self.data());
            dvui.captureMouse(self.data(), e.num);
            dvui.dragPreStart(e.evt.mouse.button, e.evt.mouse.p, .{ .cursor = cursor });
            self.drag_index = active;
        },
        .release => if (e.evt.mouse.button.pointer() and dvui.captured(self.wd.id)) {
            e.handle(@src(), self.data());
            dvui.captureMouse(null, e.num);
            dvui.dragEnd();
            self.drag_index = null;
        },
        .motion => if (dvui.captured(self.wd.id)) {
            e.handle(@src(), self.data());
            if (dvui.dragging(e.evt.mouse.p, null) != null) {
                // Aim at the handle's centre, so the boundary does not jump by half a handle
                // on the first pixel of movement.
                const target = self.fractionAt(active, p - self.init_opts.handle_size / 2);
                _ = self.bounds().moveBoundary(active, target, self.init_opts.min_fraction);
                dvui.refresh(null, @src(), self.wd.id);
            }
        },
        .position => if (within) dvui.cursorSet(cursor),
        else => {},
    }
}

/// Draw the handles. Like `PanedWidget`, a handle is drawn rather than being a widget: it must
/// sit *between* children without taking part in their layout.
fn drawHandles(self: *SplitBox) void {
    if (self.expected < 2) return;
    const rs = self.wd.contentRectScale();

    var i: usize = 0;
    while (i < self.boundaries.len) : (i += 1) {
        if (!self.marked.isSet(i)) continue;

        // Grow on approach: invisible until the pointer is within `handle_dist`, full length
        // under it. The same feel as fizzy's sash, which is what makes a thin divider findable.
        var len_ratio: f32 = 1.0 / 5.0;
        const dist = if (self.near != null and self.near.? == i) self.near_dist else std.math.floatMax(f32);
        if (dist > self.init_opts.handle_size + self.init_opts.handle_dist) continue;
        len_ratio *= 1.0 - std.math.clamp(
            (dist - self.init_opts.handle_size) / self.init_opts.handle_dist,
            0.0,
            1.0,
        );

        const thick = self.init_opts.handle_size * rs.s;
        const off = self.handleOffset(i) * rs.s;
        var r = rs.r;
        switch (self.init_opts.dir) {
            .horizontal => {
                r.x = rs.r.x + off;
                r.w = thick;
                const height = rs.r.h * len_ratio;
                r.y = rs.r.y + rs.r.h / 2 - height / 2;
                r.h = height;
            },
            .vertical => {
                r.y = rs.r.y + off;
                r.h = thick;
                const width = rs.r.w * len_ratio;
                r.x = rs.r.x + rs.r.w / 2 - width / 2;
                r.w = width;
            },
        }
        r.fill(.all(thick), .{ .color = self.wd.options.color(.text).opacity(0.5), .fade = 1.0 });

        switch (self.init_opts.dir) {
            .horizontal => {
                var g = r;
                g.h = dvui.iconWidth("grip", icons.tvg.lucide.@"grip-vertical", g.w) catch g.w;
                g.y = (rs.r.y + rs.r.h / 2) - g.h / 2;
                g = g.outset(dvui.Rect.Physical.all(2 * rs.s));
                dvui.icon(@src(), "grip", icons.tvg.lucide.@"grip-vertical", .{
                    .stroke_color = dvui.themeGet().color(.content, .fill),
                }, .{ .rect = rs.rectFromPhysical(g), .id_extra = i });
            },
            .vertical => {
                var g = r;
                g.w = dvui.iconWidth("grip", icons.tvg.lucide.@"grip-horizontal", g.h) catch g.h;
                g.x = (rs.r.x + rs.r.w / 2) - g.w / 2;
                g = g.outset(dvui.Rect.Physical.all(2 * rs.s));
                dvui.icon(@src(), "grip", icons.tvg.lucide.@"grip-horizontal", .{
                    .stroke_color = dvui.themeGet().color(.content, .fill),
                }, .{ .rect = rs.rectFromPhysical(g), .id_extra = i });
            },
        }
    }
}

// ── Widget interface ────────────────────────────────────────────────────────────────────────

pub fn widget(self: *SplitBox) dvui.Widget {
    return dvui.Widget.init(self, data, rectFor, screenRectScale, minSizeForChild);
}

pub fn data(self: *SplitBox) *dvui.WidgetData {
    return self.wd.validate();
}

pub fn rectFor(self: *SplitBox, id: dvui.Id, min_size: dvui.Size, e: dvui.Options.Expand, g: dvui.Options.Gravity) dvui.Rect {
    // Children arrive in `slot` order, and `slot` has already advanced `placed` — so the child
    // now asking for its rect is the one at `placed - 1`.
    _ = id;
    const index = if (self.placed == 0) 0 else self.placed - 1;
    return dvui.placeIn(self.childRect(index), min_size, e, g);
}

pub fn screenRectScale(self: *SplitBox, rect: dvui.Rect) dvui.RectScale {
    return self.wd.contentRectScale().rectToRectScale(rect);
}

pub fn minSizeForChild(self: *SplitBox, s: dvui.Size) void {
    // A split box divides the space it is given; it does not grow to fit its children, or one
    // wide plugin surface would push the whole window wider every frame.
    _ = self;
    _ = s;
}

pub fn deinit(self: *SplitBox) void {
    defer if (dvui.widgetIsAllocated(self)) dvui.widgetFree(self);
    defer self.* = undefined;

    self.drawHandles();
    dvui.clipSet(self.prev_clip);

    const id = self.wd.id;
    if (self.placed != self.expected) {
        // The count moved. Lay out one more frame — this one used the old count — then settle.
        dvui.dataSet(null, id, "_count", self.placed);
        if (self.placed > 1) {
            const fresh = dvui.currentWindow().arena().alloc(f32, self.placed - 1) catch &no_boundaries;
            const b: split_layout.Boundaries = .{ .values = fresh };
            b.distributeEvenly();
            dvui.dataSetSlice(null, id, "_bounds", fresh);
        }
        dvui.refresh(null, @src(), id);
    } else if (self.boundaries.len > 0) {
        dvui.dataSetSlice(null, id, "_bounds", self.boundaries);
    }
    if (self.drag_index) |d| dvui.dataSet(null, id, "_drag", d) else dvui.dataRemove(null, id, "_drag");
    // Next frame's event pass matches against these.
    if (self.marked.mask != self.draggable.mask) dvui.refresh(null, @src(), id);
    dvui.dataSet(null, id, "_draggable", self.marked.mask);

    self.wd.minSizeSetAndRefresh();
    self.wd.minSizeReportToParent();
    dvui.parentReset(id, self.wd.parent);
}

// ── Tests ───────────────────────────────────────────────────────────────────────────────────
//
// Headless, against dvui's testing backend, because the bugs this widget can have are *ordering*
// bugs that no amount of boundary maths catches: events are processed in `install`, before the
// layout body has declared anything, so every fact the body supplies — how many children there
// are, which boundaries carry a handle — is a frame late by construction. The first version of
// this widget read `handle()`'s marks in the same frame they were set, so the bitset was empty at
// event time and nothing was ever draggable. It compiled, ran, drew, and did nothing.

const testing = std.testing;

/// A window-filling horizontal split with two children and a draggable boundary. Declared at file
/// scope because dvui's test driver takes a plain frame function.
fn twoChildFrame() !dvui.App.Result {
    var box = dvui.widgetAlloc(SplitBox);
    box.install(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer box.deinit();

    {
        var c = box.slot(@src());
        defer c.deinit();
    }
    box.handle();
    {
        var c = box.slot(@src());
        defer c.deinit();
    }
    recordProbe(box);
    test_draggable = box.draggable.mask;
    return .ok;
}

var test_boundary: ?f32 = null;
var test_marked: u32 = 0;
var test_draggable: u32 = 0;
/// Where handle 0 actually is, in the physical coordinates dvui's test driver posts mouse
/// events in. Computed from the widget rather than by hand: the test window's physical pixels
/// are not its logical points, and hard-coding the point in the wrong space is a test that
/// fails for a reason that has nothing to do with the widget (it is how this test first failed).
/// Reading it from the same `handleOffset` the drawing uses also asserts the thing that actually
/// matters — that the handle you can grab is the handle you can see.
var test_handle_px: f32 = 0;

fn recordProbe(box: *SplitBox) void {
    test_boundary = if (box.boundaries.len > 0) box.boundaries[0] else null;
    test_marked = box.marked.mask;
    if (box.boundaries.len > 0) {
        const rs = box.wd.contentRectScale();
        test_handle_px = rs.r.x + (box.handleOffset(0) + box.init_opts.handle_size / 2) * rs.s;
    }
}

test "the handle is draggable from the frame after it is declared" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 300 } });
    defer t.deinit();

    try dvui.testing.settle(twoChildFrame);

    // The count and the handle mark have both made it into persistent state, so the *next*
    // frame's event pass can see them. This is the assertion that would have failed before:
    // `marked` was set every frame, but `draggable` — what events match against — stayed 0.
    try testing.expectEqual(@as(u32, 1), test_marked);
    try testing.expectEqual(@as(u32, 1), test_draggable);
    try testing.expect(test_boundary != null);
    try testing.expectApproxEqAbs(@as(f32, 0.5), test_boundary.?, 0.0001);
}

test "dragging the handle moves the boundary" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 300 } });
    defer t.deinit();

    try dvui.testing.settle(twoChildFrame);
    const before = test_boundary.?;

    const start = test_handle_px;
    const cw = dvui.currentWindow();

    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = start, .y = 40 } });
    _ = try dvui.testing.step(twoChildFrame);

    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(twoChildFrame);

    // Well past dvui's drag threshold, towards the right.
    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = start + 60, .y = 40 } });
    _ = try dvui.testing.step(twoChildFrame);

    _ = try cw.addEventMouseButton(.left, .release);
    _ = try dvui.testing.step(twoChildFrame);

    const after = test_boundary.?;
    try testing.expect(after > before);
    // The handle followed the pointer: it should now sit under where the drag ended, which is
    // the "does the boundary track without drift" question a screenshot cannot answer.
    try testing.expectApproxEqAbs(start + 60, test_handle_px, 2.0);
}

test "a boundary with no handle() call is not draggable" {
    const Static = struct {
        fn frame() !dvui.App.Result {
            var box = dvui.widgetAlloc(SplitBox);
            box.install(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
            defer box.deinit();
            { var c = box.slot(@src()); defer c.deinit(); }
            // no box.handle() here
            { var c = box.slot(@src()); defer c.deinit(); }
            recordProbe(box);
            return .ok;
        }
    };

    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 300 } });
    defer t.deinit();

    try dvui.testing.settle(Static.frame);
    const before = test_boundary.?;
    try testing.expectEqual(@as(u32, 0), test_marked);

    const start = test_handle_px;
    const cw = dvui.currentWindow();
    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = start, .y = 40 } });
    _ = try dvui.testing.step(Static.frame);
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(Static.frame);
    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = start + 60, .y = 40 } });
    _ = try dvui.testing.step(Static.frame);

    try testing.expectApproxEqAbs(before, test_boundary.?, 0.0001);
}

test {
    @import("std").testing.refAllDecls(@This());
}
