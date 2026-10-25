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
//! build module and break `core` as a dependency outright (AGENTS.md).
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
/// What the device is, read from `core.platform` when the frame's layout is made: a shape reads
/// this to choose its arrangement (mobile's single place, a desktop's rail and splits).
form_factor: core.platform.FormFactor = .desktop,
/// The card a place wears when it asks for one (`Region.InitOptions.card`): its fill, corners and
/// padding. Set by the shape before it declares its places, and worn by the floats' places too,
/// which are drawn after the shape — so a view, and the places a split makes, look the same in a
/// float as in the window. Null, no card.
card: ?dvui.Options = null,
/// Set when a region's remembered extent changed this frame. The application decides what that
/// means — fizzy debounces a write to `layout.zon`.
extents_changed: bool = false,
/// Every surface `draw` ran this frame, so `captureUnplaced` knows which ones genuinely drew
/// nowhere — as opposed to drew before the picker asked. Arena-backed, per frame.
drawn: std.ArrayList(*Surface) = .empty,
/// Views a plugin asked to put away during this frame (`hideLater`), put away once it has drawn
/// (`applyHides`). Arena-backed, per frame.
hides: std.ArrayList([]const u8) = .empty,
/// Surfaces drawn this frame in a place with no room, so not captured (`drawCaptured`): no frame
/// is asked for them until they have some. Arena-backed, per frame.
unsized: std.ArrayList(*Surface) = .empty,

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

pub const PendingSplit = struct { src: std.lang.SourceLocation, opts: Split.Options };

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
    resizables: std.ArrayList(dvui.Id) = .empty,
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
    /// The card this region handed to the panes its view opens in it (`Region.InitOptions.pane_cards`):
    /// what each of them wears. Null when it wears its own card, or has none.
    card: ?dvui.Options = null,
    /// The panes (`beginPluginRegion`) opened directly in this region so far this frame.
    panes: u8 = 0,
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

/// A frame's layout. Made at the top of the frame, before any place draws. A view being carried
/// asks for its cursor at `.drag`, above the caret of the text under the pointer, a tab's hand or
/// a split's arrow.
pub fn init(host: *sdk.Host, state: *State, gpa: std.mem.Allocator, arena: std.mem.Allocator) Layout {
    if (state.view_drag.active()) dvui.cursorSetPriority(ViewDrag.cursor, .drag);
    return .{ .host = host, .state = state, .gpa = gpa, .arena = arena, .form_factor = core.platform.formFactor() };
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
    const name = if (self.regionForKeywords(keywords)) |r| r.name else "";
    return self.matchingWith(keywords, self.assignedFor(keywords), false, name);
}

/// `matching` for a specific region rather than a keyword group. The two differ only for a
/// region that resolves **by name** (`Region.by_name`): a plugin's document panes all accept
/// `main.document`, and finding "the region with these keywords" would hand every pane the
/// first pane's assignment. The app's own regions are unique per keyword group, so for them
/// this is `matching`.
pub fn matchingIn(self: *Layout, r: *const Region) []const *Surface {
    const assigned = if (r.by_name) self.state.assignment(r.name) else self.assignedFor(r.keywords);
    // A plugin kind slot (a document pane) only shows what it accepts. Output
    // dropped on the workbench canvas must not become a document tab. A shape
    // place (Main, Panel, a leftover Center) may hold anything the user put there.
    return self.matchingWith(r.keywords, assigned, r.kind_slot, self.orderName(r));
}

/// The name a place's order is kept under: its own, or for an unnamed keyword place (`tabs`),
/// the declared region with its keywords.
fn orderName(self: *Layout, r: *const Region) []const u8 {
    if (r.name.len > 0) return r.name;
    return if (self.regionForKeywords(r.keywords)) |d| d.name else "";
}

/// `items` with the views `State.order` names for `name` first, in that order, and the rest
/// after in the order they came. An order never adds or drops a view — which views a place
/// holds is its assignment's or its keywords' business.
///
/// A place keeps its order: the first time it shows a view its order does not name, the view is
/// written down at the end. So a view keeps its slot through its plugin's reload, update or
/// reinstall (which register it again, last), and across machines; an order is never shortened,
/// so a plugin that is away (disabled, reloading) comes back where it was.
fn ordered(self: *Layout, name: []const u8, items: []*Surface) []*Surface {
    if (name.len == 0) return items;
    self.remember(name, items);
    const order = self.state.order(name) orelse return items;
    const out = self.arena.alloc(*Surface, items.len) catch return items;
    var n: usize = 0;
    for (order) |id| {
        for (items) |s| if (std.mem.eql(u8, s.id, id)) {
            out[n] = s;
            n += 1;
            break;
        };
    }
    for (items) |s| {
        const named = for (order) |id| {
            if (std.mem.eql(u8, s.id, id)) break true;
        } else false;
        if (named) continue;
        out[n] = s;
        n += 1;
    }
    return out[0..n];
}

/// Write down any of `items` that `name`'s order does not name yet, after the ones it does.
fn remember(self: *Layout, name: []const u8, items: []const *Surface) void {
    const known = self.state.order(name) orelse &.{};
    var missing: usize = 0;
    for (items) |s| missing += @intFromBool(!containsId(known, s.id));
    if (missing == 0) return;
    const ids = self.arena.alloc([]const u8, known.len + missing) catch return;
    @memcpy(ids[0..known.len], known);
    var n = known.len;
    for (items) |s| if (!containsId(known, s.id)) {
        ids[n] = s.id;
        n += 1;
    };
    self.state.setOrder(self.gpa, name, ids) catch return;
    self.state.markDirty();
}

fn containsId(ids: []const []const u8, id: []const u8) bool {
    for (ids) |x| if (std.mem.eql(u8, x, id)) return true;
    return false;
}

