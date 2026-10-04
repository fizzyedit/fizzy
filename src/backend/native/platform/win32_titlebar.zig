//! Windows chrome: the DWM Acrylic backdrop behind a client area that is the whole window, and
//! the app drawing its own title bar in it — the app says each frame where the drag strip, its
//! interactive widgets and its caption buttons are (`titlebar`), and the window's subclass answers
//! `WM_NCHITTEST` from them, so the OS drags, snaps and resizes as it would with its own frame.
//! Everything here is a no-op off Windows.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const c = @import("backend").c;
const win32 = @import("win32");
const titlebar = @import("titlebar.zig");
const TitleBarButton = titlebar.TitleBarButton;

// Windows 11 (Build 22621+): System backdrop and extended frame for title bar drawing.
const DWMWA_SYSTEMBACKDROP_TYPE: u32 = 38; // Windows 11 SDK
const DWMSBT_MAINWINDOW: u32 = 2; // Mica
const DWMSBT_TRANSIENTWINDOW: u32 = 3; // Acrylic (frosted glass) — more visible blur than Mica
/// Which of the backdrop's two tints DWM draws, and the frame's: the app's theme, not the system's.
const DWMWA_USE_IMMERSIVE_DARK_MODE: u32 = 20;
/// Windows 11 rounds a framed window's corners by default; asked for, so a frame the app draws
/// itself does not depend on that default.
const DWMWA_WINDOW_CORNER_PREFERENCE: u32 = 33;
const DWMWCP_ROUND: u32 = 2;

/// Apply the chrome to `win` (see `window.setStyle`): idempotent, cheap to call every frame.
pub fn applyChrome(win: *dvui.Window) void {
    if (builtin.os.tag != .windows) return;
        const hwnd = getWin32Hwnd(win) orelse return;
        const hwnd_h = @as(win32.foundation.HWND, @ptrCast(hwnd));
        const WS_SYSMENU: isize = 0x00080000;
        const cur_style = win32.ui.windows_and_messaging.GetWindowLongPtrW(hwnd_h, win32.ui.windows_and_messaging.GWL_STYLE);
        const zoomed = win32.ui.windows_and_messaging.IsZoomed(hwnd_h) != 0;
        const first = win32_styled_hwnd != hwnd;
        // Nothing SDL changes back: nothing to do.
        if (!first and cur_style & WS_SYSMENU == 0 and zoomed == win32_styled_zoomed) return;
        win32_styled_hwnd = hwnd;
        win32_styled_zoomed = zoomed;

        if (first) {
            // Once per window: the subclass that keeps the frame extended (re-applied in
            // WM_ACTIVATE, as DWM requires for the backdrop to show) and draws the custom
            // non-client area, rounded corners, and the black class brush.
            _ = win32.ui.shell.SetWindowSubclass(hwnd_h, win32MicaSubclassProc, win32_mica_subclass_id, 0);

            _ = win32.graphics.dwm.DwmSetWindowAttribute(
                hwnd_h,
                @as(win32.graphics.dwm.DWMWINDOWATTRIBUTE, @enumFromInt(DWMWA_WINDOW_CORNER_PREFERENCE)),
                &DWMWCP_ROUND,
                @sizeOf(u32),
            );

            // Per MSDN: for backdrop to render, the client area background must be transparent or a black brush.
            // BLACK_BRUSH (4) lets DWM draw the backdrop material; a null brush can leave the area undefined.
            const black_brush = win32.graphics.gdi.GetStockObject(win32.graphics.gdi.GET_STOCK_OBJECT_FLAGS.BLACK_BRUSH);
            _ = win32.ui.windows_and_messaging.SetClassLongPtrW(
                hwnd_h,
                win32.ui.windows_and_messaging.GCLP_HBRBACKGROUND,
                @as(isize, @bitCast(@intFromPtr(black_brush))),
            );
            // Do not set WS_EX_LAYERED here: a layered main window is a common cause of broken mouse input on
            // native modal dialogs (SDL_ShowOpenFileDialog / tinyfd) when that window is the dialog owner.
        }

        // Windows 11: Apply Acrylic (frosted glass) backdrop so title bar and extended frame show blur. Requires Build 22621+.
        // DWMSBT_TRANSIENTWINDOW = Acrylic is more visible than Mica; use MAINWINDOW for subtler Mica.
        const backdrop_type: u32 = DWMSBT_TRANSIENTWINDOW;
        _ = win32.graphics.dwm.DwmSetWindowAttribute(
            hwnd_h,
            @as(win32.graphics.dwm.DWMWINDOWATTRIBUTE, @enumFromInt(DWMWA_SYSTEMBACKDROP_TYPE)),
            &backdrop_type,
            @sizeOf(u32),
        );

        // Hide the OS-drawn caption buttons (min/max/close) so they don't show through our custom-drawn ones.
        // Returning 0 from WM_NCCALCSIZE removes the non-client area, but on Win11 DWM still composites the
        // system caption buttons whenever WS_SYSMENU is present. Strip just WS_SYSMENU — the min/max box
        // styles only render buttons when WS_SYSMENU is also set, but they're still required for Aero Snap
        // (drag-to-top maximize, drag-to-edge half-snap), so we keep them.
        if (cur_style & WS_SYSMENU != 0) {
            _ = win32.ui.windows_and_messaging.SetWindowLongPtrW(hwnd_h, win32.ui.windows_and_messaging.GWL_STYLE, cur_style & ~WS_SYSMENU);
        }

        // Extend the DWM frame (Acrylic) into the entire client area so the backdrop material shows there.
        _ = win32.graphics.dwm.DwmExtendFrameIntoClientArea(hwnd_h, &win32_mica_margins);

        // Force WM_NCCALCSIZE so the client area extends over the title bar immediately (not only after maximize).
        const SWP_NOMOVE: u32 = 0x0002;
        const SWP_NOSIZE: u32 = 0x0001;
        const SWP_FRAMECHANGED: u32 = 0x0020;
        const swp_flags = @as(win32.ui.windows_and_messaging.SET_WINDOW_POS_FLAGS, @bitCast(SWP_NOMOVE | SWP_NOSIZE | SWP_FRAMECHANGED));
        _ = win32.ui.windows_and_messaging.SetWindowPos(hwnd_h, null, 0, 0, 0, 0, swp_flags);
}

