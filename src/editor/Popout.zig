//! The pop-out plan's viewports (`docs/POPOUT_WINDOWS_PLAN.md`), on by default on macOS and behind
//! `FIZZY_POPOUT=1` elsewhere, on fizzy's native backend: where the platform has OS windows a float is one, from the frame it is
//! made in — every float its own window (a viewport, `fizzy.backend.viewports`), titled and framed by
//! the OS where it can be (macOS), moved, snapped and resized by the OS as any window. Its views go
//! back into the main window by being carried there, as any view is; the window itself never
//! merges into the main one. Without OS windows to have (the web, Wayland) floats stay in the main
//! window (`Floats`).
//!
//! There stays one `dvui.Window`. Each float is drawn in its viewport's band of the frame, far past
//! the main window's edge (`Floats.Viewport`), where no pointer over the main window reaches it. At
//! the end of the frame what is drawn in each band is taken before dvui replays the subwindows into
//! the main window's frame, and replayed instead into a target of the window's own at the band's
//! offset (`endFrame`), which the backend copies into the OS window with the main window's frame;
//! the pointer over that window goes back to dvui where the window shows it. No dvui change:
//! `Window.renderCommands` is public, and fizzy runs dvui's end-of-frame replay itself
//! (`core.FrameTarget.end`), so a float's commands are fizzy's to take first.

const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const fizzy = @import("../fizzy.zig");
const Editor = @import("Editor.zig");
const State = @import("app").layout.State;

const viewports = fizzy.backend.viewports;
const Floats = @import("app").layout.Layout.Floats;

/// The most floats out at once — the backend's viewports (`SDLBackend.max_viewports`). One more
/// stays in the main window.
const max_out = 8;

/// Each float's window, by its float (`Out.serial`).
var outs: [max_out]?Out = @splat(null);
/// The window a carried view is shown in past every window of the app's, for as long as a view
/// drag goes on (`carryFrame`).
var carry: ?Carry = null;
/// Each float's window this frame (`windowFrame`): where it lies over the main window's frame, and
/// the band of the frame it shows. A view carried over the main window is drawn under every one of
/// them, and one carried over a float's window is drawn in its band, cut at its edge: where it is
/// not wholly inside the window drawing it, unobstructed, the carry window shows it, over them all
/// (`carryFrame`).
var covers: [max_out]Cover = undefined;
var cover_count: usize = 0;

/// Each open menu's window (`menuFrame`), by its subwindow — a context menu and the submenus out of
/// it.
var menus: [max_menus]?MenuOut = @splat(null);
/// Menus and dialogs at once: a menu's submenus, a dialog with a menu open in it.
const max_menus = 6;

const MenuOut = struct {
    id: dvui.Id,
    viewport: *viewports.Viewport,
    target: ?dvui.Texture.Target = null,
    /// Drawn this frame: a menu not drawn has closed, and its window goes.
    seen: bool = false,
    /// On Liquid Glass (`viewports.windowGlass`), else vibrancy with the menu's colour drawn over it.
    glass: bool = false,
    /// Opened in a float that is out: where that float's window showed its band then. Its window
    /// moved, a menu closes (`menuFrame`) and a dialog goes with it (`dialogsRide`).
    float_at: ?dvui.Point.Physical = null,
    /// That float's window, for a dialog, which rides on it.
    float_vp: ?*viewports.Viewport = null,
    /// A dialog's window, not a menu's.
    dialog: bool = false,
};

/// A float holding a menu moved its window: every menu closes next frame (`menuFrame`).
var menus_left_behind = false;

const Cover = struct {
    /// The float's window.
    viewport: *viewports.Viewport,
    /// Where the window lies over the main window's frame, physical.
    in_main: dvui.Rect.Physical,
    /// The part of the frame it shows: its band.
    band: dvui.Rect.Physical,
};

/// The carry window of a drag that has just ended, kept one frame for a float the drop made to grow
/// out of (`growFrame`) — already where the drop is, in its shape — and let go after it otherwise.
var spare: ?Carry = null;
/// `spare` has been kept a frame already.
var spare_kept = false;

const Carry = struct {
    viewport: *viewports.Viewport,
    target: ?dvui.Texture.Target = null,
};
var env_on: ?bool = null;

const Out = struct {
    /// Which float: its serial, never handed to another (`Floats.Float.serial`) — its name is
    /// the next float's once it closes.
    serial: u64,
    viewport: *viewports.Viewport,
    /// Its part of the frame, drawn every frame for its window.
    target: ?dvui.Texture.Target = null,
    /// What its window is called now: the float's title, as its header says (`Floats.Float.titleText`).
    title_buf: [96]u8 = undefined,
    title_len: u8 = 0,
    /// The carried glass it is growing out of, landing (`growFrame`).
    grow: ?Grow = null,
    /// Born of a drop: its window kept over the drag's overlay while that still holds glass
    /// (`growFrame`), at the overlay's level, then back at its own.
    lifted: bool = false,
    /// Its base's opacity, eased between windowed and maximized as the main window's is
    /// (`Editor.easeWindowOpacity`).
    opacity: Editor.WindowOpacity = .{},
};

const Grow = struct {
    carry: Carry,
};

/// On a backend with viewports, where this run can open them (not Wayland): by default on macOS,
/// where floats as windows are fully supported (`FIZZY_POPOUT=0` keeps floats in the main window);
/// elsewhere with `FIZZY_POPOUT=1`, until their windows are dressed there too.
pub fn enabled() bool {
    if (comptime builtin.target.cpu.arch == .wasm32 or !viewports.supported) return false;
    if (env_on == null) {
        launched_float_windows = fizzy.editor().app.settings.float_windows;
        const asked = envSwitch("FIZZY_POPOUT") orelse launched_float_windows.?;
        env_on = asked and viewports.available();
    }
    return env_on.?;
}

/// The float windows setting (`Settings.float_windows`) as the app launched with it: floats move
/// in and out of windows only at launch, so a change to it waits for a restart.
var launched_float_windows: ?bool = null;

/// Whether a setting fizzy takes only at launch has been changed since (`Editor.restartPending`):
/// floats as windows.
pub fn restartPending() bool {
    if (comptime builtin.target.cpu.arch == .wasm32 or !viewports.supported) return false;
    const launched = launched_float_windows orelse return false;
    return launched != fizzy.editor().app.settings.float_windows and envSwitch("FIZZY_POPOUT") == null;
}

/// An environment switch, read once: `NAME=0` off, any other value on, unset null — the setting
/// rules then. For testing and sandboxes, over the settings.
fn envSwitch(comptime name: [:0]const u8) ?bool {
    if (comptime builtin.target.cpu.arch == .wasm32) return null;
    // One cache per variable: the struct names `name`, so each switch gets a type of its own.
    // Without it Zig makes one type for every switch, and the first one read answered for all
    // (`FIZZY_NATIVE_GLASS=0` read as whatever `FIZZY_POPOUT` was).
    const Cache = struct {
        const variable = name;
        var read = false;
        var value: ?bool = null;
    };
    if (!Cache.read) {
        Cache.read = true;
        Cache.value = if (std.c.getenv(Cache.variable)) |v| !std.mem.eql(u8, std.mem.span(v), "0") else null;
    }
    return Cache.value;
}

/// Before the frame draws anything: a window whose float has gone goes too, each window the OS
/// moved or resized takes its float with it, one the OS asked to close closes its float — and every
/// float not in a window yet (made last frame, or brought back from a saved layout) goes into one,
/// before it is ever drawn in the main window.
pub fn beginFrame(state: *State) void {
    if (!enabled()) return;
    // A view let go over no window of the app's opens a float there (`ViewDrag.apply`), and what a
    // view drag draws reaches past every window, for the carry window (`carryFrame`).
    state.floats_windowed = true;
    // Carried things are windows of their own here (`carryFrame`): photographed without their
    // place's background (`ViewDrag.photographFromFrame`).
    fizzy.core.dialogs.carry_windows = viewports.carries;
    // And a view drag's glass is the OS's where it has Liquid Glass (`overlayFrame`): while the drag
    // is on, and after it while its drops are still running back together (`ViewDrag.last_pending`)
    // — their going, as their coming, is the OS's glass too.
    fizzy.core.native_glass.publishOn(nativeGlass() and (state.view_drag.active() or state.view_drag.last_pending_count > 0));
    // And the carried view's picture under that glass, in a window of its own (`photoFrame`).
    fizzy.core.native_glass.publishUnder(nativeGlass() and viewports.carries);
    fizzy.core.screens.publishBeyond(viewports.carries and state.view_drag.active());
    // Menus in windows of their own (`menuFrame`), kept on the display rather than the window.
    fizzy.core.screens.publishMenus(if (nativeMenus()) displayNatural() else null);
    fizzy.core.screens.publishMenusDismissed(nativeMenus() and (!viewports.appActive() or menus_left_behind));
    // And dialogs, each riding on the window it opened in.
    fizzy.core.screens.publishDialogs(if (nativeDialogs()) displayNatural() else null);
    menus_left_behind = false;
    // Whatever happened, the screens floating things are placed on this frame: each window's,
    // besides the main window's (`core.screens`).
    defer publishScreens();
    // And where a held pointer is read: pinned while a float's window is being moved or resized.
    defer pinPointer(state);
    for (&outs) |*slot| {
        const o = if (slot.*) |*o| o else continue;
        const i = find(state, o.serial) orelse {
            // Closed, or Reset Layout: its window goes with it.
            release(o);
            slot.* = null;
            continue;
        };
        const f = &state.floats.items.items[i];
        const vpr = if (f.viewport) |*v| v else continue;
        // The OS moved or resized its window — by its header or edges, a snap, maximized: the
        // float follows it.
        if (viewports.osPlaced(o.viewport)) |frame| {
            const s = dvui.windowNaturalScale();
            const r = (dvui.Rect.Physical{ .x = frame.x, .y = frame.y, .w = frame.w, .h = frame.h }).insetAll(reach() * s);
            vpr.rect = .{ .x = r.x / s, .y = r.y / s, .w = r.w / s, .h = r.h / s };
            dvui.refresh(null, @src(), null);
        }
        // Read for its end: the OS's move or resize of it, let go (`viewports.osMoveEnded`).
        _ = viewports.osMoveEnded(o.viewport);
        // The OS asked to close its window (its close button, ⌘W): the float closes, its views
        // going home, as from its header (`Floats.Viewport.close_asked`).
        if (viewports.closeRequested(o.viewport) and !vpr.close_asked) {
            vpr.close_asked = true;
            dvui.refresh(null, @src(), null);
        }
    }
    for (state.floats.items.items) |*f| {
        if (f.viewport != null or f.closing) continue;
        popOut(f);
    }
}

