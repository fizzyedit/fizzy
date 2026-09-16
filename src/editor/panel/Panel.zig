//! Fizzy's own bottom panel: several tabbed panes side by side, split by the shared `Split`.
//!
//! **App furniture, not framework.** A shape asks for it by name — `layout.zig` passes
//! `bottomPane` as a region's `content` — and a differently-shaped app either passes
//! `Layout.tabbed` for a plain tabbed region, nothing at all for the single-surface form
//! (`presets/studio.zig`), or copies this directory and edits it. It sits here beside
//! `Explorer`, `Sidebar` and `Menu` rather than under `layout/`, because everything under
//! `layout/` is generic and every app has it, and this is fizzy's.
const std = @import("std");

const dvui = @import("dvui");
const fizzy = @import("../../fizzy.zig");

const panel_layout = @import("panel_layout.zig");
const Pane = @import("Pane.zig");

pub const Panel = @This();
const Layout = @import("app").layout.Layout;

scroll_info: dvui.ScrollInfo = .{
    .horizontal = .auto,
},

/// Bottom-panel splits keyed by tab-grouping id (mirrors workbench workspaces).
workspaces: std.AutoArrayHashMapUnmanaged(u64, Pane) = .empty,
open_pane: u64 = 0,
grouping_id_counter: u64 = 0,
/// Which split each registered bottom view belongs to (`view.id` -> grouping).
view_groupings: std.StringArrayHashMapUnmanaged(u64) = .empty,

pub fn init() Panel {
    return .{};
}

pub fn deinit(self: *Panel, allocator: std.mem.Allocator) void {
    self.workspaces.deinit(allocator);
    self.view_groupings.deinit(allocator);
}

pub fn draw(panel: *Panel, editor: *fizzy.Editor, f: *Layout, keywords: []const []const u8) !dvui.App.Result {
    var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = false,
    });
    defer vbox.deinit();

    const host = &editor.app.host;
    if (f.matching(keywords).len == 0) {
        Pane.drawBackground(0);
        return .ok;
    }

    panel.ensurePanes(f, keywords);
    try panel_layout.rebuildWorkspaces(panel, f, keywords);

    if (panel.workspaces.count() == 0) {
        try panel.workspaces.put(fizzy.entry().allocator, 0, Pane.init(0));
    }

    return try panel_layout.drawWorkspaces(panel, host, f, keywords, 0);
}

pub fn ensurePanes(self: *Panel, f: *Layout, keywords: []const []const u8) void {
    for (f.matching(keywords)) |view| {
        if (self.view_groupings.get(view.id) == null) {
            self.view_groupings.put(fizzy.entry().allocator, view.id, 0) catch {};
        }
    }
}

pub fn paneOf(self: *Panel, view_id: []const u8) u64 {
    return self.view_groupings.get(view_id) orelse 0;
}

pub fn setViewGrouping(self: *Panel, view_id: []const u8, grouping: u64) void {
    if (self.view_groupings.getPtr(view_id)) |g| {
        g.* = grouping;
    } else {
        self.view_groupings.put(fizzy.entry().allocator, view_id, grouping) catch {};
    }
}

pub fn newPaneId(self: *Panel) u64 {
    self.grouping_id_counter += 1;
    return self.grouping_id_counter;
}

pub fn viewIndex(self: *Panel, f: *Layout, keywords: []const []const u8, view_id: []const u8) ?usize {
    _ = self;
    for (f.matching(keywords), 0..) |view, i| {
        if (std.mem.eql(u8, view.id, view_id)) return i;
    }
    return null;
}

/// Drop panel bookkeeping that still names a surface which is no longer registered.
///
/// Both the keys of `view_groupings` and each workspace's `active_view_id` are *borrowed*
/// `Surface.id` slices, and for a runtime-loaded plugin those live in the plugin image's
/// static memory. Unregistering the plugin's contributions doesn't touch them, so without this
/// the panel goes on hashing and comparing strings that point into an unmapped library on every
/// frame it draws.
///
/// Call *after* `Host.unregisterPlugin` (so the doomed surfaces are already out of the
/// registry) and *before* `dlclose` (so these slices are still readable) — the same ordering
/// contract `unregisterPlugin` documents for the active-selection ids.
pub fn forgetUnregisteredSurfaces(self: *Panel, host: *fizzy.Editor.Host) void {
    // Checks the registry, not a Layout: this runs after `unregisterPlugin` and outside a frame,
    // so there is no live match set to consult. `surfaceById` is the frame-free equivalent —
    // an unregistered plugin's surfaces are removed by `removeOwned` at the same moment its
    // views are.
    var i = self.view_groupings.count();
    while (i > 0) {
        i -= 1;
        if (host.surfaceById(self.view_groupings.keys()[i]) == null) {
            self.view_groupings.swapRemoveAt(i);
        }
    }

    for (self.workspaces.values()) |*workspace| {
        const active = workspace.active_view_id orelse continue;
        // `rebuildWorkspaces` re-picks a live view for the grouping on the next draw.
        if (host.surfaceById(active) == null) workspace.active_view_id = null;
    }
}

pub fn activeSurfaceIn(self: *Panel, f: *Layout, keywords: []const []const u8, grouping: u64) ?*Layout.Surface {
    const workspace = self.workspaces.get(grouping) orelse return null;
    if (workspace.active_view_id) |active_id| {
        for (f.matching(keywords)) |view| {
            if (std.mem.eql(u8, view.id, active_id) and self.paneOf(view.id) == grouping) {
                return view;
            }
        }
    }
    for (f.matching(keywords)) |view| {
        if (self.paneOf(view.id) == grouping) return view;
    }
    return null;
}

/// Reorder two of this panel's surfaces, by id rather than by registry index.
///
/// Tab order is the match order, and a match set is filtered — so the indices a drag produces
/// are positions within *this region's* matches, not positions in `host.surfaces`. Translating
/// through ids is what keeps a reorder correct when some surfaces match a different region.
pub fn swapSurfaces(_: *Panel, host: *fizzy.Editor.Host, f: *Layout, keywords: []const []const u8, a: usize, b: usize) void {
    const list = f.matching(keywords);
    if (a >= list.len or b >= list.len or a == b) return;
    host.swapSurfaces(list[a].id, list[b].id);
}
