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

/// A left-region (explorer) view, selected by its sidebar icon. Exactly one
/// sidebar view is active at a time; its `draw` fills the left pane.
pub const SidebarView = struct {
    id: []const u8,
    owner: ?*Plugin = null,
    /// Icon byte slice (tvg/entypo) shown in the sidebar rail.
    icon: []const u8,
    /// User-facing title (sidebar tooltip + pane header).
    title: []const u8,
    ctx: ?*anyopaque = null,
    draw: *const fn (ctx: ?*anyopaque) anyerror!void,
    /// Optional: while this view is the active sidebar view, it takes over the workspace
    /// content region instead of the normal document tabs+canvas. The workbench calls this
    /// per workspace pane, passing the opaque workspace handle (cast back to the document
    /// host's `Workspace`). Used by pixel art's "Project" view to show the packed atlas.
    draw_workspace: ?*const fn (ctx: ?*anyopaque, workspace_handle: *anyopaque) anyerror!void = null,
};

/// A bottom-panel view. The panel shows a tab strip across all registered views;
/// the active one's `draw` fills the panel body.
pub const BottomView = struct {
    id: []const u8,
    owner: ?*Plugin = null,
    title: []const u8,
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
    ctx: ?*anyopaque = null,
    draw: *const fn (ctx: ?*anyopaque) anyerror!void,
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
