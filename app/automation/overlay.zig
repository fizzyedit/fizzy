//! What a viewer sees of a demo, over the app: the pointer the tape moves and a ripple where it
//! clicks, the keys it presses, its captions, and the bar to drive it with.
//!
//! Everything here is a function of the player's state and demo time — the caption showing is
//! whichever the tape has at `now`, the keystroke pill the last key op within a second of it —
//! so a seek shows exactly what live play showed at that moment, and there is nothing to rewind.
//!
//! The cards are the app's floating surface — a menu's, a tooltip's: in the window's material
//! (`core.material`), Liquid Glass where the window is made of it, as the key pills and the bar
//! are, else frosted at the dialog style (blur, opacity, refraction); cut with its corners,
//! shadowed with its ring, and opening and closing on its curves (`Reveal`). With the blur off,
//! the plain dialog fill.
//!
//! Each part is a subwindow that takes no input (events fall through to the app; the bar is
//! hit-tested by `Player.frame` from the rects recorded here), raised above every other subwindow
//! each frame in drawing order, the pointer last — it has to be drawn over the menu it opened and
//! over the caption explaining it.
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const Player = @import("replay").Player;
/// The pointer, and the layer every part of this overlay is drawn in (`layer`).
const plain = @import("replay").overlay;
const LiveDriver = @import("replay").LiveDriver;
const Stage = @import("replay").Stage;
const Input = @import("replay").Input;
const Tape = @import("tape").Tape;
const Sequencer = @import("tape").Sequencer;
const chord = @import("tape").chord;
const icons = @import("icons");
const motion = core.motion;
const dome = @import("../dome.zig");
const dome_rules = @import("../dome_rules.zig");
const Liquid = @import("../Liquid.zig");
const Calm = @import("Calm.zig");

/// How long a key or command stays among the popups at home.
const keys_ms: f64 = 2200;
/// How long the bar stays out of its corner, while playing, after the pointer was last on it or
/// the corner brought it.
const bar_linger_ns: i128 = 2500 * std.time.ns_per_ms;
/// How long a seek runs before the overlay says it is catching up.
const seeking_shown_after_ns: i128 = 150 * std.time.ns_per_ms;

/// Draw the overlay for `player`. Call once a frame, after everything else in the frame has drawn.
pub fn draw(player: *Player) void {
    const tape = player.tape() orelse return;
    const win: dvui.Rect = .cast(dvui.windowRect());

    // Everything else keeps above the bar, as much as the bar is open, so it slides up as the
    // bar opens and back down as it closes.
    drawCaptions(player, tape, win, drawTransport(player, tape, win));
    // Only a seek long enough to notice says so: most land in a frame or a few.
    if (player.state == .seeking and player.seekingNs() > seeking_shown_after_ns) drawSeeking(player, win);
    // The pointer last: over the menu it opened and the caption explaining it.
    plain.drawPlayer(player, .{ .fade_ms = motion.durationMs(plain_fade_ms) });
}

/// Draw the pointer of the live tape `driver` is playing, if any, and the ripple where it last
/// clicked (`replay.overlay`), its fade scaled for reduced motion. A live tape has no captions,
/// keys or bar — it is not something to watch, only to see. Call once a frame, after everything
/// else in the frame has drawn.
pub fn drawLive(driver: *LiveDriver) void {
    plain.drawLive(driver, .{ .fade_ms = motion.durationMs(plain_fade_ms) });
}

/// How long the tape's pointer takes to step aside when it types, and back when it moves.
const plain_fade_ms = (plain.Options{}).fade_ms;

/// A part of the overlay in a layer of its own (`replay.overlay.layer`), kept to the main window
/// (`core.screens.markMain`): the captions, keys and bar are the stage's, and stay on it while a
/// dialog or a menu is open in a window of its own over it. Only the pointer, and a callout beside
/// what it acts on (`drawCallout`), go into those windows. Every part goes through this.
fn layer(src: std.lang.SourceLocation, opts: dvui.Options, init: dvui.FloatingWidget.InitOptions) *dvui.FloatingWidget {
    const fw = plain.layer(src, opts, init);
    core.screens.markMain(fw.data().id);
    return fw;
}

fn theme() dvui.Theme {
    return dvui.themeGet();
}

// ---- the glass -----------------------------------------------------------------------------

/// A card's corners: a floating surface's (`dialogs.surfaceCorners`), resolved against the theme
/// up front — the frost is handed them directly, and unresolved it would draw them square.
fn corners() dvui.CornerRect {
    const t = theme();
    return core.dialogs.surfaceCorners().finalize(&t);
}

/// A card's own options: the space it takes and nothing it paints — `glass` lays the surface
/// down under what it holds, kept clear of its corners however round they are.
fn cardOptions(pad: dvui.Rect) dvui.Options {
    const inset = core.dialogs.cornerInset(corners().tl.radius());
    return .{
        .background = false,
        .border = .all(0),
        .corners = corners(),
        .padding = .{ .x = @max(pad.x, inset), .y = @max(pad.y, inset), .w = @max(pad.w, inset), .h = @max(pad.h, inset) },
    };
}

/// How long a card takes to open: a little quicker than a menu (`motion.open_us`), since a demo's
/// cards come and go all the while — in ms at the user's speed.
fn openMs() f64 {
    return motion.durationMs(@as(f32, @floatFromInt(motion.open_us)) / 1000 * 0.7);
}
/// How long one takes to close, likewise: brisker than a window's close flight.
fn closeMs() f64 {
    return motion.durationMs(260);
}

/// How far open a card is: its glass formed (`form`, 0…1) and grown out of its origin (`grow`,
/// past 1 while it overshoots), and the alpha of what it holds.
const Reveal = struct {
    form: f32 = 1,
    grow: f32 = 1,
    alpha: f32 = 1,

    const shut: Reveal = .{ .form = 0, .grow = 0, .alpha = 0 };

    /// How much of its place a card this open takes up, 0…1, for what is stacked on it.
    fn room(self: Reveal) f32 {
        return std.math.clamp(self.grow, 0, 1);
    }

    /// `u` (0…1) of the way through opening, as a tooltip or a menu opens: the glass forming and
    /// what it holds fading in together (`motion.fade`) while it grows into place (`motion.enter`).
    fn opening(u: f32) Reveal {
        const f = motion.fade(u);
        return .{ .form = f, .grow = motion.enter(u), .alpha = f };
    }

    /// `w` (0…1) of the way through closing, as a window closes: drawn back into its origin on
    /// the leaving curve (`motion.exit`), the glass unforming with it, what it holds opaque for
    /// the first half of the way and gone as it arrives.
    fn closing(w: f32) Reveal {
        const travelled = motion.exit(w);
        const gone = std.math.clamp(travelled, 0, 1);
        const late = std.math.clamp((gone - 0.55) / 0.45, 0, 1);
        return .{ .form = 1 - gone, .grow = 1 - travelled, .alpha = 1 - late * late };
    }

    /// A card shown from `start` to `stop` (demo ms), at `t`: open by `start` + the opening time,
    /// closed by `stop`. A function of demo time, so a seek lands on the same frame of it.
    fn between(t: f64, start: f64, stop: f64) Reveal {
        if (t >= stop) return shut;
        const close = closeMs();
        if (t > stop - close) return closing(@floatCast((t - (stop - close)) / close));
        const open = openMs();
        if (open <= 0) return .{};
        return opening(@floatCast(std.math.clamp((t - start) / open, 0, 1)));
    }
};

