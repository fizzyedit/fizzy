//! A trim of a document's history, as macOS trims a recording: the bar at the bottom of its pane
//! holds the history as a line with a yellow bracket over the part kept, and the document shows
//! wherever a handle is dragged, so the person sees where the part they keep begins and ends rather
//! than choosing a time. Cancel and share either side, play to see the part kept.
//!
//! What a trim keeps, and how a press takes a handle, are `history_transport.Trim`'s rules. The
//! bar seeks the document itself while a handle or the playhead is dragged (one `historyGoTo` a
//! frame at most, as the transport does); what cancel, play and share do is the app's (`Pressed`).
//! Shown for as long as the app draws it: a trim is something the person is in the middle of.
const TrimBar = @This();

const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const sdk = @import("fizzy_sdk");
const icons = @import("icons");
const rules = @import("history_transport.zig");

/// What the pointer holds while it drags on the line, until the drag ends.
grip: ?rules.Trim.Grip = null,

const bar_h: f32 = 48;
const button_d: f32 = 34;
const gap: f32 = 10;
const max_w: f32 = 620;
/// macOS's trim yellow.
const yellow: dvui.Color = .{ .r = 0xF5, .g = 0xC0, .b = 0x2E };

/// What was pressed this frame, for the app to act on.
pub const Pressed = struct {
    cancel: bool = false,
    play: bool = false,
    share: bool = false,
    /// The playhead or a handle was taken: a playing preview stops.
    grabbed: bool = false,
};

/// The id `historyGoTo` takes for stop `i`: 0 before the first step, else the step's.
fn stopId(line: sdk.Plugin.HistoryLine, i: usize) u64 {
    return if (i == 0) 0 else line.entries[i - 1].id;
}

/// Draw the bar over `area` (the document's pane, physical) and take its input. `trim` is the
/// part kept, over `doc`'s history; `summary` says what it holds, over the line; `playing` turns
/// play into pause. `id_extra` keeps one pane's bar apart from another's.
pub fn draw(self: *TrimBar, doc: sdk.DocHandle, area: dvui.Rect.Physical, id_extra: usize, trim: *rules.Trim, summary: []const u8, playing: bool) Pressed {
    var pressed: Pressed = .{};
    const arena = dvui.currentWindow().arena();
    const line = doc.owner.historyLine(doc, arena) orelse return pressed;
    const n = line.entries.len;
    if (n != trim.n) return pressed;

    const wrs = dvui.windowRectScale();
    const s = wrs.s;
    const nat = area.toNatural();
    const w = @min(max_w, nat.w - 24);
    if (w < 6 * button_d) return pressed;
    const whole: dvui.Rect = .{ .x = nat.x + (nat.w - w) / 2, .y = nat.y + nat.h - 14 - bar_h, .w = w, .h = bar_h };
    const cy = whole.y + bar_h / 2;
    const cancel: dvui.Rect = .{ .x = whole.x, .y = cy - button_d / 2, .w = button_d, .h = button_d };
    const play: dvui.Rect = .{ .x = cancel.x + button_d + gap, .y = cancel.y, .w = button_d, .h = button_d };
    const share: dvui.Rect = .{ .x = whole.x + w - button_d, .y = cancel.y, .w = button_d, .h = button_d };
    const track: dvui.Rect = .{ .x = play.x + button_d + gap, .y = whole.y, .w = share.x - gap - (play.x + button_d + gap), .h = bar_h };

    var float: dvui.FloatingWidget = undefined;
    float.init(@src(), .{}, .{ .rect = whole.outsetAll(16), .id_extra = id_extra });
    defer float.deinit();
    const bounds = float.data().rect;
    const fid = float.data().id;
    if (self.grip != null and !dvui.captured(fid)) self.grip = null;

    const phys = [4]dvui.Rect.Physical{ wrs.rectToPhysical(cancel), wrs.rectToPhysical(play), wrs.rectToPhysical(track), wrs.rectToPhysical(share) };
    const pad = 16;
    const x0 = phys[2].x + pad * s;
    const x1 = phys[2].x + phys[2].w - pad * s;
    const line_r: dvui.Rect.Physical = .{ .x = x0, .y = phys[2].y + phys[2].h - 24 * s, .w = @max(1, x1 - x0), .h = 16 * s };
    const line_hit = line_r.outsetAll(8 * s);
    const path = doc.owner.documentPath(doc);
    core.anchor.markRect(fid, phys[0], true, "trim.cancel:{s}", .{path});
    core.anchor.markRect(fid, phys[1], true, "trim.play:{s}", .{path});
    core.anchor.markRect(fid, .{ .x = x0, .y = line_r.y, .w = x1 - x0, .h = line_r.h }, true, "trim.line:{s}", .{path});
    core.anchor.markRect(fid, phys[3], true, "trim.share:{s}", .{path});

    var go: ?usize = null;
    const hit = wrs.rectToPhysical(whole.outsetAll(4));
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
                    pressed.cancel = true;
                } else if (phys[1].contains(me.p)) {
                    pressed.play = true;
                } else if (phys[3].contains(me.p)) {
                    pressed.share = true;
                } else if (line_hit.contains(me.p)) {
                    dvui.captureMouse(float.data(), e.num);
                    const grip = trim.grab(me.p.x, x0, x1, 10 * s);
                    self.grip = grip;
                    go = trim.drag(grip, rules.stopAt(me.p.x, x0, x1, n));
                    pressed.grabbed = true;
                }
            },
            .motion => if (self.grip) |grip| if (dvui.captured(fid)) {
                e.handle(@src(), float.data());
                go = trim.drag(grip, rules.stopAt(me.p.x, x0, x1, n));
            },
            .release => if (me.button.pointer() and dvui.captured(fid)) {
                e.handle(@src(), float.data());
                dvui.captureMouse(null, e.num);
                self.grip = null;
            },
            else => {},
        }
    }
    var at = line.at;
    if (go) |to| if (to != at) {
        if (doc.owner.historyGoTo(doc, stopId(line, to))) at = to;
        dvui.refresh(null, @src(), fid);
    };

    const pt = dvui.currentWindow().mouse_pt;
    var bubbles: [4]core.dialogs.Bubble = undefined;
    for (phys, &bubbles, 0..) |r, *b, i| b.* = .{ .rect = r, .light = if (i != 2 and r.contains(pt)) core.dialogs.bubble_hover else 0 };
    core.dialogs.glassBubbles(fid, &bubbles, s, .{ .merge = 14, .shadow = 1 });

    const ink = dvui.themeGet().color(.window, .text);
    button(bounds, cancel, "trim_cancel", icons.tvg.lucide.x, ink.opacity(0.85));
    button(bounds, play, "trim_play", if (playing) icons.tvg.lucide.pause else icons.tvg.lucide.play, ink.opacity(0.85));
    button(bounds, share, "trim_share", icons.tvg.lucide.check, yellow);

    const font = dvui.Font.theme(.body).larger(-2);
    dvui.labelNoFmt(@src(), summary, .{}, .{
        .rect = .{ .x = track.x + pad - bounds.x, .y = track.y + 5 - bounds.y, .w = track.w - 2 * pad, .h = font.lineHeight() },
        .padding = .{},
        .margin = .{},
        .font = font,
        .color_text = .{ .color = ink.opacity(0.85) },
    });
    paintLine(line_r, trim.*, at, ink, s);
    return pressed;
}

