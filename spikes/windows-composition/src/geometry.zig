//! The glass's outline as Direct2D builds it, and the object that hands it to composition.
//!
//! `CompositionPath` takes any `IGeometrySource2D` that also answers `IGeometrySource2DInterop`
//! with a Direct2D geometry (Win2D's `CanvasGeometry` is one). `Source` is that object, written
//! by hand: a fresh one each frame, as fizzy would trace the field's edge each frame.
const std = @import("std");
const win32 = @import("win32");
const winrt = @import("winrt.zig");

const d2d = win32.graphics.direct2d;
const common = d2d.common;
const Guid = winrt.Guid;
const HRESULT = winrt.HRESULT;

/// What the spike draws: a pill and, when `merged`, a circle orbiting it, the two as one outline
/// (a union, standing in for LiquidField's smooth union). Pixels of the window.
pub const Shape = struct {
    pill: common.D2D_RECT_F,
    circle: common.D2D_POINT_2F,
    radius: f32,
    merged: bool,

    pub fn bounds(s: Shape) common.D2D_RECT_F {
        var b = s.pill;
        if (s.merged) {
            b.left = @min(b.left, s.circle.x - s.radius);
            b.top = @min(b.top, s.circle.y - s.radius);
            b.right = @max(b.right, s.circle.x + s.radius);
            b.bottom = @max(b.bottom, s.circle.y + s.radius);
        }
        return b;
    }
};

/// `s` as one geometry of `factory`'s, owned by the caller.
pub fn build(factory: *d2d.ID2D1Factory, s: Shape) !*d2d.ID2D1Geometry {
    const h = s.pill.bottom - s.pill.top;
    var pill: *d2d.ID2D1RoundedRectangleGeometry = undefined;
    try winrt.check(factory.CreateRoundedRectangleGeometry(&.{ .rect = s.pill, .radiusX = h / 2, .radiusY = h / 2 }, &pill), "CreateRoundedRectangleGeometry");
    if (!s.merged) return &pill.ID2D1Geometry;
    defer _ = pill.IUnknown.Release();
    var circle: *d2d.ID2D1EllipseGeometry = undefined;
    try winrt.check(factory.CreateEllipseGeometry(&.{ .point = s.circle, .radiusX = s.radius, .radiusY = s.radius }, &circle), "CreateEllipseGeometry");
    defer _ = circle.IUnknown.Release();
    var path: *d2d.ID2D1PathGeometry = undefined;
    try winrt.check(factory.CreatePathGeometry(&path), "CreatePathGeometry");
    errdefer _ = path.IUnknown.Release();
    var sink: *d2d.ID2D1GeometrySink = undefined;
    try winrt.check(path.Open(&sink), "ID2D1PathGeometry.Open");
    defer _ = sink.IUnknown.Release();
    try winrt.check(pill.ID2D1Geometry.CombineWithGeometry(&circle.ID2D1Geometry, d2d.D2D1_COMBINE_MODE_UNION, null, 0.25, &sink.ID2D1SimplifiedGeometrySink), "CombineWithGeometry");
    try winrt.check(sink.ID2D1SimplifiedGeometrySink.Close(), "ID2D1GeometrySink.Close");
    return &path.ID2D1Geometry;
}

/// How composition asked for the geometry, for the report.
pub var get_geometry_calls: u32 = 0;
pub var try_factory_calls: u32 = 0;

/// An `IGeometrySource2D` over one Direct2D geometry. Starts with one reference, which the caller
/// gives up once `CompositionPath` has taken its own.
pub const Source = extern struct {
    /// `IGeometrySource2D` (and IUnknown, IInspectable, IAgileObject): this pointer.
    source_vtbl: *const SourceVtbl = &source_vtbl,
    /// `IGeometrySource2DInterop`.
    interop_vtbl: *const InteropVtbl = &interop_vtbl,
    refs: u32 = 1,
    geometry: *d2d.ID2D1Geometry,
    factory: *d2d.ID2D1Factory,

    /// Takes over `geometry`'s reference.
    pub fn create(geometry: *d2d.ID2D1Geometry, factory: *d2d.ID2D1Factory) !*Source {
        const s = try std.heap.c_allocator.create(Source);
        s.* = .{ .geometry = geometry, .factory = factory };
        return s;
    }

    pub fn object(s: *Source) winrt.Obj {
        return @ptrCast(&s.source_vtbl);
    }

    fn fromSource(this: *anyopaque) *Source {
        return @ptrCast(@alignCast(this));
    }

    fn fromInterop(this: *anyopaque) *Source {
        const field: **const InteropVtbl = @ptrCast(@alignCast(this));
        return @fieldParentPtr("interop_vtbl", field);
    }

    fn query(s: *Source, riid: *const Guid, out: *?*anyopaque) HRESULT {
        if (eql(riid, &winrt.IID_IUnknown) or eql(riid, &winrt.IID_IInspectable) or
            eql(riid, &winrt.IID_IGeometrySource2D) or eql(riid, &winrt.IID_IAgileObject))
        {
            out.* = @ptrCast(&s.source_vtbl);
        } else if (eql(riid, &winrt.IID_IGeometrySource2DInterop)) {
            out.* = @ptrCast(&s.interop_vtbl);
        } else {
            out.* = null;
            return e_nointerface;
        }
        _ = @atomicRmw(u32, &s.refs, .Add, 1, .monotonic);
        return 0;
    }

    fn addRef(s: *Source) u32 {
        return @atomicRmw(u32, &s.refs, .Add, 1, .monotonic) + 1;
    }

    fn release(s: *Source) u32 {
        const left = @atomicRmw(u32, &s.refs, .Sub, 1, .acq_rel) - 1;
        if (left == 0) {
            _ = s.geometry.IUnknown.Release();
            std.heap.c_allocator.destroy(s);
        }
        return left;
    }
};

