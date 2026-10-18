//! dvui's floating windows on this backend — `dvui.osWindow`'s too, as this backend makes no
//! `dvui.Window` of its own for one — each in the one frame, shown in an OS window of its own
//! (`viewports`): the OS's own title bar — the window's title, its buttons, moving, resizing, full
//! screen — in the theme's colour, and the floating window's content below it (`Frame.native`).
//! The app writes plain dvui; on a backend without OS windows, or past `max_outs`, the same
//! floating window stays in the main window, with dvui's own header and close button. Modal
//! dialogs stay in the window they are over.
//!
//! dvui asks as each begins whether it is in an OS window (`named`, from
//! `SDLBackend.floatingWindowOs`), and its `windowHeader` hands that window its title (`titled`).
//! The window the OS makes key is the one dvui's keyboard goes to (`beforeFrame`). Around the
//! app's frame (`SDLBackend.appIterate`, or an app's own loop):
//!
//! - `beforeFrame`: each floating window takes its window's place and size, the OS's to change —
//!   moved, resized, zoomed, full screen — never the other way, and each window's band is a screen
//!   of dvui's (`dvui.screensSet`), so dvui keeps what opens in it there;
//! - `afterFrame`: dvui's dialogs and toasts made (`Window.drawRetained`); a window whose floating
//!   window was not drawn — closed — goes; each one named and not yet in a window gets one over
//!   where it is (`viewports.open`), drawn in that window's band from the next frame; and each
//!   window is handed its picture: every subwindow in its band, taken out of the frame
//!   (`viewports.Picture`). The OS's close clears the app's `open_flag`, as dvui's close button
//!   would.
//!
//! dvui keeps where each floating window is (`_rect` in its data, by its id): set each frame to its
//! window's part of the frame, in that window's band.
const std = @import("std");
const dvui = @import("dvui");
const viewports = @import("viewports.zig");

/// As many as there are viewports. Past that, a floating window stays in the main window.
const max_outs = 8;

/// A floating window in an OS window of its own, by its dvui id.
const Out = struct {
    id: dvui.Id,
    viewport: *viewports.Viewport,
    target: ?dvui.Texture.Target = null,
    /// Opened this frame: drawn in the main window still, in its band from the next.
    fresh: bool = true,
    /// Its window's title, and least and most size (natural), as last given it.
    title: [64:0]u8 = @splat(0),
    min: dvui.Size = .{},
    max: dvui.Size = .{},
};
var outs: [max_outs]?Out = @splat(null);

/// The floating windows dvui named as OS windows this frame (`named`), with their titles
/// (`titled`), the flags their windows' close clears, and their least and most sizes.
const Named = struct {
    id: dvui.Id,
    title: [64:0]u8 = @splat(0),
    open_flag: ?*bool,
    min: dvui.Size,
    max: dvui.Size,
    shown: bool = false,
    /// Drawn as an OS window's, without dvui's frame or header, but no window opened for it yet:
    /// one being torn off (`frameless`).
    hold: bool = false,
};
var named_list: [max_outs]Named = undefined;
var named_n: usize = 0;

/// The floating window that has the keyboard, as last read from the OS's key window: null for the
/// main window's own subwindow.
var keyed: ?dvui.Id = null;

