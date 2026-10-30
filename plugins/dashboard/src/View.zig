//! The Needs-you card: the cards the provider has for the person, one at a time. A header with
//! the title and, at the right, "1 of N" and the previous and next buttons; under it the card
//! shown, whole, with its actions. Going to another slides it in from the side it is going
//! toward while the one before slides out, both clipped to the card's place: only position
//! moves, nothing fades over a large area.
//!
//! Every colour is the theme's (`control` for the card, `highlight` and `err` for emphasised
//! actions), so another app's look applies.
const std = @import("std");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const core = @import("core");
const Carousel = @import("Carousel.zig");
const demo_cards = @import("demo_cards.zig");

const Api = sdk.services.dashboard_cards.Api;
const Card = Api.Card;

/// How long a slide takes at the default motion speed and level (`core.motion.durationMs`).
const slide_ms: f32 = 280;

pub var carousel: Carousel = .{};
/// How many cards were drawn last frame (one, or two while a slide runs): what a test or an
/// agent reads to know the carousel shows one at a time.
pub var drawn: usize = 0;

/// The provider whose cards are shown: whichever the host has, else the demo's. The demo is a
/// fallback and not a registered service, so a provider loaded after the dashboard is the one
/// listed from its first frame.
pub fn provider(host: *sdk.Host) *Api {
    return host.getServiceTyped(Api) orelse &demo_cards.api;
}

/// An action the person picked this frame. The strings are the provider's, valid until `act`.
const Pick = struct { card_id: []const u8, action_id: []const u8 };

pub fn draw(host: *sdk.Host) void {
    drawn = 0;
    var column = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .all(8) });
    defer column.deinit();

    const api = provider(host);
    // Finish reading cards before `act` can free them.
    const picked = drawCards(api) orelse return;
    api.act(picked.card_id, picked.action_id);
}

fn drawCards(api: *Api) ?Pick {
    const cards = api.list();
    const ids = dvui.currentWindow().arena().alloc(u64, cards.len) catch return null;
    for (cards, ids) |c, *id| id.* = Carousel.hashId(c.id);
    carousel.sync(ids);

    const go = header(carousel.index, cards.len, ids);
    if (go) |dir| _ = carousel.go(ids, dir);
    if (cards.len == 0) {
        note("Nothing needs you.");
        return null;
    }

    var stage = dvui.overlay(@src(), .{ .expand = .both });
    defer stage.deinit();
    const stage_rect = stage.data().contentRect();
    const prev_clip = dvui.clip(stage.data().contentRectScale().r);
    defer dvui.clipSet(prev_clip);

    const t = carousel.progress(dvui.frameTimeNS(), core.motion.durationMs(slide_ms));
    const slide = carousel.slide;
    const shown = cards[carousel.index];
    var picked: ?Pick = null;
    if (t == null or slide == null) {
        drawCard(&picked, shown, 0, .{ .x = 0, .y = 0, .w = stage_rect.w, .h = stage_rect.h });
        return picked;
    }
    // Still moving: the next frame is wanted, and `slide` is what this frame ends on (it was
    // dropped by `progress` at the end, so its last frame is the card in place).
    dvui.refresh(null, @src(), stage.data().id);
    const off = Carousel.offsets(slide.?.dir, core.motion.settle(t.?));
    drawCard(&picked, shown, 0, .{ .x = off.entering * stage_rect.w, .y = 0, .w = stage_rect.w, .h = stage_rect.h });
    if (slide.?.from) |f| {
        drawCard(&picked, cards[f.index], 1, .{ .x = off.leaving * stage_rect.w, .y = 0, .w = stage_rect.w, .h = stage_rect.h });
    }
    return picked;
}

