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
//! (`DrawOptions.steps`) toward the most a history keeps (`DrawOptions.limit`), full where its
//! oldest steps start to go (`dome_rules.stepsFill`), or with a tape playing into it as it plays
//! (`DrawOptions.progress`),
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
//! (a drag on the line, a held undo or redo) grows the bar upward into a strip of them: each step's
//! picture of where it changed the document, at its own pixels, under the knob that goes there
//! (`paintStrip`). It stays while the pointer is on the bar.
//!
//! **Export.** The bar has an export button whenever the app can export (`DrawOptions.export_from`).
//! Pressed, it grows the strip and opens a window over it, as macOS trims a recording: a yellow
//! bracket over the part to export, dragged from either side (`history_transport.Trim`), the
//! document going to wherever a side is dragged and the rest dimmed. Pressed again, the part is
//! the app's (`Pressed.exported`); undo's button, a cross while the window is open, closes it.
//!
//! **Play.** Beside undo, play steps the document forward through its history at the pace it was
//! made (`DrawOptions.pace`), from where it stands, or from the start when it is at the end; inside
//! the export window, through the window's part. Any other move of the person's stops it. A tape
//! still playing into the document (`DrawOptions.tape_playing`) is paused and played on by the
//! same button (`Pressed.tape`), and play reaching the end of what has landed plays the tape on.
const HistoryTransport = @This();

const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const sdk = @import("fizzy_sdk");
const icons = @import("icons");
const rules = @import("history_transport.zig");
const dome = @import("dome.zig");
const Liquid = @import("Liquid.zig");
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
/// The liquid in a corner vial (`DrawOptions.corner`): sloshing as the vial moves, splashing and
/// its level easing up as steps come. It asks for frames only while it moves.
liquid: Liquid = .{},

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
/// Playing through the history: when it next steps. Null: not playing.
play: ?Play = null,

const Play = struct { next_ns: i128 };

/// How long each step waits when the app gives no pace (`DrawOptions.pace`), and the least any
/// waits, in ms.
const play_step_ms: u32 = 250;
const play_least_ms: u32 = 40;

const bar_h: f32 = 40;
/// How much taller the bar grows for its strip.
const strip_h: f32 = 66;
const button_d: f32 = 34;
/// How far in from the track's ends the line, and the strip over it, start.
const line_pad: f32 = 14;
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
    self.play = null;
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
    if (w < 4 * button_d) return null;
    const h = bar_h + strip_h * grown;
    const bottom = nat.y + nat.h - 14;
    return .{ .x = nat.x + nat.w / 2 - w / 2, .y = bottom - h, .w = w, .h = h };
}

/// The strip's size over `pane` (physical) fully grown, in physical pixels, at its widest (no
/// export button): what each step's picture is cut to (`HistoryFrames.take`), so the strip draws
/// it one pixel for one. Null when the pane is too narrow for the bar.
pub fn stripPixels(pane: dvui.Rect.Physical) ?[2]u32 {
    const s = dvui.windowRectScale().s;
    const whole = geometry(pane.toNatural(), 1) orelse return null;
    // As `draw` lays it out: the track between the buttons, less the line's ends; the strip's
    // height less its inset at the top and its gap at the bottom.
    const w = (whole.w - 3 * (button_d + gap) - 2 * line_pad) * s;
    const h = (strip_h - strip_top - 2) * s;
    if (w < 1 or h < 1) return null;
    // A pixel to spare each side: the strip's columns are rounded to whole pixels where `draw`
    // places them, so one can come out a pixel wider than this, and a crop narrower than its
    // column would leave glass beside it.
    return .{ @intFromFloat(@ceil(w) + 2), @intFromFloat(@ceil(h) + 2) };
}

/// The id `historyGoTo` takes for stop `i`: 0 before the first step, else the step's.
fn stopId(line: sdk.Plugin.HistoryLine, i: usize) u64 {
    return if (i == 0) 0 else line.entries[i - 1].id;
}

