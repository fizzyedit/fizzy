//! What a viewer sees of a demo, over the app: the pointer the tape moves and a ripple where it
//! clicks, the keys it presses, its captions, and the bar to drive it with.
//!
//! Everything here is a function of the player's state and demo time — the caption showing is
//! whichever the tape has at `now`, the keystroke pill the last key op within a second of it —
//! so a seek shows exactly what live play showed at that moment, and there is nothing to rewind.
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

/// How long a key or command stays in the keystroke pill.
const keys_ms: f64 = 1400;
/// How long the bar stays after the real pointer last stirred, while playing, and how long of
/// that it spends fading.
const bar_linger_ns: i128 = 2500 * std.time.ns_per_ms;
const bar_fade_ns: f64 = 400 * std.time.ns_per_ms;

/// Draw the overlay for `player`. Call once a frame, after everything else in the frame has drawn.
pub fn draw(player: *Player) void {
    const tape = player.tape() orelse return;
    const win: dvui.Rect = .cast(dvui.windowRect());

    const bar_shown = drawTransport(player, tape, win);
    const keys_shown = drawKeys(player, win, bar_shown);
    drawCaption(player, tape, win, bar_shown, keys_shown);
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

/// A floating card's look: the app's content fill, rounded, lifted off the app by a soft shadow.
fn cardOptions(radius: f32) dvui.Options {
    return .{
        .background = true,
        .corners = dvui.CornerRect.all(radius),
        .color_fill = .{ .color = theme().color(.content, .fill).opacity(0.94) },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = theme().color(.content, .text).opacity(0.12) },
        .box_shadow = .{
            .color = .black,
            .offset = .{ .x = 0, .y = 3 },
            .fade = 12,
            .alpha = 0.28,
            .corners = dvui.CornerRect.all(radius),
        },
    };
}

/// 0 → 1 over `fade` ms after `start`, and back to 0 over the `fade` ms before `stop`.
fn fadeWindow(t: f64, start: f64, stop: f64, fade: f64) f32 {
    const in = std.math.clamp((t - start) / fade, 0, 1);
    const out = std.math.clamp((stop - t) / fade, 0, 1);
    return @floatCast(@min(in, out));
}

// ---- captions ------------------------------------------------------------------------------

fn drawCaption(player: *Player, tape: *const Tape, win: dvui.Rect, bar_shown: bool, keys_shown: bool) void {
    const now = player.now();
    const c = tape.captionAt(now) orelse return;
    const a = fadeWindow(now, @floatFromInt(c.at), @floatFromInt(c.at + c.ms), 220);
    const prev_alpha = dvui.alpha(a);
    defer dvui.alphaSet(prev_alpha);

    const w = @min(620, win.w - 32);
    const from: dvui.Point = switch (c.place) {
        .top => .{ .x = win.w / 2, .y = 28 },
        .middle => .{ .x = win.w / 2, .y = win.h / 2 },
        .bottom => .{ .x = win.w / 2, .y = win.h - 24 - @as(f32, if (bar_shown) 56 else 0) - @as(f32, if (keys_shown) 56 else 0) },
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
    var card = dvui.box(@src(), .{ .dir = .vertical }, cardOptions(14).override(.{
        .padding = .{ .x = 18, .y = 12, .w = 18, .h = 14 },
        .max_size_content = .{ .w = w - 36, .h = win.h },
    }));
    defer card.deinit();
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

/// The pill naming the key or command just pressed. Returns whether it drew.
fn drawKeys(player: *Player, win: dvui.Rect, bar_shown: bool) bool {
    if (player.state == .seeking) return false;
    const op = player.recentKeys(keys_ms) orelse return false;
    const platform: chord.Platform = if (core.platform.isMacOS()) .mac else .other;
    const stroke: ?chord.Stroke, const title: ?[]const u8 = switch (op.do) {
        .key => |k| .{ chord.parseKeys(k, platform) catch null, null },
        .command => |id| .{ player.stage.chordFor(id), player.stage.commandTitle(id) },
        else => unreachable,
    };
    if (stroke == null and title == null) return false;

    const at: f64 = @floatFromInt(op.at);
    const prev_alpha = dvui.alpha(fadeWindow(player.seq.now, at, at + keys_ms, 160));
    defer dvui.alphaSet(prev_alpha);

    const fw = layer(@src(), .{}, .{
        .from = dvui.windowRectScale().pointToPhysical(.{ .x = win.w / 2, .y = win.h - 24 - @as(f32, if (bar_shown) 56 else 0) }),
        .from_gravity_x = 0.5,
        .from_gravity_y = 0,
    });
    defer fw.deinit();
    var pill = dvui.box(@src(), .{ .dir = .horizontal }, cardOptions(1000).override(.{
        .padding = .{ .x = 14, .y = 7, .w = 14, .h = 7 },
    }));
    defer pill.deinit();
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
    return true;
}

// ---- the transport bar ---------------------------------------------------------------------

/// The bar: chapter back, play/pause, chapter forward, time, the scrubber, close. Returns whether
/// it drew. Records its parts' rects on `player.transport` for `Player.frame` to hit-test.
fn drawTransport(player: *Player, tape: *const Tape, win: dvui.Rect) bool {
    const tr = &player.transport;
    // Playing, the bar fades out of the demo's way unless someone reaches for it; it is still
    // laid out while hidden, so it comes back at its size rather than settling into it. (A playing
    // player asks for every frame, so the linger runs out without a timer of its own.)
    const since_stirred: i128 = if (tr.stirred_ns) |ns| dvui.frameTimeNS() - ns else std.math.maxInt(i64);
    const shown: f32 = if (player.state != .playing or tr.scrub != null) 1 else @floatCast(std.math.clamp(
        @as(f64, @floatFromInt(bar_linger_ns - since_stirred)) / @as(f64, bar_fade_ns),
        0,
        1,
    ));
    const prev_alpha = dvui.alpha(shown);
    defer dvui.alphaSet(prev_alpha);

    const w = @min(640, win.w - 24);
    const h: f32 = 44;
    const rect: dvui.Rect = .{ .x = (win.w - w) / 2, .y = win.h - h - 12, .w = w, .h = h };
    const fw = layer(@src(), .{ .rect = rect, .name = "DemoTransport" }, .{});
    defer fw.deinit();
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, cardOptions(1000).override(.{
        .expand = .both,
        .padding = .{ .x = 10, .y = 6, .w = 12, .h = 6 },
    }));
    defer bar.deinit();
    // Only a bar that can be seen takes clicks.
    tr.bar = if (shown > 0.05) bar.data().rectScale().r else null;

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
    return shown > 0;
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
    var pill = dvui.box(@src(), .{ .dir = .vertical }, cardOptions(12).override(.{
        .padding = .{ .x = 14, .y = 7, .w = 14, .h = 9 },
    }));
    defer pill.deinit();
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
    .{ 0, 0 },     .{ 0, 17 },     .{ 4.2, 13.2 }, .{ 7.2, 19.8 },
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
