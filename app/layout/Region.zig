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
// never a widget pointer. `Explorer` used to reach for the `PanedWidget` behind the sidebar and
// call `animateSplit` on it, which only worked while a region *was* a paned.

pub fn isClosed(self: Region) bool {
    // Absence is not zero: a region that was never sized — a stretchy one that takes what is
    // left, now that every region registers — has no stored extent and is not shut.
    const stored = dvui.dataGet(null, self.id, "_size", f32) orelse return false;
    return stored <= 0;
}

pub fn close(self: Region) void {
    Split.close(self.id);
}

pub fn open(self: Region) void {
    Split.open(self.id, self.default_extent);
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
/// `background`, `corners`, `gravity`, all of it. A rounded fill is an Option the
/// shape sets. So the sizing rules are the ones already in use everywhere else: a
/// child that does not expand along the axis takes its minimum, and the children
/// that do share what is left.
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
    const keywords = regionKeywords(self, if (parent) |p| p.prefix else "", init_opts.keywords);

    const matches = if (init_opts.by_name)
        self.matchingIn(&.{ .name = init_opts.name, .keywords = keywords, .by_name = true })
    else
        self.matching(keywords);
    if (init_opts.hide_when_empty and keywords.len > 0 and matches.len == 0) {
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
        if (init_opts.name.len > 0 and self.state.takeSlideOpen(init_opts.name)) {
            dvui.dataSet(null, id, "_shown", @as(f32, 0));
        }

        // The size the user chose. Auto-collapse must never overwrite it, or folding the window
        // small destroys the extent it is supposed to restore — which is what "it does not
        // reopen to its last place" was. The paned shell kept an `uncollapse_ratio` for the same
        // reason; here the stored size simply stays put and only what is *shown* goes to zero.
        const chosen = dvui.dataGet(null, id, "_size", f32) orelse default;

        var target = chosen;
        if (init_opts.collapsible) {
            const available = if (parent) |p| p.extent(axis) else 0;
            if (available > 0 and available < InitOptions.collapse_below) target = 0;
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
    // hosts surfaces registers, resizable or not: this used to sit inside the `resize` branch,
    // so a stretchy region like the main area was invisible to the registry, the placement
    // picker never offered "Main", and the surfaces drawing there read as unplaced.
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
        .forget_when_empty = init_opts.forget_when_empty,
        .dir = init_opts.dir,
    });

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
    // A place whose view is being dragged is photographed once, then left
    // empty — the floating card is the view.
    if (!shut_now and keywords.len > 0 and !init_opts.manual_contents) {
        if (dragging_this) {
            try captureDragView(self, init_opts, keywords, clip_to);
        } else {
            _ = try drawContents(self, init_opts, keywords);
        }
    }
    if (dragging_this) drawViewFloat(self, box);

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
/// pointer (grab offset preserved). Hover another place's edge to preview a split sliding
/// open; hover the middle to preview a swap.
fn cornerButton(self: *Layout, opts: InitOptions, keywords: []const []const u8, box: *dvui.BoxWidget) void {
    const rs = box.data().borderRectScale();
    const mouse = dvui.currentWindow().mouse_pt;
    const picker_here = self.state.picker.is_open and std.mem.eql(u8, self.state.picker.region, opts.name);
    const filled = regionHasContent(self, opts, keywords);
    const dragging_this = self.state.view_drag.active() and std.mem.eql(u8, self.state.view_drag.name, opts.name);
    const drop_here = self.state.view_drag.active() and !dragging_this and rs.r.contains(mouse);
    const near = mouse.x >= rs.r.x + rs.r.w - corner_reach * rs.s and mouse.x <= rs.r.x + rs.r.w and
        mouse.y >= rs.r.y and mouse.y <= rs.r.y + corner_reach * rs.s;
    const pressing = dvui.dataGet(null, box.data().id, "_chooser_press", bool) orelse false;
    const available = !filled or picker_here or near or dragging_this or drop_here or pressing;
    const alpha = chooserFade(box.data().id, if (available) 1 else 0);

    if (alpha < 0.01 and !available and !dragging_this) return;

    var ftb: dvui.RenderFrontToBack = undefined;
    ftb.init();
    defer ftb.deinit();

    // Same corners the box fill uses — `finalize(theme)` turns `.all(r)` into
    // the theme's kind, and fizzy's theme is square, so the ring was a second
    // square outline sitting on the rounded card.
    const corners = box.data().options.cornersGet().scale(rs.s, dvui.CornerRect.Physical);
    const theme = dvui.themeGet();
    if (!filled or dragging_this) drawEmptyHatch(rs.r, corners, rs.s);
    if (drop_here) {
        drawDropHint(self, opts.name, rs.r, corners, mouse, rs.s);
    } else if (filled and !dragging_this and alpha > 0.01) {
        rs.r.stroke(corners, .{ .color = theme.focus.opacity(alpha), .thickness = 2.0 });
    }

    if (alpha < 0.01 and !pressing and !dragging_this) return;

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
        .color_fill = theme.color(.control, .fill).opacity(@max(alpha, 0.35)),
        .border = dvui.Rect.all(1),
        .color_border = theme.color(.control, .border).opacity(@max(alpha, 0.35)),
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
                if (!self.state.view_drag.active()) {
                    self.state.view_drag.name = self.state.internName(self.gpa, opts.name);
                    self.state.view_drag.from = rs.r.size();
                    self.state.view_drag.start_ns = dvui.currentWindow().frame_time_ns;
                }
                dragged = true;
                dvui.refresh(null, @src(), null);
            }
        }
        if (me.action == .release and me.button.pointer()) {
            if (self.state.view_drag.active() and std.mem.eql(u8, self.state.view_drag.name, opts.name)) {
                applyViewDrop(self, opts.name, me.p);
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
        dvui.icon(@src(), "regions", dvui.entypo.grid, .{
            .fill_color = if (bw.hovered()) theme.color(.highlight, .fill) else theme.color(.control, .text).opacity(alpha),
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

const DropKind = union(enum) {
    swap,
    split: SplitTree.Side,
};

/// Near an edge is a split on that side; the middle is a swap. The band is
/// 36pt, or 28% of the shorter side, so a small place still has a swap target.
fn dropKind(bounds: dvui.Rect.Physical, mouse: dvui.Point.Physical, scale: f32) DropKind {
    if (bounds.w <= 0 or bounds.h <= 0) return .swap;
    const band = @min(36 * scale, @min(bounds.w, bounds.h) * 0.28);
    const dl = mouse.x - bounds.x;
    const dr = bounds.x + bounds.w - mouse.x;
    const dt = mouse.y - bounds.y;
    const db = bounds.y + bounds.h - mouse.y;
    const nearest = @min(@min(dl, dr), @min(dt, db));
    if (nearest > band) return .swap;
    if (nearest == dl) return .{ .split = .left };
    if (nearest == dr) return .{ .split = .right };
    if (nearest == dt) return .{ .split = .top };
    return .{ .split = .bottom };
}

fn drawEmptyHatch(bounds: dvui.Rect.Physical, corners: dvui.CornerRect.Physical, scale: f32) void {
    _ = corners;
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
        path.build().stroke(.{ .color = color, .thickness = @max(1.0, scale) });
        path.deinit();
    }
}

fn previewEase(self: *Layout, dest: []const u8, kind: DropKind) f32 {
    const split: ?SplitTree.Side = switch (kind) {
        .swap => null,
        .split => |s| s,
    };
    const now = dvui.currentWindow().frame_time_ns;
    const name = self.state.internName(self.gpa, dest);
    const same = std.mem.eql(u8, self.state.view_drag.preview_name, name) and
        ((self.state.view_drag.preview_split == null) == (split == null)) and
        (split == null or self.state.view_drag.preview_split.? == split.?);
    if (!same) {
        self.state.view_drag.preview_name = name;
        self.state.view_drag.preview_split = split;
        self.state.view_drag.preview_ns = now;
    }
    const dur: f64 = 180 * @as(f64, std.time.ns_per_ms);
    const elapsed: f64 = @floatFromInt(now - self.state.view_drag.preview_ns);
    return outCubic(@floatCast(std.math.clamp(elapsed / dur, 0, 1)));
}

fn slidePreview(bounds: dvui.Rect.Physical, side: SplitTree.Side, t: f32) dvui.Rect.Physical {
    const u = std.math.clamp(t, 0, 1);
    var r = bounds;
    switch (side) {
        .left => r.w = bounds.w * 0.5 * u,
        .right => {
            r.w = bounds.w * 0.5 * u;
            r.x = bounds.x + bounds.w - r.w;
        },
        .top => r.h = bounds.h * 0.5 * u,
        .bottom => {
            r.h = bounds.h * 0.5 * u;
            r.y = bounds.y + bounds.h - r.h;
        },
    }
    return r;
}

fn outCubic(t: f32) f32 {
    const u = 1 - t;
    return 1 - u * u * u;
}

fn captureDragView(
    self: *Layout,
    opts: InitOptions,
    keywords: []const []const u8,
    rect: dvui.Rect.Physical,
) !void {
    if (self.state.view_drag.texture != null) return;
    if (core.anim.CrossFade.beginCapture(rect)) |captured| {
        var pic = captured;
        _ = try drawContents(self, opts, keywords);
        self.state.view_drag.takePicture(&pic);
    }
}

fn floatTarget(from: dvui.Size.Physical, scale: f32) dvui.Size.Physical {
    if (from.w <= 0 or from.h <= 0) return .{ .w = 280 * scale, .h = 180 * scale };
    const max_w = 280 * scale;
    const max_h = 200 * scale;
    const aspect = from.w / from.h;
    var w = @min(from.w, max_w);
    var h = w / aspect;
    if (h > max_h) {
        h = @min(from.h, max_h);
        w = h * aspect;
    }
    return .{ .w = w, .h = h };
}

fn drawViewFloat(self: *Layout, box: *dvui.BoxWidget) void {
    _ = box;
    const d = self.state.view_drag;
    if (!d.active()) return;
    const mouse = dvui.currentWindow().mouse_pt;
    const now = dvui.currentWindow().frame_time_ns;
    const dur: f64 = 220 * @as(f64, std.time.ns_per_ms);
    const elapsed: f64 = @floatFromInt(now - d.start_ns);
    const t = outCubic(@floatCast(std.math.clamp(elapsed / dur, 0, 1)));

    const from = d.from;
    const scale = dvui.currentWindow().natural_scale;
    const target = floatTarget(from, scale);
    const w = from.w + (target.w - from.w) * t;
    const h = from.h + (target.h - from.h) * t;
    const sx = if (from.w > 0) w / from.w else 1;
    const sy = if (from.h > 0) h / from.h else 1;
    const off = dvui.dragOffset();
    const tl = mouse.plus(.{ .x = off.x * sx, .y = off.y * sy });
    const nat = dvui.Rect.Physical.fromPoint(tl).toSize(.{ .w = w, .h = h }).toNatural();

    const theme = dvui.themeGet();
    var fw: dvui.FloatingWidget = undefined;
    fw.init(@src(), .{ .mouse_events = false }, .{
        .rect = .{ .x = nat.x, .y = nat.y, .w = nat.w, .h = nat.h },
        .padding = .{},
        .corners = dvui.CornerRect.round(12),
        .background = true,
        .color_fill = theme.color(.window, .fill),
        .border = dvui.Rect.all(1),
        .color_border = theme.color(.highlight, .fill),
        .box_shadow = .{
            .color = .black,
            .alpha = 0.28,
            .fade = 12,
            .offset = .{ .x = 0, .y = 4 },
            .corners = dvui.CornerRect.round(12),
        },
    });
    defer fw.deinit();

    const dest = fw.data().contentRectScale().r;
    if (d.texture) |tex| {
        core.anim.blit(tex, dest, 0, 1);
    } else {
        dvui.label(@src(), "view", .{}, .{
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .color_text = theme.color(.control, .text),
        });
    }
    dvui.refresh(null, @src(), null);
}

fn drawDropHint(
    self: *Layout,
    dest: []const u8,
    bounds: dvui.Rect.Physical,
    corners: dvui.CornerRect.Physical,
    mouse: dvui.Point.Physical,
    scale: f32,
) void {
    const focus = dvui.themeGet().focus;
    const kind = dropKind(bounds, mouse, scale);
    const t = previewEase(self, dest, kind);
    const tex = self.state.view_drag.texture;
    switch (kind) {
        .swap => {
            if (tex) |picture| {
                core.anim.blit(picture, bounds, 0.35 * (1 - t), 0.40 + 0.50 * t);
            } else {
                bounds.fill(corners, .{ .color = focus.opacity(0.10 + 0.12 * t), .fade = 1.0 });
            }
        },
        .split => |side| {
            const pane = slidePreview(bounds, side, t);
            if (pane.w > 1 and pane.h > 1) {
                pane.fill(corners, .{ .color = focus.opacity(0.16), .fade = 1.0 });
                if (tex) |picture| core.anim.blit(picture, pane, 0.2 * (1 - t), 0.85);
            }
        },
    }
    bounds.stroke(corners, .{ .color = focus.opacity(0.55 + 0.45 * t), .thickness = 2.0 });
}

fn dropTargetAt(state: *const Layout.State, mouse: dvui.Point.Physical, skip: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_area: f32 = std.math.floatMax(f32);
    for (state.regions.items) |r| considerDrop(&best, &best_area, r, mouse, skip);
    for (state.regions_building.items) |r| considerDrop(&best, &best_area, r, mouse, skip);
    return best;
}

fn considerDrop(best: *?[]const u8, best_area: *f32, r: Region, mouse: dvui.Point.Physical, skip: []const u8) void {
    if (r.name.len == 0 or std.mem.eql(u8, r.name, skip)) return;
    if (r.bounds.w <= 0 or r.bounds.h <= 0) return;
    if (!r.bounds.contains(mouse)) return;
    const area = r.bounds.w * r.bounds.h;
    if (area >= best_area.*) return;
    best.* = r.name;
    best_area.* = area;
}

fn placeBounds(state: *const Layout.State, name: []const u8) ?dvui.Rect.Physical {
    for (state.regions_building.items) |r| {
        if (std.mem.eql(u8, r.name, name) and r.bounds.w > 0 and r.bounds.h > 0) return r.bounds;
    }
    for (state.regions.items) |r| {
        if (std.mem.eql(u8, r.name, name) and r.bounds.w > 0 and r.bounds.h > 0) return r.bounds;
    }
    return null;
}

fn regionNamed(state: *const Layout.State, name: []const u8) ?*const Region {
    for (state.regions.items) |*r| {
        if (std.mem.eql(u8, r.name, name)) return r;
    }
    for (state.regions_building.items) |*r| {
        if (std.mem.eql(u8, r.name, name)) return r;
    }
    return null;
}

/// What this place is showing: an assignment if the user chose, otherwise the
/// surface keyword matching picked. Moving a keyword-default view has to become
/// an explicit assignment on the destination or it reappears on the source.
fn currentViewIds(self: *Layout, name: []const u8) []const []const u8 {
    if (self.state.assignment(name)) |ids| return ids;
    const r = regionNamed(self.state, name) orelse return &.{};
    const s = self.selectedIn(r) orelse return &.{};
    const one = self.arena.alloc([]const u8, 1) catch return &.{};
    one[0] = s.id;
    return one;
}

fn copyIds(arena: std.mem.Allocator, ids: []const []const u8) []const []const u8 {
    const out = arena.dupe([]const u8, ids) catch return &.{};
    return out;
}

fn applyViewDrop(self: *Layout, source: []const u8, mouse: dvui.Point.Physical) void {
    const dest = dropTargetAt(self.state, mouse, source) orelse return;
    const bounds = placeBounds(self.state, dest) orelse return;
    const scale = dvui.currentWindow().natural_scale;
    const ids = copyIds(self.arena, currentViewIds(self, source));
    switch (dropKind(bounds, mouse, scale)) {
        .swap => {
            const other = copyIds(self.arena, currentViewIds(self, dest));
            self.state.assign(self.gpa, source, other) catch {};
            self.state.assign(self.gpa, dest, ids) catch {};
            if (other.len > 0) if (regionNamed(self.state, source)) |r| self.selectIn(r, other[0]);
            if (ids.len > 0) if (regionNamed(self.state, dest)) |r| self.selectIn(r, ids[0]);
        },
        .split => |side| {
            if (ids.len == 0) return;
            const new = splitOn(self, dest, side) orelse return;
            self.state.assign(self.gpa, new, ids) catch {};
            self.state.assign(self.gpa, source, &.{}) catch {};
            if (regionNamed(self.state, new)) |r| self.selectIn(r, ids[0]);
        },
    }
    self.state.markDirty();
    dvui.refresh(null, @src(), null);
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
    if (opts.by_name) return self.drawSelectedIn(&.{
        .name = opts.name,
        .keywords = keywords,
        .by_name = true,
        .shows = opts.shows,
    });
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
            const available = if (parent) |p| p.extent(axis) else 0;
            if (available > 0 and available < InitOptions.collapse_below) target = 0;
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

    // Grouping is only the axis. Fill stays on the leaves so a sash has a
    // gap between cards instead of sitting on one shared background.
    box_opts.background = false;
    box_opts.corners = null;
    const box = dvui.box(src, .{ .dir = branch.dir }, box_opts);
    if (init_opts.resize) Split.recordEdges(id, box.data(), axis);

    if (keywords.len > 0) self.state.registerRegion(self.gpa, .{
        .name = init_opts.name,
        .keywords = keywords,
        .shows = init_opts.shows,
        .id = id,
        .default_extent = default_extent,
        .by_name = init_opts.by_name,
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
    try drawTreeNode(self, src, shape, shape_opts, branch.b, omit_b, leftover_b);
    const group = if (self.depth > 0) self.containers[self.depth - 1].box else null;
    if (group) |box| edgeHandleOn(self, box, branch.side, SplitTree.newNameOf(branch));
}

fn placeVisual(opts: dvui.Options) dvui.Options {
    return .{
        .background = opts.background,
        .color_fill = opts.color_fill,
        .corners = opts.corners,
    };
}

fn handleGutter(side: SplitTree.Side) dvui.Rect {
    // Half on each facing edge so two cards share one handle-wide gap.
    const g = Split.handle_size / 2;
    return switch (side) {
        .left => .{ .x = g },
        .right => .{ .w = g },
        .top => .{ .y = g },
        .bottom => .{ .h = g },
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
            // Both sides of the sash, or the created card paints over the handle.
            child_opts.margin = handleGutter(omit);
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

fn edgeHandleOn(
    self: *Layout,
    box: *dvui.BoxWidget,
    side: SplitTree.Side,
    target_name: []const u8,
) void {
    const tid = idOf(self.state, target_name) orelse return;
    const axis = SplitTree.axisOf(side);
    const sign: f32 = if (SplitTree.newIsLeading(side)) 1 else -1;
    const at = Split.overlayRect(box, tid, sign, axis);
    var divider = Split.init(@src(), axis, extraFor(target_name, side), at);
    defer divider.deinit();
    const extent = if (self.depth > 0) self.containers[self.depth - 1].extent(axis) else 0;
    divider.drag(box, tid, sign, .{ .push_out = true }, .{
        .extent = extent,
        .base_min = 0,
        .handles = 0,
        .sign = sign,
    });
}

fn isSlotKeywords(keywords: []const []const u8) bool {
    return keywords.len == 1 and std.mem.eql(u8, keywords[0], Layout.slot_keywords[0]);
}

fn regionKeywords(self: *Layout, prefix: []const u8, base: []const []const u8) []const []const u8 {
    // `slot` is a user tray, not a kind. Qualifying it under Main hid Clear/Remove
    // (`main.slot`) the same way `slot.slot` did in endless.
    if (isSlotKeywords(base)) return base;
    return self.state.qualify(self.gpa, prefix, base);
}

fn placePrefix(keywords: []const []const u8, parent_prefix: []const u8) []const u8 {
    if (keywords.len == 0) return parent_prefix;
    if (isSlotKeywords(keywords)) return parent_prefix;
    return keywords[0];
}

/// Divide `name` on `axis`: a new empty place opens on the trailing side and
/// eases to the middle. `axis` is the layout direction — `.horizontal` is a
/// vertical divider (side by side). The picker's Split menu names the divider.
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
    const size = self.state.placeSize(name) orelse return null;
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
    const want = span / 2;
    const new = self.state.splits.split(self.gpa, intern.go, name, side, want, null) orelse return null;
    if (self.state.setExtent(self.gpa, new, want)) self.extents_changed = true;
    self.state.assign(self.gpa, new, &.{}) catch {};
    self.state.requestSlideOpen(new);
    self.state.markDirty();
    dvui.refresh(null, @src(), null);
    return new;
}

test "drop near an edge is a split, the middle is a swap" {
    const r: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 200, .h = 100 };
    try std.testing.expectEqual(DropKind.swap, dropKind(r, .{ .x = 100, .y = 50 }, 1));
    try std.testing.expectEqual(DropKind{ .split = .left }, dropKind(r, .{ .x = 10, .y = 50 }, 1));
    try std.testing.expectEqual(DropKind{ .split = .right }, dropKind(r, .{ .x = 190, .y = 50 }, 1));
    try std.testing.expectEqual(DropKind{ .split = .top }, dropKind(r, .{ .x = 100, .y = 8 }, 1));
    try std.testing.expectEqual(DropKind{ .split = .bottom }, dropKind(r, .{ .x = 100, .y = 94 }, 1));
}

test "a split preview grows from the hovered edge to half" {
    const r: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 200, .h = 100 };
    const none = slidePreview(r, .left, 0);
    try std.testing.expectEqual(@as(f32, 0), none.w);
    const half = slidePreview(r, .left, 1);
    try std.testing.expectEqual(@as(f32, 100), half.w);
    try std.testing.expectEqual(@as(f32, 0), half.x);
    const right = slidePreview(r, .right, 1);
    try std.testing.expectEqual(@as(f32, 100), right.x);
    try std.testing.expectEqual(@as(f32, 100), right.w);
}
