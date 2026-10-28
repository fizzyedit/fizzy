//! The desktop's blur behind an X11 window: the `_KDE_NET_WM_BLUR_BEHIND_REGION` property, which
//! KWin (and compositors that follow it) reads as the part of the window to blur behind. GNOME's
//! and a bare X server's have no such thing, so there it is not offered. Nothing here is
//! per-frame work: the property is written when the region changes.
//!
//! libX11 is opened as SDL opens it, already loaded for the window, and what is called of it is
//! declared here by hand, so there is no new link dependency. Linux only; a no-op elsewhere.
const std = @import("std");
const builtin = @import("builtin");
const blur_region = @import("blur_region.zig");

const log = std.log.scoped(.x11_blur);

/// Where the blur goes: `frame` (window pixels, from its top left) with its corners rounded by
/// `radius`.
pub const Want = struct {
    frame: blur_region.Rect,
    radius: f32,
};

/// The property's value: a `x, y, width, height` row of `format 32` data per rectangle, which
/// Xlib takes as `long`s.
pub const payload_max = blur_region.max_rects * 4;

/// `want`'s rounded frame as the property's rows in `out`.
pub fn encode(want: Want, out: *[payload_max]c_long) []c_long {
    var rects: [blur_region.max_rects]blur_region.Rect = undefined;
    var n: usize = 0;
    for (blur_region.rounded(want.frame, want.radius, &rects)) |r| {
        out[n..][0..4].* = .{ r.x, r.y, r.w, r.h };
        n += 4;
    }
    return out[0..n];
}

/// Whether the window manager named `wm_name` (`_NET_WM_NAME` of its check window) is one that
/// reads the property.
pub fn readsBlurProperty(wm_name: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(wm_name, "kwin");
}

/// Whether the desktop blurs behind X11 windows at all, as `behind` would say, setting nothing.
pub fn offered(display: *anyopaque) bool {
    if (comptime builtin.target.os.tag != .linux) return false;
    const s = ready(display) orelse return false;
    return s.blurs;
}

/// Blur behind `window` (an X11 window of `display`, SDL's) as `want` says, or none: whether the
/// desktop blurs behind windows at all. Cheap to call every frame: the property is written only
/// when it changes.
pub fn behind(display: *anyopaque, window: c_ulong, want: ?Want) bool {
    if (comptime builtin.target.os.tag != .linux) return false;
    const s = ready(display) orelse return false;
    if (!s.blurs) return false;
    if (s.window == window) if (s.sent) |sent| if (std.meta.eql(sent, want)) return true;
    const d: *Display = @ptrCast(display);
    if (want) |w| {
        var rows: [payload_max]c_long = undefined;
        const data = encode(w, &rows);
        // An empty property would blur the whole window: nothing to ask for is none.
        if (data.len == 0) {
            _ = s.lib.XDeleteProperty(d, window, s.blur_atom);
        } else {
            _ = s.lib.XChangeProperty(d, window, s.blur_atom, xa_cardinal, 32, prop_mode_replace, @ptrCast(data.ptr), @intCast(data.len));
        }
    } else {
        _ = s.lib.XDeleteProperty(d, window, s.blur_atom);
    }
    _ = s.lib.XFlush(d);
    s.window = window;
    s.sent = want;
    return true;
}

// ---- libX11, by hand -------------------------------------------------------------------------

const Display = opaque {};

/// `XA_CARDINAL`, a predefined atom.
const xa_cardinal: c_ulong = 6;
const prop_mode_replace: c_int = 0;

/// What is called of libX11: each field is the symbol of its own name.
const Lib = struct {
    XInternAtom: *const fn (*Display, [*:0]const u8, c_int) callconv(.c) c_ulong,
    XChangeProperty: *const fn (*Display, c_ulong, c_ulong, c_ulong, c_int, c_int, [*]const u8, c_int) callconv(.c) c_int,
    XDeleteProperty: *const fn (*Display, c_ulong, c_ulong) callconv(.c) c_int,
    XFlush: *const fn (*Display) callconv(.c) c_int,
    XDefaultRootWindow: *const fn (*Display) callconv(.c) c_ulong,
    XGetWindowProperty: *const fn (*Display, c_ulong, c_ulong, c_long, c_long, c_int, c_ulong, *c_ulong, *c_int, *c_ulong, *c_ulong, *?[*]u8) callconv(.c) c_int,
    XFree: *const fn (?*anyopaque) callconv(.c) c_int,
};

