//! Replayer: plays a recorded stream (`stream.zig`) into a `Sim` and says where what the Sim does
//! differs from what the stream saw.
//!
//! **What is fed.** The stream's clock, its requests (windows opened, sized, …), its display
//! changes, the clipboard text behind its clipboard events, and the events a person's hands make:
//! pointer moves and buttons, wheel, keys and typed text. They go in on the Sim's own input calls,
//! in the order they happened (an event is stamped before the app polled it, so it goes in at its
//! stamp, ahead of a request the app made in between).
//!
//! **What is compared.** Everything else the Sim answers with (focus, resized, moved, state,
//! occluded, a pointer leaving, clipboard) against the events the stream polled, in order, by
//! their stream form, so a window or display is the stream's name for it and not the Sim's.
//! **Unverified.** Composition (`ime`), `touch`, `drop`, `close_requested`, `background`,
//! `foreground` and `quit` events are neither fed nor compared: a stream holding them replays
//! "clean" without any of them having been checked, and `Report.skipped` counts them so a caller
//! can see how much went unchecked. (`Sim` has `imeCompose` and the like, but no injector for
//! the rest.) TODO(seam): `Sim` injectors for these, which turns them from skipped to compared.
//!
//! A redacted stream (`Recorder.Options.redact`) has no key characters and `*` for text: a key
//! whose stream form has no `logical` is compared on everything but it, and the text replays as
//! the `*` it holds.
//!
//! A stream a Sim recorded replays clean, which is what the golden streams pin. One a real
//! platform recorded replays into the Sim's idea of that platform, and the differences are the
//! report: where Sim has not modelled something, or the platform did something it should not.
//! Pointer positions go through the window's scale and back, so a fractional scale can differ in
//! the last bit.
const std = @import("std");
const Platform = @import("Platform.zig");
const Window = @import("Window.zig");
const Display = @import("Display.zig");
const Event = @import("Event.zig");
const Sim = @import("Sim.zig");
const stream = @import("stream.zig");

const Allocator = std.mem.Allocator;

const Replayer = @This();

gpa: Allocator,
/// The decoded stream, and the text of the report.
arena: std.heap.ArenaAllocator,
records: []const stream.Record,
sim: Sim,
/// Stream-local window number to the Sim's id, and back.
windows: std.AutoHashMapUnmanaged(u64, u64) = .empty,
sim_windows: std.AutoHashMapUnmanaged(u64, u64) = .empty,
/// The same for displays.
displays: std.AutoHashMapUnmanaged(u64, u64) = .empty,
/// The first `displays` record set up the Sim, so the replay skips it.
first_displays: ?usize = null,

pub const Report = struct {
    /// Events the stream polled that are compared, and events the Sim produced that are.
    expected: usize = 0,
    actual: usize = 0,
    /// Events the stream polled that the Sim has no way to be given or to answer with.
    skipped: usize = 0,
    /// Requests that named a window the replay does not have, or that the Sim refused.
    request_errors: usize = 0,
    mismatch: ?Mismatch = null,

    pub fn clean(report: Report) bool {
        return report.mismatch == null and report.expected == report.actual and report.request_errors == 0;
    }
};

/// The first place the two sides differ, as text; null on a side that ran out. Owned by the
/// replayer.
pub const Mismatch = struct {
    index: usize,
    expected: ?[]const u8,
    actual: ?[]const u8,
};

/// Decodes `bytes` and builds the Sim it plays into, with the displays of the stream's first
/// display record. The bytes are not kept.
pub fn init(gpa: Allocator, bytes: []const u8) (stream.Error || Allocator.Error)!Replayer {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    var reader = try stream.Reader.init(bytes);
    var list: std.ArrayList(stream.Record) = .empty;
    while (try reader.next(arena.allocator())) |record| try list.append(arena.allocator(), record);

    var first: ?usize = null;
    for (list.items, 0..) |record, i| if (record.body == .displays) {
        first = i;
        break;
    };
    var specs: []const Sim.DisplaySpec = &.{.{}};
    if (first) |i| specs = try displaySpecs(arena.allocator(), list.items[i].body.displays);

    var r: Replayer = .{
        .gpa = gpa,
        .arena = arena,
        .records = list.items,
        .sim = .init(gpa, .{ .displays = specs }),
        .first_displays = first,
    };
    errdefer r.deinit();
    if (first) |i| for (list.items[i].body.displays, r.sim.displays_list.items) |d, made| {
        try r.displays.put(gpa, d.id, made.id);
    };
    return r;
}

