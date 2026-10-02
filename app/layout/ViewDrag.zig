//! A view lifted out of its place and carried to another one.
//!
//! The gesture is one thing, so it is one file: the state that survives
//! between frames, the hit-test that decides what is under the pointer, the
//! drop zones that show where it can go, and the assignment that lands when
//! the button comes up. `Region` declares places; this moves views between
//! them. The rule the zones and the landing obey is `Drop`, and the whole
//! design is written down in `SPLITS.md`.
//!
//! Two things are worth knowing before changing anything here:
//!
//! **The app under a drag does not change.** The dragged surface is
//! photographed once, at lift, and a card of it rides the pointer; its place
//! goes on drawing it, and no place poses it as a preview of landing there —
//! one view shown in two places at once was harder to read than a card over
//! a window that stays put. The layout moves after the drop, with the
//! animations every split and swap already has.
//!
//! **The place under the pointer shows its drop zones** (`drawZones`,
//! `core.widgets.DropZones`), all five of its options at once; the one under
//! the pointer is the one a release takes. Moving to another place, its zones
//! clear as the new place's come in — the window is never covered in targets,
//! and the one change on screen is where the pointer is. The middle of the
//! other half of a split is a join, which its middle bubble says with its icon
//! (`DropZones.Center.join`) — no other drop previews what it leaves, so neither does this.
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const icons = @import("icons");
const sdk = @import("fizzy_sdk");
const Split = core.widgets.Split;
const Layout = @import("Layout.zig");
const Region = @import("Region.zig");
const SplitTree = @import("SplitTree.zig");
const Drop = @import("Drop.zig");
const DropZones = core.widgets.DropZones;

const ViewDrag = @This();

/// The pointer while a view is carried, from the press that lifts it — a tab, a place's corner
/// button, a picker card (each passes it to `dvui.dragPreStart`) — to the release: the same
/// whatever is under it. dvui has no closed "grabbing" hand; this is its hand.
pub const cursor: dvui.enums.Cursor = .hand;

/// Interned name of the place the view was lifted from. Empty when idle, so
/// `active()` is the one question everything else asks first.
name: []const u8 = "",
/// Physical size of the source when the drag began — the card shrinks from it.
from: dvui.Size.Physical = .{},
/// The lifted surface as it last drew. The floating card is this texture.
texture: ?dvui.Texture = null,
/// Where it was taken.
texture_rect: dvui.Rect.Physical = .{},
start_ns: i128 = 0,
/// Surface lifted from the source: what the card under the pointer shows, and what lands.
moved_id: []const u8 = "",
/// What the view is carried as this frame (`modeAt`), and what it was before its last change.
mode: Mode = .preview,
morph_from_mode: Mode = .preview,
/// The carried shape as last drawn, whatever it was drawn as: its rect and corner radius,
/// physical. A change of what the view is carried as grows the new shape out of this one —
/// position, size and corners — so the lift from what was grabbed, the tab over a strip and the
/// drop of glass off one are one shape changing, never one swapped for another.
shape_rect: dvui.Rect.Physical = .{},
shape_radius: f32 = 0,
/// Where the current change set out from, and when (`morphProgress`).
morph_rect: dvui.Rect.Physical = .{},
morph_radius: f32 = 0,
card_start_ns: i128 = 0,
/// The view carried as a drop of glass (`dropShapes`), where the glass program draws: its head
/// following the pointer and its tail the head, each on a spring, so it stretches as it is
/// dragged and swings when it stops. This frame's shapes, head then tail.
drop_head: core.Spring = .{},
drop_tail: core.Spring = .{},
drop_ns: i128 = 0,
drop_shapes: [2]core.LiquidField.Shape = undefined,
drop_n: usize = 0,
/// The head's corner radius this frame (physical), for the photograph inside it.
drop_radius: f32 = 0,
/// Carried by a finger: the drop rides up and left of it, where the finger does not cover it.
drop_touch: bool = false,

/// The places this drag can land on, and where they were, frozen at lift.
targets: [max_targets]Target = undefined,
target_count: usize = 0,
/// Choosers a view can be dropped into — a rail, a tab strip — as they offered themselves while
/// drawing (`offerChooser`): this frame's, and last frame's for a release handled before this
/// frame's choosers have drawn.
offers: [max_offers]Offer = undefined,
offer_count: usize = 0,
last_offers: [max_offers]Offer = undefined,
last_offer_count: usize = 0,
offer_frame: i128 = 0,
/// The drops the places queued this frame (`drawZones`), for `drawOverlay`.
pending: [max_offers]PendingDrop = undefined,
pending_count: usize = 0,
pending_frame: i128 = 0,
/// Last frame's drops, for one still going after its place stopped asking for it (`drawOverlay`).
last_pending: [max_offers]PendingDrop = undefined,
last_pending_count: usize = 0,

/// What the carried view is drawn as. `drop` where the glass program draws and the pointer is off
/// every list, `tab` over a list (a tab strip, a rail), `preview` — a card of its photograph — off
/// lists with no glass program.
pub const Mode = enum {
    preview,
    tab,
    drop,

    /// Whether it shows the view's photograph (a tab shows its face instead), so a change between
    /// two that both do keeps it in view rather than fading it back in.
    fn photographs(m: Mode) bool {
        return m != .tab;
    }
};

/// A place's drop, queued while the place draws and drawn over everything once they all have
/// (`drawOverlay`) — over the card riding the pointer too, which would otherwise sit on the
/// drop it is being aimed at.
pub const PendingDrop = struct {
    key: dvui.Id,
    wheel: DropZones.Wheel,
    look: DropZones.Look,
    clip: dvui.Rect.Physical,
};

/// A chooser a carried view is over: a place's tab strip, a rail. Chrome, not content — the
/// place's drop zones and the card's preview stay off it (`interiorBounds`, `drawFloat`).
pub const Offer = struct {
    /// Interned place name.
    name: []const u8,
    bounds: dvui.Rect.Physical,
    /// A release over it lands the view in its place. False for the app's own strip of the
    /// place the view came out of, where dropping it back is no move; a plugin's strip always
    /// takes it, since back on its own strip it is being reordered.
    into: bool = true,
};
pub const max_offers = 16;

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

/// A chooser, drawing during a drag, offering itself as somewhere the view can go: into place
/// `name`, as one of its views. Its place may sit elsewhere — a rail beside a sidebar — or the
/// chooser inside it; either way over the chooser the drop is into the place, not a split of it.
pub fn offerChooser(l: *Layout, name: []const u8, bounds: dvui.Rect.Physical, into: bool) void {
    const d = &l.state.view_drag;
    if (!d.active()) return;
    const now = dvui.currentWindow().frame_time_ns;
    if (d.offer_frame != now) {
        d.last_offers = d.offers;
        d.last_offer_count = d.offer_count;
        d.offer_count = 0;
        d.offer_frame = now;
    }
    if (d.offer_count == max_offers) return;
    d.offers[d.offer_count] = .{ .name = l.state.internName(l.gpa, name), .bounds = bounds, .into = into };
    d.offer_count += 1;
}

