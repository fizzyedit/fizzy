//! Glass drawn from where its items are THIS frame (`layer`), and the visibility of glass ink in
//! physical pixels, including its antialiasing fringe.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const LiquidField = @import("glass").LiquidField;
const BlurBackdrop = @import("glass").BlurBackdrop;
const glass_look = @import("glass_look");
const dialogs = @import("dialogs.zig");
const widgets = @import("widgets.zig");

/// The antialiasing fringe, in physical pixels, that ink may reach past the clip and still show.
/// The backend keeps a copy (`BlurBackdrop.fringe_px`), pinned to it by the test below.
pub const fringe_px: f32 = 1;

/// True when physical ink meets the clip grown by `margin_px` on both axes.
pub fn within(ink: dvui.Rect.Physical, clip: dvui.Rect.Physical, margin_px: f32) bool {
    return ink.x <= clip.x + clip.w + margin_px and ink.x + ink.w >= clip.x - margin_px and
        ink.y <= clip.y + clip.h + margin_px and ink.y + ink.h >= clip.y - margin_px;
}

/// True when ink reaches the current, non-empty clip, including the physical fringe.
pub fn reaches(ink: dvui.Rect.Physical) bool {
    const clip = dvui.clipGet();
    return !clip.empty() and within(ink, clip, fringe_px);
}

/// A rounded box of glass. Physical pixels, window coordinates.
pub const Box = struct {
    rect: dvui.Rect.Physical,
    /// Top-left, top-right, bottom-right, bottom-left, as `LiquidField.Shape`.
    radii: [4]f32 = @splat(0),
    round: bool = false,
};

pub const Morph = @import("glass_morph.zig");

pub const Shape = union(enum) {
    box: Box,
    panel: LiquidField.Panel,
};

/// One piece of glass in a layer.
pub const Item = struct {
    shape: Shape,
    /// Items of one nonzero group run together where they come within `LayerOptions.merge`; group
    /// 0 never joins anything.
    group: u16 = 0,
    /// As `LiquidField.Shape`.
    blur: f32 = 1,
    lens: f32 = 1,
    light: f32 = 0,
};

/// What every item of a layer shares: the field options of `LiquidField` and the pane of
/// `BlurBackdrop.Pane`.
pub const LayerOptions = struct {
    role: ?glass_look.Role = null,
    /// Points: how near two items of one nonzero group come before they join.
    merge: f32 = 0,
    /// The glass's colour and how much of it. Null keeps the dialog style's; `lift` 0 does too.
    tint: ?dvui.Color = null,
    mix: f32 = 0,
    lift: f32 = 0,
    /// The blur; null is `core.widgets.liquidFrost()`'s.
    radius: ?f32 = null,
    /// The place the items belong to, on every field (`LiquidField.edge`).
    edge: ?LiquidField.Edge = null,
    solid: bool = false,
    window: bool = false,
    surface: bool = false,
    light_across: bool = false,
    /// A signature of what lies under the layer (`BlurBackdrop.Pane.witness`).
    witness: ?u64 = null,
    /// The items' shadow rings' share, 0…1, drawn after the glass so it never blurs them in.
    shadow: f32 = 0,
};

/// Items in one field: the program's shape slots, less the one an edge takes.
const field_items = LiquidField.max_shapes - 1;

/// Begin a layer: the glass of the items `add`ed before `end`, THIS frame's, drawn first and so
/// under everything drawn in between, from ONE capture of what is behind them. An empty layer
/// (no glass program, or the blur off) adds nothing, and `add` says so for the caller's fallback.
///
/// Drawing in the span is deferred, whatever the window was doing (as in a `dvui.RenderFrontToBack`
/// block), and replays at `end`: in an immediate context at once, in a deferred one (a floating
/// window, a picture, a front-to-back block) as one command at the layer's place. So draw-last
/// commands in the span (focus rings) draw at the layer's end, not at the subwindow's, and text
/// in the span is shaped at replay, as in every floating window. The span is a block: `end` runs
/// in the subwindow `layer` did, and a window opened inside it draws in its own subwindow.
///
///     var l = core.glass.layer(id, .{ .merge = 12 });
///     defer l.end();
///     _ = l.add(.{ .shape = .{ .box = .{ .rect = r, .radii = @splat(8) } }, .group = 1 });
///
/// `id` keys the capture and so must be stable.
pub fn layer(id: dvui.Id, opts: LayerOptions) Layer {
    if (!LiquidField.ready()) return .{};
    var pane = widgets.liquidFrost() orelse return .{};
    pane.form = 1;
    if (opts.radius) |r| pane.radius = r;
    if (opts.tint) |t| {
        pane.tint = t;
        pane.mix = opts.mix;
    }
    if (opts.lift > 0) pane.lift = opts.lift;
    pane.witness = opts.witness;
    const cw = dvui.currentWindow();
    const job = cw.arena().create(Job) catch return .{};
    job.* = .{
        .id = id,
        .opts = opts,
        .pane = pane,
        .scale = dvui.parentGet().screenRectScale(.{}).s,
        .subwindow = dvui.subwindowCurrentId(),
        .clip = dvui.clipGet(),
        .previous = current().job,
        .prev_rendering = dvui.renderingSet(false),
        .prev_queues = cw.defer_render,
    };
    dvui.dataSet(null, job.subwindow, "core.glass.layer", @as(?*Job, job));
    cw.defer_render = &job.queues;
    // First in the span's queue, so under every item; the items fill `job.items` as they lay out.
    dvui.deferRender(job, Job.drawGlass);
    return .{ .job = job };
}

