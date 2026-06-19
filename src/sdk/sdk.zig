//! Fizzy plugin SDK — the surface a plugin module depends on.
//!
//! A plugin receives a `*Host` and registers its menus, panes, document types, and
//! settings through these types instead of reaching into editor globals. File
//! management, the workspace/tabs system, and the editors (pixel art, …) all live
//! behind this boundary, which also supports loading plugins as runtime dylibs.
pub const Host = @import("Host.zig");
pub const Plugin = @import("Plugin.zig");
pub const DocHandle = @import("DocHandle.zig");

/// Shell region contribution types (sidebar / bottom / center / menu / settings).
pub const regions = @import("regions.zig");
pub const SidebarView = regions.SidebarView;
pub const BottomView = regions.BottomView;
pub const CenterProvider = regions.CenterProvider;
pub const MenuContribution = regions.MenuContribution;
pub const SettingsSection = regions.SettingsSection;

/// Shell-provided read/utility surface plugins reach through the `Host`
/// (arena, folder, shared settings, dirty-marking).
pub const EditorAPI = @import("EditorAPI.zig");
pub const SaveDialogFilter = EditorAPI.SaveDialogFilter;
pub const SaveDialogCallback = EditorAPI.SaveDialogCallback;
pub const UiSprite = EditorAPI.UiSprite;
pub const UiAtlasView = EditorAPI.UiAtlasView;

pub const WorkbenchPane = @import("WorkbenchPane.zig");
pub const WorkbenchPaneView = WorkbenchPane.WorkbenchPaneView;
pub const pane_layout = @import("pane_layout.zig");

/// Runtime dylib entry contract (`fizzy_plugin_abi_version` / `fizzy_plugin_register`).
pub const dylib = @import("dylib.zig");
/// Dvui global injection for loaded plugin images.
pub const dvui_context = @import("dvui_context.zig");
