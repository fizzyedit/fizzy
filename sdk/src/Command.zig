//! A named, invocable action a plugin registers with the Host. Fizzy, menus, and keybindings
//! trigger it by `id` via `Host.runCommand(id)` **without knowing what it does** — this is how a
//! plugin contributes its own features (atlas pack, raster transform, a grid-layout dialog, …)
//! without the SDK or fizzy naming them. Ids are plugin-namespaced (`"pixi.packProject"`).
//! The owner resolves any context it needs (active doc, selection, …) inside `run`; fizzy passes
//! only the owner's opaque state.
//!
//! **Arguments and a result.** A command may also declare parameters and take them as ZON
//! (`.{ .line = 12 }`), returning a result as ZON (`Host.callCommand`). Bytes cross the boundary
//! and types live on each side: `Params` turns a struct of `Arg` cells into the descriptors fizzy
//! reads (`params`) and parses the arguments back into that struct inside the plugin, so the
//! argument struct's layout never enters the ABI fingerprint and can change freely. Whoever
//! invokes the command — the palette asking a person for each required parameter, a keybind, a
//! tape, another plugin — sees only the descriptors and the text.
//!
//!   const GoToLine = sdk.Command.Params(struct {
//!       line: sdk.Command.Arg(u32, .{ .description = "The line to go to, from 1." }),
//!       column: sdk.Command.Arg(u32, .{ .description = "The column, from 1." }) = .init(1),
//!   });
//!   try host.registerCommand(.{
//!       .id = "text.goToLine",
//!       .owner = &plugin,
//!       .title = "Go to Line…",
//!       .params = GoToLine.params,
//!       .runWith = GoToLine.bind(goToLine),
//!   });
//!   fn goToLine(state: *anyopaque, args: GoToLine.Args, call: *sdk.Command.Call) !void { … }
const std = @import("std");
const Plugin = @import("Plugin.zig");
const settings = @import("settings.zig");

const Command = @This();

id: []const u8,
owner: ?*Plugin = null,
/// User-facing label (menus / future command palette).
title: []const u8,
/// Invoke the command with no arguments. `state` is the owning plugin's opaque state
/// (`owner.state`). May be absent when `runWith` is set: `Host.runCommand` then runs `runWith`
/// with no arguments, or — when a parameter is required — has the app ask for them. Every
/// command has `run`, `runWith`, or both (`Host.registerCommand` refuses one with neither).
run: ?*const fn (state: *anyopaque) anyerror!void = null,
/// Optional enabled-state query — e.g. grey out while busy or with no active document.
/// Absent = always enabled.
isEnabled: ?*const fn (state: *anyopaque) bool = null,
/// Optional TVG icon bytes (e.g. `icons.tvg.lucide.save`) shown ahead of this command's label
/// wherever fizzy draws a row for it: the in-app dvui menu (a fizzy-owned `CommandItem`'s row,
/// or a plugin's `menus.SectionContribution` row via `Host.drawMenuItem`) and the command
/// palette. Absent draws no icon, not a placeholder glyph.
icon: ?[]const u8 = null,
/// What `runWith` takes, in declaration order. Empty for a command that takes nothing. Built by
/// `Params(…).params`; read by whoever asks for arguments (the palette, an automation client).
params: []const Param = &.{},
/// Invoke the command with arguments, `call.args`, and let it return a result. Built by
/// `Params(…).bind`, which parses the arguments into the plugin's own struct and reports a
/// mismatch as `call.bad_args`. Absent = the command takes no arguments.
runWith: ?*const fn (state: *anyopaque, call: *Call) anyerror!void = null,

/// One parameter, as fizzy and any caller see it — the same description a setting carries
/// (`settings.Setting`), plus whether it must be given.
pub const Param = struct {
    /// The field name: the key in the arguments (`.{ .line = 12 }`).
    key: []const u8,
    /// Human-readable name derived from `key` unless the cell overrode it.
    label: []const u8,
    /// What the parameter means, in a sentence. Required at declaration, as for a setting.
    description: []const u8,
    kind: settings.Kind,
    /// No default: a call without it is refused, and the palette asks for it.
    required: bool,
    /// The default as ZON, for a parameter that has one of a simple type (bool, number, enum,
    /// string). Null when required, or when the default is not simple to write.
    default: ?[]const u8 = null,
};

