//! The control server's OpenAPI 3.1 description, generated per request from what is registered
//! now: a path per command, its body a JSON Schema built from the parameters the command declares,
//! and `/events` with every event plugins declared (`Host.declareEvent`). It changes as plugins load
//! and reload, so a client generated from it sees the app as it is (plans/CONTROL_SERVER_PLAN.md,
//! step 3).
//!
//! It says what the server enforces, no more: a parameter's type, and the choices of an enumeration.
//! The bounds and suggested choices a number declares are the palette's hints, never checked by
//! `Command.Params`, so they go in its description, not its schema, where a generated client would
//! refuse values the server takes. A command's result has no declared type yet, so its 200 response
//! is any JSON value; the seam for typing it is a result type beside `Command.Params(…)` that
//! `commandPath` would read.
const std = @import("std");
const sdk = @import("fizzy_sdk");
const AppInfo = @import("../AppInfo.zig");
const json = @import("json.zig");

const Stringify = std.json.Stringify;
pub const Error = Stringify.Error || error{OutOfMemory};

/// The whole description as JSON, in `arena`.
pub fn generate(host: *sdk.Host, arena: std.mem.Allocator) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    // Compact: generated on the UI thread per request, and half the bytes of an indented one.
    var s: Stringify = .{ .writer = &out.writer, .options = .{} };
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
        .description = "The app's commands over HTTP on a Unix socket in its config folder (`control/control.sock`; `fizzy --control-path` prints it), " ++
            "readable by this user only: `curl --unix-socket <path> http://localhost/commands`. Bodies are JSON; " ++
            "send `Content-Type: application/zon` to send and receive ZON instead.",
    });
    try s.objectField("servers");
    try s.write(.{.{ .url = "http://localhost", .description = "Over the Unix socket; the host name is not used." }});

    try s.objectField("paths");
    try s.beginObject();
    try s.objectField("/");
    try s.write(.{ .get = .{
        .operationId = "control.app",
        .summary = "The app, its version and the SDK it was built against.",
        .responses = .{ .@"200" = jsonResponse("The app.", .{ .@"$ref" = "#/components/schemas/App" }) },
    } });
    try s.objectField("/commands");
    try s.write(.{ .get = .{
        .operationId = "control.commands",
        .summary = "Every registered command, with its parameters and whether it is enabled now.",
        .responses = .{ .@"200" = jsonResponse("The commands.", .{ .type = "array", .items = .{ .@"$ref" = "#/components/schemas/Command" } }) },
    } });
    try s.objectField("/openapi.json");
    try s.write(.{ .get = .{
        .operationId = "control.openapi",
        .summary = "This description, generated from what is registered now.",
        .responses = .{ .@"200" = jsonResponse("The description.", true) },
    } });
    try s.objectField("/mcp");
    try s.write(.{ .post = .{
        .operationId = "control.mcp",
        .summary = "The Model Context Protocol (Streamable HTTP): a JSON-RPC message, its tools the commands.",
        .requestBody = .{ .required = true, .content = .{ .@"application/json" = .{ .schema = .{ .type = "object" } } } },
        .responses = .{
            .@"200" = jsonResponse("The JSON-RPC response.", .{ .type = "object" }),
            .@"202" = .{ .description = "A notification, taken." },
        },
    } });
    try eventsPath(s, host, arena);
    // The first of an id is the one the server runs (`Host.command`): a later one is not a path
    // of its own, which would repeat a key and an `operationId`. A command no plugin owns cannot
    // run (`callCommand` answers 404) and is left out.
    for (host.commands.items, 0..) |*c, i| {
        if (c.owner == null) continue;
        const first = for (host.commands.items[0..i]) |*o| {
            if (std.mem.eql(u8, o.id, c.id)) break false;
        } else true;
        if (first) try commandPath(s, c, arena);
    }
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
            .default = true,
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
    try s.write("control.events");
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
        try s.write(try example(arena, d.payload));
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    try s.endObject();
}

fn commandPath(s: *Stringify, c: *const sdk.Command, arena: std.mem.Allocator) Error!void {
    // Escaped as the server unescapes it (`routes`): an id with `{`, a space or `%` is still one path.
    try s.objectField(try arena.print("/commands/{f}", .{std.fmt.alt(std.Uri.Component{ .raw = c.id }, .formatEscaped)}));
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
    // A command with only `run` takes no body (`callCommand` refuses arguments): none described.
    if (c.runWith != null) {
        try s.objectField("requestBody");
        try s.beginObject();
        try s.objectField("required");
        try s.write(sdk.Command.requiresArguments(c.params));
        try s.objectField("content");
        try s.beginObject();
        try s.objectField("application/json");
        try s.beginObject();
        try s.objectField("schema");
        try bodySchema(s, c, arena);
        try s.endObject();
        try s.endObject();
        try s.endObject();
    }
    try s.objectField("responses");
    try s.write(.{
        .@"200" = jsonResponse("Its result: any JSON value, `null` when it returns nothing.", true),
        .@"400" = error_response,
        .@"404" = error_response,
        .@"409" = error_response,
        .@"500" = error_response,
    });
    try s.endObject();
    try s.endObject();
}

/// The JSON Schema of what `c` takes as arguments: exactly its declared parameters
/// (`Command.Params` refuses others); any object for a `runWith` written by hand, which declares
/// none and reads whatever it reads; nothing for a command with only `run`. Shared by this
/// description's request bodies and MCP's tool inputs (`mcp.zig`).
pub fn bodySchema(s: *Stringify, c: *const sdk.Command, arena: std.mem.Allocator) Error!void {
    try s.beginObject();
    try s.objectField("type");
    try s.write("object");
    if (c.params.len > 0 or c.runWith == null) {
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
    }
    try s.endObject();
}

fn paramSchema(s: *Stringify, arena: std.mem.Allocator, p: sdk.Command.Param) Error!void {
    try s.beginObject();
    try s.objectField("title");
    try s.write(p.label);
    try s.objectField("description");
    try s.write(switch (p.kind) {
        // ZON of their own: JSON that converts to it (`json.zig`), described rather than typed.
        .color, .other => try arena.print("{s} (any JSON that converts to the ZON it takes)", .{p.description}),
        .int => |k| if (k.choices.len > 0)
            try arena.print("{s} (suggested: {any})", .{ p.description, k.choices })
        else
            try arena.print("{s} (from {d} to {d})", .{ p.description, k.min, k.max }),
        else => p.description,
    });
    switch (p.kind) {
        .bool => {
            try s.objectField("type");
            try s.write("boolean");
        },
        .int => {
            try s.objectField("type");
            try s.write("integer");
        },
        .float => {
            try s.objectField("type");
            try s.write("number");
        },
        .string => {
            try s.objectField("type");
            try s.write("string");
        },
        // The one constraint `Command.Params` checks: a tag it does not have is refused.
        .enumeration => |k| {
            try s.objectField("type");
            try s.write("string");
            try s.objectField("enum");
            try s.write(k.choices);
        },
        .color, .other => {},
    }
    // Left out when it does not convert, rather than a `null` the schema would refuse.
    if (p.default) |d| if (try example(arena, d)) |value| {
        try s.objectField("default");
        try s.write(value);
    };
    try s.endObject();
}

/// `zon` as a JSON value, or null when it is not ZON that JSON can say.
fn example(arena: std.mem.Allocator, zon: []const u8) error{OutOfMemory}!?std.json.Value {
    const text = json.jsonFromZon(arena, zon) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch null;
}
