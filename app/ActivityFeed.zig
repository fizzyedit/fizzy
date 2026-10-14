//! The commands just run on one document (`Host.activity`), shown small at the bottom right of
//! its pane as they run: each fades in, stays a moment and fades out, the older ones rising as
//! newer ones come. Drawn on a layer that takes no input, so it never covers the work, and on wall
//! time, so whatever runs the commands (a person, an agent, a tape) shows the same.
const ActivityFeed = @This();

const std = @import("std");
const dvui = @import("dvui");
const sdk = @import("fizzy_sdk");
const core = @import("core");

items: [max]Item = undefined,
len: usize = 0,
/// The last `Host.Activity.seq` taken.
seen: u64 = 0,

const max = 5;
const life_ns: i128 = 2400 * std.time.ns_per_ms;
const fade_ns: i128 = 250 * std.time.ns_per_ms;
const pad: f32 = 8;
const gap: f32 = 4;

const Item = struct {
    title: [48]u8,
    len: u8,
    born: i128,
};

/// A feed showing only what runs from now on.
pub fn init(host: *const sdk.Host) ActivityFeed {
    return .{ .seen = host.activity_seq };
}

/// Take what ran on `doc_id` since last time.
pub fn take(self: *ActivityFeed, host: *const sdk.Host, doc_id: u64, now: i128) void {
    for (host.activity.items) |a| {
        if (a.seq <= self.seen) continue;
        self.seen = a.seq;
        if (a.doc_id == doc_id) self.push(a.title, now);
    }
}

pub fn clear(self: *ActivityFeed) void {
    self.len = 0;
}

fn push(self: *ActivityFeed, title: []const u8, now: i128) void {
    if (self.len == max) {
        std.mem.copyForwards(Item, self.items[0 .. max - 1], self.items[1..max]);
        self.len -= 1;
    }
    const n: u8 = @intCast(@min(title.len, 48));
    self.items[self.len] = .{ .title = undefined, .len = n, .born = now };
    @memcpy(self.items[self.len].title[0..n], title[0..n]);
    self.len += 1;
}

/// Draw the feed in the bottom right of `area` (physical), newest lowest.
pub fn draw(self: *ActivityFeed, area: dvui.Rect.Physical, id_extra: usize, now: i128) void {
    // The oldest go first.
    while (self.len > 0 and now - self.items[0].born > life_ns) {
        std.mem.copyForwards(Item, self.items[0 .. self.len - 1], self.items[1..self.len]);
        self.len -= 1;
    }
    if (self.len == 0) return;
    dvui.refresh(null, @src(), null);

    const r = area.toNatural();
    var layer: dvui.FloatingWidget = undefined;
    layer.init(@src(), .{ .mouse_events = false }, .{ .rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h }, .id_extra = id_extra });
    defer layer.deinit();

    const ink = dvui.themeGet().color(.window, .text);
    const font = dvui.Font.theme(.body).larger(-2);
    const h = font.lineHeight() + pad;
    const rs = layer.data().contentRectScale();
    // Where each goes and how far it has come in or gone out, newest lowest; then the glass under
    // all of them at once, then their titles.
    var rects: [max]dvui.Rect = undefined;
    var alphas: [max]f32 = undefined;
    var bubbles: [max]core.dialogs.Bubble = undefined;
    var bottom = r.h - 12;
    var i = self.len;
    while (i > 0) {
        i -= 1;
        const item = self.items[i];
        const age = now - item.born;
        // In, then out, over `fade_ns` each; rising into place as it comes in.
        const in = @min(1, @as(f32, @floatFromInt(age)) / @as(f32, @floatFromInt(fade_ns)));
        const out = @min(1, @as(f32, @floatFromInt(life_ns - age)) / @as(f32, @floatFromInt(fade_ns)));
        const alpha = @max(0, @min(in, out));
        const w = font.textSize(item.title[0..item.len]).w + pad * 2;
        const rect: dvui.Rect = .{ .x = r.w - 12 - w, .y = bottom - h + (1 - in) * h * 0.5, .w = w, .h = h };
        // Glass has no fade: it grows in from, and shrinks out to, a little smaller.
        const k = 0.6 + 0.4 * alpha;
        const glass: dvui.Rect = .{ .x = rect.x + rect.w * (1 - k) / 2, .y = rect.y + rect.h * (1 - k) / 2, .w = rect.w * k, .h = rect.h * k };
        rects[i] = rect;
        alphas[i] = alpha;
        bubbles[i] = .{ .rect = rs.rectToPhysical(glass) };
        bottom -= (h + gap) * in;
    }
    core.dialogs.glassBubbles(layer.data().id, bubbles[0..self.len], rs.s, .{});
    for (self.items[0..self.len], rects[0..self.len], alphas[0..self.len], 0..) |item, rect, alpha, n| {
        dvui.labelNoFmt(@src(), item.title[0..item.len], .{}, .{
            .rect = rect,
            .id_extra = n,
            .font = font,
            .padding = .{ .x = pad, .y = pad / 2, .w = pad, .h = pad / 2 },
            .margin = .{},
            .color_text = .{ .color = ink.opacity(0.85 * alpha) },
        });
    }
}
