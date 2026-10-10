//! A plain overlay: the pointer a tape moves, and a ripple where it clicks — so a person sees
//! what is being pointed at, real pointer motion being held off while a tape plays. Any dvui app
//! can draw it as is; fizzy's glass overlay (captions, keys, the transport bar) draws its pointer
//! with this too.
//!
//! Call once a frame, after everything else in the frame has drawn: `drawLive` for a live tape
//! (`LiveDriver`), `drawPlayer` for a demo (`Player`).
const std = @import("std");
const dvui = @import("dvui");
const Sequencer = @import("tape").Sequencer;
const LiveDriver = @import("LiveDriver.zig");
const Player = @import("Player.zig");

pub const Options = struct {
    /// How long the pointer takes to step aside when a tape starts typing, and to come back when
    /// it moves. An app scales it for reduced motion (fizzy: `core.motion.durationMs`); 0 snaps.
    fade_ms: f32 = 140,
};

/// A live tape's pointer, timed in wall time: its own clock jumps from op to op
/// (`LiveDriver.Hand`).
pub fn drawLive(driver: *const LiveDriver, opts: Options) void {
    if (!driver.playing()) return;
    const fw = layer(@src(), .{ .rect = pointerRect(driver.seq.pointer), .name = "LivePointer" }, .{});
    defer fw.deinit();

    const now = dvui.frameTimeNS();
    const hand = driver.hand;
    const ripple: ?Ripple = if (hand.press) |press| .{
        .pt = press.pt,
        .age_ms = @floatFromInt(@divTrunc(now - press.ns, std.time.ns_per_ms)),
    } else null;
    const since_ms: f32 = @floatFromInt(@divTrunc(now - hand.since_ns, std.time.ns_per_ms));
    const in: f32 = if (opts.fade_ms <= 0) 1 else std.math.clamp(since_ms / opts.fade_ms, 0, 1);
    paintPointer(driver.seq.pointer, ripple, if (hand.typing) 1 - in else in, driver.input.held.count() > 0);
}

/// A demo's pointer, while it drives, timed in demo time: a seek shows what playing showed.
pub fn drawPlayer(player: *Player, opts: Options) void {
    if (!player.driving()) return;
    const fw = layer(@src(), .{ .rect = pointerRect(player.seq.pointer), .name = "DemoPointer" }, .{});
    defer fw.deinit();
    const ripple: ?Ripple = if (player.last_press) |press| .{ .pt = press.pt, .age_ms = player.seq.now - press.at } else null;
    // Out of the way of the words while the tape types, as a desktop's pointer is.
    const shown = player.pointerShown(opts.fade_ms);
    paintPointer(player.seq.pointer, ripple, shown, player.input.held.count() > 0);
}

/// The pointer's layer: round its tip, natural, so its middle is where the pointer is. An app that
/// shows parts of its frame in OS windows of their own (fizzy's floats, menus and dialogs) gives
/// each window the layers whose middle is in it, and the pointer is then drawn on whatever window
/// it is over. What it draws is clipped to the screen it is on (`dvui.screenFor`), not to this.
fn pointerRect(p: Sequencer.Point) dvui.Rect {
    const s = dvui.windowNaturalScale();
    return .{ .x = p.x / s - 16, .y = p.y / s - 16, .w = 32, .h = 32 };
}

/// A floating widget that takes no input, raised to the top. A floating widget otherwise stays
/// just above the window it was made in, under anything opened after it; re-added as a subwindow
/// of its own it can be raised, and each call puts the new one above the last.
pub fn layer(src: std.builtin.SourceLocation, opts: dvui.Options, init: dvui.FloatingWidget.InitOptions) *dvui.FloatingWidget {
    var init_opts = init;
    init_opts.mouse_events = false;
    const fw = dvui.widgetAlloc(dvui.FloatingWidget);
    fw.init(src, init_opts, opts);
    const wd = fw.data();
    dvui.subwindowAdd(wd.id, wd.rect, wd.rectScale().r, false, null, false);
    dvui.raiseSubwindow(wd.id);
    return fw;
}

/// Where the last click landed, and how long ago.
pub const Ripple = struct { pt: Sequencer.Point, age_ms: f64 };

/// The classic arrow, tip at the origin, in natural pixels.
const arrow = [_][2]f32{
    .{ 0, 0 },     .{ 0, 17 },     .{ 4.2, 13.2 },  .{ 7.2, 19.8 },
    .{ 10, 18.6 }, .{ 7.1, 12.2 }, .{ 12.6, 12.2 },
};

/// The pointer at `p`, `shown` of it, pressed in while a button is held; the ripple spreading
/// and fading from the last click.
pub fn paintPointer(p: Sequencer.Point, ripple: ?Ripple, shown: f32, pressed: bool) void {
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
                .color = .{ .color = dvui.themeGet().color(.highlight, .fill).opacity(0.85 * (1 - f)) },
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
