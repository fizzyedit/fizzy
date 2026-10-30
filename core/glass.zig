//! Shared glass layers and visibility of their ink, including the physical antialiasing fringe.
const std = @import("std");
const dvui = @import("dvui");

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

const LiquidField = @import("glass").LiquidField;
const BlurBackdrop = @import("glass").BlurBackdrop;
const material = @import("material.zig");
const glass_look = @import("glass_look");

pub const Under = enum { backdrop, capture };
pub const LayerOptions = struct {
    role: glass_look.Role = .card,
    merge: f32 = 12,
    under: Under = .backdrop,
    tint: ?dvui.Color = null,
    mix: f32 = 0,
    radius: f32 = 20,
};

const Card = struct { rect: dvui.Rect, corners: dvui.CornerRect };

/// Begin under the cards that follow, using last frame's content coordinates.
/// Fields hold at most 15 cards; further cards start another field.
pub fn layer(id: dvui.Id, opts: LayerOptions) Layer {
    const out: Layer = .{ .id = id };
    if (@import("builtin").is_test) {
        dvui.dataSet(null, id, "_layer_captures", @as(usize, 0));
        dvui.dataSetSlice(null, id, "_layer_fields", @as([]const LiquidField, &.{}));
    }
    if (!LiquidField.ready()) return out;
    const cards = dvui.dataGetSlice(null, id, "_layer_cards", []Card) orelse return out;
    const rs = dvui.parentGet().screenRectScale(.{});
    var field: LiquidField = .{
        .scale = rs.s,
        .merge_px = opts.merge * rs.s,
        .role = opts.role,
        .tint = opts.tint,
        .mix = opts.mix,
    };
    var group: usize = 0;
    for (cards) |card| {
        const rect = rs.rectToPhysical(card.rect);
        if (!reaches(rect)) continue;
        const theme = dvui.themeGet();
        const c = card.corners.finalize(&theme);
        field.add(.{ .rect = rect, .radii = .{ c.tl.radius() * rs.s, c.tr.radius() * rs.s, c.br.radius() * rs.s, c.bl.radius() * rs.s } });
        if (field.len == 15) {
            drawLayer(id, group, field, opts);
            field.len = 0;
            group += 1;
        }
    }
    if (field.len > 0) drawLayer(id, group, field, opts);
    return out;
}

fn drawLayer(id: dvui.Id, group: usize, field: LiquidField, opts: LayerOptions) void {
    if (@import("builtin").is_test) {
        const previous = dvui.dataGetSlice(null, id, "_layer_fields", []LiquidField).?;
        const fields = dvui.currentWindow().arena().alloc(LiquidField, previous.len + 1) catch return;
        @memcpy(fields[0..previous.len], previous);
        fields[previous.len] = field;
        dvui.dataSetSlice(null, id, "_layer_fields", fields);
    }
    if (opts.under == .backdrop) {
        if (material.backdrop()) |b| {
            _ = field.drawOver(b.frost, b.sharp, b.covered);
            return;
        }
    }
    if (@import("builtin").is_test) {
        const n = dvui.dataGet(null, id, "_layer_captures", usize).?;
        dvui.dataSet(null, id, "_layer_captures", n + 1);
    }
    BlurBackdrop.fieldPane(id.extendId(@src(), group), field, field.scale, .{
        .radius = opts.radius,
        .tint = opts.tint,
        .mix = opts.mix,
        .form = 1,
    });
}

