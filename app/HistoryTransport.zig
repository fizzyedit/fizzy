//! A document's transport: a bar of glass at the bottom of its pane, its history as a line with a
//! knob where the document is, and undo and redo either side (`plans/RECORDING_PLAN.md`, "Undo is
//! a seek"). Undo and redo show it (`stir`), and so does its grip; it stays while the pointer is
//! on it and goes a few seconds after (`history_transport.Shown`). A press or a drag on the line
//! goes to the step under it, one `historyGoTo` a frame at most, so a drag across a thousand steps
//! costs a jump a frame.
//!
//! **The grip.** Every pane whose document has history (`DrawOptions.history`) has a grip: a dome
//! (`dome.zig`, shared with the demo's tape player) on the middle of its bottom edge, standing on
//! the edge, so it covers next to nothing. At rest it is quiet, mostly see-through
//! (`dome_rules.Presence`); the pointer on it, a step or a slosh brings it up. The pointer held on
//! it a moment (`dome_rules.Dwell`) grows the bar out of it, the grip lightening as the moment
//! runs, so passing over it on the way somewhere never does; a press brings the bar at once. The
//! grip gives way to the bar while it shows. It fills with the document's history
//! (`DrawOptions.steps`) slowly, an hour or so of editing most of the way
//! (`dome_rules.stepsFill`), or with a tape playing into it as it plays (`DrawOptions.progress`),
//! and brightens a moment at each new step: it is recording, and there is more to scrub.
//!
//! **Going.** It goes a few seconds after the pointer was last on it, and soon after the pointer
//! leaves it (`Shown.soon`). A bar grown from a grip has a tab over it, a chevron down, that sends
//! it back into the grip at once (`Shown.hide`): the growing run backwards. Pressed, the pointer
//! resting on the bar does not bring it back until it has left.
//!
//! **The liquid.** What fills the grip is an opaque liquid in its glass, inside its rim, never past
//! three quarters. Grown into the bar, the liquid runs along the line up to the knob, what is
//! applied. A new step or a scrub knocks it (`dome_rules.Slosh`, a damped spring): knocks close
//! together build on its swing or cancel it as their timing falls, each a little different, so
//! rapid edits make a living swing; still, it asks for no frames. Each shape is its vessel's outline
//! cut by its surface (`dome_rules.cut`), convex, so dvui's smooth fill draws it.
//!
//! Over any owner's history (`Plugin.historyLine`, `historyGoTo`); an owner without them has no
//! transport. Nothing runs for a bar that is not showing: no history is asked for, no timer is
//! set. One per document pane, kept by the app beside the pane.
//!
//! **The strip.** Given the document's pictures (`DrawOptions.frames`, `HistoryFrames`), scrubbing
//! (a drag on the line, a held undo or redo) grows the bar upward into a strip of them, as a
//! video's scrubber shows frames: each tile the document at a stretch of its history, the nearest
//! step to the tile's middle that has a picture. It stays while the pointer is on the bar.
//!
//! **Export.** The bar has an export button whenever the app can export (`DrawOptions.export_from`).
//! Pressed, it grows the strip and opens a window over it, as macOS trims a recording: a yellow
//! bracket over the part to export, dragged from either side (`history_transport.Trim`), the
//! document going to wherever a side is dragged and the rest dimmed. Pressed again, the part is the app's (`Pressed.exported`); undo's
//! button, a cross while the window is open, closes it.
const HistoryTransport = @This();

const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const sdk = @import("fizzy_sdk");
const icons = @import("icons");
const rules = @import("history_transport.zig");
const dome = @import("dome.zig");
const dome_rules = @import("dome_rules.zig");

shown: rules.Shown = .{},
/// The strip: grown while scrubbing, and while the pointer is on the bar after.
strip: rules.Shown = .{},
/// The export window over the strip while the person trims it; null when closed.
window: ?rules.Trim = null,
/// What the pointer holds of the window while it drags.
grip: ?rules.Trim.Grip = null,
repeat: rules.Repeat = .{},
/// The pointer held on the grip.
dwell: dome_rules.Dwell = .{},
/// The steps the grip last showed (null before it first drew), and when a new one came: it
/// brightens a moment.
grip_steps: ?usize = null,
stepped_at: ?i128 = null,
/// How much of the grip shows: quiet at rest, all of it in use.
presence: dome_rules.Presence = .{},
/// The liquid's swing, and the step the document stood at when it was last drawn: a scrub knocks it.
slosh: dome_rules.Slosh = .{},
slosh_at: ?usize = null,
/// The bar has its collapse tab (it grew from a grip): its place reaches up over it.
tab: bool = false,
/// The pointer was on the bar last frame: leaving it, the bar goes soon.
was_on: bool = false,
/// The tab sent it back: the pointer resting where the bar was does not bring it back until it
/// has left.
held_off: bool = false,
/// The stop the pointer holds the knob at while it drags the line, until the drag ends. Only
/// while the bar holds the mouse: a drag whose capture went (the bar stopped drawing) is over.
drag: ?usize = null,

