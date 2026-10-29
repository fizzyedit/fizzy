//! A scrolling list of rows of different heights that draws only the rows in view, over
//! `HeightIndex`.
//!
//!     var list = core.widgets.VirtualList.init(@src(), .{
//!         .state = &self.list,         // a `State`, kept by the caller
//!         .count = n,
//!         .ctx = self,
//!         .key = keyAt,                // stable across prepends, e.g. a message id
//!         .estimate = estimateAt,      // a guess at a row's height, until it is measured
//!         .follow_end = true,          // a reader at the bottom stays there as rows arrive
//!     }, .{ .expand = .both });
//!     defer list.deinit();
//!     while (list.next()) |i| {        // the rows in view plus overscan, in order
//!         var row = list.row(i);       // a box; its size is the measurement
//!         defer row.deinit();
//!         drawMessage(i);
//!     }
//!     if (list.nearStart()) requestOlder();
//!
//! The scroll position is an `Anchor` (a row's key and an offset into it), so rows prepended or
//! measured above the reader, and a change of width, never move what is being read, not even for
//! the frame a row is first drawn: each row is laid out at the height the index holds for it.
//!
//! It holds only the rows it is given. dvui clamps every size at `dvui.max_float_safe` (2e6), so
//! the rows' total height must stay under that (about 25,000 rows of 80 px); a longer history is
//! given in pages, not whole.

const std = @import("std");
const dvui = @import("dvui");
const HeightIndex = @import("../HeightIndex.zig");
const ScrollArea = @import("ScrollArea.zig");

const VirtualList = @This();

/// What outlives a frame. The caller owns it: `State.init(gpa)` once, `deinit` when the list is
/// gone.
pub const State = struct {
    gpa: std.mem.Allocator,
    index: HeightIndex = .{},
    si: dvui.ScrollInfo = .{},
    /// Where the reader is, as a row. Null until the first frame, or when its row is gone.
    anchor: ?HeightIndex.Anchor = null,
    /// Whether the view shows the end of the rows, so `follow_end` keeps it there.
    pinned: bool = true,
    /// The viewport's top as this frame put it, to tell the reader's scrolling from our own.
    frame_y: f32 = 0,

    pub fn init(gpa: std.mem.Allocator) State {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *State) void {
        self.index.deinit(self.gpa);
        self.* = undefined;
    }

    /// Puts the row with `key` at the top of the view from the next frame; a key not in the list
    /// does nothing. Requires a current dvui window (between `Window.begin` and `Window.end`).
    pub fn scrollTo(self: *State, key: u64) void {
        if (self.index.indexOf(key) == null) return;
        self.anchor = .{ .key = key, .offset = 0 };
        self.pinned = false;
        dvui.refresh(null, @src(), null);
    }
};

pub const InitOptions = struct {
    state: *State,
    count: usize,
    ctx: *anyopaque,
    key: *const fn (ctx: *anyopaque, index: usize) u64,
    /// A guess at a row's height at `width`, used until the row is drawn. An exact estimate is
    /// never replaced.
    estimate: *const fn (ctx: *anyopaque, index: usize, width: f32) f32,
    /// A number that changes whenever the rows do (a version counter, say). While it holds, the
    /// list trusts that the rows are as they were and does not ask for every key each frame. Null
    /// asks for every key each frame: right for a short list, costly for 20,000 rows.
    revision: ?u64 = null,
    /// Keep the view on the last row while the reader is at the bottom.
    follow_end: bool = false,
    /// Pixels drawn beyond each edge of the view. dvui forgets a widget's size when it goes
    /// undrawn, so a row must be drawn before it scrolls into view.
    overscan: f32 = 200,
};

/// The height assumed for the view on the first frame, before the scroll area has one.
const first_frame_height: f32 = 600;
/// The width assumed for estimates before the scroll area has a viewport.
const first_frame_width: f32 = 400;

/// A reader within this many viewport heights of the first row is near the start.
const near_start_views: f32 = 1;

scroll: ScrollArea,
opts: InitOptions,
range: ?HeightIndex.Range,
next_index: usize,
view_h: f32,
trail_drawn: bool = false,
/// A measurement moved a row's height, so the next frame places rows differently.
measured_change: bool = false,

