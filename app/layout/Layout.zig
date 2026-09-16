//! What an app's shape declares its regions with — the whole of how an app lays itself out.
//!
//! A region says which keywords it accepts; a plugin's `sdk.Surface` says which it carries. The
//! intersection is the match set the region draws, so neither side names the other and an app
//! can invent a region shape the SDK has never heard of.
//!
//! The three pieces, all in this directory: `Layout` is the live view (which surfaces exist,
//! which match a region, which is selected), `Region.zig` is a named area accepting keywords,
//! and fizzy's own shape lives in `src/editor/layout.zig`. The resizable division
//! between two regions is `core.widgets.Split`, and a tab strip is `core.widgets.Tabs` — both in
//! `core` rather than here because a plugin dylib draws the same ones the app does.
//!
//! ## Who draws the tabs
//!
//! There are two forms, both supported, and the difference is *what the tabs represent*:
//!
//! **The app draws them** when the tabs represent surfaces — several plugins each contributing
//! a pane to one region. The app owns the strip because no single plugin can: they must share
//! it. Fizzy's bottom panel is this. A shape writes `f.tabs(kw)` then draws the selected
//! surface, or passes `.content = Layout.tabbed` to the region.
//!
//! **The plugin draws them** when the tabs represent something only the plugin knows about —
//! its own documents, timelines, layers. Then the plugin registers *one* surface and draws the
//! entire region: its own tab strip, its own splits, its own content. Fizzy's main area is
//! already exactly this: `workbench` registers one surface and draws document tabs and splits
//! inside it (`Workspace.drawTabs`), and neither fizzy nor any shape knows how many tabs there
//! are.
//!
//! Nothing distinguishes the two at registration — a surface is a surface, and drawing a tab
//! strip inside your own area needs no permission.
//!
//! ## The shape of a layout
//!
//! ```zig
//! var body = f.region(@src(), .{ .dir = .horizontal });
//! defer body.deinit();
//!
//!     f.region(@src(), .{ .name = "Sidebar", .keywords = kw.ide.sidebar });
//!     f.split(@src(), .{ .resize = true, .collapsible = true });
//!
//!     var right = f.region(@src(), .{ .dir = .vertical });
//!     defer right.deinit();
//!         f.region(@src(), .{ .name = "Main",  .keywords = kw.ide.main });
//!         f.split(@src(), .{ .resize = true });
//!         f.region(@src(), .{ .name = "Panel", .keywords = kw.ide.panel });
//! ```
//!
//! One object with two verbs: declare a region, or put a draggable split between the last one
//! and the next. Reads top to bottom, no `showFirst` / `showSecond` / `rest()` branching, and N
//! regions on an axis rather than a forced tree of two-child panes. Nesting is how you cross
//! axes — a region's content can be another layout.
//!
//! A layout mixes `region` / `split` with whatever dvui the app wants to draw — a menu, an
//! infobar, a rail. The app's own pointer arrives as `ctx` (`Host.layout_ctx`; fizzy passes
//! `*Editor`). `region` still does double duty: with keywords it is a place surfaces draw;
//! without, it is a container for more regions.
//!
//! `dir` is what a container region orients — **its child regions and splits**, not content. A
//! horizontal region lays its children left to right, and a `split` inside it is therefore a
//! vertical bar you drag left and right. The split inherits the containing region's axis rather
//! than restating it, so direction is declared in exactly one place; an explicit `dir` on a
//! split is available for the rare case that has to differ.
//!
//! ## How a region gets its size
//!
//! From `expand`, which is dvui's existing meaning rather than a new concept — so there is no
//! separate sizing vocabulary to learn, and the three cases fall out of one field:
//!
//! **Fit to content.** A region that does not expand along its parent's axis takes its size from
//! its content's minimum. In a horizontal container, `.expand = .vertical` means "as wide as
//! what is in me". This is the answer to "a region only large enough to contain its content":
//! you do not size it, and there is no split position to store, because the content decides.
//!
//! **Stretch, with a draggable boundary.** `.expand = .both` on both neighbours means neither
//! has an opinion, so the `split` between them owns the boundary and persists it. A split
//! position is only meaningful when both sides stretch — which is why size belongs on the split
//! rather than on the region.
//!
//! **Fixed.** Fit-to-content plus a minimum: the icon rail is `.expand = .vertical` with a 40pt
//! minimum width, and needs no split at all.
//!
//! The hazard in fit-to-content is that it hands size control to whatever plugin draws there —
//! a surface with a wide minimum makes the region wide. So a fitting region should carry a
//! `max_size` guard, again dvui's existing `max_size_content`. An app that does not want a
//! plugin dictating its proportions uses the stretch form instead.
//!
//! ## Two audiences, two levels
//!
//! **App authors** use only this: `region` and `split`, with keywords assigned per region. They
//! never touch dvui. That is the whole point of the level existing, and it is why the surface
//! is two verbs rather than a widget toolkit — a small enough vocabulary to hold in your head
//! and, prospectively, to check at comptime (a layout that declares a region twice, or splits
//! outside a container, is a compile error rather than a confusing frame).
//!
//! **Plugin authors** work a level down: raw dvui for their own content, plus fizzy's mid-level
//! constructs where one exists — `core.widgets.CanvasWidget` for zoom/pan surfaces, `Tabs`, the
//! dialog chrome in `core.dialogs.dialog`, scroll areas with edge shadows, context menus. Those
//! are content blocks, not layout, and they live in `core` precisely so a dylib can reach them.
//!
//! It also leaves room for the thing this is ultimately for: once regions are the only unit, a
//! region can be dragged to move or re-split it at runtime, which is how a Premiere- or
//! Blender-style app would work. Fizzy itself stays rigid — its shape is fixed by
//! `src/editor/layout.zig` — but nothing in the model prevents an app from letting the user rearrange.
//!
//! ## Layered regions and blur
//!
//! A tray that blurs what is behind it (the bottom panel over the editor; a scroll edge over its
//! own overflowing content) is designed but not built — see `LAYERS.md` in this directory. The
//! short version, because it is the decision most likely to be re-derived wrongly: blur is a
//! **property of a region** (`.blur_behind`), never a layout verb that reverses render order. An
//! app author must not have to reason about paint order to place a panel, and reversing paint
//! order does not reverse dvui's event routing — declaration order and hit-test order would stop
//! agreeing.
//!
//! Note the core pieces come through the named `core` module, never by relative path: a file may
//! belong to only one module, and `@import("../../core/...")` here would claim it for the root
//! build module and break `core` as a dependency outright (CLAUDE.md).
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const core = @import("core");
const sdk = @import("fizzy_sdk");
const Split = core.widgets.Split;

