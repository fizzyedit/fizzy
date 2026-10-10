//! Watches `<config>/` (recursive) for external changes while fizzy is running — see
//! plans/PLUGIN_MANIFEST_PLAN.md R11/R12.
//!
//! Thin adapter over [`neurocyte/nightwatch`](https://github.com/neurocyte/nightwatch): one
//! recursive `watch(config_folder)` covers `settings.zon` reconciliation, discovery of
//! newly-created plugin directories under `plugins/`, and hot-reload of a plugin whose dylib was
//! rebuilt in place (`Editor.reconcileChangedPluginBinaries`). Nightwatch owns the thread; this
//! layer only implements its `Handler` (atomic flag + `backend.refresh()`, never file content /
//! `dvui.io` / a shared allocator from the callback) and a ~200ms coalesce on the main thread
//! via `tick`.
//!
//! `have_impl` is false on wasm and any unsupported OS — the watcher is simply not started
//! there (same "no filesystem" degrade-gracefully spirit as every other native-only guard in
//! this codebase), not a hard error.
const builtin = @import("builtin");
const std = @import("std");
const core = @import("core");
const sdk = @import("fizzy_sdk");
const wake = @import("wake.zig");
const dvui = @import("dvui");
const Allocator = std.mem.Allocator;

const SettingsWatcher = @This();

/// How long to keep coalescing further events before reacting, once the first one arrives.
/// A single logical save is often several raw filesystem events; this also gives a half-written
/// file a moment to finish before `Editor.reconcileExternalSettingsChange` reads it.
const debounce_ns: i128 = 200 * std.time.ns_per_ms;

pub const have_impl = switch (builtin.os.tag) {
    .macos, .linux, .windows => true,
    else => false,
};

gpa: Allocator,
/// Owned copy of the watched config folder path.
config_folder: []const u8,
/// Nightwatch handler + instance — only meaningful when `have_impl`. Stored as opaque
/// optional so this file still type-checks on wasm (where nightwatch isn't linked).
impl: if (have_impl) Impl else void = if (have_impl) .{} else {},
/// Set by nightwatch's handler thread; consumed/extended by `tick` on the main thread.
raw_dirty: std.atomic.Value(bool) = .init(false),
/// A plugin binary arrived whole (`isPluginBinary`): reconciled on the next tick, with no
/// coalesce — the install renamed a finished file into place, so there is nothing to wait for,
/// and the 200 ms was most of how long a rebuilt plugin took to be noticed.
binary_dirty: std.atomic.Value(bool) = .init(false),
/// Main-thread coalesce deadline (`perf.nanoTimestamp()`); 0 = nothing pending.
coalesce_deadline_ns: i128 = 0,

const Impl = if (have_impl) struct {
    const nightwatch = @import("nightwatch");
    /// `Default.Handler` — nightwatch's root module doesn't re-export `types.Handler` directly.
    const Handler = nightwatch.Default.Handler;

    handler: Handler = .{ .vtable = &vtable },
    nw: ?nightwatch.Default = null,
    /// Set in `start` once `SettingsWatcher` is at its final address — avoids a
    /// `@fieldParentPtr` alignment dance from the nested `impl` field.
    raw_dirty: ?*std.atomic.Value(bool) = null,
    binary_dirty: ?*std.atomic.Value(bool) = null,
    /// The watched folder, so an event can be placed in it (`classify`).
    config_folder: []const u8 = "",

    const vtable = Handler.VTable{
        .change = onChange,
        .rename = onRename,
    };

    fn note(h: *Handler, path: []const u8) void {
        const impl: *Impl = @fieldParentPtr("handler", h);
        const flag = switch (classify(impl.config_folder, path)) {
            .ignored => return,
            .binary => impl.binary_dirty,
            .other => impl.raw_dirty,
        };
        if (flag) |f| f.store(true, .release);
        wake.now();
    }

    fn onChange(h: *Handler, path: []const u8, event_type: nightwatch.EventType, object_type: nightwatch.ObjectType) error{HandlerFailed}!void {
        _ = event_type;
        _ = object_type;
        note(h, path);
    }

    fn onRename(h: *Handler, src: []const u8, dst: []const u8, object_type: nightwatch.ObjectType) error{HandlerFailed}!void {
        _ = src;
        _ = object_type;
        note(h, dst);
    }
} else void;

const Kind = enum { binary, ignored, other };

/// What an event at `path` means for the tick. A plugin binary (`<config>/plugins/<id>/<id>.dylib`,
/// `.so`, `.dll`) is complete when its event arrives: the plugin SDK's install writes
/// `<file>.part` and renames it into place (`plugin_sdk.zig`, `DevInstall`), and the store does the
/// same. The `.part` itself, and fizzy's own load copies (`.load-copy/`, `.load-tmp/`, written when
/// it loads a plugin), say nothing new. Everything else — `settings.zon` above all, which an editor
/// may write in several bursts — waits for the coalesce.
fn classify(config_folder: []const u8, path: []const u8) Kind {
    if (std.mem.indexOf(u8, path, ".load-copy") != null or std.mem.indexOf(u8, path, ".load-tmp") != null) return .ignored;
    // The app's own state beside its settings, written while it runs: a crash checkpoint every few
    // seconds while something is unsaved, a restart's session, a handover's signals. None of it is
    // settings or a plugin, and reconciling on each write would re-read `settings.zon` for nothing.
    if (std.mem.startsWith(u8, path, config_folder) and path.len > config_folder.len and std.fs.path.isSep(path[config_folder.len])) {
        const rest = path[config_folder.len + 1 ..];
        const top = rest[0 .. std.mem.indexOfAny(u8, rest, "/\\") orelse rest.len];
        for (state_folders) |name| if (std.mem.eql(u8, top, name)) return .ignored;
    }
    const ext = switch (builtin.os.tag) {
        .windows => ".dll",
        .macos => ".dylib",
        else => ".so",
    };
    if (std.mem.endsWith(u8, path, ext ++ ".part")) return .ignored;
    if (std.mem.endsWith(u8, path, ext)) return .binary;
    return .other;
}

