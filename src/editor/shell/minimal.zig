//! A deliberately **not** IDE-shaped shell: one main region, one status strip, no icon rail, no
//! explorer, no bottom panel.
//!
//! Its whole job is to be a second consumer of the layout API that shares no assumptions with
//! fizzy's own shape, so the API cannot quietly re-acquire them. It loads the *same*
//! `workbench` / `text` / `image` plugins as `ide.zig`, unchanged — that is the acceptance test
//! (plan, Phase 5).
//!
//! **Use it, or copy it.** Following dvui's methodology for widgets: fizzy ships a handful of
//! shapes, and an app either uses one directly — `-Dshell=ide` gives you the general IDE shape
//! with no layout code of your own — or copies this function into its own source and edits it to
//! add, remove or rearrange regions. There is nothing privileged in here: it is ordinary code
//! over the public `Frame` API, which is exactly what makes copying it a reasonable thing to do
//! rather than a fork.
//!
//! Note what is absent: no rail, so nothing selects between browser surfaces; no sidebar region,
//! so surfaces that only match `sidebar`/`explorer` are unplaced and reported rather than drawn.
//! That is the designed behavior, not a bug.
const std = @import("std");
const dvui = @import("dvui");
const fizzy = @import("../../fizzy.zig");
const sdk = fizzy.sdk;

const Frame = @import("Frame.zig");

// ── The minimal preset ──────────────────────────────────────────────────────────────────────
/// One region, and it is the main area. No sidebar or panel vocabulary at all — surfaces asking
/// for those simply have nowhere to go here, which `Frame.unplaced` reports.
pub const main_area = sdk.keywords.ide.main;

pub fn layout(editor: *fizzy.Editor, f: *Frame) !dvui.App.Result {
    var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer body.deinit();

    for (editor.host.plugins.items) |plugin| plugin.tickActiveDocument(body.data().id);
    defer for (editor.host.plugins.items) |plugin| plugin.endFrame();

    editor.flushQueuedNativeMenuActions();
    editor.flushQueuedNativeMenuItems();
    editor.processPendingSaveAs();

    // The whole window is the main region. Workbench's tabs and splits land here because its
    // surface carries the `main`/`center`/`workspace` keywords — the app never names it.
    const result = try f.region(.{ .keywords = main_area });

    // A thin status strip along the bottom.
    editor.infobar.draw(editor) catch dvui.log.err("Failed to draw infobar", .{});

    return result;
}
