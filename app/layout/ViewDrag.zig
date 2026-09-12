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
hover_name: []const u8 = "",

pub fn active(self: ViewDrag) bool {
    return self.name.len > 0;
}

pub fn discard(self: *ViewDrag) void {
    if (self.texture) |tex| dvui.Texture.destroyLater(tex);
    if (self.hover_texture) |tex| dvui.Texture.destroyLater(tex);
    self.* = .{};
}

pub fn takePicture(self: *ViewDrag, pic: *dvui.Picture) void {
    pic.stop();
    const tex = dvui.textureFromTarget(pic.texture) catch return;
    if (self.texture) |old| dvui.Texture.destroyLater(old);
    self.texture = tex;
}

pub fn takeHover(self: *ViewDrag, pic: *dvui.Picture, name: []const u8) void {
    pic.stop();
    const tex = dvui.textureFromTarget(pic.texture) catch return;
    if (self.hover_texture) |old| dvui.Texture.destroyLater(old);
    self.hover_texture = tex;
    self.hover_name = name;
}

pub fn clearHover(self: *ViewDrag) void {
    if (self.hover_texture) |tex| dvui.Texture.destroyLater(tex);
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
}

// ── What is under the pointer ───────────────────────────────────────────────────────────────────

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
    const surface_kw = draggedKeywords(l, source);
    var best: ?[]const u8 = null;
    var best_area: f32 = std.math.floatMax(f32);
    for (state.regions.items) |r| consider(&best, &best_area, r, mouse, surface_kw);
    for (state.regions_building.items) |r| consider(&best, &best_area, r, mouse, surface_kw);
    return best;
}

