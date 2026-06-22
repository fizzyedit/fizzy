//! Shell built-in: the **Plugins** sidebar tab — discover / install / update / enable / disable
//! / uninstall plugins. Registered above Settings.
//!
//! Downloads run on a worker thread (`Job`); the actual live load happens on the main thread in
//! `tick` (it mutates the Host registries + dvui keybinds). The registry index is fetched +
//! parsed by the backend (`store.Catalog`); compatibility is matched on the host ABI
//! fingerprint + arch.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const sdk = @import("sdk");
const icons = @import("icons");
const fizzy = @import("../fizzy.zig");
const store = @import("../backend/plugin_store/store.zig");
const PluginLoader = @import("PluginLoader.zig");

const compat = store.compat;
const version = sdk.version;
const dylib = sdk.dylib;

/// README rendering depends on the in-tree markdown engine, which links cmark (libc) and is
/// native-only. The store never runs on wasm (`register` bails on wasm32), so the web build gets
/// a no-op stub and the `readme`/`markdown` modules are only resolved on native.
const Readme = if (builtin.target.cpu.arch == .wasm32) struct {
    pub fn select(_: []const u8, _: []const u8, _: []const u8) void {}
    pub fn selectedId() ?[]const u8 {
        return null;
    }
    pub fn draw() void {}
    pub fn clear() void {}
    pub fn deinit() void {}
} else @import("readme.zig");

const StoreIcon = if (builtin.target.cpu.arch == .wasm32) struct {
    pub fn request(_: []const u8, _: []const u8, _: []const u8) void {}
    pub fn draw(_: []const u8) bool {
        return false;
    }
    pub fn deinit() void {}
} else @import("store_icon.zig");

pub const view_id = "shell.store";
/// Center provider that renders the selected plugin's README. Mirrors the way the workbench
/// center renders the active document: while the store tab is active and a plugin is selected,
/// `tick` swaps the active center to this provider; deselecting (or leaving the tab) restores
/// the previous center.
pub const readme_center_id = "shell.store.readme";
const default_registry_url = "https://plugins.fizzyed.it/catalog";

/// True while we have hijacked the active center to show a README, plus the center id to restore
/// when the selection is cleared or the store tab is no longer active.
var readme_center_active = false;
var saved_center: ?[]const u8 = null;

var catalog: ?store.Catalog = null;
var registry_url_owned: ?[]u8 = null;
var first_draw_done = false;

/// Upper/lower split (installed plugins on top, store on bottom) — same shape and autosizing
/// behaviour as the Pixi tools pane (`explorer/tools.zig`'s layers/palettes split): the top
/// pane's height autofits to its content every frame, and a manual drag becomes the new ceiling
/// so autofit never grows back past a size the user deliberately chose. The split ratio itself
/// is owned internally by the `PanedWidget` (persisted via `dvui.data`); only the ceiling and
/// the previous shown-count (to detect when a refit is needed) are ours to track. See `draw`.
var installed_max_split_ratio: f32 = 0.5;
var prev_installed_shown: usize = 0;

var store_scroll_info: dvui.ScrollInfo = .{ .horizontal = .auto };
var installed_scroll_info: dvui.ScrollInfo = .{ .horizontal = .auto };

/// Transient status line shown in the header (e.g. an action error). Module-owned buffer.
var status_message: [256]u8 = undefined;
var status_len: usize = 0;

fn setStatus(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&status_message, fmt, args) catch {
        status_len = 0;
        return;
    };
    status_len = s.len;
}

// ---- async install jobs ----------------------------------------------------

const JobStatus = enum(u8) { downloading, downloaded, failed };

const Job = struct {
    status: std.atomic.Value(u8),
    id: []u8,
    url: []u8,
    sha256: []u8,
    dest: []u8,
    is_update: bool,
    err_buf: [64]u8 = undefined,
    err_len: usize = 0,
};

var jobs: std.StringArrayHashMapUnmanaged(*Job) = .empty;

/// UI actions queued during `draw` and applied in `tick` so plugin unload never mutates
/// `host.plugins` (or dlcloses an image) while the store view is still iterating it.
const PendingAction = union(enum) {
    set_enabled: struct { id: []u8, enabled: bool },
    uninstall: struct { id: []u8 },
};

var pending_actions: std.ArrayListUnmanaged(PendingAction) = .empty;

/// Last-known display name per plugin id (app-allocator owned). A sideloaded plugin only exposes
/// its display name while loaded — once disabled it is unloaded and we'd otherwise fall back to the
/// bare id, which changes the A→Z sort position (e.g. "Terminal" → "ghostty") every time it is
/// toggled. We remember the name the first time we see it (loaded plugin or registry row) and reuse
/// it as the stable title for the disabled/failed states. (Session-scoped: a plugin disabled before
/// it was ever loaded this session still shows its id until enabled once.)
var name_cache: std.StringArrayHashMapUnmanaged([]u8) = .empty;

/// Last-known installed version per plugin id (app-allocator owned keys, plain values). Like
/// `name_cache`, a sideloaded plugin only exposes its version while loaded — once disabled it is
/// unloaded, and a failed build's version is only known if the dylib could be probed. We remember
/// the version the first time we see it (loaded plugin, failed-load probe, or on-disk probe) and
/// reuse it as the "current version" for disabled/failed cards.
var version_cache: std.StringArrayHashMapUnmanaged(std.SemanticVersion) = .empty;

/// Cache `id`'s version. Overwrites an existing entry so a reload/update always reflects the
/// latest known value.
fn rememberVersion(id: []const u8, v: std.SemanticVersion) void {
    const a = fizzy.app.allocator;
    const gop = version_cache.getOrPut(a, id) catch return;
    if (gop.found_existing) {
        gop.value_ptr.* = v;
        return;
    }
    const key = a.dupe(u8, id) catch {
        _ = version_cache.swapRemove(id);
        return;
    };
    gop.key_ptr.* = key;
    gop.value_ptr.* = v;
}

/// Cache `id`'s display name if it is a real name distinct from the id. Updates an existing entry
/// when the name changes (e.g. a version that renamed itself).
fn rememberName(id: []const u8, name: []const u8) void {
    if (name.len == 0 or std.mem.eql(u8, name, id)) return;
    const a = fizzy.app.allocator;
    const gop = name_cache.getOrPut(a, id) catch return;
    if (gop.found_existing) {
        if (std.mem.eql(u8, gop.value_ptr.*, name)) return;
        a.free(gop.value_ptr.*);
        gop.value_ptr.* = a.dupe(u8, name) catch {
            _ = name_cache.swapRemove(id);
            return;
        };
        return;
    }
    // New entry: own the key independently of the (borrowed) caller slice.
    const key = a.dupe(u8, id) catch {
        _ = name_cache.swapRemove(id);
        return;
    };
    gop.key_ptr.* = key;
    gop.value_ptr.* = a.dupe(u8, name) catch {
        _ = name_cache.swapRemove(id);
        a.free(key);
        return;
    };
}

/// The remembered display name for `id`, or `fallback` (the id) when we've never seen it loaded.
fn resolveTitle(id: []const u8, fallback: []const u8) []const u8 {
    return name_cache.get(id) orelse fallback;
}

/// Query the real display name + version of every disabled plugin straight from its on-disk
/// dylib (via the `fizzy_plugin_name`/version exports — no register), seeding `name_cache` and
/// `version_cache`. This covers plugins that were disabled *before* they were ever loaded this
/// session, so a disabled card shows its true name (and keeps its A→Z position) and current
/// version without a fragile on-disk cache. Cheap and bounded: only runs on first draw /
/// Refresh, and only probes ids whose name or version we don't already know.
fn probeDisabledInfo() void {
    const editor = fizzy.editor;
    const a = fizzy.app.allocator;
    const plugins_dir = std.fs.path.join(a, &.{ editor.config_folder, "plugins" }) catch return;
    defer a.free(plugins_dir);

    for (editor.disabled_plugin_ids.items) |id| {
        if (!std.unicode.utf8ValidateSlice(id)) continue;
        if (editor.host.pluginById(id) != null) continue; // loaded → info comes from the live plugin
        const have_name = name_cache.get(id) != null;
        const have_version = version_cache.get(id) != null;
        if (have_name and have_version) continue; // already known (registry / prior probe)
        const file_name = PluginLoader.pluginFilename(id, a) catch continue;
        defer a.free(file_name);
        const path = std.fs.path.join(a, &.{ plugins_dir, file_name }) catch continue;
        defer a.free(path);
        if (!have_name) {
            if (PluginLoader.probeName(a, path)) |name| {
                defer a.free(name);
                rememberName(id, name);
            }
        }
        if (!have_version) {
            if (PluginLoader.probeVersionInfo(path)) |info| {
                rememberVersion(id, info.plugin_version);
            }
        }
    }
}

