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

/// The general IDE shape (`src/editor/shell/ide.zig`): icon rail, left explorer, bottom panel,
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

/// The studio shape (`src/editor/shell/studio.zig`): no file explorer, a large canvas, a
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
