//! CPU-side variable-height VirtualList benchmark using dvui's headless backend (no GPU).
//! Reports list construction, row text layout and teardown per frame, reader stability, and
//! HeightIndex mutation costs. Compare timings only at equal `-Doptimize`.

const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const options = @import("bench_list_options");
const VirtualList = core.widgets.VirtualList;
const HeightIndex = core.HeightIndex;
const gpa = std.testing.allocator;
const Kind = enum { one_line, wrapped, chat };
const Scenario = enum { top, down, up, overscroll, jump, prepend, width };
const scenario_names = [_][]const u8{ "a top", "b down", "c up", "d overscroll", "e jump", "f prepend", "g width" };
// Main's measured-height changes, by kind and scenario. L3 brings these to zero.
// These are counts from the unchanged list/index implementation, not timing budgets.
const main_measured_changes = [3][7]usize{
    .{ 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 160, 0, 17, 21, 0, 8 },
    .{ 0, 64, 0, 8, 10, 0, 4 },
};
const paragraph =
    "A reader follows a conversation while new messages arrive. Words wrap to the available width, and each message keeps its identity as the history grows. " ++
    "A reader follows a conversation while new messages arrive. Words wrap to the available width, and each message keeps its identity as the history grows. " ++
    "A reader follows a conversation while new messages arrive. Words wrap to the available width, and each message keeps its identity as the history grows. " ++
    "A reader follows a conversation while new messages arrive. Words wrap to the available width, and each message keeps its identity as the history grows. ";

const Sample = struct { key: u64, height: f32, width: f32, measured: bool };
const Reader = struct { key: u64, y: f32 };
const Stats = struct {
    times: std.ArrayList(i128) = .empty,
    measured_changes: usize = 0,
    drift_max: f32 = 0,
    reversals: usize = 0,

    fn report(self: *Stats, count: usize, kind: Kind, scenario: []const u8, reachable: usize) void {
        std.mem.sort(i128, self.times.items, {}, std.sort.asc(i128));
        const ts = self.times.items;
        std.debug.print("{d} {s} {s} reachable={d}{s} frames={d} list_ms(p50/p95/max)={d:.4}/{d:.4}/{d:.4} measured_changes={d} drift_max={d:.4} reversals={d}\n", .{
            count,                                         @tagName(kind),        scenario,           reachable,
            if (reachable < count) " capped (L4)" else "", ts.len,                ms(ts[ts.len / 2]), ms(ts[@min(ts.len - 1, ts.len * 95 / 100)]),
            ms(ts[ts.len - 1]),                            self.measured_changes, self.drift_max,     self.reversals,
        });
    }
};

