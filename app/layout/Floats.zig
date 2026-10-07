//! The views floating over the window: places the framework owns rather than a shape, each a
//! glass window holding an ordinary region (`Float N`). A view dropped on the middle of the place
//! it was lifted from floats here (`ViewDrag.floatOut`); dragged out again by its corner button,
//! or closed from its header, it goes back.
//!
//! A float is a place like any other: its name keys its assignment, its splits (`Float 1/r1`)
//! live in the split forest, and the saved layout keeps it. What only a float has — where its
//! window is, where it came from, how it is landing or closing — is kept here, in z order. The
//! rules it follows are values in `float_rules.zig`.
const std = @import("std");
const dvui = @import("dvui");
const rules = @import("float_rules.zig");
const core = @import("core");
const Layout = @import("Layout.zig");
const ViewDrag = @import("ViewDrag.zig");
const dialogs = core.dialogs;

const Floats = @This();

/// A float growing out of the glass a view was carried in, the frame it is let go onward.
pub const Landing = struct {
    /// The carried glass when it was let go, physical pixels.
    from: dvui.Rect.Physical,
    /// Its corner radius then, physical.
    radius: f32,
    /// How far it has got: stepped from the frame its window is first drawn, the release's.
    clock: core.FrameClock = .{},
    /// The carried view's photograph, fading out as the view itself fades in over it. Owned:
    /// taken from the drag, destroyed when the landing ends or the float goes.
    photo: ?dvui.Texture = null,
    /// The size it was taken at, physical, for its proportions.
    photo_size: dvui.Size.Physical = .{},
};

pub const Float = struct {
    /// Its place's name, `Float {n}`. Interned (`State.internName`): it outlives the frame.
    name: []const u8,
    /// Where its window is, in natural units relative to the main window.
    rect: dvui.Rect,
    /// The place the view floated out of, where closing the float sends it (interned).
    home: []const u8,
    /// The window's id extra: unique for as long as the app runs, so a closed float's window
    /// state (dvui forgets it a frame later) is never read by the next float of the same name.
    serial: u64 = 0,
    /// Not drawn yet: the first frame it is drawn it only registers its place (`draw`).
    fresh: bool = true,
    /// Brought back from a saved layout: the window it comes back into may be smaller than the
    /// one it was saved in, so its first draw holds it on screen (`float_rules.reachable`).
    restored: bool = false,
    landing: ?Landing = null,
    /// Flying shut: drawn as glass only, and dropped when the flight ends.
    closing: bool = false,
    /// Its window's id, once it has drawn: what dvui's subwindow stack knows it by.
    win_id: dvui.Id = .zero,
    /// Its window last frame, physical — what a drag reads occlusion against.
    bounds: dvui.Rect.Physical = .{},
    /// Its header last frame, physical — the handle that moves it. Nothing is aimed at over it.
    header: dvui.Rect.Physical = .{},
    /// Its header's close button last frame, physical: the part of the header that does not move
    /// it — what the OS leaves to the app when it moves a popped-out float's window by its header.
    header_close: dvui.Rect.Physical = .{},
    /// Its title last frame — the view it shows, as its header says (`titleText`): what its OS
    /// window is called, out of the main window.
    title_buf: [96]u8 = undefined,
    title_len: u8 = 0,
    /// A ghost of itself while a view carried out of it is aimed elsewhere (`ViewDrag.ghosted`): 0
    /// itself, 1 its ghost (`ghostLook`), and on to `gone` when it closes as one. As a ghost it
    /// still draws its place — the drag is held by that place's corner button — but nothing of the
    /// live float shows: its photograph is what does.
    aside: Fade = .{},
    /// The float as the drag found it — window, glass, view and shadow — photographed from the
    /// frame at the lift (`liftedFrom`): what fades to the ghost, faint and out of focus, and back
    /// whenever the view is aimed at it again or let go over nothing. A photograph, not the live
    /// float under an alpha: a view may draw in ways no alpha reaches (its own triangles, an alpha
    /// of its own), and none of it may show. Owned; kept while the drag lasts, and dropped once the
    /// float is back for good, or gone.
    aside_photo: ?Photo = null,
    /// The view the drag carries out of it (interned). Still in the float when the drag ends,
    /// the drop was cancelled and the photograph is still a true picture of it; gone, it landed
    /// elsewhere, and the float comes back as it is now.
    aside_view: []const u8 = "",
    /// Out of the main window, in an OS window of its own (`docs/POPOUT_WINDOWS_PLAN.md`); null
    /// while it is in the main window. The application that owns the OS windows sets and clears
    /// it, replays the float's drawing into its window and routes that window's pointer back.
    viewport: ?Viewport = null,

    /// Its title last frame: the view it shows (`title_buf`).
    pub fn titleText(self: *const Float) []const u8 {
        return self.title_buf[0..self.title_len];
    }
};

