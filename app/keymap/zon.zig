//! Reading and writing `keybinds.zon` — the user's keybinding overrides.
//!
//! Only overrides live on disk. Defaults stay in code, so a user who has never rebound anything
//! has no `keybinds.zon` at all (same principle as R12's "omit all-default blocks" in
//! settings.zon).
//!
//! ```zon
//! .{
//!     .fizzy = .{
//!         .{ .keys = "ctrl+shift+e", .command = "fizzy.toggleExplorer" },
//!         .{ .keys = "ctrl+b",       .command = null },              // unbind
//!     },
//!     .plugins = .{
//!         .text = .{
//!             .{ .keys = "ctrl+k ctrl+c", .command = "text.addLineComment" },
//!             .{ .keys = "escape", .command = "text.dismissCompletion",
//!                .when = "completionVisible" },
//!         },
//!     },
//! }
//! ```
//!
//! Parsing goes through `std.zig.Ast` + `Zoir` rather than `std.zon.parse`, for the same reason
//! `SettingsPluginsZon.zig` does: the plugin ids under `.plugins` are **dynamic field names**,
//! which a typed parse can't express.
//!
//! **Parsing never fails on bad content.** A malformed entry produces a `Diagnostic` (with a
//! line/column) and is skipped, so one typo can't cost a user every other binding they have. The
//! settings pane surfaces the diagnostics.

const std = @import("std");
const chord_mod = @import("chord.zig");
const keymap = @import("keymap.zig");

const Allocator = std.mem.Allocator;
const Stroke = chord_mod.Stroke;
const Platform = chord_mod.Platform;
const When = keymap.When;

pub const OwnedBinding = struct {
    /// Verbatim key text as written by the user, so a round-trip through parse+format doesn't
    /// rewrite `Ctrl+S` into `ctrl+s` behind their back.
    keys: []u8,
    stroke: Stroke,
    /// null = an explicit unbind.
    command: ?[]u8,
    when: When = .{},
    when_text: ?[]u8 = null,
    /// Plugin id, or null for the `.fizzy` block.
    owner_id: ?[]u8 = null,

    pub fn deinit(self: *OwnedBinding, gpa: Allocator) void {
        gpa.free(self.keys);
        if (self.command) |c| gpa.free(c);
        if (self.when_text) |w| gpa.free(w);
        if (self.owner_id) |o| gpa.free(o);
        self.* = undefined;
    }
};

pub const Diagnostic = struct {
    /// 1-based, for showing next to the offending line.
    line: u32 = 0,
    column: u32 = 0,
    message: []u8,

    fn deinit(self: *Diagnostic, gpa: Allocator) void {
        gpa.free(self.message);
        self.* = undefined;
    }
};

pub const File = struct {
    bindings: []OwnedBinding = &.{},
    diagnostics: []Diagnostic = &.{},

    pub fn deinit(self: *File, gpa: Allocator) void {
        for (self.bindings) |*b| b.deinit(gpa);
        gpa.free(self.bindings);
        for (self.diagnostics) |*d| d.deinit(gpa);
        gpa.free(self.diagnostics);
        self.* = .{};
    }

    /// Borrowed view for feeding into a `Keymap`. The returned slice borrows this `File`'s
    /// strings, so it must not outlive it.
    pub fn toBindings(self: File, gpa: Allocator, source: keymap.Source) ![]keymap.Binding {
        const out = try gpa.alloc(keymap.Binding, self.bindings.len);
        for (self.bindings, out) |b, *o| {
            o.* = .{
                .stroke = b.stroke,
                .command = b.command,
                .when = b.when,
                .source = source,
                .owner_id = b.owner_id,
            };
        }
        return out;
    }
};

const Parsed = struct { ast: std.zig.Ast, zoir: std.zig.Zoir };

