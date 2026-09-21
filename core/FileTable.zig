//! The project's file set: one shared, cached, searchable view of what is on disk.
//!
//! Two plugins that both care about files — a tree that lists them and a tab strip that opens
//! them — must agree about what exists, and neither should pay to find out twice. So the set is
//! **not** owned by either of them. The host owns one `FileTable` and hands it out through
//! `sdk.Host`; plugin code calls these methods directly, and the framework is the only meeting
//! point. Nothing here knows a tree or a tab exists. (A built-in plugin is compiled twice — into
//! fizzy and into its dylib — so state that lived in the plugin existed twice too.)
//!
//! ## Why it is a cache and not just `Dir.iterate`
//!
//! Reading an expanded directory straight from disk every frame — `openDir` + `iterate`, an
//! arena dupe per name, a full sort, an ignore check per entry — is invisible on a normal
//! project and single-digit FPS on a vault with a few hundred thousand files in one directory.
//! (Drawing a widget per row is the other half, and the caller's problem — see the virtualized
//! file run in the file tree.)
//!
//! So a listing is read once and kept. Freshness comes from the folder watcher fizzy already
//! runs on the open root, via `invalidateListing` / `noteFileModified`; when there is no watcher
//! backend for the platform, entries fall back to a short TTL so outside edits still show up.
//!
//! ## Mounts: the disk is one filesystem among several
//!
//! Every read and write goes through a `vfs.Fs` — the local disk (`LocalFs`) for an ordinary
//! path, or whichever mount claims the path's prefix (`gdrive://<account>`). A cloud plugin
//! registers a mount through `Host.mount`; nothing here knows what is behind it. The one thing
//! a mount changes is *when* an answer arrives: `vfs.Fs` completes asynchronously, so a miss on
//! a cloud directory returns null this frame and the listing appears (with `env.refresh`) when
//! the response lands. The local mount answers inside the same call, exactly as before.
const std = @import("std");
const fuzzy = @import("fuzzy.zig");
const vfs = @import("vfs/vfs.zig");
const LocalFs = @import("LocalFs.zig");

const FileTable = @This();

/// One entry, whether it came from a directory listing or from a ranked search.
///
/// `dir` is normally null — the entry's parent is whichever directory was listed. Search results
/// come from all over the project at once (a flat ranked list, not a walk), so those carry their
/// own parent explicitly. Callers can therefore draw a listing and a result set with one code
/// path, which is why this is one type rather than two nearly identical ones.
pub const Entry = struct {
    name: []const u8,
    /// Always `.file` or `.directory`. Anything else on disk (a symlink, a fifo) is resolved to
    /// whichever it behaves as, so a sorted listing is always a directory run followed by a file
    /// run — the uniform-height run a caller needs in order to virtualize the file half.
    kind: std.Io.File.Kind,
    dir: ?[]const u8 = null,
};

/// One directory, read once. Borrowed: valid until the next `releaseRetired`.
pub const Listing = struct {
    /// Sorted by `entryLessThan` and already screened against the host's ignore rules.
    entries: []Entry,
    /// Count of leading `.directory` entries; `entries[dir_count..]` is the uniform-height run.
    dir_count: usize,
    read_at_ms: i64,
    /// The filesystem answered with an error, remembered as empty for `failed_retry_ms` so a
    /// directory that is on screen is not re-asked at frame rate — but asked again after that,
    /// because a mount's failure is usually a moment's (an expired token, a network blip) and a
    /// mount listing is otherwise never re-read on its own.
    failed: bool = false,
};

/// What the table has to ask the application, and cannot answer itself: where the project is,
/// whether a watcher is live, and which paths are ignored. Three function pointers set once by
/// the host rather than values, because all three change while the table lives.
///
/// The default answers nothing, so a `FileTable` is usable standalone (and in tests) — it just
/// applies no ignore rules and always uses the TTL.
pub const Env = struct {
    ctx: ?*anyopaque = null,
    root: *const fn (ctx: ?*anyopaque) ?[]const u8 = noRoot,
    watching: *const fn (ctx: ?*anyopaque) bool = notWatching,
    /// A listing or mutation that was pending has landed: whatever draws the table should run
    /// another frame. Only a mount that answers later ever triggers it.
    refresh: *const fn (ctx: ?*anyopaque) void = noRefresh,
    /// `prefix` is about to be unmounted and its filesystem torn down: anything the host has in
    /// flight against it (a document being read or written) must be cancelled now, while the
    /// filesystem still exists to cancel on.
    unmounting: *const fn (ctx: ?*anyopaque, prefix: []const u8) void = noUnmounting,
    ignored: *const fn (
        ctx: ?*anyopaque,
        root: []const u8,
        abs_path: []const u8,
        name: []const u8,
        kind: std.Io.File.Kind,
    ) bool = notIgnored,

    fn noRoot(_: ?*anyopaque) ?[]const u8 {
        return null;
    }
    fn notWatching(_: ?*anyopaque) bool {
        return false;
    }
    fn noRefresh(_: ?*anyopaque) void {}
    fn noUnmounting(_: ?*anyopaque, _: []const u8) void {}
    fn notIgnored(_: ?*anyopaque, _: []const u8, _: []const u8, _: []const u8, _: std.Io.File.Kind) bool {
        return false;
    }
};

const max_path_len: usize = if (@import("builtin").target.cpu.arch == .wasm32) 4096 else std.fs.max_path_bytes;

/// Refuse to index a pathological tree rather than stall a frame. A project past this many files
/// still searches — just over the first `max_indexed_files` discovered.
const max_indexed_files: usize = 200_000;
const max_index_depth: usize = 32;

/// Hard cap on returned search results. Every result becomes a real widget in the caller — an
/// id, an icon, a run-split highlighted label — so the list length is a per-frame cost, not just
/// a scroll length. Uncapped, a one-letter query over a large project matched nearly the whole
/// index and drew tens of thousands of rows per frame, which froze the app. Past a few hundred
/// hits the ranking is noise anyway; the answer is to type another character.
const max_results: usize = 300;

/// Directories held at once. A tree with more than this expanded isn't a UI anyone is reading;
/// dropping the whole cache beats maintaining an LRU for a case nobody reaches.
const max_cached_dirs: usize = 1024;

/// Re-read interval used *only* when there is no live folder watcher, so a caller still notices
/// outside edits on a platform with no watcher backend.
const unwatched_ttl_ms: i64 = 1000;
/// How long a failed listing stands before it is asked again.
const failed_retry_ms: i64 = 5000;

gpa: std.mem.Allocator,
/// Set once by the host. Every read below goes through it, so nothing here needs dvui — which
/// is what keeps the whole table testable against a real temp directory.
io: std.Io,
env: Env = .{},

/// The disk, behind the same interface as every mount. Its `fs()` is taken fresh each time
/// rather than stored: a `FileTable` is moved into its final home after `init`.
local: LocalFs,
/// Prefix-claimed filesystems, longest prefix wins. See `mount`.
mounts: std.ArrayListUnmanaged(Mount) = .empty,
/// Directories asked of a mount whose answer has not landed yet, keyed by full path (owned by
/// the job). A second `listDir` for one of these waits rather than asking twice.
pending: std.StringArrayHashMapUnmanaged(*ListJob) = .empty,

/// Keyed by absolute directory path (owned). Values are boxed because a listing is borrowed
/// across a whole draw and the map rehashes as nested directories are read, which would
/// otherwise move the value out from under the loop iterating it.
listings: std.StringArrayHashMapUnmanaged(*Listing) = .empty,

/// Listings unlinked from the cache but possibly still being read by the draw in progress.
///
/// Invalidation can fire *during* a draw — a context menu that deletes or renames a file runs
/// inside the row it belongs to, several recursion levels deep, each of which is iterating a
/// listing. Freeing eagerly there is a use-after-free in the enclosing loops, so an unlinked
/// listing is parked here and released at the top of the next frame instead.
retired: std.ArrayListUnmanaged(*Listing) = .empty,

// ---- the flat path index, for search ---------------------------------------------------------
//
// Ranking every path in a project against a query is a different access pattern from listing one
// directory, and it cannot be served by the listing cache: the listing cache only holds what the
// caller has expanded. So the project is walked **once per search session** into this index, and
// each keystroke only re-ranks strings already in memory.

/// Full paths of every non-ignored file under every indexed root. Owned.
index: std.ArrayListUnmanaged([]u8) = .empty,
/// The roots the index covers — a tree drawing the disk beside a mount searches both. Owned.
index_roots: std.ArrayListUnmanaged([]u8) = .empty,
/// Set when a search session ends, so the next one rebuilds rather than ranking a snapshot that
/// may be minutes old. Also set by every invalidation below.
index_stale: bool = true,
/// The walk filling the index, while one is running. The disk finishes inside the `search`
/// call that started it; a cloud root keeps going across frames, the index growing as each
/// listing lands, until every directory has answered.
index_job: ?*IndexJob = null,
/// Bumped whenever the index's contents change, so a cached ranking knows it is over.
index_generation: u64 = 0,

