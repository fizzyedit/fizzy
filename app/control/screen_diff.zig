//! The screen as changes on a base: what a snapshot (`replay.Snapshot`) says, each node given a key
//! that stays the same from one frame to the next, and what changed between two of them — the
//! nodes added, removed, and changed in name, place or focus. An agent reads what its action did
//! instead of finding it in two near-identical screens; a stream sends a frame's changes instead of
//! the whole screen (plans/CONTROL_SERVER_PLAN.md).
//!
//! **Keys.** A node with a tag is its tag: tags are what widgets publish to be found by. One without
//! is the path to it from the nearest node with a tag, a `role:name` per step, numbered among its
//! like siblings (`fizzy.window:main/tab:notes.md`, `…/button:#2`). A snapshot's `parent` is an
//! index, which shifts whenever anything above changes; a key does not.
//!
//! std-only, with a unit-test root of its own (`build/app.zig`).
const std = @import("std");

/// A node as a snapshot writes it (`replay.Snapshot.Node`).
pub const Node = struct {
    role: ?[]const u8 = null,
    name: ?[]const u8 = null,
    tag: ?[]const u8 = null,
    rect: Rect,
    focused: bool = false,
    parent: ?u32 = null,
    window: ?u32 = null,

    pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };
};

/// A node with its key, and its parent and window named by theirs.
pub const Keyed = struct {
    key: []const u8,
    role: ?[]const u8 = null,
    name: ?[]const u8 = null,
    tag: ?[]const u8 = null,
    rect: Node.Rect,
    focused: bool = false,
    parent: ?[]const u8 = null,
    window: ?[]const u8 = null,
};

/// What changed in a node both screens have: only what did, the rest null.
pub const Change = struct {
    key: []const u8,
    name: ?[]const u8 = null,
    rect: ?Node.Rect = null,
    focused: ?bool = null,
    /// The node it now sits in, when that changed.
    parent: ?[]const u8 = null,
};

pub const Diff = struct {
    added: []const Keyed,
    removed: []const []const u8,
    changed: []const Change,

    pub fn empty(self: Diff) bool {
        return self.added.len == 0 and self.removed.len == 0 and self.changed.len == 0;
    }
};

/// The nodes of a snapshot's text, keyed, in `arena`.
pub fn parse(arena: std.mem.Allocator, text: []const u8) ![]const Keyed {
    const source = try arena.dupeZ(u8, text);
    const nodes = try std.zon.parse.fromSliceAlloc([]const Node, arena, source, null, .{ .ignore_unknown_fields = true });
    return key(arena, nodes);
}

/// `nodes` keyed. A node's parent comes before it (tree order), as a snapshot writes them.
pub fn key(arena: std.mem.Allocator, nodes: []const Node) ![]const Keyed {
    const out = try arena.alloc(Keyed, nodes.len);
    var seen: std.StringHashMapUnmanaged(u32) = .empty;
    for (nodes, out, 0..) |n, *k, i| {
        const parent: ?[]const u8 = if (n.parent) |p| if (p < i) out[p].key else null else null;
        const base: []const u8 = if (n.tag) |t| t else blk: {
            const step = try std.fmt.allocPrint(arena, "{s}:{s}", .{ n.role orelse "", n.name orelse "" });
            break :blk if (parent) |p| try std.fmt.allocPrint(arena, "{s}/{s}", .{ p, step }) else step;
        };
        // Like siblings (or a tag used twice) numbered from the second, in tree order.
        const gop = try seen.getOrPut(arena, base);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
        k.* = .{
            .key = if (gop.value_ptr.* == 1) base else try std.fmt.allocPrint(arena, "{s}#{d}", .{ base, gop.value_ptr.* }),
            .role = n.role,
            .name = n.name,
            .tag = n.tag,
            .rect = n.rect,
            .focused = n.focused,
            .parent = parent,
            .window = if (n.window) |w| if (w < i) out[w].key else null else null,
        };
    }
    return out;
}

/// What changed from `old` to `new`, in `new`'s tree order (removals in `old`'s).
pub fn diff(arena: std.mem.Allocator, old: []const Keyed, new: []const Keyed) !Diff {
    var before: std.StringHashMapUnmanaged(*const Keyed) = .empty;
    for (old) |*n| try before.put(arena, n.key, n);
    var after: std.StringHashMapUnmanaged(void) = .empty;
    var added: std.ArrayListUnmanaged(Keyed) = .empty;
    var changed: std.ArrayListUnmanaged(Change) = .empty;
    for (new) |n| {
        try after.put(arena, n.key, {});
        const o = before.get(n.key) orelse {
            try added.append(arena, n);
            continue;
        };
        var c: Change = .{ .key = n.key };
        var any = false;
        if (!eqlOpt(o.name, n.name)) {
            c.name = n.name orelse "";
            any = true;
        }
        if (!std.meta.eql(o.rect, n.rect)) {
            c.rect = n.rect;
            any = true;
        }
        if (o.focused != n.focused) {
            c.focused = n.focused;
            any = true;
        }
        if (!eqlOpt(o.parent, n.parent)) {
            c.parent = n.parent orelse "";
            any = true;
        }
        if (any) try changed.append(arena, c);
    }
    var removed: std.ArrayListUnmanaged([]const u8) = .empty;
    for (old) |n| if (!after.contains(n.key)) try removed.append(arena, n.key);
    return .{ .added = added.items, .removed = removed.items, .changed = changed.items };
}