/// The innermost open layer of this subwindow, or an empty layer. Valid only this frame.
pub fn current() Layer {
    return .{ .job = dvui.dataGet(null, dvui.subwindowCurrentId(), "core.glass.layer", ?*Job) orelse null };
}

pub const Layer = struct {
    job: ?*Job = null,

    /// Whether `add` will draw anything: false without the glass program or with the blur off.
    pub fn active(self: Layer) bool {
        return self.job != null;
    }

    /// The physical clip under which this layer opened, or null for an empty layer.
    pub fn clip(self: Layer) ?dvui.Rect.Physical {
        return if (self.job) |job| job.clip else null;
    }

    /// An item of this frame, right after its widget lays out. False on an empty layer: the caller
    /// paints its fallback.
    pub fn add(self: *Layer, item: Item) bool {
        const job = self.job orelse return false;
        const arena = dvui.currentWindow().arena();
        var owned = item;
        if (owned.shape == .panel) {
            owned.shape.panel.seams = arena.dupe(LiquidField.Seam, item.shape.panel.seams) catch return false;
        }
        job.items.append(arena, owned) catch return false;
        return true;
    }

    pub fn end(self: *Layer) void {
        const job = self.job orelse return;
        self.job = null;
        const cw = dvui.currentWindow();
        std.debug.assert(cw.defer_render == &job.queues);
        std.debug.assert(dvui.subwindowCurrentId() == job.subwindow);
        dvui.dataSet(null, job.subwindow, "core.glass.layer", job.previous);
        cw.defer_render = job.prev_queues;
        _ = dvui.renderingSet(job.prev_rendering);
        dvui.deferRender(job, Job.replay);
    }
};

