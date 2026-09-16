//! Docking widget: walks a `Layout.DockLayout` tree, laying out each split itself with a
//! `Split` sash between its children, and a tabbed header + content box per leaf. Floating leaves are
//! drawn afterwards in their own `FloatingWindowWidget`s.
//!
//! Usage:
//! ```
//! var dock = dockspace(@src(), .{ .layout = &layout, .panelInfo = myPanelInfo }, .{ .expand = .both });
//! defer dock.deinit(); // applies queued mutations, sets dock.changed
//! while (dock.panel()) |p| {
//!     defer p.end();
//!     app.drawPanel(p.id);
//! }
//! ```
//!
//! The layout tree is treated as immutable for the duration of the walk:
//! tab clicks, closes, and (later) drag-and-drop only queue `Layout.Mutation`
//! entries, applied by `deinit` once the last pane has closed. This keeps
//! node indices (and thus `split_ratio` pointers) valid for the whole frame.
const std = @import("std");
const dvui = @import("dvui");
const icon_tex = @import("../gfx/icon.zig");

const Options = dvui.Options;
const Rect = dvui.Rect;
const RectScale = dvui.RectScale;
const Size = dvui.Size;
const Widget = dvui.Widget;
const WidgetData = dvui.WidgetData;

pub const Layout = @import("DockingWidget/Layout.zig");
const Row = @import("DockingWidget/Row.zig");
const Split = @import("Split.zig");

const Dockspace = @This();

/// Verb form, same as `dvui.dockspace` upstream — here so this copy (and its tests) never reach
/// dvui's own `DockingWidget`, which would be a different type with the same name.
pub fn dockspace(src: std.builtin.SourceLocation, init_opts: InitOptions, opts: Options) *Dockspace {
    var ret = dvui.widgetAlloc(Dockspace);
    ret.init(src, init_opts, opts);
    return ret;
}

/// App-supplied display info for a panel slug, used to draw its tab.
pub const PanelInfo = struct {
    title: []const u8,
    icon: ?[]const u8 = null,
    closable: bool = true,
};

pub const CloseButtonVisibility = enum {
    /// Every closable tab always shows its close button.
    always,
    /// Only the active tab and the currently-hovered tab show a close button.
    hover,
};

pub const InitOptions = struct {
    layout: *Layout.DockLayout,
    /// How a leaf's tabs are drawn. Required for `.tabs`; unused for `.none`.
    panelInfo: ?*const fn (Layout.PanelId) PanelInfo = null,
    /// `.tabs` draws a tab strip over each leaf (the panel-docking form). `.none` draws only the
    /// active panel's content: a leaf is then a plain split-tree cell, and whatever chrome it
    /// wants — its own tab strip, a title — is the caller's, drawn inside `panel()`. Tabs can't
    /// be dragged between leaves in this form (there is no strip to drag from); a caller moves
    /// panels through `Layout` mutations instead.
    header: enum { tabs, none } = .tabs,
    /// The sash's thickness in logical px. Always reserved, at any ratio — a pane dragged shut
    /// leaves its handle standing, and shut panes stack theirs.
    handle_size: f32 = Split.handle_size,
    close_button_visibility: CloseButtonVisibility = .always,
    /// Draws into the trailing header space after a leaf's tab strip, given
    /// the leaf's active `panel`. The area expands to fill the rest of the
    /// header row and is entirely the app's — dvui draws nothing there. Null
    /// (default) leaves just the tab strip.
    drawHeaderExtra: ?*const fn (Layout.PanelId) void = null,
    /// Called every frame a tab's right-click context menu is open (each tab
    /// is wrapped in its own `dvui.context()`). `pt` anchors a `floatingMenu`;
    /// call `.close()` on it when a menu item is picked.
    onTabContextMenu: ?*const fn (panel: Layout.PanelId, pt: dvui.Point.Natural) void = null,
    /// Options for a box wrapping each docked leaf's whole area — tab strip and
    /// content together — so an app can theme the background/border around the
    /// header too, which wrapping `panel()`'s content alone can't reach. Null
    /// (default) opens no such box.
    panel_background: ?Options = null,
    /// Options layered onto every tab button in a leaf's strip, over
    /// `TabsWidget`'s own defaults. Lets an app restyle the strip — flat tabs,
    /// an underlined selection, a different corner — without dvui having to
    /// prescribe one look. Null (default) keeps the stock tab styling.
    tab_options: ?Options = null,
    /// Options layered onto the *active* tab only, over `tab_options`. Null
    /// (default) keeps `TabsWidget`'s stock selected-tab styling.
    tab_options_selected: ?Options = null,
};

wd: WidgetData,
init_opts: InitOptions,

/// Mutations queued by tab clicks/closes/drags this frame; applied to
/// `init_opts.layout` in `deinit`.
mutations: std.ArrayList(Layout.Mutation) = .empty,
/// True once a mutation has been queued this frame (caller should persist). Read it after the
/// `panel()` loop and before `deinit`, which frees the widget.
changed: bool = false,
/// A sash somewhere in the tree is being dragged this frame. Read before `deinit`.
dragging: bool = false,
/// A split somewhere in the tree is easing toward its settled ratio this frame. Read before
/// `deinit`.
animating: bool = false,

stack: std.ArrayList(StackFrame) = .empty,
started: bool = false,
float_index: usize = 0,
current_float: ?*dvui.FloatingWindowWidget = null,
content_box: ?*dvui.BoxWidget = null,
/// The `panel_background` box wrapping the current leaf's header + content,
/// when that option is set. Opened in `openLeaf`, closed last in
/// `closeContent` (outermost box).
panel_wrapper: ?*dvui.BoxWidget = null,
/// The box a leaf is placed in (its cell in the split), outermost of all, and the clip it set.
leaf_cell: ?*dvui.BoxWidget = null,
leaf_clip: ?Rect.Physical = null,
current_leaf: ?Layout.NodeIndex = null,

/// Drop target under the mouse during a "dvui_dock" drag, found while walking
/// leaves. Root-edge zones are a fallback checked in `deinit` only if no leaf
/// claimed the point (innermost zones win).
hover_target: ?DropTarget = null,
hover_rect: Rect.Physical = .{},

/// A drag-release seen mid-walk, resolved against `hover_target` in `deinit`
/// once every leaf (and thus every zone) has been visited this frame.
pending_drop: ?struct { slug: Layout.PanelId, point: dvui.Point.Physical } = null,

const StackFrame = struct {
    node: Layout.NodeIndex,
    dir: dvui.enums.Direction,
    /// The split's cell, relative to the dockspace's content. Splits open no widget of their
    /// own: every leaf cell and every sash is a direct child of the dockspace, placed by rect,
    /// so a leaf's widget id does not depend on how deep in the tree it sits — a collapse
    /// promotes the kept child a level up, and nested boxes would have rebuilt it there.
    rect: Rect,
    /// The drawn ratio this frame — the layout's settled `ratio` (or `fixed`) eased toward, and
    /// what a sash drag moves. Lives in dvui's data store under the dockspace, keyed by node;
    /// `enterNode` explains the choreography.
    shown: *f32,
    /// The split's content length along its axis, in points.
    extent: f32,
    /// Where the two children go, relative to the dockspace's content. Recomputed after a drag.
    first_rect: Rect,
    second_rect: Rect,
    visited_first: bool = false,
    visited_second: bool = false,
};

/// How long a split takes to slide open, shut, or to a new settled ratio.
const ease_us: i32 = 220_000;