/// The surface under a card — `wd` a box that paints nothing of its own (`cardOptions`) — `r` of
/// the way open, grown out of `origin` (a point in it, as fractions), in the material every
/// floating surface wears (`core.dialogs.dialogFrost`): the frost at the dialog style, clear
/// glass where the blur is off and the glass program draws, with the shadow ring round it; with
/// neither, the dialog fill over its shadow. What the card draws after this is cut to the glass
/// as it grows.
///
/// Before the alpha for its contents is set: glass forms rather than fades (`r.form`) — a frost
/// replaces what it covers, and at partial alpha would punch a hole.
fn glass(wd: *dvui.WidgetData, origin: dvui.Point, r: Reveal) void {
    const s = wd.borderRectScale().s;
    const rect = grown(wd, origin, r);
    const c = corners();
    const bs = core.dialogs.surfaceShadow();
    if (core.dialogs.dialogFrost()) |f| {
        // The ring after the frost, so the glass does not blur it in (`dialogs.glassShadow`).
        defer core.dialogs.glassShadow(rect, c, s, bs, r.alpha);
        // Under a couple of pixels of blur there is nothing to see yet.
        if (f.radius * r.form >= 2) core.widgets.BlurBackdrop.frostPane(wd.id, rect, c, s, .{
            .radius = f.radius,
            .refresh_ms = f.refresh_ms,
            .tint = f.tint,
            .mix = f.mix,
            .lift = f.lift,
            .refraction = f.refraction,
            .clear = f.clear,
            .form = r.form,
        });
    } else {
        const pc = c.scale(s, dvui.CornerRect.Physical);
        const shadow = rect.insetAll(s * bs.shrink).offsetPoint(bs.offset.scale(s, dvui.Point.Physical));
        shadow.fill(pc, .{ .color = .{ .color = bs.color.opacity(bs.alpha * r.alpha) }, .fade = s * bs.fade });
        rect.fill(pc, .{ .color = .{ .color = core.dialogs.dialogFill().opacity(r.alpha) }, .fade = 1 });
    }
    dvui.clipSet(dvui.clipGet().intersect(rect));
}

/// The glass under a pill — a key just pressed, the seek's progress — `r` of the way open, grown
/// out of `origin` as `glass` grows a card: a capsule of the same glass as the transport bar's
/// bubbles (`core.dialogs.glassBubbles`), so the player's controls and what it shows are one
/// material. What the pill draws after this is cut to the glass as it grows.
fn pillGlass(wd: *dvui.WidgetData, origin: dvui.Point, r: Reveal) void {
    const rect = grown(wd, origin, r);
    core.dialogs.glassBubbles(wd.id, &.{.{ .rect = rect }}, wd.borderRectScale().s, .{ .shadow = r.alpha });
    dvui.clipSet(dvui.clipGet().intersect(rect));
}

/// `wd`'s border rect `r.grow` of the way grown out of `origin` (a point in it, as fractions).
fn grown(wd: *dvui.WidgetData, origin: dvui.Point, r: Reveal) dvui.Rect.Physical {
    const full = wd.borderRectScale().r;
    const k = @max(0, r.grow);
    const o: dvui.Point.Physical = .{ .x = full.x + full.w * origin.x, .y = full.y + full.h * origin.y };
    return .{
        .x = o.x + (full.x - o.x) * k,
        .y = o.y + (full.y - o.y) * k,
        .w = full.w * k,
        .h = full.h * k,
    };
}

// ---- captions and keys ---------------------------------------------------------------------

/// How long a key or command stays among the popups at home.
const keys_ms_u32: u32 = @intFromFloat(keys_ms);
/// How far down the home view the foot of its stack of popups is.
const home_down: f32 = 0.78;
/// The space between popups in the stack.
const stack_gap: f32 = 14;

/// The demo's words and keys at the current moment, each where it belongs: a title card in the
/// middle of the home view (`Caption.Place.middle`); a callout beside the action for a caption
/// that narrates the pointer (`Tape.besideAction`); and everything else — captions about no one
/// thing, and the keys just pressed — stacked together at home (`drawStack`). All kept whole on
/// the window, above `floor`.
fn drawCaptions(player: *Player, tape: *const Tape, win: dvui.Rect, floor: f32) void {
    const now = player.now();
    var stack_buf: [16]Stacked = undefined;
    var stack: std.ArrayList(Stacked) = .initBuffer(&stack_buf);
    var callouts: usize = 0;
    for (tape.captions, 0..) |c, i| {
        if (!c.shownAt(now)) continue;
        const shown = Reveal.between(now, @floatFromInt(c.at), @floatFromInt(c.at + c.ms));
        if (c.place == .middle) {
            drawTitle(player.stage, tape, c, i, shown, win);
        } else if (tape.besideAction(c)) {
            drawCallout(player, tape, c, i, shown, win, floor, callouts == 0);
            callouts += 1;
        } else if (stack.items.len < stack.capacity) {
            stack.appendAssumeCapacity(.{ .what = .{ .caption = i }, .start = c.at, .shown = shown });
        }
    }
    // Not while a seek replays them: a key there is gone before it could be read.
    if (player.state != .seeking) {
        var keys_buf: [6]usize = undefined;
        for (tape.keysAt(player.seq.cursor, player.seq.now, keys_ms, &keys_buf)) |i| {
            if (stack.items.len == stack.capacity) break;
            const op = tape.ops[i];
            // A command shows on the pane it edits (`ActivityFeed`); the keys pressed show here.
            if (op.do == .command) continue;
            if (keysLabel(player, op) == null) continue;
            const at: f64 = @floatFromInt(op.at);
            stack.appendAssumeCapacity(.{
                .what = .{ .keys = i },
                .start = op.at,
                .shown = Reveal.between(player.seq.now, at, at + keys_ms),
            });
        }
    }
    drawStack(player, tape, stack.items, win, floor);
}

/// One of the popups stacked at home.
const Stacked = struct {
    what: union(enum) {
        /// Index into `Tape.captions`.
        caption: usize,
        /// Index into `Tape.ops`: a `key` or a `command`.
        keys: usize,
    },
    start: u32,
    shown: Reveal,

    /// Stable from frame to frame while it shows, so each keeps its own widget and size.
    fn key(self: Stacked) usize {
        return switch (self.what) {
            .caption => |i| i + 1,
            .keys => |i| i + 1 + (1 << 20),
        };
    }

    fn before(_: void, a: Stacked, b: Stacked) bool {
        return a.start < b.start;
    }
};

/// The popups at home, stacked up from its foot: the newest lowest, each older one above those
/// after it — as far above as they are open, so the stack pushes up as one opens below and
/// settles back as one below it closes.
fn drawStack(player: *Player, tape: *const Tape, items: []Stacked, win: dvui.Rect, floor: f32) void {
    std.sort.insertion(Stacked, items, {}, Stacked.before);
    const home = (if (tape.home.len > 0) tagRect(player.stage, tape.home) else null) orelse win;
    const base = @min(home.y + home.h * home_down, floor);
    const w = @min(520, win.w - 32);
    const cx = std.math.clamp(home.x + home.w / 2, win.x + 16 + w / 2, @max(win.x + 16 + w / 2, win.x + win.w - 16 - w / 2));
    const src = @src();
    var above: f32 = 0;
    var i = items.len;
    while (i > 0) {
        i -= 1;
        const item = items[i];
        const k = item.key();
        const h = if (dvui.minSizeGet(dvui.parentGet().extendId(src, k))) |ms| ms.h else 0;
        const fw = layer(src, .{ .id_extra = k, .max_size_content = .{ .w = w, .h = win.h } }, .{
            .from = dvui.windowRectScale().pointToPhysical(.{ .x = cx, .y = base - above }),
            .from_gravity_x = 0.5,
            .from_gravity_y = 0,
        });
        defer fw.deinit();
        if (item.what == .caption) core.anchor.mark(fw.data(), "automation.caption:{d}", .{item.what.caption});
        // Each opens up out of its foot, where it joins the stack.
        switch (item.what) {
            .caption => |ci| captionCard(tape.captions[ci], item.shown, .{ .x = 0.5, .y = 1 }, w),
            .keys => |oi| keysCard(player, tape.ops[oi], item.shown),
        }
        above += (h + stack_gap) * item.shown.room();
    }
}

/// A title card: in the middle of the home view, opening about its middle as a dialog does. Each
/// caption (`index`) its own widget, so none is placed by the size of the one before it.
fn drawTitle(stage: Stage, tape: *const Tape, c: Tape.Caption, index: usize, shown: Reveal, win: dvui.Rect) void {
    const home = (if (tape.home.len > 0) tagRect(stage, tape.home) else null) orelse win;
    const w = @min(620, win.w - 32);
    const fw = layer(@src(), .{ .id_extra = index + 1, .max_size_content = .{ .w = w, .h = win.h } }, .{
        .from = dvui.windowRectScale().pointToPhysical(.{ .x = home.x + home.w / 2, .y = home.y + home.h / 2 }),
        .from_gravity_x = 0.5,
        .from_gravity_y = 0.5,
    });
    defer fw.deinit();
    captionCard(c, shown, .{ .x = 0.5, .y = 0.5 }, w);
}

