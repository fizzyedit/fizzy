//! Recorder: wraps any `Platform` and writes what crosses it as a stream (`stream.zig`): the
//! events the app polls, the displays it sees, the clock it reads and the requests it makes. The
//! app cannot tell it is there; `platform()` is the one to hand it.
//!
//! The recorder keeps the stream in memory (`bytes`). It costs a clock read per request and per
//! event, which is why it is a wrapper to put on for a recording and take off after. Calls that
//! only ask (`windowSize`, `windowScale`, …) pass through unrecorded, and so does `wake`: a replay
//! answers its own questions and has no thread to wake.
//!
//! **Privacy.** A stream is a transcript of the session: typed text, keys, input-method
//! composition, the clipboard, window titles and dragged-in file paths and text would all be in
//! it. By default the recorder redacts them (`Options.redact`): text, composition, clipboard,
//! titles and what a drop carries (file paths, dragged text) become `*` of the
//! same byte length (so the lengths still leak), and a key's character (`Key.logical`) is dropped. What stays is what a
//! replay needs: which physical keys went down (so a redacted stream still shows *where* someone
//! typed, though not what the layout made of it), pointer moves, sizes, timing. Do not treat a
//! redacted stream as anonymous; treat an unredacted one (`redact = false`) as holding
//! everything the person typed and copied. The clipboard is read only when asked
//! (`Options.read_clipboard`), since reading it is a side effect on a real platform.
//!
//! **Size.** The stream stops at `Options.max_bytes`: past it nothing more is written, `full` is
//! set, and what is there is whole records and replays. TODO(seam): a long-running black box
//! wants the stream drained to a ring or a file as it goes (`sdk/tape`'s `ring`), a sink the
//! writer would hand finished records to, instead of stopping.
const std = @import("std");
const Platform = @import("Platform.zig");
const Window = @import("Window.zig");
const Display = @import("Display.zig");
const Event = @import("Event.zig");
const Clipboard = @import("Clipboard.zig");
const Drop = @import("Drop.zig");
const Ime = @import("Ime.zig");
const geometry = @import("geometry.zig");
const stream = @import("stream.zig");

const Allocator = std.mem.Allocator;

const Recorder = @This();

options: Options,
gpa: Allocator,
inner: Platform,
writer: stream.Writer,
ids: stream.Ids,
/// The inner clock when recording began; every time in the stream is since this.
base_ns: u64,
/// The displays as last written, in the stream's own naming, to tell a change from a repeat.
last_displays: []Display = &.{},
/// Set after a write fails: recording stops and the stream ends at the last whole record.
failed: bool = false,
/// Set when the stream reached `Options.max_bytes`: recording stopped, the stream ends at the
/// last whole record.
full: bool = false,

pub const Options = struct {
    /// Replace typed text, composition, clipboard text, titles, dropped file paths and dragged
    /// text with `*` of the same byte length (the lengths still leak), and drop keys'
    /// characters (see the doc above). On unless someone turns it off.
    redact: bool = true,
    /// Read the clipboard (`Platform.clipboardText`) when a clipboard event arrives and record
    /// it. Off: the event is recorded with empty text behind it and the platform is not asked.
    read_clipboard: bool = false,
    /// The stream stops growing past this many bytes.
    max_bytes: usize = 64 * 1024 * 1024,
};

pub fn init(gpa: Allocator, inner: Platform, options: Options) Allocator.Error!Recorder {
    return .{
        .options = options,
        .gpa = gpa,
        .inner = inner,
        .writer = try .init(gpa),
        .ids = .init(gpa),
        .base_ns = inner.now(),
    };
}

pub fn deinit(r: *Recorder) void {
    r.freeDisplays(r.last_displays);
    r.ids.deinit();
    r.writer.deinit();
    r.* = undefined;
}

/// The stream so far, header included. Valid until the next call on the platform.
pub fn bytes(r: *const Recorder) []const u8 {
    return r.writer.bytes.items;
}

/// The platform to give the app. Everything it does is done by the inner one.
pub fn platform(r: *Recorder) Platform {
    return .{
        .ctx = r,
        .vtable = if (r.inner.vtable.frame_timing != null) &vtable_timed else &vtable,
        .caps = r.inner.caps,
    };
}