fn parseZon(gpa: Allocator, source: [:0]const u8) ?Parsed {
    var ast = std.zig.Ast.parse(gpa, source, .zon) catch return null;
    errdefer ast.deinit(gpa);
    var zoir = std.zig.ZonGen.generate(gpa, ast, .{ .parse_str_lits = true }) catch {
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

fn findField(
    zoir: std.zig.Zoir,
    container: std.zig.Zoir.Node.Index,
    name: []const u8,
) ?std.zig.Zoir.Node.Index {
    const s = switch (container.get(zoir)) {
        .struct_literal => |sl| sl,
        else => return null,
    };
    for (s.names, 0..) |field_name, i| {
        if (std.mem.eql(u8, field_name.get(zoir), name)) return s.vals.at(@intCast(i));
    }
    return null;
}

fn stringField(
    zoir: std.zig.Zoir,
    container: std.zig.Zoir.Node.Index,
    name: []const u8,
) ?[]const u8 {
    const node = findField(zoir, container, name) orelse return null;
    return switch (node.get(zoir)) {
        .string_literal => |s| s,
        else => null,
    };
}

/// 1-based line/column of a node's first token.
fn locationOf(ast: std.zig.Ast, zoir: std.zig.Zoir, node: std.zig.Zoir.Node.Index) struct { line: u32, column: u32 } {
    const tok = ast.firstToken(node.getAstNode(zoir));
    const start = ast.tokenStart(tok);
    var line: u32 = 1;
    var col: u32 = 1;
    for (ast.source[0..start]) |c| {
        if (c == '\n') {
            line += 1;
            col = 1;
        } else col += 1;
    }
    return .{ .line = line, .column = col };
}

const Collector = struct {
    gpa: Allocator,
    bindings: std.ArrayList(OwnedBinding) = .empty,
    diagnostics: std.ArrayList(Diagnostic) = .empty,

    fn diag(self: *Collector, line: u32, column: u32, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.gpa, fmt, args) catch return;
        self.diagnostics.append(self.gpa, .{ .line = line, .column = column, .message = msg }) catch {
            self.gpa.free(msg);
        };
    }
};

fn collectBlock(
    c: *Collector,
    ast: std.zig.Ast,
    zoir: std.zig.Zoir,
    block: std.zig.Zoir.Node.Index,
    owner_id: ?[]const u8,
    platform: Platform,
) Allocator.Error!void {
    const range = switch (block.get(zoir)) {
        .array_literal => |r| r,
        .empty_literal => return,
        else => {
            const loc = locationOf(ast, zoir, block);
            c.diag(loc.line, loc.column, "expected a list of bindings, e.g. .{{ .{{ .keys = \"ctrl+s\", .command = \"fizzy.save\" }} }}", .{});
            return;
        },
    };

    var i: u32 = 0;
    while (i < range.len) : (i += 1) {
        const entry = range.at(i);
        const loc = locationOf(ast, zoir, entry);

        switch (entry.get(zoir)) {
            .struct_literal => {},
            else => {
                c.diag(loc.line, loc.column, "binding must be a struct, e.g. .{{ .keys = \"ctrl+s\", .command = \"fizzy.save\" }}", .{});
                continue;
            },
        }

        const keys_text = stringField(zoir, entry, "keys") orelse {
            c.diag(loc.line, loc.column, "binding is missing a `.keys` string", .{});
            continue;
        };

        const stroke = chord_mod.parseKeys(keys_text, platform) catch |err| {
            c.diag(loc.line, loc.column, "cannot parse keys \"{s}\": {s}", .{ keys_text, @errorName(err) });
            continue;
        };

        // `.command` must be present, but may be `null` to mean "unbind".
        const command_node = findField(zoir, entry, "command") orelse {
            c.diag(loc.line, loc.column, "binding is missing `.command` (use `.command = null` to unbind)", .{});
            continue;
        };
        const command: ?[]const u8 = switch (command_node.get(zoir)) {
            .string_literal => |s| s,
            .null => null,
            else => {
                c.diag(loc.line, loc.column, "`.command` must be a string or null", .{});
                continue;
            },
        };
        if (command) |cmd| {
            if (cmd.len == 0) {
                c.diag(loc.line, loc.column, "`.command` is empty (use `.command = null` to unbind)", .{});
                continue;
            }
        }

        var when: When = .{};
        var when_text: ?[]u8 = null;
        errdefer if (when_text) |w| c.gpa.free(w);
        if (findField(zoir, entry, "when")) |when_node| {
            switch (when_node.get(zoir)) {
                .string_literal => |s| {
                    var unknown: std.ArrayList([]const u8) = .empty;
                    defer unknown.deinit(c.gpa);
                    when = When.parse(s, &unknown, c.gpa) catch .{};
                    for (unknown.items) |u| {
                        // Not fatal: a config written against a newer fizzy must round-trip.
                        c.diag(loc.line, loc.column, "unknown `when` context \"{s}\" (binding kept, context ignored)", .{u});
                    }
                    when_text = try c.gpa.dupe(u8, s);
                },
                .null => {},
                else => c.diag(loc.line, loc.column, "`.when` must be a string", .{}),
            }
        }

        const keys_copy = try c.gpa.dupe(u8, keys_text);
        errdefer c.gpa.free(keys_copy);
        const command_copy: ?[]u8 = if (command) |cmd| try c.gpa.dupe(u8, cmd) else null;
        errdefer if (command_copy) |cc| c.gpa.free(cc);
        const owner_copy: ?[]u8 = if (owner_id) |o| try c.gpa.dupe(u8, o) else null;
        errdefer if (owner_copy) |oc| c.gpa.free(oc);

        try c.bindings.append(c.gpa, .{
            .keys = keys_copy,
            .stroke = stroke,
            .command = command_copy,
            .when = when,
            .when_text = when_text,
            .owner_id = owner_copy,
        });
        when_text = null; // ownership moved
    }
}

/// Parse a `keybinds.zon` source. Only allocation failure is an error — everything else lands in
/// `File.diagnostics`.
pub fn parse(gpa: Allocator, source: [:0]const u8, platform: Platform) Allocator.Error!File {
    var c: Collector = .{ .gpa = gpa };
    errdefer {
        for (c.bindings.items) |*b| b.deinit(gpa);
        c.bindings.deinit(gpa);
        for (c.diagnostics.items) |*d| d.deinit(gpa);
        c.diagnostics.deinit(gpa);
    }

    var parsed = parseZon(gpa, source) orelse {
        c.diag(0, 0, "keybinds.zon is not valid ZON; no overrides loaded", .{});
        return .{
            .bindings = try c.bindings.toOwnedSlice(gpa),
            .diagnostics = try c.diagnostics.toOwnedSlice(gpa),
        };
    };
    defer {
        parsed.zoir.deinit(gpa);
        parsed.ast.deinit(gpa);
    }

    // Fizzy-owned overrides. `.shell` is still accepted so existing keybinds.zon files keep
    // loading after the command-id rename; writes always use `.fizzy`.
    if (findField(parsed.zoir, .root, "fizzy")) |fizzy_block| {
        try collectBlock(&c, parsed.ast, parsed.zoir, fizzy_block, null, platform);
    } else if (findField(parsed.zoir, .root, "shell")) |legacy_shell_block| {
        try collectBlock(&c, parsed.ast, parsed.zoir, legacy_shell_block, null, platform);
    }

    if (findField(parsed.zoir, .root, "plugins")) |plugins_node| {
        switch (plugins_node.get(parsed.zoir)) {
            .struct_literal => |sl| {
                for (sl.names, 0..) |id_str, i| {
                    const id = id_str.get(parsed.zoir);
                    try collectBlock(&c, parsed.ast, parsed.zoir, sl.vals.at(@intCast(i)), id, platform);
                }
            },
            .empty_literal => {},
            else => {
                const loc = locationOf(parsed.ast, parsed.zoir, plugins_node);
                c.diag(loc.line, loc.column, "`.plugins` must be a struct keyed by plugin id", .{});
            },
        }
    }

    // `shell.*` command ids were renamed to `fizzy.*` ("shell"/"fizzy" are the same length).
    for (c.bindings.items) |*b| {
        if (b.command) |cmd| migrateLegacyShellCommandId(cmd);
    }

    return .{
        .bindings = try c.bindings.toOwnedSlice(gpa),
        .diagnostics = try c.diagnostics.toOwnedSlice(gpa),
    };
}

/// In-place: `shell.save` → `fizzy.save`. Both prefixes are 5 chars + `.`.
fn migrateLegacyShellCommandId(cmd: []u8) void {
    if (cmd.len >= 6 and std.mem.eql(u8, cmd[0..6], "shell.")) {
        @memcpy(cmd[0..5], "fizzy");
    }
}

// -- writing ---------------------------------------------------------------------------------------

fn writeBinding(w: *std.Io.Writer, b: OwnedBinding, indent: []const u8) !void {
    try w.print("{s}.{{ .keys = \"{f}\", ", .{ indent, std.zig.fmtString(b.keys) });
    if (b.command) |cmd| {
        try w.print(".command = \"{f}\"", .{std.zig.fmtString(cmd)});
    } else {
        try w.writeAll(".command = null");
    }
    if (b.when_text) |wt| {
        if (wt.len > 0) try w.print(", .when = \"{f}\"", .{std.zig.fmtString(wt)});
    }
    try w.writeAll(" },\n");
}

/// Serialize overrides back to `keybinds.zon` text. Bindings are grouped by `owner_id`, matching
/// settings.zon's `.plugins.<id>` shape so an uninstall can drop one plugin's block wholesale.
pub fn format(gpa: Allocator, bindings: []const OwnedBinding) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll(".{\n");

    var wrote_fizzy = false;
    for (bindings) |b| {
        if (b.owner_id != null) continue;
        if (!wrote_fizzy) {
            try w.writeAll("    .fizzy = .{\n");
            wrote_fizzy = true;
        }
        try writeBinding(w, b, "        ");
    }
    if (wrote_fizzy) try w.writeAll("    },\n");

    // Distinct plugin ids, in first-seen order — stable output, no allocation for a sort.
    var wrote_plugins = false;
    for (bindings, 0..) |b, i| {
        const id = b.owner_id orelse continue;
        var seen_earlier = false;
        for (bindings[0..i]) |prev| {
            if (prev.owner_id) |pid| {
                if (std.mem.eql(u8, pid, id)) {
                    seen_earlier = true;
                    break;
                }
            }
        }
        if (seen_earlier) continue;

        if (!wrote_plugins) {
            try w.writeAll("    .plugins = .{\n");
            wrote_plugins = true;
        }
        try w.print("        .{f} = .{{\n", .{std.zig.fmtId(id)});
        for (bindings) |b2| {
            const bid = b2.owner_id orelse continue;
            if (!std.mem.eql(u8, bid, id)) continue;
            try writeBinding(w, b2, "            ");
        }
        try w.writeAll("        },\n");
    }
    if (wrote_plugins) try w.writeAll("    },\n");

    try w.writeAll("}\n");
    return out.toOwnedSlice();
}