/// Last ranking, reused while neither the query nor the index has changed. Without this the
/// whole index is re-scored on every frame the caller draws, not just on each keystroke.
results: std.ArrayListUnmanaged(Entry) = .empty,
results_query: []u8 = &.{},
results_root: []u8 = &.{},
results_generation: u64 = 0,
results_valid: bool = false,

pub fn init(gpa: std.mem.Allocator, io: std.Io) FileTable {
    return .{ .gpa = gpa, .io = io, .local = .init(gpa, io) };
}

pub fn deinit(self: *FileTable) void {
    for (self.pending.values()) |job| {
        job.fs.cancel(job.job);
        job.destroy();
    }
    self.pending.deinit(self.gpa);
    for (self.mounts.items) |m| self.gpa.free(m.prefix);
    self.mounts.deinit(self.gpa);
    self.local.deinit();

    self.freeIndex();
    self.index.deinit(self.gpa);
    self.index_roots.deinit(self.gpa);
    self.results.deinit(self.gpa);
    if (self.results_query.len > 0) self.gpa.free(self.results_query);
    self.results_query = &.{};
    if (self.results_root.len > 0) self.gpa.free(self.results_root);
    self.results_root = &.{};

    self.invalidateListings();
    self.releaseRetired();
    self.listings.deinit(self.gpa);
    self.retired.deinit(self.gpa);
}

// ---- mounts ----------------------------------------------------------------------------------

/// A filesystem answering every path under `prefix`. A path is on the mount when it equals the
/// prefix or continues it with a `/`; the mount itself sees the remainder rooted at `/`
/// (`gdrive://me/Notes/a.md` → `/Notes/a.md`), so a backend never learns the host's naming.
pub const Mount = struct {
    prefix: []u8,
    fs: vfs.Fs,
};

/// Where a path is answered from: the filesystem, the path as that filesystem wants it, and
/// the mount (null for the disk).
pub const Resolved = struct {
    fs: vfs.Fs,
    rel: []const u8,
    mount: ?*const Mount,
};

/// Claim `prefix` for `fs`. Re-mounting an existing prefix replaces the filesystem in place.
pub fn mount(self: *FileTable, prefix: []const u8, fs: vfs.Fs) !void {
    for (self.mounts.items) |*m| {
        if (std.mem.eql(u8, m.prefix, prefix)) {
            m.fs = fs;
            self.invalidateAll();
            return;
        }
    }
    const owned = try self.gpa.dupe(u8, prefix);
    errdefer self.gpa.free(owned);
    try self.mounts.append(self.gpa, .{ .prefix = owned, .fs = fs });
    self.invalidateAll();
}

/// Release `prefix`. Listings under it are dropped, and a pending job for it is cancelled — the
/// filesystem behind it is about to go away, so its callbacks must not run.
pub fn unmount(self: *FileTable, prefix: []const u8) void {
    for (self.mounts.items, 0..) |m, i| {
        if (!std.mem.eql(u8, m.prefix, prefix)) continue;
        self.env.unmounting(self.env.ctx, prefix);
        if (self.index_job) |job| job.cancel();
        var p: usize = 0;
        while (p < self.pending.count()) {
            const job = self.pending.values()[p];
            if (!pathOnMount(job.directory, prefix)) {
                p += 1;
                continue;
            }
            job.fs.cancel(job.job);
            self.pending.swapRemoveAt(p);
            job.destroy();
        }
        self.gpa.free(m.prefix);
        _ = self.mounts.orderedRemove(i);
        self.invalidateAll();
        return;
    }
}

pub fn mountList(self: *const FileTable) []const Mount {
    return self.mounts.items;
}

/// The filesystem for `path`. The longest matching prefix wins; no match means the disk.
pub fn resolve(self: *FileTable, path: []const u8) Resolved {
    var best: ?*const Mount = null;
    for (self.mounts.items) |*m| {
        if (!pathOnMount(path, m.prefix)) continue;
        if (best == null or m.prefix.len > best.?.prefix.len) best = m;
    }
    const m = best orelse return .{ .fs = self.local.fs(), .rel = path, .mount = null };
    const rest = path[m.prefix.len..];
    return .{ .fs = m.fs, .rel = if (rest.len == 0) "/" else rest, .mount = m };
}

/// Whether `path` is on a mount at all — the question a caller asks before handing a path to
/// something that only understands the disk (a watcher, a shell, a process).
pub fn isMounted(self: *const FileTable, path: []const u8) bool {
    for (self.mounts.items) |m| {
        if (pathOnMount(path, m.prefix)) return true;
    }
    return false;
}

fn pathOnMount(path: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    return path.len == prefix.len or path[prefix.len] == '/';
}

/// Deliver every mount's completions. Once per frame from the host, before anything draws, so a
/// listing that landed since last frame is in the cache by the time the tree asks for it.
pub fn pump(self: *FileTable) void {
    self.local.fs().pump();
    for (self.mounts.items) |m| m.fs.pump();
}

// ---- invalidation ----------------------------------------------------------------------------

/// Drop the search index. Cheap to call every frame a search box is empty — which is what ends a
/// session — because rebuilding happens lazily on the next query.
pub fn invalidateIndex(self: *FileTable) void {
    self.index_stale = true;
    self.results_valid = false;
    // A walk still in flight is for a session that just ended: stop asking.
    if (self.index_job) |job| job.cancel();
}

/// Whether a search's index is still being filled — a caller can show "searching…" beside
/// partial results rather than an empty list that later fills in.
pub fn indexing(self: *const FileTable) bool {
    return self.index_job != null;
}

/// Drop every cached listing. Callers re-read whatever they draw on the next frame.
pub fn invalidateListings(self: *FileTable) void {
    while (self.listings.count() > 0) self.retireAt(self.listings.count() - 1);
}

/// Drop the listing for one directory. The folder watcher calls this with the parent of each
/// changed path — a file appearing in `a/b/c.md` only invalidates `a/b`.
pub fn invalidateListing(self: *FileTable, directory: []const u8) void {
    if (self.listings.getIndex(directory)) |idx| self.retireAt(idx);
}

/// Everything, for a change of unknown extent: a mutation through one of the helpers below, a
/// plugin that wrote to disk through its own save routine, a new project folder.
///
/// Deliberately *not* what `invalidateIndex` does on its own: that one also fires every frame a
/// search box is empty, which would drop the listing cache continuously and undo the whole point
/// of having it.
pub fn invalidateAll(self: *FileTable) void {
    self.invalidateIndex();
    self.invalidateListings();
}

/// A `.modified` event for a file that may or may not be new.
///
/// A file's *contents* changing leaves its parent's listing exactly as it was, and that is by far
/// the most common event there is (every save of every open document), so a caller wants to
/// ignore it. But on macOS a brand-new file arrives as `.modified` too: FSEvents coalesces
/// ItemCreated and ItemModified onto one event, and nightwatch resolves that pair to `.modified`
/// because a rewrite of an existing file through `O_CREAT` sets ItemCreated as well. Ignoring
/// every `.modified` therefore meant a file created outside fizzy never appeared in the tree.
///
/// So: re-read the parent only when its cached listing has never seen this name. A save of an
/// already-listed file still costs one binary search and no disk access.
pub fn noteFileModified(self: *FileTable, path: []const u8) void {
    const parent = std.fs.path.dirname(path) orelse return;
    const idx = self.listings.getIndex(parent) orelse return; // not cached: nothing to re-read
    if (listingHasFile(self.listings.values()[idx], std.fs.path.basename(path))) return;
    self.retireAt(idx);
}

/// Release listings unlinked during earlier frames. Call once at the top of a draw, which is the
/// only point at which nothing can still be reading one.
pub fn releaseRetired(self: *FileTable) void {
    for (self.retired.items) |listing| self.freeListing(listing);
    self.retired.clearRetainingCapacity();
}

// ---- listing ---------------------------------------------------------------------------------