pub fn register(host: *sdk.Host) !void {
    if (comptime builtin.target.cpu.arch == .wasm32) return; // no dylib loading on web
    const url = resolveRegistryUrl();
    const fp_hex = try std.fmt.allocPrint(fizzy.app.allocator, "0x{x}", .{dylib.abi_fingerprint});
    defer fizzy.app.allocator.free(fp_hex);
    catalog = try store.Catalog.init(fizzy.app.allocator, dvui.io, url, fp_hex);
    try host.registerSidebarView(.{
        .id = view_id,
        .icon = dvui.entypo.shop,
        .title = "Plugins",
        .draw = draw,
    });
    // README center provider. Registered after the workbench center (see `postInit` order) so it
    // never becomes the default active center; `tick` activates it on demand.
    try host.registerCenter(.{
        .id = readme_center_id,
        .draw = drawReadmeCenter,
    });
}

/// Center provider: paint the selected plugin's README. Active only while `tick` has swapped us
/// in (store tab active + a plugin selected). Uses the same rounded, content-colored card the
/// workbench homepage / empty state draws (`sdk.pane_layout.emptyStateCard`) so the store center
/// matches the rest of the app.
fn drawReadmeCenter(_: ?*anyopaque) anyerror!dvui.App.Result {
    const host = &fizzy.editor.host;
    var content_color = dvui.themeGet().color(.window, .fill);
    switch (builtin.os.tag) {
        .macos, .windows => {
            if (!host.isMaximized()) content_color = content_color.opacity(host.contentOpacity());
        },
        else => {},
    }

    var card = sdk.pane_layout.emptyStateCard(content_color, hashId(readme_center_id));
    defer card.deinit();

    var pane = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .all(16) });
    defer pane.deinit();
    Readme.draw();
    return .ok;
}

/// `FIZZY_PLUGIN_REGISTRY_URL` overrides the default catalog *base* URL (used for local E2E
/// testing) — `store.Catalog.init` appends `/summary.json` and `/<abi_fingerprint>/releases.json`
/// to whatever this returns. Owned for the process lifetime (freed in `deinit`).
fn resolveRegistryUrl() []const u8 {
    if (std.process.Environ.getAlloc(fizzy.processEnviron(), fizzy.app.allocator, "FIZZY_PLUGIN_REGISTRY_URL")) |override| {
        if (override.len > 0) {
            registry_url_owned = override;
            return override;
        }
        fizzy.app.allocator.free(override);
    } else |_| {}
    return default_registry_url;
}

pub fn deinit() void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    for (jobs.values()) |job| freeJob(job);
    jobs.deinit(fizzy.app.allocator);
    for (pending_actions.items) |action| switch (action) {
        .set_enabled => |a| fizzy.app.allocator.free(a.id),
        .uninstall => |a| fizzy.app.allocator.free(a.id),
    };
    pending_actions.deinit(fizzy.app.allocator);
    for (name_cache.keys()) |k| fizzy.app.allocator.free(k);
    for (name_cache.values()) |v| fizzy.app.allocator.free(v);
    name_cache.deinit(fizzy.app.allocator);
    for (version_cache.keys()) |k| fizzy.app.allocator.free(k);
    version_cache.deinit(fizzy.app.allocator);
    Readme.deinit();
    StoreIcon.deinit();
    if (catalog) |*c| c.deinit();
    catalog = null;
    if (registry_url_owned) |u| {
        fizzy.app.allocator.free(u);
        registry_url_owned = null;
    }
}

fn freeJob(job: *Job) void {
    fizzy.app.allocator.free(job.id);
    fizzy.app.allocator.free(job.url);
    fizzy.app.allocator.free(job.sha256);
    fizzy.app.allocator.free(job.dest);
    fizzy.app.allocator.destroy(job);
}

// ---- per-frame completion (main thread) ------------------------------------

/// Complete any finished downloads by loading them live, and apply plugin enable/disable /
/// uninstall requests queued from the store UI. Called once per frame from `Editor.tick`,
/// before the Host-registry iterations, so a freshly-registered or unloaded plugin never
/// mutates a list mid-iteration.
pub fn tick() void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;

    syncReadmeCenter();

    for (pending_actions.items) |action| switch (action) {
        .set_enabled => |a| {
            applySetEnabled(a.id, a.enabled);
            fizzy.app.allocator.free(a.id);
        },
        .uninstall => |a| {
            applyUninstall(a.id);
            fizzy.app.allocator.free(a.id);
        },
    };
    pending_actions.clearRetainingCapacity();

    var i: usize = 0;
    while (i < jobs.count()) {
        const job = jobs.values()[i];
        switch (@as(JobStatus, @enumFromInt(job.status.load(.acquire)))) {
            .downloading, .failed => i += 1,
            .downloaded => {
                // `force = false`: an in-place update must not silently discard unsaved
                // documents the plugin owns, same protection `applySetEnabled`/
                // `applyUninstall` give the manual disable/uninstall actions. On
                // `DirtyDocuments`, the downloaded file stays at `job.dest` so Retry
                // (which threads `job.is_update` through, see `drawCardControls`) can
                // reapply the update once the user has saved/closed.
                const loaded = if (job.is_update)
                    fizzy.editor.updatePlugin(job.id, false)
                else
                    fizzy.editor.installAndLoadPlugin(job.id);
                loaded catch |err| {
                    if (err == error.DirtyDocuments) {
                        setStatus("'{s}' has unsaved changes — save or close them first", .{job.id});
                    } else {
                        setStatus("'{s}' failed to load: {s}", .{ job.id, @errorName(err) });
                    }
                    const n = @min(@errorName(err).len, job.err_buf.len);
                    @memcpy(job.err_buf[0..n], @errorName(err)[0..n]);
                    job.err_len = n;
                    job.status.store(@intFromEnum(JobStatus.failed), .release);
                    i += 1;
                    continue;
                };
                // Installed + loaded: drop the job so the card shows normal installed state.
                jobs.swapRemoveAt(i);
                freeJob(job);
                // do not advance i — swapRemove moved a new entry into slot i
            },
        }
    }
}

/// Drive the active center from the store selection: while the store tab is active and a plugin
/// is selected, show its README in the center; otherwise restore whatever center was active when
/// we took over. Idempotent — safe to call every frame.
fn syncReadmeCenter() void {
    const host = &fizzy.editor.host;
    const want = host.isActiveSidebarView(view_id) and Readme.selectedId() != null;
    if (want and !readme_center_active) {
        saved_center = host.active_center;
        host.setActiveCenter(readme_center_id);
        readme_center_active = true;
    } else if (!want and readme_center_active) {
        host.active_center = saved_center;
        saved_center = null;
        readme_center_active = false;
    }
}

/// Select `entry` (showing its README in the center), or clear the selection if it is already the
/// selected card. Only one plugin is selectable at a time.
fn toggleSelect(entry: StoreEntry) void {
    if (Readme.selectedId()) |sid| {
        if (std.mem.eql(u8, sid, entry.id)) {
            Readme.clear();
            return;
        }
    }
    const src = readmeSource(entry) orelse RepoSource{ .repo = "" };
    Readme.select(entry.id, src.repo, src.subpath);
}