fn draggedKeywords(l: *Layout, source: []const u8) []const []const u8 {
    const id = visibleId(l, source) orelse return &.{};
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

fn consider(best: *?[]const u8, best_area: *f32, r: Region, mouse: dvui.Point.Physical, surface_kw: []const []const u8) void {
    if (!accepts(r, surface_kw)) return;
    if (r.bounds.w <= 0 or r.bounds.h <= 0) return;
    if (!r.bounds.contains(mouse)) return;
    const area = r.bounds.w * r.bounds.h;
    if (area >= best_area.*) return;
    best.* = r.name;
    best_area.* = area;
}

pub fn placeBounds(state: *const Layout.State, name: []const u8) ?dvui.Rect.Physical {
    for (state.regions_building.items) |r| {
        if (std.mem.eql(u8, r.name, name) and r.bounds.w > 0 and r.bounds.h > 0) return r.bounds;
    }
    for (state.regions.items) |r| {
        if (std.mem.eql(u8, r.name, name) and r.bounds.w > 0 and r.bounds.h > 0) return r.bounds;
    }
    return null;
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

/// What `name` is previewing this frame. The preview and the release read the
/// same `Drop.plan`, so the pane that slides open is the one that lands.
pub fn previewPlan(l: *Layout, name: []const u8) ?Drop.Plan {
    if (!previewOn(l, name)) return null;
    const d = l.state.view_drag;
    const kind: Drop.Kind = if (d.preview_split) |side| .{ .split = side } else .swap;
    return Drop.plan(kind, std.mem.eql(u8, name, d.name));
}

/// The source place is previewing a split of itself, so it must keep drawing
/// its view rather than standing empty behind the floating card.
pub fn selfSplitting(l: *Layout) bool {
    const d = l.state.view_drag;
    return d.active() and d.preview_split != null and d.preview_t > 0.001 and
        std.mem.eql(u8, d.preview_name, d.name);
}

/// A swap is being previewed *and the pointer is still on it*. The second
/// half matters: `preview_t` also eases back down after the pointer leaves,
/// and the remap must stop the moment the answer changes.
pub fn swapping(l: *Layout) bool {
    const d = l.state.view_drag;
    if (!d.active() or d.preview_name.len == 0 or d.preview_t <= 0.001) return false;
    if (d.preview_split != null) return false;
    if (std.mem.eql(u8, d.preview_name, d.name)) return false;
    const mouse = dvui.currentWindow().mouse_pt;
    const dest = targetAt(l, mouse, d.name) orelse return false;
    if (!std.mem.eql(u8, dest, d.preview_name)) return false;
    return kindAt(l.state, dest, mouse, dvui.currentWindow().natural_scale) == .swap;
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
        if (d.other_id.len == 0) return &.{};
        d.other_ids[0] = d.other_id;
        return d.other_ids[0..1];
    }
    return null;
}

// ── Preview geometry ────────────────────────────────────────────────────────────────────────────

/// The half a new pane occupies as it slides in from `side`, at `t`.
pub fn slideIn(bounds: dvui.Rect.Physical, side: SplitTree.Side, t: f32) dvui.Rect.Physical {
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

/// The sash between the two halves, on the incoming pane's inner edge.
pub fn sashAt(bounds: dvui.Rect.Physical, side: SplitTree.Side, t: f32, scale: f32) dvui.Rect.Physical {
    const incoming = slideIn(bounds, side, t);
    const sash = Split.handle_size * scale;
    return switch (side) {
        .left => .{ .x = incoming.x + incoming.w, .y = bounds.y, .w = sash, .h = bounds.h },
        .right => .{ .x = incoming.x - sash, .y = bounds.y, .w = sash, .h = bounds.h },
        .top => .{ .x = bounds.x, .y = incoming.y + incoming.h, .w = bounds.w, .h = sash },
        .bottom => .{ .x = bounds.x, .y = incoming.y - sash, .w = bounds.w, .h = sash },
    };
}

/// Everything past the sash — the half the place being split keeps, and so
/// the clip its contents draw under while the preview is open.
pub fn keptHalf(bounds: dvui.Rect.Physical, side: SplitTree.Side, t: f32, scale: f32) dvui.Rect.Physical {
    const sash = sashAt(bounds, side, t, scale);
    return switch (side) {
        .left => .{
            .x = sash.x + sash.w,
            .y = bounds.y,
            .w = @max(0, bounds.x + bounds.w - (sash.x + sash.w)),
            .h = bounds.h,
        },
        .right => .{
            .x = bounds.x,
            .y = bounds.y,
            .w = @max(0, sash.x - bounds.x),
            .h = bounds.h,
        },
        .top => .{
            .x = bounds.x,
            .y = sash.y + sash.h,
            .w = bounds.w,
            .h = @max(0, bounds.y + bounds.h - (sash.y + sash.h)),
        },
        .bottom => .{
            .x = bounds.x,
            .y = bounds.y,
            .w = bounds.w,
            .h = @max(0, sash.y - bounds.y),
        },
    };
}

fn outCubic(t: f32) f32 {
    const u = 1 - t;
    return 1 - u * u * u;
}

// ── Painting ────────────────────────────────────────────────────────────────────────────────────

/// The landing preview for `dest`: the pane that is opening, what goes in it,
/// and the destination's outgoing content dissolving behind it.
pub fn drawHint(
    l: *Layout,
    dest: []const u8,
    bounds: dvui.Rect.Physical,
    scale: f32,
) void {
    const theme = dvui.themeGet();
    const t = previewVisual(l);
    const none: dvui.CornerRect.Physical = .{};
    switch (previewPlan(l, dest) orelse return) {
        // A swap needs no hint of its own: both places are already drawing
        // the other's view through `previewAssignment`.
        .swap => {},
        .split => |s| {
            // `mint` is the hole that opens — the dropped edge when the view
            // moves into it, the far edge when the origin keeps the view.
            const incoming = slideIn(bounds, s.mint, t);
            const sash = sashAt(bounds, s.mint, t, scale);
            if (incoming.w > 1 and incoming.h > 1) {
                incoming.fill(none, .{ .color = theme.color(.window, .fill), .fade = 1.0 });
                if (s.fills_mint) {
                    drawLiveIn(l, incoming, l.state.view_drag.moved_id);
                } else {
                    Region.drawEmptyHatch(incoming, scale);
                }
                blurOutgoing(l, dest, incoming, bounds, t);
            }
            if (sash.w > 0 and sash.h > 0) {
                sash.fill(none, .{ .color = theme.color(.window, .fill), .fade = 1.0 });
            }
        },
    }
}

/// The incoming surface, drawn live in the pane that is sliding open. A
/// float rather than a box in the parent: this runs mid-layout, inside a
/// place that has already sized itself.
fn drawLiveIn(l: *Layout, dest: dvui.Rect.Physical, id: []const u8) void {
    if (id.len == 0 or dest.w < 2 or dest.h < 2) return;
    const s = l.host.surfaceById(id) orelse return;
    const nat = dest.toNatural();
    const theme = dvui.themeGet();
    var fw: dvui.FloatingWidget = undefined;
    fw.init(@src(), .{ .mouse_events = false }, .{
        .rect = .{ .x = nat.x, .y = nat.y, .w = nat.w, .h = nat.h },
        .padding = .{},
        .background = true,
        .color_fill = theme.color(.window, .fill),
    });
    defer fw.deinit();
    const prev_clip = dvui.clip(fw.data().contentRectScale().r);
    defer dvui.clipSet(prev_clip);
    _ = s.draw(s.ctx) catch {};
}

/// The destination's last pixels, aligned to the whole place and dissolving
/// over the pane sliding in — the same outgoing blur a surface change uses,
/// so a split and a swap read as one family of motion.
fn blurOutgoing(
    l: *Layout,
    dest_name: []const u8,
    incoming: dvui.Rect.Physical,
    bounds: dvui.Rect.Physical,
    t: f32,
) void {
    const tex = l.state.view_drag.hover_texture orelse return;
    if (!std.mem.eql(u8, l.state.view_drag.hover_name, dest_name)) return;
    const s = core.anim.crossfade.sample(.blur, t, false);
    const prev = dvui.clip(incoming);
    defer dvui.clipSet(prev);
    core.anim.blit(tex, bounds, s.out_blur, s.out_alpha);
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
    const moved = ownId(l.arena, visibleId(l, source) orelse return) orelse return;
    if (regionNamed(l.state, dest)) |r| {
        const s = l.host.surfaceById(moved) orelse return;
        if (!accepts(r.*, s.keywords)) return;
    }
    switch (plan) {
        .swap => swap(l, source, dest, moved),
        .split => |s| {
            const new = Region.splitOn(l, dest, s.mint) orelse return;
            // A self-split leaves the view in the origin, which `mint` has
            // already put under the pointer. Moving it onto the fresh leaf
            // would remount the surface and lose everything it was holding.
            if (s.fills_mint) {
                l.state.assign(l.gpa, new, &.{moved}) catch {};
                selectNamed(l, new, moved);
                removeVisible(l, source, moved);
            }
        },
    }
    l.state.markDirty();
    dvui.refresh(null, @src(), null);
}

/// Trade views. Each place keeps whatever else it was holding: a `.many`
/// place swaps the visible tab out of its list rather than losing the list.
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
    const source_shows = if (regionNamed(l.state, source)) |r| r.shows else .one;

    if (dest_shows == .many) {
        if (l.state.assignment(dest)) |ids| {
            l.state.assign(l.gpa, dest, idsReplacing(l.arena, ids, other orelse "", moved)) catch {};
        } else {
            l.state.assign(l.gpa, dest, &.{moved}) catch {};
        }
    } else {
        l.state.assign(l.gpa, dest, &.{moved}) catch {};
    }
    selectNamed(l, dest, moved);

    if (source_shows == .many) {
        if (l.state.assignment(source)) |ids| {
            const kept = idsWithout(l.arena, ids, moved);
            if (other) |o| {
                l.state.assign(l.gpa, source, idsReplacing(l.arena, kept, "", o)) catch {};
                selectNamed(l, source, o);
            } else {
                l.state.assign(l.gpa, source, kept) catch {};
                if (kept.len > 0) selectNamed(l, source, kept[0]);
            }
        } else if (other) |o| {
            l.state.assign(l.gpa, source, &.{o}) catch {};
            selectNamed(l, source, o);
        } else {
            l.state.assign(l.gpa, source, &.{}) catch {};
        }
    } else if (other) |o| {
        l.state.assign(l.gpa, source, &.{o}) catch {};
        selectNamed(l, source, o);
    } else {
        l.state.assign(l.gpa, source, &.{}) catch {};
    }
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

/// Take `id` out of `name`. Writing an empty assignment matters: without one,
/// keywords would simply attract the view straight back in.
fn removeVisible(l: *Layout, name: []const u8, id: []const u8) void {
    if (l.state.assignment(name)) |ids| {
        const kept = idsWithout(l.arena, ids, id);
        l.state.assign(l.gpa, name, kept) catch {};
        if (kept.len > 0) selectNamed(l, name, kept[0]);
        return;
    }
    l.state.assign(l.gpa, name, &.{}) catch {};
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

test "a split preview grows from the dropped edge to half" {
    const r: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 200, .h = 100 };
    try std.testing.expectEqual(@as(f32, 0), slideIn(r, .left, 0).w);
    const half = slideIn(r, .left, 1);
    try std.testing.expectEqual(@as(f32, 100), half.w);
    try std.testing.expectEqual(@as(f32, 0), half.x);
    const right = slideIn(r, .right, 1);
    try std.testing.expectEqual(@as(f32, 100), right.x);
    try std.testing.expectEqual(@as(f32, 100), right.w);
}

test "the preview sash sits on the incoming pane's inner edge" {
    const r: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 200, .h = 100 };
    const sash = sashAt(r, .left, 1, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 100), sash.x, 0.1);
    try std.testing.expectApproxEqAbs(Split.handle_size, sash.w, 0.1);
}

test "the kept half is everything past the sash" {
    const r: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 200, .h = 100 };
    // Opening on the left leaves the right; the two never overlap the sash.
    const kept = keptHalf(r, .left, 1, 1);
    try std.testing.expectApproxEqAbs(100 + Split.handle_size, kept.x, 0.1);
    try std.testing.expectApproxEqAbs(100 - Split.handle_size, kept.w, 0.1);

    const kept_top = keptHalf(r, .top, 1, 1);
    try std.testing.expectApproxEqAbs(50 + Split.handle_size, kept_top.y, 0.1);
}

test "a place not being previewed keeps its whole self" {
    const r: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 200, .h = 100 };
    const kept = keptHalf(r, .left, 0, 1);
    try std.testing.expectApproxEqAbs(Split.handle_size, kept.x, 0.1);
    try std.testing.expectApproxEqAbs(200 - Split.handle_size, kept.w, 0.1);
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