/// Writes the displays if they differ from the last time, for a host that wants a change seen
/// without waiting for the app to ask. Called for it on `displays`, on the first window and on
/// every resize and move, which is when a display changes under a window.
pub fn snapshotDisplays(r: *Recorder) void {
    r.snapshotDisplaysAt(null);
}

/// A change an event announced happened when the event was stamped, which can be before the app
/// polled it; `at_ns` (inner clock) is that time, null for now.
fn snapshotDisplaysAt(r: *Recorder, at_ns: ?u64) void {
    const list = r.inner.displays(r.gpa) catch return;
    defer Platform.freeDisplays(r.gpa, list);
    r.noteDisplays(list, at_ns);
}

fn noteDisplays(r: *Recorder, list: []const Display, at_ns: ?u64) void {
    const named = r.renamed(list) orelse return;
    if (sameDisplays(named, r.last_displays)) return r.freeDisplays(named);
    r.freeDisplays(r.last_displays);
    r.last_displays = named;
    r.emit(.{ .t_ns = r.since(at_ns orelse r.inner.now()), .body = .{ .displays = named } });
}

fn renamed(r: *Recorder, list: []const Display) ?[]Display {
    const out = r.gpa.alloc(Display, list.len) catch return null;
    var made: usize = 0;
    for (list, out) |d, *o| {
        o.* = d;
        o.id = r.ids.display(d.id) catch {
            r.freeDisplays(out[0..made]);
            return null;
        };
        o.name = r.gpa.dupe(u8, d.name) catch {
            r.freeDisplays(out[0..made]);
            return null;
        };
        made += 1;
    }
    return out;
}

fn freeDisplays(r: *Recorder, list: []const Display) void {
    for (list) |d| r.gpa.free(d.name);
    r.gpa.free(list);
}

fn sameDisplays(a: []const Display, b: []const Display) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.id != y.id or x.primary != y.primary or x.scale != y.scale or x.refresh_hz != y.refresh_hz) return false;
        if (!std.mem.eql(u8, x.name, y.name)) return false;
        if (!std.meta.eql(x.bounds, y.bounds) or !std.meta.eql(x.usable, y.usable)) return false;
    }
    return true;
}

fn since(r: *const Recorder, ns: u64) u64 {
    return ns -| r.base_ns;
}

/// Reads the inner clock and writes `body` at that time.
fn write(r: *Recorder, body: stream.Body) void {
    if (r.failed or r.full) return;
    r.emit(.{ .t_ns = r.since(r.inner.now()), .body = body });
}

/// Appends a record unless recording has stopped; the one place a record is written.
fn emit(r: *Recorder, record: stream.Record) void {
    if (r.failed) return;
    if (r.writer.bytes.items.len >= r.options.max_bytes) {
        r.full = true;
        return;
    }
    r.writer.write(record) catch {
        r.failed = true;
    };
}

/// `text` as the stream should hold it: itself, or `*` for each byte when redacting. Free it
/// with `freeText`; null on out of memory, in which case nothing is recorded.
fn textFor(r: *Recorder, text: []const u8) ?[]const u8 {
    if (!r.options.redact) return text;
    const out = r.gpa.alloc(u8, text.len) catch return null;
    @memset(out, '*');
    return out;
}

fn freeText(r: *Recorder, original: []const u8, used: []const u8) void {
    if (used.ptr != original.ptr) r.gpa.free(used);
}

fn request(r: *Recorder, req: stream.Request) void {
    r.write(.{ .request = req });
}

fn name(r: *Recorder, w: Window) Window {
    return r.ids.window(w) catch .{ .id = 0 };
}

fn me(ctx: *anyopaque) *Recorder {
    return @ptrCast(@alignCast(ctx));
}

fn now(ctx: *anyopaque) u64 {
    const r = me(ctx);
    const t = r.inner.now();
    r.noteClock(r.since(t));
    return t;
}

/// A clock record only when the clock moved past the last record: a replay is already there.
fn noteClock(r: *Recorder, t_ns: u64) void {
    if (t_ns <= r.writer.last_ns) return;
    r.emit(.{ .t_ns = t_ns, .body = .clock });
}