const DropTarget = union(enum) {
    tab: struct { leaf: Layout.NodeIndex, index: usize },
    split: struct { leaf: Layout.NodeIndex, side: Layout.Side },
    split_root: Layout.Side,

    fn toMoveTarget(self: DropTarget) Layout.MoveTarget {
        return switch (self) {
            .tab => |t| .{ .tab = .{ .leaf = t.leaf, .index = t.index } },
            .split => |s| .{ .split = .{ .leaf = s.leaf, .side = s.side } },
            .split_root => |side| .{ .split_root = side },
        };
    }
};

/// Yielded by `panel()`; caller draws content then calls `end()` (typically via `defer`).
pub const Panel = struct {
    id: Layout.PanelId,
    leaf: Layout.NodeIndex,
    dockspace: *Dockspace,

    pub fn end(self: Panel) void {
        self.dockspace.closeContent();
    }
};

/// It's expected to call this when `self` is `undefined`
pub fn init(self: *Dockspace, src: std.builtin.SourceLocation, init_opts: InitOptions, opts: Options) void {
    const defaults = Options{ .name = "Dockspace" };
    self.* = .{ .wd = WidgetData.init(src, .{}, defaults.override(opts)), .init_opts = init_opts };
    dvui.parentSet(self.widget());
    self.data().register();
}

pub fn widget(self: *Dockspace) Widget {
    return Widget.init(self, data, rectFor, screenRectScale, minSizeForChild);
}

pub fn data(self: *Dockspace) *WidgetData {
    return self.wd.validate();
}

pub fn rectFor(self: *Dockspace, id: dvui.Id, min_size: Size, e: Options.Expand, g: Options.Gravity) Rect {
    _ = id;
    return dvui.placeIn(self.data().contentRect().justSize(), min_size, e, g);
}

pub fn screenRectScale(self: *Dockspace, rect: Rect) RectScale {
    return self.data().contentRectScale().rectToRectScale(rect);
}

pub fn minSizeForChild(self: *Dockspace, s: Size) void {
    self.data().minSizeMax(self.data().options.padSize(s));
}

/// Position-independent id for a panel's widgets (tab, close button, content
/// box), so their state (scroll, etc.) survives the panel being dragged
/// elsewhere.
fn slugIdExtra(slug: Layout.PanelId) usize {
    return @truncate(std.hash.Wyhash.hash(0, slug));
}

/// Queues `m` for `deinit` to apply, and sets `self.changed` now so callers can
/// read it right after the `while (dock.panel())` loop, before `deinit` runs.
fn queueMutation(self: *Dockspace, m: Layout.Mutation) void {
    self.mutations.append(dvui.currentWindow().arena(), m) catch return;
    self.changed = true;
}

/// Advances the walk by one leaf, returning its active panel, or null once
/// the whole tree (and all floats) have been walked.
pub fn panel(self: *Dockspace) ?Panel {
    const layout = self.init_opts.layout;
    while (true) {
        if (self.stack.items.len == 0) {
            if (!self.started) {
                self.started = true;
                if (self.enterNode(layout.root, null)) |p| return p;
                continue;
            }
            return self.nextFloat();
        }

        const frame = &self.stack.items[self.stack.items.len - 1];
        if (!frame.visited_first) {
            frame.visited_first = true;
            const child = layout.nodes.items[frame.node].split.first;
            if (self.enterNode(child, frame.first_rect)) |p| return p;
            continue;
        }
        if (!frame.visited_second) {
            frame.visited_second = true;
            const child = layout.nodes.items[frame.node].split.second;
            if (self.enterNode(child, frame.second_rect)) |p| return p;
            continue;
        }

        self.leaveSplit(frame);
        _ = self.stack.pop();
    }
}

// Per-split state is keyed by the split's *identity* (`Layout.keyOf`), never its node index: a
// collapse moves the kept child into its parent's slot, and state keyed by slot would be read
// by the wrong split afterwards.

fn shownKey(self: *Dockspace, node: Layout.NodeIndex) []const u8 {
    return std.fmt.allocPrint(dvui.currentWindow().arena(), "_shown:{d}", .{self.init_opts.layout.keyOf(node)}) catch "_shown";
}

fn animKey(self: *Dockspace, node: Layout.NodeIndex) []const u8 {
    return std.fmt.allocPrint(dvui.currentWindow().arena(), "_ease:{d}", .{self.init_opts.layout.keyOf(node)}) catch "_ease";
}

/// dvui has no way to drop an animation early; one that is already over is deleted at the start
/// of the next frame, which is the same thing a frame later.
fn cancelAnim(id: dvui.Id, key: []const u8) void {
    if (dvui.animationGet(id, key) == null) return;
    dvui.animation(id, key, .{ .start_val = 0, .end_val = 0, .end_time = 0 });
}

/// The ratio a child sits at when it has no width: `first` gone is 0, `second` gone is 1.
fn shutRatio(child: Layout.Node.Child) f32 {
    return switch (child) {
        .first => 0,
        .second => 1,
    };
}

fn along(r: Rect, dir: dvui.enums.Direction) f32 {
    return switch (dir) {
        .horizontal => r.w,
        .vertical => r.h,
    };
}

// ── Geometry ────────────────────────────────────────────────────────────────────────────────
//
// A split divides its cell into `first`, a sash, and `second`. The sash always takes its full
// `handle_size`, whatever the ratio: a pane dragged shut leaves its handle standing at the edge,
// which is the thing you drag it back out by, and several shut in a row stack their handles side
// by side and read as the several handles they are. So a subtree has a *floor* along an axis —
// the room its own sashes on that axis need — and a ratio divides what is left above the floors.

/// The least room `node` needs along `dir`: its same-axis sashes, summed; across a cross-axis
/// split the two children sit one above the other, so the wider of the two.
fn floorAlong(self: *Dockspace, node: Layout.NodeIndex, dir: dvui.enums.Direction) f32 {
    const layout = self.init_opts.layout;
    return switch (layout.nodes.items[node]) {
        .leaf, .free => 0,
        .split => |sp| if (sp.dir == dir)
            self.floorAlong(sp.first, dir) + self.gapOf(node) + self.floorAlong(sp.second, dir)
        else
            @max(self.floorAlong(sp.first, dir), self.floorAlong(sp.second, dir)),
    };
}

/// The sash's thickness for `node`: `handle_size`, except on a split closing for good, whose
/// sash folds away with the last of the closing child — a place closing reaches nothing, not
/// nearly nothing. Left whole, the sash is ten points handed back in one step the frame the
/// leaf is dropped, which is the only part of an otherwise smooth close anyone sees.
fn gapOf(self: *Dockspace, node: Layout.NodeIndex) f32 {
    const gap = self.init_opts.handle_size;
    const sp = switch (self.init_opts.layout.nodes.items[node]) {
        .split => |sp| sp,
        else => return gap,
    };
    const going = sp.closing orelse return gap;
    const shown = dvui.dataGet(null, self.data().id, self.shownKey(node), f32) orelse return gap;
    // How far the closing child still reaches, as a share of the split's usable room; it is an
    // emptied leaf, so its length is that share of whatever the split holds. The fold begins
    // once that is under a sash's width.
    const extent = dvui.dataGet(null, self.data().id, self.extentKey(node), f32) orelse return gap;
    const share = switch (going) {
        .first => shown,
        .second => 1 - shown,
    };
    return @min(gap, @max(0, share * extent));
}