pub fn init(src: std.builtin.SourceLocation, opts: InitOptions, widget_opts: dvui.Options) VirtualList {
    const st = opts.state;
    const source: HeightIndex.Source = .{ .ctx = opts.ctx, .key = opts.key, .estimate = opts.estimate };

    const width = if (st.si.viewport.w > 0) st.si.viewport.w else first_frame_width;
    const view_h = if (st.si.viewport.h > 0) st.si.viewport.h else first_frame_height;
    var count = opts.count;
    st.index.reconcile(st.gpa, source, count, width, opts.revision) catch |err| {
        // The rows are the caller's, and the index does not match them: draw none.
        dvui.log.err("VirtualList: {t} while reconciling {d} rows", .{ err, count });
        count = 0;
    };

    const total = @min(st.index.total(), dvui.max_float_safe);
    st.si.virtual_size.h = total;
    const y = if (opts.follow_end and st.pinned)
        st.index.endY(view_h)
    else if (st.anchor) |a| st.index.resolve(a) orelse st.frame_y else st.frame_y;
    st.si.scrollToOffset(.vertical, y);
    st.frame_y = st.si.viewport.y;

    var self: VirtualList = .{
        .scroll = ScrollArea.init(src, .{ .scroll_info = &st.si, .horizontal = .none }, widget_opts),
        .opts = opts,
        .range = if (count == 0) null else st.index.visibleRange(st.frame_y, view_h, opts.overscan),
        .next_index = 0,
        .view_h = view_h,
    };
    if (self.range) |r| {
        self.next_index = r.first;
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 0, .h = @min(st.index.yAt(r.first), dvui.max_float_safe) } });
    }
    return self;
}

pub fn deinit(self: *VirtualList) void {
    const st = self.opts.state;
    self.drawTrail();
    const id = self.scroll.data().id;
    self.scroll.deinit();

    // Anything but our own placement is the reader scrolling, however small a step (a slow coast
    // moves a fraction of a pixel a frame): carry the move over to the row the reader was on,
    // whose place the measurements above it may just have changed.
    const moved = st.si.viewport.y - st.frame_y;
    if (moved != 0) {
        const from = if (st.anchor) |a| st.index.resolve(a) orelse st.frame_y else st.frame_y;
        st.anchor = st.index.anchorAt(from + moved);
        st.pinned = st.index.atEnd(st.si.viewport.y, st.si.viewport.h);
    } else if (st.anchor == null) {
        st.anchor = st.index.anchorAt(st.frame_y);
    }
    if (self.measured_change) dvui.refresh(null, @src(), id);
}

/// The next row to draw, or null after the last.
pub fn next(self: *VirtualList) ?usize {
    if (self.range) |r| if (self.next_index < r.end) {
        defer self.next_index += 1;
        return self.next_index;
    };
    self.drawTrail();
    return null;
}

/// The box for row `index` as `next` gave it. Its size, once deinitialized, is the row's
/// measurement.
pub fn row(self: *VirtualList, index: usize) Row {
    const idx = &self.opts.state.index;
    const h = idx.heightAt(index);
    // dvui lays a box out at last frame's min size, and caps that at the max: pinning both to the
    // index's height places the row where the index does, whatever it measured last.
    const outer = dvui.box(@src(), .{}, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 0, .h = h },
        .max_size_content = .height(h),
        // Hash both halves before narrowing to the target's widget-id extra.
        .id_extra = @truncate(std.hash.Wyhash.hash(0, std.mem.asBytes(&idx.keys.items[index]))),
    });
    // The box records its min size in `deinit`, so opening it leaves `firstFrame` as it was.
    const inner = dvui.box(@src(), .{}, .{ .expand = .horizontal });
    return .{
        .list = self,
        .index = index,
        .outer = outer,
        .box = inner,
        .first_frame = dvui.firstFrame(inner.data().id),
    };
}

/// One row's box. `deinit` hands the inner box's natural size back to the index as the row's
/// measurement.
pub const Row = struct {
    list: *VirtualList,
    index: usize,
    outer: *dvui.BoxWidget,
    /// The box the caller draws into; its size is the measurement, whatever the outer box is
    /// pinned to.
    box: *dvui.BoxWidget,
    first_frame: bool,

    pub fn deinit(self: *Row) void {
        const id = self.box.data().id;
        self.box.deinit();
        self.outer.deinit();
        // The box has put its natural size, margins included, where dvui keeps min sizes.
        const size = dvui.minSizeGet(id) orelse return;
        const index = &self.list.opts.state.index;
        // A first-frame size never replaces a measurement.
        if (self.first_frame and index.stateAt(self.index) == .measured) return;
        if (index.record(self.index, size.h)) self.list.measured_change = true;
    }
};

