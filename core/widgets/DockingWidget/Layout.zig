//! Pure-data layout tree for the docking widget: a binary tree of splits with
//! tabbed leaves at the fringes, plus a list of floating leaves. No GUI
//! dependencies beyond `dvui.enums.Direction` and `dvui.Rect` (plain data
//! types), so this can be unit tested without a Window.
const std = @import("std");
const dvui = @import("dvui");

/// Accordion-row arithmetic used by a sash drag. The widget gathers a `Row`
/// from the live tree and drawn ratios, calls there, then writes ratios back.
pub const Row = @import("Row.zig");

/// App-owned slug identifying a dockable panel. `DockLayout` never dupes or
/// frees these: the caller must keep the underlying bytes alive for the
/// lifetime of the layout (typically a static string).
pub const PanelId = []const u8;

pub const NodeIndex = u32;

pub const Side = enum { left, right, top, bottom };

pub const Node = union(enum) {
    split: Split,
    leaf: Leaf,
    /// Free-list entry: node slots are stable and never compacted, so
    /// removed nodes are recycled via this singly linked free list.
    free: ?NodeIndex,

    pub const Split = struct {
        dir: dvui.enums.Direction,
        /// The first child's share of the split. The persisted, settled value: what a drag
        /// writes on release and what the widget eases its drawn ratio toward (see
        /// `DockingWidget`'s `animated` handling). `fixed` overrides it while set.
        ratio: f32 = 0.5,
        /// One child sized in points instead of by share — a sidebar that stays 260 wide when
        /// the window grows. The widget derives `ratio` from it each frame and writes a drag
        /// back to it, so a snapshot round-trips it unchanged.
        fixed: ?Fixed = null,
        /// One child sized to its *content* — a layer list that grows with its rows, a palette
        /// that takes the rest. Each frame the widget reads that child's content minimum along
        /// the axis, turns it into a share clamped to `[min, max]`, writes it to `ratio` and
        /// eases the drawn split there. A drag on a fitted split moves `max` (so the user can
        /// cap it, and the fit stays under the cap); `setRatio` does the same. Snapshot keeps it.
        fit: ?Fit = null,
        first: NodeIndex,
        second: NodeIndex,
        /// This split's identity for the life of the layout — see `Leaf.key`.
        key: u32 = 0,
        /// Transient: the child that has just been created by a split and should slide open
        /// from nothing. Set by `splitLeaf`/`splitRoot` when `animated`; the widget consumes
        /// it on the first frame it draws the split. Never serialized.
        opening: ?Child = null,
        /// Transient: the child that is on its way out. The widget eases the split shut over
        /// it and then applies `.collapse`, which promotes the other child. Set by
        /// `closeLeaf`, and by an emptied leaf when `animated`. Never serialized.
        closing: ?Child = null,

        pub const Fixed = struct { child: Child, points: f32 };
        pub const Fit = struct { child: Child, min: f32 = 0, max: f32 = 1 };
    };

    pub const Child = enum { first, second };

    pub const Leaf = struct {
        tabs: std.ArrayList(PanelId) = .empty,
        active: usize = 0,
        /// A leaf the layout itself declared — an app's "Main", not a pane a drag minted. What
        /// is pinned is the *place*, not the node: emptied, it stays as an empty leaf the app
        /// can fill again, and if it is closed while it has a sibling, the sibling's first
        /// leaf becomes pinned in its stead and takes its panel id (see `collapseSplit`,
        /// `takeRenamed`). Both halves of a split "Main" are removable; the last one standing
        /// is "Main". It is only refused a collapse when nothing would be left to inherit.
        pinned: bool = false,
        /// This leaf's identity for the life of the layout. A node *index* is a slot: a collapse
        /// promotes the kept child into its parent's slot, and anything keyed by index would
        /// see that as a different widget and rebuild from scratch. The key travels with the
        /// node instead. Never serialized; assigned fresh by `nextKey` wherever a node is made.
        key: u32 = 0,
    };
};

pub const Float = struct {
    leaf: NodeIndex,
    rect: dvui.Rect,
};

pub const MoveTarget = union(enum) {
    tab: struct { leaf: NodeIndex, index: usize },
    split: struct { leaf: NodeIndex, side: Side },
    /// Splits the whole tree (root-edge drop zones), regardless of whether
    /// `root` currently holds a leaf or a split.
    split_root: Side,
};

pub const Renamed = struct { from: []const u8, to: PanelId };

pub const Mutation = union(enum) {
    move: struct { panel: PanelId, target: MoveTarget },
    remove: PanelId,
    set_active: struct { leaf: NodeIndex, index: usize },
    float: struct { panel: PanelId, rect: dvui.Rect },
    /// Finish a `closing` split: the child not closing takes the split's slot. Queued by the
    /// widget once the close animation has run out.
    collapse: NodeIndex,
    /// A drag settled a split's share (or its fixed extent). Queued by the widget on release so
    /// the layout, not the widget's per-frame copy, is what persists.
    set_ratio: struct { split: NodeIndex, ratio: f32, extent: f32 },
};

/// Where a point falls on a leaf, in the leaf's own terms: the middle (add as a tab) or one of
/// the four edge bands (split that side). Pure, so both the preview and the drop read the same
/// answer, and so it can be tested without a Window.
pub const Zone = union(enum) {
    tab,
    split: Side,
};

pub const ZoneHit = struct { zone: Zone, rect: dvui.Rect.Physical };

/// The zone at `p` inside leaf rect `r`: a centre inset 30% each side, clamped to `max_edge`
/// (physical px) thick, and the four edge strips filling the rest. Null when `p` is outside `r`.
pub fn zoneAt(r: dvui.Rect.Physical, p: dvui.Point.Physical, max_edge: f32) ?ZoneHit {
    if (!r.contains(p)) return null;
    const inset_x = @min(r.w * 0.3, max_edge);
    const inset_y = @min(r.h * 0.3, max_edge);

    const center: dvui.Rect.Physical = .{ .x = r.x + inset_x, .y = r.y + inset_y, .w = @max(0, r.w - 2 * inset_x), .h = @max(0, r.h - 2 * inset_y) };
    if (center.contains(p)) return .{ .zone = .tab, .rect = center };

    const left: dvui.Rect.Physical = .{ .x = r.x, .y = r.y, .w = inset_x, .h = r.h };
    if (left.contains(p)) return .{ .zone = .{ .split = .left }, .rect = left };
    const right: dvui.Rect.Physical = .{ .x = r.x + r.w - inset_x, .y = r.y, .w = inset_x, .h = r.h };
    if (right.contains(p)) return .{ .zone = .{ .split = .right }, .rect = right };
    const top: dvui.Rect.Physical = .{ .x = r.x, .y = r.y, .w = r.w, .h = inset_y };
    if (top.contains(p)) return .{ .zone = .{ .split = .top }, .rect = top };
    const bottom: dvui.Rect.Physical = .{ .x = r.x, .y = r.y + r.h - inset_y, .w = r.w, .h = inset_y };
    if (bottom.contains(p)) return .{ .zone = .{ .split = .bottom }, .rect = bottom };
    return null;
}

pub const EdgeHit = struct { side: Side, rect: dvui.Rect.Physical };

