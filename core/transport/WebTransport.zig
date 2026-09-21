//! `vfs.http.Transport` over the browser's `fetch`, for the wasm build.
//!
//! Zig starts a request through the `fizzy_web_request` import; JS answers through the three
//! exports at the bottom — allocate the body in wasm memory, hand it over with the status, or
//! report failure — and asks for a frame. The completion is parked until `pump`, which is the
//! transport contract: a caller never hears back from inside a JS callback.
//!
//! One transport per page: the exports are global, so the state is too. `transport()` hands
//! out the same one to everybody, and requests are told apart by id.
const std = @import("std");
const builtin = @import("builtin");
const vfs = @import("../vfs/vfs.zig");

comptime {
    if (builtin.target.cpu.arch != .wasm32) {
        @compileError("WebTransport is wasm-only; gate the import with `arch == .wasm32`");
    }
}

const wasm = struct {
    /// `headers` is `Name: value\n` lines. Everything is copied on the JS side before return.
    extern "fizzy" fn fizzy_web_request(
        id: u32,
        method_ptr: [*]const u8,
        method_len: usize,
        url_ptr: [*]const u8,
        url_len: usize,
        headers_ptr: [*]const u8,
        headers_len: usize,
        body_ptr: [*]const u8,
        body_len: usize,
    ) void;
};

/// A body past this is not something a page should be holding; the request fails instead.
const max_body: usize = 256 * 1024 * 1024;

const Pending = struct {
    id: u32,
    allocator: std.mem.Allocator,
    cb: vfs.http.DoneFn,
    ctx: ?*anyopaque,
    /// Set by the JS side; null until then.
    result: ?vfs.Error!vfs.http.Response = null,
    in_batch: bool = false,
    cancelled: bool = false,
};

var gpa: ?std.mem.Allocator = null;
var pending: std.AutoArrayHashMapUnmanaged(u32, *Pending) = .empty;
var next_id: u32 = 1;

/// The page's one transport. `allocator` outlives every request; the first caller sets it.
pub fn transport(allocator: std.mem.Allocator) vfs.http.Transport {
    if (gpa == null) gpa = allocator;
    return .{ .ptr = @ptrFromInt(@alignOf(Pending)), .vtable = &vtable };
}

const vtable: vfs.http.Transport.VTable = .{ .request = request, .cancel = cancel, .pump = pump };

fn request(_: *anyopaque, allocator: std.mem.Allocator, req: vfs.http.Request, cb: vfs.http.DoneFn, ctx: ?*anyopaque) vfs.Error!vfs.http.Job {
    const a = gpa orelse return error.Unsupported;
    const p = try a.create(Pending);
    errdefer a.destroy(p);
    p.* = .{ .id = 0, .allocator = allocator, .cb = cb, .ctx = ctx };

    // Headers as lines; the JS side splits them back out. Built here so the import takes one
    // buffer rather than a table of pointers.
    var lines: std.ArrayListUnmanaged(u8) = .empty;
    defer lines.deinit(a);
    for (req.headers) |h| {
        // The line format is the protocol between Zig and JS; a CR/LF in a value would end
        // the line early (or trap the frame inside `Headers.append`), so it is refused here.
        if (std.mem.indexOfAny(u8, h.name, "\r\n:") != null or std.mem.indexOfAny(u8, h.value, "\r\n") != null) return error.Http;
        try lines.appendSlice(a, h.name);
        try lines.appendSlice(a, ": ");
        try lines.appendSlice(a, h.value);
        try lines.append(a, '\n');
    }

    const id = next_id;
    next_id +%= 1;
    p.id = id;
    try pending.put(a, id, p);
    const method = req.method.asSlice();
    wasm.fizzy_web_request(id, method.ptr, method.len, req.url.ptr, req.url.len, lines.items.ptr, lines.items.len, req.body.ptr, req.body.len);
    return .{ .id = id };
}

fn cancel(_: *anyopaque, job: vfs.http.Job) void {
    const a = gpa orelse return;
    const p = pending.get(@intCast(job.id)) orelse return;
    _ = pending.swapRemove(@intCast(job.id));
    if (p.result) |r| {
        if (r) |resp| resp.deinit(p.allocator) else |_| {}
    }
    // Sitting in the batch `pump` is delivering: it must not deliver (or free) it after us.
    p.cancelled = true;
    if (!p.in_batch) a.destroy(p);
}

fn pump(_: *anyopaque) void {
    const a = gpa orelse return;
    // Collect first: a callback may start another request, which must not land in the list
    // being walked — and may cancel a later one, which is then skipped and freed here.
    var done: std.ArrayListUnmanaged(*Pending) = .empty;
    defer done.deinit(a);
    for (pending.values()) |p| {
        if (p.result != null) {
            p.in_batch = true;
            done.append(a, p) catch break;
        }
    }
    for (done.items) |p| {
        if (!p.cancelled) {
            _ = pending.swapRemove(p.id);
            p.cb(p.ctx, p.result.?);
        }
        a.destroy(p);
    }
}

// ---- the JS side's half -------------------------------------------------------------------

// Exported only if analysed: the host references this file once (see `Editor`), and this
// block makes that reference reach the three exports even before any plugin sends a request.
comptime {
    _ = &FizzyWebRequestAlloc;
    _ = &FizzyWebRequestReady;
    _ = &FizzyWebRequestFailed;
}

export fn FizzyWebRequestAlloc(id: u32, len: usize) usize {
    const p = pending.get(id) orelse return 0;
    if (len > max_body) return 0;
    if (len == 0) return @alignOf(u8); // a non-null token for an empty body
    const buf = p.allocator.alloc(u8, len) catch return 0;
    return @intFromPtr(buf.ptr);
}

export fn FizzyWebRequestReady(id: u32, status: u32, ptr: usize, len: usize) void {
    const p = pending.get(id) orelse return;
    const body: []u8 = if (len == 0) &.{} else @as([*]u8, @ptrFromInt(ptr))[0..len];
    p.result = .{ .status = @intCast(@min(status, std.math.maxInt(u16))), .body = body };
}

export fn FizzyWebRequestFailed(id: u32) void {
    const p = pending.get(id) orelse return;
    p.result = error.Http;
}
