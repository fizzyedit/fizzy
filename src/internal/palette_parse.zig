//! Pure parser for `.hex` palette files.
//!
//! Extracted from `internal/Palette.zig` so `zig build test` can
//! exercise it without pulling in dvui / fizzy globals.
//!
//! The `.hex` format is one 6-digit RRGGBB hex color per line. Empty
//! lines and lines beginning with `#` (comments) are ignored. The
//! parser intentionally accepts both LF (`\n`) and CRLF line endings;
//! the historical implementation depended on a trailing newline, but
//! this version handles a missing trailing newline gracefully too.

const std = @import("std");

pub const Error = error{
    InvalidHexLine,
    OutOfMemory,
};

const PackedColor = packed struct(u32) { r: u8, g: u8, b: u8, a: u8 };

/// Parse `bytes` as a `.hex` palette file into a heap-allocated slice
/// of RGBA colors. Returns `Error.InvalidHexLine` on the first line
/// that is non-empty, non-comment, and fails to parse as a 6-digit
/// hex value.
///
/// The caller owns the returned slice and must free it with the same
/// allocator passed in.
pub fn parseHexBytes(allocator: std.mem.Allocator, bytes: []const u8) Error![][4]u8 {
    var colors = std.array_list.Managed([4]u8).init(allocator);
    errdefer colors.deinit();

    var iter = std.mem.splitSequence(u8, bytes, "\n");
    while (iter.next()) |raw_line| {
        const line = trimLine(raw_line);
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        const color_u32 = std.fmt.parseInt(u32, line, 16) catch {
            return Error.InvalidHexLine;
        };
        const packed_color: PackedColor = @bitCast(color_u32);
        // The original loader byte-shuffles to {b, g, r, 255}; preserve
        // that exactly so existing palettes load identically.
        try colors.append(.{ packed_color.b, packed_color.g, packed_color.r, 255 });
    }

    return colors.toOwnedSlice() catch return Error.OutOfMemory;
}

/// Trim trailing CR (handles CRLF input) and surrounding whitespace.
fn trimLine(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

test "parseHexBytes parses 4 valid hex lines" {
    const bytes = "112233\n445566\nAABBCC\nDEADBE\n";
    const colors = try parseHexBytes(std.testing.allocator, bytes);
    defer std.testing.allocator.free(colors);

    try expectEqual(@as(usize, 4), colors.len);
    for (colors) |c| try expectEqual(@as(u8, 255), c[3]);

    // Verify the historical byte-shuffle: line "112233" produces the
    // BGR-swapped triple {0x33, 0x22, 0x11, 0xff}.
    try expectEqualSlices(u8, &.{ 0x33, 0x22, 0x11, 0xff }, &colors[0]);
    try expectEqualSlices(u8, &.{ 0x66, 0x55, 0x44, 0xff }, &colors[1]);
    try expectEqualSlices(u8, &.{ 0xcc, 0xbb, 0xaa, 0xff }, &colors[2]);
    try expectEqualSlices(u8, &.{ 0xbe, 0xad, 0xde, 0xff }, &colors[3]);
}

test "parseHexBytes ignores blank lines and comments" {
    const bytes =
        \\# fizzy default palette
        \\
        \\112233
        \\# another comment
        \\445566
        \\
    ;
    const colors = try parseHexBytes(std.testing.allocator, bytes);
    defer std.testing.allocator.free(colors);
    try expectEqual(@as(usize, 2), colors.len);
}

test "parseHexBytes accepts CRLF line endings" {
    const bytes = "112233\r\n445566\r\n";
    const colors = try parseHexBytes(std.testing.allocator, bytes);
    defer std.testing.allocator.free(colors);
    try expectEqual(@as(usize, 2), colors.len);
}

test "parseHexBytes accepts a trailing line without newline" {
    const bytes = "112233\n445566";
    const colors = try parseHexBytes(std.testing.allocator, bytes);
    defer std.testing.allocator.free(colors);
    try expectEqual(@as(usize, 2), colors.len);
}

test "parseHexBytes returns InvalidHexLine on malformed input" {
    const bytes = "112233\nNOTHEX\n";
    const result = parseHexBytes(std.testing.allocator, bytes);
    try std.testing.expectError(Error.InvalidHexLine, result);
}

test "parseHexBytes on empty input returns an empty slice" {
    const colors = try parseHexBytes(std.testing.allocator, "");
    defer std.testing.allocator.free(colors);
    try expectEqual(@as(usize, 0), colors.len);
}
