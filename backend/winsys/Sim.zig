//! Sim: a `Platform` that lives in memory, so a test can drive the windowing interface the way a
//! user does and get the same answers every run. Simulated displays (scale, refresh,
//! arrangement), windows with a z-order, focus, full screen and minimise, input a test injects,
//! a clipboard, drags from other programs, input-method composition, and a virtual clock.
//!
//! **Time is the test's.** `now` returns the virtual clock and nothing moves it but `advance` and
//! `wait` (which jumps to the next thing due instead of sleeping). Two runs of a script give the
//! same events with the same stamps.
//!
//! **Transitions are late, as on a real OS.** A window state change, resize or move is a request
//! (`transition_ns` later it happens). `windowState` keeps saying the old state until then, and
//! the `state`, `resized` and `moved` events arrive when it does, so an adapter that assumed the
//! call was synchronous fails here and not on a user's machine. Focus changes are not requests
//! (a click or a raise has them at once), and their events are queued where they happen.
//!
//! **What the tests pin.** An `overlay` window never takes focus and is click-through (hit tests
//! look past it) and always stays above ordinary windows. A window's drag visit is `enter`,
//! `move`s, then `leave` or `drop`; the drop's outcome is the app's last `dropRespond`. A
//! composition in progress is cancelled when its window loses focus or text input: the notes
//! (`docs/window-notes/ime.md`) leave that to the platform until a conformance case fixes it, and
//! this is Sim's choice, not a finding. Allocation failure aborts: Sim is a test double, and the
//! functions an app calls cannot report it.
//!
//! **Raw events, not normalised.** Sim queues events itself and does not go through
//! `EventQueue`, so it does not exercise normalisation: losing focus, for one, releases
//! no held key or button. TODO(seam): an event-queue pass over Sim's output, before the
//! conformance suite (step 6) relies on it.
//!
//! Not modelled yet: pointer capture across windows (a release lands in the window under the
//! pointer), modal parents, window hints, display bounds changing in place.
const std = @import("std");
const geometry = @import("geometry.zig");
const Platform = @import("Platform.zig");
const Window = @import("Window.zig");
const Display = @import("Display.zig");
const Event = @import("Event.zig");
const Clipboard = @import("Clipboard.zig");
const Drop = @import("Drop.zig");
const Ime = @import("Ime.zig");

const Allocator = std.mem.Allocator;
const Arena = std.heap.ArenaAllocator;

const Sim = @This();

gpa: Allocator,
caps: Platform.Caps,
transition_ns: u64,
clock_ns: u64 = 0,
/// Set by `wake`; the next `wait` returns at once and clears it.
woken: bool = false,
next_window_id: u64 = 1,
next_display_id: u64 = 1,
opened: u32 = 0,
displays_list: std.ArrayList(DisplayRec) = .empty,
/// Bottom to top.
windows: std.ArrayList(Win) = .empty,
focus_id: ?u64 = null,
queue: std.ArrayList(Queued) = .empty,
pending: std.ArrayList(Pending) = .empty,
/// The arena of the event `poll` handed out last, freed by the next `poll`.
lent: ?*Arena = null,
/// Stamps events fired from `pending` with the time they were due, not the time `advance` reached.
event_time: ?u64 = null,
pointer: Pt = .{},
hover: ?u64 = null,
buttons: u8 = 0,
mods: Event.Mods = .{},
clip: ?[]u8 = null,
clip_serial: u64 = 1,
drag: ?DragSession = null,

pub const Pt = struct { x: f32 = 0, y: f32 = 0 };

pub const Options = struct {
    caps: Platform.Caps = .{
        .materials = .init(.{ .none = true, .transparent = true, .blur = true, .frost = true, .liquid = true }),
        .overlay = true,
    },
    /// How late a state change, resize or move lands after the call that asked for it.
    transition_ns: u64 = 10 * std.time.ns_per_ms,
    displays: []const DisplaySpec = &.{.{}},
};

pub const DisplaySpec = struct {
    name: []const u8 = "Simulated",
    bounds: geometry.DesktopRect = .{ .w = 1920, .h = 1080 },
    /// What system UI (a menu bar) takes off the top of `bounds`.
    top_inset: i32 = 0,
    scale: f32 = 1,
    refresh_hz: f32 = 60,
    /// The first display added is primary regardless.
    primary: bool = false,
};

/// How a drag from another program ended.
pub const DropOutcome = enum { accepted, rejected, outside };

const DisplayRec = struct {
    id: u64,
    name: []u8,
    bounds: geometry.DesktopRect,
    usable: geometry.DesktopRect,
    scale: f32,
    refresh_hz: f32,
    primary: bool,
};