fn eqlOpt(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

const test_old =
    \\.{
    \\    .{.role="window",.name="fizzy",.tag="fizzy.window:main",.rect=.{.x=0,.y=0,.w=100,.h=100}},
    \\    .{.role="tab",.name="a.md",.rect=.{.x=0,.y=0,.w=10,.h=5},.parent=0},
    \\    .{.role="tab",.name="b.md",.rect=.{.x=10,.y=0,.w=10,.h=5},.parent=0},
    \\    .{.role="button",.rect=.{.x=0,.y=90,.w=5,.h=5},.parent=0},
    \\    .{.role="button",.rect=.{.x=5,.y=90,.w=5,.h=5},.parent=0},
    \\    .{.tag="text.editor",.rect=.{.x=0,.y=5,.w=100,.h=80},.focused=true},
    \\}
;

test "keys stay put when what is above them changes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = try parse(a, test_old);
    try std.testing.expectEqualStrings("fizzy.window:main", nodes[0].key);
    try std.testing.expectEqualStrings("fizzy.window:main/tab:a.md", nodes[1].key);
    try std.testing.expectEqualStrings("fizzy.window:main", nodes[1].parent.?);
    // Like siblings numbered from the second.
    try std.testing.expectEqualStrings("fizzy.window:main/button:", nodes[3].key);
    try std.testing.expectEqualStrings("fizzy.window:main/button:#2", nodes[4].key);
    try std.testing.expectEqualStrings("text.editor", nodes[5].key);
    // A node added before them shifts every index, and no key.
    const shifted = try parse(a,
        \\.{
        \\    .{.role="window",.name="fizzy",.tag="fizzy.window:main",.rect=.{.x=0,.y=0,.w=100,.h=100}},
        \\    .{.role="dialog",.name="Save?",.rect=.{.x=20,.y=20,.w=50,.h=30}},
        \\    .{.role="tab",.name="a.md",.rect=.{.x=0,.y=0,.w=10,.h=5},.parent=0},
        \\}
    );
    try std.testing.expectEqualStrings("fizzy.window:main/tab:a.md", shifted[2].key);
}

test "a diff says what was added, removed and changed, and nothing else" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = try parse(a, test_old);
    // b.md closed, a.md moved over, a dialog opened, focus left the editor.
    const new = try parse(a,
        \\.{
        \\    .{.role="window",.name="fizzy",.tag="fizzy.window:main",.rect=.{.x=0,.y=0,.w=100,.h=100}},
        \\    .{.role="tab",.name="a.md",.rect=.{.x=2,.y=0,.w=10,.h=5},.parent=0},
        \\    .{.role="button",.rect=.{.x=0,.y=90,.w=5,.h=5},.parent=0},
        \\    .{.role="button",.rect=.{.x=5,.y=90,.w=5,.h=5},.parent=0},
        \\    .{.tag="text.editor",.rect=.{.x=0,.y=5,.w=100,.h=80}},
        \\    .{.role="dialog",.name="Save?",.rect=.{.x=20,.y=20,.w=50,.h=30}},
        \\}
    );
    const d = try diff(a, old, new);
    try std.testing.expectEqual(@as(usize, 1), d.added.len);
    try std.testing.expectEqualStrings("dialog:Save?", d.added[0].key);
    try std.testing.expectEqual(@as(usize, 1), d.removed.len);
    try std.testing.expectEqualStrings("fizzy.window:main/tab:b.md", d.removed[0]);
    try std.testing.expectEqual(@as(usize, 2), d.changed.len);
    try std.testing.expectEqualStrings("fizzy.window:main/tab:a.md", d.changed[0].key);
    try std.testing.expectEqual(@as(i32, 2), d.changed[0].rect.?.x);
    try std.testing.expect(d.changed[0].name == null and d.changed[0].focused == null);
    try std.testing.expectEqualStrings("text.editor", d.changed[1].key);
    try std.testing.expectEqual(false, d.changed[1].focused.?);
    // The same screen twice: nothing.
    try std.testing.expect((try diff(a, new, new)).empty());
}
