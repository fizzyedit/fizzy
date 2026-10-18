//! MCP on the control socket: `POST /mcp` speaks the Model Context Protocol's Streamable HTTP
//! transport, a JSON-RPC message per request answered as JSON, so an agent reaches the same
//! commands curl does (plans/CONTROL_SERVER_PLAN.md, step 5). Its tools are the app's commands:
//! `tools/list` from the registry, each tool's input schema the one `/openapi.json` gives the
//! command's body (`openapi.bodySchema`), and `tools/call` through `Host.callCommandAwaiting`, so a
//! command that answers in a later frame answers its call then.
//!
//! What it does not do yet: server-sent notifications (no `GET /mcp` stream: the tool list is
//! read when asked), sessions (`Mcp-Session-Id`), resources and prompts.
const std = @import("std");
const sdk = @import("fizzy_sdk");
const AppInfo = @import("../AppInfo.zig");
const json = @import("json.zig");
const openapi = @import("openapi.zig");

const Stringify = std.json.Stringify;

/// The protocol versions this answers, newest first: an `initialize` asking for another gets the
/// newest, as the protocol says. 2025-03-26 asked servers to take JSON-RPC batches, which 2025-06-18
/// dropped: none are taken here (no client sends them), a deliberate gap.
const versions = [_][]const u8{ "2025-06-18", "2025-03-26" };

/// What to send back for one message.
pub const Reply = union(enum) {
    /// A JSON-RPC response, as the body.
    now: []const u8,
    /// A notification: answered `202 Accepted`, no body.
    none,
    /// A tool whose command answers later: `ticket` names it, and `id` is the request's id as JSON
    /// (in the arena), for `result` to answer with once it comes.
    later: struct { ticket: u32, id: []const u8 },
};

/// Answer one JSON-RPC message, `body`. Everything returned lives in `arena`. `sink` hears a
/// command that answers later; without one, such a call is answered as started.
pub fn handle(host: *sdk.Host, body: []const u8, arena: std.mem.Allocator, sink: ?sdk.Host.CallSink) error{OutOfMemory}!Reply {
    // Numbers kept as written, so an id comes back exactly as it was sent.
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{ .parse_numbers = false }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .now = try failure(arena, "null", -32700, "the body is not JSON") },
    };
    if (value != .object) return .{ .now = try failure(arena, "null", -32600, "one JSON-RPC message per request: an object, not a batch") };
    const msg = value.object;
    const method = if (msg.get("method")) |m| if (m == .string) m.string else null else null;
    const id_value = msg.get("id");
    // No id: a notification. No method: a response to a request of ours. Neither is answered.
    if (id_value == null or method == null) return .none;
    const id = switch (id_value.?) {
        .string, .integer, .number_string => try std.json.Stringify.valueAlloc(arena, id_value.?, .{}),
        else => return .{ .now = try failure(arena, "null", -32600, "an id is a string or a number") },
    };
    const name = method.?;
    const params: ?std.json.ObjectMap = if (msg.get("params")) |p| if (p == .object) p.object else null else null;

    if (std.mem.eql(u8, name, "initialize")) return .{ .now = try initialize(host, arena, id, params) };
    if (std.mem.eql(u8, name, "ping")) return .{ .now = try result(arena, id, "{}") };
    if (std.mem.eql(u8, name, "tools/list")) return .{ .now = try listTools(host, arena, id) };
    if (std.mem.eql(u8, name, "tools/call")) return callTool(host, arena, id, params, sink);
    return .{ .now = try failure(arena, id, -32601, try std.fmt.allocPrint(arena, "no method {s}", .{name})) };
}

/// A tool call's answer once its command answers later (`Reply.later`).
pub fn outcomeReply(arena: std.mem.Allocator, id: []const u8, outcome: sdk.Host.CommandOutcome) error{OutOfMemory}![]const u8 {
    return switch (outcome) {
        .ok => |zon| {
            // The result as JSON text, which reads as it is; ZON JSON cannot say goes as it is.
            const text = json.jsonFromZon(arena, zon) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NotUtf8 => return toolResult(arena, id, "the result holds text that is not UTF-8", true),
                // Not ZON: as it is, which JSON can carry while it is UTF-8.
                else => if (std.unicode.utf8ValidateSlice(zon orelse "")) zon orelse "null" else return toolResult(arena, id, "the result is not ZON", true),
            };
            return toolResult(arena, id, text, false);
        },
        .unknown => failure(arena, id, -32602, "no such tool"),
        .disabled => toolResult(arena, id, "the command is not enabled now", true),
        .bad_args => |m| toolResult(arena, id, m, true),
        .failed => |m| toolResult(arena, id, m, true),
    };
}

