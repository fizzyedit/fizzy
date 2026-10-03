//! The views floating over the window: places the framework owns rather than a shape, each a
//! glass window holding an ordinary region (`Float N`). A view dropped on the middle of the place
//! it was lifted from floats here (`ViewDrag.floatOut`); dragged out again by its corner button,
//! or closed from its header, it goes back.
//!
//! A float is a place like any other: its name keys its assignment, its splits (`Float 1/r1`)
//! live in the split forest, and the saved layout keeps it. What only a float has — where its
//! window is, where it came from, how it is landing or closing — is kept here, in z order. The
//! rules it follows are values in `float_rules.zig`.
const std = @import("std");
const dvui = @import("dvui");
const rules = @import("float_rules.zig");
const core = @import("core");
const Layout = @import("Layout.zig");
const ViewDrag = @import("ViewDrag.zig");
const dialogs = core.dialogs;

const Floats = @This();

/// A float growing out of the glass a view was carried in, the frame it is let go onward.
pub const Landing = struct {
    /// The carried glass when it was let go, physical pixels.
    from: dvui.Rect.Physical,
    /// Its corner radius then, physical.
    radius: f32,
    start_ns: i128,
    /// The carried view's photograph, fading out as the view itself fades in over it. Owned:
    /// taken from the drag, destroyed when the landing ends or the float goes.
    photo: ?dvui.Texture = null,
    /// The size it was taken at, physical, for its proportions.
    photo_size: dvui.Size.Physical = .{},
};

pub const Float = struct {
    /// Its place's name, `Float {n}`. Interned (`State.internName`): it outlives the frame.
    name: []const u8,
    /// Where its window is, in natural units relative to the main window.
    rect: dvui.Rect,
    /// The place the view floated out of, where closing the float sends it (interned).
    home: []const u8,
    /// The window's id extra: unique for as long as the app runs, so a closed float's window
    /// state (dvui forgets it a frame later) is never read by the next float of the same name.
    serial: u64 = 0,
    /// The frame it was made on. That frame it registers its place and draws nothing (`draw`).
    born_ns: i128 = 0,
    landing: ?Landing = null,
    /// Flying shut: drawn as glass only, and dropped when the flight ends.
    closing: bool = false,
    /// Its window's id, once it has drawn: what dvui's subwindow stack knows it by.
    win_id: dvui.Id = .zero,
    /// Its window last frame, physical — what a drag reads occlusion against.
    bounds: dvui.Rect.Physical = .{},
    /// Its header last frame, physical — the handle that moves it. Nothing is aimed at over it.
    header: dvui.Rect.Physical = .{},
};

/// Bottom to top: the last is the float in front.
items: std.ArrayListUnmanaged(Float) = .empty,
/// The last serial handed out (`Float.serial`).
serial: u64 = 0,

/// The index of the float named `name`, if there is one.
pub fn find(self: *const Floats, name: []const u8) ?usize {
    for (self.items.items, 0..) |f, i| {
        if (std.mem.eql(u8, f.name, name)) return i;
    }
    return null;
}

/// The float whose place `name` is or lies in (`Float 1/r1` is in `Float 1`).
pub fn rootOf(self: *const Floats, name: []const u8) ?[]const u8 {
    for (self.items.items) |f| {
        if (rules.isUnder(name, f.name)) return f.name;
    }
    return null;
}

/// The names in use, for `float_rules.nextName`. Allocated in `arena`.
pub fn names(self: *const Floats, arena: std.mem.Allocator) []const []const u8 {
    const out = arena.alloc([]const u8, self.items.items.len) catch return &.{};
    for (self.items.items, 0..) |f, i| out[i] = f.name;
    return out;
}

/// Add `f` on top of the others, with the next serial.
pub fn add(self: *Floats, gpa: std.mem.Allocator, f: Float) !*Float {
    self.serial += 1;
    var new = f;
    new.serial = self.serial;
    try self.items.append(gpa, new);
    return &self.items.items[self.items.items.len - 1];
}

