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
/// The pointer, and the layer every part of this overlay is drawn in.
const plain = @import("replay").overlay;
const LiveDriver = @import("replay").LiveDriver;
const Input = @import("replay").Input;
const Tape = @import("tape").Tape;
const Sequencer = @import("tape").Sequencer;
const chord = @import("tape").chord;
const icons = @import("icons");
const motion = core.motion;
const dome = @import("../dome.zig");
const dome_rules = @import("../dome_rules.zig");

/// How long a key or command stays among the popups at home.
const keys_ms: f64 = 2200;
/// The height the transport bar takes along the bottom.
const slot_h: f32 = 56;
/// How long the bar stays out of its dome, while playing, after the pointer was last on it or the
/// dome brought it.
const bar_linger_ns: i128 = 2500 * std.time.ns_per_ms;
/// How long a seek runs before the overlay says it is catching up.
const seeking_shown_after_ns: i128 = 150 * std.time.ns_per_ms;

/// Draw the overlay for `player`. Call once a frame, after everything else in the frame has drawn.
pub fn draw(player: *Player) void {
    const tape = player.tape() orelse return;
    const win: dvui.Rect = .cast(dvui.windowRect());

    // Everything else keeps above the bar, as much as the bar is open, so it slides up as the
    // bar opens and back down as it closes.
    const bar = drawTransport(player, tape, win);
    drawCaptions(player, tape, win, win.h - 24 - bar * slot_h);
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
const layer = plain.layer;

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
/// the way open, grown out of `origin` (a point in it, as fractions), in the window's material
/// (`core.material`): Liquid Glass where the window is made of it, the same lens as the key pills
/// and the transport's bubbles (`core.dialogs.glassBubbles`), a card's corners rather than a
/// capsule's; else the frost at the dialog style and the shadow ring round it, or with the blur
/// off the dialog fill over its shadow. What the card draws after this is cut to the glass as it
/// grows.
///
/// Before the alpha for its contents is set: glass forms rather than fades (`r.form`) — a frost
/// replaces what it covers, and at partial alpha would punch a hole. Liquid Glass grows with the
/// card instead, whole from its first frame, as the pills' does.
fn glass(wd: *dvui.WidgetData, origin: dvui.Point, r: Reveal) void {
    const s = wd.borderRectScale().s;
    const rect = grown(wd, origin, r);
    const c = corners();
    const bs = core.dialogs.surfaceShadow();
    if (core.widgets.LiquidField.ready() and core.widgets.liquidFrost() != null) {
        if (rect.w >= 1 and rect.h >= 1) core.dialogs.glassBubbles(wd.id, &.{.{ .rect = rect, .radius = c.tl.radius() * s }}, s, .{ .shadow = r.alpha });
    } else if (core.dialogs.dialogFrost()) |f| {
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
        rect.fill(pc, .{ .color = .{ .color = core.dialogs.dialogFill().opacity(r.alpha) } });
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
    for (tape.captions, 0..) |c, i| {
        if (!c.shownAt(now)) continue;
        const shown = Reveal.between(now, @floatFromInt(c.at), @floatFromInt(c.at + c.ms));
        if (c.place == .middle) {
            drawTitle(tape, c, i, shown, win);
        } else if (tape.besideAction(c)) {
            drawCallout(player, tape, c, i, shown, win, floor);
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
    const home = (if (tape.home.len > 0) tagRect(tape.home) else null) orelse win;
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
fn drawTitle(tape: *const Tape, c: Tape.Caption, index: usize, shown: Reveal, win: dvui.Rect) void {
    const home = (if (tape.home.len > 0) tagRect(tape.home) else null) orelse win;
    const w = @min(620, win.w - 32);
    const fw = layer(@src(), .{ .id_extra = index + 1, .max_size_content = .{ .w = w, .h = win.h } }, .{
        .from = dvui.windowRectScale().pointToPhysical(.{ .x = home.x + home.w / 2, .y = home.y + home.h / 2 }),
        .from_gravity_x = 0.5,
        .from_gravity_y = 0.5,
    });
    defer fw.deinit();
    captionCard(c, shown, .{ .x = 0.5, .y = 0.5 }, w);
}

/// A caption that narrates what the pointer does: a callout beside it, where the viewer is
/// looking (`callout`), gliding rather than jumping as what it is beside moves — or, while there
/// is nothing drawn yet to sit beside, at the foot of the home view. Each caption (`index`) its
/// own widget, so none is placed by the size of the one before it.
fn drawCallout(player: *Player, tape: *const Tape, c: Tape.Caption, index: usize, shown: Reveal, win: dvui.Rect, floor: f32) void {
    // Its size as last drawn, to keep the whole of it clear.
    const src = @src();
    const size: dvui.Size = dvui.minSizeGet(dvui.parentGet().extendId(src, index + 1)) orelse .{};
    const spot = callout(player, tape, c, win, size, floor) orelse blk: {
        const home = (if (tape.home.len > 0) tagRect(tape.home) else null) orelse win;
        break :blk Spot{ .at = .{
            .x = home.x + home.w / 2 - size.w / 2,
            .y = @min(home.y + home.h * home_down, floor) - size.h,
        } };
    };
    // A callout reads at a narrower measure than a card over a whole view.
    const w = @min(440, win.w - 32);
    // Where it belongs while it opens — it is placed by its size, which it only has once drawn —
    // and gliding after.
    const fw = layer(src, .{ .id_extra = index + 1, .max_size_content = .{ .w = w, .h = win.h } }, .{
        .from = dvui.windowRectScale().pointToPhysical(glide(c, spot.at, size.w == 0 or shown.alpha < 1)),
        .from_gravity_x = 1,
        .from_gravity_y = 1,
    });
    defer fw.deinit();
    // It opens out of the side nearest what it is beside, as a popover does from its anchor.
    captionCard(c, shown, spot.origin, w);
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

/// Where a caption goes: its top-left (natural), and the point in it (fractions) it opens from.
const Spot = struct {
    at: dvui.Point,
    origin: dvui.Point = .{ .x = 0.5, .y = 0.5 },
};

/// The space between a callout and what it is beside.
const callout_gap: f32 = 14;

/// A caption that narrates what the pointer does, beside what it is done to (`Caption.near`, else
/// `Tape.aimedAt`): to its right, or below, left or above it — the first of those that covers none
/// of it, the pointer, what the pointer is aimed at in the caption's time or what the caption says
/// to keep clear (`Caption.clear`), on the window and above `floor`; failing all four, the one
/// that covers least. Null when there is nothing to sit beside.
fn callout(player: *Player, tape: *const Tape, c: Tape.Caption, win: dvui.Rect, size: dvui.Size, floor: f32) ?Spot {
    const near = nearRect(player, tape, c, win) orelse return null;

    var keep_buf: [24]dvui.Rect = undefined;
    var keep: std.ArrayList(dvui.Rect) = .initBuffer(&keep_buf);
    keep.appendAssumeCapacity(near);
    if (player.pointerShown(0) > 0) {
        const p = dvui.windowRectScale().pointFromPhysical(.{ .x = player.seq.pointer.x, .y = player.seq.pointer.y });
        keep.appendAssumeCapacity(.{ .x = p.x - 4, .y = p.y - 4, .w = 22, .h = 28 });
    }
    for (c.clear) |tag| {
        if (keep.items.len == keep.capacity) break;
        if (tagRect(tag)) |r| keep.appendAssumeCapacity(r);
    }
    for (tape.ops) |op| {
        if (op.at < c.at) continue;
        if (op.at >= c.at + c.ms or keep.items.len == keep.capacity) break;
        const target = op.do.target() orelse continue;
        // The things it acts on, not the pane it acts in: covering an editor is unavoidable.
        if (tagRect(target.tag)) |r| if (small(r, win)) keep.appendAssumeCapacity(r);
    }

    const cy = near.y + near.h / 2;
    const cx = near.x + near.w / 2;
    // Below or above, its words line up with what it is beside.
    const lined = near.x - 18;
    const tries = [_]Spot{
        .{ .at = .{ .x = near.x + near.w + callout_gap, .y = cy - size.h / 2 } },
        .{ .at = .{ .x = lined, .y = near.y + near.h + callout_gap } },
        .{ .at = .{ .x = near.x - callout_gap - size.w, .y = cy - size.h / 2 } },
        .{ .at = .{ .x = lined, .y = near.y - callout_gap - size.h } },
    };
    var best: Spot = undefined;
    var best_covered: f32 = std.math.inf(f32);
    for (tries, 0..) |t, i| {
        const at: dvui.Point = .{
            .x = std.math.clamp(t.at.x, win.x + 16, @max(win.x + 16, win.x + win.w - 16 - size.w)),
            .y = std.math.clamp(t.at.y, win.y + 16, @max(win.y + 16, floor - size.h)),
        };
        const card: dvui.Rect = .{ .x = at.x, .y = at.y, .w = size.w, .h = size.h };
        var covered: f32 = 0;
        for (keep.items) |k| {
            const o = card.intersect(k);
            covered += @max(0, o.w) * @max(0, o.h);
        }
        // It opens out of the side facing what it is beside.
        const along_x = if (size.w > 0) std.math.clamp((cx - at.x) / size.w, 0, 1) else 0.5;
        const along_y = if (size.h > 0) std.math.clamp((cy - at.y) / size.h, 0, 1) else 0.5;
        const spot: Spot = .{ .at = at, .origin = switch (i) {
            0 => .{ .x = 0, .y = along_y },
            1 => .{ .x = along_x, .y = 0 },
            2 => .{ .x = 1, .y = along_y },
            else => .{ .x = along_x, .y = 1 },
        } };
        if (covered <= 0) return spot;
        if (covered < best_covered) {
            best = spot;
            best_covered = covered;
        }
    }
    return best;
}

/// What a caption sits beside, natural: what it names (`Caption.near`), else what the pointer is
/// aimed at in its time — the point it goes to, when that is a whole pane, and the pointer itself
/// while that is still to be drawn (a row in a pane that is opening), so it is beside the action
/// all along rather than waiting somewhere else for it.
fn nearRect(player: *Player, tape: *const Tape, c: Tape.Caption, win: dvui.Rect) ?dvui.Rect {
    if (c.near.len > 0) {
        if (tagRect(c.near)) |r| return r;
    }
    const aim = tape.aimedAt(c, player.seq.cursor) orelse return null;
    const r = (if (aim.tag.len > 0) tagRect(aim.tag) else null) orelse return pointRect(player.seq.pointer);
    if (small(r, win)) return r;
    return pointRect(Input.targetPoint(aim) orelse player.seq.pointer);
}

/// A point (physical) as a small rect around it, natural.
fn pointRect(p: Sequencer.Point) dvui.Rect {
    const n = dvui.windowRectScale().pointFromPhysical(.{ .x = p.x, .y = p.y });
    return .{ .x = n.x - 12, .y = n.y - 12, .w = 24, .h = 24 };
}

/// A tag's rect, natural, when it is drawn and visible.
fn tagRect(tag: []const u8) ?dvui.Rect {
    const td = dvui.tagGet(tag) orelse return null;
    if (!td.visible) return null;
    return dvui.windowRectScale().rectFromPhysical(td.rect);
}

/// A thing rather than a place: under two fifths of the window each way.
fn small(r: dvui.Rect, win: dvui.Rect) bool {
    return r.w <= win.w * 0.4 and r.h <= win.h * 0.4;
}

/// How quickly a caption follows what it is beside: the time constant of its glide, as written.
const glide_ms: f32 = 110;

/// Where caption `c` is this frame, eased toward `to`, so it follows the action rather than
/// jumping with it. A caption that has just come up, or is told to `snap`, is where it belongs;
/// with motion off it always is.
fn glide(c: Tape.Caption, to: dvui.Point, snap: bool) dvui.Point {
    const id = dvui.currentWindow().data().id;
    const same = if (dvui.dataGet(null, id, "_demo_caption_at", u32)) |at| at == c.at else false;
    dvui.dataSet(null, id, "_demo_caption_at", c.at);
    const from = (if (same and !snap) dvui.dataGet(null, id, "_demo_caption_pos", dvui.Point) else null) orelse to;
    const tau = motion.durationMs(glide_ms);
    const k: f32 = if (tau <= 0) 1 else 1 - @exp(-dvui.secondsSinceLastFrame() * 1000 / tau);
    var at: dvui.Point = .{ .x = from.x + (to.x - from.x) * k, .y = from.y + (to.y - from.y) * k };
    if (@abs(to.x - at.x) < 0.5 and @abs(to.y - at.y) < 0.5) {
        at = to;
    } else {
        // Still on its way: a paused player asks for no frames of its own.
        dvui.refresh(null, @src(), null);
    }
    dvui.dataSet(null, id, "_demo_caption_pos", at);
    return at;
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
/// When each bubble buds out of the dome, as a share of the growing (`dome.emerge`), by `Piece`
/// and then the tab: the track over the dome first, the buttons outward from it, the tab last.
const bud_delays = [6]f32{ 0.18, 0.12, 0.06, 0, 0.06, 0.3 };

/// What the bar's dome keeps from frame to frame: the pointer held on it, its liquid's swing and
/// how far along the tape it stood last frame, and whether the pointer was on the bar.
const DomeState = struct {
    /// The tape it was kept for: another's starts over.
    tape: usize = 0,
    dwell: dome_rules.Dwell = .{},
    presence: dome_rules.Presence = .{},
    slosh: dome_rules.Slosh = .{},
    at: ?f32 = null,
    was_on: bool = false,
};

/// The bar: chapter back, play/pause, chapter forward, the time and the scrubber, close. While a
/// tape plays it hides into a dome on the window's bottom edge (`dome.zig`, the one a document's
/// history hides into), its liquid how far the tape has played; the pointer held on the dome, or a
/// press, grows the bar back out of it, its bubbles budding out of the dome, and the liquid flows
/// out into the scrubber's line. The pointer on the bar keeps it; leaving, it goes back soon.
/// Paused or ended it stays out, unless its tab sent it in (`Transport.tucked`). Returns how much
/// of its slot it takes. Records its parts' rects on `player.transport` for `Player.frame` to
/// hit-test.
fn drawTransport(player: *Player, tape: *const Tape, win: dvui.Rect) f32 {
    const tr = &player.transport;
    // Wall time: it answers the viewer's pointer, not the demo. (A playing player asks for every
    // frame, so the linger runs out without a timer of its own.)
    const wall_ns = player.wallNs();
    const wrs = dvui.windowRectScale();
    const s = wrs.s;
    const full_w = @min(640, win.w - 24);
    const center: dvui.Point = .{ .x = win.x + win.w / 2, .y = win.y + win.h - 12 - bar_h / 2 };
    const whole: dvui.Rect = .{ .x = center.x - full_w / 2, .y = center.y - bar_h / 2, .w = full_w, .h = bar_h };
    const edge = win.y + win.h;

    const st = dvui.dataGetPtrDefault(null, dvui.currentWindow().data().id, "_demo_dome", DomeState, .{});
    if (st.tape != @intFromPtr(tape)) st.* = .{ .tape = @intFromPtr(tape) };
    const pointer = tr.pointer;
    const on = struct {
        fn f(r: ?dvui.Rect.Physical, pt: ?dvui.Point.Physical) bool {
            return if (r) |rr| if (pt) |q| rr.contains(q) else false else false;
        }
    }.f;
    // Held on the dome while the bar is in it: out it comes.
    const dome_hit = wrs.rectToPhysical(dome.rect(center.x, edge, dome.radius).outsetAll(dome.reach));
    if (st.dwell.hold(on(dome_hit, pointer), !tr.closing and tr.openness <= 0, wall_ns)) {
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
        (player.state != .playing or tr.scrub != null or since_stirred < bar_linger_ns));

    // How far the tape has played: the dome's liquid, and the scrubber's. A jump knocks it.
    const total: f64 = @floatFromInt(tape.duration());
    const played: f32 = if (total > 0) @floatCast(std.math.clamp(player.now() / total, 0, 1)) else 0;
    if (st.at) |was| if (@abs(played - was) >= knock_jump) st.slosh.knock(wall_ns, dome_rules.knockFor(played - was));
    st.at = played;
    const tilt = st.slosh.tilt(wall_ns);
    // Quiet at rest, up while the pointer is on it or its liquid swings.
    const in_use = on(dome_hit, pointer) or !st.slosh.settled(wall_ns);
    const presence = st.presence.ease(in_use, wall_ns);
    // A paused player asks for no frames of its own but while the dome lightens under a held
    // pointer, comes up or settles, or its liquid swings.
    if (st.dwell.since != null or !st.slosh.settled(wall_ns) or st.presence.moving(in_use)) dvui.refresh(null, @src(), null);

    // The dome, while the bar is in it: growing, it is the bar's glass. Not while closing, which
    // lets the demo go.
    const from = wrs.rectToPhysical(dome.rect(center.x, edge, dome.radius));
    tr.dome = null;
    if (p <= 0 and !tr.closing) {
        const r = dome.rect(center.x, edge, dome.radius);
        const fw = layer(@src(), .{ .rect = r.outsetAll(dome.reach), .name = "DemoDome" }, .{});
        defer fw.deinit();
        const pr = wrs.rectToPhysical(r);
        core.anchor.markRect(fw.data().id, pr, true, "demo.dome", .{});
        dome.paint(fw.data().id, pr, .{
            .alpha = presence,
            .lit = on(dome_hit, pointer),
            .held = st.dwell.held(wall_ns),
            .fill = dome_rules.progressFill(played),
            .tilt = tilt,
        });
        tr.dome = dome_hit;
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
        tr.tab = .{};
        // Run back into its dome and gone: the demo can go (`Player.frame`), on the next frame.
        if (tr.closing and !tr.shut) {
            tr.shut = true;
            dvui.refresh(null, @src(), null);
        }
        return 0;
    }

    var pieces: [5]dvui.Rect = undefined;
    barGeometry(center, full_w, &pieces);
    const tab = dome.tabRect(whole);
    // The layer covers the bar, its tab, and as far round them as its shadow and its glass's
    // bridges reach.
    const bounds = whole.outset(.{ .x = 24, .y = 24 + dome.tab_d + dome.tab_gap, .w = 24, .h = 24 });
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

    // The glass: the bubbles bud out of the dome one after another and pull away to their places
    // (`dome.emerge`), the dome in the same glass shrinking into the edge as they leave it, the
    // glass between them reaching further while they are near; the tab a small drop on the bar's
    // top that its glass runs into. Closing, no dome waits for them: the demo goes.
    {
        const bud = dome.bud(from);
        var bubbles: [7]core.dialogs.Bubble = undefined;
        for (phys, bubbles[0..5], 0..) |r, *b, i| b.* = .{
            .rect = dome.lerpRect(bud, r, dome.emerge(p, bud_delays[i])),
            .light = if (hovered != null and @backingInt(hovered.?) == i) core.dialogs.bubble_hover else 0,
        };
        bubbles[5] = .{ .rect = dome.lerpRect(bud, tab_p, dome.emerge(p, bud_delays[5])), .light = if (on(tab_p, pointer)) core.dialogs.bubble_hover else 0 };
        var count: usize = 6;
        if (!tr.closing) {
            bubbles[count] = dome.shrinking(from, p);
            count += 1;
        }
        const prev_clip = dvui.clip(dome.aboveEdge(from));
        defer dvui.clipSet(prev_clip);
        const prev_alpha = dvui.alpha(dome.glassAlpha(presence, p));
        defer dvui.alphaSet(prev_alpha);
        // No shadow ring, as the history bar has none: each bubble's own lay dark across the necks.
        core.dialogs.glassBubbles(fw.data().id, bubbles[0..count], s, .{ .merge = dome.merge(p, bar_merge), .shadow = 0 });
    }

    const ink = theme().color(.content, .text);
    const accent = theme().color(.highlight, .fill);
    {
        // What the bubbles hold comes once they are most of the way out, and goes first.
        const prev_alpha = dvui.alpha(dome.contentAlpha(p));
        defer dvui.alphaSet(prev_alpha);
        const playing = player.state == .playing or (player.state == .seeking and player.after_seek == .play);
        const play_glyph: Glyph = if (playing) .pause else if (player.state == .ended) .replay else .play;
        barIcon(bounds, pieces[@backingInt(Piece.prev)], .prev, ink.opacity(0.8));
        barIcon(bounds, pieces[@backingInt(Piece.play)], play_glyph, ink);
        barIcon(bounds, pieces[@backingInt(Piece.next)], .next, ink.opacity(0.8));
        barIcon(bounds, pieces[@backingInt(Piece.close)], .close, ink.opacity(0.65));
        dome.chevron(bounds, tab, ink.opacity(0.85));
        tr.track = barTrack(player, tape, bounds, pieces[@backingInt(Piece.track)], ink);
    }

    // The played part of the line: the dome's liquid, flowing out of it into the line as the bar
    // grows and back as it goes, with the liquid's own alpha; the knob over it with the contents.
    const line = tr.track;
    if (line.w > 1) {
        const th = 6 * s;
        const mid = line.y + line.h / 2;
        const knob_x = line.x + line.w * played;
        const done: dvui.Rect.Physical = .{ .x = line.x - th / 2, .y = mid - th / 2, .w = @max(th, knob_x - line.x + th), .h = th };
        // Nothing played and not growing: no dot of liquid at the line's start.
        if (played > 0 or p < 1) dome.pourTube(done, tilt, if (p < 1) dome.pool(from, dome_rules.progressFill(played)) else null, core.motion.enterFull(p), dome.glassAlpha(presence, p), accent);
        const prev_alpha = dvui.alpha(dome.contentAlpha(p));
        defer dvui.alphaSet(prev_alpha);
        var knob: dvui.Path.Builder = .init(dvui.currentWindow().lifo());
        defer knob.deinit();
        knob.addArc(.{ .x = knob_x, .y = mid }, 6 * s, std.math.tau, 0, true);
        knob.build().fillConvex(.{ .color = .{ .color = accent }, .fade = 1 });
    }
    return std.math.clamp(p * 1.6, 0, 1);
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
    const time = std.fmt.bufPrint(&buf, "{d}:{d:0>2} / {d}:{d:0>2}", .{
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

    // The speed, top right of the capsule: a press steps it (`Player.stepRate`).
    var speed_buf: [8]u8 = undefined;
    const speed = std.fmt.bufPrint(&speed_buf, "{d}\u{00D7}", .{player.rate}) catch "";
    const speed_w = small_font.textSize(speed).w;
    const speed_r: dvui.Rect = .{ .x = x1 - speed_w, .y = r.y + 5, .w = speed_w, .h = small_font.lineHeight() };
    dvui.labelNoFmt(@src(), speed, .{}, .{
        .rect = .{ .x = speed_r.x - bounds.x, .y = speed_r.y - bounds.y, .w = speed_r.w + 2, .h = speed_r.h },
        .padding = .{},
        .margin = .{},
        .font = small_font,
        .color_text = .{ .color = ink.opacity(if (player.rate == 1) 0.65 else 0.95) },
    });
    player.transport.speed = wrs.rectToPhysical(speed_r.outsetAll(4));
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
/// linear in time over the dome's growing time (`dome.growNs`) at the user's speed, the curves
/// being `dome.emerge`'s — kept on `tr` from frame to frame. Wall time (`now_ns`, `Player.wallNs`):
/// it answers the viewer's pointer, not the demo. Turned round part way, it carries on from as
/// open as it is.
fn barProgress(tr: *Player.Transport, now_ns: i128, want: bool) f32 {
    const span: f64 = @floatFromInt(dome.growNs());
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
    line.fill(.all(line_h / 2), .{ .color = .{ .color = ink.opacity(0.15) } });
    for (tape.chapters) |c| {
        if (c.at == 0 or total <= 0) continue;
        const x = r.x + r.w * @as(f32, @floatCast(@as(f64, @floatFromInt(c.at)) / total));
        const tick: dvui.Rect.Physical = .{ .x = x - 1 * s, .y = r.y + 1 * s, .w = 2 * s, .h = r.h - 2 * s };
        tick.fill(.all(1 * s), .{ .color = .{ .color = ink.opacity(0.35) } });
    }
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
    r.fill(.all(r.h / 2), .{ .color = .{ .color = theme().color(.content, .text).opacity(0.15) } });
    var done = r;
    done.w *= f;
    done.fill(.all(r.h / 2), .{ .color = .{ .color = theme().color(.highlight, .fill) } });
}