const Job = struct {
    id: dvui.Id,
    opts: LayerOptions,
    pane: BlurBackdrop.Pane,
    scale: f32,
    subwindow: dvui.Id,
    clip: dvui.Rect.Physical,
    previous: ?*Job,
    prev_rendering: bool,
    prev_queues: ?*dvui.RenderQueues,
    queues: dvui.RenderQueues = .{},
    items: std.ArrayList(Item) = .empty,

    fn replay(ctx: ?*anyopaque) void {
        const job: *Job = @ptrCast(@alignCast(ctx orelse return));
        job.queues.render(dvui.currentWindow()) catch |err| dvui.logError(@src(), err, "glass layer could not replay", .{});
    }

    /// The layer's first command: at replay `items` holds this frame's, all of them.
    fn drawGlass(ctx: ?*anyopaque) void {
        const job: *Job = @ptrCast(@alignCast(ctx orelse return));
        record.beginJob();
        const arena = dvui.currentWindow().arena();
        var fields: std.ArrayList(LiquidField) = .empty;
        var groups: std.ArrayList(u16) = .empty;
        for (job.items.items) |item| {
            const box: Box = switch (item.shape) {
                .box => |b| b,
                .panel => |p| .{ .rect = p.rect, .radii = p.radii },
            };
            // Quadratic smooth min lowers distance by at most merge_px / 4, so joined ink is that close to some piece; reaches adds the 1 px fringe.
            const reach = if (item.group != 0) job.opts.merge * job.scale / 4 else 0;
            if (!reaches(box.rect.insetAll(-reach))) continue;
            // Only a group's newest field is open; earlier ones have filled or taken a panel.
            var open: ?usize = null;
            var i = fields.items.len;
            while (i > 0) {
                i -= 1;
                if (groups.items[i] != item.group) continue;
                if (fields.items[i].len < field_items and
                    (item.shape != .panel or fields.items[i].panel == null)) open = i;
                break;
            }
            if (open == null) {
                fields.append(arena, job.newField(item.group)) catch return;
                groups.append(arena, item.group) catch return;
                open = fields.items.len - 1;
            }
            if (item.shape == .panel) {
                var panel = item.shape.panel;
                panel.blur = item.blur;
                panel.lens = item.lens;
                fields.items[open.?].panel = panel;
                continue;
            }
            fields.items[open.?].add(.{
                .rect = box.rect,
                .radii = box.radii,
                .round = box.round,
                .blur = item.blur,
                .lens = item.lens,
                .light = item.light,
            });
        }
        if (fields.items.len > 0) {
            for (fields.items) |*f| record.field(f);
            record.capture();
            BlurBackdrop.fieldsPane(job.id, fields.items, job.scale, job.pane);
        }
        // The rings over the glass, never under it, so none lands on a neighbour drawn earlier.
        if (job.opts.shadow > 0) {
            const bs = dialogs.surfaceShadow();
            const s = job.scale;
            for (job.items.items) |item| {
                const box: Box = switch (item.shape) {
                    .box => |b| b,
                    .panel => |p| .{ .rect = p.rect, .radii = p.radii },
                };
                if (!reaches(box.rect.insetAll(-bs.fade * s))) continue;
                record.shadow();
                const r = box.radii;
                const corners: dvui.CornerRect = .{ .tl = .round(r[0] / s), .tr = .round(r[1] / s), .br = .round(r[2] / s), .bl = .round(r[3] / s) };
                dialogs.glassShadow(box.rect, corners, s, bs, job.opts.shadow);
            }
        }
    }

    fn newField(job: *const Job, group: u16) LiquidField {
        const o = job.opts;
        return .{
            .scale = job.scale,
            .merge_px = if (group == 0) 0 else o.merge * job.scale,
            .role = o.role,
            .tint = o.tint,
            .mix = o.mix,
            .lift = o.lift,
            .edge = o.edge,
            .solid = o.solid,
            .window = o.window,
            .surface = o.surface,
            .light_across = o.light_across,
        };
    }
};

/// What the replay drew, for tests: nothing in other builds.
const record = if (builtin.is_test) struct {
    const Tag = enum { glass, shadow, item, float_core, float_dvui };
    var jobs: usize = 0;
    var captures: usize = 0;
    var glass_shapes: usize = 0;
    var shadow_shapes: usize = 0;
    var field_lens: [8]usize = undefined;
    var field_merge: [8]f32 = undefined;
    var fields: usize = 0;
    var panels: usize = 0;
    var radii: [64][4]f32 = undefined;
    var clips: [64]dvui.Rect.Physical = undefined;
    var rects: [64]dvui.Rect.Physical = undefined;
    var order: [128]Tag = undefined;
    var order_len: usize = 0;

    fn reset() void {
        jobs = 0;
        captures = 0;
        glass_shapes = 0;
        shadow_shapes = 0;
        fields = 0;
        panels = 0;
        order_len = 0;
    }
    fn log(tag: Tag) void {
        if (order_len < order.len) order[order_len] = tag;
        order_len += 1;
    }
    fn beginJob() void {
        glass_shapes = 0;
        shadow_shapes = 0;
        fields = 0;
        panels = 0;
        jobs += 1;
        log(.glass);
    }
    fn field(f: *const LiquidField) void {
        if (fields < field_lens.len) {
            field_lens[fields] = f.len;
            field_merge[fields] = f.merge_px;
        }
        fields += 1;
        if (f.panel != null) panels += 1;
        for (f.shapes[0..f.len]) |sh| {
            if (glass_shapes < rects.len) {
                rects[glass_shapes] = sh.rect;
                radii[glass_shapes] = sh.radii;
                clips[glass_shapes] = dvui.clipGet();
            }
            glass_shapes += 1;
        }
    }
    fn shadow() void {
        shadow_shapes += 1;
        log(.shadow);
    }
    fn capture() void {
        captures += 1;
    }
} else struct {
    fn beginJob() void {}
    fn field(_: *const LiquidField) void {}
    fn shadow() void {}
    fn capture() void {}
};

/// The shapes the last replayed job drew, physical (tests only).
pub fn drawnRects() []const dvui.Rect.Physical {
    if (!builtin.is_test) @compileError("drawnRects is for tests");
    return record.rects[0..@min(record.glass_shapes, record.rects.len)];
}

