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

/// The general IDE shape (`src/editor/layout.zig`): icon rail, left explorer, bottom panel,
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

/// Do two keyword sets share a word?
///
/// The symmetric, unqualified rule — "are these two talking about the same kind of place at
/// all". Use it to look a region *up* by a vocabulary you already hold (`State.regionFor`, a
/// command that wants the sidebar). For deciding whether a surface belongs in a region, use
/// `accepts`, which is asymmetric and understands qualified names.
pub fn intersects(a: []const []const u8, b: []const []const u8) bool {
    for (a) |x| for (b) |y| {
        if (std.ascii.eqlIgnoreCase(x, y)) return true;
    };
    return false;
}

// ── Qualified keywords ─────────────────────────────────────────────────────────────────────────
//
// A keyword may name a place *inside* another, dot-separated: `main.document` is the document
// place within the main area. A region declared inside another region qualifies its keywords with
// the enclosing region's name automatically, so a shape writes `.keywords = &.{"document"}` and
// the region ends up accepting `main.document` — see `Layout.State.qualify`.
//
// This is what makes sub-regions addressable without a new concept. A plugin keeps saying what
// *kind* of place it wants and lands in the specific one; a plugin that knows fizzy's shape can
// name the specific one; and an app whose shape has no such sub-place still takes the surface in
// the nearest enclosing region rather than dropping it.

/// How well one region keyword fits one surface keyword. Ordered: a stronger fit wins.
pub const Fit = enum(u8) {
    /// Unrelated words.
    none = 0,
    /// The surface named a place *inside* this one — region `main`, surface `main.document`. The
    /// specific place does not exist in this shape, so the enclosing one takes the surface. A
    /// plugin written for a nested layout still appears in a flat one.
    place = 1,
    /// The region qualified a kind the surface named — region `main.document`, surface
    /// `document`. The ordinary case for a sub-region: the plugin says what it is, the shape says
    /// where that lives.
    kind = 2,
    /// The same word.
    exact = 3,
};

/// Is `path` `base` with ancestors in front of it — `main.document` for `document`? Segment
/// boundaries only, so `mainly` is not inside `main`.
fn qualifies(path: []const u8, base: []const u8) bool {
    if (path.len <= base.len + 1) return false;
    const at = path.len - base.len;
    return path[at - 1] == '.' and std.ascii.eqlIgnoreCase(path[at..], base);
}

/// Is `path` somewhere inside `place` — `main.document` within `main`? The other end of the same
/// relation, and a separate function because which end a name is qualified at is the whole
/// difference between the two directions in `Fit`.
fn under(path: []const u8, place: []const u8) bool {
    if (path.len <= place.len + 1) return false;
    return path[place.len] == '.' and std.ascii.eqlIgnoreCase(path[0..place.len], place);
}

pub fn fit(region_word: []const u8, surface_word: []const u8) Fit {
    if (std.ascii.eqlIgnoreCase(region_word, surface_word)) return .exact;
    if (qualifies(region_word, surface_word)) return .kind;
    if (under(surface_word, region_word)) return .place;
    return .none;
}

/// How strongly a region accepts a surface: the best fit across every pair of their keywords.
///
/// The *best* rather than a count of matches. A surface naming three synonyms of one place has
/// not made a stronger claim than a surface naming it once — but a surface naming the exact
/// sub-place has, and that is the distinction the claim rule in `Layout.matching` needs.
pub fn strength(region: []const []const u8, surface: []const []const u8) Fit {
    var best: Fit = .none;
    for (region) |r| for (surface) |s| {
        const f = fit(r, s);
        if (@intFromEnum(f) > @intFromEnum(best)) best = f;
    };
    return best;
}

/// Does a region accept a surface? The whole binding rule, and asymmetric: the region's keywords
/// come first because a qualified region accepting a general kind is not the same statement as a
/// general region accepting a qualified kind.
///
/// Beside `groupKey` for the same reason it always was: `Host.selectedSurface` and
/// `Layout.matching` must agree about what belongs where, and two implementations of this would
/// disagree silently and each look right. Case-insensitive; exact per path segment, never fuzzy —
/// fuzziness is for suggesting a fix to a keyword that matched nothing, never for the binding.
pub fn accepts(region: []const []const u8, surface: []const []const u8) bool {
    return strength(region, surface) != .none;
}

test "a word fits itself, its qualifications and its ancestors" {
    try std.testing.expectEqual(Fit.exact, fit("sidebar", "Sidebar"));
    try std.testing.expectEqual(Fit.kind, fit("main.document", "document"));
    try std.testing.expectEqual(Fit.kind, fit("main.pane.document", "pane.document"));
    try std.testing.expectEqual(Fit.place, fit("main", "main.document"));
    try std.testing.expectEqual(Fit.none, fit("main.document", "sidebar"));
    // Not a segment boundary, so not a relation: `mainly` is not inside `main`.
    try std.testing.expectEqual(Fit.none, fit("mainly", "main"));
    try std.testing.expectEqual(Fit.none, fit("document", "maindocument"));
    // A trailing kind, not any segment: a preview place is not a document place.
    try std.testing.expectEqual(Fit.none, fit("main.document.preview", "document"));
}

test "a region accepts the kind it qualifies, and a surface asking for a place it contains" {
    const main: []const []const u8 = &.{ "main", "center", "workspace" };
    const pane: []const []const u8 = &.{"main.document"};
    const doc: []const []const u8 = &.{"document"};
    const specific: []const []const u8 = &.{"main.document"};

    // The ordinary case: the plugin says what it is, the shape says where that lives.
    try std.testing.expect(accepts(pane, doc));
    try std.testing.expect(!accepts(main, doc));

    // A plugin that names the sub-place lands there, and in the enclosing region when the shape
    // has no such sub-place — but the sub-place's claim is stronger, so it wins where both exist.
    try std.testing.expectEqual(Fit.exact, strength(pane, specific));
    try std.testing.expectEqual(Fit.place, strength(main, specific));

    // Synonyms do not add up to a stronger claim.
    try std.testing.expectEqual(Fit.exact, strength(main, &.{ "main", "center", "workspace" }));
}