const bar_h: f32 = 40;
/// How much taller the bar grows for its strip.
const strip_h: f32 = 66;
const button_d: f32 = 34;
const gap: f32 = 10;
const max_w: f32 = 460;
const tab_d = dome.tab_d;
const tab_gap = dome.tab_gap;
/// How long the grip brightens at a new step.
const step_glow_ns: i128 = 450 * std.time.ns_per_ms;

/// Undo or redo was pressed at `now_ns`, or something else asked for the bar: it shows.
pub fn stir(self: *HistoryTransport, now_ns: i128) void {
    self.shown.stir(now_ns);
    dvui.refresh(null, @src(), null);
}

/// A press of undo or redo (`forward`) at `now_ns` on this document: the bar shows, and the
/// press moves this many steps (`history_transport.Repeat`: more the longer the key is held). A
/// held key is scrubbing: the strip grows.
pub fn press(self: *HistoryTransport, now_ns: i128, forward: bool) usize {
    self.stir(now_ns);
    const by = self.repeat.press(now_ns, forward);
    if (self.repeat.run > 1) self.strip.stir(now_ns);
    return by;
}

/// Where the bar is over `area` (a document's pane, physical) while it shows, as far as the
/// pointer keeps it: what else drawn at the bottom of the pane (the activity feed) stays above.
/// Null when it is not showing at `now_ns`, or the pane is too narrow for it.
pub fn place(self: *const HistoryTransport, area: dvui.Rect.Physical, now_ns: i128) ?dvui.Rect.Physical {
    if (self.drag == null and self.shown.openness(now_ns) <= 0) return null;
    const whole = geometry(area.toNatural(), self.strip.openness(now_ns)) orelse return null;
    var r = whole.outsetAll(4);
    if (self.tab) {
        r.y -= tab_d + tab_gap;
        r.h += tab_d + tab_gap;
    }
    return dvui.windowRectScale().rectToPhysical(r);
}

/// The grip over `area` (physical), standing on the middle of its bottom edge, `r` its radius, in
/// natural units as `geometry`'s; null when the pane is too narrow for the bar.
fn gripRect(area: dvui.Rect.Physical, r: f32, edge: ?f32) ?dvui.Rect {
    var on = area;
    if (edge) |y| on.h = y - on.y;
    const nat = on.toNatural();
    _ = geometry(nat, 0) orelse return null;
    return .{ .x = nat.x + nat.w / 2 - r, .y = nat.y + nat.h - r, .w = 2 * r, .h = r };
}

/// The bar's rect over a pane's natural rect, its strip `grown` (0 to 1) of the way up, or null
/// when the pane is too narrow for it.
fn geometry(nat: dvui.Rect.Natural, grown: f32) ?dvui.Rect {
    const w = @min(max_w, nat.w - 24);
    if (w < 3 * button_d) return null;
    const h = bar_h + strip_h * grown;
    const bottom = nat.y + nat.h - 14;
    return .{ .x = nat.x + nat.w / 2 - w / 2, .y = bottom - h, .w = w, .h = h };
}

/// The id `historyGoTo` takes for stop `i`: 0 before the first step, else the step's.
fn stopId(line: sdk.Plugin.HistoryLine, i: usize) u64 {
    return if (i == 0) 0 else line.entries[i - 1].id;
}

pub const DrawOptions = struct {
    /// The document has history to show: its pane has a grip. The app says, as it knows cheaply,
    /// so a pane asks its owner for nothing while the bar is hidden.
    history: bool = false,
    /// How many steps of it the app has kept (fizzy: its track's), for the grip's fill; 0: none
    /// shows, the grip is plain.
    steps: usize = 0,
    /// Where the pane's own bottom edge is (physical y), when its card reaches lower than `area`:
    /// the grip stands on it. Null: `area`'s.
    edge: ?f32 = null,
    /// The document's pictures, for the strip scrubbing grows; null: no strip.
    frames: ?*const HistoryFrames = null,
    /// An export button with the strip: the app can export a part of the history (fizzy: as a
    /// tape). The history entry the part can begin at, earliest (0: before any); null: no button.
    export_from: ?u64 = null,
    /// What the window holds, said over the line while it is open (`window`): the app's words.
    window_summary: []const u8 = "",
    /// A tape playing into the document (fizzy: in a tape's tab), how far it has played, 0 to 1:
    /// the grip fills as it plays rather than by `steps`. Null: none.
    progress: ?f32 = null,
};

