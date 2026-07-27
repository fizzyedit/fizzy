//! Parsing and formatting of VSCode-style key strings: `ctrl+shift+p`, `mod+k mod+c`, `alt+up`.
//!
//! Two-stroke chords are supported from the start, because dvui's keybind map physically cannot
//! express them (`dvui.enums.Keybind` is one key plus modifier flags) and retrofitting a chord
//! into a lookup-by-name design later would mean rewriting the dispatch rather than extending it.

const std = @import("std");
const Key = @import("Key.zig").Key;
const keyFromSpelling = @import("Key.zig").fromSpelling;
const keyToSpelling = @import("Key.zig").toSpelling;

/// Which physical modifier `mod+` resolves to. Passed in rather than detected so both branches
/// are testable without a window — and because fizzy already has to distinguish these at runtime
/// (`fizzy.platform.isMacOS()` differs from `builtin.os.tag` on wasm).
pub const Platform = enum { mac, other };

pub const Mods = packed struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    command: bool = false,

    pub fn eql(a: Mods, b: Mods) bool {
        return a.ctrl == b.ctrl and a.shift == b.shift and a.alt == b.alt and a.command == b.command;
    }

    pub fn isEmpty(self: Mods) bool {
        return !self.ctrl and !self.shift and !self.alt and !self.command;
    }
};

pub const Chord = struct {
    key: Key,
    mods: Mods = .{},

    pub fn eql(a: Chord, b: Chord) bool {
        return a.key == b.key and a.mods.eql(b.mods);
    }
};

pub const Stroke = struct {
    first: Chord,
    /// Second half of a chord, or null for an ordinary single-stroke binding.
    second: ?Chord = null,

    pub fn isChord(self: Stroke) bool {
        return self.second != null;
    }

    pub fn eql(a: Stroke, b: Stroke) bool {
        if (!a.first.eql(b.first)) return false;
        if (a.second == null and b.second == null) return true;
        if (a.second == null or b.second == null) return false;
        return a.second.?.eql(b.second.?);
    }
};

pub const ParseError = error{
    Empty,
    /// More than two strokes — VSCode allows two, and so do we.
    TooManyStrokes,
    /// A stroke with modifiers but no key, e.g. "ctrl+".
    MissingKey,
    UnknownModifier,
    UnknownKey,
    /// The key was a bare modifier, e.g. "ctrl+shift".
    ModifierAsKey,
};

fn parseModifier(token: []const u8, platform: Platform, mods: *Mods) ParseError!void {
    // `mod` is the primary accelerator: Command on macOS, Control everywhere else. Default
    // profile tables use it so one entry serves both platforms; a user who writes `ctrl`
    // explicitly gets a literal Control even on a Mac.
    if (std.mem.eql(u8, token, "mod") or std.mem.eql(u8, token, "primary")) {
        switch (platform) {
            .mac => mods.command = true,
            .other => mods.ctrl = true,
        }
        return;
    }
    if (std.mem.eql(u8, token, "ctrl") or std.mem.eql(u8, token, "control")) {
        mods.ctrl = true;
    } else if (std.mem.eql(u8, token, "shift")) {
        mods.shift = true;
    } else if (std.mem.eql(u8, token, "alt") or std.mem.eql(u8, token, "option")) {
        mods.alt = true;
    } else if (std.mem.eql(u8, token, "cmd") or std.mem.eql(u8, token, "command") or
        std.mem.eql(u8, token, "meta") or std.mem.eql(u8, token, "super") or
        std.mem.eql(u8, token, "win"))
    {
        mods.command = true;
    } else return error.UnknownModifier;
}

fn parseChord(text: []const u8, platform: Platform, buf: []u8) ParseError!Chord {
    if (text.len == 0) return error.Empty;

    var mods: Mods = .{};
    var rest = text;
    var key_token: []const u8 = text;

    // Split on '+', treating the final segment as the key. `+` is never itself a key name
    // (VSCode spells that key `=` / `shift+=`), so a trailing '+' is a missing key, not a plus.
    while (std.mem.indexOfScalar(u8, rest, '+')) |idx| {
        const token = rest[0..idx];
        if (token.len == 0) return error.MissingKey;
        const lowered = lower(token, buf);
        try parseModifier(lowered, platform, &mods);
        rest = rest[idx + 1 ..];
        key_token = rest;
    }
    if (key_token.len == 0) return error.MissingKey;

    const lowered_key = lower(key_token, buf);
    const key = keyFromSpelling(lowered_key) orelse {
        // Distinguish "you named a modifier where a key goes" from "no idea what that is" —
        // the former is a common mistake and deserves its own diagnostic.
        var probe: Mods = .{};
        if (parseModifier(lowered_key, platform, &probe)) |_| {
            return error.ModifierAsKey;
        } else |_| {}
        return error.UnknownKey;
    };
    return .{ .key = key, .mods = mods };
}

fn lower(s: []const u8, buf: []u8) []const u8 {
    if (s.len > buf.len) return s;
    for (s, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..s.len];
}

