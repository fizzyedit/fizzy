//! CPU-side variable-height list benchmark in dvui's headless backend: layout, text shaping,
//! measurement and index reconciliation, with no GPU work. Compare only at equal -Doptimize.
//! Timings are reports; smoke assertions cover reader stability, never elapsed time.
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const smoke = @import("bench_list_options").smoke;
const VirtualList = core.widgets.VirtualList;
const HeightIndex = core.HeightIndex;
const REVERSAL_EPS: f32 = 0.01;
// Main baseline per kind and scenario a-g; L3 brings repeated measurements to zero.
const main_measured_changes = [3][7]usize{
    .{ 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 156, 0, 17, 21, 0, 0 },
    .{ 0, 61, 0, 7, 11, 0, 0 },
};
const Kind = enum { one_line, wrapped, chat };
const Sample = struct { key: u64, top: f32, height: f32, measured: bool };
const Stats = struct {
    times: std.ArrayList(i128) = .empty,
    measured_changes: usize = 0,
    drift_max: f32 = 0,
    reversals: usize = 0,
    rounding_max: f32 = 0,
};
const Rows = struct {
    first_id: u64 = 10_000,
    count: usize,
    revision: u64 = 0,
    kind: Kind,
    width: f32 = 400,
    state: VirtualList.State = .init(std.testing.allocator),
    previous: std.ArrayList(Sample) = .empty,
    held: ?Sample = null,
    previous_width: f32 = 0,
    stats: Stats = .{},
    input: bool = false,
    check_drift: bool = true,
    direction: f32 = 0,
    jump: ?u64 = null,
    replacement: bool = false,
    scenario: usize = 0,
    moving: bool = false,

    fn key(ctx: *anyopaque, i: usize) u64 {
        const self: *Rows = @ptrCast(@alignCast(ctx));
        return if (self.replacement and i == self.count / 2) std.math.maxInt(u64) else self.first_id + i;
    }
    fn estimate(_: *anyopaque, _: usize, _: f32) f32 {
        return 3 * 20;
    }
    fn paragraph(n: usize, extra: usize) void {
        const prose = "A reader follows a message through the list while its lines wrap to the available width. ";
        var buf: [400]u8 = undefined;
        for (&buf, 0..) |*c, i| c.* = prose[i % prose.len];
        var text = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .id_extra = extra });
        defer text.deinit();
        text.addText(buf[0..n], .{});
    }
    fn frame(self: *Rows) !void {
        if (self.jump) |k| self.state.scrollTo(k);
        self.jump = null;
        const start = nowNs();
        var list = VirtualList.init(@src(), .{
            .state = &self.state,
            .count = self.count,
            .ctx = self,
            .key = key,
            .estimate = estimate,
            .revision = self.revision,
        }, .{ .expand = .vertical, .min_size_content = .width(self.width), .max_size_content = .width(self.width) });
        var drawn: std.ArrayList(Sample) = .empty;
        defer drawn.deinit(std.testing.allocator);
        while (list.next()) |i| {
            var row = list.row(i);
            const rs = row.box.data().rectScale();
            const top = rs.r.y / rs.s;
            switch (self.kind) {
                .one_line => {
                    var buf: [32]u8 = undefined;
                    dvui.labelNoFmt(@src(), try std.mem.print(&buf, "{d}", .{row.key}), .{}, .{});
                },
                .wrapped => paragraph(80 * (1 + row.key % 5), 0),
                .chat => {
                    dvui.labelNoFmt(@src(), "Reader", .{}, .{ .font = dvui.themeGet().font_heading });
                    paragraph(80 * (1 + row.key % 5), 0);
                    paragraph(80 * (1 + (row.key / 5) % 5), 1);
                },
            }
            row.deinit();
            const h = self.state.index.heightAt(i);
            if (self.previous_width == self.state.index.width) {
                for (self.previous.items) |old| if (old.key == row.key and old.measured and @abs(old.height - h) >= 0.5) {
                    self.stats.measured_changes += 1;
                };
            }
            try drawn.append(std.testing.allocator, .{ .key = row.key, .top = top, .height = h, .measured = self.state.index.stateAt(i) == .measured });
        }
        list.deinit();
        const elapsed = nowNs() - start;
        const touch = list.scroll.touch;
        self.moving = touch.seg_y.kind != .none or touch.seating or touch.glide_y != null;
        try self.stats.times.append(std.testing.allocator, elapsed);
        const si = self.state.si;
        const in_bounds = si.viewport.y > 0 and si.viewport.y + si.viewport.h < si.virtual_size.h;
        if (self.held) |old| for (drawn.items) |item| {
            if (old.key != item.key) continue;
            const movement = item.top - old.top;
            if (!self.input and in_bounds and self.check_drift)
                self.stats.drift_max = @max(self.stats.drift_max, @abs(movement + (si.viewport.y - self.state.frame_y)));
            if (in_bounds and self.direction != 0) {
                const against = movement * self.direction;
                if (against > REVERSAL_EPS) self.stats.reversals += 1 else if (against > 0)
                    self.stats.rounding_max = @max(self.stats.rounding_max, against);
            }
        };
        self.held = null;
        if (self.state.anchor) |anchor| for (drawn.items) |item| {
            if (item.key == anchor.key) self.held = item;
        };
        self.previous_width = self.state.index.width;
        std.mem.swap(std.ArrayList(Sample), &self.previous, &drawn);
    }
    fn step(self: *Rows) !void {
        const cw = dvui.currentWindow();
        try self.frame();
        _ = try cw.end(.{});
        // A synthetic 120 Hz clock keeps inertia independent of machine speed.
        try cw.begin(cw.frame_time_ns + 8_330_000);
    }
    fn settle(self: *Rows) !void {
        var quiet: usize = 0;
        for (0..2400) |_| {
            try self.step();
            if (!self.moving and @abs(self.state.si.viewport.y - self.state.frame_y) < 0.0001) quiet += 1 else quiet = 0;
            if (quiet >= 12) return;
        }
        return error.CoastNeverEnded;
    }
    fn swipeAt(self: *Rows, distance: f32, frames: usize) !void {
        const cw = dvui.currentWindow();
        const h = cw.data().rect.h;
        var y: f32 = if (distance > 0) 0.8 else 0.2;
        self.input = true;
        _ = try cw.addEventPointer(.{ .button = .touch0, .action = .press, .xynorm = .{ .x = 0.5, .y = y } });
        try self.step();
        for (0..frames) |_| {
            _ = try cw.addEventTouchMotion(.touch0, 0.5, y - distance / h, 0, -distance / h);
            y -= distance / h;
            try self.step();
        }
        _ = try cw.addEventPointer(.{ .button = .touch0, .action = .release, .xynorm = .{ .x = 0.5, .y = y } });
        try self.step();
        self.input = false;
        try self.settle();
    }
    fn reachable(self: *Rows) usize {
        return self.state.index.rowAt(@min(self.state.index.total() - 0.5, dvui.max_float_safe - 0.5)).? + 1;
    }
    fn report(self: *Rows, count: usize, scenario: []const u8) !void {
        const times = self.stats.times.items;
        std.mem.sort(i128, times, {}, std.sort.asc(i128));
        std.debug.print("{d} {s} {s}: frames={d} list ms p50/p95/max={d:.4}/{d:.4}/{d:.4} measured_changes={d} drift_max={d:.6} reversals={d}", .{
            count,                    @tagName(self.kind),                   scenario,                 times.len,
            ms(times[times.len / 2]), ms(times[(times.len - 1) * 95 / 100]), ms(times[times.len - 1]), self.stats.measured_changes,
            self.stats.drift_max,     self.stats.reversals,
        });
        if (self.state.index.total() > dvui.max_float_safe) std.debug.print(" capped (L4), reachable={d}", .{self.reachable()});
        std.debug.print("\n  largest sub-EPS reversal={d:.9} pt\n", .{self.stats.rounding_max});
        if (smoke) {
            try std.testing.expect(self.stats.drift_max <= 0.5);
            try std.testing.expectEqual(@as(usize, 0), self.stats.reversals);
            try std.testing.expect(self.stats.measured_changes <= main_measured_changes[@backingInt(self.kind)][self.scenario]);
        }
        self.scenario += 1;
        self.stats.times.clearRetainingCapacity();
        const times_store = self.stats.times;
        self.stats = .{ .times = times_store };
    }
};
fn nowNs() i128 {
    return std.Io.Clock.boot.now(dvui.io).nanoseconds;
}
fn ms(ns: i128) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000;
}