fn load() ?Lib {
    if (builtin.is_test) return Probe.lib;
    // SDL's own copy, already loaded for the window: never a second one.
    const handle = std.c.dlopen("libX11.so.6", .{ .LAZY = true, .NOLOAD = true }) orelse return null;
    var lib: Lib = undefined;
    inline for (@typeInfo(Lib).@"struct".field_names) |name| {
        const sym = std.c.dlsym(handle, name) orelse return null;
        @field(lib, name) = @ptrCast(@alignCast(sym));
    }
    return lib;
}

// ---- state -----------------------------------------------------------------------------------

const State = struct {
    lib: Lib,
    blur_atom: c_ulong,
    /// The window manager reads the property.
    blurs: bool,
    /// The window the property was last written on, and what was written (null in it: none);
    /// null when nothing has been.
    window: c_ulong = 0,
    sent: ??Want = null,
};

var state: State = undefined;
var tried = false;
var bound = false;

fn ready(display: *anyopaque) ?*State {
    if (tried) return if (bound) &state else null;
    tried = true;
    const lib = load() orelse {
        log.info("no blur behind the window: libX11 is not loaded, or lacks a symbol", .{});
        return null;
    };
    const d: *Display = @ptrCast(display);
    var name_buf: [64]u8 = undefined;
    const wm = windowManagerName(lib, d, &name_buf);
    const blurs = readsBlurProperty(wm);
    log.info("blur behind the window: window manager \"{s}\" {s}", .{ wm, if (blurs) "blurs" else "does not blur" });
    state = .{
        .lib = lib,
        .blur_atom = lib.XInternAtom(d, "_KDE_NET_WM_BLUR_BEHIND_REGION", 0),
        .blurs = blurs,
    };
    bound = true;
    return &state;
}

/// `_NET_WM_NAME` of the window manager's check window (`_NET_SUPPORTING_WM_CHECK` on the root),
/// copied into `buf`; empty where there is none.
fn windowManagerName(lib: Lib, d: *Display, buf: []u8) []const u8 {
    const root = lib.XDefaultRootWindow(d);
    const check = firstProperty(lib, d, root, "_NET_SUPPORTING_WM_CHECK", 33, buf) orelse return "";
    if (check.len < @sizeOf(c_ulong)) return "";
    const check_window = std.mem.bytesToValue(c_ulong, check[0..@sizeOf(c_ulong)]);
    const utf8 = lib.XInternAtom(d, "UTF8_STRING", 0);
    return firstProperty(lib, d, check_window, "_NET_WM_NAME", utf8, buf) orelse "";
}

/// Up to `buf.len` bytes of `window`'s property `name` of type `req_type`, copied into `buf`.
fn firstProperty(lib: Lib, d: *Display, window: c_ulong, name: [*:0]const u8, req_type: c_ulong, buf: []u8) ?[]const u8 {
    var actual_type: c_ulong = 0;
    var format: c_int = 0;
    var items: c_ulong = 0;
    var after: c_ulong = 0;
    var data: ?[*]u8 = null;
    const atom = lib.XInternAtom(d, name, 0);
    if (lib.XGetWindowProperty(d, window, atom, 0, @intCast(buf.len / 4), 0, req_type, &actual_type, &format, &items, &after, &data) != 0) return null;
    const p = data orelse return null;
    defer _ = lib.XFree(p);
    if (actual_type != req_type or format == 0) return null;
    // Format 32 is `long`s in memory; 8 is bytes.
    const unit: usize = if (format == 32) @sizeOf(c_long) else @intCast(@divExact(format, 8));
    const n = @min(items * unit, buf.len);
    @memcpy(buf[0..n], p[0..n]);
    return buf[0..n];
}

test "the property is a row of four per rectangle" {
    var out: [payload_max]c_long = undefined;
    const square = encode(.{ .frame = .{ .x = 2, .y = 3, .w = 100, .h = 80 }, .radius = 0 }, &out);
    try std.testing.expectEqualSlices(c_long, &.{ 2, 3, 100, 80 }, square);

    const round = encode(.{ .frame = .{ .w = 300, .h = 200 }, .radius = 12 }, &out);
    try std.testing.expect(round.len > 4 and round.len % 4 == 0);
    // Rows run top to bottom and end at the frame's bottom.
    var y: c_long = 0;
    var i: usize = 0;
    while (i < round.len) : (i += 4) {
        try std.testing.expectEqual(y, round[i + 1]);
        y += round[i + 3];
    }
    try std.testing.expectEqual(@as(c_long, 200), y);
}

test "an empty frame encodes to nothing" {
    var out: [payload_max]c_long = undefined;
    try std.testing.expectEqual(@as(usize, 0), encode(.{ .frame = .{ .w = 0, .h = 50 }, .radius = 8 }, &out).len);
}