/// A caption that narrates what the pointer does: a callout beside what it is about, where the
/// viewer is looking — or, while there is nothing drawn yet to sit beside, at the foot of the home
/// view. It keeps its spot until the tape's focus moves on or the spot stops being good, then
/// travels there once, calmly (`Calm`). Each caption (`index`) its own widget, so none is placed by
/// the size of the one before it.
fn drawCallout(player: *Player, tape: *const Tape, c: Tape.Caption, index: usize, shown: Reveal, win: dvui.Rect, floor: f32, first: bool) void {
    // Its size as last drawn, to keep the whole of it clear.
    const src = @src();
    const size: dvui.Size = dvui.minSizeGet(dvui.parentGet().extendId(src, index + 1)) orelse .{};
    const subject = subjectOf(player, tape, c, win);
    // Its subject's window: the OS window that shows it (a float's, a dialog's), else the main one.
    // The callout is drawn there, in that window's own frame and bounds, so it sits beside the
    // subject rather than over the view or clamped back onto the main window.
    const own = if (subject) |s| windowAround(player, s.rect) else null;
    const frame = own orelse win;
    const in_main = own == null;
    // The stage's bar is in the main window, under the OS windows (`Transport.covered`): another
    // window has no bar to keep above, so its floor is its own foot.
    const floor_in = if (in_main) floor else frame.y + frame.h;
    var keep_buf: [40]dvui.Rect = undefined;
    const keep = keepClear(player, tape, c, win, !in_main, &keep_buf);
    const home = (if (in_main and tape.home.len > 0) tagRect(player.stage, tape.home) else null) orelse frame;
    const now = player.now();

    // Its own, so two showing at once each keep theirs.
    const id = dvui.currentWindow().data().id.update(std.mem.asBytes(&[2]usize{ c.at, index }));
    const state = dvui.dataGetPtrDefault(null, id, "_demo_callout", Calm, .{});
    const o = state.update(.{
        .caption = c.at,
        .subject = if (subject) |s| s.key else 0,
        .near = if (subject) |s| s.rect else null,
        .home = .{ .x = home.x + home.w / 2 - size.w / 2, .y = @min(home.y + home.h * home_down, floor_in) - size.h },
        .keep = keep,
        .bounds = .{
            .x = frame.x + 16,
            .y = frame.y + 16,
            .w = @max(0, frame.w - 32 - size.w),
            .h = @max(0, floor_in - size.h - frame.y - 16),
        },
        .size = size,
        .now = now,
        .rate = motion.durationMs(1),
        .side = c.side,
        // Placed by its size, which it only has once drawn, while it opens.
        .fresh = size.w == 0 or now < @as(f64, @floatFromInt(c.at)) + openMs(),
        .hold = now >= @as(f64, @floatFromInt(c.at + c.ms)) - closeMs(),
    });
    // Its travel runs on demo time: paused, it waits where it is, and asks for no frames.
    if (o.moving and player.state == .playing) dvui.refresh(null, @src(), null);

    // A callout reads at a narrower measure than a card over a whole view.
    const w = @min(440, frame.w - 32);
    // The first named, for what checks where it went (`callout_anchor`): a name is one widget's.
    const fw = plain.layer(src, .{ .id_extra = index + 1, .max_size_content = .{ .w = w, .h = frame.h }, .tag = if (first) callout_anchor else null }, .{
        .from = dvui.windowRectScale().pointToPhysical(o.at),
        .from_gravity_x = 1,
        .from_gravity_y = 1,
    });
    defer fw.deinit();
    // Beside what the pointer acts on, it goes where that is, as the pointer does: over a dialog's
    // button, into the dialog's window. At the foot of the home view it is the stage's (`layer`),
    // and so is one whose subject's window is too small to hold it (`windowAround`).
    if (subject == null or in_main) core.screens.markMain(fw.data().id);
    // It opens out of the side nearest what it is beside, as a popover does from its anchor.
    captionCard(c, shown, o.origin, w);
}

/// A caption's card in the floating widget just made, at measure `w`: its glass `shown` of the
/// way open out of `origin`, then its title and words.
fn captionCard(c: Tape.Caption, shown: Reveal, origin: dvui.Point, w: f32) void {
    var card = dvui.box(@src(), .{ .dir = .vertical }, cardOptions(.{ .x = 18, .y = 12, .w = 18, .h = 14 }).override(.{
        .max_size_content = .{ .w = w - 36, .h = dvui.max_float_safe },
    }));
    defer card.deinit();
    glass(card.data(), origin, shown);
    const prev_alpha = dvui.alpha(shown.alpha);
    defer dvui.alphaSet(prev_alpha);
    const heading = dvui.Font.theme(.heading);
    const body = dvui.Font.theme(.body);
    // The card fits its words: as wide as its longest line wants, up to the measure, past which
    // the text wraps and the card holds the measure. (A hair over the measured width, so the
    // layout never wraps a line that only just fits.)
    const fit = @min(w - 36, @ceil(@max(
        body.textSize(c.text).w,
        if (c.title.len > 0) heading.textSize(c.title).w else 0,
    )) + 1);
    if (c.title.len > 0) {
        dvui.labelNoFmt(@src(), c.title, .{}, .{
            .font = heading,
            .color_text = .{ .color = theme().color(.content, .text) },
            .padding = .{ .h = 4 },
            .margin = .{},
        });
    }
    var tl = dvui.textLayout(@src(), .{}, .{
        .background = false,
        .padding = .{},
        .margin = .{},
        .font = body,
        .color_text = .{ .color = theme().color(.content, .text).opacity(0.86) },
        .min_size_content = .{ .w = fit, .h = 1 },
    });
    tl.addText(c.text, .{});
    tl.deinit();
}

/// The anchor a callout is drawn under: where it is, for a test or an agent to check it covers
/// nothing it should not. The first showing, when two are.
pub const callout_anchor = "automation.callout";

/// How far ahead of the pointer a callout sets off for what the pointer goes to next, in demo ms:
/// it arrives as the pointer does, or a little before, rather than chasing it.
const lead_ms: f64 = 250;

/// What a callout is about this frame: its rect (natural), and a key that changes only when the
/// tape's focus moves on to something else.
const Subject = struct { rect: dvui.Rect, key: u64 };

/// What a caption sits beside: what it names (`Caption.near`), else what the pointer is aimed at in
/// its time (`Tape.aimedAt`), looking `lead_ms` ahead so it sets off with the pointer rather than
/// after it — the point the pointer goes to, when that is a whole pane, and the pointer itself
/// while what it goes to is still to be drawn (a row in a pane that is opening). Null when there is
/// nothing to sit beside.
fn subjectOf(player: *Player, tape: *const Tape, c: Tape.Caption, win: dvui.Rect) ?Subject {
    if (c.near.len > 0) {
        if (tagRect(player.stage, c.near)) |r| return .{ .rect = r, .key = std.hash.Wyhash.hash(0, c.near) };
    }
    var ahead = player.seq.cursor;
    const until = player.now() + lead_ms;
    while (ahead < tape.ops.len and @as(f64, @floatFromInt(tape.ops[ahead].at)) <= until) ahead += 1;
    const aim = tape.aimedAt(c, ahead) orelse return null;
    // One subject wherever on it the pointer goes — on a pane, how far the point moves is left to
    // the callout's reach (`Calm.reach`) — and another while it is still to be drawn, so the
    // callout goes to it once it is rather than staying by the pointer.
    var h = std.hash.Wyhash.init(1);
    h.update(aim.tag);
    const r = (if (aim.tag.len > 0) tagRect(player.stage, aim.tag) else null) orelse {
        h.update("?");
        return .{ .rect = pointRect(player.seq.pointer), .key = h.final() };
    };
    if (small(r, win)) return .{ .rect = r, .key = h.final() };
    return .{ .rect = pointRect(Input.targetPoint(player.stage, aim) orelse player.seq.pointer), .key = h.final() };
}

