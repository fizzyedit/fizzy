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

/// `event`'s payload read as `T`, in `arena`. Fields the payload has and `T` lacks are skipped, so
/// an emitter can grow a payload without breaking its listeners.
pub fn parse(comptime T: type, arena: std.mem.Allocator, event: Event) !T {
    const text = std.mem.trim(u8, event.payload, " \t\r\n");
    const source = try arena.dupeSentinel(u8, if (text.len == 0) ".{}" else text, 0);
    var diag: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(T, .{ .gpa = arena, .arena = arena, .source = source, .diagnostics = &diag, .ignore_unknown_fields = true });
}

// ---- what fizzy announces ----
//
// `fizzy.folder.opened`, `fizzy.folder.closed`: the project folder, `Path`. Closed comes first
// when one folder replaces another, and names the folder that was open: by the time it is heard,
// `Host.folder()` is already the next one (or null), so state kept for the old folder is saved to
// `path`, never to `Host.folder()`. A plugin loaded while a folder is open reads `Host.folder()`
// at registration; it was not listening when that folder opened.
//
// `fizzy.document.opened`, `.saved`, `.closed`: a document, `Path`. `fizzy.document.changed`: an
// open document's unsaved contents settled after an edit (`Host.notifyDocumentContentChanged`,
// called by its owner after a lull in typing, never per keystroke). It names the document only,
// and the disk still holds the saved version. A listener that wants the unsaved text asks the
// owner for it, and only for documents it cares about: `host.docFromPath(path)`, then
// `doc.owner.documentBytes(doc, path, allocator)`.
//
// `fizzy.files.changed`: files under the project folder changed on disk, `FilesChanged`.
//
// `fizzy.files.reveal`: a path was just made and should be shown the way a new file is: revealed
// in whatever lists the project's files, selected, its name open for editing. `Path`. Emitted by
// fizzy's `files` service (`reveal`), for a plugin's New flow or its own.

/// The payload of fizzy's folder and document events.
pub const Path = struct {
    /// Absolute; a mount's path (`gdrive://…`) for a document on one. Empty for an unsaved buffer.
    path: []const u8,
};

/// One change on disk under the project folder.
pub const PathEvent = struct {
    /// Absolute path of the affected object.
    path: []const u8,
    kind: Kind,
    object: ObjectType = .unknown,
    /// The pre-rename path, for `.renamed` only, and only on platforms whose watcher can pair the
    /// two halves (Linux, Windows). Elsewhere a rename arrives as `.deleted` + `.created`, which is
    /// why a listener must handle that shape regardless.
    old_path: []const u8 = "",

    pub const Kind = enum { created, modified, deleted, renamed };
    /// `.unknown` happens when the object is already gone by the time fizzy looks (a delete on
    /// Windows, mostly): treat it as "could be either".
    pub const ObjectType = enum { file, dir, unknown };
};

/// `fizzy.files.changed`: a coalesced batch of changes on disk under the project folder, from
/// anyone (an agent, a `git checkout`, another editor), files nothing has open included.
///
/// - **Coalesced** (~200 ms) so one save does not arrive as five events, and already **filtered**
///   against fizzy's ignore rules: `.git`, build output and gitignored paths never appear.
/// - **Best-effort.** Not every platform has a watcher (`Host.folderWatchActive`), and one can drop
///   changes under load: then `truncated` is set and `events` is incomplete, so rescan rather
///   than trust the list (a build, a branch switch, an npm install). Treat it as a prompt to go
///   look, not a ledger; a plugin that must stay correct keeps a slow rescan for when no watch runs.
/// - The project's file set (`Host.files`) is already updated by the time it is heard.
pub const FilesChanged = struct {
    events: []const PathEvent,
    truncated: bool = false,
};

/// An emitted event, waiting for delivery: the host's own copies.
pub const Queued = struct {
    name: []u8,
    payload: []u8,
};

test "a payload parses as its type, skipping what the type lacks" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const changed = try parse(FilesChanged, arena.allocator(), .{
        .name = "fizzy.files.changed",
        .payload = ".{ .events = .{ .{ .path = \"/p/a.md\", .kind = .renamed, .object = .file, .old_path = \"/p/b.md\" } }, .truncated = true, .later = 1 }",
    });
    try std.testing.expectEqual(@as(usize, 1), changed.events.len);
    try std.testing.expectEqualStrings("/p/b.md", changed.events[0].old_path);
    try std.testing.expectEqual(PathEvent.Kind.renamed, changed.events[0].kind);
    try std.testing.expect(changed.truncated);
    const closed = try parse(Path, arena.allocator(), .{ .name = "fizzy.folder.closed", .payload = ".{ .path = \"/p\" }" });
    try std.testing.expectEqualStrings("/p", closed.path);
}

test "a subscription takes its name, its prefix, or everything" {
    try std.testing.expect(matches("fizzy.document.saved", "fizzy.document.saved"));
    try std.testing.expect(!matches("fizzy.document.saved", "fizzy.document.opened"));
    try std.testing.expect(matches("fizzy.document.*", "fizzy.document.opened"));
    try std.testing.expect(!matches("fizzy.document.*", "fizzy.folder.opened"));
    try std.testing.expect(matches("*", "chat.turn_ended"));
}
