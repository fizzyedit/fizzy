//! A tour of fizzy: tabs that go where they are dragged, places that split and views that float,
//! the window's materials, the plugins everything is made of, and the history kept of every change
//! — about a minute, in chapters a viewer can jump between (the guides view lists them).
//!
//! One keyframe, at the start: each chapter carries on in the window the last one left, a split, a
//! float and all, rather than cutting it back to a fresh one. A snapshot holds the window's
//! arrangement too (`Demo.Snapshot`), so a seek back across a split or a float puts the window
//! back as it was then, rather than replaying from the keyframe.
const Tape = @import("tape").Tape;
const Script = @import("tape").Script;
const catalog = @import("catalog.zig");

const readme =
    \\# Welcome to fizzy
    \\
    \\A small, fast editor built out of plugins. This folder lives in
    \\memory: it belongs to the tour, and nothing in it touches your disk.
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
    \\- [x] a tour that plays itself
    \\- [ ] a tour you can take over
    \\
;

const files = [_]Tape.File{
    .{ .path = "README.md", .text = readme },
    .{ .path = "src/main.zig", .text = main_zig },
    .{ .path = "notes/ideas.md", .text = ideas },
};

/// The tour's folder, cut to: its three files open as tabs, README in front, nothing else showing.
fn scene(s: *Script) !void {
    try s.keyframe(.{
        .root = "demo://tour",
        .files = &files,
        .open = &.{ "src/main.zig", "notes/ideas.md", "README.md" },
        // A preview beside the markdown rather than over it.
        .settings = &.{.{ .owner = "markdown", .key = "default_md_view", .value = ".split" }},
    });
    s.home = catalog.documents;
}

/// Where a caption about a float sits: floats exist only where there is room for them.
fn floatNear(s: *const Script, tag: []const u8) []const u8 {
    return if (s.compact) "" else tag;
}