/// A floating window dragged by its header past every window of the app's (`tearFrame`) becomes a
/// small card of itself at the pointer, in a carry window (`viewports.openCarry`): its header gone,
/// its content live. Let go over the desktop, the card grows to its window's size where it opens,
/// a title bar's place opening at its top (`Grow`), and it is in an OS window of its own there
/// (`torn`), its content under the OS's title bar where the card's was. Moved by the OS wholly back
/// into the main window, the window shrinks into its place there, dvui's header for the OS's title
/// bar (`Merge`). A card, not the floating window at its size made up as an OS window: it never
/// could look like one, and became one with a jump; a card that changes into the window is a change
/// it shows (the user). dvui says nothing of a drag, so it is read from what dvui shows: the
/// floating window that has the mouse, its rect moving while its size stays — moved by its header,
/// not resized from an edge. Over another of the app's windows the held pointer already takes it
/// into that window (`SDLBackend.heldPoint`).
const Tear = struct {
    id: dvui.Id,
    /// Where on it the pointer took it, from its top left (physical, at its size).
    grab: dvui.Point.Physical,
    /// Its rect last frame (physical): moved at the same size, it is being moved.
    last: dvui.Rect.Physical,
    moving: bool = false,
    /// When it went past the app's windows: drawn without its header from the frame after
    /// (`frameless`), and shrinking into the card from then (`shrink_ns`).
    out_ns: ?i128 = null,
    /// Its picture this frame, at its size, without its header: what the card shows.
    live: ?dvui.Texture.Target = null,
    card: ?*viewports.Viewport = null,
    card_target: ?dvui.Texture.Target = null,
    /// The card this frame, in the main window's frame (physical); null over a window of the app's.
    place: ?dvui.Rect.Physical = null,
    /// The app's window it was last over, brought forward as it came over it.
    over: ?*anyopaque = null,
};
var tear: ?Tear = null;

/// The floating window drawn without its header — as an OS window's is — though it has no window
/// yet (`named`, `titled`): the one being torn off, past the app's windows or growing into its own.
var frameless: ?dvui.Id = null;

/// Whether floating window `id` is drawn without its header though it has no window yet
/// (`frameless`): `SDLBackend.floatingWindowOs` answers for it as for an OS window's.
pub fn heldFrameless(id: dvui.Id) bool {
    return frameless == id;
}

/// The card growing into the window let go over the desktop (`tearFrame`): from where it was to the
/// window's frame, a title bar's place opening at its top, the window asked for as it gets there,
/// and the card gone once that window shows.
const Grow = struct {
    id: dvui.Id,
    card: *viewports.Viewport,
    card_target: ?dvui.Texture.Target,
    live: ?dvui.Texture.Target,
    from: dvui.Rect.Physical,
    /// The window's frame (physical): its title bar's band over its content.
    to: dvui.Rect.Physical,
    band: f32,
    start_ns: i128,
    /// The window asked for (`tearOff`), once the card has grown.
    asked: bool = false,
};
var grow: ?Grow = null;

/// A torn-off window moved wholly back into the main window (`beforeFrame`): its last picture
/// shrinking from the window's frame to the floating window's place, the OS's title bar's band
/// becoming dvui's header's, then the floating window there.
const Merge = struct {
    id: dvui.Id,
    card: *viewports.Viewport,
    card_target: ?dvui.Texture.Target = null,
    snap: dvui.Texture.Target,
    from: dvui.Rect.Physical,
    band: f32,
    to: dvui.Rect.Physical,
    header: f32,
    start_ns: i128,
};
var merge: ?Merge = null;

/// How long the card takes to grow into its window, or a window to shrink back into the main one,
/// and the floating window to shrink into the card as it goes past the app's windows.
const grow_ns: i128 = 200 * std.time.ns_per_ms;
const shrink_ns: i128 = 150 * std.time.ns_per_ms;
/// The card: half its window's size, and no wider than this (natural).
const card_scale: f32 = 0.5;
const card_max_w: f32 = 360;

/// The height of dvui's header (`dvui.windowHeader`: the heading font's line and its padding),
/// physical: what the OS's title bar takes the place of.
fn headerHeight() f32 {
    return (dvui.Font.theme(.heading).lineHeight() + 10) * dvui.windowNaturalScale();
}

/// Torn off the window it was in by a drop over no window (`tearFrame`): shown in an OS window
/// though it did not ask (`SDLBackend.floatingWindowOs`), opened where it was let go (`at`, once).
/// Its window closed, it is an ordinary floating window again.
const Torn = struct { id: dvui.Id, at: ?dvui.Rect.Physical };
var torn_list: [max_outs]?Torn = @splat(null);

/// Whether floating window `id` was torn off into an OS window of its own (`tearFrame`).
pub fn torn(id: dvui.Id) bool {
    for (torn_list) |slot| if (slot) |t| if (t.id == id) return true;
    return false;
}

/// A window failed to open (no viewport left, or the OS refused one): none is promised (`named`)
/// until one closes. Promised and never opened, a floating window stayed frameless in the main
/// window, unmovable and unclosable.
var open_failed = false;