const HistoryFrames = @import("HistoryFrames.zig");

/// What was pressed on the bar this frame that is the app's to act on.
pub const Pressed = struct {
    /// The window's part was exported: from stop `from` to stop `to` of the line.
    exported: ?rules.Trim = null,
};

/// Draw the bar over `area` (the document's pane, physical) when it shows, and take its input.
/// `id_extra` keeps one pane's bar apart from another's.
pub fn draw(self: *HistoryTransport, doc: sdk.DocHandle, area: dvui.Rect.Physical, id_extra: usize, opts: DrawOptions) Pressed {
    var pressed: Pressed = .{};
    const now = dvui.frameTimeNS();
    // The pointer on it, or a drag in it, keeps it; the pointer held on the grip brings it up.
    const mouse = dvui.currentWindow().mouse_pt;
    // A bar that grows out of its grip takes a surface's opening time to do it; one that fades, a
    // fade's.
    self.shown.fade = if (opts.history) dome.growNs() else rules.fade_ns;
    var reach = area;
    if (opts.edge) |y| reach.h = @max(reach.h, y - reach.y);
    const on_grip = opts.history and reach.contains(mouse) and !core.dialogs.modalOverCurrent() and
        if (gripRect(area, dome.radius, opts.edge)) |g| dvui.windowRectScale().rectToPhysical(g.outsetAll(dome.reach)).contains(mouse) else false;
    self.tab = opts.history;
    const on_bar = if (self.place(area, now)) |b| b.contains(mouse) else false;
    if (!on_bar) self.held_off = false;
    // Left: it goes soon, rather than lingering its whole time.
    if (self.was_on and !on_bar and self.drag == null and self.window == null) self.shown.soon(now, dome_rules.leave_ns);
    self.was_on = on_bar and !self.held_off;
    // Every frame, so it sees the pointer leave the grip whichever way it goes.
    const grows = self.dwell.hold(on_grip, self.drag == null and self.shown.openness(now) <= 0, now);
    if (self.drag != null) {
        self.shown.stir(now);
        if (opts.frames != null) self.strip.stir(now);
    } else if (on_bar and !self.held_off) {
        self.shown.stir(now);
        // On the bar, a strip grown stays.
        if (self.strip.openness(now) > 0) self.strip.stir(now);
    } else if (grows) self.stir(now);
    // An open window keeps the bar and its strip.
    if (self.window != null) {
        self.shown.stir(now);
        self.strip.stir(now);
    }
    const p = self.shown.openness(now);
    // A tape playing into the document fills it as it plays; else its history does.
    const fill = if (opts.progress) |f| dome_rules.progressFill(f) else dome_rules.stepsFill(opts.steps);
    // The grip, giving way to the bar as it comes in, quiet at rest and coming up while in use: a
    // frame each while it changes, and none while it only sits there.
    if (opts.history and p < 1) {
        if (self.grip_steps) |was| if (opts.steps > was) {
            self.stepped_at = now;
            self.slosh.knock(now, 0.35);
        };
        self.grip_steps = opts.steps;
        const glow: f32 = if (self.stepped_at) |t| (if (now - t < step_glow_ns) 1 - @as(f32, @floatCast(@as(f64, @floatFromInt(now - t)) / @as(f64, @floatFromInt(step_glow_ns)))) else 0) else 0;
        if (glow == 0) self.stepped_at = null;
        const in_use = on_grip or self.stepped_at != null or !self.slosh.settled(now);
        const alpha = self.presence.ease(in_use, now);
        // While the bar grows out of it, the grip is the bar's glass: not drawn here.
        if (p <= 0) if (gripRect(area, dome.radius, opts.edge)) |g| if (dome.draw(g, id_extra, .{
            .alpha = alpha,
            .lit = on_grip,
            .held = self.dwell.held(now),
            .fill = fill,
            .glow = glow,
            .tilt = self.slosh.tilt(now),
        }, "history.grip:{s}", .{doc.owner.documentPath(doc)})) self.stir(now);
        if (self.dwell.since != null or self.stepped_at != null or !self.slosh.settled(now) or self.presence.moving(in_use)) dvui.refresh(null, @src(), null);
    }
    if (p <= 0) return pressed;
    const arena = dvui.currentWindow().arena();
    const line = doc.owner.historyLine(doc, arena) orelse return pressed;
    const n = line.entries.len;
    // The first stop a part can begin at: where `export_from` is on the line. Gone from it (undone
    // past and edited over), nothing can be exported.
    const min_from: ?usize = if (opts.export_from) |id| (if (id == 0) 0 else for (line.entries, 1..) |e, i| {
        if (e.id == id) break i;
    } else null) else null;
    const can_export = opts.frames != null and min_from != null and min_from.? < n;
    // The history changed under an open window (an edit elsewhere): it closes.
    if (self.window) |win| if (win.n != n or !can_export) {
        self.window = null;
        self.grip = null;
    };

    const wrs = dvui.windowRectScale();
    const s = wrs.s;
    const grown = if (opts.frames != null) self.strip.openness(now) else 0;
    const whole = geometry(area.toNatural(), grown) orelse return pressed;
    const w = whole.w;
    // The buttons and the line keep to the bar's bottom row; the strip grows over them.
    const center: dvui.Point = .{ .x = whole.x + w / 2, .y = whole.y + whole.h - bar_h / 2 };
    // Export, when there is a way to: the last bubble, there whenever the bar is. Pressed, it opens
    // the window over the strip, which grows for it.
    const export_g: f32 = if (can_export) 1 else 0;
    const end_w: f32 = (button_d + gap) * export_g;
    const back: dvui.Rect = .{ .x = whole.x, .y = center.y - button_d / 2, .w = button_d, .h = button_d };
    const fwd: dvui.Rect = .{ .x = whole.x + w - button_d - end_w, .y = back.y, .w = button_d, .h = button_d };
    const share: dvui.Rect = .{ .x = whole.x + w - button_d * export_g, .y = back.y + button_d * (1 - export_g) / 2, .w = button_d * export_g, .h = button_d * export_g };
    const track: dvui.Rect = .{ .x = back.x + button_d + gap, .y = whole.y, .w = w - 2 * (button_d + gap) - end_w, .h = whole.h };
    // The collapse tab, over the middle of the bar: back into the grip.
    const tab = dome.tabRect(whole);
    const hit = if (self.place(area, now)) |pl| pl else wrs.rectToPhysical(whole.outsetAll(4));

    var float: dvui.FloatingWidget = undefined;
    float.init(@src(), .{}, .{ .rect = whole.outset(.{ .x = 16, .y = 16 + tab_d + tab_gap, .w = 16, .h = 16 }), .id_extra = id_extra });
    defer float.deinit();
    const bounds = float.data().rect;
    const fid = float.data().id;
    // A drag lives as long as the bar holds the mouse: drawn again after it was not (a claim came
    // and went), it holds nothing, and the knob is the document's again.
    if (self.drag != null and !dvui.captured(fid)) self.drag = null;
    if (self.grip != null and !dvui.captured(fid)) self.grip = null;

    const phys = [4]dvui.Rect.Physical{ wrs.rectToPhysical(back), wrs.rectToPhysical(track), wrs.rectToPhysical(fwd), wrs.rectToPhysical(share) };
    const tab_p = wrs.rectToPhysical(tab);
    const pad = 14;
    const x0 = phys[1].x + pad * s;
    const x1 = phys[1].x + phys[1].w - pad * s;
    // Where a press goes to a step: the line's band, under the title, and the strip above it
    // while it shows. A press on the title or the capsule's ends is the bar's, and does nothing.
    const band_y = phys[1].y + phys[1].h - bar_h * s * 0.55;
    const line_band: dvui.Rect.Physical = .{ .x = x0 - 8 * s, .y = band_y, .w = x1 - x0 + 16 * s, .h = bar_h * s * 0.55 };
    const strip_band: dvui.Rect.Physical = .{ .x = x0 - 8 * s, .y = phys[1].y, .w = x1 - x0 + 16 * s, .h = @max(0, phys[1].h - bar_h * s) };
    // Named for a tape or a test to aim at: the line from its first stop to its last, so a point
    // a fraction along it is that fraction of the history.
    const path = doc.owner.documentPath(doc);
    core.anchor.markRect(fid, phys[0], true, "history.back:{s}", .{path});
    core.anchor.markRect(fid, .{ .x = x0, .y = phys[1].y, .w = x1 - x0, .h = phys[1].h }, true, "history.line:{s}", .{path});
    core.anchor.markRect(fid, phys[2], true, "history.forward:{s}", .{path});
    if (export_g > 0) core.anchor.markRect(fid, phys[3], true, "history.export:{s}", .{path});
    if (self.tab) core.anchor.markRect(fid, tab_p, true, "history.collapse:{s}", .{path});

    // Input: the buttons step, the line goes where it is pressed and follows a drag.
    var go: ?usize = null;
    for (dvui.events()) |*e| {
        if (!dvui.eventMatch(e, .{ .id = fid, .r = hit })) continue;
        const me = switch (e.evt) {
            .mouse => |m| m,
            else => continue,
        };
        switch (me.action) {
            .press => if (me.button.pointer()) {
                e.handle(@src(), float.data());
                if (phys[0].contains(me.p)) {
                    // A cross while the window is open: it closes.
                    if (self.window != null) self.window = null else go = line.at -| 1;
                } else if (phys[2].contains(me.p)) {
                    if (self.window == null) go = @min(n, line.at + 1);
                } else if (self.tab and tab_p.contains(me.p)) {
                    // An open export window would keep the bar: it closes with it.
                    self.window = null;
                    self.grip = null;
                    self.shown.hide(now);
                    self.held_off = true;
                    self.was_on = false;
                    dvui.refresh(null, @src(), fid);
                } else if (export_g > 0.5 and phys[3].contains(me.p)) {
                    if (self.window) |win| {
                        pressed.exported = win;
                        self.window = null;
                    } else self.window = .{ .from = min_from.?, .to = n, .n = n };
                } else if (line_band.contains(me.p) or (grown > 0 and strip_band.contains(me.p))) {
                    dvui.captureMouse(float.data(), e.num);
                    const stop = rules.stopAt(me.p.x, x0, x1, n);
                    if (self.window) |*win| {
                        const grip = win.grab(me.p.x, x0, x1, 12 * s);
                        self.grip = grip;
                        go = dragWindow(win, grip, stop, min_from.?);
                    } else self.drag = stop;
                }
            },
            .motion => if (dvui.captured(fid)) {
                const stop = rules.stopAt(me.p.x, x0, x1, n);
                if (self.grip) |grip| {
                    e.handle(@src(), float.data());
                    go = dragWindow(&self.window.?, grip, stop, min_from.?);
                } else if (self.drag != null) {
                    e.handle(@src(), float.data());
                    self.drag = stop;
                }
            },
            .release => if (me.button.pointer() and dvui.captured(fid)) {
                e.handle(@src(), float.data());
                dvui.captureMouse(null, e.num);
                self.drag = null;
                self.grip = null;
            },
            else => {},
        }
    }
    if (self.drag) |d| go = d;
    var at = line.at;
    if (go) |to| if (to != at) {
        if (doc.owner.historyGoTo(doc, stopId(line, to))) at = to;
        dvui.refresh(null, @src(), fid);
    };
    // A scrub knocks the liquid, the way it went and as far.
    if (self.slosh_at) |was| if (was != at) {
        const by = (@as(f32, @floatFromInt(at)) - @as(f32, @floatFromInt(was))) / @as(f32, @floatFromInt(@max(1, n)));
        self.slosh.knock(now, dome_rules.knockFor(by));
    };
    self.slosh_at = at;
    const tilt = self.slosh.tilt(now);

    // Coming in and going, a pane with a grip grows the bar out of it and takes it back in. The
    // bubbles bud out of the grip one after another (`bud_delays`) and pull away to their places,
    // the grip in the same glass and shrinking as they leave it, the glass between them reaching
    // further while they are near: they run together and part as drops do. What is on them shows
    // once they are most of the way out. Without a grip, it fades.
    const from: ?dvui.Rect.Physical = if (opts.history and p < 1) if (gripRect(area, dome.radius, opts.edge)) |g| wrs.rectToPhysical(g) else null else null;
    const out = core.motion.enterFull(p);
    const bud: ?dvui.Rect.Physical = if (from) |f| dome.bud(f) else null;
    const prev_alpha = dvui.alpha(if (from != null) dome.glassAlpha(self.presence.value, p) else p);
    defer dvui.alphaSet(prev_alpha);
    const pt = dvui.currentWindow().mouse_pt;
    var bubbles: [5]core.dialogs.Bubble = undefined;
    const trimming = self.window != null;
    // The line's bubble: a capsule round the line alone, easing to a surface's corners as the
    // strip grows, so the pictures sit inside them.
    const line_radius = std.math.lerp(phys[1].h / 2, core.corners.scaled(core.corners.card) * s, @min(1, grown * 1.5));
    for (phys, bubbles[0..4], 0..) |r, *b, i| b.* = .{
        .rect = if (bud) |f| dome.lerpRect(f, r, dome.emerge(p, bud_delays[i])) else r,
        .radius = if (i == 1 and grown > 0) line_radius else null,
        .light = if (r.contains(pt) and switch (i) {
            0 => trimming or at > 0,
            2 => !trimming and at < n,
            3 => true,
            else => false,
        }) core.dialogs.bubble_hover else 0,
    };
    // The tab, a small drop on the bar's top that its glass runs into.
    var count: usize = if (export_g > 0) 4 else 3;
    if (self.tab) {
        bubbles[count] = .{
            .rect = if (bud) |f| dome.lerpRect(f, tab_p, dome.emerge(p, bud_delays[4])) else tab_p,
            .light = if (tab_p.contains(pt)) core.dialogs.bubble_hover else 0,
        };
        count += 1;
    }
    // The grip itself, in the same glass, shrinking into the pane's edge as the bar leaves it.
    var shapes: [6]core.dialogs.Bubble = undefined;
    @memcpy(shapes[0..count], bubbles[0..count]);
    if (from) |f| {
        shapes[count] = dome.shrinking(f, p);
        count += 1;
    }
    {
        // Not past the pane's edge, which the grip stands on.
        const prev_clip = if (from) |f| dvui.clip(dome.aboveEdge(f)) else dvui.clipGet();
        defer dvui.clipSet(prev_clip);
        core.dialogs.glassBubbles(fid, shapes[0..count], s, .{ .merge = dome.merge(p, 14), .shadow = 1 });
    }
    // What is on the bubbles comes once they are most of the way out; the liquid comes with them.
    const shape_alpha = dvui.alpha(1);
    if (from != null) {
        dvui.alphaSet(prev_alpha);
        _ = dvui.alpha(dome.contentAlpha(p));
    }

    const ink = dvui.themeGet().color(.window, .text);
    if (trimming) {
        button(bounds, back, "history_cancel", icons.tvg.lucide.x, ink.opacity(0.85));
    } else button(bounds, back, "history_back", icons.tvg.lucide.undo, ink.opacity(if (at > 0) 0.85 else 0.3));
    button(bounds, fwd, "history_forward", icons.tvg.lucide.redo, ink.opacity(if (!trimming and at < n) 0.85 else 0.3));
    if (self.tab) dome.chevron(bounds, tab, ink.opacity(0.85));
    if (export_g > 0.3) {
        if (trimming) {
            button(bounds, share, "history_export_done", icons.tvg.lucide.check, yellow);
        } else button(bounds, share, "history_export", icons.tvg.lucide.@"share-2", ink.opacity(0.85 * export_g));
    }

    // What the document is at, over the line: the step's title, and how far along.
    const font = dvui.Font.theme(.body).larger(-2);
    var buf: [96]u8 = undefined;
    const title = if (at == 0) "Before any change" else line.entries[at - 1].title;
    const label = if (trimming and opts.window_summary.len > 0) opts.window_summary else std.fmt.bufPrint(&buf, "{s}   {d} / {d}", .{ title, at, n }) catch title;
    const film: dvui.Rect.Physical = .{ .x = x0, .y = phys[1].y + 8 * s, .w = x1 - x0, .h = strip_h * grown * s - 6 * s };
    if (grown > 0) if (opts.frames) |frames| paintStrip(film, frames, line, at, s, grown);
    dvui.labelNoFmt(@src(), label, .{}, .{
        .rect = .{ .x = track.x + pad - bounds.x, .y = track.y + track.h - bar_h + 4 - bounds.y, .w = track.w - 2 * pad, .h = font.lineHeight() },
        .padding = .{},
        .margin = .{},
        .font = font,
        .color_text = .{ .color = ink.opacity(0.85) },
    });
    const line_r: dvui.Rect.Physical = .{ .x = x0, .y = phys[1].y + phys[1].h - 16 * s, .w = @max(1, x1 - x0), .h = 10 * s };
    // The grip's liquid, flowing out of it into the line as the bar grows (`from`, the grip's lower
    // part), and back as it goes.
    paintLine(line_r, at, n, ink, s, .{ .tilt = tilt, .from = if (from) |f| dome.pool(f, fill) else null, .out = out, .alpha = shape_alpha });
    if (self.window) |win| paintWindow(phys[1], if (grown > 0) line_radius else phys[1].h / 2, x0, x1, win, s);

    // Comes in, goes: a frame each while it fades, and one wake for when it next changes on its
    // own (it starts to go, it is gone).
    if (p < 1 or (grown > 0 and grown < 1) or !self.slosh.settled(now)) dvui.refresh(null, @src(), fid);
    const next = if (self.strip.nextChange(now)) |t| @min(t, self.shown.nextChange(now) orelse t) else self.shown.nextChange(now);
    if (next) |t| dvui.timer(fid, @intCast(@min(@divTrunc(t - now, 1000) + 1, std.math.maxInt(i32))));
    return pressed;
}

