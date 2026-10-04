//! Phase 2 of `docs/POPOUT_WINDOWS_PLAN.md`, a spike behind `FIZZY_POPOUT=1` on fizzy's native
//! backend: "Pop Out Float" takes the topmost float out of the main window into an OS window of
//! its own (a viewport, `fizzy.backend.viewports`), and brings it back when run again or when the
//! OS asks that window to close.
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
};

/// `FIZZY_POPOUT=1`, on a backend with viewports.
pub fn enabled() bool {
    if (comptime builtin.target.cpu.arch == .wasm32 or !viewports.supported) return false;
    if (env_on == null) {
        const raw = std.c.getenv("FIZZY_POPOUT");
        env_on = if (raw) |r| !std.mem.eql(u8, std.mem.span(r), "0") else false;
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
/// window the OS asked to close — comes back, and a window whose float has gone goes too.
pub fn beginFrame(state: *State) void {
    if (!enabled()) return;
    defer toggle_requested = false;
    // Whatever happened, the screens floating things are placed on this frame: the window out,
    // if there is one, besides the main window's (`core.screens`).
    defer publishScreens();
    if (out) |*o| {
        const i = find(state, o.serial) orelse {
            // Closed, or Reset Layout: its window goes with it.
            release(o);
            out = null;
            return;
        };
        if (toggle_requested or viewports.closeRequested(o.viewport)) {
            // Back where its window is now, mapped into the main window and held on it
            // (`float_rules.reachable`) — not where it left from: it was moved out there.
            const f = &state.floats.items.items[i];
            const window = viewports.inMain(o.viewport);
            const s = dvui.windowNaturalScale();
            if (window.w > 0 and window.h > 0) {
                const rules = @import("app").layout.Layout.float_rules;
                // Its rect, inside the clear margin round it out there.
                const at: dvui.Rect.Physical = (dvui.Rect.Physical{ .x = window.x, .y = window.y, .w = window.w, .h = window.h }).insetAll(Floats.outReach() * s);
                const back: dvui.Rect = .{ .x = at.x / s, .y = at.y / s, .w = at.w / s, .h = at.h / s };
                f.rect = Floats.fromRules(rules.reachable(Floats.toRules(back), Floats.toRules(dvui.windowRect())));
            }
            f.viewport = null;
            release(o);
            out = null;
            dvui.refresh(null, @src(), null);
        }
        return;
    }
    if (!toggle_requested) return;
    const i = topmost(state) orelse return;
    const f = &state.floats.items.items[i];
    var title_buf: [96]u8 = undefined;
    const title = std.fmt.bufPrintZ(&title_buf, "{s}", .{f.name}) catch "Fizzy";
    // Its window opens over the place it was in the main window, grown by the clear margin its
    // shadow is drawn in out there (`Floats.outReach`); the float goes to the same place in the
    // viewport's band, so it does not move on screen.
    const s0 = dvui.windowNaturalScale();
    const b = f.bounds.outsetAll(Floats.outReach() * s0);
    const vp = viewports.open(.{ .x = b.x, .y = b.y, .w = b.w, .h = b.h }, title) orelse return;
    const window = viewports.frameOf(vp);
    const frame = (dvui.Rect.Physical{ .x = window.x, .y = window.y, .w = window.w, .h = window.h }).insetAll(Floats.outReach() * s0);
    const s = dvui.windowNaturalScale();
    f.viewport = .{ .rect = .{ .x = frame.x / s, .y = frame.y / s, .w = frame.w / s, .h = frame.h / s } };
    out = .{ .serial = f.serial, .viewport = vp };
    dvui.refresh(null, @src(), null);
}

/// Its window's part of the frame, natural, as a screen menus, tooltips and popovers opened in the
/// float are placed on and kept within (`core.screens`) — or none, with no float out.
fn publishScreens() void {
    const o = out orelse return fizzy.core.screens.clear();
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
    if (f.viewport == null or f.win_id == .zero) return;
    const cw = dvui.currentWindow();
    if (cw.subwindows.get(f.win_id) == null) return;
    // Where it was drawn this frame, on whole points: where its window goes, and the offset its
    // drawing is replayed at, so a pointer over the window lands on what it shows.
    // Its window holds the clear margin round it its shadow is drawn in (`Floats.outReach`).
    const b = f.bounds.outsetAll(Floats.outReach() * dvui.windowNaturalScale());
    const shown = viewports.place(o.viewport, .{ .x = b.x, .y = b.y, .w = b.w, .h = b.h });
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
    if (!f.viewport.?.material) backing(.{ .x = shown.x, .y = shown.y, .w = shown.w, .h = shown.h }, b);
    // The float and everything opened in it — its menus, tooltips, popovers, placed on its
    // window's screen (`core.screens`), each a subwindow of its own — in the order dvui stacks
    // them, every one whose middle is in the window's part of the frame. Taken from each, so
    // dvui's replay into the main window draws nothing of them.
    const area: dvui.Rect.Physical = .{ .x = shown.x, .y = shown.y, .w = shown.w, .h = shown.h };
    // And a layer drawn across every screen (`core.screens.markEverywhere`: a view drag's drops
    // and carried glass) is copied in too, left in place for the main window's replay — what of
    // it lies outside the window's part of the frame falls outside its target.
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

/// What the float out here stands on where its window has no material behind its glass
/// (`Floats.Viewport.material`): it draws its fill alone then, no frost, which over nothing came
/// out as translucent as that fill. Behind its glass instead — inside the margin its shadow is
/// drawn in — the chrome's colour, opaque, in the glass's own corners, so it reads as a panel of
/// the main window does.
fn backing(target: dvui.Rect.Physical, window: dvui.Rect.Physical) void {
    const margin = (fizzy.core.widgets.FloatingWindowWidget.defaults.margin orelse dvui.Rect{}).x;
    const bounds = window.insetAll((Floats.outReach() + margin) * dvui.windowNaturalScale());
    const cw = dvui.currentWindow();
    const prev_clip = dvui.clipGet();
    defer dvui.clipSet(prev_clip);
    dvui.clipSet(target);
    const prev_alpha = cw.alpha;
    dvui.alphaSet(1);
    defer dvui.alphaSet(prev_alpha);
    var color = fizzy.core.dialogs.style().chromeColor();
    color.a = 255;
    const theme = dvui.themeGet();
    const corners = fizzy.core.dialogs.surfaceCorners().finalize(&theme).scale(cw.natural_scale, dvui.CornerRect.Physical);
    bounds.fill(corners, .{ .color = .{ .color = color } });
}
