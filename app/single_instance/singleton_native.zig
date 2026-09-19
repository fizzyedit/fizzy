//! Single-instance support for fizzy. Wraps `dvui-singleton-app`:
//!
//!   * `acquireLock` is called from `AppInit` before any fizzy globals exist.
//!     If another fizzy process already owns the lock, our argv has been
//!     forwarded to it and we exit(0).
//!   * `registerWindow` captures the dvui window pointer (so the listener
//!     thread can call `dvui.refresh`) and queues any paths from our own
//!     argv.
//!   * `drainPending` is called from the top of each frame to open queued
//!     paths in the editor.
//!
//! Path dispatch: directories → `editor.setProjectFolder`, files → `editor.openFilePath`.

const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const singleton_app = @import("singleton_app");
const core = @import("core");

const log = std.log.scoped(.singleton);

/// The lock every instance of *this* app contends for. It must be the app's own identifier and
/// not fizzy's: two apps built on fizzy would otherwise share one lock, and launching the second
/// would forward its argv to the first and exit.
/// The application's identity, set by the app before `earlyStartup`. The lock is *per
/// application* — two different fizzy-based apps must not fight over one — so this cannot be
/// read from fizzy's own identity the way it used to be.
pub var app_id: [:0]const u8 = "app.unnamed";
pub var app_name: []const u8 = "app";

const PendingOpen = struct { path: []u8 };

const State = struct {
    instance: ?singleton_app.SingletonApp = null,
    /// Captured at `earlyStartup` time; used by the listener thread to
    /// allocate queued path copies before `fizzy.entry()` may exist.
    allocator: std.mem.Allocator = undefined,
    /// Set before dvui/SDL init so secondary instances can exit without
    /// creating a window. Same as `dvui.io` once the backend starts.
    io: std.Io = undefined,
    /// Resolved argv from `earlyStartup`, consumed in `AppInit`.
    resolved_argv: ?[]const []const u8 = null,
    mutex: std.Io.Mutex = .init,
    pending: std.ArrayListUnmanaged(PendingOpen) = .empty,
    window: ?*dvui.Window = null,
};

var state: State = .{};

/// Acquire the lock and forward argv before any window exists. Secondary
/// instances call `exit(0)` here. Primary stashes argv for `consumeStartupArgv`.
pub fn earlyStartup(gpa: std.mem.Allocator, main_init: std.process.Init) !void {
    state.io = main_init.io;
    state.allocator = gpa;
    const resolved = try collectAndResolveArgv(gpa, main_init);
    state.resolved_argv = resolved;
    try acquireLock(gpa, resolved);
}

/// Take ownership of argv resolved in `earlyStartup`. Empty if `earlyStartup`
/// was not called (tests) or argv was already consumed.
pub fn consumeStartupArgv() []const []const u8 {
    const argv = state.resolved_argv orelse return &.{};
    state.resolved_argv = null;
    return argv;
}

/// Acquire the single-instance lock. If we are the secondary instance, the
/// supplied `argv` has been forwarded to the primary and this function
/// calls `std.process.exit(0)`. Caller should pass argv with file paths
/// already resolved to absolute (so the primary doesn't need to know the
/// secondary's working directory).
pub fn acquireLock(gpa: std.mem.Allocator, argv: []const []const u8) !void {
    state.allocator = gpa;

    var socket_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const socket_dir = pickUnixSocketDir(&socket_dir_buf);

    state.instance = try singleton_app.SingletonApp.init(.{
        .app_id = app_id,
        .allocator = gpa,
        .io = state.io,
        .unix_socket_dir = socket_dir,
        .on_second_instance = onSecondInstance,
    });

    switch (try state.instance.?.requestSingleInstanceLock(argv)) {
        .acquired => {},
        .already_running => {
            state.instance.?.deinit();
            state.instance = null;
            std.process.exit(0);
        },
    }
}

/// Hand the dvui window to the listener thread and queue any paths from
/// our own argv so the first frame opens them.
pub fn registerWindow(win: *dvui.Window, argv: []const []const u8) void {
    state.window = win;
    queueArgvPaths(argv);
}

pub fn deinit() void {
    if (state.instance != null) {
        state.instance.?.deinit();
        state.instance = null;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        for (state.pending.items) |item| state.allocator.free(item.path);
        state.pending.deinit(state.allocator);
    }
    if (state.resolved_argv) |argv| {
        freeResolvedArgv(state.allocator, argv);
        state.resolved_argv = null;
    }
    state.window = null;
}

