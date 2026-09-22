//! Fizzy built-in: the **Plugins** sidebar tab — discover / install / update / enable / disable
//! / uninstall plugins. Registered above Settings.
//!
//! Downloads run on a worker thread (`Job`); the actual live load happens on the main thread in
//! `tick` (it mutates the Host registries + dvui keybinds). The registry index is fetched +
//! parsed by the backend (`store.Catalog`); compatibility is matched on the host ABI
//! fingerprint + arch.
//!
//! The web build installs too. The catalog and READMEs load through the browser's `fetch`, and a
//! plugin published for `web-wasm32` is fetched and linked by the page rather than downloaded to
//! a directory (`queueInstall` → `installFromUrl`, `applyWebUpdate` → `updateFromUrl`); a plugin
//! with no web build is simply not offered there. Two things stay desktop-only: the SHA-256 the
//! registry publishes, which the page does not check, and the download queue below.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const sdk = @import("fizzy_sdk");
const icons = @import("icons");
const store = @import("registry/store.zig");
// The real loader, not `app.store.Loader`: what this file wants from it are the *manifest
// probe* helpers, which compile everywhere. Only the `LoadedLib` list — which carries a
// `DynLib` — has to come from the wasm stub, and that arrives through `PluginManager`.
const PluginLoader = @import("PluginLoader.zig");
const PluginManager = @import("PluginManager.zig");
/// Pretend two installed plugins have store updates waiting, so the update flow (the app's
/// offer, or the silent path's logging) can be exercised without an actually out-of-date
/// plugin. A build-time flag: flip it, run, flip it back.
const debug_simulate_updates: bool = false;
const core = @import("core");
const fuzzy = core.fuzzy;

const compat = store.compat;
const version = sdk.version;
const dylib = sdk.dylib;

const Readme = @import("readme.zig");
const StoreIcon = @import("store_icon.zig");
const web_fetch = if (builtin.target.cpu.arch == .wasm32)
    @import("web_fetch.zig")
else
    struct {
        pub fn deinit() void {}
    };

pub const view_id = "fizzy.store";
/// Center provider that renders the selected plugin's README. Mirrors the way the workbench
/// center renders the active document: while the store tab is active and a plugin is selected,
/// `tick` swaps the active center to this provider; deselecting (or leaving the tab) restores
/// the previous center.
pub const readme_center_id = "fizzy.store.readme";

/// Which sub-view the detail center shows below the header — VSCode marketplace-style. Reset to
/// `.details` whenever the selection changes (`toggleSelect`), so switching plugins never leaves
/// you stranded on a tab the new selection didn't ask for.
const DetailTab = enum { details, changelog };
var selected_detail_tab: DetailTab = .details;

var catalog: ?store.Catalog = null;
var registry_url_owned: ?[]u8 = null;
var first_draw_done = false;

const PaneTab = enum { store, installed };
var selected_pane_tab: PaneTab = .store;

var store_scroll_info: dvui.ScrollInfo = .{ .horizontal = .auto };
var installed_scroll_info: dvui.ScrollInfo = .{ .horizontal = .auto };
/// Detail-page header: scrolls sideways below `detail_header_min_w` instead of crushing the
/// info column (and wrapping the description into a skyscraper). Vertical is never owned here.
var detail_header_scroll: dvui.ScrollInfo = .{ .horizontal = .auto, .vertical = .none };
/// `hashId` of the entry whose header `detail_header_scroll` last showed — used to zero the
/// horizontal offset on page switches so a scrolled-over previous plugin doesn't leave you
/// looking at the middle of the next one's header.
var detail_header_scroll_entry: usize = 0;

/// Floor under the detail header row (logo + info + install controls). The header *expands*
/// with the pane above this; below it the scroll area takes over horizontally. Same role as
/// `card_min_w` on the list cards — a stable content min, not a viewport-locked width.
const detail_header_min_w: f32 = 480;

/// Applied as `max_size_content.w` on header text so labels/layouts don't report their full
/// unwrapped width as min size (which would inflate the header past `detail_header_min_w` and
/// make the horizontal scrollbar appear while the pane is still wider than the floor). Same
/// trick as `card_text_no_floor` — see that comment. The widgets still *draw* at the info
/// column's real (expanded) width via `.expand = .horizontal`.
const detail_header_text_no_floor: f32 = 1;

/// Action failures (a plugin that won't load, a queue/download that couldn't start) go to the
/// Output panel rather than into a header line in this pane: a long message there widened the
/// whole tab into a horizontal bar, and the Output panel is already where every other failure
/// in the app is reported.
fn reportError(comptime fmt: []const u8, args: anytype) void {
    std.log.err(fmt, args);
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
    /// Started by the automatic update pass rather than by a click, so a failure is logged and
    /// dropped instead of leaving a Retry card the user never asked for (see `tick`).
    quiet: bool = false,
    /// The window to wake when the download finishes. Captured on the UI thread at
    /// `startDownload` because the worker has no `currentWindow` of its own: without this a
    /// download that completes while the app sleeps sits at `.downloaded` until the next input
    /// event, which for the automatic pass is "until the user happens to touch fizzy again".
    win: *dvui.Window,
    err_buf: [64]u8 = undefined,
    err_len: usize = 0,
    /// This job's download worker, as a cancelable `Io` task group rather than a detached
    /// `std.Thread`. The worker writes `err_buf`/`err_len`/`status` back into the `Job`, so the
    /// `Job` must not be freed while it is alive — and a detached thread gave `freeJob` no way to
    /// know. Nothing in the download path sets a network timeout either, so a stalled or
    /// blackholed release host keeps that worker running arbitrarily long: quitting mid-download
    /// left a live thread writing into freed memory. `Group.cancel` both interrupts the blocked
    /// syscall (the worker returns `error.Canceled`) *and* awaits the task, so `freeJob` is
    /// provably the last toucher of the `Job`. One group per job rather than one shared group,
    /// because `await`/`cancel` are all-or-nothing over a group and jobs are freed individually.
    ///
    /// Same shape as `core/lsp/Client.zig`'s `tasks` and the store catalog's refresh worker. Not
    /// threadsafe against its own `await`/`cancel`, so every group operation stays on the UI
    /// thread (`draw` → `startDownload`, `tick`, `deinit`).
    tasks: std.Io.Group = .init,
};

var jobs: std.StringArrayHashMapUnmanaged(*Job) = .empty;

/// UI actions queued during `draw` and applied in `tick` so plugin unload never mutates
/// `host.plugins` (or dlcloses an image) while the store view is still iterating it.
const PendingAction = union(enum) {
    set_enabled: struct { id: []u8, enabled: bool },
    set_auto_update: struct { id: []u8, on: bool },
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

/// Disk-probed manifest fields per plugin id (app-allocator owned keys and values; an all-empty
/// entry means "probed, genuinely has nothing" so it isn't re-probed every frame either). Backs
/// the `PluginLoader.probeManifestInfo` fallback shared by `descriptionFor`/`tagsFor`/`authorFor`/
/// `authorUrlFor` — registry and built-in values are already cheap and never touch this. One
/// cache rather than one per field, because a single `dlopen` + parse yields all of them at once.
/// Cleared by `refreshDiskScan`.
var manifest_cache: std.StringArrayHashMapUnmanaged(PluginLoader.ProbedManifest) = .empty;

/// Every plugin id with a directory in `{config}/plugins/` (app-allocator owned), refreshed by
/// `refreshDiskScan`. The installed pane's in-memory sources (loaded plugins, disabled ids,
/// recorded load failures) each describe a *state* fizzy put a plugin into; this describes
/// what is actually on disk, which is the only thing that guarantees a broken plugin always has
/// a card to uninstall or reinstall from — even one that arrived in a state nothing recorded
/// (a half-finished install, a sideloaded directory, a build fizzy never tried to load).
var disk_ids: std.ArrayListUnmanaged([]u8) = .empty;
/// Set when the plugins directory may have changed (first draw, Refresh, and after any install /
/// uninstall / enable-disable applied in `tick`) so `draw` rescans once instead of listing the
/// directory on every frame the tab is open.
var disk_scan_dirty = true;

/// Ask `draw` to re-list the plugins directory (and re-probe names/versions) on its next pass.
/// Exposed for `Editor.reconcileDiscoveredPlugins`: the watcher discovering a dropped-in build is
/// exactly a "the plugins dir changed" event, and without this its card would draw from the stale
/// scan — bare id, or missing entirely until the user hit Refresh.
pub fn markDiskScanDirty() void {
    disk_scan_dirty = true;
}

pub const CatalogOffer = struct {
    id: []const u8,
    title: []const u8,
};

/// Catalog plugins that are not installed here and have a build this host can install.
/// Arena-backed; empty when the catalog has never loaded. `presentLocally` and the host key do
/// the filtering on both targets — in a browser "installed" means linked into this page, and a
/// plugin with no `web-wasm32` download is simply not offered.
pub fn uninstalledCatalog(arena: std.mem.Allocator) []const CatalogOffer {
    const c = &(catalog orelse return &.{});
    const snap = c.acquire();
    defer c.release();
    const s = snap orelse return &.{};
    var out: std.ArrayListUnmanaged(CatalogOffer) = .empty;
    for (s.summary.plugins) |p| {
        if (presentLocally(p.id)) continue;
        const rel = s.shard.releaseFor(p.id) orelse continue;
        if (rel.downloadFor(compat.hostKey()) == null) continue;
        if (!releaseSdkSatisfied(rel)) continue;
        out.append(arena, .{
            .id = p.id,
            .title = if (p.name.len > 0) p.name else p.id,
        }) catch return out.items;
    }
    return out.items;
}

/// Start a download+install for `id`. No-op when there is no compatible release, or on wasm.
pub fn queueInstall(id: []const u8) void {
    const c = &(catalog orelse return);
    const snap = c.acquire();
    defer c.release();
    const s = snap orelse return;
    const rel = s.shard.releaseFor(id) orelse return;
    const dl = rel.downloadFor(compat.hostKey()) orelse return;
    if (!releaseSdkSatisfied(rel)) return;
    if (comptime builtin.target.cpu.arch == .wasm32) {
        // No plugins directory in a browser: the page fetches and links the side module
        // straight from its release URL, and the app registers it when it lands.
        app.installFromUrl(id, dl.url) catch |err| {
            reportError("could not load '{s}': {s}", .{ id, @errorName(err) });
            return;
        };
        markWebInFlight(id);
        return;
    }
    startDownload(id, rel, .{ .is_update = false });
}

pub fn isInstalling(id: []const u8) bool {
    if (web_in_flight.contains(id)) return true;
    const job = jobs.get(id) orelse return false;
    const status: JobStatus = @enumFromInt(job.status.load(.acquire));
    return status == .downloading or status == .downloaded;
}

fn presentLocally(id: []const u8) bool {
    if (isBundled(id)) return true;
    if (app.host.pluginById(id) != null) return true;
    if (app.isDisabled(id)) return true;
    if (app.isFailed(id)) return true;
    if (isOnDisk(id)) return true;
    return false;
}

fn freeDiskIds() void {
    for (disk_ids.items) |id| app.gpa.free(id);
    disk_ids.clearRetainingCapacity();
}

fn clearManifestCache() void {
    for (manifest_cache.keys()) |k| app.gpa.free(k);
    for (manifest_cache.values()) |v| PluginLoader.freeProbedManifest(app.gpa, v);
    manifest_cache.clearRetainingCapacity();
}

/// Re-list `{config}/plugins/` into `disk_ids`. Best-effort: an unreadable directory (or one that
/// doesn't exist yet, before the first install) just leaves the list empty.
fn refreshDiskScan() void {
    disk_scan_dirty = false;
    freeDiskIds();
    clearManifestCache();
    if (comptime builtin.target.cpu.arch == .wasm32) return;

    const a = app.gpa;
    const plugins_dir = std.fs.path.join(a, &.{ app.config_folder, "plugins" }) catch return;
    defer a.free(plugins_dir);

    var dir = std.Io.Dir.cwd().openDir(dvui.io, plugins_dir, .{ .iterate = true }) catch return;
    defer dir.close(dvui.io);

    var iter = dir.iterate();
    while (iter.next(dvui.io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        // `.load-tmp` and friends are loader scratch, not plugin ids (see `PluginLoader`).
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (!std.unicode.utf8ValidateSlice(entry.name)) continue;
        const dup = a.dupe(u8, entry.name) catch continue;
        disk_ids.append(a, dup) catch a.free(dup);
    }
}

/// True if `id` has a directory in the plugins dir as of the last `refreshDiskScan`.
fn isOnDisk(id: []const u8) bool {
    for (disk_ids.items) |d| {
        if (std.mem.eql(u8, d, id)) return true;
    }
    return false;
}

/// Cache `id`'s version. Overwrites an existing entry so a reload/update always reflects the
/// latest known value.
fn rememberVersion(id: []const u8, v: std.SemanticVersion) void {
    const a = app.gpa;
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
    const a = app.gpa;
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

/// The best-known display name for `id` — the live plugin's `display_name` when loaded,
/// otherwise whatever `resolveTitle` remembers (a disabled/failed plugin seen earlier this
/// session), falling back to the bare id. Used by `PluginSettingsPane` to label a disabled
/// plugin's Enabled-toggle-only row without duplicating this cache's lookup logic.
pub fn displayName(id: []const u8) []const u8 {
    if (app.host.pluginById(id)) |p| return p.display_name;
    return resolveTitle(id, id);
}

/// Query the real display name + version of every on-disk plugin that isn't currently loaded,
/// straight from its dylib (embedded `plugin.zig.zon` via `fizzy_plugin_manifest_zon`, falling
/// back to the `fizzy_plugin_name`/version exports — no register, no on-disk sidecar), seeding
/// `name_cache` and `version_cache`. Covers plugins disabled before they were loaded this session
/// as well as builds that never loaded at all (wrong SDK, etc.) — a broken plugin still shows its
/// real name and version on its card. Cheap and bounded: only runs on first draw / Refresh, and
/// only probes ids whose name or version we don't already know.
fn probeOnDiskInfo() void {
    const a = app.gpa;
    const plugins_dir = std.fs.path.join(a, &.{ app.config_folder, "plugins" }) catch return;
    defer a.free(plugins_dir);

    for (disk_ids.items) |id| {
        if (app.host.pluginById(id) != null) continue; // loaded → info comes from the live plugin
        const have_name = name_cache.get(id) != null;
        const have_version = version_cache.get(id) != null;
        if (have_name and have_version) continue; // already known (registry / prior probe)
        const file_name = PluginLoader.pluginFilename(id, a) catch continue;
        defer a.free(file_name);
        const path = std.fs.path.join(a, &.{ plugins_dir, id, file_name }) catch continue;
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

/// Re-read local state: what's in the plugins directory, plus the name/version of anything there
/// we can't ask a live plugin about. Both halves are cheap and only run when the directory may
/// have changed (see `disk_scan_dirty`).
fn refreshLocalInfo() void {
    refreshDiskScan();
    if (comptime builtin.target.cpu.arch != .wasm32) probeOnDiskInfo();
}

/// The application hosting this store. Everything the store needs from its app goes through
/// here — see `PluginManager.zig`.
const app = &PluginManager.current;

pub fn register(manager: PluginManager) !void {
    PluginManager.current = manager;
    const host = manager.host;
    const url = resolveRegistryUrl();
    const fp_hex = try std.fmt.allocPrint(manager.gpa, "0x{x}", .{dylib.abi_fingerprint});
    defer manager.gpa.free(fp_hex);
    catalog = try store.Catalog.init(manager.gpa, dvui.io, url, fp_hex);
    try host.registerSurface(.{
        .id = view_id,
        .icon = .{ .tvg = dvui.entypo.shop },
        .title = "Plugins",
        .keywords = sdk.keywords.ide.sidebar,
        .draw = draw,
    });
    // The README takes the main area over while the store is the sidebar's tab
    // (`takeover_when`); `tick` hides it while no card is selected, which is the other half of
    // "only while there is something to show".
    try host.registerSurface(.{
        .id = readme_center_id,
        .title = "Plugin README",
        .keywords = sdk.keywords.ide.main,
        .takeover_when = view_id,
        .hidden = true,
        .draw = drawReadmeCenter,
    });
}

/// Center provider: a VSCode marketplace-style detail page for the selected plugin. Active only
/// while `tick` has swapped us in (store tab active + a plugin selected). The region is the
/// card; this is only the vertical stack (header/tabs/content).
fn drawReadmeCenter(_: ?*anyopaque) anyerror!dvui.App.Result {
    var pane = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = false,
        .id_extra = hashId(readme_center_id),
    });
    defer pane.deinit();

    const cat = if (catalog) |*c| c else return .ok;
    const snapshot = cat.acquire();
    defer cat.release();

    // Switching pages swaps the whole subtree (header, tabs, README), so hide the settle frame
    // and cross-fade rather than letting it flash. Keyed on the selection, so re-rendering the
    // same page every frame costs nothing.
    const rv = core.anim.reveal(pane.data().id, revealKey(), .{});
    defer rv.deinit();

    const entry = selectedEntry(snapshot) orelse {
        dvui.labelNoFmt(@src(), "Select a plugin to see its details.", .{}, .{
            .expand = .both,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .color_text = .{ .color = dvui.themeGet().color(.window, .text).opacity(0.7) },
        });
        return .ok;
    };

    drawDetailHeader(entry);
    drawDetailTabs();

    switch (selected_detail_tab) {
        .details => {
            var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .all(16) });
            defer body.deinit();
            Readme.draw();
        },
        .changelog => {
            // A plain wrapper, packed normally below the header/tabs like `.details`'s `body`
            // above — `drawChangelogPlaceholder`'s own box centers itself via `gravity_y = 0.5`,
            // which only a *normally-packed* parent can safely allow: `pane` is a vertical box
            // with the header and tabs as earlier siblings, so a gravity-in-(0,1) direct child of
            // *that* is treated as positioned/overlay (see `BoxWidget.rectFor`'s
            // `child_positioned` check) and placed relative to `pane`'s *full* content rect —
            // ignoring the space the header/tabs already consumed, i.e. drawn at the very top of
            // the pane, over everything above it. Routing through this intermediate box first
            // means the centering is relative to *its* (correctly, normally-packed) rect instead.
            var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
            defer body.deinit();
            drawChangelogPlaceholder();
        },
    }
    return .ok;
}

/// VSCode-marketplace-style header: logo, then a stacked name/id/author/description column, with
/// the same install/update/uninstall controls the card list uses (`drawCardControls`) pinned to
/// the top-right.
///
/// Width is left to dvui the same way list cards are: the row has a stable
/// `min_size_content = detail_header_min_w` and `.expand = .horizontal`, so it fills the pane
/// while there's room and only the scroll area engages once the viewport drops below that
/// floor. Text uses `detail_header_text_no_floor` so unwrapped label widths never inflate the
/// min and flash the scrollbar mid-resize. Title/id stay single-line (ellipsize); the
/// description still wraps within the (expanded) info column.
fn drawDetailHeader(entry: StoreEntry) void {
    const theme = dvui.themeGet();
    const muted = theme.color(.window, .text).opacity(0.7);

    // ScrollInfo defaults can be clobbered if a prior frame left vertical enabled; pin both.
    detail_header_scroll.horizontal = .auto;
    detail_header_scroll.vertical = .none;
    const entry_key = hashId(entry.id);
    if (detail_header_scroll_entry != entry_key) {
        detail_header_scroll_entry = entry_key;
        detail_header_scroll.viewport.x = 0;
    }

    var scroll = dvui.scrollArea(@src(), .{
        .scroll_info = &detail_header_scroll,
        // Overlay: the bar floats over the bottom padding instead of packing into the layout
        // and growing the header's height when it appears.
        .horizontal_bar = .auto_overlay,
        .vertical_bar = .hide,
    }, .{
        // Width follows the pane; height follows the header content.
        .expand = .horizontal,
        .background = false,
    });
    defer scroll.deinit();

    // Deliberately *not* keyed by `entry.id`, unlike the cards in the list: there is only ever
    // one detail header, and a per-entry id made it a brand-new widget on every page switch —
    // with no min size cached from the previous frame it laid out at zero height, which is the
    // one frame of headerless page users saw before it snapped. A stable id keeps the cache.
    //
    // Expand to fill the scroll viewport when wider than the floor; report a fixed min so the
    // scrollbar only appears once the pane is actually narrower than the content can go. Do
    // *not* lock min=max to the viewport — that made wrap width track the resize every frame and
    // flashed the scrollbar whenever a long token briefly exceeded the shrinking column.
    var header_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = detail_header_min_w },
        // Bottom padding matches top and leaves a strip for the overlay horizontal bar to sit
        // in without covering the description.
        .padding = .{ .x = 16, .y = 16, .w = 16, .h = 16 },
    });
    defer header_box.deinit();

    // 1. Logo — same fetch-or-fallback chain the card list uses.
    {
        var logo = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .gravity_y = 0.0,
            .min_size_content = .{ .w = 64, .h = 64 },
        });
        defer logo.deinit();
        if (repoSource(entry)) |src| StoreIcon.request(entry.id, src.repo, src.subpath);
        // 60 rather than the full 64 of `logo`'s box — just enough breathing room that the
        // image doesn't touch the header's own edges, per the "less empty space" ask.
        const drew = StoreIcon.draw(entry.id, 60) or app.host.drawPluginIcon(entry.id);
        if (!drew) {
            core.icon.icon(
                @src(),
                "PluginLogo",
                icons.tvg.lucide.package,
                .{ .stroke_color = .{ .color = theme.color(.window, .text) } },
                .{ .gravity_y = 0.0, .min_size_content = .{ .w = 64, .h = 64 } },
            );
        }
    }

    // 2. Toggles + install/update/uninstall controls. `drawDetailControls` right-justifies itself
    // (its own `gravity_x = 1.0` box) — laid out before the expanding info column for the same
    // reason `drawCard` does: an expand-horizontal sibling's reported min width is its full
    // unwrapped text, which would otherwise eat all the remaining space and starve these controls
    // to zero width (see `drawCard`'s comment on this exact ordering).
    drawDetailControls(entry);

    // 3. Stacked info: name (large), id (small mono), author, description. Expands into whatever
    // the row has left after logo + controls; text min-widths are capped so they can't push the
    // row's reported min past `detail_header_min_w`.
    {
        var info = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .margin = .{ .x = 12 },
        });
        defer info.deinit();

        const title_font = dvui.Font.theme(.body);
        // Single-line ellipsize (LabelWidget default) — wrapping the display-size title to one
        // word per line was the resize hitch that made the scrollbar appear mid-drag.
        dvui.labelNoFmt(@src(), entry.title, .{}, .{
            .font = title_font.withSize(title_font.size * 3 - 1).withWeight(.bold),
            .expand = .horizontal,
            .max_size_content = .{ .w = detail_header_text_no_floor, .h = std.math.floatMax(f32) },
            .margin = dvui.Rect.all(0),
            .padding = .{ .h = 2 },
        });
        dvui.labelNoFmt(@src(), entry.id, .{}, .{
            .font = dvui.Font.theme(.mono),
            .color_text = .{ .color = muted },
            .expand = .horizontal,
            .max_size_content = .{ .w = detail_header_text_no_floor, .h = std.math.floatMax(f32) },
            .margin = dvui.Rect.all(0),
            .padding = .{ .h = 4 },
        });
        drawAuthorLine(entry, muted);
        if (descriptionFor(entry)) |desc| {
            var tl = dvui.textLayout(@src(), .{ .break_lines = true }, .{
                .background = false,
                .expand = .horizontal,
                // Cap reported min width; wrap still uses the real expanded column width.
                .max_size_content = .{ .w = detail_header_text_no_floor, .h = std.math.floatMax(f32) },
                .margin = dvui.Rect.all(0),
                // `TextLayoutWidget`'s own default padding is `Rect.all(6)` — unlike the labels
                // above, which each override `.padding` down to just a bottom gap (`.{ .h = N }`,
                // leaving left at 0). Left unset here, that default 6px left inset was the only
                // thing pushing this line out of alignment with the other three.
                .padding = dvui.Rect.all(0),
                .font = dvui.Font.theme(.body),
            });
            tl.addText(desc, .{ .color_text = .{ .color = theme.color(.window, .text).opacity(0.9) } });
            tl.deinit();
        }
    }
}

