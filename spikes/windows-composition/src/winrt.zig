//! Just enough of Windows.UI.Composition to answer the spike, called by vtable slot.
//!
//! zig's MinGW headers carry no C++/WinRT and zigwin32 has only the interop interfaces, so every
//! WinRT interface here is a GUID and the slots of the methods called. Both were read from
//! `C:\Windows\System32\WinMetadata\Windows.UI.winmd` (and Windows.Graphics, Windows.Foundation,
//! Windows.System) with System.Reflection.Metadata: slot 0-2 are IUnknown's, 3-5 IInspectable's,
//! and a WinRT interface's own methods follow in metadata order, overloads included. A WinRT
//! method returns HRESULT; its result, if any, is a last out-parameter.
const std = @import("std");
const win32 = @import("win32");

pub const Guid = win32.zig.Guid;
pub const HRESULT = i32;
pub const HSTRING = ?*anyopaque;
pub const Obj = *anyopaque;

pub const Vec2 = extern struct { x: f32, y: f32 };
pub const Vec3 = extern struct { x: f32, y: f32, z: f32 };

const log = std.log.scoped(.winrt);

pub fn check(hr: HRESULT, what: []const u8) !void {
    if (hr < 0) {
        log.err("{s}: HRESULT 0x{x:0>8}", .{ what, @as(u32, @bitCast(hr)) });
        return error.ComFailed;
    }
}

fn slot(obj: Obj, comptime i: usize) usize {
    const vtbl: *const [*]const usize = @ptrCast(@alignCast(obj));
    return vtbl.*[i];
}

/// Method `i` of `obj`'s vtable, as `F`.
pub fn method(comptime F: type, obj: Obj, comptime i: usize) F {
    return @ptrFromInt(slot(obj, i));
}

pub fn qi(obj: Obj, iid: *const Guid, what: []const u8) !Obj {
    var out: ?*anyopaque = null;
    try check(method(*const fn (Obj, *const Guid, *?*anyopaque) callconv(.winapi) HRESULT, obj, 0)(obj, iid, &out), what);
    return out.?;
}

/// `qi`, null where the interface is not there (an older Windows).
pub fn tryQi(obj: Obj, iid: *const Guid) ?Obj {
    var out: ?*anyopaque = null;
    if (method(*const fn (Obj, *const Guid, *?*anyopaque) callconv(.winapi) HRESULT, obj, 0)(obj, iid, &out) < 0) return null;
    return out;
}

pub fn addRef(obj: Obj) void {
    _ = method(*const fn (Obj) callconv(.winapi) u32, obj, 1)(obj);
}

pub fn release(obj: Obj) void {
    _ = method(*const fn (Obj) callconv(.winapi) u32, obj, 2)(obj);
}

/// A method taking nothing and giving one interface pointer.
pub fn get(obj: Obj, comptime i: usize, what: []const u8) !Obj {
    var out: ?*anyopaque = null;
    try check(method(*const fn (Obj, *?*anyopaque) callconv(.winapi) HRESULT, obj, i)(obj, &out), what);
    return out orelse error.ComFailed;
}

/// A method taking one value of type `T` and giving nothing (a setter, mostly).
pub fn put(comptime T: type, obj: Obj, comptime i: usize, value: T, what: []const u8) !void {
    try check(method(*const fn (Obj, T) callconv(.winapi) HRESULT, obj, i)(obj, value), what);
}

// ---- HSTRING and activation, from combase at runtime (no import library needed) ---------------

pub fn hstring(comptime s: []const u8) !HSTRING {
    const w = comptime std.unicode.utf8ToUtf16LeStringLiteral(s);
    var h: ?win32.system.win_rt.HSTRING = null;
    try check(win32.system.win_rt.WindowsCreateString(w, w.len, &h), "WindowsCreateString");
    return @ptrCast(h);
}

const Ro = struct {
    RoInitialize: *const fn (u32) callconv(.winapi) HRESULT,
    RoActivateInstance: *const fn (HSTRING, *?*anyopaque) callconv(.winapi) HRESULT,
    RoGetActivationFactory: *const fn (HSTRING, *const Guid, *?*anyopaque) callconv(.winapi) HRESULT,
};
var ro: Ro = undefined;

const DispatcherQueueOptions = extern struct {
    dwSize: u32 = @sizeOf(DispatcherQueueOptions),
    threadType: u32, // DQTYPE_THREAD_CURRENT = 2
    apartmentType: u32, // DQTAT_COM_NONE = 0
};