/// The backdrop's tint follows the app's theme: DWM draws Acrylic's dark or light variant by this
/// window attribute, which otherwise follows the system's light or dark mode.
pub fn setDarkMode(win: *dvui.Window, dark: bool) void {
    if (builtin.os.tag != .windows) return;
    const hwnd = getWin32Hwnd(win) orelse return;
    const value: u32 = @intFromBool(dark);
    _ = win32.graphics.dwm.DwmSetWindowAttribute(
        @as(win32.foundation.HWND, @ptrCast(hwnd)),
        @as(win32.graphics.dwm.DWMWINDOWATTRIBUTE, @enumFromInt(DWMWA_USE_IMMERSIVE_DARK_MODE)),
        &value,
        @sizeOf(u32),
    );
}

/// No caption or border tint: the app draws its own title bar in the client area.
pub fn clearCaptionColors(win: *dvui.Window) void {
    if (builtin.os.tag != .windows) return;
        const hwnd = getWin32Hwnd(win) orelse return;
        const hwnd_h = @as(win32.foundation.HWND, @ptrCast(hwnd));


        // No caption/border tint; we draw our own title bar in the extended client area (see WM_NCCALCSIZE in subclass).
        const color_none: u32 = win32.graphics.dwm.DWMWA_COLOR_NONE;
        _ = win32.graphics.dwm.DwmSetWindowAttribute(hwnd_h, win32.graphics.dwm.DWMWA_CAPTION_COLOR, &color_none, @sizeOf(u32));
        _ = win32.graphics.dwm.DwmSetWindowAttribute(hwnd_h, win32.graphics.dwm.DWMWA_BORDER_COLOR, &color_none, @sizeOf(u32));
}

/// The window whose one-time Windows chrome is in place (`setWindowStyle`), and whether it was
/// maximized when its chrome was last applied: a maximize or restore re-applies the frame.
var win32_styled_hwnd: ?*anyopaque = null;
var win32_styled_zoomed: bool = false;

/// One-shot WM_NCMOUSELEAVE tracking is armed (`armNcMouseLeaveTracking`).
var hover_tracking: bool = false;

