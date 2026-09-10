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

var cached: ?[]u8 = null;
var attempted = false;

/// Timeout for the shell spawn — a pathological `.zshrc` (network calls, slow prompt themes,
/// …) shouldn't be able to hang this indefinitely.
const timeout_ms = 3000;

/// Returns the resolved login-shell `PATH`, or null if resolution hasn't succeeded (spawn
/// failure, timeout, empty output — including on Windows, where this isn't a problem GUI apps
/// have). Cached after the first call and never retried, so a broken shell config costs at
/// most one multi-hundred-ms shell spawn per process lifetime, not one per lookup. Caller must
/// not free the result — it's owned by this module for the life of the process.
///
/// Spawning a real shell and sourcing the user's full profile is comparatively slow (their
/// `.zshrc` might do real work) — call this lazily, only once nothing faster has already found
/// what you're looking for, same as `Client.zig`'s `resolveExecutable`.
pub fn path(gpa: std.mem.Allocator, io: std.Io) ?[]const u8 {
    if (attempted) return cached;
    attempted = true;
    cached = resolve(gpa, io) catch null;
    return cached;
}

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
