//! Spawns a child process on Darwin via `posix_spawn` directly, bypassing
//! `std.process.spawn`/`std.Io.Threaded.processSpawnPosix` entirely. Two independent problems
//! with that path turned up on this exact packaged binary:
//!
//!   1. It always forks (`fork()`), which is unsafe from any thread but the main one in a
//!      multithreaded Cocoa/Metal process — if some other thread holds a lock inside a
//!      non-fork-safe system framework (IOKit/Metal/libdispatch/the Obj-C runtime) at the
//!      instant of `fork()`, that lock is stuck forever in the forked child, and the next
//!      thing the child touches that needs it crashes or hangs. `posix_spawn` doesn't
//!      duplicate the caller's address space or thread state at all, so this hazard class
//!      doesn't apply regardless of which thread calls it.
//!   2. Every `std.process.spawn`/`.run` call walks the `environ` array *as captured at
//!      startup* — `std.start` records `envp` plus its length once, and `Environ`'s block
//!      builders then index that slice up to the recorded length. But libc's `unsetenv`
//!      shrinks the live array **in place**: entries shift down and the array gets a NULL
//!      one slot earlier, while the captured length stays put. So a single `unsetenv`
//!      anywhere in the process — SDL, a plugin dylib, a system framework — leaves the
//!      captured slice with a NULL before its end, and the *next* spawn from anywhere
//!      unwraps it and segfaults the whole app. (Reproduced standalone: capture at startup,
//!      `unsetenv` one inherited variable, `std.process.run` → SIGSEGV in
//!      `Environ.createPosixBlock`.) There is no public option on `std.process.spawn`/`.run`
//!      to skip that walk. This implementation never reads the `environ` array at all — the
//!      child's environment is built from individual `getenv()` lookups for a known set of
//!      keys, which is unaffected by the in-place shuffle.
//!
//! Returns a normal `std.process.Child` — its `wait`/`kill` are plain POSIX
//! `waitpid`/`kill` calls with no dependency on how the child was spawned, so callers use it
//! exactly like one from `std.process.spawn` (reader threads, `wait`, `kill`, …).
const std = @import("std");
const posix = std.posix;
const c = std.c;

pub const SpawnError = error{ SpawnFailed, OutOfMemory };

pub const StdIo = enum {
    /// A pipe is created; the corresponding `Child` field is populated.
    pipe,
    /// Redirected to `/dev/null` (read-only for stdin, write-only for stdout/stderr); the
    /// corresponding `Child` field stays null.
    discard,
};

pub const Options = struct {
    argv: []const []const u8,
    /// `chdir`'d to in the child before exec, via `posix_spawn_file_actions_addchdir_np`.
    /// Silently ignored (falls back to inheriting this process's cwd) if longer than
    /// `std.fs.max_path_bytes`.
    cwd: ?[]const u8 = null,
    stdin: StdIo = .pipe,
    stdout: StdIo = .pipe,
    stderr: StdIo = .pipe,
};

/// Environment variables forwarded to the child, looked up individually via `getenv()` rather
/// than by walking this process's `environ` array — see file doc comment.
const forwarded_env_keys = [_][:0]const u8{
    "HOME",  "USER",   "LOGNAME", "SHELL",
    "LANG",  "LC_ALL", "TERM",    "TMPDIR",
    "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME",
};

