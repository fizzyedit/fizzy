//! The running app bundle as macOS sees it, and the move into /Applications.
//!
//! Gatekeeper's App Translocation is asked through `SecTranslocate*` in Security.framework, the
//! Trash through `NSFileManager`; both are looked up with `dlsym` at the call, so nothing links
//! a framework for them and every other target compiles none of it. The rules (where a bundle
//! sits, what to do with the copy it leaves) are `install_location.zig`'s; this file only asks
//! the system and acts.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const install_location = @import("install_location.zig");

pub const supported = builtin.target.os.tag == .macos;

/// A path's room. 0 off macOS, where there is no bundle and a browser has no `PATH_MAX`.
pub const max_path = if (supported) std.fs.max_path_bytes else 0;

/// The bundle this process runs from.
pub const Bundle = struct {
    path_buf: [max_path]u8 = undefined,
    path_len: usize = 0,
    /// Where the bundle was before Gatekeeper translocated it; the same as `path` when it was not.
    original_buf: [max_path]u8 = undefined,
    original_len: usize = 0,
    place: install_location.Place,
    /// `original`'s place: where the user put the bundle.
    original_place: install_location.Place,

    /// Valid as long as the `Bundle`.
    pub fn path(self: *const Bundle) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    /// Valid as long as the `Bundle`.
    pub fn original(self: *const Bundle) []const u8 {
        return self.original_buf[0..self.original_len];
    }
};

/// Guards `cached`, which the first `current` fills from whichever thread asks first.
var cache_lock: std.Io.Mutex = .init;
var cached: ?Bundle = null;
var cache_done: bool = false;

/// The bundle this process runs from, or null for a loose executable and on every other target.
/// Asked of the system once; the answer holds for the process's life and the pointer with it.
pub fn current(io: std.Io) ?*const Bundle {
    if (comptime !supported) return null;
    cache_lock.lockUncancelable(io);
    defer cache_lock.unlock(io);
    if (!cache_done) {
        cached = ask(io);
        cache_done = true;
    }
    return if (cached) |*b| b else null;
}

fn ask(io: std.Io) ?Bundle {
    var exe_buf: [max_path]u8 = undefined;
    const n = std.process.executablePath(io, &exe_buf) catch return null;
    const bundle_path = install_location.bundlePath(exe_buf[0..n]) orelse return null;

    var b: Bundle = .{ .place = .elsewhere, .original_place = .elsewhere };
    @memcpy(b.path_buf[0..bundle_path.len], bundle_path);
    b.path_len = bundle_path.len;

    const home: ?[]const u8 = if (std.c.getenv("HOME")) |h| std.mem.span(h) else null;
    const translocated = isTranslocated(b.path());
    b.place = install_location.classify(b.path(), home, translocated);

    const orig = if (b.place == .translocated) originalPath(b.path(), &b.original_buf) else null;
    if (orig) |o| {
        b.original_len = o.len;
    } else {
        @memcpy(b.original_buf[0..b.path_len], b.path());
        b.original_len = b.path_len;
    }
    b.original_place = install_location.classify(b.original(), home, false);
    return b;
}

pub const MoveError = error{
    /// A path the move needs is too long.
    NameTooLong,
    /// The copy did not finish; the bundle is still only where it was, and an older copy in
    /// /Applications is still in place.
    CopyFailed,
    /// The user dismissed the administrator prompt.
    Cancelled,
} || core.darwin_spawn.SpawnError;

