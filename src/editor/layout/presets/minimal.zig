//! A deliberately **not** IDE-shaped shell: one main region, one status strip, no icon rail, no
//! explorer, no bottom panel.
//!
//! Its whole job is to be a second consumer of the layout API that shares no assumptions with
//! fizzy's own shape, so the API cannot quietly re-acquire them. It loads the *same*
//! `workbench` / `text` / `image` plugins as `ide.zig`, unchanged — that is the acceptance test
//! (plan, Phase 5).
//!
//! **Use it, or copy it.** Following dvui's methodology for widgets: fizzy ships a handful of
//! shapes, and an app either uses one directly — `-Dlayout=ide` gives you the general IDE shape
//! with no layout code of your own — or copies this function into its own source and edits it to
//! add, remove or rearrange regions. There is nothing privileged in here: it is ordinary code
//! over the public `Layout` API, which is exactly what makes copying it a reasonable thing to do
//! rather than a fork.
//!
//! Note what is absent: no rail, so nothing selects between browser surfaces; no sidebar region,
//! so surfaces that only match `sidebar`/`explorer` are unplaced and reported rather than drawn.
//! That is the designed behavior, not a bug.
const std = @import("std");
const dvui = @import("dvui");
const fizzy = @import("../../../fizzy.zig");
const sdk = fizzy.sdk;

const Layout = @import("app").layout.Layout;

// ── The minimal preset ──────────────────────────────────────────────────────────────────────
/// One region, and it is the main area. No sidebar or panel vocabulary at all — surfaces asking
/// for those simply have nowhere to go here, which `Layout.unplaced` reports.
pub const main_area = sdk.keywords.ide.main;

pub fn layout(editor: *fizzy.Editor, f: *Layout) !dvui.App.Result {
    var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer body.deinit();

    // Drawn first so it reserves its height: a region that expands takes every remaining point,
    // and anything declared after one gets none.
    editor.infobar.draw(editor) catch dvui.log.err("Failed to draw infobar", .{});

    // One region, filling everything. Workbench's tabs and splits land here because its surface
    // carries the `main` keywords — this shape never names it.
    var main = try f.region(@src(), .{ .name = "Main", .keywords = main_area }, .{ .expand = .both });
    defer main.deinit();

    return .ok;
}
