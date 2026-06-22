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
    pub fn select(_: []const u8, _: []const u8) void {}
    pub fn selectedId() ?[]const u8 {
        return null;
    }
    pub fn draw() void {}
    pub fn clear() void {}
    pub fn deinit() void {}
} else @import("readme.zig");

pub const view_id = "shell.store";
/// Center provider that renders the selected plugin's README. Mirrors the way the workbench
/// center renders the active document: while the store tab is active and a plugin is selected,
/// `tick` swaps the active center to this provider; deselecting (or leaving the tab) restores
/// the previous center.
pub const readme_center_id = "shell.store.readme";
const default_registry_url = "https://plugins.fizzyed.it/index.json";

/// True while we have hijacked the active center to show a README, plus the center id to restore
/// when the selection is cleared or the store tab is no longer active.
var readme_center_active = false;
var saved_center: ?[]const u8 = null;

var catalog: ?store.Catalog = null;
var registry_url_owned: ?[]u8 = null;
var first_draw_done = false;

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

/// Query the real display name of every disabled plugin straight from its on-disk dylib (via the
/// `fizzy_plugin_name` export — no register), seeding `name_cache`. This covers plugins that were
/// disabled *before* they were ever loaded this session, so a disabled card shows its true name
/// (and keeps its A→Z position) without a fragile on-disk name cache. Cheap and bounded: only runs
/// on first draw / Refresh, and only probes ids whose name we don't already know.
fn probeDisabledNames() void {
    const editor = fizzy.editor;
    const a = fizzy.app.allocator;
    const plugins_dir = std.fs.path.join(a, &.{ editor.config_folder, "plugins" }) catch return;
    defer a.free(plugins_dir);

    for (editor.disabled_plugin_ids.items) |id| {
        if (!std.unicode.utf8ValidateSlice(id)) continue;
        if (name_cache.get(id) != null) continue; // already known (loaded / registry / prior probe)
        if (editor.host.pluginById(id) != null) continue; // loaded → name comes from the live plugin
        const file_name = PluginLoader.pluginFilename(id, a) catch continue;
        defer a.free(file_name);
        const path = std.fs.path.join(a, &.{ plugins_dir, file_name }) catch continue;
        defer a.free(path);
        if (PluginLoader.probeName(a, path)) |name| {
            defer a.free(name);
            rememberName(id, name);
        }
    }
}

