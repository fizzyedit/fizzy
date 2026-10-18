//! The control server's OpenAPI 3.1 description, generated per request from what is registered
//! now: a path per command, its body a JSON Schema built from the parameters the command declares,
//! and `/events` with every event plugins declared (`Host.declareEvent`). It changes as plugins load
//! and reload, so a client generated from it sees the app as it is (plans/CONTROL_SERVER_PLAN.md,
//! step 3).
//!
//! A command's result has no declared type yet, so its 200 response is any JSON value. The seam
//! for typing it is a result type beside `Command.Params(…)` that `commandPath` would read.
const std = @import("std");
const sdk = @import("fizzy_sdk");
const AppInfo = @import("../AppInfo.zig");
const json = @import("json.zig");

const Stringify = std.json.Stringify;
const Error = Stringify.Error || error{OutOfMemory};

/// The whole description as JSON, in `arena`.
pub fn generate(host: *sdk.Host, arena: std.mem.Allocator) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var s: Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    write(&s, host, arena) catch return error.OutOfMemory;
    return out.written();
}

fn write(s: *Stringify, host: *sdk.Host, arena: std.mem.Allocator) Error!void {
    try s.beginObject();
    try s.objectField("openapi");
    try s.write("3.1.0");
    try s.objectField("info");
    try s.write(.{
        .title = AppInfo.current.display_name ++ " control server",
        .version = AppInfo.current.version,
        .description = "The app's commands over HTTP on a Unix socket in its config folder (`control.sock`), " ++
            "readable by this user only: `curl --unix-socket <path> http://localhost/commands`. Bodies are JSON; " ++
            "send `Content-Type: application/zon` to send and receive ZON instead.",
    });
    try s.objectField("servers");
    try s.write(.{.{ .url = "http://localhost", .description = "Over the Unix socket; the host name is not used." }});

    try s.objectField("paths");
    try s.beginObject();
    try s.objectField("/");
    try s.write(.{ .get = .{
        .operationId = "app",
        .summary = "The app, its version and the SDK it was built against.",
        .responses = .{ .@"200" = jsonResponse("The app.", .{ .@"$ref" = "#/components/schemas/App" }) },
    } });
    try s.objectField("/commands");
    try s.write(.{ .get = .{
        .operationId = "commands",
        .summary = "Every registered command, with its parameters and whether it is enabled now.",
        .responses = .{ .@"200" = jsonResponse("The commands.", .{ .type = "array", .items = .{ .@"$ref" = "#/components/schemas/Command" } }) },
    } });
    try eventsPath(s, host, arena);
    for (host.commands.items) |*c| try commandPath(s, c, arena);
    try s.endObject();

    try s.objectField("components");
    try s.write(.{ .schemas = .{
        .App = .{ .type = "object", .properties = .{
            .name = .{ .type = "string" },
            .version = .{ .type = "string" },
            .sdk_version = .{ .type = "string" },
        } },
        .Error = .{ .type = "object", .required = .{"error"}, .properties = .{ .@"error" = .{ .type = "string" } } },
        .Param = .{ .type = "object", .properties = .{
            .key = .{ .type = "string" },
            .label = .{ .type = "string" },
            .description = .{ .type = "string" },
            .kind = .{ .type = "string", .@"enum" = .{ "bool", "int", "float", "string", "enum", "color", "zon" } },
            .required = .{ .type = "boolean" },
            .default = .{},
            .min = .{ .type = "number" },
            .max = .{ .type = "number" },
            .choices = .{ .type = "array", .items = .{ .type = "string" } },
        } },
        .Command = .{ .type = "object", .properties = .{
            .id = .{ .type = "string" },
            .title = .{ .type = "string" },
            .owner = .{ .type = "string" },
            .visibility = .{ .type = "string", .@"enum" = .{ "external", "internal" } },
            .enabled = .{ .type = "boolean" },
            .params = .{ .type = "array", .items = .{ .@"$ref" = "#/components/schemas/Param" } },
        } },
    } });
    try s.endObject();
}

fn jsonResponse(description: []const u8, schema: anytype) JsonResponse(@TypeOf(schema)) {
    return .{ .description = description, .content = .{ .@"application/json" = .{ .schema = schema } } };
}

fn JsonResponse(comptime Schema: type) type {
    return struct {
        description: []const u8,
        content: struct { @"application/json": struct { schema: Schema } },
    };
}

const error_response = jsonResponse("Why not, in words.", .{ .@"$ref" = "#/components/schemas/Error" });

