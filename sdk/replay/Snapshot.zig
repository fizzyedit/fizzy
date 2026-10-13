//! What is on screen, as text: each widget a person could act on or a tape could aim at, with
//! what it is, what it is called, the name a tape aims at, where it is, and what it sits in.
//!
//! For a caller that reads the app rather than looks at it — a plugin's test, an automation
//! client, a recorder choosing a name for what was clicked — where a picture would cost far more
//! than the words that say the same. A snapshot is ZON:
//!
//! ```
//! .{
//!     .{ .role = "tab", .name = "Files", .tag = "fizzy.rail:files", .rect = .{ .x = 8, .y = 52, .w = 40, .h = 40 } },
//!     .{ .role = "button", .name = "Close Tab", .rect = .{ … }, .parent = 3 },
//! }
//! ```
//!
//! **Where the names come from**, all of it dvui's own, so any dvui app gets them:
//! - `role` and `name` from dvui's frame capture (`dvui.debug.captureFrame`): a widget's
//!   `Options.role`, and its name by the rule screen readers use — its `label` text, the label
//!   widget it points at, or the text of a label inside it (how `dvui.button("Save")` is named).
//! - `tag` from the frame's tags (`Options.tag`, and `anchor.mark`'s names built from data).
//!
//! A node is a visible widget with a role worth acting on (`acted`), a tag, or the focus; `parent`
//! is the nearest such node it sits in, by index. Rects are physical pixels of the frame, rounded.
//!
//! **Windows.** An app that shows parts of its one frame in OS windows of their own — a dialog, a
//! menu, a view popped out — says which (`windows`): each is a node first, `.role = "window"`,
//! named by its title, with the tag a tape aims into it by and the part of the frame it shows; the
//! main window is the first. A node in any other window says which, by index (`.window = 2`); one
//! in the main window says nothing. Its rect is still in the frame, as a tape's point is, so a
//! click aimed at it lands in its window.
//!
//! **Taking one** spans a frame: `request` arms dvui's capture of the next, `beginFrame` asks for
//! anchors in it, and `endFrame` writes it out once that frame has drawn everything — its dialogs
//! too. The app calls the two frame functions once a frame, at its start and at its very end
//! (after `Window.drawRetained`); `get` reads the text back. dvui stops its capture before it shows
//! dialogs, so a dialog's frame captures the dialog itself (`scopeBegin`).
const Snapshot = @This();

const std = @import("std");
const dvui = @import("dvui");
const anchor = @import("anchor.zig");

const CapturedWidget = dvui.Debug.CapturedWidget;

gpa: std.mem.Allocator,
/// The app's OS windows, when it has more than one. Null: everything is in the one window.
windows: ?Windows = null,
/// Asked for, and not yet taken: the frame dvui captures has not ended.
pending: bool = false,
/// The capture of the frame being taken (`Debug.CapturedFrame.index`), from its start
/// (`beginFrame`) to its end: it, and each dialog's scope captured after it.
frame: ?u64 = null,
/// How many have been taken; the last one's text is `text`.
taken: u32 = 0,
text: std.ArrayListUnmanaged(u8) = .empty,

pub fn init(gpa: std.mem.Allocator) Snapshot {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Snapshot) void {
    self.text.deinit(self.gpa);
}

/// Take a snapshot of the next frame. Returns the number it will have (`get`); asking again
/// before it is taken returns the same number.
pub fn request(self: *Snapshot) u32 {
    if (!self.pending) {
        self.pending = true;
        dvui.debug.captureFrame();
        dvui.refresh(null, @src(), null);
    }
    return self.taken + 1;
}

/// At the start of the app's frame, before anything draws: in the frame being captured, every
/// widget that marks itself is named, and a dialog captures itself (`scopeBegin`).
pub fn beginFrame(self: *Snapshot) void {
    if (!self.pending or self.frame != null or !dvui.debug.capturing) return;
    const f = dvui.debug.lastCapture() orelse return;
    self.frame = f.index;
    anchor.want();
    dvui.dataSet(null, taking_id, taking_key, dvui.currentWindow().frame_time_ns);
}

/// At the very end of the app's frame, after everything has drawn — dvui's dialogs too
/// (`Window.drawRetained`): the captured frame is written out.
pub fn endFrame(self: *Snapshot) void {
    const first = self.frame orelse return;
    self.frame = null;
    self.pending = false;
    defer dvui.debug.clearCaptures(dvui.currentWindow().gpa);

    var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const nodes = self.collect(arena, first) catch |err| {
        dvui.log.warn("snapshot: could not build: {t}", .{err});
        return;
    };
    self.text.clearRetainingCapacity();
    var out: std.Io.Writer.Allocating = .fromArrayList(self.gpa, &self.text);
    write(nodes, &out.writer) catch |err| dvui.log.warn("snapshot: could not write: {t}", .{err});
    self.text = out.toArrayList();
    self.taken += 1;
}