fn extentKey(self: *Dockspace, node: Layout.NodeIndex) []const u8 {
    return std.fmt.allocPrint(dvui.currentWindow().arena(), "_extent:{d}", .{self.init_opts.layout.keyOf(node)}) catch "_extent";
}

/// How `extent` divides at `ratio`: `first` is the first child's length; `usable` the room the
/// ratio is a share of (the extent less the sash and both floors).
fn divide(self: *Dockspace, node: Layout.NodeIndex, extent: f32, ratio: f32) Row.Division {
    const sp = self.init_opts.layout.nodes.items[node].split;
    return Row.divide(extent, ratio, self.gapOf(node), self.floorAlong(sp.first, sp.dir), self.floorAlong(sp.second, sp.dir));
}

/// The child rects and sash rect for a split of content size `cr` at `ratio`.
fn cellRects(self: *Dockspace, node: Layout.NodeIndex, cr: Rect, ratio: f32) @TypeOf(Row.cellRects(cr, .horizontal, 0, 0)) {
    const sp = self.init_opts.layout.nodes.items[node].split;
    const d = self.divide(node, along(cr, sp.dir), ratio);
    return Row.cellRects(cr, sp.dir, d.first, self.gapOf(node));
}

fn minKey(self: *Dockspace, node: Layout.NodeIndex) []const u8 {
    return std.fmt.allocPrint(dvui.currentWindow().arena(), "_min:{d}", .{self.init_opts.layout.keyOf(node)}) catch "_min";
}

/// The share a `fit` child needs for its content — what its leaf cell reported last frame —
/// clamped to the fit's bounds. Null before the child has drawn once (nothing to fit to), or
/// when the child is not a leaf.
fn fittedRatio(self: *Dockspace, node: Layout.NodeIndex, fit: Layout.Node.Split.Fit, usable: f32) ?f32 {
    const layout = self.init_opts.layout;
    const sp = layout.nodes.items[node].split;
    const child = Layout.childIndex(sp, fit.child);
    if (layout.nodes.items[child] != .leaf) return null;
    if (usable <= 0) return null;
    const min = dvui.dataGet(null, self.data().id, self.minKey(child), Size) orelse return null;
    const need = along(.{ .w = min.w, .h = min.h }, sp.dir);
    const share = std.math.clamp(need / usable, fit.min, fit.max);
    return switch (fit.child) {
        .first => share,
        .second => 1 - share,
    };
}

/// The drawn ratio for `node`, seeded at `target`.
fn shownPtr(self: *Dockspace, node: Layout.NodeIndex, target: f32) *f32 {
    return dvui.dataGetPtrDefault(null, self.data().id, self.shownKey(node), f32, target);
}

// ── Dragging a sash: the two sides accordion ─────────────────────────────────────────────────
//
// Nested splits on one axis are, to the user, a row of panes with boundaries between them, and
// a drag moves one boundary. Arithmetic is `Row.dragBoundary`: the boundary goes where the
// pointer is, and each side of it scales as a group — every pane on the squeezed side shrinks
// in proportion, keeping its share of that side, down to nothing, and the panes on the other
// side grow the same way. Drag back and they open out in the same proportions. Every split on
// the row then reads its ratio off the new positions (`Row.ratioFor`). Sashes are never scaled:
// each keeps its full width, so shut panes stack their handles at the boundary.

const Boundary = struct { node: Layout.NodeIndex, pos: f32 };

/// The same-axis splits under `node`, in row order, with each boundary's position (the start
/// of its sash) relative to the row's origin.
fn collectRow(self: *Dockspace, node: Layout.NodeIndex, dir: dvui.enums.Direction, origin: f32, extent: f32, out: *std.ArrayList(Boundary)) void {
    const layout = self.init_opts.layout;
    const sp = switch (layout.nodes.items[node]) {
        .split => |sp| sp,
        else => return,
    };
    if (sp.dir != dir) return;
    const ratio = if (dvui.dataGet(null, self.data().id, self.shownKey(node), f32)) |v| v else Layout.targetRatio(sp, extent);
    const d = self.divide(node, extent, ratio);
    self.collectRow(sp.first, dir, origin, d.first, out);
    out.append(dvui.currentWindow().arena(), .{ .node = node, .pos = origin + d.first }) catch {};
    self.collectRow(sp.second, dir, origin + d.first + self.gapOf(node), @max(0, extent - d.first - self.gapOf(node)), out);
}

/// The cells between the row's boundaries, in order — a leaf or a cross-axis subtree — so their
/// floors can hold a pushed boundary off them.
fn collectCells(self: *Dockspace, node: Layout.NodeIndex, dir: dvui.enums.Direction, out: *std.ArrayList(Layout.NodeIndex)) void {
    const layout = self.init_opts.layout;
    switch (layout.nodes.items[node]) {
        .split => |sp| if (sp.dir == dir) {
            self.collectCells(sp.first, dir, out);
            self.collectCells(sp.second, dir, out);
            return;
        },
        else => {},
    }
    out.append(dvui.currentWindow().arena(), node) catch {};
}

/// Write the row's positions back as each split's drawn ratio, and queue the settled value.
fn assignRow(self: *Dockspace, node: Layout.NodeIndex, dir: dvui.enums.Direction, origin: f32, extent: f32, collected: []const Boundary) void {
    const layout = self.init_opts.layout;
    const sp = switch (layout.nodes.items[node]) {
        .split => |sp| sp,
        else => return,
    };
    if (sp.dir != dir) return;
    const pos = for (collected) |b| {
        if (b.node == node) break b.pos;
    } else return;
    const gap = self.gapOf(node);
    const first_len = pos - origin;
    const d = self.divide(node, extent, 0);
    const ratio = Row.ratioFor(first_len, extent, gap, d.floor_first, d.floor_second);
    self.shownPtr(node, ratio).* = ratio;
    cancelAnim(self.data().id, self.animKey(node));
    self.queueMutation(.{ .set_ratio = .{ .split = node, .ratio = ratio, .extent = d.usable } });
    self.assignRow(sp.first, dir, origin, first_len, collected);
    self.assignRow(sp.second, dir, pos + gap, @max(0, extent - first_len - gap), collected);
}

/// A drag on `frame`'s sash to `to` (physical, along the axis): gather the row, resolve it
/// with `Row.dragBoundary`, write every affected split's ratio.
fn dragTo(self: *Dockspace, frame: *StackFrame, to: f32) void {
    const dir = frame.dir;
    const gap = self.init_opts.handle_size;

    var root_i = self.stack.items.len - 1;
    while (root_i > 0 and self.stack.items[root_i - 1].dir == dir) root_i -= 1;
    const root = &self.stack.items[root_i];
    const crs = self.data().contentRectScale();
    const origin_px = switch (dir) {
        .horizontal => crs.r.x + root.rect.x * crs.s,
        .vertical => crs.r.y + root.rect.y * crs.s,
    };

    var collected: std.ArrayList(Boundary) = .empty;
    self.collectRow(root.node, dir, 0, root.extent, &collected);
    var cells: std.ArrayList(Layout.NodeIndex) = .empty;
    self.collectCells(root.node, dir, &cells);
    if (collected.items.len == 0 or cells.items.len != collected.items.len + 1) return;

    const k = for (collected.items, 0..) |b, i| {
        if (b.node == frame.node) break i;
    } else return;

    const arena = dvui.currentWindow().arena();
    const boundaries = arena.alloc(f32, collected.items.len) catch return;
    const floors = arena.alloc(f32, cells.items.len) catch return;
    for (collected.items, 0..) |b, i| boundaries[i] = b.pos;
    for (cells.items, 0..) |c, i| floors[i] = self.floorAlong(c, dir);

    var r = Row{ .boundaries = boundaries, .floors = floors, .gap = gap, .extent = root.extent };
    r.dragBoundary(k, (to - origin_px) / crs.s - gap / 2);
    for (collected.items, 0..) |*b, i| b.pos = r.boundaries[i];

    self.assignRow(root.node, dir, 0, root.extent, collected.items);
    self.dragging = true;
    dvui.refresh(null, @src(), self.data().id);
}

