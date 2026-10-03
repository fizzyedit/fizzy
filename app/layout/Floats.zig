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
const Layout = @import("Layout.zig");
const ViewDrag = @import("ViewDrag.zig");

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
    if (f.win_id == .zero or f.bounds.w <= 0) {
        // Never drawn: nothing to fly shut.
        state.floats.removeAt(i);
    } else {
        f.closing = true;
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