/// The nodes of the frame whose capture is `first`: its build phase's widgets, then each dialog's,
/// captured on its own after it.
fn collect(self: *const Snapshot, arena: std.mem.Allocator, first: u64) ![]Node {
    var widgets: std.ArrayListUnmanaged(CapturedWidget) = .empty;
    for (dvui.debug.frames.items) |*f| {
        if (f.index >= first) try widgets.appendSlice(arena, f.widgets.items);
    }
    const windows: []const Window = if (self.windows) |w| w.list(w.ctx, arena) else &.{};
    return build(arena, widgets.items, windows);
}

/// Snapshot `n`'s text, while it is the last one taken; null before it is, or once another is.
/// Valid until the next snapshot is taken.
pub fn get(self: *const Snapshot, n: u32) ?[]const u8 {
    return if (n == self.taken and n != 0) self.text.items else null;
}

const taking_id: dvui.Id = @enumFromInt(0x6669_7a7a_736e_6170); // "fizzsnap"
const taking_key = "_snapshot_at";

/// Whether a snapshot is being taken of this frame (`beginFrame`). Shared through the window's
/// data, so a plugin dylib's copy of this file agrees.
pub fn taking() bool {
    const cw = dvui.current_window orelse return false;
    const at = dvui.dataGet(cw, taking_id, taking_key, i128) orelse return false;
    return at == cw.frame_time_ns;
}

/// Around a dialog's drawing, in its display function: dvui shows dialogs after it has stopped
/// capturing the frame (`Window.drawRetained`), so in a frame being taken a dialog captures its own
/// widgets, a scope of dvui's (`Debug.captureScopeBegin`) that `endFrame` reads with the frame.
/// True when one began: hand it to `scopeEnd`. Nothing, and false, in any other frame.
pub fn scopeBegin() bool {
    if (dvui.debug.capturing or !taking()) return false;
    dvui.debug.captureScopeBegin(dvui.currentWindow().gpa);
    return true;
}

/// End what `scopeBegin` began.
pub fn scopeEnd(began: bool) void {
    if (began) dvui.debug.captureScopeEnd();
}

/// One of the app's OS windows this frame (`Windows`).
pub const Window = struct {
    /// The tag that aims into it (`Tape.Target.tag`): a tape points at a fraction of it, or at
    /// natural pixels from its corner. What a picture of it is asked for by, too.
    tag: []const u8,
    /// What it is called: its title.
    title: []const u8 = "",
    /// The part of the frame it shows, physical.
    rect: dvui.Rect.Physical,
    /// The subwindow it shows: every widget drawn in it is in this window, wherever it lies.
    subwindow: ?dvui.Id = null,
    /// Whatever is drawn in `rect` is in it too: a window showing a band of the frame of its own,
    /// past the main window, where what opens in it lies (its tooltips). Not a window over the
    /// main window's part of the frame — a dialog's, a menu's — which shows its subwindow only.
    area: bool = false,
};

/// Where the app's OS windows come from, asked as a snapshot is written.
pub const Windows = struct {
    ctx: *anyopaque,
    /// This frame's, in `arena`: the main window first, then the others bottom to top.
    list: *const fn (ctx: *anyopaque, arena: std.mem.Allocator) []const Window,
};

/// Which of `windows` widget `id`, drawn in `subwindow` with its middle at `mid`, is in: by index,
/// null for the main window. A subwindow's own widget is drawn in the one under it, and is in its
/// own window.
pub fn windowOf(windows: []const Window, id: ?dvui.Id, subwindow: ?dvui.Id, mid: dvui.Point.Physical) ?u32 {
    if (windows.len < 2) return null;
    for (windows[1..], 1..) |w, i| {
        const sw = w.subwindow orelse continue;
        if (sw == id or sw == subwindow) return @intCast(i);
    }
    var i = windows.len;
    while (i > 1) {
        i -= 1;
        if (windows[i].area and windows[i].rect.contains(mid)) return @intCast(i);
    }
    return null;
}

