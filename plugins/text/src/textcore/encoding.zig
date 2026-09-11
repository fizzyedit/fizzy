//! What the editor can and cannot show: the byte-level test that separates text from
//! everything else, before any of it reaches a layout.
const std = @import("std");

/// How much of a file is examined before deciding it is not text. Enough to get past any
/// header a text format might have; small enough that the check does not register on a
/// 64 MiB open.
const binary_sniff_bytes: usize = 8 * 1024;

/// Whether `bytes` are something this editor can show. A text file may contain any UTF-8 but
/// never a NUL, and a binary file almost always contains one in its first few KiB — the same
/// test git and most editors use. Invalid UTF-8 in the sample is treated the same way: dvui's
/// text layout is a UTF-8 layout, and feeding it arbitrary bytes trips its own consistency
/// assertions rather than producing mojibake.
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
