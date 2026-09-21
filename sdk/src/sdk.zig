//! Fizzy plugin SDK — the surface a plugin module depends on.
//!
//! A plugin receives a `*Host` and registers its menus, panes, document types, and
//! settings through these types instead of reaching into editor globals. File
//! management, the workspace/tabs system, and the editors (pixel art, …) all live
//! behind this boundary, which also supports loading plugins as runtime dylibs.
//!
//! **This is everything a plugin needs.** A plugin declares one dependency — the `sdk/`
//! package — and that package hands its build the modules it draws with. The widgets and
//! helpers of the shared floor are re-exported here as `sdk.core` (`sdk.core.widgets.Split`,
//! `sdk.core.fuzzy`, …), so a plugin author never has to know that `core` is a separate tree
//! compiled per dvui flavour; `@import("core")` directly is the same thing, and both work.
//!
//! The three trees exist for the dylib boundary, not for the reader:
//!
//!   `core/`  compiled into the app *and* into every plugin, once per dvui flavour — so it may
//!            never depend on the app, and an app-only dependency (Velopack) in here would be
//!            linked into every `.dylib` fizzy ships.
//!   `sdk/`   the shape that crosses `dlopen`, locked by `recorded_sdk_shape_fingerprint`.
//!   app      what only an application needs — layout presets, the plugin store, installers.
//!            Never enters a dylib.

/// In effect only when this file is a compilation **root**, which it is for exactly one thing:
/// the SDK's own test binary (`fizzy-sdk-tests`). An app or plugin has its own root and this is
/// inert there.
///
/// It exists because the test runner fails a run that logs anything above `err`, and one of
/// these tests asserts a behaviour whose whole point is that it *warns*: a service provider
/// whose version does not match the caller's is refused rather than cast. Silencing the warning
/// in the test binary keeps that test honest — it still calls the real lookup and still asserts
/// the refusal — without turning a deliberate log into a failed build.
const std = @import("std");

pub const std_options: std.Options = .{ .log_level = .err };

// Eagerly evaluate the ABI fingerprint lock (see `version.zig`).
comptime {
    _ = @import("version.zig");
}

/// The shared floor, re-exported so `sdk` really is the one name a plugin needs: widgets
/// (`core.widgets.Split`, `Tabs`, `TreeWidget`), `core.anim`, `core.dialogs`, `core.draw`,
/// `core.fuzzy`, `core.paths`, `core.lsp`. The `sdk/` package exports it to a plugin's build as
/// its own module too, so `@import("core")` resolves to this same code.
pub const core = @import("core");

pub const Host = @import("Host.zig");
pub const Plugin = @import("Plugin.zig");
pub const DocHandle = @import("DocHandle.zig");

/// Comptime settings API (`sdk.settings.Schema(T)`) — see `docs/PLUGIN_MANIFEST_PLAN.md`.
pub const settings = @import("settings.zig");

pub const language = @import("language.zig");
pub const LanguageSupport = language.LanguageSupport;
pub const TreeSitterHighlight = language.TreeSitterHighlight;
pub const HighlightStyle = language.HighlightStyle;

/// A named thing a plugin draws. The app's layout decides where it lands, by keyword.
pub const Surface = @import("Surface.zig");
/// A region a plugin declares inside the one it is drawing in. See `Host.region`.
pub const RegionSpec = @import("RegionSpec.zig");
/// Conventional region keywords fizzy's own shell accepts.
pub const keywords = @import("keywords.zig");
/// What a plugin adds to the menu bar, in-app and native.
pub const menus = @import("menus.zig");
pub const accounts = @import("accounts.zig");
pub const MenuContribution = menus.MenuContribution;
pub const MenuSectionContribution = menus.MenuSectionContribution;
pub const NativeMenuItem = menus.NativeMenuItem;
/// A named action fizzy invokes by id, without knowing what it does.
pub const Command = @import("Command.zig");
pub const menu = @import("menu.zig");

/// Fizzy-provided read/utility surface plugins reach through the `Host`
/// (arena, folder, shared settings, dirty-marking).
pub const EditorAPI = @import("EditorAPI.zig");
pub const SaveDialogFilter = EditorAPI.SaveDialogFilter;
pub const SaveDialogCallback = EditorAPI.SaveDialogCallback;

pub const pane_layout = @import("pane_layout.zig");
pub const infobar = @import("infobar.zig");

/// Host-injected runtime: `sdk.allocator()` (the persistent host allocator) and
/// `sdk.host()` (fizzy `*Host`). The dylib entry injects these before `register`;
/// plugin code reads them directly, with no per-plugin storage file.
pub const allocator = @import("runtime.zig").allocator;
pub const host = @import("runtime.zig").host;
pub const installRuntime = @import("runtime.zig").installRuntime;
pub const injectedState = @import("runtime.zig").injectedState;

/// Wake the app event loop for another frame. Safe from worker threads.
pub fn refresh() void {
    host().refresh();
}

/// Document staging helpers (`allocStaging`, `loadPathInto`, …).
pub const document = @import("document.zig");

/// The declarative `plugin.zig.zon` manifest types (see `docs/PLUGIN_MANIFEST_PLAN.md`).
pub const Manifest = @import("Manifest.zig");

/// Services: capability offered by name and version rather than by the ABI.
///
/// `"files"` is the application's; the rest are plugins'. Every one of them is optional — a
/// caller handles null and offers what it can, which is what lets one plugin build run in
/// applications that have wildly different amounts of machinery.
pub const services = struct {
    pub const files = @import("services/files.zig");
    pub const workbench = @import("services/workbench.zig");
    pub const markdown = @import("services/markdown.zig");
    pub const wikilink = @import("services/wikilink.zig");
};

/// SDK version + ABI fingerprint lock (`sdk_version`, `recorded_abi_fingerprints`).
pub const version = @import("version.zig");

/// Runtime dylib entry contract (`fizzy_plugin_abi_fingerprint` / `fizzy_plugin_register`).
pub const dylib = @import("dylib.zig");
/// Compile-time structural ABI fingerprint used by `dylib.abi_fingerprint`.
pub const fingerprint = @import("fingerprint.zig");
/// Dvui global injection for loaded plugin images.
pub const dvui_context = @import("dvui_context.zig");
/// Host thunks that forward plugin proxy draws to fizzy backend.
pub const render_bridge = @import("render_bridge.zig");
