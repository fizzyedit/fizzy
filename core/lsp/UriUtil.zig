//! Absolute file path <-> `file://` URI conversion for LSP requests. Deliberately minimal:
//! handles the POSIX-path case and the Windows drive-letter case (language servers built on
//! this client always run locally next to the editor) rather than the full URI grammar.
const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.target.os.tag == .windows;

/// Percent-encodes `path` and prefixes it with `file://`. On POSIX, `path` is expected to
/// start with `/`, giving the conventional `file:///abs/path` triple-slash form. On Windows,
/// `path` starts with a drive letter (`C:\Users\...`); a leading `/` is inserted before the
/// drive letter and `\` separators are turned into `/`, giving `file:///C:/Users/...`. Without
/// that leading slash, `C:` sitting right after `file://` reads as URI authority `host=C
/// port=<garbage>`, which is what sent zls (the first server built on this client) into
/// `error.InvalidPort` on Windows.
pub fn pathToUri(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "file://");

    var rest = path;
    if (comptime is_windows) {
        if (path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':') {
            // The drive colon is left unescaped per the conventional Windows file URI form.
            try out.print(allocator, "/{c}:", .{path[0]});
            rest = path[2..];
        }
    }

    for (rest) |raw_c| {
        const c = if (comptime is_windows) (if (raw_c == '\\') '/' else raw_c) else raw_c;
        switch (c) {
            // RFC 3986 unreserved + the path separator; everything else gets escaped.
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~', '/' => try out.append(allocator, c),
            else => try out.print(allocator, "%{X:0>2}", .{c}),
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Reverses `pathToUri`. Returns an error if `uri` isn't a `file://` URI.
pub fn uriToPath(allocator: std.mem.Allocator, uri: []const u8) ![]u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return error.UnsupportedScheme;
    const encoded = uri[prefix.len..];

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < encoded.len) {
        if (encoded[i] == '%' and i + 2 < encoded.len) {
            const byte = std.fmt.parseInt(u8, encoded[i + 1 .. i + 3], 16) catch {
                try out.append(allocator, encoded[i]);
                i += 1;
                continue;
            };
            try out.append(allocator, byte);
            i += 3;
        } else {
            try out.append(allocator, encoded[i]);
            i += 1;
        }
    }

    if (comptime is_windows) {
        // `file:///C:/Users/...` decodes to `/C:/Users/...` above; strip the leading slash and
        // swap separators back to `\` so this round-trips into a usable native Windows path.
        if (out.items.len >= 3 and out.items[0] == '/' and std.ascii.isAlphabetic(out.items[1]) and out.items[2] == ':') {
            _ = out.orderedRemove(0);
        }
        for (out.items) |*c| {
            if (c.* == '/') c.* = '\\';
        }
    }

    return out.toOwnedSlice(allocator);
}

test "pathToUri / uriToPath roundtrip" {
    if (comptime is_windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const path = "/Users/foxnne/dev/fizzy/src/App.zig";
    const uri = try pathToUri(allocator, path);
    defer allocator.free(uri);
    try std.testing.expectEqualStrings("file:///Users/foxnne/dev/fizzy/src/App.zig", uri);

    const back = try uriToPath(allocator, uri);
    defer allocator.free(back);
    try std.testing.expectEqualStrings(path, back);
}

test "pathToUri escapes spaces" {
    const allocator = std.testing.allocator;
    const uri = try pathToUri(allocator, "/a path/with space.zig");
    defer allocator.free(uri);
    try std.testing.expectEqualStrings("file:///a%20path/with%20space.zig", uri);
}

test "pathToUri / uriToPath roundtrip on Windows drive-letter paths" {
    if (comptime !is_windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const path = "C:\\Users\\foxnne\\dev\\fizzy\\src\\App.zig";
    const uri = try pathToUri(allocator, path);
    defer allocator.free(uri);
    try std.testing.expectEqualStrings("file:///C:/Users/foxnne/dev/fizzy/src/App.zig", uri);

    const back = try uriToPath(allocator, uri);
    defer allocator.free(back);
    try std.testing.expectEqualStrings(path, back);
}