/// One invocation through `runWith`: the arguments in, and the result or the reason out. All of
/// it lives in `arena`, the caller's, which outlives the call — the command allocates its result
/// and its message there and never frees them.
pub const Call = struct {
    /// The arguments as ZON — a struct literal keyed by `params`' keys. Empty means none.
    args: []const u8,
    arena: std.mem.Allocator,
    /// Set by the command: its result as ZON. Null = nothing to return.
    result: ?[]const u8 = null,
    /// Set by the command when it fails: why, in words a person can read. A plugin's error
    /// cannot be named on the caller's side (errors are numbered per compilation —
    /// `Plugin.errorName`), so this is how the reason crosses.
    message: ?[]const u8 = null,
    /// Set, with `message`, when `args` did not fit the parameters. `bind` does this; a
    /// hand-written `runWith` rarely needs to.
    bad_args: bool = false,

    /// Return `value` (anything `std.zon.stringify` can write) as the command's result.
    pub fn returns(self: *Call, value: anytype) error{OutOfMemory}!void {
        var aw: std.Io.Writer.Allocating = .init(self.arena);
        std.zon.stringify.serialize(value, .{}, &aw.writer) catch return error.OutOfMemory;
        self.result = aw.written();
    }

    /// Fail with a message: `return call.fail("no line {d}", .{n});`.
    pub fn fail(self: *Call, comptime fmt: []const u8, args: anytype) error{CommandFailed} {
        self.message = std.fmt.allocPrint(self.arena, fmt, args) catch fmt;
        return error.CommandFailed;
    }
};

/// One self-describing parameter: a settings cell, with the same required description and
/// optional name and bounds (`settings.Options`). Give it a default (`= .init(1)`) to make the
/// parameter optional; leave it off to make it required.
pub const Arg = settings.Value;

/// Whether any of `params` must be given.
pub fn requiresArguments(params: []const Param) bool {
    for (params) |p| {
        if (p.required) return true;
    }
    return false;
}

/// What a person typed for one parameter, as ZON — or why it does not fit.
pub const Answer = union(enum) {
    zon: []const u8,
    problem: []const u8,
};

/// Turn `text`, typed for `param`, into the ZON value it means: a number checked against an
/// int's bounds, a string quoted, an enum tag or bool by name, anything else taken as ZON as it
/// stands. For whoever asks a person for arguments (fizzy's palette), so each one does not
/// re-derive the rules. A float's bounds are not checked: `settings.Kind` gives an unbounded
/// float the 0..1 a setting slider wants, which says nothing about a parameter — the command
/// checks its own.
pub fn answer(arena: std.mem.Allocator, param: Param, text: []const u8) Answer {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0 and param.kind != .string) return .{ .problem = "Required" };
    switch (param.kind) {
        .bool => {
            if (std.mem.eql(u8, t, "true") or std.mem.eql(u8, t, "false")) return .{ .zon = t };
            return .{ .problem = "Choose true or false" };
        },
        .int => |k| {
            const n = std.fmt.parseInt(i64, t, 10) catch return .{ .problem = "Enter a whole number" };
            if (n < k.min or n > k.max) return .{ .problem = std.fmt.allocPrint(
                arena,
                "Enter a number from {d} to {d}",
                .{ k.min, k.max },
            ) catch "Out of range" };
            return .{ .zon = std.fmt.allocPrint(arena, "{d}", .{n}) catch return .{ .problem = "Out of memory" } };
        },
        .float => {
            const n = std.fmt.parseFloat(f64, t) catch return .{ .problem = "Enter a number" };
            if (!std.math.isFinite(n)) return .{ .problem = "Enter a finite number" };
            return .{ .zon = std.fmt.allocPrint(arena, "{d}", .{n}) catch return .{ .problem = "Out of memory" } };
        },
        .string => return .{ .zon = std.fmt.allocPrint(arena, "\"{f}\"", .{std.zig.fmtString(text)}) catch
            return .{ .problem = "Out of memory" } },
        .enumeration => |k| {
            const name = if (t[0] == '.') t[1..] else t;
            for (k.choices) |choice| {
                if (std.mem.eql(u8, choice, name)) return .{ .zon = std.fmt.allocPrint(arena, ".{f}", .{std.zig.fmtId(choice)}) catch
                    return .{ .problem = "Out of memory" } };
            }
            return .{ .problem = "Choose one of the listed values" };
        },
        .color, .other => return .{ .zon = t },
    }
}

