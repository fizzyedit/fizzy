//! A declared region: an area that accepts keywords and draws the surfaces matching them.
//!
//! Note this is **not** docking in the draggable-panel sense — a region's place is fixed by the
//! shape that declares it. Real docking (dvui has dockable panels now) would be a layer *above*
//! this that lets the user move regions at runtime, and is the natural basis for a
//! Premiere-style shape. Named seam, not built.
//!
//! `init` + `deinit`, like any dvui widget, with the verb form on the namespace above it:
//! `f.region(@src(), .{ … }, .{ … })` in a shape, which is `Layout.region` re-exporting this
//! file's `init`. Same arrangement as `dvui.box` over `BoxWidget.init`, and `core.widgets.split`
//! over `Split.init`.
//!
//! `region` draws the region's own contents — its chrome, if it declared any, and the active
//! matching surface — and leaves the caller positioned in the *remaining* space, so whatever the
//! layout writes next lands there. That is what removes the `showFirst`/`showSecond` pairs from
//! shapes.
//!
//! The third argument is `dvui.Options` and goes to the region's box, the way
//! `dvui.box` takes them. Fill, corners, margin, padding — those are the app's.
//! The framework does not paint a card. Fizzy's explorer is a region with
//! `background = false`; a shape that wants a rounded tray sets that itself.
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const icons = @import("icons");
const sdk = @import("fizzy_sdk");
const Split = core.widgets.Split;
const Layout = @import("Layout.zig");
const SplitTree = @import("SplitTree.zig");
const Drop = @import("Drop.zig");
const ViewDrag = @import("ViewDrag.zig");

const Region = @This();

/// The human-facing name the shape gave this region — "Sidebar", "Main", "Panel". What a user
/// picks from when moving a surface somewhere else, so it is worth a real word.
name: []const u8 = "",
/// What kinds of surface this region accepts, as its shape declared them.
keywords: []const []const u8 = &.{},
/// How many of them it can show at once. See `Shows`.
shows: Shows = .one,
/// This region's widget id, stable across frames from the shape's `@src()`.
id: dvui.Id = .zero,
/// How far this region reaches along its parent's axis when it has never been dragged — the
/// width under a horizontal parent, the height under a vertical one, in points. One number,
/// because a region only ever divides its parent one way; the other axis is the parent's.
default_extent: f32 = 0,
/// Clip set while the region is open, restored on `deinit`.
prev_clip: ?dvui.Rect.Physical = null,
/// The box this region is. A region **is** a `dvui.box`: same layout mechanics, same
/// options, same lifetime rules — so an app author who has written any dvui already knows
/// how this behaves, and a split is a separator between two of them.
box: ?*dvui.BoxWidget = null,
layout: ?*Layout = null,
/// Contents and selection resolve by this region's *name*, not by its keyword group. Set for
/// plugin-declared regions: a plugin's document panes all accept the same qualified keywords,
/// and by keyword group they would be one region with one assignment and one active tab. The
/// app's own regions stay keyword-resolved so a chooser written against keywords (the icon
/// rail) needs no region in hand.
by_name: bool = false,
/// See `InitOptions.kind_slot`.
kind_slot: bool = false,
/// See `InitOptions.pane_cards`: this region counts the panes opened in it, for next frame.
pane_cards: bool = false,
/// A tray the next split should keep targeting. Center and grouping boxes are not.
resize: bool = false,
/// An empty closed tray can disappear — a runtime split, an endless edge.
forget_when_empty: bool = false,
/// How this place lays its children.
dir: dvui.enums.Direction = .vertical,
/// This frame's border box, in its parent's units (points, unless something above it scales):
/// the reach a split of it halves along one axis.
size: dvui.Size = .{},
/// This frame's border in physical pixels, for hit-testing a view drag.
bounds: dvui.Rect.Physical = .{},
/// What a view dropped here does, for a plugin's region — `sdk.RegionSpec.on_drop`.
on_drop: ?*const fn (ctx: ?*anyopaque, drop: sdk.RegionSpec.Drop) bool = null,
drop_ctx: ?*anyopaque = null,
/// Which window it is drawn in: 0 the main window, `n` the `n`th float from the bottom
/// (`Floats`). Stamped as it registers (`State.layer_building`); a drag aims only at the topmost
/// layer under the pointer.
layer: u16 = 0,

/// The key this region's selection lives under in the host — see `Layout.selectedIn`.
///
/// A by-name place keeps its selection under its name alone. A place split into others is known
/// by that name twice — the branch that holds the split (keyed to `slot`) and the leaf left
/// showing its views (keyed to its own keywords) — and a key folding in the keywords gave the
/// two different selections: a drag out of the place read the branch's and carried a view the
/// place was not showing.
pub fn selectionKey(self: *const Region) u64 {
    if (self.by_name) return namedSelectionKey(self.name);
    return sdk.keywords.groupKey(self.keywords);
}

/// `selectionKey` of the by-name place `name`, for when only its name is at hand.
pub fn namedSelectionKey(name: []const u8) u64 {
    return std.hash.Wyhash.hash(0x51a7, name);
}

pub fn deinit(self: *Region) void {
    // Plugin panes skip the corner button, so their drop zones are drawn
    // here — still clipped — after their own chrome has drawn.
    if (self.kind_slot) {
        if (self.layout) |l| {
            if (self.box) |b| ViewDrag.drawZones(l, self.name, b.data().id);
        }
    }
    if (self.prev_clip) |c| dvui.clipSet(c);
    if (self.box) |b| {
        if (self.layout) |l| {
            std.debug.assert(l.depth > 0);
            // How many panes this frame's view opened in it, for next frame's card (`pane_cards`).
            if (self.pane_cards) dvui.dataSet(null, self.id, "_panes", l.containers[l.depth - 1].panes);
            l.depth -= 1;
            // A tray the next split should keep targeting is `resize`. Center and grouping
            // boxes are not: after they close, the following split sizes the region after
            // it. Clearing only for empty-keyword groups left Center holding the last top
            // tray, so the Center–bottom split grew the top instead of the bottom.
            if (!self.resize and l.depth > 0) {
                l.containers[l.depth - 1].last_resizable = null;
            }
        }
        b.deinit();
    }
}

// Opening and shutting from outside the layout — a rail button, a command, a keybind. These
// work on the copy `Editor.regionFor` hands back as well as on a live one, which is why they
// touch only `id` and `default_extent`: everything they need is a persisted extent under an id,
// never a widget pointer.

pub fn isClosed(self: Region) bool {
    // Absence is not zero: a region that was never sized — a stretchy one that takes what is
    // left, now that every region registers — has no stored extent and is not shut.
    const stored = dvui.dataGet(null, self.id, "_size", f32) orelse return false;
    return stored <= 0;
}

pub fn close(self: Region) void {
    // Deliberately before `Split.close`: shutting a region is also the user withdrawing the peek
    // that kept it open on a narrow window (see `collapseTarget`).
    dvui.dataSet(null, self.id, "_peek", false);
    Split.close(self.id);
}

pub fn open(self: Region) void {
    // Opening is an explicit answer to the auto-collapse, and outlives it.
    dvui.dataSet(null, self.id, "_peek", true);
    Split.open(self.id, self.default_extent);
}

/// Auto-collapse is a *default*, not a lock: a `collapsible` region folds itself away when the
/// container runs out of room, unless the user has said otherwise since — by tapping its rail
/// icon, or by dragging its split back out. That answer is the peek, and it lives under the
/// region's id beside `_size`.
///
/// Without it, the collapse ran every frame and won every argument: on a phone-width window the
/// explorer shut itself the instant it was opened, and a drag moved the split for exactly as
/// long as the button was held. The peek is forgotten again when the region is shut, or when the
/// window grows back past `collapse_below` — so making the window small again collapses it, as
/// it should.
fn collapseTarget(id: dvui.Id, chosen: f32, available: f32) f32 {
    const narrow = available > 0 and available < InitOptions.collapse_below;
    // Recorded for `isPeeking`, which the shape asks from outside the layout, where there is no
    // container to measure.
    dvui.dataSet(null, id, "_narrow", narrow);
    var peek = dvui.dataGet(null, id, "_peek", bool) orelse false;

    if (!narrow) {
        // Room again: the next collapse starts from a clean slate.
        if (peek) dvui.dataSet(null, id, "_peek", false);
        return chosen;
    }

    // A drag that has pulled the region open is the same intent as tapping the icon, and has to
    // latch: `_drag` is gone on release, and without the latch the region would slam shut the
    // frame the button came up.
    const dragging = dvui.dataGet(null, id, "_drag", bool) orelse false;
    if (dragging and chosen > 0 and !peek) {
        peek = true;
        dvui.dataSet(null, id, "_peek", true);
    }
    // Shut — dragged closed, or closed from a button. Re-arm.
    if (chosen <= 0 and peek) {
        peek = false;
        dvui.dataSet(null, id, "_peek", false);
    }
    return if (peek) chosen else 0;
}

/// Whether this region is folded away by the auto-collapse: the container is too narrow for it
/// and the user has not asked for it since. Distinct from `isClosed`, which asks whether the
/// user *shut* it — a folded region keeps the extent it was left at, so widening the window puts
/// it back where it was, and `isClosed` is false the whole time it is invisible.
///
/// A rail button that toggles a region has to ask this one. Reading `isClosed` there makes the
/// first tap on a phone-width window report "close" for something already off the screen.
pub fn isFolded(self: Region) bool {
    if (!(dvui.dataGet(null, self.id, "_narrow", bool) orelse false)) return false;
    return !(dvui.dataGet(null, self.id, "_peek", bool) orelse false);
}

