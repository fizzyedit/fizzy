//! A view lifted out of its place and carried to another one.
//!
//! The gesture is one thing, so it is one file: the state that survives
//! between frames, the hit-test that decides what is under the pointer, the
//! preview that shows what will happen, and the assignment that lands when
//! the button comes up. `Region` declares places; this moves views between
//! them. The rule both the preview and the landing obey is `Drop`, and the
//! whole design is written down in `SPLITS.md`.
//!
//! Three things are worth knowing before changing anything here:
//!
//! **The float is a photograph.** The dragged surface is captured once, at
//! lift, and the card under the pointer blits that texture. Drawing the live
//! surface twice in one frame is not something a plugin has to tolerate.
//!
//! **A landing area draws the real thing.** A swap remaps both places'
//! assignments for the frame (`previewAssignment`), so each lays out the
//! other's view for real; a split slides a live copy of the incoming surface
//! in from the edge. The preview is the result, not a coloured rectangle
//! standing in for it.
//!
//! **A place being previewed keeps its own widgets.** The clip that shows a
//! place shrinking to half is set on the place's existing box. Wrapping the
//! contents in a child box to clip them remounts every widget inside, which
//! for a document pane means losing its scroll, selection and undo.
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const sdk = @import("fizzy_sdk");
const Split = core.widgets.Split;
const Layout = @import("Layout.zig");
const Region = @import("Region.zig");
const SplitTree = @import("SplitTree.zig");
const Drop = @import("Drop.zig");

const ViewDrag = @This();

/// Interned name of the place the view was lifted from. Empty when idle, so
/// `active()` is the one question everything else asks first.
name: []const u8 = "",
/// Physical size of the source when the drag began — the card shrinks from it.
from: dvui.Size.Physical = .{},
/// The lifted surface as it last drew. The floating card is this texture.
texture: ?dvui.Texture = null,
/// Its frost, for the swap-out dissolve (`core.anim.Frost`), and where it was taken.
frost: core.anim.Frost = .{},
texture_rect: dvui.Rect.Physical = .{},
start_ns: i128 = 0,
/// Place being previewed, interned. Empty when nothing is easing.
preview_name: []const u8 = "",
/// The edge under the pointer, as read. `Drop.plan` turns it into what will
/// happen; this stays the raw reading so the plan is derived in one place.
preview_split: ?SplitTree.Side = null,
/// 0 shut, 1 fully open. Eases both ways, so leaving a place slides it back.
preview_t: f32 = 0,
preview_tick_ns: i128 = 0,
/// Surface lifted from the source. Landing areas draw this one live.
moved_id: []const u8 = "",
/// The destination's own visible surface, drawn back in the source's hole
/// while a swap is previewed.
other_id: []const u8 = "",
moved_ids: [1][]const u8 = .{""},
other_ids: [1][]const u8 = .{""},
/// Set while photographing the source: matching must report the stored
/// assignment, or the capture would catch the preview instead of the view.
capturing: bool = false,
/// The destination as it looked before the preview, for the outgoing blur.
hover_texture: ?dvui.Texture = null,
hover_frost: core.anim.Frost = .{},
/// Where `hover_texture` was taken, so it is blitted back at its own size. It is a still of the
/// place's *content* rect, and possibly already mid pull-back; stretching it to the whole place
/// made every dissolve a little larger than what it was dissolving from.
hover_rect: dvui.Rect.Physical = .{},
hover_name: []const u8 = "",
/// The places this drag can land on, and where they were, frozen at lift.
targets: [max_targets]Target = undefined,
target_count: usize = 0,

/// One place the pointer can be read against.
pub const Target = struct {
    /// Interned, so it outlives the frame the map was taken on.
    name: []const u8,
    bounds: dvui.Rect.Physical,
    /// Content size in points, for the extent a landing split settles at.
    size: dvui.Size,
};

/// Generous: a shape's places plus every pane a plugin opens inside them.
/// Past this the drag simply cannot aim at the newest places, which is a far
/// better failure than a map that shifts while you are reading it.
pub const max_targets = 64;

pub fn active(self: ViewDrag) bool {
    return self.name.len > 0;
}

/// The source of a view lifted out of the picker rather than out of a place.
/// No shape declares a place by this name, so every question the gesture
/// asks of its source — its bounds, its assignment, whether it may shut —
/// answers "none", which is exactly what a view in nobody's hands has.
pub const loose_source = "\x00picker";

/// A drag with no source place: the view came from the picker.
pub fn loose(self: ViewDrag) bool {
    return std.mem.eql(u8, self.name, loose_source);
}

pub fn discard(self: *ViewDrag) void {
    if (self.texture) |tex| dvui.Texture.destroyLater(tex);
    if (self.hover_texture) |tex| dvui.Texture.destroyLater(tex);
    self.frost.drop();
    self.hover_frost.drop();
    self.* = .{};
}

pub fn takePicture(self: *ViewDrag, pic: *dvui.Picture) void {
    pic.stop();
    const tex = dvui.textureFromTarget(pic.texture) catch return;
    if (self.texture) |old| dvui.Texture.destroyLater(old);
    self.frost.drop();
    self.texture = tex;
    self.texture_rect = pic.r;
    self.frost.prepare(tex);
}

pub fn takeHover(self: *ViewDrag, pic: *dvui.Picture, name: []const u8) void {
    pic.stop();
    const tex = dvui.textureFromTarget(pic.texture) catch return;
    if (self.hover_texture) |old| dvui.Texture.destroyLater(old);
    self.hover_frost.drop();
    self.hover_texture = tex;
    self.hover_rect = pic.r;
    self.hover_name = name;
    self.hover_frost.prepare(tex);
}