/// Cached, sorted, ignore-screened listing for `directory`, asking its filesystem on a miss.
///
/// Null when the directory can't be read — or, on a mount that answers later, until it has:
/// the request is in flight, `env.refresh` fires when it lands, and the next call returns it.
pub fn listDir(self: *FileTable, directory: []const u8) ?*const Listing {
    const now = self.nowMs();

    if (self.listings.getIndex(directory)) |idx| {
        const listing = self.listings.values()[idx];
        // The TTL is the disk's fallback for a platform with no folder watcher. A mount is
        // never TTL'd: its listing stands until the mounting plugin invalidates it (a drive's
        // change feed) or nothing ever will (a zip) — re-reading it every second would mean a
        // round trip per second and a branch that empties while each one is in flight.
        const ttl: i64 = if (listing.failed) failed_retry_ms else unwatched_ttl_ms;
        const fresh = now - listing.read_at_ms < ttl;
        if (fresh or (!listing.failed and (self.isMounted(directory) or self.env.watching(self.env.ctx)))) {
            return listing;
        }
        self.retireAt(idx);
    }

    if (self.pending.contains(directory)) return null;
    if (self.listings.count() >= max_cached_dirs) self.invalidateListings();

    const job = ListJob.create(self, directory) catch return null;
    self.pending.put(self.gpa, job.directory, job) catch {
        job.destroy();
        return null;
    };
    const target = self.resolve(directory);
    job.fs = target.fs;
    job.job = target.fs.listDir(self.gpa, target.rel, ListJob.onListed, job) catch {
        _ = self.pending.swapRemove(job.directory);
        job.destroy();
        return null;
    };
    // The disk answers inside this call; a mount answers from the host's per-frame `pump`,
    // never here — this runs mid-draw, and a mount's completions may open or close documents.
    if (target.mount == null) target.fs.pump();
    if (self.listings.get(directory)) |listing| return listing;
    return null;
}

/// One directory asked of a filesystem. Owns the path (which is also the `pending` key).
const ListJob = struct {
    table: *FileTable,
    directory: []u8,
    fs: vfs.Fs = undefined,
    job: vfs.Job = .{ .id = 0 },
    asked_at_ms: i64,

    fn create(table: *FileTable, directory: []const u8) !*ListJob {
        const job = try table.gpa.create(ListJob);
        errdefer table.gpa.destroy(job);
        job.* = .{ .table = table, .directory = try table.gpa.dupe(u8, directory), .asked_at_ms = table.nowMs() };
        return job;
    }

    fn destroy(job: *ListJob) void {
        job.table.gpa.free(job.directory);
        job.table.gpa.destroy(job);
    }

    fn onListed(ctx: ?*anyopaque, result: vfs.Error![]vfs.Entry) void {
        const job: *ListJob = @ptrCast(@alignCast(ctx.?));
        const table = job.table;
        defer job.destroy();
        _ = table.pending.swapRemove(job.directory);
        const entries = result catch |err| {
            // Remembered as empty for `failed_retry_ms` rather than asked again next frame —
            // a directory that answers `Unauthorized` or `NotFound` would otherwise be
            // re-requested at frame rate for as long as it is on screen.
            std.log.warn("listing {s} failed: {t}", .{ job.directory, err });
            table.install(job.directory, &.{}, job.asked_at_ms);
            if (table.listings.get(job.directory)) |l| l.failed = true;
            table.env.refresh(table.env.ctx);
            return;
        };
        defer vfs.freeEntries(table.gpa, entries);
        table.install(job.directory, entries, job.asked_at_ms);
        table.env.refresh(table.env.ctx);
    }
};

/// Screen, sort and cache a listing that just arrived for `directory`.
fn install(self: *FileTable, directory: []const u8, raw: []const vfs.Entry, read_at_ms: i64) void {
    const gpa = self.gpa;
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    const proj_root = self.env.root(self.env.ctx);
    // The ignore check wants a full path but doesn't keep it, so it's built into a stack
    // buffer: joining through an allocator here would mean one allocation per entry on a listing
    // that can be hundreds of thousands long. (`max_path_bytes` is the OS's; freestanding has
    // no PATH_MAX, and a mount's paths are bounded by the same 4 KiB every OS settles on.)
    var path_buf: [max_path_len]u8 = undefined;

    const on_mount = self.isMounted(directory);
    for (raw) |entry| {
        const kind: std.Io.File.Kind = if (entry.kind == .dir) .directory else .file;
        if (proj_root) |root| {
            const abs = (if (on_mount)
                std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ directory, entry.name })
            else
                std.fmt.bufPrint(&path_buf, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ directory, entry.name })) catch continue;
            if (self.env.ignored(self.env.ctx, root, abs, entry.name, kind)) continue;
        }
        const name = gpa.dupe(u8, entry.name) catch continue;
        entries.append(gpa, .{ .name = name, .kind = kind }) catch {
            gpa.free(name);
            continue;
        };
    }

    const owned = entries.toOwnedSlice(gpa) catch {
        for (entries.items) |e| gpa.free(e.name);
        entries.deinit(gpa);
        return;
    };
    std.mem.sort(Entry, owned, {}, entryLessThan);

    var dir_count: usize = 0;
    while (dir_count < owned.len and owned[dir_count].kind == .directory) dir_count += 1;

    const listing = gpa.create(Listing) catch {
        for (owned) |e| gpa.free(e.name);
        gpa.free(owned);
        return;
    };
    listing.* = .{ .entries = owned, .dir_count = dir_count, .read_at_ms = read_at_ms };

    // A listing for this directory may have been installed meanwhile (an invalidation raced a
    // slow mount); the newer one wins and the older is retired like any other.
    if (self.listings.getIndex(directory)) |idx| self.retireAt(idx);
    const key = gpa.dupe(u8, directory) catch {
        self.freeListing(listing);
        return;
    };
    self.listings.put(gpa, key, listing) catch {
        gpa.free(key);
        self.freeListing(listing);
    };
}

// ---- search ----------------------------------------------------------------------------------

/// Rank every indexed path under `root` against `query` and return the best matches first, or
/// nothing for an empty query. Borrowed: valid until the next call or invalidation.
///
/// Matching runs against the **project-relative path**, not just the basename, with zf's
/// filepath mode: `src/files.zig` beats `s/r/c/f/i/l/e/s.zig` for the query `srcfiles`, and a
/// query containing a `/` is treated as a path constraint. A substring test on the basename alone
/// could not express either.
/// `arena` is scratch for the duration of the call only — the frame arena, in a draw.
pub fn search(
    self: *FileTable,
    root: []const u8,
    query_text: []const u8,
    arena: std.mem.Allocator,
) []const Entry {
    self.ensureIndex(root);

    var query = fuzzy.Query.init(query_text);
    if (query.isEmpty()) return &.{};

    // Ranking depends only on the query, the root and the index, and all three change far less
    // often than frames do — a caller redraws on hover, scroll, animation, every peer widget.
    if (self.results_valid and
        self.results_generation == self.index_generation and
        std.mem.eql(u8, self.results_query, query_text) and
        std.mem.eql(u8, self.results_root, root))
    {
        return self.results.items;
    }

    const gpa = self.gpa;
    const Hit = fuzzy.Ranked(usize);
    var hits: std.ArrayListUnmanaged(Hit) = .empty;

    for (self.index.items, 0..) |abs_path, i| {
        // Only what sits under this root; the index may cover others too.
        const rel = relativeTo(abs_path, root) orelse continue;
        const score = fuzzy.score(rel, &query, .{ .plain = false }) orelse continue;
        // Shorter paths win ties — the same tie-break zf's own frontend uses.
        hits.append(arena, .{ .item = i, .score = score, .tie = rel.len }) catch break;
    }
    fuzzy.sort(usize, hits.items);

    // Results borrow the index strings, so they live exactly as long as the index does —
    // `freeIndex` drops them.
    self.results.clearRetainingCapacity();
    for (hits.items) |hit| {
        if (self.results.items.len >= max_results) break;
        const abs_path = self.index.items[hit.item];
        self.results.append(gpa, .{
            .name = std.fs.path.basename(abs_path),
            .kind = .file,
            .dir = std.fs.path.dirname(abs_path) orelse root,
        }) catch break;
    }

    if (self.results_query.len > 0) gpa.free(self.results_query);
    self.results_query = gpa.dupe(u8, query_text) catch &.{};
    if (self.results_root.len > 0) gpa.free(self.results_root);
    self.results_root = gpa.dupe(u8, root) catch &.{};
    self.results_generation = self.index_generation;
    // A failed dupe just means the next frame re-ranks; never claim a cache we can't key.
    self.results_valid = self.results_query.len == query_text.len and self.results_root.len == root.len;

    return self.results.items;
}

/// `path` relative to `root` with the separator dropped, or null when it is not beneath it.
/// A plain prefix strip rather than `std.fs.path.relative`: the walk built these paths by
/// joining onto `root`, so the prefix is exact, and a mount's `gdrive://…` is not a path the
/// OS helpers would know how to relate.
fn relativeTo(path: []const u8, root: []const u8) ?[]const u8 {
    if (path.len <= root.len or !std.mem.startsWith(u8, path, root)) return null;
    const sep = path[root.len];
    if (sep != '/' and sep != std.fs.path.sep) return null;
    return path[root.len + 1 ..];
}

