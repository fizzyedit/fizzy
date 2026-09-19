//! Injected HTTP transport. The library never opens sockets or calls JS; the host (native
//! `std.http` on a thread, wasm `fetch`, or a test double) supplies this.
//!
//! Same completion model as `Fs`: `request` starts, the callback runs from `pump()` on the
//! calling thread. A transport that answers synchronously (a canned test double) still queues
//! the response until `pump`, so a client built on it never sees a completion re-enter the
//! call that started it.

const std = @import("std");
const Fs = @import("Fs.zig");
const Allocator = std.mem.Allocator;

pub const Method = enum {
    GET,
    POST,
    PATCH,
    PUT,
    DELETE,

    pub fn asSlice(self: Method) []const u8 {
        return @tagName(self);
    }
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// `url`, `headers` and `body` must stay valid until the callback runs.
pub const Request = struct {
    method: Method,
    url: []const u8,
    headers: []const Header = &.{},
    body: []const u8 = &.{},
};

/// `body` is allocated with the allocator passed to `request` and owned by the callback.
pub const Response = struct {
    status: u16,
    body: []u8,

    pub fn deinit(self: Response, allocator: Allocator) void {
        allocator.free(self.body);
    }
};

pub const DoneFn = *const fn (ctx: ?*anyopaque, result: Fs.Error!Response) void;

pub const Job = struct {
    id: u64,
};

pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        request: *const fn (ptr: *anyopaque, allocator: Allocator, req: Request, cb: DoneFn, ctx: ?*anyopaque) Fs.Error!Job,
        /// Forget a request. Its callback will not run.
        cancel: *const fn (ptr: *anyopaque, job: Job) void,
        pump: *const fn (ptr: *anyopaque) void,
    };

    pub fn request(self: Transport, allocator: Allocator, req: Request, cb: DoneFn, ctx: ?*anyopaque) Fs.Error!Job {
        return self.vtable.request(self.ptr, allocator, req, cb, ctx);
    }
    pub fn cancel(self: Transport, job: Job) void {
        self.vtable.cancel(self.ptr, job);
    }
    pub fn pump(self: Transport) void {
        self.vtable.pump(self.ptr);
    }
};

/// Queue of completions a backend drains from its `pump`. Shared by `Mem`, the Drive client
/// and test transports so the "deliver later, on this thread, exactly once, unless cancelled"
/// contract is written once.
pub fn Completions(comptime Payload: type) type {
    return struct {
        const Self = @This();

        pub const Item = struct {
            id: u64,
            payload: Payload,
        };

        allocator: Allocator,
        items: std.ArrayList(Item) = .empty,
        next_id: u64 = 1,

        pub fn init(allocator: Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.items.deinit(self.allocator);
        }

        pub fn nextId(self: *Self) u64 {
            const id = self.next_id;
            self.next_id += 1;
            return id;
        }

        pub fn push(self: *Self, id: u64, payload: Payload) Allocator.Error!void {
            try self.items.append(self.allocator, .{ .id = id, .payload = payload });
        }

        /// Drop the completion for `id`, handing back its payload so the caller can free what it
        /// carried. Null when nothing is queued under that id.
        pub fn remove(self: *Self, id: u64) ?Payload {
            for (self.items.items, 0..) |item, i| {
                if (item.id == id) return self.items.orderedRemove(i).payload;
            }
            return null;
        }

        /// Take everything queued so far. Callbacks may start new jobs while these are being
        /// delivered; those land in the fresh list and wait for the next `pump`. The caller
        /// deinits the returned list with this queue's allocator.
        pub fn take(self: *Self) std.ArrayList(Item) {
            const taken = self.items;
            self.items = .empty;
            return taken;
        }
    };
}