/// Drop the float at `i`, and the photograph its landing still held.
pub fn removeAt(self: *Floats, i: usize) void {
    var f = self.items.orderedRemove(i);
    endLanding(&f);
}

/// The landing is over: the view is drawn, and the photograph it grew out of is not needed.
pub fn endLanding(f: *Float) void {
    const l = f.landing orelse return;
    if (l.photo) |tex| {
        // Destroyed with the frame — and only in one. With no window (teardown) the GPU is going
        // with the process.
        if (dvui.current_window != null) dvui.Texture.destroyLater(tex);
    }
    f.landing = null;
}

/// Every float gone — Reset Layout.
pub fn clear(self: *Floats) void {
    for (self.items.items) |*f| endLanding(f);
    self.items.clearRetainingCapacity();
}

pub fn deinit(self: *Floats, gpa: std.mem.Allocator) void {
    self.clear();
    self.items.deinit(gpa);
    self.items = .empty;
}

/// `items` reordered to `order` (`float_rules.stackOrder`): `order[i]` is the index of the float
/// that goes `i`th from the bottom.
pub fn reorder(self: *Floats, order: []const usize) void {
    var buf: [max]Float = undefined;
    const n = @min(order.len, max, self.items.items.len);
    for (order[0..n], 0..) |from, i| buf[i] = self.items.items[from];
    @memcpy(self.items.items[0..n], buf[0..n]);
}

/// More floats than this and the newest stop stacking with the rest; a layout holding this many
/// windows over itself has bigger problems.
pub const max = 32;

/// A rect as `float_rules` takes it.
pub fn toRules(r: anytype) rules.Rect {
    return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
}

pub fn fromRules(r: rules.Rect) dvui.Rect {
    return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
}

// ── Closing ─────────────────────────────────────────────────────────────────────────────────────

pub const Closing = enum {
    /// Its last view left it: there is nothing to send anywhere.
    emptied,
    /// The user closed it: every view in it goes back to the place it floated out of.
    home,
};

/// Close float `name`: its views go home (`how`), every place a split of it made goes with it,
/// and its window flies shut into its middle as a dialog's does (`core.dialogs.dialogWindow`),
/// drawn as glass alone until it lands (`draw`).
pub fn close(l: *Layout, name: []const u8, how: Closing) void {
    const state = l.state;
    const i = state.floats.find(name) orelse return;
    if (state.floats.items.items[i].closing) return;
    const home = state.floats.items.items[i].home;
    const leaves = state.splits.leavesUnder(l.arena, name);
    if (how == .home) ViewDrag.sendHome(l, leaves, home);
    for (leaves) |leaf| {
        if (state.forgetPlace(l.gpa, leaf)) l.extents_changed = true;
    }
    state.splits.forget(l.gpa, name);
    const f = &state.floats.items.items[i];
    endLanding(f);
    // Marked, not removed: `draw` may be walking the list, and drops it when it comes to it —
    // at once if it never drew a window, after the flight shut if it did.
    f.closing = true;
    if (f.win_id != .zero and f.bounds.w > 0) {
        var to = f.bounds;
        to.x = to.center().x;
        to.y = to.center().y;
        to.w = 1;
        to.h = 1;
        dvui.dataSet(null, f.win_id, "_close_rect", to);
    }
    state.markDirty();
    dvui.refresh(null, @src(), null);
}

// ── Drawing ─────────────────────────────────────────────────────────────────────────────────────

/// How long a float takes to grow out of the carried glass into its window, as written — the
/// card's own change of shape (`ViewDrag.morphProgress`) and a dialog's open.
const landing_ms: f32 = 300;
/// How opaque the landing photograph is at its start — the carried card's own (`ViewDrag`).
const photo_opacity: f32 = 0.8;