fn sym(comptime T: type, dll: [*:0]const u8, name: [*:0]const u8) !T {
    const lib = win32.system.library_loader.LoadLibraryA(dll) orelse return error.NoLibrary;
    const p = win32.system.library_loader.GetProcAddress(lib, name) orelse return error.NoSymbol;
    return @ptrCast(p);
}

/// WinRT on this thread, and a DispatcherQueue on it: composition commits on the queue's tick,
/// which runs from this thread's message pump (SDL's). Returns the queue controller.
pub fn initThread() !Obj {
    inline for (@typeInfo(Ro).@"struct".fields) |f|
        @field(ro, f.name) = try sym(f.type, "combase.dll", f.name ++ "");
    // RO_INIT_SINGLETHREADED: S_FALSE or RPC_E_CHANGED_MODE when SDL got there first, both fine.
    _ = ro.RoInitialize(0);
    const create = try sym(*const fn (DispatcherQueueOptions, *?*anyopaque) callconv(.winapi) HRESULT, "CoreMessaging.dll", "CreateDispatcherQueueController");
    var controller: ?*anyopaque = null;
    try check(create(.{ .threadType = 2, .apartmentType = 0 }, &controller), "CreateDispatcherQueueController");
    return controller.?;
}

pub fn activate(comptime class: []const u8) !Obj {
    var out: ?*anyopaque = null;
    try check(ro.RoActivateInstance(try hstring(class), &out), "RoActivateInstance " ++ class);
    return out.?;
}

pub fn factory(comptime class: []const u8, iid: *const Guid) !Obj {
    var out: ?*anyopaque = null;
    try check(ro.RoGetActivationFactory(try hstring(class), iid, &out), "RoGetActivationFactory " ++ class);
    return out.?;
}

// ---- interfaces -----------------------------------------------------------------------------

fn g(comptime s: []const u8) Guid {
    return Guid.initString(s);
}

pub const IID_IUnknown = g("00000000-0000-0000-c000-000000000046");
pub const IID_IInspectable = g("af86e2e0-b12d-4c6a-9c5a-d7aa65101e90");
pub const IID_IAgileObject = g("94ea2b94-e9cc-49e0-c0ff-ee64ca8f5b90");

pub const IID_ICompositor = g("b403ca50-7f8c-4e83-985f-cc45060036d8");
pub const IID_ICompositor2 = g("735081dc-5e24-45da-a38f-e32cc349a9a0");
pub const IID_ICompositor3 = g("c9dd8ef0-6eb1-4e3c-a658-675d9c64d4ab");
pub const IID_ICompositor5 = g("48ea31ad-7fcd-4076-a79c-90cc4b852c9b");
pub const IID_ICompositor6 = g("7a38b2bd-cec8-4eeb-830f-d8d07aedebc3");
pub const IID_ICompositor7 = g("d3483fad-9a12-53ba-bfc8-88b7ff7977c6");
pub const IID_ICompositorDesktopInterop = g("29e691fa-4567-4dca-b319-d0f207eb6807");
pub const IID_ICompositorInterop = g("25297d5c-3ad4-4c9c-b5cf-e36a38512330");

pub const IID_ICompositionTarget = g("a1bea8ba-d726-4663-8129-6b5e7927ffa6");
pub const IID_IDesktopWindowTarget = g("6329d6ca-3366-490e-9db3-25312929ac51");
pub const IID_IVisual = g("117e202d-a859-4c89-873b-c2aa566788e3");
pub const IID_IContainerVisual = g("02f6bc74-ed20-4773-afe6-d49b4a93db32");
pub const IID_ISpriteVisual = g("08e05581-1ad1-4f97-9757-402d76e4233b");
pub const IID_ICompositionBrush = g("ab0d7608-30c0-40e9-b568-b60a6bd1fb46");
pub const IID_ICompositionClip = g("1ccd2a52-cfc7-4ace-9983-146bb8eb6a3c");
pub const IID_IRectangleClip = g("b3e7549e-00b4-5b53-8be8-353f6c433101");
pub const IID_ICompositionGeometricClip = g("c840b581-81c9-4444-a2c1-ccaece3a50e5");
pub const IID_ICompositionGeometry = g("e985217c-6a17-4207-abd8-5fd3dd612a9d");
pub const IID_ICompositionPathGeometry = g("0b6a417e-2c77-4c23-af5e-6304c147bb61");
pub const IID_ICompositionPathFactory = g("9c1e8c6a-0f33-4751-9437-eb3fb9d3ab07");
pub const IID_ICompositionEffectFactory = g("be5624af-ba7e-4510-9850-41c0b4ff74df");
pub const IID_ICompositionEffectBrush = g("bf7f795e-83cc-44bf-a447-3e3c071789ec");
pub const IID_ICompositionEffectSourceParameterFactory = g("b3d9f276-aba3-4724-acf3-d0397464db1c");
pub const IID_ICompositionSurfaceBrush = g("ad016d79-1e4c-4c0d-9c29-83338c87c162");

