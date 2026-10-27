//! The Model Context Protocol's dispatch: one JSON-RPC message in, its answer out, so an agent
//! reaches the same commands curl does (plans/CONTROL_SERVER_PLAN.md, step 5). Its tools are the
//! app's commands: `tools/list` from the registry, each named as every client accepts
//! (`mcp_names.zig`: `text.insert` is `text__insert`) with its id in its description, each tool's
//! input schema the one `/openapi.json` gives the command's body (`openapi.bodySchema`), and
//! `tools/call` through `Host.callCommandAwaiting`, so a command that answers in a later frame
//! answers its call then.
//!
//! No transport: it holds no socket and names no `Server`, so it builds on every target, the web's
//! too (plans/AGENTS_ANYWHERE_PLAN.md). The control server carries it as `POST /mcp`
//! (`control/routes.zig`); the seam for the page's own MCP is `handle` with a `Context` of its own.
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
const AppInfo = @import("AppInfo.zig");
const json = @import("control/json.zig");
const openapi = @import("control/openapi.zig");
const names = @import("mcp_names.zig");

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
    list: std.ArrayList(Session) = .empty,

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
    return std.mem.print(buf, "{x:0>16}", .{id}) catch unreachable;
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
    return .{ .now = try failure(arena, id, -32601, try arena.print("no method {s}", .{name})) };
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
    w.writeAll(" A tool's name is its command's id with each . as __ (text.insert is text__insert).") catch return error.OutOfMemory;
    for ([_][2][]const u8{
        .{ "fizzy.screen", "says what is on screen." },
        .{ "fizzy.settled", "waits until nothing is loading or animating." },
    }) |t| if (host.command(t[0]) != null) {
        const name = names.plain(t[0]);
        w.print(" {s} {s}", .{ name.slice(), t[1] }) catch return error.OutOfMemory;
    };
    return out.written();
}

/// A command as a tool: the commands `tools/list` lists and `tools/call` finds, each named.
const Tool = struct {
    command: *const sdk.Command,
    name: names.Name,
};

/// The runnable commands, one per id: the one `callCommand` runs (`Host.command`, an override
/// over what it replaces), with their names. Built per request: a plugin's commands come and go
/// as it loads and reloads.
fn tools(host: *sdk.Host, arena: std.mem.Allocator) error{OutOfMemory}![]Tool {
    var commands: std.ArrayList(*const sdk.Command) = .empty;
    var ids: std.ArrayList([]const u8) = .empty;
    for (host.commands.items) |*c| {
        if (c.owner == null or host.command(c.id) != c) continue;
        try commands.append(arena, c);
        try ids.append(arena, c.id);
    }
    const named = try names.assign(arena, ids.items);
    const out = try arena.alloc(Tool, commands.items.len);
    for (out, commands.items, named) |*t, c, n| t.* = .{ .command = c, .name = n };
    return out;
}

fn listTools(host: *sdk.Host, arena: std.mem.Allocator, id: []const u8) error{OutOfMemory}![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var s: Stringify = .{ .writer = &out.writer };
    writeTools(&s, try tools(host, arena), arena) catch return error.OutOfMemory;
    return result(arena, id, out.written());
}

fn writeTools(s: *Stringify, list: []const Tool, arena: std.mem.Allocator) openapi.Error!void {
    try s.beginObject();
    try s.objectField("tools");
    try s.beginArray();
    for (list) |*t| {
        const c = t.command;
        try s.beginObject();
        try s.objectField("name");
        try s.write(t.name.slice());
        try s.objectField("title");
        try s.write(c.title);
        try s.objectField("description");
        // The id as the app names it: what history, keybindings and `POST /commands/{id}` say.
        try s.write(try arena.print("{s} ({s}'s command {s}{s})", .{
            c.title,
            c.owner.?.id,
            c.id,
            if (c.visibility == .internal) ", for programs" else "",
        }));
        try s.objectField("inputSchema");
        try openapi.bodySchema(s, c, arena);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
}

/// The command a `tools/call` names: by its tool name, or by its id as a client written before the
/// names were spelled (`fizzy.screen`) sends it, when no tool has that name.
fn lookup(host: *sdk.Host, arena: std.mem.Allocator, name: []const u8) error{OutOfMemory}!?*const sdk.Command {
    // Nearly every name spells its id back, and an id that does keeps its plain name: found
    // without listing the rest.
    var buf: [names.max_len]u8 = undefined;
    if (name.len <= names.max_len) if (host.command(names.unspell(name, &buf))) |c| {
        const plain = names.plain(c.id);
        if (c.owner != null and names.reversible(c.id) and std.mem.eql(u8, plain.slice(), name)) return c;
    };
    for (try tools(host, arena)) |t| if (std.mem.eql(u8, t.name.slice(), name)) return t.command;
    return host.command(name);
}

fn callTool(host: *sdk.Host, arena: std.mem.Allocator, id: []const u8, params: ?std.json.ObjectMap, sink: ?sdk.Host.CallSink) error{OutOfMemory}!Reply {
    const p = params orelse return .{ .now = try failure(arena, id, -32602, "tools/call takes .name and .arguments") };
    const name = if (p.get("name")) |n| if (n == .string) n.string else null else null;
    const tool = name orelse return .{ .now = try failure(arena, id, -32602, "tools/call needs a name") };
    const c = try lookup(host, arena, tool) orelse return .{ .now = try failure(arena, id, -32602, try arena.print("no tool {s}", .{tool})) };
    // The arguments, through the same JSON-to-ZON edge as a REST call (`json.zig`).
    // Absent and null are none.
    const arguments = if (p.get("arguments")) |a| if (a == .null) "{}" else try Stringify.valueAlloc(arena, a, .{}) else "{}";
    var enum_keys: std.ArrayList([]const u8) = .empty;
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
    return arena.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id, body });
}

fn failure(arena: std.mem.Allocator, id: []const u8, code: i32, message: []const u8) error{OutOfMemory}![]const u8 {
    const err = try Stringify.valueAlloc(arena, .{ .code = code, .message = message }, .{});
    return arena.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{s}}}", .{ id, err });
}
