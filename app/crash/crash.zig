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
//! - a panic in a plugin dylib, which has its own std: the generated root's handler
//!   (`sdk.dylib.panic`) forwards it through `EditorAPI.panic` to `panic`, message and frames;
//! - an abort or trap anywhere (SIGABRT, SIGTRAP; POSIX only).
//!
//! After the report, each hands on to what would have run without it: std's own handler, which
//! prints the symbolized stack trace, or the signal's default action.
//!
//! Std-only, so its tests run on their own (`fizzy-crash-tests`).
const std = @import("std");
const builtin = @import("builtin");
pub const image = @import("image.zig");
pub const loaded = @import("loaded.zig");

/// Where crash reports can be written: native targets std can catch faults on.
pub const supported = builtin.target.cpu.arch != .wasm32 and std.debug.have_segfault_handling_support;

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
    /// `code` is the signal's `si_code` (why it was sent: no mapping, no permission, …).
    signal: struct { name: []const u8, address: ?usize = null, code: ?i32 = null },
};

/// The run a report describes. Every string outlives the run.
pub const Run = struct {
    app: []const u8,
    version: []const u8,
    sdk: []const u8,
};

/// The thread that crashed, and for a fault the registers it stopped with.
pub const Thread = struct {
    id: u64 = 0,
    name: []const u8 = "",
    registers: ?Registers = null,
};

pub const Registers = struct {
    pc: usize,
    sp: usize,
    fp: usize,
    /// When `pc` lies in no image's code, what its caller left; the stack is walked from there.
    caller: Caller = .none,
};

pub const Caller = union(enum) {
    /// `pc` is in an image, or the caller couldn't be read safely.
    none,
    /// The return address a call through a bad pointer left: `*(sp)` on x86_64, the link
    /// register on aarch64. By the call convention only: a jump or tail call through the bad
    /// pointer leaves the caller's own caller there, which this then names.
    address: usize,
    /// That return address is `pc` itself: `pc` came from a return through a corrupt return
    /// address, not a call, so it names no caller.
    from_return,
};

/// Whether an address is code, and whose: `loaded.at`, or a test's stand-in.
pub const CodeAt = *const fn (usize) loaded.At;