/// Whether the reader is within a view of the first row you have, so older rows should be asked
/// for. It stays true until they arrive: ask once, not once per frame.
pub fn nearStart(self: *const VirtualList) bool {
    return self.opts.state.frame_y <= self.view_h * near_start_views;
}

fn drawTrail(self: *VirtualList) void {
    if (self.trail_drawn) return;
    self.trail_drawn = true;
    const index = &self.opts.state.index;
    const r = self.range orelse return;
    const below = @max(0, index.total() - index.yAt(r.end));
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 0, .h = @min(below, dvui.max_float_safe) } });
}

const testing = std.testing;

/// Messages numbered from `first_id`, each `1 + id % 4` lines tall, estimated at three.
const Messages = struct {
    first_id: u64 = 0,
    /// The gap between neighbouring keys.
    stride: u64 = 1,
    count: usize = 0,
    follow_end: bool = false,
    /// Pixels the reader scrolls in the next frame.
    nudge: f32 = 0,
    state: State = State.init(testing.allocator),
    drawn: usize = 0,
    /// The first row whose top is on screen, and where.
    top_key: u64 = 0,
    top_y: f32 = 0,
    /// The dvui id of the first rows' boxes in the last frame.
    box_ids: [2]dvui.Id = undefined,
    /// Draws a row one line shorter on the first frame its box exists, as text does before it
    /// wraps.
    short_first: bool = false,
    /// A key to follow, and where its row's top was in the last frame (null when undrawn).
    track_key: u64 = 0,
    track_y: ?f32 = null,

    const line_h = 20;

    fn lines(id: u64) usize {
        return 1 + id % 4;
    }

    fn key(ctx: *anyopaque, i: usize) u64 {
        const self: *Messages = @ptrCast(@alignCast(ctx));
        return self.first_id + i * self.stride;
    }

    fn estimate(_: *anyopaque, _: usize, _: f32) f32 {
        return 3 * line_h;
    }

    fn frame(self: *Messages) !dvui.App.Result {
        var list = VirtualList.init(@src(), .{
            .state = &self.state,
            .count = self.count,
            .ctx = self,
            .key = key,
            .estimate = estimate,
            .follow_end = self.follow_end,
        }, .{ .expand = .both });
        defer list.deinit();
        self.drawn = 0;
        self.top_y = std.math.floatMax(f32);
        self.track_y = null;
        while (list.next()) |i| {
            var r = list.row(i);
            defer r.deinit();
            if (self.drawn < self.box_ids.len) self.box_ids[self.drawn] = r.box.data().id;
            self.drawn += 1;
            const id = self.first_id + i * self.stride;
            const short = self.short_first and r.first_frame;
            for (0..lines(id) - @intFromBool(short)) |l| _ = dvui.spacer(@src(), .{ .id_extra = l, .min_size_content = .{ .w = 10, .h = line_h } });
            const rs = r.box.data().rectScale();
            const top = rs.r.y / rs.s;
            if (top >= 0 and top < self.top_y) {
                self.top_y = top;
                self.top_key = id;
            }
            if (id == self.track_key) self.track_y = top;
        }
        // What the scroll area does with wheel and touch input, before the list is deinitialized.
        self.state.si.viewport.y += self.nudge;
        return .ok;
    }
};

var current: *Messages = undefined;

fn currentFrame() !dvui.App.Result {
    return current.frame();
}

fn settleOn(m: *Messages) !void {
    current = m;
    try dvui.testing.settle(currentFrame);
    // The settle ends once nothing asks for a frame; a measurement moved after it still
    // places rows on the next, so take a few more.
    for (0..3) |_| _ = try dvui.testing.step(currentFrame);
}

test "twenty thousand rows draw a screenful and size the scroll range from the index" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    var m: Messages = .{ .count = 20_000 };
    defer m.state.deinit();
    try settleOn(&m);
    try testing.expect(m.drawn > 0);
    try testing.expect(m.drawn < 40);
    try testing.expectApproxEqAbs(m.state.index.total(), m.state.si.virtual_size.h, 1);

    // Jump to the middle: still a screenful, and the same row is on top after it settles.
    m.state.anchor = .{ .key = 10_000, .offset = 0 };
    m.state.pinned = false;
    try settleOn(&m);
    try testing.expect(m.drawn < 40);
    try testing.expectEqual(@as(u64, 10_000), m.top_key);
}