const Layout = @This();

/// The conventional keyword sets fizzy's own regions accept. A plugin targeting "the fizzy
/// shape" uses these; an app may accept any keywords it likes.
/// Back-compat aliases for the IDE preset. Prefer `sdk.keywords.ide.*` at call sites: it says
/// *which shape's* convention is being used, where a bare `sidebar_keywords` on the generic
/// Layout implies every app has a sidebar.
pub const sidebar_keywords = sdk.keywords.ide.sidebar;
pub const bottom_keywords = sdk.keywords.ide.panel;
pub const center_keywords = sdk.keywords.ide.main;

pub const Surface = sdk.Surface;

/// The app's pointer for this frame — `Host.layout_ctx`, or fizzy's `*Editor`.
/// Same `?*anyopaque` as `Surface.draw` and `Region.Content`.
ctx: ?*anyopaque = null,
/// The registries this layout matches against and selects in.
host: *sdk.Host,
/// Per-frame scratch: match lists handed to a shape live until the frame ends.
arena: std.mem.Allocator,
/// What persists between frames — the declared regions, their extents, the user's keyword
/// overrides. Owned by the application; a `Layout` is per-frame and this is not.
state: *State,
/// Long-lived allocations the state makes (a remembered extent's name).
gpa: std.mem.Allocator,
/// Set when a region's remembered extent changed this frame. The application decides what that
/// means — fizzy debounces a write to `layout.zon`.
extents_changed: bool = false,
/// Every surface `draw` ran this frame, so `captureUnplaced` knows which ones genuinely drew
/// nowhere — as opposed to drew before the picker asked. Arena-backed, per frame.
drawn: std.ArrayListUnmanaged(*Surface) = .empty,

/// Open regions, innermost last. Every region pushes; its `deinit` pops. This is what lets
/// `split` know which axis it divides and which neighbour it resizes, without a shape having to
/// pass either in.
containers: [max_nesting]Container = undefined,
depth: usize = 0,

/// Open regions declared by *plugins*, innermost last — see `beginPluginRegion`. A separate
/// stack because these are the ones nobody scoped with a `defer`: the app holds them on the
/// plugin's behalf between two vtable calls. Bounded by `max_nesting` for the same reason the
/// container stack is: a layout this deep is a mistake to report, not a case to support.
plugin_regions: [max_nesting]Region = undefined,
plugin_depth: usize = 0,

pub const PendingSplit = struct { src: std.builtin.SourceLocation, opts: Split.Options };

pub const Container = struct {
    dir: dvui.enums.Direction,
    /// The dotted name of the region this container *is*, which the regions declared inside it
    /// qualify their keywords with — `"main"` here makes a child's `{"document"}` into
    /// `{"main.document"}`. Empty for a container that accepts nothing itself: a pure grouping
    /// box is not a place, so it passes its own parent's name through rather than inventing a
    /// level of vocabulary a shape never wrote.
    ///
    /// A region's *first* keyword, not all of them. `main` names the same place as `center` and
    /// `workspace`, and qualifying under every synonym would multiply the vocabulary by three to
    /// say one thing — while `accepts` already lets a surface reach the sub-place by kind
    /// (`document`) without naming any ancestor at all.
    prefix: []const u8 = "",
    /// The base region's declared minimum along the axis — `min_size_content` on the region in
    /// this container that is not resizable. The app declares it; the framework only reads it.
    base_min: f32 = 0,
    /// Every resizable region in this container. A split needs them all so `push_out` can
    /// shrink the trays behind the one being dragged. Arena-backed, this frame only — no count cap.
    resizables: std.ArrayListUnmanaged(dvui.Id) = .empty,
    /// Packed splits in this container, each `Split.handle_size`. The drag
    /// budget subtracts this so a handle is never eaten by a tray.
    handles: f32 = 0,
    /// The container's own box, for measuring how near the pointer is to a split inside it.
    box: ?*dvui.BoxWidget = null,
    /// A split declared and not yet drawn. A split is a boundary *between* two regions, so it is
    /// drawn when the region after it opens — and not at all if that region declines to exist
    /// (`hide_when_empty`). Drawing it eagerly left a handle with nothing behind it, still
    /// draggable, still resizing a region that was not there.
    pending_split: ?PendingSplit = null,
    /// The most recent resizable child. A `split` drags *this* region's stored extent — the
    /// neighbour before it — which is the whole of the resize mechanism: there are no ratios and
    /// no boundary table, just one number per resizable region.
    last_resizable: ?dvui.Id = null,
    /// A non-resizable child has been declared (the leftover, or a grouping box around it).
    saw_base: bool = false,

    /// How far this container reaches along `axis`, in points — its width when horizontal, its
    /// height when vertical. The same single number a region calls its extent, measured for the
    /// thing regions sit inside.
    pub fn extent(self: *Container, axis: dvui.enums.Direction) f32 {
        const b = self.box orelse return 0;
        const r = b.data().contentRect();
        return switch (axis) {
            .horizontal => r.w,
            .vertical => r.h,
        };
    }
};

/// Layouts nest a few levels; anything deeper is a mistake worth reporting rather than
/// supporting. Keeps the stack a fixed array with no allocation on the layout path.
pub const max_nesting = 16;

