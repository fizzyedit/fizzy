//! Whether an address is code, and whose, asked from a crash handler without the loader.
//!
//! `dladdr`, `dl_iterate_phdr` and `_dyld_get_image_header_containing_address` take the loader's
//! lock; called from a crash on one thread while another holds it (a plugin's `dlopen`), they
//! deadlock and the report never comes. So `at` asks the kernel, which answers for every mapping
//! whoever made it: `/proc/self/maps` on Linux (read with raw syscalls), `VirtualQuery` on
//! Windows, `mach_vm_region_recurse` on macOS. Names come from the same place on Linux, and on
//! macOS and Windows from a table of loaded images taken outside any handler (dyld's add and
//! remove callbacks; a refresh at `crash.init` and `crash.writeTo`).
//!
//! The answer has three values, and only `not_code` is acted on: a report stops its walk there
//! and recovers a caller only from there. Whatever can't be told is `unknown`, and is written as
//! it was before any of this.
const std = @import("std");
const builtin = @import("builtin");
const image = @import("image.zig");

const os = builtin.target.os.tag;
const darwin = switch (os) {
    .macos, .ios, .tvos, .visionos, .watchos => @sizeOf(usize) == 8,
    else => false,
};

/// Whether this platform can tell code from not. Elsewhere `at` always says `unknown`.
pub const supported = builtin.target.cpu.arch != .wasm32 and (darwin or os == .linux or os == .windows);

pub const Exec = enum { code, not_code, unknown };

/// What an address is. `name` and `base` name the image (or mapping) holding code, when known.
pub const At = struct { exec: Exec, name: []const u8 = "", base: usize = 0 };

/// Whether `address` is code, and whose. Calls no loader: safe in a crash handler, once
/// `beginReport` has run on Linux.
pub fn at(address: usize) At {
    if (!supported) return .{ .exec = .unknown };
    switch (os) {
        .linux => return mapsAt(mappings[0..mappings_len], maps_buf[0..maps_len], maps_complete, address),
        .windows => {
            var mbi: win.MEMORY_BASIC_INFORMATION = undefined;
            if (win.VirtualQuery(@ptrFromInt(address), &mbi, @sizeOf(win.MEMORY_BASIC_INFORMATION)) == 0) return .{ .exec = .unknown };
            if (mbi.State != win.MEM_COMMIT or mbi.Protect & win.PAGE_EXECUTE_ANY == 0) return .{ .exec = .not_code };
            // The image's base is the allocation's; the table, taken earlier, may name an image
            // since unloaded, so it names only one that starts there.
            const base = @intFromPtr(mbi.AllocationBase);
            if (entryHolding(address)) |e| if (e.base == base) return .{ .exec = .code, .name = e.name(), .base = base };
            return .{ .exec = .code, .name = "?", .base = base };
        },
        else => {
            // dyld's table is kept by its own callbacks, so what it holds is mapped code.
            if (entryHolding(address)) |e| return .{ .exec = .code, .name = e.name(), .base = e.base };
            return .{ .exec = machExec(address) };
        },
    }
}

