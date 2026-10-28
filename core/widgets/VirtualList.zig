//! A variable-height, keyed list. Only the viewport and overscan rows are drawn.
//! Keep `State` with the document; each frame pairs `init` with `deinit`, and each
//! `row` with `Row.deinit`. Supply unique keys and change `revision` when rows change.
//! The caller pages data before its total height exceeds dvui's 2e6 point limit.
const std = @import("std");
const dvui = @import("dvui");
const HeightIndex = @import("../HeightIndex.zig");
const ScrollArea = @import("ScrollArea.zig");

const VirtualList = @This();

pub const State = struct {
    heights: HeightIndex = .{},
    scroll: dvui.ScrollInfo = .{ .vertical = .given },
    anchor: ?HeightIndex.Anchor = null,
    following: bool = true,
    pending_key: ?u64 = null,

    /// Frees persistent heights using the allocator passed to `init`.
    pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
        self.heights.deinit(gpa);
        self.* = undefined;
    }

    /// Requests that a key's row start at the viewport top on the next frame.
    /// A missing key leaves the reading position unchanged.
    pub fn scrollTo(self: *State, key: u64) void {
        self.pending_key = key;
    }
};

pub const Options = struct {
    source: HeightIndex.Source,
    count: usize,
    /// Unchanged revisions skip the O(n) key comparison. Null compares every key.
    revision: ?u64 = null,
    /// Points drawn beyond each edge, so returning rows regain dvui's cached sizes.
    overscan: f32 = 200,
    follow_end: bool = false,
    near_start: f32 = 200,
};

state: *State,
opts: Options,
area: ScrollArea,
cursor: usize,
end: usize,
following: bool,

/// Opens a list in the current dvui frame. `state` and `source.ctx` must outlive it.
/// Allocation failure leaves the persistent height index usable.
pub fn init(src: std.lang.SourceLocation, gpa: std.mem.Allocator, state: *State, opts: Options, outer: dvui.Options) !VirtualList {
    const previous_y = state.scroll.viewport.y;
    var area = ScrollArea.init(src, .{
        .scroll_info = &state.scroll,
        .vertical_bar = .auto_overlay,
    }, outer);
    errdefer area.deinit();
    if (state.scroll.viewport.y != previous_y) {
        state.anchor = state.heights.anchorAt(state.scroll.viewport.y);
        state.following = state.heights.atEnd(state.scroll.viewport.y, state.scroll.viewport.h);
    }
    const following = opts.follow_end and state.following;
    try state.heights.reconcile(gpa, opts.source, opts.count, state.scroll.viewport.w, opts.revision);
    if (state.pending_key) |key| {
        if (state.heights.indexOf(key) != null) {
            state.anchor = .{ .key = key, .offset = 0 };
            state.following = false;
        }
        state.pending_key = null;
    }
    var self: VirtualList = .{
        .state = state,
        .opts = opts,
        .area = area,
        .cursor = 0,
        .end = 0,
        .following = following and state.following,
    };
    self.position();
    // An empty/deleted anchor picks the nearest surviving row at the current offset.
    state.anchor = state.heights.anchorAt(state.scroll.viewport.y);
    if (state.heights.visibleRange(state.scroll.viewport.y, state.scroll.viewport.h, opts.overscan)) |range| {
        self.cursor = range.first;
        self.end = range.end;
    }
    return self;
}

fn position(self: *VirtualList) void {
    const state = self.state;
    state.scroll.virtual_size.h = @min(state.heights.total(), dvui.max_float_safe);
    if (self.following) {
        state.scroll.viewport.y = state.heights.endY(state.scroll.viewport.h);
    } else if (state.anchor) |anchor| {
        if (state.heights.resolve(anchor)) |y| state.scroll.viewport.y = y;
    }
    state.scroll.viewport.y = std.math.clamp(state.scroll.viewport.y, 0, state.scroll.scrollMax(.vertical));
    // The container freezes its viewport at init; compensation must precede child drawing.
    self.area.area.scroll.?.frame_viewport.y = state.scroll.viewport.y;
}

/// Yields row indices in order. Draw every yielded row before asking for the next.
pub fn next(self: *VirtualList) ?usize {
    if (self.cursor >= self.end) return null;
    const i = self.cursor;
    self.cursor += 1;
    return i;
}

/// Opens the measured vertical box for a yielded row. Children use the host's theme.
/// The returned row must be closed before `next` or `deinit`.
pub fn row(self: *VirtualList, i: usize) Row {
    std.debug.assert(i + 1 == self.cursor);
    self.position();
    const heights = &self.state.heights;
    const box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = dvui.Id.update(.zero, std.mem.asBytes(&heights.keys.items[i])).asUsize(),
        .rect = .{ .x = 0, .y = heights.yAt(i), .w = self.state.scroll.viewport.w, .h = heights.heightAt(i) },
        .margin = .all(0),
        .padding = .all(0),
        .border = .all(0),
        .background = false,
    });
    return .{ .list = self, .index = i, .box = box };
}