// -- tests -----------------------------------------------------------------------------------------

const t = std.testing;

test "parses fizzy and plugin blocks" {
    const a = t.allocator;
    const src =
        \\.{
        \\    .fizzy = .{
        \\        .{ .keys = "ctrl+shift+e", .command = "fizzy.toggleExplorer" },
        \\        .{ .keys = "ctrl+b", .command = null },
        \\    },
        \\    .plugins = .{
        \\        .text = .{
        \\            .{ .keys = "ctrl+k ctrl+c", .command = "text.addLineComment" },
        \\        },
        \\        .workbench = .{
        \\            .{ .keys = "ctrl+\\", .command = "workbench.splitRight" },
        \\        },
        \\    },
        \\}
    ;
    var f = try parse(a, src, .other);
    defer f.deinit(a);

    try t.expectEqual(@as(usize, 0), f.diagnostics.len);
    try t.expectEqual(@as(usize, 4), f.bindings.len);

    try t.expectEqual(@as(?[]u8, null), f.bindings[0].owner_id);
    try t.expectEqualStrings("fizzy.toggleExplorer", f.bindings[0].command.?);
    try t.expectEqual(@as(?[]u8, null), f.bindings[1].command); // unbind
    try t.expectEqualStrings("text", f.bindings[2].owner_id.?);
    try t.expect(f.bindings[2].stroke.isChord());
    try t.expectEqualStrings("workbench", f.bindings[3].owner_id.?);
    try t.expectEqual(keymap.Key.backslash, f.bindings[3].stroke.first.key);
}