/// How far in from its glass's sides a press resizes a float's window, natural units — where the
/// OS resizes it (`viewports.hints`).
const resize_edge: f32 = 6;
/// The float's own resize zones (`FloatingWindowWidget`'s, for a mouse): how far in from its
/// sides, and along them from its corners, a press resizes it — kept the app's over its header
/// where the OS resizes the window from no edge (`viewports.hints`).
const float_side: f32 = 4;
const float_corner: f32 = 15;

/// Natural units a float's OS window reaches past its rect (`Floats.Float.bounds`): out to the
/// clear margin round its glass that its shadow is drawn in (`Floats.outReach`) — or in to the
/// glass, where the OS frames the window and its corners and shadow are the OS's
/// (`viewports.os_frame`: macOS, Windows).
fn reach() f32 {
    const margin = (fizzy.core.widgets.FloatingWindowWidget.defaults.margin orelse dvui.Rect{}).x;
    return if (viewports.os_frame) -margin else Floats.outReach();
}

/// Put `f` into a window of its own, opening over the place it would be drawn in the main window
/// (its rect, grown or shrunk by `reach`), and draw it from now in the window's band.
fn popOut(f: *Floats.Float) void {
    const slot = for (&outs) |*o| {
        if (o.* == null) break o;
    } else return;
    var title_buf: [96]u8 = undefined;
    const title = std.fmt.bufPrintZ(&title_buf, "{s}", .{f.titleText()}) catch "Fizzy";
    const s = dvui.windowNaturalScale();
    // Where it goes in the main window's frame, whole — not where it was last drawn: made last
    // frame, it may have been drawn as the carried glass it lands from, a drop's size.
    const at: dvui.Rect.Physical = .{ .x = f.rect.x * s, .y = f.rect.y * s, .w = f.rect.w * s, .h = f.rect.h * s };
    const b = at.outsetAll(reach() * s);
    const vp = viewports.open(.{ .x = b.x, .y = b.y, .w = b.w, .h = b.h }, if (title.len > 0) title else "Fizzy") orelse return;
    // A material behind its glass where the platform has one, so it looks there as it does in
    // the main window (`Floats.Viewport.material`). The glass is the float's rect less its own
    // margin: inside the clear one round it, or all of the window the OS frames.
    const margin = (fizzy.core.widgets.FloatingWindowWidget.defaults.margin orelse dvui.Rect{}).x;
    const material = viewports.glass(vp, (reach() + margin) * s, fizzy.core.corners.scaled(fizzy.core.corners.surface) * s, dvui.themeGet().dark);
    const window = viewports.frameOf(vp);
    const frame = (dvui.Rect.Physical{ .x = window.x, .y = window.y, .w = window.w, .h = window.h }).insetAll(reach() * s);
    f.viewport = .{
        .rect = .{ .x = frame.x / s, .y = frame.y / s, .w = frame.w / s, .h = frame.h / s },
        .material = material,
        .os_frame = viewports.os_frame,
        .os_buttons = viewports.os_buttons,
    };
    // The OS resizes it no smaller than its float may be.
    const rules = @import("app").layout.Layout.float_rules;
    viewports.minSize(vp, (rules.resize_min_w + 2 * reach()) * s, (rules.resize_min_h + 2 * reach()) * s);
    slot.* = .{ .serial = f.serial, .viewport = vp };
    dvui.refresh(null, @src(), null);
}

/// A held pointer, pinned to the band of the float whose window is being moved or resized, and read
/// by where it is otherwise (a view carried between windows).
fn pinPointer(state: *const State) void {
    for (outs) |slot| {
        const o = slot orelse continue;
        const i = find(state, o.serial) orelse continue;
        const f = state.floats.items.items[i];
        if (f.win_id == .zero or !dvui.captured(f.win_id)) continue;
        return viewports.pinPointer(.{ .viewport = o.viewport });
    }
    viewports.pinPointer(.none);
}

/// Each window's part of the frame, natural, as a screen menus, tooltips and popovers opened in its
/// float are placed on and kept within (`core.screens`).
fn publishScreens() void {
    var rects: [max_out]dvui.Rect.Natural = undefined;
    var n: usize = 0;
    const s = dvui.windowNaturalScale();
    for (outs) |slot| {
        const o = slot orelse continue;
        const f = viewports.frameOf(o.viewport);
        rects[n] = .{ .x = f.x / s, .y = f.y / s, .w = f.w / s, .h = f.h / s };
        n += 1;
    }
    fizzy.core.screens.publish(rects[0..n]);
}

fn find(state: *const State, serial: u64) ?usize {
    for (state.floats.items.items, 0..) |f, i| {
        if (f.serial == serial) return i;
    }
    return null;
}

fn release(o: *Out) void {
    viewports.close(o.viewport);
    if (o.target) |t| t.destroyLater();
    o.target = null;
    if (o.grow) |*g| releaseCarry(&g.carry);
    o.grow = null;
}

/// After the frame has drawn and before dvui replays the subwindows into the main window's frame
/// (`core.FrameTarget.end`): each float is replayed into its window's target instead, its window
/// put where it was drawn, and handed the picture.
pub fn endFrame(state: *State) void {
    if (!enabled()) return;
    cover_count = 0;
    for (&outs) |*slot| {
        if (slot.*) |*o| windowFrame(state, o);
    }
    // The dialogs drawn now, for `menuFrame` to take them into windows of their own: dvui draws
    // them later, at the very end of the frame. After the floats have their places for this frame
    // (`covers`), which a dialog opened in one goes along with (`dialogsRide`).
    if (nativeDialogs()) {
        dialogsRide();
        fizzy.core.dialogs.drawEarly();
    }
    carryFrame(state);
    menuFrame();
    // A drag's carry window no float grew out of in the frame after the drag: gone.
    if (spare) |*sp| {
        if (spare_kept) {
            releaseCarry(sp);
            spare = null;
        } else spare_kept = true;
    }
}