/// Whether this region is only open because the user asked for it on a container too narrow to
/// hold it — the state a phone-width layout draws a "close this" button for, and the one where a
/// shape may want to shut its other regions to make room.
///
/// False on a window with room for the region: there the answer is just "open", and nothing
/// special is owed to the user.
pub fn isPeeking(self: Region) bool {
    if (!(dvui.dataGet(null, self.id, "_narrow", bool) orelse false)) return false;
    if (!(dvui.dataGet(null, self.id, "_peek", bool) orelse false)) return false;
    return !self.isClosed();
}

/// How a region draws its own contents.
///
/// Null means "draw the selected matching surface" — the "this region IS x" form. A function
/// means the region has chrome of its own: a tab strip above its content, a titled scroll pane,
/// a splittable panel. It is handed the region's keywords and returns when the region is full.
///
/// This replaced a five-value `Chooser` enum, two of whose values (`explorer_chrome`,
/// `panel_chrome`) named *fizzy's own* furniture from inside the generic layer. That is the
/// case AGENTS.md calls a bug in `Layout` rather than a special case: a shape is supposed to be
/// ordinary code over this API, and an app copying `src/editor/layout.zig` could not have written those two
/// values itself. As a function pointer it is just `explorerPane` in `src/editor/layout.zig` —
/// app code, passed in, replaceable by the app's own loop over `matching` / `selected` / `draw`,
/// which is the governing test for everything here. (The bottom panel had one too, until
/// `shows = .many` drew the same strip generically: it is a plain Multiple place now.)
///
/// It also retired the two values nothing used (`.tabs`, `.icons`); `Layout.tabbed` is the
/// first of those as a plain function, and the icon rail was never this shape to begin with —
/// it sits *beside* the region it chooses for, so fizzy's `layout.zig` calls it directly and reads the
/// action it returns.
pub const Content = struct {
    /// Whatever the shape needs to draw its chrome — for fizzy's own shapes, the application.
    /// A `Layout` deliberately does not carry it: the layout mechanism knows about surfaces,
    /// regions and splits, and nothing about whose furniture is being drawn. Same `ctx` idiom
    /// as `Surface.draw`, for the same reason.
    ctx: ?*anyopaque = null,
    draw: *const fn (ctx: ?*anyopaque, f: *Layout, keywords: []const []const u8) anyerror!dvui.App.Result,
};

/// How many matching surfaces a region can show at once.
///
/// This is not a policy the framework enforces — it is the region *telling the truth about how it
/// draws*, which is the one thing nothing else can work out. A region with no `content` falls
/// through to `drawSelected`, so exactly one surface is ever on screen and a second assigned one
/// would simply be invisible. A region whose chrome loops over `matching` — a tab strip, an icon
/// rail — shows as many as it is given.
///
/// Everything that offers the user a choice reads this. The picker is the reason it exists: over
/// a `.one` region its cards are a *swap* (choosing writes a single surface and selects it), and
/// over a `.many` region they are toggles. Before, every region was a set, so assigning two
/// surfaces to the main area silently hid one of them.
///
/// `.one` is the truthful default: a plain region shows one, and a shape that draws a chooser
/// knows it did.
/// The SDK's enum, not a copy of it: a plugin declaring a region has to be able to say how its
/// region draws, and two definitions of `one` would eventually disagree.
pub const Shows = sdk.RegionSpec.Shows;

/// What a region *is*, as opposed to how it is laid out — which is `dvui.Options`, unchanged.
pub const InitOptions = struct {
    /// Below this container extent, a `collapsible` region folds itself away — the width at
    /// which a sidebar beside a document stops being a layout and starts being two slivers. A
    /// number rather than a policy an app configures: it is about how small a pane can be before
    /// it is useless, not about what the app is for.
    pub const collapse_below: f32 = 640;

    /// Human-facing name, shown wherever a user places a surface by hand.
    name: []const u8 = "",
    /// What kinds of surface this region accepts. Empty means it hosts nothing itself and is
    /// purely a container for other regions.
    keywords: []const []const u8 = &.{},
    /// How many of them it shows at once — `.one` unless this region's `content` draws a chooser.
    /// See `Shows`; the picker's behaviour follows it.
    shows: Shows = .one,
    /// The axis this region lays its children along, exactly as `dvui.box`'s `dir`.
    dir: dvui.enums.Direction = .vertical,
    /// Chrome drawn instead of the plain selected surface. See `Content`.
    content: ?Content = null,
    /// Leave the contents to the caller, which draws them with `Layout.drawSelected` when it
    /// reaches the right point in its own chrome.
    ///
    /// For a caller that cannot pass a `content` function: a plugin declares a region through a
    /// vtable (`Host.region`), so there is no `*Layout` in its hands and no fn pointer it could
    /// hand back that would take one. It draws its chrome and asks for the contents instead.
    manual_contents: bool = false,
    /// See `Region.by_name`.
    by_name: bool = false,
    /// See `Region.kind_slot`.
    kind_slot: bool = false,
    /// See `Region.on_drop`.
    on_drop: ?*const fn (ctx: ?*anyopaque, drop: sdk.RegionSpec.Drop) bool = null,
    drop_ctx: ?*anyopaque = null,
    /// Make this region's extent along its parent's axis draggable by the `split` after it. The
    /// starting extent comes from `min_size_content` in the `dvui.Options`; the user's drag
    /// replaces it and persists.
    resize: bool = false,
    /// Collapse while nothing matches, rather than holding empty space open.
    hide_when_empty: bool = false,
    /// Drop this region from persisted extents when it is closed and has no assigned surface.
    /// An empty tray dragged shut disappears; one the user filled can close and reopen.
    forget_when_empty: bool = false,
    /// Tree-internal edge that already has a sash — the leaf does not draw a create-handle there.
    omit_edge: ?SplitTree.Side = null,
    /// Start shut when the window has no room to show this region beside everything else.
    ///
    /// Closing itself needs no flag: a region slides continuously from its full size to nothing,
    /// because a pinned box is exactly the size it is pinned to and a region clips what it holds.
    /// There is no threshold and nothing snaps — a split that jumps the last stretch is a split
    /// that fights you.
    collapsible: bool = false,
    /// When the view in this region lays itself out as panes of its own (`Host.region`: the
    /// workbench's document panes), each pane wears this region's card — its fill, corners and
    /// padding from the `dvui.Options` — and the region wears none: the gap between two panes then
    /// shows what is behind the region, as the gap between two places does, and the split there
    /// reads as one. A region showing one pane, or none, keeps its card. Decided from the last
    /// frame's panes, so a second pane opening wears its card a frame after it appears.
    pane_cards: bool = false,
    /// Wear the layout's card (`Layout.card`) — under whatever of its fill, corners and padding
    /// the region's own `dvui.Options` set. A float's place asks for it; so can a place the shape
    /// draws, rather than spelling the card out. The places a split makes of it wear it too, and
    /// with `pane_cards` the panes its view opens.
    card: bool = false,
};

