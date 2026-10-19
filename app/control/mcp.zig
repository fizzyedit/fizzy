//! MCP on the control socket: `POST /mcp` speaks the Model Context Protocol's Streamable HTTP
//! transport, a JSON-RPC message per request answered as JSON, so an agent reaches the same
//! commands curl does (plans/CONTROL_SERVER_PLAN.md, step 5). Its tools are the app's commands:
//! `tools/list` from the registry, each tool's input schema the one `/openapi.json` gives the
//! command's body (`openapi.bodySchema`), and `tools/call` through `Host.callCommandAwaiting`, so a
//! command that answers in a later frame answers its call then.
//!
//! Each client is a session (`Sessions`): `initialize` hands out an `Mcp-Session-Id`, and every
//! `tools/call` made with it runs as that client's author (`Host.act`), so history, undo and the
//! agent plugin's tapes say which agent made a step. A session ends at `DELETE /mcp`, after an
//! hour idle, or when the server stops, and `fizzy.mcp.session_ended` says so.
//!
//! What it does not do yet: server-sent notifications (no `GET /mcp` stream: the tool list is
//! read when asked), resources and prompts.
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

/// The clients that said `initialize`, kept by the routes' `State` on the UI thread. A client's
/// calls are made as its author: `.{ .kind = .agent, .plugin = "control", .session = id }`, labelled
/// with the name its `initialize` gave (`clientInfo.name`). A request with no session id is made as
/// one shared author, as every call was before sessions; one naming a session that ended is
/// answered 404, as the protocol says, so the client starts a new one.
pub const Sessions = struct {
    list: std.ArrayListUnmanaged(Session) = .empty,

    pub const Session = struct {
        id: u64,
        /// `gpa`-owned.
        label: []u8,
        /// When it last made a request, in nanoseconds on `Io.Clock.awake`.
        seen: i96,
    };

    /// A session that has made no request for this long ends.
    pub const idle_ns: i96 = 60 * 60 * std.time.ns_per_s;
    /// At most this many open: opening one more ends the one idle longest.
    pub const max = 64;

    /// The author of a request that names no session.
    pub const shared: sdk.Author = .{ .kind = .agent, .plugin = plugin, .session = 0, .label = "An agent" };
    const plugin = "control";

    pub fn deinit(self: *Sessions, gpa: std.mem.Allocator) void {
        for (self.list.items) |s| gpa.free(s.label);
        self.list.deinit(gpa);
    }

    pub fn author(s: Session) sdk.Author {
        return .{ .kind = .agent, .plugin = plugin, .session = s.id, .label = s.label };
    }

    fn find(self: *Sessions, id: u64) ?*Session {
        for (self.list.items) |*s| if (s.id == id) return s;
        return null;
    }

    fn open(self: *Sessions, gpa: std.mem.Allocator, host: *sdk.Host, id: u64, label: []const u8, now: i96) error{OutOfMemory}!void {
        if (self.list.items.len >= max) {
            var idlest = self.list.items[0];
            for (self.list.items[1..]) |s| if (s.seen < idlest.seen) {
                idlest = s;
            };
            _ = self.end(gpa, host, idlest.id);
        }
        const owned = try gpa.dupe(u8, if (label.len > 0) label else "An agent");
        errdefer gpa.free(owned);
        try self.list.append(gpa, .{ .id = id, .label = owned, .seen = now });
    }

    /// End session `id`, saying so on the bus. False when there is none.
    pub fn end(self: *Sessions, gpa: std.mem.Allocator, host: *sdk.Host, id: u64) bool {
        for (self.list.items, 0..) |s, i| if (s.id == id) {
            announceEnd(gpa, host, s);
            gpa.free(s.label);
            _ = self.list.swapRemove(i);
            return true;
        };
        return false;
    }

    /// End the sessions idle since before `now - idle_ns`. Free with none open.
    pub fn expire(self: *Sessions, gpa: std.mem.Allocator, host: *sdk.Host, now: i96) void {
        var i: usize = 0;
        while (i < self.list.items.len) {
            const s = self.list.items[i];
            if (now - s.seen < idle_ns) {
                i += 1;
                continue;
            }
            _ = self.end(gpa, host, s.id);
        }
    }

    /// End them all, as the server stops.
    pub fn endAll(self: *Sessions, gpa: std.mem.Allocator, host: *sdk.Host) void {
        while (self.list.items.len > 0) _ = self.end(gpa, host, self.list.items[0].id);
    }
};

/// `fizzy.mcp.session_ended`, for the app to declare (`Host.declareEvent`) where it declares its
/// own: the agent plugin ends that author's sessions and tapes when it hears it.
pub const session_ended: sdk.events.Declaration = .{
    .name = "fizzy.mcp.session_ended",
    .description = "An MCP client's session on the control socket ended (DELETE /mcp, an hour idle, or the server stopping); its calls were made as .{ .kind = .agent, .plugin, .session }.",
    .payload = ".{ .session = 12345, .label = \"Claude Code\", .plugin = \"control\" }",
};

