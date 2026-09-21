//! Menu contributions: what a plugin adds to the menu bar, in-app and native.
//!
//! A plugin's `register(host)` imperatively adds as many of these as it wants. The near-empty
//! fizzy owns no menus of its own — it iterates these registries (see `Host`) and draws whatever
//! plugins contributed. Built-in fizzy items (e.g. Settings) register with `owner = null`.
//!
//! `ctx` is contribution-owned opaque state passed back to its `draw` fn (null for contributions
//! that reach through the `fizzy.*` globals directly). `id`s are stable and plugin-namespaced
//! (e.g. `"pixi.sprites"`) so selection state and cross-plugin references survive without a
//! compile-time dependency.
//!
//! The immediate-mode `draw` contributions and the pure-data `NativeMenuItem` are two
//! representations of the same menu, not alternatives: macOS draws a real `NSMenu` and never
//! sees a dvui bar, every other platform draws the dvui bar and never sees an `NSMenu`. A plugin
//! that wants an item everywhere registers both.
const Plugin = @import("Plugin.zig");

/// A menubar contribution. Its `draw` adds top-level menu(s) to the in-app menu bar
/// (non-macOS). A plugin may register several.
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

/// Another way to open something, beside fizzy's own New File / Open Folder / Open Files:
/// "Open Drive Folder" from a cloud plugin, say. Pure data — a title and the `Command` it
/// runs — so fizzy can put it wherever those verbs appear: the File menu (right after Open
/// Files, in-app and native) and the workbench's home page. Shown only while the command
/// reports enabled, so a cloud plugin lists its action only once someone is signed in.
pub const OpenAction = struct {
    id: []const u8,
    owner: ?*Plugin = null,
    title: []const u8,
    /// The registered `Command` this runs; its `isEnabled` decides whether the action shows.
    command: []const u8,
    /// SF Symbol for the native menu row, as `NativeMenuItem.sf_symbol`.
    sf_symbol: ?[]const u8 = null,
    hidden: bool = false,
};

/// A small thing drawn at the bottom of the rail, above the store and settings icons — an
/// account disc, a sync badge, a status light. Fizzy provides the slot and the row; the plugin
/// draws what goes in it (and any popup it opens), sized like the rail's own icons. Not a
/// view: it selects nothing and has no pane. Removed with the plugin.
pub const RailItemContribution = struct {
    id: []const u8,
    owner: ?*Plugin = null,
    hidden: bool = false,
    ctx: ?*anyopaque = null,
    /// `size` is the rail icon size, so the item can match it.
    draw: *const fn (ctx: ?*anyopaque, size: f32) anyerror!void,
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