fn matchingWith(self: *Layout, keywords: []const []const u8, assigned: ?[]const []const u8, require_fit: bool, order_name: []const u8) []const *Surface {
    var out: std.ArrayList(*Surface) = .empty;
    const a = self.arena;
    if (assigned) |ids| {
        for (ids) |id| {
            const s = self.host.surfaceById(id) orelse continue; // plugin not loaded right now
            if (s.hidden or !self.visibleNow(s)) continue;
            if (require_fit and !sdk.keywords.accepts(keywords, s.keywords)) continue;
            // Already assigned somewhere plain (a layout saved before this rule) or not, a tab's
            // content is not a place's: the slot made for it has it.
            if (!require_fit and self.slotted(s)) continue;
            out.append(a, s) catch return out.items;
        }
        return out.items;
    }
    for (self.host.surfaces.items) |*s| {
        if (s.hidden or !self.visibleNow(s)) continue;
        const mine = sdk.keywords.strength(keywords, s.keywords);
        if (mine == .none) continue;
        if (!require_fit and self.slotted(s)) continue;
        if (self.claimedElsewhere(keywords, s, mine)) continue;
        out.append(a, s) catch return out.items;
    }
    // Keywords chose these, in registration order; the user may have dragged them into another.
    return self.ordered(order_name, out.items);
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
    var out: std.ArrayList(*Surface) = .empty;
    const a = self.arena;
    if (assigned) |ids| {
        for (ids) |id| {
            const s = self.host.surfaceById(id) orelse continue;
            if (s.hidden or s.takeover_when != null) continue;
            if (!self.offers(r, s)) continue;
            out.append(a, s) catch return out.items;
        }
        return out.items;
    }
    for (self.host.surfaces.items) |*s| {
        if (s.hidden or s.takeover_when != null) continue;
        const mine = sdk.keywords.strength(r.keywords, s.keywords);
        if (mine == .none) continue;
        if (!r.kind_slot and self.slotted(s)) continue;
        if (self.claimedElsewhere(r.keywords, s, mine)) continue;
        out.append(a, s) catch return out.items;
    }
    return out.items;
}

/// Whether a plugin has declared a place made for `s` — a region of its own (`host.region`) that
/// accepts `s`'s kind. An open document is the case: the Workspace's panes accept `document`, and
/// that is where a document lives, as a tab.
///
/// **Tab content is not a place's content.** A document drawn straight into Main or the sidebar
/// would have no tab, no split, and no way for Save or Undo to find it — they act on the active
/// document, and only a pane has one. So a plain place (Main, the sidebar, the panel, a split
/// leaf) neither matches such a surface by keyword, nor shows it by assignment, nor takes it in a
/// drop, and its picker does not offer it. An app with no such slot (one not using the Workspace)
/// is unaffected: nothing is slotted, and every surface can go anywhere as before.
pub fn slotted(self: *Layout, s: *const Surface) bool {
    if (s.keywords.len == 0) return false;
    var it = self.declaredRegions();
    while (it.next()) |r| {
        if (r.kind_slot and sdk.keywords.accepts(r.keywords, s.keywords)) return true;
    }
    return false;
}

/// Whether region `r` may show `s` at all. A plugin's slot takes only its kind; a plain place
/// takes anything no slot was made for (`slotted`). The one rule matching, dropping and the
/// picker share.
pub fn offers(self: *Layout, r: *const Region, s: *const Surface) bool {
    if (r.kind_slot) return s.keywords.len > 0 and sdk.keywords.accepts(r.keywords, s.keywords);
    return !self.slotted(s);
}

/// Is `s` at home in some region other than the one with `keywords`?
///
/// **A surface is drawn in one place.** It has one `ctx` and one set of state behind it — a
/// tree's selection, a scroll position, what has focus, the keys it answers — so two copies in
/// one frame would be two widgets fighting over the same state. Where it lives, in order:
///
///   1. Where it is assigned. An assignment is a claim: Files dragged onto Main leaves the
///      sidebar, though the sidebar's keywords still match it exactly. Only where the region
///      could show it, though (`offers`): a document listed in a plain place claims nothing.
///   2. Otherwise the region that accepts it most specifically. A surface asking for
///      `main.document` is accepted by the main area too (`Fit.place`, so a plugin written for a
///      nested shape still appears in a flat one), but not while a document pane exists to take it.
///   3. Between equally good regions, the one the shape declares first. Deterministic, and never
///      a loss: the surface is on screen in that region, and the picker moves it anywhere else.
///
/// Regions with the same keywords are one place, not two, and share one list and one selection:
/// an icon rail and the body it chooses for, which list the same surfaces and draw one.
fn claimedElsewhere(
    self: *Layout,
    keywords: []const []const u8,
    s: *const Surface,
    mine: sdk.keywords.Fit,
) bool {
    const want = sdk.keywords.groupKey(keywords);
    // A plain place's assignment claims nothing a slot was made for (`slotted`): it cannot show
    // it, and a stale entry there — a layout saved before that rule — would otherwise take a
    // document away from its pane and leave it drawn nowhere.
    const plain_cannot = self.slotted(s);
    var it = self.declaredRegions();
    while (it.next()) |r| {
        if (sdk.keywords.groupKey(r.keywords) == want) continue;
        if (plain_cannot and !r.kind_slot) continue;
        if (self.state.assignment(r.name)) |ids| {
            for (ids) |id| if (std.mem.eql(u8, id, s.id)) return true;
        }
    }
    // Where this place falls in the shape's order, for rule 3. A place not declared (a chooser
    // asking by keywords with no region of its own) breaks no ties.
    const mine_at: ?usize = blk: {
        var at = self.declaredRegions();
        while (at.next()) |r| {
            if (sdk.keywords.groupKey(r.keywords) == want) break :blk at.index - 1;
        }
        break :blk null;
    };
    it = self.declaredRegions();
    while (it.next()) |r| {
        const i = it.index - 1;
        if (sdk.keywords.groupKey(r.keywords) == want) continue;
        if (self.state.assignment(r.name) != null) continue;
        const theirs = sdk.keywords.strength(r.keywords, s.keywords);
        if (@backingInt(theirs) > @backingInt(mine)) return true;
        if (theirs == mine and mine_at != null and i < mine_at.?) return true;
    }
    return false;
}