const Rows = struct {
    first_id: u64 = 10_000,
    count: usize,
    revision: u64 = 1,
    kind: Kind,
    replaced: ?usize = null,
    state: VirtualList.State = VirtualList.State.init(gpa),
    width: f32 = 400,
    previous: std.ArrayList(Sample) = .empty,
    reader: ?Reader = null,
    stats: Stats = .{},
    input: bool = false,
    check_drift: bool = false,
    direction: f32 = 0,
    moving: bool = false,
    changed: bool = false,

    fn key(ctx: *anyopaque, i: usize) u64 {
        const self: *Rows = @ptrCast(@alignCast(ctx));
        return if (self.replaced == i) std.math.maxInt(u64) else self.first_id + i;
    }

    fn estimate(_: *anyopaque, _: usize, _: f32) f32 {
        return 3 * 20;
    }

    fn draw(self: *Rows, id: u64) void {
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "Message {d}", .{id}) catch unreachable; // 32 bytes fits a u64.
        switch (self.kind) {
            .one_line => dvui.labelNoFmt(@src(), text, .{}, .{}),
            .wrapped => {
                var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
                tl.addText(paragraph[0 .. 80 * (1 + id % 5)], .{});
                tl.deinit();
            },
            .chat => {
                dvui.labelNoFmt(@src(), text, .{}, .{ .font = dvui.themeGet().font_body.withWeight(.bold) });
                for (0..2) |p| {
                    var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .id_extra = p });
                    tl.addText(paragraph[0 .. 80 * (1 + (id + p) % 5)], .{});
                    tl.deinit();
                }
            },
        }
    }

    fn frame(self: *Rows) !dvui.App.Result {
        var box = dvui.box(@src(), .{}, .{
            .rect = .{ .w = self.width, .h = 800 },
        });
        defer box.deinit();
        var samples: std.ArrayList(Sample) = .empty;
        defer samples.deinit(gpa);
        var first: ?Reader = null;
        var tracked_y: ?f32 = null;
        const idx = &self.state.index;
        const start = nowNs();
        {
            var list = VirtualList.init(@src(), .{
                .state = &self.state,
                .count = self.count,
                .ctx = self,
                .key = key,
                .estimate = estimate,
                .revision = self.revision,
            }, .{ .expand = .both });
            defer list.deinit();
            while (list.next()) |i| {
                var row = list.row(i);
                {
                    defer row.deinit();
                    self.draw(key(self, i));
                    const rs = row.box.data().rectScale();
                    const y = rs.r.y / rs.s;
                    if (y >= 0 and y < self.state.si.viewport.h and first == null)
                        first = .{ .key = key(self, i), .y = y };
                    if (self.reader) |r| if (r.key == key(self, i)) {
                        tracked_y = y;
                    };
                }
                const sample: Sample = .{ .key = key(self, i), .height = idx.heightAt(i), .width = idx.width, .measured = idx.stateAt(i) == .measured };
                for (self.previous.items) |prev| {
                    if (prev.key == sample.key and prev.measured and @abs(prev.width - sample.width) < 0.5 and @abs(prev.height - sample.height) >= 0.5)
                        self.stats.measured_changes += 1;
                }
                try samples.append(gpa, sample);
            }
            self.moving = list.scroll.touch.seg_y.kind != .none or list.scroll.touch.seating or list.scroll.touch.dragging;
            self.changed = list.measured_change;
        }
        try self.stats.times.append(gpa, nowNs() - start);
        const si = &self.state.si;
        if (si.viewport.y > 0 and si.viewport.y < si.scrollMax(.vertical)) {
            if (tracked_y) |y| if (self.reader) |r| {
                const delta = y - r.y;
                if (!self.input and self.check_drift)
                    self.stats.drift_max = @max(self.stats.drift_max, @abs(delta + (si.viewport.y - self.state.frame_y)));
                if (self.direction != 0 and delta * self.direction > 0) self.stats.reversals += 1;
            };
        }
        self.reader = first;
        self.previous.deinit(gpa);
        self.previous = samples;
        samples = .empty;
        return .ok;
    }

    fn reachable(self: *Rows) usize {
        const idx = &self.state.index;
        if (idx.total() <= dvui.max_float_safe) return self.count;
        const last = idx.rowAt(dvui.max_float_safe).?;
        return last + @intFromBool(idx.yAt(last) < dvui.max_float_safe);
    }

    fn finish(self: *Rows, count: usize, scenario: Scenario) !void {
        self.stats.report(count, self.kind, scenario_names[@backingInt(scenario)], self.reachable());
        if (options.smoke) {
            try std.testing.expect(self.stats.drift_max <= 0.5);
            try std.testing.expectEqual(@as(usize, 0), self.stats.reversals);
            try std.testing.expect(self.stats.measured_changes <= main_measured_changes[@backingInt(self.kind)][@backingInt(scenario)]);
        }
        self.stats.times.clearRetainingCapacity();
        self.stats.measured_changes = 0;
        self.stats.drift_max = 0;
        self.stats.reversals = 0;
    }
};

// The test thread sets this before driving dvui's argument-free frame callback.
var current: *Rows = undefined;
fn frame() !dvui.App.Result {
    return current.frame();
}
fn nowNs() i128 {
    return std.Io.Clock.boot.now(dvui.io).nanoseconds;
}
fn ms(ns: i128) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

/// Like ScrollArea's private frameAfter: input and coast use the real window clock at 120 Hz.
fn frameAfter() !void {
    const cw = dvui.currentWindow();
    _ = try frame();
    _ = try cw.end(.{});
    try cw.begin(cw.frame_time_ns + 8_333_333);
}

fn settle() !void {
    var quiet: usize = 0;
    for (0..2400) |_| {
        try frameAfter();
        quiet = if (!current.moving and !current.changed) quiet + 1 else 0;
        if (quiet >= 8) return;
    }
    return error.ListNeverSettled;
}

/// Copied from ScrollArea.swipeAt; the final one-point move and release get separate frames.
fn swipeAt(step: f32, frames: usize) !void {
    const cw = dvui.currentWindow();
    const x = 0.5;
    var y: f32 = if (step >= 0) 0.8 else 0.2;
    const h = cw.data().rect.h;
    current.input = true;
    _ = try cw.addEventPointer(.{ .button = .touch0, .action = .press, .xynorm = .{ .x = x, .y = y } });
    try frameAfter();
    for (0..frames) |_| {
        _ = try cw.addEventTouchMotion(.touch0, x, y - step / h, 0, -step / h);
        y -= step / h;
        try frameAfter();
    }
    const last: f32 = if (step >= 0) 1 else -1;
    _ = try cw.addEventTouchMotion(.touch0, x, y - last / h, 0, -last / h);
    try frameAfter();
    _ = try cw.addEventPointer(.{ .button = .touch0, .action = .release, .xynorm = .{ .x = x, .y = y } });
    try frameAfter();
    current.input = false;
}

