//! The native backend's health counters as SDL feeds them (`SDLBackend.countSDLLog`): what SDL
//! logs at warning and error priority is counted, the first error kept, and every message still
//! reaches the log output SDL had before. SDL's log needs no window, so this runs headless.
const std = @import("std");
const backend = @import("backend");
const c = backend.c;
const Health = backend.Health;

/// What reached the output function that was SDL's before the counter took it.
var seen: [8][64]u8 = undefined;
var seen_n: usize = 0;

fn earlier(_: ?*anyopaque, _: c_int, _: c.SDL_LogPriority, message: [*c]const u8) callconv(.c) void {
    const m = std.mem.span(message);
    const n = @min(m.len, 64);
    @memcpy(seen[seen_n][0..n], m[0..n]);
    seen[seen_n][n] = 0;
    seen_n += 1;
}

test "SDL's warnings and errors are counted, and passed on to the output it had" {
    c.SDL_SetLogOutputFunction(@ptrCast(&earlier), null);
    c.SDL_SetLogPriorities(c.SDL_LOG_PRIORITY_INFO);
    const before = Health.current.snapshot();

    backend.countSDLLog();
    backend.countSDLLog(); // once: a second call does not chain the counter to itself
    c.SDL_Log("an info line");
    c.SDL_LogWarn(c.SDL_LOG_CATEGORY_GPU, "a warning");
    c.SDL_LogError(c.SDL_LOG_CATEGORY_VIDEO, "the first error");
    c.SDL_LogCritical(c.SDL_LOG_CATEGORY_RENDER, "a critical one");

    const after = Health.current.snapshot();
    try std.testing.expectEqual(before.sdl_warnings + 1, after.sdl_warnings);
    try std.testing.expectEqual(before.sdl_errors + 2, after.sdl_errors);
    try std.testing.expectEqualStrings("the first error", after.first_sdl_error);
    // Every message, each once, in order.
    try std.testing.expectEqual(@as(usize, 4), seen_n);
    try std.testing.expectEqualStrings("an info line", std.mem.sliceTo(&seen[0], 0));
    try std.testing.expectEqualStrings("a critical one", std.mem.sliceTo(&seen[3], 0));
}