test "when clauses parse" {
    const a = t.allocator;
    const src =
        \\.{
        \\    .plugins = .{
        \\        .text = .{
        \\            .{ .keys = "escape", .command = "text.dismissCompletion", .when = "completionVisible" },
        \\        },
        \\    },
        \\}
    ;
    var f = try parse(a, src, .other);
    defer f.deinit(a);
    try t.expectEqual(@as(usize, 0), f.diagnostics.len);
    try t.expect(f.bindings[0].when.completion_visible);
    try t.expectEqualStrings("completionVisible", f.bindings[0].when_text.?);
}

test "an unknown when context is kept, with a diagnostic" {
    const a = t.allocator;
    const src =
        \\.{ .fizzy = .{ .{ .keys = "f5", .command = "fizzy.run", .when = "someFutureThing" } } }
    ;
    var f = try parse(a, src, .other);
    defer f.deinit(a);
    try t.expectEqual(@as(usize, 1), f.bindings.len); // kept
    try t.expectEqual(@as(usize, 1), f.diagnostics.len);
}

test "one bad entry does not discard the others" {
    const a = t.allocator;
    const src =
        \\.{
        \\    .fizzy = .{
        \\        .{ .keys = "ctrl+s", .command = "fizzy.save" },
        \\        .{ .keys = "ctrl+nope", .command = "fizzy.broken" },
        \\        .{ .command = "fizzy.nokeys" },
        \\        .{ .keys = "ctrl+q" },
        \\        .{ .keys = "ctrl+w", .command = "fizzy.close" },
        \\    },
        \\}
    ;
    var f = try parse(a, src, .other);
    defer f.deinit(a);

    try t.expectEqual(@as(usize, 2), f.bindings.len);
    try t.expectEqualStrings("fizzy.save", f.bindings[0].command.?);
    try t.expectEqualStrings("fizzy.close", f.bindings[1].command.?);
    try t.expectEqual(@as(usize, 3), f.diagnostics.len);
    // Diagnostics carry a usable location.
    try t.expectEqual(@as(u32, 4), f.diagnostics[0].line);
}

