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
            /// Cancelled while `drain` was already delivering the batch it sits in. The
            /// caller has taken the payload back; `drain` skips it.
            skipped: bool = false,
            /// Its callback is running: a `remove` now would pull the payload out from under
            /// it, so `remove` declines and the caller leaves it to `drain`.
            active: bool = false,
        };

        allocator: Allocator,
        items: std.ArrayList(Item) = .empty,
        /// The batch `drain` is delivering right now, so a `remove` from inside a callback can
        /// still find a later item of the same batch and mark it skipped instead of letting it
        /// be delivered on memory the caller just freed.
        delivering: std.ArrayList(Item) = .empty,
        next_id: u64 = 1,

        pub fn init(allocator: Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.items.deinit(self.allocator);
            self.delivering.deinit(self.allocator);
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
        /// carried. Null when nothing is queued under that id — including one whose callback
        /// is running at this very moment, which the caller must leave to `drain`.
        pub fn remove(self: *Self, id: u64) ?Payload {
            for (self.items.items, 0..) |item, i| {
                if (item.id == id) return self.items.orderedRemove(i).payload;
            }
            for (self.delivering.items) |*item| {
                if (item.id == id and !item.skipped and !item.active) {
                    item.skipped = true;
                    return item.payload;
                }
            }
            return null;
        }

        /// Deliver everything queued so far through `deliver`, on this thread. A callback may
        /// start new jobs (they wait for the next drain) or cancel later ones in this batch
        /// (they are skipped). Re-entered from a callback, it does nothing: the outer drain is
        /// still walking the batch.
        pub fn drain(self: *Self, ctx: anytype, comptime deliver: fn (@TypeOf(ctx), Payload) void) void {
            if (self.delivering.items.len != 0) return;
            self.delivering = self.items;
            self.items = .empty;
            defer {
                self.delivering.deinit(self.allocator);
                self.delivering = .empty;
            }
            var i: usize = 0;
            while (i < self.delivering.items.len) : (i += 1) {
                const item = &self.delivering.items[i];
                if (item.skipped) continue;
                item.active = true;
                deliver(ctx, item.payload);
            }
        }
    };
}
