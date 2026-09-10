//! Browser `fetch` for the wasm build — GET a URL, get the body bytes back.
//!
//! The markdown preview's image path rasterizes via `Image` (SVG badges, CORS overlays).
//! Everything else that just needs bytes — the store catalog, plugin READMEs, card icons —
//! goes through here. Same handshake as the image trio: Zig starts the load with
//! `fizzy_web_fetch`, JS writes the body through `FizzyWebFetchAlloc` / `FizzyWebFetchReady`.
//!
//! UI thread only. A URL is fetched once and cached until `deinit`.
const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.target.cpu.arch != .wasm32) {
        @compileError("web_fetch.zig is wasm-only; gate the import with `arch == .wasm32`");
    }
}

const wasm = struct {
    extern "fizzy" fn fizzy_web_fetch(id: u32, url_ptr: [*]const u8, url_len: usize) void;
};

pub const Status = enum(u8) { fetching, ready, failed };

pub const Result = union(enum) {
    pending,
    ready: []const u8,
    failed,
};

const max_bytes: usize = 2 * 1024 * 1024;
const max_entries: usize = 256;

const Entry = struct {
    id: u32,
    status: Status = .fetching,
    bytes: ?[]u8 = null,
    url: []u8,
};

var entries: std.StringHashMapUnmanaged(*Entry) = .empty;
var gpa: ?std.mem.Allocator = null;
var next_id: u32 = 1;

fn entryById(id: u32) ?*Entry {
    var it = entries.valueIterator();
    while (it.next()) |e| {
        if (e.*.id == id) return e.*;
    }
    return null;
}

/// Look up `url`, starting a browser GET on first sight.
pub fn request(allocator: std.mem.Allocator, url: []const u8) Result {
    if (gpa == null) gpa = allocator;
    const a = gpa.?;

    if (entries.get(url)) |entry| {
        return switch (entry.status) {
            .fetching => .pending,
            .failed => .failed,
            .ready => if (entry.bytes) |b| .{ .ready = b } else .failed,
        };
    }

    if (entries.count() >= max_entries) return .failed;

    const url_owned = a.dupe(u8, url) catch return .failed;
    const entry = a.create(Entry) catch {
        a.free(url_owned);
        return .failed;
    };
    const id = next_id;
    next_id +|= 1;
    entry.* = .{ .id = id, .url = url_owned };
    entries.put(a, url_owned, entry) catch {
        a.free(url_owned);
        a.destroy(entry);
        return .failed;
    };
    wasm.fizzy_web_fetch(id, url_owned.ptr, url_owned.len);
    return .pending;
}

pub fn deinit() void {
    const a = gpa orelse {
        entries = .empty;
        return;
    };
    var it = entries.iterator();
    while (it.next()) |kv| {
        const entry = kv.value_ptr.*;
        if (entry.bytes) |b| a.free(b);
        a.free(entry.url);
        a.destroy(entry);
    }
    entries.deinit(a);
    entries = .empty;
    gpa = null;
}

export fn FizzyWebFetchAlloc(len: usize) usize {
    if (len == 0 or len > max_bytes) return 0;
    const a = gpa orelse return 0;
    const buf = a.alloc(u8, len) catch return 0;
    return @intFromPtr(buf.ptr);
}

export fn FizzyWebFetchReady(id: u32, ptr: usize, len: usize) void {
    const a = gpa orelse return;
    if (ptr == 0 or len == 0) {
        if (entryById(id)) |entry| entry.status = .failed;
        return;
    }
    const bytes = @as([*]u8, @ptrFromInt(ptr))[0..len];
    const entry = entryById(id) orelse {
        a.free(bytes);
        return;
    };
    if (entry.status != .fetching) {
        a.free(bytes);
        return;
    }
    entry.bytes = bytes;
    entry.status = .ready;
}

export fn FizzyWebFetchFailed(id: u32) void {
    const entry = entryById(id) orelse return;
    if (entry.status != .fetching) return;
    entry.status = .failed;
}