/// A carried view is shown in a round window of its own (`viewports.openCarry`),
/// wherever it is: a window in the shape of what it is carried as, the OS's material in it with no
/// base over it — lighter than a window, which dialogs and float windows keep — and the OS's shadow
/// round it (`viewports.carryShape`). Its drawing — in the main window's frame, past its edge
/// too, or in the band of the float's window it is over — is in a layer of its own
/// (`core.screens.markCarried`), taken whole into it: the app's own windows draw nothing of it. Left
/// in them under the carry window, a copy drawn at another moment than the window server moved the
/// window trailed behind it. Floats being windows, it was drawn in whichever window it was over until
/// it crossed an edge: cut off at a float window's edge, and under a float's window from the main
/// one. It goes when the drag does.
fn carryFrame(state: *State) void {
    if (!viewports.carries) return;
    if (nativeGlass()) return overlayFrame(state);
    const d = &state.view_drag;
    if (!d.active()) {
        // Kept a frame: a float the drop made grows out of it (`growFrame`).
        if (carry) |c| {
            if (spare) |*sp| releaseCarry(sp);
            spare = c;
            spare_kept = false;
        }
        carry = null;
        return;
    }
    const cw = dvui.currentWindow();
    // What it is carried as: the card or tab, or a drop.
    const shape = d.shape_rect;
    const main_px = dvui.windowRectPixels();
    // Where the carry window goes, in the main window's frame. Over a float's window the view is
    // drawn in that window's band, far past the main window (`Floats.Viewport`): the carry window
    // goes where that part of the band lies on the screen, its picture still read from the band.
    var place = shape;
    const want = if (shape.w <= 0 or shape.h <= 0) false else if (shape.x > main_px.x + main_px.w + 40000) banded: {
        // The window whose band it lies on — the one it overlaps most: near an edge its middle is
        // already past it while the pointer is still on the window.
        var best: ?Cover = null;
        var best_area: f32 = 0;
        for (covers[0..cover_count]) |cv| {
            const o = cv.band.intersect(shape);
            const area = o.w * o.h;
            if (area > best_area) {
                best = cv;
                best_area = area;
            }
        }
        const cover = best orelse break :banded false;
        place = shape.offsetPoint(.{ .x = cover.in_main.x - cover.band.x, .y = cover.in_main.y - cover.band.y });
        break :banded true;
    } else true;
    if (!want) {
        if (carry) |*c| if (c.target) |t| {
            t.clear();
            viewports.present(c.viewport, t);
            viewports.carryShape(c.viewport, null, 0);
        };
        return;
    }
    if (carry == null) {
        const vp = viewports.openCarry(.{ .x = place.x, .y = place.y, .w = place.w, .h = place.h }) orelse return;
        carry = .{ .viewport = vp };
    }
    const c = &carry.?;
    // A little of the window's base under what it carries (`carried_backing`): its glass is clear
    // (the lens), and the view's picture alone, over whatever the bubble passes, did not read.
    // Lighter than a window still — dialogs and float windows keep their own.
    const drawing = carryBegin(c, place, shape, d.shape_radius, 1, carried_backing) orelse return;
    defer carryEnd(c, drawing);
    // The carried view's own layer (`core.screens.markCarried`), taken from it: dvui's replay into the main
    // window, and the float windows' (`windowFrame`), draw nothing of it.
    for (cw.subwindows.stack.items) |*sw| {
        if (!fizzy.core.screens.isCarried(sw.id)) continue;
        const cmds = sw.render_cmds;
        const after = sw.render_cmds_after;
        sw.render_cmds = .empty;
        sw.render_cmds_after = .empty;
        cw.renderCommands(cmds.items) catch |err| dvui.logError(@src(), err, "replaying a carried view into its window", .{});
        cw.renderCommands(after.items) catch |err| dvui.logError(@src(), err, "replaying a carried view into its window", .{});
    }
}

/// How opaque the window's base is under a carried view (`carryFrame`).
const carried_backing: f32 = 0.2;

/// A view drag's glass — the carried view and the drop zones' bubbles — is one overlay of the OS's
/// Liquid Glass over the display the main window is on, wherever the OS has it
/// (`viewports.liquidGlass`, macOS 26): the OS's glass where it can be, the app's where it cannot
/// (`docs/NATIVE_WINDOWS_PLAN.md`) — as the setting says (`Settings.native_glass`,
/// `FIZZY_NATIVE_GLASS` over it). Off, the app's glass.
fn nativeGlass() bool {
    if (comptime builtin.target.cpu.arch == .wasm32 or !viewports.carries) return false;
    if (!(envSwitch("FIZZY_NATIVE_GLASS") orelse fizzy.editor().app.settings.native_glass)) return false;
    if (liquid_glass == null) liquid_glass = viewports.liquidGlass();
    return liquid_glass.?;
}
var liquid_glass: ?bool = null;

/// The drag's overlay of the OS's glass (`overlayFrame`), while a view is carried.
var overlay: ?Carry = null;

/// Points within which the overlay's glass runs together (`NSGlassEffectContainerView`'s spacing),
/// where the frame says nothing else: the app's own merge distance (`DropZones.merge`). A drop's
/// bubbles rest just inside half of it from each other, so they rest joined by a thin neck, as the
/// app's glass draws them; a drop fitted smaller to a small place says its own, smaller
/// (`overlaySpacing`).
const overlay_spacing: f32 = fizzy.core.widgets.DropZones.merge;

/// Points within which the overlay's glass runs together this frame: what the frame declared
/// with its glass (`core.native_glass.mergeWithin`, physical), else `overlay_spacing`.
fn overlaySpacing(s: f32) f32 {
    const m = fizzy.core.native_glass.merge() orelse return overlay_spacing;
    return m / s;
}

/// A view drag's glass as the OS's (`nativeGlass`): an overlay window round the glass, on the main
/// window's display (`viewports.openOverlay`, `overlayArea`), holds a piece of Liquid Glass for each
/// piece the frame declared in place of drawing it (`core.native_glass`) — the drop zones' bubbles,
/// the carried drop, or its card — which the OS runs together where they come close, as it refracts
/// what is under them. The carried view's photograph lies under its drop's glass (`overlayPhoto`);
/// what goes over the glass — the drop's name, the bubbles' icons (`core.screens.markCarried`) — is
/// taken into the overlay's picture. Glass and pictures change in one transaction. It goes when the
/// drag does; a float the drop opens grows out of a carry window of its own (`growFrame`).
fn overlayFrame(state: *State) void {
    const d = &state.view_drag;
    // Kept past the drag while its drops still go, and gone once there is no glass left.
    if (!d.active() and fizzy.core.native_glass.shapes().len == 0) {
        if (overlay) |*o| releaseCarry(o);
        overlay = null;
        photo_sent = 0;
        overlay_area = null;
        return;
    }
    const cw = dvui.currentWindow();
    const display = viewports.displayInMain();
    if (display.w <= 0 or display.h <= 0) return;
    const main_px = dvui.windowRectPixels();
    const s = dvui.windowNaturalScale();
    const area = overlayArea(display, main_px, s) orelse return;
    if (overlay == null) {
        const vp = viewports.openOverlay(.{ .x = area.x, .y = area.y, .w = area.w, .h = area.h }) orelse return;
        overlay = .{ .viewport = vp };
    }
    const o = &overlay.?;
    const placed = viewports.placeMain(o.viewport, .{ .x = area.x, .y = area.y, .w = area.w, .h = area.h });
    const shown: dvui.Rect.Physical = .{ .x = placed.x, .y = placed.y, .w = placed.w, .h = placed.h };

    // The glass, in the overlay window's points — and where it lies over the main window's frame,
    // for the base over it.
    var glass: [fizzy.core.native_glass.max_shapes]viewports.GlassShape = undefined;
    var placed_shapes: [fizzy.core.native_glass.max_shapes]fizzy.core.native_glass.Shape = undefined;
    var n: usize = 0;
    for (fizzy.core.native_glass.shapes()) |sh| {
        const r = inMainFrame(sh.rect, main_px) orelse continue;
        placed_shapes[n] = sh;
        placed_shapes[n].rect = r;
        glass[n] = .{
            .x = (r.x - shown.x) / s,
            .y = (r.y - shown.y) / s,
            .w = r.w / s,
            .h = r.h / s,
            .radius = sh.radius / s,
            .lit = sh.lit,
            .alpha = sh.alpha,
            .frost = sh.frost,
        };
        n += 1;
    }
    const look = glassLook(std.math.clamp(fizzy.editor().window_opacity, 0, 1));
    const window_colour = base(false);
    const lit_toward = if (dvui.themeGet().dark) dvui.Color.white else dvui.Color.black;
    const spacing = overlaySpacing(s);
    viewports.overlayGlass(o.viewport, glass[0..n], spacing, .{
        .under = .{ .variant = look.under.variant, .style = look.under.style },
        .over = .{ .variant = look.over.variant, .style = look.over.style },
        .over_share = look.over_share,
        .glass = look.glass,
        .fill = window_colour,
        .fill_opacity = look.fill,
        .lit_toward = lit_toward,
        .lit_amount = glass_lit,
        .bevel = fizzy.core.glass_look.drop_bevel,
        .blur = look.blur,
        .bevel_cap = fizzy.core.glass_look.bevel_cap,
        .bevel_clear = fizzy.core.glass_look.bevel_clear,
    });
    overlayPhoto(o, d, shown, main_px, s);

    // The picture: what goes over the glass — the carried view, the drops' icons — each layer of it
    // (`core.screens.markCarried`) taken from the frame and replayed at the main window's part of it
    // and at each float window's band, where it lies over the main window: what is drawn in one of
    // them lands in the overlay, the rest outside it.
    const w: u32 = @intFromFloat(@max(1, @round(shown.w)));
    const h: u32 = @intFromFloat(@max(1, @round(shown.h)));
    if (o.target) |t| if (t.width != w or t.height != h) {
        t.destroyLater();
        o.target = null;
    };
    if (o.target == null) o.target = dvui.textureCreateTarget(.{ .width = w, .height = h, .interpolation = .nearest }) catch return;
    const target = o.target.?;
    target.clear();
    var rt = cw.render_target;
    rt.texture = target;
    rt.offset = .{ .x = shown.x, .y = shown.y };
    rt.rendering = true;
    const prev = dvui.renderTarget(rt);
    glassBase(placed_shapes[0..n], shown, s, spacing, look.top_fill);
    var offsets: [max_out + 1]dvui.Point.Physical = undefined;
    offsets[0] = .{ .x = shown.x, .y = shown.y };
    var n_off: usize = 1;
    for (covers[0..cover_count]) |cv| {
        offsets[n_off] = .{ .x = shown.x + (cv.band.x - cv.in_main.x), .y = shown.y + (cv.band.y - cv.in_main.y) };
        n_off += 1;
    }
    for (cw.subwindows.stack.items) |*sw| {
        if (!fizzy.core.screens.isCarried(sw.id)) continue;
        const cmds = sw.render_cmds;
        const after = sw.render_cmds_after;
        sw.render_cmds = .empty;
        sw.render_cmds_after = .empty;
        for (offsets[0..n_off]) |off| {
            rt.offset = off;
            _ = dvui.renderTarget(rt);
            cw.renderCommands(cmds.items) catch |err| dvui.logError(@src(), err, "replaying over the overlay's glass", .{});
            cw.renderCommands(after.items) catch |err| dvui.logError(@src(), err, "replaying over the overlay's glass", .{});
        }
    }
    _ = dvui.renderTarget(prev);
    viewports.present(o.viewport, target);
}