/// Parse `"ctrl+k ctrl+c"` into a `Stroke`. Whitespace separates the two halves of a chord.
pub fn parseKeys(text: []const u8, platform: Platform) ParseError!Stroke {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return error.Empty;

    var buf: [64]u8 = undefined;
    var it = std.mem.tokenizeAny(u8, trimmed, " \t");

    const first_text = it.next() orelse return error.Empty;
    const first = try parseChord(first_text, platform, &buf);

    const second_text = it.next();
    const second: ?Chord = if (second_text) |st| try parseChord(st, platform, &buf) else null;

    if (it.next() != null) return error.TooManyStrokes;
    return .{ .first = first, .second = second };
}

fn writeChord(c: Chord, w: *std.Io.Writer, platform: Platform) !void {
    // Canonical modifier order, matching VSCode's own output.
    if (c.mods.ctrl) try w.writeAll("ctrl+");
    if (c.mods.shift) try w.writeAll("shift+");
    if (c.mods.alt) try w.writeAll("alt+");
    if (c.mods.command) try w.writeAll(if (platform == .mac) "cmd+" else "win+");
    try w.writeAll(keyToSpelling(c.key));
}

/// Format back to a key string. Round-trips through `parseKeys` for the same platform.
pub fn formatKeys(gpa: std.mem.Allocator, s: Stroke, platform: Platform) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try writeChord(s.first, &out.writer, platform);
    if (s.second) |sec| {
        try out.writer.writeByte(' ');
        try writeChord(sec, &out.writer, platform);
    }
    return out.toOwnedSlice();
}

// -- tests --------------------------------------------------------------------------------------

const t = std.testing;

test "single chord with modifiers" {
    const s = try parseKeys("ctrl+shift+p", .other);
    try t.expectEqual(Key.p, s.first.key);
    try t.expect(s.first.mods.ctrl and s.first.mods.shift);
    try t.expect(!s.first.mods.alt and !s.first.mods.command);
    try t.expect(!s.isChord());
}

test "mod resolves per platform" {
    const mac = try parseKeys("mod+s", .mac);
    try t.expect(mac.first.mods.command and !mac.first.mods.ctrl);

    const other = try parseKeys("mod+s", .other);
    try t.expect(other.first.mods.ctrl and !other.first.mods.command);
}

test "explicit ctrl stays literal even on macOS" {
    const s = try parseKeys("ctrl+s", .mac);
    try t.expect(s.first.mods.ctrl and !s.first.mods.command);
}

test "two-stroke chords" {
    const s = try parseKeys("ctrl+k ctrl+c", .other);
    try t.expect(s.isChord());
    try t.expectEqual(Key.k, s.first.key);
    try t.expectEqual(Key.c, s.second.?.key);
    try t.expect(s.second.?.mods.ctrl);
}

test "case and surrounding whitespace are insensitive" {
    const a = try parseKeys("  Ctrl+Shift+P  ", .other);
    const b = try parseKeys("ctrl+shift+p", .other);
    try t.expect(a.eql(b));
}

test "modifier aliases" {
    try t.expect((try parseKeys("cmd+a", .other)).first.mods.command);
    try t.expect((try parseKeys("option+a", .other)).first.mods.alt);
    try t.expect((try parseKeys("control+a", .other)).first.mods.ctrl);
    try t.expect((try parseKeys("meta+a", .other)).first.mods.command);
}

test "punctuation keys" {
    try t.expectEqual(Key.slash, (try parseKeys("ctrl+/", .other)).first.key);
    try t.expectEqual(Key.grave, (try parseKeys("ctrl+`", .other)).first.key);
    try t.expectEqual(Key.backslash, (try parseKeys("ctrl+\\", .other)).first.key);
    try t.expectEqual(Key.equal, (try parseKeys("ctrl+=", .other)).first.key);
}

test "errors are specific" {
    try t.expectError(error.Empty, parseKeys("", .other));
    try t.expectError(error.Empty, parseKeys("   ", .other));
    try t.expectError(error.MissingKey, parseKeys("ctrl+", .other));
    try t.expectError(error.UnknownModifier, parseKeys("hyper+a", .other));
    try t.expectError(error.UnknownKey, parseKeys("ctrl+nope", .other));
    try t.expectError(error.ModifierAsKey, parseKeys("ctrl+shift", .other));
    try t.expectError(error.TooManyStrokes, parseKeys("ctrl+a ctrl+b ctrl+c", .other));
}

test "format round-trips" {
    const cases = [_][]const u8{
        "ctrl+shift+p",
        "alt+up",
        "ctrl+/",
        "f12",
        "escape",
        "ctrl+k ctrl+c",
        "ctrl+shift+alt+pageup",
    };
    for (cases) |c| {
        const parsed = try parseKeys(c, .other);
        const formatted = try formatKeys(t.allocator, parsed, .other);
        defer t.allocator.free(formatted);
        try t.expectEqualStrings(c, formatted);
        // And the formatted form parses back to the same stroke.
        try t.expect(parsed.eql(try parseKeys(formatted, .other)));
    }
}

test "every key formats to something that parses back" {
    for (std.enums.values(Key)) |k| {
        if (@import("Key.zig").isModifier(k)) continue;
        const s: Stroke = .{ .first = .{ .key = k, .mods = .{ .ctrl = true, .alt = true } } };
        const text = try formatKeys(t.allocator, s, .other);
        defer t.allocator.free(text);
        try t.expect(s.eql(try parseKeys(text, .other)));
    }
}
