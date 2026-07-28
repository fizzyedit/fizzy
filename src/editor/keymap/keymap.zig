//! Keybinding resolution: chord → command id.
//!
//! **Invariant: nothing under `keymap/` may import dvui.** dvui's keybind map is a
//! `name → Keybind` lookup where `Keybind` is a single key plus modifier flags — it cannot hold
//! a chord, and it is matched by *bind name* rather than by command, which is why today's
//! `Keybinds.tick()` is a hardcoded if-chain wired straight to `fizzy.editor.*` calls with
//! nothing addressable by a config file. This module owns the real table; the dvui-facing
//! adapter converts events in and projects single-stroke bindings back out so menus and dvui's
//! own widgets keep working.
//!
//! Staying dvui-free also puts this in the `addTest`-per-pure-root list in `build/app.zig`.
//!
//! This file is the single test root for the tree — Zig collects `test` blocks only from an
//! artifact's root module, and relative imports are part of that same module.

const std = @import("std");

pub const Key = @import("Key.zig").Key;
pub const keyIsModifier = @import("Key.zig").isModifier;
const chord_mod = @import("chord.zig");
pub const zon = @import("zon.zig");

pub const Platform = chord_mod.Platform;
pub const Mods = chord_mod.Mods;
pub const Chord = chord_mod.Chord;
pub const Stroke = chord_mod.Stroke;
pub const parseKeys = chord_mod.parseKeys;
pub const formatKeys = chord_mod.formatKeys;
pub const ParseError = chord_mod.ParseError;

const Allocator = std.mem.Allocator;

/// Context gate — VSCode's `when` clauses, reduced to a fixed set. Deliberately a small closed
/// set rather than an expression language: a binding either applies in a context or it doesn't,
/// and every entry here has to be *supplied* by the shell each frame, so an open-ended grammar
/// would just be a way to write conditions nothing ever satisfies.
///
/// Empty (`.{}`) means "applies anywhere", which is the common case.
pub const When = packed struct {
    editor_focused: bool = false,
    text_input_focused: bool = false,
    explorer_focused: bool = false,
    panel_focused: bool = false,
    completion_visible: bool = false,
    modal_open: bool = false,

    pub fn isAny(self: When) bool {
        return !self.editor_focused and !self.text_input_focused and
            !self.explorer_focused and !self.panel_focused and
            !self.completion_visible and !self.modal_open;
    }

    /// Does a binding requiring `self` apply in the live context `ctx`? Every flag the binding
    /// asks for must be present; flags it doesn't ask about are ignored.
    pub fn matches(self: When, ctx: When) bool {
        if (self.editor_focused and !ctx.editor_focused) return false;
        if (self.text_input_focused and !ctx.text_input_focused) return false;
        if (self.explorer_focused and !ctx.explorer_focused) return false;
        if (self.panel_focused and !ctx.panel_focused) return false;
        if (self.completion_visible and !ctx.completion_visible) return false;
        if (self.modal_open and !ctx.modal_open) return false;
        return true;
    }

    /// How many flags a binding constrains — the specificity used to break ties, so a
    /// context-specific binding always wins over a global one on the same chord.
    pub fn weight(self: When) u8 {
        var n: u8 = 0;
        inline for (@typeInfo(When).@"struct".fields) |f| {
            if (@field(self, f.name)) n += 1;
        }
        return n;
    }

    pub fn eql(a: When, b: When) bool {
        return @as(u6, @bitCast(a)) == @as(u6, @bitCast(b));
    }

    /// Parse a `when` string. Unknown names are *not* an error — they're reported so a config
    /// written against a newer fizzy round-trips instead of being silently dropped.
    pub fn parse(text: []const u8, unknown: ?*std.ArrayList([]const u8), gpa: ?Allocator) !When {
        var out: When = .{};
        var it = std.mem.tokenizeAny(u8, text, " \t&&,");
        while (it.next()) |raw| {
            const tok = std.mem.trim(u8, raw, " \t");
            if (tok.len == 0) continue;
            var matched = false;
            inline for (@typeInfo(When).@"struct".fields) |f| {
                if (eqlCamelOrSnake(tok, f.name)) {
                    @field(out, f.name) = true;
                    matched = true;
                }
            }
            if (!matched) {
                if (unknown) |list| try list.append(gpa.?, tok);
            }
        }
        return out;
    }
};