/// The edge strip of `r` (each `thick` physical px) under `p`, or null — the root-edge zones
/// that split the whole tree.
pub fn edgeAt(r: dvui.Rect.Physical, p: dvui.Point.Physical, thick: f32) ?EdgeHit {
    if (!r.contains(p)) return null;
    const left: dvui.Rect.Physical = .{ .x = r.x, .y = r.y, .w = thick, .h = r.h };
    if (left.contains(p)) return .{ .side = .left, .rect = left };
    const right: dvui.Rect.Physical = .{ .x = r.x + r.w - thick, .y = r.y, .w = thick, .h = r.h };
    if (right.contains(p)) return .{ .side = .right, .rect = right };
    const top: dvui.Rect.Physical = .{ .x = r.x, .y = r.y, .w = r.w, .h = thick };
    if (top.contains(p)) return .{ .side = .top, .rect = top };
    const bottom: dvui.Rect.Physical = .{ .x = r.x, .y = r.y + r.h - thick, .w = r.w, .h = thick };
    if (bottom.contains(p)) return .{ .side = .bottom, .rect = bottom };
    return null;
}

pub const DockLayout = @This();

allocator: std.mem.Allocator,
nodes: std.ArrayList(Node) = .empty,
free_head: ?NodeIndex = null,
root: NodeIndex = 0,
floats: std.ArrayList(Float) = .empty,
/// When set, this layout owns its tab slug strings: `deinit`/`removePanel`
/// free them with `allocator`. `fromSnapshot` sets it (a loaded layout has no
/// other stable source for the slugs). Don't set it yourself unless every
/// `PanelId` you hand this layout is `allocator`-owned.
owns_panel_ids: bool = false,
/// A pin that moved in the last collapse: the heir leaf used to be `from` and is now `to`.
/// `from` is a layout-owned copy; `takeRenamed` hands it over and the caller frees it with
/// `allocator`. `to` is borrowed from the live tree.
renamed: ?Renamed = null,
/// Splits and closes animate: a new leaf slides open from nothing and an emptied leaf slides
/// shut before it is collapsed, instead of both happening in one frame. Off by default so a
/// layout behaves exactly as it always has for callers that never asked; the widget reads
/// `Split.opening`/`Split.closing` only when this is set.
animated: bool = false,
/// Source of `Leaf.key` / `Split.key`.
next_key: u32 = 1,

/// A fresh node identity.
pub fn nextKey(self: *DockLayout) u32 {
    defer self.next_key += 1;
    return self.next_key;
}

/// The identity of `node` — its leaf's or split's `key`.
pub fn keyOf(self: *const DockLayout, node: NodeIndex) u32 {
    return switch (self.nodes.items[node]) {
        .leaf => |l| l.key,
        .split => |sp| sp.key,
        .free => 0,
    };
}

pub fn init(allocator: std.mem.Allocator) DockLayout {
    return .{ .allocator = allocator };
}

/// An empty root leaf, for a layout built up from nothing — `initSingleLeaf` without the panel.
/// Returns the root's index. Only meaningful on a layout that has no nodes yet.
pub fn allocNodeForRoot(self: *DockLayout) !NodeIndex {
    std.debug.assert(self.nodes.items.len == 0);
    const idx = try self.allocNode();
    self.nodes.items[idx] = .{ .leaf = .{ .key = self.nextKey() } };
    self.root = idx;
    return idx;
}

/// Convenience constructor: a single leaf holding one panel as root.
pub fn initSingleLeaf(allocator: std.mem.Allocator, panel: PanelId) !DockLayout {
    var self = init(allocator);
    const idx = try self.allocNode();
    self.nodes.items[idx] = .{ .leaf = .{ .key = self.nextKey() } };
    try self.nodes.items[idx].leaf.tabs.append(allocator, panel);
    self.root = idx;
    return self;
}

pub fn deinit(self: *DockLayout) void {
    if (self.renamed) |r| self.allocator.free(r.from);
    for (self.nodes.items) |*n| {
        switch (n.*) {
            .leaf => |*l| self.freeLeafTabs(l),
            .split, .free => {},
        }
    }
    self.nodes.deinit(self.allocator);
    self.floats.deinit(self.allocator);
    self.* = undefined;
}

/// Frees the tab slug strings too when `owns_panel_ids`, then the tab list
/// container itself either way.
fn freeLeafTabs(self: *DockLayout, l: *Node.Leaf) void {
    if (self.owns_panel_ids) {
        for (l.tabs.items) |t| self.allocator.free(t);
    }
    l.tabs.deinit(self.allocator);
}

fn allocNode(self: *DockLayout) !NodeIndex {
    if (self.free_head) |idx| {
        self.free_head = self.nodes.items[idx].free;
        return idx;
    }
    const idx: NodeIndex = @intCast(self.nodes.items.len);
    try self.nodes.append(self.allocator, .{ .free = null });
    return idx;
}

fn freeNode(self: *DockLayout, idx: NodeIndex) void {
    switch (self.nodes.items[idx]) {
        .leaf => |*l| self.freeLeafTabs(l),
        .split, .free => {},
    }
    self.nodes.items[idx] = .{ .free = self.free_head };
    self.free_head = idx;
}

/// Finds the leaf node containing `panel` as one of its tabs (main tree or floats).
pub fn findPanel(self: *const DockLayout, panel: PanelId) ?NodeIndex {
    for (self.nodes.items, 0..) |n, i| {
        switch (n) {
            .leaf => |l| for (l.tabs.items) |t| {
                if (std.mem.eql(u8, t, panel)) return @intCast(i);
            },
            .split, .free => {},
        }
    }
    return null;
}

pub fn contains(self: *const DockLayout, panel: PanelId) bool {
    return self.findPanel(panel) != null;
}

pub fn isFloat(self: *const DockLayout, leaf_idx: NodeIndex) bool {
    for (self.floats.items) |f| {
        if (f.leaf == leaf_idx) return true;
    }
    return false;
}

/// Returns the first leaf reached by always descending into `first`, starting at `start`.
pub fn firstLeaf(self: *const DockLayout, start: NodeIndex) NodeIndex {
    var idx = start;
    while (true) {
        switch (self.nodes.items[idx]) {
            .split => |s| idx = s.first,
            .leaf => return idx,
            .free => unreachable,
        }
    }
}

/// Returns the last leaf reached by always descending into `second`, starting at `start`.
pub fn lastLeaf(self: *const DockLayout, start: NodeIndex) NodeIndex {
    var idx = start;
    while (true) {
        switch (self.nodes.items[idx]) {
            .split => |s| idx = s.second,
            .leaf => return idx,
            .free => unreachable,
        }
    }
}

/// Appends the active panel of every leaf (main tree, depth-first, then floats) to `list`.
pub fn collectActivePanels(self: *const DockLayout, list: *std.ArrayList(PanelId), allocator: std.mem.Allocator) !void {
    try self.collectActiveFrom(self.root, list, allocator);
    for (self.floats.items) |f| try self.collectActiveFrom(f.leaf, list, allocator);
}

fn collectActiveFrom(self: *const DockLayout, idx: NodeIndex, list: *std.ArrayList(PanelId), allocator: std.mem.Allocator) !void {
    switch (self.nodes.items[idx]) {
        .split => |s| {
            try self.collectActiveFrom(s.first, list, allocator);
            try self.collectActiveFrom(s.second, list, allocator);
        },
        .leaf => |l| if (l.tabs.items.len > 0) try list.append(allocator, l.tabs.items[l.active]),
        .free => unreachable,
    }
}

pub const Parent = struct { idx: NodeIndex, side: enum { first, second } };

/// Linear search from root for the split node whose first/second == `target`.
/// Floats have no parent (returns null for a float leaf).
pub fn findParent(self: *const DockLayout, target: NodeIndex) ?Parent {
    return self.findParentFrom(self.root, target);
}