fn worker(job: *Job) void {
    store.download.download(fizzy.app.allocator, dvui.io, job.url, job.sha256, job.dest) catch |err| {
        const n = @min(@errorName(err).len, job.err_buf.len);
        @memcpy(job.err_buf[0..n], @errorName(err)[0..n]);
        job.err_len = n;
        job.status.store(@intFromEnum(JobStatus.failed), .release);
        return;
    };
    job.status.store(@intFromEnum(JobStatus.downloaded), .release);
}

fn removeJob(id: []const u8) void {
    if (jobs.fetchSwapRemove(id)) |kv| freeJob(kv.value);
}

/// Kick off a download for `id`'s selected release on a worker thread.
fn startDownload(id: []const u8, release: store.ShardRelease, is_update: bool) void {
    removeJob(id); // replace any prior failed job
    const dl = release.downloadFor(compat.hostKey()) orelse return;

    const job = buildJob(id, dl, is_update) catch {
        setStatus("could not prepare download for '{s}'", .{id});
        return;
    };
    jobs.put(fizzy.app.allocator, job.id, job) catch {
        freeJob(job);
        return;
    };
    const thread = std.Thread.spawn(.{}, worker, .{job}) catch {
        _ = jobs.swapRemove(job.id);
        freeJob(job);
        setStatus("could not start download for '{s}'", .{id});
        return;
    };
    thread.detach();
}

/// Allocate a `Job` with all strings owned; `errdefer` unwinds every partial allocation so a
/// mid-build OOM never leaks.
fn buildJob(id: []const u8, dl: store.registry.Download, is_update: bool) !*Job {
    const a = fizzy.app.allocator;

    const plugins_dir = try std.fs.path.join(a, &.{ fizzy.editor.config_folder, "plugins" });
    defer a.free(plugins_dir);
    std.Io.Dir.createDirAbsolute(dvui.io, plugins_dir, .default_dir) catch {}; // best-effort; exists is fine
    const file_name = try PluginLoader.pluginFilename(id, a);
    defer a.free(file_name);

    const job = try a.create(Job);
    errdefer a.destroy(job);
    const id_dup = try a.dupe(u8, id);
    errdefer a.free(id_dup);
    const url_dup = try a.dupe(u8, dl.url);
    errdefer a.free(url_dup);
    const sha_dup = try a.dupe(u8, dl.sha256);
    errdefer a.free(sha_dup);
    const dest = try std.fs.path.join(a, &.{ plugins_dir, file_name });
    errdefer a.free(dest);

    job.* = .{
        .status = .init(@intFromEnum(JobStatus.downloading)),
        .id = id_dup,
        .url = url_dup,
        .sha256 = sha_dup,
        .dest = dest,
        .is_update = is_update,
    };
    return job;
}

// ---- drawing ---------------------------------------------------------------

fn installedVersion(id: []const u8) ?std.SemanticVersion {
    for (fizzy.editor.loaded_plugin_libs.items) |loaded| {
        if (std.mem.eql(u8, loaded.plugin_id, id)) return loaded.version_info.plugin_version;
    }
    return null;
}

/// The recorded load-failure for `id`, if any — looked up straight off `editor.failed_user_plugins`
/// rather than `StoreEntry`, so it surfaces even when a registry row (which takes merge precedence
/// over the local `.failed` row, see `draw`) shadows the same id.
fn failedInfo(id: []const u8) ?fizzy.Editor.FailedPlugin {
    for (fizzy.editor.failed_user_plugins.items) |f| {
        if (std.mem.eql(u8, f.id, id)) return f;
    }
    return null;
}

/// The plugin's current on-disk version, regardless of whether it is loaded, disabled, or a
/// rejected (failed) build: the live loaded version when running, else a failed build's probed
/// version, else the last version we remembered (loaded earlier this session, or probed while
/// disabled — see `probeDisabledInfo`).
fn currentVersion(id: []const u8) ?std.SemanticVersion {
    if (installedVersion(id)) |v| return v;
    if (failedInfo(id)) |f| {
        if (f.plugin_version) |v| return v;
    }
    return version_cache.get(id);
}

/// The highest version published across *every* fingerprint of `entry`'s registry row, regardless
/// of host compatibility — "what the author has shipped", shown on every card with a store
/// presence (see `infoLine`). Distinct from `selectedRelease`, which only considers this host's
/// release (from the fetched shard) and drives the Install/Update actions. Precomputed
/// server-side into `summary.json`'s `latest_version` — the client only ever fetches its own
/// fingerprint's shard, so it can't itself see what other fingerprints have published.
fn latestRegistryVersion(entry: StoreEntry) ?[]const u8 {
    const r = entry.registry orelse return null;
    return if (r.latest_version.len > 0) r.latest_version else null;
}

fn isBundled(id: []const u8) bool {
    return std.mem.eql(u8, id, "workbench") or
        std.mem.eql(u8, id, "text") or
        std.mem.eql(u8, id, "markdown") or
        std.mem.eql(u8, id, "image");
}

/// One deterministic row in the store tree, merged from the registry index plus the local
/// plugin/disabled/failed lists.
///
/// **Lifetime:** every slice here is *borrowed* with one of three lifetimes — registry strings
/// are valid only while the catalog lock is held (the worker frees the arena on `refresh`),
/// `plugin.display_name`/`plugin.id` live in dylib/static memory only while the plugin is
/// loaded, and disabled ids are app-allocator-owned. The whole build → sort → draw pass runs
/// inside a single `catalog.acquire()`/`release()` scope and the dvui frame arena, so none of
/// these are retained past the lock release or across frames.
const StoreEntry = struct {
    id: []const u8,
    title: []const u8,
    kind: enum { registry, local, disabled, failed },
    registry: ?store.SummaryEntry = null,
    /// This host's release for `id`, if the fetched shard has one (already fingerprint-resolved
    /// server-side — see `store.ShardRelease`). Still needs an arch check; see `selectedRelease`.
    release: ?store.ShardRelease = null,
    plugin: ?*sdk.Plugin = null,
};

/// Stable, position-independent widget/branch id for a plugin id (avoids the old loop-index
/// ids that shifted as rows were added/removed).
fn hashId(id: []const u8) usize {
    return @truncate(std.hash.Wyhash.hash(0, id));
}

fn containsId(entries: []const StoreEntry, id: []const u8) bool {
    for (entries) |e| {
        if (std.mem.eql(u8, e.id, id)) return true;
    }
    return false;
}

/// A→Z by display title (case-insensitive ASCII), tie-broken on id for stability.
fn entryLess(_: void, lhs: StoreEntry, rhs: StoreEntry) bool {
    return switch (std.ascii.orderIgnoreCase(lhs.title, rhs.title)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.order(u8, lhs.id, rhs.id) == .lt,
    };
}