/// Make sure `root` is being indexed: drop a stale index, then start a walk for any root the
/// index does not cover yet. The disk finishes here; a mount finishes on later frames.
fn ensureIndex(self: *FileTable, root: []const u8) void {
    if (self.index_stale) {
        self.freeIndex();
        self.index_stale = false;
    }
    for (self.index_roots.items) |r| {
        if (std.mem.eql(u8, r, root)) return;
    }
    const owned = self.gpa.dupe(u8, root) catch return;
    self.index_roots.append(self.gpa, owned) catch {
        self.gpa.free(owned);
        return;
    };

    const job = self.index_job orelse IndexJob.create(self) catch return;
    self.index_job = job;
    job.ask(root, 0);
    job.drive();
}

/// Depth-first over listings, honouring the same ignore rules a listing does so a search never
/// surfaces something an unfiltered tree deliberately hides (`.git`, `node_modules`, …).
/// Written as a chain of `listDir` completions rather than a walker because a mount cannot be
/// walked synchronously; pruning happens where a directory is *asked for*, so `node_modules` is
/// never listed at all — the slow thing the old walker replaced.
const IndexJob = struct {
    table: *FileTable,
    /// Directories asked and not yet answered.
    in_flight: std.ArrayListUnmanaged(*DirReq) = .empty,
    /// Listings answered since the last `drive` iteration — how it knows the disk is still
    /// answering inline.
    answered: usize = 0,

    const DirReq = struct {
        job: *IndexJob,
        directory: []u8,
        depth: usize,
        fs: vfs.Fs,
        handle: vfs.Job,
    };

    fn create(table: *FileTable) !*IndexJob {
        const job = try table.gpa.create(IndexJob);
        job.* = .{ .table = table };
        return job;
    }

    /// Stop the walk: every outstanding request is cancelled so no listing lands on a table
    /// that has moved on. What was indexed so far stays until `freeIndex`.
    fn cancel(job: *IndexJob) void {
        const table = job.table;
        for (job.in_flight.items) |req| {
            req.fs.cancel(req.handle);
            table.gpa.free(req.directory);
            table.gpa.destroy(req);
        }
        job.in_flight.deinit(table.gpa);
        table.index_job = null;
        table.gpa.destroy(job);
    }

    fn ask(job: *IndexJob, directory: []const u8, depth: usize) void {
        const table = job.table;
        if (depth > max_index_depth) return;
        if (table.index.items.len >= max_indexed_files) return;
        const req = table.gpa.create(DirReq) catch return;
        req.* = .{
            .job = job,
            .directory = table.gpa.dupe(u8, directory) catch {
                table.gpa.destroy(req);
                return;
            },
            .depth = depth,
            .fs = undefined,
            .handle = undefined,
        };
        const target = table.resolve(directory);
        req.fs = target.fs;
        req.handle = target.fs.listDir(table.gpa, target.rel, onListed, req) catch {
            table.gpa.free(req.directory);
            table.gpa.destroy(req);
            return;
        };
        job.in_flight.append(table.gpa, req) catch {
            target.fs.cancel(req.handle);
            table.gpa.free(req.directory);
            table.gpa.destroy(req);
        };
    }

    /// Pump for as long as answers keep coming inside the call — the whole disk, in practice.
    /// A mount that answers later leaves the job in place for the per-frame pump.
    fn drive(job: *IndexJob) void {
        const table = job.table;
        while (true) {
            if (job.in_flight.items.len == 0) {
                // Nothing left to hear back from (or nothing could be asked): finished, not
                // cancelled — same teardown.
                job.cancel();
                return;
            }
            job.answered = 0;
            // Only the disk answers inside the call (see `listDir`); a mount's listings land
            // on the host's per-frame pump and the walk carries on from there.
            table.local.fs().pump();
            // The last answer's `settle` may have torn the job down inside that pump.
            if (table.index_job != job) return;
            if (job.answered == 0) return;
        }
    }

    fn onListed(ctx: ?*anyopaque, result: vfs.Error![]vfs.Entry) void {
        const req: *DirReq = @ptrCast(@alignCast(ctx.?));
        const job = req.job;
        const table = job.table;
        const gpa = table.gpa;
        defer {
            gpa.free(req.directory);
            gpa.destroy(req);
        }
        for (job.in_flight.items, 0..) |r, i| {
            if (r == req) {
                _ = job.in_flight.swapRemove(i);
                break;
            }
        }
        job.answered += 1;

        const entries = result catch return job.settle();
        defer vfs.freeEntries(gpa, entries);

        const on_mount = table.isMounted(req.directory);
        const proj_root = table.env.root(table.env.ctx);
        for (entries) |entry| {
            if (table.index.items.len >= max_indexed_files) break;
            const child = joinChild(gpa, req.directory, entry.name, on_mount) catch continue;
            var keep = false;
            defer if (!keep) gpa.free(child);

            const kind: std.Io.File.Kind = if (entry.kind == .dir) .directory else .file;
            if (proj_root) |root| {
                if (table.env.ignored(table.env.ctx, root, child, entry.name, kind)) continue;
            }
            switch (entry.kind) {
                .file => {
                    table.index.append(gpa, child) catch continue;
                    keep = true;
                },
                .dir => job.ask(child, req.depth + 1),
            }
        }
        table.index_generation += 1;
        job.settle();
    }

    /// After a listing: if it was the last one and nothing is driving the walk from a `search`
    /// call, the job is over and whoever draws should re-rank.
    fn settle(job: *IndexJob) void {
        const table = job.table;
        table.results_valid = false;
        if (job.in_flight.items.len != 0) return;
        job.cancel();
        table.env.refresh(table.env.ctx);
    }
};

/// `dir` + `name`: a mount's paths are `/`-separated whatever the OS.
fn joinChild(gpa: std.mem.Allocator, dir: []const u8, name: []const u8, on_mount: bool) ![]u8 {
    if (on_mount) return std.mem.concat(gpa, u8, &.{ dir, "/", name });
    return std.fs.path.join(gpa, &.{ dir, name });
}

fn freeIndex(self: *FileTable) void {
    if (self.index_job) |job| job.cancel();
    for (self.index.items) |p| self.gpa.free(p);
    self.index.clearRetainingCapacity();
    for (self.index_roots.items) |r| self.gpa.free(r);
    self.index_roots.clearRetainingCapacity();
    self.index_generation += 1;
    // Results borrow the index strings.
    self.results_valid = false;
    self.results.clearRetainingCapacity();
}

// ---- mutation --------------------------------------------------------------------------------
//
// The table that knows what is on disk is also what changes it, so a caller cannot forget to
// invalidate — which is the bug these replace. They were five near-identical helpers in the file
// tree, each opening with a manual `invalidateAfterDiskChange()` that any new call site had to
// remember, and each also exposed as a `workbench-api` service method so a plugin wanting to
// create a file had to depend on the plugin that draws tabs.
//
// Nothing here knows that documents exist. Keeping an open document's path in step with a rename
// is the host's job, because only the host can see the document set — see `Host.renamePath`.

/// Every mutation completes through `cb`, on the caller's thread, from `pump` — for the disk,
/// before the call returns; for a cloud mount, on a later frame. The table's caches are dropped
/// on completion, whichever it is, so the caller never has to remember to invalidate.
pub const DoneFn = vfs.DoneFn;

/// Create an empty file at `path`.
pub fn createFile(self: *FileTable, path: []const u8, cb: DoneFn, ctx: ?*anyopaque) !void {
    const m = try Mutation.create(self, cb, ctx);
    const target = self.resolve(path);
    _ = target.fs.createFile(target.rel, Mutation.onDone, m) catch |err| {
        m.destroy();
        return err;
    };
    if (target.mount == null) target.fs.pump();
}

/// Create a directory at `path`. Parents must already exist.
pub fn createDir(self: *FileTable, path: []const u8, cb: DoneFn, ctx: ?*anyopaque) !void {
    const m = try Mutation.create(self, cb, ctx);
    const target = self.resolve(path);
    _ = target.fs.mkdir(target.rel, Mutation.onDone, m) catch |err| {
        m.destroy();
        return err;
    };
    if (target.mount == null) target.fs.pump();
}

/// Delete `path`, which must be a file or an empty directory.
pub fn remove(self: *FileTable, path: []const u8, cb: DoneFn, ctx: ?*anyopaque) !void {
    const m = try Mutation.create(self, cb, ctx);
    const target = self.resolve(path);
    _ = target.fs.remove(target.rel, Mutation.onDone, m) catch |err| {
        m.destroy();
        return err;
    };
    if (target.mount == null) target.fs.pump();
}