/// Declare a region: an area that hosts matching surfaces, holds other regions, or both.
///
/// It is a `dvui.box`. The second argument says what the region *is*; the third is dvui's own
/// `Options` and is passed to that box — `expand`, `min_size_content`, `padding`,
/// `margin`, `background`, `corners`, `gravity`, all of it. A rounded fill is an
/// Option the shape sets. A sash gap is a packed split (`handle_size` child),
/// not a margin on the card — plugin surfaces fill this box's content rect.
///
/// Scope it and `deinit` it the way you would any box:
///
/// ```zig
/// {
///     var side = f.region(@src(), .{ .keywords = kw.ide.sidebar, .resize = true },
///                                  .{ .min_size_content = .{ .w = 240 } });
///     defer side.deinit();
/// }
/// f.split(@src(), .{});
/// ```
pub fn init(self: *Layout, src: std.builtin.SourceLocation, init_opts: InitOptions, opts_given: dvui.Options) anyerror!Region {
    const opts = withCard(self, init_opts, opts_given);
    if (self.depth >= Layout.max_nesting) {
        dvui.log.err("layout nests deeper than {d} regions; \"{s}\" ignored", .{ Layout.max_nesting, init_opts.name });
        return .{};
    }

    // The container this region lands in, if any — the layout's own stack, read directly
    // rather than through an accessor, so nothing about it appears on the app-facing API.
    const parent: ?*Layout.Container = if (self.depth == 0) null else &self.containers[self.depth - 1];
    const axis: dvui.enums.Direction = if (parent) |p| p.dir else .horizontal;
    const id = dvui.parentGet().extendId(src, opts.idExtra());

    // Declared inside another region, this one's keywords name a place *within* it: `{"document"}`
    // inside the main area accepts `main.document`. The shape writes the short word — a sub-region
    // should not have to know, or repeat, what it is nested in — and a plugin still reaches it by
    // kind alone. See `Layout.Container.prefix` and `sdk.keywords.Fit`.
    //
    // A leftover origin sits inside the split grouping box. That box already
    // qualified under the shape's parent and registered as this name. Doing
    // it again under the box prefix made `main.main`, the grouping box kept
    // the exact claim, and Split → Vertical drew two empty sides.
    const keywords = blk: {
        if (init_opts.omit_edge != null and init_opts.name.len > 0 and self.state.splits.root(init_opts.name) != null) {
            var i = self.state.regions_building.items.len;
            while (i > 0) {
                i -= 1;
                const r = self.state.regions_building.items[i];
                if (std.mem.eql(u8, r.name, init_opts.name)) break :blk r.keywords;
            }
            break :blk regionKeywords(self, "", init_opts.keywords);
        }
        break :blk regionKeywords(self, if (parent) |p| p.prefix else "", init_opts.keywords);
    };

    const probe: Region = .{
        .name = init_opts.name,
        .keywords = keywords,
        .shows = init_opts.shows,
        .by_name = init_opts.by_name,
        .kind_slot = init_opts.kind_slot,
    };
    // Stored, not the drag preview: a swap onto Main poses this place as an
    // empty hole (or as a view that does not match these keywords), and
    // collapsing then lets Main eat the column until the pointer comes back.
    // `hide_when_empty` is "nothing belongs here when idle" — the picker
    // emptied it, every panel view is toggled off — not the view sitting
    // on the pointer. Shape places stay; only a drop commits the hole.
    const matches = self.matchingIn(&probe);
    // Cleared through the picker is not "nothing belongs here": the user asked for an empty
    // place and expects to see it, hatch and all, until they put something back. Only a
    // place nothing *chose* — every view toggled off, no assignment — folds away.
    const cleared = if (self.state.assignment(init_opts.name)) |a| a.len == 0 else false;
    if (init_opts.hide_when_empty and keywords.len > 0 and matches.len == 0 and !cleared) {
        // A boundary with nothing on one side is not a boundary.
        if (parent) |p| p.pending_split = null;
        // Still a place, even with nothing in it: it stays in the registry so the picker and
        // the settings table can put something back. Emptied through the picker and then
        // gone from the picker was a region the user could not get back.
        self.state.registerRegion(self.gpa, .{
            .name = init_opts.name,
            .keywords = keywords,
            .shows = init_opts.shows,
            .id = id,
            .by_name = init_opts.by_name,
            .kind_slot = init_opts.kind_slot,
            .forget_when_empty = init_opts.forget_when_empty,
            .dir = init_opts.dir,
            .on_drop = init_opts.on_drop,
            .drop_ctx = init_opts.drop_ctx,
        });
        return .{};
    }
    // A tree-walk leaf keeps the origin name, but must not walk the tree again.
    const tree_origin = init_opts.omit_edge != null and self.state.splits.root(init_opts.name) != null;
    if (!tree_origin and init_opts.name.len > 0) {
        if (self.state.splits.root(init_opts.name)) |node| {
            if (node.kind == .branch) return try initTree(self, src, init_opts, opts, node);
        }
    }
    // The split declared before this region divides it from the one before: drawn now, with
    // this region known — so a split never precedes a region that is not there.
    if (init_opts.resize) self.drawPendingSplit(id) else self.drawPendingSplit(null);

    // A resizable region's extent along its parent's axis is whatever the user last dragged it
    // to, defaulting to the `min_size_content` the shape wrote.
    var box_opts = opts;
    var shut_now = false;
    // The region's reach along its parent's axis, in points: `extent` is what it shows this
    // frame (mid-animation it is between the two), `default_extent` what it opens to when the
    // user has never dragged it.
    var extent: f32 = 0;
    var default_extent: f32 = 0;
    if (init_opts.resize) {
        const given = opts.min_size_content orelse dvui.Size{};
        // The shape's `min_size_content` is the content it wants to open to; the extent is the
        // whole region round it.
        const default: f32 = switch (axis) {
            .horizontal => given.w,
            .vertical => given.h,
        } + alongAxis(opts.paddingGet(), axis) + alongAxis(opts.borderGet(), axis);
        default_extent = default;
        // Seeded from what the user last left this region at, by name — so a layout persists
        // across restarts without the framework knowing which regions an app has.
        if (dvui.dataGet(null, id, "_size", f32) == null) {
            dvui.dataSet(null, id, "_size", self.state.extent(init_opts.name, default));
        }
        // The size the user chose. Auto-collapse must never overwrite it, or folding the window
        // small destroys the extent it is supposed to restore: the stored size stays put and
        // only what is *shown* goes to zero.
        const chosen = dvui.dataGet(null, id, "_size", f32) orelse default;
        if (init_opts.name.len > 0) {
            if (self.state.takeSlideOpen(init_opts.name)) |from| {
                dvui.dataSet(null, id, "_shown", chosen * from);
            }
        }

        var target = chosen;
        if (init_opts.collapsible) {
            target = collapseTarget(id, chosen, if (parent) |p| p.extent(axis) else 0);
        }

        // Ease toward the target when it moved for a reason other than a drag — the collapse
        // when the window runs out of room, and the restore when it comes back.
        //
        // A drag is exempt, and stays exempt without a flag: the split writes `_shown` alongside
        // `_size`, so the two agree and nothing kicks off. Easing a drag would be wrong anyway —
        // a split should sit under the pointer, not lag behind it on a curve.
        //
        // `Split.eased` rather than a curve of its own: a region and a document pane sliding at
        // different speeds is the kind of wrongness nobody can name but everybody feels. It also
        // carries the asymmetry — out with a little overshoot, in without any (`core.anim.slide`).
        extent = Split.eased(id, target);
        dvui.dataSet(null, id, "_size", chosen);
        // A leaf draws on regardless: it walks no tree node.
        if (init_opts.name.len > 0) _ = persistExtent(self, init_opts, id, chosen, extent);

        // Pin both ends. A minimum alone is only a floor, so a region whose content wants to be
        // wider than the size the user dragged it to simply stays wider, and the split appears to
        // stop responding once it reaches that content's natural width. Pinning the maximum too
        // makes the stored size exact and stops a plugin's content dictating the app's
        // proportions — the hazard `layout.zig` names in its sizing notes.
        //
        // The extent is the region's whole reach — its border edge to border edge, what a split
        // measures from the fixed edge to the pointer — so its own padding and border come out of
        // it before it becomes a content size. Taken as the content size, a place card's padding
        // was added on top: a split grabbed at rest jumped by the card's padding either side.
        box_opts.padding = foldedPadding(box_opts.paddingGet(), extent, axis);
        const content = @max(0, extent - alongAxis(box_opts.paddingGet(), axis) - alongAxis(box_opts.borderGet(), axis));
        box_opts.min_size_content = switch (axis) {
            .horizontal => .{ .w = content, .h = given.h },
            .vertical => .{ .w = given.w, .h = content },
        };
        box_opts.max_size_content = switch (axis) {
            .horizontal => .width(content),
            .vertical => .height(content),
        };
        if (parent) |p| {
            p.last_resizable = id;
            p.resizables.append(self.arena, id) catch {};
        }
        shut_now = extent <= 0;
    }

    if (!init_opts.resize) {
        // A stretchy region must not let its *contents* set a floor under it.
        //
        // dvui clamps a widget's reported min size with `max_size_content`, so capping it along
        // the parent's axis stops the plugin inside from reserving space the app never granted.
        // Without this the bottom panel cannot be dragged open past whatever the editor above it
        // wants to be — the neighbour's content, not the layout, decides how far a split travels.
        // The region clips anyway, so nothing escapes; it just stops pushing back.
        //
        // An explicit `max_size_content` from the shape wins: that is the app deciding, which is
        // the whole point.
        // Leftover tree leaves take remaining space via expand. They still need
        // this cap: without it a wide welcome (or any plugin) sets a floor, the
        // new pane is shoved to the far edge, and the sash cannot move.
        if (parent != null and opts.max_size_content == null) {
            const given = opts.min_size_content orelse dvui.Size{};
            box_opts.max_size_content = switch (axis) {
                .horizontal => .{ .w = @max(1, given.w), .h = dvui.max_float_safe },
                .vertical => .{ .w = dvui.max_float_safe, .h = @max(1, given.h) },
            };
        }

        // The base of this container: what it insists on keeping is what the trays must leave it.
        if (parent) |p| {
            const m = opts.min_size_content orelse dvui.Size{};
            const along = switch (axis) {
                .horizontal => m.w,
                .vertical => m.h,
            };
            if (along > p.base_min) p.base_min = along;
            p.saw_base = true;
        }
    }

    // Findable from outside the layout by the keywords it accepts — a rail button or a command
    // opening and shutting it, the settings pane listing where a panel can go. Every region that
    // hosts surfaces registers, resizable or not — a stretchy region like the main area must be
    // in the registry too, or the picker never offers it and its surfaces read as unplaced.
    // A leftover leaf that kept a minted name must not overwrite the pinned
    // subtree registered under that name — the parent sash still targets it.
    const leftover_leaf = init_opts.omit_edge != null and !init_opts.resize;
    if (keywords.len > 0 and !tree_origin and !leftover_leaf) self.state.registerRegion(self.gpa, .{
        .name = init_opts.name,
        .keywords = keywords,
        .shows = init_opts.shows,
        .id = id,
        .default_extent = default_extent,
        .by_name = init_opts.by_name,
        .kind_slot = init_opts.kind_slot,
        .resize = init_opts.resize,
        .forget_when_empty = init_opts.forget_when_empty,
        .dir = init_opts.dir,
        .on_drop = init_opts.on_drop,
        .drop_ctx = init_opts.drop_ctx,
    });

    // Split into panes last frame, the region hands its card to them (`pane_cards`): no fill and
    // no padding of its own, so the panes reach its edges and the gaps between them are clear.
    var card: ?dvui.Options = null;
    if (init_opts.pane_cards and (box_opts.background orelse false)) {
        if ((dvui.dataGet(null, id, "_panes", u8) orelse 0) >= 2) {
            card = .{
                .background = true,
                .color_fill = box_opts.color_fill,
                .corners = box_opts.corners,
                .padding = box_opts.padding,
            };
            box_opts.background = false;
            box_opts.padding = .{};
        }
    }

    const box = dvui.box(src, .{ .dir = init_opts.dir }, box_opts);
    if (init_opts.resize) Split.recordEdges(id, box.data(), axis);
    if (init_opts.name.len > 0) {
        self.state.setPlaceMetrics(init_opts.name, box.data());
        core.anchor.mark(box.data(), "region:{s}", .{init_opts.name});
    }
    self.containers[self.depth] = .{
        .dir = init_opts.dir,
        .box = box,
        // A place names the places inside it; a pure grouping box is not a place, so it hands its
        // own parent's name down unchanged. `slot` is a user tray, not a kind, so it does not
        // qualify the places inside it (`slot.slot` hid Clear/Remove).
        .prefix = placePrefix(keywords, if (parent) |p| p.prefix else ""),
        .card = card,
    };
    self.depth += 1;

    // A region clips what it holds. Contents draw at their own natural size, so without this a
    // region squeezed narrower than its contents simply spills them over its neighbour instead
    // of getting smaller — which is what a half-closed sidebar looked like.
    const clip_to = box.data().contentRectScale().r;
    const prev_clip = dvui.clip(clip_to);

    // A plugin region (`manual_contents`) draws its own chrome — workspace
    // tabs, the fileless welcome. The place picker lives on the shape region
    // that hosts the plugin (Main), not on every document pane inside it.
    // An empty workspace pane was otherwise treated as a vacant slot: the
    // grid button stayed up and a square ring sat on a box with no corners.
    if (init_opts.name.len > 0 and keywords.len > 0 and !shut_now and !init_opts.manual_contents)
        cornerButton(self, init_opts, keywords, box);

    const dragging_this = self.state.view_drag.active() and std.mem.eql(u8, self.state.view_drag.name, init_opts.name);

    // Drawn at every size except none. Skipping content at *zero* is just not doing work nobody
    // can see; skipping it below a threshold would be a policy, and it would also break the
    // layered form later — a tray blurring what is behind it needs the region underneath to have
    // drawn, at every size the tray takes.
    //
    // Photographed, when the drag needs the card's picture, from this very
    // draw and no other — see `drawContentsPhotographed`.
    if (!shut_now and keywords.len > 0 and !init_opts.manual_contents) {
        // The place keeps drawing its view while the card of it rides the pointer: the app
        // under a drag does not change, the drop zones lie over it (`cornerButton`).
        const shot = ViewDrag.shotWanted(self, dragging_this);

        if (shot.any()) {
            try drawContentsPhotographed(self, init_opts, keywords, clip_to, shot);
        } else {
            _ = try drawContents(self, init_opts, keywords);
        }
    }
    // The card riding the pointer is drawn over everything, with the drops (`ViewDrag.drawOverlay`).
    if (dragging_this) ViewDrag.tick(self);

    return .{
        .name = init_opts.name,
        .keywords = keywords,
        .shows = init_opts.shows,
        .id = id,
        .default_extent = default_extent,
        .box = box,
        .layout = self,
        .prev_clip = prev_clip,
        .by_name = init_opts.by_name,
        .kind_slot = init_opts.kind_slot,
        .resize = init_opts.resize,
        .pane_cards = init_opts.pane_cards,
    };
}