fn fieldMatches(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

/// Case-insensitive substring match across id, title, and (for registry rows) description,
/// author, and tags — mirroring the Files tab filter behaviour.
fn matchesFilter(entry: StoreEntry, filter: []const u8) bool {
    if (filter.len == 0) return true;
    if (fieldMatches(entry.id, filter)) return true;
    if (fieldMatches(entry.title, filter)) return true;
    if (entry.registry) |r| {
        if (fieldMatches(r.description, filter)) return true;
        if (fieldMatches(r.author, filter)) return true;
        for (r.tags) |tag| if (fieldMatches(tag, filter)) return true;
    }
    if (entry.plugin) |p| {
        if (fieldMatches(p.id, filter)) return true;
        if (fieldMatches(p.display_name, filter)) return true;
    }
    return false;
}

fn draw(_: ?*anyopaque) anyerror!void {
    // Unlike the old flat list, the tab now fills the full explorer viewport height
    // (`expand = .both`, not just `.horizontal`) so the upper/lower paned split below gets a
    // genuinely bounded height to divide — each pane then scrolls its own overflow (see
    // `drawStoreSection`/`drawInstalledSection`) rather than the whole tab growing forever and
    // leaning on the explorer's own scrollArea (`files.zig`'s tree still does that; we don't).
    var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer vbox.deinit();

    // First time the tab is shown, fetch the registry and learn disabled plugins' real names.
    if (!first_draw_done) {
        first_draw_done = true;
        if (catalog) |*c| c.refresh();
        probeDisabledInfo();
    }

    try drawHeader();

    // Filter row — same shape as the file tree (search icon + borderless text entry).
    var filter_hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 4 } });
    dvui.icon(
        @src(),
        "FilterIcon",
        icons.tvg.lucide.search,
        .{ .stroke_color = dvui.themeGet().color(.window, .text) },
        .{ .gravity_y = 0.5, .padding = dvui.Rect.all(0) },
    );
    const filter_edit = dvui.textEntry(@src(), .{ .placeholder = "Filter..." }, .{
        .expand = .horizontal,
        .background = false,
    });
    const filter_text = filter_edit.getText();
    filter_edit.deinit();
    filter_hbox.deinit();

    const cat = if (catalog) |*c| c else return;
    const maybe_snapshot = cat.acquire();
    defer cat.release();

    const arena = dvui.currentWindow().arena();
    const editor = fizzy.editor;

    // Store entries (upper pane): one row per registry plugin, independent of local install
    // state — a pure "what does the store publish" list. See `drawStoreCard`.
    var store_entries: std.ArrayListUnmanaged(StoreEntry) = .empty;
    if (maybe_snapshot) |snap| {
        for (snap.summary.plugins) |entry| {
            rememberName(entry.id, entry.name);
            store_entries.append(arena, .{
                .id = entry.id,
                .title = if (entry.name.len > 0) entry.name else resolveTitle(entry.id, entry.id),
                .kind = .registry,
                .registry = entry,
                .release = snap.shard.releaseFor(entry.id),
            }) catch {};
        }
    }
    std.sort.pdq(StoreEntry, store_entries.items, {}, entryLess);

    // Installed entries (lower pane): everything genuinely present locally — loaded,
    // disabled-on-disk, sideloaded, or a failed/rejected build — enriched with a matching
    // registry row (for "store vX" / Update-availability) wherever the registry knows the id too.
    var installed_entries: std.ArrayListUnmanaged(StoreEntry) = .empty;
    for (editor.host.plugins.items) |plugin| {
        rememberName(plugin.id, plugin.display_name);
        if (installedVersion(plugin.id)) |v| rememberVersion(plugin.id, v);
        installed_entries.append(arena, .{
            .id = plugin.id,
            .title = plugin.display_name,
            .kind = .local,
            .registry = if (maybe_snapshot) |snap| snap.summary.pluginById(plugin.id) else null,
            .release = if (maybe_snapshot) |snap| snap.shard.releaseFor(plugin.id) else null,
            .plugin = plugin,
        }) catch {};
    }
    // Disabled plugins are unloaded (not in `host.plugins`) but remain on disk; reuse the name +
    // version we remembered while they were loaded so they keep their A→Z position and current
    // version across enable/disable.
    for (editor.disabled_plugin_ids.items) |id| {
        if (!std.unicode.utf8ValidateSlice(id)) continue;
        if (editor.host.pluginById(id) != null) continue;
        if (containsId(installed_entries.items, id)) continue;
        installed_entries.append(arena, .{
            .id = id,
            .title = resolveTitle(id, id),
            .kind = .disabled,
            .registry = if (maybe_snapshot) |snap| snap.summary.pluginById(id) else null,
            .release = if (maybe_snapshot) |snap| snap.shard.releaseFor(id) else null,
        }) catch {};
    }
    // Load failures. The reason + probed version are read directly off
    // `editor.failed_user_plugins` when drawing (see `failedInfo`/`currentVersion`).
    for (editor.failed_user_plugins.items) |f| {
        if (f.plugin_version) |v| rememberVersion(f.id, v);
        if (containsId(installed_entries.items, f.id)) continue;
        installed_entries.append(arena, .{
            .id = f.id,
            .title = resolveTitle(f.id, f.id),
            .kind = .failed,
            .registry = if (maybe_snapshot) |snap| snap.summary.pluginById(f.id) else null,
            .release = if (maybe_snapshot) |snap| snap.shard.releaseFor(f.id) else null,
        }) catch {};
    }
    std.sort.pdq(StoreEntry, installed_entries.items, {}, entryLess);

    // Surface registry-fetch state above the split (installed plugins still render below it).
    // `.fetching` fires both on the initial load and on a manual refresh, so the spinner shows
    // even once `maybe_snapshot` is already populated from a previous fetch.
    switch (cat.status()) {
        .fetching => {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .margin = .{ .y = 8 } });
            defer row.deinit();
            fizzy.dvui.bubbleSpinner(@src(), .{
                .min_size_content = .{ .w = 18, .h = 18 },
                .gravity_y = 0.5,
                .color_text = dvui.themeGet().color(.window, .text),
                .padding = .{ .w = 8 },
            }, .{});
            dvui.labelNoFmt(@src(), "Fetching plugin registry…", .{}, .{ .gravity_y = 0.5 });
        },
        .failed => if (maybe_snapshot == null) dvui.labelNoFmt(@src(), "Could not reach the plugin registry.", .{}, .{
            .margin = .{ .y = 8 },
            .color_text = dvui.themeGet().color(.err, .text),
        }),
        else => {},
    }

    // Upper/lower split — identical shape and autosizing behaviour to the Pixi tools pane's
    // layers/palettes split (`explorer/tools.zig`): the installed pane autofits snugly to its
    // content every frame, up to `installed_max_split_ratio`, unless the sash is actively being
    // dragged or an animation is in flight — a manual drag becomes the new ceiling so autofit
    // never grows back past a size the user deliberately chose.
    var paned = fizzy.dvui.paned(@src(), .{
        .direction = .vertical,
        .collapsed_size = 0,
        .handle_size = 10,
        .handle_dynamic = .{},
    }, .{ .expand = .both, .background = false });
    defer paned.deinit();

    if (paned.dragging) installed_max_split_ratio = paned.split_ratio.*;

    var shown_installed: usize = 0;
    if (paned.showFirst()) {
        shown_installed = drawInstalledSection(installed_entries.items, filter_text);
    }

    // Must run between `showFirst` and `showSecond` — `getFirstFittedRatio` reads the min size
    // the first pane's just-drawn content published.
    const autofit = !paned.dragging and !paned.animating;
    if (dvui.firstFrame(paned.data().id) or prev_installed_shown != shown_installed or autofit) {
        if (dvui.firstFrame(paned.data().id)) {
            // Min sizes for the subtree aren't published yet on the very first frame — so a fit
            // computed right now would be wrong. Nudge open (never hard-close to exactly 0):
            // `showFirst` below gates whether the installed pane's content runs *at all*, so a
            // 0 here would deadlock — the pane could never publish a size to refit from again,
            // and only a manual drag of the sash would ever reopen it. Refit properly next frame.
            paned.split_ratio.* = 1.0;
        } else {
            const ratio = paned.getFirstFittedRatio(.{
                .min_split = 0,
                .max_split = @min(installed_max_split_ratio, 0.6),
                .min_size = 0,
            });
            const diff = @abs(ratio - paned.split_ratio.*);
            if (diff > 0.000001) {
                paned.animateSplit(ratio, dvui.easing.outBack);
            }
        }
    }
    prev_installed_shown = shown_installed;

    if (paned.showSecond()) {
        _ = drawStoreSection(store_entries.items, filter_text, maybe_snapshot == null and cat.status() == .fetching);
    }
}