/// When each bubble buds out of the grip, as a share of the growing: the line first, undo and
/// redo after it, then export, then the tab.
const bud_delays = [5]f32{ 0.12, 0, 0.12, 0.22, 0.3 };

/// macOS's trim yellow.
const yellow: dvui.Color = .{ .r = 0xF5, .g = 0xC0, .b = 0x2E };

/// Drag what `grip` holds of `win` to `stop`, the part never beginning before `min_from`. Returns
/// the stop the document goes to.
fn dragWindow(win: *rules.Trim, grip: rules.Trim.Grip, stop: usize, min_from: usize) usize {
    return win.drag(grip, @max(stop, if (grip == .to) min_from + 1 else min_from));
}

/// The export window over `r` (physical: the strip and the line under it): the rest dimmed, a
/// yellow bracket over the part, a handle at each side.
fn paintWindow(vessel: dvui.Rect.Physical, radius: f32, x0: f32, x1: f32, win: rules.Trim, s: f32) void {
    // Inside the line's bubble, by its own corners less the inset, so the bracket never reaches
    // past the glass round it.
    const inset = 5 * s;
    const r = vessel.insetAll(inset);
    const ro = @max(2 * s, radius - inset);
    const ri: dvui.Corner.Physical = .round(1.5 * s);
    const outer: dvui.Corner.Physical = .round(ro);
    const xf = rules.stopX(win.from, x0, x1, win.n);
    const xt = rules.stopX(win.to, x0, x1, win.n);
    const handle_w = 8 * s;
    const edge = 2.5 * s;
    const dim: dvui.Color = dvui.Color.black.opacity(0.6);
    const left = xf - handle_w;
    const right = xt + handle_w;
    if (left > r.x) (dvui.Rect.Physical{ .x = r.x, .y = r.y, .w = left - r.x, .h = r.h }).fill(.{ .tl = outer, .bl = outer, .tr = ri, .br = ri }, .{ .color = .{ .color = dim }, .fade = 1 });
    if (right < r.x + r.w) (dvui.Rect.Physical{ .x = right, .y = r.y, .w = r.x + r.w - right, .h = r.h }).fill(.{ .tl = ri, .bl = ri, .tr = outer, .br = outer }, .{ .color = .{ .color = dim }, .fade = 1 });
    (dvui.Rect.Physical{ .x = xf, .y = r.y, .w = xt - xf, .h = edge }).fill(.{}, .{ .color = .{ .color = yellow } });
    (dvui.Rect.Physical{ .x = xf, .y = r.y + r.h - edge, .w = xt - xf, .h = edge }).fill(.{}, .{ .color = .{ .color = yellow } });
    for ([_]f32{ left, xt }, [_]bool{ true, false }) |x, is_left| {
        const hr: dvui.Rect.Physical = .{ .x = x, .y = r.y, .w = handle_w, .h = r.h };
        hr.fill(if (is_left) .{ .tl = outer, .bl = outer, .tr = ri, .br = ri } else .{ .tl = ri, .bl = ri, .tr = outer, .br = outer }, .{ .color = .{ .color = yellow }, .fade = 1 });
        const notch: dvui.Rect.Physical = .{ .x = x + handle_w / 2 - 0.75 * s, .y = r.y + r.h / 2 - 6 * s, .w = 1.5 * s, .h = 12 * s };
        notch.fill(.round(0.75 * s), .{ .color = .{ .color = .black } });
    }
}

