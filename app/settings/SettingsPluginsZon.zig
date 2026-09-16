//! Reads/writes the `.plugins = .{ .<id> = .{...}, ... }` sub-tree of the merged
//! `settings.zon` — see docs/PLUGIN_MANIFEST_PLAN.md R10/R12.
//!
//! Every plugin's block lives as a real nested ZON struct literal keyed by plugin id, not an
//! escaped-string blob. On-disk shape after R12:
//!
//! ```
//! .plugins = .{
//!     .text = .{ .enabled = true, .settings = .{ .tab_size = 8 } },
//!     .pixi = .{ .settings = .{ .grid_size = 16 } }, // enabled omitted (= false)
//!     .ghostty = .{ .enabled = true, .auto_update = false }, // auto_update omitted = true
//! }
//! ```
//!
//! `extractField` finds a named field's value **by exact source byte span** (via
//! `std.zig.Ast`/`std.zig.ZonGen`'s `Zoir` — the same machinery `std.zon.parse` uses
//! internally) rather than re-serializing it, so hand-formatting/comments inside a block
//! survive untouched. Callers compose nesting themselves:
//! `extractField(settings, "plugins")` → `extractField(that, id)` → `extractField(that, "settings")`.
//!
//! Pure text-in/text-out — no `dvui`/filesystem dependency, so this is unit-testable directly.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Entry = struct {
    id: []const u8,
    /// Verbatim ZON source text for this id's whole block (e.g.
    /// `.{ .enabled = true, .settings = .{ .tab_size = 4 } }`), or `null` meaning "remove this
    /// id's block entirely" (R12 — all-default settings + disabled, or an explicit removal).
    text: ?[]const u8,
};

pub fn freeEntries(gpa: Allocator, entries: []const Entry) void {
    for (entries) |e| {
        gpa.free(e.id);
        if (e.text) |t| gpa.free(t);
    }
    gpa.free(entries);
}

/// Finds `container`'s field named `name` (an exact-string compare — `Zoir` already resolves
/// both plain and `@"..."`-quoted field names to plain strings, so there's no bare-identifier
/// restriction on `name`). Returns the field's value node, or null if `container` isn't a struct
/// literal or has no such field.
fn findField(zoir: std.zig.Zoir, container: std.zig.Zoir.Node.Index, name: []const u8) ?std.zig.Zoir.Node.Index {
    const node = container.get(zoir);
    const s = switch (node) {
        .struct_literal => |sl| sl,
        else => return null,
    };
    for (s.names, 0..) |field_name, i| {
        if (std.mem.eql(u8, field_name.get(zoir), name)) return s.vals.at(@intCast(i));
    }
    return null;
}

/// Owned copy of `node`'s exact source text (first token's start through last token's end),
/// preserving whitespace/comments inside the span verbatim.
fn nodeSourceText(gpa: Allocator, ast: std.zig.Ast, zoir: std.zig.Zoir, node: std.zig.Zoir.Node.Index) Allocator.Error![]u8 {
    const ast_node = node.getAstNode(zoir);
    const first_tok = ast.firstToken(ast_node);
    const last_tok = ast.lastToken(ast_node);
    const start = ast.tokenStart(first_tok);
    const end = ast.tokenStart(last_tok) + ast.tokenSlice(last_tok).len;
    return gpa.dupe(u8, ast.source[start..end]);
}

/// Parses `source` as ZON and returns the `Ast`+`Zoir` pair, or null on any parse/generate
/// failure (malformed file — callers fall back to "nothing found", same as a missing file).
const Parsed = struct { ast: std.zig.Ast, zoir: std.zig.Zoir };

fn parseZon(gpa: Allocator, source: [:0]const u8) ?Parsed {
    var ast = std.zig.Ast.parse(gpa, source, .zon) catch return null;
    errdefer ast.deinit(gpa);
    var zoir = std.zig.ZonGen.generate(gpa, ast, .{ .parse_str_lits = false }) catch {
        ast.deinit(gpa);
        return null;
    };
    if (zoir.hasCompileErrors()) {
        zoir.deinit(gpa);
        ast.deinit(gpa);
        return null;
    }
    return .{ .ast = ast, .zoir = zoir };
}

/// Reads `source`'s top-level field named `field_name` as a verbatim ZON text blob
/// (caller-owned, free with `gpa`). Null if the field is absent or the source doesn't parse.
/// Compose nesting by feeding a prior extraction back in as `source` (after `dupeZ`).
pub fn extractField(gpa: Allocator, source: [:0]const u8, field_name: []const u8) ?[]u8 {
    var parsed = parseZon(gpa, source) orelse return null;
    defer {
        parsed.zoir.deinit(gpa);
        parsed.ast.deinit(gpa);
    }
    const value_node = findField(parsed.zoir, .root, field_name) orelse return null;
    return nodeSourceText(gpa, parsed.ast, parsed.zoir, value_node) catch null;
}

