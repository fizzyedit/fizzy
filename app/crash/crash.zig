//! Crash reports: when the app panics or faults, a report saying whose code it was.
//!
//! Every image the app runs code from is in a fixed table of modules: the executable (with the
//! plugins linked into it) from `init`, and each plugin dylib from its load to its unload. A
//! crash walks the stack, and each frame becomes a module and an offset into it; the innermost
//! frame in a known module names who crashed. The report goes to stderr and to a file in
//! `<config>/crashes/`, named when the run starts, so writing it allocates nothing and opens one
//! file.
//!
//! What reaches it:
//! - a panic in the app's own code (`panic`, the root file's panic handler);
//! - a fault anywhere in the process (`handleSegfault`, std's segfault handler, which the app
//!   switches on in every build mode): SIGSEGV, SIGBUS, SIGILL, SIGFPE, or an access violation;
//! - an abort or trap anywhere (SIGABRT, SIGTRAP; POSIX only). A plugin's panic lands here: its
//!   dylib has its own std, whose panic handler prints the message and aborts. The message then
//!   reaches stderr but not the report; carrying it is the dylib entry's `panic` forwarding to
//!   the host's `panic` through an exported symbol, a follow-up.
//!
//! After the report, each hands on to what would have run without it: std's own handler, which
//! prints the symbolized stack trace, or the signal's default action.
//!
//! Std-only, so its tests run on their own (`fizzy-crash-tests`).
const std = @import("std");
const builtin = @import("builtin");
pub const image = @import("image.zig");

/// Where crash reports can be written: native targets std can catch faults on.
pub const supported = builtin.cpu.arch != .wasm32 and std.debug.have_segfault_handling_support;

pub const Module = struct {
    name_buf: [32]u8 = undefined,
    name_len: u8 = 0,
    version_buf: [24]u8 = undefined,
    version_len: u8 = 0,
    image: image.Image,

    pub fn init(name_: []const u8, version_: []const u8, img: image.Image) Module {
        var m: Module = .{ .image = img };
        m.name_len = @intCast(@min(name_.len, m.name_buf.len));
        @memcpy(m.name_buf[0..m.name_len], name_[0..m.name_len]);
        m.version_len = @intCast(@min(version_.len, m.version_buf.len));
        @memcpy(m.version_buf[0..m.version_len], version_[0..m.version_len]);
        return m;
    }

    pub fn name(m: *const Module) []const u8 {
        return m.name_buf[0..m.name_len];
    }

    pub fn version(m: *const Module) []const u8 {
        return m.version_buf[0..m.version_len];
    }
};

/// What crashed, as the first line of a report says it.
pub const What = union(enum) {
    panic: []const u8,
    signal: struct { name: []const u8, address: ?usize = null },
};

/// The run a report describes. Every string outlives the run.
pub const Run = struct {
    app: []const u8,
    version: []const u8,
    sdk: []const u8,
};

