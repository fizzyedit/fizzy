//! Watches the open root folder (recursive) for on-disk changes and announces them to plugins as
//! the `fizzy.files.changed` event (`sdk.events.FilesChanged`).
//!
//! The third nightwatch adapter in this directory, and the only one whose output leaves fizzy.
//! `SettingsWatcher` reconciles `settings.zon`; `DocumentWatcher` reloads open tabs. Neither
//! helps a plugin that cares about files nobody has open - a file tree that should show what an
//! agent just created, a link indexer whose graph goes stale when a wikilink is deleted from a
//! closed file, a language server owing `didChangeWatchedFiles`.
//!
//! Three things belong on this side of the SDK boundary rather than in each plugin:
//!
//! 1. **Thread hop.** Nightwatch calls its handler on its own thread. Plugins are dylibs; a
//!    callback arriving on a thread the plugin never created - possibly mid-unload - is a
//!    crash. Events are buffered here and handed over from `tick`, on the UI thread.
//! 2. **Ignore rules.** Only fizzy knows them (`IgnoreRules`). Filtering here means `.git`,
//!    build output and gitignored paths never reach a plugin, instead of every plugin
//!    re-deriving the same filter from `Host.isPathIgnored` one path at a time.
//! 3. **One watcher.** Three plugins each watching the project folder would mean three threads
//!    and three sets of fds or event streams over the same tree.
//!
//! Nightwatch is deliberately not exposed: it is an implementation detail behind
//! `fizzy.files.changed`, so it can be swapped, forked, or replaced with per-platform code
//! without any plugin noticing.
//!
//! Not every folder is watched. Where the backend watches folder by folder (inotify), hidden
//! folders (`.git`, `.zig-cache`, ...), `node_modules` and `zig-pkg` never are
//! (`folder_events.skipWatchDir`), and a tree past `folder_events.max_dir_watches`, or past
//! what the OS allows, is watched only in part. Elsewhere events from hidden folders are dropped
//! anyway (`record`). `active` - `Host.folderWatchActive` - is true only while the tree is
//! covered, so a plugin knows when to keep its own rescan.
//!
//! `have_impl` is false on wasm and any unsupported OS - the watcher is simply not started
//! there, and `Host.folderWatchActive` reports false so a plugin knows to keep its own slow
//! rescan (same degrade-gracefully spirit as `SettingsWatcher` / `DocumentWatcher`).
const builtin = @import("builtin");
const std = @import("std");
const core = @import("core");
const sdk = @import("fizzy_sdk");
const wake = @import("wake.zig");
const dvui = @import("dvui");
const Allocator = std.mem.Allocator;

const PathEvent = sdk.events.PathEvent;
const folder_events = @import("folder_events.zig");

/// One side of the double buffer. The watcher thread fills `shared`; `tick` swaps it with
/// `staging` under the mutex and then reads at leisure, so no plugin call ever runs with the
/// lock held or races the producer.
const Buf = folder_events.Ring(PathEvent.Kind, PathEvent.ObjectType);

const FolderWatcher = @This();

/// How long to keep coalescing further events once the first arrives. One logical save is
/// several raw filesystem events, and a consumer reindexing a file wants it to have finished
/// being written.
const debounce_ns: i128 = 200 * std.time.ns_per_ms;

/// Ring capacity. Overflow is reported as `FilesChanged.truncated` rather than grown: a branch
/// switch or an `npm install` emits events by the tens of thousands, and the honest answer for
/// a consumer at that point is "rescan", not a longer list it still has to walk.
const max_events: usize = 512;
/// Flat backing store for the paths. One arena rather than a fixed slot per event, so a handful
/// of deep paths can't crowd out everything else and no path length is special-cased.
const path_arena_bytes: usize = 64 * 1024;

pub const have_impl = switch (builtin.target.os.tag) {
    .macos, .linux, .windows => true,
    else => false,
};

/// Spin lock over `std.atomic.Mutex` (which is try-lock only). A blocking primitive here would
/// mean `std.Io.Mutex` and therefore `dvui.io` on nightwatch's thread - the one thing the doc
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
/// consumer - never across a plugin call.
mutex: Spin = .{},
shared: Buf,
staging: Buf,

/// Main-thread coalesce deadline (`perf.nanoTimestamp()`); 0 = nothing pending.
coalesce_deadline_ns: i128 = 0,
/// Scratch for the fan-out, sized once so `tick` never allocates.
out: []PathEvent,