/// Convenience: `.plugins.<id>` whole-block text. Prefer composing `extractField` when you need
/// a deeper nest (e.g. `.plugins.<id>.settings` for `Host.loadPluginSettings`).
pub fn extractPluginBlob(gpa: Allocator, source: [:0]const u8, id: []const u8) ?[]u8 {
    const plugins = extractField(gpa, source, "plugins") orelse return null;
    defer gpa.free(plugins);
    const plugins_z = gpa.dupeZ(u8, plugins) catch return null;
    defer gpa.free(plugins_z);
    return extractField(gpa, plugins_z, id);
}

/// Enumerates **every** field in `source`'s `.plugins` struct literal — not filtered to any known
/// set of ids. Used by the **write path**: a plugin's block must survive every save regardless of
/// whether that plugin is currently loaded, disabled, or even uninstalled (mirrors the existing
/// "uninstall only deletes the dylib, settings persist" behavior). Empty slice (never null) if
/// `source` is null, `.plugins` is absent, or the source doesn't parse. Caller frees with
/// `freeEntries`.
pub fn listPluginBlocks(gpa: Allocator, source: ?[:0]const u8) Allocator.Error![]Entry {
    const src = source orelse return &.{};
    var parsed = parseZon(gpa, src) orelse return &.{};
    defer {
        parsed.zoir.deinit(gpa);
        parsed.ast.deinit(gpa);
    }

    const plugins_node = findField(parsed.zoir, .root, "plugins") orelse return &.{};
    const node = plugins_node.get(parsed.zoir);
    const s = switch (node) {
        .struct_literal => |sl| sl,
        else => return &.{},
    };

    var out: std.ArrayListUnmanaged(Entry) = .empty;
    errdefer {
        for (out.items) |e| {
            gpa.free(e.id);
            if (e.text) |t| gpa.free(t);
        }
        out.deinit(gpa);
    }
    for (s.names, 0..) |field_name, i| {
        const id = try gpa.dupe(u8, field_name.get(parsed.zoir));
        errdefer gpa.free(id);
        const text = try nodeSourceText(gpa, parsed.ast, parsed.zoir, s.vals.at(@intCast(i)));
        try out.append(gpa, .{ .id = id, .text = text });
    }
    return out.toOwnedSlice(gpa);
}

fn leadingSpaces(line: []const u8) usize {
    var n: usize = 0;
    for (line) |c| {
        if (c != ' ') break;
        n += 1;
    }
    return n;
}

/// Writes `text` to `writer`, prefixing every line *after the first* with `indent` spaces.
/// Used when splicing a (possibly multi-line) ZON blob after `= ` on an already-indented
/// parent line — the first line stays on that parent line; continuations deepen correctly.
///
/// Continuation lines are first **dedented** by their common leading whitespace so a block
/// that was previously written under `.plugins` (and later re-extracted verbatim by
/// `listPluginBlocks`) does not accumulate another `indent` on every autosave — that was
/// producing runaway nesting like `.enabled` at column 20 after a few UI toggles.
fn writeNested(writer: *std.Io.Writer, text: []const u8, indent: usize) !void {
    var strip: usize = std.math.maxInt(usize);
    {
        var it = std.mem.splitScalar(u8, text, '\n');
        _ = it.next(); // first line stays as-is (typically `.{`)
        while (it.next()) |line| {
            if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
            strip = @min(strip, leadingSpaces(line));
        }
        if (strip == std.math.maxInt(usize)) strip = 0;
    }

    var first = true;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed_end = std.mem.trimEnd(u8, line, "\r");
        if (!first) {
            try writer.writeByte('\n');
            try writer.splatByteAll(' ', indent);
            const content = if (trimmed_end.len >= strip) trimmed_end[strip..] else trimmed_end;
            try writer.writeAll(content);
        } else {
            try writer.writeAll(trimmed_end);
        }
        first = false;
    }
}

