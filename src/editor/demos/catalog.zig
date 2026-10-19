//! The demos fizzy ships with. Each is a script (`app.automation.Script`) built when it is played,
//! so it reads the keymap and window it plays in rather than the ones it was written against.
//!
//! Adding one: a file beside this with `pub fn build(s: *Script) !void`, and a row below. It is
//! then a command ("Demo: <title>", `fizzy.demo.<name>`), `FIZZY_DEMO=<name>` natively and
//! `?demo=<name>` on the web. What a script can aim at is in `docs/AUTOMATION.md`.
//!
//! They need nothing but `tape`, so `zig build demos` builds them on the host too, into the tapes
//! the site's copies of the app serve beside themselves (`scripts/demos.zig`).
const std = @import("std");
const Script = @import("tape").Script;
const Tape = @import("tape").Tape;

pub const Entry = struct {
    /// Stable id: the command's suffix, the web's `?demo=`, the mount `demo://<name>`.
    name: []const u8,
    title: []const u8,
    build: *const fn (s: *Script) anyerror!void,
};

pub const entries = [_]Entry{
    .{ .name = "tour", .title = "A Tour of Fizzy", .build = @import("tour.zig").build },
    .{ .name = "markdown", .title = "Markdown, Previewed as You Type", .build = @import("markdown.zig").build },
};

pub fn find(name: []const u8) ?*const Entry {
    for (&entries) |*e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    return null;
}

// ---- what fizzy's demos aim at -------------------------------------------------------------
//
// The anchor names fizzy and its bundled plugins publish (`core.anchor`), built under the
// script's current keyframe root. In one place so a renamed anchor is one edit.

/// The explorer row for `rel` (a file or a folder).
pub fn file(s: *Script, rel: []const u8) ![]const u8 {
    return s.print("workbench.file:{s}/{s}", .{ s.root, rel });
}

/// The text editor showing `rel`.
pub fn editor(s: *Script, rel: []const u8) ![]const u8 {
    return s.print("text.editor:{s}/{s}", .{ s.root, rel });
}

/// Where typing at the end of `rel` begins, in its editor: just after its last line's text.
pub fn end(s: *Script, rel: []const u8) ![]const u8 {
    return s.print("text.end:{s}/{s}", .{ s.root, rel });
}

/// What of `rel`'s text is in view, out to its longest line.
pub fn body(s: *Script, rel: []const u8) ![]const u8 {
    return s.print("text.body:{s}/{s}", .{ s.root, rel });
}

/// The preview beside `rel`'s text, when it has one.
pub fn preview(s: *Script, rel: []const u8) ![]const u8 {
    return s.print("text.preview:{s}/{s}", .{ s.root, rel });
}

/// A caption about writing in `rel`: beside where the words go, keeping clear of them and of the
/// preview redrawing them.
pub fn aboutWriting(s: *Script, rel: []const u8) !Script.CaptionOptions {
    const clear = try s.arena.allocator().dupe([]const u8, &.{ try body(s, rel), try preview(s, rel) });
    return .{ .near = try end(s, rel), .clear = clear };
}

/// A place by name (`Sidebar`, `Main`, `Float 1`): the whole of it.
pub fn place(s: *Script, name: []const u8) ![]const u8 {
    return s.print("region:{s}", .{name});
}

/// Where a place's corner button is: its anchor (`region.arrange:<name>`), wherever it grows in the
/// place's corner. The button shows only while the pointer is on the corner, so `cornerButton`
/// comes at it from the corner.
pub fn corner(s: *Script, name: []const u8) !Tape.Target {
    return .{ .tag = try s.print("region.arrange:{s}", .{name}) };
}

/// Bring a place's corner button up and rest on it: from the very corner, where it starts to
/// show, then in onto it.
pub fn cornerButton(s: *Script, name: []const u8) !void {
    try s.moveTo(.{ .tag = try place(s, name), .x = 1, .y = 0, .dx = -3, .dy = 3 }, .{ .ms = 500 });
    try s.moveTo(try corner(s, name), .{ .ms = 200 });
}

/// The grip at the foot of `rel`'s pane, shown once it has history: holding on it grows the
/// history's bar.
pub fn historyGrip(s: *Script, rel: []const u8) ![]const u8 {
    return s.print("history.grip:{s}/{s}", .{ s.root, rel });
}

/// The line of `rel`'s history in its bar: `x` 0 is before the first change, 1 the last.
pub fn historyLine(s: *Script, rel: []const u8) ![]const u8 {
    return s.print("history.line:{s}/{s}", .{ s.root, rel });
}

/// The tab for `rel`.
pub fn tab(s: *Script, rel: []const u8) ![]const u8 {
    return s.print("workbench.tab:{s}/{s}", .{ s.root, rel });
}

/// The documents' place: where the work is, and so where a demo's popups gather when they are
/// about no one thing (`Script.home`).
pub const documents = "region:Main";

/// The command palette's text field.
pub const palette = "fizzy.palette";

/// The rail's Files icon. A click opens the explorer when it is put away, and puts it away when it
/// is open — on a narrow window, where the explorer is folded rather than closed, too. Spelled out
/// rather than built from `workbench.view_files`, which would bring dvui into `zig build demos`;
/// `tests/demos.zig` holds them equal.
pub const files_icon = "fizzy.rail:workbench.files";

/// Open `rel` the way a person who keeps the explorer put away would: open the explorer from the
/// rail, click the file, and put the explorer away again so the editor has the room. A demo's
/// keyframe starts with the explorer put away (`Keyframe.Layout.focused`).
pub fn openFile(s: *Script, rel: []const u8) !void {
    try s.click(.{ .tag = files_icon }, .{});
    try s.click(.{ .tag = try file(s, rel) }, .{});
    try s.waitFor(try editor(s, rel), .{});
    try s.click(.{ .tag = files_icon }, .{});
}