/// Every region of the shape, in the order it declares them: this frame's so far, then last
/// frame's that this frame has not reached yet.
///
/// Both halves, not whichever is non-empty. A region is registered before it draws, so while the
/// sidebar draws, the regions declared after it — Main among them — exist only in last frame's
/// set. Reading this frame's alone missed every claim made further down the shape: Files
/// dragged from the sidebar onto Main went on drawing in the sidebar too, until something else
/// was picked there.
fn declaredRegions(self: *Layout) DeclaredRegions {
    return .{ .building = self.state.regions_building.items, .last = self.state.regions.items };
}

const DeclaredRegions = struct {
    building: []const Region,
    last: []const Region,
    /// How many regions `next` has returned.
    index: usize = 0,
    b: usize = 0,
    l: usize = 0,

    fn next(self: *DeclaredRegions) ?*const Region {
        if (self.b < self.building.len) {
            self.b += 1;
            self.index += 1;
            return &self.building[self.b - 1];
        }
        while (self.l < self.last.len) {
            const r = &self.last[self.l];
            self.l += 1;
            if (self.redeclared(r)) continue;
            self.index += 1;
            return r;
        }
        return null;
    }

    /// `r`, from last frame, already declared again this frame.
    fn redeclared(self: *const DeclaredRegions, r: *const Region) bool {
        for (self.building) |*b| {
            if (r.id != .zero and b.id == r.id) return true;
            if (std.mem.eql(u8, r.name, b.name) and
                sdk.keywords.groupKey(r.keywords) == sdk.keywords.groupKey(b.keywords)) return true;
        }
        return false;
    }
};

/// A surface by id, regardless of keywords — how an app places a plugin it ships with and
/// therefore knows by name (fizzy does this for `workbench.panes`).
pub fn surface(self: *Layout, id: []const u8) ?*Surface {
    return self.host.surfaceById(id);
}

/// Bring `id` into sight wherever it lives: select it in the one region that shows it (the rule
/// `claimedElsewhere` states: its assignment, else the place that accepts it best), and open that
/// region if the user shut it or a narrow window folded it away. False when no region shows it:
/// the shape has no place for it, or it is hidden.
///
/// What a plugin's "Show X" command asks for (`Host.revealSurface`): it names the view, never the
/// place, so it lands wherever the user moved the view, in any shape.
pub fn reveal(self: *Layout, id: []const u8) bool {
    const s = self.surface(id) orelse return false;
    if (s.hidden) return false;
    var it = self.declaredRegions();
    while (it.next()) |r| {
        for (self.matchingIn(r)) |m| if (m == s) {
            self.selectIn(r, id);
            if (r.isClosed() or r.isFolded()) r.open();
            return true;
        };
    }
    return false;
}

/// What putting a view away does (`hide`).
pub const Hide = union(enum) {
    /// Shut this tray, which shows the view.
    tray: Region,
    /// Close this float, the view's only place.
    float: []const u8,
};

/// What `hide` would do for `id`, from the one region that shows it (as `reveal` finds it). A
/// tray: a place the shape declared `resize` (not one a split made, which is `forget_when_empty`),
/// in the main window, open and not folded, with `id` the view it shows. A float: one not closing,
/// with `id` its only view. Null for anything else — Main, a split's half, a plugin's pane, a view
/// behind another or out of sight, a float with other views — and `hide` then changes nothing.
pub fn hideTarget(self: *Layout, id: []const u8) ?Hide {
    const s = self.surface(id) orelse return null;
    if (s.hidden) return null;
    var it = self.declaredRegions();
    const r = find: while (it.next()) |place| {
        for (self.matchingIn(place)) |m| if (m == s) break :find place;
    } else return null;
    if (r.layer > 0) {
        const name = self.state.floatRoot(r.name) orelse return null;
        const i = self.state.floats.find(name) orelse return null;
        if (self.state.floats.items.items[i].closing) return null;
        var views: usize = 0;
        for (self.state.splits.leavesUnder(self.arena, name)) |leaf| {
            if (self.state.assignment(leaf)) |ids| views += ids.len;
        }
        return if (views == 1) .{ .float = name } else null;
    }
    if (!r.resize or r.forget_when_empty or r.isClosed() or r.isFolded()) return null;
    const shown = self.selectedIn(r) orelse return null;
    return if (shown == s) .{ .tray = r.* } else null;
}

/// Put `id` away now, as the user would (`Host.hideSurface`): shut its tray as the tray's own
/// close does, or close its float as the float's close button does, the view going home. False,
/// changing nothing, where `hideTarget` finds nothing to do. Not while the shape or the floats
/// draw, which walk what this changes: `hideLater` is for then.
pub fn hide(self: *Layout, id: []const u8) bool {
    switch (self.hideTarget(id) orelse return false) {
        .tray => |r| r.close(),
        .float => |name| self.closeFloat(name),
    }
    return true;
}

/// `hide` asked during the frame: answered now, by the same `hideTarget`, and done by
/// `applyHides` once the shape, the floats and the picker have drawn. A `reveal` asked later in
/// the same frame acts at once, so it comes first: a caller toggling a view makes one call a frame.
pub fn hideLater(self: *Layout, id: []const u8) bool {
    if (self.hideTarget(id) == null) return false;
    const kept = self.arena.dupe(u8, id) catch return false;
    self.hides.append(self.arena, kept) catch return false;
    return true;
}

/// Do the hides asked during this frame (`hideLater`), in order, each asking `hideTarget` again.
/// The application calls this once its frame has drawn. True when any of them acted.
pub fn applyHides(self: *Layout) bool {
    var any = false;
    for (self.hides.items) |id| any = self.hide(id) or any;
    self.hides.clearRetainingCapacity();
    return any;
}