/// Only ever hand a `http`/`https` URL to `dvui.openURL`. `author_url` is author-controlled text
/// out of a `plugin.zig.zon`, and `openURL` ultimately reaches the OS URL handler — a `file:`,
/// `smb:`, or custom-scheme URL there would let a plugin manifest launch an arbitrary registered
/// handler on the user's machine just by being listed in the store.
fn isSafeExternalUrl(url: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(url, "https://") or std.ascii.startsWithIgnoreCase(url, "http://");
}

/// The credit line under the plugin id: `publisher · author`.
///
/// Two different kinds of claim, deliberately shown together rather than collapsed into one
/// "author" string. `publisher` is derived from where the binary is actually published and is the
/// half a user can rely on; `author` is a free string the plugin says about itself. Either may be
/// absent — a sideloaded plugin has no publisher, and a plugin that never sets `.author` has no
/// credit — in which case only the other is drawn, and the row is skipped entirely if neither
/// exists. Each is a link only when there is somewhere meaningful to go.
fn drawAuthorLine(entry: StoreEntry, muted: dvui.Color) void {
    const publisher = publisherFor(entry);
    const author = authorFor(entry);
    if (publisher == null and author == null) return;

    // Expand the row (not the individual links) so credit names stay packed on the left —
    // `expand = .horizontal` on both publisher and author made them split the row and look
    // centered. Cap the row's reported min so long names can't inflate the header floor.
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .max_size_content = .{ .w = detail_header_text_no_floor, .h = std.math.floatMax(f32) },
        .margin = dvui.Rect.all(0),
        .padding = .{ .h = 6 },
    });
    defer row.deinit();

    if (publisher) |p| {
        // Publisher links to the account itself, built from the publisher name rather than from
        // any URL the plugin supplied — the whole point of this half is that it isn't
        // author-controlled.
        const url = std.fmt.allocPrint(dvui.currentWindow().arena(), "https://github.com/{s}", .{p}) catch "";
        drawCreditLink(@src(), p, if (url.len > 0) url else null, muted);
    }

    if (publisher != null and author != null) {
        dvui.labelNoFmt(@src(), " · ", .{}, .{
            .font = dvui.Font.theme(.body),
            .color_text = .{ .color = muted.opacity(0.6) },
            .gravity_y = 0.5,
            .margin = dvui.Rect.all(0),
            .padding = dvui.Rect.all(0),
        });
    }

    if (author) |a| {
        const url = authorUrlFor(entry);
        const safe = if (url) |u| (if (isSafeExternalUrl(u)) u else null) else null;
        drawCreditLink(@src(), a, safe, muted);
    }
}

/// One name in the credit line — a plain dim label, or an underlined highlight-colored link when
/// `url` is non-null. Styling matches the text plugin's hover-doc links (`TextEditor.zig`):
/// `Font.withUnderline` + `color(.highlight, .fill)`, so every clickable bit of prose in the app
/// reads the same way. A name with nowhere to go stays deliberately unstyled — underlining
/// something unclickable is worse than leaving it plain.
fn drawCreditLink(src: std.builtin.SourceLocation, text: []const u8, url: ?[]const u8, muted: dvui.Color) void {
    const body = dvui.Font.theme(.body);
    const target = url orelse {
        dvui.labelNoFmt(src, text, .{}, .{
            .font = body,
            .color_text = .{ .color = muted },
            .gravity_y = 0.5,
            .margin = dvui.Rect.all(0),
            .padding = dvui.Rect.all(0),
        });
        return;
    };

    if (dvui.labelClick(src, "{s}", .{text}, .{}, .{
        .font = body.withUnderline(.{}),
        .color_text = .{ .color = dvui.themeGet().color(.highlight, .fill) },
        .gravity_y = 0.5,
        .margin = dvui.Rect.all(0),
        .padding = dvui.Rect.all(0),
    })) {
        _ = dvui.openURL(.{ .url = target });
    }
}

/// Simple two-tab strip: no fill of its own (reads as part of the pane behind it, not a
/// separate bar), regular body text, and the selected tab marked by a `window`-text-colored
/// underline rather than a filled pill. No drag/drop and no scroll area — there are only ever
/// two tabs here.
fn drawDetailTabs() void {
    var strip = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 12, .y = 6, .h = 12 },
    });
    defer strip.deinit();

    if (tabButton(@src(), "DETAILS", 0, selected_detail_tab == .details)) selected_detail_tab = .details;
    if (tabButton(@src(), "CHANGELOG", 1, selected_detail_tab == .changelog)) selected_detail_tab = .changelog;
}

fn tabButton(src: std.builtin.SourceLocation, label: []const u8, id_extra: usize, selected: bool) bool {
    const theme = dvui.themeGet();

    // Sized to the label's own width (no expand), so the underline drawn below — which does
    // expand horizontally, but only within this column — lines up under the text exactly rather
    // than spanning the whole strip.
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = id_extra, .margin = .{ .x = 2 } });
    defer col.deinit();

    const tab_font = dvui.Font.theme(.body);
    const clicked = dvui.button(src, label, .{}, .{
        .id_extra = id_extra,
        .background = false,
        .border = dvui.Rect.all(0),
        .margin = dvui.Rect.all(2),
        .padding = .{ .x = 4, .y = 6, .w = 4, .h = 4 },
        .color_text = .{ .color = if (selected) theme.color(.window, .text) else theme.color(.control, .text) },
        .font = tab_font.withSize(tab_font.size),
    });
    var underline = dvui.box(@src(), .{}, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .min_size_content = .{ .h = 2 },
        .background = true,
        .color_fill = .{ .color = if (selected) theme.color(.window, .text) else .transparent },
    });
    underline.deinit();

    return clicked;
}

/// CHANGELOG's content until real GitHub Releases fetching lands (tracked separately) — an
/// empty-state hint rather than a blank pane, matching how the workbench's own empty states read.
fn drawChangelogPlaceholder() void {
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .gravity_x = 0.5,
        .gravity_y = 0.5,
    });
    defer box.deinit();

    const muted = dvui.themeGet().color(.window, .text).opacity(0.7);
    core.icon.icon(@src(), "ChangelogPlaceholder", icons.tvg.lucide.history, .{ .stroke_color = .{ .color = muted } }, .{
        .gravity_x = 0.5,
        .min_size_content = .{ .w = 32, .h = 32 },
        .margin = .{ .h = 8 },
    });
    dvui.labelNoFmt(@src(), "Changelog coming soon", .{}, .{
        .font = dvui.Font.theme(.title),
        .color_text = .{ .color = muted },
        .gravity_x = 0.5,
    });
    var tl = dvui.textLayout(@src(), .{ .break_lines = true }, .{
        .background = false,
        .gravity_x = 0.5,
        .max_size_content = .{ .w = 320, .h = std.math.floatMax(f32) },
        .margin = .{ .y = 6 },
        .font = dvui.Font.theme(.body),
    });
    tl.addText("Release notes for this plugin will appear here in a future update.", .{ .color_text = .{ .color = muted } });
    tl.deinit();
}

/// `FIZZY_PLUGIN_REGISTRY_URL` overrides the app's catalog *base* URL (used for local E2E
/// testing) — `store.Catalog.init` appends `/summary.json` and `/<abi_fingerprint>/releases.json`
/// to whatever this returns. Owned for the process lifetime (freed in `deinit`).
fn resolveRegistryUrl() []const u8 {
    if (comptime builtin.target.cpu.arch == .wasm32) return app.registry_url;
    if (std.process.Environ.getAlloc(core.platform.processEnviron(), app.gpa, "FIZZY_PLUGIN_REGISTRY_URL")) |override| {
        if (override.len > 0) {
            registry_url_owned = override;
            return override;
        }
        app.gpa.free(override);
    } else |_| {}
    return app.registry_url;
}

pub fn deinit() void {
    if (comptime builtin.target.cpu.arch == .wasm32) {
        Readme.deinit();
        StoreIcon.deinit();
        if (catalog) |*c| c.deinit();
        catalog = null;
        for (web_in_flight.keys()) |k| app.gpa.free(k);
        web_in_flight.deinit(app.gpa);
        for (pending_actions.items) |action| switch (action) {
            .set_enabled => |a| app.gpa.free(a.id),
            .set_auto_update => |a| app.gpa.free(a.id),
            .uninstall => |a| app.gpa.free(a.id),
        };
        pending_actions.deinit(app.gpa);
        clearPendingUpdates();
        pending_updates.deinit(app.gpa);
        web_fetch.deinit();
        return;
    }
    // `freeJob` cancels and awaits each job's download worker before freeing it, so quitting
    // mid-install can't leave a worker writing into a freed `Job` (see `Job.tasks`).
    for (jobs.values()) |job| freeJob(job);
    jobs.deinit(app.gpa);
    for (pending_actions.items) |action| switch (action) {
        .set_enabled => |a| app.gpa.free(a.id),
        .set_auto_update => |a| app.gpa.free(a.id),
        .uninstall => |a| app.gpa.free(a.id),
    };
    pending_actions.deinit(app.gpa);
    for (name_cache.keys()) |k| app.gpa.free(k);
    for (name_cache.values()) |v| app.gpa.free(v);
    name_cache.deinit(app.gpa);
    for (version_cache.keys()) |k| app.gpa.free(k);
    version_cache.deinit(app.gpa);

    clearPendingUpdates();
    pending_updates.deinit(app.gpa);
    clearManifestCache();
    manifest_cache.deinit(app.gpa);
    freeDiskIds();
    disk_ids.deinit(app.gpa);
    Readme.deinit();
    StoreIcon.deinit();
    if (catalog) |*c| c.deinit();
    catalog = null;
    if (registry_url_owned) |u| {
        app.gpa.free(u);
        registry_url_owned = null;
    }
}