/// Build a command's parameters from `T`, a struct whose every field is an `Arg(…)` cell.
pub fn Params(comptime T: type) type {
    const built = buildParams(T);
    return struct {
        /// What the handler receives: `T`'s fields with bare payload types. A parameter with a
        /// default keeps it; one without has none, so leaving it out fails the parse.
        pub const Args = Plain(T);
        pub const params: []const Param = &built;

        /// Parse `call.args` into `Args`. On a mismatch, sets `call.bad_args` and a message
        /// naming where, and returns `error.BadArguments`.
        pub fn parse(call: *Call) error{ BadArguments, OutOfMemory }!Args {
            const text = std.mem.trim(u8, call.args, " \t\r\n");
            const source = try call.arena.dupeZ(u8, if (text.len == 0) ".{}" else text);
            var diag: std.zon.parse.Diagnostics = .{};
            return std.zon.parse.fromSliceAlloc(Args, call.arena, source, &diag, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ParseZon => {
                    call.bad_args = true;
                    const msg = std.fmt.allocPrint(call.arena, "{f}", .{&diag}) catch "the arguments do not fit";
                    call.message = std.mem.trimEnd(u8, msg, "\n");
                    return error.BadArguments;
                },
            };
        }

        /// The `runWith` for `handler`: parse, then call it with the plugin's own struct.
        pub fn bind(
            comptime handler: fn (state: *anyopaque, args: Args, call: *Call) anyerror!void,
        ) *const fn (state: *anyopaque, call: *Call) anyerror!void {
            return &struct {
                fn run(state: *anyopaque, call: *Call) anyerror!void {
                    return handler(state, try parse(call), call);
                }
            }.run;
        }
    };
}

fn buildParams(comptime T: type) [std.meta.fields(T).len]Param {
    const fields = std.meta.fields(T);
    var out: [fields.len]Param = undefined;
    for (fields, 0..) |f, i| {
        if (!settings.isCell(f.type)) @compileError(
            "sdk.Command.Params: field '" ++ f.name ++ "' of " ++ @typeName(T) ++
                " must be an argument cell — `" ++ f.name ++ ": sdk.Command.Arg(" ++
                @typeName(f.type) ++ ", .{ .description = \"…\" })`. Every parameter needs a description.",
        );
        const opts = f.type.setting_options;
        const default: ?f.type.Payload = if (f.defaultValue()) |cell| cell.v else null;
        out[i] = .{
            .key = f.name,
            .label = opts.name orelse settings.deriveLabel(f.name),
            .description = opts.description,
            .kind = settings.kindFor(f.type.Payload, opts),
            .required = default == null,
            .default = if (default) |d| defaultZon(f.type.Payload, d) else null,
        };
    }
    return out;
}

/// `value` as ZON, for the simple payloads a caller can show as a default; null otherwise.
fn defaultZon(comptime P: type, comptime value: P) ?[]const u8 {
    return switch (@typeInfo(P)) {
        .bool => if (value) "true" else "false",
        .int, .float => std.fmt.comptimePrint("{d}", .{value}),
        .@"enum" => std.fmt.comptimePrint(".{f}", .{std.zig.fmtId(@tagName(value))}),
        .pointer => |p| if (p.size == .slice and p.child == u8)
            std.fmt.comptimePrint("\"{f}\"", .{std.zig.fmtString(value)})
        else
            null,
        else => null,
    };
}

/// `T`'s fields with bare payload types, each keeping its cell's default if it has one.
fn Plain(comptime T: type) type {
    const fields = std.meta.fields(T);
    var names: [fields.len][:0]const u8 = undefined;
    var types: [fields.len]type = undefined;
    var attrs: [fields.len]std.builtin.Type.StructField.Attributes = undefined;
    for (fields, 0..) |f, i| {
        const P = f.type.Payload;
        names[i] = f.name;
        types[i] = P;
        attrs[i] = if (f.defaultValue()) |cell| blk: {
            const payload_default: P = cell.v;
            break :blk .{ .default_value_ptr = @ptrCast(&payload_default) };
        } else .{};
    }
    const frozen_names = names;
    const frozen_types = types;
    const frozen_attrs = attrs;
    return @Struct(.auto, null, &frozen_names, &frozen_types, &frozen_attrs);
}