/// Floating window `id` begins: whether it is shown in an OS window of its own — it has one, or one
/// can open for it — so dvui draws it without a frame of its own. Its window sized by the OS no
/// smaller than `min` and no larger than `max` (natural).
pub fn named(id: dvui.Id, open_flag: ?*bool, min: dvui.Size, max: dvui.Size) bool {
    if (named_n == named_list.len) return false;
    // An OS window has a close button, and only `open_flag` closes a floating window: one without
    // stays in the main window, where dvui gives it no close button either.
    if (open_flag == null) return false;
    // One that will open: room in `outs` past those already asked for this frame, and viewports.
    var free: usize = 0;
    for (outs) |slot| free += @intFromBool(slot == null);
    var waiting: usize = 0;
    for (named_list[0..named_n]) |w| waiting += @intFromBool(w.shown and outOf(w.id) == null);
    // Being torn off: as an OS window's, though none opens for it until it is let go (`frameless`).
    const hold = frameless == id and outOf(id) == null and !torn(id);
    const shown = hold or outOf(id) != null or (viewports.available() and !open_failed and waiting < free);
    named_list[named_n] = .{ .id = id, .open_flag = open_flag, .min = min, .max = max, .shown = shown, .hold = hold };
    named_n += 1;
    return shown;
}

/// `windowHeader` in floating window `id`: its title, for its OS window's title bar. Whether it has
/// one (`named`), and the header draws nothing.
pub fn titled(id: dvui.Id, header: []const u8) bool {
    for (named_list[0..named_n]) |*w| if (w.id == id) {
        // Cut at a character, never inside one: the OS takes the title as UTF-8.
        var len = @min(header.len, w.title.len - 1);
        while (len > 0 and len < header.len and header[len] & 0xC0 == 0x80) len -= 1;
        @memcpy(w.title[0..len], header[0..len]);
        w.title[len] = 0;
        return w.shown;
    };
    return false;
}

fn natural(r: viewports.Rect, s: f32) dvui.Rect {
    return .{ .x = r.x / s, .y = r.y / s, .w = r.w / s, .h = r.h / s };
}

fn physical(r: dvui.Rect, s: f32) viewports.Rect {
    return .{ .x = r.x * s, .y = r.y * s, .w = r.w * s, .h = r.h * s };
}

/// After `dvui.Window.begin`, before the app's frame.
pub fn beforeFrame() void {
    named_n = 0;
    const s = dvui.windowNaturalScale();
    for (&outs) |*slot| {
        const o = if (slot.*) |*o| o else continue;
        // Where its window is, and its size: the OS's — moved, resized, zoomed, full screen — and
        // never the other way. Not grown to fit what it holds, as dvui sizes a floating window
        // while its content changes (`_auto_size`).
        _ = viewports.osPlaced(o.viewport);
        // Torn off, and moved by the OS wholly into the main window: back in it, where it was let
        // go, as a floating window of its own again (`torn`). Wholly, so a window only overlapping
        // the main one stays a window.
        if (viewports.osMoveEnded(o.viewport)) |end| if (!end.resized and torn(o.id) and viewports.mainHolds(o.viewport)) {
            const content = viewports.inMain(o.viewport);
            dvui.dataSet(null, o.id, "_rect", natural(content, s));
            for (&torn_list) |*ts| if (ts.*) |tt| if (tt.id == o.id) {
                ts.* = null;
            };
            // Shrinking into its place from its window, its last picture in a card over it
            // (`Merge`); or there at once where no card can be made.
            const band = viewports.titleBand();
            const c: dvui.Rect.Physical = .{ .x = content.x, .y = content.y, .w = content.w, .h = content.h };
            const from: dvui.Rect.Physical = .{ .x = c.x, .y = c.y - band, .w = c.w, .h = c.h + band };
            if (merge == null and o.target != null and viewports.tears()) if (viewports.openCarry(viewRect(from))) |card| {
                merge = .{ .id = o.id, .card = card, .snap = o.target.?, .from = from, .band = band, .to = c, .header = headerHeight(), .start_ns = dvui.currentWindow().frame_time_ns };
                o.target = null;
            };
            viewports.close(o.viewport);
            if (o.target) |t| t.destroyLater();
            slot.* = null;
            open_failed = false;
            dvui.refresh(null, @src(), null);
            continue;
        };
        dvui.dataSet(null, o.id, "_rect", natural(viewports.frameOf(o.viewport), s));
        dvui.dataSet(null, o.id, "_auto_size", false);
    }
    viewports.publishScreens(park(s));
    // The OS made another window key — clicked, or opened — so dvui's keyboard goes there: to its
    // floating window, or the main window's own subwindow. Only as the key window changes, so a
    // click in the main window that focuses one of its own floating windows stands.
    if (viewports.appActive()) {
        var key: ?dvui.Id = null;
        for (outs) |slot| if (slot) |o| if (viewports.hasKeyboard(o.viewport)) {
            key = o.id;
        };
        if (key != keyed) {
            keyed = key;
            dvui.focusSubwindow(key orelse dvui.currentWindow().data().id, null);
            if (key) |id| dvui.raiseSubwindow(id);
        }
    }
}