/// Frees a job and everything it owns. Cancels and awaits its download worker first — see
/// `Job.tasks` — so nothing can be writing into the `Job` as it goes away. No-op for a job whose
/// worker never started or has already finished.
fn freeJob(job: *Job) void {
    job.tasks.cancel(dvui.io);
    app.gpa.free(job.id);
    app.gpa.free(job.url);
    app.gpa.free(job.sha256);
    app.gpa.free(job.dest);
    app.gpa.destroy(job);
}

// ---- automatic updates -----------------------------------------------------

/// One installed plugin the store has a better build for, as offered in the "Plugin updates"
/// window. Every string is app-allocator-owned: the registry strings these are built from are
/// only valid while the catalog lock is held, and this list outlives that by many frames.
pub const PendingUpdate = struct {
    id: []u8,
    /// Display name, or the id when nothing better is known yet.
    title: []u8,
    /// The store build's version.
    to: []u8,
    /// This host's download for that build, copied out of the registry at collect time.
    ///
    /// Owned here rather than re-resolved from the catalog on click, for two reasons: registry
    /// strings are only valid while the catalog lock is held (the refresh worker frees the arena),
    /// and the update window draws its cards *inside* that lock — so a click that reached back for
    /// the catalog would re-enter a non-reentrant mutex on the UI thread and hang the app.
    url: []u8,
    sha256: []u8,
    /// The installed version, when we know it. Null for a build that never loaded and could not
    /// be probed.
    from: ?std.SemanticVersion,
    /// The plugin isn't running: its installed build was rejected (an SDK/ABI mismatch after a
    /// fizzy upgrade, most often) and the store build for *this* host replaces it. Presented as a
    /// repair rather than an upgrade, since the version number often doesn't move.
    repair: bool,
    /// An Update was clicked (or Update all) — the row shows progress instead of a button.
    started: bool = false,
    /// The last attempt failed (the download, not the load — see `tick`). The row stays on the
    /// offer with its button back, labelled Retry.
    failed: bool = false,
};

var pending_updates: std.ArrayListUnmanaged(PendingUpdate) = .empty;

/// Where the once-per-session update check has got to.
const AutoPhase = enum {
    /// Nothing kicked off yet.
    idle,
    /// A catalog refresh is in flight purely for the update check.
    fetching,
    /// The check ran (or was skipped, or the fetch failed). One attempt per session — the store
    /// tab's own Refresh button is the manual retry.
    done,
};
var auto_phase: AutoPhase = .idle;

pub fn pendingUpdates() []PendingUpdate {
    return pending_updates.items;
}

fn clearPendingUpdates() void {
    const a = app.gpa;
    for (pending_updates.items) |u| {
        a.free(u.id);
        a.free(u.title);
        a.free(u.to);
        a.free(u.url);
        a.free(u.sha256);
    }
    pending_updates.clearRetainingCapacity();
}

/// Called when the update window closes: the list is UI state for that window only, and the
/// downloads it started (if any) run to completion on their own.
pub fn dismissPendingUpdates() void {
    clearPendingUpdates();
}

/// Take `id` off the offer — its newer build is now on disk, so there is nothing left to offer.
/// The window shows exactly the plugins that are still out of date, and closes itself once the
/// last row goes (see `PluginUpdates.dialog`).
fn dropPendingUpdate(id: []const u8) void {
    const a = app.gpa;
    for (pending_updates.items, 0..) |u, i| {
        if (!std.mem.eql(u8, u.id, id)) continue;
        // Ordered, so the rows the user is still looking at don't reshuffle underneath them as
        // earlier ones complete.
        const row = pending_updates.orderedRemove(i);
        a.free(row.id);
        a.free(row.title);
        a.free(row.to);
        a.free(row.url);
        a.free(row.sha256);
        return;
    }
}

/// Hand `id`'s row its button back after a failed attempt, so the offer can be retried by hand
/// rather than sitting on a permanent "Updating…".
fn markPendingUpdateFailed(id: []const u8) void {
    const row = pendingRowFor(id) orelse return;
    row.started = false;
    row.failed = true;
}

/// Start the download for one offered update. Safe to call for a row already started (the job is
/// simply replaced) and from inside the card list's own draw, since it touches no catalog state.
/// Ids whose web load or update is in flight — the page is fetching and linking, and the host
/// has not yet accepted or refused the module. `app.gpa`-owned; one entry per id.
var web_in_flight: std.StringArrayHashMapUnmanaged(void) = .empty;

fn markWebInFlight(id: []const u8) void {
    const gop = web_in_flight.getOrPut(app.gpa, id) catch return;
    if (!gop.found_existing) {
        gop.key_ptr.* = app.gpa.dupe(u8, id) catch {
            _ = web_in_flight.swapRemove(id);
            return;
        };
    }
}

fn clearWebInFlight(id: []const u8) void {
    if (web_in_flight.fetchSwapRemove(id)) |kv| app.gpa.free(kv.key);
}

/// The load or update for `id` registered. Called from the arrival path, which is the first
/// moment anything here may treat the new build as the one that is running.
pub fn webLoadSucceeded(id: []const u8) void {
    clearWebInFlight(id);
    dropPendingUpdate(id);
    dvui.refresh(null, @src(), null);
}

/// It did not: the fetch failed, the module was refused, or the plugin it would have replaced
/// has unsaved documents. The offer stays, wearing Retry — the running plugin was never torn
/// down, so there is something to go back to.
pub fn webLoadFailed(id: []const u8) void {
    clearWebInFlight(id);
    if (pendingRowFor(id)) |row| {
        row.started = false;
        row.failed = true;
    }
    dvui.refresh(null, @src(), null);
}

/// The web's update: the new build is fetched and checked while the running one keeps working,
/// and only takes the id over once it has passed (`Editor.updateWebPlugin`). The old module
/// stays linked in the page — nothing can unlink it — but it owns nothing after the swap.
fn applyWebUpdate(id: []const u8, url: []const u8) void {
    app.updateFromUrl(id, url) catch |err| {
        reportError("could not update '{s}': {s}", .{ id, @errorName(err) });
        if (pendingRowFor(id)) |row| row.failed = true;
        return;
    };
    // Not dropped here: the fetch has only *started*. `webLoadSucceeded` retires the row.
    markWebInFlight(id);
    if (pendingRowFor(id)) |row| {
        row.started = true;
        row.failed = false;
    }
    dvui.refresh(null, @src(), null);
}

pub fn applyPendingUpdate(id: []const u8) void {
    const row = pendingRowFor(id) orelse return;
    if (comptime builtin.target.cpu.arch == .wasm32) {
        applyWebUpdate(row.id, row.url);
        return;
    }
    // Whether this is an unload-and-reload or a fresh install is decided by what is *running*
    // now, not by what the row said when it was built — the plugin may have been enabled or
    // disabled while the window sat open.
    startDownloadUrl(row.id, row.url, row.sha256, .{
        .is_update = app.host.pluginById(id) != null,
        .quiet = true,
    });
    row.started = true;
    row.failed = false;
}

/// One-line progress for `id` as the update window shows it, or null while the row still has an
/// Update button to press. Reads live job state, so a download started from the store tab shows
/// here too.
pub fn updateStatus(id: []const u8) ?[]const u8 {
    if (web_in_flight.contains(id)) return "Updating\u{2026}";
    if (jobs.get(id)) |job| return switch (@as(JobStatus, @enumFromInt(job.status.load(.acquire)))) {
        .downloading => "Updating\u{2026}",
        .downloaded => "Installing\u{2026}",
        .failed => "Failed",
    };
    // A row that finished is gone from the list entirely (`dropPendingUpdate`), so anything still
    // here with no job either hasn't started or failed — both want their button back.
    return null;
}

pub fn applyAllPendingUpdates() void {
    // Index rather than pointer iteration: `applyPendingUpdate` writes back into the list.
    var i: usize = 0;
    while (i < pending_updates.items.len) : (i += 1) {
        const id = pending_updates.items[i].id;
        if (!pending_updates.items[i].started) applyPendingUpdate(id);
    }
}

/// The pending-update row for `id`, if it is one.
fn pendingRowFor(id: []const u8) ?*PendingUpdate {
    for (pending_updates.items) |*u| {
        if (std.mem.eql(u8, u.id, id)) return u;
    }
    return null;
}

/// The update window's per-card control: one small Update button, or the job's progress.
fn drawUpdateCardControls(entry: StoreEntry) void {
    const theme = dvui.themeGet();
    const body = dvui.Font.theme(.body);

    var ctl = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1.0, .gravity_y = 0.5 });
    defer ctl.deinit();

    if (updateStatus(entry.id)) |status| {
        dvui.labelNoFmt(@src(), status, .{}, .{
            .gravity_y = 0.5,
            .color_text = .{ .color = theme.color(.window, .text).opacity(0.7) },
            .font = dvui.Font.theme(.mono).larger(-1.0),
        });
        return;
    }
    const failed = if (pendingRowFor(entry.id)) |row| row.failed else false;
    if (dvui.button(@src(), if (failed) "Retry" else "Update", .{}, .{ .gravity_y = 0.5, .font = body.larger(-1.0) }))
        applyPendingUpdate(entry.id);
}

/// "v0.3.9 → v0.4.1", or what a repair actually is — the update window's equivalent of a store
/// card's `installed vX / store vY` line, in the same slot.
fn updateInfoLine(buf: []u8, row: PendingUpdate) []const u8 {
    if (row.repair) {
        return std.fmt.bufPrint(buf, "rebuild for this version of Fizzy — v{s}", .{row.to}) catch row.to;
    }
    const from = row.from orelse return std.fmt.bufPrint(buf, "v{s}", .{row.to}) catch row.to;
    return std.fmt.bufPrint(buf, "v{d}.{d}.{d} → v{s}", .{ from.major, from.minor, from.patch, row.to }) catch row.to;
}

/// The offered updates as store cards — the same shell the Plugins tab draws, so the two never
/// drift apart. Cards here are inert apart from their Update button: clicking one must not swap
/// the README center out from under a modal dialog, and the hover toggles belong to the store.
pub fn drawPendingUpdateCards() void {
    const c = if (catalog) |*ci| ci else null;
    const snapshot = if (c) |cc| cc.acquire() else null;
    defer if (c) |cc| cc.release();

    for (pending_updates.items) |row| {
        const entry = entryFor(row.id, snapshot) orelse StoreEntry{
            .id = row.id,
            .title = row.title,
            .kind = .registry,
            .registry = if (snapshot) |snap| snap.summary.pluginById(row.id) else null,
            .release = if (snapshot) |snap| snap.shard.releaseFor(row.id) else null,
        };
        var buf: [96]u8 = undefined;
        drawCardShell(entry, drawUpdateCardControls, updateInfoLine(&buf, row), .{ .clickable = false, .compact = true });
    }
}

/// True while any offered update still has an Update button to press — the window's "Update all"
/// hides itself once there is nothing left to start.
pub fn anyPendingUpdateUnstarted() bool {
    for (pending_updates.items) |u| {
        if (!u.started) return true;
    }
    return false;
}

/// Drives the once-per-session update check from `tick`: kick one catalog refresh, then act on
/// it when it lands. Deliberately *not* run before `Editor.loadUserPlugins` — that is a
/// synchronous startup path and the fetch has no timeout, so gating startup on it would hang
/// launch behind a captive portal or a dead registry host. Everything loads first; a plugin whose
/// build this fizzy can't load is then repaired live, no restart needed.
fn autoUpdateTick() void {
    switch (auto_phase) {
        .idle => {
            const c = if (catalog) |*ci| ci else return;
            if (debug_simulate_updates) {
                clearPendingUpdates();
                // A URL that resolves to nothing: clicking Update exercises the whole job path
                // and lands on a normal download failure, which is the point of a simulation.
                const fake_dl: store.registry.Download = .{ .url = "https://127.0.0.1:9/simulated", .sha256 = "" };
                appendPendingUpdate("pixi", "Pixi", "0.4.1", fake_dl, .{ .major = 0, .minor = 3, .patch = 9 }, false);
                appendPendingUpdate("ghostty", "Terminal", "1.2.0", fake_dl, .{ .major = 1, .minor = 2, .patch = 0 }, true);
                dvui.log.info("plugin updates: simulated {d} rows, mode {s}", .{ pending_updates.items.len, @tagName(app.updateMode()) });
                offerPendingUpdates();
                auto_phase = .done;
                return;
            }
            // Plugins go *after* Fizzy itself. Store builds are made against one SDK
            // generation, so the plugin builds that match the Fizzy release we're about to
            // install only become visible to us once we are running it — see
            // `PluginManager.AppUpdate`.
            switch (app.appUpdate()) {
                // The launch check is still out. Wait: it costs a few frames of a pass nobody
                // is watching, and answers whether these are even the right plugin builds.
                .checking => return,
                // A newer Fizzy exists. Say nothing about plugins yet, in either mode: the
                // builds that pair with that Fizzy are in a shard we can't see from here, so
                // anything we could offer now is the *older* build — or, without
                // `releaseSdkSatisfied`, one that wouldn't load at all. The user takes the app
                // update when they choose; this pass runs again on the relaunch, against the
                // new SDK's shard, and only then is there a plugin story worth telling.
                .pending => return,
                .none => {},
            }

            // Nothing installed to update: don't touch the network at all.
            if (disk_scan_dirty) refreshDiskScan();
            if (!anyUpdatableInstalled()) {
                auto_phase = .done;
                return;
            }
            c.refresh();
            auto_phase = .fetching;
        },
        .fetching => {
            const c = if (catalog) |*ci| ci else return;
            switch (c.status()) {
                .idle, .fetching => {},
                // Offline, or a registry that isn't answering. Silence is the right response to
                // a check the user never asked for; the store tab still says what it knows.
                .failed => auto_phase = .done,
                .ready => {
                    collectPendingUpdates();
                    offerPendingUpdates();
                    auto_phase = .done;
                },
            }
        },
        .done => {},
    }
}

/// True if any plugin on disk is a candidate for the update check at all — installed, not
/// bundled, not disabled, and not opted out.
fn anyUpdatableInstalled() bool {
    for (disk_ids.items) |id| {
        if (isBundled(id)) continue;
        if (app.isDisabled(id)) continue;
        if (!app.isAutoUpdate(id)) continue;
        return true;
    }
    return false;
}

/// Build `pending_updates` from the fetched catalog: every enabled, opted-in plugin the store has
/// a better build of for *this* host.
fn collectPendingUpdates() void {
    clearPendingUpdates();
    if (disk_scan_dirty) refreshDiskScan();

    const c = if (catalog) |*ci| ci else return;
    const snapshot = c.acquire();
    defer c.release();
    const snap = snapshot orelse return;

    for (disk_ids.items) |id| {
        if (isBundled(id)) continue;
        if (app.isDisabled(id)) continue; // "off" is a decision, not something to fix
        if (!app.isAutoUpdate(id)) continue;
        if (jobs.get(id) != null) continue; // already installing/updating from the store tab

        const rel = snap.shard.releaseFor(id) orelse continue;
        // The shard is this host's ABI fingerprint, but that alone doesn't make a release
        // loadable: it still needs a build for this OS/arch...
        const dl = rel.downloadFor(compat.hostKey()) orelse continue;
        // ...and be loadable by this SDK version. Offering an update this Fizzy would reject at
        // `dlopen` is worse than offering nothing: it replaces a working plugin with one that
        // cannot load. The user updates Fizzy first; the plugin update follows on the next run.
        if (!releaseSdkSatisfied(rel)) continue;
        const rel_ver = std.SemanticVersion.parse(rel.version) catch continue;

        const installed = currentVersion(id);
        const repair = app.host.pluginById(id) == null;
        if (repair) {
            // Enabled on record but not running: the build on disk was rejected. The store build
            // is the way back in even at the same version number (different fingerprint), but
            // never *older* than what is already there — that would downgrade an author's own
            // newer local build the moment it failed to load once.
            if (installed) |known| {
                if (rel_ver.order(known) == .lt) continue;
            }
        } else {
            // Running: only a strictly newer version is an update.
            const running = installed orelse continue;
            if (rel_ver.order(running) != .gt) continue;
        }

        appendPendingUpdate(id, resolveTitle(id, id), rel.version, dl, installed, repair);
    }
}

