//! Files the OS asks the running app to open: on macOS a double-click on a document that names
//! the app (an Apple Event, not a new process), anywhere a file dropped on the window — handed to
//! the app as they arrive, cold launch included.
const std = @import("std");
const dvui = @import("dvui");
const c = @import("backend").c;
const window = @import("window.zig");

/// What the app does with a file the OS hands it (`install`).
var sink: ?*const fn (path: []const u8) void = null;

// ----------------------------------------------------------------------------
// File-open-from-OS routing.
//
// On macOS, double-clicking a registered document type in Finder fires an
// `openFiles:` Apple Event rather than spawning a new process — so our
// singleton's argv-forwarding path never sees it. SDL3 translates the event
// into `SDL_EVENT_DROP_FILE` on the running app. We install an event watch
// that queues the path into the singleton's pending list so `drainPending`
// opens it on the next frame.
// ----------------------------------------------------------------------------

fn handleSdlFileEvent(event: ?*c.SDL_Event) void {
    const e = event orelse return;
    if (e.type != c.SDL_EVENT_DROP_FILE) return;
    const data_ptr = e.drop.data orelse return;
    const path = std.mem.span(data_ptr);
    if (sink) |f| f(path);
    // Best-effort: raise the window.
    if (window.main()) |w| _ = c.SDL_RaiseWindow(w);
}

fn sdlFileOpenEventWatch(_: ?*anyopaque, event: ?*c.SDL_Event) callconv(.c) bool {
    handleSdlFileEvent(event);
    // SDL_AddEventWatch ignores the return value; keep the event in queue.
    return true;
}

fn sdlFileOpenDrainFilter(_: ?*anyopaque, event: ?*c.SDL_Event) callconv(.c) bool {
    handleSdlFileEvent(event);
    // Keep the event in the queue (dvui's backend will harmlessly ignore it).
    return true;
}

/// Register an SDL event watch so that file-open events from the OS get
/// queued into the singleton's pending list. Also drains any DROP_FILE
/// events that were queued before the watch was installed (cold-launch
/// via macOS "Open With" can queue the event during SDL init, before
/// `AppInit` runs). Caller must pass the dvui window (we capture its SDL
/// handle so the callback can raise the window without touching dvui TLS
/// state that is only valid mid-frame).
pub fn install(win: *dvui.Window, on_open: *const fn (path: []const u8) void) void {
    window.attach(win);
    sink = on_open;
    _ = c.SDL_AddEventWatch(sdlFileOpenEventWatch, null);
    c.SDL_FilterEvents(sdlFileOpenDrainFilter, null);
}