/// Close out a split after both children have been walked: ease the drawn ratio toward the
/// settled one and, once a closing split has shut, collapse it.
fn leaveSplit(self: *Dockspace, frame: *StackFrame) void {
    const layout = self.init_opts.layout;

    const sp = layout.nodes.items[frame.node].split;
    if (!layout.animated or self.dragging) return;

    const d = self.divide(frame.node, frame.extent, 0);
    const target = if (sp.closing) |c| shutRatio(c) else Layout.targetRatio(sp, d.usable);
    const key = self.animKey(frame.node);
    if (dvui.animationGet(self.data().id, key)) |a| {
        self.animating = true;
        if (@abs(a.end_val - target) > 0.0005) {
            // Retargeted mid-slide (a leaf emptied while opening): continue from where it is.
            dvui.animation(self.data().id, key, .{ .start_val = frame.shown.*, .end_val = target, .end_time = ease_us, .easing = dvui.easing.outCubic });
        } else {
            frame.shown.* = a.value();
            if (a.done()) {
                frame.shown.* = target;
                if (sp.closing != null) self.finishClose(frame.node);
            }
        }
        dvui.refresh(null, @src(), self.data().id);
    } else if (@abs(frame.shown.* - target) > 0.0005) {
        dvui.animation(self.data().id, key, .{ .start_val = frame.shown.*, .end_val = target, .end_time = ease_us, .easing = dvui.easing.outCubic });
        dvui.refresh(null, @src(), self.data().id);
    } else if (sp.closing != null) {
        self.finishClose(frame.node);
    }
}

/// The split has shut over `going`: collapse it. State is keyed by identity, so the kept child's
/// drawn ratio needs no moving when it takes the split's slot.
fn finishClose(self: *Dockspace, node: Layout.NodeIndex) void {
    dvui.dataRemove(null, self.data().id, self.shownKey(node));
    cancelAnim(self.data().id, self.animKey(node));
    self.queueMutation(.{ .collapse = node });
}

/// Enters `node` in `cell` (relative to the current parent's content; null fills it): for a
/// split, opens its box, runs its sash, and pushes a stack frame (returns null so the caller
/// loop continues); for a leaf, draws the header and opens the content box, returning the
/// yielded `Panel`.
fn enterNode(self: *Dockspace, node: Layout.NodeIndex, cell: ?Rect) ?Panel {
    const layout = self.init_opts.layout;
    // A cell squeezed to nothing draws nothing. Not an optimisation: dvui reads a zero-width
    // `rect` as "use the minimum size", so a pane at zero would come back at its content's
    // width and paint over whatever is beside it.
    if (cell) |c| if (c.w <= 0.5 or c.h <= 0.5) return null;
    switch (layout.nodes.items[node]) {
        .split => |sp| {
            const cr = cell orelse self.data().contentRect().justSize();
            const extent = along(cr, sp.dir);
            dvui.dataSet(null, self.data().id, self.extentKey(node), extent);
            const d0 = self.divide(node, extent, 0);
            var target = Layout.targetRatio(sp, d0.usable);
            if (sp.fit) |fit| if (self.fittedRatio(node, fit, d0.usable)) |r| {
                target = r;
                // Written through, so a caller reading `ratio` sees where the fit has settled.
                layout.nodes.items[node].split.ratio = r;
            };

            // `shown` is what is drawn; `ratio`/`fixed` is where it settles. The two differ
            // only mid-slide or mid-drag: a fresh split starts its new child at nothing and
            // eases to `ratio`; a closing split eases to nothing and is then collapsed
            // (`leaveSplit`); a drag moves `shown` directly and is written back on release.
            // Without `animated` there is no gap and the settled ratio is what is drawn.
            const shown: *f32 = if (layout.animated) blk: {
                const ptr = self.shownPtr(node, target);
                if (sp.opening) |c| {
                    ptr.* = shutRatio(c);
                    layout.nodes.items[node].split.opening = null;
                    dvui.animation(self.data().id, self.animKey(node), .{ .start_val = ptr.*, .end_val = target, .end_time = ease_us, .easing = dvui.easing.outCubic });
                    dvui.refresh(null, @src(), self.data().id);
                }
                break :blk ptr;
            } else blk: {
                const ptr = self.shownPtr(node, target);
                ptr.* = target;
                break :blk ptr;
            };

            var rects = self.cellRects(node, cr, shown.*);
            self.stack.append(dvui.currentWindow().arena(), .{
                .node = node,
                .dir = sp.dir,
                .rect = cr,
                .shown = shown,
                .extent = extent,
                .first_rect = rects.first,
                .second_rect = rects.second,
            }) catch {};
            const frame = &self.stack.items[self.stack.items.len - 1];

            // The sash: fizzy's split handle, placed in the gap, matched on the box so it grows
            // as the pointer approaches. Run before the children so a press near the sash is the
            // sash's, not the pane's.
            var sash = Split.initSized(@src(), sp.dir, layout.keyOf(node), rects.sash, self.gapOf(node));
            const g = sash.grab(self.data());
            if (dvui.captured(sash.box.data().id)) self.dragging = true;
            if (g.to) |to| {
                self.dragTo(frame, to);
                rects = self.cellRects(node, cr, shown.*);
                frame.first_rect = rects.first;
                frame.second_rect = rects.second;
            }
            sash.draw(g.dist);
            sash.deinit();
            return null;
        },
        .leaf => return self.openLeaf(node, cell),
        .free => unreachable,
    }
}

fn openLeaf(self: *Dockspace, node: Layout.NodeIndex, cell: ?Rect) ?Panel {
    const layout = self.init_opts.layout;
    const leaf = layout.nodes.items[node].leaf;
    if (leaf.tabs.items.len == 0) return null; // tolerated empty root leaf

    // The leaf's cell in its split. A leaf clips what it holds: a pane squeezed narrower than
    // its content must get smaller, not spill over its neighbour.
    self.leaf_cell = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = if (cell == null) .both else .none,
        .rect = cell,
        .id_extra = layout.keyOf(node),
        .background = false,
    });
    self.leaf_clip = dvui.clip(self.leaf_cell.?.data().contentRectScale().r);
    self.current_leaf = node;

    if (self.init_opts.panel_background) |bg_opts| {
        const defaults = Options{ .name = "Dockspace.panel_background", .expand = .both };
        self.panel_wrapper = dvui.box(@src(), .{}, defaults.override(bg_opts).override(.{ .id_extra = layout.keyOf(node) }));
    }

    const header_rect: ?Rect.Physical = switch (self.init_opts.header) {
        .tabs => self.drawHeader(node, leaf),
        .none => null,
    };

    const active_slug = leaf.tabs.items[leaf.active];
    const box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .id_extra = slugIdExtra(active_slug) });
    self.content_box = box;

    if (dvui.dragName("dvui_dock")) {
        if (header_rect) |hr| self.checkHeaderZone(node, hr);
        self.checkLeafZones(node, box.data().contentRectScale().r);
    }

    return .{ .id = active_slug, .leaf = node, .dockspace = self };
}

