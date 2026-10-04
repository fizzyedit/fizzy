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
const Floats = @import("Floats.zig");
const float_rules = @import("float_rules.zig");
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
/// Not carried as anything yet: what it is first carried as is what was grabbed (`noteMode`).
lifting: bool = false,
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
/// Where the pointer was last frame, for a jump from one window's part of the frame to another's
/// (`followAcross`).
last_mouse: ?dvui.Point.Physical = null,
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
/// The floats over the window when the drag began (`Floats`), frozen like the places are: a
/// place a float covers is not aimed at through it, and over a float's header nothing is.
occluders: [Floats.max]Occluder = undefined,
occluder_count: usize = 0,
/// Whether the float the view is carried out of is firm (`settleGhost`): itself, covering what it
/// lies over, rather than its ghost. It starts firm — the drag lifts out of it — and stays so
/// until the view is aimed off it.
ghost_firm: bool = true,
/// Where and when the view came to rest over the ghost (`settleGhost`), while a drop beneath lies
/// under it; 0 when it is not resting over it.
ghost_rest_at: dvui.Point.Physical = .{},
ghost_rest_ns: i128 = 0,

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
    /// A release over it lands the view in its place.
    into: bool = true,
    /// The window it is drawn in (`Region.layer`).
    layer: u16 = 0,
    /// Where along it the view goes in, for a chooser the app draws (`Chooser`): a release puts it
    /// there in its place's list (`insertInto`) — back on the chooser it came off, a reorder. Null
    /// for a plugin's chooser, which says where along it itself, from the release's point
    /// (`RegionSpec.Drop.on_chooser`).
    at: ?Insert = null,
};

/// Where in a place's list a view goes in: before one of its views, after one, or at the end.
/// The views by their interned ids.
pub const Insert = union(enum) {
    before: []const u8,
    after: []const u8,
    end,
};
pub const max_offers = 16;

/// One place the pointer can be read against.
pub const Target = struct {
    /// Interned, so it outlives the frame the map was taken on.
    name: []const u8,
    bounds: dvui.Rect.Physical,
    /// Content size in points, for the extent a landing split settles at.
    size: dvui.Size,
    /// The window it is drawn in (`Region.layer`): 0 the main window, `n` the `n`th float.
    layer: u16 = 0,
};

/// A float over the window, as a drag reads it: the layer its places are drawn in, where its
/// window is and where its header is.
pub const Occluder = struct {
    layer: u16,
    bounds: dvui.Rect.Physical,
    header: dvui.Rect.Physical,
    /// The float the view is carried out of (`carriedOutOf`). It covers only while it is firm.
    source: bool = false,
};

/// What lies under a point, as far as which window: the topmost float there (0, the main window,
/// when none is), and whether the point is on that float's header — its handle, never a drop.
const Under = struct { layer: u16 = 0, header: bool = false };

/// What lies under `p`: the topmost float there, the one the view is carried out of only while it
/// is firm (`settleGhost`) — a ghost covers nothing.
fn under(state: *const Layout.State, p: dvui.Point.Physical) Under {
    const d = &state.view_drag;
    var out: Under = .{};
    for (d.occluders[0..d.occluder_count]) |o| {
        if (!o.bounds.contains(p) or o.layer < out.layer) continue;
        if (o.source and !d.ghost_firm) continue;
        out = .{ .layer = o.layer, .header = o.header.contains(p) };
    }
    return out;
}

/// Whether `p`, aimed with a drop of radius `r`, is on the drop of the place under it in window
/// `layer` (`zoneBounds`) — under the ghost of the float the view is carried out of, the one place it
/// can be under a float and still be aimed at.
fn onDropBeneath(state: *const Layout.State, layer: u16, p: dvui.Point.Physical, r: f32) bool {
    const d = &state.view_drag;
    var best: ?Target = null;
    var best_area: f32 = std.math.floatMax(f32);
    for (d.targets[0..d.target_count]) |t| {
        if (t.layer != layer or !t.bounds.contains(p)) continue;
        const area = t.bounds.w * t.bounds.h;
        if (area >= best_area) continue;
        best = t;
        best_area = area;
    }
    const t = best orelse return false;
    const b = zoneBounds(state, t.name) orelse return false;
    return DropZones.atDisc(DropZones.wheel(b, dvui.currentWindow().natural_scale, removableIn(state)), p, r) != null;
}

/// The float the view is carried out of, as the drag mapped it; null for a drag out of no float.
fn sourceOccluder(d: *const ViewDrag) ?Occluder {
    for (d.occluders[0..d.occluder_count]) |o| if (o.source) return o;
    return null;
}

/// How long the view must rest over the ghost of the float it is carried out of before it firms
/// up, while a drop beneath lies under it (`settleGhost`), in milliseconds as they pass — not
/// motion, which can be off: it is the user saying they mean the float, not an animation.
pub const ghost_rest_ms: i128 = 240;
/// Points the view may drift and still be resting.
const ghost_rest_slop: f32 = 10;