/// The title on the left; on the right the count and the two buttons. Returns the way the person
/// asked to go, if they did. With `ids` null (no provider) there is nothing to count.
fn header(index: usize, count: usize, ids: ?[]const u64) ?Carousel.Dir {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .h = 6 } });
    defer row.deinit();
    dvui.labelNoFmt(@src(), "Needs you", .{}, .{ .font = dvui.Font.theme(.title).larger(-2), .gravity_y = 0.5 });
    _ = dvui.spacer(@src(), .{ .expand = .horizontal });
    if (ids == null or count == 0) return null;

    var go: ?Carousel.Dir = null;
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d} of {d}", .{ index + 1, count }) catch "";
    dvui.labelNoFmt(@src(), text, .{}, .{ .gravity_y = 0.5, .margin = .{ .w = 6 }, .color_text = .{ .color = dim() } });
    // Two buttons only mean something with a second card to go to.
    const spare = count > 1;
    if (button("previous", dvui.entypo.chevron_small_left, spare, "dashboard.prev", 0)) go = .prev;
    if (button("next", dvui.entypo.chevron_small_right, spare, "dashboard.next", 1)) go = .next;
    return go;
}

/// `tag` is the anchor a demo aims at.
fn button(name: []const u8, glyph: []const u8, enabled: bool, tag: []const u8, id_extra: usize) bool {
    const theme = dvui.themeGet();
    const color = if (enabled) theme.color(.control, .text) else dim();
    const clicked = dvui.buttonIcon(@src(), name, glyph, .{}, .{ .stroke_color = .{ .color = color } }, .{
        .id_extra = id_extra,
        .tag = tag,
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 16, .h = 16 },
    });
    return clicked and enabled;
}

/// One card in `rect` (within the stage), whole: its source, title and body, then its actions.
fn drawCard(picked: *?Pick, card: Card, id_extra: usize, rect: dvui.Rect) void {
    drawn += 1;
    const theme = dvui.themeGet();
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = id_extra,
        .rect = rect,
        .background = true,
        .color_fill = .{ .color = theme.color(.control, .fill) },
        .border = .all(1),
        .color_border = .{ .color = theme.color(.control, .border) },
        .corners = .all(8),
        .padding = .all(12),
    });
    defer box.deinit();

    if (card.source.len > 0) {
        dvui.labelNoFmt(@src(), card.source, .{}, .{ .color_text = .{ .color = dim() }, .margin = .{ .h = 2 } });
    }
    dvui.labelNoFmt(@src(), card.title, .{}, .{ .font = dvui.Font.theme(.title).larger(-4), .margin = .{ .h = 6 } });

    {
        var scroll = core.widgets.ScrollArea.init(@src(), .{ .horizontal = .none, .vertical_bar = .auto_overlay }, .{ .expand = .both, .background = false });
        defer scroll.deinit();
        var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false });
        defer tl.deinit();
        tl.addText(card.body, .{});
    }

    if (card.actions.len == 0) return;
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 8 } });
    defer row.deinit();
    for (card.actions, 0..) |a, i| {
        const style: ?dvui.Theme.Style.Name = switch (a.emphasis) {
            .normal => null,
            .primary => .highlight,
            .destructive => .err,
        };
        const tag = dvui.currentWindow().arena().print("dashboard.action.{d}.{d}", .{ id_extra, i }) catch null;
        if (dvui.button(@src(), a.label, .{}, .{ .id_extra = i, .tag = tag, .style = style, .margin = .{ .w = 6 } })) {
            picked.* = .{ .card_id = card.id, .action_id = a.id };
        }
    }
}

fn note(text: []const u8) void {
    dvui.labelNoFmt(@src(), text, .{}, .{ .color_text = .{ .color = dim() }, .padding = .all(6) });
}

fn dim() dvui.Color {
    return dvui.themeGet().color(.control, .text).opacity(0.6);
}