/// What a callout must not cover, besides what it is beside: what the caption says to keep clear
/// (`Caption.clear`); what the pointer goes to in the caption's time — the thing, or the point on
/// a pane, since covering an editor is unavoidable but covering where in it the pointer goes is
/// not; every bar out under the overlay (`dome.barsOut`: a document's history bar, a corner
/// vial), which is what a step brings out; and the pointer while it rests. Not while it moves: it
/// passes under the callout on its way, and would push it about.
fn keepClear(player: *Player, tape: *const Tape, c: Tape.Caption, win: dvui.Rect, in_window: bool, buf: []dvui.Rect) []const dvui.Rect {
    var keep: std.ArrayList(dvui.Rect) = .initBuffer(buf);
    if (player.pointerShown(0) > 0 and !pointerMoving(tape, player.now())) {
        const p = dvui.windowRectScale().pointFromPhysical(.{ .x = player.seq.pointer.x, .y = player.seq.pointer.y });
        keep.appendAssumeCapacity(.{ .x = p.x - 4, .y = p.y - 4, .w = 22, .h = 28 });
    }
    // Every OS window shown over the main one, where it lies there: a callout in the main window is
    // under it, and is not placed where it would be hidden. Not the subject's own, which the
    // callout is drawn in (`in_window`).
    const rs = dvui.windowRectScale();
    if (!in_window) {
        const tr = &player.transport;
        for (tr.covered_main[0..tr.covered_n]) |r| {
            if (keep.items.len == keep.capacity) break;
            keep.appendAssumeCapacity(rs.rectFromPhysical(r));
        }
    }
    for (c.clear) |tag| {
        if (keep.items.len == keep.capacity) break;
        if (tagRect(player.stage, tag)) |r| keep.appendAssumeCapacity(r);
    }
    for (tape.ops) |op| {
        if (op.at < c.at) continue;
        if (op.at >= c.at + c.ms or keep.items.len == keep.capacity) break;
        const target = op.do.target() orelse continue;
        const r = (if (target.tag.len > 0) tagRect(player.stage, target.tag) else null) orelse continue;
        if (small(r, win)) {
            keep.appendAssumeCapacity(r);
        } else if (Input.targetPoint(player.stage, target)) |p| keep.appendAssumeCapacity(pointRect(p));
    }
    for (dome.barsOut()) |b| {
        if (keep.items.len == keep.capacity) break;
        keep.appendAssumeCapacity(rs.rectFromPhysical(b));
    }
    return keep.items;
}

/// The least an OS window may be, natural, to draw a callout in (`windowAround`).
const min_window: dvui.Size = .{ .w = 300, .h = 160 };

/// The OS window (natural, its part of the frame) that `r`'s middle lies in, the topmost where
/// parts overlap (they are listed bottom to top), else null: the main window's. Not one too small
/// to hold a callout (a menu's), which the callout then keeps to the main window.
fn windowAround(player: *Player, r: dvui.Rect) ?dvui.Rect {
    const tr = &player.transport;
    const mid = dvui.windowRectScale().pointToPhysical(.{ .x = r.x + r.w / 2, .y = r.y + r.h / 2 });
    var i = tr.covered_n;
    while (i > 0) {
        i -= 1;
        const part = tr.covered[i];
        if (!part.contains(mid)) continue;
        const natural = dvui.windowRectScale().rectFromPhysical(part);
        return if (natural.w >= min_window.w and natural.h >= min_window.h) natural else null;
    }
    return null;
}

/// Whether a move or a trace is carrying the tape's pointer at `now` (demo ms).
fn pointerMoving(tape: *const Tape, now: f64) bool {
    for (tape.ops) |op| {
        const at: f64 = @floatFromInt(op.at);
        if (at > now) break;
        if (op.do != .move and op.do != .trace) continue;
        if (now < at + @as(f64, @floatFromInt(op.ms))) return true;
    }
    return false;
}

/// A point (physical) as a small rect around it, natural.
fn pointRect(p: Sequencer.Point) dvui.Rect {
    const n = dvui.windowRectScale().pointFromPhysical(.{ .x = p.x, .y = p.y });
    return .{ .x = n.x - 12, .y = n.y - 12, .w = 24, .h = 24 };
}

/// A tag's rect, natural, when it is drawn and visible.
fn tagRect(stage: Stage, tag: []const u8) ?dvui.Rect {
    const td = Input.tagData(stage, tag) orelse return null;
    if (!td.visible) return null;
    return dvui.windowRectScale().rectFromPhysical(td.rect);
}

/// A thing rather than a place: under two fifths of the window each way.
fn small(r: dvui.Rect, win: dvui.Rect) bool {
    return r.w <= win.w * 0.4 and r.h <= win.h * 0.4;
}

// ---- keystrokes ----------------------------------------------------------------------------

fn keycapsStroke(s: chord.Stroke) core.keycaps.Stroke {
    const one = struct {
        fn f(c: chord.Chord) core.keycaps.Chord {
            return .{
                .mods = .{ .ctrl = c.mods.ctrl, .shift = c.mods.shift, .alt = c.mods.alt, .command = c.mods.command },
                .key = @tagName(c.key),
            };
        }
    }.f;
    return .{ .first = one(s.first), .second = if (s.second) |c| one(c) else null };
}

/// What a key or command op shows: its chord (from the user's keymap, for a command) and, for a
/// command, what a person would call it. Null when there is neither.
fn keysLabel(player: *Player, op: Tape.Op) ?struct { stroke: ?chord.Stroke, title: ?[]const u8 } {
    const platform: chord.Platform = if (core.platform.isMacOS()) .mac else .other;
    const stroke: ?chord.Stroke, const title: ?[]const u8 = switch (op.do) {
        .key => |k| .{ chord.parseKeys(k, platform) catch null, null },
        .command => |c| .{ player.stage.chordFor(c.id), player.stage.commandTitle(c.id) },
        else => return null,
    };
    if (stroke == null and title == null) return null;
    return .{ .stroke = stroke, .title = title };
}

/// A pill naming a key or command just pressed, in the floating widget just made, `shown` of the
/// way open out of its foot.
fn keysCard(player: *Player, op: Tape.Op, shown: Reveal) void {
    const label = keysLabel(player, op) orelse return;
    var pill = dvui.box(@src(), .{ .dir = .horizontal }, cardOptions(.{ .x = 14, .y = 7, .w = 14, .h = 7 }));
    defer pill.deinit();
    pillGlass(pill.data(), .{ .x = 0.5, .y = 1 }, shown);
    const prev_alpha = dvui.alpha(shown.alpha);
    defer dvui.alphaSet(prev_alpha);
    if (label.stroke) |s| {
        core.keycaps.draw(@src(), keycapsStroke(s), .{
            .style = .caps,
            // Faint caps, so the glass reads through them as it does through the bar's icons.
            .cap_fill = theme().color(.content, .text).opacity(0.1),
            .color = theme().color(.content, .text),
            .mac = core.platform.isMacOS(),
            .gravity_x = 0,
        });
    }
    if (label.title) |t| {
        dvui.labelNoFmt(@src(), t, .{}, .{
            .gravity_y = 0.5,
            .padding = .{ .x = if (label.stroke != null) 10 else 0 },
            .color_text = .{ .color = theme().color(.content, .text) },
        });
    }
}

// ---- the transport bar ---------------------------------------------------------------------

/// The bar's pieces, left to right: round buttons for chapter back, play/pause and chapter
/// forward, the scrubber's capsule, and a round close — separate bubbles of one liquid glass.
const Piece = enum { prev, play, next, track, close };
/// Each piece's diameter, points; the track's width is what the bar leaves it.
const piece_d = [_]f32{ 36, 44, 36, 44, 32 };
const bar_h: f32 = 44;
/// The space between the bubbles.
const bar_gap: f32 = 12;
/// Points: how near two bubbles come before their glass runs together (`LiquidField.merge_px`).
const bar_merge: f32 = 16;
/// How far a frame's change of the tape's place must jump (a seek, a chapter, the scrubber) to
/// knock the dome's liquid: playing on, it only rises.
const knock_jump: f32 = 0.02;
/// When each bubble buds out of the corner, as a share of the growing (`dome.pullFrom`), by `Piece`
/// and then the tab: the nearest the corner first, close, then the track and the buttons outward,
/// the tab last; and how high each arcs, so their paths fan out.
const bud_delays = [6]f32{ 0.3, 0.24, 0.16, 0.08, 0, 0.36 };
const bud_arcs = [6]f32{ 1.3, 1.15, 1.0, 0.8, 0.6, 1.6 };
/// How far out of the corner the bar is when the corner's liquid has all poured out into the line
/// (and, coming back, when it starts to fill again).
const corner_drain: f32 = 0.45;