pub fn build(s: *Script) !void {
    try scene(s);

    try s.chapter("Welcome");
    try s.caption("This is fizzy itself, played by a tape. Click anywhere to take over, and press play to carry on.", .{
        .title = "A tour of fizzy",
        .place = .middle,
        .ms = 4000,
    });
    s.pause(3600);

    try s.chapter("Tabs");
    try s.caption("Tabs go where you drag them.", .{ .near = try catalog.tab(s, "README.md") });
    try s.drag(.{ .tag = try catalog.tab(s, "README.md") }, .{ .tag = try catalog.tab(s, "src/main.zig"), .x = 0.2 }, .{});
    try s.caption("Drop one on the editor's edge, and it opens beside the others.", .{});
    try s.drag(.{ .tag = try catalog.tab(s, "src/main.zig") }, .{ .tag = "drop:right" }, .{ .via = .{ .tag = catalog.documents } });
    try s.waitFor(try catalog.editor(s, "src/main.zig"), .{});
    s.pause(900);

    try s.chapter("Places");
    if (s.compact) {
        // A phone has no rail and no Sidebar place: the bar's icon opens the explorer as a sheet.
        try s.caption("The bar opens the explorer, a sheet over the documents.", .{ .near = catalog.files_tab });
        try s.click(.{ .tag = catalog.files_tab }, .{});
        try s.waitFor(try catalog.file(s, "README.md"), .{});
        s.pause(1800);
        try s.click(.{ .tag = catalog.files_tab }, .{});
        s.pause(900);
    } else {
        try s.caption("The rail opens the explorer, in a place of its own beside the documents.", .{ .near = catalog.files_icon });
        try s.click(.{ .tag = catalog.files_icon }, .{});
        try s.waitFor(try catalog.file(s, "README.md"), .{});
        s.pause(900);
        try s.caption("Every place has a corner. Its button chooses what the place shows…", .{});
        try catalog.cornerButton(s, "role:explorer");
        try s.click(try catalog.corner(s, "role:explorer"), .{ .move_ms = 0 });
        try s.waitFor("region.menu.split-down:role:explorer", .{});
        s.pause(1200);
        try s.caption("…and splits it, for two views one above the other.", .{ .near = "region.menu.split-down:role:explorer" });
        try s.click(.{ .tag = "region.menu.split-down:role:explorer" }, .{});
        s.pause(1200);

        try s.chapter("Floats");
        try s.caption("Carry a view from its corner and drop it on the middle of its own place: it floats.", .{});
        try catalog.cornerButton(s, "role:explorer");
        try s.drag(try catalog.corner(s, "role:explorer"), .{ .tag = try catalog.place(s, "role:explorer") }, .{ .ms = 900 });
        try s.waitFor(try catalog.place(s, "Float 1"), .{});
        try s.waitFor("float-header:Float 1", .{});
        try s.caption("A float goes wherever you carry it by its header.", .{ .near = "float-header:Float 1" });
        try s.drag(.{ .tag = "float-header:Float 1" }, .{ .tag = catalog.documents, .x = 0.45, .y = 0.15 }, .{ .ms = 1000 });
        s.pause(600);
    }

    try s.chapter("Materials");
    try s.commandWith("fizzy.windowMaterial", .{ .kind = "liquid" });
    try s.caption("Over the code you can see what it is made of. The window, its floats, menus and dialogs are one material, Liquid Glass here…", .{ .near = floatNear(s, "float-header:Float 1") });
    s.pause(1800);
    try s.caption("…or frosted…", .{ .near = floatNear(s, "float-header:Float 1") });
    try s.commandWith("fizzy.windowMaterial", .{ .kind = "frost" });
    s.pause(1400);
    try s.caption("…blurred…", .{ .near = floatNear(s, "float-header:Float 1") });
    try s.commandWith("fizzy.windowMaterial", .{ .kind = "blur" });
    s.pause(1400);
    try s.caption("…clear, or opaque. Settings › Window keeps your choice.", .{ .near = floatNear(s, "float-header:Float 1") });
    try s.commandWith("fizzy.windowMaterial", .{ .kind = "transparent" });
    s.pause(1200);
    try s.commandWith("fizzy.windowMaterial", .{ .kind = "none" });
    s.pause(1200);
    try s.commandWith("fizzy.windowMaterial", .{ .kind = "liquid" });
    if (!s.compact) {
        try s.waitFor("float-close:Float 1", .{});
        try s.caption("Close a float, and its views go back where they came from.", .{ .near = "float-close:Float 1" });
        try s.click(.{ .tag = "float-close:Float 1" }, .{});
        try s.waitGone(try catalog.place(s, "Float 1"), .{});
    }
    s.pause(600);

    try s.chapter("Plugins");
    const store = if (s.compact) catalog.store_tab else catalog.store_icon;
    try s.caption("Everything you have seen is a plugin: the files, the editor, the previews, these guides. More are in the store.", .{ .near = store });
    try s.click(.{ .tag = store }, .{});
    s.pause(2600);
    // A sheet covers the documents the next chapter writes in, and a phone has no room beside it.
    if (s.compact) try s.click(.{ .tag = store }, .{});

    try s.chapter("History");
    // On a desktop the store is left open beside it: shutting it would slide the page over just as
    // the pointer went for it. A phone's sheet was put away above.
    try s.click(.{ .tag = try catalog.tab(s, "README.md") }, .{});
    try s.caption("Every change is kept, a step at a time.", try catalog.aboutWriting(s, "README.md"));
    try s.click(.{ .tag = try catalog.end(s, "README.md") }, .{});
    try s.typeText("\n## History\n\nEvery keystroke is a step you can go back to.\n", .{ .cps = 20 });
    s.pause(500);
    try s.caption("The grip at the foot of the page fills as the history grows, full at its limit (Settings › History)…", .{ .near = try catalog.historyGrip(s, "README.md") });
    try s.click(.{ .tag = try catalog.historyGrip(s, "README.md") }, .{});
    try s.waitFor(try catalog.historyLine(s, "README.md"), .{});
    // Shown, not scrubbed: a snapshot puts a document's text back but not its history, so a seek
    // replaying a scrub would land on other text.
    try s.moveTo(.{ .tag = try catalog.historyLine(s, "README.md"), .x = 0.35 }, .{});
    try s.caption("…and dragging along it goes back through every step. A stretch of it is a tape to share, as this tour is.", .{ .near = try catalog.historyLine(s, "README.md") });
    s.pause(3200);

    try s.chapter("Your turn");
    try s.caption(if (s.compact) "That's the tour. Find it again, and more, in Guides." else "That's the tour. Find it again, and more, in Guides on the rail.", .{
        .title = "Your turn",
        .place = .middle,
        .ms = 4000,
    });
    s.pause(3600);
}
