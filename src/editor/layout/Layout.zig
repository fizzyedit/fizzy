//! What an app's shape declares its regions with.
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
const Sash = core.dvui.Sash;
const Constants = @import("../Constants.zig");
const chrome_ref = @import("chrome.zig");

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

editor: *fizzy.Editor,

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
    /// Every resizable region in this container. A sash needs them all, because honouring one
    /// drag can mean pushing the others back.
    resizables: [max_trays]dvui.Id = undefined,
    resizable_count: usize = 0,
    /// Total length the sashes in this container take.
    handles: f32 = 0,
    /// The container's own box, for measuring how near the pointer is to a split inside it.
    box: ?*dvui.BoxWidget = null,
    /// A split that found no resizable region before it, waiting to be bound to the one after.
    pending_split: ?dvui.Id = null,
    /// The most recent resizable child. A `split` drags *this* region's stored size — the
    /// neighbour before it — which is the whole of the resize mechanism: there are no ratios and
    /// no boundary table, just one number per resizable region.
    last_resizable: ?dvui.Id = null,
};

/// Layouts nest a few levels; anything deeper is a mistake worth reporting rather than
/// supporting. Keeps the stack a fixed array with no allocation on the layout path.
pub const max_nesting = 8;

/// Trays per container. More than a handful on one axis is a layout problem, not a use case.
pub const max_trays = 6;

/// How long a region takes to fold away or come back. Matches the paned shell's feel.
pub const collapse_ms: i32 = 220;

pub fn init(editor: *fizzy.Editor) Layout {
    return .{ .editor = editor };
}

fn innermost(self: *Layout) ?*Container {
    return if (self.depth == 0) null else &self.containers[self.depth - 1];
}

/// Thickness of a split, and how near the pointer must be before it shows itself. Fizzy's tuned
/// sash values (`layout.split`), kept because a thinner target is measurably harder to grab.
pub const handle_size = Sash.handle_size;
pub const handle_dist = Sash.handle_dist;

// A region's extent along its parent's axis is stored under `"_size"`, in points.
//
// Points rather than a fraction of the parent, and per region rather than a table of boundaries,
// because that is what `dvui.box` already understands: a child that does not expand along the
// axis takes its minimum, and the ones that do share the remainder. Reusing that means there is
// no second sizing model — a fixed icon rail, a dragged sidebar and a stretching main area are
// the same mechanism with different numbers, and a window resize grows the stretchy half rather
// than rescaling the sidebar.