/// A floating window shown only as a card (`Tear` past the app's windows, `Grow`) parked where
/// nothing else is in the frame — left of the main window, as far as the bands are right of it — on
/// a screen of dvui's of its own: dvui clips it to that screen, which is itself, and keeps it there.
/// Where it was, dvui clipped it to the main window wherever its middle was over it — just past the
/// window's edge, and growing into its window (the user). The card is placed by the pointer, not by
/// where the floating window is. Set before the app draws; the screen, for `publishScreens`.
fn park(s: f32) ?dvui.Rect.Natural {
    const id = if (grow) |g| g.id else if (tear) |t| if (t.out_ns != null) t.id else return null else return null;
    // Its window opened: in that window's band from here (`beforeFrame`), its first picture there.
    if (outOf(id) != null) return null;
    const r = dvui.dataGet(null, id, "_rect", dvui.Rect) orelse return null;
    const at: dvui.Rect.Natural = .{ .x = -viewports.band_stride / s, .y = 0, .w = r.w, .h = r.h };
    dvui.dataSet(null, id, "_rect", dvui.Rect{ .x = at.x, .y = at.y, .w = at.w, .h = at.h });
    return at;
}

fn viewRect(r: dvui.Rect.Physical) viewports.Rect {
    return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
}

/// The floating window being dragged this frame, if any, as a card past the app's windows (`Tear`),
/// and a card growing into its window (`Grow`) or a window shrinking back (`Merge`). After the app
/// has drawn, so its rect and drawing are this frame's.
fn tearFrame() void {
    if (!viewports.tears()) return;
    const cw = dvui.currentWindow();
    growFrame(cw);
    mergeFrame(cw);
    const held = viewports.pointerHeld();
    var dragged: ?*dvui.Subwindows.Subwindow = null;
    if (held) if (dvui.captureMouseGet()) |cm| for (cw.subwindows.stack.items) |*sw| {
        if (sw.id != cm.id or !sw.used or sw.modal or sw.id == cw.data().id or outOf(sw.id) != null) continue;
        dragged = sw;
        break;
    };
    const sw = dragged orelse {
        if (tear) |*t| {
            if (!held and t.place != null and t.live != null and t.card != null and grow == null) {
                // Let go over the desktop: the card grows into the window, its content where the
                // floating window's would be under the pointer, its title bar's band over it.
                const r = t.last;
                const mouse = viewports.pointerInMain();
                const band = viewports.titleBand();
                const content: dvui.Rect.Physical = .{ .x = mouse.x - t.grab.x, .y = mouse.y - t.grab.y, .w = r.w, .h = r.h };
                grow = .{
                    .id = t.id,
                    .card = t.card.?,
                    .card_target = t.card_target,
                    .live = t.live.?,
                    .from = t.place.?,
                    .to = .{ .x = content.x, .y = content.y - band, .w = content.w, .h = content.h + band },
                    .band = band,
                    .start_ns = cw.frame_time_ns,
                };
                t.card = null;
                t.card_target = null;
                t.live = null;
                dvui.refresh(null, @src(), null);
            } else if (frameless == t.id) frameless = null;
            endTear(t);
            tear = null;
        }
        return;
    };
    const r = sw.rect_pixels;
    const mouse = cw.mouse_pt;
    if (tear == null or tear.?.id != sw.id) {
        if (tear) |*t| endTear(t);
        tear = .{ .id = sw.id, .grab = .{ .x = mouse.x - r.x, .y = mouse.y - r.y }, .last = r };
        return;
    }
    const t = &tear.?;
    if (r.w != t.last.w or r.h != t.last.h) {
        t.moving = false;
    } else if (r.x != t.last.x or r.y != t.last.y) {
        t.moving = true;
    }
    t.last = r;
    // The app's window it is over in front, to show where it would land (the user): once, as it
    // comes over each.
    const over = viewports.windowAtPointer();
    if (t.moving and over != t.over) if (over) |w| viewports.bringForward(w);
    t.over = over;
    if (!t.moving or over != null) {
        // In a window of the app's: drawn there, as dvui draws it, its header back — from where the
        // pointer took it, back over a window: dvui kept it at the edge it left by (`screenFor`)
        // while the pointer went on, and it came back that far from the pointer (the user).
        if (t.out_ns != null) {
            const s = dvui.windowNaturalScale();
            dvui.dataSet(null, t.id, "_rect", dvui.Rect{ .x = (mouse.x - t.grab.x) / s, .y = (mouse.y - t.grab.y) / s, .w = r.w / s, .h = r.h / s });
            dvui.refresh(null, @src(), null);
        }
        t.out_ns = null;
        if (frameless == t.id) frameless = null;
        if (t.card) |c| viewports.carryShape(c, null, 0);
        t.place = null;
        return;
    }
    if (t.out_ns == null) {
        // Past them: drawn without its header from the next frame, and the card from then. This
        // frame as dvui drew it, header and all.
        t.out_ns = cw.frame_time_ns;
        frameless = t.id;
        dvui.refresh(null, @src(), null);
        return;
    }
    // Its picture without its header, at its size, taken out of the window dvui keeps it at the
    // edge of (`screenFor`): there only at the pointer, as the card.
    if (!livePicture(&t.live, sw)) return;
    const ns = dvui.windowNaturalScale();
    const small = @min(card_scale, card_max_w * ns / @max(1, r.w));
    // From its size into the card, round the pointer, its header's place closing up as it goes.
    const k = ease(cw.frame_time_ns - t.out_ns.?, shrink_ns);
    const scale = 1 + (small - 1) * k;
    if (k < 1) dvui.refresh(null, @src(), null);
    // Where the pointer is on the desktop, in the main window's frame: a floating window pressed in
    // another OS window's band was read in that band (`SDLBackend.heldPoint`), and its card and its
    // window went a band's width off — 32,000 points — and back on screen as macOS put them (the user,
    // traced).
    const at = viewports.pointerInMain();
    const card = whole(.{ .x = at.x - t.grab.x * scale, .y = at.y - t.grab.y * scale, .w = r.w * scale, .h = r.h * scale });
    if (t.card == null) t.card = viewports.openCarry(viewRect(card)) orelse return;
    drawCard(t.card.?, &t.card_target, t.live.?, card, headerHeight() * (1 - k) * scale, scale);
    t.place = card;
}