const e_nointerface: HRESULT = @bitCast(@as(u32, 0x80004002));
const e_notimpl: HRESULT = @bitCast(@as(u32, 0x80004001));

fn eql(a: *const Guid, b: *const Guid) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

const SourceVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const Guid, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    GetIids: *const fn (*anyopaque, *u32, *?*Guid) callconv(.winapi) HRESULT,
    GetRuntimeClassName: *const fn (*anyopaque, *winrt.HSTRING) callconv(.winapi) HRESULT,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(.winapi) HRESULT,
};

const InteropVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const Guid, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    GetGeometry: *const fn (*anyopaque, *?*d2d.ID2D1Geometry) callconv(.winapi) HRESULT,
    TryGetGeometryUsingFactory: *const fn (*anyopaque, ?*d2d.ID2D1Factory, *?*d2d.ID2D1Geometry) callconv(.winapi) HRESULT,
};

const source_vtbl: SourceVtbl = .{
    .QueryInterface = struct {
        fn f(this: *anyopaque, riid: *const Guid, out: *?*anyopaque) callconv(.winapi) HRESULT {
            return Source.fromSource(this).query(riid, out);
        }
    }.f,
    .AddRef = struct {
        fn f(this: *anyopaque) callconv(.winapi) u32 {
            return Source.fromSource(this).addRef();
        }
    }.f,
    .Release = struct {
        fn f(this: *anyopaque) callconv(.winapi) u32 {
            return Source.fromSource(this).release();
        }
    }.f,
    .GetIids = inspectableGetIids,
    .GetRuntimeClassName = inspectableGetRuntimeClassName,
    .GetTrustLevel = inspectableGetTrustLevel,
};

const interop_vtbl: InteropVtbl = .{
    .QueryInterface = struct {
        fn f(this: *anyopaque, riid: *const Guid, out: *?*anyopaque) callconv(.winapi) HRESULT {
            return Source.fromInterop(this).query(riid, out);
        }
    }.f,
    .AddRef = struct {
        fn f(this: *anyopaque) callconv(.winapi) u32 {
            return Source.fromInterop(this).addRef();
        }
    }.f,
    .Release = struct {
        fn f(this: *anyopaque) callconv(.winapi) u32 {
            return Source.fromInterop(this).release();
        }
    }.f,
    .GetGeometry = struct {
        fn f(this: *anyopaque, out: *?*d2d.ID2D1Geometry) callconv(.winapi) HRESULT {
            get_geometry_calls += 1;
            const s = Source.fromInterop(this);
            _ = s.geometry.IUnknown.AddRef();
            out.* = s.geometry;
            return 0;
        }
    }.f,
    // As Win2D answers it: the geometry when it is of the factory asked about, else none.
    .TryGetGeometryUsingFactory = struct {
        fn f(this: *anyopaque, factory: ?*d2d.ID2D1Factory, out: *?*d2d.ID2D1Geometry) callconv(.winapi) HRESULT {
            try_factory_calls += 1;
            const s = Source.fromInterop(this);
            if (factory != null and @intFromPtr(factory.?) == @intFromPtr(s.factory)) {
                _ = s.geometry.IUnknown.AddRef();
                out.* = s.geometry;
            } else out.* = null;
            return 0;
        }
    }.f,
};

pub fn inspectableGetIids(_: *anyopaque, count: *u32, iids: *?*Guid) callconv(.winapi) HRESULT {
    count.* = 0;
    iids.* = null;
    return 0;
}

pub fn inspectableGetRuntimeClassName(_: *anyopaque, name: *winrt.HSTRING) callconv(.winapi) HRESULT {
    name.* = null;
    return e_notimpl;
}

pub fn inspectableGetTrustLevel(_: *anyopaque, level: *i32) callconv(.winapi) HRESULT {
    level.* = 0; // BaseTrust
    return 0;
}