/// `completionVisible` and `completion_visible` both name the same flag — the ZON file leans
/// snake_case, VSCode docs use camelCase, and there's no value in making people care.
fn eqlCamelOrSnake(input: []const u8, snake: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(input, snake)) return true;
    var i: usize = 0;
    var j: usize = 0;
    while (i < input.len and j < snake.len) {
        if (snake[j] == '_') {
            j += 1;
            if (i >= input.len) return false;
            if (std.ascii.toLower(input[i]) != std.ascii.toLower(snake[j])) return false;
            i += 1;
            j += 1;
            continue;
        }
        if (std.ascii.toLower(input[i]) != std.ascii.toLower(snake[j])) return false;
        i += 1;
        j += 1;
    }
    return i == input.len and j == snake.len;
}

/// Which layer a binding came from. Later sources override earlier ones on the same chord.
pub const Source = enum(u8) {
    dvui = 0,
    profile = 1,
    plugin = 2,
    user = 3,
};

pub const Binding = struct {
    stroke: Stroke,
    /// Command id to run, or null to *unbind* this chord — how a user turns off a default
    /// without having to know what it was bound to.
    command: ?[]const u8,
    when: When = .{},
    source: Source = .profile,
    /// Owning plugin id, for grouping in the UI and for dropping a plugin's binds on unload.
    owner_id: ?[]const u8 = null,
};

pub const Resolution = union(enum) {
    /// No binding; the event should fall through to whatever else wants it.
    none,
    /// First half of a chord matched — swallow the key and wait for the second stroke.
    pending,
    command: []const u8,
    /// An explicit unbind matched. Distinct from `.none` because the key *was* claimed: the
    /// point of unbinding is to stop a lower layer from firing, not to fall through to it.
    unbound,
};

pub const Conflict = struct {
    stroke: Stroke,
    when: When,
    winner: []const u8,
    loser: []const u8,
};