/// Composes the final `settings.zon` text: `fizzy_fields_text` (fizzy's own
/// `Settings.serialize` output, just `.{ ...fizzy's own fields... }`) with a `.plugins = .{ ... }`
/// field appended, built from every entry already in `existing_full_source` (preserved verbatim,
/// in their original order — including ids not touched this cycle, per `listPluginBlocks`'s
/// doc comment) with `overlay`'s entries upserted by id (replacing the text of an existing id in
/// place, or appended if new). An overlay entry with `text == null` **deletes** that id from the
/// result entirely (R12). Field names always go through `std.zig.fmtId` (quotes only when
/// needed) so any id string round-trips as valid ZON. Multi-line plugin blocks are re-indented
/// so nested `.enabled`/`.settings` keep standard Zig-style 4-space nesting.
pub fn composeMergedText(
    gpa: Allocator,
    fizzy_fields_text: []const u8,
    existing_full_source: ?[:0]const u8,
    overlay: []const Entry,
) ![]u8 {
    const existing = try listPluginBlocks(gpa, existing_full_source);
    defer freeEntries(gpa, existing);

    var order: std.ArrayListUnmanaged([]const u8) = .empty;
    defer order.deinit(gpa);
    var by_id: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    defer by_id.deinit(gpa);

    for (existing) |e| {
        try by_id.put(gpa, e.id, e.text.?);
        try order.append(gpa, e.id);
    }
    for (overlay) |e| {
        if (e.text) |text| {
            if (by_id.getPtr(e.id)) |slot| {
                slot.* = text;
            } else {
                try by_id.put(gpa, e.id, text);
                try order.append(gpa, e.id);
            }
        } else {
            _ = by_id.orderedRemove(e.id);
            for (order.items, 0..) |oid, i| {
                if (std.mem.eql(u8, oid, e.id)) {
                    _ = order.orderedRemove(i);
                    break;
                }
            }
        }
    }

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    const trimmed = std.mem.trimEnd(u8, fizzy_fields_text, " \t\r\n");
    const body = std.mem.trimEnd(u8, if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '}')
        trimmed[0 .. trimmed.len - 1]
    else
        trimmed, " \t\r\n");
    try aw.writer.writeAll(body);
    // `body` is fizzy's own fields with their closing `}` stripped — its last field has no
    // trailing comma unless `Settings.serialize` happens to emit one, so add one here (unless
    // the struct was empty) before appending `.plugins` as another field.
    if (body.len > 0 and body[body.len - 1] != ',' and body[body.len - 1] != '{') {
        try aw.writer.writeAll(",");
    }
    try aw.writer.writeAll("\n    .plugins = .{\n");
    for (order.items) |id| {
        const text = by_id.get(id).?;
        try aw.writer.print("        .{f} = ", .{std.zig.fmtId(id)});
        // `.plugins` is at 4 spaces; each id entry at 8 — continuations of a multi-line id
        // block deepen from there.
        try writeNested(&aw.writer, text, 8);
        try aw.writer.writeAll(",\n");
    }
    try aw.writer.writeAll("    },\n}\n");
    return aw.toOwnedSlice();
}

/// Upserts a single `id` into `existing_full_source`'s `.plugins` block, touching as little of
/// the document as possible: every other byte (fizzy's own fields, other plugins' entries, formatting,
/// comments) is left exactly as-is. Used by the one-shot legacy-per-plugin-file migration
/// (`SettingsMigration.mergeLegacyPerPluginFiles`), which runs before fizzy has a parsed
/// `Settings` value to regenerate fields from via `composeMergedText`'s normal
/// fizzy-fields-plus-overlay shape. If `id` already has an entry, returns an unchanged copy of
/// `existing_full_source` (never clobbers a live edit made through the new merged system).
/// `entry.text` must be non-null (a removal is expressible via `composeMergedText`'s overlay).
pub fn upsertOne(gpa: Allocator, existing_full_source: ?[:0]const u8, entry: Entry) ![]u8 {
    const text = entry.text orelse return error.NullEntryText;
    const src = existing_full_source orelse {
        return std.fmt.allocPrint(gpa, ".{{\n    .plugins = .{{\n        .{f} = {s},\n    }},\n}}\n", .{ std.zig.fmtId(entry.id), text });
    };

    var parsed = parseZon(gpa, src) orelse return gpa.dupe(u8, src);
    defer {
        parsed.zoir.deinit(gpa);
        parsed.ast.deinit(gpa);
    }

    const plugins_node = findField(parsed.zoir, .root, "plugins") orelse {
        // No `.plugins` field at all yet: `src` itself is safe to treat as "fizzy fields text"
        // here (it has no `.plugins` to duplicate), so this reduces to the normal compose path
        // with an empty existing-plugins base.
        return composeMergedText(gpa, src, null, &.{entry});
    };

    if (findField(parsed.zoir, plugins_node, entry.id) != null) {
        return gpa.dupe(u8, src);
    }

    const ast_node = plugins_node.getAstNode(parsed.zoir);
    const last_tok = parsed.ast.lastToken(ast_node);
    const insert_at = parsed.ast.tokenStart(last_tok);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try aw.writer.writeAll(src[0..insert_at]);
    try aw.writer.print("    .{f} = {s},\n    ", .{ std.zig.fmtId(entry.id), text });
    try aw.writer.writeAll(src[insert_at..]);
    return aw.toOwnedSlice();
}