fn fling(direction: f32) !void {
    current.direction = direction;
    current.check_drift = true;
    var distance: f32 = 0;
    while (distance < 20 * 800) {
        const before = current.state.si.viewport.y;
        try swipeAt(direction * 60, 8);
        try settle();
        const after = current.state.si.viewport.y;
        distance += @abs(after - before);
        if (after <= 0 or after >= current.state.si.scrollMax(.vertical)) break;
        if (@abs(after - before) < 0.5) return error.FlingDidNotTravel;
    }
    current.direction = 0;
}

fn run(count: usize, kind: Kind) !void {
    var t = try dvui.testing.init(.{ .allocator = gpa, .window_size = .{ .w = 400, .h = 800 } });
    defer t.deinit();
    var rows: Rows = .{ .count = count, .kind = kind };
    defer rows.state.deinit();
    defer rows.previous.deinit(gpa);
    defer rows.stats.times.deinit(gpa);
    current = &rows;
    try settle();
    try rows.finish(count, .top);
    try fling(1);
    try rows.finish(count, .down);
    try fling(-1);
    try rows.finish(count, .up);
    rows.check_drift = false;
    rows.state.scrollTo(rows.first_id);
    try settle();
    try swipeAt(-25, 8);
    try settle();
    rows.state.scrollTo(rows.first_id + rows.reachable() - 1);
    try settle();
    try swipeAt(25, 8);
    try settle();
    try rows.finish(count, .overscroll);
    rows.state.scrollTo(rows.first_id + rows.reachable() / 2);
    // A deliberate jump is input; only the following input-free settling frames count.
    rows.input = true;
    try frameAfter();
    rows.input = false;
    rows.check_drift = true;
    try settle();
    try rows.finish(count, .jump);
    rows.first_id -= 50;
    rows.count += 50;
    rows.revision += 1;
    try settle();
    try rows.finish(count, .prepend);
    rows.width = 360;
    try frameAfter();
    rows.width = 400;
    try settle();
    try rows.finish(count, .width);
}

fn benchIndex() !void {
    var rows: Rows = .{ .count = 1_000_000, .kind = .one_line };
    var idx: HeightIndex = .{};
    defer idx.deinit(gpa);
    const source: HeightIndex.Source = .{ .ctx = &rows, .key = Rows.key, .estimate = Rows.estimate };
    const labels = [_][]const u8{ "reconcile build", "prepend 1k", "append 1k", "interior replacement", "width change" };
    for (labels, 0..) |label, i| {
        switch (i) {
            1 => {
                rows.first_id -= 1000;
                rows.count += 1000;
                rows.revision += 1;
            },
            2 => {
                rows.count += 1000;
                rows.revision += 1;
            },
            3 => {
                rows.replaced = rows.count / 2;
                rows.revision += 1;
            },
            else => {},
        }
        const start = nowNs();
        try idx.reconcile(gpa, source, rows.count, if (i == 4) 360 else 400, rows.revision);
        std.debug.print("index 1M {s}: {d:.4} ms\n", .{ label, ms(nowNs() - start) });
        if (i == 0) {
            const bytes = idx.keys.capacity * @sizeOf(u64) + idx.heights.capacity * @sizeOf(f32) + idx.states.capacity * @sizeOf(HeightIndex.State) + idx.tree.capacity * @sizeOf(f64) + @as(usize, idx.by_key.capacity()) * 13;
            std.debug.print("index 1M bytes/row: {d:.4}\n", .{@as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(idx.len()))});
        }
    }
}

test "bench-list smoke: 1k rows of each kind" {
    if (!options.smoke) return error.SkipZigTest;
    for (std.enums.values(Kind)) |kind| try run(1000, kind);
}

test "bench-list: variable-height rows" {
    if (options.smoke) return error.SkipZigTest;
    for ([_]usize{ 1000, 100_000, 1_000_000 }) |count|
        for (std.enums.values(Kind)) |kind| try run(count, kind);
    // The clock uses dvui's IO, so keep a testing window current for index-only timings.
    var t = try dvui.testing.init(.{ .allocator = gpa });
    defer t.deinit();
    try benchIndex();
}
