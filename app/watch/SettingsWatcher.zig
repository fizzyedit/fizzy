//! Watches `<config>/` (recursive) for external changes while fizzy is running — see
//! docs/PLUGIN_MANIFEST_PLAN.md R11/R12.
//!
//! Thin adapter over [`neurocyte/nightwatch`](https://github.com/neurocyte/nightwatch): one
//! recursive `watch(config_folder)` covers `settings.zon` reconciliation, discovery of
//! newly-created plugin directories under `plugins/`, and hot-reload of a plugin whose dylib was
//! rebuilt in place (`Editor.reconcileChangedPluginBinaries`). Nightwatch owns the thread; this
//! layer only implements its `Handler` (atomic flag + `backend.refresh()`, never file content /
//! `dvui.io` / a shared allocator from the callback) and a ~200ms coalesce on the main thread
//! via `tick`.
//!
//! `have_impl` is false on wasm and any unsupported OS — the watcher is simply not started
//! there (same "no filesystem" degrade-gracefully spirit as every other native-only guard in
//! this codebase), not a hard error.
const builtin = @import("builtin");
const std = @import("std");
const core = @import("core");
const sdk = @import("fizzy_sdk");
const wake = @import("wake.zig");
const dvui = @import("dvui");
const Allocator = std.mem.Allocator;

const SettingsWatcher = @This();

/// How long to keep coalescing further events before reacting, once the first one arrives.
/// A single logical save is often several raw filesystem events; this also gives a half-written
/// file a moment to finish before `Editor.reconcileExternalSettingsChange` reads it.
const debounce_ns: i128 = 200 * std.time.ns_per_ms;

pub const have_impl = switch (builtin.os.tag) {
    .macos, .linux, .windows => true,
    else => false,
};

gpa: Allocator,
/// Owned copy of the watched config folder path.
config_folder: []const u8,
/// Nightwatch handler + instance — only meaningful when `have_impl`. Stored as opaque
/// optional so this file still type-checks on wasm (where nightwatch isn't linked).
impl: if (have_impl) Impl else void = if (have_impl) .{} else {},
/// Set by nightwatch's handler thread; consumed/extended by `tick` on the main thread.
raw_dirty: std.atomic.Value(bool) = .init(false),
/// Main-thread coalesce deadline (`perf.nanoTimestamp()`); 0 = nothing pending.
coalesce_deadline_ns: i128 = 0,

const Impl = if (have_impl) struct {
    const nightwatch = @import("nightwatch");
    /// `Default.Handler` — nightwatch's root module doesn't re-export `types.Handler` directly.
    const Handler = nightwatch.Default.Handler;

    handler: Handler = .{ .vtable = &vtable },
    nw: ?nightwatch.Default = null,
    /// Set in `start` once `SettingsWatcher` is at its final address — avoids a
    /// `@fieldParentPtr` alignment dance from the nested `impl` field.
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

/// Sets up bookkeeping but does **not** start nightwatch yet — see `start`'s doc comment.
/// `config_folder` is copied; caller retains ownership of the passed slice.
pub fn init(gpa: Allocator, config_folder: []const u8) !SettingsWatcher {
    if (comptime !have_impl) return error.Unsupported;
    const folder = try gpa.dupe(u8, config_folder);
    errdefer gpa.free(folder);
    return .{
        .gpa = gpa,
        .config_folder = folder,
    };
}

/// Starts nightwatch and registers a recursive watch on `config_folder`. Must be called only
/// once `self` is at its **final** address — nightwatch retains `&self.impl.handler` for the
/// watcher's lifetime, so calling this before `self` is copied into `editor.settings_watcher`
/// would leave it pointing at stack memory. Mirrors why `Editor.postInit` exists separately
/// from `Editor.init` — call this from `postInit`, not `init`.
pub fn start(self: *SettingsWatcher) !void {
    if (comptime have_impl) {
        const nightwatch = @import("nightwatch");
        self.impl.raw_dirty = &self.raw_dirty;
        var nw = try nightwatch.Default.init(dvui.io, self.gpa, &self.impl.handler);
        errdefer nw.deinit();
        try nw.watch(self.config_folder);
        self.impl.nw = nw;
    } else {
        return error.Unsupported;
    }
}

/// Stops nightwatch (joins its background thread) and frees owned paths. Safe to call even if
/// `start` was never called (e.g. `init` succeeded but `start` failed).
pub fn stop(self: *SettingsWatcher) void {
    if (comptime have_impl) {
        if (self.impl.nw) |*nw| {
            nw.deinit();
            self.impl.nw = null;
        }
    }
    self.gpa.free(self.config_folder);
}

/// What the application reconciles when this tree settles.
///
/// One callback, not four: the watcher knows that something under the config folder changed and
/// nothing more. Which passes that implies — re-read the settings file, notice a rebuilt plugin
/// dylib, notice a newly dropped-in one — is the application's business, and fizzy's order
/// between them is fizzy's reasoning (see `Editor.configChanged`).
pub const Sink = struct {
    ctx: *anyopaque,
    changed: *const fn (ctx: *anyopaque) void,
};

/// Call once per frame. Cheap no-op unless the watcher thread actually saw a change. Coalesces
/// a burst of raw events (~200ms) on the main thread before reconciling.
pub fn tick(self: *SettingsWatcher, sink: Sink) void {
    const now = core.perf.nanoTimestamp();
    if (self.raw_dirty.swap(false, .acquire)) {
        self.coalesce_deadline_ns = now + debounce_ns;
    }
    if (self.coalesce_deadline_ns == 0) return;
    if (now < self.coalesce_deadline_ns) {
        // Keep the event loop alive until the coalesce window settles.
        wake.now();
        return;
    }
    self.coalesce_deadline_ns = 0;
    sink.changed(sink.ctx);
}