/// The fizzy-reserved half of a plugin's block — everything beside the author's own `.settings`.
/// Each field is written only when it differs from its default, so a plugin sitting at defaults
/// still composes to `.{}` (and, with no settings either, is dropped from the file entirely).
pub const Reserved = struct {
    /// Load this plugin at startup. Absent means false: a dylib dropped into `plugins/` stays
    /// dormant until the user (or a store install) turns it on.
    ///
    /// **Tri-state, and the field's *presence* is load-bearing.** `null` (absent from disk) means
    /// nobody has decided yet — a build that appeared in `plugins/` on its own; `false` (written
    /// out explicitly, unlike every other default in this file) means the user deliberately
    /// switched it off. Both are "do not load", but only the first is an open offer, and fizzy
    /// distinguishes them everywhere it matters: the rail badge, the store's Load button, and
    /// whether loading raises the file-type ownership prompt. Uninstall erases the field, which
    /// is what makes a later reinstall ask again — see `Editor.clearPluginOwnershipRecord`.
    enabled: ?bool = null,
    /// Whether this plugin takes store updates at all. Absent means **true** — the inverse of
    /// `enabled`'s default, so only a deliberate opt-out is ever written. *How* an update is
    /// applied (silently, or through the update window) is one app-wide choice, not a per-plugin
    /// one — see `Settings.plugin_update_mode`.
    auto_update: bool = true,
    /// Extensions (each with its dot) this plugin is the user's chosen default owner for.
    /// Written as a plain ZON tuple (`.extensions = .{ ".png", ".jpg" }`) — `&.{...}` is Zig
    /// syntax that `std.zig.Zoir` will not parse, so `extractField` could never read it back.
    /// Absent means "no explicit choice for anything" — routing then falls through to the
    /// unique claimant, else the fallback editor (see `Host.pluginForExtension`).
    ///
    /// The plugin's identity is expressed *structurally*, by which `.plugins.<id>` block the
    /// list sits in — a plugin id is never written as a value here. Only an explicit user
    /// decision (the install-time dialog, or the File Types settings table) ever writes this;
    /// no load or reconcile path does.
    ///
    /// May legitimately name an extension the plugin does not offer via `fileTypes` — that is
    /// exactly what "keep Plain Text for `.foo`" records on the fallback editor's own block.
    extensions: []const []const u8 = &.{},
};

/// Parses a `.extensions` value blob (`.{ ".png", ".jpg" }`) into owned
/// strings. Tolerant by design: this reads a file the user is invited to hand-edit, so anything
/// that does not parse as a list of strings yields an empty slice rather than an error. Free
/// with `freeExtensions`.
pub fn parseExtensions(gpa: Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |e| gpa.free(e);
        out.deinit(gpa);
    }
    var rest = text;
    while (std.mem.indexOfScalar(u8, rest, '"')) |open_q| {
        rest = rest[open_q + 1 ..];
        const close_q = std.mem.indexOfScalar(u8, rest, '"') orelse break;
        const ext = rest[0..close_q];
        rest = rest[close_q + 1 ..];
        if (ext.len == 0) continue;
        try out.append(gpa, try gpa.dupe(u8, ext));
    }
    return out.toOwnedSlice(gpa);
}

pub fn freeExtensions(gpa: Allocator, exts: []const []const u8) void {
    for (exts) |e| gpa.free(e);
    gpa.free(exts);
}