pub const DrawOptions = struct {
    /// The document has history to show: its pane has a grip. The app says, as it knows cheaply,
    /// so a pane asks its owner for nothing while the bar is hidden.
    history: bool = false,
    /// How many steps of it are kept, in the units `limit` counts (fizzy: its owner's history
    /// entries), for the grip's fill; 0: none shows, the grip is plain.
    steps: usize = 0,
    /// The most steps a history keeps (fizzy: `Settings.history_limit`, which each owner trims
    /// its own history to): the grip is full at it, where the oldest start to go. 0: kept whole.
    limit: usize = 0,
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
    /// The card the document is on, its bottom-right corner (`dome.Corner`): the grip is a vial
    /// there rather than a dome on the middle of `edge`, where a split's bar runs.
    corner: ?dome.Corner = null,
    /// That tape's steps are landing now (it is neither played out nor held): play's button pauses
    /// it.
    tape_playing: bool = false,
    /// How long play waits before each step, as the history was made; null: `play_step_ms` each.
    pace: ?Pace = null,
};

/// The app's word on how long play waits going from one history entry to the next (`from` 0:
/// before any), in ms; null when it does not know, and the step waits `play_step_ms`.
pub const Pace = struct {
    ctx: *const anyopaque,
    gapFn: *const fn (ctx: *const anyopaque, doc: sdk.DocHandle, from: u64, to: u64) ?u32,
};

const HistoryFrames = @import("HistoryFrames.zig");