/// Settle whether the float the view is carried out of is firm, for where the view is aimed now,
/// and return it. False for a drag out of no float. Asked any number of times in a frame, it
/// answers the same, so whatever reads the drag first in a frame settles it (`tick`).
///
/// The float the view is carried out of is a ghost of itself (`Floats`) while the pointer carrying
/// the view is off it: what it lies over shows through, and covers nothing (`under`). The drops of the places it
/// lies over sit clear of it where there is room for them (`zoneBounds`), the same firm or ghost,
/// so a drop never moves as the ghost comes and goes. With every drop clear of it, aimed back over
/// it, it firms up at once — the float again, with its own places' drops — and stays firm until the
/// view is aimed off it, so its own middle and edges can be reached wherever they are.
///
/// A drop with too little room clear of it sits under the ghost instead, reached through it: the
/// view over that drop is aimed at it, not the float. And while one does, the ghost firms only for
/// a rest over it, off such a drop or on its header (`ghost_rest_ms`) — at once, it would firm as
/// the view was carried across it to the drop, and that drop could never be reached.
pub fn settleGhost(state: *Layout.State) bool {
    const d = &state.view_drag;
    const g = sourceOccluder(d) orelse {
        d.ghost_firm = false;
        return false;
    };
    const mouse = dvui.currentWindow().mouse_pt;
    const a = aimAt(state, mouse);
    // Over the float by the pointer, not the drop it carries, which rides off to one side of it:
    // lifted from the float's corner button, the drop started out past the float's edge, and the
    // float went toward its ghost, firmed as the drop crossed back over it on the way out, and went
    // again — a hitch in the middle of every drag out of a float.
    if (!g.bounds.contains(mouse)) {
        d.ghost_firm = false;
        d.ghost_rest_ns = 0;
        return false;
    }
    if (d.ghost_firm) return true;
    // Under another float over the ghost, the view is aimed at that one.
    var below: u16 = 0;
    for (d.occluders[0..d.occluder_count]) |o| {
        if (!o.source and o.bounds.contains(a.p) and o.layer > below) below = o.layer;
    }
    // On a drop beneath it the view is aimed at that drop, lit as one — never the float — except
    // over the ghost's header, its handle: a drop under a ghost is its whole size, and over a small
    // ghost it can leave nowhere else to rest.
    const on_header = g.header.contains(mouse);
    if (below > g.layer or (!on_header and onDropBeneath(state, below, a.p, a.r))) {
        d.ghost_rest_ns = 0;
        return false;
    }
    if (!dropUnderGhost(state, g)) {
        d.ghost_firm = true;
        d.ghost_rest_ns = 0;
        return true;
    }
    const cw = dvui.currentWindow();
    const now = cw.frame_time_ns;
    const slop = ghost_rest_slop * cw.natural_scale;
    const dx = mouse.x - d.ghost_rest_at.x;
    const dy = mouse.y - d.ghost_rest_at.y;
    if (d.ghost_rest_ns == 0 or dx * dx + dy * dy > slop * slop) {
        d.ghost_rest_at = mouse;
        d.ghost_rest_ns = now;
    } else if (now - d.ghost_rest_ns >= ghost_rest_ms * std.time.ns_per_ms) {
        d.ghost_firm = true;
        d.ghost_rest_ns = 0;
        return true;
    }
    // Frames while it rests, with nothing else asking for them.
    dvui.refresh(null, @src(), null);
    return false;
}

/// Whether the drop of any place beneath the ghost `g` sits under it (`zoneBounds`): one with too
/// little room clear of it, reached through the ghost.
fn dropUnderGhost(state: *const Layout.State, g: Occluder) bool {
    const d = &state.view_drag;
    for (d.targets[0..d.target_count]) |t| {
        if (t.layer >= g.layer) continue;
        const b = zoneBounds(state, t.name) orelse continue;
        const i = b.intersect(g.bounds);
        if (i.w >= 1 and i.h >= 1) return true;
    }
    return false;
}

/// Whether float `name` is a ghost of itself: a view is carried out of it, aimed elsewhere.
pub fn ghosted(l: *Layout, name: []const u8) bool {
    return carriedOutOf(l, name) and !l.state.view_drag.ghost_firm;
}

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
/// `name`, as one of its views — at `at` in its list, when the chooser knows where along it the
/// pointer is. Its place may sit elsewhere — a rail beside a sidebar — or the chooser inside it;
/// either way over the chooser the drop is into the place, not a split of it.
pub fn offerChooser(l: *Layout, name: []const u8, bounds: dvui.Rect.Physical, into: bool, at: ?Insert) void {
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
    const kept: ?Insert = if (at) |a| switch (a) {
        .before => |id| .{ .before = l.state.internName(l.gpa, id) },
        .after => |id| .{ .after = l.state.internName(l.gpa, id) },
        .end => .end,
    } else null;
    d.offers[d.offer_count] = .{ .name = l.state.internName(l.gpa, name), .bounds = bounds, .into = into, .layer = l.state.layer_building, .at = kept };
    d.offer_count += 1;
}

/// The chooser under `p` that could take what is carried, if one offered itself this frame or
/// the last. A strip whose place cannot take it — a document pane's tabs under a view that is no
/// document — is no chooser for this drag: read as one, it hid every place's zones and turned the
/// card into a tab over a strip it could never go into, so a split document area, a strip on every
/// pane, was a maze to aim a view across. The strip of the place the view came out of always is.
/// A strip a float covers is none either: only the topmost window under `p` is read (`under`).
pub fn chooserAt(state: *const Layout.State, p: dvui.Point.Physical) ?Offer {
    const d = &state.view_drag;
    if (!d.active()) return null;
    const u = under(state, p);
    if (u.header) return null;
    const now = dvui.currentWindow().frame_time_ns;
    if (d.offer_frame == now) {
        for (d.offers[0..d.offer_count]) |o| if (o.layer == u.layer and o.bounds.contains(p) and takes(d, o)) return o;
    }
    for (d.last_offers[0..d.last_offer_count]) |o| if (o.layer == u.layer and o.bounds.contains(p) and takes(d, o)) return o;
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
    // Destroyed with a frame, and only in one: discarded at teardown (quitting mid-drag) there is
    // no window, and the GPU goes with the process.
    if (self.texture) |tex| if (dvui.current_window != null) dvui.Texture.destroyLater(tex);
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
    d.last_mouse = null;
    d.drop_ns = 0;
    d.drop_n = 0;
    d.drop_touch = false;
    d.name = l.state.internName(l.gpa, name);
    d.from = from.size();
    d.start_ns = dvui.currentWindow().frame_time_ns;
    d.ghost_firm = true;
    // The carried glass grows out of what was grabbed — the place's grid button, its tab or rail
    // icon — with its photograph growing in it: not glass the size of the whole place shrinking
    // into it, which drew the view whole for a moment before it was carried.
    liftShape(d, grabbed);
    if (visibleId(l, name)) |id| d.moved_id = id;
    mapTargets(l, d);
    // Carried out of a float, the float goes to a ghost of itself: photographed now, whole, before
    // anything of the drag is drawn over it.
    Floats.liftedFrom(l, name, d.moved_id);
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
    d.lifting = true;
}

