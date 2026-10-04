//! The pop-out plan's viewports (`docs/POPOUT_WINDOWS_PLAN.md`), behind `FIZZY_POPOUT=1` on
//! fizzy's native backend. A float dragged past the main window's edge splits out into an OS window
//! of its own (a viewport, `fizzy.backend.viewports`), and merges back let go wholly inside it, as
//! Dear ImGui's viewports do. "Pop Out Float" takes the topmost float out, or brings the one out
//! back, and so does the OS asking that window to close.
//!
//! There stays one `dvui.Window`. Out, the float is drawn in its viewport's band of the frame,
//! past the main window's edge (`Floats.Viewport`), where no pointer over the main window reaches
//! it. At the end of the frame its subwindow's queued drawing is taken before dvui replays the
//! subwindows into the main window's frame, and replayed instead into a target of its own at the
//! band's offset (`endFrame`), which the backend copies into the OS window with the main window's
//! frame; the pointer over that window goes back to dvui where the window shows it. No dvui
//! change: `Window.renderCommands` is public, and fizzy runs dvui's end-of-frame replay itself
//! (`core.FrameTarget.end`), so a float's commands are fizzy's to take first.

const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const fizzy = @import("../fizzy.zig");
const State = @import("app").layout.State;

const viewports = fizzy.backend.viewports;
const Floats = @import("app").layout.Layout.Floats;

/// The float out of the main window, while one is. One at a time, in the spike.
var out: ?Out = null;
/// "Pop Out Float" ran: done at the start of the next frame (`beginFrame`), before the floats are
/// drawn, so a float is drawn in one place a frame.
var toggle_requested = false;
var env_on: ?bool = null;

const Out = struct {
    /// Which float: its serial, never handed to another (`Floats.Float.serial`) — its name is
    /// the next float's once it closes.
    serial: u64,
    viewport: *viewports.Viewport,
    /// Its part of the frame, drawn every frame for its window.
    target: ?dvui.Texture.Target = null,
    /// Where the float is drawn while its window shows it: settled into the viewport's band
    /// (`Floats.Float.viewport`), or split out of the main window under a drag of its header or
    /// edges and not let go yet — still in the main window's frame, where the drag goes on
    /// (`Floats.Float.split`), so its coordinates never change under the drag.
    mode: enum { band, held } = .band,
    /// Its window was being moved or resized last frame: a release now ends that drag.
    was_held: bool = false,
    /// What its window is called now: the float's title, as its header says (`Floats.Float.titleText`).
    title_buf: [96]u8 = undefined,
    title_len: u8 = 0,
};

/// A window whose float has come back into the main window: let go a frame later, once the main
/// window has drawn the float — so it is never on screen in neither, nor blinks out between them.
var closing: ?Out = null;

/// `FIZZY_POPOUT=1`, on a backend with viewports, where this run can open them (not Wayland).
pub fn enabled() bool {
    if (comptime builtin.target.cpu.arch == .wasm32 or !viewports.supported) return false;
    if (env_on == null) {
        const raw = std.c.getenv("FIZZY_POPOUT");
        env_on = if (raw) |r| !std.mem.eql(u8, std.mem.span(r), "0") and viewports.available() else false;
    }
    return env_on.?;
}

/// The command: the topmost float out, or the one out back in.
pub fn toggle() void {
    toggle_requested = true;
    dvui.refresh(null, @src(), null);
}

/// Whether there is a float to take out, or one out to bring back.
pub fn canToggle(state: *const State) bool {
    return out != null or topmost(state) != null;
}

/// The float in front that can go out: drawn, settled, and not on its way anywhere else.
fn topmost(state: *const State) ?usize {
    var i = state.floats.items.items.len;
    while (i > 0) : (i -= 1) {
        const f = state.floats.items.items[i - 1];
        if (f.closing or f.fresh or f.landing != null or f.aside.to > 0) continue;
        if (f.win_id == .zero or f.bounds.w < 1 or f.bounds.h < 1) continue;
        return i - 1;
    }
    return null;
}