/// What photograph this place owes the drag this frame.
///
/// A photograph is taken *from the place's own draw*, never from a second
/// one. Drawing a subtree twice in a frame gives every widget inside it a
/// duplicate id — dvui paints the lot red and the two copies fight over the
/// same stored state — and the subtree under a place is the whole editor.
pub const Shot = struct {
    /// The lifted view, for the floating card. Taken once, at lift.
    card: bool = false,
    /// The destination as it looked before the preview, for the outgoing
    /// blur. Taken once per place the pointer aims at.
    hover: bool = false,

    pub fn any(self: Shot) bool {
        return self.card or self.hover;
    }
};

/// Nothing is owed unless a drag is live and the existing texture is missing
/// or belongs to a different place.
pub fn shotWanted(l: *Layout, name: []const u8, is_source: bool, plan: ?Drop.Plan) Shot {
    const d = l.state.view_drag;
    if (!d.active()) return .{};
    var shot: Shot = .{ .card = is_source and d.texture == null };
    // Every preview dissolves the place's old pixels away — the pane slides
    // over them on a split, the other view replaces them on a swap — so any
    // plan at all needs the still.
    if (plan != null) {
        shot.hover = d.hover_texture == null or !std.mem.eql(u8, d.hover_name, name);
    }
    return shot;
}

/// Keep what the place's draw recorded, and hand the texture back so the
/// caller can blit the very same pixels to the screen.
///
/// One capture yields one texture: `textureFromTarget` consumes the render
/// target. When both are owed the card wins and the hover is taken next
/// frame — a sixtieth of a second nobody sees, and the alternative is the
/// second draw this whole arrangement exists to avoid.
pub fn keepShot(l: *Layout, shot: Shot, pic: *dvui.Picture, name: []const u8) ?dvui.Texture {
    var d = &l.state.view_drag;
    if (shot.card) {
        d.takePicture(pic);
        return d.texture;
    }
    if (shot.hover) {
        d.takeHover(pic, l.state.internName(l.gpa, name));
        return d.hover_texture;
    }
    pic.stop();
    return null;
}

pub fn clearHover(self: *ViewDrag) void {
    if (self.hover_texture) |tex| dvui.Texture.destroyLater(tex);
    self.hover_frost.drop();
    self.hover_texture = null;
    self.hover_name = "";
}

/// Begin carrying the view out of `name`. The place keeps drawing until the
/// pointer moves far enough for dvui to call it a drag.
pub fn begin(l: *Layout, name: []const u8, from: dvui.Rect.Physical) void {
    var d = &l.state.view_drag;
    d.name = l.state.internName(l.gpa, name);
    d.from = from.size();
    d.start_ns = dvui.currentWindow().frame_time_ns;
    if (visibleId(l, name)) |id| d.moved_id = id;
    mapTargets(l, d);
}

/// Begin carrying surface `id` from the picker. There is no source place,
/// so nothing stands empty and nothing is photographed: the float starts at
/// the card that was grabbed and shows the picture the card showed, which
/// the caller hands over (`State.stealSnapshot`) and the drag destroys.
pub fn beginLoose(l: *Layout, id: []const u8, from: dvui.Rect.Physical, texture: ?dvui.Texture) void {
    var d = &l.state.view_drag;
    const s = l.host.surfaceById(id) orelse return;
    d.name = loose_source;
    d.from = from.size();
    d.start_ns = dvui.currentWindow().frame_time_ns;
    d.moved_id = s.id;
    d.texture = texture;
    d.texture_rect = from;
    mapTargets(l, d);
}

// ── What is under the pointer ───────────────────────────────────────────────────────────────────

/// Photograph the places, the way the card photographs the view.
///
/// **A drag must not change the map it is being read against.** It does,
/// constantly, in two ways. A preview draws the view it is about to land, and
/// whatever regions *that* declares — a workspace's document panes — appear
/// as new, smaller places under the pointer, which then win on area. And a
/// place previewing a split pulls back to its half, so the very rect the
/// pointer is aiming at moves away from the pointer.
///
/// Either one makes the reading flip every frame: aim, preview, the reading
/// changes, the preview closes, the reading changes back. That is not a
/// wobble to damp out with a threshold — it is a loop, and the only way out
/// is to cut it. Frozen at lift, the hit-test is a pure function of where the
/// pointer is, and the drag is as steady as your hand.
fn mapTargets(l: *Layout, d: *ViewDrag) void {
    d.target_count = 0;
    const surface_kw = draggedKeywords(l);
    // Last frame's registry: complete, where this frame's is still being
    // filled in around the click that started the drag.
    const places = if (l.state.regions.items.len > 0)
        l.state.regions.items
    else
        l.state.regions_building.items;
    for (places) |r| {
        if (d.target_count == max_targets) break;
        if (!accepts(r, surface_kw)) continue;
        if (r.bounds.w <= 0 or r.bounds.h <= 0) continue;
        d.targets[d.target_count] = .{
            .name = l.state.internName(l.gpa, r.name),
            .bounds = r.bounds,
            .size = r.size,
        };
        d.target_count += 1;
    }
}

