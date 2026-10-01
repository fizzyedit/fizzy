//! Markdown, previewed as you type: a page written from nothing, its preview following along.
const Script = @import("app").automation.Script;
const catalog = @import("catalog.zig");

const start =
    \\# Release notes
    \\
;

pub fn build(s: *Script) !void {
    try s.keyframe(.{
        .root = "demo://markdown",
        .files = &.{
            .{ .path = "NOTES.md", .text = start },
            .{ .path = "CHANGELOG.md", .text = "# Changelog\n\n## 0.2.0\n\n- Demos that play themselves\n" },
        },
        .open = &.{"NOTES.md"},
        .settings = &.{.{ .owner = "markdown", .key = "default_md_view", .value = ".split" }},
    });

    try s.chapter("Write");
    try s.caption("The raw text on the left, the page on the right — redrawn on every keystroke.", .{ .ms = 5000 });
    try s.waitFor(try catalog.editor(s, "NOTES.md"), .{});
    try s.click(.{ .tag = try catalog.editor(s, "NOTES.md"), .x = 0.85, .y = 0.94 }, .{});
    try s.typeText("\nFizzy can now **play demos** of itself: real input, driven by a tape.\n\n", .{ .cps = 24 });

    try s.chapter("Lists");
    try s.typeText("- pause by clicking anywhere\n- rewind and play forward\n- resume where you left off\n\n", .{ .cps = 24 });

    try s.chapter("Tables");
    try s.caption("Tables line up the moment the separator row is there.", .{ .ms = 4500 });
    // Typed as a person would, so nothing here may be a character the editor pairs (brackets,
    // quotes, backticks): it would close the pair the way it does for them.
    try s.typeText("| You do | The demo does |\n|---|---|\n| click | pauses |\n| press play | catches up and carries on |\n", .{ .cps = 26 });
    s.pause(1200);

    try s.chapter("Another file");
    try s.caption("Every file in the folder is one click away.", .{ .ms = 3500 });
    try s.click(.{ .tag = try catalog.file(s, "CHANGELOG.md") }, .{});
    try s.waitFor(try catalog.editor(s, "CHANGELOG.md"), .{});
    s.pause(2500);
}