/// Draw every float, bottom to top: each a glass window holding its place. Called by the
/// application after its shape has run and before it publishes the shape's regions, from the
/// base window (`Layout.drawFloats`), so a float's places register this frame like any other's
/// — each stamped with its float's layer, the `n`th from the bottom being `n`.
pub fn draw(l: *Layout) void {
    const floats = &l.state.floats;
    if (floats.items.items.len == 0) return;
    syncStack(l);
    defer l.state.layer_building = 0;
    // By index, re-read after each draw: a view floated out of one adds a float at the end (and
    // may move the list), and one done flying shut goes from where it is.
    var i: usize = 0;
    while (i < floats.items.items.len) {
        l.state.layer_building = @intCast(i + 1);
        if (drawOne(l, i)) i += 1 else floats.removeAt(i);
    }
}

/// The floats in the order dvui stacks their windows: a press raises one there
/// (`float_rules.stackOrder`).
fn syncStack(l: *Layout) void {
    const floats = &l.state.floats;
    const n = @min(floats.items.items.len, max);
    var ids: [max]u64 = undefined;
    for (floats.items.items[0..n], 0..) |f, i| ids[i] = @intFromEnum(f.win_id);
    const stack = dvui.currentWindow().subwindows.stack.items;
    const stack_ids = l.arena.alloc(u64, stack.len) catch return;
    for (stack, 0..) |sw, i| stack_ids[i] = @intFromEnum(sw.id);
    var order: [max]usize = undefined;
    rules.stackOrder(order[0..n], ids[0..n], stack_ids);
    floats.reorder(order[0..n]);
}

/// Draw the float at `i`. False when it is gone: flown shut, or closed before it ever drew.
fn drawOne(l: *Layout, i: usize) bool {
    const state = l.state;
    const cw = dvui.currentWindow();
    const now = cw.frame_time_ns;
    const scale = cw.natural_scale;
    const first = state.floats.items.items[i];
    if (first.closing and first.win_id == .zero) return false;
    // Made this frame — by a release inside the place it left, which has drawn that view already
    // this frame. Its place goes in the registry, so from the next frame it claims the view away
    // from where it was; the window, and the view in it, start then. Drawn now, the view would be
    // drawn twice in one frame.
    if (first.born_ns == now and !first.closing) {
        state.registerRegion(l.gpa, .{
            .name = first.name,
            .keywords = Layout.slot_keywords,
            .shows = .many,
            .by_name = true,
        });
        return true;
    }

    // Where the window is this frame: on its way out of the carried glass, or where it was left.
    var rect = first.rect;
    var corner_r = core.corners.scaled(core.corners.surface);
    var landed: f32 = 1;
    if (first.landing) |land| {
        const frac = landingFraction(land.start_ns, now);
        landed = if (frac >= 1) 1 else core.motion.enter(frac);
        const from = land.from.toNatural();
        rect = fromRules(rules.lerp(toRules(from), toRules(first.rect), landed));
        corner_r = std.math.lerp(land.radius / scale, corner_r, std.math.clamp(landed, 0, 1));
        if (frac >= 1) endLanding(&state.floats.items.items[i]) else dvui.refresh(null, @src(), null);
    }
    const landing = state.floats.items.items[i].landing != null;

    var frost = dialogs.dialogFrost();
    // The carried drop was glass already: the window takes over from it, whole, rather than
    // forming a second time.
    if (frost) |*fr| fr.form = 1;
    var win_rect = rect;
    var win = core.widgets.floatingWindow(@src(), .{
        .rect = &win_rect,
        .placed = true,
        .resize = if (landing or first.closing) .none else .all,
        .window_avoid = .none,
        .frost = frost,
    }, .{
        .id_extra = @intCast(first.serial),
        .corners = if (landing) dvui.CornerRect.all(corner_r) else dialogs.surfaceCorners(),
        .box_shadow = dialogs.surfaceShadow(),
        .color_fill = .{ .color = dialogs.dialogFill() },
        .border = .all(0),
    });
    const win_id = win.data().id;
    const bounds = win.data().rectScale().r;

    // Flying shut: the glass alone, gone when it lands.
    if (first.closing) {
        const flown = if (dvui.animationGet(win_id, "_close_x")) |a| a.done() else true;
        win.deinit();
        return !flown;
    }

    // A press anywhere in it brings it to the front, as a press on an OS window does; dvui
    // raises a window only from its header.
    for (dvui.events()) |*e| {
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        if (me.action != .press or !me.button.pointer()) continue;
        if (dvui.eventMatch(e, .{ .id = win_id, .r = bounds })) dvui.raiseSubwindow(win_id);
    }

    var open = true;
    const title = if (ViewDrag.visibleId(l, first.name)) |id| (if (l.host.surfaceById(id)) |s| s.title else first.name) else first.name;
    const header = dialogs.windowHeader(title, "", &open, .none);
    // Moved by its header only: the rest is the view's. Not while it lands — it is going where
    // the drop put it.
    win.dragAreaSet(if (landing) .{} else header);

    {
        // The view fades in over the photograph it grew out of, which fades out above it.
        const prev_alpha = dvui.alpha(std.math.clamp(landed, 0, 1));
        defer dvui.alphaSet(prev_alpha);
        var region = l.region(@src(), .{
            .name = first.name,
            .keywords = Layout.slot_keywords,
            .by_name = true,
            .shows = .many,
        }, .{ .expand = .both }) catch null;
        if (region) |*r| r.deinit();
    }
    if (state.floats.items.items[i].landing) |land| {
        if (land.photo) |tex| drawPhoto(tex, land.photo_size, bounds, header, corner_r * scale, 1 - std.math.clamp(landed, 0, 1));
    }
    win.deinit();

    // Contents may have added a float, moving the list: read this one again.
    const f = &state.floats.items.items[i];
    f.win_id = win_id;
    f.bounds = bounds;
    f.header = header;
    if (!open) {
        close(l, f.name, .home);
        return true;
    }
    // Moved or resized: remember where, no smaller than a float may be.
    if (!landing and !f.closing and !win_rect.equals(f.rect)) {
        f.rect = fromRules(rules.resized(toRules(win_rect)));
        state.markDirty();
    }
    return true;
}

