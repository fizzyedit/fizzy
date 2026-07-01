//! A prebuilt plugin dylib. It imports `core` (the dvui stand-in) and compiles
//! its OWN copy of that code. It draws by calling core.label(), exactly as a real
//! fizzy plugin would call dvui.label() to render into the host's window — using
//! the host's Window, the host's arena allocator, and the host's FreeType handle.
const std = @import("std");
const core = @import("core");

/// Mechanism B: the host injects its dvui state into the plugin's own globals
/// before asking it to draw. (current_window per-frame; ft2lib at init.)
export fn plugin_set_context(w: ?*core.Window, ft: ?*core.FreeType) callconv(.c) void {
    core.setCurrentWindow(w);
    core.setFreeType(ft);
}

/// The plugin "renders" three labels into the current Window. Returns the length
/// of the last allocated string (proving it allocated via the host's arena).
export fn plugin_draw() callconv(.c) usize {
    const a = core.label("file.fiz") catch return 0;
    const b = core.label("sprite.png") catch return 0;
    const c = core.label("readme.md") catch return 0;
    _ = a;
    _ = b;
    return c.len;
}

export fn plugin_current_window_addr() callconv(.c) usize {
    return core.currentWindowAddr();
}