fn run(count: usize, kind: Kind) !void {
    var t = try dvui.testing.init(.{ .allocator = std.testing.allocator, .window_size = .{ .w = 400, .h = 800 } });
    defer t.deinit();
    var rows: Rows = .{ .count = count, .kind = kind };
    defer rows.state.deinit();
    defer rows.previous.deinit(std.testing.allocator);
    defer rows.stats.times.deinit(std.testing.allocator);
    try rows.settle();
    try rows.report(count, "a top");
    for ([_]f32{ 1, -1 }, [_][]const u8{ "b down", "c up" }) |dir, name| {
        rows.direction = dir;
        var travelled: f32 = 0;
        for (0..100) |_| {
            const before = rows.state.index.resolve(rows.state.anchor.?).?;
            try rows.swipeAt(dir * 60, 8);
            const after = rows.state.index.resolve(rows.state.anchor.?).?;
            travelled += @abs(after - before);
            if (travelled >= 20 * 800 or @abs(after - before) < 0.5 or rows.state.si.viewport.y <= 0 or rows.state.si.viewport.y + 800 >= rows.state.si.virtual_size.h) break;
        }
        rows.direction = 0;
        try rows.report(count, name);
    }
    rows.check_drift = false;
    rows.jump = rows.first_id;
    rows.input = true;
    try rows.step();
    rows.input = false;
    try rows.settle();
    try rows.swipeAt(-200, 1);
    rows.jump = rows.first_id + rows.reachable() - 1;
    rows.input = true;
    try rows.step();
    rows.input = false;
    try rows.settle();
    try rows.swipeAt(200, 1);
    try rows.report(count, "d overscroll");
    rows.check_drift = true;
    rows.jump = rows.first_id + rows.reachable() / 2;
    rows.input = true;
    try rows.step();
    rows.input = false;
    try rows.settle();
    try rows.report(count, "e jump");
    rows.first_id -= 50;
    rows.count += 50;
    rows.revision += 1;
    try rows.settle();
    try rows.report(count, "f prepend");
    rows.width = 360;
    try rows.step();
    rows.width = 400;
    try rows.settle();
    try rows.report(count, "g width");
}

