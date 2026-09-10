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
const core = @import("core");
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

/// Open linear containers, innermost last. A container region pushes; its `end` pops. This is
/// what lets a leaf `region` know which splitter it is a slot of, and `split` know which
/// boundary it is marking, without either being passed a handle by the shape.
containers: [max_nesting]*core.dvui.SplitBox = undefined,
depth: usize = 0,

/// Layouts nest a few levels; anything deeper is a mistake worth reporting rather than
/// supporting. Keeps the stack a fixed array with no allocation on the layout path.
pub const max_nesting = 8;

pub fn init(editor: *fizzy.Editor) Frame {
    return .{ .editor = editor };
}

fn innermost(self: *Frame) ?*core.dvui.SplitBox {
    return if (self.depth == 0) null else self.containers[self.depth - 1];
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

/// How a region draws its own contents.
///
/// Null means "draw the selected matching surface" — the "this region IS x" form. A function
/// means the region has chrome of its own: a tab strip above its content, a titled scroll pane,
/// a splittable panel. It is handed the region's keywords and returns when the region is full.
///
/// This replaced a five-value `Chooser` enum, two of whose values (`explorer_chrome`,
/// `panel_chrome`) named *fizzy's own* furniture from inside the generic layer. That is the
/// case CLAUDE.md calls a bug in `Frame` rather than a special case: a shape is supposed to be
/// ordinary code over this API, and an app copying `ide.zig` could not have written those two
/// values itself. As a function pointer they are just `chrome.explorerPane` and
/// `chrome.bottomPane` — app code, passed in, replaceable by the app's own loop over
/// `matching` / `selected` / `draw`, which is the governing test for everything here.
///
/// It also retired the two values nothing used (`.tabs`, `.icons`); `chrome.tabbed` is the
/// first of those as a plain function, and the icon rail was never this shape to begin with —
/// it sits *beside* the region it chooses for, so `ide.zig` calls it directly and reads the
/// action it returns.
pub const Content = *const fn (f: *Frame, keywords: []const []const u8) anyerror!dvui.App.Result;

pub const RegionOptions = struct {
    /// Human-facing region name. Shown wherever a user picks a region — the settings table that
    /// lets someone place a surface directly, ignoring keywords entirely. A container region
    /// needs none: nothing is placed in it directly.
    name: []const u8 = "",
    /// What kinds of surface this region accepts. Empty on a container region.
    keywords: []const []const u8 = &.{},
    /// Set to make this a **container**: a region that holds other regions along `dir`, with
    /// `split` marking draggable boundaries between them. Null makes it a leaf — a place
    /// surfaces draw.
    ///
    /// One verb doing both is deliberate rather than an overload. A container with keywords
    /// would be a region that is both a place and a place-holder, and there is no third
    /// concept: you subdivide, or you host content.
    dir: ?dvui.enums.Direction = null,
    /// Which edge it takes. Null means "the remainder".
    edge: ?Edge = null,
    /// Fraction of the parent, when docked to an edge. Null uses the persisted size.
    size: ?f32 = null,
    resize: bool = false,
    collapsible: bool = false,
    /// Chrome this region draws around/instead of its selected surface. See `Content`.
    content: ?Content = null,
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
/// `region` draws the region's own contents — its chrome, if it declared any, and the active
/// matching surface — and leaves the caller positioned in the *remaining* space, so whatever the
/// layout writes next lands there. That is what removes the `showFirst`/`showSecond` pairs from
/// shapes.
pub const Region = struct {
    split: ?layout_split.Split = null,
    rest_visible: bool = true,
    /// Set when this region is a **container**: the splitter it opened, which `end` pops.
    container: ?*core.dvui.SplitBox = null,
    /// For a nested container, the parent's slot it was opened inside. Leaves close their own
    /// slot before returning and leave this null.
    slot: ?*dvui.BoxWidget = null,
    frame: ?*Frame = null,

    /// True when the space beyond this region should draw. False while the region is expanded
    /// over everything (a collapsed-layout peek), so a shape can return early.
    ///
    /// Always true for a linear region: there is no "rest" to gate. N regions on an axis each
    /// have their own share, which is the branching the linear form exists to remove — a shape
    /// written against containers never calls this.
    pub fn rest(self: *Region) bool {
        return self.rest_visible;
    }

    pub fn end(self: *Region) void {
        // Innermost first: the splitter, then the parent slot it lives in.
        if (self.container) |box| {
            if (self.frame) |f| {
                std.debug.assert(f.depth > 0);
                f.depth -= 1;
            }
            box.deinit();
        }
        if (self.slot) |b| b.deinit();
        if (self.split) |*sp| sp.deinit();
    }
};

/// Declare a region. See `RegionOptions`.
///
/// Three forms, chosen by the options and by where the call sits:
///
///   * `dir` set — a **container**. Opens a linear splitter; regions declared inside it are its
///     children and `split` puts draggable boundaries between them.
///   * inside a container — a **leaf**. Takes the next slot and draws its contents there.
///   * outside any container — the **edge-docked** form, which docks to `edge` and leaves the
///     caller in the remaining space (`rest`). This is what `ide.zig` still uses; it predates
///     the linear form and is kept until collapse/peek exists on the linear path.
pub fn region(self: *Frame, src: std.builtin.SourceLocation, opts: RegionOptions) !Region {
    if (opts.dir) |dir| {
        if (self.depth >= max_nesting) {
            dvui.log.err("layout nests deeper than {d} containers; region \"{s}\" ignored", .{ max_nesting, opts.name });
            return .{};
        }
        // A container inside a container is one of its parent's shares, so it takes a slot
        // first and opens inside it. Without this it would be a child of the parent splitter
        // with no slot of its own, which `SplitBox` now reports rather than misplacing.
        const parent_slot = if (self.innermost()) |parent| parent.slot(src) else null;
        const box = core.dvui.splitBox(src, .{ .dir = dir }, .{ .expand = .both });
        self.containers[self.depth] = box;
        self.depth += 1;
        return .{ .container = box, .slot = parent_slot, .frame = self };
    }

    const box = self.innermost() orelse return self.edgeRegion(src, opts);

    const matches = self.matching(opts.keywords);
    // A region with nothing in it should not hold a share of the axis open.
    //
    // Note this changes the child count, so the splitter redistributes its boundaries — the
    // sizes either side are not preserved across the region appearing and disappearing.
    // `split_layout.insertSplit` / `removeSplit` exist to do that properly and are the intended
    // fix; wiring them needs a stable per-region identity, not just an index.
    if (opts.hide_when_empty and matches.len == 0) return .{};

    // A leaf **opens and closes within this call**, so it is a complete statement and needs no
    // `end`. It has to be: deferring a leaf's close to the end of the layout scope would leave
    // its box as the current dvui parent, and every later sibling would be created *inside* it
    // rather than beside it. Only containers, which really do enclose what follows, return
    // something to end.
    const slot = box.slot(src);
    defer slot.deinit();
    _ = try self.drawRegionContents(opts, matches);
    return .{};
}

/// A draggable boundary between the previous region and the next, inside a container.
///
/// It takes no direction: a split inherits the axis of the container it is in, so direction is
/// declared once, on the container, rather than restated at every boundary.
pub fn split(self: *Frame, opts: SplitOptions) void {
    const box = self.innermost() orelse {
        dvui.log.err("split() outside a container region does nothing", .{});
        return;
    };
    if (opts.resize) box.handle();
}

pub const SplitOptions = struct {
    /// False makes the boundary static: the regions either side still divide the axis, but the
    /// user cannot move the edge between them.
    resize: bool = true,
};

/// The original edge-docking region. See `region`.
fn edgeRegion(self: *Frame, src: std.builtin.SourceLocation, opts: RegionOptions) !Region {
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

/// The region's contents: its own chrome if it declared any, otherwise the active surface.
///
/// Everything reachable here is reachable by hand from `matching` / `selected` / `draw`, so a
/// shape wanting something else writes its own function and passes it as `content`.
fn drawRegionContents(self: *Frame, opts: RegionOptions, matches: []const *Surface) !dvui.App.Result {
    _ = matches;
    const content = opts.content orelse return self.drawSelected(opts.keywords);
    return content(self, opts.keywords);
}