/// Put `bundle` where it can update and return the path to open, in `dest_buf`. Blocks until
/// done; run it off the GUI thread.
///
/// A translocated bundle the user already put in an Applications folder only loses its quarantine
/// flag, so Gatekeeper runs it from there. Any other is copied to `/Applications/<its name>.app`,
/// signature and all: into a staging name first, so a copy that fails leaves the folder as it
/// was, then over an older copy, which goes to the Trash. An administrator's password is asked
/// for only when the user cannot do that themselves. Then a copy left in Downloads goes to the
/// Trash (`install_location.leftover`).
pub fn moveToApplications(gpa: std.mem.Allocator, io: std.Io, bundle: *const Bundle, dest_buf: []u8) MoveError![]const u8 {
    if (comptime !supported) return error.CopyFailed;
    if (install_location.updatable(bundle.original_place)) {
        if (!try run(gpa, io, &.{ "/usr/bin/xattr", "-d", "-r", "com.apple.quarantine", bundle.original() })) return error.CopyFailed;
        if (bundle.original().len > dest_buf.len) return error.NameTooLong;
        @memcpy(dest_buf[0..bundle.original().len], bundle.original());
        return dest_buf[0..bundle.original().len];
    }

    const dest = install_location.destination(dest_buf, bundle.path()) catch return error.NameTooLong;
    var dest_z_buf: [max_path]u8 = undefined;
    const dest_z = std.mem.printSentinel(&dest_z_buf, "{s}", .{dest}, 0) catch return error.NameTooLong;
    var staging_buf: [max_path]u8 = undefined;
    const staging = std.mem.printSentinel(&staging_buf, "/Applications/.{s}.moving", .{std.fs.path.basename(dest)}, 0) catch return error.NameTooLong;

    if (!try copyAsUser(gpa, io, bundle.path(), dest_z, staging)) try copyAsAdmin(gpa, io, bundle.path(), dest_z, staging);
    if (std.c.access(dest_z.ptr, std.c.F_OK) != 0) return error.CopyFailed;

    if (install_location.leftover(bundle.original_place) == .trash) {
        var orig_z_buf: [max_path]u8 = undefined;
        if (std.mem.printSentinel(&orig_z_buf, "{s}", .{bundle.original()}, 0)) |orig_z| {
            if (!trash(orig_z)) std.log.warn("move to Applications: {s} could not go to the Trash", .{orig_z});
        } else |_| {}
    }
    return dest;
}

/// The copy into `dest` by way of `staging`, as the user. False when the user cannot write there
/// or cannot move the older copy aside; nothing in /Applications has changed then. Errors only
/// for a copy that failed on its own.
fn copyAsUser(gpa: std.mem.Allocator, io: std.Io, src: []const u8, dest: [:0]const u8, staging: [:0]const u8) MoveError!bool {
    if (std.c.access("/Applications", std.c.W_OK) != 0) return false;
    // A staging copy is only ever this move's own, half made by one that stopped.
    _ = try run(gpa, io, &.{ "/bin/rm", "-rf", staging });
    // `ditto` keeps what a bundle's signature covers: extended attributes, resource forks,
    // symlinks inside frameworks.
    if (!try run(gpa, io, &.{ "/usr/bin/ditto", src, staging })) {
        _ = try run(gpa, io, &.{ "/bin/rm", "-rf", staging });
        return error.CopyFailed;
    }
    // A quarantined copy launched from its new place would be translocated again.
    _ = try run(gpa, io, &.{ "/usr/bin/xattr", "-d", "-r", "com.apple.quarantine", staging });
    if (std.c.access(dest.ptr, std.c.F_OK) == 0 and !trash(dest)) {
        _ = try run(gpa, io, &.{ "/bin/rm", "-rf", staging });
        return false;
    }
    if (std.c.rename(staging.ptr, dest.ptr) != 0) {
        _ = try run(gpa, io, &.{ "/bin/rm", "-rf", staging });
        return error.CopyFailed;
    }
    return true;
}

/// The same copy under the administrator prompt. The older copy is moved into the user's Trash
/// folder rather than deleted, so it can still be taken back.
fn copyAsAdmin(gpa: std.mem.Allocator, io: std.Io, src: []const u8, dest: [:0]const u8, staging: [:0]const u8) MoveError!void {
    const home = std.mem.span(std.c.getenv("HOME") orelse return error.CopyFailed);
    var old_buf: [max_path]u8 = undefined;
    const name = std.fs.path.stem(dest);
    const old = std.mem.print(&old_buf, "{s}/.Trash/{s} {d}.app", .{ home, name, std.c.getpid() }) catch return error.NameTooLong;
    // The paths are the script's arguments, quoted by AppleScript itself, so no path is ever read
    // as shell. Dismissing the prompt (-128) is an answer, not a failure: it says so.
    const script =
        \\on run argv
        \\  set src to quoted form of item 1 of argv
        \\  set dst to quoted form of item 2 of argv
        \\  set tmp to quoted form of item 3 of argv
        \\  set old to quoted form of item 4 of argv
        \\  try
        \\    do shell script "/bin/rm -rf " & tmp & " && /usr/bin/ditto " & src & " " & tmp & " && (/usr/bin/xattr -d -r com.apple.quarantine " & tmp & " || true) && (if [ -e " & dst & " ]; then /bin/mv " & dst & " " & old & "; fi) && /bin/mv " & tmp & " " & dst & " || (/bin/rm -rf " & tmp & "; false)" with administrator privileges
        \\  on error message number code
        \\    if code is -128 then return "cancelled"
        \\    error message number code
        \\  end try
        \\end run
    ;
    var out_buf: [64]u8 = undefined;
    const out = try runOutput(gpa, io, &.{ "/usr/bin/osascript", "-e", script, src, dest, staging, old }, &out_buf) orelse return error.CopyFailed;
    if (std.mem.startsWith(u8, out, "cancelled")) return error.Cancelled;
}