const corner_button_size: f32 = core.widgets.glass_button.size;
/// The corner at rest, in points: a small round bubble of glass this wide, tucked under the card's
/// top-right corner (`cornerPiece`).
const corner_piece: f32 = 16;
/// How far round the bubble the pointer is on it, in points: a bubble this small needs a margin.
const corner_reach_pt: f32 = 8;
/// A finger's target for the corner, in points: a square centred on the card's outer corner, so
/// half of it lies past the card, in the gutter, and only a quarter reaches into the place.
const corner_touch: f32 = 44;
/// How long a tap on the corner keeps the button up for a second tap, in milliseconds.
const corner_touch_ms: i32 = 3000;
/// The button's distance in from the place's corner: room for the glass's shadow ring.
const corner_inset: f32 = 8;

/// The small button in a region's top-right corner that opens the picker for it. This is the
/// piece that makes placement *visual*: a user looks at the place in the window they want to
/// change and finds the control there, rather than in a settings tree. It is framework, so
/// every region in every app has it without the shape writing anything.
///
/// Runs before the region's contents and renders after them (`RenderFrontToBack`): dvui gives
/// an event to the first widget that runs and paints the last one on top, and a corner button
/// under a scroll area needs both to be it.
///
/// An empty region shows the button always — there is nothing else to find it behind. A filled
/// one always shows its corner: a piece of glass filling the card's top-right corner, cut to its
/// curve, so a person can see the place can be arranged without the button lying on what the
/// place shows. Only the corner brings the button up — the piece itself turns into it, and back:
/// the pointer on it, or a tap on it, never a pointer or a touch merely near the corner (a control
/// there was covered by the button the press meant for it brought up). A tap keeps it up for a
/// second tap, which opens the picker, until `corner_touch_ms` pass or the next touch lands
/// anywhere else. Empty is a hatch, not a
/// ring: a ring on every vacant slot read as focus. A filled card still gets a rounded highlight
/// while its button is up.
///
/// Drag the button to lift the view: a card of it follows the pointer (grab offset preserved)
/// and every place it could land, this one included, shows its drop zones.
fn cornerButton(self: *Layout, opts: InitOptions, keywords: []const []const u8, box: *dvui.BoxWidget) void {
    const rs = box.data().borderRectScale();
    const mouse = dvui.currentWindow().mouse_pt;
    const picker_here = self.state.picker.is_open and std.mem.eql(u8, self.state.picker.region, opts.name);
    const filled = regionHasContent(self, opts, keywords);
    const dragging_this = self.state.view_drag.active() and std.mem.eql(u8, self.state.view_drag.name, opts.name);
    const id = box.data().id;
    const now = dvui.currentWindow().frame_time_ns;
    const corners = box.data().options.cornersGet().scale(rs.s, dvui.CornerRect.Physical);
    const piece = cornerPiece(rs, corners);
    // Where the button stands while it is up, physical: the pointer anywhere on it keeps it up.
    const crs = box.data().contentRectScale();
    const button_r: dvui.Rect.Physical = .{
        .x = crs.r.x + crs.r.w - (corner_button_size + corner_inset) * crs.s,
        .y = crs.r.y + corner_inset * crs.s,
        .w = corner_button_size * crs.s,
        .h = corner_button_size * crs.s,
    };
    // Whether the last press was a finger's: then where the pointer rests says nothing (it is
    // wherever the last touch was), and only a tap on the corner brings the button up.
    var touch = dvui.dataGet(null, id, "_chooser_touch", bool) orelse false;
    var tapped_until = dvui.dataGet(null, id, "_chooser_until", i128) orelse 0;
    const shown_before = (dvui.dataGet(null, id, "_chooser_shown", f32) orelse 0) > 0.01;
    for (dvui.events()) |*e| {
        if (e.evt != .mouse or e.handled) continue;
        const me = e.evt.mouse;
        if (me.action == .motion and !me.button.touch()) touch = false;
        if (me.action != .press or !me.button.pointer()) continue;
        touch = me.button.touch();
        if (!touch or !filled) continue;
        if (now < tapped_until) {
            // Up from a tap: a touch on the button is the button's; anywhere else puts it away.
            if (!button_r.contains(me.p)) tapped_until = 0;
        } else if (piece.touch.contains(me.p) and !core.dialogs.modalOverCurrent()) {
            // The first tap only brings the button up; the place under the corner never sees it.
            e.handle(@src(), box.data());
            tapped_until = now + @as(i128, corner_touch_ms) * std.time.ns_per_ms;
            dvui.timer(id, corner_touch_ms * 1000);
        }
    }
    if (tapped_until != 0 and now >= tapped_until) tapped_until = 0;
    dvui.dataSet(null, id, "_chooser_touch", touch);
    dvui.dataSet(null, id, "_chooser_until", tapped_until);
    const tapped = tapped_until != 0;
    // The pointer on the corner, or on the button it brought up. Not under a modal dialog, which
    // takes the press: the button lit and the click did nothing. The rect tests first, so the
    // subwindow walk runs only with the pointer at the corner.
    const hovered = !touch and (piece.hit.contains(mouse) or (shown_before and button_r.contains(mouse))) and
        !core.dialogs.modalOverCurrent();
    const pressing = dvui.dataGet(null, id, "_chooser_press", bool) orelse false;
    if (self.state.view_drag.active()) ViewDrag.tick(self);
    // Not while a view is carried: the button is the way to pick or lift a view, and over a drag
    // it came and went with every place the pointer crossed. (It still runs below — it is the
    // handle the drag of this place is held by.)
    const available = !self.state.view_drag.active() and (!filled or picker_here or hovered or tapped or pressing);
    const alpha = chooserFade(id, if (available) 1 else 0);
    // A filled place's corner, there whenever its button is not, but not over a drag (as the button).
    const resting = filled and !self.state.view_drag.active();

    if (alpha < 0.01 and !available and !resting and !dragging_this and !ViewDrag.zonesShowing(self, opts.name, id)) return;

    var ftb: dvui.RenderFrontToBack = undefined;
    ftb.init();
    defer ftb.deinit();

    // `corners` (above) are the box fill's — `finalize(theme)` turns `.all(r)` into the theme's
    // kind, and fizzy's theme is square, so the ring was a second square outline sitting on the
    // rounded card.
    const theme = dvui.themeGet();
    if (!filled) drawEmptyHatch(rs.r, rs.s);
    // In the same front-to-back pass as the contents' chrome: the glass lies on them.
    ViewDrag.drawZones(self, opts.name, box.data().id);
    // The ring says which place the chooser is for, so it has a fade of its own, driven only by
    // what asks that: the pointer at the corner, the picker open here, the button held. It
    // shared the button's, which a drag raises while it is over the place (`drop_here`) — and
    // at the release the ring, held off only by the drag, came on at the button's full alpha
    // for the frames that fade took to run down: a stroke flashed round the place a view landed in.
    // Held for the whole of a drag out of this place, so the place being carried from stays
    // marked — the only place a drag lights, and it goes out as the drag ends.
    // Not round a float that is a ghost of itself for the drag (`Floats`): nothing of the live
    // float shows, and the ring is drawn past the clip that hides the rest. Firm again, under the
    // view aimed back at it, it is marked as any place carried from is.
    const aside = if (self.state.floatRoot(opts.name)) |root| ViewDrag.ghosted(self, root) else false;
    const ring_wanted = filled and !aside and (dragging_this or (!self.state.view_drag.active() and (picker_here or hovered or tapped or pressing)));
    const ring_alpha = chooserFade(box.data().id.update("ring"), if (ring_wanted) 1 else 0);
    if (ring_alpha > 0.01) {
        // Under the region's own border rect, not the content clip `cornerButton` runs inside:
        // the ring is on the border, in the padding, so a region with padding (every card but
        // the explorer's) clipped it away entirely — only the explorer ever showed which place
        // its chooser was for. And inset by half its width, so all of it is inside that rect.
        const prev_clip = dvui.clipGet();
        dvui.clipSet(rs.r);
        defer dvui.clipSet(prev_clip);
        const half: f32 = 1.0;
        rs.r.insetAll(half).stroke(corners, .{ .color = .{ .color = theme.focus.opacity(ring_alpha) }, .thickness = 2 * half });
    }

    // The corner at rest. Its frost is the card's padding, which does not change: read once. While
    // the button is up, or on its way, the same piece of glass is drawn as it (below).
    if (resting and alpha < 0.01) {
        // Not under the content clip this runs in: the corner is in the card's padding, and that
        // clip cut its top and right off. The bubble may peek a little past the card's edges.
        const prev_clip = dvui.clipGet();
        dvui.clipSet(rs.r.outsetAll(corner_piece * rs.s / 2));
        defer dvui.clipSet(prev_clip);
        core.dialogs.glassBubbles(id.update("corner"), &.{.{ .rect = piece.r, .radii = piece.radii }}, rs.s, .{ .shadow = 0, .witness = core.widgets.glass_button.witness(piece.r, 0) });
        drawCornerGlyph(piece.r, rs.s, theme.color(.content, .text));
    }

    if (alpha < 0.01 and !pressing and !dragging_this) return;

    const content = box.data().contentRect();
    var bw: dvui.ButtonWidget = undefined;
    // `touch_drag`: this button is a handle — dragging it is how a view is moved. Without it
    // dvui takes a finger dragging past the threshold for a scroll, drops the capture and ends
    // the drag, so the chooser only ever moved under a mouse.
    bw.init(@src(), .{ .draw_focus = false, .touch_drag = true }, .{
        // Click for the layout picker; drag to move the view.
        .label = .{ .text = "Arrange" },
        .tab_index = 0,
        .rect = .{
            .x = content.w - corner_button_size - corner_inset,
            .y = corner_inset,
            .w = corner_button_size,
            .h = corner_button_size,
        },
        .padding = .all(0),
        .margin = .{},
        .corners = .round(corner_button_size / 2),
        .background = false,
        .border = .all(0),
        .box_shadow = null,
    });
    defer bw.deinit();
    bw.processEvents();

    var dragged = dragging_this;
    for (dvui.events()) |*e| {
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        const ours = dvui.captured(bw.data().id) or pressing or dragging_this or bw.matchEvent(e);
        if (!ours) continue;
        if (me.action == .press and me.button.pointer()) {
            e.handle(@src(), bw.data());
            dvui.captureMouse(bw.data(), e.num);
            dvui.dataSet(null, box.data().id, "_chooser_press", true);
            dvui.dragPreStart(me.button, me.p, .{
                .offset = rs.r.topLeft().diff(me.p),
                .size = rs.r.size(),
                .name = "fizzy_view",
                .cursor = ViewDrag.cursor,
            });
        }
        if (me.action == .motion and (dvui.captured(bw.data().id) or pressing)) {
            if (dvui.dragging(me.p, "fizzy_view") != null) {
                if (!self.state.view_drag.active()) ViewDrag.begin(self, opts.name, rs.r, bw.data().borderRectScale().r);
                dragged = true;
                dvui.refresh(null, @src(), null);
            }
        }
        if (me.action == .release and me.button.pointer()) {
            if (self.state.view_drag.active() and std.mem.eql(u8, self.state.view_drag.name, opts.name)) {
                ViewDrag.apply(self, opts.name, me.p);
                dragged = true;
            }
            self.state.view_drag.discard();
            dvui.dataRemove(null, box.data().id, "_chooser_press");
            dvui.captureMouse(null, e.num);
            dvui.dragEnd();
            // Whatever the release did — landed, or nothing (its own middle, off every place) —
            // the frame after it is different: the card is gone and the zones start to go. A
            // drag held still asks for no frames of its own, so this one has to be asked for.
            dvui.refresh(null, @src(), null);
        }
    }

    if (alpha > 0.01 and !dragged and !self.state.view_drag.active()) {
        // A glass bubble, as the controls over a document are (`core.widgets.glass_button`). Glass
        // has no opacity, so it fades by growing in from its centre, its shadow with it.
        const br = bw.data().borderRectScale();
        const light = core.widgets.glass_button.light(&bw);
        if (resting) {
            // A filled place's corner turns into the button: the one piece of glass, its rect and
            // corners carried from the corner's to the button's. Its frost is the view's own
            // content, read while it moves and shows.
            const m = cornerMorph(piece, br.r, alpha);
            const prev_clip = dvui.clipGet();
            dvui.clipSet(rs.r.outsetAll(corner_piece * rs.s / 2));
            defer dvui.clipSet(prev_clip);
            core.dialogs.glassBubbles(id.update("corner"), &.{.{ .rect = m.rect, .radii = m.radii, .light = light }}, br.s, .{ .shadow = alpha });
            drawCornerGlyph(m.rect, rs.s, theme.color(.content, .text).opacity(std.math.clamp(1 - 2 * alpha, 0, 1)));
        } else {
            // An empty place's button grows in from its centre (glass has no opacity) over its
            // hatch, which does not change: read the frost once.
            const grown = br.r.insetAll(br.r.w * (1 - alpha) / 2);
            core.dialogs.glassBubbles(bw.data().id, &.{.{ .rect = grown, .light = light }}, br.s, .{ .shadow = alpha, .witness = core.widgets.glass_button.witness(grown, 0) });
        }
        // White, tinted by the text colour: the icon cache tints a flat colour rather than baking
        // it, and every step of the fade (it comes and goes as a drag crosses a place) would
        // otherwise rasterize a new texture, two render-target switches a frame.
        core.icon.icon(@src(), "regions", icons.tvg.lucide.@"layout-grid", .{ .fill_color = .white, .stroke_color = .white }, .{
            .expand = .ratio,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 1, .h = 1 },
            .padding = .all(corner_button_size * 0.3 * alpha + (1 - alpha) * corner_button_size / 2),
            .color_text = .{ .color = theme.color(.content, .text).opacity(alpha) },
        });
    }
    if (bw.clicked() and !dragged) {
        dvui.dataSet(null, id, "_chooser_until", @as(i128, 0));
        self.state.openPicker(self.gpa, opts.name, bw.data().rectScale().r.toNatural().bottomLeft());
    }
}