pub fn register(host: *sdk.Host) !void {
    if (comptime builtin.target.cpu.arch == .wasm32) return; // no dylib loading on web
    const url = resolveRegistryUrl();
    catalog = store.Catalog.init(fizzy.app.allocator, dvui.io, url);
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

/// `FIZZY_PLUGIN_REGISTRY_URL` overrides the default (used for local E2E testing). Owned for the
/// process lifetime (freed in `deinit`).
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
    Readme.deinit();
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
                const loaded = if (job.is_update)
                    fizzy.editor.updatePlugin(job.id, true)
                else
                    fizzy.editor.installAndLoadPlugin(job.id);
                loaded catch |err| {
                    setStatus("'{s}' failed to load: {s}", .{ job.id, @errorName(err) });
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
    Readme.select(entry.id, repoUrl(entry) orelse "");
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
fn startDownload(id: []const u8, release: store.Release, is_update: bool) void {
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

fn isBundled(id: []const u8) bool {
    return std.mem.eql(u8, id, "workbench") or std.mem.eql(u8, id, "text");
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
    registry: ?store.PluginEntry = null,
    plugin: ?*sdk.Plugin = null,
    failed_reason: []const u8 = "",
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
    var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
    defer vbox.deinit();

    // First time the tab is shown, fetch the registry and learn disabled plugins' real names.
    if (!first_draw_done) {
        first_draw_done = true;
        if (catalog) |*c| c.refresh();
        probeDisabledNames();
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
    const maybe_index = cat.acquire();
    defer cat.release();

    // Build one deduped, A→Z model under the catalog lock, into the per-frame dvui arena.
    const arena = dvui.currentWindow().arena();
    var entries: std.ArrayListUnmanaged(StoreEntry) = .empty;

    const editor = fizzy.editor;

    // Precedence — one row per id: registry > loaded/local > disabled > failed. A registry row
    // already reflects loaded/disabled/available/needs-rebuild for its id, so it is the richest
    // representation whenever an id is published.
    if (maybe_index) |index| {
        for (index.plugins) |entry| {
            rememberName(entry.id, entry.name);
            entries.append(arena, .{
                .id = entry.id,
                .title = if (entry.name.len > 0) entry.name else resolveTitle(entry.id, entry.id),
                .kind = .registry,
                .registry = entry,
            }) catch {};
        }
    }
    // Locally-present plugins the registry doesn't list: bundled built-ins + sideloaded dylibs.
    for (editor.host.plugins.items) |plugin| {
        rememberName(plugin.id, plugin.display_name);
        if (containsId(entries.items, plugin.id)) continue;
        entries.append(arena, .{
            .id = plugin.id,
            .title = plugin.display_name,
            .kind = .local,
            .plugin = plugin,
        }) catch {};
    }
    // Disabled plugins are unloaded (not in `host.plugins`) but remain on disk; reuse the name we
    // remembered while they were loaded so they keep their A→Z position across enable/disable.
    for (editor.disabled_plugin_ids.items) |id| {
        if (!std.unicode.utf8ValidateSlice(id)) continue;
        if (editor.host.pluginById(id) != null) continue;
        if (containsId(entries.items, id)) continue;
        entries.append(arena, .{ .id = id, .title = resolveTitle(id, id), .kind = .disabled }) catch {};
    }
    // Load failures (folded into the same dedup pass so an id never renders twice).
    for (editor.failed_user_plugins.items) |f| {
        if (containsId(entries.items, f.id)) continue;
        entries.append(arena, .{ .id = f.id, .title = resolveTitle(f.id, f.id), .kind = .failed, .failed_reason = f.reason }) catch {};
    }

    std.sort.pdq(StoreEntry, entries.items, {}, entryLess);

    // Surface a registry-fetch problem above the list (local plugins still render below it).
    if (maybe_index == null) switch (cat.status()) {
        .fetching => dvui.labelNoFmt(@src(), "Fetching plugin registry…", .{}, .{ .margin = .{ .y = 8 } }),
        .failed => dvui.labelNoFmt(@src(), "Could not reach the plugin registry.", .{}, .{
            .margin = .{ .y = 8 },
            .color_text = dvui.themeGet().color(.err, .text),
        }),
        else => {},
    };

    // Flat A→Z card list. Selecting a card (clicking anywhere outside its controls) shows that
    // plugin's README in the center pane — see `syncReadmeCenter`/`drawReadmeCenter`.
    var shown: usize = 0;
    for (entries.items) |entry| {
        if (!matchesFilter(entry, filter_text)) continue;
        shown += 1;
        drawCard(entry);
    }

    if (shown == 0) {
        if (filter_text.len > 0) {
            dvui.labelNoFmt(@src(), "No plugins match the filter.", .{}, .{ .margin = .{ .y = 8 } });
        } else if (maybe_index != null) {
            dvui.labelNoFmt(@src(), "No plugins available.", .{}, .{ .margin = .{ .y = 8 } });
        }
    }
}

/// One flat store card: a clickable container (logo + info + state controls). Clicking anywhere
/// outside the controls selects the plugin (its README shows in the center). The controls consume
/// their own clicks so the card-level click never double-fires.
fn drawCard(entry: StoreEntry) void {
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
        .corner_radius = dvui.Rect.all(8),
        .background = true,
        .color_fill = fill,
        .color_fill_hover = theme.color(.control, .fill).opacity(0.5),
        .color_fill_press = theme.color(.control, .fill_press),
        .box_shadow = .{
            .color = .black,
            .corner_radius = dvui.Rect.all(8),
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

        // 1. Logo (gravity 0). Generic placeholder for now; real logos land in Phase META.
        dvui.icon(
            @src(),
            "PluginLogo",
            icons.tvg.lucide.package,
            .{ .stroke_color = theme.color(.window, .text) },
            .{ .gravity_y = 0.5, .min_size_content = .{ .w = 32, .h = 32 } },
        );

        // 2. Info column: large title + dim monospace "id · version · date" subtitle.
        {
            var info = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .horizontal,
                .gravity_y = 0.5,
                .margin = .{ .x = 8 },
            });
            defer info.deinit();

            dvui.labelNoFmt(@src(), entry.title, .{}, .{ .font = dvui.Font.theme(.title) });

            var sub_buf: [192]u8 = undefined;
            dvui.labelNoFmt(@src(), subtitle(&sub_buf, entry), .{}, .{
                .font = dvui.Font.theme(.mono),
                .color_text = theme.color(.window, .text).opacity(0.65),
            });
        }

        // 3. State controls, right-justified. These run their own processEvents (inside
        // `drawCardControls`) and consume their clicks before the card does.
        drawCardControls(entry);
    }

    // Now claim the card-body click — `dvui.clicked` skips events a control already handled.
    bw.processEvents();
    if (bw.clicked()) toggleSelect(entry);
}

/// Compose the dim subtitle `id · version · date` into `buf`, skipping parts we don't have.
/// `version` prefers the loaded plugin's version, then the selected registry release's version;
/// `date` is the selected release's publish date.
fn subtitle(buf: []u8, entry: StoreEntry) []const u8 {
    var ver_buf: [32]u8 = undefined;
    const ver: ?[]const u8 = blk: {
        if (installedVersion(entry.id)) |v|
            break :blk std.fmt.bufPrint(&ver_buf, "v{d}.{d}.{d}", .{ v.major, v.minor, v.patch }) catch null;
        if (selectedRelease(entry)) |rel|
            break :blk std.fmt.bufPrint(&ver_buf, "v{s}", .{rel.version}) catch null;
        break :blk null;
    };
    const date: ?[]const u8 = if (selectedRelease(entry)) |rel|
        (if (rel.published.len > 0) rel.published else null)
    else
        null;

    if (ver) |vv| {
        if (date) |dd|
            return std.fmt.bufPrint(buf, "{s} · {s} · {s}", .{ entry.id, vv, dd }) catch entry.id;
        return std.fmt.bufPrint(buf, "{s} · {s}", .{ entry.id, vv }) catch entry.id;
    }
    if (date) |dd|
        return std.fmt.bufPrint(buf, "{s} · {s}", .{ entry.id, dd }) catch entry.id;
    return entry.id;
}

/// The registry release that is compatible with this host, if `entry` has a registry row.
fn selectedRelease(entry: StoreEntry) ?store.Release {
    const r = entry.registry orelse return null;
    return compat.selectRelease(r, dylib.abi_fingerprint, compat.hostKey());
}

/// The compatible registry release when it is a *newer* version than the one currently loaded —
/// i.e. an update is available. Returns null when the plugin isn't loaded (we only know a live
/// plugin's version), has no host-compatible release, or is already up to date.
fn updateRelease(entry: StoreEntry) ?store.Release {
    const installed = installedVersion(entry.id) orelse return null;
    const rel = selectedRelease(entry) orelse return null;
    const rel_ver = std.SemanticVersion.parse(rel.version) catch return null;
    return if (rel_ver.order(installed) == .gt) rel else null;
}

/// Right-justified controls whose shape depends on install state (see plan Phase 1R-c):
///   * available in store → a single install button (down-to-line arrow);
///   * installed → an Enabled checkbox + a trash uninstall button;
///   * protected bundled fallback (text/workbench) → no controls;
///   * static built-in (example) → just the Enabled checkbox (nothing to uninstall).
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
                    startDownload(entry.id, rel, false);
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

    // Static built-ins (example): toggle a hidden sidebar view; no dylib to uninstall.
    if (fizzy.Editor.isStaticHidePlugin(entry.id)) {
        var enabled = !disabled;
        if (dvui.checkbox(@src(), &enabled, "Enabled", .{ .gravity_y = 0.5 })) queueSetEnabled(entry.id, enabled);
        return;
    }

    // Installed (loaded dylib, or disabled-on-disk, or a sideloaded local): disable switch + trash.
    if (loaded or disabled or entry.kind == .local or entry.kind == .disabled) {
        var enabled = !disabled;
        if (dvui.checkbox(@src(), &enabled, "Enabled", .{ .gravity_y = 0.5 })) queueSetEnabled(entry.id, enabled);
        // A newer compatible release than the loaded version → offer an in-place update, placed
        // just before the uninstall button.
        if (updateRelease(entry)) |rel| {
            if (dvui.button(@src(), "Update", .{}, .{ .gravity_y = 0.5, .margin = .{ .x = 4 } }))
                startDownload(entry.id, rel, true);
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

    // Registry row with no host-compatible release, or a load failure.
    const msg: []const u8 = if (entry.kind == .failed) "Failed" else "Needs rebuild";
    dvui.labelNoFmt(@src(), msg, .{}, .{ .gravity_y = 0.5, .color_text = theme.color(.err, .text), .font = dvui.Font.theme(.mono) });
}

/// Best-effort repository URL for a store entry (registry homepage for now). Built-in / sideloaded
/// plugins gain a `repository` field with the Phase 4a manifest bump.
fn repoUrl(entry: StoreEntry) ?[]const u8 {
    if (entry.registry) |r| {
        if (r.homepage.len > 0) return r.homepage;
    }
    return null;
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

    if (dvui.button(@src(), "Refresh", .{}, .{ .gravity_x = 1.0 })) {
        status_len = 0;
        if (catalog) |*c| c.refresh();
        probeDisabledNames();
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