/// Open the bundle at `path` once this process has exited, so the new instance takes the
/// single-instance lock rather than handing its launch to this one. The waiter is a process of
/// its own; call it as the app quits.
pub fn openAfterExit(gpa: std.mem.Allocator, path: []const u8) core.darwin_spawn.SpawnError!void {
    if (comptime !supported) return;
    var pid_buf: [16]u8 = undefined;
    // 16 bytes hold any pid_t, which is 32 bits.
    const pid = std.mem.print(&pid_buf, "{d}", .{std.c.getpid()}) catch unreachable;
    const wait_then_open = "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"";
    _ = try core.darwin_spawn.spawn(gpa, .{
        .argv = &.{ "/bin/sh", "-c", wait_then_open, "sh", pid, path },
        .stdin = .discard,
        .stdout = .discard,
        .stderr = .discard,
        .new_session = true,
    }, null);
}

/// Run `argv` to its end. True when it exited 0.
fn run(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) core.darwin_spawn.SpawnError!bool {
    var child = try core.darwin_spawn.spawn(gpa, .{ .argv = argv, .stdin = .discard, .stdout = .discard, .stderr = .discard }, null);
    const term = child.wait(io) catch return false;
    return term.success();
}

/// Run `argv` to its end. The start of what it printed, in `buf`, when it exited 0; else null.
fn runOutput(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, buf: []u8) core.darwin_spawn.SpawnError!?[]const u8 {
    var child = try core.darwin_spawn.spawn(gpa, .{ .argv = argv, .stdin = .discard, .stdout = .pipe, .stderr = .discard }, null);
    var read_buf: [256]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &read_buf);
    // Read to the end, so the child never blocks on a full pipe; only the start is kept.
    var len: usize = 0;
    while (true) {
        const n = reader.interface.readSliceShort(buf[len..]) catch break;
        len += n;
        if (n == 0 or len == buf.len) {
            _ = reader.interface.discardRemaining() catch {};
            break;
        }
    }
    const term = child.wait(io) catch return null;
    return if (term.success()) buf[0..len] else null;
}

/// Whether Gatekeeper runs `path` from a translocated mount. False when Security.framework
/// cannot be asked; `install_location.classify` then falls back on the mount's name.
fn isTranslocated(path: []const u8) bool {
    const sec = Security.load() orelse return false;
    const url = sec.urlFromPath(path) orelse return false;
    defer sec.release(url);
    var translocated = false;
    if (sec.isTranslocatedUrl(url, &translocated, null) == 0) return false;
    return translocated;
}

/// The path a translocated `path` was opened from, in `buf`. Null when it cannot be told.
fn originalPath(path: []const u8, buf: []u8) ?[]const u8 {
    const sec = Security.load() orelse return null;
    const url = sec.urlFromPath(path) orelse return null;
    defer sec.release(url);
    const orig = sec.createOriginalPathForUrl(url, null) orelse return null;
    defer sec.release(orig);
    if (sec.urlGetFileSystemRepresentation(orig, 1, buf.ptr, @intCast(buf.len)) == 0) return null;
    return std.mem.sliceTo(buf, 0);
}