/// Empty place created by a runtime split. Nothing a plugin ships matches this
/// word, so the new side stays empty until the picker fills it.
pub const slot_keywords: []const []const u8 = &.{"slot"};

// How long a region takes to fold away or come back is `core.anim.slide` — one home for the
// timing, because a sidebar and a document pane travelling at different speeds reads as broken
// without ever looking wrong in a screenshot.

pub fn init(host: *sdk.Host, state: *State, gpa: std.mem.Allocator, arena: std.mem.Allocator) Layout {
    return .{ .host = host, .state = state, .gpa = gpa, .arena = arena };
}

fn innermost(self: *Layout) ?*Container {
    return if (self.depth == 0) null else &self.containers[self.depth - 1];
}

/// Thickness of a split, and how near the pointer must be before it shows itself. Fizzy's tuned
/// split values (`layout.split`), kept because a thinner target is measurably harder to grab.
pub const handle_size = Split.handle_size;
pub const handle_dist = Split.handle_dist;

// A region's extent along its parent's axis is stored under `"_size"`, in points.
//
// Points rather than a fraction of the parent, and per region rather than a table of boundaries,
// because that is what `dvui.box` already understands: a child that does not expand along the
// axis takes its minimum, and the ones that do share the remainder. Reusing that means there is
// no second sizing model — a fixed icon rail, a dragged sidebar and a stretching main area are
// the same mechanism with different numbers, and a window resize grows the stretchy half rather
// than rescaling the sidebar.

/// The user's assignment for the region these keywords belong to, or null when they never
/// chose and the keywords decide.
///
/// Callers hand over keywords, not a region name, because that is what a shape and a pane both
/// have in hand (`f.matching(keywords)`); the region is found in the registry by keyword group —
/// this frame's set first, since a region registers before it draws its contents, then last
/// frame's for anything asked between shapes. Two regions declared with identical keywords share
/// an assignment, exactly as they already share a selection.
fn assignedFor(self: *Layout, keywords: []const []const u8) ?[]const []const u8 {
    const r = self.regionForKeywords(keywords) orelse return null;
    return ViewDrag.previewAssignment(self, r.name) orelse self.state.assignment(r.name);
}

fn assignedStored(self: *Layout, keywords: []const []const u8) ?[]const []const u8 {
    const r = self.regionForKeywords(keywords) orelse return null;
    return self.state.assignment(r.name);
}

fn regionForKeywords(self: *Layout, keywords: []const []const u8) ?Region {
    const want = sdk.keywords.groupKey(keywords);
    for (self.state.regions_building.items) |r| {
        if (sdk.keywords.groupKey(r.keywords) == want) return r;
    }
    for (self.state.regions.items) |r| {
        if (sdk.keywords.groupKey(r.keywords) == want) return r;
    }
    return null;
}

/// Every surface that belongs in the region with `keywords`: the user's assignment when there
/// is one, in the order they chose, otherwise every surface whose keywords intersect, in
/// registration order. Arena-allocated and valid for this frame only; returns an empty slice
/// rather than erroring so a layout can always iterate.
pub fn matching(self: *Layout, keywords: []const []const u8) []const *Surface {
    return self.matchingWith(keywords, self.assignedFor(keywords), false);
}

/// `matching` for a specific region rather than a keyword group. The two differ only for a
/// region that resolves **by name** (`Region.by_name`): a plugin's document panes all accept
/// `main.document`, and finding "the region with these keywords" would hand every pane the
/// first pane's assignment. The app's own regions are unique per keyword group, so for them
/// this is `matching`.
pub fn matchingIn(self: *Layout, r: *const Region) []const *Surface {
    const stored = if (r.by_name) self.state.assignment(r.name) else self.assignedStored(r.keywords);
    const assigned = ViewDrag.previewAssignment(self, r.name) orelse stored;
    // A plugin kind slot (a document pane) only shows what it accepts. Output
    // dropped on the workbench canvas must not become a document tab. A shape
    // place (Main, Panel, a leftover Center) may hold anything the user put there.
    return self.matchingWith(r.keywords, assigned, r.kind_slot);
}

/// `matchingIn` without the view-drag preview overlay. Drop, claim, and
/// `visibleId` have to see the stored assignment, not the landing pose.
pub fn matchingStored(self: *Layout, r: *const Region) []const *Surface {
    const assigned = if (r.by_name) self.state.assignment(r.name) else self.assignedStored(r.keywords);
    return self.matchingWith(r.keywords, assigned, r.kind_slot);
}

fn matchingWith(self: *Layout, keywords: []const []const u8, assigned: ?[]const []const u8, require_fit: bool) []const *Surface {
    var out: std.ArrayListUnmanaged(*Surface) = .empty;
    const a = self.arena;
    if (assigned) |ids| {
        for (ids) |id| {
            const s = self.host.surfaceById(id) orelse continue; // plugin not loaded right now
            if (s.hidden or !self.visibleNow(s)) continue;
            if (require_fit and !sdk.keywords.accepts(keywords, s.keywords)) continue;
            out.append(a, s) catch return out.items;
        }
        return out.items;
    }
    for (self.host.surfaces.items) |*s| {
        if (s.hidden or !self.visibleNow(s)) continue;
        const mine = sdk.keywords.strength(keywords, s.keywords);
        if (mine == .none) continue;
        if (self.claimedElsewhere(keywords, s, mine)) continue;
        out.append(a, s) catch return out.items;
    }
    return out.items;
}

/// Whether a surface exists right now as far as placement is concerned. Always, unless it is a
/// takeover (`Surface.takeover_when`), which exists only while its trigger is what some region
/// shows. Its trigger is looked up with takeovers excluded, so a takeover cannot trigger another
/// and the question always terminates.
fn visibleNow(self: *Layout, s: *const Surface) bool {
    const trigger = s.takeover_when orelse return true;
    for (self.state.regions.items) |r| {
        const items = self.plainMatchingIn(&r);
        const cur = pick(items, self.host.selectionForKey(r.selectionKey())) orelse continue;
        if (std.mem.eql(u8, cur.id, trigger)) return true;
    }
    return false;
}

