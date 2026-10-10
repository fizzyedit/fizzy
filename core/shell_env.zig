//! Resolves the user's real `PATH` by actually running their login shell — the same technique
//! VSCode (`resolveShellEnv`), Sublime Text, and most macOS GUI dev tools use. A GUI app
//! launched via LaunchServices/launchd never inherits the PATH customizations (Homebrew, nvm,
//! cargo, rustup, zvm, …) that live in the user's shell profile scripts — only a terminal-
//! launched process gets those for free. Rather than guessing at a fixed list of install
//! locations, this asks the shell itself: spawn it in login+interactive mode (so it sources
//! `.zprofile`/`.zshrc`/`.bash_profile`/whatever the user's own setup actually uses) and read
//! back whatever `$PATH` it ends up with.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const darwin_spawn = @import("darwin_spawn.zig");

/// The process's one resolution. Its string lives in `std.heap.page_allocator`, never in an
/// allocator a caller passed: callers come and go (a build's arena, a request's scratch) while
/// the cached slice is handed to every later caller for the life of the process. Core is
/// compiled into each plugin dylib, so each of those has a cache of its own, owned the same way.
var cache: Cache = .{};

/// Timeout for the shell spawn — a pathological `.zshrc` (network calls, slow prompt themes,
/// …) shouldn't be able to hang this indefinitely.
const timeout_ms = 3000;

/// Returns the resolved login-shell `PATH`, or null if resolution hasn't succeeded (spawn
/// failure, timeout, empty output — including on Windows, where this isn't a problem GUI apps
/// have). Cached after the first call and never retried, so a broken shell config costs at
/// most one multi-hundred-ms shell spawn per process lifetime, not one per lookup. Caller must
/// not free the result — it's owned by this module for the life of the process.
///
/// `gpa` is only scratch for the one call that resolves (the spawn, the shell's output), freed
/// before it returns; the cached string never lives in it, so any allocator will do, an arena
/// freed right after included. Safe to call from any thread: callers that arrive while the
/// first resolves wait for its answer rather than spawning a second shell.
///
/// Spawning a real shell and sourcing the user's full profile is comparatively slow (their
/// `.zshrc` might do real work) — call this lazily, only once nothing faster has already found
/// what you're looking for, same as `Client.zig`'s `resolveExecutable`.
pub fn path(gpa: std.mem.Allocator, io: std.Io) ?[]const u8 {
    return cache.get(std.heap.page_allocator, gpa, io, resolve);
}

/// A value resolved once per process, on whichever thread asks first, and kept in `owner`.
const Cache = struct {
    mutex: std.Io.Mutex = .init,
    resolved: std.atomic.Value(bool) = .init(false),
    value: ?[]const u8 = null,

    const ResolveFn = fn (gpa: std.mem.Allocator, io: std.Io) anyerror!?[]u8;

    fn get(
        self: *Cache,
        owner: std.mem.Allocator,
        gpa: std.mem.Allocator,
        io: std.Io,
        comptime resolveFn: ResolveFn,
    ) ?[]const u8 {
        if (self.resolved.load(.acquire)) return self.value;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (!self.resolved.load(.monotonic)) {
            self.value = own(owner, gpa, io, resolveFn);
            self.resolved.store(true, .release);
        }
        return self.value;
    }

    fn own(owner: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, comptime resolveFn: ResolveFn) ?[]const u8 {
        const scratch = (resolveFn(gpa, io) catch return null) orelse return null;
        defer gpa.free(scratch);
        return owner.dupe(u8, scratch) catch null;
    }
};