pub fn deinit(r: *Replayer) void {
    r.windows.deinit(r.gpa);
    r.sim_windows.deinit(r.gpa);
    r.displays.deinit(r.gpa);
    r.sim.deinit();
    r.arena.deinit();
    r.* = undefined;
}

fn displaySpecs(a: Allocator, list: []const Display) Allocator.Error![]Sim.DisplaySpec {
    const out = try a.alloc(Sim.DisplaySpec, list.len);
    for (list, out) |d, *spec| spec.* = specOf(d);
    return out;
}

fn specOf(d: Display) Sim.DisplaySpec {
    return .{
        .name = d.name,
        .bounds = d.bounds,
        .top_inset = d.usable.y - d.bounds.y,
        .scale = d.scale,
        .refresh_hz = d.refresh_hz,
        .primary = d.primary,
    };
}

/// Plays the whole stream and compares. Run once per replayer.
pub fn run(r: *Replayer) Allocator.Error!Report {
    var report: Report = .{};
    const order = try r.timeline();
    defer r.gpa.free(order);
    var end_ns: u64 = 0;
    for (order) |i| {
        const record = r.records[i];
        end_ns = @max(end_ns, record.t_ns);
        r.sim.advance(at(record) -| r.sim.clock_ns);
        switch (record.body) {
            .clock => {},
            .displays => |list| if (i != r.first_displays) try r.changeDisplays(list),
            .clipboard_text => |text| r.sim.copyFromOutside(text),
            .event => |e| r.feed(e),
            .request => |req| if (!try r.apply(req)) {
                report.request_errors += 1;
            },
        }
    }
    r.sim.advance(end_ns -| r.sim.clock_ns);
    try r.compare(&report);
    return report;
}

/// The time a record takes effect: an event at its stamp, the rest when the app saw them.
fn at(record: stream.Record) u64 {
    return switch (record.body) {
        .event => |e| e.time_ns,
        else => record.t_ns,
    };
}

/// Indices of the records the replay acts on, in the order they take effect. Stable: records at
/// one instant stay in the order the app saw them.
fn timeline(r: *Replayer) Allocator.Error![]usize {
    var order: std.ArrayList(usize) = .empty;
    errdefer order.deinit(r.gpa);
    for (r.records, 0..) |record, i| switch (record.body) {
        .event => |e| if (injected(e.payload)) try order.append(r.gpa, i),
        else => try order.append(r.gpa, i),
    };
    std.sort.block(usize, order.items, r, struct {
        fn before(rep: *Replayer, a: usize, b: usize) bool {
            return at(rep.records[a]) < at(rep.records[b]);
        }
    }.before);
    return order.toOwnedSlice(r.gpa);
}

/// Input the Sim is given, as opposed to answers it works out.
fn injected(payload: Event.Payload) bool {
    return switch (payload) {
        .pointer => |p| p.kind != .leave,
        .wheel, .key, .text => true,
        else => false,
    };
}

/// Events with no input on the Sim, so no way to compare them either.
fn skipped(payload: Event.Payload) bool {
    return switch (payload) {
        .ime, .touch, .drop, .close_requested, .background, .foreground, .quit => true,
        else => false,
    };
}

fn feed(r: *Replayer, e: Event) void {
    const local = e.window orelse return;
    const id = r.windows.get(local.id) orelse return;
    const window: Window = .{ .id = id };
    if (r.sim.stackIndex(window) == null) return;
    switch (e.payload) {
        .pointer => |p| switch (p.kind) {
            .move => r.sim.movePointer(r.sim.desktopPoint(window, p.at)),
            .press => r.sim.pressButton(p.button),
            .release => r.sim.releaseButton(p.button),
            .leave => {},
        },
        .wheel => |w| r.sim.wheel(w.dx, w.dy, w.precise),
        .key => |k| r.sim.key(k.physical, k.action),
        .text => |t| r.sim.typeText(t),
        else => unreachable, // `injected` lets nothing else through
    }
}

/// Makes the Sim's displays the snapshot's: new ones plugged in, missing ones unplugged, scales
/// followed. A display moving in place is not something the Sim models.
fn changeDisplays(r: *Replayer, list: []const Display) Allocator.Error!void {
    var gone: std.ArrayList(u64) = .empty;
    defer gone.deinit(r.gpa);
    var known = r.displays.iterator();
    next: while (known.next()) |entry| {
        for (list) |d| if (d.id == entry.key_ptr.*) continue :next;
        try gone.append(r.gpa, entry.key_ptr.*);
    }
    for (gone.items) |local| {
        r.sim.removeDisplay(r.displays.fetchRemove(local).?.value);
    }
    for (list) |d| {
        if (r.displays.get(d.id)) |id| {
            r.sim.setDisplayScale(id, d.scale);
        } else {
            try r.displays.put(r.gpa, d.id, r.sim.addDisplay(specOf(d)));
        }
    }
}