/// What the bar's corner keeps from frame to frame: the pointer held on it, its liquid, how far
/// along the tape and in which chapter it stood last frame, and whether the pointer was on the bar.
const CornerState = struct {
    /// The tape it was kept for: another's starts over.
    tape: usize = 0,
    dwell: dome_rules.Dwell = .{},
    liquid: Liquid = .{},
    at: ?f32 = null,
    chapter: ?usize = null,
    was_on: bool = false,
    /// How far the bar stands up from its place to clear a bar out under it, natural, eased.
    lift: f32 = 0,
};

/// Microseconds, as written, the bar takes to grow out of its corner and to go back: a little
/// brisker than a history bar's (`dome.growNs`), on the same curves.
const bar_grow_us: i32 = 450_000;
/// How far along its own growing (0 to 1, `dome.emerge`'s) a bubble's icon starts to show, and is
/// all there: hidden while the bubbles are still one glass, fading in once they have parted.
const icon_in_from: f32 = 0.45;
const icon_in_to: f32 = 0.8;

/// The space between the tape's bar and a bar it stacks above.
const bar_stack_gap: f32 = 10;
/// How quickly the bar moves up to clear a bar out under it, and back down: the time constant of
/// its easing, as written.
const lift_ms: f32 = 120;

/// The bar: chapter back, play/pause, chapter forward, the time and the scrubber, close. While a
/// tape plays it rests in the window's own bottom-right corner, in the corner glass a document's
/// history rests in (`dome.Corner`), cut by the window's outline rather than a card's and marked
/// with a tape: a tape plays over the whole app, not one document. Its liquid fills as the tape
/// plays (`Liquid`: a new chapter splashes it, a seek knocks it). The pointer held on it, or a
/// press, grows the bar out of it to the middle of the window's bottom, its bubbles budding out of
/// the corner, their icons riding on them, and its liquid pouring into the scrubber's line; going
/// back, the bubbles change back into the corner and the liquid pours back in, as the history bar
/// does into its vial. The pointer on the bar keeps it; leaving, it goes back soon. Paused or ended
/// it stays out, unless its tab sent it in (`Transport.tucked`). A pane's history vial or history
/// bar under it it stacks above (`dome.barsOut`), easing up to clear it and back down as it goes,
/// so both show at once. Returns how far down the window captions may come: above the bar, as much
/// as it is out. Records its parts' rects on `player.transport` for `Player.frame` to hit-test.
fn drawTransport(player: *Player, tape: *const Tape, win: dvui.Rect) f32 {
    const tr = &player.transport;
    // Wall time: it answers the viewer's pointer, not the demo. (A playing player asks for every
    // frame, so the linger runs out without a timer of its own.)
    const wall_ns = player.wallNs();
    const wrs = dvui.windowRectScale();
    const s = wrs.s;
    const corner: dome.Corner = .{
        .card = wrs.rectToPhysical(win),
        .radii = @splat(core.screens.mainRadius() * s),
        .icon = icons.tvg.lucide.@"cassette-tape",
        .icon_name = "demo_tape",
    };
    const box = corner.box(s);
    // The bar along the bottom of the window, in its middle, above the corner's glass.
    const full_w = @min(560, win.w - 24);
    const place: dvui.Rect = .{ .x = win.x + win.w / 2 - full_w / 2, .y = win.y + win.h - dome.corner_radius - 8 - bar_h, .w = full_w, .h = bar_h };

    const st = dvui.dataGetPtrDefault(null, dvui.currentWindow().data().id, "_demo_corner", CornerState, .{});
    if (st.tape != @intFromPtr(tape)) st.* = .{ .tape = @intFromPtr(tape) };
    // Above any bar out under it, eased there; in the corner, already where it will grow to.
    const lift = barLift(st, place, win, wrs, tr.openness <= 0);
    const whole: dvui.Rect = .{ .x = place.x, .y = place.y - lift, .w = place.w, .h = place.h };
    const center: dvui.Point = .{ .x = whole.x + whole.w / 2, .y = whole.y + bar_h / 2 };
    const floor_rest = win.y + win.h - 24;
    const pointer = tr.pointer;
    const on = struct {
        fn f(r: ?dvui.Rect.Physical, pt: ?dvui.Point.Physical) bool {
            return if (r) |rr| if (pt) |q| rr.contains(q) else false else false;
        }
    }.f;
    // Held on the corner while the bar is in it: out it comes.
    const hit = box;
    if (st.dwell.hold(on(hit, pointer), !tr.closing and tr.openness <= 0, wall_ns)) {
        tr.tucked = false;
        tr.stirred_ns = wall_ns;
    }
    // Left, it goes soon rather than lingering its whole time.
    const on_bar = on(tr.bar, pointer) or on(tr.tab, pointer);
    if (st.was_on and !on_bar) if (tr.stirred_ns) |ns| {
        tr.stirred_ns = @min(ns, wall_ns - (bar_linger_ns - dome_rules.leave_ns));
    };
    st.was_on = on_bar;
    const since_stirred: i128 = if (tr.stirred_ns) |ns| wall_ns - ns else std.math.maxInt(i64);
    // Closed from its close button, it closes whatever else would keep it open (`Player.close`).
    const p = barProgress(tr, wall_ns, !tr.closing and !tr.tucked and
        (player.state != .playing or tr.scrub != null or tr.speed_drag or since_stirred < bar_linger_ns));
    tr.dropStaleDrag();

    // How far the tape has played: the corner's liquid, and the scrubber's. A jump knocks it; a
    // new chapter, played into, splashes it.
    const total: f64 = @floatFromInt(tape.duration());
    const now = player.now();
    const played: f32 = if (total > 0) @floatCast(std.math.clamp(now / total, 0, 1)) else 0;
    const fill = dome_rules.progressFill(played);
    const chapter = tape.chapterAt(now);
    if (st.at) |was| {
        if (@abs(played - was) >= knock_jump) {
            st.liquid.knock(dome_rules.knockFor(played - was));
        } else if (chapter != null and st.chapter != null and chapter.? > st.chapter.?) st.liquid.splashIn();
    }
    st.at = played;
    st.chapter = chapter;
    // Out of the corner, the liquid has poured into the line: the corner's own drains as the bar
    // comes out and fills again as it goes back, the one liquid all the way, so the corner at rest
    // takes over from the bar with no change of surface.
    st.liquid.setLevel(fill * (1 - dome.smooth(p / corner_drain)));
    st.liquid.step(wall_ns, corner.point());
    // A paused player asks for no frames of its own but while the corner lightens under a held
    // pointer, or its liquid moves.
    if (st.dwell.since != null or !st.liquid.settled()) dvui.refresh(null, @src(), null);

    // The corner, while the bar is in it: growing, it is the bar's glass. Not while closing, which
    // lets the demo go.
    tr.rest = null;
    if (p <= 0 and !tr.closing) {
        const fw = layer(@src(), .{ .rect = wrs.rectFromPhysical(box), .name = "DemoCorner" }, .{});
        defer fw.deinit();
        core.anchor.markRect(fw.data().id, box, true, "demo.corner", .{});
        const look: dome.Look = .{ .lit = on(hit, pointer), .held = st.dwell.held(wall_ns), .fill = fill, .liquid = &st.liquid };
        dome.paintCorner(fw.data().id, corner, 1, look);
        dome.cornerIcon(corner, 1, look, fw.data().borderRectScale().r);
        tr.rest = hit;
    }

    // Only a bar that can be seen, or is coming, takes clicks: one reached for opens on this
    // frame's stir, and the press that follows it at once is the bar's, not the app's.
    tr.bar = if (tr.wanted or p > 0.05) wrs.rectToPhysical(whole) else null;
    if (p <= 0.001) {
        tr.prev = .{};
        tr.play = .{};
        tr.next = .{};
        tr.track = .{};
        tr.close = .{};
        tr.revert = .{};
        tr.tab = .{};
        // Run back into its corner and gone: the demo can go (`Player.frame`), on the next frame.
        if (tr.closing and !tr.shut) {
            tr.shut = true;
            dvui.refresh(null, @src(), null);
        }
        return floor_rest;
    }

    var pieces: [5]dvui.Rect = undefined;
    barGeometry(center, full_w, &pieces);
    const tab = dome.tabRect(whole);
    // The layer covers the bar, its tab, the corner it grows out of, and as far round them as the
    // glass's bridges reach.
    const bounds = whole.outset(.{ .x = 24, .y = 24 + dome.tab_d + dome.tab_gap, .w = 24, .h = 24 }).unionWith(wrs.rectFromPhysical(box));
    const fw = layer(@src(), .{ .rect = bounds, .name = "DemoTransport" }, .{});
    defer fw.deinit();

    var phys: [5]dvui.Rect.Physical = undefined;
    for (pieces, &phys) |r, *out| out.* = wrs.rectToPhysical(r);
    const tab_p = wrs.rectToPhysical(tab);
    tr.prev = phys[@backingInt(Piece.prev)];
    tr.play = phys[@backingInt(Piece.play)];
    tr.next = phys[@backingInt(Piece.next)];
    tr.close = phys[@backingInt(Piece.close)];
    tr.tab = tab_p;
    core.anchor.markRect(fw.data().id, tab_p, true, "demo.collapse", .{});
    const hovered: ?Piece = if (pointer) |pt| for (phys, 0..) |r, i| {
        if (i != @backingInt(Piece.track) and r.contains(pt)) break @fromBackingInt(@intCast(i));
    } else null else null;

    // The glass: the bubbles bud out of the corner one after another and pull away to their places
    // (`dome.pullFrom`), the corner in the same glass shrinking into the window's corner as they
    // leave it, the glass between them reaching further while they are near; going back, each
    // changes back into the corner, the glass between them letting go at the end so what is left
    // is the corner at rest. The tab a small drop on the bar's top that its glass runs into.
    // Closing, no corner waits for them: the demo goes.
    const out = dome.smooth(p);
    const home = corner.home(s);
    const travel = dome.bud(box).h;
    var bubbles: [7]core.dialogs.Bubble = undefined;
    for (phys, bubbles[0..5], 0..) |r, *b, i| b.* = .{
        .rect = dome.pullFrom(home, travel, r, p, bud_delays[i], bud_arcs[i]),
        .light = if (p >= 1 and hovered != null and @backingInt(hovered.?) == i) core.dialogs.bubble_hover else 0,
    };
    bubbles[5] = .{ .rect = dome.pullFrom(home, travel, tab_p, p, bud_delays[5], bud_arcs[5]), .light = if (p >= 1 and on(tab_p, pointer)) core.dialogs.bubble_hover else 0 };
    {
        var count: usize = 6;
        if (!tr.closing) {
            bubbles[count] = .{ .rect = core.widgets.orb.rectOf(corner.shape(s, 1 - out)) };
            count += 1;
        }
        // Cut by the window's outline, curve and all, as the corner is at rest. No shadow ring,
        // as the history bar has none: each bubble's own lay dark across the necks.
        core.dialogs.glassBubbles(fw.data().id, bubbles[0..count], s, .{ .merge = dome.homeMerge(p, bar_merge), .shadow = 0, .edge = corner.place() });
    }
    // The corner's contents change with it rather than fade: its liquid drains as it pours out into
    // the line and fills again as it pours back, its tape shrinking into the corner and growing back.
    if (!tr.closing) {
        // Its own liquid (drained by `setLevel` above), and its tape lit as at rest.
        const look: dome.Look = .{ .fill = fill, .liquid = &st.liquid, .lit = on(hit, pointer), .held = st.dwell.held(wall_ns) };
        dome.paintCornerLiquid(corner, 1 - out, look);
        dome.cornerIcon(corner, 1 - out, look, fw.data().borderRectScale().r);
    }

    const ink = theme().color(.content, .text);
    const accent = theme().color(.highlight, .fill);
    {
        // What the bubbles hold comes once they are most of the way out, and goes first.
        const prev_alpha = dvui.alpha(dome.contentAlpha(p));
        defer dvui.alphaSet(prev_alpha);
        tr.track = barTrack(player, tape, bounds, pieces[@backingInt(Piece.track)], ink);
    }
    {
        // Each icon on its bubble where the bubble is now, as big as it is, so it rides out of the
        // corner with it and back in, rather than fading.
        const playing = player.state == .playing or (player.state == .seeking and player.after_seek == .play);
        const play_glyph: Glyph = if (playing) .pause else if (player.state == .ended) .replay else .play;
        const now_r = struct {
            fn f(b: core.dialogs.Bubble) dvui.Rect {
                return dvui.windowRectScale().rectFromPhysical(b.rect);
            }
        }.f;
        // And fading with how far its bubble has come: gone by the time the bubbles run together
        // going back, and there only once they have parted coming out.
        const icon_alpha = struct {
            fn f(pp: f32, i: usize) f32 {
                const d = bud_delays[i];
                const t = dome.smooth(std.math.clamp((pp - d) / (1 - d), 0, 1));
                return dome.smooth((t - icon_in_from) / (icon_in_to - icon_in_from));
            }
        }.f;
        const glyphs = [_]Glyph{ .prev, play_glyph, .next };
        const inks = [_]f32{ 0.8, 1, 0.8 };
        for ([_]Piece{ .prev, .play, .next }, glyphs, inks) |pc, g, k| {
            const i = @backingInt(pc);
            barIcon(bounds, now_r(bubbles[i]), g, ink.opacity(k * icon_alpha(p, i)));
        }
        barIcon(bounds, now_r(bubbles[@backingInt(Piece.close)]), .close, ink.opacity(0.65 * icon_alpha(p, @backingInt(Piece.close))));
        dome.chevron(bounds, now_r(bubbles[5]), ink.opacity(0.85 * icon_alpha(p, 5)));
    }

    // The played part of the line: the corner's liquid, pouring out of it into the line as the bar
    // grows and back as it goes; the knob over it with the contents.
    const line = tr.track;
    if (line.w > 1) {
        const th = 6 * s;
        const mid = line.y + line.h / 2;
        const knob_x = line.x + line.w * played;
        const done: dvui.Rect.Physical = .{ .x = line.x - th / 2, .y = mid - th / 2, .w = @max(th, knob_x - line.x + th), .h = th };
        // Nothing played and not growing: no dot of liquid at the line's start.
        if (played > 0 or p < 1) dome.pourTube(done, 0, if (p < 1) dome.pool(box, fill) else null, out, 1, accent);
        const prev_alpha = dvui.alpha(dome.contentAlpha(p));
        defer dvui.alphaSet(prev_alpha);
        var knob: dvui.Path.Builder = .init(dvui.currentWindow().lifo());
        defer knob.deinit();
        knob.addArc(.{ .x = knob_x, .y = mid }, 6 * s, std.math.tau, 0, true);
        knob.build().fillConvex(.{ .color = .{ .color = accent }, .fade = 1 });
    }
    drawRevert(player, whole, p);
    return std.math.lerp(floor_rest, tab.y - 8, std.math.clamp(p * 1.6, 0, 1));
}

