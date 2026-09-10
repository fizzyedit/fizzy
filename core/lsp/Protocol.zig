//! Minimal JSON-RPC 2.0 framing + the handful of LSP request/response shapes this plugin
//! actually sends (`initialize`, `initialized`, `textDocument/didOpen`, `didChange`,
//! `hover`, `definition`). Deliberately not a general LSP type library — see
//! `docs/PLUGINS.md` in the fizzy repo for why the SDK boundary keeps `bytes`/`path` as
//! plain parameters instead of a richer document model.
const std = @import("std");

/// An empty JSON object (`{}`), e.g. for `InitializedParams`. Deliberately a named struct
/// type, not `.{}` — Zig infers the anonymous empty-struct literal `.{}` as a distinct
/// "tuple" type (all-positional-fields is vacuously true with zero fields), and
/// `std.json.Stringify` follows that to serialize it as `[]` instead of `{}`. LSP servers
/// (zls included) reject a JSON array where an object is required for `params`, so this
/// silent mis-serialization previously crashed zls right after `initialize`.
pub const EmptyObject = struct {};

/// Whether LSP `Position.character` is a UTF-8 byte offset within the line (if the server
/// honored our `general.positionEncodings: ["utf-8"]` capability) or the LSP-default UTF-16
/// code-unit offset. Negotiated once during `initialize`; see `Client.zig`.
pub const PositionEncoding = enum { utf8, utf16 };

pub const Position = struct {
    line: u32,
    character: u32,
};

/// Convert a byte offset into `text` to an LSP `Position`, in the given encoding.
pub fn byteOffsetToPosition(text: []const u8, byte_offset: usize, encoding: PositionEncoding) Position {
    const offset = @min(byte_offset, text.len);
    var line: u32 = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < offset) : (i += 1) {
        if (text[i] == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    const line_bytes = text[line_start..offset];
    const character: u32 = switch (encoding) {
        .utf8 => @intCast(line_bytes.len),
        // `byte_offset` comes from UI-side hit-testing, not zls, so it isn't guaranteed to
        // land on a UTF-8 character boundary — `Utf8View.initUnchecked` trusts its input is
        // valid UTF-8 and its iterator does `catch unreachable` on a bad byte sequence
        // (crashed on Windows: "reached unreachable code" on every hover). Validate first and
        // fall back to a byte count, which is wrong by at most a few units for the rare
        // misaligned/invalid case, rather than panicking.
        .utf16 => blk: {
            if (!std.unicode.utf8ValidateSlice(line_bytes)) break :blk @intCast(line_bytes.len);
            var units: u32 = 0;
            var view = std.unicode.Utf8View.initUnchecked(line_bytes);
            var it = view.iterator();
            while (it.nextCodepoint()) |cp| {
                units += if (cp > 0xFFFF) 2 else 1;
            }
            break :blk units;
        },
    };
    return .{ .line = line, .character = character };
}

/// Convert an LSP `Position` back to a byte offset into `text`.
pub fn positionToByteOffset(text: []const u8, pos: Position, encoding: PositionEncoding) usize {
    var line: u32 = 0;
    var i: usize = 0;
    while (line < pos.line and i < text.len) : (i += 1) {
        if (text[i] == '\n') line += 1;
    }
    if (line < pos.line) return text.len; // position past EOF, clamp

    const line_start = i;
    var line_end = line_start;
    while (line_end < text.len and text[line_end] != '\n') : (line_end += 1) {}
    const line_bytes = text[line_start..line_end];

    switch (encoding) {
        .utf8 => return line_start + @min(pos.character, line_bytes.len),
        // See `byteOffsetToPosition`'s matching `.utf16` branch for why this validates first
        // instead of trusting `initUnchecked`.
        .utf16 => {
            if (!std.unicode.utf8ValidateSlice(line_bytes)) return line_start + @min(pos.character, line_bytes.len);
            var units: u32 = 0;
            var byte_off: usize = 0;
            var view = std.unicode.Utf8View.initUnchecked(line_bytes);
            var it = view.iterator();
            while (units < pos.character) {
                const cp = it.nextCodepoint() orelse break;
                units += if (cp > 0xFFFF) 2 else 1;
                byte_off = it.i;
            }
            return line_start + byte_off;
        },
    }
}

/// Serializes `value` to JSON and writes it as one `Content-Length`-framed LSP message.
pub fn writeMessage(allocator: std.mem.Allocator, writer: *std.Io.Writer, value: anytype) !void {
    const body = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(body);
    try writer.print("Content-Length: {d}\r\n\r\n", .{body.len});
    try writer.writeAll(body);
    try writer.flush();
}

/// Reads one `Content-Length`-framed message body from `reader`. Returned slice is owned by
/// the caller (allocated with `allocator`).
pub fn readMessage(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    var content_length: ?usize = null;
    while (true) {
        // `takeDelimiterInclusive` (not `...Exclusive`) — the exclusive variant returns the
        // line without the delimiter but crucially does *not* consume the delimiter from the
        // stream either, leaving the `\n` for the next call to trip over as a phantom
        // zero-length line. Take the line including `\n`, then strip it (and any `\r`)
        // ourselves.
        const raw_line = try reader.takeDelimiterInclusive('\n');
        const line = std.mem.trimEnd(u8, raw_line, "\n");
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (trimmed.len == 0) break; // blank line ends the header block
        if (std.ascii.startsWithIgnoreCase(trimmed, "content-length:")) {
            const value = std.mem.trim(u8, trimmed["content-length:".len..], " \t");
            content_length = try std.fmt.parseInt(usize, value, 10);
        }
        // Other headers (e.g. Content-Type) are ignored.
    }
    const len = content_length orelse return error.MissingContentLength;
    const body = try allocator.alloc(u8, len);
    errdefer allocator.free(body);
    try reader.readSliceAll(body);
    return body;
}

pub fn nextRequestId(counter: *std.atomic.Value(i64)) i64 {
    return counter.fetchAdd(1, .monotonic);
}

/// A parsed JSON-RPC message frame's relevant fields, borrowed from a `std.json.Parsed(Value)`
/// the caller owns and frees. One shape covers all three message kinds a server can send:
/// - a **response** to a request we sent: `id` set, `method` null, `result`/`err` from the
///   server's answer.
/// - a **request** the server is sending *to us* (e.g. `workspace/configuration`,
///   `client/registerCapability`): both `id` and `method` set — callers must reply (see
///   `Client.handleServerRequest`), unlike a response or a notification.
/// - a **notification** (e.g. `textDocument/publishDiagnostics`, `window/logMessage`): `id`
///   null, `method` set. No reply expected or possible (it carries no `id` to reply to).
pub const ParsedResponse = struct {
    id: ?i64,
    /// Present only on a server-to-client request/notification, never on a response to our
    /// own request (a response's `method` would be redundant — we already know which request
    /// it answers via `id`).
    method: ?[]const u8,
    /// Present on a server-to-client request's params, or a notification's params.
    params: ?std.json.Value,
    /// Present on success (of a response to our own request).
    result: ?std.json.Value,
    /// Present on failure; `.message` is the error text if any.
    err: ?std.json.Value,
};

pub fn parseResponse(parsed: std.json.Value) ParsedResponse {
    var out: ParsedResponse = .{ .id = null, .method = null, .params = null, .result = null, .err = null };
    const obj = switch (parsed) {
        .object => |o| o,
        else => return out,
    };
    if (obj.get("id")) |id_v| {
        switch (id_v) {
            .integer => |n| out.id = n,
            else => {},
        }
    }
    if (obj.get("method")) |m| {
        switch (m) {
            .string => |s| out.method = s,
            else => {},
        }
    }
    out.params = obj.get("params");
    out.result = obj.get("result");
    out.err = obj.get("error");
    return out;
}

test "readMessage parses a single Content-Length-framed message" {
    const allocator = std.testing.allocator;
    const frame = "Content-Length: 14\r\n\r\n{\"jsonrpc\":\"\"}";
    var reader = std.Io.Reader.fixed(frame);
    const body = try readMessage(allocator, &reader);
    defer allocator.free(body);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"\"}", body);
}