pub const Row = struct {
    list: *VirtualList,
    index: usize,
    box: *dvui.BoxWidget,

    /// Closes the box and records the full height requested by its children.
    pub fn deinit(self: *Row) void {
        const id = self.box.data().id;
        self.box.deinit();
        // Box deinit publishes the full child minimum, independent of its allocated rect.
        const height = dvui.minSizeGet(id).?.h;
        if (self.list.state.heights.record(self.index, height)) {
            dvui.refresh(null, @src(), self.list.area.area.data().id);
        }
    }
};

/// Whether the viewport is within `near_start` points of the first supplied row.
pub fn nearStart(self: *const VirtualList) bool {
    return self.state.scroll.viewport.y <= self.opts.near_start;
}

/// Requests a key for the next frame, allowing calls during iteration.
pub fn scrollTo(self: *VirtualList, key: u64) void {
    self.state.scrollTo(key);
    dvui.refresh(null, @src(), self.area.area.data().id);
}

/// Saves the reading anchor after the scroll area's wheel, touch and keyboard events.
pub fn deinit(self: *VirtualList) void {
    self.position();
    self.area.deinit();
    const state = self.state;
    state.anchor = state.heights.anchorAt(state.scroll.viewport.y);
    state.following = state.heights.atEnd(state.scroll.viewport.y, state.scroll.viewport.h);
}

// The sizing test runner invokes frames serially on its test thread.
var fixture: Fixture = .{};
const Fixture = struct {
    state: State = .{},
    first: u64 = 1000,
    count: usize = 2000,
    revision: u64 = 0,
    width: f32 = 300,
    follow: bool = false,
    taller: bool = false,
    watched: u64 = 1900,
    screen_y: ?f32 = null,
    drawn: usize = 0,
    near_start: bool = false,
    demo: bool = false,
    frame_ms: f64 = 0,

    fn key(ctx: *anyopaque, i: usize) u64 {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        return self.first + i;
    }

    fn estimate(_: *anyopaque, _: usize, width: f32) f32 {
        return 40 * 300 / width;
    }
};

fn listFrame() !dvui.App.Result {
    var root = dvui.box(@src(), .{}, .{ .expand = .both });
    defer root.deinit();
    {
        var list = try VirtualList.init(@src(), std.testing.allocator, &fixture.state, .{
            .source = .{ .ctx = &fixture, .key = Fixture.key, .estimate = Fixture.estimate },
            .count = fixture.count,
            .revision = fixture.revision,
            .follow_end = fixture.follow,
        }, .{ .rect = .{ .w = fixture.width, .h = 400 } });
        defer list.deinit();
        fixture.near_start = list.nearStart();
        fixture.screen_y = null;
        fixture.drawn = 0;
        while (list.next()) |i| {
            var item = list.row(i);
            defer item.deinit();
            fixture.drawn += 1;
            if (fixture.first + i == fixture.watched) fixture.screen_y = item.box.data().borderRectScale().r.y;
            if (fixture.demo) {
                dvui.label(@src(), "Row {d} - variable height", .{fixture.first + i}, .{});
            }
            const height: f32 = if (fixture.demo) @floatFromInt(24 + i % 7 * 8) else if (fixture.taller) 65 else 40;
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 10, .h = height } });
        }
    }
    if (fixture.demo) {
        dvui.label(@src(), "20,000 rows | frame {d:.3} ms | drawn {d}", .{ fixture.frame_ms, fixture.drawn }, .{
            .rect = .{ .y = 420, .w = 490, .h = 30 },
            .tag = "virtual-list-frame-time",
        });
    }
    return .ok;
}

fn initFixture() !dvui.testing {
    fixture = .{};
    return dvui.testing.init(.{ .window_size = .{ .w = 500, .h = 500 } });
}

test "virtual list preserves the drawn anchor after 500 prepends and measurements" {
    var t = try initFixture();
    defer t.deinit();
    defer fixture.state.deinit(std.testing.allocator);
    try dvui.testing.settle(listFrame);
    fixture.state.scrollTo(fixture.watched);
    try dvui.testing.settle(listFrame);
    try std.testing.expect(fixture.screen_y != null);
    const before = fixture.screen_y.?;
    fixture.first -= 500;
    fixture.count += 500;
    fixture.revision += 1;
    _ = try dvui.testing.step(listFrame);
    try std.testing.expectApproxEqAbs(before, fixture.screen_y.?, 0.01);
    // Overscan rows above the anchor change height during this frame.
    fixture.taller = true;
    _ = try dvui.testing.step(listFrame);
    try std.testing.expectApproxEqAbs(before, fixture.screen_y.?, 0.01);
    try dvui.testing.settle(listFrame);
    try std.testing.expectApproxEqAbs(before, fixture.screen_y.?, 0.01);
}