pub const Keymap = struct {
    bindings: std.ArrayList(Binding) = .empty,
    /// Half-entered chord, if any.
    pending: ?Chord = null,

    pub fn deinit(self: *Keymap, gpa: Allocator) void {
        self.bindings.deinit(gpa);
        self.* = .{};
    }

    pub fn add(self: *Keymap, gpa: Allocator, b: Binding) !void {
        try self.bindings.append(gpa, b);
    }

    /// Cancel a half-entered chord — call on focus loss or Escape, so a stray `ctrl+k` doesn't
    /// silently eat the next keystroke minutes later.
    pub fn cancelPending(self: *Keymap) void {
        self.pending = null;
    }

    /// Best binding for `stroke` in context `ctx`: highest `source`, then most specific `when`.
    /// Bindings with `owner_id` only apply when that id matches `active_owner` (decision 1B:
    /// active document owner wins on shared chords; otherwise the shell/profile binding fires).
    fn best(self: Keymap, stroke: Stroke, ctx: When, active_owner: ?[]const u8) ?Binding {
        var winner: ?Binding = null;
        for (self.bindings.items) |b| {
            if (!b.stroke.eql(stroke)) continue;
            if (!b.when.matches(ctx)) continue;
            if (b.owner_id) |oid| {
                const ao = active_owner orelse continue;
                if (!std.mem.eql(u8, oid, ao)) continue;
            }
            const w = winner orelse {
                winner = b;
                continue;
            };
            const b_rank = (@as(u16, @intFromEnum(b.source)) << 8) | b.when.weight();
            const w_rank = (@as(u16, @intFromEnum(w.source)) << 8) | w.when.weight();
            // Owner-scoped bindings beat otherwise equal-rank global ones — that's the whole
            // point of active-owner conflict resolution (pixi Export vs shell Quick Open).
            const b_owner_boost: u16 = if (b.owner_id != null) 1 else 0;
            const w_owner_boost: u16 = if (w.owner_id != null) 1 else 0;
            const b_total = (b_rank << 1) | b_owner_boost;
            const w_total = (w_rank << 1) | w_owner_boost;
            // >= so a later entry at equal rank wins: within one layer, last one loaded wins.
            if (b_total >= w_total) winner = b;
        }
        return winner;
    }

    /// Is `c` the opening stroke of some chord that could still apply here?
    fn opensChord(self: Keymap, c: Chord, ctx: When, active_owner: ?[]const u8) bool {
        for (self.bindings.items) |b| {
            if (b.stroke.second == null) continue;
            if (b.command == null) continue;
            if (!b.stroke.first.eql(c)) continue;
            if (!b.when.matches(ctx)) continue;
            if (b.owner_id) |oid| {
                const ao = active_owner orelse continue;
                if (!std.mem.eql(u8, oid, ao)) continue;
            }
            return true;
        }
        return false;
    }

    /// Feed one key press. Stateful: consecutive calls complete a chord.
    /// `active_owner` is the focused document's plugin id, or null when none.
    pub fn resolve(self: *Keymap, c: Chord, ctx: When, active_owner: ?[]const u8) Resolution {
        // Modifier keys alone never resolve, and must not cancel a pending chord — otherwise
        // pressing Ctrl for the second half of `ctrl+k ctrl+c` would abort the chord.
        if (keyIsModifier(c.key)) return .none;

        if (self.pending) |first| {
            self.pending = null;
            const full: Stroke = .{ .first = first, .second = c };
            if (self.best(full, ctx, active_owner)) |b| {
                return if (b.command) |cmd| .{ .command = cmd } else .unbound;
            }
            // A chord was started but the second stroke matched nothing: swallow it rather than
            // letting a half-typed `ctrl+k x` fire whatever `x` happens to be bound to.
            return .unbound;
        }

        // A single-stroke binding beats an unstarted chord on the same opening key, unless the
        // single-stroke binding is a lower-priority layer.
        const single: Stroke = .{ .first = c };
        const single_match = self.best(single, ctx, active_owner);

        if (self.opensChord(c, ctx, active_owner)) {
            if (single_match) |b| {
                if (b.source == .user) {
                    return if (b.command) |cmd| .{ .command = cmd } else .unbound;
                }
            }
            self.pending = c;
            return .pending;
        }

        if (single_match) |b| {
            return if (b.command) |cmd| .{ .command = cmd } else .unbound;
        }
        return .none;
    }

    /// Every binding currently mapped to `command` — for rendering shortcut hints and the
    /// Keyboard Shortcuts pane.
    pub fn bindingsFor(self: Keymap, gpa: Allocator, command: []const u8) ![]Binding {
        var out: std.ArrayList(Binding) = .empty;
        errdefer out.deinit(gpa);
        for (self.bindings.items) |b| {
            const cmd = b.command orelse continue;
            if (std.mem.eql(u8, cmd, command)) try out.append(gpa, b);
        }
        return out.toOwnedSlice(gpa);
    }

    /// Bindings that share a chord but don't always fire together. Includes classic layer
    /// shadowing (user beats profile) and active-owner forks (shell Quick Open vs pixi Export
    /// on `mod+p`) so the settings pane can warn about them.
    ///
    /// Collapses before reporting:
    /// 1. Duplicate entries for the same command (e.g. `fizzy.openFolder` from both the dvui
    ///    `open_folder` bind and the profile default) keep only the highest-ranked claim.
    /// 2. Within one owner bucket (all-global, or one plugin), only *adjacent* ranks are
    ///    reported — if A shadows B and B shadows C, "A shadows C" is omitted because C is
    ///    already dead under B.
    /// 3. Owner-scoped claims fork against the top global on that chord (context-dependent).
    pub fn conflicts(self: Keymap, gpa: Allocator) ![]Conflict {
        const Claim = struct {
            stroke: Stroke,
            when: When,
            command: []const u8,
            owner_id: ?[]const u8,
            rank: u16,
            index: usize,
        };

        var claims: std.ArrayList(Claim) = .empty;
        defer claims.deinit(gpa);

        for (self.bindings.items, 0..) |b, i| {
            const cmd = b.command orelse continue;
            const rank: u16 = (@as(u16, @intFromEnum(b.source)) << 8) | b.when.weight();
            for (claims.items) |*c| {
                if (!c.stroke.eql(b.stroke) or !c.when.eql(b.when)) continue;
                if (!std.mem.eql(u8, c.command, cmd)) continue;
                // Later equal-rank wins — same tie-break `best()` uses.
                if (rank >= c.rank) {
                    c.rank = rank;
                    c.owner_id = b.owner_id;
                    c.index = i;
                }
                break;
            } else {
                try claims.append(gpa, .{
                    .stroke = b.stroke,
                    .when = b.when,
                    .command = cmd,
                    .owner_id = b.owner_id,
                    .rank = rank,
                    .index = i,
                });
            }
        }

        var out: std.ArrayList(Conflict) = .empty;
        errdefer out.deinit(gpa);

        var seen_group = try gpa.alloc(bool, claims.items.len);
        defer gpa.free(seen_group);
        @memset(seen_group, false);

        const byRankDesc = struct {
            fn less(cs: []Claim, a: usize, b: usize) bool {
                const ca = cs[a];
                const cb = cs[b];
                if (ca.rank != cb.rank) return ca.rank > cb.rank;
                return ca.index > cb.index;
            }
        }.less;

        for (claims.items, 0..) |seed, si| {
            if (seen_group[si]) continue;

            var group: std.ArrayList(usize) = .empty;
            defer group.deinit(gpa);
            for (claims.items, 0..) |c, ci| {
                if (!c.stroke.eql(seed.stroke) or !c.when.eql(seed.when)) continue;
                seen_group[ci] = true;
                try group.append(gpa, ci);
            }

            // Bucket by owner_id (null = global). Chain within a bucket; owner buckets fork
            // against the global bucket's top claim.
            var bucket_keys: std.ArrayList(?[]const u8) = .empty;
            defer bucket_keys.deinit(gpa);
            var buckets: std.ArrayList(std.ArrayList(usize)) = .empty;
            defer {
                for (buckets.items) |*bkt| bkt.deinit(gpa);
                buckets.deinit(gpa);
            }

            for (group.items) |ci| {
                const key = claims.items[ci].owner_id;
                const bkt_i = for (bucket_keys.items, 0..) |k, bi| {
                    if (k == null and key == null) break bi;
                    if (k != null and key != null and std.mem.eql(u8, k.?, key.?)) break bi;
                } else null;
                if (bkt_i) |bi| {
                    try buckets.items[bi].append(gpa, ci);
                } else {
                    try bucket_keys.append(gpa, key);
                    var bkt: std.ArrayList(usize) = .empty;
                    try bkt.append(gpa, ci);
                    try buckets.append(gpa, bkt);
                }
            }

            var global_top: ?[]const u8 = null;
            for (bucket_keys.items, 0..) |key, bi| {
                const bkt = &buckets.items[bi];
                std.mem.sort(usize, bkt.items, claims.items, byRankDesc);

                // Adjacent shadow links only.
                var i: usize = 0;
                while (i + 1 < bkt.items.len) : (i += 1) {
                    const w = claims.items[bkt.items[i]];
                    const l = claims.items[bkt.items[i + 1]];
                    try out.append(gpa, .{
                        .stroke = seed.stroke,
                        .when = seed.when,
                        .winner = w.command,
                        .loser = l.command,
                    });
                }

                if (key == null and bkt.items.len > 0) {
                    global_top = claims.items[bkt.items[0]].command;
                }
            }

            // Owner-scoped top vs global top — context-dependent, either can win.
            if (global_top) |gt| {
                for (bucket_keys.items, 0..) |key, bi| {
                    if (key == null) continue;
                    const bkt = buckets.items[bi];
                    if (bkt.items.len == 0) continue;
                    const owner_cmd = claims.items[bkt.items[0]].command;
                    try out.append(gpa, .{
                        .stroke = seed.stroke,
                        .when = seed.when,
                        .winner = owner_cmd,
                        .loser = gt,
                    });
                }
            }
        }

        return out.toOwnedSlice(gpa);
    }
};