fn findParentFrom(self: *const DockLayout, idx: NodeIndex, target: NodeIndex) ?Parent {
    switch (self.nodes.items[idx]) {
        .split => |s| {
            if (s.first == target) return .{ .idx = idx, .side = .first };
            if (s.second == target) return .{ .idx = idx, .side = .second };
            if (self.findParentFrom(s.first, target)) |p| return p;
            return self.findParentFrom(s.second, target);
        },
        .leaf, .free => return null,
    }
}

/// Splits `leaf_idx` into a new split node (same index, so external
/// references stay valid) with the existing content moved to one side and a
/// fresh single-tab leaf holding `panel` on the other side.
pub fn splitLeaf(self: *DockLayout, leaf_idx: NodeIndex, side: Side, panel: PanelId) !void {
    const old_leaf = self.nodes.items[leaf_idx].leaf;

    const moved_idx = try self.allocNode();
    self.nodes.items[moved_idx] = .{ .leaf = old_leaf };

    const new_idx = try self.allocNode();
    var new_tabs: std.ArrayList(PanelId) = .empty;
    try new_tabs.append(self.allocator, panel);
    self.nodes.items[new_idx] = .{ .leaf = .{ .tabs = new_tabs, .active = 0, .key = self.nextKey() } };

    const dir: dvui.enums.Direction = switch (side) {
        .left, .right => .horizontal,
        .top, .bottom => .vertical,
    };
    const first, const second = switch (side) {
        .left, .top => .{ new_idx, moved_idx },
        .right, .bottom => .{ moved_idx, new_idx },
    };

    self.nodes.items[leaf_idx] = .{ .split = .{
        .dir = dir,
        .ratio = 0.5,
        .first = first,
        .second = second,
        .key = self.nextKey(),
        .opening = if (self.animated) newChild(side) else null,
    } };
}

/// Which child a split on `side` mints: left/top go first.
pub fn newChild(side: Side) Node.Child {
    return switch (side) {
        .left, .top => .first,
        .right, .bottom => .second,
    };
}

pub fn otherChild(c: Node.Child) Node.Child {
    return switch (c) {
        .first => .second,
        .second => .first,
    };
}

pub fn childIndex(sp: Node.Split, c: Node.Child) NodeIndex {
    return switch (c) {
        .first => sp.first,
        .second => sp.second,
    };
}

/// Wraps the whole tree in a new split (root-edge drop zones): `root`'s
/// current content (leaf or split) moves to one side, unchanged, and a fresh
/// single-tab leaf holding `panel` goes on the other side. `root` itself
/// keeps its index (now holding the new split), same trick as `splitLeaf`.
pub fn splitRoot(self: *DockLayout, side: Side, panel: PanelId) !void {
    const old_root = self.nodes.items[self.root];

    const moved_idx = try self.allocNode();
    self.nodes.items[moved_idx] = old_root;

    const new_idx = try self.allocNode();
    var new_tabs: std.ArrayList(PanelId) = .empty;
    try new_tabs.append(self.allocator, panel);
    self.nodes.items[new_idx] = .{ .leaf = .{ .tabs = new_tabs, .active = 0, .key = self.nextKey() } };

    const dir: dvui.enums.Direction = switch (side) {
        .left, .right => .horizontal,
        .top, .bottom => .vertical,
    };
    const first, const second = switch (side) {
        .left, .top => .{ new_idx, moved_idx },
        .right, .bottom => .{ moved_idx, new_idx },
    };

    self.nodes.items[self.root] = .{ .split = .{
        .dir = dir,
        .ratio = 0.5,
        .first = first,
        .second = second,
        .key = self.nextKey(),
        .opening = if (self.animated) newChild(side) else null,
    } };
}

/// Send `leaf_idx` on its way out: its parent split eases shut over it and the widget then
/// applies `.collapse`. A root leaf and a float have nothing to close into and are left alone.
/// A pinned leaf closes like any other; its sibling inherits the pin (`collapseSplit`).
/// Immediate (no animation) when the layout is not `animated`.
pub fn closeLeaf(self: *DockLayout, leaf_idx: NodeIndex) void {
    if (leaf_idx == self.root) return;
    const parent = self.findParent(leaf_idx) orelse return;
    const side: Node.Child = switch (parent.side) {
        .first => .first,
        .second => .second,
    };
    if (!self.animated) {
        self.collapseSplit(parent.idx, otherChild(side));
        return;
    }
    self.nodes.items[parent.idx].split.closing = side;
}

/// Keep `leaf_idx` after all: a parent split closing over it stops closing. The widget then eases
/// it back open to its settled ratio. The counterpart of `closeLeaf`.
pub fn reopenLeaf(self: *DockLayout, leaf_idx: NodeIndex) void {
    const parent = self.findParent(leaf_idx) orelse return;
    const sp = &self.nodes.items[parent.idx].split;
    const mine: Node.Child = if (parent.side == .first) .first else .second;
    if (sp.closing == mine) sp.closing = null;
}

/// Replace split `split_idx` with its `keep` child, freeing the other subtree. The split's
/// index survives (now holding the kept child's node), so a reference to the split from above
/// stays valid — the same trick `splitLeaf` uses in the other direction.
///
/// Dropping a pinned leaf hands its pin to the kept side's first leaf, which also takes the
/// pinned leaf's first panel id (the place's name) — the kept leaf's own id is parked in
/// `renamed` for the caller to reconcile whatever it keys by that name. One-panel-per-leaf
/// layouts are what this is for; a tabbed leaf is renamed by its first tab.
pub fn collapseSplit(self: *DockLayout, split_idx: NodeIndex, keep: Node.Child) void {
    const sp = switch (self.nodes.items[split_idx]) {
        .split => |sp| sp,
        else => return,
    };
    const kept = childIndex(sp, keep);
    const dropped = childIndex(sp, otherChild(keep));
    if (self.findPinnedLeaf(dropped)) |pinned_idx| {
        const heir = self.firstLeaf(kept);
        const from = &self.nodes.items[pinned_idx].leaf;
        const to = &self.nodes.items[heir].leaf;
        to.pinned = true;
        if (from.tabs.items.len > 0 and to.tabs.items.len > 0) {
            // Swap the two ids so the dropped subtree frees the heir's old id along with
            // everything else it owns — unless the caller wants it, which is what `renamed`
            // is: a copy that outlives the collapse.
            const old = to.tabs.items[0];
            to.tabs.items[0] = from.tabs.items[0];
            from.tabs.items[0] = old;
            self.setRenamed(old, to.tabs.items[0]);
        }
    }

    self.nodes.items[split_idx] = self.nodes.items[kept];
    self.nodes.items[kept] = .{ .free = null };
    self.freeNode(kept);
    self.freeSubtree(dropped);
}

fn findPinnedLeaf(self: *const DockLayout, idx: NodeIndex) ?NodeIndex {
    return switch (self.nodes.items[idx]) {
        .leaf => |l| if (l.pinned) idx else null,
        .split => |sp| self.findPinnedLeaf(sp.first) orelse self.findPinnedLeaf(sp.second),
        .free => null,
    };
}

fn setRenamed(self: *DockLayout, from: []const u8, to: PanelId) void {
    if (self.renamed) |r| self.allocator.free(r.from);
    self.renamed = .{ .from = self.allocator.dupe(u8, from) catch return, .to = to };
}

/// The rename the last collapse made, if any; the caller owns `from` afterwards.
pub fn takeRenamed(self: *DockLayout) ?Renamed {
    defer self.renamed = null;
    return self.renamed;
}

fn freeSubtree(self: *DockLayout, idx: NodeIndex) void {
    switch (self.nodes.items[idx]) {
        .split => |sp| {
            self.freeSubtree(sp.first);
            self.freeSubtree(sp.second);
        },
        .leaf, .free => {},
    }
    self.freeNode(idx);
}

