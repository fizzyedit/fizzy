//! Keyword **presets**, grouped by the shape that defines them.
//!
//! Keywords are free-form strings — a plugin may invent any it likes, and an app's regions
//! accept any they like. These are the conventions fizzy's own shipped shapes use, published so
//! a plugin can opt into one *visibly*:
//!
//! ```zig
//! host.registerSurface(.{ .id = "pixi.sprites", .keywords = sdk.keywords.ide.sidebar, … });
//! ```
//!
//! Grouping them by shape rather than listing them flat is deliberate. A flat
//! `sidebar_keywords` / `panel_keywords` puts IDE vocabulary on the generic layer and quietly
//! implies every app has a sidebar and a panel. `ide.sidebar` says what it is: *the IDE shape's*
//! sidebar, one convention among several, which an app is free to ignore or replace.
//!
//! A new shape defines its own preset here (or in its own file — nothing here is privileged);
//! adding one never touches the ABI, because these are just string slices.

const std = @import("std");

/// The general IDE shape (`src/editor/layout/ide.zig`): icon rail, left explorer, bottom panel,
/// main area. What most fizzy-based apps start from, and what a plugin written "for fizzy"
/// should target unless it has reason not to.
pub const ide = struct {
    /// The left explorer: file trees, outlines, plugin browsers — things you pick *from*.
    pub const sidebar: []const []const u8 = &.{ "sidebar", "explorer" };
    /// The bottom panel: logs, diagnostics, terminals — things a task *produces*.
    pub const panel: []const []const u8 = &.{ "bottom", "panel", "output" };
    /// The main area: documents, canvases — the thing being worked on.
    pub const main: []const []const u8 = &.{ "main", "center", "workspace" };
};

/// The studio shape (`src/editor/layout/studio.zig`): no file explorer, a large canvas, a
/// right-hand stack, a short bottom strip. Deliberately inverts the IDE arrangement.
///
/// It reuses the IDE's keyword sets rather than inventing synonyms — that is the point of
/// matching on *kind of place* instead of on position. A surface saying "I belong somewhere
/// like a sidebar" lands in the studio's right-hand stack without knowing it moved.
pub const studio = struct {
    pub const stack = ide.sidebar;
    pub const strip = ide.panel;
    pub const canvas = ide.main;
};

/// The key a set of keywords selects under.
///
/// Two regions written with the same keywords share a selection, with nothing wired between
/// them — that is what lets an icon rail and the pane it chooses for agree without either
/// naming the other. Case-insensitive, so `"Sidebar"` and `"sidebar"` are one group.
///
/// Lives here rather than in the layout because `Host` stores the selections and the layout
/// reads them: two implementations of this hash would disagree silently and each look right.
pub fn groupKey(keywords: []const []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    for (keywords) |k| {
        var buf: [64]u8 = undefined;
        const n = @min(k.len, buf.len);
        for (k[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
        h.update(buf[0..n]);
        h.update("\x00");
    }
    return h.final();
}

/// Do two keyword sets share a word? A surface draws in a region exactly when they do.
///
/// Beside `groupKey` for the same reason: `Host.selectedSurface` and `Layout.matching` must
/// agree about what matches, and two implementations of this would disagree silently.
/// Case-insensitive; exact per word, never fuzzy — fuzziness is for suggesting a fix to a
/// keyword that matched nothing, never for the binding itself.
pub fn intersects(a: []const []const u8, b: []const []const u8) bool {
    for (a) |x| for (b) |y| {
        if (std.ascii.eqlIgnoreCase(x, y)) return true;
    };
    return false;
}
