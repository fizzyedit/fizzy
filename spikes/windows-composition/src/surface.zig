//! A picture the app presents as a swapchain made for composition (D3D11, drawn with Direct2D):
//! spike 3's mask, the overlay's rim, and the app's picture hosted in composition's own tree
//! rather than SDL's DirectComposition target (spike 1's fallback). In fizzy the device would be
//! SDL's D3D12; what is asked here is only whether composition takes such a swapchain where it is
//! put, so D3D11, which Direct2D draws into with no shaders, stands in.
const std = @import("std");
const win32 = @import("win32");
const winrt = @import("winrt.zig");

const d2d = win32.graphics.direct2d;
const common = d2d.common;
const d3d = win32.graphics.direct3d;
const d3d11 = win32.graphics.direct3d11;
const dxgi = win32.graphics.dxgi;

/// Direct2D and D3D11, once: the factory also makes every geometry the spike traces.
pub const Gpu = struct {
    factory: *d2d.ID2D1Factory1,
    device: *d3d11.ID3D11Device,
    d2d_device: *d2d.ID2D1Device,
    dxgi_factory: *dxgi.IDXGIFactory2,
    warp: bool,

    pub fn init() !Gpu {
        var factory: *d2d.ID2D1Factory1 = undefined;
        try winrt.check(d2d.D2D1CreateFactory(d2d.D2D1_FACTORY_TYPE_SINGLE_THREADED, d2d.IID_ID2D1Factory1, null, @ptrCast(&factory)), "D2D1CreateFactory");
        var device: *d3d11.ID3D11Device = undefined;
        var warp = false;
        if (d3d11.D3D11CreateDevice(null, d3d.D3D_DRIVER_TYPE_HARDWARE, null, .{ .BGRA_SUPPORT = 1 }, null, 0, d3d11.D3D11_SDK_VERSION, &device, null, null) < 0) {
            try winrt.check(d3d11.D3D11CreateDevice(null, d3d.D3D_DRIVER_TYPE_WARP, null, .{ .BGRA_SUPPORT = 1 }, null, 0, d3d11.D3D11_SDK_VERSION, &device, null, null), "D3D11CreateDevice (WARP)");
            warp = true;
        }
        var dxgi_device: *dxgi.IDXGIDevice = undefined;
        try winrt.check(device.IUnknown.QueryInterface(dxgi.IID_IDXGIDevice, @ptrCast(&dxgi_device)), "QI IDXGIDevice");
        defer _ = dxgi_device.IUnknown.Release();
        var d2d_device: *d2d.ID2D1Device = undefined;
        try winrt.check(factory.CreateDevice(dxgi_device, &d2d_device), "ID2D1Factory1.CreateDevice");
        var dxgi_factory: *dxgi.IDXGIFactory2 = undefined;
        try winrt.check(dxgi.CreateDXGIFactory2(0, dxgi.IID_IDXGIFactory2, @ptrCast(&dxgi_factory)), "CreateDXGIFactory2");
        return .{ .factory = factory, .device = device, .d2d_device = d2d_device, .dxgi_factory = dxgi_factory, .warp = warp };
    }

    pub fn d2dFactory(g: *const Gpu) *d2d.ID2D1Factory {
        return &g.factory.ID2D1Factory;
    }
};