/// Composes one plugin id's on-disk block: `.{ .enabled = true, .settings = <text> }` with each
/// half omitted when not applicable (`.enabled` only when a decision exists — see its tri-state
/// note, so `false` *is* written; `.auto_update` only when `false`, `.extensions` only when
/// non-empty; `.settings` only when present).
/// Multi-line `settings_text` (as produced by `Schema(T).diffSerialize`) is re-indented under
/// `.settings =` so the result is standard Zig-style 4-space nesting. Caller-owned.
pub fn composePluginIdBlock(gpa: Allocator, reserved: Reserved, settings_text: ?[]const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try aw.writer.writeAll(".{\n");
    if (reserved.enabled) |e| try aw.writer.print("    .enabled = {},\n", .{e});
    if (!reserved.auto_update) try aw.writer.writeAll("    .auto_update = false,\n");
    if (reserved.extensions.len > 0) {
        try aw.writer.writeAll("    .extensions = .{");
        for (reserved.extensions, 0..) |ext, i| {
            if (i > 0) try aw.writer.writeAll(",");
            try aw.writer.print(" \"{f}\"", .{std.zig.fmtString(ext)});
        }
        try aw.writer.writeAll(" },\n");
    }
    if (settings_text) |s| {
        try aw.writer.writeAll("    .settings = ");
        try writeNested(&aw.writer, s, 4);
        try aw.writer.writeAll(",\n");
    }
    try aw.writer.writeAll("}");
    return aw.toOwnedSlice();
}

const testing = std.testing;

const sample_source: [:0]const u8 =
    \\.{
    \\    .theme = 0.35,
    \\    .plugins = .{
    \\        .pixi = .{ .enabled = true, .settings = .{ .grid_size = 16 } },
    \\        .text = .{ .enabled = true, .settings = .{ .tab_size = 4 } },
    \\    },
    \\}
;

test "extractField returns the verbatim value text for a top-level field" {
    const plugins = extractField(testing.allocator, sample_source, "plugins").?;
    defer testing.allocator.free(plugins);
    try testing.expect(std.mem.indexOf(u8, plugins, ".pixi") != null);
}

test "extractPluginBlob returns the verbatim value text for an existing id" {
    const blob = extractPluginBlob(testing.allocator, sample_source, "pixi").?;
    defer testing.allocator.free(blob);
    try testing.expectEqualStrings(".{ .enabled = true, .settings = .{ .grid_size = 16 } }", blob);
}

test "extractPluginBlob returns null when .plugins is absent" {
    const source: [:0]const u8 = ".{ .theme = 0.35 }";
    try testing.expect(extractPluginBlob(testing.allocator, source, "pixi") == null);
}

test "extractPluginBlob returns null when the id is missing from an existing .plugins block" {
    try testing.expect(extractPluginBlob(testing.allocator, sample_source, "nonexistent") == null);
}

test "nested extractField reaches .plugins.<id>.settings" {
    const plugins = extractField(testing.allocator, sample_source, "plugins").?;
    defer testing.allocator.free(plugins);
    const plugins_z = try testing.allocator.dupeZ(u8, plugins);
    defer testing.allocator.free(plugins_z);
    const id_block = extractField(testing.allocator, plugins_z, "text").?;
    defer testing.allocator.free(id_block);
    const id_z = try testing.allocator.dupeZ(u8, id_block);
    defer testing.allocator.free(id_z);
    const settings = extractField(testing.allocator, id_z, "settings").?;
    defer testing.allocator.free(settings);
    try testing.expectEqualStrings(".{ .tab_size = 4 }", settings);
}

test "composeMergedText round-trips: overlay replaces one id, others survive untouched" {
    const overlay = [_]Entry{.{ .id = "pixi", .text = ".{ .enabled = true, .settings = .{ .grid_size = 32 } }" }};
    const fizzy_text = ".{ .theme = 0.35 }";

    const composed = try composeMergedText(testing.allocator, fizzy_text, sample_source, &overlay);
    defer testing.allocator.free(composed);

    const composed_z = try testing.allocator.dupeZ(u8, composed);
    defer testing.allocator.free(composed_z);

    const pixi = extractPluginBlob(testing.allocator, composed_z, "pixi").?;
    defer testing.allocator.free(pixi);
    try testing.expectEqualStrings(".{ .enabled = true, .settings = .{ .grid_size = 32 } }", pixi);

    const text_settings = extractPluginBlob(testing.allocator, composed_z, "text").?;
    defer testing.allocator.free(text_settings);
    try testing.expectEqualStrings(".{ .enabled = true, .settings = .{ .tab_size = 4 } }", text_settings);
}

test "composeMergedText removes an id when overlay text is null" {
    const overlay = [_]Entry{.{ .id = "pixi", .text = null }};
    const fizzy_text = ".{ .theme = 0.35 }";

    const composed = try composeMergedText(testing.allocator, fizzy_text, sample_source, &overlay);
    defer testing.allocator.free(composed);

    const composed_z = try testing.allocator.dupeZ(u8, composed);
    defer testing.allocator.free(composed_z);

    try testing.expect(extractPluginBlob(testing.allocator, composed_z, "pixi") == null);

    const text_settings = extractPluginBlob(testing.allocator, composed_z, "text").?;
    defer testing.allocator.free(text_settings);
    try testing.expectEqualStrings(".{ .enabled = true, .settings = .{ .tab_size = 4 } }", text_settings);
}

