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
const Split = core.dvui.Split;
const Constants = @import("../Constants.zig");

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
    /// Every resizable region in this container. A split needs them all, because honouring one
    /// drag can mean pushing the others back.
    resizables: [max_trays]dvui.Id = undefined,
    resizable_count: usize = 0,
    /// Total length the splits in this container take.
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
/// Declare a region. Lives on `Region` — the type it returns — and is re-exported here so a
/// shape writes `f.region(...)` beside `f.split(...)`. Same arrangement as `core.dvui.split`.
pub const region = Region.region;

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

    var divider = Split.split(src, axis, 0);
    defer divider.end();
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
    const room = switch (axis) {
        .horizontal => container.data().contentRect().w,
        .vertical => container.data().contentRect().h,
    };
    divider.drag(container, target, sign, opts, .{
        .length = room,
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

    var strip: fizzy.dvui.Tabs = .begin(@src(), &tabs_state, .{ .drag_name = "fizzy_tab_strip" });
    defer strip.end();

    for (surfaces, 0..) |s, i| {
        const is_selected = f.isSelected(keywords, s);
        var t = strip.tab(@src(), i, is_selected);
        defer t.end();

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
pub fn tabbed(f: *Layout, keywords: []const []const u8) !dvui.App.Result {
    f.tabs(keywords);
    return f.drawSelected(keywords);
}

/// Drag state for `tabStrip`. One strip per app in practice; a layout wanting two independent
/// strips copies this recipe (see CLAUDE.md's shipped-shapes note) rather than fizzy growing a
/// handle type for a case nothing has yet.
var tabs_state: fizzy.dvui.Tabs.State = .{};