/// A button's icon, in the middle of its bubble `r` (window-natural; `bounds` the layer's).
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

/// The line `r` (physical): the whole history faint, the part kept brighter inside the yellow
/// bracket, its two handles, and the playhead at `at`.
fn paintLine(r: dvui.Rect.Physical, trim: rules.Trim, at: usize, ink: dvui.Color, s: f32) void {
    const h = 6 * s;
    const mid = r.y + r.h / 2;
    const whole: dvui.Rect.Physical = .{ .x = r.x, .y = mid - h / 2, .w = r.w, .h = h };
    whole.fill(.all(h / 2), .{ .color = .{ .color = ink.opacity(0.12) } });

    const xf = rules.stopX(trim.from, r.x, r.x + r.w, trim.n);
    const xt = rules.stopX(trim.to, r.x, r.x + r.w, trim.n);
    const kept: dvui.Rect.Physical = .{ .x = xf, .y = whole.y, .w = @max(1, xt - xf), .h = h };
    kept.fill(.all(h / 2), .{ .color = .{ .color = ink.opacity(0.4) } });

    // The bracket: yellow over and under the part kept, a handle at each end.
    const handle_w = 7 * s;
    const bracket: dvui.Rect.Physical = .{ .x = xf - handle_w, .y = r.y, .w = xt - xf + 2 * handle_w, .h = r.h };
    const edge = 2 * s;
    (dvui.Rect.Physical{ .x = xf, .y = bracket.y, .w = xt - xf, .h = edge }).fill(.{}, .{ .color = .{ .color = yellow } });
    (dvui.Rect.Physical{ .x = xf, .y = bracket.y + bracket.h - edge, .w = xt - xf, .h = edge }).fill(.{}, .{ .color = .{ .color = yellow } });
    for ([_]f32{ xf - handle_w, xt }) |x| {
        const hr: dvui.Rect.Physical = .{ .x = x, .y = bracket.y, .w = handle_w, .h = bracket.h };
        hr.fill(.all(3 * s), .{ .color = .{ .color = yellow } });
        const notch: dvui.Rect.Physical = .{ .x = x + handle_w / 2 - 0.75 * s, .y = mid - 4 * s, .w = 1.5 * s, .h = 8 * s };
        notch.fill(.all(0.75 * s), .{ .color = .{ .color = .black } });
    }

    // The playhead: where the document is.
    const xa = rules.stopX(at, r.x, r.x + r.w, trim.n);
    const head: dvui.Rect.Physical = .{ .x = xa - 1 * s, .y = r.y - 3 * s, .w = 2 * s, .h = r.h + 6 * s };
    head.fill(.all(1 * s), .{ .color = .{ .color = .white } });
}