const Impl = if (have_impl) struct {
    const nightwatch = @import("nightwatch");
    /// `Default` on purpose - this watches a whole tree, which is the case every backend's
    /// default variant is built for. On macOS that is FSEvents (see the `macos_fsevents` build
    /// option), which watches the subtree from a single stream; the kqueue fallback would want
    /// a file descriptor per directory *and* per file, and a project folder is exactly the
    /// shape that exhausts the fd limit.
    ///
    /// Its `Backend` is driven directly rather than through `Default.watch`. Where a backend
    /// watches one directory at a time (inotify), `watch` and its handler wrapper add every
    /// directory under the folder and every one that appears later, with nothing skipped and
    /// nothing capped, on whichever thread asked, and go on after the OS has said no to each
    /// remaining one. Opening a home folder hung the app that way (#516). Here the folders
    /// watched are `folder_events.Watches`: it skips what nobody edits, counts the watches
    /// live against a cap, stops a walk when the OS runs out and goes on from there once
    /// watches are freed, and is kept by a walker thread of its own, which the backend's
    /// thread hands folder events to without waiting.
    const Watcher = nightwatch.Default;
    const Backend = Watcher.Backend;
    const Handler = Watcher.Handler;

    handler: Handler = .{ .vtable = &vtable },
    /// Heap-allocated: a backend's thread (and FSEvents' callback context) keep pointers into
    /// it, so it must not move with `FolderWatcher`.
    backend: ?*Backend = null,
    /// Set in `startWatch` once `FolderWatcher` is at its final address.
    owner: ?*FolderWatcher = null,

    /// The walker: keeps the folders watched, where the backend watches folder by folder.
    walker: ?std.Thread = null,
    /// Folder events for the walker from the backend's thread, newest first. Each is
    /// allocated before the lock, which only links it in.
    ops: ?*Op = null,
    ops_lock: Spin = .{},
    /// Rung for a new op and for the stop; safe from the backend's thread.
    bell: ?folder_events.Doorbell = null,
    /// The folder is being closed: the walker stops at its next folder.
    cancel: std.atomic.Value(bool) = .init(false),
    /// Every folder under the root is watched (`Watches.whole`), as of the walker's last batch.
    /// False during the first walk and while anything is left out.
    whole: std.atomic.Value(bool) = .init(false),
    /// A folder event was dropped for want of memory, so what is watched may have drifted
    /// from the tree. Sticky for the folder.
    dropped: std.atomic.Value(bool) = .init(false),

    const Op = struct {
        next: ?*Op = null,
        kind: enum { appeared, gone, moved },
        path: []u8,
        /// Where a moved folder was.
        old: []u8 = &.{},
        /// An appeared folder whose contents the backend has already reported: inotify reports
        /// a folder moved in from outside the tree with everything in it. Set by the reader,
        /// under `ops_lock`.
        announced: bool = false,
    };

    const vtable = Handler.VTable{
        .change = onChange,
        .rename = onRename,
    };

    /// The backend, and the event ring, as `Watches` sees them.
    const Ctx = struct {
        backend: *Backend,
        gpa: Allocator,
        folder: []const u8,
        owner: *FolderWatcher,
        /// A scratch inotify instance for `why`, or -1.
        probe: i32,

        /// The backend says only that a watch failed. Asking the kernel again, on a scratch
        /// instance, gets the errno: ENOSPC is the pool, anything else that folder.
        pub fn why(c: Ctx, path: []const u8) folder_events.Refusal {
            // No other backend here watches folder by folder (macOS uses FSEvents): if one
            // does, the pool is the common cause and a retry later the safe answer.
            if (comptime builtin.target.os.tag != .linux) return .pool;
            const linux = std.os.linux;
            if (c.probe < 0) return .pool;
            var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
            if (path.len >= buf.len) return .{ .own = "NAMETOOLONG" };
            @memcpy(buf[0..path.len], path);
            buf[path.len] = 0;
            const rc = linux.inotify_add_watch(c.probe, buf[0..path.len :0], linux.IN.ONLYDIR);
            return switch (linux.errno(rc)) {
                .SUCCESS => blk: {
                    _ = linux.inotify_rm_watch(c.probe, @intCast(rc));
                    break :blk .again;
                },
                .NOSPC, .MFILE, .NOMEM => .pool,
                .NOENT, .NOTDIR => .gone,
                else => |e| .{ .own = @tagName(e) },
            };
        }

        /// Found in a folder as its watch landed, so it had no event of its own.
        pub fn created(c: Ctx, path: []const u8, is_dir: bool) void {
            push(c.owner, path, "", .created, if (is_dir) .dir else .file);
        }

        pub fn add(c: Ctx, path: []const u8) !void {
            try c.backend.add_watch(c.gpa, path);
        }

        pub fn remove(c: Ctx, path: []const u8) void {
            const r = c.backend.remove_watch(c.gpa, path);
            if (@typeInfo(@TypeOf(r)) == .error_union) r catch {};
        }

        pub fn say(c: Ctx, said: folder_events.Said) void {
            switch (said) {
                .skipped => |k| dvui.log.warn("folder watcher: can't watch {s} ({s}); changes in it won't be reported", .{ k.path, k.reason }),
                .degraded => dvui.log.warn("folder watcher: out of memory; changes under {s} may not all be reported until it is opened again", .{c.folder}),
                .blocked => |b| switch (b.why) {
                    .cap => dvui.log.warn("folder watcher: {d} folders under {s} are watched, the most one folder may be; changes in the rest won't be reported", .{ b.watched, c.folder }),
                    .refused => if (comptime builtin.target.os.tag == .linux)
                        dvui.log.warn("folder watcher: the system is out of inotify watches after {d} folders under {s} (raise fs.inotify.max_user_watches); the rest are watched as watches are freed", .{ b.watched, c.folder })
                    else
                        dvui.log.warn("folder watcher: the system refused more watches after {d} folders under {s}; the rest are watched as watches are freed", .{ b.watched, c.folder }),
                },
            }
        }
    };

    fn kindOf(ev: nightwatch.EventType) PathEvent.Kind {
        return switch (ev) {
            .created => .created,
            .modified, .closed => .modified,
            .deleted => .deleted,
        };
    }

    fn objectOf(obj: nightwatch.ObjectType) PathEvent.ObjectType {
        return switch (obj) {
            .file => .file,
            .dir => .dir,
            .unknown => .unknown,
        };
    }

    /// The walker thread: watches the folder, then follows the folder events the backend
    /// hands over, until the folder is closed. While something is left out that time may
    /// help (watches freed by another program), it also tries again on a timer, backing off.
    fn walk(self: *FolderWatcher) void {
        const impl = &self.impl;
        const folder = self.folder orelse return;
        if (impl.bell == null) return;
        const bell = &impl.bell.?;
        var watches: folder_events.Watches = .{ .gpa = self.gpa, .root = folder, .cancel = &impl.cancel };
        defer watches.deinit();
        const probe: i32 = if (comptime builtin.target.os.tag == .linux) probe: {
            const linux = std.os.linux;
            const rc = linux.inotify_init1(linux.IN.CLOEXEC | linux.IN.NONBLOCK);
            break :probe if (linux.errno(rc) == .SUCCESS) @intCast(rc) else -1;
        } else -1;
        defer if (probe >= 0) std.Io.Threaded.closeFd(probe);
        const ctx: Ctx = .{ .backend = impl.backend orelse return, .gpa = self.gpa, .folder = folder, .owner = self, .probe = probe };
        watches.walk(dvui.io, ctx);
        impl.whole.store(watches.whole(), .release);

        const first_retry_ms: i32 = 5 * std.time.ms_per_s;
        var retry_ms = first_retry_ms;
        while (true) {
            const rung = bell.wait(if (watches.waiting()) retry_ms else -1) catch {
                // Nothing to wait on: stop following the tree rather than spin. `active`
                // turns false, so plugins rescan.
                dvui.log.warn("folder watcher: can't wait for folder events; changes under {s} won't be reported", .{folder});
                impl.whole.store(false, .release);
                return;
            };
            // Answer, then look: a stop rung after this is a new ring, one rung before it is
            // seen below. Looking first could lose it and block here for ever.
            bell.answer();
            if (impl.cancel.load(.acquire)) return;
            if (!rung) {
                watches.retry();
                retry_ms = @min(retry_ms * 2, 60 * std.time.ms_per_s);
            }
            const batch = takeOps(impl);
            defer freeOps(self.gpa, batch);
            var it = batch;
            while (it) |op| : (it = op.next) {
                if (impl.cancel.load(.acquire)) return;
                switch (op.kind) {
                    .appeared => watches.appeared(dvui.io, op.path, op.announced, ctx),
                    .gone => watches.gone(op.path, ctx),
                    .moved => watches.moved(dvui.io, op.old, op.path, ctx),
                }
            }
            // What arrived during the first walk has now been handled.
            watches.settled = true;
            watches.catchUp(dvui.io, ctx);
            if (!watches.waiting()) retry_ms = first_retry_ms;
            impl.whole.store(watches.whole(), .release);
        }
    }

    /// Everything queued, oldest first.
    fn takeOps(impl: *Impl) ?*Op {
        impl.ops_lock.lock();
        var newest = impl.ops;
        impl.ops = null;
        impl.ops_lock.unlock();
        var oldest: ?*Op = null;
        while (newest) |op| {
            newest = op.next;
            op.next = oldest;
            oldest = op;
        }
        return oldest;
    }

    fn freeOps(gpa: Allocator, first: ?*Op) void {
        var it = first;
        while (it) |op| {
            it = op.next;
            gpa.free(op.path);
            gpa.free(op.old);
            gpa.destroy(op);
        }
    }

    /// Hand a folder event to the walker. Never waits on it: this is the backend's reader
    /// thread, and a reader that falls behind loses events (inotify's queue overflows).
    fn queueFolder(self: *FolderWatcher, kind: @FieldType(Op, "kind"), path: []const u8, old: []const u8) void {
        const impl = &self.impl;
        const op = self.gpa.create(Op) catch return lose(impl, path);
        op.* = .{ .kind = kind, .path = self.gpa.dupe(u8, path) catch &.{}, .old = self.gpa.dupe(u8, old) catch &.{} };
        if (op.path.len != path.len or op.old.len != old.len) {
            freeOps(self.gpa, op);
            return lose(impl, path);
        }
        impl.ops_lock.lock();
        op.next = impl.ops;
        impl.ops = op;
        impl.ops_lock.unlock();
        if (impl.bell) |*b| b.ring();
    }

    /// Something created right inside the newest folder that appeared, before the walker took
    /// it: the backend is reporting what that folder held (a move-in, reported depth first),
    /// so the walker needn't. A folder made in place has no such events until it is watched.
    fn markAnnounced(impl: *Impl, path: []const u8) void {
        const parent = std.fs.path.dirname(path) orelse return;
        impl.ops_lock.lock();
        defer impl.ops_lock.unlock();
        const op = impl.ops orelse return;
        if (op.kind == .appeared and std.mem.eql(u8, op.path, parent)) op.announced = true;
    }

    /// A folder event that couldn't be queued: the watch no longer covers the tree for sure,
    /// so `active` says so, and the log says it once.
    fn lose(impl: *Impl, path: []const u8) void {
        if (!impl.dropped.swap(true, .acq_rel))
            dvui.log.warn("folder watcher: out of memory; {s} and later folder changes may not be watched", .{path});
    }

    fn record(
        h: *Handler,
        path: []const u8,
        old_path: []const u8,
        kind: PathEvent.Kind,
        object: PathEvent.ObjectType,
    ) void {
        const impl: *Impl = @fieldParentPtr("handler", h);
        const self = impl.owner orelse return;
        if (self.folder == null) return;

        // Where the backend watches folder by folder, the walker follows folders coming and
        // going - before the dot reject, which would hide a folder moved out of view.
        if (!Backend.watches_recursively and kind == .created) markAnnounced(impl, path);
        if (!Backend.watches_recursively and object == .dir) switch (kind) {
            .created => queueFolder(self, .appeared, path, ""),
            // Deleted, or moved out of the tree (an unpaired IN_MOVED_FROM), which keeps its
            // watches: both are given back.
            .deleted => queueFolder(self, .gone, path, ""),
            .renamed => queueFolder(self, .moved, path, old_path),
            .modified => {},
        };

        push(self, path, old_path, kind, object);
    }

    /// Into the ring, for `tick`. From the backend's thread, or the walker's.
    fn push(self: *FolderWatcher, path: []const u8, old_path: []const u8, kind: PathEvent.Kind, object: PathEvent.ObjectType) void {
        const folder = self.folder orelse return;
        // Cheap dot-directory reject before taking the lock. The authoritative `IgnoreRules`
        // pass happens on the main thread in `tick`; this one exists only so a `git checkout`
        // or a build churning `.zig-cache` can't flood the ring before we get there.
        if (folder_events.underSegment(folder, path, folder_events.dotName)) return;

        self.mutex.lock();
        self.shared.push(path, old_path, kind, object);
        self.mutex.unlock();
        wake.now();
    }

    fn onChange(h: *Handler, path: []const u8, event_type: nightwatch.EventType, object_type: nightwatch.ObjectType) error{HandlerFailed}!void {
        record(h, path, "", kindOf(event_type), objectOf(object_type));
    }

    fn onRename(h: *Handler, src: []const u8, dst: []const u8, object_type: nightwatch.ObjectType) error{HandlerFailed}!void {
        record(h, dst, src, .renamed, objectOf(object_type));
    }
} else void;

