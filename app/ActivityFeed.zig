//! The commands just run on one document (`Host.activity`), shown small at the bottom right of
//! its pane as they run: each fades in, stays a moment and fades out, the older ones rising as
//! newer ones come. Drawn on a layer that takes no input, so it never covers the work, and on wall
//! time, so whatever runs the commands (a person, an agent, a tape) shows the same. One that
//! offers an action ("Undid Claude's Draw" with its Redo) takes clicks on its button only, and
//! stays longer to be reached.
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
/// An item with an action stays this long.
const action_life_ns: i128 = 6000 * std.time.ns_per_ms;
const fade_ns: i128 = 250 * std.time.ns_per_ms;
const pad: f32 = 8;
const gap: f32 = 4;

const Item = struct {
    title: [48]u8,
    len: u8,
    born: i128,
    action: ?Action = null,

    fn life(self: Item) i128 {
        return if (self.action != null) action_life_ns else life_ns;
    }
};

/// A button on an item: its label, what it does, and the caller's own tag for it, which `draw`
/// answers when it is pressed.
const Action = struct {
    label: [16]u8,
    len: u8,
    act: Act,
    tag: u64,
};

/// What a button does, for whoever draws the feed to carry out (`draw`'s answer).
pub const Act = enum {
    /// Redo step `tag` ("Undid Claude's Draw").
    redo,
    /// Go back to before the last run of author `tag` ("Claude · Draw").
    go_back,
    /// The same, told that it also takes back some of the person's own steps.
    go_back_anyway,
    /// Go forward to step `tag` again, undoing a go back.
    forward,
};

/// A button pressed this frame.
pub const Pressed = struct { act: Act, tag: u64 };

/// A feed showing only what runs from now on.
pub fn init(host: *const sdk.Host) ActivityFeed {
    return .{ .seen = host.activity_seq };
}

/// Take what ran on `doc_id` since last time.
pub fn take(self: *ActivityFeed, host: *const sdk.Host, doc_id: u64, now: i128) void {
    for (host.activity.items) |a| {
        if (a.seq <= self.seen) continue;
        self.seen = a.seq;
        if (a.doc_id != doc_id) continue;
        // An agent's edit offers to go back to before its change.
        if (a.agent) |who| self.pushAction(a.title, "Go back", .go_back, who, now) else self.push(a.title, now);
    }
}

pub fn clear(self: *ActivityFeed) void {
    self.len = 0;
}

/// Show `title` as though a command of that name had just run: how the app says something
/// about the document itself (a share kept, a tape stopped) in the same glass as its commands.
pub fn push(self: *ActivityFeed, title: []const u8, now: i128) void {
    if (self.len == max) {
        std.mem.copyForwards(Item, self.items[0 .. max - 1], self.items[1..max]);
        self.len -= 1;
    }
    const n: u8 = @intCast(@min(title.len, 48));
    self.items[self.len] = .{ .title = undefined, .len = n, .born = now };
    @memcpy(self.items[self.len].title[0..n], title[0..n]);
    self.len += 1;
}

/// `push`, with a button labelled `label` on it: `draw` answers `act` and `tag` when it is pressed.
pub fn pushAction(self: *ActivityFeed, title: []const u8, label: []const u8, act: Act, tag: u64, now: i128) void {
    self.push(title, now);
    var action: Action = .{ .label = undefined, .len = @intCast(@min(label.len, 16)), .act = act, .tag = tag };
    @memcpy(action.label[0..action.len], label[0..action.len]);
    self.items[self.len - 1].action = action;
}

/// Draw the feed in the bottom right of `area` (physical), newest lowest. Answers the action
/// pressed this frame, if one was.
pub fn draw(self: *ActivityFeed, area: dvui.Rect.Physical, id_extra: usize, now: i128) ?Pressed {
    // Those whose time is up go.
    var kept: usize = 0;
    for (self.items[0..self.len]) |item| {
        if (now - item.born > item.life()) continue;
        self.items[kept] = item;
        kept += 1;
    }
    self.len = kept;
    if (self.len == 0) return null;
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
        const out = @min(1, @as(f32, @floatFromInt(item.life() - age)) / @as(f32, @floatFromInt(fade_ns)));
        const alpha = @max(0, @min(in, out));
        const action_w = if (item.action) |a| font.textSize(a.label[0..a.len]).w + pad * 2 else 0;
        const w = font.textSize(item.title[0..item.len]).w + pad * 2 + action_w;
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
    var pressed: ?Pressed = null;
    for (self.items[0..self.len], rects[0..self.len], alphas[0..self.len], 0..) |item, rect, alpha, n| {
        dvui.labelNoFmt(@src(), item.title[0..item.len], .{}, .{
            .rect = rect,
            .id_extra = n,
            .font = font,
            .padding = .{ .x = pad, .y = pad / 2, .w = pad, .h = pad / 2 },
            .margin = .{},
            .color_text = .{ .color = ink.opacity(0.85 * alpha) },
        });
        const a = item.action orelse continue;
        // The button alone takes input, on a layer of its own over the feed's.
        const bw = font.textSize(a.label[0..a.len]).w + pad * 2;
        var hit: dvui.FloatingWidget = undefined;
        hit.init(@src(), .{}, .{ .rect = .{ .x = r.x + rect.x + rect.w - bw, .y = r.y + rect.y, .w = bw, .h = rect.h }, .id_extra = id_extra *% 8 +% n });
        defer hit.deinit();
        if (dvui.button(@src(), a.label[0..a.len], .{}, .{
            .expand = .both,
            .font = font,
            .padding = .{ .x = pad, .y = pad / 2, .w = pad, .h = pad / 2 },
            .margin = .{},
            .background = false,
            .border = .{},
            .color_text = .{ .color = dvui.themeGet().color(.highlight, .fill).opacity(alpha) },
        })) pressed = .{ .act = a.act, .tag = a.tag };
    }
    return pressed;
}
