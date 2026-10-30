//! Glass drawn under a run of cards, and the visibility of glass ink in physical pixels, including
//! its antialiasing fringe.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const LiquidField = @import("glass").LiquidField;
const BlurBackdrop = @import("glass").BlurBackdrop;
const glass_look = @import("glass_look");
const material = @import("material.zig");
const dialogs = @import("dialogs.zig");

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

pub const Under = enum {
    /// The app's published picture (`material.publishBackdrop`) when there is one, else `capture`.
    backdrop,
    /// What is on the screen under the cards, copied and blurred (`BlurBackdrop.fieldPane`).
    capture,
};

pub const LayerOptions = struct {
    role: glass_look.Role = .card,
    /// Points: how near two cards come before their glass runs together.
    merge: f32 = 12,
    under: Under = .backdrop,
    tint: ?dvui.Color = null,
    mix: f32 = 0,
    /// The blur, for `.capture`.
    radius: f32 = 20,
    /// The cards' shadow rings' share, 0…1.
    shadow: f32 = 1,
};

/// Cards in one field: the program's shape slots, less the one an edge takes.
const field_cards = LiquidField.max_shapes - 1;

const Card = struct { rect: dvui.Rect.Physical, radii: [4]f32, corners: dvui.CornerRect };

/// Begin a layer: everything drawn until `end` goes over its glass, which is of the cards `add`ed
/// THIS frame and ordered under all of it, so it never trails a card that moves.
///
/// Drawing in the span is deferred, whatever the window was doing (as in a `dvui.RenderFrontToBack`
/// block), and replays at `end`: in an immediate context at once, in a deferred one (a floating
/// window, a picture, a front-to-back block) as one command at the layer's place. So the cards'
/// own draw-last commands (focus rings) draw at the layer's end, not at the subwindow's, and text
/// in the span is shaped at replay, as in every floating window. The span is a block: `end` runs
/// in the subwindow `layer` did, and a window opened inside it draws in its own subwindow.
///
///     var l = core.glass.layer(id, .{});
///     defer l.end();
///
/// `id` keys the capture of `.capture` and so must be stable.
pub fn layer(id: dvui.Id, opts: LayerOptions) Layer {
    if (!LiquidField.ready()) return .{};
    const cw = dvui.currentWindow();
    const job = cw.arena().create(Job) catch return .{};
    job.* = .{
        .id = id,
        .opts = opts,
        .scale = dvui.parentGet().screenRectScale(.{}).s,
        .subwindow = dvui.subwindowCurrentId(),
        .prev_rendering = dvui.renderingSet(false),
        .prev_queues = cw.defer_render,
    };
    cw.defer_render = &job.queues;
    // First in the span's queue, so under every card; the cards fill `job.cards` as they lay out.
    dvui.deferRender(job, Job.drawGlass);
    return .{ .job = job };
}

pub const Layer = struct {
    job: ?*Job = null,

    /// A card's border rect, physical, this frame's (`data().borderRectScale().r`), right after
    /// the card's box installs and before its contents. False with no glass program
    /// (`LiquidField.ready()`): the caller paints its fallback face. Cards go into fields of 15.
    pub fn add(self: *Layer, rect: dvui.Rect.Physical, corners: dvui.CornerRect) bool {
        const job = self.job orelse return false;
        const theme = dvui.themeGet();
        const c = corners.finalize(&theme);
        const s = job.scale;
        const card: Card = .{
            .rect = rect,
            .radii = .{ c.tl.radius() * s, c.tr.radius() * s, c.br.radius() * s, c.bl.radius() * s },
            .corners = corners,
        };
        job.cards.append(dvui.currentWindow().arena(), card) catch return false;
        return true;
    }

    pub fn end(self: *Layer) void {
        const job = self.job orelse return;
        self.job = null;
        const cw = dvui.currentWindow();
        std.debug.assert(cw.defer_render == &job.queues);
        std.debug.assert(dvui.subwindowCurrentId() == job.subwindow);
        cw.defer_render = job.prev_queues;
        _ = dvui.renderingSet(job.prev_rendering);
        dvui.deferRender(job, Job.replay);
    }
};