/// Surfaces that appear in no region of the last completed shape — neither assigned to one nor
/// attracted by keywords to an unassigned one. Never silently lost: the settings UI lists these
/// so a user (or the plugin author) can see the gap and fix it.
pub fn unplaced(self: *Layout) []const *Surface {
    var out: std.ArrayList(*Surface) = .empty;
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
/// the same ones, so nothing blinks, and the surface still ran exactly once. Not once capture has
/// failed for it, or here at all (`State.captureFailed`, `State.capture_unavailable`).
pub fn draw(self: *Layout, s: *Surface) !dvui.App.Result {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(s.id);
    const rv = core.anim.reveal(
        dvui.Id.extendId(null, @src(), @truncate(hasher.final())),
        hasher.final(),
        .{},
    );
    defer rv.deinit();
    return self.drawSolid(s);
}

/// `draw` without the fade-in: for a swap, whose overlay already carries the change.
fn drawSolid(self: *Layout, s: *Surface) !dvui.App.Result {
    self.drawn.append(self.arena, s) catch {};
    const watching = ScrollWatch.enabled and !s.scrolls_itself;
    var watch: ScrollWatch = undefined;
    if (watching) watch.begin();
    defer if (watching) watch.end(self.state, s.id);
    if (self.state.snapshots_wanted and !self.state.capture_unavailable and self.state.snapshot(s.id) == null and !self.state.captureFailed(s.id)) {
        if (try self.drawCaptured(s)) |r| return r;
    }
    return surfaceDraw(s);
}

/// `s.draw` into a texture the size of the current parent's content, then that texture onto the
/// screen where the surface would have drawn. Null when there is nothing to capture into — a
/// zero-sized parent, or a backend without render targets — and the caller draws normally. A
/// failure is remembered for the picker's session (`State.recordCaptureFailed`), so it is not
/// tried every frame.
///
/// Through `dvui.Picture` rather than a bare `renderTarget` switch: dvui defers part of its
/// drawing (strokes after fills, subwindow content) to queues flushed later, and a bare switch
/// hands those to the screen after the target is gone. `Picture` installs its own queues and
/// flushes them inside `stop`, which is the difference between a snapshot of a scroll area and
/// a snapshot of its background.
fn drawCaptured(self: *Layout, s: *Surface) !?dvui.App.Result {
    const prof = core.profile.begin("fizzy", "picker: capture");
    defer prof.end();
    const rs = dvui.parentGet().data().contentRectScale();
    if (rs.r.empty()) {
        self.unsized.append(self.arena, s) catch {};
        return null;
    }
    var pic = dvui.Picture.start(rs.r) orelse {
        self.state.recordCaptureFailed(self.gpa, s.id);
        return null;
    };
    // Some backends leave a fresh target uninitialised; the cross-fade learned this the hard way.
    pic.texture.clear();
    const old_clip = dvui.clipGet();
    dvui.clipSet(pic.r);
    const result = surfaceDraw(s);
    dvui.clipSet(old_clip);
    pic.stop();
    const texture = dvui.textureFromTarget(pic.texture) catch {
        self.state.recordCaptureFailed(self.gpa, s.id);
        return try result;
    };
    dvui.renderTexture(texture, .{ .r = pic.r, .s = rs.s }, .{}) catch {};
    self.state.takeSnapshot(self.gpa, s.id, .{ .texture = texture, .natural = .{ .w = pic.r.w / rs.s, .h = pic.r.h / rs.s } });
    return try result;
}

/// What a view drag draws over every place at once: each place's drop and the pane across the
/// two halves of a split a drop would join (`ViewDrag.drawOverlay`) — over the card riding the
/// pointer too. It spans places, so no one place can draw it; the application calls this after
/// its shape has run, from the base window.
pub fn drawDragOverlay(self: *Layout) void {
    ViewDrag.drawOverlay(self);
}

/// The views floating over the window (`Floats`), each a glass window holding its place. The
/// application calls this after its shape has run and before it publishes the shape's regions,
/// from the base window — so a float's places are this frame's, like the shape's — and before
/// `drawDragOverlay`, which goes over them.
pub fn drawFloats(self: *Layout) void {
    Floats.draw(self);
}

/// Close float `name`, every view in it going back to the place it floated out of — the picker's
/// Remove, as the float's own close button does. Re-docking needs nothing of this: a view dragged
/// out of a float by its corner button lands like any other, and the float shuts behind it.
pub fn closeFloat(self: *Layout, name: []const u8) void {
    Floats.close(self, name, .home);
}

/// Draw the view the picker chose for a picture (`State.offscreen`, picked from the cards it
/// shows) offscreen at a fixed size, one draw a frame: a few frames of warm-up, then its capture.
/// Only while the picker is collecting, so a frame with nothing to do costs a check. The
/// application calls this after its shape has run and before the picker draws, from the base
/// window: what the view opens (a popup, a float) stacks under the picker, and a picture taken
/// here shows on its card the same frame.
///
/// Only a view that drew nowhere this frame (`drawn`) is drawn here: one on screen is captured
/// where it lives (`draw`), and an offscreen picture of the workspace is a picture of an empty box.
///
/// Offscreen, a view costs what it draws: its first draw lays out a whole subtree from nothing,
/// and its capture is the one draw that renders any of it (the warm-up draws are clipped away).
/// The picker opening used to pay both for every view, each in one frame. One at a time, a view
/// scrolled or filtered out of the list is never drawn for it, and a card waiting for its picture
/// shows an empty tile.
pub fn captureUnplaced(self: *Layout) void {
    const state = self.state;
    if (!state.snapshots_wanted or state.capture_unavailable) return;
    const prof = core.profile.begin("fizzy", "picker: capture unplaced");
    defer prof.end();
    // A view on screen without its picture (it drew before the picker opened, this frame) is
    // captured where it lives on the next. Not one whose capture failed, or that has no room.
    var pending = false;
    for (self.drawn.items) |d| {
        if (state.snapshot(d.id) != null or state.captureFailed(d.id)) continue;
        for (self.unsized.items) |u| {
            if (u == d) break;
        } else pending = true;
    }

    if (state.offscreen) |*o| step: {
        const surfaces = self.host.surfaces.items;
        // Where the picker found it, unless the registry changed since: then wherever it is now.
        if (o.index >= surfaces.len or std.hash.Wyhash.hash(0, surfaces[o.index].id) != o.id) {
            o.index = for (surfaces, 0..) |c, i| {
                if (std.hash.Wyhash.hash(0, c.id) == o.id) break i;
            } else {
                state.offscreen = null;
                break :step;
            };
        }
        const s = &surfaces[o.index];
        // Its card left the list before it got far (filtered out, scrolled away): the list drew
        // since without it. Dropped, to be chosen again if the card comes back; further in, it is
        // finished.
        const out_of_view = o.card_ns < state.picker.list_ns and o.warm < offscreen_warmup_frames / 2;
        if (out_of_view or !self.mayDrawOffscreen(s)) {
            state.offscreen = null;
            break :step;
        }
        var box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = @truncate(o.id),
            .rect = .{ .x = -20_000, .y = -20_000, .w = offscreen_capture.w, .h = offscreen_capture.h },
            .background = true,
            .color_fill = .{ .color = dvui.themeGet().color(.content, .fill) },
        });
        defer box.deinit();
        // A subtree drawn for the first time is not yet what it will look like: dvui lays it
        // out from last frame's sizes, which it has none of, and anything inside that reveals
        // itself starts hidden. So it is drawn unphotographed for a few frames first — the same
        // settle-then-show the reveal does on screen, just without an audience: a few frames, and
        // the reveal's whole fade, however fast the frames come.
        const now = dvui.frameTimeNS();
        if (o.warm == 0) o.since_ns = now;
        if (o.warm < offscreen_warmup_frames or now - o.since_ns < offscreenWarmupNs()) {
            _ = surfaceDraw(s) catch {};
            o.warm +|= 1;
            pending = true;
            break :step;
        }
        // Taken or failed (`drawCaptured` remembers which), it is done: the picker, drawing next,
        // shows the picture and chooses the next view.
        const started = if (self.drawCaptured(s)) |r| r != null else |_| true;
        state.noteOffscreenStart(started);
        state.offscreen = null;
    }
    if (pending) dvui.refresh(null, @src(), null);
}

