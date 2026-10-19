//! Profiler scopes for the glass, recorded into the app's profiler (fizzy's `core.profile`) when
//! there is one, and nothing otherwise: a plain dvui app on fizzy's backend has none.
//!
//! The glass does not import the profiler: the profiler lives in fizzy's `core`, which the backend
//! does not depend on. The profiler hands its scopes over instead (`Hooks`): the host image sets
//! its own copy's (`host`) at the start of each frame, and publishes them through dvui's store, as
//! it publishes itself, for a plugin's copy of the glass to find (`hooks`) — so a plugin's frost
//! pane records into the app's profile as the plugin's own scopes do. Nothing is spent while no
//! profiler hands any over, or while it records nothing.
const std = @import("std");
const dvui = @import("dvui");

/// An open scope; `end` it (deferred) where the timed code ends. The profiler's own, as it hands it
/// back (`Hooks.begin`).
pub const Scope = extern struct {
    p: ?*anyopaque = null,
    idx: u16 = 0,

    pub fn end(self: Scope) void {
        if (self.p == null) return;
        if (hooks()) |h| h.end(self);
    }
};

/// The profiler's scopes, as the glass calls them: across images (a plugin's copy of the glass
/// calls the host's), so C-ABI and versioned.
pub const Hooks = extern struct {
    abi: u32 = abi,
    begin: *const fn (owner: [*]const u8, owner_len: usize, name: [*]const u8, name_len: usize) callconv(.c) Scope,
    end: *const fn (scope: Scope) callconv(.c) void,
};
pub const abi: u32 = 1;

/// The host image's hooks, set by its profiler each frame.
pub var host: ?*const Hooks = null;
/// Where the host publishes them for a plugin's copy (`dvui.dataSet`).
pub const publish_id: dvui.Id = @fromBackingInt(@intCast(0x6669_7a7a_676c_7373)); // "fizzygls"
pub const publish_key = std.fmt.comptimePrint("_glass_profile{d}", .{abi});

/// A plugin's copy of the hooks, once found.
var found: ?*const Hooks = null;

fn hooks() ?*const Hooks {
    if (host) |h| return h;
    if (found) |f| return f;
    // Outside a window — between frames, in a test — there is no store to ask.
    if (dvui.current_window == null) return null;
    const addr = dvui.dataGet(null, publish_id, publish_key, usize) orelse return null;
    const h: *const Hooks = @ptrFromInt(addr);
    if (h.abi != abi) return null;
    found = h;
    return h;
}

/// Time from here to `end` as `name` under `owner`, nested under the scope already open.
pub fn begin(owner: []const u8, name: []const u8) Scope {
    const h = hooks() orelse return .{};
    return h.begin(owner.ptr, owner.len, name.ptr, name.len);
}
