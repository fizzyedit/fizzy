//! Repository lint with per-file budgets for existing findings.
const std = @import("std");

const Rule = enum { @"fn-length", @"create-needs-destroy", @"lint-allow-reason", @"file-alias", anyerror };
const Finding = struct { rule: Rule, line: usize, message: []const u8 };
const Allow = struct { rule: Rule, file: []const u8, count: usize };
const Suppression = struct { rule: []const u8, line: usize };
const skip_dirs = [_][]const u8{ "zig-pkg", "zig-out", "zig-cache", "spikes", "examples", "node_modules" };

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const verbose = args.len == 2 and std.mem.eql(u8, args[1], "--verbose");
    if (args.len > 1 and !verbose) return error.InvalidArguments;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const source = try cwd.readFileAllocOptions(io, "scripts/lint-allow.zon", allocator, .unlimited, .of(u8), 0);
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const parsed = std.zon.parse.fromSlice([]const Allow, .{
        .gpa = allocator,
        .arena = allocator,
        .source = source,
        .diagnostics = &diagnostics,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.ParseZon => diagnostics.fatal("scripts/lint-allow.zon"),
    };
    for (parsed, 0..) |allow, index| {
        for (parsed[0..index]) |previous| {
            if (allow.rule == previous.rule and std.mem.eql(u8, allow.file, previous.file))
                return error.DuplicateAllowance;
        }
    }
    const seen = try allocator.alloc(bool, parsed.len);
    @memset(seen, false);
    var dir = try cwd.openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walkSelectively(allocator);
    defer walker.deinit();
    var failed = false;
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (entry.basename[0] == '.') continue;
            for (skip_dirs) |skip| {
                if (std.mem.eql(u8, skip, entry.basename)) break;
            } else try walker.enter(io, entry);
        } else if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".zig")) {
            const path = try allocator.dupe(u8, entry.path);
            std.mem.replaceScalar(u8, path, '\\', '/');
            const bytes = try entry.dir.readFileAllocOptions(io, entry.basename, allocator, .unlimited, .of(u8), 0);
            const stem = entry.basename[0 .. entry.basename.len - ".zig".len];
            const findings = try std.mem.concat(allocator, Finding, &.{
                try analyze(allocator, bytes),
                try fileAlias(allocator, bytes, stem),
            });
            failed = try reportFile(&output.writer, path, findings, parsed, seen, verbose) or failed;
        }
    }
    for (parsed, seen) |allow, visited| if (!visited) {
        try output.writer.print("{s}:1: {s}: file not found; remove its allowance of {d}\n", .{ allow.file, @tagName(allow.rule), allow.count });
        failed = true;
    };
    std.debug.print("{s}", .{output.written()});
    if (failed) std.process.exit(1);
}

fn reportFile(
    writer: *std.Io.Writer,
    path: []const u8,
    findings: []const Finding,
    allowances: []const Allow,
    seen: []bool,
    verbose: bool,
) !bool {
    var failed = false;
    inline for (std.meta.tags(Rule)) |rule| {
        var count: usize = 0;
        for (findings) |finding| if (finding.rule == rule) {
            count += 1;
        };
        var budget: usize = 0;
        for (allowances, 0..) |allow, index| {
            if (allow.rule == rule and std.mem.eql(u8, allow.file, path)) {
                seen[index] = true;
                budget = allow.count;
            }
        }
        const status = ratchet(count, budget);
        if (verbose or status == .over) {
            for (findings) |finding| {
                if (finding.rule == rule) try writer.print("{s}:{d}: {s}: {s}\n", .{
                    path, finding.line, @tagName(rule), finding.message,
                });
            }
        }
        switch (status) {
            .over => {
                try writer.print("{s}:1: {s}: count {d} exceeds allowance {d}\n", .{ path, @tagName(rule), count, budget });
                failed = true;
            },
            .under => {
                try writer.print("{s}:1: {s}: count {d} is under allowance {d}; lower the allowance to {d}\n", .{ path, @tagName(rule), count, budget, count });
                failed = true;
            },
            .equal => {},
        }
    }
    return failed;
}