// Performs the window button action (minimize, maximize/restore, close). The subclass calls this directly
// on WM_NCLBUTTONDOWN for our registered button rects. Public so callers without a mouse path (e.g. a
// right-click system menu or keyboard shortcut) can still trigger it. Windows only.
fn performWindowButtonHwnd(hwnd_h: win32.foundation.HWND, button: TitleBarButton) void {
    // We strip WS_SYSMENU from the window style to hide the OS-drawn caption buttons,
    // so WM_SYSCOMMAND(SC_MINIMIZE/MAXIMIZE/CLOSE) is no longer reliable. Drive the actions
    // directly via ShowWindow / WM_CLOSE instead.
    const WM_CLOSE: u32 = 0x0010;
    switch (button) {
        .minimize => _ = win32.ui.windows_and_messaging.ShowWindow(hwnd_h, win32.ui.windows_and_messaging.SW_MINIMIZE),
        .maximize => {
            const cmd = if (win32.ui.windows_and_messaging.IsZoomed(hwnd_h) != 0)
                win32.ui.windows_and_messaging.SW_RESTORE
            else
                win32.ui.windows_and_messaging.SW_MAXIMIZE;
            _ = win32.ui.windows_and_messaging.ShowWindow(hwnd_h, cmd);
        },
        .close => _ = win32.ui.windows_and_messaging.PostMessageW(hwnd_h, WM_CLOSE, 0, 0),
    }
}

pub fn getWin32Hwnd(win: *dvui.Window) ?*anyopaque {
    const raw = c.SDL_GetPointerProperty(
        c.SDL_GetWindowProperties(win.backend.impl.window),
        c.SDL_PROP_WINDOW_WIN32_HWND_POINTER,
        null,
    );
    return if (raw != null) @ptrCast(raw) else null;
}

// Full-window Mica margins for DwmExtendFrameIntoClientArea (-1 = "sheet of glass").
const win32_mica_margins = win32.ui.controls.MARGINS{
    .cxLeftWidth = -1,
    .cxRightWidth = -1,
    .cyTopHeight = -1,
    .cyBottomHeight = -1,
};

const win32_mica_subclass_id: usize = 0x50584931; // "PXI1"

// Extend client area into title bar: return 0 from WM_NCCALCSIZE when wParam TRUE (MSDN).
const WM_NCCALCSIZE: u32 = 0x0083;
const WM_NCHITTEST: u32 = 0x0084;
const HTCAPTION: i32 = 2;
const HTLEFT: i32 = 10;
const HTRIGHT: i32 = 11;
const HTTOP: i32 = 12;
const HTTOPLEFT: i32 = 13;
const HTTOPRIGHT: i32 = 14;
const HTBOTTOM: i32 = 15;
const HTBOTTOMLEFT: i32 = 16;
const HTBOTTOMRIGHT: i32 = 17;
const HTMINBUTTON: i32 = 8;
const HTMAXBUTTON: i32 = 9;
const HTCLOSE: i32 = 20;
const SM_CXSIZEFRAME: u32 = 32;
const SM_CYSIZEFRAME: u32 = 33;
const WM_NCLBUTTONDOWN: u32 = 0x00A1;
const WM_NCMOUSEMOVE: u32 = 0x00A0;
const WM_NCMOUSELEAVE: u32 = 0x02A2;

fn requestRepaint(hWnd: ?win32.foundation.HWND) void {
    _ = win32.graphics.gdi.InvalidateRect(hWnd, null, 0);
}

fn setHoveredButton(hWnd: ?win32.foundation.HWND, new_hover: ?TitleBarButton) void {
    if (titlebar.setHovered(new_hover)) requestRepaint(hWnd);
}

/// Ask Windows to deliver WM_NCMOUSELEAVE once the cursor exits the non-client area. Must be re-armed
/// on each WM_NCMOUSEMOVE after a leave, since TrackMouseEvent is one-shot.
fn armNcMouseLeaveTracking(hWnd: ?win32.foundation.HWND) void {
    if (hover_tracking) return;
    var tme = win32.ui.input.keyboard_and_mouse.TRACKMOUSEEVENT{
        .cbSize = @sizeOf(win32.ui.input.keyboard_and_mouse.TRACKMOUSEEVENT),
        .dwFlags = .{ .LEAVE = 1, .NONCLIENT = 1 },
        .hwndTrack = hWnd,
        .dwHoverTime = 0,
    };
    if (win32.ui.input.keyboard_and_mouse.TrackMouseEvent(&tme) != 0) {
        hover_tracking = true;
    }
}

