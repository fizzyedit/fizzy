//! What the control server answers, on the UI thread: fizzy's identity and its commands
//! (plans/CONTROL_SERVER_PLAN.md, "The API"). The API is the commands every loaded plugin
//! registered, with the parameters each declared; nothing registers a route.
//!
//!   GET  /                 the app, its version, the SDK it was built against
//!   GET  /commands         every command: id, title, owner, whether it is enabled, its params
//!   GET  /commands/{id}    one of them
//!   POST /commands/{id}    run it: the body is its arguments, the response its result
//!   GET  /openapi.json     all of this as OpenAPI 3.1, generated from what is registered now
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
const Server = @import("Server.zig");

pub const Answer = struct {
    /// Stream the app's events to this connection instead (`GET /events`).
    stream: bool = false,
    status: std.http.Status,
    /// Static: a string literal.
    content_type: []const u8 = "application/json",
    body: []const u8,
};

const zon_type = "application/zon";

/// Answer what waits on `server`. On the UI thread, once a frame, before plugins' `beginFrame`, so
/// a command run here is seen by the frame that follows.
pub fn answerPending(server: *Server, relay: *Relay, host: *sdk.Host) void {
    var taken: std.ArrayListUnmanaged(*Server.Request) = .empty;
    defer taken.deinit(server.gpa);
    var streaming = server.take(&taken) > 0;
    for (taken.items) |req| {
        var arena: std.heap.ArenaAllocator = .init(server.gpa);
        defer arena.deinit();
        const a = handle(host, req.method, req.path(), req.content_type, req.body, arena.allocator());
        if (a.stream) {
            req.answerStream(server);
            streaming = true;
        } else req.answer(server, a.status, a.content_type, a.body);
    }
    relay.follow(host, server, streaming);
}

/// Stop relaying and stop `server`. On the UI thread, at quit: after it, no event reaches the
/// stopped server.
pub fn stop(server: *Server, relay: *Relay, host: *sdk.Host) void {
    relay.follow(host, server, false);
    server.stop();
}

/// The subscription that relays the app's events to the server's streams, owned beside the server
/// (`App.control_relay`). Its plugin is a pseudo-plugin, as fizzy's own commands have
/// (`fizzy_plugin` in fizzy's `Keybinds.zig`): never in `host.plugins`, so no hook fires on it. It
/// listens only while a stream is open, so with none an emitted event costs the bus its one atomic
/// load, as before.
pub const Relay = struct {
    plugin: sdk.Plugin = .{
        .state = undefined, // the server, set when it starts listening
        .vtable = &relay_vtable,
        .id = "fizzy.control",
        .display_name = "Control server",
    },
    on: bool = false,

    const relay_vtable: sdk.Plugin.VTable = .{};

    fn follow(self: *Relay, host: *sdk.Host, server: *Server, on: bool) void {
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
    return route(host, method, path, content_type, body, arena) catch .{
        .status = .internal_server_error,
        .content_type = "text/plain",
        .body = "out of memory\n",
    };
}

fn route(host: *sdk.Host, method: std.http.Method, path: []const u8, content_type: ?[]const u8, body: []const u8, arena: std.mem.Allocator) error{OutOfMemory}!Answer {
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
            .POST => call(host, c, content_type, body, arena),
            else => notAllowed(arena, "GET, POST"),
        };
    }
    return failure(arena, .not_found, try std.fmt.allocPrint(arena, "nothing at {s}", .{path}));
}

fn call(host: *sdk.Host, c: *const sdk.Command, content_type: ?[]const u8, body: []const u8, arena: std.mem.Allocator) error{OutOfMemory}!Answer {
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
    switch (host.callCommand(c.id, args, arena)) {
        .ok => |result| {
            if (as_zon) return .{ .status = .ok, .content_type = zon_type, .body = result orelse "null" };
            const out = json.jsonFromZon(arena, result) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.NotUtf8 => failure(arena, .internal_server_error, "the command's result holds text that is not UTF-8 (ask for application/zon)"),
                else => failure(arena, .internal_server_error, "the command's result is not ZON"),
            };
            return .{ .status = .ok, .body = out };
        },
        .unknown => return failure(arena, .not_found, try std.fmt.allocPrint(arena, "no command {s}", .{c.id})),
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