/// Where a float out of the main window is drawn in the frame. The application chooses it: a
/// part of the frame past the main window's edge, which no pointer over the main window reaches,
/// so the only pointer the float sees is the one translated from its own OS window. Moved and
/// resized there by the user as it would be in the main window, it is `rect` that changes; the
/// float's own `rect` is kept, where it comes back to.
pub const Viewport = struct {
    /// Natural units, in the main window's frame: the float's window rect, as it would be in the
    /// main window. Its OS window is that grown by `outReach`.
    rect: dvui.Rect,
    /// Its OS window shows the desktop through a material behind the glass (vibrancy, Acrylic):
    /// what stands behind the glass (`Popout.backing`) is the main window's base over it, as
    /// translucent as the main window. Without one, that is opaque.
    material: bool = false,
    /// Its OS window is framed by the OS — its corners, shadow and resizing from its edges (macOS's
    /// titled window, DWM on Windows): the window is the float's glass, and the float resizes
    /// nothing itself.
    os_frame: bool = false,
    /// Its OS window has the OS's own buttons for close, minimize and zoom (macOS's traffic lights):
    /// the float's header draws no close button of its own.
    os_buttons: bool = false,
    /// Natural units from its window's left edge past the OS's own buttons (`os_buttons`), this
    /// frame (`Popout`): the part of its header that is theirs, not the float's to be moved by.
    buttons_w: f32 = 0,
    /// The OS asked to close its window (its close button, ⌘W): it closes as from its header.
    close_asked: bool = false,
    /// Physical: from where the float is drawn in its band to where its window is over the main
    /// window's frame, this frame (`Popout`) — for a drag to read the window where it lies over the
    /// main window's places (`ViewDrag.mapOccluders`).
    main_delta: dvui.Point.Physical = .{},
};


/// Out of the main window in an OS window the OS frames (`Viewport.os_frame`).
fn osFramed(f: Float) bool {
    if (f.viewport) |vp| return vp.os_frame;
    return false;
}

/// Out of the main window in an OS window with the OS's own buttons (`Viewport.os_buttons`).
fn osButtons(f: Float) bool {
    if (f.viewport) |vp| return vp.os_buttons;
    return false;
}

/// Natural units a float out of the main window draws past its window rect — its shadow's reach,
/// less the margin its rect already holds — and its OS window holds round it, clear: the float
/// draws the shadow it draws round its glass in the main window, and looks the same in either.
/// Its rect is the same size out as in, so going out and coming back moves it and nothing else.
pub fn outReach() f32 {
    const bs = dialogs.surfaceShadow();
    const shadow = @ceil(bs.fade + @max(@abs(bs.offset.x), @abs(bs.offset.y))) + 1;
    const margin = (core.widgets.FloatingWindowWidget.defaults.margin orelse dvui.Rect{}).x;
    return @max(0, shadow - margin);
}

/// A picture of a float taken from the frame, with a blur of it made the first time it is drawn
/// blurred (`core.anim.Frost`).
pub const Photo = struct {
    texture: dvui.Texture,
    /// Where it was taken, physical: the float's window.
    rect: dvui.Rect.Physical,
    frost: core.anim.Frost = .{},

    fn drop(self: *Photo) void {
        if (dvui.current_window != null) dvui.Texture.destroyLater(self.texture);
        self.frost.drop();
    }
};

/// A value easing to where it is sent, a step of 1 over `aside_ms` (`core.motion`), turning back
/// from wherever it is when sent elsewhere. On a clock its frames step (`core.FrameClock`): the
/// first frames of a float going to its ghost make the photograph's blur, and a long one holds the
/// fade a moment rather than skipping it on.
pub const Fade = struct {
    from: f32 = 0,
    to: f32 = 0,
    clock: core.FrameClock = .{},

    /// Where it is, as of the frame it was last stepped to (`step`).
    pub fn at(self: Fade) f32 {
        const span = @abs(self.to - self.from);
        if (span == 0) return self.to;
        return std.math.lerp(self.from, self.to, self.clock.fraction(core.motion.durationMs(aside_ms) * span));
    }

    /// Move it on to frame time `now`. Once a frame, before it is read or sent anywhere.
    pub fn step(self: *Fade, now: i128) void {
        self.clock.step(now);
    }

    /// Send it toward `to` from where it is, setting off in the frame at `now`.
    pub fn toward(self: *Fade, to: f32, now: i128) void {
        if (self.to == to) return;
        self.from = self.at();
        self.to = to;
        self.clock = .{};
        self.clock.step(now);
    }
};

/// How long a float takes to fade to its ghost for a view carried out of it, and to firm up
/// again, as written: long enough for the defocus to read, short enough that it is out of the way
/// before the drop is aimed.
pub const aside_ms: f32 = 300;