/// Top-level folders of the config folder that hold the app's running state, not settings.
const state_folders = [_][]const u8{ "checkpoint", "checkpoint.new", "session", "handover" };

test classify {
    const ext = switch (builtin.os.tag) {
        .windows => ".dll",
        .macos => ".dylib",
        else => ".so",
    };
    try std.testing.expectEqual(Kind.binary, classify("/cfg", "/cfg/plugins/hello/hello" ++ ext));
    try std.testing.expectEqual(Kind.ignored, classify("/cfg", "/cfg/plugins/hello/hello" ++ ext ++ ".part"));
    try std.testing.expectEqual(Kind.ignored, classify("/cfg", "/cfg/plugins/hello/.load-copy/12-34-hello" ++ ext));
    try std.testing.expectEqual(Kind.ignored, classify("/cfg", "/cfg/plugins/hello/.load-tmp/3-hello" ++ ext));
    try std.testing.expectEqual(Kind.other, classify("/cfg", "/cfg/settings.zon"));
    try std.testing.expectEqual(Kind.other, classify("/cfg", "/cfg/plugins/hello"));
    // The app's own state: never settings, never a plugin.
    try std.testing.expectEqual(Kind.ignored, classify("/cfg", "/cfg/checkpoint/3-0.state"));
    try std.testing.expectEqual(Kind.ignored, classify("/cfg", "/cfg/checkpoint"));
    try std.testing.expectEqual(Kind.ignored, classify("/cfg", "/cfg/checkpoint.new/session.zon"));
    try std.testing.expectEqual(Kind.ignored, classify("/cfg", "/cfg/session/session.zon"));
    try std.testing.expectEqual(Kind.ignored, classify("/cfg", "/cfg/handover/ready"));
    // A plugin that happens to share a name is still a plugin.
    try std.testing.expectEqual(Kind.binary, classify("/cfg", "/cfg/plugins/checkpoint/checkpoint" ++ ext));
}

/// Sets up bookkeeping but does **not** start nightwatch yet — see `start`'s doc comment.
/// `config_folder` is copied; caller retains ownership of the passed slice.
pub fn init(gpa: Allocator, config_folder: []const u8) !SettingsWatcher {
    if (comptime !have_impl) return error.Unsupported;
    const folder = try gpa.dupe(u8, config_folder);
    errdefer gpa.free(folder);
    return .{
        .gpa = gpa,
        .config_folder = folder,
    };
}

/// Starts nightwatch and registers a recursive watch on `config_folder`. Must be called only
/// once `self` is at its **final** address — nightwatch retains `&self.impl.handler` for the
/// watcher's lifetime, so calling this before `self` is copied into `editor.settings_watcher`
/// would leave it pointing at stack memory. Mirrors why `Editor.postInit` exists separately
/// from `Editor.init` — call this from `postInit`, not `init`.
pub fn start(self: *SettingsWatcher) !void {
    if (comptime have_impl) {
        const nightwatch = @import("nightwatch");
        self.impl.raw_dirty = &self.raw_dirty;
        self.impl.binary_dirty = &self.binary_dirty;
        self.impl.config_folder = self.config_folder;
        var nw = try nightwatch.Default.init(dvui.io, self.gpa, &self.impl.handler);
        errdefer nw.deinit();
        try nw.watch(self.config_folder);
        self.impl.nw = nw;
    } else {
        return error.Unsupported;
    }
}

/// Stops nightwatch (joins its background thread) and frees owned paths. Safe to call even if
/// `start` was never called (e.g. `init` succeeded but `start` failed).
pub fn stop(self: *SettingsWatcher) void {
    if (comptime have_impl) {
        if (self.impl.nw) |*nw| {
            nw.deinit();
            self.impl.nw = null;
        }
    }
    self.gpa.free(self.config_folder);
}

/// What the application reconciles when this tree settles.
///
/// One callback, not four: the watcher knows that something under the config folder changed and
/// nothing more. Which passes that implies — re-read the settings file, notice a rebuilt plugin
/// dylib, notice a newly dropped-in one — is the application's business, and fizzy's order
/// between them is fizzy's reasoning (see `Editor.configChanged`).
pub const Sink = struct {
    ctx: *anyopaque,
    changed: *const fn (ctx: *anyopaque) void,
};

/// Call once per frame. Cheap no-op unless the watcher thread actually saw a change. Coalesces
/// a burst of raw events (~200ms) on the main thread before reconciling — except a plugin binary
/// arriving whole, which reconciles on this tick unless a coalesce is already under way.
pub fn tick(self: *SettingsWatcher, sink: Sink) void {
    const now = core.perf.nanoTimestamp();
    if (self.raw_dirty.swap(false, .acquire)) {
        self.coalesce_deadline_ns = now + debounce_ns;
    }
    if (self.binary_dirty.swap(false, .acquire) and self.coalesce_deadline_ns == 0) {
        self.coalesce_deadline_ns = now;
    }
    if (self.coalesce_deadline_ns == 0) return;
    if (now < self.coalesce_deadline_ns) {
        // Keep the event loop alive until the coalesce window settles.
        wake.now();
        return;
    }
    self.coalesce_deadline_ns = 0;
    sink.changed(sink.ctx);
}