test "only KWin's window managers read the property" {
    try std.testing.expect(readsBlurProperty("KWin"));
    try std.testing.expect(readsBlurProperty("kwin_x11"));
    try std.testing.expect(!readsBlurProperty("GNOME Shell"));
    try std.testing.expect(!readsBlurProperty("Mutter"));
    try std.testing.expect(!readsBlurProperty(""));
}

// Test fixtures are written only by the serial tests in this file.
const Probe = struct {
    var lib: ?Lib = null;
    var unreadable = false;
    var check_window: c_ulong = 2;
    var empty_name: [1]u8 = .{0};

    fn intern(_: *Display, name: [*:0]const u8, _: c_int) callconv(.c) c_ulong {
        return if (std.mem.eql(u8, std.mem.span(name), "_NET_SUPPORTING_WM_CHECK")) 1 else 2;
    }

    fn root(_: *Display) callconv(.c) c_ulong {
        return 1;
    }

    fn property(_: *Display, _: c_ulong, atom: c_ulong, _: c_long, _: c_long, _: c_int, req_type: c_ulong, actual_type: *c_ulong, format: *c_int, items: *c_ulong, after: *c_ulong, data: *?[*]u8) callconv(.c) c_int {
        if (atom != 1 and unreadable) return 1;
        actual_type.* = req_type;
        format.* = if (atom == 1) 32 else 8;
        items.* = if (atom == 1) 1 else 0;
        after.* = 0;
        data.* = if (atom == 1) std.mem.asBytes(&check_window).ptr else &empty_name;
        return 0;
    }

    fn free(_: ?*anyopaque) callconv(.c) c_int {
        // Property storage belongs to this fixture.
        return 0;
    }

    fn change(_: *Display, _: c_ulong, _: c_ulong, _: c_ulong, _: c_int, _: c_int, _: [*]const u8, _: c_int) callconv(.c) c_int {
        @panic("a refused blur must not write a property");
    }

    fn delete(_: *Display, _: c_ulong, _: c_ulong) callconv(.c) c_int {
        @panic("a refused blur must not delete a property");
    }

    fn flush(_: *Display) callconv(.c) c_int {
        @panic("a refused blur must not flush");
    }

    const xlib: Lib = .{
        .XInternAtom = intern,
        .XChangeProperty = change,
        .XDeleteProperty = delete,
        .XFlush = flush,
        .XDefaultRootWindow = root,
        .XGetWindowProperty = property,
        .XFree = free,
    };
};

test "missing Xlib refuses blur and caches the failed probe" {
    if (builtin.target.os.tag != .linux) return error.SkipZigTest;
    defer {
        tried = false;
        bound = false;
        Probe.lib = null;
    }
    Probe.lib = null;
    var display: u8 = 0;
    try std.testing.expect(ready(&display) == null);
    // A later library cannot revive a probe that already failed.
    Probe.lib = Probe.xlib;
    try std.testing.expect(!offered(&display));
    try std.testing.expect(!behind(&display, 3, .{ .frame = .{ .w = 100, .h = 80 }, .radius = 0 }));
    try std.testing.expect(!behind(&display, 3, null));
}

test "empty or unreadable window manager names refuse blur without writing" {
    if (builtin.target.os.tag != .linux) return error.SkipZigTest;
    defer {
        tried = false;
        bound = false;
        Probe.lib = null;
        Probe.unreadable = false;
    }
    Probe.lib = Probe.xlib;
    var display: u8 = 0;
    for ([_]bool{ false, true }) |unreadable| {
        tried = false;
        bound = false;
        Probe.unreadable = unreadable;
        const s = ready(&display) orelse return error.TestUnexpectedResult;
        try std.testing.expect(!s.blurs);
        try std.testing.expect(!offered(&display));
        try std.testing.expect(!behind(&display, 3, .{ .frame = .{ .w = 100, .h = 80 }, .radius = 0 }));
        try std.testing.expect(!behind(&display, 3, null));
        try std.testing.expect(s.sent == null);
    }
}

test "behind refuses on its first call without a library or readable window manager name" {
    if (builtin.target.os.tag != .linux) return error.SkipZigTest;
    defer {
        tried = false;
        bound = false;
        Probe.lib = null;
        Probe.unreadable = false;
    }
    var display: u8 = 0;
    for ([_]?Lib{ null, Probe.xlib, Probe.xlib }, [_]bool{ false, false, true }) |lib, unreadable| {
        // Each case starts before the first capability probe.
        for ([_]?Want{ .{ .frame = .{ .w = 100, .h = 80 }, .radius = 0 }, null }) |want| {
            tried = false;
            bound = false;
            Probe.lib = lib;
            Probe.unreadable = unreadable;
            try std.testing.expect(!behind(&display, 3, want));
            try std.testing.expect(tried);
            try std.testing.expect(!offered(&display));
        }
    }
}