// -- tests ----------------------------------------------------------------------------------------

const t = std.testing;

fn km(gpa: Allocator, entries: []const Binding) !Keymap {
    var k: Keymap = .{};
    for (entries) |b| try k.add(gpa, b);
    return k;
}

fn keys(s: []const u8) Stroke {
    return parseKeys(s, .other) catch unreachable;
}

test "single-stroke resolves to its command" {
    const a = t.allocator;
    var k = try km(a, &.{
        .{ .stroke = keys("ctrl+s"), .command = "fizzy.save" },
    });
    defer k.deinit(a);

    const r = k.resolve(keys("ctrl+s").first, .{}, null);
    try t.expectEqualStrings("fizzy.save", r.command);
    try t.expect(k.resolve(keys("ctrl+q").first, .{}, null) == .none);
}

test "chord needs both strokes" {
    const a = t.allocator;
    var k = try km(a, &.{
        .{ .stroke = keys("ctrl+k ctrl+c"), .command = "text.addLineComment" },
    });
    defer k.deinit(a);

    try t.expect(k.resolve(keys("ctrl+k").first, .{}, null) == .pending);
    const r = k.resolve(keys("ctrl+c").first, .{}, null);
    try t.expectEqualStrings("text.addLineComment", r.command);
    try t.expectEqual(@as(?Chord, null), k.pending);
}

