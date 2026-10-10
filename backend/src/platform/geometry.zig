//! Where the app's window was left, and putting it back: by the window's *frame* as the OS keeps
//! it, not its content rect. An app that draws its own title bar changes how the two relate after
//! the window is made — a full-size content view on macOS, a client area that is the whole window
//! on Windows — and a content rect saved under one chrome and restored under the other walks the
//! window a titlebar further every launch. So the frame: AppKit's (the windowed frame, even while
//! in a fullscreen Space), Windows' placement (its restored rect and whether it is maximized), and
//! on Linux, where the window manager draws an ordinary frame, SDL's position and size, followed
//! while the window is neither maximized nor full screen.
//!
//! Restored as the window is about to show (`restore`), after the app has styled it; captured at
//! quit (`save`). Where it is kept is a `Store`: by default `window_geometry.zon` in the app's
//! preference folder (`fileStore`), as dvui keeps its own; an app that keeps it beside its own
//! state hands over its own (fizzy keeps it in `layout.zon`, beside the layout).
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const c = @import("backend").c;
const win32 = @import("win32");
const window_layout = @import("window_layout.zig");
const win32_titlebar = @import("win32_titlebar.zig");

/// A window's frame where it is neither maximized nor full screen, in the OS's own coordinates —
/// opaque to the app, round-tripped as saved: on macOS AppKit's (points, from the bottom left of
/// the main screen), on Windows the placement's (workspace pixels), elsewhere SDL's — and whether
/// it was left maximized or full screen.
pub const Geometry = struct {
    x: f64 = 0,
    y: f64 = 0,
    w: f64 = 0,
    h: f64 = 0,
    state: State = .normal,

    pub const State = enum { normal, maximized, fullscreen };

    fn valid(self: Geometry) bool {
        return self.w >= 1 and self.h >= 1;
    }
};

/// Where geometry is kept between runs.
pub const Store = struct {
    ctx: ?*anyopaque = null,
    load: *const fn (ctx: ?*anyopaque) ?Geometry,
    save: *const fn (ctx: ?*anyopaque, g: Geometry) void,
};

var store: ?Store = null;

/// Keep geometry in `s` from now on (`restore`, `save`).
pub fn setStore(s: Store) void {
    store = s;
}

// ── The default store: `window_geometry.zon` ───────────────────────────────────────────────────

var file_path_buf: [1024]u8 = undefined;
var file_path: ?[]const u8 = null;
var file_io: std.Io = undefined;

/// `window_geometry.zon` in `dir` (an app's preference folder).
pub fn fileStore(io: std.Io, dir: []const u8) Store {
    const sep = std.fs.path.sep_str;
    file_path = (if (std.mem.endsWith(u8, dir, sep))
        std.fmt.bufPrint(&file_path_buf, "{s}window_geometry.zon", .{dir})
    else
        std.fmt.bufPrint(&file_path_buf, "{s}" ++ sep ++ "window_geometry.zon", .{dir})) catch null;
    file_io = io;
    return .{ .load = fileLoad, .save = fileSave };
}

fn fileLoad(_: ?*anyopaque) ?Geometry {
    const path = file_path orelse return null;
    const gpa = std.heap.page_allocator;
    const data = std.Io.Dir.cwd().readFileAlloc(file_io, path, gpa, .limited(4096)) catch return null;
    defer gpa.free(data);
    const z = gpa.dupeZ(u8, data) catch return null;
    defer gpa.free(z);
    const g = std.zon.parse.fromSlice(Geometry, gpa, z, null, .{ .ignore_unknown_fields = true }) catch return null;
    return if (g.valid()) g else null;
}

fn fileSave(_: ?*anyopaque, g: Geometry) void {
    const path = file_path orelse return;
    var aw = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer aw.deinit();
    std.zon.stringify.serialize(g, .{}, &aw.writer) catch return;
    if (std.fs.path.dirname(path)) |dir| std.Io.Dir.createDirAbsolute(file_io, dir, .default_dir) catch {};
    std.Io.Dir.cwd().writeFile(file_io, .{ .sub_path = path, .data = aw.written() }) catch {};
}

// ── Restore and save ───────────────────────────────────────────────────────────────────────────

/// The state the window was restored into, for `window.show` to reveal it in.
var restored_state: Geometry.State = .normal;

