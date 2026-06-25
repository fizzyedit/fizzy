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