fn announceEnd(gpa: std.mem.Allocator, host: *sdk.Host, s: Sessions.Session) void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    std.zon.stringify.serialize(.{ .session = s.id, .label = s.label, .plugin = Sessions.plugin }, .{ .whitespace = false }, &out.writer) catch return;
    host.emit(session_ended.name, out.written());
}

/// A session id as its header carries it: 16 hex digits.
pub fn formatSession(id: u64, buf: *[16]u8) []const u8 {
    return std.fmt.bufPrint(buf, "{x:0>16}", .{id}) catch unreachable;
}

/// A header's session id, or null when it is not one.
pub fn parseSession(text: []const u8) ?u64 {
    const t = std.mem.trim(u8, text, " \t");
    if (t.len != 16) return null;
    for (t) |c| if (!std.ascii.isHex(c)) return null;
    return std.fmt.parseInt(u64, t, 16) catch null;
}

/// What the session-aware `handle` needs and answers: the table, the request's `Mcp-Session-Id`, the
/// time, and an id for a session `initialize` opens (random, from the caller).
pub const Context = struct {
    gpa: std.mem.Allocator,
    sessions: *Sessions,
    /// The request's `Mcp-Session-Id` header, as sent.
    header: ?[]const u8,
    now: i96,
    fresh_id: u64,
    /// Set by `handle`: the session to name in the response's `Mcp-Session-Id`.
    opened: ?u64 = null,
};

/// What to send back for one message.
pub const Reply = union(enum) {
    /// A JSON-RPC response, as the body.
    now: []const u8,
    /// A notification: answered `202 Accepted`, no body.
    none,
    /// A tool whose command answers later: `ticket` names it, and `id` is the request's id as JSON
    /// (in the arena), for `result` to answer with once it comes.
    later: struct { ticket: u32, id: []const u8 },
    /// The request names a session that is not open (ended, or never was): answered 404, and the
    /// client initializes again.
    unknown_session,
};

/// Answer one JSON-RPC message, `body`. Everything returned lives in `arena`. `sink` hears a
/// command that answers later; without one, such a call is answered as started.
/// With `ctx`, sessions: `initialize` opens one, and every other message is made as the session its
/// header names. Without, every message is made as the shared author.
pub fn handle(host: *sdk.Host, body: []const u8, arena: std.mem.Allocator, sink: ?sdk.Host.CallSink, ctx: ?*Context) error{OutOfMemory}!Reply {
    // Numbers kept as written, so an id comes back exactly as it was sent.
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{ .parse_numbers = false }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .now = try failure(arena, "null", -32700, "the body is not JSON") },
    };
    if (value != .object) return .{ .now = try failure(arena, "null", -32600, "one JSON-RPC message per request: an object, not a batch") };
    const msg = value.object;
    const method = if (msg.get("method")) |m| if (m == .string) m.string else null else null;
    const id_value = msg.get("id");
    // Every message but `initialize` is made as its session, which must still be open: a
    // notification naming one that ended is refused too, so the client starts again at once.
    var who: sdk.Author = Sessions.shared;
    const initializing = if (method) |m| std.mem.eql(u8, m, "initialize") else false;
    if (!initializing) if (ctx) |c| if (c.header) |h| {
        const s = c.sessions.find(parseSession(h) orelse return .unknown_session) orelse return .unknown_session;
        s.seen = c.now;
        who = Sessions.author(s.*);
    };
    // No id: a notification. No method: a response to a request of ours. Neither is answered.
    if (id_value == null or method == null) return .none;
    const id = switch (id_value.?) {
        .string, .integer, .number_string => try std.json.Stringify.valueAlloc(arena, id_value.?, .{}),
        else => return .{ .now = try failure(arena, "null", -32600, "an id is a string or a number") },
    };
    const name = method.?;
    const params: ?std.json.ObjectMap = if (msg.get("params")) |p| if (p == .object) p.object else null else null;

    if (initializing) {
        // Opened once its answer is built, so a session is never open that no client was told of.
        const reply = try initialize(host, arena, id, params);
        if (ctx) |c| {
            try c.sessions.open(c.gpa, host, c.fresh_id, clientName(params), c.now);
            c.opened = c.fresh_id;
        }
        return .{ .now = reply };
    }
    if (std.mem.eql(u8, name, "ping")) return .{ .now = try result(arena, id, "{}") };
    if (std.mem.eql(u8, name, "tools/list")) return .{ .now = try listTools(host, arena, id) };
    if (std.mem.eql(u8, name, "tools/call")) {
        const outer = host.act(who);
        defer host.endAct(outer);
        return callTool(host, arena, id, params, sink);
    }
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

/// `initialize`'s `clientInfo.name`, or empty.
fn clientName(params: ?std.json.ObjectMap) []const u8 {
    const p = params orelse return "";
    const info = p.get("clientInfo") orelse return "";
    if (info != .object) return "";
    const n = info.object.get("name") orelse return "";
    return if (n == .string) n.string else "";
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
