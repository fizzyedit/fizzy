//! The screens a floating thing — a menu, a tooltip, a popover, a dialog — is placed on and kept
//! within. The main window's, and, while a float is out of it in an OS window of its own, that
//! window's part of the frame (`plans/POPOUT_WINDOWS_PLAN.md`): far past the main window's edge,
//! where anything opened from the float is drawn and from where it is copied into that window.
//! Placed against the main window there, a menu opened in a float that is out was pulled all the
//! way back onto the main window, and drawn there.
//!
//! The app publishes them each frame, before anything is placed (`publish`). In the shared dvui
//! window's data rather than this module's own state: a plugin built as a library carries its own
//! copy of `core`, and its menus and tooltips must read the same list as the app's.
const std = @import("std");
const dvui = @import("dvui");

/// The most screens besides the main window's.
pub const max = 8;

const Published = struct {
    n: u8 = 0,
    rects: [max]dvui.Rect.Natural = undefined,
};

const key_id: dvui.Id = @enumFromInt(0x6669_7a7a_7363_726e); // "fizzscrn"
const key = "_screens";

/// The screens there are this frame besides the main window's, natural. The app's, each frame
/// before anything is placed; not published, or empty, there is the main window's alone.
pub fn publish(rects: []const dvui.Rect.Natural) void {
    if (rects.len == 0) return clear();
    var p: Published = .{};
    for (rects[0..@min(rects.len, max)]) |r| {
        p.rects[p.n] = r;
        p.n += 1;
    }
    dvui.dataSet(null, key_id, key, p);
}

/// No screens but the main window's, from now.
pub fn clear() void {
    dvui.dataRemove(null, key_id, key);
}

/// The screen `r` (natural) is on: the published one its middle is in, else the main window's
/// (`mainScreen`).
pub fn screenFor(r: dvui.Rect.Natural) dvui.Rect.Natural {
    const p = dvui.dataGetPtr(null, key_id, key, Published) orelse return mainScreen();
    const c = r.center();
    for (p.rects[0..p.n]) |s| if (s.contains(c)) return s;
    return mainScreen();
}

/// Whether `p`, natural, is on a screen of the app's besides the main window's: a float's window
/// that is out. Not where `screenFor` falls back to, which is no rect of the main window's own.
pub fn onScreen(p: dvui.Point.Natural) bool {
    const s = dvui.dataGetPtr(null, key_id, key, Published) orelse return false;
    for (s.rects[0..s.n]) |r| if (r.contains(p)) return true;
    return false;
}

/// How far down the main window its screen starts, natural (`mainScreen`): the strip its title bar
/// takes, where the OS and not the app takes a press — on macOS AppKit's title bar and toolbar, over
/// SDL's view. The app's, each frame; 0 when it publishes none.
pub fn publishMainTop(top: f32) void {
    dvui.dataSet(null, key_id, "_main_top", @max(0, top));
}

/// The main window's screen: the window, below its title strip (`publishMainTop`). A dialog drawn
/// in the window and dragged up over the strip took no press there, and could be neither clicked nor
/// dragged back (the user); kept on this, it, a menu or a tooltip stays where the app takes presses.
pub fn mainScreen() dvui.Rect.Natural {
    var r = dvui.windowRect();
    const top = @min(dvui.dataGet(null, key_id, "_main_top", f32) orelse 0, r.h);
    r.y += top;
    r.h -= top;
    return r;
}

/// A floating thing drawn across every screen this frame — a view drag's layer, whose drops and
/// carried glass are wherever the places and the pointer are: the app copies its drawing into
/// every screen's window, not just the main one. Each frame it is drawn (`isEverywhere`).
pub fn markEverywhere(id: dvui.Id) void {
    const now = dvui.currentWindow().frame_time_ns;
    const e = dvui.dataGetPtrDefault(null, key_id, "_everywhere", Everywhere, .{});
    if (e.frame != now) e.* = .{ .frame = now };
    if (e.n < e.ids.len) {
        e.ids[e.n] = id;
        e.n += 1;
    }
}

/// Whether `id` was marked as drawn across every screen this frame (`markEverywhere`).
pub fn isEverywhere(id: dvui.Id) bool {
    const e = dvui.dataGetPtr(null, key_id, "_everywhere", Everywhere) orelse return false;
    if (e.frame != dvui.currentWindow().frame_time_ns) return false;
    for (e.ids[0..e.n]) |i| if (i == id) return true;
    return false;
}

const Everywhere = struct {
    frame: i128 = 0,
    n: u8 = 0,
    ids: [8]dvui.Id = undefined,
};