test "composeMergedText adds a brand-new id when there is no existing .plugins block" {
    const overlay = [_]Entry{.{ .id = "pixi", .text = ".{ .enabled = true, .settings = .{ .grid_size = 8 } }" }};
    const fizzy_text = ".{ .theme = 0.35 }";

    const composed = try composeMergedText(testing.allocator, fizzy_text, null, &overlay);
    defer testing.allocator.free(composed);

    const composed_z = try testing.allocator.dupeZ(u8, composed);
    defer testing.allocator.free(composed_z);

    const pixi = extractPluginBlob(testing.allocator, composed_z, "pixi").?;
    defer testing.allocator.free(pixi);
    try testing.expectEqualStrings(".{ .enabled = true, .settings = .{ .grid_size = 8 } }", pixi);
}

test "listPluginBlocks retains a disabled/unloaded plugin's block untouched" {
    const entries = try listPluginBlocks(testing.allocator, sample_source);
    defer freeEntries(testing.allocator, entries);
    try testing.expectEqual(@as(usize, 2), entries.len);
}

test "composeMergedText accepts an empty fizzy struct (every fizzy field at its default)" {
    // Since fizzy serializes non-default fields only (`Settings.serialize`, R12), an
    // untouched fizzy hands this `.{}` — the `.plugins` field must still splice on as valid ZON
    // rather than producing a stray leading comma.
    const overlay = [_]Entry{.{ .id = "pixi", .text = ".{ .enabled = true }" }};

    const composed = try composeMergedText(testing.allocator, ".{}", null, &overlay);
    defer testing.allocator.free(composed);

    const composed_z = try testing.allocator.dupeZ(u8, composed);
    defer testing.allocator.free(composed_z);

    const pixi = extractPluginBlob(testing.allocator, composed_z, "pixi").?;
    defer testing.allocator.free(pixi);
    try testing.expectEqualStrings(".{ .enabled = true }", pixi);
}

test "upsertOne inserts a new id into an existing .plugins block, leaving the rest untouched" {
    const composed = try upsertOne(testing.allocator, sample_source, .{ .id = "markdown", .text = ".{ .enabled = true }" });
    defer testing.allocator.free(composed);
    const composed_z = try testing.allocator.dupeZ(u8, composed);
    defer testing.allocator.free(composed_z);

    const markdown = extractPluginBlob(testing.allocator, composed_z, "markdown").?;
    defer testing.allocator.free(markdown);
    try testing.expectEqualStrings(".{ .enabled = true }", markdown);

    // Untouched ids survive byte-for-byte.
    const pixi = extractPluginBlob(testing.allocator, composed_z, "pixi").?;
    defer testing.allocator.free(pixi);
    try testing.expectEqualStrings(".{ .enabled = true, .settings = .{ .grid_size = 16 } }", pixi);
}

test "upsertOne never clobbers an id that's already present" {
    const composed = try upsertOne(testing.allocator, sample_source, .{ .id = "pixi", .text = ".{ .grid_size = 999 }" });
    defer testing.allocator.free(composed);
    try testing.expectEqualStrings(sample_source, composed);
}

test "upsertOne adds a .plugins block when none exists yet" {
    const source: [:0]const u8 = ".{ .theme = 0.35 }";
    const composed = try upsertOne(testing.allocator, source, .{ .id = "pixi", .text = ".{ .enabled = true }" });
    defer testing.allocator.free(composed);
    const composed_z = try testing.allocator.dupeZ(u8, composed);
    defer testing.allocator.free(composed_z);

    const pixi = extractPluginBlob(testing.allocator, composed_z, "pixi").?;
    defer testing.allocator.free(pixi);
    try testing.expectEqualStrings(".{ .enabled = true }", pixi);
}

test "upsertOne handles a missing settings.zon (null source)" {
    const composed = try upsertOne(testing.allocator, null, .{ .id = "pixi", .text = ".{ .enabled = true }" });
    defer testing.allocator.free(composed);
    const composed_z = try testing.allocator.dupeZ(u8, composed);
    defer testing.allocator.free(composed_z);

    const pixi = extractPluginBlob(testing.allocator, composed_z, "pixi").?;
    defer testing.allocator.free(pixi);
    try testing.expectEqualStrings(".{ .enabled = true }", pixi);
}

