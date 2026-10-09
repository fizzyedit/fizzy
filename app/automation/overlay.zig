//! What a viewer sees of a demo, over the app: the pointer the tape moves and a ripple where it
//! clicks, the keys it presses, its captions, and the bar to drive it with.
//!
//! Everything here is a function of the player's state and demo time — the caption showing is
//! whichever the tape has at `now`, the keystroke pill the last key op within a second of it —
//! so a seek shows exactly what live play showed at that moment, and there is nothing to rewind.
//!
//! The cards are the app's floating surface — a menu's, a tooltip's: frosted at the dialog style
//! (blur, opacity, lift, detail, refraction), cut with its corners, shadowed with its ring, and
//! opening and closing on its curves (`Reveal`). With the blur off, the plain dialog fill.
//!
//! Each part is a subwindow that takes no input (events fall through to the app; the bar is
//! hit-tested by `Player.frame` from the rects recorded here), raised above every other subwindow
//! each frame in drawing order, the pointer last — it has to be drawn over the menu it opened and
//! over the caption explaining it.
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const Player = @import("Player.zig");
const LiveDriver = @import("LiveDriver.zig");
const Input = @import("Input.zig");
const Tape = @import("tape").Tape;
const Sequencer = @import("tape").Sequencer;
const chord = @import("../keymap/chord.zig");
const icons = @import("icons");
const motion = core.motion;

/// How long a key or command stays among the popups at home.
const keys_ms: f64 = 2200;
/// How long the tape's pointer takes to fade away when it starts typing, and back when it moves.
const pointer_fade_ms: f32 = 140;
/// The height the transport bar takes along the bottom.
const slot_h: f32 = 56;
/// How long the bar stays after the real pointer last stirred, while playing.
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
    if (player.driving()) {
        const fw = layer(@src(), .{ .rect = win, .name = "DemoPointer" }, .{});
        defer fw.deinit();
        drawPointer(player);
    }
}

/// Draw the pointer of the live tape `driver` is playing, if any, and the ripple where it last
/// clicked: with real pointer motion held off while it plays, this is how a person sees what is
/// being pointed at. A live tape has no captions, keys or bar — it is not something to watch,
/// only to see. Call once a frame, after everything else in the frame has drawn.
pub fn drawLive(driver: *LiveDriver) void {
    if (!driver.playing()) return;
    const win: dvui.Rect = .cast(dvui.windowRect());
    const fw = layer(@src(), .{ .rect = win, .name = "LivePointer" }, .{});
    defer fw.deinit();

    const now = dvui.frameTimeNS();
    const hand = driver.hand;
    const ripple: ?Ripple = if (hand.press) |press| .{
        .pt = press.pt,
        .age_ms = @floatFromInt(@divTrunc(now - press.ns, std.time.ns_per_ms)),
    } else null;
    const since_ms: f32 = @floatFromInt(@divTrunc(now - hand.since_ns, std.time.ns_per_ms));
    const fade_ms = motion.durationMs(pointer_fade_ms);
    const in: f32 = if (fade_ms <= 0) 1 else std.math.clamp(since_ms / fade_ms, 0, 1);
    paintPointer(driver.seq.pointer, ripple, if (hand.typing) 1 - in else in, driver.input.held.count() > 0);
}

