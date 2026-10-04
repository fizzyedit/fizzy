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
const State = @import("app").layout.State;

const viewports = fizzy.backend.viewports;
const Frost = fizzy.core.widgets.BlurBackdrop;
const Floats = @import("app").layout.Layout.Floats;

/// The most floats out at once — the backend's viewports (`SDLBackend.max_viewports`). One more
/// stays in the main window.
const max_out = 8;

/// Each float's window, by its float (`Out.serial`).
var outs: [max_out]?Out = @splat(null);
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
    /// What stands behind its glass, for its frost to read (`behindGlass`): made as the frost asks.
    behind: ?dvui.Texture.Target = null,
    /// This frame's part of the frame its window shows, and whether its window has a material:
    /// for `behindGlass`, called from the replay.
    area: dvui.Rect.Physical = .{},
    material: bool = false,
    /// Where its window was over the main window last frame (`viewports.inMain`), for the hole
    /// under its glass to keep out of where the window is leaving (`endFrame`).
    last_at: ?dvui.Rect.Physical = null,
    /// The main window directly behind its window this frame: nothing stacked between them over it
    /// (`viewports.mainBehind`). Only then does its glass read the main window's picture.
    main_behind: bool = true,
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
    if (o.behind) |t| t.destroyLater();
    o.behind = null;
}

