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
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const Split = core.widgets.Split;
const Layout = @import("Layout.zig");

const Region = @This();

/// The human-facing name the shape gave this region — "Sidebar", "Main", "Panel". What a user
/// picks from when moving a surface somewhere else, so it is worth a real word.
name: []const u8 = "",
/// What kinds of surface this region accepts, as its shape declared them.
keywords: []const []const u8 = &.{},
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

pub fn deinit(self: *Region) void {
    if (self.prev_clip) |c| dvui.clipSet(c);
    if (self.box) |b| {
        if (self.layout) |l| {
            std.debug.assert(l.depth > 0);
            l.depth -= 1;
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
/// ordinary code over this API, and an app copying `ide.zig` could not have written those two
/// values itself. As a function pointer they are just `explorerPane` and `bottomPane` in
/// `presets/ide.zig` — app code, passed in, replaceable by the app's own loop over `matching` /
/// `selected` / `draw`, which is the governing test for everything here.
///
/// It also retired the two values nothing used (`.tabs`, `.icons`); `Layout.tabbed` is the
/// first of those as a plain function, and the icon rail was never this shape to begin with —
/// it sits *beside* the region it chooses for, so `ide.zig` calls it directly and reads the
/// action it returns.
pub const Content = struct {
    /// Whatever the shape needs to draw its chrome — for fizzy's own shapes, the application.
    /// A `Layout` deliberately does not carry it: the layout mechanism knows about surfaces,
    /// regions and splits, and nothing about whose furniture is being drawn. Same `ctx` idiom
    /// as `Surface.draw`, for the same reason.
    ctx: ?*anyopaque = null,
    draw: *const fn (ctx: ?*anyopaque, f: *Layout, keywords: []const []const u8) anyerror!dvui.App.Result,
};

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
    /// The axis this region lays its children along, exactly as `dvui.box`'s `dir`.
    dir: dvui.enums.Direction = .vertical,
    /// Chrome drawn instead of the plain selected surface. See `Content`.
    content: ?Content = null,
    /// Make this region's extent along its parent's axis draggable by the `split` after it. The
    /// starting extent comes from `min_size_content` in the `dvui.Options`; the user's drag
    /// replaces it and persists.
    resize: bool = false,
    /// Collapse while nothing matches, rather than holding empty space open.
    hide_when_empty: bool = false,
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
/// `Options`, unchanged — `expand`, `min_size_content`, `padding`, `gravity`, all of it. So the
/// sizing rules are the ones already in use everywhere else: a child that does not expand along
/// the axis takes its minimum, and the children that do share what is left.
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
pub fn init(self: *Layout, src: std.builtin.SourceLocation, init_opts: InitOptions, opts: dvui.Options) !Region {
    if (self.depth >= Layout.max_nesting) {
        dvui.log.err("layout nests deeper than {d} regions; \"{s}\" ignored", .{ Layout.max_nesting, init_opts.name });
        return .{};
    }

    const matches = self.matching(init_opts.keywords);
    if (init_opts.hide_when_empty and init_opts.keywords.len > 0 and matches.len == 0) return .{};

    // The container this region lands in, if any — the layout's own stack, read directly
    // rather than through an accessor, so nothing about it appears on the app-facing API.
    const parent: ?*Layout.Container = if (self.depth == 0) null else &self.containers[self.depth - 1];
    const axis: dvui.enums.Direction = if (parent) |p| p.dir else .horizontal;
    const id = dvui.parentGet().extendId(src, opts.idExtra());

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
        if (dvui.animationGet(id, "_ease")) |a| {
            extent = a.value();
        } else {
            const shown = dvui.dataGet(null, id, "_shown", f32) orelse target;
            if (shown != target) {
                dvui.animation(id, "_ease", .{
                    .start_val = shown,
                    .end_val = target,
                    .end_time = Layout.collapse_ms * std.time.us_per_ms,
                    .easing = dvui.easing.outQuint,
                });
                extent = shown;
            } else {
                extent = target;
            }
        }
        dvui.dataSet(null, id, "_shown", extent);
        dvui.dataSet(null, id, "_size", chosen);
        if (init_opts.name.len > 0 and self.state.setExtent(self.gpa, init_opts.name, chosen)) self.extents_changed = true;

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
            // A split declared *before* this region was waiting for a neighbour to resize — the
            // bottom-panel shape, where the panel comes after its own split. Bind it now; the
            // split picks it up next frame, the same one-frame settle everything else here uses.
            if (p.pending_split) |sp| {
                dvui.dataSet(null, sp, "_after", id);
                p.pending_split = null;
            }
            p.last_resizable = id;
            if (p.resizable_count < Layout.max_trays) {
                p.resizables[p.resizable_count] = id;
                p.resizable_count += 1;
            }
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
        }
    }

    // Findable from outside the layout by the keywords it accepts — a rail button or a command
    // opening and shutting it, the settings pane listing where a panel can go. Every region that
    // hosts surfaces registers, resizable or not: this used to sit inside the `resize` branch,
    // so a stretchy region like the main area was invisible to the registry, the placement
    // picker never offered "Main", and the surfaces drawing there read as unplaced.
    if (init_opts.keywords.len > 0) self.state.registerRegion(self.gpa, .{
        .name = init_opts.name,
        .keywords = init_opts.keywords,
        .id = id,
        .default_extent = default_extent,
    });

    const box = dvui.box(src, .{ .dir = init_opts.dir }, box_opts);
    if (init_opts.resize) Split.recordEdges(id, box.data(), axis);
    self.containers[self.depth] = .{ .dir = init_opts.dir, .box = box };
    self.depth += 1;

    // A region clips what it holds. Contents draw at their own natural size, so without this a
    // region squeezed narrower than its contents simply spills them over its neighbour instead
    // of getting smaller — which is what a half-closed sidebar looked like.
    const clip_to = box.data().contentRectScale().r;
    const prev_clip = dvui.clip(clip_to);

    if (init_opts.name.len > 0 and init_opts.keywords.len > 0) cornerButton(self, init_opts.name, box);

    // Drawn at every size except none. Skipping content at *zero* is just not doing work nobody
    // can see; skipping it below a threshold would be a policy, and it would also break the
    // layered form later — a tray blurring what is behind it needs the region underneath to have
    // drawn, at every size the tray takes.
    if (!shut_now and init_opts.keywords.len > 0) _ = try drawContents(self, init_opts);

    return .{
        .name = init_opts.name,
        .keywords = init_opts.keywords,
        .id = id,
        .default_extent = default_extent,
        .box = box,
        .layout = self,
        .prev_clip = prev_clip,
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
/// under a scroll area needs both to be it. Shown only while the pointer is near the corner.
fn cornerButton(self: *Layout, name: []const u8, box: *dvui.BoxWidget) void {
    const rs = box.data().contentRectScale();
    const mouse = dvui.currentWindow().mouse_pt;
    const near = mouse.x >= rs.r.x + rs.r.w - corner_reach * rs.s and mouse.x <= rs.r.x + rs.r.w and
        mouse.y >= rs.r.y and mouse.y <= rs.r.y + corner_reach * rs.s;
    if (!near) return;

    var ftb: dvui.RenderFrontToBack = undefined;
    ftb.init();
    defer ftb.deinit();

    const content = box.data().contentRect();
    const theme = dvui.themeGet();
    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{}, .{
        .rect = .{
            .x = content.w - corner_button_size - 4,
            .y = 4,
            .w = corner_button_size,
            .h = corner_button_size,
        },
        .padding = dvui.Rect.all(2),
        .corners = dvui.CornerRect.all(4),
        .background = true,
        .color_fill = theme.color(.control, .fill),
        .border = dvui.Rect.all(1),
        .color_border = theme.color(.control, .border),
    });
    defer bw.deinit();
    bw.processEvents();
    bw.drawBackground();
    dvui.icon(@src(), "regions", dvui.entypo.grid, .{
        .fill_color = if (bw.hovered()) theme.color(.highlight, .fill) else theme.color(.control, .text),
    }, .{ .expand = .both });
    if (bw.clicked()) {
        self.state.openPicker(self.gpa, name, bw.data().rectScale().r.toNatural().bottomLeft());
    }
}

/// The region's contents: its own chrome if it declared any, otherwise the active surface.
///
/// Everything reachable here is reachable by hand from `matching` / `selected` / `draw`, so a
/// shape wanting something else writes its own function and passes it as `content`.
fn drawContents(self: *Layout, opts: InitOptions) !dvui.App.Result {
    const content = opts.content orelse return self.drawSelected(opts.keywords);
    return content.draw(content.ctx, self, opts.keywords);
}