/// A filled place's corner at rest (`cornerButton`), physical: the piece of glass, its corners
/// (top-left, top-right, bottom-right, bottom-left) and a finger's target for it.
const CornerPiece = struct {
    r: dvui.Rect.Physical,
    radii: [4]f32,
    /// Where the pointer is on it: the bubble and a margin round it.
    hit: dvui.Rect.Physical,
    touch: dvui.Rect.Physical,
};

/// The piece is a small round bubble tucked under the card's top-right corner: its centre on
/// the corner's curve, halfway round it, so half of it lies over the card and half peeks out past
/// the curve, as if from behind it.
fn cornerPiece(rs: dvui.RectScale, corners: dvui.CornerRect.Physical) CornerPiece {
    const card = corners.tr.radius();
    const d = corner_piece * rs.s;
    // The curve's centre, and the point on it halfway round, toward the card's corner. A square
    // card (no curve) has its bubble on the corner itself.
    const cx = rs.r.x + rs.r.w - card + card * std.math.sqrt1_2;
    const cy = rs.r.y + card - card * std.math.sqrt1_2;
    var r: dvui.Rect.Physical = .{ .x = cx - d / 2, .y = cy - d / 2, .w = d, .h = d };
    // Whole inside the window: a card running to the window's edge (square, or maximized) would
    // have the half that peeks out cut off by it.
    const win = dvui.windowRectPixels();
    r.x = std.math.clamp(r.x, win.x, win.x + win.w - d);
    r.y = std.math.clamp(r.y, win.y, win.y + win.h - d);
    const half = corner_touch / 2 * rs.s;
    return .{
        .r = r,
        .radii = @splat(d / 2),
        .hit = r.outsetAll(corner_reach_pt * rs.s),
        .touch = .{ .x = rs.r.x + rs.r.w - half, .y = rs.r.y - half, .w = 2 * half, .h = 2 * half },
    };
}

