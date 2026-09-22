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
/// A tray the next split should keep targeting. Center and grouping boxes are not.
resize: bool = false,
/// An empty closed tray can disappear — a runtime split, an endless edge.
forget_when_empty: bool = false,
/// How this place lays its children.
dir: dvui.enums.Direction = .vertical,
/// This frame's content size, in points. A menu split halves one axis.
size: dvui.Size = .{},
/// This frame's border in physical pixels, for hit-testing a view drag.
bounds: dvui.Rect.Physical = .{},

/// The key this region's selection lives under in the host — see `Layout.selectedIn`.
pub fn selectionKey(self: *const Region) u64 {
    const group = sdk.keywords.groupKey(self.keywords);
    if (!self.by_name) return group;
    return group ^ std.hash.Wyhash.hash(0x51a7, self.name);
}

pub fn deinit(self: *Region) void {
    // Plugin panes skip the corner button, so a retracting slide has to
    // paint here — still clipped — after their own chrome has drawn.
    if (self.kind_slot) {
        if (self.layout) |l| {
            if (ViewDrag.previewOn(l, self.name)) {
                if (self.box) |b| {
                    const rs = b.data().borderRectScale();
                    ViewDrag.drawHint(l, self.name, rs.r, rs.s, cardOf(b));
                }
            }
        }
    }
    if (self.prev_clip) |c| dvui.clipSet(c);
    if (self.box) |b| {
        if (self.layout) |l| {
            std.debug.assert(l.depth > 0);
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
/// case CLAUDE.md calls a bug in `Layout` rather than a special case: a shape is supposed to be
/// ordinary code over this API, and an app copying `src/editor/layout.zig` could not have written those two
/// values itself. As a function pointer they are just `explorerPane` and `bottomPane` in
/// `src/editor/layout.zig` — app code, passed in, replaceable by the app's own loop over `matching` /
/// `selected` / `draw`, which is the governing test for everything here.
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
pub fn init(self: *Layout, src: std.builtin.SourceLocation, init_opts: InitOptions, opts: dvui.Options) anyerror!Region {
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
    const matches = self.matchingStored(&probe);
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
        const default: f32 = switch (axis) {
            .horizontal => given.w,
            .vertical => given.h,
        };
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
        if (init_opts.name.len > 0) persistExtent(self, init_opts, id, chosen, extent);

        // Pin both ends. A minimum alone is only a floor, so a region whose content wants to be
        // wider than the size the user dragged it to simply stays wider, and the split appears to
        // stop responding once it reaches that content's natural width. Pinning the maximum too
        // makes the stored size exact and stops a plugin's content dictating the app's
        // proportions — the hazard `layout.zig` names in its sizing notes.
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
        box_opts.padding = foldedPadding(box_opts.paddingGet(), extent, axis);
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
        .forget_when_empty = init_opts.forget_when_empty,
        .dir = init_opts.dir,
    });

    // A previewed split is laid out, not drawn over: the place really pulls
    // back to the half it would keep, so the arrangement under the pointer is
    // the one the release produces. `ViewDrag.pullBack` explains why this is a
    // margin and not a child box.
    if (init_opts.name.len > 0) {
        if (ViewDrag.previewPlan(self, init_opts.name)) |p| switch (p) {
            .swap => {},
            .split => |s| ViewDrag.pullBack(self, init_opts.name, &box_opts, s.mint, axis, init_opts.resize),
        };
    }

    const box = dvui.box(src, .{ .dir = init_opts.dir }, box_opts);
    if (init_opts.resize) Split.recordEdges(id, box.data(), axis);
    if (init_opts.name.len > 0) {
        const cr = box.data().contentRect();
        self.state.setPlaceMetrics(init_opts.name, .{ .w = cr.w, .h = cr.h }, box.data().borderRectScale().r);
    }
    self.containers[self.depth] = .{
        .dir = init_opts.dir,
        .box = box,
        // A place names the places inside it; a pure grouping box is not a place, so it hands its
        // own parent's name down unchanged. `slot` is a user tray, not a kind, so it does not
        // qualify the places inside it (`slot.slot` hid Clear/Remove).
        .prefix = placePrefix(keywords, if (parent) |p| p.prefix else ""),
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
    // Photographed, when the drag needs a still, from this very draw and no
    // other — see `drawContentsPhotographed`. Landing areas draw the
    // surfaces live: a swap remaps matching so each place lays out the
    // other's view; a self-split keeps this place's view (the new leaf
    // is empty); a cross-place split leaves a hole and draws the moved
    // view in the incoming pane.
    if (!shut_now and keywords.len > 0 and !init_opts.manual_contents) {
        const plan = ViewDrag.previewPlan(self, init_opts.name);
        const swapped = ViewDrag.swapping(self);
        // The source stands empty while its view rides the pointer — but not
        // while the pointer is over it. Aiming at your own place must show
        // your own content, dimmed: that is the thing you are placing.
        const on_screen = !dragging_this or swapped or ViewDrag.overSelf(self);
        const shot = ViewDrag.shotWanted(self, init_opts.name, dragging_this, plan);

        if (shot.any()) {
            try drawContentsPhotographed(self, init_opts, keywords, clip_to, shot, on_screen);
        } else if (on_screen) {
            _ = try drawContents(self, init_opts, keywords);
        }
    }
    if (dragging_this) {
        const rs = box.data().borderRectScale();
        const corners = box_opts.cornersGet().scale(rs.s, dvui.CornerRect.Physical);
        ViewDrag.drawSwapOut(self, rs.r);
        ViewDrag.dimSource(self, rs, corners);
        ViewDrag.drawFloat(self);
    }

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
    };
}

/// How close the pointer must be to a region's top-right corner, in points, before the button
/// shows. Far enough that a glance toward the corner finds it; near enough that it never
/// appears while the user is working in the middle of the region.
const corner_reach: f32 = 56;
const corner_button_size: f32 = 22;

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
/// one fades it in when the pointer is near the corner, and out when it leaves, so the control
/// does not sit on the surface. Empty is a hatch, not a ring: a ring on every vacant slot
/// read as focus. A filled card still gets a rounded highlight when the pointer is near.
///
/// Drag the button to lift the view. The place stays as a hole; a floating card follows the
/// pointer (grab offset preserved). Hover a place's edge — including this one's — to
/// preview a split sliding open; hover another place's middle to preview a swap.
fn cornerButton(self: *Layout, opts: InitOptions, keywords: []const []const u8, box: *dvui.BoxWidget) void {
    const rs = box.data().borderRectScale();
    const mouse = dvui.currentWindow().mouse_pt;
    const picker_here = self.state.picker.is_open and std.mem.eql(u8, self.state.picker.region, opts.name);
    const filled = regionHasContent(self, opts, keywords);
    const dragging_this = self.state.view_drag.active() and std.mem.eql(u8, self.state.view_drag.name, opts.name);
    const over = self.state.view_drag.active() and rs.r.contains(mouse);
    // Null plan: the middle of the place the drag came from, which is not a
    // drop at all. Every other reading of the pointer lands somewhere.
    const drop_here = over and Drop.plan(Drop.kindAt(rs.r, mouse, rs.s), dragging_this) != null;
    const near = mouse.x >= rs.r.x + rs.r.w - corner_reach * rs.s and mouse.x <= rs.r.x + rs.r.w and
        mouse.y >= rs.r.y and mouse.y <= rs.r.y + corner_reach * rs.s;
    const pressing = dvui.dataGet(null, box.data().id, "_chooser_press", bool) orelse false;
    if (self.state.view_drag.active()) ViewDrag.tick(self);
    const showing = ViewDrag.previewOn(self, opts.name);
    const available = !filled or picker_here or near or dragging_this or drop_here or pressing or showing;
    const alpha = chooserFade(box.data().id, if (available) 1 else 0);

    if (alpha < 0.01 and !available and !dragging_this and !showing) return;

    var ftb: dvui.RenderFrontToBack = undefined;
    ftb.init();
    defer ftb.deinit();

    // Same corners the box fill uses — `finalize(theme)` turns `.all(r)` into
    // the theme's kind, and fizzy's theme is square, so the ring was a second
    // square outline sitting on the rounded card.
    const corners = box.data().options.cornersGet().scale(rs.s, dvui.CornerRect.Physical);
    const theme = dvui.themeGet();
    // The place the view was lifted out of stands empty — unless it is the
    // landing, or the pointer is over it, in which case it keeps its content
    // and dims instead.
    const hole = dragging_this and !ViewDrag.swapping(self) and !ViewDrag.overSelf(self);
    if (!filled or hole) drawEmptyHatch(rs.r, rs.s);
    if (drop_here or showing) {
        ViewDrag.drawHint(self, opts.name, rs.r, rs.s, cardOf(box));
    } else if (filled and !dragging_this and alpha > 0.01) {
        rs.r.stroke(corners, .{ .color = .{ .color = theme.focus.opacity(alpha) }, .thickness = 2.0 });
    }

    if (alpha < 0.01 and !pressing and !dragging_this and !showing) return;

    const content = box.data().contentRect();
    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{ .draw_focus = false }, .{
        .tab_index = 0,
        .rect = .{
            .x = content.w - corner_button_size - 4,
            .y = 4,
            .w = corner_button_size,
            .h = corner_button_size,
        },
        .padding = dvui.Rect.all(1),
        .corners = dvui.CornerRect.all(4),
        .background = true,
        .color_fill = .{ .color = theme.color(.control, .fill).opacity(@max(alpha, 0.35)) },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = theme.color(.control, .border).opacity(@max(alpha, 0.35)) },
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
            });
        }
        if (me.action == .motion and (dvui.captured(bw.data().id) or pressing)) {
            if (dvui.dragging(me.p, "fizzy_view") != null) {
                if (!self.state.view_drag.active()) ViewDrag.begin(self, opts.name, rs.r);
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
        }
    }

    if ((alpha > 0.01 or dragged) and !dragged) {
        bw.drawBackground();
        core.icon.icon(@src(), "regions", dvui.entypo.grid, .{
            .fill_color = .{ .color = if (bw.hovered()) theme.color(.highlight, .fill) else theme.color(.control, .text).opacity(alpha) },
        }, .{ .expand = .both });
    }
    if (bw.clicked() and !dragged) {
        self.state.openPicker(self.gpa, opts.name, bw.data().rectScale().r.toNatural().bottomLeft());
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
                .end_time = chooser_fade_ms * std.time.us_per_ms,
                .easing = dvui.easing.outQuad,
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
            .end_time = chooser_fade_ms * std.time.us_per_ms,
            .easing = dvui.easing.outQuad,
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
/// pixels back if the place is meant to be on screen.
///
/// The drag needs a still of the place — the lifted view for the floating
/// card, the destination for the outgoing blur. A second `drawContents` in
/// the same frame would build every widget under the place twice (dvui
/// reports a duplicate id for each), so one draw serves both: the screen sees
/// a photograph of itself, which is the same picture.
fn drawContentsPhotographed(
    self: *Layout,
    opts: InitOptions,
    keywords: []const []const u8,
    rect: dvui.Rect.Physical,
    shot: ViewDrag.Shot,
    on_screen: bool,
) !void {
    const captured = core.anim.CrossFade.beginCapture(rect) orelse {
        // No texture targets (web) or nothing to capture: the drag goes
        // without its still rather than the place going without its draw.
        if (on_screen) _ = try drawContents(self, opts, keywords);
        return;
    };
    var pic = captured;

    // Photograph the place as it stands, not as the preview poses it: the
    // still is taken on the frame the preview is aimed, before the place has
    // pulled back, which is exactly the picture the dissolve needs.
    self.state.view_drag.capturing = true;
    const prev_clip = dvui.clip(rect);
    _ = try drawContents(self, opts, keywords);
    dvui.clipSet(prev_clip);
    self.state.view_drag.capturing = false;

    // `pic.r`, not `rect`: `Picture.start` enlarges to pixel boundaries, and
    // blitting the smaller rect would sample the wrong UVs.
    const tex = ViewDrag.keepShot(self, shot, &pic, opts.name) orelse return;
    if (!on_screen) return;
    core.anim.blit(tex, null, pic.r, 0, 1);
}

fn persistExtent(self: *Layout, opts: InitOptions, id: dvui.Id, chosen: f32, shown: f32) void {
    _ = shown;
    const kept = if (self.state.assignment(opts.name)) |ids| ids.len > 0 else false;
    // A live drag writes a zero on the way through closed; forgetting here removes the
    // region and the next frame recreates a sentinel under the pointer — the pop.
    const dragging = dvui.dataGet(null, id, "_drag", bool) orelse false;
    if (opts.forget_when_empty and !kept and !dragging) {
        if (chosen <= 0) {
            // Still travelling shut: collapsing here drops the leaf and the
            // next frame has nothing to ease. `shown` can rest above zero
            // after the curve, so "animation finished" is the real signal.
            if (dvui.animationGet(id, "_ease") != null) {
                if (self.state.setExtent(self.gpa, opts.name, 0)) self.extents_changed = true;
                return;
            }
            if (self.state.clearExtent(self.gpa, opts.name)) self.extents_changed = true;
            if (self.state.splits.collapse(self.gpa, opts.name)) self.extents_changed = true;
            self.state.unassign(self.gpa, opts.name);
            dvui.refresh(null, @src(), id);
            return;
        }
    }
    if (self.state.setExtent(self.gpa, opts.name, chosen)) self.extents_changed = true;
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
    if (shows == .many) self.tabsIn(&place);
    if (opts.by_name) return self.drawSelectedIn(&place);
    return self.drawSelected(keywords);
}

fn nameExtra(name: []const u8) usize {
    return @truncate(std.hash.Wyhash.hash(0x51a7, name));
}

fn extraFor(name: []const u8, side: SplitTree.Side) usize {
    return @truncate(nameExtra(name) ^ @as(u64, @intFromEnum(side)) << 8);
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
        if (init_opts.name.len > 0) persistExtent(self, init_opts, id, chosen, extent);
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

    try drawTreeChildren(self, src, init_opts, opts, branch);

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
fn cardOf(box: *dvui.BoxWidget) ViewDrag.Card {
    const o = box.data().options;
    return .{
        .corners = o.cornersGet().scale(box.data().borderRectScale().s, dvui.CornerRect.Physical),
        .fill = o.color(.fill).toColor(),
        .padding = o.paddingGet(),
    };
}

/// A card's padding, folded away over the last stretch of a close.
///
/// Padding is room the place takes up, so a card closed to nothing is still as wide as its own
/// inset — 16pt of stripe that sits there until something removes the place, and then goes in
/// one frame. Once the extent is under the inset the place is narrower than the gap it wants to
/// keep inside itself, which is the point at which the inset stops meaning anything; from there
/// it comes in proportionally, so nothing reaches nothing.
///
/// Only along the parent's axis. The cross axis is not closing.
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
                persistExtent(self, .{ .name = b.origin, .forget_when_empty = true }, id, chosen, shown);
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
                const cr = box.data().contentRect();
                self.state.setPlaceMetrics(b.origin, .{ .w = cr.w, .h = cr.h }, box.data().borderRectScale().r);
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

    const cr = box.data().contentRect();
    self.state.setPlaceMetrics(init_opts.name, .{ .w = cr.w, .h = cr.h }, box.data().borderRectScale().r);

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
    if (self.state.dock) |*dock| return splitDock(self, dock, name, side);

    const size = ViewDrag.placeSize(self.state, name) orelse return null;
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
    const want = @max(1, (span - Split.handle_size) / 2);
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