/// What a place was when the drag began, or null if it was not one of the
/// places this drag can land on.
fn frozen(state: *const Layout.State, name: []const u8) ?Target {
    const d = &state.view_drag;
    if (!d.active()) return null;
    for (d.targets[0..d.target_count]) |t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

fn kindAt(state: *const Layout.State, dest: []const u8, mouse: dvui.Point.Physical, scale: f32) Drop.Kind {
    const dest_b = placeBounds(state, dest) orelse return .swap;
    return Drop.kindAt(dest_b, mouse, scale);
}

/// The place a release at `mouse` would land on, for a view lifted from
/// `source`. The smallest place containing the pointer wins, so a document
/// pane beats the main area it sits in.
pub fn targetAt(l: *Layout, mouse: dvui.Point.Physical, source: []const u8) ?[]const u8 {
    const state = l.state;
    // The source's own edge is a self-split, and it outranks any pane nested
    // inside it — otherwise a document filling the place always wins on area
    // and its own edges become unreachable.
    if (placeBounds(state, source)) |bounds| {
        if (bounds.contains(mouse)) {
            switch (Drop.kindAt(bounds, mouse, dvui.currentWindow().natural_scale)) {
                .split => return source,
                .swap => {},
            }
        }
    }
    const d = &state.view_drag;
    var best: ?[]const u8 = null;
    var best_area: f32 = std.math.floatMax(f32);
    for (d.targets[0..d.target_count]) |t| {
        if (!t.bounds.contains(mouse)) continue;
        const area = t.bounds.w * t.bounds.h;
        if (area >= best_area) continue;
        best = t.name;
        best_area = area;
    }
    return best;
}

/// What the view being carried is, for deciding which places will take it.
/// The surface lifted at the start, not whatever the source place happens to
/// be showing — mid-swap it is showing the *other* view, and reading that
/// would change which places accept the drop halfway through it.
fn draggedKeywords(l: *Layout) []const []const u8 {
    const id = l.state.view_drag.moved_id;
    if (id.len == 0) return &.{};
    const s = l.host.surfaceById(id) orelse return &.{};
    return s.keywords;
}

/// A shape place (Main, Panel, a leftover Center) can receive any surface.
/// A plugin kind slot (a workbench document pane) only receives what it
/// accepts, so dropping Output on the canvas lands on Main rather than
/// becoming a document tab.
pub fn accepts(r: Region, surface_kw: []const []const u8) bool {
    if (r.name.len == 0) return false;
    if (!r.kind_slot) return true;
    if (surface_kw.len == 0) return false;
    return sdk.keywords.accepts(r.keywords, surface_kw);
}

pub fn placeBounds(state: *const Layout.State, name: []const u8) ?dvui.Rect.Physical {
    // Mid-drag, a place is where it was when the drag began — see
    // `mapTargets`. Everything the gesture measures reads this, so the pane
    // that slides open, the half the place pulls back to and the edge the
    // pointer is being tested against are all cut from the same rect.
    if (frozen(state, name)) |t| return t.bounds;
    for (state.regions_building.items) |r| {
        if (std.mem.eql(u8, r.name, name) and r.bounds.w > 0 and r.bounds.h > 0) return r.bounds;
    }
    for (state.regions.items) |r| {
        if (std.mem.eql(u8, r.name, name) and r.bounds.w > 0 and r.bounds.h > 0) return r.bounds;
    }
    return null;
}

/// A place's content size in points, frozen mid-drag for the same reason its
/// bounds are: a place previewing a split has pulled back to the half it
/// would keep, and halving *that* to settle the landing split would land the
/// new pane at a quarter of the place the user was shown.
pub fn placeSize(state: *const Layout.State, name: []const u8) ?dvui.Size {
    if (frozen(state, name)) |t| {
        if (t.size.w > 0 and t.size.h > 0) return t.size;
    }
    return state.placeSize(name);
}

pub fn regionNamed(state: *const Layout.State, name: []const u8) ?*const Region {
    for (state.regions.items) |*r| {
        if (std.mem.eql(u8, r.name, name)) return r;
    }
    for (state.regions_building.items) |*r| {
        if (std.mem.eql(u8, r.name, name)) return r;
    }
    return null;
}

/// The surface a place is showing — the selected one, not its whole
/// assignment. A multi place drags the tab you can see, not all of them.
pub fn visibleId(l: *Layout, name: []const u8) ?[]const u8 {
    if (regionNamed(l.state, name)) |r| {
        if (l.selectedStored(r)) |s| return s.id;
    }
    const ids = l.state.assignment(name) orelse return null;
    return if (ids.len > 0) ids[0] else null;
}

// ── The preview ─────────────────────────────────────────────────────────────────────────────────

/// How long a preview takes to slide fully open, in seconds. The same number
/// runs it backwards when the pointer leaves, so a place you brush past
/// closes at the speed it opened.
const preview_dur_s: f32 = 0.28;

/// Advance the preview toward what the pointer is over. Called from every
/// place that draws during a drag, and idempotent within a frame — whichever
/// one runs first does the work.
pub fn tick(l: *Layout) void {
    var d = &l.state.view_drag;
    if (!d.active()) return;
    const now = dvui.currentWindow().frame_time_ns;
    if (d.preview_tick_ns == now) return;

    var dt: f32 = 1.0 / 60.0;
    if (d.preview_tick_ns != 0) {
        const ns: f32 = @floatFromInt(now - d.preview_tick_ns);
        dt = std.math.clamp(ns / @as(f32, std.time.ns_per_s), 0.0, 0.05);
    }
    d.preview_tick_ns = now;

    const mouse = dvui.currentWindow().mouse_pt;
    const scale = dvui.currentWindow().natural_scale;
    var hover_name: []const u8 = "";
    var hover_split: ?SplitTree.Side = null;
    if (targetAt(l, mouse, d.name)) |dest| {
        const kind = kindAt(l.state, dest, mouse, scale);
        // Null plan: the middle of your own place, which is not a hover.
        if (Drop.plan(kind, std.mem.eql(u8, dest, d.name)) != null) {
            hover_name = dest;
            hover_split = switch (kind) {
                .swap => null,
                .split => |s| s,
            };
        }
    }

    if (d.moved_id.len == 0) {
        if (visibleId(l, d.name)) |id| d.moved_id = id;
    }

    if (d.preview_name.len == 0 and hover_name.len > 0) {
        aim(l, d, hover_name, hover_split, 0);
    }

    const same = std.mem.eql(u8, d.preview_name, hover_name) and
        ((d.preview_split == null) == (hover_split == null)) and
        (hover_split == null or d.preview_split.? == hover_split.?);
    const step = dt / preview_dur_s;
    if (hover_name.len > 0 and same) d.preview_t += step else d.preview_t -= step;
    d.preview_t = std.math.clamp(d.preview_t, 0, 1);

    // Fully shut is the only moment the preview may change what it is aimed
    // at. Switching mid-slide would teleport a half-open pane to another
    // place, which reads as a glitch rather than a change of mind.
    if (d.preview_t <= 0) {
        if (hover_name.len > 0 and !same) {
            aim(l, d, hover_name, hover_split, step);
        } else if (hover_name.len == 0) {
            aim(l, d, "", null, 0);
        }
    }

    dvui.refresh(null, @src(), null);
}

fn aim(l: *Layout, d: *ViewDrag, name: []const u8, split: ?SplitTree.Side, t: f32) void {
    d.preview_name = if (name.len > 0) l.state.internName(l.gpa, name) else "";
    d.preview_split = split;
    d.preview_t = t;
    // Only a swap needs the destination's own view: a split leaves it in place.
    d.other_id = if (name.len > 0 and split == null) visibleId(l, name) orelse "" else "";
    d.clearHover();
}

pub fn previewOn(l: *Layout, name: []const u8) bool {
    const d = l.state.view_drag;
    return d.preview_t > 0.001 and std.mem.eql(u8, d.preview_name, name);
}

/// The eased 0..1 the preview draws at, as opposed to the linear `preview_t`.
pub fn previewVisual(l: *Layout) f32 {
    return outCubic(std.math.clamp(l.state.view_drag.preview_t, 0, 1));
}

/// Linear 0..1 through the preview, for anything that has its own curve —
/// the dissolve's blur-then-fade is one. Feeding it `previewVisual` instead
/// spent the hold (the only part that is a blur) in the first few frames of
/// the ease, and the rest of the motion was just alpha.
pub fn previewClock(l: *Layout) f32 {
    return std.math.clamp(l.state.view_drag.preview_t, 0, 1);
}

/// What `name` is previewing this frame. The preview and the release read the
/// same `Drop.plan`, so the pane that slides open is the one that lands.
pub fn previewPlan(l: *Layout, name: []const u8) ?Drop.Plan {
    if (!previewOn(l, name)) return null;
    const d = l.state.view_drag;
    const kind: Drop.Kind = if (d.preview_split) |side| .{ .split = side } else .swap;
    return Drop.plan(kind, std.mem.eql(u8, name, d.name));
}

/// A swap is being previewed. The pose that is already opening is the pose
/// until it shuts — re-reading the pointer here would flip the remap off the
/// moment the pointer brushed an edge, which restarts `drawSwapped`'s clock
/// every frame and is why a dissolve looked like a fade that kept snapping
/// back to the start.
pub fn swapping(l: *Layout) bool {
    const d = l.state.view_drag;
    if (!d.active() or d.preview_name.len == 0 or d.preview_t <= 0.001) return false;
    if (d.preview_split != null) return false;
    return !std.mem.eql(u8, d.preview_name, d.name);
}

/// What a place should show while a swap is previewed, so both ends lay out
/// the other's view for real. Null leaves the stored assignment alone —
/// which is what the release itself, and `visibleId`, must always see.
pub fn previewAssignment(l: *Layout, name: []const u8) ?[]const []const u8 {
    if (!swapping(l)) return null;
    if (l.state.view_drag.capturing) return null;
    var d = &l.state.view_drag;
    if (std.mem.eql(u8, name, d.preview_name)) {
        if (d.moved_id.len == 0) return null;
        d.moved_ids[0] = d.moved_id;
        return d.moved_ids[0..1];
    }
    if (std.mem.eql(u8, name, d.name)) {
        // A shelf takes the view; it does not send one back. The hole the
        // view left is a hole, not the place's current tab riding the other
        // way — that is a trade, and a trade is what a slot does.
        const dest_many = if (regionNamed(l.state, d.preview_name)) |r| r.shows == .many else false;
        if (dest_many) return &.{};
        if (d.other_id.len == 0) return &.{};
        d.other_ids[0] = d.other_id;
        return d.other_ids[0..1];
    }
    return null;
}

// ── Preview geometry ────────────────────────────────────────────────────────────────────────────

/// A split opening: where the new pane is, and how far the place being split
/// has pulled back to make room for it.
///
/// One function for all of it, because three different readings of "half of
/// this place" is how a preview stops matching what it previews. The card
/// that shrinks, the pane that slides in and the gap between them are all
/// measured here, from the same numbers a real split would settle at.
pub const Opening = struct {
    /// The pane sliding in from `side`, in physical points.
    pane: dvui.Rect.Physical,
    /// How far the kept half's edge on `side` has moved: the pane plus the
    /// sash gap. This is what the place being split insets itself by.
    inset: f32,
};

pub fn opening(bounds: dvui.Rect.Physical, side: SplitTree.Side, t: f32, scale: f32) Opening {
    const u = std.math.clamp(t, 0, 1);
    const gap = Split.handle_size * scale;
    const along = switch (side) {
        .left, .right => bounds.w,
        .top, .bottom => bounds.h,
    };
    // Halved the way a real split halves: the sash comes out of the middle
    // first, so the two sides end up the same size rather than the new one
    // being a sash narrower than the old.
    const full = @max(0, (along - gap) * 0.5);
    const size = full * u;
    var pane = bounds;
    switch (side) {
        .left => pane.w = size,
        .right => {
            pane.w = size;
            pane.x = bounds.x + bounds.w - size;
        },
        .top => pane.h = size,
        .bottom => {
            pane.h = size;
            pane.y = bounds.y + bounds.h - size;
        },
    }
    return .{ .pane = pane, .inset = size + gap * u };
}

/// Pull a place back to the half it keeps while a split previews on it.
///
/// The place is *laid out* smaller, not clipped: its contents reflow into the
/// half they will actually have, so what is under the pointer is the
/// arrangement the release produces rather than a cropped picture of the old
/// one. A margin does that in place — putting the contents inside a sized
/// child box would rebuild every widget in them, and a document pane would
/// lose its scroll and undo every time the pointer brushed an edge.
///
/// The pinned size follows the margin down so the *slot* does not change: a
/// resizable place whose minimum grew by the inset would widen the window's
/// whole arrangement the moment you hovered its edge.
pub fn pullBack(
    l: *Layout,
    name: []const u8,
    opts: *dvui.Options,
    mint: SplitTree.Side,
    axis: dvui.enums.Direction,
    pinned: bool,
) void {
    const whole = placeBounds(l.state, name) orelse return;
    if (whole.w <= 0 or whole.h <= 0) return;
    const scale = dvui.currentWindow().natural_scale;
    if (scale <= 0) return;
    const inset = opening(whole, mint, previewVisual(l), scale).inset / scale;
    if (inset <= 0) return;

    var m = opts.margin orelse dvui.Rect{};
    switch (mint) {
        .left => m.x += inset,
        .top => m.y += inset,
        .right => m.w += inset,
        .bottom => m.h += inset,
    }
    opts.margin = m;

    const along_axis = switch (mint) {
        .left, .right => axis == .horizontal,
        .top, .bottom => axis == .vertical,
    };
    if (!pinned or !along_axis) return;
    if (opts.min_size_content) |*min| switch (axis) {
        .horizontal => min.w = @max(0, min.w - inset),
        .vertical => min.h = @max(0, min.h - inset),
    };
    if (opts.max_size_content) |max| opts.max_size_content = switch (axis) {
        .horizontal => .width(@max(0, max.w - inset)),
        .vertical => .height(@max(0, max.h - inset)),
    };
}

fn outCubic(t: f32) f32 {
    const u = 1 - t;
    return 1 - u * u * u;
}

// ── Painting ────────────────────────────────────────────────────────────────────────────────────

/// How a place is dressed, so the pane a preview opens is dressed the same.
///
/// A preview that draws a bare rectangle where a rounded, padded card is
/// about to be is a preview of something else. Taken from the destination's
/// own box rather than guessed, so an app that restyles its places gets a
/// preview in its own style without saying so.
pub const Card = struct {
    corners: dvui.CornerRect.Physical = .{},
    fill: dvui.Color = .black,
    padding: dvui.Rect = .{},
};

/// The landing preview for `dest`: the pane that is opening, what goes in it,
/// and the destination's outgoing content dissolving away.
pub fn drawHint(
    l: *Layout,
    dest: []const u8,
    bounds: dvui.Rect.Physical,
    scale: f32,
    card: Card,
) void {
    const t = previewVisual(l);
    const dissolve_t = previewClock(l);
    // The place has pulled back; the opening is measured against what it was.
    const whole = placeBounds(l.state, dest) orelse bounds;

    // The pane opens in the space the place gave up, which is outside the
    // clip the pulled-back card leaves behind — so paint against the place's
    // whole rect instead of intersecting with what is left of it.
    const prev_clip = dvui.clipGet();
    defer dvui.clipSet(prev_clip);
    dvui.clipSet(whole);

    switch (previewPlan(l, dest) orelse return) {
        // Both places are already laying out the other's view. What is left
        // is making it read as a trade rather than a jump cut: the pixels
        // that were here blur away over the ones arriving, the same dissolve
        // a surface change uses anywhere else.
        .swap => dissolve(l, dest, whole, .frost, dissolve_t),
        .split => |s| {
            // `mint` is the pane that opens — the dropped edge when the view
            // moves into it, the far edge when the origin keeps the view.
            const open = opening(whole, s.mint, t, scale);
            if (open.pane.w <= 1 or open.pane.h <= 1) return;
            open.pane.fill(card.corners, .{ .color = .{ .color = card.fill }, .fade = 1.0 });
            if (s.fills_mint) {
                drawLiveIn(l, open.pane, l.state.view_drag.moved_id, card);
            } else {
                Region.drawEmptyHatch(open.pane, scale);
            }
            // Only over the pane: the rest of the place is drawing its real,
            // re-laid-out half, and blurring that would undo the point.
            dissolve(l, dest, open.pane, .fade, dissolve_t);
        },
    }
}

/// The incoming surface, drawn live in the pane that is sliding open, in the
/// same card the place it is landing in wears. A float rather than a box in
/// the parent: this runs mid-layout, inside a place that has already sized
/// itself.
fn drawLiveIn(l: *Layout, dest: dvui.Rect.Physical, id: []const u8, card: Card) void {
    if (id.len == 0 or dest.w < 2 or dest.h < 2) return;
    const s = l.host.surfaceById(id) orelse return;
    const nat = dest.toNatural();
    var fw: dvui.FloatingWidget = undefined;
    fw.init(@src(), .{ .mouse_events = false }, .{
        .rect = .{ .x = nat.x, .y = nat.y, .w = nat.w, .h = nat.h },
        .padding = card.padding,
        .background = false,
    });
    defer fw.deinit();
    const prev_clip = dvui.clip(fw.data().contentRectScale().r);
    defer dvui.clipSet(prev_clip);
    _ = s.draw(s.ctx) catch {};
}

/// A place's own content, dimmed, while the pointer is over the place the
/// drag came from.
///
/// Your own place is not losing anything — the view is being carried, not
/// taken away — so hatching it as a hole says the opposite of what dropping
/// here does. Dimming says "this is the one in your hand" and leaves the
/// content readable, which is what you are aiming with.
pub fn dimSource(l: *Layout, rs: dvui.RectScale, corners: dvui.CornerRect.Physical) void {
    if (!overSelf(l)) return;
    const theme = dvui.themeGet();
    // The card, not the content rect the place is clipped to: a dim that
    // stops short of the padding leaves a bright border around it.
    const prev = dvui.clipGet();
    defer dvui.clipSet(prev);
    dvui.clipSet(rs.r);
    rs.r.fill(corners, .{ .color = .{ .color = theme.color(.window, .fill).opacity(0.55) }, .fade = 1.0 });
}

/// True while the pointer is inside the place the drag came from.
pub fn overSelf(l: *Layout) bool {
    const d = l.state.view_drag;
    if (!d.active()) return false;
    const bounds = placeBounds(l.state, d.name) orelse return false;
    return bounds.contains(dvui.currentWindow().mouse_pt);
}

/// The source's own last pixels blurring away while a swap is previewed —
/// the far end of the same dissolve the destination is running, so a trade
/// looks like one motion happening in two places.
pub fn drawSwapOut(l: *Layout, bounds: dvui.Rect.Physical) void {
    if (!swapping(l)) return;
    const tex = l.state.view_drag.texture orelse return;
    const s = core.anim.crossfade.sample(.frost, previewClock(l), false);
    const prev = dvui.clipGet();
    defer dvui.clipSet(prev);
    dvui.clipSet(bounds);
    core.anim.blit(tex, &l.state.view_drag.frost, l.state.view_drag.texture_rect, s.out_blur, s.out_alpha);
}

/// The destination's last pixels, drawn back where they were taken and dissolving away inside
/// `within`.
///
/// A *swap* frosts them out (`Kind.frost`: defocus and fade together, never a held opaque
/// frost — the traded view is already drawing live underneath), so a trade reads as one motion
/// happening in two places. A *split* only fades them: the pixels under an opening pane
/// are the edge of content that is still there, sharp, right beside it, and frosting that edge
/// paints coloured blobs of the neighbour into the new pane. Fading reads as the pane sliding
/// over what was there, which is what is happening.
fn dissolve(
    l: *Layout,
    dest_name: []const u8,
    within: dvui.Rect.Physical,
    kind: core.anim.Kind,
    t: f32,
) void {
    const d = &l.state.view_drag;
    const tex = d.hover_texture orelse return;
    if (!std.mem.eql(u8, d.hover_name, dest_name)) return;
    const s = core.anim.crossfade.sample(kind, t, false);
    const prev = dvui.clip(within);
    defer dvui.clipSet(prev);
    core.anim.blit(tex, &d.hover_frost, d.hover_rect, s.out_blur, s.out_alpha);
}

/// The card under the pointer. Always visible while dragging: it is the only
/// thing that says what is being carried, and hiding it over a drop target
/// left the gesture looking cancelled.
pub fn drawFloat(l: *Layout) void {
    tick(l);
    const d = l.state.view_drag;
    if (!d.active()) return;
    const mouse = dvui.currentWindow().mouse_pt;
    const now = dvui.currentWindow().frame_time_ns;
    const dur: f64 = 220 * @as(f64, std.time.ns_per_ms);
    const elapsed: f64 = @floatFromInt(now - d.start_ns);
    const t = outCubic(@floatCast(std.math.clamp(elapsed / dur, 0, 1)));

    // Shrink from the place's own size to a card, keeping the grab point
    // under the pointer, so the view appears to be picked up rather than
    // replaced by an icon.
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
        .color_fill = .{ .color = theme.color(.window, .fill) },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = theme.color(.highlight, .fill) },
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
        core.anim.blit(tex, null, dest, 0, 1);
    } else {
        dvui.label(@src(), "view", .{}, .{
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .color_text = .{ .color = theme.color(.control, .text) },
        });
    }
    dvui.refresh(null, @src(), null);
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

