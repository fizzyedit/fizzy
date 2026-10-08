//! Spike 4: the overlay a drag would carry its glass in on Windows (WINDOWS_LINUX_GLASS_PLAN.md,
//! "one overlay per display"). A window over the whole primary display, topmost, never activated,
//! no taskbar entry, no redirection bitmap, holding a host-backdrop pill and its rim that follow
//! the pointer. The question is which styles let every click through to what is under it while
//! the composition tree still shows; `variant` picks one.
const std = @import("std");
const win32 = @import("win32");
const winrt = @import("winrt.zig");
const comp = @import("comp.zig");
const surface = @import("surface.zig");
const geometry = @import("geometry.zig");
const u = @import("user32.zig");

const log = std.log.scoped(.overlay);

pub const Variant = enum {
    /// `WS_EX_TRANSPARENT | WS_EX_LAYERED`, no layered attributes set.
    layered,
    /// The same, with `SetLayeredWindowAttributes(255, LWA_ALPHA)`.
    layered_alpha,
    /// `WS_EX_TRANSPARENT` alone.
    transparent,
    /// No click-through style; `WM_NCHITTEST` answers `HTTRANSPARENT`.
    hittest,

    pub fn next(v: ?Variant) ?Variant {
        const cur = v orelse return .layered;
        const i = @intFromEnum(cur) + 1;
        return if (i >= @typeInfo(Variant).@"enum".fields.len) null else @enumFromInt(i);
    }
};

const pill_w = 220;
const pill_h = 72;
const rim = 4;

hwnd: u.HWND,
variant: Variant,
target: winrt.Obj,
backdrop: winrt.Obj,
rim_visual: winrt.Obj,
rim_surface: surface.Surface,
last_hit: [64]u8 = undefined,
last_hit_len: usize = 0,

const Self = @This();

var class_registered = false;
const class_name = std.unicode.utf8ToUtf16LeStringLiteral("fizzy_spike_overlay");
var hittest_transparent = false;

fn wndProc(hwnd: u.HWND, msg: u32, wp: usize, lp: isize) callconv(.winapi) isize {
    if (msg == u.WM_NCHITTEST and hittest_transparent) return u.HTTRANSPARENT;
    return u.DefWindowProcW(hwnd, msg, wp, lp);
}