/// The strip `r` (physical): tiles across it, each the picture nearest its stretch's middle of the
/// history (`line`), the tile under the knob at `at` lit; a stretch with no picture stays glass.
fn paintStrip(r: dvui.Rect.Physical, frames: *const HistoryFrames, line: sdk.Plugin.HistoryLine, at: usize, s: f32, grown: f32) void {
    if (r.h < 4 * s or r.w < 4 * s) return;
    const n = line.entries.len;
    // Tiles about square, as many as fit, each picture cropped to its middle: a wide pane's
    // pictures at their own shape fit only three or four.
    const aspect: f32 = 1.1;
    const count: usize = @max(1, @as(usize, @intFromFloat(@floor(r.w / (r.h * aspect)))));
    const tile_w = r.w / @as(f32, @floatFromInt(count));
    const gap_px = 2 * s;
    const ink = dvui.themeGet().color(.window, .text);
    for (0..count) |i| {
        // The stretch of stops this tile stands for, and the stop nearest its middle with a picture.
        const lo = i * (n + 1) / count;
        const hi = @max(lo + 1, (i + 1) * (n + 1) / count);
        const mid = (lo + hi) / 2;
        var best: ?dvui.Texture = null;
        // Outward from the middle, until both ends of the stretch are passed.
        var d: usize = 0;
        while (best == null and (mid + d < hi or mid >= lo + d)) : (d += 1) {
            if (mid + d < hi) best = frames.get(stopId(line, mid + d));
            if (best == null and d > 0 and mid >= lo + d) best = frames.get(stopId(line, mid - d));
        }
        const tile: dvui.Rect.Physical = .{ .x = r.x + @as(f32, @floatFromInt(i)) * tile_w + gap_px / 2, .y = r.y, .w = tile_w - gap_px, .h = r.h };
        const lit = at >= lo and at < hi or (at == n and i == count - 1);
        if (best) |tex| {
            // Cover the tile, the picture's middle kept.
            const ta = @as(f32, @floatFromInt(tex.width)) / @as(f32, @floatFromInt(@max(1, tex.height)));
            const want = tile.w / tile.h;
            const uv: dvui.Rect = if (ta > want) .{ .x = (1 - want / ta) / 2, .y = 0, .w = want / ta, .h = 1 } else .{ .x = 0, .y = (1 - ta / want) / 2, .w = 1, .h = ta / want };
            dvui.renderTexture(tex, .{ .r = tile, .s = s }, .{ .uv = uv, .corners = .all(4), .colormod = dvui.Color.white.opacity(if (lit) grown else 0.75 * grown) }) catch {};
        } else {
            tile.fill(.all(4 * s), .{ .color = .{ .color = ink.opacity(0.06 * grown) } });
        }
        if (lit) tile.stroke(.all(4 * s), .{ .thickness = 1.5 * s, .color = .{ .color = dvui.themeGet().color(.highlight, .fill).opacity(grown) } });
    }
}