/// Where a surface that is not on screen is drawn to be photographed. A sidebar-ish aspect at
/// a size text is legible in; the card scales it down.
const offscreen_capture: dvui.Size = .{ .w = 360, .h = 480 };
/// Long enough for a 120 ms reveal to finish at 60 fps, with a little to spare.
const offscreen_warmup_frames: u8 = 10;

/// Whether surface `s` may be drawn offscreen for its picture (`captureUnplaced`, chosen by
/// `Picker.draw`): capture works here, it has no picture and no failed capture, it is not hidden,
/// and it drew nowhere this frame — one on screen is captured where it lives, never drawn twice.
pub fn mayDrawOffscreen(self: *const Layout, s: *const Surface) bool {
    const state = self.state;
    if (state.capture_unavailable or s.hidden) return false;
    if (state.snapshot(s.id) != null or state.captureFailed(s.id)) return false;
    for (self.drawn.items) |d| if (d == s) return false;
    return true;
}

/// How long the warm-up lasts at the least: a reveal's fade (`core.anim.reveal`) at the
/// interface's speed (`core.motion`), so a picture is never taken mid-fade on a fast display.
fn offscreenWarmupNs() i128 {
    return @as(i128, core.motion.duration((core.anim.RevealOptions{}).duration_micros)) * std.time.ns_per_us;
}

/// Draw whichever surface is selected for these keywords, into the current parent. Everything
/// it does is reachable through `matching` / `selected` / `draw`; `region` uses it to fill a
/// declared region's space.
pub fn drawSelected(self: *Layout, keywords: []const []const u8) !dvui.App.Result {
    const s = self.selected(keywords) orelse return .ok;
    return self.drawSwapped(sdk.keywords.groupKey(keywords), s, null, .none);
}

/// `drawSelected` for a specific region. A by-name region must not draw the first assignment
/// that happens to share its keywords — that is how every edge tray showed the same surface.
pub fn drawSelectedIn(self: *Layout, r: *const Region) !dvui.App.Result {
    const s = self.selectedIn(r) orelse return .ok;
    return self.drawSwapped(r.selectionKey(), s, null, .none);
}

/// `s` into `box`, blurring from whatever `slot` showed before — the swap every region gets,
/// for a place that draws its own chooser (the explorer's body, a bottom-panel pane). `slot`
/// is any key stable for the place; `box` is the parent `s` draws into, whose packing is reset
/// after the outgoing view is photographed into it. `bleed` names the edges the blur feathers
/// past into what is around the place (`core.anim.TransitionOptions.bleed`).
pub fn drawSwappedIn(self: *Layout, slot: u64, box: *dvui.BoxWidget, s: *Surface, bleed: core.anim.Bleed) !dvui.App.Result {
    return self.drawSwapped(slot, s, box, bleed);
}

/// Capture the outgoing surface and blur-fade to `s`. Keyed by place, not by
/// surface, so two regions that share a selection still each keep their own
/// overlay (by-name keys include the region name). `pack` is the box to reset after the capture;
/// null is the innermost region's.
fn drawSwapped(self: *Layout, slot: u64, s: *Surface, pack: ?*dvui.BoxWidget, bleed: core.anim.Bleed) !dvui.App.Result {
    // The part on screen: a place inside a scroll area is as tall as its content.
    const rs = dvui.parentGet().data().contentRectScale().r.intersect(dvui.clipGet());
    const tr = self.state.swapFor(self.gpa, slot) orelse return self.draw(s);

    const Ctx = struct {
        layout: *Layout,
        id: []const u8,
        pack: ?*dvui.BoxWidget,

        fn drawPrev(ctx: *anyopaque) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            if (c.layout.host.surfaceById(c.id)) |old| {
                _ = surfaceDraw(old) catch {};
            }
        }

        fn after(ctx: *anyopaque) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            if (c.pack) |b| resetPack(b) else c.layout.resetInnermostPack();
        }
    };

    var ctx: Ctx = .{ .layout = self, .id = tr.prev_id, .pack = pack };
    const had = tr.prev_id.len > 0;
    // Nothing to swap from — the first thing this place shows: fade it in instead.
    if (!had) {
        tr.prev_id = s.id;
        tr.prev_key = std.hash.Wyhash.hash(0, s.id);
        return self.draw(s);
    }
    // The region's own fill, when it has one, over the window base (`Backdrop`): the view drawn
    // into it may not paint its whole area, and a snapshot without it has holes the blur turns
    // grey.
    // The nearest enclosing box that paints one: a document draws no background of its own —
    // the pane's card behind it is — so the direct parent is often bare.
    const backdrop: ?core.anim.Backdrop = blk: {
        var w: dvui.Widget = dvui.parentGet();
        while (true) {
            const wd = w.data();
            if (wd.options.backgroundGet()) break :blk .{
                .base = core.dialogs.style().chromeColor(),
                .fill = wd.options.color(.fill).toColor(),
                .corners = wd.options.cornersGet().scale(wd.rectScale().s, dvui.CornerRect.Physical),
            };
            const up = wd.parent;
            if (up.data().id == wd.id) break :blk null;
            w = up;
        }
    };
    var frame = core.anim.transition(tr, .{
        .key = std.hash.Wyhash.hash(0, s.id),
        .rect = rs,
        .backdrop = backdrop,
        .bleed = bleed,
        .draw_previous = if (had) Ctx.drawPrev else null,
        .after_capture = if (had) Ctx.after else null,
        .ctx = @ptrCast(&ctx),
    });
    defer frame.deinit();
    tr.prev_id = s.id;
    // Solid, not faded in: the outgoing snapshot over it *is* the transition. Fading this in
    // as well left both layers part-transparent mid-swap, and the window showed through.
    return self.drawSolid(s);
}

