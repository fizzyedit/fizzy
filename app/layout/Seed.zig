//! The arrangement a shape starts from: a value tree of splits and named leaves.
//!
//! Converted to a live `DockLayout` the first time `Layout.tree` runs (or after Reset Layout).
//! After that the live tree is the truth and this seed is only consulted for a leaf's keywords
//! / shows / pinned, and as the thing Reset Layout returns to.
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const sdk = @import("fizzy_sdk");

const DockLayout = core.widgets.DockLayout;

const Seed = @This();

pub const Shows = sdk.RegionSpec.Shows;

/// A binary tree of splits with named leaves at the fringes — the same shape as
/// `DockLayout.Snapshot.Tree`, with region spec on the leaves instead of tab slugs.
pub const Tree = union(enum) {
    split: Tree.Split,
    leaf: Tree.Leaf,

    pub const Split = struct {
        dir: dvui.enums.Direction,
        ratio: f32 = 0.5,
        fixed: ?DockLayout.Node.Split.Fixed = null,
        fit: ?DockLayout.Node.Split.Fit = null,
        first: *const Tree,
        second: *const Tree,
    };

    pub const Leaf = struct {
        name: []const u8,
        keywords: []const []const u8 = &.{},
        shows: Shows = .one,
        pinned: bool = false,
    };

    pub fn findLeaf(self: *const Tree, name: []const u8) ?Tree.Leaf {
        switch (self.*) {
            .leaf => |l| return if (std.mem.eql(u8, l.name, name)) l else null,
            .split => |s| return s.first.findLeaf(name) orelse s.second.findLeaf(name),
        }
    }

    /// A `DockLayout.Snapshot` whose tabs are the leaf names. Panel-id strings are borrowed
    /// from the seed (literals); the arrays and child nodes are `allocator`-owned. Free with
    /// `Snapshot.deinit`.
    pub fn toSnapshot(self: *const Tree, allocator: std.mem.Allocator) !DockLayout.Snapshot {
        const floats = try allocator.alloc(DockLayout.Snapshot.FloatNode, 0);
        errdefer allocator.free(floats);
        const root = try snapshotNode(self, allocator);
        return .{ .root = root, .floats = floats };
    }

    /// A live animated layout ready for `dockspace`. Panel ids are owned by the result.
    pub fn toDockLayout(self: *const Tree, allocator: std.mem.Allocator) !DockLayout {
        const snap = try self.toSnapshot(allocator);
        defer snap.deinit(allocator);
        var dock = try DockLayout.fromSnapshot(allocator, snap);
        dock.animated = true;
        return dock;
    }
};

pub const Split = Tree.Split;
pub const Leaf = Tree.Leaf;

fn snapshotNode(node: *const Tree, allocator: std.mem.Allocator) !DockLayout.Snapshot.Tree {
    switch (node.*) {
        .leaf => |l| {
            const tabs = try allocator.alloc(DockLayout.PanelId, 1);
            tabs[0] = l.name;
            return .{ .leaf = .{ .tabs = tabs, .active = 0, .pinned = l.pinned } };
        },
        .split => |s| {
            const first = try allocator.create(DockLayout.Snapshot.Tree);
            first.* = try snapshotNode(s.first, allocator);
            const second = try allocator.create(DockLayout.Snapshot.Tree);
            second.* = try snapshotNode(s.second, allocator);

            return .{ .split = .{
                .dir = s.dir,
                .ratio = s.ratio,
                .fixed = s.fixed,
                .fit = s.fit,
                .first = first,
                .second = second,
            } };
        },
    }
}

/// `{origin}/{l|r|t|b}{n}` — the same mint as `SplitTree`, unique among `dock`'s panel ids.
pub fn mintName(dock: *const DockLayout, origin: []const u8, side: DockLayout.Side, buf: []u8) ?[]const u8 {
    const letter: u8 = switch (side) {
        .left => 'l',
        .right => 'r',
        .top => 't',
        .bottom => 'b',
    };
    var n: u32 = 1;
    while (n < 10_000) : (n += 1) {
        const raw = std.fmt.bufPrint(buf, "{s}/{c}{d}", .{ origin, letter, n }) catch return null;
        if (!dock.contains(raw)) return raw;
    }
    return null;
}

test "seed toDockLayout keeps a pinned single leaf" {
    const seed: Tree = .{ .leaf = .{ .name = "Center", .keywords = &.{"slot"}, .pinned = true } };
    var dock = try seed.toDockLayout(std.testing.allocator);
    defer dock.deinit();

    try std.testing.expect(dock.contains("Center"));
    try std.testing.expect(dock.nodes.items[dock.root] == .leaf);
    try std.testing.expect(dock.nodes.items[dock.root].leaf.pinned);
    try std.testing.expect(dock.animated);
}

test "seed split converts dir/ratio/fixed and both leaves" {
    const side: Tree = .{ .leaf = .{ .name = "Sidebar", .keywords = &.{"sidebar"}, .pinned = true } };
    const main: Tree = .{ .leaf = .{ .name = "Main", .keywords = &.{"main"}, .pinned = true } };
    const seed: Tree = .{ .split = .{
        .dir = .horizontal,
        .fixed = .{ .child = .first, .points = 260 },
        .first = &side,
        .second = &main,
    } };
    var dock = try seed.toDockLayout(std.testing.allocator);
    defer dock.deinit();

    try std.testing.expect(dock.nodes.items[dock.root] == .split);
    const sp = dock.nodes.items[dock.root].split;
    try std.testing.expectEqual(dvui.enums.Direction.horizontal, sp.dir);
    try std.testing.expect(sp.fixed != null);
    try std.testing.expectEqual(@as(f32, 260), sp.fixed.?.points);
    try std.testing.expect(dock.contains("Sidebar"));
    try std.testing.expect(dock.contains("Main"));
    try std.testing.expect(seed.findLeaf("Main").?.pinned);
    try std.testing.expect(seed.findLeaf("missing") == null);
}
