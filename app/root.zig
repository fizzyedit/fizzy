//! `app` — framework an application switches on, as opposed to `core` (what an app and a plugin
//! both draw with) and `sdk` (the contract a plugin is written against).
//!
//! The distinction is the dylib boundary, not taste: everything here is compiled into an
//! application and never into a plugin, so it may depend on things a plugin must never link —
//! the network, the filesystem, an installer, `dlopen` itself.
//!
//! What lives here is opt-in per app. Fizzy switches all of it on; a smaller app takes what it
//! wants and pays for nothing else.
//!
//!   `store`  the plugin store: registry catalog, install/update/uninstall, load-failure
//!            reporting, and the pane that draws all of it. Point it at your own registry with
//!            `AppInfo.registry_url` — `plugins.yourapp.com` is a config value, not a fork.
//!
//! **An app tells the store about itself once**, through `store.Manager` (see its file), and the
//! store then talks to nothing else — no `Editor`, no globals belonging to fizzy. That seam is
//! what makes this framework rather than fizzy's own source.
/// What makes an application *this* application rather than fizzy: its name, bundle id, config
/// directory, version, update feed and plugin registry. Every value arrives from the app's own
/// `build_opts`, so `AppInfo.current` is the identity of whichever app is being built.
pub const AppInfo = @import("AppInfo.zig");
/// The host runtime an application embeds — see the file.
pub const App = @import("App.zig");

/// User configuration on disk: `settings.zon` (the app's own record plus every plugin's
/// `.plugins.<id>` block), its migration from older layouts, and the shared settings-row chrome.
pub const settings = struct {
    pub const Settings = @import("settings/Settings.zig");
    pub const Migration = @import("settings/SettingsMigration.zig");
    pub const PluginsZon = @import("settings/SettingsPluginsZon.zig");
    pub const Row = @import("settings/SettingRow.zig");
    pub const PluginPane = @import("settings/PluginSettingsPane.zig");
};

/// Recently opened folders, persisted as `recents.zon`.
pub const Recents = @import("Recents.zig");

/// Key chords → command ids: the table, its ZON form, chord matching, and the dvui adapter.
pub const keymap = struct {
    pub const Keymap = @import("keymap/Keymap.zig");
    pub const key = @import("keymap/key.zig");
    pub const chord = @import("keymap/chord.zig");
    pub const zon = @import("keymap/zon.zig");
    pub const dvui_adapter = @import("keymap/dvui_adapter.zig");
};

/// Regions and the splits between them: the whole of how an application divides its window.
///
/// A minimal app is exactly this — regions laid out by dvui's boxes, a split where the user
/// should be able to drag one edge, and plugins drawing into whichever region accepts their
/// keywords. Nothing here knows what an explorer, a panel or a document is; fizzy's own shape
/// (`src/editor/layout.zig`) is ordinary code on top, and an app writes its own.
pub const layout = struct {
    pub const Layout = @import("layout/Layout.zig");
    pub const Region = @import("layout/Region.zig");
    pub const Seed = @import("layout/Seed.zig").Tree;
    /// One place in a static shape written as data, for `-Dapp-layout=<file>.zon` — a tree of
    /// them is the whole shape. See its own doc comment for what data can and cannot say.
    pub const Shape = @import("layout/Shape.zig");
    pub const Tree = @import("layout/Tree.zig");
    /// What persists between frames: declared regions, their extents, the user's keyword
    /// overrides. The application owns one; a `Layout` is per-frame and borrows it.
    pub const State = @import("layout/State.zig");
};

/// Watching the filesystem for changes the application should react to.
///
/// Opt-in: an app that does not want a folder watcher simply never starts one, and the cost is
/// zero. Each watcher's job ends at "this settled, off the watcher thread" — what is worth
/// reacting to, and what reacting means, is the app's, which is what `Sink` on each of them is.
pub const watch = struct {
    /// On-disk changes under the open project folder, coalesced and filtered by the app.
    pub const FolderWatcher = @import("watch/FolderWatcher.zig");
    /// Changes under the app's own config folder — its settings file, its plugin directory.
    pub const SettingsWatcher = @import("watch/SettingsWatcher.zig");
    /// How a watcher thread wakes a sleeping UI. Set once by the application.
    pub const wake = @import("watch/wake.zig");
};

/// Keeping the application up to date, and putting the new window where the old one was.
///
/// Both are opt-in and both are what an application wants rather than what a plugin does:
/// `update` is Velopack's install/update/uninstall lifecycle plus the toast that offers it,
/// `window` is the geometry an app saves so its next launch opens where the last one closed.
pub const update = struct {
    pub const auto_update = @import("update/auto_update.zig");
    pub const update_install = @import("update/update_install.zig");
    pub const update_notify = @import("update/update_notify.zig");
};

pub const window = struct {
    pub const layout = @import("window/window_layout.zig");
};

/// One application per machine, and a second launch handing its argv to the first.
///
/// The lock, the socket and the argv plumbing are the same for every app; what "open this path"
/// means is not, which is `singleton.Sink`. The app also sets its own `app_id` — the lock is per
/// application, and two fizzy-based apps must not fight over one.
pub const single_instance = @import("single_instance/singleton.zig");

pub const store = struct {
    pub const Store = @import("store/PluginStore.zig");
    pub const Manager = @import("store/PluginManager.zig");
    /// Runtime plugin loading: `dlopen` natively; on the web a wasm side module the page links
    /// into its function table (`PluginLoader_web.zig`). Same `LoadedLib` read-shape on both.
    pub const Loader = if (@import("builtin").target.cpu.arch == .wasm32)
        @import("store/PluginLoader_web.zig")
    else
        @import("store/PluginLoader.zig");
    pub const registry = @import("store/registry/store.zig");
};