/// `matchingIn` with takeovers left out — the list a *trigger* is chosen from.
fn plainMatchingIn(self: *Layout, r: *const Region) []const *Surface {
    const assigned = if (r.by_name) self.state.assignment(r.name) else self.assignedFor(r.keywords);
    var out: std.ArrayListUnmanaged(*Surface) = .empty;
    const a = self.arena;
    if (assigned) |ids| {
        for (ids) |id| {
            const s = self.host.surfaceById(id) orelse continue;
            if (s.hidden or s.takeover_when != null) continue;
            if (r.kind_slot and !sdk.keywords.accepts(r.keywords, s.keywords)) continue;
            out.append(a, s) catch return out.items;
        }
        return out.items;
    }
    for (self.host.surfaces.items) |*s| {
        if (s.hidden or s.takeover_when != null) continue;
        const mine = sdk.keywords.strength(r.keywords, s.keywords);
        if (mine == .none) continue;
        if (self.claimedElsewhere(r.keywords, s, mine)) continue;
        out.append(a, s) catch return out.items;
    }
    return out.items;
}

/// Is some other region a *more specific* home for `s` than the region with `keywords`?
///
/// The rule sub-regions need. A surface asking for `main.document` is accepted by the main area
/// too (`Fit.place` — the enclosing region takes a surface whose exact place this shape lacks),
/// so without this it would draw twice: once in the document pane that was made for it and once
/// behind that pane in the main area itself.
///
/// **Only a strictly stronger claim wins.** Two regions that accept a surface equally both show
/// it, which is the existing promise that the same surface in two places is a feature — an icon
/// rail and the pane it chooses for. Breaking such a tie by declaration order would leave the
/// loser mysteriously empty; an ambiguity the user can see is one they can resolve with the picker.
///
/// An assignment is a claim. Output dragged onto Main must leave the panel,
/// even though the panel's keywords still match it exactly. Same-group
/// places (rail and sidebar) share one assignment and are not "elsewhere".
fn claimedElsewhere(
    self: *Layout,
    keywords: []const []const u8,
    s: *const Surface,
    mine: sdk.keywords.Fit,
) bool {
    const want = sdk.keywords.groupKey(keywords);
    // This frame's regions once the shape has started declaring them — a region registers before
    // it draws its contents, so by the time anything asks, every region declared *above* this one
    // is present. Last frame's set fills in for the rest, which is the same trade `assignedFor`
    // and `State.regionFor` make and for the same reason.
    const declared = if (self.state.regions_building.items.len > 0)
        self.state.regions_building.items
    else
        self.state.regions.items;
    for (declared) |r| {
        if (sdk.keywords.groupKey(r.keywords) == want) continue;
        if (self.state.assignment(r.name)) |ids| {
            for (ids) |id| if (std.mem.eql(u8, id, s.id)) return true;
        }
    }
    if (mine == .exact) return false; // nothing outranks the exact word but an assignment
    for (declared) |r| {
        if (sdk.keywords.groupKey(r.keywords) == want) continue;
        if (self.state.assignment(r.name) != null) continue;
        const theirs = sdk.keywords.strength(r.keywords, s.keywords);
        if (@intFromEnum(theirs) > @intFromEnum(mine)) return true;
    }
    return false;
}

/// A surface by id, regardless of keywords — how an app places a plugin it ships with and
/// therefore knows by name (fizzy does this for `workbench.panes`).
pub fn surface(self: *Layout, id: []const u8) ?*Surface {
    return self.host.surfaceById(id);
}

/// Surfaces that appear in no region of the last completed shape — neither assigned to one nor
/// attracted by keywords to an unassigned one. Never silently lost: the settings UI lists these
/// so a user (or the plugin author) can see the gap and fix it.
pub fn unplaced(self: *Layout) []const *Surface {
    var out: std.ArrayListUnmanaged(*Surface) = .empty;
    const a = self.arena;
    outer: for (self.host.surfaces.items) |*s| {
        if (s.hidden) continue;
        if (s.keywords.len == 0) continue; // placed by id, not by keyword
        for (self.state.regions.items) |r| {
            if (self.state.assignment(r.name)) |ids| {
                for (ids) |id| if (std.mem.eql(u8, id, s.id)) continue :outer;
            } else if (sdk.keywords.accepts(r.keywords, s.keywords)) continue :outer;
        }
        out.append(a, s) catch return out.items;
    }
    return out.items;
}

fn currentId(self: *Layout, keywords: []const []const u8) ?[]const u8 {
    return self.host.selectionFor(keywords);
}

/// Which surface is current for this keyword group, or null when nothing matches. Degrades: if
/// the remembered id is gone (plugin unloaded, keywords overridden elsewhere), falls back to the
/// first match rather than drawing nothing.
pub fn selected(self: *Layout, keywords: []const []const u8) ?*Surface {
    return pick(self.matching(keywords), self.currentId(keywords));
}

pub fn isSelected(self: *Layout, keywords: []const []const u8, s: *const Surface) bool {
    const cur = self.selected(keywords) orelse return false;
    return std.mem.eql(u8, cur.id, s.id);
}

pub fn select(self: *Layout, keywords: []const []const u8, s: *const Surface) void {
    self.host.setSelectionFor(keywords, s.id);
}

/// `selected` / `select` for a specific region. A by-name region keeps its own selection —
/// two document panes must not share an active tab — under a key that folds the name into the
/// keyword group's; an app region's key is the keyword group's alone, so a chooser written
/// against keywords (the icon rail) and the region it chooses for still agree.
pub fn selectedIn(self: *Layout, r: *const Region) ?*Surface {
    return pick(self.matchingIn(r), self.host.selectionForKey(r.selectionKey()));
}