/// The pill over the bar's right end that gives the person back the session the demo set aside
/// (`Player.revert`): the one way back, since closing the player always leaves the app as it is. Shown while the tape is paused or
/// has ended, and the bar is all the way out. Records its rect on `player.transport` to be pressed.
fn drawRevert(player: *Player, whole: dvui.Rect, p: f32) void {
    const tr = &player.transport;
    const shown = p >= 1 and !tr.closing and (player.state == .paused or player.state == .ended or player.diverged);
    if (!shown) {
        tr.revert = .{};
        return;
    }
    const w: f32 = 156;
    const h: f32 = 30;
    const rect: dvui.Rect = .{ .x = whole.x + whole.w - w, .y = whole.y - h - 6, .w = w, .h = h };
    const fw = layer(@src(), .{ .rect = rect, .name = "DemoRevert" }, .{});
    defer fw.deinit();
    var pill = dvui.box(@src(), .{ .dir = .horizontal }, cardOptions(.{ .x = 12, .y = 5, .w = 12, .h = 5 }));
    defer pill.deinit();
    pillGlass(pill.data(), .{ .x = 0.5, .y = 0.5 }, .{});
    dvui.labelNoFmt(@src(), "Revert to before", .{}, .{
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .color_text = .{ .color = theme().color(.content, .text) },
    });
    tr.revert = pill.data().borderRectScale().r;
    core.anchor.markRect(fw.data().id, tr.revert, true, "demo.revert", .{});
}

