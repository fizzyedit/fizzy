//! The layout-side API an app's `layout()` function talks to.
//!
//! SPIKE NOTE (Phase 1): `Surface` here is *synthesized* from fizzy's existing
//! `host.sidebar_views` / `bottom_views` / `center_providers` registries rather than being a
//! real SDK type. That is deliberate — it lets the new shell run against every existing plugin
//! with zero plugin changes and no ABI bump, which is the whole point of doing the spike before
//! Phase 4. The default keywords assigned per registry are exactly the compat sugar Phase 4
//! will implement for real (see plan §F).
const std = @import("std");
const dvui = @import("dvui");
const fizzy = @import("../../fizzy.zig");

const Frame = @This();

/// Default keywords by originating registry. Phase 4 replaces this with keywords a plugin
/// declares on `Surface` directly; until then these are what `registerSidebarView` and friends
/// will desugar to.
pub const sidebar_keywords: []const []const u8 = &.{ "sidebar", "explorer" };
pub const bottom_keywords: []const []const u8 = &.{ "bottom", "panel", "output" };
pub const center_keywords: []const []const u8 = &.{ "main", "center", "workspace" };

pub const Origin = enum { sidebar, bottom, center };

/// A named thing that can draw. One identifier, plus the keywords describing what kind of
/// place it belongs in — never where it goes.
pub const Surface = struct {
    id: []const u8,
    title: []const u8,
    icon: ?[]const u8 = null,
    keywords: []const []const u8,
    origin: Origin,
    /// Index into the originating registry, valid for this frame only.
    index: usize,
};

editor: *fizzy.Editor,

pub fn init(editor: *fizzy.Editor) Frame {
    return .{ .editor = editor };
}

fn arena(self: *Frame) std.mem.Allocator {
    return self.editor.arena.allocator();
}

fn intersects(a: []const []const u8, b: []const []const u8) bool {
    for (a) |x| for (b) |y| {
        if (std.ascii.eqlIgnoreCase(x, y)) return true;
    };
    return false;
}

/// Every surface currently matching `keywords`, in registration order. Arena-allocated;
/// valid for this frame only. Returns an empty slice rather than erroring so a layout can
/// always iterate.
pub fn matching(self: *Frame, keywords: []const []const u8) []const Surface {
    var out: std.ArrayListUnmanaged(Surface) = .empty;
    const a = self.arena();
    const host = &self.editor.host;

    if (intersects(keywords, sidebar_keywords)) {
        for (host.sidebar_views.items, 0..) |*v, i| {
            if (v.hidden) continue;
            out.append(a, .{
                .id = v.id,
                .title = v.title,
                .icon = v.icon,
                .keywords = sidebar_keywords,
                .origin = .sidebar,
                .index = i,
            }) catch return out.items;
        }
    }
    if (intersects(keywords, bottom_keywords)) {
        for (host.bottom_views.items, 0..) |*v, i| {
            out.append(a, .{
                .id = v.id,
                .title = v.title,
                .keywords = bottom_keywords,
                .origin = .bottom,
                .index = i,
            }) catch return out.items;
        }
    }
    if (intersects(keywords, center_keywords)) {
        for (host.center_providers.items, 0..) |*p, i| {
            out.append(a, .{
                .id = p.id,
                .title = p.id,
                .keywords = center_keywords,
                .origin = .center,
                .index = i,
            }) catch return out.items;
        }
    }
    return out.items;
}