/// Own copies of one row's strings and append it. Any allocation failure unwinds the ones already
/// taken and drops the row — a plugin missing from the window is a far better outcome than a leak
/// or a half-built entry.
fn appendPendingUpdate(
    id: []const u8,
    title: []const u8,
    to: []const u8,
    dl: store.registry.Download,
    from: ?std.SemanticVersion,
    repair: bool,
) void {
    const a = app.gpa;
    var owned: [4][]u8 = undefined;
    var taken: usize = 0;
    // One unwind path for all four strings: a partial row must free exactly what it took.
    defer if (taken < owned.len) {
        for (owned[0..taken]) |o| a.free(o);
    };
    for ([_][]const u8{ id, title, to, dl.url }, 0..) |src, i| {
        owned[i] = a.dupe(u8, src) catch return;
        taken = i + 1;
    }
    const sha_dup = a.dupe(u8, dl.sha256) catch return;
    errdefer a.free(sha_dup);

    pending_updates.append(a, .{
        .id = owned[0],
        .title = owned[1],
        .to = owned[2],
        .url = owned[3],
        .sha256 = sha_dup,
        .from = from,
        .repair = repair,
    }) catch {
        a.free(sha_dup);
        return;
    };
    taken = owned.len + 1; // handed off: the list owns them now
}

/// Apply whatever `collectPendingUpdates` found, the way the user asked for in settings:
/// silently, or through the "Plugin updates" window.
///
/// Repairs (`PendingUpdate.repair`) are the exception to `.prompt`: the plugin is enabled but not
/// running, which after a Fizzy update is the normal state of every plugin built against the old
/// SDK. Prompting there offers the user a choice they don't have — declining leaves the plugin
/// dead rather than merely older — so repairs always go through silently, and the common case
/// (Fizzy updates, its plugins follow on the next launch) is seamless in both modes. Only genuine
/// version upgrades of *working* plugins are worth asking about.
fn offerPendingUpdates() void {
    if (pending_updates.items.len == 0) return;
    switch (app.updateMode()) {
        .silent => {
            for (pending_updates.items) |u| {
                dvui.log.info("plugin updates: installing {s} {s}", .{ u.title, u.to });
            }
            applyAllPendingUpdates();
            clearPendingUpdates();
        },
        .prompt => {
            var offer_window = false;
            // Index rather than pointer iteration: `applyPendingUpdate` writes back into the list.
            var i: usize = 0;
            while (i < pending_updates.items.len) : (i += 1) {
                const row = &pending_updates.items[i];
                if (!row.repair) {
                    offer_window = true;
                    continue;
                }
                dvui.log.info("plugin updates: repairing {s} {s} (enabled but not loaded)", .{ row.title, row.to });
                applyPendingUpdate(row.id);
            }
            // Repairs already in flight are left on the list so they show their progress if the
            // window opens for something else, and drop themselves as they land (`tick`). With
            // nothing but repairs there is nothing to decide, so no window opens at all.
            if (offer_window) app.offerUpdates();
        },
    }
}

// ---- per-frame completion (main thread) ------------------------------------

/// Complete any finished downloads by loading them live, and apply plugin enable/disable /
/// uninstall requests queued from the store UI. Called once per frame from `Editor.tick`,
/// before the Host-registry iterations, so a freshly-registered or unloaded plugin never
/// mutates a list mid-iteration.
pub fn tick() void {
    if (comptime builtin.target.cpu.arch == .wasm32) {
        if (catalog) |*c| c.pump(web_fetch);
        Readme.pump();
        StoreIcon.pump();
        syncReadmeCenter();
        // Enable, Disable, Uninstall and the auto-update toggle all queue here and are applied
        // nowhere else — without this the web store's buttons lit up and did nothing. The
        // download queue below is the desktop's alone: on the web a plugin arrives through the
        // page's loader instead (`applyWebUpdate`, `queueInstall`).
        applyPendingActions();
        return;
    }

    syncReadmeCenter();
    autoUpdateTick();

    applyPendingActions();

    var i: usize = 0;
    while (i < jobs.count()) {
        const job = jobs.values()[i];
        switch (@as(JobStatus, @enumFromInt(job.status.load(.acquire)))) {
            .downloading => i += 1,
            .failed => {
                // Nobody asked for a quiet job, so it leaves no failed card to retry from. Log it,
                // drop the job, and put the Update button back on its row as Retry.
                if (job.quiet) {
                    dvui.log.warn("plugin updates: '{s}' could not be downloaded ({s})", .{ job.id, job.err_buf[0..job.err_len] });
                    markPendingUpdateFailed(job.id);
                    jobs.swapRemoveAt(i);
                    freeJob(job);
                    continue; // do not advance i — swapRemove moved a new entry into slot i
                }
                i += 1;
            },
            .downloaded => {
                // A freshly downloaded file is already sitting in the plugins directory.
                disk_scan_dirty = true;
                // `force = false`: an in-place update must not silently discard unsaved
                // documents the plugin owns, same protection `applySetEnabled`/
                // `applyUninstall` give the manual disable/uninstall actions. On
                // `DirtyDocuments`, the downloaded file stays at `job.dest` so Retry
                // (which threads `job.is_update` through, see `drawCardControls`) can
                // reapply the update once the user has saved/closed.
                const loaded = if (job.is_update)
                    app.update(job.id, false)
                else
                    app.install(job.id);
                loaded catch |err| {
                    // An automatic update the user never asked for reports nothing and leaves no
                    // Retry card: the new build is already sitting at `job.dest`, so a plugin held
                    // back by unsaved documents simply comes up updated at the next launch (or
                    // sooner, when `Editor.reconcileChangedPluginBinaries` sees the new file).
                    if (job.quiet) {
                        dvui.log.info("plugin updates: '{s}' not applied live ({s}); it will load at next launch", .{ job.id, @errorName(err) });
                        // Still off the offer: the newer build *is* installed, which is what the
                        // row was offering. Only bringing it live was deferred.
                        dropPendingUpdate(job.id);
                        jobs.swapRemoveAt(i);
                        freeJob(job);
                        continue;
                    }
                    if (err == error.DirtyDocuments) {
                        reportError("'{s}' has unsaved changes — save or close them first", .{job.id});
                    } else {
                        reportError("'{s}' failed to load: {s}", .{ job.id, @errorName(err) });
                    }
                    const n = @min(@errorName(err).len, job.err_buf.len);
                    @memcpy(job.err_buf[0..n], @errorName(err)[0..n]);
                    job.err_len = n;
                    job.status.store(@intFromEnum(JobStatus.failed), .release);
                    i += 1;
                    continue;
                };
                // Installed + loaded: drop the job so the card shows normal installed state, and
                // take the plugin off the update offer — it is no longer out of date.
                dropPendingUpdate(job.id);
                jobs.swapRemoveAt(i);
                freeJob(job);
                // do not advance i — swapRemove moved a new entry into slot i
            },
        }
    }
}

/// The README exists only while a card is selected; the layout handles "and the store tab is
/// active" through `takeover_when`. Idempotent — safe to call every frame.
fn syncReadmeCenter() void {
    app.host.setSurfaceHidden(readme_center_id, Readme.selectedId() == null);
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
    selected_detail_tab = .details;
    const src = readmeSource(entry) orelse RepoSource{ .repo = "" };
    Readme.select(entry.id, src.repo, src.subpath);

    // On a collapsed (phone / narrow web) layout the detail page we just selected renders in the
    // center, hidden behind the peeked-open explorer — so get out of its way: close the peek and
    // swing the bottom panel shut. No-op on a desktop-width window (see `Editor.revealCenter`).
    app.revealMain();
}

/// Reconstruct the `StoreEntry` for whichever plugin is currently selected in the detail center
/// (`Readme.selectedId()`), in the same priority order the install/store lists build theirs
/// (`draw`'s entry-building pass) — just for one id instead of the whole list. `snapshot` is the
/// caller's already-acquired catalog snapshot (or null when the catalog has never loaded); this
/// makes no locking decisions of its own.
fn selectedEntry(snapshot: ?store.Catalog.Snapshot) ?StoreEntry {
    return entryFor(Readme.selectedId() orelse return null, snapshot);
}

/// The `StoreEntry` for one id, in the same priority order the store list builds its entries in
/// (see `draw`'s entry-building pass) — just for one id instead of the whole list. `snapshot` is
/// the caller's already-acquired catalog snapshot (or null when the catalog has never loaded);
/// this makes no locking decisions of its own.
fn entryFor(id: []const u8, snapshot: ?store.Catalog.Snapshot) ?StoreEntry {
    const registry = if (snapshot) |snap| snap.summary.pluginById(id) else null;
    const release = if (snapshot) |snap| snap.shard.releaseFor(id) else null;

    if (app.host.pluginById(id)) |plugin| {
        return .{ .id = id, .title = plugin.display_name, .kind = .local, .registry = registry, .release = release, .plugin = plugin };
    }
    if (app.isDisabled(id)) {
        return .{ .id = id, .title = resolveTitle(id, id), .kind = .disabled, .registry = registry, .release = release };
    }
    if (app.isFailed(id)) {
        return .{ .id = id, .title = resolveTitle(id, id), .kind = .failed, .registry = registry, .release = release };
    }
    if (isOnDisk(id)) {
        return .{ .id = id, .title = resolveTitle(id, id), .kind = .on_disk, .registry = registry, .release = release };
    }
    if (registry != null) {
        return .{ .id = id, .title = resolveTitle(id, id), .kind = .registry, .registry = registry, .release = release };
    }
    return null;
}

/// `entry`'s on-disk manifest fields, probed once and memoised in `manifest_cache`. A dylib open
/// + zon parse per call is far too costly to redo every frame — these resolvers run once per
/// *listed card* (see `drawCardShell`), not just for the selected detail header. Returns an
/// all-empty `ProbedManifest` when the plugin has no readable dylib, which is cached too so a
/// missing/unreadable file isn't retried every frame. `manifest_cache` is cleared by
/// `refreshDiskScan` (install/uninstall/update/Refresh) so stale values can't stick.
fn probedManifestFor(id: []const u8) PluginLoader.ProbedManifest {
    if (comptime builtin.target.cpu.arch == .wasm32) return .{};
    if (manifest_cache.get(id)) |cached| return cached;

    const a = app.gpa;
    const empty: PluginLoader.ProbedManifest = .{};

    const plugins_dir = std.fs.path.join(a, &.{ app.config_folder, "plugins" }) catch return empty;
    defer a.free(plugins_dir);
    const file_name = PluginLoader.pluginFilename(id, a) catch return empty;
    defer a.free(file_name);
    const path = std.fs.path.join(a, &.{ plugins_dir, id, file_name }) catch return empty;
    defer a.free(path);

    const probed = PluginLoader.probeManifestInfo(a, path) orelse empty;
    const id_dup = a.dupe(u8, id) catch return probed;
    manifest_cache.put(a, id_dup, probed) catch {
        a.free(id_dup);
        PluginLoader.freeProbedManifest(a, probed);
        return empty;
    };
    return probed;
}

/// Best-known one-line description for `entry`: the registry's own (freshest — a published
/// `summary.json` entry may know more than a locally built manifest), else the plugin's own
/// manifest (`Editor.builtinManifest` for a built-in — no dylib to probe — or `probedManifestFor`
/// against its on-disk dylib for anything else). Null when none of the three have one.
fn descriptionFor(entry: StoreEntry) ?[]const u8 {
    if (entry.registry) |r| {
        if (r.description.len > 0) return r.description;
    }
    if (app.builtinManifest(entry.id)) |m| {
        return if (m.description.len > 0) m.description else null;
    }
    const probed = probedManifestFor(entry.id);
    return if (probed.description.len > 0) probed.description else null;
}

/// Best-known tag list for `entry` — same three-tier fallback as `descriptionFor`. Empty slice,
/// never null, when none of the three have any: every call site only ever iterates the result.
fn tagsFor(entry: StoreEntry) []const []const u8 {
    if (entry.registry) |r| {
        if (r.tags.len > 0) return r.tags;
    }
    if (app.builtinManifest(entry.id)) |m| return m.tags;
    return probedManifestFor(entry.id).tags;
}

/// Best-known **cosmetic** author credit for `entry` — self-asserted, never a trust signal (see
/// `publisherFor` for the attestable half). Same three-tier fallback as `descriptionFor`: a
/// registry entry's own `author` wins, since it's PR-reviewed and editable without a release.
fn authorFor(entry: StoreEntry) ?[]const u8 {
    if (entry.registry) |r| {
        if (r.author.len > 0) return r.author;
    }
    if (app.builtinManifest(entry.id)) |m| {
        return if (m.author.len > 0) m.author else null;
    }
    const probed = probedManifestFor(entry.id);
    return if (probed.author.len > 0) probed.author else null;
}

/// Optional custom link for `authorFor`'s credit. Same three-tier fallback as the rest; the
/// catalog carries it so an *uninstalled* store plugin's credit is still clickable, since there
/// is no local dylib to probe until it's installed. Only ever `http`/`https` — see
/// `drawAuthorLine`.
fn authorUrlFor(entry: StoreEntry) ?[]const u8 {
    if (entry.registry) |r| {
        if (r.author_url.len > 0) return r.author_url;
    }
    if (app.builtinManifest(entry.id)) |m| {
        return if (m.author_url.len > 0) m.author_url else null;
    }
    const probed = probedManifestFor(entry.id);
    return if (probed.author_url.len > 0) probed.author_url else null;
}

/// The **attestable** half of the credit line: who actually published the binary this host would
/// install. Derived server-side at ingest from the release URL the plugin's `manifest.json` was
/// fetched from — never self-asserted, so unlike `authorFor` it can't be spoofed by editing a
/// `plugin.zig.zon`. Built-ins ship inside the fizzy binary itself, so they're attributed to the
/// fizzy org directly rather than through the registry. Null when the store has no entry (a
/// sideloaded or purely local plugin has no publisher at all — that's the point).
fn publisherFor(entry: StoreEntry) ?[]const u8 {
    if (isBundled(entry.id)) return fizzy_publisher;
    if (entry.registry) |r| {
        if (r.publisher.len > 0) return r.publisher;
    }
    return null;
}

/// Owner of `fizzy_repo_url` — the publisher every bundled built-in is attributed to.
const fizzy_publisher = "fizzyedit";

/// Runs in `job.tasks`. `io` is passed in rather than read from `dvui.io` here so the worker never
/// races the UI thread writing that global (same reason `core/lsp/Client.zig` threads `io` through
/// its task mains). A shutdown mid-download lands on `.failed` via `error.Canceled`, which nothing
/// outlives — `freeJob` is what awaited us.
fn worker(job: *Job, io: std.Io) void {
    // Whatever happens below, the result is only ever *applied* by `tick` on the UI thread, so
    // every exit path has to wake a sleeping app — see `Job.win`.
    defer dvui.refresh(job.win, @src(), null);
    store.download.download(app.gpa, io, job.url, job.sha256, job.dest) catch |err| {
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

/// Kick off a download for `id`'s selected release on a worker task. UI-thread only (`draw`), like
/// every other `Job.tasks` operation.
fn startDownload(id: []const u8, release: store.ShardRelease, opts: DownloadOptions) void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    const dl = release.downloadFor(compat.hostKey()) orelse return;
    startDownloadUrl(id, dl.url, dl.sha256, opts);
}

/// The half of `startDownload` that no longer needs the registry: everything after a release has
/// been resolved to one download for this host.
///
/// Guarded at comptime like `startDownload`, and it has to be: this is the path that writes a
/// dylib into the plugins directory, which a browser has neither the filesystem nor the `dlopen`
/// for. `applyPendingUpdate` reaches here without passing through `startDownload`, so one guard
/// upstream is not enough — and since the store became its own module, an unguarded path is a
/// wasm *compile* error rather than dead code.
fn startDownloadUrl(id: []const u8, url: []const u8, sha256: []const u8, opts: DownloadOptions) void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    removeJob(id); // replace any prior failed job

    const job = buildJob(id, url, sha256, opts) catch {
        reportError("could not prepare download for '{s}'", .{id});
        return;
    };
    jobs.put(app.gpa, job.id, job) catch {
        freeJob(job);
        return;
    };
    // `concurrent`, not `async`: the download must run off the UI thread, never inline here.
    job.tasks.concurrent(dvui.io, worker, .{ job, dvui.io }) catch {
        _ = jobs.swapRemove(job.id);
        freeJob(job);
        reportError("could not start download for '{s}'", .{id});
        return;
    };
}

