//! Shell region contributions. A plugin's `register(host)` imperatively adds as
//! many of these as it wants (multiple sidebar icons, bottom-panel views, center
//! providers, menubar entries). The near-empty shell owns no features of its own —
//! it just iterates these registries (see `Host`) and draws whatever plugins
//! contributed. Built-in shell items (e.g. Settings) register with `owner = null`.
//!
//! `ctx` is contribution-owned opaque state passed back to its `draw` fn (null for
//! contributions that reach through the `fizzy.*` globals directly). `id`s are
//! stable and plugin-namespaced (e.g. "pixelart.sprites") so selection state and
//! cross-plugin references survive without a compile-time dependency.
const dvui = @import("dvui");
const Plugin = @import("Plugin.zig");
const WorkbenchPaneView = @import("WorkbenchPane.zig").WorkbenchPaneView;

/// A left-region (explorer) view, selected by its sidebar icon. Exactly one
/// sidebar view is active at a time; its `draw` fills the left pane.
pub const SidebarView = struct {
    id: []const u8,
    owner: ?*Plugin = null,
    /// Icon byte slice (tvg/entypo) shown in the sidebar rail.
    icon: []const u8,
    /// User-facing title (sidebar tooltip + pane header).
    title: []const u8,
    /// When true the view is registered but omitted from the sidebar icon rail.
    hidden: bool = false,
    ctx: ?*anyopaque = null,
    draw: *const fn (ctx: ?*anyopaque) anyerror!void,
    /// Optional: while this view is the active sidebar view, it takes over the workspace
    /// content region instead of the normal document tabs+canvas. The workbench calls this
    /// per workspace pane with a `WorkbenchPaneView` (grouping + toast rect slot).
    draw_workspace: ?*const fn (ctx: ?*anyopaque, pane: *WorkbenchPaneView) anyerror!void = null,
};

/// A bottom-panel view. The panel shows a tab strip across all registered views;
/// the active one's `draw` fills the panel body.
pub const BottomView = struct {
    id: []const u8,
    owner: ?*Plugin = null,
    title: []const u8,
    /// When true the bottom panel stays visible even with no active document.
    persistent: bool = false,
    ctx: ?*anyopaque = null,
    draw: *const fn (ctx: ?*anyopaque) anyerror!void,
};

/// A center ("main window") provider. The active provider draws the ENTIRE center
/// region and may render a single view or its own recursive tabs/splits. The
/// workbench registers one (its tabs/splits + canvas); others may take over.
pub const CenterProvider = struct {
    id: []const u8,
    owner: ?*Plugin = null,
    ctx: ?*anyopaque = null,
    draw: *const fn (ctx: ?*anyopaque) anyerror!dvui.App.Result,
};

/// A menubar contribution. Its `draw` adds top-level menu(s) to the in-app menu
/// bar (non-macOS). A plugin may register several.
pub const MenuContribution = struct {
    id: []const u8,
    owner: ?*Plugin = null,
    /// User-facing title, e.g. "Example". Unused by the in-app `draw` path (which renders its
    /// own title text), but read by the native macOS menu builder: when this contribution has
    /// `NativeMenuItem`s parented to its `id`, the builder creates a real top-level `NSMenu`
    /// titled from this field. Leave empty to opt this menu out of native representation.
    title: []const u8 = "",
    /// When true, this contribution is skipped everywhere (in-app bar + native menu). Plugins
    /// that toggle visibility without a full load/unload (e.g. a static built-in hidden via the
    /// plugin store) flip this instead of unregistering.
    hidden: bool = false,
    ctx: ?*anyopaque = null,
    draw: *const fn (ctx: ?*anyopaque) anyerror!void,
};

/// Items injected into an already-open parent menu (e.g. shell View). The parent
/// menu's `draw` iterates sections whose `parent_menu_id` matches and calls `draw`
/// while its floating submenu is open.
pub const MenuSectionContribution = struct {
    id: []const u8,
    /// Parent top-level menu id, e.g. "shell.menu.view".
    parent_menu_id: []const u8,
    owner: ?*Plugin = null,
    /// When true, this section is skipped by the in-app bar's `drawMenuSections`. See
    /// `MenuContribution.hidden`.
    hidden: bool = false,
    ctx: ?*anyopaque = null,
    draw: *const fn (ctx: ?*anyopaque) anyerror!void,
};

/// A single, natively-representable menu leaf item — pure data (title + callback), unlike
/// `MenuContribution`/`MenuSectionContribution`'s immediate-mode `draw` callbacks. The native
/// macOS menu builder (`backend_native.zig`'s `rebuildDynamicNativeMenus`) walks these to
/// construct real `NSMenuItem`s and add/remove them live on plugin load/unload/hide, without
/// invoking any dvui drawing code. Register one of these *alongside* the matching
/// `MenuContribution`/`MenuSectionContribution` for an item that should also appear in the
/// real macOS menu bar (in-app dvui bar contributions alone are macOS-invisible — see
/// `Editor.zig`'s "on macOS the menu is handled natively" comment).
pub const NativeMenuItem = struct {
    id: []const u8,
    owner: ?*Plugin = null,
    /// Parent top-level menu: one of the shell's ids ("workbench.menu.file", "shell.menu.edit",
    /// "shell.menu.view", "shell.menu.help") to append into an existing native menu, or a
    /// plugin's own `MenuContribution.id` to populate a new top-level menu (created lazily,
    /// titled from that contribution's `title`).
    parent_menu_id: []const u8,
    title: []const u8,
    /// See `MenuContribution.hidden`.
    hidden: bool = false,
    ctx: ?*anyopaque = null,
    run: *const fn (ctx: ?*anyopaque) anyerror!void,
};

/// A named, invocable action a plugin registers with the Host. The shell, menus, and
/// keybindings trigger it by `id` via `Host.runCommand(id)` **without knowing what it
/// does** — this is how a plugin contributes its own features (atlas pack, raster
/// transform, a grid-layout dialog, …) without the SDK or shell naming them. Ids are
/// plugin-namespaced (`"pixelart.packProject"`). The owner resolves any context it needs
/// (active doc, selection, …) inside `run`; the shell passes only the owner's opaque state.
pub const Command = struct {
    id: []const u8,
    owner: ?*Plugin = null,
    /// User-facing label (menus / future command palette).
    title: []const u8,
    /// Invoke the command. `state` is the owning plugin's opaque state (`owner.state`).
    run: *const fn (state: *anyopaque) anyerror!void,
    /// Optional enabled-state query — e.g. grey out while busy or with no active document.
    /// Absent = always enabled.
    isEnabled: ?*const fn (state: *anyopaque) bool = null,
};

/// A settings section. The Settings view renders each registered section under its
/// own `title` heading, grouped by plugin (VSCode-style). The shell registers its
/// own "Editor" section; plugins register theirs (e.g. pixel art's canvas/ruler
/// prefs). `draw` fills the section body with that owner's controls.
pub const SettingsSection = struct {
    id: []const u8,
    owner: ?*Plugin = null,
    /// Heading shown above this section's controls.
    title: []const u8,
    ctx: ?*anyopaque = null,
    draw: *const fn (ctx: ?*anyopaque) anyerror!void,
};
