//! `fizzy.widgets` — app-side chrome drawn *around* and *inside* regions, as opposed to
//! `Frame`'s layout verbs.
//!
//! SPIKE FINDING (Phase 1). Fizzy's `Explorer` and `Panel` are not surfaces and are not
//! regions: they are **app chrome that wraps a region**.
//!
//!   Explorer.draw = a header showing the active view's title
//!                 + a scroll area (with per-view scroll policy)
//!                 + the active sidebar view's own draw          <- this part is the region
//!
//!   Panel.draw    = a grouping-aware, drag-reorderable tab strip
//!                 + the active bottom view's own draw           <- this part is the region
//!
//! That is a good result for the design — it confirms the app owns the furniture and the
//! plugin owns only its content — but it means the chrome cannot simply be replaced by
//! `f.region`. Splitting each into "chrome that calls `f.region`" is Phase 4 work, done
//! together with the surface/ABI change so it happens once.
//!
//! Until then these delegate to the existing implementations, which resolve the active view
//! through the same host state `Frame` reads (`host.active_sidebar_view` /
//! `active_bottom_view`), so the new shell and the old one cannot disagree.
const std = @import("std");
const dvui = @import("dvui");
const fizzy = @import("../../fizzy.zig");
const Frame = @import("Frame.zig");
const Sidebar = @import("../Sidebar.zig");

/// The icon rail. Still delegates: it carries pinned store/settings entries, a bounded scroll
/// area with edge shadows, Windows titlebar hit-rect registration, and the undecided-plugin
/// badge. Rewriting it as a bare `f.matching` loop means moving all of that into the app layer
/// first, which is the same job as splitting Explorer chrome from its region (see above).
pub fn iconRail(f: *Frame, keywords: []const []const u8) !Sidebar.Action {
    _ = keywords;
    return f.editor.sidebar.draw(f.editor);
}

/// Surfaces this app declared no region for. An app should show these somewhere (fizzy lists
/// them in settings) so a plugin never silently vanishes — the failure mode keyword matching is
/// only safe because of.
pub fn unplacedSurfaces(f: *Frame) []const *Frame.Surface {
    return f.unplaced(&.{ Frame.sidebar_keywords, Frame.bottom_keywords, Frame.center_keywords });
}

/// Explorer chrome + the sidebar region it wraps.
pub fn explorerPane(f: *Frame, keywords: []const []const u8) !dvui.App.Result {
    _ = keywords;
    return f.editor.explorer.draw(f.editor);
}

/// Bottom-panel chrome (tab strip) + the bottom region it wraps.
pub fn bottomPane(f: *Frame, keywords: []const []const u8) !dvui.App.Result {
    _ = keywords;
    return f.editor.panel.draw(f.editor);
}