/// Writes a report: who crashed and how, the run, the modules, and each frame as a module and an
/// offset. `frames` are return addresses, as `std.debug.captureCurrentStackTrace` gives them;
/// each is written less one, so it lands inside the call. `nameOf` names an address no module
/// holds (a system library), when the platform can.
pub fn writeReport(
    w: *std.Io.Writer,
    run: Run,
    what: What,
    modules: []const Module,
    frames: []const usize,
    nameOf: ?*const fn (usize, []u8) ?[]const u8,
) std.Io.Writer.Error!void {
    try w.print("{s} crashed", .{run.app});
    for (frames) |ret| if (moduleOf(modules, ret -| 1)) |i| {
        try w.print(" in {s} {s}", .{ modules[i].name(), modules[i].version() });
        break;
    };
    switch (what) {
        .panic => |msg| try w.print(": panic: {s}\n", .{msg}),
        .signal => |s| if (s.address) |a|
            try w.print(": {s} at address 0x{x}\n", .{ s.name, a })
        else
            try w.print(": {s}\n", .{s.name}),
    }
    try w.print("\n{s} {s}, sdk {s}, {t} {t} {t}\n\nmodules:\n", .{
        run.app, run.version, run.sdk, builtin.os.tag, builtin.cpu.arch, builtin.mode,
    });
    for (modules, 0..) |*m, i| {
        try w.print("  {d} {s} {s} 0x{x} 0x{x} ", .{ i, m.name(), m.version(), m.image.base, m.image.end - m.image.base });
        if (m.image.buildId().len == 0) try w.writeAll("-") else for (m.image.buildId()) |b| try w.print("{x:0>2}", .{b});
        try w.writeByte('\n');
    }
    try w.writeAll("frames:\n");
    var name_buf: [256]u8 = undefined;
    for (frames) |ret| {
        const pc = ret -| 1;
        if (moduleOf(modules, pc)) |i| {
            try w.print("  {s}+0x{x}\n", .{ modules[i].name(), pc - modules[i].image.base });
        } else {
            try w.print("  0x{x}", .{pc});
            if (nameOf) |f| if (f(pc, &name_buf)) |n| try w.print(" {s}", .{n});
            try w.writeByte('\n');
        }
    }
    if (frames.len == 0) try w.writeAll("  (none: the stack could not be walked)\n");
}

fn moduleOf(modules: []const Module, address: usize) ?usize {
    for (modules, 0..) |*m, i| if (m.image.contains(address)) return i;
    return null;
}

// The table. Only the UI thread adds and removes; a crash on any thread reads. A slot is written
// whole before it is marked used, and marked unused before it can be reused.
const max_modules = 64;
var table: [max_modules]Module = undefined;
var used: [max_modules]std.atomic.Value(bool) = @splat(.init(false));

/// Adds the image holding `address` (any code or data in it) as `name` at `version`.
pub fn addModule(name: []const u8, version: []const u8, address: usize) void {
    if (!supported) return;
    const img = image.containing(address) orelse return;
    for (&used, 0..) |*u, i| if (!u.load(.acquire)) {
        table[i] = .init(name, version, img);
        u.store(true, .release);
        return;
    };
}

/// Removes the image holding `address`, before it is unmapped.
pub fn removeModule(address: usize) void {
    if (!supported) return;
    for (&used, 0..) |*u, i| if (u.load(.acquire) and table[i].image.contains(address)) u.store(false, .release);
}

var run_info: ?Run = null;
/// The report's file, once `writeTo` has named it.
var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
var path_len: usize = 0;
var path_w: if (builtin.os.tag == .windows) [std.fs.max_path_bytes:0]u16 else void = undefined;

/// Starts reporting for this run: enters the executable as module 0 and catches aborts and
/// traps. Call once, first thing. std's segfault handler is the root's to switch on
/// (`std_options.enable_segfault_handler`) and to route here (`root.debug.handleSegfault`).
/// Until `writeTo`, a report goes to stderr only.
pub fn init(run: Run) void {
    if (!supported) return;
    run_info = run;
    addModule(run.app, run.version, @intFromPtr(&init));
    if (builtin.os.tag != .windows) {
        const act: std.posix.Sigaction = .{
            .handler = .{ .sigaction = onAbortOrTrap },
            .mask = std.posix.sigemptyset(),
            .flags = std.posix.SA.SIGINFO | std.posix.SA.ONSTACK | std.posix.SA.RESETHAND,
        };
        std.posix.sigaction(.ABRT, &act, null);
        std.posix.sigaction(.TRAP, &act, null);
    }
}

