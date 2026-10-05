//! The pop-out plan's viewports (`docs/POPOUT_WINDOWS_PLAN.md`), behind `FIZZY_POPOUT=1` on
//! fizzy's native backend: where the platform has OS windows a float is one, from the frame it is
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

const Cover = struct {
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
    /// Its base's opacity, eased between windowed and maximized as the main window's is
    /// (`Editor.easeWindowOpacity`); below 0 before its first frame.
    opacity: f32 = -1,
};

const Grow = struct {
    carry: Carry,
};

/// `FIZZY_POPOUT=1`, on a backend with viewports, where this run can open them (not Wayland).
pub fn enabled() bool {
    if (comptime builtin.target.cpu.arch == .wasm32 or !viewports.supported) return false;
    if (env_on == null) {
        const raw = std.c.getenv("FIZZY_POPOUT");
        env_on = if (raw) |r| !std.mem.eql(u8, std.mem.span(r), "0") and viewports.available() else false;
    }
    return env_on.?;
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
    fizzy.core.screens.publishBeyond(viewports.carries and state.view_drag.active());
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
    carryFrame(state);
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
    // What it is carried as: the card or tab, or a drop — round its head, drawn out toward its
    // tail as that lags on its spring, so a drop carried fast stretches out behind the pointer and
    // swings back past it when it stops, as it did run together in the app's glass.
    const shape = if (d.drop_n > 1) d.shape_rect.unionWith(d.drop_shapes[1].rect) else d.shape_rect;
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
/// (`docs/NATIVE_WINDOWS_PLAN.md`). `FIZZY_NATIVE_GLASS=0` keeps the app's.
var native_env: ?bool = null;
fn nativeGlass() bool {
    if (comptime builtin.target.cpu.arch == .wasm32 or !viewports.carries) return false;
    if (native_env == null) {
        const raw = std.c.getenv("FIZZY_NATIVE_GLASS");
        const asked_off = if (raw) |r| std.mem.eql(u8, std.mem.span(r), "0") else false;
        native_env = !asked_off and viewports.liquidGlass();
    }
    return native_env.?;
}

/// The drag's overlay of the OS's glass (`overlayFrame`), while a view is carried.
var overlay: ?Carry = null;

/// Points within which the overlay's glass runs together (`NSGlassEffectContainerView`'s spacing):
/// the app's own merge distance (`DropZones.merge`), past the gap between a drop's bubbles (16
/// points at their size), so they run partly together and the carried drop into them readily.
const overlay_spacing: f32 = fizzy.core.widgets.DropZones.merge;

/// A view drag's glass as the OS's (`nativeGlass`): an overlay window over the main window's display
/// (`viewports.openOverlay`) holds a piece of Liquid Glass for each piece the frame declared in
/// place of drawing it (`core.native_glass`) — the drop zones' bubbles, the carried drop's head and
/// tail, or its card — which the OS runs together where they come close, as it refracts what is
/// under them. The carried view's own layer (`core.screens.markCarried`), its photograph, is taken
/// into the overlay over its glass. Glass and picture change in one transaction. It goes when the
/// drag does; a float the drop opens grows out of a carry window of its own (`growFrame`).
fn overlayFrame(state: *State) void {
    const d = &state.view_drag;
    // Kept past the drag while its drops still go, and gone once there is no glass left.
    if (!d.active() and fizzy.core.native_glass.shapes().len == 0) {
        if (overlay) |*o| releaseCarry(o);
        overlay = null;
        return;
    }
    const cw = dvui.currentWindow();
    const display = viewports.displayInMain();
    if (display.w <= 0 or display.h <= 0) return;
    if (overlay == null) {
        const vp = viewports.openOverlay(display) orelse return;
        overlay = .{ .viewport = vp };
    }
    const o = &overlay.?;
    const placed = viewports.placeMain(o.viewport, display);
    const shown: dvui.Rect.Physical = .{ .x = placed.x, .y = placed.y, .w = placed.w, .h = placed.h };
    const main_px = dvui.windowRectPixels();
    const s = dvui.windowNaturalScale();

    // The glass, in the overlay window's points.
    var glass: [fizzy.core.native_glass.max_shapes]viewports.GlassShape = undefined;
    var n: usize = 0;
    for (fizzy.core.native_glass.shapes()) |sh| {
        const r = inMainFrame(sh.rect, main_px) orelse continue;
        glass[n] = .{
            .x = (r.x - shown.x) / s,
            .y = (r.y - shown.y) / s,
            .w = r.w / s,
            .h = r.h / s,
            .radius = sh.radius / s,
            .lit = sh.lit,
            .alpha = sh.alpha,
        };
        n += 1;
    }
    viewports.overlayGlass(o.viewport, glass[0..n], overlay_spacing);

    // The picture: the carried view's layer, drawn where the carried view is — in the band of the
    // float's window it is over, read from there. After the drag, none.
    const band_delta: dvui.Point.Physical = if (d.active()) delta: {
        const at = inMainFrame(d.shape_rect, main_px) orelse d.shape_rect;
        break :delta .{ .x = d.shape_rect.x - at.x, .y = d.shape_rect.y - at.y };
    } else .{};
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
    rt.offset = .{ .x = shown.x + band_delta.x, .y = shown.y + band_delta.y };
    rt.rendering = true;
    const prev = dvui.renderTarget(rt);
    for (cw.subwindows.stack.items) |*sw| {
        if (!fizzy.core.screens.isCarried(sw.id)) continue;
        const cmds = sw.render_cmds;
        const after = sw.render_cmds_after;
        sw.render_cmds = .empty;
        sw.render_cmds_after = .empty;
        cw.renderCommands(cmds.items) catch |err| dvui.logError(@src(), err, "replaying a carried view into the overlay", .{});
        cw.renderCommands(after.items) catch |err| dvui.logError(@src(), err, "replaying a carried view into the overlay", .{});
    }
    _ = dvui.renderTarget(prev);
    viewports.present(o.viewport, target);
}

/// `r` (physical, in the frame) where it lies over the main window's frame: as it is, or — drawn in
/// the band of a float's window, past the main window — where that part of the band lies, by the
/// window it overlaps most (`covers`). Null in a band no window shows.
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
        // The base comes in with the picture, which has its own.
        if (!drawGrow(o, g, rect, radius, 1, 0, arrive, if (land.photo) |tex| .{ .tex = tex, .size = land.photo_size, .fade = 1 - arrive } else null)) return 1;
        return 0;
    }
    // Landed: the window shows, and the glass goes with it.
    if (o.grow) |*g| {
        releaseCarry(&g.carry);
        o.grow = null;
    }
    return 1;
}

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
    // Zoomed or full screen there is no desktop behind it: opaque, eased there and back as the main
    // window's base is — opaque through the whole of the way out of a fullscreen Space. Where it has
    // no material it is opaque throughout.
    Editor.easeWindowOpacity(&o.opacity, viewports.maximized(o.viewport), if (material) std.math.clamp(fizzy.editor().window_opacity, 0, 1) else 1);
    backing(.{ .x = shown.x, .y = shown.y, .w = shown.w, .h = shown.h }, b, o.opacity);
    // The float and everything opened in it — its menus, tooltips, popovers, placed on its
    // window's screen (`core.screens`), each a subwindow of its own — in the order dvui stacks
    // them, every one whose middle is in the window's part of the frame. Taken from each, so
    // dvui's replay into the main window draws nothing of them. And a layer drawn across every
    // screen (`core.screens.markEverywhere`: a view drag's drops) is copied in
    // too, left in place for the main window's replay — what of it lies outside the window's part
    // of the frame falls outside its target.
    const area: dvui.Rect.Physical = .{ .x = shown.x, .y = shown.y, .w = shown.w, .h = shown.h };
    for (cw.subwindows.stack.items) |*sw| {
        // A carried view is its carry window's (`carryFrame`).
        if (fizzy.core.screens.isCarried(sw.id)) continue;
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

/// The main window's base (`Editor.windowBase`) at the window's opacity where it has a material,
/// opaque where it has none — the same colour as the main window's, side by side. The opacity as it
/// is windowed (`Editor.window_opacity`), not the main window's eased one, which goes opaque while
/// the main window is maximized: out here it is windowed.
fn base(material: bool) dvui.Color {
    return Editor.windowBase(if (material) std.math.clamp(fizzy.editor().window_opacity, 0, 1) else 1);
}
