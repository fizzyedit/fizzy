//! `zig build check-tests-reached`: every `test` block in the repo is compiled into some test
//! binary that `zig build test` or `zig build test-integration` runs.
//!
//! `addTest` collects tests only from files its root module analyzes: a file no root reaches by
//! relative `@import`, or one reached only through a `pub const x = @import(…)` nothing uses, has
//! tests that compile nowhere, and a green run says nothing about them. Rather than guess at
//! that from the imports, this reads the binaries. Each holds the name of every test it runs as
//! `<file>.test.<name>` (`<file>.decltest.<decl>` for `test decl {}`), `<file>` being the path
//! from the root module's directory with `/` as `.` and no `.zig`.
//!
//! Usage: tests_reached <repo root> (<root source file> <test binary>)...
//! Exits 1, naming each file and test, when any test is in no binary.
const std = @import("std");

/// Never scanned: other people's code, build output, experiments outside the build.
const skip_dirs = [_][]const u8{ "zig-pkg", "zig-out", "zig-cache", "spikes", "examples", "node_modules" };

const Binary = struct {
    /// The root module's directory, with a trailing separator.
    root_dir: []const u8,
    bytes: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2 or (args.len - 2) % 2 != 0) {
        std.debug.print("usage: tests_reached <repo root> (<root source file> <test binary>)...\n", .{});
        std.process.exit(2);
    }
    // Real paths, so the repo and a path dependency's sources (`sdk/`, `backend/`) compare as
    // prefixes however the build spelled them.
    const cwd = std.Io.Dir.cwd();
    const repo = try cwd.realPathFileAlloc(io, args[1], arena);

    var binaries: std.ArrayList(Binary) = .empty;
    var i: usize = 2;
    while (i < args.len) : (i += 2) {
        const root = try cwd.realPathFileAlloc(io, args[i], arena);
        const dir = std.fs.path.dirname(root) orelse ".";
        try binaries.append(arena, .{
            .root_dir = try std.fmt.allocPrint(arena, "{s}{c}", .{ dir, std.fs.path.sep }),
            .bytes = try cwd.readFileAlloc(io, args[i + 1], arena, .unlimited),
        });
    }

    var repo_dir = try cwd.openDir(io, repo, .{ .iterate = true });
    defer repo_dir.close(io);
    var walker = try repo_dir.walkSelectively(arena);
    defer walker.deinit();

    var files: usize = 0;
    var tests: usize = 0;
    var missing: usize = 0;
    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                if (entry.basename[0] == '.') continue;
                for (skip_dirs) |s| {
                    if (std.mem.eql(u8, entry.basename, s)) break;
                } else try walker.enter(io, entry);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
                const rel = try arena.dupe(u8, entry.path);
                const abs = try std.fs.path.join(arena, &.{ repo, rel });
                const source = try entry.dir.readFileAlloc(io, entry.basename, arena, .unlimited);
                var file_tests: usize = 0;
                var lines = std.mem.splitScalar(u8, source, '\n');
                while (lines.next()) |line| {
                    const name = testName(arena, line) orelse continue;
                    file_tests += 1;
                    if (reached(arena, binaries.items, abs, name)) continue;
                    if (missing == 0) std.debug.print("Tests no test binary compiles (none of `zig build test` / `test-integration` reaches the file):\n", .{});
                    std.debug.print("  {s}: {s} \"{s}\"\n", .{ rel, name.kind, name.name });
                    missing += 1;
                }
                if (file_tests > 0) files += 1;
                tests += file_tests;
            },
            else => {},
        }
    }

    if (missing > 0) {
        std.debug.print(
            \\{d} of {d} tests are never run. Give the file a root of its own in `build/app.zig`, or
            \\make a file that is already tested reach it: `test {{ _ = @import("x.zig"); }}`.
            \\
        , .{ missing, tests });
        std.process.exit(1);
    }
    std.debug.print("all {d} tests in {d} files are compiled into a test binary\n", .{ tests, files });
}

const TestName = struct {
    /// `test` for `test "name"`, `decltest` for `test decl`.
    kind: []const u8,
    name: []const u8,
};

/// The name of the top-level `test` declared on `line`, or null if none is. A bare `test {}` has
/// no name in the binary and is not counted; it only pulls other files in.
fn testName(arena: std.mem.Allocator, line: []const u8) ?TestName {
    if (!std.mem.startsWith(u8, line, "test ")) return null;
    const rest = std.mem.trimStart(u8, line["test ".len..], " ");
    if (rest.len > 0 and rest[0] == '"') {
        var end: usize = 1;
        while (end < rest.len and rest[end] != '"') : (end += 1) {
            if (rest[end] == '\\') end += 1;
        }
        if (end >= rest.len) return null;
        const name = std.zig.string_literal.parseAlloc(arena, rest[0 .. end + 1]) catch return null;
        return .{ .kind = "test", .name = name };
    }
    var end: usize = 0;
    while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_')) : (end += 1) {}
    if (end == 0) return null;
    return .{ .kind = "decltest", .name = rest[0..end] };
}

/// Whether a binary whose root module holds `file` names this test.
fn reached(arena: std.mem.Allocator, binaries: []const Binary, file: []const u8, t: TestName) bool {
    for (binaries) |b| {
        if (!std.mem.startsWith(u8, file, b.root_dir)) continue;
        const rel = file[b.root_dir.len .. file.len - ".zig".len];
        const fqn = std.mem.replaceOwned(u8, arena, rel, std.fs.path.sep_str, ".") catch return false;
        const want = std.fmt.allocPrint(arena, "{s}.{s}.{s}", .{ fqn, t.kind, t.name }) catch return false;
        if (std.mem.indexOf(u8, b.bytes, want) != null) return true;
    }
    return false;
}
