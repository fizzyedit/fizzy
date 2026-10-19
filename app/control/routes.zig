//! What the control server answers, on the UI thread: fizzy's identity and its commands
//! (plans/CONTROL_SERVER_PLAN.md, "The API"). The API is the commands every loaded plugin
//! registered, with the parameters each declared; nothing registers a route.
//!
//!   GET  /                 the app, its version, the SDK it was built against
//!   GET  /commands         every command: id, title, owner, whether it is enabled, its params
//!   GET  /commands/{id}    one of them
//!   POST /commands/{id}    run it: the body is its arguments, the response its result
//!   GET  /openapi.json     all of this as OpenAPI 3.1, generated from what is registered now
//!   POST /mcp              the Model Context Protocol, its tools the commands (`app/mcp.zig`)
//!   GET  /events           the app's events as Server-Sent Events, `?topics=a,b` to choose
//!                          (a name, or a prefix ending in `*`); every event when absent
//!
//! Bodies are JSON, converted at this edge (`json.zig`). A request sent as `application/zon` is
//! passed through as ZON and answered in ZON. Errors are HTTP's: 404 for an unknown command, 400
//! for arguments that do not fit, 409 for a command not enabled now, 500 for one that ran and
//! failed, each with `{"error": "…"}`.
const std = @import("std");
const sdk = @import("fizzy_sdk");
const AppInfo = @import("../AppInfo.zig");
const json = @import("json.zig");
const openapi = @import("openapi.zig");
const mcp = @import("../mcp.zig");
const Server = @import("Server.zig");

pub const Answer = struct {
    /// Stream the app's events to this connection instead (`GET /events`).
    stream: bool = false,
    /// The command answers in a later frame (`Command.Call.later`): its waiter answers then.
    later: bool = false,
    status: std.http.Status,
    /// Static: a string literal.
    content_type: []const u8 = "application/json",
    body: []const u8,
    /// The MCP session to name in the response's `Mcp-Session-Id` (`initialize` opened it).
    mcp_session: ?u64 = null,
};

const zon_type = "application/zon";

/// Answer what waits on `server`. On the UI thread, once a frame, before plugins' `beginFrame`, so
/// a command run here is seen by the frame that follows.
pub fn answerPending(server: *Server, state: *State, host: *sdk.Host) void {
    var taken: std.ArrayListUnmanaged(*Server.Request) = .empty;
    defer taken.deinit(server.gpa);
    var streaming = server.take(&taken) > 0;
    for (taken.items) |req| {
        var arena: std.heap.ArenaAllocator = .init(server.gpa);
        defer arena.deinit();
        // Ready for a command that answers later; let go of when it answers now.
        const waiter = server.gpa.create(Waiter) catch {
            req.answer(server, .internal_server_error, "text/plain", "out of memory\n");
            continue;
        };
        waiter.* = .{ .server = server, .state = state, .host = host, .req = req, .zon = isZon(req.content_type) };
        // An MCP request is made as its client's session; everything else has none.
        var ctx: mcp.Context = .{ .gpa = server.gpa, .sessions = &state.sessions, .header = req.mcp_session, .now = std.Io.Clock.awake.now(server.io).nanoseconds, .fresh_id = 0 };
        const is_mcp = std.mem.eql(u8, std.mem.trimEnd(u8, req.path(), "/"), "/mcp");
        if (is_mcp) {
            var bytes: [8]u8 = undefined;
            // Never 0: that is the shared author's session.
            while (ctx.fresh_id == 0) {
                server.io.random(&bytes);
                ctx.fresh_id = std.mem.readInt(u64, &bytes, .little);
            }
        }
        const a = route(host, req.method, req.path(), req.content_type, req.body, arena.allocator(), waiter, if (is_mcp) &ctx else null) catch Answer{
            .status = .internal_server_error,
            .content_type = "text/plain",
            .body = "out of memory\n",
        };
        if (a.later) {
            state.waiters.append(server.gpa, waiter) catch {
                host.abandonCall(waiter.ticket);
                req.answer(server, .internal_server_error, "text/plain", "out of memory\n");
                waiter.destroy();
            };
            continue;
        }
        waiter.destroy();
        if (a.stream) {
            req.answerStream(server);
            streaming = true;
        } else {
            if (a.mcp_session) |id| {
                var header: [16]u8 = undefined;
                _ = mcp.formatSession(id, &header);
                req.mcp_session_reply = header;
            }
            req.answer(server, a.status, a.content_type, a.body);
        }
    }
    if (state.sessions.list.items.len > 0) state.sessions.expire(server.gpa, host, std.Io.Clock.awake.now(server.io).nanoseconds);
    state.follow(host, server, streaming);
}