const Job = struct {
    id: dvui.Id,
    opts: LayerOptions,
    scale: f32,
    subwindow: dvui.Id,
    prev_rendering: bool,
    prev_queues: ?*dvui.RenderQueues,
    queues: dvui.RenderQueues = .{},
    cards: std.ArrayList(Card) = .empty,

    fn replay(ctx: ?*anyopaque) void {
        const job: *Job = @ptrCast(@alignCast(ctx orelse return));
        job.queues.render(dvui.currentWindow()) catch |err| dvui.logError(@src(), err, "glass layer could not replay", .{});
    }

    /// The layer's first command: at replay `cards` holds this frame's, all of them.
    fn drawGlass(ctx: ?*anyopaque) void {
        const job: *Job = @ptrCast(@alignCast(ctx orelse return));
        record.beginJob();
        var group: usize = 0;
        var field = job.newField();
        for (job.cards.items) |card| {
            if (!reaches(card.rect)) continue;
            field.add(.{ .rect = card.rect, .radii = card.radii });
            if (field.len == field_cards) {
                job.drawField(field, group);
                group += 1;
                field = job.newField();
            }
        }
        job.drawField(field, group);
        // The rings over the glass, never under it, so none lands on a neighbour drawn earlier.
        if (job.opts.shadow > 0) {
            const bs = dialogs.surfaceShadow();
            for (job.cards.items) |card| {
                if (!reaches(card.rect.insetAll(-bs.fade * job.scale))) continue;
                record.shadow();
                dialogs.glassShadow(card.rect, card.corners, job.scale, bs, job.opts.shadow);
            }
        }
    }

    fn newField(job: *const Job) LiquidField {
        return .{
            .scale = job.scale,
            .merge_px = job.opts.merge * job.scale,
            .role = job.opts.role,
            .tint = job.opts.tint,
            .mix = job.opts.mix,
        };
    }

    fn drawField(job: *const Job, field: LiquidField, group: usize) void {
        if (field.len == 0) return;
        record.field(&field);
        if (job.opts.under == .backdrop) {
            if (material.backdrop()) |b| {
                record.over();
                _ = field.drawOver(b.frost, b.sharp, b.covered);
                return;
            }
        }
        record.capture();
        BlurBackdrop.fieldPane(job.id.extendId(@src(), group), field, job.scale, .{
            .radius = job.opts.radius,
            .tint = job.opts.tint,
            .mix = job.opts.mix,
            .form = 1,
        });
    }
};

/// The shapes the last replayed job drew, physical (tests only).
pub fn drawnRects() []const dvui.Rect.Physical {
    if (!builtin.is_test) @compileError("drawnRects is for tests");
    return record.rects[0..@min(record.glass_shapes, record.rects.len)];
}