/// The header (tab strip + trailing space) is always an "insert as tab" target:
/// a drop there adds the dragged tab as a sibling, never a split (unlike
/// `checkLeafZones`' N/S/E/W content zones).
fn checkHeaderZone(self: *Dockspace, node: Layout.NodeIndex, r: Rect.Physical) void {
    const mouse = dvui.currentWindow().mouse_pt;
    if (!r.contains(mouse)) return;
    const leaf = self.init_opts.layout.nodes.items[node].leaf;
    self.hover_target = .{ .tab = .{ .leaf = node, .index = leaf.tabs.items.len } };
    self.hover_rect = r;
}

/// Drop zones for one leaf's content rect `r` (physical) — `Layout.zoneAt` is the geometry: a
/// centre zone (append as a new tab) and N/S/E/W edge strips (split that side), the strips
/// clamped to 40 logical px thick.
fn checkLeafZones(self: *Dockspace, node: Layout.NodeIndex, r: Rect.Physical) void {
    const mouse = dvui.currentWindow().mouse_pt;
    const hit = Layout.zoneAt(r, mouse, 40.0 * dvui.windowNaturalScale()) orelse return;
    self.hover_rect = hit.rect;
    self.hover_target = switch (hit.zone) {
        .tab => .{ .tab = .{ .leaf = node, .index = self.init_opts.layout.nodes.items[node].leaf.tabs.items.len } },
        .split => |side| .{ .split = .{ .leaf = node, .side = side } },
    };
}

/// Root-edge drop zones (24 logical px), checked only if no leaf already
/// claimed the mouse point: innermost (leaf) zones win over root zones.
fn checkRootZones(self: *Dockspace) void {
    if (self.hover_target != null) return;
    if (!dvui.dragName("dvui_dock")) return;

    const r = self.data().contentRectScale().r;
    const mouse = dvui.currentWindow().mouse_pt;
    const hit = Layout.edgeAt(r, mouse, 24.0 * dvui.windowNaturalScale()) orelse return;
    self.hover_target = .{ .split_root = hit.side };
    self.hover_rect = hit.rect;
}

/// Resolves a completed drop: moves `slug` to the currently hovered zone, or
/// (per spec) floats it at the release point if it was dropped outside any zone.
fn resolveDrop(self: *Dockspace, slug: Layout.PanelId, release_point: dvui.Point.Physical) void {
    if (self.hover_target) |target| {
        self.queueMutation(.{ .move = .{ .panel = slug, .target = target.toMoveTarget() } });
    } else {
        const p = release_point.toNatural();
        const size: Size = .{ .w = 300, .h = 200 };
        self.queueMutation(.{ .float = .{ .panel = slug, .rect = .{ .x = p.x - size.w / 2, .y = p.y - size.h / 2, .w = size.w, .h = size.h } } });
    }
}

fn closeContent(self: *Dockspace) void {
    if (self.content_box) |b| {
        b.deinit();
        self.content_box = null;
    }
    // `panel_wrapper` wraps this leaf's header + content and, for a float, is
    // opened *inside* `current_float`'s FloatingWindowWidget subwindow (see
    // `openLeaf`, called from both `enterNode` and `nextFloat`) — it must
    // close before that subwindow does, or the widget stack unwinds out of
    // LIFO order and corrupts `current_parent`.
    if (self.panel_wrapper) |w| {
        w.deinit();
        self.panel_wrapper = null;
    }
    if (self.leaf_cell) |c| {
        if (self.leaf_clip) |clip| dvui.clipSet(clip);
        self.leaf_clip = null;
        // What the cell's content asked for, for a parent split that fits to it. `min_size`
        // has accumulated every child's report by now; dvui only stores it at `deinit`.
        if (self.current_leaf) |leaf| dvui.dataSet(null, self.data().id, self.minKey(leaf), c.data().options.padSize(c.data().min_size));
        c.deinit();
        self.leaf_cell = null;
    }
    if (self.current_float) |f| {
        f.deinit();
        self.current_float = null;
    }
}

/// Draws the tab strip (plus `drawHeaderExtra`'s trailing content, if set) and
/// returns the header row's rect (used by `checkHeaderZone`).
fn drawHeader(self: *Dockspace, node: Layout.NodeIndex, leaf: Layout.Node.Leaf) Rect.Physical {
    var header_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = self.init_opts.layout.keyOf(node) });
    defer header_row.deinit();

    // Captured per tab below so `onTabContextMenu` can read a rect back after
    // the tab strip closes, without a round trip through `dvui.tag()` — that
    // registry is global per window, so keying it by the bare slug would
    // collide across two dockspaces that happen to share a panel id.
    const tab_rects: []Rect.Physical = dvui.currentWindow().arena().alloc(Rect.Physical, leaf.tabs.items.len) catch &[_]Rect.Physical{};

    {
        // When `drawHeaderExtra` is set, its box (below) claims the leftover
        // width instead, so drops and right-clicks on the empty space reach the
        // app rather than an oversized tab strip.
        const tw_expand: Options.Expand = if (self.init_opts.drawHeaderExtra != null) .none else .horizontal;
        var tw = dvui.tabs(@src(), .{ .dir = .horizontal }, .{ .expand = tw_expand, .id_extra = self.init_opts.layout.keyOf(node) });
        defer tw.deinit();

        for (leaf.tabs.items, 0..) |slug, i| {
            const info = if (self.init_opts.panelInfo) |f| f(slug) else PanelInfo{ .title = slug };
            const selected = i == leaf.active;

            // App styling first, then the selected-only layer, and finally the
            // tab's identity — which must win, since the strip's own event
            // handling looks tabs back up by id. `.tag = slug` is the public
            // hook for addressing a tab from outside (tests, automation);
            // it's a plain slug so two dockspaces sharing a panel id will
            // collide there, same as any other dvui tag.
            var tab_opts: Options = self.init_opts.tab_options orelse .{};
            if (selected) {
                if (self.init_opts.tab_options_selected) |sel| tab_opts = tab_opts.override(sel);
            }
            tab_opts = tab_opts.override(.{ .id_extra = slugIdExtra(slug), .tag = slug });

            var tab = tw.addTab(selected, .{ .process_events = false }, tab_opts);
            defer tab.deinit();

            if (i < tab_rects.len) tab_rects[i] = tab.data().rectScale().r;

            {
                var tab_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
                defer tab_row.deinit();
                if (info.icon) |ic| icon_tex.icon(@src(), "docktab_icon", ic, .{}, .{ .gravity_y = 0.5 });
                dvui.label(@src(), "{s}", .{info.title}, .{ .gravity_y = 0.5 });
                const show_close = info.closable and switch (self.init_opts.close_button_visibility) {
                    .always => true,
                    .hover => i == leaf.active or tab.hovered(),
                };
                if (show_close) {
                    const close_tag = std.fmt.allocPrint(dvui.currentWindow().arena(), "docktab_close:{s}", .{slug}) catch null;
                    // Processed before the tab's own click handling below, so a
                    // close click isn't also read as a tab-select.
                    if (dvui.buttonIcon(@src(), "docktab_close", dvui.entypo.cross, .{}, .{}, .{
                        .id_extra = slugIdExtra(slug),
                        .tag = close_tag,
                        .gravity_y = 0.5,
                        .padding = Rect.all(2),
                        .margin = Rect.all(2),
                    })) {
                        self.queueMutation(.{ .remove = slug });
                    }
                }
            }

            self.processTabEvents(tab.data(), node, i, slug);
        }
    }

    if (self.init_opts.onTabContextMenu) |cb| {
        for (leaf.tabs.items, 0..) |slug, i| {
            if (i >= tab_rects.len) continue;
            var cxt = dvui.context(@src(), .{ .rect = tab_rects[i] }, .{ .id_extra = slugIdExtra(slug) });
            defer cxt.deinit();
            if (cxt.activePoint()) |cp| cb(slug, cp);
        }
    }

    if (self.init_opts.drawHeaderExtra) |drawFn| {
        // Claims the leftover width so the callback owns the whole trailing
        // area (e.g. to catch a right-click on empty space), not just what it
        // visibly draws.
        var extra = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .gravity_y = 0.5 });
        defer extra.deinit();
        drawFn(leaf.tabs.items[leaf.active]);
    }

    return header_row.data().contentRectScale().r;
}

