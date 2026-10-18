//! Wire a loaded plugin dylib's dvui globals to the host's live state.
//!
//! Host and plugin each compile their own `dvui` copy; before plugin draw/tick the host
//! calls the plugin's `fizzy_plugin_set_dvui_context` export (see `dylib.zig`).
const dvui = @import("dvui");

/// C ABI setter type shared by host loader and plugin dylib export.
pub const SetContextFn = *const fn (
    window: ?*dvui.Window,
    io: ?*anyopaque,
    ft2lib: ?*anyopaque,
    debug: ?*dvui.Debug,
) callconv(.c) void;

/// Set this compilation unit's dvui globals from host-owned pointers.
pub fn inject(
    window: ?*dvui.Window,
    io: ?*anyopaque,
    ft2lib: ?*anyopaque,
    debug: ?*dvui.Debug,
) void {
    if (window) |w| dvui.current_window = w;
    if (io) |i| {
        const io_ptr: *@TypeOf(dvui.io) = @ptrCast(@alignCast(i));
        dvui.io = io_ptr.*;
    }
    if (comptime dvui.useFreeType) {
        if (ft2lib) |ft| {
            const ft_ptr: *@TypeOf(dvui.ft2lib) = @ptrCast(@alignCast(ft));
            dvui.ft2lib = ft_ptr.*;
        }
    }
    if (debug) |d| dvui.debug = d.*;
    if (window != null) {
        applyDragThreshold();
        // This image's dvui animates, or does not, as the host's does (`core.motion.publish`).
        @import("core").motion.apply();
        // This image's threads record spans into the host's (`core.profile.span`).
        @import("core").profile.adopt();
    }
}

/// How far a finger may drift and still tap (natural px). dvui's 3 is a mouse's slop: a
/// fingertip wanders further than that between down and up, and past it a button cancels its
/// click (it reads as the start of a scroll or drag) and a held context menu gives up its
/// hold. Taps on small targets — a tab's close button, a swatch — failed about as often as
/// they landed.
pub const touch_drag_threshold: f32 = 10;
/// dvui's own default, for the mouse.
pub const mouse_drag_threshold: f32 = 3;

/// Where the host records whether input is touch, in the shared window's data — every dylib's
/// copy of dvui has its own `Dragging.threshold`, and this is how they agree on it.
const input_id: dvui.Id = @fromBackingInt(@intCast(0x6669_7a7a_795f_7463)); // "fizzy_tc"
const input_key = "_touch_input";

/// Host only, once a frame before anything handles input: note whether the pointer is a finger
/// (the latest pointer press or motion was touch) and set this image's drag threshold to match.
/// Plugin images pick it up in `inject`, which the host calls before they draw.
pub fn syncTouchInput() void {
    var touch = dvui.dataGet(null, input_id, input_key, bool) orelse false;
    for (dvui.events()) |e| {
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        switch (me.action) {
            .press, .motion => {
                if (me.button.touch()) touch = true else if (me.button.pointer() or me.action == .motion) touch = false;
            },
            else => {},
        }
    }
    dvui.dataSet(null, input_id, input_key, touch);
    applyDragThreshold();
}

fn applyDragThreshold() void {
    const touch = dvui.dataGet(null, input_id, input_key, bool) orelse false;
    dvui.Dragging.threshold = if (touch) touch_drag_threshold else mouse_drag_threshold;
}

/// Push the host exe's current dvui state into a loaded plugin image.
pub fn syncHostIntoPlugin(setter: SetContextFn) void {
    setter(
        dvui.current_window,
        @ptrCast(&dvui.io),
        if (comptime dvui.useFreeType) @ptrCast(&dvui.ft2lib) else null,
        &dvui.debug,
    );
}