fn win32MicaSubclassProc(
    hWnd: ?win32.foundation.HWND,
    uMsg: u32,
    wParam: win32.foundation.WPARAM,
    lParam: win32.foundation.LPARAM,
    uIdSubclass: usize,
    dwRefData: usize,
) callconv(.winapi) win32.foundation.LRESULT {
    _ = uIdSubclass;
    _ = dwRefData;
    // DWM requires the frame extension to be applied in WM_ACTIVATE (and when composition changes)
    // for the backdrop to show correctly instead of staying opaque.
    // Re-apply backdrop type on activate/deactivate so the window stays acrylic when unfocused
    // instead of dimming to opaque (default DWM behavior for inactive windows).
    if (uMsg == win32.ui.windows_and_messaging.WM_ACTIVATE or
        uMsg == win32.ui.windows_and_messaging.WM_DWMCOMPOSITIONCHANGED)
    {
        const backdrop_type: u32 = DWMSBT_TRANSIENTWINDOW;
        _ = win32.graphics.dwm.DwmSetWindowAttribute(
            hWnd,
            @as(win32.graphics.dwm.DWMWINDOWATTRIBUTE, @enumFromInt(DWMWA_SYSTEMBACKDROP_TYPE)),
            &backdrop_type,
            @sizeOf(u32),
        );
        _ = win32.graphics.dwm.DwmExtendFrameIntoClientArea(hWnd, &win32_mica_margins);
    }
    // Extend client area into the title bar so the app can draw there; we keep OS min/max/close via hit-test.
    // When maximized, constrain the client rect to the monitor work area so the window doesn't extend past
    // the screen edge (the 7–8 px overflow that happens when returning 0 with borderless-style handling).
    if (uMsg == WM_NCCALCSIZE and wParam != 0) {
        const params = @as(*win32.ui.windows_and_messaging.NCCALCSIZE_PARAMS, @ptrFromInt(@as(usize, @intCast(lParam))));
        if (win32.ui.windows_and_messaging.IsZoomed(hWnd) != 0) {
            const hmon = win32.graphics.gdi.MonitorFromWindow(hWnd, win32.graphics.gdi.MONITOR_DEFAULTTONEAREST);
            var mi: win32.graphics.gdi.MONITORINFO = undefined;
            mi.cbSize = @sizeOf(win32.graphics.gdi.MONITORINFO);
            if (win32.graphics.gdi.GetMonitorInfoW(hmon, &mi) != 0) {
                params.rgrc[0] = mi.rcWork;
            }
        }
        return 0; // Client area = rgrc[0] (full window when not maximized; work area when maximized).
    }
    if (uMsg == WM_NCHITTEST) {
        const def = win32.ui.shell.DefSubclassProc(hWnd, uMsg, wParam, lParam);
        // lParam = (y << 16) | x in screen coordinates (signed 16-bit each).
        const lp = @as(isize, lParam);
        const screen_x = @as(i32, @as(i16, @truncate(lp)));
        const screen_y = @as(i32, @as(i16, @truncate(lp >> 16)));
        var rect: win32.foundation.RECT = undefined;
        if (win32.ui.windows_and_messaging.GetWindowRect(hWnd, &rect) == 0) return def;
        if (screen_x < rect.left or screen_x >= rect.right or screen_y < rect.top or screen_y >= rect.bottom) return def;

        // Client origin == window origin because WM_NCCALCSIZE returned 0.
        const client_x = screen_x - rect.left;
        const client_y = screen_y - rect.top;
        const width = rect.right - rect.left;
        const height = rect.bottom - rect.top;

        // Resize edges/corners only while not maximized.
        const frame: titlebar.Frame = if (win32.ui.windows_and_messaging.IsZoomed(hWnd) != 0) .{} else .{
            .w = @max(win32.ui.windows_and_messaging.GetSystemMetrics(@as(win32.ui.windows_and_messaging.SYSTEM_METRICS_INDEX, @enumFromInt(SM_CXSIZEFRAME))), 4),
            .h = @max(win32.ui.windows_and_messaging.GetSystemMetrics(@as(win32.ui.windows_and_messaging.SYSTEM_METRICS_INDEX, @enumFromInt(SM_CYSIZEFRAME))), 4),
        };
        // The caption-button codes are also what make the Win11 snap-layouts flyout appear on
        // the maximize button.
        const ht: i32 = switch (titlebar.hitTest(client_x, client_y, width, height, frame)) {
            .client => 1, // HTCLIENT
            .caption => HTCAPTION,
            .button => |b| switch (b) {
                .close => HTCLOSE,
                .maximize => HTMAXBUTTON,
                .minimize => HTMINBUTTON,
            },
            .resize => |e| switch (e) {
                .top_left => HTTOPLEFT,
                .top => HTTOP,
                .top_right => HTTOPRIGHT,
                .right => HTRIGHT,
                .bottom_right => HTBOTTOMRIGHT,
                .bottom => HTBOTTOM,
                .bottom_left => HTBOTTOMLEFT,
                .left => HTLEFT,
            },
        };
        return @as(win32.foundation.LRESULT, @intCast(ht));
    }

    // Hover tracking for custom-drawn caption buttons. Windows sends WM_NCMOUSEMOVE with wParam = HT code
    // when the cursor is over HTMINBUTTON/HTMAXBUTTON/HTCLOSE because we returned those from WM_NCHITTEST.
    if (uMsg == WM_NCMOUSEMOVE) {
        armNcMouseLeaveTracking(hWnd);
        const hover: ?TitleBarButton = switch (@as(i32, @intCast(wParam))) {
            HTCLOSE => .close,
            HTMAXBUTTON => .maximize,
            HTMINBUTTON => .minimize,
            else => null,
        };
        setHoveredButton(hWnd, hover);
    }
    if (uMsg == WM_NCMOUSELEAVE) {
        hover_tracking = false;
        setHoveredButton(hWnd, null);
    }

    // Click on a custom caption button: perform the action ourselves (don't let DefWindowProc try to
    // drive its own non-existent button UI). Consume the message so no spurious system menu appears.
    if (uMsg == WM_NCLBUTTONDOWN) {
        const action: ?TitleBarButton = switch (@as(i32, @intCast(wParam))) {
            HTCLOSE => .close,
            HTMAXBUTTON => .maximize,
            HTMINBUTTON => .minimize,
            else => null,
        };
        if (action) |btn| {
            if (hWnd) |h| performWindowButtonHwnd(h, btn);
            return 0;
        }
    }

    return win32.ui.shell.DefSubclassProc(hWnd, uMsg, wParam, lParam);
}