/// Rename `old_path` to `new_path`, a file or a directory. Across mounts — the disk to a
/// drive, a zip to the disk — nothing can rename, so it is a copy of the tree followed by a
/// removal of the source (`MoveJob`), which takes as many round trips as there are entries.
pub fn rename(self: *FileTable, old_path: []const u8, new_path: []const u8, cb: DoneFn, ctx: ?*anyopaque) !void {
    const from = self.resolve(old_path);
    const to = self.resolve(new_path);
    if (from.mount != to.mount) return MoveJob.start(self, old_path, new_path, cb, ctx);
    const m = try Mutation.create(self, cb, ctx);
    _ = from.fs.rename(from.rel, to.rel, Mutation.onDone, m) catch |err| {
        m.destroy();
        return err;
    };
    if (from.mount == null) from.fs.pump();
}

/// A move between two filesystems: copy every entry over, then remove the originals. One
/// operation at a time — each step lands on a pump (the disk's inline, a mount's per frame),
/// so a directory of a thousand files is a thousand-odd steps; that is the cost of there being
/// no rename between a disk and a drive. A failure part-way stops there, leaving what was
/// copied in place and the source intact from that entry on — nothing is removed until every
/// copy has landed.
const MoveJob = struct {
    table: *FileTable,
    cb: DoneFn,
    ctx: ?*anyopaque,
    /// Pairs still to copy, in discovery order (a directory's children are appended when it
    /// is listed).
    queue: std.ArrayListUnmanaged(Pair) = .empty,
    /// Source paths to remove once everything is copied, files first, then directories
    /// deepest-first (they were pushed as they were entered, so reverse order).
    remove_files: std.ArrayListUnmanaged([]u8) = .empty,
    remove_dirs: std.ArrayListUnmanaged([]u8) = .empty,
    /// The entry in flight, and the bytes being carried for a file.
    current: ?Pair = null,
    bytes: ?[]u8 = null,
    /// Removal phase: index into `remove_files`, then `remove_dirs` from the back.
    removing_files: usize = 0,
    removing_dirs: usize = 0,
    phase: enum { copying, removing_files, removing_dirs } = .copying,

    const Pair = struct { src: []u8, dst: []u8, is_dir: bool };

    fn start(table: *FileTable, src: []const u8, dst: []const u8, cb: DoneFn, ctx: ?*anyopaque) !void {
        const gpa = table.gpa;
        const job = try gpa.create(MoveJob);
        errdefer gpa.destroy(job);
        job.* = .{ .table = table, .cb = cb, .ctx = ctx };
        errdefer job.destroy();
        try job.push(src, dst, table.isDir(src));
        table.invalidateIndex();
        job.next();
    }

    fn destroy(job: *MoveJob) void {
        const gpa = job.table.gpa;
        for (job.queue.items) |p| {
            gpa.free(p.src);
            gpa.free(p.dst);
        }
        job.queue.deinit(gpa);
        for (job.remove_files.items) |p| gpa.free(p);
        job.remove_files.deinit(gpa);
        for (job.remove_dirs.items) |p| gpa.free(p);
        job.remove_dirs.deinit(gpa);
        if (job.current) |c| {
            gpa.free(c.src);
            gpa.free(c.dst);
        }
        if (job.bytes) |b| gpa.free(b);
        gpa.destroy(job);
    }

    fn push(job: *MoveJob, src: []const u8, dst: []const u8, is_dir: bool) !void {
        const gpa = job.table.gpa;
        const s = try gpa.dupe(u8, src);
        errdefer gpa.free(s);
        const d = try gpa.dupe(u8, dst);
        errdefer gpa.free(d);
        try job.queue.append(gpa, .{ .src = s, .dst = d, .is_dir = is_dir });
    }

    fn finish(job: *MoveJob, result: vfs.Error!void) void {
        job.table.invalidateAll();
        job.cb(job.ctx, result);
        job.table.env.refresh(job.table.env.ctx);
        job.destroy();
    }

    /// Start the next step, whatever phase we are in. Every callback ends here.
    fn next(job: *MoveJob) void {
        job.nextInner() catch |err| job.finish(err);
    }

    fn nextInner(job: *MoveJob) vfs.Error!void {
        const table = job.table;
        if (job.current) |c| {
            table.gpa.free(c.src);
            table.gpa.free(c.dst);
            job.current = null;
        }
        switch (job.phase) {
            .copying => {
                if (job.queue.items.len == 0) {
                    job.phase = .removing_files;
                    return job.nextInner();
                }
                const pair = job.queue.orderedRemove(0);
                job.current = pair;
                const src = table.resolve(pair.src);
                if (pair.is_dir) {
                    _ = try src.fs.listDir(table.gpa, src.rel, onListed, job);
                } else {
                    _ = try src.fs.readFile(table.gpa, src.rel, onRead, job);
                }
                if (src.mount == null) src.fs.pump();
            },
            .removing_files => {
                if (job.removing_files == job.remove_files.items.len) {
                    job.phase = .removing_dirs;
                    return job.nextInner();
                }
                const path = job.remove_files.items[job.removing_files];
                job.removing_files += 1;
                const src = table.resolve(path);
                _ = try src.fs.remove(src.rel, onStep, job);
                if (src.mount == null) src.fs.pump();
            },
            .removing_dirs => {
                if (job.removing_dirs == job.remove_dirs.items.len) return job.finish({});
                // Deepest first: they were recorded as entered.
                const path = job.remove_dirs.items[job.remove_dirs.items.len - 1 - job.removing_dirs];
                job.removing_dirs += 1;
                const src = table.resolve(path);
                _ = try src.fs.remove(src.rel, onStep, job);
                if (src.mount == null) src.fs.pump();
            },
        }
    }

    /// A directory's listing: create it at the destination, queue its children.
    fn onListed(ctx: ?*anyopaque, result: vfs.Error![]vfs.Entry) void {
        const job: *MoveJob = @ptrCast(@alignCast(ctx.?));
        const table = job.table;
        const entries = result catch |err| return job.finish(err);
        defer vfs.freeEntries(table.gpa, entries);
        const pair = job.current.?;
        job.onListedInner(pair, entries) catch |err| return job.finish(err);
    }

    fn onListedInner(job: *MoveJob, pair: Pair, entries: []const vfs.Entry) vfs.Error!void {
        const table = job.table;
        const gpa = table.gpa;
        for (entries) |e| {
            const s = try joinChild(gpa, pair.src, e.name, table.isMounted(pair.src));
            defer gpa.free(s);
            const d = try joinChild(gpa, pair.dst, e.name, table.isMounted(pair.dst));
            defer gpa.free(d);
            try job.push(s, d, e.kind == .dir);
        }
        try job.remove_dirs.append(gpa, try gpa.dupe(u8, pair.src));
        const dst = table.resolve(pair.dst);
        _ = try dst.fs.mkdir(dst.rel, onStep, job);
        if (dst.mount == null) dst.fs.pump();
    }

    /// A file's bytes: write them at the destination.
    fn onRead(ctx: ?*anyopaque, result: vfs.Error!vfs.Read) void {
        const job: *MoveJob = @ptrCast(@alignCast(ctx.?));
        const table = job.table;
        const read = result catch |err| return job.finish(err);
        job.bytes = read.bytes;
        const pair = job.current.?;
        const dst = table.resolve(pair.dst);
        _ = dst.fs.writeFile(dst.rel, read.bytes, .{}, onWritten, job) catch |err| return job.finish(err);
        if (dst.mount == null) dst.fs.pump();
    }

    fn onWritten(ctx: ?*anyopaque, result: vfs.Error!void) void {
        const job: *MoveJob = @ptrCast(@alignCast(ctx.?));
        const gpa = job.table.gpa;
        if (job.bytes) |b| gpa.free(b);
        job.bytes = null;
        result catch |err| return job.finish(err);
        const pair = job.current.?;
        job.remove_files.append(gpa, gpa.dupe(u8, pair.src) catch return job.finish(error.OutOfMemory)) catch return job.finish(error.OutOfMemory);
        job.next();
    }

    /// A mkdir or a removal landed.
    fn onStep(ctx: ?*anyopaque, result: vfs.Error!void) void {
        const job: *MoveJob = @ptrCast(@alignCast(ctx.?));
        result catch |err| return job.finish(err);
        job.next();
    }
};

/// The bookkeeping around one mutation's completion: invalidate, then tell the caller.
const Mutation = struct {
    table: *FileTable,
    cb: DoneFn,
    ctx: ?*anyopaque,

    fn create(table: *FileTable, cb: DoneFn, ctx: ?*anyopaque) !*Mutation {
        const m = try table.gpa.create(Mutation);
        m.* = .{ .table = table, .cb = cb, .ctx = ctx };
        return m;
    }

    fn destroy(m: *Mutation) void {
        m.table.gpa.destroy(m);
    }

    fn onDone(ctx: ?*anyopaque, result: vfs.Error!void) void {
        const m: *Mutation = @ptrCast(@alignCast(ctx.?));
        defer m.destroy();
        m.table.invalidateAll();
        m.cb(m.ctx, result);
        m.table.env.refresh(m.table.env.ctx);
    }
};

