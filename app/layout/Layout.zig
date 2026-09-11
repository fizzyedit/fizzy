//! What an app's shape declares its regions with — the whole of how an app lays itself out.
//!
//! A region says which keywords it accepts; a plugin's `sdk.Surface` says which it carries. The
//! intersection is the match set the region draws, so neither side names the other and an app
//! can invent a region shape the SDK has never heard of.
//!
//! The three pieces, all in this directory: `Layout` is the live view (which surfaces exist,
//! which match a region, which is selected), `Region.zig` is a named area accepting keywords,
//! and `presets.zig` dispatches to the shipped shapes in `presets/`. The resizable division
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
//! The intended end state is that a layout function contains *nothing else*: no `dvui.box`, no
//! `dvui.label`, no fizzy widgets intermixed. `region` therefore does double duty, and that is
//! deliberate rather than an overload: a region **with** keywords is a place surfaces draw; a
//! region **without** is a plain container you nest more regions in — so it takes box-like
//! options (`dir`, `expand`) as well as placement ones. There is no third concept, and no reason
//! for an app author to reach past this API into dvui.
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
//! `presets/ide.zig` — but nothing in the model prevents an app from letting the user rearrange.
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

/// Open regions, innermost last. Every region pushes; its `deinit` pops. This is what lets
/// `split` know which axis it divides and which neighbour it resizes, without a shape having to
/// pass either in.
containers: [max_nesting]Container = undefined,
depth: usize = 0,

pub const Container = struct {
    dir: dvui.enums.Direction,
    /// The base region's declared minimum along the axis — `min_size_content` on the region in
    /// this container that is not resizable. The app declares it; the framework only reads it.
    base_min: f32 = 0,
    /// Every resizable region in this container. A split needs them all, because honouring one
    /// drag can mean pushing the others back.
    resizables: [max_trays]dvui.Id = undefined,
    resizable_count: usize = 0,
    /// Total extent the splits in this container take between them.
    handles: f32 = 0,
    /// The container's own box, for measuring how near the pointer is to a split inside it.
    box: ?*dvui.BoxWidget = null,
    /// A split that found no resizable region before it, waiting to be bound to the one after.
    pending_split: ?dvui.Id = null,
    /// The most recent resizable child. A `split` drags *this* region's stored extent — the
    /// neighbour before it — which is the whole of the resize mechanism: there are no ratios and
    /// no boundary table, just one number per resizable region.
    last_resizable: ?dvui.Id = null,

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
pub const max_nesting = 8;

/// Trays per container. More than a handful on one axis is a layout problem, not a use case.
pub const max_trays = 6;

/// How long a region takes to fold away or come back. Matches the paned shell's feel.
pub const collapse_ms: i32 = 220;

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
    const want = sdk.keywords.groupKey(keywords);
    for (self.state.regions_building.items) |r| {
        if (sdk.keywords.groupKey(r.keywords) == want) return self.state.assignment(r.name);
    }
    for (self.state.regions.items) |r| {
        if (sdk.keywords.groupKey(r.keywords) == want) return self.state.assignment(r.name);
    }
    return null;
}

/// Every surface that belongs in the region with `keywords`: the user's assignment when there
/// is one, in the order they chose, otherwise every surface whose keywords intersect, in
/// registration order. Arena-allocated and valid for this frame only; returns an empty slice
/// rather than erroring so a layout can always iterate.
pub fn matching(self: *Layout, keywords: []const []const u8) []const *Surface {
    var out: std.ArrayListUnmanaged(*Surface) = .empty;
    const a = self.arena;
    if (self.assignedFor(keywords)) |ids| {
        for (ids) |id| {
            const s = self.host.surfaceById(id) orelse continue; // plugin not loaded right now
            if (s.hidden) continue;
            out.append(a, s) catch return out.items;
        }
        return out.items;
    }
    for (self.host.surfaces.items) |*s| {
        if (s.hidden) continue;
        if (!sdk.keywords.intersects(s.keywords, keywords)) continue;
        out.append(a, s) catch return out.items;
    }
    return out.items;
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
            } else if (sdk.keywords.intersects(s.keywords, r.keywords)) continue :outer;
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
    const items = self.matching(keywords);
    if (items.len == 0) return null;
    if (self.currentId(keywords)) |id| {
        for (items) |s| if (std.mem.eql(u8, s.id, id)) return s;
    }
    return items[0];
}

