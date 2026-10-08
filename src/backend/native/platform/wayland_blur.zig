//! The desktop's blur behind a Wayland window: `ext-background-effect-v1`, the protocol GNOME
//! (Mutter 51) and KDE (Plasma 6.7) both have, and before it KDE's own `org_kde_kwin_blur`
//! (`docs/WINDOWS_LINUX_GLASS_PLAN.md`). The window asks for a region of its surface to be
//! blurred behind; the compositor draws the blur, at a strength of its own.
//!
//! The region is surface state, double-buffered: set before a frame is presented, it changes
//! with the commit that frame's present makes (Vulkan's WSI commits the surface, on the same
//! connection, after these requests), so a resized window's blur and picture change together.
//!
//! libwayland-client is opened at runtime, as SDL opens it, and what is called of it is declared
//! here by hand: the two protocols' few requests are marshalled from argument arrays, and their
//! objects live on an event queue of their own, so nothing here dispatches SDL's events or SDL
//! ours. Linux only; a no-op elsewhere.
const std = @import("std");
const builtin = @import("builtin");
const blur_region = @import("blur_region.zig");

/// Where the blur goes: `frame` (surface units, from the surface's top left) with its corners
/// rounded by `radius`.
pub const Want = struct {
    frame: blur_region.Rect,
    radius: f32,
};

/// Blur behind `surface` (a `wl_surface` of `display`, SDL's) as `want` says, or none: whether
/// the compositor blurs behind windows at all — it has one of the protocols, and its blur is on.
/// Cheap to call every frame: the region is sent only when it changes. The first call binds the
/// protocols, two round trips to the compositor.
pub fn behind(display: *anyopaque, surface: *anyopaque, want: ?Want) bool {
    if (comptime builtin.os.tag != .linux) return false;
    const s = ready(display) orelse return false;
    // What the compositor has said since (the blur turned off or on).
    _ = s.lib.display_dispatch_queue_pending(s.display, s.queue);
    const kind: Kind = if (s.effect_manager != null and s.effect_blur) .ext else if (s.kde_manager != null) .kde else {
        // Gone: when it comes back, the region is sent again (`ext-background-effect-v1` drops
        // what was set while it was away).
        s.sent = null;
        return false;
    };
    if (s.surface != surface or s.effect_kind != kind) {
        // First, or another window: the effect object is made for this surface as it is needed.
        if (s.effect) |e| destroyEffect(s, e);
        s.effect_kind = kind;
        s.surface = surface;
        s.sent = null;
    }
    if (s.sent) |sent| if (std.meta.eql(sent, want)) return true;
    if (want == null and kind == .kde) {
        // KWin blurs the whole window behind a blur object with an empty region: none is no
        // blur object at all.
        if (s.effect) |e| {
            var args = [_]Argument{.{ .o = @ptrCast(surface) }};
            _ = s.lib.proxy_marshal_array_flags(s.kde_manager.?, 1, null, s.lib.proxy_get_version(s.kde_manager.?), 0, &args);
            destroyEffect(s, e);
        }
    } else {
        if (s.effect == null) s.effect = createEffect(s, kind, @ptrCast(surface)) orelse return false;
        setRegion(s, want);
    }
    s.sent = want;
    return true;
}

// ---- libwayland-client, by hand ------------------------------------------------------------

const Proxy = opaque {};
const EventQueue = opaque {};

const Message = extern struct {
    name: [*:0]const u8,
    signature: [*:0]const u8,
    types: [*]const ?*const Interface,
};

const Interface = extern struct {
    name: [*:0]const u8,
    version: c_int,
    method_count: c_int,
    methods: ?[*]const Message,
    event_count: c_int,
    events: ?[*]const Message,
};

const Argument = extern union {
    i: i32,
    u: u32,
    f: i32,
    s: ?[*:0]const u8,
    o: ?*Proxy,
    n: u32,
    a: ?*anyopaque,
    h: i32,
};

/// `WL_MARSHAL_FLAG_DESTROY`: the request is the object's destructor.
const marshal_destroy: u32 = 1;