/// The selection group key for a keyword set. Groups are keyed by the keywords themselves, so
/// two regions written with the same keywords share a selection with no wiring between them.
fn groupKey(keywords: []const []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    for (keywords) |k| {
        var buf: [64]u8 = undefined;
        const n = @min(k.len, buf.len);
        for (k[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
        h.update(buf[0..n]);
        h.update("\x00");
    }
    return h.final();
}

/// Which registry (if any) owns the selection for this keyword group.
///
/// SPIKE NOTE: the host already owns all three selections — `active_sidebar_view`,
/// `active_bottom_view`, `active_center` — so `Frame` is a *view over existing state*, not a
/// parallel store. That is what keeps the new shell behaviourally identical to the old one
/// (Phase 1's acceptance bar) and stops two selection systems from fighting. `shell_selection`
/// is the fallback for keyword groups no legacy registry owns.
fn legacyOrigin(keywords: []const []const u8) ?Origin {
    if (intersects(keywords, sidebar_keywords)) return .sidebar;
    if (intersects(keywords, bottom_keywords)) return .bottom;
    if (intersects(keywords, center_keywords)) return .center;
    return null;
}

fn currentId(self: *Frame, keywords: []const []const u8) ?[]const u8 {
    const host = &self.editor.host;
    if (legacyOrigin(keywords)) |o| return switch (o) {
        .sidebar => host.active_sidebar_view,
        .bottom => host.active_bottom_view,
        .center => host.active_center,
    };
    return self.editor.shell_selection.get(groupKey(keywords));
}

/// Which surface is current for this keyword group, or null when nothing matches.
/// Degrades: if the remembered id is gone (plugin unloaded, keywords changed), falls back to
/// the first match rather than drawing nothing.
pub fn selected(self: *Frame, keywords: []const []const u8) ?Surface {
    const items = self.matching(keywords);
    if (items.len == 0) return null;
    if (self.currentId(keywords)) |id| {
        for (items) |s| if (std.mem.eql(u8, s.id, id)) return s;
    }
    return items[0];
}

pub fn isSelected(self: *Frame, keywords: []const []const u8, s: Surface) bool {
    const cur = self.selected(keywords) orelse return false;
    return std.mem.eql(u8, cur.id, s.id);
}

pub fn select(self: *Frame, keywords: []const []const u8, s: Surface) void {
    const host = &self.editor.host;
    if (legacyOrigin(keywords)) |o| {
        switch (o) {
            .sidebar => host.setActiveSidebarView(s.id),
            .bottom => host.setActiveBottomView(s.id),
            .center => host.setActiveCenter(s.id),
        }
        return;
    }
    self.editor.shell_selection.put(fizzy.app().allocator, groupKey(keywords), s.id) catch {};
}

/// Draw one surface into the current parent, wrapped in the swap cross-fade so every region
/// gets it for free (plan §D). Keyed by surface id, never by the parent's id — a box id moves
/// with the surrounding layout and would restart the fade on changes that are not content
/// swaps (see the warning at workbench Workspace.zig:768).
pub fn draw(self: *Frame, s: Surface) !dvui.App.Result {
    const host = &self.editor.host;
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(s.id);
    const rv = fizzy.dvui.reveal(
        dvui.Id.extendId(null, @src(), @truncate(groupKey(s.keywords))),
        hasher.final(),
        .{},
    );
    defer rv.deinit();

    switch (s.origin) {
        .sidebar => {
            if (s.index >= host.sidebar_views.items.len) return .ok;
            try host.sidebar_views.items[s.index].draw(host.sidebar_views.items[s.index].ctx);
        },
        .bottom => {
            if (s.index >= host.bottom_views.items.len) return .ok;
            try host.bottom_views.items[s.index].draw(host.bottom_views.items[s.index].ctx);
        },
        .center => {
            if (s.index >= host.center_providers.items.len) return .ok;
            return try host.center_providers.items[s.index].draw(host.center_providers.items[s.index].ctx);
        },
    }
    return .ok;
}

pub const RegionOptions = struct {
    keywords: []const []const u8,
};

/// Sugar for the common case: draw whichever surface is selected for these keywords.
/// Everything it does is reachable via `matching` / `selected` / `draw`.
pub fn region(self: *Frame, opts: RegionOptions) !dvui.App.Result {
    const s = self.selected(opts.keywords) orelse return .ok;
    return self.draw(s);
}