test "an unmatched second stroke is swallowed, not misfired" {
    const a = t.allocator;
    var k = try km(a, &.{
        .{ .stroke = keys("ctrl+k ctrl+c"), .command = "text.addLineComment" },
        .{ .stroke = keys("ctrl+x"), .command = "fizzy.cut" },
    });
    defer k.deinit(a);

    try t.expect(k.resolve(keys("ctrl+k").first, .{}, null) == .pending);
    // `ctrl+x` must NOT run cut here — it was typed as the tail of an abandoned chord.
    try t.expect(k.resolve(keys("ctrl+x").first, .{}, null) == .unbound);
    // ...and afterwards it works normally again.
    try t.expectEqualStrings("fizzy.cut", k.resolve(keys("ctrl+x").first, .{}, null).command);
}

test "pressing a modifier does not cancel a pending chord" {
    const a = t.allocator;
    var k = try km(a, &.{
        .{ .stroke = keys("ctrl+k ctrl+c"), .command = "text.addLineComment" },
    });
    defer k.deinit(a);

    try t.expect(k.resolve(keys("ctrl+k").first, .{}, null) == .pending);
    try t.expect(k.resolve(.{ .key = .left_control }, .{}, null) == .none);
    try t.expect(k.pending != null);
    try t.expectEqualStrings("text.addLineComment", k.resolve(keys("ctrl+c").first, .{}, null).command);
}

test "user layer overrides profile layer" {
    const a = t.allocator;
    var k = try km(a, &.{
        .{ .stroke = keys("ctrl+b"), .command = "fizzy.toggleSidebar", .source = .profile },
        .{ .stroke = keys("ctrl+b"), .command = "text.buildProject", .source = .user },
    });
    defer k.deinit(a);
    try t.expectEqualStrings("text.buildProject", k.resolve(keys("ctrl+b").first, .{}, null).command);
}