// ── The landing ─────────────────────────────────────────────────────────────────────────────────

/// Release at `mouse`. Does nothing unless the pointer is somewhere a drop
/// means something, so letting go over the window frame cancels.
pub fn apply(l: *Layout, source: []const u8, mouse: dvui.Point.Physical) void {
    const dest = targetAt(l, mouse, source) orelse return;
    if (placeBounds(l.state, dest) == null) return;
    const scale = dvui.currentWindow().natural_scale;
    place(l, source, dest, kindAt(l.state, dest, mouse, scale));
}

/// Move the visible surface of `source` onto `dest`. The picker's own moves
/// come through here too, which is why it takes a `Drop.Kind` rather than a
/// pointer position.
pub fn place(l: *Layout, source: []const u8, dest: []const u8, kind: Drop.Kind) void {
    const plan = Drop.plan(kind, std.mem.eql(u8, source, dest)) orelse return;
    const moved = ownId(l.arena, movedFrom(l, source) orelse return) orelse return;
    if (regionNamed(l.state, dest)) |r| {
        const s = l.host.surfaceById(moved) orelse return;
        if (!accepts(r.*, s.keywords)) return;
    }
    switch (plan) {
        .swap => swap(l, source, dest, moved),
        .split => |s| {
            // A drop that has already previewed this split must not ease the
            // leaf from zero: the pane is already open, and starting again
            // snaps the leftover back to full and slides the new side in a
            // second time. Seed from the preview's own clock so the real
            // split continues from the size the user was just looking at.
            l.state.slide_open_from = if (previewOn(l, dest)) previewVisual(l) else 0;
            const new = Region.splitOn(l, dest, s.mint) orelse return;
            // A self-split leaves the view in the origin, which `mint` has
            // already put under the pointer. Moving it onto the fresh leaf
            // would remount the surface and lose everything it was holding.
            if (s.fills_mint) {
                l.state.assign(l.gpa, new, &.{moved}) catch {};
                selectNamed(l, new, moved);
                takeOut(l, source, moved, null);
            }
        },
    }
    shutIfEmptied(l, source);
    l.state.markDirty();
    dvui.refresh(null, @src(), null);
}

