//! Watches the open root folder (recursive) for on-disk changes and broadcasts them to every
//! plugin via `Plugin.VTable.folderPathsChanged`.
//!
//! The third nightwatch adapter in this directory, and the only one whose output leaves fizzy.
//! `SettingsWatcher` reconciles `settings.zon`; `DocumentWatcher` reloads open tabs. Neither
//! helps a plugin that cares about files nobody has open — a file tree that should show what an
//! agent just created, a link indexer whose graph goes stale when a wikilink is deleted from a
//! closed file, a language server owing `didChangeWatchedFiles`. Before this, each of those
//! would have had to pin nightwatch itself and stand up its own thread over the same tree.
//!
//! Three things belong on this side of the SDK boundary rather than in each plugin:
//!
//! 1. **Thread hop.** Nightwatch calls its handler on its own thread. Plugins are dylibs; a
//!    callback arriving on a thread the plugin never created — possibly mid-unload — is a
//!    crash. Events are buffered here and fan out from `tick`, on the UI thread.
//! 2. **Ignore rules.** Only fizzy knows them (`IgnoreRules`). Filtering here means `.git`,
//!    build output and gitignored paths never reach a plugin, instead of every plugin
//!    re-deriving the same filter from `Host.isPathIgnored` one path at a time.
//! 3. **One watcher.** Three plugins each watching the project folder would mean three threads
//!    and three sets of fds or event streams over the same tree.
//!
//! Nightwatch is deliberately not exposed: it is an implementation detail behind
//! `folderPathsChanged`, so it can be swapped, forked, or replaced with per-platform code
//! without any plugin noticing.
//!
//! `have_impl` is false on wasm and any unsupported OS — the watcher is simply not started
//! there, and `Host.folderWatchActive` reports false so a plugin knows to keep its own slow
//! rescan (same degrade-gracefully spirit as `SettingsWatcher` / `DocumentWatcher`).
const builtin = @import("builtin");
const std = @import("std");
const fizzy = @import("../fizzy.zig");
const dvui = @import("dvui");
const Allocator = std.mem.Allocator;

const Plugin = fizzy.sdk.Plugin;
const IgnoreRules = @import("explorer/IgnoreRules.zig");
const folder_events = @import("folder_events.zig");
const underDotSegment = folder_events.underDotSegment;

/// One side of the double buffer. The watcher thread fills `shared`; `tick` swaps it with
/// `staging` under the mutex and then reads at leisure, so no plugin call ever runs with the
/// lock held or races the producer.
const Buf = folder_events.Ring(Plugin.PathEvent.Kind, Plugin.PathEvent.ObjectType);

const FolderWatcher = @This();

/// How long to keep coalescing further events once the first arrives. One logical save is
/// several raw filesystem events, and a consumer reindexing a file wants it to have finished
/// being written.
const debounce_ns: i128 = 200 * std.time.ns_per_ms;

/// Ring capacity. Overflow is reported as `PathChanges.truncated` rather than grown: a branch
/// switch or an `npm install` emits events by the tens of thousands, and the honest answer for
/// a consumer at that point is "rescan", not a longer list it still has to walk.
const max_events: usize = 512;
/// Flat backing store for the paths. One arena rather than a fixed slot per event, so a handful
/// of deep paths can't crowd out everything else and no path length is special-cased.
const path_arena_bytes: usize = 64 * 1024;

pub const have_impl = switch (builtin.os.tag) {
    .macos, .linux, .windows => true,
    else => false,
};

/// Spin lock over `std.atomic.Mutex` (which is try-lock only). A blocking primitive here would
/// mean `std.Io.Mutex` and therefore `dvui.io` on nightwatch's thread — the one thing the doc
/// comments on the other two adapters single out as not to be touched from a watcher callback.
/// Both critical sections are a bounded memcpy or a pointer swap, so there is nothing to block
/// on for long enough to be worth a real wait.
const Spin = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *Spin) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Spin) void {
        self.inner.unlock();
    }
};

gpa: Allocator,
/// Owned copy of the folder currently watched, or null when nothing is.
folder: ?[]u8 = null,
impl: if (have_impl) Impl else void = if (have_impl) .{} else {},

/// Guards `shared` only. Held for a bounded memcpy on the producer and a pointer swap on the
/// consumer — never across a plugin call.
mutex: Spin = .{},
shared: Buf,
staging: Buf,

