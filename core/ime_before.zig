//! The text before a field's caret that an on-screen keyboard is given when the app, not the
//! keyboard, changed the field (`platform.requestImeReset`). A keyboard reads it for suggestions
//! and corrections, so a short tail is enough. std-only.

const std = @import("std");

/// The most bytes of text before the caret a keyboard is given.
pub const max = 128;

/// At most `max` bytes of `text` ending at `cursor`, starting on a UTF-8 boundary. A cut that
/// would land inside a sequence moves forward to the next sequence's start.
pub fn tail(text: []const u8, cursor: usize) []const u8 {
    const end = @min(cursor, text.len);
    var start = end -| max;
    while (start < end and isContinuation(text[start])) : (start += 1) {}
    return text[start..end];
}

fn isContinuation(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}

fn repeat(comptime byte: u8, comptime n: usize) *const [n]u8 {
    const bytes: [n]u8 = @splat(byte);
    return &bytes;
}

test "empty text gives an empty tail" {
    try std.testing.expectEqualStrings("", tail("", 0));
}

test "text shorter than max is given whole" {
    try std.testing.expectEqualStrings("hello", tail("hello", 5));
}

test "text longer than max is cut to the last max bytes" {
    const text = repeat('a', max + 10);
    const t = tail(text, text.len);
    try std.testing.expectEqual(max, t.len);
    try std.testing.expectEqual(@as([*]const u8, text) + 10, t.ptr);
}

test "a cut inside a 3-byte sequence moves to the next boundary" {
    // "€" is 3 bytes; the cut at len - max lands on its second byte.
    const text = "x€" ++ repeat('a', max - 2);
    try std.testing.expectEqual(max + 2, text.len);
    try std.testing.expectEqualStrings(repeat('a', max - 2), tail(text, text.len));
}

test "a cut inside a 4-byte sequence moves to the next boundary" {
    // "😀" is 4 bytes; the cut at len - max lands on its second byte.
    const text = "x😀" ++ repeat('b', max - 3);
    try std.testing.expectEqual(max + 2, text.len);
    try std.testing.expectEqualStrings(repeat('b', max - 3), tail(text, text.len));
}

test "a caret in the middle ends the tail there" {
    try std.testing.expectEqualStrings("hel", tail("hello", 3));
    const text = repeat('c', max + 20);
    const t = tail(text, max + 5);
    try std.testing.expectEqual(max, t.len);
    try std.testing.expectEqual(@as([*]const u8, text) + 5, t.ptr);
}
