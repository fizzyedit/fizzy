//! winsys: the windowing interface every platform implements and the app reads, std-only.
//!
//! Pure data and a vtable: no dvui, no SDL, nothing that allocates on its own, so it compiles for
//! every target including wasm32 and can be built into a test without a window. Event queueing
//! and normalisation is `EventQueue`; a Sim platform (4, branch `backend/winsys-sim`),
//! recording and replay (5), the conformance suite (6) and the SDL3 adapter (7) are built on this
//! and live beside it later; none is here.
//!
//! The decisions that apply to everything, one line each (the reason is at the type):
//!
//! - Window pixels (sizes, pointer and touch positions) are **physical**; where a window stands
//!   on the desktop is **points**; `scale` converts (`geometry.zig`).
//! - Time is **nanoseconds on `Platform.now`'s monotonic clock** (`Event.time_ns`).
//! - Events and strings **borrow** from the platform until the next `poll`; whatever a call
//!   *returns* names the allocator that owns it (`Platform`).
//! - Text offsets are **UTF-8 bytes** (`Ime`).
//! - A window handle is an id, **never reused** (`Window`).
//! - One exception to physical pixels, on purpose: a touch is a fraction of the window (`Event.Touch`).
//!
//! Deferred, each with the seam it will use:
//!
//! - Gamepads and raw mouse/keyboard input for games: new `Event.Payload` variants and a
//!   `Caps` flag; devices are named by an id, like `Touch.device`.
//! - Tablets and pens (pressure, tilt, eraser): a `Pointer` extension carrying pressure, with the
//!   pen as a `Pointer.device`; today a pen is a mouse (`touch_slots.zig`).
//! - Exclusive full screen, mode switching, variable refresh: `Window.State` stays "a full-screen
//!   window"; modes go in a separate `VTable` function, with `Display.refresh_hz` as the report.
//! - Frame pacing beyond asking when the next picture lands (`Platform.FrameTiming`):
//!   submitting at a time and learning when one was shown.
//! - Dragging *out* of the app (`Drag`, the counterpart of `Drop`), and clipboard and drop formats
//!   beyond text and files.
//! - Window creation's long tail (always-on-top, icons, min/max size, aspect, modal parents):
//!   `Window.Options` fields, added with the platform that needs one.
const std = @import("std");

pub const Platform = @import("Platform.zig");
pub const Window = @import("Window.zig");
pub const Display = @import("Display.zig");
pub const Event = @import("Event.zig");
pub const Clipboard = @import("Clipboard.zig");
pub const Drop = @import("Drop.zig");
pub const Ime = @import("Ime.zig");
pub const EventQueue = @import("EventQueue.zig");
pub const TouchSlots = @import("TouchSlots.zig");
pub const geometry = @import("geometry.zig");

/// A platform that does nothing, for tests of the interface itself: one window, no events.
const Stub = struct {
    clock: u64 = 0,
    title_set: bool = false,
    text_buf: [64]u8 = undefined,
    text_len: ?usize = null,
    next_id: u64 = 1,
    /// Scripted text events: `poll` hands out the next one copied into `event_buf`, so the slice
    /// it returns is overwritten by the next `poll`, the contract `Event` states.
    script: []const []const u8 = &.{},
    event_buf: [16]u8 = undefined,
    empty_name: bool = false,

    fn platform(self: *Stub) Platform {
        return .{ .ctx = self, .vtable = &vtable, .caps = .{} };
    }

    fn me(ctx: *anyopaque) *Stub {
        return @ptrCast(@alignCast(ctx));
    }

    fn now(ctx: *anyopaque) u64 {
        const s = me(ctx);
        s.clock += 1;
        return s.clock;
    }
    fn poll(ctx: *anyopaque) ?Event {
        const s = me(ctx);
        if (s.script.len == 0) return null;
        const text = s.script[0];
        s.script = s.script[1..];
        @memcpy(s.event_buf[0..text.len], text);
        return .{ .time_ns = 0, .window = .{ .id = 1 }, .payload = .{ .text = s.event_buf[0..text.len] } };
    }
    fn wait(_: *anyopaque, _: ?u64) void {}
    fn wake(_: *anyopaque) void {}
    fn openWindow(ctx: *anyopaque, _: Window.Options) Platform.Error!Window {
        const s = me(ctx);
        defer s.next_id += 1;
        return .{ .id = s.next_id };
    }
    fn closeWindow(_: *anyopaque, _: Window) void {}
    fn setTitle(ctx: *anyopaque, _: Window, _: []const u8) void {
        me(ctx).title_set = true;
    }
    fn windowSize(_: *anyopaque, _: Window) geometry.Size {
        return .{ .w = 640, .h = 480 };
    }
    fn setWindowSize(_: *anyopaque, _: Window, _: geometry.DesktopSize) void {}
    fn windowScale(_: *anyopaque, _: Window) f32 {
        return 2;
    }
    fn windowPosition(_: *anyopaque, _: Window) geometry.DesktopPoint {
        return .{};
    }
    fn setWindowPosition(_: *anyopaque, _: Window, _: geometry.DesktopPoint) void {}
    fn windowState(_: *anyopaque, _: Window) Window.State {
        return .normal;
    }
    fn setWindowState(_: *anyopaque, _: Window, _: Window.State) void {}
    fn showWindow(_: *anyopaque, _: Window, _: bool) void {}
    fn raiseWindow(_: *anyopaque, _: Window) void {}
    fn setCursor(_: *anyopaque, _: Window, _: Window.Cursor) void {}
    fn setHints(_: *anyopaque, _: Window, _: Window.Hints) void {}
    fn setMaterial(_: *anyopaque, _: Window, _: Window.MaterialSpec) void {}
    fn windowMaterial(_: *anyopaque, _: Window) Window.MaterialKind {
        return .none;
    }
    fn displayOf(_: *anyopaque, _: Window) ?u64 {
        return 7;
    }
    fn displays(ctx: *anyopaque, allocator: std.mem.Allocator) Platform.Error![]Display {
        const list = try allocator.alloc(Display, 1);
        errdefer allocator.free(list);
        list[0] = .{
            .id = 7,
            .name = try allocator.dupe(u8, if (me(ctx).empty_name) "" else "stub"),
            .bounds = .{ .w = 1280, .h = 800 },
            .usable = .{ .y = 24, .w = 1280, .h = 776 },
            .scale = 2,
            .primary = true,
        };
        return list;
    }
    fn setTextInput(_: *anyopaque, _: Window, _: bool) void {}
    fn setImeArea(_: *anyopaque, _: Window, _: Ime.Area) void {}
    fn clipboardSerial(_: *anyopaque) Clipboard {
        return .{ .serial = 1 };
    }
    fn clipboardText(ctx: *anyopaque, allocator: std.mem.Allocator) Platform.Error!?[]u8 {
        const s = me(ctx);
        return try allocator.dupe(u8, s.text_buf[0 .. s.text_len orelse return null]);
    }
    fn setClipboardText(ctx: *anyopaque, text: []const u8) Platform.Error!void {
        const s = me(ctx);
        @memcpy(s.text_buf[0..text.len], text);
        s.text_len = text.len;
    }
    fn dropRespond(_: *anyopaque, _: Window, _: Drop.Response) void {}

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
};

