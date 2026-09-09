//! The project's file set: one shared, cached, searchable view of what is on disk.
//!
//! Two plugins that both care about files — a tree that lists them and a tab strip that opens
//! them — must agree about what exists, and neither should pay to find out twice. So the set is
//! **not** owned by either of them. The host owns one `FileTable` and hands it out through
//! `sdk.Host`; plugin code calls these methods directly, and the framework is the only meeting
//! point. Nothing here knows a tree or a tab exists.
//!
//! Before this existed the caches below were module-level `var`s inside the workbench plugin,
//! and that module is compiled *twice* — once into fizzy, once into the dylib — so there were
//! literally two of every cache, kept roughly in step by a shared `disk_generation` counter that
//! each copy polled to decide when to throw its own work away. One table with no generation
//! counter replaces all of it.
//!
//! ## Why it is a cache and not just `Dir.iterate`
//!
//! The unfiltered tree used to re-read every expanded directory straight from disk on *every
//! frame*: `openDir` + `iterate`, an arena dupe per name, a full sort, and an ignore check per
//! entry. On a normal project that is invisible. On a vault with a few hundred thousand markdown
//! files in one directory it is megabytes of arena churn and a sort of the whole listing per
//! frame, which is half of why such a folder drops the app to single-digit FPS. (The other half
//! is drawing a widget per row, which is the caller's problem — see the virtualized file run in
//! the file tree.)
//!
//! So a listing is read once and kept. Freshness comes from the folder watcher fizzy already
//! runs on the open root, via `invalidateListing` / `noteFileModified`; when there is no watcher
//! backend for the platform, entries fall back to a short TTL so outside edits still show up.
const std = @import("std");
const fuzzy = @import("fuzzy.zig");

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
    fn notIgnored(_: ?*anyopaque, _: []const u8, _: []const u8, _: []const u8, _: std.Io.File.Kind) bool {
        return false;
    }
};

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

gpa: std.mem.Allocator,
/// Set once by the host. Every read below goes through it, so nothing here needs dvui — which
/// is what keeps the whole table testable against a real temp directory.
io: std.Io,
env: Env = .{},

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

/// Absolute paths of every non-ignored file in the project. Owned.
index: std.ArrayListUnmanaged([]u8) = .empty,
/// Project root the index was built for; empty when there is no index. Owned.
index_root: []u8 = &.{},
/// Set when a search session ends, so the next one rebuilds from disk rather than ranking a
/// snapshot that may be minutes old. Also set by every invalidation below.
index_stale: bool = true,

/// Last ranking, reused while neither the query nor the index has changed. Without this the
/// whole index is re-scored on every frame the caller draws, not just on each keystroke.
results: std.ArrayListUnmanaged(Entry) = .empty,
results_query: []u8 = &.{},
results_valid: bool = false,

pub fn init(gpa: std.mem.Allocator, io: std.Io) FileTable {
    return .{ .gpa = gpa, .io = io };
}

pub fn deinit(self: *FileTable) void {
    self.freeIndex();
    self.index.deinit(self.gpa);
    if (self.index_root.len > 0) self.gpa.free(self.index_root);
    self.index_root = &.{};
    self.results.deinit(self.gpa);
    if (self.results_query.len > 0) self.gpa.free(self.results_query);
    self.results_query = &.{};

    self.invalidateListings();
    self.releaseRetired();
    self.listings.deinit(self.gpa);
    self.retired.deinit(self.gpa);
}

// ---- invalidation ----------------------------------------------------------------------------