test "virtual list width changes keep the drawn anchor and refresh estimates" {
    var t = try initFixture();
    defer t.deinit();
    defer fixture.state.deinit(std.testing.allocator);
    try dvui.testing.settle(listFrame);
    fixture.state.scrollTo(fixture.watched);
    try dvui.testing.settle(listFrame);
    try std.testing.expect(fixture.screen_y != null);
    const before = fixture.screen_y.?;
    fixture.width = 150;
    _ = try dvui.testing.step(listFrame);
    try std.testing.expectApproxEqAbs(before, fixture.screen_y.?, 0.01);
    try std.testing.expectEqual(@as(f32, 80), fixture.state.heights.heightAt(500));
}

test "virtual list follows appends and stops following after scrollTo" {
    var t = try initFixture();
    defer t.deinit();
    defer fixture.state.deinit(std.testing.allocator);
    fixture.follow = true;
    fixture.watched = fixture.first + fixture.count - 1;
    try dvui.testing.settle(listFrame);
    try std.testing.expect(fixture.screen_y != null);
    const before = fixture.screen_y.?;
    fixture.count += 20;
    fixture.revision += 1;
    fixture.watched += 20;
    try dvui.testing.settle(listFrame);
    try std.testing.expectApproxEqAbs(before, fixture.screen_y.?, 0.01);
    try std.testing.expect(fixture.state.following);
    fixture.watched = 1900;
    fixture.state.scrollTo(fixture.watched);
    try dvui.testing.settle(listFrame);
    try std.testing.expect(!fixture.state.following);
    const reading_y = fixture.screen_y.?;
    fixture.count += 20;
    fixture.revision += 1;
    try dvui.testing.settle(listFrame);
    try std.testing.expectApproxEqAbs(reading_y, fixture.screen_y.?, 0.01);
}

test "virtual list draws a bounded window of twenty thousand rows" {
    var t = try initFixture();
    defer t.deinit();
    defer fixture.state.deinit(std.testing.allocator);
    fixture.count = 20_000;
    try dvui.testing.settle(listFrame);
    for (0..20) |step| {
        fixture.watched = fixture.first + step * 1000;
        fixture.state.scrollTo(fixture.watched);
        try dvui.testing.settle(listFrame);
        try std.testing.expect(fixture.screen_y != null);
        try std.testing.expect(fixture.drawn < 30);
    }
}

test "virtual list empty rows and nearStart use the supplied data only" {
    var t = try initFixture();
    defer t.deinit();
    defer fixture.state.deinit(std.testing.allocator);
    fixture.count = 0;
    try dvui.testing.settle(listFrame);
    try std.testing.expectEqual(@as(usize, 0), fixture.drawn);
    try std.testing.expect(fixture.near_start);
    fixture.count = 100;
    fixture.revision += 1;
    try dvui.testing.settle(listFrame);
    fixture.watched = fixture.first + 50;
    fixture.state.scrollTo(fixture.watched);
    try dvui.testing.settle(listFrame);
    try std.testing.expect(!fixture.near_start);
}

test "virtual list scrolling demo with twenty thousand rows and frame readout" {
    var t = try initFixture();
    defer t.deinit();
    defer fixture.state.deinit(std.testing.allocator);
    fixture.count = 20_000;
    fixture.demo = true;
    try dvui.testing.settle(listFrame);
    var total_ms: f64 = 0;
    var max_ms: f64 = 0;
    const frames = 180;
    for (0..frames) |frame| {
        fixture.watched = fixture.first + frame * 7;
        fixture.state.scrollTo(fixture.watched);
        const start = std.Io.Clock.awake.now(std.testing.io);
        _ = try dvui.testing.step(listFrame);
        const elapsed = start.durationTo(std.Io.Clock.awake.now(std.testing.io));
        fixture.frame_ms = @as(f64, @floatFromInt(elapsed.toNanoseconds())) / std.time.ns_per_ms;
        total_ms += fixture.frame_ms;
        max_ms = @max(max_ms, fixture.frame_ms);
        try std.testing.expect(fixture.drawn < 40);
        try std.testing.expect(dvui.tagGet("virtual-list-frame-time").?.visible);
    }
    std.debug.print("virtual list demo: {d} frames, mean {d:.3} ms, max {d:.3} ms (headless Debug, includes Window.end/begin)\n", .{ frames, total_ms / frames, max_ms });
}