/// What the replay drew, for tests: nothing in other builds.
const record = if (builtin.is_test) struct {
    const Tag = enum { glass, shadow, card, float_core, float_dvui };
    var jobs: usize = 0;
    var captures: usize = 0;
    var overs: usize = 0;
    var glass_shapes: usize = 0;
    var shadow_shapes: usize = 0;
    var field_lens: [8]usize = undefined;
    var fields: usize = 0;
    var rects: [64]dvui.Rect.Physical = undefined;
    var order: [128]Tag = undefined;
    var order_len: usize = 0;

    fn reset() void {
        jobs = 0;
        captures = 0;
        overs = 0;
        glass_shapes = 0;
        shadow_shapes = 0;
        fields = 0;
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
        jobs += 1;
        log(.glass);
    }
    fn field(f: *const LiquidField) void {
        if (fields < field_lens.len) field_lens[fields] = f.len;
        fields += 1;
        for (f.shapes[0..f.len]) |sh| {
            if (glass_shapes < rects.len) rects[glass_shapes] = sh.rect;
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
    fn over() void {
        overs += 1;
    }
} else struct {
    fn beginJob() void {}
    fn field(_: *const LiquidField) void {}
    fn shadow() void {}
    fn capture() void {}
    fn over() void {}
};

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

/// Test frames: `n` cards stacked 12 px apart, each followed by a recorded fill.
var test_n: usize = 3;

fn testRect(i: usize) dvui.Rect.Physical {
    return .{ .x = 20, .y = 20 + 12 * @as(f32, @floatFromInt(i)), .w = 100, .h = 10 };
}

fn recordFill(ctx: ?*anyopaque) void {
    const tag: record.Tag = if (ctx) |c| @fromBackingInt(@intCast(@intFromPtr(c))) else .card;
    record.log(tag);
}

fn fill(tag: record.Tag) void {
    dvui.deferRender(@ptrFromInt(@backingInt(tag)), recordFill);
}

fn addCards(l: *Layer) !void {
    for (0..test_n) |i| {
        try std.testing.expect(l.add(testRect(i), .round(8)));
        fill(.card);
    }
}

fn immediateFrame() !dvui.App.Result {
    record.reset();
    var l = layer(test_id, .{});
    try addCards(&l);
    try std.testing.expectEqual(0, record.glass_shapes);
    try std.testing.expectEqual(0, record.shadow_shapes);
    l.end();
    return .ok;
}

fn floatFrame() !dvui.App.Result {
    record.reset();
    // lint-allow(raw-transient-surface): the test is about dvui's own float inside a layer.
    var win = dvui.floatingWindow(@src(), .{}, .{ .rect = .{ .x = 0, .y = 0, .w = 500, .h = 350 } });
    defer win.deinit();
    var l = layer(test_id, .{});
    try addCards(&l);
    l.end();
    return .ok;
}

fn expectCardRects(count: usize) !void {
    try std.testing.expectEqual(count, record.glass_shapes);
    for (0..count) |i| try std.testing.expectEqual(testRect(i), record.rects[i]);
}

test "a layer draws this frame's cards" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    LiquidField.readyInTest(true);
    test_n = 3;
    _ = try dvui.testing.step(immediateFrame);
    try std.testing.expectEqual(1, record.jobs);
    try std.testing.expectEqual(1, record.fields);
    try std.testing.expectEqual(3, record.field_lens[0]);
    try expectCardRects(3);
    // Moved the same frame, not the next: the rects are the ones added before `end`.
    test_n = 2;
    _ = try dvui.testing.step(immediateFrame);
    try expectCardRects(2);
}

test "15 cards make one field, the 16th starts a second" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    LiquidField.readyInTest(true);
    test_n = 16;
    _ = try dvui.testing.step(immediateFrame);
    try std.testing.expectEqual(2, record.fields);
    try std.testing.expectEqual(15, record.field_lens[0]);
    try std.testing.expectEqual(1, record.field_lens[1]);
    test_n = 15;
    _ = try dvui.testing.step(immediateFrame);
    try std.testing.expectEqual(1, record.fields);
}

test "the glass is under the cards" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    LiquidField.readyInTest(true);
    test_n = 3;
    _ = try dvui.testing.step(immediateFrame);
    const order = record.order[0..record.order_len];
    try std.testing.expectEqual(record.Tag.glass, order[0]);
    var cards: usize = 0;
    for (order, 0..) |tag, i| {
        if (tag != .card) continue;
        try std.testing.expect(i > 0);
        cards += 1;
    }
    try std.testing.expectEqual(3, cards);
    // The rings come with the glass, before any card's fill.
    for (order[1 .. 1 + record.shadow_shapes]) |tag| try std.testing.expectEqual(record.Tag.shadow, tag);
}