/// Main-thread coalesce deadline (`perf.nanoTimestamp()`); 0 = nothing pending.
coalesce_deadline_ns: i128 = 0,
/// Scratch for the fan-out, sized once so `tick` never allocates.
out: []Plugin.PathEvent,

const Impl = if (have_impl) struct {
    const nightwatch = @import("nightwatch");
    /// `Default` on purpose — this watches a whole tree, which is the case every backend's
    /// default variant is built for. On macOS that is FSEvents (see the `macos_fsevents` build
    /// option), which watches the subtree from a single stream; the kqueue fallback would want
    /// a file descriptor per directory *and* per file, and a project folder is exactly the
    /// shape that exhausts the fd limit.
    const Watcher = nightwatch.Default;
    const Handler = Watcher.Handler;

    handler: Handler = .{ .vtable = &vtable },
    nw: ?Watcher = null,
    /// Set in `startWatch` once `FolderWatcher` is at its final address.
    owner: ?*FolderWatcher = null,

    const vtable = Handler.VTable{
        .change = onChange,
        .rename = onRename,
    };

    fn kindOf(ev: nightwatch.EventType) Plugin.PathEvent.Kind {
        return switch (ev) {
            .created => .created,
            .modified, .closed => .modified,
            .deleted => .deleted,
        };
    }

    fn objectOf(obj: nightwatch.ObjectType) Plugin.PathEvent.ObjectType {
        return switch (obj) {
            .file => .file,
            .dir => .dir,
            .unknown => .unknown,
        };
    }

    fn record(
        h: *Handler,
        path: []const u8,
        old_path: []const u8,
        kind: Plugin.PathEvent.Kind,
        object: Plugin.PathEvent.ObjectType,
    ) void {
        const impl: *Impl = @fieldParentPtr("handler", h);
        const self = impl.owner orelse return;
        const folder = self.folder orelse return;
        // Cheap dot-directory reject before taking the lock. The authoritative `IgnoreRules`
        // pass happens on the main thread in `tick`; this one exists only so a `git checkout`
        // or a build churning `.zig-cache` can't flood the ring before we get there.
        if (underDotSegment(folder, path)) return;

        self.mutex.lock();
        self.shared.push(path, old_path, kind, object);
        self.mutex.unlock();
        wake();
    }

    fn onChange(h: *Handler, path: []const u8, event_type: nightwatch.EventType, object_type: nightwatch.ObjectType) error{HandlerFailed}!void {
        record(h, path, "", kindOf(event_type), objectOf(object_type));
    }

    fn onRename(h: *Handler, src: []const u8, dst: []const u8, object_type: nightwatch.ObjectType) error{HandlerFailed}!void {
        record(h, dst, src, .renamed, objectOf(object_type));
    }
} else void;

fn wake() void {
    // Safe from any thread — see `Editor.zig`'s `fizzyRefresh` doc comment.
    fizzy.app.window.backend.refresh();
}

/// Allocates the ring buffers. Does not start nightwatch — `setFolder` does, once a folder is
/// open and `self` is at its final address.
pub fn init(gpa: Allocator) !FolderWatcher {
    if (comptime !have_impl) return error.Unsupported;

    const shared_paths = try gpa.alloc(u8, path_arena_bytes);
    errdefer gpa.free(shared_paths);
    const shared_events = try gpa.alloc(Buf.Event, max_events);
    errdefer gpa.free(shared_events);
    const staging_paths = try gpa.alloc(u8, path_arena_bytes);
    errdefer gpa.free(staging_paths);
    const staging_events = try gpa.alloc(Buf.Event, max_events);
    errdefer gpa.free(staging_events);
    const out = try gpa.alloc(Plugin.PathEvent, max_events);

    return .{
        .gpa = gpa,
        .shared = .init(shared_paths, shared_events),
        .staging = .init(staging_paths, staging_events),
        .out = out,
    };
}

pub fn deinit(self: *FolderWatcher) void {
    self.stopWatch();
    self.gpa.free(self.shared.paths);
    self.gpa.free(self.shared.events);
    self.gpa.free(self.staging.paths);
    self.gpa.free(self.staging.events);
    self.gpa.free(self.out);
    self.* = undefined;
}