fn poll(ctx: *anyopaque) ?Event {
    const r = me(ctx);
    const e = r.inner.poll() orelse return null;
    switch (e.payload) {
        .resized, .moved => r.snapshotDisplaysAt(e.time_ns),
        .clipboard => r.noteClipboard(),
        else => {},
    }
    const named = r.ids.event(e) catch return e;
    var rel = named;
    rel.time_ns = r.since(e.time_ns);
    switch (rel.payload) {
        .text => |t| {
            const used = r.textFor(t) orelse return e;
            defer r.freeText(t, used);
            rel.payload = .{ .text = used };
            r.write(.{ .event = rel });
        },
        .ime => |ime| {
            const used = r.textFor(ime.text) orelse return e;
            defer r.freeText(ime.text, used);
            var redacted = ime;
            redacted.text = used;
            rel.payload = .{ .ime = redacted };
            r.write(.{ .event = rel });
        },
        .key => |k| {
            if (r.options.redact) {
                var redacted = k;
                redacted.logical = .none;
                rel.payload = .{ .key = redacted };
            }
            r.write(.{ .event = rel });
        },
        .drop => |d| {
            if (!r.options.redact) {
                r.write(.{ .event = rel });
                return e;
            }
            switch (d.data) {
                .unsupported => r.write(.{ .event = rel }),
                .text => |t| {
                    const used = r.textFor(t) orelse return e;
                    defer r.freeText(t, used);
                    rel.payload = .{ .drop = .{ .phase = d.phase, .at = d.at, .data = .{ .text = used } } };
                    r.write(.{ .event = rel });
                },
                .files => |files| {
                    const stars = r.gpa.alloc([]u8, files.len) catch return e;
                    var made: usize = 0;
                    defer {
                        for (stars[0..made]) |f| r.gpa.free(f);
                        r.gpa.free(stars);
                    }
                    for (files) |f| {
                        stars[made] = r.gpa.alloc(u8, f.len) catch return e;
                        @memset(stars[made], '*');
                        made += 1;
                    }
                    rel.payload = .{ .drop = .{ .phase = d.phase, .at = d.at, .data = .{ .files = @ptrCast(stars) } } };
                    r.write(.{ .event = rel });
                },
            }
        },
        else => r.write(.{ .event = rel }),
    }
    return e;
}

/// The text behind a clipboard event, which the event does not carry: empty unless the recorder
/// was asked to read the clipboard.
fn noteClipboard(r: *Recorder) void {
    if (!r.options.read_clipboard) return r.write(.{ .clipboard_text = "" });
    const read = r.inner.clipboardText(r.gpa) catch return;
    const text = read orelse return;
    defer r.gpa.free(text);
    const used = r.textFor(text) orelse return;
    defer r.freeText(text, used);
    r.write(.{ .clipboard_text = used });
}

fn wait(ctx: *anyopaque, timeout_ns: ?u64) void {
    const r = me(ctx);
    r.inner.wait(timeout_ns);
    r.noteClock(r.since(r.inner.now()));
}

fn wake(ctx: *anyopaque) void {
    me(ctx).inner.wake();
}

fn frameTiming(ctx: *anyopaque, window: Window) ?Platform.FrameTiming {
    return me(ctx).inner.frameTiming(window);
}

fn openWindow(ctx: *anyopaque, options: Window.Options) Platform.Error!Window {
    const r = me(ctx);
    if (r.last_displays.len == 0) r.snapshotDisplays();
    var named = options;
    if (options.parent) |p| named.parent = r.name(p);
    const title = r.textFor(options.title) orelse return r.inner.openWindow(options);
    defer r.freeText(options.title, title);
    named.title = title;
    const opened = r.inner.openWindow(options) catch |err| {
        r.request(.{ .open_window = .{ .options = named, .result = null } });
        return err;
    };
    r.request(.{ .open_window = .{ .options = named, .result = r.name(opened) } });
    return opened;
}

fn closeWindow(ctx: *anyopaque, window: Window) void {
    const r = me(ctx);
    r.request(.{ .close_window = r.name(window) });
    r.inner.closeWindow(window);
}

fn setTitle(ctx: *anyopaque, window: Window, title: []const u8) void {
    const r = me(ctx);
    if (r.textFor(title)) |used| {
        defer r.freeText(title, used);
        r.request(.{ .set_title = .{ .window = r.name(window), .title = used } });
    }
    r.inner.setTitle(window, title);
}

fn windowSize(ctx: *anyopaque, window: Window) geometry.Size {
    return me(ctx).inner.windowSize(window);
}