fn resetInnermostPack(self: *Layout) void {
    const box = if (self.depth > 0) self.containers[self.depth - 1].box else null;
    resetPack(box orelse return);
}

/// Forget what `b` has packed this frame, so a view drawn into it again (a capture, a warm-up)
/// does not make the next child land after an expanded one.
fn resetPack(b: *dvui.BoxWidget) void {
    b.first_child = true;
    b.packed_children = 0;
    b.total_weight = 0;
    b.min_space_taken = 0;
    if (builtin.mode == .debug) b.child_id = .zero;
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
pub const Chooser = @import("Chooser.zig");
/// Runtime subdivision of a place — see `State.splits`.
pub const SplitTree = @import("SplitTree.zig");
/// What a released view-drag does — see `app/layout/SPLITS.md`.
pub const Drop = @import("Drop.zig");
/// Carrying a view from one place to another — the gesture `Drop` decides for.
pub const ViewDrag = @import("ViewDrag.zig");
/// What a place's menu does to a place, as commands (`Picker`'s header).
pub const place_commands = @import("place_commands.zig");
/// The views floating over the window, each in a place of its own — see `Floats.zig`.
pub const Floats = @import("Floats.zig");
/// The rules a float follows, as values (std-only).
pub const float_rules = @import("float_rules.zig");
const Picker = @import("Picker.zig");
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
    _ = @import("Picker.zig");
    _ = @import("State.zig");
}
/// Declare a region — the verb form of `Region.init`, so a shape writes `f.region(...)` beside
/// `f.split(...)` and never names the type. Same arrangement as `dvui.box` over `BoxWidget.init`.
pub const region = Region.init;
/// Divide a named place horizontally or vertically — the picker's Split.
pub const splitNamed = Region.splitNamed;
/// Divide a named place from a specific edge — a view-drag drop onto that side.
pub const splitOn = Region.splitOn;
/// Mark the split that minted a place as fizzy's own, so it follows its space's shape (`core.placement`).
pub const markAdaptive = Region.markAdaptive;
/// Move the visible surface from one place to another — a view-drag drop.
pub const placeVisible = ViewDrag.place;

/// Walk `seed` as a `dockspace(header = .none)`. First call (and Reset Layout) convert the
/// seed into a live `DockLayout`; after that the persisted tree is what is walked.
pub fn tree(
    self: *Layout,
    src: std.lang.SourceLocation,
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
    // The region it opens in: it counts its panes, and may have handed them its card to wear.
    const parent_card: ?dvui.Options = if (self.innermost()) |c| c.card else null;
    if (self.innermost()) |c| c.panes +|= 1;
    var opts: dvui.Options = .{
        // Truncated because `id_extra` is a `usize`, which is 32 bits on wasm. A plugin's key is
        // an id or a hash, so the low bits are the ones carrying the distinction.
        .id_extra = @truncate(spec.key),
        .expand = spec.expand,
        .min_size_content = switch (if (self.innermost()) |c| c.dir else .horizontal) {
            .horizontal => .{ .w = spec.min_extent },
            .vertical => .{ .h = spec.min_extent },
        },
    };
    if (parent_card) |card| {
        opts.background = card.background;
        opts.color_fill = card.color_fill;
        opts.corners = card.corners;
        opts.padding = card.padding;
    }
    const r = Region.init(self, @src(), .{
        // A plugin formats its name per frame; everything that holds it holds it across frames.
        .name = self.state.internName(self.gpa, spec.name),
        .keywords = spec.keywords,
        .owns_selection = spec.owns_selection,
        .dir = spec.dir,
        .hide_when_empty = spec.hide_when_empty,
        // The plugin draws its own chrome around the contents, so it says where they go.
        .manual_contents = true,
        .by_name = true,
        .kind_slot = true,
        .on_drop = spec.on_drop,
        .drop_ctx = spec.drop_ctx,
    }, opts) catch |err| {
        dvui.logError(@src(), err, "plugin region \"{s}\"", .{spec.name});
        return null;
    };
    // `hide_when_empty` with nothing to show: the region declined to exist, and a caller that
    // gets a token would draw its chrome around nothing.
    if (r.box == null) return null;

    self.plugin_regions[self.plugin_depth] = r;
    self.plugin_depth += 1;
    return @fromBackingInt(@intCast(self.plugin_depth));
}