/// After the frame has drawn and before dvui replays the subwindows into the main window's frame
/// (`core.FrameTarget.end`): each float is replayed into its window's target instead, its window
/// put where it was drawn, and handed the picture.
pub fn endFrame(state: *State) void {
    if (!enabled()) return;
    for (&outs) |*slot| {
        if (slot.*) |*o| windowFrame(state, o);
    }
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

    // With another window stacked between the main window and this one over it, what lies behind
    // the glass is that window, which nothing of fizzy's sees: the window's material shows it, and
    // the glass reads no picture of the main window, nor does the main window leave a hole —
    // reading it showed the main window through the window in between.
    o.main_behind = viewports.mainBehind(o.viewport);
    // Where the main window lies under its window, the main window leaves a hole in its picture
    // under the glass, and its window's material is kept off it (`viewports.mainHole`): the
    // float's glass shows through itself what is behind the main window there — its own material,
    // the desktop blurred — as the glass does in the main window, rather than the main window's
    // picture again, or its material tinted twice. Not before its window has shown a frame —
    // where it does not come up with its first picture (`viewports.shows_atomically`): it is not
    // there to show anything through yet.
    {
        const cut = o.main_behind and (viewports.shown(o.viewport) or viewports.shows_atomically);
        if (viewports.mainHole(o.viewport, cut) and cut) {
            const margin = (fizzy.core.widgets.FloatingWindowWidget.defaults.margin orelse dvui.Rect{}).x;
            const at_v = viewports.inMain(o.viewport);
            const at: dvui.Rect.Physical = .{ .x = at_v.x, .y = at_v.y, .w = at_v.w, .h = at_v.h };
            var hole = at.insetAll((reach() + margin) * s);
            // The OS moves its window (by its header, a snap) and the window server moves the main
            // window under it: the window is where it is when this frame reaches the screen, a frame
            // or two after where it was read, and a hole the size of its glass trailed it by a sliver
            // of nothing. Cut in from the side it is moving away from, by twice what it moved since
            // last frame; whole again once it rests.
            if (o.last_at) |was| {
                const dx = at.x - was.x;
                const dy = at.y - was.y;
                const left = @max(0, dx) * 2;
                const right = @max(0, -dx) * 2;
                const top = @max(0, dy) * 2;
                const bottom = @max(0, -dy) * 2;
                hole.x += left;
                hole.w -= left + right;
                hole.y += top;
                hole.h -= top + bottom;
                if (dx != 0 or dy != 0) dvui.refresh(null, @src(), null);
            }
            o.last_at = at;
            if (hole.w > 0 and hole.h > 0) {
                const theme = dvui.themeGet();
                fizzy.core.FrameTarget.hole(hole, fizzy.core.dialogs.surfaceCorners().finalize(&theme), s);
            }
        }
    }

    // Transparent where the float is not: past its corners.
    target.clear();
    var rt = cw.render_target;
    rt.texture = target;
    rt.offset = .{ .x = shown.x, .y = shown.y };
    rt.rendering = true;
    const prev = dvui.renderTarget(rt);
    defer _ = dvui.renderTarget(prev);
    backing(.{ .x = shown.x, .y = shown.y, .w = shown.w, .h = shown.h }, b, material);
    // Its glass reads what stands behind it in the main window, not this target (`behindGlass`).
    o.area = .{ .x = shown.x, .y = shown.y, .w = shown.w, .h = shown.h };
    o.material = material;
    Frost.behind = .{ .id = f.win_id, .ctx = o, .picture = behindGlass };
    defer Frost.behind = null;
    // The float and everything opened in it — its menus, tooltips, popovers, placed on its
    // window's screen (`core.screens`), each a subwindow of its own — in the order dvui stacks
    // them, every one whose middle is in the window's part of the frame. Taken from each, so
    // dvui's replay into the main window draws nothing of them. And a layer drawn across every
    // screen (`core.screens.markEverywhere`: a view drag's drops and carried glass) is copied in
    // too, left in place for the main window's replay — what of it lies outside the window's part
    // of the frame falls outside its target.
    const area: dvui.Rect.Physical = .{ .x = shown.x, .y = shown.y, .w = shown.w, .h = shown.h };
    for (cw.subwindows.stack.items) |*sw| {
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

/// Hybrid frost (`docs/POPOUT_WINDOWS_PLAN.md`): what the float's glass reads out here
/// (`Frost.Behind`) — what it reads in the main window. Where the main window lies under the
/// float's window, the main window's own picture of this frame; past the main window's edge, where
/// the desktop is and nothing of fizzy's can see it, the main window's base as it would be there
/// (`base`). Over `rect` whole, the margin past the glass's rim included, so the rim bends and
/// lights what lies beyond it as it does in the main window — this target holds the window's clear
/// margin there, and glass reading it drew a flat blur, its rim bent into nothing. Never shown.
///
/// The picture is the frame drawn so far — the layout, its places and views — not the deferred
/// subwindows (another float, a dialog) under this one.
fn behindGlass(ctx: ?*anyopaque, rect: dvui.Rect.Physical) ?Frost.Behind.Picture {
    const o: *Out = @ptrCast(@alignCast(ctx orelse return null));
    const cw = dvui.currentWindow();
    const w: u32 = @intFromFloat(@max(1, @round(rect.w)));
    const h: u32 = @intFromFloat(@max(1, @round(rect.h)));
    if (o.behind) |t| if (t.width != w or t.height != h) {
        t.destroyLater();
        o.behind = null;
    };
    if (o.behind == null) o.behind = dvui.textureCreateTarget(.{ .width = w, .height = h, .interpolation = .nearest }) catch return null;
    const target = o.behind.?;
    var rt = cw.render_target;
    rt.texture = target;
    rt.offset = rect.topLeft();
    rt.rendering = true;
    const prev = dvui.renderTarget(rt);
    defer _ = dvui.renderTarget(prev);
    const prev_clip = dvui.clipGet();
    defer dvui.clipSet(prev_clip);
    dvui.clipSet(rect);
    const prev_alpha = cw.alpha;
    dvui.alphaSet(1);
    defer dvui.alphaSet(prev_alpha);

    target.clear();
    rect.fill(.{}, .{ .color = .{ .color = base(o.material) } });
    mainPicture: {
        if (!o.main_behind) break :mainPicture;
        const tex = fizzy.core.FrameTarget.frameTexture() orelse break :mainPicture;
        // Where the window's part of the frame is over the main window, in the main window's frame.
        const r = viewports.inMain(o.viewport);
        const at_main: dvui.Rect.Physical = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
        // The main window, in the frame the window's part is in: shifted by where that part is.
        const main_px = dvui.windowRectPixels();
        const main_here: dvui.Rect.Physical = .{ .x = main_px.x + o.area.x - at_main.x, .y = main_px.y + o.area.y - at_main.y, .w = main_px.w, .h = main_px.h };
        const clip = rect.intersect(main_here);
        if (clip.w < 1 or clip.h < 1) break :mainPicture;
        dvui.clipSet(clip);
        // A copy, not a blend: the picture already holds the main window's base, as see-through
        // as the main window is.
        const copy = if (dvui.Backend.support_texture_blend) blk: {
            cw.backend.textureBlend(tex, .copy) catch break :blk false;
            break :blk true;
        } else false;
        defer if (copy) cw.backend.textureBlend(tex, .over) catch {};
        dvui.renderTexture(tex, .{ .r = main_here, .s = 1 }, .{}) catch {};
    }
    return .{ .texture = dvui.Texture.fromTargetTemp(target) catch return null, .origin = rect.topLeft() };
}

/// What the float out here stands on: the main window's base (`base`) behind its glass, inside the
/// margin its shadow is drawn in, in the glass's own corners — what the glass's frost, which
/// replaces what it covers, lies over at its rim's one-pixel fade. The frost reads `behindGlass`.
fn backing(target: dvui.Rect.Physical, window: dvui.Rect.Physical, material: bool) void {
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
    bounds.fill(corners, .{ .color = .{ .color = base(material) } });
}

/// The main window's base: its chrome, at the window's opacity over the window's material where it
/// has one, opaque where it has none.
fn base(material: bool) dvui.Color {
    var color = fizzy.core.dialogs.style().chromeColor();
    // The window's opacity as it is windowed (`Editor.window_opacity`), not the main window's
    // eased one, which goes opaque while the main window is maximized: out here it is windowed.
    color.a = if (material) @intFromFloat(@round(255 * std.math.clamp(fizzy.editor().window_opacity, 0, 1))) else 255;
    return color;
}