/// A float's ghost: how much of it shows, and how far it is out of focus (0 sharp, 1 its whole
/// frost) — enough to say where it is and that it is coming back, little enough that what it lies
/// over reads through it.
const ghost_alpha: f32 = 0.22;
const ghost_blur: f32 = 0.55;
/// Where `Float.aside` goes for a ghost closing — its last view landed elsewhere: past the ghost,
/// to nothing.
const gone: f32 = 2;

/// How a float looks `v` of the way aside (`Float.aside`): itself at 0, its ghost at 1, nothing
/// at `gone` — how much of it shows, and how far out of focus.
pub fn ghostLook(v: f32) struct { alpha: f32, blur: f32 } {
    const in = smoothstep(std.math.clamp(v, 0, 1));
    const out = smoothstep(std.math.clamp(v - 1, 0, 1));
    return .{
        .alpha = std.math.lerp(1, ghost_alpha, in) * (1 - out),
        .blur = std.math.lerp(0, ghost_blur, in) + (1 - ghost_blur) * out,
    };
}

fn smoothstep(t: f32) f32 {
    return t * t * (3 - 2 * t);
}

/// Bottom to top: the last is the float in front.
items: std.ArrayListUnmanaged(Float) = .empty,
/// The last serial handed out (`Float.serial`).
serial: u64 = 0,

/// The index of the float named `name`, if there is one.
pub fn find(self: *const Floats, name: []const u8) ?usize {
    for (self.items.items, 0..) |f, i| {
        if (std.mem.eql(u8, f.name, name)) return i;
    }
    return null;
}

/// The float whose place `name` is or lies in (`Float 1/r1` is in `Float 1`).
pub fn rootOf(self: *const Floats, name: []const u8) ?[]const u8 {
    for (self.items.items) |f| {
        if (rules.isUnder(name, f.name)) return f.name;
    }
    return null;
}

/// The names in use, for `float_rules.nextName`. Allocated in `arena`.
pub fn names(self: *const Floats, arena: std.mem.Allocator) []const []const u8 {
    const out = arena.alloc([]const u8, self.items.items.len) catch return &.{};
    for (self.items.items, 0..) |f, i| out[i] = f.name;
    return out;
}

/// Add `f` on top of the others, with the next serial.
pub fn add(self: *Floats, gpa: std.mem.Allocator, f: Float) !*Float {
    self.serial += 1;
    var new = f;
    new.serial = self.serial;
    try self.items.append(gpa, new);
    return &self.items.items[self.items.items.len - 1];
}

/// Drop the float at `i`, and the photographs it still held.
pub fn removeAt(self: *Floats, i: usize) void {
    var f = self.items.orderedRemove(i);
    endLanding(&f);
    dropAsidePhoto(&f);
}

fn dropAsidePhoto(f: *Float) void {
    if (f.aside_photo) |*p| p.drop();
    f.aside_photo = null;
}

/// The landing is over: the view is drawn, and the photograph it grew out of is not needed.
pub fn endLanding(f: *Float) void {
    const l = f.landing orelse return;
    if (l.photo) |tex| {
        // Destroyed with the frame — and only in one. With no window (teardown) the GPU is going
        // with the process.
        if (dvui.current_window != null) dvui.Texture.destroyLater(tex);
    }
    f.landing = null;
}

/// Every float gone — Reset Layout.
pub fn clear(self: *Floats) void {
    for (self.items.items) |*f| {
        endLanding(f);
        dropAsidePhoto(f);
    }
    self.items.clearRetainingCapacity();
}

pub fn deinit(self: *Floats, gpa: std.mem.Allocator) void {
    self.clear();
    self.items.deinit(gpa);
    self.items = .empty;
}

/// `items` reordered to `order` (`float_rules.stackOrder`): `order[i]` is the index of the float
/// that goes `i`th from the bottom.
pub fn reorder(self: *Floats, order: []const usize) void {
    var buf: [max]Float = undefined;
    const n = @min(order.len, max, self.items.items.len);
    for (order[0..n], 0..) |from, i| buf[i] = self.items.items[from];
    @memcpy(self.items.items[0..n], buf[0..n]);
}

/// More floats than this and the newest stop stacking with the rest; a layout holding this many
/// windows over itself has bigger problems.
pub const max = 32;

/// A rect as `float_rules` takes it.
pub fn toRules(r: anytype) rules.Rect {
    return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
}

pub fn fromRules(r: rules.Rect) dvui.Rect {
    return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
}

// ── Its ghost ───────────────────────────────────────────────────────────────────────────────────

