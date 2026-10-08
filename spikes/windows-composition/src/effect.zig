//! An effect description composition can compile: a Direct2D effect by CLSID, its sources and
//! properties, given through `IGraphicsEffectD2D1Interop`, as Win2D's effects give them. Written
//! by hand, for spike 3: the host backdrop masked by a surface the app presents.
const std = @import("std");
const win32 = @import("win32");
const winrt = @import("winrt.zig");
const geometry = @import("geometry.zig");

const Guid = winrt.Guid;
const HRESULT = winrt.HRESULT;

pub const Effect = extern struct {
    /// `IGraphicsEffect`, which also answers for `IGraphicsEffectSource` (it adds nothing to
    /// IInspectable), IUnknown, IInspectable and IAgileObject.
    effect_vtbl: *const EffectVtbl = &effect_vtbl,
    /// `IGraphicsEffectD2D1Interop`.
    interop_vtbl: *const InteropVtbl = &interop_vtbl,
    refs: u32 = 1,
    id: Guid,
    /// `IGraphicsEffectSource`s, referenced.
    sources: [2]?*anyopaque,
    source_count: u32,
    /// `IPropertyValue`s, referenced, by D2D property index.
    properties: [1]?*anyopaque,
    property_count: u32,

    /// Owns one reference to each of `sources` and `properties`.
    pub fn create(id: Guid, sources: []const winrt.Obj, properties: []const winrt.Obj) !*Effect {
        const e = try std.heap.c_allocator.create(Effect);
        e.* = .{ .id = id, .sources = .{ null, null }, .source_count = @intCast(sources.len), .properties = .{null}, .property_count = @intCast(properties.len) };
        for (sources, 0..) |s, i| e.sources[i] = s;
        for (properties, 0..) |p, i| e.properties[i] = p;
        return e;
    }

    pub fn object(e: *Effect) winrt.Obj {
        return @ptrCast(&e.effect_vtbl);
    }

    fn fromEffect(this: *anyopaque) *Effect {
        return @ptrCast(@alignCast(this));
    }

    fn fromInterop(this: *anyopaque) *Effect {
        const field: **const InteropVtbl = @ptrCast(@alignCast(this));
        return @fieldParentPtr("interop_vtbl", field);
    }

    fn query(e: *Effect, riid: *const Guid, out: *?*anyopaque) HRESULT {
        if (eql(riid, &winrt.IID_IUnknown) or eql(riid, &winrt.IID_IInspectable) or eql(riid, &winrt.IID_IGraphicsEffect) or
            eql(riid, &winrt.IID_IGraphicsEffectSource) or eql(riid, &winrt.IID_IAgileObject))
        {
            out.* = @ptrCast(&e.effect_vtbl);
        } else if (eql(riid, &winrt.IID_IGraphicsEffectD2D1Interop)) {
            out.* = @ptrCast(&e.interop_vtbl);
        } else {
            out.* = null;
            return e_nointerface;
        }
        _ = @atomicRmw(u32, &e.refs, .Add, 1, .monotonic);
        return 0;
    }

    fn addRef(e: *Effect) u32 {
        return @atomicRmw(u32, &e.refs, .Add, 1, .monotonic) + 1;
    }

    fn release(e: *Effect) u32 {
        const left = @atomicRmw(u32, &e.refs, .Sub, 1, .acq_rel) - 1;
        if (left == 0) {
            for (e.sources) |s| if (s) |o| winrt.release(o);
            for (e.properties) |p| if (p) |o| winrt.release(o);
            std.heap.c_allocator.destroy(e);
        }
        return left;
    }
};

const e_nointerface: HRESULT = @bitCast(@as(u32, 0x80004002));
const e_invalidarg: HRESULT = @bitCast(@as(u32, 0x80070057));

fn eql(a: *const Guid, b: *const Guid) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

const EffectVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const Guid, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    GetIids: *const fn (*anyopaque, *u32, *?*Guid) callconv(.winapi) HRESULT,
    GetRuntimeClassName: *const fn (*anyopaque, *winrt.HSTRING) callconv(.winapi) HRESULT,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(.winapi) HRESULT,
    get_Name: *const fn (*anyopaque, *winrt.HSTRING) callconv(.winapi) HRESULT,
    put_Name: *const fn (*anyopaque, winrt.HSTRING) callconv(.winapi) HRESULT,
};

const InteropVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const Guid, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    GetEffectId: *const fn (*anyopaque, *Guid) callconv(.winapi) HRESULT,
    GetNamedPropertyMapping: *const fn (*anyopaque, ?[*:0]const u16, *u32, *i32) callconv(.winapi) HRESULT,
    GetPropertyCount: *const fn (*anyopaque, *u32) callconv(.winapi) HRESULT,
    GetProperty: *const fn (*anyopaque, u32, *?*anyopaque) callconv(.winapi) HRESULT,
    GetSource: *const fn (*anyopaque, u32, *?*anyopaque) callconv(.winapi) HRESULT,
    GetSourceCount: *const fn (*anyopaque, *u32) callconv(.winapi) HRESULT,
};

const effect_vtbl: EffectVtbl = .{
    .QueryInterface = struct {
        fn f(this: *anyopaque, riid: *const Guid, out: *?*anyopaque) callconv(.winapi) HRESULT {
            return Effect.fromEffect(this).query(riid, out);
        }
    }.f,
    .AddRef = struct {
        fn f(this: *anyopaque) callconv(.winapi) u32 {
            return Effect.fromEffect(this).addRef();
        }
    }.f,
    .Release = struct {
        fn f(this: *anyopaque) callconv(.winapi) u32 {
            return Effect.fromEffect(this).release();
        }
    }.f,
    .GetIids = geometry.inspectableGetIids,
    .GetRuntimeClassName = geometry.inspectableGetRuntimeClassName,
    .GetTrustLevel = geometry.inspectableGetTrustLevel,
    // Unnamed: the brush names its sources' parameters, not the effect.
    .get_Name = struct {
        fn f(_: *anyopaque, name: *winrt.HSTRING) callconv(.winapi) HRESULT {
            name.* = null;
            return 0;
        }
    }.f,
    .put_Name = struct {
        fn f(_: *anyopaque, _: winrt.HSTRING) callconv(.winapi) HRESULT {
            return 0;
        }
    }.f,
};

const interop_vtbl: InteropVtbl = .{
    .QueryInterface = struct {
        fn f(this: *anyopaque, riid: *const Guid, out: *?*anyopaque) callconv(.winapi) HRESULT {
            return Effect.fromInterop(this).query(riid, out);
        }
    }.f,
    .AddRef = struct {
        fn f(this: *anyopaque) callconv(.winapi) u32 {
            return Effect.fromInterop(this).addRef();
        }
    }.f,
    .Release = struct {
        fn f(this: *anyopaque) callconv(.winapi) u32 {
            return Effect.fromInterop(this).release();
        }
    }.f,
    .GetEffectId = struct {
        fn f(this: *anyopaque, id: *Guid) callconv(.winapi) HRESULT {
            id.* = Effect.fromInterop(this).id;
            return 0;
        }
    }.f,
    .GetNamedPropertyMapping = struct {
        fn f(_: *anyopaque, _: ?[*:0]const u16, _: *u32, _: *i32) callconv(.winapi) HRESULT {
            return e_invalidarg;
        }
    }.f,
    .GetPropertyCount = struct {
        fn f(this: *anyopaque, count: *u32) callconv(.winapi) HRESULT {
            count.* = Effect.fromInterop(this).property_count;
            return 0;
        }
    }.f,
    .GetProperty = struct {
        fn f(this: *anyopaque, index: u32, out: *?*anyopaque) callconv(.winapi) HRESULT {
            const e = Effect.fromInterop(this);
            if (index >= e.property_count) return e_invalidarg;
            const p = e.properties[index].?;
            winrt.addRef(p);
            out.* = p;
            return 0;
        }
    }.f,
    .GetSource = struct {
        fn f(this: *anyopaque, index: u32, out: *?*anyopaque) callconv(.winapi) HRESULT {
            const e = Effect.fromInterop(this);
            if (index >= e.source_count) return e_invalidarg;
            const s = e.sources[index].?;
            winrt.addRef(s);
            out.* = s;
            return 0;
        }
    }.f,
    .GetSourceCount = struct {
        fn f(this: *anyopaque, count: *u32) callconv(.winapi) HRESULT {
            count.* = Effect.fromInterop(this).source_count;
            return 0;
        }
    }.f,
};