fn eventsPath(s: *Stringify, host: *sdk.Host, arena: std.mem.Allocator) Error!void {
    var description: std.Io.Writer.Allocating = .init(arena);
    const w = &description.writer;
    try w.writeAll("The app's events as Server-Sent Events, one `event:` (its name) and one `data:` (its payload " ++
        "as JSON) each. Events plugins have declared:\n");
    for (host.event_declarations.items) |d| try w.print("\n- `{s}`: {s}", .{ d.name, d.description });
    try s.objectField("/events");
    try s.beginObject();
    try s.objectField("get");
    try s.beginObject();
    try s.objectField("operationId");
    try s.write("events");
    try s.objectField("summary");
    try s.write("Stream the app's events.");
    try s.objectField("description");
    try s.write(description.written());
    try s.objectField("parameters");
    try s.write(.{.{
        .name = "topics",
        .in = "query",
        .description = "Comma-separated event names, or prefixes ending in `*` (`fizzy.document.*`). Every event when absent.",
        .schema = .{ .type = "string" },
    }});
    try s.objectField("responses");
    try s.write(.{ .@"200" = .{
        .description = "The stream, open until the client or the app closes it.",
        .content = .{ .@"text/event-stream" = .{ .schema = .{ .type = "string" } } },
    } });
    // Each declared event's payload, as JSON, for a client to generate its handlers from.
    try s.objectField("x-fizzy-events");
    try s.beginArray();
    for (host.event_declarations.items) |d| {
        try s.beginObject();
        try s.objectField("name");
        try s.write(d.name);
        try s.objectField("owner");
        try s.write(if (d.owner) |o| o.id else null);
        try s.objectField("description");
        try s.write(d.description);
        try s.objectField("example");
        try writeExample(s, arena, d.payload);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    try s.endObject();
}

fn commandPath(s: *Stringify, c: *const sdk.Command, arena: std.mem.Allocator) Error!void {
    try s.objectField(try std.fmt.allocPrint(arena, "/commands/{s}", .{c.id}));
    try s.beginObject();
    try s.objectField("post");
    try s.beginObject();
    try s.objectField("operationId");
    try s.write(c.id);
    try s.objectField("summary");
    try s.write(c.title);
    if (c.owner) |o| {
        try s.objectField("tags");
        try s.write(.{o.id});
    }
    try s.objectField("x-fizzy-visibility");
    try s.write(@tagName(c.visibility));
    try s.objectField("requestBody");
    try s.beginObject();
    try s.objectField("required");
    try s.write(sdk.Command.requiresArguments(c.params));
    try s.objectField("content");
    try s.beginObject();
    try s.objectField("application/json");
    try s.beginObject();
    try s.objectField("schema");
    try s.beginObject();
    try s.objectField("type");
    try s.write("object");
    try s.objectField("additionalProperties");
    try s.write(false);
    try s.objectField("properties");
    try s.beginObject();
    for (c.params) |p| {
        try s.objectField(p.key);
        try paramSchema(s, arena, p);
    }
    try s.endObject();
    try s.objectField("required");
    try s.beginArray();
    for (c.params) |p| if (p.required) try s.write(p.key);
    try s.endArray();
    try s.endObject();
    try s.endObject();
    try s.endObject();
    try s.endObject();
    try s.objectField("responses");
    try s.write(.{
        .@"200" = jsonResponse("Its result: any JSON value, `null` when it returns nothing.", .{}),
        .@"400" = error_response,
        .@"404" = error_response,
        .@"409" = error_response,
        .@"500" = error_response,
    });
    try s.endObject();
    try s.endObject();
}

fn paramSchema(s: *Stringify, arena: std.mem.Allocator, p: sdk.Command.Param) Error!void {
    try s.beginObject();
    try s.objectField("title");
    try s.write(p.label);
    try s.objectField("description");
    switch (p.kind) {
        // ZON of their own: JSON that converts to it (`json.zig`), described rather than typed.
        .color, .other => try s.write(try std.fmt.allocPrint(arena, "{s} (any JSON that converts to the ZON it takes)", .{p.description})),
        else => try s.write(p.description),
    }
    switch (p.kind) {
        .bool => {
            try s.objectField("type");
            try s.write("boolean");
        },
        .int => |k| {
            try s.objectField("type");
            try s.write("integer");
            try s.objectField("minimum");
            try s.write(k.min);
            try s.objectField("maximum");
            try s.write(k.max);
            if (k.choices.len > 0) {
                try s.objectField("enum");
                try s.write(k.choices);
            }
        },
        .float => |k| {
            try s.objectField("type");
            try s.write("number");
            try s.objectField("minimum");
            try s.write(k.min);
            try s.objectField("maximum");
            try s.write(k.max);
        },
        .string => {
            try s.objectField("type");
            try s.write("string");
        },
        .enumeration => |k| {
            try s.objectField("type");
            try s.write("string");
            try s.objectField("enum");
            try s.write(k.choices);
        },
        .color, .other => {},
    }
    if (p.default) |d| {
        try s.objectField("default");
        try writeExample(s, arena, d);
    }
    try s.endObject();
}

/// `zon` as a JSON value, or null when it is not ZON JSON can say.
fn writeExample(s: *Stringify, arena: std.mem.Allocator, zon: []const u8) Error!void {
    const text = json.jsonFromZon(arena, zon) catch return s.write(null);
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return s.write(null);
    try s.write(value);
}