fn initialize(host: *sdk.Host, arena: std.mem.Allocator, id: []const u8, params: ?std.json.ObjectMap) error{OutOfMemory}![]const u8 {
    const asked = if (params) |p| if (p.get("protocolVersion")) |v| if (v == .string) v.string else "" else "" else "";
    const version = for (versions) |v| {
        if (std.mem.eql(u8, v, asked)) break v;
    } else versions[0];
    const body = try Stringify.valueAlloc(arena, .{
        .protocolVersion = version,
        .capabilities = .{ .tools = .{ .listChanged = false } },
        .serverInfo = .{ .name = AppInfo.current.name, .title = AppInfo.current.display_name, .version = AppInfo.current.version },
        .instructions = try instructions(host, arena),
    }, .{});
    return result(arena, id, body);
}

/// What a model is told on connecting: what the tools are, and the app's own screen and settled
/// commands when it has them (fizzy does; an app built on fizzy may not).
fn instructions(host: *sdk.Host, arena: std.mem.Allocator) error{OutOfMemory}![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeAll("Each tool is one of " ++ AppInfo.current.display_name ++ "'s commands, the same ones its menus, " ++
        "keybindings and plugins run. A command acting on a document takes its path, or acts on the active one.") catch return error.OutOfMemory;
    for ([_][2][]const u8{
        .{ "fizzy.screen", " fizzy.screen says what is on screen." },
        .{ "fizzy.settled", " fizzy.settled waits until nothing is loading or animating." },
    }) |t| if (host.command(t[0]) != null) w.writeAll(t[1]) catch return error.OutOfMemory;
    return out.written();
}

fn listTools(host: *sdk.Host, arena: std.mem.Allocator, id: []const u8) error{OutOfMemory}![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var s: Stringify = .{ .writer = &out.writer };
    writeTools(&s, host, arena) catch return error.OutOfMemory;
    return result(arena, id, out.written());
}

fn writeTools(s: *Stringify, host: *sdk.Host, arena: std.mem.Allocator) openapi.Error!void {
    try s.beginObject();
    try s.objectField("tools");
    try s.beginArray();
    for (host.commands.items, 0..) |*c, i| {
        // Runnable, and the first of its id: the one `callCommand` runs.
        if (c.owner == null) continue;
        const first = for (host.commands.items[0..i]) |*o| {
            if (std.mem.eql(u8, o.id, c.id)) break false;
        } else true;
        if (!first) continue;
        try s.beginObject();
        try s.objectField("name");
        try s.write(c.id);
        try s.objectField("title");
        try s.write(c.title);
        try s.objectField("description");
        try s.write(try std.fmt.allocPrint(arena, "{s} ({s}'s command{s})", .{
            c.title,
            c.owner.?.id,
            if (c.visibility == .internal) ", for programs" else "",
        }));
        try s.objectField("inputSchema");
        try openapi.bodySchema(s, c, arena);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
}

fn callTool(host: *sdk.Host, arena: std.mem.Allocator, id: []const u8, params: ?std.json.ObjectMap, sink: ?sdk.Host.CallSink) error{OutOfMemory}!Reply {
    const p = params orelse return .{ .now = try failure(arena, id, -32602, "tools/call takes .name and .arguments") };
    const name = if (p.get("name")) |n| if (n == .string) n.string else null else null;
    const tool = name orelse return .{ .now = try failure(arena, id, -32602, "tools/call needs a name") };
    const c = host.command(tool) orelse return .{ .now = try failure(arena, id, -32602, try std.fmt.allocPrint(arena, "no tool {s}", .{tool})) };
    // The arguments, through the same JSON-to-ZON edge as a REST call (`json.zig`).
    // Absent and null are none.
    const arguments = if (p.get("arguments")) |a| if (a == .null) "{}" else try Stringify.valueAlloc(arena, a, .{}) else "{}";
    var enum_keys: std.ArrayListUnmanaged([]const u8) = .empty;
    for (c.params) |param| if (param.kind == .enumeration) try enum_keys.append(arena, param.key);
    const args = json.zonFromJson(arena, arguments, enum_keys.items) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .now = try toolResult(arena, id, "the arguments are an object keyed by the tool's input schema", true) },
    };
    return switch (host.callCommandAwaiting(c.id, args, arena, sink)) {
        .now => |outcome| .{ .now = try outcomeReply(arena, id, outcome) },
        .later => |ticket| if (sink != null)
            .{ .later = .{ .ticket = ticket, .id = id } }
        else
            .{ .now = try toolResult(arena, id, "started; its answer comes later", false) },
    };
}

fn toolResult(arena: std.mem.Allocator, id: []const u8, text: []const u8, is_error: bool) error{OutOfMemory}![]const u8 {
    const body = try Stringify.valueAlloc(arena, .{
        .content = .{.{ .type = "text", .text = text }},
        .isError = is_error,
    }, .{});
    return result(arena, id, body);
}

/// `{"jsonrpc":"2.0","id":<id>,"result":<body>}`: `id` and `body` already JSON.
fn result(arena: std.mem.Allocator, id: []const u8, body: []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id, body });
}

fn failure(arena: std.mem.Allocator, id: []const u8, code: i32, message: []const u8) error{OutOfMemory}![]const u8 {
    const err = try Stringify.valueAlloc(arena, .{ .code = code, .message = message }, .{});
    return std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{s}}}", .{ id, err });
}
