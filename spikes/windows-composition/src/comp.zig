//! The compositor and the handful of things the spike makes with it, each a WinRT call by slot
//! (`winrt.slots`). One compositor serves every window on the thread.
const std = @import("std");
const winrt = @import("winrt.zig");
const u = @import("user32.zig");

const Obj = winrt.Obj;
const s = winrt.slots;

const log = std.log.scoped(.comp);

pub const Comp = struct {
    c1: Obj,
    c3: ?Obj,
    c5: ?Obj,
    c6: ?Obj,
    c7: ?Obj,
    desktop: Obj,
    interop: Obj,

    pub fn init() !Comp {
        const inspectable = try winrt.activate("Windows.UI.Composition.Compositor");
        const c: Comp = .{
            .c1 = try winrt.qi(inspectable, &winrt.IID_ICompositor, "QI ICompositor"),
            .c3 = winrt.tryQi(inspectable, &winrt.IID_ICompositor3),
            .c5 = winrt.tryQi(inspectable, &winrt.IID_ICompositor5),
            .c6 = winrt.tryQi(inspectable, &winrt.IID_ICompositor6),
            .c7 = winrt.tryQi(inspectable, &winrt.IID_ICompositor7),
            .desktop = try winrt.qi(inspectable, &winrt.IID_ICompositorDesktopInterop, "QI ICompositorDesktopInterop"),
            .interop = try winrt.qi(inspectable, &winrt.IID_ICompositorInterop, "QI ICompositorInterop"),
        };
        log.info("compositor: ICompositor3 (host backdrop) {s}, ICompositor5 (paths) {s}, ICompositor6 (geometric clip) {s}, ICompositor7 (rounded rect clip) {s}", .{
            have(c.c3), have(c.c5), have(c.c6), have(c.c7),
        });
        return c;
    }

    fn have(o: ?Obj) []const u8 {
        return if (o != null) "yes" else "NO";
    }

    pub const Target = struct { target: Obj, topmost: bool };

    /// A `DesktopWindowTarget` for `hwnd`, as `ICompositionTarget`.
    pub fn desktopTarget(c: *const Comp, hwnd: u.HWND, topmost: bool) !Target {
        var dwt: ?*anyopaque = null;
        try winrt.check(winrt.method(*const fn (Obj, u.HWND, u.BOOL, *?*anyopaque) callconv(.winapi) winrt.HRESULT, c.desktop, s.ICompositorDesktopInterop.CreateDesktopWindowTarget)(c.desktop, hwnd, @intFromBool(topmost), &dwt), "CreateDesktopWindowTarget");
        var is_top: u8 = 0;
        try winrt.check(winrt.method(*const fn (Obj, *u8) callconv(.winapi) winrt.HRESULT, dwt.?, s.IDesktopWindowTarget.get_IsTopmost)(dwt.?, &is_top), "get_IsTopmost");
        return .{ .target = try winrt.qi(dwt.?, &winrt.IID_ICompositionTarget, "QI ICompositionTarget"), .topmost = is_top != 0 };
    }

    pub const Container = struct { visual: Obj, children: Obj };

    pub fn container(c: *const Comp) !Container {
        const cv = try winrt.get(c.c1, s.ICompositor.CreateContainerVisual, "CreateContainerVisual");
        return .{ .visual = try winrt.qi(cv, &winrt.IID_IVisual, "QI IVisual"), .children = try winrt.get(cv, s.IContainerVisual.get_Children, "get_Children") };
    }

    pub const Sprite = struct { sprite: Obj, visual: Obj };

    pub fn sprite(c: *const Comp) !Sprite {
        const sv = try winrt.get(c.c1, s.ICompositor.CreateSpriteVisual, "CreateSpriteVisual");
        return .{ .sprite = sv, .visual = try winrt.qi(sv, &winrt.IID_IVisual, "QI IVisual") };
    }

    /// A blur of what is behind the window, as `ICompositionBrush`.
    pub fn hostBackdrop(c: *const Comp) !Obj {
        const c3 = c.c3 orelse return error.NoHostBackdrop;
        const b = try winrt.get(c3, s.ICompositor3.CreateHostBackdropBrush, "CreateHostBackdropBrush");
        return winrt.qi(b, &winrt.IID_ICompositionBrush, "QI ICompositionBrush (backdrop)");
    }

    pub fn colorBrush(c: *const Comp, color: winrt.Color) !Obj {
        var b: ?*anyopaque = null;
        try winrt.check(winrt.method(*const fn (Obj, winrt.Color, *?*anyopaque) callconv(.winapi) winrt.HRESULT, c.c1, s.ICompositor.CreateColorBrushWithColor)(c.c1, color, &b), "CreateColorBrush");
        return winrt.qi(b.?, &winrt.IID_ICompositionBrush, "QI ICompositionBrush (colour)");
    }

    /// A brush showing `swapchain` (an `IDXGISwapChain1` made for composition).
    pub fn swapchainBrush(c: *const Comp, swapchain: Obj) !Obj {
        var surf: ?*anyopaque = null;
        try winrt.check(winrt.method(*const fn (Obj, Obj, *?*anyopaque) callconv(.winapi) winrt.HRESULT, c.interop, s.ICompositorInterop.CreateCompositionSurfaceForSwapChain)(c.interop, swapchain, &surf), "CreateCompositionSurfaceForSwapChain");
        var b: ?*anyopaque = null;
        try winrt.check(winrt.method(*const fn (Obj, Obj, *?*anyopaque) callconv(.winapi) winrt.HRESULT, c.c1, s.ICompositor.CreateSurfaceBrushWithSurface)(c.c1, surf.?, &b), "CreateSurfaceBrush");
        return winrt.qi(b.?, &winrt.IID_ICompositionBrush, "QI ICompositionBrush (surface)");
    }

    pub const RectClip = struct { rect: Obj, clip: Obj };

    pub fn rectClip(c: *const Comp) !RectClip {
        const c7 = c.c7 orelse return error.NoRectangleClip;
        const r = try winrt.get(c7, s.ICompositor7.CreateRectangleClip, "CreateRectangleClip");
        return .{ .rect = r, .clip = try winrt.qi(r, &winrt.IID_ICompositionClip, "QI ICompositionClip (rect)") };
    }

    pub fn setRectClip(_: *const Comp, rect: Obj, l: f32, t: f32, r: f32, b: f32, radius: f32) !void {
        const R = s.IRectangleClip;
        try winrt.put(f32, rect, R.put_Left, l, "put_Left");
        try winrt.put(f32, rect, R.put_Top, t, "put_Top");
        try winrt.put(f32, rect, R.put_Right, r, "put_Right");
        try winrt.put(f32, rect, R.put_Bottom, b, "put_Bottom");
        const v: winrt.Vec2 = .{ .x = radius, .y = radius };
        inline for (.{ R.put_TopLeftRadius, R.put_TopRightRadius, R.put_BottomRightRadius, R.put_BottomLeftRadius }) |slot|
            try winrt.put(winrt.Vec2, rect, slot, v, "put_*Radius");
    }

    pub const PathClip = struct { path_geometry: Obj, clip: Obj };

    pub fn pathClip(c: *const Comp) !PathClip {
        const c5 = c.c5 orelse return error.NoPaths;
        const c6 = c.c6 orelse return error.NoGeometricClip;
        const pg = try winrt.get(c5, s.ICompositor5.CreatePathGeometry, "CreatePathGeometry");
        const geom = try winrt.qi(pg, &winrt.IID_ICompositionGeometry, "QI ICompositionGeometry");
        var gc: ?*anyopaque = null;
        try winrt.check(winrt.method(*const fn (Obj, Obj, *?*anyopaque) callconv(.winapi) winrt.HRESULT, c6, s.ICompositor6.CreateGeometricClipWithGeometry)(c6, geom, &gc), "CreateGeometricClip");
        return .{ .path_geometry = pg, .clip = try winrt.qi(gc.?, &winrt.IID_ICompositionClip, "QI ICompositionClip (geometric)") };
    }

    pub fn setSize(_: *const Comp, visual: Obj, w: f32, h: f32) !void {
        try winrt.put(winrt.Vec2, visual, s.IVisual.put_Size, .{ .x = w, .y = h }, "put_Size");
    }

    pub fn setOffset(_: *const Comp, visual: Obj, x: f32, y: f32) !void {
        try winrt.put(winrt.Vec3, visual, s.IVisual.put_Offset, .{ .x = x, .y = y, .z = 0 }, "put_Offset");
    }

    pub fn insertTop(_: *const Comp, children: Obj, visual: Obj) !void {
        try winrt.put(Obj, children, s.IVisualCollection.InsertAtTop, visual, "InsertAtTop");
    }
};