/// A drag has just lifted `view` out of place `place`. When that place is a float's (or a split
/// of one), photograph the float now, while the frame it was last drawn in shows it whole and
/// nothing of the drag yet lies over it: the photograph is what fades to its ghost (`draw`).
pub fn liftedFrom(l: *Layout, place: []const u8, view: []const u8) void {
    const root = l.state.floatRoot(place) orelse return;
    const i = l.state.floats.find(root) orelse return;
    const f = &l.state.floats.items.items[i];
    if (f.closing or f.viewport != null or f.bounds.w <= 0 or f.bounds.h <= 0) return;
    dropAsidePhoto(f);
    f.aside_view = l.state.internName(l.gpa, view);
    // The window alone: its shadow is drawn round the photograph as it goes (`drawAsidePhoto`), so
    // nothing square of what was round it is in the picture to blur in.
    const r = f.bounds.intersect(dvui.windowRectPixels());
    // No picture where the frame cannot be read (no targets; the web before a frame is read): the
    // live float fades instead (`draw`).
    if (core.FrameTarget.snapshot(r)) |tex| f.aside_photo = .{ .texture = tex, .rect = r };
}

/// The photograph of a float fading to its ghost, `blur` of the way to its frost and at `alpha`, in
/// the window's own rounded shape with its shadow round it fading too. As `core.anim.blit` mixes
/// a snapshot with its frost — the sharp picture over the frost, at what makes the two `alpha` of
/// the mix between them — but cut to the window's corners, so the defocus stays the window's.
fn drawAsidePhoto(photo: *Photo, blur: f32, alpha: f32) void {
    const a = std.math.clamp(alpha, 0, 1);
    if (a <= 0.001) return;
    const scale = dvui.currentWindow().natural_scale;
    const theme = dvui.themeGet();
    const corners = dialogs.surfaceCorners().finalize(&theme);
    {
        // Round the window, outside the clip the window keeps to.
        const bs = dialogs.surfaceShadow();
        const reach = (bs.fade + @max(@abs(bs.offset.x), @abs(bs.offset.y))) * scale + 1;
        const prev_clip = dvui.clipGet();
        defer dvui.clipSet(prev_clip);
        dvui.clipSet(photo.rect.outsetAll(reach).intersect(dvui.windowRectPixels()));
        dialogs.glassShadow(photo.rect, corners, scale, bs, a);
    }
    const prev_clip = dvui.clipGet();
    defer dvui.clipSet(prev_clip);
    dvui.clipSet(photo.rect.intersect(dvui.windowRectPixels()));
    const m = std.math.clamp(blur, 0, 1);
    if (m > 0.001) photo.frost.prepare(photo.texture);
    const frost_tex: ?dvui.Texture = if (m > 0.001) photo.frost.texture else null;
    const sharp_a = if (frost_tex != null) a * (1 - m) else a;
    const frost_a = if (sharp_a >= 0.999) 0 else a * m / (1 - sharp_a);
    const rs: dvui.RectScale = .{ .r = photo.rect, .s = scale };
    if (frost_tex) |f| if (frost_a > 0.001) {
        dvui.renderTexture(f, rs, .{ .corners = corners, .colormod = dvui.Color.white.opacity(frost_a) }) catch {};
    };
    if (sharp_a > 0.001) dvui.renderTexture(photo.texture, rs, .{ .corners = corners, .colormod = dvui.Color.white.opacity(sharp_a) }) catch {};
}

/// Whether one of float `name`'s places holds `view`.
fn holdsView(l: *Layout, name: []const u8, view: []const u8) bool {
    if (view.len == 0) return false;
    for (l.state.splits.leavesUnder(l.arena, name)) |leaf| {
        const ids = l.state.assignment(leaf) orelse continue;
        for (ids) |id| if (std.mem.eql(u8, id, view)) return true;
    }
    return false;
}

// ── Closing ─────────────────────────────────────────────────────────────────────────────────────

pub const Closing = enum {
    /// Its last view left it: there is nothing to send anywhere.
    emptied,
    /// The user closed it: every view in it goes back to the place it floated out of.
    home,
};

/// Close float `name`: its views go home (`how`), every place a split of it made goes with it,
/// and its window flies shut into its middle as a dialog's does (`core.dialogs.dialogWindow`),
/// drawn as glass alone until it lands (`draw`).
pub fn close(l: *Layout, name: []const u8, how: Closing) void {
    const state = l.state;
    const i = state.floats.find(name) orelse return;
    if (state.floats.items.items[i].closing) return;
    const home = state.floats.items.items[i].home;
    const leaves = state.splits.leavesUnder(l.arena, name);
    if (how == .home) ViewDrag.sendHome(l, leaves, home);
    for (leaves) |leaf| {
        if (state.forgetPlace(l.gpa, leaf)) l.extents_changed = true;
    }
    state.splits.forget(l.gpa, name);
    const f = &state.floats.items.items[i];
    endLanding(f);
    // Marked, not removed: `draw` may be walking the list, and drops it when it comes to it —
    // at once if it never drew a window or was a ghost, after the flight shut if it did.
    f.closing = true;
    // Out of the main window, its OS window just goes, as any window does when closed: the
    // fly-shut is the main window's picture of a window closing in it.
    const out = f.viewport != null;
    if (!out and f.win_id != .zero and f.bounds.w > 0 and f.aside.to == 0) {
        var to = f.bounds;
        to.x = to.center().x;
        to.y = to.center().y;
        to.w = 1;
        to.h = 1;
        dvui.dataSet(null, f.win_id, "_close_rect", to);
    }
    state.markDirty();
    dvui.refresh(null, @src(), null);
}