/// The surface a drop from `source` lands: the one the live drag lifted when
/// it is this drag's source (a picker drag carries a view its source may not
/// be showing — or, loose, has no source at all), else what the place shows.
fn movedFrom(l: *Layout, source: []const u8) ?[]const u8 {
    const d = l.state.view_drag;
    if (d.active() and d.moved_id.len > 0 and std.mem.eql(u8, d.name, source)) return d.moved_id;
    return visibleId(l, source);
}

/// Land the view. A place that shows many takes it; a place that shows one
/// trades for it.
///
/// The difference is whether anything had to be displaced. A shelf has room,
/// so the view joins what is already there and the source simply loses it. A
/// slot has one view in it, and that view has to go somewhere — back where the
/// new one came from, because nowhere else is anywhere: an unassigned surface
/// whose place is now spoken for is a surface the user can no longer find.
fn swap(l: *Layout, source: []const u8, dest: []const u8, moved: []const u8) void {
    const other_raw = visibleId(l, dest);
    const other = if (other_raw) |o| ownId(l.arena, o) else null;

    // Dropping a view onto a place that is already showing it: claim it here
    // and let the source go empty, rather than trading it with itself.
    if (other) |o| {
        if (std.mem.eql(u8, o, moved)) {
            l.state.assign(l.gpa, dest, &.{moved}) catch {};
            selectNamed(l, dest, moved);
            if (l.state.assignment(source) == null)
                l.state.assign(l.gpa, source, &.{}) catch {};
            return;
        }
    }

    const dest_shows = if (regionNamed(l.state, dest)) |r| r.shows else .one;
    if (dest_shows == .many) {
        l.state.assign(l.gpa, dest, idsWith(l.arena, holding(l, dest), moved)) catch {};
        selectNamed(l, dest, moved);
        takeOut(l, source, moved, null);
        return;
    }

    l.state.assign(l.gpa, dest, &.{moved}) catch {};
    selectNamed(l, dest, moved);
    takeOut(l, source, moved, other);
}