/// One thing on screen.
pub const Node = struct {
    /// What it is: a `dvui.AccessKit.Role`'s name, for one a person acts on.
    role: ?[]const u8 = null,
    /// What a person calls it.
    name: ?[]const u8 = null,
    /// The name a tape aims at (`Tape.Target.tag`).
    tag: ?[]const u8 = null,
    rect: Rect,
    focused: bool = false,
    /// The node it sits in, by index; none at the top.
    parent: ?u32 = null,
    /// The window it is in, by its node's index; none for the main window (`Window`).
    window: ?u32 = null,

    pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };
};

/// The roles a person acts on: a widget with one is a node even with no tag.
pub fn acted(role: dvui.AccessKit.Role) bool {
    return switch (role) {
        .button, .default_button, .tab, .check_box, .radio_button, .link, .menu_item, .list_box_option, .tree_item, .text_input, .multiline_text_input, .search_input, .slider, .combo_box, .dialog, .alert_dialog => true,
        else => false,
    };
}

/// The nodes of one captured frame, in tree order, after a node for each of `windows`. Tags come
/// from the window's tag table as the frame left it, so call this in the frame that was captured.
pub fn build(arena: std.mem.Allocator, widgets: []const CapturedWidget, windows: []const Window) ![]Node {
    // Each widget's tag: `Options.tag`, or the name a mark gave it this frame. A mark on a place
    // within a widget (`anchor.markRect`) is a node of its own, inside it.
    var tags: std.AutoHashMapUnmanaged(dvui.Id, []const u8) = .empty;
    var places: std.ArrayListUnmanaged(struct { name: []const u8, data: dvui.TagData }) = .empty;
    {
        var it = dvui.currentWindow().tags.iterator();
        while (it.next_used()) |e| {
            const td = e.value_ptr.*;
            if (!td.visible) continue;
            const tag_name = e.key_ptr.*;
            // A window's own: its node.
            if (for (windows) |w| {
                if (std.mem.eql(u8, w.tag, tag_name)) break true;
            } else false) continue;
            const owner: ?*const CapturedWidget = for (widgets) |*w| {
                if (w.id == td.id) break w;
            } else null;
            if (owner) |w| {
                // Its own `Options.tag`, already on the widget: dvui files that one under a rect
                // of its own choosing.
                if (w.tag) |t| if (std.mem.eql(u8, t, tag_name)) continue;
                if (std.meta.eql(w.rect_border, td.rect)) {
                    try tags.put(arena, td.id, tag_name);
                    continue;
                }
            }
            try places.append(arena, .{ .name = tag_name, .data = td });
        }
    }

    var nodes: std.ArrayListUnmanaged(Node) = .empty;
    for (windows) |w| try nodes.append(arena, .{
        .role = "window",
        .name = if (w.title.len > 0) w.title else null,
        .tag = w.tag,
        .rect = round(w.rect),
    });
    // The node each widget is, or sits in: by widget index.
    const node_of = try arena.alloc(?u32, widgets.len);
    var index_of: std.AutoHashMapUnmanaged(dvui.Id, usize) = .empty;
    for (widgets, 0..) |*w, i| {
        try index_of.put(arena, w.id, i);
        const up: ?u32 = if (w.parent_id != w.id) if (index_of.get(w.parent_id)) |p| node_of[p] else null else null;
        node_of[i] = up;
        if (!w.visible) continue;
        const tag = w.tag orelse tags.get(w.id);
        const role_acted = if (w.role) |r| acted(r) else false;
        if (tag == null and !role_acted and !w.focused) continue;
        node_of[i] = @intCast(nodes.items.len);
        try nodes.append(arena, .{
            .role = if (role_acted) @tagName(w.role.?) else null,
            // A container is named only by its own label: the text inside a region or a pane is
            // its contents, not what it is called.
            .name = name(widgets, i, role_acted),
            .tag = tag,
            .rect = round(w.rect_border),
            .focused = w.focused,
            .parent = up,
            .window = windowOf(windows, w.id, w.subwindow_id, w.rect_border.center()),
        });
    }
    for (places.items) |p| {
        const owner = index_of.get(p.data.id);
        const within = if (owner) |i| node_of[i] else null;
        const subwindow = if (owner) |i| widgets[i].subwindow_id else null;
        try nodes.append(arena, .{ .tag = p.name, .rect = round(p.data.rect), .parent = within, .window = windowOf(windows, p.data.id, subwindow, p.data.rect.center()) });
    }
    return nodes.items;
}