/// How far through its landing a float is, 0…1 on the clock; 1 at once when motion is off.
fn landingFraction(start_ns: i128, now: i128) f32 {
    const dur: f64 = core.motion.durationMs(landing_ms) * @as(f64, std.time.ns_per_ms);
    if (dur <= 0) return 1;
    const elapsed: f64 = @floatFromInt(now - start_ns);
    return @floatCast(std.math.clamp(elapsed / dur, 0, 1));
}

/// The photograph the float grew out of, over its body (below `header`), cropped to fill it, at
/// `fade` of its carried opacity.
fn drawPhoto(tex: dvui.Texture, size: dvui.Size.Physical, bounds: dvui.Rect.Physical, header: dvui.Rect.Physical, radius: f32, fade: f32) void {
    if (fade <= 0.01) return;
    const top = header.y + header.h;
    const r: dvui.Rect.Physical = .{ .x = bounds.x, .y = top, .w = bounds.w, .h = bounds.y + bounds.h - top };
    if (r.w < 2 or r.h < 2) return;
    var uv: dvui.Rect = .{ .x = 0, .y = 0, .w = 1, .h = 1 };
    if (size.w > 0 and size.h > 0) {
        const a_img = size.w / size.h;
        const a_box = r.w / r.h;
        if (a_img > a_box) {
            uv.w = a_box / a_img;
            uv.x = (1 - uv.w) / 2;
        } else {
            uv.h = a_img / a_box;
            uv.y = (1 - uv.h) / 2;
        }
    }
    const scale = dvui.currentWindow().natural_scale;
    dvui.renderTexture(tex, .{ .r = r, .s = scale }, .{
        .corners = .round(radius / scale),
        .colormod = dvui.Color.white.opacity(photo_opacity * fade),
        .uv = uv,
    }) catch {};
}