/// Least room `node` needs along `dir` when every same-axis sash is `gap` thick:
/// those sashes summed; across a cross-axis split, the wider child. The widget's
/// own walk substitutes a closing sash's shrinking thickness for `gap`.
pub fn floorAlong(self: *const DockLayout, node: NodeIndex, dir: dvui.enums.Direction, gap: f32) f32 {
    return switch (self.nodes.items[node]) {
        .leaf, .free => 0,
        .split => |sp| if (sp.dir == dir)
            self.floorAlong(sp.first, dir, gap) + gap + self.floorAlong(sp.second, dir, gap)
        else
            @max(self.floorAlong(sp.first, dir, gap), self.floorAlong(sp.second, dir, gap)),
    };
}

/// The split's settled share, honouring `fixed` against `extent` (the split's length along its
/// axis, less the handle). What the widget draws toward.
pub fn targetRatio(sp: Node.Split, extent: f32) f32 {
    const f = sp.fixed orelse return sp.ratio;
    if (extent <= 0) return sp.ratio;
    const share = std.math.clamp(f.points / extent, 0, 1);
    return switch (f.child) {
        .first => share,
        .second => 1 - share,
    };
}

/// Record a dragged share on the split — into `fixed.points` when the split is fixed, so the
/// points are what persist, else into `ratio`.
pub fn setRatio(self: *DockLayout, split_idx: NodeIndex, ratio: f32, extent: f32) void {
    const sp = switch (self.nodes.items[split_idx]) {
        .split => |*sp| sp,
        else => return,
    };
    if (sp.fixed) |*f| {
        if (extent > 0) f.points = switch (f.child) {
            .first => ratio * extent,
            .second => (1 - ratio) * extent,
        };
        return;
    }
    if (sp.fit) |*f| {
        // The drag becomes the cap the fit may not exceed (the child's own share of it).
        f.max = std.math.clamp(switch (f.child) {
            .first => ratio,
            .second => 1 - ratio,
        }, f.min, 1);
    }
    sp.ratio = ratio;
}

/// Inserts `panel` as a new tab in `leaf_idx` at `tab_idx` (clamped) and activates it.
pub fn insertTab(self: *DockLayout, leaf_idx: NodeIndex, tab_idx: usize, panel: PanelId) !void {
    const leaf = &self.nodes.items[leaf_idx].leaf;
    const idx = @min(tab_idx, leaf.tabs.items.len);
    try leaf.tabs.insert(self.allocator, idx, panel);
    leaf.active = idx;
    // Filled again while on its way out: it stays.
    if (self.findParent(leaf_idx)) |parent| {
        const sp = &self.nodes.items[parent.idx].split;
        if (sp.closing) |c| {
            const mine: Node.Child = if (parent.side == .first) .first else .second;
            if (c == mine) sp.closing = null;
        }
    }
}

/// Like `insertTab`, but duplicates `panel` when `owns_panel_ids` is set, so a
/// borrowed/static id (e.g. from an app's panel registry) can be safely added
/// to a layout that owns its ids — `deinit`/`removePanel` would otherwise try
/// to free a string they don't own.
pub fn insertTabOwned(self: *DockLayout, leaf_idx: NodeIndex, tab_idx: usize, panel: PanelId) !void {
    const id = if (self.owns_panel_ids) try self.allocator.dupe(u8, panel) else panel;
    errdefer if (self.owns_panel_ids) self.allocator.free(id);
    try self.insertTab(leaf_idx, tab_idx, id);
}

/// Reorders `panel` (already in `leaf_idx`) to `new_index` within the same leaf.
fn reorderTab(self: *DockLayout, leaf_idx: NodeIndex, panel: PanelId, new_index: usize) void {
    const leaf = &self.nodes.items[leaf_idx].leaf;
    const cur = for (leaf.tabs.items, 0..) |t, i| {
        if (std.mem.eql(u8, t, panel)) break i;
    } else return;
    const item = leaf.tabs.orderedRemove(cur);
    const idx = @min(new_index, leaf.tabs.items.len);
    leaf.tabs.insert(self.allocator, idx, item) catch return;
    leaf.active = idx;
}

/// Removes `panel` from `leaf_idx`, fixing up `active` (removing the active tab
/// activates the previous index, not 0) and collapsing the tree/floats if the
/// leaf empties. Returns the removed `PanelId` — the same string, still alive,
/// just no longer in the tree — or null if it wasn't there. Callers relocating
/// the panel should ignore it; only `removePanel` frees it (and only when
/// `owns_panel_ids`).
fn removeFromLeaf(self: *DockLayout, leaf_idx: NodeIndex, panel: PanelId) ?PanelId {
    const leaf = &self.nodes.items[leaf_idx].leaf;
    const removed_idx = for (leaf.tabs.items, 0..) |t, i| {
        if (std.mem.eql(u8, t, panel)) break i;
    } else return null;
    const removed = leaf.tabs.orderedRemove(removed_idx);

    if (leaf.tabs.items.len == 0) {
        leaf.active = 0;
    } else {
        if (removed_idx <= leaf.active and leaf.active > 0) leaf.active -= 1;
        leaf.active = @min(leaf.active, leaf.tabs.items.len - 1);
    }

    if (leaf.tabs.items.len > 0) return removed;

    // Empty leaf: collapse it out of whichever structure holds it.
    for (self.floats.items, 0..) |f, i| {
        if (f.leaf == leaf_idx) {
            _ = self.floats.swapRemove(i);
            self.freeNode(leaf_idx);
            return removed;
        }
    }

    if (leaf_idx == self.root) return removed; // tolerate an empty root leaf
    if (leaf.pinned) return removed; // a declared place stays, empty

    // Slide shut first when animated; the widget collapses it once closed.
    // Otherwise promote the sibling into the parent's slot right now.
    self.closeLeaf(leaf_idx);
    return removed;
}

/// Removes `panel` from wherever it currently is (no-op if not present).
pub fn removePanel(self: *DockLayout, panel: PanelId) void {
    const leaf_idx = self.findPanel(panel) orelse return;
    const removed = self.removeFromLeaf(leaf_idx, panel);
    if (self.owns_panel_ids) {
        if (removed) |r| self.allocator.free(r);
    }
}

pub fn setActive(self: *DockLayout, leaf_idx: NodeIndex, index: usize) void {
    const leaf = &self.nodes.items[leaf_idx].leaf;
    if (index < leaf.tabs.items.len) leaf.active = index;
}

/// Moves `panel` (wherever it currently is) to `target`. No-op if `target`
/// re-specifies the panel's only current location.
pub fn movePanel(self: *DockLayout, panel: PanelId, target: MoveTarget) !void {
    const source_leaf = self.findPanel(panel) orelse return;

    switch (target) {
        .tab => |t| {
            if (t.leaf == source_leaf) {
                self.reorderTab(source_leaf, panel, t.index);
                return;
            }
            try self.insertTab(t.leaf, t.index, panel);
            _ = self.removeFromLeaf(source_leaf, panel);
        },
        .split => |s| {
            if (s.leaf == source_leaf) {
                const tabs_len = self.nodes.items[source_leaf].leaf.tabs.items.len;
                if (tabs_len <= 1) return; // only tab in this leaf: nothing to split against
                _ = self.removeFromLeaf(source_leaf, panel);
                try self.splitLeaf(source_leaf, s.side, panel);
                return;
            }
            try self.splitLeaf(s.leaf, s.side, panel);
            _ = self.removeFromLeaf(source_leaf, panel);
        },
        .split_root => |side| {
            if (source_leaf == self.root) {
                const tabs_len = self.nodes.items[source_leaf].leaf.tabs.items.len;
                if (tabs_len <= 1) return; // only tab in the whole tree: nothing to split against
                _ = self.removeFromLeaf(source_leaf, panel);
                try self.splitRoot(side, panel);
                return;
            }
            try self.splitRoot(side, panel);
            _ = self.removeFromLeaf(source_leaf, panel);
        },
    }
}