const Win = struct {
    id: u64,
    title: []u8,
    kind: Window.Kind,
    parent: ?u64,
    focusable: bool,
    visible: bool,
    pos: geometry.DesktopPoint,
    size: geometry.DesktopSize,
    scale: f32,
    state: Window.State = .normal,
    /// Where `normal` geometry is kept while the window is maximized or full screen.
    restore_pos: geometry.DesktopPoint,
    restore_size: geometry.DesktopSize,
    before_fullscreen: Window.State = .normal,
    before_minimized: Window.State = .normal,
    material: Window.MaterialKind,
    cursor: Window.Cursor = .arrow,
    text_input: bool = false,
    ime_area: Ime.Area = .{},
    composing: bool = false,
    drop_response: Drop.Response = .reject,

    fn rect(w: Win) geometry.DesktopRect {
        return .{ .x = w.pos.x, .y = w.pos.y, .w = @intCast(w.size.w), .h = @intCast(w.size.h) };
    }
};

/// An event waiting for `poll`, with the arena that owns what it borrows, if anything.
const Queued = struct { event: Event, owned: ?*Arena = null };

const Change = union(enum) {
    state: Window.State,
    size: geometry.DesktopSize,
    position: geometry.DesktopPoint,
};
const Pending = struct { due_ns: u64, window: u64, change: Change };

const DragSession = struct {
    arena: *Arena,
    data: Drop.Data,
    over: ?u64 = null,
};

pub fn init(gpa: Allocator, options: Options) Sim {
    var sim: Sim = .{ .gpa = gpa, .caps = options.caps, .transition_ns = options.transition_ns };
    for (options.displays) |spec| _ = sim.addDisplay(spec);
    return sim;
}

pub fn deinit(sim: *Sim) void {
    for (sim.windows.items) |w| sim.gpa.free(w.title);
    sim.windows.deinit(sim.gpa);
    for (sim.displays_list.items) |d| sim.gpa.free(d.name);
    sim.displays_list.deinit(sim.gpa);
    for (sim.queue.items) |q| sim.destroyArena(q.owned);
    sim.queue.deinit(sim.gpa);
    sim.pending.deinit(sim.gpa);
    sim.destroyArena(sim.lent);
    if (sim.drag) |d| sim.destroyArena(d.arena);
    if (sim.clip) |c| sim.gpa.free(c);
    sim.* = undefined;
}

pub fn platform(sim: *Sim) Platform {
    return .{ .ctx = sim, .vtable = &vtable, .caps = sim.caps };
}

fn oom() noreturn {
    @panic("Sim: out of memory (a test double does not report it)");
}

fn destroyArena(sim: *Sim, arena: ?*Arena) void {
    const a = arena orelse return;
    a.deinit();
    sim.gpa.destroy(a);
}

fn newArena(sim: *Sim) *Arena {
    const a = sim.gpa.create(Arena) catch oom();
    a.* = .init(sim.gpa);
    return a;
}

// ---- the clock ----------------------------------------------------------------------------

/// Moves the virtual clock forward and lets everything that falls due happen, in order.
pub fn advance(sim: *Sim, ns: u64) void {
    sim.clock_ns += ns;
    sim.pump();
}

/// When the next requested transition lands, if one is waiting.
pub fn nextDue(sim: *const Sim) ?u64 {
    return if (sim.pending.items.len > 0) sim.pending.items[0].due_ns else null;
}

fn pump(sim: *Sim) void {
    while (sim.pending.items.len > 0 and sim.pending.items[0].due_ns <= sim.clock_ns) {
        const p = sim.pending.orderedRemove(0);
        sim.event_time = p.due_ns;
        defer sim.event_time = null;
        if (sim.find(p.window) == null) continue;
        switch (p.change) {
            .state => |s| sim.applyState(p.window, s),
            .size => |s| sim.applySize(p.window, s),
            .position => |at| sim.applyPosition(p.window, at),
        }
    }
}

fn schedule(sim: *Sim, window: u64, change: Change) void {
    const due = sim.clock_ns + sim.transition_ns;
    var at = sim.pending.items.len;
    while (at > 0 and sim.pending.items[at - 1].due_ns > due) at -= 1;
    sim.pending.insert(sim.gpa, at, .{ .due_ns = due, .window = window, .change = change }) catch oom();
}

fn emit(sim: *Sim, window: ?u64, payload: Event.Payload) void {
    sim.emitOwned(window, payload, null);
}

fn emitOwned(sim: *Sim, window: ?u64, payload: Event.Payload, owned: ?*Arena) void {
    sim.queue.append(sim.gpa, .{
        .event = .{
            .time_ns = sim.event_time orelse sim.clock_ns,
            .window = if (window) |id| .{ .id = id } else null,
            .payload = payload,
        },
        .owned = owned,
    }) catch oom();
}

// ---- displays -----------------------------------------------------------------------------

/// Plugs a display in; windows are re-checked against the new arrangement. Returns its id.
pub fn addDisplay(sim: *Sim, spec: DisplaySpec) u64 {
    const id = sim.next_display_id;
    sim.next_display_id += 1;
    const primary = spec.primary or sim.displays_list.items.len == 0;
    if (primary) for (sim.displays_list.items) |*d| {
        d.primary = false;
    };
    var usable = spec.bounds;
    usable.y += spec.top_inset;
    usable.h -= spec.top_inset;
    sim.displays_list.append(sim.gpa, .{
        .id = id,
        .name = sim.gpa.dupe(u8, spec.name) catch oom(),
        .bounds = spec.bounds,
        .usable = usable,
        .scale = spec.scale,
        .refresh_hz = spec.refresh_hz,
        .primary = primary,
    }) catch oom();
    sim.rescaleAll();
    return id;
}