fn ratchet(count: usize, budget: usize) enum { over, under, equal } {
    return if (count > budget) .over else if (count < budget) .under else .equal;
}

/// Use an arena for `allocator`; findings and formatted messages share its lifetime.
fn analyze(allocator: std.mem.Allocator, source: [:0]const u8) ![]Finding {
    var tree = try std.zig.Ast.parse(allocator, source, .{});
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) return error.InvalidZigSource;
    var findings: std.ArrayList(Finding) = .empty;
    errdefer findings.deinit(allocator);
    var suppressions: std.ArrayList(Suppression) = .empty;
    defer suppressions.deinit(allocator);
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_number: usize = 0;
    while (lines.next()) |line| {
        line_number += 1;
        const comment = commentStart(line) orelse continue;
        const text = std.mem.trim(u8, line[comment + 2 ..], " \t\r");
        const prefix = "lint-allow(";
        if (!std.mem.startsWith(u8, text, prefix)) continue;
        const close = std.mem.findScalar(u8, text, ')') orelse text.len;
        const tail = if (close < text.len) std.mem.trim(u8, text[close + 1 ..], " \t\r") else "";
        if (tail.len < 2 or tail[0] != ':' or std.mem.trim(u8, tail[1..], " \t\r").len == 0) {
            try findings.append(allocator, .{ .rule = .@"lint-allow-reason", .line = line_number, .message = "lint-allow requires a reason after ':'" });
        } else {
            try suppressions.append(allocator, .{ .rule = text[prefix.len..close], .line = line_number });
        }
    }
    var create_line: ?usize = null;
    var has_destroy = false;
    for (0..tree.nodes.len) |index| {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(index));
        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, node) orelse continue;
        const line = tree.tokenLocation(0, tree.firstToken(node)).line + 1;
        if (tree.nodeTag(node) != .fn_decl) {
            if (proto.ast.return_type.unwrap()) |return_type| {
                const return_line = tree.tokenLocation(0, tree.firstToken(return_type)).line + 1;
                if (returnsAnyerror(tree, return_type) and
                    !silenced(suppressions.items, .anyerror, line) and
                    !silenced(suppressions.items, .anyerror, return_line))
                {
                    try findings.append(allocator, .{
                        .rule = .anyerror,
                        .line = return_line,
                        .message = "return type uses anyerror; infer or name the error set",
                    });
                }
            }
        }
        const name_token = proto.name_token orelse continue;
        const spelling = tree.tokenSlice(name_token);
        const name = if (std.mem.startsWith(u8, spelling, "@\""))
            try std.zig.string_literal.parseAlloc(allocator, spelling[1..])
        else
            spelling;
        if (std.mem.eql(u8, name, "destroy")) has_destroy = true;
        if (proto.visib_token != null and std.mem.startsWith(u8, name, "create") and create_line == null and
            !silenced(suppressions.items, .@"create-needs-destroy", line)) create_line = line;
        if (tree.nodeTag(node) != .fn_decl) continue;
        const end = tree.tokenLocation(0, tree.lastToken(node)).line + 1;
        const length = end - line + 1;
        if (length > 150 and !silenced(suppressions.items, .@"fn-length", line)) {
            try findings.append(allocator, .{ .rule = .@"fn-length", .line = line, .message = try allocator.print("function {s} is {d} lines (limit 150)", .{ name, length }) });
        }
    }
    if (create_line != null and !has_destroy) try findings.append(allocator, .{
        .rule = .@"create-needs-destroy",
        .line = create_line.?,
        .message = "file has pub fn create* but no destroy function",
    });
    return findings.toOwnedSlice(allocator);
}