/// Detaches `panel` into a new floating leaf at `rect`.
pub fn floatPanel(self: *DockLayout, panel: PanelId, rect: dvui.Rect) !void {
    const source_leaf = self.findPanel(panel);

    const idx = try self.allocNode();
    var tabs: std.ArrayList(PanelId) = .empty;
    try tabs.append(self.allocator, panel);
    self.nodes.items[idx] = .{ .leaf = .{ .tabs = tabs, .active = 0, .key = self.nextKey() } };
    try self.floats.append(self.allocator, .{ .leaf = idx, .rect = rect });

    if (source_leaf) |sl| _ = self.removeFromLeaf(sl, panel);
}

pub fn apply(self: *DockLayout, m: Mutation) !void {
    switch (m) {
        .move => |mv| try self.movePanel(mv.panel, mv.target),
        .remove => |p| self.removePanel(p),
        .set_active => |sa| self.setActive(sa.leaf, sa.index),
        .float => |f| try self.floatPanel(f.panel, f.rect),
        .collapse => |idx| {
            const sp = switch (self.nodes.items[idx]) {
                .split => |sp| sp,
                else => return,
            };
            const going = sp.closing orelse return;
            self.collapseSplit(idx, otherChild(going));
        },
        .set_ratio => |sr| self.setRatio(sr.split, sr.ratio, sr.extent),
    }
}

/// Serialization-facing description of a whole layout: a recursive tree of
/// splits and tabbed leaves plus the floating leaves. Holds only plain values
/// (enums, floats, slices, tagged unions), so callers can (de)serialize it in
/// whatever format they like — the widget never picks one. `snapshot` builds
/// one from a live layout; `fromSnapshot` rebuilds a layout from one.
pub const Snapshot = struct {
    root: Tree,
    floats: []const FloatNode = &.{},

    pub const Tree = union(enum) {
        split: Split,
        leaf: Leaf,

        pub const Split = struct {
            dir: dvui.enums.Direction,
            ratio: f32 = 0.5,
            fixed: ?Node.Split.Fixed = null,
            fit: ?Node.Split.Fit = null,
            first: *const Tree,
            second: *const Tree,
        };

        pub const Leaf = struct {
            tabs: []const PanelId,
            active: usize = 0,
            pinned: bool = false,
        };
    };

    pub const FloatNode = struct {
        rect: dvui.Rect,
        leaf: Tree.Leaf,
    };

    /// Frees what `snapshot` allocated. Only valid on a `Snapshot` that
    /// `snapshot` returned, not one deserialized or built by other means.
    pub fn deinit(self: Snapshot, allocator: std.mem.Allocator) void {
        freeTree(self.root, allocator);
        for (self.floats) |f| allocator.free(f.leaf.tabs);
        allocator.free(self.floats);
    }

    fn freeTree(node: Tree, allocator: std.mem.Allocator) void {
        switch (node) {
            .split => |s| {
                freeTree(s.first.*, allocator);
                freeTree(s.second.*, allocator);
                allocator.destroy(s.first);
                allocator.destroy(s.second);
            },
            .leaf => |l| allocator.free(l.tabs),
        }
    }
};

/// Builds a `Snapshot` of the current layout. Tree nodes and tab arrays are
/// allocated with `allocator`; the panel-id strings are borrowed from the live
/// layout (valid until it next changes). Free with `Snapshot.deinit`.
pub fn snapshot(self: *const DockLayout, allocator: std.mem.Allocator) !Snapshot {
    const root = try self.snapshotNode(self.root, allocator);
    errdefer Snapshot.freeTree(root, allocator);

    var floats: std.ArrayList(Snapshot.FloatNode) = .empty;
    errdefer {
        for (floats.items) |f| allocator.free(f.leaf.tabs);
        floats.deinit(allocator);
    }
    for (self.floats.items) |f| {
        const leaf = try snapshotLeaf(self.nodes.items[f.leaf].leaf, allocator);
        errdefer allocator.free(leaf.tabs);
        try floats.append(allocator, .{ .rect = f.rect, .leaf = leaf });
    }

    return .{ .root = root, .floats = try floats.toOwnedSlice(allocator) };
}

fn snapshotNode(self: *const DockLayout, idx: NodeIndex, allocator: std.mem.Allocator) !Snapshot.Tree {
    switch (self.nodes.items[idx]) {
        .split => |sp| {
            const first = try allocator.create(Snapshot.Tree);
            errdefer allocator.destroy(first);
            first.* = try self.snapshotNode(sp.first, allocator);
            errdefer Snapshot.freeTree(first.*, allocator);

            const second = try allocator.create(Snapshot.Tree);
            errdefer allocator.destroy(second);
            second.* = try self.snapshotNode(sp.second, allocator);

            return .{ .split = .{ .dir = sp.dir, .ratio = sp.ratio, .fixed = sp.fixed, .fit = sp.fit, .first = first, .second = second } };
        },
        .leaf => |l| return .{ .leaf = try snapshotLeaf(l, allocator) },
        .free => unreachable,
    }
}

fn snapshotLeaf(l: Node.Leaf, allocator: std.mem.Allocator) !Snapshot.Tree.Leaf {
    return .{ .tabs = try allocator.dupe(PanelId, l.tabs.items), .active = l.active, .pinned = l.pinned };
}

/// Rebuilds a live layout from `snap` (typically freshly deserialized). Panel
/// ids are duplicated with `allocator` and owned by the result
/// (`owns_panel_ids`), so `snap` and its backing bytes may be freed right
/// after. Any well-formed `Snapshot` yields a valid layout.
pub fn fromSnapshot(allocator: std.mem.Allocator, snap: Snapshot) !DockLayout {
    var self = DockLayout.init(allocator);
    self.owns_panel_ids = true;
    errdefer self.deinit();

    self.root = try self.buildNode(snap.root);
    for (snap.floats) |f| {
        const idx = try self.allocNode();
        self.nodes.items[idx] = .{ .leaf = try self.buildLeaf(f.leaf) };
        try self.floats.append(allocator, .{ .leaf = idx, .rect = f.rect });
    }
    return self;
}

fn buildNode(self: *DockLayout, node: Snapshot.Tree) !NodeIndex {
    switch (node) {
        .split => |sp| {
            const first = try self.buildNode(sp.first.*);
            const second = try self.buildNode(sp.second.*);
            const idx = try self.allocNode();
            self.nodes.items[idx] = .{ .split = .{ .dir = sp.dir, .ratio = sp.ratio, .fixed = sp.fixed, .fit = sp.fit, .first = first, .second = second, .key = self.nextKey() } };
            return idx;
        },
        .leaf => |l| {
            const idx = try self.allocNode();
            self.nodes.items[idx] = .{ .leaf = try self.buildLeaf(l) };
            return idx;
        },
    }
}