test "immediate and deferred alike" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    LiquidField.readyInTest(true);
    test_n = 3;
    const cw = dvui.currentWindow();
    _ = try dvui.testing.step(immediateFrame);
    try expectCardRects(3);
    try std.testing.expect(cw.render_target.rendering);
    try std.testing.expect(cw.defer_render == null);
    _ = try dvui.testing.step(floatFrame);
    try expectCardRects(3);
    try std.testing.expectEqual(1, record.jobs);
    try std.testing.expect(cw.render_target.rendering);
    try std.testing.expect(cw.defer_render == null);
}

test "over a published backdrop a layer captures nothing" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    LiquidField.readyInTest(true);
    test_n = 3;
    const texture = try dvui.textureCreate(&(@as([4]dvui.Color.PMA, @splat(.{ .r = 255, .g = 255, .b = 255, .a = 255 }))), .{ .width = 2, .height = 2 });
    defer dvui.textureDestroyLater(texture);
    material.publishBackdrop(.{ .sharp = texture, .frost = texture, .covered = .{ .w = 600, .h = 400 } });
    _ = try dvui.testing.step(immediateFrame);
    try std.testing.expectEqual(0, record.captures);
    try std.testing.expectEqual(1, record.overs);
    try std.testing.expectEqual(1, record.jobs);
    material.publishBackdrop(null);
    _ = try dvui.testing.step(immediateFrame);
    try std.testing.expectEqual(1, record.captures);
    try std.testing.expectEqual(0, record.overs);
}

test "30 cards: glass and shadows both drawn at replay" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    LiquidField.readyInTest(true);
    test_n = 30;
    _ = try dvui.testing.step(immediateFrame);
    try std.testing.expectEqual(30, record.glass_shapes);
    try std.testing.expectEqual(30, record.shadow_shapes);
}

fn nestedFrame() !dvui.App.Result {
    record.reset();
    const cw = dvui.currentWindow();
    var l = layer(test_id, .{});
    try addCards(&l);
    const queued = l.job.?.queues.normal.items.len;
    {
        var win = fizzy_floating(@src());
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

fn fizzy_floating(src: std.lang.SourceLocation) *@import("widgets/FloatingWindowWidget.zig") {
    return @import("widgets.zig").floatingWindow(src, .{}, .{ .rect = .{ .x = 10, .y = 10, .w = 100, .h = 100 } });
}

test "a floating window opened inside the layer draws normally" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    LiquidField.readyInTest(true);
    test_n = 3;
    _ = try dvui.testing.step(nestedFrame);
    // Both draw, after the page: each in its own subwindow.
    const order = record.order[0..record.order_len];
    try std.testing.expectEqual(record.Tag.float_core, order[order.len - 2]);
    try std.testing.expectEqual(record.Tag.float_dvui, order[order.len - 1]);
}

test "keptFrost re-blurs only when the version changes" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const Blur = struct {
        var calls: usize = 0;
        fn run(sharp: dvui.Texture, radius: f32) ?dvui.Texture {
            calls += 1;
            std.debug.assert(radius == 8);
            const pixels = dvui.currentWindow().arena().alloc(dvui.Color.PMA, sharp.width * sharp.height) catch return null;
            @memset(pixels, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
            return dvui.textureCreate(pixels, .{ .width = sharp.width, .height = sharp.height }) catch null;
        }
    };
    Blur.calls = 0;
    material.blur_in_test = Blur.run;
    defer material.blur_in_test = null;
    const texture = try dvui.textureCreate(&(@as([16 * 16]dvui.Color.PMA, @splat(.{ .r = 255, .g = 255, .b = 255, .a = 255 }))), .{ .width = 16, .height = 16 });
    defer dvui.textureDestroyLater(texture);
    const first = material.keptFrost(texture, 8, 1).?;
    try std.testing.expectEqual(first, material.keptFrost(texture, 8, 1).?);
    try std.testing.expectEqual(1, Blur.calls);
    const second = material.keptFrost(texture, 8, 2).?;
    try std.testing.expectEqual(2, Blur.calls);
    try std.testing.expect(!std.meta.eql(first, second));
}