/// A file-level `const X = @This();` is named for the file, as in std (`const Writer = @This();`).
/// Only top-level declarations count: `Self` inside a type-returning fn is fine.
fn fileAlias(allocator: std.mem.Allocator, source: [:0]const u8, stem: []const u8) ![]Finding {
    var tree = try std.zig.Ast.parse(allocator, source, .{});
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) return error.InvalidZigSource;
    var findings: std.ArrayList(Finding) = .empty;
    errdefer findings.deinit(allocator);
    for (tree.rootDecls()) |node| {
        const decl = tree.fullVarDecl(node) orelse continue;
        const init_node = decl.ast.init_node.unwrap() orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(decl.ast.mut_token), "const")) continue;
        var buffer: [2]std.zig.Ast.Node.Index = undefined;
        const params = tree.builtinCallParams(&buffer, init_node) orelse continue;
        if (params.len != 0) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(init_node)), "@This")) continue;
        const name = tree.tokenSlice(decl.ast.mut_token + 1);
        if (std.mem.eql(u8, name, stem)) continue;
        try findings.append(allocator, .{
            .rule = .@"file-alias",
            .line = tree.tokenLocation(0, decl.ast.mut_token).line + 1,
            .message = try allocator.print("@This() alias is {s}; name it for the file ({s})", .{ name, stem }),
        });
    }
    return findings.toOwnedSlice(allocator);
}

fn returnsAnyerror(tree: std.zig.Ast, return_type: std.zig.Ast.Node.Index) bool {
    const err_type = switch (tree.nodeTag(return_type)) {
        .error_union => tree.nodeData(return_type).node_and_node[0],
        else => return_type,
    };
    return tree.nodeTag(err_type) == .identifier and
        std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(err_type)), "anyerror");
}

fn silenced(suppressions: []const Suppression, rule: Rule, line: usize) bool {
    for (suppressions) |suppression| {
        if ((line == suppression.line or line == suppression.line + 1) and
            std.mem.eql(u8, suppression.rule, @tagName(rule))) return true;
    }
    return false;
}

// Strings and multiline string literals may contain comment-like text.
fn commentStart(line: []const u8) ?usize {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (std.mem.startsWith(u8, trimmed, "\\\\")) return null;
    var quote: ?u8 = null;
    var index: usize = 0;
    while (index < line.len) : (index += 1) {
        const char = line[index];
        if (quote) |q| {
            if (char == '\\') {
                index += 1;
            } else if (char == q) {
                quote = null;
            }
        } else if (char == '"' or char == '\'') {
            quote = char;
        } else if (char == '/' and index + 1 < line.len and line[index + 1] == '/') {
            return index;
        }
    }
    return null;
}

test "create requires destroy, with AST names and visibility" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(usize, 1), (try analyze(a, "pub fn createThing() void {}\n")).len);
    try std.testing.expectEqual(@as(usize, 1), (try analyze(a, "pub fn @\"createThing\"() void {} ")).len);
    for ([_][:0]const u8{
        "pub fn createThing() void {}\nfn @\"destroy\"() void {}",
        "pub fn createThing() void {}\nfn destroy() void {}",
        "fn createThing() void {}",
        "const s = \"pub fn createThing()\";",
        "pub fn other() void {}",
    }) |source| try std.testing.expectEqual(@as(usize, 0), (try analyze(a, source)).len);
}

test "function length includes declaration and closing brace at 150 and 151" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]usize{ 150, 151 }) |length| {
        const blanks = try a.alloc(u8, length - 2);
        @memset(blanks, '\n');
        const source = try a.printSentinel("fn long() void {{\n{s}}}", .{blanks}, 0);
        const findings = try analyze(a, source);
        try std.testing.expectEqual(@as(usize, if (length > 150) 1 else 0), findings.len);
        const allowed = try a.printSentinel("// lint-allow(fn-length): generated fixture\n{s}", .{source}, 0);
        try std.testing.expectEqual(@as(usize, 0), (try analyze(a, allowed)).len);
    }
}