/// Stop relaying and stop `server`. On the UI thread, at quit or when the setting goes off: the
/// commands still to answer are let go of, their requests answered by `server.stop`, and no event
/// reaches the stopped server.
pub fn stop(server: *Server, state: *State, host: *sdk.Host) void {
    for (state.waiters.items) |w| {
        host.abandonCall(w.ticket);
        w.destroy();
    }
    state.waiters.clearAndFree(server.gpa);
    // Their clients are gone with the server: the agent plugin hears each end.
    state.sessions.endAll(server.gpa, host);
    state.sessions.deinit(server.gpa);
    state.sessions = .{};
    state.follow(host, server, false);
    server.stop();
}

/// A request whose command answers in a later frame: answered by the host's call to `done`
/// (`Host.finishCall`), or by `server.stop` if that comes first (`stop`).
const Waiter = struct {
    server: *Server,
    state: *State,
    host: *sdk.Host,
    req: *Server.Request,
    zon: bool,
    ticket: u32 = 0,
    /// An MCP tool call's JSON-RPC id, as JSON (`gpa`): answered as JSON-RPC, not REST.
    mcp_id: ?[]u8 = null,

    fn destroy(self: *Waiter) void {
        if (self.mcp_id) |id| self.server.gpa.free(id);
        self.server.gpa.destroy(self);
    }

    fn done(ctx: *anyopaque, outcome: sdk.Host.CommandOutcome) void {
        const self: *Waiter = @ptrCast(@alignCast(ctx));
        var arena: std.heap.ArenaAllocator = .init(self.server.gpa);
        defer arena.deinit();
        const oom: Answer = .{ .status = .internal_server_error, .content_type = "text/plain", .body = "out of memory\n" };
        const a: Answer = if (self.mcp_id) |id|
            if (mcp.outcomeReply(arena.allocator(), id, outcome)) |body| .{ .status = .ok, .body = body } else |_| oom
        else
            outcomeAnswer(arena.allocator(), self.zon, "", outcome) catch oom;
        self.req.answer(self.server, a.status, a.content_type, a.body);
        for (self.state.waiters.items, 0..) |w, i| if (w == self) {
            _ = self.state.waiters.swapRemove(i);
            break;
        };
        self.destroy();
    }
};

/// What the routes keep between frames, owned beside the server (`App.control_state`): the requests
/// whose commands answer later, and the subscription that relays the app's events to the server's
/// streams. Its plugin is a pseudo-plugin, as fizzy's own commands have
/// (`fizzy_plugin` in fizzy's `Keybinds.zig`): never in `host.plugins`, so no hook fires on it. It
/// listens only while a stream is open, so with none an emitted event costs the bus its one atomic
/// load, as before.
pub const State = struct {
    plugin: sdk.Plugin = .{
        .state = undefined, // the server, set when it starts listening
        .vtable = &relay_vtable,
        .id = "fizzy.control",
        .display_name = "Control server",
    },
    on: bool = false,
    /// Requests whose commands answer in a later frame (`Waiter`). UI thread.
    waiters: std.ArrayListUnmanaged(*Waiter) = .empty,
    /// The MCP clients that initialized (`mcp.Sessions`). UI thread.
    sessions: mcp.Sessions = .{},

    const relay_vtable: sdk.Plugin.VTable = .{};

    fn follow(self: *State, host: *sdk.Host, server: *Server, on: bool) void {
        if (on == self.on) return;
        if (on) {
            self.plugin.state = server;
            host.subscribe(.{ .event = "*", .owner = &self.plugin, .handler = relayEvent }) catch return;
        } else host.withdrawPlugin(&self.plugin);
        self.on = on;
    }
};

