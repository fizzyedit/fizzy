//! Plugin-store backend: catalog fetch (summary + this host's release shard) + verified download,
//! plus a `Catalog` that owns the latest parsed documents. Pure of dvui/globals — the caller
//! supplies `allocator`, a `std.Io`, and the host's own `abi_fingerprint` as a hex string (the
//! caller already computes this from `sdk.dylib.abi_fingerprint`; this layer stays free of
//! SDK-specific concerns). The store UI drives `Catalog` and tracks per-plugin install state
//! on top of this. Native refresh uses an `Io.Group` worker; the web build pumps browser GETs
//! on the UI thread (browse-only — no wasm plugin binaries).
const std = @import("std");
const builtin = @import("builtin");

const is_wasm = builtin.target.cpu.arch == .wasm32;

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

/// Owns the latest parsed `summary.json` + this host's `<abi_fingerprint>/releases.json`.
/// Native refresh runs off the UI thread in an `Io.Group` worker; the web build has no threads
/// and instead `pump`s browser GETs on the UI thread. Shared state is guarded by a
/// `std.Io.Mutex` on native — lock with `dvui.io`. The owner must outlive any in-flight refresh
/// (in the app it is `Editor`-owned, app-lifetime).
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
    /// The refresh worker, as a cancelable `Io` task group rather than a bare `std.Thread`.
    ///
    /// Shutdown has to *stop* an in-flight fetch, not merely wait for it. Nothing in the fetch
    /// path sets a network timeout, so a registry host that accepts nothing and refuses nothing
    /// (blackholed route, captive portal) parks the worker in a blocking connect for as long as
    /// the OS allows — with a `std.Thread`, `deinit`'s `join` inherits that wait and the whole
    /// app hangs at quit with no diagnostics. A `std.Io.Group` is the same shape the LSP client
    /// uses (`core/lsp/Client.zig`'s `tasks`): `cancel` requests cancelation *and* awaits, and
    /// `Io.Threaded` interrupts the blocked syscall so the worker returns `error.Canceled`
    /// promptly instead of sitting on a dead socket.
    tasks: std.Io.Group = .init,
    /// Web-only: which document the in-flight browser GET is for. Native refresh uses `tasks`.
    wasm_phase: enum { idle, summary, shard } = .idle,
    wasm_summary_url: ?[]u8 = null,
    wasm_shard_url: ?[]u8 = null,

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
        // Cancels *and* awaits, so the worker is provably finished — and therefore done touching
        // `summary`/`shard` — before they're freed below. No-op when nothing is in flight.
        // Wasm has no worker; the browser GETs are abandoned with the cache in `web_fetch`.
        if (comptime !is_wasm) self.tasks.cancel(self.io);
        if (self.summary) |*p| p.deinit();
        self.summary = null;
        if (self.shard) |*p| p.deinit();
        self.shard = null;
        if (self.wasm_summary_url) |u| self.allocator.free(u);
        if (self.wasm_shard_url) |u| self.allocator.free(u);
        self.allocator.free(self.summary_url);
        self.allocator.free(self.shard_url);
    }

    pub fn status(self: *Catalog) Status {
        return @enumFromInt(self.status_value.load(.acquire));
    }

    /// Kick off a background refresh. No-op while one is already in flight. Must be called from
    /// the UI thread — `Io.Group` is explicitly not threadsafe against its own `await`/`cancel`.
    pub fn refresh(self: *Catalog) void {
        if (self.status() == .fetching) return;
        if (comptime is_wasm) {
            self.startWasmRefresh();
            return;
        }
        // Release the previous worker's group resources. `status() != .fetching` means it has
        // already stored its final status, so this returns as soon as that task unwinds.
        self.tasks.await(self.io) catch {};
        self.status_value.store(@intFromEnum(Status.fetching), .release);
        // `concurrent`, not `async`: this must run on its own thread, never inline on the caller's.
        self.tasks.concurrent(self.io, worker, .{self}) catch {
            self.status_value.store(@intFromEnum(Status.failed), .release);
            return;
        };
    }

    fn startWasmRefresh(self: *Catalog) void {
        if (self.wasm_summary_url) |u| self.allocator.free(u);
        if (self.wasm_shard_url) |u| self.allocator.free(u);
        self.wasm_summary_url = cacheBust(self.allocator, self.io, self.summary_url) orelse {
            self.status_value.store(@intFromEnum(Status.failed), .release);
            return;
        };
        self.wasm_shard_url = cacheBust(self.allocator, self.io, self.shard_url);
        self.wasm_phase = .summary;
        self.status_value.store(@intFromEnum(Status.fetching), .release);
    }

    /// Advance in-flight browser GETs. UI thread, wasm only — a no-op natively. `fetcher` is the
    /// wasm `web_fetch` module (`request(allocator, url)` → pending / ready / failed); it is
    /// passed in rather than imported so this file stays a standalone test root (relative
    /// `@import` cannot leave `plugin_store/`). Native callers pass `{}`.
    pub fn pump(self: *Catalog, fetcher: anytype) void {
        if (comptime !is_wasm) return;
        switch (self.wasm_phase) {
            .idle => {},
            .summary => {
                const url = self.wasm_summary_url orelse {
                    self.failWasm();
                    return;
                };
                switch (fetcher.request(self.allocator, url)) {
                    .pending => {},
                    .failed => self.failWasm(),
                    .ready => |bytes| {
                        const parsed = std.json.parseFromSlice(registry.Summary, self.allocator, bytes, .{
                            .ignore_unknown_fields = true,
                            .allocate = .alloc_always,
                        }) catch {
                            self.failWasm();
                            return;
                        };
                        if (self.summary) |*p| p.deinit();
                        self.summary = parsed;
                        self.wasm_phase = .shard;
                    },
                }
            },
            .shard => {
                const url = self.wasm_shard_url orelse {
                    self.wasm_phase = .idle;
                    self.status_value.store(@intFromEnum(Status.ready), .release);
                    return;
                };
                switch (fetcher.request(self.allocator, url)) {
                    .pending => {},
                    // No shard for this fingerprint is the browse-only case: list the plugins,
                    // every card reads "no compatible build".
                    .failed => {
                        self.wasm_phase = .idle;
                        self.status_value.store(@intFromEnum(Status.ready), .release);
                    },
                    .ready => |bytes| {
                        if (std.json.parseFromSlice(registry.ReleaseShard, self.allocator, bytes, .{
                            .ignore_unknown_fields = true,
                            .allocate = .alloc_always,
                        })) |parsed| {
                            if (self.shard) |*p| p.deinit();
                            self.shard = parsed;
                        } else |_| {}
                        self.wasm_phase = .idle;
                        self.status_value.store(@intFromEnum(Status.ready), .release);
                    },
                }
            },
        }
    }

    fn failWasm(self: *Catalog) void {
        self.wasm_phase = .idle;
        self.status_value.store(@intFromEnum(Status.failed), .release);
    }

    /// Runs in the task group. Every failure path — including `error.Canceled` from a shutdown
    /// mid-fetch — lands on `.failed`, which is also the right resting state for a canceled
    /// refresh: the app is on its way down, and a later `refresh` would overwrite it anyway.
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

    /// Lock the catalog and return the latest snapshot, or null if the summary has never loaded
    /// successfully. The slices stay valid until the matching `release` — hold the lock across
    /// any read of them. Pair with `release`.
    ///
    /// **The lock is held either way**, including when this returns null. It used to unlock on
    /// the null path, which made the pairing conditional while every caller writes an
    /// unconditional `defer release()` — so drawing the store before the first summary arrived
    /// (offline, or the first launch of a fresh install) unlocked an unlocked mutex and panicked
    /// in `std.Io`. A lock whose release depends on the return value is a lock nobody can use
    /// correctly.
    pub fn acquire(self: *Catalog) ?Snapshot {
        // Single-threaded on wasm: the browser callback and the UI share a thread, so the
        // lock would only fight `std.Io.failing`'s mutex.
        if (comptime !is_wasm) self.mutex.lockUncancelable(self.io);
        const summary = self.summary orelse return null;
        return .{
            .summary = summary.value,
            .shard = if (self.shard) |s| s.value else registry.ReleaseShard.empty,
        };
    }

    pub fn release(self: *Catalog) void {
        if (comptime !is_wasm) self.mutex.unlock(self.io);
    }
};

fn cacheBust(allocator: std.mem.Allocator, io: std.Io, url: []const u8) ?[]u8 {
    const sep: u8 = if (std.mem.indexOfScalar(u8, url, '?') != null) '&' else '?';
    const nonce = std.Io.Clock.boot.now(io).nanoseconds;
    return std.fmt.allocPrint(allocator, "{s}{c}_={d}", .{ url, sep, nonce }) catch null;
}

test {
    // Pull the building blocks' tests into the unit-test target.
    _ = registry;
    _ = compat;
    _ = download;
}