/// The piece on its way to being the button at `button` (physical), `t` of the way (0 the corner,
/// 1 the button): rect and corners carried across together, round at the end.
fn cornerMorph(piece: CornerPiece, button: dvui.Rect.Physical, t: f32) struct { rect: dvui.Rect.Physical, radii: ?[4]f32 } {
    const k = std.math.clamp(t, 0, 1);
    const rect: dvui.Rect.Physical = .{
        .x = std.math.lerp(piece.r.x, button.x, k),
        .y = std.math.lerp(piece.r.y, button.y, k),
        .w = std.math.lerp(piece.r.w, button.w, k),
        .h = std.math.lerp(piece.r.h, button.h, k),
    };
    if (k > 0.99) return .{ .rect = rect, .radii = null };
    const round = @min(button.w, button.h) / 2;
    var radii: [4]f32 = undefined;
    for (&radii, piece.radii) |*r, from| r.* = std.math.lerp(from, round, k);
    return .{ .rect = rect, .radii = radii };
}

/// The corner's glyph: the button's grid, small, as four filled squares (an icon at this size is a
/// few pixels of texture, and redrawn each step of the turn), in the middle of the bubble.
fn drawCornerGlyph(piece: dvui.Rect.Physical, scale: f32, color: dvui.Color) void {
    const cell = 2 * scale;
    const gap = 1.25 * scale;
    const side = 2 * cell + gap;
    if (piece.w < side + 3 * scale or color.a == 0) return;
    const x0 = piece.x + piece.w / 2 - side / 2;
    const y0 = piece.y + piece.h / 2 - side / 2;
    for ([_][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } }) |at| {
        const sq: dvui.Rect.Physical = .{ .x = x0 + at[0] * (cell + gap), .y = y0 + at[1] * (cell + gap), .w = cell, .h = cell };
        sq.fill(.all(0.6 * scale), .{ .color = .{ .color = color }, .fade = 1 });
    }
}

fn regionHasContent(self: *Layout, opts: InitOptions, keywords: []const []const u8) bool {
    const probe: Region = .{ .name = opts.name, .keywords = keywords, .by_name = opts.by_name };
    if (self.matchingIn(&probe).len > 0) return true;
    if (!opts.by_name and self.matching(keywords).len > 0) return true;
    if (self.state.assignment(opts.name)) |ids| return ids.len > 0;
    return false;
}

const chooser_fade_ms: i32 = 160;

fn chooserFade(id: dvui.Id, want: f32) f32 {
    const anim_key = "_chooser";
    const shown_key = "_chooser_shown";
    if (dvui.animationGet(id, anim_key)) |a| {
        const v = std.math.clamp(a.value(), 0, 1);
        if (@abs(a.end_val - want) > 0.001) {
            dvui.animation(id, anim_key, .{
                .start_val = v,
                .end_val = want,
                .end_time = core.motion.duration(chooser_fade_ms * std.time.us_per_ms),
                .easing = core.motion.fade,
            });
        }
        dvui.dataSet(null, id, shown_key, v);
        return v;
    }
    const shown = dvui.dataGet(null, id, shown_key, f32) orelse 0;
    if (@abs(shown - want) > 0.001) {
        dvui.animation(id, anim_key, .{
            .start_val = shown,
            .end_val = want,
            .end_time = core.motion.duration(chooser_fade_ms * std.time.us_per_ms),
            .easing = core.motion.fade,
        });
        dvui.refresh(null, @src(), id);
        return shown;
    }
    return shown;
}

/// A vacant place: diagonal strokes rather than a ring, because a ring on
/// every empty slot reads as focus. Also the pane a self-split is about to
/// open, which is vacant for the same reason and should look the same.
pub fn drawEmptyHatch(bounds: dvui.Rect.Physical, scale: f32) void {
    if (bounds.w <= 0 or bounds.h <= 0) return;
    const prev = dvui.clipGet();
    dvui.clipSet(prev.intersect(bounds));
    defer dvui.clipSet(prev);

    const color = dvui.themeGet().color(.control, .text).opacity(0.10);
    const step = @max(8.0, 11.0 * scale);
    const span = bounds.w + bounds.h;
    var x = bounds.x - bounds.h;
    while (x < bounds.x + bounds.w) : (x += step) {
        var path: dvui.Path.Builder = .init(dvui.currentWindow().lifo());
        path.addPoint(.{ .x = x, .y = bounds.y + bounds.h });
        path.addPoint(.{ .x = x + span, .y = bounds.y + bounds.h - span });
        path.build().stroke(.{ .color = .{ .color = color }, .thickness = @max(1.0, scale) });
        path.deinit();
    }
}

/// Draw this place's contents *once*, into a texture, and blit those same
/// pixels back to the screen.
///
/// The drag needs a still of the lifted view for the floating card. A second
/// `drawContents` in the same frame would build every widget under the place
/// twice (dvui reports a duplicate id for each), so one draw serves both: the
/// screen sees a photograph of itself, which is the same picture.
fn drawContentsPhotographed(
    self: *Layout,
    opts: InitOptions,
    keywords: []const []const u8,
    rect: dvui.Rect.Physical,
    shot: ViewDrag.Shot,
) !void {
    // The frame as last drawn, when there is one (`ViewDrag.photographFromFrame`): no capture,
    // so the place draws as usual and does not flash.
    if (shot.card and ViewDrag.photographFromFrame(self, rect)) {
        _ = try drawContents(self, opts, keywords);
        return;
    }
    // No texture targets (web) or nothing to capture: the card goes without
    // its picture (it draws as a plain card), and the place draws as usual.
    var pic = core.anim.CrossFade.beginCapture(rect) orelse {
        _ = try drawContents(self, opts, keywords);
        return;
    };
    const prev_clip = dvui.clip(rect);
    _ = try drawContents(self, opts, keywords);
    dvui.clipSet(prev_clip);
    ViewDrag.keepShot(self, shot, &pic);
}

/// Remember the extent of the place `opts` names, or forget the place when it has closed with
/// nothing in it. Returns true when it forgot it: the split tree no longer has it, and the nodes
/// a caller is walking to draw it may be gone, so it draws nothing more of it this frame.
fn persistExtent(self: *Layout, opts: InitOptions, id: dvui.Id, chosen: f32, shown: f32) bool {
    _ = shown;
    // A live drag writes a zero on the way through closed; forgetting here removes the
    // region and the next frame recreates a sentinel under the pointer — the pop.
    const dragging = dvui.dataGet(null, id, "_drag", bool) orelse false;
    if (opts.forget_when_empty and !dragging and chosen <= 0) forget: {
        // A place split again is every place in it (`SplitTree.Forest.collapse`): kept while any
        // of them holds a view, and all of them forgotten with it.
        const covered = self.state.splits.placeLeaves(self.arena, opts.name);
        for (covered) |n| {
            if (self.state.assignment(n)) |ids| if (ids.len > 0) break :forget;
        }
        // Still travelling shut: collapsing here drops the leaf and the
        // next frame has nothing to ease. `shown` can rest above zero
        // after the curve, so "animation finished" is the real signal.
        if (dvui.animationGet(id, "_ease") != null) {
            if (self.state.setExtent(self.gpa, opts.name, 0)) self.extents_changed = true;
            return false;
        }
        const dropped = self.state.splits.collapse(self.gpa, opts.name);
        if (dropped) self.extents_changed = true;
        for (covered) |n| {
            if (self.state.clearExtent(self.gpa, n)) self.extents_changed = true;
            self.state.unassign(self.gpa, n);
        }
        dvui.refresh(null, @src(), id);
        return dropped;
    }
    if (self.state.setExtent(self.gpa, opts.name, chosen)) self.extents_changed = true;
    return false;
}

/// The region's contents: its own chrome if it declared any, otherwise the active surface.
///
/// Everything reachable here is reachable by hand from `matching` / `selected` / `draw`, so a
/// shape wanting something else writes its own function and passes it as `content`.
/// `keywords` rather than `opts.keywords`: chrome is handed the region's *qualified* set, so a
/// tab strip inside a sub-region lists what that sub-region accepts and not what its kind accepts
/// everywhere in the app.
fn drawContents(self: *Layout, opts: InitOptions, keywords: []const []const u8) !dvui.App.Result {
    if (opts.content) |content| return content.draw(content.ctx, self, keywords);
    const shows = if (opts.name.len > 0) self.state.showsOf(opts.name, opts.shows) else opts.shows;
    const place: Region = .{
        .name = opts.name,
        .keywords = keywords,
        .by_name = opts.by_name,
        .shows = shows,
    };
    // Multiple is a place setting: the chooser is the place's, not something
    // each surface or the shape has to draw.
    if (shows == .many) return self.tabbedIn(&place);
    if (opts.by_name) return self.drawSelectedIn(&place);
    return self.drawSelected(keywords);
}

fn nameExtra(name: []const u8) usize {
    return @truncate(std.hash.Wyhash.hash(0x51a7, name));
}

fn extraFor(name: []const u8, side: SplitTree.Side) usize {
    return @truncate(nameExtra(name) ^ @as(u64, @backingInt(side)) << 8);
}

fn idOf(state: *Layout.State, name: []const u8) ?dvui.Id {
    for (state.regions_building.items) |r| {
        if (r.id != .zero and std.mem.eql(u8, r.name, name)) return r.id;
    }
    for (state.regions.items) |r| {
        if (r.id != .zero and std.mem.eql(u8, r.name, name)) return r.id;
    }
    return null;
}

