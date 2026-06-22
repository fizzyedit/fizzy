//! Plugin-store backend: catalog fetch (summary + this host's release shard) + verified download,
//! plus a small threaded `Catalog` that owns the latest parsed documents. Pure of dvui/globals —
//! the caller supplies `allocator`, a `std.Io`, and the host's own `abi_fingerprint` as a hex
//! string (the caller already computes this from `sdk.dylib.abi_fingerprint`; this layer stays
//! free of SDK-specific concerns). The store UI (Chunk 5) drives `Catalog` and tracks per-plugin
//! install state on top of this.
const std = @import("std");

pub const registry = @import("registry.zig");
pub const compat = @import("compat.zig");
pub const download = @import("download.zig");

pub const Summary = registry.Summary;
pub const SummaryEntry = registry.SummaryEntry;
pub const ReleaseShard = registry.ReleaseShard;
pub const ShardRelease = registry.ShardRelease;

/// Lifecycle of the catalog fetch (not a per-plugin install state — that lives in the UI).
pub const Status = enum(u8) { idle, fetching, ready, failed };

const ParsedSummary = std.json.Parsed(registry.Summary);
const ParsedShard = std.json.Parsed(registry.ReleaseShard);

/// Owns the latest parsed `summary.json` + this host's `<abi_fingerprint>/releases.json`,
/// refreshed off the UI thread by a real `std.Thread` worker. Shared state is guarded by a
/// `std.Io.Mutex` — the codebase's pattern for coordinating a `std.Thread` worker with the GUI
/// thread (see pixi's `SaveQueue`): lock with `dvui.io`, and `join` the worker on `deinit`. The
/// owner must outlive any in-flight refresh (in the app it is `Editor`-owned, app-lifetime).
///
/// Read access goes through `acquire`/`release`: hold the lock across any read of the returned
/// `Snapshot` so the worker can't free the arena underneath a reader.
///
/// The summary and the shard fail independently: a summary fetch failure is a hard catalog
/// failure (nothing to browse), but a shard fetch failure just means no install/update info is
/// available this round — the shard falls back to `registry.ReleaseShard.empty` (or whatever was
/// last fetched successfully), so the browse list still renders with every plugin showing "no
/// compatible build in store" rather than the whole tab erroring out. A fresh `abi_fingerprint`
/// generation with no shard published yet looks identical to a network hiccup from here, which is
/// the correct behavior in both cases.
pub const Catalog = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    summary_url: []const u8,
    shard_url: []const u8,
    status_value: std.atomic.Value(u8) = .init(@intFromEnum(Status.idle)),
    mutex: std.Io.Mutex = .init,
    summary: ?ParsedSummary = null,
    shard: ?ParsedShard = null,
    /// Handle to the most recent worker; joined on the next `refresh`/`deinit` so finished
    /// threads are reclaimed and shutdown waits for any in-flight fetch.
    worker_thread: ?std.Thread = null,

    /// `base_url` is the catalog root (e.g. `https://plugins.fizzyed.it/catalog`);
    /// `abi_fingerprint_hex` is this host's own fingerprint as `"0x..."`, matching a
    /// `catalog/<abi_fingerprint>/releases.json` path segment. Both are duped into the Catalog.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, base_url: []const u8, abi_fingerprint_hex: []const u8) !Catalog {
        const summary_url = try std.fmt.allocPrint(allocator, "{s}/summary.json", .{base_url});
        errdefer allocator.free(summary_url);
        const shard_url = try std.fmt.allocPrint(allocator, "{s}/{s}/releases.json", .{ base_url, abi_fingerprint_hex });
        return .{ .allocator = allocator, .io = io, .summary_url = summary_url, .shard_url = shard_url };
    }

    pub fn deinit(self: *Catalog) void {
        if (self.worker_thread) |t| {
            t.join();
            self.worker_thread = null;
        }
        if (self.summary) |*p| p.deinit();
        self.summary = null;
        if (self.shard) |*p| p.deinit();
        self.shard = null;
        self.allocator.free(self.summary_url);
        self.allocator.free(self.shard_url);
    }

    pub fn status(self: *Catalog) Status {
        return @enumFromInt(self.status_value.load(.acquire));
    }

    /// Kick off a background refresh. No-op while one is already in flight.
    pub fn refresh(self: *Catalog) void {
        if (self.status() == .fetching) return;
        if (self.worker_thread) |t| { // reclaim a previous, already-finished worker
            t.join();
            self.worker_thread = null;
        }
        self.status_value.store(@intFromEnum(Status.fetching), .release);
        self.worker_thread = std.Thread.spawn(.{}, worker, .{self}) catch {
            self.status_value.store(@intFromEnum(Status.failed), .release);
            return;
        };
    }

    fn worker(self: *Catalog) void {
        const fresh_summary = registry.fetchSummary(self.allocator, self.io, self.summary_url) catch {
            self.status_value.store(@intFromEnum(Status.failed), .release);
            return;
        };
        // Best-effort: any failure (network, 404 for a brand-new fingerprint nobody has
        // published for yet, malformed response) just means we keep whatever shard we already
        // had (possibly none) rather than failing the whole refresh.
        const fresh_shard = registry.fetchReleaseShard(self.allocator, self.io, self.shard_url) catch null;

        self.mutex.lockUncancelable(self.io);
        if (self.summary) |*p| p.deinit(); // free the previous summary; no leak
        self.summary = fresh_summary;
        if (fresh_shard) |s| {
            if (self.shard) |*p| p.deinit();
            self.shard = s;
        }
        self.mutex.unlock(self.io);
        self.status_value.store(@intFromEnum(Status.ready), .release);
    }

    /// A joined view of the latest summary + this host's release shard, for the duration the
    /// lock is held.
    pub const Snapshot = struct {
        summary: registry.Summary,
        shard: registry.ReleaseShard,
    };

    /// Lock the catalog and return the latest snapshot (or null if the summary has never loaded
    /// successfully). The slices stay valid until the matching `release` — hold the lock across
    /// any read of them. Pair with `release`.
    pub fn acquire(self: *Catalog) ?Snapshot {
        self.mutex.lockUncancelable(self.io);
        const summary = self.summary orelse return null;
        return .{
            .summary = summary.value,
            .shard = if (self.shard) |s| s.value else registry.ReleaseShard.empty,
        };
    }

    pub fn release(self: *Catalog) void {
        self.mutex.unlock(self.io);
    }
};

test {
    // Pull the building blocks' tests into the unit-test target.
    _ = registry;
    _ = compat;
    _ = download;
}