/// One event, as JSON once, to every stream that wants it (`Server.publish`).
fn relayEvent(state: *anyopaque, event: sdk.events.Event) void {
    const server: *Server = @ptrCast(@alignCast(state));
    // Built only for a stream that reads it: a client on one topic costs the others nothing.
    if (!server.wants(event.name)) return;
    var arena_state: std.heap.ArenaAllocator = .init(server.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data = json.jsonFromZon(arena, event.payload) catch |err| switch (err) {
        // A payload that is not ZON goes as its text, which JSON can carry while it is UTF-8.
        error.NotZon => if (std.unicode.utf8ValidateSlice(event.payload))
            std.json.Stringify.valueAlloc(arena, .{ .zon = event.payload }, .{}) catch "null"
        else
            "null",
        // Said as `null` rather than dropped: the client still learns that it happened.
        error.NotUtf8, error.OutOfMemory, error.NotJson, error.NotAnObject => "null",
    };
    server.publish(event.name, data);
}

/// Answer one request. Everything returned lives in `arena`.
pub fn handle(host: *sdk.Host, method: std.http.Method, path: []const u8, content_type: ?[]const u8, body: []const u8, arena: std.mem.Allocator) Answer {
    return route(host, method, path, content_type, body, arena, null, null) catch .{
        .status = .internal_server_error,
        .content_type = "text/plain",
        .body = "out of memory\n",
    };
}

fn route(host: *sdk.Host, method: std.http.Method, path: []const u8, content_type: ?[]const u8, body: []const u8, arena: std.mem.Allocator, waiter: ?*Waiter, session: ?*mcp.Context) error{OutOfMemory}!Answer {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    if (trimmed.len == 0) {
        if (method != .GET and method != .HEAD) return notAllowed(arena, "GET");
        return ok(arena, .{
            .name = AppInfo.current.name,
            .version = AppInfo.current.version,
            .sdk_version = try std.fmt.allocPrint(arena, "{f}", .{sdk.version.sdk_version}),
        });
    }
    if (std.mem.eql(u8, trimmed, "/commands")) {
        if (method != .GET and method != .HEAD) return notAllowed(arena, "GET");
        var list: std.ArrayListUnmanaged(CommandInfo) = .empty;
        for (host.commands.items) |*c| try list.append(arena, try describe(c, arena));
        return ok(arena, list.items);
    }
    if (std.mem.eql(u8, trimmed, "/openapi.json")) {
        return switch (method) {
            .GET => .{ .status = .ok, .body = try openapi.generate(host, arena) },
            // Not generated only to be thrown away.
            .HEAD => .{ .status = .ok, .body = "" },
            else => notAllowed(arena, "GET"),
        };
    }
    if (std.mem.eql(u8, trimmed, "/mcp")) {
        // A client ends its session.
        if (method == .DELETE) {
            const ctx = session orelse return notAllowed(arena, "POST");
            const id = mcp.parseSession(ctx.header orelse return failure(arena, .bad_request, "DELETE /mcp names its session in Mcp-Session-Id")) orelse
                return failure(arena, .bad_request, "Mcp-Session-Id is 16 hex digits");
            if (!ctx.sessions.end(ctx.gpa, host, id)) return failure(arena, .not_found, "no such session");
            return .{ .status = .ok, .body = "" };
        }
        if (method != .POST) return notAllowed(arena, if (session != null) "POST, DELETE" else "POST");
        const sink: ?sdk.Host.CallSink = if (waiter) |w| .{ .ctx = w, .done = Waiter.done } else null;
        const reply = try mcp.handle(host, body, arena, sink, session);
        const opened = if (session) |ctx| ctx.opened else null;
        return switch (reply) {
            .now => |r| .{ .status = .ok, .body = r, .mcp_session = opened },
            .unknown_session => failure(arena, .not_found, "no such session: initialize again"),
            .none => .{ .status = .accepted, .body = "" },
            .later => |l| later: {
                const w = waiter.?;
                w.ticket = l.ticket;
                w.mcp_id = w.server.gpa.dupe(u8, l.id) catch {
                    host.abandonCall(l.ticket);
                    return failure(arena, .internal_server_error, "out of memory");
                };
                break :later .{ .status = .ok, .later = true, .body = "" };
            },
        };
    }
    if (std.mem.eql(u8, trimmed, "/events")) {
        return switch (method) {
            .GET => .{ .status = .ok, .stream = true, .body = "" },
            // The headers alone: a stream that sends no body would never end.
            .HEAD => .{ .status = .ok, .content_type = "text/event-stream", .body = "" },
            else => notAllowed(arena, "GET"),
        };
    }
    const prefix = "/commands/";
    if (std.mem.startsWith(u8, trimmed, prefix)) {
        const id = std.Uri.percentDecodeInPlace(try arena.dupe(u8, trimmed[prefix.len..]));
        const c = host.command(id) orelse
            return failure(arena, .not_found, try std.fmt.allocPrint(arena, "no command {s}", .{id}));
        return switch (method) {
            .GET, .HEAD => ok(arena, try describe(c, arena)),
            .POST => call(host, c, content_type, body, arena, waiter),
            else => notAllowed(arena, "GET, POST"),
        };
    }
    return failure(arena, .not_found, try std.fmt.allocPrint(arena, "nothing at {s}", .{path}));
}

fn call(host: *sdk.Host, c: *const sdk.Command, content_type: ?[]const u8, body: []const u8, arena: std.mem.Allocator, waiter: ?*Waiter) error{OutOfMemory}!Answer {
    const as_zon = isZon(content_type);
    const args = if (as_zon) body else args: {
        var enum_keys: std.ArrayListUnmanaged([]const u8) = .empty;
        for (c.params) |p| if (p.kind == .enumeration) try enum_keys.append(arena, p.key);
        break :args json.zonFromJson(arena, body, enum_keys.items) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.NotAnObject => failure(arena, .bad_request, "the arguments are a JSON object keyed by the command's params"),
            else => failure(arena, .bad_request, "the body is not JSON (send ZON as application/zon)"),
        };
    };
    const sink: ?sdk.Host.CallSink = if (waiter) |w| .{ .ctx = w, .done = Waiter.done } else null;
    switch (host.callCommandAwaiting(c.id, args, arena, sink)) {
        .now => |outcome| return outcomeAnswer(arena, as_zon, c.id, outcome),
        .later => |ticket| {
            // With nobody to wait (`handle`), it has started: say so rather than hold an answer.
            const w = waiter orelse return .{ .status = .accepted, .body = "null" };
            w.ticket = ticket;
            return .{ .status = .ok, .later = true, .body = "" };
        },
    }
}