/// A provider whose cards live on the heap and are freed when one is answered, as a real one's do.
const HeapProvider = struct {
    gpa: std.mem.Allocator,
    cards: []Card = &.{},
    generation: u32 = 0,
    answered: ?[]const u8 = null,

    fn add(self: *HeapProvider, id: []const u8, labels: []const []const u8) !void {
        const actions = try self.gpa.alloc(Api.Action, labels.len);
        for (actions, labels) |*a, l| a.* = .{ .id = try self.gpa.dupe(u8, l), .label = try self.gpa.dupe(u8, l) };
        const cards = try self.gpa.realloc(self.cards, self.cards.len + 1);
        cards[cards.len - 1] = .{ .id = try self.gpa.dupe(u8, id), .title = try self.gpa.dupe(u8, id), .body = try self.gpa.dupe(u8, id), .actions = actions };
        self.cards = cards;
    }

    fn freeCards(self: *HeapProvider) void {
        for (self.cards) |c| {
            for (c.actions) |a| {
                self.gpa.free(a.id);
                self.gpa.free(a.label);
            }
            self.gpa.free(c.actions);
            self.gpa.free(c.id);
            self.gpa.free(c.title);
            self.gpa.free(c.body);
        }
        self.gpa.free(self.cards);
        self.cards = &.{};
    }

    fn list(ctx: *anyopaque) []const Card {
        const self: *HeapProvider = @ptrCast(@alignCast(ctx));
        return self.cards;
    }

    fn act(ctx: *anyopaque, card_id: []const u8, action_id: []const u8) void {
        const self: *HeapProvider = @ptrCast(@alignCast(ctx));
        self.answered = self.gpa.dupe(u8, action_id) catch null;
        _ = card_id;
        self.freeCards();
        self.generation +%= 1;
    }

    fn currentGeneration(ctx: *anyopaque) u32 {
        const self: *HeapProvider = @ptrCast(@alignCast(ctx));
        return self.generation;
    }

    const vtable: Api.VTable = .{ .list = list, .act = act, .generation = currentGeneration };

    fn api(self: *HeapProvider) Api {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

var test_host: *sdk.Host = undefined;

fn testFrame() !dvui.App.Result {
    draw(test_host);
    return .ok;
}

test "an action picked on a card is acted on after the card is drawn, not while the provider's list is in use" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 400 } });
    defer t.deinit();
    var host: sdk.Host = .init(std.testing.allocator);
    defer host.deinit();
    test_host = &host;

    var heap: HeapProvider = .{ .gpa = std.testing.allocator };
    defer {
        heap.freeCards();
        if (heap.answered) |a| heap.gpa.free(a);
    }
    try heap.add("card", &.{ "first", "second", "third" });
    var api = heap.api();
    try host.registerService(Api, &api, null);

    try dvui.testing.settle(testFrame);
    try dvui.testing.moveTo("dashboard.action.0.0");
    try dvui.testing.click(.left);
    // `act` frees the card the loop was walking; a later action button read from it would be a
    // use after free, which the testing allocator and the filled freed memory turn into a crash.
    _ = try dvui.testing.step(testFrame);
    try std.testing.expectEqualStrings("first", heap.answered orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(@as(usize, 0), heap.cards.len);
    try dvui.testing.settle(testFrame);
}

test "a provider registered after the dashboard is the one listed, over the demo's cards" {
    var host: sdk.Host = .init(std.testing.allocator);
    defer host.deinit();
    try @import("../plugin.zig").register(&host);
    try std.testing.expectEqual(&demo_cards.api, provider(&host));

    var heap: HeapProvider = .{ .gpa = std.testing.allocator };
    defer heap.freeCards();
    try heap.add("mine", &.{"ok"});
    var api = heap.api();
    try host.registerService(Api, &api, null);

    try std.testing.expectEqual(&api, provider(&host));
    try std.testing.expectEqualStrings("mine", provider(&host).list()[0].id);
}

test "cards with the same action id have distinct tags during a slide" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 400 } });
    defer t.deinit();
    var host: sdk.Host = .init(std.testing.allocator);
    defer host.deinit();
    test_host = &host;
    carousel = .{};
    defer carousel = .{};

    var heap: HeapProvider = .{ .gpa = std.testing.allocator };
    defer heap.freeCards();
    try heap.add("one", &.{"approve"});
    try heap.add("two", &.{"approve"});
    var api = heap.api();
    try host.registerService(Api, &api, null);

    try dvui.testing.settle(testFrame);
    const ids = [_]u64{ Carousel.hashId("one"), Carousel.hashId("two") };
    try std.testing.expect(carousel.go(&ids, .next));
    _ = try dvui.testing.step(testFrame);
    try std.testing.expectEqual(@as(usize, 2), drawn);
    const entering = try dvui.testing.tagGet("dashboard.action.0.0");
    const leaving = try dvui.testing.tagGet("dashboard.action.1.0");
    try std.testing.expect(entering.id != leaving.id);
}