/// Open any paths queued by `onSecondInstance` or `registerWindow`.
pub fn drainPending() void {
    var to_open: []PendingOpen = &.{};
    {
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        if (state.pending.items.len == 0) return;
        to_open = state.pending.toOwnedSlice(state.allocator) catch return;
    }
    defer state.allocator.free(to_open);

    for (to_open) |item| {
        defer state.allocator.free(item.path);
        dispatchPath(item.path) catch |err| {
            log.err("failed to open '{s}': {t}", .{ item.path, err });
        };
    }
}

/// Runs on the singleton listener thread. Just queue and wake the GUI.
fn onSecondInstance(argv: []const []const u8, _: ?*anyopaque) void {
    queueArgvPaths(argv);
    if (state.window) |w| dvui.refresh(w, @src(), null);
}

/// Queue a single absolute path to be opened on the next frame. Safe to
/// call from any thread, including SDL event-watch callbacks. No-ops if
/// the singleton hasn't been initialized yet.
pub fn queuePath(path: []const u8) void {
    if (path.len == 0) return;
    if (state.instance == null) return;
    const dup = state.allocator.dupe(u8, path) catch return;
    {
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        state.pending.append(state.allocator, .{ .path = dup }) catch {
            state.allocator.free(dup);
            return;
        };
    }
    if (state.window) |w| dvui.refresh(w, @src(), null);
}

fn queueArgvPaths(argv: []const []const u8) void {
    if (argv.len < 2) return;
    for (argv[1..]) |arg| {
        if (arg.len == 0) continue;
        // Skip flags so we don't try to open them as files.
        if (arg[0] == '-') continue;
        const path = state.allocator.dupe(u8, arg) catch continue;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        state.pending.append(state.allocator, .{ .path = path }) catch {
            state.allocator.free(path);
        };
    }
}

/// What the application does with a path a second launch forwarded to this one.
///
/// The lock, the socket and the argv plumbing are the same for every app; what "open this" means
/// is not — fizzy sets a project folder for a directory and opens a document for a file, having
/// first walked up for a project marker. An app with no documents can point both of these at
/// something else entirely.
pub const Sink = struct {
    ctx: *anyopaque,
    /// A directory was forwarded.
    openFolder: *const fn (ctx: *anyopaque, path: []const u8) anyerror!void,
    /// A file was forwarded. `project_root` is the marker directory found above it, when the app
    /// asked for that search and one exists.
    openFile: *const fn (ctx: *anyopaque, path: []const u8, project_root: ?[]const u8) anyerror!void,
    /// Whether to search upward for a project marker before opening a file — fizzy only does it
    /// when nothing is open yet.
    wantsProjectRoot: *const fn (ctx: *anyopaque) bool,
};

var sink: ?Sink = null;

/// Called once by the application, before `earlyStartup`.
pub fn setSink(s: Sink) void {
    sink = s;
}

fn dispatchPath(path: []const u8) !void {
    const io = state.io;
    const to = sink orelse return error.NoSink;

    // A path on a mounted filesystem is not the disk's to inspect: the app decides what it
    // is once the mount answers. Handed over as a file — a folder there is opened from the
    // explorer, not from argv.
    if (core.paths.isMountPath(path)) {
        try to.openFile(to.ctx, path, null);
        return;
    }

    // Try as directory first: openDirAbsolute succeeds → it's a folder.
    if (std.Io.Dir.openDirAbsolute(io, path, .{})) |dir| {
        var d = dir;
        d.close(io);
        try to.openFolder(to.ctx, path);
        return;
    } else |_| {}

    // It's a file. Walk up for a `.fizproject` (or `.pixiproject`) marker when the app wants
    // that, so double-clicking any file inside a project loads the project context too.
    var root: ?[]const u8 = null;
    defer if (root) |r| state.allocator.free(r);
    if (to.wantsProjectRoot(to.ctx)) root = findProjectRoot(state.allocator, path);

    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| {
        log.warn("open '{s}' failed: {t}", .{ path, err });
        return err;
    };
    file.close(io);
    try to.openFile(to.ctx, path, root);
}