pub fn selectedStored(self: *Layout, r: *const Region) ?*Surface {
    return pick(self.matchingStored(r), self.host.selectionForKey(r.selectionKey()));
}

pub fn selectIn(self: *Layout, r: *const Region, id: []const u8) void {
    self.host.setSelectionForKey(r.selectionKey(), id);
}

/// The selection out of `items`: an active takeover if one is among them — it annexes the
/// region for as long as its trigger holds, which is the whole point of it — else the remembered
/// id if it is still there, else the first.
fn pick(items: []const *Surface, current: ?[]const u8) ?*Surface {
    if (items.len == 0) return null;
    for (items) |s| if (s.takeover_when != null) return s;
    if (current) |id| {
        for (items) |s| if (std.mem.eql(u8, s.id, id)) return s;
    }
    return items[0];
}

/// Draw one surface into the current parent, wrapped in the swap cross-fade so every region gets
/// it for free. Keyed by **surface id**, never the parent box id — a box id moves with the
/// surrounding layout and would restart the fade on changes that are not content swaps (see the
/// warning at workbench `src/Workspace.zig:768`).
///
/// While the picker is collecting (`State.snapshots_wanted`), a surface without a snapshot is
/// drawn through a texture target and the result both kept and put on screen — the pixels are
/// the same ones, so nothing blinks, and the surface still ran exactly once.
pub fn draw(self: *Layout, s: *Surface) !dvui.App.Result {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(s.id);
    const rv = core.anim.reveal(
        dvui.Id.extendId(null, @src(), @truncate(hasher.final())),
        hasher.final(),
        .{},
    );
    defer rv.deinit();
    self.drawn.append(self.arena, s) catch {};
    if (self.state.snapshots_wanted and self.state.snapshot(s.id) == null) {
        if (try self.drawCaptured(s)) |r| return r;
    }
    return s.draw(s.ctx);
}

/// `s.draw` into a texture the size of the current parent's content, then that texture onto the
/// screen where the surface would have drawn. Null when there is nothing to capture into — a
/// zero-sized parent, or a backend without render targets — and the caller draws normally.
///
/// Through `dvui.Picture` rather than a bare `renderTarget` switch: dvui defers part of its
/// drawing (strokes after fills, subwindow content) to queues flushed later, and a bare switch
/// hands those to the screen after the target is gone. `Picture` installs its own queues and
/// flushes them inside `stop`, which is the difference between a snapshot of a scroll area and
/// a snapshot of its background.
fn drawCaptured(self: *Layout, s: *Surface) !?dvui.App.Result {
    const rs = dvui.parentGet().data().contentRectScale();
    var pic = dvui.Picture.start(rs.r) orelse return null;
    // Some backends leave a fresh target uninitialised; the cross-fade learned this the hard way.
    pic.texture.clear();
    const old_clip = dvui.clipGet();
    dvui.clipSet(pic.r);
    const result = s.draw(s.ctx);
    dvui.clipSet(old_clip);
    pic.stop();
    const texture = dvui.textureFromTarget(pic.texture) catch return try result;
    dvui.renderTexture(texture, .{ .r = pic.r, .s = rs.s }, .{}) catch {};
    self.state.takeSnapshot(self.gpa, s.id, .{ .texture = texture, .natural = .{ .w = pic.r.w / rs.s, .h = pic.r.h / rs.s } });
    return try result;
}

/// Snapshot every surface that drew nowhere this frame, by drawing each once offscreen at a
/// fixed size. Only while the picker is collecting and only for surfaces still missing a
/// snapshot, so a frame with nothing to do costs a lookup. The application calls this after
/// its shape has run, from the base window.
///
/// "Drew nowhere" is decided by `drawn`, not by the missing snapshot: the picker opens
/// mid-frame, after some regions have already run, and those surfaces must be captured where
/// they live on the *next* frame rather than photographed offscreen now — an offscreen
/// picture of the workspace is a picture of an empty box.
pub fn captureUnplaced(self: *Layout) void {
    if (!self.state.snapshots_wanted) return;
    var pending = false;
    outer: for (self.host.surfaces.items, 0..) |*s, i| {
        if (s.hidden or self.state.snapshot(s.id) != null) continue;
        for (self.drawn.items) |d| if (d == s) {
            pending = true; // drew this frame before the request: in-place capture next frame
            continue :outer;
        };
        var box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = i,
            .rect = .{ .x = -20_000, .y = -20_000, .w = offscreen_capture.w, .h = offscreen_capture.h },
            .background = true,
            .color_fill = .{ .color = dvui.themeGet().color(.content, .fill) },
        });
        defer box.deinit();
        // A subtree drawn for the first time is not yet what it will look like: dvui lays it
        // out from last frame's sizes, which it has none of, and anything inside that reveals
        // itself starts hidden. So it is drawn unphotographed for a few frames first — the same
        // settle-then-show the reveal does on screen, just without an audience.
        const warm = dvui.dataGet(null, box.data().id, "_warm", u8) orelse 0;
        if (warm < offscreen_warmup_frames) {
            _ = s.draw(s.ctx) catch {};
            dvui.dataSet(null, box.data().id, "_warm", warm + 1);
            pending = true;
            continue;
        }
        _ = self.drawCaptured(s) catch null;
    }
    if (pending) dvui.refresh(null, @src(), null);
}

/// Where a surface that is not on screen is drawn to be photographed. A sidebar-ish aspect at
/// a size text is legible in; the card scales it down.
const offscreen_capture: dvui.Size = .{ .w = 360, .h = 480 };
/// Long enough for a 120 ms reveal to finish at 60 fps, with a little to spare.
const offscreen_warmup_frames: u8 = 10;