/// Unplugs a display. A window whose home it was lands on the primary one, with `moved` and, if
/// the scale differs, `resized`.
pub fn removeDisplay(sim: *Sim, id: u64) void {
    const at = sim.displayIndex(id) orelse return;
    const gone = sim.displays_list.orderedRemove(at);
    sim.gpa.free(gone.name);
    if (gone.primary and sim.displays_list.items.len > 0) sim.displays_list.items[0].primary = true;
    for (sim.windows.items) |w| {
        if (sim.displayAt(w.rect()) != null) continue;
        if (sim.primaryDisplay()) |home| {
            sim.applyPosition(w.id, .{ .x = home.usable.x + 24, .y = home.usable.y + 24 });
        }
    }
    sim.rescaleAll();
}

pub fn setDisplayScale(sim: *Sim, id: u64, scale: f32) void {
    const at = sim.displayIndex(id) orelse return;
    sim.displays_list.items[at].scale = scale;
    sim.rescaleAll();
}

fn displayIndex(sim: *const Sim, id: u64) ?usize {
    for (sim.displays_list.items, 0..) |d, i| if (d.id == id) return i;
    return null;
}

fn primaryDisplay(sim: *const Sim) ?*const DisplayRec {
    for (sim.displays_list.items) |*d| if (d.primary) return d;
    return null;
}

/// The display with the most of `rect` on it, or null if it is on none.
fn displayAt(sim: *const Sim, rect: geometry.DesktopRect) ?*const DisplayRec {
    var best: ?*const DisplayRec = null;
    var best_area: i64 = 0;
    for (sim.displays_list.items) |*d| {
        const w = @min(rect.x + rect.w, d.bounds.x + d.bounds.w) - @max(rect.x, d.bounds.x);
        const h = @min(rect.y + rect.h, d.bounds.y + d.bounds.h) - @max(rect.y, d.bounds.y);
        if (w <= 0 or h <= 0) continue;
        const area = @as(i64, w) * h;
        if (area > best_area) {
            best = d;
            best_area = area;
        }
    }
    return best;
}

fn rescaleAll(sim: *Sim) void {
    for (sim.windows.items) |*w| sim.rescale(w);
}

/// Follows the window's display scale: the OS says so with a `resized` carrying the new one.
fn rescale(sim: *Sim, w: *Win) void {
    const d = sim.displayAt(w.rect()) orelse return;
    if (d.scale == w.scale) return;
    w.scale = d.scale;
    sim.emitResized(w.*, false);
}

fn emitResized(sim: *Sim, w: Win, live: bool) void {
    sim.emit(w.id, .{ .resized = .{ .size = pixels(w), .scale = w.scale, .live = live } });
}

fn pixels(w: Win) geometry.Size {
    if (w.state == .minimized) return .{};
    return .{
        .w = @intFromFloat(@round(@as(f32, @floatFromInt(w.size.w)) * w.scale)),
        .h = @intFromFloat(@round(@as(f32, @floatFromInt(w.size.h)) * w.scale)),
    };
}

// ---- windows ------------------------------------------------------------------------------

fn find(sim: *Sim, id: u64) ?*Win {
    for (sim.windows.items) |*w| if (w.id == id) return w;
    return null;
}

fn indexOf(sim: *const Sim, id: u64) ?usize {
    for (sim.windows.items, 0..) |w, i| if (w.id == id) return i;
    return null;
}

/// The window with keyboard focus.
pub fn focused(sim: *const Sim) ?Window {
    return if (sim.focus_id) |id| .{ .id = id } else null;
}

/// Position in the stack, 0 the bottom; null for a window that is gone.
pub fn stackIndex(sim: *const Sim, window: Window) ?usize {
    return sim.indexOf(window.id);
}

pub fn windowCount(sim: *const Sim) usize {
    return sim.windows.items.len;
}

/// The topmost window that takes input at this desktop point: not hidden, not minimized, and
/// never an overlay, which is click-through.
pub fn windowAt(sim: *const Sim, at: Pt) ?Window {
    var i = sim.windows.items.len;
    while (i > 0) {
        i -= 1;
        const w = sim.windows.items[i];
        if (!w.visible or w.state == .minimized or w.kind == .overlay) continue;
        const r = w.rect();
        const x: i32 = @intFromFloat(@floor(at.x));
        const y: i32 = @intFromFloat(@floor(at.y));
        if (x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h) return .{ .id = w.id };
    }
    return null;
}

fn canFocus(w: Win) bool {
    return w.focusable and w.visible and w.state != .minimized and w.kind != .overlay;
}

fn setFocus(sim: *Sim, new: ?u64) void {
    if (sim.focus_id == new) return;
    if (sim.focus_id) |old| if (sim.find(old)) |w| {
        sim.cancelComposition(w);
        sim.emit(old, .{ .focus = false });
    };
    sim.focus_id = new;
    if (new) |id| sim.emit(id, .{ .focus = true });
}