fn buildLeaf(self: *DockLayout, l: Snapshot.Tree.Leaf) !Node.Leaf {
    var tabs: std.ArrayList(PanelId) = .empty;
    errdefer {
        for (tabs.items) |t| self.allocator.free(t);
        tabs.deinit(self.allocator);
    }
    for (l.tabs) |t| {
        const dup = try self.allocator.dupe(u8, t);
        tabs.append(self.allocator, dup) catch |e| {
            self.allocator.free(dup);
            return e;
        };
    }
    const active: usize = if (tabs.items.len == 0) 0 else @min(l.active, tabs.items.len - 1);
    return .{ .tabs = tabs, .active = active, .pinned = l.pinned, .key = self.nextKey() };
}

test "single leaf init and find" {
    var layout = try DockLayout.initSingleLeaf(std.testing.allocator, "hierarchy");
    defer layout.deinit();

    try std.testing.expect(layout.contains("hierarchy"));
    try std.testing.expect(!layout.contains("inspector"));
}

test "splitLeaf keeps parent index stable and creates two leaves" {
    var layout = try DockLayout.initSingleLeaf(std.testing.allocator, "hierarchy");
    defer layout.deinit();

    const root = layout.root;
    try layout.splitLeaf(root, .right, "inspector");

    try std.testing.expect(layout.root == root); // root index unchanged
    try std.testing.expectEqual(Node.split, std.meta.activeTag(layout.nodes.items[root]));
    const split = layout.nodes.items[root].split;
    try std.testing.expectEqual(dvui.enums.Direction.horizontal, split.dir);
    try std.testing.expect(layout.contains("hierarchy"));
    try std.testing.expect(layout.contains("inspector"));

    const hier_leaf = layout.findPanel("hierarchy").?;
    const insp_leaf = layout.findPanel("inspector").?;
    try std.testing.expect(hier_leaf != insp_leaf);
    try std.testing.expectEqual(split.first, hier_leaf); // .right => existing moves first
    try std.testing.expectEqual(split.second, insp_leaf);
}

test "insertTab adds a tab to an existing leaf" {
    var layout = try DockLayout.initSingleLeaf(std.testing.allocator, "hierarchy");
    defer layout.deinit();

    try layout.insertTab(layout.root, 0, "scene");
    const leaf = layout.nodes.items[layout.root].leaf;
    try std.testing.expectEqual(@as(usize, 2), leaf.tabs.items.len);
    try std.testing.expectEqualStrings("scene", leaf.tabs.items[0]);
    try std.testing.expectEqual(@as(usize, 0), leaf.active);
}

test "removePanel collapses single-child split, preserving parent index" {
    var layout = try DockLayout.initSingleLeaf(std.testing.allocator, "hierarchy");
    defer layout.deinit();
    const root = layout.root;
    try layout.splitLeaf(root, .right, "inspector");

    layout.removePanel("inspector");

    try std.testing.expect(layout.root == root);
    try std.testing.expectEqual(Node.leaf, std.meta.activeTag(layout.nodes.items[root]));
    try std.testing.expect(layout.contains("hierarchy"));
    try std.testing.expect(!layout.contains("inspector"));
}

test "remove last panel leaves an empty root leaf" {
    var layout = try DockLayout.initSingleLeaf(std.testing.allocator, "hierarchy");
    defer layout.deinit();

    layout.removePanel("hierarchy");

    try std.testing.expectEqual(Node.leaf, std.meta.activeTag(layout.nodes.items[layout.root]));
    try std.testing.expectEqual(@as(usize, 0), layout.nodes.items[layout.root].leaf.tabs.items.len);
}

test "removing the active tab activates the previous index, not 0" {
    var layout = try DockLayout.initSingleLeaf(std.testing.allocator, "a");
    defer layout.deinit();
    try layout.insertTab(layout.root, 1, "b");
    try layout.insertTab(layout.root, 2, "c"); // active = 2 ("c")

    layout.removePanel("c");

    const leaf = layout.nodes.items[layout.root].leaf;
    try std.testing.expectEqualStrings("b", leaf.tabs.items[leaf.active]);
}

test "movePanel .tab moves panel between leaves and collapses source" {
    var layout = try DockLayout.initSingleLeaf(std.testing.allocator, "hierarchy");
    defer layout.deinit();
    const root = layout.root;
    try layout.splitLeaf(root, .right, "inspector");
    const insp_leaf = layout.findPanel("inspector").?;
    const hier_leaf = layout.findPanel("hierarchy").?;

    try layout.movePanel("hierarchy", .{ .tab = .{ .leaf = insp_leaf, .index = 0 } });

    try std.testing.expect(layout.root == root);
    try std.testing.expectEqual(Node.leaf, std.meta.activeTag(layout.nodes.items[root]));
    const leaf = layout.nodes.items[root].leaf;
    try std.testing.expectEqual(@as(usize, 2), leaf.tabs.items.len);
    try std.testing.expectEqualStrings("hierarchy", leaf.tabs.items[0]);
    _ = hier_leaf;
}

test "movePanel .split onto sibling leaf (adjacent collapse) does not corrupt tree" {
    var layout = try DockLayout.initSingleLeaf(std.testing.allocator, "a");
    defer layout.deinit();
    const root = layout.root;
    try layout.splitLeaf(root, .right, "b"); // root: split(a | b)
    const b_leaf = layout.findPanel("b").?;

    // Drag the only tab ("a") into "b"'s leaf as a new split (adjacent sibling).
    try layout.movePanel("a", .{ .split = .{ .leaf = b_leaf, .side = .bottom } });

    try std.testing.expect(layout.contains("a"));
    try std.testing.expect(layout.contains("b"));
    try std.testing.expect(layout.root == root);
}

test "movePanel .split onto self is a no-op when it is the only tab" {
    var layout = try DockLayout.initSingleLeaf(std.testing.allocator, "a");
    defer layout.deinit();
    const root = layout.root;

    try layout.movePanel("a", .{ .split = .{ .leaf = root, .side = .right } });

    try std.testing.expectEqual(Node.leaf, std.meta.activeTag(layout.nodes.items[root]));
    try std.testing.expectEqual(@as(usize, 1), layout.nodes.items[root].leaf.tabs.items.len);
}

test "movePanel .split on own leaf with other tabs splits off the dragged one" {
    var layout = try DockLayout.initSingleLeaf(std.testing.allocator, "a");
    defer layout.deinit();
    try layout.insertTab(layout.root, 1, "b");
    const root = layout.root;

    try layout.movePanel("a", .{ .split = .{ .leaf = root, .side = .right } });

    try std.testing.expect(layout.root == root);
    try std.testing.expectEqual(Node.split, std.meta.activeTag(layout.nodes.items[root]));
    try std.testing.expect(layout.contains("a"));
    try std.testing.expect(layout.contains("b"));
}

test "movePanel .split_root wraps a multi-panel tree, keeping root index stable" {
    var layout = try DockLayout.initSingleLeaf(std.testing.allocator, "a");
    defer layout.deinit();
    try layout.splitLeaf(layout.root, .right, "b");
    const root = layout.root;

    try layout.movePanel("a", .{ .split_root = .bottom });

    try std.testing.expect(layout.root == root);
    try std.testing.expectEqual(Node.split, std.meta.activeTag(layout.nodes.items[root]));
    try std.testing.expectEqual(dvui.enums.Direction.vertical, layout.nodes.items[root].split.dir);
    try std.testing.expect(layout.contains("a"));
    try std.testing.expect(layout.contains("b"));
}

test "movePanel .split_root onto self is a no-op when it is the only tab in the whole tree" {
    var layout = try DockLayout.initSingleLeaf(std.testing.allocator, "a");
    defer layout.deinit();
    const root = layout.root;

    try layout.movePanel("a", .{ .split_root = .left });

    try std.testing.expect(layout.root == root);
    try std.testing.expectEqual(Node.leaf, std.meta.activeTag(layout.nodes.items[root]));
}