/// Raw press/motion/release handling for one tab button: a press+release with no
/// significant motion selects the tab; crossing the drag threshold starts a named
/// "dvui_dock" drag instead, resolved against `hover_target` on release. Bypasses
/// `ButtonWidget`'s click detection, which has no notion of a drag.
fn processTabEvents(self: *Dockspace, wd: *WidgetData, node: Layout.NodeIndex, index: usize, slug: Layout.PanelId) void {
    for (dvui.events()) |*e| {
        if (!dvui.eventMatchSimple(e, wd)) continue;
        const me = switch (e.evt) {
            .mouse => |me| me,
            else => continue,
        };
        switch (me.action) {
            .press => if (me.button.pointer()) {
                e.handle(@src(), wd);
                dvui.captureMouse(wd, e.num);
                dvui.dragPreStart(me.button, me.p, .{ .name = "dvui_dock", .cursor = .arrow_all });
            },
            .motion => if (dvui.captured(wd.id)) {
                e.handle(@src(), wd);
                _ = dvui.dragging(me.p, "dvui_dock");
            },
            .release => if (me.button.pointer() and dvui.captured(wd.id)) {
                e.handle(@src(), wd);
                dvui.captureMouse(null, e.num);
                if (dvui.dragName("dvui_dock")) {
                    // Don't `dragEnd()` yet: leaves later in this walk still need
                    // the drag active to compute their own drop zones.
                    self.pending_drop = .{ .slug = slug, .point = me.p };
                } else {
                    dvui.dragEnd();
                    self.queueMutation(.{ .set_active = .{ .leaf = node, .index = index } });
                }
            },
            else => {},
        }
    }
}

fn nextFloat(self: *Dockspace) ?Panel {
    const layout = self.init_opts.layout;
    while (self.float_index < layout.floats.items.len) {
        const idx = self.float_index;
        self.float_index += 1;

        const fwin = dvui.floatingWindow(@src(), .{
            .rect = &layout.floats.items[idx].rect,
        }, .{ .id_extra = layout.floats.items[idx].leaf });
        self.current_float = fwin;

        if (self.openLeaf(layout.floats.items[idx].leaf, null)) |p| return p;

        // Empty float leaf (shouldn't normally happen): close and try the next one.
        fwin.deinit();
        self.current_float = null;
    }
    return null;
}

pub fn deinit(self: *Dockspace) void {
    defer if (dvui.widgetIsAllocated(self)) dvui.widgetFree(self);
    defer self.* = undefined;

    self.checkRootZones();
    if (self.hover_target != null) {
        // Drawn last (on top of everything else this widget drew this frame).
        self.hover_rect.fill(dvui.CornerRect.Physical.all(0), .{ .color = .{ .color = dvui.themeGet().focus.opacity(0.25) } });
    }

    if (self.pending_drop) |pd| {
        self.resolveDrop(pd.slug, pd.point);
        dvui.dragEnd();
    }

    for (self.mutations.items) |m| self.init_opts.layout.apply(m) catch {};

    self.data().minSizeSetAndRefresh();
    self.data().minSizeReportToParent();
    dvui.parentReset(self.data().id, self.data().parent);
}

fn testPanelInfo(id: Layout.PanelId) PanelInfo {
    return .{ .title = id, .closable = true };
}

test "dockspace renders nested splits, floats, and applies tab mutations" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();

    const fns = struct {
        var layout: Layout.DockLayout = undefined;
        var inited = false;
        var last_changed = false;

        fn frame() !dvui.App.Result {
            if (!inited) {
                layout = try Layout.DockLayout.initSingleLeaf(std.testing.allocator, "a");
                try layout.splitLeaf(layout.root, .right, "b");
                try layout.insertTab(layout.findPanel("b").?, 1, "c");
                // Kept away from the header row (y ~0-30) of either dock leaf,
                // so it doesn't sit on top of and steal clicks meant for them.
                try layout.floatPanel("c", .{ .x = 150, .y = 300, .w = 150, .h = 80 });
                inited = true;
            }

            var dock = dockspace(@src(), .{ .layout = &layout, .panelInfo = testPanelInfo }, .{ .expand = .both });
            defer dock.deinit();
            while (dock.panel()) |p| {
                defer p.end();
                dvui.label(@src(), "content:{s}", .{p.id}, .{});
            }
            if (dock.changed) last_changed = true;

            return .ok;
        }
    };
    defer fns.layout.deinit();

    try dvui.testing.settle(fns.frame);
    try std.testing.expect(fns.layout.contains("a"));
    try std.testing.expect(fns.layout.contains("b"));
    try std.testing.expect(fns.layout.contains("c"));
    try std.testing.expect(fns.layout.isFloat(fns.layout.findPanel("c").?));

    // Clicking tab "b" activates it (set_active mutation applied on deinit).
    fns.last_changed = false;
    try dvui.testing.moveTo("b");
    try dvui.testing.click(.left);
    try dvui.testing.settle(fns.frame);
    try std.testing.expect(fns.last_changed);
    const b_leaf = fns.layout.findPanel("b").?;
    try std.testing.expectEqualStrings("b", fns.layout.nodes.items[b_leaf].leaf.tabs.items[fns.layout.nodes.items[b_leaf].leaf.active]);

    // Closing tab "a" removes it from the layout (remove mutation applied on deinit).
    fns.last_changed = false;
    try dvui.testing.moveTo("docktab_close:a");
    try dvui.testing.click(.left);
    try dvui.testing.settle(fns.frame);
    try std.testing.expect(fns.last_changed);
    try std.testing.expect(!fns.layout.contains("a"));
}