fn setWindowSize(ctx: *anyopaque, window: Window, size: geometry.DesktopSize) void {
    const r = me(ctx);
    r.request(.{ .set_window_size = .{ .window = r.name(window), .size = size } });
    r.inner.setWindowSize(window, size);
}

fn windowScale(ctx: *anyopaque, window: Window) f32 {
    return me(ctx).inner.windowScale(window);
}

fn windowPosition(ctx: *anyopaque, window: Window) geometry.DesktopPoint {
    return me(ctx).inner.windowPosition(window);
}

fn setWindowPosition(ctx: *anyopaque, window: Window, at: geometry.DesktopPoint) void {
    const r = me(ctx);
    r.request(.{ .set_window_position = .{ .window = r.name(window), .at = at } });
    r.inner.setWindowPosition(window, at);
}

fn windowState(ctx: *anyopaque, window: Window) Window.State {
    return me(ctx).inner.windowState(window);
}

fn setWindowState(ctx: *anyopaque, window: Window, state: Window.State) void {
    const r = me(ctx);
    r.request(.{ .set_window_state = .{ .window = r.name(window), .state = state } });
    r.inner.setWindowState(window, state);
}

fn showWindow(ctx: *anyopaque, window: Window, visible: bool) void {
    const r = me(ctx);
    r.request(.{ .show_window = .{ .window = r.name(window), .visible = visible } });
    r.inner.showWindow(window, visible);
}

fn raiseWindow(ctx: *anyopaque, window: Window) void {
    const r = me(ctx);
    r.request(.{ .raise_window = r.name(window) });
    r.inner.raiseWindow(window);
}

fn setCursor(ctx: *anyopaque, window: Window, cursor: Window.Cursor) void {
    const r = me(ctx);
    r.request(.{ .set_cursor = .{ .window = r.name(window), .cursor = cursor } });
    r.inner.setCursor(window, cursor);
}

fn setHints(ctx: *anyopaque, window: Window, hints: Window.Hints) void {
    const r = me(ctx);
    r.request(.{ .set_hints = .{ .window = r.name(window), .hints = hints } });
    r.inner.setHints(window, hints);
}

fn setMaterial(ctx: *anyopaque, window: Window, material: Window.MaterialSpec) void {
    const r = me(ctx);
    r.request(.{ .set_material = .{ .window = r.name(window), .material = material } });
    r.inner.setMaterial(window, material);
}

fn windowMaterial(ctx: *anyopaque, window: Window) Window.MaterialKind {
    return me(ctx).inner.windowMaterial(window);
}

fn displayOf(ctx: *anyopaque, window: Window) ?u64 {
    return me(ctx).inner.displayOf(window);
}

fn displays(ctx: *anyopaque, allocator: Allocator) Platform.Error![]Display {
    const r = me(ctx);
    const list = try r.inner.displays(allocator);
    r.noteDisplays(list, null);
    return list;
}

fn setTextInput(ctx: *anyopaque, window: Window, on: bool) void {
    const r = me(ctx);
    r.request(.{ .set_text_input = .{ .window = r.name(window), .on = on } });
    r.inner.setTextInput(window, on);
}

fn setImeArea(ctx: *anyopaque, window: Window, area: Ime.Area) void {
    const r = me(ctx);
    r.request(.{ .set_ime_area = .{ .window = r.name(window), .area = area } });
    r.inner.setImeArea(window, area);
}

fn clipboardSerial(ctx: *anyopaque) Clipboard {
    return me(ctx).inner.clipboardSerial();
}

fn clipboardText(ctx: *anyopaque, allocator: Allocator) Platform.Error!?[]u8 {
    return me(ctx).inner.clipboardText(allocator);
}

fn setClipboardText(ctx: *anyopaque, text: []const u8) Platform.Error!void {
    const r = me(ctx);
    if (r.textFor(text)) |used| {
        defer r.freeText(text, used);
        r.request(.{ .set_clipboard_text = used });
    }
    return r.inner.setClipboardText(text);
}

fn dropRespond(ctx: *anyopaque, window: Window, response: Drop.Response) void {
    const r = me(ctx);
    r.request(.{ .drop_respond = .{ .window = r.name(window), .response = response } });
    r.inner.dropRespond(window, response);
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

/// The same, for an inner platform that can report frame timing.
const vtable_timed: Platform.VTable = blk: {
    var v = vtable;
    v.frame_timing = frameTiming;
    break :blk v;
};