/// Focus goes to the topmost window that can take it, as when the focused one closes or hides.
fn passFocus(sim: *Sim) void {
    var i = sim.windows.items.len;
    while (i > 0) {
        i -= 1;
        if (canFocus(sim.windows.items[i])) return sim.setFocus(sim.windows.items[i].id);
    }
    sim.setFocus(null);
}

fn raise(sim: *Sim, id: u64) void {
    const at = sim.indexOf(id) orelse return;
    const w = sim.windows.orderedRemove(at);
    sim.windows.append(sim.gpa, w) catch oom();
    sim.settle();
}

/// Keeps what every stacking order keeps: a child above its parent, and overlays above all.
fn settle(sim: *Sim) void {
    var moved = true;
    while (moved) {
        moved = false;
        for (sim.windows.items, 0..) |w, i| {
            const parent = w.parent orelse continue;
            const p = sim.indexOf(parent) orelse continue;
            if (p < i) continue;
            const child = sim.windows.orderedRemove(i);
            sim.windows.insert(sim.gpa, p, child) catch oom();
            moved = true;
            break;
        }
    }
    var kept: usize = 0;
    for (0..sim.windows.items.len) |i| {
        if (sim.windows.items[i].kind == .overlay) continue;
        const w = sim.windows.orderedRemove(i);
        sim.windows.insert(sim.gpa, kept, w) catch oom();
        kept += 1;
    }
}

fn applyPosition(sim: *Sim, id: u64, at: geometry.DesktopPoint) void {
    const w = sim.find(id) orelse return;
    if (w.state != .normal) return;
    if (std.meta.eql(w.pos, at)) return;
    w.pos = at;
    sim.emit(id, .{ .moved = at });
    sim.rescale(w);
}

fn applySize(sim: *Sim, id: u64, size: geometry.DesktopSize) void {
    const w = sim.find(id) orelse return;
    if (w.state != .normal or std.meta.eql(w.size, size)) return;
    w.size = size;
    sim.emitResized(w.*, false);
}

/// The geometry the window's state gives it, announced as the OS does: `moved` if it changed
/// place, `resized` always.
fn relayout(sim: *Sim, w: *Win) void {
    const home = sim.displayAt(w.rect()) orelse sim.primaryDisplay();
    const old = w.pos;
    switch (w.state) {
        .normal, .minimized => {
            w.pos = w.restore_pos;
            w.size = w.restore_size;
        },
        .maximized, .fullscreen => {
            const area = if (home) |d| (if (w.state == .maximized) d.usable else d.bounds) else w.rect();
            w.pos = .{ .x = area.x, .y = area.y };
            w.size = .{ .w = @intCast(area.w), .h = @intCast(area.h) };
        },
    }
    if (!std.meta.eql(old, w.pos)) sim.emit(w.id, .{ .moved = w.pos });
    sim.emitResized(w.*, false);
}

fn applyState(sim: *Sim, id: u64, to: Window.State) void {
    const w = sim.find(id) orelse return;
    if (w.state == to) return;
    if (to == .minimized) {
        w.before_minimized = w.state;
        w.state = .minimized;
        sim.emit(id, .{ .state = .minimized });
        sim.emit(id, .{ .occluded = true });
        if (sim.focus_id == id) sim.passFocus();
        return;
    }
    if (w.state == .minimized) {
        w.state = w.before_minimized;
        sim.emit(id, .{ .state = .unminimized });
        sim.emit(id, .{ .occluded = false });
        if (w.visible and sim.focus_id == null) sim.setFocus(id);
        if (w.state == to) return;
    }
    if (w.state == .fullscreen) {
        w.state = w.before_fullscreen;
        sim.emit(id, .{ .state = .left_fullscreen });
        sim.relayout(w);
        // Leaving full screen is an exit, not a target: the window is where it was before.
        return;
    }
    // From here the window is normal or maximized, and `to` is one of normal, maximized, fullscreen.
    if (w.state == .normal) {
        w.restore_pos = w.pos;
        w.restore_size = w.size;
    }
    const from = w.state;
    w.state = to;
    switch (to) {
        .normal => sim.emit(id, .{ .state = .restored }),
        .maximized => sim.emit(id, .{ .state = .maximized }),
        .fullscreen => {
            w.before_fullscreen = from;
            sim.emit(id, .{ .state = .entered_fullscreen });
        },
        .minimized => unreachable, // handled above
    }
    sim.relayout(w);
}

fn openWindow(ctx: *anyopaque, options: Window.Options) Platform.Error!Window {
    const sim = me(ctx);
    if (options.kind == .overlay and !sim.caps.overlay) return error.Unsupported;
    if (!sim.caps.multiple_windows and sim.windows.items.len > 0) return error.Unsupported;
    const title = try sim.gpa.dupe(u8, options.title);
    errdefer sim.gpa.free(title);
    try sim.windows.ensureUnusedCapacity(sim.gpa, 1);

    const id = sim.next_window_id;
    sim.next_window_id += 1;
    const pos = options.position orelse sim.cascade();
    var w: Win = .{
        .id = id,
        .title = title,
        .kind = options.kind,
        .parent = if (options.parent) |p| p.id else null,
        .focusable = options.focusable and options.kind != .overlay,
        .visible = options.visible,
        .pos = pos,
        .size = options.size,
        .scale = 1,
        .restore_pos = pos,
        .restore_size = options.size,
        .material = sim.nearestMaterial(options.material.kind),
    };
    if (sim.displayAt(w.rect())) |d| w.scale = d.scale;
    sim.windows.appendAssumeCapacity(w);
    sim.settle();
    sim.emitResized(w, false);
    if (w.visible) sim.emit(id, .{ .state = .shown });
    if (canFocus(w)) sim.setFocus(id);
    if (options.state != .normal) sim.applyState(id, options.state);
    return .{ .id = id };
}