// ---- a float popped out of the main window ------------------------------------------------
//
// fizzy's viewports (`docs/POPOUT_WINDOWS_PLAN.md`): a float out of the main window, in a borderless
// window of its own. SDL styles a borderless window with a caption it takes away again
// (`WM_NCCALCSIZE`), so DWM still treats it as a framed window — it rounds its corners and draws
// its shadow — and the frame extended over it shows the backdrop behind its transparent pixels, as
// it does the main window's.

const DWMWCP_DONOTROUND: u32 = 1;
const DWMWCP_ROUNDSMALL: u32 = 3;
const viewport_subclass_id: usize = 0x50584932; // "PXI2"

/// Dress a popped-out float's window, which is exactly the float's glass: Acrylic behind it, as
/// behind the main window, in the app's light or dark (`dark`); its corners rounded by DWM as near
/// the glass's `radius_pt` (points) as DWM rounds — 8 points as designed, which is DWM's own; DWM's
/// shadow; no border. True when DWM gives it the backdrop (Windows 11 22H2 on); false leaves the
/// glass on the app's opaque backing.
pub fn viewportChrome(hwnd: *anyopaque, dark: bool, radius_pt: f32) bool {
    if (builtin.os.tag != .windows) return false;
    const h: win32.foundation.HWND = @ptrCast(hwnd);
    const dwm = win32.graphics.dwm;
    const corner: u32 = if (radius_pt < 1) DWMWCP_DONOTROUND else if (radius_pt < 6) DWMWCP_ROUNDSMALL else DWMWCP_ROUND;
    _ = dwm.DwmSetWindowAttribute(h, @enumFromInt(DWMWA_WINDOW_CORNER_PREFERENCE), &corner, @sizeOf(u32));
    const none: u32 = dwm.DWMWA_COLOR_NONE;
    _ = dwm.DwmSetWindowAttribute(h, dwm.DWMWA_BORDER_COLOR, &none, @sizeOf(u32));
    const dark_value: u32 = @intFromBool(dark);
    _ = dwm.DwmSetWindowAttribute(h, @enumFromInt(DWMWA_USE_IMMERSIVE_DARK_MODE), &dark_value, @sizeOf(u32));
    _ = win32.ui.shell.SetWindowSubclass(h, viewportSubclassProc, viewport_subclass_id, 0);
    // No system menu: with the frame extended over the window, DWM draws the caption buttons
    // `WS_SYSMENU` brings, over the float's header (as `applyChrome` strips it from the main
    // window). Kept off by the subclass whenever the style is set again (`WM_STYLECHANGING`).
    const wm = win32.ui.windows_and_messaging;
    const style = wm.GetWindowLongPtrW(h, wm.GWL_STYLE);
    if (style & viewport_ws_sysmenu != 0) {
        _ = wm.SetWindowLongPtrW(h, wm.GWL_STYLE, style & ~viewport_ws_sysmenu);
        const SWP_NOSIZE: u32 = 0x0001;
        const SWP_NOMOVE: u32 = 0x0002;
        const SWP_NOZORDER: u32 = 0x0004;
        const SWP_NOACTIVATE: u32 = 0x0010;
        const SWP_FRAMECHANGED: u32 = 0x0020;
        _ = wm.SetWindowPos(h, null, 0, 0, 0, 0, @bitCast(SWP_NOSIZE | SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED));
    }
    return applyViewportBackdrop(h);
}

