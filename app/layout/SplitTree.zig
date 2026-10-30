//! A runtime split tree: any place can be divided along an edge, and the side
//! that was not dragged keeps the original name and keywords.
//!
//! The shape still writes one `region`. If that name has been split, `Region.init`
//! walks this tree and draws the leaves. New leaves are empty `slot`s until the
//! picker fills them. Closing an empty leaf collapses the branch.
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");

/// The docking widget's side: a pane tree and a place tree name an edge the same way.
pub const Side = core.widgets.DockLayout.Side;

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
    /// The leaf that was split - keeps keywords and assignment.
    origin: []const u8,
    /// The leaf minted on this split. Kept even after that side is split again,
    /// so a nested tree still writes every link to disk.
    created: []const u8,
    /// Fizzy made this split, not the person: it runs the way its space's shape asks and turns
    /// with it (`turn`). `dir` and `side` are how it runs now.
    adaptive: bool = false,
    /// An adaptive split's new half as a share of its box along the axis, 0 to 1. Saved because
    /// the half's pixel extent is along the axis it was last chosen on, which a box of another
    /// shape (a restart in portrait) no longer has. Null until the person has sized it.
    share: ?f32 = null,
    /// Transient: what a turn left in the frame's data for this split is to go on its next draw
    /// (`Region.settleTurn`). Set when it stops being adaptive, and when it is rebuilt under the
    /// name of one that was. Never saved.
    settle: bool = false,
    a: *Node,
    b: *Node,
};