/// The chooser under `p` that could take what is carried, if one offered itself this frame or
/// the last. A strip whose place cannot take it — a document pane's tabs under a view that is no
/// document — is no chooser for this drag: read as one, it hid every place's zones and turned the
/// card into a tab over a strip it could never go into, so a split document area, a strip on every
/// pane, was a maze to aim a view across. The strip of the place the view came out of always is.
pub fn chooserAt(state: *const Layout.State, p: dvui.Point.Physical) ?Offer {
    const d = &state.view_drag;
    if (!d.active()) return null;
    const now = dvui.currentWindow().frame_time_ns;
    if (d.offer_frame == now) {
        for (d.offers[0..d.offer_count]) |o| if (o.bounds.contains(p) and takes(d, o)) return o;
    }
    for (d.last_offers[0..d.last_offer_count]) |o| if (o.bounds.contains(p) and takes(d, o)) return o;
    return null;
}

/// Whether offer `o`'s place could take what drag `d` carries: one of the places mapped at lift
/// (`mapTargets`), or the place it came out of.
fn takes(d: *const ViewDrag, o: Offer) bool {
    if (std.mem.eql(u8, o.name, d.name)) return true;
    for (d.targets[0..d.target_count]) |t| if (std.mem.eql(u8, t.name, o.name)) return true;
    return false;
}

pub fn discard(self: *ViewDrag) void {
    if (self.texture) |tex| dvui.Texture.destroyLater(tex);
    // The drops still showing outlive the drag: they run back together where they were drawn
    // (`drawOverlay`), whatever the drop has just done to their places.
    const finishing = self.last_pending;
    const finishing_count = self.last_pending_count;
    self.* = .{};
    self.last_pending = finishing;
    self.last_pending_count = finishing_count;
}

pub fn takePicture(self: *ViewDrag, pic: *dvui.Picture) void {
    pic.stop();
    const tex = dvui.textureFromTarget(pic.texture) catch return;
    if (self.texture) |old| dvui.Texture.destroyLater(old);
    self.texture = tex;
    self.texture_rect = pic.r;
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

    pub fn any(self: Shot) bool {
        return self.card;
    }
};

/// Nothing is owed unless a drag is live, this is its source, and the card has no picture yet.
pub fn shotWanted(l: *Layout, is_source: bool) Shot {
    const d = l.state.view_drag;
    if (!d.active()) return .{};
    return .{ .card = is_source and d.texture == null };
}

/// Keep what the source's draw recorded as the card's picture, and put it on the screen the
/// draw was taken from — the place goes on showing its view under the drag.
pub fn keepShot(l: *Layout, shot: Shot, pic: *dvui.Picture) void {
    const d = &l.state.view_drag;
    if (shot.card) {
        d.takePicture(pic);
        if (d.texture) |tex| {
            core.anim.blit(tex, null, d.texture_rect, 0, 1);
            d.texture = backed(tex, d.texture_rect);
        }
        return;
    }
    pic.stop();
}

/// The card's picture from the frame as last drawn — what the place showed a moment ago — rather
/// than from a capture of this frame's draw. Inside a capture a frosted pane has nothing behind
/// it to frost and draws dark, and that copy is what `keepShot` puts back on the screen: the
/// place flashed dark for the frame it was lifted on. False where there is no last frame to copy
/// (`FrameTarget.snapshot`: no targets, or a web frame nothing read); the caller captures then.
pub fn photographFromFrame(l: *Layout, rect: dvui.Rect.Physical) bool {
    const d = &l.state.view_drag;
    const r = rect.intersect(dvui.windowRectPixels());
    const tex = core.FrameTarget.snapshot(r) orelse return false;
    if (d.texture) |old| dvui.Texture.destroyLater(old);
    d.texture = backed(tex, r);
    d.texture_rect = r;
    return true;
}

/// The card's photograph, laid over the content fill once, at lift: a document paints no
/// background of its own (the pane behind it does), and on bare glass its photograph was text
/// floating in the frost. One opaque picture is what lets the card be drawn see-through: the fill
/// and the photograph drawn each at `photo_opacity`, one over the other, let a twenty-fifth of
/// what is under the card through rather than a fifth. `tex` itself is what the place shows
/// this frame; it is handed back unchanged where there is nothing to draw the backing into.
fn backed(tex: dvui.Texture, r: dvui.Rect.Physical) dvui.Texture {
    var pic = dvui.Picture.start(r) orelse return tex;
    // Some backends leave a fresh target uninitialised (`Layout.drawCaptured`).
    pic.texture.clear();
    const prev_clip = dvui.clipGet();
    dvui.clipSet(pic.r);
    pic.r.fill(.{}, .{ .color = .{ .color = dvui.themeGet().color(.content, .fill) }, .fade = 0 });
    dvui.renderTexture(tex, .{ .r = pic.r, .s = 1 }, .{}) catch {};
    dvui.clipSet(prev_clip);
    pic.stop();
    const out = dvui.textureFromTarget(pic.texture) catch return tex;
    dvui.Texture.destroyLater(tex);
    return out;
}

/// Begin carrying the view out of `name`. The place keeps drawing it throughout.
pub fn begin(l: *Layout, name: []const u8, from: dvui.Rect.Physical, grabbed: dvui.Rect.Physical) void {
    var d = &l.state.view_drag;
    d.drop_head = .{};
    d.drop_tail = .{};
    d.drop_ns = 0;
    d.drop_n = 0;
    d.drop_touch = false;
    d.name = l.state.internName(l.gpa, name);
    d.from = from.size();
    d.start_ns = dvui.currentWindow().frame_time_ns;
    // The carried glass grows out of what was grabbed — the place's grid button, its tab or rail
    // icon — with its photograph growing in it: not glass the size of the whole place shrinking
    // into it, which drew the view whole for a moment before it was carried.
    liftShape(d, grabbed);
    if (visibleId(l, name)) |id| d.moved_id = id;
    mapTargets(l, d);
}

/// The carried shape starts at `from` — what was grabbed: a tab, a card, a place's grid button —
/// and grows from there into whatever it is first carried as.
fn liftShape(d: *ViewDrag, from: dvui.Rect.Physical) void {
    const radius = core.corners.scaled(core.corners.card) * dvui.currentWindow().natural_scale;
    d.mode = .preview;
    d.morph_from_mode = .preview;
    d.shape_rect = from;
    d.shape_radius = radius;
    d.morph_rect = from;
    d.morph_radius = radius;
    d.card_start_ns = d.start_ns;
}

/// Begin carrying surface `id` from the picker. There is no source place,
/// so nothing is photographed: the float starts at
/// the card that was grabbed and shows the picture the card showed, which
/// the caller hands over (`State.stealSnapshot`) and the drag destroys.
pub fn beginLoose(l: *Layout, id: []const u8, from: dvui.Rect.Physical, texture: ?dvui.Texture) void {
    var d = &l.state.view_drag;
    d.drop_head = .{};
    d.drop_tail = .{};
    d.drop_ns = 0;
    d.drop_n = 0;
    d.drop_touch = false;
    const s = l.host.surfaceById(id) orelse return;
    d.name = loose_source;
    d.from = from.size();
    d.start_ns = dvui.currentWindow().frame_time_ns;
    liftShape(d, from);
    d.moved_id = s.id;
    d.texture = texture;
    d.texture_rect = from;
    mapTargets(l, d);
}

// ── What is under the pointer ───────────────────────────────────────────────────────────────────