/// Begin carrying surface `id` from the picker, or from a plugin's own list (`Host.beginViewDrag`):
/// a tab off its strip, a file out of a tree — which may be a document not open yet, carried by
/// the id it will have (`unopened`). There is no source place, so nothing is photographed: the
/// float starts at the card that was grabbed and shows the picture the card showed, which the
/// caller hands over (`State.stealSnapshot`) and the drag destroys.
pub fn beginLoose(l: *Layout, id: []const u8, from: dvui.Rect.Physical, texture: ?dvui.Texture) void {
    var d = &l.state.view_drag;
    d.drop_head = .{};
    d.drop_tail = .{};
    d.last_mouse = null;
    d.drop_ns = 0;
    d.drop_n = 0;
    d.drop_touch = false;
    // A surface's id is its registry's; a document not open yet has only the plugin's, which is
    // its frame's, so it is interned to outlive the drag.
    const moved = if (l.host.surfaceById(id)) |s| s.id else if (unopened(l, id)) l.state.internName(l.gpa, id) else return;
    d.name = loose_source;
    d.from = from.size();
    d.start_ns = dvui.currentWindow().frame_time_ns;
    liftShape(d, from);
    d.moved_id = moved;
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
    const slotted = slottedId(l, d.moved_id);
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
            .layer = r.layer,
        };
        d.target_count += 1;
    }
    mapOccluders(l, d);
}

/// Photograph the floats with the places: each one's window and header, with the layer its places
/// are drawn in (`Floats.draw`: the `n`th from the bottom is layer `n`). A float flying shut covers
/// nothing. The one the view is being carried out of (`carriedOutOf`) is marked: it covers only
/// while it is firm (`under`).
fn mapOccluders(l: *Layout, d: *ViewDrag) void {
    d.occluder_count = 0;
    for (l.state.floats.items.items, 0..) |f, i| {
        if (d.occluder_count == d.occluders.len) break;
        if (f.closing or f.bounds.w <= 0 or f.bounds.h <= 0) continue;
        d.occluders[d.occluder_count] = .{ .layer = @intCast(i + 1), .bounds = f.bounds, .header = f.header, .source = carriedOutOf(l, f.name) };
        d.occluder_count += 1;
    }
}

/// Whether the live drag is carrying a view out of float `name` — out of its place, or a place a
/// split of it made. The float is a ghost of itself meanwhile while the view is aimed off it — it
/// fades to a faint, blurred picture of itself (`Floats.draw`) and covers nothing (`under`), so
/// what it lies over, usually where the view is going, can be seen and aimed at — and firms up
/// again when the view is aimed back over it, to be dropped into. When the drag ends it comes back:
/// as it was if the view is let go over nothing, without the view if it landed elsewhere, and not
/// at all if that left it empty.
pub fn carriedOutOf(l: *Layout, name: []const u8) bool {
    const d = &l.state.view_drag;
    if (!d.active() or d.loose()) return false;
    const root = l.state.floatRoot(d.name) orelse return false;
    return std.mem.eql(u8, root, name);
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
    const dest_b = zoneBounds(l.state, dest) orelse return null;
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
    return aimAt(l.state, mouse);
}

fn aimAt(state: *const Layout.State, mouse: dvui.Point.Physical) Aim {
    const d = &state.view_drag;
    const cw = dvui.currentWindow();
    if (!d.active() or !carriedAsDrop(state, mouse)) return .{ .p = mouse };
    const R = drop_r * cw.natural_scale;
    return .{ .p = dropCenter(mouse, R, d.drop_touch), .r = R };
}

/// Whether the view is carried as a drop of glass at `mouse`: where the glass program draws, with
/// a photograph to show in it, and not over a list (where it is a tab).
fn carriedAsDrop(state: *const Layout.State, mouse: dvui.Point.Physical) bool {
    const d = &state.view_drag;
    // A bubble only round a photograph. With none — a file not open yet, a document open in no pane
    // — it is carried as its tab in glass, its icon and its name (`drawTabFace`): a bubble with an
    // icon in it read as a thing of its own rather than the tab it is.
    return core.LiquidField.ready() and d.texture != null and chooserAt(state, mouse) == null;
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
    return removableIn(l.state);
}