/// The window's colour over the OS's glass, in its shape, `fill` opaque (`glassLook`): only at the
/// very top of the slider, as the glass hands over to flat opaque colour — below that the colour
/// is under the glass, which bends and lights it (`viewports.overlayGlass`). In the shape the
/// pieces run together in (`core.liquid_blob.fill`, its smooth union over the overlay's spacing) and
/// in a little from their edges, where the OS's glass bends and lights its rim. The bubble a carried
/// view is aimed at lights in it, as a hovered bubble does — not by the glass's pressed look, which
/// the OS will not run together with its neighbours. `area` is the overlay's part of the frame.
fn glassBase(shapes: []const fizzy.core.native_glass.Shape, area: dvui.Rect.Physical, s: f32, spacing: f32, fill: f32) void {
    if (shapes.len == 0 or fill <= 0.002) return;
    const prev_clip = dvui.clipGet();
    defer dvui.clipSet(prev_clip);
    dvui.clipSet(area);
    const prev_alpha = dvui.alpha(1);
    defer dvui.alphaSet(prev_alpha);
    var color = base(false);
    color.a = @intFromFloat(@round(255 * std.math.clamp(fill, 0, 1)));
    // In from the glass's edge while there is glass to light it, out to it as the glass goes.
    const inset = glass_rim * s * (1 - std.math.clamp(fill, 0, 1));
    var discs: [fizzy.core.native_glass.max_shapes]fizzy.core.liquid_blob.Disc = undefined;
    var nd: usize = 0;
    for (shapes) |sh| {
        const r = sh.rect;
        const half = @min(r.w, r.h) / 2;
        var c = color;
        c.a = @intFromFloat(@round(@as(f32, @floatFromInt(c.a)) * std.math.clamp(sh.alpha, 0, 1)));
        if (sh.radius >= half - 0.5) {
            // Round: a disc of the union.
            if (half - inset <= 0) continue;
            discs[nd] = .{ .c = .{ .x = r.x + r.w / 2, .y = r.y + r.h / 2 }, .r = half - inset, .lit = sh.lit };
            nd += 1;
        } else if (c.a > 0) {
            // A card or a tab: a rounded rect of its own, nothing to run into.
            r.insetAll(inset).fill(.all(@max(0, sh.radius - inset)), .{ .color = .{ .color = c } });
        }
    }
    fizzy.core.liquid_blob.fill(discs[0..nd], spacing * s, s, color, 0, .white);
}

/// What the OS's glass is at the window's opacity (`Editor.window_opacity`): the one mapping every
/// glass reads (`core.glass_look`), the app's own glass on the same breakpoints.
const glassLook = fizzy.core.glass_look.native;

/// Points in from the OS's glass's edge the window's base stops (`glassBase`): its bent, lit rim.
const glass_rim: f32 = 2;
/// How much the bubble a carried view is aimed at lights, under the glass: lighter on a dark theme,
/// darker on a light one, as a hovered fill.
const glass_lit: f32 = 0.12;

/// `r` (physical, in the frame) where it lies over the main window's frame: as it is, or — drawn in
/// the band of a float's window, past the main window — where that part of the band lies, by the
/// window it overlaps most (`covers`). Null in a band no window shows.
/// What of the display the drag's overlay covers, in the main window's frame: round all its glass
/// (`core.native_glass.shapes`) — and the picture over it, which lies inside the glass — with room to
/// spare, on the display. Not the whole display: its picture is presented every frame of a drag, and
/// one the display's size, cleared and drawn and composited each frame, held a drag to half the
/// display's rate (60 frames a second where it could have 120). With the room to spare it moves
/// only when the glass reaches past it, or it is far bigger than the glass needs, rather than
/// every frame the drop moves. Null with no glass to cover.
fn overlayArea(display: anytype, main_px: dvui.Rect.Physical, s: f32) ?dvui.Rect.Physical {
    var glass: ?dvui.Rect.Physical = null;
    for (fizzy.core.native_glass.shapes()) |sh| {
        const r = inMainFrame(sh.rect, main_px) orelse continue;
        glass = if (glass) |g| g.unionWith(r) else r;
    }
    const need_core = glass orelse return overlay_area;
    const disp: dvui.Rect.Physical = .{ .x = display.x, .y = display.y, .w = display.w, .h = display.h };
    // Past the glass itself: its rim's light and the shadow it casts.
    const need = need_core.outsetAll(overlay_margin * s).intersect(disp);
    if (overlay_area) |a| {
        const inside = need.x >= a.x and need.y >= a.y and need.x + need.w <= a.x + a.w and need.y + need.h <= a.y + a.h;
        if (inside and a.w * a.h <= overlay_most * need.w * need.h) return a;
    }
    const room = @max(overlay_room * s, @max(need.w, need.h) * 0.25);
    const a = need.outsetAll(room).intersect(disp);
    overlay_area = a;
    return a;
}

/// Points round the glass the overlay covers (`overlayArea`), for what the glass draws past its
/// edge; and the room to spare it is given past that, at least; and how many times the area the
/// glass needs it may cover before it is made smaller.
const overlay_margin: f32 = 32;
const overlay_room: f32 = 160;
const overlay_most: f32 = 6;

var overlay_area: ?dvui.Rect.Physical = null;

fn inMainFrame(r: dvui.Rect.Physical, main_px: dvui.Rect.Physical) ?dvui.Rect.Physical {
    if (r.x <= main_px.x + main_px.w + 40000) return r;
    var best: ?Cover = null;
    var best_area: f32 = 0;
    for (covers[0..cover_count]) |cv| {
        const ov = cv.band.intersect(r);
        if (ov.w * ov.h > best_area) {
            best = cv;
            best_area = ov.w * ov.h;
        }
    }
    const cv = best orelse return null;
    return r.offsetPoint(.{ .x = cv.in_main.x - cv.band.x, .y = cv.in_main.y - cv.band.y });
}

/// A carry window's picture under way (`carryBegin`): the frame's own target to go back to, and
/// the part of the frame the window shows.
const CarryDrawing = struct {
    prev: dvui.RenderTarget,
    shown: dvui.Rect.Physical,
};

/// Put `c`'s window where it shows `place` of the main window's frame, in its shape (`radius`,
/// physical), `alpha` opaque, and start its picture, read from `shape` of the frame (the same rect,
/// or the band of a float's window it lies over): the main window's base under it `fill` (0…1)
/// opaque, over the window's material — none, and it is the material alone, which glass in it
/// reads as nothing. Drawn into it until `carryEnd`; null with nothing to draw into.
fn carryBegin(c: *Carry, place: dvui.Rect.Physical, shape: dvui.Rect.Physical, radius: f32, alpha: f32, fill: f32) ?CarryDrawing {
    const cw = dvui.currentWindow();
    const placed = viewports.placeMain(c.viewport, .{ .x = place.x, .y = place.y, .w = place.w, .h = place.h });
    // The part of the frame it shows: where it was put, read from where its picture is drawn.
    const shown: dvui.Rect.Physical = .{ .x = shape.x + (placed.x - place.x), .y = shape.y + (placed.y - place.y), .w = placed.w, .h = placed.h };
    viewports.carryShape(c.viewport, radius, alpha);
    const w: u32 = @intFromFloat(@max(1, @round(shown.w)));
    const h: u32 = @intFromFloat(@max(1, @round(shown.h)));
    if (c.target) |t| if (t.width != w or t.height != h) {
        t.destroyLater();
        c.target = null;
    };
    if (c.target == null) c.target = dvui.textureCreateTarget(.{ .width = w, .height = h, .interpolation = .nearest }) catch return null;
    const target = c.target.?;
    target.clear();
    var rt = cw.render_target;
    rt.texture = target;
    rt.offset = .{ .x = shown.x, .y = shown.y };
    rt.rendering = true;
    const prev = dvui.renderTarget(rt);
    {
        const prev_clip = dvui.clipGet();
        defer dvui.clipSet(prev_clip);
        dvui.clipSet(shown);
        const prev_alpha = cw.alpha;
        dvui.alphaSet(1);
        defer dvui.alphaSet(prev_alpha);
        if (fill > 0) {
            var color = base(false);
            color.a = @intFromFloat(@round(255 * std.math.clamp(fill, 0, 1)));
            shape.fill(dvui.CornerRect.Physical.all(radius), .{ .color = .{ .color = color } });
        }
    }
    return .{ .prev = prev, .shown = shown };
}