fn initTree(
    self: *Layout,
    src: std.builtin.SourceLocation,
    init_opts: InitOptions,
    opts: dvui.Options,
    node: *SplitTree.Node,
) anyerror!Region {
    const parent: ?*Layout.Container = if (self.depth == 0) null else &self.containers[self.depth - 1];
    const axis: dvui.enums.Direction = if (parent) |p| p.dir else .horizontal;
    const id = dvui.parentGet().extendId(src, opts.idExtra());
    const keywords = regionKeywords(self, if (parent) |p| p.prefix else "", init_opts.keywords);

    if (init_opts.resize) self.drawPendingSplit(id) else self.drawPendingSplit(null);

    const branch = node.kind.branch;
    var box_opts = opts;
    var default_extent: f32 = 0;
    // Forgotten this frame, the tree `branch` points into may be freed: its children wait for
    // the next frame (`persistExtent` asked for it).
    var dropped = false;
    if (init_opts.resize) {
        const given = opts.min_size_content orelse dvui.Size{};
        const default: f32 = switch (axis) {
            .horizontal => given.w,
            .vertical => given.h,
        };
        default_extent = default;
        if (dvui.dataGet(null, id, "_size", f32) == null) {
            dvui.dataSet(null, id, "_size", self.state.extent(init_opts.name, default));
        }
        const chosen = dvui.dataGet(null, id, "_size", f32) orelse default;
        var target = chosen;
        if (init_opts.collapsible) {
            target = collapseTarget(id, chosen, if (parent) |p| p.extent(axis) else 0);
        }
        const extent = Split.eased(id, target);
        dvui.dataSet(null, id, "_size", chosen);
        if (init_opts.name.len > 0) dropped = persistExtent(self, init_opts, id, chosen, extent);
        box_opts.min_size_content = switch (axis) {
            .horizontal => .{ .w = extent, .h = given.h },
            .vertical => .{ .w = given.w, .h = extent },
        };
        box_opts.max_size_content = switch (axis) {
            .horizontal => .width(extent),
            .vertical => .height(extent),
        };
        if (parent) |p| {
            p.last_resizable = id;
            p.resizables.append(self.arena, id) catch {};
        }
    } else if (parent != null and opts.max_size_content == null) {
        const given = opts.min_size_content orelse dvui.Size{};
        box_opts.max_size_content = switch (axis) {
            .horizontal => .{ .w = @max(1, given.w), .h = dvui.max_float_safe },
            .vertical => .{ .w = dvui.max_float_safe, .h = @max(1, given.h) },
        };
        if (parent) |p| {
            const m = opts.min_size_content orelse dvui.Size{};
            const along = switch (axis) {
                .horizontal => m.w,
                .vertical => m.h,
            };
            if (along > p.base_min) p.base_min = along;
            p.saw_base = true;
        }
    }

    // Grouping is only the axis. Fill and padding stay on the leaves so a
    // sash is a gap between cards, and a region's padding insets the
    // plugin surface, not the handle.
    box_opts.background = false;
    box_opts.corners = null;
    box_opts.padding = .{};
    const box = dvui.box(src, .{ .dir = branch.dir }, box_opts);
    if (init_opts.resize) Split.recordEdges(id, box.data(), axis);

    if (keywords.len > 0) self.state.registerRegion(self.gpa, .{
        .name = init_opts.name,
        .keywords = keywords,
        .shows = init_opts.shows,
        .id = id,
        .default_extent = default_extent,
        .by_name = init_opts.by_name,
        .kind_slot = init_opts.kind_slot,
        .dir = init_opts.dir,
    });

    self.containers[self.depth] = .{
        .dir = branch.dir,
        .box = box,
        .prefix = placePrefix(keywords, if (parent) |p| p.prefix else ""),
    };
    self.depth += 1;

    if (!dropped) try drawTreeChildren(self, src, init_opts, opts, branch);

    return .{
        .name = init_opts.name,
        .keywords = keywords,
        .shows = init_opts.shows,
        .id = id,
        .box = box,
        .layout = self,
        .default_extent = default_extent,
        .by_name = init_opts.by_name,
        .kind_slot = init_opts.kind_slot,
        .resize = init_opts.resize,
    };
}

fn drawTreeChildren(
    self: *Layout,
    src: std.builtin.SourceLocation,
    shape: InitOptions,
    shape_opts: dvui.Options,
    branch: SplitTree.Branch,
) anyerror!void {
    const omit_a: SplitTree.Side = switch (branch.dir) {
        .horizontal => .right,
        .vertical => .bottom,
    };
    const omit_b: SplitTree.Side = switch (branch.dir) {
        .horizontal => .left,
        .vertical => .top,
    };
    const leftover_a = !SplitTree.newIsLeading(branch.side);
    const leftover_b = SplitTree.newIsLeading(branch.side);
    try drawTreeNode(self, src, shape, shape_opts, branch.a, omit_a, leftover_a);
    if (self.depth > 0) self.containers[self.depth - 1].saw_base = true;
    packTreeSplit(self, src, branch);
    try drawTreeNode(self, src, shape, shape_opts, branch.b, omit_b, leftover_b);
}

fn packTreeSplit(self: *Layout, src: std.builtin.SourceLocation, branch: SplitTree.Branch) void {
    const new_name = SplitTree.newNameOf(branch);
    const leading = SplitTree.newIsLeading(branch.side);
    const sign: f32 = if (leading) 1 else -1;
    const target = if (leading)
        (if (self.depth > 0) self.containers[self.depth - 1].last_resizable else null) orelse
            idOf(self.state, new_name) orelse return
    else
        dvui.parentGet().extendId(src, nameExtra(new_name));
    // Own `@src()`, not the place's: the grouping box already used that
    // source line, and a packed handle with the same id paints a red
    // duplicate and never settles.
    self.packSplitSized(@src(), extraFor(new_name, branch.side), target, sign, .{ .push_out = true }, sashWidth(self, new_name, target));
}

/// How wide the sash beside `name` is this frame.
///
/// Full width nearly always: a place dragged shut keeps its sash, because that is the handle you
/// drag it back out by, and several shut places in a row read as the several handles they are.
/// A place on its way *out* is the exception — emptied, its extent sent to zero, waiting for the
/// curve to finish before the leaf is dropped. Its sash is 10pt that the pair keeps until the
/// drop and loses in a single frame at the end, which is the step the eye reads as a pop after
/// an otherwise smooth close. Following the place down costs nothing to grab, because in a
/// moment there will be nothing to grab.
fn sashWidth(self: *Layout, name: []const u8, target: dvui.Id) f32 {
    const kept = if (self.state.assignment(name)) |ids| ids.len > 0 else false;
    if (kept or Split.sizeOf(target) > 0) return Split.handle_size;
    const shown = dvui.dataGet(null, target, "_shown", f32) orelse 0;
    return std.math.clamp(shown, 0, Split.handle_size);
}

/// Card chrome for a tree leaf. Padding insets the plugin surface inside
/// the card. Margin is not copied: a sash-facing margin is how handles
/// used to pick up extra space on one side.
/// What a place looks like, read off the place itself, so a pane a preview
/// opens is dressed like the pane that will be there.
/// A card's padding, folded away over the last stretch of a close.
///
/// Padding is room the place takes up, so a card closed to nothing is still as wide as its own
/// inset — 16pt of stripe that sits there until something removes the place, and then goes in
/// one frame. Once the extent is under the inset the place is narrower than the gap it wants to
/// keep inside itself, which is the point at which the inset stops meaning anything; from there
/// it comes in proportionally, so nothing reaches nothing.
///
/// Only along the parent's axis. The cross axis is not closing.
/// What `r` (a padding or border) takes along `axis`: both of its sides that way.
fn alongAxis(r: dvui.Rect, axis: dvui.enums.Direction) f32 {
    return switch (axis) {
        .horizontal => r.x + r.w,
        .vertical => r.y + r.h,
    };
}

fn foldedPadding(p: dvui.Rect, extent: f32, axis: dvui.enums.Direction) dvui.Rect {
    const along = switch (axis) {
        .horizontal => p.x + p.w,
        .vertical => p.y + p.h,
    };
    if (along <= 0 or extent >= along) return p;
    const f = @max(0, extent) / along;
    return switch (axis) {
        .horizontal => .{ .x = p.x * f, .y = p.y, .w = p.w * f, .h = p.h },
        .vertical => .{ .x = p.x, .y = p.y * f, .w = p.w, .h = p.h * f },
    };
}

/// `given`, wearing the layout's card where the region asks for it (`InitOptions.card`) and does not
/// set that part of it itself.
fn withCard(self: *const Layout, init_opts: InitOptions, given: dvui.Options) dvui.Options {
    if (!init_opts.card) return given;
    const card = self.card orelse return given;
    var o = given;
    if (o.background == null) o.background = card.background;
    if (o.color_fill == null) o.color_fill = card.color_fill;
    if (o.corners == null) o.corners = card.corners;
    if (o.padding == null) o.padding = card.padding;
    return o;
}

fn placeVisual(opts: dvui.Options) dvui.Options {
    return .{
        .background = opts.background,
        .color_fill = opts.color_fill,
        .corners = opts.corners,
        .padding = opts.padding,
    };
}

