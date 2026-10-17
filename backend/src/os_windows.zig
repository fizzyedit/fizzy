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
const Named = struct { id: dvui.Id, title: [64:0]u8 = @splat(0), open_flag: ?*bool, min: dvui.Size, max: dvui.Size, shown: bool = false };
var named_list: [max_outs]Named = undefined;
var named_n: usize = 0;

/// The floating window that has the keyboard, as last read from the OS's key window: null for the
/// main window's own subwindow.
var keyed: ?dvui.Id = null;

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
    const shown = outOf(id) != null or (viewports.available() and !open_failed and waiting < free);
    named_list[named_n] = .{ .id = id, .open_flag = open_flag, .min = min, .max = max, .shown = shown };
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
        dvui.dataSet(null, o.id, "_rect", natural(viewports.frameOf(o.viewport), s));
        dvui.dataSet(null, o.id, "_auto_size", false);
        _ = viewports.osMoveEnded(o.viewport);
    }
    viewports.publishScreens();
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

/// After the app's frame, before `dvui.Window.end`.
pub fn afterFrame() void {
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
        slot.* = null;
        open_failed = false;
    }

    for (named_list[0..named_n]) |*w| {
        if (!w.shown or outOf(w.id) != null) continue;
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
        const vp = viewports.open(physical(r, s), &w.title, .native) orelse {
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
        for (cw.subwindows.stack.items) |*sw| {
            if (area.contains(sw.rect_pixels.center())) picture.subwindow(sw, true);
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
