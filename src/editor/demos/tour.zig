//! A tour of fizzy: the explorer, editing, the command palette and a live markdown preview — a
//! minute and a half, in chapters a viewer can jump between.
const Script = @import("app").automation.Script;
const catalog = @import("catalog.zig");

const readme =
    \\# Welcome to fizzy
    \\
    \\A small, fast editor built out of plugins. This folder lives in
    \\memory: it belongs to the demo, and nothing in it touches your disk.
    \\
    \\- Files open from the explorer on the left
    \\- The command palette runs anything
    \\- Markdown previews as you type
    \\
;

const main_zig =
    \\const std = @import("std");
    \\
    \\pub fn main() void {
    \\    std.debug.print("hello, {s}!\n", .{"fizzy"});
    \\}
    \\
;

const ideas =
    \\# Ideas
    \\
    \\- [x] a demo that plays itself
    \\- [ ] a demo that writes itself
    \\
;

pub fn build(s: *Script) !void {
    try s.keyframe(.{
        .root = "demo://tour",
        .files = &.{
            .{ .path = "README.md", .text = readme },
            .{ .path = "src/main.zig", .text = main_zig },
            .{ .path = "notes/ideas.md", .text = ideas },
        },
        // What the script types assumes an editor that closes brackets, and a preview beside the
        // markdown rather than over it.
        .settings = &.{
            .{ .owner = "text", .key = "auto_close_brackets", .value = "true" },
            .{ .owner = "markdown", .key = "default_md_view", .value = ".split" },
        },
    });

    try s.chapter("Welcome");
    try s.caption("This is fizzy itself, driving its own controls. Click, scroll or press a key at any time to take over; press play to carry on.", .{
        .title = "A tour of fizzy",
        .place = .middle,
        .ms = 8500,
        .hold = true,
    });

    try s.chapter("The explorer");
    try s.caption("The project folder is in the explorer, a click away on the rail. Folders open with a click, and files open in tabs.", .{});
    s.pause(1500);
    try s.click(.{ .tag = catalog.files_icon }, .{});
    try s.click(.{ .tag = try catalog.file(s, "src") }, .{});
    try s.click(.{ .tag = try catalog.file(s, "src/main.zig") }, .{});
    try s.waitFor(try catalog.editor(s, "src/main.zig"), .{});
    s.pause(800);
    try s.caption("Put the explorer away again, and the editor has the room.", .{});
    try s.click(.{ .tag = catalog.files_icon }, .{});
    s.pause(2400);

    try s.chapter("Editing");
    try s.caption("Typing is typing: brackets close themselves, and Enter keeps the indent.", .{});
    // Below the last line, at the right: the caret lands at the end of the file.
    try s.click(.{ .tag = try catalog.editor(s, "src/main.zig"), .x = 0.85, .y = 0.92 }, .{});
    try s.typeText("\npub fn greet(name: []const u8) void {\nstd.debug.print(\"hi, {s}\\n\", .{name});", .{});
    s.pause(1400);

    try s.chapter("The command palette");
    try s.caption("Every action is a command, and the palette finds commands by name.", .{});
    s.pause(2000);
    try s.command("fizzy.commandPalette");
    try s.waitFor(catalog.palette, .{});
    try s.typeText("toggle explorer", .{});
    s.pause(400);
    try s.key("enter");
    try s.caption("Enter runs it, and the explorer is back\u{2026}", .{});
    s.pause(2400);
    try s.caption("\u{2026}and its shortcut puts it away again.", .{});
    s.pause(800);
    try s.command("fizzy.toggleExplorer");
    s.pause(2000);

    try s.chapter("Markdown");
    try s.caption("Markdown opens beside its preview, which follows every keystroke.", .{});
    try catalog.openFile(s, "README.md");
    s.pause(500);
    try s.click(.{ .tag = try catalog.editor(s, "README.md"), .x = 0.85, .y = 0.94 }, .{});
    try s.typeText("\n## Your turn\n\nPress **play** to watch again, or click anywhere and make it yours.\n", .{ .cps = 18 });
    s.pause(2400);

    try s.chapter("Your turn");
    try s.caption("That's the tour. Everything you saw is the real editor: pause, rewind, or take over at any moment.", .{
        .title = "Your turn",
        .place = .middle,
        .ms = 8000,
        .hold = true,
    });
}
