//! Plugin-store backend: registry fetch + compatibility matching + verified download, plus a
//! small threaded `Catalog` that owns the latest parsed index. Pure of dvui/globals — the
//! caller supplies `allocator` + `std.Io` (the app passes `dvui.io`). The store UI (Chunk 5)
//! drives `Catalog` and tracks per-plugin install state on top of this.
const std = @import("std");

pub const registry = @import("registry.zig");
pub const compat = @import("compat.zig");
pub const download = @import("download.zig");

pub const Index = registry.Index;
pub const PluginEntry = registry.PluginEntry;
pub const Release = registry.Release;

/// Lifecycle of the registry index fetch (not a per-plugin install state — that lives in the UI).
pub const Status = enum(u8) { idle, fetching, ready, failed };

const Parsed = std.json.Parsed(registry.Index);

/// Owns the latest parsed `index.json`, refreshed off the UI thread by a real `std.Thread`
/// worker. Shared state (`parsed`) is guarded by a `std.Io.Mutex` — the codebase's pattern for
/// coordinating a `std.Thread` worker with the GUI thread (see pixi's `SaveQueue`): lock with
/// `dvui.io`, and `join` the worker on `deinit`. The owner must outlive any in-flight refresh (in
/// the app it is `Editor`-owned, app-lifetime).
///
/// Read access goes through `acquire`/`release`: hold the lock across any read of the returned
/// `Index` so the worker can't free the arena underneath a reader.
pub const Catalog = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    status_value: std.atomic.Value(u8) = .init(@intFromEnum(Status.idle)),
    mutex: std.Io.Mutex = .init,
    parsed: ?Parsed = null,
    /// Handle to the most recent worker; joined on the next `refresh`/`deinit` so finished
    /// threads are reclaimed and shutdown waits for any in-flight fetch.
    worker_thread: ?std.Thread = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, url: []const u8) Catalog {
        return .{ .allocator = allocator, .io = io, .url = url };
    }

    pub fn deinit(self: *Catalog) void {
        if (self.worker_thread) |t| {
            t.join();
            self.worker_thread = null;
        }
        if (self.parsed) |*p| p.deinit();
        self.parsed = null;
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
        const fresh = registry.fetchIndex(self.allocator, self.io, self.url) catch {
            self.status_value.store(@intFromEnum(Status.failed), .release);
            return;
        };
        self.mutex.lockUncancelable(self.io);
        if (self.parsed) |*p| p.deinit(); // free the previous index; no leak
        self.parsed = fresh;
        self.mutex.unlock(self.io);
        self.status_value.store(@intFromEnum(Status.ready), .release);
    }

    /// Lock the catalog and return the parsed index (or null if none yet). The slices stay valid
    /// until the matching `release` — hold the lock across any read of them. Pair with `release`.
    pub fn acquire(self: *Catalog) ?registry.Index {
        self.mutex.lockUncancelable(self.io);
        return if (self.parsed) |p| p.value else null;
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