/// Allocate a `Job` with all strings owned; `errdefer` unwinds every partial allocation so a
/// mid-build OOM never leaks.
pub const DownloadOptions = struct {
    /// Replace a *running* plugin (unload + reload) rather than installing a fresh one.
    is_update: bool,
    /// Suppress the error reporting and Retry card a user-initiated job leaves behind.
    quiet: bool = false,
};

fn buildJob(id: []const u8, url: []const u8, sha256: []const u8, opts: DownloadOptions) !*Job {
    const a = app.gpa;

    const plugins_dir = try std.fs.path.join(a, &.{ app.config_folder, "plugins" });
    defer a.free(plugins_dir);
    const plugin_dir = try std.fs.path.join(a, &.{ plugins_dir, id });
    defer a.free(plugin_dir);
    std.Io.Dir.createDirAbsolute(dvui.io, plugins_dir, .default_dir) catch {}; // best-effort; exists is fine
    std.Io.Dir.createDirAbsolute(dvui.io, plugin_dir, .default_dir) catch {}; // best-effort; exists is fine
    const file_name = try PluginLoader.pluginFilename(id, a);
    defer a.free(file_name);

    const job = try a.create(Job);
    errdefer a.destroy(job);
    const id_dup = try a.dupe(u8, id);
    errdefer a.free(id_dup);
    const url_dup = try a.dupe(u8, url);
    errdefer a.free(url_dup);
    const sha_dup = try a.dupe(u8, sha256);
    errdefer a.free(sha_dup);
    const dest = try std.fs.path.join(a, &.{ plugin_dir, file_name });
    errdefer a.free(dest);

    job.* = .{
        .status = .init(@intFromEnum(JobStatus.downloading)),
        .id = id_dup,
        .url = url_dup,
        .sha256 = sha_dup,
        .dest = dest,
        .is_update = opts.is_update,
        .quiet = opts.quiet,
        .win = dvui.currentWindow(),
    };
    return job;
}

// ---- drawing ---------------------------------------------------------------

fn installedVersion(id: []const u8) ?std.SemanticVersion {
    for (app.loadedLibs()) |loaded| {
        if (std.mem.eql(u8, loaded.plugin_id, id)) return loaded.version_info.plugin_version;
    }
    return null;
}

/// The recorded load-failure for `id`, if any — asked of the app rather than read off a
/// `StoreEntry`, so it surfaces even when a registry row (which takes merge precedence over the
/// local `.failed` row, see `draw`) shadows the same id.
fn failedInfo(id: []const u8) ?PluginManager.Failure {
    return app.failure(id);
}

/// The plugin's current on-disk version, regardless of whether it is loaded, disabled, or a
/// rejected (failed) build: the live loaded version when running, else a failed build's probed
/// version, else the last version we remembered (loaded earlier this session, or probed while
/// disabled — see `probeOnDiskInfo`).
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
    /// `on_disk` is the catch-all for a plugin directory that exists but is in none of the
    /// fizzy's in-memory states (not loaded, not disabled, no recorded failure) — see `disk_ids`.
    kind: enum { registry, local, disabled, failed, on_disk },
    registry: ?store.SummaryEntry = null,
    /// This host's release for `id`, if the fetched shard has one (already fingerprint-resolved
    /// server-side — see `store.ShardRelease`). Still needs an arch check; see `selectedRelease`.
    release: ?store.ShardRelease = null,
    plugin: ?*sdk.Plugin = null,
    /// Fuzzy-match score against the current filter, assigned by `rankEntries`. Lower is better;
    /// 0 for every row when there is no filter.
    score: f64 = 0,
};

/// Stable, position-independent widget/branch id for a plugin id (avoids the old loop-index
/// ids that shifted as rows were added/removed).
fn hashId(id: []const u8) usize {
    return @truncate(std.hash.Wyhash.hash(0, id));
}

/// What the detail page is currently showing, as a reveal key: the selected plugin *and* the
/// open tab, since switching tabs swaps the body subtree just as much as switching plugins does.
fn revealKey() u64 {
    var h = std.hash.Wyhash.init(@intFromEnum(selected_detail_tab));
    h.update(Readme.selectedId() orelse "");
    return h.final();
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

/// How well `entry` matches the query, or null if it doesn't. Lower is better (see `core.fuzzy`).
///
/// Identity fields (id, title) and prose fields (description, author, tags) are scored separately
/// and the prose side is penalised, so a plugin *named* "theme" always outranks one that merely
/// mentions themes in its description — otherwise a long description full of common words can
/// score better than the name the user was actually typing.
fn scoreEntry(entry: StoreEntry, query: *const fuzzy.Query) ?f64 {
    if (query.isEmpty()) return 0;

    var identity: [3][]const u8 = undefined;
    var n: usize = 0;
    identity[n] = entry.id;
    n += 1;
    identity[n] = entry.title;
    n += 1;
    if (entry.plugin) |p| {
        identity[n] = p.display_name;
        n += 1;
    }
    var best = fuzzy.scoreBest(identity[0..n], query, .{ .plain = true });

    // `descriptionFor`/`tagsFor` already fall back past the registry (built-in manifest, then a
    // dylib probe), so a plugin with no registry entry yet still scores on its own prose — only
    // `author` has no such fallback (it's registry-only, see `docs/PLUGIN_MANIFEST_PLAN.md`).
    const author = if (entry.registry) |r| r.author else "";
    var prose = fuzzy.scoreBest(&.{ descriptionFor(entry) orelse "", author }, query, .{ .plain = true });
    for (tagsFor(entry)) |tag| {
        if (fuzzy.score(tag, query, .{ .plain = true })) |s| {
            if (prose == null or s < prose.?) prose = s;
        }
    }
    if (prose) |s| {
        const penalised = s + prose_match_penalty;
        if (best == null or penalised < best.?) best = penalised;
    }
    return best;
}

/// Added to description/author/tag hits so they rank below any name/id hit.
const prose_match_penalty: f64 = 2.0;

/// Best-first, falling back to the A→Z order for equal scores.
fn entryScoreLess(_: void, lhs: StoreEntry, rhs: StoreEntry) bool {
    if (lhs.score != rhs.score) return lhs.score < rhs.score;
    return entryLess({}, lhs, rhs);
}

/// Drop non-matching entries and order what's left. With no query this is the plain A→Z list the
/// store has always shown; with one, the best match is the first card.
fn rankEntries(entries: *std.ArrayListUnmanaged(StoreEntry), query: *const fuzzy.Query) void {
    if (query.isEmpty()) {
        std.sort.pdq(StoreEntry, entries.items, {}, entryLess);
        return;
    }

    var keep: usize = 0;
    for (entries.items) |entry| {
        const s = scoreEntry(entry, query) orelse continue;
        entries.items[keep] = entry;
        entries.items[keep].score = s;
        keep += 1;
    }
    entries.shrinkRetainingCapacity(keep);
    // Stable, so entries equal on both score and title keep insertion order.
    std.sort.block(StoreEntry, entries.items, {}, entryScoreLess);
}

fn draw(_: ?*anyopaque) anyerror!dvui.App.Result {
    // Unlike the old flat list, the tab now fills the full explorer viewport height
    // (`expand = .both`, not just `.horizontal`) so the section below the tab strip gets a
    // genuinely bounded height — it then scrolls its own overflow (see
    // `drawStoreSection`/`drawInstalledSection`) rather than the whole tab growing forever and
    // leaning on the explorer's own scrollArea (`files.zig`'s tree still does that; we don't).
    var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer vbox.deinit();

    // First time the tab is shown, fetch the registry. Local state is rescanned here too, and
    // again whenever an install/uninstall/enable has touched the plugins directory since.
    if (!first_draw_done) {
        first_draw_done = true;
        if (catalog) |*c| c.refresh();
    }
    if (disk_scan_dirty) refreshLocalInfo();

    try drawHeader();

    // Filter row — same shape as the file tree (search icon + borderless text entry).
    var filter_hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 4 } });
    core.icon.icon(
        @src(),
        "FilterIcon",
        icons.tvg.lucide.search,
        .{ .stroke_color = .{ .color = dvui.themeGet().color(.window, .text) } },
        .{ .gravity_y = 0.5, .padding = dvui.Rect.all(0) },
    );
    const filter_edit = dvui.textEntry(@src(), .{ .placeholder = "Filter..." }, .{
        .expand = .horizontal,
        .background = false,
    });
    const filter_text = filter_edit.getText();
    filter_edit.deinit();
    filter_hbox.deinit();
    var query = fuzzy.Query.init(filter_text);

    const cat = if (catalog) |*c| c else return .ok;
    const maybe_snapshot = cat.acquire();
    defer cat.release();

    // Registry availability is a property of the *store* pane alone. The installed pane is built
    // entirely from local state (loaded plugins, disabled ids, load failures, the plugins
    // directory) and needs no network at all, so it always draws immediately — offline, behind a
    // captive portal, or while the very first fetch is still in flight. Installed cards simply
    // render their local half until a snapshot arrives to enrich them (see `have_snapshot`).
    have_snapshot = maybe_snapshot != null;

    const arena = dvui.currentWindow().arena();

    // Store entries (STORE tab): one row per registry plugin, independent of local install
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
    rankEntries(&store_entries, &query);

    // Installed entries (INSTALLED tab): everything genuinely present locally — loaded,
    // disabled-on-disk, sideloaded, or a failed/rejected build — enriched with a matching
    // registry row (for "store vX" / Update-availability) wherever the registry knows the id too.
    var installed_entries: std.ArrayListUnmanaged(StoreEntry) = .empty;
    for (app.host.plugins.items) |plugin| {
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
    for (app.disabledIds()) |id| {
        if (!std.unicode.utf8ValidateSlice(id)) continue;
        if (app.host.pluginById(id) != null) continue;
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
    // the app's failure list when drawing (see `failedInfo`/`currentVersion`).
    for (app.failures()) |f| {
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
    // Anything else sitting in the plugins directory. Nothing in fizzy's memory describes
    // these (a half-finished install, a sideloaded directory, a build from a previous session we
    // never tried to load), but they are on disk, so they get a card — and therefore always an
    // Uninstall, and a Reinstall when the store has a build for this host (see `drawCardControls`).
    for (disk_ids.items) |id| {
        if (isBundled(id)) continue;
        if (containsId(installed_entries.items, id)) continue;
        installed_entries.append(arena, .{
            .id = id,
            .title = resolveTitle(id, id),
            .kind = .on_disk,
            .registry = if (maybe_snapshot) |snap| snap.summary.pluginById(id) else null,
            .release = if (maybe_snapshot) |snap| snap.shard.releaseFor(id) else null,
        }) catch {};
    }
    rankEntries(&installed_entries, &query);

    drawPaneTabs(cat.status());

    switch (selected_pane_tab) {
        .store => _ = drawStoreSection(store_entries.items, filter_text, cat.status()),
        .installed => _ = drawInstalledSection(installed_entries.items, filter_text),
    }
    return .ok;
}

/// Store / Installed strip below the filter row. Same look as the detail page's
/// DETAILS/CHANGELOG strip (`drawDetailTabs`), plus the store's refresh spinner pinned to the
/// right so an in-flight fetch stays visible from either tab.
fn drawPaneTabs(status: store.Status) void {
    var strip = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 12, .y = 6, .h = 6 },
    });
    defer strip.deinit();

    if (tabButton(@src(), "STORE", 0, selected_pane_tab == .store)) selected_pane_tab = .store;
    if (tabButton(@src(), "INSTALLED", 1, selected_pane_tab == .installed)) selected_pane_tab = .installed;

    // A refresh over existing cards is a footnote, not a takeover: the cards stay put and this
    // spinner is the only sign a fetch is outstanding.
    if (status == .fetching and have_snapshot) {
        core.dialogs.bubbleSpinner(@src(), .{
            .min_size_content = .{ .w = 14, .h = 14 },
            .gravity_x = 1.0,
            .gravity_y = 0.5,
            .color_text = .{ .color = dvui.themeGet().color(.window, .text).opacity(0.7) },
        }, .{});
    }
}

/// True while the catalog holds a parsed snapshot — i.e. the registry half of every card is real
/// rather than merely unknown-so-far. Set once per `draw` (under the catalog lock) and read by the
/// card drawing helpers, which run inside that same pass.
///
/// The distinction matters because "the store has no build for this host" and "we have not been
/// able to ask the store" look identical from a null `entry.release`, and only the first is a
/// genuine, user-actionable problem. Offline, the second is what's true — so the red
/// "No compatible build in store" text is suppressed rather than accusing every installed plugin
/// of being unpublished. See `drawCardControls`/`drawStoreCardControls`.
var have_snapshot = false;

/// Centered "Fetching store…" spinner, drawn inside the *store* pane only while the very first
/// catalog fetch is in flight. The installed pane above it is unaffected: it renders from local
/// state and never waits on the network (see `draw`).
fn drawFetchingPlaceholder() void {
    var center = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = false,
    });
    defer center.deinit();

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .background = false,
    });
    defer row.deinit();

    core.dialogs.bubbleSpinner(@src(), .{
        .min_size_content = .{ .w = 20, .h = 20 },
        .gravity_y = 0.5,
        .color_text = .{ .color = dvui.themeGet().color(.window, .text) },
        .padding = .{ .w = 10 },
    }, .{});
    dvui.labelNoFmt(@src(), "Fetching store…", .{}, .{
        .gravity_y = 0.5,
        .color_text = .{ .color = dvui.themeGet().color(.window, .text).opacity(0.8) },
    });
}

/// Store pane empty state when the registry could not be reached and we have nothing cached:
/// what happened, that it doesn't affect the pane above, and a way to try again. Offline is an
/// ordinary state for this pane, not an error banner over the whole tab.
fn drawUnreachablePlaceholder() void {
    const theme = dvui.themeGet();
    const muted = theme.color(.window, .text).opacity(0.7);

    var center = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = false });
    defer center.deinit();

    var col = dvui.box(@src(), .{ .dir = .vertical }, .{
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .background = false,
    });
    defer col.deinit();

    core.icon.icon(@src(), "StoreOffline", icons.tvg.lucide.@"cloud-off", .{ .stroke_color = .{ .color = muted } }, .{
        .gravity_x = 0.5,
        .min_size_content = .{ .w = 28, .h = 28 },
        .margin = .{ .h = 6 },
    });
    dvui.labelNoFmt(@src(), "Can't reach the plugin store", .{}, .{
        .gravity_x = 0.5,
        .color_text = .{ .color = muted },
    });
    var tl = dvui.textLayout(@src(), .{ .break_lines = true }, .{
        .background = false,
        .gravity_x = 0.5,
        .max_size_content = .{ .w = 240, .h = std.math.floatMax(f32) },
        .font = dvui.Font.theme(.body),
    });
    tl.addText("Your installed plugins above still work normally.", .{ .color_text = .{ .color = muted.opacity(0.8) } });
    tl.deinit();
    if (dvui.button(@src(), "Try again", .{}, .{ .gravity_x = 0.5, .margin = .{ .y = 6 } })) {
        if (catalog) |*c| c.refresh();
    }
}

/// How many cards the entry animation staggers across before every later card shares the last
/// card's delay — without a cap, a large store would spend seconds trickling cards in.
const card_stagger_cap: usize = 10;

/// Slide a card in from the left with a slight overshoot the first time its id is drawn,
/// staggered by list position so a freshly-fetched list cascades instead of appearing all at
/// once. Same widget and easing the workspace's recent-folder list uses.
///
/// `id_extra` is the plugin id's hash rather than the loop index on purpose: `dvui.animate`
/// re-triggers whenever `dvui.firstFrame` sees a new widget id, so indexing by position would
/// replay the whole cascade every time re-ranking moved a card (i.e. on every filter keystroke).
/// Keyed by id, each plugin animates exactly once, no matter how the list is later sorted.
fn cardAnimator(src: std.builtin.SourceLocation, entry: StoreEntry, index: usize) *dvui.AnimateWidget {
    const stagger = @min(index, card_stagger_cap);
    return dvui.animate(src, .{
        .kind = .horizontal,
        .duration = 200_000 + 40_000 * @as(i32, @intCast(stagger)),
        .easing = dvui.easing.outBack,
    }, .{
        .id_extra = hashId(entry.id),
        .expand = .horizontal,
    });
}