test "ink must reach both axes, with the same margins in core and the backend" {
    try std.testing.expectEqual(fringe_px, @import("glass").BlurBackdrop.fringe_px);
    const clip: dvui.Rect.Physical = .{ .x = 20, .y = 30, .w = 40, .h = 50 };
    for ([_]f32{ 1, 11 }) |margin| {
        for ([_]dvui.Rect.Physical{
            .{ .x = 20 - margin, .y = 40, .w = 0, .h = 1 },
            .{ .x = 60 + margin, .y = 40, .w = 0, .h = 1 },
            .{ .x = 40, .y = 30 - margin, .w = 1, .h = 0 },
            .{ .x = 40, .y = 80 + margin, .w = 1, .h = 0 },
        }) |edge| {
            for ([_]f32{ -0.25, 0, 0.25 }) |delta| {
                var ink = edge;
                if (ink.w == 0) ink.x += if (ink.x < clip.x) -delta else delta;
                if (ink.h == 0) ink.y += if (ink.y < clip.y) -delta else delta;
                try std.testing.expectEqual(delta <= 0, within(ink, clip, margin));
                try std.testing.expectEqual(within(ink, clip, margin), @import("glass").BlurBackdrop.inkWithin(ink, clip, margin));
            }
        }
        try std.testing.expect(!within(.{ .x = 40, .y = 100, .w = 1, .h = 1 }, clip, margin));
    }
}

const test_id: dvui.Id = @fromBackingInt(@intCast(802));

/// Test frames: `test_n` items stacked 12 px apart, each followed by a recorded fill.
var test_n: usize = 3;
var test_group: u16 = 0;
var test_shadow: f32 = 0;

fn testRect(i: usize) dvui.Rect.Physical {
    return .{ .x = 20, .y = 20 + 12 * @as(f32, @floatFromInt(i)), .w = 100, .h = 10 };
}

fn recordFill(ctx: ?*anyopaque) void {
    const tag: record.Tag = if (ctx) |c| @fromBackingInt(@intCast(@intFromPtr(c) - 1)) else .item;
    record.log(tag);
}

fn fill(tag: record.Tag) void {
    dvui.deferRender(@ptrFromInt(@backingInt(tag) + 1), recordFill);
}

fn addItems(l: *Layer) !void {
    for (0..test_n) |i| {
        const box: Box = .{ .rect = testRect(i), .radii = @splat(8) };
        try std.testing.expect(l.add(.{ .shape = .{ .box = box }, .group = test_group }));
        fill(.item);
    }
}

fn immediateFrame() !dvui.App.Result {
    record.reset();
    var l = layer(test_id, .{ .merge = 12, .shadow = test_shadow });
    try addItems(&l);
    try std.testing.expectEqual(0, record.glass_shapes);
    l.end();
    return .ok;
}

fn floatFrame() !dvui.App.Result {
    record.reset();
    // lint-allow(raw-transient-surface): the test is about dvui's own float around a layer.
    var win = dvui.floatingWindow(@src(), .{}, .{ .rect = .{ .x = 0, .y = 0, .w = 500, .h = 350 } });
    defer win.deinit();
    var l = layer(test_id, .{ .merge = 12, .shadow = test_shadow });
    try addItems(&l);
    l.end();
    return .ok;
}

fn expectRects(count: usize) !void {
    try std.testing.expectEqual(count, record.glass_shapes);
    for (0..count) |i| try std.testing.expectEqual(testRect(i), record.rects[i]);
}

fn resetTest() void {
    LiquidField.readyInTest(true);
    test_n = 3;
    test_group = 0;
    test_shadow = 0;
}

test "a layer draws this frame's items" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    resetTest();
    _ = try dvui.testing.step(immediateFrame);
    try std.testing.expectEqual(1, record.jobs);
    try std.testing.expectEqual(1, record.captures);
    try expectRects(3);
    // Moved the same frame, not the next: the rects are the ones added before `end`.
    test_n = 2;
    _ = try dvui.testing.step(immediateFrame);
    try expectRects(2);
}

test "the glass is under the items' contents" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    resetTest();
    test_shadow = 1;
    _ = try dvui.testing.step(immediateFrame);
    const order = record.order[0..record.order_len];
    try std.testing.expectEqual(record.Tag.glass, order[0]);
    var items: usize = 0;
    for (order, 0..) |tag, i| {
        if (tag != .item) continue;
        try std.testing.expect(i > 0);
        items += 1;
    }
    try std.testing.expectEqual(3, items);
    // The rings come with the glass, before any item's fill.
    for (order[1 .. 1 + record.shadow_shapes]) |tag| try std.testing.expectEqual(record.Tag.shadow, tag);
}