fn arena(self: *Layout) std.mem.Allocator {
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
fn effectiveKeywords(self: *Layout, s: *const Surface) []const []const u8 {
    if (self.editor.layout.keyword_overrides.get(s.id)) |kw| return kw;
    return s.keywords;
}

/// Every surface currently matching `keywords`, in registration order. Arena-allocated and
/// valid for this frame only; returns an empty slice rather than erroring so a layout can
/// always iterate.
pub fn matching(self: *Layout, keywords: []const []const u8) []const *Surface {
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
pub fn surface(self: *Layout, id: []const u8) ?*Surface {
    return self.editor.host.surfaceById(id);
}

/// Surfaces that match no region this app declared. Never silently lost: the settings UI lists
/// these so a user (or the plugin author) can see the gap and fix it.
pub fn unplaced(self: *Layout, declared: []const []const []const u8) []const *Surface {
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



fn currentId(self: *Layout, keywords: []const []const u8) ?[]const u8 {
    return self.editor.host.selectionFor(keywords);
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
    self.editor.host.setSelectionFor(keywords, s.id);
}


/// Draw one surface into the current parent, wrapped in the swap cross-fade so every region gets
/// it for free. Keyed by **surface id**, never the parent box id — a box id moves with the
/// surrounding layout and would restart the fade on changes that are not content swaps (see the
/// warning at workbench `src/Workspace.zig:768`).
pub fn draw(self: *Layout, s: *Surface) !dvui.App.Result {
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
pub fn region(self: *Layout, src: std.builtin.SourceLocation, kind: Region.Init, opts: dvui.Options) !Region {
    if (self.depth >= max_nesting) {
        dvui.log.err("layout nests deeper than {d} regions; \"{s}\" ignored", .{ max_nesting, kind.name });
        return .{};
    }

    const matches = self.matching(kind.keywords);
    if (kind.hide_when_empty and kind.keywords.len > 0 and matches.len == 0) return .{};

    const parent = self.innermost();
    const axis: dvui.enums.Direction = if (parent) |p| p.dir else .horizontal;
    const id = dvui.parentGet().extendId(src, opts.idExtra());

    // A resizable region's extent along its parent's axis is whatever the user last dragged it
    // to, defaulting to the `min_size_content` the shape wrote.
    var box_opts = opts;
    var shut_now = false;
    var size: f32 = 0;
    if (kind.resize) {
        const given = opts.min_size_content orelse dvui.Size{};
        const default: f32 = switch (axis) {
            .horizontal => given.w,
            .vertical => given.h,
        };
        // Seeded from what the user last left this region at, by name — so a layout persists
        // across restarts without the framework knowing which regions an app has.
        if (dvui.dataGet(null, id, "_size", f32) == null) {
            dvui.dataSet(null, id, "_size", self.editor.regionSize(kind.name, default));
        }

        // The size the user chose. Auto-collapse must never overwrite it, or folding the window
        // small destroys the extent it is supposed to restore — which is what "it does not
        // reopen to its last place" was. The paned shell kept an `uncollapse_ratio` for the same
        // reason; here the stored size simply stays put and only what is *shown* goes to zero.
        const chosen = dvui.dataGet(null, id, "_size", f32) orelse default;

        var target = chosen;
        if (kind.collapsible) {
            const room = if (parent) |p| roomOf(p, axis) else 0;
            if (room > 0 and room < Constants.min_window_size[0]) target = 0;
        }

        // Ease toward the target when it moved for a reason other than a drag — the collapse
        // when the window runs out of room, and the restore when it comes back.
        //
        // A drag is exempt, and stays exempt without a flag: the sash writes `_shown` alongside
        // `_size`, so the two agree and nothing kicks off. Easing a drag would be wrong anyway —
        // a sash should sit under the pointer, not lag behind it on a curve.
        if (dvui.animationGet(id, "_ease")) |a| {
            size = a.value();
        } else {
            const shown = dvui.dataGet(null, id, "_shown", f32) orelse target;
            if (shown != target) {
                dvui.animation(id, "_ease", .{
                    .start_val = shown,
                    .end_val = target,
                    .end_time = collapse_ms * std.time.us_per_ms,
                    .easing = dvui.easing.outQuint,
                });
                size = shown;
            } else {
                size = target;
            }
        }
        dvui.dataSet(null, id, "_shown", size);
        dvui.dataSet(null, id, "_size", chosen);
        if (kind.name.len > 0) self.editor.setRegionSize(kind.name, chosen);

        // Pin both ends. A minimum alone is only a floor, so a region whose content wants to be
        // wider than the size the user dragged it to simply stays wider, and the sash appears to
        // stop responding once it reaches that content's natural width. Pinning the maximum too
        // makes the stored size exact and stops a plugin's content dictating the app's
        // proportions — the hazard `layout.zig` names in its sizing notes.
        box_opts.min_size_content = switch (axis) {
            .horizontal => .{ .w = size, .h = given.h },
            .vertical => .{ .w = given.w, .h = size },
        };
        box_opts.max_size_content = switch (axis) {
            .horizontal => .width(size),
            .vertical => .height(size),
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
            // Findable from outside the layout by the keywords it accepts, so a rail button or
            // a command can open and shut it without knowing what the shape built.
            if (kind.keywords.len > 0) self.editor.registerRegion(.{
                .keywords = kind.keywords,
                .id = id,
                .default_size = default,
            });
            if (p.resizable_count < max_trays) {
                p.resizables[p.resizable_count] = id;
                p.resizable_count += 1;
            }
        }
        shut_now = size <= 0;
    }

    if (!kind.resize) {
        // A stretchy region must not let its *contents* set a floor under it.
        //
        // dvui clamps a widget's reported min size with `max_size_content`, so capping it along
        // the parent's axis stops the plugin inside from reserving space the app never granted.
        // Without this the bottom panel cannot be dragged open past whatever the editor above it
        // wants to be — the neighbour's content, not the layout, decides how far a sash travels.
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

    const box = dvui.box(src, .{ .dir = kind.dir }, box_opts);
    if (kind.resize) Sash.recordEdges(id, box.data(), axis);
    self.containers[self.depth] = .{ .dir = kind.dir, .box = box };
    self.depth += 1;

    // A region clips what it holds. Contents draw at their own natural size, so without this a
    // region squeezed narrower than its contents simply spills them over its neighbour instead
    // of getting smaller — which is what a half-closed sidebar looked like.
    const clip_to = box.data().contentRectScale().r;
    const prev_clip = dvui.clip(clip_to);

    // Drawn at every size except none. Skipping content at *zero* is just not doing work nobody
    // can see; skipping it below a threshold would be a policy, and it would also break the
    // layered form later — a tray blurring what is behind it needs the region underneath to have
    // drawn, at every size the tray takes.
    if (!shut_now and kind.keywords.len > 0) _ = try self.drawRegionContents(kind, matches);

    return .{ .box = box, .layout = self, .prev_clip = prev_clip };
}

fn roomOf(p: *Container, axis: dvui.enums.Direction) f32 {
    const b = p.box orelse return 0;
    const r = b.data().contentRect();
    return switch (axis) {
        .horizontal => r.w,
        .vertical => r.h,
    };
}


/// A draggable divider between the region before it and the region after it — `dvui.separator`
/// with a drag.
///
/// It takes no direction: a split divides the axis of the region it sits in, so direction is
/// declared once, on the container. Dragging it changes the stored extent of the nearest
/// preceding `resize` region, which is the entire resize model — one number per resizable
/// region, no ratios, no boundary table, and `dvui.box` doing the layout.
pub fn split(self: *Layout, src: std.builtin.SourceLocation, opts: SplitOptions) void {
    const c = self.innermost() orelse {
        dvui.log.err("split() outside a region does nothing", .{});
        return;
    };
    const axis = c.dir;

    var sep = Sash.sash(src, axis, 0);
    defer sep.end();
    if (!opts.resize) return;

    // Which neighbour this sash resizes. Preferring the one *before* it makes the sidebar case
    // work immediately; falling back to the one after is what the bottom panel needs, since a
    // panel is declared after its own split and cannot be known when the sash is drawn. That one
    // is bound by `region` and read back a frame later.
    var sign: f32 = 1;
    const target = c.last_resizable orelse blk: {
        sign = -1;
        break :blk dvui.dataGet(null, sep.box.data().id, "_after", dvui.Id) orelse {
            c.pending_split = sep.box.data().id;
            return;
        };
    };

    const container = c.box orelse return;
    c.handles += Sash.handle_size;
    const room = switch (axis) {
        .horizontal => container.data().contentRect().w,
        .vertical => container.data().contentRect().h,
    };
    sep.drag(container, target, sign, opts, .{
        .length = room,
        .base_min = c.base_min,
        .handles = c.handles,
        .others = c.resizables[0..c.resizable_count],
    });
}

/// What a `split` accepts. **The sash's own options, not a copy of them.**
///
/// This used to be a second struct with the same three fields, copied across field by field in
/// `split`. Its defaults then drifted from the sash's: `min` was lowered to zero in one place so
/// a region could be dragged shut, and stayed at 40 here — which silently won, and pinned every
/// sash 40pt from its end. Two structs describing one thing will always end up disagreeing about
/// it, so there is one.
pub const SplitOptions = Sash.Options;

/// The region's contents: its own chrome if it declared any, otherwise the active surface.
///
/// Everything reachable here is reachable by hand from `matching` / `selected` / `draw`, so a
/// shape wanting something else writes its own function and passes it as `content`.
fn drawRegionContents(self: *Layout, opts: anytype, matches: []const *Surface) !dvui.App.Result {
    _ = matches;
    const content = opts.content orelse return self.drawSelected(opts.keywords);
    return content(self, opts.keywords);
}