/// STORE tab: a pure "browse the store" list, one card per registry plugin. Wrapped in its
/// own scrollArea (independent of the installed pane above) with the same edge-shadow treatment
/// `explorer/Explorer.zig` uses, so a narrow pane or an overly-wide card still scrolls with the
/// usual visual hint instead of clipping silently. Returns the shown count (unused).
///
/// This pane — and only this pane — owns the registry's loading/offline states: the spinner while
/// the first fetch is in flight, the unreachable empty state when it fails, and a small inline
/// spinner beside the header while a refresh runs over already-shown cards.
fn drawStoreSection(entries: []const StoreEntry, filter_text: []const u8, status: store.Status) usize {
    var pane_box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = false });
    defer pane_box.deinit();

    var scroll = dvui.scrollArea(@src(), .{
        .scroll_info = &store_scroll_info,
        .horizontal_bar = .auto_overlay,
        .vertical_bar = .auto_overlay,
    }, .{ .expand = .both, .background = false });

    // `entries` is already filtered and ranked by `rankEntries` — best match first.
    var shown: usize = 0;
    for (entries) |entry| {
        var anim = cardAnimator(@src(), entry, shown);
        defer anim.deinit();
        shown += 1;
        drawStoreCard(entry);
    }
    if (shown == 0) {
        if (!have_snapshot) {
            // Nothing cached yet, so the empty list says nothing about the store's contents —
            // it's still loading, or we couldn't ask. `.idle` can only be a fetch about to start
            // (see `draw`'s `first_draw_done`), so it reads as loading too.
            switch (status) {
                .failed => drawUnreachablePlaceholder(),
                else => drawFetchingPlaceholder(),
            }
        } else {
            dvui.labelNoFmt(
                @src(),
                if (filter_text.len > 0) "No store plugins match the filter." else "No plugins available in the store.",
                .{},
                .{ .margin = .{ .y = 8 } },
            );
        }
    }

    scroll.deinit();

    const rs = pane_box.data().contentRectScale();
    core.draw.drawScrollEdgeShadows(rs, rs, &store_scroll_info, .{});

    return shown;
}

/// INSTALLED tab: everything genuinely present locally, grouped under "Local" (sideloaded dylibs)
/// and "Built-in" (bundled + static built-ins) headers. This is the *only* place enable/disable,
/// update, uninstall, and failed-to-load detail show up — see `drawCard`. Returns the shown
/// count (unused).
fn drawInstalledSection(entries: []const StoreEntry, filter_text: []const u8) usize {
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
        if (shown_local == 0) drawSectionHeader("Local", 0);
        var anim = cardAnimator(@src(), entry, shown_local);
        defer anim.deinit();
        shown_local += 1;
        shown += 1;
        drawCard(entry);
    }

    var shown_builtin: usize = 0;
    for (entries) |entry| {
        if (!isBuiltIn(entry.id)) continue;
        if (shown_builtin == 0) drawSectionHeader("Built-in", 1);
        var anim = cardAnimator(@src(), entry, shown_builtin);
        defer anim.deinit();
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

    scroll.deinit();

    const rs = pane_box.data().contentRectScale();
    core.draw.drawScrollEdgeShadows(rs, rs, &installed_scroll_info, .{});

    return shown;
}

/// Small uppercase-ish section label above a group of cards in the INSTALLED tab. `id_extra`
/// disambiguates the "Local" and "Built-in" calls, which otherwise share a source location.
fn drawSectionHeader(title: []const u8, id_extra: usize) void {
    dvui.labelNoFmt(@src(), title, .{}, .{
        .id_extra = id_extra,
        .font = dvui.Font.theme(.heading),
        .color_text = .{ .color = dvui.themeGet().color(.control, .text) },
        .margin = .{ .x = 4, .y = 6 },
    });
}

/// Bundled built-ins (always-linked, protected) belong in the "Built-in" group rather than "Installed".
fn isBuiltIn(id: []const u8) bool {
    return isBundled(id);
}

/// INSTALLED-tab card: full state — enabled checkbox, update/uninstall, failed-to-load detail —
/// via `drawCardControls`/`infoLine` (which still shows "installed vX"). See `drawCardShell`.
fn drawCard(entry: StoreEntry) void {
    var buf: [192]u8 = undefined;
    drawCardShell(entry, drawNoCardControls, infoLine(&buf, entry), .{ .show_failure = true, .hover_toggles = true, .compact = true });
}

/// STORE-tab card: browse-only — just an install button or a "no compatible build" message via
/// `drawStoreCardControls`/`storeInfoLine` (never "installed vX": that's the INSTALLED tab's job,
/// even for a store plugin the user happens to already have installed). See `drawCardShell`.
fn drawStoreCard(entry: StoreEntry) void {
    var buf: [192]u8 = undefined;
    drawCardShell(entry, drawStoreCardControls, storeInfoLine(&buf, entry), .{});
}

/// Static floor under a card's (and so the whole explorer tab's) width: below this, the
/// scrollArea takes over horizontally rather than squeezing the card further. Deliberately a
/// constant rather than content-derived (see `drawCardShell`) — roughly enough room for a short
/// title, a few words of description, and the install/update controls without either crowding
/// into the other. A fraction of the app width was the other option on the table, but that would
/// mean plumbing the window size down to every card just to move a number that has no reason to
/// track it; a plain constant is simpler and just as legible in practice.
const card_min_w: f32 = 280;

/// Applied as `max_size_content.w` to every card text line (title/description/author/row2) below.
/// This is *not* a render-width cap — `max_size_content` only clamps a widget's *reported* min
/// size (see `WidgetData.minSizeSetAndRefresh`), never the rect it actually gets handed to draw
/// into. With `.expand = .horizontal`, that rect still comes from the card's real (fluid) width;
/// `LabelWidget`'s default `ellipsize = true` then truncates the render to fit it. What this
/// *does* do is stop a plain label's other behavior — reporting its full unwrapped text width as
/// its min size — from ever reaching the card and inflating `card_min_w` into "however long the
/// longest description happens to be", which is exactly what the scrollArea must not do.
const card_text_no_floor: f32 = 1;

/// The one card text line that does *not* get `card_text_no_floor`: the title. A card whose name
/// has been squeezed away is unusable — you can't tell which plugin the controls belong to — so
/// the title reports up to this much width and the scrollArea grows a horizontal bar rather than
/// eating into it. Bounded by construction (unlike a description, whose length is unbounded and
/// author-controlled): a title longer than this still reports only this much and ellipsizes, so
/// the card's min width can't drift with the catalog's longest name.
const card_title_min_w: f32 = 96;

/// Padding for every text line inside a card's info column. `LabelWidget.defaults` is
/// `Rect.all(6)`, which across four always-drawn lines (title/description/author/row2) adds ~48px
/// of pure whitespace to a card whose text is only ~64px tall. The lines are already separated by
/// their own leading, so a small vertical pad is enough to keep them from touching; horizontally
/// the info column's own margin does the job, so the sides go to zero.
const card_text_padding: dvui.Rect = .{ .x = 0, .y = 1, .w = 0, .h = 1 };

/// Shared card shell: a clickable container (logo + info + state controls). Clicking anywhere
/// outside the controls selects the plugin (its README shows in the center). The controls consume
/// their own clicks so the card-level click never double-fires. `controls` draws the
/// bottom-right state controls (differs between the store and installed cards, see
/// `drawStoreCardControls`/`drawCardControls`); `row2_text` is the already-formatted dim
/// monospace id/version line (differs likewise, see `storeInfoLine`/`infoLine`); `show_failure`
/// gates the failed-to-load detail block, which only makes sense on an installed-pane card.
/// The per-card switches. A struct rather than four positional bools — the list cards, the store
/// cards and the update window each want a different combination, and `(…, true, false, true)`
/// says nothing at the call site.
const CardOptions = struct {
    /// Surface a rejected build's load-failure detail under the info line.
    show_failure: bool = false,
    /// Reveal the Enabled / Auto-update panel while the card is hovered.
    hover_toggles: bool = false,
    /// Clicking the card body selects it (and shows its README in the center).
    clickable: bool = true,
    /// Drop the empty-line reservation for description / author.
    ///
    /// The *store* pane keeps it: every card there is a registry row that has both, so reserving
    /// the lines costs nothing and keeps a long browse list on an even rhythm. Installed and
    /// update cards don't — a sideloaded or locally built plugin often has neither — and there the
    /// reservation is just a hole between the title and the rest of the card.
    compact: bool = false,
};

/// A card whose every control lives in its hover flyout instead (`drawHoverToggles`).
fn drawNoCardControls(_: StoreEntry) void {}

fn drawCardShell(entry: StoreEntry, controls: *const fn (StoreEntry) void, row2_text: []const u8, opts: CardOptions) void {
    const theme = dvui.themeGet();
    const selected = if (Readme.selectedId()) |sid| std.mem.eql(u8, sid, entry.id) else false;
    // Disabled plugins read as a faded card: half the surface fill opacity and half the shadow.
    //const disabled = app.isDisabled(entry.id);

    // The card stays lit while the pointer is inside its own flyout. The panel overhangs the
    // card's right edge, so `ButtonWidget`'s hover goes false the instant the mouse crosses into
    // it — without this the row would go dark while the menu it opened is still up and being used.
    // `flyout_rect` is last frame's, which is exactly when the pointer was over it.
    const flyout_pinned = opts.hover_toggles and flyoutIsFor(entry.id) and
        flyout_rect.contains(dvui.currentWindow().mouse_pt);

    const fill = if (selected or flyout_pinned)
        theme.color(.control, .fill).opacity(0.5)
    else
        theme.color(.content, .fill).opacity(0.0);

    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{}, .{
        .id_extra = hashId(entry.id),
        .expand = .horizontal,
        .min_size_content = .{ .w = card_min_w },
        .margin = .{ .x = 3, .y = 3, .w = 12, .h = 3 },
        .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
        .corners = dvui.CornerRect.all(8),
        .background = true,
        .color_fill = .{ .color = fill },
        .color_fill_hover = .{ .color = theme.color(.control, .fill).opacity(0.5) },
        .color_fill_press = .{ .color = theme.color(.control, .fill).opacity(0.9) },
    });
    defer bw.deinit();
    // Hover highlight without consuming click events, so the inner controls get first dibs; the
    // card's own click is processed *after* the controls (see `bw.processEvents()` below).
    bw.processHover();
    bw.drawBackground();

    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hbox.deinit();

        // 1. Logo (gravity 0), shown as-is. Fetch `ICON.png` from the plugin repo when known;
        // fall back to a loaded plugin's registered icon, then the generic placeholder.
        {
            var logo = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .gravity_y = 0.5,
                .min_size_content = .{ .w = 32, .h = 32 },
            });
            defer logo.deinit();
            if (repoSource(entry)) |src| StoreIcon.request(entry.id, src.repo, src.subpath);
            const drew = StoreIcon.draw(entry.id, 32) or app.host.drawPluginIcon(entry.id);
            if (!drew) {
                core.icon.icon(
                    @src(),
                    "PluginLogo",
                    icons.tvg.lucide.package,
                    .{ .stroke_color = .{ .color = theme.color(.window, .text) } },
                    .{ .gravity_y = 0.5, .min_size_content = .{ .w = 32, .h = 32 } },
                );
            }
        }

        // 2. State controls, bottom-right. `gravity_y = 1.0` on this wrapper (rather than the
        // shared `controls(entry)`'s own centered `gravity_y = 0.5` — that function is reused
        // as-is by the detail header, where centered is right) bottom-anchors it within the
        // card row, reading as "underneath the text stack" without actually nesting inside the
        // (vertical) info column, which would put it after `bw.processEvents()` below and lose
        // click priority — see the note there. Must still be laid out *before* the
        // (expand-horizontal) info column: a `gravity_x = 1.0` child reserves its natural width
        // from the right edge of whatever's left regardless of draw order, but an `expand`-ing
        // sibling's bottom-up min size would otherwise eat 100% of what's left and starve this
        // down to a zero-width row (the Uninstall trash button silently disappearing). This runs
        // its own processEvents and consumes its clicks before the card does.
        {
            var ctl_anchor = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .gravity_x = 1.0,
                // Bottom-anchored on a full card (it reads as sitting under the text stack);
                // centred on a compact one, where there is no four-line stack to sit under.
                .gravity_y = if (opts.compact) 0.5 else 1.0,
            });
            defer ctl_anchor.deinit();
            controls(entry);
        }

        // Claim the card-body click *now*, before the info column below: `dvui.clicked` skips
        // events a widget earlier in this pass already handled, and a `dvui.textLayout` always
        // captures press/release for its own text-selection (see its `processEvent`) regardless
        // of whether anyone actually wants to select that text. If the info column ran first, it
        // would silently steal every click landing on the failure text (the only remaining
        // `textLayout` below — everything else in the column is a plain label), so this has to
        // run after the (already-first) controls but before the (still-to-come) text.
        bw.processEvents();

        // 3. Info column: title (largest, bold) — description (single line, ellipsized) —
        // author — then the dim id/version line. Every line below is always drawn, even with an
        // empty string, so every card reserves the same four lines of height regardless of which
        // fields a given plugin actually has (see the "cards that are all the same size" ask).
        {
            var info = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .horizontal,
                .gravity_y = 0.5,
                .margin = .{ .x = 8 },
            });
            defer info.deinit();

            {
                var title_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
                defer title_row.deinit();
                const title_font = dvui.Font.theme(.title);
                dvui.labelNoFmt(@src(), entry.title, .{}, .{
                    .font = title_font.withWeight(.bold),
                    .expand = .horizontal,
                    .padding = card_text_padding,
                    .max_size_content = .{ .w = card_title_min_w, .h = std.math.floatMax(f32) },
                });
                if (releaseDate(entry)) |date| {
                    dvui.labelNoFmt(@src(), date, .{}, .{
                        .font = dvui.Font.theme(.mono),
                        .color_text = .{ .color = theme.color(.control, .text) },
                        .gravity_y = 0.5,
                        .padding = card_text_padding,
                        .margin = .{ .x = 6 },
                    });
                }
            }

            // Single line, ellipsized (LabelWidget's default) rather than wrapped — a tooltip
            // picks up the full text only when it was actually truncated.
            const description: []const u8 = descriptionFor(entry) orelse "";
            if (!opts.compact or description.len > 0) {
                var desc_label: dvui.LabelWidget = undefined;
                desc_label.initNoFmt(@src(), description, .{}, .{
                    .font = dvui.Font.theme(.body),
                    .color_text = .{ .color = theme.color(.window, .text).opacity(0.75) },
                    .expand = .horizontal,
                    .padding = card_text_padding,
                    .max_size_content = .{ .w = card_text_no_floor, .h = std.math.floatMax(f32) },
                });
                desc_label.draw();
                if (desc_label.ellipsized) {
                    dvui.tooltip(
                        @src(),
                        .{
                            .active_rect = desc_label.data().borderRectScale().r,
                            .position = .vertical,
                            .delay = 500_000,
                        },
                        "{s}",
                        .{desc_label.label_str},
                        .{
                            .border = .all(0),
                            .box_shadow = .{
                                .color = .black,
                                .corners = dvui.CornerRect.all(8),
                                .fade = 4,
                                .alpha = 0.25,
                            },
                        },
                    );
                }
                desc_label.deinit();
            }

            const author: []const u8 = if (entry.registry) |r| r.author else "";
            if (!opts.compact or author.len > 0) {
                dvui.labelNoFmt(@src(), author, .{}, .{
                    .font = dvui.Font.theme(.body),
                    .color_text = .{ .color = theme.color(.control, .text) },
                    .expand = .horizontal,
                    .padding = card_text_padding,
                    .max_size_content = .{ .w = card_text_no_floor, .h = std.math.floatMax(f32) },
                });
            }

            dvui.labelNoFmt(@src(), row2_text, .{}, .{
                .font = dvui.Font.theme(.mono),
                .color_text = .{ .color = theme.color(.control, .text) },
                .expand = .horizontal,
                .padding = card_text_padding,
                .max_size_content = .{ .w = card_text_no_floor, .h = std.math.floatMax(f32) },
            });

            // A local build that is on disk but rejected at load time (ABI/SDK mismatch, id
            // collision, etc.) — this is the *only* place that surfaces it (there is no more
            // startup dialog), so it must carry every diagnostic detail we have. It wraps across
            // the card's full width: nothing shares this row any more, since every control moved
            // into the hover flyout. The zero-floor max (as on the labels above) keeps the wrapped
            // text from reporting its unwrapped width as the card's min size. Store (upper-pane)
            // cards never show this — see `show_failure`.
            if (opts.show_failure) if (failedInfo(entry.id)) |f| {
                var fail_wrap = dvui.box(@src(), .{ .dir = .vertical }, .{
                    .expand = .horizontal,
                    .max_size_content = .{ .w = card_text_no_floor, .h = std.math.floatMax(f32) },
                });
                defer fail_wrap.deinit();

                var fail_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 2 } });
                defer fail_row.deinit();
                core.icon.icon(
                    @src(),
                    "PluginFailedIcon",
                    icons.tvg.lucide.@"circle-alert",
                    .{ .stroke_color = .{ .color = theme.color(.err, .fill) }, .fill_color = .{ .color = theme.color(.err, .fill) } },
                    .{ .gravity_y = 0, .margin = .{ .y = 3 }, .min_size_content = .{ .w = 14, .h = 14 } },
                );
                var fail_buf: [256]u8 = undefined;
                const fail_text = if (f.detail) |d|
                    std.fmt.bufPrint(&fail_buf, "Failed to load: {s} ({s})", .{ f.reason, d }) catch f.reason
                else
                    std.fmt.bufPrint(&fail_buf, "Failed to load: {s}", .{f.reason}) catch f.reason;
                const fail_font = dvui.Font.theme(.body);
                var fail_tl = dvui.textLayout(@src(), .{}, .{
                    .expand = .horizontal,
                    .background = false,
                    .margin = .{ .x = 4 },
                    .font = fail_font.withSize(fail_font.size - 1),
                });
                fail_tl.addText(fail_text, .{ .color_text = .{ .color = theme.color(.err, .text) } });
                fail_tl.deinit();
            };
        }
    }

    // The info column's failure-detail text layout sets an ibeam cursor on hover (for its own
    // text selection) regardless of whether the card claimed its clicks above — restore the
    // plain card cursor now that it's had its turn this frame ("last cursorSet call wins" for
    // the frame).
    if (bw.hover) dvui.cursorSet(.arrow);
    if (bw.clicked() and opts.clickable) toggleSelect(entry);

    // Drawn last so the flyout paints over the card and gets first refusal on the mouse. Its
    // anchor is this card's own rect, so it has to be inside the card widget's scope.
    if (opts.hover_toggles) drawHoverToggles(entry, bw.data().borderRectScale().r, bw.hover);
}