/// Before a report's first `at`: on Linux, reads `/proc/self/maps` (open and read are
/// async-signal-safe) and parses it once. Nothing elsewhere.
pub fn beginReport() void {
    if (os != .linux) return;
    const linux = std.os.linux;
    maps_len = 0;
    mappings_len = 0;
    maps_complete = false;
    const rc = linux.open("/proc/self/maps", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var whole = false;
    while (maps_len < maps_buf.len) {
        const n = linux.read(fd, maps_buf[maps_len..].ptr, maps_buf.len - maps_len);
        if (linux.errno(n) != .SUCCESS) return;
        if (n == 0) {
            whole = true;
            break;
        }
        maps_len += n;
    }
    const parsed = parseMaps(maps_buf[0..maps_len], &mappings);
    mappings_len = parsed.len;
    maps_complete = whole and parsed.all;
}

var maps_buf: [if (os == .linux) 1 << 19 else 0]u8 = undefined;
var maps_len: usize = 0;
var mappings: [if (os == .linux) 8192 else 0]Mapping = undefined;
var mappings_len: usize = 0;
var maps_complete = false;

/// A line of `/proc/self/maps`: its range, whether it is code, the base of the file it maps,
/// and that file's name as a range of the text.
const Mapping = struct { lo: usize, hi: usize, base: usize, exec: bool, name_at: u32, name_len: u32 };

/// Parses `/proc/self/maps` text into `out`, in the kernel's order (by address). The base of a
/// file's mapping is the start of that file's first mapping (offset 0): the load bias of an
/// object whose first segment is at address 0, though its code may sit at another offset from
/// its file offset than 0 (lld puts it a page on). `all` is false when `out` was too short.
fn parseMaps(text: []const u8, out: []Mapping) struct { len: usize, all: bool } {
    var n: usize = 0;
    var file_key: []const u8 = "";
    var file_base: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        // start-end perms offset dev inode [path]
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const range = fields.next() orelse continue;
        const perms = fields.next() orelse continue;
        const offset = std.fmt.parseInt(usize, fields.next() orelse continue, 16) catch continue;
        const dev = fields.next() orelse continue;
        const inode = fields.next() orelse continue;
        const dash = std.mem.findScalar(u8, range, '-') orelse continue;
        const lo = std.fmt.parseInt(usize, range[0..dash], 16) catch continue;
        const hi = std.fmt.parseInt(usize, range[dash + 1 ..], 16) catch continue;
        var path = std.mem.trim(u8, fields.rest(), " ");
        if (std.mem.endsWith(u8, path, " (deleted)")) path = path[0 .. path.len - " (deleted)".len];
        const name = std.fs.path.basename(path);
        // dev and inode together name the file; inode 0 is no file.
        const key = line[@intFromPtr(dev.ptr) - @intFromPtr(line.ptr) .. @intFromPtr(inode.ptr) - @intFromPtr(line.ptr) + inode.len];
        if (std.mem.eql(u8, inode, "0")) {
            file_key = "";
            file_base = lo;
        } else if (!std.mem.eql(u8, key, file_key)) {
            file_key = key;
            file_base = if (offset == 0) lo else lo -| offset;
        }
        if (n == out.len) return .{ .len = n, .all = false };
        out[n] = .{
            .lo = lo,
            .hi = hi,
            .base = file_base,
            .exec = perms.len >= 3 and perms[2] == 'x',
            .name_at = if (name.len == 0) 0 else @intCast(@intFromPtr(name.ptr) - @intFromPtr(text.ptr)),
            .name_len = @intCast(name.len),
        };
        n += 1;
    }
    return .{ .len = n, .all = true };
}

/// `address` among parsed mappings: code if an executable mapping holds it, not code if another
/// does or (the list being whole) none does.
fn mapsAt(maps: []const Mapping, text: []const u8, complete: bool, address: usize) At {
    // The last mapping starting at or below `address`.
    var lo: usize = 0;
    var hi: usize = maps.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (maps[mid].lo <= address) lo = mid + 1 else hi = mid;
    }
    if (lo > 0 and address < maps[lo - 1].hi) {
        const m = maps[lo - 1];
        if (!m.exec) return .{ .exec = .not_code };
        return .{ .exec = .code, .name = text[m.name_at..][0..m.name_len], .base = m.base };
    }
    return .{ .exec = if (complete) .not_code else .unknown };
}

/// The protection of the region holding `address`, descending into the shared cache's submaps.
fn machExec(address: usize) Exec {
    const KERN_INVALID_ADDRESS = 1;
    var depth: u32 = 0;
    for (0..8) |_| {
        var addr: u64 = address;
        var size: u64 = 0;
        // vm_region_submap_info_64 is #pragma pack(4) in C: protection is word 0, is_submap word 12.
        var info: [32]u32 = undefined;
        var count: u32 = 19; // VM_REGION_SUBMAP_INFO_COUNT_64
        const kr = mach_vm_region_recurse(std.c.mach_task_self(), &addr, &size, &depth, &info, &count);
        if (kr == KERN_INVALID_ADDRESS) return .not_code; // no region at or above it
        if (kr != 0) return .unknown;
        if (addr > address) return .not_code; // it lies in a hole below the next region
        if (info[12] == 0) return if (info[0] & 4 != 0) .code else .not_code; // VM_PROT_EXECUTE
        depth += 1;
    }
    return .unknown;
}