/// Draw whichever surface is selected for these keywords, into the current parent. Everything
/// it does is reachable through `matching` / `selected` / `draw`; `region` uses it to fill a
/// declared region's space.
pub fn drawSelected(self: *Layout, keywords: []const []const u8) !dvui.App.Result {
    const s = self.selected(keywords) orelse return .ok;
    return self.drawSwapped(sdk.keywords.groupKey(keywords), s);
}

/// `drawSelected` for a specific region. A by-name region must not draw the first assignment
/// that happens to share its keywords — that is how every edge tray showed the same surface.
pub fn drawSelectedIn(self: *Layout, r: *const Region) !dvui.App.Result {
    const s = self.selectedIn(r) orelse return .ok;
    return self.drawSwapped(r.selectionKey(), s);
}

/// Capture the outgoing surface and blur-fade to `s`. Keyed by place, not by
/// surface, so two regions that share a selection still each keep their own
/// overlay (by-name keys include the region name).
fn drawSwapped(self: *Layout, slot: u64, s: *Surface) !dvui.App.Result {
    const rs = dvui.parentGet().data().contentRectScale();
    const tr = self.state.swapFor(self.gpa, slot) orelse return self.draw(s);

    // A swap preview already dissolves the outgoing still. Starting a second
    // `transition` here would arm a new clock, and the drop would fire it —
    // the preview that had just finished would rewind and fade again. Keep
    // the slot in step with what the preview is showing so the landing is
    // already the current key.
    const d = self.state.view_drag;
    if (d.active() and d.preview_t > 0.001 and d.preview_split == null) {
        tr.prev_id = s.id;
        tr.prev_key = std.hash.Wyhash.hash(0, s.id);
        return self.draw(s);
    }

    const Ctx = struct {
        layout: *Layout,
        id: []const u8,

        fn drawPrev(ctx: *anyopaque) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            if (c.layout.host.surfaceById(c.id)) |old| {
                _ = old.draw(old.ctx) catch {};
            }
        }

        fn after(ctx: *anyopaque) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            c.layout.resetInnermostPack();
        }
    };

    var ctx: Ctx = .{ .layout = self, .id = tr.prev_id };
    const had = tr.prev_id.len > 0;
    var frame = core.anim.transition(tr, .{
        .key = std.hash.Wyhash.hash(0, s.id),
        .rect = rs.r,
        .kind = .blur,
        .draw_previous = if (had) Ctx.drawPrev else null,
        .after_capture = if (had) Ctx.after else null,
        .ctx = @ptrCast(&ctx),
    });
    defer frame.deinit();
    tr.prev_id = s.id;
    return self.draw(s);
}

fn resetInnermostPack(self: *Layout) void {
    const box = if (self.depth > 0) self.containers[self.depth - 1].box else null;
    const b = box orelse return;
    b.first_child = true;
    b.packed_children = 0;
    b.total_weight = 0;
    b.min_space_taken = 0;
    if (builtin.mode == .Debug) b.child_id = .zero;
}

// ── The base layer: regions and keywords ────────────────────────────────────────────────────
//
// Everything above is the vocabulary — which surfaces exist, which match, which is selected.
// This is the layer a *layout* is written against: a shape declares regions, and the framework
// owns the mechanism (paned trees, split ratios, persistence, collapse animation, auto-hide).
//
// The test this has to pass is that a shape never writes mechanism: nothing here should be
// something an app author has to know about, and nothing may assume fizzy's own shape.

pub const Region = @import("Region.zig");
/// Runtime subdivision of a place — see `State.splits`.
pub const SplitTree = @import("SplitTree.zig");
/// What a released view-drag does — see `app/layout/SPLITS.md`.
pub const Drop = @import("Drop.zig");
/// Carrying a view from one place to another — the gesture `Drop` decides for.
pub const ViewDrag = @import("ViewDrag.zig");
/// The arrangement a shape starts from — see `Seed.zig`. `Layout.Seed` is the tree union.
pub const Seed = @import("Seed.zig").Tree;
/// Walker `Layout.tree` returns over a seed-backed dockspace.
pub const Tree = @import("Tree.zig");

test {
    _ = @import("SplitTree.zig");
    _ = @import("Seed.zig");
    _ = @import("Region.zig");
    _ = @import("Drop.zig");
    _ = @import("ViewDrag.zig");
}
/// Declare a region — the verb form of `Region.init`, so a shape writes `f.region(...)` beside
/// `f.split(...)` and never names the type. Same arrangement as `dvui.box` over `BoxWidget.init`.
pub const region = Region.init;
/// Divide a named place horizontally or vertically — the picker's Split.
pub const splitNamed = Region.splitNamed;
/// Divide a named place from a specific edge — a view-drag drop onto that side.
pub const splitOn = Region.splitOn;
/// Move the visible surface from one place to another — a view-drag drop.
pub const placeVisible = ViewDrag.place;

/// Walk `seed` as a `dockspace(header = .none)`. First call (and Reset Layout) convert the
/// seed into a live `DockLayout`; after that the persisted tree is what is walked.
pub fn tree(
    self: *Layout,
    src: std.builtin.SourceLocation,
    seed: *const Seed,
    opts: dvui.Options,
) !Tree {
    try self.state.ensureDock(self.gpa, seed);
    const dock = if (self.state.dock) |*d| d else unreachable;
    return .{
        .dock = core.widgets.dockspace(src, .{
            .layout = dock,
            .header = .none,
        }, opts),
        .layout = self,
        .seed = seed,
    };
}

/// Draw a region into an already-open tree leaf: keyword qualification, registry, corner
/// button, contents. Geometry belongs to the tree — there is no box to `deinit`.
pub fn regionIn(self: *Layout, leaf: Tree.Leaf, init_opts: Region.InitOptions) !void {
    const box = leaf.panel.dockspace.content_box orelse return;
    var opts = init_opts;
    if (opts.name.len == 0) opts.name = leaf.name;
    if (opts.keywords.len == 0) opts.keywords = leaf.keywords;
    if (init_opts.name.len == 0) opts.shows = leaf.shows;
    opts.by_name = true;
    opts.forget_when_empty = !leaf.pinned;
    try Region.fillInBox(self, opts, box);
}

