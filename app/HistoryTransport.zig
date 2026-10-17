//! A document's transport: a bar of glass at the bottom of its pane, its history as a line with a
//! knob where the document is, and undo and redo either side (`plans/RECORDING_PLAN.md`, "Undo is
//! a seek"). Undo and redo show it (`stir`); it stays while the pointer is on it and goes a few
//! seconds after (`history_transport.Shown`). A press or a drag on the line goes to the step under
//! it, one `historyGoTo` a frame at most, so a drag across a thousand steps costs a jump a frame.
//!
//! Over any owner's history (`Plugin.historyLine`, `historyGoTo`); an owner without them has no
//! transport. Nothing runs for a bar that is not showing: no history is asked for, no timer is
//! set. One per document pane, kept by the app beside the pane.
const HistoryTransport = @This();

const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const sdk = @import("fizzy_sdk");
const icons = @import("icons");
const rules = @import("history_transport.zig");

shown: rules.Shown = .{},
repeat: rules.Repeat = .{},
/// The stop the pointer holds the knob at while it drags the line, until the drag ends. Only
/// while the bar holds the mouse: a drag whose capture went (the bar stopped drawing) is over.
drag: ?usize = null,

const bar_h: f32 = 40;
const button_d: f32 = 34;
const gap: f32 = 10;
const max_w: f32 = 460;

/// Undo or redo was pressed at `now_ns`, or something else asked for the bar: it shows.
pub fn stir(self: *HistoryTransport, now_ns: i128) void {
    self.shown.stir(now_ns);
    dvui.refresh(null, @src(), null);
}

/// A press of undo or redo (`forward`) at `now_ns` on this document: the bar shows, and the
/// press moves this many steps (`history_transport.Repeat`: more the longer the key is held).
pub fn press(self: *HistoryTransport, now_ns: i128, forward: bool) usize {
    self.stir(now_ns);
    return self.repeat.press(now_ns, forward);
}

/// Where the bar is over `area` (a document's pane, physical) while it shows, as far as the
/// pointer keeps it: what else drawn at the bottom of the pane (the activity feed) stays above.
/// Null when it is not showing at `now_ns`, or the pane is too narrow for it.
pub fn place(self: *const HistoryTransport, area: dvui.Rect.Physical, now_ns: i128) ?dvui.Rect.Physical {
    if (self.drag == null and self.shown.openness(now_ns) <= 0) return null;
    const whole = geometry(area.toNatural()) orelse return null;
    return dvui.windowRectScale().rectToPhysical(whole.outsetAll(4));
}

/// The bar's rect over a pane's natural rect, or null when the pane is too narrow for it.
fn geometry(nat: dvui.Rect.Natural) ?dvui.Rect {
    const w = @min(max_w, nat.w - 24);
    if (w < 3 * button_d) return null;
    const center: dvui.Point = .{ .x = nat.x + nat.w / 2, .y = nat.y + nat.h - 14 - bar_h / 2 };
    return .{ .x = center.x - w / 2, .y = center.y - bar_h / 2, .w = w, .h = bar_h };
}

/// The id `historyGoTo` takes for stop `i`: 0 before the first step, else the step's.
fn stopId(line: sdk.Plugin.HistoryLine, i: usize) u64 {
    return if (i == 0) 0 else line.entries[i - 1].id;
}

pub const DrawOptions = struct {
    /// A share button at the bar's end: the app has a way to share how the document was made
    /// (fizzy: its track as a tape). What a press does is the app's (`Pressed.share`).
    share: bool = false,
};

/// What was pressed on the bar this frame that is the app's to act on.
pub const Pressed = struct {
    share: bool = false,
};

