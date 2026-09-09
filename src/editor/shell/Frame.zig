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
const sdk = fizzy.sdk;

const Frame = @This();

/// The conventional keyword sets fizzy's own regions accept. A plugin targeting "the fizzy
/// shape" uses these; an app may accept any keywords it likes.
/// Back-compat aliases for the IDE preset. Prefer `sdk.keywords.ide.*` at call sites: it says
/// *which shape's* convention is being used, where a bare `sidebar_keywords` on the generic
/// Frame implies every app has a sidebar.
pub const sidebar_keywords = sdk.keywords.ide.sidebar;
pub const bottom_keywords = sdk.keywords.ide.panel;
pub const center_keywords = sdk.keywords.ide.main;

pub const Surface = sdk.Surface;

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

/// The keywords in force for a surface: the user's per-plugin override from `settings.zon` if
/// present, otherwise the plugin's declared defaults. This is what makes a wrong default cost
/// two clicks rather than a release.
fn effectiveKeywords(self: *Frame, s: *const Surface) []const []const u8 {
    if (self.editor.surface_keyword_overrides.get(s.id)) |kw| return kw;
    return s.keywords;
}

/// Every surface currently matching `keywords`, in registration order. Arena-allocated and
/// valid for this frame only; returns an empty slice rather than erroring so a layout can
/// always iterate.
pub fn matching(self: *Frame, keywords: []const []const u8) []const *Surface {
    var out: std.ArrayListUnmanaged(*Surface) = .empty;
    const a = self.arena();
    for (self.editor.host.surfaces.items) |*s| {
        if (s.hidden) continue;
        if (!intersects(self.effectiveKeywords(s), keywords)) continue;
        out.append(a, s) catch return out.items;
    }
    return out.items;
}

/// A surface by id, regardless of keywords — how an app places a plugin it ships with and
/// therefore knows by name (fizzy does this for `workbench.panes`).
pub fn surface(self: *Frame, id: []const u8) ?*Surface {
    return self.editor.host.surfaceById(id);
}

/// Surfaces that match no region this app declared. Never silently lost: the settings UI lists
/// these so a user (or the plugin author) can see the gap and fix it.
pub fn unplaced(self: *Frame, declared: []const []const []const u8) []const *Surface {
    var out: std.ArrayListUnmanaged(*Surface) = .empty;
    const a = self.arena();
    outer: for (self.editor.host.surfaces.items) |*s| {
        if (s.hidden) continue;
        const kw = self.effectiveKeywords(s);
        if (kw.len == 0) continue; // placed by id, not by keyword
        for (declared) |region_kw| if (intersects(kw, region_kw)) continue :outer;
        out.append(a, s) catch return out.items;
    }
    return out.items;
}

/// The selection group key for a keyword set.
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

/// Which legacy registry (if any) owns the selection for this keyword group.
///
/// The host already owns three selections — `active_sidebar_view`, `active_bottom_view`,
/// `active_center` — so for the conventional keyword sets `Frame` is a *view over existing
/// state* rather than a parallel store. That is what keeps the new shell and the legacy one
/// from disagreeing. `Editor.shell_selection` is the fallback for any other keyword group.
const LegacyOwner = enum { sidebar, bottom, center };

fn legacyOwner(keywords: []const []const u8) ?LegacyOwner {
    if (intersects(keywords, sidebar_keywords)) return .sidebar;
    if (intersects(keywords, bottom_keywords)) return .bottom;
    if (intersects(keywords, center_keywords)) return .center;
    return null;
}

fn currentId(self: *Frame, keywords: []const []const u8) ?[]const u8 {
    const host = &self.editor.host;
    if (legacyOwner(keywords)) |o| return switch (o) {
        .sidebar => host.active_sidebar_view,
        .bottom => host.active_bottom_view,
        .center => host.active_center,
    };
    return self.editor.shell_selection.get(groupKey(keywords));
}

/// Which surface is current for this keyword group, or null when nothing matches. Degrades: if
/// the remembered id is gone (plugin unloaded, keywords overridden elsewhere), falls back to the
/// first match rather than drawing nothing.
pub fn selected(self: *Frame, keywords: []const []const u8) ?*Surface {
    const items = self.matching(keywords);
    if (items.len == 0) return null;
    if (self.currentId(keywords)) |id| {
        for (items) |s| if (std.mem.eql(u8, s.id, id)) return s;
    }
    return items[0];
}

pub fn isSelected(self: *Frame, keywords: []const []const u8, s: *const Surface) bool {
    const cur = self.selected(keywords) orelse return false;
    return std.mem.eql(u8, cur.id, s.id);
}

pub fn select(self: *Frame, keywords: []const []const u8, s: *const Surface) void {
    const host = &self.editor.host;
    if (legacyOwner(keywords)) |o| {
        switch (o) {
            .sidebar => host.setActiveSidebarView(s.id),
            .bottom => host.setActiveBottomView(s.id),
            .center => host.setActiveCenter(s.id),
        }
        return;
    }
    self.editor.shell_selection.put(self.editor.gpa, groupKey(keywords), s.id) catch {};
}

/// Draw one surface into the current parent, wrapped in the swap cross-fade so every region gets
/// it for free. Keyed by **surface id**, never the parent box id — a box id moves with the
/// surrounding layout and would restart the fade on changes that are not content swaps (see the
/// warning at workbench `src/Workspace.zig:768`).
pub fn draw(self: *Frame, s: *Surface) !dvui.App.Result {
    _ = self;
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(s.id);
    const rv = fizzy.dvui.reveal(
        dvui.Id.extendId(null, @src(), @truncate(hasher.final())),
        hasher.final(),
        .{},
    );
    defer rv.deinit();
    return s.draw(s.ctx);
}

pub const RegionOptions = struct {
    keywords: []const []const u8,
};

/// Sugar for the common case: draw whichever surface is selected for these keywords. Everything
/// it does is reachable through `matching` / `selected` / `draw`.
pub fn region(self: *Frame, opts: RegionOptions) !dvui.App.Result {
    const s = self.selected(opts.keywords) orelse return .ok;
    return self.draw(s);
}
