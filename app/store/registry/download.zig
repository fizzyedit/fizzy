//! Download + SHA-256-verified install of a plugin binary into the plugins dir.
//!
//! The downloaded bytes are verified against the manifest's `sha256` before being written, and
//! the host's ABI fingerprint + id are re-checked at load time (`PluginLoader`). Hashing logic
//! is unit-tested; the network + filesystem half is exercised by the Chunk 5/7 E2E.
const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Error = error{ HttpStatus, Sha256Mismatch };

/// Lowercase-hex SHA-256 of `data`.
pub fn sha256Hex(data: []const u8) [Sha256.digest_length * 2]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(data, &digest, .{});
    var hex: [Sha256.digest_length * 2]u8 = undefined;
    const charset = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        hex[i * 2] = charset[b >> 4];
        hex[i * 2 + 1] = charset[b & 0xf];
    }
    return hex;
}

/// True if `data`'s SHA-256 equals `expected_hex` (case-insensitive, surrounding whitespace
/// ignored). A malformed expectation (wrong length) is treated as a mismatch.
pub fn matchesSha256(data: []const u8, expected_hex: []const u8) bool {
    const exp = std.mem.trim(u8, expected_hex, " \t\r\n");
    if (exp.len != Sha256.digest_length * 2) return false;
    const actual = sha256Hex(data);
    for (actual, 0..) |c, i| {
        if (std.ascii.toLower(exp[i]) != c) return false;
    }
    return true;
}

/// HTTPS GET `url` into memory, verify its SHA-256, then atomically install at `dest_path`
/// (absolute; e.g. `{config}/plugins/{id}.{ext}`) via a temp file + rename. Rejects and
/// installs nothing on a non-200 status or a hash mismatch.
pub fn download(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    expected_sha256: []const u8,
    dest_path: []const u8,
) !void {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
    });
    if (result.status != .ok) return error.HttpStatus;

    const data = body.written();
    if (!matchesSha256(data, expected_sha256)) return error.Sha256Mismatch;

    // Write to a sibling temp file, then rename into place so a crash mid-write never leaves a
    // half-written dylib at the load path.
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.part", .{dest_path});
    defer allocator.free(tmp_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_path, .data = data });
    try std.Io.Dir.renameAbsolute(tmp_path, dest_path, io);
}

const testing = std.testing;

test "sha256Hex matches a known vector" {
    // SHA-256("abc")
    const want = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    try testing.expectEqualStrings(want, &sha256Hex("abc"));
}

test "matchesSha256 accepts correct digest case-insensitively, rejects others" {
    const want = "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD";
    try testing.expect(matchesSha256("abc", want));
    try testing.expect(matchesSha256("abc", "  ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad \n"));
    try testing.expect(!matchesSha256("abcd", want)); // wrong data
    try testing.expect(!matchesSha256("abc", "deadbeef")); // wrong length
}