extern "c" fn mach_vm_region_recurse(task: std.c.mach_port_t, address: *u64, size: *u64, depth: *u32, info: *[32]u32, count: *u32) c_int;

// The table of loaded images, on macOS and Windows: names, and on macOS code ranges.

pub const Entry = struct {
    base: usize = 0,
    end: usize = 0,
    name_buf: [64]u8 = undefined,
    name_len: u8 = 0,

    pub fn name(e: *const Entry) []const u8 {
        return e.name_buf[0..e.name_len];
    }

    fn setName(e: *Entry, path: []const u8) void {
        const base = std.fs.path.basename(path);
        e.name_len = @intCast(@min(base.len, e.name_buf.len));
        @memcpy(e.name_buf[0..e.name_len], base[0..e.name_len]);
    }
};

const max_images = 1024;
var table: [max_images]Entry = undefined;
var used: [max_images]std.atomic.Value(bool) = @splat(.init(false));
/// Held by whoever writes the table (dyld's callbacks run on any thread). Readers never take it:
/// a slot is written whole before it is marked used, and marked unused before it is rewritten.
var writing: std.atomic.Value(bool) = .init(false);
/// Set when an image found the table full; `refresh` says so once.
var overflowed: std.atomic.Value(bool) = .init(false);

fn lock() void {
    while (writing.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn entryHolding(address: usize) ?*const Entry {
    for (&used, 0..) |*u, i| if (u.load(.acquire) and address >= table[i].base and address < table[i].end) return &table[i];
    return null;
}

/// Under the lock: enters `e`, replacing what was at its base. A slot in use is never written:
/// `e` goes into a free one, and only then is the old one let go, so a crash reading the table
/// meanwhile sees one whole entry or the other. Free slots are taken round-robin, so one just
/// let go is the last to be reused.
fn put(e: *const Entry) ?usize {
    var old: ?usize = null;
    for (&used, 0..) |*u, i| if (u.load(.acquire) and table[i].base == e.base) {
        if (std.meta.eql(table[i], e.*)) return i;
        old = i;
        break;
    };
    for (0..max_images) |k| {
        const i = (next_slot + k) % max_images;
        if (used[i].load(.acquire)) continue;
        table[i] = e.*;
        used[i].store(true, .release);
        next_slot = (i + 1) % max_images;
        if (old) |o| used[o].store(false, .release);
        return i;
    }
    overflowed.store(true, .release);
    return old;
}

var next_slot: usize = 0;

/// Takes the table from the loader. Calls the loader, so never from a crash handler. On macOS the
/// first call registers dyld's callbacks, which keep it from then on.
pub fn refresh() void {
    if (!supported or os == .linux) return;
    if (darwin) {
        if (!registered.swap(true, .acq_rel)) {
            _dyld_register_func_for_add_image(onAdd);
            _dyld_register_func_for_remove_image(onRemove);
            // dyld itself is in no image list; it is where every thread's stack starts.
            if (dyldHeader()) |h| addMacho(h, "dyld");
        }
    } else {
        lock();
        defer writing.store(false, .release);
        seen = @splat(false);
        enumerateWindows();
        for (&used, seen) |*u, s| if (!s) u.store(false, .release);
    }
    if (overflowed.swap(false, .acq_rel))
        std.log.warn("crash reports: more than {d} images loaded; the rest are named by address only", .{max_images});
}

var registered: std.atomic.Value(bool) = .init(false);
extern "c" fn _dyld_register_func_for_add_image(f: *const fn (*const anyopaque, isize) callconv(.c) void) void;
extern "c" fn _dyld_register_func_for_remove_image(f: *const fn (*const anyopaque, isize) callconv(.c) void) void;

fn onAdd(header: *const anyopaque, _: isize) callconv(.c) void {
    addMacho(header, "?");
}

/// Enters the Mach-O image at `header`, named by its file, or `unnamed` when dyld has no path.
fn addMacho(header: *const anyopaque, unnamed: []const u8) void {
    const img = image.machoAt(@ptrCast(@alignCast(header))) orelse return;
    var e: Entry = .{ .base = img.base, .end = img.end };
    var info: Dl_info = undefined;
    if (dladdr(header, &info) != 0) if (info.dli_fname) |f| e.setName(std.mem.span(f));
    if (e.name_len == 0) e.setName(unnamed);
    lock();
    defer writing.store(false, .release);
    _ = put(&e);
}

fn onRemove(header: *const anyopaque, _: isize) callconv(.c) void {
    lock();
    defer writing.store(false, .release);
    for (&used, 0..) |*u, i| if (u.load(.acquire) and table[i].base == @intFromPtr(header)) u.store(false, .release);
}

/// dyld's own header, from the task's `dyld_all_image_infos` (`dyldImageLoadAddress`), on
/// 64-bit targets.
fn dyldHeader() ?*const anyopaque {
    const TASK_DYLD_INFO = 17;
    var info: extern struct { addr: u64, size: u64, format: i32 } = undefined;
    var count: std.c.mach_msg_type_number_t = @sizeOf(@TypeOf(info)) / @sizeOf(std.c.natural_t);
    if (std.c.task_info(std.c.mach_task_self(), TASK_DYLD_INFO, @ptrCast(&info), &count) != 0 or info.addr == 0) return null;
    // version, infoArrayCount, infoArray, notification, two bools, then dyldImageLoadAddress.
    return @as(*const ?*const anyopaque, @ptrFromInt(info.addr + 32)).*;
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
    const MEM_COMMIT = 0x1000;
    /// PAGE_EXECUTE, _READ, _READWRITE, _WRITECOPY.
    const PAGE_EXECUTE_ANY = 0x10 | 0x20 | 0x40 | 0x80;
    const MEMORY_BASIC_INFORMATION = extern struct {
        BaseAddress: ?*anyopaque,
        AllocationBase: ?*anyopaque,
        AllocationProtect: u32,
        PartitionId: u16,
        RegionSize: usize,
        State: u32,
        Protect: u32,
        Type: u32,
    };
    extern "kernel32" fn VirtualQuery(address: ?*const anyopaque, info: *MEMORY_BASIC_INFORMATION, len: usize) callconv(.winapi) usize;
    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
    extern "kernel32" fn K32EnumProcessModules(process: HANDLE, modules: [*]?HANDLE, bytes: u32, needed: *u32) callconv(.winapi) i32;
    extern "kernel32" fn GetModuleFileNameW(module: ?HANDLE, name: [*]u16, len: u32) callconv(.winapi) u32;
};

// Under the lock, during `refresh`: kept static, off the stack.
var seen: [max_images]bool = @splat(false);
var modules_w: [max_images]?win.HANDLE = undefined;
var path_w: [512]u16 = undefined;
var path_8: [512 * 3]u8 = undefined;

fn enumerateWindows() void {
    if (os != .windows) return;
    var needed: u32 = 0;
    if (win.K32EnumProcessModules(win.GetCurrentProcess(), &modules_w, @sizeOf(@TypeOf(modules_w)), &needed) == 0) return;
    const n = @min(needed / @sizeOf(?win.HANDLE), modules_w.len);
    for (modules_w[0..n]) |m| {
        const img = image.containing(@intFromPtr(m orelse continue)) orelse continue;
        var e: Entry = .{ .base = img.base, .end = img.end };
        const len = win.GetModuleFileNameW(m, &path_w, path_w.len);
        e.setName(if (len == 0 or len >= path_w.len) "?" else path_8[0..std.unicode.wtf16LeToWtf8(&path_8, path_w[0..len])]);
        if (put(&e)) |i| seen[i] = true;
    }
}

test "this code is code, by its image's name; the heap and data are not" {
    if (!supported) return error.SkipZigTest;
    refresh();
    beginReport();
    const here = @intFromPtr(&refresh);
    const code = at(here);
    try std.testing.expectEqual(Exec.code, code.exec);
    try std.testing.expect(code.base <= here and code.name.len > 0);
    // A system library, reached through the dyld shared cache on macOS.
    try std.testing.expectEqual(Exec.code, at(@intFromPtr(&std.c.write)).exec);
    try std.testing.expectEqual(Exec.not_code, at(@intFromPtr(&table)).exec);
    const heap = try std.testing.allocator.create(usize);
    defer std.testing.allocator.destroy(heap);
    try std.testing.expectEqual(Exec.not_code, at(@intFromPtr(heap)).exec);
    try std.testing.expectEqual(Exec.not_code, at(0x1000).exec);
    if (darwin) { // the kernel's answer alone, as for an image the table doesn't hold
        try std.testing.expectEqual(Exec.code, machExec(here));
        try std.testing.expectEqual(Exec.code, machExec(@intFromPtr(&std.c.write)));
        try std.testing.expectEqual(Exec.not_code, machExec(@intFromPtr(heap)));
    }
}

test "maps say what is code, and name each file from its first mapping" {
    // lld's layout: the code a page past its file offset; a deleted file; the heap.
    const text =
        \\55d000000000-55d000001000 r--p 00000000 fd:01 42   /usr/bin/fizzy
        \\55d000002000-55d000009000 r-xp 00001000 fd:01 42   /usr/bin/fizzy
        \\55d00000a000-55d00000b000 rw-p 00008000 fd:01 42   /usr/bin/fizzy
        \\7f0000000000-7f0000021000 rw-p 00000000 00:00 0
        \\7f1000000000-7f1000028000 r--p 00000000 fd:01 7    /usr/lib/libc.so.6
        \\7f1000028000-7f1000180000 r-xp 00028000 fd:01 7    /usr/lib/libc.so.6
        \\7f2000000000-7f2000001000 r-xp 00000000 fd:01 9    /tmp/plugin.so (deleted)
        \\
    ;
    var maps: [16]Mapping = undefined;
    const parsed = parseMaps(text, &maps);
    try std.testing.expect(parsed.all);
    const m = maps[0..parsed.len];
    const fizzy = mapsAt(m, text, true, 0x55d000002200);
    try std.testing.expectEqual(Exec.code, fizzy.exec);
    try std.testing.expectEqualStrings("fizzy", fizzy.name);
    try std.testing.expectEqual(0x55d000000000, fizzy.base);
    const libc = mapsAt(m, text, true, 0x7f1000028100);
    try std.testing.expectEqualStrings("libc.so.6", libc.name);
    try std.testing.expectEqual(0x7f1000000000, libc.base);
    try std.testing.expectEqualStrings("plugin.so", mapsAt(m, text, true, 0x7f2000000010).name);
    try std.testing.expectEqual(Exec.not_code, mapsAt(m, text, true, 0x7f0000000010).exec); // the heap
    try std.testing.expectEqual(Exec.not_code, mapsAt(m, text, true, 0x55d00000a010).exec); // fizzy's data
    try std.testing.expectEqual(Exec.not_code, mapsAt(m, text, true, 0x55d000001010).exec); // a gap
    try std.testing.expectEqual(Exec.not_code, mapsAt(m, text, true, 0x1000).exec); // below them all
    try std.testing.expectEqual(Exec.unknown, mapsAt(m, text, false, 0x1000).exec); // or not read whole
    // Too many lines for the list: the rest is not known.
    try std.testing.expect(!parseMaps(text, maps[0..3]).all);
}

test "replacing an entry leaves the old one whole until the new one is in" {
    lock();
    defer writing.store(false, .release);
    var a: Entry = .{ .base = 0x9000_0000, .end = 0x9000_1000 };
    a.setName("old");
    const i = put(&a).?;
    var b = a;
    b.setName("new");
    const j = put(&b).?;
    try std.testing.expect(i != j);
    try std.testing.expect(!used[i].load(.acquire) and used[j].load(.acquire));
    try std.testing.expectEqualStrings("old", table[i].name());
    try std.testing.expectEqualStrings("new", entryHolding(0x9000_0010).?.name());
    used[j].store(false, .release);
}