/// What is carried, in a layer of its own this frame, where the app shows it in a window of its
/// own over every other (fizzy's carry window): that window takes the layer's drawing whole, and
/// the app's own windows draw none of it. A copy left in them, under the carry window, was drawn
/// at a different moment from it — the window server moves the carry window, the app presents its
/// windows — and trailed behind it as it moved.
/// Several a frame: the carried view, and what goes over the OS's glass with it (a drop's icons).
pub fn markCarried(id: dvui.Id) void {
    const now = dvui.currentWindow().frame_time_ns;
    const c = dvui.dataGetPtrDefault(null, key_id, "_carried", Carried, .{});
    if (c.frame != now) c.* = .{ .frame = now };
    if (c.n < c.ids.len) {
        c.ids[c.n] = id;
        c.n += 1;
    }
}

/// Whether `id` is carried this frame (`markCarried`).
pub fn isCarried(id: dvui.Id) bool {
    const c = dvui.dataGetPtr(null, key_id, "_carried", Carried) orelse return false;
    if (c.frame != dvui.currentWindow().frame_time_ns) return false;
    for (c.ids[0..c.n]) |i| if (i == id) return true;
    return false;
}

const Carried = struct {
    frame: i128 = 0,
    n: u8 = 0,
    ids: [4]dvui.Id = undefined,
};

/// Menus in windows of their own this frame (`markMenu`): the app's, each frame, with the display
/// the main window is on — natural, in the main window's frame — as the screen they are kept on, so
/// one near the window's edge hangs past it. Null: menus are drawn in the window they open from, on
/// its screen. In dvui's data, as `publish`, so a plugin's menus read it too.
pub fn publishMenus(display: ?dvui.Rect.Natural) void {
    if (display) |d| dvui.dataSet(null, key_id, "_menus", d) else dvui.dataRemove(null, key_id, "_menus");
}

/// Whether menus are windows of their own this frame (`publishMenus`): a menu draws no frost, fill
/// or shadow of its own then — its window wears the OS's material and shadow.
pub fn nativeMenus() bool {
    return dvui.dataGet(null, key_id, "_menus", dvui.Rect.Natural) != null;
}

/// The screen a menu at `r` is kept on: the display, where menus are windows of their own and `r`'s
/// middle is on it (`publishMenus`); else `screenFor`.
pub fn menuScreenFor(r: dvui.Rect.Natural) dvui.Rect.Natural {
    if (dvui.dataGet(null, key_id, "_menus", dvui.Rect.Natural)) |d| {
        if (d.contains(r.center())) return d;
    }
    return screenFor(r);
}

/// `menuScreenFor`, physical: what a menu clips its drawing to.
pub fn menuPixelsFor(r: dvui.Rect.Natural) dvui.Rect.Physical {
    const s = menuScreenFor(r);
    const m = dvui.windowNaturalScale();
    return .{ .x = s.x * m, .y = s.y * m, .w = s.w * m, .h = s.h * m };
}

/// Whether every menu should close this frame: where menus are windows of their own, kept above
/// every window, the app is not the active one — as an OS menu closes when its app is left
/// (`core.widgets.FloatingMenuWidget`). The app's, each frame.
pub fn publishMenusDismissed(dismissed: bool) void {
    if (dismissed) dvui.dataSet(null, key_id, "_menus_dismissed", true) else dvui.dataRemove(null, key_id, "_menus_dismissed");
}

/// Whether every menu should close this frame (`publishMenusDismissed`).
pub fn menusDismissed() bool {
    return dvui.dataGet(null, key_id, "_menus_dismissed", bool) orelse false;
}

/// A menu, in a subwindow of its own this frame: where menus are windows of their own
/// (`publishMenus`), the app shows each in one (`Popout`). Each frame it is drawn.
pub fn markMenu(id: dvui.Id) void {
    const now = dvui.currentWindow().frame_time_ns;
    const m = dvui.dataGetPtrDefault(null, key_id, "_menu_ids", Marked, .{});
    if (m.frame != now) m.* = .{ .frame = now };
    if (m.n < m.ids.len) {
        m.ids[m.n] = id;
        m.n += 1;
    }
}

/// Whether `id` is a menu this frame (`markMenu`).
pub fn isMenu(id: dvui.Id) bool {
    const m = dvui.dataGetPtr(null, key_id, "_menu_ids", Marked) orelse return false;
    if (m.frame != dvui.currentWindow().frame_time_ns) return false;
    for (m.ids[0..m.n]) |i| if (i == id) return true;
    return false;
}

/// Dialogs in windows of their own this frame (`markDialog`), as menus are (`publishMenus`): the
/// app's, each frame, with the display the main window is on as the screen they are kept on. Null:
/// dialogs are drawn in the window they open in.
pub fn publishDialogs(display: ?dvui.Rect.Natural) void {
    if (display) |d| dvui.dataSet(null, key_id, "_dialogs", d) else dvui.dataRemove(null, key_id, "_dialogs");
}