/// Where the OS puts a window nobody placed: stepped down and right from the primary display.
fn cascade(sim: *Sim) geometry.DesktopPoint {
    const n: i32 = @intCast(sim.opened % 10);
    sim.opened += 1;
    const d = sim.primaryDisplay() orelse return .{ .x = 40 + 24 * n, .y = 40 + 24 * n };
    return .{ .x = d.usable.x + 40 + 24 * n, .y = d.usable.y + 40 + 24 * n };
}

fn nearestMaterial(sim: *const Sim, want: Window.MaterialKind) Window.MaterialKind {
    var i: u8 = @backingInt(want);
    while (true) : (i -= 1) {
        const kind: Window.MaterialKind = @fromBackingInt(@intCast(i));
        if (sim.caps.materials.contains(kind)) return kind;
        if (i == 0) return .none;
    }
}

fn closeWindow(ctx: *anyopaque, window: Window) void {
    const sim = me(ctx);
    const at = sim.indexOf(window.id) orelse return;
    // A window's children close with it.
    var i: usize = 0;
    while (i < sim.windows.items.len) {
        if (sim.windows.items[i].parent == window.id) {
            closeWindow(ctx, .{ .id = sim.windows.items[i].id });
            i = 0;
        } else i += 1;
    }
    const gone = sim.windows.orderedRemove(sim.indexOf(window.id) orelse at);
    sim.gpa.free(gone.title);
    if (sim.hover == window.id) sim.hover = null;
    if (sim.drag) |*d| if (d.over == window.id) {
        d.over = null;
    };
    if (sim.focus_id == window.id) {
        sim.focus_id = null;
        sim.passFocus();
    }
}

fn me(ctx: *anyopaque) *Sim {
    return @ptrCast(@alignCast(ctx));
}

fn now(ctx: *anyopaque) u64 {
    return me(ctx).clock_ns;
}

fn poll(ctx: *anyopaque) ?Event {
    const sim = me(ctx);
    sim.pump();
    sim.destroyArena(sim.lent);
    sim.lent = null;
    if (sim.queue.items.len == 0) return null;
    const q = sim.queue.orderedRemove(0);
    sim.lent = q.owned;
    return q.event;
}

/// Sleeps in virtual time: returns at once if an event is waiting or `wake` was called,
/// otherwise jumps the clock to the next transition or the timeout, whichever is first. With no
/// timeout and nothing due it returns without moving the clock (a real one would block forever).
fn wait(ctx: *anyopaque, timeout_ns: ?u64) void {
    const sim = me(ctx);
    if (sim.woken) {
        sim.woken = false;
        return;
    }
    if (sim.queue.items.len > 0) return;
    var until: ?u64 = if (timeout_ns) |t| sim.clock_ns + t else null;
    if (sim.nextDue()) |due| until = if (until) |u| @min(u, due) else due;
    if (until) |u| sim.advance(u -| sim.clock_ns);
}

fn wake(ctx: *anyopaque) void {
    me(ctx).woken = true;
}

fn setTitle(ctx: *anyopaque, window: Window, title: []const u8) void {
    const sim = me(ctx);
    const w = sim.find(window.id) orelse return;
    const copy = sim.gpa.dupe(u8, title) catch oom();
    sim.gpa.free(w.title);
    w.title = copy;
}

fn windowSize(ctx: *anyopaque, window: Window) geometry.Size {
    const w = me(ctx).find(window.id) orelse return .{};
    return pixels(w.*);
}

fn setWindowSize(ctx: *anyopaque, window: Window, size: geometry.DesktopSize) void {
    me(ctx).schedule(window.id, .{ .size = size });
}

fn windowScale(ctx: *anyopaque, window: Window) f32 {
    return if (me(ctx).find(window.id)) |w| w.scale else 1;
}

fn windowPosition(ctx: *anyopaque, window: Window) geometry.DesktopPoint {
    return if (me(ctx).find(window.id)) |w| w.pos else .{};
}

fn setWindowPosition(ctx: *anyopaque, window: Window, at: geometry.DesktopPoint) void {
    me(ctx).schedule(window.id, .{ .position = at });
}

fn windowState(ctx: *anyopaque, window: Window) Window.State {
    return if (me(ctx).find(window.id)) |w| w.state else .normal;
}

fn setWindowState(ctx: *anyopaque, window: Window, state: Window.State) void {
    me(ctx).schedule(window.id, .{ .state = state });
}