/// Whether anything is at `abs`. On a mount, answered from the parent's cached listing (a
/// draw-time question cannot wait on a round trip), so a name the tree has not listed yet
/// reads as absent — the same answer the tree itself would draw.
pub fn exists(self: *FileTable, abs: []const u8) bool {
    if (!self.isMounted(abs)) return LocalFs.existsAbsolute(self.io, abs);
    const parent = std.fs.path.dirname(abs) orelse return false;
    if (self.resolve(abs).rel.len <= 1) return true; // the mount's root
    const listing = self.listings.get(parent) orelse return false;
    const name = std.fs.path.basename(abs);
    for (listing.entries) |e| {
        if (std.mem.eql(u8, e.name, name)) return true;
    }
    return false;
}

/// Whether `abs` names a directory. False for anything that can't be answered, so a caller
/// treating a vanished path as a file is the safe default. On a mount the answer comes from the
/// parent's cached listing — asking the mount would mean waiting, and this is a draw-time query.
pub fn isDir(self: *FileTable, abs: []const u8) bool {
    if (!self.isMounted(abs)) return LocalFs.isDirAbsolute(self.io, abs);
    if (self.resolve(abs).rel.len <= 1) return true; // the mount's root
    const parent = std.fs.path.dirname(abs) orelse return false;
    const listing = self.listings.get(parent) orelse return false;
    const name = std.fs.path.basename(abs);
    for (listing.entries[0..listing.dir_count]) |e| {
        if (std.mem.eql(u8, e.name, name)) return true;
    }
    return false;
}

// ---- internals -------------------------------------------------------------------------------

/// Unlink one listing, parking it for release on the next frame (see `retired`).
fn retireAt(self: *FileTable, index: usize) void {
    const listing = self.listings.values()[index];
    self.gpa.free(self.listings.keys()[index]);
    self.listings.swapRemoveAt(index);
    self.retired.append(self.gpa, listing) catch self.freeListing(listing);
}

fn freeListing(self: *FileTable, listing: *Listing) void {
    for (listing.entries) |e| self.gpa.free(e.name);
    self.gpa.free(listing.entries);
    self.gpa.destroy(listing);
}

/// Display order for two names: case-insensitive, so `README.md`, `docs/` and `zig-out/` sort
/// where a reader expects rather than splitting into an uppercase run followed by a lowercase one
/// (`std.mem.order` compares raw bytes, and every uppercase ASCII letter sorts below every
/// lowercase one).
///
/// Falls back to an exact byte comparison when two names differ only in case. That keeps the
/// order *total* — without it `README` and `readme`, which can coexist on a case-sensitive
/// filesystem, would compare equal and their relative position would depend on the sort's
/// internals. `listingHasFile` binary-searches with this same function, so the tiebreak is load
/// bearing, not cosmetic.
pub fn nameOrder(a: []const u8, b: []const u8) std.math.Order {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |ca, cb| {
        const la = std.ascii.toLower(ca);
        const lb = std.ascii.toLower(cb);
        if (la != lb) return if (la < lb) .lt else .gt;
    }
    if (a.len != b.len) return if (a.len < b.len) .lt else .gt;
    return std.mem.order(u8, a, b);
}

fn entryLessThan(_: void, lhs: Entry, rhs: Entry) bool {
    if (lhs.kind == .directory and rhs.kind != .directory) return true;
    if (lhs.kind != .directory and rhs.kind == .directory) return false;
    return nameOrder(lhs.name, rhs.name) == .lt;
}

/// Binary search of the file half of a listing (`entries[dir_count..]`, sorted by `nameOrder` —
/// see `entryLessThan`; this must use the *same* comparator or the search silently misses). A
/// per-save lookup must not walk a listing that can be hundreds of thousands of entries long.
fn listingHasFile(listing: *const Listing, name: []const u8) bool {
    const files_only = listing.entries[listing.dir_count..];
    var lo: usize = 0;
    var hi: usize = files_only.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (nameOrder(files_only[mid].name, name)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return true,
        }
    }
    return false;
}

/// Monotonic milliseconds. The boot clock rather than a wall clock: a TTL must not be perturbed
/// by the system clock stepping.
fn nowMs(self: *const FileTable) i64 {
    return @intCast(@divTrunc(std.Io.Clock.boot.now(self.io).nanoseconds, std.time.ns_per_ms));
}

/// A table over a real temp directory, standing in for the host: the project root is the temp
/// directory, nothing is watching it, and the ignore rule — fizzy's is gitignore-shaped — is
/// "anything named `ignored`".
const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: [:0]u8,
    table: FileTable,

    /// Two steps because `env.ctx` is this fixture's own address, which only settles once the
    /// value has been moved into its final home. Same two-step the host does with `*Editor`.
    fn init(gpa: std.mem.Allocator) !Fixture {
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        try tmp.dir.writeFile(io, .{ .sub_path = "beta.zig", .data = "" });
        try tmp.dir.writeFile(io, .{ .sub_path = "Alpha.zig", .data = "" });
        try tmp.dir.createDirPath(io, "src");
        try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "" });
        try tmp.dir.createDirPath(io, "ignored");
        try tmp.dir.writeFile(io, .{ .sub_path = "ignored/secret.zig", .data = "" });

        return .{
            .tmp = tmp,
            .root = try tmp.dir.realPathFileAlloc(io, ".", gpa),
            .table = .init(gpa, io),
        };
    }

    fn wire(self: *Fixture) *FileTable {
        self.table.env = .{
            .ctx = self,
            .root = struct {
                fn f(ctx: ?*anyopaque) ?[]const u8 {
                    const fx: *Fixture = @ptrCast(@alignCast(ctx.?));
                    return fx.root;
                }
            }.f,
            .ignored = struct {
                fn f(_: ?*anyopaque, _: []const u8, _: []const u8, name: []const u8, _: std.Io.File.Kind) bool {
                    return std.mem.eql(u8, name, "ignored");
                }
            }.f,
        };
        return &self.table;
    }

    fn deinit(self: *Fixture) void {
        const gpa = self.table.gpa;
        self.table.deinit();
        gpa.free(self.root);
        self.tmp.cleanup();
    }

    fn join(self: *Fixture, arena: std.mem.Allocator, rel: []const u8) ![]u8 {
        return std.fs.path.join(arena, &.{ self.root, rel });
    }
};

test "listDir sorts directories first and screens ignored names" {
    const t = std.testing;
    var fx = try Fixture.init(t.allocator);
    defer fx.deinit();
    const table = fx.wire();

    const listing = table.listDir(fx.root) orelse return error.ListingFailed;
    try t.expectEqual(@as(usize, 1), listing.dir_count);
    try t.expectEqualStrings("src", listing.entries[0].name);
    try t.expectEqualStrings("Alpha.zig", listing.entries[1].name);
    try t.expectEqualStrings("beta.zig", listing.entries[2].name);
    try t.expectEqual(@as(usize, 3), listing.entries.len); // `ignored/` is gone
}

test "a second listDir is served from the cache, and invalidation drops it" {
    const t = std.testing;
    var fx = try Fixture.init(t.allocator);
    defer fx.deinit();
    const table = fx.wire();

    const first = table.listDir(fx.root) orelse return error.ListingFailed;
    // No watcher in the fixture, so freshness rests on the TTL — which has not elapsed, so this
    // must be the very same allocation rather than a re-read.
    try t.expectEqual(first, table.listDir(fx.root).?);

    table.invalidateListings();
    try t.expectEqual(@as(usize, 0), table.listings.count());
    // Retired, not freed: the draw that invalidated may still be reading it.
    try t.expectEqual(@as(usize, 1), table.retired.items.len);
    table.releaseRetired();
    try t.expectEqual(@as(usize, 0), table.retired.items.len);
}

test "search ranks by relative path and prunes ignored directories" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = try Fixture.init(t.allocator);
    defer fx.deinit();
    const table = fx.wire();

    const hits = table.search(fx.root, "main", arena);
    try t.expectEqual(@as(usize, 1), hits.len);
    try t.expectEqualStrings("main.zig", hits[0].name);
    // Search results carry their own parent, since they come from all over the project.
    try t.expect(std.mem.endsWith(u8, hits[0].dir.?, "src"));

    // The query matches `ignored/secret.zig` on name, so an empty result proves the walk pruned
    // the directory rather than filtering after the fact.
    try t.expectEqual(@as(usize, 0), table.search(fx.root, "secret", arena).len);

    // An empty query is not a match-everything.
    try t.expectEqual(@as(usize, 0), table.search(fx.root, "", arena).len);
}