/// Lower pane: a pure "browse the store" list, one card per registry plugin. Wrapped in its
/// own scrollArea (independent of the installed pane above) with the same edge-shadow treatment
/// `explorer/Explorer.zig` uses, so a manually-shrunk pane or an overly-wide card still scrolls
/// with the usual visual hint instead of clipping silently. Returns the shown count (unused by
/// the caller now that the store pane no longer drives the paned autofit).
fn drawStoreSection(entries: []const StoreEntry, filter_text: []const u8, is_first_fetch: bool) usize {
    dvui.labelNoFmt(@src(), "STORE", .{}, .{ .font = dvui.Font.theme(.heading), .margin = .{ .x = 8 } });

    var pane_box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = false });
    defer pane_box.deinit();

    var scroll = dvui.scrollArea(@src(), .{
        .scroll_info = &store_scroll_info,
        .horizontal_bar = .auto_overlay,
        .vertical_bar = .auto_overlay,
    }, .{ .expand = .both, .background = false });

    var shown: usize = 0;
    for (entries) |entry| {
        if (!matchesFilter(entry, filter_text)) continue;
        shown += 1;
        drawStoreCard(entry);
    }
    // While the very first fetch is still in flight, the top banner's spinner already explains
    // the empty pane — skip the "no plugins" fallback so we don't show both at once.
    if (shown == 0 and !is_first_fetch) {
        dvui.labelNoFmt(
            @src(),
            if (filter_text.len > 0) "No store plugins match the filter." else "No plugins available in the store.",
            .{},
            .{ .margin = .{ .y = 8 } },
        );
    }

    const vertical_scroll = scroll.si.offset(.vertical);
    const horizontal_scroll = scroll.si.offset(.horizontal);
    scroll.deinit();

    if (vertical_scroll > 0.0) fizzy.dvui.drawEdgeShadow(pane_box.data().contentRectScale(), .top, .{});
    if (store_scroll_info.virtual_size.h > store_scroll_info.viewport.h) fizzy.dvui.drawEdgeShadow(pane_box.data().contentRectScale(), .bottom, .{});
    if (store_scroll_info.virtual_size.w > store_scroll_info.viewport.w) fizzy.dvui.drawEdgeShadow(pane_box.data().contentRectScale(), .right, .{});
    if (horizontal_scroll > 0.0) fizzy.dvui.drawEdgeShadow(pane_box.data().contentRectScale(), .left, .{});

    return shown;
}

/// Upper pane: everything genuinely present locally, grouped under "Local" (sideloaded dylibs)
/// and "Built-in" (bundled + static built-ins) headers. This is the *only* place enable/disable,
/// update, uninstall, and failed-to-load detail show up — see `drawCard`. Returns the shown
/// count (drives the paned autofit refit trigger in `draw`).
fn drawInstalledSection(entries: []const StoreEntry, filter_text: []const u8) usize {
    dvui.labelNoFmt(@src(), "INSTALLED", .{}, .{ .font = dvui.Font.theme(.heading), .margin = .{ .y = 4 } });

    var pane_box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = false });
    defer pane_box.deinit();

    var scroll = dvui.scrollArea(@src(), .{
        .scroll_info = &installed_scroll_info,
        .horizontal_bar = .auto_overlay,
        .vertical_bar = .auto_overlay,
    }, .{ .expand = .both, .background = false });

    var shown: usize = 0;

    var shown_local: usize = 0;
    for (entries) |entry| {
        if (isBuiltIn(entry.id)) continue;
        if (!matchesFilter(entry, filter_text)) continue;
        if (shown_local == 0) drawSectionHeader("Local", 0);
        shown_local += 1;
        shown += 1;
        drawCard(entry);
    }

    var shown_builtin: usize = 0;
    for (entries) |entry| {
        if (!isBuiltIn(entry.id)) continue;
        if (!matchesFilter(entry, filter_text)) continue;
        if (shown_builtin == 0) drawSectionHeader("Built-in", 1);
        shown_builtin += 1;
        shown += 1;
        drawCard(entry);
    }

    if (shown == 0) {
        dvui.labelNoFmt(
            @src(),
            if (filter_text.len > 0) "No installed plugins match the filter." else "No plugins installed.",
            .{},
            .{ .margin = .{ .y = 8 } },
        );
    }

    const vertical_scroll = scroll.si.offset(.vertical);
    const horizontal_scroll = scroll.si.offset(.horizontal);
    scroll.deinit();

    if (vertical_scroll > 0.0) fizzy.dvui.drawEdgeShadow(pane_box.data().contentRectScale(), .top, .{});
    if (installed_scroll_info.virtual_size.h > installed_scroll_info.viewport.h) fizzy.dvui.drawEdgeShadow(pane_box.data().contentRectScale(), .bottom, .{});
    if (installed_scroll_info.virtual_size.w > installed_scroll_info.viewport.w) fizzy.dvui.drawEdgeShadow(pane_box.data().contentRectScale(), .right, .{});
    if (horizontal_scroll > 0.0) fizzy.dvui.drawEdgeShadow(pane_box.data().contentRectScale(), .left, .{});

    return shown;
}

/// Small uppercase-ish section label above a group of cards in the upper pane. `id_extra`
/// disambiguates the "Local" and "Built-in" calls, which otherwise share a source location.
fn drawSectionHeader(title: []const u8, id_extra: usize) void {
    dvui.labelNoFmt(@src(), title, .{}, .{
        .id_extra = id_extra,
        .font = dvui.Font.theme(.heading),
        .color_text = dvui.themeGet().color(.control, .text),
        .margin = .{ .x = 4, .y = 6 },
    });
}

/// Bundled built-ins (always-linked, protected) belong in the "Built-in" group rather than "Installed".
fn isBuiltIn(id: []const u8) bool {
    return isBundled(id);
}

/// Lower-pane card: full state — enabled checkbox, update/uninstall, failed-to-load detail —
/// via `drawCardControls`/`infoLine` (which still shows "installed vX"). See `drawCardShell`.
fn drawCard(entry: StoreEntry) void {
    var buf: [192]u8 = undefined;
    drawCardShell(entry, drawCardControls, infoLine(&buf, entry), true);
}

/// Upper-pane card: browse-only — just an install button or a "no compatible build" message via
/// `drawStoreCardControls`/`storeInfoLine` (never "installed vX": that's the lower pane's job,
/// even for a store plugin the user happens to already have installed). See `drawCardShell`.
fn drawStoreCard(entry: StoreEntry) void {
    var buf: [192]u8 = undefined;
    drawCardShell(entry, drawStoreCardControls, storeInfoLine(&buf, entry), false);
}