test "null command unbinds and claims the key" {
    const a = t.allocator;
    var k = try km(a, &.{
        .{ .stroke = keys("ctrl+b"), .command = "fizzy.toggleSidebar", .source = .profile },
        .{ .stroke = keys("ctrl+b"), .command = null, .source = .user },
    });
    defer k.deinit(a);
    // Not `.none` — the whole point is to stop the profile binding firing.
    try t.expect(k.resolve(keys("ctrl+b").first, .{}, null) == .unbound);
}

test "more specific when wins at equal source" {
    const a = t.allocator;
    var k = try km(a, &.{
        .{ .stroke = keys("escape"), .command = "fizzy.cancel" },
        .{ .stroke = keys("escape"), .command = "text.dismissCompletion", .when = .{ .completion_visible = true } },
    });
    defer k.deinit(a);

    try t.expectEqualStrings("fizzy.cancel", k.resolve(keys("escape").first, .{}, null).command);
    try t.expectEqualStrings(
        "text.dismissCompletion",
        k.resolve(keys("escape").first, .{ .completion_visible = true }, null).command,
    );
}

test "a binding whose context is unmet does not match" {
    const a = t.allocator;
    var k = try km(a, &.{
        .{ .stroke = keys("ctrl+/"), .command = "text.toggleLineComment", .when = .{ .editor_focused = true } },
    });
    defer k.deinit(a);
    try t.expect(k.resolve(keys("ctrl+/").first, .{}, null) == .none);
    try t.expectEqualStrings(
        "text.toggleLineComment",
        k.resolve(keys("ctrl+/").first, .{ .editor_focused = true }, null).command,
    );
}

test "cancelPending drops a half-entered chord" {
    const a = t.allocator;
    var k = try km(a, &.{
        .{ .stroke = keys("ctrl+k ctrl+c"), .command = "text.addLineComment" },
        .{ .stroke = keys("ctrl+c"), .command = "fizzy.copy" },
    });
    defer k.deinit(a);

    try t.expect(k.resolve(keys("ctrl+k").first, .{}, null) == .pending);
    k.cancelPending();
    try t.expectEqualStrings("fizzy.copy", k.resolve(keys("ctrl+c").first, .{}, null).command);
}

test "a user single-stroke binding beats a profile chord on the same opening key" {
    const a = t.allocator;
    var k = try km(a, &.{
        .{ .stroke = keys("ctrl+k ctrl+c"), .command = "text.addLineComment", .source = .profile },
        .{ .stroke = keys("ctrl+k"), .command = "fizzy.killLine", .source = .user },
    });
    defer k.deinit(a);
    try t.expectEqualStrings("fizzy.killLine", k.resolve(keys("ctrl+k").first, .{}, null).command);
}

test "when parsing accepts camelCase and snake_case, and reports unknowns" {
    const a = t.allocator;
    var unknown: std.ArrayList([]const u8) = .empty;
    defer unknown.deinit(a);

    const w = try When.parse("editorFocused && completion_visible && someFutureThing", &unknown, a);
    try t.expect(w.editor_focused and w.completion_visible);
    try t.expect(!w.panel_focused);
    try t.expectEqual(@as(usize, 1), unknown.items.len);
    try t.expectEqualStrings("someFutureThing", unknown.items[0]);
}

test "bindingsFor lists every chord for a command" {
    const a = t.allocator;
    var k = try km(a, &.{
        .{ .stroke = keys("ctrl+s"), .command = "fizzy.save" },
        .{ .stroke = keys("ctrl+k ctrl+s"), .command = "fizzy.save" },
        .{ .stroke = keys("ctrl+q"), .command = "fizzy.quit" },
    });
    defer k.deinit(a);

    const found = try k.bindingsFor(a, "fizzy.save");
    defer a.free(found);
    try t.expectEqual(@as(usize, 2), found.len);
}