/// Names this run's report file, `<config>/crashes/<launch ms>-<pid>.txt`, creating the folder.
/// Nothing is written there unless the run crashes.
pub fn writeTo(io: std.Io, config_folder: []const u8) void {
    if (!supported) return;
    const pid = if (builtin.os.tag == .windows) win.GetCurrentProcessId() else std.c.getpid();
    const launched = std.Io.Timestamp.now(io, .real).toMilliseconds();
    const sep = std.fs.path.sep;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}{c}crashes{c}{d}-{d}.txt", .{ config_folder, sep, sep, launched, pid }) catch return;
    const dir = std.fs.path.dirname(path).?;
    std.Io.Dir.cwd().createDirPath(io, dir) catch |err| {
        std.log.warn("crash reports: can't create {s}: {t}", .{ dir, err });
        return;
    };
    if (builtin.os.tag == .windows) {
        const n = std.unicode.wtf8ToWtf16Le(&path_w, path) catch return;
        if (n >= path_w.len) return;
        path_w[n] = 0;
    }
    path_len = path.len;
}

/// The root's panic handler (`std.debug.FullPanic(crash.panic)`): the report, then std's.
pub fn panic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    report(.{ .panic = msg }, .{ .first_address = first_trace_addr orelse @returnAddress() });
    std.debug.defaultPanic(msg, first_trace_addr);
}

/// The root's `debug.handleSegfault`: the report, then std's.
pub fn handleSegfault(address: ?usize, name: []const u8, ctx: ?std.debug.CpuContextPtr) noreturn {
    report(.{ .signal = .{ .name = name, .address = address } }, .{ .context = ctx });
    std.debug.defaultHandleSegfault(address, name, ctx);
}

fn onAbortOrTrap(sig: std.posix.SIG, _: *const std.posix.siginfo_t, ctx_ptr: ?*anyopaque) callconv(.c) void {
    const ctx = std.debug.cpu_context.fromPosixSignalContext(ctx_ptr);
    const name = if (sig == .ABRT) "Abort" else "Trace/breakpoint trap";
    report(.{ .signal = .{ .name = name } }, .{ .context = if (ctx) |*c| c else null });
    // RESETHAND put the default action back; raised again, it runs once this handler returns.
    _ = std.c.raise(sig);
}

const Where = struct { first_address: ?usize = null, context: ?std.debug.CpuContextPtr = null };

var reported: std.atomic.Value(bool) = .init(false);
var report_buf: [32 * 1024]u8 = undefined;
var frame_buf: [128]usize = undefined;

/// One report per run: a crash while reporting, or the abort std's panic ends in, adds none.
fn report(what: What, where: Where) void {
    if (reported.swap(true, .acq_rel)) return;
    const run = run_info orelse return;
    const trace = std.debug.captureCurrentStackTrace(.{
        .first_address = where.first_address,
        .context = where.context,
        .allow_unsafe_unwind = true,
    }, &frame_buf);

    var modules: [max_modules]Module = undefined;
    var n: usize = 0;
    for (&used, 0..) |*u, i| if (u.load(.acquire)) {
        modules[n] = table[i];
        n += 1;
    };

    var w: std.Io.Writer = .fixed(&report_buf);
    writeReport(&w, run, what, modules[0..n], trace.return_addresses, imageName) catch {};
    const text = w.buffered();
    const path = path_buf[0..path_len];
    if (path_len > 0 and writeFile(text)) {
        writeStderr("\n");
        writeStderr(text);
        writeStderr("crash report: ");
        writeStderr(path);
        writeStderr("\n\n");
    } else {
        writeStderr("\n");
        writeStderr(text);
        writeStderr("\n");
    }
}

