//! Watches open on-disk documents for external changes while fizzy is running.
//!
//! Thin adapter over [`neurocyte/nightwatch`](https://github.com/neurocyte/nightwatch): each
//! tracked path gets its own `watch(path)` on a `doc_variant` watcher (see that decl — the
//! variant choice is load-bearing for single-file watches). Nightwatch owns the background
//! thread; this layer only implements its `Handler` (atomic flag + `backend.refresh()`, never
//! file content / `dvui.io` / a shared allocator from the callback) and a ~200ms coalesce on
//! the main thread via `tick`.
//!
//! On a real external change (content hash differs from the baseline captured at open / after
//! our own save):
//! - **clean** document → `Plugin.reloadDocument` (when implemented) and refresh the baseline
//! - **dirty** document → set `disk_conflict`; `Editor.save` shows `FileChangedOnDisk` before
//!   writing
//!
//! `have_impl` is false on wasm and any unsupported OS — the watcher is simply not started
//! there (same degrade-gracefully spirit as `SettingsWatcher`).
const builtin = @import("builtin");
const std = @import("std");
const fizzy = @import("../fizzy.zig");
const wake = @import("app").watch.wake;
const dvui = @import("dvui");
const Allocator = std.mem.Allocator;

const DocumentWatcher = @This();

/// How long to keep coalescing further events before reacting, once the first one arrives.
const debounce_ns: i128 = 200 * std.time.ns_per_ms;

/// Same ceiling as the text plugin's open path — guards against hashing something huge.
const max_hash_bytes: usize = 64 * 1024 * 1024;

pub const have_impl = switch (builtin.os.tag) {
    .macos, .linux, .windows => true,
    else => false,
};

const Entry = struct {
    /// Owned, nightwatch-normalized absolute path (the watch key).
    path: []u8,
    /// Wyhash of file contents as of open / last successful save / last reload.
    last_hash: u64,
    /// Disk changed while the in-memory buffer was dirty — block save until the user chooses.
    disk_conflict: bool = false,
    /// After `saveDocument` / `saveDocumentAsync`, refresh the baseline once the doc is clean
    /// and no longer saving (covers async plugin saves that finish on a worker).
    pending_baseline: bool = false,
};

gpa: Allocator,
impl: if (have_impl) Impl else void = if (have_impl) .{} else {},
raw_dirty: std.atomic.Value(bool) = .init(false),
coalesce_deadline_ns: i128 = 0,
/// doc id → tracking entry.
by_id: std.AutoHashMapUnmanaged(u64, Entry) = .empty,
/// normalized path → doc id (event matching). Path keys are borrowed from `Entry.path`.
by_path: std.StringHashMapUnmanaged(u64) = .empty,

/// The nightwatch variant to drive open-document watching.
///
/// **Not `Default`.** We watch individual *files*, and on the BSD/macOS `.kqueue` variant a
/// regular-file path silently lands in the directory watch map: its `NOTE_WRITE` is routed to
/// `scan_dir`, which no-ops on a non-directory, so the write is dropped and no handler event
/// ever fires. `.kqueuedir` `fstat`s the path at `add_watch` time and emits real-time
/// `.modified` for regular files — the case nightwatch's README calls out as the supported way
/// to watch single files. Its directory-tree trade-off (mtime-diff scans miss pure content
/// writes) doesn't apply to us: we only ever pass file paths.
const doc_variant: if (have_impl) @import("nightwatch").Variant else void = switch (builtin.os.tag) {
    .macos, .freebsd, .openbsd, .netbsd, .dragonfly => .kqueuedir,
    else => if (have_impl) @import("nightwatch").default_variant else {},
};

const Impl = if (have_impl) struct {
    const nightwatch = @import("nightwatch");
    const Watcher = nightwatch.Create(doc_variant);
    const Handler = Watcher.Handler;

    handler: Handler = .{ .vtable = &vtable },
    nw: ?Watcher = null,
    raw_dirty: ?*std.atomic.Value(bool) = null,

    const vtable = Handler.VTable{
        .change = onChange,
        .rename = onRename,
    };

    fn note(h: *Handler) void {
        const impl: *Impl = @fieldParentPtr("handler", h);
        if (impl.raw_dirty) |flag| flag.store(true, .release);
        wake.now();
    }

    fn onChange(h: *Handler, path: []const u8, event_type: nightwatch.EventType, object_type: nightwatch.ObjectType) error{HandlerFailed}!void {
        _ = path;
        _ = event_type;
        _ = object_type;
        note(h);
    }

    fn onRename(h: *Handler, src: []const u8, dst: []const u8, object_type: nightwatch.ObjectType) error{HandlerFailed}!void {
        _ = src;
        _ = dst;
        _ = object_type;
        note(h);
    }
} else void;