/// Shared card shell: a clickable container (logo + info + state controls). Clicking anywhere
/// outside the controls selects the plugin (its README shows in the center). The controls consume
/// their own clicks so the card-level click never double-fires. `controls` draws the
/// right-justified state controls (differs between the store and installed cards, see
/// `drawStoreCardControls`/`drawCardControls`); `row2_text` is the already-formatted dim
/// monospace line (differs likewise, see `storeInfoLine`/`infoLine`); `show_failure` gates the
/// failed-to-load detail block, which only makes sense on an installed-pane card.
fn drawCardShell(entry: StoreEntry, controls: *const fn (StoreEntry) void, row2_text: []const u8, show_failure: bool) void {
    const theme = dvui.themeGet();
    const selected = if (Readme.selectedId()) |sid| std.mem.eql(u8, sid, entry.id) else false;
    // Disabled plugins read as a faded card: half the surface fill opacity and half the shadow.
    const disabled = fizzy.editor.isPluginDisabled(entry.id);

    const fill = if (selected)
        theme.color(.control, .fill).opacity(0.5)
    else
        theme.color(.content, .fill).opacity(if (disabled) 0.5 else 1.0);
    const shadow_alpha: f32 = if (disabled) 0.125 else 0.25;

    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{}, .{
        .id_extra = hashId(entry.id),
        .expand = .horizontal,
        .margin = .all(4),
        .padding = .all(8),
        .corners = dvui.CornerRect.all(8),
        .background = true,
        .color_fill = fill,
        .color_fill_hover = theme.color(.control, .fill).opacity(0.5),
        .color_fill_press = theme.color(.control, .fill_press),
        .box_shadow = .{
            .color = .black,
            .corners = dvui.CornerRect.all(8),
            .fade = 4,
            .alpha = shadow_alpha,
        },
    });
    defer bw.deinit();
    // Hover highlight without consuming click events, so the inner controls get first dibs; the
    // card's own click is processed *after* the controls (see `bw.processEvents()` below).
    bw.processHover();
    bw.drawBackground();

    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hbox.deinit();

        // 1. Logo (gravity 0). Fetch `ICON.png` from the plugin repo when known; fall back to a
        // loaded plugin's registered icon, then the generic placeholder.
        {
            var logo = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .gravity_y = 0.5,
                .min_size_content = .{ .w = 32, .h = 32 },
            });
            defer logo.deinit();
            if (repoSource(entry)) |src| StoreIcon.request(entry.id, src.repo, src.subpath);
            const drew = StoreIcon.draw(entry.id) or fizzy.editor.host.drawPluginIcon(entry.id);
            if (!drew) {
                dvui.icon(
                    @src(),
                    "PluginLogo",
                    icons.tvg.lucide.package,
                    .{ .stroke_color = theme.color(.window, .text) },
                    .{ .gravity_y = 0.5, .min_size_content = .{ .w = 32, .h = 32 } },
                );
            }
        }

        // 2. State controls, right-justified. Must be laid out *before* the (expand-horizontal)
        // info column below: a `gravity_x = 1.0` child reserves its natural width from the right
        // edge of whatever's left regardless of draw order, but an `expand`-ing sibling's
        // bottom-up min size is its full *unwrapped* text width (wrapping text layouts don't
        // shrink their reported min size — see the info column) — if info claimed space first,
        // that inflated want would eat 100% of what's left and starve these controls down to a
        // zero-width row (the Uninstall trash button silently disappearing). These run their own
        // processEvents and consume their clicks before the card does.
        controls(entry);

        // Claim the card-body click *now*, before the info column below: `dvui.clicked` skips
        // events a widget earlier in this pass already handled, and a `dvui.textLayout` always
        // captures press/release for its own text-selection (see its `processEvent`) regardless
        // of whether anyone actually wants to select that text. If the info column ran first, it
        // would silently steal every click landing on the failure text (the only remaining
        // `textLayout` below — title/date/info-line are plain labels now), so this has to run
        // after the (already-first) controls but before the (still-to-come) text.
        bw.processEvents();

        // 3. Info column: title + upload date on one row, then a dim monospace info row.
        {
            var info = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .horizontal,
                .gravity_y = 0.5,
                .margin = .{ .x = 8 },
            });
            defer info.deinit();

            // The id/version row (row2, drawn below) is the *only* thing allowed to set the
            // floor under this card — logo + controls (already laid out) plus this text is
            // exactly the width the card should never shrink below, triggering the explorer's
            // horizontal scroll instead. Everything else in this column (title/date, the failure
            // detail) must be capped to this width rather than being free to inflate the floor
            // themselves. Measured directly from font metrics (matching what `LabelWidget` does
            // internally — text size plus its default 6px-a-side padding) so the value is exact
            // and available *before* row2 is actually drawn below.
            const row2_font = dvui.Font.theme(.mono);
            const row2_w = row2_font.textSize(row2_text).w + 12;

            {
                var title_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .horizontal,
                    .max_size_content = .{ .w = row2_w, .h = std.math.floatMax(f32) },
                });
                defer title_row.deinit();
                dvui.labelNoFmt(@src(), entry.title, .{}, .{ .font = dvui.Font.theme(.title), .expand = .horizontal });
                if (releaseDate(entry)) |date| {
                    dvui.labelNoFmt(@src(), date, .{}, .{
                        .font = dvui.Font.theme(.mono),
                        .color_text = theme.color(.control, .text),
                        .gravity_y = 0.5,
                        .margin = .{ .x = 6 },
                    });
                }
            }

            // A plain `label` reports its full unwrapped text width as its min size — that's
            // exactly what we want here: the card (and the whole tab, see `draw`) should never
            // get squeezed narrower than this line, so a long id/version string pushes the card
            // wider and the explorer's scrollArea takes over horizontally instead of wrapping.
            dvui.labelNoFmt(@src(), row2_text, .{}, .{
                .font = row2_font,
                .color_text = theme.color(.control, .text),
            });

            // A local build that is on disk but rejected at load time (ABI/SDK mismatch, id
            // collision, etc.) — this is the *only* place that surfaces it (there is no more
            // startup dialog), so it must carry every diagnostic detail we have. Unlike the info
            // line above, this genuinely should wrap rather than widen the card: pin it to row2's
            // width (see above) rather than the full viewport, or a long error message alone
            // would force the card — and horizontal scrolling — wider than it needs to be.
            // Store (upper-pane) cards never show this — see `show_failure`.
            if (show_failure) if (failedInfo(entry.id)) |f| {
                var fail_wrap = dvui.box(@src(), .{ .dir = .vertical }, .{
                    .min_size_content = .{ .w = row2_w },
                    .max_size_content = .{ .w = row2_w, .h = std.math.floatMax(f32) },
                });
                defer fail_wrap.deinit();

                var fail_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 2 } });
                defer fail_row.deinit();
                dvui.icon(
                    @src(),
                    "PluginFailedIcon",
                    icons.tvg.lucide.@"circle-alert",
                    .{ .stroke_color = theme.color(.err, .fill), .fill_color = theme.color(.err, .fill) },
                    .{ .gravity_y = 0, .margin = .{ .y = 3 }, .min_size_content = .{ .w = 14, .h = 14 } },
                );
                var fail_buf: [256]u8 = undefined;
                const fail_text = if (f.detail) |d|
                    std.fmt.bufPrint(&fail_buf, "Failed to load: {s} ({s})", .{ f.reason, d }) catch f.reason
                else
                    std.fmt.bufPrint(&fail_buf, "Failed to load: {s}", .{f.reason}) catch f.reason;
                var fail_tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false, .margin = .{ .x = 4 } });
                fail_tl.addText(fail_text, .{ .color_text = theme.color(.err, .text) });
                fail_tl.deinit();
            };
        }
    }

    // The info column's text layouts set an ibeam cursor on hover (for their own text
    // selection) regardless of whether the card claimed their clicks above — restore the
    // plain card cursor now that they've all had their turn this frame ("last cursorSet call
    // wins" for the frame).
    if (bw.hover) dvui.cursorSet(.arrow);
    if (bw.clicked()) toggleSelect(entry);
}

/// True when `entry` is genuinely present on disk in some form — loaded, disabled-on-disk,
/// sideloaded local, a failed/rejected build, or a protected bundled built-in. Mirrors the
/// "present on disk" condition `drawCardControls` uses to decide whether to show
/// enable/uninstall controls at all; `infoLine` reuses it so a plugin that was *never*
/// installed (or was uninstalled earlier this session, leaving only a stale `version_cache`
/// entry behind) never shows an "installed vX" it has no business showing.
fn isInstalled(entry: StoreEntry) bool {
    if (isBundled(entry.id)) return true;
    const editor = fizzy.editor;
    if (editor.host.pluginById(entry.id) != null) return true;
    if (editor.isPluginDisabled(entry.id)) return true;
    if (entry.kind == .local or entry.kind == .disabled) return true;
    if (entry.kind == .failed or editor.isFailedUserPlugin(entry.id)) return true;
    return false;
}

/// The host-installable release's publish date, or null when none is compatible with this
/// host (even if a `store v{latest}` is shown elsewhere on the card).
fn releaseDate(entry: StoreEntry) ?[]const u8 {
    const rel = selectedRelease(entry) orelse return null;
    return if (rel.published.len > 0) rel.published else null;
}

/// Compose the dim `id · store v{latest} · installed v{current}` line into `buf`, skipping
/// parts we don't have:
///   * `store v{latest}` — the highest version published in the registry, shown for *any*
///     plugin with a store presence, independent of whether it is installed or host-compatible.
///   * `installed v{current}` — the plugin's own current version, shown only when `entry` is
///     genuinely installed (see `isInstalled`) — never for a plugin the user hasn't installed.
fn infoLine(buf: []u8, entry: StoreEntry) []const u8 {
    var latest_buf: [40]u8 = undefined;
    const latest: ?[]const u8 = if (latestRegistryVersion(entry)) |lv|
        std.fmt.bufPrint(&latest_buf, "store v{s}", .{lv}) catch null
    else
        null;

    var installed_buf: [40]u8 = undefined;
    const installed: ?[]const u8 = if (isInstalled(entry))
        (if (currentVersion(entry.id)) |v|
            std.fmt.bufPrint(&installed_buf, "installed v{d}.{d}.{d}", .{ v.major, v.minor, v.patch }) catch null
        else
            null)
    else
        null;

    var parts: [3][]const u8 = undefined;
    var n: usize = 0;
    parts[n] = entry.id;
    n += 1;
    if (latest) |l| {
        parts[n] = l;
        n += 1;
    }
    if (installed) |i| {
        parts[n] = i;
        n += 1;
    }
    return joinParts(buf, parts[0..n]);
}

