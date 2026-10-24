//! The OS's stacking of the app's top-level windows (Windows): which lie under another. Needs only
//! zigwin32, so a test can stack real windows. A no-op off Windows.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("win32");
const wm = win32.ui.windows_and_messaging;

/// Most top-level windows `markUnder` visits: a desktop has a few hundred at the very most, and
/// the walk runs every present, so a pathological or cyclic-looking list must not stall a frame.
const max_stack_walk = 2048;

/// Sets `under[i]` for each `lowers[i]` that lies under window `upper` among the top-level windows.
/// One walk down the stack from `upper`, for all of them, ending when each is found or after
/// `max_stack_walk` windows (the rest are then read as not under: the main window in front, the
/// rect test in `heldPoint` decides). Precondition: `lowers.len == under.len`, `under[i]` answering
/// `lowers[i]`.
pub fn markUnder(upper: *anyopaque, lowers: []const ?*anyopaque, under: []bool) void {
    std.debug.assert(lowers.len == under.len);
    @memset(under, false);
    if (builtin.target.os.tag != .windows) return;
    var left: usize = 0;
    for (lowers) |l| left += @intFromBool(l != null);
    var below = wm.GetWindow(@ptrCast(upper), wm.GW_HWNDNEXT);
    var steps: usize = 0;
    while (below) |h| : (below = wm.GetWindow(h, wm.GW_HWNDNEXT)) {
        if (left == 0 or steps >= max_stack_walk) break;
        steps += 1;
        for (lowers, 0..) |l, i| if (l == @as(?*anyopaque, @ptrCast(h)) and !under[i]) {
            under[i] = true;
            left -= 1;
        };
    }
}

const testing = std.testing;

const test_rect = struct {
    const x = 120;
    const y = 120;
    const size = 240;
};

fn stackProc(hwnd: win32.foundation.HWND, msg: u32, wp: win32.foundation.WPARAM, lp: win32.foundation.LPARAM) callconv(.winapi) win32.foundation.LRESULT {
    return wm.DefWindowProcW(hwnd, msg, wp, lp);
}

fn registerClass(name: [*:0]const u16, proc: wm.WNDPROC) !void {
    const class = wm.WNDCLASSEXW{
        .cbSize = @sizeOf(wm.WNDCLASSEXW),
        .style = .{},
        .lpfnWndProc = proc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = win32.system.library_loader.GetModuleHandleW(null),
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = name,
        .hIconSm = null,
    };
    if (wm.RegisterClassExW(&class) == 0) return error.RegisterClass;
}

/// A visible, never-activated, topmost popup over the test rect, on top of the others.
fn openWindow(class: [*:0]const u16) !win32.foundation.HWND {
    return wm.CreateWindowExW(
        .{ .TOPMOST = 1, .NOACTIVATE = 1, .TOOLWINDOW = 1 },
        class,
        null,
        .{ .POPUP = 1, .VISIBLE = 1 },
        test_rect.x,
        test_rect.y,
        test_rect.size,
        test_rect.size,
        null,
        null,
        win32.system.library_loader.GetModuleHandleW(null),
        null,
    ) orelse error.CreateWindow;
}

fn raise(h: win32.foundation.HWND) void {
    // HWND_TOP is the null handle.
    _ = wm.SetWindowPos(h, null, 0, 0, 0, 0, .{ .NOSIZE = 1, .NOMOVE = 1, .NOACTIVATE = 1 });
}

const test_class = std.unicode.utf8ToUtf16LeStringLiteral("FizzyStackTest");

test "markUnder reads the OS's stacking of real windows" {
    if (builtin.target.os.tag != .windows) return error.SkipZigTest;
    try registerClass(test_class, stackProc);
    defer _ = wm.UnregisterClassW(test_class, win32.system.library_loader.GetModuleHandleW(null));
    // Created in turn, so `a` is on top, `b` under it, `c` under that; `loose` is none of these
    // and a null slot is no window.
    const c = try openWindow(test_class);
    defer _ = wm.DestroyWindow(c);
    const b = try openWindow(test_class);
    defer _ = wm.DestroyWindow(b);
    const a = try openWindow(test_class);
    defer _ = wm.DestroyWindow(a);

    var under: [4]bool = undefined;
    markUnder(a, &.{ b, c, null, a }, &under);
    try testing.expectEqualSlices(bool, &.{ true, true, false, false }, &under);

    markUnder(c, &.{ a, b }, under[0..2]);
    try testing.expectEqualSlices(bool, &.{ false, false }, under[0..2]);

    // Click `b` to the front: now `a` is under it, and `c` still is.
    raise(b);
    markUnder(b, &.{ a, c }, under[0..2]);
    try testing.expectEqualSlices(bool, &.{ true, true }, under[0..2]);
    markUnder(a, &.{ b, c }, under[0..2]);
    try testing.expectEqualSlices(bool, &.{ false, true }, under[0..2]);
}
