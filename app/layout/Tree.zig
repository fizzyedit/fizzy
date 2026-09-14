//! Walker over a seed-backed `dockspace(header = .none)`.
//!
//! `Layout.tree` returns one; `leaf()` yields each cell; `regionIn` draws a region into it.
//! `deinit` applies the widget's queued mutations (sash drags, animated collapses).
const dvui = @import("dvui");
const core = @import("core");

const Layout = @import("Layout.zig");
const Seed = @import("Seed.zig");
const Region = @import("Region.zig");

const Dockspace = core.widgets.DockingWidget;
const DockLayout = core.widgets.DockLayout;

const Tree = @This();

dock: *Dockspace,
layout: *Layout,
seed: *const Seed.Tree,

/// One cell of the walk: the live dock leaf plus the spec the seed (or a mint) gave it.
pub const Leaf = struct {
    name: []const u8,
    keywords: []const []const u8 = &.{},
    shows: Region.Shows = .one,
    pinned: bool = false,
    panel: Dockspace.Panel,

    pub fn end(self: Leaf) void {
        self.panel.end();
    }
};

pub fn leaf(self: *Tree) ?Leaf {
    const p = self.dock.panel() orelse return null;
    const spec = self.seed.findLeaf(p.id) orelse Seed.Leaf{
        .name = p.id,
        .keywords = Layout.slot_keywords,
        .shows = .one,
        .pinned = false,
    };
    const pinned = if (self.layout.state.dock) |*d| blk: {
        break :blk switch (d.nodes.items[p.leaf]) {
            .leaf => |l| l.pinned,
            else => spec.pinned,
        };
    } else spec.pinned;
    return .{
        .name = p.id,
        .keywords = spec.keywords,
        .shows = spec.shows,
        .pinned = pinned,
        .panel = p,
    };
}

pub fn deinit(self: *Tree) void {
    if (self.dock.changed) self.layout.state.markDirty();
    self.dock.deinit();
    // A collapse may have handed a declared place's pin — and its name — to a sibling.
    if (self.layout.state.dock) |*d| {
        if (d.takeRenamed()) |r| {
            defer d.allocator.free(r.from);
            self.layout.state.renamePlace(self.layout.gpa, r.from, r.to);
        }
    }
}