/// `carryBegin`'s picture done: handed to its window.
fn carryEnd(c: *Carry, drawing: CarryDrawing) void {
    _ = dvui.renderTarget(drawing.prev);
    if (c.target) |t| viewports.present(c.viewport, t);
}

fn releaseCarry(c: *Carry) void {
    viewports.close(c.viewport);
    if (c.target) |t| t.destroyLater();
    c.target = null;
}

/// A float made by a drop grows out of the carried glass into its window, as it grows into its
/// glass in the main window (`Floats.Landing`): its window shows nothing while the carried glass —
/// a carry window (`viewports.openCarry`), the drag's own when it had one, already where the drop
/// is — grows from the drop to the window's frame and rounds to its corners. What it carries changes
/// as it begins to grow, while it is small: the carried view's photograph goes, and the float's own
/// picture — what its window will show, last frame's — arrives in its place, filling the glass
/// with its proportions kept, so at the window's size it is the window's picture exactly, base and
/// all. Crossing the two at a size where each was laid out differently showed the text of both, at
/// two sizes. The glass grows as frost, as the window's own material is, not as the carried lens.
/// Landed, the window shows and the glass goes in the same frame: faded off a window already
/// showing under it, both bases at once made the window flare opaque at the end. How much of the
/// window shows. Where there are no carry windows, the window shows at once.
fn growFrame(o: *Out, f: *const Floats.Float) f32 {
    if (!viewports.carries) return 1;
    if (f.landing) |land| {
        if (o.grow == null) {
            const c = if (spare) |sp| blk: {
                spare = null;
                break :blk sp;
            } else blk: {
                const vp = viewports.openCarry(.{ .x = land.from.x, .y = land.from.y, .w = land.from.w, .h = land.from.h }) orelse return 1;
                break :blk Carry{ .viewport = vp };
            };
            viewports.carryLens(c.viewport, false);
            o.grow = .{ .carry = c };
        }
        const g = &o.grow.?;
        const into = viewports.inMain(o.viewport);
        const to: dvui.Rect.Physical = .{ .x = into.x, .y = into.y, .w = into.w, .h = into.h };
        const t = Floats.landedAt(land);
        const from = land.from;
        const rect: dvui.Rect.Physical = .{
            .x = std.math.lerp(from.x, to.x, t),
            .y = std.math.lerp(from.y, to.y, t),
            .w = @max(1, std.math.lerp(from.w, to.w, t)),
            .h = @max(1, std.math.lerp(from.h, to.h, t)),
        };
        const radius = std.math.lerp(land.radius, viewports.windowRadius() * dvui.windowNaturalScale(), std.math.clamp(t, 0, 1));
        // The float's picture over the first part of the growth, the photograph going as it comes.
        const arrive = smoothstep(std.math.clamp(Floats.landingFraction(land) / picture_share, 0, 1));
        // Where the OS draws the drag's glass, the window grows out of drops in it (`growDrops`),
        // and its own window comes in over the last of it, the drop's picture growing with it in
        // the overlay. Elsewhere its picture and colour are the carry window's, over the glass.
        const drops = nativeGlass();
        const window_in: f32 = if (drops) growDrops(land, rect, radius, to) else 0;
        if (drops) if (overlay) |*ov| liftOver(o, ov);
        // The window's colour comes in with the picture, as much of it as the window it grows into
        // will have (`windowShade`): with none, the glass ended lighter than that window, which
        // popped darker on the last frame as it took over (the user).
        const keep = 1 - window_in;
        if (drops) {
            // The drop's picture grows with it, from where it lay in the drop to the window's top
            // left at the size it was taken — the view as the window will show it, its own heading
            // where the window's header is — on the glass's own way there, and goes as the window
            // comes in over it (the user: it went as the drop was let go). The overlay holds its
            // image (`overlayPhoto`); the carry window has nothing of its own to show here.
            if (land.photo_from) |pf| {
                const b = to.insetAll(reach() * dvui.windowNaturalScale());
                const sz = land.photo_size;
                const body: dvui.Rect.Physical = .{ .x = b.x, .y = b.y, .w = sz.w, .h = sz.h };
                const k = std.math.clamp(t, 0, 1);
                // Frosted over as the glass grows round it, and clear again as the window comes in —
                // the view itself, there (the user: it then unblurs).
                const frosted = smoothstep(std.math.clamp(Floats.landingFraction(land) / frost_share, 0, 1));
                const look = glassLook(std.math.clamp(fizzy.editor().window_opacity, 0, 1));
                grow_photo = .{
                    .rect = rect,
                    .radius = radius,
                    // From the drag's touch of frost (`drop_photo_blur`), not from sharp.
                    .blur = @max(fizzy.core.glass_look.drop_photo_blur, look.blur * frosted) * keep,
                    .image = .{ .x = std.math.lerp(pf.x, body.x, k), .y = std.math.lerp(pf.y, body.y, k), .w = std.math.lerp(pf.w, body.w, k), .h = std.math.lerp(pf.h, body.h, k) },
                    .alpha = keep,
                };
            }
            return window_in;
        }
        if (!drawGrow(o, g, rect, radius, 1, windowShade() * arrive * keep, arrive * keep, if (land.photo) |tex| .{ .tex = tex, .size = land.photo_size, .fade = 1 - arrive } else null)) return 1;
        return window_in;
    }
    // Landed: the window shows, and the glass goes with it.
    if (o.grow) |*g| {
        releaseCarry(&g.carry);
        o.grow = null;
    }
    // Over the overlay for as long as it holds glass — the drop zones it was let go over still
    // going — and back at its own level once it is gone.
    if (o.lifted) {
        if (overlay) |*ov| liftOver(o, ov) else {
            viewports.settle(o.viewport);
            o.lifted = false;
        }
    }
    return 1;
}

/// The carried view's picture on the drag's glass (`core.native_glass.publishUnder`,
/// `ViewDrag.photo_under`): in the overlay, over its drop's frost — what the view shows and nothing
/// of its ground, on frosted glass as a bubble's icon is — fitted to what the view shows. Its image
/// goes over once a drag (`photo_gen`); after that it only moves, in the glass's transaction. A
/// window of its own for it, presented every frame, cost the compositor a third window a frame (the
/// user saw 40 fps).
fn overlayPhoto(o: *Carry, d: *const @FieldType(State, "view_drag"), shown: dvui.Rect.Physical, main_px: dvui.Rect.Physical, s: f32) void {
    defer grow_photo = null;
    // In the drop, as the drag carries it; or, the drag over, growing with the float its drop was
    // let go as (`growFrame`), from the image the drag handed over.
    const carried: ?PhotoPlace = if (d.active()) if (d.photo_under) |pu| if (d.photo_pixels) |px| blk: {
        if (photo_sent != d.photo_gen) {
            viewports.overlayPhotoImage(o.viewport, std.mem.sliceAsBytes(px), d.photo_size[0], d.photo_size[1]);
            photo_sent = d.photo_gen;
        }
        break :blk .{ .rect = pu.rect, .radius = pu.radius, .image = pu.image, .alpha = pu.alpha, .blur = fizzy.core.glass_look.drop_photo_blur };
    } else null else null else null;
    const p = carried orelse grow_photo orelse return hidePhoto(o);
    if (photo_sent == 0) return hidePhoto(o);
    const r = inMainFrame(p.rect, main_px) orelse return hidePhoto(o);
    viewports.overlayPhoto(o.viewport, .{
        .rect = .{ .x = (r.x - shown.x) / s, .y = (r.y - shown.y) / s, .w = r.w / s, .h = r.h / s },
        .radius = p.radius / s,
        .image = .{ .x = (p.image.x - p.rect.x) / s, .y = (p.image.y - p.rect.y) / s, .w = p.image.w / s, .h = p.image.h / s },
        // Its content alone, on the drop's frosted glass: no ground of its own, a touch out of focus
        // with the glass it is in (`glass_look.drop_photo_blur`), the frost under it the drop's, as
        // a bubble's is (the user).
        .fill = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .alpha = p.alpha,
        .blur = p.blur,
    });
}

/// Where the carried view's picture is on the drag's glass this frame (`overlayPhoto`), physical:
/// the glass it is in, its corners, where the whole picture lies, and how much of it shows.
const PhotoPlace = struct { rect: dvui.Rect.Physical, radius: f32, image: dvui.Rect.Physical, alpha: f32, blur: f32 = 0 };

/// The picture growing with a float out of the drop it was let go as (`growFrame`), this frame —
/// for the overlay's pass after the windows' (`overlayPhoto`). Null when none is.
var grow_photo: ?PhotoPlace = null;