/// Whether dialogs are windows of their own this frame (`publishDialogs`): a dialog draws no frost,
/// fill, shadow or dimming of its own then — its window wears the OS's material and shadow.
pub fn nativeDialogs() bool {
    return dvui.dataGet(null, key_id, "_dialogs", dvui.Rect.Natural) != null;
}

/// The screen a dialog at `r` is kept on and sized to. Where dialogs are windows of their own
/// (`publishDialogs`), the display: the one the main window is on, for a dialog over the main
/// window; for one opened in a float that is out — in that float's band — the display's size round
/// the dialog itself, its window being its own and no bigger than a display. Else `screenFor`.
pub fn dialogScreenFor(r: dvui.Rect.Natural) dvui.Rect.Natural {
    const d = dvui.dataGet(null, key_id, "_dialogs", dvui.Rect.Natural) orelse return screenFor(r);
    if (d.contains(r.center())) return d;
    const s = screenFor(r);
    if (s.equals(mainScreen())) return s;
    const c = r.center();
    return .{ .x = c.x - d.w / 2, .y = c.y - d.h / 2, .w = d.w, .h = d.h };
}

/// `dialogScreenFor`, physical: what a dialog clips its drawing to.
pub fn dialogPixelsFor(r: dvui.Rect.Natural) dvui.Rect.Physical {
    const s = dialogScreenFor(r);
    const m = dvui.windowNaturalScale();
    return .{ .x = s.x * m, .y = s.y * m, .w = s.w * m, .h = s.h * m };
}

/// A dialog, in a subwindow of its own this frame: where dialogs are windows of their own
/// (`publishDialogs`), the app shows each in one (`Popout`). Each frame it is drawn; `radius` is
/// its corners, natural, which its window's material is rounded to, and `alpha` how far it has
/// faded on its way shut.
pub fn markDialog(id: dvui.Id, radius: f32, alpha: f32) void {
    const now = dvui.currentWindow().frame_time_ns;
    const m = dvui.dataGetPtrDefault(null, key_id, "_dialog_ids", MarkedDialogs, .{});
    if (m.frame != now) m.* = .{ .frame = now };
    if (m.n < m.ids.len) {
        m.ids[m.n] = .{ .id = id, .radius = radius, .alpha = alpha };
        m.n += 1;
    }
}

/// `id` as a dialog this frame (`markDialog`), if it is one.
pub fn dialog(id: dvui.Id) ?MarkedDialog {
    const m = dvui.dataGetPtr(null, key_id, "_dialog_ids", MarkedDialogs) orelse return null;
    if (m.frame != dvui.currentWindow().frame_time_ns) return null;
    for (m.ids[0..m.n]) |d| if (d.id == id) return d;
    return null;
}

pub const MarkedDialog = struct {
    id: dvui.Id,
    radius: f32,
    alpha: f32,
};

const MarkedDialogs = struct {
    frame: i128 = 0,
    n: u8 = 0,
    ids: [4]MarkedDialog = undefined,
};

const Marked = struct {
    frame: i128 = 0,
    n: u8 = 0,
    ids: [8]dvui.Id = undefined,
};

/// While something drawn across every screen may be carried past every window of the app's — a
/// view drag where floats are OS windows of their own, and a window carries the view over the
/// desktop — it reaches across the whole desktop (`allPixels`). The app's, each frame.
pub fn publishBeyond(on: bool) void {
    if (on) dvui.dataSet(null, key_id, "_beyond", true) else dvui.dataRemove(null, key_id, "_beyond");
}

/// How far past the main window the whole desktop reaches, natural units each way: further than
/// any desktop.
const beyond: f32 = 16384;

/// Every screen at once, physical: what a floating thing drawn across all of them clips to.
pub fn allPixels() dvui.Rect.Physical {
    var r = dvui.windowRectPixels();
    if (dvui.dataGet(null, key_id, "_beyond", bool) orelse false) r = r.outsetAll(beyond * dvui.windowNaturalScale());
    const p = dvui.dataGetPtr(null, key_id, key, Published) orelse return r;
    const m = dvui.windowNaturalScale();
    for (p.rects[0..p.n]) |s| r = r.unionWith(.{ .x = s.x * m, .y = s.y * m, .w = s.w * m, .h = s.h * m });
    return r;
}

/// `screenFor`, physical: what a floating thing on that screen clips its drawing to.
pub fn pixelsFor(r: dvui.Rect.Natural) dvui.Rect.Physical {
    const s = screenFor(r);
    const m = dvui.windowNaturalScale();
    return .{ .x = s.x * m, .y = s.y * m, .w = s.w * m, .h = s.h * m };
}