/// Sets up bookkeeping but does **not** start nightwatch yet — see `start`.
pub fn init(gpa: Allocator) DocumentWatcher {
    return .{ .gpa = gpa };
}

/// Starts nightwatch. Must be called only once `self` is at its **final** address (same reason
/// as `SettingsWatcher.start` — nightwatch retains `&self.impl.handler`).
pub fn start(self: *DocumentWatcher) !void {
    if (comptime !have_impl) return error.Unsupported;
    self.impl.raw_dirty = &self.raw_dirty;
    var nw = try Impl.Watcher.init(dvui.io, self.gpa, &self.impl.handler);
    errdefer nw.deinit();
    self.impl.nw = nw;
}

/// Safe from the nightwatch handler thread — wakes the blocked event loop for one frame.
/// Main-thread only. Call after mutating open-doc contents so the editor repaints without
/// waiting for an unrelated input event. `backend.refresh` alone is enough to wake a sleeping
/// loop from a background thread, but a mid/end-of-frame reload also needs `dvui.refresh` so
/// the *next* iterate actually redraws.
fn requestRepaint() void {
    dvui.refresh(null, @src(), null);
    wake.now();
}

/// Stops nightwatch and frees all tracking entries. Safe if `start` never ran, and safe to call
/// twice: the maps are reset to `.empty` rather than left as `std.HashMapUnmanaged.deinit`'s
/// `undefined`, so a late `notifyPathChanged`/`untrack` during shutdown reads an empty map
/// instead of dereferencing garbage metadata. `Editor.deinit` still clears its
/// `document_watcher` right after calling this — this is the belt to that suspenders.
pub fn stop(self: *DocumentWatcher) void {
    if (comptime have_impl) {
        if (self.impl.nw) |*nw| {
            nw.deinit();
            self.impl.nw = null;
        }
    }
    var it = self.by_id.iterator();
    while (it.next()) |e| self.gpa.free(e.value_ptr.path);
    self.by_id.deinit(self.gpa);
    self.by_path.deinit(self.gpa);
    self.by_id = .empty;
    self.by_path = .empty;
}

/// Begin watching `doc` if it has a real on-disk path. No-op on wasm / when nightwatch isn't
/// running / when the path can't be hashed (missing untitled, etc.).
pub fn track(self: *DocumentWatcher, doc: fizzy.sdk.DocHandle) void {
    if (comptime !have_impl) return;
    if (self.impl.nw == null) return;

    const path = doc.owner.documentPath(doc);
    if (path.len == 0) return;
    // Untitled docs (never written) must not be watched — there's nothing on disk yet.
    if (!doc.owner.documentHasRecognizedSaveExtension(doc)) return;

    const norm = normalizePath(self.gpa, path) catch return;
    errdefer self.gpa.free(norm);

    const hash = hashFile(self.gpa, norm) orelse {
        self.gpa.free(norm);
        return;
    };

    // Already tracking this id (e.g. re-open after failed close) — replace.
    if (self.by_id.fetchRemove(doc.id)) |old| {
        _ = self.by_path.remove(old.value.path);
        self.unwatchPath(old.value.path);
        self.gpa.free(old.value.path);
    }
    // Path already tracked under a different id — shouldn't happen (fizzy dedupes opens), but
    // drop the stale mapping so we don't leave a dangling watch key.
    if (self.by_path.fetchRemove(norm)) |old_id| {
        if (self.by_id.fetchRemove(old_id.value)) |stale| {
            self.unwatchPath(stale.value.path);
            self.gpa.free(stale.value.path);
        }
    }

    // Still track even if the OS watch fails — `notifyPathChanged` (settings.zon writes)
    // and hash compares on later events need the entry. Best-effort watch only.
    self.watchPath(norm) catch |err| {
        dvui.log.warn("document watcher: watch('{s}') failed ({s}); relying on explicit change notifies", .{ norm, @errorName(err) });
    };

    self.by_id.put(self.gpa, doc.id, .{
        .path = norm,
        .last_hash = hash,
    }) catch {
        self.unwatchPath(norm);
        self.gpa.free(norm);
        return;
    };
    self.by_path.put(self.gpa, norm, doc.id) catch {
        if (self.by_id.fetchRemove(doc.id)) |e| {
            self.unwatchPath(e.value.path);
            self.gpa.free(e.value.path);
        }
    };
}

/// Stop watching `doc_id` (document closed).
pub fn untrack(self: *DocumentWatcher, doc_id: u64) void {
    const entry = self.by_id.fetchRemove(doc_id) orelse return;
    _ = self.by_path.remove(entry.value.path);
    self.unwatchPath(entry.value.path);
    self.gpa.free(entry.value.path);
}