/// Nothing of the picture shows this frame. Its image is kept: the frame a drop is let go as a float
/// shows none of it, and the frames after grow it with the float (`grow_photo`). It goes with the
/// overlay (`overlayFrame`), or for the next drag's.
fn hidePhoto(o: *Carry) void {
    viewports.overlayPhoto(o.viewport, null);
}

/// The picture whose image the overlay holds (`ViewDrag.photo_gen`); 0, none.
var photo_sent: u32 = 0;

/// A float's window born of a drop, over the drag's overlay (`overlayFrame`): under it, the glass
/// still in the overlay — the window growing out of it, the drop zones it was let go over going, in
/// the very place the window opens — bent the window's picture with its lens, its title folded back
/// on itself for a frame (the user). Over it, they go beneath the window.
fn liftOver(o: *Out, ov: *Carry) void {
    viewports.lift(o.viewport, ov.viewport);
    o.lifted = true;
}

/// How much of a float's window its colour covers, settled, at the window opacity: a window of
/// Liquid Glass's colour in its body and, at the top, over all of it (`core.glass_look.window`);
/// a window on vibrancy, its base's opacity (`Editor.windowBase`).
/// Drops a float's window grows out of, where the OS draws the drag's glass (`growDrops`): each the
/// point of the window it swells toward — shares of its width and height — its size a share of the
/// window's shorter side, and when in the growth it starts and how long it takes, shares of it. They
/// bud out of the growing glass at different times and sizes, ahead of it, and it takes them in as
/// it fills its window: a liquid growing rather than a rectangle scaling (the user).
const GrowSeed = struct {
    at: [2]f32,
    share: f32,
    start: f32,
    len: f32,
};

const grow_seeds = [_]GrowSeed{
    .{ .at = .{ 0.76, 0.24 }, .share = 0.2, .start = 0, .len = 0.55 },
    .{ .at = .{ 0.28, 0.74 }, .share = 0.16, .start = 0.08, .len = 0.5 },
    .{ .at = .{ 0.76, 0.76 }, .share = 0.23, .start = 0.16, .len = 0.55 },
    .{ .at = .{ 0.3, 0.3 }, .share = 0.13, .start = 0.04, .len = 0.45 },
};

/// How far through the growth its own window starts coming in over the glass, which goes as it
/// does: the window's glass is not the drag's, and a cut between them showed.
const grow_window_from: f32 = 0.7;

/// A float's growth as the OS's glass (`growFrame`): the growing glass `rect` (corners `radius`) and
/// the drops budding out of it toward the window `to` (`grow_seeds`), run together by the OS where
/// they come close, in the drag's overlay. Returns how far the window itself has come in over it,
/// all of the glass going by the same.
fn growDrops(land: Floats.Landing, rect: dvui.Rect.Physical, radius: f32, to: dvui.Rect.Physical) f32 {
    const tl = std.math.clamp(Floats.landingFraction(land), 0, 1);
    const window_in = smoothstep(std.math.clamp((tl - grow_window_from) / (1 - grow_window_from), 0, 1));
    const alpha = 1 - window_in;
    if (alpha <= 0.001) return window_in;
    const centre = rect.center();
    fizzy.core.native_glass.add(.{ .rect = rect, .radius = radius, .alpha = alpha });
    const side = @min(to.w, to.h);
    for (grow_seeds) |seed| {
        const u = std.math.clamp((tl - seed.start) / seed.len, 0, 1);
        if (u <= 0) continue;
        const r = side * seed.share * easeOutBack(u);
        if (r < 1) continue;
        const goal: dvui.Point.Physical = .{ .x = to.x + to.w * seed.at[0], .y = to.y + to.h * seed.at[1] };
        const e = smoothstep(u);
        const c: dvui.Point.Physical = .{ .x = std.math.lerp(centre.x, goal.x, e), .y = std.math.lerp(centre.y, goal.y, e) };
        fizzy.core.native_glass.add(.{ .rect = .{ .x = c.x - r, .y = c.y - r, .w = 2 * r, .h = 2 * r }, .radius = r, .alpha = alpha });
    }
    if (window_in < 1) dvui.refresh(null, @src(), null);
    return window_in;
}

/// Past 1 and back on the way in, as a drop swells and settles: by how much, at the app's motion
/// level (`core.motion`) — none where motion is minimal.
fn easeOutBack(u: f32) f32 {
    const play = std.math.clamp((fizzy.core.motion.level() - 0.5) * 2, 0, 1);
    const k: f32 = 1.4 * play;
    const v = u - 1;
    return 1 + (k + 1) * v * v * v + k * v * v;
}

fn windowShade() f32 {
    const op = std.math.clamp(fizzy.editor().window_opacity, 0, 1);
    if (!viewports.liquidGlass()) return op;
    const w = fizzy.core.glass_look.window(op);
    return 1 - (1 - w.fill) * (1 - w.top_fill);
}

/// The share of a float's growth out of the drop over which the drop's picture, growing with it,
/// frosts over (`growFrame`), before it clears as the window comes in.
const frost_share: f32 = 0.3;

/// The share of a float's growth out of the carried glass over which its picture takes over from
/// the carried photograph (`growFrame`).
const picture_share: f32 = 0.25;

/// A photograph a growing glass carries (`drawGrow`): the carried view's, at `fade`.
const GrowPhoto = struct {
    tex: dvui.Texture,
    size: dvui.Size.Physical,
    fade: f32,
};

/// `g`'s window at `rect` (physical, in the main window's frame) in `radius` corners, `alpha`
/// opaque: `fill` of the window's base over its material, the photograph, and `picture` (0…1) of
/// the float's own picture (`Out.target`, last frame's) scaled to it. False with nothing to draw
/// into.
fn drawGrow(o: *Out, g: *Grow, rect: dvui.Rect.Physical, radius: f32, alpha: f32, fill: f32, picture: f32, photo: ?GrowPhoto) bool {
    const drawing = carryBegin(&g.carry, rect, rect, radius, alpha, fill) orelse return false;
    // Its glass in the overlay (`growDrops`): none of its own.
    if (alpha <= 0) viewports.carryShape(g.carry.viewport, null, 1);
    defer carryEnd(&g.carry, drawing);
    const prev_clip = dvui.clipGet();
    defer dvui.clipSet(prev_clip);
    dvui.clipSet(drawing.shown);
    if (photo) |p| Floats.drawPhoto(p.tex, p.size, rect, .{ .x = rect.x, .y = rect.y, .w = rect.w }, radius, p.fade);
    if (picture > 0.01) if (o.target) |target| {
        const tex = dvui.Texture.fromTargetTemp(target) catch return true;
        const scale = dvui.windowNaturalScale();
        // Its proportions kept, filling the glass from its top left — where the window grows from
        // (`ViewDrag.floatOut`): at the window's size, all of it.
        var uv: dvui.Rect = .{ .x = 0, .y = 0, .w = 1, .h = 1 };
        const tw: f32 = @floatFromInt(target.width);
        const th: f32 = @floatFromInt(target.height);
        if (tw > 0 and th > 0 and rect.w > 0 and rect.h > 0) {
            const a_img = tw / th;
            const a_box = rect.w / rect.h;
            if (a_img > a_box) uv.w = a_box / a_img else uv.h = a_img / a_box;
        }
        dvui.renderTexture(tex, .{ .r = rect, .s = scale }, .{
            .corners = .round(radius / scale),
            .colormod = dvui.Color.white.opacity(picture),
            .uv = uv,
        }) catch {};
    };
    return true;
}

fn smoothstep(x: f32) f32 {
    return x * x * (3 - 2 * x);
}

