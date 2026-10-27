//! What the composer and the message list decide, std-only so it tests without a Window: what
//! Enter does, how many lines the composer shows, and where a message's ``` fences begin and end.
const std = @import("std");

/// Lines the composer grows to; past this it scrolls.
pub const max_lines: usize = 8;

pub const Enter = enum { send, newline };

/// Enter sends on a desktop and is a new line on a phone, where the send button sends; Shift+Enter
/// is a new line anywhere.
pub fn enter(shift: bool, mobile: bool) Enter {
    return if (shift or mobile) .newline else .send;
}

/// The lines the composer shows for `wrapped` lines of text: one while empty, growing with the
/// text up to `max_lines`.
pub fn visibleLines(wrapped: usize) usize {
    return std.math.clamp(wrapped, 1, max_lines);
}

/// `text` with the whitespace around it removed, or null when nothing is left to send.
pub fn sendable(text: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    return if (t.len == 0) null else t;
}

pub const Segment = struct {
    kind: enum { text, code },
    body: []const u8,
    /// The word after the opening fence, for a code segment; empty if none.
    lang: []const u8 = "",
};

/// Splits a message into plain text and finished ``` fences, in order. A fence is finished when a
/// later line is a bare ```; an unfinished one stays text.
pub const Segments = struct {
    text: []const u8,
    pos: usize = 0,

    pub fn next(self: *Segments) ?Segment {
        const rest = self.text[self.pos..];
        if (rest.len == 0) return null;
        var line_start: usize = 0;
        while (line_start < rest.len) {
            const line_end = std.mem.findScalarPos(u8, rest, line_start, '\n') orelse rest.len;
            const line = std.mem.trimEnd(u8, rest[line_start..line_end], "\r");
            if (std.mem.startsWith(u8, line, "```")) {
                if (closingFence(rest, line_end)) |close| {
                    if (line_start > 0) {
                        self.pos += line_start;
                        return .{ .kind = .text, .body = std.mem.trim(u8, rest[0..line_start], "\n") };
                    }
                    self.pos += close.after;
                    return .{
                        .kind = .code,
                        .body = rest[@min(line_end + 1, close.body_end)..close.body_end],
                        .lang = std.mem.trim(u8, line[3..], " \t"),
                    };
                }
                break;
            }
            line_start = line_end + 1;
        }
        self.pos = self.text.len;
        return .{ .kind = .text, .body = std.mem.trim(u8, rest, "\n") };
    }
};

const Close = struct { body_end: usize, after: usize };

/// The line after `open_end` that is a bare ```: where the code before it ends and the text after
/// it begins.
fn closingFence(rest: []const u8, open_end: usize) ?Close {
    var start = open_end + 1;
    while (start <= rest.len) {
        const end = std.mem.findScalarPos(u8, rest, start, '\n') orelse rest.len;
        if (std.mem.eql(u8, std.mem.trim(u8, rest[start..end], " \t\r"), "```")) {
            return .{ .body_end = if (start > 0) start - 1 else start, .after = @min(end + 1, rest.len) };
        }
        if (end == rest.len) return null;
        start = end + 1;
    }
    return null;
}

test "Enter sends on a desktop and breaks the line on a phone or with Shift" {
    try std.testing.expectEqual(Enter.send, enter(false, false));
    try std.testing.expectEqual(Enter.newline, enter(true, false));
    try std.testing.expectEqual(Enter.newline, enter(false, true));
    try std.testing.expectEqual(Enter.newline, enter(true, true));
}

test "the composer grows with its lines up to the cap" {
    try std.testing.expectEqual(@as(usize, 1), visibleLines(0));
    try std.testing.expectEqual(@as(usize, 3), visibleLines(3));
    try std.testing.expectEqual(max_lines, visibleLines(max_lines + 4));
}

test "only text with something in it can be sent" {
    try std.testing.expect(sendable(" \n\t") == null);
    try std.testing.expectEqualStrings("hi", sendable("  hi\n").?);
}

test "a finished fence is a code segment between its text" {
    var it: Segments = .{ .text = "before\n```zig\nconst a = 1;\n```\nafter" };
    const a = it.next().?;
    try std.testing.expectEqual(.text, a.kind);
    try std.testing.expectEqualStrings("before", a.body);
    const b = it.next().?;
    try std.testing.expectEqual(.code, b.kind);
    try std.testing.expectEqualStrings("zig", b.lang);
    try std.testing.expectEqualStrings("const a = 1;", b.body);
    const c = it.next().?;
    try std.testing.expectEqualStrings("after", c.body);
    try std.testing.expect(it.next() == null);
}

test "an unfinished fence stays text" {
    var it: Segments = .{ .text = "look\n```\nnot closed" };
    const a = it.next().?;
    try std.testing.expectEqual(.text, a.kind);
    try std.testing.expectEqualStrings("look\n```\nnot closed", a.body);
    try std.testing.expect(it.next() == null);
}

test "an empty fence is an empty code segment" {
    var it: Segments = .{ .text = "```\n```" };
    const a = it.next().?;
    try std.testing.expectEqual(.code, a.kind);
    try std.testing.expectEqualStrings("", a.body);
    try std.testing.expect(it.next() == null);
}