test "noteFileModified re-reads a parent only for a name it has not seen" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = try Fixture.init(t.allocator);
    defer fx.deinit();
    const table = fx.wire();

    _ = table.listDir(fx.root) orelse return error.ListingFailed;

    // A save of an already-listed file: nothing to do.
    table.noteFileModified(try fx.join(arena, "beta.zig"));
    try t.expectEqual(@as(usize, 1), table.listings.count());

    // A name the listing has never seen — macOS reports a brand-new file this way — must drop it.
    table.noteFileModified(try fx.join(arena, "gamma.zig"));
    try t.expectEqual(@as(usize, 0), table.listings.count());
}

/// Records what a mutation's completion said, for the tests below.
const DoneSink = struct {
    calls: usize = 0,
    err: ?vfs.Error = null,
    fn onDone(ctx: ?*anyopaque, result: vfs.Error!void) void {
        const self: *DoneSink = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        result catch |err| {
            self.err = err;
        };
    }
};

test "disk mutations complete inside the call and drop the caches" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = try Fixture.init(t.allocator);
    defer fx.deinit();
    const table = fx.wire();
    var sink: DoneSink = .{};

    _ = table.listDir(fx.root) orelse return error.ListingFailed;
    try table.createFile(try fx.join(arena, "gamma.zig"), DoneSink.onDone, &sink);
    try t.expectEqual(@as(usize, 1), sink.calls);
    try t.expect(sink.err == null);
    try t.expectEqual(@as(usize, 0), table.listings.count());
    const listing = table.listDir(fx.root) orelse return error.ListingFailed;
    try t.expectEqual(@as(usize, 4), listing.entries.len);

    try table.createDir(try fx.join(arena, "docs"), DoneSink.onDone, &sink);
    try t.expect(table.isDir(try fx.join(arena, "docs")));
    try table.rename(try fx.join(arena, "docs"), try fx.join(arena, "notes"), DoneSink.onDone, &sink);
    try t.expect(table.isDir(try fx.join(arena, "notes")));
    try table.remove(try fx.join(arena, "notes"), DoneSink.onDone, &sink);
    try t.expect(!table.isDir(try fx.join(arena, "notes")));
    try t.expectEqual(@as(usize, 4), sink.calls);

    // A failure is reported the same way, not thrown from the call.
    try table.remove(try fx.join(arena, "nope"), DoneSink.onDone, &sink);
    try t.expectEqual(vfs.Error.NotFound, sink.err.?);
}

test "a mount answers paths under its prefix; the disk keeps the rest" {
    const t = std.testing;
    var fx = try Fixture.init(t.allocator);
    defer fx.deinit();
    const table = fx.wire();

    var mem = try vfs.Mem.init(t.allocator);
    defer mem.deinit();
    try mem.put("/a.txt", "hi");
    try table.mount("mem://box", mem.fs());
    defer table.unmount("mem://box");

    // Prefix stripping: the mount sees `/`, not `mem://box`.
    const r = table.resolve("mem://box");
    try t.expect(r.mount != null);
    try t.expectEqualStrings("/", r.rel);
    try t.expectEqualStrings("/a.txt", table.resolve("mem://box/a.txt").rel);
    try t.expect(table.resolve("mem://boxes/a.txt").mount == null); // not a prefix match
    try t.expect(table.resolve(fx.root).mount == null);

    // A mount answers on the host's per-frame pump, never inside the call: the first ask
    // is pending, the next frame has it.
    try t.expect(table.listDir("mem://box") == null);
    table.pump();
    const listing = table.listDir("mem://box") orelse return error.ListingFailed;
    try t.expectEqual(@as(usize, 1), listing.entries.len);
    try t.expectEqualStrings("a.txt", listing.entries[0].name);

    var sink: DoneSink = .{};
    try table.createDir("mem://box/sub", DoneSink.onDone, &sink);
    table.pump();
    try t.expect(sink.err == null);
    _ = table.listDir("mem://box");
    table.pump();
    _ = table.listDir("mem://box") orelse return error.ListingFailed;
    try t.expect(table.isDir("mem://box/sub"));
    try t.expect(table.isDir("mem://box"));
    try t.expect(!table.isDir("mem://box/a.txt"));


    // The disk still works beside it.
    try t.expect(table.listDir(fx.root) != null);
}

test "a move across mounts copies the tree and removes the source" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fx = try Fixture.init(t.allocator);
    defer fx.deinit();
    const table = fx.wire();
    var mem = try vfs.Mem.init(t.allocator);
    defer mem.deinit();
    try table.mount("mem://box", mem.fs());
    defer table.unmount("mem://box");

    // The fixture's `src/` (with main.zig) goes onto the mount.
    var sink: DoneSink = .{};
    try table.rename(try fx.join(arena, "src"), "mem://box/src", DoneSink.onDone, &sink);
    var frames: usize = 0;
    // A local read now lands from the `Io`'s pool (see `LocalFs.readFile`), so this is frames
    // of pumping with a yield between, not a fixed count of synchronous turns.
    while (sink.calls == 0 and frames < 100_000) : (frames += 1) {
        table.pump();
        std.Thread.yield() catch {};
    }
    try t.expectEqual(@as(usize, 1), sink.calls);
    try t.expect(sink.err == null);
    try t.expectEqualStrings("", mem.nodes.get("/src/main.zig").?.bytes);
    try t.expect(mem.nodes.get("/src").?.kind == .dir);
    try t.expect(!table.exists(try fx.join(arena, "src")));

    // And a single file back to the disk.
    try mem.put("/src/back.txt", "home");
    sink = .{};
    try table.rename("mem://box/src/back.txt", try fx.join(arena, "back.txt"), DoneSink.onDone, &sink);
    frames = 0;
    while (sink.calls == 0 and frames < 64) : (frames += 1) table.pump();
    try t.expect(sink.err == null);
    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try fx.join(arena, "back.txt"), arena, .limited(64));
    try t.expectEqualStrings("home", got);
    try t.expect(!mem.nodes.contains("/src/back.txt"));
}

test "a mount's listing outlives the unwatched TTL" {
    const t = std.testing;
    var fx = try Fixture.init(t.allocator);
    defer fx.deinit();
    const table = fx.wire();
    var mem = try vfs.Mem.init(t.allocator);
    defer mem.deinit();
    try mem.put("/a.txt", "");
    try table.mount("mem://box", mem.fs());
    defer table.unmount("mem://box");
    _ = table.listDir("mem://box");
    table.pump();
    const first = table.listDir("mem://box") orelse return error.ListingFailed;
    // Pretend a long time passed: the listing is still the same allocation, not re-asked.
    @constCast(first).read_at_ms -= 10 * unwatched_ttl_ms;
    try t.expectEqual(first, table.listDir("mem://box").?);
    try t.expectEqual(@as(usize, 0), table.pending.count());
}

test "a mount's failed listing is empty for a while, then asked again" {
    const t = std.testing;
    var fx = try Fixture.init(t.allocator);
    defer fx.deinit();
    const table = fx.wire();
    var mem = try vfs.Mem.init(t.allocator);
    defer mem.deinit();
    try mem.put("/a.txt", "");
    try table.mount("mem://box", mem.fs());
    defer table.unmount("mem://box");
    // A directory the mount does not have: it answers NotFound.
    _ = table.listDir("mem://box/missing");
    table.pump();
    const failed = table.listDir("mem://box/missing") orelse return error.ListingFailed;
    try t.expect(failed.failed);
    try t.expectEqual(@as(usize, 0), failed.entries.len);
    // Not re-asked at frame rate.
    try t.expectEqual(failed, table.listDir("mem://box/missing").?);
    try t.expectEqual(@as(usize, 0), table.pending.count());
    // Once the retry window passes it is asked again — and by then the directory exists.
    try mem.putDir("/missing");
    try mem.put("/missing/b.txt", "");
    @constCast(failed).read_at_ms -= 2 * failed_retry_ms;
    _ = table.listDir("mem://box/missing");
    table.pump();
    const again = table.listDir("mem://box/missing") orelse return error.ListingFailed;
    try t.expect(!again.failed);
    try t.expectEqualStrings("b.txt", again.entries[0].name);
}