// ---- per-card hover flyout -------------------------------------------------

/// Which card's toggle flyout is showing, by id. A fixed buffer rather than an allocation: this
/// changes on every mouse move across the list, and plugin ids are short by construction
/// (`Editor.isValidPluginId`). An over-long id simply never gets a flyout.
var flyout_id_buf: [96]u8 = undefined;
var flyout_id_len: usize = 0;
/// Last drawn flyout rect, so the mouse can leave the card *into* the flyout without it closing.
var flyout_rect: dvui.Rect.Physical = .{};
/// The popover's own rect, which it animates its size through across frames. Zeroed whenever the
/// flyout moves to another card, so each one grows from its anchor rather than sliding over.
var flyout_win_rect: dvui.Rect = .{};

/// How far the flyout overlaps the card's right edge (natural px). Non-zero deliberately: a gap
/// here is a dead strip the pointer crosses on the way over, and the flyout would close in it.
const flyout_overlap: f32 = 6;

fn flyoutIsFor(id: []const u8) bool {
    return flyout_id_len == id.len and std.mem.eql(u8, flyout_id_buf[0..flyout_id_len], id);
}

fn flyoutSet(id: []const u8) void {
    if (id.len > flyout_id_buf.len) {
        flyout_id_len = 0;
        return;
    }
    @memcpy(flyout_id_buf[0..id.len], id);
    flyout_id_len = id.len;
    flyout_rect = .{};
    flyout_win_rect = .{};
}

fn flyoutClear() void {
    flyout_id_len = 0;
    flyout_rect = .{};
    flyout_win_rect = .{};
}

/// The installed card's Enabled / Auto-update controls, as a small rounded panel butted against
/// the card's right edge while the card (or the panel itself) is hovered.
///
/// These two are settings rather than actions, and a sidebar-width card has no room for four
/// controls in a row without squeezing the title and description into nothing. Hover-revealing
/// them keeps the resting card readable and still puts them one mouse-move away.
fn drawHoverToggles(entry: StoreEntry, card_r: dvui.Rect.Physical, card_hovered: bool) void {
    // Bundled built-ins are neither disablable nor store-updatable, and a plugin with no build on
    // disk has nothing to toggle.
    if (isBundled(entry.id) or !isInstalled(entry)) return;

    const mouse = dvui.currentWindow().mouse_pt;
    const showing = flyoutIsFor(entry.id);
    // `card_hovered` is false the moment the pointer crosses onto the flyout (which overhangs the
    // card), so the panel's own rect has to keep it alive.
    const keep_open = card_hovered or (showing and flyout_rect.contains(mouse));
    if (!keep_open) {
        if (showing) flyoutClear();
        return;
    }
    if (!showing) flyoutSet(entry.id);
    if (!flyoutIsFor(entry.id)) return; // id too long to track

    const scale = dvui.windowNaturalScale();
    // Anchor to the card's right edge *or* the visible edge of the list, whichever comes first.
    // A card is wider than a narrow sidebar (`card_min_w` + horizontal scroll), so its own right
    // edge is often somewhere out under the center pane — anchoring there would leave the panel
    // floating in the middle of the editor, detached from the row it belongs to. Clipping is also
    // what the pointer sees: the user can only hover the part of the card that is actually drawn.
    const clip = dvui.clipGet();
    const right = @min(card_r.x + card_r.w, clip.x + clip.w);
    const anchor: dvui.Point.Physical = .{
        .x = right - flyout_overlap * scale,
        // Clamped for the same reason: a card scrolled half out of view still gets its panel
        // beside the visible half.
        .y = std.math.clamp(card_r.y + card_r.h / 2, clip.y, clip.y + clip.h),
    };

    // The same frosted panel the account flyout and every dialog use (`core.widgets.Popover`):
    // one definition of what a floating surface in fizzy looks like — the blur behind it, the
    // fill, the corners, the shadow — rather than this one hand-rolling a translucent box that
    // only resembled them.
    //
    // `Popover` anchors by its top-left, so the vertical centring comes from the height it had
    // last frame; on the first frame there is none, which is also the frame it grows out of the
    // anchor, so nothing jumps.
    const natural = anchor.toNatural();
    var panel = core.widgets.Popover.init(@src(), .{
        .rect = &flyout_win_rect,
        .anchor = .{ .x = natural.x, .y = natural.y - flyout_win_rect.h / 2 },
        .id_extra = hashId(entry.id),
    });
    defer panel.deinit();

    drawToggleControls(entry, .compact);
    // The card's actions live here as well, so the card body itself is pure content — that is what
    // lets a rejected build's failure message wrap across the full card width instead of squeezing
    // into a fixed column beside a row of buttons.
    //
    // Wrapped in a normally-packed row of its own: `drawCardControls`'s box sets `gravity_y = 0.5`
    // (right for the detail header, where it centres against the header), and a gravity-in-(0,1)
    // *direct* child of a vertical box is treated as positioned/overlay by `BoxWidget.rectFor` —
    // it would be drawn on top of the toggles above instead of under them.
    {
        var actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 2 } });
        defer actions.deinit();
        drawCardControls(entry);
    }

    // Recorded *after* the contents so the rect matches what was actually laid out this frame.
    flyout_rect = panel.rect;
}

/// The two per-plugin settings shared by the hover flyout and the detail page header: whether the
/// plugin loads at all, and whether the store's update pass considers it.
/// `.compact` shrinks the labels a step for the hover flyout, which sits over the content rather
/// than in a header and should read as a small menu, not a second row of primary controls.
const ToggleSize = enum { normal, compact };

fn drawToggleControls(entry: StoreEntry, size: ToggleSize) void {
    if (isBundled(entry.id)) return;
    const body = dvui.Font.theme(.body);
    const opts: dvui.Options = .{
        .gravity_y = 0.5,
        .font = switch (size) {
            .normal => body,
            .compact => body.larger(-1.0),
        },
    };

    const loaded = app.host.pluginById(entry.id) != null;
    const disabled = app.isDisabled(entry.id);
    const failed = entry.kind == .failed or app.isFailed(entry.id);
    const untracked = !loaded and !disabled and !failed and (entry.kind == .on_disk or isOnDisk(entry.id));

    // A *failed* build is the one case with nothing to toggle — it already tried and lost, and
    // gets the Retry/Reinstall buttons on the card instead.
    // Each control gets its own normally-packed row: these are drawn into *vertical* parents (the
    // hover flyout, the detail header's toggle column), where a `gravity_y = 0.5` direct child is
    // treated as positioned/overlay and would stack on top of its sibling rather than under it.
    if (loaded or disabled or untracked) {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        var enabled = loaded;
        if (dvui.checkbox(@src(), &enabled, "Enabled", opts)) queueSetEnabled(entry.id, enabled);
    }
    // Per-plugin half of the update setting: whether this plugin is considered at all. *How* an
    // update lands once found (silently, or in the update window) is one app-wide choice, in
    // fizzy's own settings (`Settings.plugin_update_mode`).
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        var auto_update = app.isAutoUpdate(entry.id);
        if (dvui.checkbox(@src(), &auto_update, "Auto-update", opts))
            queueSetAutoUpdate(entry.id, auto_update);
    }
}

/// Detail-page header controls: the same actions a card carries, plus the two toggles inline —
/// the header has the width for them, and there is no card to hover there.
fn drawDetailControls(entry: StoreEntry) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1.0, .gravity_y = 0.5 });
    defer row.deinit();
    {
        var toggles = dvui.box(@src(), .{ .dir = .vertical }, .{ .gravity_y = 0.5, .margin = .{ .w = 8 } });
        defer toggles.deinit();
        drawToggleControls(entry, .normal);
    }
    drawCardControls(entry);
}

/// True when `entry` is genuinely present on disk in some form — loaded, disabled-on-disk,
/// sideloaded local, a failed/rejected build, or a protected bundled built-in. Mirrors the
/// "present on disk" condition `drawCardControls` uses to decide whether to show
/// enable/uninstall controls at all; `infoLine` reuses it so a plugin that was *never*
/// installed (or was uninstalled earlier this session, leaving only a stale `version_cache`
/// entry behind) never shows an "installed vX" it has no business showing.
fn isInstalled(entry: StoreEntry) bool {
    if (isBundled(entry.id)) return true;
    if (app.host.pluginById(entry.id) != null) return true;
    if (app.isDisabled(entry.id)) return true;
    if (entry.kind == .local or entry.kind == .disabled) return true;
    if (entry.kind == .failed or app.isFailed(entry.id)) return true;
    if (entry.kind == .on_disk or isOnDisk(entry.id)) return true;
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

    var parts: [4][]const u8 = undefined;
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
    // A build that is present but has never been run reads as installed-and-working otherwise;
    // say so, so the Load button beside it has a reason. Only for the never-decided case — a
    // plugin the user switched off deliberately doesn't need telling.
    if (!isBundled(entry.id) and app.host.pluginById(entry.id) == null and
        app.isUndecided(entry.id))
    {
        parts[n] = "not loaded";
        n += 1;
    }
    return joinParts(buf, parts[0..n]);
}

/// Compose the dim `id · store v{latest}` line for a store (upper-pane) card into `buf`. Unlike
/// `infoLine`, this never shows install state — the STORE tab is a pure "what does the store
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

/// The optimize class every published store build is produced in: the plugin release CI
/// (`fizzyedit/plugin-build-action`) always builds `-Doptimize=ReleaseFast`. A property of the
/// store, not of any one plugin.
const store_optimize_class = "fast";

/// False when this Fizzy is a `Debug`/`ReleaseSafe` build. Such a host folds the `"safe"`
/// optimize class into its `abi_fingerprint` (see `dylib.optimize_safety_class`), so it fetches a
/// shard URL the store never publishes under, and *every* plugin — including ones whose SDK
/// version matches this host exactly — reads "No compatible build in store". That message points
/// at the store, but the cause is entirely local and comptime-known, so say so instead. Same
/// condition the local load path reports as `error.AbiBuildEnvMismatch` ("SDK versions match, but
/// optimize mode does not match").
const host_optimize_matches_store = std.mem.eql(u8, dylib.optimize_safety_class, store_optimize_class);

/// Cap on the reported min width of the no-build message (same `max_size_content` trick as
/// `card_text_no_floor`, just with a usable floor instead of ~0). The message sits in the controls
/// column, which is *not* expand-horizontal: whatever it reports, it takes out of the info column
/// beside it. Left uncapped, a long message plus the icon reserved so much of a narrowed card that
/// the title/description — all of which report ~0 and yield — collapsed to nothing while the error
/// text alone stayed fully drawn. Capped, it ellipsizes (its tooltip carries the full text either
/// way) and the title keeps its own floor below.
const no_build_msg_max_w: f32 = 110;

/// The "nothing here to install" message, shown wherever no host-compatible release resolved —
/// identical in both panes (store card, installed card, detail header) so a card never changes
/// width just by which list it's in. Out-of-class hosts (see `host_optimize_matches_store`) get
/// the optimize-mode wording plus the same alert icon a failed local load carries; the tooltip
/// holds the long-form explanation in both cases.
fn drawNoStoreBuild(entry: StoreEntry, opts: dvui.Options) void {
    const theme = dvui.themeGet();

    var no_build_box = dvui.box(@src(), .{ .dir = .horizontal }, opts.override(.{ .gravity_y = 0.5 }));
    defer no_build_box.deinit();

    // Web has no plugin binaries at all, so the Debug/ReleaseSafe "Needs release" wording
    // would be a lie — same "No store build" the native ReleaseFast host shows.
    const optimize_mismatch = (comptime builtin.target.cpu.arch != .wasm32) and !host_optimize_matches_store;
    // The store *does* have this host's build — it just needs a newer Fizzy. Nothing about the
    // plugin is wrong, so point at the app update instead of at a missing build.
    const needs_newer_fizzy = !optimize_mismatch and releaseNeedsNewerFizzy(entry);

    if (optimize_mismatch or needs_newer_fizzy) {
        core.icon.icon(
            @src(),
            "StoreNoBuildAlertIcon",
            icons.tvg.lucide.@"circle-alert",
            .{ .stroke_color = .{ .color = theme.color(.err, .fill) }, .fill_color = .{ .color = theme.color(.err, .fill) } },
            .{ .gravity_y = 0.5, .margin = .{ .x = 2 }, .min_size_content = .{ .w = 14, .h = 14 } },
        );
    }

    dvui.labelNoFmt(
        @src(),
        if (optimize_mismatch) "Needs release" else if (needs_newer_fizzy) "Update Fizzy" else "No store build",
        .{},
        .{
            .color_text = .{ .color = theme.color(.err, .text) },
            .font = dvui.Font.theme(.mono),
            .gravity_y = 0.5,
            .max_size_content = .{ .w = no_build_msg_max_w, .h = std.math.floatMax(f32) },
        },
    );

    if (needs_newer_fizzy) {
        const rel = entry.release orelse store.ShardRelease{};
        dvui.tooltip(
            @src(),
            .{ .active_rect = no_build_box.data().borderRectScale().r },
            "The store build of this plugin (v{s}) needs Fizzy SDK {s} — this Fizzy is {d}.{d}.{d}. " ++
                "Update Fizzy (Help → Check for Updates) and it will install on the next run.",
            .{
                rel.version,
                rel.min_sdk_version,
                version.sdk_version.major,
                version.sdk_version.minor,
                version.sdk_version.patch,
            },
            .{},
        );
    } else if (!optimize_mismatch) {
        dvui.tooltip(
            @src(),
            .{ .active_rect = no_build_box.data().borderRectScale().r },
            "No compatible build in store (SDK {d}.{d}.{d} · ABI 0x{x} · {s})",
            .{ version.sdk_version.major, version.sdk_version.minor, version.sdk_version.patch, dylib.abi_fingerprint, compat.hostKey() },
            .{},
        );
    } else {
        dvui.tooltip(
            @src(),
            .{ .active_rect = no_build_box.data().borderRectScale().r },
            "This Fizzy is a {s} build. Store plugins are published ReleaseFast only, so the " ++
                "optimize mode does not match even when the SDK version does. Run zig build run -Doptimize=ReleaseFast, or build the plugin from source in {s}. " ++
                "(SDK {d}.{d}.{d} · ABI 0x{x} · {s})",
            .{
                @tagName(builtin.mode),
                @tagName(builtin.mode),
                version.sdk_version.major,
                version.sdk_version.minor,
                version.sdk_version.patch,
                dylib.abi_fingerprint,
                compat.hostKey(),
            },
            .{},
        );
    }
}

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