/// What was pressed on the bar this frame that is the app's to act on.
pub const Pressed = struct {
    /// The window's part was exported: from stop `from` to stop `to` of the line.
    exported: ?rules.Trim = null,
    /// The tape playing into the document: true, play it on; false, pause it (`DrawOptions.tape_playing`).
    tape: ?bool = null,
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
    const on_grip = opts.history and !core.dialogs.modalOverCurrent() and if (opts.corner) |c|
        c.hit(dvui.windowRectScale().s).contains(mouse)
    else
        reach.contains(mouse) and if (gripRect(area, dome.radius, opts.edge)) |g| dvui.windowRectScale().rectToPhysical(g.outsetAll(dome.reach)).contains(mouse) else false;
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
    const fill = if (opts.progress) |f| dome_rules.progressFill(f) else dome_rules.stepsFill(opts.steps, opts.limit);
    // The grip, giving way to the bar as it comes in, quiet at rest and coming up while in use: a
    // frame each while it changes, and none while it only sits there.
    if (opts.history and p < 1) {
        if (self.grip_steps) |was| if (opts.steps > was) {
            self.stepped_at = now;
            self.slosh.knock(now, 0.35);
        };
        const stepped = if (self.grip_steps) |was| opts.steps > was else false;
        self.grip_steps = opts.steps;
        // Out of a corner vial, the liquid has poured into the line: the vial's own drains as the
        // bar comes out and fills again as it goes back, the one liquid all the way, so the vial at
        // rest takes over from the bar with no change of surface.
        self.liquid.setLevel(if (opts.corner != null) fill * (1 - dome.smooth(p / vial_drain)) else fill);
        if (opts.corner) |c| {
            self.liquid.step(now, c.point());
            // Into a vial, the new step splashes the surface, as a drop landing would: after the
            // step, so a step landing after an idle spell — when the liquid starts afresh, still —
            // splashes all the same. Only into a vial: a liquid nothing steps would hold its
            // splashes for when a vial came.
            if (stepped) self.liquid.splashIn();
        }
        const glow = self.stepGlow(now);
        if (glow == 0) self.stepped_at = null;
        const in_use = on_grip or self.stepped_at != null or !self.slosh.settled(now);
        const alpha = self.presence.ease(in_use, now);
        // While the bar grows out of it, the grip is the bar's glass: not drawn here.
        const grip_look: dome.Look = .{
            .alpha = alpha,
            .lit = on_grip,
            .held = self.dwell.held(now),
            .fill = fill,
            .glow = glow,
            .tilt = self.slosh.tilt(now),
            .liquid = if (opts.corner != null) &self.liquid else null,
        };
        if (p <= 0) if (opts.corner) |c| {
            if (dome.drawCorner(c, id_extra, grip_look, "history.grip:{s}", .{doc.owner.documentPath(doc)})) self.stir(now);
        } else if (gripRect(area, dome.radius, opts.edge)) |g| if (dome.draw(g, id_extra, grip_look, "history.grip:{s}", .{doc.owner.documentPath(doc)})) self.stir(now);
        if (self.dwell.since != null or self.stepped_at != null or !self.slosh.settled(now) or self.presence.moving(in_use) or
            (opts.corner != null and !self.liquid.settled())) dvui.refresh(null, @src(), null);
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
    const play_r: dvui.Rect = .{ .x = back.x + button_d + gap, .y = back.y, .w = button_d, .h = button_d };
    const track: dvui.Rect = .{ .x = play_r.x + button_d + gap, .y = whole.y, .w = w - 3 * (button_d + gap) - end_w, .h = whole.h };
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

    const phys = [5]dvui.Rect.Physical{ wrs.rectToPhysical(back), wrs.rectToPhysical(track), wrs.rectToPhysical(fwd), wrs.rectToPhysical(share), wrs.rectToPhysical(play_r) };
    const tab_p = wrs.rectToPhysical(tab);
    const x0 = phys[1].x + line_pad * s;
    const x1 = phys[1].x + phys[1].w - line_pad * s;
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
    core.anchor.markRect(fid, phys[4], true, "history.play:{s}", .{path});
    if (export_g > 0) core.anchor.markRect(fid, phys[3], true, "history.export:{s}", .{path});
    if (self.tab) core.anchor.markRect(fid, tab_p, true, "history.collapse:{s}", .{path});

    // Input: the buttons step, the line goes where it is pressed and follows a drag.
    var go: ?usize = null;
    var play_pressed = false;
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
                } else if (phys[4].contains(me.p)) {
                    play_pressed = true;
                } else if (self.tab and tab_p.contains(me.p)) {
                    // An open export window would keep the bar: it closes with it.
                    self.window = null;
                    self.grip = null;
                    self.play = null;
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
                        const grip = win.grab(me.p.x, x0, x1, (handle_w + trim_reach) * s, trim_reach * s);
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
    // Any other move of the person's stops play; play's own button starts or stops it.
    if (go != null) self.play = null;
    const lo: usize = if (self.window) |win| win.from else 0;
    const hi: usize = if (self.window) |win| win.to else n;
    if (play_pressed) {
        if (self.play != null or opts.tape_playing) {
            self.play = null;
            if (opts.tape_playing) pressed.tape = false;
        } else if (line.at >= hi and opts.progress != null and opts.progress.? < 1) {
            // At the end of what a held tape has landed: it plays on.
            pressed.tape = true;
        } else {
            const from = if (line.at >= hi or line.at < lo) lo else line.at;
            if (from != line.at) go = from;
            self.play = .{ .next_ns = now + std.time.ns_per_ms * @as(i128, playGap(opts.pace, doc, line, from)) };
        }
    }
    if (self.play) |*pl| if (go == null and now >= pl.next_ns) {
        if (line.at >= hi or line.at < lo) {
            self.play = null;
            // Played to the end of what has landed: a held tape plays on from there.
            if (self.window == null and opts.progress != null and opts.progress.? < 1) pressed.tape = true;
        } else {
            go = line.at + 1;
            pl.next_ns = now + std.time.ns_per_ms * @as(i128, playGap(opts.pace, doc, line, line.at + 1));
            self.shown.stir(now);
            if (opts.frames != null) self.strip.stir(now);
        }
    };
    var at = line.at;
    if (go) |to| if (to != at) {
        if (doc.owner.historyGoTo(doc, stopId(line, to))) at = to;
        dvui.refresh(null, @src(), fid);
    };
    // A scrub knocks the liquid, the way it went and as far.
    if (self.slosh_at) |was| if (was != at) {
        const by = (@as(f32, @floatFromInt(at)) - @as(f32, @floatFromInt(was))) / @as(f32, @floatFromInt(@max(1, n)));
        self.slosh.knock(now, dome_rules.knockFor(by));
        // The vial's liquid too, a scrub's step tipping it as the dome's swing does.
        if (opts.corner != null) self.liquid.knock(dome_rules.knockFor(by));
    };
    self.slosh_at = at;
    const tilt = self.slosh.tilt(now);

    // Coming in and going, a pane with a grip grows the bar out of it and takes it back in. The
    // bubbles bud out of the grip one after another (`bud_delays`) and pull away to their places,
    // the grip in the same glass and shrinking as they leave it, the glass between them reaching
    // further while they are near: they run together and part as drops do. What is on them shows
    // once they are most of the way out. Without a grip, it fades.
    const from: ?dvui.Rect.Physical = if (!opts.history or p >= 1) null else if (opts.corner) |c| c.box(s) else if (gripRect(area, dome.radius, opts.edge)) |g| wrs.rectToPhysical(g) else null;
    const out = dome.smooth(p);
    // What the bubbles bud out of and change back into: a dome's bud, or a corner vial's own circle.
    const home: ?dvui.Rect.Physical = if (from) |f| if (opts.corner) |c| c.home(s) else dome.bud(f) else null;
    const travel: f32 = if (from) |f| dome.bud(f).h else 0;
    // Out of a corner vial, which is whole at rest, the glass is whole throughout: eased toward a
    // dome's quiet presence, it was glass at partial alpha — a hole — and the vial at full alpha
    // the frame it went back in, a flash.
    const prev_alpha = dvui.alpha(if (opts.corner != null and from != null) 1 else if (from != null) dome.glassAlpha(self.presence.value, p) else p);
    defer dvui.alphaSet(prev_alpha);
    const pt = dvui.currentWindow().mouse_pt;
    var bubbles: [6]core.dialogs.Bubble = undefined;
    const trimming = self.window != null;
    // The line's bubble: a capsule round the line alone, easing to a surface's corners as the
    // strip grows, so the pictures sit inside them.
    const line_radius = std.math.lerp(phys[1].h / 2, core.corners.scaled(core.corners.card) * s, @min(1, grown * 1.5));
    for (phys, bubbles[0..5], 0..) |r, *b, i| b.* = .{
        .rect = if (home) |h| dome.pullFrom(h, travel, r, p, bud_delays[i], bud_arcs[i]) else r,
        .radius = if (i == 1 and grown > 0) line_radius else null,
        // Lit under the pointer only once the bar is out: moving, a lit bubble was a lighter drop
        // among the rest, its light running across the necks as they joined.
        .light = if (p >= 1 and r.contains(pt) and switch (i) {
            0 => trimming or at > 0,
            2 => !trimming and at < n,
            3, 4 => true,
            else => false,
        }) core.dialogs.bubble_hover else 0,
    };
    // The tab, a small drop on the bar's top that its glass runs into.
    // Play's bubble rides behind export's in the list, so export's may be left out.
    if (export_g <= 0) bubbles[3] = bubbles[4];
    var count: usize = if (export_g > 0) 5 else 4;
    var tab_index: ?usize = null;
    if (self.tab) {
        tab_index = count;
        bubbles[count] = .{
            .rect = if (home) |h| dome.pullFrom(h, travel, tab_p, p, bud_delays[5], bud_arcs[5]) else tab_p,
            .light = if (p >= 1 and tab_p.contains(pt)) core.dialogs.bubble_hover else 0,
        };
        count += 1;
    }
    // The grip itself, in the same glass, shrinking into the pane's edge as the bar leaves it.
    var shapes: [7]core.dialogs.Bubble = undefined;
    @memcpy(shapes[0..count], bubbles[0..count]);
    if (from) |f| {
        // A corner vial shrinks into its corner; a dome into its edge.
        shapes[count] = if (opts.corner) |c| .{ .rect = core.widgets.orb.rectOf(c.shape(s, 1 - dome.smooth(p))) } else dome.shrinking(f, p);
        count += 1;
    }
    {
        // Not past the pane's edge, which the grip stands on: the card, for a corner vial.
        const prev_clip = if (opts.corner) |c| dvui.clip(c.card) else if (from) |f| dvui.clip(dome.aboveEdge(f)) else dvui.clipGet();
        defer dvui.clipSet(prev_clip);
        // No shadow ring: each bubble's own ring lay dark across the necks where they run together
        // (the tab into the bar). The one soft shadow of the merged shape is the orb's
        // (`plans/LIQUID_EDGE_PLAN.md`); the rim and lens are what set the glass off meanwhile.
        // Out of a corner vial, cut by the card's outline, curve and all, as the vial is at rest.
        core.dialogs.glassBubbles(fid, shapes[0..count], s, .{ .merge = if (opts.corner != null) dome.cornerMerge(p, 14) else dome.merge(p, 14), .shadow = 0, .edge = if (opts.corner) |c| c.place() else null });
    }
    // A corner vial's contents change with it rather than fade: its liquid drains as the stream
    // pours out into the line and fills again as it pours back, and its icon shrinks into the
    // corner with the vial and grows back with it, so the vial the bar ends as is the vial at rest.
    if (opts.corner) |c| if (from != null) {
        const t = 1 - dome.smooth(p);
        // The vial's own liquid (drained by `setLevel` above) and its icon lit as at rest.
        const look: dome.Look = .{ .fill = fill, .tilt = tilt, .liquid = &self.liquid, .lit = on_grip, .glow = self.stepGlow(now) };
        dome.paintCornerLiquid(c, t, look);
        dome.cornerIcon(c, t, look, float.data().borderRectScale().r);
    };
    // What is on the bubbles comes once they are most of the way out; the liquid comes with them.
    const shape_alpha = dvui.alpha(1);
    if (from != null) {
        dvui.alphaSet(prev_alpha);
        _ = dvui.alpha(dome.contentAlpha(p));
    }

    const ink = dvui.themeGet().color(.window, .text);
    // Each icon on its bubble where the bubble is now, so it rides out of the grip with it and
    // grows with it, rather than waiting at the place the bubble is going to.
    const back_now = wrs.rectFromPhysical(bubbles[0].rect);
    const fwd_now = wrs.rectFromPhysical(bubbles[2].rect);
    const share_now = wrs.rectFromPhysical(bubbles[3].rect);
    if (trimming) {
        button(bounds, back_now, "history_cancel", icons.tvg.lucide.x, ink.opacity(0.85));
    } else button(bounds, back_now, "history_back", icons.tvg.lucide.undo, ink.opacity(if (at > 0) 0.85 else 0.3));
    button(bounds, fwd_now, "history_forward", icons.tvg.lucide.redo, ink.opacity(if (!trimming and at < n) 0.85 else 0.3));
    // Play's bubble is behind export's, or in its place when there is no export.
    const play_now = wrs.rectFromPhysical(bubbles[if (export_g > 0) 4 else 3].rect);
    if (self.play != null or opts.tape_playing) {
        button(bounds, play_now, "history_pause", icons.tvg.lucide.pause, ink.opacity(0.85));
    } else button(bounds, play_now, "history_play", icons.tvg.lucide.play, ink.opacity(if (hi > lo) 0.85 else 0.3));
    if (tab_index) |ti| dome.chevron(bounds, wrs.rectFromPhysical(bubbles[ti].rect), ink.opacity(0.85));
    if (export_g > 0.3) {
        if (trimming) {
            button(bounds, share_now, "history_export_done", icons.tvg.lucide.check, yellow);
        } else button(bounds, share_now, "history_export", icons.tvg.lucide.@"share-2", ink.opacity(0.85 * export_g));
    }

    // What the document is at, over the line: the step's title, and how far along.
    const font = dvui.Font.theme(.body).larger(-2);
    var buf: [96]u8 = undefined;
    const title = if (at == 0) "Before any change" else line.entries[at - 1].title;
    const label = if (trimming and opts.window_summary.len > 0) opts.window_summary else std.fmt.bufPrint(&buf, "{s}   {d} / {d}", .{ title, at, n }) catch title;
    // The strip of pictures, inset from the bar's top far enough that the trim's bracket round it
    // stays inside the glass, its corners the bar's own curve less that inset, so it never runs
    // into it.
    const film_top = strip_top * s;
    const film: dvui.Rect.Physical = .{ .x = x0, .y = phys[1].y + film_top, .w = x1 - x0, .h = @max(0, strip_h * grown * s - film_top - 2 * s) };
    const film_radius = @max(strip_radius * s, line_radius - film_top);
    if (grown > 0) if (opts.frames) |frames| paintStrip(film, film_radius, frames, line, at, s, grown);
    dvui.labelNoFmt(@src(), label, .{}, .{
        .rect = .{ .x = track.x + line_pad - bounds.x, .y = track.y + track.h - bar_h + 4 - bounds.y, .w = track.w - 2 * line_pad, .h = font.lineHeight() },
        .padding = .{},
        .margin = .{},
        .font = font,
        .color_text = .{ .color = ink.opacity(0.85) },
    });
    const line_r: dvui.Rect.Physical = .{ .x = x0, .y = phys[1].y + phys[1].h - 16 * s, .w = @max(1, x1 - x0), .h = 10 * s };
    // The grip's liquid, flowing out of it into the line as the bar grows (`from`, the grip's lower
    // part), and back as it goes.
    paintLine(line_r, at, n, ink, s, .{ .tilt = tilt, .from = if (from) |f| dome.pool(f, fill) else null, .out = out, .alpha = shape_alpha });
    if (self.window) |win| {
        // Round the strip of pictures alone, as a recorder's trim wraps its strip, not the bar.
        paintWindow(film.outsetAll(trim_inset * s + trim_edge * s), film_radius + trim_inset * s + trim_edge * s, x0, x1, win, s);
        // Its sides are what drag: the pointer over one, or dragging it, shows they move sideways.
        const over_side = film.outsetAll(8 * s).contains(pt) and win.grab(pt.x, x0, x1, (handle_w + trim_reach) * s, trim_reach * s) != .head;
        if (over_side or self.grip != null) dvui.cursorSet(.arrow_w_e);
    }

    // Comes in, goes: a frame each while it fades, and one wake for when it next changes on its
    // own (it starts to go, it is gone).
    if (p < 1 or (grown > 0 and grown < 1) or !self.slosh.settled(now)) dvui.refresh(null, @src(), fid);
    var next = if (self.strip.nextChange(now)) |t| @min(t, self.shown.nextChange(now) orelse t) else self.shown.nextChange(now);
    if (self.play) |pl| next = if (next) |t| @min(t, pl.next_ns) else pl.next_ns;
    if (next) |t| dvui.timer(fid, @intCast(@min(@divTrunc(t - now, 1000) + 1, std.math.maxInt(i32))));
    return pressed;
}

/// When each bubble buds out of the grip, as a share of the growing — the line first, then the
/// nearest the grip outward: export, redo, play, undo, the tab — each on its own moment so none
/// travels stacked on another; and how high each arcs, so their paths fan out. As `phys`: undo,
/// line, redo, export, play; then the tab.
const bud_delays = [6]f32{ 0.3, 0, 0.16, 0.08, 0.23, 0.36 };
const bud_arcs = [6]f32{ 1.3, 0.6, 1.0, 0.8, 1.15, 1.6 };

/// How far out of a corner vial the bar is when the vial's liquid has all poured out into the line
/// (and, coming back, when it starts to fill again).
const vial_drain: f32 = 0.45;

/// How bright the grip is from the step it took last, 1 as it lands to 0 after `step_glow_ns`.
fn stepGlow(self: *const HistoryTransport, now: i128) f32 {
    const t = self.stepped_at orelse return 0;
    if (now - t >= step_glow_ns) return 0;
    return 1 - @as(f32, @floatCast(@as(f64, @floatFromInt(now - t)) / @as(f64, @floatFromInt(step_glow_ns))));
}

/// macOS's trim yellow.
const yellow: dvui.Color = .{ .r = 0xF5, .g = 0xC0, .b = 0x2E };

/// Drag what `grip` holds of `win` to `stop`, the part never beginning before `min_from`. Returns
/// the stop the document goes to.
fn dragWindow(win: *rules.Trim, grip: rules.Trim.Grip, stop: usize, min_from: usize) usize {
    return win.drag(grip, @max(stop, if (grip == .to) min_from + 1 else min_from));
}

/// How long play waits at stop `at` before going on to the next, in ms.
fn playGap(pace: ?Pace, doc: sdk.DocHandle, line: sdk.Plugin.HistoryLine, at: usize) u32 {
    if (at >= line.entries.len) return play_step_ms;
    const ms = if (pace) |pc| pc.gapFn(pc.ctx, doc, stopId(line, at), stopId(line, at + 1)) orelse play_step_ms else play_step_ms;
    return @max(play_least_ms, ms);
}

/// The export window over `r` (physical: the strip and the line under it): the rest dimmed, a
/// yellow bracket over the part, a handle at each side.
/// The trim window's bracket, `trim_inset` inside `vessel` (physical), its outer corners `radius`
/// less that: drawn round the strip of pictures (`vessel` is the strip grown by the inset and the
/// bracket's own width), so its yellow wraps the pictures and nothing else.
fn paintWindow(vessel: dvui.Rect.Physical, radius: f32, x0: f32, x1: f32, win: rules.Trim, s: f32) void {
    const inset = trim_inset * s;
    const r = vessel.insetAll(inset);
    const ro = @max(2 * s, radius - inset);
    const ri: dvui.Corner.Physical = .round(1.5 * s);
    const outer: dvui.Corner.Physical = .round(ro);
    // On the edges of the first and last stops' slices, so the bracket holds whole slices.
    const xf = rules.cellStart(win.from, x0, x1, win.n);
    const xt = rules.cellEnd(win.to, x0, x1, win.n);
    const edge = trim_edge * s;
    const dim: dvui.Color = dvui.Color.black.opacity(0.6);
    const left = xf - handle_w * s;
    const right = xt + handle_w * s;
    if (left > r.x) (dvui.Rect.Physical{ .x = r.x, .y = r.y, .w = left - r.x, .h = r.h }).fill(.{ .tl = outer, .bl = outer, .tr = ri, .br = ri }, .{ .color = .{ .color = dim }, .fade = 1 });
    if (right < r.x + r.w) (dvui.Rect.Physical{ .x = right, .y = r.y, .w = r.x + r.w - right, .h = r.h }).fill(.{ .tl = ri, .bl = ri, .tr = outer, .br = outer }, .{ .color = .{ .color = dim }, .fade = 1 });
    (dvui.Rect.Physical{ .x = xf, .y = r.y, .w = xt - xf, .h = edge }).fill(.{}, .{ .color = .{ .color = yellow } });
    (dvui.Rect.Physical{ .x = xf, .y = r.y + r.h - edge, .w = xt - xf, .h = edge }).fill(.{}, .{ .color = .{ .color = yellow } });
    for ([_]f32{ left, xt }, [_]bool{ true, false }) |x, is_left| {
        const hr: dvui.Rect.Physical = .{ .x = x, .y = r.y, .w = handle_w * s, .h = r.h };
        hr.fill(if (is_left) .{ .tl = outer, .bl = outer, .tr = ri, .br = ri } else .{ .tl = ri, .bl = ri, .tr = outer, .br = outer }, .{ .color = .{ .color = yellow }, .fade = 1 });
        const notch: dvui.Rect.Physical = .{ .x = x + handle_w * s / 2 - 0.75 * s, .y = r.y + r.h / 2 - 6 * s, .w = 1.5 * s, .h = 12 * s };
        notch.fill(.round(0.75 * s), .{ .color = .{ .color = .black } });
    }
}

/// The strip `r` (physical), its ends where the line's are: each stop's picture
/// (`HistoryFrames.Picture`) in its column (`history_transport.stripColumns`), under the knob that
/// goes to it. A picture is a crop of the document round where that step changed it, drawn one
/// pixel for one (`history_transport.oneToOne`), its middle in the column's, so across the strip
/// the steps read as the actions themselves, as crisp as the pane. A stop with no picture shows the
/// nearest that has one; none at all, the stretch stays glass. Where the document is, `at`, a line
/// across the strip says, as a recorder's playhead does, over the middle of its stop's column where
/// the knob below it is.
fn paintStrip(r: dvui.Rect.Physical, radius: f32, frames: *const HistoryFrames, line: sdk.Plugin.HistoryLine, at: usize, s: f32, grown: f32) void {
    if (r.h < 4 * s or r.w < 4 * s) return;
    const n = line.entries.len;
    var buf: [256]rules.Column = undefined;
    const columns = rules.stripColumns(n, r.x, r.x + r.w, 2 * s, &buf);
    const ink = dvui.themeGet().color(.window, .text);
    for (columns, 0..) |c, i| {
        // On whole pixels, so neighbouring slices meet edge to edge: a fractional edge is half
        // covered on both sides, and the glass shows through the join as a seam.
        const cx0 = @round(c.x0);
        const cx1 = @round(c.x1);
        const col: dvui.Rect.Physical = .{ .x = cx0, .y = r.y, .w = cx1 - cx0, .h = r.h };
        // The strip's own corners on its two end columns, square between them.
        const end: dvui.Corner.Physical = .round(radius);
        const square: dvui.Corner.Physical = .{ .kind = .square };
        const corners: dvui.CornerRect.Physical = .{
            .tl = if (i == 0) end else square,
            .bl = if (i == 0) end else square,
            .tr = if (i == columns.len - 1) end else square,
            .br = if (i == columns.len - 1) end else square,
        };
        const plain: dvui.Color = ink.opacity(0.06 * grown);
        const pic = nearestPicture(frames, line, c.stop) orelse {
            col.fill(corners, .{ .color = .{ .color = plain } });
            continue;
        };
        const fit = rules.oneToOne(.{ .x = col.x, .y = col.y, .w = col.w, .h = col.h }, .{ pic.tex.width, pic.tex.height }) orelse continue;
        // A picture smaller than its column (taken from a narrower pane): the rest plain.
        if (fit.dest.w < col.w or fit.dest.h < col.h) col.fill(corners, .{ .color = .{ .color = plain } });
        const dest: dvui.Rect.Physical = .{ .x = fit.dest.x, .y = fit.dest.y, .w = fit.dest.w, .h = fit.dest.h };
        // The strip's round ends only where the picture reaches them.
        const fills = dest.x == col.x and dest.w == col.w and dest.y == col.y and dest.h == col.h;
        const uv: dvui.Rect = .{ .x = fit.uv.x, .y = fit.uv.y, .w = fit.uv.w, .h = fit.uv.h };
        dvui.renderTexture(pic.tex, .{ .r = dest, .s = s }, .{ .uv = uv, .corners = (if (fills) corners else dvui.CornerRect.Physical{ .tl = square, .bl = square, .tr = square, .br = square }).scale(1 / s, dvui.CornerRect), .colormod = dvui.Color.white.opacity(grown) }) catch {};
    }
    // The playhead, standing a little past the strip's top and bottom, with a dark edge so it reads
    // over any picture.
    const hx = rules.stopX(at, r.x, r.x + r.w, n);
    const over = 3 * s;
    const head: dvui.Rect.Physical = .{ .x = hx - 1 * s, .y = r.y - over, .w = 2 * s, .h = r.h + 2 * over };
    head.outsetAll(0.75 * s).fill(.round(1.75 * s), .{ .color = .{ .color = dvui.Color.black.opacity(0.4 * grown) } });
    head.fill(.round(1 * s), .{ .color = .{ .color = dvui.themeGet().color(.highlight, .fill).opacity(grown) } });
}

/// The trim bracket's gap to what it holds, the width of its yellow and of its handles, in points;
/// the strip's own corner radius; and how far past a handle, either way, a press still takes it
/// (`Trim.grab`): inside that, a press on the strip is a seek.
const trim_inset: f32 = 5;
const trim_edge: f32 = 2.5;
const handle_w: f32 = 8;
const strip_radius: f32 = 4;
/// The strip's inset from the top of the bar, in points: room for the trim's bracket round it.
const strip_top: f32 = 12;
const trim_reach: f32 = 3;

/// The picture of stop `stop`, or of the nearest stop to it that has one.
fn nearestPicture(frames: *const HistoryFrames, line: sdk.Plugin.HistoryLine, stop: usize) ?HistoryFrames.Picture {
    const n = line.entries.len;
    var d: usize = 0;
    while (d <= n) : (d += 1) {
        if (stop + d <= n) if (frames.get(stopId(line, stop + d))) |t| return t;
        if (d > 0 and stop >= d) if (frames.get(stopId(line, stop - d))) |t| return t;
    }
    return null;
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