test "a mount that answers later is pending, then installed" {
    const t = std.testing;
    var fx = try Fixture.init(t.allocator);
    defer fx.deinit();
    const table = fx.wire();

    // A filesystem that never answers inside the call: `Mem` behind a gate that swallows the
    // first pump, standing in for a network round trip.
    const Gated = struct {
        inner: vfs.Fs,
        held: usize = 0,
        fn gatedList(ptr: *anyopaque, allocator: std.mem.Allocator, path: []const u8, cb: vfs.ListDirFn, ctx: ?*anyopaque) vfs.Error!vfs.Job {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.held = 1;
            return self.inner.listDir(allocator, path, cb, ctx);
        }
        fn gatedPump(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (self.held > 0) {
                self.held -= 1;
                return;
            }
            self.inner.pump();
        }
        fn gatedCancel(ptr: *anyopaque, job: vfs.Job) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.inner.cancel(job);
        }
        fn unsupportedDone(_: *anyopaque, _: []const u8, _: vfs.DoneFn, _: ?*anyopaque) vfs.Error!vfs.Job {
            return error.Unsupported;
        }
        const vt: vfs.Fs.VTable = .{
            .listDir = gatedList,
            .stat = undefined,
            .readFile = undefined,
            .writeFile = undefined,
            .createFile = unsupportedDone,
            .mkdir = unsupportedDone,
            .rename = undefined,
            .remove = unsupportedDone,
            .cancel = gatedCancel,
            .pump = gatedPump,
        };
    };
    var mem = try vfs.Mem.init(t.allocator);
    defer mem.deinit();
    try mem.put("/late.txt", "");
    var gated: Gated = .{ .inner = mem.fs() };
    try table.mount("slow://", .{ .ptr = &gated, .vtable = &Gated.vt });
    defer table.unmount("slow://");

    try t.expect(table.listDir("slow://") == null);
    try t.expectEqual(@as(usize, 1), table.pending.count());
    // Asking again does not ask the mount again.
    try t.expect(table.listDir("slow://") == null);
    try t.expectEqual(@as(usize, 1), table.pending.count());
    // The gate swallows one pump; the host's next per-frame pump lands it.
    table.pump();
    table.pump();
    try t.expectEqual(@as(usize, 0), table.pending.count());
    const listing = table.listDir("slow://") orelse return error.ListingFailed;
    try t.expectEqualStrings("late.txt", listing.entries[0].name);
}

test "search walks a mount, and the disk beside it, as separate roots of one index" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = try Fixture.init(t.allocator);
    defer fx.deinit();
    const table = fx.wire();

    var mem = try vfs.Mem.init(t.allocator);
    defer mem.deinit();
    try mem.putDir("/notes");
    try mem.put("/notes/main.md", "");
    try mem.putDir("/ignored");
    try mem.put("/ignored/main.txt", "");
    try table.mount("mem://box", mem.fs());
    defer table.unmount("mem://box");

    // A mount root: walked through its listings (which land on the frame pump — two levels,
    // two frames), pruned by the same ignore rule as the disk.
    try t.expectEqual(@as(usize, 0), table.search("mem://box", "main", arena).len);
    table.pump();
    table.pump();
    const cloud = table.search("mem://box", "main", arena);
    try t.expectEqual(@as(usize, 1), cloud.len);
    try t.expectEqualStrings("main.md", cloud[0].name);
    try t.expectEqualStrings("mem://box/notes", cloud[0].dir.?);
    try t.expect(!table.indexing());

    // The disk root joins the same index; each search sees only its own root.
    const disk = table.search(fx.root, "main", arena);
    try t.expectEqual(@as(usize, 1), disk.len);
    try t.expectEqualStrings("main.zig", disk[0].name);
    try t.expectEqual(@as(usize, 2), table.index_roots.items.len);
    // …and switching back is a re-rank, not a rebuild.
    const before = table.index_generation;
    try t.expectEqual(@as(usize, 1), table.search("mem://box", "main", arena).len);
    try t.expectEqual(before, table.index_generation);
}

test "search over a mount that answers later fills in across frames" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = try Fixture.init(t.allocator);
    defer fx.deinit();
    const table = fx.wire();

    // Every listing is held back one pump — a two-level tree takes two frames to index.
    const Slow = struct {
        inner: vfs.Fs,
        hold: bool = false,
        fn listSlow(ptr: *anyopaque, allocator: std.mem.Allocator, path: []const u8, cb: vfs.ListDirFn, ctx: ?*anyopaque) vfs.Error!vfs.Job {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.hold = true;
            return self.inner.listDir(allocator, path, cb, ctx);
        }
        fn pumpSlow(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (self.hold) {
                self.hold = false;
                return;
            }
            self.inner.pump();
        }
        fn cancelSlow(ptr: *anyopaque, job: vfs.Job) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.inner.cancel(job);
        }
        const vt: vfs.Fs.VTable = .{
            .listDir = listSlow,
            .stat = undefined,
            .readFile = undefined,
            .writeFile = undefined,
            .createFile = undefined,
            .mkdir = undefined,
            .rename = undefined,
            .remove = undefined,
            .cancel = cancelSlow,
            .pump = pumpSlow,
        };
    };
    var mem = try vfs.Mem.init(t.allocator);
    defer mem.deinit();
    try mem.put("/top.md", "");
    try mem.putDir("/deep");
    try mem.put("/deep/inner.md", "");
    var slow: Slow = .{ .inner = mem.fs() };
    try table.mount("slow://x", .{ .ptr = &slow, .vtable = &Slow.vt });
    defer table.unmount("slow://x");

    // Nothing has answered yet: no results, but the walk is on.
    try t.expectEqual(@as(usize, 0), table.search("slow://x", "md", arena).len);
    try t.expect(table.indexing());
    // The gate holds each listing for one pump. Frame 2: the root lands — `top.md` is
    // searchable, `deep/` has been asked; two frames later it lands too.
    table.pump();
    table.pump();
    try t.expectEqual(@as(usize, 1), table.search("slow://x", "md", arena).len);
    try t.expect(table.indexing());
    table.pump();
    table.pump();
    try t.expectEqual(@as(usize, 2), table.search("slow://x", "md", arena).len);
    try t.expect(!table.indexing());

    // Ending the session mid-walk cancels it cleanly (nothing leaks, nothing lands later).
    table.invalidateIndex();
    try t.expectEqual(@as(usize, 0), table.search("slow://x", "md", arena).len);
    try t.expect(table.indexing());
    table.invalidateIndex();
    try t.expect(!table.indexing());
    table.pump();
}

test "unmount tells the host first, while the filesystem still exists" {
    const t = std.testing;
    var fx = try Fixture.init(t.allocator);
    defer fx.deinit();
    const table = fx.wire();
    const Seen = struct {
        var prefix: []const u8 = "";
        var mounted_then: bool = false;
        var table_ptr: *FileTable = undefined;
        fn f(_: ?*anyopaque, p: []const u8) void {
            prefix = p;
            mounted_then = table_ptr.isMounted(p);
        }
    };
    Seen.table_ptr = table;
    table.env.unmounting = Seen.f;
    var mem = try vfs.Mem.init(t.allocator);
    defer mem.deinit();
    try table.mount("mem://gone", mem.fs());
    table.unmount("mem://gone");
    try t.expectEqualStrings("mem://gone", Seen.prefix);
    try t.expect(Seen.mounted_then);
    try t.expect(!table.isMounted("mem://gone"));
}

test "nameOrder is case-insensitive but total" {
    const t = std.testing;
    try t.expectEqual(std.math.Order.lt, nameOrder("apple", "Banana"));
    try t.expectEqual(std.math.Order.lt, nameOrder("README", "readme"));
    try t.expectEqual(std.math.Order.eq, nameOrder("same", "same"));
    try t.expectEqual(std.math.Order.lt, nameOrder("doc", "docs"));
}

test "a listing sorts directories first, then names" {
    const t = std.testing;
    var entries = [_]Entry{
        .{ .name = "zebra.zig", .kind = .file },
        .{ .name = "Apple", .kind = .directory },
        .{ .name = "alpha.zig", .kind = .file },
        .{ .name = "beta", .kind = .directory },
    };
    std.mem.sort(Entry, &entries, {}, entryLessThan);
    try t.expectEqualStrings("Apple", entries[0].name);
    try t.expectEqualStrings("beta", entries[1].name);
    try t.expectEqualStrings("alpha.zig", entries[2].name);
    try t.expectEqualStrings("zebra.zig", entries[3].name);
}

test "listingHasFile searches only the file run" {
    const t = std.testing;
    var entries = [_]Entry{
        .{ .name = "src", .kind = .directory },
        .{ .name = "alpha.zig", .kind = .file },
        .{ .name = "beta.zig", .kind = .file },
        .{ .name = "gamma.zig", .kind = .file },
    };
    const listing: Listing = .{ .entries = &entries, .dir_count = 1, .read_at_ms = 0 };
    try t.expect(listingHasFile(&listing, "beta.zig"));
    try t.expect(listingHasFile(&listing, "alpha.zig"));
    try t.expect(listingHasFile(&listing, "gamma.zig"));
    try t.expect(!listingHasFile(&listing, "delta.zig"));
    // A directory is not a file, even though it is in `entries`.
    try t.expect(!listingHasFile(&listing, "src"));
}