/// `sw`'s drawing this frame into `slot`'s target at its size, taken out of the frame: smoothly
/// sampled, for a card that shrinks it (sampled by the nearest pixel, its text crawled as the card
/// moved, the user). Whether there is a picture.
fn livePicture(slot: *?dvui.Texture.Target, sw: *dvui.Subwindows.Subwindow) bool {
    const r = sw.rect_pixels;
    const w: u32 = @intFromFloat(@max(1, @round(r.w)));
    const h: u32 = @intFromFloat(@max(1, @round(r.h)));
    if (slot.*) |target| if (target.width != w or target.height != h) {
        target.destroyLater();
        slot.* = null;
    };
    if (slot.* == null) slot.* = dvui.textureCreateTarget(.{ .width = w, .height = h, .interpolation = .linear }) catch return false;
    const picture: viewports.Picture = .begin(slot.*.?, viewRect(r));
    dvui.currentWindow().renderSubwindow(sw, .{ .take = true });
    picture.end();
    return true;
}

/// A card in carry window `card` at `at` (the main window's frame, physical): the window's colour,
/// a band of it `strip` high at its top — a title bar's or a header's place — and `content` under
/// it at the card's width; its corners the window's at `scale`.
fn drawCard(card: *viewports.Viewport, card_target: *?dvui.Texture.Target, content: dvui.Texture.Target, at: dvui.Rect.Physical, strip: f32, scale: f32) void {
    const placed = viewports.placeMain(card, viewRect(at));
    const shown: dvui.Rect.Physical = .{ .x = placed.x, .y = placed.y, .w = placed.w, .h = placed.h };
    viewports.carryShape(card, viewports.windowRadius() * dvui.windowNaturalScale() * scale, 1);
    const w: u32 = @intFromFloat(@max(1, @round(shown.w)));
    const h: u32 = @intFromFloat(@max(1, @round(shown.h)));
    const target = viewports.sizedTarget(card_target, w, h) orelse return;
    const picture: viewports.Picture = .begin(target, viewRect(shown));
    {
        const prev_clip = dvui.clipGet();
        defer dvui.clipSet(prev_clip);
        dvui.clipSet(shown);
        shown.fill(.all(0), .{ .color = .{ .color = dvui.themeGet().color(.window, .fill) } });
        if (dvui.Texture.fromTargetTemp(content)) |tex| {
            const k = at.w / @max(1, @as(f32, @floatFromInt(content.width)));
            const r: dvui.Rect.Physical = .{ .x = at.x, .y = @round(at.y + strip), .w = at.w, .h = @as(f32, @floatFromInt(content.height)) * k };
            dvui.renderTexture(tex, .{ .r = r, .s = 1 }, .{}) catch {};
        } else |_| {}
    }
    picture.end();
    viewports.present(card, target);
}

