//! Byte-level helpers before anything reaches a layout: sniff binary, and turn arbitrary
//! bytes into UTF-8 dvui can draw.
const std = @import("std");

/// How much of a file is examined before deciding it is not text. Enough to get past any
/// header a text format might have; small enough that the check does not register on a
/// 64 MiB open.
const binary_sniff_bytes: usize = 8 * 1024;

/// U+FFFD — what a NUL or a malformed sequence becomes so the buffer stays valid UTF-8.
const replacement = "\u{FFFD}";

/// Whether `bytes` look like something other than text. A text file may contain any UTF-8 but
/// never a NUL, and a binary file almost always contains one in its first few KiB — the same
/// test git and most editors use. Used to warn, not to refuse: unknown files still open.
pub fn looksBinary(bytes: []const u8) bool {
    const sample = bytes[0..@min(bytes.len, binary_sniff_bytes)];
    if (std.mem.indexOfScalar(u8, sample, 0) != null) return true;
    // The sample may end mid-codepoint; only a *malformed* sequence counts, not a truncated one.
    var i: usize = 0;
    while (i < sample.len) {
        const n = std.unicode.utf8ByteSequenceLength(sample[i]) catch return true;
        if (i + n > sample.len) break;
        _ = std.unicode.utf8Decode(sample[i..][0..n]) catch return true;
        i += n;
    }
    return false;
}

test looksBinary {
    try std.testing.expect(!looksBinary(""));
    try std.testing.expect(!looksBinary("plain ascii\n"));
    try std.testing.expect(!looksBinary("h\xc3\xa9llo \xe2\x80\x94 \xf0\x9f\x8d\x80"));
    try std.testing.expect(looksBinary("GIF89a\x00\x01"));
    try std.testing.expect(looksBinary("\xff\xfe not utf8"));
    // A multi-byte sequence cut off by the sample boundary is not malformed.
    var big: [binary_sniff_bytes + 2]u8 = @splat('a');
    big[binary_sniff_bytes - 1] = 0xe2;
    big[binary_sniff_bytes] = 0x80;
    big[binary_sniff_bytes + 1] = 0x94;
    try std.testing.expect(!looksBinary(&big));
}

/// Append `bytes` as UTF-8, replacing NULs and malformed sequences with U+FFFD. The result
/// is always something dvui's text layout can draw — including a `.fiz` or `.DS_Store` that
/// no specialized plugin claimed.
pub fn appendLossy(list: *std.ArrayList(u8), gpa: std.mem.Allocator, bytes: []const u8) !void {
    var i: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] == 0) {
            try list.appendSlice(gpa, replacement);
            i += 1;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            try list.appendSlice(gpa, replacement);
            i += 1;
            continue;
        };
        if (i + n > bytes.len) {
            try list.appendSlice(gpa, replacement);
            break;
        }
        if (std.unicode.utf8Decode(bytes[i..][0..n])) |_| {
            try list.appendSlice(gpa, bytes[i .. i + n]);
            i += n;
        } else |_| {
            try list.appendSlice(gpa, replacement);
            i += 1;
        }
    }
}

test appendLossy {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try appendLossy(&list, std.testing.allocator, "plain");
    try std.testing.expectEqualStrings("plain", list.items);
    list.clearRetainingCapacity();
    try appendLossy(&list, std.testing.allocator, "a\x00b\xffc");
    try std.testing.expectEqualStrings("a\u{FFFD}b\u{FFFD}c", list.items);
}