/// Put `win` back where it was left, if it was, and the screen it was on is still there. Call
/// once the app has styled the window and before it shows.
pub fn restore(win: *dvui.Window) void {
    watchLinux(win);
    const s = store orelse return;
    const g = s.load(s.ctx) orelse return;
    if (!g.valid()) return;
    if (apply(win, g)) restored_state = g.state;
}

/// Whether the window was left maximized, for revealing it so (`window.show`).
pub fn restoredMaximized() bool {
    return restored_state == .maximized;
}

/// Keep where `win` is, for `restore` next run. Call at quit.
pub fn save(win: *dvui.Window) void {
    const s = store orelse return;
    const g = capture(win) orelse return;
    s.save(s.ctx, g);
}

// ── Per OS ─────────────────────────────────────────────────────────────────────────────────────

extern fn fizzy_macos_window_current_windowed_frame(cocoa_window: ?*anyopaque, out4: [*]f64) void;
extern fn fizzy_macos_window_set_frame(cocoa_window: ?*anyopaque, x: f64, y: f64, w: f64, h: f64) void;
extern fn fizzy_macos_copy_screen_frames(out: [*]f64, max: c_int) c_int;
extern fn fizzy_macos_window_in_fullscreen_space(cocoa_window: ?*anyopaque) c_int;

fn cocoaWindowOf(window: *c.SDL_Window) ?*anyopaque {
    return c.SDL_GetPointerProperty(c.SDL_GetWindowProperties(window), c.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, null);
}

/// Where `win` is now, as `Geometry`.
pub fn capture(win: *dvui.Window) ?Geometry {
    switch (builtin.os.tag) {
        .macos => {
            const cocoa = cocoaWindowOf(win.backend.impl.window) orelse return null;
            var out4: [4]f64 = .{0} ** 4;
            // The windowed frame — the one it had before a fullscreen Space, while it is in one.
            fizzy_macos_window_current_windowed_frame(cocoa, &out4);
            const g: Geometry = .{ .x = out4[0], .y = out4[1], .w = out4[2], .h = out4[3] };
            return if (g.valid()) g else null;
        },
        .windows => {
            const hwnd: win32.foundation.HWND = @ptrCast(win32_titlebar.getWin32Hwnd(win) orelse return null);
            var wp = std.mem.zeroes(win32.ui.windows_and_messaging.WINDOWPLACEMENT);
            wp.length = @sizeOf(win32.ui.windows_and_messaging.WINDOWPLACEMENT);
            if (win32.ui.windows_and_messaging.GetWindowPlacement(hwnd, &wp) == 0) return null;
            const r = wp.rcNormalPosition;
            const maximized = @as(u32, @bitCast(wp.showCmd)) == @as(u32, @bitCast(win32.ui.windows_and_messaging.SW_SHOWMAXIMIZED)) or
                wp.flags.RESTORETOMAXIMIZED != 0;
            const g: Geometry = .{
                .x = @floatFromInt(r.left),
                .y = @floatFromInt(r.top),
                .w = @floatFromInt(r.right - r.left),
                .h = @floatFromInt(r.bottom - r.top),
                .state = if (maximized) .maximized else .normal,
            };
            return if (g.valid()) g else null;
        },
        else => {
            var g = linux_normal;
            const flags = c.SDL_GetWindowFlags(win.backend.impl.window);
            if (flags & c.SDL_WINDOW_FULLSCREEN != 0) g.state = .fullscreen else if (flags & c.SDL_WINDOW_MAXIMIZED != 0) g.state = .maximized;
            return if (g.valid()) g else null;
        },
    }
}