/// Makes the call on the Sim. False when it could not: the window is not one the replay has, or
/// the Sim refused.
fn apply(r: *Replayer, req: stream.Request) Allocator.Error!bool {
    const p = r.sim.platform();
    switch (req) {
        .open_window => |o| {
            var options = o.options;
            if (options.parent) |parent| options.parent = r.simWindow(parent) orelse return false;
            const opened = p.openWindow(options) catch return o.result == null;
            const local = o.result orelse return false;
            try r.windows.put(r.gpa, local.id, opened.id);
            try r.sim_windows.put(r.gpa, opened.id, local.id);
        },
        .set_clipboard_text => |text| p.setClipboardText(text) catch return false,
        inline else => |args, tag| {
            const Args = @TypeOf(args);
            const local: Window = if (Args == Window) args else args.window;
            const w = r.simWindow(local) orelse return false;
            switch (tag) {
                .close_window => p.closeWindow(w),
                .raise_window => p.raiseWindow(w),
                .set_title => p.setTitle(w, args.title),
                .set_window_size => p.setWindowSize(w, args.size),
                .set_window_position => p.setWindowPosition(w, args.at),
                .set_window_state => p.setWindowState(w, args.state),
                .show_window => p.showWindow(w, args.visible),
                .set_cursor => p.setCursor(w, args.cursor),
                .set_hints => p.setHints(w, args.hints),
                .set_material => p.setMaterial(w, args.material),
                .set_text_input => p.setTextInput(w, args.on),
                .set_ime_area => p.setImeArea(w, args.area),
                .drop_respond => p.dropRespond(w, args.response),
                else => unreachable, // handled above
            }
        },
    }
    return true;
}

/// The Sim's window for a stream's name, null if the replay never opened it.
fn simWindow(r: *const Replayer, local: Window) ?Window {
    return .{ .id = r.windows.get(local.id) orelse return null };
}

/// Drains the Sim and sets each event beside the one the stream polled in its place.
fn compare(r: *Replayer, report: *Report) Allocator.Error!void {
    var want: std.ArrayList(Event) = .empty;
    defer want.deinit(r.gpa);
    for (r.records) |record| switch (record.body) {
        .event => |e| if (skipped(e.payload)) {
            report.skipped += 1;
        } else try want.append(r.gpa, e),
        else => {},
    };
    report.expected = want.items.len;

    const p = r.sim.platform();
    while (p.poll()) |sim_event| {
        var got = sim_event;
        if (got.window) |w| got.window = .{ .id = r.sim_windows.get(w.id) orelse 0 };
        const i = report.actual;
        report.actual += 1;
        if (report.mismatch != null) continue;
        if (i >= want.items.len) {
            report.mismatch = .{ .index = i, .expected = null, .actual = try r.describe(got) };
        } else if (!try r.same(want.items[i], got)) {
            report.mismatch = .{ .index = i, .expected = try r.describe(want.items[i]), .actual = try r.describe(got) };
        }
    }
    if (report.mismatch == null and report.actual < want.items.len) {
        const i = report.actual;
        report.mismatch = .{ .index = i, .expected = try r.describe(want.items[i]), .actual = null };
    }
}

fn same(r: *Replayer, a: Event, b_in: Event) Allocator.Error!bool {
    var b = b_in;
    // A redacted key has no character to compare.
    if (a.payload == .key and b.payload == .key and a.payload.key.logical == .none) b.payload.key.logical = .none;
    var wa = try stream.Writer.init(r.gpa);
    defer wa.deinit();
    var wb = try stream.Writer.init(r.gpa);
    defer wb.deinit();
    try wa.write(.{ .t_ns = a.time_ns, .body = .{ .event = a } });
    try wb.write(.{ .t_ns = b.time_ns, .body = .{ .event = b } });
    return std.mem.eql(u8, wa.bytes.items, wb.bytes.items);
}

fn describe(r: *Replayer, e: Event) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(r.arena.allocator());
    stream.format(.{ .t_ns = e.time_ns, .body = .{ .event = e } }, &out.writer) catch return error.OutOfMemory;
    return out.written();
}