fn showWindow(ctx: *anyopaque, window: Window, visible: bool) void {
    const sim = me(ctx);
    const w = sim.find(window.id) orelse return;
    if (w.visible == visible) return;
    w.visible = visible;
    sim.emit(window.id, .{ .state = if (visible) .shown else .hidden });
    if (!visible and sim.focus_id == window.id) sim.passFocus();
}

fn raiseWindow(ctx: *anyopaque, window: Window) void {
    const sim = me(ctx);
    const w = sim.find(window.id) orelse return;
    sim.raise(window.id);
    if (canFocus(w.*)) sim.setFocus(window.id);
}

fn setCursor(ctx: *anyopaque, window: Window, cursor: Window.Cursor) void {
    if (me(ctx).find(window.id)) |w| w.cursor = cursor;
}

fn setHints(_: *anyopaque, _: Window, _: Window.Hints) void {}

fn setMaterial(ctx: *anyopaque, window: Window, material: Window.MaterialSpec) void {
    const sim = me(ctx);
    if (sim.find(window.id)) |w| w.material = sim.nearestMaterial(material.kind);
}

fn windowMaterial(ctx: *anyopaque, window: Window) Window.MaterialKind {
    return if (me(ctx).find(window.id)) |w| w.material else .none;
}

fn displayOf(ctx: *anyopaque, window: Window) ?u64 {
    const sim = me(ctx);
    const w = sim.find(window.id) orelse return null;
    return if (sim.displayAt(w.rect())) |d| d.id else null;
}

fn displays(ctx: *anyopaque, allocator: Allocator) Platform.Error![]Display {
    const sim = me(ctx);
    const list = try allocator.alloc(Display, sim.displays_list.items.len);
    var made: usize = 0;
    errdefer {
        for (list[0..made]) |d| allocator.free(d.name);
        allocator.free(list);
    }
    for (sim.displays_list.items, list) |d, *out| {
        out.* = .{
            .id = d.id,
            .name = try allocator.dupe(u8, d.name),
            .bounds = d.bounds,
            .usable = d.usable,
            .scale = d.scale,
            .refresh_hz = d.refresh_hz,
            .primary = d.primary,
        };
        made += 1;
    }
    return list;
}

// ---- text input and the clipboard ---------------------------------------------------------

fn setTextInput(ctx: *anyopaque, window: Window, on: bool) void {
    const sim = me(ctx);
    const w = sim.find(window.id) orelse return;
    w.text_input = on;
    if (!on) sim.cancelComposition(w);
}

fn setImeArea(ctx: *anyopaque, window: Window, area: Ime.Area) void {
    if (me(ctx).find(window.id)) |w| w.ime_area = area;
}

fn clipboardSerial(ctx: *anyopaque) Clipboard {
    return .{ .serial = me(ctx).clip_serial };
}

fn clipboardText(ctx: *anyopaque, allocator: Allocator) Platform.Error!?[]u8 {
    return try allocator.dupe(u8, me(ctx).clip orelse return null);
}

fn setClipboardText(ctx: *anyopaque, text: []const u8) Platform.Error!void {
    const sim = me(ctx);
    const copy = try sim.gpa.dupe(u8, text);
    if (sim.clip) |old| sim.gpa.free(old);
    sim.clip = copy;
    sim.clip_serial += 1;
}

/// Another program copies: the serial moves and the focused window hears it.
pub fn copyFromOutside(sim: *Sim, text: []const u8) void {
    const copy = sim.gpa.dupe(u8, text) catch oom();
    if (sim.clip) |old| sim.gpa.free(old);
    sim.clip = copy;
    sim.clip_serial += 1;
    sim.emit(sim.focus_id, .{ .clipboard = .{ .serial = sim.clip_serial } });
}

// ---- input a test injects -----------------------------------------------------------------

fn toWindow(w: Win, at: Pt) geometry.Point {
    return .{ .x = (at.x - @as(f32, @floatFromInt(w.pos.x))) * w.scale, .y = (at.y - @as(f32, @floatFromInt(w.pos.y))) * w.scale };
}

/// Where a point of a window is on the desktop, for `movePointer`.
pub fn desktopPoint(sim: *Sim, window: Window, at: geometry.Point) Pt {
    const w = sim.find(window.id).?;
    return .{ .x = @as(f32, @floatFromInt(w.pos.x)) + at.x / w.scale, .y = @as(f32, @floatFromInt(w.pos.y)) + at.y / w.scale };
}

/// The pointer goes to a desktop point. The window it leaves hears `leave`, the one it enters a
/// `move`; during a drag from another program the drag hears it instead of a pointer.
pub fn movePointer(sim: *Sim, to: Pt) void {
    const from = sim.pointer;
    sim.pointer = to;
    const target = if (sim.windowAt(to)) |w| w.id else null;
    if (sim.drag != null) return sim.dragSync(target);
    if (target != sim.hover) {
        if (sim.hover) |old| if (sim.find(old)) |w| {
            sim.emit(old, .{ .pointer = .{ .kind = .leave, .at = toWindow(w.*, from), .mods = sim.mods } });
        };
        sim.hover = target;
    }
    if (target) |id| sim.emit(id, .{ .pointer = .{ .kind = .move, .at = toWindow(sim.find(id).?.*, to), .mods = sim.mods } });
}