test "readMessage parses back-to-back messages correctly (regression: header delimiter must be consumed)" {
    // Regression test for a bug where `takeDelimiterExclusive` was used without also
    // consuming the delimiter byte it leaves behind, causing every header line after the
    // first to be misread as an empty line terminating the header block early, and the
    // body read to start at the wrong offset. Two full messages back to back is the
    // minimal repro: the first message's parsing must not corrupt the stream position for
    // the second.
    const allocator = std.testing.allocator;
    const frame =
        "Content-Length: 13\r\n\r\n{\"a\":\"first\"}" ++
        "Content-Length: 14\r\n\r\n{\"a\":\"second\"}";
    var reader = std.Io.Reader.fixed(frame);

    const first = try readMessage(allocator, &reader);
    defer allocator.free(first);
    try std.testing.expectEqualStrings("{\"a\":\"first\"}", first);

    const second = try readMessage(allocator, &reader);
    defer allocator.free(second);
    try std.testing.expectEqualStrings("{\"a\":\"second\"}", second);
}

test "readMessage ignores non-Content-Length headers" {
    const allocator = std.testing.allocator;
    const frame = "Content-Type: application/vscode-jsonrpc\r\nContent-Length: 7\r\n\r\n{\"x\":1}";
    var reader = std.Io.Reader.fixed(frame);
    const body = try readMessage(allocator, &reader);
    defer allocator.free(body);
    try std.testing.expectEqualStrings("{\"x\":1}", body);
}

test "writeMessage / readMessage roundtrip" {
    const allocator = std.testing.allocator;
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeMessage(allocator, &writer, .{ .jsonrpc = "2.0", .id = 1, .method = "initialize" });

    var reader = std.Io.Reader.fixed(writer.buffered());
    const body = try readMessage(allocator, &reader);
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const resp = parseResponse(parsed.value);
    try std.testing.expectEqual(@as(?i64, 1), resp.id);
}