test "immediate and deferred alike" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    resetTest();
    const cw = dvui.currentWindow();
    _ = try dvui.testing.step(immediateFrame);
    try expectRects(3);
    try std.testing.expect(cw.render_target.rendering);
    try std.testing.expect(cw.defer_render == null);
    _ = try dvui.testing.step(floatFrame);
    try expectRects(3);
    try std.testing.expectEqual(1, record.jobs);
    try std.testing.expect(cw.render_target.rendering);
    try std.testing.expect(cw.defer_render == null);
}

fn nestedFrame() !dvui.App.Result {
    record.reset();
    const cw = dvui.currentWindow();
    var l = layer(test_id, .{});
    try addItems(&l);
    const queued = l.job.?.queues.normal.items.len;
    {
        var win = widgets.floatingWindow(@src(), .{}, .{ .rect = .{ .x = 10, .y = 10, .w = 100, .h = 100 } });
        defer win.deinit();
        fill(.float_core);
    }
    try std.testing.expect(cw.defer_render == &l.job.?.queues);
    try std.testing.expect(!cw.render_target.rendering);
    {
        // lint-allow(raw-transient-surface): the test is about dvui's own float inside a layer.
        var win = dvui.floatingWindow(@src(), .{}, .{ .rect = .{ .x = 50, .y = 50, .w = 100, .h = 100 } });
        defer win.deinit();
        fill(.float_dvui);
    }
    try std.testing.expect(cw.defer_render == &l.job.?.queues);
    // Neither window's fill came into the layer's queue.
    try std.testing.expectEqual(queued, l.job.?.queues.normal.items.len);
    l.end();
    try std.testing.expect(cw.defer_render == null);
    return .ok;
}

test "a floating window opened inside a layer draws normally" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    resetTest();
    _ = try dvui.testing.step(nestedFrame);
    // Both draw after the span, each in its own subwindow.
    const order = record.order[0..record.order_len];
    try std.testing.expectEqual(record.Tag.float_core, order[order.len - 2]);
    try std.testing.expectEqual(record.Tag.float_dvui, order[order.len - 1]);
}

test "30 items: glass and shadows both drawn at replay" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    resetTest();
    test_n = 30;
    test_shadow = 1;
    _ = try dvui.testing.step(immediateFrame);
    try std.testing.expectEqual(30, record.glass_shapes);
    try std.testing.expectEqual(30, record.shadow_shapes);
}

test "16 items of one group: two fields, one capture" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    resetTest();
    test_n = 16;
    test_group = 1;
    _ = try dvui.testing.step(immediateFrame);
    try std.testing.expectEqual(2, record.fields);
    try std.testing.expectEqual(15, record.field_lens[0]);
    try std.testing.expectEqual(1, record.field_lens[1]);
    try std.testing.expectEqual(1, record.captures);
    test_n = 15;
    _ = try dvui.testing.step(immediateFrame);
    try std.testing.expectEqual(1, record.fields);
}

var test_scale: f32 = 1;

fn groupsFrame() !dvui.App.Result {
    record.reset();
    test_scale = dvui.parentGet().screenRectScale(.{}).s;
    var l = layer(test_id, .{ .merge = 12 });
    for ([_]u16{ 1, 2, 0, 1, 0 }, 0..) |group, i| {
        const box: Box = .{ .rect = testRect(i) };
        try std.testing.expect(l.add(.{ .shape = .{ .box = box }, .group = group }));
    }
    l.end();
    return .ok;
}

test "merged glass reaching into the clip is kept" {
    const Frame = struct {
        var far = false;

        fn draw() !dvui.App.Result {
            record.reset();
            const s = dvui.parentGet().screenRectScale(.{}).s;
            const b: f32 = if (far) 100 - (12 * s / 4 + 2) else 98;
            const clip = dvui.clipGet();
            dvui.clipSet(.{ .x = 0, .y = 100, .w = 500, .h = 300 });
            var l = layer(test_id, .{ .merge = 12 });
            for ([_]f32{ 20, 70 }) |x| {
                try std.testing.expect(l.add(.{
                    .shape = .{ .box = .{ .rect = .{ .x = x, .y = b - 30, .w = 60, .h = 30 }, .radii = @splat(8) } },
                    .group = test_group,
                }));
            }
            l.end();
            dvui.clipSet(clip);
            return .ok;
        }
    };
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    resetTest();
    test_group = 1;
    _ = try dvui.testing.step(Frame.draw);
    try std.testing.expectEqual(2, record.glass_shapes);
    Frame.far = true;
    _ = try dvui.testing.step(Frame.draw);
    try std.testing.expectEqual(0, record.glass_shapes);
    Frame.far = false;
    test_group = 0;
    _ = try dvui.testing.step(Frame.draw);
    try std.testing.expectEqual(0, record.glass_shapes);
}