test "conflicts reports the shadowed binding" {
    const a = t.allocator;
    var k = try km(a, &.{
        .{ .stroke = keys("ctrl+b"), .command = "fizzy.toggleSidebar", .source = .profile },
        .{ .stroke = keys("ctrl+b"), .command = "text.buildProject", .source = .user },
        .{ .stroke = keys("ctrl+s"), .command = "fizzy.save", .source = .profile },
    });
    defer k.deinit(a);

    const c = try k.conflicts(a);
    defer a.free(c);
    try t.expectEqual(@as(usize, 1), c.len);
    try t.expectEqualStrings("text.buildProject", c[0].winner);
    try t.expectEqualStrings("fizzy.toggleSidebar", c[0].loser);
}

test "conflicts dedupes when the same command is bound twice on a chord" {
    // Mirrors `fizzy.openFolder`: lifted from dvui's `open_folder` bind *and* listed in the
    // shell profile. A user rebind of another command onto that chord must yield one row, not
    // one per duplicate loser entry.
    const a = t.allocator;
    var k = try km(a, &.{
        .{ .stroke = keys("ctrl+f"), .command = "fizzy.openFolder", .source = .dvui },
        .{ .stroke = keys("ctrl+f"), .command = "fizzy.openFolder", .source = .profile },
        .{ .stroke = keys("ctrl+f"), .command = "text.format", .source = .user },
    });
    defer k.deinit(a);

    const c = try k.conflicts(a);
    defer a.free(c);
    try t.expectEqual(@as(usize, 1), c.len);
    try t.expectEqualStrings("text.format", c[0].winner);
    try t.expectEqualStrings("fizzy.openFolder", c[0].loser);
}

test "conflicts reports only adjacent ranks in a shadow chain" {
    // format > quickOpen > openFolder: omit the transitive "format shadows openFolder".
    const a = t.allocator;
    var k = try km(a, &.{
        .{ .stroke = keys("ctrl+f"), .command = "fizzy.openFolder", .source = .dvui },
        .{ .stroke = keys("ctrl+f"), .command = "fizzy.openFolder", .source = .profile },
        .{ .stroke = keys("ctrl+f"), .command = "fizzy.quickOpen", .source = .plugin },
        .{ .stroke = keys("ctrl+f"), .command = "text.format", .source = .user },
    });
    defer k.deinit(a);

    const c = try k.conflicts(a);
    defer a.free(c);
    try t.expectEqual(@as(usize, 2), c.len);
    try t.expectEqualStrings("text.format", c[0].winner);
    try t.expectEqualStrings("fizzy.quickOpen", c[0].loser);
    try t.expectEqualStrings("fizzy.quickOpen", c[1].winner);
    try t.expectEqualStrings("fizzy.openFolder", c[1].loser);
}

test "owner-scoped binding only fires when that owner is active" {
    const a = t.allocator;
    var k = try km(a, &.{
        .{ .stroke = keys("ctrl+p"), .command = "fizzy.quickOpen", .source = .profile },
        .{ .stroke = keys("ctrl+p"), .command = "pixi.export", .source = .plugin, .owner_id = "pixi" },
    });
    defer k.deinit(a);

    try t.expectEqualStrings("fizzy.quickOpen", k.resolve(keys("ctrl+p").first, .{}, null).command);
    try t.expectEqualStrings("pixi.export", k.resolve(keys("ctrl+p").first, .{}, "pixi").command);
    try t.expectEqualStrings("fizzy.quickOpen", k.resolve(keys("ctrl+p").first, .{}, "text").command);

    const c = try k.conflicts(a);
    defer a.free(c);
    try t.expectEqual(@as(usize, 1), c.len);
    try t.expectEqualStrings("pixi.export", c[0].winner);
    try t.expectEqualStrings("fizzy.quickOpen", c[0].loser);
}

test {
    _ = @import("Key.zig");
    _ = chord_mod;
    _ = zon;
}
