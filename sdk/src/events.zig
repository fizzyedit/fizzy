//! Events: a plugin announces that something happened, and any plugin may listen, neither knowing
//! the other (plans/PLUGIN_INTERACTION_PLAN.md). Plugins meet on a name, never on each other.
//!
//! - **Names** are `<emitter>.<event>`, the emitter's id first, like commands:
//!   `fizzy.document.saved`, `chat.turn_ended`. Fizzy's own are under `fizzy.`.
//! - **Payloads** are ZON, like command arguments: bytes across the boundary, types on each side.
//!   The host copies a payload at `Host.emit`; a handler borrows it for the call.
//! - **Subscribing** is by name, by prefix (`"fizzy.document.*"`) or to everything (`"*"`, for an
//!   agent's bridge or the devtools). A subscription goes with its plugin (`unregisterPlugin`,
//!   `withdrawPlugin`), so a handler never outlives its image.
//! - **Delivery** is queued and happens on the UI thread once a frame, before plugins'
//!   `beginFrame`, in the order emitted: never inside `emit`. So a handler that emits queues for
//!   the next delivery, nothing runs at a surprising moment, and `emit` is safe from any thread.
//! - **Declaring** an event (`Host.declareEvent`) says what it means and what its payload holds,
//!   so tooling and agents can list what a plugin announces. Emitting an undeclared name works.
const std = @import("std");
const Plugin = @import("Plugin.zig");

/// One event as a handler sees it: borrowed for the call.
pub const Event = struct {
    name: []const u8,
    /// ZON; empty for an event that carries nothing.
    payload: []const u8,
};

pub const Subscription = struct {
    /// An event's name, a prefix ending in `*` (`"fizzy.document.*"`), or `"*"` for every event.
    event: []const u8,
    /// The listening plugin, whose state the handler is called with. Its subscriptions go with it.
    owner: ?*Plugin = null,
    handler: *const fn (state: *anyopaque, event: Event) void,
};

/// What an event means, for whoever lists them (the devtools, an agent). Optional: an event is
/// emitted and heard whether or not it is declared.
pub const Declaration = struct {
    name: []const u8,
    owner: ?*Plugin = null,
    /// When it is emitted, in a sentence.
    description: []const u8,
    /// Its payload's shape, as ZON a reader would recognize: `.{ .path = "…" }`. Empty for none.
    payload: []const u8 = "",
};

/// Whether `pattern` (a name, `prefix*`, or `*`) takes the event `name`.
pub fn matches(pattern: []const u8, name: []const u8) bool {
    if (pattern.len > 0 and pattern[pattern.len - 1] == '*') return std.mem.startsWith(u8, name, pattern[0 .. pattern.len - 1]);
    return std.mem.eql(u8, pattern, name);
}

/// An emitted event, waiting for delivery: the host's own copies.
pub const Queued = struct {
    name: []u8,
    payload: []u8,
};

test "a subscription takes its name, its prefix, or everything" {
    try std.testing.expect(matches("fizzy.document.saved", "fizzy.document.saved"));
    try std.testing.expect(!matches("fizzy.document.saved", "fizzy.document.opened"));
    try std.testing.expect(matches("fizzy.document.*", "fizzy.document.opened"));
    try std.testing.expect(!matches("fizzy.document.*", "fizzy.folder.opened"));
    try std.testing.expect(matches("*", "chat.turn_ended"));
}