/// The card growing into the window let go over the desktop (`Grow`): eased from where it was to
/// the window's frame, the title bar's band opening at its top, the window asked for as it gets
/// there, and the card gone once that window shows. The floating window, drawn without its header
/// meanwhile (`frameless`), nowhere but in the card.
fn growFrame(cw: *dvui.Window) void {
    const g = if (grow) |*g| g else return;
    var drawn = false;
    for (cw.subwindows.stack.items) |*sw| if (sw.id == g.id) {
        drawn = true;
        if (outOf(sw.id)) |o| {
            if (o.fresh) viewports.Picture.drop(sw);
        } else _ = livePicture(&g.live, sw);
    };
    // Given up: the floating window closed on its way, or no window opened for it in a second past
    // the card's growing (none to spare, or one it cannot have: no `open_flag` to close it by). The
    // card goes, and the floating window is an ordinary one again; kept, the card stayed and every
    // frame asked for the next.
    if (!drawn or (g.asked and outOf(g.id) == null and cw.frame_time_ns - g.start_ns > grow_ns + std.time.ns_per_s)) {
        endGrow(g);
        return;
    }
    const live = g.live orelse return;
    const k = ease(cw.frame_time_ns - g.start_ns, grow_ns);
    const at = whole(lerp(g.from, g.to, k));
    const scale = at.w / @max(1, g.to.w);
    drawCard(g.card, &g.card_target, live, at, g.band * k * scale, scale);
    if (k >= 1 and !g.asked) {
        g.asked = true;
        tearOff(g.id, .{ .x = g.to.x, .y = g.to.y + g.band, .w = g.to.w, .h = g.to.h - g.band });
    }
    // Its window on screen: the card goes, and the window is where it was.
    if (outOf(g.id)) |o| if (!o.fresh and viewports.shown(o.viewport)) {
        endGrow(g);
        return;
    };
    dvui.refresh(null, @src(), null);
}