test "ratchet rejects increases and decreases" {
    try std.testing.expectEqual(.over, ratchet(2, 1));
    try std.testing.expectEqual(.under, ratchet(0, 1));
    try std.testing.expectEqual(.equal, ratchet(1, 1));
    try std.testing.expectEqual(.over, ratchet(1, 0));
}

test "line suppressions require a nonempty reason" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][:0]const u8{
        "// lint-allow(create-needs-destroy): borrowed storage\npub fn create() void {}",
        "pub fn create() void {} // lint-allow(create-needs-destroy): borrowed storage",
    }) |source| try std.testing.expectEqual(@as(usize, 0), (try analyze(a, source)).len);
    for ([_][:0]const u8{
        "// lint-allow(create-needs-destroy)\npub fn create() void {}",
        "// lint-allow(create-needs-destroy):   \npub fn create() void {}",
    }) |source| {
        const findings = try analyze(a, source);
        try std.testing.expectEqual(@as(usize, 2), findings.len);
        try std.testing.expectEqual(Rule.@"lint-allow-reason", findings[0].rule);
    }
    try std.testing.expectEqual(@as(usize, 1), (try analyze(
        a,
        "// lint-allow(create-needs-destroy): reason\n\npub fn create() void {}",
    )).len);
    try std.testing.expectEqual(@as(usize, 0), (try analyze(
        a,
        "const s = \"// lint-allow(fn-length)\";",
    )).len);
}

test "runner is quiet on pass and verbose prints known findings" {
    const findings = [_]Finding{.{ .rule = .@"fn-length", .line = 2, .message = "known" }};
    const allowances = [_]Allow{.{ .rule = .@"fn-length", .file = "known.zig", .count = 1 }};
    var seen = [_]bool{false};
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expect(!try reportFile(&output.writer, "known.zig", &findings, &allowances, &seen, false));
    try std.testing.expectEqualStrings("", output.written());
    try std.testing.expect(seen[0]);
    try std.testing.expect(!try reportFile(&output.writer, "known.zig", &findings, &allowances, &seen, true));
    try std.testing.expectEqualStrings("known.zig:2: fn-length: known\n", output.written());
}

test "runner prints only over-budget rules and unallowed files" {
    const findings = [_]Finding{
        .{ .rule = .@"fn-length", .line = 2, .message = "first" },
        .{ .rule = .@"fn-length", .line = 3, .message = "second" },
        .{ .rule = .@"create-needs-destroy", .line = 4, .message = "known" },
    };
    const allowances = [_]Allow{
        .{ .rule = .@"fn-length", .file = "over.zig", .count = 1 },
        .{ .rule = .@"create-needs-destroy", .file = "over.zig", .count = 1 },
        .{ .rule = .@"fn-length", .file = "known.zig", .count = 2 },
        .{ .rule = .@"create-needs-destroy", .file = "known.zig", .count = 1 },
    };
    var seen = [_]bool{ false, false, false, false };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expect(try reportFile(&output.writer, "over.zig", &findings, &allowances, &seen, false));
    try std.testing.expect(!try reportFile(&output.writer, "known.zig", &findings, &allowances, &seen, false));
    try std.testing.expect(try reportFile(&output.writer, "new.zig", findings[2..], &allowances, &seen, false));
    try std.testing.expectEqualStrings(
        "over.zig:2: fn-length: first\n" ++
            "over.zig:3: fn-length: second\n" ++
            "over.zig:1: fn-length: count 2 exceeds allowance 1\n" ++
            "new.zig:4: create-needs-destroy: known\n" ++
            "new.zig:1: create-needs-destroy: count 1 exceeds allowance 0\n",
        output.written(),
    );
}

test "runner keeps the ratchet hint without printing remaining known findings" {
    const findings = [_]Finding{.{ .rule = .@"fn-length", .line = 2, .message = "known" }};
    const allowances = [_]Allow{.{ .rule = .@"fn-length", .file = "under.zig", .count = 2 }};
    var seen = [_]bool{false};
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expect(try reportFile(&output.writer, "under.zig", &findings, &allowances, &seen, false));
    try std.testing.expectEqualStrings(
        "under.zig:1: fn-length: count 1 is under allowance 2; lower the allowance to 1\n",
        output.written(),
    );
}

