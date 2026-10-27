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

const Api = sdk.services.dashboard_cards.Api;
const Card = Api.Card;

/// How long a slide takes at the default motion speed and level (`core.motion.durationMs`).
const slide_ms: f32 = 280;

pub var carousel: Carousel = .{};
/// How many cards were drawn last frame (one, or two while a slide runs): what a test or an
/// agent reads to know the carousel shows one at a time.
pub var drawn: usize = 0;

pub fn draw(host: *sdk.Host) void {
    drawn = 0;
    var column = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .all(8) });
    defer column.deinit();

    const api = host.getServiceTyped(Api) orelse {
        _ = header(0, 0, null);
        return note("This app has no cards to show.");
    };
    const cards = api.list();
    const ids = host.arena().alloc(u64, cards.len) catch return;
    for (cards, ids) |c, *id| id.* = Carousel.hashId(c.id);
    carousel.sync(ids);

    const go = header(carousel.index, cards.len, ids);
    if (go) |dir| _ = carousel.go(ids, dir);
    if (cards.len == 0) return note("Nothing needs you.");

    var stage = dvui.overlay(@src(), .{ .expand = .both });
    defer stage.deinit();
    const stage_rect = stage.data().contentRect();
    const prev_clip = dvui.clip(stage.data().contentRectScale().r);
    defer dvui.clipSet(prev_clip);

    const t = carousel.progress(dvui.frameTimeNS(), core.motion.durationMs(slide_ms));
    const slide = carousel.slide;
    const shown = cards[carousel.index];
    if (t == null or slide == null) {
        drawCard(api, shown, 0, .{ .x = 0, .y = 0, .w = stage_rect.w, .h = stage_rect.h });
        return;
    }
    // Still moving: the next frame is wanted, and `slide` is what this frame ends on (it was
    // dropped by `progress` at the end, so its last frame is the card in place).
    dvui.refresh(null, @src(), stage.data().id);
    const off = Carousel.offsets(slide.?.dir, core.motion.settle(t.?));
    drawCard(api, shown, 0, .{ .x = off.entering * stage_rect.w, .y = 0, .w = stage_rect.w, .h = stage_rect.h });
    if (slide.?.from) |f| {
        drawCard(api, cards[f.index], 1, .{ .x = off.leaving * stage_rect.w, .y = 0, .w = stage_rect.w, .h = stage_rect.h });
    }
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
fn drawCard(api: *Api, card: Card, id_extra: usize, rect: dvui.Rect) void {
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
        if (dvui.button(@src(), a.label, .{}, .{ .id_extra = i, .style = style, .margin = .{ .w = 6 } })) {
            api.act(card.id, a.id);
        }
    }
}

fn note(text: []const u8) void {
    dvui.labelNoFmt(@src(), text, .{}, .{ .color_text = .{ .color = dim() }, .padding = .all(6) });
}

fn dim() dvui.Color {
    return dvui.themeGet().color(.control, .text).opacity(0.6);
}