pub fn open(c: *const comp.Comp, gpu: *const surface.Gpu, variant: Variant) !Self {
    const instance = u.GetModuleHandleW(null);
    if (!class_registered) {
        _ = u.RegisterClassExW(&.{ .lpfnWndProc = wndProc, .hInstance = instance, .lpszClassName = class_name });
        class_registered = true;
    }
    hittest_transparent = variant == .hittest;
    var ex: u32 = u.WS_EX_TOPMOST | u.WS_EX_TOOLWINDOW | u.WS_EX_NOACTIVATE | u.WS_EX_NOREDIRECTIONBITMAP;
    switch (variant) {
        .layered, .layered_alpha => ex |= u.WS_EX_TRANSPARENT | u.WS_EX_LAYERED,
        .transparent => ex |= u.WS_EX_TRANSPARENT,
        .hittest => {},
    }
    const sw = u.GetSystemMetrics(0);
    const sh = u.GetSystemMetrics(1);
    const hwnd = u.CreateWindowExW(ex, class_name, std.unicode.utf8ToUtf16LeStringLiteral("spike overlay"), u.WS_POPUP, 0, 0, sw, sh, null, null, instance, null) orelse return error.CreateWindow;
    if (variant == .layered_alpha) _ = u.SetLayeredWindowAttributes(hwnd, 0, 255, u.LWA_ALPHA);
    const yes: u.BOOL = 1;
    const hr = u.DwmSetWindowAttribute(hwnd, u.DWMWA_USE_HOSTBACKDROPBRUSH, &yes, @sizeOf(u.BOOL));
    _ = u.ShowWindow(hwnd, u.SW_SHOWNOACTIVATE);
    log.info("open {s}: ex style 0x{x} (asked 0x{x}), {d}x{d}, USE_HOSTBACKDROPBRUSH hr=0x{x}", .{ @tagName(variant), @as(u32, @truncate(@as(usize, @bitCast(u.GetWindowLongPtrW(hwnd, u.GWL_EXSTYLE))))), ex, sw, sh, @as(u32, @bitCast(hr)) });

    const t = try c.desktopTarget(hwnd, false);
    const root = try c.container();
    try winrt.put(?*anyopaque, t.target, winrt.slots.ICompositionTarget.put_Root, root.visual, "overlay put_Root");

    // The rim under the glass: a picture the app presents (Direct2D into a composition swapchain),
    // hosted in this tree.
    var rim_surface = try surface.Surface.init(gpu, pill_w + 2 * rim, pill_h + 2 * rim);
    const outline = try geometry.build(gpu.d2dFactory(), .{ .pill = .{ .left = rim / 2, .top = rim / 2, .right = pill_w + rim * 1.5, .bottom = pill_h + rim * 1.5 }, .circle = .{ .x = 0, .y = 0 }, .radius = 0, .merged = false });
    defer _ = outline.IUnknown.Release();
    try rim_surface.draw(&.{.{ .stroke = .{ .geometry = outline, .width = rim, .color = .{ .r = 1, .g = 0.25, .b = 0.2, .a = 1 } } }});
    const rim_sprite = try c.sprite();
    try winrt.put(?*anyopaque, rim_sprite.sprite, winrt.slots.ISpriteVisual.put_Brush, try c.swapchainBrush(rim_surface.unknown()), "overlay rim put_Brush");
    try c.setSize(rim_sprite.visual, pill_w + 2 * rim, pill_h + 2 * rim);
    try c.insertTop(root.children, rim_sprite.visual);

    const glass = try c.sprite();
    try winrt.put(?*anyopaque, glass.sprite, winrt.slots.ISpriteVisual.put_Brush, try c.hostBackdrop(), "overlay glass put_Brush");
    try c.setSize(glass.visual, pill_w, pill_h);
    const clip = try c.rectClip();
    try c.setRectClip(clip.rect, 0, 0, pill_w, pill_h, pill_h / 2);
    try winrt.put(?*anyopaque, glass.visual, winrt.slots.IVisual.put_Clip, clip.clip, "overlay put_Clip");
    try c.insertTop(root.children, glass.visual);

    return .{ .hwnd = hwnd, .variant = variant, .target = t.target, .backdrop = glass.visual, .rim_visual = rim_sprite.visual, .rim_surface = rim_surface };
}

/// The glass where the pointer is, a little below and right of it as a carried view would be.
/// Returns what the desktop says is under the pointer when that changes (`WindowFromPoint`).
pub fn update(o: *Self, c: *const comp.Comp) !?[]const u8 {
    var p: u.POINT = undefined;
    _ = u.GetCursorPos(&p);
    const x: f32 = @floatFromInt(p.x + 16);
    const y: f32 = @floatFromInt(p.y + 16);
    try c.setOffset(o.backdrop, x, y);
    try c.setOffset(o.rim_visual, x - rim, y - rim);

    // Who takes a click at the pointer: the overlay, or the window under it.
    const hit = u.WindowFromPoint(p);
    var buf: [64]u8 = undefined;
    const name: []const u8 = if (hit) |h| blk: {
        if (h == o.hwnd) break :blk "the overlay";
        var w: [48]u16 = undefined;
        const n = u.GetClassNameW(u.GetAncestor(h, u.GA_ROOT) orelse h, &w, w.len);
        const len = std.unicode.utf16LeToUtf8(&buf, w[0..@intCast(@max(n, 0))]) catch 0;
        break :blk buf[0..len];
    } else "nothing";
    if (std.mem.eql(u8, name, o.last_hit[0..o.last_hit_len])) return null;
    @memcpy(o.last_hit[0..name.len], name);
    o.last_hit_len = name.len;
    return o.last_hit[0..o.last_hit_len];
}

pub fn close(o: *Self) void {
    winrt.put(?*anyopaque, o.target, winrt.slots.ICompositionTarget.put_Root, null, "overlay put_Root null") catch {};
    _ = u.DestroyWindow(o.hwnd);
}