fn resolve(gpa: std.mem.Allocator, io: std.Io) !?[]u8 {
    if (comptime builtin.os.tag != .macos) return null;

    const shell = if (std.c.getenv("SHELL")) |s| std.mem.span(s) else "/bin/zsh";

    // `darwin_spawn`, not `std.process.spawn` — see its doc comment for the two crashes this
    // sidesteps (fork-safety, and a malformed `environ` specifically after a Velopack
    // installer auto-open). stdin is unused by a `-c` command; stderr is unused here (a noisy
    // `.zshrc` warning shouldn't fail resolution) and discarded straight to `/dev/null` rather
    // than piped, so there's no pipe to drain concurrently with stdout.
    var child = darwin_spawn.spawn(gpa, .{
        .argv = &.{ shell, "-ilc", "echo -n \"$PATH\"" },
        .stdin = .discard,
        .stdout = .pipe,
        .stderr = .discard,
    }, null) catch return null;

    // Kills the shell if it doesn't finish within `timeout_ms`. Only touches the raw pid (an
    // immutable copy, not the shared `child` the main thread is simultaneously reading/waiting
    // on) — `posix.kill` is a plain signal send, safe to call from any thread regardless of how
    // the target was spawned.
    const pid = child.id.?;
    var done: std.atomic.Value(bool) = .init(false);
    const watchdog = std.Thread.spawn(.{}, timeoutWatchdog, .{ pid, io, &done }) catch null;
    defer {
        done.store(true, .release);
        if (watchdog) |t| t.join();
    }

    const stdout = child.stdout.?;
    var buf: [4096]u8 = undefined;
    var rdr = stdout.readerStreaming(io, &buf);
    const result = rdr.interface.allocRemaining(gpa, .unlimited);
    _ = child.wait(io) catch {};

    const stdout_bytes = result catch return null;
    defer gpa.free(stdout_bytes);

    const trimmed = std.mem.trim(u8, stdout_bytes, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try gpa.dupe(u8, trimmed);
}

fn timeoutWatchdog(pid: posix.pid_t, io: std.Io, done: *std.atomic.Value(bool)) void {
    io.sleep(std.Io.Duration.fromMilliseconds(timeout_ms), .awake) catch {};
    if (!done.load(.acquire)) posix.kill(pid, posix.SIG.KILL) catch {};
}

var test_resolutions: std.atomic.Value(u32) = .init(0);

fn testResolve(gpa: std.mem.Allocator, io: std.Io) !?[]u8 {
    _ = io;
    _ = test_resolutions.fetchAdd(1, .monotonic);
    return try gpa.dupe(u8, "/opt/homebrew/bin:/usr/bin");
}

fn testGet(c: *Cache, io: std.Io) void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    _ = c.get(std.testing.allocator, arena.allocator(), io, testResolve);
}

test "the cached value outlives the allocator its first caller passed" {
    const io = std.testing.io;
    test_resolutions.store(0, .monotonic);
    var c: Cache = .{};
    defer if (c.value) |v| std.testing.allocator.free(v);

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    const first = c.get(std.testing.allocator, arena.allocator(), io, testResolve);
    arena.deinit();

    const second = c.get(std.testing.allocator, std.testing.allocator, io, testResolve);
    try std.testing.expectEqualStrings("/opt/homebrew/bin:/usr/bin", second.?);
    try std.testing.expectEqual(first.?.ptr, second.?.ptr);
    try std.testing.expectEqual(1, test_resolutions.load(.monotonic));
}

test "threads asking at once resolve once" {
    const io = std.testing.io;
    test_resolutions.store(0, .monotonic);
    var c: Cache = .{};
    defer if (c.value) |v| std.testing.allocator.free(v);

    var threads: [8]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, testGet, .{ &c, io });
    for (threads) |t| t.join();

    try std.testing.expectEqual(1, test_resolutions.load(.monotonic));
    try std.testing.expectEqualStrings("/opt/homebrew/bin:/usr/bin", c.value.?);
}

test "a failed resolution is cached as null" {
    const io = std.testing.io;
    const fail = struct {
        fn resolve(gpa: std.mem.Allocator, _: std.Io) !?[]u8 {
            _ = gpa;
            _ = test_resolutions.fetchAdd(1, .monotonic);
            return error.SpawnFailed;
        }
    }.resolve;
    test_resolutions.store(0, .monotonic);
    var c: Cache = .{};
    try std.testing.expectEqual(null, c.get(std.testing.allocator, std.testing.allocator, io, fail));
    try std.testing.expectEqual(null, c.get(std.testing.allocator, std.testing.allocator, io, fail));
    try std.testing.expectEqual(1, test_resolutions.load(.monotonic));
}