/// Writes a report: who crashed and how, the run, the thread, the modules, and each frame as a
/// module (or image) and an offset. `frames` are return addresses, as
/// `std.debug.captureCurrentStackTrace` gives them; each is written less one, so it lands inside
/// the call. (The first, a context's own PC, std already gives plus one.) `code_at` says which
/// addresses are code. The walk stops at the first frame past the first that is definitely not
/// code, since a frame-pointer walk through a corrupt frame reads garbage from there on; a frame
/// it can't tell about is written as it is. A module only names an address: its span covers its
/// data too. Not reentrant (it locates frames into a static buffer); a run reports once.
pub fn writeReport(
    w: *std.Io.Writer,
    run: Run,
    what: What,
    thread: Thread,
    modules: []const Module,
    all_frames: []const usize,
    code_at: CodeAt,
) std.Io.Writer.Error!void {
    // Each frame is located once, for where the walk stops and for what is written.
    const frames = all_frames[0..@min(all_frames.len, located_buf.len)];
    var shown = frames.len;
    for (frames, 0..) |ret, i| {
        located_buf[i] = locate(modules, ret -| 1, code_at);
        if (i > 0 and located_buf[i].exec == .not_code) {
            shown = i;
            break;
        }
    }
    const located = located_buf[0..shown];
    try w.print("{s} crashed", .{run.app});
    for (located) |l| if (l.module) |i| {
        try w.print(" in {s} {s}", .{ modules[i].name(), modules[i].version() });
        break;
    };
    switch (what) {
        .panic => |msg| try w.print(": panic: {s}\n", .{msg}),
        .signal => |s| {
            try w.print(": {s}", .{s.name});
            if (s.address) |a| try w.print(" at address 0x{x}", .{a});
            if (s.code) |c| try w.print(" (code {d})", .{c});
            try w.writeByte('\n');
        },
    }
    try w.print("\n{s} {s}, sdk {s}, {t} {t} {t}\n", .{
        run.app, run.version, run.sdk, builtin.target.os.tag, builtin.target.cpu.arch, builtin.mode,
    });
    try w.print("thread {d}", .{thread.id});
    if (thread.name.len > 0) try w.print(" \"{s}\"", .{thread.name});
    try w.writeByte('\n');
    if (thread.registers) |r| {
        try w.print("registers: pc 0x{x} sp 0x{x} fp 0x{x}\n", .{ r.pc, r.sp, r.fp });
        switch (r.caller) {
            .none => {},
            .address => |c| {
                try w.writeAll("caller (by call convention): ");
                try writeAddress(w, c -| 1, locate(modules, c -| 1, code_at));
                try w.writeAll(" (pc is not code)\n");
            },
            .from_return => try w.writeAll("caller: (caller unknown: pc came from a return)\n"),
        }
    }
    try w.writeAll("\nmodules:\n");
    for (modules, 0..) |*m, i| {
        try w.print("  {d} {s} {s} 0x{x} 0x{x} ", .{ i, m.name(), m.version(), m.image.base, m.image.end - m.image.base });
        if (m.image.buildId().len == 0) try w.writeAll("-") else for (m.image.buildId()) |b| try w.print("{x:0>2}", .{b});
        try w.writeByte('\n');
    }
    try w.writeAll("frames:\n");
    for (located, frames[0..shown]) |l, ret| {
        try w.writeAll("  ");
        try writeAddress(w, ret -| 1, l);
        try w.writeByte('\n');
    }
    if (shown < frames.len) try w.print("  (unwind stopped: 0x{x} is not code)\n", .{frames[shown] -| 1});
    if (frames.len == 0) try w.writeAll("  (none: the stack could not be walked)\n");
}

var located_buf: [frame_buf.len]Located = undefined;

/// Where an address lies: whether it is code, and the module or image naming it, if any.
const Located = struct { exec: loaded.Exec, name: []const u8 = "", offset: usize = 0, module: ?usize = null };

fn locate(modules: []const Module, address: usize, code_at: CodeAt) Located {
    const at = code_at(address);
    if (at.exec == .not_code) return .{ .exec = .not_code };
    if (moduleOf(modules, address)) |i| return .{ .exec = at.exec, .name = modules[i].name(), .offset = address - modules[i].image.base, .module = i };
    if (at.name.len == 0) return .{ .exec = at.exec };
    return .{ .exec = at.exec, .name = at.name, .offset = address -% at.base };
}

