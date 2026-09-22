//! What the plugin store needs from the application hosting it.
//!
//! The store — registry catalog, install/update jobs, the store pane — is framework an app
//! either switches on or leaves out, exactly like watching and installers. It was reaching
//! `fizzy.editor()` in sixty-odd places, which made "any fizzy app gets a plugin store" false:
//! the code was fizzy's, not the framework's.
//!
//! This is the seam. An application fills one of these in once at startup and the store talks to
//! nothing else — no `Editor`, no fizzy globals. The store is compiled *into* an app and never
//! into a dylib, so this is a plain `{ctx, vtable}` pair with no ABI implications; it is here
//! because the store has one host per process, not because anything crosses a boundary.
//!
//! Everything on it is genuinely the app's: which plugins the user disabled, which failed to
//! load, where they are installed, and what happens when one is installed or removed. The store
//! decides none of that — it draws it and asks.
const std = @import("std");
const sdk = @import("fizzy_sdk");
/// Via `app.zig` so this picks up the wasm stub on a web build: `LoadedLib` holds a `DynLib`,
/// which does not exist there.
const PluginLoader = @import("../root.zig").store.Loader;

const PluginManager = @This();

/// A plugin whose dylib is on disk but was refused at load. The store shows these as rows so a
/// broken build is visible rather than silently absent.
pub const Failure = struct {
    id: []const u8,
    reason: []const u8,
    detail: ?[]const u8 = null,
    plugin_version: ?std.SemanticVersion = null,
};

/// How the app applies available updates. The store reads it; where it is stored — a settings
/// file, a flag, nowhere — is the app's business.
pub const UpdateMode = enum {
    /// Collect them and let the user apply them.
    prompt,
    /// Download and apply with no interaction.
    silent,
};

/// The application hosting the store, set once at registration.
///
/// A single mutable global rather than a parameter threaded through forty draw functions: there
/// is exactly one store per process, and the store's own state (catalog, icon cache, job queue)
/// is module-level for the same reason. `PluginStore.register` sets it before anything reads it.
pub var current: PluginManager = undefined;

ctx: *anyopaque,
/// The registries the store draws from and writes to.
host: *sdk.Host,
/// Long-lived allocations (catalog, icons, job queues).
gpa: std.mem.Allocator,
/// Where this app keeps its config; `plugins/` under it is the install directory.
config_folder: []const u8,
/// Where this app's plugin registry lives. `plugins.yourapp.com` is a config value, not a
/// fork — the store is the same code pointed somewhere else.
registry_url: []const u8,
/// The running executable's path, for the dev-tree asset fallback (`plugin_repo_asset.zig`
/// walks up from here looking for a sibling checkout before it reaches for the network).
root_path: []const u8,

vtable: *const VTable,

/// Whether an update to the *application itself* is in flight. Plugin builds are made against
/// one SDK generation, so the builds that pair with a newer app only become visible once it is
/// running — the store waits rather than offering the older ones.
pub const AppUpdate = enum {
    /// The launch check has not answered yet.
    checking,
    /// A newer application exists, or is installing.
    pending,
    /// Nothing waiting — go ahead.
    none,
};

pub const VTable = struct {
    // ---- decisions the app persists -------------------------------------------------------
    isDisabled: *const fn (ctx: *anyopaque, id: []const u8) bool,
    isUndecided: *const fn (ctx: *anyopaque, id: []const u8) bool,
    isAutoUpdate: *const fn (ctx: *anyopaque, id: []const u8) bool,
    setAutoUpdate: *const fn (ctx: *anyopaque, id: []const u8, on: bool) anyerror!void,
    updateMode: *const fn (ctx: *anyopaque) UpdateMode,
    /// Ids the user switched off. They have no live `Plugin`, so the store cannot find them any
    /// other way, and it must still list them.
    disabledIds: *const fn (ctx: *anyopaque) []const []const u8,

    // ---- load state ------------------------------------------------------------------------
    loadedLibs: *const fn (ctx: *anyopaque) []const PluginLoader.LoadedLib,
    failures: *const fn (ctx: *anyopaque) []const Failure,
    /// Identity for a plugin compiled into the binary, which has no `plugin.zig.zon` on disk.
    /// Null for an app that bundles none.
    builtinManifest: *const fn (ctx: *anyopaque, id: []const u8) ?sdk.Manifest,

    // ---- actions ---------------------------------------------------------------------------
    install: *const fn (ctx: *anyopaque, id: []const u8) anyerror!void,
    /// The web's install: fetch and link a plugin's wasm side module straight from its release
    /// URL (there is no plugins directory to download into). Null for an app that does not
    /// load web plugins.
    installFromUrl: ?*const fn (ctx: *anyopaque, id: []const u8, url: []const u8) anyerror!void = null,
    /// The web's update: link the build at `url` alongside the running one and hand the id over,
    /// within the session. Null for an app that does not load web plugins.
    updateFromUrl: ?*const fn (ctx: *anyopaque, id: []const u8, url: []const u8) anyerror!void = null,
    update: *const fn (ctx: *anyopaque, id: []const u8, force: bool) anyerror!void,
    uninstall: *const fn (ctx: *anyopaque, id: []const u8, force: bool) anyerror!void,
    setEnabled: *const fn (ctx: *anyopaque, id: []const u8, enabled: bool, force: bool) anyerror!void,
    /// Re-read the install directory after the store changed it.
    reconcileDiscovered: *const fn (ctx: *anyopaque) void,
    /// See `AppUpdate`. An app with no self-updater returns `.none`.
    appUpdate: *const fn (ctx: *anyopaque) AppUpdate,
    /// Tell the user updates are waiting, however this app does that — fizzy opens its "Plugin
    /// updates" window. The store has already collected them (`pendingUpdates`); this is only
    /// the invitation, and doing nothing is a valid answer for an app that applies silently.
    offerUpdates: *const fn (ctx: *anyopaque) void,
    /// Bring the main region into view — on a narrow layout the store's README page is drawn
    /// somewhere the user cannot see yet. A no-op is a perfectly good implementation.
    revealMain: *const fn (ctx: *anyopaque) void,
};

