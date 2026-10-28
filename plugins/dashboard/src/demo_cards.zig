//! A tiny `dashboard.cards` provider of three made-up cards, so the dashboard can be tried before
//! an app has a provider of its own. The view falls back to it when the host has none
//! (`View.provider`); it is never registered as the service. Answering a card (any action) drops
//! it, as a real provider does.
const std = @import("std");
const sdk = @import("fizzy_sdk");

const Api = sdk.services.dashboard_cards.Api;

const all = [_]Api.Card{
    .{
        .id = "demo.review",
        .title = "Review the layout change?",
        .source = "Demo worker",
        .body = "The worker finished the split-tree change and opened a pull request. The diff is 312 lines, the gates passed, and it asks whether to mark the pull request ready for review.",
        .actions = &.{
            .{ .id = "ready", .label = "Mark ready", .emphasis = .primary },
            .{ .id = "later", .label = "Not yet" },
        },
    },
    .{
        .id = "demo.delete",
        .title = "Delete the old build cache?",
        .source = "Demo housekeeping",
        .body = "The build cache holds 6.4 GB that nothing has read in three weeks. Deleting it frees the space; the next build recreates what it needs and runs slower once.",
        .actions = &.{
            .{ .id = "delete", .label = "Delete", .emphasis = .destructive },
            .{ .id = "keep", .label = "Keep" },
        },
    },
    .{
        .id = "demo.question",
        .title = "Which name should the plugin take?",
        .source = "Demo planner",
        .body = "Two names are open for the new plugin: one says what it shows, the other what it is for. Either is fine to ship; the planner only needs one picked before it writes the docs.",
        .actions = &.{
            .{ .id = "shows", .label = "What it shows" },
            .{ .id = "for", .label = "What it is for" },
        },
    },
};

var answered: [all.len]bool = @splat(false);
var listed: [all.len]Api.Card = undefined;
var generation: u32 = 0;

fn list(_: *anyopaque) []const Api.Card {
    var n: usize = 0;
    for (all, answered) |c, gone| {
        if (gone) continue;
        listed[n] = c;
        n += 1;
    }
    return listed[0..n];
}

fn act(_: *anyopaque, card_id: []const u8, action_id: []const u8) void {
    for (all, &answered) |c, *gone| {
        if (gone.* or !std.mem.eql(u8, c.id, card_id)) continue;
        for (c.actions) |a| if (std.mem.eql(u8, a.id, action_id)) {
            gone.* = true;
            generation +%= 1;
        };
    }
}

fn currentGeneration(_: *anyopaque) u32 {
    return generation;
}

const vtable: Api.VTable = .{ .list = list, .act = act, .generation = currentGeneration };

var token: u8 = 0;
pub var api: Api = .{ .ctx = &token, .vtable = &vtable };

/// Bring the three cards back, for a run that starts over.
pub fn reset() void {
    answered = @splat(false);
    generation +%= 1;
}

test "answering a card drops it from the list and moves the generation" {
    reset();
    defer reset();
    try std.testing.expectEqual(@as(usize, 3), api.list().len);
    const before = api.generation();
    api.act("demo.nothing", "ready");
    api.act("demo.review", "nothing");
    try std.testing.expectEqual(@as(usize, 3), api.list().len);
    api.act("demo.review", "ready");
    try std.testing.expectEqual(@as(usize, 2), api.list().len);
    try std.testing.expectEqualStrings("demo.delete", api.list()[0].id);
    try std.testing.expect(api.generation() != before);
}