test "composePluginIdBlock omits enabled when false and settings when absent" {
    const empty = try composePluginIdBlock(testing.allocator, .{}, null);
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings(".{\n}", empty);

    const enabled_only = try composePluginIdBlock(testing.allocator, .{ .enabled = true }, null);
    defer testing.allocator.free(enabled_only);
    try testing.expectEqualStrings(".{\n    .enabled = true,\n}", enabled_only);

    const settings_only = try composePluginIdBlock(testing.allocator, .{}, ".{ .tab_size = 8 }");
    defer testing.allocator.free(settings_only);
    try testing.expectEqualStrings(".{\n    .settings = .{ .tab_size = 8 },\n}", settings_only);
}

test "composePluginIdBlock omits extensions when empty and writes them when set" {
    const none = try composePluginIdBlock(testing.allocator, .{ .enabled = true }, null);
    defer testing.allocator.free(none);
    try testing.expectEqualStrings(".{\n    .enabled = true,\n}", none);

    const one = try composePluginIdBlock(testing.allocator, .{ .enabled = true, .extensions = &.{".txt"} }, null);
    defer testing.allocator.free(one);
    try testing.expectEqualStrings(".{\n    .enabled = true,\n    .extensions = .{ \".txt\" },\n}", one);

    const many = try composePluginIdBlock(testing.allocator, .{ .extensions = &.{ ".png", ".jpg" } }, null);
    defer testing.allocator.free(many);
    try testing.expectEqualStrings(".{\n    .extensions = .{ \".png\", \".jpg\" },\n}", many);
}

test "composed extensions survive extractField + parseExtensions" {
    const block = try composePluginIdBlock(
        testing.allocator,
        .{ .enabled = true, .auto_update = false, .extensions = &.{ ".png", ".jpeg" } },
        ".{ .zoom = 2 }",
    );
    defer testing.allocator.free(block);

    const block_z = try testing.allocator.dupeZ(u8, block);
    defer testing.allocator.free(block_z);

    const exts_text = extractField(testing.allocator, block_z, "extensions").?;
    defer testing.allocator.free(exts_text);
    const exts = try parseExtensions(testing.allocator, exts_text);
    defer freeExtensions(testing.allocator, exts);

    try testing.expectEqual(@as(usize, 2), exts.len);
    try testing.expectEqualStrings(".png", exts[0]);
    try testing.expectEqualStrings(".jpeg", exts[1]);

    // The other reserved fields and the author's settings still round-trip alongside it.
    const settings = extractField(testing.allocator, block_z, "settings").?;
    defer testing.allocator.free(settings);
    try testing.expectEqualStrings(".{ .zoom = 2 }", settings);
}

test "parseExtensions tolerates a hand-edited or malformed list" {
    const empty = try parseExtensions(testing.allocator, ".{}");
    defer freeExtensions(testing.allocator, empty);
    try testing.expectEqual(@as(usize, 0), empty.len);

    // Unterminated string / trailing garbage must not error — this file is user-editable.
    const ragged = try parseExtensions(testing.allocator, ".{ \".md\", \".mdx");
    defer freeExtensions(testing.allocator, ragged);
    try testing.expectEqual(@as(usize, 1), ragged.len);
    try testing.expectEqualStrings(".md", ragged[0]);

    const not_a_list = try parseExtensions(testing.allocator, "true");
    defer freeExtensions(testing.allocator, not_a_list);
    try testing.expectEqual(@as(usize, 0), not_a_list.len);
}

test "every Reserved field is discoverable by extractField" {
    // `SettingsMigration.isAlreadyNested` decides whether a `.plugins.<id>` block is R12-shaped
    // or a pre-R12 flat one by probing for each reserved field by name — and a block judged flat
    // has its whole contents wrapped into `.settings` and stamped `.enabled = true`. So a
    // reserved field that composes to something `extractField` cannot find back is silently
    // destructive: it would be reinterpreted as a plugin-author setting. This asserts the two
    // sides stay in step for every field, including ones added later.
    inline for (@typeInfo(Reserved).@"struct".fields) |field| {
        // Compose a block in which this field is guaranteed non-default, so it is actually
        // emitted (fields are written only when they differ from their default).
        var reserved: Reserved = .{};
        switch (field.type) {
            bool => @field(reserved, field.name) = !@field(reserved, field.name),
            // Tri-state: absent is the default, so either concrete value is "non-default" and
            // must be emitted. `false` is the interesting one — it used to be omitted.
            ?bool => @field(reserved, field.name) = false,
            []const []const u8 => @field(reserved, field.name) = &.{".probe"},
            else => @compileError("extend this test for Reserved field type " ++ @typeName(field.type)),
        }
        const block = try composePluginIdBlock(testing.allocator, reserved, null);
        defer testing.allocator.free(block);
        const block_z = try testing.allocator.dupeZ(u8, block);
        defer testing.allocator.free(block_z);

        const found = extractField(testing.allocator, block_z, field.name);
        try testing.expect(found != null);
        testing.allocator.free(found.?);
    }
}