/// What a place is holding: the list it was given, or the one its keywords
/// attract when it has never been given one. A `.many` place usually has no
/// list of its own — the sidebar's tabs are every plugin that asked for the
/// sidebar — and reading only the assignment there says "nothing", so a drop
/// onto the rail would leave it holding one lone view.
fn holding(l: *Layout, name: []const u8) []const []const u8 {
    if (l.state.assignment(name)) |ids| return ids;
    const r = regionNamed(l.state, name) orelse return &.{};
    const items = l.matchingStored(r);
    var out = std.ArrayListUnmanaged([]const u8).initCapacity(l.arena, items.len) catch return &.{};
    for (items) |s| out.appendAssumeCapacity(s.id);
    return out.items;
}

/// Take `moved` out of `name`, putting `give` where it was if the trade sent
/// one back.
fn takeOut(l: *Layout, name: []const u8, moved: []const u8, give: ?[]const u8) void {
    // Nothing to take it out of: the destination's assignment already claims
    // the view away from wherever keywords had put it (`State.assign` evicts
    // it from every other list), and a view the trade sends back has nowhere
    // to go but its keywords.
    if (std.mem.eql(u8, name, loose_source)) return;
    const held = holding(l, name);
    const kept = if (give) |g|
        idsReplacing(l.arena, held, moved, g)
    else
        idsWithout(l.arena, held, moved);

    // A place whose keywords chose its list, losing a view and getting none
    // back, is left alone: the destination's assignment already claims the
    // view away from it. Writing the list down instead would freeze the place
    // against every surface a plugin registers from here on.
    if (give != null or l.state.assignment(name) != null)
        l.state.assign(l.gpa, name, kept) catch {};
    reselect(l, name, moved, kept);
}