/// `path_override`, if given, replaces this process's own `$PATH` in the child's environment
/// (e.g. the fuller login-shell-resolved one from `shell_env.path`).
pub fn spawn(gpa: std.mem.Allocator, opts: Options, path_override: ?[]const u8) SpawnError!std.process.Child {
    const argv_z = buildArgv(gpa, opts.argv) catch return error.OutOfMemory;
    defer {
        for (argv_z) |a| if (a) |p| gpa.free(std.mem.span(p));
        gpa.free(argv_z);
    }
    const envp_z = buildEnvp(gpa, path_override) catch return error.OutOfMemory;
    defer {
        for (envp_z) |e| if (e) |p| gpa.free(std.mem.span(p));
        gpa.free(envp_z);
    }

    var actions: c.posix_spawn_file_actions_t = undefined;
    if (c.posix_spawn_file_actions_init(&actions) != 0) return error.SpawnFailed;
    defer _ = c.posix_spawn_file_actions_destroy(&actions);

    var stdin_pipe: ?[2]posix.fd_t = null;
    errdefer if (stdin_pipe) |p| closePipe(p);
    var stdout_pipe: ?[2]posix.fd_t = null;
    errdefer if (stdout_pipe) |p| closePipe(p);
    var stderr_pipe: ?[2]posix.fd_t = null;
    errdefer if (stderr_pipe) |p| closePipe(p);

    stdin_pipe = try setUpChildStream(&actions, opts.stdin, posix.STDIN_FILENO, .read_only);
    stdout_pipe = try setUpChildStream(&actions, opts.stdout, posix.STDOUT_FILENO, .write_only);
    stderr_pipe = try setUpChildStream(&actions, opts.stderr, posix.STDERR_FILENO, .write_only);

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (opts.cwd) |cwd| {
        if (cwd.len < cwd_buf.len) {
            @memcpy(cwd_buf[0..cwd.len], cwd);
            cwd_buf[cwd.len] = 0;
            _ = c.posix_spawn_file_actions_addchdir_np(&actions, cwd_buf[0..cwd.len :0].ptr);
        }
    }

    var pid: posix.pid_t = undefined;
    const rc = c.posix_spawn(&pid, argv_z[0].?, &actions, null, argv_z.ptr, envp_z.ptr);

    // Parent closes the child-side end of every pipe it created, regardless of outcome.
    if (stdin_pipe) |p| closeFd(p[0]);
    if (stdout_pipe) |p| closeFd(p[1]);
    if (stderr_pipe) |p| closeFd(p[1]);

    if (rc != 0) {
        if (stdin_pipe) |p| closeFd(p[1]);
        if (stdout_pipe) |p| closeFd(p[0]);
        if (stderr_pipe) |p| closeFd(p[0]);
        return error.SpawnFailed;
    }

    return .{
        .id = pid,
        .thread_handle = {},
        .stdin = if (stdin_pipe) |p| .{ .handle = p[1], .flags = .{ .nonblocking = false } } else null,
        .stdout = if (stdout_pipe) |p| .{ .handle = p[0], .flags = .{ .nonblocking = false } } else null,
        .stderr = if (stderr_pipe) |p| .{ .handle = p[0], .flags = .{ .nonblocking = false } } else null,
        .request_resource_usage_statistics = false,
    };
}

const OpenMode = enum { read_only, write_only };

/// Wires up one of the child's std streams in `actions`: a real pipe, or `/dev/null`. Returns
/// the pipe fds (parent frees/closes them) when `mode == .pipe`, else null.
fn setUpChildStream(actions: *c.posix_spawn_file_actions_t, mode: StdIo, fd: posix.fd_t, open_mode: OpenMode) SpawnError!?[2]posix.fd_t {
    switch (mode) {
        .discard => {
            const o: std.c.O = switch (open_mode) {
                .read_only => .{ .ACCMODE = .RDONLY },
                .write_only => .{ .ACCMODE = .WRONLY },
            };
            const oflag: c_int = @bitCast(o);
            _ = c.posix_spawn_file_actions_addopen(actions, fd, "/dev/null", oflag, 0);
            return null;
        },
        .pipe => {
            var pipe_fds: [2]posix.fd_t = undefined;
            if (c.pipe(&pipe_fds) != 0) return error.SpawnFailed;
            const child_end = if (open_mode == .read_only) pipe_fds[0] else pipe_fds[1];
            _ = c.posix_spawn_file_actions_adddup2(actions, child_end, fd);
            _ = c.posix_spawn_file_actions_addclose(actions, pipe_fds[0]);
            _ = c.posix_spawn_file_actions_addclose(actions, pipe_fds[1]);
            return pipe_fds;
        },
    }
}

fn closePipe(fds: [2]posix.fd_t) void {
    closeFd(fds[0]);
    closeFd(fds[1]);
}

fn closeFd(fd: posix.fd_t) void {
    _ = std.c.close(fd);
}

fn buildArgv(gpa: std.mem.Allocator, items: []const []const u8) ![:null]?[*:0]const u8 {
    const argv = try gpa.allocSentinel(?[*:0]const u8, items.len, null);
    var built: usize = 0;
    errdefer {
        for (argv[0..built]) |a| if (a) |p| gpa.free(std.mem.span(p));
        gpa.free(argv);
    }
    for (items, 0..) |item, i| {
        argv[i] = (try gpa.dupeZ(u8, item)).ptr;
        built = i + 1;
    }
    return argv;
}

fn buildEnvp(gpa: std.mem.Allocator, path_override: ?[]const u8) ![:null]?[*:0]const u8 {
    var tmp: [forwarded_env_keys.len + 1]?[*:0]const u8 = undefined;
    var n: usize = 0;
    errdefer for (tmp[0..n]) |e| if (e) |p| gpa.free(std.mem.span(p));

    for (forwarded_env_keys) |key| {
        const value = c.getenv(key) orelse continue;
        tmp[n] = (try std.fmt.allocPrintSentinel(gpa, "{s}={s}", .{ key, std.mem.span(value) }, 0)).ptr;
        n += 1;
    }
    const path_value = path_override orelse if (c.getenv("PATH")) |p| std.mem.span(p) else null;
    if (path_value) |p| {
        tmp[n] = (try std.fmt.allocPrintSentinel(gpa, "PATH={s}", .{p}, 0)).ptr;
        n += 1;
    }

    const envp = try gpa.allocSentinel(?[*:0]const u8, n, null);
    @memcpy(envp, tmp[0..n]);
    return envp;
}