fn removableIn(state: *const Layout.State) bool {
    const d = state.view_drag;
    if (!d.active() or d.loose()) return false;
    // Out of a float, as out of a split the user made: the view leaves it, and a float its last
    // view leaves closes — the view, claimed by no place then, back where its keywords put it.
    if (state.floatRoot(d.name) != null) return true;
    if (state.userSplitPart(d.name)) return true;
    const r = regionNamed(state, d.name) orelse return false;
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

/// The part of place `name` its drop sits in: its interior (`interiorBounds`) less every float over
/// it — a float drawn in a window above the place's, as the drag mapped them (`mapOccluders`). A
/// drop under a float could not be aimed at, so it goes where it can be: the middle of the part
/// left clear, fitted there as a wheel or a strip as anywhere (`DropZones.uncovered`). A float's
/// own places are in its window, so theirs are inside it. Null when floats cover all of it: that
/// place has no drop.
///
/// The float the view is carried out of is weighed differently, since as a ghost it can be aimed
/// through (`settleGhost`): a drop stays clear of it only while that leaves the drop
/// `ghost_min_share` or more of the size it would have with no ghost there. Squeezed smaller, or with nothing clear of it, the drop
/// sits as if the ghost were not there, under it, whole, and is reached through it. Firm or ghost,
/// it is the same rect, so no drop moves or changes size as the ghost comes and goes; firm, the
/// float takes the pointer over it, so a drop under it is not aimed at until it fades again.
///
/// Everything that reads or draws a place's drop reads this — its zones (`drawZones`), the release
/// (`kindAt`), the self-split (`targetAtAim`) — so what shows is what a release takes.
pub fn zoneBounds(state: *const Layout.State, name: []const u8) ?dvui.Rect.Physical {
    if (!state.view_drag.active()) return interiorBounds(state, name);
    const clear = zoneBoundsAs(state, name, true);
    if (sourceOccluder(&state.view_drag) == null) return clear;
    const through = zoneBoundsAs(state, name, false) orelse return clear;
    const c = clear orelse return through;
    const scale = dvui.currentWindow().natural_scale;
    const trash = removableIn(state);
    const clear_unit = DropZones.wheel(c, scale, trash).unit;
    const through_unit = DropZones.wheel(through, scale, trash).unit;
    return if (clear_unit >= ghost_min_share * through_unit) c else through;
}

/// The least share of the size it would have with no ghost there that a drop shrinks to, to stay
/// clear of the ghost of the float the view is carried out of (`zoneBounds`); any smaller, and it
/// keeps that size, under the ghost.
pub const ghost_min_share: f32 = 0.75;

/// `zoneBounds` with the float the view is carried out of covering (`ghost`) or not.
fn zoneBoundsAs(state: *const Layout.State, name: []const u8, ghost: bool) ?dvui.Rect.Physical {
    const inner = interiorBounds(state, name) orelse return null;
    const d = &state.view_drag;
    if (!d.active()) return inner;
    const layer = layerOf(state, name);
    var covers: [Floats.max]dvui.Rect.Physical = undefined;
    var n: usize = 0;
    for (d.occluders[0..d.occluder_count]) |o| {
        if (o.layer <= layer or (o.source and !ghost)) continue;
        covers[n] = o.bounds;
        n += 1;
    }
    return DropZones.uncovered(inner, covers[0..n], dvui.currentWindow().natural_scale, removableIn(state));
}

/// Place `name`'s drop, where it sits (`zoneBounds`); null where it has none.
pub fn wheelOf(state: *const Layout.State, name: []const u8) ?DropZones.Wheel {
    const b = zoneBounds(state, name) orelse return null;
    return DropZones.wheel(b, dvui.currentWindow().natural_scale, removableIn(state));
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
    const d = &state.view_drag;
    // Only the topmost window under the pointer is aimed at: a place a float covers is not
    // reached through it, and a float's header is its handle, no drop.
    const u = under(state, mouse);
    if (u.header) return null;
    // Over a chooser, its place — as one of its views, never a split — or nowhere, over the
    // app's own strip of the place the view came out of.
    if (chooserAt(state, mouse)) |o| return if (o.into) o.name else null;
    // The source's own edge is a self-split, and it outranks any pane nested
    // inside it — otherwise a document filling the place always wins on area
    // and its own edges become unreachable.
    if (layerOf(state, source) == u.layer) {
        if (interiorBounds(state, source)) |bounds| {
            if (bounds.contains(mouse)) if (zoneBounds(state, source)) |zb| {
                if (Drop.kindAtDisc(zb, mouse, a.r, dvui.currentWindow().natural_scale, removable(l))) |k| switch (k) {
                    .split, .remove => return source,
                    .swap => {},
                };
            };
        }
    }
    var best: ?[]const u8 = null;
    var best_area: f32 = std.math.floatMax(f32);
    for (d.targets[0..d.target_count]) |t| {
        if (t.layer != u.layer or !t.bounds.contains(mouse)) continue;
        const area = t.bounds.w * t.bounds.h;
        if (area >= best_area) continue;
        best = t.name;
        best_area = area;
    }
    return best;
}

/// The window place `name` is drawn in (`Region.layer`), as the drag mapped it — or as it last
/// registered, for a place the drag did not map.
fn layerOf(state: *const Layout.State, name: []const u8) u16 {
    if (frozen(state, name)) |t| return t.layer;
    if (regionNamed(state, name)) |r| return r.layer;
    return 0;
}

/// What the view being carried is, for deciding which places will take it.
/// The surface lifted at the start, not whatever the source place happens to
/// be showing — mid-swap it is showing the *other* view, and reading that
/// would change which places accept the drop halfway through it.
fn draggedKeywords(l: *Layout) []const []const u8 {
    const id = l.state.view_drag.moved_id;
    if (id.len == 0) return &.{};
    return keywordsOf(l, id);
}

/// Whether `id` is a document not open yet: a file carried out of a tree, by the id it will have
/// (`sdk.document.surfaceId`), for which no surface is registered until it opens. It goes only to
/// a slot made for documents, whose own drop opens it (`RegionSpec.on_drop`).
fn unopened(l: *Layout, id: []const u8) bool {
    return l.host.surfaceById(id) == null and sdk.document.pathOfSurfaceId(id) != null;
}

/// The keywords `id` is carried with: its surface's, or a document's while it is not open.
fn keywordsOf(l: *Layout, id: []const u8) []const []const u8 {
    if (l.host.surfaceById(id)) |s| return s.keywords;
    return if (unopened(l, id)) sdk.document.keywords else &.{};
}

/// Whether `id` goes only to a slot made for its kind (`Layout.slotted`), as a document does,
/// open or not.
fn slottedId(l: *Layout, id: []const u8) bool {
    if (l.host.surfaceById(id)) |s| return l.slotted(s);
    return unopened(l, id);
}

/// What `id` is called on its tab: its surface's title, or a document's file name while it is
/// not open.
fn titleOf(l: *Layout, id: []const u8) []const u8 {
    if (l.host.surfaceById(id)) |s| return s.title;
    if (sdk.document.pathOfSurfaceId(id)) |path| return std.fs.path.basename(path);
    return "view";
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
    _ = settleGhost(l.state);
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
    // place's list, and the zones are for its content — the part of it no float lies over
    // (`zoneBounds`). All of it under floats, it has no drop: one still going finishes where it was.
    const whole = interiorBounds(l.state, name) orelse {
        DropZones.forget(key);
        return;
    };
    const own = wheelOf(l.state, name);
    const covered = own == null;
    const zones = own orelse DropZones.given(key) orelse {
        DropZones.forget(key);
        return;
    };
    const d = &l.state.view_drag;
    const center: DropZones.Center = if (std.mem.eql(u8, d.name, name))
        (if (canFloat(l, name)) .float else .none)
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
            .hovered = if (aimed and !covered) blk: {
                const a = aim(l);
                break :blk DropZones.atDisc(zones, a.p, a.r);
            } else null,
            .target = target and !covered,
            .center = center,
        },
        .clip = whole,
    };
    d.pending_count += 1;
}