pub const IID_IGeometrySource2D = g("caff7902-670c-4181-a624-da977203b845");
pub const IID_IGeometrySource2DInterop = g("0657af73-53fd-47cf-84ff-c8492d2a80a3");
pub const IID_IGraphicsEffect = g("cb51c0ce-8fe6-4636-b202-861faa07d8f3");
pub const IID_IGraphicsEffectSource = g("2d8f9ddc-4339-4eb9-9216-f9deb75658a2");
pub const IID_IGraphicsEffectD2D1Interop = g("2fc57384-a068-44d7-a331-30982fcf7177");
pub const IID_IPropertyValueStatics = g("629bdbc8-d932-4ff4-96b9-8d96c5c1e858");
pub const IID_IPropertyValue = g("4bd682dd-7554-40e9-9a9b-82654ede7e62");

/// The slots called, by interface (see the file comment for where they come from).
pub const slots = struct {
    pub const ICompositor = struct {
        pub const CreateColorBrushWithColor = 8;
        pub const CreateContainerVisual = 9;
        pub const CreateEffectFactory = 11;
        pub const CreateSpriteVisual = 22;
        pub const CreateSurfaceBrushWithSurface = 24;
    };
    pub const ICompositor3 = struct {
        pub const CreateHostBackdropBrush = 6;
    };
    pub const ICompositor5 = struct {
        pub const CreatePathGeometry = 16;
    };
    pub const ICompositor6 = struct {
        pub const CreateGeometricClipWithGeometry = 7;
    };
    pub const ICompositor7 = struct {
        pub const CreateRectangleClip = 8;
    };
    pub const ICompositorDesktopInterop = struct {
        pub const CreateDesktopWindowTarget = 3; // IUnknown-based: (HWND, BOOL isTopmost, **target)
    };
    pub const ICompositorInterop = struct {
        pub const CreateCompositionSurfaceForSwapChain = 4; // IUnknown-based: (IUnknown*, **surface)
    };
    pub const IDesktopWindowTarget = struct {
        pub const get_IsTopmost = 6;
    };
    pub const ICompositionTarget = struct {
        pub const put_Root = 7;
    };
    pub const IContainerVisual = struct {
        pub const get_Children = 6;
    };
    pub const IVisualCollection = struct {
        pub const InsertAtTop = 9;
    };
    pub const ISpriteVisual = struct {
        pub const put_Brush = 7;
    };
    pub const IVisual = struct {
        pub const put_Clip = 15;
        pub const put_IsVisible = 19;
        pub const put_Offset = 21;
        pub const put_Opacity = 23;
        pub const put_Size = 36;
    };
    pub const IRectangleClip = struct {
        pub const put_Bottom = 7;
        pub const put_BottomLeftRadius = 9;
        pub const put_BottomRightRadius = 11;
        pub const put_Left = 13;
        pub const put_Right = 15;
        pub const put_Top = 17;
        pub const put_TopLeftRadius = 19;
        pub const put_TopRightRadius = 21;
    };
    pub const ICompositionPathGeometry = struct {
        pub const put_Path = 7;
    };
    pub const ICompositionPathFactory = struct {
        pub const Create = 6;
    };
    pub const ICompositionEffectFactory = struct {
        pub const CreateBrush = 6;
        pub const get_ExtendedError = 7;
        pub const get_LoadStatus = 8;
    };
    pub const ICompositionEffectBrush = struct {
        pub const SetSourceParameter = 7;
    };
    pub const ICompositionEffectSourceParameterFactory = struct {
        pub const Create = 6;
    };
    pub const IPropertyValueStatics = struct {
        pub const CreateUInt32 = 11;
    };
};

/// `Windows.UI.Color`: a, r, g, b bytes.
pub const Color = extern struct { a: u8, r: u8, g: u8, b: u8 };