/// Compose the dim `id · store v{latest}` line for a store (upper-pane) card into `buf`. Unlike
/// `infoLine`, this never shows install state — the upper pane is a pure "what does the store
/// publish" list, even for a plugin the user happens to already have installed (see `drawCard`).
fn storeInfoLine(buf: []u8, entry: StoreEntry) []const u8 {
    var latest_buf: [40]u8 = undefined;
    const latest: ?[]const u8 = if (latestRegistryVersion(entry)) |lv|
        std.fmt.bufPrint(&latest_buf, "store v{s}", .{lv}) catch null
    else
        null;

    var parts: [2][]const u8 = undefined;
    var n: usize = 0;
    parts[n] = entry.id;
    n += 1;
    if (latest) |l| {
        parts[n] = l;
        n += 1;
    }
    return joinParts(buf, parts[0..n]);
}

const part_separator = " · ";

/// Join `parts` with " · ", truncating (rather than overflowing) if `buf` is too small.
fn joinParts(buf: []u8, parts: []const []const u8) []const u8 {
    var len: usize = 0;
    for (parts, 0..) |p, i| {
        if (i > 0) {
            if (len + part_separator.len > buf.len) break;
            @memcpy(buf[len..][0..part_separator.len], part_separator);
            len += part_separator.len;
        }
        const n = @min(p.len, buf.len - len);
        @memcpy(buf[len..][0..n], p[0..n]);
        len += n;
        if (n < p.len) break;
    }
    return buf[0..len];
}

/// The release that is compatible with this host, if `entry` has one in the fetched shard (the
/// shard is already resolved to this host's exact `abi_fingerprint` server-side — see
/// `store.Catalog` — so the only thing left to check here is whether it ships a binary for this
/// `os-arch`).
fn selectedRelease(entry: StoreEntry) ?store.ShardRelease {
    const r = entry.release orelse return null;
    if (r.downloadFor(compat.hostKey()) == null) return null;
    return r;
}

/// The compatible registry release when it is a *newer* version than the one currently loaded —
/// i.e. an update is available. Returns null when the plugin isn't loaded (we only know a live
/// plugin's version), has no host-compatible release, or is already up to date.
fn updateRelease(entry: StoreEntry) ?store.ShardRelease {
    const installed = installedVersion(entry.id) orelse return null;
    const rel = selectedRelease(entry) orelse return null;
    const rel_ver = std.SemanticVersion.parse(rel.version) catch return null;
    return if (rel_ver.order(installed) == .gt) rel else null;
}

/// Right-justified controls whose shape depends on install state (see plan Phase 1R-c):
///   * available in store → a single install button (down-to-line arrow);
///   * installed → an Enabled checkbox + a trash uninstall button;
///   * protected bundled fallback (workbench/text/markdown) → no controls;
///   * bundled built-in → not store-manageable (no uninstall).
fn drawCardControls(entry: StoreEntry) void {
    const editor = fizzy.editor;
    const theme = dvui.themeGet();
    const muted = theme.color(.window, .text).opacity(0.7);

    var ctl = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1.0, .gravity_y = 0.5 });
    defer ctl.deinit();

    // An in-flight / failed install job preempts the normal controls.
    if (jobs.get(entry.id)) |job| switch (@as(JobStatus, @enumFromInt(job.status.load(.acquire)))) {
        .downloading => {
            dvui.labelNoFmt(@src(), if (job.is_update) "Updating…" else "Installing…", .{}, .{ .gravity_y = 0.5, .color_text = muted, .font = dvui.Font.theme(.mono) });
            return;
        },
        .failed => {
            if (selectedRelease(entry)) |rel| {
                if (dvui.buttonIcon(@src(), "Retry", icons.tvg.lucide.@"rotate-ccw", .{}, .{ .stroke_color = theme.color(.err, .text) }, .{ .gravity_y = 0.5 }))
                    startDownload(entry.id, rel, job.is_update);
            }
            return;
        },
        .downloaded => {}, // about to complete in tick(); fall through to installed controls
    };

    // Protected universal fallbacks: never disablable / uninstallable.
    if (isBundled(entry.id)) {
        dvui.labelNoFmt(@src(), "Built-in", .{}, .{ .gravity_y = 0.5, .color_text = muted, .font = dvui.Font.theme(.mono) });
        return;
    }

    const loaded = editor.host.pluginById(entry.id) != null;
    const disabled = editor.isPluginDisabled(entry.id);
    // A build sitting in the plugins dir that failed to load (ABI/SDK mismatch, etc.). It is on
    // disk like any installed plugin, so it must stay actionable (replace / uninstall) rather than
    // dead-ending at a bare "Failed" label the user can't act on.
    const failed_on_disk = entry.kind == .failed or editor.isFailedUserPlugin(entry.id);

    // Present on disk in some form: loaded, disabled-on-disk, sideloaded local, or a failed build.
    if (loaded or disabled or entry.kind == .local or entry.kind == .disabled or failed_on_disk) {
        // Enable/disable only makes sense for a plugin that can actually load — a mismatched
        // (never-loaded) build has nothing to toggle, so skip the checkbox for the pure-failed case.
        if (loaded or disabled) {
            var enabled = !disabled;
            if (dvui.checkbox(@src(), &enabled, "Enabled", .{ .gravity_y = 0.5 })) queueSetEnabled(entry.id, enabled);
        }
        // Replace with a host-compatible registry build, just before uninstall:
        //   * loaded & strictly newer → in-place Update (unload + reload);
        //   * failed-on-disk          → replace the broken build. Nothing is loaded to unload, so
        //     route through the install path (is_update = false → installAndLoadPlugin loads the
        //     freshly downloaded file over the old one and clears the failure record).
        if (loaded) {
            if (updateRelease(entry)) |rel| {
                if (dvui.button(@src(), "Update", .{}, .{ .gravity_y = 0.5, .margin = .{ .x = 4 } }))
                    startDownload(entry.id, rel, true);
            }
        } else if (failed_on_disk) {
            if (selectedRelease(entry)) |rel| {
                if (dvui.button(@src(), "Update", .{}, .{ .gravity_y = 0.5, .margin = .{ .x = 4 } }))
                    startDownload(entry.id, rel, false);
            }
        }
        if (dvui.buttonIcon(@src(), "Uninstall", icons.tvg.lucide.@"trash-2", .{}, .{ .stroke_color = theme.color(.err, .text) }, .{ .gravity_y = 0.5 }))
            queueUninstall(entry.id);
        return;
    }

    // Available in the store but not installed.
    if (selectedRelease(entry)) |rel| {
        if (dvui.buttonIcon(@src(), "Install", icons.tvg.lucide.@"arrow-down-to-line", .{}, .{ .stroke_color = theme.color(.control, .text) }, .{ .gravity_y = 0.5 }))
            startDownload(entry.id, rel, false);
        return;
    }

    // Registry row with no host-compatible release and nothing on disk: the *store* hasn't
    // published a build for this exact Fizzy version/arch yet — nothing the user can fix
    // locally (unlike a failed local build, handled above), so the wording and the tooltip
    // both point at "the store doesn't have one" rather than "rebuild your plugin".
    {
        var no_build_box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_y = 0.5 });
        defer no_build_box.deinit();
        dvui.labelNoFmt(@src(), "No compatible build in store", .{}, .{
            .color_text = theme.color(.err, .text),
            .font = dvui.Font.theme(.mono),
        });
        dvui.tooltip(
            @src(),
            .{ .active_rect = no_build_box.data().borderRectScale().r },
            "No compatible build in store (SDK {d}.{d}.{d} · ABI 0x{x} · {s})",
            .{ version.sdk_version.major, version.sdk_version.minor, version.sdk_version.patch, dylib.abi_fingerprint, compat.hostKey() },
            .{},
        );
    }
}