pub const Layer = struct {
    id: dvui.Id,
    cards: std.ArrayList(Card) = .empty,

    /// Record in the parent's content coordinates for next frame. False on allocation failure.
    pub fn add(self: *Layer, rect: dvui.Rect, corners: dvui.CornerRect) bool {
        self.cards.append(dvui.currentWindow().arena(), .{ .rect = rect, .corners = corners }) catch return false;
        return true;
    }

    pub fn end(self: *Layer) void {
        dvui.dataSetSlice(null, self.id, "_layer_cards", self.cards.items);
    }
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

fn testCards(count: usize) !void {
    var l = layer(test_id, .{});
    for (0..count) |i| {
        try std.testing.expect(l.add(.{ .x = 20, .y = 60 + @as(f32, @floatFromInt(i)), .w = 100, .h = 60 }, .round(8)));
    }
    l.end();
}

fn testFields() []LiquidField {
    return dvui.dataGetSlice(null, test_id, "_layer_fields", []LiquidField).?;
}

fn emptyFrame() !dvui.App.Result {
    return .ok;
}

test "a layer draws last frame's cards" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    LiquidField.readyInTest(true);
    try testCards(3);
    try std.testing.expectEqual(0, testFields().len);
    _ = try dvui.testing.step(emptyFrame);
    const rs = dvui.parentGet().screenRectScale(.{});
    var l = layer(test_id, .{});
    l.end();
    try std.testing.expectEqual(1, testFields().len);
    try std.testing.expectEqual(3, testFields()[0].len);
    try std.testing.expectEqual(rs.rectToPhysical(.{ .x = 20, .y = 60, .w = 100, .h = 60 }), testFields()[0].shapes[0].rect);
    // An empty list replaces the previous frame, rather than retaining vanished cards.
    _ = try dvui.testing.step(emptyFrame);
    l = layer(test_id, .{});
    l.end();
    try std.testing.expectEqual(0, testFields().len);
}

test "15 cards make one field, the 16th starts a second" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    LiquidField.readyInTest(true);
    try testCards(16);
    _ = try dvui.testing.step(emptyFrame);
    var l = layer(test_id, .{});
    l.end();
    try std.testing.expectEqual(2, testFields().len);
    try std.testing.expectEqual(15, testFields()[0].len);
    try std.testing.expectEqual(1, testFields()[1].len);
}

test "a scroll moves last frame's cards rigidly" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    LiquidField.readyInTest(true);
    var si: dvui.ScrollInfo = .{ .virtual_size = .{ .w = 200, .h = 1000 } };
    var area = @import("widgets/ScrollArea.zig").init(@src(), .{ .scroll_info = &si }, .{ .rect = .{ .w = 200, .h = 200 } });
    const rs = dvui.parentGet().screenRectScale(.{});
    try testCards(3);
    area.deinit();
    _ = try dvui.testing.step(emptyFrame);
    si.viewport.y = 40;
    area = @import("widgets/ScrollArea.zig").init(@src(), .{ .scroll_info = &si }, .{ .rect = .{ .w = 200, .h = 200 } });
    var l = layer(test_id, .{});
    l.end();
    try std.testing.expectEqual(3, testFields()[0].len);
    for (testFields()[0].shapes[0..3], 0..) |shape, i| {
        const y = 60 + @as(f32, @floatFromInt(i));
        try std.testing.expectApproxEqAbs(rs.rectToPhysical(.{ .y = y }).y - 40 * rs.s, shape.rect.y, 0.01);
    }
    area.deinit();
}

test "over a published backdrop a layer captures nothing" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    LiquidField.readyInTest(true);
    try testCards(1);
    _ = try dvui.testing.step(emptyFrame);
    const texture = try dvui.textureCreate(&(@as([16 * 16]dvui.Color.PMA, @splat(.{ .r = 255, .g = 255, .b = 255, .a = 255 }))), .{ .width = 16, .height = 16 });
    defer dvui.textureDestroyLater(texture);
    material.publishBackdrop(.{ .sharp = texture, .frost = texture, .covered = .{ .w = 600, .h = 400 } });
    var queues: dvui.RenderQueues = .{};
    const cw = dvui.currentWindow();
    const prev_rendering = dvui.renderingSet(false);
    defer _ = dvui.renderingSet(prev_rendering);
    cw.defer_render = &queues;
    defer cw.defer_render = null;
    var l = layer(test_id, .{});
    try std.testing.expectEqual(0, dvui.dataGet(null, test_id, "_layer_captures", usize).?);
    try std.testing.expectEqual(1, queues.normal.items.len);
    try std.testing.expect(queues.normal.items[0].cmd == .custom);
    material.publishBackdrop(null);
    l = layer(test_id, .{});
    try std.testing.expectEqual(1, dvui.dataGet(null, test_id, "_layer_captures", usize).?);
    material.publishBackdrop(.{ .sharp = texture, .frost = texture, .covered = .{ .w = 600, .h = 400 } });
    l = layer(test_id, .{ .under = .capture });
    try std.testing.expectEqual(1, dvui.dataGet(null, test_id, "_layer_captures", usize).?);
    l.end();
}

test "keptFrost re-blurs only when the version changes" {
    try material.testKeptFrost();
}