test "500 rows prepended above the reader leave the row they read where it was" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    var m: Messages = .{ .first_id = 1000, .count = 2000 };
    defer m.state.deinit();
    try settleOn(&m);
    m.state.anchor = .{ .key = 2000, .offset = 0 };
    m.state.pinned = false;
    try settleOn(&m);
    const key_before = m.top_key;
    const y_before = m.top_y;
    try testing.expectEqual(@as(u64, 2000), key_before);

    m.first_id -= 500;
    m.count += 500;
    try settleOn(&m);
    try testing.expectEqual(key_before, m.top_key);
    try testing.expectApproxEqAbs(y_before, m.top_y, 0.5);
}

test "State.scrollTo puts a row at the top, and an unknown key does nothing" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    var m: Messages = .{ .count = 500 };
    defer m.state.deinit();
    try settleOn(&m);
    m.state.scrollTo(300);
    try testing.expect(!m.state.pinned);
    try settleOn(&m);
    try testing.expectEqual(@as(u64, 300), m.top_key);

    m.state.scrollTo(99_999);
    try settleOn(&m);
    try testing.expectEqual(@as(u64, 300), m.top_key);
}

test "a scroll of a fraction of a pixel accumulates instead of being put back" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    var m: Messages = .{ .count = 500 };
    defer m.state.deinit();
    try settleOn(&m);
    m.state.scrollTo(100);
    try settleOn(&m);
    const start = m.state.si.viewport.y;
    for (0..10) |_| {
        m.nudge = 0.2;
        _ = try dvui.testing.step(currentFrame);
    }
    m.nudge = 0;
    try testing.expectApproxEqAbs(start + 2, m.state.si.viewport.y, 0.05);
}

test "follow_end holds the last row at the bottom as rows are appended" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    var m: Messages = .{ .count = 100, .follow_end = true };
    defer m.state.deinit();
    try settleOn(&m);
    for (0..10) |_| {
        m.count += 3;
        try settleOn(&m);
        const si = &m.state.si;
        try testing.expectApproxEqAbs(si.virtual_size.h, si.viewport.y + si.viewport.h, 1);
    }
}

test "keys that differ only above 32 bits draw boxes with distinct ids" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    var m: Messages = .{ .first_id = 1, .count = 2 };
    defer m.state.deinit();
    // Exercise truncation and XOR-fold collision pairs, including 32-bit id extras on any host.
    for ([_]u64{ 1 << 32, (1 << 32) - 1 }) |stride| {
        m.stride = stride;
        const a: u64 = 1;
        const b = a + stride;
        const a_extra: u32 = @truncate(std.hash.Wyhash.hash(0, std.mem.asBytes(&a)));
        const b_extra: u32 = @truncate(std.hash.Wyhash.hash(0, std.mem.asBytes(&b)));
        try testing.expect(a_extra != b_extra);
        try settleOn(&m);
        try testing.expect(m.drawn >= 2);
        try testing.expect(m.box_ids[0] != m.box_ids[1]);
    }
}

test "scrolling up through rows that measure short on their first frame never moves the reader's row" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    var m: Messages = .{ .count = 2000, .short_first = true };
    defer m.state.deinit();
    try settleOn(&m);
    m.state.scrollTo(1800);
    try settleOn(&m);

    const step = 7;
    var tracking = false;
    var last_y: f32 = 0;
    for (0..20 * 400 / step) |frame_no| {
        m.nudge = -step;
        _ = try dvui.testing.step(currentFrame);
        if (tracking) {
            if (m.track_y) |y| {
                if (@abs(y - (last_y + step)) > 1) {
                    std.debug.print("frame {d}: key {d} top {d} after {d}\n", .{ frame_no, m.track_key, y, last_y });
                    return error.ReaderMoved;
                }
                last_y = y;
            }
        }
        // Follow the row at the top until it leaves the view, then the one now at the top.
        if (!tracking or m.track_y == null or m.track_y.? >= 400) {
            m.track_key = m.top_key;
            last_y = m.top_y;
            tracking = true;
        }
    }
}