fn indexBench() !void {
    var rows: Rows = .{ .count = 1_000_000, .kind = .one_line };
    var idx: HeightIndex = .{};
    defer idx.deinit(std.testing.allocator);
    const source: HeightIndex.Source = .{ .ctx = &rows, .key = Rows.key, .estimate = Rows.estimate };
    for ([_][]const u8{ "build", "prepend 1k", "append 1k", "interior replacement", "width change" }, 0..) |name, i| {
        switch (i) {
            1 => {
                rows.first_id -= 1000;
                rows.count += 1000;
            },
            2 => rows.count += 1000,
            3 => rows.replacement = true,
            else => {},
        }
        rows.revision += 1;
        const start = nowNs();
        try idx.reconcile(std.testing.allocator, source, rows.count, if (i == 4) 360 else 400, rows.revision);
        std.debug.print("index 1M reconcile {s}: {d:.4} ms\n", .{ name, ms(nowNs() - start) });
        if (i == 0) {
            const bytes = idx.keys.capacity * @sizeOf(u64) + idx.heights.capacity * @sizeOf(f32) + idx.states.capacity * @sizeOf(HeightIndex.State) + idx.tree.capacity * @sizeOf(f64) + idx.by_key.capacity() * 13;
            std.debug.print("index 1M bytes per row={d:.3}\n", .{@as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(idx.len()))});
        }
    }
}
test "bench-list smoke: 1k rows of each kind" {
    if (!smoke) return error.SkipZigTest;
    for (std.enums.values(Kind)) |kind| try run(1000, kind);
}
test "bench-list: variable-height list CPU cost" {
    if (smoke) return error.SkipZigTest;
    for ([_]usize{ 1000, 100_000, 1_000_000 }) |count| for (std.enums.values(Kind)) |kind| try run(count, kind);
    try indexBench();
}