/// True when a watch is live, i.e. when `folderPathsChanged` can be relied on to fire. Backs
/// `Host.folderWatchActive`.
pub fn active(self: *const FolderWatcher) bool {
    if (comptime !have_impl) return false;
    return self.impl.nw != null;
}

/// Point the watcher at `path` (or nowhere, when null). Must be called only once `self` is at
/// its **final** address — nightwatch retains `&self.impl.handler` for the watcher's lifetime,
/// the same constraint `SettingsWatcher.start` documents.
///
/// Best-effort throughout: a folder that can't be watched is a degraded experience, never a
/// failure to open the folder.
pub fn setFolder(self: *FolderWatcher, path: ?[]const u8) void {
    self.stopWatch();
    if (path) |p| {
        self.folder = self.gpa.dupe(u8, p) catch {
            dvui.log.warn("folder watcher: out of memory; plugins won't see on-disk changes under {s}", .{p});
            return;
        };
        self.startWatch() catch |err| {
            dvui.log.warn("folder watcher: failed to watch {s} ({s}); plugins won't see on-disk changes there", .{ p, @errorName(err) });
            self.stopWatch();
        };
    }
}

fn startWatch(self: *FolderWatcher) !void {
    if (comptime !have_impl) return error.Unsupported;
    const folder = self.folder orelse return error.NoFolder;
    self.impl.owner = self;
    var nw = try Impl.Watcher.init(dvui.io, self.gpa, &self.impl.handler);
    errdefer nw.deinit();
    try nw.watch(folder);
    self.impl.nw = nw;
}

/// Tears the watcher down entirely rather than calling `unwatch`: nightwatch's `unwatch` drops
/// only the path it was given, not the subdirectories its recursive walk added, so a folder
/// switch would otherwise leak watches on the old tree.
fn stopWatch(self: *FolderWatcher) void {
    if (comptime have_impl) {
        if (self.impl.nw) |*nw| {
            nw.deinit();
            self.impl.nw = null;
        }
        self.impl.owner = null;
    }
    if (self.folder) |f| {
        self.gpa.free(f);
        self.folder = null;
    }
    self.mutex.lock();
    self.shared.reset();
    self.mutex.unlock();
    self.coalesce_deadline_ns = 0;
}

/// Call once per frame. Cheap no-op unless the watcher thread actually buffered something.
pub fn tick(self: *FolderWatcher, editor: *fizzy.Editor) void {
    if (comptime !have_impl) return;

    const now = fizzy.perf.nanoTimestamp();
    {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.shared.empty()) self.coalesce_deadline_ns = now + debounce_ns;
    }
    if (self.coalesce_deadline_ns == 0) return;
    if (now < self.coalesce_deadline_ns) {
        // Keep the event loop alive until the coalesce window settles.
        wake();
        return;
    }
    self.coalesce_deadline_ns = 0;

    // Swap rather than copy, so the producer is unblocked immediately and the fan-out below
    // reads a buffer nothing else can touch.
    {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.mem.swap(Buf, &self.shared, &self.staging);
        self.shared.reset();
    }
    defer self.staging.reset();

    const folder = editor.folder orelse return;
    var n: usize = 0;
    for (self.staging.slice()) |e| {
        const path = self.staging.pathOf(e);
        const name = std.fs.path.basename(path);
        // A deleted path can no longer be stat'd, so `.unknown` has to guess; `.file` is both
        // the common case and the conservative one (directory rules are the broader filter).
        const kind: std.Io.File.Kind = switch (e.object) {
            .dir => .directory,
            .file, .unknown => .file,
        };
        if (editor.ignore.isIgnored(folder, path, name, kind)) continue;
        self.out[n] = .{
            .path = path,
            .kind = e.kind,
            .object = e.object,
            .old_path = self.staging.oldPathOf(e),
        };
        n += 1;
    }

    // A truncated batch still has to go out even when every surviving event was ignored: the
    // dropped ones are precisely the events nobody got to inspect.
    if (n == 0 and !self.staging.truncated) return;
    editor.host.notifyFolderPathsChanged(.{
        .events = self.out[0..n],
        .truncated = self.staging.truncated,
    });
}

test {
    // The buffering and filtering live in `folder_events.zig` (std-only, so its tests actually
    // run); pull them in here too so they aren't orphaned if this file grows its own root.
    _ = folder_events;
}
