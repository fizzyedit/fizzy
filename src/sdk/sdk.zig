//! Fizzy plugin SDK — the surface a plugin module depends on.
//!
//! A plugin receives a `*Host` and registers its menus, panes, document types, and
//! settings through these types instead of reaching into editor globals. File
//! management, the workspace/tabs system, and the editors (pixel art, …) all live
//! behind this boundary, which also supports loading plugins as runtime dylibs.

// Eagerly evaluate the ABI fingerprint lock (see `version.zig`).
comptime {
    _ = @import("version.zig");
}

pub const Host = @import("Host.zig");
pub const Plugin = @import("Plugin.zig");
pub const DocHandle = @import("DocHandle.zig");

/// Comptime settings API (`sdk.settings.Schema(T)`) — see `docs/PLUGIN_MANIFEST_PLAN.md`.
pub const settings = @import("settings.zig");

pub const language = @import("language.zig");
pub const LanguageSupport = language.LanguageSupport;
pub const TreeSitterHighlight = language.TreeSitterHighlight;
pub const HighlightStyle = language.HighlightStyle;

/// Shell region contribution types (sidebar / bottom / center / menu / settings).
pub const regions = @import("regions.zig");
pub const SidebarView = regions.SidebarView;
pub const BottomView = regions.BottomView;
pub const CenterProvider = regions.CenterProvider;
pub const MenuContribution = regions.MenuContribution;
pub const MenuSectionContribution = regions.MenuSectionContribution;
pub const Command = regions.Command;
pub const menu = @import("menu.zig");

/// Shell-provided read/utility surface plugins reach through the `Host`
/// (arena, folder, shared settings, dirty-marking).
pub const EditorAPI = @import("EditorAPI.zig");
pub const SaveDialogFilter = EditorAPI.SaveDialogFilter;
pub const SaveDialogCallback = EditorAPI.SaveDialogCallback;

pub const WorkbenchPane = @import("WorkbenchPane.zig");
pub const WorkbenchPaneView = WorkbenchPane.WorkbenchPaneView;
pub const pane_layout = @import("pane_layout.zig");

/// Host-injected runtime: `sdk.allocator()` (the persistent host allocator) and
/// `sdk.host()` (the shell `*Host`). The dylib entry injects these before `register`;
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
pub const manifest = @import("manifest.zig");
pub const Manifest = manifest.Manifest;

/// Inter-plugin services (`"workbench"`, `"markdown"`).
pub const services = struct {
    pub const workbench = @import("services/workbench.zig");
    pub const markdown = @import("services/markdown.zig");
};

/// SDK version + ABI fingerprint lock (`sdk_version`, `recorded_abi_fingerprints`).
pub const version = @import("version.zig");

/// Runtime dylib entry contract (`fizzy_plugin_abi_fingerprint` / `fizzy_plugin_register`).
pub const dylib = @import("dylib.zig");
/// Compile-time structural ABI fingerprint used by `dylib.abi_fingerprint`.
pub const fingerprint = @import("fingerprint.zig");
/// Dvui global injection for loaded plugin images.
pub const dvui_context = @import("dvui_context.zig");
/// Host thunks that forward plugin proxy draws to the shell backend.
pub const render_bridge = @import("render_bridge.zig");