/// How far up from `place` (natural) the tape's bar stands to clear the bars out under it this
/// frame (`dome.barsOut`): above each it would overlap, with `bar_stack_gap` between, looked at again
/// from where that puts it so it clears a stack of them. Eased toward that on `st.lift`, asking
/// for frames while it moves; `snap`, there at once (the bar is in its corner, and grows to it).
fn barLift(st: *CornerState, place: dvui.Rect, win: dvui.Rect, wrs: dvui.RectScale, snap: bool) f32 {
    var y = place.y;
    for (0..3) |_| {
        for (dome.barsOut()) |rp| {
            const r = wrs.rectFromPhysical(rp);
            const over = r.x < place.x + place.w and r.x + r.w > place.x and r.y < y + place.h + bar_stack_gap and r.y + r.h > y;
            if (over) y = @min(y, r.y - bar_stack_gap - place.h);
        }
    }
    // Never off the top of the window.
    const target = @max(0, place.y - @max(y, win.y + 8));
    if (snap) {
        st.lift = target;
        return target;
    }
    const tau = motion.durationMs(lift_ms);
    const k: f32 = if (tau <= 0) 1 else 1 - @exp(-dvui.secondsSinceLastFrame() * 1000 / tau);
    st.lift += (target - st.lift) * k;
    if (@abs(target - st.lift) < 0.5) st.lift = target else dvui.refresh(null, @src(), null);
    return st.lift;
}

/// The bar's pieces in place, window-natural, into `out`: round buttons and the track's capsule
/// side by side, `bar_gap` apart, centred on `center`.
fn barGeometry(center: dvui.Point, full_w: f32, out: *[5]dvui.Rect) void {
    var widths = piece_d;
    var round_w: f32 = 0;
    for (piece_d, 0..) |d, i| {
        if (i != @backingInt(Piece.track)) round_w += d;
    }
    widths[@backingInt(Piece.track)] = @max(80, full_w - round_w - 4 * bar_gap);
    var total: f32 = 4 * bar_gap;
    for (widths) |w| total += w;
    var x = center.x - total / 2;
    for (widths, 0..) |w, i| {
        out[i] = .{ .x = x, .y = center.y - piece_d[i] / 2, .w = w, .h = piece_d[i] };
        x += w + bar_gap;
    }
}

/// A bar button's icon, in the middle of its bubble `r` (window-natural; `bounds` the layer's).
fn barIcon(bounds: dvui.Rect, r: dvui.Rect, glyph: Glyph, color: dvui.Color) void {
    const name: []const u8, const tvg: []const u8 = switch (glyph) {
        .play => .{ "demo_play", icons.tvg.lucide.play },
        .pause => .{ "demo_pause", icons.tvg.lucide.pause },
        .replay => .{ "demo_replay", icons.tvg.lucide.@"rotate-ccw" },
        .prev => .{ "demo_prev", icons.tvg.lucide.@"skip-back" },
        .next => .{ "demo_next", icons.tvg.lucide.@"skip-forward" },
        .close => .{ "demo_close", icons.tvg.lucide.x },
    };
    const d = @min(r.w, r.h) * 0.42;
    if (d < 2) return;
    core.icon.icon(@src(), name, tvg, .{
        .stroke_color = .{ .color = color },
        .fill_color = .{ .color = color },
    }, .{
        .id_extra = @backingInt(glyph),
        .rect = .{ .x = r.x + (r.w - d) / 2 - bounds.x, .y = r.y + (r.h - d) / 2 - bounds.y, .w = d, .h = d },
    });
}

/// The scrubber's capsule `r` (window-natural; `bounds` the layer's): the time, then the chapter's
/// name over the line with its ticks. Returns where the line takes presses, physical; its played
/// part and knob are `drawTransport`'s, drawn past the capsule's clip as they flow out of the dome.
fn barTrack(player: *Player, tape: *const Tape, bounds: dvui.Rect, r: dvui.Rect, ink: dvui.Color) dvui.Rect.Physical {
    const wrs = dvui.windowRectScale();
    const prev_clip = dvui.clip(wrs.rectToPhysical(r));
    defer dvui.clipSet(prev_clip);
    const pad = r.h / 2 - 4;
    const now = player.now();
    const total: f64 = @floatFromInt(tape.duration());
    const mono = dvui.Font.theme(.mono);
    var buf: [48]u8 = undefined;
    const time = std.mem.print(&buf, "{d}:{d:0>2} / {d}:{d:0>2}", .{
        minutes(now), seconds(now), minutes(total), seconds(total),
    }) catch "";
    const time_w = mono.textSize(time).w;
    const line_h = mono.lineHeight();
    dvui.labelNoFmt(@src(), time, .{}, .{
        .rect = .{ .x = r.x + pad - bounds.x, .y = r.y + (r.h - line_h) / 2 - bounds.y, .w = time_w + 2, .h = line_h },
        .padding = .{},
        .margin = .{},
        .font = mono,
        .color_text = .{ .color = ink.opacity(0.8) },
    });

    const x0 = r.x + pad + time_w + 14;
    const x1 = r.x + r.w - pad;
    const small_font = dvui.Font.theme(.body).larger(-2);

    // The speed, top right of the capsule: its value, then a line with a notch for each of
    // `Sequencer.speeds`, which a press or drag snaps to (`Player.transportTakes`) and the arrow
    // keys step (`Player.speedKey`).
    var speed_buf: [8]u8 = undefined;
    const speed = std.mem.print(&speed_buf, "{d}x", .{player.seq.speed}) catch "";
    const value_w = small_font.textSize("0.75x").w;
    const slider_w: f32 = 64;
    const slider_h = small_font.lineHeight();
    const line_r: dvui.Rect = .{ .x = x1 - slider_w - 6, .y = r.y + 5, .w = slider_w, .h = slider_h };
    const value_r: dvui.Rect = .{ .x = line_r.x - 8 - value_w, .y = r.y + 5, .w = value_w, .h = slider_h };
    dvui.labelNoFmt(@src(), speed, .{}, .{
        .rect = .{ .x = value_r.x - bounds.x, .y = value_r.y - bounds.y, .w = value_r.w + 2, .h = value_r.h },
        .padding = .{},
        .margin = .{},
        .font = small_font,
        .color_text = .{ .color = ink.opacity(if (player.seq.speed == 1) 0.65 else 0.95) },
    });
    const line_p = wrs.rectToPhysical(line_r);
    player.transport.speed = wrs.rectToPhysical(line_r.outsetAll(4));
    player.transport.speed_line = line_p;
    paintSpeed(line_p, player.seq.speedIndex(), player.transport.speed_focus, ink, wrs.s);
    const speed_w = value_w + slider_w + 14;
    const chapter = if (tape.chapterAt(now)) |i| tape.chapters[i].title else tape.title;
    const ch = small_font.lineHeight();
    if (x1 - x0 > 8) {
        dvui.labelNoFmt(@src(), chapter, .{}, .{
            .rect = .{ .x = x0 - bounds.x, .y = r.y + 5 - bounds.y, .w = @max(0, x1 - x0 - speed_w - 10), .h = ch },
            .padding = .{},
            .margin = .{},
            .font = small_font,
            .color_text = .{ .color = ink.opacity(0.65) },
        });
    }
    const line = wrs.rectToPhysical(.{ .x = x0, .y = r.y + r.h - 18, .w = @max(0, x1 - x0), .h = 12 });
    if (line.w > 1) paintTrack(line, tape, total, ink, wrs.s);
    return line;
}