// ── Drawing ─────────────────────────────────────────────────────────────────────────────────────

/// How long a float takes to grow out of the carried glass into its window, as written — the
/// card's own change of shape (`ViewDrag.morphProgress`) and a dialog's open.
const landing_ms: f32 = 300;
/// How opaque the landing photograph is at its start — the carried card's own (`ViewDrag`).
const photo_opacity: f32 = 0.8;

/// How far a landing has got in time: 0 at the release, 1 in its window.
pub fn landingFraction(land: Landing) f32 {
    return std.math.clamp(land.clock.fraction(core.motion.durationMs(landing_ms)), 0, 1);
}

/// `landingFraction` on the arrival curve, past 1 and back on the way when motion is playful.
pub fn landedAt(land: Landing) f32 {
    const frac = land.clock.fraction(core.motion.durationMs(landing_ms));
    return if (frac >= 1) 1 else core.motion.enter(frac);
}

/// Draw every float, bottom to top: each a glass window holding its place. Called by the
/// application after its shape has run and before it publishes the shape's regions, from the
/// base window (`Layout.drawFloats`), so a float's places register this frame like any other's
/// — each stamped with its float's layer, the `n`th from the bottom being `n`.
pub fn draw(l: *Layout) void {
    const floats = &l.state.floats;
    if (floats.items.items.len == 0) return;
    syncStack(l);
    defer l.state.layer_building = 0;
    // By index, re-read after each draw: a view floated out of one adds a float at the end (and
    // may move the list), and one done flying shut goes from where it is.
    var i: usize = 0;
    while (i < floats.items.items.len) {
        l.state.layer_building = @intCast(i + 1);
        if (drawOne(l, i)) i += 1 else floats.removeAt(i);
    }
}

/// The floats in the order dvui stacks their windows: a press raises one there
/// (`float_rules.stackOrder`).
fn syncStack(l: *Layout) void {
    const floats = &l.state.floats;
    const n = @min(floats.items.items.len, max);
    var ids: [max]u64 = undefined;
    for (floats.items.items[0..n], 0..) |f, i| ids[i] = @intFromEnum(f.win_id);
    const stack = dvui.currentWindow().subwindows.stack.items;
    const stack_ids = l.arena.alloc(u64, stack.len) catch return;
    for (stack, 0..) |sw, i| stack_ids[i] = @intFromEnum(sw.id);
    var order: [max]usize = undefined;
    rules.stackOrder(order[0..n], ids[0..n], stack_ids);
    floats.reorder(order[0..n]);
}