/// What a view drag draws over every place at once, after they have all drawn: the drops they
/// queued (`drawZones`), and over them the card riding the pointer — in a layer of its own over the
/// window and every float on it.
pub fn drawOverlay(l: *Layout) void {
    const d = &l.state.view_drag;
    const now = dvui.currentWindow().frame_time_ns;
    if (d.active()) followAcross(d, dvui.currentWindow().mouse_pt);
    const queued = if (d.pending_frame == now) d.pending[0..d.pending_count] else d.pending[0..0];
    // This frame's drops, and any from last frame still going that no place asked for this time —
    // the place a drop just landed on can be gone or changed by now, and its drop still has to run
    // back together and shrink away rather than vanish mid-way.
    // Whether the float the view is carried out of is firm, kept for the frames after this one
    // (`under`).
    if (d.active()) _ = settleGhost(l.state);
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
    n = handOffDrops(drops[0..n]);
    d.last_pending = drops;
    d.last_pending_count = n;
    // Nothing to lay over the window.
    if (n == 0 and !d.active()) return;
    var layer: dvui.FloatingWidget = undefined;
    layer.init(@src(), .{ .mouse_events = false }, .{ .rect = .cast(dvui.windowRect()), .background = false });
    defer layer.deinit();
    // Over every float. A floating widget stays just above the window it was made in — this one
    // the app's own, which every float is over, so the drops on a float's place and the view
    // carried over a float were drawn under its glass — and is re-added as a window of its own
    // and raised, as the demo overlay's layers are (`automation/overlay.zig`). It takes no pointer
    // events: what is under it still takes them, the drag's hold on the pointer included.
    const wd = layer.data();
    dvui.subwindowAdd(wd.id, wd.rect, wd.rectScale().r, false, null, false);
    dvui.raiseSubwindow(wd.id);
    // On every screen (`core.screens`): a place in a float popped out into its own window has
    // its drop drawn here, at that window's part of the frame, and so does the carried view
    // when the pointer is there — clipped to the main window, both were dropped as they were
    // drawn, and the app copies this layer into every such window as well as the main one.
    core.screens.markEverywhere(wd.id);
    dvui.clipSet(core.screens.allPixels());
    // The drops, then the card over them: one layer, so their order is the order drawn — the
    // card's glass showing the drop it is aimed at blurred through it, its top left just off the
    // pointer so the bubble under the pointer stays in view.
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

/// A drop coming in where another is going — the place the view is aimed at now lying under the
/// one it was, as a float's place does under the place beneath it when the float firms up from its
/// ghost — takes over the going one's glass and changes into itself (`DropZones.handOff`), rather
/// than coming in over it as it goes: both in one spot read as the drop opening and shutting twice.
/// Returns how many of `drops` are left, the ones handed off taken out.
fn handOffDrops(drops: []PendingDrop) usize {
    var n = drops.len;
    for (0..drops.len) |i| {
        if (i >= n) break;
        const p = drops[i];
        if (!p.look.target or DropZones.showing(p.key)) continue;
        var j: usize = 0;
        while (j < n) : (j += 1) {
            const q = drops[j];
            if (q.key == p.key or q.look.target) continue;
            const shape = DropZones.shapeOf(q.key) orelse continue;
            if (shape.unit <= 0) continue;
            const reach = 2 * q.wheel.bubble(.center).r;
            const dx = p.wheel.center.x - shape.center.x;
            const dy = p.wheel.center.y - shape.center.y;
            if (dx * dx + dy * dy > reach * reach) continue;
            DropZones.handOff(q.key, p.key);
            drops[j] = drops[n - 1];
            n -= 1;
            break;
        }
    }
    return n;
}

/// Points: the radius of the view carried as a drop — the drop zones' middle bubble's, so what is
/// carried reads as big as where it goes, and is still seen beside a finger — and its tail's share
/// of it.
const drop_r: f32 = 52;
const drop_tail_share: f32 = 0.62;
/// How far toward the bubble it is aimed at the drop is drawn, so the two run together.
const drop_pull: f32 = 0.45;

/// The farthest the pointer moves in a frame within one window's part of the frame, physical
/// pixels: past it, it went from one window to another — a float out of the main window is drawn
/// in a band 100000 pixels on (`Floats.Viewport`).
const across_jump: f32 = 30000;

/// The pointer gone from one window's part of the frame to another's in one frame — out of a
/// float's window over the main window, or back — the carried view goes with it as it is: its
/// springs and the shape it is changing from move by the same jump. Left, they swept back across
/// the band and the view showed for a frame or two in the window it had left.
fn followAcross(d: *ViewDrag, mouse: dvui.Point.Physical) void {
    defer d.last_mouse = mouse;
    const was = d.last_mouse orelse return;
    const dx = mouse.x - was.x;
    const dy = mouse.y - was.y;
    if (@abs(dx) < across_jump and @abs(dy) < across_jump) return;
    for ([_]*core.Spring{ &d.drop_head, &d.drop_tail }) |sp| {
        sp.pos.x += dx;
        sp.pos.y += dy;
    }
    d.morph_rect.x += dx;
    d.morph_rect.y += dy;
    d.shape_rect.x += dx;
    d.shape_rect.y += dy;
}

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
    if (carriedAsDrop(l.state, mouse)) return .drop;
    return if (chooserAt(l.state, mouse) != null) .tab else .preview;
}