// ── Regions a plugin declares ───────────────────────────────────────────────────────────────────
//
// A plugin has no `*Layout` — it is a dylib, it holds a `Host`, and the layout API takes a
// `@src()` and returns a widget. So the three calls it makes through the vtable land here, on the
// live `Layout` the app is running its shape with (`Host.region` → `EditorAPI.beginRegion` →
// `Editor.beginPluginRegion` → this).
//
// The regions themselves are ordinary: same `Region.init`, same registry, same claiming, same
// picker. What is different is only that nobody wrote a `@src()` for them, so the id comes from
// this function's source location plus the caller's `key` — which is why `RegionSpec.key` has to
// be stable and unique among one caller's regions.

pub fn beginPluginRegion(self: *Layout, spec: sdk.RegionSpec) ?sdk.RegionSpec.Token {
    if (self.plugin_depth >= max_nesting) {
        dvui.log.err("plugin regions nest deeper than {d}; \"{s}\" ignored", .{ max_nesting, spec.name });
        return null;
    }
    const r = Region.init(self, @src(), .{
        // A plugin formats its name per frame; everything that holds it holds it across frames.
        .name = self.state.internName(self.gpa, spec.name),
        .keywords = spec.keywords,
        .shows = spec.shows,
        .dir = spec.dir,
        .hide_when_empty = spec.hide_when_empty,
        // The plugin draws its own chrome around the contents, so it says where they go.
        .manual_contents = true,
        .by_name = true,
        .kind_slot = true,
    }, .{
        // Truncated because `id_extra` is a `usize`, which is 32 bits on wasm. A plugin's key is
        // an id or a hash, so the low bits are the ones carrying the distinction.
        .id_extra = @truncate(spec.key),
        .expand = spec.expand,
        .min_size_content = switch (if (self.innermost()) |c| c.dir else .horizontal) {
            .horizontal => .{ .w = spec.min_extent },
            .vertical => .{ .h = spec.min_extent },
        },
    }) catch |err| {
        dvui.logError(@src(), err, "plugin region \"{s}\"", .{spec.name});
        return null;
    };
    // `hide_when_empty` with nothing to show: the region declined to exist, and a caller that
    // gets a token would draw its chrome around nothing.
    if (r.box == null) return null;

    self.plugin_regions[self.plugin_depth] = r;
    self.plugin_depth += 1;
    return @enumFromInt(self.plugin_depth);
}

pub fn drawPluginRegionContents(self: *Layout, token: sdk.RegionSpec.Token) !dvui.App.Result {
    const r = self.pluginRegion(token) orelse return .ok;
    const s = self.selectedIn(r) orelse return .ok;
    return self.draw(s);
}

/// A plugin region's contents and selection, by token — what a plugin's own chooser (a tab
/// strip) is drawn from and writes back to.
pub fn pluginRegionMatching(self: *Layout, token: sdk.RegionSpec.Token) []const *Surface {
    const r = self.pluginRegion(token) orelse return &.{};
    return self.matchingIn(r);
}

pub fn pluginRegionSelected(self: *Layout, token: sdk.RegionSpec.Token) ?*Surface {
    const r = self.pluginRegion(token) orelse return null;
    return self.selectedIn(r);
}

pub fn pluginRegionSelect(self: *Layout, token: sdk.RegionSpec.Token, id: []const u8) void {
    const r = self.pluginRegion(token) orelse return;
    self.selectIn(r, id);
}

pub fn endPluginRegion(self: *Layout, token: sdk.RegionSpec.Token) void {
    // Strictly nested, like the boxes they are. Closing out of order would deinit the wrong box
    // and dvui would report it as a stack mismatch two widgets later, naming neither the plugin
    // nor the region — so say it here while the token still means something.
    const depth = @intFromEnum(token);
    if (depth != self.plugin_depth) {
        dvui.log.err("plugin region closed out of order ({d} of {d} open)", .{ depth, self.plugin_depth });
        return;
    }
    self.plugin_depth -= 1;
    self.plugin_regions[self.plugin_depth].deinit();
}

fn pluginRegion(self: *Layout, token: sdk.RegionSpec.Token) ?*Region {
    const depth = @intFromEnum(token);
    if (depth == 0 or depth > self.plugin_depth) return null;
    return &self.plugin_regions[depth - 1];
}

/// What persists behind a `Layout` between frames — selections, declared regions, sizes.
pub const State = @import("State.zig");

/// A draggable divider between the region before it and the region after it — `dvui.separator`
/// with a drag.
///
/// It takes no direction: a split divides the axis of the region it sits in, so direction is
/// declared once, on the container. Dragging it changes the stored extent of the nearest
/// preceding `resize` region, which is the entire resize model — one number per resizable
/// region, no ratios, no boundary table, and `dvui.box` doing the layout.
/// The options are `Split.Options` itself, never a copy: this once had a second struct with the
/// same three fields, whose defaults drifted — `min` went to zero in one place so a region could
/// be dragged shut and stayed 40 here, which silently won and pinned every split 40pt from its
/// end. Two structs describing one thing will always end up disagreeing about it.
/// Unlike `region`, this stays here rather than moving next to its type: `Split` lives in `core`
/// so a plugin can draw one without a `Layout` at all, and everything this adds — finding the
/// neighbour to resize, and the container constraint to resolve against — is layout state that
/// `core` cannot see.
pub fn split(self: *Layout, src: std.builtin.SourceLocation, opts: Split.Options) void {
    const c = self.innermost() orelse {
        dvui.log.err("split() outside a region does nothing", .{});
        return;
    };
    if (c.pending_split != null) dvui.log.err("two splits with no region between them; the first is dropped", .{});
    c.pending_split = .{ .src = src, .opts = opts };
}