/// A place never stays selected on a view it no longer holds.
///
/// The selection is remembered per place and only *read* against what the
/// place shows, so a chooser that has already dropped the icon can sit beside
/// a body still drawing what that icon used to choose — which is what dragging
/// Files out of the sidebar looked like until you clicked another icon.
fn reselect(l: *Layout, name: []const u8, gone: []const u8, kept: []const []const u8) void {
    const key = if (regionNamed(l.state, name)) |r| r.selectionKey() else slotKey(name);
    const cur = l.host.selectionForKey(key) orelse return;
    if (!std.mem.eql(u8, cur, gone)) return;
    if (kept.len > 0) selectNamed(l, name, kept[0]);
}

fn ownId(arena: std.mem.Allocator, id: []const u8) ?[]const u8 {
    return arena.dupe(u8, id) catch null;
}

fn slotKey(name: []const u8) u64 {
    const group = sdk.keywords.groupKey(Layout.slot_keywords);
    return group ^ std.hash.Wyhash.hash(0x51a7, name);
}

fn selectNamed(l: *Layout, name: []const u8, id: []const u8) void {
    const stable = if (l.host.surfaceById(id)) |s| s.id else return;
    if (regionNamed(l.state, name)) |r| {
        l.selectIn(r, stable);
        return;
    }
    l.host.setSelectionForKey(slotKey(name), stable);
}