/// What is called of libwayland-client: each field is the symbol `wl_<name>`.
const Lib = struct {
    display_create_queue: *const fn (*Proxy) callconv(.c) ?*EventQueue,
    proxy_create_wrapper: *const fn (*Proxy) callconv(.c) ?*Proxy,
    proxy_wrapper_destroy: *const fn (*Proxy) callconv(.c) void,
    proxy_set_queue: *const fn (*Proxy, ?*EventQueue) callconv(.c) void,
    proxy_marshal_array_flags: *const fn (*Proxy, u32, ?*const Interface, u32, u32, ?[*]Argument) callconv(.c) ?*Proxy,
    proxy_add_listener: *const fn (*Proxy, *const anyopaque, ?*anyopaque) callconv(.c) c_int,
    proxy_get_version: *const fn (*Proxy) callconv(.c) u32,
    display_roundtrip_queue: *const fn (*Proxy, *EventQueue) callconv(.c) c_int,
    display_dispatch_queue_pending: *const fn (*Proxy, *EventQueue) callconv(.c) c_int,
    registry_interface: *const Interface,
    compositor_interface: *const Interface,
    region_interface: *const Interface,
    surface_interface: *const Interface,
};

fn load() ?Lib {
    // SDL's own copy, already loaded for the window: never a second one.
    const handle = std.c.dlopen("libwayland-client.so.0", .{ .LAZY = true, .NOLOAD = true }) orelse return null;
    var lib: Lib = undefined;
    inline for (@typeInfo(Lib).@"struct".fields) |f| {
        const sym = std.c.dlsym(handle, "wl_" ++ f.name) orelse return null;
        @field(lib, f.name) = @ptrCast(@alignCast(sym));
    }
    return lib;
}

// ---- the two protocols, as wayland-scanner would declare them --------------------------------
//
// From `ext-background-effect-v1.xml` (wayland-protocols, staging) and KDE's `blur.xml`
// (plasma-wayland-protocols). The core interfaces their requests name are libwayland's, found
// when it is opened (`ready`).

var no_types = [_]?*const Interface{ null, null, null, null };
var effect_get_types = [_]?*const Interface{ &effect_surface_interface, null };
var region_types = [_]?*const Interface{null};
var kde_create_types = [_]?*const Interface{ &kde_blur_interface, null };
var kde_surface_types = [_]?*const Interface{null};

const effect_manager_requests = [_]Message{
    .{ .name = "destroy", .signature = "", .types = &no_types },
    .{ .name = "get_background_effect", .signature = "no", .types = &effect_get_types },
};
const effect_manager_events = [_]Message{
    .{ .name = "capabilities", .signature = "u", .types = &no_types },
};
const effect_manager_interface: Interface = .{
    .name = "ext_background_effect_manager_v1",
    .version = 1,
    .method_count = effect_manager_requests.len,
    .methods = &effect_manager_requests,
    .event_count = effect_manager_events.len,
    .events = &effect_manager_events,
};
const effect_surface_requests = [_]Message{
    .{ .name = "destroy", .signature = "", .types = &no_types },
    .{ .name = "set_blur_region", .signature = "?o", .types = &region_types },
};
const effect_surface_interface: Interface = .{
    .name = "ext_background_effect_surface_v1",
    .version = 1,
    .method_count = effect_surface_requests.len,
    .methods = &effect_surface_requests,
    .event_count = 0,
    .events = null,
};
const kde_manager_requests = [_]Message{
    .{ .name = "create", .signature = "no", .types = &kde_create_types },
    .{ .name = "unset", .signature = "o", .types = &kde_surface_types },
};
const kde_manager_interface: Interface = .{
    .name = "org_kde_kwin_blur_manager",
    .version = 1,
    .method_count = kde_manager_requests.len,
    .methods = &kde_manager_requests,
    .event_count = 0,
    .events = null,
};
const kde_blur_requests = [_]Message{
    .{ .name = "commit", .signature = "", .types = &no_types },
    .{ .name = "set_region", .signature = "?o", .types = &region_types },
    .{ .name = "release", .signature = "", .types = &no_types },
};
const kde_blur_interface: Interface = .{
    .name = "org_kde_kwin_blur",
    .version = 1,
    .method_count = kde_blur_requests.len,
    .methods = &kde_blur_requests,
    .event_count = 0,
    .events = null,
};

