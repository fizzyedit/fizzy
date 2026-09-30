//! Answers a filesystem already has, held until its `pump`. `Fs` promises every completion
//! arrives from `pump`, never inside the call that asked — a caller that registers a document
//! when the read lands must be past its own bookkeeping by then. A backend that knows the answer
//! on the spot (`Mem`, the store's pages) computes it at once and queues it here.
const Deferred = @This();

const std = @import("std");
const Fs = @import("Fs.zig");
const http = @import("http.zig");
const Allocator = std.mem.Allocator;

completions: http.Completions(Completion),

const Completion = union(enum) {
    list: struct { allocator: Allocator, cb: Fs.ListDirFn, ctx: ?*anyopaque, result: Fs.Error![]Fs.Entry },
    stat: struct { cb: Fs.StatFn, ctx: ?*anyopaque, result: Fs.Error!Fs.Stat },
    read: struct { allocator: Allocator, cb: Fs.ReadFn, ctx: ?*anyopaque, result: Fs.Error!Fs.Read },
    done: struct { cb: Fs.DoneFn, ctx: ?*anyopaque, result: Fs.Error!void },

    fn discard(self: Completion) void {
        switch (self) {
            .list => |c| if (c.result) |entries| Fs.freeEntries(c.allocator, entries) else |_| {},
            .read => |c| if (c.result) |r| c.allocator.free(r.bytes) else |_| {},
            .stat, .done => {},
        }
    }

    fn deliver(self: Completion) void {
        switch (self) {
            .list => |c| c.cb(c.ctx, .of(c.result)),
            .stat => |c| c.cb(c.ctx, .of(c.result)),
            .read => |c| c.cb(c.ctx, .of(c.result)),
            .done => |c| c.cb(c.ctx, .of(c.result)),
        }
    }
};

pub fn init(allocator: Allocator) Deferred {
    return .{ .completions = .init(allocator) };
}

/// Answers never delivered are freed, not delivered.
pub fn deinit(self: *Deferred) void {
    for (self.completions.items.items) |item| item.payload.discard();
    self.completions.deinit();
}

/// `result` is owned by the queue until delivered (entries and bytes in `allocator`).
pub fn list(self: *Deferred, allocator: Allocator, cb: Fs.ListDirFn, ctx: ?*anyopaque, result: Fs.Error![]Fs.Entry) Fs.Error!Fs.Job {
    return self.queue(.{ .list = .{ .allocator = allocator, .cb = cb, .ctx = ctx, .result = result } });
}

pub fn stat(self: *Deferred, cb: Fs.StatFn, ctx: ?*anyopaque, result: Fs.Error!Fs.Stat) Fs.Error!Fs.Job {
    return self.queue(.{ .stat = .{ .cb = cb, .ctx = ctx, .result = result } });
}

pub fn read(self: *Deferred, allocator: Allocator, cb: Fs.ReadFn, ctx: ?*anyopaque, result: Fs.Error!Fs.Read) Fs.Error!Fs.Job {
    return self.queue(.{ .read = .{ .allocator = allocator, .cb = cb, .ctx = ctx, .result = result } });
}

pub fn done(self: *Deferred, cb: Fs.DoneFn, ctx: ?*anyopaque, result: Fs.Error!void) Fs.Error!Fs.Job {
    return self.queue(.{ .done = .{ .cb = cb, .ctx = ctx, .result = result } });
}

fn queue(self: *Deferred, completion: Completion) Fs.Error!Fs.Job {
    const id = self.completions.nextId();
    self.completions.push(id, completion) catch |err| {
        completion.discard();
        return err;
    };
    return .{ .id = id };
}

pub fn cancel(self: *Deferred, job: Fs.Job) void {
    if (self.completions.remove(job.id)) |completion| completion.discard();
}

pub fn pump(self: *Deferred) void {
    self.completions.drain({}, struct {
        fn f(_: void, c: Completion) void {
            c.deliver();
        }
    }.f);
}
