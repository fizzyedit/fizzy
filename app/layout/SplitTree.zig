//! A runtime split tree: any place can be divided along an edge, and the side
//! that was not dragged keeps the original name and keywords.
//!
//! The shape still writes one `region`. If that name has been split, `Region.init`
//! walks this tree and draws the leaves. New leaves are empty `slot`s until the
//! picker fills them. Closing an empty leaf collapses the branch.
const std = @import("std");
const dvui = @import("dvui");

pub const Side = enum { left, right, top, bottom };

pub fn axisOf(side: Side) dvui.enums.Direction {
    return switch (side) {
        .left, .right => .horizontal,
        .top, .bottom => .vertical,
    };
}

pub fn newIsLeading(side: Side) bool {
    return side == .left or side == .top;
}

pub fn opposite(side: Side) Side {
    return switch (side) {
        .left => .right,
        .right => .left,
        .top => .bottom,
        .bottom => .top,
    };
}

pub fn parseSide(s: []const u8) ?Side {
    inline for (std.meta.tags(Side)) |tag| {
        if (std.mem.eql(u8, s, @tagName(tag))) return tag;
    }
    return null;
}

pub const Node = struct {
    kind: union(enum) {
        leaf: []const u8,
        branch: Branch,
    },
};

pub const Branch = struct {
    dir: dvui.enums.Direction,
    side: Side,
    /// The leaf that was split — keeps keywords and assignment.
    origin: []const u8,
    /// The leaf minted on this split. Kept even after that side is split again,
    /// so a nested tree still writes every link to disk.
    created: []const u8,
    a: *Node,
    b: *Node,
};

pub fn newNameOf(branch: Branch) []const u8 {
    return branch.created;
}

pub fn leafName(node: Node) ?[]const u8 {
    return switch (node.kind) {
        .leaf => |n| n,
        .branch => null,
    };
}

