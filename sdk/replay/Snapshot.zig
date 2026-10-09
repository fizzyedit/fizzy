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
//! is the nearest such node it sits in, by index. Rects are physical pixels, rounded.
//!
//! **Taking one** spans a frame: `request` arms dvui's capture of the next, `beginFrame` asks for
//! anchors in it, and `endFrame` writes it out as that frame ends. The app calls the two frame
//! functions once a frame, at its start and its end; `get` reads the text back.
const Snapshot = @This();

const std = @import("std");
const dvui = @import("dvui");
const anchor = @import("anchor.zig");

const CapturedWidget = dvui.Debug.CapturedWidget;

gpa: std.mem.Allocator,
/// Asked for, and not yet taken: the frame dvui captures has not ended.
pending: bool = false,
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
/// widget that marks itself is named.
pub fn beginFrame(self: *Snapshot) void {
    if (self.pending and dvui.debug.capturing) anchor.want();
}

/// At the end of the app's frame, after everything has drawn: the captured frame is written out.
pub fn endFrame(self: *Snapshot) void {
    if (!self.pending or !dvui.debug.capturing) return;
    const frame = dvui.debug.lastCapture() orelse return;
    self.pending = false;
    defer dvui.debug.clearCaptures(dvui.currentWindow().gpa);

    var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena_state.deinit();
    const nodes = build(arena_state.allocator(), frame.widgets.items) catch |err| {
        dvui.log.warn("snapshot: could not build: {t}", .{err});
        return;
    };
    self.text.clearRetainingCapacity();
    var out: std.Io.Writer.Allocating = .fromArrayList(self.gpa, &self.text);
    write(nodes, &out.writer) catch |err| dvui.log.warn("snapshot: could not write: {t}", .{err});
    self.text = out.toArrayList();
    self.taken += 1;
}

/// Snapshot `n`'s text, while it is the last one taken; null before it is, or once another is.
/// Valid until the next snapshot is taken.
pub fn get(self: *const Snapshot, n: u32) ?[]const u8 {
    return if (n == self.taken and n != 0) self.text.items else null;
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

    pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };
};

/// The roles a person acts on: a widget with one is a node even with no tag.
pub fn acted(role: dvui.AccessKit.Role) bool {
    return switch (role) {
        .button, .default_button, .tab, .check_box, .radio_button, .link, .menu_item, .list_box_option, .tree_item, .text_input, .multiline_text_input, .search_input, .slider, .combo_box, .dialog, .alert_dialog => true,
        else => false,
    };
}

/// The nodes of one captured frame, in tree order. Tags come from the window's tag table as the
/// frame left it, so call this in the frame that was captured.
pub fn build(arena: std.mem.Allocator, widgets: []const CapturedWidget) ![]Node {
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
        });
    }
    for (places.items) |p| {
        const within = if (index_of.get(p.data.id)) |i| node_of[i] else null;
        try nodes.append(arena, .{ .tag = p.name, .rect = round(p.data.rect), .parent = within });
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
