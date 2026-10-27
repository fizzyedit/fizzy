//! What of fizzy's own shape an application keeps: where the sidebar sits, and whether the panel,
//! the menu bar and the infobar exist, and whether places draw a corner button. An application sets them as build options
//! (`-Dchrome-sidebar-edge=right`, `-Dchrome-panel=false`, ...); the defaults are fizzy's own
//! frame, so nothing changes for fizzy or an app that sets none. Read by the desktop and mobile shapes; an
//! app-supplied layout (`-Dapp-layout=`) draws its own frame and ignores them.
const build_opts = @import("build_opts");

const Chrome = @This();

/// The build option's own enum, so the two cannot drift.
pub const Edge = @TypeOf(build_opts.chrome_sidebar_edge);

/// The end of the window the icon rail and the Sidebar sit at. The Sidebar's width is still its
/// `extent` in `layout.zon`, whichever edge it is on.
sidebar_edge: Edge = .left,
/// The Panel place and fizzy's Output view in it. False draws neither, so nothing opens a panel.
panel: bool = true,
/// The in-window menu bar; macOS has only its native menu, so this changes nothing there.
menu_bar: bool = true,
infobar: bool = true,
/// The corner button on every place, the handle that lifts a view. False for an app with one place,
/// where lifting means nothing; a drag begun elsewhere still lands (`Layout.corner_buttons`).
corner_buttons: bool = true,

/// What this build was configured with.
pub const configured: Chrome = .{
    .sidebar_edge = build_opts.chrome_sidebar_edge,
    .panel = build_opts.chrome_panel,
    .menu_bar = build_opts.chrome_menu_bar,
    .infobar = build_opts.chrome_infobar,
    .corner_buttons = build_opts.chrome_corner_buttons,
};