/// A button goes down over the window under the pointer, which comes forward and takes focus
/// unless it is a kind that never does. Over no window it is lost.
pub fn pressButton(sim: *Sim, button: Event.Button) void {
    const id = sim.hover orelse return;
    const w = sim.find(id) orelse return;
    sim.buttons |= @as(u8, 1) << @backingInt(button);
    if (canFocus(w.*)) {
        sim.raise(id);
        sim.setFocus(id);
    }
    sim.emit(id, .{ .pointer = .{ .kind = .press, .at = toWindow(w.*, sim.pointer), .button = button, .mods = sim.mods } });
}

/// The release goes to the window under the pointer, wherever the press was.
pub fn releaseButton(sim: *Sim, button: Event.Button) void {
    sim.buttons &= ~(@as(u8, 1) << @backingInt(button));
    const id = sim.hover orelse return;
    const w = sim.find(id) orelse return;
    sim.emit(id, .{ .pointer = .{ .kind = .release, .at = toWindow(w.*, sim.pointer), .button = button, .mods = sim.mods } });
}

pub fn wheel(sim: *Sim, dx: f32, dy: f32, precise: bool) void {
    const id = sim.hover orelse return;
    const w = sim.find(id) orelse return;
    sim.emit(id, .{ .wheel = .{
        .dx = dx,
        .dy = dy,
        .at = toWindow(w.*, sim.pointer),
        .precise = precise,
        .mods = sim.mods,
    } });
}

/// A key event for the focused window. The modifiers a key holds are tracked here, as the OS
/// does, so every event carries them; `caps_lock` and `num_lock` toggle on a press.
pub fn key(sim: *Sim, code: Event.Code, action: @FieldType(Event.Key, "action")) void {
    const down = action != .up;
    switch (code) {
        .left_shift, .right_shift => sim.mods.shift = down,
        .left_ctrl, .right_ctrl => sim.mods.ctrl = down,
        .left_alt => sim.mods.alt = down,
        .right_alt => sim.mods.altgr = down,
        .left_gui, .right_gui => sim.mods.gui = down,
        .caps_lock => if (action == .down) {
            sim.mods.caps_lock = !sim.mods.caps_lock;
        },
        .num_lock => if (action == .down) {
            sim.mods.num_lock = !sim.mods.num_lock;
        },
        else => {},
    }
    const id = sim.focus_id orelse return;
    const code_int = @backingInt(code);
    const logical: Event.Key.Logical = if (code_int >= @backingInt(Event.Code.a) and code_int <= @backingInt(Event.Code.z))
        .{ .char = 'a' + @as(u21, @intCast(code_int - @backingInt(Event.Code.a))) }
    else if (code_int >= @backingInt(Event.Code.@"0") and code_int <= @backingInt(Event.Code.@"9"))
        .{ .char = '0' + @as(u21, @intCast(code_int - @backingInt(Event.Code.@"0"))) }
    else if (code == .space)
        .{ .char = ' ' }
    else
        .{ .named = code };
    sim.emit(id, .{ .key = .{ .physical = code, .logical = logical, .action = action, .mods = sim.mods } });
}

/// A key tapped: down, the text it types if the window is taking text, then up.
pub fn tap(sim: *Sim, code: Event.Code) void {
    sim.key(code, .down);
    if (sim.focus_id) |id| if (sim.find(id)) |w| if (w.text_input and !sim.mods.ctrl and !sim.mods.gui) {
        const code_int = @backingInt(code);
        var typed: ?u8 = null;
        if (code_int >= @backingInt(Event.Code.a) and code_int <= @backingInt(Event.Code.z)) {
            const upper = sim.mods.shift != sim.mods.caps_lock;
            typed = @as(u8, if (upper) 'A' else 'a') + @as(u8, @intCast(code_int - @backingInt(Event.Code.a)));
        } else if (code_int >= @backingInt(Event.Code.@"0") and code_int <= @backingInt(Event.Code.@"9")) {
            typed = '0' + @as(u8, @intCast(code_int - @backingInt(Event.Code.@"0")));
        } else if (code == .space) typed = ' ';
        if (typed) |c| sim.typeText(&.{c});
    };
    sim.key(code, .up);
}

/// Committed text for the focused window, as a layout or an input method makes it; dropped if
/// no window is taking text.
pub fn typeText(sim: *Sim, text: []const u8) void {
    const w = sim.find(sim.focus_id orelse return) orelse return;
    if (!w.text_input or text.len == 0) return;
    const arena = sim.newArena();
    const copy = arena.allocator().dupe(u8, text) catch oom();
    sim.emitOwned(w.id, .{ .text = copy }, arena);
}

// ---- input-method composition -------------------------------------------------------------

/// The input method shows provisional text in the focused window, replacing what it showed.
pub fn imeCompose(sim: *Sim, text: []const u8, start: u32, len: u32) void {
    const w = sim.find(sim.focus_id orelse return) orelse return;
    if (!w.text_input) return;
    w.composing = true;
    sim.emitIme(w.id, text, start, len);
}