/// Draw the bar over `area` (the document's pane, physical) when it shows, and take its input.
/// `id_extra` keeps one pane's bar apart from another's.
pub fn draw(self: *HistoryTransport, doc: sdk.DocHandle, area: dvui.Rect.Physical, id_extra: usize, opts: DrawOptions) Pressed {
    var pressed: Pressed = .{};
    const now = dvui.frameTimeNS();
    // The pointer on it, or a drag in it, keeps it.
    if (self.drag != null) self.shown.stir(now) else if (self.place(area, now)) |b| if (b.contains(dvui.currentWindow().mouse_pt)) self.shown.stir(now);
    const p = self.shown.openness(now);
    if (p <= 0) return pressed;
    const arena = dvui.currentWindow().arena();
    const line = doc.owner.historyLine(doc, arena) orelse return pressed;
    const n = line.entries.len;

    const wrs = dvui.windowRectScale();
    const s = wrs.s;
    const whole = geometry(area.toNatural()) orelse return pressed;
    const w = whole.w;
    const center = whole.center();
    // Share, when there is a way to: the last bubble, inside the bar's width.
    const end_w: f32 = if (opts.share) button_d + gap else 0;
    const back: dvui.Rect = .{ .x = whole.x, .y = center.y - button_d / 2, .w = button_d, .h = button_d };
    const fwd: dvui.Rect = .{ .x = whole.x + w - button_d - end_w, .y = back.y, .w = button_d, .h = button_d };
    const share: dvui.Rect = .{ .x = whole.x + w - button_d, .y = back.y, .w = if (opts.share) button_d else 0, .h = button_d };
    const track: dvui.Rect = .{ .x = back.x + button_d + gap, .y = whole.y, .w = w - 2 * (button_d + gap) - end_w, .h = bar_h };
    const hit = wrs.rectToPhysical(whole.outsetAll(4));

    var float: dvui.FloatingWidget = undefined;
    float.init(@src(), .{}, .{ .rect = whole.outsetAll(16), .id_extra = id_extra });
    defer float.deinit();
    const bounds = float.data().rect;
    const fid = float.data().id;
    // A drag lives as long as the bar holds the mouse: drawn again after it was not (a claim came
    // and went), it holds nothing, and the knob is the document's again.
    if (self.drag != null and !dvui.captured(fid)) self.drag = null;

    const phys = [4]dvui.Rect.Physical{ wrs.rectToPhysical(back), wrs.rectToPhysical(track), wrs.rectToPhysical(fwd), wrs.rectToPhysical(share) };
    const pad = 14;
    const x0 = phys[1].x + pad * s;
    const x1 = phys[1].x + phys[1].w - pad * s;
    // Where a press goes to a step: the line's band, under the title. A press on the title or
    // the capsule's ends is the bar's, and does nothing.
    const line_hit: dvui.Rect.Physical = .{ .x = x0 - 8 * s, .y = phys[1].y + phys[1].h * 0.45, .w = x1 - x0 + 16 * s, .h = phys[1].h * 0.55 };
    // Named for a tape or a test to aim at: the line from its first stop to its last, so a point
    // a fraction along it is that fraction of the history.
    const path = doc.owner.documentPath(doc);
    core.anchor.markRect(fid, phys[0], true, "history.back:{s}", .{path});
    core.anchor.markRect(fid, .{ .x = x0, .y = phys[1].y, .w = x1 - x0, .h = phys[1].h }, true, "history.line:{s}", .{path});
    core.anchor.markRect(fid, phys[2], true, "history.forward:{s}", .{path});
    if (opts.share) core.anchor.markRect(fid, phys[3], true, "history.share:{s}", .{path});

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
                    go = line.at -| 1;
                } else if (phys[2].contains(me.p)) {
                    go = @min(n, line.at + 1);
                } else if (opts.share and phys[3].contains(me.p)) {
                    pressed.share = true;
                } else if (line_hit.contains(me.p)) {
                    dvui.captureMouse(float.data(), e.num);
                    self.drag = rules.stopAt(me.p.x, x0, x1, n);
                }
            },
            .motion => if (self.drag != null and dvui.captured(fid)) {
                e.handle(@src(), float.data());
                self.drag = rules.stopAt(me.p.x, x0, x1, n);
            },
            .release => if (me.button.pointer() and dvui.captured(fid)) {
                e.handle(@src(), float.data());
                dvui.captureMouse(null, e.num);
                self.drag = null;
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

    const prev_alpha = dvui.alpha(p);
    defer dvui.alphaSet(prev_alpha);
    const pt = dvui.currentWindow().mouse_pt;
    var bubbles: [4]core.dialogs.Bubble = undefined;
    for (phys, &bubbles, 0..) |r, *b, i| b.* = .{
        .rect = r,
        .light = if (r.contains(pt) and switch (i) {
            0 => at > 0,
            2 => at < n,
            3 => true,
            else => false,
        }) core.dialogs.bubble_hover else 0,
    };
    core.dialogs.glassBubbles(fid, bubbles[0..if (opts.share) 4 else 3], s, .{ .merge = 14, .shadow = 1 });

    const ink = dvui.themeGet().color(.window, .text);
    button(bounds, back, "history_back", icons.tvg.lucide.undo, ink.opacity(if (at > 0) 0.85 else 0.3));
    button(bounds, fwd, "history_forward", icons.tvg.lucide.redo, ink.opacity(if (at < n) 0.85 else 0.3));
    if (opts.share) button(bounds, share, "history_share", icons.tvg.lucide.@"share-2", ink.opacity(0.85));

    // What the document is at, over the line: the step's title, and how far along.
    const font = dvui.Font.theme(.body).larger(-2);
    var buf: [96]u8 = undefined;
    const title = if (at == 0) "Before any change" else line.entries[at - 1].title;
    const label = std.fmt.bufPrint(&buf, "{s}   {d} / {d}", .{ title, at, n }) catch title;
    dvui.labelNoFmt(@src(), label, .{}, .{
        .rect = .{ .x = track.x + pad - bounds.x, .y = track.y + 4 - bounds.y, .w = track.w - 2 * pad, .h = font.lineHeight() },
        .padding = .{},
        .margin = .{},
        .font = font,
        .color_text = .{ .color = ink.opacity(0.85) },
    });
    paintLine(.{ .x = x0, .y = phys[1].y + phys[1].h - 16 * s, .w = @max(1, x1 - x0), .h = 10 * s }, at, n, ink, s);

    // Comes in, goes: a frame each while it fades, and one wake for when it next changes on its
    // own (it starts to go, it is gone).
    if (p < 1) dvui.refresh(null, @src(), fid);
    if (self.shown.nextChange(now)) |t| dvui.timer(fid, @intCast(@min(@divTrunc(t - now, 1000) + 1, std.math.maxInt(i32))));
    return pressed;
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
fn paintLine(r: dvui.Rect.Physical, at: usize, n: usize, ink: dvui.Color, s: f32) void {
    const h = 4 * s;
    const line: dvui.Rect.Physical = .{ .x = r.x, .y = r.y + (r.h - h) / 2, .w = r.w, .h = h };
    line.fill(.all(h / 2), .{ .color = .{ .color = ink.opacity(0.15) } });
    const accent = dvui.themeGet().color(.highlight, .fill);
    const knob_x = rules.stopX(at, r.x, r.x + r.w, n);
    var done = line;
    done.w = knob_x - line.x;
    if (done.w > 0) done.fill(.all(h / 2), .{ .color = .{ .color = accent } });
    // A tick per step while they stand 6 points apart; past that the line is its own scale.
    if (n > 0 and r.w / @as(f32, @floatFromInt(n)) >= 6 * s) for (1..n) |i| {
        const x = rules.stopX(i, r.x, r.x + r.w, n);
        const tick: dvui.Rect.Physical = .{ .x = x - 0.5 * s, .y = r.y + 1 * s, .w = 1 * s, .h = r.h - 2 * s };
        tick.fill(.{}, .{ .color = .{ .color = ink.opacity(0.25) } });
    };
    var knob: dvui.Path.Builder = .init(dvui.currentWindow().lifo());
    defer knob.deinit();
    knob.addArc(.{ .x = knob_x, .y = line.y + h / 2 }, 6 * s, std.math.tau, 0, true);
    knob.build().fillConvex(.{ .color = .{ .color = accent }, .fade = 1 });
}