/// `ext_background_effect_manager_v1.capability.blur`.
const capability_blur: u32 = 1;

// ---- state ------------------------------------------------------------------------------------

const Kind = enum { ext, kde };

const State = struct {
    lib: Lib,
    display: *Proxy,
    queue: *EventQueue,
    compositor: ?*Proxy = null,
    effect_manager: ?*Proxy = null,
    /// The compositor blurs (`capabilities`); false until it says.
    effect_blur: bool = false,
    kde_manager: ?*Proxy = null,
    /// The surface the effect object is for, and the object.
    surface: ?*anyopaque = null,
    effect: ?*Proxy = null,
    effect_kind: Kind = .ext,
    /// The region last sent (null in it: none), or null when nothing has been sent since the
    /// effect object was made or the blur came back.
    sent: ??Want = null,
};

var state: State = undefined;
var tried = false;
var bound = false;

/// The protocols bound on `display`, once: null where libwayland or a compositor to ask is not
/// there.
fn ready(display: *anyopaque) ?*State {
    if (tried) return if (bound) &state else null;
    tried = true;
    const lib = load() orelse return null;
    region_types[0] = lib.region_interface;
    effect_get_types[1] = lib.surface_interface;
    kde_create_types[1] = lib.surface_interface;
    kde_surface_types[0] = lib.surface_interface;
    const d: *Proxy = @ptrCast(display);
    const queue = lib.display_create_queue(d) orelse return null;
    state = .{ .lib = lib, .display = d, .queue = queue };
    // The registry on our queue: made through a wrapper of the display that carries it, so
    // SDL's own queue sees nothing of it.
    const wrapper = lib.proxy_create_wrapper(d) orelse return null;
    lib.proxy_set_queue(wrapper, queue);
    var get_registry_args = [_]Argument{.{ .n = 0 }};
    const registry = lib.proxy_marshal_array_flags(wrapper, 1, lib.registry_interface, lib.proxy_get_version(wrapper), 0, &get_registry_args);
    lib.proxy_wrapper_destroy(wrapper);
    const reg = registry orelse return null;
    _ = lib.proxy_add_listener(reg, &registry_listener, null);
    // The globals (bound as they are announced), then what the effect manager says it can do.
    if (lib.display_roundtrip_queue(d, queue) < 0) return null;
    if (state.effect_manager != null) _ = lib.display_roundtrip_queue(d, queue);
    bound = state.compositor != null and (state.effect_manager != null or state.kde_manager != null);
    return if (bound) &state else null;
}

const RegistryListener = extern struct {
    global: *const fn (?*anyopaque, ?*Proxy, u32, [*:0]const u8, u32) callconv(.c) void,
    global_remove: *const fn (?*anyopaque, ?*Proxy, u32) callconv(.c) void,
};
const registry_listener: RegistryListener = .{ .global = onGlobal, .global_remove = onGlobalRemove };

fn onGlobal(_: ?*anyopaque, registry: ?*Proxy, name: u32, interface: [*:0]const u8, version: u32) callconv(.c) void {
    const reg = registry orelse return;
    const iface = std.mem.span(interface);
    if (std.mem.eql(u8, iface, "wl_compositor")) {
        // `create_region` is in every version.
        state.compositor = bind(reg, name, state.lib.compositor_interface, 1);
    } else if (std.mem.eql(u8, iface, "ext_background_effect_manager_v1")) {
        const m = bind(reg, name, &effect_manager_interface, @min(version, 1)) orelse return;
        state.effect_manager = m;
        _ = state.lib.proxy_add_listener(m, &effect_manager_listener, null);
    } else if (std.mem.eql(u8, iface, "org_kde_kwin_blur_manager")) {
        state.kde_manager = bind(reg, name, &kde_manager_interface, @min(version, 1));
    }
}