/// Turn an adaptive `branch` a quarter: right becomes bottom, left top, and the other way. The
/// new half stays the trailing (or leading) one, and `created` keeps the name its letter gave.
pub fn turn(branch: *Branch) void {
    branch.side = switch (branch.side) {
        .right => .bottom,
        .bottom => .right,
        .left => .top,
        .top => .left,
    };
    branch.dir = axisOf(branch.side);
}

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
    /// Nodes `collapse` and `forget` took out of the tree during a frame. The draw walk holds
    /// pointers into the tree it is drawing, and a place dropped mid-walk (a bubble dropped on
    /// the trash, an emptied place closing) must not free them under it: they are freed by `reap`
    /// once the frame's walk is done.
    buried: std.ArrayList(Buried) = .empty,

    const Buried = struct { node: *Node, deep: bool };

    /// Free the nodes buried since the last call. Call when no walk of the tree is under way: a
    /// frame loop that collapses places must call it once per frame after its shape's walk, or the
    /// nodes wait (bounded, nothing freed early) until `deinit`.
    pub fn reap(self: *Forest, gpa: std.mem.Allocator) void {
        for (self.buried.items) |b| if (b.deep) freeNode(gpa, b.node) else gpa.destroy(b.node);
        self.buried.clearRetainingCapacity();
    }

    /// `node` and what hangs under it, out of the tree but still readable until `reap`.
    /// `deep` frees the children too; a branch whose children live on is buried shallow.
    fn bury(self: *Forest, gpa: std.mem.Allocator, node: *Node, deep: bool) void {
        // Out of memory: leak the node rather than free it. A walk may still hold it, and a
        // leaked node costs bytes where a freed one is a use after free.
        self.buried.append(gpa, .{ .node = node, .deep = deep }) catch {};
    }

    pub fn deinit(self: *Forest, gpa: std.mem.Allocator) void {
        self.reap(gpa);
        self.buried.deinit(gpa);
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

    /// Remove the place `name` from the split it is a half of. The sibling takes the branch's place.
    ///
    /// A place split again is the whole branch its split made, not the leaf that kept its name
    /// inside it: that is how the split it is a half of sees it, and how it is sized there. Taking
    /// only the leaf would hand the place's slot to its other half, sized along the wrong axis and
    /// under a name no link records.
    pub fn collapse(self: *Forest, gpa: std.mem.Allocator, name: []const u8) bool {
        var it = self.roots.iterator();
        while (it.next()) |e| {
            if (!tryCollapse(self, gpa, e.value_ptr, name)) continue;
            if (leafName(e.value_ptr.*.*)) |n| {
                if (std.mem.eql(u8, n, e.key_ptr.*)) {
                    const key = e.key_ptr.*;
                    const node = e.value_ptr.*;
                    _ = self.roots.fetchRemove(key);
                    gpa.free(key);
                    self.bury(gpa, node, true);
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
        adaptive: bool = false,
        share: ?f32 = null,
    };

    /// The split that minted `created` is fizzy's own (`Branch.adaptive`). False when no split did.
    pub fn markAdaptive(self: *Forest, created: []const u8) bool {
        var it = self.roots.valueIterator();
        while (it.next()) |n| if (markIn(n.*, created)) return true;
        return false;
    }

    /// The split `name` is one half of, as a single place; null when it is no split's half.
    pub fn halfOf(self: *const Forest, name: []const u8) ?*Branch {
        var it = self.roots.valueIterator();
        while (it.next()) |n| if (halfIn(n.*, name)) |b| return b;
        return null;
    }

    fn halfIn(node: *Node, name: []const u8) ?*Branch {
        switch (node.kind) {
            .leaf => return null,
            .branch => |*b| {
                for ([_]*Node{ b.a, b.b }) |half| {
                    if (leafName(half.*)) |n| if (std.mem.eql(u8, n, name)) return b;
                }
                return halfIn(b.a, name) orelse halfIn(b.b, name);
            },
        }
    }

    /// Record the share of the adaptive split that minted `created`. True when it changed.
    pub fn setShare(self: *Forest, created: []const u8, share: f32) bool {
        var it = self.roots.valueIterator();
        while (it.next()) |n| if (shareIn(n.*, created, share)) |changed| return changed;
        return false;
    }

    fn shareIn(node: *Node, created: []const u8, share: f32) ?bool {
        switch (node.kind) {
            .leaf => return null,
            .branch => |*b| {
                if (std.mem.eql(u8, b.created, created)) {
                    if (b.share == share) return false;
                    b.share = share;
                    return true;
                }
                return shareIn(b.a, created, share) orelse shareIn(b.b, created, share);
            },
        }
    }

    fn markIn(node: *Node, created: []const u8) bool {
        switch (node.kind) {
            .leaf => return false,
            .branch => |*b| {
                if (std.mem.eql(u8, b.created, created)) {
                    b.adaptive = true;
                    return true;
                }
                return markIn(b.a, created) or markIn(b.b, created);
            },
        }
    }

    pub fn collectLinks(self: *const Forest, gpa: std.mem.Allocator) []const SavedLink {
        var out: std.ArrayList(SavedLink) = .empty;
        var it = self.roots.valueIterator();
        while (it.next()) |n| collectFrom(n.*, gpa, &out);
        return out.toOwnedSlice(gpa) catch {
            out.deinit(gpa);
            return &.{};
        };
    }

    fn collectFrom(node: *const Node, gpa: std.mem.Allocator, out: *std.ArrayList(SavedLink)) void {
        switch (node.kind) {
            .leaf => {},
            .branch => |b| {
                out.append(gpa, .{ .name = b.created, .parent = b.origin, .side = b.side, .adaptive = b.adaptive, .share = b.share }) catch {};
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
            const raw = std.mem.print(&buf, "{s}/{c}{d}", .{ origin, letter, n }) catch return null;
            if (self.findLeaf(raw) == null) return intern(gpa, raw);
        }
        return null;
    }

    /// Two places one split made - the two leaves of one branch - as the place a join keeps and
    /// the one it closes. Null for any other pair: only a split's own two halves are one place
    /// again when joined, so that is the only pair the middle of a place joins.
    ///
    /// The origin is kept, whichever way the join was dragged: it holds the shape's name (or its
    /// parent split's), and closing the minted leaf is the one thing the tree can undo.
    pub const Pair = struct { keep: []const u8, drop: []const u8 };

    pub fn joinable(self: *const Forest, a: []const u8, b: []const u8) ?Pair {
        if (std.mem.eql(u8, a, b)) return null;
        var it = self.roots.valueIterator();
        while (it.next()) |n| {
            if (pairIn(n.*, a, b)) |p| return p;
        }
        return null;
    }

    fn pairIn(node: *Node, a: []const u8, b: []const u8) ?Pair {
        switch (node.kind) {
            .leaf => return null,
            .branch => |br| {
                const la = leafName(br.a.*);
                const lb = leafName(br.b.*);
                if (la != null and lb != null) {
                    const x = la.?;
                    const y = lb.?;
                    const hit = (std.mem.eql(u8, x, a) and std.mem.eql(u8, y, b)) or
                        (std.mem.eql(u8, x, b) and std.mem.eql(u8, y, a));
                    if (hit) {
                        const keep = if (std.mem.eql(u8, x, br.created)) y else x;
                        return .{ .keep = keep, .drop = if (keep.ptr == x.ptr) y else x };
                    }
                }
                return pairIn(br.a, a, b) orelse pairIn(br.b, a, b);
            },
        }
    }

    /// The other half of the split `name` is one half of, when that half is a single place;
    /// null when `name` is no split's half or its other half is split again.
    pub fn siblingLeaf(self: *const Forest, name: []const u8) ?[]const u8 {
        var it = self.roots.valueIterator();
        while (it.next()) |n| {
            if (siblingIn(n.*, name)) |hit| return hit;
        }
        return null;
    }

    fn siblingIn(node: *Node, name: []const u8) ?[]const u8 {
        switch (node.kind) {
            .leaf => return null,
            .branch => |br| {
                if (leafName(br.a.*)) |a| if (std.mem.eql(u8, a, name)) return leafName(br.b.*);
                if (leafName(br.b.*)) |b| if (std.mem.eql(u8, b, name)) return leafName(br.a.*);
                return siblingIn(br.a, name) orelse siblingIn(br.b, name);
            },
        }
    }

    /// The place whose split `name` is a part of - the root its tree is keyed by - or `name`
    /// itself when it was never split or is a root. Null when the forest has never heard of it.
    pub fn rootOf(self: *const Forest, name: []const u8) ?[]const u8 {
        var it = self.roots.iterator();
        while (it.next()) |e| {
            if (std.mem.eql(u8, e.key_ptr.*, name) or findIn(e.value_ptr.*, name) != null) return e.key_ptr.*;
        }
        return null;
    }

    /// Every single place `root` is divided into, in drawing order; `root` alone when it was never
    /// split. Allocated in `arena`.
    pub fn leavesUnder(self: *const Forest, arena: std.mem.Allocator, root_name: []const u8) []const []const u8 {
        const node = self.root(root_name) orelse {
            const one = arena.alloc([]const u8, 1) catch return &.{};
            one[0] = root_name;
            return one;
        };
        var out: std.ArrayList([]const u8) = .empty;
        leavesIn(node, arena, &out);
        return out.items;
    }

    fn leavesIn(node: *const Node, arena: std.mem.Allocator, out: *std.ArrayList([]const u8)) void {
        switch (node.kind) {
            .leaf => |n| out.append(arena, n) catch {},
            .branch => |b| {
                leavesIn(b.a, arena, out);
                leavesIn(b.b, arena, out);
            },
        }
    }

    /// Drop `root`'s whole tree: the place is gone, and every split of it with it - a float
    /// closing. Nothing to do for a place never split.
    pub fn forget(self: *Forest, gpa: std.mem.Allocator, root_name: []const u8) void {
        const kv = self.roots.fetchRemove(root_name) orelse return;
        gpa.free(kv.key);
        self.bury(gpa, kv.value, true);
    }

    /// Whether `name` was split again: the origin of a split, so the place under that name is
    /// that split's whole branch, its kept leaf one half of it.
    pub fn isSplit(self: *const Forest, name: []const u8) bool {
        if (self.root(name) != null) return true;
        const node = self.findPlace(name) orelse return false;
        return node.kind == .branch;
    }

    /// Every single place `collapse(name)` would take, in drawing order: `name` alone for a leaf
    /// or a name the forest does not know, each leaf of its branch for a place split again. A
    /// root's is its own kept half, as `collapse` sees it, not the whole tree it is keyed by.
    /// Allocated in `arena`.
    pub fn placeLeaves(self: *const Forest, arena: std.mem.Allocator, name: []const u8) []const []const u8 {
        const node = self.findPlace(name) orelse {
            const one = arena.alloc([]const u8, 1) catch return &.{};
            one[0] = name;
            return one;
        };
        var out: std.ArrayList([]const u8) = .empty;
        leavesIn(node, arena, &out);
        return out.items;
    }

    /// The node the place `name` is in its parent's split: the outermost that carries the name.
    fn findPlace(self: *const Forest, name: []const u8) ?*Node {
        var it = self.roots.valueIterator();
        while (it.next()) |n| {
            if (placeIn(n.*, name)) |hit| return hit;
        }
        return null;
    }

    fn placeIn(node: *Node, name: []const u8) ?*Node {
        switch (node.kind) {
            .leaf => return null,
            .branch => |b| {
                if (isPlaceNamed(b.a, name)) return b.a;
                if (isPlaceNamed(b.b, name)) return b.b;
                return placeIn(b.a, name) orelse placeIn(b.b, name);
            },
        }
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

/// Whether `node` is the place `name` in its parent's split: its leaf, or the branch a split of
/// it made.
fn isPlaceNamed(node: *Node, name: []const u8) bool {
    return switch (node.kind) {
        .leaf => |n| std.mem.eql(u8, n, name),
        .branch => |b| std.mem.eql(u8, b.origin, name),
    };
}

fn tryCollapse(forest: *Forest, gpa: std.mem.Allocator, slot: **Node, name: []const u8) bool {
    const node = slot.*;
    switch (node.kind) {
        .leaf => return false,
        .branch => |*b| {
            // Children before descending: the outermost node carrying the name is the place.
            // Dropped nodes are buried, not freed: a walk drawing this tree may still hold them.
            if (isPlaceNamed(b.a, name)) {
                slot.* = b.b;
                forest.bury(gpa, b.a, true);
                forest.bury(gpa, node, false);
                return true;
            }
            if (isPlaceNamed(b.b, name)) {
                slot.* = b.a;
                forest.bury(gpa, b.b, true);
                forest.bury(gpa, node, false);
                return true;
            }
            return tryCollapse(forest, gpa, &b.a, name) or tryCollapse(forest, gpa, &b.b, name);
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

test "a place collapsed mid-walk leaves the tree being walked readable until reap" {
    const gpa = std.testing.allocator;
    var f: Forest = .{};
    defer f.deinit(gpa);
    _ = f.split(gpa, internLiteral, "Main", .left, 80, "Main/l1").?;
    const root = f.root("Main").?;
    const branch = root.kind.branch;
    // The walk holds `branch` and its children; dropping the minted half closes the whole tree
    // down to the origin leaf, and the root itself goes with it.
    try std.testing.expect(f.collapse(gpa, "Main/l1"));
    try std.testing.expect(f.root("Main") == null);
    // Still readable: freed here, the debug allocator's poison would make these reads fail.
    try std.testing.expectEqualStrings("Main", branch.origin);
    try std.testing.expectEqualStrings("Main", leafName(branch.b.*).?);
    f.reap(gpa);
    try std.testing.expectEqual(@as(usize, 0), f.buried.items.len);
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

test "only a split's own two halves join, and the origin is what stays" {
    const gpa = std.testing.allocator;
    var f: Forest = .{};
    defer f.deinit(gpa);
    _ = f.split(gpa, internLiteral, "Center", .right, 80, "Center/r1").?;
    const p = f.joinable("Center/r1", "Center").?;
    try std.testing.expectEqualStrings("Center", p.keep);
    try std.testing.expectEqualStrings("Center/r1", p.drop);
    try std.testing.expectEqualStrings("Center", f.joinable("Center", "Center/r1").?.keep);
    try std.testing.expect(f.joinable("Center", "Center") == null);

    // Split again: the new pair is the inner branch; the outer halves are no longer a pair.
    _ = f.split(gpa, internLiteral, "Center/r1", .top, 40, "Center/r1/t1").?;
    try std.testing.expect(f.joinable("Center", "Center/r1") == null);
    const inner = f.joinable("Center/r1/t1", "Center/r1").?;
    try std.testing.expectEqualStrings("Center/r1", inner.keep);
    try std.testing.expectEqualStrings("Center/r1/t1", inner.drop);
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

test "a split's places know their root, list as its leaves, and go with it" {
    const gpa = std.testing.allocator;
    var f: Forest = .{};
    defer f.deinit(gpa);
    try std.testing.expect(f.rootOf("Float 1") == null);
    _ = f.split(gpa, internLiteral, "Float 1", .right, 80, "Float 1/r1").?;
    _ = f.split(gpa, internLiteral, "Float 1/r1", .top, 40, "Float 1/r1/t1").?;
    try std.testing.expectEqualStrings("Float 1", f.rootOf("Float 1/r1/t1").?);
    try std.testing.expectEqualStrings("Float 1", f.rootOf("Float 1").?);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const leaves = f.leavesUnder(arena.allocator(), "Float 1");
    try std.testing.expectEqual(@as(usize, 3), leaves.len);
    try std.testing.expectEqualStrings("Float 1", leaves[0]);
    try std.testing.expectEqualStrings("Float 1/r1/t1", leaves[1]);
    try std.testing.expectEqualStrings("Float 1/r1", leaves[2]);
    try std.testing.expectEqual(@as(usize, 1), f.leavesUnder(arena.allocator(), "Main").len);

    f.forget(gpa, "Float 1");
    try std.testing.expect(f.root("Float 1") == null);
    try std.testing.expect(f.rootOf("Float 1/r1") == null);
}

test "collapsing a place split again drops its whole branch, never just the leaf that kept the name" {
    const gpa = std.testing.allocator;
    var f: Forest = .{};
    defer f.deinit(gpa);
    _ = f.split(gpa, internLiteral, "Center", .right, 80, "Center/r1").?;
    _ = f.split(gpa, internLiteral, "Center/r1", .bottom, 40, "Center/r1/b1").?;
    try std.testing.expect(f.isSplit("Center/r1"));
    try std.testing.expect(!f.isSplit("Center/r1/b1"));

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const covered = f.placeLeaves(arena.allocator(), "Center/r1");
    try std.testing.expectEqual(@as(usize, 2), covered.len);
    try std.testing.expectEqualStrings("Center/r1", covered[0]);
    try std.testing.expectEqualStrings("Center/r1/b1", covered[1]);
    try std.testing.expectEqual(@as(usize, 1), f.placeLeaves(arena.allocator(), "Center/r1/b1").len);

    try std.testing.expect(f.collapse(gpa, "Center/r1"));
    try std.testing.expect(f.root("Center") == null);
    try std.testing.expect(f.rootOf("Center/r1/b1") == null);
}

test "collapsing the minted half of a nested split leaves its origin in the outer split" {
    const gpa = std.testing.allocator;
    var f: Forest = .{};
    defer f.deinit(gpa);
    _ = f.split(gpa, internLiteral, "Center", .right, 80, "Center/r1").?;
    _ = f.split(gpa, internLiteral, "Center/r1", .bottom, 40, "Center/r1/b1").?;
    try std.testing.expect(f.collapse(gpa, "Center/r1/b1"));
    try std.testing.expectEqualStrings("Center", f.siblingLeaf("Center/r1").?);
    const links = f.collectLinks(gpa);
    defer gpa.free(links);
    try std.testing.expectEqual(@as(usize, 1), links.len);
    try std.testing.expectEqualStrings("Center/r1", links[0].name);
}

test "an adaptive split turns a quarter, keeps its half and its name, and is saved so" {
    const gpa = std.testing.allocator;
    var f: Forest = .{};
    defer f.deinit(gpa);
    _ = f.split(gpa, internLiteral, "Main", .right, 80, "Main/r1").?;
    try std.testing.expect(!f.markAdaptive("Nowhere/r1"));
    try std.testing.expect(f.markAdaptive("Main/r1"));

    const links = f.collectLinks(gpa);
    defer gpa.free(links);
    for (links) |l| try std.testing.expectEqual(std.mem.eql(u8, l.name, "Main/r1"), l.adaptive);

    const b = &f.root("Main").?.kind.branch;
    try std.testing.expectEqual(dvui.enums.Direction.horizontal, b.dir);
    turn(b);
    try std.testing.expectEqual(Side.bottom, b.side);
    try std.testing.expectEqual(dvui.enums.Direction.vertical, b.dir);
    try std.testing.expectEqualStrings("Main/r1", b.created);
    turn(b);
    try std.testing.expectEqual(Side.right, b.side);
}

test "a place's own split is found from either half, and is saved as the toggle leaves it" {
    const gpa = std.testing.allocator;
    var f: Forest = .{};
    defer f.deinit(gpa);
    _ = f.split(gpa, internLiteral, "Main", .right, 80, "Main/r1").?;
    _ = f.split(gpa, internLiteral, "Main/r1", .bottom, 40, "Main/r1/b1").?;
    try std.testing.expect(f.halfOf("Nowhere") == null);

    const outer = f.halfOf("Main").?;
    try std.testing.expectEqualStrings("Main/r1", outer.created);
    // The half split again is a half of its own split, not of the one that made it.
    try std.testing.expectEqualStrings("Main/r1/b1", f.halfOf("Main/r1").?.created);
    try std.testing.expectEqual(f.halfOf("Main/r1"), f.halfOf("Main/r1/b1"));

    outer.adaptive = true;
    turn(outer);
    outer.adaptive = false;
    const links = f.collectLinks(gpa);
    defer gpa.free(links);
    for (links) |l| {
        try std.testing.expect(!l.adaptive);
        if (std.mem.eql(u8, l.name, "Main/r1")) try std.testing.expectEqual(Side.bottom, l.side);
    }
}
