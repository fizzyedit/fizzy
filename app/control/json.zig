//! JSON at the control server's edge, ZON inside: a command's arguments arrive as JSON and go to
//! `Host.callCommand` as ZON, and its ZON result goes back out as JSON. The one place the two
//! meet, so the plugin boundary never sees JSON (plans/CONTROL_SERVER_PLAN.md).
//!
//! The mapping is the obvious one both ways - objects and structs, arrays and tuples, strings,
//! numbers, booleans, null - with one thing JSON cannot say: an enum. Going in, a string is an
//! enum literal where the command's parameter is an enumeration (`enum_keys`); everywhere else it
//! is a string. Going out, an enum literal is its name as a string. A caller who needs an enum
//! deeper than a top-level argument sends ZON instead (`Content-Type: application/zon`).
//!
//! std-only, with a unit-test root of its own (`build/app.zig`).
const std = @import("std");

pub const Error = error{ OutOfMemory, NotJson, NotAnObject, NotZon, NotUtf8 };

/// `json`, an object of arguments, as a ZON struct literal: `{"line": 12}` -> `.{.line=12}`. A
/// top-level string whose key is in `enum_keys` becomes an enum literal. An empty body is no
/// arguments, `""`.
pub fn zonFromJson(arena: std.mem.Allocator, json: []const u8, enum_keys: []const []const u8) Error![]u8 {
    if (std.mem.trim(u8, json, " \t\r\n").len == 0) return arena.dupe(u8, "");
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotJson,
    };
    if (value != .object) return error.NotAnObject;
    var out: std.Io.Writer.Allocating = .init(arena);
    writeZonObject(&out.writer, value.object, enum_keys) catch return error.OutOfMemory;
    return out.written();
}

fn writeZonObject(w: *std.Io.Writer, object: std.json.ObjectMap, enum_keys: []const []const u8) std.Io.Writer.Error!void {
    try w.writeAll(".{");
    var it = object.iterator();
    var first = true;
    while (it.next()) |entry| {
        if (!first) try w.writeByte(',');
        first = false;
        try w.print(".{f}=", .{std.zig.fmtId(entry.key_ptr.*)});
        const as_enum = for (enum_keys) |k| {
            if (std.mem.eql(u8, k, entry.key_ptr.*)) break true;
        } else false;
        if (as_enum and entry.value_ptr.* == .string) {
            try w.print(".{f}", .{std.zig.fmtId(entry.value_ptr.string)});
        } else try writeZon(w, entry.value_ptr.*);
    }
    try w.writeByte('}');
}

fn writeZon(w: *std.Io.Writer, value: std.json.Value) std.Io.Writer.Error!void {
    switch (value) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |n| try w.print("{d}", .{n}),
        // ZON reads `-0` as an integer it refuses; `-0.0` it takes.
        .float => |f| if (f == 0 and std.math.signbit(f)) try w.writeAll("-0.0") else try w.print("{d}", .{f}),
        .number_string => |s| try w.writeAll(s),
        .string => |s| try w.print("\"{f}\"", .{std.zig.fmtString(s)}),
        .array => |a| {
            try w.writeAll(".{");
            for (a.items, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try writeZon(w, item);
            }
            try w.writeByte('}');
        },
        .object => |o| try writeZonObject(w, o, &.{}),
    }
}

/// `zon`, a command's result, as JSON. Empty or absent is `null`.
pub fn jsonFromZon(arena: std.mem.Allocator, zon: ?[]const u8) Error![]u8 {
    const text = zon orelse return arena.dupe(u8, "null");
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return arena.dupe(u8, "null");
    const source = try arena.dupeSentinel(u8, text, 0);
    const ast = try std.zig.Ast.parse(arena, source, .{ .mode = .zon });
    if (ast.errors.len > 0) return error.NotZon;
    const zoir = try std.zig.ZonGen.generate(arena, ast, .{ .parse_str_lits = true });
    if (zoir.hasCompileErrors()) return error.NotZon;
    var out: std.Io.Writer.Allocating = .init(arena);
    writeJson(&out.writer, &zoir, .root) catch |err| return switch (err) {
        error.NotUtf8 => error.NotUtf8,
        error.WriteFailed => error.OutOfMemory,
    };
    return out.written();
}

/// JSON strings are UTF-8, and std copies other bytes through as they are: a result holding them
/// is refused rather than sent as a body no client can parse.
fn writeString(w: *std.Io.Writer, s: []const u8) (std.Io.Writer.Error || error{NotUtf8})!void {
    if (!std.unicode.utf8ValidateSlice(s)) return error.NotUtf8;
    try std.json.Stringify.encodeJsonString(s, .{}, w);
}