fn windowFrame(state: *State, o: *Out) void {
    // Nothing to copy unless this frame drew it: a target let go this frame is gone by then.
    viewports.present(o.viewport, null);
    const i = find(state, o.serial) orelse return;
    const f = &state.floats.items.items[i];
    if (f.viewport == null or f.win_id == .zero) return;
    const cw = dvui.currentWindow();
    if (cw.subwindows.get(f.win_id) == null) return;
    const s = dvui.windowNaturalScale();
    // Where it was drawn this frame, on whole points: where its window goes, and the offset its
    // drawing is replayed at, so a pointer over the window lands on what it shows — grown or
    // shrunk by `reach`.
    const b = f.bounds.outsetAll(reach() * s);
    const shown = viewports.place(o.viewport, .{ .x = b.x, .y = b.y, .w = b.w, .h = b.h });
    const material = f.viewport.?.material;
    // Called what its header says — the view it shows — in the taskbar, the Window menu, the
    // window switcher.
    const title = f.titleText();
    if (title.len > 0 and !std.mem.eql(u8, title, o.title_buf[0..o.title_len])) {
        viewports.setTitle(o.viewport, title);
        @memcpy(o.title_buf[0..title.len], title);
        o.title_len = @intCast(title.len);
    }
    // How far in from its window's left edge the OS's own buttons reach, for its header to leave
    // them be (`Floats.Viewport.buttons_w`).
    f.viewport.?.buttons_w = viewports.buttonsWidth(o.viewport);
    // Where its window lies over the main window's frame, from where it is drawn in its band, for a
    // drag to read it there (`Floats.Viewport.main_delta`).
    {
        const band = viewports.frameOf(o.viewport);
        const at = viewports.inMain(o.viewport);
        f.viewport.?.main_delta = .{ .x = at.x - band.x, .y = at.y - band.y };
    }
    // Whether its window lies under the main window, for a drag over the main window to take no
    // account of it there (`Floats.Viewport.under_main`).
    f.viewport.?.under_main = viewports.underMain(o.viewport);
    // A view carried out of it: while it is its own ghost (`ViewDrag.settleGhost`), its window fades
    // to the ghost, material and all, and a held pointer over it reads the main window beneath — the
    // places it lies over can be seen and aimed at. Firm again, the pointer is the window's.
    {
        const d = &state.view_drag;
        const carried_out = d.active() and !d.loose() and if (state.floatRoot(d.name)) |root| std.mem.eql(u8, root, f.name) else false;
        const see_through = carried_out and !d.ghost_firm;
        viewports.seeThrough(o.viewport, see_through);
        // Where the window lies, for a view carried under or out of it (`carryFrame`).
        if (cover_count < covers.len) {
            const m = viewports.inMain(o.viewport);
            const band = viewports.frameOf(o.viewport);
            covers[cover_count] = .{
                .viewport = o.viewport,
                .in_main = .{ .x = m.x, .y = m.y, .w = m.w, .h = m.h },
                .band = .{ .x = band.x, .y = band.y, .w = band.w, .h = band.h },
            };
            cover_count += 1;
        }
        // Coming in under the carried glass as that grows into it (`growFrame`).
        const shown_share = growFrame(o, f);
        viewports.fade(o.viewport, shown_share * Floats.ghostLook(f.aside.at()).alpha);
    }
    // Where a press is the OS's: its header moves the window and its glass's edges resize it, so
    // the OS snaps, tiles and maximizes it as any window.
    {
        const margin = (fizzy.core.widgets.FloatingWindowWidget.defaults.margin orelse dvui.Rect{}).x;
        const glass = f.bounds.insetAll(margin * s);
        viewports.hints(o.viewport, .{
            .drag = .{ .x = f.header.x, .y = f.header.y, .w = f.header.w, .h = f.header.h },
            .keep = .{ .x = f.header_close.x, .y = f.header_close.y, .w = f.header_close.w, .h = f.header_close.h },
            .glass = .{ .x = glass.x, .y = glass.y, .w = glass.w, .h = glass.h },
            .edge = resize_edge * s,
            // The float's own resize zones, kept the app's over its header — where the OS resizes
            // the window from no edge (a borderless macOS window). A window the OS frames it resizes
            // from its edges itself, and the float resizes nothing (`viewports.os_frame`).
            .app_side = if (viewports.os_frame) 0 else float_side * s,
            .app_corner = if (viewports.os_frame) 0 else float_corner * s,
        });
    }
    const w: u32 = @intFromFloat(@max(1, @round(shown.w)));
    const h: u32 = @intFromFloat(@max(1, @round(shown.h)));
    if (o.target) |t| if (t.width != w or t.height != h) {
        t.destroyLater();
        o.target = null;
    };
    if (o.target == null) o.target = dvui.textureCreateTarget(.{ .width = w, .height = h, .interpolation = .nearest }) catch return;
    const target = o.target.?;

    // Transparent where the float is not: past its corners.
    target.clear();
    var rt = cw.render_target;
    rt.texture = target;
    rt.offset = .{ .x = shown.x, .y = shown.y };
    rt.rendering = true;
    const prev = dvui.renderTarget(rt);
    defer _ = dvui.renderTarget(prev);
    // Zoomed or full screen there is no desktop behind it: opaque, eased there and back with the
    // OS's transitions as the main window's base is. Where it has no material it is opaque
    // throughout.
    Editor.easeWindowOpacity(&o.opacity, viewports.coversDesktop(o.viewport), viewports.enteringSpace(o.viewport), viewports.spaceFullness(o.viewport), if (material) std.math.clamp(fizzy.editor().window_opacity, 0, 1) else 1);
    // A window of Liquid Glass (macOS 26) stands on its glass, its colour under it on the one
    // slider, as the main window does (`Editor.windowGlassLook`): no base of its own in the frame.
    if (!viewports.windowGlass(o.viewport, Editor.windowGlassLook(o.opacity.value, .{ .w = shown.w / s, .h = shown.h / s })))
        backing(.{ .x = shown.x, .y = shown.y, .w = shown.w, .h = shown.h }, b, o.opacity.value);
    // The float and everything opened in it — its menus, tooltips, popovers, placed on its
    // window's screen (`core.screens`), each a subwindow of its own — in the order dvui stacks
    // them, every one whose middle is in the window's part of the frame. Taken from each, so
    // dvui's replay into the main window draws nothing of them. And a layer drawn across every
    // screen (`core.screens.markEverywhere`: a view drag's drops) is copied in
    // too, left in place for the main window's replay — what of it lies outside the window's part
    // of the frame falls outside its target.
    const area: dvui.Rect.Physical = .{ .x = shown.x, .y = shown.y, .w = shown.w, .h = shown.h };
    for (cw.subwindows.stack.items) |*sw| {
        // A carried view is its carry window's (`carryFrame`); a menu, its own (`menuFrame`).
        if (fizzy.core.screens.isCarried(sw.id)) continue;
        if (fizzy.core.screens.isMenu(sw.id) and nativeMenus()) continue;
        const mine = area.contains(sw.rect_pixels.center());
        if (!mine and !fizzy.core.screens.isEverywhere(sw.id)) continue;
        const cmds = sw.render_cmds;
        const after = sw.render_cmds_after;
        if (mine) {
            sw.render_cmds = .empty;
            sw.render_cmds_after = .empty;
        }
        cw.renderCommands(cmds.items) catch |err| dvui.logError(@src(), err, "replaying a float into its window", .{});
        cw.renderCommands(after.items) catch |err| dvui.logError(@src(), err, "replaying a float into its window", .{});
    }
    viewports.present(o.viewport, target);
}

/// What the float out here stands on: the main window's base (`base`), as the main window's own
/// content does — all of its window where the OS frames it (`viewports.os_frame`), drawn as the main
/// window is; elsewhere behind its glass, inside the clear margin its shadow is drawn in, in the
/// glass's own corners, for the glass to read.
fn backing(target: dvui.Rect.Physical, window: dvui.Rect.Physical, opacity: f32) void {
    const margin = (fizzy.core.widgets.FloatingWindowWidget.defaults.margin orelse dvui.Rect{}).x;
    const bounds = window.insetAll((reach() + margin) * dvui.windowNaturalScale());
    const cw = dvui.currentWindow();
    const prev_clip = dvui.clipGet();
    defer dvui.clipSet(prev_clip);
    dvui.clipSet(target);
    const prev_alpha = cw.alpha;
    dvui.alphaSet(1);
    defer dvui.alphaSet(prev_alpha);
    const theme = dvui.themeGet();
    const corners = fizzy.core.dialogs.surfaceCorners().finalize(&theme).scale(cw.natural_scale, dvui.CornerRect.Physical);
    bounds.fill(corners, .{ .color = .{ .color = Editor.windowBase(opacity) } });
}

/// Whether menus are windows of their own (`menuFrame`): where the OS can show them (macOS), with
/// floats as windows, as the setting says (`Settings.native_menus`, `FIZZY_NATIVE_MENUS` over it).
fn nativeMenus() bool {
    if (comptime !viewports.menus) return false;
    if (!viewports.available()) return false;
    return envSwitch("FIZZY_NATIVE_MENUS") orelse fizzy.editor().app.settings.native_menus;
}

/// Whether dialogs are windows of their own (`menuFrame`): as menus are, as the setting says
/// (`Settings.native_dialogs`, `FIZZY_NATIVE_DIALOGS` over it).
fn nativeDialogs() bool {
    if (comptime !viewports.menus) return false;
    if (!viewports.available()) return false;
    return envSwitch("FIZZY_NATIVE_DIALOGS") orelse fizzy.editor().app.settings.native_dialogs;
}

/// The display the main window is on, natural, in the main window's frame: the screen menus are kept
/// on where they are windows of their own (`core.screens.publishMenus`).
fn displayNatural() dvui.Rect.Natural {
    const d = viewports.displayInMain();
    const s = dvui.windowNaturalScale();
    if (d.w <= 0 or d.h <= 0) return dvui.windowRect();
    return .{ .x = d.x / s, .y = d.y / s, .w = d.w / s, .h = d.h / s };
}

/// The least window opacity a menu's glass takes: a menu carries text, and over a clear window
/// there was too little behind it to read it by.
const menu_opacity_floor: f32 = 0.6;