pub const Forest = struct {
    roots: std.StringHashMapUnmanaged(*Node) = .empty,

    pub fn deinit(self: *Forest, gpa: std.mem.Allocator) void {
        var it = self.roots.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            freeNode(gpa, e.value_ptr.*);
        }
        self.roots.deinit(gpa);
        self.roots = .empty;
    }

    pub fn root(self: *const Forest, name: []const u8) ?*Node {
        return self.roots.get(name);
    }

    /// Divide `origin` from `side`. `want` is the new leaf's extent. `existing`
    /// is a saved name on load; null mints `{origin}/{l|r|t|b}{n}`.
    pub fn split(
        self: *Forest,
        gpa: std.mem.Allocator,
        intern: *const fn (gpa: std.mem.Allocator, name: []const u8) []const u8,
        origin: []const u8,
        side: Side,
        want: f32,
        existing: ?[]const u8,
    ) ?[]const u8 {
        _ = want;
        if (self.findLeaf(origin) == null and self.root(origin) != null) return null;

        const new_name = existing orelse self.mintName(gpa, intern, origin, side) orelse return null;
        const new_leaf = gpa.create(Node) catch return null;
        new_leaf.* = .{ .kind = .{ .leaf = intern(gpa, new_name) } };

        const kept = gpa.create(Node) catch {
            gpa.destroy(new_leaf);
            return null;
        };
        kept.* = .{ .kind = .{ .leaf = intern(gpa, origin) } };

        const branch_node = gpa.create(Node) catch {
            gpa.destroy(new_leaf);
            gpa.destroy(kept);
            return null;
        };
        const leading = newIsLeading(side);
        const created = new_leaf.kind.leaf;
        branch_node.* = .{ .kind = .{ .branch = .{
            .dir = axisOf(side),
            .side = side,
            .origin = intern(gpa, origin),
            .created = created,
            .a = if (leading) new_leaf else kept,
            .b = if (leading) kept else new_leaf,
        } } };

        if (self.replaceLeaf(gpa, origin, branch_node)) {
            return new_leaf.kind.leaf;
        }

        const key = gpa.dupe(u8, origin) catch {
            freeNode(gpa, branch_node);
            return null;
        };
        self.roots.put(gpa, key, branch_node) catch {
            gpa.free(key);
            freeNode(gpa, branch_node);
            return null;
        };
        return new_leaf.kind.leaf;
    }

    /// Remove an empty new leaf. The sibling takes the branch's place.
    pub fn collapse(self: *Forest, gpa: std.mem.Allocator, name: []const u8) bool {
        var it = self.roots.iterator();
        while (it.next()) |e| {
            if (!tryCollapse(gpa, e.value_ptr, name)) continue;
            if (leafName(e.value_ptr.*.*)) |n| {
                if (std.mem.eql(u8, n, e.key_ptr.*)) {
                    const key = e.key_ptr.*;
                    const node = e.value_ptr.*;
                    _ = self.roots.fetchRemove(key);
                    gpa.free(key);
                    freeNode(gpa, node);
                }
            }
            return true;
        }
        return false;
    }

    pub const SavedLink = struct {
        name: []const u8,
        parent: []const u8,
        side: Side,
    };

    pub fn collectLinks(self: *const Forest, gpa: std.mem.Allocator) []const SavedLink {
        var out: std.ArrayListUnmanaged(SavedLink) = .empty;
        var it = self.roots.valueIterator();
        while (it.next()) |n| collectFrom(n.*, gpa, &out);
        return out.toOwnedSlice(gpa) catch {
            out.deinit(gpa);
            return &.{};
        };
    }

    fn collectFrom(node: *const Node, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(SavedLink)) void {
        switch (node.kind) {
            .leaf => {},
            .branch => |b| {
                out.append(gpa, .{ .name = b.created, .parent = b.origin, .side = b.side }) catch {};
                collectFrom(b.a, gpa, out);
                collectFrom(b.b, gpa, out);
            },
        }
    }

    fn mintName(
        self: *Forest,
        gpa: std.mem.Allocator,
        intern: *const fn (gpa: std.mem.Allocator, name: []const u8) []const u8,
        origin: []const u8,
        side: Side,
    ) ?[]const u8 {
        const letter: u8 = switch (side) {
            .left => 'l',
            .right => 'r',
            .top => 't',
            .bottom => 'b',
        };
        var n: u32 = 1;
        var buf: [128]u8 = undefined;
        while (n < 10_000) : (n += 1) {
            const raw = std.fmt.bufPrint(&buf, "{s}/{c}{d}", .{ origin, letter, n }) catch return null;
            if (self.findLeaf(raw) == null) return intern(gpa, raw);
        }
        return null;
    }

    /// A leaf minted by a split, not a shape-declared root. The picker can Remove these.
    pub fn canForget(self: *const Forest, name: []const u8) bool {
        return self.root(name) == null and self.findLeaf(name) != null;
    }

    fn findLeaf(self: *const Forest, name: []const u8) ?*Node {
        var it = self.roots.valueIterator();
        while (it.next()) |n| {
            if (findIn(n.*, name)) |hit| return hit;
        }
        return null;
    }

    fn findIn(node: *Node, name: []const u8) ?*Node {
        return switch (node.kind) {
            .leaf => |n| if (std.mem.eql(u8, n, name)) node else null,
            .branch => |b| findIn(b.a, name) orelse findIn(b.b, name),
        };
    }

    fn replaceLeaf(self: *Forest, gpa: std.mem.Allocator, name: []const u8, with: *Node) bool {
        var it = self.roots.valueIterator();
        while (it.next()) |n| {
            if (replaceIn(gpa, n.*, name, with)) return true;
        }
        return false;
    }

    fn replaceIn(gpa: std.mem.Allocator, node: *Node, name: []const u8, with: *Node) bool {
        switch (node.kind) {
            .leaf => return false,
            .branch => |*b| {
                if (leafName(b.a.*) != null and std.mem.eql(u8, leafName(b.a.*).?, name)) {
                    gpa.destroy(b.a);
                    b.a = with;
                    return true;
                }
                if (leafName(b.b.*) != null and std.mem.eql(u8, leafName(b.b.*).?, name)) {
                    gpa.destroy(b.b);
                    b.b = with;
                    return true;
                }
                return replaceIn(gpa, b.a, name, with) or replaceIn(gpa, b.b, name, with);
            },
        }
    }
};

fn isLeafNamed(node: *Node, name: []const u8) bool {
    return if (leafName(node.*)) |n| std.mem.eql(u8, n, name) else false;
}

fn tryCollapse(gpa: std.mem.Allocator, slot: **Node, name: []const u8) bool {
    const node = slot.*;
    switch (node.kind) {
        .leaf => return false,
        .branch => |*b| {
            if (isLeafNamed(b.a, name)) {
                slot.* = b.b;
                gpa.destroy(b.a);
                gpa.destroy(node);
                return true;
            }
            if (isLeafNamed(b.b, name)) {
                slot.* = b.a;
                gpa.destroy(b.b);
                gpa.destroy(node);
                return true;
            }
            return tryCollapse(gpa, &b.a, name) or tryCollapse(gpa, &b.b, name);
        },
    }
}