/// `nodes` as ZON, a node a line: small, and two snapshots diff line by line.
pub fn write(nodes: []const Node, w: *std.Io.Writer) !void {
    try w.writeAll(".{\n");
    for (nodes) |node| {
        try w.writeAll("    ");
        try std.zon.stringify.serialize(node, .{ .whitespace = false, .emit_default_optional_fields = false }, w);
        try w.writeAll(",\n");
    }
    try w.writeAll("}\n");
}

fn round(r: dvui.Rect.Physical) Node.Rect {
    return .{ .x = @intFromFloat(@round(r.x)), .y = @intFromFloat(@round(r.y)), .w = @intFromFloat(@round(r.w)), .h = @intFromFloat(@round(r.h)) };
}

/// The name widget `i` goes by, or null when it has none: its `label` text, the label widget it
/// points at, or — `from_content`, for a button, tab or the like — the text of a label inside it.
pub fn name(widgets: []const CapturedWidget, i: usize, from_content: bool) ?[]const u8 {
    const w = &widgets[i];
    if (w.label) |l| switch (l) {
        .text => |t| return t,
        .by_id => |id| for (widgets) |*o| {
            if (o.id == id) return o.text;
        },
        // The label widget just before or after it in the tree.
        .label_widget => |dir| {
            var j = i;
            while (if (dir == .next) j + 1 < widgets.len else j > 0) {
                j = if (dir == .next) j + 1 else j - 1;
                if (widgets[j].role == .label) return widgets[j].text;
            }
        },
        .for_id => {},
    };
    if (!from_content) return null;
    // Named by a label inside it: any descendant's text.
    var inside: [64]dvui.Id = undefined;
    inside[0] = w.id;
    var n: usize = 1;
    for (widgets[i + 1 ..]) |*o| {
        const within = for (inside[0..n]) |id| {
            if (o.parent_id == id) break true;
        } else false;
        if (!within) continue;
        if (o.role == .label) if (o.text) |t| if (t.len > 0) return t;
        if (n < inside.len) {
            inside[n] = o.id;
            n += 1;
        }
    }
    return null;
}

// ---- tests ---------------------------------------------------------------------------------

var test_snapshot: Snapshot = undefined;

fn testFrame() !dvui.App.Result {
    test_snapshot.beginFrame();
    defer test_snapshot.endFrame();
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer box.deinit();
    _ = dvui.button(@src(), "Save", .{}, .{ .tag = "demo.save" });
    // An icon-only button: named by its label, not by anything it shows.
    var close = dvui.box(@src(), .{}, .{ .role = .button, .label = .{ .text = "Close" }, .min_size_content = .{ .w = 10, .h = 10 } });
    close.deinit();
    // A mark, named from data, only while someone asked.
    var area = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = 20, .h = 20 } });
    anchor.mark(area.data(), "demo.area:{s}", .{"one"});
    area.deinit();
    // Nothing to act on and no name: not a node.
    dvui.label(@src(), "plain", .{}, .{});
    return .ok;
}

test "a snapshot names what a person acts on, and what a tape aims at" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    test_snapshot = .init(std.testing.allocator);
    defer test_snapshot.deinit();

    try dvui.testing.settle(testFrame);
    const n = test_snapshot.request();
    try std.testing.expectEqual(n, test_snapshot.request());
    try std.testing.expect(test_snapshot.get(n) == null);
    // The capture begins at the next frame's start: one step arms it, the next is captured.
    for (0..3) |_| {
        if (test_snapshot.get(n) != null) break;
        _ = try dvui.testing.step(testFrame);
    }
    const text = test_snapshot.get(n) orelse return error.TestUnexpectedResult;

    // It reads back as what it says: two buttons by name, the tagged one by its tag, the mark.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const nodes = try std.zon.parse.fromSliceAlloc([]const Node, arena.allocator(), try arena.allocator().dupeZ(u8, text), null, .{});
    var buttons: usize = 0;
    var save = false;
    var close = false;
    var area = false;
    for (nodes) |node| {
        if (node.role) |r| if (std.mem.eql(u8, r, "button")) {
            buttons += 1;
        };
        if (node.name) |nm| {
            if (std.mem.eql(u8, nm, "Save")) save = node.tag != null and std.mem.eql(u8, node.tag.?, "demo.save");
            if (std.mem.eql(u8, nm, "Close")) close = true;
        }
        if (node.tag) |tg| if (std.mem.eql(u8, tg, "demo.area:one")) {
            area = node.role == null;
        };
    }
    try std.testing.expectEqual(@as(usize, 2), buttons);
    try std.testing.expect(save and close and area);
    try std.testing.expect(std.mem.indexOf(u8, text, "plain") == null);
    // The capture is let go once written.
    try std.testing.expectEqual(@as(usize, 0), dvui.debug.capturedFrameCount());
}