/// Retarget watches after Save As (or any `setDocumentPath`).
pub fn retarget(self: *DocumentWatcher, doc: fizzy.sdk.DocHandle) void {
    self.untrack(doc.id);
    self.track(doc);
}

/// True when disk changed while this doc was dirty — `Editor.save` must confirm first.
pub fn hasDiskConflict(self: *const DocumentWatcher, doc_id: u64) bool {
    const entry = self.by_id.get(doc_id) orelse return false;
    return entry.disk_conflict;
}

/// Mark that we just initiated a save; baseline refreshes once the doc is clean again.
pub fn markPendingBaseline(self: *DocumentWatcher, doc_id: u64) void {
    const entry = self.by_id.getPtr(doc_id) orelse return;
    entry.pending_baseline = true;
    entry.disk_conflict = false;
}

/// Restore conflict after a failed overwrite attempt.
pub fn restoreDiskConflict(self: *DocumentWatcher, doc_id: u64) void {
    const entry = self.by_id.getPtr(doc_id) orelse return;
    entry.pending_baseline = false;
    entry.disk_conflict = true;
}

/// Clear conflict + refresh baseline immediately (sync save just succeeded).
pub fn noteSaved(self: *DocumentWatcher, doc_id: u64) void {
    const entry = self.by_id.getPtr(doc_id) orelse return;
    entry.disk_conflict = false;
    entry.pending_baseline = false;
    if (hashFile(self.gpa, entry.path)) |h| {
        entry.last_hash = h;
    } else {
        // File briefly missing (atomic replace) — retry on next tick.
        entry.pending_baseline = true;
    }
    // Atomic replace can drop a per-file watch; re-arm.
    self.watchPath(entry.path) catch {};
}

/// Discard in-memory edits and reload from disk (dialog "Discard Changes").
pub fn discardToDisk(self: *DocumentWatcher, doc: fizzy.sdk.DocHandle) void {
    const entry = self.by_id.getPtr(doc.id) orelse return;
    if (doc.owner.reloadDocument(doc)) {
        entry.disk_conflict = false;
        if (hashFile(self.gpa, entry.path)) |h| entry.last_hash = h;
        self.watchPath(entry.path) catch {};
        requestRepaint();
    } else {
        dvui.log.warn("document watcher: cannot reload '{s}' — owner has no reloadDocument", .{entry.path});
    }
}

/// Immediately reconcile any open doc at `path` (settings.zon UI write / settings watcher).
/// Does not wait for a filesystem event — our own `writeFile` and the config-folder watcher
/// already know the file changed; the open text tab needs an explicit poke.
pub fn notifyPathChanged(self: *DocumentWatcher, editor: *fizzy.Editor, path: []const u8) void {
    if (path.len == 0) return;
    const norm = normalizePath(self.gpa, path) catch return;
    defer self.gpa.free(norm);

    if (self.by_path.get(norm)) |doc_id| {
        self.applyEntry(editor, doc_id);
        return;
    }
    // Normalization can disagree with the path stored at track time (symlink / cwd); fall
    // back to comparing against every open doc fizzy knows about.
    for (editor.app.open_files.values()) |doc| {
        const doc_path = doc.owner.documentPath(doc);
        if (doc_path.len == 0) continue;
        const doc_norm = normalizePath(self.gpa, doc_path) catch continue;
        defer self.gpa.free(doc_norm);
        if (!std.mem.eql(u8, doc_norm, norm)) continue;
        // Ensure we're tracking it (open before watcher started, or watch() failed).
        if (self.by_id.get(doc.id) == null) self.track(doc);
        self.applyEntry(editor, doc.id);
        return;
    }
}

fn applyEntry(self: *DocumentWatcher, editor: *fizzy.Editor, doc_id: u64) void {
    const entry = self.by_id.getPtr(doc_id) orelse return;
    const hash = hashFile(self.gpa, entry.path) orelse return;
    if (hash == entry.last_hash) return;

    const doc = editor.app.docById(doc_id) orelse return;

    if (entry.pending_baseline or doc.owner.isDocumentSaving(doc)) {
        entry.last_hash = hash;
        entry.pending_baseline = doc.owner.isDocumentSaving(doc) or doc.owner.isDirty(doc);
        return;
    }

    if (doc.owner.isDirty(doc)) {
        entry.disk_conflict = true;
        requestRepaint();
        return;
    }

    if (doc.owner.reloadDocument(doc)) {
        entry.last_hash = hash;
        entry.disk_conflict = false;
        self.watchPath(entry.path) catch {};
        requestRepaint();
    } else {
        entry.last_hash = hash;
    }
}