/// Draw the float at `i`. False when it is gone: flown shut, or closed before it ever drew.
fn drawOne(l: *Layout, i: usize) bool {
    const state = l.state;
    const cw = dvui.currentWindow();
    const now = cw.frame_time_ns;
    const scale = cw.natural_scale;
    if (state.floats.items.items[i].closing and state.floats.items.items[i].win_id == .zero) return false;
    // Not drawn before: made this frame by a release inside the place it left, which has drawn
    // that view already this frame — or brought back from a saved layout before any place has
    // said it is not theirs. Its place goes in the registry, so from the next frame it claims the
    // view away from where it was; the view in it starts then. Drawn now, the view would be drawn
    // twice in one frame.
    var fresh = false;
    if (state.floats.items.items[i].fresh) {
        const f = &state.floats.items.items[i];
        f.fresh = false;
        if (f.restored) {
            f.rect = fromRules(rules.reachable(toRules(f.rect), toRules(dvui.windowRect())));
            f.restored = false;
        }
        if (f.closing) return false;
        state.registerRegion(l.gpa, .{
            .name = f.name,
            .keywords = Layout.slot_keywords,
            .shows = .many,
            .by_name = true,
        });
        // Brought back, its window starts with its view, next frame. Landing, its window is the
        // carried glass from this frame on — glass and photograph, the view not yet — so the drop
        // let go never leaves a frame with nothing where it was. And the window's own first frame,
        // which lays its header out from nothing and makes its glass, is this one, not one of the
        // landing's.
        if (f.landing == null) return true;
        fresh = true;
    }
    // A ghost while a view carried out of it is aimed elsewhere: the drop is aimed at what it lies
    // over. Itself again when the view is aimed back over it, and when the drag ends.
    const carried_out = ViewDrag.carriedOutOf(l, state.floats.items.items[i].name);
    const ghosted = carried_out and !ViewDrag.settleGhost(state);
    {
        const f = &state.floats.items.items[i];
        f.aside.step(now);
        if (f.landing) |*land| land.clock.step(now);
        if (!f.closing) {
            f.aside.toward(if (ghosted) 1 else 0, now);
            // The drag is over and the view is not in it any more — it landed elsewhere: the
            // photograph is of what the float was, so it comes back as it is now, the live float
            // fading in.
            if (!carried_out and f.aside_photo != null and !holdsView(l, f.name, f.aside_view)) dropAsidePhoto(f);
        } else if (f.aside.to > 0 or f.aside.at() > 0.01) {
            // Closing as a ghost — its last view landed elsewhere: what is left of it finishes
            // going, then so does it, with no flight shut.
            f.aside.toward(gone, now);
        }
    }
    const first = state.floats.items.items[i];
    const aside = first.aside.at();
    if (aside != first.aside.to) dvui.refresh(null, @src(), null);
    const closing_aside = first.closing and first.aside.to > 0;
    if (closing_aside and (first.aside_photo == null or aside >= gone)) return false;
    // A ghost, on its way to or from one, or going: its photograph is what shows, and nothing of
    // the live float. By where it is heading as well as where it is — the frame it sets off it
    // has not moved yet.
    const stepping = first.aside.to > 0 or aside > 0;
    const as_photo = first.aside_photo != null and (closing_aside or stepping);
    // Back for good: the live float again. Not while the drag is on — it may go back to its ghost.
    if (!as_photo and first.aside_photo != null and !carried_out) dropAsidePhoto(&state.floats.items.items[i]);
    // With no photograph it is the live float that fades to its ghost — its view whole, where it
    // can be drawn into a picture of itself (`Whole`), though not out of focus — and gone, nothing
    // of it shows.
    // In an OS window of its own, the window fades whole, its material and all (`Popout`): its
    // content stays as it is in it.
    const shown = if (as_photo or first.viewport != null) 1 else ghostLook(aside).alpha;
    const hide_live = as_photo or aside >= gone;

    // Out of the main window it is wherever its OS window's part of the frame is. It lands there
    // too, but the landing is its window's (`Popout`): the carried glass grows into the window, which
    // shows once it has, the float in it drawn whole all along.
    const out = first.viewport != null;
    // Where the window is this frame: on its way out of the carried glass, or where it was left.
    var rect = if (first.viewport) |vp| vp.rect else first.rect;
    var corner_r = core.corners.scaled(core.corners.surface);
    var landed: f32 = 1;
    if (state.floats.items.items[i].landing) |land| {
        if (!out) {
            landed = landedAt(land);
            const from = land.from.toNatural();
            rect = fromRules(rules.lerp(toRules(from), toRules(first.rect), landed));
            corner_r = std.math.lerp(land.radius / scale, corner_r, std.math.clamp(landed, 0, 1));
        }
        if (land.clock.fraction(core.motion.durationMs(landing_ms)) >= 1) endLanding(&state.floats.items.items[i]) else dvui.refresh(null, @src(), null);
    }
    const landing = state.floats.items.items[i].landing != null and !out;

    // The carried drop was glass already: the window takes over from it, whole, rather than
    // forming a second time. Fading to its ghost under its alpha, the glass dissolves as a closing
    // window's does; as a photograph, the window draws no glass at all.
    // In an OS window the OS frames (`Viewport.os_frame`), it is a window as the main window is,
    // drawn as it is: no glass and no shadow of its own — the window's base stands under it, its
    // chrome at the window's opacity over the window's material (`Popout.backing`), and the OS
    // draws the shadow. Imitating a glass window in the main window out there, its frost had to read
    // the main window's picture behind it, which the OS moves the window over faster than fizzy can
    // draw it: the blur trailed the window, and its rim streaked. Out of the main window in a window
    // the float frames itself (X11), its shadow is in the clear margin round it (`outReach`), its
    // glass over the base.
    const plain = osFramed(first);
    var frost = if (as_photo or plain) null else dialogs.dialogFrost();
    if (frost) |*fr| {
        fr.form = shown;
        // Landing, it grows into its window — past it and back, when motion is playful — and its
        // glass is captured that size from the start.
        if (landing) {
            const grown = scale * (1 + core.motion.overshoot_max);
            fr.reach = .{ .w = first.rect.w * grown, .h = first.rect.h * grown };
        }
    }
    var shadow = dialogs.surfaceShadow();
    shadow.alpha *= shown;
    // Everything else the window draws — its fill, header, the view — fades with it.
    const prev_alpha_window = dvui.alpha(shown);
    defer dvui.alphaSet(prev_alpha_window);
    // Held by the pointer as the frame begins: the user is moving or resizing it. Read before the
    // window runs, because it lets go of the pointer on the release while it handles its events —
    // a last move and the release in one frame would otherwise read as not held, and snap back.
    const held_before = first.win_id != .zero and dvui.captured(first.win_id);
    var win_rect = rect;
    // One window, one header and one place, whatever it is showing — the same widgets, so the
    // float keeps its place among the others and its view keeps its state through a drag.
    var win = core.widgets.floatingWindow(@src(), .{
        .rect = &win_rect,
        .placed = true,
        .resize = if (landing or first.closing or aside > 0 or osFramed(first)) .none else .all,
        .window_avoid = .none,
        .frost = frost,
        .detached = out,
        .detached_reach = if (out) outReach() else 0,
    }, .{
        .id_extra = @intCast(first.serial),
        .corners = if (landing) dvui.CornerRect.all(corner_r) else dialogs.surfaceCorners(),
        .box_shadow = if (as_photo or plain) null else shadow,
        .background = !as_photo and !plain,
        .color_fill = .{ .color = dialogs.dialogFill() },
        .border = .all(0),
    });
    const win_id = win.data().id;
    const bounds = win.data().rectScale().r;

    if (as_photo) {
        // Out of focus as it fades to its ghost, over what it lies in front of.
        const look = ghostLook(aside);
        drawAsidePhoto(&state.floats.items.items[i].aside_photo.?, look.blur, look.alpha);
    }

    // Flying shut: the glass alone, gone when it lands — or, a ghost, its photograph alone.
    if (first.closing) {
        const flown = if (dvui.animationGet(win_id, "_close_x")) |a| a.done() else true;
        // Out of the main window, its OS window shuts with it, placed from its rect as ever
        // (`Popout`): kept at the size it had, the glass shrank inside a window whose material, base
        // and the hole under it in the main window stood still until it went.
        if (out) state.floats.items.items[i].bounds = bounds;
        win.deinit();
        return as_photo or !flown;
    }

    // A press anywhere in it brings it to the front, as a press on an OS window does; dvui
    // raises a window only from its header.
    if (!hide_live) for (dvui.events()) |*e| {
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        if (me.action != .press or !me.button.pointer()) continue;
        if (dvui.eventMatch(e, .{ .id = win_id, .r = bounds })) dvui.raiseSubwindow(win_id);
    };

    // A ghost, its header and place are drawn as ever — the place's corner button holds the drag —
    // but clipped to nothing, so nothing of them shows however the view draws. Fresh, the header
    // too — laid out, for the next frame to draw it where it goes — and the place not at all.
    const prev_clip_live = dvui.clipGet();
    if (hide_live or fresh) dvui.clipSet(.{});
    var open = true;
    const title = if (ViewDrag.visibleId(l, first.name)) |id| (if (l.host.surfaceById(id)) |s| s.title else first.name) else first.name;
    // Its OS window's own buttons close it out of the main window (macOS's traffic lights): no
    // close button of its own beside them.
    const header = dialogs.windowHeader(title, "", if (osButtons(first)) null else &open, .none);
    const header_close = dialogs.windowHeaderCloseRect();
    // For demo tapes (`docs/AUTOMATION.md`): its header, to move it by, and its close button.
    core.anchor.markRect(win_id, header, true, "float-header:{s}", .{first.name});
    if (header_close) |r| core.anchor.markRect(win_id, r, true, "float-close:{s}", .{first.name});
    // Moved by its header only: the rest is the view's. Not while it lands — it is going where
    // the drop put it — nor while it is out of the way. Not over its OS window's own buttons
    // either, which are theirs: the move cursor showed over the traffic lights.
    const buttons_w = if (first.viewport) |vp| (if (vp.os_buttons) vp.buttons_w * scale else 0) else 0;
    const drag_area: dvui.Rect.Physical = .{ .x = header.x + buttons_w, .y = header.y, .w = @max(0, header.w - buttons_w), .h = header.h };
    win.dragAreaSet(if (landing or aside > 0) .{} else drag_area);

    if (!fresh) {
        // The view fades with the window round it: in over the photograph it grew out of as it
        // lands; in when the float comes back from a drag without the view that landed
        // elsewhere; out when it fades to its ghost with no photograph to fade as. It fades
        // whole — drawn into a picture of itself, laid down at the fade (`Whole`) — since a view
        // may draw where no alpha reaches (the workbench's home page sets its own; a view drawing
        // its own triangles is handed alpha to apply itself), and under an alpha alone that much
        // of it was there at once, ahead of its window. With nothing to draw into (no targets, a
        // frame nobody sees) it fades under its alpha.
        const view_fade = std.math.clamp(landed, 0, 1);
        const top = header.y + header.h;
        const body: dvui.Rect.Physical = .{ .x = bounds.x, .y = top, .w = bounds.w, .h = @max(0, bounds.y + bounds.h - top) };
        var whole: ?Whole = if (!hide_live and view_fade * shown < 1) Whole.begin(body.intersect(dvui.clipGet())) else null;
        // Drawn into the picture as it is when whole; the picture takes the fade.
        const prev_alpha = if (whole != null) dvui.alpha(1) else dvui.alpha(view_fade);
        if (whole != null) dvui.alphaSet(1);
        // Inset from the glass's sides and foot by its corner radius, as a place's card insets
        // its view: a view that draws to its edges — a document's canvas and rulers — would
        // otherwise run flush to the glass and under its rounded corners. The header is its top.
        const inset = core.corners.scaled(core.corners.surface);
        var region = l.region(@src(), .{
            .name = first.name,
            .keywords = Layout.slot_keywords,
            .by_name = true,
            .shows = .many,
        }, .{ .expand = .both, .padding = .{ .x = inset, .w = inset, .h = inset } }) catch null;
        if (region) |*r| r.deinit();
        dvui.alphaSet(prev_alpha);
        if (whole) |*w| w.end(view_fade);
    }
    dvui.clipSet(prev_clip_live);
    if (landing) if (state.floats.items.items[i].landing) |land| {
        if (land.photo) |tex| drawPhoto(tex, land.photo_size, bounds, header, corner_r * scale, 1 - std.math.clamp(landed, 0, 1));
    };
    // Or taken hold of this frame (a press lands in `deinit`; anything it moves is next frame's).
    const held = held_before or dvui.captured(win_id);
    win.deinit();

    // Contents may have added a float, moving the list: read this one again.
    const f = &state.floats.items.items[i];
    f.win_id = win_id;
    f.bounds = bounds;
    f.header = header;
    f.header_close = header_close orelse .{};
    const kept = title[0..@min(title.len, f.title_buf.len)];
    @memcpy(f.title_buf[0..kept.len], kept);
    f.title_len = @intCast(kept.len);
    const asked = if (f.viewport) |vp| vp.close_asked else false;
    if (!open or asked) {
        close(l, f.name, .home);
        return true;
    }
    // Out of the main window, moved or resized: that is its OS window's, which follows it, and
    // nothing the layout keeps.
    if (f.viewport) |*vp| {
        if (held and !f.closing and !win_rect.equals(vp.rect)) vp.rect = fromRules(rules.resized(toRules(win_rect)));
        return true;
    }
    // Moved or resized by the user: remember where, no smaller than a float may be. Only theirs —
    // the window holds a float on screen when it shrinks (`FloatingWindowWidget`), and that is
    // shown, not kept, so the float is back where they left it when the window grows again.
    if (held and !landing and !f.closing and !win_rect.equals(f.rect)) {
        f.rect = fromRules(rules.resized(toRules(win_rect)));
        state.markDirty();
    }
    return true;
}

