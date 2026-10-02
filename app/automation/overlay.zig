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
const Tape = @import("Tape.zig");
const Sequencer = @import("Sequencer.zig");
const chord = @import("../keymap/chord.zig");
const motion = core.motion;

/// How long a key or command stays in the keystroke pill.
const keys_ms: f64 = 2200;
/// The height of a slot along the bottom: the bar's, the keystroke pill's.
const slot_h: f32 = 56;
/// How long the bar stays after the real pointer last stirred, while playing.
const bar_linger_ns: i128 = 2500 * std.time.ns_per_ms;

/// Draw the overlay for `player`. Call once a frame, after everything else in the frame has drawn.
pub fn draw(player: *Player) void {
    const tape = player.tape() orelse return;
    const win: dvui.Rect = .cast(dvui.windowRect());

    // Each card along the bottom takes a slot above the one below it, as much of it as the card
    // is open, so what sits above slides up as it opens and back down as it closes.
    const bar = drawTransport(player, tape, win);
    const keys = drawKeys(player, win, bar);
    drawCaption(player, tape, win, bar + keys);
    if (player.state == .seeking) drawSeeking(player, win);
    if (player.driving()) {
        const fw = layer(@src(), .{ .rect = win, .name = "DemoPointer" }, .{});
        defer fw.deinit();
        drawPointer(player);
    }
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

/// A floating surface's opening time (`motion.open_us`), in ms at the user's speed.
fn openMs() f64 {
    return motion.durationMs(@as(f32, @floatFromInt(motion.open_us)) / 1000);
}
/// Its closing time — a window's close flight (`FloatingWindowWidget`) — likewise.
fn closeMs() f64 {
    return motion.durationMs(400);
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

// ---- captions ------------------------------------------------------------------------------

/// `below`: how many bottom slots the cards under a bottom caption take (`slot_h` each).
fn drawCaption(player: *Player, tape: *const Tape, win: dvui.Rect, below: f32) void {
    const now = player.now();
    const c = tape.captionAt(now) orelse return;
    const shown = Reveal.between(now, @floatFromInt(c.at), @floatFromInt(c.at + c.ms));

    const w = @min(620, win.w - 32);
    const from: dvui.Point = switch (c.place) {
        .top => .{ .x = win.w / 2, .y = 28 },
        .middle => .{ .x = win.w / 2, .y = win.h / 2 },
        .bottom => .{ .x = win.w / 2, .y = win.h - 24 - below * slot_h },
    };
    const gravity_y: f32 = switch (c.place) {
        .top => 1,
        .middle => 0.5,
        .bottom => 0,
    };
    const fw = layer(@src(), .{ .max_size_content = .{ .w = w, .h = win.h } }, .{
        .from = dvui.windowRectScale().pointToPhysical(from),
        .from_gravity_x = 0.5,
        .from_gravity_y = gravity_y,
    });
    defer fw.deinit();
    var card = dvui.box(@src(), .{ .dir = .vertical }, cardOptions(.{ .x = 18, .y = 12, .w = 18, .h = 14 }).override(.{
        .max_size_content = .{ .w = w - 36, .h = win.h },
    }));
    defer card.deinit();
    // It opens out of the edge it hangs from, as a menu slides out of its bar.
    glass(card.data(), .{ .x = 0.5, .y = 1 - gravity_y }, shown);
    const prev_alpha = dvui.alpha(shown.alpha);
    defer dvui.alphaSet(prev_alpha);
    if (c.title.len > 0) {
        dvui.labelNoFmt(@src(), c.title, .{}, .{
            .font = dvui.Font.theme(.heading),
            .color_text = .{ .color = theme().color(.content, .text) },
            .padding = .{ .h = 4 },
            .margin = .{},
        });
    }
    var tl = dvui.textLayout(@src(), .{}, .{
        .background = false,
        .padding = .{},
        .margin = .{},
        .color_text = .{ .color = theme().color(.content, .text).opacity(0.86) },
        .min_size_content = .{ .w = @min(w - 36, 420), .h = 1 },
    });
    tl.addText(c.text, .{});
    tl.deinit();
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

/// The pill naming the key or command just pressed, above `below` slots. Returns how much of its
/// slot it takes (`Reveal.room`).
fn drawKeys(player: *Player, win: dvui.Rect, below: f32) f32 {
    if (player.state == .seeking) return 0;
    const keys = player.recentKeys(keys_ms) orelse return 0;
    const op = keys.op;
    const platform: chord.Platform = if (core.platform.isMacOS()) .mac else .other;
    const stroke: ?chord.Stroke, const title: ?[]const u8 = switch (op.do) {
        .key => |k| .{ chord.parseKeys(k, platform) catch null, null },
        .command => |id| .{ player.stage.chordFor(id), player.stage.commandTitle(id) },
        else => unreachable,
    };
    if (stroke == null and title == null) return 0;

    const shown = Reveal.between(player.seq.now, keys.since, @as(f64, @floatFromInt(op.at)) + keys_ms);

    const fw = layer(@src(), .{}, .{
        .from = dvui.windowRectScale().pointToPhysical(.{ .x = win.w / 2, .y = win.h - 24 - below * slot_h }),
        .from_gravity_x = 0.5,
        .from_gravity_y = 0,
    });
    defer fw.deinit();
    var pill = dvui.box(@src(), .{ .dir = .horizontal }, cardOptions(.{ .x = 14, .y = 7, .w = 14, .h = 7 }));
    defer pill.deinit();
    glass(pill.data(), .{ .x = 0.5, .y = 1 }, shown);
    const prev_alpha = dvui.alpha(shown.alpha);
    defer dvui.alphaSet(prev_alpha);
    if (stroke) |s| {
        core.keycaps.draw(@src(), keycapsStroke(s), .{
            .style = .caps,
            .color = theme().color(.content, .text),
            .mac = platform == .mac,
            .gravity_x = 0,
        });
    }
    if (title) |t| {
        dvui.labelNoFmt(@src(), t, .{}, .{
            .gravity_y = 0.5,
            .padding = .{ .x = if (stroke != null) 10 else 0 },
            .color_text = .{ .color = theme().color(.content, .text) },
        });
    }
    return shown.room();
}

// ---- the transport bar ---------------------------------------------------------------------

/// The bar: chapter back, play/pause, chapter forward, time, the scrubber, close. Returns how much
/// of its slot it takes (`Reveal.room`). Records its parts' rects on `player.transport` for
/// `Player.frame` to hit-test.
fn drawTransport(player: *Player, tape: *const Tape, win: dvui.Rect) f32 {
    const tr = &player.transport;
    // Playing, the bar closes out of the demo's way unless someone reaches for it; it is still
    // laid out while closed, so it opens at its size rather than settling into it. (A playing
    // player asks for every frame, so the linger runs out without a timer of its own.)
    const since_stirred: i128 = if (tr.stirred_ns) |ns| dvui.frameTimeNS() - ns else std.math.maxInt(i64);
    const shown = barReveal(tr, player.state != .playing or tr.scrub != null or since_stirred < bar_linger_ns);

    const w = @min(640, win.w - 24);
    const h: f32 = 44;
    const rect: dvui.Rect = .{ .x = (win.w - w) / 2, .y = win.h - h - 12, .w = w, .h = h };
    const fw = layer(@src(), .{ .rect = rect, .name = "DemoTransport" }, .{});
    defer fw.deinit();
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, cardOptions(.{ .x = 10, .y = 6, .w = 12, .h = 6 }).override(.{
        .expand = .both,
    }));
    defer bar.deinit();
    glass(bar.data(), .{ .x = 0.5, .y = 1 }, shown);
    const prev_alpha = dvui.alpha(shown.alpha);
    defer dvui.alphaSet(prev_alpha);
    // Only a bar that can be seen, or is coming, takes clicks: one reached for opens on this
    // frame's stir, and the press that follows it at once is the bar's, not the app's.
    tr.bar = if (tr.wanted or shown.alpha > 0.05) bar.data().rectScale().r else null;

    const ink = theme().color(.content, .text);
    tr.prev = glyphButton(@src(), .prev, ink.opacity(0.75), 26);
    const playing = player.state == .playing or (player.state == .seeking and player.after_seek == .play);
    tr.play = glyphButton(@src(), if (playing) .pause else if (player.state == .ended) .replay else .play, ink, 32);
    tr.next = glyphButton(@src(), .next, ink.opacity(0.75), 26);

    const now = player.now();
    const total: f64 = @floatFromInt(tape.duration());
    {
        var buf: [48]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "{d}:{d:0>2} / {d}:{d:0>2}", .{
            minutes(now), seconds(now), minutes(total), seconds(total),
        }) catch "";
        dvui.labelNoFmt(@src(), label, .{}, .{
            .gravity_y = 0.5,
            .padding = .{ .x = 8, .w = 10 },
            .font = dvui.Font.theme(.mono),
            .color_text = .{ .color = ink.opacity(0.8) },
        });
    }

    // The scrubber fills what is left, with the chapter's name above the line.
    {
        var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .gravity_y = 0.5 });
        defer col.deinit();
        const chapter = if (tape.chapterAt(now)) |i| tape.chapters[i].title else tape.title;
        dvui.labelNoFmt(@src(), chapter, .{}, .{
            .font = dvui.Font.theme(.body).larger(-2),
            .color_text = .{ .color = ink.opacity(0.65) },
            .padding = .{},
            .margin = .{},
        });
        const track_wd = dvui.spacer(@src(), .{ .expand = .horizontal, .min_size_content = .{ .w = 40, .h = 12 } });
        const r = track_wd.rectScale().r;
        tr.track = r;
        paintTrack(r, tape, now, total, ink, track_wd.rectScale().s);
    }

    tr.close = glyphButton(@src(), .close, ink.opacity(0.6), 24);
    return shown.room();
}

