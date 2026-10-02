//! The demos fizzy ships with. Each is a script (`app.automation.Script`) built when it is played,
//! so it reads the keymap and window it plays in rather than the ones it was written against.
//!
//! Adding one: a file beside this with `pub fn build(s: *Script) !void`, and a row below. It is
//! then a command ("Demo: <title>", `fizzy.demo.<name>`), `FIZZY_DEMO=<name>` natively and
//! `?demo=<name>` on the web. What a script can aim at is in `docs/AUTOMATION.md`.
const std = @import("std");
const Script = @import("app").automation.Script;

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

/// The tab for `rel`.
pub fn tab(s: *Script, rel: []const u8) ![]const u8 {
    return s.print("workbench.tab:{s}/{s}", .{ s.root, rel });
}

/// The command palette's text field.
pub const palette = "fizzy.palette";

/// The rail's Files icon. A click opens the explorer when it is put away, and puts it away when it
/// is open — on a narrow window, where the explorer is folded rather than closed, too.
pub const files_icon = "fizzy.rail:" ++ @import("workbench").view_files;

/// Open `rel` the way a person who keeps the explorer put away would: open the explorer from the
/// rail, click the file, and put the explorer away again so the editor has the room. A demo's
/// keyframe starts with the explorer put away (`Keyframe.Layout.focused`).
pub fn openFile(s: *Script, rel: []const u8) !void {
    try s.click(.{ .tag = files_icon }, .{});
    try s.click(.{ .tag = try file(s, rel) }, .{});
    try s.waitFor(try editor(s, rel), .{});
    try s.click(.{ .tag = files_icon }, .{});
}