/// A floating widget that takes no input, raised to the top. A floating widget otherwise stays
/// just above the window it was made in, under anything opened after it; re-added as a subwindow
/// of its own it can be raised, and each call puts the new one above the last.
fn layer(src: std.builtin.SourceLocation, opts: dvui.Options, init: dvui.FloatingWidget.InitOptions) *dvui.FloatingWidget {
    var init_opts = init;
    init_opts.mouse_events = false;
    const fw = dvui.widgetAlloc(dvui.FloatingWidget);
    fw.init(src, init_opts, opts);
    const wd = fw.data();
    dvui.subwindowAdd(wd.id, wd.rect, wd.rectScale().r, false, null, false);
    dvui.raiseSubwindow(wd.id);
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
/// the way open, grown out of `origin` (a point in it, as fractions): the frost at the dialog
/// style and the shadow ring round it, or with the blur off the dialog fill over its shadow.
/// What the card draws after this is cut to the glass as it grows.
///
/// Before the alpha for its contents is set: glass forms rather than fades (`r.form`) — a frost
/// replaces what it covers, and at partial alpha would punch a hole.
fn glass(wd: *dvui.WidgetData, origin: dvui.Point, r: Reveal) void {
    const brs = wd.borderRectScale();
    const full = brs.r;
    const s = brs.s;
    const k = @max(0, r.grow);
    const o: dvui.Point.Physical = .{ .x = full.x + full.w * origin.x, .y = full.y + full.h * origin.y };
    const rect: dvui.Rect.Physical = .{
        .x = o.x + (full.x - o.x) * k,
        .y = o.y + (full.y - o.y) * k,
        .w = full.w * k,
        .h = full.h * k,
    };
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
            .detail = f.detail,
            .refraction = f.refraction,
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
        if (op.do != .move) continue;
        // The things it acts on, not the pane it acts in: covering an editor is unavoidable.
        if (tagRect(op.do.move.tag)) |r| if (small(r, win)) keep.appendAssumeCapacity(r);
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
    glass(pill.data(), .{ .x = 0.5, .y = 1 }, shown);
    const prev_alpha = dvui.alpha(shown.alpha);
    defer dvui.alphaSet(prev_alpha);
    if (label.stroke) |s| {
        core.keycaps.draw(@src(), keycapsStroke(s), .{
            .style = .caps,
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
/// The space between the bubbles, open.
const bar_gap: f32 = 12;
/// Points: how near two bubbles come before their glass runs together (`LiquidField.merge_px`).
const bar_merge: f32 = 16;
/// How long the bar takes to open and to close, as written (`motion.durationMs`).
const bar_open_ms: f32 = 620;
const bar_close_ms: f32 = 420;

/// The bar: chapter back, play/pause, chapter forward, the time and the scrubber, close. Opening,
/// it grows out of its middle as a single bar of glass and pinches apart into its bubbles; closing
/// is that run back (`barGeometry`). Returns how much of its slot it takes. Records its parts'
/// rects on `player.transport` for `Player.frame` to hit-test.
fn drawTransport(player: *Player, tape: *const Tape, win: dvui.Rect) f32 {
    const tr = &player.transport;
    // Playing, the bar gets out of the demo's way unless someone reaches for it. (A playing
    // player asks for every frame, so the linger runs out without a timer of its own.)
    const wall_ns = player.wallNs();
    const since_stirred: i128 = if (tr.stirred_ns) |ns| wall_ns - ns else std.math.maxInt(i64);
    // Closed from its close button, it closes whatever else would keep it open (`Player.close`).
    const p = barProgress(tr, wall_ns, !tr.closing and (player.state != .playing or tr.scrub != null or since_stirred < bar_linger_ns));

    const full_w = @min(640, win.w - 24);
    const center: dvui.Point = .{ .x = win.x + win.w / 2, .y = win.y + win.h - 12 - bar_h / 2 };
    const whole: dvui.Rect = .{ .x = center.x - full_w / 2, .y = center.y - bar_h / 2, .w = full_w, .h = bar_h };
    // Only a bar that can be seen, or is coming, takes clicks: one reached for opens on this
    // frame's stir, and the press that follows it at once is the bar's, not the app's.
    const wrs = dvui.windowRectScale();
    tr.bar = if (tr.wanted or p > 0.05) wrs.rectToPhysical(whole) else null;
    if (p <= 0.001) {
        tr.prev = .{};
        tr.play = .{};
        tr.next = .{};
        tr.track = .{};
        tr.close = .{};
        // Run back together and gone: the demo can go (`Player.frame`), on the next frame.
        if (tr.closing and !tr.shut) {
            tr.shut = true;
            dvui.refresh(null, @src(), null);
        }
        return 0;
    }

    var pieces: [5]dvui.Rect = undefined;
    const apart = barGeometry(center, full_w, p, &pieces);
    // The layer covers the bar and as far round it as its shadow and its glass's bridges reach.
    const bounds = whole.outsetAll(24);
    const fw = layer(@src(), .{ .rect = bounds, .name = "DemoTransport" }, .{});
    defer fw.deinit();
    const s = wrs.s;

    var phys: [5]dvui.Rect.Physical = undefined;
    for (pieces, &phys) |r, *out| out.* = wrs.rectToPhysical(r);
    tr.prev = phys[@intFromEnum(Piece.prev)];
    tr.play = phys[@intFromEnum(Piece.play)];
    tr.next = phys[@intFromEnum(Piece.next)];
    tr.close = phys[@intFromEnum(Piece.close)];
    const hovered: ?Piece = if (tr.pointer) |pt| for (phys, 0..) |r, i| {
        if (i != @intFromEnum(Piece.track) and r.contains(pt)) break @enumFromInt(i);
    } else null else null;

    barGlass(fw.data().id, &phys, s, hovered, apart);

    // What the bubbles hold comes in as they part, and goes as they run back together.
    const prev_alpha = dvui.alpha(std.math.clamp((p - 0.55) / 0.45, 0, 1));
    defer dvui.alphaSet(prev_alpha);
    const ink = theme().color(.content, .text);
    const playing = player.state == .playing or (player.state == .seeking and player.after_seek == .play);
    const play_glyph: Glyph = if (playing) .pause else if (player.state == .ended) .replay else .play;
    barIcon(bounds, pieces[@intFromEnum(Piece.prev)], .prev, ink.opacity(0.8));
    barIcon(bounds, pieces[@intFromEnum(Piece.play)], play_glyph, ink);
    barIcon(bounds, pieces[@intFromEnum(Piece.next)], .next, ink.opacity(0.8));
    barIcon(bounds, pieces[@intFromEnum(Piece.close)], .close, ink.opacity(0.65));
    tr.track = barTrack(player, tape, bounds, pieces[@intFromEnum(Piece.track)], ink);
    return std.math.clamp(p * 1.6, 0, 1);
}

/// The bar's pieces `p` of the way open (0 shut, 1 open), window-natural, into `out`; returns how
/// far apart they have come, 0 (one bar) to 1 (bubbles). First a single bar grows out of the
/// middle — its pieces abutting, so their glass runs together into one — rising to its height as
/// it widens; then the pieces draw apart, the bridges between them thinning to necks and letting
/// go, until each is a bubble of its own. Run backwards it closes.
fn barGeometry(center: dvui.Point, full_w: f32, p: f32, out: *[5]dvui.Rect) f32 {
    // The growing, on the arrival curve: past its width and back, when motion is playful.
    const grow = @max(0, motion.enter(std.math.clamp(p / 0.6, 0, 1)));
    // The parting overlaps the end of the growing, so the bar never sits still between them.
    const apart = std.math.clamp(motion.settle(std.math.clamp((p - 0.38) / 0.62, 0, 1)), 0, 1.2);
    var widths = piece_d;
    var round_w: f32 = 0;
    for (piece_d, 0..) |d, i| {
        if (i != @intFromEnum(Piece.track)) round_w += d;
    }
    widths[@intFromEnum(Piece.track)] = @max(80, full_w - round_w - 4 * bar_gap);
    const gap = bar_gap * apart;
    var total: f32 = 4 * gap;
    for (widths) |w| total += w;
    const lift = 0.55 + 0.45 * @min(grow, 1.1);
    var x = center.x - total * grow / 2;
    for (widths, 0..) |w, i| {
        const h = piece_d[i] * lift;
        out[i] = .{ .x = x, .y = center.y - h / 2, .w = w * grow, .h = h };
        x += (w + gap) * grow;
    }
    return std.math.clamp(apart, 0, 1);
}

/// The bar's glass: its pieces as one liquid glass (`LiquidField`), running together where they
/// are close, the hovered one lit; where the glass program is not there to draw it, or the blur is
/// off, each piece frosted (or filled) on its own. Their shadows come in as they part — a ring
/// round each piece would lie dark across the bridges while they are one.
fn barGlass(id: dvui.Id, pieces: []const dvui.Rect.Physical, s: f32, hovered: ?Piece, apart: f32) void {
    const bs = core.dialogs.surfaceShadow();
    defer for (pieces) |r| {
        if (r.w < 1 or r.h < 1) continue;
        core.dialogs.glassShadow(r, .round(r.h / 2 / s), s, bs, apart);
    };
    if (core.widgets.LiquidField.ready()) {
        var field: core.widgets.LiquidField = .{ .merge_px = bar_merge * s, .scale = s };
        for (pieces, 0..) |r, i| {
            if (r.w < 1 or r.h < 1) continue;
            field.add(.{
                .rect = r,
                .radii = @splat(r.h),
                .round = i != @intFromEnum(Piece.track),
                .light = if (hovered != null and @intFromEnum(hovered.?) == i) 0.14 else 0,
            });
        }
        if (core.dialogs.carriedFieldWhole(id, field, s)) return;
    }
    for (pieces, 0..) |r, i| {
        if (r.w < 1 or r.h < 1) continue;
        const round: dvui.CornerRect = .round(r.h / 2 / s);
        if (!core.dialogs.frostPane(id.update(@tagName(@as(Piece, @enumFromInt(i)))), r, round, s)) {
            r.fill(round.scale(s, dvui.CornerRect.Physical), .{ .color = .{ .color = core.dialogs.dialogFill() } });
        }
        if (hovered != null and @intFromEnum(hovered.?) == i) {
            r.fill(round.scale(s, dvui.CornerRect.Physical), .{ .color = .{ .color = core.dialogs.rowHover() } });
        }
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
        .id_extra = @intFromEnum(glyph),
        .rect = .{ .x = r.x + (r.w - d) / 2 - bounds.x, .y = r.y + (r.h - d) / 2 - bounds.y, .w = d, .h = d },
    });
}

/// The scrubber's capsule `r` (window-natural; `bounds` the layer's): the time, then the chapter's
/// name over the line with its ticks and knob. Returns where the line takes presses, physical.
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
    const chapter = if (tape.chapterAt(now)) |i| tape.chapters[i].title else tape.title;
    const ch = small_font.lineHeight();
    if (x1 - x0 > 8) {
        dvui.labelNoFmt(@src(), chapter, .{}, .{
            .rect = .{ .x = x0 - bounds.x, .y = r.y + 5 - bounds.y, .w = x1 - x0, .h = ch },
            .padding = .{},
            .margin = .{},
            .font = small_font,
            .color_text = .{ .color = ink.opacity(0.65) },
        });
    }
    const line = wrs.rectToPhysical(.{ .x = x0, .y = r.y + r.h - 18, .w = @max(0, x1 - x0), .h = 12 });
    if (line.w > 1) paintTrack(line, tape, now, total, ink, wrs.s);
    return line;
}

/// The bar opening when `want` turns true and closing when it turns false — 0 shut to 1 open,
/// linear in time over `bar_open_ms` and `bar_close_ms` at the user's speed, the curves being
/// `barGeometry`'s — kept on `tr` from frame to frame. Wall time (`now_ns`, `Player.wallNs`): it
/// answers the viewer's pointer, not the demo. Turned round part way, it carries on from as open
/// as it is.
fn barProgress(tr: *Player.Transport, now_ns: i128, want: bool) f32 {
    const open_ms: f64 = motion.durationMs(bar_open_ms);
    const close_ms: f64 = motion.durationMs(bar_close_ms);
    if (tr.since_ns == null or want != tr.wanted) {
        const was: f64 = if (tr.since_ns == null) 0 else tr.openness;
        const back_ms: f64 = if (want) was * open_ms else (1 - was) * close_ms;
        tr.wanted = want;
        tr.since_ns = now_ns - @as(i128, @intFromFloat(back_ms * std.time.ns_per_ms));
    }
    const ms = @as(f64, @floatFromInt(now_ns - tr.since_ns.?)) / std.time.ns_per_ms;
    const span = if (want) open_ms else close_ms;
    const u: f32 = if (span <= 0) 1 else @floatCast(std.math.clamp(ms / span, 0, 1));
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

fn paintTrack(r: dvui.Rect.Physical, tape: *const Tape, now: f64, total: f64, ink: dvui.Color, s: f32) void {
    const line_h = 4 * s;
    const line: dvui.Rect.Physical = .{ .x = r.x, .y = r.y + (r.h - line_h) / 2, .w = r.w, .h = line_h };
    line.fill(.all(line_h / 2), .{ .color = .{ .color = ink.opacity(0.15) } });
    const f: f32 = if (total > 0) @floatCast(std.math.clamp(now / total, 0, 1)) else 0;
    const accent = theme().color(.highlight, .fill);
    var done = line;
    done.w = line.w * f;
    if (done.w > 0) done.fill(.all(line_h / 2), .{ .color = .{ .color = accent } });
    // Chapter ticks: where a jump lands.
    for (tape.chapters) |c| {
        if (c.at == 0 or total <= 0) continue;
        const x = r.x + r.w * @as(f32, @floatCast(@as(f64, @floatFromInt(c.at)) / total));
        const tick: dvui.Rect.Physical = .{ .x = x - 1 * s, .y = r.y + 1 * s, .w = 2 * s, .h = r.h - 2 * s };
        tick.fill(.all(1 * s), .{ .color = .{ .color = ink.opacity(0.35) } });
    }
    var knob: dvui.Path.Builder = .init(dvui.currentWindow().lifo());
    defer knob.deinit();
    knob.addArc(.{ .x = line.x + done.w, .y = line.y + line_h / 2 }, 6 * s, std.math.tau, 0, true);
    knob.build().fillConvex(.{ .color = .{ .color = accent }, .fade = 1 });
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
    glass(pill.data(), .{ .x = 0.5, .y = 0 }, .{});
    dvui.labelNoFmt(@src(), "Catching up\u{2026}", .{}, .{ .color_text = .{ .color = theme().color(.content, .text) } });
    const wd = dvui.spacer(@src(), .{ .expand = .horizontal, .min_size_content = .{ .w = 120, .h = 3 } });
    const r = wd.rectScale().r;
    r.fill(.all(r.h / 2), .{ .color = .{ .color = theme().color(.content, .text).opacity(0.15) } });
    var done = r;
    done.w *= f;
    done.fill(.all(r.h / 2), .{ .color = .{ .color = theme().color(.highlight, .fill) } });
}

// ---- the pointer ---------------------------------------------------------------------------

/// The classic arrow, tip at the origin, in natural pixels.
const arrow = [_][2]f32{
    .{ 0, 0 },     .{ 0, 17 },     .{ 4.2, 13.2 },  .{ 7.2, 19.8 },
    .{ 10, 18.6 }, .{ 7.1, 12.2 }, .{ 12.6, 12.2 },
};

fn drawPointer(player: *Player) void {
    const ripple: ?Ripple = if (player.last_press) |press| .{ .pt = press.pt, .age_ms = player.seq.now - press.at } else null;
    // Out of the way of the words while the tape types, as a desktop's pointer is.
    const shown = player.pointerShown(motion.durationMs(pointer_fade_ms));
    paintPointer(player.seq.pointer, ripple, shown, player.input.held.count() > 0);
}

/// Where the last click landed, and how long ago.
const Ripple = struct { pt: Sequencer.Point, age_ms: f64 };

/// The pointer at `p`, `shown` of it, pressed in while a button is held; the ripple spreading
/// and fading from the last click.
fn paintPointer(p: Sequencer.Point, ripple: ?Ripple, shown: f32, pressed: bool) void {
    const s = dvui.windowNaturalScale() * 1.1;

    if (ripple) |press| {
        const age = press.age_ms;
        if (age >= 0 and age < 450) {
            const f: f32 = @floatCast(age / 450);
            var ring: dvui.Path.Builder = .init(dvui.currentWindow().lifo());
            defer ring.deinit();
            ring.addArc(.{ .x = press.pt.x, .y = press.pt.y }, (6 + 18 * f) * s, std.math.tau, 0, true);
            ring.build().stroke(.{
                .thickness = 2.5 * s * (1 - f) + 0.5,
                .color = .{ .color = theme().color(.highlight, .fill).opacity(0.85 * (1 - f)) },
                .closed = true,
            });
        }
    }

    if (shown <= 0) return;
    const prev_alpha = dvui.alpha(shown);
    defer dvui.alphaSet(prev_alpha);

    const k: f32 = if (pressed) 0.88 else 1;
    inline for (.{ true, false }) |shadow| {
        var path: dvui.Path.Builder = .init(dvui.currentWindow().lifo());
        defer path.deinit();
        const off: f32 = if (shadow) 1.6 * s else 0;
        for (arrow) |pt| path.addPoint(.{ .x = p.x + pt[0] * s * k + off * 0.6, .y = p.y + pt[1] * s * k + off });
        const built = path.build();
        if (shadow) {
            dvui.Path.fill(&.{built}, .{ .color = .{ .color = dvui.Color.black.opacity(0.28) }, .fade = 2.5 * s });
        } else {
            dvui.Path.fill(&.{built}, .{ .color = .{ .color = .white }, .fade = 1 });
            built.stroke(.{ .thickness = 1.1 * s, .color = .{ .color = dvui.Color.black.opacity(0.85) }, .closed = true });
        }
    }
}