test "insertTabOwned: a borrowed static id in an owning layout doesn't crash on deinit" {
    // An owning layout has every string duped from the start (never a mix);
    // "a" here stands in for that, so deinit freeing it afterward is valid.
    const owned_a = try std.testing.allocator.dupe(u8, "a");
    var layout = try DockLayout.initSingleLeaf(std.testing.allocator, owned_a);
    defer layout.deinit();
    layout.owns_panel_ids = true; // simulates a layout loaded via fromSnapshot

    const static_id: PanelId = "profiler"; // NOT allocated by layout.allocator
    try layout.insertTabOwned(layout.root, 1, static_id);

    try std.testing.expect(layout.contains("profiler"));
    // Removing it exercises the free path too (not just deinit's).
    layout.removePanel("profiler");
    try std.testing.expect(!layout.contains("profiler"));
}

test "insertTabOwned: leaves a borrowed id borrowed when the layout doesn't own its ids" {
    var layout = try DockLayout.initSingleLeaf(std.testing.allocator, "a");
    defer layout.deinit();

    const static_id: PanelId = "profiler";
    try layout.insertTabOwned(layout.root, 1, static_id);

    try std.testing.expectEqual(static_id.ptr, layout.nodes.items[layout.root].leaf.tabs.items[1].ptr);
}

test "floatPanel detaches a panel and freeNode/free-list is reused" {
    var layout = try DockLayout.initSingleLeaf(std.testing.allocator, "a");
    defer layout.deinit();
    try layout.insertTab(layout.root, 1, "b");
    const node_count_before = layout.nodes.items.len;

    try layout.floatPanel("b", .{ .x = 10, .y = 10, .w = 200, .h = 200 });

    try std.testing.expectEqual(@as(usize, 1), layout.floats.items.len);
    try std.testing.expect(!layout.contains("b") or layout.isFloat(layout.findPanel("b").?));
    try std.testing.expectEqual(@as(usize, 1), layout.nodes.items[layout.root].leaf.tabs.items.len);

    // Float back out (last tab of the float leaf) -> float entry removed and its slot recycled.
    const float_leaf = layout.findPanel("b").?;
    layout.removePanel("b");
    try std.testing.expectEqual(@as(usize, 0), layout.floats.items.len);
    try std.testing.expectEqual(layout.free_head.?, float_leaf);
    try std.testing.expectEqual(node_count_before + 1, layout.nodes.items.len);
}

test "collectActivePanels walks tree and floats" {
    var layout = try DockLayout.initSingleLeaf(std.testing.allocator, "a");
    defer layout.deinit();
    try layout.splitLeaf(layout.root, .right, "b");
    try layout.floatPanel("b", .{ .x = 0, .y = 0, .w = 100, .h = 100 });

    var list: std.ArrayList(PanelId) = .empty;
    defer list.deinit(std.testing.allocator);
    try layout.collectActivePanels(&list, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), list.items.len);
}

test "snapshot/fromSnapshot round-trip preserves tree, tabs, and floats" {
    var layout = try DockLayout.initSingleLeaf(std.testing.allocator, "a");
    defer layout.deinit();
    try layout.splitLeaf(layout.root, .right, "b");
    try layout.insertTab(layout.findPanel("b").?, 1, "c");
    try layout.floatPanel("c", .{ .x = 10, .y = 20, .w = 300, .h = 200 });

    const snap = try layout.snapshot(std.testing.allocator);
    defer snap.deinit(std.testing.allocator);

    // Plain `std.testing.allocator` (no arena): exercises that `deinit`
    // actually frees the slug strings `fromSnapshot` duplicated, not just the
    // node/tab-list containers — `owns_panel_ids` is what makes that safe.
    var loaded = try DockLayout.fromSnapshot(std.testing.allocator, snap);
    defer loaded.deinit();

    try std.testing.expect(loaded.owns_panel_ids);
    try std.testing.expect(loaded.contains("a"));
    try std.testing.expect(loaded.contains("b"));
    try std.testing.expect(loaded.contains("c"));
    try std.testing.expect(loaded.isFloat(loaded.findPanel("c").?));
    try std.testing.expectEqual(Node.split, std.meta.activeTag(loaded.nodes.items[loaded.root]));

    const b_float = loaded.floats.items[0];
    try std.testing.expectApproxEqAbs(@as(f32, 10), b_float.rect.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 300), b_float.rect.w, 0.01);

    // Also exercise removePanel actually freeing an owned slug (not just deinit).
    loaded.removePanel("c");
    try std.testing.expect(!loaded.contains("c"));
}

test {
    std.testing.refAllDecls(@This());
}

test "zoneAt: the middle is a tab and each band is its side" {
    const r: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 200, .h = 100 };
    try std.testing.expectEqual(Zone.tab, zoneAt(r, .{ .x = 100, .y = 50 }, 40).?.zone);
    try std.testing.expectEqual(Zone{ .split = .left }, zoneAt(r, .{ .x = 10, .y = 50 }, 40).?.zone);
    try std.testing.expectEqual(Zone{ .split = .right }, zoneAt(r, .{ .x = 190, .y = 50 }, 40).?.zone);
    try std.testing.expectEqual(Zone{ .split = .top }, zoneAt(r, .{ .x = 100, .y = 5 }, 40).?.zone);
    try std.testing.expectEqual(Zone{ .split = .bottom }, zoneAt(r, .{ .x = 100, .y = 95 }, 40).?.zone);
    try std.testing.expect(zoneAt(r, .{ .x = 300, .y = 50 }, 40) == null);
}

test "animated: a split opens marked, an emptied leaf closes marked, collapse promotes" {
    var layout = try DockLayout.initSingleLeaf(std.testing.allocator, "a");
    defer layout.deinit();
    layout.animated = true;
    const root = layout.root;

    try layout.splitLeaf(root, .right, "b");
    try std.testing.expectEqual(Node.Child.second, layout.nodes.items[root].split.opening.?);
    layout.nodes.items[root].split.opening = null; // the widget consumed it

    layout.removePanel("b");
    // Still a split: b's leaf is on its way out, not gone.
    try std.testing.expectEqual(Node.split, std.meta.activeTag(layout.nodes.items[root]));
    try std.testing.expectEqual(Node.Child.second, layout.nodes.items[root].split.closing.?);

    try layout.apply(.{ .collapse = root });
    try std.testing.expectEqual(Node.leaf, std.meta.activeTag(layout.nodes.items[root]));
    try std.testing.expect(layout.contains("a"));
}

test "a pinned leaf empties but is never collapsed" {
    var layout = try DockLayout.initSingleLeaf(std.testing.allocator, "a");
    defer layout.deinit();
    const root = layout.root;
    try layout.splitLeaf(root, .right, "b");
    const b_leaf = layout.findPanel("b").?;
    layout.nodes.items[b_leaf].leaf.pinned = true;

    layout.removePanel("b");
    try std.testing.expectEqual(Node.split, std.meta.activeTag(layout.nodes.items[root]));
    try std.testing.expectEqual(@as(usize, 0), layout.nodes.items[b_leaf].leaf.tabs.items.len);
}