/// Call once per frame. Cheap no-op unless the watcher thread saw a change, or a pending
/// baseline refresh is waiting on an async save to settle.
pub fn tick(self: *DocumentWatcher, editor: *fizzy.Editor) void {
    // Finish baselines for async saves even when no FS event arrived this frame.
    self.refreshPendingBaselines(editor);

    const now = fizzy.core.perf.nanoTimestamp();
    if (self.raw_dirty.swap(false, .acquire)) {
        self.coalesce_deadline_ns = now + debounce_ns;
    }
    if (self.coalesce_deadline_ns == 0) return;
    if (now < self.coalesce_deadline_ns) {
        wake.now();
        return;
    }
    self.coalesce_deadline_ns = 0;
    self.reconcile(editor);
}

fn refreshPendingBaselines(self: *DocumentWatcher, editor: *fizzy.Editor) void {
    var it = self.by_id.iterator();
    while (it.next()) |e| {
        if (!e.value_ptr.pending_baseline) continue;
        const doc = editor.app.docById(e.key_ptr.*) orelse continue;
        if (doc.owner.isDocumentSaving(doc)) continue;
        if (doc.owner.isDirty(doc)) continue;
        e.value_ptr.pending_baseline = false;
        if (hashFile(self.gpa, e.value_ptr.path)) |h| {
            e.value_ptr.last_hash = h;
        }
        self.watchPath(e.value_ptr.path) catch {};
    }
}

fn reconcile(self: *DocumentWatcher, editor: *fizzy.Editor) void {
    // Collect ids first — `applyEntry` may re-enter `track` and mutate the map.
    var ids: std.ArrayListUnmanaged(u64) = .empty;
    defer ids.deinit(self.gpa);
    var it = self.by_id.iterator();
    while (it.next()) |e| {
        ids.append(self.gpa, e.key_ptr.*) catch continue;
    }
    var need_retry = false;
    for (ids.items) |doc_id| {
        const entry = self.by_id.getPtr(doc_id) orelse continue;
        if (hashFile(self.gpa, entry.path) == null) {
            // Atomic replace (write-temp + rename) drops the per-file watch and briefly
            // makes the path missing — re-arm and ask for another coalesce pass so we
            // pick up the new inode's contents once it exists.
            self.watchPath(entry.path) catch {};
            if (hashFile(self.gpa, entry.path) != null) {
                self.applyEntry(editor, doc_id);
            } else {
                need_retry = true;
            }
            continue;
        }
        self.applyEntry(editor, doc_id);
    }
    if (need_retry) {
        self.coalesce_deadline_ns = fizzy.core.perf.nanoTimestamp() + debounce_ns;
        wake.now();
    }
}

fn watchPath(self: *DocumentWatcher, path: []const u8) !void {
    if (comptime !have_impl) return;
    const nw = if (self.impl.nw) |*n| n else return;
    // Re-arm is a no-op when the path is already watched (nightwatch early-returns).
    try nw.watch(path);
}

fn unwatchPath(self: *DocumentWatcher, path: []const u8) void {
    if (comptime !have_impl) return;
    const nw = if (self.impl.nw) |*n| n else return;
    nw.unwatch(path) catch {};
}

fn normalizePath(gpa: Allocator, path: []const u8) ![]u8 {
    return NativeFs.normalizePath(gpa, path);
}

fn hashFile(gpa: Allocator, path: []const u8) ?u64 {
    return NativeFs.hashFile(gpa, path);
}

/// File I/O lives in a `have_impl`-gated type so `Io.Dir.cwd` (posix.AT) is never
/// referenced on wasm — same pattern as `SettingsWatcher`'s nightwatch `Impl`.
const NativeFs = if (have_impl) struct {
    fn normalizePath(gpa: Allocator, path: []const u8) ![]u8 {
        // Match nightwatch's watch() normalization so event paths key the same map entries.
        if (std.fs.path.isAbsolute(path)) {
            return std.fs.path.resolve(gpa, &.{path});
        }
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_len = try std.Io.Dir.cwd().realPath(dvui.io, &cwd_buf);
        return std.fs.path.resolve(gpa, &.{ cwd_buf[0..cwd_len], path });
    }

    fn hashFile(gpa: Allocator, path: []const u8) ?u64 {
        const data = std.Io.Dir.cwd().readFileAlloc(dvui.io, path, gpa, .limited(max_hash_bytes)) catch return null;
        defer gpa.free(data);
        return std.hash.Wyhash.hash(0, data);
    }
} else struct {
    fn normalizePath(_: Allocator, _: []const u8) ![]u8 {
        return error.Unsupported;
    }
    fn hashFile(_: Allocator, _: []const u8) ?u64 {
        return null;
    }
};