/// Referenced by the wasm32 object build (`build.zig`), which would otherwise analyse nothing:
/// Zig skips what is never used. Every vtable function of the stub is reached through it.
pub export fn winsys_analysed() usize {
    var stub: Stub = .{};
    const p = stub.platform();
    return @sizeOf(Event) + p.windowSize(.{ .id = 1 }).w + @intFromPtr(&Stub.vtable);
}

test "calls reach the platform through the vtable" {
    var stub: Stub = .{};
    const p = stub.platform();

    const w = try p.openWindow(.{ .title = "t" });
    try std.testing.expectEqual(@as(u64, 1), w.id);
    try std.testing.expectEqual(geometry.Size{ .w = 640, .h = 480 }, p.windowSize(w));
    try std.testing.expectEqual(@as(f32, 2), p.windowScale(w));

    p.setTitle(w, "x");
    try std.testing.expect(stub.title_set);

    const t0 = p.now();
    try std.testing.expect(p.now() > t0);
    try std.testing.expect(p.poll() == null);
}

test "an optional function the platform lacks answers null" {
    var stub: Stub = .{};
    const p = stub.platform();
    try std.testing.expect(p.frameTiming(.{ .id = 1 }) == null);
}

test "displays and clipboard text are owned by the caller's allocator" {
    var stub: Stub = .{};
    const p = stub.platform();
    const a = std.testing.allocator;

    const list = try p.displays(a);
    defer Platform.freeDisplays(a, list);
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expect(list[0].primary);
    try std.testing.expectEqual(p.displayOf(.{ .id = 1 }), list[0].id);

    try std.testing.expect(try p.clipboardText(a) == null);
    var scratch = "héllo".*;
    try p.setClipboardText(&scratch);
    scratch = "XXXXXX".*;
    const got = (try p.clipboardText(a)).?;
    defer a.free(got);
    try std.testing.expectEqualStrings("héllo", got);
}

test "an event's text is valid only until the next poll" {
    var stub: Stub = .{ .script = &.{ "a", "b" } };
    const p = stub.platform();
    const first = p.poll().?.payload.text;
    try std.testing.expectEqualStrings("a", first);
    const second = p.poll().?.payload.text;
    try std.testing.expectEqualStrings("b", second);
    // The first slice now shows the second event: a consumer that kept it saw it change.
    try std.testing.expectEqualStrings("b", first);
    try std.testing.expect(p.poll() == null);
}

test "a window id is never reused after close" {
    var stub: Stub = .{};
    const p = stub.platform();
    const a = try p.openWindow(.{});
    p.closeWindow(a);
    const b = try p.openWindow(.{});
    try std.testing.expect(a.id != b.id);
    try std.testing.expect(a.id != 0 and b.id != 0);
}

test "freeDisplays frees an empty name as well as a named one" {
    var stub: Stub = .{ .empty_name = true };
    const p = stub.platform();
    const list = try p.displays(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), list[0].name.len);
    // The testing allocator fails the test on a leak or a bad free.
    Platform.freeDisplays(std.testing.allocator, list);
}

test "a material spec defaults to the plain, fully covering one" {
    const spec: Window.MaterialSpec = .{};
    try std.testing.expectEqual(Window.MaterialKind.none, spec.kind);
    try std.testing.expectEqual(@as(f32, 1), spec.opacity);
    const opts: Window.Options = .{};
    try std.testing.expectEqual(spec, opts.material);
}

test "a key carries both where it is and what it types" {
    const k: Event.Key = .{
        .physical = .k,
        .logical = .{ .char = 0x043A }, // Cyrillic ka on that key
        .action = .down,
        .mods = .{},
    };
    try std.testing.expect(k.logical.char != @backingInt(k.physical));
}

test "every modifier is one distinct bit" {
    const Mods = Event.Mods;
    var seen: u8 = 0;
    inline for (comptime std.meta.fieldNames(Mods)) |name| {
        if (name[0] == '_') continue;
        var m: Mods = .{};
        @field(m, name) = true;
        const bit: u8 = @bitCast(m);
        try std.testing.expect(bit != 0 and seen & bit == 0);
        seen |= bit;
    }
}

test {
    std.testing.refAllDecls(@This());
}