/// `name+0xoffset`, or the bare address, marked when it is definitely not code.
fn writeAddress(w: *std.Io.Writer, address: usize, l: Located) std.Io.Writer.Error!void {
    if (l.name.len > 0) return w.print("{s}+0x{x}", .{ l.name, l.offset });
    try w.print("0x{x}", .{address});
    if (l.exec == .not_code) try w.writeAll(" (not code)");
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
var path_w: if (builtin.target.os.tag == .windows) [std.fs.max_path_bytes:0]u16 else void = undefined;

/// Starts reporting for this run: enters the executable as module 0, takes the table of
/// loaded images' names, and catches aborts and traps. Call once, first thing. std's segfault handler is the root's to switch on
/// (`std_options.enable_segfault_handler`) and to route here (`root.debug.handleSegfault`).
/// Until `writeTo`, a report goes to stderr only.
pub fn init(run: Run) void {
    if (!supported) return;
    run_info = run;
    addModule(run.app, run.version, @intFromPtr(&init));
    loaded.refresh();
    if (builtin.target.os.tag != .windows) {
        const act: std.posix.Sigaction = .{
            .handler = .{ .sigaction = onAbortOrTrap },
            .mask = std.posix.sigemptyset(),
            .flags = std.posix.SA.SIGINFO | std.posix.SA.ONSTACK | std.posix.SA.RESETHAND,
        };
        std.posix.sigaction(.ABRT, &act, null);
        std.posix.sigaction(.TRAP, &act, null);
        // std's fault handler is told the address but not the `si_code`; note it on the way in.
        for (fault_signals, &prev_fault) |sig, *prev| {
            std.posix.sigaction(sig, null, prev);
            // Not std's (or already ours, from an earlier `init`): leave it.
            if (prev.flags & std.posix.SA.SIGINFO == 0 or prev.handler.sigaction == null or prev.handler.sigaction == &onFault) continue;
            var ours = prev.*;
            ours.handler = .{ .sigaction = onFault };
            std.posix.sigaction(sig, &ours, null);
        }
    }
}

const fault_signals = [_]std.posix.SIG{ .SEGV, .BUS, .ILL, .FPE };
var prev_fault: [fault_signals.len]std.posix.Sigaction = undefined;
/// The last fault's `si_code`, tagged with its thread: the faulting thread's id in the high half,
/// the code in the low. One word, so a fault on another thread can't pair its code with ours; a
/// thread local would be cleaner, but its first touch on macOS can allocate, in a signal handler.
var fault_code: std.atomic.Value(u64) = .init(0);

/// This thread's fault code, if `onFault` noted one.
fn faultCode() ?i32 {
    const v = fault_code.load(.acquire);
    if (v == 0 or @as(u32, @truncate(v >> 32)) != @as(u32, @truncate(@as(u64, @intCast(std.Thread.getCurrentId()))))) return null;
    return @bitCast(@as(u32, @truncate(v)));
}

fn onFault(sig: std.posix.SIG, info: *const std.posix.siginfo_t, ctx_ptr: ?*anyopaque) callconv(.c) void {
    const code: u32 = @bitCast(@as(i32, @intCast(info.code)));
    const tag: u32 = @truncate(@as(u64, @intCast(std.Thread.getCurrentId())));
    fault_code.store(@as(u64, tag) << 32 | code, .release);
    for (fault_signals, prev_fault) |s, prev| if (s == sig) prev.handler.sigaction.?(sig, info, ctx_ptr);
}

/// Names this run's report file, `<config>/crashes/<launch ms>-<pid>.txt`, creating the folder.
/// Nothing is written there unless the run crashes.
pub fn writeTo(io: std.Io, config_folder: []const u8) void {
    if (!supported) return;
    loaded.refresh(); // the names of libraries loaded since `init` (a window's, a GPU driver's)
    const pid = if (builtin.target.os.tag == .windows) win.GetCurrentProcessId() else std.c.getpid();
    const launched = std.Io.Timestamp.now(io, .real).toMilliseconds();
    const sep = std.fs.path.sep;
    const path = std.mem.printSentinel(&path_buf, "{s}{c}crashes{c}{d}-{d}.txt", .{ config_folder, sep, sep, launched, pid }, 0) catch return;
    const dir = std.fs.path.dirname(path).?;
    std.Io.Dir.cwd().createDirPath(io, dir) catch |err| {
        std.log.warn("crash reports: can't create {s}: {t}", .{ dir, err });
        return;
    };
    if (builtin.target.os.tag == .windows) {
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
    report(.{ .signal = .{ .name = name, .address = address, .code = if (builtin.target.os.tag == .windows) null else faultCode() } }, .{ .context = ctx });
    std.debug.defaultHandleSegfault(address, name, ctx);
}

fn onAbortOrTrap(sig: std.posix.SIG, _: *const std.posix.siginfo_t, ctx_ptr: ?*anyopaque) callconv(.c) void {
    const ctx = std.debug.cpu_context.fromPosixSignalContext(ctx_ptr);
    const name = if (sig == .ABRT) "Abort" else "Trace/breakpoint trap";
    // No code: for a raised signal `si_code` says who sent it, not why.
    report(.{ .signal = .{ .name = name } }, .{ .context = if (ctx) |*c| c else null });
    // RESETHAND put the default action back; raised again, it runs once this handler returns.
    _ = std.c.raise(sig);
}

const Where = struct { first_address: ?usize = null, context: ?std.debug.CpuContextPtr = null };

var reported: std.atomic.Value(bool) = .init(false);
var report_buf: [32 * 1024]u8 = undefined;
var frame_buf: [128]usize = undefined;

/// One report per run: a crash while reporting, or the abort std's panic ends in, adds none.
/// Calls no loader (`dladdr` and the like take its lock, which another thread may hold): images
/// come from `loaded`'s table. std's own unwinder still asks the loader for unwind info.
fn report(what: What, where: Where) void {
    if (reported.swap(true, .acq_rel)) return;
    const run = run_info orelse return;

    loaded.beginReport();
    var n: usize = 0;
    for (&used, 0..) |*u, i| if (u.load(.acquire)) {
        modules_buf[n] = table[i];
        n += 1;
    };
    const modules = modules_buf[0..n];

    var thread: Thread = .{ .id = @intCast(std.Thread.getCurrentId()), .name = threadName(&thread_name_buf) };
    var frames: []const usize = &.{};
    if (comptime std.debug.cpu_context.Native != noreturn) if (where.context) |ctx| if (registersOf(ctx)) |regs| {
        thread.registers = regs;
        // A PC in no image's code (a call through a bad pointer) has no unwind info, and std's
        // frame-pointer fallback skips the caller, so walk from the caller instead.
        if (loaded.at(regs.pc).exec == .not_code) if (callerOf(ctx)) |c| {
            thread.registers.?.caller = c.caller;
            if (c.caller == .address and loaded.at(c.caller.address -| 1).exec == .code) {
                const rest = std.debug.captureCurrentStackTrace(.{ .context = &c.ctx, .allow_unsafe_unwind = true }, frame_buf[1..]);
                if (rest.return_addresses.len > 0) {
                    // std gives a context's PC plus one: the faulting PC's, and the caller's
                    // context PC (its return address less one) as the return address itself.
                    frame_buf[0] = regs.pc +| 1;
                    frames = frame_buf[0 .. 1 + rest.return_addresses.len];
                }
            }
        };
    };
    // Otherwise, and whenever the walk from the caller found nothing, std's walk from the context.
    if (frames.len == 0) frames = std.debug.captureCurrentStackTrace(.{
        .first_address = where.first_address,
        .context = where.context,
        .allow_unsafe_unwind = true,
    }, &frame_buf).return_addresses;

    var w: std.Io.Writer = .fixed(&report_buf);
    writeReport(&w, run, what, thread, modules, frames, loaded.at) catch {};
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

// Static, off the stack: on Windows a report can come from a stack overflow.
var modules_buf: [max_modules]Module = undefined;

var thread_name_buf: [64:0]u8 = undefined;

fn threadName(buf: *[64:0]u8) []const u8 {
    switch (builtin.target.os.tag) {
        .linux, .freebsd, .netbsd, .macos, .ios, .tvos, .visionos, .watchos => {},
        else => return "",
    }
    buf[0] = 0;
    if (std.c.pthread_getname_np(std.c.pthread_self(), buf, buf.len) != 0) return "";
    return std.mem.sliceTo(buf, 0);
}

fn registersOf(ctx: std.debug.CpuContextPtr) ?Registers {
    return switch (builtin.target.cpu.arch) {
        .x86_64 => .{ .pc = ctx.gprs.get(.rip), .sp = ctx.gprs.get(.rsp), .fp = ctx.gprs.get(.rbp) },
        .aarch64 => .{ .pc = ctx.pc, .sp = ctx.sp, .fp = ctx.x[29] },
        else => null,
    };
}

const Arch = enum { x86_64, aarch64 };

/// How `pc` was reached, by the call convention. A call through a bad pointer left its return
/// address at `*(sp)` (x86_64's `call` pushed it) or in `lr` (aarch64's `blr`). A return through
/// a corrupt return address left `pc` itself in `lr` (aarch64's `ret` jumped to it) or just
/// below `sp` (x86_64's `ret` popped it). That word is below the stack, where anything may
/// linger, so on x86_64 it counts only when `*(sp)` is no code address a call could have left.
/// A word that is not surely code names no caller. `read` reads a stack word safely;
/// `is_code` says whether an address is surely code.
fn callerFrom(arch: Arch, pc: usize, sp: usize, lr: usize, read: *const fn (usize) ?usize, is_code: *const fn (usize) bool) Caller {
    switch (arch) {
        .x86_64 => {
            if (read(sp)) |r| if (r > 1 and is_code(r - 1)) return .{ .address = r };
            if (read(sp -% @sizeOf(usize))) |popped| if (popped == pc) return .from_return;
            return .none;
        },
        .aarch64 => {
            if (lr == pc) return .from_return;
            return if (lr > 1 and is_code(lr - 1)) .{ .address = lr } else .none;
        },
    }
}

fn isCode(address: usize) bool {
    return loaded.at(address).exec == .code;
}

/// The faulting context's caller, and the context as it was at the return to it.
fn callerOf(ctx: std.debug.CpuContextPtr) ?struct { caller: Caller, ctx: std.debug.cpu_context.Native } {
    const regs = registersOf(ctx) orelse return null;
    var at = ctx.*;
    switch (builtin.target.cpu.arch) {
        .x86_64 => {
            const caller = callerFrom(.x86_64, regs.pc, regs.sp, 0, readStackWord, isCode);
            // The PC goes in as the return address less one: std takes a context's PC as exact,
            // and a call that ends its function returns to the next one's first byte.
            if (caller == .address) {
                at.gprs.set(.rip, caller.address - 1);
                at.gprs.set(.rsp, regs.sp + @sizeOf(usize));
            }
            return .{ .caller = caller, .ctx = at };
        },
        .aarch64 => {
            const caller = callerFrom(.aarch64, regs.pc, regs.sp, ctx.x[30], readStackWord, isCode);
            if (caller == .address) at.pc = caller.address - 1;
            return .{ .caller = caller, .ctx = at };
        },
        else => return null,
    }
}

fn writeFile(text: []const u8) bool {
    if (builtin.target.os.tag == .windows) {
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
    if (builtin.target.os.tag == .windows) {
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

/// The word at `sp` on the faulting thread's stack, read so that a corrupt or pivoted `sp`
/// can't fault again inside the handler (which would end the run with no report at all): on
/// Linux through `process_vm_readv`, which fails rather than faults; on macOS and Windows only
/// when it lies within this thread's stack. Null where neither can be done.
fn readStackWord(sp: usize) ?usize {
    if (sp == 0 or !std.mem.isAligned(sp, @alignOf(usize))) return null;
    const lo: usize, const hi: usize = switch (builtin.target.os.tag) {
        .linux => {
            const linux = std.os.linux;
            var word: usize = 0;
            const local = [_]std.posix.iovec{.{ .base = @ptrCast(&word), .len = @sizeOf(usize) }};
            const remote = [_]std.posix.iovec_const{.{ .base = @ptrFromInt(sp), .len = @sizeOf(usize) }};
            if (linux.process_vm_readv(linux.getpid(), &local, &remote, 0) != @sizeOf(usize)) return null;
            return word;
        },
        .macos, .ios, .tvos, .visionos, .watchos => bounds: {
            const self = std.c.pthread_self();
            const top = @intFromPtr(pthread_get_stackaddr_np(self));
            break :bounds .{ top -| pthread_get_stacksize_np(self), top };
        },
        .windows => bounds: {
            const tib = &std.os.windows.teb().NtTib;
            break :bounds .{ @intFromPtr(tib.StackLimit), @intFromPtr(tib.StackBase) };
        },
        else => return null,
    };
    if (sp < lo or sp > hi -| @sizeOf(usize)) return null;
    return @as(*const usize, @ptrFromInt(sp)).*;
}

extern "c" fn pthread_get_stackaddr_np(thread: std.c.pthread_t) ?*anyopaque;
extern "c" fn pthread_get_stacksize_np(thread: std.c.pthread_t) usize;

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

const test_run: Run = .{ .app = "fizzy", .version = "0.4.2", .sdk = "0.2.22" };

/// Code: fizzy's at 0x1000..0x5000, pixi's at 0x20000..0x28000, libc's at 0x400000..0x600000.
/// Not code: fizzy's data at 0x5000..0x9000, the heap at 0x7e0000..0x800000. The rest: unknown.
fn testCodeAt(address: usize) loaded.At {
    if (address >= 0x1000 and address < 0x5000) return .{ .exec = .code, .name = "fizzy", .base = 0x1000 };
    if (address >= 0x20000 and address < 0x28000) return .{ .exec = .code, .name = "pixi.dylib", .base = 0x20000 };
    if (address >= 0x400000 and address < 0x600000) return .{ .exec = .code, .name = "libc.so.6", .base = 0x400000 };
    if (address >= 0x5000 and address < 0x9000) return .{ .exec = .not_code };
    if (address >= 0x7e0000 and address < 0x800000) return .{ .exec = .not_code };
    return .{ .exec = .unknown };
}

fn testUnknown(_: usize) loaded.At {
    return .{ .exec = .unknown };
}

test "a report names the innermost frame's module, and writes each frame against its module or image" {
    const app: Module = .init("fizzy", "0.4.2", .{ .base = 0x1000, .end = 0x9000 });
    var pixi: Module = .init("pixi", "0.1.40", .{ .base = 0x20000, .end = 0x28000 });
    pixi.image.build_id_buf[0..2].* = .{ 0xab, 0x01 };
    pixi.image.build_id_len = 2;
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeReport(&w, test_run, .{ .panic = "index out of bounds" }, .{ .id = 7, .name = "main" }, &.{ app, pixi }, &.{ 0x500001, 0x20101, 0x1201 }, testCodeAt);
    const text = w.buffered();
    try std.testing.expect(std.mem.startsWith(u8, text, "fizzy crashed in pixi 0.1.40: panic: index out of bounds\n"));
    try std.testing.expect(std.mem.find(u8, text, "thread 7 \"main\"\n") != null);
    try std.testing.expect(std.mem.find(u8, text, "registers:") == null);
    try std.testing.expect(std.mem.find(u8, text, "  1 pixi 0.1.40 0x20000 0x8000 ab01\n") != null);
    try std.testing.expect(std.mem.find(u8, text, "  0 fizzy 0.4.2 0x1000 0x8000 -\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "frames:\n  libc.so.6+0x100000\n  pixi+0x100\n  fizzy+0x200\n"));
}

test "a fault with no frames still says what and where" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeReport(&w, test_run, .{ .signal = .{ .name = "Segmentation fault", .address = 0x10 } }, .{}, &.{}, &.{}, testUnknown);
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "fizzy crashed: Segmentation fault at address 0x10\n"));
    try std.testing.expect(std.mem.endsWith(u8, w.buffered(), "frames:\n  (none: the stack could not be walked)\n"));
}

test "a PC that is not code is reported with its registers, code and caller, and the walk goes on from the caller" {
    const app: Module = .init("fizzy", "0.4.2", .{ .base = 0x1000, .end = 0x9000 });
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const thread: Thread = .{ .id = 42, .registers = .{ .pc = 0x7f0000, .sp = 0x9ff0, .fp = 0x10, .caller = .{ .address = 0x1301 } } };
    // The context's PC as std gives it (plus one), then the caller and its callers.
    try writeReport(&w, test_run, .{ .signal = .{ .name = "Segmentation fault", .address = 0x7f0000, .code = 2 } }, thread, &.{app}, &.{ 0x7f0001, 0x1301, 0x1201 }, testCodeAt);
    const text = w.buffered();
    try std.testing.expect(std.mem.startsWith(u8, text, "fizzy crashed in fizzy 0.4.2: Segmentation fault at address 0x7f0000 (code 2)\n"));
    try std.testing.expect(std.mem.find(u8, text, "thread 42\nregisters: pc 0x7f0000 sp 0x9ff0 fp 0x10\ncaller (by call convention): fizzy+0x300 (pc is not code)\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "frames:\n  0x7f0000 (not code)\n  fizzy+0x300\n  fizzy+0x200\n"));
}

test "the walk stops at the first frame past the PC that is not code, and at nothing unknown" {
    const app: Module = .init("fizzy", "0.4.2", .{ .base = 0x1000, .end = 0x9000 });
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // A corrupt frame pointer: after fizzy's frame comes a heap address, then whatever it held.
    try writeReport(&w, test_run, .{ .signal = .{ .name = "Segmentation fault" } }, .{}, &.{app}, &.{ 0x7f0001, 0x1201, 0x7e0001, 0x450001 }, testCodeAt);
    try std.testing.expect(std.mem.endsWith(u8, w.buffered(), "frames:\n  0x7f0000 (not code)\n  fizzy+0x200\n  (unwind stopped: 0x7e0000 is not code)\n"));
    // What can't be told about stops nothing, and is written as it is.
    w = .fixed(&buf);
    try writeReport(&w, test_run, .{ .signal = .{ .name = "Segmentation fault" } }, .{}, &.{app}, &.{ 0x7f0001, 0x1201, 0x7e0001 }, testUnknown);
    try std.testing.expect(std.mem.endsWith(u8, w.buffered(), "frames:\n  0x7f0000\n  fizzy+0x200\n  0x7e0000\n"));
}

test "the header names a module only from frames before the walk stopped" {
    const pixi: Module = .init("pixi", "0.1.40", .{ .base = 0x20000, .end = 0x28000 });
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeReport(&w, test_run, .{ .signal = .{ .name = "Segmentation fault" } }, .{}, &.{pixi}, &.{ 0x7f0001, 0x7e0001, 0x20101 }, testCodeAt);
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "fizzy crashed: Segmentation fault\n"));
    try std.testing.expect(std.mem.endsWith(u8, w.buffered(), "frames:\n  0x7f0000 (not code)\n  (unwind stopped: 0x7e0000 is not code)\n"));
}

test "a PC that came from a return names no caller" {
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const thread: Thread = .{ .id = 1, .registers = .{ .pc = 0x7f0000, .sp = 0x9ff0, .fp = 0x10, .caller = .from_return } };
    try writeReport(&w, test_run, .{ .signal = .{ .name = "Segmentation fault" } }, thread, &.{}, &.{0x7f0001}, testCodeAt);
    try std.testing.expect(std.mem.find(u8, w.buffered(), "registers: pc 0x7f0000 sp 0x9ff0 fp 0x10\ncaller: (caller unknown: pc came from a return)\n") != null);
}

test "a fault code is this thread's only" {
    const saved = fault_code.load(.acquire);
    defer fault_code.store(saved, .release);
    fault_code.store(0, .release);
    try std.testing.expectEqual(null, faultCode());
    const tag: u32 = @truncate(@as(u64, @intCast(std.Thread.getCurrentId())));
    fault_code.store(@as(u64, tag) << 32 | @as(u32, @bitCast(@as(i32, -2))), .release);
    try std.testing.expectEqual(-2, faultCode());
    fault_code.store(@as(u64, tag +% 1) << 32 | 2, .release);
    try std.testing.expectEqual(null, faultCode());
}

test "a stack word is read where it is this thread's, and an unmapped one is refused" {
    if (!supported) return error.SkipZigTest;
    var word: usize = 0x5eed;
    std.mem.doNotOptimizeAway(&word);
    switch (builtin.target.os.tag) {
        .linux, .macos, .windows => try std.testing.expectEqual(0x5eed, readStackWord(@intFromPtr(&word)).?),
        else => {},
    }
    try std.testing.expectEqual(null, readStackWord(0x1000));
    try std.testing.expectEqual(null, readStackWord(@intFromPtr(&word) + 1));
}

test "a module's data is not code: the walk stops there" {
    const app: Module = .init("fizzy", "0.4.2", .{ .base = 0x1000, .end = 0x9000 });
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeReport(&w, test_run, .{ .signal = .{ .name = "Segmentation fault" } }, .{}, &.{app}, &.{ 0x1201, 0x6001, 0x1301 }, testCodeAt);
    try std.testing.expect(std.mem.endsWith(u8, w.buffered(), "frames:\n  fizzy+0x200\n  (unwind stopped: 0x6000 is not code)\n"));
}

/// The stack around `test_sp`: the word just below it, and the word at it.
var test_words: [2]?usize = .{ null, null };
const test_sp = 0x9000;

fn testRead(address: usize) ?usize {
    if (address == test_sp - @sizeOf(usize)) return test_words[0];
    if (address == test_sp) return test_words[1];
    return null;
}

fn testIsCode(address: usize) bool {
    return testCodeAt(address).exec == .code;
}

test "a call through a bad pointer names its caller; a return through a bad address names none" {
    // x86_64: `call` pushed the return address at sp; below sp lingers whatever was there.
    test_words = .{ 0x55, 0x1301 };
    try std.testing.expectEqual(Caller{ .address = 0x1301 }, callerFrom(.x86_64, 0x7f0000, test_sp, 0, testRead, testIsCode));
    // Even when that lingering word is the bad pointer itself: `*(sp)` is a return address in code.
    test_words = .{ 0x7f0000, 0x1301 };
    try std.testing.expectEqual(Caller{ .address = 0x1301 }, callerFrom(.x86_64, 0x7f0000, test_sp, 0, testRead, testIsCode));
    // x86_64: `ret` popped pc from just below sp, and `*(sp)` is no return address.
    test_words = .{ 0x7f0000, 0x7e1234 };
    try std.testing.expectEqual(Caller.from_return, callerFrom(.x86_64, 0x7f0000, test_sp, 0, testRead, testIsCode));
    // x86_64: a stack word that is not code is no caller.
    test_words = .{ 0x55, 0x7e1234 };
    try std.testing.expectEqual(Caller.none, callerFrom(.x86_64, 0x7f0000, test_sp, 0, testRead, testIsCode));
    // x86_64: a stack that can't be read names none.
    test_words = .{ null, null };
    try std.testing.expectEqual(Caller.none, callerFrom(.x86_64, 0x7f0000, test_sp, 0, testRead, testIsCode));
    // aarch64: `blr` left the return address in lr; `ret` jumped to lr.
    try std.testing.expectEqual(Caller{ .address = 0x1301 }, callerFrom(.aarch64, 0x7f0000, test_sp, 0x1301, testRead, testIsCode));
    try std.testing.expectEqual(Caller.from_return, callerFrom(.aarch64, 0x7f0000, test_sp, 0x7f0000, testRead, testIsCode));
    try std.testing.expectEqual(Caller.none, callerFrom(.aarch64, 0x7f0000, test_sp, 0, testRead, testIsCode));
    try std.testing.expectEqual(Caller.none, callerFrom(.aarch64, 0x7f0000, test_sp, 0x7e1234, testRead, testIsCode));
}