pub fn drawPluginRegionContents(self: *Layout, token: sdk.RegionSpec.Token) !dvui.App.Result {
    const r = self.pluginRegion(token) orelse return .ok;
    // A region that does not choose among its views itself gets the app's strip while it holds
    // more than one, and the view in a box of its own beneath it (`tabbedIn`'s reasons): the
    // warm-up and the photograph below are the body's then, as the swap is.
    const body: ?*dvui.BoxWidget = if (!r.owns_selection and self.tabsIn(r)) dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = false,
        .id_extra = @truncate(r.selectionKey()),
    }) else null;
    defer if (body) |b| b.deinit();
    const s = self.selectedIn(r) orelse return .ok;
    // Blurs from one surface to the next like every other region: a tab switch, and a document
    // landing over its loading placeholder. Capturing the outgoing view means drawing it once
    // more, which a large document can afford because it keeps its layout while hidden.
    const key = r.selectionKey();
    // One waiting warm-up a frame (`State.warmIn`), under the parent the surface will be shown
    // in, clipped to nothing, then the parent's packing reset — the same pass a swap's capture
    // makes — so the shown surface lays out as if the warm-up had not happened.
    if (self.state.takeWarm(key)) |id| {
        defer self.gpa.free(id);
        if (self.host.surfaceById(id)) |w| if (w != s) {
            const prev_clip = dvui.clipGet();
            dvui.clipSet(.{});
            _ = surfaceDraw(w) catch {};
            dvui.clipSet(prev_clip);
            if (body) |b| resetPack(b) else self.resetInnermostPack();
            // Another may be waiting; this one's work is done.
            dvui.refresh(null, @src(), null);
        };
    }
    // A document lifted off its tab strip has no place of its own to be photographed from
    // (`ViewDrag.beginLoose`): its card's preview is taken here, from the pane that is showing
    // it, from this very draw and no other — as a region's card is (`Region.drawContentsPhotographed`).
    if (ViewDrag.previewWanted(self, s.id)) {
        const rect = dvui.parentGet().data().contentRectScale().r.intersect(dvui.clipGet());
        if (ViewDrag.photographFromFrame(self, rect)) return self.drawSwapped(key, s, body, .none);
        if (core.anim.CrossFade.beginCapture(rect)) |pic_in| {
            var pic = pic_in;
            const res = self.drawSwapped(key, s, body, .none);
            ViewDrag.keepShot(self, .{ .card = true }, &pic);
            return res;
        }
    }
    return self.drawSwapped(key, s, body, .none);
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

/// A plugin region's own chooser (its tab strip) is at `bounds` this frame
/// (`Host.Region.offerChooser`): while a view is carried it is where the view goes *into* the
/// region, and chrome the region's zones stay off. True while the carried view is over it.
pub fn offerPluginRegionChooser(self: *Layout, token: sdk.RegionSpec.Token, bounds: dvui.Rect.Physical) bool {
    const r = self.pluginRegion(token) orelse return false;
    if (!self.state.view_drag.active() or r.name.len == 0) return false;
    // Into the region even for the one the view came out of: back on its own strip it is being
    // reordered, which only the plugin can do (`RegionSpec.Drop.on_chooser`).
    ViewDrag.offerChooser(self, r.name, bounds, true, null);
    // Over it, and it could take what is carried: the drag's own reading (`chooserAt`, which
    // asks whether the place is one the view can land in). A place lifted out of the layout over
    // a document pane's strip is over no chooser at all — the strip opening a slot for it said
    // it could go in, and the drag, rightly, did not take it there.
    const under = ViewDrag.chooserAt(self.state, dvui.currentWindow().mouse_pt) orelse return false;
    return std.mem.eql(u8, under.name, r.name);
}

pub fn pluginRegionSelect(self: *Layout, token: sdk.RegionSpec.Token, id: []const u8) void {
    const r = self.pluginRegion(token) orelse return;
    self.selectIn(r, id);
}

pub fn endPluginRegion(self: *Layout, token: sdk.RegionSpec.Token) void {
    // Strictly nested, like the boxes they are. Closing out of order would deinit the wrong box
    // and dvui would report it as a stack mismatch two widgets later, naming neither the plugin
    // nor the region — so say it here while the token still means something.
    const depth = @backingInt(token);
    if (depth != self.plugin_depth) {
        dvui.log.err("plugin region closed out of order ({d} of {d} open)", .{ depth, self.plugin_depth });
        return;
    }
    self.plugin_depth -= 1;
    self.plugin_regions[self.plugin_depth].deinit();
}

fn pluginRegion(self: *Layout, token: sdk.RegionSpec.Token) ?*Region {
    const depth = @backingInt(token);
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
pub fn split(self: *Layout, src: std.lang.SourceLocation, opts: Split.Options) void {
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
    src: std.lang.SourceLocation,
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
    src: std.lang.SourceLocation,
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
    _ = tabsIn(f, &place);
}

/// Carry surface `id` in the view drag, lifted from `from` (its tab, its card, its rail icon, its
/// row in a file tree) rather than out of a place: the drop zones and the preview follow the
/// pointer over every place, and the release lands it (`RegionSpec.on_drop` for a plugin's
/// region). `id` may be a document not open yet, by the id it will have (`sdk.document.surfaceId`):
/// it goes only to a document's slot, whose drop opens it. What a plugin's `Host.beginViewDrag`
/// reaches, and a chooser beside a shut place. Driven, like a card lifted out of the picker, by the
/// picker's loose drag each frame.
pub fn beginViewDrag(f: *Layout, id: []const u8, from: dvui.Rect.Physical) void {
    if (f.state.view_drag.active()) return;
    ViewDrag.beginLoose(f, id, from, null);
    if (!f.state.view_drag.active()) return;
    f.state.picker.lifted = true;
    dvui.captureMouseCustom(Picker.looseCapture(), dvui.currentWindow().event_num);
    dvui.refresh(null, @src(), null);
}

/// `beginViewDrag` for several things lifted together — a selection out of a file tree, a folder —
/// the first the one in hand (`ViewDrag.beginLooseMany`): what a plugin's `Host.beginViewDragMany`
/// reaches.
pub fn beginViewDragMany(f: *Layout, items: []const sdk.EditorAPI.Carried, from: dvui.Rect.Physical) void {
    if (f.state.view_drag.active()) return;
    ViewDrag.beginLooseMany(f, items, from);
    if (!f.state.view_drag.active()) return;
    f.state.picker.lifted = true;
    dvui.captureMouseCustom(Picker.looseCapture(), dvui.currentWindow().event_num);
    dvui.refresh(null, @src(), null);
}

/// Tab strip for one place: a horizontal `Chooser` with the stock `label` look. `tabs` is this
/// keyed by keywords; a by-name place (a minted split leaf) must not share another place's
/// selection. Nothing is drawn for a place with one view or none — a single Output is just Output
/// — nor while a takeover has annexed the place (`Surface.takeover_when`): it is the place, not a
/// tab beside what it covers. True when the strip was drawn.
pub fn tabsIn(f: *Layout, r: *const Region) bool {
    const items = f.matchingIn(r);
    if (items.len <= 1) return false;
    for (items) |s| if (s.takeover_when != null) return false;
    // Across the whole place, not just its tabs: a view carried anywhere along it goes in among
    // them — past the last one, at the end.
    var strip = Chooser.init(@src(), f, r.*, .{ .outer = .{ .expand = .horizontal } });
    defer strip.deinit();
    if (r.name.len > 0) core.anchor.mark(strip.strip.outer.data(), "tabs:{s}", .{r.name});
    for (strip.views()) |view| {
        var it = strip.item(@src(), view, .{});
        defer it.deinit();
        Chooser.label(view, it.selected, it.hovered());
    }
    return true;
}

/// A place's strip (none while it holds one view), then the selected view in a box of its own
/// beneath it.
///
/// The box is the point. The swap between views photographs and blurs *its parent*, and resets
/// that parent's layout after the photograph as if the view were its only child. Drawn straight
/// into the place alongside the strip, the blur ran over the strip too and the view laid out as
/// though the strip were not there. In its own box the strip stays put and sharp, inside the
/// place's card, and only what changed dissolves — the same as the bottom panel.
pub fn tabbedIn(f: *Layout, r: *const Region) !dvui.App.Result {
    _ = f.tabsIn(r);
    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = false,
        .id_extra = @truncate(r.selectionKey()),
    });
    defer body.deinit();
    const s = (if (r.by_name) f.selectedIn(r) else f.selected(r.keywords)) orelse return .ok;
    return f.drawSwappedIn(r.selectionKey(), body, s, .none);
}