test "dockspace drawHeaderExtra: called once per leaf for the active tab, app owns the content" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();

    const fns = struct {
        var layout: Layout.DockLayout = undefined;
        var inited = false;
        var drawn_for: std.ArrayList(Layout.PanelId) = .empty;

        fn drawHeaderExtra(id: Layout.PanelId) void {
            drawn_for.append(std.testing.allocator, id) catch {};
            // The app can put whatever it wants here — a button, an icon,
            // several of each — dvui neither knows nor cares. `id_extra`
            // disambiguates the two leaves' otherwise-identical buttons,
            // same as any other app code drawing per-panel widgets.
            _ = dvui.button(@src(), "extra", .{}, .{ .id_extra = slugIdExtra(id) });
        }

        fn frame() !dvui.App.Result {
            if (!inited) {
                layout = try Layout.DockLayout.initSingleLeaf(std.testing.allocator, "a");
                try layout.splitLeaf(layout.root, .right, "b");
                inited = true;
            }

            var dock = dockspace(@src(), .{
                .layout = &layout,
                .panelInfo = testPanelInfo,
                .drawHeaderExtra = drawHeaderExtra,
            }, .{ .expand = .both });
            defer dock.deinit();
            while (dock.panel()) |p| {
                defer p.end();
                dvui.label(@src(), "content:{s}", .{p.id}, .{});
            }

            return .ok;
        }
    };
    defer fns.layout.deinit();
    defer fns.drawn_for.deinit(std.testing.allocator);

    try dvui.testing.settle(fns.frame);

    // `settle` may run `frame` more than once, so don't assume an exact
    // call count — just that both leaves' active tabs got a call.
    try std.testing.expect(fns.drawn_for.items.len >= 2);
    var saw_a = false;
    var saw_b = false;
    for (fns.drawn_for.items) |id| {
        if (std.mem.eql(u8, id, "a")) saw_a = true;
        if (std.mem.eql(u8, id, "b")) saw_b = true;
    }
    try std.testing.expect(saw_a);
    try std.testing.expect(saw_b);
}

test "dockspace onTabContextMenu: fires while a tab's context menu is open, closes on pick" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();

    const fns = struct {
        var layout: Layout.DockLayout = undefined;
        var inited = false;
        var call_count: usize = 0;
        var last_id: ?Layout.PanelId = null;

        fn onTabContextMenu(id: Layout.PanelId, pt: dvui.Point.Natural) void {
            call_count += 1;
            last_id = id;

            var fw = dvui.floatingMenu(@src(), .{ .from = dvui.Rect.Natural.fromPoint(pt) }, .{});
            defer fw.deinit();
            if (dvui.menuItemLabel(@src(), "Add Something", .{}, .{ .tag = "ctx_add" }) != null) {
                fw.close();
            }
        }

        fn frame() !dvui.App.Result {
            if (!inited) {
                layout = try Layout.DockLayout.initSingleLeaf(std.testing.allocator, "a");
                try layout.insertTab(layout.root, 1, "b");
                inited = true;
            }

            var dock = dockspace(@src(), .{
                .layout = &layout,
                .panelInfo = testPanelInfo,
                .onTabContextMenu = onTabContextMenu,
            }, .{ .expand = .both });
            defer dock.deinit();
            while (dock.panel()) |p| {
                defer p.end();
                dvui.label(@src(), "content:{s}", .{p.id}, .{});
            }

            return .ok;
        }
    };
    defer fns.layout.deinit();

    try dvui.testing.settle(fns.frame);
    try std.testing.expectEqual(@as(usize, 0), fns.call_count);

    try dvui.testing.moveTo("a");
    try dvui.testing.click(.right);
    try dvui.testing.settle(fns.frame);

    try std.testing.expect(fns.call_count > 0);
    try std.testing.expectEqualStrings("a", fns.last_id.?);

    // Picking the item closes the context menu: further frames stop calling back.
    try dvui.testing.moveTo("ctx_add");
    try dvui.testing.click(.left);
    try dvui.testing.settle(fns.frame);

    const count_after_pick = fns.call_count;
    try dvui.testing.settle(fns.frame);
    try std.testing.expectEqual(count_after_pick, fns.call_count);
}

test "dockspace onTabContextMenu: reads each dockspace's own tab rect, not a stale one from another dockspace open the same frame" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();

    const fns = struct {
        var layout_a: Layout.DockLayout = undefined;
        var layout_b: Layout.DockLayout = undefined;
        var inited = false;
        var calls_a: usize = 0;
        var calls_b: usize = 0;

        fn onCtxA(id: Layout.PanelId, pt: dvui.Point.Natural) void {
            _ = id;
            calls_a += 1;
            var fw = dvui.floatingMenu(@src(), .{ .from = dvui.Rect.Natural.fromPoint(pt) }, .{ .id_extra = 1 });
            defer fw.deinit();
        }
        fn onCtxB(id: Layout.PanelId, pt: dvui.Point.Natural) void {
            _ = id;
            calls_b += 1;
            var fw = dvui.floatingMenu(@src(), .{ .from = dvui.Rect.Natural.fromPoint(pt) }, .{ .id_extra = 2 });
            defer fw.deinit();
        }

        fn frame() !dvui.App.Result {
            if (!inited) {
                layout_a = try Layout.DockLayout.initSingleLeaf(std.testing.allocator, "panel_a");
                layout_b = try Layout.DockLayout.initSingleLeaf(std.testing.allocator, "panel_b");
                inited = true;
            }

            var pair = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
            defer pair.deinit();

            {
                var side = dvui.box(@src(), .{}, .{ .expand = .both, .tag = "side_a" });
                defer side.deinit();
                var dock = dockspace(@src(), .{ .layout = &layout_a, .panelInfo = testPanelInfo, .onTabContextMenu = onCtxA }, .{ .expand = .both, .id_extra = 1 });
                defer dock.deinit();
                while (dock.panel()) |p| {
                    defer p.end();
                    dvui.label(@src(), "content:{s}", .{p.id}, .{});
                }
            }
            {
                var side = dvui.box(@src(), .{}, .{ .expand = .both, .tag = "side_b" });
                defer side.deinit();
                var dock = dockspace(@src(), .{ .layout = &layout_b, .panelInfo = testPanelInfo, .onTabContextMenu = onCtxB }, .{ .expand = .both, .id_extra = 2 });
                defer dock.deinit();
                while (dock.panel()) |p| {
                    defer p.end();
                    dvui.label(@src(), "content:{s}", .{p.id}, .{});
                }
            }

            return .ok;
        }
    };
    defer fns.layout_a.deinit();
    defer fns.layout_b.deinit();

    try dvui.testing.settle(fns.frame);

    // Right-click near the top-left of side A's box, where its (only) tab
    // sits — found via the container's own tag, not the panel's.
    const cw = dvui.currentWindow();
    const side_a_rect = (try dvui.testing.tagGet("side_a")).rect;
    const click_pt = side_a_rect.topLeft().plus(.{ .x = 15, .y = 10 });
    _ = try cw.addEventMouseMotion(.{ .pt = click_pt });
    try dvui.testing.click(.right);
    try dvui.testing.settle(fns.frame);

    // Fires every frame the context menu is open (see the single-dockspace
    // `onTabContextMenu` test above), so assert presence/absence, not count.
    try std.testing.expect(fns.calls_a > 0);
    try std.testing.expectEqual(@as(usize, 0), fns.calls_b);
}