fn freeNode(gpa: std.mem.Allocator, node: *Node) void {
    switch (node.kind) {
        .leaf => {},
        .branch => |b| {
            freeNode(gpa, b.a);
            freeNode(gpa, b.b);
        },
    }
    gpa.destroy(node);
}

fn internLiteral(_: std.mem.Allocator, name: []const u8) []const u8 {
    return name;
}

test "opposite flips each edge" {
    try std.testing.expectEqual(Side.right, opposite(.left));
    try std.testing.expectEqual(Side.left, opposite(.right));
    try std.testing.expectEqual(Side.bottom, opposite(.top));
    try std.testing.expectEqual(Side.top, opposite(.bottom));
}

test "a right split keeps the origin on the left" {
    const gpa = std.testing.allocator;
    var f: Forest = .{};
    defer f.deinit(gpa);
    const new = f.split(gpa, internLiteral, "Center", .right, 80, "Center/r1").?;
    try std.testing.expectEqualStrings("Center/r1", new);
    const r = f.root("Center").?;
    const b = r.kind.branch;
    try std.testing.expectEqual(dvui.enums.Direction.horizontal, b.dir);
    try std.testing.expectEqualStrings("Center", leafName(b.a.*).?);
    try std.testing.expectEqualStrings("Center/r1", leafName(b.b.*).?);
}

test "a left split keeps the origin on the right" {
    const gpa = std.testing.allocator;
    var f: Forest = .{};
    defer f.deinit(gpa);
    _ = f.split(gpa, internLiteral, "Center", .left, 80, "Center/l1").?;
    const b = f.root("Center").?.kind.branch;
    try std.testing.expectEqualStrings("Center/l1", leafName(b.a.*).?);
    try std.testing.expectEqualStrings("Center", leafName(b.b.*).?);
}

test "collapsing the new leaf restores a single place" {
    const gpa = std.testing.allocator;
    var f: Forest = .{};
    defer f.deinit(gpa);
    _ = f.split(gpa, internLiteral, "Center", .right, 80, "Center/r1").?;
    try std.testing.expect(f.collapse(gpa, "Center/r1"));
    try std.testing.expect(f.root("Center") == null);
}

test "a nested split stays under the same root" {
    const gpa = std.testing.allocator;
    var f: Forest = .{};
    defer f.deinit(gpa);
    _ = f.split(gpa, internLiteral, "Center", .right, 80, "Center/r1").?;
    _ = f.split(gpa, internLiteral, "Center/r1", .top, 40, "Center/r1/t1").?;
    const b = f.root("Center").?.kind.branch;
    try std.testing.expectEqualStrings("Center", leafName(b.a.*).?);
    const inner = b.b.kind.branch;
    try std.testing.expectEqualStrings("Center/r1/t1", leafName(inner.a.*).?);
    try std.testing.expectEqualStrings("Center/r1", leafName(inner.b.*).?);
}

test "canForget is only a minted leaf" {
    const gpa = std.testing.allocator;
    var f: Forest = .{};
    defer f.deinit(gpa);
    try std.testing.expect(!f.canForget("Center"));
    _ = f.split(gpa, internLiteral, "Center", .right, 80, "Center/r1").?;
    try std.testing.expect(!f.canForget("Center"));
    try std.testing.expect(f.canForget("Center/r1"));
}

test "collectLinks keeps a nested parent link" {
    const gpa = std.testing.allocator;
    var f: Forest = .{};
    defer f.deinit(gpa);
    _ = f.split(gpa, internLiteral, "Center", .right, 80, "Center/r1").?;
    _ = f.split(gpa, internLiteral, "Center/r1", .top, 40, "Center/r1/t1").?;
    const links = f.collectLinks(gpa);
    defer gpa.free(links);
    try std.testing.expectEqual(@as(usize, 2), links.len);
    try std.testing.expectEqualStrings("Center/r1", links[0].name);
    try std.testing.expectEqualStrings("Center", links[0].parent);
    try std.testing.expectEqual(Side.right, links[0].side);
    try std.testing.expectEqualStrings("Center/r1/t1", links[1].name);
    try std.testing.expectEqualStrings("Center/r1", links[1].parent);
    try std.testing.expectEqual(Side.top, links[1].side);
}