/// Security.framework's translocation calls, and the CoreFoundation ones their URLs need.
const Security = struct {
    const CfUrl = *anyopaque;

    urlCreateFromFileSystemRepresentation: *const fn (?*anyopaque, [*]const u8, isize, u8) callconv(.c) ?CfUrl,
    urlGetFileSystemRepresentation: *const fn (CfUrl, u8, [*]u8, isize) callconv(.c) u8,
    release: *const fn (*anyopaque) callconv(.c) void,
    isTranslocatedUrl: *const fn (CfUrl, *bool, ?*?*anyopaque) callconv(.c) u8,
    createOriginalPathForUrl: *const fn (CfUrl, ?*?*anyopaque) callconv(.c) ?CfUrl,

    fn load() ?Security {
        const cf = std.c.dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", .{ .LAZY = true }) orelse return null;
        const sec = std.c.dlopen("/System/Library/Frameworks/Security.framework/Security", .{ .LAZY = true }) orelse return null;
        return .{
            .urlCreateFromFileSystemRepresentation = @ptrCast(@alignCast(std.c.dlsym(cf, "CFURLCreateFromFileSystemRepresentation") orelse return null)),
            .urlGetFileSystemRepresentation = @ptrCast(@alignCast(std.c.dlsym(cf, "CFURLGetFileSystemRepresentation") orelse return null)),
            .release = @ptrCast(@alignCast(std.c.dlsym(cf, "CFRelease") orelse return null)),
            .isTranslocatedUrl = @ptrCast(@alignCast(std.c.dlsym(sec, "SecTranslocateIsTranslocatedURL") orelse return null)),
            .createOriginalPathForUrl = @ptrCast(@alignCast(std.c.dlsym(sec, "SecTranslocateCreateOriginalPathForURL") orelse return null)),
        };
    }

    /// A CFURL the caller releases.
    fn urlFromPath(self: Security, path: []const u8) ?CfUrl {
        return self.urlCreateFromFileSystemRepresentation(null, path.ptr, @intCast(path.len), 1);
    }
};

/// Move `path` to the Trash, as Finder does, so the user can put it back. False when it could not.
fn trash(path: [:0]const u8) bool {
    const objc = Objc.load() orelse return false;
    const pool = objc.poolPush();
    defer objc.poolPop(pool);

    const ns_string = objc.getClass("NSString") orelse return false;
    const ns_url = objc.getClass("NSURL") orelse return false;
    const file_manager = objc.getClass("NSFileManager") orelse return false;

    const SendPtr = *const fn (*anyopaque, *anyopaque, ?*const anyopaque) callconv(.c) ?*anyopaque;
    const Send = *const fn (*anyopaque, *anyopaque) callconv(.c) ?*anyopaque;
    const SendTrash = *const fn (*anyopaque, *anyopaque, *anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) u8;
    const send_ptr: SendPtr = @ptrCast(@alignCast(objc.msgSend));
    const send: Send = @ptrCast(@alignCast(objc.msgSend));
    const send_trash: SendTrash = @ptrCast(@alignCast(objc.msgSend));

    const str = send_ptr(ns_string, objc.sel("stringWithUTF8String:"), path.ptr) orelse return false;
    const url = send_ptr(ns_url, objc.sel("fileURLWithPath:"), str) orelse return false;
    const manager = send(file_manager, objc.sel("defaultManager")) orelse return false;
    return send_trash(manager, objc.sel("trashItemAtURL:resultingItemURL:error:"), url, null, null) != 0;
}

/// The Objective-C runtime's C entry points. `msgSend` is cast to each call's own signature at
/// the call, as the runtime requires.
const Objc = struct {
    getClass: *const fn ([*:0]const u8) callconv(.c) ?*anyopaque,
    sel: *const fn ([*:0]const u8) callconv(.c) *anyopaque,
    msgSend: *const anyopaque,
    poolPush: *const fn () callconv(.c) ?*anyopaque,
    poolPop: *const fn (?*anyopaque) callconv(.c) void,

    fn load() ?Objc {
        const lib = std.c.dlopen("/usr/lib/libobjc.A.dylib", .{ .LAZY = true }) orelse return null;
        return .{
            .getClass = @ptrCast(@alignCast(std.c.dlsym(lib, "objc_getClass") orelse return null)),
            .sel = @ptrCast(@alignCast(std.c.dlsym(lib, "sel_registerName") orelse return null)),
            .msgSend = std.c.dlsym(lib, "objc_msgSend") orelse return null,
            .poolPush = @ptrCast(@alignCast(std.c.dlsym(lib, "objc_autoreleasePoolPush") orelse return null)),
            .poolPop = @ptrCast(@alignCast(std.c.dlsym(lib, "objc_autoreleasePoolPop") orelse return null)),
        };
    }
};