/// Walk upward from `file_path`'s parent directory, returning the first
/// ancestor that contains a `.fizproject` or `.pixiproject` marker (caller
/// owns the returned slice). Returns null on filesystem root, after a
/// safety-bound depth, or if no marker is found.
fn findProjectRoot(gpa: std.mem.Allocator, file_path: []const u8) ?[]u8 {
    var current = std.fs.path.dirname(file_path) orelse return null;
    var depth: u8 = 0;
    while (depth < 64) : (depth += 1) {
        if (dirHasProjectMarker(gpa, current)) {
            return gpa.dupe(u8, current) catch null;
        }
        const parent = std.fs.path.dirname(current) orelse return null;
        if (parent.len == current.len) return null; // unchanged (hit root)
        current = parent;
    }
    return null;
}

fn dirHasProjectMarker(gpa: std.mem.Allocator, dir: []const u8) bool {
    const names = [_][]const u8{ ".fizproject", ".pixiproject" };
    for (names) |name| {
        const candidate = std.fs.path.join(gpa, &.{ dir, name }) catch continue;
        defer gpa.free(candidate);
        if (std.Io.Dir.accessAbsolute(state.io, candidate, .{ .read = true })) |_| return true else |_| {}
    }
    return false;
}

/// Walk `argv` once via this zig's `Args.Iterator` API and return a slice
/// `[argv[0], abs_path_1, abs_path_2, …]` owned by `gpa`. Flags (entries
/// starting with `-`) pass through unchanged; everything else is resolved
/// to an absolute path so the singleton primary doesn't need to know the
/// secondary's working directory. Resolution failures pass the original
/// string through with a warning.
pub fn collectAndResolveArgv(
    gpa: std.mem.Allocator,
    main_init_opt: ?std.process.Init,
) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |s| gpa.free(s);
        out.deinit(gpa);
    }

    const main_init = main_init_opt orelse {
        const exe = try gpa.dupe(u8, app_name);
        try out.append(gpa, exe);
        return out.toOwnedSlice(gpa);
    };

    var iter = try std.process.Args.Iterator.initAllocator(main_init.minimal.args, gpa);
    defer iter.deinit();

    // Capture cwd up-front so relative paths can be resolved before fizzy
    // chdirs to the exe directory.
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(main_init.io, &cwd_buf) catch 0;
    const cwd: []const u8 = if (cwd_len > 0) cwd_buf[0..cwd_len] else &.{};

    var first = true;
    while (iter.next()) |arg| {
        if (first) {
            first = false;
            try out.append(gpa, try gpa.dupe(u8, arg));
            continue;
        }
        if (arg.len == 0 or arg[0] == '-') {
            try out.append(gpa, try gpa.dupe(u8, arg));
            continue;
        }
        const abs = resolveAbsolute(gpa, cwd, arg) catch |err| {
            log.warn("could not resolve '{s}': {t}; passing through", .{ arg, err });
            try out.append(gpa, try gpa.dupe(u8, arg));
            continue;
        };
        try out.append(gpa, abs);
    }
    return out.toOwnedSlice(gpa);
}

pub fn freeResolvedArgv(gpa: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |s| gpa.free(s);
    gpa.free(argv);
}

/// Normalizing (not just joining) matters for the common `fizzy .` invocation: a plain join
/// yields `<cwd>/.`, which names the right directory but is a distinct string from `<cwd>`
/// everywhere downstream — see `core.paths.normalize`.
fn resolveAbsolute(gpa: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path) or core.paths.isMountPath(path)) return core.paths.normalize(gpa, path);
    if (cwd.len == 0) return error.NoCwd;
    return core.paths.normalizeJoin(gpa, cwd, path);
}

fn pickUnixSocketDir(buf: *[std.fs.max_path_bytes]u8) []const u8 {
    if (builtin.os.tag == .windows) return "."; // unused on Windows
    // Prefer TMPDIR (macOS sets it per-user) → /tmp fallback.
    // Use the libc env to avoid plumbing `process.Environ` here.
    if (std.c.getenv("TMPDIR")) |env_ptr| {
        const len = std.mem.len(env_ptr);
        if (len > 0 and len < buf.len) {
            @memcpy(buf[0..len], env_ptr[0..len]);
            return buf[0..len];
        }
    }
    if (builtin.os.tag == .linux) {
        if (std.c.getenv("XDG_RUNTIME_DIR")) |env_ptr| {
            const len = std.mem.len(env_ptr);
            if (len > 0 and len < buf.len) {
                @memcpy(buf[0..len], env_ptr[0..len]);
                return buf[0..len];
            }
        }
    }
    return "/tmp";
}