/// The plain tabbed region: a strip of tabs, then the selected surface beneath it. The
/// `content` function form of the two-line recipe `tabs` documents above — pass it as
/// `.content = Layout.tabbed` and the region is tabbed.
///
/// the icon rail deliberately has no counterpart here. It is a chooser that sits *beside* the
/// region it chooses for rather than above it (see `src/editor/layout.zig`), so it is not a region's content
/// and wrapping it as one would only lose the action it returns.
pub fn tabbed(_: ?*anyopaque, f: *Layout, keywords: []const []const u8) !dvui.App.Result {
    const place: Region = .{ .keywords = keywords };
    return f.tabbedIn(&place);
}

/// Debug builds only: catches a surface that fills its place with a scroll area of its own but
/// does not say `Surface.scrolls_itself`. In a place that scrolls what it shows (fizzy's
/// explorer) that view grows wider without limit and never shrinks after a resize, and nothing
/// on screen says why.
///
/// It stands in as the parent the surface draws into, passing everything through to the real
/// one (whose data it hands out, so every id is unchanged) and noting the first child placed:
/// a scroll area, when dvui has kept that id's `ScrollInfo`, which every scroll area does as it
/// closes. Only the first child, which is what "the content is its own scroll area" means; one
/// under a header is not seen.
const ScrollWatch = struct {
    const enabled = builtin.mode == .debug;

    parent: dvui.Widget,
    first: ?struct { id: dvui.Id, expand: dvui.Options.Expand } = null,

    fn begin(self: *ScrollWatch) void {
        self.* = .{ .parent = dvui.parentGet() };
        dvui.parentSet(dvui.Widget.init(self, data, rectFor, screenRectScale, minSizeForChild));
    }

    fn end(self: *ScrollWatch, state: *State, id: []const u8) void {
        dvui.parentSet(self.parent);
        const first = self.first orelse return;
        if (!first.expand.isHorizontal() and !first.expand.isVertical()) return;
        if (dvui.dataGet(null, first.id, "_scroll_info", dvui.ScrollInfo) == null) return;
        if (!state.noteUnmarkedScroller(id)) return;
        // Not in tests, which check `State.unmarked_scrollers`: a logged warning fails the step.
        if (!builtin.is_test) dvui.log.warn("surface \"{s}\" fills its place with its own scroll area but does not set `scrolls_itself`: in a place that scrolls (a sidebar) it grows wider without limit. Set `.scrolls_itself = true` on its `Surface`.", .{id});
    }

    fn data(self: *ScrollWatch) *dvui.WidgetData {
        return self.parent.data();
    }

    fn rectFor(self: *ScrollWatch, id: dvui.Id, min_size: dvui.Size, e: dvui.Options.Expand, g: dvui.Options.Gravity) dvui.Rect {
        if (self.first == null) self.first = .{ .id = id, .expand = e };
        return self.parent.rectFor(id, min_size, e, g);
    }

    fn screenRectScale(self: *ScrollWatch, r: dvui.Rect) dvui.RectScale {
        return self.parent.screenRectScale(r);
    }

    fn minSizeForChild(self: *ScrollWatch, s: dvui.Size) void {
        self.parent.minSizeForChild(s);
    }
};

/// A surface's draw, timed in the frame profiler under its owner (fizzy's own when it has none)
/// and its id.
fn surfaceDraw(s: *Surface) Region.Error!dvui.App.Result {
    const prof = core.profile.begin(if (s.owner) |o| o.id else "fizzy", s.id);
    defer prof.end();
    return s.draw(s.ctx) catch |err| if (s.owner) |o| o.failed(s.id, err) else switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => {
            dvui.log.err("{s}: draw failed: {s}", .{ s.id, @errorName(err) });
            return error.Failed;
        },
    };
}

test "a surface's draw failure reaches a caller as Region.Error; an allocation keeps its name" {
    const fns = struct {
        // lint-allow(anyerror): `Surface.draw`'s own type.
        fn starved(_: ?*anyopaque) anyerror!dvui.App.Result {
            return error.OutOfMemory;
        }
    };
    var s: Surface = .{ .id = "test.surface", .title = "Test", .draw = fns.starved };
    const why: []const u8 = if (surfaceDraw(&s)) |_| "ok" else |err| switch (err) {
        error.OutOfMemory => "oom",
        error.PluginFailed => "plugin",
        error.Failed => "failed",
    };
    try std.testing.expectEqualStrings("oom", why);
}