fn outcomeAnswer(arena: std.mem.Allocator, as_zon: bool, id: []const u8, outcome: sdk.Host.CommandOutcome) error{OutOfMemory}!Answer {
    switch (outcome) {
        .ok => |result| {
            if (as_zon) return .{ .status = .ok, .content_type = zon_type, .body = result orelse "null" };
            const out = json.jsonFromZon(arena, result) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.NotUtf8 => failure(arena, .internal_server_error, "the command's result holds text that is not UTF-8 (ask for application/zon)"),
                else => failure(arena, .internal_server_error, "the command's result is not ZON"),
            };
            return .{ .status = .ok, .body = out };
        },
        .unknown => return failure(arena, .not_found, try std.fmt.allocPrint(arena, "no command {s}", .{id})),
        .disabled => return failure(arena, .conflict, "the command is not enabled now"),
        .bad_args => |msg| return failure(arena, .bad_request, msg),
        .failed => |msg| return failure(arena, .internal_server_error, msg),
    }
}

fn isZon(content_type: ?[]const u8) bool {
    const t = content_type orelse return false;
    const bare = std.mem.trim(u8, t[0 .. std.mem.indexOfScalar(u8, t, ';') orelse t.len], " ");
    return std.ascii.eqlIgnoreCase(bare, zon_type);
}

const CommandInfo = struct {
    id: []const u8,
    title: []const u8,
    owner: ?[]const u8,
    /// `external`: a person finds it too; `internal`: called by id only.
    visibility: []const u8,
    enabled: bool,
    params: []const ParamInfo,
};

const ParamInfo = struct {
    key: []const u8,
    label: []const u8,
    description: []const u8,
    /// `bool`, `int`, `float`, `string`, `enum`, `color` or `zon` (anything else ZON can say).
    kind: []const u8,
    required: bool,
    /// The default; absent when required or not simple to write.
    default: ?std.json.Value = null,
    min: ?f64 = null,
    max: ?f64 = null,
    choices: ?[]const []const u8 = null,
};

fn describe(c: *const sdk.Command, arena: std.mem.Allocator) error{OutOfMemory}!CommandInfo {
    const params = try arena.alloc(ParamInfo, c.params.len);
    for (c.params, params) |p, *out| {
        out.* = .{
            .key = p.key,
            .label = p.label,
            .description = p.description,
            .kind = switch (p.kind) {
                .bool => "bool",
                .int => "int",
                .float => "float",
                .string => "string",
                .enumeration => "enum",
                .color => "color",
                .other => "zon",
            },
            .required = p.required,
        };
        switch (p.kind) {
            .int => |k| {
                out.min = @floatFromInt(k.min);
                out.max = @floatFromInt(k.max);
            },
            .float => |k| {
                out.min = k.min;
                out.max = k.max;
            },
            .enumeration => |k| out.choices = k.choices,
            else => {},
        }
        if (p.default) |d| if (json.jsonFromZon(arena, d)) |text| {
            out.default = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch null;
        } else |_| {};
    }
    const enabled = if (c.isEnabled) |f| if (c.owner) |o| f(o.state) else false else true;
    return .{
        .id = c.id,
        .title = c.title,
        .owner = if (c.owner) |o| o.id else null,
        .visibility = @tagName(c.visibility),
        .enabled = enabled,
        .params = params,
    };
}

fn ok(arena: std.mem.Allocator, value: anytype) error{OutOfMemory}!Answer {
    return .{ .status = .ok, .body = try std.json.Stringify.valueAlloc(arena, value, .{ .emit_null_optional_fields = false }) };
}

fn failure(arena: std.mem.Allocator, status: std.http.Status, message: []const u8) error{OutOfMemory}!Answer {
    return .{ .status = status, .body = try std.json.Stringify.valueAlloc(arena, .{ .@"error" = message }, .{}) };
}

fn notAllowed(arena: std.mem.Allocator, allowed: []const u8) error{OutOfMemory}!Answer {
    return failure(arena, .method_not_allowed, try std.fmt.allocPrint(arena, "use {s}", .{allowed}));
}
