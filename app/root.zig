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
    pub const key = @import("tape").key;
    pub const chord = @import("tape").chord;
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
    /// A place's views as something to pick from — a tab strip, an icon rail, or anything drawn
    /// over the same reorder, select and drag-off behaviour.
    pub const Chooser = @import("layout/Chooser.zig");
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

/// Quitting the way the app always quits — unsaved documents asked about first — then starting
/// again: for a setting the app takes only at launch, and for installing a downloaded `update`.
/// The app asks with `request`, runs `tick` each frame and `relaunch` at the end of teardown.
pub const restart = @import("restart.zig");

/// Demos that drive the real app — a tape of timed input played into dvui, which a viewer can
/// pause, take over, rewind and resume. `Tape` is the format, `Sequencer` the deterministic engine
/// that replays it, `Script` the high-level way to write one, `Player` + `overlay` the dvui half
/// (input injection, the pointer and captions a viewer sees), `Stage` what the app fills in.
pub const automation = struct {
    pub const Tape = @import("tape").Tape;
    pub const Sequencer = @import("tape").Sequencer;
    pub const Script = @import("tape").Script;
    pub const binary = @import("tape").binary;
    pub const Stage = @import("replay").Stage;
    pub const Player = @import("replay").Player;
    /// Tape input as dvui events: the half of a sequencer's sink every player of tapes shares.
    pub const Input = @import("replay").Input;
    /// Plays a live tape — input on the app as it is, a step at a time — beside the `Player`.
    pub const LiveDriver = @import("replay").LiveDriver;
    /// What is on screen, as text: roles, names, tags, rects (`replay.Snapshot`).
    pub const Snapshot = @import("replay").Snapshot;
    /// The `automation` service a plugin plays live tapes through, over a `LiveDriver`.
    pub const Service = @import("automation/Service.zig");
    pub const overlay = @import("automation/overlay.zig");
};

/// One application per machine, and a second launch handing its argv to the first.
///
/// The lock, the socket and the argv plumbing are the same for every app; what "open this path"
/// means is not, which is `singleton.Sink`. The app also sets its own `app_id` — the lock is per
/// application, and two fizzy-based apps must not fight over one.
pub const single_instance = @import("single_instance/singleton.zig");
/// `--profile <dir>` / `FIZZY_PROFILE`: one root for the config folder, the plugins, the lock and
/// the runtime directory. Read by `single_instance` at startup; the app asks it where to live.
pub const profile = @import("profile.zig");

pub const store = struct {
    pub const Store = @import("store/PluginStore.zig");
    /// A plugin's store page as a document — the owner of `store://…` pages.
    pub const Page = @import("store/PluginPage.zig");
    pub const Manager = @import("store/PluginManager.zig");
    /// Runtime plugin loading: `dlopen` natively; on the web a wasm side module the page links
    /// into its function table (`PluginLoader_web.zig`). Same `LoadedLib` read-shape on both.
    pub const Loader = if (@import("builtin").target.cpu.arch == .wasm32)
        @import("store/PluginLoader_web.zig")
    else
        @import("store/PluginLoader.zig");
    pub const registry = @import("store/registry/store.zig");
};

// The root of `zig build test-integration`'s `fizzy-app-tests` (`build/app.zig`): the files here
// whose tests no std-only test root of their own reaches. `Layout`'s own `test` block brings in
// the split trees, seeds, regions, drop plans and view drag beside it.
test {
    _ = layout.Layout;
    _ = layout.Shape;
    _ = watch.FolderWatcher;
    _ = watch.SettingsWatcher;
    _ = store.Loader;
}