/// A change of what the view is carried as: the new shape sets out from the one last drawn.
///
/// The first, at the lift, is from what was grabbed, which already shows what it is carried as —
/// a tab lifted along a strip is carried as the tab it was — so it grows into its shape with its
/// face whole, rather than fading its own face back in.
fn noteMode(d: *ViewDrag, mode: Mode, now: i128) void {
    const first = d.lifting;
    d.lifting = false;
    if (mode == d.mode) return;
    d.morph_from_mode = if (first) mode else d.mode;
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
        // At the merge it is drawn at inside a place's drop (`DropZones.merge`). Its head and tail
        // overlap, and the join between them swells the outline by up to a quarter of the merge:
        // drawn alone at a wider one, between two places — over the sash between them — the drop
        // grew by some 8% of its radius, and shrank back as the pointer reached either side.
        var field: core.LiquidField = .{ .merge_px = DropZones.merge * scale };
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
    drawDropLabel(l, head, shown);
}

/// What the drop is carrying, named: a photograph of a view is not always enough to tell one
/// from another, and an icon alone says only what kind of file it is.
fn dropTitle(l: *Layout, d: ViewDrag) ?[]const u8 {
    if (l.host.surfaceById(d.moved_id)) |s| return s.title;
    const doc = draggedDoc(l, d) orelse return null;
    return std.fs.path.basename(doc.path);
}

/// How far below the head's middle the label's line sits, as a share of the head's radius:
/// inside the circle, clear of the photograph's middle.
const drop_label_drop: f32 = 0.42;