fn endGrow(g: *Grow) void {
    viewports.close(g.card);
    if (g.card_target) |ct| ct.destroyLater();
    if (g.live) |live| live.destroyLater();
    if (frameless == g.id) frameless = null;
    // Asked for and never opened: not torn off after all.
    if (outOf(g.id) == null) for (&torn_list) |*ts| if (ts.*) |tt| if (tt.id == g.id) {
        ts.* = null;
    };
    grow = null;
    dvui.refresh(null, @src(), null);
}

/// A torn-off window shrinking back into the main window (`Merge`): its last picture eased from the
/// window's frame to the floating window's place, the OS's title bar's band becoming dvui's
/// header's; the floating window drawn nowhere meanwhile, and there as the card goes.
fn mergeFrame(cw: *dvui.Window) void {
    const m = if (merge) |*m| m else return;
    const k = ease(cw.frame_time_ns - m.start_ns, grow_ns);
    if (k >= 1) {
        viewports.close(m.card);
        if (m.card_target) |ct| ct.destroyLater();
        m.snap.destroyLater();
        merge = null;
        return;
    }
    for (cw.subwindows.stack.items) |*sw| if (sw.id == m.id) viewports.Picture.drop(sw);
    const at = whole(lerp(m.from, m.to, k));
    drawCard(m.card, &m.card_target, m.snap, at, m.band + (m.header - m.band) * k, 1);
    dvui.refresh(null, @src(), null);
}

fn lerp(a: dvui.Rect.Physical, b: dvui.Rect.Physical, k: f32) dvui.Rect.Physical {
    return .{ .x = a.x + (b.x - a.x) * k, .y = a.y + (b.y - a.y) * k, .w = a.w + (b.w - a.w) * k, .h = a.h + (b.h - a.h) * k };
}

/// How far `elapsed` is through `total`, eased out (cubic), 0 to 1.
fn ease(elapsed: i128, total: i128) f32 {
    const t: f32 = @floatCast(std.math.clamp(@as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(total)), 0, 1));
    return 1 - (1 - t) * (1 - t) * (1 - t);
}

/// `r` on whole pixels: a card at a fraction of one was drawn a little differently each frame,
/// and shimmered as it moved.
fn whole(r: dvui.Rect.Physical) dvui.Rect.Physical {
    return .{ .x = @round(r.x), .y = @round(r.y), .w = @round(r.w), .h = @round(r.h) };
}

fn endTear(t: *Tear) void {
    if (t.card) |c| viewports.close(c);
    if (t.card_target) |target| target.destroyLater();
    if (t.live) |live| live.destroyLater();
    t.card = null;
    t.card_target = null;
    t.live = null;
}

/// Floating window `id` in an OS window of its own from the next frame, opened at `at` (the main
/// window's frame, physical) rather than where dvui keeps it, at the window's edge.
fn tearOff(id: dvui.Id, at: dvui.Rect.Physical) void {
    for (&torn_list) |*slot| if (slot.* == null) {
        slot.* = .{ .id = id, .at = at };
        dvui.refresh(null, @src(), null);
        return;
    };
}

