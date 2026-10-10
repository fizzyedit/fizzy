//! `dvui.osWindow` on this backend: each is a floating window in the one frame (dvui's fallback,
//! as this backend makes no `dvui.Window` of its own for one), shown in an OS window of its own
//! (`viewports`) that looks just as it does inside the main window — dvui's header and close
//! button, no OS title bar (`Frame.app`). The app writes plain dvui; on a backend without OS
//! windows the same floating window stays in the main window.
//!
//! dvui says which floating windows are OS windows as they draw (`named`, from
//! `SDLBackend.osWindowFloating`). Around the app's frame (`SDLBackend.appIterate`, or an app's
//! own loop):
//!
//! - `beforeFrame`: a window the OS moved takes its floating window with it (`osPlaced`), and each
//!   window's band is a screen of dvui's (`dvui.screensSet`), so dvui keeps the floating window in
//!   it; one being resized holds the pointer in its band (`pinPointer`);
//! - `afterFrame`: dvui's dialogs and toasts made (`Window.drawRetained`); a window whose floating
//!   window was not drawn — closed — goes; each one named and not yet in a window gets one over
//!   where it is (`viewports.open`), drawn in that window's band from the next frame; and each
//!   window is put where its floating window is (`viewports.place`), told its header is where the
//!   OS moves it from (`hints`), and handed its picture: every subwindow in its band, taken out of
//!   the frame (`viewports.Picture`).
//!
//! dvui keeps where each floating window is (`_rect` in its data, by its id): moved into the
//! window's band, and read back after the frame.
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
};
var outs: [max_outs]?Out = @splat(null);

/// The floating windows dvui named as OS windows this frame (`named`), with their headers
/// (physical) and titles.
const Named = struct { id: dvui.Id, header: dvui.Rect.Physical, title: [64:0]u8 };
var named_list: [max_outs]Named = undefined;
var named_n: usize = 0;

/// The pointer is pinned to a window's band by `beforeFrame`, to be let go once nothing holds it.
var pinned = false;

/// dvui drew floating window `id` for an OS window this frame (`dvui.osWindow`), moved by `header`.
pub fn named(id: dvui.Id, header: dvui.Rect.Physical, title: ?[:0]const u8) void {
    if (named_n == named_list.len) return;
    var n: Named = .{ .id = id, .header = header, .title = @splat(0) };
    const t = title orelse "";
    const len = @min(t.len, n.title.len);
    @memcpy(n.title[0..len], t[0..len]);
    named_list[named_n] = n;
    named_n += 1;
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
    var screens: [max_outs]dvui.Rect.Natural = undefined;
    var n: usize = 0;
    var pin: ?*viewports.Viewport = null;
    for (&outs) |*slot| {
        const o = if (slot.*) |*o| o else continue;
        if (viewports.osPlaced(o.viewport)) |fr| dvui.dataSet(null, o.id, "_rect", natural(fr, s));
        _ = viewports.osMoveEnded(o.viewport);
        const r = dvui.dataGet(null, o.id, "_rect", dvui.Rect) orelse continue;
        screens[n] = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
        n += 1;
        // Resized from its edges, it holds the pointer: read in its band till it lets go, even
        // past its window's edge.
        if (dvui.captured(o.id)) pin = o.viewport;
    }
    // Only with windows of its own: an app keeping screens of its own (fizzy's floats) sets them.
    if (n > 0) dvui.screensSet(screens[0..n]);
    if (pin) |vp| {
        viewports.pinPointer(.{ .viewport = vp });
        pinned = true;
    } else if (pinned) {
        viewports.pinPointer(.none);
        pinned = false;
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
    }

    for (named_list[0..named_n]) |*w| {
        if (outOf(w.id) != null) continue;
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
        const vp = viewports.open(physical(r, s), &w.title, .app) orelse break;
        slot.* = .{ .id = w.id, .viewport = vp };
        dvui.dataSet(null, w.id, "_rect", natural(viewports.frameOf(vp), s));
        dvui.refresh(null, @src(), null);
    }

    for (&outs) |*slot| {
        const o = if (slot.*) |*o| o else continue;
        if (o.fresh) {
            o.fresh = false;
            continue;
        }
        const r = dvui.dataGet(null, o.id, "_rect", dvui.Rect) orelse continue;
        const shown = viewports.place(o.viewport, physical(r, s));
        // The OS moves its window by its header, but for the close button — square at the
        // header's height, at its right end where buttons go OK then Cancel, else its left
        // (`dvui.windowHeader`) — and not from the floating window's own resize zones round its
        // edge (`app_side`).
        if (namedOf(o.id)) |w| {
            const hd = w.header;
            const keep_x = if (cw.button_order == .ok_cancel) hd.x + hd.w - hd.h else hd.x;
            viewports.hints(o.viewport, .{
                .drag = .{ .x = hd.x, .y = hd.y, .w = hd.w, .h = hd.h },
                .keep = .{ .x = keep_x, .y = hd.y, .w = hd.h, .h = hd.h },
                .glass = shown,
                .edge = 0,
                .app_side = 6 * s,
                .app_corner = 15 * s,
            });
        }
        const w: u32 = @intFromFloat(@max(1, @round(shown.w)));
        const h: u32 = @intFromFloat(@max(1, @round(shown.h)));
        const target = viewports.sizedTarget(&o.target, w, h) orelse continue;
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