/// Allocates the ring buffers. Does not start nightwatch - `setFolder` does, once a folder is
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
    const out = try gpa.alloc(PathEvent, max_events);

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

/// True when a watch is live, i.e. when `fizzy.files.changed` can be relied on. Backs
/// `Host.folderWatchActive`.
pub fn active(self: *const FolderWatcher) bool {
    if (comptime !have_impl) return false;
    if (self.impl.backend == null) return false;
    // Folder by folder, the tree is covered only once the walker says every folder is watched;
    // until then, and while any is left out, a plugin keeps its own rescan.
    return Impl.Backend.watches_recursively or
        (self.impl.whole.load(.acquire) and !self.impl.dropped.load(.acquire));
}

/// Point the watcher at `path` (or nowhere, when null). Must be called only once `self` is at
/// its **final** address - nightwatch retains `&self.impl.handler` for the watcher's lifetime,
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
    const impl = &self.impl;
    impl.owner = self;
    impl.cancel.store(false, .release);
    impl.whole.store(false, .release);
    impl.dropped.store(false, .release);
    const backend = try self.gpa.create(Impl.Backend);
    errdefer self.gpa.destroy(backend);
    backend.* = try Impl.Backend.init(dvui.io, &impl.handler);
    errdefer backend.deinit(self.gpa);
    try backend.arm(self.gpa);
    impl.backend = backend;
    errdefer impl.backend = null;
    if (Impl.Backend.watches_recursively) {
        // One watch covers the tree: FSEvents' stream, ReadDirectoryChangesW's subtree.
        try backend.add_watch(self.gpa, folder);
    } else {
        // A watch per folder, and a large tree has a great many: never on the UI thread.
        impl.bell = try folder_events.Doorbell.init();
        errdefer {
            impl.bell.?.deinit();
            impl.bell = null;
        }
        impl.walker = try std.Thread.spawn(.{}, Impl.walk, .{self});
    }
}