test "groups do not join" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    resetTest();
    _ = try dvui.testing.step(groupsFrame);
    const scale = test_scale;
    // Groups 1 and 2, and group 0 together: three fields, one capture.
    try std.testing.expectEqual(3, record.fields);
    try std.testing.expectEqual(1, record.captures);
    try std.testing.expectEqual(5, record.glass_shapes);
    try std.testing.expectEqual(2, record.field_lens[0]);
    try std.testing.expectEqual(12 * scale, record.field_merge[0]);
    try std.testing.expectEqual(1, record.field_lens[1]);
    try std.testing.expectEqual(12 * scale, record.field_merge[1]);
    try std.testing.expectEqual(2, record.field_lens[2]);
    try std.testing.expectEqual(0, record.field_merge[2]);
}

/// Replay details for headless widget tests; valid until the next replay.
pub fn drawnDetails() struct { radii: []const [4]f32, clips: []const dvui.Rect.Physical, jobs: usize, fields: usize, shapes: usize, merge: f32 } {
    if (!builtin.is_test) @compileError("drawnDetails is for tests");
    const n = @min(record.glass_shapes, record.rects.len);
    return .{ .jobs = record.jobs, .radii = record.radii[0..n], .clips = record.clips[0..n], .fields = record.fields, .shapes = record.glass_shapes, .merge = if (record.fields > 0) record.field_merge[0] else 0 };
}

fn currentFrame() !dvui.App.Result {
    try std.testing.expect(!current().active());
    var outer = layer(test_id, .{});
    try std.testing.expectEqual(outer.job, current().job);
    var inner = layer(test_id, .{});
    try std.testing.expectEqual(inner.job, current().job);
    inner.end();
    try std.testing.expectEqual(outer.job, current().job);
    outer.end();
    try std.testing.expect(!current().active());
    return .ok;
}

test "current is the innermost layer, and none after end" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    resetTest();
    _ = try dvui.testing.step(currentFrame);
    _ = try dvui.testing.step(currentFrame);
}

fn panelFrame() !dvui.App.Result {
    record.reset();
    var l = layer(test_id, .{ .merge = 12 });
    var seams = [_]LiquidField.Seam{
        .{ .axis = .vertical, .at = 50, .reach = 8 },
        .{ .axis = .horizontal, .at = 60, .reach = 8 },
    };
    try std.testing.expect(l.add(.{ .shape = .{ .panel = .{ .rect = .{ .x = 10, .y = 10, .w = 100, .h = 100 }, .radii = @splat(8), .seams = &seams } }, .group = 1 }));
    // The layer owns its seams even when the caller reuses its buffer before replay.
    seams[0].at = 70;
    try std.testing.expectEqual(50, l.job.?.items.items[0].shape.panel.seams[0].at);
    for (0..2) |i| try std.testing.expect(l.add(.{ .shape = .{ .box = .{ .rect = testRect(i) } }, .group = 1 }));
    l.end();
    try std.testing.expectEqual(1, record.fields);
    try std.testing.expectEqual(1, record.panels);
    try std.testing.expectEqual(2, record.glass_shapes);
    l = layer(test_id, .{ .merge = 12 });
    for (0..2) |_| try std.testing.expect(l.add(.{ .shape = .{ .panel = .{ .rect = testRect(0), .seams = &seams } }, .group = 1 }));
    try std.testing.expect(l.add(.{ .shape = .{ .box = .{ .rect = testRect(1) } }, .group = 1 }));
    l.end();
    try std.testing.expectEqual(2, record.fields);
    try std.testing.expectEqual(2, record.panels);
    try std.testing.expectEqual(0, record.field_lens[0]);
    try std.testing.expectEqual(1, record.field_lens[1]);
    return .ok;
}

test "a panel item becomes the field's panel" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    resetTest();
    _ = try dvui.testing.step(panelFrame);
}