var test_dialog_window: dvui.Id = .zero;
var test_band: dvui.Rect.Physical = .{};

fn testDialog(id: dvui.Id) anyerror!void {
    const began = scopeBegin();
    defer scopeEnd(began);
    var win = dvui.floatingWindow(@src(), .{}, .{ .id_extra = id.asUsize(), .rect = .{ .x = 10, .y = 10, .w = 80, .h = 40 } });
    defer win.deinit();
    test_dialog_window = win.data().id;
    _ = dvui.button(@src(), "Go ahead", .{}, .{});
}

fn testWindowsFrame() !dvui.App.Result {
    test_snapshot.beginFrame();
    {
        var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
        defer box.deinit();
        _ = dvui.button(@src(), "Main", .{}, .{});
        // Drawn in a part of the frame another window shows: in that window, by where it is.
        var band = dvui.floatingWindow(@src(), .{}, .{ .rect = .{ .x = 200, .y = 200, .w = 80, .h = 40 } });
        defer band.deinit();
        test_band = band.data().rectScale().r;
        _ = dvui.button(@src(), "Banded", .{}, .{});
    }
    // dvui shows its dialogs here, its capture of the frame already stopped; the snapshot is
    // written after.
    dvui.currentWindow().drawRetained(.{});
    test_snapshot.endFrame();
    return .ok;
}

fn testWindows(_: *anyopaque, arena: std.mem.Allocator) []const Window {
    const list = arena.dupe(Window, &.{
        .{ .tag = "app.window:main", .title = "App", .rect = dvui.windowRectPixels() },
        .{ .tag = "app.window:band", .rect = test_band, .area = true },
        .{ .tag = "app.window:dialog", .title = "Ask", .rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 }, .subwindow = test_dialog_window },
    }) catch return &.{};
    return list;
}

test "a snapshot has the dialogs dvui shows after its capture, and says which window each thing is in" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    test_snapshot = .init(std.testing.allocator);
    defer test_snapshot.deinit();
    var ctx: u8 = 0;
    test_snapshot.windows = .{ .ctx = &ctx, .list = testWindows };

    const id_mutex = dvui.dialogAdd(null, @src(), 0, testDialog);
    id_mutex.mutex.unlock(dvui.io);
    try dvui.testing.settle(testWindowsFrame);
    const n = test_snapshot.request();
    for (0..3) |_| {
        if (test_snapshot.get(n) != null) break;
        _ = try dvui.testing.step(testWindowsFrame);
    }
    const text = test_snapshot.get(n) orelse return error.TestUnexpectedResult;

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const nodes = try std.zon.parse.fromSliceAlloc([]const Node, arena.allocator(), try arena.allocator().dupeZ(u8, text), null, .{});
    // The windows first, each a node.
    try std.testing.expect(nodes.len > 3);
    for (nodes[0..3], [_][]const u8{ "app.window:main", "app.window:band", "app.window:dialog" }) |node, tag| {
        try std.testing.expectEqualStrings("window", node.role.?);
        try std.testing.expectEqualStrings(tag, node.tag.?);
    }
    try std.testing.expectEqualStrings("Ask", nodes[2].name.?);
    // Each button in the window it is drawn for: the dialog's, drawn after dvui's capture stopped,
    // there at all.
    var seen: usize = 0;
    for (nodes[3..]) |node| {
        // A floating window is in its window too, though dvui draws it in the one under it.
        if (std.mem.eql(u8, node.role orelse "", "dialog")) try std.testing.expect(node.window != null);
        if (!std.mem.eql(u8, node.role orelse "", "button")) continue;
        const nm = node.name orelse continue;
        if (std.mem.eql(u8, nm, "Main")) {
            try std.testing.expectEqual(@as(?u32, null), node.window);
            seen += 1;
        } else if (std.mem.eql(u8, nm, "Banded")) {
            try std.testing.expectEqual(@as(?u32, 1), node.window);
            seen += 1;
        } else if (std.mem.eql(u8, nm, "Go ahead")) {
            try std.testing.expectEqual(@as(?u32, 2), node.window);
            seen += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), seen);
    try std.testing.expectEqual(@as(usize, 0), dvui.debug.capturedFrameCount());
    // Taken, nothing more is captured: a dialog drawn in a frame nobody asked for is free.
    try std.testing.expect(!taking());
}