/// The bar opening when `want` turns true and closing when it turns false — 0 shut to 1 open,
/// linear in time over `bar_grow_us` at the user's speed, the curves being `dome.pullFrom`'s —
/// kept on `tr` from frame to frame. Wall time (`now_ns`, `Player.wallNs`): it answers the
/// viewer's pointer, not the demo. Turned round part way, it carries on from as open as it is.
fn barProgress(tr: *Player.Transport, now_ns: i128, want: bool) f32 {
    const span: f64 = @floatFromInt(@as(i128, motion.duration(bar_grow_us)) * std.time.ns_per_us);
    if (tr.since_ns == null or want != tr.wanted) {
        const was: f64 = if (tr.since_ns == null) 0 else tr.openness;
        const back: f64 = if (want) was * span else (1 - was) * span;
        tr.wanted = want;
        tr.since_ns = now_ns - @as(i128, @intFromFloat(back));
    }
    const u: f32 = if (span <= 0) 1 else @floatCast(std.math.clamp(@as(f64, @floatFromInt(now_ns - tr.since_ns.?)) / span, 0, 1));
    const p = if (want) u else 1 - u;
    tr.openness = p;
    // A paused player asks for no frames of its own.
    if (u < 1) dvui.refresh(null, @src(), null);
    return p;
}

fn minutes(ms: f64) u32 {
    return @intFromFloat(@max(0, ms) / 60_000);
}
fn seconds(ms: f64) u32 {
    return @intFromFloat(@mod(@max(0, ms) / 1000, 60));
}

/// The line `r` (physical) under the played part: its groove, and a tick at each chapter, where a
/// jump lands.
fn paintTrack(r: dvui.Rect.Physical, tape: *const Tape, total: f64, ink: dvui.Color, s: f32) void {
    const line_h = 4 * s;
    const line: dvui.Rect.Physical = .{ .x = r.x, .y = r.y + (r.h - line_h) / 2, .w = r.w, .h = line_h };
    line.fill(.all(line_h / 2), .{ .color = .{ .color = ink.opacity(0.15) }, .fade = 1 });
    for (tape.chapters) |c| {
        if (c.at == 0 or total <= 0) continue;
        const x = r.x + r.w * @as(f32, @floatCast(@as(f64, @floatFromInt(c.at)) / total));
        const tick: dvui.Rect.Physical = .{ .x = x - 1 * s, .y = r.y + 1 * s, .w = 2 * s, .h = r.h - 2 * s };
        tick.fill(.all(1 * s), .{ .color = .{ .color = ink.opacity(0.35) }, .fade = 1 });
    }
}

/// The speed slider's line in `r`: a notch for each of `Sequencer.speeds`, the knob on the chosen
/// one, ringed while the arrow keys are its.
fn paintSpeed(r: dvui.Rect.Physical, at: usize, focused: bool, ink: dvui.Color, s: f32) void {
    const n = Sequencer.speeds.len;
    const line_h = 2 * s;
    const mid = r.y + r.h / 2;
    const knob_d = 9 * s;
    const inset = knob_d / 2;
    const span = r.w - 2 * inset;
    const line: dvui.Rect.Physical = .{ .x = r.x + inset, .y = mid - line_h / 2, .w = span, .h = line_h };
    line.fill(.all(line_h / 2), .{ .color = .{ .color = ink.opacity(0.2) } });
    for (0..n) |i| {
        const x = line.x + span * @as(f32, @floatFromInt(i)) / @as(f32, n - 1);
        const notch: dvui.Rect.Physical = .{ .x = x - 1 * s, .y = mid - 3 * s, .w = 2 * s, .h = 6 * s };
        notch.fill(.all(1 * s), .{ .color = .{ .color = ink.opacity(if (i == at) 0 else 0.4) } });
    }
    const kx = line.x + span * @as(f32, @floatFromInt(at)) / @as(f32, n - 1);
    const knob: dvui.Rect.Physical = .{ .x = kx - knob_d / 2, .y = mid - knob_d / 2, .w = knob_d, .h = knob_d };
    if (focused) knob.outsetAll(2 * s).fill(.all(knob_d), .{ .color = .{ .color = ink.opacity(0.25) } });
    knob.fill(.all(knob_d / 2), .{ .color = .{ .color = ink } });
}

const Glyph = enum { play, pause, replay, prev, next, close };

// ---- seeking -------------------------------------------------------------------------------

/// While a seek replays, a pill at the top says so and how far it has got.
fn drawSeeking(player: *Player, win: dvui.Rect) void {
    const span = player.seek_target - player.seek_from;
    const f: f32 = if (span > 0) @floatCast(std.math.clamp((player.seq.now - player.seek_from) / span, 0, 1)) else 1;
    const fw = layer(@src(), .{}, .{
        .from = dvui.windowRectScale().pointToPhysical(.{ .x = win.w / 2, .y = 20 }),
        .from_gravity_x = 0.5,
        .from_gravity_y = 1,
    });
    defer fw.deinit();
    var pill = dvui.box(@src(), .{ .dir = .vertical }, cardOptions(.{ .x = 14, .y = 7, .w = 14, .h = 9 }));
    defer pill.deinit();
    // A seek runs with motion off, so there is no opening to play.
    pillGlass(pill.data(), .{ .x = 0.5, .y = 0 }, .{});
    dvui.labelNoFmt(@src(), "Catching up\u{2026}", .{}, .{ .color_text = .{ .color = theme().color(.content, .text) } });
    const wd = dvui.spacer(@src(), .{ .expand = .horizontal, .min_size_content = .{ .w = 120, .h = 3 } });
    const r = wd.rectScale().r;
    r.fill(.all(r.h / 2), .{ .color = .{ .color = theme().color(.content, .text).opacity(0.15) }, .fade = 1 });
    var done = r;
    done.w *= f;
    done.fill(.all(r.h / 2), .{ .color = .{ .color = theme().color(.highlight, .fill) }, .fade = 1 });
}

test "a caption's card is made of the material tooltips and menus wear" {
    const fns = struct {
        var blur: f32 = 0;
        var tooltip: ?f32 = null;
        var caption: ?f32 = null;
        var menu: ?core.widgets.BlurBackdrop.Pane = null;
        var dialog: ?core.widgets.FloatingWindowWidget.Frost = null;
        fn frame() !dvui.App.Result {
            core.dialogs.publishStyle(.{ .blur = blur, .opacity = 0.5 });
            menu = core.widgets.menuFrost();
            dialog = core.dialogs.dialogFrost();
            {
                var box = dvui.box(@src(), .{}, core.dialogs.tooltipOptions(0));
                defer box.deinit();
                core.dialogs.tooltipSurface(box.data());
                tooltip = radiusOf(box.data().id);
                dvui.labelNoFmt(@src(), "tooltip", .{}, .{});
            }
            {
                var box = dvui.box(@src(), .{}, cardOptions(.{}));
                defer box.deinit();
                glass(box.data(), .{ .x = 0.5, .y = 0.5 }, .{});
                caption = radiusOf(box.data().id);
                dvui.labelNoFmt(@src(), "caption", .{}, .{});
            }
            return .ok;
        }
        fn radiusOf(id: dvui.Id) ?f32 {
            const f = dvui.dataGetPtr(null, id, "_frost", core.widgets.BlurBackdrop) orelse return null;
            return f.radius_px;
        }
        /// A window of its own each, so no frost is left over from the other's frame.
        fn drawnAt(b: f32) !void {
            var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 300 } });
            defer t.deinit();
            blur = b;
            _ = try dvui.testing.step(frame);
        }
    };
    // Blur on: both are the dialog frost, at the style's radius.
    try fns.drawnAt(20);
    try std.testing.expectEqual(@as(?f32, 20), fns.tooltip);
    try std.testing.expectEqual(fns.tooltip, fns.caption);
    // The menus ask for the same frost from the same place.
    try std.testing.expectEqual(fns.dialog.?.radius, fns.menu.?.radius);
    try std.testing.expectEqual(fns.dialog.?.mix, fns.menu.?.mix);
    try std.testing.expectEqual(fns.dialog.?.tint, fns.menu.?.tint);
    // Blur off (and no glass program in the testing backend): a plain fill for both, no frost.
    try fns.drawnAt(0);
    try std.testing.expectEqual(@as(?f32, null), fns.tooltip);
    try std.testing.expectEqual(@as(?f32, null), fns.caption);
    try std.testing.expect(fns.menu == null);
}
