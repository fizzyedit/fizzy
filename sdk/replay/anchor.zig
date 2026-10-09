//! Names for the things a demo points at: `dvui.tag`, with a name built from data.
//!
//! A demo tape aims at widgets by name rather than by pixel (`tape.Tape.Target`), so it
//! plays at any window size. dvui already keeps such names — `Options.tag` registers a widget's
//! rect under a string every frame, and `dvui.tagGet` reads it back — but only for a name known
//! when the options are written. An explorer row or an editor is one of many, named by the file
//! it shows; `mark` builds that name and tags the widget with it.
//!
//! Names are `<owner>.<kind>[:<subject>]`, the subject usually an absolute path:
//! `workbench.file:demo://tour/src/main.zig`, `text.editor:demo://tour/README.md`. The ones fizzy
//! and its bundled plugins publish are listed in `docs/AUTOMATION.md`.
//!
//! Marking costs nothing while nobody is looking: whoever wants anchors asks for them, a frame at
//! a time (`want`), and `mark` returns at once in a frame nobody asked. Shared through the
//! window's data, so a plugin dylib's copy of this file agrees. fizzy's plugins reach it as
//! `core.anchor`.
const std = @import("std");
const dvui = @import("dvui");

const publish_id: dvui.Id = @enumFromInt(0x6669_7a7a_616e_6368); // "fizzanch"
/// The frame anchors were last asked for in, by its `frame_time_ns`. Not the `_anchors` bool an
/// older copy of this file reads: a plugin built against that one marks nothing until rebuilt,
/// rather than reading a value of another type.
const want_key = "_anchors_at";

/// Ask for anchors this frame, before anything draws: every widget that marks itself is named
/// for whoever is looking. Anyone may ask — the demo player and the live driver while a tape
/// plays (`app.automation`), a recorder, a plugin's test through the `automation` service — and
/// asking twice is asking once. It lasts the frame: ask again in the next to keep them.
pub fn want() void {
    const cw = dvui.current_window orelse return;
    dvui.dataSet(cw, publish_id, want_key, cw.frame_time_ns);
}

/// Whether anyone asked for anchors this frame.
pub fn wanted() bool {
    const cw = dvui.current_window orelse return false;
    const at = dvui.dataGet(cw, publish_id, want_key, i128) orelse return false;
    return at == cw.frame_time_ns;
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