/// Before the frame draws anything: a float asked out goes out, the one asked back — or whose
/// window the OS asked to close — comes back, and a window whose float has gone goes too. And,
/// as Dear ImGui's viewports do, a float dragged past the main window's edge splits out into a
/// window of its own, and one let go wholly inside the main window merges back into it — with
/// no transition: its window shows it exactly where it was drawn, before and after.
pub fn beginFrame(state: *State) void {
    if (!enabled()) return;
    defer toggle_requested = false;
    // Whatever happened, the screens floating things are placed on this frame: the window out,
    // if there is one, besides the main window's (`core.screens`).
    defer publishScreens();
    // And where a held pointer is read: pinned while the float out is being moved or resized.
    defer pinPointer(state);
    // Back in the main window since last frame, and drawn there: its window can go.
    if (closing) |*c| {
        release(c);
        closing = null;
    }
    if (out) |*o| {
        const i = find(state, o.serial) orelse {
            // Closed, or Reset Layout: its window goes with it.
            release(o);
            out = null;
            return;
        };
        const f = &state.floats.items.items[i];
        const held = f.win_id != .zero and dvui.captured(f.win_id);
        const released = o.was_held and !held;
        o.was_held = held;
        switch (o.mode) {
            .held => {
                if (held) {
                    // Its window up, a move of it — not a resize — goes on as the OS's own, as a
                    // press on a title bar would: it snaps to half the screen, maximizes at the top.
                    // The float settles where it is, and follows its window from here
                    // (`viewports.osPlaced`); dvui's drag of it ends, the OS holding the press.
                    const resizing = fizzy.core.widgets.FloatingWindowWidget.DragPart.isResizeDrag(f.win_id);
                    if (viewports.shown(o.viewport) and !resizing and viewports.dragMove(o.viewport)) {
                        dvui.captureMouse(null, 0);
                        dvui.dragEnd();
                        settle(f, o);
                        o.was_held = false;
                        dvui.refresh(null, @src(), null);
                    }
                    return;
                }
                // Let go. Wholly inside the main window it merges back in — drawn there already,
                // in its frame — and out of it settles into its band, at the same place.
                if (insideMain(f.bounds)) {
                    f.split = null;
                    closeAfterFrame();
                } else settle(f, o);
                dvui.refresh(null, @src(), null);
            },
            .band => {
                // The OS moved or resized its window — by its header or edges, a snap, maximized:
                // the float follows it.
                if (viewports.osPlaced(o.viewport)) |frame| if (f.viewport) |*vpr| {
                    const s = dvui.windowNaturalScale();
                    const r = (dvui.Rect.Physical{ .x = frame.x, .y = frame.y, .w = frame.w, .h = frame.h }).insetAll(reach() * s);
                    vpr.rect = .{ .x = r.x / s, .y = r.y / s, .w = r.w / s, .h = r.h / s };
                    dvui.refresh(null, @src(), null);
                };
                // A move of the OS's let go, as one of dvui's: wholly inside the main window it
                // comes back. Not one that left the window another size — resized, snapped to
                // half the screen, maximized: that put it where it is to stay.
                const os_released = if (viewports.osMoveEnded(o.viewport)) |end| !end.resized else false;
                if (toggle_requested or viewports.closeRequested(o.viewport) or ((released or os_released) and insideMain(inMainRect(o)))) {
                    comeBack(f, o);
                    dvui.refresh(null, @src(), null);
                }
            },
        }
        return;
    }
    if (toggle_requested) {
        const i = topmost(state) orelse return;
        popOut(&state.floats.items.items[i], .band);
        return;
    }
    // A float held — being moved or resized — past the main window's edge, or with the pointer
    // gone past it (a float is held on the main window by all but a strip of itself, so a drag
    // up out of it shows only in where the pointer is): split out, where it is.
    var i = state.floats.items.items.len;
    while (i > 0) : (i -= 1) {
        const f = &state.floats.items.items[i - 1];
        if (f.closing or f.fresh or f.landing != null or f.aside.to > 0 or f.win_id == .zero) continue;
        if (!dvui.captured(f.win_id)) continue;
        if (insideMain(f.bounds) and dvui.windowRectPixels().contains(dvui.currentWindow().mouse_pt)) break;
        popOut(f, .held);
        break;
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
/// (`viewports.os_frame`: Windows).
fn reach() f32 {
    const margin = (fizzy.core.widgets.FloatingWindowWidget.defaults.margin orelse dvui.Rect{}).x;
    return if (viewports.os_frame) -margin else Floats.outReach();
}

/// Take `f` out into a window of its own, opening over the place it is drawn in the main window
/// (grown or shrunk by `reach`). `.band`: into
/// the viewport's band at the same place (the command). `.held`: left in the main window's frame,
/// split, while the drag that took it out goes on.
fn popOut(f: *Floats.Float, mode: @FieldType(Out, "mode")) void {
    var title_buf: [96]u8 = undefined;
    const title = std.fmt.bufPrintZ(&title_buf, "{s}", .{f.name}) catch "Fizzy";
    const s = dvui.windowNaturalScale();
    const b = f.bounds.outsetAll(reach() * s);
    const vp = viewports.open(.{ .x = b.x, .y = b.y, .w = b.w, .h = b.h }, title) orelse return;
    // A material behind its glass where the platform has one, so it looks there as it does in
    // the main window (`Floats.Viewport.material`). The glass is the float's rect less its own
    // margin: inside the clear one round it, or all of the window the OS frames.
    const margin = (fizzy.core.widgets.FloatingWindowWidget.defaults.margin orelse dvui.Rect{}).x;
    const material = viewports.glass(vp, (reach() + margin) * s, fizzy.core.corners.scaled(fizzy.core.corners.surface) * s, dvui.themeGet().dark);
    switch (mode) {
        .band => {
            const window = viewports.frameOf(vp);
            const frame = (dvui.Rect.Physical{ .x = window.x, .y = window.y, .w = window.w, .h = window.h }).insetAll(reach() * s);
            f.viewport = .{ .rect = .{ .x = frame.x / s, .y = frame.y / s, .w = frame.w / s, .h = frame.h / s }, .material = material };
        },
        .held => f.split = .{ .material = material },
    }
    // The OS resizes it no smaller than its float may be.
    const rules = @import("app").layout.Layout.float_rules;
    viewports.minSize(vp, (rules.resize_min_w + 2 * reach()) * s, (rules.resize_min_h + 2 * reach()) * s);
    out = .{ .serial = f.serial, .viewport = vp, .mode = mode, .was_held = mode == .held };
    dvui.refresh(null, @src(), null);
}

/// A float split out under a drag, let go out of the main window: into the viewport's band at the
/// same place on the desktop, its window unmoved.
fn settle(f: *Floats.Float, o: *Out) void {
    const s = dvui.windowNaturalScale();
    const r = f.bounds;
    const band = viewports.bandFromMain(o.viewport, .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h });
    f.viewport = .{ .rect = .{ .x = band.x / s, .y = band.y / s, .w = band.w / s, .h = band.h / s }, .material = if (f.split) |sp| sp.material else false };
    f.split = null;
    o.mode = .band;
}

/// The float out, back in the main window where its window is now — mapped into the main window
/// and held on it (`float_rules.reachable`), not where it left from: it was moved out there. Its
/// window goes a frame later (`closeAfterFrame`).
fn comeBack(f: *Floats.Float, o: *Out) void {
    const s = dvui.windowNaturalScale();
    const at = inMainRect(o);
    if (at.w > 0 and at.h > 0) {
        const rules = @import("app").layout.Layout.float_rules;
        const back: dvui.Rect = .{ .x = at.x / s, .y = at.y / s, .w = at.w / s, .h = at.h / s };
        f.rect = Floats.fromRules(rules.reachable(Floats.toRules(back), Floats.toRules(dvui.windowRect())));
    }
    f.viewport = null;
    closeAfterFrame();
}

/// The float out has come back: its window stays for this frame, showing what it showed, and goes
/// at the start of the next, once the main window has drawn it (`closing`).
fn closeAfterFrame() void {
    const o = out orelse return;
    if (closing) |*c| release(c);
    closing = o;
    out = null;
}

/// Where the float out is, as a rect of the main window's frame: its window now, less `reach`
/// (physical).
fn inMainRect(o: *const Out) dvui.Rect.Physical {
    const window = viewports.inMain(o.viewport);
    return (dvui.Rect.Physical{ .x = window.x, .y = window.y, .w = window.w, .h = window.h }).insetAll(reach() * dvui.windowNaturalScale());
}

/// Whether a float's window rect `r` (physical, the main window's frame) is wholly inside the main
/// window: where it merges back into it, let go.
fn insideMain(r: dvui.Rect.Physical) bool {
    const w = dvui.windowRectPixels();
    return r.x >= w.x and r.y >= w.y and r.x + r.w <= w.x + w.w and r.y + r.h <= w.y + w.h;
}

/// A held pointer, pinned to the frame the float out is drawn in while its window is being moved
/// or resized — the main window's, split under the drag; its band, settled — and read by where it
/// is otherwise (a view carried between windows).
fn pinPointer(state: *const State) void {
    const o = out orelse return viewports.pinPointer(.none);
    const i = find(state, o.serial) orelse return viewports.pinPointer(.none);
    const f = state.floats.items.items[i];
    if (f.win_id == .zero or !dvui.captured(f.win_id)) return viewports.pinPointer(.none);
    viewports.pinPointer(switch (o.mode) {
        .held => .main,
        .band => .{ .viewport = o.viewport },
    });
}

/// Its window's part of the frame, natural, as a screen menus, tooltips and popovers opened in the
/// float are placed on and kept within (`core.screens`) — or none, with no float out.
fn publishScreens() void {
    const o = out orelse return fizzy.core.screens.clear();
    // Split under a drag, it is still in the main window's frame: nothing opens from it meanwhile.
    if (o.mode == .held) return fizzy.core.screens.clear();
    const f = viewports.frameOf(o.viewport);
    const s = dvui.windowNaturalScale();
    fizzy.core.screens.publish(&.{.{ .x = f.x / s, .y = f.y / s, .w = f.w / s, .h = f.h / s }});
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
}

/// After the frame has drawn and before dvui replays the subwindows into the main window's frame
/// (`core.FrameTarget.end`): the float out is replayed into its own target instead, its window
/// put where it was drawn, and handed the picture.
pub fn endFrame(state: *State) void {
    if (!enabled()) return;
    const o = if (out) |*o| o else return;
    // Nothing to copy unless this frame drew it: a target let go this frame is gone by then.
    viewports.present(o.viewport, null);
    const i = find(state, o.serial) orelse return;
    const f = &state.floats.items.items[i];
    if ((f.viewport == null and f.split == null) or f.win_id == .zero) return;
    const cw = dvui.currentWindow();
    if (cw.subwindows.get(f.win_id) == null) return;
    // Where it was drawn this frame, on whole points: where its window goes, and the offset its
    // drawing is replayed at, so a pointer over the window lands on what it shows — grown or
    // shrunk by `reach`. Split under a drag, that is in the main window's frame, which runs on
    // past its edge across the desktop.
    const b = f.bounds.outsetAll(reach() * dvui.windowNaturalScale());
    const shown = switch (o.mode) {
        .band => viewports.place(o.viewport, .{ .x = b.x, .y = b.y, .w = b.w, .h = b.h }),
        .held => viewports.placeMain(o.viewport, .{ .x = b.x, .y = b.y, .w = b.w, .h = b.h }),
    };
    const material = if (f.viewport) |vp| vp.material else if (f.split) |sp| sp.material else false;
    // Called what its header says — the view it shows — in the taskbar, the Window menu, the
    // window switcher.
    const title = f.titleText();
    if (title.len > 0 and !std.mem.eql(u8, title, o.title_buf[0..o.title_len])) {
        viewports.setTitle(o.viewport, title);
        @memcpy(o.title_buf[0..title.len], title);
        o.title_len = @intCast(title.len);
    }
    // Settled, where a press is the OS's: its header moves the window and its glass's edges resize
    // it, so the OS snaps, tiles and maximizes it as any window. Split under a drag, all of it is
    // the drag's.
    if (o.mode == .band) {
        const s = dvui.windowNaturalScale();
        const margin = (fizzy.core.widgets.FloatingWindowWidget.defaults.margin orelse dvui.Rect{}).x;
        const glass = f.bounds.insetAll(margin * s);
        viewports.hints(o.viewport, .{
            .drag = .{ .x = f.header.x, .y = f.header.y, .w = f.header.w, .h = f.header.h },
            .keep = .{ .x = f.header_close.x, .y = f.header_close.y, .w = f.header_close.w, .h = f.header_close.h },
            .glass = .{ .x = glass.x, .y = glass.y, .w = glass.w, .h = glass.h },
            .edge = resize_edge * s,
            .app_side = float_side * s,
            .app_corner = float_corner * s,
        });
    } else viewports.hints(o.viewport, null);
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
    backing(.{ .x = shown.x, .y = shown.y, .w = shown.w, .h = shown.h }, b, material);
    // The float and everything opened in it — its menus, tooltips, popovers, placed on its
    // window's screen (`core.screens`), each a subwindow of its own — in the order dvui stacks
    // them, every one whose middle is in the window's part of the frame. Taken from each, so
    // dvui's replay into the main window draws nothing of them.
    const area: dvui.Rect.Physical = .{ .x = shown.x, .y = shown.y, .w = shown.w, .h = shown.h };
    // And a layer drawn across every screen (`core.screens.markEverywhere`: a view drag's drops
    // and carried glass) is copied in too, left in place for the main window's replay — what of
    // it lies outside the window's part of the frame falls outside its target.
    //
    // Split under a drag, it is in the main window's frame, and what else is there is the main
    // window's: only the float itself is its window's. And until its window has shown a frame, the
    // float stays in the main window's replay too (copied, not taken) — so it is never on screen in
    // neither while its window comes up.
    const keep = o.mode == .held and !viewports.shown(o.viewport);
    for (cw.subwindows.stack.items) |*sw| {
        const mine = switch (o.mode) {
            .band => area.contains(sw.rect_pixels.center()),
            .held => sw.id == f.win_id,
        };
        if (!mine and !fizzy.core.screens.isEverywhere(sw.id)) continue;
        const cmds = sw.render_cmds;
        const after = sw.render_cmds_after;
        if (mine and !keep) {
            sw.render_cmds = .empty;
            sw.render_cmds_after = .empty;
        }
        cw.renderCommands(cmds.items) catch |err| dvui.logError(@src(), err, "replaying a float into its window", .{});
        cw.renderCommands(after.items) catch |err| dvui.logError(@src(), err, "replaying a float into its window", .{});
    }
    viewports.present(o.viewport, target);
}

/// What the float out here stands on: what the main window's base is under a float in it — its
/// chrome, at the window's opacity over the window's material (vibrancy, Acrylic) where it has one,
/// opaque where it has none — behind its glass, inside the margin its shadow is drawn in, in the
/// glass's own corners. Its frost reads this, as it reads the app in the main window: glass is made
/// as see-through as what it reads, and over the window's clear pixels it drew nothing at all,
/// neither its tint nor the light on its rim.
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
    var color = fizzy.core.dialogs.style().chromeColor();
    // The window's opacity as it is windowed (`Editor.window_opacity`), not the main window's
    // eased one, which goes opaque while the main window is maximized: out here it is windowed.
    color.a = if (material) @intFromFloat(@round(255 * std.math.clamp(fizzy.editor().window_opacity, 0, 1))) else 255;
    const theme = dvui.themeGet();
    const corners = fizzy.core.dialogs.surfaceCorners().finalize(&theme).scale(cw.natural_scale, dvui.CornerRect.Physical);
    bounds.fill(corners, .{ .color = .{ .color = color } });
}