pub fn isDisabled(self: PluginManager, id: []const u8) bool {
    return self.vtable.isDisabled(self.ctx, id);
}
pub fn isUndecided(self: PluginManager, id: []const u8) bool {
    return self.vtable.isUndecided(self.ctx, id);
}
pub fn isAutoUpdate(self: PluginManager, id: []const u8) bool {
    return self.vtable.isAutoUpdate(self.ctx, id);
}
pub fn setAutoUpdate(self: PluginManager, id: []const u8, on: bool) anyerror!void {
    return self.vtable.setAutoUpdate(self.ctx, id, on);
}
pub fn updateMode(self: PluginManager) UpdateMode {
    return self.vtable.updateMode(self.ctx);
}
pub fn disabledIds(self: PluginManager) []const []const u8 {
    return self.vtable.disabledIds(self.ctx);
}
pub fn loadedLibs(self: PluginManager) []const PluginLoader.LoadedLib {
    return self.vtable.loadedLibs(self.ctx);
}
pub fn failures(self: PluginManager) []const Failure {
    return self.vtable.failures(self.ctx);
}
pub fn builtinManifest(self: PluginManager, id: []const u8) ?sdk.Manifest {
    return self.vtable.builtinManifest(self.ctx, id);
}
pub fn install(self: PluginManager, id: []const u8) anyerror!void {
    return self.vtable.install(self.ctx, id);
}
pub fn installFromUrl(self: PluginManager, id: []const u8, url: []const u8) anyerror!void {
    const f = self.vtable.installFromUrl orelse return error.Unsupported;
    return f(self.ctx, id, url);
}
pub fn updateFromUrl(self: PluginManager, id: []const u8, url: []const u8) anyerror!void {
    const f = self.vtable.updateFromUrl orelse return error.Unsupported;
    return f(self.ctx, id, url);
}
pub fn update(self: PluginManager, id: []const u8, force: bool) anyerror!void {
    return self.vtable.update(self.ctx, id, force);
}
pub fn uninstall(self: PluginManager, id: []const u8, force: bool) anyerror!void {
    return self.vtable.uninstall(self.ctx, id, force);
}
pub fn setEnabled(self: PluginManager, id: []const u8, enabled: bool, force: bool) anyerror!void {
    return self.vtable.setEnabled(self.ctx, id, enabled, force);
}
pub fn reconcileDiscovered(self: PluginManager) void {
    self.vtable.reconcileDiscovered(self.ctx);
}
pub fn appUpdate(self: PluginManager) AppUpdate {
    return self.vtable.appUpdate(self.ctx);
}
pub fn offerUpdates(self: PluginManager) void {
    self.vtable.offerUpdates(self.ctx);
}
pub fn revealMain(self: PluginManager) void {
    self.vtable.revealMain(self.ctx);
}

/// True when `id` has a dylib on disk that was refused at load.
pub fn isFailed(self: PluginManager, id: []const u8) bool {
    return self.failure(id) != null;
}

/// The recorded load failure for `id`, if any.
pub fn failure(self: PluginManager, id: []const u8) ?Failure {
    for (self.failures()) |f| {
        if (std.mem.eql(u8, f.id, id)) return f;
    }
    return null;
}