/// Photograph the places, the way the card photographs the view.
///
/// **A drag must not change the map it is being read against.** Places can
/// move under a drag — a split easing shut, a window resized — and a hit-test
/// read against the live layout would chase them. Frozen at lift, it is a pure function of where the pointer is,
/// and the drag is as steady as your hand.
fn mapTargets(l: *Layout, d: *ViewDrag) void {
    d.target_count = 0;
    const surface_kw = draggedKeywords(l);
    // A tab's content goes to a slot made for it, never a plain place (`Layout.slotted`).
    const slotted = if (l.host.surfaceById(d.moved_id)) |s| l.slotted(s) else false;
    // Last frame's registry: complete, where this frame's is still being
    // filled in around the click that started the drag.
    const places = if (l.state.regions.items.len > 0)
        l.state.regions.items
    else
        l.state.regions_building.items;
    for (places) |r| {
        if (d.target_count == max_targets) break;
        if (!accepts(r, surface_kw)) continue;
        if (slotted and !r.kind_slot) continue;
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

/// What a release at `mouse` over `dest` does: its drop's reading, null off the drop.
fn kindAt(l: *Layout, dest: []const u8, a: Aim, scale: f32) ?Drop.Kind {
    const dest_b = interiorBounds(l.state, dest) orelse return null;
    return Drop.kindAtDisc(dest_b, a.p, a.r, scale, removable(l));
}

/// What the carried view aims with: the middle and radius of the drop it is carried as — the
/// drop is what is aimed, and it rides off the pointer (up and left of a finger) so it can be
/// seen, so it is its overlap with a bubble that chooses, not where the finger is — or the
/// pointer itself, for a card or a tab.
pub const Aim = struct { p: dvui.Point.Physical, r: f32 = 0 };

pub fn aim(l: *Layout) Aim {
    return aimFor(l, dvui.currentWindow().mouse_pt);
}

/// `aim` for the pointer at `mouse` — a release's own point.
pub fn aimFor(l: *Layout, mouse: dvui.Point.Physical) Aim {
    const d = &l.state.view_drag;
    const cw = dvui.currentWindow();
    if (!d.active() or !carriedAsDrop(l, mouse)) return .{ .p = mouse };
    const R = drop_r * cw.natural_scale;
    return .{ .p = dropCenter(mouse, R, d.drop_touch), .r = R };
}

/// Whether the view is carried as a drop of glass at `mouse`: where the glass program draws, with
/// a photograph to show, and not over a list (where it is a tab).
fn carriedAsDrop(l: *Layout, mouse: dvui.Point.Physical) bool {
    const d = &l.state.view_drag;
    return core.LiquidField.ready() and d.texture != null and chooserAt(l.state, mouse) == null;
}

/// Where a drop of radius `r` rides for the pointer at `mouse`: below and right of a mouse; up
/// and left of a finger, the finger at its bottom-right corner, where the hand covers none of it.
fn dropCenter(mouse: dvui.Point.Physical, r: f32, touch: bool) dvui.Point.Physical {
    return if (touch) .{ .x = mouse.x - r, .y = mouse.y - r } else .{ .x = mouse.x + 0.55 * r, .y = mouse.y + 0.55 * r };
}

/// Whether the drop offers the trash: everywhere but where it would wipe out a place the shape
/// declared. Out of one half of a split the user made (`State.userSplitPart`) the trash takes what
/// is carried, and the half, emptied, closes into the other; out of a place that shows several
/// (the sidebar, the bottom panel) it takes just that view, back to the picker. A place the shape
/// declared to show one, never split, offers none — the trash would only leave it empty. A view
/// carried out of the picker is in no place to leave.
pub fn removable(l: *Layout) bool {
    const d = l.state.view_drag;
    if (!d.active() or d.loose()) return false;
    if (l.state.userSplitPart(d.name)) return true;
    const r = regionNamed(l.state, d.name) orelse return false;
    return r.shows == .many;
}

/// The part of place `name` a carried view's zones cover: the place less its own chooser — a tab
/// strip across its top or foot, which offered itself while the drag was on (`offerChooser`).
/// The strip is chrome: over it the view goes into the place's list, not onto a zone, so the
/// zones, the edge the pointer is read against and a split's halves are all cut from the rest.
pub fn interiorBounds(state: *const Layout.State, name: []const u8) ?dvui.Rect.Physical {
    const whole = placeBounds(state, name) orelse return null;
    var b = whole;
    const d = &state.view_drag;
    const now = dvui.currentWindow().frame_time_ns;
    const sets = [2][]const Offer{
        if (d.offer_frame == now) d.offers[0..d.offer_count] else &.{},
        d.last_offers[0..d.last_offer_count],
    };
    for (sets) |set| for (set) |o| {
        if (!std.mem.eql(u8, o.name, name)) continue;
        const i = b.intersect(o.bounds);
        // A band across the place, not a rail beside it or a sliver of overlap.
        if (i.w < b.w * 0.5 or i.h <= 0) continue;
        const above = i.y - b.y;
        const below = (b.y + b.h) - (i.y + i.h);
        if (above <= below) {
            const cut = i.y + i.h - b.y;
            b.y += cut;
            b.h -= cut;
        } else {
            b.h = i.y - b.y;
        }
    };
    return if (b.h >= 1 and b.w >= 1) b else whole;
}

/// The place a release at `mouse` would land on, for a view lifted from
/// `source`. The smallest place containing the pointer wins, so a document
/// pane beats the main area it sits in.
pub fn targetAt(l: *Layout, mouse: dvui.Point.Physical, source: []const u8) ?[]const u8 {
    return targetAtAim(l, .{ .p = mouse }, source);
}

/// `targetAt` for what the view aims with (`aim`).
pub fn targetAtAim(l: *Layout, a: Aim, source: []const u8) ?[]const u8 {
    const mouse = a.p;
    const state = l.state;
    // Over a chooser, its place — as one of its views, never a split — or nowhere, over the
    // app's own strip of the place the view came out of.
    if (chooserAt(state, mouse)) |o| return if (o.into) o.name else null;
    // The source's own edge is a self-split, and it outranks any pane nested
    // inside it — otherwise a document filling the place always wins on area
    // and its own edges become unreachable.
    if (interiorBounds(state, source)) |bounds| {
        if (bounds.contains(mouse)) {
            if (Drop.kindAtDisc(bounds, mouse, a.r, dvui.currentWindow().natural_scale, removable(l))) |k| switch (k) {
                .split, .remove => return source,
                .swap => {},
            };
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
    // `mapTargets`. Everything the gesture measures reads this, so the zones,
    // the edge the pointer is tested against and the split a drop settles are
    // all cut from the same rect.
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
/// bounds are: the split a drop settles is sized from the place the user saw.
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
        if (l.selectedIn(r)) |s| return s.id;
    }
    const ids = l.state.assignment(name) orelse return null;
    return if (ids.len > 0) ids[0] else null;
}

// ── The live drag ───────────────────────────────────────────────────────────────────────────────

/// Keep a live drag moving: its view named, and frames coming while it rides the pointer.
/// Called from every place that draws during a drag; idempotent within a frame.
pub fn tick(l: *Layout) void {
    var d = &l.state.view_drag;
    if (!d.active()) return;
    if (d.moved_id.len == 0) {
        if (visibleId(l, d.name)) |id| d.moved_id = id;
    }
}

// ── Painting ────────────────────────────────────────────────────────────────────────────────────

/// Whether the pointer is over `name` as the place a release would land on.
fn aimedAt(l: *Layout, name: []const u8) bool {
    const d = l.state.view_drag;
    if (!d.active() or name.len == 0) return false;
    const target = targetAtAim(l, aim(l), d.name) orelse return false;
    return std.mem.eql(u8, target, name);
}

/// The drop zones over `name` while the dragged view is over it and could land there
/// (`core.widgets.DropZones`): every option the place offers at once, as the dialogs' frosted
/// glass, the one under the pointer lit. Call after the place's own contents, so the glass lies
/// over them. `key` is any id stable for the place.
pub fn drawZones(l: *Layout, name: []const u8, key: dvui.Id) void {
    // Only the place under the pointer: its zones come in as the pointer arrives and clear as it
    // leaves for another, whose come in over it — for as long as they are still showing, so a
    // place left mid-fade finishes going.
    // Over a chooser the drop is into its place, shown by the chooser (`Chooser`); the places'
    // own zones step back.
    // With the drag over, a drop still going is `drawOverlay`'s to finish where it was: the place
    // it was over may be renamed, moved or gone now, and looking it up again forgot the drop
    // mid-way — it vanished instead of running back together.
    if (!l.state.view_drag.active()) return;
    const over_chooser = chooserAt(l.state, dvui.currentWindow().mouse_pt) != null;
    const aimed = aimedAt(l, name) and !over_chooser;
    const target = aimed and isTarget(l, name);
    if (!target and !DropZones.showing(key)) return;
    // Over the place less its own strip (`interiorBounds`): the strip takes the view into the
    // place's list, and the zones are for its content.
    const whole = interiorBounds(l.state, name) orelse {
        DropZones.forget(key);
        return;
    };
    const scale = dvui.currentWindow().natural_scale;
    const zones = DropZones.wheel(whole, scale, removable(l));
    const d = &l.state.view_drag;
    const center: DropZones.Center = if (std.mem.eql(u8, d.name, name))
        .none
    else if (joins(l, d.name, name))
        .join
    else if (regionNamed(l.state, name)) |r| (if (r.shows == .many) .add else .replace) else .replace;
    // Queued, not drawn: over everything, once every place has drawn (`drawOverlay`).
    const now = dvui.currentWindow().frame_time_ns;
    if (d.pending_frame != now) {
        d.pending_count = 0;
        d.pending_frame = now;
    }
    if (d.pending_count == max_offers) return;
    d.pending[d.pending_count] = .{
        .key = key,
        .wheel = zones,
        .look = .{
            .hovered = if (aimed) blk: {
                const a = aim(l);
                break :blk DropZones.atDisc(zones, a.p, a.r);
            } else null,
            .target = target,
            .center = center,
        },
        .clip = whole,
    };
    d.pending_count += 1;
}

/// What a view drag draws over every place at once, after they have all drawn: the drops they
/// queued (`drawZones`), and over them the card riding the pointer — in a layer of its own over the window.
pub fn drawOverlay(l: *Layout) void {
    const d = &l.state.view_drag;
    const now = dvui.currentWindow().frame_time_ns;
    const queued = if (d.pending_frame == now) d.pending[0..d.pending_count] else d.pending[0..0];
    // This frame's drops, and any from last frame still going that no place asked for this time —
    // the place a drop just landed on can be gone or changed by now, and its drop still has to run
    // back together and shrink away rather than vanish mid-way.
    var drops: [max_offers]PendingDrop = undefined;
    var n: usize = 0;
    for (queued) |p| {
        drops[n] = p;
        n += 1;
    }
    for (d.last_pending[0..d.last_pending_count]) |p| {
        if (n == max_offers) break;
        var asked = false;
        for (queued) |q| {
            if (q.key == p.key) asked = true;
        }
        if (asked or !DropZones.showing(p.key)) continue;
        drops[n] = p;
        drops[n].look.target = false;
        drops[n].look.hovered = null;
        n += 1;
    }
    d.last_pending = drops;
    d.last_pending_count = n;
    // Nothing to lay over the window.
    if (n == 0 and !d.active()) return;
    var layer: dvui.FloatingWidget = undefined;
    layer.init(@src(), .{ .mouse_events = false }, .{ .rect = .cast(dvui.windowRect()), .background = false });
    defer layer.deinit();
    // The drops, then the card over them: one layer, so their order is the order drawn — the
    // card's glass showing the drop it is aimed at blurred through it, its top left just off the
    // pointer so the bubble under the pointer stays in view. (Two floating layers stack in the
    // order they first appeared, and raising one breaks the drag's hold on the pointer.)
    const scale = dvui.currentWindow().natural_scale;
    const prev_clip = dvui.clipGet();
    const mouse = dvui.currentWindow().mouse_pt;
    // The view as a drop, run together with the drop it is over: reaching a bubble, it bridges
    // into it — which bubble a release takes, said by the glass itself.
    const carried = if (d.active()) dropShapes(l, drops[0..n]) else d.drop_shapes[0..0];
    var taken = false;
    var clips: [max_offers]dvui.Rect.Physical = undefined;
    for (drops[0..n], 0..) |p, i| {
        var look = p.look;
        const over = p.look.target and p.clip.contains(mouse);
        if (!taken and over) look.carried = carried;
        // The icons go over the carried view, which is laid on the drop after it: the bubble it
        // is about to be dropped in says what it does through it.
        if (d.active()) look.icons = .later;
        // Carrying the view, the drop is not held to its place: the carried drop reaches past it.
        clips[i] = if (look.carried.len > 0) prev_clip else p.clip;
        dvui.clipSet(clips[i]);
        if (DropZones.draw(p.key, p.wheel, scale, look) and look.carried.len > 0) taken = true;
    }
    dvui.clipSet(prev_clip);
    if (!d.active()) return;
    drawFloat(l, taken);
    for (drops[0..n], clips[0..n]) |p, clip| {
        dvui.clipSet(clip);
        DropZones.drawIcons(p.key, scale);
    }
    dvui.clipSet(prev_clip);
}

/// Points: the radius of the view carried as a drop — the drop zones' middle bubble's, so what is
/// carried reads as big as where it goes, and is still seen beside a finger — and its tail's share
/// of it.
const drop_r: f32 = 52;
const drop_tail_share: f32 = 0.62;
/// How far toward the bubble it is aimed at the drop is drawn, so the two run together.
const drop_pull: f32 = 0.45;

/// The view carried as a drop this frame — its head and tail, stepped on their springs — or none
/// where it is carried as a card (`drawFloat`): no glass program, no photograph, or over a list.
fn dropShapes(l: *Layout, drops: []const PendingDrop) []const core.LiquidField.Shape {
    const d = &l.state.view_drag;
    d.drop_n = 0;
    const cw = dvui.currentWindow();
    const mouse = cw.mouse_pt;
    const now = cw.frame_time_ns;
    noteMode(d, modeAt(l, mouse), now);
    if (d.mode != .drop) {
        d.drop_ns = 0;
        d.drop_head = .{};
        d.drop_tail = .{};
        return d.drop_shapes[0..0];
    }
    const scale = cw.natural_scale;
    const dt: f32 = if (d.drop_ns == 0) 0 else @as(f32, @floatFromInt(now - d.drop_ns)) / std.time.ns_per_s;
    d.drop_ns = now;
    const R = drop_r * scale;
    // Which is carrying it, from what moves it: a finger's presses and moves are touch, a mouse's
    // are not. Not from the position event dvui adds every frame, which is neither.
    for (dvui.events()) |e| switch (e.evt) {
        .mouse => |me| switch (me.action) {
            .press, .motion => d.drop_touch = me.button.touch(),
            else => {},
        },
        else => {},
    };
    // Off the pointer, so the bubble under it stays in view — below and right of a mouse; up and
    // left of a finger, the finger at the drop's bottom-right corner, where the hand holding it
    // covers none of it — and drawn toward the bubble it is aimed at, far enough that the two
    // run together.
    var target = dropCenter(mouse, R, d.drop_touch);
    for (drops) |p| {
        if (!p.look.target or !p.clip.contains(mouse)) continue;
        const z = p.look.hovered orelse continue;
        const b = p.wheel.bubble(z);
        target = .{ .x = target.x + (b.c.x - target.x) * drop_pull, .y = target.y + (b.c.y - target.y) * drop_pull };
    }
    var moving = d.drop_head.step(target, dt, .{ .hz = 9, .playful_damping = 0.55 });
    moving = d.drop_tail.step(d.drop_head.pos, dt, .{ .hz = 4.5, .playful_damping = 0.4 }) or moving;
    // The tail stays on the drop: pulled out a little way, not off it.
    const tx = d.drop_tail.pos.x - d.drop_head.pos.x;
    const ty = d.drop_tail.pos.y - d.drop_head.pos.y;
    const reach = 1.1 * R;
    const len = @sqrt(tx * tx + ty * ty);
    if (len > reach) {
        d.drop_tail.pos = .{ .x = d.drop_head.pos.x + tx / len * reach, .y = d.drop_head.pos.y + ty / len * reach };
    }
    if (moving) dvui.refresh(null, @src(), null);

    // From the shape it was last drawn as — what was grabbed at the lift, the tab it was over a
    // strip — to the drop, on the card's own curve: that rounded rect closing into a circle round
    // the head.
    const t = morphProgress(d.*, now);
    const to: dvui.Rect.Physical = .{ .x = d.drop_head.pos.x - R, .y = d.drop_head.pos.y - R, .w = 2 * R, .h = 2 * R };
    const head = lerpRect(d.morph_rect, to, t);
    d.drop_radius = std.math.lerp(d.morph_radius, R, std.math.clamp(t, 0, 1));
    d.shape_rect = head;
    d.shape_radius = d.drop_radius;
    d.drop_shapes[0] = .{ .rect = head, .radii = @splat(d.drop_radius), .round = true };
    d.drop_n = 1;
    const tr = R * drop_tail_share * std.math.clamp(t, 0, 1);
    if (tr > 1) {
        d.drop_shapes[1] = core.LiquidField.Shape.circle(d.drop_tail.pos, tr);
        d.drop_n = 2;
    }
    return d.drop_shapes[0..d.drop_n];
}

/// What the view is carried as with the pointer at `mouse` (`Mode`).
fn modeAt(l: *Layout, mouse: dvui.Point.Physical) Mode {
    if (carriedAsDrop(l, mouse)) return .drop;
    return if (chooserAt(l.state, mouse) != null) .tab else .preview;
}

/// A change of what the view is carried as: the new shape sets out from the one last drawn.
fn noteMode(d: *ViewDrag, mode: Mode, now: i128) void {
    if (mode == d.mode) return;
    d.morph_from_mode = d.mode;
    d.mode = mode;
    d.morph_rect = d.shape_rect;
    d.morph_radius = d.shape_radius;
    d.card_start_ns = now;
}

/// How much the content of what it is carried as has come in: a change between two that both
/// show the photograph keeps it; a change to or from a tab's face fades the new one in.
fn contentIn(d: ViewDrag, t: f32) f32 {
    return if (d.morph_from_mode.photographs() == d.mode.photographs()) 1 else std.math.clamp(t, 0, 1);
}

fn lerpRect(a: dvui.Rect.Physical, b: dvui.Rect.Physical, t: f32) dvui.Rect.Physical {
    const lerp = std.math.lerp;
    return .{ .x = lerp(a.x, b.x, t), .y = lerp(a.y, b.y, t), .w = @max(1, lerp(a.w, b.w, t)), .h = @max(1, lerp(a.h, b.h, t)) };
}

/// How far the carried shape has come from the one it set out from into what it is carried as:
/// `motion.enter` over the dialogs' 300ms as written, past its size and back when motion is
/// playful; at once when motion is off.
fn morphProgress(d: ViewDrag, now: i128) f32 {
    const dur: f64 = core.motion.durationMs(300) * @as(f64, std.time.ns_per_ms);
    const elapsed: f64 = @floatFromInt(now - d.card_start_ns);
    return if (dur <= 0) 1 else core.motion.enter(@floatCast(std.math.clamp(elapsed / dur, 0, 1)));
}

/// The view carried as a drop: its glass — run in with the drop it is over when that took it
/// (`taken`), its own otherwise — and its photograph inside the head, cropped to fill it.
fn drawDrop(l: *Layout, taken: bool) void {
    const d = &l.state.view_drag;
    const scale = dvui.currentWindow().natural_scale;
    if (!taken) {
        var field: core.LiquidField = .{ .merge_px = drop_r * 0.9 * scale };
        for (d.drop_shapes[0..d.drop_n]) |sh| field.add(sh);
        _ = core.dialogs.carriedFieldWhole(dvui.Id.update(.zero, "view_drag_drop"), field, scale);
    }
    const tex = d.texture orelse return;
    const head = d.drop_shapes[0].rect;
    const pad = card_padding * scale * 0.5;
    const r = head.insetAll(pad);
    if (r.w < 2 or r.h < 2) return;
    // Cover: the photograph's middle, as much of it as keeps its proportions in the head.
    const pw = d.texture_rect.w;
    const ph = d.texture_rect.h;
    var uv: dvui.Rect = .{ .x = 0, .y = 0, .w = 1, .h = 1 };
    if (pw > 0 and ph > 0) {
        const a_img = pw / ph;
        const a_box = r.w / r.h;
        if (a_img > a_box) {
            uv.w = a_box / a_img;
            uv.x = (1 - uv.w) / 2;
        } else {
            uv.h = a_img / a_box;
            uv.y = (1 - uv.h) / 2;
        }
    }
    const radius = @max(0, d.drop_radius - pad) / scale;
    const shown = contentIn(d.*, morphProgress(d.*, dvui.currentWindow().frame_time_ns));
    dvui.renderTexture(tex, .{ .r = r, .s = scale }, .{ .corners = .round(radius), .colormod = dvui.Color.white.opacity(photo_opacity * shown), .uv = uv }) catch {};
}

/// Whether dropping the view lifted from `source` in the middle of `dest` joins them: the two
/// halves of one split (`State.joinable`), with the view the last thing `source` shows — a
/// place of one, or a place of tabs down to this one. Carried out of a place that keeps other
/// views, it is only moving, and the middle means what it means anywhere else.
fn joins(l: *Layout, source: []const u8, dest: []const u8) bool {
    if (source.len == 0 or dest.len == 0) return false;
    if (l.state.joinable(source, dest) == null) return false;
    const r = regionNamed(l.state, source) orelse return true;
    return r.shows == .one or holding(l, source).len <= 1;
}

/// Whether `name` is somewhere the dragged view could land — one of the places mapped at lift
/// (`mapTargets`), or the place it came from.
fn isTarget(l: *Layout, name: []const u8) bool {
    const d = l.state.view_drag;
    if (!d.active() or name.len == 0) return false;
    if (std.mem.eql(u8, d.name, name)) return true;
    for (d.targets[0..d.target_count]) |t| if (std.mem.eql(u8, t.name, name)) return true;
    return false;
}

/// Whether `key`'s zones are on screen — the place the drag is over, or fading out after it.
pub fn zonesShowing(l: *Layout, name: []const u8, key: dvui.Id) bool {
    return (isTarget(l, name) and aimedAt(l, name)) or DropZones.showing(key);
}

/// The card under the pointer. Always visible while dragging: it is the only
/// thing that says what is being carried, and hiding it over a drop target
/// left the gesture looking cancelled.
pub fn drawFloat(l: *Layout, taken: bool) void {
    tick(l);
    const d = &l.state.view_drag;
    if (!d.active()) return;
    if (d.drop_n > 0) {
        drawDrop(l, taken);
        // Frames while it is still turning from what was grabbed into the drop.
        if (morphProgress(d.*, dvui.currentWindow().frame_time_ns) < 1) dvui.refresh(null, @src(), null);
        return;
    }
    const mouse = dvui.currentWindow().mouse_pt;
    const now = dvui.currentWindow().frame_time_ns;
    // Over a chooser — a tab strip, a rail — the view is going into a list, and the card is a
    // tab: the preview of a place is for the places' insides. What it is carried as was settled
    // this frame (`dropShapes`, `noteMode`); each change grows from the shape it was, the way a
    // dialog grows open.
    const as_tab = d.mode == .tab;
    const t = morphProgress(d.*, now);

    // Into a card the size of what it shows, keeping the grab point under the pointer, so the
    // view appears to be picked up rather than replaced by an icon: a place shrinks into its
    // photograph, a tab grows into its document's (or, with none, into a pill of its own).
    const scale = dvui.currentWindow().natural_scale;
    const pad = card_padding * scale;
    const title = if (l.host.surfaceById(d.moved_id)) |s| s.title else "view";
    const show_photo = d.texture != null and !as_tab;
    const target: dvui.Size.Physical = if (show_photo) blk: {
        const f = floatTarget(d.texture_rect.size(), scale);
        break :blk .{ .w = f.w + 2 * pad, .h = f.h + 2 * pad };
    } else pillSize(l, d.*, title, scale);
    const off = dvui.dragOffset();
    // The pointer keeps its place on the card: the card's top left stays where it was from the
    // pointer when it was grabbed, and the card grows right and down from there into what it
    // shows — so what the tab was held by is still under the pointer, and the card grows away
    // from the place it is aimed at rather than over it. Pulled in only as far as keeps the
    // pointer on the card: a place grabbed far from its corner shrinks to a card far smaller.
    const inset = 8 * scale;
    const tl: dvui.Point.Physical = .{
        .x = mouse.x + std.math.clamp(off.x, -@max(0, target.w - inset), 0),
        .y = mouse.y + std.math.clamp(off.y, -@max(0, target.h - inset), 0),
    };
    const to = dvui.Rect.Physical.fromPoint(tl).toSize(target);
    const rect = lerpRect(d.morph_rect, to, t);
    const radius = std.math.lerp(d.morph_radius, core.corners.scaled(core.corners.card) * scale, std.math.clamp(t, 0, 1));
    d.shape_rect = rect;
    d.shape_radius = radius;
    const nat = rect.toNatural();

    // A box in the drag's own layer (`drawOverlay`), not a floating window of its own: the drops
    // go over it in the same layer, drawn after it.
    const fw = dvui.box(@src(), .{}, .{
        .rect = .{ .x = nat.x, .y = nat.y, .w = nat.w, .h = nat.h },
        // The photograph sits inset in its glass; a tab is the glass.
        .padding = if (show_photo) .all(card_padding) else .all(0),
        .corners = .round(radius / scale),
        .background = false,
        .border = .all(0),
    });
    defer fw.deinit();
    {
        // Glass, like every floating surface. Where the glass program draws it is the same glass
        // the drop is (`drawDrop`), under one id, so a tab becoming the drop and back is one
        // piece of glass changing shape; elsewhere the carried look (`core.dialogs.carriedGlass`),
        // the same a tab has while it is dragged along its strip.
        const brs = fw.data().borderRectScale();
        if (core.LiquidField.ready()) {
            var field: core.LiquidField = .{ .merge_px = drop_r * 0.9 * scale };
            field.add(.{ .rect = brs.r, .radii = @splat(radius), .round = true });
            if (!core.dialogs.carriedFieldWhole(dvui.Id.update(.zero, "view_drag_drop"), field, scale))
                core.dialogs.carriedGlass(fw.data().id, brs.r, brs.s);
        } else core.dialogs.carriedGlass(fw.data().id, brs.r, brs.s);
    }

    const shown = contentIn(d.*, t);
    if (if (show_photo) d.texture else null) |tex| {
        // The photograph (backed by the content fill, `backed`), inset in the glass, its corners
        // following the card's: at `photo_opacity`, so the glass — and what is under the card,
        // through it — shows as the card moves.
        const inner = dvui.CornerRect.round(@max(0, radius / scale - card_padding));
        dvui.renderTexture(tex, fw.data().contentRectScale(), .{ .corners = inner, .colormod = dvui.Color.white.opacity(photo_opacity * shown) }) catch {};
    } else {
        const prev_alpha = dvui.alpha(shown);
        defer dvui.alphaSet(prev_alpha);
        drawTabFace(l, d.*, title);
    }
    // Frames only while the card is still changing into the one in the hand: after that it moves
    // when the pointer does, and the pointer moving is a frame anyway.
    if (t < 1) dvui.refresh(null, @src(), null);
}

/// Points between the card's glass and what it carries.
const card_padding: f32 = 6;
/// How opaque the card's photograph is over its glass.
const photo_opacity: f32 = 0.8;

/// Points: the tab face on a card with no photograph — a file icon, the title and, when there
/// are unsaved changes, the dirty dot — and the gaps between them.
const face_icon: f32 = 16;
const face_gap: f32 = 6;
const face_dot: f32 = 7;
const face_pad_x: f32 = 10;
const face_pad_y: f32 = 6;

/// The document behind the dragged surface, when it is one.
fn draggedDoc(l: *Layout, d: ViewDrag) ?struct { path: []const u8, dirty: bool } {
    const path = sdk.document.pathOfSurfaceId(d.moved_id) orelse return null;
    const doc = l.host.docFromPath(path);
    return .{ .path = path, .dirty = if (doc) |dh| dh.owner.isDirty(dh) else false };
}

/// A card with no photograph: the tab's face in glass, tab-sized.
fn pillSize(l: *Layout, d: ViewDrag, title: []const u8, scale: f32) dvui.Size.Physical {
    const text = dvui.Font.theme(.body).textSize(title);
    const doc = draggedDoc(l, d);
    var w = text.w + 2 * face_pad_x;
    if (doc != null) w += face_icon + face_gap;
    if (doc) |dd| if (dd.dirty) {
        w += face_gap + face_dot;
    };
    const h = @max(face_icon, text.h) + 2 * face_pad_y;
    // Tab-sized, with no card padding round it: the same as a tab carried along its strip, which
    // is the tab itself in glass.
    return .{ .w = w * scale, .h = h * scale };
}

/// What a tab shows, centred on the card: the file's icon, its title, the dirty dot.
fn drawTabFace(l: *Layout, d: ViewDrag, title: []const u8) void {
    // As the strip draws the tab it was (`Workspace`'s tab row): the icon in the control colour,
    // in the file tree's glyph slot, a plain file glyph where no plugin draws one; the title as a
    // selected tab's — it is the tab in hand. The face drawn before the tab became glass is the
    // strip's own, so anything else here changed on the way back.
    const theme = dvui.themeGet();
    const icon_color = theme.color(.control, .text);
    const color = theme.color(.window, .text);
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5, .gravity_y = 0.5 });
    defer row.deinit();
    const doc = draggedDoc(l, d);
    if (doc) |dd| {
        var slot = core.widgets.treeRowGlyph(@src(), .{ .gravity_y = 0.5, .margin = .{ .w = face_gap } });
        defer slot.deinit();
        if (!l.host.drawFileIcon(std.fs.path.extension(dd.path), dd.path, icon_color)) {
            core.icon.icon(@src(), "file_icon", icons.tvg.lucide.file, .{
                .stroke_color = .{ .color = icon_color },
            }, core.widgets.treeRowIconOptions(.{}));
        }
    }
    dvui.labelNoFmt(@src(), title, .{}, .{ .gravity_y = 0.5, .color_text = .{ .color = color }, .padding = .{} });
    if (doc) |dd| if (dd.dirty) {
        var dot = dvui.box(@src(), .{}, .{
            .gravity_y = 0.5,
            .min_size_content = .all(face_dot),
            .margin = .{ .x = face_gap },
            .background = true,
            .color_fill = .{ .color = color.opacity(0.8) },
            .corners = .round(face_dot / 2),
        });
        dot.drawBackground();
        dot.deinit();
    };
}

/// Whether surface `id`'s draw this frame should photograph it for the card: a loose drag (a
/// document lifted off its tab strip) carrying it, with no picture yet.
pub fn previewWanted(l: *Layout, id: []const u8) bool {
    const d = l.state.view_drag;
    return d.active() and d.loose() and d.texture == null and std.mem.eql(u8, d.moved_id, id);
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
    if (chooserAt(l.state, mouse)) |o| {
        if (!o.into) return;
        if (dropOnPluginChooser(l, source, o.name, mouse)) return;
        place(l, source, o.name, .swap);
        return;
    }
    // Where the carried view aims — the drop's middle where it is carried as one — not where the
    // pointer is, so the release lands where the glass showed it would.
    const a = aimFor(l, mouse);
    const dest = targetAtAim(l, a, source) orelse return;
    if (placeBounds(l.state, dest) == null) return;
    const scale = dvui.currentWindow().natural_scale;
    // Off the wheel, no drop: every drop is one the wheel lit first.
    place(l, source, dest, kindAt(l, dest, a, scale) orelse return);
}

/// A release over a plugin region's own chooser: straight to the plugin's `on_drop`, as into the
/// region with where along its strip — even for the region the view came out of, whose strip
/// reorders it, which `place` would refuse as no move. False when `dest` is not a plugin region
/// with a drop of its own, for `place` to handle.
fn dropOnPluginChooser(l: *Layout, source: []const u8, dest: []const u8, mouse: dvui.Point.Physical) bool {
    const r = regionNamed(l.state, dest) orelse return false;
    const on_drop = r.on_drop orelse return false;
    const moved = ownId(l.arena, movedFrom(l, source) orelse return true) orelse return true;
    const s = l.host.surfaceById(moved) orelse return true;
    if (!accepts(r.*, s.keywords)) return true;
    if (on_drop(r.drop_ctx, .{ .surface_id = moved, .zone = .center, .point = mouse, .on_chooser = true })) {
        l.state.markDirty();
        dvui.refresh(null, @src(), null);
    }
    return true;
}

/// Move the visible surface of `source` onto `dest`. The picker's own moves
/// come through here too, which is why it takes a `Drop.Kind` rather than a
/// pointer position.
pub fn place(l: *Layout, source: []const u8, dest: []const u8, kind: Drop.Kind) void {
    // Split onto its own place, a view stays where it is (the empty leaf opens beside it) only
    // when it is all the place holds. Beside others it goes to the leaf under the pointer and they
    // stay: left in the origin, the view and the others kept the place between them and the leaf
    // opened empty on the far side — a tab dragged to the top of its own strip's place moved the
    // tabs left behind to the bottom, as though another view had been carried.
    const same = std.mem.eql(u8, source, dest);
    // An empty place carried: it is the place that moves, not a view (`placeEmpty`).
    if (!std.mem.eql(u8, source, loose_source) and movedFrom(l, source) == null) return placeEmpty(l, source, dest, kind);
    const stays = same and (kind != .split or holding(l, source).len <= 1);
    const plan = Drop.plan(kind, stays, joins(l, source, dest)) orelse return;
    // The trash is about what is carried, not where it was let go.
    if (plan == .remove) return remove(l, source);
    const moved = ownId(l.arena, movedFrom(l, source) orelse return) orelse return;
    if (regionNamed(l.state, dest)) |r| {
        const s = l.host.surfaceById(moved) orelse return;
        if (!accepts(r.*, s.keywords)) return;
        if (!r.kind_slot and l.slotted(s)) return;
        // A plugin's region is asked first: it makes its own places, so a split of it is
        // something only it can do (`RegionSpec.on_drop`).
        if (r.on_drop) |on_drop| {
            const zone: sdk.RegionSpec.Drop.Zone = switch (plan) {
                .swap, .join => .center,
                // Handled before anything is asked of a place (`remove`).
                .remove => unreachable,
                .split => |sp| .{ .edge = switch (sp.landing) {
                    .left => .left,
                    .right => .right,
                    .top => .top,
                    .bottom => .bottom,
                } },
            };
            if (on_drop(r.drop_ctx, .{ .surface_id = moved, .zone = zone })) {
                l.state.markDirty();
                dvui.refresh(null, @src(), null);
                return;
            }
            // Unhandled: the middle falls through to the default below. A plugin's region
            // cannot be split by the app, so an edge nobody handled is no drop.
            if (plan == .split and r.kind_slot) return;
        }
    }
    switch (plan) {
        .swap => swap(l, source, dest, moved),
        .join => join(l, source, dest, moved),
        .remove => unreachable,
        .split => |s| {
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

/// An empty place carried somewhere — the place itself is what moves, there being nothing in it.
/// The trash or another place's middle: it goes, closing into the half beside it (an empty place
/// dropped on an empty one leaves one empty place). Another place's edge: it goes from where it
/// was and opens there instead, an empty half of that place. Onto itself, nothing. Only a half of
/// a split the user made can go (`State.userSplitPart`); a place the shape declared stays.
fn placeEmpty(l: *Layout, source: []const u8, dest: []const u8, kind: Drop.Kind) void {
    if (std.mem.eql(u8, source, dest) and kind != .remove) return;
    if (!l.state.userSplitPart(source)) return;
    switch (kind) {
        .remove, .swap => _ = closeEmptied(l, source),
        .split => |side| {
            // Close it first: closing the half that was split merges its other half into it, and
            // if that other half is where it is going, it is now there under the source's name.
            const merged = closeEmptied(l, source);
            const target = if (merged) |m| (if (std.mem.eql(u8, m.gone, dest)) m.into else dest) else dest;
            _ = Region.splitOn(l, target, side);
        },
    }
    l.state.markDirty();
    dvui.refresh(null, @src(), null);
}

/// What the trash does with the view carried out of `source`: a document closes — the ordinary
/// close, which asks about unsaved changes — and any other view leaves its place, back to the
/// picker it can be placed from again.
fn remove(l: *Layout, source: []const u8) void {
    const moved = ownId(l.arena, movedFrom(l, source) orelse return) orelse return;
    if (sdk.document.pathOfSurfaceId(moved)) |path| if (l.host.docFromPath(path)) |doc| {
        l.host.closeDocById(doc.id) catch |err| dvui.log.err("drop: could not close {s}: {t}", .{ path, err });
        dvui.refresh(null, @src(), null);
        return;
    };
    // A place its keywords fill gives a view up only to a place that claims it (`takeOut`), and
    // the trash claims nothing: the place's list is written down without it, or it stays.
    if (l.state.assignment(source) == null)
        l.state.assign(l.gpa, source, idsWithout(l.arena, holding(l, source), moved)) catch {};
    takeOut(l, source, moved, null);
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

    // Dropped on a place that shows several and already holds it (a tab dropped back into its
    // own strip's place): it is already there, so show it and leave the list alone — claiming
    // it the way a one-view place does would shrink the place to it.
    const dest_many = if (regionNamed(l.state, dest)) |r| r.shows == .many else false;
    if (dest_many) {
        for (holding(l, dest)) |id| if (std.mem.eql(u8, id, moved)) {
            selectNamed(l, dest, moved);
            if (!std.mem.eql(u8, source, dest)) takeOut(l, source, moved, null);
            return;
        };
    }

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

/// Make the two halves of a split one place again, holding the views of both: the place under
/// the pointer's first, in its order, then the source's, the dragged one selected. The split's
/// origin is what stays, whichever half the drag started in (`SplitTree.Forest.joinable`); it
/// shows them as tabs, since it now holds more than one. The minted half slides shut and is
/// dropped once it has (`shutIfEmptied`).
fn join(l: *Layout, source: []const u8, dest: []const u8, moved: []const u8) void {
    const pair = l.state.joinable(source, dest) orelse return swap(l, source, dest, moved);
    var ids: std.ArrayListUnmanaged([]const u8) = .empty;
    for ([_][]const u8{ dest, source }) |name| {
        for (shownIn(l, name)) |id| {
            const own = ownId(l.arena, id) orelse continue;
            if (!containsId(ids.items, own)) ids.append(l.arena, own) catch {};
        }
    }
    if (!containsId(ids.items, moved)) ids.append(l.arena, moved) catch {};
    l.state.setShows(l.gpa, pair.keep, .many);
    l.state.assign(l.gpa, pair.keep, ids.items) catch {};
    l.state.assign(l.gpa, pair.drop, &.{}) catch {};
    selectNamed(l, pair.keep, moved);
    shutIfEmptied(l, pair.drop);
}

/// What a place is showing, for a join to keep: every view a place of tabs holds, the one view
/// a place of one does. A place of one matched by keywords "holds" every surface they match —
/// the whole list it picks from — and joining must not turn that into a row of tabs.
fn shownIn(l: *Layout, name: []const u8) []const []const u8 {
    const many = if (regionNamed(l.state, name)) |r| r.shows == .many else false;
    if (many) return holding(l, name);
    const id = visibleId(l, name) orelse return &.{};
    const out = l.arena.alloc([]const u8, 1) catch return &.{};
    out[0] = id;
    return out;
}

fn containsId(ids: []const []const u8, id: []const u8) bool {
    for (ids) |x| if (std.mem.eql(u8, x, id)) return true;
    return false;
}

/// What a place is holding: the list it was given, or the one its keywords
/// attract when it has never been given one. A `.many` place usually has no
/// list of its own — the sidebar's tabs are every plugin that asked for the
/// sidebar — and reading only the assignment there says "nothing", so a drop
/// onto the rail would leave it holding one lone view.
fn holding(l: *Layout, name: []const u8) []const []const u8 {
    if (l.state.assignment(name)) |ids| return ids;
    const r = regionNamed(l.state, name) orelse return &.{};
    const items = l.matchingIn(r);
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
    return Region.namedSelectionKey(name);
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
/// the user tidy up after their own drag. `State.isMinted` is exactly that
/// distinction — a place the tree is allowed to drop.
///
/// The leaf a split *mints* is empty on purpose and is never passed here: it
/// is the room being made, not room left over.
///
/// Shut rather than deleted, so it slides closed on the curve it opened on;
/// `Region.persistExtent` drops the leaf once the animation has finished.
///
/// Empty is what the place holds, not whether it has a list written down: a place its keywords
/// fill has none, and read as empty it merged the half a split of it had just opened.
fn shutIfEmptied(l: *Layout, name: []const u8) void {
    if (holding(l, name).len > 0) return;
    _ = closeEmptied(l, name);
}

/// A merge of two halves of a split: `gone` closed, its views now in `into`.
const Merged = struct { gone: []const u8, into: []const u8 };

/// Close the emptied place `name`, one half of a split the user made, into the other half. A
/// minted half closes outright (`closeMinted`). The half that was split keeps its name — it is
/// the shape's place — so it takes the other half's views and that half closes instead: the same
/// one place either way, under the name the shape knows. Returns that merge, when it was one.
/// A place no user split made, or whose other half is split again, stays as it is.
fn closeEmptied(l: *Layout, name: []const u8) ?Merged {
    if (l.state.isMinted(name)) {
        closeMinted(l, name);
        return null;
    }
    const sibling_raw = l.state.siblingLeaf(name) orelse return null;
    if (!l.state.isMinted(sibling_raw)) return null;
    const sibling = ownId(l.arena, sibling_raw) orelse return null;
    const into = ownId(l.arena, name) orelse return null;
    const views = shownIn(l, sibling);
    if (views.len > 1) l.state.setShows(l.gpa, into, .many);
    l.state.assign(l.gpa, into, views) catch {};
    if (views.len > 0) selectNamed(l, into, views[0]);
    l.state.assign(l.gpa, sibling, &.{}) catch {};
    closeMinted(l, sibling);
    return .{ .gone = sibling, .into = into };
}

/// Close a minted place, whatever it holds — sliding its split shut where it was drawn.
fn closeMinted(l: *Layout, name: []const u8) void {
    if (!l.state.isMinted(name)) return;
    // A seed's dock tree closes its own leaves, easing the split shut over it.
    if (l.state.dock) |*dock| {
        if (dock.findPanel(name)) |idx| dock.closeLeaf(idx);
        return;
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

test "a document pane does not accept a panel surface" {
    const pane: Region = .{ .name = "Pane 1", .keywords = &.{"main.document"}, .by_name = true, .kind_slot = true };
    const main: Region = .{ .name = "Main", .keywords = sdk.keywords.ide.main };
    const center: Region = .{ .name = "Center", .keywords = &.{"slot"}, .by_name = true };
    try std.testing.expect(!accepts(pane, sdk.keywords.ide.panel));
    try std.testing.expect(accepts(pane, &.{"document"}));
    try std.testing.expect(accepts(main, sdk.keywords.ide.panel));
    try std.testing.expect(accepts(center, sdk.keywords.ide.panel));
}
