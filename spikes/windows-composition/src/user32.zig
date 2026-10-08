//! The few user32/dwmapi/kernel32 calls the spike makes, declared with plain integer flags.
pub const HWND = *anyopaque;
pub const BOOL = i32;
pub const POINT = extern struct { x: i32, y: i32 };
pub const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
pub const WNDPROC = *const fn (HWND, u32, usize, isize) callconv(.winapi) isize;

pub const WNDCLASSEXW = extern struct {
    cbSize: u32 = @sizeOf(WNDCLASSEXW),
    style: u32 = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?*anyopaque,
    hIcon: ?*anyopaque = null,
    hCursor: ?*anyopaque = null,
    hbrBackground: ?*anyopaque = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: ?*anyopaque = null,
};

pub const MSG = extern struct {
    hwnd: ?HWND,
    message: u32,
    wParam: usize,
    lParam: isize,
    time: u32,
    pt: POINT,
    lPrivate: u32,
};

pub extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) u16;
pub extern "user32" fn CreateWindowExW(ex_style: u32, class: [*:0]const u16, name: [*:0]const u16, style: u32, x: i32, y: i32, w: i32, h: i32, parent: ?HWND, menu: ?*anyopaque, instance: ?*anyopaque, param: ?*anyopaque) callconv(.winapi) ?HWND;
pub extern "user32" fn DestroyWindow(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn DefWindowProcW(HWND, u32, usize, isize) callconv(.winapi) isize;
pub extern "user32" fn ShowWindow(HWND, i32) callconv(.winapi) BOOL;
pub extern "user32" fn SetLayeredWindowAttributes(HWND, color: u32, alpha: u8, flags: u32) callconv(.winapi) BOOL;
pub extern "user32" fn GetCursorPos(*POINT) callconv(.winapi) BOOL;
pub extern "user32" fn WindowFromPoint(POINT) callconv(.winapi) ?HWND;
pub extern "user32" fn GetAncestor(HWND, u32) callconv(.winapi) ?HWND;
pub extern "user32" fn GetClassNameW(HWND, [*]u16, i32) callconv(.winapi) i32;
pub extern "user32" fn GetSystemMetrics(i32) callconv(.winapi) i32;
pub extern "user32" fn GetWindowLongPtrW(HWND, i32) callconv(.winapi) isize;
pub extern "user32" fn GetWindowRect(HWND, *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn PeekMessageW(*MSG, ?HWND, u32, u32, u32) callconv(.winapi) BOOL;
pub extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) isize;
pub extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(.winapi) ?*anyopaque;
pub extern "dwmapi" fn DwmSetWindowAttribute(HWND, attribute: u32, value: *const anyopaque, size: u32) callconv(.winapi) i32;
pub extern "dwmapi" fn DwmFlush() callconv(.winapi) i32;

pub const WS_POPUP: u32 = 0x80000000;
pub const WS_EX_TOPMOST: u32 = 0x00000008;
pub const WS_EX_TRANSPARENT: u32 = 0x00000020;
pub const WS_EX_TOOLWINDOW: u32 = 0x00000080;
pub const WS_EX_LAYERED: u32 = 0x00080000;
pub const WS_EX_NOREDIRECTIONBITMAP: u32 = 0x00200000;
pub const WS_EX_NOACTIVATE: u32 = 0x08000000;
pub const LWA_ALPHA: u32 = 0x2;
pub const SW_SHOWNOACTIVATE: i32 = 4;
pub const WM_NCHITTEST: u32 = 0x0084;
pub const HTTRANSPARENT: isize = -1;
pub const GA_ROOT: u32 = 2;
pub const GWL_EXSTYLE: i32 = -20;
pub const PM_REMOVE: u32 = 0x1;

/// `DWMWA_USE_HOSTBACKDROPBRUSH`: the window may be painted with a host backdrop brush.
pub const DWMWA_USE_HOSTBACKDROPBRUSH: u32 = 17;
pub const DWMWA_SYSTEMBACKDROP_TYPE: u32 = 38;
pub const DWMSBT_NONE: u32 = 1;

/// Dispatch the thread's waiting messages: SDL's (which SDL turns into its events) and the
/// DispatcherQueue's, which is when composition commits what was set since.
pub fn pump() u32 {
    var msg: MSG = undefined;
    var n: u32 = 0;
    while (PeekMessageW(&msg, null, 0, 0, PM_REMOVE) != 0) {
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
        n += 1;
    }
    return n;
}