/// Put `win` at `g`: false where it was not (no window, or nowhere on the screens there are now).
fn apply(win: *dvui.Window, g: Geometry) bool {
    switch (builtin.os.tag) {
        .macos => {
            const cocoa = cocoaWindowOf(win.backend.impl.window) orelse return false;
            if (!frameOnScreens(.{ .x = g.x, .y = g.y, .w = g.w, .h = g.h })) return false;
            fizzy_macos_window_set_frame(cocoa, g.x, g.y, g.w, g.h);
            return true;
        },
        .windows => {
            const hwnd: win32.foundation.HWND = @ptrCast(win32_titlebar.getWin32Hwnd(win) orelse return false);
            var rect: win32.foundation.RECT = .{
                .left = @intFromFloat(g.x),
                .top = @intFromFloat(g.y),
                .right = @intFromFloat(g.x + g.w),
                .bottom = @intFromFloat(g.y + g.h),
            };
            if (win32.graphics.gdi.MonitorFromRect(&rect, win32.graphics.gdi.MONITOR_DEFAULTTONULL) == null) return false;
            var wp = std.mem.zeroes(win32.ui.windows_and_messaging.WINDOWPLACEMENT);
            wp.length = @sizeOf(win32.ui.windows_and_messaging.WINDOWPLACEMENT);
            // Placed hidden, it shows where it was left when it is revealed (`window.show`).
            wp.showCmd = win32.ui.windows_and_messaging.SW_HIDE;
            wp.rcNormalPosition = rect;
            return win32.ui.windows_and_messaging.SetWindowPlacement(hwnd, &wp) != 0;
        },
        else => {
            const window = win.backend.impl.window;
            if (!rectOnDisplays(g)) return false;
            _ = c.SDL_SetWindowPosition(window, @intFromFloat(g.x), @intFromFloat(g.y));
            _ = c.SDL_SetWindowSize(window, @intFromFloat(g.w), @intFromFloat(g.h));
            linux_normal = g;
            linux_normal.state = .normal;
            return true;
        },
    }
}

/// macOS: whether `frame`'s title strip lands on a connected screen.
fn frameOnScreens(frame: window_layout.Rect) bool {
    var raw: [8 * 4]f64 = undefined;
    const n = fizzy_macos_copy_screen_frames(&raw, 8);
    if (n <= 0) return false;
    var screens: [8]window_layout.Rect = undefined;
    const count: usize = @intCast(n);
    for (0..count) |i| screens[i] = .{ .x = raw[i * 4 + 0], .y = raw[i * 4 + 1], .w = raw[i * 4 + 2], .h = raw[i * 4 + 3] };
    return window_layout.frameTitleReachable(frame, screens[0..count]);
}

/// Elsewhere: whether a point near `g`'s top middle is on a display (as dvui checks).
fn rectOnDisplays(g: Geometry) bool {
    var count: c_int = 0;
    const displays = c.SDL_GetDisplays(&count) orelse return false;
    defer c.SDL_free(displays);
    const cx: c_int = @intFromFloat(g.x + g.w / 2);
    const cy: c_int = @intFromFloat(g.y + 10);
    for (displays[0..@intCast(count)]) |id| {
        var b: c.SDL_Rect = undefined;
        if (!c.SDL_GetDisplayUsableBounds(id, &b)) continue;
        if (cx >= b.x and cx < b.x + b.w and cy >= b.y and cy < b.y + b.h) return true;
    }
    return false;
}

// Linux: the window's last frame while it was neither maximized nor full screen, followed from
// SDL's move and resize events — what a maximized window restores to.
var linux_normal: Geometry = .{};
var linux_window: ?*c.SDL_Window = null;
var linux_watching = false;

fn watchLinux(win: *dvui.Window) void {
    if (comptime builtin.os.tag == .macos or builtin.os.tag == .windows) return;
    linux_window = win.backend.impl.window;
    trackLinux();
    if (linux_watching) return;
    linux_watching = true;
    _ = c.SDL_AddEventWatch(linuxWatch, null);
}

fn linuxWatch(_: ?*anyopaque, event: ?*c.SDL_Event) callconv(.c) bool {
    const e = event orelse return true;
    if (e.type == c.SDL_EVENT_WINDOW_MOVED or e.type == c.SDL_EVENT_WINDOW_RESIZED) trackLinux();
    return true;
}

fn trackLinux() void {
    const window = linux_window orelse return;
    const flags = c.SDL_GetWindowFlags(window);
    if (flags & (c.SDL_WINDOW_MINIMIZED | c.SDL_WINDOW_MAXIMIZED | c.SDL_WINDOW_FULLSCREEN) != 0) return;
    var x: c_int = 0;
    var y: c_int = 0;
    var w: c_int = 0;
    var h: c_int = 0;
    if (!c.SDL_GetWindowPosition(window, &x, &y) or !c.SDL_GetWindowSize(window, &w, &h)) return;
    if (w < 1 or h < 1) return;
    linux_normal = .{ .x = @floatFromInt(x), .y = @floatFromInt(y), .w = @floatFromInt(w), .h = @floatFromInt(h) };
}