/// Upper-pane (store) card controls: browse-only. Just an in-flight job status, an Install
/// button, or a "no compatible build" message — never enable/disable, update, or uninstall
/// (those are the installed pane's job, see `drawCardControls`), regardless of whether this
/// particular store plugin also happens to be installed.
fn drawStoreCardControls(entry: StoreEntry) void {
    const theme = dvui.themeGet();
    const muted = theme.color(.window, .text).opacity(0.7);

    var ctl = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1.0, .gravity_y = 0.5 });
    defer ctl.deinit();

    // An in-flight / failed install job preempts the normal controls.
    if (jobs.get(entry.id)) |job| switch (@as(JobStatus, @enumFromInt(job.status.load(.acquire)))) {
        .downloading => {
            dvui.labelNoFmt(@src(), if (job.is_update) "Updating…" else "Installing…", .{}, .{ .gravity_y = 0.5, .color_text = muted, .font = dvui.Font.theme(.mono) });
            return;
        },
        .failed => {
            if (selectedRelease(entry)) |rel| {
                if (dvui.buttonIcon(@src(), "Retry", icons.tvg.lucide.@"rotate-ccw", .{}, .{ .stroke_color = theme.color(.err, .text) }, .{ .gravity_y = 0.5 }))
                    startDownload(entry.id, rel, job.is_update);
            }
            return;
        },
        .downloaded => {}, // about to complete in tick(); fall through
    };

    if (selectedRelease(entry)) |rel| {
        if (dvui.buttonIcon(@src(), "Install", icons.tvg.lucide.@"arrow-down-to-line", .{}, .{ .stroke_color = theme.color(.control, .text) }, .{ .gravity_y = 0.5 }))
            startDownload(entry.id, rel, false);
        return;
    }

    // Registry row with no host-compatible release: the *store* hasn't published a build for
    // this exact Fizzy version/arch yet.
    {
        var no_build_box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_y = 0.5 });
        defer no_build_box.deinit();
        dvui.labelNoFmt(@src(), "No compatible build in store", .{}, .{
            .color_text = theme.color(.err, .text),
            .font = dvui.Font.theme(.mono),
        });
        dvui.tooltip(
            @src(),
            .{ .active_rect = no_build_box.data().borderRectScale().r },
            "No compatible build in store (SDK {d}.{d}.{d} · ABI 0x{x} · {s})",
            .{ version.sdk_version.major, version.sdk_version.minor, version.sdk_version.patch, dylib.abi_fingerprint, compat.hostKey() },
            .{},
        );
    }
}

/// A repo URL plus an optional path within it to look under for `README.md` / `ICON.png`.
const RepoSource = struct {
    repo: []const u8,
    subpath: []const u8 = "",
};

/// The fizzy monorepo — source of truth for the bundled built-ins (workbench, text, markdown), whose
/// `README.md` / `ICON.png` live at `src/plugins/<id>/` rather than at a repo root.
const fizzy_repo_url = "https://github.com/fizzyedit/fizzy";

/// Where to fetch `entry`'s README and store icon from, regardless of whether it's a store plugin or a
/// built-in: the registry homepage (repo root) for anything with a store presence, or the
/// fizzy monorepo subdirectory for a bundled built-in. Sideloaded/local plugins with no
/// registry entry have no known repo, so this is null and the store shows "no README found".
/// Built-in / sideloaded plugins gain a `repository` field with the Phase 4a manifest bump,
/// which can replace the bundled-only fallback below.
fn repoSource(entry: StoreEntry) ?RepoSource {
    if (entry.registry) |r| {
        if (r.homepage.len > 0) return .{ .repo = r.homepage };
    }
    if (isBundled(entry.id)) return .{ .repo = fizzy_repo_url, .subpath = builtinSubpath(entry.id) };
    return null;
}

fn readmeSource(entry: StoreEntry) ?RepoSource {
    return repoSource(entry);
}

/// `src/plugins/<id>` — only ever called for `isBundled` ids.
fn builtinSubpath(id: []const u8) []const u8 {
    if (std.mem.eql(u8, id, "workbench")) return "src/plugins/workbench";
    if (std.mem.eql(u8, id, "text")) return "src/plugins/text";
    if (std.mem.eql(u8, id, "markdown")) return "src/plugins/markdown";
    if (std.mem.eql(u8, id, "image")) return "src/plugins/image";
    unreachable;
}

fn drawHeader() !void {
    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .h = 6 } });
    defer hbox.deinit();

    var buf: [96]u8 = undefined;
    const host_sdk = std.fmt.bufPrint(&buf, "Fizzy SDK {d}.{d}.{d} · ABI 0x{x}", .{
        version.sdk_version.major,
        version.sdk_version.minor,
        version.sdk_version.patch,
        dylib.abi_fingerprint,
    }) catch "Fizzy SDK ?";
    dvui.labelNoFmt(@src(), host_sdk, .{}, .{ .gravity_y = 0.5 });

    if (dvui.buttonIcon(
        @src(),
        "Refresh",
        icons.tvg.lucide.@"rotate-ccw",
        .{},
        .{ .stroke_color = dvui.themeGet().color(.control, .text) },
        .{ .gravity_x = 1.0, .corners = .all(1000000) },
    )) {
        status_len = 0;
        if (catalog) |*c| c.refresh();
        probeDisabledInfo();
    }

    if (status_len > 0) {
        dvui.labelNoFmt(@src(), status_message[0..status_len], .{}, .{
            .gravity_x = 1.0,
            .color_text = dvui.themeGet().color(.err, .text),
        });
    }
}

fn removePendingForId(id: []const u8) void {
    var i: usize = 0;
    while (i < pending_actions.items.len) {
        const action = pending_actions.items[i];
        const matches = switch (action) {
            .set_enabled => |a| std.mem.eql(u8, a.id, id),
            .uninstall => |a| std.mem.eql(u8, a.id, id),
        };
        if (matches) {
            switch (action) {
                .set_enabled => |a| fizzy.app.allocator.free(a.id),
                .uninstall => |a| fizzy.app.allocator.free(a.id),
            }
            _ = pending_actions.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

fn queueSetEnabled(id: []const u8, enabled: bool) void {
    removePendingForId(id);
    const dup = fizzy.app.allocator.dupe(u8, id) catch {
        setStatus("'{s}' could not be queued", .{id});
        return;
    };
    pending_actions.append(fizzy.app.allocator, .{ .set_enabled = .{ .id = dup, .enabled = enabled } }) catch {
        fizzy.app.allocator.free(dup);
        setStatus("'{s}' could not be queued", .{id});
    };
}

fn queueUninstall(id: []const u8) void {
    removePendingForId(id);
    const dup = fizzy.app.allocator.dupe(u8, id) catch {
        setStatus("'{s}' could not be queued", .{id});
        return;
    };
    pending_actions.append(fizzy.app.allocator, .{ .uninstall = .{ .id = dup } }) catch {
        fizzy.app.allocator.free(dup);
        setStatus("'{s}' could not be queued", .{id});
    };
}

fn applySetEnabled(id: []const u8, enabled: bool) void {
    status_len = 0;
    fizzy.editor.setPluginEnabled(id, enabled, false) catch |err| switch (err) {
        error.DirtyDocuments => setStatus("'{s}' has unsaved changes — save or close them first", .{id}),
        else => setStatus("'{s}' could not be {s}: {s}", .{ id, if (enabled) "enabled" else "disabled", @errorName(err) }),
    };
}

fn applyUninstall(id: []const u8) void {
    status_len = 0;
    fizzy.editor.uninstallPlugin(id, false) catch |err| switch (err) {
        error.DirtyDocuments => setStatus("'{s}' has unsaved changes — save or close them first", .{id}),
        else => setStatus("'{s}' could not be uninstalled: {s}", .{ id, @errorName(err) }),
    };
}