const viewport_ws_sysmenu: isize = 0x00080000;

/// The backdrop, and the frame extended over the whole window for it to show through — again on
/// every activation, as DWM wants (and as `win32MicaSubclassProc` does for the main window).
fn applyViewportBackdrop(h: win32.foundation.HWND) bool {
    const backdrop_type: u32 = DWMSBT_TRANSIENTWINDOW;
    const hr = win32.graphics.dwm.DwmSetWindowAttribute(h, @enumFromInt(DWMWA_SYSTEMBACKDROP_TYPE), &backdrop_type, @sizeOf(u32));
    _ = win32.graphics.dwm.DwmExtendFrameIntoClientArea(h, &win32_mica_margins);
    return hr >= 0;
}

fn viewportSubclassProc(
    hWnd: ?win32.foundation.HWND,
    uMsg: u32,
    wParam: win32.foundation.WPARAM,
    lParam: win32.foundation.LPARAM,
    uIdSubclass: usize,
    dwRefData: usize,
) callconv(.winapi) win32.foundation.LRESULT {
    _ = uIdSubclass;
    _ = dwRefData;
    const wm = win32.ui.windows_and_messaging;
    if (uMsg == wm.WM_ACTIVATE or uMsg == wm.WM_DWMCOMPOSITIONCHANGED) {
        if (hWnd) |h| _ = applyViewportBackdrop(h);
    }
    // SDL sets the window's style again as it likes (`viewportChrome`): never the system menu.
    if (uMsg == wm.WM_STYLECHANGING and @as(isize, @bitCast(wParam)) == @intFromEnum(wm.GWL_STYLE)) {
        const ss: *wm.STYLESTRUCT = @ptrFromInt(@as(usize, @bitCast(lParam)));
        ss.styleNew &= ~@as(u32, @intCast(viewport_ws_sysmenu));
    }
    // A subclass goes before its window does.
    if (uMsg == wm.WM_NCDESTROY) _ = win32.ui.shell.RemoveWindowSubclass(hWnd, viewportSubclassProc, viewport_subclass_id);
    return win32.ui.shell.DefSubclassProc(hWnd, uMsg, wParam, lParam);
}