/// Tears the watcher down entirely rather than removing one watch: a folder switch would
/// otherwise leak the watches on the old tree's subdirectories.
fn stopWatch(self: *FolderWatcher) void {
    if (comptime have_impl) {
        const impl = &self.impl;
        // The walker returns at its next folder, or wakes to find it should.
        impl.cancel.store(true, .release);
        if (comptime !Impl.Backend.watches_recursively) if (impl.bell) |*b| b.ring();
        if (impl.walker) |t| {
            t.join();
            impl.walker = null;
        }
        if (impl.backend) |b| {
            b.deinit(self.gpa);
            self.gpa.destroy(b);
            impl.backend = null;
        }
        // Only now: the backend's thread may have queued more until it was joined.
        Impl.freeOps(self.gpa, impl.ops);
        impl.ops = null;
        if (comptime !Impl.Backend.watches_recursively) if (impl.bell) |*b| b.deinit();
        impl.bell = null;
        impl.owner = null;
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

/// What the application does with a settled batch, and which of them it wants at all.
///
/// The watcher's job ends at "these paths changed, coalesced, off the watcher thread". Deciding
/// that `.zig-cache/` is noise, and deciding who hears about the rest, is the application's - so
/// both are here rather than inside the watcher, which is what lets this file belong to any app.
pub const Sink = struct {
    ctx: *anyopaque,
    /// False drops the event. Fizzy answers with its ignore rules; an app with none passes
    /// everything.
    wanted: *const fn (ctx: *anyopaque, path: []const u8, name: []const u8, kind: std.Io.File.Kind) bool,
    /// A settled batch. `truncated` means events were dropped before anything could inspect
    /// them, which is why an all-ignored batch still has to be delivered.
    changed: *const fn (ctx: *anyopaque, events: []const PathEvent, truncated: bool) void,
};

/// Call once per frame. Cheap no-op unless the watcher thread actually buffered something.
pub fn tick(self: *FolderWatcher, sink: Sink) void {
    if (comptime !have_impl) return;

    const now = core.perf.nanoTimestamp();
    {
        self.mutex.lock();
        defer self.mutex.unlock();
        // Only *start* a window; extending it on every tick would postpone the fan-out forever,
        // because the buffer stays non-empty until the swap below drains it.
        if (!self.shared.empty() and self.coalesce_deadline_ns == 0) self.coalesce_deadline_ns = now + debounce_ns;
    }
    if (self.coalesce_deadline_ns == 0) return;
    if (now < self.coalesce_deadline_ns) {
        // Keep the event loop alive until the coalesce window settles.
        wake.now();
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
        if (!sink.wanted(sink.ctx, path, name, kind)) continue;
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
    sink.changed(sink.ctx, self.out[0..n], self.staging.truncated);
}

test {
    // The buffering and filtering live in `folder_events.zig` (std-only, so its tests actually
    // run); pull them in here too so they aren't orphaned if this file grows its own root.
    _ = folder_events;
}