/// A global going away mid-session (a compositor restarting its blur): not followed. The
/// effect manager's `capabilities` says when the blur itself is off.
fn onGlobalRemove(_: ?*anyopaque, _: ?*Proxy, _: u32) callconv(.c) void {}

const EffectManagerListener = extern struct {
    capabilities: *const fn (?*anyopaque, ?*Proxy, u32) callconv(.c) void,
};
const effect_manager_listener: EffectManagerListener = .{ .capabilities = onCapabilities };

fn onCapabilities(_: ?*anyopaque, _: ?*Proxy, flags: u32) callconv(.c) void {
    state.effect_blur = flags & capability_blur != 0;
}

/// `wl_registry.bind`.
fn bind(registry: *Proxy, name: u32, interface: *const Interface, version: u32) ?*Proxy {
    var args = [_]Argument{ .{ .u = name }, .{ .s = interface.name }, .{ .u = version }, .{ .n = 0 } };
    return state.lib.proxy_marshal_array_flags(registry, 0, interface, version, 0, &args);
}

fn createEffect(s: *State, kind: Kind, surface: *Proxy) ?*Proxy {
    var args = [_]Argument{ .{ .n = 0 }, .{ .o = surface } };
    return switch (kind) {
        // `ext_background_effect_manager_v1.get_background_effect`.
        .ext => s.lib.proxy_marshal_array_flags(s.effect_manager.?, 1, &effect_surface_interface, s.lib.proxy_get_version(s.effect_manager.?), 0, &args),
        // `org_kde_kwin_blur_manager.create`.
        .kde => s.lib.proxy_marshal_array_flags(s.kde_manager.?, 0, &kde_blur_interface, s.lib.proxy_get_version(s.kde_manager.?), 0, &args),
    };
}

fn destroyEffect(s: *State, effect: *Proxy) void {
    // `destroy` and `release`: the region goes with the next commit.
    const opcode: u32 = switch (s.effect_kind) {
        .ext => 0,
        .kde => 2,
    };
    _ = s.lib.proxy_marshal_array_flags(effect, opcode, null, s.lib.proxy_get_version(effect), marshal_destroy, null);
    s.effect = null;
}

/// The effect's region as `want` says, made and let go: the protocols copy it. None is an empty
/// region, not a null one: null hands the surface back to the compositor's own choice, and some
/// blur every translucent window by default (Hyprland).
fn setRegion(s: *State, want: ?Want) void {
    const effect = s.effect orelse return;
    const version = s.lib.proxy_get_version(effect);
    // `wl_compositor.create_region`, then `wl_region.add` for each row.
    const compositor = s.compositor orelse return;
    var create_args = [_]Argument{.{ .n = 0 }};
    const region = s.lib.proxy_marshal_array_flags(compositor, 1, s.lib.region_interface, s.lib.proxy_get_version(compositor), 0, &create_args) orelse return;
    if (want) |w| {
        var rects: [blur_region.max_rects]blur_region.Rect = undefined;
        for (blur_region.rounded(w.frame, w.radius, &rects)) |r| {
            var add_args = [_]Argument{ .{ .i = r.x }, .{ .i = r.y }, .{ .i = r.w }, .{ .i = r.h } };
            _ = s.lib.proxy_marshal_array_flags(region, 1, null, s.lib.proxy_get_version(region), 0, &add_args);
        }
    }
    var set_args = [_]Argument{.{ .o = region }};
    switch (s.effect_kind) {
        // `ext_background_effect_surface_v1.set_blur_region`.
        .ext => _ = s.lib.proxy_marshal_array_flags(effect, 1, null, version, 0, &set_args),
        // `org_kde_kwin_blur.set_region`, then its `commit`: it takes effect with the surface's.
        .kde => {
            _ = s.lib.proxy_marshal_array_flags(effect, 1, null, version, 0, &set_args);
            _ = s.lib.proxy_marshal_array_flags(effect, 0, null, version, 0, null);
        },
    }
    // `wl_region.destroy`.
    _ = s.lib.proxy_marshal_array_flags(region, 0, null, s.lib.proxy_get_version(region), marshal_destroy, null);
}
