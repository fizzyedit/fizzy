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
const chrome = @import("chrome.zig");
const Sidebar = @import("../Sidebar.zig");

/// The icon rail. Still delegates: it carries pinned store/settings entries, a bounded scroll
/// area with edge shadows, Windows titlebar hit-rect registration, and the undecided-plugin
/// badge. Rewriting it as a bare `f.matching` loop means moving all of that into the app layer
/// first, which is the same job as splitting Explorer chrome from its region (see above).
pub fn iconRail(f: *Frame, keywords: []const []const u8) !Sidebar.Action {
    return f.editor.sidebar.draw(f.editor, f, keywords);
}

/// A **tab strip**: the chooser half of a tabbed region.
///
/// This is the piece that makes the two forms of region explicit in a layout:
///
/// ```zig
/// // "this region IS x" — one surface fills it, no chooser at all. An app that just wants a
/// // terminal at the bottom writes only this.
/// try f.drawSelected(bottom);
///
/// // "this region is TABBED, and the tabs correspond to x"
/// chrome.tabs(f, bottom);            // the tabs
/// try f.drawSelected(bottom);  // ...and the active one
/// ```
///
/// Nothing here is privileged: it lists `f.matching`, reads `f.isSelected` and writes
/// `f.select`, so an app that wants a different-looking chooser — a dropdown, a segmented
/// control, a radial menu — writes its own loop and calls the same three functions. The rail
/// (`iconRail`) is the same idea drawn as icons, and it sits in a *different place* from its
/// body, which is exactly why these are two widgets rather than one region mode.
///
/// **No in-tree caller yet, deliberately.** Fizzy's own bottom panel uses the richer `Panel`
/// path (which draws its own strip *and* supports splitting the bottom into several panes), and
/// `studio.zig` demonstrates the single-surface form. This is the plain tabbed form in between,
/// and it exists as consumer API rather than as fizzy's own code — the first shape that wants
/// tabs without splits uses it as-is instead of copying `Panel`.
pub fn tabs(f: *Frame, keywords: []const []const u8) void {
    const surfaces = f.matching(keywords);
    if (surfaces.len == 0) return;

    var strip: fizzy.dvui.Tabs = .begin(@src(), &tabs_state, .{ .drag_name = "fizzy_tab_strip" });
    defer strip.end();

    for (surfaces, 0..) |surface, i| {
        const selected = f.isSelected(keywords, surface);
        var t = strip.tab(@src(), i, selected);
        defer t.end();

        var title_buf: [64]u8 = undefined;
        const title_upper = if (surface.title.len <= title_buf.len)
            std.ascii.upperString(&title_buf, surface.title)
        else
            surface.title;

        dvui.label(@src(), "{s}", .{title_upper}, .{
            .color_text = if (selected)
                dvui.themeGet().color(.highlight, .fill)
            else
                dvui.themeGet().color(.control, .text),
            .font = dvui.Font.theme(.heading),
            .padding = dvui.Rect.all(4),
            .gravity_y = 0.5,
        });

        if (t.clicked()) f.select(keywords, surface);
    }

    strip.finalSlot(surfaces.len);
}

/// Drag state for `tabStrip`. One strip per app in practice; a layout wanting two independent
/// strips copies this recipe (see CLAUDE.md's shipped-shapes note) rather than fizzy growing a
/// handle type for a case nothing has yet.
var tabs_state: fizzy.dvui.Tabs.State = .{};

/// Surfaces this app declared no region for. An app should show these somewhere (fizzy lists
/// them in settings) so a plugin never silently vanishes — the failure mode keyword matching is
/// only safe because of.
pub fn unplacedSurfaces(f: *Frame) []const *Frame.Surface {
    return f.unplaced(&.{ Frame.sidebar_keywords, Frame.bottom_keywords, Frame.center_keywords });
}

/// Explorer chrome + the sidebar region it wraps.
pub fn explorerPane(f: *Frame, keywords: []const []const u8) !dvui.App.Result {
    return f.editor.explorer.draw(f.editor, f, keywords);
}

/// Bottom-panel chrome (tab strip) + the bottom region it wraps.
pub fn bottomPane(f: *Frame, keywords: []const []const u8) !dvui.App.Result {
    return f.editor.panes.draw(f.editor, f, keywords);
}
