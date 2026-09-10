//! Fizzy region contributions. A plugin's `register(host)` imperatively adds as
//! many of these as it wants (multiple sidebar icons, bottom-panel views, center
//! providers, menubar entries). The near-empty fizzy owns no features of its own —
//! it just iterates these registries (see `Host`) and draws whatever plugins
//! contributed. Built-in fizzy items (e.g. Settings) register with `owner = null`.
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

/// Items injected into an already-open parent menu (e.g. fizzy View). The parent
/// menu's `draw` iterates sections whose `parent_menu_id` matches and calls `draw`
/// while its floating submenu is open.
pub const MenuSectionContribution = struct {
    id: []const u8,
    /// Parent top-level menu id, e.g. "fizzy.menu.view".
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
    /// Parent top-level menu: one of fizzy's ids ("workbench.menu.file", "fizzy.menu.edit",
    /// "fizzy.menu.view", "fizzy.menu.help") to append into an existing native menu, or a
    /// plugin's own `MenuContribution.id` to populate a new top-level menu (created lazily,
    /// titled from that contribution's `title`).
    parent_menu_id: []const u8,
    title: []const u8,
    /// The registered `Command` this item stands for, e.g. `"text.format"`. Optional, and
    /// purely about the *chord*: `run` is still what a click invokes. Fizzy stamps this
    /// command's current binding onto the `NSMenuItem` as its key equivalent and restamps on
    /// every rebind, so the macOS menu shows the same shortcut as the in-app one instead of
    /// none at all. Leave null for an item with no command behind it — the item then never
    /// carries a shortcut.
    command: ?[]const u8 = null,
    /// SF Symbol name for the item's icon (e.g. `"wand.and.stars"`), matching what fizzy's
    /// own items use. Null draws no icon.
    sf_symbol: ?[]const u8 = null,
    /// See `MenuContribution.hidden`.
    hidden: bool = false,
    ctx: ?*anyopaque = null,
    run: *const fn (ctx: ?*anyopaque) anyerror!void,
};

/// A named, invocable action a plugin registers with the Host. Fizzy, menus, and
/// keybindings trigger it by `id` via `Host.runCommand(id)` **without knowing what it
/// does** — this is how a plugin contributes its own features (atlas pack, raster
/// transform, a grid-layout dialog, …) without the SDK or fizzy naming them. Ids are
/// plugin-namespaced (`"pixelart.packProject"`). The owner resolves any context it needs
/// (active doc, selection, …) inside `run`; fizzy passes only the owner's opaque state.
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
    /// Optional TVG icon bytes (e.g. `icons.tvg.lucide.save`) shown ahead of this command's
    /// label wherever fizzy draws a row for it: the in-app dvui menu (a fizzy-owned
    /// `CommandItem`'s row, or a plugin's `MenuSectionContribution` row via `Host.drawMenuItem`)
    /// and the command palette. Absent draws no icon, not a placeholder glyph.
    icon: ?[]const u8 = null,
};

