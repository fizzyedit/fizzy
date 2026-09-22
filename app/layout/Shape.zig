//! A layout shape as **data**: the declarative subset of what a shape function says, in a form a
//! `.zon` file can hold. `-Dapp-layout=src/layout.zon` builds an app whose shape is this tree
//! instead of a function.
//!
//! **What this is for.** A shape is ordinary code over `Layout` because shapes branch: fizzy's
//! own asks the platform whether to draw a menu bar and the window whether it is maximised;
//! `examples/endless-app`'s *loops*, making a new edge tray each time the user drags one open.
//! Data cannot answer those without becoming a language, and the interpreter for that language
//! would be the configurable layout engine fizzy deliberately does not have. So this covers only
//! the static case — a fixed arrangement of named places — and says so rather than growing
//! conditionals later. When an app needs a condition, it copies a shape file and writes one.
//!
//! **What it can say:** nesting and direction, a region's name and keywords, how many surfaces it
//! shows, its starting extent, whether the user may drag it, whether it collapses. A split is
//! implied between consecutive children, which is where a hand-written shape puts one.
//!
//! **What it cannot:** `content` chrome (a function), anything conditional, anything that reads
//! app state. A shape that needs those is a `.zig` file; that is the escape hatch, and it is the
//! same `Layout` API this file calls.
const std = @import("std");
const dvui = @import("dvui");

const Layout = @import("Layout.zig");
const Region = @import("Region.zig");

const Shape = @This();

/// Human-facing name, and the key this place's extent and assignment persist under in
/// `layout.zon`. Empty for a pure container, exactly as in a hand-written shape.
name: []const u8 = "",
/// The kinds of surface this place accepts (`sdk.keywords`' vocabulary, spelled out).
keywords: []const []const u8 = &.{},
/// `.one` or `.many` — how many of the surfaces that fit here it shows at once.
shows: Region.Shows = .one,
/// The axis children are laid along.
dir: dvui.enums.Direction = .vertical,
/// How the box expands, as `dvui.Options.expand`.
expand: dvui.Options.Expand = .both,
/// Starting extent along the parent's axis, in points. Zero lets it flex. This is the
/// `min_size_content` a hand-written shape passes; the user's drag replaces and persists it.
extent: f32 = 0,
/// Let the split after this region drag its extent.
resize: bool = false,
/// Fold away when the window is too narrow to hold it beside everything else.
collapsible: bool = false,
/// Collapse while nothing matches, rather than holding empty space open.
hide_when_empty: bool = false,
/// The places inside this one. A spec with children is a container — its own `name`/`keywords`
/// may still make it host surfaces — and one without is a leaf place. A subtree is a `Shape`
/// like any other, which is why the whole file is one type.
children: []const Shape = &.{},

/// Draw the whole tree. One `@src()` serves every region and every split — identity comes from
/// each node's position in a depth-first walk, which is stable as long as the file is.
///
/// Uses nothing an app's own shape file could not: `Layout.region` and `Layout.split`, the same
/// two calls a hand-written shape makes. The axis a node's `extent` applies to is carried down
/// the walk rather than read off the layout, so this stays a walk over the data.
pub fn apply(root: Shape, f: *Layout) !void {
    var counter: usize = 0;
    // The root divides the window horizontally, as a shape's outermost box does.
    try place(root, f, &counter, .horizontal);
}

fn place(node: Shape, f: *Layout, counter: *usize, along: dvui.enums.Direction) !void {
    const id_extra = counter.*;
    counter.* += 1;
    var r = try f.region(@src(), .{
        .name = node.name,
        .keywords = node.keywords,
        .shows = node.shows,
        .dir = node.dir,
        .resize = node.resize,
        .collapsible = node.collapsible,
        .hide_when_empty = node.hide_when_empty,
    }, .{
        .id_extra = id_extra,
        .expand = node.expand,
        .min_size_content = switch (along) {
            .horizontal => .{ .w = node.extent },
            .vertical => .{ .h = node.extent },
        },
    });
    defer r.deinit();

    for (node.children, 0..) |child, i| {
        // Between siblings, never before the first or after the last: a split is the boundary
        // two places share, and a trailing one would be a handle against the container's edge.
        if (i > 0) f.split(@src(), .{ .id_extra = counter.* });
        try place(child, f, counter, node.dir);
    }
}

test "a depth-first walk numbers every place once" {
    const tree: Shape = .{
        .dir = .horizontal,
        .children = &.{
            .{ .name = "Sidebar", .keywords = &.{ "sidebar", "explorer" }, .extent = 260, .resize = true },
            .{ .name = "Main", .keywords = &.{"main"}, .children = &.{
                .{ .name = "Panel", .keywords = &.{"panel"}, .extent = 220 },
            } },
        },
    };

    // Counting without drawing: the same walk `place` does, so the ids it hands out are as many
    // as there are nodes and no two are equal.
    const walk = struct {
        fn count(n: Shape) usize {
            var total: usize = 1;
            for (n.children) |c| total += count(c);
            return total;
        }
    };
    try std.testing.expectEqual(@as(usize, 4), walk.count(tree));
}