/// After the app's frame, before `dvui.Window.end`.
pub fn afterFrame() void {
    tearFrame();
    if (named_n == 0 and for (outs) |slot| {
        if (slot != null) break false;
    } else true) return;
    const cw = dvui.currentWindow();
    // Dialogs and toasts are subwindows from here, so each lands in the window it is over.
    cw.drawRetained(.{});
    const s = dvui.windowNaturalScale();

    for (&outs) |*slot| {
        const o = if (slot.*) |*o| o else continue;
        const drawn = for (cw.subwindows.stack.items) |sw| {
            if (sw.id == o.id) break sw.used;
        } else false;
        if (drawn) {
            // Its close button cleared what showed it: it goes next frame, which comes now
            // rather than at the next event.
            if (namedOf(o.id) == null) dvui.refresh(null, @src(), null);
            continue;
        }
        viewports.close(o.viewport);
        if (o.target) |t| t.destroyLater();
        // Closed: an ordinary floating window again, next time it shows.
        for (&torn_list) |*ts| if (ts.*) |tt| if (tt.id == o.id) {
            ts.* = null;
        };
        slot.* = null;
        open_failed = false;
    }

    for (named_list[0..named_n]) |*w| {
        if (!w.shown or w.hold or outOf(w.id) != null) continue;
        if (!viewports.available()) break;
        const slot = for (&outs) |*slot| {
            if (slot.* == null) break slot;
        } else break;
        const r = dvui.dataGet(null, w.id, "_rect", dvui.Rect) orelse continue;
        // Not before dvui has sized and placed it: a floating window spends its first frame
        // measuring itself, hidden, and centers itself once (`_auto_pos`) — over the main window,
        // which would take it out of its window's band again.
        if (r.w < 1 or r.h < 1) continue;
        if (dvui.dataGet(null, w.id, "_auto_pos", bool) orelse true) continue;
        // Torn off: where it was let go.
        var at = physical(r, s);
        for (&torn_list) |*ts| if (ts.*) |*tt| if (tt.id == w.id) if (tt.at) |a| {
            at = viewRect(a);
            tt.at = null;
        };
        const vp = viewports.open(at, &w.title, .native) orelse {
            open_failed = true;
            break;
        };
        slot.* = .{ .id = w.id, .viewport = vp, .title = w.title };
        dvui.dataSet(null, w.id, "_rect", natural(viewports.frameOf(vp), s));
        dvui.refresh(null, @src(), null);
    }

    for (&outs) |*slot| {
        const o = if (slot.*) |*o| o else continue;
        if (o.fresh) {
            o.fresh = false;
            continue;
        }
        // Its window's part of the frame: the floating window was given it (`beforeFrame`), and
        // anything it did to its own size this frame is not handed back to the window.
        const shown = viewports.frameOf(o.viewport);
        // Its window's close: as the floating window's close button would, and gone next frame.
        if (viewports.closeRequested(o.viewport)) if (namedOf(o.id)) |w| if (w.open_flag) |of| {
            of.* = false;
            dvui.refresh(null, @src(), null);
        };
        if (namedOf(o.id)) |n| {
            if (!std.mem.eql(u8, &n.title, &o.title)) {
                o.title = n.title;
                viewports.setTitle(o.viewport, std.mem.sliceTo(&o.title, 0));
            }
            // The OS resizes it, within what the floating window allows — dvui's demo is no wider
            // than 600, and its window maximizes no wider. Not what its content needs, which
            // changes as it is resized (a pane collapsing) and fought the person.
            if (!std.meta.eql(n.min, o.min)) {
                o.min = n.min;
                viewports.minSize(o.viewport, n.min.w * s, n.min.h * s);
            }
            if (!std.meta.eql(n.max, o.max)) {
                o.max = n.max;
                // None each way it has none (`dvui.max_float_safe`).
                const none = dvui.max_float_safe;
                viewports.maxSize(o.viewport, if (n.max.w >= none) 0 else n.max.w * s, if (n.max.h >= none) 0 else n.max.h * s);
            }
        }
        const w: u32 = @intFromFloat(@max(1, @round(shown.w)));
        const h: u32 = @intFromFloat(@max(1, @round(shown.h)));
        const target = viewports.keptTarget(o.viewport, &o.target, w, h) orelse continue;
        const area: dvui.Rect.Physical = .{ .x = shown.x, .y = shown.y, .w = shown.w, .h = shown.h };
        const picture: viewports.Picture = .begin(target, shown);
        // Every subwindow over any of its part of the frame: the parts are a band apart, so one
        // overlaps one at most. By its middle, a floating window larger than the window it was
        // dragged into — dvui keeps it on that window's screen from its top left, the rest past the
        // edge — had its middle past the part, was in no window's picture, and vanished (the user).
        for (cw.subwindows.stack.items) |*sw| {
            if (!area.intersect(sw.rect_pixels).empty()) dvui.currentWindow().renderSubwindow(sw, .{ .take = true });
        }
        picture.end();
        viewports.present(o.viewport, target);
    }
}

fn outOf(id: dvui.Id) ?*Out {
    for (&outs) |*slot| if (slot.*) |*o| if (o.id == id) return o;
    return null;
}

fn namedOf(id: dvui.Id) ?*const Named {
    for (named_list[0..named_n]) |*w| if (w.id == id) return w;
    return null;
}