pub fn isSelected(self: *Layout, keywords: []const []const u8, s: *const Surface) bool {
    const cur = self.selected(keywords) orelse return false;
    return std.mem.eql(u8, cur.id, s.id);
}

pub fn select(self: *Layout, keywords: []const []const u8, s: *const Surface) void {
    self.host.setSelectionFor(keywords, s.id);
}

/// Draw one surface into the current parent, wrapped in the swap cross-fade so every region gets
/// it for free. Keyed by **surface id**, never the parent box id — a box id moves with the
/// surrounding layout and would restart the fade on changes that are not content swaps (see the
/// warning at workbench `src/Workspace.zig:768`).
pub fn draw(self: *Layout, s: *Surface) !dvui.App.Result {
    _ = self;
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(s.id);
    const rv = core.anim.reveal(
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
pub fn drawSelected(self: *Layout, keywords: []const []const u8) !dvui.App.Result {
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
// `editor.layout.panel_ratio` in sync by hand and published `editor.panes.paned` so other code could
// find it — none of which an app author should know about, and all of which only worked because
// fizzy's own shape happens to have a panel.

pub const Region = @import("Region.zig");
/// Declare a region — the verb form of `Region.init`, so a shape writes `f.region(...)` beside
/// `f.split(...)` and never names the type. Same arrangement as `dvui.box` over `BoxWidget.init`.
pub const region = Region.init;

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
    const axis = c.dir;

    var divider = Split.init(src, axis, 0);
    defer divider.deinit();
    if (!opts.resize) return;

    // Which neighbour this split resizes. Preferring the one *before* it makes the sidebar case
    // work immediately; falling back to the one after is what the bottom panel needs, since a
    // panel is declared after its own split and cannot be known when the split is drawn. That one
    // is bound by `region` and read back a frame later.
    var sign: f32 = 1;
    const target = c.last_resizable orelse blk: {
        sign = -1;
        break :blk dvui.dataGet(null, divider.box.data().id, "_after", dvui.Id) orelse {
            c.pending_split = divider.box.data().id;
            return;
        };
    };

    const container = c.box orelse return;
    c.handles += Split.handle_size;
    divider.drag(container, target, sign, opts, .{
        .extent = c.extent(axis),
        .base_min = c.base_min,
        .handles = c.handles,
        .others = c.resizables[0..c.resizable_count],
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
    const surfaces = f.matching(keywords);
    if (surfaces.len == 0) return;

    var strip: core.widgets.Tabs = .init(@src(), &tab_info, .{ .drag_name = "fizzy_tab_strip" });
    defer strip.deinit();

    for (surfaces, 0..) |s, i| {
        const is_selected = f.isSelected(keywords, s);
        var t = strip.tab(@src(), i, is_selected);
        defer t.deinit();

        var title_buf: [64]u8 = undefined;
        const title_upper = if (s.title.len <= title_buf.len)
            std.ascii.upperString(&title_buf, s.title)
        else
            s.title;

        dvui.label(@src(), "{s}", .{title_upper}, .{
            .color_text = if (is_selected)
                dvui.themeGet().color(.highlight, .fill)
            else
                dvui.themeGet().color(.control, .text),
            .font = dvui.Font.theme(.heading),
            .padding = dvui.Rect.all(4),
            .gravity_y = 0.5,
        });

        if (t.clicked()) f.select(keywords, s);
    }

    strip.finalSlot(surfaces.len);
}

/// The plain tabbed region: a strip of tabs, then the selected surface beneath it. The
/// `content` function form of the two-line recipe `tabs` documents above — pass it as
/// `.content = Layout.tabbed` and the region is tabbed.
///
/// the icon rail deliberately has no counterpart here. It is a chooser that sits *beside* the
/// region it chooses for rather than above it (see `ide.zig`), so it is not a region's content
/// and wrapping it as one would only lose the action it returns.
pub fn tabbed(_: ?*anyopaque, f: *Layout, keywords: []const []const u8) !dvui.App.Result {
    f.tabs(keywords);
    return f.drawSelected(keywords);
}

/// Drag state for `tabStrip`. One strip per app in practice; a layout wanting two independent
/// strips copies this recipe (see CLAUDE.md's shipped-shapes note) rather than fizzy growing a
/// handle type for a case nothing has yet.
var tab_info: core.widgets.Tabs.TabInfo = .{};
