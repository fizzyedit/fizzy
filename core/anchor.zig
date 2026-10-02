//! Names for the things a demo points at: `dvui.tag`, with a name built from data.
//!
//! A demo tape aims at widgets by name rather than by pixel (`app.automation.Tape.Target`), so it
//! plays at any window size. dvui already keeps such names — `Options.tag` registers a widget's
//! rect under a string every frame, and `dvui.tagGet` reads it back — but only for a name known
//! when the options are written. An explorer row or an editor is one of many, named by the file
//! it shows; `mark` builds that name and tags the widget with it.
//!
//! Names are `<owner>.<kind>[:<subject>]`, the subject usually an absolute path:
//! `workbench.file:demo://tour/src/main.zig`, `text.editor:demo://tour/README.md`. The ones fizzy
//! and its bundled plugins publish are listed in `docs/AUTOMATION.md`.
//!
//! Marking costs nothing while nobody is looking: the host publishes whether anyone wants anchors
//! this frame (`publish`, while a demo is loaded), and `mark` returns at once otherwise. Shared
//! through the window's data like `core.motion`, so a plugin dylib's copy of this file agrees.
const std = @import("std");
const dvui = @import("dvui");

const publish_id: dvui.Id = @enumFromInt(0x6669_7a7a_616e_6368); // "fizzanch"
const publish_key = "_anchors";

/// Host only, once a frame before anything draws: whether anchors are wanted this frame.
pub fn publish(on: bool) void {
    dvui.dataSet(null, publish_id, publish_key, on);
}

/// Whether anyone wants anchors this frame.
pub fn wanted() bool {
    if (dvui.current_window == null) return false;
    return dvui.dataGet(null, publish_id, publish_key, bool) orelse false;
}

/// Tag `wd` with the name `fmt` formats to, when anchors are wanted. The first widget to claim a
/// name in a frame keeps it: the same document shown in two panes is one name, the first pane.
pub fn mark(wd: *const dvui.WidgetData, comptime fmt: []const u8, args: anytype) void {
    markRect(wd.id, wd.borderRectScale().r, wd.visible(), fmt, args);
}

/// `mark` for a place in a widget rather than the whole of it: `r` (physical), in the widget `id`
/// — where in a document typing at its end begins, say, which is where a demo clicks to type.
pub fn markRect(id: dvui.Id, r: dvui.Rect.Physical, visible: bool, comptime fmt: []const u8, args: anytype) void {
    if (!wanted()) return;
    var buf: [512]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, fmt, args) catch return;
    if (dvui.currentWindow().tags.containsUsed(name) orelse false) return;
    dvui.tag(name, .{ .id = id, .rect = r, .visible = visible });
}