/// Draw the split waiting in the innermost container, now that `after` — the region it divides
/// from the one before — is about to open. Called by `Region.init` for every region that exists.
pub fn drawPendingSplit(self: *Layout, after: ?dvui.Id) void {
    const c = self.innermost() orelse return;
    const pending = c.pending_split orelse return;
    c.pending_split = null;
    const axis = c.dir;
    if (!pending.opts.resize) {
        c.handles += Split.handle_size;
        var unused = Split.init(pending.src, axis, pending.opts.id_extra, null);
        unused.deinit();
        return;
    }

    // Which neighbour this split resizes. The one *before* it when there is one (the sidebar);
    // otherwise the one after, which is the bottom panel's shape and is known now because the
    // split is drawn as that region opens.
    var sign: f32 = 1;
    const target = c.last_resizable orelse blk: {
        sign = -1;
        break :blk after orelse return;
    };

    packSplit(self, pending.src, pending.opts.id_extra, target, sign, pending.opts);
}

/// A `handle_size` child between two regions. The gap is this widget, so a
/// region's Options.margin is never a sash, and a card cannot paint over it.
pub fn packSplit(
    self: *Layout,
    src: std.builtin.SourceLocation,
    id_extra: usize,
    target: dvui.Id,
    sign: f32,
    opts: Split.Options,
) void {
    packSplitSized(self, src, id_extra, target, sign, opts, Split.handle_size);
}

/// `packSplit` with the gap given a width, for a sash closing along with the place beside it.
pub fn packSplitSized(
    self: *Layout,
    src: std.builtin.SourceLocation,
    id_extra: usize,
    target: dvui.Id,
    sign: f32,
    opts: Split.Options,
    thickness: f32,
) void {
    const c = self.innermost() orelse return;
    const container = c.box orelse return;
    c.handles += thickness;
    var divider = Split.initSized(src, c.dir, id_extra, null, thickness);
    defer divider.deinit();
    divider.drag(container, target, sign, opts, .{
        .extent = c.extent(c.dir),
        .base_min = c.base_min,
        .handles = c.handles,
        .others = c.resizables.items,
        .sign = sign,
    });
}

/// A **tab strip**: the chooser half of a tabbed region.
///
/// This is the piece that makes the two forms of region explicit in a layout:
///
/// ```zig
/// // "this region IS x" — one surface fills it, no chooser at all. An app that just wants a
/// // terminal at the bottom writes only this.
/// try f.drawSelected(bottom);
///
/// // "this region is TABBED, and the tabs correspond to x"
/// f.tabs(bottom);            // the tabs
/// try f.drawSelected(bottom);  // ...and the active one
/// ```
///
/// Nothing here is privileged: it lists `f.matching`, reads `f.isSelected` and writes
/// `f.select`, so an app that wants a different-looking chooser — a dropdown, a segmented
/// control, a radial menu — writes its own loop and calls the same three functions. The rail
/// (the icon rail) is the same idea drawn as icons, and it sits in a *different place* from its
/// body, which is exactly why these are two widgets rather than one region mode.
///
/// **No in-tree caller yet, deliberately.** Fizzy's own bottom panel uses the richer `Panel`
/// path (which draws its own strip *and* supports splitting the bottom into several panes), and
/// `studio.zig` demonstrates the single-surface form. This is the plain tabbed form in between,
/// and it exists as consumer API rather than as fizzy's own code — the first shape that wants
/// tabs without splits uses it as-is instead of copying `Panel`.
pub fn tabs(f: *Layout, keywords: []const []const u8) void {
    const place: Region = .{ .keywords = keywords };
    tabsIn(f, &place);
}

/// Tab strip for one place. `tabs` is this keyed by keywords; a by-name
/// place (a minted split leaf) must not share another place's selection.
pub fn tabsIn(f: *Layout, r: *const Region) void {
    const surfaces = f.matchingIn(r);
    if (surfaces.len <= 1) return;

    var strip: core.widgets.Tabs = .init(@src(), &tab_info, .{ .drag_name = "fizzy_tab_strip" });
    defer strip.deinit();

    for (surfaces, 0..) |s, i| {
        const cur = f.selectedIn(r);
        const is_selected = if (cur) |sel| std.mem.eql(u8, sel.id, s.id) else false;
        var t = strip.tab(@src(), i, is_selected);
        defer t.deinit();

        var title_buf: [64]u8 = undefined;
        const title_upper = if (s.title.len <= title_buf.len)
            std.ascii.upperString(&title_buf, s.title)
        else
            s.title;

        dvui.label(@src(), "{s}", .{title_upper}, .{
            .color_text = .{ .color = if (is_selected)
                dvui.themeGet().color(.highlight, .fill)
            else
                dvui.themeGet().color(.control, .text) },
            .font = dvui.Font.theme(.heading),
            .padding = dvui.Rect.all(4),
            .gravity_y = 0.5,
        });

        if (t.clicked()) f.selectIn(r, s.id);
    }

    strip.finalSlot(surfaces.len);
}

/// The plain tabbed region: a strip of tabs, then the selected surface beneath it. The
/// `content` function form of the two-line recipe `tabs` documents above — pass it as
/// `.content = Layout.tabbed` and the region is tabbed.
///
/// the icon rail deliberately has no counterpart here. It is a chooser that sits *beside* the
/// region it chooses for rather than above it (see `src/editor/layout.zig`), so it is not a region's content
/// and wrapping it as one would only lose the action it returns.
pub fn tabbed(_: ?*anyopaque, f: *Layout, keywords: []const []const u8) !dvui.App.Result {
    f.tabs(keywords);
    return f.drawSelected(keywords);
}

/// Drag state for `tabStrip`. One strip per app in practice; a layout wanting two independent
/// strips copies this recipe (see CLAUDE.md's shipped-shapes note) rather than fizzy growing a
/// handle type for a case nothing has yet.
var tab_info: core.widgets.Tabs.TabInfo = .{};