test "closing a pinned leaf hands the pin and the name to its sibling" {
    var layout = try DockLayout.initSingleLeaf(std.testing.allocator, "Main");
    defer layout.deinit();
    const root = layout.root;
    layout.nodes.items[root].leaf.pinned = true;
    try layout.splitLeaf(root, .right, "Main/r1");

    // Close "Main" itself: the minted sibling becomes "Main", pinned, and its old id is
    // reported so the app can move what it keyed by it.
    const main_leaf = layout.findPanel("Main").?;
    layout.closeLeaf(main_leaf); // not animated: collapses now
    try std.testing.expectEqual(Node.leaf, std.meta.activeTag(layout.nodes.items[root]));
    try std.testing.expect(layout.nodes.items[root].leaf.pinned);
    try std.testing.expectEqualStrings("Main", layout.nodes.items[root].leaf.tabs.items[0]);
    const r = layout.takeRenamed().?;
    defer std.testing.allocator.free(r.from);
    try std.testing.expectEqualStrings("Main/r1", r.from);
    try std.testing.expectEqualStrings("Main", r.to);
}

test "a fixed child derives its ratio from points and writes a drag back as points" {
    var layout = try DockLayout.initSingleLeaf(std.testing.allocator, "a");
    defer layout.deinit();
    const root = layout.root;
    try layout.splitLeaf(root, .left, "side");
    layout.nodes.items[root].split.fixed = .{ .child = .first, .points = 250 };

    try std.testing.expectApproxEqAbs(@as(f32, 0.25), targetRatio(layout.nodes.items[root].split, 1000), 0.001);
    layout.setRatio(root, 0.5, 1000);
    try std.testing.expectApproxEqAbs(@as(f32, 500), layout.nodes.items[root].split.fixed.?.points, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), layout.nodes.items[root].split.ratio, 0.001); // untouched

    const snap = try layout.snapshot(std.testing.allocator);
    defer snap.deinit(std.testing.allocator);
    try std.testing.expectApproxEqAbs(@as(f32, 500), snap.root.split.fixed.?.points, 0.001);
}

fn testCellRoom(r: Row, i: usize) f32 {
    const start: f32 = if (i == 0) 0 else r.boundaries[i - 1] + r.gap;
    const end: f32 = if (i == r.floors.len - 1) r.extent else r.boundaries[i];
    return @max(0, end - start - r.floors[i]);
}

test "dragBoundary: dragging right past two sashes shrinks both cells in proportion and stacks the sashes" {
    // Three cells, rooms 100 / 50 / 140, two sashes of 10: extent 310.
    var boundaries = [_]f32{ 100, 160 };
    var floors = [_]f32{ 0, 0, 0 };
    var r = Row{ .boundaries = &boundaries, .floors = &floors, .gap = 10, .extent = 310 };
    r.dragBoundary(0, 10_000);

    const hi: f32 = 290; // extent - gap - right floors - the sash between the two right cells
    try std.testing.expectApproxEqAbs(hi, r.boundaries[0], 0.01);
    // The two right-hand sashes stack at gap spacing (plus the squeezed-side 0.01pt remnant).
    try std.testing.expectApproxEqAbs(r.gap, r.boundaries[1] - r.boundaries[0], 0.05);
    const s1 = testCellRoom(r, 1);
    const orig1: f32 = 50;
    const orig2: f32 = 140;
    try std.testing.expectApproxEqAbs(orig1 / (orig1 + orig2) * 0.01, s1, 0.001);
}

test "dragBoundary: dragging back restores the same proportions" {
    var boundaries = [_]f32{ 100, 160 };
    var floors = [_]f32{ 0, 0, 0 };
    var r = Row{ .boundaries = &boundaries, .floors = &floors, .gap = 10, .extent = 310 };
    const orig0 = boundaries[0];
    const orig1 = boundaries[1];
    // Past the second sash, but not onto the 0.01pt floor — reconstruction of the last cell stays faithful.
    r.dragBoundary(0, 200);
    try std.testing.expectApproxEqAbs(@as(f32, 50.0 / 140.0), testCellRoom(r, 1) / testCellRoom(r, 2), 0.001);
    r.dragBoundary(0, orig0);
    try std.testing.expectApproxEqAbs(orig0, r.boundaries[0], 0.05);
    try std.testing.expectApproxEqAbs(orig1, r.boundaries[1], 0.05);
}

test "dragBoundary: a cell's floor holds the boundary off it" {
    // Middle cell is a cross-axis subtree that needs 40pt of sashes along this axis.
    var boundaries = [_]f32{ 80, 150 };
    var floors = [_]f32{ 0, 40, 0 };
    var r = Row{ .boundaries = &boundaries, .floors = &floors, .gap = 10, .extent = 240 };
    r.dragBoundary(0, 10_000);
    const lo_right: f32 = 40; // middle floor
    const hi = 240 - 10 - lo_right - 10; // extent - this sash - right floors - inner sash
    try std.testing.expectApproxEqAbs(hi, r.boundaries[0], 0.01);
    const mid_len = r.boundaries[1] - (r.boundaries[0] + r.gap);
    try std.testing.expect(mid_len + 0.001 >= floors[1]);
}

test "ratioFor o divide round-trips" {
    const cases = [_]struct { extent: f32, ratio: f32, gap: f32, ff: f32, fs: f32 }{
        .{ .extent = 400, .ratio = 0.5, .gap = 10, .ff = 0, .fs = 0 },
        .{ .extent = 400, .ratio = 0.25, .gap = 10, .ff = 20, .fs = 30 },
        .{ .extent = 200, .ratio = 0.0, .gap = 8, .ff = 0, .fs = 0 },
        .{ .extent = 200, .ratio = 1.0, .gap = 8, .ff = 5, .fs = 5 },
        .{ .extent = 500, .ratio = 0.73, .gap = 10, .ff = 40, .fs = 0 },
    };
    for (cases) |c| {
        const d = Row.divide(c.extent, c.ratio, c.gap, c.ff, c.fs);
        try std.testing.expectApproxEqAbs(c.ratio, Row.ratioFor(d.first, c.extent, c.gap, c.ff, c.fs), 0.0001);
        try std.testing.expectApproxEqAbs(d.first, c.ff + d.usable * c.ratio, 0.0001);
    }
}

test "dragBoundary: clamps at both ends" {
    var boundaries = [_]f32{95};
    var floors = [_]f32{ 0, 0 };
    var r = Row{ .boundaries = &boundaries, .floors = &floors, .gap = 10, .extent = 200 };
    r.dragBoundary(0, -1_000);
    try std.testing.expectApproxEqAbs(@as(f32, 0.01), r.boundaries[0], 0.001);
    boundaries[0] = 95;
    r.dragBoundary(0, 10_000);
    try std.testing.expectApproxEqAbs(@as(f32, 190), r.boundaries[0], 0.01);
}

test "floorAlong: same-axis sashes add, a cross-axis subtree takes the wider child" {
    var layout = try DockLayout.initSingleLeaf(std.testing.allocator, "a");
    defer layout.deinit();
    const gap: f32 = 10;
    try layout.splitLeaf(layout.root, .right, "b");
    try std.testing.expectApproxEqAbs(gap, layout.floorAlong(layout.root, .horizontal, gap), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), layout.floorAlong(layout.root, .vertical, gap), 0.001);

    try layout.splitLeaf(layout.findPanel("b").?, .right, "c");
    try std.testing.expectApproxEqAbs(2 * gap, layout.floorAlong(layout.root, .horizontal, gap), 0.001);

    var nested = try DockLayout.initSingleLeaf(std.testing.allocator, "a");
    defer nested.deinit();
    try nested.splitLeaf(nested.root, .bottom, "b");
    try nested.splitLeaf(nested.findPanel("a").?, .right, "a2");
    try std.testing.expectApproxEqAbs(gap, nested.floorAlong(nested.root, .horizontal, gap), 0.001);
    try std.testing.expectApproxEqAbs(gap, nested.floorAlong(nested.root, .vertical, gap), 0.001);
}