/// A place that exists only because a split made it, left holding nothing,
/// shuts itself and hands the room back to its neighbour.
///
/// The shape's own places stay. Main with nothing in it is still where Main
/// is, and a user who empties it expects to be able to put something back. A
/// minted leaf is not furniture: it was a container for the view that has
/// just been carried out of it, and leaving a blank rectangle behind makes
/// the user tidy up after their own drag. `canForget` is exactly that
/// distinction — a place the tree is allowed to drop.
///
/// The leaf a split *mints* is empty on purpose and is never passed here: it
/// is the room being made, not room left over.
///
/// Shut rather than deleted, so it slides closed on the curve it opened on;
/// `Region.persistExtent` drops the leaf once the animation has finished.
fn shutIfEmptied(l: *Layout, name: []const u8) void {
    if (!l.state.splits.canForget(name)) return;
    if (l.state.assignment(name)) |ids| {
        if (ids.len > 0) return;
    }
    const r = regionNamed(l.state, name) orelse return;
    if (r.id != .zero and Split.sizeOf(r.id) > 0) {
        Split.close(r.id);
        l.extents_changed = true;
        return;
    }
    // Never drawn at a size, so there is nothing to slide: drop it outright.
    if (l.state.splits.collapse(l.gpa, name)) {
        if (l.state.clearExtent(l.gpa, name)) l.extents_changed = true;
        l.state.unassign(l.gpa, name);
    }
}

fn idsWith(arena: std.mem.Allocator, ids: []const []const u8, add: []const u8) []const []const u8 {
    return idsReplacing(arena, ids, "", add);
}

fn idsWithout(arena: std.mem.Allocator, ids: []const []const u8, drop: []const u8) []const []const u8 {
    var out = std.ArrayListUnmanaged([]const u8).initCapacity(arena, ids.len) catch return &.{};
    for (ids) |id| {
        if (!std.mem.eql(u8, id, drop)) out.appendAssumeCapacity(id);
    }
    return out.items;
}

fn idsReplacing(arena: std.mem.Allocator, ids: []const []const u8, drop: []const u8, add: []const u8) []const []const u8 {
    var out = std.ArrayListUnmanaged([]const u8).initCapacity(arena, ids.len + 1) catch return &.{add};
    var replaced = false;
    for (ids) |id| {
        if (std.mem.eql(u8, id, drop)) {
            if (!replaced) {
                out.appendAssumeCapacity(add);
                replaced = true;
            }
            continue;
        }
        if (std.mem.eql(u8, id, add)) continue;
        out.appendAssumeCapacity(id);
    }
    if (!replaced) out.appendAssumeCapacity(add);
    return out.items;
}

test "a split preview grows from the dropped edge to an even half" {
    const r: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 200, .h = 100 };
    const half = (200 - Split.handle_size) / 2;

    try std.testing.expectEqual(@as(f32, 0), opening(r, .left, 0, 1).pane.w);

    const left = opening(r, .left, 1, 1);
    try std.testing.expectApproxEqAbs(half, left.pane.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0), left.pane.x, 0.01);
    // What the pane takes plus the sash is exactly what the place gives up,
    // so the two halves come out the same size.
    try std.testing.expectApproxEqAbs(half, 200 - left.inset, 0.01);

    const right = opening(r, .right, 1, 1);
    try std.testing.expectApproxEqAbs(200 - half, right.pane.x, 0.01);
    try std.testing.expectApproxEqAbs(half, right.pane.w, 0.01);
}

test "a place not being previewed gives up nothing" {
    const r: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 200, .h = 100 };
    try std.testing.expectEqual(@as(f32, 0), opening(r, .left, 0, 1).inset);
    try std.testing.expectEqual(@as(f32, 0), opening(r, .top, 0, 1).inset);
}

test "the pane and the place it pulls back from never overlap" {
    const r: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 120, .h = 300 };
    var t: f32 = 0;
    while (t <= 1.0) : (t += 0.05) {
        for (std.meta.tags(SplitTree.Side)) |side| {
            const o = opening(r, side, t, 1);
            const along = switch (side) {
                .left, .right => o.pane.w,
                .top, .bottom => o.pane.h,
            };
            try std.testing.expect(o.inset >= along);
        }
    }
}

test "the dissolve clock is the preview's linear time, not its ease" {
    // outCubic(0.2) is already past the blur hold. The dissolve must not use it.
    const eased = 1 - (1 - 0.2) * (1 - 0.2) * (1 - 0.2);
    try std.testing.expect(eased > core.anim.crossfade.hold);
    const fading = core.anim.crossfade.sample(.blur, eased, false);
    try std.testing.expect(fading.out_alpha < 1);
    const blurring = core.anim.crossfade.sample(.blur, 0.2, false);
    try std.testing.expectEqual(@as(f32, 1), blurring.out_alpha);
    try std.testing.expect(blurring.out_blur < 1);
}

test "a document pane does not accept a panel surface" {
    const pane: Region = .{ .name = "Pane 1", .keywords = &.{"main.document"}, .by_name = true, .kind_slot = true };
    const main: Region = .{ .name = "Main", .keywords = sdk.keywords.ide.main };
    const center: Region = .{ .name = "Center", .keywords = &.{"slot"}, .by_name = true };
    try std.testing.expect(!accepts(pane, sdk.keywords.ide.panel));
    try std.testing.expect(accepts(pane, &.{"document"}));
    try std.testing.expect(accepts(main, sdk.keywords.ide.panel));
    try std.testing.expect(accepts(center, sdk.keywords.ide.panel));
}