test "malformed ZON yields a diagnostic, not a crash" {
    const a = t.allocator;
    var f = try parse(a, ".{ this is not zon ", .other);
    defer f.deinit(a);
    try t.expectEqual(@as(usize, 0), f.bindings.len);
    try t.expectEqual(@as(usize, 1), f.diagnostics.len);
}

test "empty and absent blocks are fine" {
    const a = t.allocator;
    for ([_][:0]const u8{ ".{}", ".{ .fizzy = .{} }", ".{ .shell = .{} }", ".{ .plugins = .{} }" }) |src| {
        var f = try parse(a, src, .other);
        defer f.deinit(a);
        try t.expectEqual(@as(usize, 0), f.bindings.len);
        try t.expectEqual(@as(usize, 0), f.diagnostics.len);
    }
}

test "mod resolves per platform at parse time" {
    const a = t.allocator;
    const src = ".{ .fizzy = .{ .{ .keys = \"mod+s\", .command = \"fizzy.save\" } } }";

    var mac = try parse(a, src, .mac);
    defer mac.deinit(a);
    try t.expect(mac.bindings[0].stroke.first.mods.command);

    var other = try parse(a, src, .other);
    defer other.deinit(a);
    try t.expect(other.bindings[0].stroke.first.mods.ctrl);
}