test "file alias must equal the file stem, only at the top level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][:0]const u8{
        "const Writer = @This();",
        "pub const Writer = @This();",
        "const Other = struct {};\nfn Gen() type {\n    return struct {\n        const Self = @This();\n    };\n}",
        "const x = @import(\"std\");\nconst T = @TypeOf(1);",
    }) |source| try std.testing.expectEqual(@as(usize, 0), (try fileAlias(a, source, "Writer")).len);
    const findings = try fileAlias(a, "const std = @import(\"std\");\nconst Self = @This();", "Writer");
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(Rule.@"file-alias", findings[0].rule);
    try std.testing.expectEqual(@as(usize, 2), findings[0].line);
    try std.testing.expectEqual(@as(usize, 1), (try fileAlias(a, "const writer = @This();", "Writer")).len);
}

test "file alias findings are reported over budget and quiet when baselined" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const findings = try fileAlias(arena.allocator(), "const Self = @This();", "Step");
    const allowances = [_]Allow{.{ .rule = .@"file-alias", .file = "Step.zig", .count = 1 }};
    var seen = [_]bool{false};
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expect(!try reportFile(&output.writer, "Step.zig", findings, &allowances, &seen, false));
    try std.testing.expectEqualStrings("", output.written());
    try std.testing.expect(try reportFile(&output.writer, "Claim.zig", findings, &allowances, &seen, false));
    try std.testing.expectEqualStrings(
        "Claim.zig:1: file-alias: @This() alias is Self; name it for the file (Step)\n" ++
            "Claim.zig:1: file-alias: count 1 exceeds allowance 0\n",
        output.written(),
    );
}

test "anyerror return type covers hit, allowed file, suppressed line, and ratchet-under" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][:0]const u8{
        "fn f() anyerror!void {}",
        "fn f() anyerror { return error.OutOfMemory; }",
        "const F = fn () anyerror!u32;",
        "const VTable = struct { open: *const fn () anyerror!void };",
        "fn outer() *const fn () anyerror!void { unreachable; }",
    }) |source| {
        const findings = try analyze(a, source);
        try std.testing.expectEqual(@as(usize, 1), findings.len);
        try std.testing.expectEqual(Rule.anyerror, findings[0].rule);
    }
    for ([_][:0]const u8{
        "fn f() !void {}",
        "fn f() error{OutOfMemory}!void {}",
        "fn f(err: anyerror) void { _ = err; }",
        "// lint-allow(anyerror): vtable slot\nconst VTable = struct { open: *const fn () anyerror!void };",
        "fn f() anyerror!void {} // lint-allow(anyerror): callback",
    }) |source| try std.testing.expectEqual(@as(usize, 0), (try analyze(a, source)).len);

    const hit = try analyze(a, "fn f() anyerror!void {}\n");
    const allowances = [_]Allow{
        .{ .rule = .anyerror, .file = "allowed.zig", .count = 1 },
        .{ .rule = .anyerror, .file = "under.zig", .count = 2 },
    };
    var seen = [_]bool{ false, false };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expect(try reportFile(&output.writer, "hit.zig", hit, &allowances, &seen, false));
    try std.testing.expect(!try reportFile(&output.writer, "allowed.zig", hit, &allowances, &seen, false));
    try std.testing.expect(try reportFile(&output.writer, "under.zig", hit, &allowances, &seen, false));
    try std.testing.expect(seen[0] and seen[1]);
    try std.testing.expectEqualStrings(
        "hit.zig:1: anyerror: return type uses anyerror; infer or name the error set\n" ++
            "hit.zig:1: anyerror: count 1 exceeds allowance 0\n" ++
            "under.zig:1: anyerror: count 1 is under allowance 2; lower the allowance to 1\n",
        output.written(),
    );
}