test "dockspace drag: dropping directly onto another leaf's tab (not just its content) adds a tab there" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();

    const fns = struct {
        var layout: Layout.DockLayout = undefined;
        var inited = false;

        fn frame() !dvui.App.Result {
            if (!inited) {
                layout = try Layout.DockLayout.initSingleLeaf(std.testing.allocator, "a");
                try layout.splitLeaf(layout.root, .right, "b");
                inited = true;
            }

            var dock = dockspace(@src(), .{ .layout = &layout, .panelInfo = testPanelInfo }, .{ .expand = .both });
            defer dock.deinit();
            while (dock.panel()) |p| {
                defer p.end();
                dvui.label(@src(), "content:{s}", .{p.id}, .{});
            }

            return .ok;
        }
    };
    defer fns.layout.deinit();

    try dvui.testing.settle(fns.frame);

    const cw = dvui.currentWindow();
    const a_center = dvui.tagGet("a").?.rect.center();
    // "b"'s own tab button (in the header, not its content area below).
    const b_tab = dvui.tagGet("b").?.rect.center();

    _ = try cw.addEventMouseMotion(.{ .pt = a_center });
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(fns.frame);

    _ = try cw.addEventMouseMotion(.{ .pt = b_tab });
    _ = try dvui.testing.step(fns.frame);

    _ = try cw.addEventMouseButton(.left, .release);
    try dvui.testing.settle(fns.frame);

    const b_leaf = fns.layout.findPanel("b").?;
    try std.testing.expect(!fns.layout.isFloat(b_leaf));
    try std.testing.expectEqual(@as(usize, 2), fns.layout.nodes.items[b_leaf].leaf.tabs.items.len);
    try std.testing.expectEqual(fns.layout.root, b_leaf);
}

test "dockspace drag: press+motion+release onto another leaf's center adds a new tab there" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();

    const fns = struct {
        var layout: Layout.DockLayout = undefined;
        var inited = false;

        fn frame() !dvui.App.Result {
            if (!inited) {
                layout = try Layout.DockLayout.initSingleLeaf(std.testing.allocator, "a");
                try layout.splitLeaf(layout.root, .right, "b");
                inited = true;
            }

            var dock = dockspace(@src(), .{ .layout = &layout, .panelInfo = testPanelInfo }, .{ .expand = .both });
            defer dock.deinit();
            while (dock.panel()) |p| {
                defer p.end();
                dvui.label(@src(), "content:{s}", .{p.id}, .{});
            }

            return .ok;
        }
    };
    defer fns.layout.deinit();

    try dvui.testing.settle(fns.frame);

    const cw = dvui.currentWindow();
    const a_center = dvui.tagGet("a").?.rect.center();
    // Window is 600x400 logical, "b" is the right half; scale to physical
    // so this lands well inside "b"'s content center zone regardless of dpi.
    const scale = dvui.windowNaturalScale();
    const b_target: dvui.Point.Physical = .{ .x = 450 * scale, .y = 200 * scale };

    _ = try cw.addEventMouseMotion(.{ .pt = a_center });
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(fns.frame);

    _ = try cw.addEventMouseMotion(.{ .pt = b_target });
    _ = try dvui.testing.step(fns.frame);

    _ = try cw.addEventMouseButton(.left, .release);
    try dvui.testing.settle(fns.frame);

    try std.testing.expect(fns.layout.contains("a"));
    try std.testing.expect(fns.layout.contains("b"));
    const b_leaf = fns.layout.findPanel("b").?;
    try std.testing.expect(!fns.layout.isFloat(b_leaf));
    try std.testing.expectEqual(Layout.Node.leaf, std.meta.activeTag(fns.layout.nodes.items[b_leaf]));
    try std.testing.expectEqual(@as(usize, 2), fns.layout.nodes.items[b_leaf].leaf.tabs.items.len);
    // "a"'s original leaf (empty) collapsed away: the whole tree is one leaf now.
    try std.testing.expectEqual(fns.layout.root, b_leaf);
}

test "dockspace drag: release outside any zone floats the panel at the drop point" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();

    const fns = struct {
        var layout: Layout.DockLayout = undefined;
        var inited = false;

        fn frame() !dvui.App.Result {
            if (!inited) {
                layout = try Layout.DockLayout.initSingleLeaf(std.testing.allocator, "a");
                try layout.insertTab(layout.root, 1, "b");
                inited = true;
            }

            var dock = dockspace(@src(), .{ .layout = &layout, .panelInfo = testPanelInfo }, .{ .expand = .both });
            defer dock.deinit();
            while (dock.panel()) |p| {
                defer p.end();
                dvui.label(@src(), "content:{s}", .{p.id}, .{});
            }

            return .ok;
        }
    };
    defer fns.layout.deinit();

    try dvui.testing.settle(fns.frame);

    const cw = dvui.currentWindow();
    const a_center = dvui.tagGet("a").?.rect.center();

    _ = try cw.addEventMouseMotion(.{ .pt = a_center });
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(fns.frame);

    // Drag well outside the whole dockspace rect: no leaf or root zone can
    // possibly contain this point, so the drop should float instead.
    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = a_center.x, .y = -50 } });
    _ = try dvui.testing.step(fns.frame);

    _ = try cw.addEventMouseButton(.left, .release);
    try dvui.testing.settle(fns.frame);

    const a_leaf = fns.layout.findPanel("a").?;
    try std.testing.expect(fns.layout.isFloat(a_leaf));
}

test "dockspace: floating a panel via a drawHeaderExtra menu doesn't corrupt the widget stack" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();

    const fns = struct {
        var layout: Layout.DockLayout = undefined;
        var inited = false;
        var pending: ?Layout.PanelId = null;

        fn drawHeaderExtra(id: Layout.PanelId) void {
            var m = dvui.menu(@src(), .horizontal, .{ .id_extra = slugIdExtra(id), .gravity_x = 1.0 });
            defer m.deinit();

            const dots_tag = std.fmt.allocPrint(dvui.currentWindow().arena(), "hdr_dots:{s}", .{id}) catch return;
            if (dvui.menuItemLabel(@src(), "...", .{ .submenu = true }, .{ .id_extra = slugIdExtra(id), .tag = dots_tag })) |r| {
                var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
                defer fw.deinit();

                const float_tag = std.fmt.allocPrint(dvui.currentWindow().arena(), "hdr_float:{s}", .{id}) catch return;
                if (dvui.menuItemLabel(@src(), "Float Panel", .{}, .{ .tag = float_tag }) != null) {
                    fw.close();
                    pending = id;
                }
            }
        }

        fn frame() !dvui.App.Result {
            if (!inited) {
                layout = try Layout.DockLayout.initSingleLeaf(std.testing.allocator, "viewport");
                try layout.splitLeaf(layout.root, .left, "hierarchy");
                const viewport_leaf = layout.findPanel("viewport").?;
                try layout.splitLeaf(viewport_leaf, .right, "inspector");
                const inspector_leaf = layout.findPanel("inspector").?;
                try layout.splitLeaf(inspector_leaf, .bottom, "console");
                inited = true;
            }

            {
                var dock = dockspace(@src(), .{
                    .layout = &layout,
                    .panelInfo = testPanelInfo,
                    .drawHeaderExtra = drawHeaderExtra,
                    .panel_background = .{ .background = true, .border = Rect.all(1) },
                }, .{ .expand = .both });
                defer dock.deinit();
                while (dock.panel()) |p| {
                    defer p.end();
                    dvui.label(@src(), "content:{s}", .{p.id}, .{});
                }
            }

            if (pending) |id| {
                pending = null;
                try layout.floatPanel(id, .{ .x = 60, .y = 60, .w = 260, .h = 180 });
            }

            return .ok;
        }
    };
    defer fns.layout.deinit();

    try dvui.testing.settle(fns.frame);

    try dvui.testing.moveTo("hdr_dots:console");
    try dvui.testing.click(.left);
    try dvui.testing.settle(fns.frame);

    try dvui.testing.moveTo("hdr_float:console");
    try dvui.testing.click(.left);
    try dvui.testing.settle(fns.frame);
}

test {
    @import("std").testing.refAllDecls(@This());
}
