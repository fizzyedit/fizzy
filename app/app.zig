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
pub const store = struct {
    pub const Store = @import("store/PluginStore.zig");
    pub const Manager = @import("store/PluginManager.zig");
    /// Runtime plugin loading is native-only — there is no `dlopen` in a browser, and web
    /// builds link their plugins statically. The stub keeps the *types* so cross-platform code
    /// (the store's installed list) compiles either way; on wasm the list is simply always empty.
    pub const Loader = if (@import("builtin").target.cpu.arch == .wasm32)
        @import("store/PluginLoader_stub.zig")
    else
        @import("store/PluginLoader.zig");
    pub const registry = @import("store/registry/store.zig");
};
