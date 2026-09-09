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
const layout_split = @import("split.zig");
const Constants = @import("../Constants.zig");
const chrome_ref = @import("chrome.zig");

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
/// from disagreeing. `Editor.layout_selection` is the fallback for any other keyword group.
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
    return self.editor.layout_selection.get(groupKey(keywords));
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
    self.editor.layout_selection.put(self.editor.gpa, groupKey(keywords), s.id) catch {};
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

/// Draw whichever surface is selected for these keywords, into the current parent. Everything
/// it does is reachable through `matching` / `selected` / `draw`; `region` uses it to fill a
/// declared region's space.
pub fn drawSelected(self: *Frame, keywords: []const []const u8) !dvui.App.Result {
    const s = self.selected(keywords) orelse return .ok;
    return self.draw(s);
}

// ── The base layer: regions and keywords ────────────────────────────────────────────────────
//
// Everything above is the vocabulary — which surfaces exist, which match, which is selected.
// This is the layer a *layout* is written against: a shape declares regions, and the framework
// owns the mechanism (paned trees, split ratios, persistence, collapse animation, auto-hide).
//
// The test this has to pass is that a shape never writes mechanism. Before it existed,
// `ide.zig` reached `dock.paned.dragging`, called `animateSplit`, read `split_ratio.*`, kept
// `editor.panel_ratio` in sync by hand and published `editor.panes.paned` so other code could
// find it — none of which an app author should know about, and all of which only worked because
// fizzy's own shape happens to have a panel.

/// Which edge a region takes. Re-exported from the split widget rather than declared again —
/// `Frame.Edge` and `split.Side` were two identical enums for one concept.
pub const Edge = layout_split.Side;

/// How a region presents itself when several surfaces match it.
///
/// This is a mode, and modes have been removed from this design twice already — so the reason
/// it survives here: it is the *region* stating how it shows its own contents, not a plugin
/// stating where it goes, and every value is reachable by hand from `matching`/`selected`/
/// `draw` if a shape wants something else. `.none` is the "this region IS x" form; `.tabs` is
/// the "this region is tabbed" form.
pub const Chooser = enum {
    none,
    tabs,
    icons,
    /// Fizzy's explorer chrome: a header naming the active surface plus a per-view scroll
    /// policy, wrapped around the region's content.
    explorer_chrome,
    /// Fizzy's panel chrome: a grouping-aware, drag-reorderable tab strip that additionally
    /// supports splitting the region into several panes.
    panel_chrome,
};

pub const RegionOptions = struct {
    /// Human-facing region name. Shown wherever a user picks a region — the settings table that
    /// lets someone place a surface directly, ignoring keywords entirely.
    name: []const u8,
    /// What kinds of surface this region accepts.
    keywords: []const []const u8,
    /// Which edge it takes. Null means "the remainder".
    edge: ?Edge = null,
    /// Fraction of the parent, when docked to an edge. Null uses the persisted size.
    size: ?f32 = null,
    resize: bool = false,
    collapsible: bool = false,
    chooser: Chooser = .none,
    /// Collapse the region while nothing matches it. Framework behaviour, not app policy: a
    /// region with nothing in it should not hold space open.
    hide_when_empty: bool = false,
};

/// A declared region: an area that accepts keywords and draws the surfaces matching them.
///
/// Note this is **not** docking in the draggable-panel sense — a region's place is fixed by the
/// shape that declares it. Real docking (dvui has dockable panels now) would be a layer *above*
/// this that lets the user move regions at runtime, and is the natural basis for a
/// Premiere-style shape. Named seam, not built.
///
/// `region` draws the region's own contents — the chooser, if it asked for one, and the active
/// matching surface — and leaves the caller positioned in the *remaining* space, so whatever the
/// layout writes next lands there. That is what removes the `showFirst`/`showSecond` pairs from
/// shapes.
pub const Region = struct {
    split: ?layout_split.Split,
    rest_visible: bool,

    /// True when the space beyond this region should draw. False while the region is expanded
    /// over everything (a collapsed-layout peek), so a shape can return early.
    pub fn rest(self: *Region) bool {
        return self.rest_visible;
    }

    pub fn end(self: *Region) void {
        if (self.split) |*s| s.deinit();
    }
};

/// Declare a region. See `RegionOptions`.
pub fn region(self: *Frame, src: std.builtin.SourceLocation, opts: RegionOptions) !Region {
    const editor = self.editor;
    const matches = self.matching(opts.keywords);

    // A region with nothing in it should not hold space open. Framework behaviour: an app that
    // wants an empty region to keep its space simply leaves `hide_when_empty` off.
    if (opts.hide_when_empty and matches.len == 0) {
        return .{ .split = null, .rest_visible = true };
    }

    const edge = opts.edge orelse {
        // The remainder. No split at all — draw straight into whatever space is left.
        _ = try self.drawRegionContents(opts, matches);
        return .{ .split = null, .rest_visible = true };
    };

    // Size persistence, first-frame collapse and drag-write are framework behaviour, keyed by
    // the region's name — a shape declaring a "Stack" gets its size remembered without fizzy
    // knowing what a Stack is. These were fifteen hand-written lines in `ide.zig`.
    const ratio_slot = editor.regionRatio(opts.name, opts.size orelse 0.25);

    var s = layout_split.split(editor, src, .{
        .side = edge,
        .keywords = opts.keywords,
        .size = ratio_slot.*,
        .resize = if (opts.resize) .drag else null,
        .collapse = if (opts.collapsible) .peek else null,
    });

    if (dvui.firstFrame(s.paned.wd.id)) {
        // Start collapsed when the window is too narrow to show both halves — the mobile / narrow
        // case — rather than animating open to a desktop size that will not fit.
        const avail = switch (edge) {
            .left, .right => s.paned.wd.contentRect().w,
            .top, .bottom => s.paned.wd.contentRect().h,
        };
        const too_narrow = avail < Constants.min_window_size[0];
        if (too_narrow or ratio_slot.* < 0.01) s.close() else s.open(ratio_slot.*);
    } else if (s.paned.dragging) {
        ratio_slot.* = s.ratio();
        editor.markWindowRatiosDirty();
    }

    if (s.showDock()) {
        _ = try self.drawRegionContents(opts, matches);
    }

    return .{ .split = s, .rest_visible = s.showRest() };
}

/// The chooser (if any) plus the active surface. Everything here is reachable by hand from
/// `matching` / `selected` / `draw` — a shape wanting a different chooser writes its own loop
/// and never calls `dock`.
fn drawRegionContents(self: *Frame, opts: RegionOptions, matches: []const *Surface) !dvui.App.Result {
    _ = matches;
    switch (opts.chooser) {
        .none => {},
        .tabs => chrome_ref.tabs(self, opts.keywords),
        .icons => _ = chrome_ref.iconRail(self, opts.keywords) catch {},
        // These two draw chrome *and* content, so they return directly. They are fizzy's own
        // richer variants (a titled scroll pane; a splittable tabbed panel) and exist as
        // chooser values rather than as app code because an app copying the IDE shape wants
        // them wholesale — see CLAUDE.md on shipped shapes.
        .explorer_chrome => return chrome_ref.explorerPane(self, opts.keywords),
        .panel_chrome => return chrome_ref.bottomPane(self, opts.keywords),
    }
    return self.drawSelected(opts.keywords);
}