/// The input method commits: the run is cleared, then the text arrives, in that order.
pub fn imeCommit(sim: *Sim, text: []const u8) void {
    const w = sim.find(sim.focus_id orelse return) orelse return;
    if (!w.composing) return;
    w.composing = false;
    sim.emitIme(w.id, "", 0, 0);
    sim.typeText(text);
}

/// The user abandons the composition: the run is cleared and no text follows.
pub fn imeCancel(sim: *Sim) void {
    const w = sim.find(sim.focus_id orelse return) orelse return;
    sim.cancelComposition(w);
}

fn cancelComposition(sim: *Sim, w: *Win) void {
    if (!w.composing) return;
    w.composing = false;
    sim.emitIme(w.id, "", 0, 0);
}

fn emitIme(sim: *Sim, id: u64, text: []const u8, start: u32, len: u32) void {
    const arena = sim.newArena();
    const copy = arena.allocator().dupe(u8, text) catch oom();
    sim.emitOwned(id, .{ .ime = .{ .text = copy, .start = start, .len = len } }, arena);
}

// ---- drags from other programs ------------------------------------------------------------

/// Another program starts dragging `data` (copied here). Until it ends, the pointer is the
/// drag's: the window under it hears `enter`, `move` and `leave` as `Drop`, not pointer events.
pub fn dragBegin(sim: *Sim, data: Drop.Data) void {
    std.debug.assert(sim.drag == null);
    const arena = sim.newArena();
    const owned = cloneData(arena.allocator(), data);
    sim.drag = .{ .arena = arena, .data = owned };
    sim.dragSync(if (sim.windowAt(sim.pointer)) |w| w.id else null);
}

/// The data given to a window event: the same as the session's, held by the event's own arena
/// because the session may end before the event is polled.
fn dropEvent(sim: *Sim, id: u64, phase: Drop.Phase, with_data: bool) void {
    const arena = sim.newArena();
    const a = arena.allocator();
    const at = if (phase == .leave) geometry.Point{} else toWindow(sim.find(id).?.*, sim.pointer);
    const data: Drop.Data = if (with_data) cloneData(a, sim.drag.?.data) else .unsupported;
    sim.emitOwned(id, .{ .drop = .{ .phase = phase, .at = at, .data = data } }, arena);
}

fn cloneData(a: Allocator, data: Drop.Data) Drop.Data {
    return switch (data) {
        .unsupported => .unsupported,
        .text => |t| .{ .text = a.dupe(u8, t) catch oom() },
        .files => |files| blk: {
            const list = a.alloc([]const u8, files.len) catch oom();
            for (files, list) |f, *out| out.* = a.dupe(u8, f) catch oom();
            break :blk .{ .files = list };
        },
    };
}

fn dragSync(sim: *Sim, target: ?u64) void {
    const session = &sim.drag.?;
    if (target != session.over) {
        if (session.over) |old| sim.dropEvent(old, .leave, false);
        session.over = target;
        if (target) |id| {
            sim.find(id).?.drop_response = .reject;
            return sim.dropEvent(id, .enter, true);
        }
        return;
    }
    if (target) |id| sim.dropEvent(id, .move, true);
}

/// The user lets go. Over a window it hears `drop`; the outcome is what the app last answered
/// with `dropRespond`. Over none (or after `dragCancel`) nothing is delivered.
pub fn dragRelease(sim: *Sim) DropOutcome {
    const session = sim.drag.?;
    defer {
        sim.destroyArena(session.arena);
        sim.drag = null;
    }
    const id = session.over orelse return .outside;
    sim.dropEvent(id, .drop, true);
    return if (sim.find(id).?.drop_response == .copy) .accepted else .rejected;
}

/// The user abandons the drag (Escape): the window under it hears `leave`.
pub fn dragCancel(sim: *Sim) void {
    const session = sim.drag.?;
    if (session.over) |id| sim.dropEvent(id, .leave, false);
    sim.destroyArena(session.arena);
    sim.drag = null;
}

fn dropRespond(ctx: *anyopaque, window: Window, response: Drop.Response) void {
    if (me(ctx).find(window.id)) |w| w.drop_response = response;
}

const vtable: Platform.VTable = .{
    .now = now,
    .poll = poll,
    .wait = wait,
    .wake = wake,
    .open_window = openWindow,
    .close_window = closeWindow,
    .set_title = setTitle,
    .window_size = windowSize,
    .set_window_size = setWindowSize,
    .window_scale = windowScale,
    .window_position = windowPosition,
    .set_window_position = setWindowPosition,
    .window_state = windowState,
    .set_window_state = setWindowState,
    .show_window = showWindow,
    .raise_window = raiseWindow,
    .set_cursor = setCursor,
    .set_hints = setHints,
    .set_material = setMaterial,
    .window_material = windowMaterial,
    .display_of = displayOf,
    .displays = displays,
    .set_text_input = setTextInput,
    .set_ime_area = setImeArea,
    .clipboard_serial = clipboardSerial,
    .clipboard_text = clipboardText,
    .set_clipboard_text = setClipboardText,
    .drop_respond = dropRespond,
};

test {
    _ = @import("tests/root.zig");
}