/// A float's view drawn into a picture of itself while it fades (`drawOne`): laid down at the
/// fade, it fades whole, however the view draws.
const Whole = struct {
    pic: dvui.Picture,

    /// Draw into a picture of `r`, physical, from here. Null where there is nothing to draw into
    /// (`core.anim.CrossFade.beginCapture`: no texture targets, nothing in `r`, a frame nobody
    /// sees).
    fn begin(r: dvui.Rect.Physical) ?Whole {
        return .{ .pic = core.anim.CrossFade.beginCapture(r) orelse return null };
    }

    /// Stop drawing into it, and lay it down where it was drawn, at `opacity` under the alpha in
    /// effect.
    fn end(self: *Whole, opacity: f32) void {
        self.pic.stop();
        const tex = dvui.textureFromTarget(self.pic.texture) catch return;
        const rs: dvui.RectScale = .{ .r = self.pic.r, .s = dvui.currentWindow().natural_scale };
        dvui.renderTexture(tex, rs, .{ .colormod = dvui.Color.white.opacity(opacity) }) catch {};
        dvui.Texture.destroyLater(tex);
    }
};

/// The photograph the float grew out of, over its body (below `header`), cropped to fill it, at
/// `fade` of its carried opacity — in its window, or the carried glass its OS window grows out of
/// (`Popout`). `radius` is physical.
pub fn drawPhoto(tex: dvui.Texture, size: dvui.Size.Physical, bounds: dvui.Rect.Physical, header: dvui.Rect.Physical, radius: f32, fade: f32) void {
    if (fade <= 0.01) return;
    const top = header.y + header.h;
    const r: dvui.Rect.Physical = .{ .x = bounds.x, .y = top, .w = bounds.w, .h = bounds.y + bounds.h - top };
    if (r.w < 2 or r.h < 2) return;
    var uv: dvui.Rect = .{ .x = 0, .y = 0, .w = 1, .h = 1 };
    if (size.w > 0 and size.h > 0) {
        const a_img = size.w / size.h;
        const a_box = r.w / r.h;
        if (a_img > a_box) {
            uv.w = a_box / a_img;
            uv.x = (1 - uv.w) / 2;
        } else {
            uv.h = a_img / a_box;
            uv.y = (1 - uv.h) / 2;
        }
    }
    const scale = dvui.currentWindow().natural_scale;
    dvui.renderTexture(tex, .{ .r = r, .s = scale }, .{
        .corners = .round(radius / scale),
        .colormod = dvui.Color.white.opacity(photo_opacity * fade),
        .uv = uv,
    }) catch {};
}