test "format round-trips through parse" {
    const a = t.allocator;
    const src =
        \\.{
        \\    .fizzy = .{
        \\        .{ .keys = "ctrl+shift+e", .command = "fizzy.toggleExplorer" },
        \\        .{ .keys = "ctrl+b", .command = null },
        \\    },
        \\    .plugins = .{
        \\        .text = .{
        \\            .{ .keys = "ctrl+k ctrl+c", .command = "text.addLineComment" },
        \\            .{ .keys = "escape", .command = "text.dismiss", .when = "completionVisible" },
        \\        },
        \\    },
        \\}
    ;
    var first = try parse(a, src, .other);
    defer first.deinit(a);

    const written = try format(a, first.bindings);
    defer a.free(written);
    const written_z = try a.dupeZ(u8, written);
    defer a.free(written_z);

    var second = try parse(a, written_z, .other);
    defer second.deinit(a);

    try t.expectEqual(@as(usize, 0), second.diagnostics.len);
    try t.expectEqual(first.bindings.len, second.bindings.len);
    for (first.bindings, second.bindings) |x, y| {
        try t.expectEqualStrings(x.keys, y.keys);
        try t.expect(x.stroke.eql(y.stroke));
        try t.expect(x.when.eql(y.when));
        if (x.command) |xc| try t.expectEqualStrings(xc, y.command.?) else try t.expect(y.command == null);
        if (x.owner_id) |xo| try t.expectEqualStrings(xo, y.owner_id.?) else try t.expect(y.owner_id == null);
    }
}

test "backslash keys survive a write/read cycle" {
    const a = t.allocator;
    var f = try parse(a, ".{ .fizzy = .{ .{ .keys = \"ctrl+\\\\\", .command = \"fizzy.split\" } } }", .other);
    defer f.deinit(a);
    try t.expectEqual(keymap.Key.backslash, f.bindings[0].stroke.first.key);

    const written = try format(a, f.bindings);
    defer a.free(written);
    const written_z = try a.dupeZ(u8, written);
    defer a.free(written_z);
    var again = try parse(a, written_z, .other);
    defer again.deinit(a);
    try t.expectEqual(keymap.Key.backslash, again.bindings[0].stroke.first.key);
}

test "legacy .shell block and shell.* command ids still load" {
    const a = t.allocator;
    var f = try parse(a, ".{ .shell = .{ .{ .keys = \"ctrl+s\", .command = \"shell.save\" } } }", .other);
    defer f.deinit(a);
    try t.expectEqual(@as(usize, 0), f.diagnostics.len);
    try t.expectEqualStrings("fizzy.save", f.bindings[0].command.?);
}

test "toBindings feeds a Keymap" {
    const a = t.allocator;
    var f = try parse(a, ".{ .fizzy = .{ .{ .keys = \"ctrl+s\", .command = \"fizzy.save\" } } }", .other);
    defer f.deinit(a);

    const view = try f.toBindings(a, .user);
    defer a.free(view);

    var k: keymap.Keymap = .{};
    defer k.deinit(a);
    for (view) |b| try k.add(a, b);

    const r = k.resolve((try chord_mod.parseKeys("ctrl+s", .other)).first, .{}, null);
    try t.expectEqualStrings("fizzy.save", r.command);
    try t.expectEqual(keymap.Source.user, view[0].source);
}
