//! The command palette's recently used commands: ids, oldest first, capped at `max`. Held by
//! `Recents` and stored in `recents.zon` beside the recent folders. std-only, so the ordering
//! rules are unit-tested without a Window (`build/app.zig`).
const std = @import("std");

const RecentCommands = @This();

/// How many commands are remembered.
pub const max: usize = 8;

/// Oldest first, like `Recents.folders`; owned. Ids, not titles: a command whose plugin is gone
/// simply is not shown, and comes back with the plugin.
ids: std.ArrayList([]const u8) = .empty,

/// Copies of `ids` (as read from disk), empty entries dropped, at most `max`.
pub fn fromIds(gpa: std.mem.Allocator, ids: []const []const u8) RecentCommands {
    var self: RecentCommands = .{};
    for (ids) |id| {
        if (id.len == 0) continue;
        if (self.ids.items.len >= max) break;
        const owned = gpa.dupe(u8, id) catch break;
        self.ids.append(gpa, owned) catch {
            gpa.free(owned);
            break;
        };
    }
    return self;
}

/// `id` was just run: it moves to (or joins at) the recent end, and the oldest falls off past
/// `max`.
pub fn use(self: *RecentCommands, gpa: std.mem.Allocator, id: []const u8) !void {
    for (self.ids.items, 0..) |existing, i| {
        if (std.mem.eql(u8, existing, id)) {
            const kept = self.ids.orderedRemove(i);
            try self.ids.append(gpa, kept);
            return;
        }
    }
    const owned = try gpa.dupe(u8, id);
    errdefer gpa.free(owned);
    if (self.ids.items.len >= max) gpa.free(self.ids.orderedRemove(0));
    try self.ids.append(gpa, owned);
}

/// How recently `id` was run: 0 for the most recent, null if it is not remembered.
pub fn recency(self: *const RecentCommands, id: []const u8) ?usize {
    const items = self.ids.items;
    for (items, 0..) |existing, i| {
        if (std.mem.eql(u8, existing, id)) return items.len - 1 - i;
    }
    return null;
}

pub fn deinit(self: *RecentCommands, gpa: std.mem.Allocator) void {
    for (self.ids.items) |id| gpa.free(id);
    self.ids.deinit(gpa);
    self.* = .{};
}

test "most recent first, re-use moves to the top, oldest drops past the cap" {
    const gpa = std.testing.allocator;
    var r: RecentCommands = .{};
    defer r.deinit(gpa);

    try r.use(gpa, "a");
    try r.use(gpa, "b");
    try std.testing.expectEqual(@as(?usize, 0), r.recency("b"));
    try std.testing.expectEqual(@as(?usize, 1), r.recency("a"));

    // Re-using "a" makes it the most recent, without a second entry.
    try r.use(gpa, "a");
    try std.testing.expectEqual(@as(?usize, 0), r.recency("a"));
    try std.testing.expectEqual(@as(?usize, 1), r.recency("b"));
    try std.testing.expectEqual(@as(usize, 2), r.ids.items.len);

    // Past the cap the oldest falls off.
    var buf: [8]u8 = undefined;
    for (0..max) |i| try r.use(gpa, try std.mem.print(&buf, "c{d}", .{i}));
    try std.testing.expectEqual(max, r.ids.items.len);
    try std.testing.expectEqual(@as(?usize, null), r.recency("b"));
    try std.testing.expectEqual(@as(?usize, 0), r.recency("c7"));
    try std.testing.expectEqual(@as(?usize, null), r.recency("missing"));
}

test "from disk: empty ids dropped, capped" {
    const gpa = std.testing.allocator;
    const on_disk = [_][]const u8{ "", "x", "y", "a", "b", "c", "d", "e", "f", "g" };
    var r = fromIds(gpa, &on_disk);
    defer r.deinit(gpa);
    try std.testing.expectEqual(max, r.ids.items.len);
    try std.testing.expectEqualStrings("x", r.ids.items[0]);
    try std.testing.expectEqual(@as(?usize, 0), r.recency("f"));
}