fn writeFile(text: []const u8) bool {
    if (builtin.os.tag == .windows) {
        const h = win.CreateFileW(&path_w, win.GENERIC_WRITE, 0, null, win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, null);
        if (h == win.INVALID_HANDLE_VALUE) return false;
        defer _ = win.CloseHandle(h);
        return win.writeAll(h, text);
    }
    const fd = std.c.open(path_buf[0..path_len :0], .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return false;
    defer _ = std.c.close(fd);
    return posixWriteAll(fd, text);
}

fn writeStderr(text: []const u8) void {
    if (builtin.os.tag == .windows) {
        _ = win.writeAll(win.GetStdHandle(win.STD_ERROR_HANDLE) orelse return, text);
    } else _ = posixWriteAll(2, text);
}

fn posixWriteAll(fd: std.c.fd_t, text: []const u8) bool {
    var at: usize = 0;
    while (at < text.len) {
        const n = std.c.write(fd, text[at..].ptr, text.len - at);
        if (n <= 0) return false;
        at += @intCast(n);
    }
    return true;
}

/// The file name of the image holding `address`, for a frame in no known module.
fn imageName(address: usize, buf: []u8) ?[]const u8 {
    if (builtin.os.tag == .windows) return null;
    var info: Dl_info = undefined;
    if (dladdr(@ptrFromInt(address), &info) == 0) return null;
    const path = std.mem.span(info.dli_fname orelse return null);
    const base = std.fs.path.basename(path);
    const n = @min(base.len, buf.len);
    @memcpy(buf[0..n], base[0..n]);
    return buf[0..n];
}

const Dl_info = extern struct {
    dli_fname: ?[*:0]const u8,
    dli_fbase: ?*anyopaque,
    dli_sname: ?[*:0]const u8,
    dli_saddr: ?*anyopaque,
};
extern "c" fn dladdr(address: *const anyopaque, info: *Dl_info) c_int;

const win = struct {
    const HANDLE = *anyopaque;
    const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
    const GENERIC_WRITE = 0x40000000;
    const CREATE_ALWAYS = 2;
    const FILE_ATTRIBUTE_NORMAL = 0x80;
    const STD_ERROR_HANDLE: u32 = @bitCast(@as(i32, -12));
    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, disposition: u32, flags: u32, template: ?HANDLE) callconv(.winapi) HANDLE;
    extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, len: u32, written: *u32, overlapped: ?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) i32;
    extern "kernel32" fn GetStdHandle(which: u32) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;

    fn writeAll(h: HANDLE, text: []const u8) bool {
        var at: usize = 0;
        while (at < text.len) {
            var written: u32 = 0;
            const chunk: u32 = @intCast(@min(text.len - at, std.math.maxInt(u32)));
            if (WriteFile(h, text[at..].ptr, chunk, &written, null) == 0 or written == 0) return false;
            at += written;
        }
        return true;
    }
};

test {
    // The handlers too, so every target's `zig build test` compiles them.
    std.testing.refAllDecls(@This());
}

test "a report names the innermost frame's module, and writes each frame against its module" {
    const app: Module = .init("fizzy", "0.4.2", .{ .base = 0x1000, .end = 0x9000 });
    var pixi: Module = .init("pixi", "0.1.40", .{ .base = 0x20000, .end = 0x28000 });
    pixi.image.build_id_buf[0..2].* = .{ 0xab, 0x01 };
    pixi.image.build_id_len = 2;
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const unknown = struct {
        fn f(_: usize, out: []u8) ?[]const u8 {
            @memcpy(out[0..9], "libc.so.6");
            return out[0..9];
        }
    }.f;
    try writeReport(&w, .{ .app = "fizzy", .version = "0.4.2", .sdk = "0.2.22" }, .{ .panic = "index out of bounds" }, &.{ app, pixi }, &.{ 0x500001, 0x20101, 0x1201 }, unknown);
    const text = w.buffered();
    try std.testing.expect(std.mem.startsWith(u8, text, "fizzy crashed in pixi 0.1.40: panic: index out of bounds\n"));
    try std.testing.expect(std.mem.indexOf(u8, text, "  1 pixi 0.1.40 0x20000 0x8000 ab01\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  0 fizzy 0.4.2 0x1000 0x8000 -\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "frames:\n  0x500000 libc.so.6\n  pixi+0x100\n  fizzy+0x200\n"));
}

test "a fault with no frames still says what and where" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeReport(&w, .{ .app = "fizzy", .version = "0.4.2", .sdk = "0.2.22" }, .{ .signal = .{ .name = "Segmentation fault", .address = 0x10 } }, &.{}, &.{}, null);
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "fizzy crashed: Segmentation fault at address 0x10\n"));
    try std.testing.expect(std.mem.endsWith(u8, w.buffered(), "frames:\n  (none: the stack could not be walked)\n"));
}