/// True when this host's SDK satisfies `rel`'s `min_sdk_version` — i.e. `PluginLoader` will
/// actually accept the build rather than rejecting it with `error.SdkVersionMismatch`.
///
/// Being in this host's fingerprint shard is not sufficient. `sdk_version` bumps for every
/// boundary change; the structural fingerprint only moves for those that change the *shape* of
/// the SDK types, so an SDK release that adds a host function (or tightens a behavior contract)
/// leaves the fingerprint alone. A plugin rebuilt against that SDK therefore lands in the exact
/// shard an older Fizzy fetches, looks like a plain version bump, and fails to load once
/// downloaded. `min_sdk_version` is the field that carries the difference — this is where it is
/// checked, so an out-of-date Fizzy is never offered a build it cannot run.
fn releaseSdkSatisfied(rel: store.ShardRelease) bool {
    const min = rel.minSdk() orelse return true;
    return version.sdkVersionSatisfies(version.sdk_version, min);
}

/// The release that is compatible with this host, if `entry` has one in the fetched shard: it
/// must ship a binary for this `os-arch` *and* be loadable by this SDK version
/// (see `releaseSdkSatisfied`).
fn selectedRelease(entry: StoreEntry) ?store.ShardRelease {
    const r = entry.release orelse return null;
    if (r.downloadFor(compat.hostKey()) == null) return null;
    if (!releaseSdkSatisfied(r)) return null;
    return r;
}

/// True when the store *does* have this host's build of `entry` but it needs a newer Fizzy than
/// the one running. Distinguishes "the store has nothing for you" from "update Fizzy first",
/// which are very different things for the user to read (see `drawNoStoreBuild`).
fn releaseNeedsNewerFizzy(entry: StoreEntry) bool {
    const r = entry.release orelse return false;
    if (r.downloadFor(compat.hostKey()) == null) return false;
    return !releaseSdkSatisfied(r);
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
    const theme = dvui.themeGet();
    const muted = theme.color(.window, .text).opacity(0.7);

    var ctl = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1.0, .gravity_y = 0.5 });
    defer ctl.deinit();

    // An in-flight / failed install job preempts the normal controls.
    if (jobs.get(entry.id)) |job| switch (@as(JobStatus, @enumFromInt(job.status.load(.acquire)))) {
        .downloading => {
            dvui.labelNoFmt(@src(), if (job.is_update) "Updating…" else "Installing…", .{}, .{ .gravity_y = 0.5, .color_text = .{ .color = muted }, .font = dvui.Font.theme(.mono) });
            return;
        },
        .failed => {
            if (selectedRelease(entry)) |rel| {
                if (dvui.buttonIcon(@src(), "Retry", icons.tvg.lucide.@"rotate-ccw", .{}, .{ .stroke_color = .{ .color = theme.color(.err, .text) } }, .{ .gravity_y = 0.5 }))
                    startDownload(entry.id, rel, .{ .is_update = job.is_update });
            }
            return;
        },
        .downloaded => {}, // about to complete in tick(); fall through to installed controls
    };

    // Protected universal fallbacks: never disablable / uninstallable.
    if (isBundled(entry.id)) {
        dvui.labelNoFmt(@src(), "Built-in", .{}, .{ .gravity_y = 0.5, .color_text = .{ .color = muted }, .font = dvui.Font.theme(.mono) });
        return;
    }

    const loaded = app.host.pluginById(entry.id) != null;
    const disabled = app.isDisabled(entry.id);
    const failed = entry.kind == .failed or app.isFailed(entry.id);
    // On disk, never loaded, and nothing in memory describes it — a build dropped into
    // `plugins/<id>/` that fizzy has not classified yet (no `.plugins.<id>.enabled` on record, no
    // load attempt, no failure). `Editor.reconcileDiscoveredPlugins` normally promotes these to
    // `.disabled` (which carries the Enabled checkbox), but it runs off the watcher, so a card can
    // still be drawn in this state — it must offer a way *in*, not just Uninstall.
    const untracked = !loaded and !disabled and !failed and (entry.kind == .on_disk or isOnDisk(entry.id));
    // A build sitting in the plugins dir that isn't running: it failed to load (ABI/SDK mismatch,
    // etc.), or it is simply there with nothing in memory describing it. Either way it is on disk
    // like any installed plugin, so it must stay actionable (reinstall / uninstall) rather than
    // dead-ending at a bare "Failed" label — or, worse, at no card at all.
    const broken = failed or untracked;
    // On disk, never run, and nobody has decided about it: a local `zig build install` or a
    // hand-dropped build. `untracked` is the same situation a frame or two earlier, before the
    // watcher (or Refresh) classified it. This is an *offer*, not a fault, so it gets one primary
    // "Load" button instead of the broken-build repair controls — and loading it goes through the
    // same first-load path a store install does, file-association prompt included
    // (`Editor.setPluginEnabled`).
    const undecided = !loaded and !failed and (app.isUndecided(entry.id) or untracked);

    // Present on disk in some form: loaded, disabled-on-disk, sideloaded local, or a broken build.
    if (loaded or disabled or entry.kind == .local or entry.kind == .disabled or broken) {
        // Enabled / Auto-update are not here: on a list card they live in the hover flyout at the
        // card's right edge (`drawHoverToggles`), and on the detail page they sit beside these
        // buttons (`drawDetailControls`). Only actions — update, repair, uninstall — are inline
        // on a card, so a row of four controls can't crowd the text out of a narrow sidebar.
        // Replace with a host-compatible registry build, just before uninstall:
        //   * loaded & strictly newer → in-place Update (unload + reload);
        //   * broken/not loaded       → Reinstall: download this host's build fresh over the one
        //     on disk and load it. Nothing is loaded to unload, so route through the install path
        //     (is_update = false → `installAndLoadPlugin`, which re-enables the plugin, loads the
        //     freshly downloaded file and clears the failure record). This is the way out of a
        //     wrong-SDK build: `selectedRelease` only ever hands back a release this Fizzy's ABI
        //     fingerprint, os-arch and SDK version can all load — even when it carries the same
        //     version number as the broken one already on disk.
        if (loaded) {
            if (comptime builtin.target.cpu.arch == .wasm32) {
                if (updateRelease(entry)) |rel| {
                    if (rel.downloadFor(compat.hostKey())) |dl| {
                        if (dvui.button(@src(), "Update", .{}, .{ .gravity_y = 0.5, .margin = .{ .x = 4 } }))
                            applyWebUpdate(entry.id, dl.url);
                    }
                }
            } else if (updateRelease(entry)) |rel| {
                if (dvui.button(@src(), "Update", .{}, .{ .gravity_y = 0.5, .margin = .{ .x = 4 } }))
                    startDownload(entry.id, rel, .{ .is_update = true });
            }
        } else if (undecided) {
            if (dvui.button(@src(), "Load", .{}, .{ .gravity_y = 0.5, .margin = .{ .x = 4 } }))
                queueSetEnabled(entry.id, true);
        } else if (broken) {
            // A locally built plugin that lost its load has no registry release to reinstall
            // *from*, so Retry is the whole fix once the author rebuilds it in place: it re-runs
            // the load against whatever is on disk now and clears the failure record on success.
            if (failed) {
                if (dvui.button(@src(), "Retry", .{}, .{ .gravity_y = 0.5, .margin = .{ .x = 4 } }))
                    queueSetEnabled(entry.id, true);
            }
            if (selectedRelease(entry)) |rel| {
                if (dvui.button(@src(), "Reinstall", .{}, .{ .gravity_y = 0.5, .margin = .{ .x = 4 } }))
                    startDownload(entry.id, rel, .{ .is_update = false });
            } else if (!have_snapshot or untracked) {
                // No catalog yet (offline, or the first fetch is still running), so we genuinely
                // don't know whether a build exists — say nothing rather than claim there is none.
                // Uninstall below still works; the card gains a Reinstall once a snapshot lands.
                // An untracked build stays quiet too: its Enabled checkbox is the action here, and
                // "no store build" is irrelevant noise for something never installed from the store.
            } else {
                // No build for this host in the fetched shard, so there is nothing to reinstall
                // *from*. Say why (short form — this card also carries the wrapped failure text,
                // and the controls row shares its width with it) instead of leaving a lone trash
                // icon next to an unexplained "Failed to load".
                drawNoStoreBuild(entry, .{ .margin = .{ .x = 4 } });
            }
        }
        if (dvui.buttonIcon(@src(), "Uninstall", icons.tvg.lucide.@"trash-2", .{}, .{ .stroke_color = .{ .color = theme.color(.err, .text) } }, .{ .gravity_y = 0.5 }))
            queueUninstall(entry.id);
        return;
    }

    // Available in the store but not installed.
    if (selectedRelease(entry)) |rel| {
        if (dvui.buttonIcon(@src(), "Install", icons.tvg.lucide.@"arrow-down-to-line", .{}, .{ .stroke_color = .{ .color = theme.color(.control, .text) } }, .{ .gravity_y = 0.5 }))
            startDownload(entry.id, rel, .{ .is_update = false });
        return;
    }

    // Same "we couldn't ask" caveat as the broken branch above — an unfetched catalog is not
    // evidence of a missing build.
    if (!have_snapshot) return;

    // Registry row with no host-compatible release and nothing on disk: the *store* hasn't
    // published a build for this exact Fizzy version/arch yet — nothing the user can fix
    // locally (unlike a failed local build, handled above), so the wording and the tooltip
    // both point at "the store doesn't have one" rather than "rebuild your plugin".
    drawNoStoreBuild(entry, .{});
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
            dvui.labelNoFmt(@src(), if (job.is_update) "Updating…" else "Installing…", .{}, .{ .gravity_y = 0.5, .color_text = .{ .color = muted }, .font = dvui.Font.theme(.mono) });
            return;
        },
        .failed => {
            if (selectedRelease(entry)) |rel| {
                if (dvui.buttonIcon(@src(), "Retry", icons.tvg.lucide.@"rotate-ccw", .{}, .{ .stroke_color = .{ .color = theme.color(.err, .text) } }, .{ .gravity_y = 0.5 }))
                    startDownload(entry.id, rel, .{ .is_update = job.is_update });
            }
            return;
        },
        .downloaded => {}, // about to complete in tick(); fall through
    };

    if (selectedRelease(entry)) |rel| {
        if (dvui.buttonIcon(@src(), "Install", icons.tvg.lucide.@"arrow-down-to-line", .{}, .{ .stroke_color = .{ .color = theme.color(.control, .text) } }, .{ .gravity_y = 0.5 }))
            startDownload(entry.id, rel, .{ .is_update = false });
        return;
    }

    // Registry row with no host-compatible release: the *store* hasn't published a build for
    // this exact Fizzy version/arch yet.
    drawNoStoreBuild(entry, .{});
}

/// A repo URL plus an optional path within it to look under for `README.md` / `ICON.png`.
const RepoSource = struct {
    repo: []const u8,
    subpath: []const u8 = "",
};

/// The fizzy monorepo — source of truth for the bundled built-ins (workbench, text, markdown), whose
/// `README.md` / `ICON.png` live at `plugins/<id>/` rather than at a repo root.
const fizzy_repo_url = "https://github.com/fizzyedit/fizzy";

/// Where to fetch `entry`'s README and store icon from, regardless of whether it's a store plugin or a
/// built-in: the registry homepage (repo root) for anything with a store presence, or the
/// fizzy monorepo subdirectory for a bundled built-in. Sideloaded/local plugins with no
/// registry entry have no known repo, so this is null and the store shows "no README found".
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

/// `plugins/<id>` — only ever called for `isBundled` ids.
fn builtinSubpath(id: []const u8) []const u8 {
    if (std.mem.eql(u8, id, "workbench")) return "plugins/workbench";
    if (std.mem.eql(u8, id, "text")) return "plugins/text";
    if (std.mem.eql(u8, id, "markdown")) return "plugins/markdown";
    if (std.mem.eql(u8, id, "image")) return "plugins/image";
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
        .{ .stroke_color = .{ .color = dvui.themeGet().color(.control, .text) } },
        .{ .gravity_x = 1.0, .corners = .all(1000000) },
    )) {
        if (catalog) |*c| c.refresh();
        // Classify anything that appeared in the plugins dir since the last pass — same call the
        // file watcher makes, so Refresh is a manual stand-in for it on a platform (or a mount)
        // where the watcher never fired. It deliberately only *offers* a discovered build (it
        // becomes an undecided "Load" card); Refresh never loads or executes a plugin.
        if (comptime builtin.target.cpu.arch != .wasm32) app.reconcileDiscovered();
        refreshLocalInfo();
    }
}

fn removePendingForId(id: []const u8) void {
    var i: usize = 0;
    while (i < pending_actions.items.len) {
        const action = pending_actions.items[i];
        const matches = switch (action) {
            .set_enabled => |a| std.mem.eql(u8, a.id, id),
            .uninstall => |a| std.mem.eql(u8, a.id, id),
            // A different axis entirely: enabling or uninstalling a plugin must not silently
            // swallow a queued auto-update toggle for the same id.
            .set_auto_update => false,
        };
        if (matches) {
            switch (action) {
                .set_enabled => |a| app.gpa.free(a.id),
                .uninstall => |a| app.gpa.free(a.id),
                .set_auto_update => unreachable,
            }
            _ = pending_actions.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

/// Queue an enable/disable request for `id`, applied on the next `tick()` (see the
/// `PendingAction`/`pending_actions` doc comment above). Exposed so `PluginSettingsPane`'s
/// disabled-plugin "Enabled" checkbox can reuse the exact same deferred-apply path the store
/// tab's own checkbox uses, rather than calling `Editor.setPluginEnabled` directly while a
/// settings-pane draw pass may itself be iterating Host registries.
pub fn queueSetEnabled(id: []const u8, enabled: bool) void {
    removePendingForId(id);
    const dup = app.gpa.dupe(u8, id) catch {
        reportError("'{s}' could not be queued", .{id});
        return;
    };
    pending_actions.append(app.gpa, .{ .set_enabled = .{ .id = dup, .enabled = enabled } }) catch {
        app.gpa.free(dup);
        reportError("'{s}' could not be queued", .{id});
    };
}

/// Queue an auto-update opt in/out for `id`. Deliberately does **not** clear other queued actions
/// for the same id (see `removePendingForId`) — it changes nothing about the plugin's load state.
fn queueSetAutoUpdate(id: []const u8, on: bool) void {
    const dup = app.gpa.dupe(u8, id) catch {
        reportError("'{s}' could not be queued", .{id});
        return;
    };
    pending_actions.append(app.gpa, .{ .set_auto_update = .{ .id = dup, .on = on } }) catch {
        app.gpa.free(dup);
        reportError("'{s}' could not be queued", .{id});
    };
}

fn queueUninstall(id: []const u8) void {
    removePendingForId(id);
    const dup = app.gpa.dupe(u8, id) catch {
        reportError("'{s}' could not be queued", .{id});
        return;
    };
    pending_actions.append(app.gpa, .{ .uninstall = .{ .id = dup } }) catch {
        app.gpa.free(dup);
        reportError("'{s}' could not be queued", .{id});
    };
}

/// Apply what the store's buttons queued. Both targets: the actions are the manager's, and the
/// manager is what differs between them.
fn applyPendingActions() void {
    // Anything applied here can add to, remove from, or change the load state of the plugins
    // directory, so the next draw rescans it (see `disk_scan_dirty`).
    if (pending_actions.items.len > 0) disk_scan_dirty = true;
    for (pending_actions.items) |action| switch (action) {
        .set_enabled => |a| {
            applySetEnabled(a.id, a.enabled);
            app.gpa.free(a.id);
        },
        .set_auto_update => |a| {
            app.setAutoUpdate(a.id, a.on) catch |err|
                reportError("could not change auto-update for '{s}': {s}", .{ a.id, @errorName(err) });
            app.gpa.free(a.id);
        },
        .uninstall => |a| {
            applyUninstall(a.id);
            app.gpa.free(a.id);
        },
    };
    pending_actions.clearRetainingCapacity();
}

fn applySetEnabled(id: []const u8, enabled: bool) void {
    app.setEnabled(id, enabled, false) catch |err| switch (err) {
        error.DirtyDocuments => reportError("'{s}' has unsaved changes — save or close them first", .{id}),
        else => reportError("'{s}' could not be {s}: {s}", .{ id, if (enabled) "enabled" else "disabled", @errorName(err) }),
    };
}

fn applyUninstall(id: []const u8) void {
    app.uninstall(id, false) catch |err| switch (err) {
        error.DirtyDocuments => reportError("'{s}' has unsaved changes — save or close them first", .{id}),
        else => reportError("'{s}' could not be uninstalled: {s}", .{ id, @errorName(err) }),
    };
}