/// A step button's icon, in the middle of its bubble `r` (window-natural; `bounds` the layer's).
fn button(bounds: dvui.Rect, r: dvui.Rect, name: []const u8, tvg: []const u8, color: dvui.Color) void {
    const d = r.w * 0.44;
    core.icon.icon(@src(), name, tvg, .{
        .stroke_color = .{ .color = color },
        .fill_color = .{ .color = color },
    }, .{
        .id_extra = @intFromPtr(name.ptr),
        .rect = .{ .x = r.x + (r.w - d) / 2 - bounds.x, .y = r.y + (r.h - d) / 2 - bounds.y, .w = d, .h = d },
    });
}

/// The line `r` (physical): the history to `at` lit, a tick per step while they fit, the knob.
/// The line's liquid: what is applied, up to the knob.
const LineLiquid = struct {
    /// How tipped its head is, -1 to 1 (`dome_rules.Slosh`).
    tilt: f32 = 0,
    /// Growing out of the grip: the pool it flows from (physical), and how far it has come, 0 to 1.
    from: ?dvui.Rect.Physical = null,
    out: f32 = 1,
    /// Its own alpha: it shows while the bubbles grow, before what is on them does.
    alpha: f32 = 1,
};

fn paintLine(r: dvui.Rect.Physical, at: usize, n: usize, ink: dvui.Color, s: f32, liquid: LineLiquid) void {
    const h = 4 * s;
    const line: dvui.Rect.Physical = .{ .x = r.x, .y = r.y + (r.h - h) / 2, .w = r.w, .h = h };
    line.fill(.round(h / 2), .{ .color = .{ .color = ink.opacity(0.15) } });
    const accent = dvui.themeGet().color(.highlight, .fill);
    const knob_x = rules.stopX(at, r.x, r.x + r.w, n);
    // A tick per step while they stand 6 points apart; past that the line is its own scale.
    if (n > 0 and r.w / @as(f32, @floatFromInt(n)) >= 6 * s) for (1..n) |i| {
        const x = rules.stopX(i, r.x, r.x + r.w, n);
        const tick: dvui.Rect.Physical = .{ .x = x - 0.5 * s, .y = r.y + 1 * s, .w = 1 * s, .h = r.h - 2 * s };
        tick.fill(.{}, .{ .color = .{ .color = ink.opacity(0.25) } });
    };
    // The applied part, a liquid in a tube a little thicker than the line, its head tipped by the
    // slosh; growing, it runs out of the grip's pool along the line.
    const th = 6 * s;
    const done: dvui.Rect.Physical = .{ .x = line.x, .y = line.y + h / 2 - th / 2, .w = @max(th, knob_x - line.x + th / 2), .h = th };
    // Nothing applied and not growing: no dot of liquid at the line's start.
    if (at > 0 or liquid.from != null) dome.pourTube(done, liquid.tilt, liquid.from, liquid.out, liquid.alpha, accent);
    var knob: dvui.Path.Builder = .init(dvui.currentWindow().lifo());
    defer knob.deinit();
    knob.addArc(.{ .x = knob_x, .y = line.y + h / 2 }, 6 * s, std.math.tau, 0, true);
    knob.build().fillConvex(.{ .color = .{ .color = accent }, .fade = 1 });
}
