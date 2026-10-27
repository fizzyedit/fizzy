//! Asks Windows which window materials this box accepts and prints the answers.
//!
//! Run: `zig run tools/win_materials_probe.zig`. Standalone and std-only; it is not part of the
//! build. An HRESULT of 0 means DWM accepted the call, not that the material is visible: the
//! session may have no input desktop, transparency may be switched off, or the window may be
//! hidden. The probe reports those conditions beside the results.

const std = @import("std");
const builtin = @import("builtin");

const Hwnd = *anyopaque;
const Hresult = i32;

const OsVersionInfo = extern struct {
    size: u32 = @sizeOf(OsVersionInfo),
    major: u32 = 0,
    minor: u32 = 0,
    build: u32 = 0,
    platform: u32 = 0,
    csd: [128]u16 = @splat(0),
};

const Margins = extern struct { left: i32, right: i32, top: i32, bottom: i32 };

const Accent = extern struct { state: u32, flags: u32, gradient_color: u32, animation_id: u32 };

const CompositionAttribData = extern struct {
    attrib: u32,
    data: *anyopaque,
    size: usize,
};

const BlurBehind = extern struct {
    flags: u32,
    enable: i32,
    region: ?*anyopaque,
    transition_on_maximized: i32,
};

extern "ntdll" fn RtlGetVersion(info: *OsVersionInfo) callconv(.winapi) i32;
extern "dwmapi" fn DwmIsCompositionEnabled(enabled: *i32) callconv(.winapi) Hresult;
extern "dwmapi" fn DwmSetWindowAttribute(hwnd: Hwnd, attr: u32, value: *const anyopaque, size: u32) callconv(.winapi) Hresult;
extern "dwmapi" fn DwmGetWindowAttribute(hwnd: Hwnd, attr: u32, value: *anyopaque, size: u32) callconv(.winapi) Hresult;
extern "dwmapi" fn DwmExtendFrameIntoClientArea(hwnd: Hwnd, margins: *const Margins) callconv(.winapi) Hresult;
extern "dwmapi" fn DwmEnableBlurBehindWindow(hwnd: Hwnd, bb: *const BlurBehind) callconv(.winapi) Hresult;
extern "user32" fn CreateWindowExW(ex: u32, class: [*:0]const u16, title: [*:0]const u16, style: u32, x: i32, y: i32, w: i32, h: i32, parent: ?Hwnd, menu: ?*anyopaque, inst: ?*anyopaque, param: ?*anyopaque) callconv(.winapi) ?Hwnd;
extern "user32" fn DestroyWindow(hwnd: Hwnd) callconv(.winapi) i32;
extern "user32" fn OpenInputDesktop(flags: u32, inherit: i32, access: u32) callconv(.winapi) ?*anyopaque;
extern "user32" fn CloseDesktop(desktop: *anyopaque) callconv(.winapi) i32;
extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetModuleHandleW(name: [*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn ProcessIdToSessionId(pid: u32, session: *u32) callconv(.winapi) i32;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "advapi32" fn RegGetValueW(key: usize, subkey: [*:0]const u16, value: [*:0]const u16, flags: u32, kind: ?*u32, data: *anyopaque, size: *u32) callconv(.winapi) i32;

const hkcu: usize = 0x80000001;
const rrf_rt_reg_dword: u32 = 0x10;
const ws_overlapped: u32 = 0;

const Attr = struct { id: u32, name: []const u8 };

const backdrop_attr: u32 = 38; // DWMWA_SYSTEMBACKDROP_TYPE
const backdrops = [_]Attr{
    .{ .id = 0, .name = "DWMSBT_AUTO" },
    .{ .id = 1, .name = "DWMSBT_NONE" },
    .{ .id = 2, .name = "DWMSBT_MAINWINDOW (Mica)" },
    .{ .id = 3, .name = "DWMSBT_TRANSIENTWINDOW (Acrylic)" },
    .{ .id = 4, .name = "DWMSBT_TABBEDWINDOW (Mica Alt)" },
    .{ .id = 5, .name = "out of range (control)" },
};

const accents = [_]Attr{
    .{ .id = 0, .name = "ACCENT_DISABLED" },
    .{ .id = 1, .name = "ACCENT_ENABLE_GRADIENT" },
    .{ .id = 2, .name = "ACCENT_ENABLE_TRANSPARENTGRADIENT" },
    .{ .id = 3, .name = "ACCENT_ENABLE_BLURBEHIND" },
    .{ .id = 4, .name = "ACCENT_ENABLE_ACRYLICBLURBEHIND" },
    .{ .id = 5, .name = "ACCENT_ENABLE_HOSTBACKDROP" },
};

const window_attrs = [_]Attr{
    .{ .id = 17, .name = "DWMWA_USE_HOSTBACKDROPBRUSH" },
    .{ .id = 20, .name = "DWMWA_USE_IMMERSIVE_DARK_MODE" },
    .{ .id = 33, .name = "DWMWA_WINDOW_CORNER_PREFERENCE" },
    .{ .id = 34, .name = "DWMWA_BORDER_COLOR" },
    .{ .id = 35, .name = "DWMWA_CAPTION_COLOR" },
    .{ .id = 38, .name = "DWMWA_SYSTEMBACKDROP_TYPE" },
    .{ .id = 1029, .name = "undocumented MICA_EFFECT (pre-22621 Mica)" },
};

pub fn main() void {
    if (builtin.os.tag != .windows) {
        std.debug.print("win_materials_probe only runs on Windows\n", .{});
        return;
    }

    var ver: OsVersionInfo = .{};
    _ = RtlGetVersion(&ver);
    std.debug.print("os: {d}.{d} build {d}\n", .{ ver.major, ver.minor, ver.build });

    var session: u32 = 0;
    _ = ProcessIdToSessionId(GetCurrentProcessId(), &session);
    const input_desktop = OpenInputDesktop(0, 0, 0x1); // DESKTOP_READOBJECTS
    std.debug.print("session id: {d}; input desktop: {s}\n", .{
        session,
        if (input_desktop != null) "available" else "none (no screenshot possible)",
    });
    if (input_desktop) |d| _ = CloseDesktop(d);

    var enabled: i32 = 0;
    const comp = DwmIsCompositionEnabled(&enabled);
    std.debug.print("DwmIsCompositionEnabled: hr=0x{x:0>8} enabled={d}\n", .{ @as(u32, @bitCast(comp)), enabled });

    var transparency: u32 = 0;
    var tsize: u32 = @sizeOf(u32);
    const personalize = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize");
    const tvalue = std.unicode.utf8ToUtf16LeStringLiteral("EnableTransparency");
    const treg = RegGetValueW(hkcu, personalize, tvalue, rrf_rt_reg_dword, null, &transparency, &tsize);
    if (treg == 0) {
        std.debug.print("Transparency effects setting: {s}\n", .{if (transparency != 0) "on" else "off"});
    } else {
        std.debug.print("Transparency effects setting: unreadable (error {d})\n", .{treg});
    }

    const class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
    const title = std.unicode.utf8ToUtf16LeStringLiteral("probe");
    const hwnd = CreateWindowExW(0, class, title, ws_overlapped, 0, 0, 64, 64, null, null, null, null) orelse {
        std.debug.print("CreateWindowExW failed: error {d}\n", .{GetLastError()});
        return;
    };
    defer _ = DestroyWindow(hwnd);

    std.debug.print("\nDwmSetWindowAttribute(DWMWA_SYSTEMBACKDROP_TYPE = 38), then read back:\n", .{});
    for (backdrops) |b| {
        const v: u32 = b.id;
        const set = DwmSetWindowAttribute(hwnd, backdrop_attr, &v, @sizeOf(u32));
        var got: u32 = 0xffff;
        const get = DwmGetWindowAttribute(hwnd, backdrop_attr, &got, @sizeOf(u32));
        std.debug.print("  {d} {s}: set hr=0x{x:0>8}, get hr=0x{x:0>8} value={d}\n", .{
            b.id, b.name, @as(u32, @bitCast(set)), @as(u32, @bitCast(get)), got,
        });
    }

    std.debug.print("\nDwmSetWindowAttribute with a plausible value (hr only):\n", .{});
    for (window_attrs) |a| {
        const v: u32 = if (a.id == 34 or a.id == 35) 0x00ff0000 else 1;
        const set = DwmSetWindowAttribute(hwnd, a.id, &v, @sizeOf(u32));
        std.debug.print("  {d} {s}: hr=0x{x:0>8}\n", .{ a.id, a.name, @as(u32, @bitCast(set)) });
    }

    const margins: Margins = .{ .left = -1, .right = -1, .top = -1, .bottom = -1 };
    const extend = DwmExtendFrameIntoClientArea(hwnd, &margins);
    std.debug.print("\nDwmExtendFrameIntoClientArea(-1 margins): hr=0x{x:0>8}\n", .{@as(u32, @bitCast(extend))});

    const bb: BlurBehind = .{ .flags = 1, .enable = 1, .region = null, .transition_on_maximized = 0 };
    const blur = DwmEnableBlurBehindWindow(hwnd, &bb);
    std.debug.print("DwmEnableBlurBehindWindow(enable): hr=0x{x:0>8}\n", .{@as(u32, @bitCast(blur))});

    std.debug.print("\nSetWindowCompositionAttribute (WCA_ACCENT_POLICY = 19):\n", .{});
    const user32 = GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("user32.dll"));
    const proc = if (user32) |m| GetProcAddress(m, "SetWindowCompositionAttribute") else null;
    if (proc) |p| {
        const SetWca = *const fn (Hwnd, *CompositionAttribData) callconv(.winapi) i32;
        const set_wca: SetWca = @ptrCast(p);
        for (accents) |a| {
            var policy: Accent = .{ .state = a.id, .flags = 2, .gradient_color = 0x99000000, .animation_id = 0 };
            var data: CompositionAttribData = .{ .attrib = 19, .data = &policy, .size = @sizeOf(Accent) };
            const ok = set_wca(hwnd, &data);
            std.debug.print("  {d} {s}: returned {d}{s}\n", .{
                a.id,
                a.name,
                ok,
                if (ok == 0) " (failed)" else "",
            });
        }
    } else {
        std.debug.print("  SetWindowCompositionAttribute not exported by user32\n", .{});
    }
}