fn writeJson(w: *std.Io.Writer, zoir: *const std.zig.Zoir, index: std.zig.Zoir.Node.Index) (std.Io.Writer.Error || error{NotUtf8})!void {
    switch (index.get(zoir)) {
        .true => try w.writeAll("true"),
        .false => try w.writeAll("false"),
        // JSON has no infinities or NaN.
        .null, .pos_inf, .neg_inf, .nan => try w.writeAll("null"),
        .int_literal => |n| switch (n) {
            .small => |s| try w.print("{d}", .{s}),
            .big => |b| try w.print("{f}", .{b}),
        },
        // Beyond f64 (`1e400`) is an infinity, which JSON cannot say either.
        .float_literal => |f| {
            const d: f64 = @floatCast(f);
            if (std.math.isFinite(d)) try w.print("{d}", .{d}) else try w.writeAll("null");
        },
        .char_literal => |c| try w.print("{d}", .{c}),
        .enum_literal => |name| try writeString(w, name.get(zoir)),
        .string_literal => |s| try writeString(w, s),
        // `.{}` is an empty struct as much as an empty tuple; a list is the likelier reading of a
        // command's result (no changes, no matches), and a client iterating it must not choke.
        .empty_literal => try w.writeAll("[]"),
        .array_literal => |range| {
            try w.writeByte('[');
            for (0..range.len) |i| {
                if (i > 0) try w.writeByte(',');
                try writeJson(w, zoir, range.at(@intCast(i)));
            }
            try w.writeByte(']');
        },
        .struct_literal => |s| {
            try w.writeByte('{');
            for (s.names, 0..) |name, i| {
                if (i > 0) try w.writeByte(',');
                try writeString(w, name.get(zoir));
                try w.writeByte(':');
                try writeJson(w, zoir, s.vals.at(@intCast(i)));
            }
            try w.writeByte('}');
        },
    }
}

test "arguments: JSON object to a ZON struct literal" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("", try zonFromJson(a, " \n", &.{}));
    try std.testing.expectEqualStrings(".{}", try zonFromJson(a, "{}", &.{}));
    try std.testing.expectEqualStrings(
        ".{.line=12,.path=\"a \\\"b\\\".zig\",.on=true,.none=null,.xs=.{1,2.5},.at=.{.x=1}}",
        try zonFromJson(a, "{\"line\":12,\"path\":\"a \\\"b\\\".zig\",\"on\":true,\"none\":null,\"xs\":[1,2.5],\"at\":{\"x\":1}}", &.{}),
    );
    // A parameter that is an enumeration takes the string as its tag; a key that needs quoting is.
    try std.testing.expectEqualStrings(
        ".{.mode=.careful,.label=\"careful\",.@\"two words\"=1}",
        try zonFromJson(a, "{\"mode\":\"careful\",\"label\":\"careful\",\"two words\":1}", &.{"mode"}),
    );
    try std.testing.expectError(error.NotJson, zonFromJson(a, "{line: 12}", &.{}));
    // Negative zero as ZON reads it.
    const neg = try zonFromJson(a, "{\"x\":-0.0}", &.{});
    try std.testing.expectEqualStrings(".{.x=-0.0}", neg);
    var diag: std.zon.parse.Diagnostics = undefined;
    _ = try std.zon.parse.fromSlice(struct { x: f64 }, .{ .gpa = a, .arena = a, .source = try a.dupeSentinel(u8, neg, 0), .diagnostics = &diag });
    try std.testing.expectError(error.NotAnObject, zonFromJson(a, "[1]", &.{}));
}

test "results: ZON to JSON" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("null", try jsonFromZon(a, null));
    try std.testing.expectEqualStrings("null", try jsonFromZon(a, ""));
    try std.testing.expectEqualStrings("[]", try jsonFromZon(a, ".{}"));
    try std.testing.expectEqualStrings(
        "{\"path\":\"a\\nb\",\"line\":12,\"big\":123456789012345678901234567890,\"f\":0.5,\"mode\":\"careful\",\"xs\":[1,true,null],\"c\":97}",
        try jsonFromZon(a, ".{ .path = \"a\\nb\", .line = 12, .big = 123456789012345678901234567890, .f = 0.5, .mode = .careful, .xs = .{ 1, true, null }, .c = 'a' }"),
    );
    try std.testing.expectEqualStrings("\"text\"", try jsonFromZon(a, "\"text\""));
    try std.testing.expectError(error.NotZon, jsonFromZon(a, ".{ .x = }"));
    // What JSON cannot say: an infinity is null, bytes that are not UTF-8 are refused.
    try std.testing.expectEqualStrings("{\"f\":null,\"g\":-1.5}", try jsonFromZon(a, ".{ .f = 1e400, .g = -1.5 }"));
    try std.testing.expectError(error.NotUtf8, jsonFromZon(a, ".{ .s = \"\\x00\\xff\" }"));
}

test "round trip: what goes in comes back" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json = "{\"s\":\"\\u00e9 \\\\ \\t\",\"n\":-3,\"o\":{\"xs\":[]}}";
    const zon = try zonFromJson(a, json, &.{});
    // An empty array comes back as one: ZON's `.{}` does not say which it was, and a list is
    // the likelier.
    try std.testing.expectEqualStrings("{\"s\":\"é \\\\ \\t\",\"n\":-3,\"o\":{\"xs\":[]}}", try jsonFromZon(a, zon));
}