/// The bar opening when `want` turns true and closing when it turns false, on a floating
/// surface's clocks, kept on `tr` from frame to frame. Wall time: it answers the viewer's
/// pointer, not the demo.
fn barReveal(tr: *Player.Transport, want: bool) Reveal {
    const now_ns = dvui.frameTimeNS();
    if (tr.since_ns == null or want != tr.wanted) {
        // Turned round part way: carry on from as open as it is — along each curve's straight
        // stretch, to the arrival — rather than from shut or from open.
        const was: f64 = if (tr.since_ns == null) 0 else tr.openness;
        const back_ms: f64 = motion.arrival * if (want) was * openMs() else (1 - was) * closeMs();
        tr.wanted = want;
        tr.since_ns = now_ns - @as(i128, @intFromFloat(back_ms * std.time.ns_per_ms));
    }
    const span = if (want) openMs() else closeMs();
    const ms = @as(f64, @floatFromInt(now_ns - tr.since_ns.?)) / std.time.ns_per_ms;
    const u: f32 = if (span <= 0) 1 else @floatCast(std.math.clamp(ms / span, 0, 1));
    const r = if (want) Reveal.opening(u) else Reveal.closing(u);
    tr.openness = r.form;
    // A paused player asks for no frames of its own.
    if (u < 1) dvui.refresh(null, @src(), null);
    return r;
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

/// A square for a glyph, painted with paths so the bar needs no icon set. Returns its rect.
fn glyphButton(src: std.builtin.SourceLocation, glyph: Glyph, color: dvui.Color, size: f32) dvui.Rect.Physical {
    const wd = dvui.spacer(src, .{ .min_size_content = .{ .w = size, .h = size }, .gravity_y = 0.5 });
    const rs = wd.rectScale();
    const r = rs.r;
    const s = rs.s;
    const cx = r.x + r.w / 2;
    const cy = r.y + r.h / 2;
    const u = @min(r.w, r.h) / 2; // half the square
    const c: dvui.Path.FillConvexOptions = .{ .color = .{ .color = color }, .fade = 1 };
    const lifo = dvui.currentWindow().lifo();
    switch (glyph) {
        .play, .replay => {
            var p: dvui.Path.Builder = .init(lifo);
            defer p.deinit();
            const k = u * 0.55;
            p.addPoint(.{ .x = cx - k * 0.7, .y = cy - k });
            p.addPoint(.{ .x = cx + k, .y = cy });
            p.addPoint(.{ .x = cx - k * 0.7, .y = cy + k });
            p.build().fillConvex(c);
            if (glyph == .replay) {
                var ring: dvui.Path.Builder = .init(lifo);
                defer ring.deinit();
                ring.addArc(.{ .x = cx, .y = cy }, u * 0.9, std.math.pi * 1.75, std.math.pi * 0.15, false);
                ring.build().stroke(.{ .thickness = 1.5 * s, .color = .{ .color = color } });
            }
        },
        .pause => {
            const bw = u * 0.28;
            const bh = u * 1.1;
            const left: dvui.Rect.Physical = .{ .x = cx - bw * 1.6, .y = cy - bh / 2, .w = bw, .h = bh };
            var right = left;
            right.x = cx + bw * 0.6;
            left.fill(.all(bw / 3), .{ .color = .{ .color = color } });
            right.fill(.all(bw / 3), .{ .color = .{ .color = color } });
        },
        .prev, .next => {
            const dir: f32 = if (glyph == .next) 1 else -1;
            const k = u * 0.45;
            var p: dvui.Path.Builder = .init(lifo);
            defer p.deinit();
            p.addPoint(.{ .x = cx - dir * k * 0.6, .y = cy - k });
            p.addPoint(.{ .x = cx + dir * k * 0.6, .y = cy });
            p.addPoint(.{ .x = cx - dir * k * 0.6, .y = cy + k });
            p.build().fillConvex(c);
            const stop: dvui.Rect.Physical = .{ .x = cx + dir * k * 0.6 - (if (dir < 0) 2 * s else 0), .y = cy - k, .w = 2 * s, .h = 2 * k };
            stop.fill(.all(s), .{ .color = .{ .color = color } });
        },
        .close => {
            const k = u * 0.38;
            inline for (.{ 1, -1 }) |d| {
                var p: dvui.Path.Builder = .init(lifo);
                defer p.deinit();
                p.addPoint(.{ .x = cx - k, .y = cy - d * k });
                p.addPoint(.{ .x = cx + k, .y = cy + d * k });
                p.build().stroke(.{ .thickness = 1.6 * s, .color = .{ .color = color }, .endcap_style = .square });
            }
        },
    }
    return r;
}

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
    const p = player.seq.pointer;
    const s = dvui.windowNaturalScale() * 1.1;

    // The ripple where the last click landed, spreading and fading.
    if (player.last_press) |press| {
        const age = player.seq.now - press.at;
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

    const pressed = player.held.count() > 0;
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