fn drawTreeNode(
    self: *Layout,
    src: std.builtin.SourceLocation,
    shape: InitOptions,
    shape_opts: dvui.Options,
    node: *SplitTree.Node,
    omit: SplitTree.Side,
    leftover: bool,
) anyerror!void {
    switch (node.kind) {
        .leaf => |name| {
            var o = shape;
            var child_opts = placeVisual(shape_opts);
            child_opts.expand = .both;
            child_opts.id_extra = nameExtra(name);
            if (leftover) {
                if (!std.mem.eql(u8, name, shape.name)) {
                    o = .{
                        .name = name,
                        .keywords = Layout.slot_keywords,
                        .by_name = true,
                        .resize = false,
                        .forget_when_empty = true,
                        .omit_edge = omit,
                    };
                } else {
                    o.resize = false;
                    o.omit_edge = omit;
                    o.by_name = true;
                    // A leftover Panel must still draw — hiding it leaves a
                    // hole with no sash, no card, and no corner control.
                    o.hide_when_empty = false;
                }
            } else {
                o = .{
                    .name = name,
                    .keywords = Layout.slot_keywords,
                    .by_name = true,
                    .resize = true,
                    .forget_when_empty = true,
                    .omit_edge = omit,
                };
                const ext = self.state.extent(name, 0);
                const dir = if (self.depth > 0) self.containers[self.depth - 1].dir else .horizontal;
                child_opts.min_size_content = switch (dir) {
                    .horizontal => .{ .w = ext },
                    .vertical => .{ .h = ext },
                };
                child_opts.expand = switch (dir) {
                    .horizontal => .vertical,
                    .vertical => .horizontal,
                };
            }
            var r = try init(self, src, o, child_opts);
            r.deinit();
        },
        .branch => |b| {
            if (self.depth >= Layout.max_nesting) return;
            const parent_dir = if (self.depth > 0) self.containers[self.depth - 1].dir else .horizontal;
            // Same extra as the leaf this branch replaced, so the parent sash
            // keeps the widget it was already dragging.
            var box_opts: dvui.Options = .{
                .expand = .both,
                .id_extra = nameExtra(b.origin),
                .background = false,
            };
            if (!leftover) {
                const id = dvui.parentGet().extendId(src, nameExtra(b.origin));
                const default = self.state.extent(b.origin, 0);
                if (dvui.dataGet(null, id, "_size", f32) == null) {
                    dvui.dataSet(null, id, "_size", default);
                }
                const chosen = dvui.dataGet(null, id, "_size", f32) orelse default;
                const shown = Split.eased(id, chosen);
                dvui.dataSet(null, id, "_size", chosen);
                // Forgotten, its nodes are freed with it: nothing more of it to draw this frame.
                if (persistExtent(self, .{ .name = b.origin, .forget_when_empty = true }, id, chosen, shown)) return;
                box_opts.min_size_content = switch (parent_dir) {
                    .horizontal => .{ .w = shown },
                    .vertical => .{ .h = shown },
                };
                box_opts.max_size_content = switch (parent_dir) {
                    .horizontal => .width(shown),
                    .vertical => .height(shown),
                };
                box_opts.expand = switch (parent_dir) {
                    .horizontal => .vertical,
                    .vertical => .horizontal,
                };
                if (self.depth > 0) {
                    const p = &self.containers[self.depth - 1];
                    p.last_resizable = id;
                    p.resizables.append(self.arena, id) catch {};
                }
            }
            const box = dvui.box(src, .{ .dir = b.dir }, box_opts);
            if (!leftover) {
                const id = box.data().id;
                Split.recordEdges(id, box.data(), parent_dir);
                self.state.registerRegion(self.gpa, .{
                    .name = b.origin,
                    .keywords = Layout.slot_keywords,
                    .id = id,
                    .by_name = true,
                    .forget_when_empty = true,
                    .dir = b.dir,
                });
                self.state.setPlaceMetrics(b.origin, box.data());
            }
            self.containers[self.depth] = .{
                .dir = b.dir,
                .box = box,
                .prefix = if (self.depth > 0) self.containers[self.depth - 1].prefix else "",
            };
            self.depth += 1;
            try drawTreeChildren(self, src, shape, shape_opts, b);
            self.depth -= 1;
            box.deinit();
        },
    }
}

fn isSlotKeywords(keywords: []const []const u8) bool {
    return keywords.len == 1 and std.mem.eql(u8, keywords[0], Layout.slot_keywords[0]);
}

fn regionKeywords(self: *Layout, prefix: []const u8, base: []const []const u8) []const []const u8 {
    // `slot` is a user tray, not a kind. Qualifying it under Main hid Remove
    // (`main.slot`) the same way `slot.slot` did in endless.
    if (isSlotKeywords(base)) return base;
    return self.state.qualify(self.gpa, prefix, base);
}

fn placePrefix(keywords: []const []const u8, parent_prefix: []const u8) []const u8 {
    if (keywords.len == 0) return parent_prefix;
    if (isSlotKeywords(keywords)) return parent_prefix;
    return keywords[0];
}

/// Draw a region into an already-open box — `init` minus geometry. Keyword qualification,
/// registry, corner button, contents. The box is the caller's (a dockspace leaf cell).
pub fn fillInBox(self: *Layout, init_opts: InitOptions, box: *dvui.BoxWidget) !void {
    const parent: ?*Layout.Container = if (self.depth == 0) null else &self.containers[self.depth - 1];
    const keywords = regionKeywords(self, if (parent) |p| p.prefix else "", init_opts.keywords);

    if (keywords.len > 0) self.state.registerRegion(self.gpa, .{
        .name = init_opts.name,
        .keywords = keywords,
        .shows = init_opts.shows,
        .id = box.data().id,
        .by_name = init_opts.by_name,
        .kind_slot = init_opts.kind_slot,
        .forget_when_empty = init_opts.forget_when_empty,
        .dir = init_opts.dir,
    });

    self.state.setPlaceMetrics(init_opts.name, box.data());

    if (self.depth >= Layout.max_nesting) return;
    self.containers[self.depth] = .{
        .dir = init_opts.dir,
        .box = box,
        .prefix = placePrefix(keywords, if (parent) |p| p.prefix else ""),
    };
    self.depth += 1;
    defer {
        self.depth -= 1;
        self.containers[self.depth].box = null;
    }

    const clip_to = box.data().contentRectScale().r;
    const prev_clip = dvui.clip(clip_to);
    defer dvui.clipSet(prev_clip);

    if (init_opts.name.len > 0 and keywords.len > 0 and !init_opts.manual_contents)
        cornerButton(self, init_opts, keywords, box);
    if (keywords.len > 0 and !init_opts.manual_contents)
        _ = try drawContents(self, init_opts, keywords);
}

/// Divide `name` on `axis`, keeping its view and opening an empty place beside
/// it on the trailing side. `axis` is the layout direction — `.horizontal` is a
/// vertical divider (side by side), which is what the picker's Split menu names.
pub fn splitNamed(self: *Layout, name: []const u8, axis: dvui.enums.Direction) void {
    const side: SplitTree.Side = switch (axis) {
        .horizontal => .right,
        .vertical => .bottom,
    };
    _ = splitOn(self, name, side);
}

/// Divide `name` from `side`. Returns the minted leaf, or null if the place
/// is too small or is not a leaf. A view-drag drop uses this so a left or
/// top edge can open on that side, not only the trailing one.
pub fn splitOn(self: *Layout, name: []const u8, side: SplitTree.Side) ?[]const u8 {
    // A float is no leaf of a shape's seed tree: its splits live in the split forest, whatever
    // the shape below it is built from.
    if (self.state.floatRoot(name) == null) {
        if (self.state.dock) |*dock| return splitDock(self, dock, name, side);
    }
    return splitOnSized(self, name, side, ViewDrag.placeSize(self.state, name) orelse return null, 0.5);
}

/// `splitOn` for a place of `size` that need not have been drawn yet — a split of a half another
/// split made this frame, as a saved arrangement is rebuilt — with `share` of it for the new half.
/// Only the split forest's: a seed's dock tree splits its own drawn leaves (`splitOn`).
pub fn splitOnSized(self: *Layout, name: []const u8, side: SplitTree.Side, size: dvui.Size, share: f32) ?[]const u8 {
    const span = switch (SplitTree.axisOf(side)) {
        .horizontal => size.w,
        .vertical => size.h,
    };
    if (span < 8) return null;
    const intern = struct {
        var state: *Layout.State = undefined;
        fn go(gpa: std.mem.Allocator, n: []const u8) []const u8 {
            return state.internName(gpa, n);
        }
    };
    intern.state = self.state;
    // Halved the way the preview halves it — the sash out of the middle, both
    // sides the same — so what slid open is the size that lands.
    const want = @max(1, (span - Split.handle_size) * std.math.clamp(share, 0, 1));
    const new = self.state.splits.split(self.gpa, intern.go, name, side, want, null) orelse return null;
    if (self.state.setExtent(self.gpa, new, want)) self.extents_changed = true;
    self.state.assign(self.gpa, new, &.{}) catch {};
    self.state.requestSlideOpen(new);
    self.state.markDirty();
    dvui.refresh(null, @src(), null);
    return new;
}

fn splitDock(
    self: *Layout,
    dock: *core.widgets.DockLayout,
    name: []const u8,
    side: SplitTree.Side,
) ?[]const u8 {
    const size = ViewDrag.placeSize(self.state, name) orelse dvui.Size{ .w = 400, .h = 400 };
    const span = switch (SplitTree.axisOf(side)) {
        .horizontal => size.w,
        .vertical => size.h,
    };
    if (span < 8) return null;

    const leaf_idx = dock.findPanel(name) orelse return null;
    if (dock.nodes.items[leaf_idx] != .leaf) return null;

    const dock_side: core.widgets.DockLayout.Side = switch (side) {
        .left => .left,
        .right => .right,
        .top => .top,
        .bottom => .bottom,
    };
    var buf: [128]u8 = undefined;
    const raw = @import("Seed.zig").mintName(dock, name, dock_side, &buf) orelse return null;
    const interned = self.state.internName(self.gpa, raw);
    const panel = self.gpa.dupe(u8, interned) catch return null;
    dock.splitLeaf(leaf_idx, dock_side, panel) catch {
        self.gpa.free(panel);
        return null;
    };
    self.state.assign(self.gpa, interned, &.{}) catch {};
    self.state.markDirty();
    dvui.refresh(null, @src(), null);
    return interned;
}