/// The drop's label: the view's title, or the document's name, low in the head, cut to fit its
/// width with an ellipsis. `shown` fades it in with the drop's content.
fn drawDropLabel(l: *Layout, head: dvui.Rect.Physical, shown: f32) void {
    const d = &l.state.view_drag;
    const title = dropTitle(l, d.*) orelse return;
    if (title.len == 0 or shown <= 0.01) return;
    const hn = head.toNatural();
    const font = dvui.Font.theme(.body).larger(-2);
    const line_h = font.lineHeight();
    const max_w = hn.w * 0.72;
    if (max_w < 16) return;
    // Cut to fit, a character at a time, with an ellipsis: a long file name keeps its start.
    var buf: [128]u8 = undefined;
    var text: []const u8 = title;
    if (font.textSize(text).w > max_w) {
        var n: usize = @min(title.len, buf.len - 4);
        while (n > 0) : (n -= 1) {
            // Never split a UTF-8 sequence.
            if (n < title.len and (title[n] & 0xC0) == 0x80) continue;
            text = std.fmt.bufPrint(&buf, "{s}…", .{title[0..n]}) catch return;
            if (font.textSize(text).w <= max_w) break;
        }
        if (n == 0) return;
    }
    const tw = font.textSize(text).w;
    const cx = hn.x + hn.w / 2;
    const cy = hn.y + hn.h / 2 + hn.h / 2 * drop_label_drop;
    const prev_alpha = dvui.alpha(shown);
    defer dvui.alphaSet(prev_alpha);
    const theme = dvui.themeGet();
    dvui.labelNoFmt(@src(), text, .{}, .{
        .rect = .{ .x = cx - tw / 2, .y = cy - line_h / 2, .w = tw + 1, .h = line_h },
        .padding = .{},
        .margin = .{},
        .font = font,
        .color_text = .{ .color = theme.color(.window, .text) },
    });
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
    const title = titleOf(l, d.moved_id);
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
            var field: core.LiquidField = .{ .merge_px = DropZones.merge * scale };
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
/// Points: the widest a carried tab keeps the width it was lifted at (`pillSize`).
const max_lifted_w: f32 = 480;

fn pillSize(l: *Layout, d: ViewDrag, title: []const u8, scale: f32) dvui.Size.Physical {
    const text = dvui.Font.theme(.body).textSize(title);
    const doc = draggedDoc(l, d);
    var w = text.w + 2 * face_pad_x;
    if (doc != null) w += face_icon + face_gap;
    if (doc) |dd| if (dd.dirty) {
        w += face_gap + face_dot;
    };
    const h = @max(face_icon, text.h) + 2 * face_pad_y;
    // As wide as what it was lifted from, when that was wider than what it shows — an explorer row
    // runs on past its name: it is held where it was grabbed (`drawFloat`), and narrowed to its
    // name, a row grabbed toward its end was carried off to the side of the pointer. A loose drag
    // only: one lifted from a place is that place's size, not a tab's.
    if (d.loose()) w = @max(w, @min(d.from.w / scale, max_lifted_w));
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
    // Let go over no window of the app's, where floats are OS windows of their own: a float opens
    // there, in a window of its own, with the view in it — as a tab torn off onto the desktop opens
    // a window where it lands.
    if (l.state.floats_windowed and overNoWindow(mouse)) return floatAway(l, source, mouse);
    if (chooserAt(l.state, mouse)) |o| {
        if (!o.into) return;
        if (dropOnPluginChooser(l, source, o.name, mouse)) return;
        // Where along it the chooser said: in the place's list there — on the chooser it came
        // off, moved along it.
        if (o.at) |at| return insertInto(l, source, o.name, at);
        // Its own place's chooser, saying nothing of where along it: no move. Never a float —
        // that is the middle of the place, not its list.
        if (std.mem.eql(u8, o.name, source)) return;
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
    if (!accepts(r.*, keywordsOf(l, moved))) return true;
    if (on_drop(r.drop_ctx, .{ .surface_id = moved, .zone = .center, .point = mouse, .on_chooser = true })) {
        l.state.markDirty();
        dvui.refresh(null, @src(), null);
    }
    return true;
}

/// Put the view carried out of `source` into place `dest`'s list at `at`, and show it there — let
/// go over a chooser the app drew (`Chooser`), where along it. Into the place it came out of, it
/// moves along the list: the place's order, kept as its assignment when it has one, else as an
/// order (`State.setOrder`) — never as a new assignment, which would freeze a place its keywords
/// fill against views registered later. Into another place, it leaves the one it was in, as any
/// drop into a place's middle does, and the list it goes into is written down. A place that shows
/// one view at a time has a list all the same — the one its chooser picks from — and shows the view
/// that went in.
pub fn insertInto(l: *Layout, source: []const u8, dest: []const u8, at: Insert) void {
    const moved = ownId(l.arena, movedFrom(l, source) orelse return) orelse return;
    if (l.host.surfaceById(moved) == null) return;
    const r = regionNamed(l.state, dest) orelse return;
    if (!accepts(r.*, keywordsOf(l, moved))) return;
    if (!r.kind_slot and slottedId(l, moved)) return;
    const assigned = l.state.assignment(dest);
    const held = holding(l, dest);
    const along = containsId(held, moved);
    // The whole list it goes into: the assignment, ids of plugins not loaded now included so they
    // keep their slots; or what the place shows by keyword, then — moving along an order —
    // whatever an earlier order named that is not showing now.
    var base: std.ArrayListUnmanaged([]const u8) = .empty;
    base.appendSlice(l.arena, held) catch return;
    if (assigned == null and along) if (l.state.order(dest)) |ids| for (ids) |id| {
        if (!containsId(base.items, id)) base.append(l.arena, id) catch return;
    };
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    for (base.items) |id| if (!std.mem.eql(u8, id, moved)) list.append(l.arena, id) catch return;
    const index = switch (at) {
        .before => |id| indexOfId(list.items, id) orelse list.items.len,
        .after => |id| if (indexOfId(list.items, id)) |i| i + 1 else list.items.len,
        .end => list.items.len,
    };
    list.insert(l.arena, index, moved) catch return;
    if (assigned == null and along) {
        l.state.setOrder(l.gpa, dest, list.items) catch return;
    } else {
        l.state.assign(l.gpa, dest, list.items) catch return;
    }
    selectNamed(l, dest, moved);
    if (!along) {
        takeOut(l, source, moved, null);
        shutIfEmptied(l, source);
    }
    l.state.markDirty();
    dvui.refresh(null, @src(), null);
}

fn indexOfId(ids: []const []const u8, id: []const u8) ?usize {
    for (ids, 0..) |x, i| if (std.mem.eql(u8, x, id)) return i;
    return null;
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
    const plan = Drop.plan(kind, stays, joins(l, source, dest), same and canFloat(l, source)) orelse return;
    // The trash is about what is carried, not where it was let go.
    if (plan == .remove) return remove(l, source);
    const moved = ownId(l.arena, movedFrom(l, source) orelse return) orelse return;
    // Out of its own place into a window of its own: the framework's to do, not the place's —
    // a plugin region's own drop is never asked.
    if (plan == .float) {
        floatOut(l, source, moved, null);
        shutIfEmptied(l, source);
        l.state.markDirty();
        dvui.refresh(null, @src(), null);
        return;
    }
    // A document not open yet has no surface to place: only a slot's own drop takes it, and
    // opens it there (`unopened`).
    const has_surface = l.host.surfaceById(moved) != null;
    if (!has_surface and !unopened(l, moved)) return;
    if (regionNamed(l.state, dest)) |r| {
        if (!accepts(r.*, keywordsOf(l, moved))) return;
        if (!r.kind_slot and slottedId(l, moved)) return;
        // A plugin's region is asked first: it makes its own places, so a split of it is
        // something only it can do (`RegionSpec.on_drop`).
        if (r.on_drop) |on_drop| {
            const zone: sdk.RegionSpec.Drop.Zone = switch (plan) {
                .swap, .join => .center,
                // Handled before anything is asked of a place (`remove`, `floatOut`).
                .remove, .float => unreachable,
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
    if (!has_surface) return;
    switch (plan) {
        .swap => swap(l, source, dest, moved),
        .join => join(l, source, dest, moved),
        .remove, .float => unreachable,
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

/// Whether the view carried out of `source` floats when it is dropped on the middle of `source`
/// (`float_rules.canFloat`): not out of the picker, not a document — its place is the slot a
/// plugin made for it — and not a view already alone in a float nobody split.
/// Over no window of the app's: past the main window, and on no screen a float's window shows
/// (`core.screens`) — the pointer is read in the main window's frame there (`SDLBackend.heldPoint`).
fn overNoWindow(mouse: dvui.Point.Physical) bool {
    if (dvui.windowRectPixels().contains(mouse)) return false;
    const s = dvui.windowNaturalScale();
    const screen = core.screens.screenFor(.{ .x = mouse.x / s, .y = mouse.y / s });
    const main = dvui.windowRect();
    return screen.x == main.x and screen.y == main.y and screen.w == main.w and screen.h == main.h;
}

/// The view carried out of `source`, let go over no window of the app's (`apply`): a float of its
/// own opens round where it was let go (`floatOut`), which the application puts in an OS window of
/// its own. Any view that may float — a view alone in a float's window too: its window closes, and
/// one opens where it was let go.
fn floatAway(l: *Layout, source: []const u8, mouse: dvui.Point.Physical) void {
    if (std.mem.eql(u8, source, loose_source)) return;
    const moved = ownId(l.arena, movedFrom(l, source) orelse return) orelse return;
    const s = l.host.surfaceById(moved) orelse return;
    if (!float_rules.canFloat(.{ .slotted = l.slotted(s), .alone_in_float = false })) return;
    floatOut(l, source, moved, mouse);
    shutIfEmptied(l, source);
    l.state.markDirty();
    dvui.refresh(null, @src(), null);
}

fn canFloat(l: *Layout, source: []const u8) bool {
    if (std.mem.eql(u8, source, loose_source)) return false;
    const moved = movedFrom(l, source) orelse return false;
    const s = l.host.surfaceById(moved) orelse return false;
    const alone = l.state.floats.find(source) != null and l.state.splits.root(source) == null and holding(l, source).len <= 1;
    return float_rules.canFloat(.{ .slotted = l.slotted(s), .alone_in_float = alone });
}

/// Float `moved` out of `source`: a new float (`Floats`) holding just it, where `float_rules`
/// opens one — out of another float, a step down and right of that one — growing out of the glass
/// it was carried in, with the photograph the drag took of it. The source loses the view; a place
/// of several keeps the rest.
fn floatOut(l: *Layout, source: []const u8, moved: []const u8, at: ?dvui.Point.Physical) void {
    const state = l.state;
    const cw = dvui.currentWindow();
    const scale = cw.natural_scale;
    var buf: [32]u8 = undefined;
    const name = state.internName(l.gpa, float_rules.nextName(&buf, state.floats.names(l.arena)));
    const window = Floats.toRules(dvui.windowRect());
    const src = placeBounds(state, source) orelse dvui.windowRectPixels();
    const out_of: ?usize = if (state.floats.rootOf(source)) |root| state.floats.find(root) else null;
    var rect = if (out_of) |i|
        float_rules.nudged(Floats.toRules(state.floats.items.items[i].rect), window)
    else
        float_rules.initialRect(Floats.toRules(src.toNatural()), window);
    // Let go over no window of the app's (`floatAway`): its size, round where it was let go, out
    // there — not held on the main window.
    if (at) |p| {
        rect.x = p.x / scale - rect.w / 2;
        rect.y = p.y / scale - rect.h / 2;
    }
    // Out of a float, home is still where that float came from: the place it opened over is a
    // float's, and goes with it.
    const home = if (out_of) |i| state.floats.items.items[i].home else state.internName(l.gpa, source);
    // The glass it was carried in, when a drag let go of it here; the place itself, when nothing
    // was carried (the picker, a test).
    const d = &state.view_drag;
    const carried = d.active() and std.mem.eql(u8, d.name, source) and d.shape_rect.w > 0;
    var landing: Floats.Landing = .{
        .from = if (carried) d.shape_rect else src,
        .radius = if (carried) d.shape_radius else core.corners.scaled(core.corners.card) * scale,
    };
    if (carried) {
        // The float has the photograph now; the drag's discard must not destroy it.
        landing.photo = d.texture;
        landing.photo_size = d.texture_rect.size();
        d.texture = null;
    }
    _ = state.floats.add(l.gpa, .{
        .name = name,
        .rect = Floats.fromRules(rect),
        .home = home,
        .landing = landing,
    }) catch {
        if (landing.photo) |tex| dvui.Texture.destroyLater(tex);
        return;
    };
    state.assign(l.gpa, name, &.{moved}) catch {};
    selectNamed(l, name, moved);
    takeOut(l, source, moved, null);
}

/// Send the views of a closing float's places (`leaves`) back to `home`, the place the float came
/// out of (`float_rules.goHome`): into its list when the user had arranged it, otherwise let go,
/// for its keywords to place — which, for a place its keywords fill, is home again. Each is
/// selected there, so the view the user had in front of them is in front of them again.
pub fn sendHome(l: *Layout, leaves: []const []const u8, home: []const u8) void {
    const state = l.state;
    // No home (a saved float whose home was lost): every view is let go. Not looked up — an
    // unnamed place would answer to "".
    const r = if (home.len > 0) regionNamed(state, home) else null;
    for (leaves) |leaf| {
        // A copy: assigning a view home takes it out of the leaf's list, freeing the one read.
        const ids = l.arena.dupe([]const u8, state.assignment(leaf) orelse continue) catch continue;
        for (ids) |raw| {
            const id = ownId(l.arena, raw) orelse continue;
            const held = holding(l, home);
            switch (float_rules.goHome(.{
                .declared = r != null,
                .assigned = state.assignment(home) != null,
                .shows_many = if (r) |x| x.shows == .many else false,
                .empty = held.len == 0,
            })) {
                .add => state.assign(l.gpa, home, idsWith(l.arena, held, id)) catch {},
                .put => state.assign(l.gpa, home, &.{id}) catch {},
                .keywords => {},
            }
            if (r != null) selectNamed(l, home, id);
        }
    }
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
    // A float nobody split, left with nothing to show, closes: it was the view's window.
    if (l.state.floats.find(name) != null and l.state.splits.root(name) == null) {
        Floats.close(l, name, .emptied);
        return null;
    }
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
    // A seed's dock tree closes its own leaves, easing the split shut over it. A float's splits
    // are the forest's, whatever the shape is built from.
    if (l.state.floatRoot(name) == null) {
        if (l.state.dock) |*dock| {
            if (dock.findPanel(name)) |idx| dock.closeLeaf(idx);
            return;
        }
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