test "composePluginIdBlock records enabled as a tri-state" {
    // Absent means "never decided" (a build dropped into plugins/ that nobody has answered for);
    // an explicit `false` is the user's decision to keep it off. Collapsing the two — which the
    // non-default-only rule would otherwise do — silently demotes a disabled plugin back to an
    // unanswered offer on the next launch.
    const unset = try composePluginIdBlock(testing.allocator, .{}, ".{ .a = 1 }");
    defer testing.allocator.free(unset);
    try testing.expect(std.mem.indexOf(u8, unset, ".enabled") == null);

    const off = try composePluginIdBlock(testing.allocator, .{ .enabled = false }, null);
    defer testing.allocator.free(off);
    try testing.expectEqualStrings(".{\n    .enabled = false,\n}", off);

    const on = try composePluginIdBlock(testing.allocator, .{ .enabled = true }, null);
    defer testing.allocator.free(on);
    try testing.expectEqualStrings(".{\n    .enabled = true,\n}", on);
}

test "composePluginIdBlock writes auto_update only when opted out" {
    // True is the absent state — a plugin that takes updates adds no bytes to the file.
    const default_on = try composePluginIdBlock(testing.allocator, .{ .enabled = true }, null);
    defer testing.allocator.free(default_on);
    try testing.expectEqualStrings(".{\n    .enabled = true,\n}", default_on);

    const opted_out = try composePluginIdBlock(testing.allocator, .{ .enabled = true, .auto_update = false }, null);
    defer testing.allocator.free(opted_out);
    try testing.expectEqualStrings(".{\n    .enabled = true,\n    .auto_update = false,\n}", opted_out);

    // Opting out is itself worth persisting for a plugin that is otherwise all-default.
    const disabled_no_auto = try composePluginIdBlock(testing.allocator, .{ .auto_update = false }, null);
    defer testing.allocator.free(disabled_no_auto);
    try testing.expectEqualStrings(".{\n    .auto_update = false,\n}", disabled_no_auto);
}

test "composePluginIdBlock re-indents a multi-line settings blob" {
    // Shape `Schema(T).diffSerialize` emits for a single changed field.
    const settings =
        \\.{
        \\    .tab_size = 8,
        \\}
    ;
    const block = try composePluginIdBlock(testing.allocator, .{ .enabled = true }, settings);
    defer testing.allocator.free(block);
    try testing.expectEqualStrings(
        \\.{
        \\    .enabled = true,
        \\    .settings = .{
        \\        .tab_size = 8,
        \\    },
        \\}
    , block);
}

test "composeMergedText re-indents a multi-line id block under .plugins" {
    const id_block =
        \\.{
        \\    .enabled = true,
        \\    .settings = .{
        \\        .tab_size = 8,
        \\    },
        \\}
    ;
    const overlay = [_]Entry{.{ .id = "text", .text = id_block }};
    const composed = try composeMergedText(testing.allocator, ".{ .theme = 0.35 }", null, &overlay);
    defer testing.allocator.free(composed);
    try testing.expectEqualStrings(
        \\.{ .theme = 0.35,
        \\    .plugins = .{
        \\        .text = .{
        \\            .enabled = true,
        \\            .settings = .{
        \\                .tab_size = 8,
        \\            },
        \\        },
        \\    },
        \\}
        \\
    , composed);
}

test "composeMergedText dedents an already-nested block (no indent compounding)" {
    // Shape that used to accumulate: a prior writeNested left absolute indent inside the
    // extracted block; rewriting without dedent pushed `.enabled` further right each save.
    const existing: [:0]const u8 =
        \\.{
        \\    .theme = 0.35,
        \\    .plugins = .{
        \\        .zig = .{
        \\                    .enabled = true,
        \\                },
        \\    },
        \\}
    ;
    const composed = try composeMergedText(testing.allocator, ".{ .theme = 0.35 }", existing, &.{});
    defer testing.allocator.free(composed);
    try testing.expectEqualStrings(
        \\.{ .theme = 0.35,
        \\    .plugins = .{
        \\        .zig = .{
        \\            .enabled = true,
        \\        },
        \\    },
        \\}
        \\
    , composed);
}