/// Each open menu (`core.screens.markMenu`) in a window of its own (`viewports.openMenu`): the OS's
/// material in it, its shadow round it and its corners the menu's, above every window — the menu
/// drawn in it as the app draws it, its drawing taken whole out of the frame, so the main window and
/// the float windows draw none of it. In the main window's frame, past its edge too — its window the
/// main window's child, which the OS moves with it; or in the band of a float that is out, its
/// window over where that part of the band lies. A menu is drawn where it opened in its band, and
/// the float's window moving leaves it behind, so it closes then, as an OS menu closes on a press
/// outside it. A menu that closed takes its window with it.
///
/// Each open dialog (`core.screens.markDialog`) the same way, but in the main window's stacking
/// rather than above every window, its corners its own, and its window fading with it as it flies
/// shut. It stays where it is when a float it opened in moves; it has a place of its own.
fn menuFrame() void {
    for (&menus) |*slot| if (slot.*) |*m| {
        m.seen = false;
    };
    defer for (&menus) |*slot| if (slot.*) |*m| if (!m.seen) {
        releaseMenu(m);
        slot.* = null;
    };
    if (!nativeMenus() and !nativeDialogs()) return;
    const cw = dvui.currentWindow();
    const main_px = dvui.windowRectPixels();
    const s = dvui.windowNaturalScale();
    const theme = dvui.themeGet();
    const radius = fizzy.core.dialogs.surfaceCorners().finalize(&theme).tl.radius();
    for (cw.subwindows.stack.items) |*sw| {
        const as_dialog = fizzy.core.screens.dialog(sw.id);
        if (as_dialog == null and !fizzy.core.screens.isMenu(sw.id)) continue;
        const corner = if (as_dialog) |d| d.radius else radius;
        const frame = sw.rect_pixels;
        if (frame.w < 1 or frame.h < 1) continue;
        // Where its window lies over the main window: where the menu is, or — in a float's band —
        // where that part of the band lies on the screen.
        var place = frame;
        var float_at: ?dvui.Point.Physical = null;
        var float_vp: ?*viewports.Viewport = null;
        if (frame.x > main_px.x + main_px.w + 40000) {
            const cover = for (covers[0..cover_count]) |cv| {
                if (cv.band.contains(frame.center())) break cv;
            } else continue;
            place = frame.offsetPoint(.{ .x = cover.in_main.x - cover.band.x, .y = cover.in_main.y - cover.band.y });
            float_at = cover.band.topLeft();
            float_vp = cover.viewport;
        }
        // The window it moves with: the main window's, or for a dialog its float's; a menu in a
        // float is left behind by its window and closes (below). Where it lies over that window is
        // what places it again (`viewports.placeRiding`).
        const ride: viewports.Ride = if (float_vp) |fv| (if (as_dialog != null) .{ .viewport = fv } else .none) else .main;
        const key: dvui.Rect.Physical = if (float_at) |at| .{ .x = frame.x - at.x, .y = frame.y - at.y, .w = frame.w, .h = frame.h } else frame;
        const m = menuOut(sw.id, place, corner, ride, as_dialog != null) orelse {
            // No window for a dialog out in a float's band: over the main window instead, where it
            // is drawn in the main window — out there nothing would show it, modal over all.
            if (as_dialog != null and float_at != null) {
                var rect = dvui.dataGet(null, sw.id, "_rect", dvui.Rect) orelse continue;
                const main = dvui.windowRect();
                rect.x = main.x + (main.w - rect.w) / 2;
                rect.y = main.y + (main.h - rect.h) / 2;
                dvui.dataSet(null, sw.id, "_rect", rect);
            }
            continue;
        };
        m.seen = true;
        m.dialog = as_dialog != null;
        if (m.dialog) {
            if (m.float_at == null) m.float_at = float_at;
            m.float_vp = float_vp;
        }
        if (as_dialog) |d| viewports.fade(m.viewport, d.alpha);
        if (as_dialog == null) if (float_at) |at| {
            const was = m.float_at orelse at;
            m.float_at = at;
            if (@abs(at.x - was.x) > 0.5 or @abs(at.y - was.y) > 0.5) menus_left_behind = true;
        };
        viewports.mainOffset(m.viewport, .{ .x = frame.x - place.x, .y = frame.y - place.y });
        const placed = viewports.placeRiding(m.viewport, .{ .x = place.x, .y = place.y, .w = place.w, .h = place.h }, .{ .x = key.x, .y = key.y, .w = key.w, .h = key.h });
        const shown: dvui.Rect.Physical = .{ .x = frame.x + (placed.x - place.x), .y = frame.y + (placed.y - place.y), .w = placed.w, .h = placed.h };
        // Its material: Liquid Glass on the slider, no lighter than a menu's text needs; vibrancy
        // before macOS 26, with the window's colour drawn under the menu.
        const op = @max(std.math.clamp(fizzy.editor().window_opacity, 0, 1), menu_opacity_floor);
        var look = Editor.windowGlassLook(op, .{ .w = shown.w / s, .h = shown.h / s });
        look.radius = corner;
        m.glass = viewports.windowGlass(m.viewport, look);
        const w: u32 = @intFromFloat(@max(1, @round(shown.w)));
        const h: u32 = @intFromFloat(@max(1, @round(shown.h)));
        if (m.target) |t| if (t.width != w or t.height != h) {
            t.destroyLater();
            m.target = null;
        };
        if (m.target == null) m.target = dvui.textureCreateTarget(.{ .width = w, .height = h, .interpolation = .nearest }) catch continue;
        const target = m.target.?;
        target.clear();
        var rt = cw.render_target;
        rt.texture = target;
        rt.offset = .{ .x = shown.x, .y = shown.y };
        rt.rendering = true;
        const prev = dvui.renderTarget(rt);
        defer _ = dvui.renderTarget(prev);
        if (!m.glass) {
            const prev_clip = dvui.clipGet();
            defer dvui.clipSet(prev_clip);
            dvui.clipSet(shown);
            const prev_alpha = cw.alpha;
            dvui.alphaSet(1);
            defer dvui.alphaSet(prev_alpha);
            frame.fill(dvui.CornerRect.Physical.all(corner * s), .{ .color = .{ .color = Editor.windowBase(op) } });
        }
        const cmds = sw.render_cmds;
        const after = sw.render_cmds_after;
        sw.render_cmds = .empty;
        sw.render_cmds_after = .empty;
        cw.renderCommands(cmds.items) catch |err| dvui.logError(@src(), err, "replaying a menu into its window", .{});
        cw.renderCommands(after.items) catch |err| dvui.logError(@src(), err, "replaying a menu into its window", .{});
        _ = dvui.renderTarget(prev);
        viewports.present(m.viewport, target);
    }
}

/// A dialog opened in a float that is out goes with it, as a dialog belongs to the window it opened
/// in: its float's window moved — dragged, snapped — and the dialog is put where it lies over the
/// float as before, before it draws, so its window, the float's child, is where the OS carried it
/// (`viewports.placeRiding`). Its float gone, it comes back over the main window rather than be
/// left where no window shows it, modal over everything.
fn dialogsRide() void {
    const s = dvui.windowNaturalScale();
    for (&menus) |*slot| if (slot.*) |*m| {
        if (!m.dialog) continue;
        const was = m.float_at orelse continue;
        const vp = m.float_vp orelse continue;
        var rect = dvui.dataGet(null, m.id, "_rect", dvui.Rect) orelse continue;
        const cover = for (covers[0..cover_count]) |cv| {
            if (cv.viewport == vp) break cv;
        } else {
            const main = dvui.windowRect();
            rect.x = main.x + (main.w - rect.w) / 2;
            rect.y = main.y + (main.h - rect.h) / 2;
            dvui.dataSet(null, m.id, "_rect", rect);
            m.float_at = null;
            m.float_vp = null;
            continue;
        };
        const at = cover.band.topLeft();
        if (at.x == was.x and at.y == was.y) continue;
        rect.x += (at.x - was.x) / s;
        rect.y += (at.y - was.y) / s;
        dvui.dataSet(null, m.id, "_rect", rect);
        m.float_at = at;
    };
}

/// Menu `id`'s window (`menuFrame`), opened at `place` (physical, in the main window's frame) where
/// it has none yet — riding on `ride`; a dialog's (`dialog`) in that window's stacking. Null where
/// no more windows can be opened: the menu is drawn in its window then.
fn menuOut(id: dvui.Id, place: dvui.Rect.Physical, radius: f32, ride: viewports.Ride, dialog: bool) ?*MenuOut {
    for (&menus) |*slot| if (slot.*) |*m| if (m.id == id) return m;
    for (&menus) |*slot| if (slot.* == null) {
        const vp = viewports.openMenu(.{ .x = place.x, .y = place.y, .w = place.w, .h = place.h }, radius, ride, dialog) orelse return null;
        slot.* = .{ .id = id, .viewport = vp };
        return &slot.*.?;
    };
    return null;
}

fn releaseMenu(m: *MenuOut) void {
    viewports.close(m.viewport);
    if (m.target) |t| t.destroyLater();
    m.target = null;
}

/// The main window's base (`Editor.windowBase`) at the window's opacity where it has a material,
/// opaque where it has none — the same colour as the main window's, side by side. The opacity as it
/// is windowed (`Editor.window_opacity`), not the main window's eased one, which goes opaque while
/// the main window is maximized: out here it is windowed.
fn base(material: bool) dvui.Color {
    return Editor.windowBase(if (material) std.math.clamp(fizzy.editor().window_opacity, 0, 1) else 1);
}