/// Drop the search index. Cheap to call every frame a search box is empty — which is what ends a
/// session — because rebuilding happens lazily on the next query.
pub fn invalidateIndex(self: *FileTable) void {
    self.index_stale = true;
    self.results_valid = false;
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

/// Cached, sorted, ignore-screened listing for `directory`, reading it from disk on a miss.
/// Null when the directory can't be opened.
pub fn listDir(self: *FileTable, directory: []const u8) ?*const Listing {
    const now = self.nowMs();

    if (self.listings.getIndex(directory)) |idx| {
        const listing = self.listings.values()[idx];
        if (self.env.watching(self.env.ctx) or now - listing.read_at_ms < unwatched_ttl_ms) {
            return listing;
        }
        self.retireAt(idx);
    }

    if (self.listings.count() >= max_cached_dirs) self.invalidateListings();

    const io = self.io;
    const gpa = self.gpa;
    var dir = std.Io.Dir.cwd().openDir(io, directory, .{ .access_sub_paths = true, .iterate = true }) catch return null;
    defer dir.close(io);

    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    const proj_root = self.env.root(self.env.ctx);
    // The ignore check wants an absolute path but doesn't keep it, so it's built into a stack
    // buffer: joining through an allocator here would mean one allocation per entry on a listing
    // that can be hundreds of thousands long.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        const abs_path: ?[]const u8 = std.fmt.bufPrint(
            &path_buf,
            "{s}" ++ std.fs.path.sep_str ++ "{s}",
            .{ directory, entry.name },
        ) catch null;

        if (proj_root) |root| {
            const abs = abs_path orelse continue;
            if (self.env.ignored(self.env.ctx, root, abs, entry.name, entry.kind)) continue;
        }

        const kind: std.Io.File.Kind = switch (entry.kind) {
            .directory => .directory,
            .file => .file,
            else => if (abs_path) |abs|
                (if (isDirAbsolute(io, abs)) .directory else .file)
            else
                .file,
        };

        const name = gpa.dupe(u8, entry.name) catch continue;
        entries.append(gpa, .{ .name = name, .kind = kind }) catch {
            gpa.free(name);
            continue;
        };
    }

    const owned = entries.toOwnedSlice(gpa) catch {
        for (entries.items) |e| gpa.free(e.name);
        entries.deinit(gpa);
        return null;
    };
    std.mem.sort(Entry, owned, {}, entryLessThan);

    var dir_count: usize = 0;
    while (dir_count < owned.len and owned[dir_count].kind == .directory) dir_count += 1;

    const listing = gpa.create(Listing) catch {
        for (owned) |e| gpa.free(e.name);
        gpa.free(owned);
        return null;
    };
    listing.* = .{ .entries = owned, .dir_count = dir_count, .read_at_ms = now };

    const key = gpa.dupe(u8, directory) catch {
        self.freeListing(listing);
        return null;
    };
    self.listings.put(gpa, key, listing) catch {
        gpa.free(key);
        self.freeListing(listing);
        return null;
    };
    return listing;
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

    // Ranking depends only on the query and the index, and both change far less often than
    // frames do — a caller redraws on hover, scroll, animation, every peer widget.
    if (self.results_valid and std.mem.eql(u8, self.results_query, query_text)) {
        return self.results.items;
    }

    const gpa = self.gpa;
    const Hit = fuzzy.Ranked(usize);
    var hits: std.ArrayListUnmanaged(Hit) = .empty;

    for (self.index.items, 0..) |abs_path, i| {
        const rel = std.fs.path.relativePosix(arena, ".", root, abs_path) catch continue;
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
    // A failed dupe just means the next frame re-ranks; never claim a cache we can't key.
    self.results_valid = self.results_query.len == query_text.len;

    return self.results.items;
}

/// Rebuild the index for `root` if it's missing, stale, or was built for a different project.
fn ensureIndex(self: *FileTable, root: []const u8) void {
    if (!self.index_stale and std.mem.eql(u8, self.index_root, root)) return;

    self.freeIndex();
    if (!std.mem.eql(u8, self.index_root, root)) {
        if (self.index_root.len > 0) self.gpa.free(self.index_root);
        self.index_root = self.gpa.dupe(u8, root) catch &.{};
    }
    self.indexDir(root, 0);
    self.index_stale = false;
}

/// Depth-first walk honouring the same ignore rules a listing does, so a search never surfaces
/// something an unfiltered tree deliberately hides (`.git`, `node_modules`, …). Written by hand
/// rather than with `Dir.walk` precisely because it has to *prune* ignored directories — a walker
/// that descends into `node_modules` first and filters after is the slow thing this replaced.
fn indexDir(self: *FileTable, directory: []const u8, depth: usize) void {
    if (depth > max_index_depth) return;
    if (self.index.items.len >= max_indexed_files) return;

    const io = self.io;
    const gpa = self.gpa;
    var dir = std.Io.Dir.cwd().openDir(io, directory, .{ .access_sub_paths = true, .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (self.index.items.len >= max_indexed_files) return;

        const abs_path = std.fs.path.join(gpa, &.{ directory, entry.name }) catch continue;
        var keep = false;
        defer if (!keep) gpa.free(abs_path);

        if (self.env.root(self.env.ctx)) |proj_root| {
            if (self.env.ignored(self.env.ctx, proj_root, abs_path, entry.name, entry.kind)) continue;
        }

        switch (entry.kind) {
            .file => {
                self.index.append(gpa, abs_path) catch continue;
                keep = true;
            },
            .directory => self.indexDir(abs_path, depth + 1),
            else => {},
        }
    }
}

fn freeIndex(self: *FileTable) void {
    for (self.index.items) |p| self.gpa.free(p);
    self.index.clearRetainingCapacity();
    // Results borrow the index strings.
    self.results_valid = false;
    self.results.clearRetainingCapacity();
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

fn isDirAbsolute(io: std.Io, abs: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, abs, .{}) catch return false;
    return st.kind == .directory;
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