test "Params: descriptors, defaults and parsing" {
    const Mode = enum { fast, careful };
    const P = Params(struct {
        line: Arg(u32, .{ .description = "The line." }),
        column: Arg(u32, .{ .description = "The column." }) = .init(1),
        mode: Arg(Mode, .{ .description = "How." }) = .init(.careful),
        note: Arg([]const u8, .{ .description = "A note.", .name = "Remark" }) = .init("hi \"there\""),
        on: Arg(bool, .{ .description = "Whether." }) = .init(false),
    });
    try std.testing.expectEqual(@as(usize, 5), P.params.len);
    try std.testing.expect(P.params[0].required);
    try std.testing.expectEqual(@as(?[]const u8, null), P.params[0].default);
    try std.testing.expectEqualStrings("Line", P.params[0].label);
    try std.testing.expect(!P.params[1].required);
    try std.testing.expectEqualStrings("1", P.params[1].default.?);
    try std.testing.expectEqualStrings(".careful", P.params[2].default.?);
    try std.testing.expectEqualStrings("Remark", P.params[3].label);
    try std.testing.expectEqualStrings("\"hi \\\"there\\\"\"", P.params[3].default.?);
    try std.testing.expectEqualStrings("false", P.params[4].default.?);
    try std.testing.expect(requiresArguments(P.params));

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ok: Call = .{ .args = ".{ .line = 12, .mode = .fast }", .arena = arena };
    const args = try P.parse(&ok);
    try std.testing.expectEqual(@as(u32, 12), args.line);
    try std.testing.expectEqual(@as(u32, 1), args.column);
    try std.testing.expectEqual(Mode.fast, args.mode);
    try std.testing.expectEqualStrings("hi \"there\"", args.note);

    var missing: Call = .{ .args = "", .arena = arena };
    try std.testing.expectError(error.BadArguments, P.parse(&missing));
    try std.testing.expect(missing.bad_args);
    try std.testing.expect(std.mem.indexOf(u8, missing.message.?, "line") != null);

    var unknown: Call = .{ .args = ".{ .line = 1, .lime = 2 }", .arena = arena };
    try std.testing.expectError(error.BadArguments, P.parse(&unknown));
}

test "answer: what a person typed, as ZON the parameters parse" {
    const Mode = enum { fast, @"very careful" };
    const P = Params(struct {
        n: Arg(u8, .{ .description = "A small number." }),
        x: Arg(f32, .{ .description = "Any number." }),
        on: Arg(bool, .{ .description = "Whether." }),
        mode: Arg(Mode, .{ .description = "How." }),
        name: Arg([]const u8, .{ .description = "A name." }),
    });
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("12", answer(arena, P.params[0], " 12 ").zon);
    try std.testing.expectEqualStrings("Enter a number from 0 to 255", answer(arena, P.params[0], "256").problem);
    try std.testing.expectEqualStrings("Enter a whole number", answer(arena, P.params[0], "1.5").problem);
    try std.testing.expectEqualStrings("Required", answer(arena, P.params[0], "").problem);
    try std.testing.expectEqualStrings("12.5", answer(arena, P.params[1], "12.5").zon);
    try std.testing.expectEqualStrings("true", answer(arena, P.params[2], "true").zon);
    try std.testing.expectEqualStrings(".fast", answer(arena, P.params[3], ".fast").zon);
    try std.testing.expectEqualStrings(".@\"very careful\"", answer(arena, P.params[3], "very careful").zon);
    try std.testing.expect(answer(arena, P.params[3], "slow") == .problem);
    try std.testing.expectEqualStrings("\"say \\\"hi\\\"\"", answer(arena, P.params[4], "say \"hi\"").zon);
    try std.testing.expectEqualStrings("\"\"", answer(arena, P.params[4], "").zon);

    // Everything `answer` writes, the parameters parse back.
    const args = try std.fmt.allocPrint(arena, ".{{ .n = {s}, .x = {s}, .on = {s}, .mode = {s}, .name = {s} }}", .{
        answer(arena, P.params[0], "7").zon,
        answer(arena, P.params[1], "-0.25").zon,
        answer(arena, P.params[2], "false").zon,
        answer(arena, P.params[3], "very careful").zon,
        answer(arena, P.params[4], "a\\b\n").zon,
    });
    var call: Call = .{ .args = args, .arena = arena };
    const parsed = try P.parse(&call);
    try std.testing.expectEqual(@as(u8, 7), parsed.n);
    try std.testing.expectEqual(@as(f32, -0.25), parsed.x);
    try std.testing.expectEqual(Mode.@"very careful", parsed.mode);
    try std.testing.expectEqualStrings("a\\b\n", parsed.name);
}

test "Params.bind runs the handler with parsed arguments and its result" {
    const P = Params(struct {
        n: Arg(i32, .{ .description = "A number." }),
    });
    const H = struct {
        fn double(_: *anyopaque, args: P.Args, call: *Call) anyerror!void {
            if (args.n < 0) return call.fail("{d} is negative", .{args.n});
            try call.returns(.{ .doubled = args.n * 2 });
        }
    };
    const run = P.bind(H.double);

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var dummy: u8 = 0;

    var good: Call = .{ .args = ".{ .n = 21 }", .arena = arena_state.allocator() };
    try run(&dummy, &good);
    try std.testing.expectEqualStrings(".{ .doubled = 42 }", good.result.?);

    var bad: Call = .{ .args = ".{ .n = -1 }", .arena = arena_state.allocator() };
    try std.testing.expectError(error.CommandFailed, run(&dummy, &bad));
    try std.testing.expectEqualStrings("-1 is negative", bad.message.?);
    try std.testing.expect(!bad.bad_args);
}