/// One swapchain for composition, premultiplied, and the Direct2D context that draws into it.
pub const Surface = struct {
    swapchain: *dxgi.IDXGISwapChain1,
    context: *d2d.ID2D1DeviceContext,
    brush: *d2d.ID2D1SolidColorBrush,
    width: u32,
    height: u32,

    pub fn init(gpu: *const Gpu, width: u32, height: u32) !Surface {
        const desc: dxgi.DXGI_SWAP_CHAIN_DESC1 = .{
            .Width = width,
            .Height = height,
            .Format = .B8G8R8A8_UNORM,
            .Stereo = 0,
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .BufferUsage = dxgi.DXGI_USAGE_RENDER_TARGET_OUTPUT,
            .BufferCount = 2,
            .Scaling = dxgi.DXGI_SCALING_STRETCH,
            .SwapEffect = dxgi.DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL,
            .AlphaMode = .PREMULTIPLIED,
            .Flags = 0,
        };
        var swapchain: *dxgi.IDXGISwapChain1 = undefined;
        try winrt.check(gpu.dxgi_factory.CreateSwapChainForComposition(&gpu.device.IUnknown, &desc, null, &swapchain), "CreateSwapChainForComposition");
        var context: *d2d.ID2D1DeviceContext = undefined;
        try winrt.check(gpu.d2d_device.CreateDeviceContext(.{}, &context), "ID2D1Device.CreateDeviceContext");
        var brush: *d2d.ID2D1SolidColorBrush = undefined;
        try winrt.check(context.ID2D1RenderTarget.CreateSolidColorBrush(&.{ .r = 1, .g = 1, .b = 1, .a = 1 }, null, &brush), "CreateSolidColorBrush");
        return .{ .swapchain = swapchain, .context = context, .brush = brush, .width = width, .height = height };
    }

    /// The swapchain as `IUnknown`, for `ICompositorInterop.CreateCompositionSurfaceForSwapChain`.
    pub fn unknown(s: *const Surface) winrt.Obj {
        return @ptrCast(s.swapchain);
    }

    pub const Paint = union(enum) {
        /// The geometry filled, opaque white: a mask.
        fill: *d2d.ID2D1Geometry,
        /// The geometry's outline, `width` pixels, in `color` (premultiplied by Direct2D).
        stroke: struct { geometry: *d2d.ID2D1Geometry, width: f32, color: common.D2D_COLOR_F },
    };

    /// Clear to nothing, paint, present (not waiting for a vblank: the caller's own present does).
    pub fn draw(s: *Surface, paints: []const Paint) !void {
        var surface: *dxgi.IDXGISurface = undefined;
        try winrt.check(s.swapchain.IDXGISwapChain.GetBuffer(0, dxgi.IID_IDXGISurface, @ptrCast(&surface)), "GetBuffer");
        defer _ = surface.IUnknown.Release();
        const props: d2d.D2D1_BITMAP_PROPERTIES1 = .{
            .pixelFormat = .{ .format = .B8G8R8A8_UNORM, .alphaMode = common.D2D1_ALPHA_MODE_PREMULTIPLIED },
            .dpiX = 96,
            .dpiY = 96,
            .bitmapOptions = .{ .TARGET = 1, .CANNOT_DRAW = 1 },
            .colorContext = null,
        };
        var bitmap: *d2d.ID2D1Bitmap1 = undefined;
        try winrt.check(s.context.CreateBitmapFromDxgiSurface(surface, &props, &bitmap), "CreateBitmapFromDxgiSurface");
        defer _ = bitmap.IUnknown.Release();
        s.context.SetTarget(&bitmap.ID2D1Image);
        const rt = &s.context.ID2D1RenderTarget;
        rt.BeginDraw();
        rt.Clear(&.{ .r = 0, .g = 0, .b = 0, .a = 0 });
        for (paints) |p| switch (p) {
            .fill => |geometry| {
                s.brush.SetColor(&.{ .r = 1, .g = 1, .b = 1, .a = 1 });
                rt.FillGeometry(geometry, &s.brush.ID2D1Brush, null);
            },
            .stroke => |st| {
                s.brush.SetColor(&st.color);
                rt.DrawGeometry(st.geometry, &s.brush.ID2D1Brush, st.width, null);
            },
        };
        try winrt.check(rt.EndDraw(null, null), "EndDraw");
        s.context.SetTarget(null);
        try winrt.check(s.swapchain.IDXGISwapChain.Present(0, 0), "IDXGISwapChain.Present");
    }
};
